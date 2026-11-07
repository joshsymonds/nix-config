# ultraviolet's VPN exit (services.vpn-exit): one Mullvad WireGuard tunnel in
# a gluetun container. SABnzbd (sabnzbd-vpn.nix) and qBittorrent
# (qbittorrent.nix) join its netns; there is one Mullvad device for this host,
# and two gluetun containers on the same peer would fight over the handshake.
# The HTTP proxy is published on the LAN for other devices and testing.
{config, ...}: let
  network = import ../../lib/network.nix;
in {
  imports = [
    ../../modules/services/vpn-exit.nix
  ];

  services.vpn-exit = {
    enable = true;
    serverCities = "Los Angeles CA";
    privateKeyFile = config.age.secrets."mullvad-privatekey".path;
    addressesFile = config.age.secrets."mullvad-addresses".path;
    httpProxy = {
      enable = true;
      address = null;
    };
    # LAN proxy clients: without this the killswitch drops replies to them.
    firewallOutboundSubnets = [network.subnets.home.cidr];
  };

  age.secrets = {
    "mullvad-privatekey" = {
      file = ../../secrets/hosts/ultraviolet/mullvad-privatekey.age;
      owner = "root";
      mode = "0600";
    };
    "mullvad-addresses" = {
      file = ../../secrets/hosts/ultraviolet/mullvad-addresses.age;
      owner = "root";
      mode = "0600";
    };
  };
}
