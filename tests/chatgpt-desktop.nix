{
  pkgs,
  chatgptDesktop,
  chatgptDesktopUnwrapped,
}: let
  expectedSources = {
    "x86_64-linux" = {
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.810.41047_amd64.deb";
      hash = "sha256-eHFfo80Tb/ZwcNqnaBmtrsxbQumYUVWWWWRdzh+/KvM=";
    };
    "aarch64-linux" = {
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.810.41047_arm64.deb";
      hash = "sha256-mW95PKA5dnb8uc0AIRTJd1XMN0GQfEAPf13c9scMCk4=";
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

      if grep -E -i 'chromium|chatgpt\.com|--app=|--user-data-dir|chrome-chatgpt' "$launcher" "$desktop"; then
        echo "ASSERT FAIL: native ChatGPT package contains Chromium app-mode/profile launcher behavior" >&2
        exit 1
      fi

      touch "$out"
    ''
