{pkgs, ...}: {
  # Standalone qBittorrent Qt client.
  #
  # On hosts that ALSO run the system-level VPN-routed instance from
  # modules/services/qbittorrent-vpn.nix, prefer that one's WebUI
  # (http://localhost:<webUIPort>) over launching this. They're two
  # separate qBittorrent instances with separate state — the native one
  # here speaks to the open internet and bypasses the VPN entirely.
  # Kept in home-manager because the package is still useful on hosts
  # without a VPN setup, and for ad-hoc magnet-link handling where
  # routing through the VPN container isn't required.
  home.packages = [pkgs.qbittorrent];
}
