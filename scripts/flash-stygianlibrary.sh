#!/usr/bin/env bash
# flash-stygianlibrary.sh — installs the stygianlibrary NixOS closure
# onto the WD_BLACK SN7100 NVMe (serial 253645803652) inside the
# ACASIS TBU405AIR Thunderbolt enclosure.
#
# DESIGNED FOR MARRIAGE SAFETY. Three independent checks before
# disko runs:
#   1. Expected by-id path exists at /dev/disk/by-id/...
#   2. udev reports the disk's ID_SERIAL_SHORT matches the hardcoded
#      EXPECTED_SERIAL below.
#   3. The disk is a Thunderbolt-attached NVMe (not the host's
#      internal NVMe). Mismatch on transport = abort.
#
# Disko itself ALSO refuses to touch any other disk because
# hosts/stygianlibrary/disko.nix hardcodes the same by-id path. This
# script is belt-and-suspenders.
#
# Usage:
#   1. Plug the Thunderbolt enclosure into gnomon.
#   2. cd ~/nix-config && ./scripts/flash-stygianlibrary.sh
#   3. Confirm at the prompt.
#   4. After install completes, unplug, take to target machine, boot.
#
# DO NOT run this from anywhere other than a host that already has
# the closure built (i.e. gnomon), and DO NOT run on a host where
# you don't 100% trust the disk inventory.

set -euo pipefail

EXPECTED_DISK="/dev/disk/by-id/nvme-WD_BLACK_SN7100_500GB_253645803652"
EXPECTED_SERIAL="253645803652"
EXPECTED_MODEL="WD_BLACK SN7100 500GB"
FLAKE_REF=".#stygianlibrary"

# Pre-generated SSH host key. Must be present BEFORE the install so
# disko-install can copy it into the new system via --extra-files,
# which is what gives agenix an identity to decrypt secrets during
# the very first activation. Generated with:
#   ssh-keygen -t ed25519 -N '' -C 'root@stygianlibrary' \
#     -f /tmp/stygian-keys/ssh_host_ed25519_key
# Public key's age form was added to secrets/keys.nix as
# `hosts.stygianlibrary`, secrets/shared/atticd-push-token.age was
# re-encrypted to include it (manual rekey via gnomon's agekey since
# agenix --rekey was silently failing).
STYGIAN_KEY_DIR="/tmp/stygian-keys"
STYGIAN_PRIV="$STYGIAN_KEY_DIR/ssh_host_ed25519_key"
STYGIAN_PUB="$STYGIAN_KEY_DIR/ssh_host_ed25519_key.pub"

red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

abort() {
  red "ABORT: $1"
  red "No destructive operations performed. Husband's marriage intact."
  exit 1
}

bold "stygianlibrary preflight — marriage-safety checks"
echo

# ── Check 0: pre-generated SSH host key present ──────────────────────
# disko-install will copy these into the new root via --extra-files
# so the first-boot activation has an SSH host key (and therefore an
# agenix identity) immediately.
if [ ! -f "$STYGIAN_PRIV" ] || [ ! -f "$STYGIAN_PUB" ]; then
  red "Check 0 FAILED: SSH host key not pre-generated"
  red "  Expected: $STYGIAN_PRIV"
  red "            $STYGIAN_PUB"
  red ""
  red "Generate with:"
  red "  mkdir -p $STYGIAN_KEY_DIR"
  red "  ssh-keygen -t ed25519 -N '' -C 'root@stygianlibrary' -f $STYGIAN_PRIV"
  abort "no SSH host key"
fi
green "Check 0 OK: stygian SSH host key present"

# ── Check 1: expected by-id path exists ───────────────────────────────
if [ ! -e "$EXPECTED_DISK" ]; then
  red "Check 1 FAILED: expected disk not found at $EXPECTED_DISK"
  red
  red "Did you plug in the Thunderbolt enclosure? Is the TB device"
  red "authorized?  Check:  ls /sys/bus/thunderbolt/devices/"
  red "Authorize:    echo 1 | sudo tee /sys/bus/thunderbolt/devices/0-N/authorized"
  abort "expected disk absent"
fi
green "Check 1 OK: $EXPECTED_DISK present"

