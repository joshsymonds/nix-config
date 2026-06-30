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

  # Our niri fork (niri-flake input override, branch josh/integration).
  # Under NixOS this is redundant — modules/desktop/dms-niri.nix pins the
  # same package and niri-flake's HM injection mkForces it through — but
  # the standalone homeConfigurations path otherwise falls back to
  # niri-stable, whose config validator rejects fork/unstable settings at
  # build time.
  programs.niri.package = inputs.niri-flake.packages.${pkgs.stdenv.hostPlatform.system}.niri-unstable;

  # Tell GTK we prefer dark colors. Electron on Linux derives
  # `nativeTheme.shouldUseDarkColors` from GtkSettings'
  # `gtk-application-prefer-dark-theme` property. Apps that ship light/dark
  # tray-icon variants (Claude Desktop's `TrayIconLinux.png` /
  # `TrayIconLinux-Dark.png`) pick the white-on-transparent "-Dark" one when
  # `shouldUseDarkColors` is true; setting this flag is what flips it, so the
  # tray icon stays legible against DMS's dark bar. Other GTK apps inherit the
  # preference too, which is the desired default — niri/DMS is a dark surface.
  #
  # gtk-enable-mnemonics=0 disables the Alt-as-menubar-accelerator and the
  # underline-letter visual that goes with it. The keyd layer already
  # neutralizes a *lone* Alt tap (overload(alt, noop) in modules/services/
  # keyd.nix), but two cases still trigger GTK's menubar focus:
  #   1. Alt+letter chords that niri intercepts (e.g. Alt+H at the leftmost
  #      column — niri runs focus-column-or-monitor-left, consumes the key,
  #      and the focused GTK app sees Alt depressed → Alt released with no
  #      intervening key event, which is GTK's exact trigger for menubar.
  #   2. Unbound Alt+letter chords that fall through to the app — GTK opens
  #      the menubar on Alt-release when no mnemonic matched.
  # Both are downstream of keyd; this setting is the one knob that covers
  # both. Tradeoff: Alt+<underlined letter> dialog mnemonics stop working —
  # acceptable since every Alt+letter we reach for is a niri WM bind.
  xdg.configFile."gtk-3.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=1
    gtk-enable-mnemonics=0
  '';
  xdg.configFile."gtk-4.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=1
    gtk-enable-mnemonics=0
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
