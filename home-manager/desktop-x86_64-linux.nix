{
  config,
  inputs,
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
    exec nh os switch ${config.home.homeDirectory}/nix-config "$@"
  '';
in {
  imports = [
    ./common.nix
    ./devspaces-client
    ./firefox
    ./niri
    ./dms
    # DMS's niri HM module adds the niri-flake-typed bindings DMS needs;
    # imported once at the desktop layer so both ./niri and ./dms can
    # reference niri-flake settings without import-order tripping.
    inputs.dms.homeModules.dank-material-shell
    inputs.dms.homeModules.niri
  ];

  # Tell GTK we prefer dark colors. Electron on Linux derives
  # `nativeTheme.shouldUseDarkColors` from GtkSettings'
  # `gtk-application-prefer-dark-theme` property — there is no equivalent
  # "template image" path on Linux, so apps that ship macOS-style monochrome
  # tray icons (Claude Desktop's `TrayIconTemplate*.png`) only render
  # legibly when they pick the "-Dark" white-on-transparent variant.
  # aaddrick's claude-desktop-debian build already swaps to that variant
  # when `shouldUseDarkColors` is true; setting this flag is what flips it.
  # Other GTK apps inherit the preference too, which is the desired
  # default — niri/DMS is a dark surface.
  xdg.configFile."gtk-3.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=1
  '';
  xdg.configFile."gtk-4.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=1
  '';

  home = {
    homeDirectory = "/home/joshsymonds";

    packages = with pkgs; [
      updateScript

      firefox
      file
      unzip
      gcc

      # Terminal/editor font — kitty asks for "Maple Mono NF CN" and the
      # Nerd Font glyphs (icons, powerline separators in tmux/starship,
      # devicons in helix) live in the NF-CN variant. Without this, kitty
      # silently falls back to a sans-serif and Nerd Font codepoints
      # render as boxes. Same package the macOS config installs.
      maple-mono.NF-CN-unhinted

      # Screenshot annotation. Niri's built-in screenshot UI (Print) handles
      # capture-to-disk + clipboard; satty layers on top via Shift+Print for
      # the grim → slurp → satty pipeline (region pick → draw → copy/save).
      # grim/slurp/wl-clipboard are installed system-side in modules/desktop/niri.nix.
      satty

      libreoffice-fresh
    ];
  };

  systemd.user.startServices = "sd-switch";
}
