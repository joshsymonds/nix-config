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

# localize_prepare <link> <twin> <index>: the first copy pass of the NAS dir that
# <link> resolves into the bucket onto <twin>. A dir that is skipped, or whose
# copy fails, is not marked copied and is not swapped.
localize_prepare() {
  local src=$1 twin=$2 index=$3 real
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
  if ! mkdir -p "$twin" || ! localize_copy "$real" "$twin"; then
    echo "transcript-sync: copy of $real to $twin failed; $src left as it is" >&2
    failed=1
    return 0
  fi
  localize_copied[index]=1
}

# localize_record <link> <twin> <index>: the second copy pass, run once every
# first pass is done, so a file written during the first is caught. The sizes the
# twin holds after that pass are recorded for localize_swap, not the NAS sizes: a
# NAS file that grows after the pass is then appended in the swap rather than
# recorded as copied. A dir whose copy or listing fails is not marked ready and
# is not swapped.
localize_record() {
  local src=$1 twin=$2 index=$3 real
  if [ -z "${localize_copied[index]:-}" ]; then
    return 0
  fi
  real=$(readlink -f "$src")
  if ! localize_copy "$real" "$twin"; then
    echo "transcript-sync: copy of $real to $twin failed; $src left as it is" >&2
    failed=1
    return 0
  fi
  if ! find "$twin" -type f -printf '%s %P\0' >"$state/localize-recorded.$index"; then
    echo "transcript-sync: cannot list $twin" >&2
    failed=1
    return 0
  fi
  localize_ready[index]=1
}

# localize_mark <link>: a dir that already resolves outside the bucket can hold
# local files that sync has not sent. The stamp is taken before this runs, so
# last-success moves past them. A chmod to each file's own mode moves its ctime
# past the stamp and leaves its bytes, mtime and mode alone, so the next sync
# selects it. A file that vanished needs no mark. If any other file cannot be
# marked, the run swaps nothing, so last-success stays where it is.
localize_mark() {
  local src=$1 real f
  local listing="$state/localize-listing"
  local -a since=()
  if [ ! -e "$src" ]; then
    return 0
  fi
  real=$(readlink -f "$src")
  case "$real/" in
  "$bucket/"*) return 0 ;;
  esac
  if [ -e "$last" ]; then
    since=(-cnewer "$last")
  fi
  if ! find "$real" -type f "${since[@]}" -print0 >"$listing"; then
    echo "transcript-sync: cannot list $real" >&2
    failed=1
    localize_unmarked=1
    return 0
  fi
  while IFS= read -r -d '' f; do
    if ! chmod --reference="$f" -- "$f" && [ -e "$f" ]; then
      echo "transcript-sync: cannot mark $f" >&2
      failed=1
      localize_unmarked=1
    fi
  done <"$listing"
}

# localize_swap <link> <twin> <index>: swaps the link to the twin for a dir that
# localize_record marked ready. NAS files that grew since the copy are appended
# to the twin when the twin still holds exactly the recorded bytes, and listed as
# window files otherwise. Finally, symlinks in the twin that point into the NAS
# dir are retargeted to the twin.
localize_swap() {
  local src=$1 twin=$2 index=$3 real rec nas_size rec_size rel local_path local_size tmp target link
  local listing="$state/localize-listing"
  local -A recorded=()
  if [ -z "${localize_ready[index]:-}" ]; then
    return 0
  fi
  real=$(readlink -f "$src")
  while IFS= read -r -d '' rec; do
    recorded["${rec#* }"]=${rec%% *}
  done <"$state/localize-recorded.$index"
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
      if [ -f "$local_path" ] && [ "$(stat -c %s -- "$local_path")" -eq "$rec_size" ] && cmp -s -n "$rec_size" "$local_path" "$real/$rel"; then
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
  localize_swapped=0
  localize_unmarked=0
  localize_missing=0
  localize_copied=()
  localize_ready=()
  localize_prepare "$HOME/.claude/projects" "$HOME/.claude-local/projects" 1
  localize_prepare "$HOME/.claude/sessions" "$HOME/.claude-local/sessions" 2
  localize_prepare "$HOME/.claude/todos" "$HOME/.claude-local/todos" 3
  localize_prepare "$HOME/.claude/tasks" "$HOME/.claude-local/tasks" 4
  localize_prepare "$HOME/.codex/sessions" "$HOME/.codex-local/sessions" 5
  localize_prepare "$HOME/.codex/archived_sessions" "$HOME/.codex-local/archived_sessions" 6
  localize_record "$HOME/.claude/projects" "$HOME/.claude-local/projects" 1
  localize_record "$HOME/.claude/sessions" "$HOME/.claude-local/sessions" 2
  localize_record "$HOME/.claude/todos" "$HOME/.claude-local/todos" 3
  localize_record "$HOME/.claude/tasks" "$HOME/.claude-local/tasks" 4
  localize_record "$HOME/.codex/sessions" "$HOME/.codex-local/sessions" 5
  localize_record "$HOME/.codex/archived_sessions" "$HOME/.codex-local/archived_sessions" 6
  # Taken after every copy and size record, so no copy is newer than the stamp.
  # The marks run after it, and the swaps only once every mark has succeeded.
  if ! touch "$localize_stamp"; then
    echo "transcript-sync: cannot write $localize_stamp" >&2
    failed=1
  else
    localize_mark "$HOME/.claude/projects"
    localize_mark "$HOME/.claude/sessions"
    localize_mark "$HOME/.claude/todos"
    localize_mark "$HOME/.claude/tasks"
    localize_mark "$HOME/.codex/sessions"
    localize_mark "$HOME/.codex/archived_sessions"
    if [ "$localize_unmarked" -eq 0 ]; then
      localize_swap "$HOME/.claude/projects" "$HOME/.claude-local/projects" 1
      localize_swap "$HOME/.claude/sessions" "$HOME/.claude-local/sessions" 2
      localize_swap "$HOME/.claude/todos" "$HOME/.claude-local/todos" 3
      localize_swap "$HOME/.claude/tasks" "$HOME/.claude-local/tasks" 4
      localize_swap "$HOME/.codex/sessions" "$HOME/.codex-local/sessions" 5
      localize_swap "$HOME/.codex/archived_sessions" "$HOME/.codex-local/archived_sessions" 6
    fi
  fi
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
