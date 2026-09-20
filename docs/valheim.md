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
systemctl is-active valheim.service
sudo -u valheim tail -n 100 /var/lib/valheim/logs/valheim-current.log
```

The encrypted password is
`secrets/hosts/ultraviolet/valheim-password.age`; agenix exposes it at runtime
outside the state directory. An authorized operator can deliberately retrieve
it with `sudo -u valheim cat /run/agenix/valheim-password`; this prints the
secret, so never run it into logs, paste it, or use it for routine checks. The
launcher passes the password in argv: persisted logs are protected, but an
authorized local process inspector can see the live argv.

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
sudo systemctl stop valheim.service
sudo mv /var/lib/valheim "$saved"
sudo install -d -m 0700 -o valheim -g valheim /var/lib/valheim
sudo tar -xf "$archive" -C /var/lib/valheim --strip-components=1 state
sudo chown -R valheim:valheim /var/lib/valheim
sudo systemctl start valheim.service
systemctl is-active valheim.service
```

If validation fails, stop the service, remove the restored directory, move
`$saved` back, and start it again.

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

Recovery roots are the pinned package/configuration in this repository and the
Nix store, ciphertext in `secrets/hosts/ultraviolet/`, live state in
`/var/lib/valheim`, transient protected spool in `/var/lib/valheim-backup`, and
seven-day NAS archives in `/mnt/backups/valheim`.
