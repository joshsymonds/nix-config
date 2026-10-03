{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.valheim;
  stateDirectory = "/var/lib/valheim";
  invalidPassword = ''
    printf '%s\n' "valheim password is invalid" >> "$log_file"
    exit 78
  '';
  serverArgs =
    [
      "-nographics"
      "-batchmode"
      "-disable-crash-handler"
      "-logFile"
      "-"
      "-name"
      cfg.serverName
      "-world"
      cfg.worldName
      "-port"
      (toString cfg.port)
      "-public"
      "0"
      "-savedir"
      stateDirectory
    ]
    ++ lib.concatLists (lib.mapAttrsToList (name: value: ["-modifier" name value]) cfg.modifiers);
  stopper = pkgs.writeShellScript "valheim-stop" ''
    set -eu
    game_pid=
    for proc in /proc/[0-9]*; do
      executable=$(${pkgs.coreutils}/bin/readlink "$proc/exe" 2>/dev/null || true)
      case "$executable" in
        */valheim_server.x86_64)
          game_pid=''${proc#/proc/}
          break
          ;;
      esac
    done

    [ -n "$game_pid" ] || exit 0
    ${pkgs.coreutils}/bin/kill -INT "$game_pid"
    while ${pkgs.coreutils}/bin/kill -0 "$game_pid" 2>/dev/null; do
      ${pkgs.coreutils}/bin/sleep 1
    done
  '';
  # BepInEx takes its root from two directories above the preloader it was
  # handed and writes its cache, config and log there, so it needs a writable
  # copy of itself rather than store symlinks Doorstop could resolve back into
  # the store. core/ and plugins/ are rebuilt from the store on every start;
  # config/ persists, with the declared files rewritten each time.
  bepinexRoot = "${stateDirectory}/bepinex/BepInEx";
  bepinexSetup = ''
    ${pkgs.coreutils}/bin/rm -rf "${bepinexRoot}/core" "${bepinexRoot}/plugins"
    ${pkgs.coreutils}/bin/mkdir -p "${bepinexRoot}/config" "${bepinexRoot}/plugins"
    ${pkgs.coreutils}/bin/cp -rL --no-preserve=mode ${cfg.bepinex.pack}/BepInEx/core "${bepinexRoot}/core"
    if [ ! -e "${bepinexRoot}/config/BepInEx.cfg" ]; then
      ${pkgs.coreutils}/bin/cp -L --no-preserve=mode ${cfg.bepinex.pack}/BepInEx/config/BepInEx.cfg "${bepinexRoot}/config/BepInEx.cfg"
    fi
    ${lib.concatStrings (lib.mapAttrsToList (name: plugin: ''
        ${pkgs.coreutils}/bin/cp -rL --no-preserve=mode ${plugin} ${lib.escapeShellArg "${bepinexRoot}/plugins/${name}"}
      '')
      cfg.bepinex.plugins)}
    ${lib.concatStrings (lib.mapAttrsToList (name: text: ''
        ${pkgs.coreutils}/bin/cp --no-preserve=mode ${pkgs.writeText "bepinex-${name}" text} ${lib.escapeShellArg "${bepinexRoot}/config/${name}"}
      '')
      cfg.bepinex.configFiles)}
    export DOORSTOP_ENABLED=1
    export DOORSTOP_TARGET_ASSEMBLY="${bepinexRoot}/core/BepInEx.Preloader.dll"
    export VALHEIM_LD_PRELOAD=${cfg.bepinex.pack}/doorstop_libs/libdoorstop_x64.so
  '';
  launcher = pkgs.writeShellScript "valheim-launch" ''
    set -eu
    log_directory=${stateDirectory}/logs
    log_file="$log_directory/valheim-current.log"

    ${pkgs.coreutils}/bin/mkdir -p "$log_directory"
    ${pkgs.coreutils}/bin/chmod 0700 "$log_directory"
    : > "$log_file"
    ${pkgs.coreutils}/bin/chmod 0600 "$log_file"
    printf '%s\n' "valheim invocation start" >> "$log_file"
    ${lib.optionalString cfg.bepinex.enable bepinexSetup}

    password=""
    ${lib.optionalString (cfg.passwordFile != null) ''
      password_file=${lib.escapeShellArg (toString cfg.passwordFile)}
      if [ ! -r "$password_file" ]; then
        printf '%s\n' "valheim password file is missing or unreadable" >> "$log_file"
        exit 78
      fi

      if ! password=$(${pkgs.coreutils}/bin/cat -- "$password_file"); then
        printf '%s\n' "valheim password file is missing or unreadable" >> "$log_file"
        exit 78
      fi
      byte_count=$(${pkgs.coreutils}/bin/wc -c < "$password_file")
      line_count=$(${pkgs.coreutils}/bin/wc -l < "$password_file")

      case "$password" in
        ""|*[!A-Za-z0-9]*)
          ${invalidPassword}
          ;;
      esac
      if [ ''${#password} -lt 5 ]; then
        ${invalidPassword}
      fi

      # Accept one alphanumeric line with or without its final newline. Reject
      # extra/truncated lines even though command substitution strips newlines.
      case "$line_count" in
        0) expected_bytes=''${#password} ;;
        1) expected_bytes=$(( ''${#password} + 1 )) ;;
        *) ${invalidPassword} ;;
      esac
      if [ "$byte_count" -ne "$expected_bytes" ]; then
        ${invalidPassword}
      fi
    ''}

    set +e
    ${lib.getExe' cfg.package "valheim-server"} \
      ${lib.escapeShellArgs serverArgs} \
      -password "$password" >> "$log_file" 2>&1
    game_status=$?
    set -e
    printf '%s\n' "valheim invocation exit status=$game_status" >> "$log_file"
    exit "$game_status"
  '';
in {
  options.services.valheim = {
    enable = lib.mkEnableOption "the Valheim dedicated server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.valheim-server;
      description = "Valheim dedicated server package.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      description = "Restricted runtime password file, or null to explicitly allow passwordless joins.";
    };

    serverName = lib.mkOption {
      type = lib.types.strMatching ".+";
      default = "Midgard";
      description = "Name advertised by the server.";
    };

    worldName = lib.mkOption {
      type = lib.types.strMatching ".+";
      default = "Midgard";
      description = "Persistent world name.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 2456;
      description = "Base UDP game port.";
    };

    modifiers = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {deathpenalty = "casual";};
      description = ''
        World modifiers passed as `-modifier <name> <option>`. The server
        applies them to the existing world at every load. Names are
        WorldModifiers values (deathpenalty, combat, resources, raids,
        portals); options are WorldModifierOption values (casual, veryeasy, ...).
      '';
    };

    bepinex = {
      enable = lib.mkEnableOption "BepInEx server-side plugins (clients need nothing)";

      pack = lib.mkOption {
        type = lib.types.package;
        default = pkgs.valheim-server.bepinex.pack;
        defaultText = lib.literalExpression "pkgs.valheim-server.bepinex.pack";
        description = "BepInExPack_Valheim root (BepInEx/, doorstop_libs/).";
      };

      plugins = lib.mkOption {
        type = lib.types.attrsOf lib.types.package;
        default = {};
        description = "Plugin folders, each installed as BepInEx/plugins/<name>.";
      };

      configFiles = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        default = {};
        description = "Files written to BepInEx/config/<name> on every start, replacing what was there.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.valheim = {
      isSystemUser = true;
      group = "valheim";
      home = stateDirectory;
    };
    users.groups.valheim = {};

    systemd.services.valheim = {
      description = "Valheim dedicated server";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      environment.HOME = stateDirectory;

      serviceConfig = {
        Type = "simple";
        User = "valheim";
        Group = "valheim";
        ExecStart = launcher;
        ExecStop = stopper;
        Restart = "on-failure";
        RestartSec = "5s";

        StateDirectory = "valheim";
        StateDirectoryMode = "0700";
        WorkingDirectory = stateDirectory;
        UMask = "0077";

        KillSignal = "SIGINT";
        TimeoutStopSec = "120s";
        LimitCORE = 0;
        StandardOutput = "null";
        StandardError = "null";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };
  };
}
