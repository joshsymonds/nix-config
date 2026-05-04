{
  pkgs,
  config,
  ...
}: {
  systemd.services.caddy.serviceConfig.EnvironmentFile = config.age.secrets."cloudflare-api-token".path;

  services.caddy = {
    acmeCA = null;
    enable = true;
    package = pkgs.myCaddy.overrideAttrs (old: {
      meta = old.meta // {mainProgram = "caddy";};
    });
    globalConfig = ''
      storage file_system {
        root /var/lib/caddy
      }
    '';
    extraConfig = ''
      (cloudflare) {
        tls {
          dns cloudflare {env.CF_API_TOKEN}
          resolvers 1.1.1.1
        }
      }
    '';
    virtualHosts = {};
  };
}
