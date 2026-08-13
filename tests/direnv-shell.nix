{pkgs}: let
  inherit (pkgs) lib;
  standaloneShell = import ../shell.nix {system = pkgs.stdenv.hostPlatform.system;};
  sharedShell = import ../dev-shell.nix {inherit pkgs;};
  envrc = builtins.readFile ../.envrc;
  prewarmModule = builtins.readFile ../home-manager/direnv-prewarm/default.nix;
  shellExpression = builtins.readFile ../shell.nix;
in
  assert standaloneShell.drvPath == sharedShell.drvPath;
  assert standaloneShell.nativeBuildInputs == [pkgs.statix pkgs.deadnix pkgs.git];
  assert lib.hasInfix "watch_file flake.lock dev-shell.nix" envrc;
  assert lib.hasInfix "\nuse nix\n" envrc;
  assert !(lib.hasInfix "\nuse flake" envrc);
  assert lib.hasInfix "lock.nodes.root.inputs.nixpkgs" shellExpression;
  assert lib.hasInfix "builtins.fetchTree nixpkgsNode.locked" shellExpression;
  assert !(lib.hasInfix "savecraft" shellExpression);
  assert lib.all (path: lib.hasInfix path prewarmModule) ["/.envrc" "/dev-shell.nix" "/flake.lock" "/shell.nix"];
  assert !(lib.hasInfix "/flake.nix" prewarmModule);
    pkgs.runCommand "direnv-shell-check" {} ''
      touch "$out"
    ''
