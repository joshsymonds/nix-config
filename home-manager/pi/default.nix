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

  piLspSource = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@narumitw/pi-lsp/-/pi-lsp-0.49.7.tgz";
    hash = "sha256-v6NQ311vtZl2x0PAEkGCIDzR3IixEd1t0Bg5h3jzM9E=";
  };

  piTasks = pkgs.runCommand "pi-tasks-0.9.0" {} ''
    cp -r ${piTasksSource} $out
    chmod -R u+w $out
    mkdir -p $out/node_modules
    ln -s ${stewardRuntime.nodeModules}/typebox $out/node_modules/typebox
  '';

  piGoal = import ./pi-goal.nix {
    inherit pkgs;
    nodeModules = stewardRuntime.nodeModules;
  };

  piLsp = pkgs.runCommand "pi-lsp-0.49.7" {} ''
    cp -r ${piLspSource} $out
    chmod -R u+w $out
    mkdir -p $out/node_modules
    ln -s ${stewardRuntime.nodeModules}/typebox $out/node_modules/typebox
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
  # Web search resolves this at request time; only its path enters the store.
  age.secrets."tavily-key".file = ../../secrets/user/tavily-key.age;

  programs.pi-coding-agent = {
    enable = true;
    package = stewardPackage;

    models.providers.omakase = {
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
    ".pi/agent/extensions/compact-transcript.ts".source = "${compactTranscript}/extensions/compact-transcript.ts";
    ".pi/agent/agents".source = piRungAgents;
    ".pi/agent/tasks-config.json".text = builtins.toJSON {
      taskScope = "session-global";
      autoCascade = false;
      autoClearCompleted = "never";
    };
    # Reuse language servers already installed by home-manager/helix. This
    # explicit map replaces upstream defaults (which use ty/biome instead).
    # Gambit leaf agents keep extensions off except the writing fast-tier hook.
    # Orchestrators explicitly load task/process tools; LSP stays available to
    # the parent, not silently injected into read-only/isolated workers.
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
        noProgressTurns = null;
      };
    };
    ".pi/agent/subagents.json".text = builtins.toJSON {
      # Dispatch detached unless the call says otherwise (pi-subagents' own
      # default, matching Claude Code's Agent tool): the call returns an id,
      # the parent's turn ends, and the completion notification wakes it. The
      # 2026-09-06 gpt-6-astra savecraft session ran with `false`: its 85
      # unqualified Agent calls held the parent's turn for 9.6 hours in total
      # (avg 6.8 min, max 79 min on one sol-xhigh), and the four longest
      # text-free stretches (69-85 min each) were exactly those waits.
      backgroundByDefault = true;
      # Show every running child in the above-editor widget, including any
      # explicit foreground run (the default hides those), with its live tool
      # activity and token counts.
      widgetMode = "all";
      strictAgentFiles = true;
      fallbackSubagent = "none";
      workflowsEnabled = false;
      schedulingEnabled = false;
    };
  };
}
