# nixd settings for editing this flake, shared by every client that runs
# nixd against it (helix, Claude Code's nixd-lsp plugin).
#
# nixd evaluates the real per-host option sets and nixpkgs through the flake,
# lazily: the first query that needs them pays an eval (and ~1 GiB of worker
# RSS), then nixd caches. That eval is what lets go-to-definition land in
# nixpkgs source for pkgs.* and lib.*. The flake path must match NH_FLAKE
# (home-manager/common.nix).
{
  homeDirectory,
  hostname,
  isDarwin,
}: let
  flakeRef = ''builtins.getFlake "${homeDirectory}/nix-config"'';
in {
  nixpkgs.expr = "import (${flakeRef}).inputs.nixpkgs { }";
  options =
    {
      home-manager.expr = ''(${flakeRef}).homeConfigurations."joshsymonds@${hostname}".options'';
    }
    // (
      if isDarwin
      then {nix-darwin.expr = "(${flakeRef}).darwinConfigurations.${hostname}.options";}
      else {nixos.expr = "(${flakeRef}).nixosConfigurations.${hostname}.options";}
    );
}
