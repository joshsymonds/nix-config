{
  inputs,
  pkgs,
  ...
}: let
  # Every named "ambient" workspace exists as a -left/-right pair, one
  # per monitor. Mod+<letter> jumps to the focused monitor's copy via
  # the perMonitorWsAction helper in desktop-x86_64-linux.nix; Mod+
  # Shift+<letter> moves the focused window into it.
  rightMonitor = "Dell Inc. DELL U2724D CBC35Z3";
  leftMonitor = "Dell Inc. DELL U2724D CDL25Z3";
in {
  imports = [
    ../desktop-x86_64-linux.nix
  ];

  home.packages = with pkgs; [
    # Gaming auxiliaries (Steam itself is system-level via programs.steam)
    mangohud # in-game FPS/perf overlay
    protontricks # Proton/Wine troubleshooting for specific games
    # If you ever want a non-Steam launcher: heroic or bottles are the
    # modern alternatives to lutris (which we previously had here but
    # removed because lutris's fhsenv pulls in openldap, whose flaky
    # syncreplication test broke gnomon's first install).

    # Communication / media
    slack
    zoom-us
    spotify
    signal-desktop

    # Claude Desktop (the chat app — separate from Claude Code).
    # Sourced from the claude-desktop flake input, which tracks
    # upstream Anthropic releases via daily CI auto-bumps. Use
    # `nix flake update claude-desktop` to pull a newer version.
    # The -fhs variant wraps the Electron app in buildFHSEnv so MCP
    # servers can shell out to npx/uvx/docker as expected.
    inputs.claude-desktop.packages.${pkgs.system}.claude-desktop-fhs
  ];

  # Same signing key vermissian uses — single user identity across machines
  programs.git.settings.user.signingkey = "0x7DD8F05131AEEC3A";

  # Zoom on Wayland. The official client has no native-Wayland mode and
  # hard-codes which "OS" gets to use the Wayland screencast path — niri
  # isn't on the list. Three lines in ~/.config/zoomus.conf flip the
  # behavior:
  #   enableWaylandShare=true   — opt into the Wayland screencast code
  #                               path (otherwise it's Xorg-only)
  #   enableMiniWindow=true     — fix the floating self-view under Wayland
  #   XDG_CURRENT_DESKTOP=gnome — *application-internal* lie that gets
  #                               Zoom past its DE allowlist. Doesn't
  #                               affect the system XDG_CURRENT_DESKTOP
  #                               (still "niri" globally), so portals
  #                               still route via the niri/common section.
  # If screen share still misbehaves, the documented bailout is the
  # us.zoom.Zoom Flatpak (ships with FHS layout that Zoom's hard-coded
  # /usr/share/xdg-desktop-portal/portals/ lookups expect).
  xdg.configFile."zoomus.conf".text = ''
    [General]
    enableWaylandShare=true
    enableMiniWindow=true
    XDG_CURRENT_DESKTOP=gnome
  '';

  programs.niri.settings.input.keyboard.xkb.options = "caps:escape";

  # Monitor layout. Two identical Dell U2724D side-by-side, distinguished
  # only by serial in the EDID name. Left = CDL25Z3 (DP-6), right = CBC35Z3
  # (HDMI-A-2). Owned by nix; DMS no longer includes outputs.kdl (see the
  # niri.includes.filesToInclude override in desktop-x86_64-linux.nix).
  programs.niri.settings.outputs = {
    ${leftMonitor}.position = {
      x = 0;
      y = 0;
    };
    ${rightMonitor}.position = {
      x = 2560;
      y = 0;
    };
  };

  # Pre-populated "ambient" workspaces. Each is a niri named workspace
  # (persistent — does not auto-close when emptied), pinned to a
  # specific monitor, and seeded with one or more apps at niri startup
  # via spawn-at-startup. The Mod+T/W/M/S/C/Z/O binds in the desktop
  # file focus the local-monitor copy by name.
  #
  # Every role has a -left/-right pair. Single-process apps (firefox,
  # spotify, slack, signal, claude-desktop) only seed one window —
  # routed to the -right copy by default. Open another instance manually
  # onto the other side when you want one there; Mod+<letter> from
  # either monitor focuses that monitor's workspace, empty or not.
  programs.niri.settings.workspaces = {
    term-left = {open-on-output = leftMonitor;};
    term-right = {open-on-output = rightMonitor;};
    web-left = {open-on-output = leftMonitor;};
    web-right = {open-on-output = rightMonitor;};
    music-left = {open-on-output = leftMonitor;};
    music-right = {open-on-output = rightMonitor;};
    slack-left = {open-on-output = leftMonitor;};
    slack-right = {open-on-output = rightMonitor;};
    chat-left = {open-on-output = leftMonitor;};
    chat-right = {open-on-output = rightMonitor;};
    claude-left = {open-on-output = leftMonitor;};
    claude-right = {open-on-output = rightMonitor;};
    # Zoom is intentionally not seeded — Zoom is heavy and only useful
    # during calls. Empty workspaces exist on both monitors so Mod+Z
    # always lands somewhere predictable, and any zoom window auto-
    # routes to zoom-right (move it across with Mod+Shift+H if wanted).
    zoom-left = {open-on-output = leftMonitor;};
    zoom-right = {open-on-output = rightMonitor;};
  };

  # Seeds for the ambient workspaces. Per-instance routing for kitty
  # uses --class (sets the Wayland app-id), so the window-rules below
  # can match unambiguously. Firefox/Spotify/Slack/Signal each have
  # exactly one "scratch" instance per workspace, so we route by their
  # default app-id + at-startup matching (only the first 60 seconds of
  # niri lifetime — manually-launched copies later go to the focused
  # workspace as normal).
  programs.niri.settings.spawn-at-startup = [
    # One kitty per side. Use kitty's built-in tabs (Ctrl+Shift+T) for
    # multiple shells inside the same window — niri's full-width
    # default makes a second seeded kitty just scroll off-screen
    # anyway, and kitty's tab UX is good enough that a second window
    # adds little.
    {command = ["kitty" "--class" "scratch-term-left"];}
    {command = ["kitty" "--class" "scratch-term-right"];}
    # Single seed per single-process app — firefox/spotify/slack/signal/
    # claude-desktop each share one app-id across all their windows, so
    # we can't route two seeds to two different workspaces by app-id
    # alone. The window-rules below route the seed to the -right copy;
    # open another instance manually onto the -left side if wanted
    # (Mod+<letter> from the left monitor lands you on it).
    {command = ["firefox"];}
    {command = ["spotify"];}
    {command = ["slack"];}
    {command = ["signal-desktop"];}
    {command = ["claude-desktop"];}
  ];

  # Route windows to their workspaces. App-id values are Wayland
  # xdg-shell app_id strings as reported by niri:
  #   kitty --class FOO  →  app-id = "FOO"
  #   firefox            →  "firefox"
  #   spotify            →  "spotify"
  #   slack              →  "Slack"
  #   signal-desktop     →  "signal"
  #   zoom-us            →  "zoom"
  #   claude-desktop     →  "Claude"
  # All seed apps use at-startup = true so the rule only catches the
  # initial windows at niri startup. Ad-hoc copies opened later (e.g.
  # firefox from clicking a link in kitty, a second slack from
  # spotlight) go to the focused workspace as normal — that's how a
  # second window lands on the -left copy.
  programs.niri.settings.window-rules = [
    {
      matches = [{app-id = "^scratch-term-left$";}];
      open-on-workspace = "term-left";
    }
    {
      matches = [{app-id = "^scratch-term-right$";}];
      open-on-workspace = "term-right";
    }
    {
      matches = [
        {
          app-id = "^firefox$";
          at-startup = true;
        }
      ];
      open-on-workspace = "web-right";
    }
    {
      matches = [
        {
          app-id = "^spotify$";
          at-startup = true;
        }
      ];
      open-on-workspace = "music-right";
    }
    {
      matches = [
        {
          app-id = "^Slack$";
          at-startup = true;
        }
      ];
      open-on-workspace = "slack-right";
    }
    {
      matches = [
        {
          app-id = "^signal$";
          at-startup = true;
        }
      ];
      open-on-workspace = "chat-right";
    }
    {
      matches = [
        {
          app-id = "^Claude$";
          at-startup = true;
        }
      ];
      open-on-workspace = "claude-right";
    }
    # Zoom usually stays on XWayland (via xwayland-satellite), where
    # xdg-decoration doesn't apply and prefer-no-csd has no effect — so
    # Zoom keeps drawing its own titlebar regardless. Drop niri's border
    # and focus-ring for this app so we're not stacking a niri frame
    # around Zoom's frame around Zoom's contents. No at-startup gate
    # here because zoom isn't seeded — every zoom window goes to the
    # right-side copy.
    {
      matches = [{app-id = "^zoom$";}];
      open-on-workspace = "zoom-right";
      border.enable = false;
      focus-ring.enable = false;
    }
  ];
}
