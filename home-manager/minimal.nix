# Minimal configuration for resource-constrained bridge devices
# Only includes essentials for remote management and basic operations
{
  config,
  pkgs,
  ...
}: {
  imports = [
    ./git
    ./ssh-config # SSH configuration
    ./starship # Keep starship for nice prompt
    ./tmux # Keep tmux for persistent sessions
  ];

  home = {
    username = "joshsymonds";
    homeDirectory = "/home/joshsymonds";
    stateVersion = "25.05";

    packages = with pkgs; [
      # Absolute essentials only
      coreutils-full
      curl
      jq # For parsing JSON from APIs
      htop # Lightweight monitoring
      nano # Simple text editor (not vim/neovim)
      ncdu # Disk usage analyzer (useful given storage issues)
    ];

    sessionVariables = {
      EDITOR = "nano"; # Not nvim on this box
    };
  };

  programs = {
    # Minimal zsh config - light plugins only
    zsh = {
      enable = true;
      enableCompletion = true; # Keep completions, they're helpful
      autosuggestion.enable = false; # Save resources
      syntaxHighlighting.enable = false; # Save resources

      shellAliases = {
        ll = "ls -la";
        l = "ls -l";
        # Monitoring aliases for this box
        diskspace = "df -h / && du -sh /nix/store";
        zwave-logs = "sudo podman logs zwave-js-ui";
        ntfy-status = "systemctl status ntfy-sh";
      };
    };

    # Disable heavy services
    direnv = {
      enable = false;
    };
  };

  # https://github.com/nix-community/home-manager/issues/7935
  manual.manpages.enable = false;

  systemd.user.startServices = "sd-switch";
}
