{
  description = "Josh Symonds' nix config";

  inputs = {
    # Nixpkgs - using unstable as primary
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Side-channel nixpkgs pinned to current unstable HEAD, used by the
    # inference-stack module (modules/services/inference-stack.nix) for
    # llama-cpp + llama-swap only. Decoupled from the main `nixpkgs`
    # input so the inference toolchain can ride the edge (new model
    # arches, MoE-offload flags, perf fixes land in llama.cpp on a
    # weekly cadence) without dragging a 200-package rebuild every time
    # the main lock bumps. Update independently via
    # `nix flake update nixpkgs-inference`.
    nixpkgs-inference.url = "github:nixos/nixpkgs/nixos-unstable";

    # Open WebUI moves quickly and chat transport fixes often land between
    # nixos-unstable staging cycles. Keep it on a narrow master side channel
    # so updating the UI does not pull the rest of the system forward.
    nixpkgs-open-webui.url = "github:nixos/nixpkgs/master";

    # Official Codex plugin sources. Consumed as a plain source tree so
    # individual skills can be installed declaratively without mutable
    # `codex plugin add` state.
    openai-plugins = {
      url = "github:openai/plugins/bd2122cb92f2ade874d8c2b1d00383976ab9415b";
      flake = false;
    };

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

    # Nix-on-Droid — Nix + home-manager userland on Android (shrike, the
    # Pixel 11). Not NixOS-on-a-phone: it owns the terminal environment
    # inside the com.termux.nix app sandbox; Android apps stay imperative,
    # reconciled against hosts/shrike/apps.nix by shrike's `update`.
    #
    # NB: deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`. Their
    # pinned nixpkgs (2024-02) carries the nix 2.18 lineage, which is the
    # only nix that builds derivations under proot on Android: 2.18 opens
    # the pty slave in the forked child, while the modern refactor opens
    # it in the parent and dies with "getting pseudoterminal attributes:
    # Permission denied" during activation (user-environment build).
    # shrike's nix.package points at their pin; the rest of shrike's
    # closure still comes from our nixpkgs.
    nix-on-droid = {
      url = "github:nix-community/nix-on-droid";
      # Their own flake.lock's nixpkgs rev, pinned explicitly — a bare
      # re-lock would resolve their `nixpkgs-unstable` ref to today's
      # HEAD and hand us modern nix again.
      inputs.nixpkgs.url = "github:nixos/nixpkgs/5d874ac46894c896119bce68e758e9e80bdb28f1";
      inputs.home-manager.follows = "home-manager";
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
      url = "github:nix-community/lanzaboote/v1.1.0";
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
    cc-tools = {
      url = "github:joshsymonds/cc-tools";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
    # source; deployed into ~/.claude).
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
    # GitHub-tracked (not `path:`): a path: input hashes the entire
    # directory tree including target/ (~4 GiB), .cargo-home, and
    # .worktrees, so any local `cargo build` or `just check` mutates
    # the NAR hash and forces every downstream derivation to rebuild.
    # github: pins by commit, immune to working-tree noise. halmasuit's
    # own flake declares dms + niri-flake as direct inputs (not via
    # nix-config), so consuming halmasuit here doesn't create a
    # flake-input cycle.
    halmasuit = {
      url = "github:joshsymonds/halmasuit/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane.url = "github:ipetkov/crane";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Savecraft — public client daemon + private commercial services
    savecraft-client.url = "github:joshsymonds/savecraft-client";
    savecraft.url = "git+ssh://git@github.com/joshsymonds/savecraft.git";
    savecraft-egress = {
      url = "git+ssh://git@github.com/joshsymonds/savecraft-egress.git?ref=master&rev=27d5c9c4c07879f8daa670291bd23fb0e72a9bc4";
      flake = false;
    };

    # Patchbay — per-host Anthropic Messages API gateway (Claude Code → per-project models)
    patchbay = {
      url = "git+ssh://git@github.com/joshsymonds/patchbay.git?ref=main&rev=d82a65e450d760443e20681b432e71f9ebad7ede";
      flake = false;
    };

    # Mentat — personal assistant daemon (Claude as the brain)
    mentat = {
      url = "github:joshsymonds/mentat";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
    # Back on `github:powerofthe69/nix-gaming-edge` directly: upstream fixed
    # the bad proton-cachyos 11.0-20260602 hashes (verified 2026-07-03), so
    # the joshsymonds/nix-gaming-edge josh/fix-fhsenv-override fork (which
    # only existed to carry that hash correction) is retired.
    #
    # NB: deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`. nix-gaming-
    # edge's tokidoki binary cache is built by their CI against THEIR pinned
    # nixpkgs; following ours would force a different output hash on every
    # flake-lock bump and miss the cache. Worth ~5s of extra eval time for
    # the cache hit on proton-cachyos.
    nix-gaming-edge.url = "github:powerofthe69/nix-gaming-edge";

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
    # latest (generic march). v3/v4-suffixed variants exist but are not
    # covered by the retained binary caches, so any march suffix means a
    # 25-30 min from-source rebuild on every kernel bump for sub-1% kernel
    # perf — see hosts/gnomon/default.nix for the full reasoning. -lto also
    # breaks the out-of-tree it87 module without kernelModuleLLVMOverride.
    #
    # NB: deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`. The
    # upstream README warns ("there can be mismatch between patches and
    # kernel version") and their lantian Attic cache is built against
    # their pinned nixpkgs. Same reasoning as nix-gaming-edge above.
    #
    # Cache: lantian Attic (https://attic.xuyh0120.win/lantian) is wired in
    # on gnomon only via nix.settings.
    nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

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
          inputs.savecraft.nixosModules.knowledge-drain
          inputs.mentat.nixosModules.default
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

      # stygianlibrary — halmasuit test rig on a Thunderbolt-attached
      # WD_BLACK SN7100 in an ACASIS TBU405AIR enclosure. Hardware-
      # identical to gnomon (9800X3D + 5070 Ti + X870) so that
      # NVIDIA Wayland-EGL behavior reproduces faithfully. Boots on
      # husband's PC; we SSH in over tailscale to iterate on
      # halmasuit without disrupting gnomon as a daily driver.
      # Same halmasuit overlay as gnomon — module.nix on
      # stygianlibrary resolves halmasuit packages through this
      # overlay just as gnomon does.
      stygianlibrary = {
        system = "x86_64-linux";
        modules = [
          ./hosts/stygianlibrary
          ./hosts/common.nix
          inputs.agenix.nixosModules.default
          ({outputs, ...}: {
            nixpkgs.overlays = [
              outputs.overlays.gaming
              inputs.halmasuit.overlays.default
            ];
          })
        ];
        homeModule = ./home-manager/hosts/stygianlibrary.nix;
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
        # niri-flake's HM config module (programs.niri.settings +
        # config.lib.niri.actions, which DMS's HM module dereferences).
        # On NixOS hosts, niri-flake's nixosModule injects this into
        # home-manager.sharedModules for every user; these standalone
        # configs have to import it themselves for parity. Linux only,
        # matching the injection's reach — and inert on hosts that never
        # set programs.niri.settings. NOT in the desktop home layer:
        # that file is shared with the NixOS path, where a second
        # (differently-keyed) import collides with the injected one.
        modules =
          [inputs.agenix.homeManagerModules.default]
          ++ lib.optionals (system == "x86_64-linux") [inputs.niri-flake.homeModules.config]
          ++ [module];
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
          (import ./pkgs {inherit pkgs inputs;})
          // {
            # Regenerates the committed Shader Editor artifact:
            #   nix build .#chrome-hexrain-shadereditor
            #   cp -L result hosts/shrike/chrome-hexrain-shadereditor.glsl
            # The committed copy exists so the phone can grab it via
            # GitHub's copy-raw button; checks.chrome-hexrain-sync
            # fails when it drifts from the generators.
            chrome-hexrain-shadereditor =
              (import ./modules/desktop/chrome-hexrain {inherit (pkgs) lib;}).androidSource pkgs;
            savecraft-egress = pkgs.callPackage ./pkgs/savecraft-egress {
              src = inputs.savecraft-egress;
            };
            patchbay = pkgs.callPackage ./pkgs/patchbay {
              src = inputs.patchbay;
            };
          }
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
        checks = lib.optionalAttrs (system == "x86_64-linux") (let
          checkPkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [self.outputs.overlays.default];
          };
        in {
          codex-agent-roster = import ./tests/codex-agent-roster.nix {
            pkgs = checkPkgs;
          };
          codex-multi-agent-config = import ./tests/codex-multi-agent-config.nix {
            pkgs = checkPkgs;
            codexConfig = import ./home-manager/codex/managed-config.nix {
              pkgs = checkPkgs;
              lib = checkPkgs.lib;
              gambitHasCodex = true;
            };
          };
          chatgpt-desktop = import ./tests/chatgpt-desktop.nix {
            pkgs = checkPkgs;
            chatgptDesktop = checkPkgs.chatgpt-desktop;
            chatgptDesktopUnwrapped = checkPkgs.chatgpt-desktop-unwrapped;
          };
          direnv-shell = import ./tests/direnv-shell.nix {inherit pkgs;};
          gambit-rung-agents = import ./tests/gambit-rung-agents.nix {
            pkgs = checkPkgs;
          };
          installer-kit-fixture = import ./tests/installer-kit-fixture.nix {
            inherit pkgs;
            flakeSource = self.outPath;
          };
          substituters = import ./tests/substituters.nix {inherit pkgs;};
          # The committed Shader Editor artifact must match what the
          # generators produce — see packages.chrome-hexrain-shadereditor.
          chrome-hexrain-sync = let
            generated = (import ./modules/desktop/chrome-hexrain {inherit (checkPkgs) lib;}).androidSource checkPkgs;
          in
            checkPkgs.runCommand "chrome-hexrain-sync" {} ''
              if ! diff -u ${./hosts/shrike/chrome-hexrain-shadereditor.glsl} ${generated}; then
                echo "hosts/shrike/chrome-hexrain-shadereditor.glsl is stale." >&2
                echo "Regenerate: nix build .#chrome-hexrain-shadereditor && cp -L result hosts/shrike/chrome-hexrain-shadereditor.glsl" >&2
                exit 1
              fi
              touch $out
            '';
        });

        # mkShellNoCC + a tiny package set keeps the direnv shell closure
        # small, so a flake.lock bump re-pulls megabytes, not gigabytes.
        # google-cloud-sdk used to live here (~700MB closure, re-fetched on
        # every lock bump); the host that actually uses gcloud (vermissian)
        # installs it system-wide in hosts/vermissian/default.nix.
        devShells.default = import ./dev-shell.nix {inherit pkgs;};

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

        # One-command bootstrap seeding for shrike, run BEFORE the first
        # switch (phone-typeable, needs neither git nor a clone — github:
        # refs use the tarball fetcher):
        #   nix run --extra-experimental-features 'nix-command flakes' github:joshsymonds/nix-config#seed
        # Writes the ultraviolet hosts entry, the attic substituter, and
        # flakes-by-default into the pre-switch environment, so the first
        # switch substitutes from the household cache instead of building
        # on-device (proot's unpackPhase chokes on source-dir builds like
        # termux-am). Idempotent.
        apps.aarch64-linux.seed = let
          pkgs = import nixpkgs {system = "aarch64-linux";};
        in {
          type = "app";
          # Self-contained: the pre-switch bootstrap PATH has almost
          # nothing (not even grep), so every tool is a store path. And
          # /etc/hosts is read-only pre-switch, so the substituter URL
          # uses ultraviolet's tailscale IP — atticd's allowedHosts on
          # ultraviolet admits the IP form for exactly this window.
          program = "${pkgs.writeShellScript "seed-shrike" ''
            set -eu
            GREP=${pkgs.gnugrep}/bin/grep
            MKDIR=${pkgs.coreutils}/bin/mkdir
            "$MKDIR" -p "$HOME/.config/nix"
            conf="$HOME/.config/nix/nix.conf"
            if ! "$GREP" -qs '8081/nix-config' "$conf"; then
              {
                echo 'extra-substituters = http://100.66.32.65:8081/nix-config'
                echo 'extra-trusted-public-keys = nix-config:ohee3Ue/5Mw2k1KHLUW26FpngXv/bg3YRtnFk0aMHZs='
                echo 'experimental-features = nix-command flakes'
              } >> "$conf"
            fi
            echo 'seeded: attic substituter + flakes-by-default'
            echo 'next: nix shell nixpkgs#git --command nix-on-droid switch --flake ~/nix-config'
          ''}";
        };

        # shrike — Pixel 11, Nix-on-Droid. Evaluated on demand by
        # `nix-on-droid switch --flake ~/nix-config#shrike` on the phone;
        # no host here builds aarch64-linux, so this config is eval-checked
        # locally but built on-device (cache.nixos.org covers most of it).
        nixOnDroidConfigurations = let
          shrike = inputs.nix-on-droid.lib.nixOnDroidConfiguration {
            pkgs = import nixpkgs {
              system = "aarch64-linux";
              config.allowUnfree = true;
            };
            extraSpecialArgs = mkSpecialArgs "aarch64-linux";
            modules = [./hosts/shrike];
          };
        in {
          inherit shrike;
          # `nix-on-droid switch --flake ~/nix-config` (no fragment) uses
          # `default`. Only one phone exists, so alias it — a dropped
          # #shrike shouldn't be an error.
          default = shrike;
        };

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
