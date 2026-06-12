let
  network = import ../../lib/network.nix;
  self = network.hosts.ultraviolet;
  subnet = network.subnets.${self.subnet};
in
  {
    inputs,
    lib,
    config,
    pkgs,
    ...
  }: {
    # You can import other NixOS modules here
    imports = [
      # Household atticd binary cache
      ../../modules/services/atticd-cache.nix

      # Periodic Podman + Nix store cleanup
      ../../modules/services/cleanup-services.nix

      # SABnzbd with Mullvad VPN (migrated from bluedesert)
      ./sabnzbd-vpn.nix

      # Home Assistant for home automation
      ./home-assistant.nix

      # Wyoming Whisper STT service for Home Assistant voice
      ./wyoming-whisper.nix

      # Cloudflare Tunnel for secure external access
      ./cloudflare-tunnel.nix

      # Service-specific configuration
      ./services/caddy-base.nix
      ./services/jellyfin.nix
      ./services/radarr-sonarr.nix
      ./services/arr-extras.nix
      ./services/jellyseerr.nix
      ./services/bazarr.nix
      ./services/arr-healthcheck.nix
      ./services/service-reliability.nix
      ./services/media-backups.nix
      ./services/recyclarr.nix
      ./services/invidious.nix
      ./services/redlib.nix
      ./services/shimmer.nix
      ./services/mentat.nix
      ./services/inbox-zero.nix
      ./services/inbox-zero-alerts.nix
      ./services/download-proxies.nix
      ./services/flaresolverr.nix
      ./services/obsidian.nix
      ./services/nextdns-linkip.nix
      ./services/sound-stage.nix

      # Import your generated (nixos-generate-config) hardware configuration
      ./hardware-configuration.nix

      # Headless-server hardening (BT module blacklist on top of fleet-wide)
      ../../modules/linux-base/server-hardening.nix
    ];

    # Performance tuning
    performance.profile = "server";
    performance.cpuVendor = "intel";

    # Additional NFS mount for Home Assistant backups
    fileSystems."/mnt/backups" = {
      device = "${network.infra.nas.ip}:${network.infra.nas.shares.backup}";
      fsType = "nfs";
      options = ["x-systemd.automount" "noauto" "x-systemd.idle-timeout=60"];
    };

    # NFS-backed storage for atticd binary cache (always mounted; atticd reads
    # and writes continuously, so no idle-unmount).
    fileSystems."/mnt/atticd" = {
      device = "${network.infra.nas.ip}:${network.infra.nas.shares.atticd}";
      fsType = "nfs";
      options = ["nfsvers=3" "noatime" "async" "_netdev" "bg"];
    };

    # Hardware setup
    hardware = {
      cpu = {
        intel.updateMicrocode = true;
      };
      graphics = {
        enable = true;
        extraPackages = with pkgs; [
          intel-media-driver
          intel-vaapi-driver
          libva-vdpau-driver
          intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
          vpl-gpu-rt # Modern Intel Media SDK replacement with QSV support
        ];
      };
      enableAllFirmware = true;
    };

    # Host-specific nix settings (common.nix provides defaults)

    networking = {
      useDHCP = false;
      useNetworkd = true;
      hostName = "ultraviolet";
      firewall = {
        enable = true;
        checkReversePath = "loose";
        trustedInterfaces = [
          "tailscale0"
          "podman0"
        ];
        allowedUDPPorts = [
          51820
          config.services.tailscale.port
          5353 # mDNS/Bonjour for HomeKit discovery
        ];
        allowedTCPPorts = [
          22
          80
          443
          9437
          1400 # Sonos event callbacks (primary)
          10200 # Wyoming Piper TTS server
          8123 # Home Assistant (LAN access for TTS fetch by Sonos)
        ];
      };
    };

    # Wired LAN comes up in 1-3s when the link is live; cap the wait so a
    # missing cable or dead switch doesn't hold network-online.target for
    # the full 120s default. Bounds the cold-boot stall for everything
    # downstream (cloudflare-tunnel, gluetun, atticd push, etc.).
    systemd.network.wait-online = {
      anyInterface = true;
      timeout = 10;
    };
    systemd.network.networks."10-lan" = {
      matchConfig.Name = "en*";
      address = ["${self.ip}/${toString subnet.prefixLength}"];
      gateway = [subnet.gateway];
      dns = subnet.nameservers;
    };

    boot = {
      kernelModules = [
        "coretemp"
        "kvm-intel"
        "i915"
      ];
      supportedFilesystems = [
        "ntfs"
        "nfs"
        "nfs4"
      ];
      kernelParams = [
        # intel_pstate=active is now provided by performance module
        "i915.enable_fbc=1"
        "i915.enable_psr=2"
      ];
    };

    users.users.joshsymonds.extraGroups = ["podman"];

    # Host-specific SSH settings
    services.openssh.settings = {
      X11Forwarding = true;
      StreamLocalBindUnlink = true;
    };

    # Services
    services = {
      # Wyoming Piper TTS server for Home Assistant
      wyoming.piper.servers = {
        "amy" = {
          enable = true;
          voice = "en_US-amy-medium";
          uri = "tcp://0.0.0.0:10200";
        };
      };

      tailscale = {
        enable = true;
        package = pkgs.tailscale;
        useRoutingFeatures = "server";
        openFirewall = true; # Open firewall for Tailscale
      };

      # Enable NFS client for better NAS performance
      nfs.server.enable = true;
      rpcbind.enable = true;
    };

    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      gcc-unwrapped.lib
    ];

    services.cleanup-services.enable = true;

    systemd.services.remote-mounts = {
      description = "Check if remote mounts are available";
      after = [
        "network.target"
        "remote-fs.target"
      ];
      before = ["podman-bazarr.service"];
      wantedBy = [
        "multi-user.target"
        "podman-bazarr.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/test -d /mnt/video'";
      };
    };

    age.secrets = {
      "cloudflare-api-token" = {
        file = ../../secrets/hosts/ultraviolet/cloudflare-api-token.age;
        owner = "caddy";
        group = "caddy";
        mode = "0400";
      };

      "cloudflared-token" = {
        file = ../../secrets/hosts/ultraviolet/cloudflared-token.age;
        owner = "cloudflared";
        group = "cloudflared";
        mode = "0400";
      };

      "redlib-collections" = {
        file = ../../secrets/hosts/ultraviolet/redlib-collections.age;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      "x11vnc-password" = {
        file = ../../secrets/hosts/ultraviolet/x11vnc-password.age;
        owner = "joshsymonds";
        group = "users";
        mode = "0400";
      };

      "pob-server-api-key" = {
        file = ../../secrets/hosts/ultraviolet/pob-server-api-key.age;
        owner = "pob-server";
        group = "pob-server";
        mode = "0400";
      };

      "atticd-env" = {
        file = ../../secrets/hosts/ultraviolet/atticd-env.age;
        # atticd uses systemd DynamicUser=true, so atticd:atticd doesn't
        # exist at activation time. Root reads EnvironmentFile as PID 1
        # before dropping into the dynamic user.
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };

    # Server-side bits only. consumer + publisher + push-token agenix come
    # from hosts/common.nix.
    services.atticd-cache = {
      enable = true;
      environmentFile = config.age.secrets."atticd-env".path;
      apiEndpoint = "http://ultraviolet:8081/";
      storagePath = "/mnt/atticd/storage";
      nfsStorage.enable = true;
      # Storage is now on the 13 TB NAS — be generous so cached builds aren't
      # rotated out before the next time we substitute against them.
      gcRetentionPeriod = "1 year";
    };

    services.savecraftPobServer = {
      enable = true;
      package = inputs.savecraft.packages.x86_64-linux.pob-server;
      apiKeyFile = config.age.secrets."pob-server-api-key".path;
    };

    # Podman for media containers
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
      # Enable cgroup v2 for better container resource management
      enableNvidia = false; # Set to true if you have NVIDIA GPU
      extraPackages = [
        pkgs.podman-compose
        pkgs.podman-tui
      ];
    };

    virtualisation.oci-containers = {
      backend = "podman";
      containers = {};
    };

    # Environment
    environment = {
      systemPackages = with pkgs; [
        tailscale
        podman-tui
        jellyfin-ffmpeg
        chromium
        signal-cli
      ];
    };

    # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
    system.stateVersion = "25.05";
  }
