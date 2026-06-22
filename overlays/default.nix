# This file defines overlays
{inputs, ...}: let
  moarRev = "25be66bf628ad02e807ca929b5e7a1128511d255";
  moarVersion = "unstable-2025-11-09";
  moarVersionString = "${moarVersion}+g${builtins.substring 0 7 moarRev}";
in {
  default = final: prev: let
    devenvPkg = inputs.devenv.packages.${final.stdenv.hostPlatform.system}.devenv;

    # Append `--disable-blink-features=ScrollAnchoring` to an Electron app's
    # launcher, and re-point its desktop entry at the wrapped binary.
    #
    # Why this is a package-level fix and not a per-host preference: niri,
    # per xdg-shell, sends an activation-only `xdg_toplevel.configure` on
    # *every* keyboard-focus change (same size, only the `Activated` state
    # toggles — confirmed via WAYLAND_DEBUG: Claude Desktop's toplevel#46
    # got `configure(1274,1432, array[16/20])` on focus loss/gain, size
    # byte-identical). Chromium wrongly runs a layout pass on that no-op
    # configure; CSS scroll anchoring then re-latches to a mid-list element,
    # knocking bottom-pinned chat views (Claude Desktop, Slack, Discord,
    # Signal) partway up. These apps JS-pin to the bottom on new content,
    # so disabling Blink's scroll anchoring removes the bad re-latch with
    # no downside. An app installed on a niri box without this is simply
    # broken — so it belongs with the package, inherited by every host.
    #
    # `overrideAttrs` + `postFixup` is the right tool for nixpkgs Electron
    # apps: their `.desktop` Exec is generated against `$out` (Slack hard-
    # codes the store path), so the wrapper must live in the same
    # derivation or GUI launches bypass it. The FHS-env claude-desktop is
    # handled separately below (its builder runs no postFixup, and its
    # desktop entry is bare-name/PATH-resolved).
    electronNoScrollAnchoring = pkg: exe:
      pkg.overrideAttrs (o: {
        nativeBuildInputs = (o.nativeBuildInputs or []) ++ [final.makeWrapper];
        postFixup =
          (o.postFixup or "")
          + ''
            wrapProgram "$out/bin/${exe}" \
              --add-flags "--disable-blink-features=ScrollAnchoring"
          '';
      });
  in {
    devenv = devenvPkg;
    myCaddy = final.callPackage ../pkgs/caddy {};
    starlark-lsp = final.callPackage ../pkgs/starlark-lsp {};
    nuclei = final.callPackage ../pkgs/nuclei {};
    mcp-atlassian = final.callPackage ../pkgs/mcp-atlassian {};
    claudeCodeCli = final.callPackage ../pkgs/claude-code-cli {};
    codexCli = final.callPackage ../pkgs/codex-cli {};
    deadcode = final.callPackage ../pkgs/deadcode {};
    golangciLintBin = final.callPackage ../pkgs/golangci-lint-bin {};
    coder = final.callPackage ../pkgs/coder-cli {inherit (final) unzip;};
    invidious-companion = final.callPackage ../pkgs/invidious-companion {};
    newrelic-cli = final.callPackage ../pkgs/newrelic-cli {};
    morgen-fetch = final.callPackage ../pkgs/morgen-fetch {};
    morgen-notifier = final.callPackage ../pkgs/morgen-notifier {};
    wyoming-onnx-asr = final.callPackage ../pkgs/wyoming-onnx-asr {};
    claude-notify-sounds = final.callPackage ../pkgs/claude-notify-sounds {};
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

    # keyd: fix a silent wire-parser desync in keyd-application-mapper.
    # Its Wayland reader used bare self.sock.recv(8)/recv(size-8); on a
    # SOCK_STREAM recv() may short-read, and a short payload read desyncs
    # the parser permanently — the mapper stays alive and connected but
    # stops reacting to focus changes, so per-app masks (e.g. gnomon's
    # [steam-app-*] meta⇒alt) silently stop applying until it's restarted.
    # The patch routes reads through a recvall() loop. Mirrors upstream
    # PR #1261 (open, bundled with unrelated Cosmic work); drop this once
    # that lands. Correctness fix → overlay (all hosts), not per-host.
    #
    # nixpkgs builds the mapper as a SEPARATE buildPythonApplication
    # (`appMap`) that the main keyd only symlinks to — overrideAttrs on
    # keyd can't reach it, so we rebuild that small derivation from the
    # same (now patched) src and re-point the symlink. Tracking
    # `inherit (prev.keyd) version src` keeps us on nixpkgs' keyd version.
    keyd = let
      appMap = prev.python3Packages.buildPythonApplication {
        pname = "keyd-application-mapper";
        inherit (prev.keyd) version src;
        pyproject = false;
        patches = [../pkgs/keyd/recvall.patch];
        postPatch = ''
          substituteInPlace scripts/keyd-application-mapper \
            --replace-fail /bin/sh ${prev.runtimeShell}
        '';
        propagatedBuildInputs = with prev.python3Packages; [
          xlib
          pygobject3.out
          dbus-python.out
        ];
        dontBuild = true;
        installPhase = ''
          install -Dm555 -t $out/bin scripts/keyd-application-mapper
        '';
        meta.mainProgram = "keyd-application-mapper";
      };
    in
      prev.keyd.overrideAttrs (_: {
        postInstall = ''
          ln -sf ${prev.lib.getExe appMap} $out/bin/keyd-application-mapper
          rm -rf $out/etc
        '';
      });

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

    # Morgen patches, applied by splicing into the upstream asar-pack
    # invocation. Both anchors are exact-string `--replace-fail` matches
    # so a future morgen bump fails loudly here instead of silently
    # producing a broken build. Reference: 0xpetersatoshi/nix-config.
    #
    # (1) main.js: `app.disableHardwareAcceleration()` → no-op.
    # On Wayland/NVIDIA that call flips Chromium's GPU process fully
    # off, and Sentry's electron integration then calls
    # `app.getGPUInfo()` which rejects with "GPU access not allowed" —
    # an unhandled promise rejection at the top of main, so
    # BrowserWindow.show() never fires and the app runs as a
    # window-less zombie process.
    #
    # (2) app.js: merged-event color → primary calendar only.
    # When "Merge Duplicate Events" combines an event with mirrors
    # (the N→N calendar-propagation workflow lives in this repo's
    # Morgen Custom Workflow), the renderer builds a gradient of
    # every merged event's calendar color. Patch the color-array
    # to single-element {primary's calendar color}; the `[Busy]`
    # mirrors carry "Calendar Propagation" + a `Ref-Group-Id`
    # description marker, which combine to give them ~100× the
    # priority factor of the source, so `D` (= `L[0]` after
    # priority sort) is always the source event. Result: merged
    # block shows the source calendar's color and title, mirrors
    # contribute busy-block visibility without polluting the view.
    morgen = prev.morgen.overrideAttrs (oldAttrs: {
      installPhase =
        builtins.replaceStrings
        ["asar pack --unpack='{*.node,*.ftz,rect-overlay}' \"$TMP/work\" $out/opt/Morgen/resources/app.asar"]
        [
          ''
            substituteInPlace $TMP/work/dist/main.js \
              --replace-fail "zj&&ee.app.disableHardwareAcceleration()" "void 0"
            substituteInPlace $TMP/work/dist/app.js \
              --replace-fail "N.map(e=>A.calendarById\$[e]?.mtColor)" "[A.calendarById\$[D?.mtCalendarId]?.mtColor]"
            asar pack --unpack='{*.node,*.ftz,rect-overlay}' "$TMP/work" $out/opt/Morgen/resources/app.asar
          ''
        ]
        oldAttrs.installPhase;
    });

    # Electron chat apps, scroll-anchoring fix baked in (see
    # electronNoScrollAnchoring above). Per-host package lists reference
    # these by bare name and transparently get the fix.
    slack = electronNoScrollAnchoring prev.slack "slack";
    signal-desktop = electronNoScrollAnchoring prev.signal-desktop "signal-desktop";
    vesktop = electronNoScrollAnchoring prev.vesktop "vesktop";

    # Claude Desktop: sourced from the claude-desktop flake input (daily
    # CI auto-bumps upstream Anthropic releases; `nix flake update
    # claude-desktop` pulls newer). The -fhs variant wraps the Electron
    # app in buildFHSEnv so MCP servers can shell out to npx/uvx/docker.
    # That builder runs no postFixup, but its desktop Exec is bare
    # `claude-desktop` (PATH-resolved), so a symlinkJoin that replaces
    # only the bin with a flag-injecting wrapper is sufficient and cheap
    # (no app rebuild) — the desktop entry resolves to the wrapper via
    # PATH without needing a rewrite.
    claude-desktop = let
      base = inputs.claude-desktop.packages.${final.stdenv.hostPlatform.system}.claude-desktop-fhs;
    in
      final.symlinkJoin {
        name = "claude-desktop-noscrollanchor";
        paths = [base];
        nativeBuildInputs = [final.makeWrapper];
        postBuild = ''
          rm "$out/bin/claude-desktop"
          makeWrapper "${base}/bin/claude-desktop" "$out/bin/claude-desktop" \
            --add-flags "--disable-blink-features=ScrollAnchoring"
        '';
      };

    # Stable packages available under pkgs.stable (if needed)
    stable = import inputs.nixpkgs-stable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };

    # Tailscale pinned to 1.98.2+ (nixpkgs-tailscale side-channel input).
    # The main lock ships tailscale 1.98.0, whose Linux MagicDNS handling
    # breaks after a network link change: tailscaled stops registering the
    # `tail*.ts.net` LocalDomain and routes the suffix to the public ts.net
    # nameserver (no private records), so every node NXDOMAINs the tailnet's
    # own MagicDNS names. On ultraviolet, podman veth churn re-triggers this
    # constantly and the fleet loses the Shimmer MCP endpoint
    # (https://ultraviolet.tail82223.ts.net:8443). 1.98.2 fixes the
    # recompute. See NixOS/nixpkgs#520715. REMOVE this override + the input
    # once the main lock carries tailscale >= 1.98.2.
    tailscale =
      (import inputs.nixpkgs-tailscale {
        system = final.stdenv.hostPlatform.system;
      })
      .tailscale;
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

  # Gaming overlay: proton-cachyos from nix-gaming-edge, extended with a
  # libvpx.so.9 patch for proton-cachyos's bundled ffmpeg. Applied only on
  # gnomon (see flake.nix) — keeps the tokidoki cache out of headless
  # servers' eval graphs. Native-Wayland / NVAPI / iGPU-filter defaults are
  # baked into the tool as a user_settings.py (below) — NOT niri session env
  # vars: Steam is not spawned from niri's environment (verified absent from
  # the game's /proc/<pid>/environ), so programs.niri.settings.environment
  # never reached Proton games and those defaults silently did nothing there.
  #
  # composeManyExtensions threads the upstream overlay first so the
  # proton-cachyos-x86_64-v3 override below sees the base package.
  gaming = inputs.nixpkgs.lib.composeManyExtensions [
    inputs.nix-gaming-edge.overlays.default
    (_final: prev: let
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

      # Per-tool environment defaults for every game launched through
      # proton-cachyos. proton imports this in init_session and merges each
      # key into the game env *only if not already set* (proton:1801-1808),
      # so a per-game `PROTON_USE_WAYLAND=0 %command%` launch option still
      # wins. check_environment reads PROTON_USE_WAYLAND from that merged env
      # (proton:1711/1873), so this genuinely selects winewayland.drv.
      #
      #   PROTON_USE_WAYLAND       winewayland.drv → native Wayland to niri
      #   PROTON_ENABLE_NVAPI      expose the NVIDIA GPU to NVAPI → DLSS / RT
      #   PROTON_HIDE_NVIDIA_GPU=0 counterpart: don't hide it from NVAPI probes
      #   VKD3D/DXVK filter        hide the Raphael iGPU so UE5 (Satisfactory)
      #                            doesn't pick its fake-huge GTT "VRAM"
      protonUserSettings = prev.writeText "proton-cachyos-user_settings.py" ''
        user_settings = {
            "PROTON_USE_WAYLAND": "1",
            "PROTON_ENABLE_NVAPI": "1",
            "PROTON_HIDE_NVIDIA_GPU": "0",
            "VKD3D_FILTER_DEVICE_NAME": "NVIDIA",
            "DXVK_FILTER_DEVICE_NAME": "NVIDIA",
        }
      '';
    in {
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
        postFixup =
          (old.postFixup or "")
          + ''
            install -m 0644 ${libvpxLibPath}/lib/libvpx.so.9 \
              $steamcompattool/files/lib/x86_64-linux-gnu/libvpx.so.9
            install -m 0644 ${protonUserSettings} \
              $steamcompattool/user_settings.py
          '';
      });
    })
  ];
}
