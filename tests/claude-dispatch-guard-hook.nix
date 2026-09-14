# Behavioural check for the PreToolUse hook that validates gambit worker
# dispatches before Claude Code launches them.
{pkgs}: let
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

    # Keep this registry independent of the installed roster. The worker entry
    # and ladder deliberately name the same writing agent, while another rung
    # exercises the non-worker path.
    cat > "$GAMBIT_MODELS" <<'JSON'
    {
      "rungs": {
        "worker-rung": {"agent": "worker-agent"},
        "other-rung": {"agent": "other-agent"}
      },
      "roles": {
        "worker": {"entry": "worker-rung", "ladder": ["worker-rung"]}
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
Workspace: $PWD/workspace"

    # Other tools never reach the dispatch guard, even with a worker agent.
    out=$(run_hook Bash worker-agent "no marker")
    test -z "$out" || fail "non-Agent/Task tool was denied: $out"

    # An Agent/Task dispatch to an agent outside the worker entry and ladder
    # remains untouched.
    out=$(run_hook Agent other-agent "no marker")
    test -z "$out" || fail "non-worker rung was denied: $out"

    # Worker dispatches must carry both absolute paths in their prompt.
    out=$(run_hook Agent worker-agent "Workspace: $PWD/workspace")
    printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
      .hookSpecificOutput.hookEventName == "PreToolUse"
      and .hookSpecificOutput.permissionDecision == "deny"
      and (.hookSpecificOutput.permissionDecisionReason | contains("Brief"))
    ' >/dev/null || fail "missing Brief line was not denied: $out"

    # A valid worker dispatch invokes the configured validator and remains
    # silent when that validator succeeds.
    unset FAIL
    rm -f "$MARKER"
    out=$(run_hook Agent worker-agent "$prompt")
    test -z "$out" || fail "passing validation was denied: $out"
    test -f "$MARKER" || fail "validator was not invoked"
    grep -Fqx -- "--brief" "$MARKER" || fail "validator missing --brief: $(cat "$MARKER")"
    grep -Fqx "$PWD/brief.md" "$MARKER" || fail "validator missing brief path: $(cat "$MARKER")"
    grep -Fqx -- "--workspace" "$MARKER" || fail "validator missing --workspace: $(cat "$MARKER")"
    grep -Fqx "$PWD/workspace" "$MARKER" || fail "validator missing workspace path: $(cat "$MARKER")"

    # A validator failure denies and exposes its diagnostic in the reason.
    export FAIL=1
    out=$(run_hook Task worker-agent "$prompt")
    printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
      .hookSpecificOutput.permissionDecision == "deny"
      and (.hookSpecificOutput.permissionDecisionReason | contains("stub validator rejected dispatch"))
    ' >/dev/null || fail "validator failure was not denied with its message: $out"
    unset FAIL

    # Malformed hook input and an unreadable registry fail open.
    out=$(printf '{not-json' | ${pkgs.python3}/bin/python3 ${hook})
    test -z "$out" || fail "malformed input was denied: $out"
    export GAMBIT_MODELS="$PWD/missing-models.json"
    out=$(run_hook Agent worker-agent "$prompt")
    test -z "$out" || fail "unreadable registry was denied: $out"

    # An unset or missing validator is a deny, rather than an accidental pass.
    export GAMBIT_MODELS="$PWD/models.json"
    export GAMBIT_VALIDATE_DISPATCH="$PWD/missing-validator.py"
    out=$(run_hook Agent worker-agent "$prompt")
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
    grep -Fq 'env.GAMBIT_VALIDATE_DISPATCH = "''${gambitSrc}/skills/executing-plans/scripts/validate_dispatch.py"' ${defaultNix} \
      || fail "default.nix does not inject Gambit validator path"

    touch "$result_path"
  ''
