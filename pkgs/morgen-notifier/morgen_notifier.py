"""Fire desktop notifications at T-10 and T-2 for upcoming Morgen meetings.

Reads `~/.local/share/morgen-fetch/upcoming-events.json` once per
systemd-timer tick (every 60 s), figures out which events are inside the
±30 s tolerance band around T-10 or T-2 minutes-until-start, and fires
`notify-send` for each one — at most once per (uid, threshold) pair
across the lifetime of the event.

Deduplication is kept in `~/.cache/morgen-notifier/fired.json`:

    {"<uid>": {"fired_10": true, "fired_2": true}, ...}

Entries are pruned once the matching event leaves
upcoming-events.json (event ended, was deleted, or the user moved the
start time so far that morgen-fetch stopped emitting it). Without
pruning the state file would grow forever; with it, the working set
matches what's actually on the upcoming list.

## Why URL ends up in the notification body, not as an action

The Epic spec (Task #23) initially called for
`notify-send --action="open=Join"` to launch a browser on click. In
practice that wiring requires notify-send `--wait` to receive the
ActionInvoked dbus signal, which blocks the calling process until the
notification is dismissed. Bad fit for a oneshot timer-driven daemon —
we'd accumulate stuck processes.

Resolution adopted here: embed the URL in the notification body. The
DMS notification panel auto-detects URLs and renders them as clickable
chips, and the meeting pill itself is click-to-join (the body URL is a
secondary path). If a non-DMS notification daemon ever needs first-class
join buttons we can add a long-running listener as a separate package;
the notifier itself stays simple."""
from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

# ── Paths and constants ─────────────────────────────────────────────

DEFAULT_EVENTS_PATH = Path.home() / ".local/share/morgen-fetch/upcoming-events.json"
DEFAULT_STATE_PATH = Path.home() / ".cache/morgen-notifier/fired.json"

# 30 s tolerance against the 60 s polling cadence: any T-10 or T-2 instant
# is guaranteed to fall inside exactly one tick's window. Wider (e.g. 60 s)
# and we could double-fire across ticks; narrower (e.g. 10 s) and a tick
# that lands halfway between windows could miss the notification entirely.
_TOLERANCE_S = 30


def threshold_minutes() -> list[tuple[str, int]]:
    """Canonical (state_key, minutes) pairs. Ordered so the 10-min
    early-warning fires before the 2-min critical alert when both
    happen to be due in the same tick."""
    return [("fired_10", 10), ("fired_2", 2)]


# ── Pure helpers (the test surface) ─────────────────────────────────


def event_threshold_due(start_ms: int, now_ms: int, minutes: int, tolerance_s: int = _TOLERANCE_S) -> bool:
    """Is `start - now` within ±tolerance of `minutes` minutes?

    Times are in milliseconds since epoch (matches Date.now() / JS-ish
    timestamps, which is what we end up with after json-parsing ISO 8601).
    A True return means right NOW is the moment to fire the notification
    for this threshold."""
    target_ms = minutes * 60 * 1000
    return abs((start_ms - now_ms) - target_ms) <= tolerance_s * 1000


def events_due_for_notification(
    events: list[dict],
    now_ms: int,
    fired_state: dict,
) -> list[tuple[dict, str, int]]:
    """For each (event, threshold) pair where the event is currently
    inside the threshold's tolerance band AND we haven't already fired
    that pair, yield a (event, state_key, minutes) tuple.

    Result is flat — main_cli iterates and fires each tuple's
    notification independently, then folds the result back into
    fired_state."""
    due: list[tuple[dict, str, int]] = []
    for ev in events:
        uid = ev.get("uid")
        start_ms = ev.get("start")
        if uid is None or start_ms is None:
            continue
        already = fired_state.get(uid, {})
        for state_key, minutes in threshold_minutes():
            if already.get(state_key):
                continue
            if event_threshold_due(start_ms, now_ms, minutes):
                due.append((ev, state_key, minutes))
    return due


def update_fired_state(fired_state: dict, uid: str, state_key: str) -> dict:
    """Pure: returns a new dict reflecting `fired_state[uid][state_key]
    = True`. Doesn't mutate the input — callers fold a sequence of
    these into the running state, then write the final dict atomically."""
    new_state = {k: dict(v) for k, v in fired_state.items()}
    new_state.setdefault(uid, {})[state_key] = True
    return new_state


