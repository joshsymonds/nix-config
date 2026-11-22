# Google Gemini as a standalone app window.
#
# Google ships no Gemini desktop app for Linux (macOS, ChromeOS, mobile, and
# web only), and the third-party Electron wrappers are unmaintained. This runs
# Google's own web app in a Chromium `--app` window with a dedicated profile,
# so it gets its own process, window class, login, and desktop entry.
#
# Chromium names an `--app` window's Wayland app_id after the URL and profile
# directory: --app=https://gemini.google.com/app in profile Default reports
# chrome-gemini.google.com__app-Default, and `--class` does not change it
# (checked under headless sway). StartupWMClass is built from the same host
# and path as the launch URL, so the focus-or-spawn window match follows it.
{
  lib,
  stdenvNoCC,
  chromium,
  fetchurl,
  makeDesktopItem,
  writeShellApplication,
}: let
  host = "gemini.google.com";
  path = "app";
  url = "https://${host}/${path}";
  appId = "chrome-${host}__${path}-Default";

  icon = fetchurl {
    url = "https://www.gstatic.com/lamda/images/gemini_sparkle_4g_512_lt_f94943af3be039176192d.png";
    hash = "sha256-Xnz+yqU/T2WjE/6JsPOJVIEmVEp4+thIlRDHCuZBpKE=";
  };

  # --ozone-platform-hint=auto keeps the window on Wayland even when
  # NIXOS_OZONE_WL is unset; under XWayland the window class differs and
  # StartupWMClass would no longer match. ScrollAnchoring is disabled for the
  # same niri focus-change re-latch that overlays/default.nix fixes in the
  # Electron chat apps.
  launcher = writeShellApplication {
    name = "gemini-web";
    text = ''
      exec ${lib.getExe chromium} \
        --user-data-dir="''${XDG_DATA_HOME:-$HOME/.local/share}/gemini-web" \
        --no-first-run \
        --no-default-browser-check \
        --ozone-platform-hint=auto \
        --disable-blink-features=ScrollAnchoring \
        --app=${url} \
        "$@"
    '';
  };

  desktopItem = makeDesktopItem {
    name = "gemini-web";
    desktopName = "Gemini";
    genericName = "AI Assistant";
    comment = "Google Gemini";
    exec = "gemini-web";
    icon = "gemini-web";
    startupWMClass = appId;
    categories = ["Network" "Chat"];
  };
in
  stdenvNoCC.mkDerivation {
    pname = "gemini-web";
    version = "1";

    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 ${lib.getExe launcher} "$out/bin/gemini-web"
      install -Dm644 ${desktopItem}/share/applications/gemini-web.desktop \
        "$out/share/applications/gemini-web.desktop"
      install -Dm644 ${icon} "$out/share/icons/hicolor/512x512/apps/gemini-web.png"
      runHook postInstall
    '';

    passthru = {inherit appId url;};

    meta = {
      description = "Google Gemini web app in a dedicated Chromium app window";
      homepage = url;
      platforms = lib.platforms.linux;
      mainProgram = "gemini-web";
    };
  }
