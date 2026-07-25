{pkgs}: let
  common = {
    executor = "codex";
    tool = "mcp__codex__codex";
    approval_policy = "never";
  };
  solXhigh =
    common
    // {
      model = "gpt-5.6-sol";
      reasoning_effort = "xhigh";
    };
in {
  mcpServer = {
    type = "stdio";
    command = "${pkgs.codex}/bin/codex";
    args = ["-c" "features.apps=false" "mcp-server"];
    # Long implementation workers must not inherit Claude's ordinary MCP
    # timeout. Codex still owns its own per-turn and authentication limits.
    timeout = 7200000;
  };

  registry = {
    steelman =
      solXhigh
      // {
        sandbox = "read-only";
        web_search = "live";
      };
    scout =
      common
      // {
        model = "gpt-5.6-terra";
        reasoning_effort = "medium";
        sandbox = "read-only";
      };
    # Repair ladder, ordered by the tiltyard Round-1 Pareto frontier over
    # correctness and wall-clock. Every other seat measured was strictly
    # dominated on both axes, including the previous luna-high worker.
    #
    #   rung 1  sol-low        80% solved, 108s/task
    #   rung 3  terra-medium   90% solved, 159s/task
    #   rung 4  (native Claude) 100% solved
    #
    # escalation-final is deliberately absent: gambit resolves an omitted role to
    # native execution at its most-capable tier, which ends the ladder on Opus
    # without spending the 5-hour Claude window on rungs 1-3. Terra halves how
    # often rung 4 is reached versus escalating straight from sol-low, which is
    # the whole reason the middle rung exists — expected wall-clock is the same.
    worker =
      common
      // {
        reply_tool = "mcp__codex__codex-reply";
        model = "gpt-5.6-sol";
        reasoning_effort = "low";
        service_tier = "fast";
        sandbox = "danger-full-access";
      };
    escalation =
      common
      // {
        model = "gpt-5.6-terra";
        reasoning_effort = "medium";
        sandbox = "danger-full-access";
      };
    finder =
      solXhigh
      // {
        sandbox = "read-only";
        web_search = "live";
      };
    verifier =
      solXhigh
      // {
        sandbox = "read-only";
      };
    test-runner =
      common
      // {
        model = "gpt-5.6-luna";
        reasoning_effort = "low";
        sandbox = "danger-full-access";
      };
  };
}