def prune_fired_state(fired_state: dict, current_uids: set) -> dict:
    """Drop entries for uids no longer present in upcoming-events.json.
    Returns a new dict; doesn't mutate. Same pattern as render_event's
    keep-set in morgen-fetch — converge state to reality on every tick."""
    return {uid: dict(v) for uid, v in fired_state.items() if uid in current_uids}


# ── I/O helpers ─────────────────────────────────────────────────────


def _read_events(path: Path) -> list[dict] | None:
    """Returns the events list, or None when the file doesn't exist yet
    (cold start — morgen-fetch hasn't written its first JSON). Other
    parse errors bubble up so systemd's status reports them."""
    try:
        raw = path.read_text()
    except FileNotFoundError:
        return None
    parsed = json.loads(raw)
    if not isinstance(parsed, list):
        return []
    # Convert ISO 8601 "...Z" timestamps to ms since epoch so the pure
    # functions can keep doing simple arithmetic. We pass the converted
    # dicts onward — start becomes an int.
    out: list[dict] = []
    for ev in parsed:
        start_iso = ev.get("start")
        if not start_iso:
            continue
        try:
            d = dt.datetime.fromisoformat(start_iso.replace("Z", "+00:00"))
        except ValueError:
            continue
        out.append({
            **ev,
            "start": int(d.timestamp() * 1000),
        })
    return out


def _read_state(path: Path) -> dict:
    """Returns existing dedup state, or {} when the file doesn't exist
    (first run). Malformed JSON resets to {} too — better to lose dedup
    once than to crash the daemon and miss every future notification."""
    try:
        raw = path.read_text()
    except FileNotFoundError:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _write_state_atomic(path: Path, state: dict) -> None:
    """Write to .tmp + rename, matching morgen-fetch's pattern. POSIX
    rename within the same filesystem is atomic, so a concurrent reader
    sees either the old file or the new one — never a partial write."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.replace(path)


def _fire_notification(title: str, body: str, urgency: str) -> None:
    """One-shot notify-send call. Stderr is left attached to the
    daemon's stderr so failures show in journalctl. Non-zero exit
    propagates as a CalledProcessError — main_cli catches it and
    keeps processing remaining events instead of crashing the whole tick."""
    subprocess.run(
        [
            "notify-send",
            "--app-name=morgen-notifier",
            f"--urgency={urgency}",
            "--icon=appointment-soon",
            title,
            body,
        ],
        check=True,
    )


# ── main ────────────────────────────────────────────────────────────


def main_cli() -> int:
    events_path = Path(os.environ.get("MORGEN_NOTIFIER_EVENTS", DEFAULT_EVENTS_PATH))
    state_path = Path(os.environ.get("MORGEN_NOTIFIER_STATE", DEFAULT_STATE_PATH))

    events = _read_events(events_path)
    if events is None:
        # Cold start before morgen-fetch's first run. Silent no-op so
        # systemd doesn't mark this tick as failed during the boot
        # window.
        return 0

    fired = _read_state(state_path)
    now_ms = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)

    due = events_due_for_notification(events, now_ms, fired)
    for ev, state_key, minutes in due:
        urgency = "critical" if minutes <= 2 else "normal"
        title = f"Meeting in {minutes} minute{'s' if minutes != 1 else ''}"
        body_parts = [ev.get("title") or "(no title)"]
        url = ev.get("url")
        if url:
            # URL on its own line keeps DMS's auto-detect tidy; users
            # who copy-paste see one neat link below the title.
            body_parts.append(url)
        try:
            _fire_notification(title, "\n".join(body_parts), urgency)
        except FileNotFoundError:
            print("morgen-notifier: notify-send not on PATH", file=sys.stderr)
            return 1
        except subprocess.CalledProcessError as e:
            print(f"morgen-notifier: notify-send failed: {e}", file=sys.stderr)
            # Don't update state — we'll retry next tick (still inside
            # the tolerance window for most failure modes).
            continue
        fired = update_fired_state(fired, ev["uid"], state_key)

    current_uids = {ev["uid"] for ev in events if ev.get("uid")}
    fired = prune_fired_state(fired, current_uids)
    _write_state_atomic(state_path, fired)
    return 0


if __name__ == "__main__":
    raise SystemExit(main_cli())
