{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  # Get cc-tools binaries from the flake
  cc-tools = inputs.cc-tools.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  age.secrets."ntfy-url" = {
    file = ../../secrets/user/ntfy-url.age;
  };

  home = {
    # Install Node.js to enable npm
    packages =
      (with pkgs; [
        nodejs_24
        # Dependencies for hooks and wrappers
        yq
        jq
        ripgrep
        # Include cc-tools binaries
        cc-tools
      ])
      ++ [pkgs.claudeCodeCli];

    # Add npm global bin to PATH for user-installed packages
    sessionPath = lib.mkAfter [
      "$HOME/.npm-global/bin"
    ];

    # Set npm prefix to user directory and cc-tools socket path
    sessionVariables = {
      NPM_CONFIG_PREFIX = "$HOME/.npm-global";
      CC_TOOLS_SOCKET = "/run/user/\${UID}/cc-tools.sock";
      CLAUDE_CODE_ENABLE_TASKS = "true";
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
      CLAUDE_CODE_NO_FLICKER = "1";
      CLAUDE_CODE_TMUX_TRUECOLOR = "1";
      CLAUDE_HOOKS_NTFY_URL_FILE = config.age.secrets."ntfy-url".path;
      # The only reliable way to disable auto-updates for native installs.
      # settings.json autoUpdater.disabled is cosmetic; ~/.claude.json autoUpdates
      # is bypassed by autoUpdatesProtectedForNative for native installMethod.
      DISABLE_AUTOUPDATER = "1";
    };

    # Create and manage Claude Code config directories.
    # Both ~/.claude (personal, default) and ~/.claude-work (Enterprise) receive
    # identical Nix-managed static content; runtime state (.credentials.json,
    # .claude.json, projects/, todos/, history.jsonl, plugins/installed_plugins.json)
    # is owned by claude per-dir and selected at invocation time via CLAUDE_CONFIG_DIR.
    file = let
      commandFiles = builtins.readDir ./commands;
      commandEntries =
        lib.filterAttrs (
          name: type: type == "regular" && lib.hasSuffix ".md" name
        )
        commandFiles;
      mkClaudeFiles = dir: let
        commandFileAttrs =
          lib.mapAttrs' (
            name: _: lib.nameValuePair "${dir}/commands/${name}" {source = ./commands/${name};}
          )
          commandEntries;
      in
        lib.mkMerge [
          commandFileAttrs
          {
            "${dir}/settings.json".source = ./settings.json;
            "${dir}/CLAUDE.md".source = ./CLAUDE.md;
            "${dir}/agents".source = ./agents;
            "${dir}/skills".source = ./skills;
            "${dir}/bin/cc-tools-statusline".source = "${cc-tools}/bin/cc-tools-statusline";
            "${dir}/hooks/ntfy-notifier.sh" = {
              source = ./hooks/ntfy-notifier.sh;
              executable = true;
            };
            "${dir}/.keep".text = "";
            "${dir}/projects/.keep".text = "";
            "${dir}/todos/.keep".text = "";
            "${dir}/statsig/.keep".text = "";
            "${dir}/commands/.keep".text = "";
          }
        ];
    in
      lib.mkMerge [
        (mkClaudeFiles ".claude")
        (mkClaudeFiles ".claude-work")
      ];

    activation.claudeDirectoryPermissions = lib.hm.dag.entryAfter ["writeBoundary"] ''
      set -euo pipefail
      for base in ".claude" ".claude-work"; do
        for dir in "$base" "$base/bin" "$base/commands" "$base/hooks" "$base/projects" "$base/statsig" "$base/todos"; do
          if [ -d "$HOME/$dir" ]; then
            chmod 755 "$HOME/$dir"
          fi
        done
        if [ ! -d "$HOME/$base/debug" ]; then
          mkdir -p "$HOME/$base/debug"
          chmod 755 "$HOME/$base/debug"
        fi
      done

      # Remove vim mode if previously set in Claude Code preferences.
      # Personal prefs live at ~/.claude.json (default when CLAUDE_CONFIG_DIR unset);
      # work prefs live at ~/.claude-work/.claude.json.
      for prefs in "$HOME/.claude.json" "$HOME/.claude-work/.claude.json"; do
        if [ -f "$prefs" ] && ${pkgs.jq}/bin/jq -e '.editorMode == "vim"' "$prefs" >/dev/null 2>&1; then
          ${pkgs.jq}/bin/jq 'del(.editorMode)' "$prefs" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs"
        fi
      done
    '';

    # Install declared plugins if not already installed, for each profile dir.
    # Nix declares intent (settings.json), Claude manages state (installed_plugins.json).
    # Work-profile install may fail on first rebuild if the Enterprise account isn't
    # logged in yet; the || fallback tolerates it and a subsequent `update` will retry.
    activation.claudePluginInstall = lib.hm.dag.entryAfter ["claudeDirectoryPermissions"] ''
      set -euo pipefail

      DECLARED_PLUGINS=(
        "gambit@gambit"
      )

      for base in ".claude" ".claude-work"; do
        INSTALLED_PLUGINS="$HOME/$base/plugins/installed_plugins.json"
        mkdir -p "$HOME/$base/plugins"

        for plugin in "''${DECLARED_PLUGINS[@]}"; do
          if [ ! -f "$INSTALLED_PLUGINS" ] || ! ${pkgs.jq}/bin/jq -e ".plugins[\"$plugin\"]" "$INSTALLED_PLUGINS" >/dev/null 2>&1; then
            echo "Installing missing Claude plugin into $base: $plugin"
            CLAUDE_CONFIG_DIR="$HOME/$base" ${pkgs.claudeCodeCli}/bin/claude plugin install "$plugin" || echo "Warning: Failed to install $plugin in $base (may need manual install)"
          fi
        done
      done
    '';

    # Place a wrapper script at ~/.local/bin/claude that execs the Nix-patched binary.
    # This satisfies Claude's native installMethod check (file exists at expected path)
    # while ensuring the patchelf'd binary always runs. A regular file can't be silently
    # replaced by Claude's auto-updater (which uses ln -sf for symlinks).
    # Runs after plugin install since that step can trigger Claude's self-installer.
    activation.claudeNativeWrapper = lib.hm.dag.entryAfter ["claudePluginInstall"] ''
      set -euo pipefail
      rm -rf "$HOME/.local/share/claude/versions"
      rm -f "$HOME/.local/bin/claude"
      mkdir -p "$HOME/.local/bin"
      printf '#!/bin/sh\nexec %s "$@"\n' "${pkgs.claudeCodeCli}/bin/claude" > "$HOME/.local/bin/claude"
      chmod +x "$HOME/.local/bin/claude"
    '';
  };
}
