{...}: {
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

    # Trust is normally persisted by codex rewriting config.toml, which
    # fails against this read-only store symlink — declare trusted
    # projects here instead (one table per directory).
    [projects."/home/joshsymonds/nix-config"]
    trust_level = "trusted"

    [tui]
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
}
