{
  config,
  hostname,
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
  codexExecutorConfig = import ./codex-executor-config.nix {inherit pkgs;};

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

  # The work profile (~/.claude-work) is a SINGLE config dir whose LLM
  # backend (AWS Bedrock vs Anthropic OAuth) is a runtime-toggled mode, not
  # a baked setting. Home-manager therefore deploys this file as
  # settings.base.json (never settings.json), and `cwrender` (below) merges
  # it with the runtime backend mode into a REAL ~/.claude-work/settings.json
  # at activation time and on every `cwswitch` flip.
  #
  # Why settings.json and not just launch env: the bg-agent daemon inherits
  # the launch env, but the spare workers it forks get a SCRUBBED env —
  # CLAUDE_CODE_USE_BEDROCK, ANTHROPIC_MODEL, and ANTHROPIC_DEFAULT_*_MODEL
  # are exactly the vars stripped (observed on CLI 2.1.204 via /proc environ
  # diff, 2026-07-09; an older CLI did inherit them, which is how this went
  # unnoticed). Spares DO read settings.json's `env` block at spawn, so the
  # backend env must live there for resumed/background sessions to hit
  # Bedrock. settings.local.json is NOT an option: its `env` block is
  # ignored entirely (probed empirically, same date). The launch-time zsh
  # wrapper exports remain as the interactive-session path; cwrender is the
  # worker path. The Bedrock model ARNs embed the Attain AWS account id and
  # this repo is public, so they are never baked in here — cwrender reads
  # them from the claude-bedrock-models agenix secret at runtime.
  settingsJsonWork = mkSettingsJson "work" {};

  # tier -> {anthropic, bedrock} model map (declared in home-manager/zsh,
  # shared here for cwrender).
  bedrockModelsFile = config.age.secrets."claude-bedrock-models".path;

  # cwrender — render ~/.claude-work/settings.json from the HM-deployed
  # settings.base.json plus the runtime backend pointer (.backend). In
  # bedrock mode the env block gets CLAUDE_CODE_USE_BEDROCK + region/profile
  # + per-tier model ARNs from the agenix secret ([1m] 1M-context suffix on
  # everything but haiku, matching the zsh launch wrapper exactly); in
  # anthropic mode the base is written through untouched, so NO backend env
  # leaks into OAuth sessions. Output is always a real, writable file
  # replaced atomically — never a store symlink — because spare workers
  # re-read it at spawn and cwswitch must be able to re-render without a
  # rebuild.
  cwrender = pkgs.writeShellApplication {
    name = "cwrender";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      work="$HOME/.claude-work"
      base="$work/settings.base.json"
      out="$work/settings.json"

      if [ ! -r "$base" ]; then
        echo "cwrender: $base missing or unreadable — is home-manager deployed?" >&2
        exit 1
      fi

      mode=bedrock
      [ -f "$work/.backend" ] && mode=$(tr -d '[:space:]' < "$work/.backend")
      [ -n "$mode" ] || mode=bedrock

      models="${bedrockModelsFile}"
      tmp="$out.cwrender.$$"

      if [ "$mode" = bedrock ] && [ -r "$models" ]; then
        jq --slurpfile m "$models" '
          .env += {
            CLAUDE_CODE_USE_BEDROCK: "1",
            AWS_REGION: "us-east-2",
            AWS_PROFILE: "attain",
            ANTHROPIC_MODEL: ($m[0].fable.bedrock + "[1m]"),
            ANTHROPIC_DEFAULT_FABLE_MODEL: ($m[0].fable.bedrock + "[1m]"),
            ANTHROPIC_DEFAULT_OPUS_MODEL: ($m[0].opus.bedrock + "[1m]"),
            ANTHROPIC_DEFAULT_SONNET_MODEL: ($m[0].sonnet.bedrock + "[1m]"),
            ANTHROPIC_DEFAULT_HAIKU_MODEL: $m[0].haiku.bedrock
          }' "$base" > "$tmp"
      else
        if [ "$mode" = bedrock ]; then
          echo "cwrender: model map $models unreadable (claude-bedrock-models agenix secret not deployed?) — rendering WITHOUT Bedrock env; work workers will use the Anthropic OAuth backend despite .backend=bedrock." >&2
        fi
        jq . "$base" > "$tmp"
      fi
      mv "$tmp" "$out"
      echo "cwrender: $out rendered for backend '$mode'"
    '';
  };

  # ── Model registry ──────────────────────────────────────────────────────
  # Single source of truth for every Claude Code model this fleet adopts.
  # Drives cmswitch's alias resolution (below) and the generated
  # per-model unpin<Model>LaunchEffort check/assignment in
  # activation.claudeEffortUnpin (further down). Adding a model here is the
  # only step needed for cmswitch to recognise it and — if unpinKey is
  # non-null — for activation to clear its launch-default effort pin.
  modelRegistry = {
    "fable-5" = {
      model = "claude-fable-5";
      defaultEffort = "high";
      unpinKey = "unpinFable5LaunchEffort";
      aliases = ["fable"];
    };
    "opus-5" = {
      model = "claude-opus-5";
      defaultEffort = "xhigh";
      unpinKey = "unpinOpus5LaunchEffort";
      aliases = ["opus"];
    };
    "opus-4-8" = {
      model = "claude-opus-4-8";
      defaultEffort = "xhigh";
      unpinKey = "unpinOpus48LaunchEffort";
      aliases = [];
    };
    "opus-4-7" = {
      model = "claude-opus-4-7";
      defaultEffort = "xhigh";
      unpinKey = "unpinOpus47LaunchEffort";
      aliases = [];
    };
    "sonnet-5" = {
      model = "claude-sonnet-5";
      defaultEffort = "high";
      unpinKey = null;
      aliases = ["sonnet"];
    };
    "haiku-4-5" = {
      model = "claude-haiku-4-5-20251001";
      defaultEffort = "high";
      unpinKey = null;
      aliases = ["haiku"];
    };
  };

  # Normalize a model name/alias for matching: lowercase, drop spaces/dots/
  # underscores/dashes, then strip a leading "claude" prefix. Mirrored
  # exactly in cmswitch's bash `normalize()` (below) so Nix-side
  # alias-table construction and runtime CLI parsing agree on what counts
  # as "the same name" — e.g. normalize "Claude Opus 4.8" == normalize
  # "opus-4-8" == "opus48".
  normalize = s: let
    lower = lib.toLower s;
    noSeparators = lib.concatStrings (
      builtins.filter (c: !(builtins.elem c [" " "." "_" "-"])) (lib.stringToCharacters lower)
    );
  in
    lib.removePrefix "claude" noSeparators;

  # Flatten modelRegistry into a normalized-alias -> {name; model;
  # defaultEffort;} lookup table. Each entry contributes its attr name, its
  # model string, and any extra aliases — deduped after normalizing, since
  # e.g. normalize "fable-5" and normalize "claude-fable-5" both collide on
  # "fable5". Throws at eval time, naming the offending alias, if two
  # DIFFERENT registry entries would normalize to the same key — plain
  # attrset construction would otherwise silently keep only the last
  # writer, which is exactly the failure mode we don't want from a typo'd
  # alias.
  aliasTable = let
    aliasEntries = lib.concatMap (
      name: let
        entry = modelRegistry.${name};
        candidates = lib.unique (map normalize ([name entry.model] ++ entry.aliases));
      in
        map (alias: {
          inherit alias name;
          value = {
            inherit name;
            inherit (entry) model defaultEffort;
          };
        })
        candidates
    ) (lib.attrNames modelRegistry);
  in
    lib.foldl' (
      acc: e:
        if acc ? ${e.alias} && acc.${e.alias}.name != e.name
        then
          throw
          "modelRegistry: alias '${e.alias}' is claimed by both '${acc.${e.alias}.name}' and '${e.name}' — aliases must be unique after normalization"
        else acc // {${e.alias} = e.value;}
    ) {}
    aliasEntries;

  # Human-readable "known models" listing, shared by cmswitch's usage text
  # and its refusal-path output (empty input, unknown alias).
  modelListingText = lib.concatStringsSep "\n" (
    map (
      name: let
        entry = modelRegistry.${name};
        aliasSuffix =
          if entry.aliases == []
          then ""
          else " (aliases: ${lib.concatStringsSep ", " entry.aliases})";
      in "  ${name} — default effort ${entry.defaultEffort}${aliasSuffix}"
    ) (lib.attrNames modelRegistry)
  );

  # unpin<Model>LaunchEffort keys to clear in activation.claudeEffortUnpin,
  # generated from modelRegistry.*.unpinKey — see that activation script
  # for why this exists at all.
  unpinKeys = builtins.filter (k: k != null) (
    lib.mapAttrsToList (_: entry: entry.unpinKey) modelRegistry
  );
  unpinCheckExpr = lib.concatMapStringsSep " and " (k: ".${k} == true") unpinKeys;
  unpinAssignExpr = lib.concatMapStringsSep " | " (k: ".${k} = true") unpinKeys;

  # Registry-driven model/effort switcher for settings.json. See the
  # extensive comment on the `cmswitch` derivation itself (below) for full
  # behavior; this mirrors cwswitch's shape (home-manager/zsh/default.nix)
  # but edits+commits+deploys the Nix-tracked settings.json instead of
  # rewriting runtime daemon state.
  cmswitch = pkgs.writeShellApplication {
    name = "cmswitch";
    runtimeInputs = [pkgs.jq pkgs.git pkgs.coreutils];
    text = ''
      # Switch the repo's home-manager/claude-code/settings.json to a
      # different model/effort, commit just that file, deploy via `update`,
      # and bounce the Claude Code background-agent daemon in each profile
      # (~/.claude, ~/.claude-work) so new work picks up the change —
      # mirroring cwswitch's daemon-bounce step, but for the *default*
      # model/effort baked into settings.json rather than the work-profile
      # Bedrock/Anthropic backend.
      #
      # `update`/`claude` are user-profile binaries, not Nix store paths we
      # can reference at build time (this derivation's runtimeInputs only
      # cover jq/git/coreutils) — guard for them explicitly so a missing
      # profile fails fast with a clear message instead of a raw
      # "command not found".
      command -v update >/dev/null 2>&1 || { echo "cmswitch: 'update' not found on PATH — is it deployed for this profile?" >&2; exit 1; }
      command -v claude >/dev/null 2>&1 || { echo "cmswitch: 'claude' not found on PATH." >&2; exit 1; }

      repo="${config.home.homeDirectory}/nix-config"
      settings_file="$repo/home-manager/claude-code/settings.json"

      # The alias table is baked in at build time from modelRegistry, so
      # cmswitch and the Nix-side alias resolution can never drift.
      table='${builtins.toJSON aliasTable}'

      model_listing='${modelListingText}'

      # Mirrors the Nix `normalize` function above exactly: lowercase, drop
      # spaces/dots/underscores/dashes, strip a leading "claude" prefix.
      normalize() {
        local s="''${1,,}"
        s="''${s//[ ._-]/}"
        s="''${s#claude}"
        printf '%s' "$s"
      }

      usage() {
        cat >&2 <<EOF
      usage: cmswitch <model> [effort]
        <model>  a registry name or alias below (matching ignores case, spaces,
                 dots, underscores, dashes, and a leading "claude")
        effort   low | medium | high | xhigh — defaults to the model's own default

      known models:
      $model_listing

      valid efforts: low medium high xhigh
      EOF
      }

      # Reverse-map a settings.json model string back to its canonical
      # registry name, for the no-args status display.
      reverse_lookup() {
        printf '%s' "$table" | jq -r --arg m "$1" \
          'to_entries | map(select(.value.model == $m)) | (.[0].value.name // empty)'
      }

      if [ $# -eq 0 ]; then
        cur_model=$(jq -r '.model // empty' "$settings_file")
        cur_effort=$(jq -r '.effortLevel // empty' "$settings_file")
        if [ -z "$cur_model" ]; then
          echo "model: (unset)"
        else
          canon=$(reverse_lookup "$cur_model")
          if [ -n "$canon" ]; then
            echo "model: $cur_model ($canon)"
          else
            echo "model: $cur_model"
          fi
        fi
        if [ -z "$cur_effort" ]; then
          echo "effortLevel: (unset)"
        else
          echo "effortLevel: $cur_effort"
        fi
        exit 0
      fi

      # Join every arg with spaces, then re-split into words so callers can
      # quote however they like (`cmswitch opus xhigh`, `cmswitch "opus
      # xhigh"`, ...). If the last word normalizes to a known effort level,
      # peel it off; whatever remains (rejoined and normalized) is the
      # model key.
      all_args="$*"
      read -ra words <<< "$all_args"
      word_count=''${#words[@]}
      effort=""
      model_words=("''${words[@]}")
      if [ "$word_count" -gt 0 ]; then
        last_norm=$(normalize "''${words[$((word_count - 1))]}")
        case "$last_norm" in
          low | medium | high | xhigh)
            effort="$last_norm"
            model_words=("''${words[@]:0:$((word_count - 1))}")
            ;;
        esac
      fi
      model_key=$(normalize "''${model_words[*]}")

      # Empty model key (input was only an effort, or only the word
      # "claude") or an alias-table miss: refuse with usage, no side
      # effects.
      if [ -z "$model_key" ]; then
        usage
        exit 2
      fi
      if ! printf '%s' "$table" | jq -e --arg k "$model_key" '.[$k] // empty' >/dev/null 2>&1; then
        usage
        exit 2
      fi

      name=$(printf '%s' "$table" | jq -r --arg k "$model_key" '.[$k].name')
      model=$(printf '%s' "$table" | jq -r --arg k "$model_key" '.[$k].model')
      default_effort=$(printf '%s' "$table" | jq -r --arg k "$model_key" '.[$k].defaultEffort')
      effort="''${effort:-$default_effort}"

      cur_model=$(jq -r '.model // empty' "$settings_file")
      cur_effort=$(jq -r '.effortLevel // empty' "$settings_file")

      if [ "$cur_model" = "$model" ] && [ "$cur_effort" = "$effort" ]; then
        echo "already on $name $effort"
        exit 0
      fi

      tmp="$settings_file.cmswitch.$$"
      jq --indent 2 --arg m "$model" --arg e "$effort" '.model = $m | .effortLevel = $e' "$settings_file" > "$tmp"
      mv "$tmp" "$settings_file"

      # Commit ONLY settings.json — the pathspec on both `add` and `commit`
      # guarantees any other dirty files in the repo are left untouched.
      git -C "$repo" add -- home-manager/claude-code/settings.json
      git -C "$repo" commit -m "claude-code: $name $effort" -- home-manager/claude-code/settings.json
      sha=$(git -C "$repo" rev-parse --short HEAD)

      if ! update; then
        echo "cmswitch: commit $sha is in place but NOT deployed — rerun 'update'." >&2
        exit 1
      fi

      # Bounce each profile's bg-agent daemon so new work picks up the new
      # default — but only if nothing is actively "working" there (a bounce
      # would kill in-flight work; leave the daemon up and let it pick up
      # the new default on its own next restart instead). Mirrors the
      # jobs/*/state.json scan in cwswitch (home-manager/zsh/default.nix).
      for base in ".claude" ".claude-work"; do
        profile_dir="$HOME/$base"
        working=0
        if [ -d "$profile_dir/jobs" ]; then
          for state_file in "$profile_dir"/jobs/*/state.json; do
            [ -f "$state_file" ] || continue
            if grep -q '"state": *"working"' "$state_file" 2>/dev/null; then
              working=$((working + 1))
            fi
          done
        fi
        if [ "$working" -gt 0 ]; then
          echo "$base: $working job(s) working — daemon left running; new bg jobs may use the old default until it restarts"
        else
          CLAUDE_CONFIG_DIR="$profile_dir" claude daemon stop --any >/dev/null 2>&1 || true
          echo "$base: bounce requested"
        fi
      done

      echo "''${cur_model:-(unset)} ''${cur_effort:-(unset)} -> $name $effort (commit $sha) deployed"
    '';
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

  # Exposes the cwrender package so other modules (home-manager/zsh's
  # cwswitch) can depend on the exact same renderer without duplicating it
  # or reaching across module files.
  options.programs.claudeCode.cwrenderPackage = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The cwrender script that materializes ~/.claude-work/settings.json from settings.base.json + the runtime backend mode.";
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

  config.programs.claudeCode.cwrenderPackage = cwrender;

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
        python3
        # Include cc-tools binaries
        cc-tools
      ])
      ++ [pkgs.claudeCodeCli pkgs.claude-swap cmswitch cwrender];

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
      # Shared by Claude's stdin hooks and Codex's argv notify command.
      CC_TOOLS_NTFY_URL_FILE = config.age.secrets."ntfy-url".path;
      CC_TOOLS_NTFY_TOKEN_FILE = config.age.secrets."ntfy-token".path;
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

      # settingsAttr: the personal profile symlinks settings.json straight
      # to the store; the work profile deploys settings.base.json instead
      # and lets cwrender produce the real settings.json (see the cwrender
      # comment above for why it can't be a store symlink).
      mkClaudeFiles = dir: settings: let
        commandFileAttrs =
          lib.mapAttrs' (
            name: _: lib.nameValuePair "${dir}/commands/${name}" {source = ./commands/${name};}
          )
          commandEntries;
        settingsAttr =
          if dir == ".claude-work"
          then {"${dir}/settings.base.json".source = settings;}
          else {"${dir}/settings.json".source = settings;};
      in
        lib.mkMerge [
          commandFileAttrs
          settingsAttr
          {
            "${dir}/CLAUDE.md".text = claudeMdText;
            "${dir}/host.md".text = cfg.hostContext;
            "${dir}/fleet.md".source = ./fleet.md;
            "${dir}/agents".source = ./agents;
            "${dir}/skills".source = skillsDir;
            "${dir}/bin/cc-tools-statusline".source = "${cc-tools}/bin/cc-tools-statusline";
            "${dir}/bin/cc-tools".source = "${cc-tools}/bin/cc-tools";
            "${dir}/hooks/aws-profile-mirror.sh" = {
              source = ./hooks/aws-profile-mirror.sh;
              executable = true;
            };
            "${dir}/hooks/destructive-guard.py" = {
              source = ./hooks/destructive-guard.py;
              executable = true;
            };
            "${dir}/hooks/usage-summary-refresh.sh" = {
              source = ./hooks/usage-summary-refresh.sh;
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
        {
          # External executors are intentionally personal-only. The work
          # profile may run on Bedrock and must retain native Claude agents.
          ".claude/gambit/executors.json".text = builtins.toJSON codexExecutorConfig.registry;
          # Async-dispatch wrappers ride the cheap tier by default, but live
          # acceptance showed haiku-class relays failing as transport (tool
          # churn, terminated without the envelope). Sonnet-class relays cost
          # effectively the same tokens and don't drop the call.
          ".claude/gambit/models.json".text = builtins.toJSON {wrapper = "sonnet";};
        }
      ];

    # Unify stateful dirs across personal and work profiles AND across hosts.
    # Transcripts (projects, sessions, todos, tasks) live on NFS at
    # /mnt/claude/${HOSTNAME}/{personal,work}/, so each host owns its bucket
    # and gnomon can read every host's transcripts for the DMS bar widget.
    # High-churn small-file state (file-history, shell-snapshots) stays
    # LOCAL at ~/.claude-local/ to spare the NAS btrfs metadata storm.
    #
    # Scoped to the three hosts that actually run Claude Code (gnomon,
    # ultraviolet, vermissian). Out-of-scope hosts skip this activation
    # entirely and keep whatever layout they have.
    #
    # One-shot migration: if a pre-NFS ~/.claude-shared/ exists with real
    # data and the per-host .migrated marker is absent, rsync into the
    # bucket, then rename ~/.claude-shared/ to .bak-<date> (no destructive
    # delete). Idempotent thereafter.
    activation.claudeUnifiedState = lib.hm.dag.entryBefore ["claudeDirectoryPermissions"] (let
      inScope = builtins.elem hostname ["gnomon" "ultraviolet" "vermissian"];
    in
      if !inScope
      then ''
        echo "claudeUnifiedState: ${hostname} out of scope; skipping." >&2
      ''
      else ''
        # Subshell: ensures any `exit` inside this activation phase only
        # terminates the phase, not the entire HM activation script
        # (which would skip linkGeneration / reloadSystemd / etc.).
        (
        set -euo pipefail

        BUCKET="/mnt/claude/${hostname}"
        LOCAL="$HOME/.claude-local"
        SHARED="$HOME/.claude-shared"
        MARKER="$BUCKET/personal/.migrated"

        # NAS reachability — try to trigger automount, then verify. Refuse
        # to touch symlinks if the NAS is unreachable so we don't leave
        # the user with dangling targets.
        ${pkgs.coreutils}/bin/ls /mnt/claude >/dev/null 2>&1 || true
        if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/claude; then
          echo "claudeUnifiedState: /mnt/claude not mounted (NAS down?). Refusing to touch ~/.claude symlinks." >&2
          exit 1
        fi

        # Always ensure bucket and local-state directories exist (cheap,
        # idempotent).
        for profile in personal work; do
          for d in projects sessions todos tasks; do
            ${pkgs.coreutils}/bin/mkdir -p "$BUCKET/$profile/$d"
          done
        done
        ${pkgs.coreutils}/bin/mkdir -p "$LOCAL/file-history" "$LOCAL/shell-snapshots"

        # Helper: report whether a path is a non-empty directory.
        has_content() {
          [ -d "$1" ] && [ -n "$(${pkgs.findutils}/bin/find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]
        }

        # Detect whether any pre-NFS data needs rescuing. Two sources:
        #  (a) the old ~/.claude-shared/ unified dir (when it has real data
        #      and the marker is absent — the original layout on gnomon), or
        #  (b) any ~/.claude{,-work}/{projects,sessions,todos,tasks} that is
        #      itself a real directory with content (the layout on hosts
        #      that never went through the .claude-shared intermediate step,
        #      e.g. ultraviolet, vermissian).
        needs_rescue=false
        if [ -d "$SHARED" ] && [ ! -L "$SHARED" ] && [ ! -f "$MARKER" ]; then
          has_content "$SHARED" && needs_rescue=true || true
        fi
        if [ "$needs_rescue" = false ]; then
          for base in .claude .claude-work; do
            for d in projects sessions todos tasks file-history shell-snapshots; do
              tgt="$HOME/$base/$d"
              if [ -d "$tgt" ] && [ ! -L "$tgt" ] && has_content "$tgt"; then
                needs_rescue=true
                break 2
              fi
            done
          done
        fi

        # If a rescue would run AND an active Claude Code process is holding
        # JSONL files open under the about-to-be-rewritten paths, abort
        # quietly: don't fail the rebuild, just no-op so the existing
        # layout stays valid until the user stops claude.
        if [ "$needs_rescue" = true ]; then
          if ${pkgs.procps}/bin/pgrep -u "$USER" -fa 'claude' 2>/dev/null \
              | ${pkgs.gnugrep}/bin/grep -qE '(^| )claude( |$)|/claude( |$)'; then
            echo "claudeUnifiedState: pre-NFS data still present and an active 'claude' process was detected on ${hostname}." >&2
            echo "claudeUnifiedState: stop all Claude Code sessions, then re-run 'update' to complete the migration." >&2
            echo "claudeUnifiedState: bucket dirs were created but no symlinks were touched (in-flight writes preserved)." >&2
            exit 0
          fi
        fi

        # Project-dir classifier. The Claude Code project dir name is
        # the cwd with / replaced by -, so /home/joshsymonds/Work/attain
        # becomes -home-joshsymonds-Work-attain (and -attain-* for subdirs).
        # Only ~/Work/attain is Bedrock-billed work; every other Work/
        # subdir is side projects on the personal Max sub.
        is_work_dir() {
          case "$1" in
            -home-joshsymonds-Work-attain|-home-joshsymonds-Work-attain-*) return 0 ;;
            *) return 1 ;;
          esac
        }

        # Split projects/ by classifier into personal/ and work/.
        # Caller passes the source dir; we walk its immediate subdirs.
        split_projects() {
          local src="$1"
          [ -d "$src" ] || return 0
          for proj in "$src"/*; do
            [ -d "$proj" ] || continue
            local name
            name="$(${pkgs.coreutils}/bin/basename "$proj")"
            local dest_profile=personal
            is_work_dir "$name" && dest_profile=work
            ${pkgs.rsync}/bin/rsync -a --no-owner --no-group "$proj/" "$BUCKET/$dest_profile/projects/$name/" || true
          done
        }

        # Rescue the legacy ~/.claude-shared/ layout into the bucket + local.
        # projects/ gets split by is_work_dir; everything else goes to
        # personal/ since sessions/todos/tasks are by sessionId and we
        # can't recover the originating profile from name alone (and
        # they're small, and personal is the safe default).
        if [ -d "$SHARED" ] && [ ! -L "$SHARED" ] && [ ! -f "$MARKER" ]; then
          if has_content "$SHARED"; then
            echo "claudeUnifiedState: migrating $SHARED -> $BUCKET (projects split by ~/Work/attain rule)" >&2
            split_projects "$SHARED/projects"
            for d in sessions todos tasks; do
              [ -d "$SHARED/$d" ] && ${pkgs.rsync}/bin/rsync -a --no-owner --no-group "$SHARED/$d/" "$BUCKET/personal/$d/" || true
            done
            for d in file-history shell-snapshots; do
              [ -d "$SHARED/$d" ] && ${pkgs.rsync}/bin/rsync -a "$SHARED/$d/" "$LOCAL/$d/" || true
            done
            BAK="$HOME/.claude-shared.bak-$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)"
            ${pkgs.coreutils}/bin/mv "$SHARED" "$BAK" || true
            echo "claudeUnifiedState: previous ~/.claude-shared moved to $BAK" >&2
          else
            ${pkgs.coreutils}/bin/rm -rf "$SHARED" || true
          fi
          ${pkgs.coreutils}/bin/touch "$MARKER"
        fi

        # Symlink + per-dir rescue. For each target:
        #  - if it's already the right symlink, leave it alone;
        #  - if it's a real dir with data, rsync into the destination
        #    (bucket dirs refuse a merge when both sides have data; local
        #    dirs always merge because file-history/shell-snapshots are
        #    naturally union-by-session-id), then delete and symlink;
        #  - if it's missing or an empty dir, just symlink.
        ensure_linked() {
          local target="$1" want="$2" mode="$3"  # mode: bucket | local
          if [ -L "$target" ]; then
            cur="$(${pkgs.coreutils}/bin/readlink "$target")"
            if [ "$cur" != "$want" ]; then
              ${pkgs.coreutils}/bin/rm "$target"
              ${pkgs.coreutils}/bin/ln -s "$want" "$target"
            fi
            return
          fi
          if [ -d "$target" ]; then
            if has_content "$target"; then
              if [ "$mode" = "bucket" ] && has_content "$want"; then
                echo "claudeUnifiedState: BOTH $target and $want have data; leaving as-is. Resolve manually." >&2
                return
              fi
              echo "claudeUnifiedState: rescuing $target -> $want" >&2
              ${pkgs.rsync}/bin/rsync -a --no-owner --no-group "$target/" "$want/" || true
            fi
            ${pkgs.coreutils}/bin/rm -rf "$target"
          fi
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$target")"
          ${pkgs.coreutils}/bin/ln -s "$want" "$target"
        }

        for base in .claude .claude-work; do
          profile="personal"
          [ "$base" = ".claude-work" ] && profile="work"
          ${pkgs.coreutils}/bin/mkdir -p "$HOME/$base"
          for d in projects sessions todos tasks; do
            ensure_linked "$HOME/$base/$d" "$BUCKET/$profile/$d" bucket
          done
          ensure_linked "$HOME/$base/file-history" "$LOCAL/file-history" local
          ensure_linked "$HOME/$base/shell-snapshots" "$LOCAL/shell-snapshots" local
        done
        )
      '');

    # Render the work profile's real settings.json from settings.base.json +
    # the current backend mode. Must run after linkGeneration so the new
    # generation's settings.base.json is in place. On a first-ever activation
    # the agenix mount may not exist yet; cwrender degrades to a no-Bedrock
    # render with a loud warning and the next `cwswitch`/activation fixes it.
    activation.claudeWorkSettingsRender = lib.hm.dag.entryAfter ["linkGeneration"] ''
      # Legacy cleanup: settings.json used to be an HM-managed store symlink;
      # remove it so cwrender's atomic mv never writes through a stale link.
      if [ -L "$HOME/.claude-work/settings.json" ]; then
        run rm "$HOME/.claude-work/settings.json"
      fi
      run ${cwrender}/bin/cwrender || echo "claudeWorkSettingsRender: cwrender failed — work profile may lack a settings.json until the next activation or cwswitch." >&2
    '';

    activation.claudeDirectoryPermissions = lib.hm.dag.entryAfter ["writeBoundary" "claudeUnifiedState"] ''
      set -euo pipefail
      for base in ".claude" ".claude-work"; do
        for dir in "$base" "$base/bin" "$base/commands" "$base/hooks" "$base/projects" "$base/statsig" "$base/todos"; do
          # Skip symlinks: post-NFS rollout, projects/todos point at the
          # NFS bucket which is owned by anonuid=1024 (all_squash). User
          # can't chmod those, and the share permissions are governed
          # Synology-side anyway.
          if [ -d "$HOME/$dir" ] && [ ! -L "$HOME/$dir" ]; then
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

    # Shimmer as a default user-scope MCP server in BOTH profiles. Claude
    # Code reads user-scope MCP from .claude.json's top-level `mcpServers`
    # (NOT settings.json, which only gates MCP permissions) — verified
    # against `claude mcp add -s user` on 2.1.x. Personal config is
    # $HOME/.claude.json (CLAUDE_CONFIG_DIR unset); work is
    # $HOME/.claude-work/.claude.json. These files are runtime-mutable
    # (OAuth, caches), so we MERGE (never overwrite) and only rewrite when
    # the entry differs — idempotent, preserves any other servers.
    # Reachable only from tailnet machines authed as your Tailscale user;
    # off-tailnet hosts just show it unavailable (harmless).
    activation.claudeShimmerMcp = lib.hm.dag.entryAfter ["claudeDirectoryPermissions"] ''
      set -euo pipefail
      SHIMMER_MCP='{"type":"http","url":"https://ultraviolet.tail82223.ts.net:8443/mcp"}'
      for prefs in "$HOME/.claude.json" "$HOME/.claude-work/.claude.json"; do
        mkdir -p "$(dirname "$prefs")"
        [ -f "$prefs" ] || echo '{}' > "$prefs"
        if ! ${pkgs.jq}/bin/jq -e --argjson s "$SHIMMER_MCP" \
            '.mcpServers.shimmer == $s' "$prefs" >/dev/null 2>&1; then
          ${pkgs.jq}/bin/jq --argjson s "$SHIMMER_MCP" \
            '.mcpServers = ((.mcpServers // {}) + {shimmer: $s})' \
            "$prefs" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs"
        fi
      done
    '';

    # Codex is the Gambit worker/finder executor in BOTH profiles (the
    # executor registry routes Gambit dispatch through it regardless of
    # profile). Use the pinned Nix binary so Claude never depends on PATH
    # or a mutable Codex install. The server reuses this user's existing
    # ~/.codex ChatGPT authentication and returns each completed Codex
    # thread as a tool result.
    activation.claudeCodexMcp = lib.hm.dag.entryAfter ["claudeShimmerMcp"] ''
      set -euo pipefail
      CODEX_MCP=${lib.escapeShellArg (builtins.toJSON codexExecutorConfig.mcpServer)}
      for prefs in "$HOME/.claude.json" "$HOME/.claude-work/.claude.json"; do
        mkdir -p "$(dirname "$prefs")"
        [ -f "$prefs" ] || echo '{}' > "$prefs"
        if ! ${pkgs.jq}/bin/jq -e --argjson c "$CODEX_MCP" \
            '.mcpServers.codex == $c' "$prefs" >/dev/null 2>&1; then
          ${pkgs.jq}/bin/jq --argjson c "$CODEX_MCP" \
            '.mcpServers = ((.mcpServers // {}) + {codex: $c})' \
            "$prefs" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs"
        fi
      done
    '';

    # Clear the per-model "launch effort pin" in both profiles. When a new
    # model ships (Opus 4.7/4.8, Fable 5), Claude Code pins it to a
    # conservative launch-default effort and IGNORES the persisted
    # effortLevel from settings.json until the user bumps effort for that
    # model once — an acknowledgement recorded as unpin<Model>LaunchEffort
    # in .claude.json (NOT settings.json). The resolver reads it at session
    # start: pinned -> launch default; unpinned -> settings.json effortLevel.
    #
    # Our settings.json is a read-only Nix store symlink, so the normal
    # interactive unpin (/effort) fails with EROFS and can never write the
    # flag — leaving settings.json's "xhigh" permanently overridden by the
    # pin. We set the flags here so settings.json stays authoritative.
    # Same merge discipline as claudeShimmerMcp: .claude.json is
    # runtime-mutable, so MERGE and only rewrite when a flag is missing.
    # The check/assignment expressions below are generated from
    # modelRegistry's unpinKey field (see that `let`-block definition);
    # new models pick up automatically once added there.
    activation.claudeEffortUnpin = lib.hm.dag.entryAfter ["claudeDirectoryPermissions"] ''
      set -euo pipefail
      for prefs in "$HOME/.claude.json" "$HOME/.claude-work/.claude.json"; do
        mkdir -p "$(dirname "$prefs")"
        [ -f "$prefs" ] || echo '{}' > "$prefs"
        if ! ${pkgs.jq}/bin/jq -e \
            '${unpinCheckExpr}' \
            "$prefs" >/dev/null 2>&1; then
          ${pkgs.jq}/bin/jq \
            '${unpinAssignExpr}' \
            "$prefs" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs"
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

  # notifyd — the per-user notification daemon. The `cc-tools notify` hook
  # (settings.json Notification/SessionEnd; the Stop turn-end hook was
  # removed 2026-07) is a fire-and-forget client that hands each hook
  # payload to this daemon over a unix socket at
  # $XDG_RUNTIME_DIR/cc-tools/notifyd.sock and exits in milliseconds. The
  # daemon owns decide/judge/dedupe/watchdog/delivery in one serialized
  # process; if it is unreachable the client falls back inline (deterministic
  # send, no judge) so a ping is never lost.
  #
  # PATH carries the two binaries the daemon shells out to: `claude` for the
  # judge that composes turn-end summaries, and `tmux` for presence detection
  # (is the user looking at the pane the frame came from). The ntfy URL/token
  # ride the same agenix secret-file env the interactive hook uses — a
  # systemd user service does NOT inherit home.sessionVariables, so they are
  # set explicitly here; without a URL the daemon fail-fasts at startup.
  config.systemd.user.services.cc-tools-notifyd = {
    Unit = {
      Description = "cc-tools notifyd — serialized turn-end notification daemon";
      After = ["default.target"];
    };
    Service = {
      # The ntfy secrets are read in a shell wrapper rather than passed as
      # *_FILE env: home-manager agenix leaves the runtime dir unexpanded in
      # the secret path (literal "''${XDG_RUNTIME_DIR}/agenix/..."), and
      # systemd's Environment= does not expand it — only bash, at runtime,
      # does. Same reason ntfy-notify reads its secret in-shell. The daemon
      # fail-fasts if the URL is empty, so a missing secret surfaces loudly.
      ExecStart = pkgs.writeShellScript "cc-tools-notifyd-start" ''
        export CC_TOOLS_NTFY_URL
        CC_TOOLS_NTFY_URL="$(cat "${config.age.secrets."ntfy-url".path}")"
        export CC_TOOLS_NTFY_TOKEN
        CC_TOOLS_NTFY_TOKEN="$(cat "${config.age.secrets."ntfy-token".path}")"
        exec ${cc-tools}/bin/cc-tools notifyd
      '';
      Restart = "on-failure";
      RestartSec = 5;
      Environment = [
        "PATH=${lib.makeBinPath [pkgs.claudeCodeCli pkgs.tmux pkgs.git pkgs.coreutils]}"
      ];
    };
    Install.WantedBy = ["default.target"];
  };
}
