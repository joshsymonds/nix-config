#!/usr/bin/env bash
#
# prepare-host-kit.sh — agent-driven NixOS host bring-up tool
#
# Two-stage workflow for adding a new host (e.g., gnomon) to the flake:
#
#   1. ./scripts/prepare-host-kit.sh keys <hostname>
#        Generates SSH host key + agekey + user SSH key, stashes the private
#        halves in ~/.local/share/host-kits/<hostname>/, programmatically
#        updates secrets/keys.nix, and re-keys every .age file in the repo
#        so the new user key joins allUserKeys-derived recipient lists.
#        Prints the user SSH pubkey for you to paste into GitHub.
#
#   2. ./scripts/prepare-host-kit.sh kit <hostname> <usb-path>
#        Verifies the GitHub paste happened and the keys.nix change is
#        committed + pushed, then writes the bootable kit (identity +
#        flake tarball + bootstrap script + manifest + README) to
#        <usb-path>/<hostname>-kit/.
#
# Run from a trusted machine that has ~/.config/agenix/keys.txt set up.

set -euo pipefail

# REPO_ROOT and STASH_BASE are overridable via env vars so the bats harness
# in scripts/tests/ can redirect them at the fixture without copying the script.
REPO_ROOT="${REPO_ROOT:-$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)}"
STASH_BASE="${STASH_BASE:-${HOME}/.local/share/host-kits}"
GITHUB_USER="${GITHUB_USER:-joshsymonds}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"
FLAKE_REF="${FLAKE_REF:-github:joshsymonds/nix-config}"

usage() {
  cat <<EOF
Usage:
  $0 keys <hostname>            Generate keys, edit keys.nix, re-key secrets
  $0 kit  <hostname> <usb>      Write USB kit at <usb>/<hostname>-kit/

The 'keys' subcommand:
  - Generates SSH host keypair (ed25519) for <hostname>
  - Derives agekey via ssh-to-age
  - Generates user SSH keypair (ed25519) for josh+<hostname>@joshsymonds.com
  - Stashes private keys in ${STASH_BASE}/<hostname>/
  - Updates secrets/keys.nix to include hosts.<hostname>, users.joshsymonds@<hostname>,
    and the output entry <hostname> = [hosts.<hostname>] ++ allUserKeys
  - Re-keys every .age file in the repo (since allUserKeys grew)
  - Prints the user SSH pubkey for GitHub paste

After running 'keys':
  1. git diff   (review)
  2. Add the printed user SSH key to GitHub Settings as "Josh <Hostname>"
  3. git commit -m "Add <hostname> host" && git push
  4. ./scripts/prepare-host-kit.sh kit <hostname> /path/to/usb   (TODO)
EOF
}

require_clean_tree() {
  if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    echo "ERROR: Working tree has uncommitted changes. Stash or commit first." >&2
    git -C "$REPO_ROOT" status --short >&2
    exit 1
  fi
}

require_dependencies() {
  local missing=()
  for cmd in ssh-keygen ssh-to-age agenix sed git find nix-shell curl install awk; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: required commands not in PATH: ${missing[*]}" >&2
    exit 1
  fi
  if [ ! -f "${HOME}/.config/agenix/keys.txt" ]; then
    echo "ERROR: ~/.config/agenix/keys.txt not found." >&2
    echo "       Run home-manager activation to derive it from your SSH key." >&2
    exit 1
  fi
}

# age and age-keygen are pulled in via nix-shell on demand so this script works
# without requiring `age` in the fleet-wide PATH.
age_keygen_y() {
  nix-shell -p age --run "age-keygen -y $1"
}

