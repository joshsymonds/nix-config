{...}: {
  imports = [
    ../aarch64-darwin.nix
  ];

  programs.git.settings.user.signingkey = "0x8B0D6CFA07BB41A5";
}
