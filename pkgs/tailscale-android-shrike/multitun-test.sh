#!/usr/bin/env bash
# multitun-test — run the multiTUN regression test (tailscale-android PR #901)
# against the unpatched and the patched libtailscale/multitun.go.
# Usage: multitun-test.sh <checkout-dir> <unpatched-rev>
#
# The test file is multitun_test.go beside this script. libtailscale only
# compiles for Android, so multitun.go is copied into its own module with
# the checkout's go.mod and go.sum. Exits 0 only when all three hold:
#   run 1  unpatched multitun.go, two devices then Shutdown: fails with
#          "close of closed channel"
#   run 2  patched multitun.go, same test: passes
#   run 3  patched multitun.go, burst of three devices then Shutdown, -race:
#          passes
set -o errexit -o nounset -o pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: multitun-test.sh <checkout-dir> <unpatched-rev>" >&2
  exit 2
fi
checkout=$1
unpatched_rev=$2
test_src="$(dirname "${BASH_SOURCE[0]}")/multitun_test.go"
if [ ! -f "$test_src" ]; then
  echo "multitun-test: missing test file $test_src" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkg="$work/libtailscale"
mkdir "$pkg"
cp "$checkout/go.mod" "$checkout/go.sum" "$work/"
cp "$test_src" "$pkg/multitun_test.go"

unpatched_src="$work/multitun.unpatched.go"
if ! git -C "$checkout" show "$unpatched_rev:libtailscale/multitun.go" > "$unpatched_src"; then
  echo "multitun-test: cannot read libtailscale/multitun.go at $unpatched_rev" >&2
  exit 1
fi
patched_src="$checkout/libtailscale/multitun.go"

# run_case <label> <multitun.go> <expect: panic|pass> <go test args...>
# Prints the run's output and reports whether its expectation held.
run_case() {
  local label=$1 src=$2 expect=$3 out rc
  shift 3
  cp "$src" "$pkg/multitun.go"
  echo "== $label =="
  if out="$(go -C "$work" test -count=1 -timeout 60s "$@" ./libtailscale 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  printf '%s\n' "$out"
  echo "== exit $rc"
  case $expect in
  panic)
    [ "$rc" -ne 0 ] || return 1
    case $out in
    *'close of closed channel'*) return 0 ;;
    esac
    return 1
    ;;
  pass)
    [ "$rc" -eq 0 ]
    ;;
  esac
}

failed=0
if ! run_case "run 1: unpatched, two devices then Shutdown" "$unpatched_src" panic \
  -run '^TestMultiTUNTwoDevicesShutdown$'; then
  echo "multitun-test: run 1 expected a non-zero exit with 'close of closed channel'" >&2
  failed=1
fi
if ! run_case "run 2: patched, two devices then Shutdown" "$patched_src" pass \
  -run '^TestMultiTUNTwoDevicesShutdown$'; then
  echo "multitun-test: run 2 expected a pass on the patched multitun.go" >&2
  failed=1
fi
if ! run_case "run 3: patched, burst of three devices then Shutdown, -race" "$patched_src" pass \
  -race -run '^TestMultiTUNBurstShutdown$'; then
  echo "multitun-test: run 3 expected a pass under -race on the patched multitun.go" >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "multitun-test: FAILED" >&2
  exit 1
fi
echo "multitun-test: all three expectations held"
