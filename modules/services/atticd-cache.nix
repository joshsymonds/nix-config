{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.services.atticd-cache;
in {
  options.services.atticd-cache = {
    enable = mkEnableOption "household atticd binary cache (server)";

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        EnvironmentFile providing ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64.
        Generate with: openssl genrsa -traditional 4096 | base64 -w0
        Format: ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=<that-base64>
        Typically an agenix-decrypted secret.
      '';
    };

    listen = mkOption {
      type = types.str;
      default = "[::]:8081";
      description = "atticd listen address. Default binds all interfaces on 8081 (Tailscale-trusted only via firewall).";
    };

    storagePath = mkOption {
      type = types.str;
      default = "/var/lib/atticd/storage";
      description = "Local cache storage directory.";
    };

    databaseUrl = mkOption {
      type = types.str;
      default = "sqlite:///var/lib/atticd/atticd.db?mode=rwc";
      description = "Database connection URL. SQLite by default; switch to PostgreSQL for higher concurrency.";
    };

    apiEndpoint = mkOption {
      type = types.str;
      example = "http://ultraviolet:8081/";
      description = "Public URL for the cache (used in JWT issuer claims and client config).";
    };

    allowedHosts = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Allowed Host header values. Empty = allow all (suitable for trusted-LAN).";
    };

    consumer = {
      enable = mkEnableOption "use the household atticd as a substituter (pull-only)";

      url = mkOption {
        type = types.str;
        default = "http://ultraviolet:8081/nix-config";
        description = "Cache URL for clients to pull from.";
      };

      publicKey = mkOption {
        type = types.str;
        default = "nix-config:oFasWpcTwQxVGCxSBTLw8gGNZNjhRLZsnWnZQIyU4HY=";
        description = "Cache signing public key (from `attic cache info`). Public keys are not secret.";
      };
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.environmentFile != null;
          message = "services.atticd-cache.environmentFile must be set when atticd-cache is enabled.";
        }
      ];

      services.atticd = {
        enable = true;
        environmentFile = cfg.environmentFile;
        settings = {
          listen = cfg.listen;
          api-endpoint = cfg.apiEndpoint;
          allowed-hosts = cfg.allowedHosts;
          database.url = cfg.databaseUrl;
          storage = {
            type = "local";
            path = cfg.storagePath;
          };
        };
      };
    })

    (mkIf cfg.consumer.enable {
      nix.settings.extra-substituters = [cfg.consumer.url];
      nix.settings.extra-trusted-public-keys = [cfg.consumer.publicKey];
    })
  ];
}
