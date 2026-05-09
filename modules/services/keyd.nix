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

      Per-app exceptions go in ~/.config/keyd/app.conf (managed by the user's
      home-manager — see home-manager/hosts/<host>.nix). The kitty exception
      lives there: when kitty is the focused window, leftmeta/rightmeta pass
      through as Super unchanged so kitty's own super+c / super+v / super+t /
      etc. binds fire while Ctrl+C and Ctrl+D in kitty stay raw SIGINT/EOF
      to the running shell.

      App detection requires keyd-application-mapper, enabled as a user
      service alongside the daemon. It reads ~/.config/keyd/app.conf, then
      watches the focused window via wlr-foreign-toplevel-management-v1
      (niri implements that protocol) and pokes keyd's IPC socket on
      changes.
    '';

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["joshsymonds"];
      description = ''
        Users to add to the `keyd` group. Members of that group can talk
        to keyd's IPC socket (/run/keyd.socket), which is required for
        keyd-application-mapper to push focused-window changes. Without
        this, the per-app overrides in ~/.config/keyd/app.conf never
        activate and keyd stays in the default [main] layer always.
      '';
    };
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
      };
    };

    # keyd group + membership. nixpkgs' services.keyd doesn't create
    # the group; we do it here so keyd's own logic kicks in: when the
    # `keyd` group exists, the daemon setgid()'s into it at startup
    # AND chowns/chmods /run/keyd.socket to root:keyd 0660 itself —
    # no ExecStartPost dance needed.
    users.groups.keyd = {};
    users.users = lib.genAttrs cfg.users (_: {
      extraGroups = ["keyd"];
    });

    # nixpkgs hardens services.keyd four different ways that all block
    # keyd's setgid() into the keyd group at startup. All four have to
    # be relaxed:
    #   - NoNewPrivileges=true — setgid counts as a privilege gain.
    #   - RestrictSUIDSGID=true — outright bans the syscall.
    #   - CapabilityBoundingSet — must include CAP_SETGID; nixpkgs only
    #       allows CAP_SYS_NICE + CAP_IPC_LOCK.
    #   - SystemCallFilter=~@privileged — blacklists setgid because
    #       @privileged covers it.
    # Upstream keyd's own systemd unit applies none of these. The
    # daemon runs as root regardless (raw /dev/input access, CAP_SYS_NICE,
    # CAP_IPC_LOCK), so loosening these flags doesn't meaningfully
    # change the security posture.
    systemd.services.keyd.serviceConfig = {
      NoNewPrivileges = lib.mkForce false;
      RestrictSUIDSGID = lib.mkForce false;
      CapabilityBoundingSet = lib.mkForce [
        "CAP_SYS_NICE"
        "CAP_IPC_LOCK"
        "CAP_SETGID"
      ];
      SystemCallFilter = lib.mkForce [
        "nice"
        "@system-service"
        # Dropped the "~@privileged" entry that nixpkgs adds — that
        # filter blacklists setgid (it's in the @privileged group).
      ];
    };

    # User-level service that reads ~/.config/keyd/app.conf, watches the
    # focused window, and tells keyd via IPC. Without this running, the
    # app.conf overrides never activate.
    systemd.user.services.keyd-application-mapper = {
      description = "keyd application context mapper";
      wantedBy = ["graphical-session.target"];
      partOf = ["graphical-session.target"];
      after = ["graphical-session.target"];
      serviceConfig = {
        # NOT -d: that flag forks and exits, which systemd interprets as
        # the service finishing. Run in foreground so systemd tracks the
        # actual mapper process and Restart= works.
        ExecStart = "${pkgs.keyd}/bin/keyd-application-mapper";
        # The mapper shells out to `keyd bind reset ...` whenever the
        # focused app changes. systemd user services start with a
        # minimal PATH that doesn't include the keyd package, so without
        # this the subprocess.run() raises FileNotFoundError on every
        # focus switch.
        Environment = "PATH=${pkgs.keyd}/bin";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
