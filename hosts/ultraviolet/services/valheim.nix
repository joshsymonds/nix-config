{pkgs, ...}: {
  imports = [../../../modules/services/valheim.nix];

  networking.firewall.allowedUDPPorts = [2456 2457];

  services.valheim = {
    enable = true;
    package = pkgs.valheim-server;
    passwordFile = null;
  };

  systemd.services.valheim-backup = {
    description = "Back up Valheim state to the NAS";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      StateDirectory = "valheim-backup";
      StateDirectoryMode = "0700";
      UMask = "0077";
      ExecStart = pkgs.writeShellScript "valheim-backup" ''
        set -euo pipefail

        state=/var/lib/valheim
        spool=/var/lib/valheim-backup
        destination=/mnt/backups/valheim
        staging="$spool/.current.$$"
        remote_tmp=
        restart_needed=0
        lock_held=0
        lock=/run/valheim-backup.lock

        release_lock() {
          if [ "$lock_held" -eq 1 ]; then
            ${pkgs.util-linux}/bin/flock -u 9
            exec 9>&-
            lock_held=0
          fi
        }

        finish() {
          status=$?
          trap - EXIT HUP INT TERM
          if ! ${pkgs.coreutils}/bin/rm -rf -- "$staging"; then
            echo "failed to clean local backup staging" >&2
            status=1
          fi
          if [ -n "$remote_tmp" ] && ! ${pkgs.coreutils}/bin/rm -f -- "$remote_tmp"; then
            echo "failed to clean remote backup temporary file" >&2
            status=1
          fi
          if ! release_lock; then
            echo "failed to release Valheim backup lock" >&2
            status=1
          fi
          if [ "$restart_needed" -eq 1 ]; then
            if ! ${pkgs.systemd}/bin/systemctl start valheim.service; then
              echo "failed to restore initially running Valheim service" >&2
              status=1
            fi
          fi
          exit "$status"
        }
        trap finish EXIT
        trap 'exit 1' HUP INT TERM

        exec 9>"$lock"
        if ! ${pkgs.util-linux}/bin/flock -n 9; then
          echo "another backup is already capturing Valheim state" >&2
          exit 1
        fi
        lock_held=1
        ${pkgs.coreutils}/bin/mkdir -p "$spool"
        ${pkgs.coreutils}/bin/chmod 0700 "$spool"

        before_save_markers=0
        if ${pkgs.systemd}/bin/systemctl is-active --quiet valheim.service; then
          restart_needed=1
          before_save_markers=$(${pkgs.gnugrep}/bin/grep -Fc 'World save (5/5) done.' "$state/logs/valheim-current.log" || true)
        fi
        ${pkgs.systemd}/bin/systemctl stop valheim.service
        if ${pkgs.systemd}/bin/systemctl is-active --quiet valheim.service; then
          echo "Valheim remained active after its graceful stop" >&2
          exit 1
        fi
        if [ "$restart_needed" -eq 1 ]; then
          after_save_markers=$(${pkgs.gnugrep}/bin/grep -Fc 'World save (5/5) done.' "$state/logs/valheim-current.log" || true)
          if [ "$after_save_markers" -le "$before_save_markers" ]; then
            echo "graceful stop did not record a newly completed world save" >&2
            exit 1
          fi
        fi

        world_directory="$state/worlds_local/Midgard"
        for suffix in fwl2 db2 chunks; do
          world_file=$(${pkgs.findutils}/bin/find "$world_directory" \
            -maxdepth 1 -type f -name "_main.*.$suffix" -size +0c -print -quit)
          if [ -z "$world_file" ]; then
            echo "missing or empty pinned world data: _main.*.$suffix" >&2
            exit 1
          fi
        done

        ${pkgs.coreutils}/bin/mkdir -p "$staging/state"
        ${pkgs.coreutils}/bin/cp -a "$state/." "$staging/state/"

        release_lock
        if [ "$restart_needed" -eq 1 ]; then
          ${pkgs.systemd}/bin/systemctl start valheim.service
          if ! ${pkgs.systemd}/bin/systemctl is-active --quiet valheim.service; then
            echo "failed to restore initially running Valheim service" >&2
            exit 1
          fi
          restart_needed=0
        fi

        # Trigger the automount read-only, then require its real backing rather
        # than accepting the simultaneously visible autofs mount.
        ${pkgs.coreutils}/bin/stat /mnt/backups/. >/dev/null
        backing=$(${pkgs.util-linux}/bin/findmnt -rn -T /mnt/backups -o FSTYPE,SOURCE \
          | ${pkgs.gawk}/bin/awk '$1 ~ /^nfs4?$/ && $2 == "172.31.0.100:/volume1/backup" { print; exit }')
        if [ -z "$backing" ]; then
          echo "expected NAS backing is not mounted at /mnt/backups" >&2
          exit 1
        fi

        ${pkgs.coreutils}/bin/mkdir -p "$destination"
        remote_tmp=$(${pkgs.coreutils}/bin/mktemp \
          "$destination/.valheim-$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)-XXXXXX.tmp")
        temporary_name=''${remote_tmp##*/}
        archive="$destination/''${temporary_name#.}"
        archive=''${archive%.tmp}.tar
        ${pkgs.gnutar}/bin/tar -C "$staging" -cf "$remote_tmp" state
        ${pkgs.coreutils}/bin/mv -- "$remote_tmp" "$archive"
        remote_tmp=

        ${pkgs.findutils}/bin/find "$destination" -maxdepth 1 -type f \
          -name 'valheim-*.tar' -mtime +7 -delete
      '';
    };
  };

  systemd.timers.valheim-backup = {
    description = "Daily Valheim backup at 04:15";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 04:15:00";
      Persistent = true;
      Unit = "valheim-backup.service";
    };
  };
}
