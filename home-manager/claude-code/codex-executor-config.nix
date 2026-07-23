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
    worker =
      common
      // {
        reply_tool = "mcp__codex__codex-reply";
        model = "gpt-5.6-luna";
        reasoning_effort = "high";
        service_tier = "fast";
        sandbox = "danger-full-access";
      };
    escalation =
      common
      // {
        model = "gpt-5.6-sol";
        reasoning_effort = "high";
        sandbox = "danger-full-access";
      };
    escalation-final =
      solXhigh
      // {
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
