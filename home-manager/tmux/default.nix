{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  zshPackage = config.programs.zsh.package or pkgs.zsh;
  defaultShell = "${zshPackage}/bin/zsh";
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
  # sysstat provides iostat (cpu plugin's preferred sampler — accurate 1s
  # delta vs. the ps-aux fallback's lifetime average). systemd provides
  # systemctl for the failed-units widget.
  statusBinPath = lib.makeBinPath (with pkgs; [bash coreutils gawk gnugrep gnused procps iproute2 sysstat systemd tmux util-linux]);
  # Wrap a script with (a) baked-in PATH, (b) a TTL cache + flock, so that
  # multiple tmux clients (each renders status independently) don't all run
  # the underlying script in parallel — one process computes per TTL window,
  # the rest serve cached output. Critical for net-speed, whose state file
  # would otherwise be raced by N clients and produce nonsense velocities.
  wrapStatusScript = name: ttl: target:
    pkgs.writeShellScript name ''
      export PATH="${statusBinPath}:$PATH"
      cache=/tmp/tmux-status-${name}.cache
      lock=/tmp/tmux-status-${name}.lock

      serve_if_fresh() {
        if [ -f "$cache" ]; then
          age=$(( $(date +%s) - $(stat -c %Y "$cache") ))
          if [ "$age" -lt ${toString ttl} ]; then
            cat "$cache"
            return 0
          fi
        fi
        return 1
      }

      serve_if_fresh && exit 0

      # Race for the right to recompute; losers serve stale cache rather than
      # piling on the underlying script.
      exec 9>"$lock"
      if ! flock -n 9; then
        [ -f "$cache" ] && cat "$cache"
        exit 0
      fi

      # We hold the lock — a peer may have refreshed while we waited.
      serve_if_fresh && exit 0

      ${target} > "$cache.tmp" && mv "$cache.tmp" "$cache"
      cat "$cache"
    '';
  mkInlineStatusScript = name: ttl: text:
    wrapStatusScript name ttl (pkgs.writeShellScript "${name}-impl" text);
  # TTL of 4s with status-interval=5s ensures exactly one recompute per tick:
  # the cache stays fresh through any in-tick re-render bursts (multi-client,
  # focus events, etc.) and goes stale just before the next scheduled tick.
  statusTtl = 4;
  netSpeedScript = wrapStatusScript "tmux-net-speed" statusTtl "${netSpeedPatched}/share/tmux-plugins/net-speed/scripts/net_speed.sh";
  cpuPercentageScript = wrapStatusScript "tmux-cpu-percentage" statusTtl "${pkgs.tmuxPlugins.cpu}/share/tmux-plugins/cpu/scripts/cpu_percentage.sh";
  ramPercentageScript = wrapStatusScript "tmux-ram-percentage" statusTtl "${pkgs.tmuxPlugins.cpu}/share/tmux-plugins/cpu/scripts/ram_percentage.sh";
  diskUsageScript = mkInlineStatusScript "tmux-disk-usage" statusTtl ''
    df --output=pcent / | tail -n 1 | tr -d ' '
  '';
  # When count > 0, emit the full catppuccin pill markup so tmux renders it;
  # when 0, output nothing so the pill disappears entirely.
  # `` is U+E0B6 (catppuccin "rounded" left separator), `󰀦` is the alert glyph.
  failedUnitsScript = mkInlineStatusScript "tmux-failed-units" statusTtl ''
    count=$(systemctl --failed --no-legend --plain --state=failed | wc -l)
    if [ "$count" -gt 0 ]; then
      printf '#[fg=#fab387]#[fg=#11111b,bg=#fab387]󰀦 #[fg=#cdd6f4,bg=#313244] %s#[fg=#313244] ' "$count"
    fi
  '';
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
        set -g status-interval 5
        set -g status-right-length 200
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

        # Disk usage on / — blue pill, harddisk
        set -ag status-right \
          "#[fg=#89b4fa]#{E:@catppuccin_status_left_separator}#[fg=#11111b,bg=#89b4fa]󰋊 #{E:@catppuccin_status_middle_separator}#[fg=#cdd6f4,bg=#313244] #(${diskUsageScript})#[fg=#313244]#{E:@catppuccin_status_right_separator}"

        # Failed systemd units — peach pill, alert. Script emits full pill
        # markup when count > 0 and nothing otherwise, so the pill disappears
        # entirely when there are no failures.
        set -ag status-right "#(${failedUnitsScript})"

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
