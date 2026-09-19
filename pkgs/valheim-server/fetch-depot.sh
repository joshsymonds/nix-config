#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: fetch-depot APP DEPOT MANIFEST OUT" >&2
  exit 2
fi
: "${DEPOT_DOWNLOADER:?DEPOT_DOWNLOADER must name the packaged DepotDownloader}"

app=$1
depot=$2
manifest=$3
out=$4
mkdir -p "$out"

exec "$DEPOT_DOWNLOADER" \
  -app "$app" \
  -depot "$depot" \
  -manifest "$manifest" \
  -dir "$out" \
  -validate
