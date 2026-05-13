"""Poll Morgen's REST API for upcoming events and drop them as ICS files
into a vdir directory that khal (and DMS's calendar bar widget) reads.

Auth is a static API key dispensed at https://platform.morgen.so/developers-api
— Morgen already brokered the Google + Microsoft OAuth flows, so we don't.

Single module, stdlib only. Designed to be idempotent: every run produces
the same set of files for the same set of events; stale files (events that
ended or were deleted upstream) get pruned at the end of each run."""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import NoReturn
from zoneinfo import ZoneInfo

API_BASE = "https://api.morgen.so/v3"
DEFAULT_KEY_PATH = Path("~/.config/morgen-fetch/api-key").expanduser()
DEFAULT_VDIR = Path("~/.local/share/vdirs/morgen/primary").expanduser()
DEFAULT_JSON_PATH = Path("~/.local/share/morgen-fetch/upcoming-events.json").expanduser()
DEFAULT_LOOKAHEAD = dt.timedelta(days=7)

# ISO 8601 duration parser, restricted to the subset JSCalendar uses in
# practice: PT<H>H<M>M<S>S. Multi-day events come back from Morgen with
# an explicit end (or via showWithoutTime), not as P1D, so we don't need
# to handle the calendar-date duration form.
_DURATION_RE = re.compile(r"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$")


def die(msg: str, code: int = 1) -> NoReturn:
    print(f"morgen-fetch: {msg}", file=sys.stderr)
    sys.exit(code)


def escape_text(s: str) -> str:
    """Escape a string for use in an ICS TEXT field (RFC 5545 §3.3.11).

    Order matters: backslash MUST be escaped first, otherwise we'd
    double-escape the backslashes we just inserted for ;/,/newline."""
    return (
        s.replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(",", "\\,")
        .replace("\n", "\\n")
    )


def to_utc_stamp(local_str: str, tz_name: str) -> str:
    """Convert a JSCalendar local datetime + IANA timeZone to an ICS UTC
    stamp (`YYYYMMDDTHHMMSSZ`). Rendering everything as UTC `Z` form
    sidesteps having to emit VTIMEZONE blocks for every event — khal
    handles VTIMEZONE fine, but the bar widget's parsing of khal output
    has historically been happier with absolute times."""
    naive = dt.datetime.fromisoformat(local_str)
    aware = naive.replace(tzinfo=ZoneInfo(tz_name or "UTC"))
    return aware.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _to_iso_utc(local_str: str, tz_name: str) -> str:
    """Same arithmetic as `to_utc_stamp` but emits ISO 8601 with colons
    (`2024-01-15T10:00:00Z`) — the form upcoming-events.json consumers
    expect (Quickshell's QML date parsers, Python's
    datetime.fromisoformat, jq, etc.)."""
    naive = dt.datetime.fromisoformat(local_str)
    aware = naive.replace(tzinfo=ZoneInfo(tz_name or "UTC"))
    return aware.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso8601_duration(d: str) -> dt.timedelta:
    """Parse an ISO 8601 duration string into a `timedelta`. Restricted
    to the PT-prefixed time-only form JSCalendar emits in practice;
    unparseable input (including the empty string and `None`) falls back
    to 1 hour, mirroring `render_event`'s existing duration behavior so
    the JSON output and the ICS files agree on end times."""
    if not d:
        return dt.timedelta(hours=1)
    m = _DURATION_RE.match(d)
    if not m or not any(m.groups()):
        return dt.timedelta(hours=1)
    hours = int(m.group(1) or 0)
    minutes = int(m.group(2) or 0)
    seconds = int(m.group(3) or 0)
    return dt.timedelta(hours=hours, minutes=minutes, seconds=seconds)


