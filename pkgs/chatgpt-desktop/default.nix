# OpenAI's official preview ChatGPT desktop app for Linux.
#
# This is the unwrapped derivation. The deployed package is the FHS wrapper in
# ./fhs.nix, which gives the bundled Work/Codex subprocesses the tools they
# expect on a normal Linux filesystem.
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
  graphite2,
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
  libusb1,
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
  version = "26.810.41047";
  debBase = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt";

  sourceMetadata = {
    "x86_64-linux" = {
      url = "${debBase}/chatgpt_${version}_amd64.deb";
      hash = "sha256-eHFfo80Tb/ZwcNqnaBmtrsxbQumYUVWWWWRdzh+/KvM=";
    };
    "aarch64-linux" = {
      url = "${debBase}/chatgpt_${version}_arm64.deb";
      hash = "sha256-mW95PKA5dnb8uc0AIRTJd1XMN0GQfEAPf13c9scMCk4=";
    };
  };

  srcs = lib.mapAttrs (_: source: fetchurl source) sourceMetadata;
  hostSystem = stdenv.hostPlatform.system;
  hostPayload =
    {
      "x86_64-linux" = "linux-x64";
      "aarch64-linux" = "linux-arm64";
    }
    .${
      hostSystem
    } or (throw "chatgpt-desktop: unsupported system ${hostSystem}");
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "chatgpt-desktop-unwrapped";
    inherit version;

    src = srcs.${hostSystem} or (throw "chatgpt-desktop: unsupported system ${hostSystem}");

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
      graphite2
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
      libusb1
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

    runtimeDependencies = [
      libGL
      libglvnd
      libpulseaudio
      libsecret
      (lib.getLib systemd)
    ];

    # Electron optionally dlopen()s these Qt Ozone shims when present in the
    # upstream payload. They are not required on the GTK runtime path, so
    # permit only their exact SONAMEs rather than masking unrelated misses.
    autoPatchelfIgnoreMissingDeps = [
      "libQt5Core.so.5"
      "libQt5Gui.so.5"
      "libQt5Widgets.so.5"
      "libQt6Core.so.6"
      "libQt6Gui.so.6"
      "libQt6Widgets.so.6"
    ];

    dontConfigure = true;
    dontBuild = true;
    dontWrapGApps = true;

    unpackPhase = ''
      runHook preUnpack
      dpkg-deb --fsys-tarfile "$src" | tar -x --no-same-owner --no-same-permissions
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      mkdir -p "$out/lib"
      cp -r usr/lib/chatgpt "$out/lib/"

      # Keep only the native glibc prebuild. The upstream bundle carries
      # platform and musl variants alongside it; pruning only direct children
      # of `prebuilds` avoids touching unrelated application directories.
      find "$out/lib/chatgpt" -type d -name prebuilds -print0 | while IFS= read -r -d "" prebuilds; do
        find "$prebuilds" -mindepth 1 -maxdepth 1 -type d ! -name "${hostPayload}" -exec rm -rf {} +
      done
      find "$out/lib/chatgpt" -type f -name '*.musl.node' -delete

      install -Dm644 usr/share/applications/chatgpt.desktop "$out/share/applications/chatgpt.desktop"
      sed -i \
        -e 's|^Exec=.*|Exec=chatgpt %U|' \
        -e 's|^Icon=.*|Icon=chatgpt|' \
        -e 's|^StartupWMClass=.*|StartupWMClass=Chatgpt|' \
        "$out/share/applications/chatgpt.desktop"
      grep -q '^Exec=' "$out/share/applications/chatgpt.desktop" || echo 'Exec=chatgpt %U' >> "$out/share/applications/chatgpt.desktop"
      grep -q '^Icon=' "$out/share/applications/chatgpt.desktop" || echo 'Icon=chatgpt' >> "$out/share/applications/chatgpt.desktop"
      grep -q '^StartupWMClass=' "$out/share/applications/chatgpt.desktop" || echo 'StartupWMClass=Chatgpt' >> "$out/share/applications/chatgpt.desktop"
      install -Dm644 usr/lib/chatgpt/resources/icon-chatgpt.png \
        "$out/share/icons/hicolor/256x256/apps/chatgpt.png"

      runHook postInstall
    '';

    postFixup = ''
      makeWrapper "$out/lib/chatgpt/codex-launcher" "$out/bin/chatgpt" \
        "''${gappsWrapperArgs[@]}" \
        --add-flags "--disable-blink-features=ScrollAnchoring" \
        --add-flags "--ozone-platform-hint=auto" \
        --add-flags "--password-store=gnome-libsecret"
    '';

    passthru = {
      inherit sourceMetadata;
      deb = finalAttrs.src;
    };

    meta = {
      description = "Official preview ChatGPT desktop app with bundled ChatGPT, Work, and Codex";
      homepage = "https://chatgpt.com";
      downloadPage = "https://openai.com/chatgpt/download/";
      license = lib.licenses.unfree;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = ["x86_64-linux" "aarch64-linux"];
      mainProgram = "chatgpt";
    };
  })
