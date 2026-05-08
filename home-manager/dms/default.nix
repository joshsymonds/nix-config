{
  config,
  lib,
  workspaceRoles,
  ...
}: {
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

    # Use the standard DMS-IPC keybinds (Mod+Space spotlight, Mod+N
    # notifications, Mod+Comma settings, volume/brightness keys, etc.)
    # via niri-flake's typed `programs.niri.settings.binds`. This is the
    # nix-native path — no on-disk binds.kdl involved.
    niri.enableKeybinds = true;

    # Don't spawn DMS via niri startup — systemd.enable handles it,
    # giving us restart-on-failure.
    niri.enableSpawn = false;

    # Local plugin: single-pill widget showing the friendly name of the
    # bar's monitor's active workspace (e.g. "Terminal", "Web") instead
    # of the multi-pill workspaceSwitcher. Niri requires unique workspace
    # names, so we keep `term-left`/`term-right` and let the plugin map
    # both to "Terminal" — each bar only ever shows its own monitor's
    # active workspace, so the duplicate display label is unambiguous.
    plugins.workspaceLabel = {
      enable = true;
      src = ./plugins/workspaceLabel;
      # `workspaceRoles` comes from the host's `_module.args.workspaceRoles`
      # (see hosts/<host>.nix). Both `-left` and `-right` map to the same
      # label — each bar only shows its own monitor's active workspace, so
      # the duplicate display label is unambiguous.
      settings.labelMap =
        lib.concatMapAttrs (role: {label, ...}: {
          "${role}-left" = label;
          "${role}-right" = label;
        })
        workspaceRoles;
    };

    # The launcher button (Material `apps` 3×3 grid icon at the bar's left
    # edge, opens the app drawer) is always rendered before `leftWidgets`
    # regardless of bar config. We open the launcher with Mod+Space (DMS's
    # spotlight bind) instead, so the button is dead weight.
    settings.showLauncherButton = false;

    # focusedWindow compact mode hides the app-id prefix and renders only
    # the window title. With our scratch terminals named `scratch-term-
    # {left,right}`, the non-compact form prints `scratch-term-left  ·
    # Some Title` — the leading app-id reads like a workspace name. The
    # workspaceLabel pill already covers the "what workspace am I on"
    # need, so we don't want it duplicated here.
    settings.focusedWindowCompactMode = true;

    # Bar layout. `programs.dank-material-shell.settings` is serialized
    # verbatim to ~/.config/DankMaterialShell/settings.json; barConfigs is
    # an array of full bar configurations (DMS supports multiple bars), so
    # we write the whole object — DMS replaces the default array if this
    # key is present. The only departure from the stock default is
    # leftWidgets: workspaceSwitcher → workspaceLabel (our plugin).
    settings.barConfigs = [
      {
        id = "default";
        name = "Main Bar";
        enabled = true;
        position = 0;
        screenPreferences = ["all"];
        showOnLastDisplay = true;
        leftWidgets = ["workspaceLabel" "focusedWindow"];
        centerWidgets = ["music" "clock" "weather"];
        rightWidgets = ["systemTray" "clipboard" "cpuUsage" "memUsage" "notificationButton" "battery" "controlCenterButton"];
        spacing = 4;
        innerPadding = 4;
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
      }
    ];
  };

  # Pick up DMS config changes between HM generations. DMS watches its
  # config files natively (`watchChanges: true` on the FileView in
  # Common/SettingsData.qml) but HM publishes config files by atomically
  # swapping the symlink to a new /nix/store path — Qt's
  # QFileSystemWatcher tracks the resolved inode, so the swap is
  # invisible to the watcher and DMS keeps its stale in-memory state.
  #
  # Two paths:
  #   - plugin_settings.json: hot-reload via the plugins IPC handler
  #     (DMSShellIPC.qml `target: "plugins"; reload(pluginId)`). No unit
  #     restart, no bar flicker — just unload + load of the one plugin.
  #   - settings.json: no IPC reload exists for global settings, so
  #     restart dms.service. Brief bar flicker, only fires when the file
  #     actually changed (cmp -s) so no-op rebuilds stay quiet.
  #
  # Both paths skip silently when DMS isn't running (first boot, manual
  # stop) and on first activation (no `oldGenPath` to diff against).
  home.activation.dmsReloadConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    fileChanged() {
      local rel="$1"
      [[ -v oldGenPath ]] \
        && [ -e "$oldGenPath/home-files/$rel" ] \
        && [ -e "$newGenPath/home-files/$rel" ] \
        && ! cmp -s "$oldGenPath/home-files/$rel" "$newGenPath/home-files/$rel"
    }

    if systemctl --user is-active --quiet dms.service 2>/dev/null; then
      if fileChanged ".config/DankMaterialShell/plugin_settings.json"; then
        XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
          ${config.programs.dank-material-shell.package}/bin/dms ipc plugins reload workspaceLabel \
          >/dev/null 2>&1 || true
      fi
      if fileChanged ".config/DankMaterialShell/settings.json"; then
        systemctl --user restart dms.service >/dev/null 2>&1 || true
      fi
    fi
  '';
}
