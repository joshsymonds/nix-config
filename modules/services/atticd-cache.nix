{
  config,
  lib,
  pkgs,
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

    gcInterval = lib.mkOption {
      type = lib.types.str;
      default = "12 hours";
      description = "How often atticd runs garbage collection. Accepts expressions like \"12 hours\", \"1 day\".";
    };

    gcRetentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "14 days";
      description = ''
        Default retention period applied to caches without their own setting.
        Entries last accessed/created longer ago than this are deleted on the next GC run.
        Set to "0" to retain forever.
      '';
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

    publisher = {
      # Independent of `enable` and `consumer.enable`. A host can publish without being a server
      # or substituter, though typical use is publisher + consumer together.
      enable = lib.mkEnableOption "push successful nix builds to the household atticd";

      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the atticd push token (single line, no trailing newline).
          Typically wired to `config.age.secrets."atticd-push-token".path`.
          The token must be scoped (atticadm) to push+pull on the target cache only — never
          an admin token, since this file lives on multiple machines.
        '';
      };

      cacheUrl = lib.mkOption {
        type = lib.types.str;
        default = cfg.consumer.url;
        defaultText = lib.literalExpression "config.services.atticd-cache.consumer.url";
        description = ''
          Push target URL. Defaults to the consumer URL so most hosts need no override.
          The cache server itself should override this to a loopback URL
          (e.g. http://localhost:8081/nix-config) to avoid round-tripping through DNS/Tailscale
          on self-pushes.
        '';
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
          garbage-collection = {
            interval = cfg.gcInterval;
            default-retention-period = cfg.gcRetentionPeriod;
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

    (lib.mkIf cfg.publisher.enable (let
      # cacheUrl is "http://host:port/cachename"; split into endpoint + cache.
      cacheName = lib.last (lib.splitString "/" cfg.publisher.cacheUrl);
      endpoint = lib.removeSuffix "/${cacheName}" cfg.publisher.cacheUrl;

      hookScript = pkgs.writeShellScript "upload-to-attic" ''
        set -eu

        # nix invokes the hook even when no outputs were produced (e.g. fixed-output failures).
        [ -n "''${OUT_PATHS:-}" ] || exit 0

        if [ ! -r ${lib.escapeShellArg cfg.publisher.tokenFile} ]; then
          echo "atticd-push: token file unreadable: ${cfg.publisher.tokenFile}" >&2
          exit 1
        fi

        # Detach into a transient unit. The unit owns the token-bearing
        # config dir and cleans it up on its own exit, avoiding a race
        # with this hook script returning before the upload starts.
        # Failures land in `journalctl -u 'attic-push-*'`.
        # $OUT_PATHS is intentionally word-split inside the inner shell.
        # RuntimeMaxSec caps the unit so a worker hung on DB contention
        # (or any other reason) can't sit forever holding a token-bearing
        # tmpdir; SIGTERM at the cap fires bash's EXIT trap → cleanup.
        exec ${pkgs.systemd}/bin/systemd-run \
          --no-block --collect \
          --unit="attic-push-$$" \
          --property=RuntimeMaxSec=300 \
          --setenv=ATTIC_TOKEN_FILE=${lib.escapeShellArg cfg.publisher.tokenFile} \
          --setenv=ATTIC_ENDPOINT=${lib.escapeShellArg endpoint} \
          --setenv=ATTIC_CACHE_NAME=${lib.escapeShellArg cacheName} \
          --setenv=ATTIC_OUT_PATHS="$OUT_PATHS" \
          ${pkgs.bash}/bin/bash -c '
            set -eu
            export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin

            # Skip paths the cache already has via the public narinfo endpoint —
            # avoids spawning attic-client (each instance ~500MB-2GB RSS while
            # walking closures) for paths that would no-op anyway. Falls through
            # on any curl failure (network, non-200) so a degraded check can
            # never silently drop pushes.
            TO_PUSH=""
            for p in $ATTIC_OUT_PATHS; do
              HASH=$(basename "$p" | cut -d- -f1)
              if curl -sfo /dev/null --max-time 5 \
                "$ATTIC_ENDPOINT/$ATTIC_CACHE_NAME/$HASH.narinfo"; then
                continue
              fi
              TO_PUSH="$TO_PUSH $p"
            done
            [ -n "$TO_PUSH" ] || exit 0

            CFG=$(mktemp -d -p /run attic-push-XXXXXX)
            trap "rm -rf $CFG" EXIT
            mkdir -p "$CFG/attic"
            {
              echo "default-server = \"h\""
              echo "[servers.h]"
              echo "endpoint = \"$ATTIC_ENDPOINT\""
              echo "token = \"$(cat $ATTIC_TOKEN_FILE)\""
            } > "$CFG/attic/config.toml"
            chmod 0400 "$CFG/attic/config.toml"
            # --no-closure: every locally-built path fires its own hook, so
            # walking the closure here is pure redundant work and the source
            # of the per-process memory blow-up.
            XDG_CONFIG_HOME="$CFG" \
              ${pkgs.attic-client}/bin/attic push --no-closure \
                "h:$ATTIC_CACHE_NAME" $TO_PUSH
          '
      '';
    in {
      environment.systemPackages = [pkgs.attic-client];
      nix.settings.post-build-hook = "${hookScript}";
    }))
  ];
}
