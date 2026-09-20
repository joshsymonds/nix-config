{
  callPackage,
  coreutils,
  depotdownloader,
  jq,
  lib,
  nix,
  runCommand,
  stdenvNoCC,
  steam-run,
  writeShellApplication,
}: let
  lock = builtins.fromJSON (builtins.readFile ./source-lock.json);

  fetchDepot = name: depotLock:
    stdenvNoCC.mkDerivation {
      pname = name;
      version = depotLock.manifest;
      dontUnpack = true;
      nativeBuildInputs = [depotdownloader];
      buildCommand = ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$out"
        export DEPOT_DOWNLOADER=${lib.getExe depotdownloader}
        ${./fetch-depot.sh} \
          ${toString depotLock.app} \
          ${toString depotLock.depot} \
          ${lib.escapeShellArg depotLock.manifest} \
          "$out"
      '';
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = depotLock.narHash;
    };

  rawServer = fetchDepot "valheim-server-raw" lock.server;
  rawRuntime = fetchDepot "valheim-runtime-raw" lock.runtime;

  source = runCommand "valheim-source-${toString lock.server.build}" {} ''
    mkdir "$out"
    ln -s ${rawServer} "$out/server"
    ln -s ${rawRuntime} "$out/runtime"
  '';

  sourceCheck = writeShellApplication {
    name = "valheim-source-check";
    runtimeInputs = [coreutils depotdownloader jq nix];
    text = ''
      export DEPOT_DOWNLOADER=${lib.getExe depotdownloader}
      export FETCH_DEPOT=${./fetch-depot.sh}
      export SOURCE_LOCK=${./source-lock.json}
      exec ${./check-source.sh} "$@"
    '';
    meta = {
      description = "Independently fetch and validate pinned Valheim server sources";
      mainProgram = "valheim-source-check";
      platforms = ["x86_64-linux"];
    };
  };

  package = stdenvNoCC.mkDerivation {
    pname = "valheim-server";
    version = toString lock.server.build;
    src = source;
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/libexec/valheim"
      cp -as ${source}/server/. "$out/libexec/valheim/"
      chmod u+w "$out/libexec/valheim"
      rm "$out/libexec/valheim/valheim_server.x86_64"
      cp ${source}/server/valheim_server.x86_64 "$out/libexec/valheim/valheim_server.x86_64"
      chmod +x "$out/libexec/valheim/valheim_server.x86_64"
      install -Dm755 ${./run-server.sh} "$out/bin/valheim-server"
      substituteInPlace "$out/bin/valheim-server" \
        --replace-fail '@serverRoot@' "$out/libexec/valheim" \
        --replace-fail '@runtimeRoot@' '${source}/runtime' \
        --replace-fail '@steamRun@' '${lib.getExe steam-run}'
      runHook postInstall
    '';

    passthru = {
      inherit rawRuntime rawServer sourceCheck;
      tests.package = callPackage ../../tests/valheim-package.nix {
        inherit package source;
        launcherTemplate = ./run-server.sh;
      };
    };

    meta = {
      description = "Immutable Valheim dedicated server";
      homepage = "https://www.valheimgame.com/support/a-guide-to-dedicated-servers/";
      license = lib.licenses.unfreeRedistributable;
      mainProgram = "valheim-server";
      platforms = ["x86_64-linux"];
    };
  };
in
  package
