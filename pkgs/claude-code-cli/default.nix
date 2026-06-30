{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  glibc,
}: let
  version = "2.1.197";
  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}";

  sources = {
    "aarch64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-arm64/claude";
      hash = "sha256-jMDE0eTrHco7DMkqsC7jUF3nZOAj+MkBdhwWe3IEH7g=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-x64/claude";
      hash = "sha256-XopXzHqSN38HRPpMeRkc+T1LJsecuRmwekB1Ef7RviY=";
    };
    "x86_64-linux" = fetchurl {
      url = "${gcsBase}/linux-x64/claude";
      hash = "sha256-9U5py8ibLaYaQVcAr3/1KhR+hiUX1PGw7s92hEjPf4M=";
    };
    "aarch64-linux" = fetchurl {
      url = "${gcsBase}/linux-arm64/claude";
      hash = "sha256-+0hHPEZ8J2Fax5mnVPTvC2jDY+RZbO+7WcOBXVGgzIo=";
    };
  };
in
  stdenv.mkDerivation {
    pname = "claude-code-cli";
    inherit version;

    src = sources.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [patchelf];

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;

    installPhase =
      ''
        runHook preInstall
        mkdir -p "$out/bin"
        cp "$src" "$out/bin/claude"
        chmod +wx "$out/bin/claude"
      ''
      + lib.optionalString stdenv.hostPlatform.isLinux ''
        patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" "$out/bin/claude"
      ''
      + ''
        runHook postInstall
      '';

    meta = {
      description = "Anthropic Claude Code CLI - native binary";
      homepage = "https://github.com/anthropics/claude-code";
      license = lib.licenses.unfree;
      maintainers = with lib.maintainers; [];
      platforms = ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"];
      mainProgram = "claude";
    };
  }
