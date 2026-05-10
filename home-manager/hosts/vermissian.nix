{pkgs, ...}: {
  imports = [
    ../headless-x86_64-linux.nix
    ../go
  ];

  home.packages = with pkgs; [
    jq
    httpie
    websocat
    mkcert
    awscli2
    kind
    kubectl
    ctlptl
    tilt
    postgresql
    mongosh
    tcpdump
    lsof
    inetutils
    kubernetes-helm
    ginkgo
    prisma
    prisma-engines
    rustup
    glab
    slack-cli
    newrelic-cli
  ];

  programs.go.enable = true;

  programs.git.settings.user.signingkey = "0x7DD8F05131AEEC3A";

  programs.claudeCode.hostContext = ''
    # Host: vermissian (Linux NixOS, x86_64)

    You are on `vermissian`. This is a **Linux NixOS** host — not macOS, not
    another machine in the fleet.

    ## Hardware
    - AMD Ryzen 9 9955HX — 16 cores / 32 threads (Zen 5)
    - 64 GB RAM
    - AMD integrated graphics (Granite Ridge); no discrete GPU
    - ~880 GB NVMe root, headless

    ## Role
    Primary headless dev box. Josh remotes in via SSH/mosh and does most dev
    work here, often via Claude Code. Highest core count + RAM in the fleet,
    so it's the default place for parallel compiles, large nix builds, and
    long-running tasks.
  '';
}
