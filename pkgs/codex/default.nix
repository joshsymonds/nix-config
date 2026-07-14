{
  lib,
  stdenvNoCC,
  fetchurl,
}: let
  sources = builtins.fromJSON (builtins.readFile ./sources.json);
  system = stdenvNoCC.hostPlatform.system;
  source =
    sources.sources.${system}
    or (throw "codex: unsupported system ${system}; supported systems: aarch64-darwin, aarch64-linux, x86_64-darwin, x86_64-linux");
in
  stdenvNoCC.mkDerivation {
    pname = "codex";
    inherit (sources) version;

    src = fetchurl {
      url = "https://github.com/openai/codex/releases/download/rust-v${sources.version}/codex-package-${source.target}.tar.gz";
      inherit (source) hash;
    };

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      tar -xzf "$src" -C "$out"

      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      test -x "$out/bin/codex"
      test -x "$out/bin/codex-code-mode-host"
      test -x "$out/codex-path/rg"
      test -f "$out/codex-package.json"
      ${lib.optionalString stdenvNoCC.hostPlatform.isLinux ''
        test -x "$out/codex-resources/bwrap"
      ''}
      ${lib.optionalString (stdenvNoCC.buildPlatform.canExecute stdenvNoCC.hostPlatform) ''
        versionOutput="$("$out/bin/codex" --version)"
        case "$versionOutput" in
          "codex-cli ${sources.version}") ;;
          *)
            echo "codex --version did not report ${sources.version}: $versionOutput" >&2
            exit 1
            ;;
        esac
      ''}

      runHook postInstallCheck
    '';

    meta = {
      description = "Lightweight coding agent that runs in your terminal";
      homepage = "https://github.com/openai/codex";
      changelog = "https://github.com/openai/codex/releases/tag/rust-v${sources.version}";
      license = lib.licenses.asl20;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      maintainers = [];
      platforms = builtins.attrNames sources.sources;
      mainProgram = "codex";
    };
  }
