#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $(basename "$0") <version>" >&2
  echo "example: $(basename "$0") 2.1.118" >&2
  exit 1
fi

VERSION="$1"
case "$VERSION" in
  *[[:space:]]*)
    echo "error: invalid Claude Code version: $VERSION" >&2
    exit 1
    ;;
esac
if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?$'; then
  echo "error: invalid Claude Code version: $VERSION" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_FILE="$SCRIPT_DIR/../pkgs/claude-code-cli/default.nix"
TMP_FILE=""

cleanup() {
  if [ -n "$TMP_FILE" ]; then
    rm -f "$TMP_FILE"
  fi
}

die() {
  echo "error: $*" >&2
  exit 1
}

is_sha256_sri() {
  candidate="$1"
  case "$candidate" in
    sha256-*) encoded="${candidate#sha256-}" ;;
    *) return 1 ;;
  esac
  if [ "${#encoded}" -ne 44 ]; then
    return 1
  fi
  base64_body="${encoded%=}"
  if [ "${#base64_body}" -ne 43 ]; then
    return 1
  fi
  case "$base64_body" in
    *[!A-Za-z0-9+/]*) return 1 ;;
    *) return 0 ;;
  esac
}

trap cleanup EXIT

if [ ! -f "$PKG_FILE" ]; then
  die "$PKG_FILE not found"
fi

GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${VERSION}"
MANIFEST_URL="${GCS_BASE}/manifest.json"

SYSTEMS=(
  "aarch64-darwin"
  "x86_64-darwin"
  "x86_64-linux"
  "aarch64-linux"
)
PLATFORMS=(
  "darwin-arm64"
  "darwin-x64"
  "linux-x64"
  "linux-arm64"
)
HASHES=()

echo "fetching checksums for Claude Code ${VERSION}..." >&2
if ! manifest="$(curl -fsSL "$MANIFEST_URL")"; then
  die "failed to download Claude Code manifest for $VERSION"
fi
if ! printf '%s\n' "$manifest" | jq -e '.version | select(type == "string")' >/dev/null; then
  die "invalid Claude Code manifest for $VERSION"
fi
if ! printf '%s\n' "$manifest" | jq -e --arg version "$VERSION" '.version == $version' >/dev/null; then
  die "manifest version does not match requested version"
fi

for index in "${!SYSTEMS[@]}"; do
  platform="${PLATFORMS[$index]}"
  if ! checksum="$(printf '%s\n' "$manifest" | jq -er --arg platform "$platform" '
    .platforms[$platform].checksum
    | select(
        type == "string"
        and length == 64
        and (
          explode
          | all(
              .[];
              (. >= 48 and . <= 57)
              or (. >= 65 and . <= 70)
              or (. >= 97 and . <= 102)
            )
        )
      )
  ')"; then
    die "missing or invalid checksum for $platform"
  fi
  if ! sri_hash="$(nix hash convert --hash-algo sha256 --from base16 --to sri "$checksum")"; then
    die "failed to convert checksum for $platform"
  fi
  if ! is_sha256_sri "$sri_hash"; then
    die "invalid converted checksum for $platform"
  fi
  HASHES[index]="$sri_hash"
done

TMP_FILE="$(mktemp "${PKG_FILE}.tmp.XXXXXX")"
if ! awk \
  -v version="$VERSION" \
  -v system0="${SYSTEMS[0]}" -v hash0="${HASHES[0]}" \
  -v system1="${SYSTEMS[1]}" -v hash1="${HASHES[1]}" \
  -v system2="${SYSTEMS[2]}" -v hash2="${HASHES[2]}" \
  -v system3="${SYSTEMS[3]}" -v hash3="${HASHES[3]}" \
  '
    function replacement_hash(system_name) {
      if (system_name == system0) return hash0
      if (system_name == system1) return hash1
      if (system_name == system2) return hash2
      if (system_name == system3) return hash3
      return ""
    }

    /^[[:space:]]*version = "[^"]+";[[:space:]]*$/ {
      version_count++
      indent = $0
      sub(/[^[:space:]].*$/, "", indent)
      $0 = indent "version = \"" version "\";"
    }

    {
      for (i = 0; i < 4; i++) {
        system_name = (i == 0 ? system0 : i == 1 ? system1 : i == 2 ? system2 : system3)
        if ($0 ~ "^[[:space:]]*\"" system_name "\"[[:space:]]*=[[:space:]]*fetchurl[[:space:]]*\\{[[:space:]]*$") {
          current_system = system_name
          block_counts[system_name]++
        }
      }

      if (current_system != "" && $0 ~ /^[[:space:]]*hash = "sha256-[^"]*";[[:space:]]*$/) {
        hash_counts[current_system]++
        indent = $0
        sub(/[^[:space:]].*$/, "", indent)
        $0 = indent "hash = \"" replacement_hash(current_system) "\";"
      }

      print

      if (current_system != "" && $0 ~ /^[[:space:]]*};[[:space:]]*$/) {
        current_system = ""
      }
    }

    END {
      if (version_count != 1) {
        print "error: expected exactly one version assignment" > "/dev/stderr"
        failed = 1
      }
      for (i = 0; i < 4; i++) {
        system_name = (i == 0 ? system0 : i == 1 ? system1 : i == 2 ? system2 : system3)
        if (block_counts[system_name] != 1) {
          print "error: expected exactly one source block for " system_name > "/dev/stderr"
          failed = 1
        }
        if (hash_counts[system_name] != 1) {
          print "error: expected exactly one hash assignment for " system_name > "/dev/stderr"
          failed = 1
        }
      }
      if (failed) exit 1
    }
  ' "$PKG_FILE" >"$TMP_FILE"; then
  die "failed to rewrite $PKG_FILE"
fi

chmod 0644 "$TMP_FILE"
if cmp -s "$TMP_FILE" "$PKG_FILE"; then
  rm -f "$TMP_FILE"
  TMP_FILE=""
  echo "Claude Code ${VERSION} already up to date" >&2
  exit 0
fi

mv "$TMP_FILE" "$PKG_FILE"
TMP_FILE=""
echo "updated $PKG_FILE to Claude Code ${VERSION}" >&2
