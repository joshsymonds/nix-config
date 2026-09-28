{pkgs, ...}: {
  # GUI + CLI apps delivered via nixpkgs (appear in ~/Applications through activation helper)
  environment.systemPackages = with pkgs; [
    aerospace
    kitty
  ];

  homebrew = {
    enable = true;
    casks = [
      "1password"
      "1password-cli"
      "claude"
      "dbeaver-community"
      "discord"
      "docker"
      "firefox"
      "obsidian"
      "readdle-spark"
      "sf-symbols"
      "signal"
      "slack"
      "spotify"
      "todoist"
    ];
    brews = [
      "pyenv"
      "qemu"
      "pam-reattach"
      "xz"
    ];
  };
}
