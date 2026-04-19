{
  pkgs,
  ...
}: {
  imports = [
    ./common.nix
    ./devspaces-host
    ./security-tools
    ./gmailctl
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

  programs.zsh.shellAliases.update = "sudo nixos-rebuild switch --flake \".#$(hostname)\" --option warn-dirty false";

  systemd.user.startServices = "sd-switch";
}
