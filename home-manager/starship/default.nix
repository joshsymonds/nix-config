{pkgs, ...}: {
  programs.starship = {
    package = pkgs.starship;
    enable = true;
    # Disabled: init script is pre-rendered at build time and sourced from
    # home-manager/zsh/default.nix. See preRender helper there.
    enableZshIntegration = false;

    settings = {
      palette = "catppuccin_mocha";

      format = "[](fg:lavender)$directory$character";

      # Right side: devspace? | host | git | aws? | gcloud? | k8s? | curve.
      # Static-color chips (devspace, host, git) use built-in starship
      # styling. Dynamic-color chips (aws, gcloud, k8s) are rendered as a
      # single block by `steward render-clouds`, which emits raw ANSI
      # including its own internal powerline chevrons and the closing
      # right curve.
      right_format = "[](fg:mauve)\${custom.context}[](fg:rosewater bg:mauve)\${custom.host}[](fg:sky bg:rosewater)$git_branch$git_status\${custom.clouds}";

      add_newline = false;

      "line_break" = {
        disabled = true;
      };

      fill = {
        disabled = true;
      };

      directory = {
        style = "bg:lavender fg:base";
        format = "[ $path ]($style)";

        # Match Steward's formatPath: keep first segment (~ or /), last
        # two full, middle replaced with …. Starship's truncation_length
        # is the count of TRAILING segments to keep (last N), and
        # truncation_symbol prepends when truncation occurred.
        truncation_length = 2;
        truncation_symbol = "…/";
        truncate_to_repo = false;
      };

      character = {
        success_symbol = "[](bg:green fg:lavender)[](fg:green)";
        error_symbol = "[](bg:red fg:lavender)[](fg:red)";
      };

      "cmd_duration" = {
        style = "bg:mauve fg:base";
        format = "[ $duration ]($style)";
      };

      "git_branch" = {
        style = "bg:sky fg:base";
        format = "[ $symbol$branch ]($style)";
      };

      "git_status" = {
        style = "bg:sky fg:base";
        format = "[$all_status$ahead_behind ]($style)";
      };

      # Built-in aws/kubernetes modules are intentionally NOT configured.
      # Their output is replaced by `custom.clouds` below, which calls
      # `steward render-clouds` for a single ANSI block that matches the
      # Claude Code statusline byte-for-byte. (Disabling them explicitly
      # prevents accidental fallback rendering.)
      aws = {
        disabled = true;
      };
      kubernetes = {
        disabled = true;
      };

      custom = {
        context = {
          when = ''test -n "$CODER_WORKSPACE_NAME" || test -n "$DEV_CONTEXT"'';
          # Mirror Steward's devspace rule: known planet names truncate
          # to 3 chars (the glyph carries identity); arbitrary names
          # (Coder workspaces, custom devspaces) keep their full text
          # since the name IS the identifier.
          command = ''
            shorten() {
              case "$1" in
                mercury|venus|earth|mars|jupiter)
                  printf '%s' "$1" | cut -c1-3
                  ;;
                *)
                  printf '%s' "$1"
                  ;;
              esac
            }
            if [ -n "$CODER_WORKSPACE_NAME" ]; then
              icon="''${DEV_CONTEXT_ICON:-}"
              printf " %s %s" "$icon" "$CODER_WORKSPACE_NAME"
            elif [ -n "$DEV_CONTEXT" ]; then
              name="$(shorten "$DEV_CONTEXT")"
              if [ -n "$DEV_CONTEXT_ICON" ]; then
                printf " %s %s" "$DEV_CONTEXT_ICON" "$name"
              else
                printf " ● %s" "$name"
              fi
            fi
          '';
          format = "[ $output ]($style)";
          style = "bg:mauve fg:base bold";
        };

        # Host chip: 2-char alias from the shared statusline-aliases
        # table. Falls back to the raw short hostname when no alias exists.
        # Always bg=rosewater (the adjacency invariant rules out per-host
        # tinting). Sources hostname from $HOSTNAME, then $CODER_AGENT_URL
        # (for Coder workspaces), then `hostname -s`.
        host = {
          when = ''true'';
          command = ''
            host=""
            if [ -n "$CODER_WORKSPACE_NAME" ] && [ -n "$CODER_AGENT_URL" ]; then
              host="$(printf '%s' "$CODER_AGENT_URL" | sed -e 's|^[^:]*://||' -e 's|/.*$||')"
            elif [ -n "$HOSTNAME" ]; then
              host="$HOSTNAME"
            else
              host="$(hostname -s 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || printf "")"
            fi
            if [ -n "$host" ]; then
              label="$(steward resolve --type=host --raw="$host" 2>/dev/null | awk -F '\t' '{print $1}')"
              [ -z "$label" ] && label="$host"
              printf " 󰒋 %s" "$label"
            fi
          '';
          format = "[ $output ]($style)";
          style = "bg:rosewater fg:base";
        };

        # Cloud section: aws + gcloud + k8s chips, rendered as a single
        # raw-ANSI block. The leading chevron transitions from sky (git's
        # color); the trailing right curve seals the prompt. Steward owns
        # the resolution logic and chevron drawing, so this stays in lockstep
        # with the Claude Code statusline.
        clouds = {
          when = ''true'';
          command = ''steward render-clouds 2>/dev/null'';
          format = "$output";
          style = "";
        };
      };

      palettes.catppuccin_mocha = {
        rosewater = "#f5e0dc";
        flamingo = "#f2cdcd";
        pink = "#f5c2e7";
        mauve = "#cba6f7";
        red = "#f38ba8";
        maroon = "#eba0ac";
        peach = "#fab387";
        yellow = "#f9e2af";
        green = "#a6e3a1";
        teal = "#94e2d5";
        sky = "#89dceb";
        sapphire = "#74c7ec";
        blue = "#89b4fa";
        lavender = "#b4befe";
        text = "#cdd6f4";
        subtext1 = "#bac2de";
        subtext0 = "#a6adc8";
        overlay2 = "#9399b2";
        overlay1 = "#7f849c";
        overlay0 = "#6c7086";
        surface2 = "#585b70";
        surface1 = "#45475a";
        surface0 = "#313244";
        base = "#1e1e2e";
        mantle = "#181825";
        crust = "#11111b";
      };
    };
  };
}
