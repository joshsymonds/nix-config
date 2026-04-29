# Inbox Zero (https://github.com/elie222/inbox-zero) — self-hosted on ultraviolet.
#
# This task only stands up the database tier:
#   - three agenix secrets (env, db-password, pubsub-key)
#   - a dedicated Podman network "inbox-zero" so containers can reach each other by name
#   - a containerized Postgres bound to that network, NOT to the host's 127.0.0.1
#
# Web/worker/redis/redis-http and the cron timers come in later tasks. The system
# Postgres on this host is intentionally left untouched (its pg_hba.conf trust
# default is fine for invidious's local-socket use; we just don't build on top of it).
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

  systemd.tmpfiles.rules = [
    "d /var/lib/inbox-zero 0700 root root -"
    "d /var/lib/inbox-zero/postgres 0700 root root -"
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
}
