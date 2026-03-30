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
    nodePackages.prisma
    rustup
    glab
    slack-cli
  ];

  programs.go.enable = true;

  programs.git.settings.user.signingkey = "0x7DD8F05131AEEC3A";
}
