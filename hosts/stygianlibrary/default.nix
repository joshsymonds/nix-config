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
    ../../modules/desktop/dms-niri.nix
    ../../modules/desktop/halmasuit.nix
    ../../modules/hardware/gpu-nvidia.nix
    inputs.lanzaboote.nixosModules.lanzaboote
  ];

  # ── Performance ──────────────────────────────────────────────────────
  performance.profile = "dev";
  performance.cpuVendor = "amd";

  # ── Platform ─────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfree = true;

  # ── GPU ─────────────────────────────────────────────────────────────
  # Same NVIDIA setup as gnomon. The whole point of this rig is to
  # reproduce gnomon's NVIDIA-specific behaviour.
  hardware.gpu-nvidia = {
    enable = true;
    enable32Bit = false;  # No Steam/Proton on a test rig.
  };

  # ── Bootloader: lanzaboote + systemd-boot fallback ──────────────────
  # Same shape as gnomon. UKIs go in /boot/EFI/Linux/; sbctl-signed
  # so Secure Boot works after enrollment. Plain systemd-boot is the
  # fallback if Secure Boot is off.
  boot.loader = {
    systemd-boot = {
      enable = lib.mkForce false;  # lanzaboote owns the bootloader
      configurationLimit = 8;
    };
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot";
    };
  };

  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";
    configurationLimit = 8;
  };

  # ── Kernel: latest CachyOS (matches gnomon) ─────────────────────────
  # Sourced from the same nix-cachyos-kernel input as gnomon. Attr
  # name is hyphen-style here (`linuxPackages-cachyos-latest`), not
  # nixpkgs's underscore style.
  boot.kernelPackages =
    inputs.nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-latest;

  # ── Kernel cmdline: mirror gnomon's quiet-boot policy ────────────────
  boot.kernelParams = [
    "amd_pstate=active"
    "mitigations=auto"
    "acpi_enforce_resources=lax"
    "quiet"
    "rd.udev.log_priority=3"
    "udev.log_level=3"
    "rd.systemd.show_status=false"
    "systemd.show_status=false"
    "vt.global_cursor_default=0"
    "fbcon=nodefer"
    # Native panel mode hint (matches gnomon's primary display).
    "video=2560x1440"
  ];

  # Epic #42 R6: consoleLogLevel=1 so kernel ERR/WARN don't reach the
  # console between BIOS handoff and halmasuit's first frame.
  boot.consoleLogLevel = 1;

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
    sbctl
    tailscale
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
