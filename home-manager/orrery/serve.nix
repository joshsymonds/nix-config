{
  config,
  lib,
  pkgs,
  ...
}: let
  # orrery serve runs --host-status-cmd with no arguments and no shell, so it
  # gets a store path to a wrapper that execs the tmux status widget as JSON.
  hostStatusCmd = pkgs.writeShellScript "orrery-host-status" ''
    exec ${config.programs.tmux-status.package}/bin/tmux-status --json
  '';

  # The one push host for orreryd and orrery serve on this machine.
  pushHost = "vermissian.tail82223.ts.net";
in {
  # serve drives the headless sessions, so the host that runs it runs them.
  services.orreryd.sessions = true;
  services.orreryd.pushHost = pushHost;

  # Loopback listener only. Any exposure is configured elsewhere, never here.
  systemd.user.services.orrery-serve = {
    Unit.Description = "orrery serve";
    Service = {
      ExecStart = "${config.programs.orrery.package}/bin/orrery serve --listen 127.0.0.1:8489 --allow-login josh@joshsymonds.com --push-host ${pushHost} --host-status-cmd ${hostStatusCmd}";
      Restart = "always";
      Environment = [
        "TMUX_TMPDIR=%t"
        "PATH=${lib.makeBinPath [pkgs.tmux pkgs.claudeCodeCli]}"
      ];
    };
    Install.WantedBy = ["default.target"];
  };
}
