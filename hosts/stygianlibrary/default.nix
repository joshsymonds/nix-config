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
    # NO halmasuit, NO dms-niri, NO gpu-nvidia on the host: stygianlibrary
    # is a VFIO HOST that passes the entire NVIDIA GPU to a guest VM
    # where halmasuit runs. The host must NOT claim the GPU.
    # No lanzaboote (test rig, no sensitive data; saves install complexity).
  ];

  # ── Performance ──────────────────────────────────────────────────────
  performance.profile = "dev";
  performance.cpuVendor = "amd";

  # ── Platform ─────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfree = true;

  # ── VFIO: bind NVIDIA RTX 5070 Ti to vfio-pci at boot ────────────────
  # The whole point of stygianlibrary as a halmasuit test rig: pass
  # the 5070 Ti to a guest VM where halmasuit runs against real NVIDIA
  # hardware, reproducing gnomon's behavior bit-for-bit. The host
  # itself never uses the GPU — it's headless from the GPU's
  # perspective, displaying only its TTY via simpledrm/fbcon on the
  # motherboard's framebuffer (or nothing at all once VFIO claims).
  #
  # IOMMU group 13 on gnomon contains:
  #   10de:2c05 — NVIDIA GB203 (RTX 5070 Ti) VGA controller
  #   10de:22e9 — NVIDIA GB203 HDMI audio controller
  # Both must be bound to vfio-pci (audio function is in the same
  # group — kernel won't let us pass just one). The IDs are identical
  # on hardware-identical stygianlibrary.
  boot.kernelParams = [
    "amd_pstate=active"
    "mitigations=auto"
    "acpi_enforce_resources=lax"

    # IOMMU: required for VFIO. amd_iommu=on for AMD; iommu=pt
    # (pass-through) skips DMA-remapping for host devices (faster +
    # avoids quirks). Has zero effect on the passed-through guest
    # devices.
    "amd_iommu=on"
    "iommu=pt"

    # Bind the NVIDIA GPU + audio to vfio-pci BEFORE the nvidia driver
    # has a chance to claim them. This is the key VFIO directive on
    # single-GPU passthrough systems.
    "vfio-pci.ids=10de:2c05,10de:22e9"

    "quiet"
    "rd.udev.log_priority=3"
    "udev.log_level=3"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "vt.global_cursor_default=0"
    "fbcon=nodefer"
  ];

  # Load vfio-pci in initrd so it claims the NVIDIA device before
  # any in-tree driver gets a chance. Order matters: vfio_pci AFTER
  # vfio_iommu_type1, both BEFORE anything that would touch the GPU.
  boot.initrd.kernelModules = [
    "vfio_pci"
    "vfio"
    "vfio_iommu_type1"
  ];

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
    networkmanager.enable = false;  # systemd-networkd-managed; DHCP via networkd
    useNetworkd = true;
    firewall = {
      enable = true;
      trustedInterfaces = ["tailscale0"];
      allowedTCPPorts = [22];
      allowedUDPPorts = [config.services.tailscale.port];
      checkReversePath = "loose";  # tailscale forwarded packets
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
