# transcript-sync: copies the local Claude and Codex transcripts into the NAS
# bucket. The copy is append-only: nothing on the NAS is deleted, truncated, or
# renamed away. A run that fails leaves last-success in place, so the next run
# resends everything changed since the last complete run.

if [ "$#" -ne 1 ] || [ "$1" != sync ]; then
  echo "usage: transcript-sync sync" >&2
  exit 2
fi

state="${TRANSCRIPT_SYNC_STATE:-$HOME/.claude-local/transcript-sync}"

if [ -n "${TRANSCRIPT_SYNC_BUCKET:-}" ]; then
  bucket="$TRANSCRIPT_SYNC_BUCKET"
else
  # Trigger the automount, then require NFS before touching /mnt/claude.
  ls /mnt/claude >/dev/null 2>&1 || true
  if ! findmnt -n -t nfs,nfs4 /mnt/claude >/dev/null 2>&1; then
    echo "transcript-sync: /mnt/claude is not mounted (NAS down?)" >&2
    exit 1
  fi
  bucket="/mnt/claude/$(uname -n)"
fi

mkdir -p "$state" "$bucket"
bucket=$(readlink -f "$bucket")

last="$state/last-success"
conflicts="$state/conflicts"
failed=0

# Stamped before anything is listed. It replaces last-success only when the
# whole run succeeds, so a file changed mid-run is picked up by the next run.
touch "$state/run-start"

# sync_jsonl <local> <nas>: appends the part of a local .jsonl that the NAS copy
# lacks. A NAS copy at least as long as the local file is left alone. A NAS copy
# whose prefix differs is logged to conflicts and skipped.
sync_jsonl() {
  local src=$1 nas=$2 nas_size local_size rc=0
  if [ ! -e "$nas" ]; then
    if ! mkdir -p "$(dirname -- "$nas")"; then
      echo "transcript-sync: cannot create parent of $nas" >&2
      failed=1
      return 0
    fi
    rsync -t --no-owner --no-group "$src" "$nas" || failed=1
    return 0
  fi
  nas_size=$(stat -c %s "$nas")
  local_size=$(stat -c %s "$src")
  if [ "$nas_size" -ge "$local_size" ]; then
    return 0
  fi
  cmp -s -n "$nas_size" "$src" "$nas" || rc=$?
  case "$rc" in
  0) rsync --append -t --no-owner --no-group "$src" "$nas" || failed=1 ;;
  1) printf '%s\t%s\tprefix mismatch\n' "$(date -Iseconds)" "$nas" >>"$conflicts" ;;
  *)
    echo "transcript-sync: cannot compare $src with $nas" >&2
    failed=1
    ;;
  esac
}

# sync_dir <local dir> <nas dir>: copies the regular files of one local dir whose
# ctime is past last-success. A moved-in file keeps its old mtime but gets a new
# ctime, so it is caught too. A dir that resolves into the bucket is skipped.
sync_dir() {
  local src=$1 dest=$2 real rel
  local listing="$state/listing" others="$state/others"
  local -a since=()
  [ -d "$src" ] || return 0
  real=$(readlink -f "$src")
  case "$real/" in
  "$bucket/"*)
    echo "transcript-sync: skipping $src (resolves into the bucket)" >&2
    return 0
    ;;
  esac
  if [ -e "$last" ]; then
    since=(-cnewer "$last")
  fi
  if ! mkdir -p "$dest"; then
    echo "transcript-sync: cannot create $dest" >&2
    failed=1
    return 0
  fi
  if ! find "$real" -type f "${since[@]}" -printf '%P\0' >"$listing"; then
    echo "transcript-sync: cannot list $real" >&2
    failed=1
    return 0
  fi
  : >"$others"
  while IFS= read -r -d '' rel; do
    case "$rel" in
    *.jsonl) sync_jsonl "$real/$rel" "$dest/$rel" ;;
    *) printf '%s\0' "$rel" >>"$others" ;;
    esac
  done <"$listing"
  # --ignore-times: the ctime filter already chose these files. rsync's quick
  # check (size and whole-second mtime) would skip a same-size rewrite.
  rsync -t --ignore-times --no-owner --no-group --from0 --files-from="$others" "$real/" "$dest/" || failed=1
}

sync_dir "$HOME/.claude/projects" "$bucket/personal/projects"
sync_dir "$HOME/.claude/sessions" "$bucket/personal/sessions"
sync_dir "$HOME/.claude/todos" "$bucket/personal/todos"
sync_dir "$HOME/.claude/tasks" "$bucket/personal/tasks"
sync_dir "$HOME/.codex/sessions" "$bucket/codex/sessions"
sync_dir "$HOME/.codex/archived_sessions" "$bucket/codex/archived_sessions"

if [ "$failed" -ne 0 ]; then
  echo "transcript-sync: run failed; last-success not advanced" >&2
  exit 1
fi
mv -f "$state/run-start" "$last"
