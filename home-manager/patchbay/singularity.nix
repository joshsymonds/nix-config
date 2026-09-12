# Imported only by Vermissian. The beta's Chat Completions API works, but
# its Anthropic Messages adapter fails (2026-09-12), so Claude Code needs a
# local translator. Pi uses Chat Completions directly. Neither path changes
# the default model or sends unrelated traffic to the beta.
{
  config,
  pkgs,
  ...
}: let
  model = "deepseek-ai/DeepSeek-V4.1-Flash";
  alias = "deepseek-v4.1-flash";
  baseUrl = "https://beta.singularityapi.tech/v1";
  keyFile = "${config.xdg.configHome}/patchbay/singularity.key";
  port = 8318;
  listenerKey = "patchbay-singularity-local";
  listenerKeyFile = pkgs.writeText "patchbay-singularity-listener-key" listenerKey;

  proxyConfig = {
    host = "127.0.0.1";
    inherit port;
    # Isolated from the existing Codex proxy's OAuth credential directory.
    auth-dir = "${config.xdg.stateHome}/singularity-proxy/auth";
    api-keys = [listenerKey];
    request-retry = 0;
    remote-management = {
      allow-remote = false;
      secret-key = "";
      disable-control-panel = true;
    };
    openai-compatibility = [
      {
        name = "singularity";
        base-url = baseUrl;
        models = [
          {
            name = model;
            inherit alias;
          }
        ];
      }
    ];
  };
  template = (pkgs.formats.json {}).generate "singularity-proxy-template.json" proxyConfig;
  # Only the template and key PATH enter the Nix store. The credential-bearing
  # config is regenerated privately in /run/user/<uid> at service start.
  prepare = pkgs.writeShellScript "singularity-proxy-prepare" ''
    set -eu
    umask 077
    ${pkgs.jq}/bin/jq --rawfile key ${libKeyFile} \
      '."openai-compatibility"[0]."api-key-entries" = [{"api-key": ($key | gsub("^\\s+|\\s+$"; ""))}]' \
      ${template} > "$RUNTIME_DIRECTORY/config.json"
  '';
  libKeyFile = pkgs.lib.escapeShellArg keyFile;
in {
  services.patchbay.extraSeats."singularity/deepseek-flash" = {
    upstream = "http://127.0.0.1:${toString port}";
    auth_mode = "inject";
    billing = "metered";
    api_key_env_file = "PATCHBAY_SINGULARITY_KEY_FILE";
    model = alias;
    strip_cache_control = true;
    # Conservative client limits until the beta publishes its serving limits.
    max_input_tokens = 128000;
  };
  systemd.user.services.patchbay.Service.Environment = [
    "PATCHBAY_SINGULARITY_KEY_FILE=${listenerKeyFile}"
  ];

  systemd.user.services.singularity-proxy = {
    Unit = {
      Description = "Singularity beta Chat Completions translator for patchbay";
      After = ["network-online.target"];
      Wants = ["network-online.target"];
      ConditionPathExists = keyFile;
    };
    Service = {
      ExecStartPre = "${prepare}";
      ExecStart = "${pkgs.cliproxyapi}/bin/cli-proxy-api --config %t/singularity-proxy/config.json";
      RuntimeDirectory = "singularity-proxy";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = ["default.target"];
  };

  programs.pi-coding-agent.models.providers.singularity = {
    inherit baseUrl;
    api = "openai-completions";
    apiKey = "!${pkgs.coreutils}/bin/cat ${libKeyFile}";
    compat = {
      supportsStore = false;
      supportsDeveloperRole = false;
      supportsStrictMode = false;
      maxTokensField = "max_tokens";
      thinkingFormat = "deepseek";
      requiresReasoningContentOnAssistantMessages = true;
    };
    models = [
      {
        id = model;
        name = "DeepSeek V4.1 Flash (Singularity beta)";
        reasoning = true;
        input = ["text"];
        # Serving limits and pricing are not published by this beta. These are
        # conservative client caps, not claims about the model's full window.
        contextWindow = 128000;
        maxTokens = 16384;
        thinkingLevelMap = {
          minimal = null;
          low = null;
          medium = null;
          high = "high";
          xhigh = null;
        };
      }
    ];
  };
}
