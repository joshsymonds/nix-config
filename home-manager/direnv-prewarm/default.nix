{
  config,
  lib,
  pkgs,
  ...
}: let
  nixConfigDir = "${config.home.homeDirectory}/nix-config";

  # `direnv exec` evaluates the directory's .envrc exactly as an
  # interactive cd would, so nix-direnv writes the same cache + GC root
  # under .direnv/. PATH needs the system profile for nix/git — the user
  # manager's default PATH covers it on NixOS, but be explicit so the
  # unit also works under a degraded environment.
  prewarmScript = pkgs.writeShellScript "direnv-prewarm" ''
    export PATH=/run/current-system/sw/bin:${lib.makeBinPath [pkgs.bash pkgs.coreutils pkgs.git]}:$PATH
    exec ${pkgs.direnv}/bin/direnv exec ${nixConfigDir} true
  '';
in {
  # Re-warm nix-direnv's isolated shell for ~/nix-config in the background
  # whenever its definition or nixpkgs pin changes. The shell deliberately
  # does not evaluate or archive the root flake's unrelated inputs.
  systemd.user.services.direnv-prewarm = {
    Unit = {
      Description = "Pre-warm nix-direnv cache for ~/nix-config";
      # Skip on machines where the repo isn't checked out or direnv
      # hasn't been allowed yet ('-' on ExecStart tolerates the latter).
      ConditionPathExists = "${nixConfigDir}/.envrc";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "-${prewarmScript}";
      # Saves to flake.nix retrigger this on every write; keep the
      # background evals out of the foreground's way.
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  systemd.user.paths.direnv-prewarm = {
    Unit.Description = "Watch ~/nix-config dev-shell files for direnv pre-warm";
    Path.PathChanged = [
      "${nixConfigDir}/.envrc"
      "${nixConfigDir}/dev-shell.nix"
      "${nixConfigDir}/flake.lock"
      "${nixConfigDir}/shell.nix"
    ];
    Install.WantedBy = ["default.target"];
  };
}
