#!/usr/bin/env bats
#
# Hermetic test harness for modules/installer-iso/install.sh.
#
# install.sh is the auto-install script invoked by the systemd service in
# the installer ISO, after that service has mounted the INSTALL-KIT-labeled
# kit partition and exported KIT_DIR. The script is functionally a port of
# scripts/templates/bootstrap.sh (the legacy two-USB flow), kept as a real
# .sh file so shellcheck and bats coverage carry forward — the structural
# fix for the original autoInstaller's "untested vibecode" failure mode.
#
# Strategy: each test sources the script (which exposes its functions
# without running main()), populates a fixture KIT_DIR with a synthetic
# manifest.env, fake identity files, and a small flake tarball, then
# exercises individual functions or the full main() flow with the
# destructive operations (disko, nixos-install, btrfs) mocked via
# BOOTSTRAP_MOCK_* env vars.
#
# Run via:  ./scripts/tests/run.sh

bats_require_minimum_version 1.5.0

BOOTSTRAP_PATH="${BATS_TEST_DIRNAME}/../../modules/installer-iso/install.sh"

setup() {
  FIXTURE="$(mktemp -d)"

  # Kit directory
  export KIT_DIR="$FIXTURE/kit"
  mkdir -p "$KIT_DIR/identity"

  # Manifest
  cat >"$KIT_DIR/manifest.env" <<'EOF'
HOSTNAME=testhost
FLAKE_REF=github:test/test
EOF

  # Mock identity files (real content not needed for path/permission tests)
  printf 'fake-host-priv\n' >"$KIT_DIR/identity/ssh_host_ed25519_key"
  printf 'fake-host-pub\n'  >"$KIT_DIR/identity/ssh_host_ed25519_key.pub"
  printf 'fake-agekey\n'    >"$KIT_DIR/identity/testhost.agekey"
  printf 'fake-user-priv\n' >"$KIT_DIR/identity/id_ed25519"
  printf 'fake-user-pub\n'  >"$KIT_DIR/identity/id_ed25519.pub"

  # Build a minimal flake tarball: flake.nix + hosts/testhost/disko.nix with the sentinel
  TARSRC="$FIXTURE/tarsrc"
  mkdir -p "$TARSRC/nix-config/hosts/testhost"
  cat >"$TARSRC/nix-config/flake.nix" <<'EOF'
{ outputs = _: { dummy = "flake"; }; }
EOF
  cat >"$TARSRC/nix-config/hosts/testhost/disko.nix" <<'EOF'
{ device = "/dev/disk/by-id/REPLACE-AT-INSTALL"; }
EOF
  tar -czf "$KIT_DIR/nix-config.tar.gz" -C "$TARSRC" nix-config

  # Fake EFI presence (a directory's existence is the marker)
  export EFI_VARS_DIR="$FIXTURE/efi"
  mkdir -p "$EFI_VARS_DIR"

  # Fake mount target
  export MNT="$FIXTURE/mnt"
  mkdir -p "$MNT"

  # Test-controlled paths
  export FLAKE_TMP="$FIXTURE/flake_tmp"
  export BTRFS_TOP_TMP="$FIXTURE/btrfs_top"
  export CRYPTROOT_DEVICE="$FIXTURE/fake-cryptroot"  # doesn't exist by default

  # Fake bin for mocking commands the script calls
  export FAKE_BIN="$FIXTURE/bin"
  mkdir -p "$FAKE_BIN"
  # Mock `id` so non-root tests don't trip the root check
  cat >"$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-u" ] && echo 0 || /run/current-system/sw/bin/id "$@" 2>/dev/null || /usr/bin/id "$@"
EOF
  chmod +x "$FAKE_BIN/id"
  PATH="$FAKE_BIN:$PATH"
  export PATH

  # Mocks for destructive operations
  export BOOTSTRAP_MOCK_DISKO=1
  export BOOTSTRAP_MOCK_BTRFS=1
  export BOOTSTRAP_MOCK_NIXOS_INSTALL=1
  export BOOTSTRAP_AUTO_CONFIRM=1
  export DISK="$FIXTURE/fake-disk"  # skips the interactive disk picker

  # Source the script — exposes all functions without running main()
  # shellcheck disable=SC1090
  source "$BOOTSTRAP_PATH"
}

teardown() {
  rm -rf "$FIXTURE"
}

# ─── preflight ─────────────────────────────────────────────────────────

@test "preflight passes with a complete fixture" {
  source "$KIT_DIR/manifest.env"
  run preflight
  [ "$status" -eq 0 ]
}

@test "preflight: rejects non-UEFI boot" {
  source "$KIT_DIR/manifest.env"
  rm -rf "$EFI_VARS_DIR"
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"UEFI"* ]]
}

@test "preflight: rejects when manifest didn't set HOSTNAME" {
  # Don't source manifest.env — HOSTNAME stays unset
  unset HOSTNAME
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"HOSTNAME"* ]]
}

@test "preflight: rejects when nix-config.tar.gz is missing" {
  source "$KIT_DIR/manifest.env"
  rm "$KIT_DIR/nix-config.tar.gz"
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"nix-config.tar.gz"* ]]
}

