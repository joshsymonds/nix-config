{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  glibc,
}: let
  version = "2.1.150";
  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}";

  sources = {
    "aarch64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-arm64/claude";
      hash = "sha256-L4QT6hCD8QhYeUBJahcFd1E0QQnSYftCOastRbIoXJk=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-x64/claude";
      hash = "sha256-xm1XId84zOgs3gPSRPj6knaBJf4G6NHTjUv7ra9KjRc=";
    };
    "x86_64-linux" = fetchurl {
      url = "${gcsBase}/linux-x64/claude";
      hash = "sha256-bAhqD1+/aE1BSLtpYpJotPUQlJjBp751es8YxR/QT0s=";
    };
    "aarch64-linux" = fetchurl {
      url = "${gcsBase}/linux-arm64/claude";
      hash = "sha256-IFKUlUPqB24rXNpEwDGys0/DA9uY3FatZYO34KQX6+s=";
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
