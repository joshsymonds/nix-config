# installer-iso — generic NixOS installer ISO with auto-install service.
#
# Pairs with a per-host kit on a separately-labeled partition (INSTALL-KIT)
# on the same USB. The kit holds identity + manifest + flake snapshot;
# this ISO holds the install logic and the service that fires it.
#
# At build time the ISO derivation contains zero host-specific data —
# safe to push to a public binary cache. The actual host data is written
# to the kit partition by scripts/make-install-usb.sh (later task).
#
# At boot time:
#   1. Stock NixOS minimal ISO comes up; networkd brings up Ethernet
#   2. installer-autorun service fires after network-online.target
#   3. Service waits for /dev/disk/by-label/INSTALL-KIT, mounts it, exports
#      KIT_DIR=/run/installer-kit, execs install.sh
#   4. install.sh handles: pick disk → confirm hostname → disko → @root-blank
#      snapshot → copy identity → nixos-install → poweroff
{
  inputs,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  caches = import ../../lib/caches.nix;
  diskoPkg = inputs.disko.packages.${pkgs.stdenv.hostPlatform.system}.disko;

  # The install logic itself — a real .sh file with shellcheck and bats
  # coverage. Inline shell in the systemd-service wrapper below is just
  # plumbing (wait-for-label → mount → exec); the install pipeline lives
  # in install.sh, which is the structural fix for the original
  # autoInstaller's untested-vibecode failure mode.
  installScript = ./install.sh;

  defaultBanner = ''
    ███╗   ██╗██╗██╗  ██╗ ██████╗ ███████╗    ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗     ███████╗██████╗
    ████╗  ██║██║╚██╗██╔╝██╔═══██╗██╔════╝    ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝██╔══██╗
    ██╔██╗ ██║██║ ╚███╔╝ ██║   ██║███████╗    ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     █████╗  ██████╔╝
    ██║╚██╗██║██║ ██╔██╗ ██║   ██║╚════██║    ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██╔══╝  ██╔══██╗
    ██║ ╚████║██║██╔╝ ██╗╚██████╔╝███████║    ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗███████╗██║  ██║
    ╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝    ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝

    Plug in the install USB. The installer service will start automatically
    once a partition labeled INSTALL-KIT is detected. Press Ctrl-C to drop
    to a shell if you need to debug.
  '';
in {
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  # nixpkgs.config.allowUnfree is set by the production install path (see
  # flake.nix's nixosHostDefinitions.installer) so the test machine can
  # inherit the framework's locked-down nixpkgs.config without a merge
  # conflict. enableAllFirmware is mkDefault so the test can override
  # to false (qemu virtual hw doesn't need real firmware).
  hardware.enableAllFirmware = lib.mkDefault true;

  # Cachix substituters baked in so nixos-install can pull from binary
  # cache without per-install configuration. Same set as the legacy
  # installer.nix; cuda is included because future hosts (e.g. gnomon)
  # may need it. trusted-users restricted to root — the installer is
  # not a development environment.
  nix.settings = {
    experimental-features = "nix-command flakes";
    extra-substituters = [
      caches.nixCommunity.url
      caches.joshsymonds.url
      "https://devenv.cachix.org"
      caches.cuda.url
      caches.niri.url
    ];
    extra-trusted-public-keys = [
      caches.nixCommunity.publicKey
      caches.joshsymonds.publicKey
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      caches.cuda.publicKey
      caches.niri.publicKey
    ];
    trusted-users = ["root"];
  };

  # Tools available on a shell drop-out for manual recovery / debugging.
  # disko is bundled too, so install.sh's run_disko prefers the local
  # binary (works offline; required for the nixosTest to pass in CI).
  environment.systemPackages =
    (with pkgs; [
      util-linux
      gptfdisk
      e2fsprogs
      dosfstools
      btrfs-progs
      cryptsetup
      git
      jq
      sbctl # install.sh's prepare_bootloader_keys, for lanzaboote hosts
    ])
    ++ [diskoPkg];

  services.getty.helpLine = defaultBanner;

  # Auto-install service. Inline shell here is plumbing only (wait, mount,
  # exec); the install logic itself is in ${installScript}.
  systemd.services.installer-autorun = {
    description = "Auto-install NixOS using kit on INSTALL-KIT-labeled partition";
    wantedBy = ["multi-user.target"];
    after = ["multi-user.target" "network-online.target"];
    wants = ["network-online.target"];
    path =
      (with pkgs; [
        bash # install.sh's shebang `/usr/bin/env bash` needs bash in PATH
        util-linux # mount, umount, lsblk
        gptfdisk
        e2fsprogs
        dosfstools
        btrfs-progs
        cryptsetup
        coreutils
        gawk
        gnugrep
        gnused
        gnutar
        gzip
        systemd
        gitMinimal
        openssh
        nix # nixos-install internally invokes nix-env / nix
        nixos-install-tools
        sbctl # install.sh's prepare_bootloader_keys
      ])
      ++ [diskoPkg]; # so install.sh's run_disko sees `disko` in $PATH
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      set -euo pipefail

      KIT_LABEL="INSTALL-KIT"
      KIT_DIR="/run/installer-kit"
      export KIT_DIR

      echo "→ Waiting for /dev/disk/by-label/$KIT_LABEL ..."
      tries=0
      until [ -b "/dev/disk/by-label/$KIT_LABEL" ]; do
        tries=$((tries + 1))
        if [ "$tries" -ge 60 ]; then
          echo "ERROR: $KIT_LABEL did not appear after 60s. Plug in the install USB and retry." >&2
          exit 1
        fi
        sleep 1
      done

      echo "→ Mounting kit at $KIT_DIR ..."
      mkdir -p "$KIT_DIR"
      mount -o ro "/dev/disk/by-label/$KIT_LABEL" "$KIT_DIR"

      # Per-host banner overlay (optional). The default banner is shown on
      # getty before this service runs; this echoes a kit-specific banner
      # to journal+console once the kit is mounted.
      if [ -f "$KIT_DIR/banner.txt" ]; then
        cat "$KIT_DIR/banner.txt"
      fi

      echo "→ Handing off to install.sh ..."
      exec ${installScript}
    '';
  };
}
