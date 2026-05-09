let
  network = import ../../lib/network.nix;
  self = network.hosts.gnomon;
  subnet = network.subnets.${self.subnet};
in
  {
    inputs,
    lib,
    pkgs,
    ...
  }: {
    imports = [
      ./disko.nix
      ../../modules/desktop/dms-niri.nix
      ../../modules/hardware/gpu-nvidia.nix
      ../../modules/services/keyd.nix
      inputs.lanzaboote.nixosModules.lanzaboote
    ];

    # ── Keyboard: Mac-style Cmd modifier on the Q6 HE ───────────────────
    # leftmeta/rightmeta (physical Cmd in Mac mode) act as Ctrl globally,
    # so Cmd+C/V/T/W/etc. fire the Linux Ctrl+letter shortcuts in Firefox,
    # Slack, Electron apps, and so on. Kitty has a per-app exception so it
    # receives raw Super (and Ctrl+C/D in the terminal stays as untouched
    # interrupt/EOF). See modules/services/keyd.nix for the why.
    services.keyd-mac-style.enable = true;

    # ── Performance profile ─────────────────────────────────────────────
    performance.profile = "dev";
    performance.cpuVendor = "amd";

    # ── Platform ────────────────────────────────────────────────────────
    nixpkgs.hostPlatform = "x86_64-linux";
    nixpkgs.config.allowUnfree = true;

    # ── CPU & GPU ───────────────────────────────────────────────────────
    hardware.cpu.amd.updateMicrocode = true;
    hardware.enableAllFirmware = true;
    hardware.enableRedistributableFirmware = true;

    hardware.gpu-nvidia = {
      enable = true;
      enable32Bit = true; # Steam/Proton, 32-bit Wine
      cudaArches = ["12.0"]; # Blackwell sm_120 (RTX 50-series)
    };

    # ── Desktop session (niri + DMS, see modules/desktop/dms-niri.nix) ──
    desktop.dms-niri.enable = true;

    # ── Keyboard: Caps Lock → Escape, everywhere ────────────────────────
    # services.xserver.xkb drives /etc/X11/xkb + XKB_DEFAULT_* env vars,
    # which greetd and Wayland compositors (incl. niri's defaults) pick up.
    # console.useXkbConfig propagates the same to TTYs (Ctrl+Alt+F1..F6).
    services.xserver.xkb.options = "caps:escape";
    console.useXkbConfig = true;

    # ── Bluetooth (for controllers, headphones) ─────────────────────────
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    services.blueman.enable = true;

    # ── Gaming ──────────────────────────────────────────────────────────
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = false;
      gamescopeSession.enable = true;
    };
    hardware.steam-hardware.enable = true;

    # ── 1Password ───────────────────────────────────────────────────────
    # Enabling at system level provides:
    #   - `op` CLI on PATH
    #   - SSH-agent unix socket (~/.1password/agent.sock) for git/ssh signing
    #   - PolicyKit integration so the GUI can prompt for system auth
    #     (Quick Unlock, app permissions). polkitPolicyOwners is the list
    #     of users allowed to invoke that.
    programs._1password.enable = true;
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = ["joshsymonds"];
    };

    # ── Boot: lanzaboote-signed UKI ─────────────────────────────────────
    boot.bootspec.enable = true;
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };

    # ── Boot: AM5 / 9800X3D ─────────────────────────────────────────────
    # amd_pstate=active matches the X3D's preferred frequency-driver mode.
    # mitigations=auto keeps default kernel mitigations; gamers sometimes pass
    # =off for a few % perf at security cost — explicit "auto" so the choice
    # is visible if you ever revisit it.
    #
    # The quiet/loglevel/rd.* family suppresses dmesg + udev + systemd unit
    # spam so plymouth can own the screen from initrd through stage 2.
    # `splash` is the conventional flag plymouth's generator looks for.
    boot.kernelParams = [
      "amd_pstate=active"
      "mitigations=auto"
      "quiet"
      "loglevel=3"
      "rd.systemd.show_status=false"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
      "splash"
    ];
    boot.kernelModules = ["kvm-amd"];
    boot.consoleLogLevel = 0;
    boot.initrd.verbose = false;

    # ── Boot: graphical splash (plymouth) ──────────────────────────────
    # `bgrt` reads the firmware's BGRT ACPI table and renders the same
    # logo the BIOS just showed, with an animated spinner. Visually this
    # is a seamless handoff: POST logo → identical logo + spinner →
    # greetd, with no scrolling text in between.
    #
    # Plymouth files land in the initrd, which lanzaboote bakes into the
    # signed UKI — so the UKI grows by a few MB but no extra wiring is
    # needed for secure boot.
    #
    # NVIDIA modules in initrd let plymouth render via the real GPU from
    # the first frame; without this, plymouth falls back to simpledrm at
    # boot-framebuffer resolution and there's a visible mode-switch flash
    # when nvidia takes over later. (modesetting.enable in gpu-nvidia.nix
    # already sets nvidia-drm.modeset=1.)
    boot.plymouth = {
      enable = true;
      theme = "bgrt";
    };
    boot.initrd.kernelModules = ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"];

    # 1s grace to hit space for the recovery menu without lingering.
    boot.loader.timeout = 1;

    # ── Boot: initrd hardware modules ──────────────────────────────────
    # Standard for AM5 NVMe + USB. If real hardware reveals missing modules
    # at install time, fold them into THIS file in a follow-up commit.
    boot.initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "ahci"
      "usbhid"
      "usb_storage"
      "sd_mod"
    ];

    # ── Networking: static IP via systemd-networkd, wildcard interface match ──
    # Same pattern as ultraviolet/vermissian — no hardcoded interface name.
    # The actual NIC (whatever its kernel-assigned `enX` name is) is matched
    # by the `en*` glob, so changing motherboards or upgrading the kernel's
    # device naming doesn't break the static-IP config.
    networking = {
      useDHCP = false;
      useNetworkd = true; # disable legacy scripted networking; systemd-networkd handles it
      hostName = "gnomon";
      firewall = {
        enable = true;
        trustedInterfaces = ["tailscale0"];
        allowedTCPPorts = [22];
      };
    };

    # ── Tailscale ───────────────────────────────────────────────────────
    # Workstation-mode client: no subnet routing, no exit-node advertising.
    # `openFirewall = true` opens the WireGuard UDP port automatically;
    # tailscale0 is in trustedInterfaces above so peers can reach local services.
    services.tailscale = {
      enable = true;
      package = pkgs.tailscale;
      useRoutingFeatures = "client";
      openFirewall = true;
    };

    environment.systemPackages = with pkgs; [sbctl tailscale];

    systemd.network.wait-online.anyInterface = true;
    systemd.network.networks."10-lan" = {
      matchConfig.Name = "en*";
      address = ["${self.ip}/${toString subnet.prefixLength}"];
      gateway = [subnet.gateway];
      dns = subnet.nameservers;
    };

    # ── State version ───────────────────────────────────────────────────
    system.stateVersion = "25.05";
  }
