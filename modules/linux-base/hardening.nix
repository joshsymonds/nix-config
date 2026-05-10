# Fleet-wide kernel hardening policy. Sysctls, kernelParams, and module
# blacklists here apply identically across every Linux host — the kernel
# build differs per host (latest / hardened / cachyos) but the policy is
# uniform. Defense-in-depth: hosts on linuxPackages_hardened already
# enforce many of these at compile time; setting them as runtime params
# is redundant but harmless there, and necessary on the non-hardened
# hosts (gnomon, vermissian).
{lib, ...}: {
  # ── Module blacklists ──────────────────────────────────────────────
  # AF_ALG userspace crypto API — unused fleet-wide. Removing it closes
  # the surface that produced CVE-2026-31431 ("Copy Fail"): a local
  # user with AF_ALG sockets + splice() can write 4 bytes into any
  # page-cache page (typical target: setuid binaries). 7.0 mainline
  # fixed the specific bug; blacklisting the whole family is defense-
  # in-depth against the next vuln in the same subsystem. Does NOT
  # break dm-crypt/LUKS, kTLS, IPsec, OpenSSL default paths, or SSH —
  # those use the in-kernel crypto API directly, not AF_ALG.
  #
  # Cold-attack-surface filesystems: legacy formats kept for
  # compatibility, historically vulnerable to parser bugs on malformed
  # images. Blocking autoload means an attacker who can plug in a USB
  # stick can't trigger one of their CVEs by autoprobe.
  #
  # NOT blacklisted: thunderbolt / thunderbolt-net — gnomon uses a
  # Thunderbolt drive intermittently.
  boot.blacklistedKernelModules = [
    # AF_ALG family — see CVE-2026-31431
    "af_alg"
    "algif_aead"
    "algif_hash"
    "algif_rng"
    "algif_skcipher"

    # Legacy / cold-attack-surface filesystems
    "freevxfs"
    "jffs2"
    "hfsplus"
    "udf"
    "cramfs"
  ];

  # ── Memory-corruption mitigation kernelParams ──────────────────────
  # All cheap or zero-cost except init_on_free (~1–3% on memory-heavy
  # workloads), which kills most UAF and uninit-read exploit primitives.
  # Verified compatible with NVIDIA proprietary, podman, jellyfin
  # transcoding, Docker, and gaming workloads.
  boot.kernelParams = [
    "slab_nomerge" # no cross-cache aliasing for heap-spray
    "init_on_alloc=1" # zero pages at alloc
    "init_on_free=1" # zero pages at free
    "page_alloc.shuffle=1" # randomize free-list order
    "randomize_kstack_offset=on" # per-syscall kernel stack offset
    "vsyscall=none" # kill legacy vsyscall page (ROP gadget removal)
  ];

  # ── Sysctl hardening ───────────────────────────────────────────────
  # unprivileged_userns_clone is INTENTIONALLY left at 1. linux-hardened
  # defaults it to 0, which would break chromium's sandbox (used on
  # ultraviolet via X11VNC), bubblewrap-based isolation, and rootless
  # podman if we ever add it. The user-namespace primitive is genuinely
  # useful; the historical CVEs around it are mostly closed.
  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.kexec_load_disabled" = 1;
    "kernel.yama.ptrace_scope" = 1;
    "kernel.unprivileged_bpf_disabled" = 2;
    "net.core.bpf_jit_harden" = 2;
    # Override linux-hardened default (0); chromium sandbox needs this.
    "kernel.unprivileged_userns_clone" = lib.mkForce 1;
  };
}
