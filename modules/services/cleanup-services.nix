{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.services.cleanup-services;
  user = "joshsymonds";
in {
  options.services.cleanup-services = {
    enable = mkEnableOption "periodic Docker/Podman/Nix-store cleanup and (optionally) kind cluster cleanup";

    interval = mkOption {
      type = types.str;
      default = "1h";
      description = "Timer cadence (OnBootSec / OnUnitActiveSec).";
    };

    kindClusters = {
      enable = mkEnableOption "cleanup of stale kind/ctlptl clusters";
      olderThanSeconds = mkOption {
        type = types.int;
        default = 3600;
        description = "Delete kind clusters older than this many seconds.";
      };
    };

    dockerPrune = mkOption {
      type = types.bool;
      default = config.virtualisation.docker.enable;
      description = "Run 'docker system prune -a --volumes' in the cleanup pass.";
    };

    podmanPrune = mkOption {
      type = types.bool;
      default = config.virtualisation.podman.enable;
      description = "Run 'podman system prune -a --volumes' in the cleanup pass.";
    };

    nixGC = mkOption {
      type = types.bool;
      default = true;
      description = "Run 'nix-store --gc' in the cleanup pass.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.cleanup-old-clusters = mkIf cfg.kindClusters.enable {
      description = "Clean up kind and ctlptl clusters older than configured timeout";
      after = ["docker.service"];
      path = [pkgs.kind pkgs.ctlptl];
      environment.CLUSTER_MAX_AGE_SECONDS = toString cfg.kindClusters.olderThanSeconds;
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = "docker";
        ExecStart = pkgs.writeShellScript "cleanup-old-clusters" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          MAX_AGE_SECONDS=''${CLUSTER_MAX_AGE_SECONDS:-3600}
          echo "Using cluster max age: $MAX_AGE_SECONDS seconds"

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

          if ${pkgs.ctlptl}/bin/ctlptl version &> /dev/null; then
            echo "Checking ctlptl registries..."
            for registry in $(${pkgs.ctlptl}/bin/ctlptl get registries -o json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.items[].metadata.name // empty'); do
              if [[ "$registry" == kind-* ]]; then
                cluster_name=''${registry#kind-}
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

    systemd.timers.cleanup-old-clusters = mkIf cfg.kindClusters.enable {
      description = "Run cluster cleanup every ${cfg.interval}";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitActiveSec = cfg.interval;
        Persistent = true;
      };
    };

    systemd.services.cleanup-docker-and-nix = {
      description = "Clean up Docker and Nix store";
      after = ["docker.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "cleanup-docker-and-nix" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          echo "=== Starting cleanup at $(date) ==="

          ${optionalString cfg.dockerPrune ''
            if systemctl is-active --quiet docker; then
              echo "Cleaning Docker system..."
              ${pkgs.docker}/bin/docker system prune -a --volumes -f || true
              echo "Docker cleanup completed"
            else
              echo "Docker is not running, skipping Docker cleanup"
            fi
          ''}

          ${optionalString cfg.podmanPrune ''
            if command -v podman &> /dev/null; then
              echo "Cleaning Podman system..."
              ${pkgs.podman}/bin/podman system prune -a --volumes -f || true
              echo "Podman cleanup completed"
            fi
          ''}

          ${optionalString cfg.nixGC ''
            echo "Cleaning old Nix generations..."
            ${pkgs.nix}/bin/nix-env --delete-generations +5 || true
            ${pkgs.nix}/bin/nix-collect-garbage || true

            echo "Running Nix garbage collection..."
            ${pkgs.nix}/bin/nix-store --gc || true
          ''}

          echo "=== Cleanup completed at $(date) ==="
        '';
      };
    };

    systemd.timers.cleanup-docker-and-nix = {
      description = "Run Docker and Nix cleanup every ${cfg.interval}";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitActiveSec = cfg.interval;
        Persistent = true;
      };
    };
  };
}
