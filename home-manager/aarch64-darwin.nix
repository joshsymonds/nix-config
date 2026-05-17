{
  config,
  pkgs,
  ...
}: let
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
    exec nh darwin switch ${config.home.homeDirectory}/nix-config "$@"
  '';
in {
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
    updateScript
    maple-mono.NF-CN-unhinted
  ];

  programs.go.enable = true;
}
