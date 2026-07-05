# Claude Code Hooks

Hook scripts deployed verbatim to `~/.claude/hooks/` and `~/.claude-work/hooks/`
by `../default.nix` (`mkClaudeFiles`), wired up in `../settings.json`:

- `aws-profile-mirror.sh` — `PostToolUse`/`Bash` hook.

## Notifications live in cc-tools

The ntfy sender is `cc-tools notify` (https://github.com/joshsymonds/cc-tools,
`internal/notify/`), wired in `../settings.json` on the `Stop`, `Notification`
(matcher `permission_prompt|idle_prompt|agent_needs_input|agent_completed`),
and `SessionEnd` events. It reads the same `CLAUDE_HOOKS_NTFY_URL_FILE` /
`CLAUDE_HOOKS_NTFY_TOKEN_FILE` agenix env wiring as the old bash hook did,
and keeps the tag contract gnomon's subscriber (`home-manager/ntfy-notify/`)
chimes on: blocked = priority 5 + `question`, done/info = 4/3 +
`white_check_mark`.

What it adds over the deleted `ntfy-notifier.sh`: transcript-derived gates
(silent while a `/goal` is unmet or background tasks are pending; silent in
subagent contexts), a Haiku judge that writes the notification title/body
(`<project> · <task>` instead of window-title guessing), a per-session
detached watchdog that pings on goal completion, hung tasks, and a 4h
parked ceiling, and an append-only decision log of every evaluation at
`~/.local/state/cc-tools/notify-decisions.jsonl` — read that log first when
a ping (or a silence) looks wrong.
