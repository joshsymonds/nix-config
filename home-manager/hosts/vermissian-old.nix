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
  ];

  programs.go.enable = true;
}
