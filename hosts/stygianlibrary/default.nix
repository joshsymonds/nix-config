# stygianlibrary — halmasuit test rig on a Thunderbolt-attached NVMe.
#
# Hardware-identical to gnomon (same 9800X3D + 5070 Ti + X870), runs
# the same halmasuit + DMS Quickshell stack, but lives on a portable
# TB drive so it can be plugged into ANY hardware-identical host
# (currently: husband's PC) for iteration. The whole point is to
# reproduce gnomon's NVIDIA Wayland-EGL behavior without rebooting
# gnomon every test cycle.
#
# Differences from gnomon (deliberate):
#   - hostname `stygianlibrary` (legacy continuity; the drive was
#     stygianlibrary before too).
#   - DHCP networking (rig is portable; can't pin a static IP).
#   - Tailscale enabled (gives stable name regardless of which LAN it
#     boots on; SSH from gnomon goes over the tailnet).
#   - No yubikey-auth (interactive U2F enrollment is a hassle for a
#     test rig; password fallback is fine).
#   - No qbittorrent-vpn, no inference-stack, no keyd-mac-style, no
#     impermanence.persistence["/persist"]/comfyui (gnomon-only
#     workloads).
#   - No LUKS on root (see disko.nix — test rig, no sensitive data).
#   - Thunderbolt auto-authorize udev rule in initrd (the TB
#     enclosure must be authorized BEFORE the root NVMe enumerates).
#
# Same as gnomon (deliberate):
#   - halmasuit module with the exact same config — same wallpaper
#     shader, same DMS Quickshell greeter, same PAM stack. The
#     halmasuit module reads the same flake input we use on gnomon.
#   - gpu-nvidia module, NVIDIA initrd modules.
#   - it87 fan controller (X870 board has the same IT8696E chip).
#   - boot.consoleLogLevel = 1 (Epic #42 R6 — RDSEED32 suppression).
#   - Same lanzaboote / systemd-boot setup, signed UKIs.
#   - Same kernel cmdline (quiet, video=2560x1440, etc.).
{
  inputs,
  lib,
  pkgs,
  config,
  ...
}: {
  imports = [
    ./disko.nix
    ./hardware-configuration.nix
    # Repurposed 2026-08-14 (halmasuit VFIO testing paused): the host now
    # claims the GPU itself and runs the same llama-swap inference stack
    # as gnomon, serving Tiltyard local-model pilots headless. VFIO
    # binding removed below; re-add it if halmasuit testing resumes.
    # Still NO halmasuit / dms-niri (headless is the point — the full
    # 16 GB of VRAM stays free for model weights).
    # No lanzaboote (test rig, no sensitive data; saves install complexity).
    ../../modules/hardware/gpu-nvidia.nix
    ../../modules/services/inference-stack.nix
  ];

  # ── Performance ──────────────────────────────────────────────────────
  performance.profile = "dev";
  performance.cpuVendor = "amd";

  # ── Platform ─────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfree = true;

  # ── Kernel params ────────────────────────────────────────────────────
  # VFIO binding (vfio-pci.ids=…) removed 2026-08-14 — the host claims
  # the 5070 Ti for the inference stack now. Quiet-boot suppression
  # also removed (same change as gnomon): the silent console made the
  # 2026-08-14 "boot hang" (actually a dark VFIO'd display) undiagnosable
  # at the machine.
  boot.kernelParams = [
    "amd_pstate=active"
    "mitigations=auto"
    "acpi_enforce_resources=lax"
    "fbcon=nodefer"
  ];

  # ── GPU: host-claimed NVIDIA for llama.cpp ───────────────────────────
  # Same 610.43.02 new-feature-branch pin as gnomon (Blackwell fixes;
  # see gnomon/default.nix for the Xid 109 rationale). Same cachyos
  # kernel, so the pin carries over verbatim.
  hardware.gpu-nvidia = {
    enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      version = "610.43.02";
      sha256_64bit = "sha256-MDSgVLtM33dS/43CclZMsQVROAS/9TU4lFkBsWyndGM=";
      openSha256 = "sha256-hP5NVZZ4vGsACHLmUDKq4uckpd/kn1GxCSYnnJfAuBs=";
      settingsSha256 = "sha256-0YAhufRgjDW+uR+kjaTb154fibpcDw8QowfrucoZsKE=";
      persistencedSha256 = "sha256-Whgv9X+v2fRhzliOl2LzltY9v1SxDafFfv3IUPqj/hk=";
    };
  };

  # ── Inference stack: llama-swap + llama-server (mirror of gnomon) ────
  # Headless llama-swap on 11434 (loopback; reach it over an SSH
  # tunnel), no Open-WebUI. Model entries mirror gnomon's qwen3.8
  # pair — flag rationale lives with gnomon's entries.
  services.inference-stack = {
    enable = true;
    openWebUI.enable = false;
    models = let
      base = "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main";
      # Explicit -ngl instead of --fit: fit mis-probes when anything else
      # holds VRAM, and these splits are measured on this exact card
      # (headless, 2026-08-14): iq4xs 58/65 at 96k ctx = 20.6 tok/s gen /
      # 134 pp (64/65 at 32k did 36.4/243); q3kxl 65/65 = 52.8 gen / 460 pp.
      # 96k window + q4 KV: attempt1 of the Tiltyard pilot truncated the
      # subagent-chain scenario at 32k. q4_0 KV keeps the bigger window
      # affordable (q8 at 96k cost 3.1 GB); -ctxcp/--cache-ram give the
      # hybrid-SSM arch restorable prompt states so interleaved eval
      # cells stop reprocessing full transcripts every swap.
      qwenCommon = [
        "-c"
        "98304"
        "-np"
        "1"
        "-fa"
        "on"
        "--mlock"
        "--no-mmap"
        "-ctk"
        "q4_0"
        "-ctv"
        "q4_0"
        "-ctxcp"
        "8"
        "--cache-ram"
        "16384"
        "--no-context-shift"
        "--jinja"
        "--reasoning-format"
        "deepseek"
        # Server-default sampling = Qwen's thinking-mode recommendation.
        # Raw Tiltyard seats override per-request via extra_body; these
        # defaults exist for harness clients (qwen-code) that don't send
        # sampling parameters.
        "--temp"
        "1.0"
        "--top-p"
        "0.95"
        "--top-k"
        "20"
        "--min-p"
        "0.0"
      ];
    in {
      "qwen3.8-27b-iq4xs" = {
        ggufUrl = "${base}/Qwen3.8-27B-IQ4_XS.gguf";
        flags = qwenCommon ++ ["-ngl" "58" "-b" "512" "-ub" "512"];
      };
      "qwen3.8-27b-q3kxl" = {
        ggufUrl = "${base}/Qwen3.8-27B-UD-Q3_K_XL.gguf";
        flags = qwenCommon ++ ["-ngl" "62" "-b" "512" "-ub" "512"];
      };
    };
  };

  # Add joshsymonds to libvirtd / kvm groups so they can drive VMs
  # without sudo every time. Mirror's NixOS's standard libvirtd UX.
  users.users.joshsymonds.extraGroups = ["libvirtd" "kvm"];

  # ── Bootloader: plain systemd-boot, no Secure Boot ───────────────────
  # No lanzaboote (see imports above for rationale). systemd-boot
  # writes UKIs to /boot/EFI/systemd/ on stock NixOS-managed paths;
  # the firmware boot menu picks them up via canTouchEfiVariables.
  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 8;
    };
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot";
    };
  };

  # ── Kernel: latest CachyOS (matches gnomon) ─────────────────────────
  # Sourced from the same nix-cachyos-kernel input as gnomon. Attr
  # name is hyphen-style here (`linuxPackages-cachyos-latest`), not
  # nixpkgs's underscore style.
  boot.kernelPackages =
    inputs.nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-latest;

  # ── Virtualization stack: libvirt + qemu for VFIO VMs ────────────────
  # OVMF (UEFI firmware for the guest) is bundled with qemu now and
  # doesn't need the explicit `ovmf` submodule that older NixOS had.
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = false;
    };
    onShutdown = "shutdown";
  };

  programs.virt-manager.enable = true;

  # ── VFIO test-runner access (Epic #45) ───────────────────────────────
  # stygianlibrary doubles as the halmasuit NVIDIA test runner: it runs
  # `nix run .#checks…<test>.driver` (the non-sandboxed nixosTest driver)
  # with the 5070 Ti passed through to the guest. Two host prerequisites
  # the default libvirtd setup does NOT grant the invoking user:
  #
  #   1. The IOMMU-group device node /dev/vfio/<group> is created
  #      root:root 0600 — only root can open it. The runner user
  #      (joshsymonds, already in `kvm`) needs it. A udev rule hands the
  #      vfio nodes to the kvm group, 0660. Scoped to the `vfio`
  #      subsystem so it touches only /dev/vfio/* (the group nodes +
  #      /dev/vfio/vfio), nothing else.
  #   2. qemu with vfio-pci pins ALL guest RAM (the device can DMA
  #      anywhere), so the process needs RLIMIT_MEMLOCK >= guest memory.
  #      The default soft/hard memlock is 8 MiB — far below a multi-GiB
  #      guest. Raise it to unlimited for the kvm group (pam_limits
  #      applies it to the SSH login session the driver runs under).
  #
  # Both are runner-only conveniences; neither weakens the host's own
  # boundary (the GPU is already vfio-bound and unused by the host).
  services.udev.extraRules = ''
    SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm", MODE="0660"
  '';

  security.pam.loginLimits = [
    {
      domain = "@kvm";
      type = "hard";
      item = "memlock";
      value = "unlimited";
    }
    {
      domain = "@kvm";
      type = "soft";
      item = "memlock";
      value = "unlimited";
    }
  ];

  # ── Thunderbolt: auto-authorize so root NVMe enumerates ──────────────
  # The ACASIS TBU405AIR enclosure must be Thunderbolt-authorized
  # before the NVMe inside it appears as a block device. Without this
  # rule, initrd would mount-fail (or stall on disk-not-found) on
  # every boot. Copied verbatim from the prior stygianlibrary config
  # — proven pattern.
  boot.initrd.services.udev.rules = ''
    ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
  '';

  # ── Networking: DHCP + Tailscale ─────────────────────────────────────
  # Portable rig — no static IP. Tailscale gives a stable hostname on
  # the tailnet (e.g. `stygianlibrary.tail-XXXX.ts.net`) so SSH from
  # gnomon works regardless of which LAN the rig is on.
  networking = {
    hostName = "stygianlibrary";
    useDHCP = true;
    networkmanager.enable = false; # systemd-networkd-managed; DHCP via networkd
    useNetworkd = true;
    firewall = {
      enable = true;
      trustedInterfaces = ["tailscale0"];
      allowedTCPPorts = [22];
      allowedUDPPorts = [config.services.tailscale.port];
      checkReversePath = "loose"; # tailscale forwarded packets
    };
  };

  systemd.network.networks."10-lan" = {
    matchConfig.Name = "en*";
    networkConfig.DHCP = "yes";
    dhcpV4Config.UseDNS = true;
  };

  services.tailscale = {
    enable = true;
    package = pkgs.tailscale;
    useRoutingFeatures = "client";
    openFirewall = true;
  };

  # ── mDNS / Avahi: first-boot discovery on husband's LAN ──────────────
  # Tailscale gives a stable name on the tailnet, but FIRST boot needs
  # an initial `tailscale up` — which requires SSH access. mDNS solves
  # the chicken-and-egg: on any LAN, the rig is reachable as
  # `stygianlibrary.local` once it's DHCP'd and avahi has published.
  #
  # Bootstrap flow:
  #   1. Plug in TB drive, boot husband's PC.
  #   2. From any LAN host: `ssh joshsymonds@stygianlibrary.local`
  #      (key-only auth; the keys from common.nix already work).
  #   3. On the rig: `sudo tailscale up` (browser auth via tailscale
  #      admin console).
  #   4. From then on: `ssh stygianlibrary` works over the tailnet from
  #      anywhere.
  #
  # nssmdns4 wires Avahi into the system's name resolution so anything
  # using glibc's getaddrinfo (ssh, curl, etc.) resolves *.local names.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      domain = true;
      hinfo = true;
      workstation = true;
    };
    # mDNS uses UDP 5353; firewall already trusts tailscale0 and
    # allows TCP 22. Open 5353 explicitly on the LAN interface so
    # mDNS announcements traverse it. Without this, avahi listens
    # but the firewall drops inbound queries from the router /
    # other LAN hosts.
    openFirewall = true;
  };

  # ── SSH ──────────────────────────────────────────────────────────────
  # Key-only auth (joshsymonds keys defined in common.nix, including
  # josh+gnomon@joshsymonds.com so this Claude session can connect).
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  environment.systemPackages = with pkgs; [
    tailscale
    qemu_kvm
    virt-viewer
    # Convenience for iteration on the rig: editor + journal + diff.
    vim
    git
    htop
  ];

  # Cap network-wait time. Same as gnomon — don't block boot for 120s
  # if the network is down.
  systemd.network.wait-online = {
    anyInterface = true;
    timeout = 10;
  };

  # ── State version ────────────────────────────────────────────────────
  system.stateVersion = "25.05";
}
