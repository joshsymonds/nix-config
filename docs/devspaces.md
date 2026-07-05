# Dev Contexts

This document describes the new dev context abstraction that replaced the older devspace stack. Contexts are just names plus a little metadata, but we treat them as first-class across tmux, shells, prompts, and notifications. Whether you attach from a Mac, run inside Coder, or SSH straight into a server, the same variables (`DEV_CONTEXT`, `DEV_CONTEXT_KIND`, `DEV_CONTEXT_ICON`) follow you.

## Goals
- Provide a single, user-facing label for every long-lived shell
- Make prompts, terminal titles, and notifications agree on that label
- Support both tmux-managed sessions and non-tmux environments (Coder, bare hosts)
- Keep the implementation small enough to reason about and extend quickly

## Components
1. **`tmux-devspace`** (`home-manager/tmux/scripts/tmux-devspace.sh`)
   - Creates or attaches to tmux sessions
   - Sets `DEV_CONTEXT`, `DEV_CONTEXT_KIND=tmux`, and whatever `DEV_CONTEXT_ICON` value callers pass via `--icon`
   - Writes the legacy `TMUX_DEVSPACE` variables for scripts that still expect them
2. **`t` helper** (`home-manager/zsh/default.nix`)
   - Front-end for `tmux-devspace`
   - Sanitizes labels and chooses auto names when none are provided
3. **Planetary aliases** (`home-manager/devspaces-host` and `home-manager/devspaces-client`)
   - Convenience commands (`earth`, `mars`, etc.); hosts call `t <planet> <icon>` while macOS invokes `tmux-devspace attach --icon ...`
   - Work on both the host itself and from macOS via Eternal Terminal/SSH
4. **Shell integration** (`home-manager/zsh/default.nix`)
   - Imports tmux-provided variables when already inside tmux
   - Otherwise derives `DEV_CONTEXT` from `CODER_WORKSPACE_NAME` or falls back to the hostname (`DEV_CONTEXT_KIND=host`)
5. **Prompt + titles** (`home-manager/starship/default.nix`, `home-manager/tmux/default.nix`)
   - Starship adds a right-side context segment with optional icons
   - Tmux titles use the per-session option `@dev_context` so Kitty tabs and other terminals stay in sync
6. **Notifications** (`cc-tools notify (see home-manager/claude-code/hooks/README.md)`)
   - Reads the derived context metadata and embeds it in mobile alerts

## Planetary helpers

| Context | Icon | Description |
| --- | --- | --- |
| `mercury` | ☿ | Quick experiments and prototypes |
| `venus` | ♀ | Personal creative projects |
| `earth` | ♁ | Primary work project |
| `mars` | ♂ | Secondary work project |
| `jupiter` | ♃ | Large personal project |

Each helper calls `t <label> <icon>`, so the icon is stored in `DEV_CONTEXT_ICON` at creation time. To change the glyph, update the alias instead of touching tmux scripts.

## Usage

```bash
# General helper
t                      # Auto-named context (sanitized label based on cwd)
t my-feature 🌙        # Spawn or attach to "my-feature" with a moon icon
t my-feature -- cargo watch  # Run command in a fresh context without an icon

# Planetary helpers
earth                  # Attach/Create earth (calls t earth ♁)
mars status            # Pass subcommands through to tmux-devspace
ds                     # tmux list-sessions summary (alias for devspace-status)
dsl                    # Detailed tmux session listing
```

`tmux-devspace attach [--icon <icon>] <label>` is idempotent: it sets the metadata and switches clients if you are already inside tmux, or execs `tmux attach-session` if you run it from a plain terminal.

## Status commands

Both the host and macOS client modules expose:
- `devspace-status` / `ds` – quick list of active sessions
- `dsl` – full session list with creation times and window counts

## Extending contexts

1. Decide on a new context label (keep it lowercase/kebab-case).
2. If you need a dedicated helper command, add an alias next to the planetary ones in `home-manager/devspaces-host` and `home-manager/devspaces-client`.
3. Decide what icon to show and pass it via `t <label> <icon>` or by adding `--icon` to any `tmux-devspace` invocation (macOS aliases already support this).
4. Optional: teach Starship or other surfaces about the new context if it needs special treatment.

## Compatibility

Scripts that still expect `TMUX_DEVSPACE` will continue to work, but any new tooling should read `DEV_CONTEXT`, `DEV_CONTEXT_KIND`, and `DEV_CONTEXT_ICON`. When tmux is not involved (Coder, bare SSH shell, cron jobs, etc.), only the new variables are guaranteed to exist.
