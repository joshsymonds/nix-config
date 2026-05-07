{
  description = "Josh Symonds' nix config";

  inputs = {
    # Nixpkgs - using unstable as primary
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11"; # Keep stable available if needed

    # Flake-parts - modular flake outputs
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    # treefmt-nix - declarative formatter (alejandra, shellcheck, etc.)
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Darwin
    darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Home manager
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hardware-specific optimizations
    hardware.url = "github:nixos/nixos-hardware/master";

    # Declarative disk partitioning (used by btrfs-impermanence module)
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Ephemeral root + selective persistence (paired with disko)
    impermanence.url = "github:nix-community/impermanence";

    # Lanzaboote — Secure Boot for NixOS (signed UKI; PCR 7 binding for TPM-sealed LUKS)
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # DankMaterialShell — Quickshell-based desktop shell for niri (and others).
    # Provides notifications, launcher, lockscreen, polkit agent, idle, login greeter
    # as cohesive Quickshell modules, replacing the typical mako/fuzzel/swaylock stitchwork.
    # Tracking master (edge) per user directive.
    dms = {
      url = "github:AvengeMedia/DankMaterialShell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # niri-flake — declaratively-typed niri config + module that supersedes nixpkgs'
    # programs/wayland/niri.nix (auto-disabled). DMS's home-manager niri module
    # integrates with this via its `includes` mechanism (config-file merging).
    niri-flake = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CC-Tools - Claude Code smart hooks
    cc-tools.url = "github:joshsymonds/cc-tools";

    # Gambit — Claude Code skills marketplace (consumed as a directory
    # source; deployed into both ~/.claude and ~/.claude-work).
    gambit.url = "github:joshsymonds/gambit";

    # sound-stage — karaoke downloader + delyric vocal separation worker.
    sound-stage = {
      url = "github:joshsymonds/sound-stage";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Target Process MCP - Target Process API integration
    targetprocess-mcp.url = "github:joshsymonds/targetprocess-mcp";

    # Shimmer - Unified MCP server (Reddit, Monarch Money, GitHub)
    shimmer.url = "git+ssh://git@github.com/joshsymonds/shimmer.git";

    # Redlib fork for customizations
    redlib-fork = {
      url = "github:joshsymonds/redlib";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane.url = "github:ipetkov/crane";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Savecraft — game save parser + MCP server
    savecraft.url = "github:joshsymonds/savecraft.gg";

    # Google Workspace CLI — official `gws` from Google
    googleworkspace-cli = {
      url = "github:googleworkspace/cli";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Devenv for development environments
    # No nixpkgs.follows — devenv 2.0 bundles a nix fork (cachix/nix) that
    # requires its own pinned nixpkgs to build correctly.
    devenv.url = "github:cachix/devenv";

    # Determinate Nix - consistent Nix with parallel eval, flake stability
    # No nixpkgs.follows — keeps FlakeHub Cache hits
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
  };

  # NB: nixConfig must be a literal attrset (no `let ... in`); Nix CLI parses it
  # before expression evaluation. Keep these strings in sync with lib/caches.nix.
  nixConfig = {
    extra-experimental-features = ["pipe-operators"];
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://joshsymonds.cachix.org"
      "https://cache.nixos-cuda.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "joshsymonds.cachix.org-1:DajO7Bjk/Q8eQVZQZC/AWOzdUst2TGp8fHS/B1pua2c="
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
    ];
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    darwin,
    home-manager,
    ...
  }: let
    inherit (nixpkgs) lib;

    mkSpecialArgs = _system: {
      inherit inputs;
      outputs = self.outputs;
    };

    mkHomeManagerModules = {
      hostname,
      system,
      module,
    }: [
      home-manager.nixosModules.home-manager
      {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "backup";
          users.joshsymonds = import module;
          extraSpecialArgs =
            mkSpecialArgs system
            // {
              inherit hostname;
            };
          sharedModules = [inputs.agenix.homeManagerModules.default];
        };
      }
    ];

    mkNixosHost = hostname: cfg:
      lib.nixosSystem {
        inherit (cfg) system;
        specialArgs = mkSpecialArgs cfg.system;
        modules =
          cfg.modules
          ++ lib.optionals (cfg ? homeModule)
          (mkHomeManagerModules {
            inherit hostname;
            inherit (cfg) system;
            module = cfg.homeModule;
          });
      };

    nixosHostDefinitions = {
      ultraviolet = {
        system = "x86_64-linux";
        modules = [
          ./hosts/ultraviolet
          ./hosts/common.nix
          inputs.agenix.nixosModules.default
          inputs.savecraft.nixosModules.pob-server
          ({outputs, ...}: {
            nixpkgs.overlays = [outputs.overlays.privatePackages];
          })
        ];
        homeModule = ./home-manager/hosts/ultraviolet.nix;
      };

      bluedesert = {
        system = "x86_64-linux";
        modules = [
          ./hosts/bluedesert
          ./hosts/common.nix
          inputs.agenix.nixosModules.default
        ];
        homeModule = ./home-manager/hosts/bluedesert.nix;
      };

      echelon = {
        system = "x86_64-linux";
        modules = [
          ./hosts/echelon
          ./hosts/common.nix
          inputs.agenix.nixosModules.default
        ];
        homeModule = ./home-manager/hosts/echelon.nix;
      };

      gnomon = {
        system = "x86_64-linux";
        modules = [
          ./hosts/gnomon
          ./hosts/common.nix
          inputs.agenix.nixosModules.default
        ];
        homeModule = ./home-manager/hosts/gnomon.nix;
      };

      vermissian = {
        system = "x86_64-linux";
        modules = [
          ./hosts/vermissian
          ./hosts/common.nix
          inputs.agenix.nixosModules.default
          inputs.savecraft.nixosModules.magic-data-refresh
        ];
        homeModule = ./home-manager/hosts/vermissian.nix;
      };

      # testhost — fixture for the installer VM test. Minimal consumer of
      # modules/disko/btrfs-impermanence.nix. Deliberately does NOT include
      # hosts/common.nix, agenix, or privatePackages — must work with no
      # GitHub credentials. See hosts/testhost/default.nix for details.
      testhost = {
        system = "x86_64-linux";
        modules = [
          ./hosts/testhost
        ];
      };

      # installer — the generic installer ISO. Built as a package (via
      # config.system.build.isoImage), not deployed as a host. Pairs with
      # a per-host kit on a partition labeled INSTALL-KIT on the same USB.
      # See modules/installer-iso/default.nix for the design.
      installer = {
        system = "x86_64-linux";
        modules = [
          ./modules/installer-iso
          # Production-only: allowUnfree is required for hardware.enableAllFirmware
          # (firmware blobs are unfree). Set here, NOT in installer-iso itself, so
          # the nixosTest can inherit the framework's read-only nixpkgs.config
          # without a merge conflict.
          {nixpkgs.config.allowUnfree = true;}
        ];
      };

      ultraviolet-installer = {
        system = "x86_64-linux";
        modules = [./hosts/ultraviolet/installer.nix];
      };

      vermissian-installer = {
        system = "x86_64-linux";
        modules = [./hosts/vermissian/installer.nix];
      };
    };

    mkHome = {
      system,
      module,
      hostname,
    }:
      home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            self.outputs.overlays.default
            self.outputs.overlays.darwin
          ];
          config.allowUnfree = true;
        };
        extraSpecialArgs = mkSpecialArgs system // {inherit hostname;};
        modules = [inputs.agenix.homeManagerModules.default module];
      };
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-darwin"];

      imports = [inputs.treefmt-nix.flakeModule];

      perSystem = {
        pkgs,
        system,
        ...
      }: {
        packages =
          (import ./pkgs {inherit pkgs;})
          // lib.optionalAttrs (system == "x86_64-linux") {
            installerIso = self.nixosConfigurations.installer.config.system.build.isoImage;
            ultravioletInstallerIso = self.nixosConfigurations.ultraviolet-installer.config.system.build.isoImage;
            vermissianInstallerIso = self.nixosConfigurations.vermissian-installer.config.system.build.isoImage;
          };

        # checks: things that nix flake check (and CI) should validate.
        # treefmt-nix's flakeModule already adds checks.formatting; we merge.
        checks = lib.optionalAttrs (system == "x86_64-linux") {
          installer-kit-fixture = import ./tests/installer-kit-fixture.nix {
            inherit pkgs;
            flakeSource = self.outPath;
          };
          installer = import ./tests/installer-test.nix {
            inherit pkgs inputs self;
            flakeSource = self.outPath;
          };
        };

        devShells.default = pkgs.mkShell {
          name = "nix-config-dev";
          packages = with pkgs; [
            statix
            deadnix
            git
            google-cloud-sdk
          ];
        };

        treefmt = {
          projectRootFile = "flake.nix";
          programs.alejandra.enable = true;
        };
      };

      flake = {
        overlays = import ./overlays {
          inherit inputs;
          outputs = self.outputs;
        };

        nixosConfigurations = lib.mapAttrs mkNixosHost nixosHostDefinitions;

        darwinConfigurations.ninuan = darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          specialArgs = mkSpecialArgs "aarch64-darwin";
          modules = [
            ./hosts/ninuan
            home-manager.darwinModules.home-manager
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                backupFileExtension = "backup";
                users.joshsymonds = import ./home-manager/aarch64-darwin.nix;
                extraSpecialArgs =
                  mkSpecialArgs "aarch64-darwin"
                  // {
                    hostname = "ninuan";
                  };
                sharedModules = [inputs.agenix.homeManagerModules.default];
              };
            }
          ];
        };

        homeConfigurations = let
          linuxHosts = builtins.attrNames (lib.filterAttrs (_: cfg: cfg ? homeModule) nixosHostDefinitions);
          darwinHosts = ["ninuan"];
        in
          (
            lib.genAttrs
            (map (h: "joshsymonds@${h}") linuxHosts)
            (h: let
              hostname = lib.removePrefix "joshsymonds@" h;
            in
              mkHome {
                system = "x86_64-linux";
                module = ./home-manager/hosts/${hostname}.nix;
                inherit hostname;
              })
          )
          // (
            lib.genAttrs
            (map (h: "joshsymonds@${h}") darwinHosts)
            (h: let
              hostname = lib.removePrefix "joshsymonds@" h;
            in
              mkHome {
                system = "aarch64-darwin";
                module = ./home-manager/hosts/${hostname}.nix;
                inherit hostname;
              })
          );
      };
    };
}
