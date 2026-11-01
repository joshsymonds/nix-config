_: {
  # Questarr: *arr-style video game manager (IGDB discovery, Prowlarr
  # indexers, SABnzbd downloads). SQLite + config live in /app/data; the
  # entrypoint chowns it to PUID/PGID (1000) before dropping root.
  systemd.tmpfiles.rules = [
    "d /var/lib/questarr 0755 1000 1000 -"
  ];

  virtualisation.oci-containers.containers.questarr = {
    image = "ghcr.io/doezer/questarr:v1.5.0";
    environment = {
      # Host network so it reaches Prowlarr and SABnzbd on localhost, but
      # bound to loopback so only Caddy exposes it.
      HOST = "127.0.0.1";
      PORT = "5000";
      TRUST_PROXY = "1";
      APP_URL = "https://questarr.home.husbuddies.gay";
    };
    volumes = [
      "/var/lib/questarr:/app/data"
      # Same path SABnzbd reports for completed downloads, so no path mapping.
      "/mnt/video/:/mnt/video"
    ];
    extraOptions = [
      "--network=host"
      "--security-opt=no-new-privileges"
      "--memory=2g"
    ];
  };

  systemd.services.podman-questarr = {
    after = ["remote-mounts.service"];
    requires = ["remote-mounts.service"];
  };

  services.caddy.virtualHosts."questarr.home.husbuddies.gay".extraConfig = ''
    reverse_proxy /* localhost:5000
    import cloudflare
  '';
}
