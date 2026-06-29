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
#   A Stop hook fires once per completed top-level turn — not per tool call
#   (that is PostToolUse) and not per sub-agent (that is SubagentStop); this
#   hook is registered only on Stop.  Even so, back-to-back short turns, and
#   simultaneous turns from concurrent sessions on the same host+profile, can
#   cluster.  We cap to one summarizer spawn per 60 seconds so a cluster can't
#   hammer the platter-backed Synology with a write storm.  The 60s is purely
#   write-storm protection — unrelated to any API cache window (the reader,
#   get-claude-usage, separately caches the live API usage for 120s).
#
# WHY A LOCAL STAMP
#   The debounce is keyed on a small LOCAL stamp file, not the NFS summary.
#   Two reasons.  (1) The summary's mtime only advances after the detached
#   child finishes its multi-second JSONL crawl and atomic mv, so gating on it
#   would let every turn during that window pass the check and spawn another
#   concurrent crawl — the exact storm we are preventing.  A local stamp we
#   touch *before* spawning closes the window the instant we commit.  (2)
#   stat-ing the NFS file would put a synchronous GETATTR — and a possible
#   automount stall — on every turn's critical path; the local stamp is a
#   tmpfs/SSD read.
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
# DEBOUNCE + DETACHED SPAWN — at most one summarizer per 60s, per profile.
#
# Keyed on a small LOCAL stamp (see WHY A LOCAL STAMP above), not $OUT: we
# touch the stamp *before* spawning so a burst of turns during the child's
# multi-second crawl can't each slip past and pile concurrent crawls onto the
# platter NAS.  A missing stamp counts as stale, so the first run after boot
# or a manual cleanup always proceeds.
#
# The check-touch-spawn runs under flock on a sibling lockfile so two
# concurrent hooks (simultaneous sessions on the same host+profile) can't both
# pass the age check and double-spawn.  The lock is held only for the few
# syscalls here and released the instant the subshell exits — the setsid'd
# child is reparented and runs on past it; we never wait on it.  The 10-min
# timer in transcripts.nix is the fallback for any run the hook misses, and
# the summarizer's own atomic $OUT.tmp → mv keeps a concurrent timer run safe.
#
# Dependency assumptions, all safe on the NixOS hosts that import this hook
# (macOS never does): flock (util-linux), stat -c %Y (GNU coreutils).  </dev/null
# keeps the child off Claude's hook stdin pipe; >/dev/null 2>&1 keeps its output
# out of Claude's hook stream.
# ---------------------------------------------------------------------------
STAMP_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}"
STAMP="$STAMP_DIR/claude-usage-refresh.$profile.stamp"
mkdir -p "$STAMP_DIR" 2>/dev/null || true

(
  flock -n 9 || exit 0  # another invocation owns the window; nothing to do.

  if [[ -f "$STAMP" ]] && [[ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt 60 ]]; then
    exit 0  # a summarizer was spawned within the last 60s; debounced.
  fi

  # Claim the window before spawning so overlapping turns can't double-fire.
  touch "$STAMP"

  setsid claude-usage-summary --profile "$profile" --out "$OUT" \
    >/dev/null 2>&1 </dev/null &
) 9>"$STAMP.lock"

exit 0
