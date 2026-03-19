let
  network = import ../../lib/network.nix;
  self = network.hosts.bluedesert;
  subnet = network.subnets.${self.subnet};
in
  {
    inputs,
    lib,
    pkgs,
    ...
  }: {
    # You can import other NixOS modules here
    imports = [
      ./home-automation.nix
      ./hardware-configuration.nix
    ];

    # Performance tuning
    performance.profile = "constrained";
    performance.cpuVendor = "intel";

    # Hardware setup (minimal for headless Z-Wave bridge)
    hardware = {
      cpu = {
        intel.updateMicrocode = true;
      };
      # No graphics drivers needed for headless operation
      graphics.enable = false;
      # Only enable specific firmware needed for this hardware
      enableAllFirmware = false;
      enableRedistributableFirmware = true;
    };

    # Host-specific: constrained resource limits (common.nix provides defaults)
    nix.settings = {
      download-buffer-size = 268435456; # 256MB buffer to avoid "buffer full" warnings
      max-substitution-jobs = 4; # Parallel downloads
      cores = 2; # Limit build parallelism on weak CPU
    };

    networking = {
      useDHCP = false;
      hostName = "bluedesert";
      firewall = {
        enable = true;
        checkReversePath = "loose";
        trustedInterfaces = [];
        allowedUDPPorts = [51820];
        allowedTCPPorts = [22 80 443 8080];
      };
      defaultGateway = subnet.gateway;
      nameservers = subnet.nameservers;
      interfaces.${self.interface}.ipv4.addresses = [
        {
          address = self.ip;
          prefixLength = subnet.prefixLength;
        }
      ];
      interfaces.enp1s0.useDHCP = false;
    };

    boot = {
      kernelModules = ["coretemp" "kvm-intel"];
      supportedFilesystems = ["ntfs"];
      kernelParams = [];
      loader = {
        systemd-boot = {
          enable = true;
          configurationLimit = 8;
        };
        efi = {
          canTouchEfiVariables = true;
          efiSysMountPoint = "/boot";
        };
      };
    };

    # Services
    services = {
      rpcbind.enable = true;
    };

    # Environment
    environment = {
      systemPackages = with pkgs; [
      ];

};

    # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
    system.stateVersion = "25.05";
  }
