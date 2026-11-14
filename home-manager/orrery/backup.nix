# Every 10 minutes, copy orreryd's evidence blobs to the NAS. Blob names are
# content hashes, so a name already on the NAS holds the same bytes and is left
# alone; nothing on the NAS is deleted. orreryd's in-progress `.blob-*` temp
# files are skipped.
{
  pkgs,
  hostname,
  ...
}: let
  orreryBackup = pkgs.writeShellApplication {
    name = "orrery-backup";
    runtimeInputs = with pkgs; [coreutils rsync util-linux];
    text = ''
      source="''${ORRERY_BACKUP_SRC:-$HOME/.local/state/orrery/evidence/blobs}"
      # The pinned orrery may not have written a blob yet, so the directory can be
      # absent; then there is nothing to copy.
      if [ ! -d "$source" ]; then
        echo "orrery-backup: no evidence blobs at $source; nothing to copy"
        exit 0
      fi
      if [ -n "''${ORRERY_BACKUP_DIR:-}" ]; then
        dest="$ORRERY_BACKUP_DIR"
      else
        # Trigger the automount, then require NFS before touching /mnt/claude.
        ls /mnt/claude >/dev/null 2>&1 || true
        if ! findmnt -n -t nfs,nfs4 /mnt/claude >/dev/null 2>&1; then
          echo "orrery-backup: /mnt/claude is not mounted (NAS down?)" >&2
          exit 1
        fi
        dest="/mnt/claude/$(uname -n)/orrery-evidence-blobs"
      fi

      mkdir -p "$dest"
      rsync --archive --no-owner --no-group --ignore-existing --exclude='.blob-*' "$source/" "$dest/"
    '';
  };
  # Continuous replication of the store to the NAS as a Litestream file replica.
  # A negative truncate-page-n skips TRUNCATE checkpoints; 0 would mean
  # Litestream's default, not off.
  litestreamConfig = (pkgs.formats.yaml {}).generate "orrery-litestream.yml" {
    snapshot.retention = "336h";
    dbs = [
      {
        path = "$HOME/.local/state/orrery/orrery.db";
        truncate-page-n = -1;
        replica = {
          type = "file";
          path = "/mnt/claude/${hostname}/orrery-litestream";
        };
      }
    ];
  };
  # Refuse to start unless the NAS is mounted, so the replica never lands on the
  # local disk. Same mount check as orrery-backup.
  requireNas = pkgs.writeShellApplication {
    name = "orrery-litestream-require-nas";
    runtimeInputs = with pkgs; [coreutils util-linux];
    text = ''
      ls /mnt/claude >/dev/null 2>&1 || true
      if ! findmnt -n -t nfs,nfs4 /mnt/claude >/dev/null 2>&1; then
        echo "orrery-litestream: /mnt/claude is not mounted (NAS down?)" >&2
        exit 1
      fi
    '';
  };
in {
  home.packages = [orreryBackup];

  systemd.user.services.orrery-backup = {
    Unit = {
      Description = "Copy orrery evidence blobs to the NAS";
      After = ["network-online.target"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${orreryBackup}/bin/orrery-backup";
    };
  };

  systemd.user.services.orrery-litestream = {
    Unit = {
      Description = "Replicate the orrery store to the NAS with Litestream";
      After = ["network-online.target"];
      # Restarts continue across a NAS outage; 0 disables the start-rate limit.
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStartPre = "${requireNas}/bin/orrery-litestream-require-nas";
      ExecStart = "${pkgs.litestream}/bin/litestream replicate -config ${litestreamConfig}";
      Restart = "always";
      RestartSec = "60s";
    };
    Install.WantedBy = ["default.target"];
  };

  systemd.user.timers.orrery-backup = {
    Unit.Description = "Copy orrery evidence blobs to the NAS every 10 minutes";
    Timer = {
      # No Persistent: systemd only honors it on OnCalendar= timers.
      OnBootSec = "2min";
      OnUnitActiveSec = "10min";
      Unit = "orrery-backup.service";
    };
    Install.WantedBy = ["timers.target"];
  };
}
