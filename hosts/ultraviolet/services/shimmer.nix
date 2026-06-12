{
  pkgs,
  config,
  ...
}: {
  # Declare the secrets
  age.secrets."shimmer-access-client-id" = {
    file = ../../../secrets/hosts/ultraviolet/shimmer-access-client-id.age;
    owner = "shimmer";
    group = "shimmer";
    mode = "0400";
  };

  age.secrets."shimmer-access-client-secret" = {
    file = ../../../secrets/hosts/ultraviolet/shimmer-access-client-secret.age;
    owner = "shimmer";
    group = "shimmer";
    mode = "0400";
  };

  age.secrets."shimmer-jwt-secret" = {
    file = ../../../secrets/hosts/ultraviolet/shimmer-jwt-secret.age;
    owner = "shimmer";
    group = "shimmer";
    mode = "0400";
  };

  age.secrets."shimmer-env" = {
    file = ../../../secrets/hosts/ultraviolet/shimmer-env.age;
    owner = "shimmer";
    group = "shimmer";
    mode = "0400";
  };

  # Create dedicated user (needed for secret ownership)
  users.users.shimmer = {
    isSystemUser = true;
    group = "shimmer";
  };
  users.groups.shimmer = {};

  # Runs on port 8000 - HTTP transport with OAuth
  systemd.services.shimmer = {
    description = "Shimmer MCP Server - Reddit, Monarch Money, GitHub";
    after = ["network.target" "redlib.service"];
    wants = ["redlib.service"];
    wantedBy = ["multi-user.target"];

    environment = {
      REDLIB_URL = "http://localhost:8091";
      ACCESS_CONFIG_URL = "https://husbuddies.cloudflareaccess.com/cdn-cgi/access/sso/oidc/69b35faf843d61c236a30432a87293c3e37f6daeaa8e2f9c3bfc8f6ceb337e24/.well-known/openid-configuration";
      MCP_SERVER_URL = "https://shimmer.husbuddies.gay";
      MCP_SERVER_HOST = "127.0.0.1";
      MCP_SERVER_PORT = "8000";
    };

    restartTriggers = [
      config.age.secrets."shimmer-env".file
      config.age.secrets."shimmer-access-client-id".file
      config.age.secrets."shimmer-access-client-secret".file
      config.age.secrets."shimmer-jwt-secret".file
    ];

    serviceConfig = {
      Type = "simple";
      User = "shimmer";
      Group = "shimmer";
      Restart = "always";
      RestartSec = "5s";

      # Load secrets as credentials
      LoadCredential = [
        "access-client-id:${config.age.secrets."shimmer-access-client-id".path}"
        "access-client-secret:${config.age.secrets."shimmer-access-client-secret".path}"
        "jwt-secret:${config.age.secrets."shimmer-jwt-secret".path}"
      ];

      # Environment file with MONARCH_EMAIL, MONARCH_PASSWORD, GITHUB_TOKEN
      EnvironmentFile = config.age.secrets."shimmer-env".path;

      # State directory for OAuth token storage
      StateDirectory = "shimmer";

      # Security hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };

    # Load secrets and run the HTTP server with OAuth
    script = ''
      export ACCESS_CLIENT_ID=$(cat $CREDENTIALS_DIRECTORY/access-client-id)
      export ACCESS_CLIENT_SECRET=$(cat $CREDENTIALS_DIRECTORY/access-client-secret)
      export MCP_JWT_SECRET=$(cat $CREDENTIALS_DIRECTORY/jwt-secret)
      export HOME=/var/lib/shimmer
      exec ${pkgs.shimmer}/bin/shimmer-server
    '';
  };

  # Second, independent ingress for the tailnet (Claude Code / Bedrock).
  # Auth is the tailscale-serve-injected Tailscale-User-Login header checked
  # against SHIMMER_TAILNET_ALLOWLIST. Bound to localhost only so the header
  # is reachable solely via `tailscale serve` (un-spoofable). Separate
  # failure domain from the OIDC `shimmer` service above.
  systemd.services.shimmer-tailnet = {
    description = "Shimmer MCP Server - tailnet ingress (Tailscale identity auth)";
    after = ["network.target" "redlib.service"];
    wants = ["redlib.service"];
    wantedBy = ["multi-user.target"];

    environment = {
      REDLIB_URL = "http://localhost:8091";
      MCP_SERVER_HOST = "127.0.0.1";
      MCP_TAILNET_PORT = "8001";
      SHIMMER_TAILNET_ALLOWLIST = "josh@joshsymonds.com";
    };

    restartTriggers = [
      config.age.secrets."shimmer-env".file
    ];

    serviceConfig = {
      Type = "simple";
      User = "shimmer";
      Group = "shimmer";
      Restart = "always";
      RestartSec = "5s";

      # Upstream service creds (MONARCH_*, GITHUB_TOKEN, etc.). No ACCESS_*.
      EnvironmentFile = config.age.secrets."shimmer-env".path;

      StateDirectory = "shimmer-tailnet";

      # Security hardening
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };

    script = ''
      export HOME=/var/lib/shimmer-tailnet
      exec ${pkgs.shimmer}/bin/shimmer-tailnet-server
    '';
  };

  # Idempotently front the tailnet service with `tailscale serve` ->
  # 127.0.0.1:8001. HTTPS on port 8443 (NOT 443: Caddy binds *:443 on all
  # interfaces, including the tailscale IP, which would shadow serve's
  # listener). NEVER `tailscale funnel` (that would expose it publicly).
  # Re-running serve with the same target is idempotent.
  systemd.services.shimmer-tailnet-serve = {
    description = "Tailscale serve front for shimmer-tailnet";
    after = ["tailscaled.service" "shimmer-tailnet.service"];
    requires = ["tailscaled.service" "shimmer-tailnet.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    # Wait for the local listener before applying serve config so the unit
    # doesn't race shimmer-tailnet's startup. `serve reset` first so the
    # config is idempotent across port/target changes (a prior mapping on a
    # different port would otherwise linger). The reset wipes EVERY serve
    # mapping on the node — other consumers (mentat-tailnet-serve) must be
    # partOf this unit so they re-run after it and re-add theirs.
    script = ''
      for i in $(seq 1 30); do
        if ${pkgs.iproute2}/bin/ss -ltn 2>/dev/null | grep -q '127.0.0.1:8001'; then
          break
        fi
        sleep 1
      done
      ${pkgs.tailscale}/bin/tailscale serve reset
      exec ${pkgs.tailscale}/bin/tailscale serve --bg --https=8443 8001
    '';
  };
}
