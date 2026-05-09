{
  inputs,
  lib,
  pkgs,
  ...
}: {
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

    # Firefox is the daily driver; chromium is here for WebHID-only sites
    # (gaming-mouse configurators, etc.) since Firefox doesn't implement it.
    chromium

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

  # Propagate to XKB_DEFAULT_OPTIONS so nested compositors (gamescope
  # for Steam/Proton games) rebuild their own xkb keymap with caps:escape
  # too — they don't inherit niri's keymap, just the env vars. niri's
  # `environment` block lands in niri's own env AND gets imported into
  # the systemd user manager, so Steam-launched scopes pick it up.
  programs.niri.settings.environment.XKB_DEFAULT_OPTIONS = "caps:escape";

  # keyd app.conf — per-app modifier overrides read by keyd-application-
  # mapper (set up by modules/services/keyd.nix at the system level).
  # The system config has [main] doing leftmeta = layer(cmd) so Cmd+C →
  # Ctrl+C globally; this override restores raw passthrough when kitty
  # is focused so kitty's own super+c/v/t/etc. binds fire and Ctrl+C/D
  # in the terminal stay raw SIGINT/EOF.
  xdg.configFile."keyd/app.conf".text = ''
    [kitty]
    leftmeta = leftmeta
    rightmeta = rightmeta
  '';

  # Restart keyd-application-mapper when app.conf changes. The mapper
  # reads the file at startup only and doesn't watch for changes, so
  # without this the new override sits on disk but the running mapper
  # keeps the old in-memory rules. Same hm-symlink-vs-watcher dance as
  # the dms.service activation in home-manager/dms/default.nix.
  home.activation.keydReloadAppConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # systemd isn't on the activation script's PATH (HM scopes it to its own
    # reloadSystemd block) — a bare `systemctl` call exits 127 and the
    # surrounding `2>/dev/null` hides it, leaving the hook a silent no-op.
    # See home-manager/dms/default.nix for the same gotcha.
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    fileChanged() {
      local rel="$1"
      [[ -v oldGenPath ]] \
        && [ -e "$oldGenPath/home-files/$rel" ] \
        && [ -e "$newGenPath/home-files/$rel" ] \
        && ! cmp -s "$oldGenPath/home-files/$rel" "$newGenPath/home-files/$rel"
    }
    if $SYSTEMCTL --user is-active --quiet keyd-application-mapper.service 2>/dev/null; then
      if fileChanged ".config/keyd/app.conf"; then
        $SYSTEMCTL --user restart keyd-application-mapper.service >/dev/null 2>&1 || true
      fi
    fi
  '';

  # Monitor positions. Two identical Dell U2724D side-by-side, distinguished
  # only by serial in the EDID name. Niri needs explicit positions when
  # there's no other signal, otherwise it picks an arbitrary side-by-side
  # ordering at detection time.
  #
  # scale = 1.1 nudges every app's effective DPI up ~10% (kitty, browser,
  # gnomon, GTK, Qt). Niri output positions are in *logical* (post-scale)
  # coordinates — at scale 1.1 the 2560-wide panel takes 2328 logical px,
  # so the right monitor sits at x=2328 to stay edge-to-edge.
  programs.niri.settings.outputs."Dell Inc. DELL U2724D CDL25Z3" = {
    scale = 1.1;
    position = {
      x = 0;
      y = 0;
    };
  };
  programs.niri.settings.outputs."Dell Inc. DELL U2724D CBC35Z3" = {
    scale = 1.1;
    position = {
      x = 2328;
      y = 0;
    };
  };

  # Seed the daily-driver apps. They land on whichever workspace niri
  # has focused at startup — no per-app pinning. First boot is messy;
  # arrange once with Mod+Shift+H/L to push windows where you want
  # them, and niri's per-output workspace stickiness keeps them there
  # on subsequent logins. Add open-on-output rules below if the manual
  # arranging gets old.
  programs.niri.settings.spawn-at-startup = [
    {command = ["kitty"];}
    {command = ["firefox"];}
    {command = ["spotify"];}
    {command = ["slack"];}
    {command = ["signal-desktop"];}
    {command = ["claude-desktop"];}
  ];

  programs.niri.settings.window-rules = [
    # Zoom on XWayland (via xwayland-satellite). xdg-decoration doesn't
    # apply there, so prefer-no-csd doesn't reach Zoom — it keeps drawing
    # its own titlebar. Drop niri's border and focus-ring so we're not
    # stacking a niri frame around Zoom's frame around Zoom's contents.
    {
      matches = [{app-id = "^zoom$";}];
      border.enable = false;
      focus-ring.enable = false;
    }
  ];
}
