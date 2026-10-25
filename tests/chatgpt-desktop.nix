{
  pkgs,
  chatgptDesktop,
  chatgptDesktopUnwrapped,
}: let
  expectedSources = {
    "x86_64-linux" = {
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.1013.40934_amd64.deb";
      hash = "sha256-PKWef5pmQbni+5rWgGg3hLWrgCb/dBj7ISoOvl3zodc=";
    };
    "aarch64-linux" = {
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.1013.40934_arm64.deb";
      hash = "sha256-mrLLuvM86+qh4G61yreBKJNvknoNl78A5AaU5fMcYps=";
    };
  };

  # These are strings in passthru, not fetchurl derivations. The check can
  # therefore inspect both architectures while evaluating only the host
  # architecture's source.
  sourceMetadata = chatgptDesktopUnwrapped.passthru.sourceMetadata;
  hostPayload =
    {
      "x86_64-linux" = "linux-x64";
      "aarch64-linux" = "linux-arm64";
    }.${
      pkgs.stdenv.hostPlatform.system
    };
in
  assert sourceMetadata == expectedSources;
    pkgs.runCommand "chatgpt-desktop-check" {
      nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.gnugrep];
    } ''
      set -euo pipefail

      wrapped=${chatgptDesktop}
      unwrapped=${chatgptDesktopUnwrapped}
      launcher="$wrapped/bin/chatgpt"
      desktop="$wrapped/share/applications/chatgpt.desktop"
      icon="$wrapped/share/icons/hicolor/256x256/apps/chatgpt.png"

      test -x "$launcher"
      test -f "$desktop"
      test -s "$icon"
      cmp "$unwrapped/lib/chatgpt/resources/icon-chatgpt.png" "$icon"
      test -f "$unwrapped/lib/chatgpt/resources/app.asar"

      test -n "$(find -L "$unwrapped/lib/chatgpt" -type f -name codex -perm -111 -print -quit)"
      test -n "$(find -L "$unwrapped/lib/chatgpt" -type f -name rg -perm -111 -print -quit)"
      test -n "$(find -L "$unwrapped/lib/chatgpt" -type f -name codex-code-mode-host -perm -111 -print -quit)"

      while IFS= read -r prebuild; do
        case "$(basename "$prebuild")" in
          ${hostPayload}) ;;
          *)
            echo "ASSERT FAIL: foreign direct prebuild directory remains: $prebuild" >&2
            exit 1
            ;;
        esac
      done < <(find -L "$unwrapped/lib/chatgpt" -type d -name prebuilds -exec find {} -mindepth 1 -maxdepth 1 -type d -print \;)
      test -z "$(find -L "$unwrapped/lib/chatgpt" -type f -name '*.musl.node' -print -quit)"

      grep -F -- '--disable-blink-features=ScrollAnchoring' "$unwrapped/bin/chatgpt"
      grep -F -- '--ozone-platform-hint=auto' "$unwrapped/bin/chatgpt"
      grep -F -- '--password-store=gnome-libsecret' "$unwrapped/bin/chatgpt"
      grep -Fx 'Exec=chatgpt %U' "$desktop"
      grep -Fx 'Icon=chatgpt' "$desktop"
      grep -Fx 'StartupWMClass=Chatgpt' "$desktop"
      grep -Fx 'MimeType=x-scheme-handler/codex;' "$desktop"

      # The bundled plugin marketplace must be materialized from a writable
      # copy, or every attempt leaks a read-only staging directory under
      # ~/.codex/.tmp/bundled-marketplaces. Guard the upstream knob too: if a
      # bump renames it, the override silently stops applying.
      grep -aqF CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH "$unwrapped/lib/chatgpt/resources/app.asar"
      grep -F CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH "$unwrapped/bin/chatgpt"
      helper="$unwrapped/lib/chatgpt/bundled-plugins-resources"
      export XDG_STATE_HOME="$TMPDIR/state"
      mkdir -p "$XDG_STATE_HOME/chatgpt-desktop/bundled-plugins-resources/old-version/plugins"
      chmod a-w "$XDG_STATE_HOME/chatgpt-desktop/bundled-plugins-resources/old-version/plugins"
      mirror=$("$helper")
      test "$("$helper")" = "$mirror"
      test "$(ls "$XDG_STATE_HOME/chatgpt-desktop/bundled-plugins-resources")" = "$(basename "$mirror")"
      test -d "$mirror/plugins" && test ! -L "$mirror/plugins"
      test -z "$(find "$mirror/plugins" ! -perm -u+w -print -quit)"
      test -n "$(find "$mirror/plugins" -name plugin.json -path '*/.codex-plugin/*' -print -quit)"
      test "$(readlink "$mirror/app.asar")" = "$unwrapped/lib/chatgpt/resources/app.asar"
      test "$(find "$unwrapped/lib/chatgpt/resources/plugins" -type f -perm -u+x | wc -l)" = \
        "$(find "$mirror/plugins" -type f -perm -u+x | wc -l)"

      if grep -E -i 'chromium|chatgpt\.com|--app=|--user-data-dir|chrome-chatgpt' "$launcher" "$desktop"; then
        echo "ASSERT FAIL: native ChatGPT package contains Chromium app-mode/profile launcher behavior" >&2
        exit 1
      fi

      touch "$out"
    ''
