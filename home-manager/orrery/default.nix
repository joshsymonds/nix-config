{
  config,
  lib,
  pkgs,
  ...
}: let
  sessions = config.services.orreryd.sessions;

  # Sessions get three gate locks in orreryd's own runtime dir, which systemd
  # creates at each start (RuntimeDirectory below). They never share a heavy
  # wrapper slot.
  gateLocks = lib.concatMapStrings (n: " --gate-lock \"$XDG_RUNTIME_DIR/orreryd/gate-${toString n}.lock\"") [1 2 3];

  orreryd-start = pkgs.writeShellScript "orreryd-start" ''
    set -eu
    exec ${config.programs.orrery.package}/bin/orreryd${lib.optionalString sessions " --sessions --step-cap 16${gateLocks}"}
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

  config.systemd.user.services.orreryd = {
    Unit.Description = "orrery daemon";
    Service =
      {
        ExecStart = "${orreryd-start}";
        Restart = "always";
        # orreryd runs every headless agent and its gates as plain children
        # in this unit, so nothing else capped them: on 2026-11-12 one agent's
        # node test grew to 48 GB resident plus 43 GB swap on vermissian and
        # hung the host three times. At MemoryMax the kernel kills the largest
        # process inside the unit; OOMPolicy=continue keeps orreryd and the
        # other agents running (the default, stop, would end them all).
        # MemorySwapMax stops a runaway from grinding through swap first.
        MemoryHigh = "60%";
        MemoryMax = "66%";
        MemorySwapMax = "4G";
        OOMPolicy = "continue";
        Environment = [
          "TMUX_TMPDIR=%t"
          "PATH=${path}"
        ];
      }
      // lib.optionalAttrs sessions {RuntimeDirectory = "orreryd";};
    Install.WantedBy = ["default.target"];
  };
}
