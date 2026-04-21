{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  # Get cc-tools binaries from the flake
  cc-tools = inputs.cc-tools.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Gambit skills marketplace as a directory-source. Pinned via flake.lock;
  # updates with `nix flake update gambit`.
  gambitSrc = inputs.gambit.packages.${pkgs.stdenv.hostPlatform.system}.default;
  gambitRev = inputs.gambit.rev or "unknown";

  # Generate settings.json with gambit's marketplace entry injected at build
  # time, pointing at the Nix store path. Keeps a single source of truth
  # between settings.json's extraKnownMarketplaces and the runtime
  # known_marketplaces.json populated by activation.
  settingsJsonBase = builtins.fromJSON (builtins.readFile ./settings.json);
  settingsJson = pkgs.writeText "claude-settings.json" (builtins.toJSON (
    settingsJsonBase
    // {
      extraKnownMarketplaces =
        (settingsJsonBase.extraKnownMarketplaces or {})
        // {
          gambit = {
            source = {
              source = "directory";
              path = toString gambitSrc;
            };
          };
        };
    }
  ));
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
            "${dir}/settings.json".source = settingsJson;
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

    # Declaratively install gambit into both profile dirs. Rather than shell
    # out to `claude plugin install` (which wants to modify settings.json —
    # not possible when it's a read-only Nix store symlink), we populate the
    # runtime state by hand:
    #   - known_marketplaces.json: gambit → directory source at ${gambitSrc}
    #   - plugins/cache/gambit/gambit/<version>: symlink to ${gambitSrc}
    #   - installed_plugins.json: gambit@gambit entry pointing at the cache
    # Claude reads these on session start and sees gambit as an installed,
    # enabled plugin (enablement is declared in settings.json). Idempotent:
    # re-running activation after a flake update rewrites the marketplace
    # path and the cache symlink to the new store path.
    activation.claudePluginInstall = lib.hm.dag.entryAfter ["claudeDirectoryPermissions"] ''
      set -euo pipefail

      GAMBIT_SRC="${gambitSrc}"
      GAMBIT_REV="${gambitRev}"
      GAMBIT_VERSION=$(${pkgs.jq}/bin/jq -r .version "$GAMBIT_SRC/.claude-plugin/plugin.json")
      NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

      for base in ".claude" ".claude-work"; do
        mkdir -p "$HOME/$base/plugins"
        KM="$HOME/$base/plugins/known_marketplaces.json"
        INSTALLED="$HOME/$base/plugins/installed_plugins.json"
        CACHE_PARENT="$HOME/$base/plugins/cache/gambit/gambit"
        CACHE_DIR="$CACHE_PARENT/$GAMBIT_VERSION"

        # 1. known_marketplaces.json
        [ -f "$KM" ] || echo '{}' > "$KM"
        ${pkgs.jq}/bin/jq \
          --arg path "$GAMBIT_SRC" \
          --arg now "$NOW" \
          '.gambit = {
            source: {source: "directory", path: $path},
            installLocation: $path,
            lastUpdated: $now
          }' "$KM" > "$KM.tmp" && mv "$KM.tmp" "$KM"

        # 2. plugin cache — symlink to the Nix store path. Replace any
        # existing dir or mismatched symlink so the cache always reflects
        # the current flake pin.
        mkdir -p "$CACHE_PARENT"
        if [ -L "$CACHE_DIR" ] || [ -e "$CACHE_DIR" ]; then
          rm -rf "$CACHE_DIR"
        fi
        ln -s "$GAMBIT_SRC" "$CACHE_DIR"

        # 3. installed_plugins.json — record gambit@gambit pointing at the
        # cache symlink. Preserve installedAt if a prior entry exists;
        # always refresh lastUpdated and gitCommitSha.
        [ -f "$INSTALLED" ] || echo '{"version":2,"plugins":{}}' > "$INSTALLED"
        ${pkgs.jq}/bin/jq \
          --arg version "$GAMBIT_VERSION" \
          --arg installPath "$CACHE_DIR" \
          --arg rev "$GAMBIT_REV" \
          --arg now "$NOW" \
          '.plugins["gambit@gambit"] = [{
            scope: "user",
            installPath: $installPath,
            version: $version,
            installedAt: (.plugins["gambit@gambit"][0].installedAt // $now),
            lastUpdated: $now,
            gitCommitSha: $rev
          }]' "$INSTALLED" > "$INSTALLED.tmp" && mv "$INSTALLED.tmp" "$INSTALLED"
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
