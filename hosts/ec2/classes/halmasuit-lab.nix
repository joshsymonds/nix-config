# halmasuit-lab: an EC2 g4dn.xlarge (one NVIDIA T4) that boots halmasuit as its
# display manager from the initramfs. Kernel, NVIDIA driver, and halmasuit
# wiring match gnomon's lab image (hosts/gnomon/lab-halmasuit.nix); the lab
# instrumentation comes from halmasuit's gnomon-lab module.
{
  config,
  inputs,
  lib,
  ...
}: {
  imports = [
    ./nvidia.nix
    ../../../modules/desktop/halmasuit.nix
    inputs.dank-greeter.nixosModules.default
    inputs.halmasuit.nixosModules.gnomon-lab
  ];

  nixpkgs.overlays = [inputs.halmasuit.overlays.default];

  # gnomon's kernel (hosts/gnomon/default.nix).
  boot.kernelPackages = inputs.nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-latest;

  hardware.gpu-nvidia.package = config.boot.kernelPackages.nvidiaPackages.new_feature;

  # NVIDIA modules in initrd, and vkms, the box's only display.
  boot.initrd.kernelModules = ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" "vkms"];

  # No firmware framebuffer driver binds, and no in-kernel DRM client (fbdev,
  # console) attaches to vkms, so nothing lights it before halmasuit does.
  boot.kernelParams = [
    "initcall_blacklist=simpledrm_platform_driver_init,efifb_driver_init"
    "drm_client_lib.active="
  ];

  # nixpkgs sets nvidia-drm.fbdev to 1 under modesetting; the lab images use 0.
  hardware.nvidia.moduleParams.nvidia-drm.fbdev = lib.mkForce 0;

  desktop.halmasuit = {
    enable = true;
    # The greeter opens on the username field, not DMS's click-only single-user picker.
    greeter.rememberLastUser = false;
  };

  services.halmasuit = {
    package = inputs.halmasuit.packages.x86_64-linux.halmasuit-debug;
    rendering = {
      # PCI address of the T4 on g4dn.
      renderNode = "pci:0000:00:1e.0";
      primaryOutput = null;
    };
    # Auto-discovery: with simpledrm blacklisted, vkms is the only card with a
    # connected connector. The T4 renders through rendering.renderNode.
    drmDevice = null;
    # Every frame from stage 1 on. /run survives switch-root; the initramfs's /var does not.
    diagnostic.recordFrames = "/run/halmasuit-lab/frames";
  };

  halmasuit.lab = {
    enable = true;
    displayManagerUnit = "halmasuit.service";
    vkmsCrc.enable = true;
    probe = {
      enable = true;
      earlyKeyboard = true;
      consumerUser = config.services.halmasuit.compositorUser;
    };
    u2fOffServices = ["halmasuit"];
  };

  # Lab login account. Its password is set per run with `chpasswd`; no password is declared here.
  # Its primary group is its own gid 1500: the broker's UID_MIN floor covers gid as well as uid.
  users.groups.labuser.gid = 1500;
  users.users.labuser = {
    isNormalUser = true;
    uid = 1500;
    group = "labuser";
    extraGroups = [config.services.halmasuit.greeterGroup];
  };

  # halmasuit.lab.enable declares gnomon's cryptroot LUKS device; this root is not encrypted.
  boot.initrd.luks.devices = lib.mkForce {};

  # The fleet box has no DMS state under joshsymonds' home. systemd skips a "-"
  # bind whose source is absent.
  systemd.services.halmasuit-greeter-setup.serviceConfig.BindReadOnlyPaths = lib.mkForce [
    "-/home/joshsymonds/.config/dms"
    "-/home/joshsymonds/.local/state/dms"
    "-/home/joshsymonds/.cache/dms"
  ];
}
