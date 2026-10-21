{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hardware.gpu-nvidia;

  # patchelf leaves nvidia-smi's writable .dynamic on a page that the next,
  # read-only PT_LOAD remaps, so glibc 2.44's ld.so segfaults writing DT_DEBUG
  # (segfault at 401568, error 7, measured on 615.78.08 2026-10-21). Marking
  # every PT_LOAD that shares a page with PT_DYNAMIC writable lets that write
  # land; a binary without the overlap passes through unchanged.
  nvidia-smi-fixed =
    pkgs.runCommand "nvidia-smi-fixed-${config.hardware.nvidia.package.version}" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      install -Dm755 ${config.hardware.nvidia.package.bin}/bin/nvidia-smi $out/bin/nvidia-smi
      python3 - $out/bin/nvidia-smi <<'EOF'
      import struct, sys
      path = sys.argv[1]
      with open(path, "r+b") as f:
          data = bytearray(f.read())
          assert data[:4] == b"\x7fELF" and data[4] == 2 and data[5] == 1
          (phoff,) = struct.unpack_from("<Q", data, 0x20)
          phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
          phdrs = []
          for i in range(phnum):
              off = phoff + i * phentsize
              p_type, p_flags, _, vaddr, _, _, memsz, _ = struct.unpack_from("<IIQQQQQQ", data, off)
              phdrs.append((off, p_type, p_flags, vaddr & ~0xFFF, (vaddr + memsz + 0xFFF) & ~0xFFF))
          dyn = [p for p in phdrs if p[1] == 2]
          assert len(dyn) == 1
          d_lo, d_hi = dyn[0][3], dyn[0][4]
          for off, p_type, p_flags, lo, hi in phdrs:
              if p_type == 1 and lo < d_hi and d_lo < hi and not p_flags & 2:
                  struct.pack_into("<I", data, off + 4, p_flags | 2)
          f.seek(0)
          f.write(data)
      EOF
    '';
in {
  options.hardware.gpu-nvidia = {
    enable = lib.mkEnableOption "NVIDIA GPU (open driver, Blackwell-ready)";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "NVIDIA driver package. Defaults to nvidiaPackages.production from boot.kernelPackages.";
    };

    containerToolkit = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable nvidia-container-toolkit for Docker/Podman GPU passthrough.";
    };

    enable32Bit = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable 32-bit graphics support (Steam/Proton on gaming systems).";
    };

    cudaArches = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["8.9" "12.0"];
      description = ''
        Explicit CUDA compute capabilities to build CUDA packages for.

        Empty (default) means "don't set nixpkgs.config.cudaCapabilities"
        — each CUDA-supporting package uses its own upstream default,
        which is typically a broad multi-arch list covering Turing
        through Blackwell. This is the cache-friendly choice: the
        binaries match what cache.nixos-cuda.org pre-builds (which also
        uses broad targets), so onnxruntime / pytorch / ollama-cuda /
        etc. download from cache instead of rebuilding for ~45 min
        each.

        Set to a narrow list (e.g. ["12.0"] for Blackwell-only) only if
        you specifically want sm-targeted optimization — but
        understand it WILL invalidate every CUDA package's cache hash
        relative to the public CI builds, forcing local rebuilds.

        For typical workloads (CNN inference, ML training on a single
        consumer GPU) the broad-target build is functionally identical
        to a narrow-target one on the runtime hardware; the only delta
        is ~50-100 MB of unused PTX per package on disk.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.graphics = {
      enable = true;
      enable32Bit = cfg.enable32Bit;
      extraPackages = with pkgs; [
        libvdpau-va-gl
        libva-vdpau-driver
      ];
    };

    hardware.nvidia = {
      open = true;
      nvidiaSettings = true;
      powerManagement.enable = lib.mkDefault true;
      package =
        if cfg.package != null
        then cfg.package
        else config.boot.kernelPackages.nvidiaPackages.production;
      modesetting.enable = true;
    };

    # Shadows the driver's nvidia-smi in the system profile; the driver package
    # itself is untouched, so the kernel module and libraries keep their paths.
    environment.systemPackages = [(lib.hiPrio nvidia-smi-fixed)];

    hardware.nvidia-container-toolkit.enable = cfg.containerToolkit;

    # A driver bump swaps the userspace libs while the old kernel module stays
    # loaded until reboot, so running the CDI generator mid-switch fails with
    # NVML "Driver/library version mismatch" — and that failed unit makes
    # switch-to-configuration exit 4, which leaves nh's boot profile on the old
    # generation. Regenerate the spec on the next boot instead.
    systemd.services.nvidia-container-toolkit-cdi-generator = lib.mkIf cfg.containerToolkit {
      # Keep an active unit (and its /run/cdi spec, which still matches the
      # loaded module) across the switch.
      restartIfChanged = false;
      # An inactive unit still gets started, because the switch re-starts every
      # active target and multi-user.target wants it. Skip on a version mismatch
      # instead of failing: a failed ExecCondition leaves the unit inactive, not
      # failed, and doesn't fail docker's Requires=. A module that isn't loaded
      # yet falls through to the generator as before.
      serviceConfig.ExecCondition = pkgs.writeShellScript "nvidia-module-matches-driver" ''
        loaded=$(cat /sys/module/nvidia/version 2>/dev/null) || exit 0
        [ "$loaded" = "${config.hardware.nvidia.package.version}" ] && exit 0
        echo "nvidia module $loaded is loaded but the driver is ${config.hardware.nvidia.package.version}; skipping until reboot"
        exit 1
      '';
    };

    # Only pin cudaCapabilities when explicitly requested. Empty list
    # (the default) leaves the global config unset so each CUDA
    # package uses its own upstream default — matching what
    # cache.nixos-cuda.org pre-builds, so we get cache hits instead
    # of multi-hour local rebuilds for onnxruntime / pytorch / etc.
    nixpkgs.config.cudaCapabilities =
      lib.mkIf (cfg.cudaArches != [])
      cfg.cudaArches;

    services.xserver.videoDrivers = ["nvidia"];

    users.users.joshsymonds.extraGroups = ["video" "render"];
  };
}
