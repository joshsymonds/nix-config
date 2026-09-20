# Consistency check over Gambit model profiles: the profile definitions, the
# two profile/role maps written to <profile>/gambit/models.json, the rendered
# subagent files, and the patchbay routes they point at. The compatibility
# filename and check attribute remain stable for callers.
{pkgs}: let
  inherit (pkgs) lib;

  workflowTools = import ../home-manager/pi/tool-packages {inherit lib pkgs;};
  orchestratorProcessExtension = "${workflowTools}/orchestrator-processes/index.ts";
  modelProfileData = import ../home-manager/claude-code/gambit-rungs.nix {
    inherit lib pkgs orchestratorProcessExtension;
  };
  inherit
    (modelProfileData)
    gambitProfiles
    profileAgentEntries
    optionalClaudeProfileAgentEntries
    piProfileAgentEntries
    omakasePiProfiles
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

  profilesJson = pkgs.writeText "gambit-model-profiles.json" (builtins.toJSON gambitProfiles);
  fullJson = pkgs.writeText "gambit-models-full.json" (builtins.toJSON gambitModelsFull);
  claudeOnlyJson = pkgs.writeText "gambit-models-claude-only.json" (builtins.toJSON gambitModelsClaudeOnly);
  routesJson = pkgs.writeText "patchbay-chatgpt-routes.json" (builtins.toJSON chatgptRoutes);
  omakaseJson = pkgs.writeText "gambit-omakase-pi-profiles.json" (builtins.toJSON omakasePiProfiles);

  # The same entries home-manager links into <profile>/agents, rendered here so
  # the frontmatter can be read back off disk.
  agentsDir = pkgs.linkFarm "gambit-profile-agents-check-dir" profileAgentEntries;
  piAgentsDir = pkgs.linkFarm "gambit-pi-profile-agents-check-dir" piProfileAgentEntries;
  optionalAgentsDir = assert optionalClaudeProfileAgentEntries [] == [];
  assert optionalClaudeProfileAgentEntries ["chatgpt/sol"] == [];
  assert map (entry: entry.name) (optionalClaudeProfileAgentEntries ["singularity/deepseek-flash"])
  == ["singularity-flash-high.md" "singularity-flash-high-ro.md"];
  assert !(gambitModelsFull.profiles ? singularity-flash-high);
  assert !(gambitModelsClaudeOnly.profiles ? singularity-flash-high);
    pkgs.linkFarm "gambit-optional-claude-agents-check-dir" (optionalClaudeProfileAgentEntries ["singularity/deepseek-flash"]);
