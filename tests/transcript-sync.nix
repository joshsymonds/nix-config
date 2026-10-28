# Behavioural check for transcript-sync. The binary is the one the Home Manager
# module builds, run against scratch trees under the build directory: a private
# HOME, bucket and state per case. Nothing here reads or writes /mnt/claude.
{pkgs}: let
  module = import ../home-manager/claude-code/transcript-sync.nix {inherit pkgs;};
  transcriptSync = builtins.head module.home.packages;
  timerJson = pkgs.writeText "transcript-sync-timer.json" (builtins.toJSON module.systemd.user.timers.transcript-sync.Timer);
in
  pkgs.runCommand "transcript-sync-check" {
    nativeBuildInputs = with pkgs; [coreutils diffutils findutils gawk gnugrep jq];
  } ''
    set -euo pipefail

    CASE=setup
    fail() {
      echo "transcript-sync check [$CASE]: $1" >&2
      exit 1
    }

    bin=${transcriptSync}/bin/transcript-sync

    # Each case gets its own HOME, bucket and state.
    setup() {
      export HOME="$PWD/$1/home"
      export TRANSCRIPT_SYNC_BUCKET="$PWD/$1/nas"
      export TRANSCRIPT_SYNC_STATE="$PWD/$1/state"
      mkdir -p "$HOME" "$TRANSCRIPT_SYNC_BUCKET"
    }

    # sync_run: one run that must exit 0. Its stderr is kept in stderr.txt.
    sync_run() {
      if ! "$bin" sync 2>"$PWD/stderr.txt"; then
        cat "$PWD/stderr.txt" >&2
        fail "sync exited nonzero"
      fi
    }

    # expect <path> <printf args...>: the file holds exactly the bytes printf writes.
    expect() {
      local path=$1
      shift
      printf "$@" | cmp -s - "$path" || fail "$path does not hold the expected bytes"
    }

    CASE=timer
    jq -e '.OnCalendar == "*-*-* 03:45:00" and .Persistent == true and .Unit == "transcript-sync.service"' ${timerJson} >/dev/null \
      || fail "timer is not 03:45 Persistent for transcript-sync.service"

    CASE=appends
    setup appends
    mkdir -p "$HOME/.claude/projects/p" "$HOME/.claude/todos"
    printf 'a1\n' > "$HOME/.claude/projects/p/s.jsonl"
    printf 'v1' > "$HOME/.claude/todos/t.json"
    sync_run
    nas="$TRANSCRIPT_SYNC_BUCKET/personal"
    expect "$nas/projects/p/s.jsonl" 'a1\n'
    expect "$nas/todos/t.json" 'v1'
    inode=$(stat -c %i "$nas/projects/p/s.jsonl")
    printf 'a2\n' >> "$HOME/.claude/projects/p/s.jsonl"
    printf 'v2' > "$HOME/.claude/todos/t.json"
    sync_run
    expect "$nas/projects/p/s.jsonl" 'a1\na2\n'
    expect "$nas/todos/t.json" 'v2'
    [ "$(stat -c %i "$nas/projects/p/s.jsonl")" = "$inode" ] \
      || fail ".jsonl was rewritten whole instead of appended in place"

    CASE=never-shrinks
    setup never-shrinks
    mkdir -p "$HOME/.claude/projects/p" "$HOME/.claude/todos"
    printf 'a1\n' > "$HOME/.claude/projects/p/s.jsonl"
    sync_run
    nas="$TRANSCRIPT_SYNC_BUCKET/personal"
    printf 'a1\nNAS-ONLY\n' > "$nas/projects/p/s.jsonl"
    printf 'keep' > "$nas/projects/p/extra.jsonl"
    printf 'orphan' > "$nas/todos/orphan.json"
    touch "$HOME/.claude/projects/p/s.jsonl"
    sync_run
    expect "$nas/projects/p/s.jsonl" 'a1\nNAS-ONLY\n'
    expect "$nas/projects/p/extra.jsonl" 'keep'
    expect "$nas/todos/orphan.json" 'orphan'

    CASE=diverged-skips
    setup diverged-skips
    mkdir -p "$HOME/.claude/projects/p" "$TRANSCRIPT_SYNC_BUCKET/personal/projects/p"
    printf 'ABCDEF\n' > "$HOME/.claude/projects/p/s.jsonl"
    printf 'XYZ\n' > "$TRANSCRIPT_SYNC_BUCKET/personal/projects/p/s.jsonl"
    sync_run
    nasfile="$TRANSCRIPT_SYNC_BUCKET/personal/projects/p/s.jsonl"
    expect "$nasfile" 'XYZ\n'
    [ "$(wc -l < "$TRANSCRIPT_SYNC_STATE/conflicts")" -eq 1 ] \
      || fail "conflicts does not hold exactly one line"
    awk -F '\t' -v p="$nasfile" \
      'NF == 3 && $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ && $2 == p { ok = 1 } END { exit !ok }' \
      "$TRANSCRIPT_SYNC_STATE/conflicts" \
      || fail "conflicts line is not timestamp, NAS path, reason"

    CASE=incremental
    setup incremental
    mkdir -p "$HOME/.claude/projects/p" "$HOME/.claude/todos" "$PWD/incremental-src"
    printf 'one\n' > "$HOME/.claude/projects/p/a.jsonl"
    printf 't1' > "$HOME/.claude/todos/t.json"
    sync_run
    nas="$TRANSCRIPT_SYNC_BUCKET/personal"
    printf 'nas-edit' > "$nas/todos/t.json"
    sync_run
    expect "$nas/todos/t.json" 'nas-edit'
    printf 'old\n' > "$PWD/incremental-src/moved.json"
    touch -d '2001-01-01' "$PWD/incremental-src/moved.json"
    mv "$PWD/incremental-src/moved.json" "$HOME/.claude/todos/moved.json"
    sync_run
    expect "$nas/todos/moved.json" 'old\n'
    expect "$nas/todos/t.json" 'nas-edit'
    # A failed run keeps last-success, so a file changed before it is sent by the next run.
    mkdir -p "$HOME/.claude/tasks"
    printf 'n1\n' > "$HOME/.claude/tasks/new.json"
    printf 'blocker' > "$nas/tasks"
    rc=0
    "$bin" sync 2>/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "run with a blocked destination exited 0"
    rm "$nas/tasks"
    sync_run
    expect "$nas/tasks/new.json" 'n1\n'

    CASE=skips-links
    setup skips-links
    mkdir -p "$HOME/.claude/projects/p" "$HOME/.codex" "$PWD/outside"
    printf 'real\n' > "$HOME/.claude/projects/p/real.jsonl"
    printf 'secret\n' > "$PWD/outside/secret.jsonl"
    ln -s "$PWD/outside/secret.jsonl" "$HOME/.claude/projects/p/link.jsonl"
    mkdir -p "$TRANSCRIPT_SYNC_BUCKET/codex/archived_sessions"
    printf 'arch\n' > "$TRANSCRIPT_SYNC_BUCKET/codex/archived_sessions/a.jsonl"
    ln -s "$TRANSCRIPT_SYNC_BUCKET/codex/archived_sessions" "$HOME/.codex/archived_sessions"
    sync_run
    expect "$TRANSCRIPT_SYNC_BUCKET/personal/projects/p/real.jsonl" 'real\n'
    if [ -e "$TRANSCRIPT_SYNC_BUCKET/personal/projects/p/link.jsonl" ] \
      || [ -L "$TRANSCRIPT_SYNC_BUCKET/personal/projects/p/link.jsonl" ]; then
      fail "symlink reached the NAS"
    fi
    [ -z "$(find "$TRANSCRIPT_SYNC_BUCKET" -type l)" ] || fail "a symlink exists on the NAS"
    expect "$TRANSCRIPT_SYNC_BUCKET/codex/archived_sessions/a.jsonl" 'arch\n'
    grep -q skipping "$PWD/stderr.txt" || fail "dir linked into the bucket was not skipped"

    CASE=all-linked
    setup all-linked
    nas="$TRANSCRIPT_SYNC_BUCKET"
    for d in personal/projects personal/sessions personal/todos personal/tasks codex/sessions codex/archived_sessions; do
      mkdir -p "$nas/$d"
      printf 'keep\n' > "$nas/$d/kept.jsonl"
    done
    mkdir -p "$HOME/.claude" "$HOME/.codex"
    for d in projects sessions todos tasks; do
      ln -s "$nas/personal/$d" "$HOME/.claude/$d"
    done
    for d in sessions archived_sessions; do
      ln -s "$nas/codex/$d" "$HOME/.codex/$d"
    done
    find "$nas" -printf '%P %s %T@\n' | sort > "$PWD/all-linked.before"
    sync_run
    find "$nas" -printf '%P %s %T@\n' | sort > "$PWD/all-linked.after"
    cmp -s "$PWD/all-linked.before" "$PWD/all-linked.after" || fail "NAS changed although every dir is linked"
    [ "$(grep -c skipping "$PWD/stderr.txt")" -eq 6 ] || fail "not all six linked dirs were skipped"

    CASE=usage
    setup usage
    rc=0
    "$bin" bogus 2>"$PWD/usage.txt" || rc=$?
    [ "$rc" -eq 2 ] || fail "unknown subcommand exited $rc, want 2"
    grep -q usage "$PWD/usage.txt" || fail "unknown subcommand printed no usage on stderr"
    rc=0
    "$bin" 2>/dev/null || rc=$?
    [ "$rc" -eq 2 ] || fail "no subcommand exited $rc, want 2"

    touch $out
  ''
