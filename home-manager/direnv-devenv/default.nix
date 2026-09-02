{pkgs, ...}: let
  # devenv ships its `use devenv` direnv library only as `devenv direnvrc`
  # output; nothing installs it, so `.envrc` files that say `use devenv`
  # fail with `use_devenv: command not found`.
  #
  # Why the renames: devenv's library is adapted from nix-direnv and defines
  # the same three helpers nix-direnv's own library does. direnv sources
  # ~/.config/direnv/lib/*.sh alphabetically, so whichever file loads last
  # silently replaces the other's helpers — nix-direnv's preflight never sets
  # DEVENV_BIN, which leaves `use devenv` running an empty command. Keeping
  # nix-direnv authoritative for `use flake` / `use nix` and giving devenv's
  # helpers their own names makes the two libraries coexist in either order.
  devenvDirenvLib =
    pkgs.runCommand "devenv-direnv-lib" {
      nativeBuildInputs = [pkgs.devenv pkgs.gnused];
    } ''
      devenv direnvrc \
        | sed \
          -e 's/\b_nix_direnv_preflight\b/_devenv_direnv_preflight/g' \
          -e 's/\b_nix_export_or_unset\b/_devenv_export_or_unset/g' \
          -e 's/\b_nix_import_env\b/_devenv_import_env/g' \
        > "$out"
      grep -q '^use_devenv()' "$out"
    '';
in {
  xdg.configFile."direnv/lib/devenv.sh" = {
    source = devenvDirenvLib;
    # The same path was hand-installed before this module existed; let the
    # first activation take it over instead of refusing to clobber it.
    force = true;
  };
}
