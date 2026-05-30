# modules/desktop/halmasuit.nix — gnomon's halmasuit Phase B
# deployment wiring.
#
# Replaces the upstream greetd + DMS greeter chain with halmasuit
# (Linux system compositor) owning DRM master from initramfs through
# shutdown. DankGreeter (DMS Quickshell) runs directly as halmasuit's
# Wayland client — no nested-niri-for-greeter, no greetd daemon.
# Post-auth, niri-session is forked-then-dropped by the privileged
# halmasuit-session broker as the authenticated user.
#
# Architectural anti-patterns followed (Epic anti-patterns):
#   - greetd-the-daemon and DMS's greeter NixOS module are off; their
#     responsibilities split between halmasuit (compositor + greetd
#     protocol socket) and the local halmasuit-greeter-setup oneshot
#     that reproduces DMS's small file-copy preStart logic.
#   - /etc/pam.d/halmasuit is the canonical PAM service (the previous
#     /etc/pam.d/greetd is deleted along with greetd); yubikey-auth
#     wires U2F to the new name.
#
# What this module does NOT do:
#   - It does NOT wrap DMS's greeter module (CLAUDE.md: don't wrap;
#     restructure instead). DMS's greeter.nix is for the greetd-based
#     world halmasuit replaces. The small preStart copy logic is
#     reproduced locally because that's smaller than threading a
#     feature flag through upstream DMS.

