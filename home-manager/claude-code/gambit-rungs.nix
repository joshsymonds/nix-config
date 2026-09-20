# Gambit's profile/role data — the single source of truth for which non-Claude
# model profiles exist, what each one is named, how it is rendered as a Claude
# Code subagent, and how roles map onto profiles.
#
# Imported by home-manager/claude-code/default.nix (which installs the agents
# and writes <profile>/gambit/models.json) and by tests/gambit-rung-agents.nix
# (which checks the two stay consistent). Nothing here reads `config`, so the
# check can import it without evaluating a host.
{
  lib,
  pkgs,
  orchestratorProcessExtension ? "${import ../pi/tool-packages {inherit lib pkgs;}}/orchestrator-processes/index.ts",
}: rec {
  # ── Gambit profile agents ──────────────────────────────────────────────────
  # Gambit's non-Claude model profiles ship as Claude Code SUBAGENT
  # DEFINITIONS, not as model parameters. The Agent tool's `model:` argument
  # is enum-locked (sonnet/opus/haiku/fable/inherit), so a patchbay route id
  # like chatgpt/sol can only reach the wire through a subagent's
  # frontmatter, whose `model` field accepts a full model id. Gambit
  # dispatches a profile by subagent_type and passes the real contract by path
  # in the prompt, so these bodies stay deliberately generic and minimal.
  #
  # Each `route` must be a route key patchbay publishes under codexUpstream;
  # home-manager/patchbay/chatgpt-models.nix owns that list and the check
  # asserts the two agree. A route whose Seat carries speed = "fast" makes
  # the profile a fast profile on both harnesses: the Claude Code agent gets it from
  # the Seat, the Pi twin from the codex-fast extension below.
  #
  # The Implementer role is entry-only: Luna is cheap and fast, while
  # higher-effort model profiles remain reserved for advisory roles.
  gambitProfiles = {
    # Implementer entry profile: Luna, always on the fast tier.
    "luna-low" = {
      route = "chatgpt/luna";
      effort = "low";
    };
    # Retained standard-speed profile: Sol. It ran on the fast tier from
    # 2026-09-09 to 2026-09-11 and was the largest Codex-quota draw on the
    # profile catalog, so it went back to standard.
    "sol-low" = {
      route = "chatgpt/sol";
      effort = "low";
    };
    # Scout profile: Terra, always on the fast tier.
    "terra-medium" = {
      route = "chatgpt/terra";
      effort = "medium";
    };
    # Orchestrator profile: Sol at high effort runs one effort, review, or
    # release from the durable record (gambit contracts/models.md). Chosen by
    # Josh on 2026-09-12 when the judgment campaign was stopped short of its
    # table to save quota.
    "sol-high" = {
      route = "chatgpt/sol";
      effort = "high";
    };
    # Retained Sol xhigh profile for explicit/manual dispatch.
    "sol-xhigh" = {
      route = "chatgpt/sol";
      effort = "xhigh";
    };
    # Retained Astra high profile for explicit/manual dispatch. Claude Code
    # reaches it through patchbay's HTTPS path (cli-proxy-api), while Pi uses
    # Codex WebSocket. It is not an implementation escalation target.
    "astra-high" = {
      route = "chatgpt/astra";
      effort = "high";
    };
    # Astra at its highest effort: the read-only steelman pass brainstorming
    # runs on an agreed design.
    "astra-xhigh" = {
      route = "chatgpt/astra";
      effort = "xhigh";
    };
  };

  # Explicit Claude Code dispatch only: these never enter Gambit's role map
  # or Pi's agent directory. Install each pair only where its route is declared.
  optionalClaudeProfiles = {
    "singularity-flash-high" = {
      route = "singularity/deepseek-flash";
      effort = "high";
    };
  };

  # Route key -> the Seat's upstream identity (model id, optional speed),
  # owned by the patchbay module. The model id labels the Claude Code agent
  # and names the Pi twin's provider model, so a profile never hardcodes a model
  # generation; the speed decides whether the Pi twin loads the fast
  # extension.
  chatgptModels = import ../patchbay/chatgpt-models.nix;
  routeModel = route: chatgptModels.${route}.model;
  routeFast = route: chatgptModels.${route} ? speed;

  # The Pi-side counterpart of a fast Seat: a before_provider_request hook
  # that asks the openai-codex provider for the priority tier. Referenced by
  # store path from the profile frontmatter, so only fast profiles ever load it.
  codexFastExtension = ../pi/codex-fast.ts;

  # The naming contract models.json depends on: a profile's writing agent is the
  # profile name, its advisory agent is the profile name plus "-ro".
  profileAgentName = profile: readonly: profile + lib.optionalString readonly "-ro";

  # The read-only denylist. `disallowedTools` is resolved before any `tools`
  # allowlist (Claude Code sub-agents reference), so this removes the
  # mutating tools outright: file edits, sub-dispatch (which could launch a
  # writing agent), and every MCP server (shimmer reaches Jira, GitLab,
  # Todoist, Monarch — all write-capable).
  profileAgentDenylist = "disallowedTools: Edit, Write, NotebookEdit, Agent, mcp__*";

  # What the -ro variants are told, over and above the denylist. Bash
  # survives the denylist because the read-only contracts (scout, steelman,
  # and reviewers) are useless without git and search, so the bound on it has
  # to be stated in the body — a prompt-level rule, not a sandbox.
  readonlyDirective = [
    "You are a Gambit model-profile agent in its READ-ONLY advisory variant. Follow the"
    "contract and brief given in your prompt exactly."
    ""
    "You inspect and report; you never change the workspace. The editing tools"
    "are denied to you outright. Bash is still available, and it is bounded by"
    "this rule: use it only for read-only inspection — `git diff`, `git log`,"
    "`git show`, `git status`, `rg`, `grep`, `cat`, `sed -n`, `ls`, `find`,"
    "`head`, `tail`."
    ""
    "Never run: anything that mutates a file, output redirection into a file"
    "(`>`, `>>`), `sed -i`, `tee`, `git commit`/`reset`/`checkout`/`merge`/"
    "`worktree`, package installs or any other command that writes outside its"
    "own process, or anything that sends data over the network. If the brief"
    "seems to require one of these, stop and report instead of running it."
  ];

  # The description is quoted because it contains a colon; an unquoted YAML
  # plain scalar cannot carry ": ".
  mkProfileAgent = profile: readonly: let
    inherit ((gambitProfiles // optionalClaudeProfiles).${profile}) route effort;
    agentName = profileAgentName profile readonly;
    modelLabel =
      if builtins.hasAttr route chatgptModels
      then routeModel route
      else route;
  in
    pkgs.writeText "gambit-profile-${agentName}.md" (lib.concatStringsSep "\n" (
      [
        "---"
        "name: ${agentName}"
        ''description: "Gambit model profile: ${modelLabel} (${route}) at ${effort} effort via patchbay${lib.optionalString readonly ", read-only advisory variant"}"''
        "model: ${route}"
        "effort: ${effort}"
      ]
      ++ lib.optional readonly profileAgentDenylist
      ++ [
        "---"
        ""
      ]
      ++ (
        if readonly
        then readonlyDirective
        else ["You are a Gambit model-profile agent. Follow the contract and brief given in your prompt exactly."]
      )
      ++ [""]
    ));

  # Both variants of every profile, as linkFarm entries.
  profileAgentEntries = lib.concatMap (
    profile:
      map (readonly: {
        name = "${profileAgentName profile readonly}.md";
        path = mkProfileAgent profile readonly;
      }) [false true]
  ) (lib.attrNames gambitProfiles);

  optionalClaudeProfileAgentEntries = routes:
    lib.concatMap (
      profile:
        map (readonly: {
          name = "${profileAgentName profile readonly}.md";
          path = mkProfileAgent profile readonly;
        }) [false true]
    ) (lib.attrNames (lib.filterAttrs (_: spec: builtins.elem spec.route routes) optionalClaudeProfiles));

  # Nested dispatch is opt-in independently of extension loading. Permit the
  # Orchestrator to reach exactly the non-Orchestrator role targets and advisory
  # variants, not arbitrary agents or itself.
  piOrchestratorChildren = lib.sort builtins.lessThan (lib.unique (lib.concatMap (
    role:
      map (profile: let
        target = gambitModelsFull.profiles.${profile};
      in
        if role.readonly or false
        then target.readonly_agent
        else target.agent) (role.ladder or [role.entry])
  ) (lib.attrValues (lib.removeAttrs gambitModelsFull.roles ["orchestrator"]))));

  # pi-subagents uses Pi frontmatter rather than Claude's patchbay fields.
  # Leaf agents keep extensions off except the fast-tier hook. Orchestrators
  # need task-state and process tools as well as ownership-scoped nested Agent;
  # do not expose pi-tasks' separate RPC dispatch/control tools. Skills remain
  # explicit contract-path loads. Read-only variants stay isolated leaves.
  mkPiProfileAgent = profile: readonly: let
    inherit (gambitProfiles.${profile}) route effort;
    agentName = profileAgentName profile readonly;
    model = "openai-codex/${routeModel route}";
    fast = routeFast route && !readonly;
    orchestrator = !readonly && profile == gambitModelsFull.roles.orchestrator.entry;
  in
    pkgs.writeText "gambit-pi-profile-${agentName}.md" (lib.concatStringsSep "\n" (
      [
        "---"
        "name: ${agentName}"
        ''description: "Gambit model profile: ${model} at ${effort} thinking${lib.optionalString fast ", fast tier"}${lib.optionalString readonly ", read-only advisory variant"}"''
        "model: ${model}"
        "thinking: ${effort}"
        ''tools: "${
            if readonly
            then "read, bash, grep, find, ls"
            else if orchestrator
            then "*, ext:pi-tasks/TaskCreate, ext:pi-tasks/TaskGet, ext:pi-tasks/TaskList, ext:pi-tasks/TaskUpdate, ext:pi-processes"
            else "*"
          }"''
        (
          if orchestrator
          then ''extensions: ["pi-tasks", "${orchestratorProcessExtension}"]''
          else if fast
          then ''extensions: ["${codexFastExtension}"]''
          else "extensions: false"
        )
        "skills: false"
      ]
      ++ lib.optional orchestrator ''allowed_subagents: "${lib.concatStringsSep ", " piOrchestratorChildren}"''
      ++ lib.optional readonly "isolated: true"
      ++ [
        "---"
        ""
      ]
      ++ (
        if readonly
        then readonlyDirective
        else if orchestrator
        then [
          "You are a Gambit Orchestrator. Follow the contract and phase brief exactly."
          "Dispatch children with run_in_background: true and record the returned IDs."
          "Join them with get_subagent_result(wait: true) before returning your report."
          "Nested children do not notify you; completing your run stops them."
          "For commands, use process start with turn notifications for results you need."
          "After starting a process, end your turn to yield; the harness keeps this run"
          "open until a native turn notification resumes you or all owned work ends."
          "Use notify.logMatches for readiness; context/ignore do not request a turn."
          "Never sleep, poll, or dispatch a model just to wait. Stop owned servers"
          "when finished, join nested children, then return your final report."
          "Use the scoped Agent tools, never shell-launched models or a parent proxy."
        ]
        else ["You are a Gambit model-profile agent. Follow the contract and brief given in your prompt exactly."]
      )
      ++ [""]
    ));

  # Pi-only profiles on the omakase gateway (home-manager/pi declares the
  # provider). No Claude Code twin: patchbay publishes no omakase route, and
  # the gateway pins reasoning effort per alias, so `thinking` here records
  # the alias's fixed effort rather than choosing one. These are for @deep /
  # @everyday mentions and Agent dispatch while work migrates off Codex; the
  # gambit role map below still resolves to the Codex profiles.
  omakasePiProfiles = {
    everyday = {
      model = "omakase/everyday";
      thinking = "medium";
    };
    deep = {
      model = "omakase/deep";
      thinking = "xhigh";
    };
  };

  mkOmakasePiProfileAgent = profile: readonly: let
    inherit (omakasePiProfiles.${profile}) model thinking;
    agentName = profileAgentName profile readonly;
  in
    pkgs.writeText "gambit-pi-profile-${agentName}.md" (lib.concatStringsSep "\n" (
      [
        "---"
        "name: ${agentName}"
        ''description: "Gambit model profile: ${model} (omakase gateway, effort pinned ${thinking})${lib.optionalString readonly ", read-only advisory variant"}"''
        "model: ${model}"
        "thinking: ${thinking}"
        ''tools: "${
            if readonly
            then "read, bash, grep, find, ls"
            else "*"
          }"''
        "extensions: false"
        "skills: false"
      ]
      ++ lib.optional readonly "isolated: true"
      ++ [
        "---"
        ""
      ]
      ++ (
        if readonly
        then readonlyDirective
        else ["You are a Gambit model-profile agent. Follow the contract and brief given in your prompt exactly."]
      )
      ++ [""]
    ));

  piProfileAgentEntries =
    lib.concatMap (
      profile:
        map (readonly: {
          name = "${profileAgentName profile readonly}.md";
          path = mkPiProfileAgent profile readonly;
        }) [false true]
    ) (lib.attrNames gambitProfiles)
    ++ lib.concatMap (
      profile:
        map (readonly: {
          name = "${profileAgentName profile readonly}.md";
          path = mkOmakasePiProfileAgent profile readonly;
        }) [false true]
    ) (lib.attrNames omakasePiProfiles);

  # ── Gambit profile/role map ────────────────────────────────────────────────
  # <profile>/gambit/models.json: what gambit reads to turn a role into a
  # dispatch. Two kinds of profile entry:
  #   - {agent, readonly_agent} — dispatch subagent_type=<agent> and NO model
  #     parameter; a readonly role takes readonly_agent instead. This is the
  #     only way a foreign model id reaches the wire (see mkProfileAgent above).
  #   - {model} — dispatch general-purpose/Explore with that enum model.
  # A role names its entry model profile; `readonly = true` marks an advisory
  # role that must not write.
  #
  # These role defaults are provisional policy selected by the user, not the
  # measured lowest-passing profiles from a completed evaluation campaign.
  # Keep deployment deferred until Gambit's consumers and this registry can
  # switch together. The intended flow places task-reviewer and
  # finding-verifier at task gates, runs conformance-reviewer and
  # integration-reviewer as the final passes, and sends every final finding to
  # finding-verifier.
  gambitModelsFull = {
    profiles =
      lib.mapAttrs (profile: _: {
        agent = profileAgentName profile false;
        readonly_agent = profileAgentName profile true;
      })
      gambitProfiles
      // {
        sonnet.model = "sonnet";
        opus.model = "opus";
        fable.model = "fable";
      };
    roles = {
      implementer.entry = "luna-low";
      scout = {
        entry = "terra-medium";
        readonly = true;
      };
      steelman = {
        entry = "astra-xhigh";
        readonly = true;
      };
      "task-reviewer" = {
        entry = "terra-medium";
        readonly = true;
      };
      "finding-verifier" = {
        entry = "terra-medium";
        readonly = true;
      };
      "conformance-reviewer" = {
        entry = "sol-high";
        readonly = true;
      };
      "integration-reviewer" = {
        entry = "sol-high";
        readonly = true;
      };
      "test-runner".entry = "luna-low";
      orchestrator.entry = "sol-high";
    };
  };

  # Claude-only map: the same provisional role policy with the current Claude
  # model choices and no GPT fallback. Used on hosts without the Codex upstream,
  # where patchbay publishes no chatgpt/* route for a profile to reach.
  gambitModelsClaudeOnly = {
    profiles = {
      sonnet.model = "sonnet";
      opus.model = "opus";
      fable.model = "fable";
    };
    roles = {
      implementer.entry = "opus";
      scout = {
        entry = "sonnet";
        readonly = true;
      };
      steelman = {
        entry = "fable";
        readonly = true;
      };
      "task-reviewer" = {
        entry = "fable";
        readonly = true;
      };
      "finding-verifier" = {
        entry = "fable";
        readonly = true;
      };
      "conformance-reviewer" = {
        entry = "fable";
        readonly = true;
      };
      "integration-reviewer" = {
        entry = "fable";
        readonly = true;
      };
      "test-runner".entry = "sonnet";
    };
  };
}
