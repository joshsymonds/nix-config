# Inbox Zero (https://github.com/elie222/inbox-zero) — self-hosted on ultraviolet.
#
# Tiers built so far:
#   - three agenix secrets (env, db-password, pubsub-key)
#   - a dedicated Podman network "inbox-zero" so containers reach each other by name
#   - a containerized Postgres (scram-sha-256 enforced)
#   - Redis with AOF persistence
#   - the Upstash REST shim that the app talks to instead of raw Redis
#   - the web container (Next.js) bound to 127.0.0.1:3000
#   - the worker container (BullMQ consumer)
#
# All non-web containers stay on the inbox-zero Podman network with no host-port
# exposure; only the web container publishes a port (127.0.0.1:3000), reached publicly
# via Cloudflare Tunnel (configured out-of-band in the CF dashboard). The six cron
# timers and the real OAuth/LLM/Pub/Sub credentials come in later tasks. The system
# Postgres on this host is intentionally left untouched.
{
  pkgs,
  config,
  ...
}: {
  age.secrets."inbox-zero-env" = {
    file = ../../../secrets/hosts/ultraviolet/inbox-zero-env.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  age.secrets."inbox-zero-db-password" = {
    file = ../../../secrets/hosts/ultraviolet/inbox-zero-db-password.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  age.secrets."inbox-zero-pubsub-key" = {
    file = ../../../secrets/hosts/ultraviolet/inbox-zero-pubsub-key.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # The /var/lib/inbox-zero parent stays root-managed; the per-service subdirs use
  # `- - -` so tmpfiles creates them once and never re-asserts ownership/mode.
  # (With explicit `0700 root root`, systemd-tmpfiles-resetup overwrites the
  # container's runtime uid on every nixos-rebuild and breaks the data dir.)
  systemd.tmpfiles.rules = [
    "d /var/lib/inbox-zero 0700 root root -"
    "d /var/lib/inbox-zero/postgres - - - -"
    "d /var/lib/inbox-zero/redis - - - -"
  ];

  systemd.services.inbox-zero-podman-network = {
    description = "Create Podman network for inbox-zero containers";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["podman-inbox-zero-postgres.service"];
    before = ["podman-inbox-zero-postgres.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "inbox-zero-podman-network" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail
        if ! ${pkgs.podman}/bin/podman network exists inbox-zero; then
          ${pkgs.podman}/bin/podman network create inbox-zero
        fi
      '';
    };
  };

  systemd.services.inbox-zero-postgres-env = {
    description = "Materialize postgres env file from agenix secret for inbox-zero";
    after = ["run-agenix.d.mount"];
    requires = ["run-agenix.d.mount"];
    wantedBy = ["podman-inbox-zero-postgres.service"];
    before = ["podman-inbox-zero-postgres.service"];
    restartTriggers = [config.age.secrets."inbox-zero-db-password".file];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      ExecStart = pkgs.writeShellScript "inbox-zero-postgres-env" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail
        ${pkgs.coreutils}/bin/mkdir -p /run/inbox-zero
        ${pkgs.coreutils}/bin/chmod 0700 /run/inbox-zero
        # shellcheck disable=SC1090
        source ${config.age.secrets."inbox-zero-db-password".path}
        if [ -z "''${INBOX_ZERO_DB_PASSWORD:-}" ]; then
          echo "INBOX_ZERO_DB_PASSWORD missing from agenix secret" >&2
          exit 1
        fi
        umask 0077
        {
          echo "POSTGRES_DB=inbox_zero"
          echo "POSTGRES_USER=inbox_zero"
          ${pkgs.coreutils}/bin/printf 'POSTGRES_PASSWORD=%s\n' "$INBOX_ZERO_DB_PASSWORD"
          # Only takes effect on first initdb (empty data dir); ignored otherwise.
          echo "POSTGRES_HOST_AUTH_METHOD=scram-sha-256"
          echo "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256"
        } > /run/inbox-zero/postgres.env
      '';
    };
  };

  # Runtime env merging: agenix env (AUTH_SECRET, ANTHROPIC_API_KEY, OAuth ids/secrets,
  # SRH_TOKEN, etc.) plus dynamically-assembled DATABASE_URL, UPSTASH_REDIS_*,
  # NEXT_PUBLIC_BASE_URL, AUTH_URL, DEFAULT_LLM_PROVIDER. Consumed by both web and
  # worker containers via environmentFiles.
  systemd.services.inbox-zero-runtime-env = {
    description = "Materialize runtime env file for inbox-zero web and worker";
    after = ["run-agenix.d.mount"];
    requires = ["run-agenix.d.mount"];
    wantedBy = [
      "podman-inbox-zero-web.service"
      "podman-inbox-zero-worker.service"
    ];
    before = [
      "podman-inbox-zero-web.service"
      "podman-inbox-zero-worker.service"
    ];
    restartTriggers = [
      config.age.secrets."inbox-zero-env".file
      config.age.secrets."inbox-zero-db-password".file
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      ExecStart = pkgs.writeShellScript "inbox-zero-runtime-env" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail
        ${pkgs.coreutils}/bin/mkdir -p /run/inbox-zero
        ${pkgs.coreutils}/bin/chmod 0700 /run/inbox-zero

        ENV_FILE=${config.age.secrets."inbox-zero-env".path}
        DB_PW_FILE=${config.age.secrets."inbox-zero-db-password".path}

        # shellcheck disable=SC1090
        source "$DB_PW_FILE"
        if [ -z "''${INBOX_ZERO_DB_PASSWORD:-}" ]; then
          echo "INBOX_ZERO_DB_PASSWORD missing from agenix secret" >&2
          exit 1
        fi
        SRH_TOKEN=$(${pkgs.gnugrep}/bin/grep -E '^SRH_TOKEN=' "$ENV_FILE" | ${pkgs.coreutils}/bin/cut -d= -f2-)
        if [ -z "$SRH_TOKEN" ]; then
          echo "SRH_TOKEN missing from inbox-zero-env" >&2
          exit 1
        fi
        ENCODED_PW=$(${pkgs.jq}/bin/jq -nr --arg p "$INBOX_ZERO_DB_PASSWORD" '$p|@uri')

        umask 0077
        {
          # Pass through everything in the agenix env file as-is.
          ${pkgs.coreutils}/bin/cat "$ENV_FILE"

          # DB connection (Prisma reads DATABASE_URL for the connection pool and
          # DIRECT_URL for migrations; both point at the inbox-zero-postgres container).
          ${pkgs.coreutils}/bin/printf 'DATABASE_URL=postgresql://inbox_zero:%s@inbox-zero-postgres:5432/inbox_zero?schema=public&connection_limit=10\n' "$ENCODED_PW"
          ${pkgs.coreutils}/bin/printf 'DIRECT_URL=postgresql://inbox_zero:%s@inbox-zero-postgres:5432/inbox_zero?schema=public\n' "$ENCODED_PW"

          # Upstash REST shim endpoints (used by the Next.js web app).
          echo "UPSTASH_REDIS_URL=http://inbox-zero-redis-http:80"
          ${pkgs.coreutils}/bin/printf 'UPSTASH_REDIS_TOKEN=%s\n' "$SRH_TOKEN"
          # Inbox Zero accepts the *_REST_* names too; emit both forms so whichever the
          # upstream code reads first works.
          echo "UPSTASH_REDIS_REST_URL=http://inbox-zero-redis-http:80"
          ${pkgs.coreutils}/bin/printf 'UPSTASH_REDIS_REST_TOKEN=%s\n' "$SRH_TOKEN"

          # Direct Redis URL for the BullMQ worker — BullMQ speaks raw Redis pub/sub
          # and cannot use the REST shim. The web container ignores REDIS_URL.
          echo "REDIS_URL=redis://inbox-zero-redis:6379"

          # Public URL — served via Cloudflare Tunnel (CF dashboard route is out-of-band).
          echo "NEXT_PUBLIC_BASE_URL=https://inbox.husbuddies.gay"
          echo "AUTH_URL=https://inbox.husbuddies.gay"

          # LLM provider selection (the agenix env file carries ANTHROPIC_API_KEY).
          echo "DEFAULT_LLM_PROVIDER=anthropic"

          # Container hint so Next.js binds 0.0.0.0 inside the container.
          echo "HOSTNAME=0.0.0.0"
        } > /run/inbox-zero/runtime.env
      '';
    };
  };

  systemd.services.inbox-zero-redis-http-env = {
    description = "Materialize redis-http env file from agenix secret for inbox-zero";
    after = ["run-agenix.d.mount"];
    requires = ["run-agenix.d.mount"];
    wantedBy = ["podman-inbox-zero-redis-http.service"];
    before = ["podman-inbox-zero-redis-http.service"];
    restartTriggers = [config.age.secrets."inbox-zero-env".file];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      ExecStart = pkgs.writeShellScript "inbox-zero-redis-http-env" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail
        ${pkgs.coreutils}/bin/mkdir -p /run/inbox-zero
        ${pkgs.coreutils}/bin/chmod 0700 /run/inbox-zero
        SRH_TOKEN=$(${pkgs.gnugrep}/bin/grep -E '^SRH_TOKEN=' ${config.age.secrets."inbox-zero-env".path} | ${pkgs.coreutils}/bin/cut -d= -f2-)
        if [ -z "$SRH_TOKEN" ]; then
          echo "SRH_TOKEN missing from inbox-zero-env" >&2
          exit 1
        fi
        umask 0077
        {
          # SRH_MODE=env -> single-user, configured via env vars (vs. tokens.json file mode)
          echo "SRH_MODE=env"
          ${pkgs.coreutils}/bin/printf 'SRH_TOKEN=%s\n' "$SRH_TOKEN"
          echo "SRH_CONNECTION_STRING=redis://inbox-zero-redis:6379"
        } > /run/inbox-zero/redis-http.env
      '';
    };
  };

  virtualisation.oci-containers.containers."inbox-zero-postgres" = {
    image = "postgres:16-alpine";
    autoStart = true;
    environmentFiles = ["/run/inbox-zero/postgres.env"];
    volumes = [
      "/var/lib/inbox-zero/postgres:/var/lib/postgresql/data"
    ];
    extraOptions = [
      "--network=inbox-zero"
      "--memory=2g"
      "--security-opt=no-new-privileges"
    ];
  };

  virtualisation.oci-containers.containers."inbox-zero-redis" = {
    image = "redis:7-alpine";
    autoStart = true;
    cmd = ["redis-server" "--appendonly" "yes" "--save" "60" "1000"];
    volumes = [
      "/var/lib/inbox-zero/redis:/data"
    ];
    extraOptions = [
      "--network=inbox-zero"
      "--memory=1g"
      "--security-opt=no-new-privileges"
    ];
  };

  virtualisation.oci-containers.containers."inbox-zero-redis-http" = {
    image = "hiett/serverless-redis-http:latest";
    autoStart = true;
    environmentFiles = ["/run/inbox-zero/redis-http.env"];
    dependsOn = ["inbox-zero-redis"];
    extraOptions = [
      "--network=inbox-zero"
      "--security-opt=no-new-privileges"
    ];
  };

  virtualisation.oci-containers.containers."inbox-zero-web" = {
    image = "ghcr.io/elie222/inbox-zero:latest";
    autoStart = true;
    environmentFiles = ["/run/inbox-zero/runtime.env"];
    ports = ["127.0.0.1:3000:3000"];
    dependsOn = [
      "inbox-zero-postgres"
      "inbox-zero-redis"
      "inbox-zero-redis-http"
    ];
    extraOptions = [
      "--network=inbox-zero"
      "--memory=2g"
      "--security-opt=no-new-privileges"
    ];
  };

  virtualisation.oci-containers.containers."inbox-zero-worker" = {
    image = "ghcr.io/elie222/inbox-zero:latest";
    autoStart = true;
    environmentFiles = ["/run/inbox-zero/runtime.env"];
    cmd = ["/app/docker/scripts/start-worker.sh"];
    dependsOn = [
      "inbox-zero-postgres"
      "inbox-zero-redis"
      "inbox-zero-redis-http"
    ];
    extraOptions = [
      "--network=inbox-zero"
      "--memory=1g"
      "--security-opt=no-new-privileges"
    ];
  };

  systemd.services."podman-inbox-zero-postgres" = {
    after = [
      "inbox-zero-postgres-env.service"
      "inbox-zero-podman-network.service"
    ];
    requires = [
      "inbox-zero-postgres-env.service"
      "inbox-zero-podman-network.service"
    ];
  };

  systemd.services."podman-inbox-zero-redis" = {
    after = ["inbox-zero-podman-network.service"];
    requires = ["inbox-zero-podman-network.service"];
  };

  systemd.services."podman-inbox-zero-redis-http" = {
    after = [
      "inbox-zero-podman-network.service"
      "inbox-zero-redis-http-env.service"
      "podman-inbox-zero-redis.service"
    ];
    requires = [
      "inbox-zero-podman-network.service"
      "inbox-zero-redis-http-env.service"
      "podman-inbox-zero-redis.service"
    ];
  };

  systemd.services."podman-inbox-zero-web" = {
    after = [
      "inbox-zero-podman-network.service"
      "inbox-zero-runtime-env.service"
      "podman-inbox-zero-postgres.service"
      "podman-inbox-zero-redis-http.service"
    ];
    requires = [
      "inbox-zero-podman-network.service"
      "inbox-zero-runtime-env.service"
      "podman-inbox-zero-postgres.service"
      "podman-inbox-zero-redis-http.service"
    ];
  };

  systemd.services."podman-inbox-zero-worker" = {
    after = [
      "inbox-zero-podman-network.service"
      "inbox-zero-runtime-env.service"
      "podman-inbox-zero-postgres.service"
      "podman-inbox-zero-redis-http.service"
    ];
    requires = [
      "inbox-zero-podman-network.service"
      "inbox-zero-runtime-env.service"
      "podman-inbox-zero-postgres.service"
      "podman-inbox-zero-redis-http.service"
    ];
  };
}
