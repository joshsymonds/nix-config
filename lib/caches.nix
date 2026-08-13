# Substituter / binary-cache definitions. Consumed by
# modules/nix/substituters.nix (the single source of truth for
# which substituters every NixOS host trusts and pulls from).
#
# Naming: lowerCamelCase keys; each entry has { url, publicKey }.
# Keep this file pure data — no logic, no per-host gating. Gating
# happens in substituters.nix using config-driven feature flags.
{
  # ─── Universal caches (every host benefits) ────────────────────────
  nixCommunity = {
    url = "https://nix-community.cachix.org";
    publicKey = "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";
  };
  joshsymonds = {
    url = "https://joshsymonds.cachix.org";
    publicKey = "joshsymonds.cachix.org-1:DajO7Bjk/Q8eQVZQZC/AWOzdUst2TGp8fHS/B1pua2c=";
  };
  devenv = {
    url = "https://devenv.cachix.org";
    publicKey = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
  };
  niri = {
    url = "https://niri.cachix.org";
    publicKey = "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964=";
  };

  # ─── GPU / ML caches (gated on hardware.gpu-nvidia.enable) ─────────
  #
  # SomeoneSerge/nixpkgs-cuda-ci builds nixpkgs packages with
  # cudaSupport=true and pushes them here. Without this, every CUDA-
  # enabled package (onnxruntime, ollama-cuda, pytorch, etc.) builds
  # from source locally — ~45 min for onnxruntime alone.
  #
  # Cache moved from cuda-maintainers.cachix.org to cache.nixos-cuda.org
  # in Nov 2025; the older URL still resolves via redirect but the
  # canonical one is below.
  cuda = {
    url = "https://cache.nixos-cuda.org";
    publicKey = "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=";
  };

  # ─── Gaming caches (gated on programs.steam.enable) ────────────────
  #
  # tokidoki: proton-cachyos prebuilts (~30 min of clang otherwise).
  # Wired by nix-gaming-edge as the proton-cachyos overlay's home.
  tokidoki = {
    url = "https://nix-cache.tokidoki.dev/tokidoki";
    publicKey = "tokidoki:MD4VWt3kK8Fmz3jkiGoNRJIW31/QAm7l1Dcgz2Xa4hk=";
  };
  # lantian: xddxdd/nix-cachyos-kernel kernel binaries. Without it the
  # CachyOS kernel rebuilds from source on every bump.
  lantian = {
    url = "https://attic.xuyh0120.win/lantian";
    publicKey = "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=";
  };
}
