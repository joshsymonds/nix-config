{pkgs, ...}: {
  environment.systemPackages = with pkgs; [devenv git rsync];

  systemd.tmpfiles.rules = [
    "d /work 0755 joshsymonds users -"
    "d /data 0755 joshsymonds users -"
  ];
}