in
  pkgs.runCommand "gambit-rung-agents-check" {
    nativeBuildInputs = [pkgs.jq];
  } ''
    set -euo pipefail

    # Guard against the whole file passing vacuously on an empty profile set.
    jq -e 'length > 0' ${profilesJson} >/dev/null

    # Both maps expose exactly the explicit roles Gambit dispatches. The
    # orchestrator is seated only where a Codex route exists; without it,
    # Gambit's loading session performs the effort itself.
    jq -e '
      (.roles | keys | sort)
      == ["conformance-reviewer", "finding-verifier", "implementer", "integration-reviewer", "orchestrator", "scout", "steelman", "task-reviewer", "test-runner"]
      and .roles.implementer == {"entry":"luna-low"}
      and .roles."task-reviewer" == {"entry":"terra-medium","readonly":true}
      and .roles."finding-verifier" == {"entry":"terra-medium","readonly":true}
      and .roles."conformance-reviewer" == {"entry":"sol-high","readonly":true}
      and .roles."integration-reviewer" == {"entry":"sol-high","readonly":true}
      and .roles.orchestrator.entry == "sol-high"
      and (.roles.orchestrator | has("readonly") | not)
      and (.roles as $roles | ["worker", "finder", "verifier", "reviewer"] | all(. as $old | ($roles | has($old) | not)))
    ' ${fullJson} >/dev/null
    jq -e '
      (.roles | keys | sort)
      == ["conformance-reviewer", "finding-verifier", "implementer", "integration-reviewer", "scout", "steelman", "task-reviewer", "test-runner"]
      and .roles.implementer == {"entry":"opus"}
      and .roles."task-reviewer" == {"entry":"fable","readonly":true}
      and .roles."finding-verifier" == {"entry":"fable","readonly":true}
      and .roles."conformance-reviewer" == {"entry":"fable","readonly":true}
      and .roles."integration-reviewer" == {"entry":"fable","readonly":true}
      and (.roles as $roles | ["worker", "finder", "verifier", "reviewer"] | all(. as $old | ($roles | has($old) | not)))
    ' ${claudeOnlyJson} >/dev/null
    for map in ${fullJson} ${claudeOnlyJson}; do
      # Every role entry names a model profile the same map declares.
      jq -e '
        (.profiles | keys) as $declared
        | [.roles[].entry] as $used
        | all($used[]; . as $profile | ($declared | index($profile)) != null)
        and (. | has("rungs") | not)
      ' "$map" >/dev/null
    done

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

    # The agent profiles of the full map are exactly the declared Gambit model
    # profiles, and each follows the <profile> / <profile>-ro naming contract.
    jq -e --argjson declared "$(cat ${profilesJson})" '
      ([.profiles | to_entries[] | select(.value | has("agent")) | .key] | sort)
        == ($declared | keys | sort)
      and all(
        .profiles | to_entries[] | select(.value | has("agent"));
        .value.agent == .key and .value.readonly_agent == (.key + "-ro")
      )
    ' ${fullJson} >/dev/null

    # The Claude-only map carries no GPT profile — only enum-model profiles.
    jq -e 'all(.profiles[]; (has("agent") | not) and has("model"))' ${claudeOnlyJson} >/dev/null

    # No profile may name a route patchbay does not publish under
    # codexUpstream; such a profile would dispatch at a port nothing listens on.
    jq -e --argjson routes "$(cat ${routesJson})" '
      all(.[]; .route as $route | ($routes | index($route)) != null)
    ' ${profilesJson} >/dev/null

    # The rendered subagents: model/effort match the declaration, the
    # read-only variant carries the full denylist and its bounded-Bash
    # directive, and the writing variant carries neither.
    for profile in $(jq -r 'keys[]' ${profilesJson}); do
      route=$(jq -r --arg r "$profile" '.[$r].route' ${profilesJson})
      effort=$(jq -r --arg r "$profile" '.[$r].effort' ${profilesJson})

      plain="${agentsDir}/$profile.md"
      ro="${agentsDir}/$profile-ro.md"
      test -f "$plain"
      test -f "$ro"

      for f in "$plain" "$ro"; do
        grep -qxF "model: $route" "$f"
        grep -qxF "effort: $effort" "$f"
        grep -qF "Gambit model profile:" "$f"
        if grep -qF "Gambit rung" "$f"; then
          echo "generated profile $f retains rung wording" >&2
          exit 1
        fi
      done

      grep -qxF ${lib.escapeShellArg expectedDenylist} "$ro"
      grep -qF "READ-ONLY advisory variant" "$ro"
      grep -qF "Never run:" "$ro"

      if grep -qF "disallowedTools" "$plain"; then
        echo "writing variant $profile.md carries a denylist" >&2
        exit 1
      fi
      if grep -qF "READ-ONLY" "$plain"; then
        echo "writing variant $profile.md carries the read-only directive" >&2
        exit 1
      fi

      # Pi gets the same named profiles rendered in pi-subagents frontmatter.
      # Its direct Codex provider replaces Claude's patchbay route, `thinking`
      # replaces `effort`, and read-only variants expose inspection tools only.
      pi_model="openai-codex/$(jq -r --arg r "$route" '.[$r].model' ${routeModelsJson})"
      speed=$(jq -r --arg r "$route" '.[$r].speed // ""' ${routeModelsJson})
      pi_plain="${piAgentsDir}/$profile.md"
      pi_ro="${piAgentsDir}/$profile-ro.md"
      for f in "$pi_plain" "$pi_ro"; do
        test -f "$f"
        grep -qxF "model: $pi_model" "$f"
        grep -qxF "thinking: $effort" "$f"
        grep -qxF "skills: false" "$f"
        grep -qF "Gambit model profile:" "$f"
        if grep -qF "disallowedTools:" "$f"; then
          echo "Pi profile $f leaked Claude-only frontmatter" >&2
          exit 1
        fi
      done
      # An Orchestrator is not a leaf Implementer: it needs scoped child
      # dispatch and task-state tools. Keep the expected privileges independent
      # of the renderer, including the absence of task RPC dispatch.
      if [ "$profile" = sol-high ]; then
        grep -qxF 'allowed_subagents: "astra-xhigh-ro, luna-low, sol-high-ro, terra-medium-ro"' "$pi_plain"
        grep -qxF 'extensions: ["pi-tasks", "${orchestratorProcessExtension}"]' "$pi_plain"
        grep -qE '^extensions: \["pi-tasks", "/nix/store/[^"/]+/orchestrator-processes/index.ts"\]$' "$pi_plain"
        test -f '${orchestratorProcessExtension}'
        jq -e '.name == "pi-processes" and .pi.extensions == ["./index.ts"]' '${workflowTools}/orchestrator-processes/package.json' >/dev/null
        # Root discovery must never opt in to the child lifecycle gate.
        jq -e 'all(.pi.extensions[]; contains("orchestrator") | not)' '${workflowTools}/node_modules/@aliou/pi-processes/package.json' >/dev/null
        grep -qxF 'tools: "*, ext:pi-tasks/TaskCreate, ext:pi-tasks/TaskGet, ext:pi-tasks/TaskList, ext:pi-tasks/TaskUpdate, ext:pi-processes"' "$pi_plain"
        grep -qF 'run_in_background: true' "$pi_plain"
        grep -qF 'get_subagent_result(wait: true)' "$pi_plain"
        grep -qF 'completing your run stops them' "$pi_plain"
        grep -qF 'end your turn to yield' "$pi_plain"
        grep -qF 'context/ignore do not request a turn' "$pi_plain"
        grep -qF 'Never sleep, poll, or dispatch a model just to wait' "$pi_plain"
      else
        if grep -q '^allowed_subagents:' "$pi_plain"; then
          echo "leaf profile $profile unexpectedly grants delegation" >&2
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
        echo "read-only $profile unexpectedly grants delegation" >&2
        exit 1
      fi
      grep -qxF "extensions: false" "$pi_ro"
      grep -qxF 'tools: "read, bash, grep, find, ls"' "$pi_ro"
      grep -qxF 'isolated: true' "$pi_ro"
      grep -qF "READ-ONLY advisory variant" "$pi_ro"
      if grep -qF "isolated: true" "$pi_plain"; then
        echo "writing Pi variant $profile.md is isolated read-only" >&2
        exit 1
      fi
    done

    # Pi-only omakase profiles: rendered into the same agents dir, with the
    # gateway model id and alias's pinned effort, and the same tool discipline
    # as the Codex profiles. They have no Claude Code twin.
    for profile in $(jq -r 'keys[]' ${omakaseJson}); do
      model=$(jq -r --arg r "$profile" '.[$r].model' ${omakaseJson})
      thinking=$(jq -r --arg r "$profile" '.[$r].thinking' ${omakaseJson})
      pi_plain="${piAgentsDir}/$profile.md"
      pi_ro="${piAgentsDir}/$profile-ro.md"
      for f in "$pi_plain" "$pi_ro"; do
        test -f "$f"
        grep -qxF "model: $model" "$f"
        grep -qxF "thinking: $thinking" "$f"
        grep -qxF "extensions: false" "$f"
        grep -qxF "skills: false" "$f"
        if grep -qF "disallowedTools:" "$f"; then
          echo "omakase Pi profile $f leaked Claude-only frontmatter" >&2
          exit 1
        fi
      done
      grep -qxF 'tools: "*"' "$pi_plain"
      grep -qxF 'tools: "read, bash, grep, find, ls"' "$pi_ro"
      grep -qxF 'isolated: true' "$pi_ro"
      grep -qF "READ-ONLY advisory variant" "$pi_ro"
      if grep -qF "isolated: true" "$pi_plain"; then
        echo "writing omakase Pi variant $profile.md is isolated read-only" >&2
        exit 1
      fi
      if grep -q '^allowed_subagents:' "$pi_plain" "$pi_ro"; then
        echo "omakase leaf profile $profile unexpectedly grants delegation" >&2
        exit 1
      fi
      # An omakase profile must not collide with a Codex profile name.
      if jq -e --arg r "$profile" 'has($r)' ${profilesJson} >/dev/null; then
        echo "omakase profile $profile shadows a Codex profile" >&2
        exit 1
      fi
    done

    # Optional beta agents share the Claude renderer, never Pi or role defaults.
    plain="${optionalAgentsDir}/singularity-flash-high.md"
    ro="${optionalAgentsDir}/singularity-flash-high-ro.md"
    for f in "$plain" "$ro"; do
      test -f "$f"
      grep -qxF 'model: singularity/deepseek-flash' "$f"
      grep -qxF 'effort: high' "$f"
    done
    grep -qxF 'name: singularity-flash-high' "$plain"
    grep -qxF 'name: singularity-flash-high-ro' "$ro"
    grep -qxF ${lib.escapeShellArg expectedDenylist} "$ro"
    grep -qF 'READ-ONLY advisory variant' "$ro"
    grep -qF 'Never run:' "$ro"
    if grep -qE 'disallowedTools|READ-ONLY' "$plain"; then
      echo 'writing Singularity agent carries read-only restrictions' >&2
      exit 1
    fi
    for name in singularity-flash-high singularity-flash-high-ro; do
      test ! -e "${piAgentsDir}/$name.md"
      test ! -e "${agentsDir}/$name.md"
    done

    touch "$out"
  ''
