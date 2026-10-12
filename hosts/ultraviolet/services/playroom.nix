# The nephews' games (~/Personal/playroom on vermissian), deployed there with `just deploy`, which
# rsyncs the static build into /var/lib/playroom/games. The Cloudflare tunnel routes
# playroom.husbuddies.gay to this loopback-only port. Only /games/ is served; everything else 404s,
# and nothing asks to be indexed.
{...}: {
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

    handle /games* {
      root * /var/lib/playroom
      @hashed path /games/assets/*
      header @hashed Cache-Control "public, max-age=31536000, immutable"
      header ?Cache-Control "no-cache"
      file_server
    }

    handle {
      respond 404
    }
  '';
}
