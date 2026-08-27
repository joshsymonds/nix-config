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
  version = "0.84.3";

  src = fetchFromGitHub {
    owner = "earendil-works";
    repo = "pi";
    tag = "v${finalAttrs.version}";
    hash = "sha256-fC9pKgP2qD61ae5d7iOqP8anl88J1N1Bq8X8+aAjA2A=";
  };

  npmDepsHash = "sha256-cDx28+c4bwtQpiy5+BCvZhZezoZb4WRqfZj2eoEeMbw=";

  # Upstream generates the provider model catalog with network access and
  # leaves it out of the source tarball. The matching published pi-ai package
  # contains the hydrated catalog needed by the offline Nix build.
  modelData = fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-${finalAttrs.version}.tgz";
    hash = "sha256-nECvL0OVD46U57vNDBs1SPAAly2gDE+5wNBSnU19VDE=";
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

  buildPhase = ''
    runHook preBuild
    npx tsgo -p packages/tui/tsconfig.build.json
    npx tsgo -p packages/telemetry/tsconfig.build.json
    npx tsgo -p packages/ai/tsconfig.build.json
    npx tsgo -p packages/agent/tsconfig.build.json
    npx tsgo -p packages/protocol/tsconfig.build.json
    npx tsgo -p packages/client/tsconfig.build.json
    npm run build --workspace=packages/coding-agent
    runHook postBuild
  '';

  dontNpmPrune = true;

  preInstall = ''
    npm prune --omit=dev --no-save
  '';

  postInstall =
    ''
      local nm="$out/lib/node_modules/pi-monorepo/node_modules"
      for ws in @earendil-works/pi-ai:packages/ai \
                @earendil-works/pi-agent-core:packages/agent \
                @earendil-works/pi-client:packages/client \
                @earendil-works/pi-protocol:packages/protocol \
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
