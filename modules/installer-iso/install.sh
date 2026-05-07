#!/usr/bin/env bash
#
# install.sh — auto-install script for the NixOS installer ISO.
#
# Lives in /nix/store at runtime, invoked by the installer-autorun systemd
# service after that service has located the kit partition (label INSTALL-KIT)
# on the install USB, mounted it, and exported KIT_DIR. Not invoked directly
# by the user.
#
# Reads manifest.env for HOSTNAME and FLAKE_REF. Asks the user to choose the
# target disk from a candidate list. Confirms the destructive WIPE by demanding
# the hostname literally. Substitutes the disko sentinel, runs disko, takes
# the impermanence @root-blank snapshot, copies identity files into /mnt,
# runs nixos-install, powers off.
#
# Functionally a port of scripts/templates/bootstrap.sh (the legacy two-USB
# host-kit flow) into the new single-USB ISO+kit-partition design. Kept as a
# real .sh file (not inline shell in a Nix module) so shellcheck and bats
# coverage carry forward.

set -euo pipefail

# Test-overridable paths so the bats harness can redirect into fixtures.
# Default KIT_DIR is the conventional mount path the installer-autorun
# systemd service uses; the service exports it explicitly when invoking
# this script, so this fallback is mostly for ergonomic local testing.
KIT_DIR="${KIT_DIR:-/run/installer-kit}"
MNT="${MNT:-/mnt}"
EFI_VARS_DIR="${EFI_VARS_DIR:-/sys/firmware/efi}"
FLAKE_TMP="${FLAKE_TMP:-/tmp/nix-config}"
BTRFS_TOP_TMP="${BTRFS_TOP_TMP:-/tmp/btrfs-top}"
CRYPTROOT_DEVICE="${CRYPTROOT_DEVICE:-/dev/mapper/cryptroot}"

# ─── helpers ───────────────────────────────────────────────────────────

