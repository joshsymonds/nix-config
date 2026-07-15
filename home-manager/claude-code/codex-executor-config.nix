{pkgs}: let
  common = {
    executor = "codex";
    tool = "mcp__codex__codex";
    model = "gpt-5.6-sol";
    reasoning_effort = "xhigh";
    approval_policy = "never";
  };
in {
  mcpServer = {
    type = "stdio";
    command = "${pkgs.codex}/bin/codex";
    args = ["mcp-server"];
    # Long implementation workers must not inherit Claude's ordinary MCP
    # timeout. Codex still owns its own per-turn and authentication limits.
    timeout = 7200000;
  };

  registry = {
    steelman =
      common
      // {
        sandbox = "read-only";
        web_search = "live";
      };
    worker =
      common
      // {
        sandbox = "danger-full-access";
      };
    finder =
      common
      // {
        sandbox = "read-only";
        web_search = "live";
      };
  };
}
