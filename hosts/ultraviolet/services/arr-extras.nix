_: {
  services = {
    prowlarr = {
      enable = true;
    };

    caddy.virtualHosts = {
      "prowlarr.home.husbuddies.gay".extraConfig = ''
        reverse_proxy /* localhost:9696
        import cloudflare
      '';
    };
  };
}
