#!/usr/bin/env bash
# gambit-record-context.sh — SessionStart hook: name this epic's durable record.
#
# WHY
#   A gambit epic keeps its record outside the repository, under
#   ~/.gambit/<repository-id>/<epic-slug>/.  A session that starts from a
#   compaction or a resume has lost whatever pointed at that directory, so the
#   orchestrator would have to rediscover it — or, worse, carry on without it.
#   This hook re-states the path as SessionStart context.  It is registered in
#   settings.json for the `compact|resume` sources only: a fresh `startup`
#   session has no prior context to recover.
#
# THE LOOKUP
#   repository-id is the basename of the parent of the COMMON git dir plus the
#   first seven characters of the root commit.  Using the common dir rather
#   than the per-worktree git dir is what makes every linked worktree of a
#   repository — the epic workspace and each worker's — resolve to the same
#   record.  The branch is then matched against the `epic_branch` field of each
#   candidate record's state.json, so only the epic being worked on is named.
#
# STDOUT DISCIPLINE
#   Claude Code injects SessionStart stdout into the session as context, so
#   this script prints one compact JSON object per matching record and nothing
#   at all otherwise.  It exits 0 on every path: a session start must not fail
#   because a record is missing, the directory is not a git repository, or the
#   payload is not what we expected.

set -euo pipefail

# Every extraction below falls through to a silent exit 0 rather than failing
# the session start.  This also covers jq being absent from PATH entirely.
payload=$(cat) || exit 0
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# --path-format=absolute matters: the bare flag returns a relative ".git" when
# run at a repository toplevel, and the parent of that is "." — the wrong
# basename, and one that would differ from the same repository's worktrees.
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
root_commit=$(git rev-list --max-parents=0 HEAD 2>/dev/null | tail -1) || exit 0
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
[ -n "$common_dir" ] && [ -n "$root_commit" ] && [ -n "$branch" ] || exit 0

repository_id="$(basename "$(dirname "$common_dir")")-${root_commit:0:7}"
record_home="${GAMBIT_HOME:-${HOME:-}/.gambit}"

for state in "$record_home/$repository_id"/*/state.json; do
  # An unmatched glob stays literal, so this also covers "no records at all".
  [ -f "$state" ] || continue
  epic_branch=$(jq -r '.epic_branch // empty' "$state" 2>/dev/null) || continue
  [ "$epic_branch" = "$branch" ] || continue
  jq -nc --arg dir "$(dirname "$state")" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("Gambit record for this epic: " + $dir
        + ". Read state.json before continuing.")
    }
  }'
done

exit 0
