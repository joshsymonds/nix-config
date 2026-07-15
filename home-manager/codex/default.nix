{
  hostname,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cc-tools = inputs.cc-tools.packages.${pkgs.stdenv.hostPlatform.system}.default;
  gambitPackages = inputs.gambit.packages.${pkgs.stdenv.hostPlatform.system};
  gambitHasCodex = gambitPackages ? codex && inputs.gambit ? lib && inputs.gambit.lib ? version;
  gambitCodex =
    if gambitHasCodex
    then gambitPackages.codex
    else null;
  gambitVersion =
    if gambitHasCodex
    then inputs.gambit.lib.version
    else "unavailable";
  gambitCodexCache =
    if gambitHasCodex
    then
      pkgs.runCommand "gambit-codex-cache-${gambitVersion}" {} ''
        mkdir -p "$out/${gambitVersion}"
        cp -R ${gambitCodex}/. "$out/${gambitVersion}/"
      ''
    else null;
  codexConfig = import ./managed-config.nix {
    inherit gambitHasCodex lib pkgs;
    ccTools = cc-tools;
  };
  subagentIsolation = import ./subagent-isolation.nix;
  codexAgentRoles = {
    escalation = {
      description = "Escalate a previously blocked or failed task with the strongest available reasoning.";
      instructions = "Follow the task and any referenced contract exactly. Use the additional reasoning budget to resolve the reported blocker without broadening scope.";
      model = "gpt-5.6-sol";
      reasoningEffort = "max";
    };
    explorer = {
      description = "Answer a specific read-only codebase question quickly with file and line evidence.";
      instructions = "Investigate read-only. Do not edit files. Answer only the requested question with checkable file:line evidence and report NOT FOUND when appropriate.";
      model = "gpt-5.6-luna";
      reasoningEffort = "max";
      sandboxMode = "read-only";
    };
    finder = {
      description = "Perform independent, high-recall code review using the referenced finder contract.";
      instructions = "Read and follow the referenced finder contract before reviewing. Do not edit files. Report only evidence-backed findings within the supplied review boundary.";
      model = "gpt-5.6-sol";
      reasoningEffort = "xhigh";
      sandboxMode = "read-only";
    };
    scout = {
      description = "Perform bounded read-only discovery for a Gambit workflow with file and line evidence.";
      instructions = "Read and follow the referenced scout contract before investigating. Do not edit files. Return file:line evidence or an explicit NOT FOUND result.";
      model = "gpt-5.6-luna";
      reasoningEffort = "max";
      sandboxMode = "read-only";
    };
    test-runner = {
      description = "Run an objective test, build, or lint command and report its exact result without editing source files.";
      instructions = "Run only the requested verification commands. Make no source edits. Report the exit status, pass/fail counts, and relevant failure output exactly.";
      model = "gpt-5.6-luna";
      reasoningEffort = "low";
    };
    verifier = {
      description = "Independently confirm or refute candidate review findings using the referenced verifier contract.";
      instructions = "Read and follow the referenced verifier contract before acting. Do not edit files. Classify only the supplied candidates using fresh, quoted evidence.";
      model = "gpt-5.6-sol";
      reasoningEffort = "xhigh";
      sandboxMode = "read-only";
    };
    worker = {
      description = "Implement one bounded, well-specified coding task from a complete worker brief.";
      instructions = "Read and follow the referenced worker contract before acting. Own only the files and responsibility assigned in the brief, and return the contract's required terminal state.";
      model = "gpt-5.6-sol";
      reasoningEffort = "xhigh";
    };
  };
  # Codex 0.144.4 discovers standalone custom agent roles under
  # ~/.codex/agents. The role owns the concrete model and effort so skills
  # dispatch by agent_type without embedding provider-specific model IDs.
  codexAgentFiles = lib.mapAttrs' (name: role:
    lib.nameValuePair ".codex/agents/${name}.toml" {
      text = ''
        name = ${builtins.toJSON name}
        description = ${builtins.toJSON role.description}
        developer_instructions = ${builtins.toJSON role.instructions}
        model = ${builtins.toJSON role.model}
        model_reasoning_effort = ${builtins.toJSON role.reasoningEffort}
        ${lib.optionalString (role ? sandboxMode) "sandbox_mode = ${builtins.toJSON role.sandboxMode}"}
        ${subagentIsolation}
      '';
    })
  codexAgentRoles;
