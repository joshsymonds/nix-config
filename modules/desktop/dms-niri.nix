# DMS + niri desktop session — the full Quickshell-shelled experience.
#
# Imports:
#   - niri-flake's NixOS module (replaces nixpkgs' niri, adds typed settings)
#   - DMS's two NixOS modules (the shell itself + DankGreeter login)
#   - The thin compositor support layer in ./niri.nix (portals, audio, fonts, CLI)
#
# Hosts opt in with desktop.dms-niri.enable = true.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.desktop.dms-niri;
in {
  imports = [
    inputs.niri-flake.nixosModules.niri
    inputs.dms.nixosModules.dank-material-shell
    # DMS's greeter NixOS module — the greetd-based DankGreeter login.
    # Gated below by desktop.dms-niri.greeter.enable. (gnomon ran
    # halmasuit as its display manager for a stretch; that lives in
    # modules/desktop/halmasuit.nix and, when enabled, replaces this
    # greetd path. With halmasuit off, this is gnomon's login.)
    inputs.dms.nixosModules.greeter
    ./niri.nix
  ];

  options.desktop.dms-niri = {
    enable = lib.mkEnableOption "niri (via niri-flake) + DankMaterialShell + DankGreeter desktop session";

    greeter.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable DankGreeter (the Material You-style login screen via
        greetd). Disable to fall back to a plain tty login. The tty
        escape hatch (Ctrl+Alt+F2 → standard NixOS console login) is
        always available regardless. Mutually exclusive with
        desktop.halmasuit.enable, which owns the greeter itself when on.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Compositor support layer (xdg portals, pipewire, dconf, fonts, CLI tools)
    desktop.niri.enable = true;

    # niri itself — niri-flake provides programs.niri.{enable, package}.
    # Pin to niri-unstable for parity with DMS's edge tracking; switch to
    # niri-flake.packages.${pkgs.stdenv.hostPlatform.system}.niri-stable if
    # you want a slower-moving target. niri-flake doesn't add niri-unstable
    # to the top-level pkgs by default — reference it through the flake input.
    programs.niri.enable = true;
    programs.niri.package = inputs.niri-flake.packages.${pkgs.stdenv.hostPlatform.system}.niri-unstable;

    # DMS shell layer. The DMS edge release made several feature toggles
    # built-in (no longer effective; produces hard assertion failures if
    # set): enableBrightnessControl, enableClipboard, enableColorPicker,
    # enableSystemSound. Only setting toggles that still take effect.
    programs.dank-material-shell = {
      enable = true;
      systemd.enable = true;
      enableAudioWavelength = true;
      enableCalendarEvents = true;
      enableClipboardPaste = true;
      enableDynamicTheming = true;
      enableSystemMonitoring = true;
      enableVPN = true;
    };

    # niri-flake unconditionally ships a polkit-kde-agent unit
    # (systemd.user.services.niri-flake-polkit, hardcoded at flake.nix:510
    # in the niri NixOS module — there is no opt-out option). It races to
    # register as the org.freedesktop.PolicyKit1 authentication agent and
    # wins, so DMS's own quickshell PolkitAgent (Services/PolkitService.qml
    # → Modals/PolkitAuthModal.qml) inits but then fails to register
    # ("An authentication agent already exists for the given subject") and
    # every privilege prompt falls back to the unthemed KDE window. DMS
    # already runs in-session and renders the prompt with the same Theme
    # surfaces as the rest of the shell, so kill the niri-flake unit and
    # let DMS own the registration. polkitd itself (security.polkit.enable,
    # also set by niri-flake) stays — only the redundant KDE agent goes.
    systemd.user.services.niri-flake-polkit.enable = lib.mkForce false;

    # DankGreeter — graphical login via greetd. Recovery escape hatch
    # is the tty (Ctrl+Alt+F2 → standard NixOS console login).
    programs.dank-material-shell.greeter = lib.mkIf cfg.greeter.enable {
      enable = true;
      compositor.name = "niri";
      # DankGreeter gates its FIDO/U2F login flow behind the DMS setting
      # greeterEnableU2f, which defaults to false (GreetdSettings.qml).
      # With it false, maybeAutoStartExternalAuth() early-returns and the
      # greeter only ever shows the password field — even though
      # /etc/pam.d/greetd already has pam_u2f sufficient+first (via
      # services.yubikey-auth) and the key is enrolled. Feed a
      # Nix-generated settings.json turning it on so the greeter
      # auto-starts the touch prompt at login and falls back to password.
      # greetd.preStart copies each configFiles entry into the greeter's
      # cache dir by basename, so the path must end in /settings.json —
      # writeTextDir gives a store dir containing exactly that name.
      configFiles = [
        "${pkgs.writeTextDir "settings.json" (builtins.toJSON {
          greeterEnableU2f = true;
        })}/settings.json"
      ];
    };
  };
}
