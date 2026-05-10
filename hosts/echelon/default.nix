let
  network = import ../../lib/network.nix;
  self = network.hosts.echelon;
  subnet = network.subnets.${self.subnet};
in
  {
    inputs,
    lib,
    config,
    pkgs,
    ...
  }: {
    imports = [
      inputs.hardware.nixosModules.common-cpu-intel
      ./hardware-configuration.nix

      # Headless-server hardening (BT module blacklist on top of fleet-wide)
      ../../modules/linux-base/server-hardening.nix
    ];

    # Hardware setup
    hardware = {
      cpu = {
        intel.updateMicrocode = true;
      };
      graphics = {
        enable = true;
        enable32Bit = true;
        extraPackages = with pkgs; [
          intel-media-driver
          libvdpau-va-gl
        ];
      };
      enableAllFirmware = true;
    };

    # More aggressive than common.nix periodic optimise
    nix.settings.auto-optimise-store = true;

    # Performance tuning
    performance.profile = "router";
    performance.cpuVendor = "intel";

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1; # Enable IPv4 forwarding
      "net.ipv6.conf.all.forwarding" = 1; # Enable IPv6 forwarding if needed
    };

    networking = {
      useDHCP = false;
      hostName = "echelon";
      firewall = {
        enable = true;
        allowPing = true;
        checkReversePath = "loose";
        trustedInterfaces = ["tailscale0"];
        allowedUDPPorts = [51820 config.services.tailscale.port];
        allowedTCPPorts = [22 80 443];
      };
      defaultGateway = subnet.gateway;
      nameservers = subnet.nameservers;
      interfaces.${self.interface} = {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = self.ip;
            prefixLength = subnet.prefixLength;
          }
        ];
      };
      nat = {
        enable = true;
        internalInterfaces = [self.interface];
        externalInterface = "tailscale0";
      };
    };

    boot = {
      kernelModules = ["coretemp" "kvm-intel"];
      supportedFilesystems = ["ntfs"];
      kernelParams = [];
    };

    # Services
    services = {
      rpcbind.enable = true;

      tailscale = {
        enable = true;
        package = pkgs.tailscale;
        useRoutingFeatures = "both";
      };
    };

    # Environment
    environment = {
      systemPackages = with pkgs; [
      ];
    };

    # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
    system.stateVersion = "25.05";
  }
