# qwen-code at upstream latest — local bump of the nixpkgs expression.
# nixpkgs now carries the pnpm-based build (upstream moved from npm to
# pnpm in 0.22) but trails upstream; we want the current release for the
# Tiltyard harness arm. Same shape as pkgs/by-name/qw/qwen-code/package.nix
# upstream minus its Darwin node-pty/keytar workarounds (the only consumer,
# modules/services/inference-stack.nix, is Linux), version + hashes bumped.
# Drop this file when nixpkgs catches up.
{
  lib,
  stdenvNoCC,
  nodejs,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
  fetchFromGitHub,
  git,
  ripgrep,
  pkg-config,
  glib,
  libsecret,
  versionCheckHook,
}: let
  pnpm = pnpm_11;
in
  stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "qwen-code";
    version = "0.25.3";

    src = fetchFromGitHub {
      owner = "QwenLM";
      repo = "qwen-code";
      tag = "v${finalAttrs.version}";
      hash = "sha256-fHDvs5l7nqi/Wv+VLGaHPNiXqV1IKoxS30l1BpZPmmo=";
    };

    pnpmDeps = fetchPnpmDeps {
      inherit
        (finalAttrs)
        pname
        version
        src
        ;
      inherit pnpm;
      fetcherVersion = 4;
      hash = "sha256-6mzPUw8TMvZe72qSgiFXTJZB3ECEjw0b8HEVrPLVQt4=";
    };

    nativeBuildInputs = [
      nodejs
      pnpm
      pnpmConfigHook
      pkg-config
      git
    ];

    buildInputs = [
      ripgrep
      glib
      libsecret
      nodejs
    ];

    # Use the local pnpm instead of letting corepack fetch one.
    postPatch = ''
      substituteInPlace scripts/build.js \
        --replace-fail 'corepack pnpm' 'pnpm'
    '';

    env.CI = true;

    buildPhase = ''
      runHook preBuild

      # The root postinstall (skipped by pnpmConfigHook) applies the ink
      # patch packages/cli typechecks against.
      pnpm exec patch-package

      # pnpmConfigHook only patches the root node_modules. Workspaces with
      # nested .bin (web-shell's vite) keep /usr/bin/env otherwise.
      patchShebangs packages/*/node_modules

      # Upstream's own heap cap; tsc OOMs without it.
      export NODE_OPTIONS="--max-old-space-size=4096"

      npm run generate

      # Upstream's orchestrator: dependency-ordered workspace builds of
      # everything the CLI bundle pulls in; --cli-only skips the webui /
      # web-shell / vscode-companion / chrome-extension packages that fail
      # (and are useless) in the sandbox.
      node scripts/build.js --cli-only

      npm run bundle

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/share/qwen-code

      cp -r dist/* $out/share/qwen-code/

      # dist/cli.js has no shebang; upstream's bin wrapper relaunches it with
      # node --expose-gc and reads package.json for the reported version.
      cp scripts/cli-entry.js $out/share/qwen-code/cli-entry.js
      cp package.json $out/share/qwen-code/package.json

      # Production dependencies only.
      pnpm install --offline --prod --frozen-lockfile --ignore-scripts
      cp -r node_modules $out/share/qwen-code/

      # Remove broken symlinks that cause issues in the Nix environment.
      find $out/share/qwen-code/node_modules -type l -delete || true

      patchShebangs $out/share/qwen-code

      ln -s $out/share/qwen-code/cli-entry.js $out/bin/qwen

      runHook postInstall
    '';

    doInstallCheck = true;
    nativeInstallCheckInputs = [versionCheckHook];

    strictDeps = true;

    meta = {
      description = "Coding agent that lives in digital world";
      homepage = "https://github.com/QwenLM/qwen-code";
      mainProgram = "qwen";
      license = lib.licenses.asl20;
      platforms = lib.platforms.linux;
    };
  })
