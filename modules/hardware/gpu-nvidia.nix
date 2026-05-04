{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hardware.gpu-nvidia;
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
      default = ["12.0"];
      example = ["8.9" "12.0"];
      description = "CUDA compute capabilities to build for. \"12.0\" = sm_120 (Blackwell, RTX 50 series).";
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

    hardware.nvidia-container-toolkit.enable = cfg.containerToolkit;

    nixpkgs.config.cudaCapabilities = cfg.cudaArches;

    services.xserver.videoDrivers = ["nvidia"];

    users.users.joshsymonds.extraGroups = ["video" "render"];
  };
}
