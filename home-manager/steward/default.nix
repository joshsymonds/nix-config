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

      sessionVariables =
        {
          STEWARD_HELPER_BIN = lib.mkDefault "${stewardRuntime}/bin/steward-pi-helper";
          STEWARD_MODEL_PROVIDER = lib.mkDefault "openai-codex";
          STEWARD_MODEL_ID = lib.mkDefault "gpt-6-luna";
          # Medium, not low: at low, gpt-6-luna broke the compose contract's
          # 3-4 word label rule in 4 of 16 helper runs (2026-09-22); at medium
          # it passed 16 of 16. gpt-5.6-luna held the rule at low.
          STEWARD_MODEL_THINKING = lib.mkDefault "medium";
          STEWARD_NTFY_URL_FILE = config.age.secrets."ntfy-url".path;
          STEWARD_NTFY_TOKEN_FILE = config.age.secrets."ntfy-token".path;
          STEWARD_STATE_FILE = lib.mkDefault "${config.xdg.cacheHome}/steward/state.json";
        }
        // lib.optionalAttrs (patchbayBaseUrl != null) {
          STEWARD_PATCHBAY_URL = patchbayBaseUrl;
          PATCHBAY_CALLER_KEY_FILE = "/run/agenix/patchbay-caller-key";
        };
    };
  };
}
