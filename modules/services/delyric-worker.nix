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
      example = lib.literalExpression "inputs.sound-stage.packages.\${pkgs.stdenv.hostPlatform.system}.delyric-worker";
      description = ''
        The delyric-worker package to run. Typically consumed from the
        sound-stage flake input — it provides meta.mainProgram so
        lib.getExe resolves correctly.
      '';
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
      wantedBy = ["multi-user.target"];

      # Scope the mount dependency to the specific NFS path rather than
      # the umbrella remote-fs.target. If /mnt/music drops, systemd stops
      # this unit; unrelated NFS mounts on this host won't drag it down.
      unitConfig.RequiresMountsFor = [cfg.libraryDir];

      environment = {
        DELYRIC_LIBRARY = cfg.libraryDir;
        DELYRIC_PORT = toString cfg.port;
        DELYRIC_BIND_HOST = cfg.bindHost;
        DELYRIC_STATE_DIR = "/var/lib/delyric-worker";
        AUDIO_SEPARATOR_MODEL_DIR = "/var/lib/delyric-worker/models";
        # The packaged wrapper bootstraps a pip venv for audio-separator[gpu]
        # + torch at first run (see sound-stage nix/wrapper.sh). This is an
        # explicit design choice over pure-Nix packaging because CUDA wheels
        # are painful to rebuild through Nix. Redirect pip's cache into the
        # StateDirectory so it persists across restarts and respects
        # ProtectHome.
        PIP_CACHE_DIR = "/var/lib/delyric-worker/pip-cache";
      };

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = 10;

        # First start after a fresh deploy pip-installs audio-separator[gpu]
        # + torch + CUDA wheels (hundreds of MB) before the FastAPI process
        # bind()s the port. Type=exec does NOT bypass TimeoutStartSec — the
        # default 90s would SIGTERM mid-install and flap restart. 30 min
        # gives headroom; subsequent starts short-circuit via the
        # requirements.txt hash check.
        TimeoutStartSec = 1800;
        # A single separation job can run up to ~10 min (delyric.py
        # SEPARATOR_TIMEOUT = 600). TimeoutStopSec must exceed that or
        # systemd will SIGKILL mid-job on stop/restart, leaving partial
        # outputs on the NFS share. 15 min gives margin for I/O.
        TimeoutStopSec = 900;

        StateDirectory = "delyric-worker";
        StateDirectoryMode = "0750";
        WorkingDirectory = "/var/lib/delyric-worker";

        # --- Hardening ---
        # Filesystem isolation
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = ["/var/lib/delyric-worker" cfg.libraryDir];
        UMask = "0027";

        # Kernel / process isolation
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        LockPersonality = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        # @system-service is systemd's curated allowlist for service workloads;
        # denying @privileged blocks uncommon admin syscalls. @resources is
        # NOT denied here because CUDA/PyTorch may schedule with sched_*/nice.
        SystemCallFilter = ["@system-service" "~@privileged"];

        # No capabilities needed — the worker binds a TCP port >1024 and
        # talks to NVIDIA device nodes via DeviceAllow, not via CAP_SYS_*.
        CapabilityBoundingSet = [];
        AmbientCapabilities = [];
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];

        # NVIDIA device nodes for CUDA. DeviceAllow requires PrivateDevices=false
        # (the default) — we set it explicitly so a future edit can't silently
        # toggle it true and break the GPU path. Single GPU assumed — add
        # /dev/nvidia1 etc. if stygianlibrary ever grows a second card.
        PrivateDevices = false;
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
