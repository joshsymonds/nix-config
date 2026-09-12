# Behavioural check for the SessionStart hook that surfaces the gambit record
# directory belonging to the repository and branch a session starts in.
#
# The hook's whole job is a lookup: map (repository, branch) onto at most one
# `<GAMBIT_HOME>/<repository-id>/<epic-slug>/` directory and print it as
# SessionStart context, or print nothing. This check builds a throwaway git
# repository and a throwaway record home so both halves of that lookup — the
# hit and the silence — are asserted against the real script, not a mock.
{pkgs}: let
  script = ../home-manager/claude-code/hooks/gambit-record-context.sh;

  # The settings file the hook is registered in. Asserted here so the script
  # cannot keep passing while nothing wires it to the compact/resume sources.
  settingsJson = ../home-manager/claude-code/settings.json;
in
  pkgs.runCommand "claude-session-start-hook-check" {
    nativeBuildInputs = [pkgs.git pkgs.jq];
  } ''
    set -euo pipefail

    fail() {
      echo "claude-session-start-hook: $1" >&2
      exit 1
    }

    # A private HOME so an unset GAMBIT_HOME could never reach a real record
    # directory, and a git identity so `git commit` works in the sandbox.
    export HOME="$PWD/fakehome"
    export GAMBIT_HOME="$PWD/records"
    export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@example.invalid
    export GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@example.invalid
    mkdir -p "$HOME" "$GAMBIT_HOME"

    repo="$PWD/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    : > "$repo/file"
    git -C "$repo" add file
    git -C "$repo" commit -qm root

    # repository-id is the basename of the parent of the common git dir plus
    # the first seven characters of the root commit. The parent of
    # "$repo/.git" is "$repo", so the basename here is literally "repo".
    root7=$(git -C "$repo" rev-list --max-parents=0 HEAD | tail -1 | cut -c1-7)
    id="repo-$root7"

    alpha="$GAMBIT_HOME/$id/alpha"
    beta="$GAMBIT_HOME/$id/beta"
    mkdir -p "$alpha" "$beta"
    jq -n '{epic_branch: "main"}' > "$alpha/state.json"
    jq -n '{epic_branch: "epic/two"}' > "$beta/state.json"

    # A decoy under a different repository-id, on a branch name the fixture
    # repository really is on. Only the repository half of the lookup can
    # reject it, so a hook matching on branch alone would fail here.
    decoy="$GAMBIT_HOME/other-0000000/alpha"
    mkdir -p "$decoy"
    jq -n '{epic_branch: "main"}' > "$decoy/state.json"

    # Guard against a vacuous pass: the fixture must really hold three records.
    records=$(find "$GAMBIT_HOME" -name state.json | wc -l)
    test "$records" -eq 3 || fail "fixture holds $records records, expected 3"

    run_hook() {
      printf '{"cwd":"%s","source":"compact"}' "$1" | bash ${script}
    }

    # $1 cwd, $2 the record directory that must be named, $3 one that must not.
    assert_names() {
      local out rc count
      out=$(run_hook "$1") && rc=0 || rc=$?
      test "$rc" -eq 0 || fail "hook exited $rc in $1"
      # Exactly one object: "the matching directory only".
      count=$(printf '%s' "$out" | jq -s 'length')
      test "$count" -eq 1 \
        || fail "expected 1 context object in $1, got $count: ''${out:-<empty>}"
      printf '%s' "$out" | jq -e '
        .hookSpecificOutput.hookEventName == "SessionStart"
      ' >/dev/null || fail "wrong hookEventName in $1: $out"
      printf '%s' "$out" | jq -e --arg want "$2" '
        .hookSpecificOutput.additionalContext | contains($want)
      ' >/dev/null || fail "context in $1 does not name $2: $out"
      printf '%s' "$out" | jq -e --arg bad "$3" '
        .hookSpecificOutput.additionalContext | contains($bad) | not
      ' >/dev/null || fail "context in $1 wrongly names $3: $out"
    }

    assert_silent() {
      local out rc
      out=$(run_hook "$1") && rc=0 || rc=$?
      test "$rc" -eq 0 || fail "hook exited $rc in $1"
      test -z "$out" || fail "expected no output in $1, got: $out"
    }

    # On each recorded branch the hook names that branch's directory and no
    # other — including the decoy from the other repository.
    assert_names "$repo" "$alpha" "$beta"
    assert_names "$repo" "$alpha" "$decoy"

    git -C "$repo" switch -q -c epic/two
    assert_names "$repo" "$beta" "$alpha"

    # A branch with no record, and a directory that is not a git repository at
    # all: both print nothing and exit 0, so a session there is unaffected.
    git -C "$repo" switch -q -c no-record
    assert_silent "$repo"

    mkdir -p "$PWD/plain"
    assert_silent "$PWD/plain"

    # The hook is registered for the two sources that start a session with the
    # prior context already lost: compaction and resume.
    jq -e '
      [ .hooks.SessionStart[]
        | select(.matcher == "compact|resume")
        | .hooks[]
        | select(.type == "command"
                 and .command == "~/.claude/hooks/gambit-record-context.sh")
      ] | length == 1
    ' ${settingsJson} >/dev/null \
      || fail "settings.json does not register the hook for compact|resume"

    touch "$out"
  ''
