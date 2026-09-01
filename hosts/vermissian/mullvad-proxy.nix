# Mullvad WireGuard tunnel scoped to the in-tunnel SOCKS5 proxy only.
#
# AllowedIPs is pinned to 10.64.0.1/32 — Mullvad's internal SOCKS5 proxy
# (port 1080). Only traffic addressed to that proxy enters the tunnel, so
# this changes no default route and affects no other service on this host.
# Consumers opt in per-connection with socks5://10.64.0.1:1080 (bathhouse's
# `crawl -proxy` is the intended user).
#
# Device key registered on the Mullvad account 2026-08-31 ("Keen Jaguar").
# Rotate by registering a new key and re-encrypting the agenix secret.
{config, ...}: {
  age.secrets."mullvad-privatekey" = {
    file = ../../secrets/hosts/vermissian/mullvad-privatekey.age;
    mode = "0400";
  };

  # The assigned tunnel addresses are also recorded gluetun-style in
  # secrets/hosts/vermissian/mullvad-addresses.age for parity with
  # ultraviolet/gnomon; the interface declares them literally because
  # networking.wireguard ips are evaluation-time values.
  networking.wireguard.interfaces.mullvad0 = {
    ips = ["10.72.133.13/32" "fc00:bbbb:bbbb:bb01::9:850c/128"];
    privateKeyFile = config.age.secrets."mullvad-privatekey".path;
    peers = [
      {
        # us-lax-wg-001 — if it goes dark, pick a sibling from
        # https://api.mullvad.net/public/relays/wireguard/v2/ (us-lax).
        publicKey = "zqsfGglzJPY657WMRxf/S4omG7+ZkSDIpDq+ggbc9yo=";
        endpoint = "23.234.72.2:51820";
        allowedIPs = ["10.64.0.1/32"];
        persistentKeepalive = 25;
      }
    ];
  };
}
