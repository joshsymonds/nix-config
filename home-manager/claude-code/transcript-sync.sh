# transcript-sync: copies the local Claude and Codex transcripts into the NAS
# bucket. The copy is append-only: nothing on the NAS is deleted, truncated, or
# renamed away. A run that fails leaves last-success in place, so the next run
# resends everything changed since the last complete run.
#
# localize moves the dirs that link into the bucket onto local twins
# (~/.claude-local, ~/.codex-local) and swaps each link to its twin. It only
# reads the NAS.

if [ "$#" -ne 1 ] || { [ "$1" != sync ] && [ "$1" != localize ]; }; then
  echo "usage: transcript-sync sync|localize" >&2
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

mkdir -p "$state"
if [ "$1" = sync ]; then
  mkdir -p "$bucket"
fi
bucket=$(readlink -f "$bucket")

last="$state/last-success"
conflicts="$state/conflicts"
failed=0

# localize_copy <nas dir> <twin>: one rsync pass from a NAS dir into its twin.
# Symlinks are copied as symlinks, and a newer twin file is kept.
localize_copy() {
  rsync -a --update --no-owner --no-group --chmod=Du=rwx,Dgo=,Fu=rw,Fgo= "$1/" "$2/"
}

# localize_dir <link> <twin>: moves the dir that <link> resolves into the bucket
# onto <twin>. Two copy passes run first, so a file written during the first is
# caught. Then the link is swapped to the twin. NAS files that grew since the
# copy are appended to the twin when the twin still has the recorded size, and
# listed as window files otherwise. Finally, symlinks in the twin that point into
# the NAS dir are retargeted to the twin.
localize_dir() {
  local src=$1 twin=$2 real rec nas_size rec_size rel local_path local_size tmp target link
  local listing="$state/localize-listing"
  local -A recorded=()
  if [ ! -e "$src" ]; then
    echo "transcript-sync: skipping $src (missing)" >&2
    return 0
  fi
  real=$(readlink -f "$src")
  case "$real/" in
  "$bucket/"*) ;;
  *)
    echo "transcript-sync: skipping $src (does not resolve into the bucket)" >&2
    return 0
    ;;
  esac
  if ! mkdir -p "$twin" || ! localize_copy "$real" "$twin" || ! localize_copy "$real" "$twin"; then
    echo "transcript-sync: copy of $real to $twin failed; $src left as it is" >&2
    failed=1
    return 0
  fi
  if ! find "$real" -type f -printf '%s %P\0' >"$listing"; then
    echo "transcript-sync: cannot list $real" >&2
    failed=1
    return 0
  fi
  while IFS= read -r -d '' rec; do
    recorded["${rec#* }"]=${rec%% *}
  done <"$listing"
  # The stamp is taken before the first swap of the run, and only then.
  if [ "$localize_stamped" -eq 0 ]; then
    if ! touch "$localize_stamp"; then
      echo "transcript-sync: cannot write $localize_stamp" >&2
      failed=1
      return 0
    fi
    localize_stamped=1
  fi
  tmp="$(dirname -- "$src")/.$(basename -- "$src").localize"
  if ! ln -s "$twin" "$tmp" || ! mv -T "$tmp" "$src"; then
    echo "transcript-sync: cannot swap $src to $twin" >&2
    failed=1
    return 0
  fi
  localize_swapped=1
  if ! find "$real" -type f -printf '%s %P\0' >"$listing"; then
    echo "transcript-sync: cannot list $real" >&2
    failed=1
    return 0
  fi
  while IFS= read -r -d '' rec; do
    nas_size=${rec%% *}
    rel=${rec#* }
    rec_size=${recorded["$rel"]:-0}
    local_path="$twin/$rel"
    if [ "$nas_size" -gt "$rec_size" ]; then
      if [ -f "$local_path" ] && [ "$(stat -c %s -- "$local_path")" -eq "$rec_size" ]; then
        if ! dd if="$real/$rel" iflag=skip_bytes,count_bytes skip="$rec_size" count="$((nas_size - rec_size))" status=none >>"$local_path"; then
          echo "transcript-sync: cannot append to $local_path" >&2
          failed=1
        fi
      else
        echo "window: $real/$rel"
        continue
      fi
    fi
    if ! local_size=$(stat -c %s -- "$local_path") || [ "$local_size" -lt "$nas_size" ]; then
      localize_missing=$((localize_missing + 1))
    fi
  done <"$listing"
  if ! find "$twin" -type l -print0 >"$listing"; then
    echo "transcript-sync: cannot list $twin" >&2
    failed=1
    return 0
  fi
  while IFS= read -r -d '' link; do
    target=$(readlink -- "$link")
    case "$target" in
    "$real"/*)
      ln -sfn -- "$twin/${target#"$real"/}" "$link" || failed=1
      ;;
    esac
  done <"$listing"
}

if [ "$1" = localize ]; then
  localize_stamp="$state/localize-stamp"
  localize_stamped=0
  localize_swapped=0
  localize_missing=0
  localize_dir "$HOME/.claude/projects" "$HOME/.claude-local/projects"
  localize_dir "$HOME/.claude/sessions" "$HOME/.claude-local/sessions"
  localize_dir "$HOME/.claude/todos" "$HOME/.claude-local/todos"
  localize_dir "$HOME/.claude/tasks" "$HOME/.claude-local/tasks"
  localize_dir "$HOME/.codex/sessions" "$HOME/.codex-local/sessions"
  localize_dir "$HOME/.codex/archived_sessions" "$HOME/.codex-local/archived_sessions"
  echo "missing: $localize_missing"
  # A run that swapped no link leaves last-success alone.
  if [ "$localize_swapped" -eq 1 ]; then
    mv -f "$localize_stamp" "$last" || failed=1
  fi
  if [ "$failed" -ne 0 ] || [ "$localize_missing" -ne 0 ]; then
    echo "transcript-sync: localize incomplete" >&2
    exit 1
  fi
  exit 0
fi

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
