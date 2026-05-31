# stygianlibrary home-manager — VFIO host for halmasuit test VMs.
#
# Stygianlibrary itself is a HEADLESS host. The NVIDIA GPU is bound
# to vfio-pci at boot and passed to a guest VM where halmasuit runs.
# The host needs zsh + git + libvirt CLI + SSH; no desktop, no DMS,
# no niri.
#
# We use the headless base — same shape as ultraviolet / echelon.
{pkgs, ...}: {
  imports = [
    ../headless-x86_64-linux.nix
    ../claude-code/transcripts.nix
  ];

  home.packages = with pkgs; [
    # Minimal: enough to debug halmasuit from a remote SSH session.
    htop
    strace
    lsof
    tcpdump
    file
  ];

  programs.claudeCode.hostContext = ''
    # Host: stygianlibrary (Linux NixOS, x86_64) — halmasuit test rig

    You are on `stygianlibrary`. This is a **portable Thunderbolt-drive
    halmasuit test rig**, hardware-identical to gnomon but living on a
    WD_BLACK SN7100 in an ACASIS TBU405AIR Thunderbolt enclosure.

    ## Hardware
    - AMD Ryzen 7 9800X3D — same CPU as gnomon
    - NVIDIA RTX 5070 Ti — same GPU as gnomon
    - Gigabyte X870 board — same motherboard as gnomon
    - 500 GB WD_BLACK SN7100 — via TB enclosure (host machine's
      internal disks are NEVER touched)

    ## Role
    Iteration target for halmasuit's NVIDIA Wayland-EGL behavior.
    Boots on husband's PC (hardware-identical), accessible from
    gnomon over tailscale. Reproduces gnomon's halmasuit stack
    faithfully so we can debug NVIDIA-specific bugs without rebooting
    gnomon every test cycle.

    ## Don't
    - Treat this as a daily driver. Files here are EPHEMERAL
      (impermanence rollback to @root-blank every boot).
    - Touch husband's internal disks under any circumstance.
  '';
}
