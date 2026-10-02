{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.privateStore;
  imageDirectory = builtins.dirOf cfg.imagePath;
  mapper = "/dev/mapper/strongbox";
  lockFile = "/run/lock/strongbox.lock";
  backupMount = "/mnt/backup";
  backupImage = "${backupMount}/private-store.img";
  previousBackupImage = "${backupImage}.previous";
  databaseUnit = "postgresql.target";
  databaseSocketDirectory = "${cfg.mountPath}/postgresql/socket";
  sessionSocket = "${cfg.mountPath}/tmux/socket";

  strongbox = pkgs.writeShellApplication {
    name = "strongbox";
    runtimeInputs = with pkgs; [
      coreutils
      cryptsetup
      e2fsprogs
      systemd
      tmux
      util-linux
    ];
    text = ''
      set -euo pipefail

      image=${lib.escapeShellArg cfg.imagePath}
      mount_path=${lib.escapeShellArg cfg.mountPath}
      mapper=${lib.escapeShellArg mapper}
      lock_file=${lib.escapeShellArg lockFile}
      session_socket=${lib.escapeShellArg sessionSocket}
      backup_mount=${lib.escapeShellArg backupMount}
      backup_image=${lib.escapeShellArg backupImage}
      previous_backup_image=${lib.escapeShellArg previousBackupImage}

      fail() {
        printf 'strongbox: %s\n' "$*" >&2
        exit 1
      }

      require_root() {
        if [ "$EUID" -ne 0 ]; then
          fail 'run this command as root, usually with sudo'
        fi
      }

      acquire_lock() {
        exec 9>"$lock_file"
        flock -x 9
      }

      prompt_passphrase() {
        local label="$1"
        local confirmation
        if [ ! -t 0 ]; then
          IFS= read -r passphrase || fail 'unable to read passphrase from stdin'
          return
        fi
        read -r -s -p "$label: " passphrase
        printf '\n' >&2
        if [ "$label" = 'New passphrase' ]; then
          read -r -s -p 'Confirm passphrase: ' confirmation
          printf '\n' >&2
          [ "$passphrase" = "$confirmation" ] || fail 'passphrases do not match'
        fi
      }

      close_mapper() {
        if [ -e "$mapper" ]; then
          cryptsetup close strongbox || return 1
        fi
        [ ! -e "$mapper" ]
      }

      report_still_open() {
        printf 'strongbox: still open; mapper or mount remains active\n' >&2
      }

      cleanup_open_failure() {
        local failed=0
        systemctl stop strongbox-session.service >/dev/null 2>&1 || true
        systemctl stop ${lib.escapeShellArg databaseUnit} >/dev/null 2>&1 || true
        systemctl stop postgresql.service postgresql-setup.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet strongbox-session.service || systemctl is-active --quiet ${lib.escapeShellArg databaseUnit} || systemctl is-active --quiet postgresql.service || systemctl is-active --quiet postgresql-setup.service; then
          report_still_open
          return 1
        fi
        if mountpoint -q "$mount_path"; then
          umount "$mount_path" || failed=1
        fi
        if [ -e "$mapper" ]; then
          close_mapper || failed=1
        fi
        if [ "$failed" -ne 0 ] || mountpoint -q "$mount_path" || [ -e "$mapper" ]; then
          report_still_open
        fi
      }

      open_store() {
        require_root
        acquire_lock
        [ ! -L "$image" ] || fail 'encrypted image must not be a symlink'
        [ -f "$image" ] || fail 'encrypted image does not exist'
        [ ! -e "$mapper" ] || fail 'store is already open'
        ! mountpoint -q "$mount_path" || fail 'store is already mounted'
        prompt_passphrase 'Passphrase'

        if ! printf '%s' "$passphrase" | cryptsetup open --key-file - "$image" strongbox; then
          unset passphrase
          fail 'unable to unlock encrypted image'
        fi
        unset passphrase

        if ! mount -t ext4 -o nodev,nosuid "$mapper" "$mount_path"; then
          cleanup_open_failure
          fail 'unable to mount encrypted filesystem'
        fi

        if ! chown strongbox:strongbox "$mount_path" || ! chmod 0700 "$mount_path" || ! install -d -o strongbox -g strongbox -m 0700 "$(dirname "$session_socket")" "$mount_path/tmp" "$mount_path/postgresql/data" "$mount_path/postgresql/log" || ! install -d -o strongbox -g private-store-socket -m 0770 "$mount_path/postgresql/socket"; then
          cleanup_open_failure
          fail 'unable to prepare encrypted filesystem'
        fi

        if ! systemctl start ${lib.escapeShellArg databaseUnit} || ! systemctl start strongbox-session.service; then
          cleanup_open_failure
          fail 'unable to start private PostgreSQL service and session'
        fi
      }

      create_store() {
        require_root
        acquire_lock
        [ ! -e "$image" ] && [ ! -L "$image" ] || fail 'encrypted image already exists; refusing to overwrite it'
        [ -d ${lib.escapeShellArg imageDirectory} ] || fail 'encrypted image directory is unavailable'
        chown strongbox:strongbox ${lib.escapeShellArg imageDirectory}
        chmod 0700 ${lib.escapeShellArg imageDirectory}
        prompt_passphrase 'New passphrase'
        [ -n "$passphrase" ] || fail 'passphrase must not be empty'

        created=0
        opened=0
        cleanup_create_failure() {
          local failed=0
          if [ "$opened" -eq 1 ]; then
            close_mapper || failed=1
          fi
          if [ "$failed" -eq 0 ] && [ "$created" -eq 1 ]; then
            rm -f -- "$image" || failed=1
          fi
          if [ "$failed" -ne 0 ]; then
            report_still_open
          fi
        }
        on_create_exit() {
          local result
          result=$?
          if [ "$result" -ne 0 ]; then
            cleanup_create_failure
          fi
        }
        trap on_create_exit EXIT

        umask 077
        truncate -s 32G "$image"
        created=1
        if ! printf '%s' "$passphrase" | cryptsetup luksFormat --batch-mode --type luks2 --pbkdf argon2id --key-file - "$image"; then
          unset passphrase
          fail 'unable to initialize LUKS2 image'
        fi
        if ! printf '%s' "$passphrase" | cryptsetup open --key-file - "$image" strongbox; then
          unset passphrase
          fail 'unable to open newly initialized image'
        fi
        unset passphrase
        opened=1
        mkfs.ext4 -F -m 0 -L strongbox "$mapper"
        close_mapper || fail 'unable to close newly formatted image'
        opened=0
        chown strongbox:strongbox "$image"
        chmod 0600 "$image"
        trap - EXIT
      }

      backup_locked_image() {
        local filesystem filesystems has_nfs=0 temporary
        stat -- "$backup_mount/." >/dev/null 2>&1 || return 1
        filesystems=$(findmnt --noheadings --output FSTYPE --mountpoint "$backup_mount" 2>/dev/null) || return 1
        while IFS= read -r filesystem; do
          case "$filesystem" in
            nfs|nfs4)
              has_nfs=1
              break
              ;;
          esac
        done <<< "$filesystems"
        [ "$has_nfs" -eq 1 ] || return 1

        temporary=$(runuser -u strongbox -- mktemp "$backup_mount/.private-store.img.XXXXXXXXXX") || return 1
        if ! runuser -u strongbox -- cp -- "$image" "$temporary"; then
          runuser -u strongbox -- rm -f -- "$temporary" || true
          return 1
        fi
        if { [ -e "$backup_image" ] || [ -L "$backup_image" ]; } && ! runuser -u strongbox -- mv -fT -- "$backup_image" "$previous_backup_image"; then
          runuser -u strongbox -- rm -f -- "$temporary" || true
          return 1
        fi
        if ! runuser -u strongbox -- mv -fT -- "$temporary" "$backup_image"; then
          runuser -u strongbox -- rm -f -- "$temporary" || true
          return 1
        fi
      }

      close_store() {
        require_root
        acquire_lock
        local failed=0
        systemctl stop strongbox-session.service || failed=1
        systemctl stop ${lib.escapeShellArg databaseUnit} || failed=1
        systemctl stop postgresql.service postgresql-setup.service || failed=1
        if [ "$failed" -ne 0 ]; then
          report_still_open
          return 1
        fi
        if mountpoint -q "$mount_path" && ! umount "$mount_path"; then
          report_still_open
          return 1
        fi
        if ! close_mapper; then
          report_still_open
          return 1
        fi
        if mountpoint -q "$mount_path" || [ -e "$mapper" ]; then
          report_still_open
          return 1
        fi
        if ! backup_locked_image; then
          printf 'strongbox: locked, backup failed\n' >&2
          return 1
        fi
      }

      remote_session() {
        if [ "$EUID" -ne 0 ]; then
          exec sudo -n -- "$0" --remote-session-root
        fi
        [ -t 0 ] && [ -t 1 ] || fail 'remote session requires a PTY'
        local answer attach_status=0
        if [ -e "$mapper" ] || mountpoint -q "$mount_path"; then
          if [ ! -e "$mapper" ] || ! mountpoint -q "$mount_path" || ! systemctl is-active --quiet strongbox-session.service; then
            fail 'store is already open or in an inconsistent state'
          fi
        else
          open_store
        fi
        tmux -S "$session_socket" attach-session -t private-shell || attach_status=$?
        if ! read -r -p 'Close strongbox? [Y/n] ' answer; then
          report_still_open
          return 1
        fi
        if [ -z "$answer" ] || [ "$answer" = y ] || [ "$answer" = Y ] || [ "$answer" = yes ] || [ "$answer" = YES ]; then
          close_store || return 1
        else
          report_still_open
        fi
        return "$attach_status"
      }

      case "''${1:-}" in
        --remote-session-root)
          [ "$#" -eq 1 ] || fail 'usage: strongbox'
          [ "$EUID" -eq 0 ] || fail 'internal remote session must run as root'
          remote_session
          ;;
        create)
          [ "$#" -eq 1 ] || fail 'usage: strongbox create'
          create_store
          ;;
        open)
          [ "$#" -eq 1 ] || fail 'usage: strongbox open'
          open_store
          ;;
        close)
          [ "$#" -eq 1 ] || fail 'usage: strongbox close'
          close_store
          ;;
        *)
          if [ "$#" -eq 0 ]; then
            remote_session
          else
            fail 'usage: strongbox {create|open|close}'
          fi
          ;;
      esac
    '';
  };