in {
  # Codex persists project trust, hook hashes, and interactive settings by
  # rewriting ~/.codex/config.toml. Keep that file real and writable, while
  # treating codexConfig as an authoritative baseline for the keys declared
  # above. Runtime-only keys survive each activation; declared keys are
  # reasserted, matching the mutable-state merge discipline used for Claude.
  #
  # yq-go provides a lossless-enough TOML <-> JSON bridge for Codex's config
  # types; jq's recursive object merge lets the Nix baseline win without
  # deleting hooks.state or additional projects written by Codex.
  home.activation.codexConfig = lib.hm.dag.entryAfter ["linkGeneration"] ''
    (
    set -euo pipefail

    BASE="${codexConfig}"
    TARGET="$HOME/.codex/config.toml"
    WORK="$(${pkgs.coreutils}/bin/mktemp -d)"
    trap '${pkgs.coreutils}/bin/rm -rf "$WORK"' EXIT

    ${pkgs.coreutils}/bin/mkdir -p "$HOME/.codex"
    ${pkgs.yq-go}/bin/yq -p=toml -o=json '.' "$BASE" > "$WORK/base.json"

    if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
      if ! ${pkgs.yq-go}/bin/yq -p=toml -o=json '.' "$TARGET" > "$WORK/current.json"; then
        echo "codexConfig: $TARGET is not valid TOML; preserving it unchanged." >&2
        exit 0
      fi
    else
      echo '{}' > "$WORK/current.json"
    fi

    ${pkgs.jq}/bin/jq -s '.[0] * .[1]' \
      "$WORK/current.json" "$WORK/base.json" > "$WORK/merged.json"

    current="$(${pkgs.jq}/bin/jq -Sc . "$WORK/current.json")"
    merged="$(${pkgs.jq}/bin/jq -Sc . "$WORK/merged.json")"
    if [ ! -L "$TARGET" ] && [ "$current" = "$merged" ]; then
      exit 0
    fi

    ${pkgs.yq-go}/bin/yq -p=json -o=toml '.' "$WORK/merged.json" > "$WORK/config.toml"
    ${pkgs.coreutils}/bin/chmod 600 "$WORK/config.toml"
    ${pkgs.coreutils}/bin/mv -f "$WORK/config.toml" "$TARGET"
    )
  '';

  # Codex's rollout JSONL files are its transcripts. Mirror Claude's storage
  # split: active and archived transcripts live in this host's NAS bucket,
  # while SQLite databases, caches, logs, history, and shell snapshots remain
  # local (SQLite and high-churn small files are poor NFS workloads).
  #
  # Migration is deliberately conservative: do nothing if the NAS is down;
  # wait for active Codex processes before moving local data; refuse to merge
  # two non-empty trees; and retain migrated local data as a timestamped
  # backup instead of deleting it.
  home.activation.codexTranscriptState = lib.hm.dag.entryAfter ["writeBoundary"] (let
    inScope = builtins.elem hostname ["gnomon" "ultraviolet" "vermissian"];
  in
    if !inScope
    then ''
      echo "codexTranscriptState: ${hostname} out of scope; skipping." >&2
    ''
    else ''
      (
      set -euo pipefail

      BUCKET="/mnt/claude/${hostname}/codex"

      # Trigger the automount, then verify it before touching any local path.
      ${pkgs.coreutils}/bin/ls /mnt/claude >/dev/null 2>&1 || true
      if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/claude; then
        echo "codexTranscriptState: /mnt/claude not mounted (NAS down?). Refusing to touch ~/.codex transcript symlinks." >&2
        exit 0
      fi

      for d in sessions archived_sessions; do
        ${pkgs.coreutils}/bin/mkdir -p "$BUCKET/$d"
      done

      has_content() {
        [ -d "$1" ] && [ -n "$(${pkgs.findutils}/bin/find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]
      }

      needs_rescue=false
      for d in sessions archived_sessions; do
        target="$HOME/.codex/$d"
        if [ -d "$target" ] && [ ! -L "$target" ] && has_content "$target"; then
          needs_rescue=true
          break
        fi
      done

      if [ "$needs_rescue" = true ]; then
        if ${pkgs.procps}/bin/pgrep -u "$USER" -fa 'codex' 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -qE '(^|/| )codex([^/ ]*|)( |$)'; then
          echo "codexTranscriptState: local transcripts still need migration and an active Codex process was detected on ${hostname}." >&2
          echo "codexTranscriptState: stop all Codex sessions, then re-run 'update'; no transcript paths were changed." >&2
          exit 0
        fi
      fi

      ensure_linked() {
        local target="$1" want="$2"
        if [ -L "$target" ]; then
          current="$(${pkgs.coreutils}/bin/readlink "$target")"
          if [ "$current" != "$want" ]; then
            ${pkgs.coreutils}/bin/rm "$target"
            ${pkgs.coreutils}/bin/ln -s "$want" "$target"
          fi
          return
        fi

        if [ -d "$target" ]; then
          if has_content "$target"; then
            if has_content "$want"; then
              echo "codexTranscriptState: BOTH $target and $want have data; leaving the local directory in place. Resolve manually." >&2
              return
            fi
            echo "codexTranscriptState: migrating $target -> $want" >&2
            # The NAS export forbids chgrp/chown; -a would fail with exit 23.
            ${pkgs.rsync}/bin/rsync -a --no-owner --no-group "$target/" "$want/"
            backup="$target.bak-$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)"
            ${pkgs.coreutils}/bin/mv "$target" "$backup"
            echo "codexTranscriptState: retained previous local data at $backup" >&2
          else
            ${pkgs.coreutils}/bin/rmdir "$target"
          fi
        fi

        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$target")"
        ${pkgs.coreutils}/bin/ln -s "$want" "$target"
      }

      for d in sessions archived_sessions; do
        ensure_linked "$HOME/.codex/$d" "$BUCKET/$d"
      done
      )
    '');

  # Gambit's Codex-native bundle is exposed through the implicit personal
  # marketplace. The marketplace path is rooted at $HOME, so
  # ./plugins/gambit resolves to the Nix-managed ~/plugins/gambit symlink.
  # Codex ignores symlinked SKILL.md files during discovery. Build the whole
  # versioned cache as one immutable tree so its directories and files are
  # real; Home Manager then symlinks only the cache root. The enabled config
  # block avoids mutable `codex plugin add` state, while INSTALLED_BY_DEFAULT
  # records the same policy in the marketplace UI.
  home.file =
    codexAgentFiles
    // {
      # Keep the submission helper pinned with the rest of the Codex install.
      # It lives in the OpenAI Developers plugin upstream, but does not require
      # installing that plugin's Platform connector or its unrelated skills.
      ".codex/skills/chatgpt-app-submission".source = "${inputs.openai-plugins}/plugins/openai-developers/skills/chatgpt-app-submission";

      "plugins/gambit" = lib.mkIf gambitHasCodex {source = gambitCodex;};
      ".codex/plugins/cache/personal/gambit" = lib.mkIf gambitHasCodex {source = gambitCodexCache;};
      ".agents/plugins/marketplace.json" = lib.mkIf gambitHasCodex {
        text = builtins.toJSON {
          name = "personal";
          interface.displayName = "Personal";
          plugins = [
            {
              name = "gambit";
              source = {
                source = "local";
                path = "./plugins/gambit";
              };
              policy = {
                installation = "INSTALLED_BY_DEFAULT";
                authentication = "ON_INSTALL";
              };
              category = "Coding";
            }
          ];
        };
      };
    };
}
