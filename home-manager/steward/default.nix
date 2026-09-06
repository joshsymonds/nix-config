{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
  steward = inputs.steward.packages.${system}.default;
  stewardRuntime = inputs.steward.packages.${system}.steward-pi-runtime;
  patchbayBaseUrl =
    if (config.services.patchbay.enable or false)
    then "http://127.0.0.1:${toString config.services.patchbay.port}"
    else null;
in {
  config = {
    age.secrets = {
      "ntfy-url".file = ../../secrets/user/ntfy-url.age;
      "ntfy-token".file = ../../secrets/user/ntfy-token.age;
    };

    home = {
      packages = [steward];

      sessionVariables = {
        STEWARD_HELPER_BIN = lib.mkDefault "${stewardRuntime}/bin/steward-pi-helper";
        STEWARD_MODEL_PROVIDER = lib.mkDefault "openai-codex";
        STEWARD_MODEL_ID = lib.mkDefault "gpt-5.6-luna";
        STEWARD_MODEL_THINKING = lib.mkDefault "low";
        STEWARD_NTFY_URL_FILE = config.age.secrets."ntfy-url".path;
        STEWARD_NTFY_TOKEN_FILE = config.age.secrets."ntfy-token".path;
        STEWARD_STATE_FILE = lib.mkDefault "${config.xdg.cacheHome}/steward/state.json";
      }
      // lib.optionalAttrs (patchbayBaseUrl != null) {
        STEWARD_PATCHBAY_URL = patchbayBaseUrl;
        PATCHBAY_CALLER_KEY_FILE = "/run/agenix/patchbay-caller-key";
      };
    };

    systemd.user.services.steward-notifyd = {
      Unit = {
        Description = "Steward notification daemon";
        After = ["default.target"];
      };
      Service = {
        ExecStart = pkgs.writeShellScript "steward-notifyd-start" ''
          set -eu
          STEWARD_NTFY_URL="$(cat "${config.age.secrets."ntfy-url".path}")"
          STEWARD_NTFY_TOKEN="$(cat "${config.age.secrets."ntfy-token".path}")"
          export STEWARD_NTFY_URL STEWARD_NTFY_TOKEN
          export STEWARD_HELPER_BIN=${lib.escapeShellArg config.home.sessionVariables.STEWARD_HELPER_BIN}
          export STEWARD_MODEL_PROVIDER=${lib.escapeShellArg config.home.sessionVariables.STEWARD_MODEL_PROVIDER}
          export STEWARD_MODEL_ID=${lib.escapeShellArg config.home.sessionVariables.STEWARD_MODEL_ID}
          export STEWARD_MODEL_THINKING=${lib.escapeShellArg config.home.sessionVariables.STEWARD_MODEL_THINKING}
          exec ${steward}/bin/steward notifyd
        '';
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "PATH=${lib.makeBinPath [steward pkgs.tmux pkgs.git pkgs.coreutils]}"
        ];
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
