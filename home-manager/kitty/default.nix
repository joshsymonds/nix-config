{
  config,
  pkgs,
  ...
}: let
  # Mac-style command key: `mod` = `cmd` on macOS (the real Cmd key), `alt`
  # on Linux. On gnomon the keyd [kitty] app.conf swap makes the physical Cmd
  # key emit Alt inside kitty (Ctrl stays on the corner key for SIGINT/EOF,
  # Super is the Option key for niri), so the command key copies/pastes via
  # alt+. macOS keeps the real Cmd key. gnomon is the only interactive-kitty
  # Linux host; on headless Linux servers kitty is unused so the choice is
  # moot.
  mod =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "cmd"
    else "alt";
in {
  programs.kitty = {
    enable = true;

    font.name = "Maple Mono NF CN";
    font.size = 13;
    themeFile = "Catppuccin-Mocha";

    keybindings = {
      "kitty_mod" = "ctrl+shift";

      # Mac-style command-key shortcuts on `${mod}` (cmd on macOS, alt on
      # Linux — see the `mod` binding at the top). On gnomon the physical Cmd
      # key arrives as Alt inside kitty (keyd [kitty] swap), so these copy/
      # paste/tab on the command key; on macOS they use the real Cmd key.
      # Same finger, same result on both.
      #
      # Crucially absent: Ctrl+C / Ctrl+D are NOT bound — they stay raw to
      # the shell as SIGINT / EOF. On gnomon that is the corner key (which
      # the keyd [kitty] swap restores to Ctrl); on macOS it is the Control
      # key. Copy is the command key (${mod}+c), never Ctrl+C.
      "${mod}+c" = "copy_to_clipboard";
      "${mod}+v" = "paste_from_clipboard";
      "${mod}+t" = "new_tab";
      "${mod}+w" = "close_tab";
      "${mod}+n" = "new_os_window";
      "${mod}+1" = "goto_tab 1";
      "${mod}+2" = "goto_tab 2";
      "${mod}+3" = "goto_tab 3";
      "${mod}+4" = "goto_tab 4";
      "${mod}+5" = "goto_tab 5";
      "${mod}+6" = "goto_tab 6";
      "${mod}+7" = "goto_tab 7";
      "${mod}+8" = "goto_tab 8";
      "${mod}+9" = "goto_tab 9";
      "${mod}+shift+]" = "next_tab";
      "${mod}+shift+[" = "previous_tab";
      "${mod}+plus" = "change_font_size all +2.0";
      "${mod}+equal" = "change_font_size all +2.0";
      "${mod}+minus" = "change_font_size all -2.0";
      "${mod}+0" = "change_font_size all 0";
      "${mod}+k" = "clear_terminal scrollback active";
      "${mod}+f" = "show_scrollback";
      "${mod}+enter" = "no_op";
      "${mod}+shift+enter" = "no_op";

      # Also map Ctrl+V for paste in terminal apps (corner key on gnomon).
      "ctrl+v" = "paste_from_clipboard";

      # kitty_mod (= Ctrl+Shift) variants — Linux convention fallback.
      "kitty_mod+c" = "copy_to_clipboard";
      "kitty_mod+v" = "paste_from_clipboard";
      "kitty_mod+s" = "launch --type=overlay --cwd=current cursor -";
      "kitty_mod+l" = "clear_terminal scrollback active";
      "kitty_mod+t" = "new_tab";
      "kitty_mod+1" = "goto_tab 1";
      "kitty_mod+2" = "goto_tab 2";
      "kitty_mod+3" = "goto_tab 3";
      "kitty_mod+4" = "goto_tab 4";
      "kitty_mod+5" = "goto_tab 5";
      "kitty_mod+6" = "goto_tab 6";
      "kitty_mod+shift+]" = "next_tab";
      "kitty_mod+shift+[" = "previous_tab";
      "kitty_mod+h" = "show_scrollback";
      "kitty_mod+g" = "show_last_non_empty_command_output";
    };

    settings = {
      "cursor_trail" = 1;
      "cursor_trail_decay" = "0.1 0.4";
      "cursor_trail_start_threshold" = 2;
      "cursor_shape" = "block";
      "cursor_stop_blinking_after" = 0;
      "confirm_os_window_close" = 0;
      "scrollback_lines" = 10000;
      "enable_audio_bell" = false;
      "visual_bell_duration" = "0.1";
      "window_alert_on_bell" = true;
      "bell_on_tab" = true;
      "remember_window_size" = true;
      "enabled_layouts" = "Tall";
      "window_border_width" = "0.0";
      "draw_minimal_borders" = true;
      "window_margin_width" = "0.0";
      "window_padding_width" = "5.0";
      "inactive_text_alpha" = "0.8";
      "tab_bar_margin_width" = "0.0";
      "tab_bar_style" = "powerline";
      "tab_separator" = " ┇";
      "allow_remote_control" = true;
      "listen_on" = "unix:/tmp/kitty";
      "shell_integration" = "enabled";
      "clipboard_control" = "write-clipboard write-primary read-clipboard read-primary";
      "term" = "xterm-kitty";
      # SSH configuration
      "ssh_env" = "TERM=xterm-256color"; # Use compatible TERM for SSH
      # SSH clipboard integration
      "share_connections" = true;
      "remote_kitty" = "if-needed";
      # macOS clipboard integration
      "copy_on_select" = false; # Don't auto-copy on select
      "paste_actions" = "quote-urls-at-prompt";
      "strip_trailing_spaces" = "smart";
      "background_opacity" = "0.8";
      "sync_to_monitor" = true;
      "hide_window_decorations" = true;
      "scrollback_pager" = "moar --terminal-fg --wrap --no-statusbar --no-linenumbers --quit-if-one-screen +INPUT_LINE_NUMBER";
      "mouse_map ctrl+shift+right" = "press ungrabbed combine : mouse_select_command_output : show_last_visited_command_output";
      # Open URLs on plain left-click even when an app (tmux) has grabbed
      # the mouse. Default kitty restricts this to ungrabbed mode, so
      # clicks land on tmux which has no URL handler. `link`-only action
      # means non-URL clicks still pass through to tmux for selection /
      # pane focus.
      "mouse_map left click grabbed" = "mouse_handle_click link";
      "exe_search_path" = "/run/current-system/sw/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/opt/homebrew/bin";
      # Enable hyperlink handling
      "open_url_with" = "default";
      "detect_urls" = "yes";
      "url_prefixes" = "file ftp ftps gemini git gopher http https irc ircs kitty mailto news sftp ssh";
      "url_style" = "curly";
    };
  };
}
