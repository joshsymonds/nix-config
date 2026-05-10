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
      ./hardware-configuration.nix

      # Headless-server hardening (BT module blacklist on top of fleet-wide)
      ../../modules/linux-base/server-hardening.nix
    ];

    services.cleanup-services = {
      enable = true;
      kindClusters.enable = true;
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
          9437
        ];
      };
    };

    systemd.network.wait-online.anyInterface = true;
    systemd.network.networks."10-lan" = {
      matchConfig.Name = "en*";
      address = ["${self.ip}/${toString subnet.prefixLength}"];
      gateway = [subnet.gateway];
      dns = subnet.nameservers;
    };

    boot = {
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

      savecraftDataRefresh.enable = true;
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
