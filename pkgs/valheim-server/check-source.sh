#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ "$1" != "--fetch-twice" ]; then
  echo "usage: valheim-source-check --fetch-twice" >&2
  exit 2
fi
: "${DEPOT_DOWNLOADER:?DEPOT_DOWNLOADER is required}"
: "${FETCH_DEPOT:?FETCH_DEPOT is required}"
: "${SOURCE_LOCK:?SOURCE_LOCK is required}"

fetch_pass() (
  root=$(mktemp -d)
  trap 'rm -rf "$root"' EXIT HUP INT TERM
  export HOME="$root/home"
  mkdir -p "$HOME"

  for source in server runtime; do
    app=$(jq -r ".${source}.app" "$SOURCE_LOCK")
    depot=$(jq -r ".${source}.depot" "$SOURCE_LOCK")
    manifest=$(jq -r ".${source}.manifest" "$SOURCE_LOCK")
    expected=$(jq -r ".${source}.narHash" "$SOURCE_LOCK")
    destination="$root/$source"

    "$FETCH_DEPOT" "$app" "$depot" "$manifest" "$destination"
    actual=$(nix hash path "$destination")
    if [ "$actual" != "$expected" ]; then
      echo "$source hash mismatch: expected $expected, got $actual" >&2
      exit 1
    fi
  done
)

fetch_pass
fetch_pass
printf '%s\n' "validated both pinned Valheim depots from two independent fresh fetches"
