{
  pkgs,
  config,
  lib,
  ...
}: let
  port = 8091;

  # Audit fleet: throwaway redlib instances for morning-room's bulk subreddit
  # audit. Reddit's app-only token is good for 100 requests per ten-minute
  # window and each redlib process holds exactly one token, so throughput
  # scales with instance count. They all leave through gluetun's Mullvad exit,
  # where many tokens behind one IP is what Reddit already sees from every
  # other Mullvad user. Bound to 0.0.0.0 so vermissian can reach them over
  # tailscale0 (a trusted interface); the LAN firewall keeps them closed
  # everywhere else. The audit staggers first contact so twenty token requests
  # do not land on Reddit in the same second.
  auditInstances = 20;
  auditBasePort = 18100;
  auditPorts = lib.genList (i: auditBasePort + i) auditInstances;

  # The hardening set the nixpkgs redlib module applies to its own unit.
  hardening = {
    DynamicUser = true;
    CapabilityBoundingSet = "";
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateIPC = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProcSubset = "pid";
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "full";
    RemoveIPC = true;
    RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = ["~@mount" "~@swap" "~@resources" "~@reboot" "~@raw-io" "~@obsolete" "~@module" "~@debug" "~@cpu-emulation" "~@clock" "~@privileged"];
    UMask = "0027";
  };

  auditService = p:
    lib.nameValuePair "redlib-audit-${toString p}" {
      description = "redlib audit instance on port ${toString p}";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "podman-gluetun.service"];
      wants = ["network-online.target"];
      environment.HTTPS_PROXY = "http://127.0.0.1:8888";
      serviceConfig =
        hardening
        // {
          ExecStart = "${pkgs.redlib-veraticus}/bin/redlib --port ${toString p} --address 0.0.0.0";
          Restart = "on-failure";
          RestartSec = "10s";
        };
    };
in {
  services.redlib = {
    enable = true;
    package = pkgs.redlib-veraticus;
    address = "127.0.0.1";
    inherit port;
    settings = {
      REDLIB_DEFAULT_THEME = "catppuccinMocha";
      REDLIB_DEFAULT_LAYOUT = "clean";
      REDLIB_DEFAULT_WIDE = true;
      REDLIB_HOME_FROM_COLLECTIONS = "on";
    };
  };

  systemd.services =
    {
      # The redlib-collections secret is an env file (KEY=VALUE per line) holding
      # REDLIB_COLLECTIONS and any other settings we don't want surfaced in this
      # public repo — e.g. REDLIB_HOME_EXCLUDED_COLLECTIONS. agenix decrypts it
      # to a root-owned 0400 path; systemd reads it before dropping to DynamicUser.
      redlib = {
        serviceConfig = {
          EnvironmentFile = config.age.secrets."redlib-collections".path;
          # redlib exits after ~90s if it can't mint an OAuth token. After a
          # power loss gluetun's tunnel can take minutes to come up (the
          # container is "active" long before the proxy can reach Reddit), so
          # keep retrying like the audit instances do.
          Restart = "on-failure";
          RestartSec = "10s";
        };
        restartTriggers = [config.age.secrets."redlib-collections".file];

        # Reddit 403-blocked this host's home IP on 2026-09-16 after redlib's
        # OAuth token rollover looked like abuse (the morning-room audit pushed
        # ~1200 requests through it in minutes). Send Reddit traffic out through
        # gluetun's HTTP proxy (sabnzbd-vpn.nix, Mullvad exit) instead. redlib's
        # wreq client honours HTTPS_PROXY; only reddit.com is ever contacted.
        environment.HTTPS_PROXY = "http://127.0.0.1:8888";
        after = ["podman-gluetun.service"];
      };
    }
    // lib.listToAttrs (map auditService auditPorts);

  # Cloudflare Tunnel handles public exposure (redlib.husbuddies.gay) directly,
  # so no local Caddy vhost is defined here.
}
