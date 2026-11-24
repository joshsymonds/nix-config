{pkgs}: let
  roles = import ../home-manager/codex/agent-roles.nix;
  codexModule = ../home-manager/codex/default.nix;
in
  pkgs.runCommand "codex-agent-roster-check" {} ''
    test ${pkgs.lib.escapeShellArg roles.worker.model} = gpt-6-luna
    test ${pkgs.lib.escapeShellArg roles.worker.reasoningEffort} = high
    test ${pkgs.lib.escapeShellArg roles.worker.serviceTier} = fast
    test ${pkgs.lib.escapeShellArg roles.escalation.model} = gpt-6-sol
    test ${pkgs.lib.escapeShellArg roles.escalation.reasoningEffort} = high
    for forbidden in \
      '".agents/plugins/marketplace.json"'; do
      if ${pkgs.gnugrep}/bin/grep -Fq "$forbidden" ${codexModule}; then
        echo "Codex module still installs retired plugin path: $forbidden" >&2
        exit 1
      fi
    done
    touch "$out"
  ''
