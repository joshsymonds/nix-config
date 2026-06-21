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
      keyd-driven static Mac-style modifier remap (gnomon).

      Physical bottom-left keycaps in Mac mode are [Ctrl][Option][Cmd][Space].
      keyd statically remaps the EMITTED modifier per physical key so the
      desktop keeps Mac muscle memory while bare-Proton games get clean,
      reliable Ctrl+Alt:

        corner Ctrl key -> Alt    (games' Alt modifier; GUI menu mnemonics)
        Option          -> Super  (niri's sole modifier: Option+M = Spotify)
        Cmd (by space)  -> Ctrl   (Cmd+C -> Ctrl+C copies natively)

      This is fully static: no Cmd->Ctrl translation layer, no tap/hold
      overload, no game-mode toggle, and no dependence on detecting a
      focused game. It works for bare-Proton (XWayland) games — which
      cannot use the Wayland keyboard-shortcuts-inhibit protocol — precisely
      because niri binds only the Super keysym (the Option key), which games
      never press, so Alt and Ctrl reach the game untouched.

      Two consumers cooperate with this remap, configured in the user's
      home-manager (the niri module and home-manager/hosts/<host>.nix):

        - niri rebinds every WM/launcher/DMS/screenshot action onto Super,
          so nothing sits on the Alt or Ctrl keysyms.
        - kitty swaps Alt<->Ctrl back *inside kitty only* via
          ~/.config/keyd/app.conf, so the terminal stays Mac-correct: the
          corner key is Ctrl (SIGINT/EOF and every control char, wholesale),
          the Cmd key is Alt (kitty's alt+c/alt+v/alt+t copy/paste/new-tab).
          Alt is the only free terminal lane (Ctrl=SIGINT, Super=niri).

      App detection requires keyd-application-mapper, enabled as a user
      service alongside the daemon. It reads ~/.config/keyd/app.conf, watches
      the focused window via wlr-foreign-toplevel-management-v1 (niri
      implements it), and pokes keyd's IPC socket on focus changes. Only the
      kitty swap depends on this; the global remap and the game path do not.
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

        # Static 3-key modifier remap. See the option description above for
        # the full rationale; in short, this relabels the EMITTED modifier
        # per physical key so the desktop is Mac-correct and bare-Proton
        # games get clean Ctrl+Alt with niri off those keysyms entirely.
        #
        #   corner Ctrl key -> Alt    (leftctrl/rightctrl = leftalt)
        #   Option          -> Super  (leftalt/rightalt   = leftmeta)
        #   Cmd (by space)  -> Ctrl   (leftmeta/rightmeta = leftctrl)
        #
        # This is the canonical keyd "swap modifiers" idiom — direct [main]
        # key-to-key rebinds, no stateful layers, no overload. kitty swaps
        # Alt<->Ctrl back for itself via app.conf so the terminal keeps
        # interrupt on the corner and copy on the command key (see the
        # home-manager host module).
        #
        # Mirrored left/right so both physical Cmd/Option/Ctrl keys behave
        # alike regardless of which one the user reaches for.
        settings.main = {
          leftctrl = "leftalt";
          rightctrl = "leftalt";
          leftalt = "leftmeta";
          rightalt = "leftmeta";
          leftmeta = "leftctrl";
          rightmeta = "leftctrl";

          # Caps Lock -> Escape at the evdev layer (keyd, not xkb) so the
          # remap reaches apps that read raw scancodes (Steam/Proton games)
          # and bypass the xkb keymap. An xkb-level caps:escape only changes
          # the keysym and silently does nothing for those games. keyd grabs
          # all keyboards before greetd starts (multi-user.target vs
          # graphical.target), so caps->esc is live at the greeter, in
          # Wayland, on TTYs, and in games alike.
          capslock = "esc";
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
