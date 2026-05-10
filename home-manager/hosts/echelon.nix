{pkgs, ...}: {
  imports = [
    ../headless-x86_64-linux.nix
  ];

  home.packages = with pkgs; [
    traceroute
    mtr
    tcpdump
  ];

  programs.claudeCode.hostContext = ''
    # Host: echelon (Linux NixOS, x86_64)

    You are on `echelon`. This is a **Linux NixOS** host — not macOS, not
    another machine in the fleet.

    ## Hardware
    - Intel Pentium N4200 — 4 cores / 4 threads (twin of bluedesert)
    - 4 GB RAM — **resource-constrained**
    - Root ~57 GB

    ## Role
    Small NixOS box on a separate LAN, reachable via tailscale; offers
    exit-node service. Network-presence box on that subnet — not for heavy work.
  '';
}
