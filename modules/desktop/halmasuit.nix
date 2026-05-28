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

  # Wallpaper uniforms — match the bar config in
  # home-manager/dms/default.nix's shaderPrimaryColor etc. so the
  # greeter wallpaper visually matches the post-login wallpaper.
  # Vec4 values include alpha=1.0 in the .a slot. The set tracks
  # chrome_hexrain.frag's declared uniforms; defaults are taken from
  # DankMaterialShell's scenes/wallpaper.json shipped values.
  wallpaperUniforms = {
    intensity = 1.0;
    cellSize  = 14.0;

    colorPrimary          = [ 0.345 0.588 0.882 1.0 ];  # #5896E1 (cyan band)
    colorSecondary        = [ 0.717 0.067 0.859 1.0 ];  # #B711DB (magenta)
    colorPrimaryContainer = [ 0.090 0.043 0.333 1.0 ];  # #170B55 (deep purple base)
    colorTertiary         = [ 0.224 1.0   0.600 1.0 ];  # #39FF99 (neon green)

    # Same "Next" palette as current (no flip animation by default —
    # flipStartTime is held far in the future so per-hex flip phase
    # clamps to 0 everywhere).
    colorPrimaryNext          = [ 0.345 0.588 0.882 1.0 ];
    colorSecondaryNext        = [ 0.717 0.067 0.859 1.0 ];
    colorPrimaryContainerNext = [ 0.090 0.043 0.333 1.0 ];
    colorTertiaryNext         = [ 0.224 1.0   0.600 1.0 ];
    flipOriginX    = 0.0;
    flipOriginY    = 0.0;
    flipStartTime  = 1.0e9;  # far future — flip wave inert
    flipPropDelay  = 0.0;
    flipDuration   = 1.0;

    modeAmount   = 1.0;
    domeStrength = 0.8;
    seamGlow     = 1.5;
    sunDriftSpeed   = 1.0;
    heightAmount    = 0.0;
    matteness       = 0.70;
    bleedBack       = 0.03;
    hexBevel        = 0.6;
    heightDriftSpeed = 0.0;

    frontSunStrength       = 0.0;
    frontSunSize           = 0.3;
    frontSunLifetime       = 40.0;
    frontSunGap            = 10.0;
    frontSunSpeed          = 0.02;
    frontSunShadowLength   = 1.0;
    frontSunShadowDarkness = 0.85;
    backSunSize            = 0.4;
    backSunStrength        = 1.0;
    backSunLifetime        = 45.0;
    backSunGap             = 12.0;
    backSunSpeed           = 0.02;
    backNegSunSize         = 0.3;
    backNegSunStrength     = 0.0;
    backNegSunLifetime     = 35.0;
    backNegSunGap          = 18.0;
    backNegSunSpeed        = 0.02;
    backSunPaletteSpeed    = 0.02;
    frontSunPaletteSpeed   = 0.02;
    backSunCount           = 3.0;
    backNegSunCount        = 2.0;
    frontSunCount          = 0.0;
    frontNegSunCount       = 0.0;
    frontNegSunStrength    = 0.0;
    frontNegSunSize        = 0.3;
    frontNegSunLifetime    = 30.0;
    frontNegSunGap         = 12.0;
    frontNegSunSpeed       = 0.02;
    fastBackSunStrength    = 0.0;
    fastBackSunSize        = 0.2;
    fastBackSunLifetime    = 8.0;
    fastBackSunGap         = 60.0;
    fastBackSunSpeed       = 0.15;

    # Single-monitor mode: windowGeom = (0, 0, width, height). The
    # actual resolution is filled in at runtime by the wallpaper
    # engine — but we declare it here so the uniform exists.
    # gnomon's DP-2/DP-3 are both 2560x1440.
    windowGeom = [ 0.0 0.0 2560.0 1440.0 ];

    barZoneEnabled   = 0.0;  # no taskbar bump on the greeter
    barZoneAnchor    = 1.0;
    barZoneThickness = 40.0;
    barZoneElevation = 0.5;
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
    # Ordered Before=halmasuit.service so the cache dir is seeded
    # before halmasuit forks the greeter.
    systemd.tmpfiles.settings."10-halmasuit-greeter" = {
      ${cacheDir}.d = {
        user  = "halmasuit-greeter";
        group = "halmasuit-greeter";
        mode  = "0750";
      };
    };

    systemd.services.halmasuit-greeter-setup = {
      description = "Seed DankGreeter cache dir with user session state";
      wantedBy    = [ "halmasuit.service" ];
      before      = [ "halmasuit.service" ];
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

        # Copy joshsymonds' session/settings/colors if present. Use
        # `cp -L` here is fine — these paths are NOT user-supplied
        # (they're hard-coded above and prefix-checked by
        # is_under_home). Symlinks INTO the DMS dir tree are honored;
        # symlinks pointing OUT escape the read-only ProtectHome
        # bind anyway, so root reads nothing it shouldn't.
        for f in /home/joshsymonds/.config/DankMaterialShell/settings.json \
                 /home/joshsymonds/.local/state/DankMaterialShell/session.json \
                 /home/joshsymonds/.cache/DankMaterialShell/dms-colors.json ; do
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

        # dms-colors.json is read at the canonical name colors.json.
        mv dms-colors.json colors.json || :

        # Hand ownership to the greeter user.
        chown -R halmasuit-greeter:halmasuit-greeter ${cacheDir} || :
      '';
    };
  };
}
