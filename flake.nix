{
  description = "Josh Symonds' nix config";

  inputs = {
    # Nixpkgs - using unstable as primary
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11"; # Keep stable available if needed

    # Side-channel nixpkgs pinned to current unstable HEAD, used by the
    # inference-stack module (modules/services/inference-stack.nix) for
    # llama-cpp + llama-swap only. Decoupled from the main `nixpkgs`
    # input so the inference toolchain can ride the edge (new model
    # arches, MoE-offload flags, perf fixes land in llama.cpp on a
    # weekly cadence) without dragging a 200-package rebuild every time
    # the main lock bumps. Update independently via
    # `nix flake update nixpkgs-inference`.
    nixpkgs-inference.url = "github:nixos/nixpkgs/nixos-unstable";

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

    # Ephemeral root + selective persistence (paired with disko).
    # PINNED to the post-bindfs-migration HEAD (real systemd bind mounts).
    # Explicit rev so the input can't silently float and re-regress.
    impermanence.url = "github:nix-community/impermanence/7b1d382faf603b6d264f58627330f9faa5cba149";

    # Declarative Flatpak management. Adds `services.flatpak.packages` so the
    # system's Flatpak install set is reconciled on activation (install missing,
    # update existing, remove unmanaged). Used on gnomon for the Zoom Flatpak —
    # the official client's nixpkgs build can't keep up with portal/screencast
    # quirks, and the upstream Flatpak ships the FHS layout Zoom hard-codes.
    nix-flatpak = {
      url = "github:gmodena/nix-flatpak";
    };

    # Lanzaboote — Secure Boot for NixOS (signed UKI; PCR 7 binding for TPM-sealed LUKS)
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # DankMaterialShell — Quickshell-based desktop shell for niri (and others).
    # Provides notifications, launcher, lockscreen, polkit agent, idle, login greeter
    # as cohesive Quickshell modules, replacing the typical mako/fuzzel/swaylock stitchwork.
    # Tracks `josh/integration` on a personal fork: a long-lived,
    # *maintained* branch (durable --no-ff merges of the deployed patch
    # branches: chrome-shader, wider-pills, icon-cleanup,
    # notif-suppress-sound, … + persistent tooling commits). NOT
    # regenerated/force-pushed. Source lives at
    # ~/Personal/DankMaterialShell — see its CLAUDE.md / INTEGRATION.md
    # for the branch model. To bump after merging a new patch into
    # integration there (plain push): `nix flake update dms` here.
    dms = {
      url = "github:joshsymonds/DankMaterialShell/josh/integration";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # niri-flake — declaratively-typed niri config + module that supersedes nixpkgs'
    # programs/wayland/niri.nix (auto-disabled). DMS's home-manager niri module
    # integrates with this via its `includes` mechanism (config-file merging).
    #
    # We override niri-unstable to point at our fork at ~/Personal/niri (branch
    # josh/integration). dms-niri.nix consumes niri-unstable explicitly. niri-
    # flake's `make-niri` callPackage wraps this source, so all of its packaging
    # machinery (config validator, niri-session systemd unit, xwayland-satellite
    # integration) flows from one source of truth — critical for the validator
    # step, which would otherwise reject our new `cross-monitor-column-insert`
    # config key.
    niri-flake = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.niri-unstable.url = "github:joshsymonds/niri/josh/integration";
    };

    # niri-float-sticky — Go daemon that pins floating windows across
    # workspaces, used to make Zoom's screen-share popups (annotate
    # toolbar, sharing controls, participant mini-tile, leave/end
    # dialogs) follow the focused workspace including across monitor
    # switches. niri doesn't natively support sticky-across-workspaces;
    # this is the well-known third-party fill (probeldev/niri-float-
    # sticky; we fork to joshsymonds for safety against upstream churn).
    # Wired only into the Zoom .desktop wrapper in
    # home-manager/hosts/gnomon.nix — it spawns when Zoom launches and
    # the wrapper kills it on flatpak-run exit, so no idle resident.
    niri-float-sticky = {
      url = "github:joshsymonds/niri-float-sticky";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CC-Tools - Claude Code smart hooks
    cc-tools.url = "github:joshsymonds/cc-tools";

    # dms-claudecode — DMS plugin showing Claude Code subscription usage
    # (5h/7d rate windows, token burn, cost estimates) in the bar. Personal
    # fork of titeya/dms-claudecode; source lives in ~/Personal/dms-claudecode
    # with `upstream` remote pointing at titeya. `flake = false` because the
    # plugin is just a directory of QML + a shell script — no flake.nix.
    dms-claudecode = {
      url = "github:joshsymonds/dms-claudecode";
      flake = false;
    };

    # dms-bandwidth-pill — DMS plugin showing instantaneous network
    # throughput (RX/TX) from /proc/net/dev. Public repo; same
    # consume-as-source pattern as dms-claudecode (plugin.json + QML
    # at the repo root, DMS's plugin loader picks them up directly).
    # The repo's own flake.nix exposes a `packages.default` derivation
    # for non-NixOS-flake consumers; we don't need it here because the
    # source layout is already what DMS expects.
    dms-bandwidth-pill = {
      url = "github:joshsymonds/dms-bandwidth-pill";
      flake = false;
    };

    # dms-gpu-pill — DMS plugin showing NVIDIA GPU utilization + VRAM
    # via nvidia-smi. Same consume-as-source pattern as the bandwidth
    # pill above.
    dms-gpu-pill = {
      url = "github:joshsymonds/dms-gpu-pill";
      flake = false;
    };

    # dms-meeting-pill — DMS plugin showing the countdown to your next
    # upcoming calendar event (read via khal, which DMS already brings
    # in for enableCalendarEvents). Paired with morgen-fetch (pkgs/
    # morgen-fetch) the pipeline is: Morgen API → vdir → khal → pill.
    dms-meeting-pill = {
      url = "github:joshsymonds/dms-meeting-pill";
      flake = false;
    };

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

    # scriptorium — gnomon's local-LLM workspace (Modelfiles, eval scripts,
    # chat-template source). Private repo because personas/system prompts
    # *could* end up here, even though right now they live in Open-WebUI's
    # SQLite. Consumed as source (flake = false) — the ollama-modelfiles
    # module references ${inputs.scriptorium}/modelfiles/<name>.
    # Excluded from the nix registry in hosts/common.nix for the same
    # reason shimmer is: hosts without ssh credentials to this repo (the
    # installer VM test, fresh installs) would fail flake-fetch otherwise.
    scriptorium = {
      url = "git+ssh://git@github.com/joshsymonds/scriptorium.git";
      flake = false;
    };

    # Redlib fork for customizations
    redlib-fork = {
      url = "github:joshsymonds/redlib";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # halmasuit — the Linux system compositor that replaces greetd on
    # gnomon (Phase B from-initrd deployment; eliminates kernel-handoff,
    # greeter→session, and shutdown flashes). Consumed via
    # nixosModules.halmasuit + overlays.default; the gnomon-shaped
    # wiring lives in modules/desktop/halmasuit.nix.
    #
    # `path:` for now while the gnomon integration epic is in flight;
    # switch to `github:joshsymonds/halmasuit` once stable. halmasuit's
    # own flake declares dms + niri-flake as direct inputs (not via
    # nix-config), so consuming halmasuit here doesn't create a
    # flake-input cycle.
    halmasuit = {
      url = "path:/home/joshsymonds/Personal/halmasuit";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane.url = "github:ipetkov/crane";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Savecraft — game save parser + MCP server
    savecraft.url = "github:joshsymonds/savecraft.gg";

    # nix-gaming-edge — proton-cachyos (the SLR x86_64-v3 build). Replaces
    # proton-ge-bin on gnomon. Cache (tokidoki) is wired in on gnomon only —
    # the only host that consumes any of this.
    #
    # Used to also enable the mesa-git module, but mesa is bypassed entirely
    # on NVIDIA proprietary (all rendering goes through libGLX_nvidia /
    # nvidia_icd.json — mesa is only libgbm/libdrm dispatch on this stack)
    # and from-source rebuilds of every mesa-touching package weren't
    # earning measurable FPS. Reverted to nixpkgs stable mesa. The overlay
    # still ships proton-cachyos, which we do want.
    #
    # Tracking joshsymonds/nix-gaming-edge josh/fix-fhsenv-override until
    # the upstream FHS-env wrapper bug is merged: the upstream wrapFhsEnv
    # rewrites pkgs.buildFHSEnv as a plain function, dropping `.override`.
    # That breaks evaluation when programs.steam.gamescopeSession.enable
    # AND programs.gamescope.capSysNice are both true (steam.nix calls
    # pkgs.buildFHSEnv.override to swap in setuid bubblewrap). Source lives
    # at ~/Personal/nix-gaming-edge with `upstream` remote pointing at
    # powerofthe69; rebase + push when picking up new releases.
    #
    # NB: deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`. nix-gaming-
    # edge's tokidoki binary cache is built by their CI against THEIR pinned
    # nixpkgs; following ours would force a different output hash on every
    # flake-lock bump and miss the cache. Worth ~5s of extra eval time for
    # the cache hit on proton-cachyos.
    nix-gaming-edge.url = "github:joshsymonds/nix-gaming-edge/josh/fix-fhsenv-override";

    # nix-cachyos-kernel — CachyOS kernel for gnomon, completing the
    # gaming-edge stack alongside proton-cachyos + mesa-git. Provides
    # the BORE-EEVDF scheduler + cachy patchset + BBR3 on top of the
    # same mainline Linux source nixpkgs ships (no security delta —
    # same CVE coverage as linuxPackages_latest). Gain is tail-latency
    # in interactive workloads (game 1% lows, compositor latency,
    # compile throughput), not headline FPS.
    #
    # Wired in on gnomon ONLY — see hosts/gnomon/default.nix. The
    # nix-cachyos-kernel.legacyPackages API exposes the full
    # linuxPackages set per variant; we use linuxPackages-cachyos-
    # latest (generic march). v3/v4-suffixed variants exist but are
    # not on garnix.io's build matrix (only latest{,-lto} + lts{,-lto}
    # are), so any march suffix means a 25-30 min from-source rebuild
    # on every kernel bump for sub-1% kernel perf — see hosts/gnomon
    # default.nix for the full reasoning. -lto is on garnix but breaks
    # the out-of-tree it87 module without kernelModuleLLVMOverride.
    #
    # NB: deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`. The
    # upstream README warns ("there can be mismatch between patches and
    # kernel version") and their lantian Attic cache is built against
    # their pinned nixpkgs. Same reasoning as nix-gaming-edge above.
    #
    # Cache: lantian Attic (https://attic.xuyh0120.win/lantian) is
    # wired in on gnomon only via nix.settings. Garnix is a fallback
    # for builds the lantian Attic doesn't have yet.
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

    # Google Workspace CLI — official `gws` from Google
    googleworkspace-cli = {
      url = "github:googleworkspace/cli";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Claude Desktop (the chat app, not Claude Code) for Linux. The repo
    # name says "debian" for historical reasons — the flake itself is
    # standalone and pulls Anthropic's Windows installer at build time,
    # extracts the asar, applies a patch suite for Linux, and re-wraps
    # it. CI auto-bumps the URLs/SRI hashes on every upstream release,
    # so `nix flake update claude-desktop` is the bleeding-edge knob.
    #
    # Currently consumed via our fork (joshsymonds/claude-desktop-debian
    # branch joshsymonds/niri-quality-of-life), which adds two patches on
    # top of upstream main: orange-tray.sh (replaces macOS-template Tray
    # PNGs with the orange Claude launcher icon — Linux StatusNotifierItem
    # has no template-image concept, so the upstream monochrome silhouettes
    # render as black/white blobs in DMS's tray) and quick-window-size.sh
    # (shrinks the Quick Entry popup height from 420 → 80 to fit the input
    # bar, eliminating the alpha=0 dead area below it that niri wraps in
    # a focus-ring). When/if those land upstream, point this back at
    # aaddrick/claude-desktop-debian.
    claude-desktop = {
      url = "github:joshsymonds/claude-desktop-debian/joshsymonds/niri-quality-of-life";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # spicetify-nix — declarative Spotify customization via spicetify-cli.
    # Wraps the nixpkgs `spotify` derivation in a script that runs
    # `spicetify backup apply` on every nix-store rebuild, so the patched
    # Spotify is itself a nix-built package (path-pinned, GC-managed)
    # rather than an imperatively-modified copy of /home/.../Spotify.
    # When nixpkgs bumps spotify, the wrapper rebuilds and reapplies —
    # no manual `spicetify apply` step survives in the user's workflow.
    # Use `programs.spicetify` from the home-manager module; do NOT also
    # install pkgs.spotify, the wrapper provides it.
    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
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
      "https://niri.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "joshsymonds.cachix.org-1:DajO7Bjk/Q8eQVZQZC/AWOzdUst2TGp8fHS/B1pua2c="
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "niri.cachix.org-1:Wv0OmO7PsuocRKzfDoJ3mulSl7Z6oezYhGhR+3W2964="
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
          ({outputs, ...}: {
            nixpkgs.overlays = [
              outputs.overlays.gaming
              outputs.overlays.ml
              # halmasuit-replaces-greetd integration; the new
              # modules/desktop/halmasuit.nix on gnomon imports
              # services.halmasuit.* whose package defaults
              # resolve through this overlay.
              inputs.halmasuit.overlays.default
            ];
          })
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
        # Override flake-parts' default `pkgs` with an allowUnfree-enabled
        # instance so `nix flake check` doesn't refuse evaluating packages
        # that carry meta.license = unfree (claude-code-cli is one). The
        # mkNixos / mkHome paths set this themselves; perSystem doesn't
        # inherit it by default.
        _module.args.pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        packages =
          (import ./pkgs {inherit pkgs;})
          // lib.optionalAttrs (system == "x86_64-linux") {
            installerIso = self.nixosConfigurations.installer.config.system.build.isoImage;
            ultravioletInstallerIso = self.nixosConfigurations.ultraviolet-installer.config.system.build.isoImage;
            vermissianInstallerIso = self.nixosConfigurations.vermissian-installer.config.system.build.isoImage;

            # End-to-end installer VM test. Boots a qemu VM, runs install.sh,
            # asserts post-install state. Slow (minutes) — exposed as a
            # package, NOT a check, so `nix flake check` stays fast. Run
            # explicitly with `nix build .#installerTest -L`.
            installerTest = import ./tests/installer-test.nix {
              inherit pkgs inputs self;
              flakeSource = self.outPath;
            };
          };

        # checks: things that nix flake check (and CI) should validate.
        # Keep this fast — anything that needs to boot a VM goes in
        # packages above, not here. treefmt-nix's flakeModule adds
        # checks.formatting; we merge.
        checks = lib.optionalAttrs (system == "x86_64-linux") {
          installer-kit-fixture = import ./tests/installer-kit-fixture.nix {
            inherit pkgs;
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
