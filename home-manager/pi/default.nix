{
  inputs,
  lib,
  pkgs,
  ...
}: let
  system = pkgs.stdenv.hostPlatform.system;
  stewardPackage = inputs.steward.packages.${system}.default;
  stewardRuntime = inputs.steward.packages.${system}.steward-pi-runtime;

  compactTranscript = pkgs.fetchzip {
    url = "https://registry.npmjs.org/pi-compact-transcript/-/pi-compact-transcript-0.8.1.tgz";
    hash = "sha256-KdQZhE9fAo5ZSdQp44bmJ2Q9qCpF33Hknu+mGHc+A0k=";
  };

  piTasksSource = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@tintinweb/pi-tasks/-/pi-tasks-0.9.0.tgz";
    hash = "sha256-9mTixVJ37vG8w1RK6frUlRfXTi/7oApiAj5P1o98jh0=";
  };

  piGoalSource = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@narumitw/pi-goal/-/pi-goal-0.54.3.tgz";
    hash = "sha256-Zw+7QW0g4Xk5EXhCwkB+fBXxe5+3nsfNLAyVuzP6v78=";
  };

  piTuiKit = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@narumitw/pi-tui-kit/-/pi-tui-kit-0.59.0.tgz";
    hash = "sha256-dMzOHA7jxKShvU2okzNt7qRNm/5ONa+05ZkcfVTALbI=";
  };

  grokMermaid = pkgs.fetchzip {
    url = "https://registry.npmjs.org/grok-mermaid/-/grok-mermaid-0.2.3.tgz";
    hash = "sha256-tT9tKcotpywP98aI4H8AJZa6cikj9adGFZpialQ0Dxk=";
  };

  highlightJs = pkgs.fetchzip {
    url = "https://registry.npmjs.org/highlight.js/-/highlight.js-11.12.0.tgz";
    hash = "sha256-fcEJdFLzFkMR1rlm9sPVCr6A8YhUgm6+JNlLjMIrHk0=";
  };

  piTasks = pkgs.runCommand "pi-tasks-0.9.0" {} ''
    cp -r ${piTasksSource} $out
    chmod -R u+w $out
    mkdir -p $out/node_modules
    ln -s ${stewardRuntime.nodeModules}/typebox $out/node_modules/typebox
  '';

  piGoal = pkgs.runCommand "pi-goal-0.54.3" {} ''
    cp -r ${piGoalSource} $out
    chmod -R u+w $out
    mkdir -p $out/node_modules/@narumitw
    ln -s ${piTuiKit} $out/node_modules/@narumitw/pi-tui-kit
    ln -s ${grokMermaid} $out/node_modules/grok-mermaid
    ln -s ${highlightJs} $out/node_modules/highlight.js
    ln -s ${stewardRuntime.nodeModules}/typebox $out/node_modules/typebox
  '';

  inherit
    (import ../claude-code/gambit-rungs.nix {inherit lib pkgs;})
    piRungAgentEntries
    ;

  piRungAgents = pkgs.linkFarm "pi-gambit-rung-agents" piRungAgentEntries;
in {
  # The omakase gateway (Klover's LLM front door) as a first-class Pi
  # provider. LiteLLM speaks Anthropic Messages, so no adapter is needed. The
  # two aliases are the whole menu: `everyday` (GLM 5.3 Flash via Together,
  # reasoning pinned to medium) and `deep` (GPT-5.6 Sol via Azure US, pinned
  # to xhigh). The gateway ignores Pi's thinking parameter, so a thinking
  # level here is documentation, not control. The key is a personal one from
  # https://omakase.kloverinfrastructure.com, agenix-decrypted per login into
  # $XDG_RUNTIME_DIR/agenix and read through Pi's "!command" resolver, which
  # runs under a shell so the variable expands. Which projects default to
  # this provider is decided by the `pi` shell function (home-manager/zsh)
  # and a per-tree .pi-args file, not here.
  age.secrets."omakase-key".file = ../../secrets/user/omakase-key.age;

  programs.pi-coding-agent = {
    enable = true;
    package = stewardPackage;

    settings = {
      defaultProvider = "openai-codex";
      defaultModel = "gpt-6-astra";
      defaultThinkingLevel = "high";
      enableSkillCommands = true;
      skills = ["~/Personal/gambit/skills"];
      packages = [
        "${piTasks}"
        "${stewardRuntime.extensionRoot}"
        "${piGoal}"
      ];
    };

    context = ''
      # Response style

      - Be terse by default: keep final responses under 120 words or 8 lines.
      - Lead with the result. Do not restate the request or narrate routine tool use.
      - For code changes, report only the files changed and verification performed.
      - Expand only when the user asks, critical context would otherwise be lost, or an active workflow requires a structured artifact.
    '';
  };

  home.file = {
    ".pi/agent/models.json".text = builtins.toJSON {
      # Merge GPT-6 Astra into the built-in openai-codex provider (pi 0.85.0
      # predates it). Cloned from pi's own gpt-5.6-sol entry; pricing from
      # developers.openai.com/api/docs/models/gpt-6-astra (2x input / 1.5x
      # output above 272K input).
      providers.openai-codex.models = [
        {
          id = "gpt-6-astra";
          name = "GPT-6 Astra";
          api = "openai-codex-responses";
          reasoning = true;
          input = ["text" "image"];
          cost = {
            input = 10;
            output = 50;
            cacheRead = 1;
            cacheWrite = 12.5;
            tiers = [
              {
                inputTokensAbove = 272000;
                input = 20;
                output = 75;
                cacheRead = 2;
                cacheWrite = 25;
              }
            ];
          };
          contextWindow = 272000;
          maxTokens = 128000;
          thinkingLevelMap = {
            xhigh = "xhigh";
            max = "max";
            minimal = "low";
          };
          compat = {
            supportsOpenAIGrammarTools = true;
            supportsAdditionalTools = true;
            supportsToolSearch = true;
          };
        }
      ];
      providers.omakase = {
        name = "omakase";
        baseUrl = "https://llm.kloverinfrastructure.com";
        api = "anthropic-messages";
        apiKey = "!cat \"$XDG_RUNTIME_DIR/agenix/omakase-key\"";
        models = [
          {
            id = "everyday";
            name = "everyday";
            reasoning = true;
            contextWindow = 1048575;
            maxTokens = 131072;
          }
          {
            id = "deep";
            name = "deep";
            reasoning = true;
            contextWindow = 1050000;
            maxTokens = 128000;
          }
        ];
      };
    };
    ".pi/agent/extensions/compact-transcript.ts".source = "${compactTranscript}/extensions/compact-transcript.ts";
    ".pi/agent/agents".source = piRungAgents;
    ".pi/agent/tasks-config.json".text = builtins.toJSON {
      taskScope = "session-global";
      autoCascade = false;
      autoClearCompleted = "never";
    };
    ".pi/agent/pi-goal.json".text = builtins.toJSON {
      rpc.enabled = false;
      continuationLimits = {
        automaticTurns = null;
        noProgressTurns = 3;
      };
    };
    ".pi/agent/subagents.json".text = builtins.toJSON {
      backgroundByDefault = false;
      strictAgentFiles = true;
      fallbackSubagent = "none";
      workflowsEnabled = false;
      schedulingEnabled = false;
    };
  };
}
