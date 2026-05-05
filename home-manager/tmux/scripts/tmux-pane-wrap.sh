#!/bin/sh
# Wrap each tmux pane shell in a transient systemd scope that auto-reaps all
# descendants on pane close. The inner sh's EXIT trap fires when zsh exits,
# stopping its own scope; KillMode=mixed then SIGKILLs every other process in
# the cgroup (including SIGHUP/SIGTERM-ignorers like wrangler+esbuild).

PANE_ID=$(printf '%s' "$TMUX_PANE" | tr -d '%')
UNIT="tmux-pane-${PANE_ID}.scope"

exec systemd-run --user --scope --quiet --collect \
    --slice=tmux-pane.slice \
    --unit="tmux-pane-${PANE_ID}" \
    --property=KillMode=mixed \
    --property=TimeoutStopSec=5 \
    --property=SendSIGHUP=true \
    -- /bin/sh -c "
trap 'systemctl --user stop --no-block \"$UNIT\" >/dev/null 2>&1 || true' EXIT
@DEFAULT_SHELL@ -l
"
