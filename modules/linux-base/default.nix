{
  config,
  lib,
  ...
}:
with lib; {
  options.linux-base = {
    systemdBoot.configurationLimit = mkOption {
      type = types.int;
      default = 8;
      description = "How many systemd-boot menu entries to keep.";
    };
  };

  config = {
    boot.loader = {
      systemd-boot = {
        enable = true;
        configurationLimit = config.linux-base.systemdBoot.configurationLimit;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };

    hardware.enableAllFirmware = mkDefault true;
  };
}
