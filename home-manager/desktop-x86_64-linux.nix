{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  # Helper for Mod+T / Mod+Shift+T (and similar per-monitor named-
  # workspace binds): pick the named workspace whose name starts with
  # `prefix` and lives on the focused monitor, then run a niri action
  # against it.
  perMonitorWsAction = prefix: action: ''
    focused=$(niri msg --json focused-output | jq -r .name)
    ws=$(niri msg --json workspaces | jq -r --arg out "$focused" --arg prefix "${prefix}" '.[] | select(.output == $out and ((.name // "") | startswith($prefix))) | .name' | head -1)
    [ -n "$ws" ] && niri msg action ${action} "$ws"
  '';
in {
  imports = [
    ./common.nix
    # niri-flake's HM module is auto-loaded by its NixOS module when
    # home-manager is detected (conditional import based on options ?
    # home-manager). Explicitly importing it here creates a duplicate-
    # declaration error for programs.niri.finalConfig. Don't.
    inputs.dms.homeModules.dank-material-shell
    inputs.dms.homeModules.niri
  ];

  home = {
    homeDirectory = "/home/joshsymonds";

    packages = with pkgs; [
      firefox
      file
      unzip
      gcc

      # Terminal/editor font — kitty asks for "Maple Mono NF CN" and the
      # Nerd Font glyphs (icons, powerline separators in tmux/starship,
      # devicons in helix) live in the NF-CN variant. Without this, kitty
      # silently falls back to a sans-serif and Nerd Font codepoints
      # render as boxes. Same package the macOS config installs.
      maple-mono.NF-CN-unhinted
    ];
  };

  # `update` alias mirrors the headless base's pattern
  programs.zsh.shellAliases.update = "nh os switch ${config.home.homeDirectory}/nix-config";

  systemd.user.startServices = "sd-switch";

  # DMS home-manager configuration. The DMS edge release made several of the
  # HM-side feature toggles built-in and no-op (they're now always available):
  # enableNightMode, enableSystemSound, enableClipboard, enableColorPicker,
  # enableBrightnessControl. enableSystemd was renamed to systemd.enable.
  # We only set the toggles that still have effect.
  programs.dank-material-shell = {
    enable = true;
    systemd.enable = true;
    enableAudioWavelength = true;
    enableCalendarEvents = true;
    enableClipboardPaste = true;
    enableDynamicTheming = true;
    enableSystemMonitoring = true;
    enableVPN = true;

    # All niri config lives in nix. We disable DMS's runtime "includes"
    # mechanism (the seven dms/*.kdl files DMS writes into ~/.config/niri/
    # at runtime: alttab, binds, colors, cursor, layout, outputs,
    # windowrules, wpblur) and instead set everything via niri-flake's
    # typed `programs.niri.settings`. DMS still writes those files at
    # runtime, but niri never reads them — they're orphaned, not config.
    niri.includes.enable = false;

    # Use the standard DMS-IPC keybinds (Mod+Space spotlight, Mod+N
    # notifications, Mod+Comma settings, volume/brightness keys, etc.)
    # via niri-flake's typed `programs.niri.settings.binds`. This is the
    # nix-native path — no on-disk binds.kdl involved.
    niri.enableKeybinds = true;

    # Don't spawn DMS via niri startup — systemd.enable handles it,
    # giving us restart-on-failure. (The earlier eval-error workaround
    # that needed enableSpawn = true is no longer triggered now that
    # `programs.niri.settings.layout.border` is fully materialized in
    # nix below — DMS's `fixes` block can dereference `.enable` safely.)
    niri.enableSpawn = false;
  };

  # Window-management keybinds. DMS's enableKeybinds only injects the
  # DMS-IPC binds (spotlight, notifications, audio/brightness keys, etc.)
  # — niri itself ships nothing by default, so close-window/quit/etc.
  # have to be declared here.
  # Key repeat — niri's stock 600ms delay / 25Hz rate is sluggish for
  # backspace/arrow-key-heavy use. Tuning toward what macOS exposes via
  # `defaults write -g InitialKeyRepeat 12 KeyRepeat 1` (the common
  # Mac power-user fast-fast preset).
  programs.niri.settings.input.keyboard.repeat-delay = 200;
  programs.niri.settings.input.keyboard.repeat-rate = 50;

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
  programs.niri.settings.environment.DISPLAY = ":0";
  programs.niri.settings.spawn-at-startup = [
    {command = ["xwayland-satellite" ":0"];}
  ];

  programs.niri.settings.binds = {
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

    # Scratch workspace navigators. Each pre-populated workspace
    # follows a `<role>-<side>` naming convention (term-left,
    # term-right, web-left, web-right, music). T/W look up the named
    # workspace pinned to the focused monitor and jump there; M jumps
    # to the single shared "music" workspace.
    #
    # The lookup uses niri IPC instead of hard-coding monitor names so
    # the same bind set works on any host with the same workspace
    # naming. Per-host pinning + spawn-at-startup live in the host
    # file (e.g. home-manager/hosts/gnomon.nix).
    # Focus the ambient workspace.
    "Mod+T" = {
      hotkey-overlay.title = "Focus Terminal Workspace";
      action.spawn-sh = perMonitorWsAction "term-" "focus-workspace";
    };
    "Mod+W" = {
      hotkey-overlay.title = "Focus Web Workspace";
      action.focus-workspace = "web";
    };
    # Override DMS's enableKeybinds Mod+M (process list) with our music
    # workspace. Process list is relocated to Mod+Ctrl+M so Mod+Shift+M
    # is free for the move-window-to-music bind below.
    "Mod+M" = lib.mkForce {
      hotkey-overlay.title = "Focus Music";
      action.focus-workspace = "music";
    };
    "Mod+Ctrl+M" = {
      hotkey-overlay.title = "Toggle Process List";
      action.spawn = ["dms" "ipc" "processlist" "toggle"];
    };
    "Mod+S" = {
      hotkey-overlay.title = "Focus Slack";
      action.focus-workspace = "slack";
    };
    "Mod+C" = {
      hotkey-overlay.title = "Focus Chat (Signal)";
      action.focus-workspace = "chat";
    };
    "Mod+Z" = {
      hotkey-overlay.title = "Focus Zoom";
      action.focus-workspace = "zoom";
    };

    # Mac-style Mod+Shift+<workspace-id> moves the focused window to
    # that workspace. Mirrors the focus binds above.
    "Mod+Shift+T" = {
      hotkey-overlay.title = "Move Window to Terminal Workspace";
      action.spawn-sh = perMonitorWsAction "term-" "move-window-to-workspace";
    };
    "Mod+Shift+W" = {
      hotkey-overlay.title = "Move Window to Web";
      action.move-window-to-workspace = "web";
    };
    "Mod+Shift+M" = {
      hotkey-overlay.title = "Move Window to Music";
      action.move-window-to-workspace = "music";
    };
    "Mod+Shift+S" = {
      hotkey-overlay.title = "Move Window to Slack";
      action.move-window-to-workspace = "slack";
    };
    "Mod+Shift+C" = {
      hotkey-overlay.title = "Move Window to Chat";
      action.move-window-to-workspace = "chat";
    };
    "Mod+Shift+Z" = {
      hotkey-overlay.title = "Move Window to Zoom";
      action.move-window-to-workspace = "zoom";
    };
  };

  # Niri config that DMS used to write into ~/.config/niri/dms/*.kdl,
  # ported into nix-typed niri-flake settings.
  programs.niri.settings = {
    # From dms/layout.kdl
    layout = {
      gaps = 4;
      background-color = "transparent";

      # New windows take half the screen width by default. (niri's
      # built-in default — when this option is the empty `{}` — is the
      # first entry of preset-column-widths, which currently leaves
      # newly opened windows looking small.)
      default-column-width.proportion = 0.5;

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

    # From dms/layout.kdl — universal window-rule (no match clause
    # = applies to every window): 12px corner radius, clipped to
    # geometry, no border-with-background for CSD windows.
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
