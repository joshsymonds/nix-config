{
  config,
  lib,
  pkgs,
  ...
}: {
  # Loopback listener only. Any exposure is configured elsewhere, never here.
  systemd.user.services.orrery-serve = {
    Unit.Description = "orrery serve";
    Service = {
      ExecStart = "${config.programs.orrery.package}/bin/orrery serve --listen 127.0.0.1:8489 --allow-login josh@joshsymonds.com --push-host ntfy.sh";
      Restart = "always";
      Environment = ["PATH=${lib.makeBinPath [pkgs.tmux]}"];
    };
    Install.WantedBy = ["default.target"];
  };
}
