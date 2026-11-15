_: {
  services = {
    prowlarr = {
      enable = true;
      # Host filtering; see the Allowed Hosts note in radarr-sonarr.nix.
      # Sonarr, Radarr and Questarr reach Prowlarr on localhost, which is
      # always allowed.
      settings.server.allowedhosts = "prowlarr.home.husbuddies.gay,${import ./arr-direct-hosts.nix}";
    };

    caddy.virtualHosts = {
      "prowlarr.home.husbuddies.gay".extraConfig = ''
        reverse_proxy /* localhost:9696
        import cloudflare
      '';
    };
  };
}
