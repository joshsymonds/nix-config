#!/usr/bin/env bash
# Reap orphan processes inside tmux pane cgroups, and kill stale sessions.
#
# Two passes:
#  PASS A — session staleness:
#    For each session on each discovered tmux server, check session_activity.
#    If older than TMUX_SESSION_STALE_SEC, kill-session. tmux closes its panes
#    normally; their cgroups drain via the L1 wrapper trap (or via PASS B).
#  PASS B — orphan reaping in cgroups:
#    1. ABANDONED scope: no live tmux pane_pid in cgroup.procs → systemctl stop.
#    2. LIVE scope: a pane_pid is in cgroup.procs → find descendants from that
#       PID; anything in cgroup.procs but NOT in descendant tree, and etime
#       >= grace, gets SIGKILL.
#
# Discovery: socket paths come from `ss -xlpH state listening` filtered to
# AF_UNIX listeners held by `tmux: server` processes. This catches every server
# the user has running regardless of TMUX_TMPDIR or cwd quirks. The previous
# hardcoded TMUX_SOCK_DIR=/run/user/UID/tmux-UID missed the systemd-launched
# server when its env lacked TMUX_TMPDIR (incident 2026-05-04: lost mercury).
#
# Safety guard: before any destructive Pass B work, walk every tmux-pane-*.scope
# and verify that any pid whose parent's comm is `tmux: server` is present in the
# discovered LIVE_PANE_PIDS union. If not, our socket discovery missed a server
# — abort. This is the structural defense against future asymmetric-discovery
# regressions.
#
# Env:
#   TMUX_REAPER_GRACE        Seconds a process must have lived before being killed (default 600).
#   TMUX_SESSION_STALE_SEC   Seconds since session_activity to consider stale (default 172800 = 48h).
#   TMUX_REAPER_DRY_RUN      If "1", log actions but don't kill or stop anything.

set -euo pipefail

GRACE="${TMUX_REAPER_GRACE:-600}"
SESSION_STALE="${TMUX_SESSION_STALE_SEC:-172800}"
DRY_RUN="${TMUX_REAPER_DRY_RUN:-0}"
USER_ID="$(id -u)"
USER_CG="/sys/fs/cgroup/user.slice/user-${USER_ID}.slice/user@${USER_ID}.service"

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

# PPID of a pid via /proc/PID/stat. Handles parens/spaces in comm field by
# splitting on the LAST ") " — everything after is the post-comm portion whose
# first field is state and second is PPID.
ppid_of() {
  local pid="$1" line rest
  [[ -r "/proc/$pid/stat" ]] || return 1
  read -r line < "/proc/$pid/stat" || return 1
  rest="${line##*) }"
  # shellcheck disable=SC2086
  set -- $rest
  printf '%s\n' "$2"
}

