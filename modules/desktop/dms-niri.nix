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
    inputs.dms.nixosModules.greeter
    ./niri.nix
  ];

  options.desktop.dms-niri = {
    enable = lib.mkEnableOption "niri (via niri-flake) + DankMaterialShell + DankGreeter desktop session";

    greeter.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable DankGreeter (the Material You-style login screen via greetd).
        Disable if you want to fall back to a plain tty login. The tty escape hatch
        is always available via Ctrl+Alt+F2 even when this is enabled.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Compositor support layer (xdg portals, pipewire, dconf, fonts, CLI tools)
      desktop.niri.enable = true;

      # niri itself — niri-flake provides programs.niri.{enable, package}.
      # Pin to niri-unstable for parity with DMS's edge tracking; switch to
      # niri-flake.packages.${pkgs.system}.niri-stable if you want a
      # slower-moving target. niri-flake doesn't add niri-unstable to the
      # top-level pkgs by default — reference it through the flake input.
      programs.niri.enable = true;
      programs.niri.package = inputs.niri-flake.packages.${pkgs.system}.niri-unstable;

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
    }

    # DankGreeter — graphical login. Recovery escape hatch is the tty
    # (Ctrl+Alt+F2 → standard NixOS console login).
    (lib.mkIf cfg.greeter.enable {
      programs.dank-material-shell.greeter = {
        enable = true;
        compositor.name = "niri";
      };
    })
  ]);
}
