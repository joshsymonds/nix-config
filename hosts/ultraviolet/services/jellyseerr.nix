_: {
  # Seerr (the merged Jellyseerr/Overseerr successor) runs as the image's
  # `node` user (UID 1000), so the config tree must be owned by it.
  systemd.tmpfiles.rules = [
    "d /etc/jellyseerr/config 0755 1000 1000 -"
    "Z /etc/jellyseerr/config - 1000 1000 -"
  ];

  virtualisation.oci-containers.containers.jellyseerr = {
    image = "ghcr.io/seerr-team/seerr:v3.5.0";
    ports = [
      "5055:5055"
    ];
    extraOptions = [
      "--network=host"
      "--init"
      "--cpu-shares=1024"
      "--memory=2g"
      "--security-opt=no-new-privileges"
    ];
    volumes = [
      "/etc/jellyseerr/config:/app/config"
    ];
  };

  services.caddy.virtualHosts."jellyseerr.home.husbuddies.gay".extraConfig = ''
    reverse_proxy /* localhost:5055
    import cloudflare
  '';
}
