{pkgs, ...}: {
  programs.pi-coding-agent = {
    enable = true;
    package = pkgs.pi-coding-agent;
  };

  home.file.".pi/agent/extensions/cc-tools.ts".source = ./cc-tools.ts;
}