{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.desktop.halmasuit;

  # Cache dir for the greeter — XDG_CACHE_HOME for the
  # halmasuit-greeter system user. The halmasuit-greeter-setup
  # oneshot below seeds this with the user's session.json,
  # settings.json, wallpaper paths, etc. so DankGreeter picks up
  # the same look the post-login session has.
  cacheDir = "/var/lib/halmasuit-greeter";

  # DMS-supplied packages (the same flake input nix-config consumes
  # for the post-login DMS experience). Reached directly rather than
  # through halmasuit's own dms input — both pin the same branch.
  dmsShell      = inputs.dms.packages.${pkgs.stdenv.hostPlatform.system}.dms-shell;
  dmsQuickshell = inputs.dms.packages.${pkgs.stdenv.hostPlatform.system}.quickshell;

  # The greeter executable halmasuit forks at startup. Runs as the
  # halmasuit-greeter system user; XDG_RUNTIME_DIR + WAYLAND_DISPLAY
  # point at halmasuit's own Wayland socket; HOME points at the
  # cache dir the oneshot seeded; DMS_RUN_GREETER=1 selects the
  # greeter QML code path inside DMS.
  #
  # Same shape as tests/lib/phase-b-golden.nix's greeterCmd, minus
  # the test-substrate env (LIBGL_ALWAYS_SOFTWARE, GALLIUM_DRIVER):
  # gnomon has real NVIDIA hardware, no llvmpipe forcing.
  greeterCmd = pkgs.writeShellScript "halmasuit-dankgreeter" ''
    export XDG_RUNTIME_DIR=/run/halmasuit-greeter
    export WAYLAND_DISPLAY=/run/halmasuit/wayland-0
    # halmasuit's spawn_greeter already exports GREETD_SOCK pointing
    # at the path it bound (see services.halmasuit.fromInitrd module
    # docs); do not override.
    export QT_QPA_PLATFORM=wayland
    export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
    export HOME=${cacheDir}
    export XDG_CACHE_HOME=$HOME/.cache
    export DMS_RUN_GREETER=1
    mkdir -p "$XDG_CACHE_HOME/dms-greeter"
    exec ${dmsQuickshell}/bin/quickshell \
      -p ${dmsShell}/share/quickshell/dms
  '';

  # Wallpaper uniforms — synced byte-equivalently from the user's live
  # DMS chrome_hexrain scene at
  # ~/Personal/DankMaterialShell/quickshell/Shaders/scenes/wallpaper.json
  # (the canonical source-of-truth edited via DMS's scene editor) so
  # the Phase B greeter wallpaper matches the post-login DMS exactly.
  #
  # Coercions applied:
  #   - DMS uses "#RRGGBB" hex; halmasuit takes [ r g b a ] floats.
  #     Each color row carries the source hex as a trailing comment.
  #   - DMS uses int for some uniforms (e.g. backSunCount = 4);
  #     halmasuit needs floats (the .frag declares `uniform float`).
  #     Integers are written as `4.0` etc.
  #   - DMS sends `barZoneScreens: [ "DP-2" ]` as a per-output filter
  #     consumed by Quickshell, not the shader. halmasuit's barZone is
  #     global; this knob is intentionally absent.
  #   - DMS sends `depthShading`, `flipSpecular`, `hexDepth` — these
  #     are NEWER scene-editor uniforms not present in halmasuit's
  #     current chrome_hexrain port (`halmasuit-wallpaper.glsl`).
  #     Intentionally absent until the shader is updated; sending them
  #     to a shader without bindings would be a no-op anyway.
  #
  # Last synced: 2026-05-29 against wallpaper.json in DMS fork.
  wallpaperUniforms = {
    intensity = 0.66;
    cellSize  = 29.0;

    colorPrimary          = [ 0.345098 0.592157 0.886275 1.0 ];  # #5897e2
    colorSecondary        = [ 0.717647 0.066667 0.858824 1.0 ];  # #b711db
    colorPrimaryContainer = [ 0.090196 0.082353 0.337255 1.0 ];  # #171556
    colorTertiary         = [ 0.223529 1.000000 0.600000 1.0 ];  # #39ff99

    # Distinct "Next" palette — DMS's flip-wave animation cycles
    # through these as the secondary hues. flipStartTime is held far
    # in the future (DMS default 1e9 sec) so the wave is inert under
    # normal viewing.
    colorPrimaryNext          = [ 0.223529 1.000000 0.600000 1.0 ];  # #39ff99
    colorSecondaryNext        = [ 1.000000 0.466667 0.200000 1.0 ];  # #ff7733
    colorPrimaryContainerNext = [ 0.337255 0.082353 0.082353 1.0 ];  # #561515
    colorTertiaryNext         = [ 1.000000 0.847059 0.290196 1.0 ];  # #ffd84a
    flipOriginX    = 200.0;
    flipOriginY    = 700.0;
    flipStartTime  = 1.0e9;  # far future — flip wave inert
    flipPropDelay  = 0.12;
    flipDuration   = 1.6;

    modeAmount   = 0.77;
    domeStrength = 0.78;
    seamGlow     = 2.26;
    sunDriftSpeed   = 1.8;
    heightAmount    = 0.55;
    matteness       = 0.42;
    bleedBack       = 0.18;
    hexBevel        = 0.6;
    heightDriftSpeed = 0.75;

    frontSunStrength       = 0.62;
    frontSunSize           = 0.57;
    frontSunLifetime       = 45.0;
    frontSunGap            = 12.0;
    frontSunSpeed          = 0.02;
    frontSunShadowLength   = 2.5;
    frontSunShadowDarkness = 2.3;
    backSunSize            = 0.32;
    backSunStrength        = 1.0;
    backSunLifetime        = 50.0;
    backSunGap             = 15.0;
    backSunSpeed           = 0.015;
    backNegSunSize         = 0.33;
    backNegSunStrength     = 0.43;
    backNegSunLifetime     = 35.0;
    backNegSunGap          = 18.0;
    backNegSunSpeed        = 0.02;
    backSunPaletteSpeed    = 0.84;
    frontSunPaletteSpeed   = 0.5;
    backSunCount           = 4.0;
    backNegSunCount        = 4.0;
    frontSunCount          = 4.0;
    frontNegSunCount       = 4.0;
    frontNegSunStrength    = 0.3;
    frontNegSunSize        = 0.43;
    frontNegSunLifetime    = 30.0;
    frontNegSunGap         = 15.0;
    frontNegSunSpeed       = 0.025;
    fastBackSunStrength    = 1.12;
    fastBackSunSize        = 0.25;
    fastBackSunLifetime    = 26.0;
    fastBackSunGap         = 37.0;
    fastBackSunSpeed       = 0.145;

    # Single-monitor mode: windowGeom = (0, 0, width, height). The
    # actual resolution is filled in at runtime by the wallpaper
    # engine — but we declare it here so the uniform exists.
    # gnomon's DP-2/DP-3 are both 2560x1440.
    windowGeom = [ 0.0 0.0 2560.0 1440.0 ];

    barZoneEnabled   = 1.0;   # DMS scene has it on; barZoneScreens
                              # = [ "DP-2" ] is Quickshell-side only.
    barZoneAnchor    = 2.0;
    barZoneThickness = 80.0;
    barZoneElevation = 2.0;
  };
in
{
  imports = [
    # The halmasuit module itself, imported from the flake input.
    # Always imported (not gated on cfg.enable) — the imported
    # module exposes services.halmasuit.* options that this module's
    # config block consumes; gating the import would make those
    # options invisible to other consumers of the same NixOS eval.
    inputs.halmasuit.nixosModules.halmasuit
  ];

  options.desktop.halmasuit = {
    enable = lib.mkEnableOption ''
      halmasuit (Linux system compositor) as gnomon's display
      manager + greetd-protocol host. Phase B fromInitrd
      deployment with NVIDIA rendering backend and the
      DankMaterialShell hexrain wallpaper.
    '';
  };

  config = lib.mkIf cfg.enable {
    services.halmasuit = {
      # Phase B: halmasuit starts in initramfs, survives
      # switch_root, holds DRM master from kernel handoff to
      # shutdown. The two deployment shapes (`enable` vs.
      # `fromInitrd.enable`) are mutually exclusive — see the
      # module's assertion at nix/module.nix.
      fromInitrd.enable = true;

      # The PAM service file we declare below. installPamConfig =
      # false because we declare a richer stack (with U2F) than
      # the module's default.
      pamService       = "halmasuit";
      installPamConfig = false;

      # H2: NVIDIA rendering backend. The module's nvidiaPackage
      # default is config.hardware.nvidia.package, which gnomon
      # sets via modules/hardware/gpu-nvidia.nix. extraInitrdStorePaths
      # adds the egl-wayland and egl-gbm platform-plugin closures
      # halmasuit needs to render Wayland via NVIDIA — NixOS's
      # /run/opengl-driver farm wires those on rootfs, but
      # initramfs has no such farm.
      rendering = {
        backend = "nvidia";
        extraInitrdStorePaths = [
          # The NVIDIA EGL platform plugins. Without these, libglvnd
          # can dispatch to libEGL_nvidia but the Wayland platform
          # binding is missing and the compositor fails to create
          # an EGL display.
          "${pkgs.egl-wayland}"
          "${pkgs.egl-gbm}"
        ];
        # Pin DP-3 (the left Dell U2724D — "Dell Inc. DELL U2724D
        # CDL25Z3" at logical position 0,0 per `niri msg outputs`)
        # as the primary connector. Its mode becomes the canonical
        # cloned mode for the multi-connector kernel-clone scanout;
        # DP-2 (the right monitor) joins the clone since both
        # support 2560x1440 @120Hz.
        primaryOutput = "DP-3";
      };

      # PCI BDF of the RTX 5070 Ti. gnomon has multiple DRM devices —
      # simpledrm (firmware framebuffer wrapper) + chipset-side DRM at
      # 0000:74:00.0 + NVIDIA at 0000:01:00.0. Without this, halmasuit
      # would auto-discover and possibly pick the chipset card (which
      # has no connected monitors), or hit a kernel-probe-order race.
      # Resolving by PCI BDF is stable across reboots regardless of how
      # the kernel orders DRM driver loading.
      #
      # Also: the module adds Wants=/After=systemd-udev-settle.service
      # so halmasuit waits for udev's device-node creation to complete
      # — the race that bit us during the first deploy attempt.
      drmDevice = "pci:0000:01:00.0";

      # Cursor theme + size — propagated through the broker's
      # session-leader env allowlist so the child compositor (niri)
      # renders the same theme.
      cursor.theme = "Adwaita";
      cursor.size  = 24;

      # The DankGreeter wrapper. halmasuit forks this at startup
      # as the halmasuit-greeter user; Quickshell runs as a Wayland
      # client of halmasuit (no nested niri compositor).
      greeterCommand = "${greeterCmd}";

      # Hexrain shader wallpaper — ported from DMS for visual
      # continuity between greeter and post-login. Uniforms below
      # match the post-login DMS bar config so the colour palette
      # is consistent.
      wallpaper = {
        type     = "shader";
        source   = ./halmasuit-wallpaper.glsl;
        uniforms = wallpaperUniforms;
      };

      # Epic #42 R4: ONE diagnostic boot — enables the env-gated
      # broker wire-frame trace so the next boot captures the exact
      # PAM conv byte sequence from the gen-404 signin failure.
      # REMOVE this line (or set to false) on the very next nix-config
      # change after analysis lands, per the epic's "one boot then
      # off" workflow.
      diagnostic.brokerTraceFrames = true;
    };

    # ── PAM service: /etc/pam.d/halmasuit ─────────────────────────
    # The yubikey-auth module wires U2F into this service (see
    # modules/services/yubikey-auth.nix). Without a corresponding
    # declaration of the PAM service ITSELF, the U2F wire has
    # nothing to attach to.
    #
    # This is the unixAuth-backed stack (pam_unix, pam_env,
    # pam_limits, pam_motd, etc.) — same shape as NixOS's default
    # PAM stack but under the halmasuit name.
    security.pam.services.halmasuit = {};

    # ── halmasuit-greeter-setup oneshot ──────────────────────────
    # Reproduces DMS's greeter.preStart file-copy logic locally so
    # DankGreeter can pick up the user's session.json /
    # settings.json / dms-colors at greeter start.
    #
    # Wired as a pre-hook of halmasuit-session.service (NOT
    # halmasuit.service). In Phase B halmasuit IS the surviving
    # initramfs unit and the rootfs `halmasuit.service` never
    # "starts", so wantedBy=halmasuit.service would never fire (the
    # gen 392/394 silent-no-DMS-state failure mode). The broker
    # halmasuit-session.service IS a rootfs unit, socket-activated
    # by halmasuit's first connection at /run/halmasuit-session.sock
    # post-pivot. wantedBy=halmasuit-session.service pulls this
    # oneshot into the broker's activation; before=halmasuit-session
    # .service makes systemd run it synchronously to completion
    # BEFORE the broker starts handling the auth conversation.
    # Net effect: by the time DankGreeter (forked by the broker)
    # exists, /var/lib/halmasuit-greeter is already populated.
    systemd.tmpfiles.settings."10-halmasuit-greeter" = {
      ${cacheDir}.d = {
        user  = "halmasuit-greeter";
        group = "halmasuit-greeter";
        mode  = "0750";
      };
      # XDG_RUNTIME_DIR for the greeter. The greeterCmd wrapper above
      # exports XDG_RUNTIME_DIR=/run/halmasuit-greeter; without this
      # dir present, Quickshell SEGVs in QsPaths::linkRunDir on
      # startup (gen 392, 2026-05-28 strace). Mode 0700 per XDG Base
      # Directory Spec; owned by the greeter user. Cannot use
      # systemd's RuntimeDirectory= idiom because the halmasuit unit
      # that would own it is the Phase B initramfs-survival unit, and
      # RuntimeDirectory= makes that unit eligible for the post-pivot
      # initrd-cleanup.service SIGTERM sweep — breaking
      # SurviveFinalKillSignal. See halmasuit nix/module.nix:1505 for
      # the full rationale. tmpfiles is the right tool here:
      # declarative, recreated every boot from the /run tmpfs, no
      # interaction with the survival mechanism.
      "/run/halmasuit-greeter".d = {
        user  = "halmasuit-greeter";
        group = "halmasuit-greeter";
        mode  = "0700";
      };
    };

    systemd.services.halmasuit-greeter-setup = {
      description = "Seed DankGreeter cache dir with user session state";
      wantedBy    = [ "halmasuit-session.service" ];
      before      = [ "halmasuit-session.service" ];
      after       = [ "local-fs.target" ];

      serviceConfig = {
        Type            = "oneshot";
        RemainAfterExit = true;
        # Runs as root because it reads joshsymonds' state files and
        # chowns the destination to halmasuit-greeter. The sandbox
        # directives below confine root to "read the three DMS state
        # dirs, write the cache dir, talk to no devices, see no
        # other processes."
        User  = "root";
        Group = "root";

        # Defense-in-depth sandboxing (review S-1). The unit's job is
        # bounded: read up to three well-known paths under joshsymonds'
        # home, write to /var/lib/halmasuit-greeter/. Without these
        # directives the root oneshot has full filesystem authority.
        NoNewPrivileges       = true;
        ProtectSystem         = "strict";
        # ProtectHome=true + explicit BindReadOnlyPaths is tighter
        # than ProtectHome=read-only (review S-3): the unit sees only
        # the three DMS state dirs, not joshsymonds' home as a whole.
        # An accidentally-mis-pathed jq value can't reach anything
        # outside those three dirs because they're not present in the
        # unit's filesystem namespace.
        ProtectHome           = true;
        BindReadOnlyPaths     = [
          "/home/joshsymonds/.config/DankMaterialShell"
          "/home/joshsymonds/.local/state/DankMaterialShell"
          "/home/joshsymonds/.cache/DankMaterialShell"
        ];
        PrivateTmp            = true;
        PrivateDevices        = true;
        ProtectKernelLogs     = true;
        ProtectKernelTunables = true;
        ProtectKernelModules  = true;
        ProtectControlGroups  = true;
        LockPersonality       = true;
        RestrictNamespaces    = true;
        RestrictSUIDSGID      = true;
        RestrictRealtime      = true;
        # Only the cache dir is writable; ProtectSystem=strict +
        # ProtectHome=true cover everything else.
        ReadWritePaths        = [ cacheDir ];
      };

      path = [ pkgs.jq pkgs.coreutils ];

      script = ''
        set -eu
        cd ${cacheDir}

        # Reject paths outside joshsymonds' DMS state dirs (review
        # S-2). The wallpaperPath/customThemeFile values are
        # user-controlled JSON content; without a prefix guard, root
        # would dereference an attacker-supplied symlink (`/etc/shadow`
        # or a chain that ends there) and widen its content to the
        # halmasuit-greeter system user.
        is_under_home() {
          case "$1" in
            /home/joshsymonds/.config/DankMaterialShell/*) return 0 ;;
            /home/joshsymonds/.local/state/DankMaterialShell/*) return 0 ;;
            /home/joshsymonds/.cache/DankMaterialShell/*) return 0 ;;
            *) return 1 ;;
          esac
        }

        # Copy joshsymonds' session + settings. These are home-manager-
        # symlinked to /nix/store, so they're deterministically present
        # whenever the user's HM activation has run.
        #
        # Epic #42 R1: dms-colors.json is NOT in this loop anymore. The
        # gen-404 boot showed it absent at the moment this oneshot ran
        # (DMS regenerates it lazily on user login), and the previous
        # `mv ... || :` silently fell through, leaving the greeter to
        # fall back to Tux. The colors are now baked into nix-config as
        # `./dms-colors-baked.json` and copied below — no $HOME read,
        # no silent-fallback.
        for f in /home/joshsymonds/.config/DankMaterialShell/settings.json \
                 /home/joshsymonds/.local/state/DankMaterialShell/session.json ; do
          if [ -f "$f" ]; then
            cp "$f" "./$(basename "$f")"
          fi
        done

        # If session.json references a wallpaper file under DMS's
        # state dirs, copy it in and rewrite the path. Mirrors the
        # DMS greeter module's preStart copy_wallpaper helper, with
        # the prefix guard added.
        if [ -f session.json ]; then
          copy_wallpaper() {
            local key=$1 dest=$2
            local src
            src=$(jq -r ".''${key} // empty" session.json)
            if [ -z "$src" ]; then
              return 0
            fi
            if ! is_under_home "$src"; then
              echo "halmasuit-greeter-setup: refusing $key=$src (outside DMS state dirs)" >&2
              return 0
            fi
            if [ -L "$src" ]; then
              echo "halmasuit-greeter-setup: refusing $key=$src (symlink)" >&2
              return 0
            fi
            if [ -f "$src" ]; then
              cp -P "$src" "$dest"
              jq ".''${key} = \"${cacheDir}/$dest\"" session.json > session.tmp
              mv session.tmp session.json
            fi
          }
          copy_wallpaper wallpaperPath      wallpaper
          copy_wallpaper wallpaperPathLight wallpaper-light
          copy_wallpaper wallpaperPathDark  wallpaper-dark
        fi

        # Custom-theme file referenced by settings.json — same
        # rewrite pattern, same prefix guard.
        if [ -f settings.json ]; then
          theme_file=$(jq -r '.customThemeFile // empty' settings.json)
          if [ -n "$theme_file" ] \
             && is_under_home "$theme_file" \
             && [ ! -L "$theme_file" ] \
             && [ -f "$theme_file" ] && [ -r "$theme_file" ]; then
            cp -P "$theme_file" custom-theme.json
            mv settings.json settings.orig.json
            jq '.customThemeFile = "${cacheDir}/custom-theme.json"' \
              settings.orig.json > settings.json
          elif [ -n "$theme_file" ] && ! is_under_home "$theme_file"; then
            echo "halmasuit-greeter-setup: refusing customThemeFile=$theme_file (outside DMS state dirs)" >&2
          fi
        fi

        # Epic #42 R1: write the baked DMS colors snapshot.
        # DMS's Quickshell greeter reads `colors.json` from the cache
        # dir; baking the content removes the prior dependency on
        # `~/.cache/DankMaterialShell/dms-colors.json` (which DMS only
        # writes at user-login time and was absent during the gen-404
        # cold boot). `set -eu` is in effect — a missing baked file
        # fails closed, surfacing the regression instead of silently
        # producing a default-themed greeter.
        cp ${./dms-colors-baked.json} ./colors.json

        # Force DMS's greeter-cache settings.json to render with a
        # transparent background. halmasuit paints the chrome_hexrain
        # wallpaper underneath; without this, DMS's SessionData
        # fallback paints opaque on top and the user's wallpaper is
        # hidden. The override applies ONLY to the greeter cache,
        # never to the user's actual ~/.config/DankMaterialShell —
        # post-login DMS retains its own dim Rectangle (it's the
        # right look there).
        if [ -f settings.json ]; then
          mv settings.json settings.greeter-input.json
          jq '. + {"greeterTransparentBackground": true}' \
            settings.greeter-input.json > settings.json
          rm -f settings.greeter-input.json
        else
          # No user settings.json copied — seed a minimal one that
          # still carries the transparent-background flag.
          echo '{"greeterTransparentBackground": true}' > settings.json
        fi

        # Hand ownership to the greeter user.
        chown -R halmasuit-greeter:halmasuit-greeter ${cacheDir} || :
      '';
    };
  };
}
