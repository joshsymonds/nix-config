let
  network = import ../../lib/network.nix;
  self = network.hosts.gnomon;
  subnet = network.subnets.${self.subnet};
in
  {
    inputs,
    lib,
    pkgs,
    config,
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
    # proton-cachyos-x86_64-v3 (CachyOS Proton, AVX2/x86_64-v3 ISA build,
    # Steam Linux Runtime sniper variant) is the only Proton in the picker.
    # Comes from nix-gaming-edge (flake input), prebuilt and pulled from the
    # tokidoki cache below — no compile cost. Set once in Steam → Settings
    # → Compatibility → "Run other titles with…" → "Proton CachyOS x86_64-v3".
    #
    # No automatic gamescope wrapping. Two ways to get gamescope:
    #   - Big Picture: boot the "Steam (Gamescope)" greetd session
    #     (gamescopeSession.enable = true)
    #   - Per-game: add `gamescope -W 2560 -H 1440 -f -- %command%` to that
    #     game's Launch Options
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = false;
      gamescopeSession.enable = true;
      extraCompatPackages = with pkgs; [
        proton-cachyos-x86_64-v3
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

    # ── Mesa-git ────────────────────────────────────────────────────────
    # nix-gaming-edge's mesa-git module replaces the system mesa with the
    # latest from upstream git. On NVIDIA the GPU driver is unaffected
    # (proprietary blob via hardware.nvidia), but compositor infrastructure
    # — libgbm, libdrm, Vulkan loader/layers — all get bumped. Required to
    # land for two reasons even on NVIDIA:
    #   1. Steam's FHS env bundles stable libdrm; mesa-git refuses to load
    #      against it. The module's overlay rewrites buildFHSEnv to inject
    #      libdrm-git into every FHS sandbox so Steam keeps working.
    #   2. cacheCleanup wipes stale Mesa/Proton shader caches when those
    #      packages bump version, avoiding the "old shaders crash on new
    #      drivers" footgun. Pinned to proton-cachyos-x86_64-v3 below so
    #      Proton's DXVK/VKD3D caches also flush on upstream releases.
    #
    # Fallback: the module auto-creates a `stable-mesa` boot specialisation,
    # selectable at the systemd-boot menu if mesa HEAD regresses.
    drivers.mesa-git = {
      enable = true;
      enableCache = false; # cache wired in nix.settings below instead
      cacheCleanup = {
        enable = true;
        protonPackage = pkgs.proton-cachyos-x86_64-v3;
      };
    };

    # Caches scoped to gnomon — host-level rather than flake-level because
    # only gnomon consumes any of this content:
    #
    #   tokidoki  — mesa-git + proton-cachyos prebuilds (~30 min of clang
    #               otherwise). Wired by nix-gaming-edge.
    #   lantian   — xddxdd/nix-cachyos-kernel kernel binaries. Without
    #               it the kernel rebuilds from source on every bump.
    #   garnix    — fallback for cache hits lantian Attic is missing
    #               (lantian is on a free Garnix plan + their own Hydra).
    nix.settings = {
      extra-substituters = [
        "https://nix-cache.tokidoki.dev/tokidoki"
        "https://attic.xuyh0120.win/lantian"
        "https://cache.garnix.io"
      ];
      extra-trusted-public-keys = [
        "tokidoki:MD4VWt3kK8Fmz3jkiGoNRJIW31/QAm7l1Dcgz2Xa4hk="
        "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      ];
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

    # ── Kernel: CachyOS x86_64-v3 ───────────────────────────────────────
    # Overrides hosts/common.nix's mkDefault linuxPackages_latest. Same
    # mainline Linux source the rest of the fleet runs, with the CachyOS
    # patch stack on top (BORE-EEVDF scheduler, AutoFDO/PGO, x86_64-v3
    # ISA tuning). Symmetric with proton-cachyos-x86_64-v3 + mesa-git.
    # See flake.nix nix-cachyos-kernel comment for input rationale.
    #
    # nvidiaPackages.production is auto-derived by linuxPackagesFor —
    # the NVIDIA proprietary blob rebuilds against this kernel. No
    # special compat shims required; CachyOS is a major NVIDIA distro.
    boot.kernelPackages = inputs.nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-latest-x86_64-v3;

    # ── Boot: AM5 / 9800X3D ─────────────────────────────────────────────
    # amd_pstate=active matches the X3D's preferred frequency-driver mode.
    # mitigations=auto keeps default kernel mitigations; gamers sometimes pass
    # =off for a few % perf at security cost — explicit "auto" so the choice
    # is visible if you ever revisit it.
    # acpi_enforce_resources=lax: the IT8696E super-I/O on Gigabyte X870
    # boards declares its IO ports in ACPI, which the kernel refuses to
    # let drivers touch under default strict resource enforcement. lax
    # downgrades that refusal to a warning, so the out-of-tree it87
    # module below can claim the ports and expose fan tachs + PWM.
    boot.kernelParams = [
      "amd_pstate=active"
      "mitigations=auto"
      "acpi_enforce_resources=lax"
    ];

    # ── it87 fan tach / PWM (out-of-tree) ───────────────────────────────
    # Mainline it87 doesn't recognize the IT8689E/IT8696E chip IDs on
    # newer Gigabyte boards (X670/X870). The out-of-tree fork
    # (config.boot.kernelPackages.it87, ultimately frankcrawford/it87)
    # carries the ID additions. Exposes fan*_input (RPMs) and pwm*
    # (duty cycle) under /sys/class/hwmon/, which lm_sensors / hass-cli
    # can surface for monitoring.
    #
    # NB: lantian Attic does NOT pre-build kernel modules other than zfs,
    # so this rebuilds locally on every kernel bump. Few minutes per
    # `update`; acceptable trade for the fan visibility.
    boot.extraModulePackages = [config.boot.kernelPackages.it87];
    boot.kernelModules = ["kvm-amd" "it87"];

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
