# Dev Contexts

Long-lived shells run in tmux sessions managed by orrery v0.2.1. You start or attach a session with the `p` launcher, move around with the tmux bindings, and get ntfy notifications from Claude Code hook events through orreryd.

## Components
1. **orrery** (installed by `programs.orrery` from orrery v0.2.1's home-manager module)
   - `orrery open` attaches or starts a project session
   - `orrery tree` shows the orrery tree of panes
   - `orrery help` prints the cheatsheet
   - `orrery hook` is the Claude Code hook command
2. **orreryd** (vermissian, gnomon, ultraviolet)
   - Posts ntfy notifications from `orrery hook` events
   - Reads the ntfy secrets from agenix by path at runtime
3. **`p` launcher**
   - On vermissian it runs `orrery open`
   - On gnomon, ninuan and shrike it runs `orrery open --remote` on vermissian over ssh
4. **tmux plugin** (`orrery tmux-conf`)
   - Binds prefix `Space` to the orrery tree and prefix `s` to a shell for the current pane's directory
   - Appends orrery's status segment to the status line
   - Window titles are `#S:#W` (session:window)
5. **Kitty binding**
   - `kitty_mod+p` opens a tab running `p`
6. **Starship context chip**
   - Shows the Coder workspace name on Coder
   - Shows the hostname everywhere else

## Launching sessions

On vermissian, `p` takes these forms:

```
p                 attach the most recently active session, then open the tree
p .               the session for the current directory, else the picker
p WORD            a session named WORD, else the known directory named WORD (several: choose one), else the picker
p new NAME        create project directory NAME and a session for it
p WORDS...        open the picker with WORDS as the intent
```

On gnomon, ninuan and shrike, `p` runs `orrery open --remote` on vermissian over ssh.

## Help

`orrery help` prints the cheatsheet. vermissian serves it on the tailnet only, at https://vermissian.tail82223.ts.net:10003/.
