{
  config,
  inputs,
  lib,
  ...
}:
with lib; let
  cfg = config.btrfs-impermanence;

  # btrfs subvolumes: @root is ephemeral (rolled back to @root-blank each boot).
  # @home/@nix/@persist/@log/@swap are persistent.
  rootSubvolumes =
    {
      "@root" = {
        mountpoint = "/";
        mountOptions = ["compress=zstd:3" "noatime"];
      };
      "@home" = {
        mountpoint = "/home";
        mountOptions = ["compress=zstd:3" "noatime"];
      };
      "@nix" = {
        mountpoint = "/nix";
        mountOptions = ["compress=zstd:3" "noatime"];
      };
      "@persist" = {
        mountpoint = "/persist";
        mountOptions = ["compress=zstd:3" "noatime"];
      };
      "@log" = {
        mountpoint = "/var/log";
        mountOptions = ["compress=zstd:3" "noatime"];
      };
    }
    // optionalAttrs (cfg.swapSizeGiB > 0) {
      "@swap" = {
        mountpoint = "/.swapvol";
        swap.swapfile.size = "${toString cfg.swapSizeGiB}G";
      };
    };

  btrfsContent = {
    type = "btrfs";
    extraArgs = ["-L" "nixos" "-f"];
    subvolumes = rootSubvolumes;
  };
in {
  imports = [
    inputs.disko.nixosModules.disko
    inputs.impermanence.nixosModules.impermanence
  ];

  options.btrfs-impermanence = {
    enable = mkEnableOption "btrfs subvolume layout + impermanence rollback";

    device = mkOption {
      type = types.str;
      example = "/dev/disk/by-id/nvme-...";
      description = "Block device path. Use a /dev/disk/by-id/... path for stability.";
    };

    luks = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "LUKS-encrypt the btrfs partition.";
      };
      name = mkOption {
        type = types.str;
        default = "cryptroot";
        description = "Mapper name for the LUKS device.";
      };
      passwordFile = mkOption {
        type = types.str;
        default = "/tmp/secret.key";
        description = "Path to file containing LUKS password (only read during disko install).";
      };
    };

    swapSizeGiB = mkOption {
      type = types.int;
      default = 32;
      description = "Swap subvolume size in GiB. Set to 0 to disable swap.";
    };

    persistDirectories = mkOption {
      type = types.listOf types.str;
      default = [
        "/etc/ssh"
        "/etc/age"
        "/var/lib/nixos"
        "/var/lib/systemd"
      ];
      description = "Directories bind-mounted from /persist into the ephemeral root every boot.";
    };

    persistFiles = mkOption {
      type = types.listOf types.str;
      default = [
        "/etc/machine-id"
        "/etc/adjtime"
      ];
      description = "Files bind-mounted from /persist into the ephemeral root every boot.";
    };
  };

  config = mkIf cfg.enable {
    disko.devices.disk.main = {
      type = "disk";
      device = cfg.device;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = ["umask=0077"];
            };
          };
          root = {
            size = "100%";
            content =
              if cfg.luks.enable
              then {
                type = "luks";
                name = cfg.luks.name;
                passwordFile = cfg.luks.passwordFile;
                settings.allowDiscards = true;
                content = btrfsContent;
              }
              else btrfsContent;
          };
        };
      };
    };

    # Rollback @root to @root-blank in initrd, before sysroot.mount.
    # Requires a one-time @root-blank snapshot, taken at install via the
    # postInstall hook below (or manually: `btrfs subvolume snapshot -r
    # /mnt/@root /mnt/@root-blank`).
    boot.initrd.systemd.enable = true;
    boot.initrd.systemd.services.rollback-root = {
      description = "Roll @root back to @root-blank";
      wantedBy = ["initrd.target"];
      after = lib.optional cfg.luks.enable "systemd-cryptsetup@${cfg.luks.name}.service";
      before = ["sysroot.mount"];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = let
        device =
          if cfg.luks.enable
          then "/dev/mapper/${cfg.luks.name}"
          else "/dev/disk/by-label/nixos";
      in ''
        mkdir -p /mnt
        mount -o subvol=/ ${device} /mnt
        btrfs subvolume list -o /mnt/@root | cut -f9 -d' ' | while read sv; do
          btrfs subvolume delete "/mnt/$sv"
        done
        btrfs subvolume delete /mnt/@root
        btrfs subvolume snapshot /mnt/@root-blank /mnt/@root
        umount /mnt
      '';
    };

    # Bind-mounts from /persist into the ephemeral root.
    environment.persistence."/persist" = {
      hideMounts = true;
      directories = cfg.persistDirectories;
      files = cfg.persistFiles;
    };

    # /persist needs to exist as a mountpoint root before bind-mounts run.
    fileSystems."/persist".neededForBoot = true;
  };
}
