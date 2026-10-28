{
  hostname,
  inputs,
  lib,
  pkgs,
  ...
}: let
  codexConfig = import ./managed-config.nix {inherit lib pkgs;};
  subagentIsolation = import ./subagent-isolation.nix;
  codexAgentRoles = import ./agent-roles.nix;
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
        ${lib.optionalString (role ? serviceTier) "service_tier = ${builtins.toJSON role.serviceTier}"}
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
  # types; jq applies the ordinary recursive baseline-wins merge.
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
        exit 1
      fi
    else
      echo '{}' > "$WORK/current.json"
    fi

    ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$WORK/current.json" "$WORK/base.json" > "$WORK/merged.json"

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

  # Codex's rollout JSONL files are its transcripts. Each transcript directory
  # (sessions, archived_sessions) links to ~/.codex-local/<d> on local disk;
  # SQLite databases, caches, logs, history, and shell snapshots stay in
  # ~/.codex as before. The nightly `transcript-sync` job copies the rollouts
  # to the NAS. The one-time `transcript-sync localize` cutover moves the
  # NAS-linked layout local.
  home.activation.codexTranscriptState = lib.hm.dag.entryAfter ["writeBoundary"] (let
    inScope = builtins.elem hostname ["gnomon" "ultraviolet" "vermissian"];
  in
    if !inScope
    then ''
      echo "codexTranscriptState: ${hostname} out of scope; skipping." >&2
    ''
    else ''
      # Subshell + trailing `||`: the outer HM activation script runs under
      # `set -e`, so any failing command in here would abort the entire
      # activation. The `|| echo` after the closing paren turns a phase
      # failure into a logged skip instead.
      (
      set -euo pipefail

      ${pkgs.coreutils}/bin/mkdir -p "$HOME/.codex"

      for d in sessions archived_sessions; do
        target="$HOME/.codex/$d"
        twin="$HOME/.codex-local/$d"
        ${pkgs.coreutils}/bin/mkdir -p "$twin"

        # Test -L before -e: -e follows a symlink, and a link into the NAS
        # automount would trigger it. Existing symlinks are left as they are.
        if [ ! -L "$target" ]; then
          if [ -e "$target" ]; then
            echo "codexTranscriptState: $target is a real path; keeping it." >&2
          else
            ${pkgs.coreutils}/bin/ln -s "$twin" "$target"
          fi
        fi
      done
      ) || echo "codexTranscriptState: phase aborted (see above); the rest of the activation continues." >&2
    '');

  home.file =
    codexAgentFiles
    // {
      # Keep the submission helper pinned with the rest of the Codex install.
      # It lives in the OpenAI Developers plugin upstream, but does not require
      # installing that plugin's Platform connector or its unrelated skills.
      ".codex/skills/chatgpt-app-submission".source = "${inputs.openai-plugins}/plugins/openai-developers/skills/chatgpt-app-submission";
    };
}