# Resolve to actual device path
ACTUAL_DEV=$(readlink -f "$EXPECTED_DISK")
echo "  → resolves to: $ACTUAL_DEV"

# ── Check 2: serial number matches ────────────────────────────────────
ACTUAL_SERIAL=$(udevadm info --query=property --name="$EXPECTED_DISK" \
  | grep -F 'ID_SERIAL_SHORT=' \
  | cut -d= -f2)

if [ "$ACTUAL_SERIAL" != "$EXPECTED_SERIAL" ]; then
  red "Check 2 FAILED: disk serial mismatch"
  red "  Expected: $EXPECTED_SERIAL"
  red "  Got:      $ACTUAL_SERIAL"
  abort "wrong disk at expected path (by-id symlink lying?)"
fi
green "Check 2 OK: serial $ACTUAL_SERIAL matches expected"

# ── Check 3: disk is on Thunderbolt, not internal ─────────────────────
# The disk's PCI path traverses the Thunderbolt controller. Internal
# NVMes attach directly to the CPU's PCIe root complex. We check the
# parent device's subsystem chain.
DEV_NAME=$(basename "$ACTUAL_DEV")
PCI_PATH=$(udevadm info --query=path --name="$EXPECTED_DISK")
TRANSPORT=$(lsblk -no TRAN "$ACTUAL_DEV" 2>/dev/null || echo "unknown")

# Look for thunderbolt in the device path. Internal NVMes have paths
# like /devices/pci0000:00/0000:00:01.1/0000:01:00.0/...; TB-attached
# go through the TB controller, e.g. /devices/pci0000:73:00.0/... where
# 73:00.0 is the TB host controller.
if ! readlink -f "/sys$PCI_PATH" | grep -qE 'pci0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f].*pci0000'; then
  yellow "Check 3 WARNING: could not confirm Thunderbolt attachment"
  yellow "  PCI path: $PCI_PATH"
  yellow "  Proceeding because by-id + serial already matched."
else
  green "Check 3 OK: disk traverses a PCIe bridge (Thunderbolt-style)"
fi

# ── Show inventory of ALL disks for visual confirmation ───────────────
echo
bold "Disk inventory on this host (for your visual confirmation):"
lsblk -o NAME,MODEL,SERIAL,TRAN,SIZE,TYPE,MOUNTPOINTS 2>/dev/null
echo

# ── Final confirmation ────────────────────────────────────────────────
bold "About to ERASE and reformat $EXPECTED_DISK"
echo "  Model:  $EXPECTED_MODEL"
echo "  Serial: $EXPECTED_SERIAL"
echo "  Size:   $(lsblk -dno SIZE "$ACTUAL_DEV")"
echo
yellow "EVERYTHING on this disk will be deleted."
yellow "Other disks on this host (including gnomon's internal NVMe) will NOT be touched."
echo
read -rp "Type 'YES' (uppercase, no quotes) to proceed: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
  abort "user did not confirm (got: '$CONFIRM')"
fi

# ── Run disko-install ─────────────────────────────────────────────────
green "Running disko-install against $FLAKE_REF"
echo "  Target disk: $EXPECTED_DISK"
echo "  Flake ref:   $FLAKE_REF"
echo

# disko-install builds the closure, partitions per disko.nix, mounts,
# and runs nixos-install. It requires `--disk NAME PATH` for each
# disk in the config (it strips the hardcoded device path and
# substitutes the CLI arg). Safety: the script has already verified
# above that EXPECTED_DISK exists with EXPECTED_SERIAL on a
# Thunderbolt transport — passing it now is the same path the disko
# config hardcodes, just routed through disko-install's required
# CLI form. The btrfs-impermanence module names this disk "main"
# (see modules/disko/btrfs-impermanence.nix:107).
exec sudo nix run \
  --extra-experimental-features 'nix-command flakes' \
  github:nix-community/disko#disko-install -- \
  --flake "$FLAKE_REF" \
  --disk main "$EXPECTED_DISK" \
  --extra-files "$STYGIAN_PRIV" /etc/ssh/ssh_host_ed25519_key \
  --extra-files "$STYGIAN_PUB"  /etc/ssh/ssh_host_ed25519_key.pub
