{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  fetchurl,
  nix-update-script,
  versionCheckHook,
  writableTmpDirAsHomeHook,
  ripgrep,
  fd,
  makeBinaryWrapper,
  stdenvNoCC,
}:
buildNpmPackage (finalAttrs: {
  pname = "pi-coding-agent";
  version = "1.3.0";

  src = fetchFromGitHub {
    owner = "earendil-works";
    repo = "pi";
    tag = "v${finalAttrs.version}";
    hash = "sha256-AsutbwnjiwwLkB5tqLW+1GdGZyLmXsU0W+SNdNhJu7U=";
  };

  npmDepsHash = "sha256-+gFyvrhkCsF99oNvs0gBmLXnDW0hWnZI/wFId7UbI6Q=";

  # Upstream generates the provider model catalog with network access and
  # leaves it out of the source tarball. The matching published pi-ai package
  # contains the hydrated catalog needed by the offline Nix build.
  modelData = fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-${finalAttrs.version}.tgz";
    hash = "sha256-U0PhY5vzQ73DNE3zrWwxwFpQtoutB6xrzhCJDUtrimE=";
  };

  preConfigure = ''
    mkdir -p packages/ai/src/providers/data
    tar --extract --gzip --file=${finalAttrs.modelData} \
      --directory=packages/ai/src/providers/data \
      --strip-components=4 \
      package/dist/providers/data
  '';

  npmWorkspace = "packages/coding-agent";
  npmRebuildFlags = ["--ignore-scripts"];

  nativeBuildInputs = [makeBinaryWrapper];

  # Upstream's own offline build: every workspace in dependency order, with
  # pi-ai's model-data check standing in for network catalog generation.
  buildPhase = ''
    runHook preBuild
    npm run build:offline
    runHook postBuild
  '';

  dontNpmPrune = true;

  preInstall = ''
    npm prune --omit=dev --no-save
  '';

  postInstall =
    ''
      local nm="$out/lib/node_modules/pi-monorepo/node_modules"
      for ws in @earendil-works/pi-agent-core:packages/agent \
                @earendil-works/pi-ai:packages/ai \
                @earendil-works/pi-codemode:packages/codemode \
                @earendil-works/pi-mcp:packages/mcp \
                @earendil-works/pi-telemetry:packages/telemetry \
                @earendil-works/pi-tui:packages/tui; do
        IFS=: read -r pkg src <<< "$ws"
        rm "$nm/$pkg"
        cp -r "$src" "$nm/$pkg"
      done
      find "$nm" -type l -lname '*/packages/*' -delete
      find "$nm/.bin" -xtype l -delete
    ''
    + lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
      rm -rf \
        "$nm/@anthropic-ai/sandbox-runtime/dist/vendor/seccomp" \
        "$nm/@anthropic-ai/sandbox-runtime/vendor/seccomp"
    '';

  postFixup = ''
    wrapProgram $out/bin/pi --prefix PATH : ${
      lib.makeBinPath [
        ripgrep
        fd
      ]
    } \
      --set-default PI_SKIP_VERSION_CHECK 1 \
      --set-default PI_TELEMETRY 0
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = ["HOME"];
  versionCheckProgram = "${placeholder "out"}/bin/pi";
  versionCheckProgramArg = "--version";

  passthru.updateScript = nix-update-script {
    extraArgs = [
      "--custom-dep"
      "modelData"
    ];
  };

  meta = {
    description = "Minimal terminal coding harness";
    homepage = "https://pi.dev/";
    downloadPage = "https://www.npmjs.com/package/@earendil-works/pi-coding-agent";
    changelog = "https://github.com/earendil-works/pi/blob/v${finalAttrs.version}/packages/coding-agent/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "pi";
    platforms = lib.platforms.unix;
  };
})
