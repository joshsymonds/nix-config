{
  inputs,
  outputs,
  lib,
  ...
}: {
  nixpkgs = {
    overlays = [
      outputs.overlays.default
      outputs.overlays.darwin
      outputs.overlays.additions
      outputs.overlays.modifications
      outputs.overlays.unstable-packages
    ];
    config.allowUnfree = lib.mkDefault true;
  };

  nix = {
    optimise.automatic = lib.mkDefault true;
    settings = {
      experimental-features = lib.mkDefault "nix-command flakes pipe-operators";
      # Substituters + trusted-public-keys live in
      # modules/nix/substituters.nix (single source of truth, with
      # per-feature gating so the right hosts pull from the right
      # caches). Previously declared here with lib.mkDefault, which
      # was silently clobbered by hosts (gnomon, ninuan) that set
      # their own extra-substituters without mkDefault — losing the
      # universal cache.nixos-cuda.org / nix-community / joshsymonds
      # / devenv / niri hits across the closure.
      trusted-users = ["root" "joshsymonds"];
      accept-flake-config = true;

      # Keep build-time deps of live roots out of the daily GC's reach.
      # With gc --delete-older-than 3d and keep-outputs=false, every
      # post-GC rebuild re-downloaded toolchains and other build inputs.
      # Substitute-only hosts never fetch build deps, so this costs them
      # nothing.
      keep-outputs = true;

      # Determinate's default is 15s; one unreachable substituter (e.g.
      # ultraviolet's attic during a reboot) stalls every nix command
      # that long before falling through. Fail over faster.
      connect-timeout = 5;
    };
  };
}