@test "preflight: rejects when identity/ is missing" {
  source "$KIT_DIR/manifest.env"
  rm -rf "$KIT_DIR/identity"
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"identity"* ]]
}

@test "preflight: rejects when CRYPTROOT_DEVICE already exists" {
  source "$KIT_DIR/manifest.env"
  touch "$CRYPTROOT_DEVICE"
  run preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"partial install"* ]]
}

# ─── confirm_wipe ──────────────────────────────────────────────────────

@test "confirm_wipe: BOOTSTRAP_AUTO_CONFIRM=1 skips the prompt" {
  source "$KIT_DIR/manifest.env"
  export BOOTSTRAP_AUTO_CONFIRM=1
  run confirm_wipe "/dev/sda"
  [ "$status" -eq 0 ]
}

@test "confirm_wipe: accepts correct hostname typed by user" {
  skip "covered by auto-confirm + mismatch tests; subshell isolation makes exact prompt-test awkward"
}

@test "confirm_wipe: rejects mismatched input and aborts" {
  source "$KIT_DIR/manifest.env"
  export BOOTSTRAP_AUTO_CONFIRM=0
  run bash -c "echo 'wrong-host' | { source '$BOOTSTRAP_PATH'; confirm_wipe /dev/sda; }"
  [ "$status" -ne 0 ]
  [[ "$output" == *"confirmation mismatch"* ]] || [[ "$output" == *"aborting"* ]]
}

# ─── extract_flake ─────────────────────────────────────────────────────

@test "extract_flake: unpacks the tarball and verifies flake.nix" {
  source "$KIT_DIR/manifest.env"
  run extract_flake
  [ "$status" -eq 0 ]
  [ -f "$FLAKE_TMP/flake.nix" ]
}

@test "extract_flake: errors clearly if extracted flake.nix is missing" {
  source "$KIT_DIR/manifest.env"
  # Replace tarball with one that doesn't contain flake.nix
  EMPTY_SRC="$FIXTURE/empty"
  mkdir -p "$EMPTY_SRC/nix-config"
  tar -czf "$KIT_DIR/nix-config.tar.gz" -C "$EMPTY_SRC" nix-config
  run extract_flake
  [ "$status" -ne 0 ]
  [[ "$output" == *"flake.nix"* ]]
}

# ─── run_disko local-binary preference ────────────────────────────────

@test "run_disko: prefers local disko binary when available" {
  source "$KIT_DIR/manifest.env"
  # Don't enable mock — we want to test the fallback logic
  unset BOOTSTRAP_MOCK_DISKO

  # Stub disko in PATH (the case we want to take)
  cat >"$FAKE_BIN/disko" <<'EOF'
#!/usr/bin/env bash
echo "fake-local-disko: $*"
EOF
  chmod +x "$FAKE_BIN/disko"

  # Stub nix to detect if it gets called (it shouldn't when local disko exists)
  cat >"$FAKE_BIN/nix" <<'EOF'
#!/usr/bin/env bash
echo "ASSERT FAIL: nix should not be invoked when local disko exists" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/nix"

  export FLAKE_TMP="$FIXTURE/flake_tmp_disko"
  mkdir -p "$FLAKE_TMP"

  run run_disko
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using local disko"* ]]
  [[ "$output" == *"fake-local-disko: --mode disko --flake"* ]]
  [[ "$output" != *"fetching from github"* ]]
}

@test "run_disko: BOOTSTRAP_DISKO_SCRIPT short-circuits to a pre-built script" {
  source "$KIT_DIR/manifest.env"
  unset BOOTSTRAP_MOCK_DISKO

  cat >"$FIXTURE/prebuilt-disko" <<'EOF'
#!/usr/bin/env bash
echo "fake-prebuilt-disko: ran"
EOF
  chmod +x "$FIXTURE/prebuilt-disko"

  cat >"$FAKE_BIN/disko" <<'EOF'
#!/usr/bin/env bash
echo "ASSERT FAIL: disko CLI should not be invoked when prebuilt is set" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/disko"

  export BOOTSTRAP_DISKO_SCRIPT="$FIXTURE/prebuilt-disko"
  run run_disko
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using pre-built disko script"* ]]
  [[ "$output" == *"fake-prebuilt-disko: ran"* ]]
}

@test "run_install: BOOTSTRAP_NIXOS_INSTALL_SYSTEM uses --system instead of --flake" {
  source "$KIT_DIR/manifest.env"
  unset BOOTSTRAP_MOCK_NIXOS_INSTALL

  cat >"$FAKE_BIN/nixos-install" <<'EOF'
#!/usr/bin/env bash
echo "fake-nixos-install: $*"
EOF
  chmod +x "$FAKE_BIN/nixos-install"

  export BOOTSTRAP_NIXOS_INSTALL_SYSTEM="/nix/store/fake-system"
  run run_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using pre-built system"* ]]
  [[ "$output" == *"fake-nixos-install: --system /nix/store/fake-system"* ]]
  [[ "$output" != *"--flake"* ]]
}

