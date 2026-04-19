{
  config,
  lib,
  pkgs,
  modulesPath,
  outputs,
  ...
}: let
  cfg = config.autoInstaller;
  inherit (pkgs) util-linux jq gptfdisk e2fsprogs dosfstools;

  prebuiltSystem =
    lib.optionalString cfg.prebuilt
    outputs.nixosConfigurations.${cfg.targetHost}.config.system.build.toplevel;

  installerSshKey =
    pkgs.runCommand "installer-ssh-key-${cfg.targetHost}" {
      nativeBuildInputs = [pkgs.openssh];
    } ''
      mkdir -p $out
      ssh-keygen -t ed25519 -C "${cfg.targetHost}-installer" -f $out/id_ed25519 -N ""
      echo ""
      echo "================================================================"
      echo "  INSTALLER SSH PUBLIC KEY for ${cfg.targetHost}:"
      echo "  $(cat $out/id_ed25519.pub)"
      echo "================================================================"
      echo ""
    '';

  diskDetectionScript = ''
    echo "Selecting installation disk..."
    disk="''${INSTALL_DISK:-}"

    if [[ -z "$disk" ]]; then
      # Try EFI boot entries to find the BIOS-preferred boot disk
      if command -v efibootmgr &>/dev/null; then
        efi_disk=$(efibootmgr -v 2>/dev/null | grep -i 'boot[0-9]' | head -1 | grep -oP '/dev/\S+' | head -1 || true)
        if [[ -n "$efi_disk" && -b "$efi_disk" ]]; then
          efi_parent=$(${util-linux}/bin/lsblk -ndo PKNAME "$efi_disk" 2>/dev/null || true)
          if [[ -n "$efi_parent" && -b "/dev/$efi_parent" ]]; then
            disk="/dev/$efi_parent"
            echo "Selected disk from EFI boot entry: $disk"
          fi
        fi
      fi
    fi

    if [[ -z "$disk" ]]; then
      # Find non-removable disks using plain lsblk (no JSON/jq — more robust)
      # -d = no partitions, -n = no header, -o = columns
      candidates=$(${util-linux}/bin/lsblk -dno NAME,RM,TYPE | awk '$2 == "0" && $3 == "disk" { print $1 }')

      best=""
      best_score=-1
      for cand in $candidates; do
        score=0
        has_esp=$(${util-linux}/bin/lsblk -nro PARTTYPE "/dev/$cand" 2>/dev/null | grep -ci 'c12a7328' || true)
        if [[ "$has_esp" -gt 0 ]]; then
          score=1000
        fi
        nparts=$(${util-linux}/bin/lsblk -nro TYPE "/dev/$cand" 2>/dev/null | grep -c 'part' || true)
        score=$((score + nparts))
        if [[ $score -gt $best_score ]]; then
          best="$cand"
          best_score=$score
        fi
      done

      if [[ -n "$best" ]]; then
        disk="/dev/$best"
        echo "Selected disk by partition heuristic (score=$best_score): $disk"
      fi
    fi

    if [[ -z "$disk" ]]; then
      # Final fallback: largest non-removable disk
      disk=$(${util-linux}/bin/lsblk -dno NAME,SIZE,RM,TYPE --bytes | awk '$3 == "0" && $4 == "disk" { print $2, $1 }' | sort -rn | head -1 | awk '{ print $2 }')
      if [[ -n "$disk" ]]; then
        disk="/dev/$disk"
        echo "Selected largest non-removable disk: $disk"
      fi
    fi

    if [[ -z "$disk" || ! -b "$disk" ]]; then
      echo "Could not determine install disk" >&2
      exit 1
    fi

    echo ""
    echo "============================================"
    echo "  TARGET: ${cfg.targetHost}"
    echo "  DISK:   $disk"
    ${util-linux}/bin/lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL "$disk"
    echo "============================================"
    echo ""
    echo "This will DESTROY ALL DATA on $disk."
    confirm=$(${pkgs.systemd}/bin/systemd-ask-password "Type 'yes' to continue")
    if [[ "$confirm" != "yes" ]]; then
      echo "Aborted by user." >&2
      exit 1
    fi
  '';

  partitionScript =
    if cfg.luks.enable
    then ''
      ${gptfdisk}/bin/sgdisk --zap-all "$disk"
      ${gptfdisk}/bin/sgdisk -n1:1MiB:+1G -t1:ef00 -c1:${cfg.labels.efi} "$disk"
      ${gptfdisk}/bin/sgdisk -n2:0:0 -t2:8300 -c2:${cfg.labels.luks} "$disk"
      ${util-linux}/bin/partprobe "$disk"
      sleep 2

      wait_for [ -b /dev/disk/by-partlabel/${cfg.labels.efi} ]
      wait_for [ -b /dev/disk/by-partlabel/${cfg.labels.luks} ]

      echo "Formatting partitions..."
      ${dosfstools}/bin/mkfs.vfat -F32 -n ${cfg.labels.efi} /dev/disk/by-partlabel/${cfg.labels.efi}

      passphrase=$(${pkgs.systemd}/bin/systemd-ask-password "Enter LUKS passphrase for ${cfg.targetHost} install")
      if [[ -z "$passphrase" ]]; then
        echo "Empty passphrase not allowed" >&2
        exit 1
      fi
      mapperName="${cfg.luks.mapperName}"
      if [[ -e "/dev/mapper/$mapperName" ]]; then
        echo "/dev/mapper/$mapperName already exists; close it before installing" >&2
        exit 1
      fi
      printf '%s' "$passphrase" | ${pkgs.cryptsetup}/bin/cryptsetup luksFormat --type luks2 --batch-mode /dev/disk/by-partlabel/${cfg.labels.luks} -
      printf '%s' "$passphrase" | ${pkgs.cryptsetup}/bin/cryptsetup open /dev/disk/by-partlabel/${cfg.labels.luks} "$mapperName" --key-file - --allow-discards
      unset passphrase
      ${e2fsprogs}/bin/mkfs.ext4 -F -L ${cfg.labels.root} "/dev/mapper/$mapperName"

      echo "Mounting target..."
      mount "/dev/mapper/$mapperName" /mnt
    ''
    else if cfg.swap.enable
    then ''
      ${gptfdisk}/bin/sgdisk --zap-all "$disk"
      ${gptfdisk}/bin/sgdisk -n1:1MiB:+1G -t1:ef00 -c1:${cfg.labels.efi} "$disk"
      ${gptfdisk}/bin/sgdisk -n2:0:-${cfg.swap.size} -t2:8300 -c2:${cfg.labels.root} "$disk"
      ${gptfdisk}/bin/sgdisk -n3:0:0 -t3:8200 -c3:${cfg.labels.swap} "$disk"
      ${util-linux}/bin/partprobe "$disk"
      sleep 2

      wait_for [ -b /dev/disk/by-partlabel/${cfg.labels.efi} ]
      wait_for [ -b /dev/disk/by-partlabel/${cfg.labels.root} ]
      wait_for [ -b /dev/disk/by-partlabel/${cfg.labels.swap} ]

      echo "Formatting partitions..."
      ${dosfstools}/bin/mkfs.vfat -F32 -n ${cfg.labels.efi} /dev/disk/by-partlabel/${cfg.labels.efi}
      ${e2fsprogs}/bin/mkfs.ext4 -F -L ${cfg.labels.root} /dev/disk/by-partlabel/${cfg.labels.root}
      ${util-linux}/bin/mkswap -L ${cfg.labels.swap} /dev/disk/by-partlabel/${cfg.labels.swap}
      swapon /dev/disk/by-partlabel/${cfg.labels.swap}

      echo "Mounting target..."
      mount /dev/disk/by-partlabel/${cfg.labels.root} /mnt
    ''
    else ''
      ${gptfdisk}/bin/sgdisk --zap-all "$disk"
      ${gptfdisk}/bin/sgdisk -n1:1MiB:+1G -t1:ef00 -c1:${cfg.labels.efi} "$disk"
      ${gptfdisk}/bin/sgdisk -n2:0:0 -t2:8300 -c2:${cfg.labels.root} "$disk"
      ${util-linux}/bin/partprobe "$disk"
      sleep 2

      wait_for [ -b /dev/disk/by-partlabel/${cfg.labels.efi} ]
      wait_for [ -b /dev/disk/by-partlabel/${cfg.labels.root} ]

      echo "Formatting partitions..."
      ${dosfstools}/bin/mkfs.vfat -F32 -n ${cfg.labels.efi} /dev/disk/by-partlabel/${cfg.labels.efi}
      ${e2fsprogs}/bin/mkfs.ext4 -F -L ${cfg.labels.root} /dev/disk/by-partlabel/${cfg.labels.root}

      echo "Mounting target..."
      mount /dev/disk/by-partlabel/${cfg.labels.root} /mnt
    '';

  postMountScript = ''
    mkdir -p /mnt/boot ${lib.concatMapStringsSep " " (d: "/mnt/${d}") cfg.extraMountDirs}
    mount /dev/disk/by-partlabel/${cfg.labels.efi} /mnt/boot
    ${lib.concatStringsSep "\n" cfg.extraPostMountCommands}
  '';

  cloneScript = ''
    repoRemote="''${REPO_REMOTE:-${cfg.repoRemote}}"
    targetRepo=${cfg.repoClonePath}
    if [[ -d "$targetRepo/.git" ]]; then
      git -C "$targetRepo" fetch origin
      git -C "$targetRepo" reset --hard origin/main
    else
      rm -rf "$targetRepo"
      git clone "$repoRemote" "$targetRepo"
    fi
  '';

  # nixos-install's built-in bootloader step calls `bootctl status` which fails
  # in a chroot when /boot is empty. Work around: install with --no-bootloader,
  # then manually run bootctl install + the NixOS bootloader script.
  bootloaderFixup = ''
    echo "Installing bootloader..."
    for fs in dev proc sys; do mount --rbind /$fs /mnt/$fs && mount --make-rslave /mnt/$fs; done
    mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || true

    # Use the ISO's bootctl to pre-install systemd-boot EFI binaries
    ${pkgs.systemd}/bin/bootctl install --root=/mnt --esp-path=/boot || true

    # Now run the NixOS bootloader script (bootctl status will pass since it's installed)
    NIXOS_INSTALL_BOOTLOADER=1 chroot /mnt /nix/var/nix/profiles/system/bin/switch-to-configuration boot || echo "WARNING: switch-to-configuration had errors (non-fatal for boot)"

    umount /mnt/sys/firmware/efi/efivars 2>/dev/null || true
    for fs in sys proc dev; do umount -R /mnt/$fs 2>/dev/null || true; done
  '';

  installScript =
    if cfg.prebuilt
    then ''
      echo "Running nixos-install with prebuilt system..."
      ${config.system.build.nixos-install}/bin/nixos-install \
        --system ${prebuiltSystem} \
        --root /mnt \
        --no-root-passwd \
        --no-channel-copy \
        --no-bootloader \
        --cores 0

      ${bootloaderFixup}
    ''
    else ''
      echo "Running nixos-install from flake (building on target)..."

      # Configure root's SSH so the nix daemon can fetch git+ssh:// inputs.
      # The daemon runs as root; when it spawns git→ssh, ssh reads /root/.ssh/.
      # An ssh-agent won't work here because the daemon has its own environment.
      mkdir -p /root/.ssh
      cp ${installerSshKey}/id_ed25519 /root/.ssh/id_ed25519
      chmod 600 /root/.ssh/id_ed25519
      printf '%s\n' "Host github.com" "  IdentityFile /root/.ssh/id_ed25519" "  StrictHostKeyChecking accept-new" > /root/.ssh/config
      chmod 600 /root/.ssh/config

      # Restart the nix daemon so it inherits a clean environment
      ${pkgs.systemd}/bin/systemctl restart nix-daemon.service
      sleep 2

      ${config.system.build.nixos-install}/bin/nixos-install \
        --flake ${cfg.repoClonePath}#${cfg.targetHost} \
        --root /mnt \
        --no-root-passwd \
        --no-channel-copy \
        --no-bootloader \
        --cores 0

      ${bootloaderFixup}
    '';

  postInstallFixup = ''
    echo "Fixing up installed system..."
    targetHome="/mnt/home/${cfg.targetUser}"

    # Copy baked-in SSH key to target user's ~/.ssh/
    if [[ -d "$targetHome" ]]; then
      mkdir -p "$targetHome/.ssh"
      cp ${installerSshKey}/id_ed25519 "$targetHome/.ssh/github"
      cp ${installerSshKey}/id_ed25519.pub "$targetHome/.ssh/github.pub"
      cat > "$targetHome/.ssh/config" <<SSHEOF
    Host github.com
      IdentityFile ~/.ssh/github
    SSHEOF
      chmod 700 "$targetHome/.ssh"
      chmod 600 "$targetHome/.ssh/github" "$targetHome/.ssh/config"
      chmod 644 "$targetHome/.ssh/github.pub"

      # Chown entire home directory (was created as root during install)
      chown -R 1000:100 "$targetHome"
      echo "SSH key deployed and home directory ownership fixed."
    else
      echo "WARNING: $targetHome does not exist, skipping SSH key deployment."
    fi
  '';

  cleanupScript =
    ''
      echo "Syncing and ${
        if cfg.powerOff
        then "powering off"
        else "rebooting"
      }..."
      sync
      umount -R /mnt || true
    ''
    + lib.optionalString cfg.luks.enable ''
      ${pkgs.cryptsetup}/bin/cryptsetup close "${cfg.luks.mapperName}"
    ''
    + (
      if cfg.powerOff
      then ''
        ${pkgs.systemd}/bin/systemctl poweroff
      ''
      else ''
        ${pkgs.systemd}/bin/systemctl reboot
      ''
    );

  serviceName = "${cfg.targetHost}-auto-install";
