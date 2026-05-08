{
  config,
  inputs,
  pkgs,
  ...
}: {
  imports = [
    ./common.nix
    ./devspaces-client
    ./niri
    ./dms
    # DMS's niri HM module adds the niri-flake-typed bindings DMS needs;
    # imported once at the desktop layer so both ./niri and ./dms can
    # reference niri-flake settings without import-order tripping.
    inputs.dms.homeModules.dank-material-shell
    inputs.dms.homeModules.niri
  ];

  home = {
    homeDirectory = "/home/joshsymonds";

    packages = with pkgs; [
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
    ];
  };

  # `update` alias mirrors the headless base's pattern
  programs.zsh.shellAliases.update = "nh os switch ${config.home.homeDirectory}/nix-config";

  systemd.user.startServices = "sd-switch";
}
