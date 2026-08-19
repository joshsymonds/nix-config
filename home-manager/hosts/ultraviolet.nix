{pkgs, ...}: {
  imports = [
    ../headless-x86_64-linux.nix
    ../claude-code/transcripts.nix
    ../patchbay
  ];

  # Per-host Anthropic API gateway. Mounts /mnt/claude, so it also ships its
  # request ledger to the NAS bucket.
  services.patchbay = {
    enable = true;
    ledgerShipper.enable = true;
  };

  home.packages = with pkgs; [
    mediainfo
    ffmpeg
    tcpdump
    lsof
    inetutils
  ];

  programs.git.settings.user.signingkey = "0x374165B74CF6A70C";

  programs.zsh.shellAliases.update-bluedesert = "cd ~/nix-config && sudo env NIX_SSHOPTS='-i /home/joshsymonds/.ssh/github' nixos-rebuild switch --flake '.#bluedesert' --target-host joshsymonds@172.31.0.201 --sudo --option warn-dirty false";

  programs.claudeCode.hostContext = ''
    # Host: ultraviolet (Linux NixOS, x86_64)

    You are on `ultraviolet`. This is a **Linux NixOS** host — not macOS, not
    another machine in the fleet.

    ## Hardware
    - Intel i3-12300HL — 8 cores (P+E hybrid) / 12 threads
    - 64 GB RAM
    - Intel UHD integrated graphics
    - ~224 GB SSD root, headless

    ## Role
    Headless home server — the household's "always on" box. If this is down,
    people notice.

    Runs:
    - **Media stack**: Jellyfin, Jellyseerr, Radarr, Sonarr, Bazarr, Recyclarr,
      SABnzbd (via gluetun VPN), FlareSolverr
    - **Home Assistant** + Wyoming faster-whisper (voice STT for HA)
    - **Self-hosted apps**: Shimmer (private project), Inbox Zero, Obsidian sync,
      Invidious, Redlib
    - **Infra**: Caddy reverse proxy, Postgres + Redis, atticd nix binary cache
      (household-wide), cloudflared tunnels, savecraft data refresh + PoB server
    - Tailscale exit-node-capable
  '';
}
