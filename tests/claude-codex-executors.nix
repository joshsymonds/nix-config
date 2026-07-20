{
  pkgs,
  executorConfig,
  subagentIsolation,
  gambit,
}: let
  python = pkgs.python3.withPackages (ps: [ps.jsonschema]);
  mcpServerJson = pkgs.writeText "claude-codex-mcp-server.json" (builtins.toJSON executorConfig.mcpServer);
  registryJson = pkgs.writeText "gambit-codex-executors.json" (builtins.toJSON executorConfig.registry);
  isolationToml = pkgs.writeText "codex-subagent-isolation.toml" subagentIsolation;
  interactiveConfigToml = import ../home-manager/codex/managed-config.nix {
    inherit pkgs;
    lib = pkgs.lib;
    ccTools = "/test/cc-tools";
    gambitHasCodex = true;
  };
in
  pkgs.runCommand "claude-codex-executors-check" {
    nativeBuildInputs = [pkgs.jq pkgs.yq-go python];
  } ''
    set -euo pipefail

    jq -e '
      .type == "stdio"
      and .command == "${pkgs.codex}/bin/codex"
      and .args == ["-c", "features.apps=false", "mcp-server"]
      and .timeout == 7200000
      and (keys | sort) == ["args", "command", "timeout", "type"]
    ' ${mcpServerJson} >/dev/null

    jq -e '
      (keys | sort) == ["escalation", "finder", "scout", "steelman", "test-runner", "verifier", "worker"]
      and all(.[];
        .executor == "codex"
        and .tool == "mcp__codex__codex"
        and .approval_policy == "never")
      and .steelman.model == "gpt-5.6-sol"
      and .steelman.reasoning_effort == "xhigh"
      and .steelman.sandbox == "read-only"
      and .steelman.web_search == "live"
      and .scout.model == "gpt-5.6-terra"
      and .scout.reasoning_effort == "max"
      and .scout.sandbox == "read-only"
      and (.scout | has("web_search") | not)
      and .finder.model == "gpt-5.6-sol"
      and .finder.reasoning_effort == "xhigh"
      and .finder.sandbox == "read-only"
      and .finder.web_search == "live"
      and .verifier.model == "gpt-5.6-sol"
      and .verifier.reasoning_effort == "xhigh"
      and .verifier.sandbox == "read-only"
      and (.verifier | has("web_search") | not)
      and .["test-runner"].model == "gpt-5.6-luna"
      and .["test-runner"].reasoning_effort == "low"
      and .["test-runner"].sandbox == "danger-full-access"
      and (.["test-runner"] | has("web_search") | not)
      and .worker.model == "gpt-5.6-luna"
      and .worker.reasoning_effort == "high"
      and .worker.service_tier == "fast"
      and .worker.reply_tool == "mcp__codex__codex-reply"
      and .worker.sandbox == "danger-full-access"
      and (.worker | has("web_search") | not)
      and .escalation.model == "gpt-5.6-sol"
      and .escalation.reasoning_effort == "high"
      and .escalation.sandbox == "danger-full-access"
      and (.escalation | has("service_tier") | not)
      and (.escalation | has("web_search") | not)
    ' ${registryJson} >/dev/null

    yq -p=toml -o=json '.' ${isolationToml} > isolation.json
    jq -e '
      .plugins["gambit@personal"].enabled == false
      and .skills.include_instructions == false
      and .orchestrator.skills.enabled == false
      and .features.multi_agent == false
      and .features.multi_agent_v2.enabled == false
      and .features.apps == false
    ' isolation.json >/dev/null

    yq -p=toml -o=json '.' ${interactiveConfigToml} > interactive.json
    jq -e '
      ((.features | has("apps") | not) or .features.apps == true)
    ' interactive.json >/dev/null

    python - <<'PY'
    import json
    import re
    from pathlib import Path

    import jsonschema

    contract = Path("${gambit}/contracts/executors.md").read_text(encoding="utf-8")
    match = re.search(r"```json\n(.*?)\n```", contract, re.DOTALL)
    if match is None:
        raise SystemExit("executor contract JSON schema not found")
    schema = json.loads(match.group(1))
    registry = json.loads(Path("${registryJson}").read_text(encoding="utf-8"))
    jsonschema.Draft202012Validator(schema).validate(registry)
    PY

    test -x ${pkgs.codex}/bin/codex
    ${pkgs.codex}/bin/codex -c features.apps=false mcp-server --help >/dev/null
    touch "$out"
  ''
