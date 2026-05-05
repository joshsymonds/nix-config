# gnomon disk layout — single 2TB NVMe, LUKS-encrypted btrfs with impermanence.
#
# The `device` path is a sentinel that bootstrap.sh substitutes at install time
# by reading the kit's manifest.env (which the prep step records based on what
# `lsblk` reveals on the target). Until then, this file evaluates as a plain
# string — flake check is happy, disko is not run at eval time.
{...}: {
  imports = [
    ../../modules/disko/btrfs-impermanence.nix
  ];

  btrfs-impermanence = {
    enable = true;
    device = "/dev/disk/by-id/REPLACE-AT-INSTALL";
    luks.enable = true;
    swapSizeGiB = 32;

    # Defaults from the module: /etc/ssh, /etc/age, /var/lib/nixos, /var/lib/systemd.
    # Adding desktop-service state so paired devices, color profiles, and power
    # history survive impermanence rollback.
    persistDirectories = [
      "/etc/ssh"
      "/etc/age"
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/bluetooth"
      "/var/lib/upower"
      "/var/lib/colord"
    ];

    # Defaults from the module: /etc/machine-id, /etc/adjtime.
    persistFiles = [
      "/etc/machine-id"
      "/etc/adjtime"
    ];
  };
}
