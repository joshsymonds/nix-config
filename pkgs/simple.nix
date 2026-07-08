# Packages that are a plain `pkgs.callPackage ./<dir> {}` with no extra
# wiring (no flake inputs, no overrides). Shared between pkgs/default.nix
# (flake `packages` output, so `nix build .#<name>` works) and
# overlays/default.nix (so `pkgs.<name>` resolves on every host) — a single
# source of truth so the two don't drift out of sync (they had: this file
# exists because wyoming-onnx-asr and redlib-veraticus were overlay-only and
# `nix build .#wyoming-onnx-asr` didn't work).
{pkgs}: {
  myCaddy = pkgs.callPackage ./caddy {};
  starlark-lsp = pkgs.callPackage ./starlark-lsp {};
  nuclei = pkgs.callPackage ./nuclei {};
  mcp-atlassian = pkgs.callPackage ./mcp-atlassian {};
  claudeCodeCli = pkgs.callPackage ./claude-code-cli {};
  claude-swap = pkgs.callPackage ./claude-swap {};
  codexCli = pkgs.callPackage ./codex-cli {};
  deadcode = pkgs.callPackage ./deadcode {};
  golangciLintBin = pkgs.callPackage ./golangci-lint-bin {};
  coder = pkgs.callPackage ./coder-cli {inherit (pkgs) unzip;};
  invidious-companion = pkgs.callPackage ./invidious-companion {};
  newrelic-cli = pkgs.callPackage ./newrelic-cli {};
  morgen-fetch = pkgs.callPackage ./morgen-fetch {};
  morgen-notifier = pkgs.callPackage ./morgen-notifier {};
  claude-notify-sounds = pkgs.callPackage ./claude-notify-sounds {};
  wyoming-onnx-asr = pkgs.callPackage ./wyoming-onnx-asr {};
}
