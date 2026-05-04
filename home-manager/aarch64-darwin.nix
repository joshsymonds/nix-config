{pkgs, ...}: {
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
  programs.zsh.shellAliases.update = "nh darwin switch";
  programs.kitty.font.size = 13;
}
