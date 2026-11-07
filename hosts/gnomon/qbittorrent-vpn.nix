# gnomon composition of services.qbittorrent-vpn. qBittorrent joins the
# host's VPN exit (vpn-exit.nix), so its traffic and DNS leave through
# Mullvad behind gluetun's killswitch.
{
  imports = [
    ../../modules/services/qbittorrent-vpn.nix
  ];

  services.qbittorrent-vpn = {
    enable = true;

    timezone = "America/Los_Angeles";

    # Downloads land in the user's home so files are immediately usable
    # without juggling /var/lib ownership. @home is persistent on
    # gnomon's btrfs-impermanence layout, so this survives @root rollback
    # natively (no /persist bind-mount needed).
    downloadsDir = "/home/joshsymonds/Downloads/torrents";
  };
}