in {
  options.autoInstaller = {
    targetHost = lib.mkOption {
      type = lib.types.str;
      description = "Name of the nixosConfiguration to install";
    };

    labels = {
      efi = lib.mkOption {
        type = lib.types.str;
        description = "Partition/filesystem label for the EFI System Partition";
      };
      root = lib.mkOption {
        type = lib.types.str;
        description = "Filesystem label for the root partition";
      };
      luks = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Partition label for the LUKS container";
      };
      swap = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Partition/filesystem label for the swap partition";
      };
    };

    luks = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to use LUKS encryption";
      };
      mapperName = lib.mkOption {
        type = lib.types.str;
        default = "cryptroot";
        description = "Device mapper name for the LUKS container";
      };
    };

    swap = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to create a swap partition";
      };
      size = lib.mkOption {
        type = lib.types.str;
        default = "8G";
        description = "Size of the swap partition (sgdisk format, e.g. '8G')";
      };
    };

    extraMountDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Directories to create under /mnt after mounting root";
    };

    extraPostMountCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Shell commands to run after mounting, before cloning";
    };

    repoClonePath = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/nix-config";
      description = "Where to clone the nix-config repo under /mnt";
    };

    repoRemote = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/joshsymonds/nix-config";
      description = "Git remote URL for nix-config";
    };

    extraInitrdKernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra kernel modules to load in initrd";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Extra packages to include in the installer environment";
    };

    extraBootCommands = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra commands for boot.initrd.postDeviceCommands";
    };

    bannerText = lib.mkOption {
      type = lib.types.lines;
      default = "Auto-installer for ${cfg.targetHost}. The system will install automatically on boot.";
      description = "Text shown on the getty help line";
    };

    targetUser = lib.mkOption {
      type = lib.types.str;
      default = "joshsymonds";
      description = "Primary user account on the target system. Used for SSH key deployment and home directory ownership.";
    };

    powerOff = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to power off (true) or reboot (false) after install";
    };

    prebuilt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to embed the full system closure in the ISO (true) or build from the flake on the target (false). Prebuilt ISOs are large but install offline; non-prebuilt ISOs are small but require network.";
    };
  };

  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  config = {
    nixpkgs.config.allowUnfree = true;
    hardware.enableAllFirmware = true;

    nix.settings = {
      experimental-features = "nix-command flakes";
      extra-substituters = [
        "https://nix-community.cachix.org"
        "https://joshsymonds.cachix.org"
        "https://devenv.cachix.org"
        "https://cuda-maintainers.cachix.org"
      ];
      extra-trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "joshsymonds.cachix.org-1:DajO7Bjk/Q8eQVZQZC/AWOzdUst2TGp8fHS/B1pua2c="
        "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
      ];
      trusted-users = ["root"];
    };

    boot.initrd = {
      kernelModules = cfg.extraInitrdKernelModules;
      systemd.services.installer-extra-boot = lib.mkIf (cfg.extraBootCommands != "") {
        description = "Installer extra boot commands";
        wantedBy = ["initrd.target"];
        after = ["systemd-udev-settle.service"];
        before = ["initrd-fs.target"];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = cfg.extraBootCommands;
      };
    };

    services.openssh.enable = true;

    environment.systemPackages =
      [
        util-linux
        jq
        gptfdisk
        e2fsprogs
        dosfstools
      ]
      ++ lib.optionals cfg.luks.enable [pkgs.cryptsetup]
      ++ cfg.extraPackages;

    services.getty.helpLine = cfg.bannerText;

    systemd.services.${serviceName} = {
      description = "Partition disk and install ${cfg.targetHost}";
      wantedBy = ["multi-user.target"];
      after = ["multi-user.target" "network-online.target"];
      wants = ["network-online.target"];
      path =
        [
          util-linux
          jq
          gptfdisk
          e2fsprogs
          dosfstools
          pkgs.coreutils
          pkgs.gawk
          pkgs.mount
          pkgs.systemd
          pkgs.gitMinimal
          pkgs.openssh
        ]
        ++ lib.optionals cfg.luks.enable [pkgs.cryptsetup];
      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
      script = ''
        set -euxo pipefail

        wait_for() {
          local tries=0
          until "$@"; do
            tries=$((tries + 1))
            if [[ $tries -ge 10 ]]; then
              return 1
            fi
            sleep 1
          done
        }

        ${diskDetectionScript}
        ${partitionScript}
        ${postMountScript}
        ${cloneScript}
        ${installScript}
        ${postInstallFixup}
        ${cleanupScript}
      '';
    };
  };
}
