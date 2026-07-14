#!/usr/bin/env bash
set -euo pipefail

LATEST_RELEASE_URL="https://api.github.com/repos/openai/codex/releases/latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/../pkgs/codex/sources.json"
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

normalize_version() {
  candidate="$1"
  case "$candidate" in
    rust-v*) candidate="${candidate#rust-v}" ;;
  esac

  if printf '%s\n' "$candidate" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)(\.[0-9]+)?)?$'; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

trap cleanup EXIT

if [ "$#" -gt 1 ]; then
  die "usage: $(basename "$0") [VERSION]"
fi

requested_version="${1:-latest}"
if [ "$requested_version" = "latest" ]; then
  echo "resolving latest stable release..." >&2
  if ! release_json="$(curl -fsSL "$LATEST_RELEASE_URL")"; then
    die "failed to resolve latest Codex release"
  fi
  if ! printf '%s\n' "$release_json" | jq -e '.draft == false and .prerelease == false' >/dev/null; then
    die "latest release API returned malformed data"
  fi
  if ! release_tag="$(printf '%s\n' "$release_json" | jq -er '.tag_name | select(type == "string" and length > 0)')"; then
    die "latest release API returned malformed data"
  fi
  if ! version="$(normalize_version "$release_tag")"; then
    die "latest release API returned invalid tag: $release_tag"
  fi
else
  if ! version="$(normalize_version "$requested_version")"; then
    die "invalid Codex version: $requested_version"
  fi
fi

SYSTEMS=(
  "x86_64-linux"
  "aarch64-linux"
  "x86_64-darwin"
  "aarch64-darwin"
)
TARGETS=(
  "x86_64-unknown-linux-musl"
  "aarch64-unknown-linux-musl"
  "x86_64-apple-darwin"
  "aarch64-apple-darwin"
)
SRI_HASHES=()

manifest_url="https://github.com/openai/codex/releases/download/rust-v${version}/codex-package_SHA256SUMS"
echo "fetching checksums for Codex ${version}..." >&2
if ! manifest="$(curl -fsSL "$manifest_url")"; then
  die "failed to download checksum manifest for Codex $version"
fi

for index in "${!SYSTEMS[@]}"; do
  target="${TARGETS[$index]}"
  asset="codex-package-${target}.tar.gz"
  matches="$(printf '%s\n' "$manifest" | awk -v asset="$asset" '$2 == asset { print $1 }')"
  match_count="$(printf '%s\n' "$matches" | awk 'NF { count++ } END { print count + 0 }')"

  if [ "$match_count" -eq 0 ]; then
    die "checksum missing for $asset"
  fi
  if [ "$match_count" -ne 1 ]; then
    die "duplicate checksum entries for $asset"
  fi
  if ! printf '%s\n' "$matches" | grep -Eq '^[0-9a-fA-F]{64}$'; then
    die "invalid checksum for $asset"
  fi

  checksum="$(printf '%s\n' "$matches" | tr 'A-F' 'a-f')"
  if ! sri_hash="$(nix hash convert --hash-algo sha256 --to sri "$checksum")"; then
    die "failed to convert checksum for $asset"
  fi
  if ! printf '%s\n' "$sri_hash" | grep -Eq '^sha256-[A-Za-z0-9+/]{43}=$'; then
    die "failed to convert checksum for $asset"
  fi
  SRI_HASHES[index]="$sri_hash"
done

TMP_FILE="$(mktemp "${SOURCES_FILE}.tmp.XXXXXX")"
if ! jq -n -S \
  --arg version "$version" \
  --arg x86_64_linux_target "${TARGETS[0]}" \
  --arg x86_64_linux_hash "${SRI_HASHES[0]}" \
  --arg aarch64_linux_target "${TARGETS[1]}" \
  --arg aarch64_linux_hash "${SRI_HASHES[1]}" \
  --arg x86_64_darwin_target "${TARGETS[2]}" \
  --arg x86_64_darwin_hash "${SRI_HASHES[2]}" \
  --arg aarch64_darwin_target "${TARGETS[3]}" \
  --arg aarch64_darwin_hash "${SRI_HASHES[3]}" \
  '{
    version: $version,
    sources: {
      "x86_64-linux": {target: $x86_64_linux_target, hash: $x86_64_linux_hash},
      "aarch64-linux": {target: $aarch64_linux_target, hash: $aarch64_linux_hash},
      "x86_64-darwin": {target: $x86_64_darwin_target, hash: $x86_64_darwin_hash},
      "aarch64-darwin": {target: $aarch64_darwin_target, hash: $aarch64_darwin_hash}
    }
  }' >"$TMP_FILE"; then
  die "failed to generate sources.json"
fi
if ! chmod 0644 "$TMP_FILE"; then
  die "failed to set permissions on generated sources.json"
fi

if [ -f "$SOURCES_FILE" ] && cmp -s "$TMP_FILE" "$SOURCES_FILE"; then
  rm -f "$TMP_FILE"
  TMP_FILE=""
  echo "Codex ${version} sources already up to date" >&2
  exit 0
fi

mv "$TMP_FILE" "$SOURCES_FILE"
TMP_FILE=""
echo "updated $SOURCES_FILE to Codex ${version}" >&2
