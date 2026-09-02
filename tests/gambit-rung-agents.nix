# Consistency check over the gambit rung data: the rung definitions, the two
# rung/role maps written to <profile>/gambit/models.json, the rendered subagent
# files, and the patchbay routes they point at. Replaces the coverage the
# deleted claude-codex-executors.nix gave the Codex executor registry.
{pkgs}: let
  inherit (pkgs) lib;

  rungData = import ../home-manager/claude-code/gambit-rungs.nix {
    inherit lib pkgs;
  };
  inherit
    (rungData)
    gambitRungs
    rungAgentEntries
    piRungAgentEntries
    omakasePiRungs
    gambitModelsFull
    gambitModelsClaudeOnly
    ;

  # Spelled out here rather than imported from gambit-rungs.nix: importing the
  # constant would make the assertion tautological — it would prove the file
  # says whatever the module says, not that the module denies the right tools.
  # Edit/Write/NotebookEdit are the file mutators, Agent stops an -ro variant
  # sub-dispatching a writing agent, and mcp__* removes every MCP server
  # (shimmer alone reaches Jira, GitLab, Todoist and Monarch write APIs).
  expectedDenylist = "disallowedTools: Edit, Write, NotebookEdit, Agent, mcp__*";

  # The route keys patchbay actually publishes under codexUpstream.
  chatgptRoutes = lib.attrNames (import ../home-manager/patchbay/chatgpt-models.nix);

  rungsJson = pkgs.writeText "gambit-rungs.json" (builtins.toJSON gambitRungs);
  fullJson = pkgs.writeText "gambit-models-full.json" (builtins.toJSON gambitModelsFull);
  claudeOnlyJson = pkgs.writeText "gambit-models-claude-only.json" (builtins.toJSON gambitModelsClaudeOnly);
  routesJson = pkgs.writeText "patchbay-chatgpt-routes.json" (builtins.toJSON chatgptRoutes);
  omakaseJson = pkgs.writeText "gambit-omakase-pi-rungs.json" (builtins.toJSON omakasePiRungs);

  # The same entries home-manager links into <profile>/agents, rendered here so
  # the frontmatter can be read back off disk.
  agentsDir = pkgs.linkFarm "gambit-rung-agents-check-dir" rungAgentEntries;
  piAgentsDir = pkgs.linkFarm "gambit-pi-rung-agents-check-dir" piRungAgentEntries;
