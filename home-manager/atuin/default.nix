{pkgs, ...}: {
  programs.atuin = {
    enable = true;
    package = pkgs.atuin;

    # Disabled: init script is pre-rendered at build time and sourced from
    # home-manager/zsh/default.nix. See preRender helper there.
    enableZshIntegration = false;
    daemon.enable = true;
  };
}
