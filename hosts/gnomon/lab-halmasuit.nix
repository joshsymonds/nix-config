# Halmasuit lab images for gnomon: two experiments that boot halmasuit as the
# display manager in place of the greetd greeter. flake.nix's labSystems.gnomon
# builds each one on the same lab host as halmasuit's own labExperiments.
#
# `baseKernelParams` is the kernel command line of the plain lab image. Its
# definitions come from gnomon's default host and the lab module (`panic=10`),
# so the list is taken whole, `fbcon=nodefer` is dropped and `quiet` is added.
{
  inputs,
  lib,
  baseKernelParams,
}: let
  common = {
    imports = [../../modules/desktop/halmasuit.nix];

    desktop.halmasuit.enable = true;
    desktop.dms-niri.greeter.enable = lib.mkForce false;

    halmasuit.lab = {
      enable = true;
      displayManagerUnit = "halmasuit.service";
    };

    # nvidia-drm.fbdev is 0 in the lab images; nixpkgs sets it to 1 under modesetting.
    hardware.nvidia.moduleParams.nvidia-drm.fbdev = lib.mkForce 0;

    # No firmware framebuffer driver binds, so fbcon has nothing to take
    # over before halmasuit's first modeset: the firmware logo stays up.
    boot.kernelParams = lib.mkForce (
      lib.remove "fbcon=nodefer" baseKernelParams
      ++ ["quiet" "initcall_blacklist=simpledrm_platform_driver_init,efifb_driver_init"]
    );
  };
in {
  halmasuit = {
    imports = [common];
    services.halmasuit.package = inputs.halmasuit.packages.x86_64-linux.halmasuit-debug;
  };

  halmasuit-production = {
    imports = [common];
    services.halmasuit.package = inputs.halmasuit.packages.x86_64-linux.halmasuit;
  };
}