# Insert text into keys.nix at a given anchor line, then verify the insertion.
# Uses sed -E for ERE so patterns can use `+`, `?`, etc. naturally.
keys_nix_insert_after() {
  local anchor_pattern="$1"
  local new_line="$2"
  local file="${REPO_ROOT}/secrets/keys.nix"
  grep -qE "$anchor_pattern" "$file" || {
    echo "ERROR: anchor pattern not found in keys.nix: $anchor_pattern" >&2
    exit 1
  }
  sed -E -i "/${anchor_pattern}/a\\${new_line}" "$file"
  grep -qF "$new_line" "$file" || {
    echo "ERROR: insertion failed (line not found post-edit): $new_line" >&2
    exit 1
  }
}

keys_nix_insert_before() {
  local anchor_pattern="$1"
  local new_line="$2"
  local file="${REPO_ROOT}/secrets/keys.nix"
  grep -qE "$anchor_pattern" "$file" || {
    echo "ERROR: anchor pattern not found in keys.nix: $anchor_pattern" >&2
    exit 1
  }
  sed -E -i "/${anchor_pattern}/i\\${new_line}" "$file"
  grep -qF "$new_line" "$file" || {
    echo "ERROR: insertion failed (line not found post-edit): $new_line" >&2
    exit 1
  }
}

edit_keys_nix() {
  local hostname="$1"
  local host_age_pubkey="$2"
  local user_age_pubkey="$3"

  echo "→ Editing secrets/keys.nix..."

  # 1. hosts attrset — insert after the ninuan = "..." line
  keys_nix_insert_after \
    "^    ninuan = \"age1[a-z0-9]+\";\$" \
    "    ${hostname} = \"${host_age_pubkey}\";"

  # 2. users attrset — insert after "joshsymonds@ninuan" = "..." line
  keys_nix_insert_after \
    "^    \"joshsymonds@ninuan\" = \"age1[a-z0-9]+\";\$" \
    "    \"joshsymonds@${hostname}\" = \"${user_age_pubkey}\";"

  # 3. Output attrset — insert before the joshsymonds = allUserKeys; line
  keys_nix_insert_before \
    "^  joshsymonds = allUserKeys;\$" \
    "  ${hostname} = [hosts.${hostname}] ++ allUserKeys;"
}

rekey_all_secrets() {
  echo "→ Re-keying all .age files (export EDITOR=':' for non-interactive re-encrypt)..."
  cd "$REPO_ROOT"
  export EDITOR=":"
  local logfile
  logfile="$(mktemp)"
  trap 'rm -f "$logfile"' EXIT
  while IFS= read -r f; do
    printf "    %s\n" "$f"
    if ! agenix -e "$f" -i "${HOME}/.config/agenix/keys.txt" >"$logfile" 2>&1; then
      echo "ERROR: agenix -e failed for $f:" >&2
      cat "$logfile" >&2
      exit 1
    fi
  done < <(find secrets -name '*.age' | sort)
  rm -f "$logfile"
  trap - EXIT
}

