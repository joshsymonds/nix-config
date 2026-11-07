# tests/ec2-halmasuit-lab-eval.nix
#
# Eval-only check for the halmasuit-lab EC2 class (hosts/ec2/classes/halmasuit-lab.nix).
# Each assertion names one setting the lab image depends on; a failure prints
# that setting's name. Nothing is built beyond the marker derivation.
{
  pkgs,
  inputs,
  lab,
  gnomon,
}: let
  inherit (pkgs) lib;

  cls = (import ../hosts/ec2/classes.nix).halmasuit-lab;
  renderNode = "pci:0000:00:1e.0";
  recordDir = "/run/halmasuit-lab/frames";
  halmasuitHosts = inputs.halmasuit.packages.x86_64-linux;
  nvidiaNew = inputs.nix-cachyos-kernel.legacyPackages.x86_64-linux.linuxPackages-cachyos-latest.nvidiaPackages.new_feature;

  check = cond: msg: lib.assertMsg cond "ec2-halmasuit-lab-eval: ${msg}";
  has = list: value: lib.elem value list;
  greeterDirs = [
    "-/home/joshsymonds/.config/dms"
    "-/home/joshsymonds/.local/state/dms"
    "-/home/joshsymonds/.cache/dms"
  ];
  pamLines = lib.splitString "\n" lab.security.pam.services.halmasuit.text;
  authLines = lib.filter (line: lib.hasPrefix "auth" line) pamLines;
  initrdEnv = lab.boot.initrd.systemd.services.halmasuit.environment;
  labuser = lab.users.users.labuser or {};
  greeterGroup = lab.services.halmasuit.greeterGroup;
  primaryGid = (lab.users.groups.${labuser.group or ""} or {}).gid or null;
