# Shared by the commonframe classes: the cf runner user and its Nix and package setup.
{pkgs, ...}: {
  users.users.cf = {
    isNormalUser = true;
    uid = 1001;
    linger = true;
    openssh.authorizedKeys.keys = import ../../../lib/ssh-keys.nix;
  };

  ec2Fleet.s3Cache = {
    prefix = "commonframe/";
    path = "/home/cf/.cache/commonframe";
    user = "cf";
  };

  nix.settings.trusted-users = ["cf"];

  environment.systemPackages = with pkgs; [devenv git rsync procps];
}