# comm of a pid via /proc/PID/comm.
comm_of() {
  local pid="$1" c
  [[ -r "/proc/$pid/comm" ]] || return 1
  read -r c < "/proc/$pid/comm" || return 1
  printf '%s\n' "$c"
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

# Collect live tmux pane PIDs across ALL discovered tmux servers.
collect_live_pane_pids() {
  local sock
  while IFS= read -r sock; do
    [[ -z "$sock" || ! -S "$sock" ]] && continue
    tmux -S "$sock" list-panes -aF '#{pane_pid}' 2>/dev/null || true
  done < <(discover_tmux_sockets) | sort -un
}

# Descendants of one or more root PIDs via pstree. Outputs PIDs one per line
# (including roots).
descendants_of() {
  local r
  for r in "$@"; do
    pstree -p "$r" 2>/dev/null | grep -oE '\([0-9]+\)' | tr -d '()' || true
  done | sort -un
}

# Process one scope cgroup. Path is $1.
process_scope() {
  local scope_path="$1"
  local scope_name
  scope_name="$(basename "$scope_path")"

  local procs_file="$scope_path/cgroup.procs"
  [[ -e "$procs_file" ]] || return 0

  local -a pids=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && pids+=("$p")
  done < "$procs_file"
  (( ${#pids[@]} == 0 )) && return 0

  local -a live_in_scope=()
  for p in "${pids[@]}"; do
    if printf '%s\n' "$LIVE_PANE_PIDS" | grep -qx "$p"; then
      live_in_scope+=("$p")
    fi
  done

  if (( ${#live_in_scope[@]} == 0 )); then
    log "ABANDONED $scope_name procs=${#pids[@]} → stop"
    if [[ "$DRY_RUN" != "1" ]]; then
      systemctl --user stop --no-block "$scope_name" 2>&1 || true
    fi
    return 0
  fi

  local live_tree
  live_tree="$(descendants_of "${live_in_scope[@]}")"

  local -a orphans=()
  local esecs
  for p in "${pids[@]}"; do
    if ! printf '%s\n' "$live_tree" | grep -qx "$p"; then
      esecs="$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ' || true)"
      if [[ -n "$esecs" && "$esecs" =~ ^[0-9]+$ && "$esecs" -ge "$GRACE" ]]; then
        orphans+=("$p")
      fi
    fi
  done

  if (( ${#orphans[@]} > 0 )); then
    log "LIVE-WITH-ORPHANS $scope_name live=${live_in_scope[*]} orphans=${#orphans[@]}"
    if [[ "$DRY_RUN" != "1" ]]; then
      kill -KILL "${orphans[@]}" 2>/dev/null || true
    fi
  fi
}

# --- main ---

# PASS A: kill stale sessions first. tmux's normal pane teardown handles cleanup.
session_staleness_pass

# Re-collect live pane PIDs after possible session kills, so PASS B sees post-kill state.
LIVE_PANE_PIDS="$(collect_live_pane_pids)"
LIVE_COUNT=$(printf '%s' "$LIVE_PANE_PIDS" | grep -c . || true)
SOCKET_COUNT=$(discover_tmux_sockets | grep -c . || true)
log "discovered $SOCKET_COUNT tmux server socket(s); $LIVE_COUNT live pane_pid(s)"

# Enumerate scopes once.
shopt -s nullglob
SCOPES=(
  "$USER_CG"/tmux-spawn-*.scope
  "$USER_CG"/tmux.slice/tmux-pane.slice/tmux-pane-*.scope
)
SCOPE_COUNT=${#SCOPES[@]}

# Discovery-completeness guard.
# For every scope, walk cgroup.procs. If we find a pid whose PARENT is a live
# `tmux: server` process but the pid itself isn't in our discovered pane_pids
# union, our socket discovery missed at least one server. Refuse to do anything
# destructive — running PASS B with an incomplete view is exactly what killed
# mercury on 2026-05-04.
for scope in "${SCOPES[@]}"; do
  procs_file="$scope/cgroup.procs"
  [[ -e "$procs_file" ]] || continue
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    ppid="$(ppid_of "$p" 2>/dev/null || true)"
    [[ -z "$ppid" || "$ppid" == "0" || "$ppid" == "1" ]] && continue
    pcomm="$(comm_of "$ppid" 2>/dev/null || true)"
    [[ "$pcomm" == "tmux: server" ]] || continue
    if ! printf '%s\n' "$LIVE_PANE_PIDS" | grep -qx "$p"; then
      log "ABORT: scope $(basename "$scope") proc $p is anchored to tmux: server (ppid=$ppid) but $p is not in discovered pane_pids — socket discovery incomplete"
      exit 0
    fi
  done < "$procs_file"
done

# Belt-and-suspenders: never run destructive Pass B with zero discovered pane_pids while scopes exist.
if (( SCOPE_COUNT > 0 && LIVE_COUNT == 0 )); then
  log "ABORT: $SCOPE_COUNT tmux scopes exist but 0 live pane_pids found"
  exit 0
fi

# PASS B: orphan reaping inside scopes.
for scope in "${SCOPES[@]}"; do
  process_scope "$scope"
done
