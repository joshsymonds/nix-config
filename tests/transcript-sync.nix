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

    # localize_run: one localize run that must exit 0. Its output is kept in
    # stdout.txt and stderr.txt.
    localize_run() {
      if ! "$bin" localize >"$PWD/stdout.txt" 2>"$PWD/stderr.txt"; then
        cat "$PWD/stderr.txt" >&2
        fail "localize exited nonzero"
      fi
    }

    # localize_fixture: all six bucket dirs hold a file, and HOME links to them.
    localize_fixture() {
      local nas=$TRANSCRIPT_SYNC_BUCKET d
      for d in personal/projects personal/sessions personal/todos personal/tasks codex/sessions codex/archived_sessions; do
        mkdir -p "$nas/$d"
        printf 'keep\n' > "$nas/$d/kept.jsonl"
      done
      mkdir -p "$nas/personal/projects/nested/deeper"
      printf 'deep\n' > "$nas/personal/projects/nested/deeper/d.jsonl"
      mkdir -p "$HOME/.claude" "$HOME/.codex"
      for d in projects sessions todos tasks; do
        ln -s "$nas/personal/$d" "$HOME/.claude/$d"
      done
      for d in sessions archived_sessions; do
        ln -s "$nas/codex/$d" "$HOME/.codex/$d"
      done
    }

    # nas_snapshot <file>: the bucket's names, sizes and mtimes.
    nas_snapshot() {
      find "$TRANSCRIPT_SYNC_BUCKET" -printf '%P %s %T@\n' | sort >"$1"
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

    CASE=localize-copies
    setup localize-copies
    localize_fixture
    nas=$TRANSCRIPT_SYNC_BUCKET
    nas_snapshot "$PWD/before.txt"
    localize_run
    nas_snapshot "$PWD/after.txt"
    cmp -s "$PWD/before.txt" "$PWD/after.txt" || fail "NAS changed"
    grep -qx 'missing: 0' "$PWD/stdout.txt" || fail "stdout does not report missing: 0"
    [ -e "$TRANSCRIPT_SYNC_STATE/last-success" ] || fail "last-success was not written"
    for d in projects sessions todos tasks; do
      [ "$(readlink -f "$HOME/.claude/$d")" = "$(readlink -f "$HOME/.claude-local/$d")" ] \
        || fail "~/.claude/$d does not resolve to ~/.claude-local/$d"
    done
    for d in sessions archived_sessions; do
      [ "$(readlink -f "$HOME/.codex/$d")" = "$(readlink -f "$HOME/.codex-local/$d")" ] \
        || fail "~/.codex/$d does not resolve to ~/.codex-local/$d"
    done
    for d in personal/projects personal/sessions personal/todos personal/tasks codex/sessions codex/archived_sessions; do
      case "$d" in
      personal/*) twin="$HOME/.claude-local/''${d#personal/}" ;;
      *) twin="$HOME/.codex-local/''${d#codex/}" ;;
      esac
      find "$nas/$d" -type f >"$PWD/files.txt"
      while IFS= read -r f; do
        cmp -s "$f" "$twin/''${f#"$nas/$d/"}" || fail "$f has no identical local copy"
      done <"$PWD/files.txt"
    done

    CASE=localize-copy-failure
    setup localize-copy-failure
    localize_fixture
    nas=$TRANSCRIPT_SYNC_BUCKET
    mkdir -p "$HOME/.codex-local"
    printf 'blocker' > "$HOME/.codex-local/sessions"
    nas_snapshot "$PWD/before.txt"
    rc=0
    "$bin" localize >"$PWD/stdout.txt" 2>"$PWD/stderr.txt" || rc=$?
    [ "$rc" -ne 0 ] || fail "run with a failed copy exited 0"
    [ "$(readlink -f "$HOME/.codex/sessions")" = "$(readlink -f "$nas/codex/sessions")" ] \
      || fail "the link whose copy failed was swapped"
    nas_snapshot "$PWD/after.txt"
    cmp -s "$PWD/before.txt" "$PWD/after.txt" || fail "NAS changed"

    CASE=localize-idempotent
    setup localize-idempotent
    localize_fixture
    nas=$TRANSCRIPT_SYNC_BUCKET
    printf 'old\n' > "$nas/personal/projects/s.jsonl"
    touch -d '2001-01-01' "$nas/personal/projects/s.jsonl"
    mkdir -p "$HOME/.claude-local/projects" "$HOME/.claude-local/todos"
    printf 'newer-local-line\n' > "$HOME/.claude-local/projects/s.jsonl"
    printf 'local\n' > "$HOME/.claude-local/todos/t.json"
    ln -sfn "$HOME/.claude-local/todos" "$HOME/.claude/todos"
    nas_snapshot "$PWD/before.txt"
    localize_run
    expect "$HOME/.claude-local/projects/s.jsonl" 'newer-local-line\n'
    expect "$HOME/.claude-local/todos/t.json" 'local\n'
    [ "$(readlink "$HOME/.claude/todos")" = "$HOME/.claude-local/todos" ] || fail "already-local dir was relinked"
    grep -q skipping "$PWD/stderr.txt" || fail "already-local dir was not skipped with a message"
    localize_run
    nas_snapshot "$PWD/after.txt"
    cmp -s "$PWD/before.txt" "$PWD/after.txt" || fail "NAS changed"

    CASE=localize-rewrites-links
    setup localize-rewrites-links
    localize_fixture
    nas=$TRANSCRIPT_SYNC_BUCKET
    ln -s "$nas/personal/projects/nested/deeper/d.jsonl" "$nas/personal/projects/alias.jsonl"
    ln -s "$nas/personal/projects/nested" "$nas/personal/projects/nested-link"
    nas_snapshot "$PWD/before.txt"
    localize_run
    nas_snapshot "$PWD/after.txt"
    cmp -s "$PWD/before.txt" "$PWD/after.txt" || fail "NAS changed"
    [ "$(readlink "$HOME/.claude-local/projects/alias.jsonl")" = "$HOME/.claude-local/projects/nested/deeper/d.jsonl" ] \
      || fail "file link in projects does not point into the twin"
    [ "$(readlink "$HOME/.claude-local/projects/nested-link")" = "$HOME/.claude-local/projects/nested" ] \
      || fail "dir link in projects does not point into the twin"
    [ -z "$(find "$HOME/.claude-local" "$HOME/.codex-local" -lname "$nas/*")" ] \
      || fail "a local twin link still targets the bucket"

    CASE=localize-then-sync-quiet
    setup localize-then-sync-quiet
    localize_fixture
    nas=$TRANSCRIPT_SYNC_BUCKET
    for d in personal/projects personal/sessions personal/todos personal/tasks codex/sessions codex/archived_sessions; do
      printf 'bytes %s\n' "$d" > "$nas/$d/note.json"
    done
    find "$nas" -type f -printf '%P %i\n' | sort >"$PWD/inodes-before.txt"
    localize_run
    sync_run
    find "$nas" -type f -printf '%P %i\n' | sort >"$PWD/inodes-after.txt"
    cmp -s "$PWD/inodes-before.txt" "$PWD/inodes-after.txt" || fail "sync rewrote a bucket file that localize only copied"
    for d in personal/projects personal/sessions personal/todos personal/tasks codex/sessions codex/archived_sessions; do
      expect "$nas/$d/note.json" 'bytes %s\n' "$d"
    done

    CASE=localize-window-rewrite
    setup localize-window-rewrite
    localize_fixture
    nas=$TRANSCRIPT_SYNC_BUCKET
    printf 'a1\n' > "$nas/personal/projects/s.jsonl"
    printf 'AAAA' > "$nas/personal/todos/x.json"
    # The NAS changes after the size record and before the post-swap listing. That
    # listing is the first find run once localize-stamp exists. The function is
    # exported into the packaged script's bash, and removed after the run.
    find() {
      if [ -e "$TRANSCRIPT_SYNC_STATE/localize-stamp" ] && [ ! -e "$PWD/nas-changed" ]; then
        touch "$PWD/nas-changed"
        printf 'a1\na2\n' > "$TRANSCRIPT_SYNC_BUCKET/personal/projects/s.jsonl"
        printf 'CDEFGHIJ' > "$TRANSCRIPT_SYNC_BUCKET/personal/todos/x.json"
      fi
      command find "$@"
    }
    export -f find
    localize_run
    unset -f find
    [ -e "$PWD/nas-changed" ] || fail "the NAS was not changed between the size record and the listing"
    nas_real=$(readlink -f "$nas")
    expect "$HOME/.claude-local/projects/s.jsonl" 'a1\na2\n'
    expect "$HOME/.claude-local/todos/x.json" 'AAAA'
    grep -qxF "window: $nas_real/personal/todos/x.json" "$PWD/stdout.txt" \
      || fail "stdout does not list the rewritten file as a window file"
    sync_run
    expect "$nas/personal/todos/x.json" 'CDEFGHIJ'

    CASE=localize-grows-before-record
    setup localize-grows-before-record
    localize_fixture
    nas=$TRANSCRIPT_SYNC_BUCKET
    printf 'a1\n' > "$nas/personal/projects/s.jsonl"
    # The NAS gains a line after the second copy pass and before the size record.
    # That record is the first find of the run. The function is exported into the
    # packaged script's bash, and removed after the run.
    find() {
      if [ ! -e "$PWD/grown" ]; then
        touch "$PWD/grown"
        printf 'a2\n' >> "$TRANSCRIPT_SYNC_BUCKET/personal/projects/s.jsonl"
      fi
      command find "$@"
    }
    export -f find
    localize_run
    unset -f find
    [ -e "$PWD/grown" ] || fail "the NAS was not changed before the size record"
    grep -qxF 'missing: 0' "$PWD/stdout.txt" || fail "stdout does not report missing: 0"
    grep -q '^window:' "$PWD/stdout.txt" && fail "a grown file was listed as a window file instead of appended"
    cmp -s "$nas/personal/projects/s.jsonl" "$HOME/.claude-local/projects/s.jsonl" \
      || fail "the local copy is not byte-identical to the NAS file"

    CASE=localize-rerun-keeps-unsent
    setup localize-rerun-keeps-unsent
    localize_fixture
    nas=$TRANSCRIPT_SYNC_BUCKET
    printf 'note\n' > "$nas/codex/sessions/note.json"
    mkdir -p "$HOME/.codex-local"
    printf 'blocker' > "$HOME/.codex-local/sessions"
    find "$nas/codex/sessions" -type f -printf '%P %i\n' | sort >"$PWD/inodes-before.txt"
    rc=0
    "$bin" localize >"$PWD/stdout.txt" 2>"$PWD/stderr.txt" || rc=$?
    [ "$rc" -ne 0 ] || fail "run 1 with a blocked copy exited 0"
    printf 'A\n' > "$HOME/.claude/todos/a.json"
    sync_run
    printf 'B\n' > "$HOME/.claude/todos/b.json"
    rm "$HOME/.codex-local/sessions"
    localize_run
    sync_run
    find "$nas/codex/sessions" -type f -printf '%P %i\n' | sort >"$PWD/inodes-after.txt"
    cmp -s "$PWD/inodes-before.txt" "$PWD/inodes-after.txt" || fail "sync rewrote a bucket file that localize only copied"
    expect "$nas/personal/todos/a.json" 'A\n'
    expect "$nas/personal/todos/b.json" 'B\n'

    CASE=usage
    setup usage
    rc=0
    "$bin" bogus 2>"$PWD/usage.txt" || rc=$?
    [ "$rc" -eq 2 ] || fail "unknown subcommand exited $rc, want 2"
    grep -q usage "$PWD/usage.txt" || fail "unknown subcommand printed no usage on stderr"
    grep -qF 'usage: transcript-sync sync|localize' "$PWD/usage.txt" || fail "usage line does not name sync and localize"
    rc=0
    "$bin" 2>/dev/null || rc=$?
    [ "$rc" -eq 2 ] || fail "no subcommand exited $rc, want 2"

    touch $out
  ''
