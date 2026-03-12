{
  lib,
  config,
  pkgs,
  hostname ? null,
  ...
}: let
  isDarwin = hostname == "cloudbank" || hostname == "ninuan";
  autoAttachRemoteTmux = hostname != null && !isDarwin;
in {
  home.sessionVariables =
    {
      NIX_CONFIG = "experimental-features = nix-command flakes";
      ZVM_CURSOR_STYLE_ENABLED = "false";
      XL_SECRET_PROVIDER = "FILE";
      WINEDLLOVERRIDES = "d3dcompiler_47=n;d3d11=n,b";
    }
    // lib.optionalAttrs pkgs.stdenv.isLinux {
      PRISMA_SCHEMA_ENGINE_BINARY = "${pkgs.prisma-engines}/bin/schema-engine";
      PRISMA_QUERY_ENGINE_LIBRARY = "${pkgs.prisma-engines}/lib/libquery_engine.node";
      PRISMA_QUERY_ENGINE_BINARY = "${pkgs.prisma-engines}/bin/query-engine";
      PRISMA_FMT_BINARY = "${pkgs.prisma-engines}/bin/prisma-fmt";
    };

  xdg.configFile."zsh" = {
    source = ./zsh;
    recursive = true;
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    dotDir = "${config.xdg.configHome}/zsh";

    historySubstringSearch.enable = true;

    syntaxHighlighting.enable = true;

    autosuggestion.enable = true;

    shellAliases = {
      ll = "eza -a -F -l -B --git";
      ls = "ls --color=auto";
      agenix = "agenix -i ~/.config/agenix/keys.txt";
    };

    envExtra = ''
      # GPG agent needs this to find the terminal for pinentry
      export GPG_TTY=$(tty)

      # Only set LS_COLORS if vivid is available
      if command -v vivid &>/dev/null; then
        export LS_COLORS="$(vivid generate catppuccin-mocha)"
      fi

      # Source secrets file if it exists
      [ -f ~/.secrets ] && source ~/.secrets

      # Source local environment overrides (used by child container images)
      [ -f ~/.env.local ] && source ~/.env.local
    '';

    history = {
      size = 50000;
      save = 50000;
      path = "${config.xdg.dataHome}/zsh/history";
    };

    initContent = ''
      t() {
        if [[ $# -eq 0 ]]; then
          tmux-devspace new
          return
        fi

        if [[ "$1" == "--" ]]; then
          shift
          tmux-devspace new "$@"
          return
        fi

        if [[ "$1" == -* ]]; then
          tmux-devspace new "$@"
          return
        fi

        local label="$1"
        shift

        local icon_flag=""
        local icon_value=""
        if [[ $# -gt 0 && "$1" != "--" ]]; then
          icon_flag="--icon"
          icon_value="$1"
          shift
        fi

        if [[ $# -gt 0 && "$1" == "--" ]]; then
          shift
        fi

        if [[ $# -gt 0 ]]; then
          if [[ -n "$icon_flag" ]]; then
            tmux-devspace attach "$icon_flag" "$icon_value" "$label" -- "$@"
          else
            tmux-devspace attach "$label" -- "$@"
          fi
        else
          if [[ -n "$icon_flag" ]]; then
            tmux-devspace attach "$icon_flag" "$icon_value" "$label"
          else
            tmux-devspace attach "$label"
          fi
        fi
      }

      ${lib.optionalString autoAttachRemoteTmux ''
        # Auto-attach to tmux on remote hosts (managed by systemd user service)
        # No exec — shell survives if tmux dies, so kill-server is safe
        # -A: attach if main exists, create if not — no dependency on systemd pre-creating it
        if [[ $- == *i* ]] && [[ -z "''${TMUX:-}" ]] && [[ "''${NO_REMOTE_TMUX:-0}" != 1 ]]; then
          tmux new-session -A -s main
        fi
      ''}

      # Disable mouse reporting in shell when not in tmux
      # This prevents raw mouse escape sequences from appearing
      if [ -z "$TMUX" ] && [ -n "$SSH_TTY" ]; then
        printf '\e[?1000l'  # Disable mouse tracking
        printf '\e[?1002l'  # Disable cell motion tracking
        printf '\e[?1003l'  # Disable all motion tracking
        printf '\e[?1006l'  # Disable SGR extended mode
      fi

      # Import dev context metadata from tmux environment if we're in tmux
      if [ -n "$TMUX" ]; then
        TMUX_DEVSPACE=$(tmux show-environment TMUX_DEVSPACE 2>/dev/null | cut -d= -f2)
        if [ -n "$TMUX_DEVSPACE" ]; then
          export TMUX_DEVSPACE
        fi

        DEV_CONTEXT=$(tmux show-environment DEV_CONTEXT 2>/dev/null | cut -d= -f2)
        if [ -n "$DEV_CONTEXT" ]; then
          export DEV_CONTEXT
        fi

        DEV_CONTEXT_ICON=$(tmux show-environment DEV_CONTEXT_ICON 2>/dev/null | cut -d= -f2)
        if [ -n "$DEV_CONTEXT_ICON" ]; then
          export DEV_CONTEXT_ICON
        fi
      fi

      # Derive a unified dev context for prompts and titles
      if [ -n "''${CODER_WORKSPACE_NAME:-}" ]; then
        export DEV_CONTEXT="$CODER_WORKSPACE_NAME"
        : "''${DEV_CONTEXT_KIND:=coder}"
        export DEV_CONTEXT_KIND
      elif [ -n "''${TMUX_DEVSPACE:-}" ]; then
        export DEV_CONTEXT="$TMUX_DEVSPACE"
        : "''${DEV_CONTEXT_KIND:=tmux}"
        export DEV_CONTEXT_KIND
      else
        if [ -z "''${DEV_CONTEXT:-}" ]; then
          DEV_CONTEXT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
          export DEV_CONTEXT
          : "''${DEV_CONTEXT_KIND:=host}"
          export DEV_CONTEXT_KIND
        fi
      fi

      # SSH agent is now managed by systemd (Linux) or launchd (macOS)
      # Keys are automatically loaded by the ssh-agent service
      # Use 'ssh-add-git-keys' to manually reload keys if needed

      function set-title-precmd() {
        printf "\e]2;%s\a" "''${PWD/#$HOME/~}"
      }

      function set-title-preexec() {
        printf "\e]2;%s\a" "$1"
      }

      autoload -Uz add-zsh-hook
      add-zsh-hook precmd set-title-precmd
      add-zsh-hook preexec set-title-preexec

      function _tmux_devspace_autoname_precmd() {
        if [ -n "$TMUX" ] && [ "''${TMUX_AUTO_NAME:-0}" = "1" ] && command -v tmux-devspace >/dev/null 2>&1; then
          tmux-devspace rename >/dev/null 2>&1 || true
        fi
      }

      function _tmux_devspace_autoname_preexec() {
        if [ -n "$TMUX" ] && [ "''${TMUX_AUTO_NAME:-0}" = "1" ] && command -v tmux-devspace >/dev/null 2>&1; then
          tmux-devspace rename "$1" >/dev/null 2>&1 || true
        fi
      }

      add-zsh-hook precmd _tmux_devspace_autoname_precmd
      add-zsh-hook preexec _tmux_devspace_autoname_preexec

      # Ensure emacs mode (not vi mode)
      bindkey -e

      if [ -n "''${commands[fzf-share]}" ]; then
        source "$(fzf-share)/key-bindings.zsh"
        source "$(fzf-share)/completion.zsh"
      fi

      if type it &>/dev/null; then
        # Only source brew completions on macOS where brew is available
        if [[ "$(uname)" == "Darwin" ]] && type brew &>/dev/null; then
          source $(brew --prefix)/share/zsh/site-functions/_it
        fi
        eval "$(it wrapper)"
      fi

      export PATH=''${PATH}:''${HOME}/go/bin:''${HOME}/.local/share/../bin

      if [[ -z ''${EE_SYNCED-} && -x ''${HOME}/.local/bin/ee && -n ''${OP_SERVICE_ACCOUNT_TOKEN-} ]]; then
        "''${HOME}/.local/bin/ee" sync --quiet || true
        export EE_SYNCED=1
      fi

      # Start atuin daemon if not running (for containers without systemd)
      # Run in subshell to suppress job control messages
      if command -v atuin &>/dev/null && ! pgrep -x "atuin" &>/dev/null; then
        mkdir -p ~/.local/share/atuin
        (atuin daemon &>/dev/null &)
      fi

      cd ~
    '';
  };
}
