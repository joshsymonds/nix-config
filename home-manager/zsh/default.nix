{
  lib,
  config,
  pkgs,
  hostname ? null,
  ...
}: let
  isDarwin = pkgs.stdenv.isDarwin;
  autoAttachRemoteTmux = hostname != null && !isDarwin;

  # Pre-render shell-init scripts at Nix build time so each new zsh sources
  # an immutable /nix/store/.../*.zsh instead of forking the helper binary.
  # Cache is invalidated automatically because rebuilding with a new helper
  # version produces a new store path. brew shellenv is rendered at
  # activation time instead (see home.activation.cacheBrewShellenv) because
  # /opt/homebrew is unavailable in the Nix build sandbox.
  # atuin's `init zsh` touches $HOME to ensure a config dir exists; the Nix
  # sandbox sets $HOME=/homeless-shelter which is read-only. Give helpers a
  # throwaway HOME so they don't crash on first run.
  preRender = name: cmd:
    pkgs.runCommand "${name}.zsh" {} ''
      export HOME=$(mktemp -d)
      ${cmd} > $out
    '';
  starshipInit = preRender "starship-init" "${config.programs.starship.package}/bin/starship init zsh";
  atuinInit = preRender "atuin-init" "${config.programs.atuin.package}/bin/atuin init zsh";
  direnvInit = preRender "direnv-init" "${config.programs.direnv.package}/bin/direnv hook zsh";
  zoxideInit = preRender "zoxide-init" "${config.programs.zoxide.package}/bin/zoxide init zsh";
  rbenvBin = "${config.programs.rbenv.package}/bin/rbenv";
  brewShellenvCache = "${config.xdg.cacheHome}/zsh/brew-shellenv.zsh";

  # ── Work-profile LLM backend toggle ────────────────────────────────────
  # ~/.claude-work is a SINGLE config dir; its backend (AWS Bedrock vs the
  # Anthropic OAuth account) is a runtime mode persisted in
  # ~/.claude-work/.backend (default "bedrock"). The launch env below is
  # exported by the claude()/cw/cwa wrappers and INHERITED by the bg-agent
  # daemon + every spare worker — verified that workers never re-read
  # settings.json, they freeze the launch env (a daemon left up across a
  # 4-7->4-8 bump kept serving 4-7). So flipping backend means: rewrite the
  # frozen --model baked into each job's respawnFlags, then bounce the
  # daemon. `cwswitch` does both. cm/cw/cwa are the explicit overrides.
  #
  # bedrock<->anthropic model equivalents (the only backend-specific bit in
  # a job) live in an agenix secret: JSON of tier -> {anthropic, bedrock}
  # with tiers fable/opus/sonnet/haiku. The bedrock side is my per-user
  # application-inference-profile ARNs (cost governance: the us.*/global.*
  # system profiles are denied per principal). The ARNs embed the Attain
  # AWS account id and this repo is public, so they are never written into
  # the repo or the nix store — the launch wrapper and cwswitch read the
  # decrypted file at runtime. The secret stores BARE ids/ARNs; the [1m]
  # suffix (client-side 1M-context hint, stripped before the request) is
  # applied in code. haiku has no 1M variant. us-east-2 is where the attain
  # account's profiles live. In anthropic mode NONE of the backend env is
  # exported, so Claude Code falls back to the OAuth account's normal model
  # selection.
  bedrockModelsFile = config.age.secrets."claude-bedrock-models".path;

  cwswitch = pkgs.writeShellApplication {
    name = "cwswitch";
    runtimeInputs = [pkgs.jq pkgs.coreutils pkgs.procps config.programs.claudeCode.cwrenderPackage];
    text = ''
      # Flip the ~/.claude-work LLM backend between Bedrock and the Anthropic
      # OAuth account. Rewrites the frozen --model in every job's
      # respawnFlags, persists the new mode, re-renders the work profile's
      # settings.json via cwrender (spare workers get a scrubbed env and read
      # their backend from settings.json's env block — see the cwrender
      # comment in home-manager/claude-code), and bounces the bg-agent daemon
      # so new/resumed workers pick up the new backend.
      work="$HOME/.claude-work"
      pointer="$work/.backend"
      jobs="$work/jobs"

      # Model maps come from the agenix secret at runtime (bare ids/ARNs;
      # any [1m] suffix on a job's --model is preserved across the flip).
      # Double quotes: the agenix path contains a literal ''${XDG_RUNTIME_DIR}
      # that must expand at runtime.
      models_file="${bedrockModelsFile}"
      if [ ! -r "$models_file" ]; then
        echo "cwswitch: model map $models_file unreadable — is the claude-bedrock-models agenix secret deployed?" >&2
        exit 1
      fi
      to_anthropic=$(jq -c '[.[] | {key: .bedrock, value: .anthropic}] | from_entries' "$models_file")
      to_bedrock=$(jq -c '[.[] | {key: .anthropic, value: .bedrock}] | from_entries' "$models_file")

      cur=bedrock
      [ -f "$pointer" ] && cur=$(tr -d '[:space:]' < "$pointer")
      [ -n "$cur" ] || cur=bedrock

      target=''${1:-}
      if [ -z "$target" ]; then
        if [ "$cur" = bedrock ]; then target=anthropic; else target=bedrock; fi
      fi
      case "$target" in
        bedrock | anthropic) ;;
        *)
          echo "usage: cwswitch [bedrock|anthropic]   (no arg toggles)" >&2
          exit 2
          ;;
      esac

      # Same-target runs still do the job-rewrite loop below (repair mode):
      # a job created while the launch env disagreed with the pointer keeps
      # a frozen --model from the wrong backend, and skipping here would
      # strand it forever. Only the daemon bounce is conditional on an
      # actual backend change.
      repair=no
      [ "$target" = "$cur" ] && repair=yes

      if [ "$target" = anthropic ]; then map=$to_anthropic; else map=$to_bedrock; fi

      changed=0
      unknown=0
      active=0
      if [ -d "$jobs" ]; then
        for sj in "$jobs"/*/state.json; do
          [ -f "$sj" ] || continue
          if grep -q '"state": *"working"' "$sj"; then active=$((active + 1)); fi
          # Warn (don't mangle) on any --model value we don't recognise
          # (lookup is on the base id, with any [1m] suffix stripped).
          # Known = a key of either direction's map: source-side ids get
          # rewritten, target-side ids are already correct — only ids from
          # neither backend are truly unknown.
          while IFS= read -r m; do
            [ -n "$m" ] || continue
            base=''${m%"[1m]"}
            if ! printf '%s%s' "$to_anthropic" "$to_bedrock" | jq -e -s --arg k "$base" 'any(has($k))' >/dev/null 2>&1; then
              echo "warn: $(basename "$(dirname "$sj")"): unrecognised model '$m' left unchanged" >&2
              unknown=$((unknown + 1))
            fi
          done < <(jq -r '.respawnFlags as $f | range(1;($f|length)) | select($f[.-1]=="--model") | $f[.]' "$sj" 2>/dev/null || true)

          tmp="$sj.cwswitch.$$"
          if jq --argjson m "$map" '
            .respawnFlags |= ( . as $f | [ range(0;length) | . as $i |
              if $i > 0 and $f[$i-1] == "--model"
              then ( $f[$i] as $v
                   | ($v | sub("\\[1m\\]$"; "")) as $base
                   | (if ($v | endswith("[1m]")) then "[1m]" else "" end) as $sfx
                   | if $m[$base] != null then ($m[$base] + $sfx) else $v end )
              else $f[$i] end ] )
          ' "$sj" > "$tmp" 2>/dev/null; then
            # Count only real model changes: cmp on whole files would count
            # jq's whitespace re-serialization as a rewrite.
            before=$(jq -c '[.respawnFlags as $f | range(1;($f|length)) | select($f[.-1]=="--model") | $f[.]]' "$sj" 2>/dev/null || echo '[]')
            after=$(jq -c '[.respawnFlags as $f | range(1;($f|length)) | select($f[.-1]=="--model") | $f[.]]' "$tmp" 2>/dev/null || echo '[]')
            [ "$before" = "$after" ] || changed=$((changed + 1))
            mv "$tmp" "$sj"
          else
            rm -f "$tmp"
            echo "warn: failed to rewrite $sj — left unchanged" >&2
          fi
        done
      fi

      printf '%s\n' "$target" > "$pointer.$$" && mv "$pointer.$$" "$pointer"

      # Re-render settings.json for the (possibly unchanged) backend: spare
      # workers read their backend env from here at spawn, so repair mode
      # re-renders too — a stale render is exactly the strand this fixes.
      cwrender

      # Repair mode: backend unchanged, so the daemon's inherited env is
      # already correct — bounce nothing. Workers pick up rewritten
      # respawnFlags on their next respawn regardless.
      bounced=no
      if [ "$repair" = no ]; then
        if [ "$active" != 0 ]; then
          echo "note: $active work agent(s) were 'working'; the daemon bounce stops them — pause+resume to migrate them onto $target." >&2
        fi
        status="$work/daemon.status.json"
        if [ -f "$status" ]; then
          pid=$(jq -r '.supervisorPid // empty' "$status" 2>/dev/null || true)
          if [ -n "''${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            pkill -TERM -P "$pid" 2>/dev/null || true
            kill -TERM "$pid" 2>/dev/null || true
            bounced=yes
          fi
        fi
      fi

      if [ "$repair" = yes ]; then
        echo "work backend already '$target' — repaired stranded jobs instead  (jobs rewritten: $changed, unknown left: $unknown)"
      else
        echo "work backend: $cur -> $target  (jobs rewritten: $changed, unknown left: $unknown, daemon bounced: $bounced)"
        echo "next: run 'claude agents' in a work dir and resume workers — they respawn on $target."
      fi
    '';
  };
in {
  # tier -> {anthropic, bedrock} model map for the claude-work Bedrock
  # backend. Encrypted because the bedrock side is application-inference-
  # profile ARNs embedding the Attain AWS account id, and this repo is
  # public.
  age.secrets."claude-bedrock-models" = {
    file = ../../secrets/user/claude-bedrock-models.age;
  };

  home.packages = [cwswitch];

  home.sessionVariables =
    {
      NIX_CONFIG = "experimental-features = nix-command flakes";
      ZVM_CURSOR_STYLE_ENABLED = "false";
      XL_SECRET_PROVIDER = "FILE";
      WINEDLLOVERRIDES = "d3dcompiler_47=n;d3d11=n,b";
      # fd-backed fzf file search (Ctrl-T and the default `**`-completion
      # source). Written out identically in both vars rather than having
      # one reference the other — home.sessionVariables' export order isn't
      # guaranteed to put FZF_DEFAULT_COMMAND before FZF_CTRL_T_COMMAND.
      FZF_DEFAULT_COMMAND = "fd --type f --strip-cwd-prefix --hidden --exclude .git";
      FZF_CTRL_T_COMMAND = "fd --type f --strip-cwd-prefix --hidden --exclude .git";
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
    # Skip compaudit (saves ~50ms per shell). fpath is Nix-managed, so the
    # security check it would perform is moot.
    completionInit = ''
      autoload -Uz compinit
      compinit -C -d ''${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump
    '';
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
      ${lib.optionalString isDarwin ''
        # Homebrew on Apple Silicon (cached output, regenerated by home-manager activation)
        [ -r "${brewShellenvCache}" ] && source "${brewShellenvCache}"
      ''}

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
      # Claude Code profile selection. Walks $PWD upward looking for a
      # .claude-work marker file; if found, launches the work profile
      # (~/.claude-work) on whichever backend ~/.claude-work/.backend names
      # (default bedrock). Otherwise passes through untouched, letting
      # claude use its default personal profile (~/.claude).
      #
      # The backend env is exported here at launch and inherited by the
      # bg-agent daemon + spare workers; `cwswitch` flips it (and bounces
      # the daemon). See the workBackend block in this module's `let`.
      __cc_work() {
        emulate -L zsh
        local mode=bedrock
        [[ -r $HOME/.claude-work/.backend ]] && mode=$(<$HOME/.claude-work/.backend)
        local -a pfx=( CLAUDE_CONFIG_DIR=$HOME/.claude-work )
        if [[ $mode == bedrock ]]; then
          # ARNs come from the agenix secret at launch (see the workBackend
          # block in this module's `let`). Fable is the primary; [1m] is the
          # client-side 1M-context hint (haiku has no 1M variant).
          local models="${bedrockModelsFile}"
          if [[ -r $models ]]; then
            local fable opus sonnet haiku
            IFS=$'\t' read -r fable opus sonnet haiku < <(
              jq -r '[.fable.bedrock, .opus.bedrock, .sonnet.bedrock, .haiku.bedrock] | @tsv' "$models"
            )
            pfx+=(
              CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-2 AWS_PROFILE=attain
              ANTHROPIC_MODEL="''${fable}[1m]"
              ANTHROPIC_DEFAULT_FABLE_MODEL="''${fable}[1m]"
              ANTHROPIC_DEFAULT_OPUS_MODEL="''${opus}[1m]"
              ANTHROPIC_DEFAULT_SONNET_MODEL="''${sonnet}[1m]"
              ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku"
            )
          else
            print -u2 "claude-work: $models unreadable (claude-bedrock-models agenix secret not deployed?) — launching WITHOUT Bedrock env; this session will use the Anthropic OAuth backend despite .backend=bedrock."
          fi
        fi
        command env "''${pfx[@]}" claude "$@"
      }
      claude() {
        emulate -L zsh
        local dir=$PWD
        while [[ $dir != / ]]; do
          if [[ -f $dir/.claude-work ]]; then
            __cc_work "$@"
            return
          fi
          dir=''${dir:h}
        done
        command claude "$@"
      }

      # Explicit profile overrides. cw/cwa also SET the persistent work
      # backend (bouncing the daemon on change, via cwswitch) so they double
      # as the toggle, then launch the work profile regardless of $PWD. `cm`
      # uses a subshell to scope the unset — personal prefs live at
      # ~/.claude.json (at $HOME), so the default (CLAUDE_CONFIG_DIR unset)
      # is what we need.
      cw() { cwswitch bedrock && __cc_work "$@" }
      cwa() { cwswitch anthropic && __cc_work "$@" }
      cm() { ( unset CLAUDE_CONFIG_DIR && command claude "$@" ) }

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
        # Auto-attach to tmux ONLY when this shell was started by an
        # incoming SSH connection — i.e. someone SSH'd into this host and
        # we want them dropped into the long-lived `main` session managed
        # by the systemd tmux user service. Local terminal emulators
        # (kitty, etc.) get a plain zsh and use the emulator's own tabs
        # for multiplexing.
        # No exec — shell survives if tmux dies, so kill-server is safe.
        # -A: attach if main exists, create if not — no dependency on systemd pre-creating it.
        if [[ $- == *i* ]] && [[ -z "''${TMUX:-}" ]] && [[ -n "''${SSH_CONNECTION:-}" ]] && [[ "''${NO_REMOTE_TMUX:-0}" != 1 ]]; then
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

      # rbenv lazy-load: defer the ~140ms init until first ruby/rbenv command.
      # On first call, the stub unfunctions itself, runs the real init, then
      # re-execs the originally-typed command via the now-installed shim.
      __rbenv_init() {
        unfunction rbenv ruby gem bundle 2>/dev/null
        eval "$(${rbenvBin} init - zsh)"
      }
      rbenv()  { __rbenv_init; rbenv  "$@"; }
      ruby()   { __rbenv_init; ruby   "$@"; }
      gem()    { __rbenv_init; gem    "$@"; }
      bundle() { __rbenv_init; bundle "$@"; }

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

      ${lib.optionalString (!isDarwin) ''
        # Start atuin daemon if not running (for containers without systemd).
        # macOS uses launchd, so this fallback is gated to Linux.
        if command -v atuin &>/dev/null && ! pgrep -x "atuin" &>/dev/null; then
          mkdir -p ~/.local/share/atuin
          (atuin daemon &>/dev/null &)
        fi
      ''}

      # Pre-rendered helper inits (replace enableZshIntegration auto-evals).
      # Sourced last so atuin's Ctrl-R binding wins over fzf-history-widget,
      # matching the original auto-eval ordering at the bottom of zshrc.
      source ${starshipInit}
      source ${atuinInit}
      source ${direnvInit}
      source ${zoxideInit}
    '';
  };

  # Cache `brew shellenv` output once per home-manager activation. Cannot use
  # pkgs.runCommand here because /opt/homebrew is unreachable from the Nix
  # build sandbox; activation runs with the real $HOME and PATH.
  home.activation.cacheBrewShellenv = lib.mkIf isDarwin (lib.hm.dag.entryAfter ["writeBoundary"] ''
    if [ -x /opt/homebrew/bin/brew ]; then
      run mkdir -p "$(dirname "${brewShellenvCache}")"
      run /opt/homebrew/bin/brew shellenv > "${brewShellenvCache}"
    fi
  '');
}
