{
  config,
  lib,
  ...
}: let
  cfg = config.services.vpn-exit;
  onOff = b:
    if b
    then "on"
    else "off";
in {
  options.services.vpn-exit = {
    enable = lib.mkEnableOption ''
      the host's one VPN exit: a gluetun container that owns a podman network
      namespace with a WireGuard tunnel in it.

      Anything that should leave through the VPN uses this one exit, so a
      host needs only one VPN device (two gluetun containers on the same
      WireGuard peer fight over the handshake). Two ways in:

      - Containers join the namespace with
        `--network=container:''${config.services.vpn-exit.containerName}`
        and publish their ports on that container, since a container sharing
        a netns can't publish its own (qbittorrent-vpn and ultraviolet's
        SABnzbd do this).
      - Host programs use gluetun's HTTP proxy (httpProxy), which also exits
        through the tunnel.

      gluetun's FIREWALL=on killswitch drops every packet that isn't headed
      into the tunnel, so when the tunnel is down everything behind it loses
      connectivity instead of falling back to the clear net. The host's own
      networking is untouched: anything not pointed at the exit is direct
    '';

    containerName = lib.mkOption {
      type = lib.types.str;
      default = "gluetun";
      description = "Name of the gluetun container that owns the namespace. Consumers join and publish ports on it.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/qmcgaw/gluetun:v3.41.3";
      description = "gluetun OCI image. Pinned to a known-good tag; bump deliberately.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gluetun";
      description = "Host path mounted at /gluetun inside the container (server list cache, etc.).";
    };

    serviceProvider = lib.mkOption {
      type = lib.types.str;
      default = "mullvad";
      description = "Gluetun VPN_SERVICE_PROVIDER. See gluetun's wiki for the supported list.";
    };

    type = lib.mkOption {
      type = lib.types.enum ["wireguard" "openvpn"];
      default = "wireguard";
      description = "Gluetun VPN_TYPE. Mullvad has dropped OpenVPN; keep wireguard for it.";
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/agenix/mullvad-privatekey";
      description = ''
        Path to a file containing the WireGuard private key. Mounted
        read-only into gluetun at /gluetun/wireguard/privatekey and read via
        WIREGUARD_PRIVATE_KEY_SECRETFILE, so the contents never enter the Nix
        store. Typically `config.age.secrets.<name>.path`.
      '';
    };

    addressesFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/agenix/mullvad-addresses";
      description = ''
        Path to a file containing the WireGuard interface addresses
        (comma-separated IPv4 CIDR list, e.g. "10.x.y.z/32"). IPv4 only: the
        namespace has IPv6 disabled, and gluetun refuses to start with an IPv6
        interface address there. Mounted read-only into gluetun and read via
        WIREGUARD_ADDRESSES_SECRETFILE.
      '';
    };

    serverCities = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Los Angeles CA";
      description = "Comma-separated SERVER_CITIES for gluetun's server selection. null for any.";
    };

    serverCountries = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "USA";
      description = "Comma-separated SERVER_COUNTRIES for gluetun. Used together with or instead of serverCities.";
    };

    blockMalicious = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable gluetun's malicious-host DNS block list.";
    };

    portForwarding = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable gluetun port forwarding. Mullvad removed support in 2023, so
        leave false on Mullvad. Useful on ProtonVPN and other providers that
        hand out an inbound port.
      '';
    };

    firewallOutboundSubnets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["172.31.0.0/24"];
      description = ''
        Subnets the namespace may reach directly, outside the tunnel
        (FIREWALL_OUTBOUND_SUBNETS). The LAN, when proxy clients or the
        containers inside need to talk to it.
      '';
    };

    httpProxy = {
      enable = lib.mkEnableOption ''
        gluetun's built-in HTTP proxy (HTTPS goes through CONNECT). Clients
        pointed at it exit through the tunnel behind the same killswitch, so
        when the tunnel or the container is down their connections fail
        instead of going out directly. Stealth mode is on: the proxy adds no
        headers of its own
      '';

      port = lib.mkOption {
        type = lib.types.port;
        default = 8888;
        description = "Port the proxy listens on in the namespace and is published on.";
      };

      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "127.0.0.1";
        description = ''
          Host address the proxy is published on. The default keeps it to
          this machine; null publishes on every interface, for LAN clients
          (then firewallOutboundSubnets must include their subnet, or the
          replies are dropped).
        '';
      };
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = lib.literalExpression ''{ SERVER_REGIONS = "Europe"; }'';
      description = "Extra environment variables for the gluetun container. Wins over the defaults set by this module.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";

      containers.${cfg.containerName} = {
        image = cfg.image;

        environment =
          {
            VPN_SERVICE_PROVIDER = cfg.serviceProvider;
            VPN_TYPE = cfg.type;
            WIREGUARD_PRIVATE_KEY_SECRETFILE = "/gluetun/wireguard/privatekey";
            WIREGUARD_ADDRESSES_SECRETFILE = "/gluetun/wireguard/addresses";
            WIREGUARD_PRESHARED_KEY = ""; # Mullvad and most providers omit it.
            FIREWALL = "on";
            DNS_SERVER = "on"; # gluetun's resolver inside the netns; DNS-over-TLS upstream by default.
            BLOCK_MALICIOUS = onOff cfg.blockMalicious;
            VPN_PORT_FORWARDING = onOff cfg.portForwarding;
            HTTPPROXY = onOff cfg.httpProxy.enable;
            # The server list baked into a pinned gluetun image goes stale as
            # the provider retires and re-keys relays; a dead peer handshakes
            # silently into nothing. Refresh the list daily into the persisted
            # /gluetun/servers.json (gluetun prefers whichever copy is newer).
            # The first refresh fires one period after start, not at start.
            UPDATER_PERIOD = "24h";
            UPDATER_VPN_SERVICE_PROVIDERS = cfg.serviceProvider;
          }
          // lib.optionalAttrs cfg.httpProxy.enable {
            HTTPPROXY_LISTENING_ADDRESS = ":${toString cfg.httpProxy.port}";
            HTTPPROXY_STEALTH = "on";
          }
          // lib.optionalAttrs (cfg.firewallOutboundSubnets != []) {
            FIREWALL_OUTBOUND_SUBNETS = lib.concatStringsSep "," cfg.firewallOutboundSubnets;
          }
          // lib.optionalAttrs (cfg.serverCities != null) {
            SERVER_CITIES = cfg.serverCities;
          }
          // lib.optionalAttrs (cfg.serverCountries != null) {
            SERVER_COUNTRIES = cfg.serverCountries;
          }
          // cfg.extraEnvironment;

        volumes = [
          "${cfg.dataDir}:/gluetun"
          "${cfg.privateKeyFile}:/gluetun/wireguard/privatekey:ro"
          "${cfg.addressesFile}:/gluetun/wireguard/addresses:ro"
        ];

        ports = lib.optional cfg.httpProxy.enable (
          lib.optionalString (cfg.httpProxy.address != null) "${cfg.httpProxy.address}:"
          + "${toString cfg.httpProxy.port}:${toString cfg.httpProxy.port}"
        );

        extraOptions = [
          "--cap-add=NET_ADMIN"
          "--device=/dev/net/tun"
          "--sysctl=net.ipv4.conf.all.src_valid_mark=1"
          # IPv4-only netns. gluetun (through v3.41.3) counts the eth0
          # fe80::/64 link-local route as IPv6 support and then dials random
          # IPv6 endpoints the podman bridge can't route (sendmmsg: network is
          # unreachable), leaving the tunnel down until a healthcheck restart
          # happens to pick IPv4. With IPv6 off, detection is truthful and
          # every endpoint is IPv4. The addressesFile must then hold only IPv4
          # CIDRs: gluetun refuses an IPv6 interface address when IPv6 is
          # unsupported.
          "--sysctl=net.ipv6.conf.all.disable_ipv6=1"
          "--sysctl=net.ipv6.conf.default.disable_ipv6=1"
          # gluetun is stateless (its only volume is a server-list cache);
          # nothing it holds is worth a graceful drain. It also owns the netns
          # + /dev/net/tun + the podman0 bridge, exactly the teardown that
          # wedges systemd-shutdown's post-journald phase. So give podman stop
          # a 1s SIGTERM grace, then SIGKILL.
          "--stop-timeout=1"
        ];

        autoStart = true;
      };
    };

    systemd.tmpfiles.rules = ["d ${cfg.dataDir} 0700 root root -"];

    # Backstop for --stop-timeout above: if podman itself wedges (the failure
    # mode behind the shutdown hang), systemd must not idle the default wait
    # and feed the post-journald stall. Just above the stop-timeout, so the
    # graceful path wins when podman is healthy. mkForce because
    # virtualisation.oci-containers pins these units to TimeoutStopSec=120.
    systemd.services."podman-${cfg.containerName}".serviceConfig.TimeoutStopSec = lib.mkForce 10;
  };
}
