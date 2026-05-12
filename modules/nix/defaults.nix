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
    };
  };
}
