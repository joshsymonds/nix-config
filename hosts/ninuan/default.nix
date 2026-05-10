let
  user = "joshsymonds";
in
  {
    inputs,
    lib,
    config,
    pkgs,
    ...
  }: {
    # You can import other NixOS modules here
    imports = [
      ../../modules/nix/defaults.nix
      ../../modules/darwin/applications.nix
      ../../modules/darwin/atticd-cache.nix
      ../../modules/darwin/defaults.nix
      ../../modules/darwin/software.nix
      inputs.agenix.darwinModules.default
      inputs.determinate.darwinModules.default
    ];

    age.secrets."atticd-push-token" = {
      file = ../../secrets/shared/atticd-push-token.age;
      owner = "root";
      group = "wheel";
      mode = "0400";
    };

    services.atticd-cache = {
      consumer.enable = true;
      publisher = {
        enable = true;
        tokenFile = config.age.secrets."atticd-push-token".path;
      };
    };

    determinateNix = {
      enable = true;
      customSettings = {
        trusted-users = ["root" user];
        extra-substituters = [
          "https://nix-community.cachix.org"
          "https://joshsymonds.cachix.org"
          "https://devenv.cachix.org"
        ];
        extra-trusted-public-keys = [
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "joshsymonds.cachix.org-1:DajO7Bjk/Q8eQVZQZC/AWOzdUst2TGp8fHS/B1pua2c="
          "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
        ];
        extra-experimental-features = ["pipe-operators"];
        accept-flake-config = true;
      };
    };

    # Determinate Nix manages the daemon, so nix.gc, nix.optimise, and
    # nix.settings are disabled. Use determinateNix.customSettings above.
    # nix.registry and nix.nixPath still work for CLI configuration.
    nix = {
      gc.automatic = false;
      optimise.automatic = false;

      # Configure the nix registry
      registry = {
        nixpkgs.flake = inputs.nixpkgs;
        devenv.flake = inputs.devenv;
      };

      # Configure the nixPath
      nixPath = [
        "nixpkgs=${inputs.nixpkgs}"
      ];
    };

    networking.hostName = "ninuan";

    # Time and internationalization
    time.timeZone = "America/Los_Angeles";

    # Users and their homes
    users.users.${user} = {
      shell = pkgs.zsh;
      home = "/Users/${user}";
    };

    # Security
    security.pam.services.sudo_local = {
      enable = true;
      text = ''
        auth       optional       ${pkgs.pam-reattach}/lib/pam/pam_reattach.so
        auth       sufficient     pam_tid.so
      '';
    };

    # Services
    programs.zsh.enable = true; # This is necessary to set zsh paths properly

    # Environment
    environment = {
      pathsToLink = [
        "/bin"
        "/share/locale"
        "/share/terminfo"
        "/share/zsh"
      ];
      variables = {
        EDITOR = "hx";
      };
    };

    # System setup
    system = {
      primaryUser = "joshsymonds";
      keyboard = {
        enableKeyMapping = true;
        remapCapsLockToEscape = true;
      };
      # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
      stateVersion = 4;
    };
  }
