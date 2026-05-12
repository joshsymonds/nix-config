# This file defines overlays
{inputs, ...}: let
  moarRev = "25be66bf628ad02e807ca929b5e7a1128511d255";
  moarVersion = "unstable-2025-11-09";
  moarVersionString = "${moarVersion}+g${builtins.substring 0 7 moarRev}";
in {
  default = final: prev: let
    devenvPkg = inputs.devenv.packages.${final.stdenv.hostPlatform.system}.devenv;
  in {
    devenv = devenvPkg;
    myCaddy = final.callPackage ../pkgs/caddy {};
    starlark-lsp = final.callPackage ../pkgs/starlark-lsp {};
    nuclei = final.callPackage ../pkgs/nuclei {};
    mcp-atlassian = final.callPackage ../pkgs/mcp-atlassian {};
    claudeCodeCli = final.callPackage ../pkgs/claude-code-cli {};
    deadcode = final.callPackage ../pkgs/deadcode {};
    golangciLintBin = final.callPackage ../pkgs/golangci-lint-bin {};
    coder = final.callPackage ../pkgs/coder-cli {inherit (final) unzip;};
    invidious-companion = final.callPackage ../pkgs/invidious-companion {};
    newrelic-cli = final.callPackage ../pkgs/newrelic-cli {};
    obs-face-tracker = final.callPackage ../pkgs/obs-face-tracker {};
    # lazycam is built from its own flake (~/Personal/lazycam, exposed
    # via inputs.lazycam). Surfacing it here means home-manager modules
    # can reference `pkgs.lazycam` without consumers having to know it's
    # not in nixpkgs.
    lazycam = inputs.lazycam.packages.${final.stdenv.hostPlatform.system}.default;
    redlib-veraticus = final.callPackage ../pkgs/redlib-veraticus {
      inherit (inputs) crane;
      redlibSrc = inputs.redlib-fork.sourceInfo.outPath;
      redlibRev = inputs.redlib-fork.sourceInfo.rev;
      rustOverlay = inputs.rust-overlay;
    };

    # gocover-cobertura 1.3.0 fails to build with Go 1.24; rebuild with Go 1.23
    gocover-cobertura =
      final.callPackage
      (inputs.nixpkgs + "/pkgs/by-name/go/gocover-cobertura/package.nix")
      {
        buildGoModule = final.buildGo123Module;
      };

    moor = prev.moor.overrideAttrs (_: {
      version = moarVersion;
      src = final.fetchFromGitHub {
        owner = "walles";
        repo = "moor";
        rev = moarRev;
        hash = "sha256-c2ypM5xglQbvgvU2Eq7sgMpNHSAsKEBDwQZC/Sf4GPU=";
      };
      vendorHash = "sha256-ve8QT2dIUZGTFYESt9vIllGTan22ciZr8SQzfqtqQfw=";
      ldflags = [
        "-s"
        "-w"
        "-X"
        "main.versionString=${moarVersionString}"
      ];
      postInstall = ''
        ln -s moor "$out/bin/moar"
        if [ -f ./moor.1 ]; then
          installManPage ./moor.1
        fi
      '';
    });
    moar = final.moor;

    # XIVLauncher customizations
    xivlauncher =
      prev.xivlauncher.override {
        steam = prev.steam.override {
          extraLibraries = _: [prev.gamemode.lib];
        };
      }
      // {
        desktopItems = [];
      };

    vaapiIntel = prev.vaapiIntel.override {
      enableHybridCodec = true;
    };

    # Stable packages available under pkgs.stable (if needed)
    stable = import inputs.nixpkgs-stable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  };

  additions = _: _: {};
  modifications = _: _: {};
  unstable-packages = _: _: {};
  darwin = import ./darwin.nix;

  # Packages whose flake inputs are private (git+ssh://). Applied only by the
  # specific hosts that consume them, so non-consumer hosts don't drag the
  # private input into their eval graph (which would block secrets-clean
  # reinstalls and the nixosTest VM that has no GitHub credentials).
  privatePackages = final: _prev: {
    shimmer = inputs.shimmer.packages.${final.stdenv.hostPlatform.system}.default;
  };

  # ML overlay: rebuild `onnxruntime` with the CUDA execution provider so
  # ML inference (obs-backgroundremoval's RVM, future models) offloads to
  # the GPU instead of the CPU. Applied only on gnomon (see flake.nix) —
  # CUDA toolkit + cuDNN are multi-GB and pull only one consumer in this
  # config; headless hosts (ultraviolet/bluedesert/echelon, no GPU) skip
  # the rebuild entirely.
  #
  # cudaCapabilities = ["12.0"] is set system-wide by
  # modules/hardware/gpu-nvidia.nix on gnomon — the override here picks
  # that up automatically, so the resulting onnxruntime targets sm_120
  # (Blackwell RTX 50-series) only. Build artifacts push to atticd
  # (services.atticd-cache in common.nix), available for future GPU
  # hosts to cache-hit.
  #
  # The plugin (`obs-studio-plugins.obs-backgroundremoval`) uses
  # `-DUSE_SYSTEM_ONNXRUNTIME=ON` and links against `pkgs.onnxruntime`;
  # overriding the dependency is sufficient, no plugin-level cudaSupport
  # flag exists. Plugin CMake auto-detects CUDA EP availability through
  # the linked onnxruntime symbols.
  ml = _final: prev: {
    onnxruntime = prev.onnxruntime.override {cudaSupport = true;};
  };

  # Gaming overlay: proton-cachyos + mesa-git from nix-gaming-edge, extended
  # with the local proton-gamescope wrapper (a Steam compatibility tool that
  # auto-wraps every Proton game in gamescope) and a libvpx.so.9 patch for
  # proton-cachyos's bundled ffmpeg. Applied only on gnomon (see flake.nix)
  # — keeps the bleeding-edge mesa-git rebuild and the tokidoki cache out
  # of headless servers' eval graphs.
  #
  # composeManyExtensions threads the upstream overlay first, so
  # proton-gamescope's callPackage scope can see proton-cachyos-x86_64-v3.
  #
  # ── Outstanding issues to chase later ────────────────────────────────────
  # 1. gamescope + NVIDIA Streamline (DLSS-FG) interaction triggers a 0×0
  #    DXGI swapchain reallocation that vkd3d-proton never recovers from,
  #    producing a permanently black gamescope window for any RE Engine
  #    title (and probably any other title that initialises Streamline).
  #    Currently mitigated per-game via `PROTON_GAMESCOPE_DISABLE=1` in
  #    launch options. Real fix is likely in vkd3d-proton's
  #    dxgi_vk_swap_chain_ChangeProperties — ignore 0×0 ResizeBuffers
  #    when the window has a real size, or stop destroying the swapchain
  #    when Streamline's DLSS-G context init fails.
  #
  # 2. DXVK-NVAPI Blackwell/Streamline private IDs are addressed by
  #    inputs.dxvk-nvapi-josh (joshsymonds/dxvk-nvapi @ josh/blackwell-
  #    streamline-stubs). The pkgs/dxvk-nvapi derivation cross-compiles
  #    nvapi64.dll + nvapi.dll from that fork, and the proton-cachyos
  #    postFixup below drops them over the bundled DLLs. Verification
  #    pending — if it works, this comment + TODO can be removed.
  gaming = inputs.nixpkgs.lib.composeManyExtensions [
    inputs.nix-gaming-edge.overlays.default
    (final: prev: let
      # libvpx 1.14.1 (SOVERSION 9). proton-cachyos's bundled
      # libavcodec.so.61.19.101 has a hard NEEDED on libvpx.so.9, but
      # nix-gaming-edge doesn't bundle libvpx, the SLR sniper container
      # ships libvpx.so.6, and nixpkgs is on libvpx 1.16 (libvpx.so.12).
      # On other distros pressure-vessel passes the host's libvpx.so.9
      # through from /usr/lib; NixOS has no /usr/lib to forward, so the
      # symbol resolution fails and gst-libav can't load → MF can't decode
      # AAC → RE Engine games (PRAGMATA, etc.) error during Streamline-
      # triggered intro video playback with MF_E_UNEXPECTED. Pin libvpx
      # 1.14.1 just to feed proton-cachyos the right soname.
      libvpxForProton = prev.libvpx.overrideAttrs (_: {
        version = "1.14.1";
        src = prev.fetchFromGitHub {
          owner = "webmproject";
          repo = "libvpx";
          rev = "v1.14.1";
          hash = "sha256-Pfg7g4y/dqn2VKDQU1LnTJQSj1Tont9/8Je6ShDb2GQ=";
        };
      });
      # libvpx's outputs are ["bin" "dev" "out"] with bin as the default;
      # `${libvpxForProton.out}` in string context still resolved to bin
      # on the first try (observed via `nix derivation show`). lib.getOutput
      # is the canonical accessor that unambiguously selects an output.
      libvpxLibPath = inputs.nixpkgs.lib.getOutput "out" libvpxForProton;

      # Cross-compile our forked dxvk-nvapi for both Wine target architectures.
      # The fork adds 5 NVIDIA-internal NVAPI function ID stubs (Blackwell +
      # Streamline 2.x DLSS-G + NGX runtime). See pkgs/dxvk-nvapi/default.nix.
      dxvkNvapi64 = final.pkgsCross.mingwW64.callPackage ../pkgs/dxvk-nvapi {
        src = inputs.dxvk-nvapi-josh;
      };
      dxvkNvapi32 = final.pkgsCross.mingw32.callPackage ../pkgs/dxvk-nvapi {
        src = inputs.dxvk-nvapi-josh;
      };
    in {
      # gamescope ships a Vulkan implicit layer (VkLayer_FROG_gamescope_wsi)
      # that proxies WSI surface creation to gamescope, surfacing present
      # feedback to the xwm and unlocking gamescope-specific knobs like
      # GAMESCOPE_WSI_HIDE_PRESENT_WAIT_EXT. nixpkgs builds gamescope with
      # enableWsi=false by default (the layer isn't installed), which makes
      # gamescope's xwm fall into the no-feedback dedup path on NVIDIA
      # (ValveSoftware/gamescope#1592) — every commit collapses to "same
      # buffer twice", every frame gets dropped, output is permanently
      # black. Flip the build option on so the layer is available
      # system-wide. The layer auto-activates only inside a gamescope
      # session via env-var presence, so it's a no-op outside gamescope.
      gamescope = (prev.gamescope.override { enableWsi = true; }).overrideAttrs (old: {
        patches = (old.patches or []) ++ [
          # Wine's winevulkan thunks assert on non-VK_SUCCESS returns from
          # vkGetPastPresentationTimingEXT / vkGetRefreshCycleDurationGOOGLE.
          # The WSI layer returned VK_ERROR_SURFACE_LOST_KHR for swapchains it
          # didn't create itself — which is the case under NVIDIA Streamline /
          # DLSS-FG, where the swapchain the game holds is opaque to the
          # layer. PRAGMATA hit this as an "Assertion failed!" dialog at
          # boot. Patch makes the layer return VK_SUCCESS with zero
          # timings / a 60Hz fallback for unknown swapchains.
          ../pkgs/gamescope-patches/wsi-success-on-unknown-swapchain.patch
        ];
      });

      proton-cachyos-x86_64-v3 = prev.proton-cachyos-x86_64-v3.overrideAttrs (old: {
        # Drop libvpx.so.9 into proton's bundled lib dir. proton-cachyos's
        # libavcodec.so.61.19.101 has a hard NEEDED on libvpx.so.9 — nixpkgs
        # ships libvpx 1.16 (libvpx.so.12) and the SLR sniper bundles libvpx
        # 1.10 (libvpx.so.6), so neither path satisfies the soname on NixOS.
        # On Arch/Debian, pressure-vessel forwards the host's libvpx.so.9
        # via /usr/lib. NixOS has no /usr/lib for that, so we ship it in
        # proton's own lib path. Without this, MF AAC decode for RE Engine
        # intro videos fails with MF_E_UNEXPECTED (PRAGMATA "Failed to
        # create SourceReader" dialog).
        #
        # Run in postFixup, NOT postInstall: stdenv's fixup phase runs
        # `patchelf --shrink-rpath`, which would strip RUNPATHs to anything
        # not in DT_NEEDED. Copy AFTER the shrink so libvpx keeps its
        # original RUNPATH pointing back into /nix/store (which pressure-
        # vessel forwards into the sniper).
        #
        # DO NOT bundle libSDL2/libSDL3 here. We tried, and it broke
        # joystick input: our bundled libSDL2 (sdl2-compat) overrode the
        # SLR sniper's working classic SDL2, then sdl2-compat's runtime
        # dlopen of libSDL3 failed inside the sniper. Wine's winebus uses
        # the sniper's SDL2 fine when we stay out of its way.
        postFixup = (old.postFixup or "") + ''
          install -m 0644 ${libvpxLibPath}/lib/libvpx.so.9 \
            $steamcompattool/files/lib/x86_64-linux-gnu/libvpx.so.9

          # Replace bundled jp7677/dxvk-nvapi with our forked build that has
          # the 5 Blackwell/Streamline-private NVAPI ID stubs. proton-cachyos
          # ships the same DLL twice (legacy + new wine layout); overwrite
          # both copies so whichever path Wine resolves wins.
          for dst in \
            $steamcompattool/files/lib/wine/nvapi/x86_64-windows/nvapi64.dll \
            $steamcompattool/files/lib/wine/nvidia-libs/nvapi/x86_64-windows/nvapi64.dll
          do
            install -m 0644 ${dxvkNvapi64}/nvapi64.dll "$dst"
          done
          for dst in \
            $steamcompattool/files/lib/wine/nvapi/i386-windows/nvapi.dll \
            $steamcompattool/files/lib/wine/nvidia-libs/nvapi/i386-windows/nvapi.dll
          do
            install -m 0644 ${dxvkNvapi32}/nvapi.dll "$dst"
          done
        '';
      });
      proton-gamescope = final.callPackage ../pkgs/proton-gamescope {};
    })
  ];
}
