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

  # `update` as a real binary on PATH, not a zsh shellAlias — so subagents
  # and other non-interactive shells can call it. Refuses if sudo would
  # prompt, since hanging on a password prompt is worse than failing fast.
  updateScript = pkgs.writeShellScriptBin "update" ''
    set -euo pipefail
    if ! sudo -n true 2>/dev/null; then
      echo "update: sudo would prompt for a password — cowardly refusing." >&2
      echo "update: run 'sudo -v' first, or configure NOPASSWD." >&2
      exit 1
    fi
    exec nh os switch ${config.home.homeDirectory}/nix-config "$@"
  '';
in {
  imports = [
    ./common.nix
    ./claudex
    ./devspaces-host
    ./direnv-prewarm
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
      updateScript
    ];

    sessionVariables = {
      BROWSER = "remote-link-open";
      DEFAULT_BROWSER = "remote-link-open";
    };
  };

  systemd.user.startServices = "sd-switch";
}
