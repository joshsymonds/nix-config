"""Tests for the pure-function half of morgen_notifier.

Network and filesystem are touched only by `main_cli`; the pure functions
below are what we lean on for correctness. Same testing strategy as
morgen-fetch — keep the pure side covered, accept that the I/O layer
fails loudly in journalctl if it drifts."""
from __future__ import annotations

from morgen_notifier import (
    event_threshold_due,
    events_due_for_notification,
    prune_fired_state,
    threshold_minutes,
    update_fired_state,
)


# ── threshold_minutes ────────────────────────────────────────────────


def test_threshold_minutes_returns_canonical_pairs():
    # Order matters for downstream determinism (10 then 2): a single
    # tick that crosses both windows would fire 10 first, which is the
    # more useful early-warning behavior.
    assert threshold_minutes() == [("fired_10", 10), ("fired_2", 2)]


# ── event_threshold_due ──────────────────────────────────────────────


def test_event_threshold_due_exact_match():
    start = 1_700_000_000_000
    now = start - 10 * 60 * 1000
    assert event_threshold_due(start, now, 10) is True


def test_event_threshold_due_within_tolerance_early():
    # 30s before the canonical T-10 moment (i.e. 10:30 to go) → still True.
    # 30s tolerance is the default and matches a 60s polling cadence.
    start = 1_700_000_000_000
    now = start - (10 * 60 + 30) * 1000
    assert event_threshold_due(start, now, 10) is True


def test_event_threshold_due_within_tolerance_late():
    # 30s after the canonical T-10 moment (9:30 to go) → still True.
    start = 1_700_000_000_000
    now = start - (10 * 60 - 30) * 1000
    assert event_threshold_due(start, now, 10) is True


def test_event_threshold_due_outside_tolerance_early():
    # 31s before T-10 → False. With tolerance=30s, 11:00 minus 31s is
    # outside the window. A 60s tick will catch it on the next pass.
    start = 1_700_000_000_000
    now = start - (10 * 60 + 31) * 1000
    assert event_threshold_due(start, now, 10) is False


def test_event_threshold_due_outside_tolerance_late():
    # 1 minute past the T-10 moment (only 9:00 left). The window has
    # already closed; we'd be on T-9, not T-10. False.
    start = 1_700_000_000_000
    now = start - (10 * 60 - 60) * 1000
    assert event_threshold_due(start, now, 10) is False


# ── events_due_for_notification ─────────────────────────────────────


def _ev(uid: str, start_ms: int, title: str = "Some meeting") -> dict:
    return {"uid": uid, "title": title, "start": start_ms}


def test_events_due_empty_when_nothing_in_window():
    # Far-future event: no threshold reached yet.
    now = 1_700_000_000_000
    events = [_ev("a", now + 60 * 60 * 1000)]   # 1 hour out
    assert events_due_for_notification(events, now, {}) == []


def test_events_due_returns_ten_min_entry_when_due():
    now = 1_700_000_000_000
    events = [_ev("a", now + 10 * 60 * 1000)]
    due = events_due_for_notification(events, now, {})
    assert len(due) == 1
    ev, state_key, threshold = due[0]
    assert ev["uid"] == "a"
    assert state_key == "fired_10"
    assert threshold == 10


def test_events_due_returns_two_min_entry_when_due():
    now = 1_700_000_000_000
    events = [_ev("a", now + 2 * 60 * 1000)]
    # Mark 10-min as already fired so it doesn't show up.
    fired = {"a": {"fired_10": True}}
    due = events_due_for_notification(events, now, fired)
    assert len(due) == 1
    _, state_key, threshold = due[0]
    assert state_key == "fired_2"
    assert threshold == 2


def test_events_due_skips_already_fired_threshold():
    # Event is at T-10; we've already fired the 10-min notification.
    # Result: nothing due.
    now = 1_700_000_000_000
    events = [_ev("a", now + 10 * 60 * 1000)]
    fired = {"a": {"fired_10": True}}
    assert events_due_for_notification(events, now, fired) == []


def test_events_due_handles_two_events_simultaneously():
    # Two distinct events, both at T-10 in the same tick. Both fire
    # independently — no cross-contamination of state.
    now = 1_700_000_000_000
    events = [
        _ev("a", now + 10 * 60 * 1000),
        _ev("b", now + 10 * 60 * 1000),
    ]
    due = events_due_for_notification(events, now, {})
    assert {e["uid"] for e, _, _ in due} == {"a", "b"}


def test_events_due_skips_events_missing_uid():
    # Defensive guard: _read_events should never feed us an event
    # without a uid (it filters those out), but events_due_for_notification
    # double-checks. A regression that removes the guard would crash
    # later in update_fired_state's ev["uid"] access.
    now = 1_700_000_000_000
    events = [{"title": "no uid", "start": now + 10 * 60 * 1000}]
    assert events_due_for_notification(events, now, {}) == []


def test_events_due_skips_events_missing_start():
    # Same as above but for start. Without the guard, event_threshold_due
    # would receive None and raise TypeError on the arithmetic.
    now = 1_700_000_000_000
    events = [{"uid": "no-start", "title": "x"}]
    assert events_due_for_notification(events, now, {}) == []


# ── update_fired_state ──────────────────────────────────────────────


def test_update_fired_state_does_not_mutate_input():
    original = {"a": {"fired_10": True}}
    updated = update_fired_state(original, "a", "fired_2")
    assert "fired_2" not in original.get("a", {})
    assert updated["a"]["fired_2"] is True


def test_update_fired_state_preserves_existing_thresholds_for_same_uid():
    state = {"a": {"fired_10": True}}
    updated = update_fired_state(state, "a", "fired_2")
    assert updated["a"]["fired_10"] is True
    assert updated["a"]["fired_2"] is True


def test_update_fired_state_creates_new_uid_entry():
    updated = update_fired_state({}, "new-uid", "fired_10")
    assert updated == {"new-uid": {"fired_10": True}}


# ── prune_fired_state ──────────────────────────────────────────────


def test_prune_fired_state_removes_uids_not_in_current_set():
    state = {"a": {"fired_10": True}, "b": {"fired_2": True}}
    pruned = prune_fired_state(state, {"a"})
    assert "a" in pruned
    assert "b" not in pruned


def test_prune_fired_state_returns_empty_when_nothing_current():
    state = {"a": {"fired_10": True}}
    assert prune_fired_state(state, set()) == {}


def test_prune_fired_state_does_not_mutate_input():
    state = {"a": {"fired_10": True}, "b": {"fired_2": True}}
    prune_fired_state(state, {"a"})
    # Original retains both entries.
    assert set(state.keys()) == {"a", "b"}
