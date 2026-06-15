# Runs the Savecraft daemon as a systemd user service. The daemon watches
# the game-save directories advertised by the plugins it downloads (e.g.
# Satisfactory's Steam/Proton SaveGames path) and pushes parsed save state
# to the Savecraft backend over a WebSocket.
#
# It is a per-user daemon by design: it self-registers on first run and
# stores its source token under ~/.config/savecraft, watches files under the
# user's $HOME, and needs no root. On first start it registers a new source;
# link it to your account from the Savecraft web UI (the daemon logs the
# pairing URL). Switching `server` makes it re-register — the stored token is
# per-backend.
#
# No lingering: the service is tied to the login session, which is when the
# games actually run and write saves. Set users.users.<name>.linger = true
# in the host config if you want it to keep running headless.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  cfg = config.services.savecraftd;
  serverUrls = {
    production = "https://api.savecraft.gg";
    staging = "https://staging-api.savecraft.gg";
  };
in {
  options.services.savecraftd = {
    enable = lib.mkEnableOption "the Savecraft save-watching daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.savecraft.packages.${pkgs.stdenv.hostPlatform.system}.savecraftd;
      defaultText = lib.literalExpression "inputs.savecraft.packages.\${system}.savecraftd";
      description = "The savecraftd package to run.";
    };

    server = lib.mkOption {
      type = lib.types.enum ["production" "staging"];
      default = "production";
      description = ''
        Which Savecraft backend to register with and push saves to.
        "production" links this machine to your real account; "staging" is
        for validating the pipeline without touching production data.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Expose the CLI too, so `savecraftd verify` / `savecraftd setup` and
    # friends are on PATH for manual inspection.
    home.packages = [cfg.package];

    systemd.user.services.savecraftd = {
      Unit = {
        Description = "Savecraft daemon — watches game saves and pushes them to Savecraft";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };
      Service = {
        ExecStart = "${lib.getExe cfg.package} run";
        Restart = "on-failure";
        RestartSec = 10;
        Environment = ["SAVECRAFT_SERVER_URL=${serverUrls.${cfg.server}}"];
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
