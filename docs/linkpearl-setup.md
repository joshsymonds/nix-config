# Linkpearl Setup

Linkpearl provides secure, peer-to-peer clipboard synchronization between your devices.

## Configuration

Linkpearl is configured to:
- Run as a server on `ultraviolet` listening on port 9437
- Run as a client on `ninuan` (macOS) connecting to ultraviolet

## Secret Setup

Before using linkpearl, you need to create a secret file on each machine:

### On ultraviolet (server):
```bash
mkdir -p ~/.config/linkpearl
echo "your-secure-shared-secret" > ~/.config/linkpearl/secret
chmod 600 ~/.config/linkpearl/secret
```

### On ninuan (client):
```bash
mkdir -p ~/.config/linkpearl
echo "your-secure-shared-secret" > ~/.config/linkpearl/secret
chmod 600 ~/.config/linkpearl/secret
```

**Important**: Use the same secret on all machines that should sync clipboards.

## Applying Configuration

After creating the secret files:

### On ultraviolet:
```bash
sudo nixos-rebuild switch --flake ".#ultraviolet" --option warn-dirty false
```

### On ninuan:
```bash
darwin-rebuild switch --flake ".#ninuan" --option warn-dirty false
```

## Verification

### Check service status on ultraviolet:
```bash
systemctl --user status linkpearl
```

### Check service status on ninuan:
```bash
launchctl list | grep linkpearl
```

### Test clipboard sync:
1. Copy some text on one machine
2. Paste on the other machine - it should have the same content

## Troubleshooting

### Enable verbose logging:
Edit the configuration and set `verbose = true`, then rebuild.

### Check logs on ultraviolet:
```bash
journalctl --user -u linkpearl -f
```

### Check logs on ninuan:
```bash
log show --predicate 'process == "linkpearl"' --last 1h
```

### Firewall issues:
- Ensure port 9437 is open on ultraviolet (already configured)
- Ensure both machines can reach each other over Tailscale
- Test connectivity: `nc -zv ultraviolet 9437`

## Adding More Machines

To add more machines to the clipboard sync network:

1. For servers (accept connections): Configure like ultraviolet with a `listen` address
2. For clients (only connect out): Configure like ninuan with `join` addresses
3. All machines must use the same secret
