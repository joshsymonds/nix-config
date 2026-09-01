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

    homeBuildCachePrune = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Age-prune Go build caches under /home/*/.cache (go-build and
        per-project <name>/build GOCACHE dirs). Deletes only entries unused
        longer than homeBuildCacheAgeDays, so recent warm cache survives.
        Go touches an entry's mtime on use, so mtime is an LRU signal.
      '';
    };

    homeBuildCacheAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Minimum age in days before a home build-cache entry is deleted.";
    };

    homeBuildCacheCap = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Hourly size-capped LRU eviction for the same cache dirs the age prune
        covers. Agent build churn can write 10-15G/hour of never-again-read
        cache entries (each edit-build cycle adds new object files), so an
        age-based prune alone cannot bound growth. When a cache exceeds
        homeBuildCacheMaxGB, oldest-mtime entries are evicted until it fits
        (Go touches mtime on cache hits, so mtime is an LRU signal).
      '';
    };

    homeBuildCacheMaxGB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = "Per-directory size budget in GB for home build caches.";
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
                 -o -name '*-authorrun-*' -o -name 'tmp.*' -o -name '*-scratch' \
                 -o -name '*shared-target*' \) \
              -mtime +${toString cfg.tmpBuildCacheAgeDays} \
              -exec rm -rf {} + || true
            echo "/tmp build-cache prune completed"
          ''}

          ${lib.optionalString cfg.homeBuildCachePrune ''
            echo "Age-pruning Go build caches under /home/*/.cache..."
            for d in /home/*/.cache/go-build /home/*/.cache/*/build; do
              [ -d "$d" ] || continue
              ${pkgs.findutils}/bin/find "$d" -type f \
                -mtime +${toString cfg.homeBuildCacheAgeDays} -delete || true
              ${pkgs.findutils}/bin/find "$d" -mindepth 1 -type d -empty -delete || true
            done
            echo "Home build-cache prune completed"
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

    systemd.services.home-build-cache-cap = lib.mkIf cfg.homeBuildCacheCap {
      description = "Evict oldest home build-cache entries over the ${toString cfg.homeBuildCacheMaxGB}G budget";
      serviceConfig = {
        Type = "oneshot";
        # GOCACHE shard paths are hex names with no whitespace, so
        # newline-delimited find output is safe to pipe through sort/awk.
        ExecStart = pkgs.writeShellScript "home-build-cache-cap" ''
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          budget=$((${toString cfg.homeBuildCacheMaxGB} * 1024 * 1024 * 1024))
          for d in /home/*/.cache/go-build /home/*/.cache/*/build; do
            [ -d "$d" ] || continue
            total=$(${pkgs.coreutils}/bin/du -sb "$d" | ${pkgs.coreutils}/bin/cut -f1)
            [ "$total" -le "$budget" ] && continue
            echo "Capping $d: $((total / 1024 / 1024 / 1024))G -> ${toString cfg.homeBuildCacheMaxGB}G"
            ${pkgs.findutils}/bin/find "$d" -type f -printf '%T@\t%s\t%p\n' \
              | ${pkgs.coreutils}/bin/sort -n \
              | ${pkgs.gawk}/bin/awk -v excess=$((total - budget)) \
                  'freed < excess {freed += $2; print $3}' \
              | ${pkgs.findutils}/bin/xargs -r rm -f
            ${pkgs.findutils}/bin/find "$d" -mindepth 1 -type d -empty -delete || true
          done
        '';
      };
    };

    systemd.timers.home-build-cache-cap = lib.mkIf cfg.homeBuildCacheCap {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*:23";
        RandomizedDelaySec = "5m";
        Persistent = true;
      };
    };
  };
}
