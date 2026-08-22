# shrike — Pixel 11 bootstrap

Day-one ritual for a fresh phone (or post-wipe rebuild, e.g. when
GrapheneOS adds Pixel 11 support). After this, the phone converges with
`update` like every other host.

## 1. Stores

1. Browser → <https://f-droid.org> → download and install **F-Droid Basic**
   (allow "install unknown apps" for the browser when prompted). F-Droid
   Basic does silent background *updates* of everything it installs, via
   the official Android 12+ mechanism — no Shizuku, no adb.
2. From F-Droid Basic, install **Nix-on-Droid** (`com.termux.nix`).

## 2. Nix-on-Droid

Open the app, let it bootstrap, then:

```bash
# nix-config is public — anonymous https clone, no credentials on the
# phone (it only ever pulls). Flakes syntax, NOT nix-shell -p: the fresh
# install has no nixpkgs channel, so channel-era commands fail with
# "file 'nixpkgs' was not found in the Nix search path".
nix shell --extra-experimental-features 'nix-command flakes' nixpkgs#git \
  --command git clone https://github.com/joshsymonds/nix-config.git ~/nix-config

# The first switch ALSO needs git on PATH (nix shells out to git to read
# a git-repo flake, and pre-switch there is no git) — run it inside the
# same ephemeral shell. After this switch, git is in the closure and
# plain `update` works forever.
nix shell --extra-experimental-features 'nix-command flakes' nixpkgs#git \
  --command nix-on-droid switch --flake ~/nix-config#shrike
```

Post-switch, mint the phone's identity and register it (fleet +
GitHub — the git module's https→ssh rewrite means pulls go over ssh
once the closure is active):

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C josh+shrike@joshsymonds.com
```

Add the pubkey to lib/ssh-keys.nix (fleet authorized_keys) and to the
GitHub account — read it over the tailnet
(`ssh shrike cat .ssh/id_ed25519.pub`), never through copy-paste.

### Seed the attic before the first switch (one command)

The config declares ultraviolet's attic as a substituter, but that only
takes effect *after* a switch. Seeding it first is not optional in
practice: without it the phone tries to *build* nix-on-droid's
source-dir packages (termux-am) on-device, and proot's unpackPhase
chokes on that. With Tailscale up, run the flake's seed app — github:
refs use the tarball fetcher, so this needs neither git nor the clone:

```bash
nix run --extra-experimental-features 'nix-command flakes' \
  github:joshsymonds/nix-config#seed
```

It writes the ultraviolet hosts entry (proot's resolv.conf can't see
MagicDNS pre-switch), the attic substituter + key, and
flakes-by-default into `~/.config/nix/nix.conf` — that command is the
last time the experimental-features flag is ever typed. Idempotent.
Seeding only speeds downloads; evaluation still happens on-device and
is slow under proot no matter what.

### Re-warming the cache after config changes

On vermissian (or gnomon — both have aarch64 binfmt):

```bash
nix build .#nixOnDroidConfigurations.shrike.activationPackage \
  --impure --no-link --print-out-paths \
  --extra-substituters https://nix-on-droid.cachix.org \
  --extra-trusted-public-keys 'nix-on-droid.cachix.org-1:56snoMJTXmDRC1Ei24CmKoUqvHJ9XCp+nidK7qkMQrU='
# then push that path's closure with attic push (post-build hooks only
# cover locally-BUILT paths; substituted deps need an explicit push):
attic push h:nix-config <generation-path>
```

First switch downloads the closure from cache.nixos.org — do it on wifi.
When the terminal settings change (font/colors), run
`termux-reload-settings` or restart the app.

## 3. Converge the app layer

```bash
update
```

- Grants: first run of anything touching `~/storage` needs
  `termux-setup-storage` (fires the Android permission prompt).
- F-Droid apps: `update` downloads each missing APK and fires the system
  install prompt — one confirmation tap per app.
- Play / Obtainium apps: `update` prints what's missing; install those by
  hand (Tailscale from Play, Obtainium from its GitHub releases APK).

## 4. The rest of the fleet glue (manual, once)

- Tailscale: sign in, join the tailnet.
- Termux (from F-Droid, never Play): SMS-bridge runtime — Termux:API
  addon must come from the same source as Termux itself.
- Android Settings → Apps → Nix-on-Droid → Battery: enable "Allow
  background usage", then **tap the label text (not the switch)** and
  pick **Unrestricted** — the toggle alone means Optimized, which still
  dozes the app. Android sometimes reverts this to Optimized; if sshd
  seems dead despite the open-the-app ritual, re-check here first.

## 5. SSH: outbound is the product, inbound is a debug tool

The phone's daily job is outbound: `earth` / `mars` / etc. drop into
tmux devspaces on vermissian (devspaces-client module), `ssh <host>`
works fleet-wide with the phone's own key.

Inbound sshd exists but is started BY HAND when wanted:

```bash
sshd-start            # on the phone; then from a fleet machine:
ssh shrike            # tailnet name, port 8022, user nix-on-droid
ssh shrike update     # converge the phone remotely
sshd-stop             # when done (releases the wake lock)
```

It is deliberately NOT auto-armed: any daemon spawned from a session
chains that session's proot supervisor open (ptrace), making the
session unclosable — the "bricked on Ctrl-D" symptom. Same reason the
atuin daemon is disabled here (classic sqlite mode instead). The
session that runs `sshd-start` won't close until `sshd-stop`; that's
inherent, and fine for a debug session.

## Known unverified-on-device bits

Written before the phone existed; check on first run:

- `pm list packages` visibility from inside the sandbox (Android 11+
  package-visibility rules). If it fails, `update` degrades to printing
  the declared checklist. If it half-works (hides installed apps), the
  installer prompt will offer "update" instead of "install" — harmless.
- `fdroidcl` cache path pattern used to locate downloaded APKs.
- `system.stateVersion "24.05"` is the newest the docs list; bump when
  upstream adds newer.
