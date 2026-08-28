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

  inherit
    (import ../claude-code/gambit-rungs.nix {inherit lib pkgs;})
    piRungAgentEntries
    ;

  piRungAgents = pkgs.linkFarm "pi-gambit-rung-agents" piRungAgentEntries;
in {
  programs.pi-coding-agent = {
    enable = true;
    package = pkgs.pi-coding-agent;

    settings = {
      defaultProvider = "openai-codex";
      defaultModel = "gpt-5.6-sol";
      defaultThinkingLevel = "high";
      enableSkillCommands = true;
      skills = ["~/Personal/gambit/skills"];
      packages = [
        "${piTasks}"
        "${piSubagents}"
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
    ".pi/agent/extensions/cc-tools.ts".source = ./cc-tools.ts;
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
