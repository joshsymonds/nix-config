# Claude Code Remote Sessions with orrery

Claude Code runs on vermissian, the work and dev server, inside tmux sessions.
[orrery](https://github.com/joshsymonds/orrery) opens and tracks those sessions.
Its launcher is `p`. From gnomon, ninuan, or shrike, `p` opens the sessions on
vermissian over ssh. On vermissian, `p` runs the launcher locally.

## Opening a session

From gnomon, ninuan, or shrike, `p` runs `orrery open --remote` on vermissian over
ssh, and the arguments pass through unchanged:

| Command | Effect |
| --- | --- |
| `p` | Attach the most recently active session, then open the tree |
| `p .` | The session for the current directory, else the picker. Exits 2 on a remote client: `.` is local only, so run it on vermissian |
| `p WORD` | The session named `WORD`, else the known directory named `WORD` (several: choose one), else the picker |
| `p new NAME` | Create project directory `NAME` and a session for it (`--root DIR` sets the parent) |
| `p WORDS...` | Open the picker with `WORDS` as the intent |

On vermissian, `p` runs `orrery open` locally, so every form above works there,
including `p .`.

## tmux

The orrery tmux plugin is sourced from the home-manager module:

- prefix `Space` opens the orrery tree in a popup.
- prefix `s` opens a shell popup for the current pane's directory.
- The plugin appends its status segment to `status-right`.

tmux titles are `#S:#W` (session name, then window name), so the terminal and
Kitty tab titles name the session and window that produced the output.

## Kitty

`kitty_mod+p` opens a tab that runs `p`. The binding lives in
`home-manager/kitty/default.nix`, not in orrery.

## Prompt

Starship's context chip shows the Coder workspace name inside a Coder
workspace, and the hostname everywhere else.

## Help

`orrery help` prints the cheatsheet. vermissian serves the cheatsheet on the
tailnet only, at https://vermissian.tail82223.ts.net:10003/.

## Notifications

`orreryd` runs on vermissian, gnomon, and ultraviolet. On each `waiting` and
`done` transition of a pane, it routes the notice to the desk stream, to Web
Push, to both, or to neither (orrery `docs/contract.md`, "Notice routing"). With
the desk at hand, the notice goes to the desk stream and reaches the phone only
if it stays unseen for 5 minutes. With the desk away, it goes to both at once.

Each host's desk stream is read by `orrery notices`. On gnomon, the
`orrery-desk` user unit (`home-manager/orrery/desk.nix`) reads gnomon's stream,
and vermissian's and ultraviolet's over ssh, and shows each notice as a desktop
popup. A `waiting` notice is a critical popup. Web Push is relayed through
`ntfy.sh` by default, as named by `--push-host`.
