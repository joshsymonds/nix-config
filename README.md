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

Long-lived shells run in tmux sessions managed by orrery. The `p` launcher attaches a session for a project directory, the tmux plugin adds the orrery tree and a shell popup, and orreryd routes Claude Code `waiting` and `done` notices to the desk stream and to Web Push. The full workflow is in [docs/devspaces.md](docs/devspaces.md).

### Launching sessions
`p` is orrery's launcher. On vermissian it runs `orrery open`, and these forms work there:

```
p                 attach the most recently active session, then open the tree
p .               the session for the current directory, else the picker
p WORD            a session named WORD, else the known directory named WORD (several: choose one), else the picker
p new NAME        create project directory NAME and a session for it
p WORDS...        open the picker with WORDS as the intent
```

On gnomon, ninuan and shrike, `p` runs `orrery open --remote` on vermissian over ssh. Kitty's `kitty_mod+p` opens a tab running `p`.

### tmux
- prefix `Space` opens the orrery tree.
- prefix `s` opens a shell for the current pane's directory.
- The plugin appends orrery's status segment to the status line.
- Window titles are `#S:#W` (session:window).

### Shell prompt
Starship's context chip shows the Coder workspace name on Coder and the hostname everywhere else.

### Help
`orrery help` prints the cheatsheet. vermissian serves it on the tailnet only, at https://vermissian.tail82223.ts.net:10003/.

### Notifications
orreryd runs on vermissian, gnomon and ultraviolet. It routes each pane notice from `orrery hook` events to the desk stream, to Web Push, to both, or to neither. gnomon's `orrery-desk` unit reads the desk streams of gnomon, vermissian and ultraviolet (the last two over ssh, via `orrery notices`) and shows each notice as a desktop popup. Web Push reaches the phone through the `ntfy.sh` relay.

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
