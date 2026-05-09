{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.keyd-mac-style;
in {
  options.services.keyd-mac-style = {
    enable = lib.mkEnableOption ''
      keyd-driven Mac-style modifier remap.

      Default behavior: leftmeta/rightmeta (the physical "Cmd" keys, in Mac
      mode on the keyboard) act as Control. So Cmd+C in Firefox/Slack/Electron
      apps becomes Ctrl+C and copies natively. Cmd+T → new tab, Cmd+W → close
      tab, etc., across every Linux GUI app that binds Ctrl+letter.

      Kitty exception: when kitty is the focused window, leftmeta/rightmeta
      pass through as Super unchanged. Kitty's own keymap binds super+c /
      super+v / super+t / etc. (via the shared kitty home-manager module's
      cmd+letter entries — kitty interprets "cmd" as Super on Linux), so
      Cmd+C still copies. Crucially, Ctrl+C and Ctrl+D in kitty are never
      touched by keyd, so they remain raw SIGINT / EOF to the running shell.

      App detection requires keyd-application-mapper, which is enabled as a
      user service alongside the daemon. It uses wlr-foreign-toplevel-
      management-v1 to follow focus changes (verified niri implements it).
    '';
  };

  config = lib.mkIf cfg.enable {
    services.keyd = {
      enable = true;
      keyboards.default = {
        ids = ["*"];

        settings = {
          main = {
            leftmeta = "layer(cmd)";
            rightmeta = "layer(cmd)";
          };

          # Layer body. The `:C` in the section name makes Ctrl the
          # default substitute modifier — pressing leftmeta+anything emits
          # Ctrl+anything, which is what every Linux GUI app expects for
          # its copy/paste/new-tab/etc. shortcuts.
          #
          # The exceptions below override per-key: `M-foo` outputs Super+foo
          # (just M, ignoring the layer's implicit C). Why each one passes
          # through as raw Super:
          #
          #   space, comma — niri grabs Super+Space → DMS spotlight (Mac
          #     Cmd+Space) and Super+Comma → DMS settings (Mac Cmd+Comma).
          #     Carving out preserves real Ctrl+Space (Emacs mark, IDE
          #     autocomplete) and real Ctrl+Comma.
          #   tab, grave — niri's built-in `recent-windows` config has
          #     defaults for Mod+Tab/Mod+Shift+Tab (next/previous window in
          #     MRU order) and Mod+grave/Mod+Shift+grave (same, filtered
          #     to the current app — Mac Cmd+`). Mod = Super by niri
          #     default, so the carve-out lets physical Cmd+Tab and Cmd+`
          #     hit those defaults. Real Ctrl+Tab keeps working in
          #     browsers for "next browser tab".
          "cmd:C" = {
            space = "M-space";
            comma = "M-comma";
            tab = "M-tab";
            grave = "M-grave";
          };
        };

        # App-specific overrides. keyd's `[<class>.<layer>]` form layers on
        # top of the named layer for the matching window class only.
        # keyd-application-mapper feeds the class via niri's wlr-foreign-
        # toplevel-management-v1.
        #
        # Kitty: restore raw passthrough so kitty receives Super+C/V/T/etc.
        # directly. Kitty's keymap binds those (cmd+c → copy_to_clipboard,
        # etc.). Outside kitty, the default [main] still translates Super
        # to Ctrl, so Cmd+C in Firefox keeps working.
        extraConfig = ''
          [kitty.main]
          leftmeta = leftmeta
          rightmeta = rightmeta
        '';
      };
    };

    # User-level service that watches the focused window and tells keyd
    # which app class is active. Required for the [kitty.main] section
    # above to ever take effect — without it, keyd stays in [main] always.
    systemd.user.services.keyd-application-mapper = {
      description = "keyd application context mapper";
      wantedBy = ["graphical-session.target"];
      partOf = ["graphical-session.target"];
      after = ["graphical-session.target"];
      serviceConfig = {
        ExecStart = "${pkgs.keyd}/bin/keyd-application-mapper -d";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
