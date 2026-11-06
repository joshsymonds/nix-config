# Performance profile selector
#
# Imports sub-modules and exposes a single option: performance.profile
# Each profile configures memory, network, and CPU tuning appropriate
# for the host's role.
#
# Profiles:
#   dev         - Bursty dev workloads (schedutil, low swappiness, MGLRU, BBR)
#   server      - Steady-state services (schedutil, moderate swappiness, MGLRU, BBR)
#   workstation - GPU compute / high-perf (performance governor, MGLRU, BBR, no zram)
#   constrained - Low-resource hosts (powersave, high swappiness, no MGLRU)
#   router      - Network-optimized (schedutil, BBR, minimal memory tuning)
#   none        - No tuning applied (default)
{lib, ...}: {
  imports = [
    ./memory.nix
    ./network.nix
    ./intel-cpu.nix
    ./amd-cpu.nix
  ];

  options.performance = {
    profile = lib.mkOption {
      type = lib.types.enum ["dev" "server" "workstation" "constrained" "router" "none"];
      default = "none";
      description = "Performance profile to apply. Sub-modules read this value to configure memory, network, and CPU tuning.";
    };

    cpuVendor = lib.mkOption {
      type = lib.types.enum ["intel" "amd" "none"];
      default = "none";
      description = "CPU vendor for pstate driver and governor tuning. Set to 'intel' or 'amd' to enable vendor-specific CPU tuning.";
    };

    ioScheduler = lib.mkOption {
      type = lib.types.enum ["none" "bfq" "mq-deadline" "kyber"];
      default = "none";
      description = "I/O scheduler for NVMe and non-rotational SATA disks. 'none' maximizes raw IOPS; 'bfq' honors cgroup IOWeight so background jobs yield the disk.";
    };
  };
}
