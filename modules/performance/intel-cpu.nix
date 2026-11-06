# Intel CPU and I/O scheduler tuning based on performance profile
#
# Configures:
#   - intel_pstate driver mode
#   - CPU scaling governor (schedutil/powersave)
#   - Energy Performance Preference (EPP) via HWP
#   - NVMe and SSD I/O scheduler (performance.ioScheduler, default none)
#
# Intel-specific: the systemd service detects Intel CPUs at runtime
# and skips gracefully on AMD or other architectures.
#
# All values use lib.mkDefault so hosts can override.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.performance;

  # With intel_pstate=active, only "performance" and "powersave" governors
  # are available. HWP (Hardware P-States) handles dynamic scaling internally,
  # so "powersave" + an EPP hint is the equivalent of schedutil behavior.
  cpuSettings = {
    dev = {
      governor = "powersave";
      epp = "balance_performance";
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
  config = lib.mkIf (cfg.cpuVendor == "intel" && cfg.profile != "none" && cpu.governor != null) {
    # Ensure intel_pstate is active (HWP-aware mode)
    # No mkDefault here -- kernelParams is a list that merges via concatenation,
    # and mkDefault would cause the entire list to be discarded if the host
    # defines any kernelParams explicitly.
    boot.kernelParams = ["intel_pstate=active"];

    # Set governor and EPP at boot
    # Detects Intel CPU at runtime - exits cleanly on AMD
    systemd.services.cpu-performance-setup = {
      description = "Configure CPU governor and EPP for ${cfg.profile} profile";
      wantedBy = ["multi-user.target"];
      after = ["systemd-modules-load.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "cpu-performance-setup" ''
          set -euo pipefail

          # Check if intel_pstate is available
          if [ ! -d /sys/devices/system/cpu/intel_pstate ]; then
            echo "intel_pstate not available (AMD CPU or different driver) - skipping"
            exit 0
          fi

          # Set scaling governor on all CPUs
          for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            if [ -w "$gov" ]; then
              echo "${cpu.governor}" > "$gov"
            fi
          done
          echo "Set CPU governor to ${cpu.governor}"

          # Set Energy Performance Preference (requires HWP support)
          for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
            if [ -w "$epp" ]; then
              echo "${cpu.epp}" > "$epp"
            fi
          done
          echo "Set EPP to ${cpu.epp}"
        '';
      };
    };

    # I/O scheduler: performance.ioScheduler ('none' by default, optimal for NVMe
    # parallel queues and SSDs; 'bfq' where cgroup IO weights must take effect)
    services.udev.extraRules = ''
      ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="${cfg.ioScheduler}"
      ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="${cfg.ioScheduler}"
    '';
  };
}
