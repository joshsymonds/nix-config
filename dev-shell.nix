{pkgs}:
pkgs.mkShellNoCC {
  name = "nix-config-dev";
  packages = with pkgs; [
    statix
    deadnix
    git
  ];
}
