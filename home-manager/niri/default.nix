{
  lib,
  pkgs,
  ...
}: let
  # Region pick → satty annotate → wl-copy + timestamped save. Shared by the
  # Shift+Print and Super+Shift+5 binds. slurp's -d shows the selection's
  # pixel dimensions while dragging (the "screen ruler" side-effect). The
  # whole chain runs in one `sh -c` so grim's PNG streams through stdin
  # into satty without ever touching disk; satty writes the final file
  # itself via its strftime --output-filename template, and --early-exit
  # closes it as soon as you copy or save.
  sattyPipeline = [
    "sh"
    "-c"
    ''mkdir -p "$HOME/Pictures/Screenshots" && grim -g "$(slurp -d)" - | satty --filename - --output-filename "$HOME/Pictures/Screenshots/satty-%Y%m%d-%H%M%S.png" --copy-command wl-copy --early-exit''
  ];

  # AI-driveable snapshot tool. Captures pixels + niri's structural metadata
  # into a fresh /tmp/niri-snap/<ts>/ dir, prints a JSON manifest to stdout,
  # and updates /tmp/niri-snap/latest. Designed so an agent can run one
  # command and read one stdout line to find every artifact.
  #
  # Mode selection:
  #   default     focused output. Uses `screenshot-screen --path`, which is
  #               the only screenshot variant that takes an output path, so
  #               we can write straight to our temp dir.
  #   --window    focused window (or by id). `screenshot-window` has no
  #               --path option, so we set `--write-to-disk false` and pull
  #               the PNG out of the wl-clipboard via wl-paste.
  #
  # Caveat: niri's screenshot actions always populate the wl-clipboard with
  # the captured image. This tool inherits that — running it overwrites
  # whatever the user had on the clipboard. The same is true of every other
  # screenshot path on this system (Print binds, satty pipeline), so the
  # cost is consistent rather than surprising.
  # Launcher hotkeys: focus a window matching --app-id if one exists,
  # otherwise spawn the command. With multiple matches, cycles to the next
  # window after the currently-focused one (or the first match if focus is
  # elsewhere). app_id matching is case-insensitive exact — covers the
  # capitalisation drift between apps (e.g. Slack reports "Slack", spotify
  # reports "spotify") without a per-bind regex.
  focus-or-spawn = pkgs.writeShellApplication {
    name = "focus-or-spawn";
    runtimeInputs = with pkgs; [jq];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage: focus-or-spawn --app-id <id> [--title-regex <re>] -- <command> [args...]

        --app-id <id>       Case-insensitive exact match on the window's app_id.
        --title-regex <re>  Optional regex (case-insensitive) further narrowing
                            matches by title.
        <command>           Argv to spawn through niri if no window matches.

      With one match, focuses it. With multiple matches, focuses the next one
      after the currently-focused window (cycle), or the first match if focus
      is elsewhere. With zero matches, spawns the command via niri.
      EOF
      }

      app_id=""
      title_re=""
      while (( $# )); do
        case "$1" in
          -h|--help) usage; exit 0 ;;
          --app-id)
            [[ $# -ge 2 ]] || { printf 'focus-or-spawn: --app-id needs a value\n' >&2; exit 2; }
            app_id="$2"; shift 2 ;;
          --title-regex)
            [[ $# -ge 2 ]] || { printf 'focus-or-spawn: --title-regex needs a value\n' >&2; exit 2; }
            title_re="$2"; shift 2 ;;
          --) shift; break ;;
          *) printf 'focus-or-spawn: unknown flag: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
      done

      if [[ -z "$app_id" ]]; then
        printf 'focus-or-spawn: --app-id required\n' >&2
        exit 2
      fi
      if (( $# == 0 )); then
        printf 'focus-or-spawn: spawn command required after --\n' >&2
        exit 2
      fi

      windows="$(niri msg --json windows)"

      matches="$(jq --arg app "$app_id" --arg title "$title_re" '
        [.[]
         | select((.app_id // "") | ascii_downcase == ($app | ascii_downcase))
         | select(($title == "") or ((.title // "") | test($title; "i")))]
        | sort_by(.id)
      ' <<<"$windows")"

      count="$(jq 'length' <<<"$matches")"

      if (( count == 0 )); then
        exec niri msg action spawn -- "$@"
      fi

      # Cycle order is by window id (stable, monotonic at creation time).
      # Predictable across presses; not always visually adjacent, but that
      # only matters for >2 matches of the same app, which is the rare case.
      target="$(jq -r '
        (map(select(.is_focused)) | first | .id // null) as $focused
        | (map(.id)) as $ids
        | if $focused == null then $ids[0]
          else
            ($ids | index($focused)) as $i
            | $ids[(($i + 1) % ($ids | length))]
          end
      ' <<<"$matches")"

      exec niri msg action focus-window --id "$target"
    '';
  };

  niri-snap = pkgs.writeShellApplication {
    name = "niri-snap";
    runtimeInputs = with pkgs; [jq wl-clipboard];
    text = ''
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage: niri-snap [--window [<id>]]

        (no args)         Capture the focused output (screen.png).
        --window          Capture the focused window (window.png).
        --window <id>     Capture a specific window by niri window id.
        -h, --help        Show this help.

      Outputs land in /tmp/niri-snap/<timestamp>/ alongside structural JSON
      (windows, workspaces, focused-window, focused-output). The symlink
      /tmp/niri-snap/latest is updated to point at the newest dir, and a
      one-line JSON manifest is printed to stdout for programmatic use.

      Note: niri's screenshot actions copy the image to the wl-clipboard,
      so your clipboard will hold the captured PNG after each run.
      EOF
      }

      mode="screen"
      window_id=""

      while (( $# )); do
        case "$1" in
          -h|--help) usage; exit 0 ;;
          --window)
            mode="window"
            shift
            if (( $# )) && [[ "$1" != -* ]]; then
              window_id="$1"
              shift
            fi
            ;;
          *) printf 'niri-snap: unknown flag: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
      done

      ts="$(date -u +%Y%m%dT%H%M%SZ)"
      root="/tmp/niri-snap"
      dir="$root/$ts"
      mkdir -p "$dir"

      # Structural metadata, always collected regardless of mode.
      niri msg --json windows         > "$dir/windows.json"
      niri msg --json workspaces      > "$dir/workspaces.json"
      niri msg --json focused-window  > "$dir/focused-window.json"
      niri msg --json focused-output  > "$dir/focused-output.json"

      # niri's screenshot IPC returns immediately and the compositor writes
      # the file (or populates the clipboard) on its next frame, so we have
      # to wait for the artifact before printing the manifest — otherwise an
      # agent that reads the path right after `niri-snap` exits will race.
      wait_for_file() {
        local path="$1"
        for _ in $(seq 1 50); do
          [[ -s "$path" ]] && return 0
          sleep 0.05
        done
        printf 'niri-snap: timed out waiting for %s\n' "$path" >&2
        return 1
      }

      case "$mode" in
        screen)
          niri msg action screenshot-screen --path "$dir/screen.png" >/dev/null
          wait_for_file "$dir/screen.png"
          image="$dir/screen.png"
          ;;
        window)
          args=(--write-to-disk false)
          if [[ -n "$window_id" ]]; then
            args+=(--id "$window_id")
          fi
          # Clear the clipboard before issuing the screenshot. Otherwise a
          # previous niri-snap (or any earlier screenshot) leaves image/png
          # in the clipboard, and the wait loop below short-circuits on that
          # stale offer — handing back the *previous* capture's pixels at the
          # wrong dimensions. niri's screenshot-window action overwrites the
          # clipboard regardless, so clearing first costs nothing extra.
          wl-copy --clear
          niri msg action screenshot-window "''${args[@]}" >/dev/null
          for _ in $(seq 1 50); do
            if wl-paste --list-types 2>/dev/null | grep -qx 'image/png'; then
              break
            fi
            sleep 0.05
          done
          wl-paste -t image/png > "$dir/window.png"
          wait_for_file "$dir/window.png"
          image="$dir/window.png"
          ;;
      esac

      ln -sfn "$dir" "$root/latest"

      jq -n \
        --arg ts "$ts" \
        --arg dir "$dir" \
        --arg mode "$mode" \
        --arg image "$image" \
        '{
          ts: $ts,
          dir: $dir,
          mode: $mode,
          latest: "/tmp/niri-snap/latest",
          artifacts: {
            screenshot:     $image,
            windows:        ($dir + "/windows.json"),
            workspaces:     ($dir + "/workspaces.json"),
            focused_window: ($dir + "/focused-window.json"),
            focused_output: ($dir + "/focused-output.json")
          }
        }'
    '';
  };
in {
  # niri-snap is niri-only, so it ships from this module. The package is
  # built above via writeShellApplication; here we just expose it on PATH.
  home.packages = [niri-snap focus-or-spawn];

  # niri-flake's HM module is auto-loaded by its NixOS module when
  # home-manager is detected — no explicit import needed (and an
  # explicit import here would duplicate `programs.niri.finalConfig`).
  # The DMS niri HM module is imported once at the desktop layer.

  # No `workspaces` declaration. Niri auto-creates an empty workspace
  # per monitor at startup and a trailing empty workspace as you fill
  # them. The whole "named role workspaces" model (term/web/zoom/...)
  # was a holdover from laptop muscle memory: when only one window
  # fits at a time, workspace == app. On a 5120-wide multi-monitor
  # setup, that flips — every "role" is a column on the default
  # workspace, navigable by Alt+H/L. Workspaces are reserved for
  # genuine mode shifts, which we now handle via fullscreen-window
  # (Alt+F) instead of dedicated workspaces.

  # Niri's `recent-windows` (alt-tab) overlay opens via the upper-left
  # hot-corner by default; also, that hot-corner triggers the overview
  # grid when the mouse approaches it. Disable both — we have no
  # `toggle-overview` keybind either, so the grid is fully unreachable.
  programs.niri.settings.gestures.hot-corners.enable = false;

  # Key repeat — niri's stock 600ms delay / 25Hz rate is sluggish for
  # backspace/arrow-key-heavy use. Tuning toward what macOS exposes via
  # `defaults write -g InitialKeyRepeat 12 KeyRepeat 1` (the common
  # Mac power-user fast-fast preset).
  programs.niri.settings.input.keyboard.repeat-delay = 200;
  programs.niri.settings.input.keyboard.repeat-rate = 50;

  # focus-follows-mouse lives in extras.kdl as a fork-only block (the
  # `edge-deadzone` property comes from josh/ffm-edge-deadzone and isn't
  # in niri-flake's typed schema yet — same pattern as
  # `cross-monitor-column-insert` and `clip-fullscreen-backdrop-to-window`).

  # Warp the mouse to the focused window on keyboard focus changes. Without
  # this, cross-monitor keyboard switches land the cursor at the new
  # monitor's center (per `move_cursor_to_output` in niri's focus_window),
  # which on monitors with vertical taskbars sits over a non-focused tile —
  # the next mouse motion would then bounce focus to that tile via FFM.
  # Empty block uses default mode: only warp when cursor isn't already
  # inside the focused window (intra-output: per-axis nudge; cross-output:
  # always center on the new window).
  programs.niri.settings.input.warp-mouse-to-focus = {
    enable = true;
  };

  # X11 fallback via xwayland-satellite (package added system-side in
  # modules/desktop/niri.nix). Niri itself is pure Wayland; satellite
  # provides an on-demand Xwayland server claiming DISPLAY=:0 so X11-only
  # apps (Zoom, older JetBrains splash screens, some Steam titles) can
  # connect when launched from a niri-spawned scope.
  #
  # programs.niri.settings.environment lands the var in niri's own env
  # *and* gets propagated to the systemd user manager (niri runs
  # `systemctl --user import-environment` on startup), so app.slice
  # scopes — which is how niri/DMS launch every app — inherit DISPLAY.
  #
  # NIXOS_OZONE_WL=1 flips Electron apps (Slack, Signal, Spotify, 1Password
  # GUI, VS Code) onto native Wayland Ozone — without this they default to
  # XWayland and ignore xdg-decoration, so prefer-no-csd doesn't reach them.
  # QT_QPA_PLATFORM tries native Wayland for Qt apps (Zoom) with X11 as the
  # fallback if the app refuses Wayland.
  programs.niri.settings.environment = {
    DISPLAY = ":0";
    NIXOS_OZONE_WL = "1";
    QT_QPA_PLATFORM = "wayland;xcb";
  };

  # NVIDIA + niri + PipeWire screencast: SHM-fallback ships in our niri
  # fork via josh/zoom-screencast-fix, which carries niri PR #1791
  # (wrvsrx). That PR teaches niri's pw_utils to emit two SPA EnumFormat
  # pods per fourcc — one with the modifier prop (DMA-BUF), one without
  # (SHM) — matching the canonical pattern from Mutter MR !1939, KWin
  # MR !1210, and the PipeWire dma-buf negotiation spec. Consumers like
  # Zoom / Slack / Chromium that don't speak DMA-BUF can now fixate on
  # the SHM offer; niri allocates a memfd, renders into it via the same
  # path used by wlr-screencopy, and queues it back. No debug flags
  # needed at the niri side. See INTEGRATION.md in the niri fork repo.

  programs.niri.settings.spawn-at-startup = [
    {command = ["xwayland-satellite" ":0"];}
  ];

  # Wrap every bind with `allow-inhibiting = false` so the wayland
  # keyboard-shortcuts-inhibit protocol can't steal our WM keys.
  # Default niri honors inhibit (intended for remote-desktop clients
  # and software KVMs), but Steam/SDL/Proton games request it too —
  # which silently disables Alt+Shift+H/L (move column to monitor),
  # Alt+F (exit fullscreen), Alt+Q (close), etc. while the game is
  # focused. We're not running an RDP client; niri's binds always win.
  programs.niri.settings.binds = lib.mapAttrs (_: v: v // {allow-inhibiting = false;}) {
    # ── Window lifecycle ──────────────────────────────────────────
    "Alt+Q" = {
      hotkey-overlay.title = "Close Window";
      action.close-window = [];
    };

    # ── Focus motion ──────────────────────────────────────────────
    # H/L walk columns and hop to the next monitor when the current
    # monitor is exhausted. J/K walk stacked windows in the focused
    # column and fall through to the previous/next workspace when the
    # stack is exhausted. Niri keeps exactly one empty trailing
    # workspace per monitor and auto-creates/collapses as needed.
    "Alt+H".action.focus-column-or-monitor-left = [];
    "Alt+L".action.focus-column-or-monitor-right = [];
    "Alt+J".action.focus-window-or-workspace-down = [];
    "Alt+K".action.focus-window-or-workspace-up = [];

    # ── Reorder (Shift = reorder, mirrors focus motion) ───────────
    # Shift+H/L: shove the focused column left/right. When already at
    # the edge, falls through to the next monitor — same edge-crossing
    # shape as the Alt+H/L focus binds.
    # Shift+J/K: reorder the focused window within its stacked column,
    # falling through to the previous/next workspace when the stack is
    # exhausted — mirrors the focus binds.
    "Alt+Shift+H".action.move-column-left-or-to-monitor-left = [];
    "Alt+Shift+L".action.move-column-right-or-to-monitor-right = [];
    "Alt+Shift+J".action.move-window-down-or-to-workspace-down = [];
    "Alt+Shift+K".action.move-window-up-or-to-workspace-up = [];

    # ── Resize ────────────────────────────────────────────────────
    # R cycles the column through preset widths (1/3, 1/2, 2/3).
    # Shift+R cycles the focused window through preset heights —
    # useful for stacked columns where you want one window to take
    # more vertical space than its siblings.
    "Alt+R" = {
      hotkey-overlay.title = "Cycle Column Width";
      action.switch-preset-column-width = [];
    };
    "Alt+Shift+R" = {
      hotkey-overlay.title = "Cycle Window Height";
      action.switch-preset-window-height = [];
    };

    # ── Focus modes (replaces modal workspaces) ───────────────────
    # F: fullscreen the focused window (covers the whole monitor;
    # other columns hidden). This is what was previously a Zoom
    # workspace — Alt+F on the Zoom window IS call mode. Alt+F again
    # exits fullscreen.
    # Shift+F: maximize column to fill the monitor (other columns
    # scrolled off but still on the workspace, no fullscreen).
    "Alt+F" = {
      hotkey-overlay.title = "Fullscreen Window";
      action.fullscreen-window = [];
    };
    "Alt+Shift+F" = {
      hotkey-overlay.title = "Maximize Column";
      action.maximize-column = [];
    };

    # ── Stack manipulation ────────────────────────────────────────
    # Shift+I: pull the right neighbor INTO this column, stacking it.
    # Shift+O: expel the focused window OUT of this column, into a new
    #    column to the right.
    # Shift+T: toggle the focused column between split (all stacked windows
    #    visible at fractional height) and tabbed (only one visible,
    #    J/K to swap) display.
    # The bare Alt+I/O/T slots are now launcher binds (see below) — these
    # WM ops moved to Alt+Shift to free those letters for app focus-or-spawn.
    "Alt+Shift+I" = {
      hotkey-overlay.title = "Consume Window into Column";
      action.consume-window-into-column = [];
    };
    "Alt+Shift+O" = {
      hotkey-overlay.title = "Expel Window from Column";
      action.expel-window-from-column = [];
    };
    "Alt+Shift+T" = {
      hotkey-overlay.title = "Toggle Tabbed Column";
      action.toggle-column-tabbed-display = [];
    };

    # ── App launchers (focus-or-spawn) ────────────────────────────
    # Each bind hits the named app's window if one exists (cycling
    # between matches if multiple), else spawns it via niri so the
    # window lands through the same code path as action.spawn. app_id
    # match is case-insensitive exact — covers the Slack/spotify
    # capitalisation drift without per-bind regex.
    #
    # If a launcher fails to find an existing window after launch,
    # check `niri msg --json windows | jq '.[].app_id'` against the
    # --app-id below — Electron apps occasionally drift their app_id
    # across versions and the bind needs a one-letter update.
    "Alt+M" = {
      hotkey-overlay.title = "Focus or Launch Spotify";
      action.spawn = ["focus-or-spawn" "--app-id" "spotify" "--" "spotify"];
    };
    "Alt+O" = {
      hotkey-overlay.title = "Focus or Launch Claude";
      action.spawn = ["focus-or-spawn" "--app-id" "claude-desktop" "--" "claude-desktop"];
    };
    "Alt+W" = {
      hotkey-overlay.title = "Focus or Launch Firefox";
      action.spawn = ["focus-or-spawn" "--app-id" "firefox" "--" "firefox"];
    };
    "Alt+T" = {
      hotkey-overlay.title = "Focus or Launch Kitty";
      action.spawn = ["focus-or-spawn" "--app-id" "kitty" "--" "kitty"];
    };
    "Alt+S" = {
      hotkey-overlay.title = "Focus or Launch Slack";
      action.spawn = ["focus-or-spawn" "--app-id" "slack" "--" "slack"];
    };
    "Alt+C" = {
      hotkey-overlay.title = "Focus or Launch Signal";
      action.spawn = ["focus-or-spawn" "--app-id" "signal" "--" "signal-desktop"];
    };
    "Alt+D" = {
      hotkey-overlay.title = "Focus or Launch Vesktop";
      action.spawn = ["focus-or-spawn" "--app-id" "vesktop" "--" "vesktop"];
    };
    # Zoom is special-cased because its app_id "Zoom" covers many
    # top-levels (hub "Zoom Workplace …", chat, settings, annotate
    # toolbar, screen-share controls). Tier the lookup:
    #   1. In-call video window (title exactly "Meeting") — preferred
    #      target during a call.
    #   2. Hub ("Zoom Workplace …") — has the Join/Start/Schedule UI,
    #      so focusing it is what we want when no meeting is live.
    #   3. Nothing open → gtk-launch the desktop entry. This MUST go
    #      through us.zoom.Zoom.desktop (hosts/gnomon nix.xdg.dataFile)
    #      so the zoom-bypass-zoomlauncher wrapper and any OBS/exec
    #      shimming in that .desktop apply. Direct `flatpak run` would
    #      bypass the wrapper and SIGILL on NVIDIA.
    "Alt+Z" = {
      hotkey-overlay.title = "Focus or Launch Zoom";
      action.spawn = [
        "focus-or-spawn" "--app-id" "Zoom" "--title-regex" "^Meeting$" "--"
        "focus-or-spawn" "--app-id" "Zoom" "--title-regex" "^Zoom Workplace" "--"
        "${pkgs.gtk3}/bin/gtk-launch" "us.zoom.Zoom"
      ];
    };

    # ── DMS shell features ────────────────────────────────────────
    # Mac-style Cmd shortcuts (physical Cmd key → keyd carve-out
    # passes Super raw → niri grabs Super+key). These mirror the
    # universal Mac chord for each feature.
    "Super+Space" = {
      hotkey-overlay.title = "Toggle Application Launcher";
      action.spawn = ["dms" "ipc" "call" "spotlight" "toggle"];
    };
    "Super+Comma" = {
      hotkey-overlay.title = "Toggle Settings";
      action.spawn = ["dms" "ipc" "call" "settings" "toggle"];
    };
    # Cmd+Tab / Cmd+Shift+Tab / Cmd+` / Cmd+Shift+` are handled by
    # niri's built-in `recent-windows` config defaults (Mod+Tab etc.,
    # Mod = Super) — no explicit bind needed here.

    # Aerospace-style Option shortcuts (no Mac convention for these
    # features, so they live alongside the WM binds on Alt).
    "Alt+N" = {
      hotkey-overlay.title = "Toggle Notification Center";
      action.spawn = ["dms" "ipc" "call" "notifications" "toggle"];
    };
    "Alt+P" = {
      hotkey-overlay.title = "Toggle Notepad";
      action.spawn = ["dms" "ipc" "call" "notepad" "toggle"];
    };
    "Alt+X" = {
      hotkey-overlay.title = "Toggle Power Menu";
      action.spawn = ["dms" "ipc" "call" "powermenu" "toggle"];
    };
    "Alt+V" = {
      hotkey-overlay.title = "Toggle Clipboard Manager";
      action.spawn = ["dms" "ipc" "call" "clipboard" "toggle"];
    };
    # Lock and night mode get Ctrl+Alt because the bare-Alt slots are
    # already used (Alt+N = notifications). Lock lands on Q to mirror
    # Mac's Ctrl+Cmd+Q lock convention: physical Alt+Cmd+Q → keyd →
    # Ctrl+Alt+Q reaches niri.
    "Ctrl+Alt+Q" = {
      hotkey-overlay.title = "Lock Screen";
      action.spawn = ["dms" "ipc" "call" "lock" "lock"];
    };
    "Ctrl+Alt+N" = {
      allow-when-locked = true;
      hotkey-overlay.title = "Toggle Night Mode";
      action.spawn = ["dms" "ipc" "call" "night" "toggle"];
    };

    "Alt+Shift+Slash" = {
      hotkey-overlay.title = "Show Hotkeys";
      action.show-hotkey-overlay = [];
    };

    # ── Screenshots ───────────────────────────────────────────────
    # Two parallel bindsets:
    #
    #   Print key (PrtSc): niri's standard screenshot keybinds. Print =
    #     interactive picker (region/window), Ctrl+Print = whole monitor,
    #     Alt+Print = focused window, Shift+Print = region → satty annotate.
    #     The Q6 HE's PrtSc currently emits something other than KEY_SYSRQ
    #     (likely a VIA layer), so these are dormant fallbacks until the
    #     firmware is fixed or another keyboard is attached.
    #
    #   Super+Shift+3/4/5 (Mac-style): mirrors macOS exactly via the
    #     Cmd→Super keyd carve-out, since this config heavily uses Mac
    #     muscle memory elsewhere (Cmd+Space spotlight, Ctrl+Cmd+Q lock).
    #     3 = whole monitor, 4 = niri's interactive picker (analogous to
    #     macOS's Cmd+Shift+4 + Space window-pick combined into one UI),
    #     5 = satty annotation pipeline.
    #
    # All variants write to ~/Pictures/Screenshots and copy to the
    # clipboard. Annotation pipeline lives in `sattyPipeline` (top of file).
    "Print" = {
      hotkey-overlay.title = "Screenshot";
      action.screenshot = [];
    };
    "Ctrl+Print" = {
      hotkey-overlay.title = "Screenshot Monitor";
      action.screenshot-screen = [];
    };
    "Alt+Print" = {
      hotkey-overlay.title = "Screenshot Window";
      action.screenshot-window = [];
    };
    "Shift+Print" = {
      hotkey-overlay.title = "Region Screenshot → Annotate";
      action.spawn = sattyPipeline;
    };

    "Super+Shift+3" = {
      hotkey-overlay.title = "Screenshot Monitor";
      action.screenshot-screen = [];
    };
    "Super+Shift+4" = {
      hotkey-overlay.title = "Screenshot";
      action.screenshot = [];
    };
    "Super+Shift+5" = {
      hotkey-overlay.title = "Region Screenshot → Annotate";
      action.spawn = sattyPipeline;
    };

    # Audio + brightness keys: pass through to DMS for the OSD.
    # allow-when-locked so they keep working on the lock screen.
    "XF86AudioRaiseVolume" = {
      allow-when-locked = true;
      action.spawn = ["dms" "ipc" "call" "audio" "increment" "3"];
    };
    "XF86AudioLowerVolume" = {
      allow-when-locked = true;
      action.spawn = ["dms" "ipc" "call" "audio" "decrement" "3"];
    };
    "XF86AudioMute" = {
      allow-when-locked = true;
      action.spawn = ["dms" "ipc" "call" "audio" "mute"];
    };
    "XF86AudioMicMute" = {
      allow-when-locked = true;
      action.spawn = ["dms" "ipc" "call" "audio" "micmute"];
    };
    "XF86MonBrightnessUp" = {
      allow-when-locked = true;
      action.spawn = ["dms" "ipc" "call" "brightness" "increment" "5" ""];
    };
    "XF86MonBrightnessDown" = {
      allow-when-locked = true;
      action.spawn = ["dms" "ipc" "call" "brightness" "decrement" "5" ""];
    };
  };

  # Niri config that DMS used to write into ~/.config/niri/dms/*.kdl,
  # ported into nix-typed niri-flake settings.
  programs.niri.settings = {
    # Tell xdg-decoration-aware clients we prefer SSD. niri itself draws
    # only a border + focus-ring (no titlebar), so apps that honor this
    # — Electron when on Ozone, GTK, Qt — drop their custom titlebars
    # and the visual stack flattens to just niri's outer ring.
    prefer-no-csd = true;

    # Workspace-switch animation: keep niri's default vertical-slide
    # spring. The spatial cue ("this thing is moving") matters more
    # now that workspaces are rare events — when one DOES happen, the
    # animation should read as travel rather than a flash.

    # From dms/layout.kdl
    layout = {
      gaps = 4;
      background-color = "transparent";

      # Two columns visible per monitor at 50% width. Niri's
      # scrollable-tiling model is built around proportional widths
      # exactly so multiple windows can be visible at once. Alt+R
      # cycles the focused column through 1/3, 1/2, 2/3 if you want
      # to redistribute briefly. Alt+Shift+F maximizes the column;
      # Alt+F fullscreens the window.
      default-column-width.proportion = 0.5;

      # Preset widths cycled by Alt+R. Standard niri progression:
      # one-third, half, two-thirds. Tap repeatedly to walk through.
      preset-column-widths = [
        {proportion = 1.0 / 3.0;}
        {proportion = 1.0 / 2.0;}
        {proportion = 2.0 / 3.0;}
      ];

      # Preset window heights cycled by Alt+Shift+R inside a stacked
      # column. Same shape as widths.
      preset-window-heights = [
        {proportion = 1.0 / 3.0;}
        {proportion = 1.0 / 2.0;}
        {proportion = 2.0 / 3.0;}
      ];

      border = {
        width = 2;
        active.color = "#d0bcff";
        inactive.color = "#948f99";
        urgent.color = "#f2b8b5";
      };

      focus-ring = {
        width = 2;
        active.color = "#d0bcff";
        inactive.color = "#948f99";
        urgent.color = "#f2b8b5";
      };

      # From dms/colors.kdl
      shadow.color = "#00000070";

      # Tab indicator for tabbed columns. Default niri style is a 4px
      # sliver on the column edge that's basically invisible. Bump
      # width and put it across the top so a tabbed column looks like
      # browser tabs — N segments visible, active one highlighted.
      # place-within-column: the indicator renders inside the column's
      # area (eating 12px from the top of the visible window) instead
      # of in the outer workspace gap, which is only 4px wide and
      # would clip the 12px indicator.
      # length.total-proportion = 1.0: tabs span the full column edge.
      tab-indicator = {
        width = 6;
        position = "top";
        place-within-column = true;
        gaps-between-tabs = 2;
        length.total-proportion = 1.0;
        active.color = "#d0bcff";
        inactive.color = "#948f99";
        urgent.color = "#f2b8b5";
      };

      insert-hint.display.color = "#d0bcff80";
    };

    # Universal window-rule (no match clause = applies to every window):
    # 12px corner radius, clipped to geometry, no border-with-background
    # for CSD windows. Per-app routing rules belong in the host module.
    window-rules = [
      {
        geometry-corner-radius = {
          top-left = 12.0;
          top-right = 12.0;
          bottom-left = 12.0;
          bottom-right = 12.0;
        };
        clip-to-geometry = true;
        draw-border-with-background = false;
      }
      # Steam/Proton games: app-id is "steam_app_<numeric>". They often
      # open as floating Xwayland surfaces, which makes niri's
      # fullscreen-window action a no-op (it only fullscreens tiled
      # windows properly) and leaves the universal corner-radius +
      # focus-ring visible. Force them tiled and fullscreen on open;
      # Alt+F still toggles back to windowed if needed.
      {
        matches = [{app-id = "^steam_app_";}];
        open-floating = false;
        open-fullscreen = true;
      }
      # Zoom annotation toolbar: a 112×112 floating xdg_toplevel Zoom
      # spawns alongside the Meeting window when annotation is available
      # (so participant pens can draw on a screen share, even when WE
      # aren't sharing). By default Zoom opens it at center-screen,
      # right where the cursor naturally crosses the Meeting tile —
      # focus-follows-mouse lands on it and Zoom's set_cursor sprite
      # gets sticky, producing the "cursor captured by an invisible
      # button" symptom until a hard focus change (alt-tab) refreshes
      # the cursor.
      #
      # The toolbar's value is real (you want to see participant pen
      # marks), so we keep it open + functional. We just banish it to
      # the bottom-right corner of the workspace where the cursor
      # doesn't camp in normal use. Caveat: default-floating-position
      # only applies at open time. If Zoom programmatically moves the
      # toolbar later (not observed empirically, but possible), niri
      # honors that move and the rule won't re-apply.
      {
        matches = [
          {
            app-id = "^Zoom$";
            title = "^annotate_toolbar$";
          }
        ];
        open-floating = true;
        default-floating-position = {
          x = 20;
          y = 20;
          relative-to = "bottom-right";
        };
      }
    ];

    # From dms/wpblur.kdl — DMS's wallpaper-blur layer surface should
    # render in the niri overview backdrop, not as a regular layer.
    layer-rules = [
      {
        matches = [{namespace = "dms:blurwallpaper";}];
        place-within-backdrop = true;
      }
      # Hide DMS notification popups from screencast captures (Zoom
      # window/screen share, OBS, xdg-desktop-portal-gnome). Notifications
      # still appear locally and still beep; they're just blacked out in
      # the captured stream. Mirrors the existing `block-out-from`
      # window rule, applied to layer-shell namespaces.
      {
        matches = [
          {namespace = "^dms:notification-popup$";}
          {namespace = "^dms:dnd-duration-menu$";}
        ];
        block-out-from = "screencast";
      }
    ];
  };

  # niri-flake doesn't (yet) type a few niri config blocks like
  # `recent-windows` (alt-tab styling). To stay fully declarative we
  # redirect niri-flake's typed config to `niri/hm.kdl` and write our
  # own `niri/config.kdl` that pulls in hm.kdl plus a sibling fragment
  # holding the un-typed bits. Both files end up as HM-managed read-
  # only symlinks into the nix store — same lifecycle as the rest.
  xdg.configFile = {
    niri-config.target = lib.mkForce "niri/hm.kdl";

    "niri/config.kdl".text = ''
      include "hm.kdl"
      include "extras.kdl"
    '';

    # Niri config blocks not yet exposed by niri-flake's typed schema.
    # Niri merges duplicate top-level blocks across `include`d files
    # (each include parses as its own ConfigPart, values accumulate into
    # the shared Config), so a separate `layout {...}` here augments the
    # one niri-flake renders into hm.kdl rather than colliding with it.
    "niri/extras.kdl".text = ''
      // focus-follows-mouse from josh/ffm-edge-deadzone. `edge-deadzone`
      // requires the cursor to be at least N logical pixels from any edge
      // of the candidate window before FFM activates — gates focus on
      // cursor position rather than view-shift, which is what we actually
      // want for the "no accidental focus on edge-brush" semantic that
      // max-scroll-amount was the wrong tool for. The whole block lives
      // here (not in typed settings) because niri-flake's schema doesn't
      // know `edge-deadzone` yet.
      input {
          focus-follows-mouse edge-deadzone=30
      }

      // recent-windows: alt-tab overlay styling. From dms/alttab.kdl
      // (corner-radius) plus the recent-windows section of dms/colors.kdl.
      recent-windows {
          highlight {
              corner-radius 12
              active-color "#4f378b"
              urgent-color "#f2b8b5"
          }
      }

      // Background blur (since niri 26.04). Tuning rule from upstream:
      // bump `offset` first (no GPU cost) until artifacts appear, only
      // then bump `passes` (each pass is a real shader pass).
      blur {
          passes 3
          offset 3
          noise 0.02
          saturation 1.5
      }

      // xray=true blurs only the wallpaper (cheap, default). xray=false
      // blurs whatever is actually beneath the surface — NSVisualEffectView
      // semantics where windows behind show through. Per-frame cost is one
      // BlitFramebuffer + a 6-draw dual-Kawase pyramid: sub-millisecond on
      // modern GPUs. Known niri quirk: non-xray blur disappears briefly
      // during window open/close animations and tile drags (offscreen-FB
      // refactor pending upstream); xray avoids this.

      // kitty terminal — only meaningful with kitty's background_opacity < 1.0.
      // clip-fullscreen-backdrop-to-window opts out of niri's spec-compliant
      // black backdrop behind a non-opaque fullscreen surface so a translucent
      // fullscreen kitty composes against the wallpaper instead of black.
      // This is a downstream-only config option (see josh/fullscreen-backdrop-clip).
      window-rule {
          match app-id="kitty"
          clip-fullscreen-backdrop-to-window true
          background-effect {
              blur true
              xray false
          }
      }

      // Vesktop — Discord client. Pairs with home-manager/vesktop's
      // activation script that flips Vencord's `transparent: true`. With
      // that flag set, Vesktop's BrowserWindow opens with Electron
      // `transparent: true` and a fully-transparent backgroundColor, so
      // anywhere the Discord UI doesn't paint (gaps between message
      // groups, the rounded-corner clip from our universal corner-radius
      // rule) we want a frosted blur of what's behind, not the bare
      // wallpaper. xray=false matches kitty above for the same reason —
      // stacked windows still show through softly instead of flat-cropping
      // to the wallpaper.
      window-rule {
          match app-id="vesktop"
          background-effect {
              blur true
              xray false
          }
      }

      // No Spotify blur rule on purpose: vanilla Spotify's Electron
      // BrowserWindow is opaque (no transparent:true at construction)
      // and Spicetify can't change that — it's a renderer-side mod, not
      // a native Electron one. Adding background-effect blur here would
      // be a no-op against the opaque surface. Revisit only if/when we
      // patch Spotify's app.asar to enable BrowserWindow transparency.

      // DMS chrome blur is entirely driven by DMS's protocol path
      // (BackgroundEffect.blurRegion via ext-background-effect-v1) when
      // settings.blurEnabled = true (see home-manager/dms/default.nix).
      // Niri applies blur to the surface-shaped regions DMS sends; we
      // don't add per-surface layer-rules because:
      //   - Niri can't reshape protocol-set blur regions (only enable/disable).
      //   - Layer-rule blur targets a layer's whole rendered geometry,
      //     which is rectangular and ignores transparency — wrong shape
      //     on rounded modals.
      //   - DMS's design intent IS small surface-shaped frosted glass
      //     on each chrome panel. Fighting it with broad rules introduces
      //     double-blur and z-order artifacts (verified via niri-snap
      //     during 2026-05-08 debugging — see commit 9e30d7c).

      // From the josh/cross-monitor-column-insert patch in our niri fork.
      // Lands cross-monitor moves on the destination edge we arrived from
      // instead of after the destination's active column.
      //
      // From the josh/focus-flash patch in our niri fork. Pulses the focus
      // ring (and a screen-edge frame on fullscreen windows) through
      // `flash-color` on focus arrival. Solves the original problem of
      // fullscreen windows having no focus-change feedback at all.
      //
      // `flash-color` matches DMS's `shaderTertiaryColor` (chrome shader's
      // "highlight peak" hue — see home-manager/dms/default.nix:193). Same
      // semantic role across the desktop: synthwave neon green is the
      // "this is the active highlight" accent. Lerps cleanly off the
      // purple `active.color` and stays out of the urgent-pink lane.
      // 220 ms / 1 pulse: long enough to register on a 144 Hz display,
      // short enough that rapid focus cycling doesn't feel busy.
      layout {
          cross-monitor-column-insert "adjacent"
          focus-flash {
              flash-color "#39FF99"
              pulse-duration-ms 220
              pulses 1
          }
      }
    '';
  };
}
