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
      # A live pid isn't a live sshd: an orphaned listener (e.g. its proot
      # supervisor died) still accepts TCP but resets every handshake, and
      # trusting the pidfile would keep the zombie enthroned forever.
      # Healthy sshd greets with its banner immediately; probe it.
      banner=""
      read -r -t 3 banner < /dev/tcp/127.0.0.1/8022 2>/dev/null || true
      case "$banner" in
        SSH-*)
          [ "$quiet" = 1 ] || echo "sshd already running (pid $(cat "$pidfile"))"
          exit 0
          ;;
        *)
          [ "$quiet" = 1 ] || echo "sshd pid alive but not answering — replacing zombie"
          kill -9 "$(cat "$pidfile")" 2>/dev/null || true
          rm -f "$pidfile"
          ;;
      esac
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
  # the Android app layer. Installs open a URL for the user to finish
  # (one confirmation each) — deliberately no adb-loopback/Shizuku
  # machinery. /system/bin/pm isn't usable from the app sandbox on the
  # device, so drift detection degrades to a printed checklist.
  updateScript = pkgs.writeShellScriptBin "update" ''
    set -euo pipefail

    # The app-sandbox PATH is sparse (no sed, sometimes no grep/find) —
    # bring our own tools, learned the hard way on-device.
    export PATH=${lib.makeBinPath [pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.findutils]}:$PATH

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
    GIT=${pkgs.git}/bin/git
    APPS=${appsJson}

    installed=""
    have_pm=0
    if installed="$(/system/bin/pm list packages 2>/dev/null | sed 's/^package://')"; then
      have_pm=1
    fi

    is_installed() {
      printf '%s\n' "$installed" | grep -qxF "$1"
    }

    # Android's installer can't read files out of this sandbox: the app's
    # file provider only serves them with allow-external-apps on, which
    # also lets any app granted RUN_COMMAND read this home (fleet ssh key
    # included) and run commands here. So installs go through URLs:
    # termux-open-url hands Android the link itself, and the user finishes
    # the install there, one app at a time.
    open_for_install() {
      local url="$1"
      termux-open-url "$url"
      read -r -p "     press enter once installed... " _ || true
    }

    # Our own APKs (committed in this repo): offered when the APK differs
    # from the last one an install was confirmed for, or the app is gone
    # (where pm can tell). The browser fetches it from GitHub at the
    # checked-out commit (raw.githubusercontent.com: github.com links go
    # to the GitHub app, which does nothing with a raw file); open the
    # download to install. Without pm, confirming counts as installed;
    # delete $state/<id>.sha256 to be offered it again.
    RAW_URL=https://raw.githubusercontent.com/joshsymonds/nix-config
    rev="$("$GIT" -C "$FLAKE_DIR" rev-parse HEAD)"
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/shrike-apps"
    mkdir -p "$state"
    while IFS="$(printf '\t')" read -r id label apk path <&3; do
      sum="$(sha256sum "$apk" | cut -d' ' -f1)"
      if [ "$(cat "$state/$id.sha256" 2>/dev/null)" = "$sum" ] \
        && { [ "$have_pm" = 0 ] || is_installed "$id"; }; then
        continue
      fi
      echo "==> $label: download it in the browser, then open the download to install"
      open_for_install "$RAW_URL/$rev/$path"
      if [ "$have_pm" = 0 ] \
        || /system/bin/pm list packages 2>/dev/null | sed 's/^package://' | grep -qxF "$id"; then
        echo "$sum" > "$state/$id.sha256"
      fi
    done 3< <("$JQ" -r '.local[] | [.id, .label, .apk, .path] | @tsv' "$APPS")

    if [ "$have_pm" = 0 ]; then
      echo "warning: pm not usable from this sandbox — can't detect drift."
      echo "Declared app set:"
      "$JQ" -r '(.fdroid[], .obtainium[], .play[]) | "  \(.label) (\(.id))"' "$APPS"
      exit 0
    fi

    # Missing F-Droid apps: their store page (F-Droid answers market://
    # links), install from there.
    while IFS=$'\t' read -r id label <&3; do
      is_installed "$id" && continue
      echo "==> $label: install it from the store page that opens"
      open_for_install "market://details?id=$id"
    done 3< <("$JQ" -r '.fdroid[] | [.id, .label] | @tsv' "$APPS")

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
  # termux-open-url is how `update` sends installs to the browser and the
  # store; the wake locks keep rebuilds alive; setup-storage grants
  # /sdcard access (~/storage symlinks).
  android-integration = {
    am.enable = true;
    termux-open.enable = true;
    termux-open-url.enable = true;
    termux-reload-settings.enable = true;
    termux-setup-storage.enable = true;
    termux-wake-lock.enable = true;
    termux-wake-unlock.enable = true;
  };

  # Maple Mono NF CN — the same face kitty uses fleet-wide; catppuccin-
  # mocha to match the rest of the fleet's terminals. Termux (a separate
  # sandbox) can't be fed from the nix store: its copy goes to
  # ~/.termux/font.ttf by hand — see README.
  terminal.font = "${pkgs.maple-mono.NF-CN-unhinted}/share/fonts/truetype/MapleMono-NF-CN-Regular.ttf";
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
  networking.hosts = {
    "100.66.32.65" = ["ultraviolet"];
    "100.94.194.116" = ["vermissian"];
    "100.108.237.97" = ["gnomon"];
    "100.120.163.8" = ["echelon"];
  };
  nix = {
    # The 2.18-era nix from nix-on-droid's own pinned nixpkgs — the same
    # lineage as the app's bootstrap, and the only one whose pty handling
    # survives proot (see the nix-on-droid input comment in flake.nix).
    # Do NOT bump to pkgs.nix without testing a build on-device.
    package = inputs.nix-on-droid.inputs.nixpkgs.legacyPackages.aarch64-linux.nix;
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
