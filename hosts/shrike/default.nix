# shrike — Pixel 11, Nix-on-Droid (aarch64-linux, stock Pixel OS for now;
# GrapheneOS doesn't support the 11 yet — reflash day is also wipe-and-
# rebuild-from-this-config day). This module owns the terminal userland
# inside the com.termux.nix app; Android itself stays imperative, with
# apps.nix as the declared app set that `update` reconciles.
{
  config,
  lib,
  pkgs,
  inputs,
  outputs,
  ...
}: let
  appsJson = pkgs.writeText "shrike-apps.json" (builtins.toJSON (import ./apps.nix));

  # sshd, phone-shaped: no systemd, no root, no port 22. Port 8022 (the
  # Termux convention), pubkey-only, host key generated on first start.
  # Started by sshd-start — invoked automatically by every new shell (see
  # home layer), so opening the app once after a reboot arms remote access.
  # Reachability is Tailscale's job; the fleet's ssh-config has a shrike
  # matchBlock pointing at the tailnet name with this port.
  sshdConfig = pkgs.writeText "shrike-sshd-config" ''
    Port 8022
    HostKey ${config.user.home}/.ssh/host_ed25519
    PidFile ${config.user.home}/.ssh/sshd.pid

    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthorizedKeysFile .ssh/authorized_keys
    # authorized_keys is a home-manager symlink into /nix/store; StrictModes
    # rejects that ownership shape, and the store is read-only anyway.
    StrictModes no

    # Mobile networks drop connections silently; reap dead sessions.
    ClientAliveInterval 60
    ClientAliveCountMax 3

    PrintMotd no
    Subsystem sftp ${pkgs.openssh}/libexec/sftp-server
  '';

  sshdStart = pkgs.writeShellScriptBin "sshd-start" ''
    set -euo pipefail
    quiet=0
    [ "''${1:-}" = "--quiet" ] && quiet=1

    pidfile="$HOME/.ssh/sshd.pid"
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      [ "$quiet" = 1 ] || echo "sshd already running (pid $(cat "$pidfile"))"
      exit 0
    fi

    mkdir -p "$HOME/.ssh"
    if [ ! -f "$HOME/.ssh/host_ed25519" ]; then
      ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/host_ed25519" >/dev/null
    fi

    # Without a wake lock Android doze will eventually freeze the process.
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock || true

    ${pkgs.openssh}/bin/sshd -f ${sshdConfig} -E "$HOME/.ssh/sshd.log"
    [ "$quiet" = 1 ] || echo "sshd listening on :8022 (log: ~/.ssh/sshd.log)"
  '';

  sshdStop = pkgs.writeShellScriptBin "sshd-stop" ''
    set -euo pipefail
    pidfile="$HOME/.ssh/sshd.pid"
    if [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null; then
      echo "sshd stopped"
    else
      echo "sshd not running"
    fi
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock || true
  '';

  # `update`, phone-shaped: switch the nix-on-droid closure, then converge
  # the Android app layer. F-Droid installs go through the system installer
  # prompt (one tap each) — deliberately no adb-loopback/Shizuku machinery.
  # /system/bin/pm package visibility from inside the app sandbox is
  # unverified until this runs on the device; every use degrades to a
  # printed checklist instead of failing.
  updateScript = pkgs.writeShellScriptBin "update" ''
    set -euo pipefail

    FLAKE_DIR="$HOME/nix-config"
    if [ ! -d "$FLAKE_DIR" ]; then
      echo "update: $FLAKE_DIR not found — see hosts/shrike/README.md for bootstrap" >&2
      exit 1
    fi

    # Keep Android from dozing mid-rebuild.
    if command -v termux-wake-lock >/dev/null 2>&1; then
      termux-wake-lock || true
      trap 'termux-wake-unlock >/dev/null 2>&1 || true' EXIT
    fi

    echo "==> switching nix-on-droid closure"
    nix-on-droid switch --flake "$FLAKE_DIR#shrike" "$@"

    echo "==> checking declared Android app set"
    JQ=${pkgs.jq}/bin/jq
    FDROIDCL=${pkgs.fdroidcl}/bin/fdroidcl
    APPS=${appsJson}

    installed=""
    have_pm=0
    if installed="$(/system/bin/pm list packages 2>/dev/null | sed 's/^package://')"; then
      have_pm=1
    fi

    if [ "$have_pm" = 0 ]; then
      echo "warning: pm not usable from this sandbox — can't detect drift."
      echo "Declared app set:"
      "$JQ" -r '(.fdroid[], .obtainium[], .play[]) | "  \(.label) (\(.id))"' "$APPS"
      exit 0
    fi

    is_installed() {
      printf '%s\n' "$installed" | grep -qxF "$1"
    }

    fdroid_missing=()
    while IFS= read -r id; do
      is_installed "$id" || fdroid_missing+=("$id")
    done < <("$JQ" -r '.fdroid[].id' "$APPS")

    if [ "''${#fdroid_missing[@]}" -gt 0 ]; then
      echo "==> missing F-Droid apps: ''${fdroid_missing[*]}"
      "$FDROIDCL" update
      for id in "''${fdroid_missing[@]}"; do
        if ! "$FDROIDCL" download "$id"; then
          echo "  ! download failed for $id (bad id, or not in the main repo)" >&2
          continue
        fi
        apk="$(find "''${XDG_CACHE_HOME:-$HOME/.cache}/fdroidcl" -name "''${id}_*.apk" -print -quit)"
        if [ -z "$apk" ]; then
          echo "  ! downloaded but APK not found in fdroidcl cache for $id" >&2
          continue
        fi
        if command -v termux-open >/dev/null 2>&1; then
          echo "  -> $id: confirm the install prompt"
          termux-open --content-type application/vnd.android.package-archive "$apk"
          # One prompt at a time — a second intent would replace the first.
          read -r -p "     press enter once installed... " _ || true
        else
          dest="$HOME/storage/downloads/shrike-apps"
          mkdir -p "$dest" && cp "$apk" "$dest/"
          echo "  -> staged ''${dest}/$(basename "$apk") — tap it in the Files app"
          echo "     (termux-open missing: run termux-setup-storage / re-switch first)"
        fi
      done
    fi

    "$JQ" -r '.obtainium[] | [.id, .label] | @tsv' "$APPS" | while IFS="$(printf '\t')" read -r id label; do
      is_installed "$id" || echo "  missing: $label ($id) — install via Obtainium / GitHub releases"
    done
    "$JQ" -r '.play[] | [.id, .label] | @tsv' "$APPS" | while IFS="$(printf '\t')" read -r id label; do
      is_installed "$id" || echo "  missing: $label ($id) — install from the Play Store"
    done

    echo "==> shrike converged"
  '';
in {
  environment.packages = [
    updateScript
    sshdStart
    sshdStop
    pkgs.git
    pkgs.openssh
  ];

  environment.motd = null;

  # Bridges into the Android side of the fence, provided by the app:
  # termux-open is what lets `update` hand APKs to the system installer;
  # the wake locks keep rebuilds alive; setup-storage grants /sdcard
  # access (~/storage symlinks).
  android-integration = {
    am.enable = true;
    termux-open.enable = true;
    termux-open-url.enable = true;
    termux-reload-settings.enable = true;
    termux-setup-storage.enable = true;
    termux-wake-lock.enable = true;
    termux-wake-unlock.enable = true;
  };

  # Nerd font so the starship prompt renders; catppuccin-mocha to match
  # the rest of the fleet's terminals.
  terminal.font = "${pkgs.nerd-fonts.jetbrains-mono}/share/fonts/truetype/NerdFonts/JetBrainsMono/JetBrainsMonoNerdFontMono-Regular.ttf";
  terminal.colors = {
    background = "#1e1e2e";
    foreground = "#cdd6f4";
    cursor = "#f5e0dc";
    color0 = "#45475a";
    color1 = "#f38ba8";
    color2 = "#a6e3a1";
    color3 = "#f9e2af";
    color4 = "#89b4fa";
    color5 = "#f5c2e7";
    color6 = "#94e2d5";
    color7 = "#bac2de";
    color8 = "#585b70";
    color9 = "#f38ba8";
    color10 = "#a6e3a1";
    color11 = "#f9e2af";
    color12 = "#89b4fa";
    color13 = "#f5c2e7";
    color14 = "#94e2d5";
    color15 = "#a6adc8";
  };

  user.shell = "${pkgs.zsh}/bin/zsh";

  # Household attic on ultraviolet as first substituter: `update` pulls
  # the closure over the tailnet instead of cache.nixos.org (vermissian
  # builds shrike's closure under emulation and pushes it — see
  # hosts/shrike/README.md). The static hosts entry matters twice over:
  # proot's resolv.conf bypasses MagicDNS so the name wouldn't resolve,
  # and atticd's Host-header allowlist only admits the hostname form.
  # Tailscale node IPs are stable.
  networking.hosts."100.66.32.65" = ["ultraviolet"];
  nix = {
    substituters = ["http://ultraviolet:8081/nix-config"];
    trustedPublicKeys = ["nix-config:ohee3Ue/5Mw2k1KHLUW26FpngXv/bg3YRtnFk0aMHZs="];
    # Same rationale as modules/nix/defaults.nix: an unreachable attic
    # (phone off-tailnet, ultraviolet rebooting) must cost 5s per nix
    # command, not the default hang-around — fall through to
    # cache.nixos.org fast. And flakes-by-default, so bare `nix` works
    # like Determinate does on the rest of the fleet — the
    # --extra-experimental-features incantation is bootstrap-only.
    extraOptions = ''
      connect-timeout = 5
      experimental-features = nix-command flakes
    '';
  };

  home-manager = {
    useGlobalPkgs = true;
    backupFileExtension = "backup";
    extraSpecialArgs = {
      inherit inputs outputs;
      hostname = "shrike";
    };
    config = ../../home-manager/hosts/shrike.nix;
  };

  system.stateVersion = "24.05";
}
