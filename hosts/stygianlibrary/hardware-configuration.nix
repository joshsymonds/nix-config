# stygianlibrary hardware — hardware-identical to gnomon
# (Ryzen 7 9800X3D + RTX 5070 Ti + Gigabyte X870 + IT8696E super-I/O).
#
# Only the disk differs: stygianlibrary lives on the WD_BLACK SN7100
# in an ACASIS Thunderbolt enclosure. Everything else mirrors gnomon's
# kernel module set, microcode policy, and initrd contents so any
# hardware-specific bug on gnomon reproduces here.
#
# Boot path:
#   - lanzaboote (signed UKIs in /boot/EFI/Linux/)
#   - systemd-boot fallback wired by gnomon's loader config (mirrored
#     in the host default.nix)
#   - Thunderbolt subsystem must authorize the enclosure BEFORE the
#     NVMe inside enumerates as a block device. An initrd udev rule
#     in default.nix handles this.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Kernel modules needed in initrd to find the root device.
  # Standard AM5 set + thunderbolt (the rig boots from a TB-attached
  # NVMe) + xhci_pci (USB host controller, also TB-tunneled).
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "thunderbolt"
  ];

  # NO NVIDIA modules in initrd: stygianlibrary is a VFIO host. The
  # NVIDIA GPU is bound to vfio-pci at boot (see kernelParams in
  # default.nix) and never touched by the host kernel. The guest VM
  # claims it via PCIe passthrough.
  #
  # Thunderbolt initrd module IS needed: root lives on a TB-attached
  # NVMe and the TB controller has to enumerate the device before the
  # rootfs mount can find it.
  boot.initrd.kernelModules = [
    "thunderbolt"
  ];

  # Post-pivot kernel modules. kvm-amd for any virt work; it87 for
  # the Gigabyte X870's IT8696E fan controller (out-of-tree, see
  # default.nix). v4l2loopback omitted — no webcam workflows on the
  # test rig.
  boot.kernelModules = ["kvm-amd" "it87"];

  # Same out-of-tree it87 fork as gnomon (mainline doesn't have the
  # X870 IT8696E chip ID).
  boot.extraModulePackages = [
    config.boot.kernelPackages.it87
  ];

  # AMD microcode — Zen 5 errata, including the documented
  # RDSEED32 bug (AMD-SB-7055). Mirrors gnomon.
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;
  hardware.enableAllFirmware = true;
  hardware.enableRedistributableFirmware = true;

  # Same nixpkgs platform pin as the gnomon profile.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
