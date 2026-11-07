# vermissian's VPN exit (services.vpn-exit): one Mullvad WireGuard tunnel in
# a gluetun container. Host programs reach it through the loopback proxies:
# HTTP for ssh-vpn (home-manager/vpn-exit), SOCKS5 for bathhouse's crawl
# (~/Personal/bathhouse, default socks5://127.0.0.1:1080).
#
# The key was generated locally (2026-11-06) and only its public half
# registered with Mullvad as a device; the address file holds the IPv4
# address Mullvad assigned (IPv4 only, as the module requires). Rotate by
# registering a new key and re-encrypting both secrets.
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
    socksProxy.enable = true;
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
