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
    # You can import other NixOS modules here
    imports = [
      ../../modules/services/cloudflare-tunnel.nix
      ./hardware-configuration.nix
    ];

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
      extraHosts = ''
        ${network.hosts.ultraviolet.ip} ultraviolet
        ${network.hosts.bluedesert.ip} bluedesert
        ${network.hosts.echelon.ip} echelon
      '';
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
      kernelPackages = pkgs.linuxPackages_latest;
      loader = {
        systemd-boot = {
          enable = true;
          configurationLimit = 8;
        };
        efi = {
          canTouchEfiVariables = true;
          efiSysMountPoint = "/boot";
        };
      };
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

        cleanup-old-clusters = {
          description = "Clean up kind and ctlptl clusters older than configured timeout";
          after = ["docker.service"];
          path = [
            pkgs.kind
            pkgs.ctlptl
          ];
          environment = {
            CLUSTER_MAX_AGE_SECONDS = "3600";
          };
          serviceConfig = {
            Type = "oneshot";
            User = user;
            Group = "docker";
            ExecStart = pkgs.writeShellScript "cleanup-old-clusters" ''
              #!${pkgs.bash}/bin/bash
              set -euo pipefail

              # Get timeout from environment or use default (1 hour)
              MAX_AGE_SECONDS=''${CLUSTER_MAX_AGE_SECONDS:-3600}
              echo "Using cluster max age: $MAX_AGE_SECONDS seconds"

              # Function to get cluster age in seconds
              get_cluster_age() {
                local cluster=$1
                local created_time=$(${pkgs.docker}/bin/docker inspect "$cluster-control-plane" 2>/dev/null | ${pkgs.jq}/bin/jq -r '.[0].Created // empty')

                if [ -z "$created_time" ]; then
                  echo "0"
                  return
                fi

                local created_epoch=$(${pkgs.coreutils}/bin/date -d "$created_time" +%s 2>/dev/null || echo "0")
                local current_epoch=$(${pkgs.coreutils}/bin/date +%s)
                echo $((current_epoch - created_epoch))
              }

              # Clean up kind clusters older than configured timeout
              if ${pkgs.kind}/bin/kind version &> /dev/null; then
                echo "Checking kind clusters..."
                for cluster in $(${pkgs.kind}/bin/kind get clusters 2>/dev/null); do
                  age=$(get_cluster_age "$cluster")
                  if [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
                    echo "Deleting old kind cluster: $cluster (age: $((age/60)) minutes, max: $((MAX_AGE_SECONDS/60)) minutes)"
                    ${pkgs.kind}/bin/kind delete cluster --name "$cluster" || true
                  else
                    echo "Keeping kind cluster: $cluster (age: $((age/60)) minutes, max: $((MAX_AGE_SECONDS/60)) minutes)"
                  fi
                done
              else
                echo "Kind not available, skipping kind cluster cleanup"
              fi

              # Clean up ctlptl registries
              if ${pkgs.ctlptl}/bin/ctlptl version &> /dev/null; then
                echo "Checking ctlptl registries..."
                # Get all ctlptl registries and delete those associated with deleted clusters
                for registry in $(${pkgs.ctlptl}/bin/ctlptl get registries -o json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.items[].metadata.name // empty'); do
                  # Check if registry starts with "kind-" (associated with a kind cluster)
                  if [[ "$registry" == kind-* ]]; then
                    cluster_name=''${registry#kind-}
                    # Check if the associated cluster still exists
                    if ! ${pkgs.kind}/bin/kind get clusters 2>/dev/null | grep -q "^$cluster_name$"; then
                      echo "Removing orphaned ctlptl registry: $registry"
                      ${pkgs.ctlptl}/bin/ctlptl delete registry "$registry" || true
                    fi
                  fi
                done
              else
                echo "Ctlptl not available, skipping registry cleanup"
              fi

              echo "Cluster cleanup completed"
            '';
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

    };

    systemd.timers.cleanup-old-clusters = {
      description = "Run cluster cleanup every hour";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1h";
        OnUnitActiveSec = "1h";
        Persistent = true;
      };
    };

    # Clean up Docker and Nix store regularly
    systemd.services.cleanup-docker-and-nix = {
      description = "Clean up Docker and Nix store";
      after = ["docker.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "cleanup-docker-and-nix" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          echo "=== Starting cleanup at $(date) ==="

          # Clean Docker if it's running
          if systemctl is-active --quiet docker; then
            echo "Cleaning Docker system..."
            ${pkgs.docker}/bin/docker system prune -a --volumes -f || true
            echo "Docker cleanup completed"
          else
            echo "Docker is not running, skipping Docker cleanup"
          fi

          # Clean Podman
          if command -v podman &> /dev/null; then
            echo "Cleaning Podman system..."
            ${pkgs.podman}/bin/podman system prune -a --volumes -f || true
            echo "Podman cleanup completed"
          fi

          # Clean old Nix generations (keep last 5)
          echo "Cleaning old Nix generations..."
          ${pkgs.nix}/bin/nix-env --delete-generations +5 || true
          ${pkgs.nix}/bin/nix-collect-garbage || true

          # Clean Nix store of unreferenced packages
          echo "Running Nix garbage collection..."
          ${pkgs.nix}/bin/nix-store --gc || true

          echo "=== Cleanup completed at $(date) ==="
        '';
      };
    };

    systemd.timers.cleanup-docker-and-nix = {
      description = "Run Docker and Nix cleanup every hour";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1h";
        OnUnitActiveSec = "1h";
        Persistent = true;
      };
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
