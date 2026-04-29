# Daily backups of service configs to NAS.
# Back up config directories, databases, and certificates so a full
# restore is possible from NAS backups + nix-config repo alone.
{pkgs, ...}: let
  backupScript = pkgs.writeShellScript "media-backup" ''
    #!${pkgs.bash}/bin/bash
    set -uo pipefail
    export PATH="${pkgs.gzip}/bin:$PATH"

    BACKUP_ROOT="/mnt/backups/media-services"
    DATE=$(${pkgs.coreutils}/bin/date +%Y-%m-%d)
    KEEP_DAYS=7
    FAILURES=0

    echo "=== Media service backup starting at $(${pkgs.coreutils}/bin/date) ==="

    # Ensure NAS is mounted
    if ! ${pkgs.coreutils}/bin/mountpoint -q /mnt/backups 2>/dev/null; then
      echo "Mounting /mnt/backups..."
      ${pkgs.systemd}/bin/systemctl start mnt-backups.automount || {
        echo "ERROR: Failed to mount /mnt/backups"
        exit 1
      }
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$BACKUP_ROOT"

    backup_dir() {
      local name="$1" src="$2"
      local dest="$BACKUP_ROOT/$name"
      local tarball="$dest/$name-$DATE.tar.gz"

      if [ ! -d "$src" ]; then
        echo "$name: ERROR - source $src not found"
        FAILURES=$((FAILURES + 1))
        return 1
      fi

      # Check source has actual content (not just empty dir)
      local file_count
      file_count=$(${pkgs.findutils}/bin/find "$src" -type f 2>/dev/null | ${pkgs.coreutils}/bin/wc -l)
      if [ "$file_count" -eq 0 ]; then
        echo "$name: ERROR - source $src exists but contains no files"
        FAILURES=$((FAILURES + 1))
        return 1
      fi

      ${pkgs.coreutils}/bin/mkdir -p "$dest"
      echo "$name: backing up $src ($file_count files)"
      if ! ${pkgs.gnutar}/bin/tar czf "$tarball" \
        -C "$(${pkgs.coreutils}/bin/dirname "$src")" \
        "$(${pkgs.coreutils}/bin/basename "$src")"; then
        echo "$name: ERROR - tar failed"
        ${pkgs.coreutils}/bin/rm -f "$tarball"
        FAILURES=$((FAILURES + 1))
        return 1
      fi

      # Verify tarball is non-empty
      local size
      size=$(${pkgs.coreutils}/bin/stat -c%s "$tarball")
      if [ "$size" -lt 100 ]; then
        echo "$name: ERROR - tarball is only $size bytes, removing"
        ${pkgs.coreutils}/bin/rm -f "$tarball"
        FAILURES=$((FAILURES + 1))
        return 1
      fi

      echo "$name: done ($(${pkgs.coreutils}/bin/numfmt --to=iec "$size"))"
    }

    # *arr services - back up full config dirs (DB, config.xml, logs, etc.)
    backup_dir "sonarr" "/var/lib/sonarr/.config/NzbDrone"
    backup_dir "radarr" "/var/lib/radarr/.config/Radarr"
    backup_dir "readarr" "/var/lib/readarr"
    # Prowlarr uses DynamicUser=true; real data is at /var/lib/private/prowlarr
    backup_dir "prowlarr" "/var/lib/private/prowlarr"

    # Jellyfin - config and data (excludes transcodes/cache)
    backup_dir "jellyfin" "/var/lib/jellyfin/config"

    # Jellyseerr - full config
    backup_dir "jellyseerr" "/etc/jellyseerr/config"

    # Bazarr - full config
    backup_dir "bazarr" "/etc/bazarr/config"

    # SABnzbd - config (excludes downloads/cache)
    backup_dir "sabnzbd" "/var/lib/sabnzbd"

    # Caddy - ACME accounts and TLS certificates
    # Without this, a reimage hits Let's Encrypt rate limits and all HTTPS is down
    backup_dir "caddy" "/var/lib/caddy"

    # inbox-zero Redis (BullMQ queues + cache, AOF-persisted)
    backup_dir "inbox-zero-redis" "/var/lib/inbox-zero/redis"

    # PostgreSQL - dump databases (used by Invidious)
    pg_dest="$BACKUP_ROOT/postgresql"
    ${pkgs.coreutils}/bin/mkdir -p "$pg_dest"
    echo "postgresql: dumping all databases"
    if ${pkgs.sudo}/bin/sudo -u postgres ${pkgs.postgresql}/bin/pg_dumpall \
      | ${pkgs.gzip}/bin/gzip > "$pg_dest/pg_dumpall-$DATE.sql.gz"; then
      size=$(${pkgs.coreutils}/bin/stat -c%s "$pg_dest/pg_dumpall-$DATE.sql.gz")
      if [ "$size" -lt 100 ]; then
        echo "postgresql: ERROR - dump is only $size bytes, removing"
        ${pkgs.coreutils}/bin/rm -f "$pg_dest/pg_dumpall-$DATE.sql.gz"
        FAILURES=$((FAILURES + 1))
      else
        echo "postgresql: done ($(${pkgs.coreutils}/bin/numfmt --to=iec "$size"))"
      fi
    else
      echo "postgresql: ERROR - pg_dumpall failed"
      ${pkgs.coreutils}/bin/rm -f "$pg_dest/pg_dumpall-$DATE.sql.gz"
      FAILURES=$((FAILURES + 1))
    fi

    # inbox-zero (containerized postgres on its own podman network)
    iz_pg_dest="$BACKUP_ROOT/inbox-zero-postgres"
    ${pkgs.coreutils}/bin/mkdir -p "$iz_pg_dest"
    if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-inbox-zero-postgres.service; then
      echo "inbox-zero-postgres: dumping inbox_zero database"
      if ${pkgs.podman}/bin/podman exec inbox-zero-postgres \
           pg_dump -U inbox_zero -d inbox_zero -Fc \
           | ${pkgs.gzip}/bin/gzip > "$iz_pg_dest/inbox-zero-$DATE.sql.gz"; then
        size=$(${pkgs.coreutils}/bin/stat -c%s "$iz_pg_dest/inbox-zero-$DATE.sql.gz")
        if [ "$size" -lt 100 ]; then
          echo "inbox-zero-postgres: ERROR - dump is only $size bytes, removing"
          ${pkgs.coreutils}/bin/rm -f "$iz_pg_dest/inbox-zero-$DATE.sql.gz"
          FAILURES=$((FAILURES + 1))
        else
          echo "inbox-zero-postgres: done ($(${pkgs.coreutils}/bin/numfmt --to=iec "$size"))"
        fi
      else
        echo "inbox-zero-postgres: ERROR - pg_dump failed"
        ${pkgs.coreutils}/bin/rm -f "$iz_pg_dest/inbox-zero-$DATE.sql.gz"
        FAILURES=$((FAILURES + 1))
      fi
    else
      echo "inbox-zero-postgres: skipped (container not running)"
    fi

    # Only prune old backups if all current backups succeeded
    if [ "$FAILURES" -eq 0 ]; then
      echo "Pruning backups older than $KEEP_DAYS days..."
      ${pkgs.findutils}/bin/find "$BACKUP_ROOT" \( -name "*.tar.gz" -o -name "*.sql.gz" \) -mtime +$KEEP_DAYS -delete 2>/dev/null || true
    else
      echo "WARNING: $FAILURES backup(s) failed, skipping pruning to preserve old backups"
    fi

    echo "=== Backup complete at $(${pkgs.coreutils}/bin/date) ($FAILURES failures) ==="
    [ "$FAILURES" -eq 0 ]
  '';
in {
  systemd.services.media-backup = {
    description = "Backup media service configs to NAS";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = backupScript;
    };
  };

  systemd.timers.media-backup = {
    description = "Daily media service backup at 4:00 AM";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
  };
}
