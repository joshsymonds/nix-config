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

`orreryd` (on vermissian, gnomon, and ultraviolet) posts ntfy notifications
from `orrery hook` events. ntfy is enabled only when `ORRERY_NTFY_URL_FILE` is
set. `orreryd` reads the topic URL from that file and the access token from
the file named by `ORRERY_NTFY_TOKEN_FILE`. Both are agenix secret paths read
at runtime, so no topic or token lives in the tree. The subscriber contract in
`home-manager/ntfy-notify/` remains: blocked = priority 5 + `question`, while
done/info = priority 4/3 + `white_check_mark`.
