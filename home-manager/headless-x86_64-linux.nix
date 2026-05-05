{
  config,
  pkgs,
  ...
}: {
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

  # Pass the flake path explicitly so `update` works from any directory and
  # before NH_FLAKE is in the active environment (bootstrap case after a fresh
  # install or before the first home-manager activation that exports it).
  programs.zsh.shellAliases.update = "nh os switch ${config.home.homeDirectory}/nix-config";

  systemd.user.startServices = "sd-switch";
}
