#!/usr/bin/env python3
"""Merge Home Manager's Codex baseline without replacing mutable hook state."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
from typing import Any


class MergeError(ValueError):
    """Raised when the narrow Steward hook migration cannot be performed safely."""


_OWNED_EXECUTABLE = r"(?:steward|cc-tools|/nix/store/[^/\s]+/bin/(?:steward|cc-tools))"
_OWNED_STOP = re.compile(rf"^{_OWNED_EXECUTABLE} notify --harness codex$")
_OWNED_PROGRAM = re.compile(rf"^{_OWNED_EXECUTABLE}$")


def _load_object(path: str, label: str) -> dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise MergeError(f"cannot read {label} JSON: {error}") from error
    if not isinstance(value, dict):
        raise MergeError(f"{label} JSON must be an object")
    return value


def _recursive_baseline_wins(current: dict[str, Any], baseline: dict[str, Any]) -> dict[str, Any]:
    merged = copy.deepcopy(current)
    for key, baseline_value in baseline.items():
        current_value = merged.get(key)
        if isinstance(current_value, dict) and isinstance(baseline_value, dict):
            merged[key] = _recursive_baseline_wins(current_value, baseline_value)
        else:
            merged[key] = copy.deepcopy(baseline_value)
    return merged


def _is_owned_stop_handler(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and value.get("type") == "command"
        and isinstance(value.get("command"), str)
        and _OWNED_STOP.fullmatch(value["command"]) is not None
    )


def _groups(hooks: dict[str, Any], event: str) -> list[Any]:
    value = hooks.get(event, [])
    if not isinstance(value, list):
        raise MergeError(f"hooks.{event} must be an array")
    return value


def _handler_positions(groups: list[Any], event: str) -> list[tuple[int, int]]:
    owned: list[tuple[int, int]] = []
    for group_index, group in enumerate(groups):
        if not isinstance(group, dict):
            raise MergeError(f"hooks.{event}[{group_index}] must be an object")
        handlers = group.get("hooks", [])
        if not isinstance(handlers, list):
            raise MergeError(f"hooks.{event}[{group_index}].hooks must be an array")
        for handler_index, handler in enumerate(handlers):
            if _is_owned_stop_handler(handler):
                owned.append((group_index, handler_index))
    return owned


def _desired_handler(baseline: dict[str, Any]) -> dict[str, Any]:
    hooks = baseline.get("hooks")
    if not isinstance(hooks, dict):
        raise MergeError("baseline hooks must be an object")
    groups = _groups(hooks, "Stop")
    positions = _handler_positions(groups, "Stop")
    if len(positions) != 1:
        raise MergeError("baseline must declare exactly one canonical Steward Stop handler")
    group_index, handler_index = positions[0]
    handler = groups[group_index]["hooks"][handler_index]
    normalized = {
        "type": "command",
        "command": handler.get("command"),
        "timeout": 10,
        "async": False,
    }
    if handler != normalized:
        raise MergeError("baseline Steward Stop handler is not canonical")
    return copy.deepcopy(normalized)


def _is_owned_legacy_notify(value: Any) -> bool:
    if not isinstance(value, list) or len(value) not in (2, 4):
        return False
    if not isinstance(value[0], str) or _OWNED_PROGRAM.fullmatch(value[0]) is None:
        return False
    return value[1:] == ["notify"] or value[1:] == ["notify", "--harness", "codex"]


def _trusted_hash(command: str) -> str:
    normalized = {
        "event_name": "stop",
        "hooks": [
            {
                "async": False,
                "command": command,
                "timeout": 10,
                "type": "command",
            }
        ],
    }
    compact = json.dumps(normalized, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(compact.encode("utf-8")).hexdigest()


def merge_config(
    baseline: dict[str, Any], current: dict[str, Any], target: str
) -> dict[str, Any]:
    if not os.path.isabs(target):
        raise MergeError("target config path must be absolute")

    desired = _desired_handler(baseline)
    baseline_without_stop = copy.deepcopy(baseline)
    baseline_hooks = baseline_without_stop["hooks"]
    del baseline_hooks["Stop"]

    current_hooks = current.get("hooks", {})
    if not isinstance(current_hooks, dict):
        raise MergeError("current hooks must be an object")
    stop_groups = _groups(current_hooks, "Stop")
    positions = _handler_positions(stop_groups, "Stop")
    if len(positions) > 1:
        raise MergeError("multiple owned Steward Stop handlers; target left unchanged")

    subagent_groups = _groups(current_hooks, "SubagentStop")
    if _handler_positions(subagent_groups, "SubagentStop"):
        raise MergeError("owned Steward SubagentStop migration is unsupported; target left unchanged")

    merged = _recursive_baseline_wins(current, baseline_without_stop)
    if _is_owned_legacy_notify(merged.get("notify")):
        del merged["notify"]

    hooks = merged.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise MergeError("merged hooks must be an object")
    groups = hooks.setdefault("Stop", copy.deepcopy(stop_groups))
    if not isinstance(groups, list):
        raise MergeError("merged hooks.Stop must be an array")

    if positions:
        group_index, handler_index = positions[0]
        groups[group_index]["hooks"][handler_index] = desired
    else:
        groups.append({"hooks": [desired]})
        group_index = len(groups) - 1
        handler_index = 0

    state = hooks.setdefault("state", {})
    if not isinstance(state, dict):
        raise MergeError("hooks.state must be an object")
    key = f"{target}:stop:{group_index}:{handler_index}"
    own_state = state.get(key, {})
    if not isinstance(own_state, dict):
        raise MergeError(f"hooks.state[{key!r}] must be an object")
    own_state = copy.deepcopy(own_state)
    own_state["trusted_hash"] = _trusted_hash(desired["command"])
    own_state["enabled"] = True
    state[key] = own_state
    return merged


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="baseline JSON file")
    parser.add_argument("--current", required=True, help="current user JSON file")
    parser.add_argument("--target", required=True, help="absolute user config.toml path")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        baseline = _load_object(args.baseline, "baseline")
        current = _load_object(args.current, "current")
        merged = merge_config(baseline, current, args.target)
    except MergeError as error:
        print(f"codex merge: {error}", file=sys.stderr)
        return 2
    json.dump(merged, sys.stdout, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
