# On resume from S3 suspend, systemd replays all Persistent= timers that
# fired while the machine was asleep.  On gnomon this means nix-gc and
# nix-optimise start within seconds of each other and hammer the NVMe,
# making the desktop sluggish for several minutes.  Observed 2026-06-29:
# PSI io ~40%, CPU pressure ~0, both jobs in D state, load average ~8.
#
# IOSchedulingClass=idle is the change that matters: I/O was the measured
# bottleneck (PSI io ~40% while CPU pressure ~0), so putting these jobs at
# the bottom of the I/O queue lets interactive reads jump ahead of them.
#
# Nice=19 instead of CPUSchedulingPolicy=idle: nix-gc and nix-optimise hold
# the Nix DB / GC lock.  SCHED_IDLE can starve a lock-holder under CPU
# saturation, which would stall a foreground `nix build` waiting on the
# same lock.  Nice=19 deprioritizes CPU without that inversion risk.
#
# fstrim is deliberately absent: the btrfs hosts trim continuously via
# discard=async and disable the periodic fstrim batch outright (see
# modules/disko/btrfs-impermanence.nix), and the ext4 hosts that keep
# fstrim are headless servers with no interactive I/O to protect.
#
# Fleet-wide on purpose: servers never suspend, but they also benefit from
# gc/optimise never starving service I/O.  The hygiene is correct
# everywhere; only gnomon triggered the observation.
{...}: let
  idlePriority = {
    IOSchedulingClass = "idle";
    Nice = 19;
  };
in {
  systemd.services.nix-gc.serviceConfig = idlePriority;
  systemd.services.nix-optimise.serviceConfig = idlePriority;
}
