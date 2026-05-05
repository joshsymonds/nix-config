#!/usr/bin/env bash
# Reap orphan processes inside tmux pane cgroups, and kill stale sessions.
#
# Two passes:
#  PASS A — session staleness:
#    For each session on each tmux socket, check session_activity. If older
#    than TMUX_SESSION_STALE_SEC, kill-session. tmux closes its panes
#    normally; their cgroups drain via the L1 wrapper trap (or via PASS B).
#  PASS B — orphan reaping in cgroups:
#    1. ABANDONED scope: no live tmux pane_pid in cgroup.procs → systemctl stop the scope.
#    2. LIVE scope: a pane_pid is in cgroup.procs → find descendants from that PID;
#       anything in cgroup.procs but NOT in descendant tree, and etime >= grace, gets SIGKILL.
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
# Always use the system default tmux socket dir. Do NOT honor TMUX_TMPDIR —
# overriding it caused the reaper to see only a subset of sockets and
# misclassify real scopes as abandoned (incident 2026-05-04: lost mars:2.1 + mercury:2.1).
TMUX_SOCK_DIR="/run/user/${USER_ID}/tmux-${USER_ID}"

log() { printf '[reaper] %s\n' "$*"; }

# PASS A — kill tmux sessions whose session_activity is older than SESSION_STALE.
session_staleness_pass() {
  [[ -d "$TMUX_SOCK_DIR" ]] || return 0
  local now sock sockname name activity age
  now=$(date +%s)
  for sock in "$TMUX_SOCK_DIR"/*; do
    [[ -S "$sock" ]] || continue
    sockname=$(basename "$sock")
    while IFS=' ' read -r name activity; do
      [[ -z "$name" || -z "$activity" ]] && continue
      [[ "$activity" =~ ^[0-9]+$ ]] || continue
      age=$(( now - activity ))
      if (( age > SESSION_STALE )); then
        log "STALE-SESSION socket=$sockname name=$name age=${age}s → kill-session"
        if [[ "$DRY_RUN" != "1" ]]; then
          tmux -L "$sockname" kill-session -t "$name" 2>&1 || true
        fi
      fi
    done < <(tmux -L "$sockname" list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null || true)
  done
}

# Collect live tmux pane PIDs across all sockets the user has running.
# Outputs one PID per line.
collect_live_pane_pids() {
  [[ -d "$TMUX_SOCK_DIR" ]] || return 0
  local sock
  for sock in "$TMUX_SOCK_DIR"/*; do
    [[ -S "$sock" ]] || continue
    tmux -L "$(basename "$sock")" list-panes -aF '#{pane_pid}' 2>/dev/null || true
  done | sort -un
}

# Descendants of one or more root PIDs via pstree.
# Args: each PID is a separate positional arg.
# Outputs PIDs one per line (including roots).
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

  # Read scope PIDs into an array (one per line in cgroup.procs)
  local -a pids=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && pids+=("$p")
  done < "$procs_file"
  (( ${#pids[@]} == 0 )) && return 0

  # Find live pane_pids that are in this cgroup.
  local -a live_in_scope=()
  for p in "${pids[@]}"; do
    if printf '%s\n' "$LIVE_PANE_PIDS" | grep -qx "$p"; then
      live_in_scope+=("$p")
    fi
  done

  if (( ${#live_in_scope[@]} == 0 )); then
    # ABANDONED — stop the scope
    log "ABANDONED $scope_name procs=${#pids[@]} → stop"
    if [[ "$DRY_RUN" != "1" ]]; then
      systemctl --user stop --no-block "$scope_name" 2>&1 || true
    fi
    return 0
  fi

  # LIVE — compute descendants of every live pane_pid in scope.
  local live_tree
  live_tree="$(descendants_of "${live_in_scope[@]}")"

  # Orphans = pids in cgroup but not in live_tree, with etime >= grace.
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
      # SIGKILL orphans (best-effort; some may have already died).
      kill -KILL "${orphans[@]}" 2>/dev/null || true
    fi
  fi
}

# --- main ---

# PASS A: kill stale sessions first. tmux's normal pane teardown handles cleanup.
session_staleness_pass

# Re-collect live pane PIDs after possible session kills, so PASS B sees post-kill state.
LIVE_PANE_PIDS="$(collect_live_pane_pids)"
LIVE_COUNT=$(echo "$LIVE_PANE_PIDS" | grep -c . || true)
log "live tmux pane_pids: $LIVE_COUNT"

# Enumerate scopes once so we can sanity-check before destructive work.
shopt -s nullglob
SCOPES=(
  "$USER_CG"/tmux-spawn-*.scope
  "$USER_CG"/tmux.slice/tmux-pane.slice/tmux-pane-*.scope
)
SCOPE_COUNT=${#SCOPES[@]}

# Safety guard: if there are existing tmux scopes but the reaper sees ZERO live
# pane_pids, something is wrong (tmux server crashed mid-run, sock dir empty,
# discovery bug). Refuse to proceed — running PASS B would classify every scope
# as abandoned and stop them all. Better to no-op and let the next timer fire.
if (( SCOPE_COUNT > 0 && LIVE_COUNT == 0 )); then
  log "ABORT: $SCOPE_COUNT tmux scopes exist but 0 live pane_pids found — refusing to run PASS B"
  exit 0
fi

# PASS B: orphan reaping inside scopes.
for scope in "${SCOPES[@]}"; do
  process_scope "$scope"
done
