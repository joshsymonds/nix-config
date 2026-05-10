{
  inputs,
  pkgs,
  ...
}: let
  spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.system};
in {
  # Spicetify wraps the nixpkgs Spotify in a script that runs
  # `spicetify backup apply` at *build* time, so the patched binary is a
  # nix-store path. When nixpkgs bumps Spotify (or any of the inputs
  # below change), the wrapper rebuilds and re-patches automatically —
  # the imperative "Spotify auto-updated and ate my theme" loop other
  # users hit doesn't apply on NixOS, because Spotify never auto-updates
  # in the first place.
  #
  # Provided by the spicetify-nix flake's homeManagerModule, imported below.
  imports = [inputs.spicetify-nix.homeManagerModules.spicetify];

  programs.spicetify = {
    enable = true;

    # Comfy (by NYRI4) — bundled in the official spicetify-themes repo.
    # Picked over the more popular dribbblish because comfy's defaults
    # already lean modern (rounded cards, generous spacing, multiple
    # bundled color schemes) and its CSS is structured around named
    # --spice-* variables, which makes future per-color tweaks one-line
    # changes instead of selector hunts.
    #
    # NOT chosen for transparency: vanilla Spotify's Electron BrowserWindow
    # has no `transparent: true` flag and Spicetify (a renderer-side
    # CSS/JS mod) cannot change that. Earlier we tried zeroing every
    # background-color via an `enabledSnippets` block — it revealed
    # Electron's opaque dark backgroundColor, not the wallpaper, so the
    # whole window looked black. Removed. True wallpaper-transparent
    # Spotify on Linux requires patching app.asar to add transparent:true
    # at BrowserWindow construction time; that's a separate, fragile
    # project (Spotify reshuffles its bundle ~quarterly).
    theme = spicePkgs.themes.comfy;

    # Default colorScheme is "comfy-dark". Other bundled options:
    # https://github.com/Comfy-Themes/Spicetify/tree/main/Themes/Comfy
    # (Mono, Maroon, etc.) — pick another by setting `colorScheme = "..."`.
  };
}
