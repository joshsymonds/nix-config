{
  config,
  hostname,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.claudeCode;

  # Gambit skills marketplace as a directory-source. Pinned via flake.lock;
  # updates with `nix flake update gambit`.
  gambitSrc = inputs.gambit.packages.${pkgs.stdenv.hostPlatform.system}.default;
  gambitRev = inputs.gambit.rev or "unknown";

  # Whether this host runs the ChatGPT/Codex upstream, and therefore whether
  # patchbay publishes the chatgpt/* routes the gambit rung agents point at.
  # `or false` keeps hosts that never import home-manager/patchbay — darwin
  # (ninuan), echelon — evaluating.
  codexUpstream = config.services.patchbay.codexUpstream.enable or false;

  # Generate settings.json with gambit's marketplace entry injected at build
  # time, pointing at the Nix store path. Keeps a single source of truth
  # between settings.json's extraKnownMarketplaces and the runtime
  # known_marketplaces.json populated by activation.
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

  # `or false` keeps hosts that never import home-manager/patchbay — darwin
  # (ninuan), echelon — evaluating, and null there means "no local gateway",
  # leaving the vendor endpoint in place.
  patchbayBaseUrl =
    if (config.services.patchbay.enable or false)
    then "http://127.0.0.1:${toString config.services.patchbay.port}"
    else null;

  # The prefix-less base URL selects patchbay's personal context. A project
  # that bills elsewhere selects its context with a /ctx/<name> base URL in
  # its own .claude/settings.json — activation.claudeAttainContext below
  # stamps the Attain repos.
  settingsJson = mkSettingsJson "base" (
    lib.optionalAttrs (patchbayBaseUrl != null) {
      env.ANTHROPIC_BASE_URL = patchbayBaseUrl;
    }
  );

  # ccrender — render the real ~/.claude/settings.json from the HM-deployed
  # settings.base.json, merging in the patchbay caller-key header.
  #
  # The header is a secret, so settings.json cannot be a store symlink. And
  # it must be settings.json rather than launch env: the bg-agent daemon's
  # spare workers spawn with a SCRUBBED env — ANTHROPIC_MODEL,
  # ANTHROPIC_DEFAULT_*_MODEL and ANTHROPIC_CUSTOM_HEADERS are among the
  # vars stripped (observed on CLI 2.1.204 via /proc environ diff,
  # 2026-07-09) — and read settings.json's env block at spawn instead.
  # Without the header there, patchbay's gate refuses every inject/sigv4
  # request from any background session. settings.local.json cannot carry it
  # either: its env block is ignored entirely (probed empirically, same
  # date).
  #
  # Output is a real file replaced atomically, chmod 600: it carries the
  # caller key's VALUE, which is fine in $HOME (a runtime file) and would
  # never be fine in the world-readable Nix store.
  ccrender = pkgs.writeShellApplication {
    name = "ccrender";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text = ''
      base="$HOME/.claude/settings.base.json"
      out="$HOME/.claude/settings.json"

      if [ ! -r "$base" ]; then
        echo "ccrender: $base missing or unreadable — is home-manager deployed?" >&2
        exit 1
      fi

      # Merged only on hosts that run a local patchbay: with no gateway the
      # request goes straight to api.anthropic.com and the key must never
      # ride along.
      caller_key=""
      ${lib.optionalString (patchbayBaseUrl != null) ''
        key_file=/run/agenix/patchbay-caller-key
        if [ -r "$key_file" ]; then
          caller_key=$(cat "$key_file")
        else
          echo "ccrender: caller key $key_file unreadable (patchbay-caller-key agenix secret not deployed?) — rendering WITHOUT the X-Patchbay-Key header; patchbay will refuse every inject/sigv4 request." >&2
        fi
      ''}

      tmp="$out.ccrender.$$"
      jq --arg caller_key "$caller_key" '
        .env += (
          if $caller_key == "" then {} else {ANTHROPIC_CUSTOM_HEADERS: ("X-Patchbay-Key: " + $caller_key)} end
        )
      ' "$base" > "$tmp"
      chmod 600 "$tmp"
      mv "$tmp" "$out"
      echo "ccrender: $out rendered"
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
    "fable-5-1" = {
      # No unpinKey: CC 2.1.257 pins launch effort only for opus-4-7/4-8 and
      # fable-5 (see unpin<Model>LaunchEffort in the binary); fable-5-1 honors
      # settings.json effortLevel directly.
      model = "claude-fable-5-1";
      defaultEffort = "high";
      unpinKey = null;
      aliases = ["fable"];
    };
    "fable-5" = {
      # Plain id since CC 2.1.257: its static model table has native_1m for
      # fable-5, so the [1m] marker the 2.1.234-era entry needed is redundant.
      model = "claude-fable-5";
      defaultEffort = "high";
      unpinKey = "unpinFable5LaunchEffort";
      aliases = [];
    };
    "opus-5" = {
      model = "claude-opus-5";
      defaultEffort = "xhigh";
      # CC 2.1.257 dropped unpinOpus5LaunchEffort (only opus-4-7/4-8 and
      # fable-5 keys remain in the binary), so there is no pin to clear.
      unpinKey = null;
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
  # behavior: it edits, commits, and deploys the Nix-tracked settings.json.
  cmswitch = pkgs.writeShellApplication {
    name = "cmswitch";
    runtimeInputs = [pkgs.jq pkgs.git pkgs.coreutils];
    text = ''
      # Switch the repo's home-manager/claude-code/settings.json to a
      # different model/effort, commit just that file, deploy via `update`,
      # and bounce the Claude Code background-agent daemon so new work picks
      # up the change.
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

      # Bounce the bg-agent daemon so new work picks up the new default —
      # but only if nothing is actively "working" (a bounce would kill
      # in-flight work; leave the daemon up and let it pick up the new
      # default on its own next restart instead).
      working=0
      if [ -d "$HOME/.claude/jobs" ]; then
        for state_file in "$HOME"/.claude/jobs/*/state.json; do
          [ -f "$state_file" ] || continue
          if grep -q '"state": *"working"' "$state_file" 2>/dev/null; then
            working=$((working + 1))
          fi
        done
      fi
      if [ "$working" -gt 0 ]; then
        echo "$working job(s) working — daemon left running; new bg jobs may use the old default until it restarts"
      else
        claude daemon stop --any >/dev/null 2>&1 || true
        echo "daemon bounce requested"
      fi

      echo "''${cur_model:-(unset)} ''${cur_effort:-(unset)} -> $name $effort (commit $sha) deployed"
    '';
  };

  # ── Gambit rungs ────────────────────────────────────────────────────────
  # The rung definitions, the subagent renderer, and both rung/role maps live
  # in ./gambit-rungs.nix so tests/gambit-rung-agents.nix can import the same
  # data this module installs. See that file for what a rung is and why it
  # has to be a subagent definition.
  #
  # On the -ro variants: "read-only" here is a denylist plus a prompt-level
  # directive, and that is strictly weaker than the OS-level
  # `sandbox = "read-only"` the deleted Codex executor path used to get.
  # `disallowedTools` removes the editing tools, sub-dispatch, and every MCP
  # server, but Bash survives — the read-only contracts (scout, steelman,
  # finder, verifier) need git and search inspection, so the variant's body
  # spells out the bounded command set instead. A determined prompt could
  # still talk Bash into writing; the destructive-guard hook is what backstops
  # the worst of that.
  inherit
    (import ./gambit-rungs.nix {inherit lib pkgs;})
    rungAgentEntries
    gambitModelsFull
    gambitModelsClaudeOnly
    ;

  # Agents dir as a linkFarm, mirroring skillsDir: the checked-in ./agents
  # definitions plus, on Codex-upstream hosts, the generated rung agents.
  # Off a Codex-upstream host the chatgpt/* routes are not published, so a
  # rung agent would point at a port nothing listens on.
  agentsDir = let
    staticAgents = lib.attrNames (
      lib.filterAttrs (
        name: type: type == "regular" && lib.hasSuffix ".md" name
      ) (builtins.readDir ./agents)
    );
  in
    pkgs.linkFarm "claude-agents" (
      (map (n: {
          name = n;
          path = ./agents + "/${n}";
        })
        staticAgents)
      ++ lib.optionals codexUpstream rungAgentEntries
    );

  gambitModelsJson = builtins.toJSON (
    if codexUpstream
    then gambitModelsFull
    else gambitModelsClaudeOnly
  );

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
          path = "/home/joshsymonds/.claude-local/skills/team-status";
        }
        {
          name = "harvest-weekly";
          path = "/home/joshsymonds/.claude-local/skills/harvest-weekly";
        }
      ]
    );
in {
  options.programs.claudeCode.hostContext = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = ''
      Per-host markdown rendered to ~/.claude/host.md,
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
      ])
      ++ [pkgs.claudeCodeCli pkgs.claude-swap cmswitch ccrender];

    # Add npm global bin to PATH for user-installed packages
    sessionPath = lib.mkAfter [
      "$HOME/.npm-global/bin"
    ];

    # Set npm prefix to user directory.
    sessionVariables = {
      NPM_CONFIG_PREFIX = "$HOME/.npm-global";
      CLAUDE_CODE_ENABLE_TASKS = "true";
      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
      CLAUDE_CODE_NO_FLICKER = "1";
      CLAUDE_CODE_TMUX_TRUECOLOR = "1";
      # The only reliable way to disable auto-updates for native installs.
      # settings.json autoUpdater.disabled is cosmetic; ~/.claude.json autoUpdates
      # is bypassed by autoUpdatesProtectedForNative for native installMethod.
      DISABLE_AUTOUPDATER = "1";
    };

    # Create and manage the ~/.claude config directory. Runtime state
    # (.credentials.json, ~/.claude.json, projects/, todos/, history.jsonl,
    # plugins/installed_plugins.json) is owned by claude itself.
    file = let
      commandFiles = builtins.readDir ./commands;
      commandEntries =
        lib.filterAttrs (
          name: type: type == "regular" && lib.hasSuffix ".md" name
        )
        commandFiles;
      # CLAUDE.md is written as text (not symlinked) so the trailing
      # @host.md and @fleet.md imports resolve relative to ~/.claude
      # rather than the nix store path the symlink would otherwise expose.
      # Per Claude Code's memory docs, relative @-imports resolve relative
      # to the file containing them.
      claudeMdText =
        builtins.readFile ./CLAUDE.md
        + ''


          @host.md
          @fleet.md
        '';

      commandFileAttrs =
        lib.mapAttrs' (
          name: _: lib.nameValuePair ".claude/commands/${name}" {source = ./commands/${name};}
        )
        commandEntries;
    in
      lib.mkMerge [
        commandFileAttrs
        {
          # ccrender produces the real settings.json from this at activation
          # (see the ccrender comment above for why it can't be a store
          # symlink).
          ".claude/settings.base.json".source = settingsJson;
          ".claude/CLAUDE.md".text = claudeMdText;
          ".claude/host.md".text = cfg.hostContext;
          ".claude/fleet.md".source = ./fleet.md;
          ".claude/agents".source = agentsDir;
          ".claude/skills".source = skillsDir;
          ".claude/hooks/aws-profile-mirror.sh" = {
            source = ./hooks/aws-profile-mirror.sh;
            executable = true;
          };
          ".claude/hooks/destructive-guard.py" = {
            source = ./hooks/destructive-guard.py;
            executable = true;
          };
          ".claude/hooks/usage-summary-refresh.sh" = {
            source = ./hooks/usage-summary-refresh.sh;
            executable = true;
          };
          ".claude/.keep".text = "";
          ".claude/statsig/.keep".text = "";
          ".claude/commands/.keep".text = "";
          # The rung/role map gambit dispatches from: GPT rungs wherever the
          # Codex upstream runs, Claude-only elsewhere. See gambitModelsFull
          # above.
          ".claude/gambit/models.json".text = gambitModelsJson;
        }
      ];

    # Unify stateful dirs across hosts. Transcripts (projects, sessions,
    # todos, tasks) live on NFS at /mnt/claude/${HOSTNAME}/personal/, so
    # each host owns its bucket and gnomon can read every host's transcripts
    # for the DMS bar widget. High-churn small-file state (file-history,
    # shell-snapshots) stays LOCAL at ~/.claude-local/ to spare the NAS
    # btrfs metadata storm.
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
        for d in projects sessions todos tasks; do
          ${pkgs.coreutils}/bin/mkdir -p "$BUCKET/personal/$d"
        done
        ${pkgs.coreutils}/bin/mkdir -p "$LOCAL/file-history" "$LOCAL/shell-snapshots"

        # One-shot migration: fold the retired /mnt/claude/<host>/work/
        # bucket into personal/ so its sessions stay resumable. Copies,
        # never deletes — the work/ tree stays behind for manual cleanup.
        if [ -d "$BUCKET/work" ] && [ ! -f "$BUCKET/personal/.work-merged" ]; then
          for d in projects sessions todos tasks; do
            if [ -d "$BUCKET/work/$d" ]; then
              ${pkgs.rsync}/bin/rsync -a --no-owner --no-group "$BUCKET/work/$d/" "$BUCKET/personal/$d/" || true
            fi
          done
          ${pkgs.coreutils}/bin/touch "$BUCKET/personal/.work-merged"
          echo "claudeUnifiedState: merged $BUCKET/work into $BUCKET/personal (originals left in place)" >&2
        fi

        # Helper: report whether a path is a non-empty directory.
        has_content() {
          [ -d "$1" ] && [ -n "$(${pkgs.findutils}/bin/find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]
        }

        # Detect whether any pre-NFS data needs rescuing. Two sources:
        #  (a) the old ~/.claude-shared/ unified dir (when it has real data
        #      and the marker is absent — the original layout on gnomon), or
        #  (b) any ~/.claude/{projects,sessions,todos,tasks} that is itself
        #      a real directory with content (the layout on hosts that never
        #      went through the .claude-shared intermediate step, e.g.
        #      ultraviolet, vermissian).
        needs_rescue=false
        if [ -d "$SHARED" ] && [ ! -L "$SHARED" ] && [ ! -f "$MARKER" ]; then
          has_content "$SHARED" && needs_rescue=true || true
        fi
        if [ "$needs_rescue" = false ]; then
          for d in projects sessions todos tasks file-history shell-snapshots; do
            tgt="$HOME/.claude/$d"
            if [ -d "$tgt" ] && [ ! -L "$tgt" ] && has_content "$tgt"; then
              needs_rescue=true
              break
            fi
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

        # Rescue the legacy ~/.claude-shared/ layout into the bucket + local.
        if [ -d "$SHARED" ] && [ ! -L "$SHARED" ] && [ ! -f "$MARKER" ]; then
          if has_content "$SHARED"; then
            echo "claudeUnifiedState: migrating $SHARED -> $BUCKET" >&2
            for d in projects sessions todos tasks; do
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

        ${pkgs.coreutils}/bin/mkdir -p "$HOME/.claude"
        for d in projects sessions todos tasks; do
          ensure_linked "$HOME/.claude/$d" "$BUCKET/personal/$d" bucket
        done
        ensure_linked "$HOME/.claude/file-history" "$LOCAL/file-history" local
        ensure_linked "$HOME/.claude/shell-snapshots" "$LOCAL/shell-snapshots" local
        )
      '');

    # Render the real settings.json from settings.base.json. Must run after
    # linkGeneration so the new generation's settings.base.json is in place.
    # On a first-ever activation the agenix mount may not exist yet;
    # ccrender degrades to a headerless render with a loud warning and the
    # next activation fixes it.
    activation.claudeSettingsRender = lib.hm.dag.entryAfter ["linkGeneration"] ''
      # Legacy cleanup: settings.json used to be an HM-managed store symlink;
      # remove it so ccrender writes a real file in its place.
      if [ -L "$HOME/.claude/settings.json" ]; then
        run rm "$HOME/.claude/settings.json"
      fi
      run ${ccrender}/bin/ccrender || echo "claudeSettingsRender: ccrender failed — ~/.claude may lack a settings.json until the next activation." >&2
    '';

    # The writable skill working dirs (rosters, ledgers, tokens — state the
    # skills accumulate at runtime) live outside the store at
    # ~/.claude-local/skills/, where the skills linkFarm points. One-shot
    # move from their previous home in the retired ~/.claude-work profile.
    activation.claudeSkillState = lib.hm.dag.entryAfter ["writeBoundary"] ''
      run mkdir -p "$HOME/.claude-local/skills"
      for skill in team-status harvest-weekly; do
        if [ -d "$HOME/.claude-work/$skill" ] && [ ! -e "$HOME/.claude-local/skills/$skill" ]; then
          run mv "$HOME/.claude-work/$skill" "$HOME/.claude-local/skills/$skill"
        fi
      done
    '';

    # Stamp each Attain repo's project settings with the /ctx/attain
    # patchbay context. Which account answers a request is registry policy,
    # but WHICH context a session speaks to is the one fact patchbay cannot
    # know — the base URL carries it, and a project's own
    # .claude/settings.json is where Claude Code reads a per-project base
    # URL from. Merges the env key into any existing file, preserving
    # everything else; the file stays untracked in the employer repos.
    activation.claudeAttainContext = lib.hm.dag.entryAfter ["writeBoundary"] (
      lib.optionalString (patchbayBaseUrl != null) ''
        attain_root="$HOME/Work/attain"
        attain_url="${patchbayBaseUrl}/ctx/attain"
        if [ -d "$attain_root" ]; then
          for project in "$attain_root" "$attain_root"/*/; do
            project="''${project%/}"
            [ -d "$project" ] || continue
            # The root itself (sessions launched at ~/Work/attain) and each
            # git repo under it. Claude Code resolves a session's project
            # root to the enclosing repo, so launches anywhere inside a repo
            # read that repo's file.
            if [ "$project" != "$attain_root" ] && [ ! -e "$project/.git" ]; then
              continue
            fi
            sfile="$project/.claude/settings.json"
            run mkdir -p "$project/.claude"
            [ -f "$sfile" ] || echo '{}' > "$sfile"
            if ! ${pkgs.jq}/bin/jq -e --arg u "$attain_url" '.env.ANTHROPIC_BASE_URL == $u' "$sfile" >/dev/null 2>&1; then
              ${pkgs.jq}/bin/jq --arg u "$attain_url" '.env = ((.env // {}) + {ANTHROPIC_BASE_URL: $u})' "$sfile" > "$sfile.tmp" && mv "$sfile.tmp" "$sfile"
            fi
          done
        fi
      ''
    );

    activation.claudeDirectoryPermissions = lib.hm.dag.entryAfter ["writeBoundary" "claudeUnifiedState"] ''
      set -euo pipefail
      for dir in ".claude" ".claude/bin" ".claude/commands" ".claude/hooks" ".claude/projects" ".claude/statsig" ".claude/todos"; do
        # Skip symlinks: post-NFS rollout, projects/todos point at the
        # NFS bucket which is owned by anonuid=1024 (all_squash). User
        # can't chmod those, and the share permissions are governed
        # Synology-side anyway.
        if [ -d "$HOME/$dir" ] && [ ! -L "$HOME/$dir" ]; then
          chmod 755 "$HOME/$dir"
        fi
      done
      if [ ! -d "$HOME/.claude/debug" ]; then
        mkdir -p "$HOME/.claude/debug"
        chmod 755 "$HOME/.claude/debug"
      fi

      # Remove vim mode if previously set in Claude Code preferences
      # (~/.claude.json).
      prefs="$HOME/.claude.json"
      if [ -f "$prefs" ] && ${pkgs.jq}/bin/jq -e '.editorMode == "vim"' "$prefs" >/dev/null 2>&1; then
        ${pkgs.jq}/bin/jq 'del(.editorMode)' "$prefs" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs"
      fi
    '';

    # Shimmer as a default user-scope MCP server. Claude Code reads
    # user-scope MCP from ~/.claude.json's top-level `mcpServers` (NOT
    # settings.json, which only gates MCP permissions) — verified against
    # `claude mcp add -s user` on 2.1.x. The file is runtime-mutable
    # (OAuth, caches), so we MERGE (never overwrite) and only rewrite when
    # the entry differs — idempotent, preserves any other servers.
    # Reachable only from tailnet machines authed as your Tailscale user;
    # off-tailnet hosts just show it unavailable (harmless).
    activation.claudeShimmerMcp = lib.hm.dag.entryAfter ["claudeDirectoryPermissions"] ''
      set -euo pipefail
      SHIMMER_MCP='{"type":"http","url":"https://ultraviolet.tail82223.ts.net:8443/mcp"}'
      prefs="$HOME/.claude.json"
      [ -f "$prefs" ] || echo '{}' > "$prefs"
      if ! ${pkgs.jq}/bin/jq -e --argjson s "$SHIMMER_MCP" \
          '.mcpServers.shimmer == $s' "$prefs" >/dev/null 2>&1; then
        ${pkgs.jq}/bin/jq --argjson s "$SHIMMER_MCP" \
          '.mcpServers = ((.mcpServers // {}) + {shimmer: $s})' \
          "$prefs" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs"
      fi
    '';

    # Retire the Codex MCP server from the runtime prefs. Gambit's
    # non-Claude rungs are subagent definitions now (see the rung agent
    # block above), so nothing dispatches through mcp__codex__* any more.
    # But the activation that used to live here MERGED the server into
    # ~/.claude.json — runtime-mutable user prefs Nix never regenerates.
    # Dropping the generator alone would orphan the entry, and every session
    # would go on spawning the Codex MCP server forever. So delete exactly
    # that one key, preserving everything else in the file and its
    # permissions. Idempotent, silent when absent.
    activation.claudeCodexMcpCleanup = lib.hm.dag.entryAfter ["claudeShimmerMcp"] ''
      set -euo pipefail
      prefs="$HOME/.claude.json"
      if [ -f "$prefs" ] && ${pkgs.jq}/bin/jq -e '.mcpServers | has("codex")' "$prefs" >/dev/null 2>&1; then
        # Subshell so the cleanup trap is scoped to this rewrite and cannot
        # outlive it into the rest of the activation script. The umask is
        # inside its own subshell because the SHELL creates $tmp for the
        # redirect, before jq or chmod --reference ever run: .claude.json
        # carries OAuth state, and it must not exist world-readable even for
        # that instant. Any failure under set -e removes $tmp rather than
        # stranding a half-written copy of the prefs next to the original.
        (
          tmp="$prefs.codex-cleanup.$$"
          trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
          (umask 077; ${pkgs.jq}/bin/jq 'del(.mcpServers.codex)' "$prefs" > "$tmp")
          ${pkgs.coreutils}/bin/chmod --reference="$prefs" "$tmp"
          mv "$tmp" "$prefs"
        )
        echo "claudeCodexMcpCleanup: removed .mcpServers.codex from $prefs" >&2
      fi
    '';

    # Clear the per-model "launch effort pin". When a new model ships
    # (Opus 4.7/4.8, Fable 5), Claude Code pins it to a conservative
    # launch-default effort and IGNORES the persisted effortLevel from
    # settings.json until the user bumps effort for that model once — an
    # acknowledgement recorded as unpin<Model>LaunchEffort in .claude.json
    # (NOT settings.json). The resolver reads it at session start:
    # pinned -> launch default; unpinned -> settings.json effortLevel.
    #
    # Our settings.json is re-rendered from the Nix-managed base at every
    # activation (see ccrender), so anything the interactive unpin (/effort)
    # writes into it is transient. We set the flags here so settings.json's
    # effortLevel stays authoritative. Same merge discipline as
    # claudeShimmerMcp: .claude.json is runtime-mutable, so MERGE and only
    # rewrite when a flag is missing. The check/assignment expressions below
    # are generated from modelRegistry's unpinKey field (see that
    # `let`-block definition); new models pick up automatically once added
    # there.
    activation.claudeEffortUnpin = lib.hm.dag.entryAfter ["claudeDirectoryPermissions"] ''
      set -euo pipefail
      prefs="$HOME/.claude.json"
      [ -f "$prefs" ] || echo '{}' > "$prefs"
      if ! ${pkgs.jq}/bin/jq -e \
          '${unpinCheckExpr}' \
          "$prefs" >/dev/null 2>&1; then
        ${pkgs.jq}/bin/jq \
          '${unpinAssignExpr}' \
          "$prefs" > "$prefs.tmp" && mv "$prefs.tmp" "$prefs"
      fi
    '';

    # Declaratively install gambit. Rather than shell out to
    # `claude plugin install` (which wants to modify settings.json — futile
    # when ccrender re-renders it from the Nix base at every activation), we
    # populate the runtime state by hand:
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

      mkdir -p "$HOME/.claude/plugins"
      KM="$HOME/.claude/plugins/known_marketplaces.json"
      INSTALLED="$HOME/.claude/plugins/installed_plugins.json"
      CACHE_PARENT="$HOME/.claude/plugins/cache/gambit/gambit"
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
