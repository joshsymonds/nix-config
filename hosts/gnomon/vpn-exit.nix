# gnomon's VPN exit (services.vpn-exit): one Mullvad WireGuard tunnel in a
# gluetun container. qBittorrent joins its netns (qbittorrent-vpn.nix), and
# the loopback HTTP proxy is for host programs (home-manager/vpn-exit:
# firefox-vpn, ssh-vpn).
#
# Mullvad's WireGuard config is per-device, so gnomon needs its own peer
# (a new peer added under your Mullvad account → WireGuard configuration,
# distinct from ultraviolet's). The peer's private key + assigned
# addresses go into two agenix secrets under
# secrets/hosts/gnomon/mullvad-{privatekey,addresses}.age and are wired
# into the module via config.age.secrets.<name>.path below.
#
# Provisioning (do once, locally):
#
#   1. Mullvad account → "WireGuard configuration" → Add new device for
#      gnomon. Save the generated private key and the assigned IPv4
#      address (e.g., "10.x.y.z/32"). Drop the fc00:... IPv6 address
#      Mullvad also assigns: the gluetun netns is IPv4-only and gluetun
#      refuses an IPv6 interface address there.
#
#   2. Add recipient entries to secrets/secrets.nix:
#        "secrets/hosts/gnomon/mullvad-privatekey.age".publicKeys = keys.gnomon;
#        "secrets/hosts/gnomon/mullvad-addresses.age".publicKeys = keys.gnomon;
#      (keys.gnomon is already declared in secrets/keys.nix — it covers
#       the host agekey + every user key, so any of your machines can
#       edit these secrets.)
#
#   3. Encrypt the values:
#        agenix -e secrets/hosts/gnomon/mullvad-privatekey.age
#        agenix -e secrets/hosts/gnomon/mullvad-addresses.age
#
#   4. Run `update`. The first boot pulls the gluetun image and brings the
#      tunnel up; verify with
#        curl -s --proxy http://127.0.0.1:8888 https://am.i.mullvad.net/json
#      and confirm mullvad_exit_ip is true.
{config, ...}: {
  imports = [
    ../../modules/services/vpn-exit.nix
  ];

  services.vpn-exit = {
    enable = true;
    serverCities = "Los Angeles CA";
    privateKeyFile = config.age.secrets."mullvad-privatekey".path;
    addressesFile = config.age.secrets."mullvad-addresses".path;
    # Loopback only: for this machine's programs, not the LAN.
    httpProxy.enable = true;
  };

  age.secrets = {
    "mullvad-privatekey" = {
      file = ../../secrets/hosts/gnomon/mullvad-privatekey.age;
      owner = "root";
      mode = "0600";
    };
    "mullvad-addresses" = {
      file = ../../secrets/hosts/gnomon/mullvad-addresses.age;
      owner = "root";
      mode = "0600";
    };
  };
}
