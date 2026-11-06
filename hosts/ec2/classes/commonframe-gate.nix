args @ {
  lib,
  pkgs,
  ...
}: {
  # Taken in by import and merged here, not through `imports`: module imports
  # reorder the trusted users list in nix.conf and would change the gate's toplevel.
  config = lib.mkMerge [
    (import ./commonframe.nix args)
    {
      # Busy while a cf-owned tiers.sh runs. The guard runs as root, so the
      # shell it spawns is not matched by pgrep -u cf.
      ec2Fleet.busyCommand = "${pkgs.procps}/bin/pgrep -u cf -f tiers.sh >/dev/null";
    }
  ];
}
