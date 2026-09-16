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

  # The redlib-collections secret is an env file (KEY=VALUE per line) holding
  # REDLIB_COLLECTIONS and any other settings we don't want surfaced in this
  # public repo — e.g. REDLIB_HOME_EXCLUDED_COLLECTIONS. agenix decrypts it
  # to a root-owned 0400 path; systemd reads it before dropping to DynamicUser.
  systemd.services.redlib = {
    serviceConfig.EnvironmentFile = config.age.secrets."redlib-collections".path;
    restartTriggers = [config.age.secrets."redlib-collections".file];

    # Reddit 403-blocked this host's home IP on 2026-09-16 after redlib's
    # OAuth token rollover looked like abuse (the morning-room audit pushed
    # ~1200 requests through it in minutes). Send Reddit traffic out through
    # gluetun's HTTP proxy (sabnzbd-vpn.nix, Mullvad exit) instead. redlib's
    # wreq client honours HTTPS_PROXY; only reddit.com is ever contacted.
    environment.HTTPS_PROXY = "http://127.0.0.1:8888";
    after = ["podman-gluetun.service"];
  };

  # Cloudflare Tunnel handles public exposure (redlib.husbuddies.gay) directly,
  # so no local Caddy vhost is defined here.
}
