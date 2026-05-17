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
      mode on the keyboard) act as Super (sustained, kernel-held), but
      Cmd+letter / Cmd+digit / Cmd+arrow / etc. chords get rewritten to
      Ctrl+key. So Cmd+C in Firefox/Slack/Electron becomes Ctrl+C and
      copies natively, Cmd+T → new tab, Cmd+W → close tab, while Cmd+Tab
      / Cmd+Space / Cmd+, / Cmd+\` reach the niri compositor as genuine
      Super-held chords (which niri's `recent-windows` switcher and DMS
      spotlight/settings binds require — they only stay open while the
      modifier is held).

      Per-app exceptions go in ~/.config/keyd/app.conf (managed by the user's
      home-manager — see home-manager/hosts/<host>.nix). The kitty exception
      lives there: under `[kitty]` we override each Ctrl-translation in
      [meta] with its Super equivalent (`meta.t = M-t`, etc.), so kitty
      receives raw Super+key for its own super+c/v/t/etc. binds while raw
      Ctrl+C and Ctrl+D in the terminal stay SIGINT/EOF.

      Why we override [meta] rules instead of just neutralizing leftmeta:
      keyd's [meta] is a predefined `:M` layer whose activation by
      leftmeta/rightmeta is hardcoded into the modifier handler, not a
      [main] binding. Rebinding leftmeta in [main] does NOT suppress that
      activation, so a [main]-level exception is a silent no-op.

      Why the layer prefix is on the binding (`meta.t = M-t`) and not on
      the section header (`[kitty.meta]`): keyd-application-mapper splits
      section names on `|` (class|title), not `.`, so `[kitty.meta]`
      would be treated as the class string "kitty.meta" and never match
      the focused window class "kitty". The mapper passes each line
      under `[kitty]` verbatim to `keyd bind reset`, which accepts the
      `[<layer>.]<key> = <action>` form natively.

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

        # We extend keyd's predefined `[meta]` layer rather than swallowing
        # leftmeta/rightmeta into a custom `[cmd:C]` layer. The reason is
        # subtle but matters for niri: keyd's predefined `[meta]` is a `:M`
        # layer that the leftmeta key activates by default, AND in that
        # mode the kernel sees Super held continuously while the physical
        # key is held. Niri's `recent-windows` (Cmd+Tab) switcher relies on
        # exactly that — the overlay closes the moment the modifier
        # releases, so it has to stay genuinely held for browse-style
        # cycling to work.
        #
        # Our previous design (`leftmeta = layer(cmd)` + `[cmd:C]`) instead
        # swallowed leftmeta entirely and re-emitted Super+key as a
        # synthesized chord per keystroke (Super DOWN, Tab DOWN, Tab UP,
        # Super UP). That released Super between Tab presses and made the
        # niri switcher commit + flip-flop between two windows on every
        # tap. Letting `[meta]` retain its sustained-Super semantics fixes
        # that; we just enumerate the keys we want translated to Ctrl
        # (the bulk of Mac muscle memory: Cmd+letter, Cmd+digit) instead
        # of carving out the few that should stay as Super.
        #
        # Keys deliberately NOT remapped — they fall through to `:M` and
        # emit as raw Super+key with the modifier still held, which is
        # what we want:
        #   tab, grave   — niri recent-windows (Cmd+Tab / Cmd+`)
        #   space, comma — niri DMS spotlight / settings (Cmd+Space, Cmd+,)
        #   F-keys, escape — no Mac convention worth translating
        # Neutralize a *lone* Alt tap. The physical Alt key is "Option" in
        # Mac mode and every binding we care about (niri Alt+H/J/K/L, the
        # Alt+<letter> focus-or-spawn launchers, Alt+Shift WM ops) is a
        # *held* chord. A solo press-and-release of Alt, by contrast, is
        # never wanted: GTK/Qt interpret it as "focus the app menubar"
        # (the toolkit behavior macOS deliberately lacks — macOS uses
        # Ctrl+F2, never a bare modifier). overload(alt, noop) keeps Alt
        # fully live as the held modifier layer while making the tap emit
        # nothing, so the menubar never steals a half-typed chord. F10
        # remains the explicit GTK menubar accel when a menu is actually
        # wanted (the real analog of Mac's Ctrl+F2).
        #
        # This is a static [main] rebind of the activating key, NOT an
        # app.conf dynamic override of a predefined layer's internal
        # translations — so the "[main] rebind is a silent no-op" caveat
        # documented for the meta layer below does not apply here; this is
        # keyd's canonical modifier-without-tap idiom.
        settings.main = {
          leftalt = "overload(alt, noop)";
          rightalt = "overload(alt, noop)";
        };

        settings.meta = {
          # Letters: Cmd+letter → Ctrl+letter (copy/paste/new-tab/close-
          # tab/quit/find/save/etc., the universal Linux GUI idiom).
          a = "C-a";
          b = "C-b";
          c = "C-c";
          d = "C-d";
          e = "C-e";
          f = "C-f";
          g = "C-g";
          h = "C-h";
          i = "C-i";
          j = "C-j";
          k = "C-k";
          l = "C-l";
          m = "C-m";
          n = "C-n";
          o = "C-o";
          p = "C-p";
          q = "C-q";
          r = "C-r";
          s = "C-s";
          t = "C-t";
          u = "C-u";
          v = "C-v";
          w = "C-w";
          x = "C-x";
          y = "C-y";
          z = "C-z";

          # Digits: Cmd+1..9 → Ctrl+1..9 (browser tab switching, IDE
          # tool-window jumps, terminal-multiplexer pane focus).
          "1" = "C-1";
          "2" = "C-2";
          "3" = "C-3";
          "4" = "C-4";
          "5" = "C-5";
          "6" = "C-6";
          "7" = "C-7";
          "8" = "C-8";
          "9" = "C-9";
          "0" = "C-0";

          # Arrows: Cmd+arrow → Ctrl+arrow (word/paragraph navigation in
          # browsers, IDEs, text editors). Not literally what Mac does
          # (Mac Cmd+Left = Home), but matches the previous `[cmd:C]`
          # behavior so we don't change muscle memory in this rewrite.
          left = "C-left";
          right = "C-right";
          up = "C-up";
          down = "C-down";

          # Editing: Cmd+Backspace → Ctrl+Backspace (delete previous word).
          # Cmd+Enter → Ctrl+Enter (force-send / submit-without-newline in
          # chat apps, run-cell in notebooks).
          backspace = "C-backspace";
          enter = "C-enter";

          # Punctuation that shows up in app shortcuts. Common cases:
          # Cmd+/ → Ctrl+/ (toggle comment in IDEs); Cmd+- / Cmd+= →
          # Ctrl+-/= (zoom out/in); Cmd+[ / Cmd+] → Ctrl+[/] (back/forward
          # in browsers, indent/outdent in IDEs); Cmd+. → Ctrl+. (quick
          # actions in some IDEs, stop in others).
          minus = "C-minus";
          equal = "C-equal";
          leftbrace = "C-leftbrace";
          rightbrace = "C-rightbrace";
          semicolon = "C-semicolon";
          apostrophe = "C-apostrophe";
          backslash = "C-backslash";
          dot = "C-dot";
          slash = "C-slash";
        };

        # Composite layer that activates when both Cmd and Shift are held.
        #
        # 3/4/5 → Super+Shift+digit: niri's Mac-style screenshot binds
        # (Super+Shift+3 monitor, +4 picker, +5 satty annotate) expect a
        # genuine Super-held chord. Without these, Cmd+Shift+3 falls
        # through the (otherwise empty) composite layer to [meta]'s
        # `3 = C-3` and reaches niri as Ctrl+Shift+3 — which has no bind,
        # so the screenshot keys do nothing. keyd composite layers fall
        # through to their component layers on unbound keys, so the
        # passthrough has to be stated explicitly here; an empty
        # [meta+shift] does NOT mean "emit raw Super+Shift+key".
        #
        # The bare `[meta+shift]` declaration also lets per-app overrides
        # in ~/.config/keyd/app.conf target the layer (e.g. Firefox's
        # `meta+shift.rightbrace = C-tab`). keyd refuses dynamic binds
        # against an undeclared composite layer ("meta+shift is not a
        # valid layer"). Composite layers MUST be declared after their
        # component layers; both [meta] and [shift] are keyd built-ins,
        # so order is fine.
        extraConfig = ''
          [meta+shift]
          3 = M-S-3
          4 = M-S-4
          5 = M-S-5
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
