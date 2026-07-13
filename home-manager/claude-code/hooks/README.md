# Coding-agent hooks

Hook scripts deployed verbatim to `~/.claude/hooks/` and `~/.claude-work/hooks/`
by `../default.nix` (`mkClaudeFiles`), wired up in `../settings.json`:

- `aws-profile-mirror.sh` — `PostToolUse`/`Bash` hook.

## Notifications live in cc-tools

The ntfy sender is `cc-tools notify` (https://github.com/joshsymonds/cc-tools,
`internal/notify/`). Claude wires it in `../settings.json` on the `Stop`,
`Notification` (matcher
`permission_prompt|idle_prompt|agent_needs_input|agent_completed`), and
`SessionEnd` events. Codex wires the same binary through the top-level `notify`
key in `home-manager/codex/default.nix`; its `agent-turn-complete` JSON arrives
as one argv value instead of stdin. Both read the
`CC_TOOLS_NTFY_URL_FILE` / `CC_TOOLS_NTFY_TOKEN_FILE` agenix environment and
keep the tag contract gnomon's subscriber (`home-manager/ntfy-notify/`) chimes
on: blocked = priority 5 + `question`, done/info = 4/3 + `white_check_mark`.

For Claude, it adds transcript-derived gates over the deleted `ntfy-notifier.sh`
(silent while a `/goal` is unmet or background tasks are pending; silent in
subagent contexts), a Haiku judge that writes the notification title/body
(`<project> · <task>` instead of window-title guessing), a per-session
detached watchdog that pings on goal completion, hung tasks, and a 4h
parked ceiling, and an append-only decision log of every evaluation at
`~/.local/state/cc-tools/notify-decisions.jsonl` — read that log first when
a ping (or a silence) looks wrong.
