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

  # ML overlay: hand obs-backgroundremoval a CUDA-enabled onnxruntime
  # without globally swapping `pkgs.onnxruntime` itself. The plugin
  # uses `-DUSE_SYSTEM_ONNXRUNTIME=ON` and accepts `onnxruntime` as a
  # callPackage argument — overriding ONLY that argument keeps the
  # rest of the closure (notably Firefox, which carries onnxruntime
  # as a ML-translation dependency) pointing at the cache.nixos.org
  # CPU build and avoids invalidating their hashes.
  #
  # Applied only on gnomon (see flake.nix) — headless hosts have no
  # GPU and skip the CUDA closure entirely. Default `cudaPackages`
  # alias (currently 12.9) is what cache.nixos-cuda.org pre-builds
  # against, so this combination is a cache hit instead of a ~45-min
  # local onnxruntime rebuild.
  #
  # ── RVM `.ort` → `.onnx` replacement ───────────────────────────────
  #
  # obs-backgroundremoval bundles RobustVideoMatting as
  # `rvm_mobilenetv3_fp32.with_runtime_opt.ort` — a FlatBuffers-format
  # runtime-optimized model. Empirically, that file SIGSEGVs the ORT
  # CUDA Execution Provider during first inference (in
  # ParseScalesData → __memmove_avx512_unaligned_erms via
  # cuda::Resize/Upsample::ComputeInternal). The root cause: the
  # `.ort` flatbuffer freezes ORT's graph-optimization decisions at
  # conversion time, which strips the `MemcpyToHost` nodes that the
  # CUDA EP needs around Resize/Upsample to route the model's `scales`
  # input from device → host memory. Without those memcpy edges,
  # ParseScalesData memmoves a CUDA device pointer as if it were host
  # memory and the kernel faults.
  #
  # The `.onnx` (Protobuf) variant hasn't been pre-optimized — at
  # session creation, ORT's MemcpyTransformer runs against the live
  # EP set and correctly inserts the host-bound memcpy edges. So we
  # need the plugin to LOAD an `.onnx` file. ORT routes by file
  # extension (not magic bytes), so we have to actually rename — a
  # `.onnx` file at a `.ort` path goes through LoadOrtModelWithLoader
  # and verification-fails on the protobuf content.
  #
  # The fix is two-part:
  #   1. `substituteInPlace src/consts.h` so the plugin's MODEL_RVM
  #      constant points at "models/rvm_mobilenetv3_fp32.onnx"
  #      instead of "...with_runtime_opt.ort".
  #   2. `install` the .onnx at the new path in $out.
  #
  # Our declarative scene file in home-manager/obs/default.nix also
  # needs to match — the filter's model_select setting value must
  # equal the new constant ("models/rvm_mobilenetv3_fp32.onnx"),
  # otherwise the plugin won't recognize the saved selection on
  # scene-collection load.
  #
  # RVM .onnx pulled from PeterL1n/RobustVideoMatting v1.0.0 release
  # (the canonical Sep 2021 upload, 14.3 MB, fp32). Stays at fp32
  # because RVM at fp32 measures ~5 ms/frame on a 5070 Ti — well
  # under the 33 ms 30fps budget. No latency problem to solve, so
  # no reason to trade away the model's trained numerical precision
  # for speed we don't need.
  ml = _final: prev: let
    rvmOnnx = prev.fetchurl {
      url = "https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3_fp32.onnx";
      sha256 = "0a18pp5z10636vsd20iq75cybhmfcvszcq7xy9dmk3qijw957m48";
    };
  in {
    obs-studio-plugins =
      prev.obs-studio-plugins
      // {
        obs-backgroundremoval =
          (prev.obs-studio-plugins.obs-backgroundremoval.override {
            onnxruntime = prev.onnxruntime.override {cudaSupport = true;};
          })
          .overrideAttrs (old: {
            postPatch =
              (old.postPatch or "")
              + ''
                substituteInPlace src/consts.h \
                  --replace-fail \
                    'models/rvm_mobilenetv3_fp32.with_runtime_opt.ort' \
                    'models/rvm_mobilenetv3_fp32.onnx'
              '';
            postFixup =
              (old.postFixup or "")
              + ''
                install -m 0644 ${rvmOnnx} \
                  $out/share/obs/obs-plugins/obs-backgroundremoval/models/rvm_mobilenetv3_fp32.onnx
                # Leave the original .with_runtime_opt.ort in place
                # so other RVM-using paths (if any future code refers
                # to it by name) don't 404; it's just no longer the
                # plugin's selected MODEL_RVM target.
              '';
          });
      };
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
