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
in
  pkgs.runCommand "claude-codex-executors-check" {
    nativeBuildInputs = [pkgs.jq pkgs.yq-go python];
  } ''
    set -euo pipefail

    jq -e '
      .type == "stdio"
      and .command == "${pkgs.codex}/bin/codex"
      and .args == ["mcp-server"]
      and .timeout == 7200000
      and (keys | sort) == ["args", "command", "timeout", "type"]
    ' ${mcpServerJson} >/dev/null

    jq -e '
      (keys | sort) == ["finder", "steelman", "worker"]
      and all(.[];
        .executor == "codex"
        and .tool == "mcp__codex__codex"
        and .model == "gpt-5.6-sol"
        and .reasoning_effort == "xhigh"
        and .approval_policy == "never")
      and .steelman.sandbox == "read-only"
      and .steelman.web_search == "live"
      and .worker.sandbox == "danger-full-access"
      and (.worker | has("web_search") | not)
      and .finder.sandbox == "read-only"
      and .finder.web_search == "live"
    ' ${registryJson} >/dev/null

    yq -p=toml -o=json '.' ${isolationToml} > isolation.json
    jq -e '
      .plugins["gambit@personal"].enabled == false
      and .skills.include_instructions == false
      and .orchestrator.skills.enabled == false
      and .features.collab == false
      and .features.multi_agent_v2.enabled == false
    ' isolation.json >/dev/null

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
    ${pkgs.codex}/bin/codex mcp-server --help >/dev/null
    touch "$out"
  ''
