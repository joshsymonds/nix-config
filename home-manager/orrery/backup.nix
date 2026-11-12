# Nightly copy of the orrery store to the NAS bucket. sqlite's online backup
# takes a consistent copy while orreryd keeps writing; the copy is checked with
# integrity_check before it goes to the NAS. Copies older than 14 days in the
# backup directory are removed; nothing else on the NAS is touched.
{pkgs, ...}: let
  orreryBackup = pkgs.writeShellApplication {
    name = "orrery-backup";
    runtimeInputs = with pkgs; [coreutils findutils sqlite util-linux];
    text = ''
      store="''${ORRERY_BACKUP_STORE:-$HOME/.local/state/orrery/orrery.db}"
      if [ -n "''${ORRERY_BACKUP_DIR:-}" ]; then
        dest="$ORRERY_BACKUP_DIR"
      else
        # Trigger the automount, then require NFS before touching /mnt/claude.
        ls /mnt/claude >/dev/null 2>&1 || true
        if ! findmnt -n -t nfs,nfs4 /mnt/claude >/dev/null 2>&1; then
          echo "orrery-backup: /mnt/claude is not mounted (NAS down?)" >&2
          exit 1
        fi
        dest="/mnt/claude/$(uname -n)/orrery-backups"
      fi
      if [ ! -f "$store" ]; then
        echo "orrery-backup: no store at $store" >&2
        exit 1
      fi

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      copy="$work/orrery.db"
      sqlite3 "$store" ".backup '$copy'"
      check=$(sqlite3 "$copy" 'PRAGMA integrity_check;')
      if [ "$check" != ok ]; then
        echo "orrery-backup: integrity_check failed: $check" >&2
        exit 1
      fi

      mkdir -p "$dest"
      name="orrery-$(date +%Y-%m-%d).db"
      cp "$copy" "$dest/$name.partial"
      mv -f "$dest/$name.partial" "$dest/$name"
      find "$dest" -maxdepth 1 -type f -name 'orrery-*.db' -mtime +14 -delete
      echo "orrery-backup: $dest/$name ($(stat -c %s "$dest/$name") bytes)"
    '';
  };
in {
  home.packages = [orreryBackup];

  systemd.user.services.orrery-backup = {
    Unit = {
      Description = "Copy the orrery store to the NAS bucket";
      After = ["network-online.target"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${orreryBackup}/bin/orrery-backup";
    };
  };

  systemd.user.timers.orrery-backup = {
    Unit.Description = "Copy the orrery store to the NAS bucket nightly at 03:30";
    Timer = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
      Unit = "orrery-backup.service";
    };
    Install.WantedBy = ["timers.target"];
  };
}
