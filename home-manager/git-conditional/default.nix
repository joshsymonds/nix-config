{
  config,
  osConfig,
  ...
}: let
  home = config.home.homeDirectory;
in {
  # Per-directory git settings whose contents stay out of this public repo:
  # the conditional include and what it applies are encrypted, and decrypted
  # into fixed paths so git and ssh can read them. Each host has its own key
  # (secrets/user/git-conditional-key-<host>.age). The settings use ssh-vpn,
  # so a host importing this needs a VPN exit (home-manager/vpn-exit).
  programs.git.includes = [{path = config.age.secrets."git-conditional".path;}];
  age.secrets = {
    "git-conditional" = {
      file = ../../secrets/user/git-conditional.age;
      path = "${home}/.config/git/conditional";
    };
    "git-conditional-config" = {
      file = ../../secrets/user/git-conditional-config.age;
      path = "${home}/.config/git/conditional-config";
    };
    "git-conditional-key" = {
      file = ../../secrets/user/git-conditional-key-${osConfig.networking.hostName}.age;
      path = "${home}/.config/git/conditional-key";
    };
  };
}
