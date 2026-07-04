_: {
  systemd.tmpfiles.rules = [
    "d /etc/bazarr/config 0755 1000 1000 -"
  ];

  virtualisation.oci-containers.containers.bazarr = {
    image = "linuxserver/bazarr:1.5.1";
    ports = [
      "6767:6767"
    ];
    volumes = [
      "/etc/bazarr/config:/config"
      "/mnt/video/:/mnt/video"
    ];
    environment = {
      PUID = "1000";
      PGID = "1000";
    };
    autoStart = true;
    extraOptions = [
      "--network=host"
      "--security-opt=no-new-privileges"
    ];
  };

  services.caddy.virtualHosts."bazarr.home.husbuddies.gay".extraConfig = ''
    reverse_proxy /* localhost:6767
    import cloudflare
  '';
}
