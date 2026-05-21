{
  pkgs,
  lib,
  ...
}: let
  # Forces silent session restore on every launch. Firefox on niri does not
  # reliably shut down cleanly: closing the window with Alt+Q (close-window →
  # xdg_toplevel.close) starts the quit, but the relaunch keybind
  # (focus-or-spawn) races it — the new `firefox` attaches to the still-dying
  # instance, aborting the session final-write so no clean sessionstore.jsonlz4
  # is produced. (Historically there was also a Wayland-disconnect MOZ_CRASH;
  # that class is gone since the niri 1 MiB wl_display buffer fix.) Either way
  # Firefox concludes it crashed and shows "Could not restore your previous
  # session" every start.
  #
  # browser.startup.page=3 makes SessionStartup take the RESUME_SESSION branch
  # *before* the crash/recover branch is evaluated (verified in
  # SessionStartup.sys.mjs), so recovery.jsonlz4 — rewritten every ~15s and
  # always current — is restored silently regardless of how the prior instance
  # died. It does not mask real crashes: the crash reporter (about:crashes /
  # Breakpad) is a separate subsystem.
  #
  # Delivered as user.js (local-only, never Sync'd) rather than
  # programs.firefox so the synced default profile stays the source of truth
  # (see the home.packages comment below).
  # ui.key.menuAccessKey=0 disables Firefox's Alt-as-menubar-accelerator.
  # Firefox ignores GTK's gtk-enable-mnemonics here (it implements its own
  # accel handling), so the GTK-wide knob in desktop-x86_64-linux.nix
  # doesn't cover Firefox. Setting the keycode to 0 means "no key" — neither
  # bare-Alt-release nor any Alt+letter focuses the menubar or activates
  # mnemonics. Matches the rationale documented over there: every Alt+letter
  # we reach for is a niri WM bind, so killing Firefox's grab is pure win.
  userJs = pkgs.writeText "firefox-user.js" ''
    // Managed by nix-config (home-manager/firefox/default.nix). Do not edit.
    user_pref("browser.startup.page", 3);
    user_pref("ui.key.menuAccessKey", 0);
  '';
