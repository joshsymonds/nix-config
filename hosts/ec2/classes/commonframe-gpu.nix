{pkgs, ...}: {
  imports = [
    ./nvidia.nix
    ./commonframe.nix
  ];

  environment.systemPackages = [pkgs.xvfb];

  # Busy while a cf commonframe-* user unit is active. The guard runs as root,
  # so systemctl reaches the cf user manager through -M.
  ec2Fleet.busyCommand = "${pkgs.systemd}/bin/systemctl --user -M cf@ is-active --quiet 'commonframe-*' || exit 1";
}
