# gemini-web: the desktop entry must match the Wayland app_id Chromium
# reports for the launched --app window, or focus-or-spawn (Mod+B in niri)
# launches a second window on every press instead of focusing the first.
# The launcher runs against a stub chromium that records its argv.
{pkgs}: let
  fakeChromium = pkgs.writeShellScriptBin "chromium" ''
    printf '%s\n' "$@" > "$ARGV_OUT"
  '';
  geminiWeb = pkgs.callPackage ../pkgs/gemini-web {chromium = fakeChromium;};
in
  pkgs.runCommand "gemini-web-check" {
    nativeBuildInputs = [pkgs.gnugrep];
  } ''
    set -euo pipefail

    desktop=${geminiWeb}/share/applications/gemini-web.desktop
    launcher=${geminiWeb}/bin/gemini-web

    test -x "$launcher"
    test -s ${geminiWeb}/share/icons/hicolor/512x512/apps/gemini-web.png

    # Observed under headless sway for --app=https://gemini.google.com/app.
    grep -Fx 'StartupWMClass=chrome-gemini.google.com__app-Default' "$desktop"
    test "${geminiWeb.appId}" = chrome-gemini.google.com__app-Default
    grep -Fx 'Exec=gemini-web' "$desktop"
    grep -Fx 'Icon=gemini-web' "$desktop"
    grep -Fx 'Name=Gemini' "$desktop"

    export ARGV_OUT="$TMPDIR/argv"

    HOME=/home/test XDG_DATA_HOME=/data "$launcher" --extra
    grep -Fx -- '--app=https://gemini.google.com/app' "$ARGV_OUT"
    grep -Fx -- '--user-data-dir=/data/gemini-web' "$ARGV_OUT"
    grep -Fx -- '--ozone-platform-hint=auto' "$ARGV_OUT"
    # Chromium flags this as unsupported with a warning bar on every launch.
    if grep -F -- '--disable-blink-features' "$ARGV_OUT"; then
      echo "ASSERT FAIL: launcher passes --disable-blink-features" >&2
      exit 1
    fi
    grep -Fx -- '--no-first-run' "$ARGV_OUT"
    test "$(tail -n1 "$ARGV_OUT")" = --extra

    (unset XDG_DATA_HOME; HOME=/home/test "$launcher")
    grep -Fx -- '--user-data-dir=/home/test/.local/share/gemini-web' "$ARGV_OUT"

    touch "$out"
  ''
