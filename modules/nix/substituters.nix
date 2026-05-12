# Single source of truth for substituters + trusted-public-keys
# on every NixOS host. Each cache is gated on a feature flag so
# the right hosts pull from the right caches automatically —
# headless servers don't trust signers for content they'll never
# consume; GPU hosts auto-pick up the CUDA cache; gaming hosts
# auto-pick up the proton-cachyos / cachyos-kernel caches.
#
# Why this lives in one file:
#   * Previously, substituters were scattered across defaults.nix
#     + hosts/<host>/default.nix. defaults.nix used `lib.mkDefault`,
#     which (per Nix module semantics) gets entirely REPLACED by a
#     non-default setter at the same option path. Result: gnomon's
#     explicit `extra-substituters = [...]` clobbered the universal
#     defaults, silently disabling nix-community + joshsymonds +
#     devenv cache hits across the whole closure.
#   * The fix is structural — declare every cache once, with the
#     feature flag that activates it, in one place. No mkDefault,
#     no per-host overrides.
#
# How to add a new cache:
#   1. Add { url, publicKey } to lib/caches.nix.
#   2. Add the url/key pair to extra-substituters/extra-trusted-
#      public-keys below, gated on the right feature flag.
{
  config,
  lib,
  ...
}: let
  caches = import ../../lib/caches.nix;

  # Feature flags driving which caches get added. Tied to actual
  # NixOS module options rather than hostnames so substituter
  # provisioning Just Works™ when a feature is enabled on a new
  # host, without remembering to also touch this file.
  hasGpuNvidia = config.hardware.gpu-nvidia.enable or false;
  hasSteam = config.programs.steam.enable or false;
in {
  nix.settings = {
    extra-substituters =
      # ─── Universal (every NixOS host) ──────────────────────
      [
        caches.nixCommunity.url
        caches.joshsymonds.url
        caches.devenv.url
        caches.niri.url
      ]
      # ─── GPU / ML (gated on hardware.gpu-nvidia.enable) ────
      # SomeoneSerge/nixpkgs-cuda-ci's cudaSupport=true builds.
      # Without this, onnxruntime/ollama-cuda/pytorch rebuild
      # from source — ~45 min for onnxruntime alone.
      ++ lib.optionals hasGpuNvidia [
        caches.cuda.url
      ]
      # ─── Gaming (gated on programs.steam.enable) ───────────
      # proton-cachyos prebuilts + CachyOS kernel binaries.
      # Without these, proton-cachyos rebuilds clang (~30 min)
      # and the CachyOS kernel rebuilds on every bump.
      ++ lib.optionals hasSteam [
        caches.tokidoki.url
        caches.lantian.url
        caches.garnix.url
      ];

    extra-trusted-public-keys =
      [
        caches.nixCommunity.publicKey
        caches.joshsymonds.publicKey
        caches.devenv.publicKey
        caches.niri.publicKey
      ]
      ++ lib.optionals hasGpuNvidia [
        caches.cuda.publicKey
      ]
      ++ lib.optionals hasSteam [
        caches.tokidoki.publicKey
        caches.lantian.publicKey
        caches.garnix.publicKey
      ];
  };
}