in
  pkgs.runCommand "gambit-rung-agents-check" {
    nativeBuildInputs = [pkgs.jq];
  } ''
    set -euo pipefail

    # Guard against the whole file passing vacuously on an empty rung set.
    jq -e 'length > 0' ${rungsJson} >/dev/null

    # Both maps expose exactly the roles gambit dispatches. A role gambit asks
    # for that is missing here resolves to nothing at runtime.
    for map in ${fullJson} ${claudeOnlyJson}; do
      jq -e '
        (.roles | keys | sort)
        == ["escalation", "finder", "scout", "steelman", "test-runner", "verifier", "worker"]
      ' "$map" >/dev/null

      # Every entry rung and every ladder element names a rung the same map
      # declares — no dangling ladder step.
      jq -e '
        (.rungs | keys) as $declared
        | [.roles[] | .entry, ((.ladder // [])[])] as $used
        | all($used[]; . as $rung | ($declared | index($rung)) != null)
      ' "$map" >/dev/null
    done

    # The agent rungs of the full map are exactly the declared gambit rungs,
    # and each one follows the <rung> / <rung>-ro naming models.json and the
    # generated subagent files both depend on.
    jq -e --argjson declared "$(cat ${rungsJson})" '
      ([.rungs | to_entries[] | select(.value | has("agent")) | .key] | sort)
        == ($declared | keys | sort)
      and all(
        .rungs | to_entries[] | select(.value | has("agent"));
        .value.agent == .key and .value.readonly_agent == (.key + "-ro")
      )
    ' ${fullJson} >/dev/null

    # The Claude-only map (work profile everywhere, plus every non-Codex host)
    # carries no GPT rung at all — only enum-model rungs.
    jq -e 'all(.rungs[]; (has("agent") | not) and has("model"))' ${claudeOnlyJson} >/dev/null

    # No rung may name a route patchbay does not publish under codexUpstream;
    # such a rung would dispatch at a port nothing listens on.
    jq -e --argjson routes "$(cat ${routesJson})" '
      all(.[]; .route as $route | ($routes | index($route)) != null)
    ' ${rungsJson} >/dev/null

    # The rendered subagents: model/effort match the declaration, the
    # read-only variant carries the full denylist and its bounded-Bash
    # directive, and the writing variant carries neither.
    for rung in $(jq -r 'keys[]' ${rungsJson}); do
      route=$(jq -r --arg r "$rung" '.[$r].route' ${rungsJson})
      effort=$(jq -r --arg r "$rung" '.[$r].effort' ${rungsJson})

      plain="${agentsDir}/$rung.md"
      ro="${agentsDir}/$rung-ro.md"
      test -f "$plain"
      test -f "$ro"

      for f in "$plain" "$ro"; do
        grep -qxF "model: $route" "$f"
        grep -qxF "effort: $effort" "$f"
      done

      grep -qxF ${lib.escapeShellArg expectedDenylist} "$ro"
      grep -qF "READ-ONLY advisory variant" "$ro"
      grep -qF "Never run:" "$ro"

      if grep -qF "disallowedTools" "$plain"; then
        echo "writing variant $rung.md carries a denylist" >&2
        exit 1
      fi
      if grep -qF "READ-ONLY" "$plain"; then
        echo "writing variant $rung.md carries the read-only directive" >&2
        exit 1
      fi

      # Pi gets the same named rungs rendered in pi-subagents frontmatter.
      # Its direct Codex provider replaces Claude's patchbay route, `thinking`
      # replaces `effort`, and read-only variants expose inspection tools only.
      pi_model="openai-codex/gpt-5.6-''${route#chatgpt/}"
      pi_plain="${piAgentsDir}/$rung.md"
      pi_ro="${piAgentsDir}/$rung-ro.md"
      for f in "$pi_plain" "$pi_ro"; do
        test -f "$f"
        grep -qxF "model: $pi_model" "$f"
        grep -qxF "thinking: $effort" "$f"
        grep -qxF "extensions: false" "$f"
        grep -qxF "skills: false" "$f"
        if grep -qF "disallowedTools:" "$f"; then
          echo "Pi rung $f leaked Claude-only frontmatter" >&2
          exit 1
        fi
      done
      grep -qxF 'tools: "*"' "$pi_plain"
      grep -qxF 'tools: "read, bash, grep, find, ls"' "$pi_ro"
      grep -qxF 'isolated: true' "$pi_ro"
      grep -qF "READ-ONLY advisory variant" "$pi_ro"
      if grep -qF "isolated: true" "$pi_plain"; then
        echo "writing Pi variant $rung.md is isolated read-only" >&2
        exit 1
      fi
    done

    # Pi-only omakase rungs: rendered into the same agents dir, with the
    # gateway model id and the alias's pinned effort, and the same tool
    # discipline as the Codex rungs. They have no Claude Code twin.
    for rung in $(jq -r 'keys[]' ${omakaseJson}); do
      model=$(jq -r --arg r "$rung" '.[$r].model' ${omakaseJson})
      thinking=$(jq -r --arg r "$rung" '.[$r].thinking' ${omakaseJson})
      pi_plain="${piAgentsDir}/$rung.md"
      pi_ro="${piAgentsDir}/$rung-ro.md"
      for f in "$pi_plain" "$pi_ro"; do
        test -f "$f"
        grep -qxF "model: $model" "$f"
        grep -qxF "thinking: $thinking" "$f"
        grep -qxF "extensions: false" "$f"
        grep -qxF "skills: false" "$f"
        if grep -qF "disallowedTools:" "$f"; then
          echo "omakase Pi rung $f leaked Claude-only frontmatter" >&2
          exit 1
        fi
      done
      grep -qxF 'tools: "*"' "$pi_plain"
      grep -qxF 'tools: "read, bash, grep, find, ls"' "$pi_ro"
      grep -qxF 'isolated: true' "$pi_ro"
      grep -qF "READ-ONLY advisory variant" "$pi_ro"
      if grep -qF "isolated: true" "$pi_plain"; then
        echo "writing omakase Pi variant $rung.md is isolated read-only" >&2
        exit 1
      fi
      # An omakase rung must not collide with a Codex rung name.
      if jq -e --arg r "$rung" 'has($r)' ${rungsJson} >/dev/null; then
        echo "omakase rung $rung shadows a Codex rung" >&2
        exit 1
      fi
    done

    touch "$out"
  ''
