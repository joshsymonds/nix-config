"""Tests for the pure-function half of morgen_fetch.

We don't test the HTTP layer or main() — they touch network/filesystem and
the cost/benefit of stubbing urllib doesn't pay off at this size. If the
API surface drifts (Morgen changes a field name), the systemd unit fails
loudly in journalctl and we'll know within minutes."""
from __future__ import annotations

import datetime as dt
import os
from pathlib import Path
from unittest.mock import patch

from morgen_fetch import (
    escape_text,
    extract_event_json,
    render_event,
    render_upcoming_events_json,
    to_utc_stamp,
)


# ── env-var path resolution (main_cli wiring) ───────────────────────


def _resolve_key_path() -> Path:
    """Mirror the logic of main_cli's key-path resolution. Pulled out
    so tests don't have to call main_cli (which calls sys.exit)."""
    raw = os.environ.get("MORGEN_FETCH_KEY_FILE") or "~/.config/morgen-fetch/api-key"
    return Path(os.path.expandvars(raw)).expanduser()


def test_resolve_key_path_expands_xdg_runtime_dir():
    # Home-manager agenix hands the systemd unit a path containing the
    # literal `${XDG_RUNTIME_DIR}` placeholder. systemd's Environment=
    # doesn't expand it; we have to. Without this, the service fails
    # with "missing API key at ${XDG_RUNTIME_DIR}/agenix/..." which is
    # exactly the regression that prompted this test.
    with patch.dict(os.environ, {
        "XDG_RUNTIME_DIR": "/run/user/1000",
        "MORGEN_FETCH_KEY_FILE": "${XDG_RUNTIME_DIR}/agenix/morgen-api-key",
    }, clear=False):
        assert _resolve_key_path() == Path("/run/user/1000/agenix/morgen-api-key")


def test_resolve_key_path_passes_through_already_resolved_path():
    with patch.dict(os.environ, {
        "MORGEN_FETCH_KEY_FILE": "/run/user/1000/agenix/morgen-api-key",
    }, clear=False):
        assert _resolve_key_path() == Path("/run/user/1000/agenix/morgen-api-key")


def test_resolve_key_path_expands_tilde_in_fallback():
    with patch.dict(os.environ, {}, clear=True):
        # No env var set → fall back to ~/.config/morgen-fetch/api-key,
        # which must expand to an absolute path under $HOME.
        result = _resolve_key_path()
        assert result.is_absolute()
        assert str(result).endswith("/.config/morgen-fetch/api-key")


# ── escape_text ─────────────────────────────────────────────────────

def test_escape_text_passthrough_for_plain_strings():
    assert escape_text("hello world") == "hello world"


def test_escape_text_escapes_semicolons():
    assert escape_text("a;b") == "a\\;b"


def test_escape_text_escapes_commas():
    assert escape_text("a,b") == "a\\,b"


def test_escape_text_escapes_newlines():
    assert escape_text("line one\nline two") == "line one\\nline two"


def test_escape_text_escapes_backslashes_first():
    # If we escaped backslash AFTER the others, the backslashes we
    # inserted to escape ;/,/\n would themselves get doubled. Verify by
    # mixing a literal backslash with another special — the result has
    # exactly one escape pass per special character.
    assert escape_text("a\\b;c") == "a\\\\b\\;c"


def test_escape_text_handles_all_specials_together():
    assert escape_text("a;b,c\nd\\e") == "a\\;b\\,c\\nd\\\\e"


# ── to_utc_stamp ────────────────────────────────────────────────────

def test_to_utc_stamp_utc_is_identity():
    assert to_utc_stamp("2024-01-15T10:00:00", "UTC") == "20240115T100000Z"


def test_to_utc_stamp_pst_adds_8_hours():
    # Mid-January in Los Angeles is PST (UTC-8) — 10:00 local = 18:00 UTC.
    assert (
        to_utc_stamp("2024-01-15T10:00:00", "America/Los_Angeles")
        == "20240115T180000Z"
    )


