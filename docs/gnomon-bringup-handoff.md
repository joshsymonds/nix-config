# Gnomon bring-up handoff (2026-05-07 → 08)

Snapshot of where gnomon is and what's left, written so a fresh session
(or a future Claude after compaction) can pick up without losing context.

## Where gnomon currently is

- ✅ Installed: NixOS, btrfs+LUKS+impermanence on `/dev/nvme0n1`, lanzaboote-signed UKI
- ✅ Booted on gen 3 (`/nix/store/izkji4fya...`) — built fresh from latest `main` via `nixos-rebuild boot --flake .#gnomon`
- ✅ Networking: systemd-networkd active, `enp7s0` static `172.31.0.80/24` via wildcard `en*` match
- ✅ NFS: all four NAS shares mounted (books/music/video/creative); `.80` is in blackbox `/etc/exports` allowlists
- ✅ sshd: running from the proper systemd unit, NixOS-managed `/etc/ssh/authorized_keys.d/joshsymonds`
- ✅ home-manager activated; kitty, firefox, etc. wired up
- ✅ DMS + niri session works (Super+Space for launcher)
- ⚠️ **Secure Boot is OFF** — boots lanzaboote-signed UKI without UEFI signature validation
- ⚠️ **TPM2 LUKS auto-unlock NOT yet enrolled** — types long passphrase every boot
- ⚠️ **Login password is empty** (declarative `hashedPassword = ""` from common.nix; the manual `passwd` we set during debug got reset on reboot)
- ⚠️ Two cosmetic-only orphan files in `/persist` (rsa host keys from a debug-era boot)

## Open work, by priority

### 1. Cosmetic cleanup on gnomon (5 min, do first)

```bash
sudo rm /persist/etc/ssh/ssh_host_rsa_key /persist/etc/ssh/ssh_host_rsa_key.pub
rm ~/.ssh/authorized_keys   # NixOS now manages via /etc/ssh/authorized_keys.d/<user>
```

### 2. Re-enable Secure Boot (15 min)

The first attempt failed because `@root-blank` rollback wiped `/var/lib/sbctl` and we generated fresh keys that didn't match the ones already enrolled in UEFI. Now that the impermanence config persists `/var/lib/sbctl` AND `install.sh` pre-stages keys to `/persist` (commit `a29492e`), it'll be sticky for future hosts. For gnomon's existing install, do this once:

```bash
# In BIOS:
#   - Reset / Clear Secure Boot keys (puts UEFI back in Setup Mode)
#   - Save & exit, boot the system

# After boot:
sudo sbctl enroll-keys --microsoft
sudo sbctl verify  # should show all .efi binaries signed

# Reboot, in BIOS enable Secure Boot, save & exit
# Verify after reboot:
sudo sbctl status   # Setup Mode: ✓ Disabled, Secure Boot: ✓ Enabled
```

If a kernel/UKI fails to validate, drop SB off in BIOS, debug, retry.

### 3. TPM2 LUKS auto-unlock (10 min, AFTER SB is on)

PCR 7 only matters if SB is meaningfully configured, so this comes after step 2.

```bash
# Find LUKS partition UUID
sudo cryptsetup luksDump /dev/nvme0n1p2 | grep UUID

# Enroll TPM2 keyslot (long passphrase keyslot stays as fallback)
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-uuid/<UUID>

# Reboot. Should auto-unlock without prompting.
# If it fails, the long passphrase still works as fallback.
```

### 4. Login password (declarative, 5 min)

Pick a short PIN (this is for session/sudo, not LUKS):

```bash
mkpasswd -m sha-512   # paste your PIN, copy the output hash
```

Add to gnomon-specific config (`hosts/gnomon/default.nix` or a fragment) — NOT `hosts/common.nix` since other hosts have their own auth flow:

```nix
users.users.joshsymonds.hashedPassword = "$6$...hash...";
```

Then `nh os switch ~/nix-config`. From then on: short PIN for login + sudo, long passphrase only for LUKS recovery.

## Outstanding code work (epic Task #1)