in {
  # Tridactyl native messenger + tridactylrc.
  #
  # We deliberately do NOT use `programs.firefox` here. That module manages
  # `profiles.ini` and would replace the synced default profile with a fresh
  # HM-managed one — losing the bookmarks/history/extensions that already
  # live in Firefox Sync. The synced profile stays the source of truth;
  # this module just plugs in the bits that have to live outside it.
  #
  # Two declarative pieces:
  #
  # 1. tridactyl-native: a tiny stdio binary Tridactyl talks to over
  #    Mozilla's NativeMessaging API. Without it, Tridactyl can't read
  #    files from disk, so :source / :editor (Ctrl-I → external editor for
  #    textareas) / advanced commands are disabled. The JSON manifest at
  #    ~/.mozilla/native-messaging-hosts/tridactyl.json tells Firefox where
  #    to find the binary; it has to live in the user's home (not the
  #    system NixOS path) because regular pkgs.firefox isn't built with
  #    `nativeMessagingHosts` and so doesn't search /run/current-system.
  #
  # 2. tridactylrc at $XDG_CONFIG_HOME/tridactyl/tridactylrc — auto-sourced
  #    by Tridactyl on startup once the native messenger is in place.
  #
  # Tridactyl the *extension* itself is installed via Firefox Sync — same
  # as ublock, 1Password, etc. on this profile. Don't try to install it
  # via NUR here; that would force programs.firefox.profiles which we're
  # avoiding (see above).
  home.packages = [pkgs.tridactyl-native];

  home.file.".mozilla/native-messaging-hosts/tridactyl.json".source = "${pkgs.tridactyl-native}/lib/mozilla/native-messaging-hosts/tridactyl.json";

  xdg.configFile."tridactyl/tridactylrc".text = ''
    " Reset all settings to default. Without this, settings from previous
    " versions of tridactylrc / extension storage stick around silently.
    sanitise tridactyllocal tridactylsync

    " ── Hints ─────────────────────────────────────────────────────────
    " Home-row only — same letters as kitty's grab key set, so muscle
    " memory carries between terminal motions and link hinting.
    set hintchars asdfghjkl;

    " Filter hints by visible text as you type letters — much faster
    " disambiguation on dense pages (e.g. Google SERPs) than position-only.
    set hintfiltermode vimperator-reflow

    " ── Search ────────────────────────────────────────────────────────
    set searchengine google

    " ── Editor ────────────────────────────────────────────────────────
    " Ctrl-I in any textarea opens the contents in this command. The
    " native messenger writes the buffer to a temp file, runs the editor,
    " reads back. `kitty -e nvim` so the editor gets its own terminal
    " window instead of inheriting Firefox's invisible parent process.
    set editorcmd kitty -e nvim

    " ── Smooth scrolling ─────────────────────────────────────────────
    set smoothscroll true

    " ── Per-domain rules ──────────────────────────────────────────────
    " Sites that have their own keyboard navigation and would conflict
    " with Tridactyl's normal-mode bindings. `seturl` toggles Tridactyl's
    " mode for matching URLs; nokeys disables ALL Tridactyl keys.
    seturl ^https://mail\.google\.com mode ignore
    seturl ^https://app\.element\.io mode ignore
    seturl ^https://web\.whatsapp\.com mode ignore
    seturl ^https://discord\.com mode ignore
    seturl ^https://docs\.google\.com mode ignore

    " ── Theme ─────────────────────────────────────────────────────────
    " Built-in dark theme for hint labels, command bar, completions.
    " Tridactyl's hint labels are one of few UI elements that respect a
    " straight `colourscheme` — most others (the cmdline, completions)
    " ride along automatically.
    colourscheme dark
  '';

  # Resolve the active profile from profiles.ini (the synced profile name is
  # not knowable here) and drop user.js into it. Handles both ~/.mozilla and
  # the XDG (~/.config/mozilla) layout; prefers an [Install*] Default= entry,
  # else the [Profile*] with Default=1, else the first profile.
  home.activation.firefoxUserJs = lib.hm.dag.entryAfter ["writeBoundary"] ''
    firefoxRoot=""
    for d in "$HOME/.mozilla/firefox" "''${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox"; do
      if [ -f "$d/profiles.ini" ]; then firefoxRoot="$d"; break; fi
    done
    if [ -z "$firefoxRoot" ]; then
      echo "firefox user.js: no profiles.ini found — skipping" >&2
    else
      profilePath=$(${pkgs.gawk}/bin/awk '
        /^\[/        { isInstall = ($0 ~ /^\[Install/); isProfile = ($0 ~ /^\[Profile/); pdef = 0; ppath = "" }
        /^Default=/  { v = substr($0, 9);
                       if (isInstall) installDefault = v;
                       if (isProfile && v == "1") { pdef = 1; if (ppath != "") chosen = ppath } }
        /^Path=/     { v = substr($0, 6); ppath = v;
                       if (isProfile && pdef == 1) chosen = v;
                       if (firstPath == "") firstPath = v }
        END          { print (installDefault != "" ? installDefault : (chosen != "" ? chosen : firstPath)) }
      ' "$firefoxRoot/profiles.ini")
      case "$profilePath" in
        /*) profileDir="$profilePath" ;;
        *)  profileDir="$firefoxRoot/$profilePath" ;;
      esac
      if [ -n "$profilePath" ] && [ -d "$profileDir" ]; then
        $DRY_RUN_CMD install -m0644 ${userJs} "$profileDir/user.js"
      else
        echo "firefox user.js: profile dir not found (root=$firefoxRoot path=$profilePath) — skipping" >&2
      fi
    fi
  '';
}