def extract_event_json(ev: dict, now: dt.datetime) -> dict | None:
    """Project a Morgen JSCalendar event to the schema upcoming-events.json
    emits: `{uid, title, start, end, url}` with all times in ISO 8601 UTC.

    Returns `None` for:
      - events without a stable identifier (`uid` or `id`)
      - events whose start is in the past (≤ `now`)
      - events whose `start` field is missing or unparseable

    `url` is pulled from `morgen.so:derived.virtualRoom.url` and coerced
    to `None` when absent OR empty string, so downstream consumers can
    treat null-vs-non-null as the only branching condition without also
    checking for empty strings."""
    uid = ev.get("uid") or ev.get("id")
    if not uid:
        return None
    start_local = ev.get("start")
    if not start_local:
        return None
    tz = ev.get("timeZone") or "UTC"
    try:
        start_iso = _to_iso_utc(start_local, tz)
    except (ValueError, KeyError):
        return None
    start_dt = dt.datetime.fromisoformat(start_iso.replace("Z", "+00:00"))
    if start_dt <= now:
        return None
    duration = _parse_iso8601_duration(ev.get("duration") or "")
    end_iso = (start_dt + duration).strftime("%Y-%m-%dT%H:%M:%SZ")
    derived = ev.get("morgen.so:derived") or {}
    vroom = derived.get("virtualRoom") or {}
    raw_url = vroom.get("url")
    url = raw_url if raw_url else None  # empty string → None
    return {
        "uid": uid,
        "title": ev.get("title") or "(no title)",
        "start": start_iso,
        "end": end_iso,
        "url": url,
    }


def render_upcoming_events_json(events: list, now: dt.datetime) -> list:
    """Filter to future events, project each via `extract_event_json`,
    sort by start ascending. Events that `extract_event_json` rejects
    (no id, in the past, malformed) are silently skipped — better to
    emit a smaller correct list than to fail the whole write."""
    out = []
    for ev in events:
        rendered = extract_event_json(ev, now)
        if rendered is not None:
            out.append(rendered)
    out.sort(key=lambda e: e["start"])
    return out


def render_event(ev: dict, dtstamp: str) -> tuple[str, str] | None:
    """Render a single Morgen JSCalendar event as (filename, ics_text).

    Returns None if the event has no usable identifier — without a stable
    UID we can't dedupe across runs, so dropping the event is safer than
    making one up. The filename has non-alnum characters scrubbed (some
    Morgen UIDs contain slashes or colons that aren't valid in POSIX
    filenames), but the on-wire ICS UID line preserves the original so
    khal/calendars match it correctly across runs."""
    uid = ev.get("uid") or ev.get("id")
    if not uid:
        return None
    title = escape_text(ev.get("title") or "(no title)")
    tz = ev.get("timeZone") or "UTC"
    duration = ev.get("duration") or "PT1H"
    if ev.get("showWithoutTime"):
        date_part = ev["start"].split("T")[0].replace("-", "")
        dtstart_line = f"DTSTART;VALUE=DATE:{date_part}"
    else:
        dtstart_line = f"DTSTART:{to_utc_stamp(ev['start'], tz)}"
    safe_uid = re.sub(r"[^A-Za-z0-9._@-]", "_", uid)
    fname = f"{safe_uid}.ics"
    ics = (
        "BEGIN:VCALENDAR\r\n"
        "VERSION:2.0\r\n"
        "PRODID:-//morgen-bar//EN\r\n"
        "BEGIN:VEVENT\r\n"
        f"UID:{uid}@morgen\r\n"
        f"SUMMARY:{title}\r\n"
        f"{dtstart_line}\r\n"
        f"DURATION:{duration}\r\n"
        f"DTSTAMP:{dtstamp}\r\n"
        "END:VEVENT\r\n"
        "END:VCALENDAR\r\n"
    )
    return (fname, ics)


def api(path: str, key: str, **params: str) -> dict:
    qs = urllib.parse.urlencode(params)
    url = f"{API_BASE}{path}" + (f"?{qs}" if qs else "")
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"ApiKey {key}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        body = e.read()[:300].decode("utf-8", "replace")
        die(f"HTTP {e.code} {e.reason} from {path}: {body}")
    except urllib.error.URLError as e:
        die(f"network error talking to {path}: {e.reason}")


