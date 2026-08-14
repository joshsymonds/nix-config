# FHS wrapper around the unwrapped official ChatGPT Desktop preview.
#
# The native app bundles its Electron runtime, while Work and Codex shell out
# to ordinary host tools. Keep those subprocesses in the same Debian-shaped
# environment OpenAI tests against.
{
  lib,
  buildFHSEnv,
  callPackage,
  chatgpt-desktop-unwrapped ? callPackage ./default.nix {},
  git,
  openssh,
  xdg-utils,
  bubblewrap,
  libsecret,
}:
buildFHSEnv {
  pname = "chatgpt-desktop";
  executableName = "chatgpt";
  inherit (chatgpt-desktop-unwrapped) version;

  targetPkgs = _pkgs: [
    chatgpt-desktop-unwrapped
    git
    openssh
    xdg-utils
    bubblewrap
    libsecret
  ];

  runScript = "${chatgpt-desktop-unwrapped}/bin/chatgpt";

  extraInstallCommands = ''
    mkdir -p "$out/share"
    cp -r ${chatgpt-desktop-unwrapped}/share/applications "$out/share/"
    cp -r ${chatgpt-desktop-unwrapped}/share/icons "$out/share/"
  '';

  meta =
    chatgpt-desktop-unwrapped.meta
    // {
      description = "Official preview ChatGPT desktop app with bundled ChatGPT, Work, and Codex (FHS-wrapped)";
      mainProgram = "chatgpt";
    };
}
