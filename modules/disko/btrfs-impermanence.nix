{
  config,
  inputs,
  lib,
  ...
}: let
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
    // lib.optionalAttrs (cfg.swapSizeGiB > 0) {
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
    enable = lib.mkEnableOption "btrfs subvolume layout + impermanence rollback";

    device = lib.mkOption {
      type = lib.types.str;
      example = "/dev/disk/by-id/nvme-...";
      description = "Block device path. Use a /dev/disk/by-id/... path for stability.";
    };

    luks = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "LUKS-encrypt the btrfs partition.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "cryptroot";
        description = "Mapper name for the LUKS device.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.str;
        default = "/tmp/secret.key";
        description = "Path to file containing LUKS password (only read during disko install).";
      };
    };

    swapSizeGiB = lib.mkOption {
      type = lib.types.int;
      default = 32;
      description = "Swap subvolume size in GiB. Set to 0 to disable swap.";
    };

    persistDirectories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/etc/ssh"
        "/etc/age"
        "/var/lib/nixos"
        "/var/lib/systemd"
      ];
      description = "Directories bind-mounted from /persist into the ephemeral root every boot.";
    };

    persistFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/etc/machine-id"
        "/etc/adjtime"
      ];
      description = "Files bind-mounted from /persist into the ephemeral root every boot.";
    };
  };

  config = lib.mkIf cfg.enable {
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
    # Requires a one-time @root-blank snapshot taken manually at install:
    # `btrfs subvolume snapshot -r /mnt/@root /mnt/@root-blank`.
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

    # Persist bind-mounts that the new initrd-init flow can rely on. NixOS
    # unstable runs `activate` inside `chroot /sysroot` BEFORE stage-2,
    # so any activation snippet that reads from a /persist-backed path
    # (agenix decrypt of /etc/age/<host>.agekey, lanzaboote signing keys
    # in /var/lib/sbctl, …) sees an empty target unless the bind-mount
    # was already wired in initrd. Impermanence's own initrd path only
    # covers persistDirectories whose path is in NixOS's static
    # `pathsNeededForBoot` list (/, /etc, /var, /var/lib, /var/lib/nixos,
    # /usr, …) — the rest get mounted only at stage-2, too late for
    # initrd-chroot activation. We add the missing ones here.
    #
    # Why this matters: the original incident was an agenix snippet for
    # atticd-push-token failing because /etc/age wasn't bound in initrd,
    # which made `set -e` propagate, which made `activate` exit early,
    # which made switch-root fail with no init in /sysroot. Mounting
    # everything up front prevents the same shape of failure for any
    # future activation step that reads /persist-backed config.
    boot.initrd.systemd.mounts = let
      # Mirror lib/utils.nix's `pathsNeededForBoot` so we don't duplicate
      # impermanence's own initrd mounts. (We can't read it cleanly from
      # _module.args.utils without making this module non-portable.)
      stdNeededForBoot = [
        "/"
        "/usr"
        "/usr/local"
        "/nix"
        "/nix/store"
        "/var"
        "/var/log"
        "/var/lib"
        "/var/lib/nixos"
        "/etc"
      ];
      extras = lib.filter (d: !(builtins.elem d stdNeededForBoot)) cfg.persistDirectories;
    in
      map (dir: {
        wantedBy = ["initrd.target"];
        before = ["initrd-nixos-activation.service"];
        where = "/sysroot${dir}";
        what = "/sysroot/persist${dir}";
        unitConfig.DefaultDependencies = "no";
        type = "none";
        options = "bind";
      })
      extras;
  };
}
