{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  glibc,
}: let
  version = "2.1.144";
  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}";

  sources = {
    "aarch64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-arm64/claude";
      hash = "sha256-mIa6pOxMRV+GEIRk8SFzIZPuduXfzrAxAF9Z8xJ2pd8=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-x64/claude";
      hash = "sha256-0iXAe3E2Fc7aVM68+2KAlCsRPGTcy6oRSxIgTpFwh/g=";
    };
    "x86_64-linux" = fetchurl {
      url = "${gcsBase}/linux-x64/claude";
      hash = "sha256-FHSAd0Ry5XIP1eg2F7PpKZNE5yE++oTDJrJb1aDyC04=";
    };
    "aarch64-linux" = fetchurl {
      url = "${gcsBase}/linux-arm64/claude";
      hash = "sha256-yMzMv84S1oRYi9OvNmOUEy9hTc88hr6yBm+GveJwRRM=";
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
