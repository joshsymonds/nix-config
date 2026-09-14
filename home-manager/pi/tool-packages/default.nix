{
  lib,
  pkgs,
}:
pkgs.buildNpmPackage {
  pname = "pi-workflow-tools";
  version = "1.0.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
      ./process-keepalive.patch
      ./process-keepalive.ts
      ./orchestrator-processes
    ];
  };
  npmDepsHash = "sha256-XyUA/DStMea0muvSswluhTmgmIn9F2fNfuN5ajaN/+8=";
  # Pi's loader supplies SDK peers. Never install another harness, run package
  # lifecycle scripts, or download mutable dependencies at Pi startup.
  npmFlags = ["--legacy-peer-deps"];
  npmInstallFlags = ["--omit=dev"];
  npmRebuildFlags = ["--ignore-scripts"];
  dontNpmBuild = true;
  dontNpmPrune = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r node_modules $out/
    # Upstream's ConfigLoader reads project-local shellPath even when Pi has
    # not trusted that project. Keep process settings global/in-memory only.
    substituteInPlace $out/node_modules/@aliou/pi-processes/extensions/processes/config/loader.ts \
      --replace-fail 'scopes: ["global", "local", "memory"]' 'scopes: ["global", "memory"]'
    # Opt-in child lifecycle only; the normal package manifest is unchanged.
    patch -d $out/node_modules/@aliou/pi-processes -p1 < process-keepalive.patch
    cp process-keepalive.ts $out/node_modules/@aliou/pi-processes/extensions/processes/hooks/keepalive.ts
    cp -r orchestrator-processes $out/
    cp package.json package-lock.json $out/
    runHook postInstall
  '';
}