def test_to_utc_stamp_pdt_adds_7_hours():
    # July in LA is PDT (UTC-7) — confirms DST is honored, not assumed off.
    assert (
        to_utc_stamp("2024-07-15T10:00:00", "America/Los_Angeles")
        == "20240715T170000Z"
    )


def test_to_utc_stamp_empty_timezone_defaults_to_utc():
    # JSCalendar permits an empty/missing timeZone; we fall back to UTC
    # so the renderer never crashes on a malformed event.
    assert to_utc_stamp("2024-01-15T10:00:00", "") == "20240115T100000Z"


# ── render_event ────────────────────────────────────────────────────

DTSTAMP = "20240115T080000Z"


def _base_event(**overrides):
    base = {
        "uid": "abc-123",
        "title": "Test meeting",
        "start": "2024-01-15T10:00:00",
        "timeZone": "UTC",
        "duration": "PT1H",
    }
    base.update(overrides)
    return base


def _render(ev: dict) -> tuple[str, str]:
    """Test helper: render_event returns Optional[tuple]; in the happy-path
    tests we know the event has a UID, so unwrap once here and let the
    actual `None`-return contract be tested by the one explicit test for
    it. Keeps each happy-path test focused on the field it cares about."""
    result = render_event(ev, DTSTAMP)
    assert result is not None, "render_event returned None for an event with a UID"
    return result


def test_render_event_produces_filename_and_ics():
    fname, ics = _render(_base_event())
    assert fname == "abc-123.ics"
    assert "BEGIN:VCALENDAR" in ics
    assert "BEGIN:VEVENT" in ics
    assert "END:VEVENT" in ics
    assert "END:VCALENDAR" in ics


def test_render_event_emits_uid_with_morgen_suffix():
    _, ics = _render(_base_event())
    assert "UID:abc-123@morgen" in ics


def test_render_event_emits_summary():
    _, ics = _render(_base_event(title="Standup"))
    assert "SUMMARY:Standup" in ics


def test_render_event_emits_dtstart_in_utc():
    _, ics = _render(_base_event())
    assert "DTSTART:20240115T100000Z" in ics


def test_render_event_uses_duration_verbatim():
    _, ics = _render(_base_event(duration="PT30M"))
    assert "DURATION:PT30M" in ics


def test_render_event_returns_none_without_uid():
    ev = {"title": "no uid"}
    assert render_event(ev, DTSTAMP) is None


def test_render_event_falls_back_to_id_field():
    # Morgen sometimes returns `id` instead of `uid` for events
    # synced from M365 — the renderer should accept either.
    ev = _base_event()
    del ev["uid"]
    ev["id"] = "fallback-123"
    fname, ics = _render(ev)
    assert fname == "fallback-123.ics"
    assert "UID:fallback-123@morgen" in ics


def test_render_event_all_day_uses_value_date():
    ev = _base_event(
        start="2024-12-25T00:00:00",
        showWithoutTime=True,
    )
    _, ics = _render(ev)
    assert "DTSTART;VALUE=DATE:20241225" in ics
    assert "DTSTART:" not in ics.replace("DTSTART;", "")


def test_render_event_skips_mirror_events():
    # The N-way busy mirror workflow (morgen-mirror-workflow) creates
    # `[Busy]` events on other calendars. Their description carries the
    # marker "Calendar Propagation: Ref-Group-Id <id>#" — the same prefix
    # Morgen's own client uses to merge duplicates. Without filtering, the
    # khal vdir picks them up and the bar widget shows `[Busy]` as the
    # next meeting instead of the real source event.
    ev = _base_event(
        title="[Busy]",
        description="Calendar Propagation: Ref-Group-Id abc123#",
    )
    assert render_event(ev, DTSTAMP) is None


def test_render_event_sanitizes_filename_but_preserves_uid_in_body():
    # Real Morgen UIDs sometimes contain slashes and colons that aren't
    # legal in POSIX filenames — only the filename gets scrubbed.
    fname, ics = _render(_base_event(uid="a/b:c?d"))
    assert "/" not in fname
    assert ":" not in fname
    assert "?" not in fname
    assert "UID:a/b:c?d@morgen" in ics


