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
  coreutils,
  findutils,
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
  nodejs_24,
  nspr,
  nss,
  openssl,
  pango,
  systemd,
  tpm2-tss,
}: let
  version = "26.1013.40934";
  debBase = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt";

  sourceMetadata = {
    "x86_64-linux" = {
      url = "${debBase}/chatgpt_${version}_amd64.deb";
      hash = "sha256-PKWef5pmQbni+5rWgGg3hLWrgCb/dBj7ISoOvl3zodc=";
    };
    "aarch64-linux" = {
      url = "${debBase}/chatgpt_${version}_arm64.deb";
      hash = "sha256-mrLLuvM86+qh4G61yreBKJNvknoNl78A5AaU5fMcYps=";
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
      # resources/native/remote-control-device-key.node (26.10xx+) links
      # libtss2-{esys,mu,tcti-device} and libcrypto.so.3 directly.
      openssl
      tpm2-tss
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

      # The computer-use plugins (cua-repl, code-review, codex_app) run on
      # the bundled cua_node/bin/node, an upstream node-v24 linux-x64
      # build. autoPatchelf corrupts it: the PHDR segment it prepends at
      # 0x3ff000 overlaps the original text LOAD, and ld.so SIGSEGVs in
      # dl_main before node starts. Swap in nixpkgs' node of the same
      # major, and fail the build when an upstream bump moves
      # manifest.json's node_binary_version to a different major.
      cua_node_version="$(sed -n 's/.*"node_binary_version": *"\([^"]*\)".*/\1/p' \
        "$out/lib/chatgpt/resources/cua_node/manifest.json")"
      if [[ "''${cua_node_version%%.*}" != "${lib.versions.major nodejs_24.version}" ]]; then
        echo "chatgpt-desktop: cua_node ships node $cua_node_version; swap nodejs_24 for its major" >&2
        exit 1
      fi
      ln -sf ${lib.getExe nodejs_24} "$out/lib/chatgpt/resources/cua_node/bin/node"

      install -Dm644 usr/share/applications/chatgpt.desktop "$out/share/applications/chatgpt.desktop"
      # Upstream's entry claims http/https, csv/tsv, and the Office formats,
      # so file managers without an explicit default hand spreadsheets and
      # documents to ChatGPT. Keep only the codex:// scheme the app owns.
      sed -i \
        -e 's|^MimeType=.*|MimeType=x-scheme-handler/codex;|' \
        -e 's|^Exec=.*|Exec=chatgpt %U|' \
        -e 's|^Icon=.*|Icon=chatgpt|' \
        -e 's|^StartupWMClass=.*|StartupWMClass=Chatgpt|' \
        "$out/share/applications/chatgpt.desktop"
      grep -q '^Exec=' "$out/share/applications/chatgpt.desktop" || echo 'Exec=chatgpt %U' >> "$out/share/applications/chatgpt.desktop"
      grep -q '^Icon=' "$out/share/applications/chatgpt.desktop" || echo 'Icon=chatgpt' >> "$out/share/applications/chatgpt.desktop"
      grep -q '^StartupWMClass=' "$out/share/applications/chatgpt.desktop" || echo 'StartupWMClass=Chatgpt' >> "$out/share/applications/chatgpt.desktop"
      install -Dm644 usr/lib/chatgpt/resources/icon-chatgpt.png \
        "$out/share/icons/hicolor/256x256/apps/chatgpt.png"

      substitute ${./bundled-plugins-resources.sh} "$out/lib/chatgpt/bundled-plugins-resources" \
        --subst-var-by shell "${stdenv.shell}" \
        --subst-var-by coreutils "${coreutils}" \
        --subst-var-by findutils "${findutils}" \
        --subst-var-by resources "$out/lib/chatgpt/resources" \
        --subst-var out
      chmod +x "$out/lib/chatgpt/bundled-plugins-resources"

      runHook postInstall
    '';

    postFixup = ''
      makeWrapper "$out/lib/chatgpt/codex-launcher" "$out/bin/chatgpt" \
        "''${gappsWrapperArgs[@]}" \
        --run "export CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH=\"\$($out/lib/chatgpt/bundled-plugins-resources)\"" \
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
