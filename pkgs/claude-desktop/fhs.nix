# buildFHSEnv wrap around the unwrapped Claude Desktop.
#
# The unwrapped app is already autoPatchelf'd and runs standalone, so this
# layer is not about libraries — it's about the *subprocesses* the app spawns:
#   - MCP servers shell out to node/npx and uv/uvx.
#   - Cowork boots a microVM via qemu (the .deb bundles virtiofsd + the VM
#     image; qemu/OVMF are the host pieces it expects on PATH).
# An FHS sandbox gives all of that a normal Debian-shaped filesystem, which is
# exactly the environment Anthropic builds and tests the .deb against.
#
# This is the package hosts actually install (overlay attr `claude-desktop`).
{
  lib,
  buildFHSEnv,
  callPackage,
  claude-desktop-unwrapped ? callPackage ./default.nix {},
  nodejs,
  uv,
  docker,
  docker-compose,
  openssl,
  qemu,
  OVMF,
}:
buildFHSEnv {
  pname = "claude-desktop";
  inherit (claude-desktop-unwrapped) version;

  targetPkgs = _pkgs: [
    claude-desktop-unwrapped
    nodejs
    uv
    docker
    docker-compose
    openssl
    # Cowork microVM host dependencies.
    qemu
    OVMF
  ];

  runScript = "${claude-desktop-unwrapped}/bin/claude-desktop";

  # buildFHSEnv only produces bin/; surface the desktop entry + icons so
  # launchers (DMS/fuzzel) and the niri Mod+O keybind find it. The .desktop
  # Exec is bare `claude-desktop`, which PATH-resolves to this FHS launcher.
  extraInstallCommands = ''
    mkdir -p "$out/share"
    cp -r ${claude-desktop-unwrapped}/share/applications "$out/share/"
    cp -r ${claude-desktop-unwrapped}/share/icons "$out/share/"
  '';

  meta =
    claude-desktop-unwrapped.meta
    // {
      description = "Claude Desktop (official native Linux build, FHS-wrapped for MCP + Cowork)";
      mainProgram = "claude-desktop";
    };
}
