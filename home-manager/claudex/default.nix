# "Claudex": Claude Code's harness running on GPT models from the ChatGPT
# subscription, via CLIProxyAPI translating the Anthropic Messages API to the
# Codex OAuth backend. Anthropic explicitly supports harness-with-other-models
# use; OpenAI's Codex lead published the pattern himself.
#
# The proxy runs as a user service bound to localhost. OAuth state lives in
# ~/.cli-proxy-api (mutable, like ~/.codex) — authenticate once per machine:
#   cli-proxy-api --config ~/.config/cliproxyapi/config.yaml --codex-login
# (or --codex-device-login on headless hosts; it prints a URL + code to enter
# from any browser).
#
# The api-key below only gates the localhost listener — it is not a secret in
# the agenix sense; anyone with local shell access already has ~/.codex creds.
{
  config,
  lib,
  pkgs,
  ...
}: let
  # Shared claudex coordinates (port/key/model ids) live in lib/claudex.nix
  # so home-manager/patchbay routes at the exact same values.
  # fastModel is the fast tier for haiku-slot work (summaries, small tool
  # calls). Confirmed present in the codex channel's /v1/models.
  claudexLib = import ../../lib/claudex.nix;
  inherit (claudexLib) port apiKey model fastModel;

  proxyConfig = (pkgs.formats.yaml {}).generate "cliproxyapi-config.yaml" {
    host = "127.0.0.1";
    inherit port;
    auth-dir = "~/.cli-proxy-api";
    api-keys = [apiKey];
    # Empty secret-key disables the management API and its control panel
    # (which otherwise auto-downloads a web UI from GitHub at runtime).
    remote-management = {
      allow-remote = false;
      secret-key = "";
      disable-control-panel = true;
    };
  };

  # ENABLE_TOOL_SEARCH=false and the tool-use concurrency cap follow the
  # published claudex recipe: GPT mishandles deferred-tool discovery and
  # over-parallelizes tool calls in this harness.
  claudex = pkgs.writeShellScriptBin "claudex" ''
    export ANTHROPIC_BASE_URL="http://127.0.0.1:${toString port}"
    export ANTHROPIC_AUTH_TOKEN="${apiKey}"
    export ANTHROPIC_MODEL="${model}"
    export ANTHROPIC_SMALL_FAST_MODEL="${fastModel}"
    export CLAUDE_CODE_SUBAGENT_MODEL="${model}"
    export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
    export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1
    export CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3
    export ENABLE_TOOL_SEARCH=false
    exec claude "$@"
  '';
in {
  home.packages = [pkgs.cliproxyapi claudex];

  xdg.configFile."cliproxyapi/config.yaml".source = proxyConfig;

  systemd.user.services.cli-proxy-api = {
    Unit = {
      Description = "CLIProxyAPI — Anthropic-compatible endpoint over the ChatGPT Codex subscription";
      After = ["network-online.target"];
      Wants = ["network-online.target"];
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.cliproxyapi} --config ${config.xdg.configHome}/cliproxyapi/config.yaml";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = ["default.target"];
  };
}
