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

    performance.profile = "router";
    performance.cpuVendor = "intel";

    boot = {
      kernelModules = ["coretemp" "kvm-intel"];
      supportedFilesystems = ["ntfs"];
    };

    # Echelon sits in a friend's house bridging his LAN (192.168.1.0/24, enp2s0)
    # into our tailnet, so a static route on his router (192.168.1.1) sends
    # 172.31.0.0/24 traffic to 192.168.1.200. The only intended destination is
    # ultraviolet (jellyfin/etc.) — not the rest of the household subnet, and
    # not anything in the friend's network from our side.
    networking = {
      useDHCP = false;
      hostName = "echelon";
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
      # SNAT friend's traffic onto the tailnet so ultraviolet's response
      # routes back through echelon (which then conntrack-undoes the SNAT).
      nat = {
        enable = true;
        internalInterfaces = [self.interface];
        externalInterface = "tailscale0";
      };

      nftables.enable = true;
      firewall = {
        enable = true;
        allowPing = true;
        checkReversePath = "loose";
        trustedInterfaces = ["tailscale0"];
        allowedUDPPorts = [51820 config.services.tailscale.port];
        allowedTCPPorts = [22 80 443];

        # Default-drop FORWARD; only allow friend's LAN to reach ultraviolet.
        # Return traffic is allowed via conntrack. Anything else (friend → other
        # 172.31.x hosts, our tailnet → friend's LAN) is dropped.
        filterForward = true;
        extraForwardRules = ''
          ct state established,related accept
          iifname "${self.interface}" oifname "tailscale0" ip daddr 172.31.0.66 accept
        '';
      };
    };

    services = {
      rpcbind.enable = true;

      tailscale = {
        enable = true;
        package = pkgs.tailscale;
        # "both" — accept the 172.31.0.0/24 subnet route advertised by
        # ultraviolet AND act as a forwarder for friend's traffic. The latter
        # also enables ip_forward sysctls automatically.
        useRoutingFeatures = "both";
        # Clear unintended advertisements left over from earlier flailing —
        # was --advertise-exit-node and --advertise-routes=0.0.0.0/0,::/0,
        # 192.168.1.0/24. Echelon should be a passive tailnet member that
        # only forwards friend → ultraviolet.
        extraSetFlags = [
          "--advertise-routes="
          "--advertise-exit-node=false"
        ];
      };
    };

    environment.systemPackages = with pkgs; [];

    # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
    system.stateVersion = "25.05";
  }
