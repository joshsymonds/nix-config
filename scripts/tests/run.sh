#!/usr/bin/env bash
#
# Wrapper for running scripts/tests/*.bats under a nix-shell that has
# the runtime crypto deps available. The user's PATH (and thus agenix)
# is inherited.

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
exec nix-shell -p bats age openssh ssh-to-age \
  --run "bats $(pwd)/test-prepare-host-kit.bats $(pwd)/test-bootstrap.bats $(pwd)/test-install-sh.bats $(pwd)/test-ntfy-notifier.bats"
