{lib, ...}: {
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
        position = 0;
        screenPreferences = ["all"];
        showOnLastDisplay = true;
        leftWidgets = ["focusedWindow"];
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
  # No IPC reload exists for global settings, so restart dms.service.
  # Brief bar flicker, only fires when the file actually changed
  # (cmp -s) so no-op rebuilds stay quiet. Skips silently when DMS
  # isn't running and on first activation (no `oldGenPath` to diff).
  home.activation.dmsReloadConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    # NixOS-integrated HM runs activation via home-manager-joshsymonds.service
    # with a sanitized env — no XDG_RUNTIME_DIR, no DBUS_SESSION_BUS_ADDRESS.
    # `systemctl --user` needs the runtime dir to find the user manager.
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

    fileChanged() {
      local rel="$1"
      [[ -v oldGenPath ]] \
        && [ -e "$oldGenPath/home-files/$rel" ] \
        && [ -e "$newGenPath/home-files/$rel" ] \
        && ! cmp -s "$oldGenPath/home-files/$rel" "$newGenPath/home-files/$rel"
    }

    if systemctl --user is-active --quiet dms.service 2>/dev/null; then
      if fileChanged ".config/DankMaterialShell/settings.json"; then
        systemctl --user restart dms.service >/dev/null 2>&1 || true
      fi
    fi
  '';
}