def test_render_event_escapes_punctuation_in_summary():
    _, ics = _render(_base_event(title="Sync, with; commas"))
    assert "SUMMARY:Sync\\, with\\; commas" in ics


def test_render_event_defaults_title_when_missing():
    ev = _base_event()
    del ev["title"]
    _, ics = _render(ev)
    assert "SUMMARY:(no title)" in ics


def test_render_event_ics_uses_crlf_line_endings():
    # RFC 5545 mandates CRLF; some parsers tolerate bare LF but khal
    # (and conservative ICS handlers) have been known to mis-fold lines
    # without it. Check that every line is CRLF-terminated.
    _, ics = _render(_base_event())
    lines = ics.split("\r\n")
    # Last element is empty (trailing \r\n) — drop it and confirm every
    # remaining line is non-empty and doesn't contain a bare \n.
    assert lines[-1] == ""
    for line in lines[:-1]:
        assert line
        assert "\n" not in line


# ── extract_event_json ──────────────────────────────────────────────
# Pure function: takes a JSCalendar event dict + a `now` datetime, returns
# either None (past event / no id) or the dict shape upcoming-events.json
# emits. URL handling is the headline addition: pull from
# morgen.so:derived.virtualRoom.url, coerce empty/missing to None.

# `now` for all these tests is 09:00 UTC on Jan 15, 2024. The _base_event
# helper produces an event starting at 10:00 UTC the same day, so by
# default it's in the future. Tests that need the past override `start`.
NOW_2024 = dt.datetime(2024, 1, 15, 9, 0, 0, tzinfo=dt.timezone.utc)


def _extract(ev: dict, now: dt.datetime = NOW_2024) -> dict:
    """Test helper mirroring _render: happy-path tests know the event has
    a UID and is in the future, so unwrap the Optional once and let the
    None-return contract be tested by dedicated tests."""
    result = extract_event_json(ev, now)
    assert result is not None, "extract_event_json returned None unexpectedly"
    return result


def test_extract_event_json_basic():
    result = _extract(_base_event())
    assert result["uid"] == "abc-123"
    assert result["title"] == "Test meeting"
    assert result["start"] == "2024-01-15T10:00:00Z"
    assert result["end"] == "2024-01-15T11:00:00Z"  # PT1H default duration
    assert result["url"] is None  # no virtualRoom in _base_event


def test_extract_event_json_skips_past_events():
    ev = _base_event(start="2024-01-15T08:00:00")  # 1 hour before NOW_2024
    assert extract_event_json(ev, NOW_2024) is None


def test_extract_event_json_skips_mirror_events():
    # Companion to test_render_event_skips_mirror_events. The JSON path
    # feeds the meeting pill AND morgen-notifier; if mirrors leak through
    # here, the pill shows `[Busy]` and the user gets T-10/T-2 desktop
    # notifications for an event that's just an opaque busy block.
    ev = _base_event(
        title="[Busy]",
        description="Calendar Propagation: Ref-Group-Id abc123#",
    )
    assert extract_event_json(ev, NOW_2024) is None


def test_extract_event_json_skips_all_day_events():
    # Morgen flags all-day events with `showWithoutTime: true` and a null
    # timeZone. Without an explicit guard, extract_event_json's UTC
    # fallback would stamp "2024-01-15T00:00:00" as midnight UTC and the
    # pill would countdown to that — wrong for a 24-hour day-context
    # entry like Eurovision or a holiday. Drop them.
    ev = _base_event(
        start="2024-01-16T00:00:00",
        timeZone=None,
        showWithoutTime=True,
        duration="PT24H",
    )
    assert extract_event_json(ev, NOW_2024) is None


