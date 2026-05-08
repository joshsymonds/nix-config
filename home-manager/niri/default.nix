{
  lib,
  pkgs,
  workspaceRoles,
  ...
}: let
  # `workspaceRoles` comes from the host (see hosts/<host>.nix's
  # `_module.args.workspaceRoles`): an attrset
  #   { <role> = { letter = "X"; label = "Pretty Name"; }; ... }
  # The niri config declares a -left/-right pair per role; the dynamic
  # assignment script (below) attaches each pair to the leftmost / rightmost
  # output at niri startup. Adding a role in the host file is enough to get
  # workspaces, Mod+letter/Mod+Shift+letter/Mod+Alt+letter binds, and the
  # DMS pill label.
  roleNames = lib.attrNames workspaceRoles;

  # Build a map { "term-left" = {}; "term-right" = {}; ... } with no
  # `open-on-output` pinning — we let niri create them on the focused
  # output at startup, then our assignment script moves each to the
  # correct physical monitor.
  workspacePairs =
    lib.concatMapAttrs (role: _: {
      "${role}-left" = {};
      "${role}-right" = {};
    })
    workspaceRoles;

  # Assign workspaces to monitors at runtime by sorting outputs by their
  # logical x position. Whichever output niri places at the lowest x gets
  # all `*-left` workspaces; the highest gets `*-right`. This means the
  # niri module knows nothing about specific monitor identities — swap
  # cables, replace a monitor, the script still produces the right
  # arrangement as long as niri's auto-arrangement (or the host's
  # `outputs.<name>.position` overrides) put them side-by-side correctly.
  #
  # Single-monitor fallback: both `*-left` and `*-right` land on the only
  # output. The Mod+<letter> binds still work — they pick the focused
  # monitor's matching workspace, which is whichever was focused last.
  assignWorkspaces = pkgs.writeShellScript "niri-assign-workspaces" ''
    set -eu
    PATH=${lib.makeBinPath [pkgs.jq pkgs.coreutils]}:$PATH

    # Wait briefly for outputs to be reported. Niri's spawn-at-startup
    # sometimes fires before output enumeration finalizes; one or two
    # 100ms ticks is enough on every machine I've tested.
    for i in 1 2 3 4 5; do
      count=$(niri msg --json outputs | jq 'length')
      [ "$count" -ge 1 ] && break
      sleep 0.1
    done

    sorted=$(niri msg --json outputs | jq -r '
      to_entries
      | map({name: .value.name, x: (.value.logical.x // 0)})
      | sort_by(.x)
      | .[].name
    ')
    left=$(printf '%s\n' "$sorted" | sed -n '1p')
    right=$(printf '%s\n' "$sorted" | sed -n '2p')
    [ -z "$left" ] && exit 0
    [ -z "$right" ] && right="$left"

    move() {
      niri msg action move-workspace-to-monitor --reference "$1" "$2" >/dev/null 2>&1 || true
    }

    ${lib.concatMapStringsSep "\n" (role: ''
        move "${role}-left" "$left"
        move "${role}-right" "$right"
      '')
      roleNames}
  '';

  # Helper for Mod+T / Mod+W / Mod+M / etc. (every per-monitor named-
  # workspace bind): pick the named workspace whose name starts with
  # `prefix` and lives on the focused monitor, then run a niri action
  # against it.
  perMonitorWsAction = prefix: action: ''
    focused=$(niri msg --json focused-output | jq -r .name)
    ws=$(niri msg --json workspaces | jq -r --arg out "$focused" --arg prefix "${prefix}" '.[] | select(.output == $out and ((.name // "") | startswith($prefix))) | .name' | head -1)
    [ -n "$ws" ] && niri msg action ${action} "$ws"
  '';

  # Same as perMonitorWsAction, but targets the named workspace with
  # the given prefix on the OTHER monitor. Used by the Mod+Alt+<letter>
  # binds to fling the focused window from (e.g.) zoom-right onto
  # zoom-left in one keystroke, without changing focus monitor.
  crossMonitorWsAction = prefix: action: ''
    focused=$(niri msg --json focused-output | jq -r .name)
    other=$(niri msg --json outputs | jq -r --arg cur "$focused" 'to_entries[] | .value | select(.name != $cur) | .name' | head -1)
    [ -z "$other" ] && exit 0
    ws=$(niri msg --json workspaces | jq -r --arg out "$other" --arg prefix "${prefix}" '.[] | select(.output == $out and ((.name // "") | startswith($prefix))) | .name' | head -1)
    [ -n "$ws" ] && niri msg action ${action} "$ws"
  '';

  # Per-role binds: Mod+<letter> focuses, Mod+Shift+<letter> moves the
  # focused window into, Mod+Alt+<letter> sends it to the OTHER monitor's
  # copy. roleBinds builds all three for one role; perRoleBinds folds them
  # together across every role.
  roleBinds = role: {
    letter,
    label,
  }: {
    "Mod+${letter}" = {
      hotkey-overlay.title = "Focus ${label}";
      action.spawn-sh = perMonitorWsAction "${role}-" "focus-workspace";
    };
    "Mod+Shift+${letter}" = {
      hotkey-overlay.title = "Move Window to ${label}";
      action.spawn-sh = perMonitorWsAction "${role}-" "move-window-to-workspace";
    };
    "Mod+Alt+${letter}" = {
      hotkey-overlay.title = "Send Window to Other ${label}";
      action.spawn-sh = crossMonitorWsAction "${role}-" "move-window-to-workspace";
    };
  };

  perRoleBinds = lib.concatMapAttrs roleBinds workspaceRoles;
in {
  # niri-flake's HM module is auto-loaded by its NixOS module when
  # home-manager is detected — no explicit import needed (and an
  # explicit import here would duplicate `programs.niri.finalConfig`).
  # The DMS niri HM module is imported once at the desktop layer.

  # Every named workspace declared, no monitor pinning. The startup
  # script attaches them to physical monitors after niri comes up.
  programs.niri.settings.workspaces = workspacePairs;

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

  programs.niri.settings.input.focus-follows-mouse.enable = true;

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

  programs.niri.settings.spawn-at-startup = [
    {command = ["xwayland-satellite" ":0"];}
    {command = ["${assignWorkspaces}"];}
  ];

  programs.niri.settings.binds =
    {
      "Mod+Q" = {
        hotkey-overlay.title = "Close Window";
        action.close-window = [];
      };

      # General terminal spawn. Lands a fresh kitty in the focused
      # workspace (default app-id "kitty", so the scratch routing rules
      # don't catch it).
      "Mod+Return" = {
        hotkey-overlay.title = "Open Terminal";
        action.spawn = ["kitty"];
      };

      # Focus motion. Niri's per-monitor layout is a horizontal scrolling
      # strip of columns; each column may stack multiple windows; each
      # monitor has its own vertical stack of workspaces (= macOS
      # "spaces"). H/L walk columns and hop to the next monitor when the
      # current monitor is exhausted; J/K walk stacked windows in the
      # focused column and fall through to the previous/next workspace
      # when the stack is exhausted. Niri keeps exactly one empty trailing
      # workspace per monitor and auto-creates/collapses as needed, so
      # "down past the last workspace" lands you on a fresh one without
      # ever piling up extras.
      "Mod+H".action.focus-column-or-monitor-left = [];
      "Mod+L".action.focus-column-or-monitor-right = [];
      "Mod+J".action.focus-window-or-workspace-down = [];
      "Mod+K".action.focus-window-or-workspace-up = [];

      # Move the focused window between monitors. Mirrors the H/L focus
      # binds: same direction, plus Shift to mean "take this window with
      # me." `move-window-to-monitor-*` moves the focused window only;
      # if you want to drag a stacked column wholesale, swap to
      # `move-column-to-monitor-{left,right}`.
      "Mod+Shift+H".action.move-window-to-monitor-left = [];
      "Mod+Shift+L".action.move-window-to-monitor-right = [];

      # DMS's enableKeybinds claims Mod+M for the process-list toggle.
      # We override with mkForce so our music-workspace focus wins, and
      # relocate the process list to Mod+Ctrl+M. Mod+Shift+M and
      # Mod+Alt+M for the music role flow through perRoleBinds below
      # without needing mkForce — DMS doesn't claim those.
      "Mod+M" = lib.mkForce perRoleBinds."Mod+M";
      "Mod+Ctrl+M" = {
        hotkey-overlay.title = "Toggle Process List";
        action.spawn = ["dms" "ipc" "processlist" "toggle"];
      };
    }
    # All per-role binds except Mod+M (handled with mkForce above).
    // (lib.filterAttrs (k: _: k != "Mod+M") perRoleBinds);

  # Niri config that DMS used to write into ~/.config/niri/dms/*.kdl,
  # ported into nix-typed niri-flake settings.
  programs.niri.settings = {
    # Tell xdg-decoration-aware clients we prefer SSD. niri itself draws
    # only a border + focus-ring (no titlebar), so apps that honor this
    # — Electron when on Ozone, GTK, Qt — drop their custom titlebars
    # and the visual stack flattens to just niri's outer ring.
    prefer-no-csd = true;

    # Workspace switches default to a vertical-slide spring, which tells a
    # spatial story: workspaces are stacked, you're traveling between
    # adjacent ones. Our workspace model is the opposite — named roles
    # (term/web/music/...) reached directly by Mod+<letter>, not by stack
    # position. ease-out-expo front-loads ~80% of the motion into the
    # first ~20% of the duration, so visually the destination workspace
    # is already in place with a tiny settle at the end — reads as
    # "appeared" rather than "slid in." 100ms is short enough to flash
    # by, long enough to confirm the bind fired.
    animations.workspace-switch.kind.easing = {
      duration-ms = 100;
      curve = "ease-out-expo";
    };

    # From dms/layout.kdl
    layout = {
      gaps = 4;
      background-color = "transparent";

      # New windows take the full screen width. niri's scrollable-
      # tiling model treats a workspace as an infinite horizontal
      # strip — extra columns scroll off rather than auto-shrinking
      # siblings, so 0.5 mostly hurts (you only ever see two windows
      # at once, neither full-size). 1.0 leans into the model: each
      # window full-size, Mod+H/L pans between them. Resize on the
      # fly with Mod+R if you want a smaller column.
      default-column-width.proportion = 1.0;

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

      tab-indicator = {
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
    ];

    # From dms/wpblur.kdl — DMS's wallpaper-blur layer surface should
    # render in the niri overview backdrop, not as a regular layer.
    layer-rules = [
      {
        matches = [{namespace = "dms:blurwallpaper";}];
        place-within-backdrop = true;
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
    "niri/extras.kdl".text = ''
      // recent-windows: alt-tab overlay styling. From dms/alttab.kdl
      // (corner-radius) plus the recent-windows section of dms/colors.kdl.
      recent-windows {
          highlight {
              corner-radius 12
              active-color "#4f378b"
              urgent-color "#f2b8b5"
          }
      }
    '';
  };
}