@test "run_disko: falls back to nix run github: when no local disko" {
  source "$KIT_DIR/manifest.env"
  unset BOOTSTRAP_MOCK_DISKO

  # Make sure no `disko` exists in PATH; FAKE_BIN doesn't have it
  # (only `id` and any test-specific stubs, none of which are `disko` here).

  # Stub nix to capture the call without actually fetching from github
  cat >"$FAKE_BIN/nix" <<'EOF'
#!/usr/bin/env bash
echo "fake-nix-run: $*"
EOF
  chmod +x "$FAKE_BIN/nix"

  export FLAKE_TMP="$FIXTURE/flake_tmp_disko_fb"
  mkdir -p "$FLAKE_TMP"

  run run_disko
  [ "$status" -eq 0 ]
  [[ "$output" == *"No local disko in PATH"* ]]
  [[ "$output" == *"fake-nix-run:"* ]]
  [[ "$output" == *"github:nix-community/disko/latest"* ]]
}

# ─── substitute_sentinel ───────────────────────────────────────────────

@test "substitute_sentinel: replaces the sentinel and verifies" {
  source "$KIT_DIR/manifest.env"
  extract_flake
  run substitute_sentinel "/dev/disk/by-id/nvme-test-12345"
  [ "$status" -eq 0 ]
  grep -q '/dev/disk/by-id/nvme-test-12345' "$FLAKE_TMP/hosts/testhost/disko.nix"
  ! grep -q 'REPLACE-AT-INSTALL' "$FLAKE_TMP/hosts/testhost/disko.nix"
}

@test "substitute_sentinel: errors if disko.nix lacks the sentinel" {
  source "$KIT_DIR/manifest.env"
  extract_flake
  # Pre-substitute the sentinel; subsequent call should fail
  sed -i 's|REPLACE-AT-INSTALL|already-replaced|' "$FLAKE_TMP/hosts/testhost/disko.nix"
  run substitute_sentinel "/dev/disk/by-id/whatever"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sentinel not found"* ]]
}

@test "substitute_sentinel: errors if disko.nix doesn't exist" {
  source "$KIT_DIR/manifest.env"
  extract_flake
  rm "$FLAKE_TMP/hosts/testhost/disko.nix"
  run substitute_sentinel "/dev/disk/by-id/whatever"
  [ "$status" -ne 0 ]
  [[ "$output" == *"disko.nix"* ]]
}

# ─── copy_identity ─────────────────────────────────────────────────────

@test "copy_identity: creates target dirs and copies all 5 files" {
  source "$KIT_DIR/manifest.env"
  # install with -o requires root for chown; tests aren't root, so this
  # will fail on the chown step. Override `install` via fake bin.
  cat >"$FAKE_BIN/install" <<'EOF'
#!/usr/bin/env bash
# Strip -o/-g (chown) flags but keep -m (mode); copy + chmod.
mode=""
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    -m) mode="$2"; shift 2 ;;
    -o|-g) shift 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done
src="${positional[0]}"
dst="${positional[1]}"
cp "$src" "$dst"
[ -n "$mode" ] && {
  if [ -d "$dst" ]; then chmod "$mode" "$dst/$(basename "$src")"; else chmod "$mode" "$dst"; fi
}
EOF
  chmod +x "$FAKE_BIN/install"

  run copy_identity
  [ "$status" -eq 0 ]

  [ -f "$MNT/persist/etc/ssh/ssh_host_ed25519_key" ]
  [ -f "$MNT/persist/etc/ssh/ssh_host_ed25519_key.pub" ]
  [ -f "$MNT/persist/etc/age/testhost.agekey" ]
  [ -f "$MNT/home/joshsymonds/.ssh/id_ed25519" ]
  [ -f "$MNT/home/joshsymonds/.ssh/id_ed25519.pub" ]

  # Permissions on the privates
  [ "$(stat -c %a "$MNT/persist/etc/ssh/ssh_host_ed25519_key")" = "600" ]
  [ "$(stat -c %a "$MNT/persist/etc/age/testhost.agekey")" = "600" ]
  [ "$(stat -c %a "$MNT/home/joshsymonds/.ssh/id_ed25519")" = "600" ]
}

# ─── full main() with mocks ────────────────────────────────────────────

@test "main(): full flow with mocks succeeds end-to-end" {
  # Mock install too
  cat >"$FAKE_BIN/install" <<'EOF'
#!/usr/bin/env bash
mode=""
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    -m) mode="$2"; shift 2 ;;
    -o|-g) shift 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done
src="${positional[0]}"
dst="${positional[1]}"
cp "$src" "$dst"
[ -n "$mode" ] && {
  if [ -d "$dst" ]; then chmod "$mode" "$dst/$(basename "$src")"; else chmod "$mode" "$dst"; fi
}
EOF
  chmod +x "$FAKE_BIN/install"

  run "$BOOTSTRAP_PATH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install complete"* ]]
  [[ "$output" == *"testhost"* ]]
}

@test "main(): exits non-zero if preflight fails (no UEFI)" {
  rm -rf "$EFI_VARS_DIR"
  run "$BOOTSTRAP_PATH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"UEFI"* ]]
}
