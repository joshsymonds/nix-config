{lib, ...}: {
  imports = [./hardening.nix];

  boot.loader = {
    systemd-boot = {
      enable = true;
      configurationLimit = 8;
    };
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot";
    };
  };

  hardware.enableAllFirmware = lib.mkDefault true;
}
