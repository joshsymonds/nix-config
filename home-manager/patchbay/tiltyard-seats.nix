# The tiltyard judgment roster: the models a judgment run compares, keyed by the
# plain identifier a caller names inside patchbay's `tiltyard` context. Every
# entry pins a model, because a comparison is only worth recording if each name
# resolved to a known model rather than to whatever the caller happened to ask
# for.
#
# Split out of home-manager/patchbay/default.nix so the roster has one home and
# stays free of `config` and `lib`: tests/gambit-rung-agents.nix imports this
# file directly to assert the roster's shape without evaluating a host, the same
# arrangement chatgpt-models.nix has.
#
# Selectors are plain identifiers rather than the `vendor/model` spelling the
# personal context uses. They are what a judgment run writes down next to a
# result, so they are short and carry the pinned version in the name.
#
# An entry with `seat` names a Seat the registry already publishes and adds none;
# the rest become Seats of their own under `tiltyard-<selector>`.
{
  # The three Claude candidates ride the caller's own OAuth credential on
  # forward Seats — the subscription already pays for them, so a judgment run
  # spends nothing extra. `model` is the whole point of the Seat: a forward Seat
  # without it would serve whatever model the request already named.
  fable51 = {
    upstream = "https://api.anthropic.com";
    auth_mode = "forward";
    model = "claude-fable-5-1";
  };
  opus5 = {
    upstream = "https://api.anthropic.com";
    auth_mode = "forward";
    model = "claude-opus-5";
  };
  sonnet5 = {
    upstream = "https://api.anthropic.com";
    auth_mode = "forward";
    model = "claude-sonnet-5";
  };

  # The open-weight candidates, billed per token to the household OpenRouter key
  # on the same gateway and the same key as the personal context's OpenRouter
  # Seats, so their ledger rows are comparable with everything else.
  glm53 = {
    upstream = "https://openrouter.ai/api";
    auth_mode = "inject";
    billing = "metered";
    api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
    model = "z-ai/glm-5.3-flash";
  };
  kimik3 = {
    upstream = "https://openrouter.ai/api";
    auth_mode = "inject";
    billing = "metered";
    api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
    model = "moonshotai/kimi-k3";
  };
  dsv41flash = {
    upstream = "https://openrouter.ai/api";
    auth_mode = "inject";
    billing = "metered";
    api_key_env_file = "PATCHBAY_OPENROUTER_KEY_FILE";
    model = "deepseek/deepseek-v4.1-flash";
  };

  # The self-hosted candidate is the bf16 RunPod pod patchbay already publishes
  # as `runpod/qwen3.8`. A second Seat at the same address would be a second
  # ledger identity for one pod, so this binds the existing Seat by ID.
  qwen38 = {seat = "runpod-qwen3-8";};
}
