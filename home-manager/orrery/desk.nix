# gnomon-only: the desktop end of the coding-agent notifications. `orrery desk`
# follows the orreryd hosts listed below and shows each event as a libnotify
# popup with the notification tick. It runs ssh, notify-send, pw-play and tmux
# from PATH, so PATH carries exactly those tools plus the orrery package itself.
{
  config,
  lib,
  pkgs,
  ...
}: let
  orrery = config.programs.orrery.package;
  sounds = pkgs.claude-notify-sounds;
in {
  systemd.user.services.orrery-desk = {
    Unit = {
      Description = "orrery desk: coding-agent popups and chime";
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${orrery}/bin/orrery desk --sound ${sounds}/tick.wav --host vermissian --host ultraviolet";
      Restart = "always";
      RestartSec = 5;
      Environment = [
        "TMUX_TMPDIR=%t"
        "PATH=${lib.makeBinPath [pkgs.libnotify pkgs.pipewire pkgs.openssh pkgs.tmux orrery]}"
      ];
    };
    Install.WantedBy = ["graphical-session.target"];
  };
}
