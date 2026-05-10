# Fleet-wide kernel hardening policy. Sysctls, kernelParams, and module
# blacklists here apply identically across every Linux host — the kernel
# build differs per host (latest / hardened / cachyos) but the policy is
# uniform. Defense-in-depth: hosts on linuxPackages_hardened already
# enforce many of these at compile time; setting them as runtime params
# is redundant but harmless there, and necessary on the non-hardened
# hosts (gnomon, vermissian).
{lib, ...}: {
  # ── Module blacklists ──────────────────────────────────────────────
  # Layered rationale (each group documented inline):
  #
  # AF_ALG family — closes the surface that produced CVE-2026-31431
  # ("Copy Fail"). 7.0 mainline fixed the specific bug; blacklisting
  # the whole family is defense-in-depth against the next vuln in the
  # same subsystem. dm-crypt/LUKS, kTLS, IPsec, OpenSSL default paths,
  # and SSH use the in-kernel crypto API directly, not AF_ALG, so
  # nothing on this fleet breaks.
  #
  # IPsec ESP / IPcomp / rxrpc — entry points for CVE-2026-43284
  # ("Dirty Frag", May 2026): xfrm scatterlist confusion → LPE via
  # corrupting page-cache pages of files like /etc/passwd. Tailscale
  # uses WireGuard (not IPsec), no AFS in fleet, so these auto-loaded
  # modules are pure attack surface for us.
  #
  # Dead protocol families — DCCP/SCTP/RDS/TIPC are niche cluster/
  # telecom protocols with multiple historical CVEs (CVE-2017-6074
  # DCCP UAF, CVE-2021-43267 TIPC remote heap overflow). The amateur-
  # radio / legacy WAN stacks (ax25/netrom/rose/n-hdlc/x25/decnet/
  # econet/ipx/appletalk/p8023/psnap/atm) are dead protocol families
  # with unaudited code. CAN bus has no automotive workload.
  #
  # Legacy filesystems — verbatim from NixOS's last canonical
  # profiles/hardened.nix (nixos-25.05, before the profile was
  # removed in 26.05). All historically vulnerable to parser bugs on
  # malformed images; blacklisting blocks autoprobe attacks via USB.
  # NTFS family kept enabled — user actively plugs in NTFS USBs.
  #
  # FireWire — IEEE-1394 grants direct memory access to attached
  # devices (DMA attack surface). Distinct from `thunderbolt` module
  # which is preserved (modern TB is PCIe-tunneling, not 1394).
  #
  # ksmbd — kernel-mode SMB server with multiple 2025 CVEs
  # (CVE-2025-37899 UAF in SMB2 LOGOFF found by an LLM, plus -21945
  # / -22041). Fleet uses NFS for media + Synology, never SMB.
  #
  # vivid — V4L2 test driver, CVE-2019-18683 LPE history. Not
  # auto-loaded by any normal hardware so this is pure surface
  # reduction at zero compatibility cost.
  boot.blacklistedKernelModules = [
    # AF_ALG family — CVE-2026-31431 ("Copy Fail")
    "af_alg"
    "algif_aead"
    "algif_hash"
    "algif_rng"
    "algif_skcipher"

    # IPsec ESP + IPcomp + rxrpc — CVE-2026-43284 ("Dirty Frag")
    "esp4"
    "esp6"
    "ipcomp4"
    "ipcomp6"
    "rxrpc"

    # Dead network protocols — niche cluster / telecom / amateur radio /
    # vendor stacks with unaudited code paths
    "dccp"
    "sctp"
    "rds"
    "tipc"
    "ax25"
    "netrom"
    "rose"
    "n-hdlc"
    "x25"
    "decnet"
    "econet"
    "ipx"
    "appletalk"
    "p8023"
    "psnap"
    "atm"
    "can"

    # Legacy filesystems — autoload-via-USB attack vector
    "freevxfs"
    "jffs2"
    "hfsplus"
    "hfs"
    "udf"
    "cramfs"
    "adfs"
    "affs"
    "bfs"
    "befs"
    "efs"
    "exofs"
    "f2fs"
    "hpfs"
    "jfs"
    "minix"
    "nilfs2"
    "omfs"
    "qnx4"
    "qnx6"
    "sysv"
    "ufs"
    "gfs2"

    # FireWire — DMA attack surface (distinct from thunderbolt)
    "firewire-core"
    "firewire-ohci"
    "firewire-sbp2"

    # Specific surfaces
    "ksmbd" # kernel SMB server, multiple 2025 CVEs
    "vivid" # V4L2 test driver, LPE history
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
