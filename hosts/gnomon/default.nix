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
      # cudaArches deliberately left at module default (empty list).
      # Pinning to ["12.0"] (Blackwell-only) was technically tighter
      # but every CUDA package's hash diverged from cache.nixos-cuda.org
      # — forcing ~45-min local rebuilds for onnxruntime, pytorch,
      # ollama-cuda, etc. on every bump. Broad targeting matches the
      # public CI cache, so updates download instead of rebuilding.
      # Runtime perf is identical on a single-arch system (the unused
      # SMs just sit dead in the binary).
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

    # ── Bluetooth: disabled ─────────────────────────────────────────────
    # Probed live: zero connected devices, zero paired devices, no
    # journal activity in 7+ days. The radio was on but unused. Disabling
    # the userspace stack here; the bluetooth + btusb kernel modules are
    # not blacklisted on gnomon (only on servers via server-hardening.nix)
    # so a future re-enable just needs flipping this back to true.
    hardware.bluetooth.enable = false;

    # ── Gaming ──────────────────────────────────────────────────────────
    # Two Proton tools in Steam → Settings → Compatibility:
    #
    #   "Proton CachyOS x86_64-v3" — bare proton-cachyos from nix-gaming-edge
    #     (AVX2/x86_64-v3 ISA build, Steam Linux Runtime sniper variant).
    #     Prebuilt and pulled from the tokidoki cache below — no compile cost.
    #
    #   "Proton CachyOS (Gamescope)" — local pkgs/proton-gamescope wrapper.
    #     Drops a 2560x1440 fullscreen gamescope between Steam Linux Runtime
    #     and Proton, so every Windows game gets a niri-friendly stable
    #     Wayland surface instead of fighting xwayland-satellite. Set this
    #     ONCE as the default ("Run other titles with…") and forget it.
    #     Also exports PROTON_ENABLE_NVAPI=1 so RE Engine titles (PRAGMATA,
    #     RE4R, MH Wilds, DD2) can probe the NVIDIA GPU and unlock RT/DLSS.
    #
    #   Per-game escape hatches (Steam → Properties → Launch Options):
    #     PROTON_GAMESCOPE_DISABLE=1     bypass gamescope (EAC titles, etc.)
    #     PROTON_GAMESCOPE_FORCE_GRAB=1  force pointer lock (buggy FPS games)
    #     PROTON_ENABLE_NVAPI=0          hide NVIDIA GPU again (rare)
    #
    # gamescopeSession.enable below adds a separate "Steam (Gamescope)"
    # greetd login session for Big Picture mode — unrelated to the
    # per-game wrapping that proton-gamescope provides.
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = false;
      gamescopeSession.enable = true;
      extraCompatPackages = with pkgs; [
        proton-cachyos-x86_64-v3
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

    # Expose gamescope's WSI Vulkan implicit layer (VkLayer_FROG_gamescope_wsi)
    # to the Vulkan loader. programs.gamescope.enable only adds the binary
    # to system PATH via a makeWrapper wrapper that drops share/vulkan/.
    # hardware.graphics.extraPackages symlinks the unwrapped package's
    # share/vulkan/implicit_layer.d/ into /run/opengl-driver/share/vulkan/
    # where pressure-vessel / the SLR sniper's Vulkan loader will find it.
    # Without this, the WSI layer is built (enableWsi = true in the gaming
    # overlay) but never loaded — gamescope's xwm dedup path fires for
    # every commit and gamescope output is permanently black on NVIDIA
    # for any vkd3d-proton or DXVK game.
    hardware.graphics.extraPackages = [pkgs.gamescope];

    # Substituters live in modules/nix/substituters.nix (single source
    # of truth, feature-gated). gnomon picks up tokidoki + lantian +
    # garnix automatically because programs.steam.enable=true below,
    # and the CUDA cache because hardware.gpu-nvidia.enable=true above.

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

    # ── Kernel: CachyOS latest (generic march) ──────────────────────────
    # Overrides hosts/common.nix's mkDefault linuxPackages_latest. Same
    # mainline Linux source the rest of the fleet runs, with the CachyOS
    # patch stack on top (BORE-EEVDF scheduler, cachy patchset, BBR3).
    # Those patches are where CachyOS earns its tail-latency wins —
    # independent of march flag.
    #
    # Was -x86_64-v3 previously. Switched off because cache.garnix.io
    # ships exactly four xddxdd variants — latest{,-lto}, lts{,-lto} —
    # and the v3-suffixed variants are not among them. Eating 25–30 min
    # from-source rebuild per kernel bump for sub-1% kernel perf was
    # the wrong trade: the kernel forbids SSE/AVX outside
    # kernel_fpu_begin/end via arch/x86/Makefile -mno-* flags, so
    # -march=v3 can only enable narrow GPR instructions (BMI1/2, LZCNT,
    # MOVBE) in kernel code; SIMD subsystems like crypto/RAID are
    # runtime-dispatched via alternative_call regardless of -march.
    # Userspace v3 (proton-cachyos) keeps its v3 builds where AVX2
    # actually fires in hot loops; the kernel is generic and
    # substituted from garnix.
    #
    # The -lto variant is also on garnix but skipped — clang+ThinLTO
    # would force the out-of-tree it87 module below to build with LLVM
    # too (kernelModuleLLVMOverride), and the LTO kernel-perf gain
    # doesn't pay for that integration work.
    #
    # nvidiaPackages.production is auto-derived by linuxPackagesFor —
    # the NVIDIA proprietary blob rebuilds against this kernel. No
    # special compat shims required; CachyOS is a major NVIDIA distro.
    boot.kernelPackages = inputs.nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-latest;

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
    boot.extraModulePackages = [
      config.boot.kernelPackages.it87
      config.boot.kernelPackages.v4l2loopback
    ];
    boot.kernelModules = ["kvm-amd" "it87" "v4l2loopback"];

    # v4l2loopback: virtual /dev/video device that OBS (or any other
    # producer) writes into, so Zoom / Meet / Firefox see it as a webcam.
    # exclusive_caps=1 makes the kernel advertise V4L2_CAP_VIDEO_CAPTURE
    # on the device — without it, Chromium-based apps (incl. the Zoom
    # flatpak's CEF stack) skip the loopback entirely because it only
    # advertises V4L2_CAP_VIDEO_OUTPUT. video_nr=10 pins it at /dev/video10
    # so it never collides with the real USB cam at video0/1 across reboots.
    boot.extraModprobeConfig = ''
      options v4l2loopback devices=1 video_nr=10 card_label="OBS Cam" exclusive_caps=1
    '';

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
