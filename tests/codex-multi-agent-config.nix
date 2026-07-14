{
  pkgs,
  codexModuleSource,
}:
pkgs.runCommand "codex-multi-agent-config-check" {
  nativeBuildInputs = [pkgs.gnugrep];
} ''
  set -euo pipefail

  source=${codexModuleSource}

  grep -F 'suppress_unstable_features_warning = true' "$source" >/dev/null
  grep -F 'hide_spawn_agent_metadata = false' "$source" >/dev/null

  namespace="$(${pkgs.gnused}/bin/sed -n -E \
    's/^[[:space:]]*tool_namespace = "([^"]+)"/\1/p' "$source" \
    | ${pkgs.coreutils}/bin/head -n1)"

  if [ -z "$namespace" ]; then
    echo "ASSERT FAIL: exposed spawn metadata requires a non-reserved tool namespace" >&2
    exit 1
  fi
  if [ "$namespace" = collaboration ]; then
    echo "ASSERT FAIL: collaboration.spawn_agent has a server-reserved schema" >&2
    exit 1
  fi
  if [ "$namespace" != gambit_agents ]; then
    echo "ASSERT FAIL: expected the profile-aware Gambit namespace, got $namespace" >&2
    exit 1
  fi

  grep -F 'root_agent_usage_hint_text = ' "$source" >/dev/null
  grep -F 'subagent_usage_hint_text = ' "$source" >/dev/null
  grep -F "to=functions.$namespace.spawn_agent" "$source" >/dev/null
  grep -F 'All agents share the same directory' "$source" >/dev/null
  grep -F 'There are 4 available concurrency slots' "$source" >/dev/null

  touch "$out"
''
