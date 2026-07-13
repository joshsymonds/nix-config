{
  pkgs,
  chatgptDesktop,
}: let
  expectedIcon = pkgs.fetchurl {
    url = "https://images.ctfassets.net/j22is2dtoxu1/intercom-img-d177d076c9a5453052925143/49d5d812b0a6fcc20a14faa8c629d9fb/icon-ios-1024_401x.png";
    hash = "sha256-55ni+g1BSaLsKPxZXIv7SZC8u0eGSXkbQqz/fN5ugF4=";
  };
in
  pkgs.runCommand "chatgpt-desktop-check" {
    nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.gnugrep];
  } ''
    set -euo pipefail

    launcher=${chatgptDesktop}/bin/chatgpt
    desktop=${chatgptDesktop}/share/applications/chatgpt.desktop
    icon=${chatgptDesktop}/share/icons/hicolor/1024x1024/apps/chatgpt.png

    if ! test -x "$launcher"; then
      echo "ASSERT FAIL: missing executable $launcher" >&2
      exit 1
    fi
    test -f "$desktop"
    if ! test -s "$icon"; then
      echo "ASSERT FAIL: missing icon $icon" >&2
      exit 1
    fi

    grep -F -- '${pkgs.chromium}/bin/chromium' "$launcher"
    grep -F -- '--app=https://chatgpt.com/' "$launcher"
    grep -F -- '--class=chatgpt' "$launcher"
    grep -F -- '--no-first-run' "$launcher"
    grep -F -- '--no-default-browser-check' "$launcher"
    if grep -F -- '--disable-blink-features=ScrollAnchoring' "$launcher"; then
      echo "ASSERT FAIL: launcher contains unsupported ScrollAnchoring flag" >&2
      exit 1
    fi
    grep -F -- 'profile_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/chatgpt-desktop"' "$launcher"
    if ! grep -F -- '${pkgs.coreutils}/bin/mkdir -p "$profile_dir"' "$launcher"; then
      echo "ASSERT FAIL: launcher does not reference ${pkgs.coreutils}/bin/mkdir" >&2
      exit 1
    fi
    grep -F -- '--user-data-dir="$profile_dir"' "$launcher"

    grep -Fx 'Name=ChatGPT' "$desktop"
    grep -Fx 'StartupWMClass=chatgpt' "$desktop"
    desktop_exec="$(sed -n 's/^Exec=//p' "$desktop")"
    test -x "$desktop_exec"
    test "$(readlink -f "$desktop_exec")" = "$(readlink -f "$launcher")"

    cmp ${expectedIcon} "$icon"

    test ! -e ${chatgptDesktop}/bin/codex-desktop
    test ! -e ${chatgptDesktop}/share/applications/codex-desktop.desktop
    residue_path="$(find -L ${chatgptDesktop} \( -iname '*codex*' -o -iname '*updat*' \) -print -quit)"
    if test -n "$residue_path"; then
      echo "ASSERT FAIL: ChatGPT wrapper contains residue path $residue_path" >&2
      exit 1
    fi
    if grep -RiE 'codex|update(r|s|check)' ${chatgptDesktop}; then
      echo "ASSERT FAIL: ChatGPT wrapper contains Codex or updater residue" >&2
      exit 1
    fi

    touch "$out"
  ''
