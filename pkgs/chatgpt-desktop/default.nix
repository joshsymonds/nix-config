{
  lib,
  chromium,
  coreutils,
  fetchurl,
  makeDesktopItem,
  runCommand,
  symlinkJoin,
  writeShellApplication,
}: let
  icon = fetchurl {
    url = "https://images.ctfassets.net/j22is2dtoxu1/intercom-img-d177d076c9a5453052925143/49d5d812b0a6fcc20a14faa8c629d9fb/icon-ios-1024_401x.png";
    hash = "sha256-55ni+g1BSaLsKPxZXIv7SZC8u0eGSXkbQqz/fN5ugF4=";
  };

  launcher = writeShellApplication {
    name = "chatgpt";
    text = ''
      profile_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/chatgpt-desktop"
      ${lib.getExe' coreutils "mkdir"} -p "$profile_dir"

      exec ${lib.getExe chromium} \
        --app=https://chatgpt.com/ \
        --class=chatgpt \
        --user-data-dir="$profile_dir" \
        --no-first-run \
        --no-default-browser-check \
        --disable-blink-features=ScrollAnchoring
    '';
  };

  desktopItem = makeDesktopItem {
    name = "chatgpt";
    desktopName = "ChatGPT";
    exec = "${launcher}/bin/chatgpt";
    icon = "chatgpt";
    startupWMClass = "chatgpt";
    categories = ["Network" "InstantMessaging"];
  };

  iconPackage = runCommand "chatgpt-icon" {} ''
    install -Dm644 ${icon} "$out/share/icons/hicolor/1024x1024/apps/chatgpt.png"
  '';
in
  symlinkJoin {
    name = "chatgpt-desktop";
    paths = [launcher desktopItem iconPackage];

    meta = {
      description = "Chat-only ChatGPT web app for Chromium";
      homepage = "https://chatgpt.com/";
      platforms = lib.platforms.linux;
      mainProgram = "chatgpt";
    };
  }
