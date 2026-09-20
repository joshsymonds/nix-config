#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo 'usage: check-valheim-secret.sh CIPHERTEXT' >&2
  exit 2
fi
if [[ -z ${VALHEIM_SSH_IDENTITY:-} ]]; then
  echo 'valheim secret check failed: VALHEIM_SSH_IDENTITY is required' >&2
  exit 2
fi
ciphertext=$1
if [[ ! -f $ciphertext ]]; then
  echo 'valheim secret check failed: ciphertext is not readable' >&2
  exit 1
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${VALHEIM_PINNED_TOOLS:-} != 1 ]]; then
  exec env VALHEIM_PINNED_TOOLS=1 nix shell --inputs-from "$repo" nixpkgs#age nixpkgs#ssh-to-age --command bash --noprofile --norc "$0" "$ciphertext"
fi
identity=$(mktemp)
plain=$(mktemp)
trap 'rm -f "$identity" "$plain"' EXIT
if ! ssh-to-age -private-key -i "$VALHEIM_SSH_IDENTITY" -o "$identity" >/dev/null 2>&1; then
  echo 'valheim secret check failed: SSH identity could not be converted' >&2
  exit 1
fi
if ! age --decrypt -i "$identity" -o "$plain" "$ciphertext" >/dev/null 2>&1; then
  echo 'valheim secret check failed: ciphertext could not be decrypted' >&2
  exit 1
fi
if ! [[ $(cat "$plain") =~ ^[[:alnum:]]{24,}$ ]]; then
  echo 'valheim secret check failed: decrypted content is invalid' >&2
  exit 1
fi
echo 'valheim secret check passed'
