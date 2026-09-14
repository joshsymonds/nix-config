#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
sdk=${PI_TEST_SDK:-/nix/store/sqk34zjszpyryapzfdq02yawdvycl767-steward-pi-runtime-584ae32/lib/steward/node_modules/@earendil-works/pi-coding-agent}
base=${PI_TEST_WORKFLOW_TOOLS:-/nix/store/21yj6507chrmhnqffpcajra80llvy3bw-pi-workflow-tools-1.0.0}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$base"/. "$work"/
chmod -R u+w "$work"
if [[ ${1:-} != --unpatched ]]; then
  patch -d "$work/node_modules/@aliou/pi-processes" -p1 < "$here/process-keepalive.patch"
  cp "$here/process-keepalive.ts" "$work/node_modules/@aliou/pi-processes/extensions/processes/hooks/keepalive.ts"
  cp -r "$here/orchestrator-processes" "$work/"
fi
if [[ ${1:-} == --typecheck ]]; then
  # SDK peers are provided by Pi's loader in production. Make them visible to
  # the standalone compiler only in this disposable copy, not in the package.
  ln -s "$sdk/.." "$work/node_modules/@earendil-works"
  ln -s "$sdk/node_modules/@types" "$work/node_modules/@types"
  ln -s "$sdk/node_modules/typebox" "$work/node_modules/typebox"
  cd "$work"
  timeout 30s tsc --noEmit --skipLibCheck --strict --target es2022 --module esnext \
    --moduleResolution bundler --allowImportingTsExtensions --types node orchestrator-processes/index.ts
  exit
fi
# Bound failures, including deadlocks, rather than leaving test processes alive.
timeout --signal=TERM --kill-after=3s 45s node "$here/tests/process-keepalive.mjs" "$sdk" "$work" "$base"
