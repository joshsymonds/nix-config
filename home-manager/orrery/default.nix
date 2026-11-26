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
  # The gateway orreryd sends Claude traffic through, on the same host as
  # claude-code's claudeBaseUrl. `or false` keeps hosts without gateway.nix
  # evaluating as they do today.
  gatewayArgs = lib.optionalString (config.services.orreryGateway.serveClaude or false) " --gateway http://127.0.0.1:${toString config.services.orreryGateway.port}";

  orreryd-start = pkgs.writeShellScript "orreryd-start" ''
    set -eu
    exec ${config.programs.orrery.package}/bin/orreryd${lib.optionalString sessions " --sessions --holder-scope /run/current-system/sw/bin/systemd-run"}${pushArgs}${metricsArgs}${gatewayArgs}
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
  # /run/wrappers/bin comes before the system profile so `sudo` resolves to the
  # setuid wrapper, as in a login shell: a release step that runs `update` under
  # orreryd's PATH otherwise finds the store's non-setuid sudo and fails.
  sessionPath = lib.concatStringsSep ":" [
    toolPath
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/run/wrappers/bin"
    "/run/current-system/sw/bin"
  ];
  path =
    if sessions
    then sessionPath
    else toolPath;

  # An agent runs `orrery node` in place of orreryd: both bind the daemon
  # socket and notices.sock, so a host runs one or the other.
  fleet = config.services.orreryFleet;
  node = config.services.orreryNode.enable;
  nodeRoots = lib.concatMapStringsSep " " (root: "--root ${config.home.homeDirectory}/${root}") fleet.agentRoots;
  nodeExecStart = "${config.programs.orrery.package}/bin/orrery node --controller ${fleet.controller} --relay ${fleet.addresses.${fleet.controller}}:${toString fleet.relayPort} --listen ${fleet.addresses.${hostname}}:${toString fleet.agentPort} ${nodeRoots} --holder-scope /run/current-system/sw/bin/systemd-run --secret-file ${fleet.secretFile}";
in {
  imports = [./fleet.nix];

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

  config.assertions = [
    {
      assertion = !(node && hostname == fleet.controller);
      message = "services.orreryNode.enable refuses the controller host ${fleet.controller}: the controller runs orreryd, which binds the sockets orrery node binds.";
    }
  ];

  config.systemd.user.services.orrery-node = lib.mkIf node {
    Unit = {
      Description = "orrery node: agent of the fleet controller";
      StartLimitIntervalSec = 0;
    };
    Service = {
      ExecStart = nodeExecStart;
      Restart = "always";
      RestartSec = 5;
      OOMPolicy = "continue";
      Environment = [
        "TMUX_TMPDIR=%t"
        "PATH=${sessionPath}"
      ];
    };
    Install.WantedBy = ["default.target"];
  };

  config.systemd.user.services.orreryd = lib.mkIf (!node) {
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
