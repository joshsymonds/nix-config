{pkgs, ...}: let
  compactTranscript = pkgs.fetchzip {
    url = "https://registry.npmjs.org/pi-compact-transcript/-/pi-compact-transcript-0.8.1.tgz";
    hash = "sha256-KdQZhE9fAo5ZSdQp44bmJ2Q9qCpF33Hknu+mGHc+A0k=";
  };

  coreSubagent = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@arhen/pi-core-subagent/-/pi-core-subagent-1.3.38.tgz";
    hash = "sha256-CbtakYxfVB/OGmsOZ7qqMat+6LbcWylg2zONoKA6/2k=";
  };
in {
  programs.pi-coding-agent = {
    enable = true;
    package = pkgs.pi-coding-agent;
  };

  home.file = {
    ".pi/agent/extensions/cc-tools.ts".source = ./cc-tools.ts;
    ".pi/agent/extensions/compact-transcript.ts".source = "${compactTranscript}/extensions/compact-transcript.ts";
    ".pi/agent/extensions/core-subagent" = {
      source = "${coreSubagent}/src";
      recursive = true;
    };
  };
}
