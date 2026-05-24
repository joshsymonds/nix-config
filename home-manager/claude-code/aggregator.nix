# Gnomon-only cache-warm timer for the DMS bar.
#
# get-claude-usage hits Anthropic's /api/oauth/usage endpoint and
# aggregates per-host summary.json files from /mnt/claude/*/personal/.
# It writes ~/.claude/usage-cache.json (the 120s server-side cache)
# as a side effect; the DMS widget reads from there.
#
# Running it on a 10-minute systemd timer means the bar shows recent
# numbers whenever DMS opens the popout, even if the widget hasn't
# polled in a while (after wake-from-sleep, after a session pause,
# etc.). Persistent=true catches missed firings.
#
# Imported only on gnomon — the other in-scope hosts run the summary
# WRITER (claude-code/transcripts.nix) but not this READER. Only gnomon
# has the bar.
{
  hostname,
  inputs,
  pkgs,
  ...
}: let
  getClaudeUsage = pkgs.writeShellApplication {
    name = "get-claude-usage";
    runtimeInputs = with pkgs; [jq coreutils findutils gnused gawk curl];
    text = builtins.readFile "${inputs.dms-claudecode}/get-claude-usage";
  };

  # Discard stdout — the script's side effect (writing ~/.claude/
  # usage-cache.json) is what we want, not its KEY=VALUE printout.
  runner = pkgs.writeShellScript "claude-usage-cache-warm-runner" ''
    ${getClaudeUsage}/bin/get-claude-usage >/dev/null || true
  '';
in {
  assertions = [
    {
      assertion = hostname == "gnomon";
      message = "claude-code/aggregator.nix should only be imported on gnomon (got ${hostname}). The DMS bar lives there.";
    }
  ];

  home.packages = [getClaudeUsage];

  systemd.user.services.claude-usage-cache-warm = {
    Unit = {
      Description = "Pre-warm Claude usage cache for the DMS bar widget";
      After = ["network-online.target"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${runner}";
    };
  };

  systemd.user.timers.claude-usage-cache-warm = {
    Unit.Description = "Refresh Claude usage cache every 10 minutes";
    Timer = {
      OnBootSec = "3min";
      OnUnitActiveSec = "10min";
      Persistent = true;
      Unit = "claude-usage-cache-warm.service";
    };
    Install.WantedBy = ["timers.target"];
  };
}
