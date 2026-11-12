# Coding-agent hooks

Hook scripts deployed verbatim to `~/.claude/hooks/`
by `../default.nix` (`mkClaudeFiles`), wired up in `../settings.json`:

- `aws-profile-mirror.sh` — `PostToolUse`/`Bash` hook.

## Notifications live in orrery

Claude wires `orrery hook` on its eight events in `../settings.json`:
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`,
`PermissionRequest`, `Notification`, `Stop`, and `SessionEnd`. The existing
`usage-summary-refresh.sh` Stop hook runs beside them. Pi integrates
separately at the root TUI `agent_settled` event; there is no Codex
integration.

`orreryd` (on vermissian, gnomon, and ultraviolet) routes each pane notice from
`orrery hook` events, a transition to `waiting` or `done`, to the desk stream,
to Web Push, to both, or to neither (orrery `docs/contract.md`, "Notice
routing"). Each host's desk stream is read by `orrery notices`. gnomon's
`orrery-desk` user unit (`home-manager/orrery/desk.nix`) reads gnomon's stream
and those of vermissian and ultraviolet over ssh, and shows each notice as a
desktop popup with the tick. A `waiting` notice is a critical popup. Web Push
reaches the phone through the relay named by `--push-host`, `ntfy.sh` by default.
