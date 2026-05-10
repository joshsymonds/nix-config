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

    # Compositor-driven background blur. Master toggle for the
    # ext-background-effect-v1 path: when on, every WindowBlur instance
    # in DMS (BlurService.qml:18 gates on this) sets a per-surface
    # blur_region via Quickshell's BackgroundEffect API, and niri applies
    # blur within those region shapes. This is DMS's designed path for
    # frosted-glass chrome — niri layer-rules can only enable/disable,
    # not reshape, the protocol-set regions, so we let DMS drive shape
    # and niri drive the actual blur.
    settings.blurEnabled = true;

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
        leftWidgets = ["claudeCodeUsage" "focusedWindow"];
        centerWidgets = ["music" "clock" "weather"];
        rightWidgets = ["systemTray" "clipboard" "cpuUsage" "memUsage" "notificationButton" "battery" "controlCenterButton"];
        spacing = 4;
        # innerPadding drives DMS bar/widget thickness via:
        #   widgetThickness    = max(20, 26 + innerPadding * 0.6)
        #   effectiveBarThick. = max(widgetThickness + innerPadding + 4, 40)
        # Bumping to 16 takes the vertical bar from ~40px → ~56px and the
        # widget cross-axis from ~28 → ~36, giving the claudeCodeUsage
        # plugin's two stacked rings (28px each) room to render with
        # legible labels inside them.
        innerPadding = 16;
        bottomGap = 0;
        transparency = 1.0;
        widgetTransparency = 1.0;
        squareCorners = false;
        noBackground = false;
        maximizeWidgetIcons = false;
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
        fontScale = 1.0;
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
        # Mode selector for ChromeShader: "aurora" (drifting plasma veils),
        # "hexrain" (matrix-rain through hex grid, matching wallpaper). Read
        # at BarCanvas.qml via `barConfig?.shaderMode || "aurora"` — flipping
        # this string is a one-line nix-config edit + rebuild, no DMS source
        # change required.
        shaderMode = "hexrain";
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
    plugins.claudeCodeUsage.src = inputs.dms-claudecode;
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
  # No IPC reload exists for global settings, so restart dms.service.
  # Brief bar flicker, only fires when the file actually changed
  # (cmp -s) so no-op rebuilds stay quiet. Skips silently when DMS
  # isn't running and on first activation (no `oldGenPath` to diff).
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

    fileChanged() {
      local rel="$1"
      [[ -v oldGenPath ]] \
        && [ -e "$oldGenPath/home-files/$rel" ] \
        && [ -e "$newGenPath/home-files/$rel" ] \
        && ! cmp -s "$oldGenPath/home-files/$rel" "$newGenPath/home-files/$rel"
    }

    # Compare the resolved store paths of each plugin directory between
    # generations. Each plugin under home-files/.config/DankMaterialShell/
    # plugins/<name> is a symlink into a flake-input store path; when the
    # input bumps, the resolved path changes even though the JSON files
    # don't, so cmp-on-JSON misses it. Added/removed plugins also show up
    # here as a changed listing.
    pluginsChanged() {
      local dir=".config/DankMaterialShell/plugins"
      [[ -v oldGenPath ]] || return 1
      local old new
      old=$([ -d "$oldGenPath/home-files/$dir" ] \
        && (cd "$oldGenPath/home-files/$dir" && for p in *; do [ -e "$p" ] && echo "$p $(readlink -f "$p")"; done | sort) \
        || echo "")
      new=$([ -d "$newGenPath/home-files/$dir" ] \
        && (cd "$newGenPath/home-files/$dir" && for p in *; do [ -e "$p" ] && echo "$p $(readlink -f "$p")"; done | sort) \
        || echo "")
      [ "$old" != "$new" ]
    }

    if $SYSTEMCTL --user is-active --quiet dms.service 2>/dev/null; then
      if fileChanged ".config/DankMaterialShell/settings.json" \
        || fileChanged ".config/DankMaterialShell/plugin_settings.json" \
        || fileChanged ".local/state/DankMaterialShell/session.json" \
        || pluginsChanged; then
        $SYSTEMCTL --user restart dms.service >/dev/null 2>&1 || true
      fi
    fi
  '';
}
