#!/usr/bin/env bash
# Reap orphan processes left behind by closed tmux panes/sessions, and kill
# tmux sessions that have been idle past TMUX_SESSION_STALE_SEC.
#
# Two passes:
#  PASS A — session staleness:
#    For each session on each discovered tmux server, check session_activity.
#    If older than TMUX_SESSION_STALE_SEC, kill-session.
#  PASS B — sid-based orphan reaping:
#    Walk every user process. A process is a tmux orphan when:
#      - it has TMUX= in its env (was spawned by some tmux server), AND
#      - its session id (from /proc/PID/stat) is not currently a tmux pane_pid
#        on any discovered tmux server, AND
#      - the session leader process at that sid is dead (no /proc/sid), AND
#      - its etime >= TMUX_REAPER_GRACE (avoid races with new processes).
#    SIGKILL it. The TMUX= env check confines killing to processes tmux
#    spawned, leaving e.g. unrelated daemons with dead session leaders alone.
#
# Why sid? When tmux opens a pane it setsid()s the shell, so every descendant
# has session id == pane_pid. When the pane closes, the shell exits but
# SIGTERM/SIGHUP-ignoring children survive, get reparented to PID 1, and keep
# their sid pointing at the (now-dead) pane_pid. That's the signal we use.
#
# Discovery: socket paths come from `ss -xlpH state listening` filtered to
# AF_UNIX listeners held by `tmux: server` processes — catches every server
# regardless of TMUX_TMPDIR (incident 2026-05-04: lost mercury).
#
# Env:
#   TMUX_REAPER_GRACE        Seconds a process must have lived before being killed (default 600).
#   TMUX_SESSION_STALE_SEC   Seconds since session_activity to consider stale (default 172800 = 48h).
#   TMUX_REAPER_DRY_RUN      If "1", log actions but don't kill anything.

set -euo pipefail

GRACE="${TMUX_REAPER_GRACE:-600}"
SESSION_STALE="${TMUX_SESSION_STALE_SEC:-172800}"
DRY_RUN="${TMUX_REAPER_DRY_RUN:-0}"
USER_ID="$(id -u)"

log() { printf '[reaper] %s\n' "$*"; }

# Discover all AF_UNIX socket paths held by `tmux: server` listeners.
# We rely on ss because TMUX_TMPDIR varies between systemd and shell envs;
# the kernel's listening-socket table is the only source of truth that catches
# every running tmux server regardless of who started it.
discover_tmux_sockets() {
  ss -xlpH state listening 2>/dev/null \
    | awk '
        /"tmux: server"/ {
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^\//) { print $i; next }
          }
        }
      ' | sort -u
}

# Read the session id (sid) field from /proc/PID/stat. The stat line is
# `pid (comm) state ppid pgrp sid tpgid ...`. comm can contain spaces and
# parens, so split on the LAST `) ` and take the 4th field of the remainder.
sid_of() {
  local pid="$1" line rest
  [[ -r "/proc/$pid/stat" ]] || return 1
  read -r line < "/proc/$pid/stat" || return 1
  rest="${line##*) }"
  # shellcheck disable=SC2086
  set -- $rest
  printf '%s\n' "$4"
}

# PASS A — kill tmux sessions whose session_activity is older than SESSION_STALE.
session_staleness_pass() {
  local now sock name activity age
  now=$(date +%s)
  while IFS= read -r sock; do
    [[ -z "$sock" || ! -S "$sock" ]] && continue
    while IFS=' ' read -r name activity; do
      [[ -z "$name" || -z "$activity" ]] && continue
      [[ "$activity" =~ ^[0-9]+$ ]] || continue
      age=$(( now - activity ))
      if (( age > SESSION_STALE )); then
        log "STALE-SESSION sock=$sock name=$name age=${age}s → kill-session"
        if [[ "$DRY_RUN" != "1" ]]; then
          tmux -S "$sock" kill-session -t "$name" 2>&1 || true
        fi
      fi
    done < <(tmux -S "$sock" list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null || true)
  done < <(discover_tmux_sockets)
}

# Collect live tmux pane PIDs across all discovered servers.
collect_live_pane_pids() {
  local sock
  while IFS= read -r sock; do
    [[ -z "$sock" || ! -S "$sock" ]] && continue
    tmux -S "$sock" list-panes -aF '#{pane_pid}' 2>/dev/null || true
  done < <(discover_tmux_sockets) | sort -un
}

# PASS B — sid-based orphan reaping.
sid_orphan_pass() {
  local pid sid etime
  local killed=0 inspected=0

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ ! -r "/proc/$pid/stat" ]] && continue
    [[ ! -r "/proc/$pid/environ" ]] && continue

    # Only tmux-spawned processes carry TMUX= in their env at exec time.
    # /proc/PID/environ uses NUL-separated entries; -z makes grep treat NULs
    # as line terminators so ^TMUX= matches at the start of *any* env entry
    # (not only the first one — without -z it only checks the file start).
    grep -azq '^TMUX=' "/proc/$pid/environ" 2>/dev/null || continue
    inspected=$((inspected + 1))

    sid="$(sid_of "$pid" 2>/dev/null || true)"
    [[ -z "$sid" || "$sid" == "0" || "$sid" == "1" ]] && continue

    # The session leader itself isn't an orphan candidate — it IS the session.
    [[ "$sid" == "$pid" ]] && continue

    # Still a member of a live tmux pane → not orphaned.
    if printf '%s\n' "$LIVE_PANE_PIDS" | grep -qx "$sid"; then continue; fi

    # Session leader still alive → process tree intact, leave it.
    [[ -d "/proc/$sid" ]] && continue

    # etime guard: skip very young processes to avoid races with newly-created
    # panes whose pane_pid hasn't yet appeared in `tmux list-panes`.
    etime="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [[ -z "$etime" || ! "$etime" =~ ^[0-9]+$ ]] && continue
    (( etime < GRACE )) && continue

    log "ORPHAN pid=$pid sid=$sid etime=${etime}s → SIGKILL"
    if [[ "$DRY_RUN" != "1" ]]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    killed=$((killed + 1))
  done < <(ps -o pid= -u "$USER_ID" 2>/dev/null | tr -d ' ')

  log "sid-pass: inspected $inspected tmux-tagged process(es); killed $killed orphan(s)"
}

# --- main ---

# PASS A: kill stale sessions first. tmux's normal pane teardown reaps the
# pane shells; PASS B picks up any descendants that survived SIGHUP.
session_staleness_pass

LIVE_PANE_PIDS="$(collect_live_pane_pids)"
LIVE_COUNT=$(printf '%s' "$LIVE_PANE_PIDS" | grep -c . || true)
SOCKET_COUNT=$(discover_tmux_sockets | grep -c . || true)
log "discovered $SOCKET_COUNT tmux server socket(s); $LIVE_COUNT live pane_pid(s)"

# PASS B: sid-based orphan reaping.
sid_orphan_pass
