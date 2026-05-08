{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../desktop-x86_64-linux.nix
  ];

  # Named workspaces for niri + DMS. The niri module turns each role into a
  # `${role}-left` / `${role}-right` workspace pair plus three Mod+letter
  # binds (focus / move window into / send to other monitor's copy). The
  # DMS workspaceLabel plugin uses the same map to render the bar pill.
  # Adding a role here is the only change needed to get all of that.
  #
  # letter: the keyboard key bound under Mod (and Mod+Shift / Mod+Alt).
  #   Most are the role's first letter; chat and claude collide on C, so
  #   claude is on O instead.
  # label: human-readable name shown in the DMS pill *and* in niri's
  #   hotkey-overlay titles ("Focus Terminal", "Move Window to Web").
  _module.args.workspaceRoles = {
    term = {
      letter = "T";
      label = "Terminal";
    };
    web = {
      letter = "W";
      label = "Web";
    };
    music = {
      letter = "M";
      label = "Music";
    };
    slack = {
      letter = "S";
      label = "Slack";
    };
    chat = {
      letter = "C";
      label = "Chat";
    };
    claude = {
      letter = "O";
      label = "Claude";
    };
    zoom = {
      letter = "Z";
      label = "Zoom";
    };
    game = {
      letter = "G";
      label = "Game";
    };
  };

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

  # Caps Lock → Escape (host-local: the laptop has its own keyboard
  # config, this is gnomon's external-keyboard preference).
  programs.niri.settings.input.keyboard.xkb.options = "caps:escape";

  # kitty_mod = Alt on gnomon only. The shared kitty module sets
  # ctrl+shift (Linux convention), but on this Windows-layout keyboard
  # Alt sits at the same physical position-from-spacebar that Cmd
  # occupies on the Mac — so Alt+T/C/V/etc. land where macOS muscle
  # memory expects them. Doesn't help Firefox (Linux apps still want
  # Ctrl+T), but inside kitty itself the layout matches.
  programs.kitty.keybindings."kitty_mod" = lib.mkForce "alt";

  # Monitor positions. Two identical Dell U2724D side-by-side, distinguished
  # only by serial in the EDID name. The niri module is monitor-agnostic —
  # it sorts outputs by `logical.x` at runtime to decide which is "left"
  # and "right" — but niri itself needs explicit positions when there's no
  # other signal, otherwise it picks an arbitrary side-by-side ordering at
  # detection time. Keep this tiny serial→position map here so the niri
  # module never needs to know about specific hardware.
  programs.niri.settings.outputs."Dell Inc. DELL U2724D CDL25Z3".position = {
    x = 0;
    y = 0;
  };
  programs.niri.settings.outputs."Dell Inc. DELL U2724D CBC35Z3".position = {
    x = 2560;
    y = 0;
  };

  # Seeds for the niri-module ambient workspaces. Per-instance routing
  # for kitty uses --class (sets the Wayland app-id), so the window-rules
  # below can match unambiguously. Firefox/Spotify/Slack/Signal/Claude
  # each have exactly one "scratch" instance per workspace, so we route
  # by their default app-id at startup — manually-launched copies later
  # land on the focused workspace as normal.
  programs.niri.settings.spawn-at-startup = [
    # One kitty per side. Use kitty's built-in tabs (Ctrl+Shift+T) for
    # multiple shells inside the same window — niri's full-width
    # default makes a second seeded kitty just scroll off-screen
    # anyway, and kitty's tab UX is good enough that a second window
    # adds little.
    {command = ["kitty" "--class" "scratch-term-left"];}
    {command = ["kitty" "--class" "scratch-term-right"];}
    # Single seed per single-process app. No window-rule pins these
    # to a specific workspace — at startup they land on whichever
    # workspace niri currently has focused. Use Mod+Shift+<letter>
    # after login to drop them onto their named workspace if you want
    # them organized.
    {command = ["firefox"];}
    {command = ["spotify"];}
    {command = ["slack"];}
    {command = ["signal-desktop"];}
    {command = ["claude-desktop"];}
  ];

  # Route windows to their workspaces. Only the per-instance kitty
  # scratches need static routing — the kitties are seeded with
  # explicit `--class scratch-term-{left,right}` so each side gets
  # its own discriminable app-id and lands on the correct named
  # workspace.
  #
  # Other apps (firefox, spotify, slack, signal, claude-desktop, zoom)
  # have no rule. Niri can't dynamically route an app to "{role}-
  # {focused-side}" — window-rules are static and can't condition on
  # focused output — so every routing rule we could write would either
  # force one monitor (annoying) or only catch startup spawns (the
  # at-startup gate misses heavy Electron apps when their first window
  # surfaces > 60s after niri start). Without a rule, every window
  # from these apps lands on the focused workspace at spawn time —
  # which is naturally the focused monitor's workspace, matching the
  # "go to the monitor I'm on" intent. Use Mod+Shift+<letter> to send
  # an existing window into its named workspace if it landed somewhere
  # else.
  programs.niri.settings.window-rules = [
    {
      matches = [{app-id = "^scratch-term-left$";}];
      open-on-workspace = "term-left";
    }
    {
      matches = [{app-id = "^scratch-term-right$";}];
      open-on-workspace = "term-right";
    }
    # Zoom usually stays on XWayland (via xwayland-satellite), where
    # xdg-decoration doesn't apply and prefer-no-csd has no effect — so
    # Zoom keeps drawing its own titlebar regardless. Drop niri's border
    # and focus-ring for this app so we're not stacking a niri frame
    # around Zoom's frame around Zoom's contents. No workspace routing
    # — like the other apps above, zoom lands on the focused workspace.
    {
      matches = [{app-id = "^zoom$";}];
      border.enable = false;
      focus-ring.enable = false;
    }
  ];
}
