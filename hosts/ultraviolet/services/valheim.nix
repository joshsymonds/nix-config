{
  config,
  pkgs,
  ...
}: {
  imports = [../../../modules/services/valheim.nix];

  age.secrets."valheim-password" = {
    file = ../../../secrets/hosts/ultraviolet/valheim-password.age;
    owner = "valheim";
    group = "valheim";
    mode = "0400";
  };

  networking.firewall.allowedUDPPorts = [2456 2457];

  services.valheim = {
    enable = true;
    package = pkgs.valheim-server;
    passwordFile = config.age.secrets."valheim-password".path;
  };
}
