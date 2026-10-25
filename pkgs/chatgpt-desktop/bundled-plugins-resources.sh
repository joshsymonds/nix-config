#!@shell@
# Prints a resources directory for CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH.
#
# The app materializes its bundled plugin marketplace by fs.cp-ing
# resources/plugins into ~/.codex/.tmp/bundled-marketplaces/<name>.staging-*,
# then rewriting files inside the copy. fs.cp keeps the Nix store's read-only
# modes, so the rewrite fails with EACCES and the cleanup rm cannot unlink
# inside the read-only directories: every attempt leaked a ~55 MB staging
# directory and the runtime marketplace never updated.
#
# The mirror symlinks every resources entry back to the store except plugins/,
# which is a user-writable copy, so the staged copy is writable too. It is
# keyed by store path and rebuilt only when the package changes.
set -eu
PATH=@coreutils@/bin:@findutils@/bin

resources=@resources@
root=${XDG_STATE_HOME:-$HOME/.local/state}/chatgpt-desktop/bundled-plugins-resources
dest=$root/$(basename @out@)

if [ ! -e "$dest/.complete" ]; then
  mkdir -p "$root"
  tmp=$(mktemp -d "$root/.tmp.XXXXXX")
  find "$resources" -mindepth 1 -maxdepth 1 ! -name plugins -exec ln -s -t "$tmp" {} +
  cp -r "$resources/plugins" "$tmp/plugins"
  chmod -R u+w "$tmp/plugins"
  touch "$tmp/.complete"
  if [ -e "$dest" ]; then
    chmod -R u+w "$dest"
    rm -rf "$dest"
  fi
  # A concurrent launch may have won the race; its mirror is equivalent.
  mv -T "$tmp" "$dest" 2>/dev/null || { chmod -R u+w "$tmp"; rm -rf "$tmp"; }
fi

# Drop mirrors from other package versions, and temp dirs abandoned long
# enough that no concurrent launch can still be filling them.
find "$root" -mindepth 1 -maxdepth 1 ! -path "$dest" \
  \( ! -name '.tmp.*' -o -mmin +10 \) -print0 |
  while IFS= read -r -d '' stale; do
    chmod -R u+w "$stale"
    rm -rf "$stale"
  done

printf '%s\n' "$dest"
