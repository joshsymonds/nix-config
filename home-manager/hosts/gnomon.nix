{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../desktop-x86_64-linux.nix
    ../vesktop
    ../spicetify
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
    # Zoom is installed via nix-flatpak (us.zoom.Zoom) at the system level —
    # see hosts/gnomon/default.nix. The nixpkgs zoom-us build couldn't keep
    # up with portal/screencast quirks on niri.
    # spotify is provided by ../spicetify (a wrapped Spotify with the
    # comfy theme + transparency snippet baked in at build time). Don't
    # add pkgs.spotify here — the wrapper IS the spotify package.
    signal-desktop
    # vesktop is provided by ../vesktop along with its transparent-window
    # settings activation. See that module for why we don't symlink the
    # JSON files declaratively.

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
  #
  # Two non-obvious mechanics:
  #
  # 1. The system config translates Cmd+key → Ctrl+key via rules in the
  #    predefined [meta] layer (a `:M` modifier layer that leftmeta/
  #    rightmeta activate implicitly — that activation is hardcoded in
  #    keyd's modifier handler, NOT a [main] binding you can rebind
  #    away). So a per-app exception has to override the [meta] rules
  #    themselves; `[kitty] leftmeta = leftmeta` is a literal no-op,
  #    since leftmeta still activates [meta] regardless.
  #
  # 2. Section headers in app.conf are `[<class>]` (split on `|`, not
  #    `.`) — keyd-application-mapper does NOT recognize a layer-suffix
  #    syntax in the header. The layer prefix goes on each *binding*
  #    inside, the same `[<layer>.]<key> = <action>` form the `keyd bind`
  #    CLI accepts. So `meta.t = M-t` under `[kitty]` is right;
  #    `t = M-t` under `[kitty.meta]` would silently never match
  #    because the focused-class "kitty" doesn't fnmatch "kitty.meta".
  #
  # For kitty we re-translate every Ctrl-prefixed [meta] rule to use
  # Super (M-) instead, so kitty's own super+c/v/t/etc. binds fire while
  # raw Ctrl+C / Ctrl+D in the terminal stay SIGINT/EOF. Keep this list
  # in sync with `settings.meta` in modules/services/keyd.nix.
  xdg.configFile."keyd/app.conf".text = let
    kittyPassthroughKeys = [
      "a"
      "b"
      "c"
      "d"
      "e"
      "f"
      "g"
      "h"
      "i"
      "j"
      "k"
      "l"
      "m"
      "n"
      "o"
      "p"
      "q"
      "r"
      "s"
      "t"
      "u"
      "v"
      "w"
      "x"
      "y"
      "z"
      "1"
      "2"
      "3"
      "4"
      "5"
      "6"
      "7"
      "8"
      "9"
      "0"
      "left"
      "right"
      "up"
      "down"
      "backspace"
      "enter"
      "minus"
      "equal"
      "leftbrace"
      "rightbrace"
      "semicolon"
      "apostrophe"
      "backslash"
      "dot"
      "slash"
    ];
    kittyMetaOverrides =
      lib.concatMapStringsSep "\n"
      (k: "meta.${k} = M-${k}")
      kittyPassthroughKeys;
  in ''
    [kitty]
    ${kittyMetaOverrides}

    # Firefox: Mac-style tab cycling on Cmd+Shift+]/[. Linux Firefox
    # doesn't bind Ctrl+Shift+]/[ — its tab-cycle shortcuts are Ctrl+Tab
    # / Ctrl+Shift+Tab. Targeting the composite [meta+shift] layer means
    # plain Cmd+] / Cmd+[ keep their existing [meta] translation
    # (Ctrl+]/Ctrl+[) and only the shifted variant cycles tabs. The
    # [meta+shift] layer is declared (empty) in modules/services/keyd.nix.
    [firefox]
    meta+shift.rightbrace = C-tab
    meta+shift.leftbrace = C-S-tab
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
