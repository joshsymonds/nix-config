{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.claudeCode;

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
  #
  # Two variants get built: a vanilla one for the personal profile
  # (~/.claude) and one with the AWS Bedrock env overlay for the work
  # profile (~/.claude-work). Work-profile sessions route through the
  # Attain AWS account; personal sessions stay on Anthropic OAuth.
  settingsJsonBase = builtins.fromJSON (builtins.readFile ./settings.json);

  settingsJsonWithGambit =
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
    };

  mkSettingsJson = name: overlay:
    pkgs.writeText "claude-settings-${name}.json" (builtins.toJSON (
      lib.recursiveUpdate settingsJsonWithGambit overlay
    ));

  settingsJsonPersonal = mkSettingsJson "personal" {};

  settingsJsonWork = mkSettingsJson "work" {
    # Bedrock model IDs use the cross-region inference profile form, e.g.
    # `us.anthropic.claude-opus-4-7` (`us.` for the US Geo profile).
    #
    # Opus 4.7 is 1M-context NATIVELY on Bedrock per the model card -- there
    # is no separate 1M variant, and the `[1m]` suffix Claude Code uses for
    # models that have 200K-default-with-1M-opt-in (Opus 4.6, Sonnet 4.6)
    # triggers `400 invalid_request_error: invalid beta flag` on Opus 4.7
    # because it attaches a `context-1m-2025-08-07` beta header the model
    # rejects. So: no `[1m]` suffix for Opus 4.7. The 1M context comes for
    # free with the base profile ID. (See claude-code issue #49238.)
    #
    # Same reasoning for the Sonnet entry below -- accepting 200K context
    # for the rarely-used sonnet alias rather than risking the beta-flag
    # error. If Sonnet 1M is needed later, revisit after confirming the
    # AWS-side fix has rolled out in our region.
    #
    # Personal profile keeps the Anthropic-API-style ID inherited from the
    # base settings.json (which expects `claude-opus-4-7[1m]` syntax).
    model = "us.anthropic.claude-opus-4-7";
    env = {
      CLAUDE_CODE_USE_BEDROCK = "1";
      AWS_REGION = "us-east-1";
      AWS_PROFILE = "attain";
      # Alias-resolution targets for opus/sonnet/haiku in /model. The HAIKU
      # entry also doubles as the small/fast background-task model on
      # Bedrock (title generation, auto-compaction summaries). Per Bedrock
      # docs, ANTHROPIC_SMALL_FAST_MODEL is deprecated -- ANTHROPIC_DEFAULT_
      # HAIKU_MODEL covers both slots when set.
      ANTHROPIC_DEFAULT_OPUS_MODEL = "us.anthropic.claude-opus-4-7";
      ANTHROPIC_DEFAULT_SONNET_MODEL = "us.anthropic.claude-sonnet-4-6";
      ANTHROPIC_DEFAULT_HAIKU_MODEL = "us.anthropic.claude-haiku-4-5-20251001-v1:0";
    };
  };

  # Skills dir as a linkFarm derivation: nix-managed skills + the
  # team-status skill at an out-of-store writable path so iteration
  # on team-status does not require a rebuild. New skills added under
  # ./skills/ are picked up automatically. Per-host opt-in skills go
  # in programs.claudeCode.extraSkills (host-skills/ on disk, named
  # so they're discoverable but not auto-included on every host).
  skillsDir = let
    nixSkills = lib.attrNames (
      lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./skills)
    );
  in
    pkgs.linkFarm "claude-skills" (
      (map (n: {
          name = n;
          path = ./skills + "/${n}";
        })
        nixSkills)
      ++ (lib.mapAttrsToList (n: p: {
          name = n;
          path = p;
        })
        cfg.extraSkills)
      ++ [
        {
          name = "team-status";
          path = "/home/joshsymonds/.claude-work/team-status";
        }
        {
          name = "harvest-weekly";
          path = "/home/joshsymonds/.claude-work/harvest-weekly";
        }
      ]
    );
