{
  lib,
  pkgs,
  inputs,
  ...
}: let
  # 2560×1440 abstract purple hexagons from wallhaven (id dpo38l). Low-
  # contrast and uniform enough that tiled windows don't fight the image,
  # and the purple/magenta palette matches the Material You theme niri
  # uses for borders/focus rings. Pinned by hash so the wallpaper is
  # reproducible across rebuilds and machines.
  wallpaper = pkgs.fetchurl {
    url = "https://w.wallhaven.cc/full/dp/wallhaven-dpo38l.jpg";
    sha256 = "1r3wfg75n7f20kph7i5hgg6af518p8p2bw795953jzcdcvy7m89w";
  };
in {
  # DankMaterialShell home-manager configuration. The DMS edge release
  # made several HM-side feature toggles built-in and no-op (they're now
  # always available): enableNightMode, enableSystemSound, enableClipboard,
  # enableColorPicker, enableBrightnessControl. enableSystemd was renamed
  # to systemd.enable. We only set toggles that still have effect.
  programs.dank-material-shell = {
    enable = true;
    systemd.enable = true;
    enableAudioWavelength = true;
    enableCalendarEvents = true;
    enableClipboardPaste = true;
    enableDynamicTheming = true;
    enableSystemMonitoring = true;
    enableVPN = true;

    # All niri config lives in the niri/ HM module. Disable DMS's runtime
    # "includes" mechanism (the seven dms/*.kdl files DMS writes into
    # ~/.config/niri/ at runtime: alttab, binds, colors, cursor, layout,
    # outputs, windowrules, wpblur). DMS still writes those files at
    # runtime, but niri never reads them — they're orphaned, not config.
    niri.includes.enable = false;

    # DMS's stock binds put spotlight/notifications/settings/clipboard/
    # powermenu under Mod (= Super = the physical Cmd key in Mac mode on
    # the Q6). On gnomon, Super is reserved for keyd's Mac-style Cmd
    # remap (Cmd+C → Ctrl+C, etc.) — see modules/services/keyd.nix —
    # which would translate Mod+Space to Ctrl+Space before DMS ever sees
    # it, breaking every DMS keybind. Disable the auto-injection and
    # re-bind the same features under Alt+ in home-manager/niri/default.nix
    # so they live alongside niri's other Alt-modifier WM binds.
    niri.enableKeybinds = false;

    # Don't spawn DMS via niri startup — systemd.enable handles it,
    # giving us restart-on-failure.
    niri.enableSpawn = false;

    # The launcher button (Material `apps` 3×3 grid icon at the bar's left
    # edge, opens the app drawer) is always rendered before `leftWidgets`
    # regardless of bar config. We open the launcher with Mod+Space (DMS's
    # spotlight bind) instead, so the button is dead weight.
    settings.showLauncherButton = false;

    # focusedWindow compact mode hides the app-id prefix and renders only
    # the window title — without it, the bar reads "kitty · ~/proj" with
    # the app-id prefix that's already obvious from the visible window.
    settings.focusedWindowCompactMode = true;

    # Widget pill chrome uses the darkest matugen-derived surface tone
    # (surfaceContainerLowest) instead of the default surfaceContainerHigh,
    # so each pill reads as a near-black palette-coherent chip against
    # the wallpaper's raised hex platform. "scl" is a new switch entry
    # added in Theme.qml on the chrome-shader fork — stock DMS only
    # recognises "s" / "sc" / "sch" / "sth".
    settings.widgetBackgroundColor = "scl";

    # Wallpaper, set declaratively. DMS persists this in
    # ~/.local/state/DankMaterialShell/session.json under wallpaperPath.
    # `session` is serialized verbatim by the DMS HM module
    # (distro/nix/home.nix:104).
    session.wallpaperPath = "${wallpaper}";

    # Run matugen against the actual wallpaper rather than a stock seed
    # hex. Without this DMS picks Theme.qml:176's stock branch — runs
    # matugen on currentThemeName's hardcoded primary hex (default
    # "purple"), producing a palette where tertiary collapses onto
    # secondary (the M3 generator only differentiates tertiary when
    # given a real source image with chroma variation). "dynamic" picks
    # Theme.qml:167's wallpaper branch — matugen extracts the palette
    # from session.wallpaperPath and generates a distinct tertiary
    # (hue-shifted complement to primary, used by ChromeShader's
    # aurora highlights at chrome_aurora.frag:60).
    settings.currentThemeName = "dynamic";

    # Promote notification popups to WlrLayershell.Overlay so they appear
    # above fullscreen windows (movies, games, full-window terminals). DMS
    # default is false — only Critical-urgency notifications get Overlay,
    # everything else lands on WlrLayershell.Top, which niri (and most
    # layer-shell compositors) hide beneath fullscreen surfaces.
    # Trade-off: anything tagged via libnotify (Slack pings, etc.) will pop
    # over presentations and movies. Worth it for never missing a message.
    # Logic at NotificationPopup.qml:178-180.
    settings.notificationOverlayEnabled = true;

    # Auto-dismiss critical-urgency popups after 15 s. DMS defaults
    # notificationTimeoutCritical to 0, which it treats as "never auto-
    # dismiss" (NotificationService.qml:725 timer + _initWrapperPersistence),
    # so Critical popups otherwise sit on screen until manually cleared.
    # Both the ntfy "needs-you" popups (sent -u critical) and the T-2-min
    # morgen-notifier meeting alert (also -u critical) ride this. Low/
    # normal already auto-dismiss at the 5 s default. The notification
    # still goes to the notification center; this only bounds on-screen
    # dwell. Global to all Critical notifications, but effectively only
    # those two sources send Critical here.
    settings.notificationTimeoutCritical = 15000;

    # Compositor-driven background blur. Master toggle for the
    # ext-background-effect-v1 path: when on, every WindowBlur instance
    # in DMS (BlurService.qml:18 gates on this) sets a per-surface
    # blur_region via Quickshell's BackgroundEffect API, and niri applies
    # blur within those region shapes. This is DMS's designed path for
    # frosted-glass chrome — niri layer-rules can only enable/disable,
    # not reshape, the protocol-set regions, so we let DMS drive shape
    # and niri drive the actual blur.
    settings.blurEnabled = true;

    # Idle / power. DMS's IdleService (Services/IdleService.qml) drives
    # Wayland idle directly via Quickshell's IdleMonitor, so no swayidle
    # needed. Timeouts are in seconds; 0 disables that stage. Defaults
    # are all 0, which leaves a desktop running at ~110W indefinitely.
    #
    # On AC: monitors DPMS-off after 5 min (saves ~50W of backlight,
    # instant wake on input). Suspend-to-RAM is disabled (0) — gnomon
    # should never sleep on its own. Battery keys are irrelevant on
    # gnomon (desktop, no battery) — leave at 0. fadeToDpmsEnabled is
    # already true by default; the screen dims smoothly for
    # fadeToDpmsGracePeriod (5s) before the DPMS-off signal.
    settings.acMonitorTimeout = 300;
    settings.acSuspendTimeout = 0;

    # Bar layout. `programs.dank-material-shell.settings` is serialized
    # verbatim to ~/.config/DankMaterialShell/settings.json; barConfigs is
    # an array of full bar configurations (DMS supports multiple bars), so
    # we write the whole object — DMS replaces the default array if this
    # key is present. leftWidgets is just focusedWindow because we don't
    # use named workspaces — there's no workspace identity to label.
    settings.barConfigs = [
      {
        id = "default";
        name = "Main Bar";
        enabled = true;
        # Position enum (Common/SettingsData.qml:22): 0=Top, 1=Bottom,
        # 2=Left, 3=Right. Left edge of DP-2 (the right-hand monitor,
        # CBC35Z3) puts the bar on the seam between the two displays — the
        # sightline we cross most often — and keeps it visible during
        # fullscreen games, which run on DP-3 (the left monitor, CDL25Z3).
        position = 2;
        screenPreferences = ["DP-2"];
        # Fallback: if DP-2 disconnects and only one screen remains,
        # show the bar on whatever's left rather than vanishing entirely.
        showOnLastDisplay = true;
        leftWidgets = ["claudeCodeUsage" "cpuUsage" "memUsage" "gpuPill" "bandwidthPill"];
        centerWidgets = ["music" "clock" "meetingPill"];
        rightWidgets = ["systemTray" "controlCenterButton"];
        spacing = 4;
        innerPadding = 0;
        bottomGap = 0;
        # transparency = 0 makes the bar's painted Shape (BarCanvas's
        # surfaceContainer-coloured rectangle) fully invisible. The
        # widgets still draw on top, floating directly on the
        # wallpaper, which provides the visual "platform" via the
        # bar-zone elevation in the hexrain shader. widgetTransparency
        # stays at 1 so the icons/text remain fully opaque against
        # whatever the wallpaper happens to be underneath.
        transparency = 0.0;
        widgetTransparency = 1.0;
        squareCorners = false;
        # Keep widget chrome enabled — they need backgrounds to read as
        # discrete chips against the wallpaper. Bar's OWN panel
        # background is killed via `transparency = 0` + `shaderMode =
        # "none"` below; the wallpaper's bar-zone elevation provides
        # the visual platform underneath.
        noBackground = false;
        # Force widget backgrounds to true pill (capsule) shape — radius
        # becomes min(width, height) / 2, so square widgets read as
        # circles and wider ones as stadiums. Custom barConfig key
        # added in DMS BasePill.qml on the chrome-shader fork.
        widgetPill = true;
        # With josh/wider-pills pushing widgetThickness to 36 (in a 40px
        # bar), the default sizing is anemic against the chunkier pills.
        # Icons: maximizeWidgetIcons swaps the icon base from iconSize
        # (24) to iconSizeLarge (32), putting icons at ~22px.
        # Text: instead of maximizeWidgetText (which multiplies by 1.5 →
        # 18px, too aggressive), use fontScale alone for finer control.
        # fontScale=1.4 → fontSizeSmall (12) × 1.4 ≈ 17px, one or two
        # pixels below the maximize result. See Theme.qml barTextSize.
        maximizeWidgetIcons = true;
        maximizeWidgetText = false;
        removeWidgetPadding = false;
        widgetPadding = 8;
        gothCornersEnabled = false;
        gothCornerRadiusOverride = false;
        gothCornerRadiusValue = 12;
        borderEnabled = false;
        borderColor = "surfaceText";
        borderOpacity = 1.0;
        borderThickness = 1;
        widgetOutlineEnabled = false;
        widgetOutlineColor = "primary";
        widgetOutlineOpacity = 1.0;
        widgetOutlineThickness = 1;
        fontScale = 1.3;
        iconScale = 1.0;
        autoHide = false;
        autoHideDelay = 250;
        showOnWindowsOpen = false;
        openOnOverview = false;
        visible = true;
        popupGapsAuto = true;
        popupGapsManual = 4;
        maximizeDetection = true;
        scrollEnabled = true;
        scrollXBehavior = "column";
        scrollYBehavior = "workspace";
        shadowIntensity = 0;
        shadowOpacity = 60;
        shadowColorMode = "default";
        shadowCustomColor = "#000000";
        clickThrough = false;

        # Hand-picked shader background colors, sampled directly from the
        # wallpaper's saturated neon hexagon edges. Matugen's tonal-spot
        # algorithm averages sparse high-chroma pixels away, so its
        # generated palette is muted pastels. The shader's atmospheric
        # aurora effect needs the actual neon to read on screen, so we
        # bypass matugen for the four shader uniforms only — DMS's
        # widget chrome and the rest of Material You theming still use
        # the matugen-derived palette.
        #
        # SettingsStore.js loads barConfigs raw (no per-key spec
        # validation; only top-level unknowns are stripped at line 25).
        # BarCanvas.qml reads `barConfig?.shader<X>Color` and falls back
        # to Theme.<x> when absent.
        #
        # Triadic synthwave palette (cyan + magenta + neon-green) chosen
        # to match the wallpaper's design intent.
        # Mode selector for ChromeShader. ChromeShader.qml's switch
        # falls through to `return ""` for any unknown mode, which makes
        # the ShaderEffect render nothing — exactly what we want here:
        # the bar's own internal shader overlay is disabled, and the
        # wallpaper underneath shows through, with the raised hex strip
        # there providing the visual bar surface. The four shaderColor
        # overrides below become no-ops in this mode but stay in place
        # so flipping shaderMode back to "hexrain"/"aurora" later just
        # works without re-pasting the palette.
        shaderMode = "none";
        shaderHexSize = 14; # inradius per hex (cellSize); hex width = 2*this

        shaderPrimaryColor = "#5896E1"; # cyan band hue
        shaderSecondaryColor = "#B711DB"; # magenta band hue
        shaderPrimaryContainerColor = "#170B55"; # deep purple base in dark zones
        shaderTertiaryColor = "#39FF99"; # neon green highlight peak
      }
    ];

    # DMS plugins. Each attrname becomes a directory under
    # ~/.config/DankMaterialShell/plugins/<name>, populated from `src`.
    # The DMS plugin loader keys off plugin.json:id (not the dir name),
    # but matching the manifest id keeps things grep-friendly.
    #
    # `managePluginSettings = true` is required: it generates
    # ~/.config/DankMaterialShell/plugin_settings.json with `{enabled: true}`
    # per plugin. Without that file DMS treats the plugin as disabled even
    # though its source sits in plugins/. The HM module's default auto-flips
    # this only when at least one plugin has a non-empty `settings` attr,
    # which we don't have a use for here — so set it explicitly.
    managePluginSettings = true;

    # Claude Code subscription usage widget. Source is our personal fork at
    # ~/Personal/dms-claudecode (flake input `dms-claudecode`); upstream is
    # titeya/dms-claudecode. Picks up token burn from ~/.claude/projects
    # and rate-window state from the OAuth token in ~/.claude/.credentials.json.
    #
    # settings.* land in ~/.config/DankMaterialShell/plugin_settings.json,
    # which under managePluginSettings = true is a read-only symlink to a
    # store path — toggles in the DMS plugin settings UI silently no-op,
    # so any non-default value MUST be declared here. The plugin's
    # ToggleSetting widget reads pluginData.<key> via SettingsData, so the
    # name must match the QML settingKey exactly.
    plugins.claudeCodeUsage = {
      src = inputs.dms-claudecode;
      settings.showWorkCostPill = true; # appends today's work spend after the rings
      # Poll the aggregated NFS summaries every 1 min instead of the 2-min
      # default. The Stop hook (claude-code/usage-summary-refresh.sh) keeps
      # those summaries fresh within seconds of remote activity, so a tighter
      # widget poll is what actually surfaces it here without a long wait.
      # NB: 1 is intentionally below the plugin slider's declared minimum of 2
      # (ClaudeCodeUsageSettings.qml). It works because the widget consumes the
      # raw value unclamped ((pluginData.refreshInterval || 2) * 60000); if a
      # future plugin revision adds Math.max(minimum, …) it silently floors
      # back to 2 — harmless, just slower.
      settings.refreshInterval = 1;
    };

    # Network bandwidth pill (RX/TX from /proc/net/dev). Source repo at
    # ~/Personal/dms-bandwidth-pill / github:joshsymonds/dms-bandwidth-pill.
    # Auto-detects the first non-lo interface with traffic; if you want a
    # specific NIC, set `settings.interface = "eno1";` here.
    plugins.bandwidthPill.src = inputs.dms-bandwidth-pill;

    # NVIDIA GPU pill (utilization % + VRAM %). Source repo at
    # ~/Personal/dms-gpu-pill / github:joshsymonds/dms-gpu-pill. Uses
    # nvidia-smi (ships with the proprietary driver on gnomon). Works
    # only with NVIDIA cards; AMD users want a different plugin.
    plugins.gpuPill.src = inputs.dms-gpu-pill;

    # Next-meeting countdown pill. Reads khal (which we already pull
    # in via enableCalendarEvents) → the vdir morgen-fetch populates
    # → Morgen API. Glance widget: icon + "12m" / "2h" / "2d".
    plugins.meetingPill.src = inputs.dms-meeting-pill;
  };

  # Promote DMS modals (spotlight, settings, etc.) to the wlr-layer-shell
  # `Overlay` layer instead of the default `Top`. Niri renders fullscreen
  # windows ABOVE Top (per render_above_top_layer() in
  # src/layout/scrolling.rs:2886-2899), so a fullscreened kitty / Firefox /
  # game would otherwise cover the spotlight when triggered. Overlay is
  # the highest layer-shell tier and renders above fullscreen.
  #
  # DMS reads this env var in DankLauncherV2ModalStandalone.qml:363-376
  # (and the same pattern in other modals). Setting it on the systemd
  # service environment ensures every DMS-spawned surface honors it.
  systemd.user.services.dms.Service.Environment = "DMS_MODAL_LAYER=overlay";

  # Pick up DMS config changes between HM generations. DMS watches its
  # config files natively (`watchChanges: true` on the FileView in
  # Common/SettingsData.qml) but HM publishes config files by atomically
  # swapping the symlink to a new /nix/store path — Qt's
  # QFileSystemWatcher tracks the resolved inode, so the swap is
  # invisible to the watcher and DMS keeps its stale in-memory state.
  #
  # Two recovery paths depending on what changed:
  #   • Plugins: call `qs ipc plugins reload <id>` (DMSShellIPC.qml,
  #     handler at target "plugins"). That calls
  #     PluginService.reloadPlugin = unloadPlugin + loadPlugin, picking
  #     up the new QML in-process without restarting the bar. DMS's own
  #     FolderListModel-based auto-detection (PluginService.qml:72) only
  #     fires on dir entry add/remove and misses symlink retargets, which
  #     is how HM publishes new plugin sources.
  #   • Global settings / session state: no IPC equivalent exists, so we
  #     fall back to restarting dms.service (brief bar flicker).
  #
  # Only fires when the resolved store path / file content actually
  # changed, so no-op rebuilds stay quiet. Skips silently when DMS isn't
  # running and on first activation (no `oldGenPath` to diff).
  home.activation.dmsReloadConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # NixOS-integrated HM runs activation via home-manager-joshsymonds.service.
    # Two gotchas the hook has to handle itself:
    #   1. systemd is NOT in the activation script's PATH (HM only adds it
    #      around its own reloadSystemd block), so a bare `systemctl` call
    #      exits 127 and the surrounding `2>/dev/null` swallows the error,
    #      making the hook silently no-op forever. Use the absolute path.
    #   2. XDG_RUNTIME_DIR isn't set in the sanitized service env;
    #      `systemctl --user` needs it to find the per-user manager bus.
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    QS=${pkgs.quickshell}/bin/qs
    AWK=${pkgs.gawk}/bin/awk

    fileChanged() {
      local rel="$1"
      [[ -v oldGenPath ]] \
        && [ -e "$oldGenPath/home-files/$rel" ] \
        && [ -e "$newGenPath/home-files/$rel" ] \
        && ! cmp -s "$oldGenPath/home-files/$rel" "$newGenPath/home-files/$rel"
    }

    # Find the DMS quickshell instance among potentially many running
    # quickshell processes (the user may also have shader previews etc.).
    # Match on the config path containing `/dms/shell.qml`, which is how
    # the dms-shell package exposes its entry point.
    findDmsInstance() {
      "$QS" list --all 2>/dev/null \
        | "$AWK" '/^Instance / { id = $2; sub(/:$/, "", id) }
               /Config path:.*\/dms\/shell\.qml/ { print id; exit }'
    }

    # For each plugin whose resolved store target differs between
    # generations, ask DMS to reload it via IPC. Brand-new plugins (not
    # present in oldGen) are skipped here — DMS's FolderListModel does
    # detect directory entry additions and auto-loads them.
    reloadChangedPlugins() {
      [[ -v oldGenPath ]] || return 0
      local dir="home-files/.config/DankMaterialShell/plugins"
      [ -d "$newGenPath/$dir" ] || return 0

      local instance
      instance=$(findDmsInstance)
      [ -n "$instance" ] || return 0

      local p name new_target old_p old_target
      for p in "$newGenPath/$dir"/*; do
        [ -e "$p" ] || continue
        name=$(basename "$p")
        new_target=$(readlink -f "$p" 2>/dev/null || true)
        old_p="$oldGenPath/$dir/$name"
        [ -e "$old_p" ] || continue
        old_target=$(readlink -f "$old_p" 2>/dev/null || true)
        if [ -n "$new_target" ] && [ "$old_target" != "$new_target" ]; then
          "$QS" ipc -i "$instance" call plugins reload "$name" \
            >/dev/null 2>&1 || true
        fi
      done
    }

    if $SYSTEMCTL --user is-active --quiet dms.service 2>/dev/null; then
      # Plugins first: hot-reload anything whose source changed.
      reloadChangedPlugins

      # Settings/state files have no IPC reload, so fall back to a full
      # service restart. (Plugin reloads above happen before this, so if
      # both kinds of change land in the same generation, plugins get
      # reloaded twice — once via IPC, once via the restart that follows.
      # Harmless.)
      if fileChanged ".config/DankMaterialShell/settings.json" \
        || fileChanged ".config/DankMaterialShell/plugin_settings.json" \
        || fileChanged ".local/state/DankMaterialShell/session.json"; then
        $SYSTEMCTL --user restart dms.service >/dev/null 2>&1 || true
      fi
    fi
  '';
}
