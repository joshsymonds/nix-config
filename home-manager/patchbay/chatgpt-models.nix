# The ChatGPT/Codex subscription route set patchbay publishes when
# codexUpstream is enabled: route key -> the Seat's upstream identity, `model`
# (the Codex model id) plus the optional `speed` tier the Seat asks for.
#
# Split out of home-manager/patchbay/default.nix so the route keys have one
# home. The gambit rung agents in home-manager/claude-code point at these keys
# by name, and tests/gambit-rung-agents.nix imports this file to prove no rung
# names a route patchbay does not publish, and that the Pi twin of a fast
# route asks Codex for the same tier.
#
# Every model id below is confirmed present in the codex channel's /v1/models.
#
# speed = "fast" is patchbay's Seat field: the Seat writes Anthropic's
# `speed: fast` into every request it carries, and CLIProxyAPI's Claude→Codex
# translator maps that onto the Codex priority service tier — what the Codex
# catalogue calls Fast: 1.5x speed at roughly 2.5x quota. The backend honors
# the tier only on the Responses websocket transport, which is why
# pkgs/cliproxyapi is built from source with the patch that routes priority
# requests there (upstream #4586, closed as not planned).
{
  # GPT-6 Astra: the Claude Code default model on Codex-upstream hosts
  # (home-manager/claude-code/settings.json names this key), and the terminal
  # worker rung. Effort rides Claude Code's output_config.effort, which
  # CLIProxyAPI translates to the Responses reasoning effort — verified
  # 2026-09-05 by comparing reasoning tokens at low vs xhigh, same step as the
  # "(xhigh)" model-id suffix.
  "chatgpt/astra" = {model = "gpt-6-astra";};
  # The capable GPT-5.6 tier at standard speed: the review finders and
  # verifier, and the brainstorming steelman's neighbour.
  "chatgpt/sol" = {model = "gpt-5.6-sol";};
  # The same model on the fast tier. Published for direct use; no gambit rung
  # points at it since the worker ladder's second rung returned to standard
  # speed to spare Codex quota.
  "chatgpt/sol-fast" = {
    model = "gpt-5.6-sol";
    speed = "fast";
  };
  # The fast tier for haiku-slot work and the worker entry rung. Always fast:
  # Luna's whole point is turnaround.
  "chatgpt/luna" = {
    model = "gpt-5.6-luna";
    speed = "fast";
  };
  # The scout rung. Always fast, for the same reason.
  "chatgpt/terra" = {
    model = "gpt-5.6-terra";
    speed = "fast";
  };
}
