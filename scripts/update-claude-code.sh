#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $(basename "$0") <version>" >&2
  echo "example: $(basename "$0") 2.1.118" >&2
  exit 1
fi

VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_FILE="$SCRIPT_DIR/../pkgs/claude-code-cli/default.nix"

if [ ! -f "$PKG_FILE" ]; then
  echo "error: $PKG_FILE not found" >&2
  exit 1
fi

GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${VERSION}"

PLATFORMS=(
  "aarch64-darwin:darwin-arm64"
  "x86_64-darwin:darwin-x64"
  "x86_64-linux:linux-x64"
  "aarch64-linux:linux-arm64"
)

declare -A HASHES
for entry in "${PLATFORMS[@]}"; do
  key="${entry%%:*}"
  subpath="${entry##*:}"
  url="${GCS_BASE}/${subpath}/claude"
  echo "fetching ${key}..." >&2
  HASHES[$key]=$(nix store prefetch-file --hash-type sha256 --json "$url" | jq -r .hash)
  echo "  ${HASHES[$key]}" >&2
done

sed -i -E "s|^([[:space:]]*)version = \"[^\"]+\";|\1version = \"${VERSION}\";|" "$PKG_FILE"

for entry in "${PLATFORMS[@]}"; do
  key="${entry%%:*}"
  sed -i "/\"${key}\" = fetchurl/,/};/ s|hash = \"sha256-[^\"]*\";|hash = \"${HASHES[$key]}\";|" "$PKG_FILE"
done

echo "updated ${PKG_FILE} to ${VERSION}" >&2
