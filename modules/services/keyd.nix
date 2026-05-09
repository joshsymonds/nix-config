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

          # Empty layer body — the `:C` in the section name is what does the
          # work. While this layer is active (i.e. while leftmeta/rightmeta
          # is held), keyd holds Control on every emitted key, and the Super
          # press is suppressed (the meta keys were reassigned to layer
          # activation, so they no longer send their own scancode).
          "cmd:C" = {};
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
