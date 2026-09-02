# Gambit's rung/role data — the single source of truth for which non-Claude
# ladder rungs exist, what each one is named, how it is rendered as a Claude
# Code subagent, and how roles map onto rungs.
#
# Imported by home-manager/claude-code/default.nix (which installs the agents
# and writes <profile>/gambit/models.json) and by tests/gambit-rung-agents.nix
# (which checks the two stay consistent). Nothing here reads `config`, so the
# check can import it without evaluating a host.
{
  lib,
  pkgs,
}: rec {
  # ── Gambit rung agents ──────────────────────────────────────────────────
  # Gambit's non-Claude ladder rungs ship as Claude Code SUBAGENT
  # DEFINITIONS, not as model parameters. The Agent tool's `model:` argument
  # is enum-locked (sonnet/opus/haiku/fable/inherit), so a patchbay route id
  # like chatgpt/sol can only reach the wire through a subagent's
  # frontmatter, whose `model` field accepts a full model id. Gambit
  # dispatches a rung by subagent_type and passes the real contract by path
  # in the prompt, so these bodies stay deliberately generic and minimal.
  #
  # Each `route` must be a route key patchbay publishes under codexUpstream;
  # home-manager/patchbay/chatgpt-models.nix owns that list and the check
  # asserts the two agree.
  gambitRungs = {
    "luna-low" = {
      route = "chatgpt/luna";
      effort = "low";
    };
    "sol-low" = {
      route = "chatgpt/sol";
      effort = "low";
    };
    "terra-medium" = {
      route = "chatgpt/terra";
      effort = "medium";
    };
    "sol-xhigh" = {
      route = "chatgpt/sol";
      effort = "xhigh";
    };
  };

  # The naming contract models.json depends on: a rung's writing agent is the
  # rung name, its advisory agent is the rung name plus "-ro".
  rungAgentName = rung: readonly: rung + lib.optionalString readonly "-ro";

  # The read-only denylist. `disallowedTools` is resolved before any `tools`
  # allowlist (Claude Code sub-agents reference), so this removes the
  # mutating tools outright: file edits, sub-dispatch (which could launch a
  # writing agent), and every MCP server (shimmer reaches Jira, GitLab,
  # Todoist, Monarch — all write-capable).
  rungAgentDenylist = "disallowedTools: Edit, Write, NotebookEdit, Agent, mcp__*";

  # What the -ro variants are told, over and above the denylist. Bash
  # survives the denylist because the read-only contracts (scout, steelman,
  # finder, verifier) are useless without git and search, so the bound on it
  # has to be stated in the body — a prompt-level rule, not a sandbox.
  readonlyDirective = [
    "You are a gambit rung agent in its READ-ONLY advisory variant. Follow the"
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
  mkRungAgent = rung: readonly: let
    inherit (gambitRungs.${rung}) route effort;
    agentName = rungAgentName rung readonly;
  in
    pkgs.writeText "gambit-rung-${agentName}.md" (lib.concatStringsSep "\n" (
      [
        "---"
        "name: ${agentName}"
        ''description: "Gambit rung: GPT-5.6 ${route} at ${effort} effort via patchbay${lib.optionalString readonly ", read-only advisory variant"}"''
        "model: ${route}"
        "effort: ${effort}"
      ]
      ++ lib.optional readonly rungAgentDenylist
      ++ [
        "---"
        ""
      ]
      ++ (
        if readonly
        then readonlyDirective
        else ["You are a gambit rung agent. Follow the contract and brief given in your prompt exactly."]
      )
      ++ [""]
    ));

  # Both variants of every rung, as linkFarm entries.
  rungAgentEntries = lib.concatMap (
    rung:
      map (readonly: {
        name = "${rungAgentName rung readonly}.md";
        path = mkRungAgent rung readonly;
      }) [false true]
  ) (lib.attrNames gambitRungs);

  # pi-subagents uses Pi model IDs and frontmatter rather than Claude Code's
  # patchbay route, effort, and camel-case denylist fields. Keep extensions
  # and skills out of rung children: Gambit passes the complete contract and
  # brief, and only the root orchestrator may mutate task state or dispatch.
  mkPiRungAgent = rung: readonly: let
    inherit (gambitRungs.${rung}) route effort;
    agentName = rungAgentName rung readonly;
    model = "openai-codex/gpt-5.6-${lib.removePrefix "chatgpt/" route}";
  in
    pkgs.writeText "gambit-pi-rung-${agentName}.md" (lib.concatStringsSep "\n" (
      [
        "---"
        "name: ${agentName}"
        ''description: "Gambit rung: ${model} at ${effort} thinking${lib.optionalString readonly ", read-only advisory variant"}"''
        "model: ${model}"
        "thinking: ${effort}"
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
        else ["You are a gambit rung agent. Follow the contract and brief given in your prompt exactly."]
      )
      ++ [""]
    ));

  # Pi-only rungs on the omakase gateway (home-manager/pi declares the
  # provider). No Claude Code twin: patchbay publishes no omakase route, and
  # the gateway pins reasoning effort per alias, so `thinking` here records
  # the alias's fixed effort rather than choosing one. These are for @deep /
  # @everyday mentions and Agent dispatch while work migrates off Codex; the
  # gambit role map below still resolves to the Codex rungs.
  omakasePiRungs = {
    everyday = {
      model = "omakase/everyday";
      thinking = "medium";
    };
    deep = {
      model = "omakase/deep";
      thinking = "xhigh";
    };
  };

  mkOmakasePiRungAgent = rung: readonly: let
    inherit (omakasePiRungs.${rung}) model thinking;
    agentName = rungAgentName rung readonly;
  in
    pkgs.writeText "gambit-pi-rung-${agentName}.md" (lib.concatStringsSep "\n" (
      [
        "---"
        "name: ${agentName}"
        ''description: "Gambit rung: ${model} (omakase gateway, effort pinned ${thinking})${lib.optionalString readonly ", read-only advisory variant"}"''
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
        else ["You are a gambit rung agent. Follow the contract and brief given in your prompt exactly."]
      )
      ++ [""]
    ));

  piRungAgentEntries =
    lib.concatMap (
      rung:
        map (readonly: {
          name = "${rungAgentName rung readonly}.md";
          path = mkPiRungAgent rung readonly;
        }) [false true]
    ) (lib.attrNames gambitRungs)
    ++ lib.concatMap (
      rung:
        map (readonly: {
          name = "${rungAgentName rung readonly}.md";
          path = mkOmakasePiRungAgent rung readonly;
        }) [false true]
    ) (lib.attrNames omakasePiRungs);

  # ── Gambit rung/role map ────────────────────────────────────────────────
  # <profile>/gambit/models.json: what gambit reads to turn a role into a
  # dispatch. Two kinds of rung entry:
  #   - {agent, readonly_agent} — dispatch subagent_type=<agent> and NO model
  #     parameter; a readonly role takes readonly_agent instead. This is the
  #     only way a foreign model id reaches the wire (see mkRungAgent above).
  #   - {model} — dispatch general-purpose/Explore with that enum model.
  # A role names its entry rung, plus the escalation ladder where it has one;
  # `readonly = true` marks an advisory role that must not write.
  gambitModelsFull = {
    rungs =
      lib.mapAttrs (rung: _: {
        agent = rungAgentName rung false;
        readonly_agent = rungAgentName rung true;
      })
      gambitRungs
      // {
        sonnet.model = "sonnet";
        opus.model = "opus";
        fable.model = "fable";
      };
    roles = {
      worker = {
        entry = "sol-low";
        ladder = ["sol-low" "terra-medium" "sol-xhigh" "opus"];
      };
      escalation = {
        entry = "terra-medium";
        ladder = ["terra-medium" "sol-xhigh" "opus"];
      };
      scout = {
        entry = "terra-medium";
        readonly = true;
      };
      steelman = {
        entry = "sol-xhigh";
        readonly = true;
      };
      finder = {
        entry = "sol-xhigh";
        readonly = true;
      };
      verifier = {
        entry = "sol-xhigh";
        readonly = true;
      };
      "test-runner".entry = "luna-low";
    };
  };

  # Claude-only map: no GPT rungs at all. Used on hosts without the Codex
  # upstream, where patchbay publishes no chatgpt/* route for a rung to reach.
  gambitModelsClaudeOnly = {
    rungs = {
      sonnet.model = "sonnet";
      opus.model = "opus";
      fable.model = "fable";
    };
    roles = {
      worker = {
        entry = "opus";
        ladder = ["opus" "fable"];
      };
      escalation = {
        entry = "fable";
        ladder = ["fable"];
      };
      scout = {
        entry = "sonnet";
        readonly = true;
      };
      steelman = {
        entry = "fable";
        readonly = true;
      };
      finder = {
        entry = "fable";
        readonly = true;
      };
      verifier = {
        entry = "fable";
        readonly = true;
      };
      "test-runner".entry = "sonnet";
    };
  };
}
