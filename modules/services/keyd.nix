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
      keyd-driven Mac-style keyboard model (gnomon).

      Physical bottom-left keycaps in Mac mode are [Ctrl][Option][Cmd][Space].
      Rather than SWAP which modifier each physical key emits, keyd gives the
      Cmd key its own occluding layer that emulates Control and translates
      Cmd-combos to Linux equivalents — globally and per-app — while Ctrl and
      Alt are left completely untouched:

        corner Ctrl key -> REAL Control   (unmapped: SIGINT/EOF in terminals,
                                           clean Ctrl for games, native Linux
                                           Ctrl shortcuts)
        Option          -> Super          (niri's sole modifier: Option+M ...)
        Cmd (by space)  -> layer(cmd)     ([cmd:C] emulates Control, so every
                                           Cmd+<key> with no explicit override
                                           becomes Ctrl+<key> automatically —
                                           Cmd+C copy, Cmd+A, Cmd+Z, ...)

      Only the EXCEPTIONS to "Cmd = Ctrl" are enumerated (in [cmd]/[cmd+shift]
      below and in ~/.config/keyd/app.conf): e.g. Cmd+Tab -> Super+Tab (niri
      switcher), Cmd+Left/Right -> Home/End. This is the same translation model
      Toshy uses (Cmd as a distinct Control-emulating modifier), expressed in
      keyd's native modifier-layer system instead of a Python event loop.

      Why this beats the old static swap, especially for games: because Cmd is
      a layer activated ONLY by the Cmd key — which bare-Proton (XWayland)
      games never press — Ctrl and Alt reach games completely untouched, with
      NO per-game exclusion and NO swap to undo. The old design remapped the
      corner key to Alt and then un-swapped it inside kitty to recover SIGINT;
      here the corner key is simply real Control everywhere, so that whole
      dance is gone.

      Two consumers cooperate, configured in the user's home-manager (the niri
      module and home-manager/hosts/<host>.nix):

        - niri binds every WM/launcher/DMS/screenshot action onto Super, so
          nothing sits on the Ctrl or Alt keysyms (games own those).
        - kitty: app.conf points the Cmd key at the `alt` layer *inside kitty*
          so kitty's own alt+c/alt+v/alt+t/alt+<n> command binds fire. The
          corner key stays real Control (the global default) for SIGINT/EOF
          wholesale — no per-key terminal remap needed anymore.

      Per-app overrides require keyd-application-mapper, enabled as a user
      service alongside the daemon. It reads ~/.config/keyd/app.conf, watches
      the focused window via wlr-foreign-toplevel-management-v1 (niri
      implements it), and applies each section's binds as a mask on FOCUS
      CHANGE (not per keypress) by calling `keyd bind` over the IPC socket.
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

        # Modifier-layer model (NOT a static swap of emitted modifiers, and
        # NOT bare keycode assignment like `leftcontrol = leftalt`):
        #
        #   Cmd    (leftmeta/rightmeta) -> layer(cmd); [cmd:C] emulates Control,
        #     so Cmd+<key> = Ctrl+<key> by default (exceptions in extraConfig).
        #   Option (leftalt/rightalt)   -> layer(meta) = Super (niri's modifier).
        #   corner Ctrl                 -> left UNMAPPED = real Control. SIGINT/
        #     EOF in terminals, clean Ctrl for games, native Linux Ctrl. Games
        #     never press Cmd, so the cmd layer never activates for them and
        #     Ctrl/Alt pass through untouched — no per-game exclusion needed.
        #
        # NB: keyd's key name is `leftcontrol`/`rightcontrol`, NOT `leftctrl`
        # (no such alias — keyd rejects it as "not a valid key").
        settings.main = {
          leftmeta = "layer(cmd)";
          rightmeta = "layer(cmd)";
          leftalt = "layer(meta)";
          rightalt = "layer(meta)";

          # Caps Lock -> Escape at the evdev layer (keyd, not xkb) so the
          # remap reaches apps that read raw scancodes (Steam/Proton games)
          # and bypass the xkb keymap. An xkb-level caps:escape only changes
          # the keysym and silently does nothing for those games. keyd grabs
          # all keyboards before greetd starts (multi-user.target vs
          # graphical.target), so caps->esc is live at the greeter, in
          # Wayland, on TTYs, and in games alike.
          capslock = "esc";
        };

        # The cmd layer (Control-emulating) plus composite declarations.
        #
        # [cmd:C] holds only the EXCEPTIONS to "Cmd = Ctrl":
        #   tab/grave  -> Super+Tab / Super+grave so the Cmd key drives niri's
        #                 recent-windows / app-window switchers (bound to Mod+
        #                 in the niri module) instead of leaking Ctrl+Tab.
        #   q          -> Super+Q = niri close-window (Mac's Cmd+Q "quit", as
        #                 close-focused-window — the tiling-WM equivalent).
        #   left/right -> Home/End (Mac line-nav; browsers override these to
        #                 history back/forward in app.conf).
        #
        # [cmd+shift] and [alt+shift] are composite layers, declared here so
        # binds can target them (composites must follow their components):
        #   [cmd+shift] = the Cmd+Shift+Tab / Cmd+Shift+grave reverse switchers
        #     and Cmd+Shift+[/] tab cycling (Ctrl+Shift+Tab / Ctrl+Tab). Bound
        #     globally here, NOT per-app, so it doesn't depend on the focus-
        #     triggered app-mapper having pushed the mask (and because Mac
        #     cycles tabs with Cmd+Shift+[/] in essentially every tabbed app).
        #   [alt+shift] backs kitty's Cmd+Shift+Tab (Cmd = Alt inside kitty).
        extraConfig = ''
          [cmd:C]
          tab = M-tab
          grave = M-grave
          q = M-q
          left = home
          right = end

          [cmd+shift]
          tab = M-S-tab
          grave = M-S-grave
          leftbrace = C-S-tab
          rightbrace = C-tab

          [alt+shift]
        '';
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
