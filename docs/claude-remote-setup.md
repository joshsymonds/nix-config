# Claude Code Remote Development Setup with tmux

## Project Goal

Maintain persistent, labeled environments for Claude Code on remote hosts. Each environment is just a tmux session, but we decorate it with a shared "dev context" so prompts, GUI surfaces, and notifications always know which session produced the output. The same approach works for macOS terminals, Linux hosts, and Coder workspaces.

## Core Requirements

### 1. Persistent Development Sessions
- Five named planetary contexts (mercury → jupiter) plus ad-hoc labels via `t`
- Sessions survive SSH disconnects and inherit their context metadata
- Claude Code keeps running when no client is attached
- Notifications include the context name/icon so you know which session finished

### 2. Naming Convention & Mental Model
- `mercury` – quick experiments
- `venus` – personal creative/web work
- `earth` – primary work project
- `mars` – secondary work project
- `jupiter` – large personal project

### 3. Client Access Requirements

**Mac**
- Cmd+number shortcuts mapped to the planetary helpers
- Context-aware prompts and Kitty tab titles
- Seamless attach via SSH or Eternal Terminal

**Mobile (Blink Shell, etc.)**
- Type the planet name to connect
- Context name shows up in status bar titles
- Easy switching with `tmux switch-client`

### 4. Development Environment Structure
- Each tmux session is tagged with `DEV_CONTEXT`, `DEV_CONTEXT_KIND`, and (optionally) `DEV_CONTEXT_ICON`
- `tmux-devspace` guarantees those variables exist before attaching
- Shells outside tmux derive the same metadata from Coder or host fallbacks

### 5. Authentication & Credentials
- AWS SSO sync continues to ride over SSH using the existing helper scripts
- Git/Kube credentials are shared through ssh-agent forwarding and synced dotfiles

### 6. Quality of Life Features
- `devspace-status` / `ds` shows which contexts are alive
- Starship exposes the context + icon on the right side of the prompt
- Kitty window/tab titles reflect the context instead of raw hostnames
- `ntfy` notifications echo the same label/icon

## Implementation Overview

1. **`tmux-devspace` (`home-manager/tmux/scripts/tmux-devspace.sh`)**
   - Wraps `tmux new-session` / `attach`
   - Sets `DEV_CONTEXT`, `DEV_CONTEXT_KIND=tmux`, and any `DEV_CONTEXT_ICON` value supplied via `--icon`
   - Keeps `TMUX_DEVSPACE` around for compatibility

2. **`t` helper (`home-manager/zsh/default.nix`)**
   - Sanitizes labels and spawns contexts on demand
   - Auto-names sessions when called without arguments
   - Never nests tmux; it switches clients if already inside tmux

3. **Planetary aliases (`home-manager/devspaces-host`, `home-manager/devspaces-client`)**
   - Provide `earth`, `mars`, etc. on both the server and macOS clients
   - Hosts call `t <label> <icon>`; macOS uses Eternal Terminal (`et`) to run `tmux-devspace attach --icon …` so icons are captured even from remote launches

4. **Shell integration (`home-manager/zsh/default.nix`)**
   - Imports tmux environment variables when `$TMUX` is present
   - Falls back to `CODER_WORKSPACE_NAME` or `hostname` and sets `DEV_CONTEXT_KIND` accordingly

5. **Prompt + UI (`home-manager/starship/default.nix`, `home-manager/tmux/default.nix`)**
   - Right-aligned context segment with icons (☿♀♁♂♃ or `` for Coder)
   - Kitty/tmux titles read `DEV_CONTEXT` so tabs match prompts

6. **Notifications (`cc-tools notify (see home-manager/claude-code/hooks/README.md)`)**
   - Derives the same metadata and includes it in the push title/body

## Session Flow

1. Run `t` or a planetary alias.
2. `tmux-devspace` creates a detached tmux session (if needed) and sets the context env vars.
3. If you were already in tmux, the helper switches the client; otherwise it execs `tmux attach-session`.
4. Inside the session, shells inherit the exported variables so Starship, Kitty, and hooks all stay in sync.
5. Outside tmux (e.g., a Coder terminal), the shell still computes `DEV_CONTEXT` so prompts remain labeled even without tmux involvement.

## Commands & Shortcuts

```bash
# Generic helper
t                     # Auto-named context
t feature-auth ☾     # Attach/create "feature-auth" with a moon icon
t feature-auth -- cargo watch  # Spawn and run a command without setting an icon

# Planetary helpers
earth                 # Attach to primary work session (runs t earth ♁)
mars status          # Run helper subcommands
ds                    # Quick tmux session summary
dsl                   # Detailed tmux session list
```

Key tmux bindings remain the same (Ctrl-b + planet initial to jump between planetary contexts). Because the context metadata is embedded in the tmux session, Kitty tabs and prompts update immediately when you switch.

## Status & Notifications
- `devspace-status` / `ds` → `tmux list-sessions`
- `dsl` → includes window counts and creation times
- `cc-tools notify (see home-manager/claude-code/hooks/README.md)` → reads `DEV_CONTEXT` and `DEV_CONTEXT_ICON` so phone alerts show "☿ mercury" or " coder-workspace"

## File Map

| Path | Purpose |
| --- | --- |
| `home-manager/tmux/scripts/tmux-devspace.sh` | Core session helper |
| `home-manager/zsh/default.nix` | `t` function + context derivation |
| `home-manager/devspaces-host` | Planetary aliases on the server |
| `home-manager/devspaces-client` | Same aliases for macOS (via ET) |
| `home-manager/starship/default.nix` | Prompt segment showing the context |
| `cc-tools notify (see home-manager/claude-code/hooks/README.md)` | Push notifications with context metadata |

## Troubleshooting

1. **Context missing from prompt**
   - Run `printenv DEV_CONTEXT DEV_CONTEXT_KIND DEV_CONTEXT_ICON`
   - If empty inside tmux, run `tmux show-environment DEV_CONTEXT`
   - Ensure `t`/`tmux-devspace` was used to start the session

2. **Planetary alias not found on macOS**
   - Confirm `home-manager/devspaces-client` is imported for that host
   - Rebuild Home Manager (`home-manager switch ...`)

3. **Notifications lack icon**
   - Ensure the helper passed `t <label> <icon>` or invoked `tmux-devspace attach --icon ...`
   - Make sure the session was launched through `tmux-devspace`

## Extending the System

- Add new helpers by extending the alias list and providing an icon via `t ... <icon>` / `tmux-devspace attach --icon ...`
- If Coder workspaces need custom icons, set `DEV_CONTEXT_ICON` before invoking tools
- Any script can rely on `DEV_CONTEXT` instead of `TMUX_DEVSPACE`; only fall back to the legacy variable for backward compatibility

This slimmer design keeps context metadata centralized while remaining easy to adapt for future hosts or remote platforms.