in {
  options.services.privateStore = {
    enable = lib.mkEnableOption "encrypted private PostgreSQL store";

    imagePath = lib.mkOption {
      type = lib.types.str;
      default = "/home/strongbox/private-store.img";
      description = "Persistent path to the LUKS image in the strongbox home directory.";
    };

    mountPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/strongbox";
      description = "Mount point used only while the encrypted store is open.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.strongbox.gid = 1024;
    users.groups.private-store-socket = {};
    users.users.strongbox = {
      isSystemUser = true;
      uid = 1024;
      group = "strongbox";
      home = "/home/strongbox";
      createHome = true;
      shell = pkgs.bash;
    };

    systemd.tmpfiles.rules = [
      "z ${imageDirectory} 0700 strongbox strongbox - -"
      "d ${cfg.mountPath} 0700 strongbox strongbox - -"
    ];

    environment.systemPackages = [strongbox pkgs.cryptsetup pkgs.postgresql_17 pkgs.tmux pkgs.util-linux];

    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      extensions = extensions: [extensions.pgvector];
      dataDir = "${cfg.mountPath}/postgresql/data";
      ensureDatabases = ["strongbox"];
      ensureUsers = [
        {
          name = "strongbox";
          ensureDBOwnership = true;
        }
      ];
      identMap = ''
        strongbox-map strongbox postgres
        strongbox-map strongbox strongbox
      '';
      authentication = lib.mkForce ''
        local all all peer map=strongbox-map
      '';
      settings = {
        listen_addresses = lib.mkForce "";
        unix_socket_directories = databaseSocketDirectory;
        unix_socket_permissions = "0770";
        logging_collector = true;
        log_directory = "${cfg.mountPath}/postgresql/log";
      };
    };

    systemd.targets.postgresql.wantedBy = lib.mkForce [];
    systemd.services.postgresql.serviceConfig = {
      User = lib.mkForce "strongbox";
      Group = lib.mkForce "private-store-socket";
      UMask = lib.mkForce "0007";
      ReadWritePaths = lib.mkForce [
        "${cfg.mountPath}/postgresql/data"
        "${cfg.mountPath}/postgresql/log"
        databaseSocketDirectory
      ];
      LimitCORE = 0;
    };
    systemd.services.postgresql-setup = {
      environment = {
        PGHOST = databaseSocketDirectory;
        PGUSER = "postgres";
      };
      serviceConfig = {
        User = lib.mkForce "strongbox";
        Group = lib.mkForce "strongbox";
      };
    };

    systemd.services.strongbox-session = {
      description = "Private strongbox shell session";
      after = ["postgresql.service"];
      requires = ["postgresql.service"];
      serviceConfig = {
        Type = "oneshot";
        User = "strongbox";
        Group = "strongbox";
        WorkingDirectory = cfg.mountPath;
        Environment = [
          "HOME=${cfg.mountPath}"
          "TMPDIR=${cfg.mountPath}/tmp"
          "HISTFILE=/dev/null"
        ];
        ExecStart = "${pkgs.tmux}/bin/tmux -S ${sessionSocket} new-session -d -s private-shell ${pkgs.bash}/bin/bash --noprofile --rcfile ${cfg.mountPath}/.bash_profile";
        ExecStop = "${pkgs.tmux}/bin/tmux -S ${sessionSocket} kill-server";
        RemainAfterExit = true;
        KillMode = "control-group";
        UMask = "0077";
        LimitCORE = 0;
      };
    };

    assertions = [
      {
        assertion = cfg.imagePath != cfg.mountPath && !(lib.hasPrefix "${cfg.imagePath}/" cfg.mountPath) && !(lib.hasPrefix "${cfg.mountPath}/" cfg.imagePath);
        message = "services.privateStore.imagePath must not be the mount path or contain it";
      }
      {
        assertion = imageDirectory != "/" && cfg.imagePath != "/" && cfg.mountPath != "/";
        message = "services.privateStore paths must not be the filesystem root";
      }
    ];
  };
}
