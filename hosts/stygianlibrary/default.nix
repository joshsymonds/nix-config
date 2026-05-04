{
  inputs,
  lib,
  config,
  pkgs,
  ...
}: {
  imports = [
    inputs.hardware.nixosModules.common-pc
    ./hardware-configuration.nix
    ../../modules/hardware/gpu-nvidia.nix
    ../../modules/services/atticd-cache.nix
    ../../modules/services/delyric-worker.nix
    ../../modules/services/inference-stack.nix
  ];

  hardware.gpu-nvidia.enable = true;
  services.atticd-cache.consumer.enable = true;
  services.inference-stack.enable = true;

  # Performance tuning
  performance.profile = "workstation";
  performance.cpuVendor = "intel";

  # Host-specific: use all cores (common.nix provides defaults; CUDA cache via inference-stack)
  nix.settings = {
    cores = 0;
    max-jobs = "auto";
  };

  networking = {
    hostName = "stygianlibrary";
    useDHCP = false;
    networkmanager.enable = true;
    firewall = {
      enable = true;
      checkReversePath = "loose";
      trustedInterfaces = ["tailscale0"];
      allowedTCPPorts = [22 2022 8188 8888 9090];
      allowedUDPPorts = [config.services.tailscale.port];
    };
  };

  boot = {
    supportedFilesystems = ["ntfs" "vfat"];
    kernelModules = ["coretemp" "kvm-intel"];
    kernelParams = ["kernel.unprivileged_userns_clone=1"];
    kernelPackages = pkgs.linuxPackages_latest;
    initrd = {
      luks.devices.stygianlibrary = {
        device = "/dev/disk/by-partlabel/STYGIAN-LUKS";
        allowDiscards = true;
      };
      kernelModules = ["thunderbolt" "vmd" "xhci_pci"];
      # Auto-authorize Thunderbolt devices as they appear. The LUKS
      # partition (STYGIAN-LUKS) is on a TB-attached NVMe, so the TB
      # controller must be authorized before cryptsetup can see the
      # device. A udev rule reacts to every `add` uevent, which handles
      # chained TB enumeration without the races of a polling loop.
      services.udev.rules = ''
        ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
      '';
    };
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

  hardware = {
    cpu = {
      intel.updateMicrocode = lib.mkDefault true;
      amd.updateMicrocode = lib.mkDefault true;
    };
    enableAllFirmware = true;
  };

  virtualisation.docker.enable = true;

  # ComfyUI is managed by creative-lab/devenv.nix (devenv up)

  services = {
    hardware.bolt.enable = true;
    caddy = {
      enable = true;
      virtualHosts.":8888".extraConfig = ''
        handle /output/* {
          root * /var/lib/comfyui/storage
          file_server browse
        }
        handle {
          reverse_proxy localhost:8188
        }
      '';
      virtualHosts.":9090".extraConfig = ''
        root * /home/joshsymonds/creative-lab/ai-toolkit/output
        file_server browse
      '';
    };
  };

  systemd.services.caddy.serviceConfig = {
    ProtectHome = lib.mkForce "tmpfs";
    BindReadOnlyPaths = ["/home/joshsymonds/creative-lab/ai-toolkit/output"];
  };

  # Delyric vocal separation worker (FastAPI on :9001). Reads/writes songs
  # under /mnt/music/sound-stage; dispatched to by the sound-stage Go server
  # on vermissian. The bindHost must be bindable locally or the unit exits
  # cleanly (by design for dual-boot — absent on Windows = orchestrator 503).
  services.delyric-worker = {
    enable = true;
    package = inputs.sound-stage.packages.${pkgs.stdenv.hostPlatform.system}.delyric-worker;
    bindHost = "172.31.0.98";
    openFirewall = true;
  };

  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
  '';

  programs.nm-applet.enable = true;

  users.users.joshsymonds.extraGroups = ["docker"];

  programs.nix-ld.enable = true;

  environment = {
    systemPackages = with pkgs; [
      cachix
      git
      hwdata
      nvtopPackages.full
      ollama
      python313
      python313Packages.pip
      tmux
      vulkan-tools
    ];
  };

  system.stateVersion = "25.05";
}
