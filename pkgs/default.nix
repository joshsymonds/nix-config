# Custom packages, that can be defined similarly to ones from nixpkgs
# You can build them using 'nix build .#example' or (legacy) 'nix-build -A example'
{pkgs ? (import ../nixpkgs.nix) {}, ...}: let
  darwinOnly =
    if pkgs.stdenv.hostPlatform.isDarwin
    then {
      aerospace = pkgs.callPackage ./aerospace {};
    }
    else {};
in
  {
    myCaddy = pkgs.callPackage ./caddy {};
    starlark-lsp = pkgs.callPackage ./starlark-lsp {};
    nuclei = pkgs.callPackage ./nuclei {};
    mcp-atlassian = pkgs.callPackage ./mcp-atlassian {};
    claudeCodeCli = pkgs.callPackage ./claude-code-cli {};
    geminiCli = pkgs.callPackage ./gemini-cli {};
    deadcode = pkgs.callPackage ./deadcode {};
    golangciLintBin = pkgs.callPackage ./golangci-lint-bin {};
    coder = pkgs.callPackage ./coder-cli {inherit (pkgs) unzip;};
    invidious-companion = pkgs.callPackage ./invidious-companion {};
    newrelic-cli = pkgs.callPackage ./newrelic-cli {};
  }
  // darwinOnly
