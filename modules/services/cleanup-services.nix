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
