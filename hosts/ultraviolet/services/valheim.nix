{pkgs, ...}: {
  imports = [../../../modules/services/valheim.nix];

  networking.firewall.allowedUDPPorts = [2456 2457];

  services.valheim = {
    enable = true;
    package = pkgs.valheim-server;
    passwordFile = null;

    bepinex = {
      enable = true;
      plugins = {
        SpreadTheLoad = pkgs.valheim-server.bepinex.plugins.spreadTheLoad;
        ValheimTune = pkgs.valheim-server.bepinex.plugins.valheimTune;
        PortalGhostFix = pkgs.valheim-server.bepinex.plugins.portalGhostFix;
        AFKManager = pkgs.valheim-server.bepinex.plugins.afkManager;
      };
      # Shared objects (creatures, spawners, trees) are simulated by whoever
      # owns them; Futhark's and Björn's machines lag when that is them, so
      # anything they share with Atmus is handed to Atmus. Alone, they keep it.
      configFiles."DeathMonger.SpreadTheLoad.cfg" = ''
        [General]
        Yield Players = 76561198051614518,76561197995483534
      '';
      # Vanilla bug fixes only; every performance replacement off. Fix #1:
      # 1.0's incremental save skips chunks only clients changed, so player
      # edits there revert on restart (worse with SpreadTheLoad, which routes
      # more changes through clients). AllPeersPerRound stays off because
      # SpreadTheLoad already replaces SendZDOToPeers2.
      configFiles."akoozie.valheimtune.cfg" = ''
        [Fixes]
        SaveDirtyFix = true
        SpawnerLinkFix = true
        DisconnectNoSleep = true
        DeadZdoPrune = true
        GlobalKeyDedupe = true

        [Sync]
        DirtySets = false
        TopKSort = false
        AllPeersPerRound = false
        OverrideSendWindow = false
        RelayMinIntervalMs = 0

        [Steam]
        OverrideSendRate = false

        [Receive]
        MaxPacketsPerPeerPerFrame = 0

        [Server]
        TargetFrameRate = 0
        SkipRenderMesh = false
        DeferAssetUnload = false

        [Cleanup]
        FloatingDropsRun = false
        FloatingDropsDelete = false

        [Compat]
        DisableOnUnknownBuild = true

        [Measure]
        LogIntervalSeconds = 300
        ConfigReloadSeconds = 0
      '';
      # Top-left notice only: the chat announcement works by briefly sending
      # every client a player list with a fake "AFKManager" player in it.
      configFiles."torokal.afkmanager.cfg" = ''
        [Announcements]
        AnnounceInChat = false
      '';
    };
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
        worlds="$state/worlds_local"
        spool=/var/lib/valheim-backup
        destination=/mnt/backups/valheim
        staging="$spool/.current.$$"
        remote_tmp=

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
          exit "$status"
        }
        trap finish EXIT
        trap 'exit 1' HUP INT TERM

        # Copy the world while the server runs. Every save writes new chunk
        # generations and a new _main.<N> set, so an unchanged listing across
        # the copy means no save (or Valheim auto-backup) touched it.
        fingerprint() {
          ${pkgs.findutils}/bin/find "$worlds" -type f -printf '%P %s %T@\n' \
            | ${pkgs.coreutils}/bin/sort
        }

        ${pkgs.coreutils}/bin/mkdir -p "$spool"
        ${pkgs.coreutils}/bin/chmod 0700 "$spool"

        copied=0
        for attempt in 1 2 3 4 5; do
          ${pkgs.coreutils}/bin/rm -rf -- "$staging"
          ${pkgs.coreutils}/bin/mkdir -p "$staging/state"
          before=$(fingerprint)
          ${pkgs.coreutils}/bin/cp -a "$state/." "$staging/state/"
          after=$(fingerprint)
          if [ "$before" = "$after" ]; then
            copied=1
            break
          fi
          echo "world changed during copy (attempt $attempt), retrying" >&2
          ${pkgs.coreutils}/bin/sleep 5
        done
        if [ "$copied" -ne 1 ]; then
          echo "world kept changing during every copy attempt" >&2
          exit 1
        fi

        # A committed save is one _main.<N> set ending in its .ok marker, which
        # Valheim writes last; chunks newer than the marker mean a save was
        # still in progress.
        world_directory="$staging/state/worlds_local/Midgard"
        shopt -s nullglob
        markers=("$world_directory"/_main.*.ok)
        shopt -u nullglob
        if [ "''${#markers[@]}" -ne 1 ]; then
          echo "expected exactly one committed save marker, found ''${#markers[@]}" >&2
          exit 1
        fi
        marker=''${markers[0]}
        save=''${marker##*/_main.}
        save=''${save%.ok}
        for suffix in chunks db2 fwl2; do
          if [ ! -s "$world_directory/_main.$save.$suffix" ]; then
            echo "missing or empty world data: _main.$save.$suffix" >&2
            exit 1
          fi
        done
        if [ -n "$(${pkgs.findutils}/bin/find "$world_directory" -maxdepth 1 \
          -name '*.chunk' -newer "$marker" -print -quit)" ]; then
          echo "chunks newer than save $save marker: copy caught a save in progress" >&2
          exit 1
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
