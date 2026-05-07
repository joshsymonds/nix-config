# testhost — fixture for the installer VM test.
#
# Minimal direct consumer of modules/disko/btrfs-impermanence.nix and the
# install pipeline. Deliberately does NOT import hosts/common.nix (NFS mounts
# to NAS, determinate-nix, production user keys), does NOT use lanzaboote
# (separate test concern). The two markers (bad-key in authorized_keys and
# /etc/test-marker) are the assertions the future VM test will check.
{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./disko.nix
    ../../modules/linux-base
    ../../modules/nix/defaults.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # Initrd modules: virtio for qemu, plus the standard storage drivers so
  # the same config could in principle run on bare metal under qemu-passthru
  # for manual smoke testing.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "ahci"
    "sd_mod"
    "nvme"
  ];

  networking = {
    hostName = "testhost";
    useDHCP = true;
    firewall.allowedTCPPorts = [22];
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  users.users.joshsymonds = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    hashedPassword = ""; # passwordless console; sshd PasswordAuthentication = false above keeps SSH locked
    openssh.authorizedKeys.keys = [
      # Bad-SSH-key marker. Valid base64 ed25519 wire format (32 NUL bytes
      # of key material), but obviously-fake. The VM test asserts this exact
      # string is present in authorized_keys after install — proving the
      # host config evaluation actually applied during nixos-install.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA testhost-marker"
    ];
  };
  users.groups.joshsymonds = {};

  # Passwordless sudo for wheel — the VM test drives commands via console.
  security.sudo.wheelNeedsPassword = false;

  # Test-marker assertions. Two distinct markers:
  #   /etc/test-marker — written from nix on every boot. Confirms nixos-install
  #     ran AND the host config was applied AND ephemeral-root regeneration works.
  #   /etc/test-persist-marker — touched on first boot, persisted via the
  #     btrfs-impermanence persistFiles list. Confirms /persist survives the
  #     @root-blank rollback. (Asserted-present after a second reboot in the
  #     VM test.)
  environment.etc."test-marker".text = "TESTHOST-INSTALLED-OK\n";

  systemd.services.touch-persist-marker = {
    description = "Touch /etc/test-persist-marker on first boot for impermanence test";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/touch /etc/test-persist-marker";
    };
  };

  system.stateVersion = "25.05";
}
