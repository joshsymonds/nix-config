{
  inputs,
  lib,
  pkgs,
  config,
  ...
}: let
  network = import ../lib/network.nix;
  nas = network.infra.nas;
in {
  imports = [
    ../modules/nix/defaults.nix
    ../modules/services/age-identity.nix
    ../modules/services/cleanup-stale-processes.nix
    ../modules/performance/profiles.nix
    inputs.determinate.nixosModules.default
  ];

  nix = {
    # Nix package is managed by Determinate Nix module

    # Make nix3 commands consistent with flake
    registry = lib.mapAttrs (_: value: {flake = value;}) inputs;

    # Make legacy nix commands consistent too
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;

    settings = {
      # Trigger GC when disk space is low
      min-free = "${toString (10 * 1024 * 1024 * 1024)}"; # 10GB free space minimum
      max-free = "${toString (50 * 1024 * 1024 * 1024)}"; # Clean up to 50GB when triggered
    };

    # Automatic garbage collection
    gc = {
      automatic = true;
      dates = "daily";
      options = "--delete-older-than 3d";
    };

    # Automatic store optimization (hard-linking identical files)
    optimise.automatic = true;
  };

  # Timezone and locale
  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  # Shell and user setup
  users.defaultUserShell = pkgs.zsh;
  users.users.joshsymonds = {
    shell = pkgs.zsh;
    home = "/home/joshsymonds";
    isNormalUser = true;
    extraGroups = ["wheel" config.users.groups.keys.name];
  };

  # Security
  security = {
    rtkit.enable = true;
    sudo.extraRules = [
      {
        users = ["joshsymonds"];
        commands = [
          {
            command = "ALL";
            options = ["SETENV" "NOPASSWD"];
          }
        ];
      }
    ];
  };

  # Core services
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  services.thermald.enable = lib.mkDefault true;
  services.fstrim.enable = lib.mkDefault true;

  # Programs
  programs = {
    zsh.enable = true;
    ssh.startAgent = true;
  };

  # Common packages for all headless Linux hosts
  environment.pathsToLink = ["/share/zsh"];
  environment.systemPackages = with pkgs; [
    yamllint # YAML linter, useful for Home Assistant configurations
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.agenix
    ssh-to-age
  ];

  fileSystems = lib.mkIf (!builtins.elem config.networking.hostName ["stygianlibrary" "bluedesert" "echelon"]) {
    "/mnt/video" = {
      device = "${nas.ip}:${nas.shares.video}";
      fsType = "nfs";
    };
    "/mnt/music" = {
      device = "${nas.ip}:${nas.shares.music}";
      fsType = "nfs";
    };
    "/mnt/books" = {
      device = "${nas.ip}:${nas.shares.books}";
      fsType = "nfs";
    };
    "/mnt/creative" = {
      device = "${nas.ip}:${nas.shares.creative}";
      fsType = "nfs";
    };
  };

  services.eternal-terminal = {
    enable = true;
    port = 2022;
  };

  services.openssh.settings.AcceptEnv = lib.mkBefore [ "TERM" "COLORTERM" "TERM_PROGRAM" "TERM_PROGRAM_VERSION" ];

  # Open firewall for ET
  networking.firewall.allowedTCPPorts = [2022];

  users.users.joshsymonds = {
    hashedPassword = lib.mkDefault "";
    group = "joshsymonds";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMnWlXMFExsVFYMB9eN63JcF3Ry3iFqA8KbebAwvBH4t josh+ninuan@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINTWmaNJwRqzDMdfVOXbX6FNjcJ94VRK+aKLI2NqrcWV josh+morningstar@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID0OvTKlW2Vk5WA11YOQ6SNDS4KsT9I1ffVGomswscZA josh+ultraviolet@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhL0xP1eFVuYEPAvO6t+Mb9ragHnk4dxeBd/1Tmka41 josh+phone@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIORmNHlIFi2MWPh9H0olD2VBvPNK7+wJkA+A/3wCOtZN josh+vermissian@joshsymonds.com"
    ];
  };

  users.groups.joshsymonds = {};
}
