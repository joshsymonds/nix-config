{
  lib,
  pkgs,
  ...
}: let
  compactTranscript = pkgs.fetchzip {
    url = "https://registry.npmjs.org/pi-compact-transcript/-/pi-compact-transcript-0.8.1.tgz";
    hash = "sha256-KdQZhE9fAo5ZSdQp44bmJ2Q9qCpF33Hknu+mGHc+A0k=";
  };

  piTasksSource = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@tintinweb/pi-tasks/-/pi-tasks-0.9.0.tgz";
    hash = "sha256-9mTixVJ37vG8w1RK6frUlRfXTi/7oApiAj5P1o98jh0=";
  };

  piSubagentsSource = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@tintinweb/pi-subagents/-/pi-subagents-0.19.0.tgz";
    hash = "sha256-xqbnZ8IQ4dpc1Wmkmt96Nye3XoEm1ECI434nGMrXBXk=";
  };

  piGoalSource = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@narumitw/pi-goal/-/pi-goal-0.54.3.tgz";
    hash = "sha256-Zw+7QW0g4Xk5EXhCwkB+fBXxe5+3nsfNLAyVuzP6v78=";
  };

  piLspSource = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@narumitw/pi-lsp/-/pi-lsp-0.49.7.tgz";
    hash = "sha256-v6NQ311vtZl2x0PAEkGCIDzR3IixEd1t0Bg5h3jzM9E=";
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

  sinclairTypebox = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@sinclair/typebox/-/typebox-0.34.49.tgz";
    hash = "sha256-Yr3Y1jq8pzUQFEOfHtZRZ/F1yhkHi2+riWLR4QC9AdA=";
  };

  croner = pkgs.fetchzip {
    url = "https://registry.npmjs.org/croner/-/croner-10.0.1.tgz";
    hash = "sha256-fZ+02mjadauHBt+bvQqBmeSBnOtdv6WDcYIw64IRInQ=";
  };

  nanoid = pkgs.fetchzip {
    url = "https://registry.npmjs.org/nanoid/-/nanoid-5.1.6.tgz";
    hash = "sha256-HkFkiir1M/ljs85odhual1WcVg2lNrmBOV60E4M9nNo=";
  };

  piTasks = pkgs.runCommand "pi-tasks-0.9.0" {} ''
    cp -r ${piTasksSource} $out
    chmod -R u+w $out
    mkdir -p $out/node_modules
    ln -s ${pkgs.pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/typebox $out/node_modules/typebox
  '';

  piSubagents = pkgs.runCommand "pi-subagents-0.19.0" {} ''
    cp -r ${piSubagentsSource} $out
    chmod -R u+w $out
    mkdir -p $out/node_modules/@sinclair
    ln -s ${sinclairTypebox} $out/node_modules/@sinclair/typebox
    ln -s ${croner} $out/node_modules/croner
    ln -s ${nanoid} $out/node_modules/nanoid
    ln -s ${pkgs.pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/typebox $out/node_modules/typebox
  '';

  piGoal = pkgs.runCommand "pi-goal-0.54.3" {} ''
    cp -r ${piGoalSource} $out
    chmod -R u+w $out
    mkdir -p $out/node_modules/@narumitw
    ln -s ${piTuiKit} $out/node_modules/@narumitw/pi-tui-kit
    ln -s ${grokMermaid} $out/node_modules/grok-mermaid
    ln -s ${highlightJs} $out/node_modules/highlight.js
    ln -s ${pkgs.pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/typebox $out/node_modules/typebox
  '';

  piLsp = pkgs.runCommand "pi-lsp-0.49.7" {} ''
    cp -r ${piLspSource} $out
    chmod -R u+w $out
    mkdir -p $out/node_modules
    ln -s ${pkgs.pi-coding-agent}/lib/node_modules/pi-monorepo/node_modules/typebox $out/node_modules/typebox
  '';

  inherit
    (import ../claude-code/gambit-rungs.nix {inherit lib pkgs;})
    piRungAgentEntries
    ;

  piRungAgents = pkgs.linkFarm "pi-gambit-rung-agents" piRungAgentEntries;
  workflowTools = import ./tool-packages {inherit lib pkgs;};
  browser = import ./agent-browser.nix {inherit lib pkgs;};
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
    package = pkgs.pi-coding-agent;

    settings = {
      defaultProvider = "openai-codex";
      defaultModel = "gpt-6-astra";
      defaultThinkingLevel = "high";
      enableSkillCommands = true;
      skills = ["~/Personal/gambit/skills"];
      packages = [
        "${piTasks}"
        "${piSubagents}"
        "${piGoal}"
        "${piLsp}"
        {
          source = "${workflowTools}/node_modules/@aliou/pi-processes";
          prompts = [];
          themes = [];
        }
        {
          source = "${workflowTools}/node_modules/pi-web-access";
          skills = [];
          prompts = [];
          themes = [];
        }
        {
          source = "${browser.extension}";
          skills = [];
          prompts = [];
          themes = [];
        }
      ];
    };

    context = builtins.readFile ./AGENTS.md;
  };

  home.file = {
    # ~/.local/bin is already on the login-shell PATH. Keep the native CLI
    # declarative without modifying Pi itself or downloading browsers at runtime.
    ".local/bin/agent-browser".source = "${browser.cli}/bin/agent-browser";
    ".pi/config/pi-agent-browser-native/config.json".text = builtins.toJSON {
      version = 1;
      webSearch.enabled = false;
      browser.executablePath = browser.chromiumExecutable;
    };
    # 0.28.0 uses the legacy ~/.pi path; XDG and explicit agent-dir launches
    # select the other locations. All three contain the same non-secret defaults.
    ".pi/web-search.json".source = ./web-search.json;
    ".config/pi/web-search.json".source = ./web-search.json;
    ".pi/agent/web-search.json".source = ./web-search.json;
    ".pi/agent/extensions/processes.json".text = builtins.toJSON {
      version = "0.10.6";
      execution.shellPath = "${pkgs.bash}/bin/bash";
      interception.blockBackgroundCommands = false;
      widget = {
        showStatusWidget = false;
        dockDefaultState = "closed";
      };
    };
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
    ".pi/agent/extensions/cc-tools.ts".source = ./cc-tools.ts;
    ".pi/agent/extensions/compact-transcript.ts".source = "${compactTranscript}/extensions/compact-transcript.ts";
    ".pi/agent/agents".source = piRungAgents;
    ".pi/agent/tasks-config.json".text = builtins.toJSON {
      taskScope = "session-global";
      autoCascade = false;
      autoClearCompleted = "never";
    };
    # Reuse language servers already installed by home-manager/helix. This
    # explicit map replaces upstream defaults (which use ty/biome instead).
    # Gambit rung agents intentionally keep --no-extensions; LSP is available
    # to the parent, not silently injected into read-only/isolated workers.
    ".pi/agent/pi-lsp.json".text = builtins.toJSON {
      timeout = 30000;
      servers = {
        nixd = {
          command = ["nixd"];
          extensions = [".nix"];
          # Diagnostics only: do not import/evaluate any host closure or the
          # editor's expensive NixOS/Home Manager option-completion expressions.
          initialization.nixd = {
            nixpkgs.expr = "{}";
            options = {};
          };
        };
        pyright = {
          command = ["pyright-langserver" "--stdio"];
          extensions = [".py" ".pyi"];
        };
        typescript = {
          command = ["typescript-language-server" "--stdio"];
          extensions = [".ts" ".tsx" ".mts" ".cts" ".js" ".jsx" ".mjs" ".cjs"];
          initialization = {
            disableAutomaticTypingAcquisition = true;
            tsserver.path = "${pkgs.typescript}/lib/node_modules/typescript/lib/tsserver.js";
          };
        };
        gopls = {
          command = ["gopls"];
          extensions = [".go"];
        };
      };
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
