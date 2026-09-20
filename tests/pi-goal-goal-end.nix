{
  pkgs,
  piGoalSettings,
  nodeModules,
}: let
  piGoal = import ../home-manager/pi/pi-goal.nix {inherit pkgs nodeModules;};
  settings = pkgs.writeText "pi-goal-settings.json" piGoalSettings;
in
  pkgs.runCommand "pi-goal-goal-end-check" {} ''
    set -euo pipefail

    bundle=${piGoal}/dist/index.ts
    grep -qF 'const goalEndTool = defineTool({' "$bundle" || {
      echo "pi-goal bundle does not define goalEndTool" >&2
      exit 1
    }
    grep -qF 'name: "goal_end",' "$bundle" || {
      echo "goalEndTool is not named goal_end" >&2
      exit 1
    }
    grep -qF 'outcome: Type.Union([Type.Literal("ended_with_gaps"), Type.Literal("stopped_on_catastrophe")]),' "$bundle" || {
      echo "goal_end outcome enum is not exactly ended_with_gaps and stopped_on_catastrophe" >&2
      exit 1
    }
    grep -qF 'pi.registerTool(goalEndTool);' "$bundle" || {
      echo "goalEndTool is not registered" >&2
      exit 1
    }

    grep -qF '"automaticTurns":25' ${settings} || {
      echo "pi-goal automaticTurns limit is not 25" >&2
      exit 1
    }
    grep -qF '"noProgressTurns":3' ${settings} || {
      echo "pi-goal noProgressTurns limit is not 3" >&2
      exit 1
    }

    # Pi loads this generated .ts entry through Jiti. Plain Node cannot execute
    # it without a TypeScript loader, so deployed-system smoke covers behavior.
    touch "$out"
  ''
