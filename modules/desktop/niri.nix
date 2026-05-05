{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.desktop.niri;
in {
  options.desktop.niri = {
    enable = lib.mkEnableOption "niri Wayland compositor + desktop session";
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
    security.polkit.enable = true;
    programs.dconf.enable = true;

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd niri-session";
        user = "greeter";
      };
    };

    fonts.packages = with pkgs; [
      noto-fonts
      noto-fonts-color-emoji
      noto-fonts-cjk-sans
      inter
    ];

    environment.systemPackages = with pkgs; [
      wl-clipboard
      mako
      fuzzel
      grim
      slurp
      swaybg
    ];
  };
}
