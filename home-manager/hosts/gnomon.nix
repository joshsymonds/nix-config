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
    ../obs
    inputs.lazycam.homeManagerModules.default
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
    # up with portal/screencast quirks on niri. The flatpak's ZoomLauncher
    # binary aborts in libQt6Core during init on our NVIDIA-on-niri stack
    # (confirmed 2026-05-11 — SIGABRT at libQt6Core+0xbced0 in 6 consecutive
    # launches); the xdg.dataFile entry below shadows the desktop entry to
    # bypass ZoomLauncher entirely and exec /app/extra/zoom/zoom directly,
    # which lets Qt auto-pick libqwayland-generic and works cleanly.

    # OBS Studio + lazycam-related scenes live in ../obs (imported
    # above) — that module ships the wrapped OBS package, the
    # declarative scene collection, and global.ini with the WebSocket
    # server enabled. Don't add pkgs.obs-studio here.
    # spotify is provided by ../spicetify (a wrapped Spotify with the
    # comfy theme + transparency snippet baked in at build time). Don't
    # add pkgs.spotify here — the wrapper IS the spotify package.
    signal-desktop
    # vesktop is provided by ../vesktop along with its transparent-window
    # settings activation. See that module for why we don't symlink the
    # JSON files declaratively.

    # Todoist desktop client — Electron wrapper around the web app. The
    # native Linux app from Doist (Flatpak/Snap-only) and todoist-electron
    # are functionally equivalent; nixpkgs only carries the Electron one.
    todoist-electron

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

  programs.claudeCode.hostContext = ''
    # Host: gnomon (Linux NixOS, x86_64)

    You are on `gnomon`. This is a **Linux NixOS** host — not macOS, not
    another machine in the fleet.

    ## Hardware
    - AMD Ryzen 7 9800X3D — 8 cores (SMT off → 8 threads), Zen 5 + 96 MB V-Cache
    - 64 GB RAM
    - NVIDIA RTX 5070 Ti, 16 GB VRAM, CUDA 12.0 (Blackwell sm_120)
    - ~1.9 TB encrypted NVMe root
    - niri + DankMaterialShell desktop, Wayland, lanzaboote-signed boot

    ## Role
    Linux gaming + GPU workstation. Steam/Proton (gamescope), 1Password GUI,
    Bluetooth controllers/headphones. The RTX 5070 Ti makes this the local
    CUDA / inference box. The 9800X3D is tuned for game latency, not parallel
    throughput.
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
  # scale = 1.0: native pixel mapping, sharpest possible at this ~108 PPI.
  # Avoids the wp-fractional-scale path and XWayland bilinear downscale
  # that fractional scales (1.1, 1.25, …) impose. Tradeoff: smaller UI.
  # Output positions are in *logical* (post-scale) coordinates, so at 1.0
  # the right monitor sits at x=2560 to stay edge-to-edge.
  #
  # variable-refresh-rate = true: the U2724D advertises Adaptive-Sync up
  # to 120Hz on DP and the RTX 5070 Ti drives it cleanly.
  programs.niri.settings.outputs."Dell Inc. DELL U2724D CDL25Z3" = {
    scale = 1.0;
    variable-refresh-rate = true;
    position = {
      x = 0;
      y = 0;
    };
  };
  programs.niri.settings.outputs."Dell Inc. DELL U2724D CBC35Z3" = {
    scale = 1.0;
    variable-refresh-rate = true;
    position = {
      x = 2560;
      y = 0;
    };
  };

  programs.niri.settings.window-rules = [
    # Zoom on XWayland (via xwayland-satellite). xdg-decoration doesn't
    # apply there, so prefer-no-csd doesn't reach Zoom — it keeps drawing
    # its own titlebar. Drop niri's border and focus-ring so we're not
    # stacking a niri frame around Zoom's frame around Zoom's contents.
    # Capital-Z is what xwayland-satellite reports as app-id, confirmed via
    # `niri msg windows` 2026-05-11 — the lowercase form never matched.
    {
      matches = [{app-id = "^Zoom$";}];
      border.enable = false;
      focus-ring.enable = false;
    }
    # Zoom popups (annotate_toolbar, leave/end-meeting confirmation
    # dialogs, share-screen pickers, etc.) all register as separate
    # XWayland top-levels but Zoom designs them as transient floating
    # overlays. Under niri's tiling layout each one becomes a full-tile
    # window — annotate_toolbar in particular renders fully transparent
    # pre-annotation, showing up as a "ghost column" the cursor reveals
    # on hover. Float everything under app-id Zoom *except* the two
    # legitimate top-levels (the Workplace home and the Meeting view),
    # which we want tiled normally.
    {
      matches = [{app-id = "^Zoom$";}];
      excludes = [
        {title = "^Zoom Workplace";}
        {title = "^Meeting$";}
      ];
      open-floating = true;
    }
  ];

  # Shadow the flatpak's us.zoom.Zoom.desktop entry. The flatpak's wrapper
  # at /app/bin/zoom execs /app/extra/zoom/ZoomLauncher, a stripped binary
  # that probes the session and sets QT_QPA_PLATFORM / LD_LIBRARY_PATH
  # before invoking the real ./zoom. On our NVIDIA-on-niri stack that
  # probe path SIGABRTs in libQt6Core+0xbced0 during init (6/6 launches
  # 2026-05-11, all the same offset). Running /app/extra/zoom/zoom
  # directly bypasses ZoomLauncher; Qt then auto-picks libqwayland-generic
  # and the client comes up cleanly. ~/.local/share/applications takes
  # precedence over /var/lib/flatpak/exports/share/applications in XDG
  # lookup order, so this entry wins for both menu launches and zoommtg://
  # URL handlers without needing to disable the flatpak's exports.
  #
  # Wrapper script (not inline Exec=) because the freedesktop Exec= field
  # parser is finicky about embedded shell quoting — defining the command
  # once in writeShellScript sidesteps escaping entirely. The wrapper
  # uses flatpak's --file-forwarding @@u "$@" @@ syntax so zoommtg://
  # URIs from xdg-open still get sandboxed-translated correctly.
  xdg.dataFile."applications/us.zoom.Zoom.desktop".text = let
    # niri-float-sticky daemon: pins floating Zoom popups (annotate toolbar,
    # share toolbar, participant mini-tile, leave/end dialogs — anything
    # niri's window-rules float above) to the user's focused workspace
    # across monitor switches. Niri has no native sticky-across-workspaces;
    # this is the gap-filler. `-app-id '^Zoom$'` scopes the daemon to only
    # touch Zoom's own popups, never other apps. `-allow-moving-to-foreign-
    # monitors` is what makes the "follow me when I switch monitors" part
    # actually work (without it, sticky windows stay on their birth monitor).
    stickyDaemon = "${inputs.niri-float-sticky.packages.${pkgs.system}.default}/bin/niri-float-sticky";
    zoomLauncher = pkgs.writeShellScript "zoom-bypass-zoomlauncher" ''
      # Spawn the sticky daemon in the background, then run Zoom in the
      # foreground. When Zoom (`flatpak run`) exits, the EXIT trap kills
      # the daemon — tracking *Zoom's lifecycle* not Zoom's window count,
      # which sidesteps the "Zoom helper subprocess exits but main is
      # alive" races. Daemon stderr is dropped; pass --debug here when
      # iterating.
      ${stickyDaemon} -app-id '^Zoom$' -allow-moving-to-foreign-monitors 2>/dev/null &
      STICKY_PID=$!
      trap 'kill $STICKY_PID 2>/dev/null || true' EXIT
      flatpak run \
        --branch=stable \
        --arch=x86_64 \
        --command=sh \
        --file-forwarding \
        us.zoom.Zoom \
        -c 'cd /app/extra/zoom && exec ./zoom "$@"' \
        zoom @@u "$@" @@
    '';
  in ''
    [Desktop Entry]
    Name=Zoom
    Comment=Zoom Video Conference
    GenericName=Zoom Client for Linux
    Exec=${zoomLauncher} %U
    Icon=us.zoom.Zoom
    Terminal=false
    Type=Application
    StartupNotify=true
    Categories=Network;InstantMessaging;VideoConference;Telephony;
    MimeType=x-scheme-handler/zoommtg;x-scheme-handler/zoomus;x-scheme-handler/tel;x-scheme-handler/callto;x-scheme-handler/zoomphonecall;application/x-zoom
    X-KDE-Protocols=zoommtg;zoomus;tel;callto;zoomphonecall;
    StartupWMClass=zoom
    X-Flatpak-Tags=proprietary;
    X-Flatpak=us.zoom.Zoom
  '';

  # lazycam — on-demand v4l2loopback producer gating. Daemon watches
  # /dev/video10 (the v4l2loopback device declared in
  # hosts/gnomon/default.nix) and asks OBS to switch scenes via
  # WebSocket v5 (127.0.0.1:4455) when consumers attach/detach. The
  # privacy payoff is the hardware LED: OBS only holds /dev/video0
  # while the "Active" scene is the program scene, so leaving Zoom /
  # Meet / etc. genuinely releases the camera and turns the LED off.
  #
  # Requires a one-time OBS scene-collection setup: two scenes named
  # "Active" (containing a Video Capture Device source against
  # /dev/video0) and "Standby" (no camera source — image, color, or
  # placeholder). OBS WebSocket server enabled in Tools → WebSocket
  # Server Settings → Enable.
  services.lazycam = {
    enable = true;
    # All other options take their module defaults:
    # - device      = /dev/video10
    # - obsUrl      = ws://127.0.0.1:4455
    # - sceneActive = "Active"
    # - sceneStandby= "Standby"
    # - stateSocket = null → daemon picks $XDG_RUNTIME_DIR/lazycam.sock
    # - dryRun      = false (genuinely contact OBS)
    # - debug       = false
  };
}