cmd_keys() {
  local hostname="${1:-}"
  if [ -z "$hostname" ]; then
    echo "ERROR: 'keys' subcommand requires a hostname argument." >&2
    usage >&2
    exit 1
  fi

  local stash="${STASH_BASE}/${hostname}"

  require_clean_tree
  require_dependencies

  if [ -e "$stash" ]; then
    echo "ERROR: stash directory already exists: ${stash}" >&2
    echo "       Remove it (rm -rf) to start fresh." >&2
    exit 1
  fi

  mkdir -p "$stash"
  chmod 700 "$stash"

  echo "→ Generating SSH host key (root@${hostname})..."
  ssh-keygen -q -t ed25519 -N "" \
    -f "${stash}/ssh_host_ed25519_key" \
    -C "root@${hostname}"

  echo "→ Deriving agekey via ssh-to-age..."
  ssh-to-age -private-key \
    -i "${stash}/ssh_host_ed25519_key" \
    -o "${stash}/${hostname}.agekey"
  chmod 600 "${stash}/${hostname}.agekey"

  local host_age_pubkey
  host_age_pubkey="$(age_keygen_y "${stash}/${hostname}.agekey")"

  echo "→ Generating user SSH key (josh+${hostname}@joshsymonds.com)..."
  ssh-keygen -q -t ed25519 -N "" \
    -f "${stash}/id_ed25519" \
    -C "josh+${hostname}@joshsymonds.com"

  local user_age_pubkey
  user_age_pubkey="$(ssh-to-age -i "${stash}/id_ed25519.pub")"
  local user_ssh_pubkey
  user_ssh_pubkey="$(cat "${stash}/id_ed25519.pub")"

  edit_keys_nix "$hostname" "$host_age_pubkey" "$user_age_pubkey"

  rekey_all_secrets

  # Cap-first the hostname for the GitHub key name (gnomon → Gnomon)
  local capitalized
  capitalized="$(printf '%s' "$hostname" | sed 's/^./\U&/')"

  cat <<EOF

═══════════════════════════════════════════════════════════════════════
  ${hostname} keys generated.
═══════════════════════════════════════════════════════════════════════

User SSH public key — paste into GitHub Settings → SSH and GPG keys
(name it "Josh ${capitalized}"):

${user_ssh_pubkey}

Stashed private keys at: ${stash}/

Files modified:
  - secrets/keys.nix    (gnomon entries added)
  - all .age files re-keyed under expanded recipient set

Next:
  1. Review:    git -C ${REPO_ROOT} diff
  2. Paste the SSH key into GitHub
  3. Commit:   git -C ${REPO_ROOT} commit -m "Add ${hostname} host"
  4. Push:     git -C ${REPO_ROOT} push
  5. (TODO)    $0 kit ${hostname} /path/to/usb

EOF
}

verify_github_key() {
  local pubkey_file="$1"
  local pubkey_part
  pubkey_part="$(awk '{print $2}' "$pubkey_file")"
  if [ "${KIT_SKIP_GITHUB_CHECK:-0}" = "1" ]; then
    echo "→ KIT_SKIP_GITHUB_CHECK=1 — skipping GitHub key verification" >&2
    return 0
  fi
  curl -fsS "https://github.com/${GITHUB_USER}.keys" 2>/dev/null \
    | grep -qF "$pubkey_part"
}

