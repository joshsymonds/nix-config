# niri compositor + immediate system dependencies.
#
# This module is intentionally thin: it enables niri itself, the XDG portals,
# the PipeWire audio stack, dconf, and a basic font set. It does NOT include
# a notification daemon, launcher, lockscreen, idle handler, polkit agent,
# screenshot UI, wallpaper manager, or login greeter — those are provided by
# DankMaterialShell (DMS).
#
# A host wanting the full niri+DMS desktop session imports BOTH:
#   - this module (sets desktop.niri.enable = true)
#   - inputs.dms.nixosModules.dank-material-shell  (system services + DMS user unit)
#   - inputs.dms.nixosModules.greeter              (DankGreeter via greetd)
# and on the home-manager side:
#   - inputs.dms.homeModules.dank-material-shell   (Quickshell + DMS app)
#   - inputs.dms.homeModules.niri                  (DMS keybinds + autostart for niri)
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.desktop.niri;
in {
  options.desktop.niri = {
    enable = lib.mkEnableOption "niri Wayland compositor (paired separately with DMS for the shell layer)";
  };

  config = lib.mkIf cfg.enable {
    programs.niri.enable = true;

    xdg.portal = {
      enable = true;
      wlr.enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
    };

    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      wireplumber.enable = true;
    };

    security.rtkit.enable = true;
    programs.dconf.enable = true;

    # The desktop stack (likely via xdg.portal or dconf) pulls in
    # services.gnome.gcr-ssh-agent which conflicts with common.nix's
    # programs.ssh.startAgent. We use the standard ssh-agent across the
    # whole fleet — disable the GNOME variant explicitly.
    services.gnome.gcr-ssh-agent.enable = false;

    fonts.packages = with pkgs; [
      noto-fonts
      noto-fonts-color-emoji
      noto-fonts-cjk-sans
      inter
    ];

    # Low-level CLI tools that complement the DMS-provided GUI equivalents:
    # wl-clipboard for scripts (DMS has its own clipboard manager UI),
    # grim/slurp for ad-hoc CLI screenshots (DMS handles interactive capture).
    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
    ];
  };
}
