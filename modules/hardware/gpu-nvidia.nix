{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.hardware.gpu-nvidia;
in {
  options.hardware.gpu-nvidia = {
    enable = mkEnableOption "NVIDIA GPU (open driver, Blackwell-ready)";

    package = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "NVIDIA driver package. Defaults to nvidiaPackages.production from boot.kernelPackages.";
    };

    containerToolkit = mkOption {
      type = types.bool;
      default = true;
      description = "Enable nvidia-container-toolkit for Docker/Podman GPU passthrough.";
    };

    enable32Bit = mkOption {
      type = types.bool;
      default = false;
      description = "Enable 32-bit graphics support (Steam/Proton on gaming systems).";
    };
  };

  config = mkIf cfg.enable {
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

    services.xserver.videoDrivers = ["nvidia"];

    users.users.joshsymonds.extraGroups = ["video" "render"];
  };
}
