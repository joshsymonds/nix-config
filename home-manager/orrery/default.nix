{
  config,
  hostname,
  lib,
  pkgs,
  ...
}: let
  sessions = config.services.orreryd.sessions;

  orreryd-start = pkgs.writeShellScript "orreryd-start" ''
    set -eu
    exec ${config.programs.orrery.package}/bin/orreryd${lib.optionalString sessions " --sessions --step-cap 16 --holder-scope /run/current-system/sw/bin/systemd-run"}
  '';

  # The gate pool's three members bound gate runs on this host. Their member
  # commands are `true`, so wake, status and admit do nothing.
  trueBin = "${pkgs.coreutils}/bin/true";
  poolsFile = ''
    [pools.gate]
    host = "${hostname}"
    cap = 3
    members = ["gate-1", "gate-2", "gate-3"]
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
      # orreryd's headless agents and gates used to run as plain children in
      # this unit, so nothing else capped them: on 2026-11-12 one agent's
      # node test grew to 48 GB resident plus 43 GB swap on vermissian and
      # hung the host three times. Where sessions run, each session's holder
      # now runs in its own orrery-hold-<session>.scope under app.slice,
      # capped per scope by home-manager/terminal-memory-cap. This cap bounds
      # orreryd and whatever stays in the unit. At MemoryMax the kernel kills
      # the largest process inside the unit; OOMPolicy=continue keeps orreryd
      # and the rest of the unit running (the default, stop, would end them
      # all). MemorySwapMax stops a runaway from grinding through swap first.
      MemoryHigh = "60%";
      MemoryMax = "66%";
      MemorySwapMax = "4G";
      OOMPolicy = "continue";
      Environment = [
        "TMUX_TMPDIR=%t"
        "PATH=${path}"
      ];
    };
    Install.WantedBy = ["default.target"];
  };
}
