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
  # Re-warm nix-direnv's cached devShell for ~/nix-config in the
  # background whenever the flake changes, so an interactive cd hits a
  # fresh cache and loads instantly instead of paying the eval + pull at
  # the prompt. Only a cd within seconds of the change (before the
  # prewarm finishes) still pays the normal reload.
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
    Unit.Description = "Watch ~/nix-config flake files for direnv pre-warm";
    Path.PathChanged = [
      "${nixConfigDir}/flake.nix"
      "${nixConfigDir}/flake.lock"
      "${nixConfigDir}/.envrc"
    ];
    Install.WantedBy = ["default.target"];
  };
}
