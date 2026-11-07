# ultraviolet composition of services.qbittorrent-vpn.
#
# qBittorrent joins the host's VPN exit (vpn-exit.nix), next to SABnzbd.
# Mullvad has no port forwarding, so torrents are outbound-only.
#
# Downloads land on the NAS at the paths the importers see, by category:
# tv and movies under /mnt/video/torrents (hardlinked into /mnt/video/tv
# and /mnt/video/movies by Sonarr/Radarr), games under /mnt/games/torrents
# (hardlinked into the library by Questarr). Hardlinks can't cross NFS
# mounts, which is why games get their own tree on the games share.
# Categories, seeding limits (ratio 1.0 / 7 days) and the WebUI password
# live in qBittorrent's own config under /var/lib/qbittorrent.
{
  imports = [
    ../../modules/services/qbittorrent-vpn.nix
  ];

  services.qbittorrent-vpn = {
    enable = true;
    # SABnzbd holds 8080 inside the shared netns.
    webUIPort = 8090;
    webUIAddress = "127.0.0.1";
    timezone = "America/Los_Angeles";
    extraVolumes = [
      "/mnt/video/torrents:/mnt/video/torrents"
      "/mnt/games/torrents:/mnt/games/torrents"
    ];
  };

  # Without this a container started before the NAS is reachable binds the
  # bare local directories and fills the root disk.
  systemd.services.podman-qbittorrent.unitConfig.RequiresMountsFor = [
    "/mnt/video/torrents"
    "/mnt/games/torrents"
  ];

  services.caddy.virtualHosts."qbittorrent.home.husbuddies.gay".extraConfig = ''
    reverse_proxy /* localhost:8090
    import cloudflare
  '';
}
