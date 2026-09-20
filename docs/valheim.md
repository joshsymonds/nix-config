# Valheim on ultraviolet

Valheim is pinned by `pkgs/valheim-server/source-lock.json`. Before deployment,
run:

```sh
nix build .#checks.x86_64-linux.valheim \
  .#valheim-server.passthru.tests.package \
  .#nixosConfigurations.ultraviolet.config.system.build.toplevel --no-link -L
bash tests/valheim-secret.sh
```

A deliberate update changes the server/runtime manifest IDs (and server build)
in `source-lock.json`, obtains each new fixed-output `narHash` from a failing
`nix build .#valheim-server -L`, records the reported hashes, then independently
verifies both depots twice:

```sh
nix run .#valheim-source-check -- --fetch-twice
```

Do not update the pin or accept a hash without that final check.

## Runtime operations

The service is `valheim.service`, user/group `valheim`, with state under
`/var/lib/valheim`. Current world files match
`worlds_local/Midgard/_main.*.{fwl2,db2,chunks}`. Its restricted per-invocation
log is `/var/lib/valheim/logs/valheim-current.log`.

```sh
sudo systemctl start valheim.service
sudo systemctl stop valheim.service
sudo systemctl restart valheim.service
systemctl is-enabled --quiet valheim.service
systemctl is-active --quiet valheim.service
sudo -u valheim tail -n 100 /var/lib/valheim/logs/valheim-current.log
sudo grep -Fq 'Game server connected' /var/lib/valheim/logs/valheim-current.log
sudo ss -lunp | grep -Eq ':2456\b'
sudo ss -lunp | grep -Eq ':2457\b'
world_dir=/var/lib/valheim/worlds_local/Midgard
world_id=$(sudo find "$world_dir" -maxdepth 1 -type f -name '_main.*.fwl2' -size +0c -printf '%f\n')
test -n "$world_id"
for suffix in fwl2 db2 chunks; do
  sudo find "$world_dir" -maxdepth 1 -type f -name "_main.*.$suffix" -size +0c -print -quit | grep -q .
done
sudo systemctl restart valheim.service
test "$world_id" = "$(sudo find "$world_dir" -maxdepth 1 -type f -name '_main.*.fwl2' -size +0c -printf '%f\n')"
for suffix in fwl2 db2 chunks; do
  sudo find "$world_dir" -maxdepth 1 -type f -name "_main.*.$suffix" -size +0c -print -quit | grep -q .
done
sudo grep -Fq 'Game server connected' /var/lib/valheim/logs/valheim-current.log
invocation=$(systemctl show --value -p InvocationID valheim.service)
restarts=$(systemctl show --value -p NRestarts valheim.service)
sleep 300
systemctl is-active --quiet valheim.service
test "$invocation" = "$(systemctl show --value -p InvocationID valheim.service)"
test "$restarts" = "$(systemctl show --value -p NRestarts valheim.service)"
```

Midgard is **passwordless** (`services.valheim.passwordFile = null`) and remains
unlisted. Anyone who can reach its game ports can join, subject to Valheim's
normal version/account checks and any ban/permit lists. Network access, not a
shared password, is the access boundary; do not forward ports publicly unless
that is intended. LAN players connect to `172.31.0.200:2456`; authorized Tailscale
peers can use ultraviolet's Tailscale address without a game password.

The module still supports a restricted runtime `passwordFile` for servers that
need a password. In that mode, upstream Valheim exposes it in process arguments.
The old encrypted credential remains in
`secrets/hosts/ultraviolet/valheim-password.age` for rollback, but Midgard no longer
provisions or reads it.

The LAN endpoint is `172.31.0.200:2456`; the host firewall opens UDP
2456–2457. No router, Tailscale, Cloudflare, or other public ingress is part of
this setup, and an actual client join remains unverified.

## Backup and restore

`valheim-backup.timer` runs daily at 04:15 with `Persistent=true`:

```sh
systemctl list-timers valheim-backup.timer
sudo systemctl start valheim-backup.service
journalctl -u valheim-backup.service --since today --no-pager
```

A running server is gracefully saved and briefly stopped. A protected copy of
all state is staged on local SSD at `/var/lib/valheim-backup`, then the prior
running/stopped state is restored before NAS transfer. A unique archive is
atomically published under `/mnt/backups/valheim` only when `/mnt/backups` has
actual `nfs`/`nfs4` backing from `172.31.0.100:/volume1/backup`. Successful
backups prune only owned archives older than seven days. This does not promise
recovery from power loss or uninterruptible NFS; the live backup and restore
checks are release work.

Restore to scratch without stopping production:

```sh
scratch=$(mktemp -d)
sudo tar -xf /mnt/backups/valheim/valheim-YYYYMMDDTHHMMSS-XXXXXX.tar -C "$scratch"
sudo find "$scratch/state/worlds_local/Midgard" -maxdepth 1 -type f -name '_main.*' -ls
sudo rm -rf "$scratch"
```

For a deliberate production restore, first choose and scratch-check the exact
archive, then preserve the current state and restore the archive's `state/`
contents. Do not run this during normal operation or as part of deployment.

```sh
archive=/mnt/backups/valheim/valheim-YYYYMMDDTHHMMSS-XXXXXX.tar
saved=/var/lib/valheim.before-restore.$(date -u +%Y%m%dT%H%M%SZ)
timer_was_active=0
if systemctl is-active --quiet valheim-backup.timer; then timer_was_active=1; fi
sudo systemctl stop valheim-backup.timer
sudo systemctl stop valheim-backup.service
sudo systemctl stop valheim.service
sudo mv /var/lib/valheim "$saved"
sudo install -d -m 0700 -o valheim -g valheim /var/lib/valheim
sudo tar -xf "$archive" -C /var/lib/valheim --strip-components=1 state
sudo chown -R valheim:valheim /var/lib/valheim
sudo systemctl start valheim.service
systemctl is-active valheim.service
if [ "$timer_was_active" -eq 1 ]; then sudo systemctl start valheim-backup.timer; fi
```

If validation fails, stop the service, remove the restored directory, move
`$saved` back, and start it again. Restart `valheim-backup.timer` as well when
`$timer_was_active` is 1.

## Deploy and rollback

Keep the prior system path in the same operator shell, build first, then switch:

```sh
prior_system=$(readlink -f /run/current-system)
nix build .#nixosConfigurations.ultraviolet.config.system.build.toplevel --no-link -L
sudo nixos-rebuild switch --flake .#ultraviolet
systemctl is-active valheim.service
systemctl list-timers valheim-backup.timer
```

Rollback without changing world data using the captured generation:

```sh
sudo "$prior_system/bin/switch-to-configuration" switch
```

Recovery roots are linked explicitly by record: source is
`~/.gambit/nix-config-2c8df73/valheim-server/artifacts/source`, package is
`~/.gambit/nix-config-2c8df73/valheim-server/artifacts/server`, and system is
`~/.gambit/nix-config-2c8df73/valheim-server/artifacts/ultraviolet-system`;
ciphertext is `secrets/hosts/ultraviolet/valheim-password.age`,
live state is `/var/lib/valheim`, transient protected spool is
`/var/lib/valheim-backup`, and seven-day NAS archives are
`/mnt/backups/valheim`.