def main(
    key_path: Path = DEFAULT_KEY_PATH,
    vdir: Path = DEFAULT_VDIR,
    lookahead: dt.timedelta = DEFAULT_LOOKAHEAD,
) -> int:
    if not key_path.is_file():
        die(
            f"missing API key at {key_path}\n"
            "  get one at https://platform.morgen.so/developers-api"
        )
    key = key_path.read_text().strip()
    if not key:
        die(f"{key_path} is empty")

    cals = api("/calendars/list", key)
    groups: dict[str, list[str]] = {}
    for c in cals.get("data", {}).get("calendars", []):
        groups.setdefault(c["accountId"], []).append(c["id"])
    if not groups:
        die("Morgen returned no calendars — connect an account in the app first")

    now = dt.datetime.now(dt.timezone.utc)
    start_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    end_iso = (now + lookahead).strftime("%Y-%m-%dT%H:%M:%SZ")
    events: list[dict] = []
    for account_id, cal_ids in groups.items():
        resp = api(
            "/events/list",
            key,
            accountId=account_id,
            calendarIds=",".join(cal_ids),
            start=start_iso,
            end=end_iso,
        )
        events.extend(resp.get("data", {}).get("events", []))

    vdir.mkdir(parents=True, exist_ok=True)
    dtstamp = now.strftime("%Y%m%dT%H%M%SZ")
    keep: set[str] = set()
    for ev in events:
        rendered = render_event(ev, dtstamp)
        if rendered is None:
            continue
        fname, ics = rendered
        keep.add(fname)
        (vdir / fname).write_text(ics)

    # Prune files whose events ended / were deleted upstream. Pruning
    # AFTER writes (not before) keeps the vdir continuously valid — khal
    # reading mid-sync sees either the old snapshot or the new one, never
    # an empty directory.
    for f in vdir.glob("*.ics"):
        if f.name not in keep:
            f.unlink()

    # Sibling JSON output: upcoming-events.json. Consumed by the meeting
    # pill (for title/countdown/URL display) and the morgen-notifier (for
    # T-10/T-2 alerts). Written AFTER the ICS pipeline so a failure here
    # doesn't compromise khal's data; the .tmp + rename pattern makes
    # the swap atomic on POSIX same-filesystem renames so consumers
    # using FileView with watchChanges never observe a partial write.
    upcoming = render_upcoming_events_json(events, now)
    DEFAULT_JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = DEFAULT_JSON_PATH.with_suffix(".json.tmp")
    tmp_path.write_text(json.dumps(upcoming, indent=2))
    tmp_path.rename(DEFAULT_JSON_PATH)

    print(
        f"morgen-fetch: wrote {len(keep)} ICS events, "
        f"{len(upcoming)} JSON upcoming",
        file=sys.stderr,
    )
    return 0


def main_cli() -> None:
    """Console-script entry point (see pyproject.toml [project.scripts]).

    Honors $MORGEN_FETCH_KEY_FILE so the systemd unit can point us at an
    agenix-decrypted file under /run/user/$UID/agenix/ instead of a
    plaintext file in $HOME. Falls back to ~/.config/morgen-fetch/api-key
    for local/dev runs.

    Home-manager agenix produces .path values containing literal
    `${XDG_RUNTIME_DIR}` placeholders so the same Nix-evaluated string
    works across different UIDs; systemd's `Environment=` doesn't expand
    those, so we run expandvars + expanduser ourselves here. A bare path
    or an already-expanded path roundtrips through both calls unchanged."""
    raw = os.environ.get("MORGEN_FETCH_KEY_FILE") or "~/.config/morgen-fetch/api-key"
    key_path = Path(os.path.expandvars(raw)).expanduser()
    sys.exit(main(key_path=key_path))


if __name__ == "__main__":
    main_cli()
