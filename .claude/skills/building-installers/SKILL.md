---
name: building-installers
description: Builds NixOS installer ISOs for hosts using the autoInstaller module. Use when creating installer USBs, adding new hosts to the installer system, or troubleshooting installer issues.
---

# Building NixOS Installer ISOs

## Overview

The `modules/installer.nix` module creates bootable USB ISOs that auto-partition, format, and install a NixOS host. Each host has a thin wrapper in `hosts/<name>/installer.nix` setting `autoInstaller.*` options.

## Building an ISO

```bash
nix build .#<host>InstallerIso --print-build-logs
```

**Always use `--print-build-logs`** — the build output contains the baked-in SSH public key:

```
INSTALLER SSH PUBLIC KEY for <host>:
ssh-ed25519 AAAA... <host>-installer
```

If the host's flake has private repo inputs (e.g. `shimmer` uses `git+ssh://`), add this public key as a **deploy key** on those repos before booting the USB.

## Flashing to USB

```bash
sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=direct
sudo eject /dev/sdX
```

## What Happens on Boot

1. NixOS minimal ISO boots, shows ASCII banner on getty
2. Auto-install service starts after `network-online.target`
3. Detects target disk (EFI boot entries > ESP heuristic > partition count > largest disk)
4. **Confirmation prompt** via `systemd-ask-password`: shows disk info, requires typing `yes`
5. Partitions and formats disk with configured labels
6. If LUKS: prompts for passphrase via `systemd-ask-password`
7. Mounts root and boot, creates extra dirs
8. Clones nix-config repo
9. Runs `nixos-install` (prebuilt closure or `--flake` depending on config)
10. Powers off (or reboots if `powerOff = false`)

## Creating an Installer for a New Host

1. **Generate age keypair** for the new host:
   ```bash
   nix-shell -p age --run 'age-keygen'
   ```
   Save the private key securely (e.g. `/tmp/<host>.agekey`). You'll need both the public and private components.

2. **Update `secrets/keys.nix`** — add or replace the host's machine-specific age public key. Each host entry has: machine key, shared SSH-derived key (`age10kwzae...`), and the personal key (`age1yyrhr0...`).

3. **Rekey secrets** so they're encrypted to the new key set:
   ```bash
   nix-shell -p ssh-to-age --run 'ssh-to-age --private-key < ~/.ssh/id_ed25519 > /tmp/rekey.agekey'
   nix run github:ryantm/agenix -- --rekey -i /tmp/rekey.agekey
   ```
   This decrypts all secrets with your SSH-derived age key and re-encrypts them with the updated recipient lists.

4. Create `hosts/<name>/installer.nix` — use `ultraviolet` (non-LUKS, swap) or `stygianlibrary` (LUKS) as templates.

5. Add to `flake.nix` in `nixosHostDefinitions`:
   ```nix
   <name>-installer = {
     system = "x86_64-linux";
     modules = [ ./hosts/<name>/installer.nix ];
   };
   ```
6. Add to `packages.x86_64-linux`:
   ```nix
   <name>InstallerIso = self.nixosConfigurations.<name>-installer.config.system.build.isoImage;
   ```
7. `git add` new files (flakes only see tracked files).
8. **Commit and push** — the target machine will clone this repo during install.
9. Build with `--print-build-logs`, note the SSH public key for private repo deploy keys.
10. **After install, before first boot**: copy the age private key to the installed system:
    ```bash
    ssh <installer-ip> "sudo mkdir -p /mnt/etc/age && sudo chmod 700 /mnt/etc/age"
    scp /tmp/<host>.agekey <installer-ip>:/tmp/<host>.agekey
    ssh <installer-ip> "sudo cp /tmp/<host>.agekey /mnt/etc/age/<host>.agekey && sudo chmod 600 /mnt/etc/age/<host>.agekey"
    ```
    Without this, agenix cannot decrypt secrets and services that depend on secrets will fail.

## Key Module Options (`autoInstaller.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `targetHost` | str | required | nixosConfiguration name to install |
| `prebuilt` | bool | **false** | Embed full closure in ISO (large, offline) vs build from flake on target (small, needs network) |
| `labels.efi` | str | required | EFI partition label |
| `labels.root` | str | required | Root filesystem label |
| `labels.luks` | str | "" | LUKS container partition label |
| `labels.swap` | str | "" | Swap partition label |
| `luks.enable` | bool | false | LUKS encryption |
| `luks.mapperName` | str | "cryptroot" | Device mapper name |
| `swap.enable` | bool | false | Create swap partition |
| `swap.size` | str | "8G" | Swap size (sgdisk format) |
| `extraMountDirs` | [str] | [] | Dirs to create under /mnt |
| `extraPostMountCommands` | [str] | [] | Shell commands after mount |
| `repoClonePath` | str | "/mnt/nix-config" | Where to clone nix-config |
| `powerOff` | bool | true | Power off vs reboot after install |
| `extraInitrdKernelModules` | [str] | [] | Extra initrd modules |
| `extraPackages` | [pkg] | [] | Extra packages in ISO |
| `extraBootCommands` | lines | "" | initrd stage-1 systemd service script |

## Prebuilt vs Non-Prebuilt

- **`prebuilt = false`** (default): ISO is ~1.3GB, builds in seconds. Target machine builds its own system from the flake. Requires network. Good for powerful machines.
- **`prebuilt = true`**: ISO is multi-GB, takes a long time to build (embeds entire system closure). Target installs offline in minutes. Use for machines without reliable network (e.g. stygianlibrary via Thunderbolt).

## Existing Host: Switching to Labels

If a host currently uses UUIDs in `hardware-configuration.nix`, label partitions **before** rebuilding:

```bash
sudo e2label /dev/sdX2 LABEL-ROOT
sudo fatlabel /dev/sdX1 LABEL-EFI
sudo swaplabel -L LABEL-SWAP /dev/sdX3   # if swap exists
```

Then update `hardware-configuration.nix` to use `/dev/disk/by-label/...` and `nixos-rebuild switch`.

## Troubleshooting

- **Disk detection fails**: Set `INSTALL_DISK=/dev/sdX` env var, or check `lsblk -dno NAME,RM,TYPE` — the heuristic only considers `RM=0` `TYPE=disk`
- **SSH key issues for private repos**: The ISO bakes in a key at build time. Add its public component as a deploy key. The service auto-loads it via `ssh-agent`
- **Service doesn't start**: Check `systemctl status <host>-auto-install` and `journalctl -u <host>-auto-install`
- **No cachix during install**: The installer module configures all cachix caches in `nix.settings`. If still building from source, ensure the cache has the derivations pushed
- **Agenix "no readable identities"**: The age private key isn't at `/etc/age/<hostname>.agekey` on the installed system. Copy it before first boot (see step 10 in "Creating an Installer"). On subsequent boots, the activation script in `modules/services/age-identity.nix` will also derive an age key from the SSH host key, but the pre-generated key must be in place for the first boot
