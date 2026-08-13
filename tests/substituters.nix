{pkgs}: let
  inherit (pkgs) lib;
  caches = import ../lib/caches.nix;

  evalSettings = {
    hasGpu,
    hasSteam,
  }:
    (lib.evalModules {
      modules = [
        {
          options = {
            hardware.gpu-nvidia.enable = lib.mkEnableOption "NVIDIA GPU test fixture";
            programs.steam.enable = lib.mkEnableOption "Steam test fixture";
            nix.settings.extra-substituters = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
            };
            nix.settings.extra-trusted-public-keys = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
            };
          };
          config = {
            hardware.gpu-nvidia.enable = hasGpu;
            programs.steam.enable = hasSteam;
          };
        }
        ../modules/nix/substituters.nix
      ];
    }).config.nix.settings;

  universal = evalSettings {
    hasGpu = false;
    hasSteam = false;
  };
  gpu = evalSettings {
    hasGpu = true;
    hasSteam = false;
  };
  gaming = evalSettings {
    hasGpu = false;
    hasSteam = true;
  };

  universalUrls = [
    caches.nixCommunity.url
    caches.joshsymonds.url
    caches.devenv.url
    caches.niri.url
  ];
  universalKeys = [
    caches.nixCommunity.publicKey
    caches.joshsymonds.publicKey
    caches.devenv.publicKey
    caches.niri.publicKey
  ];
  allConfiguredValues =
    gaming.extra-substituters
    ++ gaming.extra-trusted-public-keys
    ++ gpu.extra-substituters
    ++ gpu.extra-trusted-public-keys;
in
  assert !(caches ? garnix);
  assert universal.extra-substituters == universalUrls;
  assert universal.extra-trusted-public-keys == universalKeys;
  assert gpu.extra-substituters == universalUrls ++ [caches.cuda.url];
  assert gpu.extra-trusted-public-keys == universalKeys ++ [caches.cuda.publicKey];
  assert gaming.extra-substituters == universalUrls ++ [caches.tokidoki.url caches.lantian.url];
  assert gaming.extra-trusted-public-keys == universalKeys ++ [caches.tokidoki.publicKey caches.lantian.publicKey];
  assert lib.all (value: !(lib.hasInfix "garnix" value)) allConfiguredValues;
    pkgs.runCommand "substituters-check" {} ''
      touch "$out"
    ''
