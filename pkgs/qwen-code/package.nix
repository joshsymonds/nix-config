# qwen-code at upstream latest — local bump of the nixpkgs expression.
# Unlike upstream nixpkgs we keep node-pty and keytar: the strip was a
# Darwin workaround, and 0.21.x's core type-imports @lydell/node-pty so
# stripping now breaks tsc. Linux-only as a result.
# (nixpkgs is stuck at 0.16.0 even on master; we want the current
# release for the Tiltyard harness arm: newer context-window handling
# and five minor versions of headless fixes). Same shape as
# pkgs/by-name/qw/qwen-code/package.nix upstream, version + hashes
# bumped. Drop this file when nixpkgs catches up.
{
  lib,
  buildNpmPackage,
  nodejs_22,
  fetchFromGitHub,
  jq,
  git,
  ripgrep,
  pkg-config,
  glib,
  libsecret,
}:
buildNpmPackage (finalAttrs: {
  pname = "qwen-code";
  version = "0.21.12";

  src = fetchFromGitHub {
    owner = "QwenLM";
    repo = "qwen-code";
    tag = "v${finalAttrs.version}";
    hash = "sha256-do586hHiIlDQ8dojVJxba6P2gnI/FY1m9CxCljr2X38=";
  };

  npmDepsFetcherVersion = 2;
  npmDepsHash = "sha256-8JntRCj1+mBD9+jUOP172h+0PV2nPZ64HghuybFND5k=";

  # npm 11 incompatible with fetchNpmDeps
  # https://github.com/NixOS/nixpkgs/issues/474535
  nodejs = nodejs_22;

  nativeBuildInputs = [
    jq
    pkg-config
    git
  ];

  buildInputs = [
    ripgrep
    glib
    libsecret
  ];

  postPatch = ''
    # The vscode-ide-companion workspace fails its check-types under the
    # sandbox (webview DOM types) and is irrelevant to the CLI — no-op
    # its build. Scripts aren't covered by npmDepsHash.
    ${jq}/bin/jq '.scripts.build = "echo vscode companion skipped"'       packages/vscode-ide-companion/package.json > companion.tmp       && mv companion.tmp packages/vscode-ide-companion/package.json
  '';

  buildPhase = ''
    runHook preBuild

    # 0.21.x grew more internal workspaces (acp-bridge, core subpath
    # exports); build them all via the root build:packages script
    # instead of the 0.16.0-era hand-picked list. bundle re-runs
    # generate itself.
    # Upstream's own orchestrator: dependency-ordered workspace builds
    # (core -> web-templates -> channels -> acp-bridge -> cli), runs
    # `npm run generate` itself, and --cli-only skips the webui /
    # web-shell / vscode-companion / chrome-extension packages that
    # fail (and are useless) in the sandbox.
    node scripts/build.js --cli-only
    npm run bundle

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/qwen-code
    cp -r dist/* $out/share/qwen-code/
    # Install production dependencies only
    npm prune --production
    cp -r node_modules $out/share/qwen-code/
    # Remove broken symlinks that cause issues in Nix environment
    find $out/share/qwen-code/node_modules -type l -delete || true
    patchShebangs $out/share/qwen-code
    ln -s $out/share/qwen-code/cli.js $out/bin/qwen

    runHook postInstall
  '';

  meta = {
    description = "Coding agent that lives in digital world";
    homepage = "https://github.com/QwenLM/qwen-code";
    mainProgram = "qwen";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
})
