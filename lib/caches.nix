{
  cuda = {
    url = "https://cache.nixos-cuda.org";
    publicKey = "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=";
  };
  nixCommunity = {
    url = "https://nix-community.cachix.org";
    publicKey = "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";
  };
  joshsymonds = {
    url = "https://joshsymonds.cachix.org";
    publicKey = "joshsymonds.cachix.org-1:DajO7Bjk/Q8eQVZQZC/AWOzdUst2TGp8fHS/B1pua2c=";
  };
  niri = {
    url = "https://niri.cachix.org";
    publicKey = "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964=";
  };
  # nix-gaming-edge upstream cache (proton-cachyos + mesa-git prebuilds).
  # Gnomon-only — wired into hosts/gnomon/default.nix nix.settings, NOT
  # added to modules/nix/defaults.nix so headless servers don't trust an
  # external signer they don't need.
  tokidoki = {
    url = "https://nix-cache.tokidoki.dev/tokidoki";
    publicKey = "tokidoki:MD4VWt3kK8Fmz3jkiGoNRJIW31/QAm7l1Dcgz2Xa4hk=";
  };
}
