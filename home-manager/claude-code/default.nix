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
      CLAUDE_HOOKS_NTFY_URL_FILE = config.age.secrets."ntfy-url".path;
      # The only reliable way to disable auto-updates for native installs.
      # settings.json autoUpdater.disabled is cosmetic; ~/.claude.json autoUpdates
      # is bypassed by autoUpdatesProtectedForNative for native installMethod.
      DISABLE_AUTOUPDATER = "1";
    };

    # Create and manage ~/.claude directory
    file = let
      # Dynamically read command files
      commandFiles = builtins.readDir ./commands;
      commandEntries =
        lib.filterAttrs (
          name: type: type == "regular" && lib.hasSuffix ".md" name
        )
        commandFiles;
      commandFileAttrs =
        lib.mapAttrs' (
          name: _: lib.nameValuePair ".claude/commands/${name}" {source = ./commands/${name};}
        )
        commandEntries;
    in
      lib.mkMerge [
        commandFileAttrs
        {
          ".claude/settings.json".source = ./settings.json;
          ".claude/CLAUDE.md".source = ./CLAUDE.md;
          ".claude/agents".source = ./agents;
          ".claude/skills".source = ./skills;
          ".claude/bin/cc-tools-statusline".source = "${cc-tools}/bin/cc-tools-statusline";
          ".claude/hooks/ntfy-notifier.sh" = {
            source = ./hooks/ntfy-notifier.sh;
            executable = true;
          };
          ".claude/.keep".text = "";
          ".claude/projects/.keep".text = "";
          ".claude/todos/.keep".text = "";
          ".claude/statsig/.keep".text = "";
          ".claude/commands/.keep".text = "";
        }
      ];

    activation.claudeDirectoryPermissions = lib.hm.dag.entryAfter ["writeBoundary"] ''
      set -euo pipefail
      for dir in ".claude" ".claude/bin" ".claude/commands" ".claude/hooks" ".claude/projects" ".claude/statsig" ".claude/todos"; do
        if [ -d "$HOME/$dir" ]; then
          chmod 755 "$HOME/$dir"
        fi
      done
      if [ ! -d "$HOME/.claude/debug" ]; then
        mkdir -p "$HOME/.claude/debug"
        chmod 755 "$HOME/.claude/debug"
      fi

      # Remove vim mode if previously set in Claude Code preferences
      CLAUDE_PREFS="$HOME/.claude.json"
      if [ -f "$CLAUDE_PREFS" ] && ${pkgs.jq}/bin/jq -e '.editorMode == "vim"' "$CLAUDE_PREFS" >/dev/null 2>&1; then
        ${pkgs.jq}/bin/jq 'del(.editorMode)' "$CLAUDE_PREFS" > "$CLAUDE_PREFS.tmp" && mv "$CLAUDE_PREFS.tmp" "$CLAUDE_PREFS"
      fi
    '';

    # Install declared plugins if not already installed
    # Nix declares intent (settings.json), Claude manages state (installed_plugins.json)
    activation.claudePluginInstall = lib.hm.dag.entryAfter ["claudeDirectoryPermissions"] ''
      set -euo pipefail
      INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"

      # Declared plugins: plugin@marketplace
      DECLARED_PLUGINS=(
        "gambit@gambit"
      )

      for plugin in "''${DECLARED_PLUGINS[@]}"; do
        if [ ! -f "$INSTALLED_PLUGINS" ] || ! ${pkgs.jq}/bin/jq -e ".plugins[\"$plugin\"]" "$INSTALLED_PLUGINS" >/dev/null 2>&1; then
          echo "Installing missing Claude plugin: $plugin"
          ${pkgs.claudeCodeCli}/bin/claude plugin install "$plugin" || echo "Warning: Failed to install $plugin (may need manual install)"
        fi
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
