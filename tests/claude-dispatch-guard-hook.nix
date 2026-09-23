# Behavioural check for the PreToolUse hook that validates Gambit Implementer
# dispatches before Claude Code launches them.
{
  pkgs,
  renderedSettings,
}: let
  hook = ../home-manager/claude-code/hooks/gambit-dispatch-guard.py;
  settingsJson = ../home-manager/claude-code/settings.json;
  defaultNix = ../home-manager/claude-code/default.nix;
in
  pkgs.runCommand "claude-dispatch-guard-hook-check" {
    nativeBuildInputs = [pkgs.jq pkgs.python3];
  } ''
        set -euo pipefail
        result_path="$out"

        fail() {
          echo "claude-dispatch-guard-hook: $1" >&2
          exit 1
        }

        export HOME="$PWD/fakehome"
        export GAMBIT_MODELS="$PWD/models.json"
        export GAMBIT_VALIDATE_DISPATCH="$PWD/validator.py"
        export MARKER="$PWD/validator-args"
        mkdir -p "$HOME" "$PWD/workspace"
        : > "$PWD/brief.md"
        : > "$PWD/state.json"

        # Keep this registry independent of the installed roster. The
        # Implementer is entry-only, while test-runner and another profile
        # exercise dispatches that the Implementer guard must exempt.
        cat > "$GAMBIT_MODELS" <<'JSON'
        {
          "profiles": {
            "implementer-profile": {"agent": "implementer-agent"},
            "test-profile": {"agent": "test-runner-agent"},
            "other-profile": {"agent": "other-agent"}
          },
          "roles": {
            "implementer": {"entry": "implementer-profile"},
            "test-runner": {"entry": "test-profile"}
          }
        }
    JSON

        cat > "$GAMBIT_VALIDATE_DISPATCH" <<'PY'
    import os
    import pathlib
    import sys

    pathlib.Path(os.environ["MARKER"]).write_text("\n".join(sys.argv[1:]))
    if os.environ.get("FAIL") == "1":
        print("stub validator rejected dispatch", file=sys.stderr)
        raise SystemExit(7)
    PY

        dispatch_json() {
          ${pkgs.jq}/bin/jq -cn \
            --arg tool "$1" --arg agent "$2" --arg prompt "$3" \
            '{tool_name:$tool,tool_input:{subagent_type:$agent,prompt:$prompt}}'
        }

        run_hook() {
          dispatch_json "$@" | ${pkgs.python3}/bin/python3 ${hook}
        }

        prompt="Brief: $PWD/brief.md
    Workspace: $PWD/workspace
    Record: $PWD/state.json
    Task: task-123"

        # Other tools never reach the dispatch guard, even with an Implementer.
        out=$(run_hook Bash implementer-agent "no marker")
        test -z "$out" || fail "non-Agent/Task tool was denied: $out"

        # Agents outside the Implementer entry remain untouched, including the
        # explicit test-runner role.
        out=$(run_hook Agent other-agent "no marker")
        test -z "$out" || fail "non-Implementer profile was denied: $out"
        out=$(run_hook Agent test-runner-agent "no marker")
        test -z "$out" || fail "test-runner profile was denied: $out"

        # Implementer dispatches must carry the full dispatch context.
        out=$(run_hook Agent implementer-agent "Workspace: $PWD/workspace")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.hookEventName == "PreToolUse"
          and .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("Brief"))
        ' >/dev/null || fail "missing Brief line was not denied: $out"

        # Record and Task are required, and neither missing line may reach the validator.
        missing_record_prompt="Brief: $PWD/brief.md
    Workspace: $PWD/workspace
    Task: task-123"
        rm -f "$MARKER"
        out=$(run_hook Agent implementer-agent "$missing_record_prompt")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("Record"))
        ' >/dev/null || fail "missing Record line was not denied: $out"
        test ! -e "$MARKER" || fail "validator ran without Record: $(cat "$MARKER")"

        missing_task_prompt="Brief: $PWD/brief.md
    Workspace: $PWD/workspace
    Record: $PWD/state.json"
        rm -f "$MARKER"
        out=$(run_hook Agent implementer-agent "$missing_task_prompt")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("Task"))
        ' >/dev/null || fail "missing Task line was not denied: $out"
        test ! -e "$MARKER" || fail "validator ran without Task: $(cat "$MARKER")"

        # A valid Implementer dispatch invokes the configured validator and
        # identifies its entry as a model profile.
        unset FAIL
        rm -f "$MARKER"
        out=$(run_hook Agent implementer-agent "$prompt")
        test -z "$out" || fail "passing validation was denied: $out"
        test -f "$MARKER" || fail "validator was not invoked"
        expected_args="$(printf '%s\n' \
          --brief "$PWD/brief.md" \
          --workspace "$PWD/workspace" \
          --record "$PWD/state.json" \
          --task task-123 \
          --entry-profile implementer-profile)"
        test "$(cat "$MARKER")" = "$expected_args" \
          || fail "validator argv mismatch: $(cat "$MARKER")"

        # A validator failure denies and exposes its diagnostic in the reason.
        export FAIL=1
        out=$(run_hook Task implementer-agent "$prompt")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("stub validator rejected dispatch"))
        ' >/dev/null || fail "validator failure was not denied with its message: $out"
        unset FAIL

        # The retired rungs/worker schema is no longer read; a registry in that
        # shape denies model-profile-shaped dispatches instead of guessing.
        old_models="$PWD/old-models.json"
        cat > "$old_models" <<'JSON'
        {
          "rungs": {"old-entry": {"agent": "old-low"}},
          "roles": {"worker": {"entry": "old-entry"}}
        }
    JSON
        export GAMBIT_MODELS="$old_models"
        rm -f "$MARKER"
        out=$(run_hook Agent old-low "$prompt")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("invalid profiles or Implementer role"))
        ' >/dev/null || fail "old rungs registry allowed profile dispatch: $out"
        test ! -e "$MARKER" || fail "validator ran for old rungs registry"

        # A syntactically valid new registry is still malformed when its
        # Implementer entry is not an agent-backed model profile.
        malformed_schema="$PWD/malformed-schema.json"
        cat > "$malformed_schema" <<'JSON'
        {
          "profiles": {"bad-high": {"model": "opus"}},
          "roles": {"implementer": {"entry": "bad-high"}}
        }
    JSON
        export GAMBIT_MODELS="$malformed_schema"
        out=$(run_hook Agent bad-high "$prompt")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("Implementer profile is invalid"))
        ' >/dev/null || fail "malformed profile registry allowed dispatch: $out"

        # Malformed hook input still fails open because it is not a dispatch the
        # hook can read.
        out=$(printf '{not-json' | ${pkgs.python3}/bin/python3 ${hook})
        test -z "$out" || fail "malformed input was denied: $out"

        # A malformed registry denies model-profile-shaped agents and names the
        # registry problem, while unrelated agents remain untouched.
        malformed_models="$PWD/malformed-models.json"
        printf '{not-json' > "$malformed_models"
        export GAMBIT_MODELS="$malformed_models"
        out=$(run_hook Agent some-profile-high "$prompt")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("GAMBIT_MODELS"))
        ' >/dev/null || fail "malformed registry allowed profile dispatch: $out"
        out=$(run_hook Agent general-purpose "$prompt")
        test -z "$out" || fail "malformed registry denied unrelated agent: $out"

        # A missing registry denies a read-only profile-shaped agent as well.
        export GAMBIT_MODELS="$PWD/missing-models.json"
        out=$(run_hook Agent some-profile-low-ro "$prompt")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("GAMBIT_MODELS"))
        ' >/dev/null || fail "missing registry allowed profile dispatch: $out"
        export GAMBIT_MODELS="$PWD/models.json"

        # An unset or missing validator is a deny, rather than an accidental pass.
        export GAMBIT_MODELS="$PWD/models.json"
        export GAMBIT_VALIDATE_DISPATCH="$PWD/missing-validator.py"
        out=$(run_hook Agent implementer-agent "$prompt")
        printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
          .hookSpecificOutput.permissionDecision == "deny"
          and (.hookSpecificOutput.permissionDecisionReason | contains("GAMBIT_VALIDATE_DISPATCH"))
        ' >/dev/null || fail "missing validator was not denied: $out"

        # The source settings register the hook under the Agent|Task matcher, and
        # the module overlays the installed Gambit validator path at evaluation.
        ${pkgs.jq}/bin/jq -e '
          .hooks.PreToolUse[]
          | select(.matcher == "Agent|Task")
          | .hooks[]
          | select(.command == "~/.claude/hooks/gambit-dispatch-guard.py")
        ' ${settingsJson} >/dev/null || fail "settings do not register dispatch guard"
        ${pkgs.jq}/bin/jq -e '.env.GAMBIT_VALIDATE_DISPATCH == "__GAMBIT_VALIDATE_DISPATCH__"' ${settingsJson} >/dev/null \
          || fail "settings do not reserve validator environment"
        grep -Fq 'GAMBIT_VALIDATE_DISPATCH = "''${gambitSrc}/skills/executing-plans/scripts/validate_dispatch.py"' ${defaultNix} \
          || fail "default.nix does not inject Gambit validator path"
        # The rendered settings must carry the substituted path alongside the
        # patchbay base URL: a shallow `//` merge of two env overlays drops one.
        ${pkgs.jq}/bin/jq -e '.env.GAMBIT_VALIDATE_DISPATCH | test("/skills/executing-plans/scripts/validate_dispatch\\.py$")' ${renderedSettings} >/dev/null \
          || fail "rendered settings do not substitute the Gambit validator path"
        ${pkgs.jq}/bin/jq -e '.env.ANTHROPIC_BASE_URL | startswith("http://127.0.0.1:")' ${renderedSettings} >/dev/null \
          || fail "rendered settings lost the patchbay base URL"

        touch "$result_path"
  ''
