{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  zshPackage = config.programs.zsh.package or pkgs.zsh;
  defaultShell = "${zshPackage}/bin/zsh";
  # Remote link opening script for server side
  remoteLinkOpenScript = pkgs.writeScriptBin "remote-link-open" ''
    #!${pkgs.bash}/bin/bash
    # Open links on the client machine when running on a remote server

    set -euo pipefail

    if [ $# -eq 0 ]; then
      echo "Usage: remote-link-open <url>"
      exit 1
    fi

    URL="$1"

    # Check if we're in an SSH session
    if [ -z "''${SSH_CLIENT:-}" ]; then
      echo "Not in an SSH session, opening locally..."
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$URL"
      elif command -v open >/dev/null 2>&1; then
        open "$URL"
      else
        echo "No suitable browser opener found"
        exit 1
      fi
      exit 0
    fi

    # Get the client IP
    CLIENT_IP=$(echo $SSH_CLIENT | awk '{print $1}')

    # Use OSC 8 hyperlink sequence to send URL to client
    printf '\033]8;;%s\033\\Click to open: %s\033]8;;\033\\\n' "$URL" "$URL"

    echo "Sent link to client terminal: $URL"
  '';
  tmuxDevspaceHelper =
    pkgs.writeShellScriptBin "tmux-devspace" (builtins.readFile ./scripts/tmux-devspace.sh);
  # Orphan reaper: systemd user timer (10 min). PASS A kills sessions whose
  # session_activity > 48h. PASS B SIGKILLs processes that have TMUX= in env
  # but whose session leader (pane_pid) is gone — catches SIGHUP/SIGTERM-
  # ignoring children (wrangler, esbuild, …) that survived a closed pane.
  # Linux-only.
  tmuxOrphanReaper = pkgs.writeShellApplication {
    name = "tmux-orphan-reaper";
    runtimeInputs = with pkgs; [tmux psmisc procps systemd bash gnugrep coreutils iproute2 gawk];
    text = builtins.readFile ./scripts/tmux-orphan-reaper.sh;
  };
  netSpeedPatched = pkgs.tmuxPlugins.net-speed.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
        for f in scripts/*.sh *.sh; do
          [ -f "$f" ] && substituteInPlace "$f" --replace-quiet '#!/bin/bash' '#!${pkgs.bash}/bin/bash'
        done
      '';
  });
  # Status-bar widgets are rendered by tmux's `run-shell` (`#(...)`), which
  # inherits the tmux server process's PATH. Setting PATH on tmux.service only
  # works for *fresh* server starts; X-RestartIfChanged=false means an existing
  # server keeps whatever PATH it was originally launched with (often just
  # systemd's bin dir). Wrapping the plugin scripts here baked-in PATH means
  # the widgets work regardless of how the server got started or what its env
  # looks like.
  statusBinPath = lib.makeBinPath (with pkgs; [bash coreutils gawk gnugrep gnused procps iproute2 tmux]);
  wrapStatusScript = name: target:
    pkgs.writeShellScript name ''
      export PATH="${statusBinPath}:$PATH"
      exec ${target}
    '';
  netSpeedScript = wrapStatusScript "tmux-net-speed" "${netSpeedPatched}/share/tmux-plugins/net-speed/scripts/net_speed.sh";
  cpuPercentageScript = wrapStatusScript "tmux-cpu-percentage" "${pkgs.tmuxPlugins.cpu}/share/tmux-plugins/cpu/scripts/cpu_percentage.sh";
  ramPercentageScript = wrapStatusScript "tmux-ram-percentage" "${pkgs.tmuxPlugins.cpu}/share/tmux-plugins/cpu/scripts/ram_percentage.sh";
in {
  config = {
    programs.tmux = {
      enable = true;
      baseIndex = 1;
      historyLimit = 200000;
      keyMode = "vi";
      mouse = true;
      escapeTime = 0;
      terminal = "tmux-256color";

      plugins = with pkgs.tmuxPlugins; [
        sensible
        yank
        cpu
        netSpeedPatched
        {
          plugin = catppuccin;
          extraConfig = ''
            # Catppuccin settings
            set -g @catppuccin_flavor 'mocha'
            set -g @catppuccin_window_status_style "rounded"

            # Ensure transparent backgrounds where possible
            set -g status-bg default
            set -g message-style "fg=#94e2d5,bg=default"
            set -g message-command-style "fg=#94e2d5,bg=default"

            # Window settings
            set -g @catppuccin_window_left_separator ""
            set -g @catppuccin_window_right_separator " "
            set -g @catppuccin_window_middle_separator " █"
            set -g @catppuccin_window_number_position "right"

            set -g @catppuccin_window_default_fill "number"
            set -g @catppuccin_window_default_text "#{window_name}"

            set -g @catppuccin_window_current_fill "number"
            set -g @catppuccin_window_current_text "#{window_name}"
          '';
        }
      ];

      extraConfig = ''
        # Enable true color support
        set -ga terminal-overrides ",tmux-256color:Tc"
        set -ga terminal-overrides ",xterm-256color:Tc"
        set -ga terminal-overrides ",xterm-kitty:Tc"
        # Eternal Terminal presents itself as a screen(1) derivative, so make
        # sure tmux still drives it with truecolor sequences.
        set -ga terminal-overrides ",screen-256color:Tc"
        set -ga terminal-overrides ",screen:Tc"
        set -as terminal-features ",tmux-256color:RGB:sync"
        set -as terminal-features ",xterm-256color:RGB"
        set -as terminal-features ",xterm-kitty:RGB:sync"
        set -as terminal-features ",screen-256color:RGB"
        set -as terminal-features ",screen:RGB"

        # Ensure proper color rendering
        set -g default-terminal "tmux-256color"
        set -g default-shell "${defaultShell}"
        set -g default-command "${defaultShell} -l"
        set -ag terminal-overrides ",xterm*:RGB"
        set -ag terminal-overrides ",screen*:RGB"

        # Allow TUIs to detect terminal capabilities accurately
        set -ga update-environment "COLORTERM"
        set -ga update-environment "TERM_PROGRAM"
        set -ga update-environment "TERM_PROGRAM_VERSION"
        set -g allow-passthrough on
        set -g set-clipboard on

        # Keep server alive even when all sessions are destroyed
        set -g exit-empty off

        # General Settings
        setw -g pane-base-index 1
        set -g renumber-windows on
        set -g set-titles on
        set -g focus-events on
        set -g status-position bottom
        setw -g automatic-rename on
        setw -g allow-rename on
        set -g automatic-rename-format '#{pane_current_command}'

        # Terminal title: DEV_CONTEXT option (fallback to hostname) + command + compressed path
        set -g set-titles-string '#{?@dev_context,#{@dev_context},#H}*#{pane_current_command}*#(${tmuxDevspaceHelper}/bin/tmux-devspace title-path #{q:pane_current_path})'

        # Status line configuration
        set -g status-interval 30
        set -g status-right-length 100
        set -g status-left-length 100
        set -g status-left ""

        # Right side status with system monitoring
        set -g status-right \
          "#[fg=#94e2d5]#{E:@catppuccin_status_left_separator}#[fg=#11111b,bg=#94e2d5]󰈀  #{E:@catppuccin_status_middle_separator}#[fg=#cdd6f4,bg=#313244] #(${netSpeedScript})#[fg=#313244]#{E:@catppuccin_status_right_separator}"

        set -ag status-right \
          "#[fg=#f9e2af]#{E:@catppuccin_status_left_separator}#[fg=#11111b,bg=#f9e2af]#{E:@catppuccin_cpu_icon} #{E:@catppuccin_status_middle_separator}#[fg=#cdd6f4,bg=#313244] #(${cpuPercentageScript})#[fg=#313244]#{E:@catppuccin_status_right_separator}"

        set -g @catppuccin_ram_icon " "

        set -ag status-right \
          "#[fg=#cba6f7]#{E:@catppuccin_status_left_separator}#[fg=#11111b,bg=#cba6f7]  #{E:@catppuccin_status_middle_separator}#[fg=#cdd6f4,bg=#313244] #(${ramPercentageScript})#[fg=#313244]#{E:@catppuccin_status_right_separator}"

        # Pane borders - Catppuccin Mocha colors
        set -g pane-border-style "fg=#313244"
        set -g pane-active-border-style "fg=#89b4fa"

        # Window and pane styles - ensure no background is set
        set -g window-style 'default'
        set -g window-active-style 'default'

        # Key bindings
        unbind C-b
        set -g prefix C-a
        bind C-a send-prefix

        # Window/pane creation with current path
        bind c new-window -c "#{pane_current_path}"
        bind '"' split-window -c "#{pane_current_path}"
        bind % split-window -h -c "#{pane_current_path}"

        # Smart mouse wheel behavior - scroll alternate screen apps naturally
        bind -n WheelUpPane if -F "#{pane_in_mode}" "send-keys -M" "if -F '#{alternate_on}' 'send-keys -M' 'copy-mode -e; send-keys -M'"
        bind -n WheelDownPane if -F "#{pane_in_mode}" "send-keys -M" "send-keys -M"

        # Vim-style pane navigation
        bind h select-pane -L
        bind j select-pane -D
        bind k select-pane -U
        bind l select-pane -R

        # Quick window switching
        bind-key -n M-1 select-window -t 1
        bind-key -n M-2 select-window -t 2
        bind-key -n M-3 select-window -t 3
        bind-key -n M-4 select-window -t 4
        bind-key -n M-5 select-window -t 5
      '';
    };

    home.packages = with pkgs; [
      remoteLinkOpenScript
    ];

    # Set up environment for remote link opening
    home.sessionVariables = {
      BROWSER = "remote-link-open";
      DEFAULT_BROWSER = "remote-link-open";
    };

    # systemd user service to keep tmux server running (Linux only).
    # TMUX_TMPDIR=%t (= $XDG_RUNTIME_DIR) aligns the systemd-launched server's
    # socket path with the interactive shell's (home-manager exports the same
    # value via hm-session-vars.sh). Without this, the systemd server lands in
    # /tmp/tmux-UID/ and the shell server lands in /run/user/UID/tmux-UID/,
    # producing two parallel servers and an asymmetric view for the reaper.
    systemd.user.services.tmux = mkIf pkgs.stdenv.isLinux {
      Unit = {
        Description = "tmux server";
        # Never tear down a running tmux server during home-manager activation.
        # ExecStop runs `kill-server`, which terminates every session — so a
        # benign unit-definition change would kill the user's live work
        # (incident 2026-05-05: lost mars+mercury during `update`).
        X-RestartIfChanged = "false";
        X-StopIfChanged = "false";
        X-StopOnRemoval = "false";
      };
      Service = {
        Type = "forking";
        # PATH must include bash + standard utilities so plugin run-shell
        # scripts (e.g. catppuccin's `#!/usr/bin/env bash`) can find their
        # interpreter. systemd's default user PATH is just systemd's bin
        # dir, which broke the status bar render — `run-shell` returned 127
        # and the catppuccin plugin never sourced its theme files
        # (incident 2026-05-05: status bar reverted to default green).
        Environment = [
          "TMUX_TMPDIR=%t"
          "PATH=%h/.nix-profile/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
        ];
        ExecStart = "${pkgs.tmux}/bin/tmux new-session -d -s main";
        ExecStop = "${pkgs.tmux}/bin/tmux kill-server";
        Restart = "on-failure";
        RestartSec = "2s";
      };
      Install = {
        WantedBy = ["default.target"];
      };
    };

    # Orphan reaper: kills stale sessions (>48h idle) and orphans inside live
    # scopes. Two-pass design — see scripts/tmux-orphan-reaper.sh. Linux only.
    systemd.user.services.tmux-orphan-reaper = mkIf pkgs.stdenv.isLinux {
      Unit = {
        Description = "Reap orphans in tmux pane scopes; kill stale sessions";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${tmuxOrphanReaper}/bin/tmux-orphan-reaper";
      };
    };

    systemd.user.timers.tmux-orphan-reaper = mkIf pkgs.stdenv.isLinux {
      Unit = {
        Description = "Run tmux orphan reaper every 10 minutes";
      };
      Timer = {
        OnBootSec = "5min";
        OnUnitActiveSec = "10min";
        Unit = "tmux-orphan-reaper.service";
      };
      Install = {
        WantedBy = ["timers.target"];
      };
    };
  };
}
