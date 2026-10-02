{
  pkgs,
  renderedSettings,
}: let
  hook = ../home-manager/claude-code/hooks/private-store-guard.py;
  settingsJson = ../home-manager/claude-code/settings.json;
  defaultNix = ../home-manager/claude-code/default.nix;
in
  pkgs.runCommand "private-store-hook-check" {
    nativeBuildInputs = [pkgs.jq pkgs.python3];
  } ''
    set -euo pipefail
    result_path="$out"

    fail() {
      echo "private-store-hook: $1" >&2
      exit 1
    }

    run_hook() {
      printf '%s' "$1" | ${pkgs.python3}/bin/python3 ${hook}
    }

    assert_denied() {
      out=$(run_hook "$1")
      printf '%s' "$out" | ${pkgs.jq}/bin/jq -e '
        .hookSpecificOutput.hookEventName == "PreToolUse"
        and .hookSpecificOutput.permissionDecision == "deny"
        and (.hookSpecificOutput.permissionDecisionReason | length > 0)
      ' >/dev/null || fail "expected denial for input: $1 (got: $out)"
    }

    assert_allowed() {
      out=$(run_hook "$1")
      test -z "$out" || fail "expected fail-open/allow for input: $1 (got: $out)"
    }

    assert_denied '{"tool_name":"Bash","tool_input":{"command":"cat /tmp/strongbox"}}'
    # Match a whole token, not an unrelated longer identifier.
    assert_allowed '{"tool_name":"Bash","tool_input":{"command":"printf strongboxes"}}'
    assert_allowed '{"tool_name":"Bash","tool_input":{"command":"ls /tmp"}}'

    assert_denied '{"tool_name":"Read","tool_input":{"file_path":"/run/strongbox/key"}}'
    assert_denied '{"tool_name":"Grep","tool_input":{"path":"/run/strongbox/data"}}'
    assert_denied '{"tool_name":"Glob","tool_input":{"path":"/run/strongbox"}}'
    assert_allowed '{"tool_name":"Read","tool_input":{"file_path":"/run/elsewhere/file"}}'
    assert_allowed '{"tool_name":"Grep","tool_input":{"path":"/run/strongboxx/file"}}'
    assert_allowed '{"tool_name":"Glob","tool_input":{"path":"/tmp"}}'

    # Parse and input-shape errors must remain fail-open and never emit a denial.
    assert_allowed '{not-json'
    assert_allowed '[]'
    assert_allowed '{"tool_name":"Read","tool_input":null}'
    assert_allowed '{"tool_name":null,"tool_input":{"file_path":"/run/strongbox"}}'
    assert_allowed '{"tool_name":"Bash","tool_input":{"command":[]}}'

    ${pkgs.jq}/bin/jq -e '
      .hooks.PreToolUse[]
      | select(.matcher == "Bash|Read|Grep|Glob")
      | .hooks[]
      | select(.command == "~/.claude/hooks/private-store-guard.py")
    ' ${settingsJson} >/dev/null || fail "source settings do not register the guard matcher"
    ${pkgs.jq}/bin/jq -e '
      .permissions.deny | index("Read(/run/strongbox/**)") != null
      and index("Grep(/run/strongbox/**)") != null
      and index("Glob(/run/strongbox/**)") != null
    ' ${settingsJson} >/dev/null || fail "source settings do not deny protected read permissions"
    ${pkgs.jq}/bin/jq -e '
      .hooks.PreToolUse[]
      | select(.matcher == "Bash|Read|Grep|Glob")
      | .hooks[]
      | select(.command == "~/.claude/hooks/private-store-guard.py")
    ' ${renderedSettings} >/dev/null || fail "rendered settings do not register the guard matcher"
    ${pkgs.jq}/bin/jq -e '
      .permissions.deny | index("Read(/run/strongbox/**)") != null
      and index("Grep(/run/strongbox/**)") != null
      and index("Glob(/run/strongbox/**)") != null
    ' ${renderedSettings} >/dev/null || fail "rendered settings do not deny protected read permissions"
    grep -Fq '".claude/hooks/private-store-guard.py"' ${defaultNix} \
      || fail "default.nix does not install the guard hook"

    touch "$result_path"
  ''
