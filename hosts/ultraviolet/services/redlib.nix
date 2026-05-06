{
  pkgs,
  config,
  ...
}: let
  port = 8091;
  collectionsEnvFile = "/run/redlib/collections.env";
  collectionsSecret = config.age.secrets."redlib-collections".path;
in {
  services.redlib = {
    enable = true;
    package = pkgs.redlib-veraticus;
    address = "127.0.0.1";
    inherit port;
    settings = {
      REDLIB_DEFAULT_THEME = "catppuccinMocha";
      REDLIB_DEFAULT_LAYOUT = "clean";
      REDLIB_DEFAULT_WIDE = true;
    };
  };

  systemd.services.redlib = {
    path = [pkgs.coreutils pkgs.gnused];
    serviceConfig.EnvironmentFile = ["-${collectionsEnvFile}"];
    restartTriggers = [config.age.secrets."redlib-collections".file];
    preStart = ''
      mkdir -p /run/redlib
      if [ -s ${collectionsSecret} ]; then
        collections=$(${pkgs.gnused}/bin/sed '/^\s*$/d' ${collectionsSecret} | ${pkgs.coreutils}/bin/tr '\n' ';' | ${pkgs.gnused}/bin/sed 's/;*$//')
      else
        collections=""
      fi
      printf 'REDLIB_COLLECTIONS=%s\n' "$collections" > ${collectionsEnvFile}
      chmod 600 ${collectionsEnvFile}
    '';
  };

  # Cloudflare Tunnel handles public exposure (redlib.husbuddies.gay) directly,
  # so no local Caddy vhost is defined here.
}
