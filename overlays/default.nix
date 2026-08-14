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
  in
    (import ../pkgs/simple.nix {pkgs = final;})
    // {
      devenv = devenvPkg;

      # redlib-veraticus needs flake inputs (crane, redlib-fork, rust-overlay)
      # so it isn't in pkgs/simple.nix's plain-callPackage set; pkgs/default.nix
      # (the `nix build .#redlib-veraticus` path) wires the same inputs
      # through separately.
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

      # ChatGPT Desktop: OpenAI's official native Linux preview with bundled
      # ChatGPT, Work, and Codex. The unwrapped .deb package and FHS wrapper
      # mirror the Claude Desktop packaging structure.
      chatgpt-desktop-unwrapped = final.callPackage ../pkgs/chatgpt-desktop {};
      chatgpt-desktop = final.callPackage ../pkgs/chatgpt-desktop/fhs.nix {};

      # Claude Desktop (the chat app — not Claude Code): Anthropic's official
      # native-Linux build, packaged locally from their apt repo. See
      # pkgs/claude-desktop/. The niri scroll-anchoring fix and the Wayland
      # ozone hint are baked into the package launcher (default.nix); the
      # -fhs wrap gives MCP servers and Cowork a normal filesystem to shell
      # out into. Bump via pkgs/claude-desktop/default.nix (version + hashes).
      claude-desktop-unwrapped = final.callPackage ../pkgs/claude-desktop {};
      claude-desktop = final.callPackage ../pkgs/claude-desktop/fhs.nix {};
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

  # Gaming overlay: proton-cachyos from nix-gaming-edge, extended with a
  # libvpx.so.9 patch for proton-cachyos's bundled ffmpeg. Both gnomon and
  # stygianlibrary attach this overlay (see flake.nix), but only gnomon
  # currently consumes proton-cachyos. NVAPI / iGPU-filter defaults are baked
  # into the tool as a user_settings.py (below) — NOT niri session env vars:
  # Steam is not spawned from niri's environment (verified absent from the
  # game's /proc/<pid>/environ), so programs.niri.settings.environment never
  # reached Proton games and those defaults silently did nothing there.
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
      # so per-game launch options still win. PROTON_USE_WAYLAND is
      # intentionally omitted: proton-cachyos keeps its compatibility-first
      # X11/Xwayland default, while a per-title
      # `PROTON_USE_WAYLAND=1 %command%` opts into winewayland.drv.
      #
      #   PROTON_ENABLE_NVAPI      expose the NVIDIA GPU to NVAPI → DLSS / RT
      #   PROTON_HIDE_NVIDIA_GPU=0 counterpart: don't hide it from NVAPI probes
      #   VKD3D/DXVK filter        hide the Raphael iGPU so UE5 (Satisfactory)
      #                            doesn't pick its fake-huge GTT "VRAM"
      protonUserSettings = prev.writeText "proton-cachyos-user_settings.py" ''
        user_settings = {
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
