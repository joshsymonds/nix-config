{
  config,
  lib,
  ...
}: let
  cfg = config.services.qbittorrent-vpn;
in {
  options.services.qbittorrent-vpn = {
    enable = lib.mkEnableOption ''
      qBittorrent routed through a gluetun WireGuard tunnel.

      Same pattern as hosts/ultraviolet/sabnzbd-vpn.nix: gluetun owns the
      podman network namespace and qBittorrent shares it
      (--network=container:gluetun-qbittorrent). All of qBittorrent's
      traffic — and crucially its DNS resolution — exits through the VPN,
      and gluetun's FIREWALL=on killswitch drops every packet if the
      tunnel ever goes down. The host's own networking stays untouched;
      browsers, ssh, anything else on this machine is direct.

      You provide three things in your host composition: the gluetun
      environment that selects a provider + server, and two file paths
      whose contents gluetun reads (private key + interface addresses).
      For agenix users that's `config.age.secrets.<name>.path`; nothing
      in this module is provider-specific.

      The WebUI is reached at http://localhost:<webUIPort>. The container
      pair is the only qBittorrent instance you want on the host — a
      second native qBittorrent running as the user would speak to the
      open internet directly and silently defeat the whole arrangement.
    '';

    image = lib.mkOption {
      type = lib.types.str;
      default = "lscr.io/linuxserver/qbittorrent:5.0.4";
      description = "qBittorrent OCI image. linuxserver's image runs qbittorrent-nox and reads PUID/PGID.";
    };

    gluetunImage = lib.mkOption {
      type = lib.types.str;
      default = "qmcgaw/gluetun:v3.40.0";
      description = "gluetun OCI image. Pinned to a known-good tag; bump deliberately.";
    };

    puid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "UID the qBittorrent process runs as inside the container. Must match the owner of downloadsDir on the host.";
    };

    pgid = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "GID for the qBittorrent process. 100 = `users` on NixOS by default.";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "Etc/UTC";
      example = "America/Los_Angeles";
      description = "TZ env var inside the container. Affects qBittorrent's scheduler + log timestamps.";
    };

    webUIPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Host TCP port forwarded to qBittorrent's WebUI inside the netns.
        Bound on the gluetun container (it owns the netns), not on the
        qbittorrent container. Choose something free on this host —
        ultraviolet already uses 8080 for SABnzbd-via-gluetun, so on a
        host running both you'd offset this.
      '';
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/qbittorrent";
      description = "Host path mounted at /config inside the qBittorrent container.";
    };

    downloadsDir = lib.mkOption {
      type = lib.types.str;
      example = "/home/joshsymonds/Downloads/torrents";
      description = ''
        Host path mounted at /downloads inside the qBittorrent container.
        Created by tmpfiles with `puid:pgid` ownership so the container
        can write to it. Put this on a persistent filesystem — on an
        impermanence host, /home is the natural choice.
      '';
    };

    gluetunDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gluetun";
      description = "Host path mounted at /gluetun inside the gluetun container (server list cache, etc.).";
    };

    vpn = {
      serviceProvider = lib.mkOption {
        type = lib.types.str;
        default = "mullvad";
        example = "mullvad";
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
          read-only into gluetun at /gluetun/wireguard/privatekey and
          read via WIREGUARD_PRIVATE_KEY_SECRETFILE — the contents never
          enter the Nix store. Typically `config.age.secrets.<name>.path`.
        '';
      };

      addressesFile = lib.mkOption {
        type = lib.types.str;
        example = "/run/agenix/mullvad-addresses";
        description = ''
          Path to a file containing the WireGuard interface addresses
          (comma-separated CIDR list, e.g. "10.x.y.z/32,fc00:.../128").
          Mounted read-only into gluetun and read via
          WIREGUARD_ADDRESSES_SECRETFILE.
        '';
      };

      serverCities = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Los Angeles CA";
        description = "Comma-separated SERVER_CITIES passed to gluetun for server selection. Leave null for any.";
      };

      serverCountries = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "USA";
        description = "Comma-separated SERVER_COUNTRIES passed to gluetun. Used together with or instead of serverCities.";
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
          Enable gluetun port forwarding. Mullvad removed support in 2023 —
          leave false on Mullvad. Useful on ProtonVPN and other providers
          where you can claim an inbound port for higher seed connectivity.
        '';
      };

      extraEnvironment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = lib.literalExpression ''{ SERVER_REGIONS = "Europe"; }'';
        description = "Extra environment variables forwarded to the gluetun container. Wins over defaults set by this module.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers = {
      backend = "podman";

      containers = {
        # gluetun owns the netns: WireGuard interface comes up here, FIREWALL=on
        # is the killswitch (default-drop unless traffic is destined for the
        # tunnel + provider DNS), and the WebUI port is bound on this container
        # because the qbittorrent container shares this netns and therefore
        # cannot publish ports itself.
        gluetun-qbittorrent = {
          image = cfg.gluetunImage;

          environment =
            {
              VPN_SERVICE_PROVIDER = cfg.vpn.serviceProvider;
              VPN_TYPE = cfg.vpn.type;
              WIREGUARD_PRIVATE_KEY_SECRETFILE = "/gluetun/wireguard/privatekey";
              WIREGUARD_ADDRESSES_SECRETFILE = "/gluetun/wireguard/addresses";
              WIREGUARD_PRESHARED_KEY = ""; # Mullvad and most providers omit it.
              FIREWALL = "on";
              DOT = "on"; # DNS-over-TLS to gluetun's resolver inside the netns.
              BLOCK_MALICIOUS =
                if cfg.vpn.blockMalicious
                then "on"
                else "off";
              VPN_PORT_FORWARDING =
                if cfg.vpn.portForwarding
                then "on"
                else "off";
              HEALTH_VPN_DURATION_INITIAL = "30s";
              HEALTH_VPN_DURATION_ADDITION = "10s";
            }
            // lib.optionalAttrs (cfg.vpn.serverCities != null) {
              SERVER_CITIES = cfg.vpn.serverCities;
            }
            // lib.optionalAttrs (cfg.vpn.serverCountries != null) {
              SERVER_COUNTRIES = cfg.vpn.serverCountries;
            }
            // cfg.vpn.extraEnvironment;

          volumes = [
            "${cfg.gluetunDataDir}:/gluetun"
            "${cfg.vpn.privateKeyFile}:/gluetun/wireguard/privatekey:ro"
            "${cfg.vpn.addressesFile}:/gluetun/wireguard/addresses:ro"
          ];

          extraOptions = [
            "--cap-add=NET_ADMIN"
            "--device=/dev/net/tun"
            "--sysctl=net.ipv4.conf.all.src_valid_mark=1"
            # gluetun is stateless (its only volume is a server-list
            # cache); nothing it holds is worth a graceful drain. It also
            # owns the netns + /dev/net/tun + the podman0 bridge — exactly
            # the teardown that wedges systemd-shutdown's post-journald
            # phase. So give podman stop a 1s SIGTERM grace, then SIGKILL.
            "--stop-timeout=1"
          ];

          # The host port maps to 8080 inside the netns — where qbittorrent's
          # WebUI listens (set via WEBUI_PORT on the qbittorrent container).
          ports = ["${toString cfg.webUIPort}:8080"];

          autoStart = true;
        };

        # qbittorrent shares gluetun's network namespace. dependsOn ensures the
        # netns container is running first; --network=container:... mounts that
        # netns into this one. qbittorrent never sees the host network — if
        # gluetun crashes, qbittorrent immediately loses connectivity (no
        # silent fallback to clear-net).
        qbittorrent = {
          image = cfg.image;

          environment = {
            PUID = toString cfg.puid;
            PGID = toString cfg.pgid;
            TZ = cfg.timezone;
            WEBUI_PORT = "8080";
          };

          volumes = [
            "${cfg.configDir}:/config"
            "${cfg.downloadsDir}:/downloads"
          ];

          dependsOn = ["gluetun-qbittorrent"];
          extraOptions = [
            "--network=container:gluetun-qbittorrent"
            # qBittorrent is the one container with state worth
            # protecting: on SIGTERM qbittorrent-nox flushes .fastresume
            # / session into /config (sub-second normally). Give it a
            # real—but short—10s grace so that flush completes; a
            # zero-grace kill would only cost a force-recheck of any
            # in-flight torrent (downloaded data in /downloads is already
            # safe), but the flush is cheap insurance.
            "--stop-timeout=10"
          ];

          autoStart = true;
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.gluetunDataDir} 0700 root root -"
      "d ${cfg.configDir} 0755 ${toString cfg.puid} ${toString cfg.pgid} -"
      "d ${cfg.downloadsDir} 0755 ${toString cfg.puid} ${toString cfg.pgid} -"
    ];

    # Backstop for the --stop-timeout values above. `podman stop` honours
    # the container's own stop-timeout, but if podman itself wedges (the
    # actual failure mode behind the shutdown hang), systemd must not idle
    # the default 90s waiting on it and feed the post-journald stall.
    # These caps sit just above each container's stop-timeout so the
    # graceful path always wins when podman is healthy, and the unit is
    # SIGKILLed promptly when it isn't. Generated unit names are
    # `podman-<container>.service`. mkForce because virtualisation.oci-
    # containers already pins these units to TimeoutStopSec=120, which is
    # precisely the over-long wait we are here to shorten.
    systemd.services."podman-gluetun-qbittorrent".serviceConfig.TimeoutStopSec = lib.mkForce 10;
    systemd.services."podman-qbittorrent".serviceConfig.TimeoutStopSec = lib.mkForce 20;
  };
}
