# gnomon composition of services.qbittorrent-vpn.
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
#      gnomon. Save the generated private key and the assigned
#      addresses (e.g., "10.x.y.z/32,fc00:bbbb:...:1/128").
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
#   4. Flip services.qbittorrent-vpn.enable to true below and run
#      `update`. The first boot will pull the gluetun + qbittorrent
#      images (~150 MB) and bring the tunnel up; verify with
#        podman exec qbittorrent curl -s https://am.i.mullvad.net/json
#      and confirm mullvad_exit_ip is true before adding torrents.
{
  config,
  lib,
  ...
}: {
  imports = [
    ../../modules/services/qbittorrent-vpn.nix
  ];

  services.qbittorrent-vpn = {
    enable = true;

    timezone = "America/Los_Angeles";

    # Downloads land in the user's home so files are immediately usable
    # without juggling /var/lib ownership. @home is persistent on
    # gnomon's btrfs-impermanence layout, so this survives @root rollback
    # natively (no /persist bind-mount needed).
    downloadsDir = "/home/joshsymonds/Downloads/torrents";

    vpn = {
      serviceProvider = "mullvad";
      type = "wireguard";
      serverCities = "Los Angeles CA";
      portForwarding = false; # Mullvad dropped support in 2023.
      privateKeyFile = config.age.secrets."mullvad-privatekey".path;
      addressesFile = config.age.secrets."mullvad-addresses".path;
    };
  };

  age.secrets = lib.mkIf config.services.qbittorrent-vpn.enable {
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
