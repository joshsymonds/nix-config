{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}: let
  sources = builtins.fromJSON (builtins.readFile ./sources.json);
  system = stdenv.hostPlatform.system;
  source =
    sources.sources.${system}
    or (throw "cliproxyapi: unsupported system ${system}; supported systems: ${lib.concatStringsSep ", " (builtins.attrNames sources.sources)}");
in
  stdenv.mkDerivation {
    pname = "cliproxyapi";
    inherit (sources) version;

    src = fetchurl {
      url = "https://github.com/router-for-me/CLIProxyAPI/releases/download/v${sources.version}/CLIProxyAPI_${sources.version}_${source.asset}.tar.gz";
      inherit (source) hash;
    };

    # Upstream release binaries link only against glibc (libdl, libresolv,
    # libpthread, libc); autoPatchelfHook fixes the interpreter on NixOS.
    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];

    sourceRoot = ".";
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      install -Dm755 cli-proxy-api "$out/bin/cli-proxy-api"
      install -Dm644 config.example.yaml "$out/share/doc/cliproxyapi/config.example.yaml"

      runHook postInstall
    '';

    meta = {
      description = "Proxy that exposes CLI-agent subscriptions (ChatGPT Codex, Gemini, Claude) as OpenAI/Anthropic-compatible API endpoints";
      homepage = "https://github.com/router-for-me/CLIProxyAPI";
      changelog = "https://github.com/router-for-me/CLIProxyAPI/releases/tag/v${sources.version}";
      license = lib.licenses.mit;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = builtins.attrNames sources.sources;
      mainProgram = "cli-proxy-api";
    };
  }
