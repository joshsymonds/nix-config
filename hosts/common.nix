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
    ../modules/linux-base
    ../modules/nix/defaults.nix
    ../modules/services/age-identity.nix
    ../modules/services/atticd-cache.nix
    ../modules/services/cleanup-stale-processes.nix
    ../modules/performance/profiles.nix
    inputs.determinate.nixosModules.default
  ];

  nix = {
    # Nix package is managed by Determinate Nix module

    # Make nix3 commands consistent with flake. shimmer is excluded for
    # the same reason it's split out of overlays.default: the registry
    # assignment forces lazy evaluation of inputs.shimmer.flake, which
    # tries to fetch git+ssh://github.com/joshsymonds/shimmer.git — and
    # any host that doesn't have ssh credentials to that repo (the
    # nixosTest VM, gnomon's first install before identity is in place)
    # fails with "Failed to fetch git repository". The shimmer service
    # itself only runs on ultraviolet (which DOES have credentials);
    # other hosts don't need shimmer in their registry.
    registry = lib.mapAttrs (_: value: {flake = value;}) (lib.removeAttrs inputs ["shimmer"]);

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

  # Latest mainline kernel everywhere — pinned in one place so a critical
  # kernel fix lands on all hosts together. NVIDIA `production` driver
  # tracks linuxPackages_latest.nvidiaPackages.production (gnomon).
  boot.kernelPackages = pkgs.linuxPackages_latest;

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

  # Household DNS — the LAN router (172.31.0.1) doesn't serve names for
  # household hosts, so every host needs a static map to talk to its
  # neighbors. Single source of truth in lib/network.nix.
  networking.extraHosts = ''
    ${network.hosts.ultraviolet.ip} ultraviolet
    ${network.hosts.vermissian.ip} vermissian
    ${network.hosts.bluedesert.ip} bluedesert
    ${network.hosts.echelon.ip} echelon
  '';

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

  # Don't let the user manager's per-scope TasksMax (default: 15% of
  # kernel.threads-max) cap forks inside tmux-spawn-*.scope. Heavy
  # nix-eval workloads run inside a tmux session can exhaust it and
  # then every fork() in that session returns EAGAIN until the scope
  # frees slots. Lift the per-scope cap; the kernel-wide threads-max
  # still applies as the real ceiling.
  systemd.user.extraConfig = ''
    DefaultTasksMax=infinity
  '';

  # Common packages for all headless Linux hosts
  environment.pathsToLink = ["/share/zsh"];
  environment.systemPackages = with pkgs; [
    # Secrets management
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.agenix
    ssh-to-age

    # Hardware & system info
    cachix
    hwdata
    lshw
    pciutils
    polkit
    unar

    # DNS & network diagnostics
    dnsutils # dig, nslookup, host
    ethtool
    iperf3
    mtr
    nmap
    tcpdump
    traceroute
    whois

    # System inspection & debugging
    iotop
    lsof
    strace
    sysstat # iostat, sar, mpstat

    # General utilities
    bc
    man-pages
    psmisc # pstree, fuser
    rsync
    tree
    xxd
    yamllint
    zip
    p7zip
  ];

  # atticd-cache: every NixOS host pulls from + pushes to ultraviolet's cache.
  # bluedesert/echelon are excluded until their host keys land in
  # secrets/keys.nix and the shared push token is re-keyed to them.
  age.secrets."atticd-push-token" = lib.mkIf (!builtins.elem config.networking.hostName ["echelon"]) {
    file = ../secrets/shared/atticd-push-token.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  services.atticd-cache = lib.mkIf (!builtins.elem config.networking.hostName ["echelon"]) {
    consumer.enable = true;
    publisher = {
      enable = true;
      tokenFile = config.age.secrets."atticd-push-token".path;
    };
  };

  # NFS mounts. `nofail` keeps a failed network mount from stalling boot at
  # remote-fs.target → emergency mode. Bluedesert isn't authorized for the
  # `creative` share on the NAS (per export ACL), so it gets the other three only.
  fileSystems = let
    nfs = device: {
      device = device;
      fsType = "nfs";
      options = ["nofail"];
    };
  in
    lib.mkMerge [
      (lib.mkIf (!builtins.elem config.networking.hostName ["echelon"]) {
        "/mnt/video" = nfs "${nas.ip}:${nas.shares.video}";
        "/mnt/music" = nfs "${nas.ip}:${nas.shares.music}";
        "/mnt/books" = nfs "${nas.ip}:${nas.shares.books}";
      })
      (lib.mkIf (!builtins.elem config.networking.hostName ["bluedesert" "echelon"]) {
        "/mnt/creative" = nfs "${nas.ip}:${nas.shares.creative}";
      })
    ];

  services.openssh.settings.AcceptEnv = lib.mkBefore ["TERM" "COLORTERM" "TERM_PROGRAM" "TERM_PROGRAM_VERSION"];

  users.users.joshsymonds = {
    hashedPassword = lib.mkDefault "";
    group = "joshsymonds";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMnWlXMFExsVFYMB9eN63JcF3Ry3iFqA8KbebAwvBH4t josh+ninuan@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINTWmaNJwRqzDMdfVOXbX6FNjcJ94VRK+aKLI2NqrcWV josh+morningstar@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID0OvTKlW2Vk5WA11YOQ6SNDS4KsT9I1ffVGomswscZA josh+ultraviolet@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEhL0xP1eFVuYEPAvO6t+Mb9ragHnk4dxeBd/1Tmka41 josh+phone@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIORmNHlIFi2MWPh9H0olD2VBvPNK7+wJkA+A/3wCOtZN josh+vermissian@joshsymonds.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKi6ZE7mq37XFkWvBDRAPP5eReUO5c0D2ngU4wEIhPhH josh+gnomon@joshsymonds.com"
    ];
  };

  users.groups.joshsymonds = {};
}
