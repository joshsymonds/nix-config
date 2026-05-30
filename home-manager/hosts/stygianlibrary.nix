# stygianlibrary home-manager — halmasuit test rig.
#
# Strips gnomon.nix down to JUST what the test rig needs:
#   - Desktop base (zsh, kitty, niri integration via halmasuit, etc.)
#   - SSH-able workflow
#   - Git + transcripts so debugging via Claude works
#
# Drops gnomon-specific:
#   - claude-code/aggregator (DMS bar, gnomon-only by assertion)
#   - vesktop / spicetify / qbittorrent / calendar / ntfy-notify
#     (daily-driver apps; not needed on a test rig)
#
# Reuses the desktop-x86_64-linux base because halmasuit IS a
# desktop on this rig.
{pkgs, ...}: {
  imports = [
    ../desktop-x86_64-linux.nix
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
