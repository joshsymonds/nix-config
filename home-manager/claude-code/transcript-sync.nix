# Nightly append-only copy of the local Claude and Codex transcripts to the NAS
# bucket. transcript-sync.sh holds the copy logic; this module installs it with
# its user service and timer.
{pkgs, ...}: let
  transcriptSync = pkgs.writeShellApplication {
    name = "transcript-sync";
    runtimeInputs = with pkgs; [coreutils diffutils findutils rsync util-linux];
    text = builtins.readFile ./transcript-sync.sh;
  };
in {
  home.packages = [transcriptSync];

  systemd.user.services.transcript-sync = {
    Unit = {
      Description = "Copy local transcripts to the NAS bucket";
      After = ["network-online.target"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${transcriptSync}/bin/transcript-sync sync";
    };
  };

  systemd.user.timers.transcript-sync = {
    Unit.Description = "Copy local transcripts to the NAS bucket nightly at 03:45";
    Timer = {
      OnCalendar = "*-*-* 03:45:00";
      Persistent = true;
      Unit = "transcript-sync.service";
    };
    Install.WantedBy = ["timers.target"];
  };
}
