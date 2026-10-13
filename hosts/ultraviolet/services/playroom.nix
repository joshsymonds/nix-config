# The nephews' games (~/Personal/playroom on vermissian), deployed there with `just deploy`, which
# rsyncs the static build into /var/lib/playroom/games. The Cloudflare tunnel routes
# playroom.husbuddies.gay to this loopback-only port. The games are served only under a secret path
# that Caddy reads from PLAYROOM_PATH in its environment; the value lives in the playroom-path agenix
# secret, which the caddy unit loads as an EnvironmentFile. The slashless form redirects to the
# slashed one; everything else 404s, and nothing asks to be indexed.
{config, ...}: {
  age.secrets."playroom-path" = {
    file = ../../../secrets/hosts/ultraviolet/playroom-path.age;
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile = [
    config.age.secrets."playroom-path".path
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/playroom 0755 joshsymonds users -"
    "d /var/lib/playroom/games 0755 joshsymonds users -"
  ];

  services.caddy.virtualHosts.":8097".extraConfig = ''
    bind 127.0.0.1
    header X-Robots-Tag "noindex, nofollow, noarchive"

    handle /robots.txt {
      respond "User-agent: *
    Disallow: /
    " 200
    }

    redir /{$PLAYROOM_PATH} /{$PLAYROOM_PATH}/ 308

    handle_path /{$PLAYROOM_PATH}/* {
      root * /var/lib/playroom/games
      @hashed path /assets/*
      header @hashed Cache-Control "public, max-age=31536000, immutable"
      header ?Cache-Control "no-cache"
      file_server
    }

    handle {
      respond 404
    }
  '';
}
