{
  config,
  lib,
  pkgs,
  ...
}: let
  # Literal agenix-hm paths; the strings contain "${XDG_RUNTIME_DIR}" verbatim
  # (home-manager agenix doesn't pre-resolve it). systemd Environment= won't
  # expand that, but the wrapper's shell will, and XDG_RUNTIME_DIR is always in
  # the user-service environment.
  ntfyUrlFile = config.age.secrets."ntfy-url".path;
  ntfyTokenFile = config.age.secrets."ntfy-token".path;

  orreryd-start = pkgs.writeShellScript "orreryd-start" ''
    set -eu
    export ORRERY_NTFY_URL_FILE="${ntfyUrlFile}"
    export ORRERY_NTFY_TOKEN_FILE="${ntfyTokenFile}"
    exec ${config.programs.orrery.package}/bin/orreryd
  '';
in {
  systemd.user.services.orreryd = {
    Unit.Description = "orrery daemon";
    Service = {
      ExecStart = "${orreryd-start}";
      Restart = "always";
      Environment = ["PATH=${lib.makeBinPath [pkgs.tmux pkgs.claudeCodeCli]}"];
    };
    Install.WantedBy = ["default.target"];
  };
}