write_readme() {
  local file="$1"
  local hostname="$2"
  cat >"$file" <<EOF
# ${hostname} install kit

This USB contains everything needed to install NixOS on ${hostname}.

## Layout

- \`manifest.env\` — sourced by bootstrap.sh; HOSTNAME, FLAKE_REF, build
  timestamp, and HEAD commit hash
- \`bootstrap.sh\` — install-time script (run on the target as root)
- \`nix-config.tar.gz\` — frozen flake snapshot from KIT_HEAD
- \`identity/\` — host SSH keypair, host agekey, user SSH keypair

## Use

On the target machine:

1. Boot the stock NixOS minimal ISO.
2. Plug this USB.
3. Mount it (NixOS minimal usually auto-mounts to \`/run/media/...\`).
4. Run as root:
       sudo /run/media/.../<hostname>-kit/bootstrap.sh
5. Pick the target disk from the menu, type the hostname literally to
   confirm the wipe, set the LUKS passphrase when disko prompts.
6. Wait. nixos-install pulls the closure from binary cache.
7. Reboot, remove the install ISO USB.

## Recovery

The host SSH keys + agekey are private. Don't lose this USB until first
boot succeeds. After install, ${hostname}'s keys live at \`/persist/etc/\`.
EOF
}

build_kit() {
  local hostname="$1"
  local stash="$2"
  local kit_dir="$3"

  echo "→ Building kit at $kit_dir..." >&2

  rm -rf "$kit_dir"
  mkdir -p "$kit_dir/identity"

  # manifest.env
  cat >"$kit_dir/manifest.env" <<EOF
HOSTNAME=$hostname
FLAKE_REF=$FLAKE_REF
KIT_BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
KIT_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)
EOF

  # bootstrap.sh
  cp "$REPO_ROOT/scripts/templates/bootstrap.sh" "$kit_dir/bootstrap.sh"
  chmod 755 "$kit_dir/bootstrap.sh"

  # identity files
  install -m 600 "$stash/ssh_host_ed25519_key"     "$kit_dir/identity/"
  install -m 644 "$stash/ssh_host_ed25519_key.pub" "$kit_dir/identity/"
  install -m 600 "$stash/$hostname.agekey"         "$kit_dir/identity/"
  install -m 600 "$stash/id_ed25519"               "$kit_dir/identity/"
  install -m 644 "$stash/id_ed25519.pub"           "$kit_dir/identity/"

  # nix-config.tar.gz from HEAD's tree (not working tree — clean state only)
  git -C "$REPO_ROOT" archive --format=tar.gz --prefix=nix-config/ HEAD \
    >"$kit_dir/nix-config.tar.gz"

  # README
  write_readme "$kit_dir/README.md" "$hostname"
}

cmd_kit() {
  local hostname="${1:-}"
  local usb_path="${2:-}"
  if [ -z "$hostname" ] || [ -z "$usb_path" ]; then
    echo "ERROR: 'kit' subcommand requires <hostname> <usb-path>." >&2
    usage >&2
    exit 1
  fi

  local stash="${STASH_BASE}/${hostname}"
  local kit_dir="${usb_path}/${hostname}-kit"

  # 1. Stash exists (keys subcommand was run)
  [ -d "$stash" ] || {
    echo "ERROR: no stash at $stash" >&2
    echo "       Run '$0 keys $hostname' first." >&2
    exit 1
  }

  # 2. USB path is a writable directory
  [ -d "$usb_path" ] || { echo "ERROR: $usb_path not a directory" >&2; exit 1; }
  [ -w "$usb_path" ] || { echo "ERROR: $usb_path not writable" >&2; exit 1; }

  require_dependencies
  require_clean_tree

  # 3. Local HEAD pushed
  echo "→ Verifying $GIT_REMOTE/$GIT_BRANCH is in sync with HEAD..."
  git -C "$REPO_ROOT" fetch -q "$GIT_REMOTE" "$GIT_BRANCH" \
    || { echo "ERROR: could not fetch $GIT_REMOTE/$GIT_BRANCH" >&2; exit 1; }
  local head remote
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  remote="$(git -C "$REPO_ROOT" rev-parse "$GIT_REMOTE/$GIT_BRANCH")"
  [ "$head" = "$remote" ] || {
    echo "ERROR: HEAD ($head) != $GIT_REMOTE/$GIT_BRANCH ($remote)" >&2
    echo "       Push your commits before building the kit." >&2
    exit 1
  }

  # 4. GitHub has the user pubkey
  echo "→ Verifying $GITHUB_USER's GitHub SSH keys include the new user pubkey..."
  verify_github_key "$stash/id_ed25519.pub" || {
    echo "ERROR: user pubkey not found on https://github.com/${GITHUB_USER}.keys" >&2
    echo "       Paste it via Settings → SSH and GPG keys → New SSH key." >&2
    echo "       Or set KIT_SKIP_GITHUB_CHECK=1 to skip this check." >&2
    exit 1
  }

  # 5. Build
  build_kit "$hostname" "$stash" "$kit_dir"

  cat <<EOF

═══════════════════════════════════════════════════════════════════════
  USB kit ready at: $kit_dir
═══════════════════════════════════════════════════════════════════════

On the target machine:
  1. Boot the stock NixOS minimal ISO
  2. Plug this USB
  3. sudo $kit_dir/bootstrap.sh
  4. Pick the target disk, type "$hostname" to confirm the wipe
  5. Set the LUKS passphrase when disko prompts
  6. Wait. Reboot when nixos-install completes.
EOF
}

main() {
  case "${1:-}" in
    keys)
      shift
      cmd_keys "$@"
      ;;
    kit)
      shift
      cmd_kit "$@"
      ;;
    -h|--help|help|"")
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown subcommand: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
