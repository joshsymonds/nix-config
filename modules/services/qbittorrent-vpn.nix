{
  config,
  lib,
  ...
}: let
  cfg = config.services.qbittorrent-vpn;
  exit = config.services.vpn-exit;
in {
  imports = [./vpn-exit.nix];

  options.services.qbittorrent-vpn = {
    enable = lib.mkEnableOption ''
      qBittorrent routed through the host's VPN exit (services.vpn-exit).

      qBittorrent joins the exit's network namespace
      (--network=container:<vpn-exit.containerName>), so all of its traffic,
      and crucially its DNS resolution, leaves through the tunnel, and the
      exit's FIREWALL=on killswitch drops every packet if the tunnel ever goes
      down. The host's own networking stays untouched.

      The WebUI is reached at http://localhost:<webUIPort>. The container is
      the only qBittorrent instance you want on the host — a second native
      qBittorrent running as the user would speak to the open internet
      directly and silently defeat the whole arrangement.
    '';

    image = lib.mkOption {
      type = lib.types.str;
      default = "lscr.io/linuxserver/qbittorrent:5.3.0";
      description = "qBittorrent OCI image. linuxserver's image runs qbittorrent-nox and reads PUID/PGID.";
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
        TCP port of qBittorrent's WebUI, both inside the netns and on the
        host. Published on the exit's container (it owns the netns), not on
        the qbittorrent container. It must be free in the netns too, so pick
        another port when something else in the exit (SABnzbd on 8080, the
        exit's HTTP proxy) already holds it.
      '';
    };

    webUIAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1";
      description = "Host address the WebUI port is published on. null publishes on all interfaces.";
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/qbittorrent";
      description = "Host path mounted at /config inside the qBittorrent container.";
    };

    downloadsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/home/joshsymonds/Downloads/torrents";
      description = ''
        Host path mounted at /downloads inside the qBittorrent container.
        Created by tmpfiles with `puid:pgid` ownership so the container
        can write to it. Put this on a persistent filesystem — on an
        impermanence host, /home is the natural choice. null skips it,
        for hosts that mount their download locations via extraVolumes.
      '';
    };

    extraVolumes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["/mnt/video/torrents:/mnt/video/torrents"];
      description = ''
        Extra podman volume specs for the qBittorrent container. Mount
        download locations at the same path the *arr apps see, so their
        imports need no remote path mapping.
      '';
    };
  };

  config = let
    webUIPublish =
      lib.optionalString (cfg.webUIAddress != null) "${cfg.webUIAddress}:"
      + "${toString cfg.webUIPort}:${toString cfg.webUIPort}";
  in
    lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = exit.enable;
          message = "services.qbittorrent-vpn joins the host's VPN exit: enable services.vpn-exit.";
        }
        {
          assertion = !(exit.httpProxy.enable && exit.httpProxy.port == cfg.webUIPort);
          message = "services.qbittorrent-vpn.webUIPort collides with services.vpn-exit.httpProxy.port in the shared netns.";
        }
      ];

      virtualisation.oci-containers.containers = {
        # The WebUI port is published on the exit's container, which owns the
        # netns; qbittorrent listens on the same port inside it (WEBUI_PORT).
        ${exit.containerName}.ports = [webUIPublish];

        # dependsOn ensures the exit is running first; --network=container:...
        # mounts its netns into this one. qbittorrent never sees the host
        # network — if gluetun crashes, qbittorrent immediately loses
        # connectivity (no silent fallback to clear-net).
        qbittorrent = {
          image = cfg.image;

          environment = {
            PUID = toString cfg.puid;
            PGID = toString cfg.pgid;
            TZ = cfg.timezone;
            WEBUI_PORT = toString cfg.webUIPort;
          };

          volumes =
            ["${cfg.configDir}:/config"]
            ++ lib.optional (cfg.downloadsDir != null) "${cfg.downloadsDir}:/downloads"
            ++ cfg.extraVolumes;

          dependsOn = [exit.containerName];
          extraOptions = [
            "--network=container:${exit.containerName}"
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

      systemd.tmpfiles.rules =
        ["d ${cfg.configDir} 0755 ${toString cfg.puid} ${toString cfg.pgid} -"]
        ++ lib.optional (cfg.downloadsDir != null) "d ${cfg.downloadsDir} 0755 ${toString cfg.puid} ${toString cfg.pgid} -";

      # Backstop for --stop-timeout above. `podman stop` honours the
      # container's own stop-timeout, but if podman itself wedges (the
      # failure mode behind the shutdown hang), systemd must not idle the
      # default 120s waiting on it and feed the post-journald stall. Just
      # above the stop-timeout so the graceful path always wins when podman is
      # healthy. mkForce because virtualisation.oci-containers already pins
      # these units to TimeoutStopSec=120.
      systemd.services."podman-qbittorrent".serviceConfig.TimeoutStopSec = lib.mkForce 20;
    };
}
