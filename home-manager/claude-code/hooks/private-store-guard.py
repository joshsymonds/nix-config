#!/usr/bin/env python3
"""PreToolUse guard for commands and reads targeting the protected store."""

import json
import os
import re
import sys
from typing import NoReturn, cast

_PROTECTED_ROOT = "/run/strongbox"
_PROTECTED_TOOLS = {"Read": "file_path", "Grep": "path", "Glob": "path"}
_TOKEN = re.compile(r"\bstrongbox\b")


def allow() -> NoReturn:
    sys.exit(0)


def deny(reason: str) -> NoReturn:
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
    sys.exit(0)


def is_protected_path(path: str) -> bool:
    normalized = os.path.normpath(path)
    return normalized == _PROTECTED_ROOT or normalized.startswith(_PROTECTED_ROOT + "/")


def main() -> None:
    try:
        raw_event = cast(object, json.loads(sys.stdin.read() or "{}"))
        if not isinstance(raw_event, dict):
            allow()
        event = cast(dict[str, object], raw_event)

        tool_name = event.get("tool_name")
        raw_input = event.get("tool_input")
        if not isinstance(raw_input, dict):
            allow()
        tool_input = cast(dict[str, object], raw_input)

        if tool_name == "Bash":
            command = tool_input.get("command")
            if isinstance(command, str) and _TOKEN.search(command):
                deny("Bash commands containing the protected token are blocked.")
            allow()

        if not isinstance(tool_name, str):
            allow()
        path_key = _PROTECTED_TOOLS.get(tool_name)
        if path_key is None:
            allow()
        path = tool_input.get(path_key)
        if isinstance(path, str) and is_protected_path(path):
            deny(f"{tool_name} access under {_PROTECTED_ROOT} is blocked.")
    except Exception:
        allow()

    allow()


if __name__ == "__main__":
    main()
