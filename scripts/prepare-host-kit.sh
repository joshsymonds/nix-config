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
#        Verifies the GitHub paste happened, the keys.nix change is pushed,
#        then writes the bootable kit (identity + flake tarball + bootstrap
#        script) to the USB. (Not yet implemented.)
#
# Run from a trusted machine that has ~/.config/agenix/keys.txt set up.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)"
STASH_BASE="${HOME}/.local/share/host-kits"

usage() {
  cat <<EOF
Usage:
  $0 keys <hostname>            Generate keys, edit keys.nix, re-key secrets
  $0 kit  <hostname> <usb>      Write USB kit (NOT YET IMPLEMENTED)

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
  for cmd in ssh-keygen ssh-to-age agenix sed git find nix-shell; do
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

cmd_kit() {
  echo "ERROR: 'kit' subcommand not yet implemented." >&2
  echo "       Will be added in a follow-up task once scripts/templates/bootstrap.sh exists." >&2
  exit 1
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
