let
  user = "joshsymonds";
  network = import ../../lib/network.nix;
  self = network.hosts.vermissian;
  subnet = network.subnets.${self.subnet};
in
  {
    inputs,
    lib,
    config,
    pkgs,
    ...
  }: {
    # You can import other NixOS modules here. atticd-cache comes via common.nix.
    imports = [
      ../../modules/services/cleanup-services.nix
      ../../modules/services/cloudflare-tunnel.nix
      ../../modules/services/cloudflare-warp-dns.nix
      ./hardware-configuration.nix
      ./mullvad-proxy.nix
      ./services/marvin-blackbox-reap.nix

      # Headless-server hardening (BT module blacklist on top of fleet-wide)
      ../../modules/linux-base/server-hardening.nix
    ];

    services.cleanup-services = {
      enable = true;
      # The marvin-blackbox reaper (./services/marvin-blackbox-reap.nix) owns
      # docker hygiene *for marvin-blackbox specifically* (idle kind clusters,
      # aged build caches, registry tag GC) on this host; nightly `docker
      # system prune -a --volumes` here wiped every unused image and all
      # build cache regardless of source, making the first blackbox build of
      # each day fully cold and undercutting that reaper's warm-cache design.
      # docker-scoped-prune below is the narrow stopgap for everything else
      # Docker on this host accumulates (Coder stack images, ad-hoc builds)
      # now that the nightly global prune is gone.
      dockerPrune = false;
      # 25G x 5 project caches was ~105G of regenerable Go objects on a 884G
      # disk (Sep 2026); 10G per project keeps the warm set, bounds the total.
      homeBuildCacheMaxGB = 10;
    };

    # Docker hygiene stopgap for everything OTHER than marvin-blackbox (see
    # the dockerPrune comment above). Deliberately narrow so it can't repeat
    # the warm-cache wipe that got the nightly global prune disabled: no
    # `-a` (only dangling/unreferenced images, not everything unused) and no
    # volume pruning (never touch data) — just dangling images idle >72h and
    # build cache idle >168h (1wk).
    systemd.services.docker-scoped-prune = {
      description = "Weekly scoped Docker prune (dangling images >72h, build cache >168h)";
      after = ["docker.service"];
      path = [pkgs.docker];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "docker-scoped-prune" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          ${pkgs.docker}/bin/docker image prune -f --filter until=72h
          ${pkgs.docker}/bin/docker builder prune -f --filter until=168h
        '';
      };
    };

    systemd.timers.docker-scoped-prune = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "30m";
        Persistent = true;
      };
    };

    # Performance tuning
    performance.profile = "dev";
    performance.cpuVendor = "amd";

    # Hardware setup
    hardware = {
      cpu = {
        amd.updateMicrocode = true;
      };
      graphics = {
        enable = true;
        extraPackages = with pkgs; [
          libva-vdpau-driver
        ];
      };
      enableAllFirmware = true;
    };

    # Host-specific nix settings (common.nix provides defaults)

    networking = {
      useDHCP = false;
      useNetworkd = true;
      hostName = "vermissian";
      firewall = {
        enable = true;
        checkReversePath = "loose";
        trustedInterfaces = ["tailscale0"];
        allowedUDPPorts = [
          51820
          config.services.tailscale.port
        ];
        allowedTCPPorts = [
          22
          80
          443
          7080
        ];
      };
    };

    # Wired LAN comes up in 1-3s when the link is live; cap the wait so a
    # missing cable or dead switch doesn't hold network-online.target for
    # the full 120s default.
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
      # aarch64 user-mode emulation (qemu binfmt), same as gnomon: lets this
      # host eval-check and build shrike's nix-on-droid closure. Agents do
      # repo work here, so shrike verification has to work here too.
      binfmt.emulatedSystems = ["aarch64-linux"];
      kernelModules = [
        "kvm-amd"
        "amdgpu"
      ];
      supportedFilesystems = [
        "ntfs"
        "nfs"
        "nfs4"
      ];
      kernelParams = [
        # amd_pstate=active is provided by performance module
      ];
    };

    users.users.joshsymonds.extraGroups = ["podman" "docker"];

    # Directories and system services
    systemd = {
      tmpfiles.rules = [];

      services = {
        "agenix-import-ssh-${user}" = let
          homeDir = "/home/${user}";
          sshKey = "${homeDir}/.ssh/github";
          sshPubKey = "${sshKey}.pub";
          ageDir = "${homeDir}/.config/agenix";
          privateOut = "${ageDir}/keys.txt";
          publicOut = "${ageDir}/keys.pub";
          defaultSshKey = "${homeDir}/.ssh/id_ed25519";
          defaultSshPub = "${defaultSshKey}.pub";
        in {
          description = "Convert ${user}'s SSH key to an Age identity";
          wantedBy = ["multi-user.target"];
          unitConfig = {
            ConditionPathExists = [
              sshKey
              sshPubKey
            ];
            StartLimitIntervalSec = 0;
          };
          serviceConfig = {
            Type = "oneshot";
            User = user;
            UMask = "0077";
            ExecStart = pkgs.writeShellScript "agenix-import-ssh-${user}" ''
              set -euo pipefail

              key="${sshKey}"
              pub="${sshPubKey}"
              age_dir="${ageDir}"
              private_out="${privateOut}"
              public_out="${publicOut}"

              mkdir -p "$age_dir"

              tmp_private="$(${pkgs.coreutils}/bin/mktemp "$age_dir/keys.txt.XXXXXX")"
              ${pkgs.ssh-to-age}/bin/ssh-to-age --private-key < "$key" > "$tmp_private"
              mv "$tmp_private" "$private_out"
              chmod 600 "$private_out"

              ${pkgs.ssh-to-age}/bin/ssh-to-age < "$pub" > "$public_out"
              chmod 600 "$public_out"

              if [ ! -e "${defaultSshKey}" ]; then
                ln -sf "$key" "${defaultSshKey}"
                ln -sf "$pub" "${defaultSshPub}"
              fi

              echo "Age identity written to $private_out"
              echo "Age public key:"
              cat "$public_out"
            '';
          };
        };

        remote-mounts = {
          description = "Check if remote mounts are available";
          after = [
            "network.target"
            "remote-fs.target"
          ];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/test -d /mnt/video'";
          };
        };
      };
    };

    virtualisation = {
      # Podman for containers
      podman = {
        enable = true;
        dockerCompat = false; # Disable compat since we have real Docker
        defaultNetwork.settings.dns_enabled = true;
        # Enable cgroup v2 for better container resource management
        enableNvidia = false; # Set to true if you have NVIDIA GPU
        extraPackages = [
          pkgs.podman-compose
          pkgs.podman-tui
        ];
      };

      # Docker for development tools (Kind, ctlptl, etc)
      docker = {
        enable = true;
        enableOnBoot = true;
        # Use a separate storage driver to avoid conflicts
        storageDriver = "overlay2";
      };

      oci-containers = {
      };
    };

    age.secrets."cloudflared-token" = {
      file = ../../secrets/hosts/vermissian/cloudflared-token.age;
      owner = "cloudflared";
      group = "cloudflared";
      mode = "0400";
    };

    services = {
      tailscale = {
        enable = true;
        package = pkgs.tailscale;
        useRoutingFeatures = "server";
        openFirewall = true;
      };

      cloudflareTunnel = {
        enable = true;
        tokenFile = config.age.secrets."cloudflared-token".path;
      };

      # Cloudflare Zero Trust client (WARP). Enrollment is interactive and
      # lives in /var/lib/cloudflare-warp, never in this repo — headless flow:
      # `warp-cli registration new <team>` prints an auth URL, finish login in
      # a browser on another machine, then paste the com.cloudflare.warp://
      # callback URL into `warp-cli registration token '<url>'`. Toggle with
      # `warp-cli connect` / `warp-cli disconnect`; disconnected, WARP touches
      # neither traffic nor DNS. Tailscale coexistence is profile-side:
      # 100.64.0.0/10 is split-tunnel excluded by default, and MagicDNS needs
      # a Local Domain Fallback entry (tail82223.ts.net -> 100.100.100.100)
      # while connected. Do not add ProtectSystem=strict hardening — gnomon
      # hit EROFS applying DNS because the upstream unit only allow-lists
      # /etc/resolv.conf itself, not its parent directory.
      cloudflare-warp = {
        enable = true;
        openFirewall = false;
      };

      # WARP's own DNS handling stops at /etc/resolv.conf, which glibc never
      # reads here; without this, Gateway sees no lookups and FQDN-based
      # egress policies never match. See the module for the full reasoning.
      cloudflareWarpDns.enable = true;

      savecraftDataRefresh.enable = true;
      savecraftDataRefresh.enableDatagen = true;
      savecraftDataRefresh.repoPath = "/home/joshsymonds/Personal/savecraft-worktrees/main";
      # Monthly (first Monday), not weekly: Magic data is set-paced and write-
      # heavy refreshes were pushing D1 rows-written past the free tier. Stale
      # data is fine at current usage. See the private savecraft repo's
      # nix/magic-data-refresh.nix.
      savecraftDataRefresh.onCalendar = "Mon *-*-1..7 04:00:00";
    };

    # Host-specific SSH settings
    services.openssh.settings = {
      X11Forwarding = true;
      StreamLocalBindUnlink = true;
    };

    # Environment
    environment = {
      systemPackages = with pkgs; [
        polkit
        pciutils
        hwdata
        cachix
        tailscale
        unar
        podman-tui
        chromium

        gcc
        gnumake
        grpcurl
        nodejs
        python3
        uv
        protobuf
        protoc-gen-go
        protoc-gen-go-grpc
        pkg-config
        openssl
        openssl.dev
        (google-cloud-sdk.withExtraComponents [google-cloud-sdk.components.gke-gcloud-auth-plugin])
      ];

      variables = {
        PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
        OPENSSL_DIR = "${pkgs.openssl.out}";
        OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
        OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
      };
    };

    # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
    system.stateVersion = "25.05";
  }
