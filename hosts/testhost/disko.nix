# testhost disk layout — minimal consumer of modules/disko/btrfs-impermanence.nix.
#
# Same sentinel pattern as gnomon: bootstrap.sh / install.sh substitutes the
# device path at install time. This is the unit under test for the install
# pipeline, so the sentinel string MUST match what install.sh greps for.
{...}: {
  imports = [
    ../../modules/disko/btrfs-impermanence.nix
  ];

  btrfs-impermanence = {
    enable = true;
    device = "/dev/disk/by-id/REPLACE-AT-INSTALL";
    luks.enable = true;
    swapSizeGiB = 0; # tests don't need swap
    # Module defaults cover persistDirectories (/etc/ssh, /etc/age,
    # /var/lib/nixos, /var/lib/systemd) and persistFiles
    # (/etc/machine-id, /etc/adjtime). Adding /persist/test-marker
    # for the future VM test's persistence-survives-reboot assertion.
    persistFiles = [
      "/etc/machine-id"
      "/etc/adjtime"
      "/etc/test-persist-marker"
    ];
  };
}
