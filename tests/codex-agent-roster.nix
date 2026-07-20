{pkgs}: let
  roles = import ../home-manager/codex/agent-roles.nix;
in
  pkgs.runCommand "codex-agent-roster-check" {} ''
    test ${pkgs.lib.escapeShellArg roles.worker.model} = gpt-5.6-luna
    test ${pkgs.lib.escapeShellArg roles.worker.reasoningEffort} = high
    test ${pkgs.lib.escapeShellArg roles.worker.serviceTier} = fast
    test ${pkgs.lib.escapeShellArg roles.escalation.model} = gpt-5.6-sol
    test ${pkgs.lib.escapeShellArg roles.escalation.reasoningEffort} = high
    touch "$out"
  ''
