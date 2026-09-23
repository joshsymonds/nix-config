#!/usr/bin/env python3
"""PreToolUse:Agent|Task guard for Gambit Implementer dispatches.

The Implementer's brief is the source of truth for each dispatch. This hook
runs the validator for the writing agent named by the Implementer role's entry
model profile. Malformed hook input fails open, while registry failures deny
model-profile-shaped agents and leave unrelated agents untouched.
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


def implementer_dispatch(registry_path: str) -> tuple[set[str], str]:
    """Return the guarded agents and the Implementer's entry profile."""
    with open(registry_path, encoding="utf-8") as registry_file:
        registry = json.load(registry_file)

    if not isinstance(registry, dict):
        raise ValueError("registry is not an object")
    roles = registry.get("roles")
    if not isinstance(roles, dict):
        raise ValueError("registry roles are invalid")

    profiles = registry.get("profiles")
    implementer = roles.get("implementer")
    if not isinstance(profiles, dict) or not isinstance(implementer, dict):
        raise ValueError("registry has invalid profiles or Implementer role")
    if "ladder" in implementer:
        raise ValueError("registry Implementer role must be entry-only")
    entry = implementer.get("entry")
    if not isinstance(entry, str):
        raise ValueError("registry Implementer entry is invalid")
    profile = profiles.get(entry)
    if not isinstance(profile, dict) or not isinstance(profile.get("agent"), str):
        raise ValueError("registry Implementer profile is invalid")
    return {profile["agent"]}, entry


def is_profile_agent(agent: Any) -> bool:
    if not isinstance(agent, str):
        return False
    if agent.endswith("-ro"):
        agent = agent[:-3]
    return agent.endswith(("-low", "-medium", "-high", "-xhigh"))


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


def prompt_value(prompt: Any, label: str) -> str | None:
    if not isinstance(prompt, str):
        return None
    prefix = f"{label}: "
    for line in prompt.splitlines():
        if line.startswith(prefix):
            value = line[len(prefix) :].strip()
            return value or None
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

    agent = tool_input.get("subagent_type")
    registry_path = os.path.expanduser(os.environ.get(MODELS_ENV, DEFAULT_MODELS))
    try:
        agents, entry = implementer_dispatch(registry_path)
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        if is_profile_agent(agent):
            deny(
                "Gambit Implementer dispatch is blocked because the "
                f"{MODELS_ENV} registry could not be loaded at "
                f"{registry_path}: {error}."
            )
        allow()

    if agent not in agents:
        allow()

    brief = prompt_path(tool_input.get("prompt"), "Brief")
    workspace = prompt_path(tool_input.get("prompt"), "Workspace")
    record = prompt_path(tool_input.get("prompt"), "Record")
    task = prompt_value(tool_input.get("prompt"), "Task")
    if brief is None or workspace is None or record is None or task is None:
        missing = []
        if brief is None:
            missing.append("Brief")
        if workspace is None:
            missing.append("Workspace")
        if record is None:
            missing.append("Record")
        if task is None:
            missing.append("Task")
        deny(
            "Gambit Implementer dispatch is blocked because the prompt is missing "
            + " and ".join(missing)
            + " line(s)."
        )

    validator = os.environ.get(VALIDATOR_ENV, "")
    validator_path = os.path.expanduser(validator)
    if not validator_path or not os.path.isfile(validator_path):
        deny(
            "Gambit Implementer dispatch is blocked because "
            f"{VALIDATOR_ENV} is unset or missing: {validator or '<unset>'}."
        )

    try:
        result = subprocess.run(
            [
                "python3",
                validator_path,
                "--brief",
                brief,
                "--workspace",
                workspace,
                "--record",
                record,
                "--task",
                task,
                "--entry-profile",
                entry,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
    except OSError as error:
        deny(
            "Gambit Implementer dispatch is blocked because the validator could not "
            f"run: {error}."
        )

    if result.returncode != 0:
        output = result.stdout.strip() or "<validator produced no output>"
        deny(
            "Gambit Implementer dispatch is blocked because brief validation failed "
            f"(exit {result.returncode}): {output}"
        )


if __name__ == "__main__":
    main()
