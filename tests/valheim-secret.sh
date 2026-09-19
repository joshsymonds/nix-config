#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ ${VALHEIM_TEST_TOOLS:-} != 1 ]]; then
  exec env VALHEIM_TEST_TOOLS=1 nix shell --inputs-from "$root" nixpkgs#age nixpkgs#ssh-to-age --command bash --noprofile --norc "$root/tests/valheim-secret.sh"
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
age=$(command -v age || true)
[[ -n "$age" ]] || { echo 'age is required' >&2; exit 1; }
identity="$tmp/identity"; ssh-keygen -q -t ed25519 -N '' -f "$identity"
recipient=$(ssh-to-age -i "$identity.pub")
plain="$tmp/plain"; printf '%s\n' 'SyntheticValheimPassword123456' >"$plain"
cipher="$tmp/valid.age"; age -r "$recipient" -o "$cipher" "$plain"
run() { VALHEIM_SSH_IDENTITY="$identity" bash "$root/scripts/check-valheim-secret.sh" "$@"; }
run "$cipher"
for bad in missing corrupt wrong content; do
  case $bad in
    missing) f="$tmp/missing.age" ;;
    corrupt) f="$tmp/corrupt.age"; printf 'not age ciphertext\n' >"$f" ;;
    wrong) other="$tmp/other"; ssh-keygen -q -t ed25519 -N '' -f "$other"; age -r "$(ssh-to-age -i "$other.pub")" -o "$tmp/wrong.age" "$plain"; f="$tmp/wrong.age" ;;
    content) short="$tmp/short"; printf 'bad!\n' >"$short"; age -r "$recipient" -o "$tmp/content.age" "$short"; f="$tmp/content.age" ;;
  esac
  if run "$f" >"$tmp/out" 2>&1; then echo "$bad unexpectedly passed" >&2; exit 1; fi
  ! grep -Fq 'SyntheticValheimPassword' "$tmp/out"
  ! grep -Fq "$identity" "$tmp/out"
done
if VALHEIM_SSH_IDENTITY= bash "$root/scripts/check-valheim-secret.sh" "$cipher" >/dev/null 2>&1; then exit 1; fi
if run "$cipher" extra >/dev/null 2>&1; then exit 1; fi
echo 'valheim secret validator: PASS'
