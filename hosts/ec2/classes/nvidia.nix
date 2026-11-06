{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [../../../modules/hardware/gpu-nvidia.nix];

  hardware.gpu-nvidia = {
    enable = true;
    containerToolkit = false;
    package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.new_feature;
  };

  hardware.nvidia = {
    nvidiaSettings = false;
    powerManagement.enable = false;
    nvidiaPersistenced = true;
  };

  environment.systemPackages = [pkgs.vulkan-tools];
}
