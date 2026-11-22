{
  config,
  hostname,
  lib,
  pkgs,
  ...
}: let
  sessions = config.services.orreryd.sessions;
  pushHost = config.services.orreryd.pushHost;
  pushArgs = lib.optionalString (pushHost != null) " --push-host ${pushHost}";
  metricsListen = config.services.orreryd.metricsListen;
  metricsArgs = lib.optionalString (metricsListen != null) " --metrics-listen ${metricsListen}";

  orreryd-start = pkgs.writeShellScript "orreryd-start" ''
    set -eu
    exec ${config.programs.orrery.package}/bin/orreryd${lib.optionalString sessions " --sessions --holder-scope /run/current-system/sw/bin/systemd-run"}${pushArgs}${metricsArgs}
  '';

  # The gate pool never bounds gate runs: hardware does. Remote gates queue on
  # the orrery-gate box for its own slots (nproc/20 full checks, nproc/8 light).
  # 64 members sits above what runs here at once.
  # Their member commands are `true`, so wake, status and admit do nothing.
  trueBin = "${pkgs.coreutils}/bin/true";
  gateMembers = 64;
  poolsFile = ''
    [pools.gate]
    host = "${hostname}"
    cap = ${toString gateMembers}
    members = [${lib.concatMapStringsSep ", " (i: "\"gate-${toString i}\"") (lib.range 1 gateMembers)}]
    wake = ["${trueBin}"]
    wake_limit = 5
    status = ["${trueBin}"]
    status_limit = 5
    admit = ["${trueBin}"]
    admit_limit = 5
  '';

  toolPath = lib.makeBinPath [pkgs.tmux pkgs.claudeCodeCli];
  # Session steps run the user's and the system's tools, not just tmux and claude.
  sessionPath = lib.concatStringsSep ":" [
    toolPath
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/run/current-system/sw/bin"
  ];
  path =
    if sessions
    then sessionPath
    else toolPath;
in {
  options.services.orreryd.sessions = lib.mkEnableOption "orreryd's headless engine session service";

  # Passed to orreryd as --push-host. Null leaves orreryd's default, ntfy.sh.
  options.services.orreryd.pushHost = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Push host orreryd accepts, passed as --push-host. Null keeps orreryd's default, ntfy.sh.";
  };

  # Passed to orreryd as --metrics-listen, a loopback IP literal with a port.
  # Null leaves orreryd's default, which serves no metrics.
  options.services.orreryd.metricsListen = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Loopback address orreryd serves /metrics on, passed as --metrics-listen. Null keeps orreryd's default, which serves no metrics.";
  };

  config.xdg.configFile = lib.optionalAttrs sessions {
    "orrery/pools.toml".text = poolsFile;
  };

  config.systemd.user.services.orreryd = {
    Unit.Description = "orrery daemon";
    Service = {
      ExecStart = "${orreryd-start}";
      # orreryd sends READY=1 once sessions.sock listens (or once its store
      # opens without sessions). 900 s is a chosen ceiling, not a worst case:
      # 36 holders at 30 s each to re-adopt would take 1080 s. A timed-out
      # start is retried; holders keep running in their own scopes, so the
      # retry has fewer to re-adopt.
      Type = "notify";
      TimeoutStartSec = 900;
      Restart = "always";
      # Each session's holder, with its agents and gates, runs in its own
      # orrery-hold-<session>.scope under app.slice, so orreryd's unit holds
      # orreryd alone and needs no memory cap of its own. OOMPolicy=continue
      # keeps the unit running if the kernel kills a process in it (the
      # default, stop, would end the unit).
      OOMPolicy = "continue";
      Environment = [
        "TMUX_TMPDIR=%t"
        "PATH=${path}"
      ];
    };
    Install.WantedBy = ["default.target"];
  };
}
