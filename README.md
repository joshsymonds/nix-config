# Josh Symonds' Nix Configuration

This repository contains my personal Nix configuration for managing my desktop, servers, and (occasionally) a Mac, using a declarative, reproducible approach with Nix flakes.

## Overview

This configuration manages 9 hosts:

| Host | Platform | Role |
|------|----------|------|
| gnomon | NixOS (x86_64-linux) | Primary desktop — niri + DankMaterialShell, gaming rig |
| ultraviolet | NixOS (x86_64-linux) | Main homelab server |
| bluedesert | NixOS (x86_64-linux) | Z-Wave bridge (zwave-js-ui) |
| vermissian | NixOS (x86_64-linux) | Work/dev server |
| echelon | NixOS (x86_64-linux) | Remote tailnet node |
| stygianlibrary | NixOS (x86_64-linux) | halmasuit test rig (portable, hardware-identical to gnomon) |
| ninuan | macOS (aarch64-darwin) | Rarely powered on now that gnomon is the primary desktop |
| testhost | NixOS (x86_64-linux) | VM fixture for the installer test, not a real machine |
| installer | NixOS (x86_64-linux) | Generic installer ISO output, not a deployed host |

## Features

- **Unified Configuration**: Single repository managing both macOS and Linux systems
- **Modular Design**: Separated system-level and user-level configurations
- **Consistent Theming**: Catppuccin Mocha theme across all applications
- **Custom Packages**: Currently includes a customized Caddy web server
- **Development Environment**: Neovim, Git, Starship prompt, and modern CLI tools
- **Simplified Architecture**: Streamlined flake structure with minimal abstraction
- **Devspace Development Environment**: Persistent tmux-based remote development sessions
- **Remote Link Opening**: Seamless browser integration for SSH sessions

## Quick Start

### Rebuild System Configuration

On the target machine, run `update` — a `writeShellScriptBin` on `PATH` that dispatches to `nh os switch`/`nh darwin switch` (or SSHes into bluedesert, which has no local Nix). It pre-flights `sudo -n true` and refuses to hang waiting on a password prompt, so it's safe to run from scripts and agents:

```bash
update
```

Or invoke the underlying rebuild directly:

```bash
# macOS
darwin-rebuild switch --flake ".#$(hostname -s)" --option warn-dirty false

# Linux
sudo nixos-rebuild switch --flake ".#$(hostname)" --option warn-dirty false
```

### Validate Before Rebuilding

```bash
git add .        # flakes only see git-tracked files
nix flake check
```

### Update Flake Inputs

```bash
nix flake update
```

### Build Custom Packages

```bash
nix build .#myCaddy  # Custom Caddy web server
```

## Structure

- `flake.nix` - Main entry point and flake configuration
- `hosts/` - System-level configurations for each machine
  - `common.nix` - Shared configuration for Linux servers (NFS mounts)
- `home-manager/` - User-level dotfiles and application configs
  - `common.nix` - Shared configuration across all systems
  - `aarch64-darwin.nix` - macOS-specific user configuration
  - `headless-x86_64-linux.nix` - Linux server user configuration
  - Individual app modules (neovim, zsh, kitty, etc.)
- `pkgs/` - Custom package definitions
- `overlays/` - Nixpkgs modifications
- `secrets/` - Public keys

## Key Applications

### Development
- **Editor**: Neovim with custom configuration
- **Terminal**: Kitty with Catppuccin theme
- **Shell**: Zsh with syntax highlighting and autosuggestions
- **Version Control**: Git
- **AI Assistance**: Claude Code (automatically installed via npm)

### macOS Desktop
- **Window Manager**: Aerospace
- **Package Management**: Homebrew (declaratively managed)

### Server Applications
- **Kubernetes**: k9s for cluster management
- **File Sharing**: NFS mounts to NAS
- **Web Server**: Custom Caddy build

## Notable Changes from Standard Nix Configs

1. **Simplified Flake Structure**: Removed unnecessary helper functions and abstractions
2. **Unified Nixpkgs**: Using nixpkgs-unstable as primary source
3. **Single Overlay**: Consolidated all overlays into one default overlay
4. **Minimal Special Args**: Only passing essential inputs and outputs
5. **Direct Home Manager Integration**: Home Manager configured directly in flake.nix

## Customization