in {
  options.programs.claudeCode.hostContext = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = ''
      Per-host markdown rendered to ~/.claude/host.md and ~/.claude-work/host.md,
      then imported from CLAUDE.md via @host.md. Used to ground agents about
      which physical machine they're running on (hardware, role, capabilities).
      Empty string produces an empty file; the @-import is harmless in that case.
    '';
  };

  options.programs.claudeCode.extraSkills = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = {};
    description = ''
      Per-host opt-in skills, merged into the skills linkFarm under
      ~/.claude/skills/<name>. Use for skills whose trigger surface only
      exists on one host (e.g., debugging-linux-games on the gaming
      machine) and shouldn't load on hosts where they'd be dead weight.
      Map entries: name → directory containing SKILL.md.
    '';
  };

  config.age.secrets."ntfy-url" = {
    file = ../../secrets/user/ntfy-url.age;
  };

  # ntfy.sh API token for the paid account. Publishing with this as a
  # Bearer token attributes messages to the account so the paid daily
  # limits apply instead of the anonymous per-IP free quota (the whole
  # fleet looping through one topic exhausts the free quota by mid-morning
  # and every publish then 429s — silently, since the hook never checked
  # HTTP status). The topic stays a public, unauthenticated-read topic so
  # iOS Firebase push keeps full message content; only publish is authed.
  config.age.secrets."ntfy-token" = {
    file = ../../secrets/user/ntfy-token.age;
  };

  config.home = {
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
      CLAUDE_HOOKS_NTFY_TOKEN_FILE = config.age.secrets."ntfy-token".path;
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
      # CLAUDE.md is written as text (not symlinked) so the trailing
      # @host.md and @fleet.md imports resolve relative to ~/.claude
      # (or ~/.claude-work) rather than the nix store path the symlink
      # would otherwise expose. Per Claude Code's memory docs, relative
      # @-imports resolve relative to the file containing them.
      claudeMdText =
        builtins.readFile ./CLAUDE.md
        + ''


          @host.md
          @fleet.md
        '';

      mkClaudeFiles = dir: settings: let
        commandFileAttrs =
          lib.mapAttrs' (
            name: _: lib.nameValuePair "${dir}/commands/${name}" {source = ./commands/${name};}
          )
          commandEntries;
      in
        lib.mkMerge [
          commandFileAttrs
          {
            "${dir}/settings.json".source = settings;
            "${dir}/CLAUDE.md".text = claudeMdText;
            "${dir}/host.md".text = cfg.hostContext;
            "${dir}/fleet.md".source = ./fleet.md;
            "${dir}/agents".source = ./agents;
            "${dir}/skills".source = skillsDir;
            "${dir}/bin/cc-tools-statusline".source = "${cc-tools}/bin/cc-tools-statusline";
            "${dir}/hooks/ntfy-notifier.sh" = {
              source = ./hooks/ntfy-notifier.sh;
              executable = true;
            };
            "${dir}/hooks/aws-profile-mirror.sh" = {
              source = ./hooks/aws-profile-mirror.sh;
              executable = true;
            };
            "${dir}/.keep".text = "";
            "${dir}/statsig/.keep".text = "";
            "${dir}/commands/.keep".text = "";
          }
        ];
    in
      lib.mkMerge [
        (mkClaudeFiles ".claude" settingsJsonPersonal)
        (mkClaudeFiles ".claude-work" settingsJsonWork)
      ];

    # Unify stateful dirs (transcripts, memories, task lists, file history, etc.)
    # across personal and work profiles. Both profiles see the same session
    # history and auto-memory state — only billing / OAuth / MCP servers stay
    # per-profile. Runs before claudeDirectoryPermissions so chmod targets the
    # symlinked shared dir rather than racing with real-dir creation.
    #
    # Defensive: if a profile dir already exists as a real directory with
    # content, the symlink is skipped and a warning is logged. The one-time
    # migration from real dirs → shared + symlinks is done by hand; this
    # activation maintains the structure on fresh machines and after rebuilds.
    activation.claudeUnifiedState = lib.hm.dag.entryBefore ["claudeDirectoryPermissions"] ''
      set -euo pipefail
      SHARED="$HOME/.claude-shared"
      mkdir -p "$SHARED"
      for d in projects todos tasks sessions file-history shell-snapshots; do
        mkdir -p "$SHARED/$d"
        for base in ".claude" ".claude-work"; do
          target="$HOME/$base/$d"
          if [ -L "$target" ]; then
            cur="$(readlink "$target")"
            if [ "$cur" != "$SHARED/$d" ]; then
              rm "$target"
              ln -s "$SHARED/$d" "$target"
            fi
          elif [ ! -e "$target" ]; then
            mkdir -p "$HOME/$base"
            ln -s "$SHARED/$d" "$target"
          elif [ -d "$target" ]; then
            echo "claudeUnifiedState: $target is a real dir with data; skipping. Move to $SHARED/$d manually." >&2
          fi
        done
      done
    '';

    activation.claudeDirectoryPermissions = lib.hm.dag.entryAfter ["writeBoundary" "claudeUnifiedState"] ''
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
