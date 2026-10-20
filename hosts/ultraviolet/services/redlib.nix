{
  pkgs,
  config,
  ...
}: let
  port = 8091;
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
      REDLIB_HOME_FROM_COLLECTIONS = "on";
    };
  };

  systemd.services = {
    # The redlib-collections secret is an env file (KEY=VALUE per line) holding
    # REDLIB_COLLECTIONS and any other settings we don't want surfaced in this
    # public repo — e.g. REDLIB_HOME_EXCLUDED_COLLECTIONS. agenix decrypts it
    # to a root-owned 0400 path; systemd reads it before dropping to DynamicUser.
    #
    # Reddit traffic leaves from the home IP. It went through gluetun's shared
    # Mullvad exit for a while after a bulk audit got the home IP 403-blocked
    # on 2026-09-16, but other users on a shared exit trip Reddit's IP-level
    # 403s for everyone on it; one redlib's browsing volume from a residential
    # IP does not.
    redlib = {
      serviceConfig = {
        EnvironmentFile = config.age.secrets."redlib-collections".path;
        # redlib exits after ~90s if it can't mint an OAuth token (e.g. the
        # network is still coming up after a power loss); keep retrying.
        Restart = "on-failure";
        RestartSec = "10s";
      };
      restartTriggers = [config.age.secrets."redlib-collections".file];
    };
  };

  # Cloudflare Tunnel handles public exposure (redlib.husbuddies.gay) directly,
  # so no local Caddy vhost is defined here.
}
