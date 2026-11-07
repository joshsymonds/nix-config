# vermissian's VPN exit (services.vpn-exit): one Mullvad WireGuard tunnel in
# a gluetun container, with the loopback HTTP proxy for host programs
# (home-manager/vpn-exit: ssh-vpn).
#
# Its own Mullvad device, separate from mullvad-proxy.nix's "Keen Jaguar":
# two tunnels on one WireGuard key fight over the peer's endpoint. The key was
# generated locally (2026-11-06) and only its public half registered with
# Mullvad; the address file holds the IPv4 address Mullvad assigned (IPv4
# only, as the module requires).
{config, ...}: {
  imports = [
    ../../modules/services/vpn-exit.nix
  ];

  services.vpn-exit = {
    enable = true;
    serverCities = "Los Angeles CA";
    privateKeyFile = config.age.secrets."mullvad-exit-privatekey".path;
    addressesFile = config.age.secrets."mullvad-exit-addresses".path;
    httpProxy.enable = true;
  };

  age.secrets = {
    "mullvad-exit-privatekey" = {
      file = ../../secrets/hosts/vermissian/mullvad-exit-privatekey.age;
      owner = "root";
      mode = "0600";
    };
    "mullvad-exit-addresses" = {
      file = ../../secrets/hosts/vermissian/mullvad-exit-addresses.age;
      owner = "root";
      mode = "0600";
    };
  };
}
