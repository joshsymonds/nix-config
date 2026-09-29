_: {
  systemd.tmpfiles.rules = [
    "d /etc/jellyseerr/config 0644 root root -"
  ];

  virtualisation.oci-containers.containers.jellyseerr = {
    image = "docker.io/fallenbagel/jellyseerr:2.7.3";
    ports = [
      "5055:5055"
    ];
    extraOptions = [
      "--network=host"
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
