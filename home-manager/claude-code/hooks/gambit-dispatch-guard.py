#!/usr/bin/env python3
"""PreToolUse:Agent|Task guard for gambit worker dispatches.

The worker's brief is the source of truth for each dispatch. This hook only
runs the validator for the writing agents named by the worker role's entry and
ladder in the local Gambit registry. Malformed input and an unreadable registry
fail open, matching destructive-guard.py's documented policy.
"""
import json
import os
import subprocess
import sys
from typing import Any


MODELS_ENV = "GAMBIT_MODELS"
VALIDATOR_ENV = "GAMBIT_VALIDATE_DISPATCH"
DEFAULT_MODELS = "~/.claude/gambit/models.json"


def allow() -> None:
    raise SystemExit(0)


def deny(reason: str) -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    raise SystemExit(0)


def load_json_stdin() -> dict[str, Any]:
    value = json.load(sys.stdin)
    if not isinstance(value, dict):
        raise ValueError("hook input is not an object")
    return value


def worker_agents(registry_path: str) -> set[str]:
    with open(registry_path, encoding="utf-8") as registry_file:
        registry = json.load(registry_file)

    if not isinstance(registry, dict):
        raise ValueError("registry is not an object")
    rungs = registry["rungs"]
    roles = registry["roles"]
    if not isinstance(rungs, dict) or not isinstance(roles, dict):
        raise ValueError("registry has invalid rungs or roles")
    worker = roles["worker"]
    if not isinstance(worker, dict):
        raise ValueError("registry worker role is invalid")

    entry = worker["entry"]
    ladder = worker.get("ladder", [])
    if not isinstance(entry, str) or not isinstance(ladder, list) or not all(
        isinstance(rung, str) for rung in ladder
    ):
        raise ValueError("registry worker entry or ladder is invalid")

    agents: set[str] = set()
    for rung_name in [entry, *ladder]:
        rung = rungs[rung_name]
        if not isinstance(rung, dict) or not isinstance(rung.get("agent"), str):
            raise ValueError("registry worker rung is invalid")
        agents.add(rung["agent"])
    return agents


def prompt_path(prompt: Any, label: str) -> str | None:
    if not isinstance(prompt, str):
        return None
    prefix = f"{label}: "
    for line in prompt.splitlines():
        if line.startswith(prefix):
            value = line[len(prefix) :].strip()
            if value and os.path.isabs(value):
                return value
            return None
    return None


def main() -> None:
    try:
        event = load_json_stdin()
    except (json.JSONDecodeError, OSError, TypeError, ValueError):
        allow()

    if event.get("tool_name") not in {"Agent", "Task"}:
        allow()
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        allow()

    try:
        registry_path = os.path.expanduser(os.environ.get(MODELS_ENV, DEFAULT_MODELS))
        agents = worker_agents(registry_path)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        allow()

    if tool_input.get("subagent_type") not in agents:
        allow()

    brief = prompt_path(tool_input.get("prompt"), "Brief")
    workspace = prompt_path(tool_input.get("prompt"), "Workspace")
    if brief is None or workspace is None:
        missing = []
        if brief is None:
            missing.append("Brief")
        if workspace is None:
            missing.append("Workspace")
        deny(
            "Gambit worker dispatch is blocked because the prompt is missing "
            + " and ".join(missing)
            + " line(s) with absolute paths."
        )

    validator = os.environ.get(VALIDATOR_ENV, "")
    validator_path = os.path.expanduser(validator)
    if not validator_path or not os.path.isfile(validator_path):
        deny(
            "Gambit worker dispatch is blocked because "
            f"{VALIDATOR_ENV} is unset or missing: {validator or '<unset>'}."
        )

    try:
        result = subprocess.run(
            ["python3", validator_path, "--brief", brief, "--workspace", workspace],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    except OSError as error:
        deny(
            "Gambit worker dispatch is blocked because the validator could not "
            f"run: {error}."
        )

    if result.returncode != 0:
        output = result.stdout.strip() or "<validator produced no output>"
        deny(
            "Gambit worker dispatch is blocked because brief validation failed "
            f"(exit {result.returncode}): {output}"
        )


if __name__ == "__main__":
    main()
