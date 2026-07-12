{
  inputs,
  pkgs,
  ...
}: let
  cc-tools = inputs.cc-tools.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  # Declarative Codex CLI config. The /statusline interactive picker won't
  # be able to save changes (config.toml is a Nix-store symlink); edit this
  # file and rebuild instead.
  #
  # Status line items mirror what's portable from the cc-tools chip set —
  # model, dir, git branch, context, rate limits. Codex has no native
  # equivalent for the host/AWS/GCloud/K8s chips, so they're absent here.
  home.file.".codex/config.toml".text = ''
    model = "gpt-5.6-sol"
    model_reasoning_effort = "xhigh"

    # Codex passes agent-turn-complete JSON as one argv value. cc-tools
    # normalizes that into the same ntfy delivery path Claude's stdin hooks
    # use, without invoking the Claude transcript/judge pipeline.
    notify = ["${cc-tools}/bin/cc-tools", "notify"]

    # Equivalent to --dangerously-bypass-approvals-and-sandbox. This machine
    # is intentionally configured to let Codex work outside the repo without
    # interrupting for per-command or per-directory confirmation.
    approval_policy = "never"
    sandbox_mode = "danger-full-access"

    # Trust is normally persisted by codex rewriting config.toml, which
    # fails against this read-only store symlink — declare trusted
    # projects here instead (one table per directory).
    [projects."/home/joshsymonds/nix-config"]
    trust_level = "trusted"

    [tui]
    # External notify owns turn-complete delivery. Keep Codex's built-in
    # terminal notification only for approvals, which external notify does
    # not currently emit.
    notifications = ["approval-requested"]
    notification_condition = "unfocused"
    notification_method = "auto"
    status_line = [
      "model-with-reasoning",
      "current-dir",
      "git-branch",
      "context-remaining",
      "five-hour-limit",
      "weekly-limit",
    ]
    status_line_use_colors = true
  '';

  # Keep the submission helper pinned with the rest of the Codex install.
  # It lives in the OpenAI Developers plugin upstream, but does not require
  # installing that plugin's Platform connector or its unrelated skills.
  home.file.".codex/skills/chatgpt-app-submission".source = "${inputs.openai-plugins}/plugins/openai-developers/skills/chatgpt-app-submission";
}
