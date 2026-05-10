{pkgs, ...}: {
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
}
