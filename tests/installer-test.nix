# tests/installer-test.nix
#
# End-to-end nixosTest for the installer ISO. Boots a VM that imports the
# installer-iso module, attaches the INSTALL-KIT fixture as one disk and a
# blank target disk as another, lets the installer-autorun systemd service
# fire, asserts post-install state on /mnt.
#
# Phase 1 only: assertions run while /mnt is still mounted from the install
# (install.sh doesn't unmount or reboot — it just exits). A future phase 2
# task adds reboot-from-target with impermanence-survives-reboot assertions.
{
  pkgs,
  inputs, # for installer-iso's `inputs.disko.packages.<sys>.disko`
  self, # the flake itself, for testhost's pre-built system + diskoScript
  flakeSource, # = self.outPath
}: let
  kitImage = import ./installer-kit-fixture.nix {
    inherit pkgs flakeSource;
  };

  # Pre-built artifacts so the install runs without flake evaluation in
  # the VM (which has no internet). install.sh detects these env vars and
  # uses the pre-built paths instead of `disko --flake` / `nixos-install
  # --flake`.
  #
  # extendModules overrides testhost's disko device sentinel with the
  # actual VM target disk (/dev/vdb) so the rendered diskoScript has the
  # right path baked in. testhost itself stays untouched — production
  # still substitutes the sentinel at install time via install.sh.
  testhostVm = self.nixosConfigurations.testhost.extendModules {
    modules = [
      ({lib, ...}: {
        btrfs-impermanence.device = lib.mkForce "/dev/vdb";
      })
    ];
  };
  testhostDiskoScript = testhostVm.config.system.build.diskoScript;
  testhostSystem = testhostVm.config.system.build.toplevel;
in
  pkgs.testers.runNixOSTest {
    name = "installer";

    nodes.machine = {
      lib,
      pkgs,
      ...
    }: {
      # installer-iso/default.nix consumes `inputs.disko.packages.<sys>.disko`,
      # so the test machine module needs `inputs` in scope.
      _module.args = {inherit inputs;};

      imports = [
        ../modules/installer-iso
      ];

      # Qemu virtual hw doesn't need real firmware blobs, and the test
      # framework's read-only nixpkgs.config has allowUnfree=false — so
      # the production installer-iso's mkDefault enableAllFirmware=true
      # would fail eval. Override to false.
      hardware.enableAllFirmware = lib.mkForce false;

      # installation-device.nix (transitive import of installation-cd-minimal.nix)
      # adds an mbrola-voices slim-down overlay; the test framework makes
      # nixpkgs.overlays read-only when pre-passing pkgs, so this would
      # conflict. Override with empty (mbrola is irrelevant in the test).
      nixpkgs.overlays = lib.mkForce [];

      # Test-only env overrides for installer-autorun:
      #   DISK=/dev/vdb                  skip install.sh's interactive disk picker
      #   BOOTSTRAP_AUTO_CONFIRM=1       skip the hostname-literal prompt
      #   BOOTSTRAP_DISKO_SCRIPT=...     use pre-built script (no flake eval)
      #   BOOTSTRAP_NIXOS_INSTALL_SYSTEM=...  use pre-built closure (ditto)
      systemd.services.installer-autorun.environment = {
        DISK = "/dev/vdb";
        BOOTSTRAP_AUTO_CONFIRM = "1";
        BOOTSTRAP_DISKO_SCRIPT = "${testhostDiskoScript}";
        BOOTSTRAP_NIXOS_INSTALL_SYSTEM = "${testhostSystem}";
      };

      # Pull testhost's pre-built closures into the VM's nix store so
      # install.sh's nixos-install --system call finds them.
      system.extraDependencies = [
        testhostDiskoScript
        testhostSystem
      ];

      # Pre-populate /tmp/secret.key BEFORE installer-autorun fires.
      # disko's luks.passwordFile defaults to /tmp/secret.key (see
      # modules/disko/btrfs-impermanence.nix).
      systemd.services.test-luks-key = {
        description = "Pre-populate LUKS passphrase for the test install";
        wantedBy = ["installer-autorun.service"];
        before = ["installer-autorun.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${pkgs.coreutils}/bin/printf 'testpass\n' > /tmp/secret.key
          ${pkgs.coreutils}/bin/chmod 600 /tmp/secret.key
        '';
      };

      # VM disk layout:
      #   /dev/vda = test machine's own root (auto-created by the test framework)
      #   /dev/vdb = blank install target (8 GB)
      #   /dev/vdc = INSTALL-KIT fixture (label drives discovery)
      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 8192;

        # Blank target disk — install.sh writes here.
        emptyDiskImages = [8192];

        # UEFI: install.sh's preflight requires /sys/firmware/efi.
        useEFIBoot = true;

        # Attach the kit fixture as a third virtio disk. ext4 label
        # INSTALL-KIT → udev creates /dev/disk/by-label/INSTALL-KIT.
        # readonly=on prevents the test from accidentally writing to it
        # (matches the production ISO's `mount -o ro`).
        qemu.options = [
          "-drive if=virtio,file=${kitImage},format=raw,readonly=on"
        ];
      };

      # Suppress the unused-binding warning for `lib`.
      _module.args = {inherit lib;};
    };

    testScript = ''
      machine.start()

      machine.wait_for_unit("multi-user.target")

      # Pre-condition: kit is visible by label (attached at qemu start time)
      machine.succeed("test -b /dev/disk/by-label/INSTALL-KIT")

      # Wait for the install pipeline to complete. installer-autorun is
      # a oneshot without RemainAfterExit, so it transitions through
      # active→inactive on success — wait_for_unit can race this. Poll the
      # journal for install.sh's report_success line instead. On failure,
      # dump the journal so we can diagnose without re-running.
      try:
          machine.wait_until_succeeds(
              "journalctl -u installer-autorun | grep -q 'Install complete'",
              timeout=600,
          )
      except Exception:
          machine.execute("journalctl -u installer-autorun --no-pager | tail -200 >&2")
          raise

      # Assert the service exited 0 (not just that the success line printed)
      machine.succeed(
          "systemctl show installer-autorun --property=Result --value | grep -q '^success$'"
      )

      # Assert the report_success message landed in the journal — proves
      # install.sh ran end-to-end.
      machine.succeed("journalctl -u installer-autorun | grep -q 'Install complete'")

      # /mnt is still mounted at this point (install.sh doesn't unmount).
      # Identity copy assertions:
      machine.succeed("test -f /mnt/persist/etc/age/testhost.agekey")
      machine.succeed('[ "$(stat -c %a /mnt/persist/etc/age/testhost.agekey)" = "600" ]')
      machine.succeed("test -f /mnt/persist/etc/ssh/ssh_host_ed25519_key")
      machine.succeed("test -f /mnt/persist/etc/ssh/ssh_host_ed25519_key.pub")
      machine.succeed("test -f /mnt/home/joshsymonds/.ssh/id_ed25519")

      # Btrfs subvolume layout (proves disko ran the expected layout):
      machine.succeed("btrfs subvolume list /mnt | grep -qE '@root\\b'")
      machine.succeed("btrfs subvolume list /mnt | grep -q '@persist'")
      machine.succeed("btrfs subvolume list /mnt | grep -q '@root-blank'")

      # nixos-install actually wrote the system closure
      machine.succeed("test -L /mnt/nix/var/nix/profiles/system")
    '';
  }
