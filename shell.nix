{
  system ? builtins.currentSystem,
  pkgs ? let
    lock = builtins.fromJSON (builtins.readFile ./flake.lock);
    nixpkgsNode = lock.nodes.${lock.nodes.root.inputs.nixpkgs};
    nixpkgsSource = builtins.fetchTree nixpkgsNode.locked;
  in
    import nixpkgsSource {
      inherit system;
      config.allowUnfree = true;
    },
  ...
}:
import ./dev-shell.nix {inherit pkgs;}
