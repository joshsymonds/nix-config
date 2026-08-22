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

If the phone ever needs to *push*, that's the moment to mint a key — and
by then `ssh shrike` works, so the pubkey travels over the tailnet
(`ssh shrike cat .ssh/id_ed25519.pub`), never through copy-paste.

### Optional: pull the first switch from the household attic

The config declares ultraviolet's attic as a substituter, but that only
takes effect *after* a switch — the first one doesn't know about it.
vermissian prebuilds and pushes shrike's closure (see below), so if
Tailscale is already up, seed the first switch by hand:

```bash
# proot's /etc/hosts doesn't know MagicDNS names pre-switch:
echo '100.66.32.65 ultraviolet' >> /etc/hosts
mkdir -p ~/.config/nix
cat >> ~/.config/nix/nix.conf <<'EOF'
extra-substituters = http://ultraviolet:8081/nix-config
extra-trusted-public-keys = nix-config:ohee3Ue/5Mw2k1KHLUW26FpngXv/bg3YRtnFk0aMHZs=
EOF
```

If /etc/hosts turns out to be read-only pre-switch, skip this — the
first switch just pulls from cache.nixos.org and attic takes over from
the second onward. This seeding only speeds downloads; evaluation still
happens on-device and is slow under proot no matter what.

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

## 5. Inbound SSH

sshd config, host-key bootstrap, and the fleet's authorized_keys are all
in the closure; `sshd-start` runs automatically from every new shell. The
whole ritual is: **open the Nix-on-Droid app once after a reboot**. Then,
from any fleet machine (matchBlock ships in ssh-config):

```bash
ssh shrike            # tailnet name, port 8022, user nix-on-droid
ssh shrike update     # converge the phone remotely
```

`sshd-stop` kills it and releases the wake lock. Log: `~/.ssh/sshd.log`.

Verify on device: that non-interactive `ssh shrike update` finds `update`
on PATH (zsh .zshenv should provide the profile PATH; if not, add a
`SetEnv`/wrapper to the sshd config in hosts/shrike/default.nix).

## Known unverified-on-device bits

Written before the phone existed; check on first run:

- `pm list packages` visibility from inside the sandbox (Android 11+
  package-visibility rules). If it fails, `update` degrades to printing
  the declared checklist. If it half-works (hides installed apps), the
  installer prompt will offer "update" instead of "install" — harmless.
- `fdroidcl` cache path pattern used to locate downloaded APKs.
- `system.stateVersion "24.05"` is the newest the docs list; bump when
  upstream adds newer.
