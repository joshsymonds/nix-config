# AMD CPU tuning based on performance profile
#
# Configures:
#   - amd_pstate driver in active mode (required for Zen 4+/Zen 5)
#   - CPU scaling governor (schedutil/performance/powersave)
#   - Energy Performance Preference (EPP) via CPPC
#   - Preferred core scheduling (critical for 3D V-Cache CPUs like 9800X3D)
#   - NVMe and SSD I/O scheduler (none - best for parallel queues)
#
# AMD-specific: the systemd service detects AMD CPUs at runtime
# and skips gracefully on Intel or other architectures.
#
# All values use lib.mkDefault so hosts can override.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.performance;

  # With amd_pstate=active, only "performance" and "powersave" governors
  # are available. CPPC handles dynamic scaling internally, so "powersave"
  # + an EPP hint is the equivalent of schedutil behavior.
  cpuSettings = {
    dev = {
      governor = "performance";
      epp = "performance";
    };
    server = {
      governor = "powersave";
      epp = "balance_performance";
    };
    workstation = {
      governor = "performance";
      epp = "performance";
    };
    constrained = {
      governor = "powersave";
      epp = "power";
    };
    router = {
      governor = "powersave";
      epp = "balance_power";
    };
    none = {
      governor = null;
      epp = null;
    };
  };

  cpu = cpuSettings.${cfg.profile};
in {
  config = lib.mkIf (cfg.cpuVendor == "amd" && cfg.profile != "none" && cpu.governor != null) {
    # amd_pstate in active mode - enables CPPC and preferred core ranking
    # Critical for 3D V-Cache CPUs (9800X3D) where the kernel needs to know
    # which cores have the best performance characteristics
    # No mkDefault here -- kernelParams is a list that merges via concatenation,
    # and mkDefault would cause the entire list to be discarded if the host
    # defines any kernelParams explicitly.
    boot.kernelParams = ["amd_pstate=active"];

    # Set governor and EPP at boot
    # Detects AMD CPU at runtime - exits cleanly on Intel
    systemd.services.cpu-performance-setup-amd = {
      description = "Configure AMD CPU governor and EPP for ${cfg.profile} profile";
      wantedBy = ["multi-user.target"];
      after = ["systemd-modules-load.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "cpu-performance-setup-amd" ''
          set -euo pipefail

          # Check if amd_pstate is available
          if [ ! -d /sys/devices/system/cpu/amd_pstate ]; then
            echo "amd_pstate not available (Intel CPU or different driver) - skipping"
            exit 0
          fi

          # Set scaling governor on all CPUs
          for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            if [ -w "$gov" ]; then
              echo "${cpu.governor}" > "$gov"
            fi
          done
          echo "Set CPU governor to ${cpu.governor}"

          # Set Energy Performance Preference (CPPC)
          for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            if [ -w "$epp" ]; then
              echo "${cpu.epp}" > "$epp"
            fi
          done
          echo "Set EPP to ${cpu.epp}"

          # Log preferred core status (informational for V-Cache CPUs)
          if [ -f /sys/devices/system/cpu/amd_pstate/prefcore ]; then
            prefcore=$(cat /sys/devices/system/cpu/amd_pstate/prefcore)
            echo "AMD preferred core scheduling: $prefcore"
          fi
        '';
      };
    };

    # I/O scheduler: 'none' is optimal for NVMe (parallel queue hardware)
    # and SSDs (no rotational latency to optimize for)
    services.udev.extraRules = ''
      ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="256"
      ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
    '';
  };
}
