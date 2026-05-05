{
  config,
  pkgs,
  ...
}: {
  imports = [
    ./common.nix
    ./aerospace
    ./devspaces-client
    ./go
    ./ssh-hosts
    ./ssh-config
  ];

  home.homeDirectory = "/Users/joshsymonds";

  # Fonts managed by Nix
  home.packages = with pkgs; [
    maple-mono.NF-CN-unhinted
  ];

  programs.go.enable = true;
  # Explicit flake path — works from any cwd and bootstraps before NH_FLAKE
  # is exported by a home-manager activation.
  programs.zsh.shellAliases.update = "nh darwin switch ${config.home.homeDirectory}/nix-config";
  programs.kitty.font.size = 13;
}
