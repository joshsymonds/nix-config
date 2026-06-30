# Claude Desktop (the chat app — not Claude Code) for Linux.
#
# Source is Anthropic's *official* native-Linux build, pulled straight from
# their apt repository's pool (https://downloads.claude.ai/claude-desktop/apt).
# The `.deb` is a self-contained Electron 42 bundle with the app.asar, locales,
# tray icons, the Cowork helper, virtiofsd and the Cowork VM image already laid
# out under resources/ — no Windows `.exe` extraction or asar repacking needed.
# So packaging is the standard "prebuilt Electron .deb" recipe: extract,
# autoPatchelf the bundled ELFs, wrap.
#
# This is the *unwrapped* derivation — runnable on its own, but the deployed
# package is the buildFHSEnv wrap in ./fhs.nix, which gives MCP servers and
# Cowork a normal filesystem to shell out into.
#
# Bump: edit `version` + both hashes, then `nix flake check`. Find the latest
# version and hashes in the apt Packages index:
#   curl -fsSL https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  wrapGAppsHook3,
  makeWrapper,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libcap_ng,
  libGL,
  libayatana-appindicator,
  libdrm,
  libgbm,
  libglvnd,
  libnotify,
  libpulseaudio,
  libseccomp,
  libsecret,
  libuuid,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxkbcommon,
  libxrandr,
  libxrender,
  libxscrnsaver,
  libxshmfence,
  libxtst,
  nspr,
  nss,
  pango,
  systemd,
}: let
  version = "1.17377.0";
  debBase = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop";

  srcs = {
    "x86_64-linux" = fetchurl {
      url = "${debBase}/claude-desktop_${version}_amd64.deb";
      hash = "sha256-VjyN+O47lXyiNBFZgDhulgAH7Yz8jMBMd9WKjUP2wBg=";
    };
    "aarch64-linux" = fetchurl {
      url = "${debBase}/claude-desktop_${version}_arm64.deb";
      hash = "sha256-R1ms8ZtqyYH7rlzRwlqCjunG6Vz6nqTLjJzNfC/FOHE=";
    };
  };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "claude-desktop-unwrapped";
    inherit version;

    src = srcs.${stdenv.hostPlatform.system} or (throw "claude-desktop: unsupported system ${stdenv.hostPlatform.system}");

    nativeBuildInputs = [
      dpkg
      autoPatchelfHook
      wrapGAppsHook3
      makeWrapper
    ];

    buildInputs = [
      alsa-lib
      at-spi2-atk
      at-spi2-core
      atk
      cairo
      cups
      dbus
      expat
      fontconfig
      freetype
      gdk-pixbuf
      glib
      gtk3
      libayatana-appindicator
      libcap_ng
      libdrm
      libgbm
      libnotify
      libseccomp
      libsecret
      libuuid
      libx11
      libxcb
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxi
      libxkbcommon
      libxrandr
      libxrender
      libxscrnsaver
      libxshmfence
      libxtst
      nspr
      nss
      pango
      systemd
      stdenv.cc.cc.lib
    ];

    # Libraries the Electron/Chromium process dlopen()s at runtime rather than
    # listing in DT_NEEDED — autoPatchelfHook bakes these into every patched
    # ELF's RUNPATH so they resolve without an FHS env or LD_LIBRARY_PATH.
    runtimeDependencies = [
      libGL
      libglvnd
      libpulseaudio
      libsecret
      (lib.getLib systemd)
    ];

    dontConfigure = true;
    dontBuild = true;

    # We wrap the launcher ourselves in postFixup (to add Chromium flags), so
    # let wrapGAppsHook3 only *collect* the GTK/GIO/pixbuf env into
    # gappsWrapperArgs instead of wrapping a binary that doesn't exist yet.
    dontWrapGApps = true;

    # `dpkg-deb -x` preserves chrome-sandbox's SUID bit (rwsr-xr-x) and dies
    # when the build sandbox forbids the setuid chmod. Pipe the data tarball
    # through our own tar instead, dropping special modes — the SUID helper
    # can't be setuid in the (read-only) store anyway; Chromium falls back to
    # the unprivileged user-namespace sandbox, which NixOS enables by default.
    unpackPhase = ''
      runHook preUnpack
      dpkg-deb --fsys-tarfile "$src" | tar -x --no-same-owner --no-same-permissions
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      # The bundle (Electron binary + resources/) and the hicolor icons +
      # .desktop file. We intentionally drop usr/bin/claude-desktop (a symlink
      # to the raw, unwrapped Electron binary) — our wrapper replaces it.
      cp -r usr/lib "$out/lib"
      cp -r usr/share "$out/share"

      runHook postInstall
    '';

    # autoPatchelfHook runs during fixupOutput (before this postFixup), so the
    # Electron binary is already patched when we wrap it. The flags:
    #   --disable-blink-features=ScrollAnchoring  niri sends activation-only
    #     xdg_toplevel.configure events on every focus change; Chromium runs a
    #     spurious layout pass and scroll anchoring re-latches, knocking the
    #     bottom-pinned chat view partway up. The app JS-pins to bottom, so
    #     killing Blink's anchoring is pure win on niri. (Same fix the overlay
    #     applies to slack/signal/vesktop.)
    #   --ozone-platform-hint=auto  run natively on Wayland (niri) when
    #     available, fall back to XWayland otherwise.
    #   --password-store=gnome-libsecret  Chromium picks its safeStorage
    #     backend from XDG_CURRENT_DESKTOP; on niri (neither GNOME nor KDE) it
    #     falls back to the `basic` plaintext store, which the app rejects with
    #     "your sign-in won't be saved". gnome-keyring owns org.freedesktop.secrets
    #     on this fleet, so forcing the libsecret backend lets the login persist.
    postFixup = ''
      makeWrapper "$out/lib/claude-desktop/claude-desktop" "$out/bin/claude-desktop" \
        "''${gappsWrapperArgs[@]}" \
        --add-flags "--disable-blink-features=ScrollAnchoring" \
        --add-flags "--ozone-platform-hint=auto" \
        --add-flags "--password-store=gnome-libsecret"
    '';

    passthru.deb = finalAttrs.src;

    meta = {
      description = "Claude Desktop (official native Linux build, unwrapped)";
      homepage = "https://claude.ai";
      downloadPage = "https://claude.com/download";
      license = lib.licenses.unfree;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = ["x86_64-linux" "aarch64-linux"];
      mainProgram = "claude-desktop";
    };
  })
