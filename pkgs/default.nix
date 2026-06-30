# Custom packages, that can be defined similarly to ones from nixpkgs
# You can build them using 'nix build .#example' or (legacy) 'nix-build -A example'
{pkgs ? (import ../nixpkgs.nix) {}, ...}: let
  darwinOnly =
    if pkgs.stdenv.hostPlatform.isDarwin
    then {
      aerospace = pkgs.callPackage ./aerospace {};
    }
    else {};

  # Linux-only: Claude Desktop is built from Anthropic's .deb (buildFHSEnv +
  # dpkg), neither of which evaluates on darwin. Gated so `nix flake check`
  # on ninuan (aarch64-darwin) doesn't force it.
  linuxOnly =
    if pkgs.stdenv.hostPlatform.isLinux
    then let
      claude-desktop-unwrapped = pkgs.callPackage ./claude-desktop {};
    in {
      inherit claude-desktop-unwrapped;
      claude-desktop = pkgs.callPackage ./claude-desktop/fhs.nix {inherit claude-desktop-unwrapped;};
    }
    else {};
in
  {
    myCaddy = pkgs.callPackage ./caddy {};
    starlark-lsp = pkgs.callPackage ./starlark-lsp {};
    nuclei = pkgs.callPackage ./nuclei {};
    mcp-atlassian = pkgs.callPackage ./mcp-atlassian {};
    claudeCodeCli = pkgs.callPackage ./claude-code-cli {};
    codexCli = pkgs.callPackage ./codex-cli {};
    deadcode = pkgs.callPackage ./deadcode {};
    golangciLintBin = pkgs.callPackage ./golangci-lint-bin {};
    coder = pkgs.callPackage ./coder-cli {inherit (pkgs) unzip;};
    invidious-companion = pkgs.callPackage ./invidious-companion {};
    newrelic-cli = pkgs.callPackage ./newrelic-cli {};
    morgen-fetch = pkgs.callPackage ./morgen-fetch {};
    morgen-notifier = pkgs.callPackage ./morgen-notifier {};
    claude-notify-sounds = pkgs.callPackage ./claude-notify-sounds {};
  }
  // darwinOnly
  // linuxOnly
