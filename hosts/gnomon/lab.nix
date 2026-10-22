# Lab instrumentation for gnomon's halmasuit lab images. flake.nix's
# labSystems.gnomon hook appends this module to each experiment image; the
# default gnomon system never imports it.
{
  config,
  inputs,
  lib,
  ...
}: let
  network = import ../../lib/network.nix;
  labPatch = inputs.halmasuit.lib.labPatches.nvidiaCrcVblankWait;
  driver = config.hardware.gpu-nvidia.package;
in {
  halmasuit.lab = {
    crcSampler.enable = true;
    probe.enable = true;
    u2fOffServices = ["greetd" "login"];
    netconsole = {
      enable = true;
      targetIp = network.hosts.vermissian.ip;
      sourceIp = network.hosts.gnomon.ip;
      interface = "enp7s0";
      port = 6666;
    };
  };

  # The NIC driver must load in stage 1 so netconsole can send from the
  # initramfs.
  boot.initrd.availableKernelModules = ["r8169"];

  # The patch makes the CRC sampler's per-head scanout reads reflect a fully
  # scanned-out frame. Only the `open` derivation is overridden; the driver
  # package keeps its store path, so userspace and CUDA do not rebuild.
  hardware.nvidia.package = lib.mkForce (driver
    // {
      open = driver.open.overrideAttrs (o: {
        patches = (o.patches or []) ++ [labPatch];
      });
    });
}
