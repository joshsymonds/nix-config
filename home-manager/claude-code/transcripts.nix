# Per-host transcript summarizer — bash script + systemd user timer.
#
# Each in-scope Claude host (gnomon, ultraviolet, vermissian) runs the
# `claude-usage-summary` script every 10 minutes, once per profile, and
# writes a small JSON file into its NFS bucket at
# /mnt/claude/${hostname}/{personal,work}/summary.json.
#
# The DMS bar widget on gnomon reads those summary files via
# `get-claude-usage` instead of crawling every host's JSONL. This keeps
# the Synology platter drives quiet during widget polling — the bar
# touches 3 tiny JSON files, not hundreds of MB of session transcripts.
{
  hostname,
  inputs,
  pkgs,
  ...
}: let
  # Wrap the script from dms-claudecode as a runtime executable. The
  # flake input is a flake=false source; we pull just this one script
  # via writeShellApplication so its runtime deps come from nixpkgs
  # rather than the user's environment. writeShellApplication also
  # runs shellcheck at build time as a free extra check.
  claudeUsageSummary = pkgs.writeShellApplication {
    name = "claude-usage-summary";
    runtimeInputs = with pkgs; [jq coreutils findutils gnused gawk];
    text = builtins.readFile "${inputs.dms-claudecode}/claude-usage-summary";
  };
  bucket = "/mnt/claude/${hostname}";

  # Run both profiles in one ExecStart with `|| true` between them so a
  # failure in one profile doesn't fail the timer (e.g. work profile
  # might not exist on every host yet, and that should be a quiet
  # zero-summary, not a unit failure).
  runner = pkgs.writeShellScript "claude-usage-summary-runner" ''
    set -u
    ${claudeUsageSummary}/bin/claude-usage-summary --profile personal --out ${bucket}/personal/summary.json || true
    ${claudeUsageSummary}/bin/claude-usage-summary --profile work     --out ${bucket}/work/summary.json     || true
  '';
in {
  home.packages = [claudeUsageSummary];

  systemd.user.services.claude-usage-summary = {
    Unit = {
      Description = "Per-host Claude Code transcript summary writer (personal + work)";
      # The NFS bucket has to be reachable; wait on the automount unit
      # so we don't spam stderr right after boot before /mnt/claude is
      # mounted on first access.
      After = ["network-online.target"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${runner}";
    };
  };

  systemd.user.timers.claude-usage-summary = {
    Unit.Description = "Run claude-usage-summary every 10 minutes";
    Timer = {
      OnBootSec = "2min";
      OnUnitActiveSec = "10min";
      Persistent = true;
      Unit = "claude-usage-summary.service";
    };
    Install.WantedBy = ["timers.target"];
  };
}
