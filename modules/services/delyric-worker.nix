{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.delyric-worker;
in {
  options.services.delyric-worker = {
    enable = lib.mkEnableOption "delyric vocal separation worker (FastAPI + GPU)";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The delyric-worker package (from the sound-stage flake).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9001;
      description = "TCP port for the HTTP API.";
    };

    bindHost = lib.mkOption {
      type = lib.types.str;
      description = ''
        Address to bind the HTTP server to. The worker performs a local
        bind-test on startup and exits cleanly (code 0) if the address is
        not bindable on this host — so systemd will not restart it. This
        is the explicit design for a dual-boot host: when booted to Linux
        the address binds and the worker runs; when booted elsewhere the
        unit is absent and the Go orchestrator's 503 path applies.
      '';
    };

    libraryDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/music/sound-stage";
      description = "Directory containing song subdirectories with audio.webm.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "delyric";
      description = "User to run the worker as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "delyric";
      description = "Group to run the worker as.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the worker port on the firewall. Host-level firewall scoping
        (e.g. trustedInterfaces = ["tailscale0"]) still applies.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/lib/delyric-worker";
      # NVIDIA device access for audio-separator[gpu].
      extraGroups = ["video" "render"];
    };
    users.groups.${cfg.group} = {};

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.port];

    systemd.services.delyric-worker = {
      description = "Delyric vocal separation worker";
      after = ["network-online.target" "remote-fs.target"];
      wants = ["network-online.target"];
      requires = ["remote-fs.target"];
      wantedBy = ["multi-user.target"];

      environment = {
        DELYRIC_LIBRARY = cfg.libraryDir;
        DELYRIC_PORT = toString cfg.port;
        DELYRIC_BIND_HOST = cfg.bindHost;
        DELYRIC_STATE_DIR = "/var/lib/delyric-worker";
        AUDIO_SEPARATOR_MODEL_DIR = "/var/lib/delyric-worker/models";
        PIP_CACHE_DIR = "/var/lib/delyric-worker/pip-cache";
      };

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = 10;

        # A single separation job can run up to ~10 min (delyric.py
        # SEPARATOR_TIMEOUT = 600). TimeoutStopSec must exceed that or
        # systemd will SIGKILL mid-job on stop/restart, leaving partial
        # outputs on the NFS share. 15 min gives margin for I/O.
        TimeoutStopSec = 900;

        StateDirectory = "delyric-worker";
        StateDirectoryMode = "0750";
        WorkingDirectory = "/var/lib/delyric-worker";

        # Hardening — loose enough to allow GPU + NFS writes.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["/var/lib/delyric-worker" cfg.libraryDir];

        # NVIDIA device nodes for CUDA.
        DeviceAllow = [
          "/dev/nvidia0 rw"
          "/dev/nvidiactl rw"
          "/dev/nvidia-uvm rw"
          "/dev/nvidia-uvm-tools rw"
          "/dev/nvidia-modeset rw"
        ];
        DevicePolicy = "closed";
      };
    };
  };
}
