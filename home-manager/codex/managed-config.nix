{
  gambitHasCodex,
  lib,
  pkgs,
}: let
  # Codex 0.144.4's default guidance names the default collaboration
  # namespace. Keep its complete role-specific semantics while pointing the
  # tool example at the non-reserved namespace configured below.
  multiAgentSharedUsageHint = ''
    Note that collaboration tools cannot be called from inside `functions.exec`. Call `spawn_agent`, `send_message`, `followup_task`, `wait_agent`, `interrupt_agent`, and `list_agents` only as direct tool calls using the recipient shown in their tool definitions, such as `to=functions.gambit_agents.spawn_agent`, since they are intentionally absent from the `functions.exec` `tools.*` namespace. Available tools in `functions.exec` are explicitly described with a `tools` namespace in the developer message.

    All agents share the same directory. In detail:
    - All agents have access to the same container and filesystem as you.
    - All agents use the same current working directory.
    - As a result, edits made by one agent are immediately visible to all other agents.
  '';
  multiAgentRootUsageHint = ''
    You are `/root`, the primary agent in a team of agents collaborating to fulfill the user's goals.

    At the start of your turn, you are the active agent.
    You can spawn sub-agents to handle subtasks, and those sub-agents can spawn their own sub-agents.
    All agents in the team, including the agents that you can assign tasks to, are equally intelligent and capable, and have access to the same set of tools.

    You can use `spawn_agent` to create a new agent, `followup_task` to give an existing agent a new task and trigger a turn, and `send_message` to pass a message to a running agent without triggering a turn.
    Child agents can also spawn their own sub-agents.
    You can decide how much context you want to propagate to your sub-agents with the `fork_turns` parameter.

    You will receive messages in the analysis channel in the form:
    ```
    Message Type: MESSAGE | FINAL_ANSWER
    Task name: <recipient>
    Sender: <author>
    Payload:
    <payload text>
    ```
    They may be addressed as to=/root

    ${multiAgentSharedUsageHint}
    There are 4 available concurrency slots, meaning that up to 4 agents can be active at once, including you.
  '';
  multiAgentSubagentUsageHint = ''
    You are an agent in a team of agents collaborating to complete a task.

    You can spawn sub-agents to handle subtasks, and those sub-agents can spawn their own sub-agents. All agents in the team, including the agents that you can assign tasks to, are equally intelligent and capable, and have access to the same set of tools.

    You can use `spawn_agent` to create a new agent, `followup_task` to give an existing agent a new task and trigger a turn, and `send_message` to pass a message to a running agent.
    Child agents can also spawn their own sub-agents.

    When you provide a response in the final channel, that content is immediately delivered back to your parent agent.

    You will receive messages in the analysis channel in the form:
    ```
    Message Type: NEW_TASK | MESSAGE | FINAL_ANSWER
    Task name: <recipient>
    Sender: <author>
    Payload:
    <payload text>
    ```
    You may also see them addressed as to=/root/..., which indicates your identity is /root/...

    ${multiAgentSharedUsageHint}
    There are 4 available concurrency slots, meaning that up to 4 agents can be active at once, including you.
  '';
in
  pkgs.writeText "codex-managed-config.toml" ''
    model = "gpt-5.6-sol"
    model_reasoning_effort = "xhigh"

    # Equivalent to --dangerously-bypass-approvals-and-sandbox. This machine
    # is intentionally configured to let Codex work outside the repo without
    # interrupting for per-command or per-directory confirmation.
    approval_policy = "never"
    sandbox_mode = "danger-full-access"
    suppress_unstable_features_warning = true

    ${lib.optionalString gambitHasCodex ''
        # Home Manager also materializes the matching cache entry below, so
        # Gambit is installed and enabled without mutable `codex plugin add` state.
      [plugins."gambit@personal"]
      enabled = true
    ''}

    [projects."/home/joshsymonds/nix-config"]
    trust_level = "trusted"

    # Exposing metadata lets Gambit select the named roles materialized below,
    # but changes spawn_agent's schema. The API reserves the default
    # collaboration.spawn_agent schema, so profile-aware spawning must use a
    # non-reserved namespace with matching usage hints.
    [features.multi_agent_v2]
    enabled = true
    tool_namespace = "gambit_agents"
    hide_spawn_agent_metadata = false
    root_agent_usage_hint_text = ${builtins.toJSON multiAgentRootUsageHint}
    subagent_usage_hint_text = ${builtins.toJSON multiAgentSubagentUsageHint}

    [tui]
    # Turn-complete notifications are intentionally off (no external notify
    # command, no "agent-turn-complete" here). Built-in terminal notification
    # covers approvals only.
    notifications = ["approval-requested"]
    notification_condition = "unfocused"
    notification_method = "auto"
    status_line = [
      "model-with-reasoning",
      "current-dir",
      "git-branch",
      "context-remaining",
      "five-hour-limit",
      "weekly-limit",
    ]
    status_line_use_colors = true
  ''
