{pkgs, ...}: let
  # Pin every singleton "ambient" workspace (web, music, slack, chat) to
  # the right monitor so the left stays the primary workspace area.
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
  ];

  # Same signing key vermissian uses — single user identity across machines
  programs.git.settings.user.signingkey = "0x7DD8F05131AEEC3A";

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
  # via spawn-at-startup. The Mod+T/W/M/S/C binds in the desktop file
  # focus these by name.
  #
  # Two terminals, one per monitor (Mod+T = current monitor's). Web /
  # music / slack / chat are singletons on the right monitor — Mod+W/M
  # /S/C is monitor-agnostic since there's only one of each.
  programs.niri.settings.workspaces = {
    term-left = {open-on-output = leftMonitor;};
    term-right = {open-on-output = rightMonitor;};
    web = {open-on-output = rightMonitor;};
    music = {open-on-output = rightMonitor;};
    slack = {open-on-output = rightMonitor;};
    chat = {open-on-output = rightMonitor;};
    # Zoom is intentionally not seeded — Zoom is heavy and only useful
    # during calls. The empty workspace is here so Mod+Z always lands
    # somewhere predictable, and any zoom window auto-routes here.
    zoom = {open-on-output = rightMonitor;};
  };

  # Seeds for the ambient workspaces. Per-instance routing for kitty
  # uses --class (sets the Wayland app-id), so the window-rules below
  # can match unambiguously. Firefox/Spotify/Slack/Signal each have
  # exactly one "scratch" instance per workspace, so we route by their
  # default app-id + at-startup matching (only the first 60 seconds of
  # niri lifetime — manually-launched copies later go to the focused
  # workspace as normal).
  programs.niri.settings.spawn-at-startup = [
    {command = ["kitty" "--class" "scratch-term-left"];}
    {command = ["kitty" "--class" "scratch-term-left"];}
    {command = ["kitty" "--class" "scratch-term-right"];}
    {command = ["kitty" "--class" "scratch-term-right"];}
    {command = ["firefox"];}
    {command = ["firefox"];}
    {command = ["spotify"];}
    {command = ["slack"];}
    {command = ["signal-desktop"];}
  ];

  # Route windows to their workspaces. App-id values are Wayland
  # xdg-shell app_id strings as reported by niri:
  #   kitty --class FOO  →  app-id = "FOO"
  #   firefox            →  "firefox"
  #   spotify            →  "spotify"
  #   slack              →  "Slack"
  #   signal-desktop     →  "signal"
  #   zoom-us            →  "zoom"
  # Firefox uses at-startup = true so the rule only catches the seed
  # instances at niri startup; ad-hoc firefox windows opened later
  # (e.g. from clicking a link in kitty) go to the focused workspace
  # as normal. Singletons (spotify/slack/signal/zoom) have no at-
  # startup gate — every window from those apps belongs in its named
  # workspace regardless of when it spawned.
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
      open-on-workspace = "web";
    }
    {
      matches = [{app-id = "^spotify$";}];
      open-on-workspace = "music";
    }
    {
      matches = [{app-id = "^Slack$";}];
      open-on-workspace = "slack";
    }
    {
      matches = [{app-id = "^signal$";}];
      open-on-workspace = "chat";
    }
    {
      matches = [{app-id = "^zoom$";}];
      open-on-workspace = "zoom";
    }
  ];
}
