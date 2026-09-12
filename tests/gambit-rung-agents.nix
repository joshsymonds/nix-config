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

  # The route keys patchbay actually publishes under codexUpstream, and the
  # Seat identity each one maps to: the upstream model id (the Pi twin
  # dispatches that id directly on its Codex provider) and the optional speed
  # tier (the Pi twin loads the codex-fast extension for it).
  chatgptModels = import ../home-manager/patchbay/chatgpt-models.nix;
  chatgptRoutes = lib.attrNames chatgptModels;
  routeModelsJson = pkgs.writeText "patchbay-chatgpt-route-models.json" (builtins.toJSON chatgptModels);

  # The tiltyard judgment roster: the plain-identifier selectors patchbay's
  # `tiltyard` context publishes, and the Seat each one names. Imported for the
  # same reason as chatgpt-models.nix above — it is config-free data, so this
  # check can assert the roster without evaluating a host.
  tiltyardSeats = import ../home-manager/patchbay/tiltyard-seats.nix;
  tiltyardJson = pkgs.writeText "patchbay-tiltyard-seats.json" (builtins.toJSON tiltyardSeats);

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
    # for that is missing here resolves to nothing at runtime. The orchestrator
    # is seated only where a Codex route exists; without it, gambit's loading
    # session performs the effort itself (contracts/models.md).
    jq -e '
      (.roles | keys | sort)
      == ["escalation", "finder", "orchestrator", "scout", "steelman", "test-runner", "verifier", "worker"]
      and .roles.orchestrator.entry == "sol-high"
      and (.roles.orchestrator | has("readonly") | not)
    ' ${fullJson} >/dev/null
    jq -e '
      (.roles | keys | sort)
      == ["escalation", "finder", "scout", "steelman", "test-runner", "verifier", "worker"]
    ' ${claudeOnlyJson} >/dev/null
    for map in ${fullJson} ${claudeOnlyJson}; do
      # Every entry rung and every ladder element names a rung the same map
      # declares — no dangling ladder step.
      jq -e '
        (.rungs | keys) as $declared
        | [.roles[] | .entry, ((.ladder // [])[])] as $used
        | all($used[]; . as $rung | ($declared | index($rung)) != null)
      ' "$map" >/dev/null
    done

    # The full map is the measured ladder: two fast rungs, then the
    # orchestrator's own model, never an Opus escalation. Keep these expected
    # ladders independent of the source declarations.
    jq -e '
      .roles.worker.entry == "luna-low"
      and .roles.worker.ladder == ["luna-low", "sol-low", "astra-high"]
      and .roles.escalation.entry == "sol-low"
      and .roles.escalation.ladder == ["sol-low", "astra-high"]
    ' ${fullJson} >/dev/null

    # The fast policy, pinned independently of the route file: Luna and Terra
    # are always fast, Sol is fast only on its own fast route, Astra never.
    jq -e '
      .["chatgpt/luna"].speed == "fast"
      and .["chatgpt/terra"].speed == "fast"
      and .["chatgpt/sol-fast"].speed == "fast"
      and (.["chatgpt/sol"] | has("speed") | not)
      and (.["chatgpt/astra"] | has("speed") | not)
      and .["chatgpt/sol-fast"].model == .["chatgpt/sol"].model
    ' ${routeModelsJson} >/dev/null

    # The tiltyard roster is exactly the eight judgment selectors. A missing
    # one silently drops a candidate from a comparison; an extra one adds a
    # model nothing measured.
    jq -e '
      (keys | sort)
      == ["dsv41flash", "fable51", "glm53", "kimik3", "opus5", "qwen38", "sol", "sonnet5"]
    ' ${tiltyardJson} >/dev/null

    # The three Claude candidates ride the caller's own credential on forward
    # Seats: no billing class to declare, and the model pin is the only thing
    # that makes each one a distinct candidate, so it must be there. The counts
    # keep these from passing vacuously on a roster that declares no such Seat.
    jq -e '
      [.[] | select(.auth_mode == "forward")] as $forward
      | ($forward | length) == 3
      and all($forward[];
        (.model | type) == "string" and (.model | length) > 0
        and (has("billing") | not))
    ' ${tiltyardJson} >/dev/null

    # The OpenRouter candidates spend the household key per token, which the
    # ledger prices only when the Seat says so.
    jq -e '
      [.[] | select(.auth_mode == "inject")] as $inject
      | ($inject | length) == 3
      and all($inject[]; .billing == "metered")
    ' ${tiltyardJson} >/dev/null

    # The pinned ids themselves. A judgment run only compares what it claims to
    # compare if each selector resolves to the model named here, and qwen3.8 is
    # the RunPod pod patchbay already publishes rather than a second Seat.
    jq -e '
      .fable51.model == "claude-fable-5-1"
      and .opus5.model == "claude-opus-5"
      and .sonnet5.model == "claude-sonnet-5"
      and .glm53.model == "z-ai/glm-5.3-flash"
      and .kimik3.model == "moonshotai/kimi-k3"
      and .dsv41flash.model == "deepseek/deepseek-v4.1-flash"
      and .qwen38.seat == "runpod-qwen3-8"
      and .sol.seat == "chatgpt-sol"
    ' ${tiltyardJson} >/dev/null

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
      pi_model="openai-codex/$(jq -r --arg r "$route" '.[$r].model' ${routeModelsJson})"
      speed=$(jq -r --arg r "$route" '.[$r].speed // ""' ${routeModelsJson})
      pi_plain="${piAgentsDir}/$rung.md"
      pi_ro="${piAgentsDir}/$rung-ro.md"
      for f in "$pi_plain" "$pi_ro"; do
        test -f "$f"
        grep -qxF "model: $pi_model" "$f"
        grep -qxF "thinking: $effort" "$f"
        grep -qxF "skills: false" "$f"
        if grep -qF "disallowedTools:" "$f"; then
          echo "Pi rung $f leaked Claude-only frontmatter" >&2
          exit 1
        fi
      done
      # An Orchestrator is not a leaf worker: it needs scoped child dispatch
      # and task-state tools. Keep the expected privileges independent of the
      # renderer, including the absence of the task extension's RPC dispatch.
      if [ "$rung" = sol-high ]; then
        grep -qxF 'allowed_subagents: "astra-high, astra-xhigh-ro, luna-low, sol-low, sol-xhigh-ro, terra-medium-ro"' "$pi_plain"
        grep -qxF 'extensions: ["pi-tasks", "pi-processes"]' "$pi_plain"
        grep -qxF 'tools: "*, ext:pi-tasks/TaskCreate, ext:pi-tasks/TaskGet, ext:pi-tasks/TaskList, ext:pi-tasks/TaskUpdate, ext:pi-processes"' "$pi_plain"
        grep -qF 'run_in_background: true' "$pi_plain"
        grep -qF 'get_subagent_result(wait: true)' "$pi_plain"
        grep -qF 'returning a final answer stops them' "$pi_plain"
      else
        if grep -q '^allowed_subagents:' "$pi_plain"; then
          echo "leaf worker $rung unexpectedly grants delegation" >&2
          exit 1
        fi
        if [ "$speed" = fast ]; then
          grep -qE '^extensions: \["/nix/store/[^"/]+-codex-fast\.ts"\]$' "$pi_plain"
        else
          grep -qxF "extensions: false" "$pi_plain"
        fi
        grep -qxF 'tools: "*"' "$pi_plain"
      fi
      if grep -q '^allowed_subagents:' "$pi_ro"; then
        echo "read-only $rung unexpectedly grants delegation" >&2
        exit 1
      fi
      grep -qxF "extensions: false" "$pi_ro"
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
      if grep -q '^allowed_subagents:' "$pi_plain" "$pi_ro"; then
        echo "omakase leaf rung $rung unexpectedly grants delegation" >&2
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
