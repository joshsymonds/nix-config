# nix-config

Flake-based Nix configuration managing multiple systems.

## Systems

| Host | Platform | Description |
|------|----------|-------------|
| gnomon | NixOS (x86_64-linux) | Primary dev machine now, niri + DankMaterialShell, gaming rig |
| ultraviolet | NixOS (x86_64-linux) | Main homelab server |
| bluedesert | NixOS (x86_64-linux) | Z-Wave bridge (zwave-js-ui) |
| vermissian | NixOS (x86_64-linux) | Work/dev server |
| echelon | NixOS (x86_64-linux) | Remote tailnet node |
| stygianlibrary | NixOS (x86_64-linux) | halmasuit test rig, hardware-identical to gnomon |
| ninuan | macOS (aarch64-darwin) | Aerospace WM; rarely powered on now that gnomon is primary |
| testhost | NixOS (x86_64-linux) | VM fixture for the installer test, not a real machine |
| installer | NixOS (x86_64-linux) | Generic installer ISO output, not a deployed host |

## Essential Commands

```bash
update                    # Rebuild current system (real binary, not an alias)
nix flake check          # Validate flake
nix build .#<package>    # Build a package
```

**IMPORTANT**: Run `update` after any Nix config changes. Nothing takes effect until rebuilt.

`update` is a `writeShellScriptBin` on `PATH` (per host: `nh os switch` for NixOS, `nh darwin switch` for macOS, ssh-into-ultraviolet for bluedesert). It works from non-interactive shells, agents, and subprocesses — no need to fall back to invoking `nh` directly. It pre-flights `sudo -n true` and refuses with a clear error if sudo would prompt, so agents fail fast instead of hanging.

**Git gotcha**: Nix flakes only see git-tracked files. Run `git add` before `nix flake check`.

## Directory Structure

```
flake.nix              # Entry point
hosts/                 # System configs (per-machine)
home-manager/          # User configs (apps, dotfiles)
  claude-code/         # Claude Code agents, hooks, settings
pkgs/                  # Custom packages
overlays/              # Nixpkgs modifications
home-assistant/        # HA dashboards and config
```

## Home Assistant

Dashboards use YAML mode - edit files directly, then `update` to deploy.

```bash
hass-cli state list                    # List entities
hass-cli state get <entity_id>         # Get entity state
hass-cli service call <service>        # Call service
```

Token location: `~/.config/home-assistant/token`

## Agenix Secrets

Secrets are encrypted with [agenix](https://github.com/ryantm/agenix). Key files:

- `secrets/keys.nix` — age public keys per host/user
- `secrets/secrets.nix` — maps `.age` files to their recipient keys
- `modules/services/age-identity.nix` — generates `/etc/age/<host>.agekey` from SSH host key

**Critical: agekey vs SSH host key divergence.** `age.identityPaths` points to `/etc/age/<host>.agekey`, which is generated once from the SSH host key and never regenerated. If the SSH host key rotates, the agekey stays — so `ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub` will return a DIFFERENT public key than what's in `keys.nix`. The activation script warns about this drift.

- `keys.nix` must reference the **agekey's** public key (check with `sudo age-keygen -y /etc/age/<host>.agekey`)
- Do NOT use `ssh-to-age -i /etc/ssh/...pub` to determine the key for `keys.nix` — it may be wrong
- `agenix -r` is unsafe when secrets span multiple hosts — it processes in-place with no rollback, and a failure partway through corrupts already-rewritten files. Re-key secrets individually instead.

```bash
# Find the correct public key for keys.nix:
sudo age-keygen -y /etc/age/ultraviolet.agekey

# Re-key a single secret (after updating keys.nix):
agenix -e secrets/hosts/ultraviolet/<name>.age -i <identity>

# Verify a secret decrypts with the host agekey:
sudo age -d -i /etc/age/<host>.agekey secrets/hosts/<host>/<name>.age
```

## Adding Things

**New system**: Create `hosts/<name>/default.nix`, add to `flake.nix`

**New package**: Create `pkgs/<name>/default.nix`, add to `pkgs/default.nix` and overlay
