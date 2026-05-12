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

    # /etc/ssh is NOT a directory-bind — that whole-dir bind hides
    # NixOS-generated sshd_config + authorized_keys.d/<user>. We persist
    # only the host keys via persistFiles below; everything else in
    # /etc/ssh stays NixOS-managed (regenerated each boot from declarative
    # config). /var/lib/sbctl persisted so lanzaboote's signing keys
    # survive @root-blank rollback (without this, every nh os switch
    # fails with "Failed to read public key from /var/lib/sbctl/keys/db/db.pem").
    persistDirectories = [
      "/etc/age"
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/bluetooth"
      "/var/lib/upower"
      "/var/lib/colord"
      "/var/lib/sbctl"
      "/var/lib/tailscale"
      # nix-flatpak installs system Flatpaks here. Without persistence,
      # @root-blank rollback wipes the OSTree repo + state file every boot
      # and the activation re-downloads runtimes (~500 MB+) every time.
      # Per-user state (~/.var/app/...) lives on @home and survives natively.
      "/var/lib/flatpak"
      # services.qbittorrent-vpn — listed unconditionally because empty
      # dirs in /persist cost nothing while the service is disabled. When
      # enabled, gluetun caches server lists here and qbittorrent stores
      # torrent state + resume data + the WebUI password under /config.
      # Downloads themselves land in ~/Downloads/torrents (on @home,
      # persistent natively).
      "/var/lib/gluetun"
      "/var/lib/qbittorrent"
    ];

    persistFiles = [
      "/etc/machine-id"
      "/etc/adjtime"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
  };
}
