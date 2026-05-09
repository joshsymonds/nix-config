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
      # ScreenCast routing for niri goes through xdg-desktop-portal-gnome.
      # That's what niri's own README and wiki call out as required for
      # screencasting: gnome's portal is the only one that consumes
      # niri's native ext-image-capture-source-v1, which gives per-window
      # share in addition to monitor share. Despite the name, this portal
      # works standalone — niri's maintainer confirmed it does not need
      # gnome-shell or mutter at runtime (niri-wm/niri#3085).
      #
      # We previously routed via xdg-desktop-portal-wlr. wlr only
      # implements wlr-screencopy, which is monitor-only — fine for
      # "share entire screen" in Zoom but gives no window picker.
      # Removed entirely (no fallback): leaving both portals installed
      # without a niri-portals.conf is a known footgun where D-Bus
      # arbitration can silently break screencast.
      #
      # gtk stays on as the default fallback for everything that isn't
      # screencast (FileChooser, OpenURI, Notification, Access). Order
      # matters in `default`: gnome is tried first, gtk picks up what
      # gnome doesn't implement.
      extraPortals = [
        pkgs.xdg-desktop-portal-gnome
        pkgs.xdg-desktop-portal-gtk
      ];
      # Per-DE routing — written to /etc/xdg/xdg-desktop-portal/niri-portals.conf,
      # which the portal frontend prefers over the common portals.conf when
      # XDG_CURRENT_DESKTOP=niri (the module sets that). Mirrors niri's
      # shipped resources/niri-portals.conf, except:
      #   - FileChooser pinned to gtk: xdg-desktop-portal-gnome 47+ uses
      #     nautilus by default, and we don't want to pull that in.
      #   - Secret omitted: the upstream config points it at gnome-keyring,
      #     but we use the standard ssh-agent / no keyring service. Apps
      #     needing the Secret portal will fail; none of ours do.
      config.niri = {
        default = ["gnome" "gtk"];
        "org.freedesktop.impl.portal.FileChooser" = ["gtk"];
        "org.freedesktop.impl.portal.Access" = ["gtk"];
        "org.freedesktop.impl.portal.Notification" = ["gtk"];
      };
    };

    # Order XDP-G after niri so libgxdp finds niri's `org.gnome.Mutter.
    # ServiceChannel` D-Bus name when it tries to open a privileged Wayland
    # service connection at startup. Without this, on cold boot XDP-G starts
    # first, gets "name without owner", falls back to a degraded init via
    # `gtk_init_check`, and the screencast picker never renders. Symptom:
    # "Share Screen" in Zoom/Meet/etc. produces no picker dialog at all.
    # Diagnostic: `systemctl --user restart xdg-desktop-portal-gnome.service`
    # after niri is fully up makes the picker appear (verified 2026-05-09).
    # niri's stub at `src/dbus/mutter_service_channel.rs` is correct; the bug
    # is purely the unit-ordering race between XDP-G's user service and
    # niri's session-bus name registration.
    systemd.user.services.xdg-desktop-portal-gnome.unitConfig.After = ["niri.service"];

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
    #
    # xwayland-satellite is niri's X11 compatibility shim: niri itself is
    # pure Wayland, so any X11-only client (Zoom, older JetBrains, Steam,
    # Citrix) needs satellite to provide an on-demand Xwayland server.
    # The home-manager side (desktop-x86_64-linux.nix) spawns it at niri
    # startup and exports DISPLAY=:0 into niri's env.
    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
      xwayland-satellite
    ];
  };
}
