{pkgs, ...}: {
  users.users.cf = {
    isNormalUser = true;
    linger = true;
    openssh.authorizedKeys.keys = import ../../../lib/ssh-keys.nix;
  };

  nix.settings.trusted-users = ["cf"];

  environment.systemPackages = with pkgs; [devenv git rsync procps];

  # Busy while a cf-owned tiers.sh runs. The guard runs as root, so the
  # shell it spawns is not matched by pgrep -u cf.
  ec2Fleet.busyCommand = "${pkgs.procps}/bin/pgrep -u cf -f tiers.sh >/dev/null";
}
