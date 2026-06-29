#!/usr/bin/env bash
# usage-summary-refresh.sh — Stop hook: debounced, detached summary refresh.
#
# PURPOSE
#   Every Claude turn that runs to completion triggers this hook via the
#   Stop event.  The normal summary pipeline runs on a 10-minute systemd
#   timer (claude-code/transcripts.nix), which means the DMS bar widget
#   on gnomon can show data up to 10 minutes stale.  This hook fires the
#   same `claude-usage-summary` binary immediately after each turn so the
#   widget picks up the new transcript in seconds rather than minutes.
#
# WHY DETACHED
#   Claude Code waits for Stop hooks to exit before returning control to
#   the user.  Running the summarizer synchronously would add its entire
#   wall-clock time to every turn's latency — potentially several seconds
#   of JSONL parsing on a platter-backed NFS share.  We setsid+background
#   the child so this hook returns immediately; the summary races the next
#   prompt interaction to finish first, which it always does.
#
# WHY DEBOUNCED
#   Rapid-fire turns (tool loops, agent sub-turns) generate many Stop
#   events in quick succession.  The summarizer is idempotent and the
#   result is the same modulo a few seconds of new data, so there is no
#   point running it more than once per minute.  The 60-second window is
#   a deliberately chosen floor that caps how often we write to the
#   platter-backed Synology NFS share — without it, a bursty tool loop
#   would hammer the slow spinning disks with a write storm.  It is not
#   tied to any API cache window (the summarizer's own usage cache in
#   get-claude-usage is 120s); 60s is purely write-storm protection.
#
# WHY THE GUARD
#   This hook is deployed to ALL profiles on ALL in-scope hosts (gnomon,
#   ultraviolet, vermissian) because settings.json is shared.  Only the
#   hosts that import claude-code/transcripts.nix ship the
#   `claude-usage-summary` binary.  On hosts or profiles without it the
#   hook must be a silent no-op — not an error, not output to stdout
#   (Claude parses hook stdout for control messages), not a delay.
#
# WHY CLAUDE_SUMMARIES_DIR
#   The NFS bucket path (/mnt/claude) is controlled by the NFS automount
#   config and must match the path baked into the systemd timer runner in
#   transcripts.nix.  CLAUDE_SUMMARIES_DIR is the same override used by
#   get-claude-usage (the aggregator side in aggregator.nix) so a single
#   env var can redirect all summary I/O during testing without touching
#   any Nix config.
#
# STDOUT DISCIPLINE
#   Claude Code reads hook stdout and interprets non-empty output as a
#   control message.  This script never prints to stdout — all diagnostic
#   noise goes to >&2, and the detached child's stdout is also discarded.

set -eu

# ---------------------------------------------------------------------------
# GUARD — silent no-op on hosts/profiles without the summarizer binary.
#
# The hook deploys to every Claude profile (personal AND work) on every
# in-scope host via the shared home.file block in default.nix.  Only
# hosts that import transcripts.nix have claude-usage-summary on PATH.
# An exit-0 here is the correct contract: the hook succeeded (nothing to
# do), and Claude should proceed without treating this as a failure.
# ---------------------------------------------------------------------------
command -v claude-usage-summary >/dev/null 2>&1 || exit 0

# ---------------------------------------------------------------------------
# BUCKET — where this host writes its per-profile summary files.
#
# CLAUDE_SUMMARIES_DIR overrides /mnt/claude for offline testing without
# touching production NFS.  The host segment is the raw hostname from
# uname, matching the directory layout created by the NFS automount and
# consumed by gnomon's get-claude-usage aggregator.
# ---------------------------------------------------------------------------
SUMMARIES_DIR="${CLAUDE_SUMMARIES_DIR:-/mnt/claude}"
host="$(uname -n)"
BUCKET="$SUMMARIES_DIR/$host"

# ---------------------------------------------------------------------------
# PROFILE DETECTION — personal vs work, definitively.
#
# Claude Code sets CLAUDE_CONFIG_DIR to the active profile's config
# directory before invoking hooks.  Personal sessions use the default
# (~/.claude), so CLAUDE_CONFIG_DIR is either unset or points elsewhere.
# Work sessions set CLAUDE_CONFIG_DIR=$HOME/.claude-work (see the
# __cc_work function in home-manager/zsh/default.nix).  Checking for the
# substring "claude-work" is the canonical test — it is immune to HOME
# being set differently across hosts, and it matches any future variant
# of the work-profile path without additional configuration.
# ---------------------------------------------------------------------------
profile="personal"
if [[ "${CLAUDE_CONFIG_DIR:-}" == *claude-work* ]]; then
  profile="work"
fi

OUT="$BUCKET/$profile/summary.json"

# ---------------------------------------------------------------------------
# DEBOUNCE — at most one refresh per 60 seconds.
#
# A rapid tool loop can generate a burst of Stop events.  Re-running the
# summarizer on every one would write to the NFS share many times per
# minute for negligible gain.  60s is a chosen write-frequency floor —
# not a mirror of any API cache window — that spares NAS I/O and avoids a
# pile-up of background processes on the Synology platter drives.
#
# A missing OUT file counts as stale: first run on a new host or profile,
# or after a manual cleanup, should always proceed.
#
# stat -c %Y is GNU coreutils (standard on NixOS); this hook is not
# intended to run on macOS (ninuan does not import transcripts.nix).
# ---------------------------------------------------------------------------
if [[ -f "$OUT" ]]; then
  NOW="$(date +%s)"
  MTIME="$(stat -c %Y "$OUT")"
  AGE=$(( NOW - MTIME ))
  if [[ $AGE -lt 60 ]]; then
    exit 0  # File is fresh enough; nothing to do.
  fi
fi

# ---------------------------------------------------------------------------
# DETACHED RUN — fire and forget.
#
# setsid detaches the child from this hook's process session so it is not
# killed when Claude tears down the hook's process group.  Stdin is
# redirected from /dev/null so the child does not inherit the hook's
# stdin pipe (which Claude holds open and may close at any time).  Stdout
# and stderr are discarded — this is a background writer, not a UI tool,
# and any diagnostic output must not leak into Claude's hook stream.
#
# We do NOT wait on the child.  The exit 0 returns control to Claude
# before the summarizer has done any work.  The 10-minute timer in
# transcripts.nix is the fallback for any run the hook misses (host
# unreachable at NFS mount time, binary crash, etc.).  The summarizer
# already writes atomically ($OUT.tmp → mv), so a concurrent timer run
# is safe — no additional locking is needed here.
# ---------------------------------------------------------------------------
setsid claude-usage-summary --profile "$profile" --out "$OUT" \
  >/dev/null 2>&1 </dev/null &

exit 0
