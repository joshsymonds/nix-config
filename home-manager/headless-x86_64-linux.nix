{pkgs, ...}: {
  imports = [
    ./common.nix
    ./devspaces-host
    ./security-tools
  ];

  home = {
    homeDirectory = "/home/joshsymonds";

    packages = with pkgs; [
      file
      unzip
      dmidecode
      gcc
    ];
  };

  programs.zsh.shellAliases.update = "nh os switch";

  systemd.user.startServices = "sd-switch";
}
