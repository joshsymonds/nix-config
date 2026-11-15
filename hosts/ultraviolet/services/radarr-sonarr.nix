{pkgs, ...}: let
  # Allowed Hosts turns on ASP.NET host filtering: a request whose Host header
  # isn't listed gets a 400. localhost/127.0.0.1/[::1] and the machine's own
  # hostname are always allowed, so the in-host clients (Prowlarr app sync,
  # Bazarr, Recyclarr, media-healthcheck) need nothing here. Listed: the Caddy
  # vhost (Caddy forwards the original Host; Jellyseerr goes through it) and
  # ultraviolet's direct addresses from arr-direct-hosts.nix.
  directHosts = import ./arr-direct-hosts.nix;
in {
  services = {
    sonarr = {
      enable = true;
      package = pkgs.sonarr;
      settings.server.allowedhosts = "sonarr.home.husbuddies.gay,${directHosts}";
    };

    radarr = {
      enable = true;
      package = pkgs.radarr;
      settings.server.allowedhosts = "radarr.home.husbuddies.gay,${directHosts}";
    };

    caddy.virtualHosts = {
      "radarr.home.husbuddies.gay".extraConfig = ''
        reverse_proxy /* localhost:7878
        import cloudflare
      '';
      "sonarr.home.husbuddies.gay".extraConfig = ''
        reverse_proxy /* localhost:8989
        import cloudflare
      '';
    };
  };
}
