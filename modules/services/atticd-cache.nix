{
  config,
  lib,
  ...
}: let
  cfg = config.services.atticd-cache;
in {
  options.services.atticd-cache = {
    enable = lib.mkEnableOption "household atticd binary cache (server)";

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        EnvironmentFile providing ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64.
        Generate with: openssl genrsa -traditional 4096 | base64 -w0
        Format: ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=<that-base64>
        Typically an agenix-decrypted secret.
      '';
    };

    listen = lib.mkOption {
      type = lib.types.str;
      default = "[::]:8081";
      description = "atticd listen address. Default binds all interfaces on 8081 (Tailscale-trusted only via firewall).";
    };

    storagePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/atticd/storage";
      description = "Local cache storage directory.";
    };

    databaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "sqlite:///var/lib/atticd/atticd.db?mode=rwc";
      description = "Database connection URL. SQLite by default; switch to PostgreSQL for higher concurrency.";
    };

    apiEndpoint = lib.mkOption {
      type = lib.types.str;
      example = "http://ultraviolet:8081/";
      description = "Public URL for the cache (used in JWT issuer claims and client config).";
    };

    allowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        config.networking.hostName
        "${config.networking.hostName}:8081"
      ];
      description = "Allowed Host header values. Defaults to the host's own name; widen for multi-name access.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the atticd listen port (8081) in the firewall.";
    };

    consumer = {
      # Enabling this adds the cache's public key to nix.settings.extra-trusted-public-keys
      # globally. That key can then sign ANY store path the daemon will accept — standard
      # Nix substituter trust, but worth noting since the signing key lives on a single host.
      enable = lib.mkEnableOption "use the household atticd as a substituter (pull-only)";

      url = lib.mkOption {
        type = lib.types.str;
        default = "http://ultraviolet:8081/nix-config";
        description = "Cache URL for clients to pull from.";
      };

      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "nix-config:oFasWpcTwQxVGCxSBTLw8gGNZNjhRLZsnWnZQIyU4HY=";
        description = "Cache signing public key (from `attic cache info`). Public keys are not secret.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
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

      # Raise FD limit for parallel NAR fetches from multiple consumers.
      systemd.services.atticd.serviceConfig = {
        LimitNOFILE = 65536;
        TimeoutStartSec = "30s";
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [8081];
    })

    (lib.mkIf cfg.consumer.enable {
      nix.settings.extra-substituters = [cfg.consumer.url];
      nix.settings.extra-trusted-public-keys = [cfg.consumer.publicKey];
    })
  ];
}