The brainstormed-and-mostly-shipped epic ("Single-USB installer with end-to-end VM test", Task #1) has these still open:

### Task #9 — `prepare-host-kit.sh` `kit` → `build` rewrite

The user-facing deliverable: replace the old "copy files to mounted USB" kit subcommand with one that writes a complete bootable USB (build ISO → dd → add INSTALL-KIT partition → populate). The first WIP was stashed and dropped; redo from scratch with the lessons from gnomon's bringup baked in.

Important: include sbctl-key pre-staging in the kit-build flow (or rely on `install.sh`'s now-correct pre-staging — commit `a29492e` does this declaratively in install.sh, so make-install-usb doesn't need to add anything).

### Phase 2 of the installer nixosTest

Currently the test exits after the install completes and asserts on `/mnt`. Phase 2: reboot the VM from the target disk, type LUKS passphrase via the test driver, assert:

- `testhost-marker` SSH key in `authorized_keys` (proves nix evaluation applied)
- `/etc/test-marker` content (proves nixos-install completed)
- `/etc/test-persist-marker` survives a SECOND reboot (proves `/persist` survives `@root-blank` rollback)

### qemu pinned in `devShells.default`

For Tier-4 manual smoke testing of installer USBs without spinning up the full nixosTest. Add `qemu_kvm`, `OVMF`, `swtpm` to `devShells.default` in `flake.nix`.

### Old autoInstaller deletion (epic Req 12)

The legacy auto-installer module is now dead code. Delete:

- `modules/installer.nix`
- `hosts/ultraviolet/installer.nix`
- `hosts/vermissian/installer.nix`
- `ultraviolet-installer` and `vermissian-installer` from `flake.nix`'s `nixosHostDefinitions`
- `ultravioletInstallerIso` and `vermissianInstallerIso` from `packages.x86_64-linux`
- `scripts/templates/bootstrap.sh`
- `scripts/tests/test-bootstrap.bats` (replaced by `test-install-sh.bats`)

Update `.claude/skills/building-installers/SKILL.md` to describe only the new flow.

## Lessons learned (for future hosts)

### `nh os switch` partial-failure trap

When `nh os switch`'s **test** phase fails (any unit fails to start, even non-fatal warnings), `nh` returns exit 4 and `/run/current-system` may or may not be updated. Running `switch-to-configuration boot` afterwards from a stale `/run/current-system` installs the wrong generation as the bootloader default — confusingly labeled "Generation 2" in the menu while actually being an older closure. **Workaround**: use `sudo nixos-rebuild boot --flake .#<host>` (absolute path) directly. It rebuilds from latest, no stale-pointer risk.

### sbctl key persistence (now fixed)

Lanzaboote needs `/var/lib/sbctl/keys/db/db.pem` at install time. On a fresh install with impermanence, that file lives on `@root` which gets rolled back to `@root-blank` on first boot — wiping the keys we just used to sign + enroll to UEFI. Subsequent rebuilds fail; regenerating keys produces signatures UEFI no longer recognizes.

**Fixed in commit `a29492e`** — `install.sh`'s `prepare_bootloader_keys` runs `sbctl create-keys` and copies to BOTH `/mnt/var/lib/sbctl` (for the install's bootloader signing) AND `/mnt/persist/var/lib/sbctl` (so the impermanence bind on first boot finds them).

### NixOS interface naming

Don't hardcode interface names in `lib/network.nix` for new hosts. Use systemd-networkd with `matchConfig.Name = "en*"` like ultraviolet/vermissian do. The `interface = "..."` field for gnomon was a guess that turned out wrong (real NIC was `enp7s0`, guessed `enp4s0`).

### `useNetworkd = true` is required when using `systemd.network.networks.*`

Without it, the legacy scripted-networking path (`network-setup.service`) ALSO runs and conflicts. Caught when `nh os switch` failed with `Failed to start network-setup.service` and resolv.conf signature mismatch.

### NFS allowlists on blackbox

Per-host IP allowlist in `/etc/exports` on the NAS — manual editing via SSH (password in memory at `blackbox_nas.md`). When adding a new host, append its IP to the allowlist for each share it mounts. `exportfs -ra` to reload.

## Recent commits from this session

```
a29492e installer-iso: pre-stage sbctl keys to /persist before nixos-install
f757275 gnomon: enable networking.useNetworkd
6383649 gnomon: stable IP .80, systemd-networkd wildcard interface match
12b67b3 gnomon/disko: fix impermanence — persist sbctl keys, file-bind sshd hostkey
06deab6 caches: add niri.cachix.org
386897d common: exclude shimmer from nix.registry
d4d199f gnomon: drop lutris from home-manager packages
ac918c7 tests: add installer nixosTest (phase 1) — install completes end-to-end
a0d6af0 installer-iso: prefer local disko binary; bundle disko in the ISO
fb5e67d tests: add INSTALL-KIT image fixture for installer VM test
f51e98f installer-iso: add NixOS module + flake wiring for installerIso
471dcc7 installer-iso: port install.sh from bootstrap.sh, with bats coverage
716daf1 hosts: add testhost nixosConfiguration as installer test fixture
b8da078 overlays: move shimmer to privatePackages, applied only to ultraviolet
```

All pushed to `origin/main`.