in
  # 0. class registry entry (hosts/ec2/classes.nix)
  assert check (cls.instanceType == "g4dn.xlarge") "classes.nix halmasuit-lab instanceType must be g4dn.xlarge";
  assert check (cls.diskGb == 100) "classes.nix halmasuit-lab diskGb must be 100";
  assert check (cls.spot == true) "classes.nix halmasuit-lab spot must be true";
  assert check (cls.reboot == true) "classes.nix halmasuit-lab reboot must be true";
  assert check (cls.idleMinutes == 30) "classes.nix halmasuit-lab idleMinutes must be 30";
  assert check (cls.maxHours == 4) "classes.nix halmasuit-lab maxHours must be 4";
  assert check (cls.module == ../hosts/ec2/classes/halmasuit-lab.nix) "classes.nix halmasuit-lab module must be classes/halmasuit-lab.nix";
  assert check (lab.ec2Fleet.idleMinutes == 30) "ec2Fleet.idleMinutes must be 30";
  assert check (lab.ec2Fleet.maxHours == 4) "ec2Fleet.maxHours must be 4";
  # 1. kernel
  assert check (lab.boot.kernelPackages.kernel.outPath == gnomon.boot.kernelPackages.kernel.outPath) "boot.kernelPackages must be gnomon's CachyOS kernel";
  # 2. NVIDIA through hardware.gpu-nvidia
  assert check lab.hardware.gpu-nvidia.enable "hardware.gpu-nvidia.enable must be true";
  assert check (lab.hardware.gpu-nvidia.containerToolkit == false) "hardware.gpu-nvidia.containerToolkit must be false";
  assert check lab.hardware.nvidia.open "hardware.nvidia.open must be true";
  assert check lab.hardware.nvidia.modesetting.enable "hardware.nvidia.modesetting.enable must be true";
  assert check (lab.hardware.nvidia.package.outPath == nvidiaNew.outPath) "hardware.nvidia.package must be kernelPackages.nvidiaPackages.new_feature";
  assert check (lab.hardware.nvidia.nvidiaSettings == false) "hardware.nvidia.nvidiaSettings must be false (classes/nvidia.nix)";
  assert check (lab.hardware.nvidia.powerManagement.enable == false) "hardware.nvidia.powerManagement.enable must be false (classes/nvidia.nix)";
  assert check lab.hardware.nvidia.nvidiaPersistenced "hardware.nvidia.nvidiaPersistenced must be true (classes/nvidia.nix)";
  assert check (lib.any (p: lib.getName p == "vulkan-tools") lab.environment.systemPackages) "environment.systemPackages must include vulkan-tools (classes/nvidia.nix)";
  # 3. initrd modules
  assert check (has lab.boot.initrd.kernelModules "nvidia") "boot.initrd.kernelModules must include nvidia";
  assert check (has lab.boot.initrd.kernelModules "nvidia_modeset") "boot.initrd.kernelModules must include nvidia_modeset";
  assert check (has lab.boot.initrd.kernelModules "nvidia_uvm") "boot.initrd.kernelModules must include nvidia_uvm";
  assert check (has lab.boot.initrd.kernelModules "nvidia_drm") "boot.initrd.kernelModules must include nvidia_drm";
  assert check (has lab.boot.initrd.kernelModules "vkms") "boot.initrd.kernelModules must include vkms";
  # 4. kernel params and nvidia-drm fbdev
  assert check (has lab.boot.kernelParams "initcall_blacklist=simpledrm_platform_driver_init,efifb_driver_init") "boot.kernelParams must include the initcall_blacklist entry";
  assert check (has lab.boot.kernelParams "drm_client_lib.active=") "boot.kernelParams must include drm_client_lib.active=";
  assert check (lab.hardware.nvidia.moduleParams.nvidia-drm.fbdev == 0) "hardware.nvidia.moduleParams.nvidia-drm.fbdev must be 0";
  assert check (!(lib.hasInfix "fbdev=1" lab.boot.extraModprobeConfig)) "boot.extraModprobeConfig must not contain fbdev=1";
  # 5. halmasuit
  assert check lab.programs.dms-greeter.enable "programs.dms-greeter must be enabled (dank-greeter module imported)";
  assert check lab.halmasuit.lab.enable "halmasuit.lab.enable must be true (gnomon-lab module imported)";
  assert check lab.desktop.halmasuit.enable "desktop.halmasuit.enable must be true";
  assert check (lab.desktop.halmasuit.greeter.rememberLastUser == false) "desktop.halmasuit.greeter.rememberLastUser must be false";
  assert check lab.services.halmasuit.fromInitrd.enable "services.halmasuit.fromInitrd.enable must be true";
  assert check (lab.services.halmasuit.rendering.backend == "nvidia") "services.halmasuit.rendering.backend must be nvidia";
  assert check (lab.services.halmasuit.package.outPath == halmasuitHosts.halmasuit-debug.outPath) "services.halmasuit.package must be halmasuit-debug";
  assert check (lab.services.halmasuit.rendering.renderNode == renderNode) "services.halmasuit.rendering.renderNode must be ${renderNode}";
  assert check (lab.services.halmasuit.drmDevice == null) "services.halmasuit.drmDevice must be null";
  assert check (lab.services.halmasuit.rendering.primaryOutput == null) "services.halmasuit.rendering.primaryOutput must be null";
  assert check ((initrdEnv.HALMASUIT_RENDER_NODE or null) == renderNode) "boot.initrd.systemd.services.halmasuit.environment must set HALMASUIT_RENDER_NODE";
  assert check (!(initrdEnv ? HALMASUIT_DRM_DEVICE)) "boot.initrd.systemd.services.halmasuit.environment must not set HALMASUIT_DRM_DEVICE";
  # 5b. frame recorder (R2): the lab image records from stage 1 to a path that survives switch-root
  assert check (lab.services.halmasuit.diagnostic.recordFrames == recordDir) "services.halmasuit.diagnostic.recordFrames must be ${recordDir}";
  assert check ((initrdEnv.HALMASUIT_RECORD_FRAMES or null) == recordDir) "boot.initrd.systemd.services.halmasuit.environment must set HALMASUIT_RECORD_FRAMES to ${recordDir}";
  # 7. lab options and their units
  assert check (lab.halmasuit.lab.displayManagerUnit == "halmasuit.service") "halmasuit.lab.displayManagerUnit must be halmasuit.service";
  assert check lab.halmasuit.lab.vkmsCrc.enable "halmasuit.lab.vkmsCrc.enable must be true";
  assert check lab.halmasuit.lab.probe.enable "halmasuit.lab.probe.enable must be true";
  assert check lab.halmasuit.lab.probe.earlyKeyboard "halmasuit.lab.probe.earlyKeyboard must be true";
  assert check (lab.halmasuit.lab.probe.consumerUser == lab.services.halmasuit.compositorUser) "halmasuit.lab.probe.consumerUser must be the halmasuit compositor user";
  assert check (lab.halmasuit.lab.u2fOffServices == ["halmasuit"]) "halmasuit.lab.u2fOffServices must be [halmasuit]";
  assert check (lab.boot.initrd.systemd.services ? lab-vkms-crc-initrd) "boot.initrd.systemd.services must include lab-vkms-crc-initrd";
  assert check (lab.boot.initrd.systemd.services ? lab-probe-kbd) "boot.initrd.systemd.services must include lab-probe-kbd";
  assert check (lab.boot.initrd.luks.devices == {}) "boot.initrd.luks.devices must be empty";
  # 8. greeter
  assert check lab.services.halmasuit.niriSession.enable "services.halmasuit.niriSession.enable must be true";
  assert check (lib.hasInfix "halmasuit-dankgreeter" lab.services.halmasuit.greeterCommand) "services.halmasuit.greeterCommand must name halmasuit-dankgreeter";
  assert check (lab.systemd.services.halmasuit-greeter-setup.serviceConfig.BindReadOnlyPaths == greeterDirs) "halmasuit-greeter-setup BindReadOnlyPaths must be the three optional DMS dirs";
  # 9. PAM
  assert check (!(lib.hasInfix "pam_u2f" lab.security.pam.services.halmasuit.text)) "security.pam.services.halmasuit must not contain pam_u2f";
  assert check (lib.all (line: !(lib.hasInfix "nullok" line)) authLines) "security.pam.services.halmasuit auth lines must not contain nullok";
  # 10. lab login account labuser (J3, classes/halmasuit-lab.nix)
  assert check (lab.users.users ? labuser) "users.users.labuser must be declared";
  assert check (labuser.isNormalUser or false) "users.users.labuser.isNormalUser must be true";
  assert check ((labuser.uid or null) == 1500) "users.users.labuser.uid must be 1500";
  assert check ((labuser.uid or 0) >= 1000) "users.users.labuser.uid must be at least 1000";
  assert check ((labuser.group or null) == "labuser") "users.users.labuser.group must be labuser";
  assert check ((labuser.group or null) != "users") "users.users.labuser.group must not be users (gid 100 is below the broker UID_MIN floor)";
  assert check (primaryGid == 1500) "the primary group of users.users.labuser must resolve through users.groups to gid 1500";
  assert check (primaryGid >= 1000) "the primary group of users.users.labuser must have a gid of at least 1000";
  assert check (lib.hasAttr greeterGroup lab.users.groups) "users.groups.${greeterGroup} must exist (services.halmasuit.greeterGroup)";
  assert check ((labuser.extraGroups or null) == [greeterGroup]) "users.users.labuser.extraGroups must be exactly [services.halmasuit.greeterGroup]";
  assert check (!(has (labuser.extraGroups or []) "wheel")) "users.users.labuser.extraGroups must not contain wheel";
  assert check ((labuser.hashedPassword or null) == null) "users.users.labuser.hashedPassword must be unset";
  assert check ((labuser.hashedPasswordFile or null) == null) "users.users.labuser.hashedPasswordFile must be unset";
  assert check ((labuser.password or null) == null) "users.users.labuser.password must be unset";
  assert check ((labuser.initialPassword or null) == null) "users.users.labuser.initialPassword must be unset";
  assert check ((labuser.initialHashedPassword or null) == null) "users.users.labuser.initialHashedPassword must be unset";
  assert check (!(lib.any (rule: has (rule.users or []) "labuser") lab.security.sudo.extraRules)) "security.sudo.extraRules must not name labuser";
  assert check (!(lib.hasInfix "labuser" lab.security.sudo.configFile)) "security.sudo.configFile must not name labuser";
  assert check (lab.users.mutableUsers == true) "users.mutableUsers must stay true (chpasswd password must persist across reboot)";
    pkgs.runCommand "ec2-halmasuit-lab-eval" {} ''
      touch "$out"
    ''