def test_extract_event_json_returns_none_without_uid_or_id():
    ev = _base_event()
    del ev["uid"]
    # _base_event doesn't add an "id" field, so with uid removed there's
    # no stable identifier; extract returns None for the same reason
    # render_event does.
    assert extract_event_json(ev, NOW_2024) is None


def test_extract_event_json_falls_back_to_id_field():
    # Mirrors render_event's behavior — Morgen returns `id` for events
    # synced from some providers (notably M365).
    ev = _base_event()
    del ev["uid"]
    ev["id"] = "fallback-123"
    assert _extract(ev)["uid"] == "fallback-123"


def test_extract_event_json_pulls_url_from_virtual_room():
    ev: dict = _base_event()
    ev["morgen.so:derived"] = {"virtualRoom": {"url": "https://zoom.us/j/123"}}
    assert _extract(ev)["url"] == "https://zoom.us/j/123"


def test_extract_event_json_url_is_none_when_empty_string():
    # Morgen sometimes returns an empty-string URL for events the API
    # couldn't extract a join link from. Downstream code expects None for
    # "no URL"; coercing avoids the consumer having to special-case "".
    ev: dict = _base_event()
    ev["morgen.so:derived"] = {"virtualRoom": {"url": ""}}
    assert _extract(ev)["url"] is None


def test_extract_event_json_handles_missing_virtualRoom():
    # `morgen.so:derived` present but `virtualRoom` absent — common for
    # in-person events Morgen has classified but found no join link in.
    ev: dict = _base_event()
    ev["morgen.so:derived"] = {}
    assert _extract(ev)["url"] is None


def test_extract_event_json_handles_missing_derived_block_entirely():
    ev = _base_event()
    # _base_event already lacks "morgen.so:derived"; confirm extract is
    # robust to the whole block being absent (not just sub-keys missing).
    assert "morgen.so:derived" not in ev
    assert _extract(ev)["url"] is None


def test_extract_event_json_end_from_explicit_duration():
    assert _extract(_base_event(duration="PT30M"))["end"] == "2024-01-15T10:30:00Z"


def test_extract_event_json_end_falls_back_for_unparseable_duration():
    # render_event's existing fallback is "default PT1H if duration is
    # weird" — extract_event_json mirrors that so the two outputs stay
    # consistent for the same event.
    assert _extract(_base_event(duration="garbage"))["end"] == "2024-01-15T11:00:00Z"


def test_extract_event_json_translates_local_time_to_utc():
    # Same arithmetic as to_utc_stamp but emitted in ISO-with-colons form.
    # Jan in LA is PST (UTC-8); 10:00 local → 18:00 UTC.
    ev = _base_event(timeZone="America/Los_Angeles")
    # Use a `now` early enough that the LA-translated start is still in
    # the future when interpreted as UTC.
    now = dt.datetime(2024, 1, 15, 0, 0, 0, tzinfo=dt.timezone.utc)
    result = _extract(ev, now)
    assert result["start"] == "2024-01-15T18:00:00Z"
    assert result["end"] == "2024-01-15T19:00:00Z"


# ── render_upcoming_events_json ─────────────────────────────────────


def test_render_upcoming_events_json_filters_past_and_sorts():
    events = [
        _base_event(uid="future-late", start="2024-01-15T14:00:00"),
        _base_event(uid="past", start="2024-01-15T08:00:00"),
        _base_event(uid="future-early", start="2024-01-15T11:00:00"),
    ]
    result = render_upcoming_events_json(events, NOW_2024)
    assert [e["uid"] for e in result] == ["future-early", "future-late"]


def test_render_upcoming_events_json_empty_list():
    assert render_upcoming_events_json([], NOW_2024) == []


def test_render_upcoming_events_json_skips_events_without_id():
    events = [
        _base_event(uid="has-id", start="2024-01-15T11:00:00"),
        {"title": "no uid", "start": "2024-01-15T12:00:00", "timeZone": "UTC"},
    ]
    result = render_upcoming_events_json(events, NOW_2024)
    assert len(result) == 1
    assert result[0]["uid"] == "has-id"
