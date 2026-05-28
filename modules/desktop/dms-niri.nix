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
    # DMS's greeter NixOS module was the upstream-greetd-based login
    # path. On gnomon the halmasuit module (modules/desktop/halmasuit.nix)
    # replaces it — halmasuit IS the display manager and forks
    # DankGreeter directly as its Wayland client; there is no
    # greetd daemon and no nested niri compositor for the greeter.
    # Hosts using dms-niri but NOT halmasuit can re-add this import
    # locally.
    ./niri.nix
  ];

  options.desktop.dms-niri = {
    enable = lib.mkEnableOption "niri (via niri-flake) + DankMaterialShell post-login session";

    # The `greeter` sub-option was the toggle for DMS's
    # nixosModules.greeter integration. With that module no longer
    # imported (replaced by halmasuit on gnomon), the option is
    # vestigial; keep the eval-compatible shape so existing host
    # configs setting `desktop.dms-niri.greeter.enable = true` don't
    # break, but the option is now a no-op.
    greeter.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        DEPRECATED no-op. DMS's greeter NixOS module is no longer
        imported by this module; the greeter path is handled by
        modules/desktop/halmasuit.nix. This option is kept for eval
        compatibility and may be removed in a future revision.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
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
    }

    # NOTE: the greeter sub-option used to gate
    # programs.dank-material-shell.greeter.enable (DMS's greetd-
    # based login) here. With halmasuit replacing greetd on gnomon
    # (modules/desktop/halmasuit.nix), the greeter path is
    # halmasuit-owned and that wiring lives in halmasuit.nix.
    # The greeter option remains for eval compatibility but is now
    # a no-op (see options.desktop.dms-niri.greeter.enable above).
  ]);
}
