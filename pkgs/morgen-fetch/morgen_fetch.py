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
DEFAULT_LOOKAHEAD = dt.timedelta(days=7)


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

    print(f"morgen-fetch: wrote {len(keep)} events", file=sys.stderr)
    return 0


def main_cli() -> None:
    """Console-script entry point (see pyproject.toml [project.scripts]).

    Honors $MORGEN_FETCH_KEY_FILE so the systemd unit can point us at an
    agenix-decrypted file under /run/user/$UID/agenix/ instead of a
    plaintext file in $HOME. Falls back to ~/.config/morgen-fetch/api-key
    for local/dev runs."""
    key_path = Path(
        os.environ.get("MORGEN_FETCH_KEY_FILE")
        or "~/.config/morgen-fetch/api-key"
    ).expanduser()
    sys.exit(main(key_path=key_path))


if __name__ == "__main__":
    main_cli()
