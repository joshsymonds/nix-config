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
      inputs.nix-flatpak.nixosModules.nix-flatpak
    ];

    # ── Keyboard: Mac-style Cmd modifier on the Q6 HE ───────────────────
    # leftmeta/rightmeta (physical Cmd in Mac mode) act as Ctrl globally,
    # so Cmd+C/V/T/W/etc. fire the Linux Ctrl+letter shortcuts in Firefox,
    # Slack, Electron apps, and so on. Kitty has a per-app exception so it
    # receives raw Super (and Ctrl+C/D in the terminal stays as untouched
    # interrupt/EOF). See modules/services/keyd.nix for the why.
    services.keyd-mac-style = {
      enable = true;
      users = ["joshsymonds"];
    };

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

    # ── HID device access for WebHID configurators ──────────────────────
    # Grant the seat-local user read/write on these devices' hidraw nodes
    # so Chromium's WebHID can open the vendor interface. Without uaccess
    # the device shows up in the picker but selection fails with "Failed
    # to select device".
    #   04f3:026e — SOLAKAKA E9 PRO mouse (driver.yuandaxin-tech.com)
    #   3434:0b60 — Keychron Q6 HE keyboard (launcher.keychron.com)
    services.udev.extraRules = ''
      KERNEL=="hidraw*", ATTRS{idVendor}=="04f3", ATTRS{idProduct}=="026e", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{idVendor}=="3434", ATTRS{idProduct}=="0b60", MODE="0660", TAG+="uaccess"
    '';

    # ── Bluetooth (for controllers, headphones) ─────────────────────────
    # DMS's control center handles pairing/connecting/battery via bluez
    # directly — no blueman-applet needed (and its tray icon is hideous).
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };

    # ── Gaming ──────────────────────────────────────────────────────────
    # Two compat tools land in Steam via extraCompatPackages:
    #   - proton-ge-bin: GE-Proton (community Proton fork). Required for
    #     Steam to install the Steam Linux Runtime sniper, and the Proton
    #     our wrapper delegates to.
    #   - proton-gamescope: a custom Steam compat tool that wraps GE-Proton
    #     in a niri-friendly gamescope (--backend sdl, --force-grab-cursor,
    #     full monitor resolution). Selected once in Steam → Settings →
    #     Compatibility → "Run other titles with…" → "Proton (Gamescope)"
    #     and it applies to every non-native game with no per-game launch
    #     options. Needed because xwayland-satellite has open fullscreen
    #     bugs with newer Wine/Proton (#165) that gamescope sidesteps.
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = false;
      gamescopeSession.enable = true;
      extraCompatPackages = with pkgs; [
        proton-ge-bin
        proton-gamescope
      ];
    };
    hardware.steam-hardware.enable = true;

    # gamescope module installs the binary + sets cap_sys_nice (needed for
    # gamescope's input-thread scheduling; without it gamescope warns and
    # cursor capture is flaky). Distinct from gamescopeSession above which
    # only adds the "boot to Steam Big Picture" session entry.
    programs.gamescope = {
      enable = true;
      capSysNice = true;
    };

    # ── Flatpak (declarative via nix-flatpak) ───────────────────────────
    # `services.flatpak.packages` is reconciled on activation: missing apps
    # are installed, declared apps are updated, and anything not on the list
    # is uninstalled (uninstallUnmanaged = true). The Flathub remote is
    # auto-added by nix-flatpak — no imperative `flatpak remote-add` needed.
    #
    # Why Zoom is here and not in nixpkgs: the official zoom-us client has
    # hard-coded /usr/share/xdg-desktop-portal/portals/ lookups for the
    # screencast path, and niri's portal layout doesn't match. The us.zoom.Zoom
    # Flatpak ships with the FHS layout Zoom expects, so screen sharing on
    # Wayland just works without the in-app config workarounds we used to
    # carry in home-manager/hosts/gnomon.nix (zoomus.conf).
    #
    # Persistence: /var/lib/flatpak is on @root (ephemeral). Without persisting
    # it, every reboot would re-download the GNOME runtime + Zoom (~500 MB).
    # See hosts/gnomon/disko.nix for the persistDirectories entry.
    services.flatpak = {
      enable = true;
      uninstallUnmanaged = true;
      packages = ["us.zoom.Zoom"];
    };

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
    boot.kernelParams = [
      "amd_pstate=active"
      "mitigations=auto"
    ];
    boot.kernelModules = ["kvm-amd"];

    # NVIDIA modules in initrd avoid the simpledrm → nvidia-drm mode-switch
    # flash on boot. Keeps the kernel console text-mode but at the panel's
    # native resolution from the first frame. (modesetting.enable in
    # gpu-nvidia.nix already sets nvidia-drm.modeset=1.)
    boot.initrd.kernelModules = ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"];

    # 5s grace to hit space for the recovery menu — long enough to actually
    # catch a misbehaving kernel without making routine boots feel sluggish.
    boot.loader.timeout = 5;

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
