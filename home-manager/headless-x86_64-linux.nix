{
  config,
  pkgs,
  ...
}: let
  # On a headless server I am, by definition, always reached via SSH. Apps that
  # respect $BROWSER (gh browse, bundle open, …) emit an OSC 8 hyperlink that
  # the client terminal can hand to its own xdg-open. Strictly SSH-only — no
  # local fallback, since recursing through xdg-open is what produced a
  # 23k-deep fork bomb when this leaked onto the desktop.
  remoteLinkOpenScript = pkgs.writeScriptBin "remote-link-open" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    if [ $# -eq 0 ]; then
      echo "Usage: remote-link-open <url>" >&2
      exit 1
    fi

    if [ -z "''${SSH_CLIENT:-}" ]; then
      echo "remote-link-open: refusing to run outside an SSH session" >&2
      exit 1
    fi

    URL="$1"
    printf '\033]8;;%s\033\\Click to open: %s\033]8;;\033\\\n' "$URL" "$URL"
    echo "Sent link to client terminal: $URL"
  '';
in {
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
      remoteLinkOpenScript
    ];

    sessionVariables = {
      BROWSER = "remote-link-open";
      DEFAULT_BROWSER = "remote-link-open";
    };
  };

  # Pass the flake path explicitly so `update` works from any directory and
  # before NH_FLAKE is in the active environment (bootstrap case after a fresh
  # install or before the first home-manager activation that exports it).
  programs.zsh.shellAliases.update = "nh os switch ${config.home.homeDirectory}/nix-config";

  systemd.user.startServices = "sd-switch";
}
