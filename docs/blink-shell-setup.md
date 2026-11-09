# Blink Shell Setup

Blink Shell on iOS uses one host: vermissian. From there, `p` opens the orrery
sessions on vermissian. No per-project hosts are needed.

## Host

In Blink Shell, go to **Settings → Hosts** and add:

- **Host**: vermissian
- **HostName**: vermissian.tail82223.ts.net
- **User**: joshsymonds

## Usage

1. Connect to the vermissian host in Blink.
2. Run `p`.

`p` attaches the most recently active Claude Code session and opens the orrery
tree. The other `p` forms work the same way, including `p WORD`, `p new NAME`,
and `p WORDS...`. See [Opening a session](claude-remote-setup.md#opening-a-session)
for the full list.

## Notifications

When a push notification from ntfy reports that a session is waiting or done:

1. Open Blink.
2. Connect to the vermissian host.
3. Run `p`. The orrery tree opens.
