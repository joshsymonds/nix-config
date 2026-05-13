"""Tests for the pure-function half of morgen_fetch.

We don't test the HTTP layer or main() — they touch network/filesystem and
the cost/benefit of stubbing urllib doesn't pay off at this size. If the
API surface drifts (Morgen changes a field name), the systemd unit fails
loudly in journalctl and we'll know within minutes."""
from __future__ import annotations

from morgen_fetch import escape_text, render_event, to_utc_stamp


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