To add a new system:
1. Create a configuration in `hosts/<hostname>/`
2. Add to `flake.nix` under appropriate section (nixosConfigurations or darwinConfigurations)
3. Add hostname to the appropriate list in homeConfigurations

To add a new package:
1. Create package in `pkgs/<name>/default.nix`
2. Add to `pkgs/default.nix`
3. Add to overlay in `overlays/default.nix` if needed globally

## Dev Contexts

The dev context system unifies the metadata that describes where a shell is running. Every session exports `DEV_CONTEXT`, `DEV_CONTEXT_KIND`, and an optional `DEV_CONTEXT_ICON`, and all UI surfaces read from those variables. Starship prompts, Kitty tab titles, tmux status lines, and mobile notifications now stay in sync regardless of whether the context came from tmux, Coder, or a plain host shell.

### How contexts are created
- `tmux-devspace` wraps `tmux new-session`/`attach` and immediately sets `DEV_CONTEXT`, `DEV_CONTEXT_KIND=tmux`, plus whatever `DEV_CONTEXT_ICON` value the caller provides via `--icon`. Legacy `TMUX_DEVSPACE` variables still exist for older scripts but should be treated as compatibility shims.
- `t` (defined in `home-manager/zsh/default.nix`) is the main entry point. Running `t` with no arguments creates an auto-named context. `t feature-login ☾` sanitizes the label, records the icon, and spawns/attaches to `feature-login`. Use `t feature-login -- cargo watch` to skip the icon while forwarding a command after `--`.
- Planetary aliases (`mercury`, `venus`, `earth`, `mars`, `jupiter`) remain for muscle memory on both the servers and macOS clients. Each alias now calls `t <planet> <icon>` (or `tmux-devspace attach --icon ...` on macOS), so the icon travels with the context from the moment it is created.
- On Coder, `CODER_WORKSPACE_NAME` seeds `DEV_CONTEXT` with `DEV_CONTEXT_KIND=coder`, so prompts stay labeled even when tmux is not involved.

### Quick commands
```
t                          # Create/switch to an auto-named context
t feature-login ☾          # Spawn or attach to feature-login with a moon icon
t feature-login -- cargo watch  # Run a command without setting an icon
earth                      # Attach to the earth planetary context (via t earth ♁)
mars status                # Invoke helper subcommands inside that context
devspace-status            # List sessions on the current host (alias: ds)
dsl                        # Detailed tmux session listing
```

### Shell and prompt integration
- During shell init we import tmux-provided context variables (when inside tmux), fall back to `CODER_WORKSPACE_NAME`, and finally to the system hostname (`DEV_CONTEXT_KIND=host`).
- Starship replaced the older devspace segment with a context-aware block that shows the icon and `DEV_CONTEXT`. Coder contexts default to ``, tmux planetary contexts get their astronomical glyphs (`☿♀♁♂♃`), and non-planetary sessions display as `● <label>`.
- Tmux titles now use the per-session option `@dev_context` so Kitty tabs, native terminal windows, and the macOS tab bar all render the same label.
- The Codex `ntfy` notifier includes the context string (and icon when present), so phone alerts point to the exact session that completed.

### Why contexts?
- Consistent naming flows through tmux, prompts, tab titles, and notification hooks.
- No reliance on tmux-only variables; any tool can opt-in by exporting `DEV_CONTEXT` and friends.
- Icons become optional metadata that travels with the session, enabling richer UI hints without heuristics.

Compatibility aliases and historical docs still reference “devspaces”, but new code and copy should prefer the “dev context” terminology.

## Remote Link Opening

When SSH'd into a server, links can be opened on your local Mac browser automatically. This is especially useful for AWS SSO authentication.

### How it Works
1. The server sets `BROWSER=remote-link-open`
2. When applications try to open URLs, they display as clickable links in Kitty
3. Click the link in your terminal to open it in your Mac browser

### Example
```bash
# On the server
aws sso login     # Will display a clickable authentication URL
remote-link-open https://example.com  # Manually open a URL
```

## Testing Changes

See [CLAUDE.md](./CLAUDE.md) for detailed testing procedures. Quick summary:

```bash
# Validate configuration
nix flake check

# Preview changes
darwin-rebuild switch --flake ".#$(hostname -s)" --option warn-dirty false --dry-run

# Build specific components
nix build .#homeConfigurations."joshsymonds@$(hostname -s)".activationPackage
```
