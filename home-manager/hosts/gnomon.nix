{pkgs, ...}: {
  imports = [
    ../desktop-x86_64-linux.nix
  ];

  home.packages = with pkgs; [
    # Gaming auxiliaries (Steam itself is system-level via programs.steam)
    lutris # non-Steam game launcher (GOG, Epic, emulators)
    mangohud # in-game FPS/perf overlay
    protontricks # Proton/Wine troubleshooting for specific games
  ];

  # Same signing key vermissian uses — single user identity across machines
  programs.git.settings.user.signingkey = "0x7DD8F05131AEEC3A";
}
