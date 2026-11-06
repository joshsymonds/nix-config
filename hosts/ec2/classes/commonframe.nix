# Shared by the commonframe classes: the cf runner user and its Nix and package setup.
{pkgs, ...}: {
  users.users.cf = {
    isNormalUser = true;
    linger = true;
    openssh.authorizedKeys.keys = import ../../../lib/ssh-keys.nix;
  };

  nix.settings.trusted-users = ["cf"];

  environment.systemPackages = with pkgs; [devenv git rsync procps];
}
