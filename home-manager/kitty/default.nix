{config, ...}: {
  programs.kitty = {
    enable = true;

    font.name = "Maple Mono NF CN";
    themeFile = "Catppuccin-Mocha";

    keybindings = {
      "kitty_mod" = "ctrl+shift";

      # Mac-style Cmd shortcuts. On macOS, kitty interprets `cmd` as the
      # actual Cmd key. On Linux, kitty interprets `cmd` as Super — and
      # on gnomon the keyd config has a `[kitty.main]` exception that
      # lets Super reach kitty raw (instead of being translated to Ctrl
      # as it is for every other app). Net effect: identical Cmd-key
      # muscle memory on both platforms.
      #
      # Crucially absent from this list: cmd+c is bound below (works on
      # both), but Ctrl+C is NOT bound — it stays raw to the shell as
      # SIGINT, same as Ctrl+D for EOF. That's the whole point of the
      # kitty exception in keyd.
      "cmd+c" = "copy_to_clipboard";
      "cmd+v" = "paste_from_clipboard";
      "cmd+t" = "new_tab";
      "cmd+w" = "close_tab";
      "cmd+n" = "new_os_window";
      "cmd+1" = "goto_tab 1";
      "cmd+2" = "goto_tab 2";
      "cmd+3" = "goto_tab 3";
      "cmd+4" = "goto_tab 4";
      "cmd+5" = "goto_tab 5";
      "cmd+6" = "goto_tab 6";
      "cmd+7" = "goto_tab 7";
      "cmd+8" = "goto_tab 8";
      "cmd+9" = "goto_tab 9";
      "cmd+shift+]" = "next_tab";
      "cmd+shift+[" = "previous_tab";
      "cmd+plus" = "change_font_size all +2.0";
      "cmd+equal" = "change_font_size all +2.0";
      "cmd+minus" = "change_font_size all -2.0";
      "cmd+0" = "change_font_size all 0";
      "cmd+k" = "clear_terminal scrollback active";
      "cmd+f" = "show_scrollback";
      "cmd+enter" = "no_op";
      "cmd+shift+enter" = "no_op";

      # Also map Ctrl+V for consistency in terminal apps
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
      "background_opacity" = "0.9";
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
