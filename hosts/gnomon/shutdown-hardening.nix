# gnomon shutdown hardening + post-journald diagnostics.
#
# Context: gnomon's final shutdown stage (the systemd-shutdown binary:
# SIGTERM → SIGKILL → unmount → detach loop/DM → reboot) has hung
# effectively forever on occasion. That phase runs *after*
# systemd-journald has exited, so it is structurally absent from
# `journalctl` — every boot's journal simply ends at "Journal stopped".
# The trigger is the qbittorrent/gluetun podman stack: overlay mounts +
# a network namespace + the podman0 bridge layered on a LUKS-backed
# btrfs root, which systemd-shutdown cannot always tear down from the
# still-live rootfs.
#
# The primary fix lives in modules/services/qbittorrent-vpn.nix (bounded
# container stop-timeouts + per-service TimeoutStopSec). This module is
# the host-wide *backstop* and the "so we can actually see it next time"
# instrumentation.
#
# Note on what is deliberately NOT set here: NixOS already enables
# `systemd.shutdownRamfs` (pivot to a tmpfs for the final unmount) and
# already wires `systemd-pstore.service` (archives /sys/fs/pstore into
# /var/lib/systemd/pstore on boot) by default. We rely on those rather
# than redundantly re-declaring them.
{...}: {
  # ── Backstop: bound the post-journald phase ───────────────────────────
  systemd.settings.Manager = {
    # The hardware watchdog (SP5100 TCO) is armed by systemd-shutdown for
    # the final phase. Default is 10min — i.e. a wedged teardown sits
    # dead for ten minutes before the board force-resets. systemd-shutdown
    # sync()s filesystems *before* the unmount loop that hangs, so a
    # watchdog-forced reset here lands after a global sync; on btrfs
    # (atomic transaction commits) that means journal replay and at most
    # a few seconds of un-fsynced writes, not structural corruption.
    # 60s turns "hung forever" into "reboots within a minute".
    RebootWatchdogSec = "60s";

    # Host-wide: don't let any unit burn the default 90s in the
    # journald-alive stop phase (where data is safest) and thereby feed
    # the post-journald stall. 45s is ample for every service on this
    # host; the podman units have their own tighter caps on top of this.
    DefaultTimeoutStopSec = "45s";
  };

  # ── Diagnostics: make the invisible phase visible next time ───────────
  boot.kernelParams = [
    # systemd-shutdown already logs unmount/detach failures (at default
    # level) to kmsg — the gap is persistence, since journald is gone and
    # the kernel only dumps kmsg to pstore on panic/oops by default. This
    # makes the kernel dump the ring buffer to the (efi-)pstore backend on
    # every reboot path, including a hardware-watchdog-forced reset, so
    # the final-phase messages survive into /sys/fs/pstore →
    # /var/lib/systemd/pstore.
    "printk.always_kmsg_dump=1"
  ];

  boot.kernel.sysctl = {
    # The actual smoking gun for a stuck unmount/detach is a task parked
    # in uninterruptible (D) sleep. The kernel scheduler is fully alive
    # during the final phase, so the hung-task detector will fire and
    # printk the blocked task's stack trace — which, combined with
    # always_kmsg_dump above, is then captured in pstore. Warn only;
    # never panic — we want the trace, not an even harder crash.
    "kernel.hung_task_timeout_secs" = 60;
    "kernel.hung_task_panic" = 0;
  };
}
