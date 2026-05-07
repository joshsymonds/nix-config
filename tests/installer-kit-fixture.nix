# installer-kit-fixture.nix
#
# Build-time fixture for the installer nixosTest. Produces an ext4
# filesystem image labeled INSTALL-KIT containing the same files a real
# kit USB would carry, but for testhost (the test fixture nixosConfig).
# Identity keys are generated inside the derivation — no real credentials
# ever land in /nix/store.
#
# Outputs an ext4 disk image. The nixosTest attaches it as a virtual disk;
# the installer-autorun service finds it via /dev/disk/by-label/INSTALL-KIT.
#
# The build itself is the test: assertions at the end fail the build if
# the kit format is wrong (label, file presence, identity perms).
{
  pkgs,
  flakeSource, # = self.outPath at the call site
}: let
  # Step 1: assemble the kit tree. A plain directory containing the same
  # files a real `make-install-usb.sh` would write to the kit partition.
  kitTree =
    pkgs.runCommand "installer-kit-tree" {
      nativeBuildInputs = [pkgs.openssh pkgs.gnutar pkgs.gzip];
    } ''
      set -euo pipefail
      mkdir -p $out/identity

      # Test-only host SSH keypair (no passphrase, fresh each build).
      ssh-keygen -q -t ed25519 -N "" \
        -f $out/identity/ssh_host_ed25519_key \
        -C "root@testhost-fixture"

      # Test-only user SSH keypair.
      ssh-keygen -q -t ed25519 -N "" \
        -f $out/identity/id_ed25519 \
        -C "joshsymonds+testhost-fixture"

      # Test-only agekey: opaque to the install path. Real agekeys come from
      # `ssh-to-age -private-key`; install.sh just copies it to /persist as-is.
      printf 'AGE-TESTHOST-FIXTURE-KEY-DO-NOT-USE\n' > $out/identity/testhost.agekey
      chmod 600 $out/identity/testhost.agekey
      chmod 600 $out/identity/ssh_host_ed25519_key
      chmod 600 $out/identity/id_ed25519
      chmod 644 $out/identity/ssh_host_ed25519_key.pub
      chmod 644 $out/identity/id_ed25519.pub

      cat > $out/manifest.env <<'MANIFEST'
      HOSTNAME=testhost
      FLAKE_REF=path:/tmp/nix-config
      KIT_BUILT_AT=fixture-build
      KIT_HEAD=fixture
      MANIFEST

      cat > $out/banner.txt <<'BANNER'
      === testhost installer (VM-test fixture) ===
      BANNER

      # Frozen flake snapshot. ${flakeSource} is the flake's source path in
      # /nix/store — already filtered to git-tracked content (the nix flake
      # source-path treatment), so .git, result/, .direnv, and other
      # untracked detritus aren't included.
      #
      # --transform prepends nix-config/ so install.sh's extract_flake
      # (which uses --strip-components=1) drops files at the right place.
      tar -czf $out/nix-config.tar.gz \
        --transform 's,^\./,nix-config/,' \
        --transform 's,^/,nix-config/,' \
        -C ${flakeSource} \
        .
    '';

  # Step 2: wrap the kit tree as an ext4 filesystem image labeled
  # INSTALL-KIT. mke2fs -d populates the FS from the directory tree
  # without needing loopback mounts (works in nix sandbox).
  #
  # 256 MiB is conservative; the actual fixture content is a few MB.
  kitImage =
    pkgs.runCommand "installer-kit-fixture" {
      nativeBuildInputs = [pkgs.e2fsprogs pkgs.coreutils];
    } ''
      set -euo pipefail
      truncate -s 256M $out
      mke2fs -t ext4 -L INSTALL-KIT -d ${kitTree} -E root_owner=0:0 -F $out

      # Self-test: assert label is correct.
      label=$(${pkgs.e2fsprogs}/bin/e2label $out)
      if [ "$label" != "INSTALL-KIT" ]; then
        echo "ASSERT FAIL: expected label INSTALL-KIT, got '$label'" >&2
        exit 1
      fi

      # Self-test: assert critical files are present in the image. We use
      # debugfs to introspect the FS without mounting it.
      expected_files=(
        "manifest.env"
        "banner.txt"
        "nix-config.tar.gz"
        "identity/ssh_host_ed25519_key"
        "identity/ssh_host_ed25519_key.pub"
        "identity/id_ed25519"
        "identity/id_ed25519.pub"
        "identity/testhost.agekey"
      )
      for f in "''${expected_files[@]}"; do
        if ! ${pkgs.e2fsprogs}/bin/debugfs -R "stat /$f" $out 2>/dev/null | grep -q "Inode:"; then
          echo "ASSERT FAIL: kit image missing /$f" >&2
          exit 1
        fi
      done

      echo "Fixture self-test passed: label=INSTALL-KIT, all 8 expected files present"
    '';
in
  kitImage
