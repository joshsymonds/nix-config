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
    ../qbittorrent
    ../calendar
    ../claude-code/transcripts.nix
    ../claude-code/aggregator.nix
    ../ntfy-notify
    ../savecraftd
  ];

  # Watch this gaming box's game saves (Satisfactory et al.) and push parsed
  # state to Savecraft. Links to the production account; the daemon logs a
  # pairing URL on first run.
  services.savecraftd = {
    enable = true;
    server = "production";
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
    # Zoom is installed via nix-flatpak (us.zoom.Zoom) at the system level —
    # see hosts/gnomon/default.nix. The nixpkgs zoom-us build couldn't keep
    # up with portal/screencast quirks on niri. The flatpak's ZoomLauncher
    # binary aborts in libQt6Core during init on our NVIDIA-on-niri stack
    # (confirmed 2026-05-11 — SIGABRT at libQt6Core+0xbced0 in 6 consecutive
    # launches); the xdg.dataFile entry below shadows the desktop entry to
    # bypass ZoomLauncher entirely and exec /app/extra/zoom/zoom directly,
    # which lets Qt auto-pick libqwayland-generic and works cleanly.

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

    # Morgen — unified calendar across Google Workspace + Microsoft 365
    # business accounts. Native Linux binary (Electron, but real), talks
    # Microsoft Graph + Entra ID directly so no DavMail bridge needed.
    # 14-day full-feature trial; paid after.
    morgen

    # Firefox is the daily driver; chromium is here for WebHID-only sites
    # (gaming-mouse configurators, etc.) since Firefox doesn't implement it.
    chromium

    # Claude Desktop (the chat app — separate from Claude Code).
    # Packaging (flake-input sourcing, fhs wrap, scroll-anchoring fix)
    # lives in overlays/default.nix; this is just the per-host opt-in.
    # `nix flake update claude-desktop` still pulls a newer upstream.
    claude-desktop

    # Obsidian — Markdown notes / vaults. The headless flavor on
    # ultraviolet (hosts/ultraviolet/services/obsidian.nix) is a
    # separate, Xvfb-driven daemon for Sync; this is the native
    # GUI you actually click on.
    obsidian

    # Video player. mpv only — lightweight, plays anything, and the one
    # thing that handles HDR + 10-bit cleanly on Wayland-NVIDIA without
    # ginger workarounds. VLC was kept as an "ad-hoc fallback" but both
    # decode through libavcodec, so VLC almost never plays what mpv can't;
    # the real fix for a stubborn file is an mpv flag, not a second player.
    # `nix shell nixpkgs#vlc` covers the rare disc/IPTV case on demand.
    (mpv.override {
      scripts = with pkgs.mpvScripts; [
        uosc # modern OSC: bottom-bar timeline, sidebar menus
        thumbfast # hover-preview thumbnails for the timeline
      ];
    })

    # Image viewer. qimgv (Qt) — true gallery: thumbnail panel + folder
    # navigation + smooth zoom. Without this, image/* falls through to
    # chromium (no explicit default → browser wins by sort order), which
    # is what cosmic-files was handing pictures to. video/* stays on mpv;
    # the xdg.mimeApps block below only claims image types for qimgv.
    qimgv

    # GUI file manager. cosmic-files (System76, iced/libcosmic) — Wayland-
    # native, no GNOME/KDE deps, distinctive Pop-style look. Picked over
    # Nautilus (drags in the GNOME platform; FileChooser portal is already
    # pinned to gtk in modules/desktop/niri.nix so we don't need it) and
    # Thunar (lighter but visually dated GTK3). Lives in nixpkgs proper —
    # the upstream lilyinstarlight/nixos-cosmic flake is stale (last touch
    # July 2025, still ships pre-stable alpha.6) so we don't use it.
    cosmic-files

    # Trash reaper. cosmic-files has no "delete permanently" / disable-trash
    # config (only Shift+Delete), so plain Delete silently accumulates in
    # ~/.local/share/Trash forever — there is no DE here to age it out. The
    # freedesktop trash spec mandates no daemon and no retention; that's a
    # per-DE bolt-on we don't get on bare niri. gtrash (Go, single static
    # binary, actively maintained — picked over the dormant Python autotrash
    # and the slow Python trash-cli) does spec-correct age/size pruning. Run
    # from the systemd user timer at the bottom of this file. No `rm` alias:
    # cosmic-files stays the only thing that trashes; the terminal still
    # deletes for real.
    gtrash
  ];

  # Same signing key vermissian uses — single user identity across machines
  programs.git.settings.user.signingkey = "0x7DD8F05131AEEC3A";

  # Gnomon-only Claude skill: research-first methodology for Steam-on-Linux
  # debugging. Born from the PRAGMATA debacle (commit 6251c4c) where ~10
  # hours of fork patches turned out to be unnecessary; the actual fix was
  # a game CLI flag findable in 15 minutes of community research. The
  # skill enforces the 6-source checklist before any shim patching. Lives
  # in host-skills/ rather than skills/ because the trigger surface (Steam
  # games on Linux) only exists on gnomon — no point loading it on the
  # mac, headless servers, or vermissian.
  programs.claudeCode.extraSkills.debugging-linux-games =
    ../claude-code/host-skills/debugging-linux-games;

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
    Linux gaming + GPU workstation. Steam/Proton (native Wayland), 1Password GUI,
    Bluetooth controllers/headphones. The RTX 5070 Ti makes this the local
    CUDA / inference box. The 9800X3D is tuned for game latency, not parallel
    throughput.
  '';

  # Caps Lock → Escape is handled by keyd at the evdev layer (see
  # modules/services/keyd.nix, capslock = esc in [main]), NOT xkb. An
  # xkb-level caps:escape only rewrites the keysym, which raw-input games
  # (Steam/Proton) bypass — so it never reached them. keyd rewrites the
  # actual key event upstream of niri and the games.

  # keyd app.conf — per-app overrides read by keyd-application-mapper
  # (set up by modules/services/keyd.nix). The global remap there is
  # static: corner Ctrl key → Alt, Option → Super, Cmd → Ctrl. That keeps
  # the GUI desktop Mac-correct (Cmd+C → Ctrl+C natively) and gives
  # bare-Proton games clean Ctrl (Cmd key) + Alt (corner) with niri living
  # only on the Super keysym (the Option key), which games never press.
  #
  # kitty needs the *terminal* to stay Mac-correct, so we swap Alt↔Ctrl
  # back inside kitty only: the corner key returns to Ctrl (so Ctrl+C
  # SIGINT, Ctrl+D EOF and every other control char work wholesale — no
  # per-key send_key remapping), and the Cmd key becomes Alt so kitty's own
  # alt+c/alt+v/alt+t binds copy/paste/new-tab. Alt is the only free
  # terminal lane: Ctrl is SIGINT, Super is niri. Option stays Super
  # (unstated → inherits its [main] binding).
  #
  # These are plain [main] per-app rebinds, NOT overrides of a predefined
  # layer, so the old "rebinding leftmeta in [main] is a no-op for the
  # [meta] layer" caveat no longer applies — there is no [meta] layer.
  # Section headers are `[<class>]`, fnmatched against the focused window's
  # app_id (split on `|`), so `[kitty]` matches the kitty window class.
  xdg.configFile."keyd/app.conf".text = ''
    [kitty]
    leftcontrol = layer(control)
    leftmeta = layer(alt)
    rightcontrol = layer(control)
    rightmeta = layer(alt)
    # Tab story inside kitty, where the swap inverts Ctrl/Alt: the corner key
    # is Ctrl, the Cmd key is Alt. Override the global [control] tab = M-tab
    # back to Ctrl+Tab so the corner key tab-cycles kitty (kitty.conf binds
    # ctrl+tab → next_tab); route the Cmd key (Alt here) to Super+Tab so it
    # still drives niri's window switcher. Mirrors the desktop behaviour by
    # physical key despite the inverted modifiers.
    control.tab = C-tab
    control+shift.tab = C-S-tab
    alt.tab = M-tab
    alt+shift.tab = M-S-tab

    # Firefox: Mac-style tab cycling. The user's Cmd+Shift+]/[ muscle memory
    # arrives here as Ctrl+Shift+]/[ (Cmd → Ctrl globally), which Firefox
    # doesn't bind. Translate to Firefox's native Ctrl+Tab / Ctrl+Shift+Tab.
    # Targets the [control+shift] composite layer (declared in
    # modules/services/keyd.nix); plain Cmd+]/[ keep their Ctrl+]/[ meaning.
    #
    # alt.tab / alt+shift.tab: the corner key (= Alt outside kitty) tab-cycles
    # Firefox via its native Ctrl+Tab / Ctrl+Shift+Tab. The Cmd key (= Ctrl)
    # is untouched here so it falls through to the global [control] tab = M-tab
    # rule → Super+Tab → niri window switcher.
    [firefox]
    control+shift.rightbrace = C-tab
    control+shift.leftbrace = C-S-tab
    alt.tab = C-tab
    alt+shift.tab = C-S-tab
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

  # Spotify private sink. Spotify on Linux is wired so its in-app
  # volume slider also moves the system's default sink — and the
  # natural counter (pipewire-pulse's `block-sink-volume` quirk) was
  # tested on PipeWire 1.6.3 here and didn't block the path this
  # spicetify-Comfy build uses. Static `context.modules` declarations
  # would work but require restarting pipewire.service to load, which
  # hard-crashed Zoom (and would break any other live audio session).
  #
  # Instead: run pw-loopback as a userspace systemd service. It
  # creates a virtual sink "spotify-sink" with `media.class=Audio/Sink`
  # and bridges it to whatever the current default sink is — same
  # graph topology as the module-loopback approach but loaded into
  # its own process, so starting/stopping it doesn't touch any
  # other client's connection.
  #
  # Routing Spotify to spotify-sink is done one-time via
  # `wpctl set-target <spotify-stream-id> <spotify-sink-id>`;
  # wireplumber's stream-restore persists that target in
  # ~/.local/state/wireplumber so it survives reboots and Spotify
  # restarts. No declarative routing rule because every declarative
  # alternative requires either a pipewire-pulse restart (disrupts
  # all other pulse clients) or a wireplumber restart at a bad time.
  #
  # The loopback's playback side has no node.target → follows whatever
  # sink is default, so switching from Katana to HDMI to DualSense
  # Just Works without touching this config.
  systemd.user.services.pw-loopback-spotify = let
    runLoopback = pkgs.writeShellScript "pw-loopback-spotify" ''
      exec ${pkgs.pipewire}/bin/pw-loopback \
        --channel-map='[FL,FR]' \
        --capture-props='node.name=spotify-sink node.description="Spotify" media.class=Audio/Sink' \
        --playback-props='node.name=spotify-sink-loopback node.description="Spotify → Default"'
    '';
  in {
    Unit = {
      Description = "Spotify private sink (loopback to default output)";
      After = ["wireplumber.service"];
      Requires = ["wireplumber.service"];
    };
    Service = {
      ExecStart = "${runLoopback}";
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install.WantedBy = ["default.target"];
  };

  # Hide the SB Katana V2X's "capture" source from PipeWire. The Katana
  # V2X is a USB soundbar — its capture endpoint is a loopback of the
  # internal mix, not a real microphone. WirePlumber was picking it as
  # the default source, so Zoom (and any "use default" app) was treating
  # the soundbar's own playback as the mic input. Symptoms: voice was
  # ghostly-quiet, and the echo canceller (correctly seeing speaker
  # output on the mic) suppressed it entirely whenever anyone else
  # spoke. With this source hidden, the C920 webcam mic becomes the
  # only real default-source candidate (DualSense controller mic is
  # rarely connected and lower priority).
  #
  # node.name regex matches any Katana V2X analog source regardless of
  # the serial-number suffix in the alsa-USB id, so this rule survives
  # a replacement unit without manual fixup. Only the source side is
  # affected — the matching playback sink (Katana speakers) is
  # untouched and stays the default output.
  #
  # No activation-restart of wireplumber here: bouncing the audio
  # stack mid-session breaks active streams (Zoom, browser, etc.).
  # Takes effect on next login / reboot, or run
  # `systemctl --user restart wireplumber.service` manually when not
  # on a call.
  xdg.configFile."wireplumber/wireplumber.conf.d/50-disable-katana-source.conf".text = ''
    monitor.alsa.rules = [
      {
        matches = [
          {
            node.name = "~^alsa_input\\.usb-Creative_Technology_Ltd_SB_Katana_V2X_.*"
          }
        ]
        actions = {
          update-props = {
            node.disabled = true
          }
        }
      }
    ]
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

  # Proton/game env defaults (PROTON_USE_WAYLAND, NVAPI, vkd3d/dxvk iGPU
  # filter) live in the proton-cachyos user_settings.py baked by the gaming
  # overlay (overlays/default.nix), NOT here. They were previously set as niri
  # session env vars on the theory that niri import-environment'd them to
  # Steam — it doesn't, and Steam isn't spawned from niri's env anyway, so
  # they never reached Proton games (the game ran on XWayland, not winewayland).
  # Per-game override still works via Steam launch options, e.g.
  # `PROTON_USE_WAYLAND=0 %command%`.

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
    # Pin Steam/Proton games to the leftmost monitor (the gaming monitor,
    # CDL25Z3 at x=0). Native-Wayland Proton games capture the FPS camera
    # with a oneshot zwp_locked_pointer; moving such a window across outputs
    # (meta+shift+h/l) transiently drops pointer focus, which destroys the
    # oneshot lock — niri's follow-the-window cursor warp doesn't re-arm it,
    # so the cursor escapes and clicks stop registering. Opening games on the
    # monitor we actually play on sidesteps the cross-output move entirely.
    # Every Steam title reports app-id steam_app_<id> (Satisfactory = 526870).
    {
      matches = [{app-id = "^steam_app_";}];
      open-on-output = "Dell Inc. DELL U2724D CDL25Z3";
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
    stickyDaemon = "${inputs.niri-float-sticky.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/niri-float-sticky";
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
      # Force Qt onto native Wayland (default Zoom flatpak honors $XDG_SESSION_TYPE
      # via QT_QPA_PLATFORM only if the env var actually reaches inside the sandbox,
      # and flatpak's bwrap swallows host env unless explicitly forwarded with --env=).
      # GDK_BACKEND covers Zoom's embedded Chromium-shell (ZoomWebviewHost). Cursor
      # behavior is materially better on Wayland: the XWayland path through
      # xwayland-satellite has a cursor-warp pathway we haven't isolated that
      # captures the cursor near floating Zoom helpers (annotate_toolbar etc.);
      # native Wayland sidesteps it. Screen-share still works via the Wayland
      # screencast portal (xdp + josh/zoom-screencast-fix's SHM fallback).
      flatpak run \
        --env=QT_QPA_PLATFORM=wayland \
        --env=GDK_BACKEND=wayland \
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

  # MIME defaults, poked imperatively into ~/.config/mimeapps.list. That
  # file is a live, app-written surface — Firefox, claude-cli, vesktop,
  # perimeter81 etc. register their own handlers there via "set as
  # default" flows. Home-manager's declarative xdg.mimeApps would replace
  # the whole file with a read-only store symlink, regressing every
  # handler not re-declared and freezing out app self-registration. So we
  # only poke the specific keys we own and leave the file writable.
  #
  # Zoom: the shadowed us.zoom.Zoom.desktop handles zoommtg:// and
  # zoomus://. Both the flatpak's exported entry and our shadowing one
  # declare these MimeTypes, so xdg-open can't pick without an explicit
  # default — `xdg-mime query default` returns empty and Firefox's "Open
  # Zoom?" prompt does nothing. Slack works without this because only one
  # slack.desktop declares its scheme. Desktop-file lookup resolves
  # "us.zoom.Zoom.desktop" to ~/.local/share/applications/ first (XDG
  # precedence), so it points at the zoomLauncher wrapper above, not the
  # Flatpak's broken ZoomLauncher.
  #
  # Images: qimgv for the raster set it actually decodes well — mirrors
  # qimgv.desktop's declared MimeType list (minus video/webm, mpv keeps
  # video) plus tiff. Without this, image/* falls through to chromium.
  # SVG is left alone so it stays with the browser.
  #
  # Video: mpv. Unlike Firefox (which self-asserts as default browser on
  # launch and so is self-healing), mpv has no "set as default" flow and
  # never self-registers — without this pin, a fresh install or a wiped
  # mimeapps.list drops video/* through to chromium, the same latent bug
  # images had. Firefox's scheme/html defaults are deliberately NOT pinned
  # here: the app owns them and codifying would just be drift-prone dupe.
  home.activation.mimeDefaults = lib.hm.dag.entryAfter ["writeBoundary"] ''
    run ${pkgs.xdg-utils}/bin/xdg-mime default us.zoom.Zoom.desktop x-scheme-handler/zoommtg
    run ${pkgs.xdg-utils}/bin/xdg-mime default us.zoom.Zoom.desktop x-scheme-handler/zoomus
    run ${pkgs.xdg-utils}/bin/xdg-mime default qimgv.desktop \
      image/jpeg image/png image/gif image/bmp image/webp image/tiff
    run ${pkgs.xdg-utils}/bin/xdg-mime default mpv.desktop \
      video/mp4 video/x-matroska video/webm video/quicktime video/x-msvideo
  '';

  # Trash retention: prune anything trashed >7 days ago, once a day. 7 (vs
  # the GNOME/KDE-conventional 30) because nothing here cares about the
  # trash — a tighter bound keeps silent disk use low and the recovery
  # window short by intent. `prune --day` reads each entry's .trashinfo
  # DeletionDate, so it's correct regardless of which tool trashed it.
  # `-f` is belt-and-suspenders: gtrash already skips the confirm prompt
  # when stdin isn't a TTY (i.e. under systemd), but stating it is clearer
  # than relying on that. Oneshot so `systemctl --user status` surfaces
  # the last run's exit code.
  systemd.user.services.gtrash-prune = {
    Unit.Description = "Prune freedesktop trash entries older than 7 days";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.gtrash}/bin/gtrash prune --day 7 -f";
    };
  };

  # OnCalendar+Persistent (not a monotonic OnUnitActiveSec timer): gnomon
  # sleeps/powers off, so a missed daily run must catch up on next boot
  # rather than silently never firing — same reasoning as the morgen-fetch
  # timer in home-manager/calendar.
  systemd.user.timers.gtrash-prune = {
    Unit.Description = "Daily freedesktop trash prune";
    Timer = {
      OnCalendar = "daily";
      Unit = "gtrash-prune.service";
      Persistent = true;
    };
    Install.WantedBy = ["timers.target"];
  };
}
