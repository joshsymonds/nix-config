# stygianlibrary disk layout — halmasuit test rig on a Thunderbolt
# NVMe enclosure (ACASIS TBU405AIR) containing a WD_BLACK SN7100 500GB.
#
# SAFETY LOCK: the device path is hardcoded to a serial-locked by-id
# path. The serial number `253645803652` is baked into the drive's
# firmware and is unique to this physical drive. Disko will only
# operate on a disk that matches this exact path.
#
# If this config were accidentally run on a host without this drive
# plugged in (e.g. on husband's PC, on gnomon without the TB enclosure
# attached), disko would fail with "device not found" — it CANNOT
# fall back to another disk. This is the marriage-safety property.
#
# btrfs-impermanence module same shape as gnomon's, with two
# deliberate differences:
#   - luks.enable = false. Halmasuit test rig, no sensitive data; the
#     LUKS-unlock pain across reboots wastes more time than encryption
#     would protect. If sensitive data ever lands here, switch to
#     `luks.enable = true` + TPM autoenroll.
#   - swapSizeGiB = 4 (vs gnomon's 32). The rig is a build / test
#     scratch — no swap-heavy workloads.
{...}: {
  imports = [
    ../../modules/disko/btrfs-impermanence.nix
  ];

  btrfs-impermanence = {
    enable = true;

    # ACASIS TBU405AIR Thunderbolt enclosure holding WD_BLACK SN7100
    # serial 253645803652. The kernel exposes the drive inside the
    # enclosure as an NVMe device; the by-id path is identical
    # regardless of whether the enclosure is plugged into gnomon's TB
    # port or another machine's, because the serial is on the drive
    # firmware, not the host.
    device = "/dev/disk/by-id/nvme-WD_BLACK_SN7100_500GB_253645803652";

    luks.enable = false;
    swapSizeGiB = 4;

    persistDirectories = [
      "/etc/ssh"
      "/etc/age"
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/tailscale"
      # lanzaboote signing keys (sbctl) — preserved across @root-blank
      # rollback so each rebuild doesn't have to re-sign UKIs.
      "/var/lib/sbctl"
    ];
  };
}
