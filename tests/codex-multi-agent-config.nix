{
  pkgs,
  codexConfig,
}: let
  expectedSharedUsageHint = ''
    Note that collaboration tools cannot be called from inside `functions.exec`. Call `spawn_agent`, `send_message`, `followup_task`, `wait_agent`, `interrupt_agent`, and `list_agents` only as direct tool calls using the recipient shown in their tool definitions, such as `to=functions.gambit_agents.spawn_agent`, since they are intentionally absent from the `functions.exec` `tools.*` namespace. Available tools in `functions.exec` are explicitly described with a `tools` namespace in the developer message.

    All agents share the same directory. In detail:
    - All agents have access to the same container and filesystem as you.
    - All agents use the same current working directory.
    - As a result, edits made by one agent are immediately visible to all other agents.
  '';
  expectedRootUsageHint = ''
    You are `/root`, the primary agent in a team of agents collaborating to fulfill the user's goals.

    At the start of your turn, you are the active agent.
    You can spawn sub-agents to handle subtasks, and those sub-agents can spawn their own sub-agents.
    All agents in the team, including the agents that you can assign tasks to, are equally intelligent and capable, and have access to the same set of tools.

    You can use `spawn_agent` to create a new agent, `followup_task` to give an existing agent a new task and trigger a turn, and `send_message` to pass a message to a running agent without triggering a turn.
    `send_message` calls may be read by a human, so ensure they are legible. Always put proper spaces between words and/or numbers.
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

    ${expectedSharedUsageHint}
    There are 4 available concurrency slots, meaning that up to 4 agents can be active at once, including you.
  '';
  expectedSubagentUsageHint = ''
    You are an agent in a team of agents collaborating to complete a task.

    You can spawn sub-agents to handle subtasks, and those sub-agents can spawn their own sub-agents. All agents in the team, including the agents that you can assign tasks to, are equally intelligent and capable, and have access to the same set of tools.

    You can use `spawn_agent` to create a new agent, `followup_task` to give an existing agent a new task and trigger a turn, and `send_message` to pass a message to a running agent.
    `send_message` calls may be read by a human, so ensure they are legible. Always put proper spaces between words and/or numbers.
    Child agents can also spawn their own sub-agents.

    When you provide a response in the final channel, that content is immediately delivered back to your parent agent.
    In addition, your final answer may be read by a human, so ensure it is legible.

    You will receive messages in the analysis channel in the form:
    ```
    Message Type: NEW_TASK | MESSAGE | FINAL_ANSWER
    Task name: <recipient>
    Sender: <author>
    Payload:
    <payload text>
    ```
    You may also see them addressed as to=/root/..., which indicates your identity is /root/...

    ${expectedSharedUsageHint}
    There are 4 available concurrency slots, meaning that up to 4 agents can be active at once, including you.
  '';
  expectedRootUsageHintFile = pkgs.writeText "codex-expected-root-agent-usage-hint" expectedRootUsageHint;
  expectedSubagentUsageHintFile = pkgs.writeText "codex-expected-subagent-usage-hint" expectedSubagentUsageHint;
in
  pkgs.runCommand "codex-multi-agent-config-check" {} ''
    set -euo pipefail

    ${pkgs.yq-go}/bin/yq -p=toml -o=json '.' ${codexConfig} > config.json

    ${pkgs.jq}/bin/jq -e \
      --rawfile expectedRoot ${expectedRootUsageHintFile} \
      --rawfile expectedSubagent ${expectedSubagentUsageHintFile} \
      '
        .suppress_unstable_features_warning == true
        and .plugins."gambit@personal" == null
        and .features.multi_agent_v2.enabled == true
        and .features.multi_agent_v2.tool_namespace == "gambit_agents"
        and .features.multi_agent_v2.hide_spawn_agent_metadata == false
        and .features.multi_agent_v2.root_agent_usage_hint_text == $expectedRoot
        and .features.multi_agent_v2.subagent_usage_hint_text == $expectedSubagent
      ' config.json >/dev/null

    touch "$out"
  ''