log()  { printf '→ %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ─── steps ─────────────────────────────────────────────────────────────

preflight() {
  log "Pre-flight checks..."

  [ "$(id -u)" -eq 0 ] || die "must run as root"
  [ -d "$EFI_VARS_DIR" ] || die "not booted in UEFI mode (lanzaboote requires UEFI)"
  [ -n "${HOSTNAME:-}" ] || die "manifest.env did not set HOSTNAME"
  [ -f "${KIT_DIR}/nix-config.tar.gz" ] || die "kit missing nix-config.tar.gz"
  [ -d "${KIT_DIR}/identity" ] || die "kit missing identity/ directory"

  # Refuse if a previous install left state behind.
  if [ -e "$CRYPTROOT_DEVICE" ]; then
    die "$CRYPTROOT_DEVICE already exists; partial install detected. Clean up before re-running."
  fi
}

# Print a numbered menu of physical, unmounted disks. User picks one.
# In test mode, set DISK env var to skip the prompt.
choose_disk() {
  if [ -n "${DISK:-}" ]; then
    printf '%s\n' "$DISK"
    return 0
  fi

  local candidates=()
  while IFS= read -r line; do
    local name size model
    name="$(awk '{print $1}' <<<"$line")"
    size="$(awk '{print $2}' <<<"$line")"
    model="$(awk '{$1=""; $2=""; print}' <<<"$line" | sed 's/^ *//')"

    # Skip disks that have any mounted partition. Crucially, this excludes
    # the install USB itself (the device whose INSTALL-KIT partition is
    # currently mounted at KIT_DIR).
    if grep -q "^${name}" /proc/mounts; then continue; fi

    candidates+=("${name}|${size}|${model}")
  done < <(lsblk -dnpo NAME,SIZE,MODEL 2>/dev/null)

  if [ "${#candidates[@]}" -eq 0 ]; then
    die "no unmounted physical disks found"
  fi

  printf 'Available target disks:\n' >&2
  local i=1
  for c in "${candidates[@]}"; do
    IFS='|' read -r n s m <<<"$c"
    printf '  %d) %-30s %-10s %s\n' "$i" "$n" "$s" "$m" >&2
    i=$((i+1))
  done

  local choice
  while true; do
    read -r -p "Pick a disk number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ]; then
      IFS='|' read -r n _ _ <<<"${candidates[$((choice-1))]}"
      printf '%s\n' "$n"
      return 0
    fi
    printf 'Invalid selection.\n' >&2
  done
}

# Demand the user type the hostname literally to confirm.
# Bypass with BOOTSTRAP_AUTO_CONFIRM=1 (test mode).
confirm_wipe() {
  local disk="$1"

  if [ "${BOOTSTRAP_AUTO_CONFIRM:-0}" = "1" ]; then
    log "auto-confirm in effect; skipping interactive prompt"
    return 0
  fi

  cat <<EOF >&2

═══════════════════════════════════════════════════════════════════════
  WARNING — DESTRUCTIVE OPERATION

  Hostname: $HOSTNAME
  Target:   $disk

  This will WIPE $disk and install NixOS on it.

  To proceed, type the hostname literally: $HOSTNAME
  Anything else aborts.
═══════════════════════════════════════════════════════════════════════

EOF
  local typed
  read -r -p "> " typed
  if [ "$typed" != "$HOSTNAME" ]; then
    die "confirmation mismatch ('$typed' != '$HOSTNAME'); aborting"
  fi
}

extract_flake() {
  log "Extracting flake to $FLAKE_TMP..."
  rm -rf "$FLAKE_TMP"
  mkdir -p "$FLAKE_TMP"
  # --strip-components=1 puts the tarball's top-level dir contents directly
  # into FLAKE_TMP, so the choice of FLAKE_TMP path is independent of the
  # tarball's internal layout.
  tar -xzf "${KIT_DIR}/nix-config.tar.gz" -C "$FLAKE_TMP" --strip-components=1
  [ -f "$FLAKE_TMP/flake.nix" ] || die "extracted tarball missing flake.nix at $FLAKE_TMP"
}

# Replace the disko sentinel /dev/disk/by-id/REPLACE-AT-INSTALL with the real path.
substitute_sentinel() {
  local disk="$1"
  local disko_file="$FLAKE_TMP/hosts/$HOSTNAME/disko.nix"

  [ -f "$disko_file" ] || die "host disko.nix not found at $disko_file"
  grep -q 'REPLACE-AT-INSTALL' "$disko_file" || die "sentinel not found in $disko_file"

  # Use a delimiter unlikely to appear in disk paths to avoid escaping.
  local esc_disk
  esc_disk="$(printf '%s' "$disk" | sed 's:[\/&]:\\&:g')"
  sed -i "s|/dev/disk/by-id/REPLACE-AT-INSTALL|${esc_disk}|" "$disko_file"

  grep -q "$disk" "$disko_file" || die "post-edit verification failed: $disk not in $disko_file"
}

run_disko() {
  log "Running disko (will prompt for LUKS passphrase)..."
  if [ "${BOOTSTRAP_MOCK_DISKO:-0}" = "1" ]; then
    log "BOOTSTRAP_MOCK_DISKO=1: pretending disko ran"
    return 0
  fi
  # Pre-built script path — used by the nixosTest, which can't evaluate
  # flakes inside its VM (no internet). The fixture pre-builds
  # testhost.config.system.build.diskoScript and points this env var at
  # it; install.sh runs it directly without any flake evaluation.
  if [ -n "${BOOTSTRAP_DISKO_SCRIPT:-}" ]; then
    log "Using pre-built disko script: $BOOTSTRAP_DISKO_SCRIPT"
    "$BOOTSTRAP_DISKO_SCRIPT"
    return 0
  fi
  # Prefer a locally-installed disko binary: faster, works offline, and
  # stays pinned to whatever version the installer ISO bundles. Fall
  # back to `nix run github:` only if no local binary is present — keeps
  # the script usable in a stripped-down environment (e.g., a stock
  # NixOS minimal ISO without the bundle).
  if command -v disko >/dev/null 2>&1; then
    log "Using local disko: $(command -v disko)"
    disko --mode disko --flake "${FLAKE_TMP}#${HOSTNAME}"
  else
    log "No local disko in PATH; fetching from github..."
    nix --experimental-features 'nix-command flakes' run \
      github:nix-community/disko/latest -- \
      --mode disko \
      --flake "${FLAKE_TMP}#${HOSTNAME}"
  fi
}

# Take the @root-blank snapshot for impermanence rollback.
take_root_blank() {
  log "Taking @root-blank snapshot..."
  if [ "${BOOTSTRAP_MOCK_BTRFS:-0}" = "1" ]; then
    log "BOOTSTRAP_MOCK_BTRFS=1: pretending snapshot ran"
    return 0
  fi
  mkdir -p "$BTRFS_TOP_TMP"
  mount -o subvol=/ "$CRYPTROOT_DEVICE" "$BTRFS_TOP_TMP"
  btrfs subvolume snapshot -r "$BTRFS_TOP_TMP/@root" "$BTRFS_TOP_TMP/@root-blank"
  umount "$BTRFS_TOP_TMP"
  rmdir "$BTRFS_TOP_TMP"
}

copy_identity() {
  log "Copying identity files into $MNT..."
  local id_dir="$KIT_DIR/identity"

  mkdir -p \
    "$MNT/persist/etc/ssh" \
    "$MNT/persist/etc/age" \
    "$MNT/home/joshsymonds/.ssh"

  install -m 600 -o 0 -g 0 "$id_dir/ssh_host_ed25519_key"     "$MNT/persist/etc/ssh/"
  install -m 644 -o 0 -g 0 "$id_dir/ssh_host_ed25519_key.pub" "$MNT/persist/etc/ssh/"
  install -m 600 -o 0 -g 0 "$id_dir/${HOSTNAME}.agekey"       "$MNT/persist/etc/age/"

  # User keys: ownership will be fixed by first-boot home-manager activation;
  # set permissions here for safety.
  install -m 600 "$id_dir/id_ed25519"     "$MNT/home/joshsymonds/.ssh/"
  install -m 644 "$id_dir/id_ed25519.pub" "$MNT/home/joshsymonds/.ssh/"
}

run_install() {
  log "Running nixos-install (binary cache will pull the closure)..."
  if [ "${BOOTSTRAP_MOCK_NIXOS_INSTALL:-0}" = "1" ]; then
    log "BOOTSTRAP_MOCK_NIXOS_INSTALL=1: pretending nixos-install ran"
    return 0
  fi
  # Pre-built system path — used by the nixosTest, which can't evaluate
  # flakes inside its VM (no internet). The fixture pre-builds
  # testhost.config.system.build.toplevel and points this env var at it;
  # nixos-install then has the full closure already in the store.
  if [ -n "${BOOTSTRAP_NIXOS_INSTALL_SYSTEM:-}" ]; then
    log "Using pre-built system: $BOOTSTRAP_NIXOS_INSTALL_SYSTEM"
    nixos-install \
      --system "$BOOTSTRAP_NIXOS_INSTALL_SYSTEM" \
      --root "$MNT" \
      --no-root-passwd \
      --no-channel-copy
    return 0
  fi
  nixos-install \
    --flake "${FLAKE_TMP}#${HOSTNAME}" \
    --root "$MNT" \
    --no-root-passwd
}

report_success() {
  cat <<EOF

═══════════════════════════════════════════════════════════════════════
  Install complete: $HOSTNAME on $1
═══════════════════════════════════════════════════════════════════════

Next:
  1. Reboot. Remove the install USB. The host's identity (/persist/etc/ssh
     and /persist/etc/age) is now on the encrypted target disk.
  2. First boot prompts for LUKS passphrase (you set it during disko).
  3. For hosts using lanzaboote: SecureBoot keys auto-enroll on first boot
     via sbctl. If SecureBoot is in setup mode, it switches to user mode.
  4. After login, enroll TPM auto-unlock:
       sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 \\
         /dev/disk/by-uuid/<luks-partition-uuid>
     Then reboot — should be unattended.
  5. Verify recovery: deliberately clear TPM, reboot, confirm passphrase
     fallback works, re-enroll. (Do this once, when calm.)
EOF
}

# ─── main ──────────────────────────────────────────────────────────────

main() {
  # manifest.env contains HOSTNAME, FLAKE_REF, and other kit metadata.
  # Sourced inside main() so the bats harness can `source install.sh`
  # to test individual functions without needing a fixture manifest.
  # shellcheck disable=SC1091
  source "${KIT_DIR}/manifest.env"

  preflight
  local disk
  disk="$(choose_disk)"
  confirm_wipe "$disk"
  extract_flake
  substitute_sentinel "$disk"
  run_disko
  take_root_blank
  copy_identity
  run_install
  report_success "$disk"
}

# Only run main() when executed directly. When `source`d (e.g., by tests),
# functions become available but the workflow doesn't auto-fire.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
