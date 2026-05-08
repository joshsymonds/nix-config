# Centralized network topology
#
# All host IPs, interfaces, gateways, and nameservers in one place.
# Hosts reference this file instead of hardcoding network values.
#
# Usage in a host:
#   let network = import ../../lib/network.nix; in { ... }
#   networking.defaultGateway = network.subnets.home.gateway;
#   networking.interfaces.${network.hosts.vermissian.interface}.ipv4.addresses = [ ... ];
{
  # Subnets
  subnets = {
    home = {
      prefix = "172.31.0";
      cidr = "172.31.0.0/24";
      prefixLength = 24;
      gateway = "172.31.0.1";
      nameservers = ["172.31.0.1"];
    };
    remote = {
      prefix = "192.168.1";
      cidr = "192.168.1.0/24";
      prefixLength = 24;
      gateway = "192.168.1.1";
      nameservers = ["8.8.8.8" "1.1.1.1"];
    };
  };

  # Infrastructure devices (not managed by nix, but referenced)
  infra = {
    nas = {
      ip = "172.31.0.100";
      shares = {
        video = "/volume1/video";
        music = "/volume1/music";
        books = "/volume1/books";
        backup = "/volume1/backup";
        creative = "/volume1/creative";
      };
    };
    sonos-move = {
      ip = "172.31.0.32";
    };
  };

  # Managed hosts
  hosts = {
    ultraviolet = {
      ip = "172.31.0.200";
      interface = "enp0s31f6";
      subnet = "home";
    };
    bluedesert = {
      ip = "172.31.0.201";
      interface = "enp2s0";
      subnet = "home";
    };
    vermissian = {
      ip = "172.31.0.202";
      interface = "enp0s31f6";
      subnet = "home";
    };
    gnomon = {
      # Stable .80 (mirror in blackbox NFS export allowlists for
      # video/music/books/creative). No hardcoded interface — gnomon
      # uses systemd-networkd with `matchConfig.Name = "en*"` (same as
      # ultraviolet/vermissian), so the actual NIC name doesn't matter.
      ip = "172.31.0.80";
      subnet = "home";
    };
    echelon = {
      ip = "192.168.1.200";
      interface = "enp2s0";
      subnet = "remote";
    };
  };
}
