{
  lib,
  stdenv,
  fetchurl,
}: let
  version = "0.134.0";
  ghBase = "https://github.com/openai/codex/releases/download/rust-v${version}";

  sources = {
    "aarch64-darwin" = {
      url = "${ghBase}/codex-aarch64-apple-darwin.tar.gz";
      hash = "sha256-eK1ILMrrDriYOzQPM6HyjIrTFbbV4xQMNMfhGcgmvBI=";
      binary = "codex-aarch64-apple-darwin";
    };
    "x86_64-darwin" = {
      url = "${ghBase}/codex-x86_64-apple-darwin.tar.gz";
      hash = "sha256-Jl+PbWJ7qcbtHKx/NuXRnv9g7zRTMpJPla8stqDIu7c=";
      binary = "codex-x86_64-apple-darwin";
    };
    "x86_64-linux" = {
      url = "${ghBase}/codex-x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256-5UuYPDq1ypktqO3eg7sppUV2GnLE+jnxihZdnnkuHHE=";
      binary = "codex-x86_64-unknown-linux-musl";
    };
    "aarch64-linux" = {
      url = "${ghBase}/codex-aarch64-unknown-linux-musl.tar.gz";
      hash = "sha256-jgZvmYER64tEJQrBHfAE2qB/rfJ2xZQqcYPLjkIQkaM=";
      binary = "codex-aarch64-unknown-linux-musl";
    };
  };

  source =
    sources.${stdenv.hostPlatform.system}
    or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");
in
  stdenv.mkDerivation {
    pname = "codex-cli";
    inherit version;

    src = fetchurl {
      inherit (source) url hash;
    };

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    dontPatchELF = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      tar -xzf "$src" -C "$out/bin"
      mv "$out/bin/${source.binary}" "$out/bin/codex"
      chmod +x "$out/bin/codex"
      runHook postInstall
    '';

    meta = {
      description = "OpenAI Codex CLI - native Rust binary";
      homepage = "https://github.com/openai/codex";
      license = lib.licenses.asl20;
      platforms = ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"];
      mainProgram = "codex";
    };
  }
