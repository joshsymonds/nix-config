{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.cleanup-services;
in {
  options.services.cleanup-services = {
    enable = lib.mkEnableOption "periodic Docker/Podman/Nix-store cleanup";

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1d";
      description = "Timer cadence (OnBootSec / OnUnitActiveSec).";
    };

    dockerPrune = lib.mkOption {
      type = lib.types.bool;
      default = config.virtualisation.docker.enable;
      description = "Run 'docker system prune -a --volumes' in the cleanup pass.";
    };

    podmanPrune = lib.mkOption {
      type = lib.types.bool;
      default = config.virtualisation.podman.enable;
      description = "Run 'podman system prune -a --volumes' in the cleanup pass.";
    };

    nixGC = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run 'nix-collect-garbage --delete-older-than 3d' + 'nix-store --gc' in the cleanup pass.";
    };

    tmpBuildCachePrune = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Delete stale per-run build caches in /tmp (Go caches, arena-run dirs, scratch dirs) left behind by agent runs.";
    };

    tmpBuildCacheAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Minimum age in days before a /tmp build-cache dir is deleted.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.cleanup-docker-and-nix = {
      description = "Clean up Docker and Nix store";
      after = ["docker.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "cleanup-docker-and-nix" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          echo "=== Starting cleanup at $(date) ==="

          ${lib.optionalString cfg.dockerPrune ''
            if systemctl is-active --quiet docker; then
              echo "Cleaning Docker system..."
              ${pkgs.docker}/bin/docker system prune -a --volumes -f || true
              echo "Docker cleanup completed"
            else
              echo "Docker is not running, skipping Docker cleanup"
            fi
          ''}

          ${lib.optionalString cfg.podmanPrune ''
            if command -v podman &> /dev/null; then
              echo "Cleaning Podman system..."
              ${pkgs.podman}/bin/podman system prune -a --volumes -f || true
              echo "Podman cleanup completed"
            fi
          ''}

          ${lib.optionalString cfg.tmpBuildCachePrune ''
            echo "Pruning stale build caches in /tmp..."
            ${pkgs.findutils}/bin/find /tmp -mindepth 1 -maxdepth 1 \
              \( -name '*cache*' -o -name '*go-build*' -o -name 'arena-run-*' \
                 -o -name 'tmp.*' -o -name '*-scratch' -o -name '*shared-target*' \) \
              -mtime +${toString cfg.tmpBuildCacheAgeDays} \
              -exec rm -rf {} + || true
            echo "/tmp build-cache prune completed"
          ''}

          ${lib.optionalString cfg.nixGC ''
            echo "Cleaning old Nix generations..."
            ${pkgs.nix}/bin/nix-env --delete-generations +5 || true
            ${pkgs.nix}/bin/nix-collect-garbage --delete-older-than 3d || true

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
