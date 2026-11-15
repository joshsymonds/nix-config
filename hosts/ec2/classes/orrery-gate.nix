# orrery's gate box: orrery's scripts/gate-remote.sh runs `just check`, `just android-test` or `nix flake check` here
# as the orrery user, from a checkout under ~/gate, inside the repo's devenv shell.
{pkgs, ...}: {
  users.users.orrery = {
    isNormalUser = true;
    uid = 1002;
    linger = true;
    openssh.authorizedKeys.keys = import ../../../lib/ssh-keys.nix;
  };

  # Mounted beside orrery's Go caches (~/.cache/orrery), never over them: the Go build cache renames and locks files,
  # which a Mountpoint mount does not serve.
  ec2Fleet.s3Cache = {
    prefix = "orrery/";
    path = "/home/orrery/.cache/fleet";
    user = "orrery";
  };

  # devenv adds its own binary cache to the builds it asks for, which the daemon honours only for a trusted user.
  nix.settings.trusted-users = ["orrery"];

  # Busy while a gate runs: gate-remote.sh runs each command under a shell named orrery-gate-run. The guard runs as
  # root, so the shell it spawns is not matched by pgrep -u orrery.
  ec2Fleet.busyCommand = "${pkgs.procps}/bin/pgrep -u orrery -f orrery-gate-run >/dev/null";

  # nix with flakes comes from the base (modules/nix/defaults.nix). orrery's own tools come from its devenv shell;
  # the box supplies what runs before that shell exists.
  environment.systemPackages = with pkgs; [devenv git just procps rsync tmux];
}
