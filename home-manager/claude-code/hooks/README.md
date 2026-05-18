# Claude Code Hooks

Hook scripts deployed verbatim to `~/.claude/hooks/` and `~/.claude-work/hooks/`
by `../default.nix` (`mkClaudeFiles`), wired up in `../settings.json`:

- `ntfy-notifier.sh` — **the** ntfy sender. Runs on the `Stop` and
  `Notification` events; POSTs to the ntfy URL in the `ntfy-url` agenix
  secret. Classifies the event so the phone (priority + emoji) and
  gnomon's ntfy subscriber (`home-manager/ntfy-notify/`) can tell
  "finished" (`white_check_mark`, priority 3) from "Claude is waiting
  on you" (`question`, priority 5). This is the only ntfy path; it is
  NOT in cc-tools.
- `aws-profile-mirror.sh` — `PostToolUse`/`Bash` hook.

## cc-tools

Only the **statusline** lives in cc-tools (https://github.com/joshsymonds/cc-tools),
installed as the `cc-tools-statusline` binary and referenced by
`settings.json`'s `statusLine.command`. cc-tools has a parsed-but-unused
`notifications.ntfy_topic` config field and `docs/claude-notify-go-design.md`
sketches a Go rewrite of the notifier — neither is implemented. Do not
assume cc-tools sends notifications; `ntfy-notifier.sh` does.
