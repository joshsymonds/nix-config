{lib, ...}: {
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
  ];

  programs.niri.settings.binds = {
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

    # ── Move focused window ───────────────────────────────────────
    # Shift+H/L: move window to the other monitor (cross monitors).
    # Shift+J/K: reorder window within its stacked column.
    "Alt+Shift+H".action.move-window-to-monitor-left = [];
    "Alt+Shift+L".action.move-window-to-monitor-right = [];
    "Alt+Shift+J".action.move-window-down = [];
    "Alt+Shift+K".action.move-window-up = [];

    # ── Reorder columns (the structure itself) ────────────────────
    # Ctrl+H/L: swap the focused column with its neighbor. Different
    # from Shift+H/L (which moves a window across monitors) — these
    # rearrange the column strip without crossing monitors.
    "Alt+Ctrl+H".action.move-column-left = [];
    "Alt+Ctrl+L".action.move-column-right = [];

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
    # I: pull the right neighbor INTO this column, stacking it.
    # O: expel the focused window OUT of this column, into a new
    #    column to the right.
    # T: toggle the focused column between split (all stacked windows
    #    visible at fractional height) and tabbed (only one visible,
    #    J/K to swap) display.
    "Alt+I" = {
      hotkey-overlay.title = "Consume Window into Column";
      action.consume-window-into-column = [];
    };
    "Alt+O" = {
      hotkey-overlay.title = "Expel Window from Column";
      action.expel-window-from-column = [];
    };
    "Alt+T" = {
      hotkey-overlay.title = "Toggle Tabbed Column";
      action.toggle-column-tabbed-display = [];
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
    # Ctrl+Alt+Q reaches niri. Note that Ctrl+Alt+L would collide with
    # the move-column-right bind above (niri treats Alt+Ctrl+L and
    # Ctrl+Alt+L as the same chord regardless of modifier order).
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
      tab-indicator = {
        width = 12;
        position = "top";
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
