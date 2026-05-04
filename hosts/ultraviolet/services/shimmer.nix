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
}
