{
  lib,
  stdenv,
  fetchurl,
  patchelf,
  glibc,
}:
let
  version = "2.1.92";
  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${version}";

  sources = {
    "aarch64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-arm64/claude";
      hash = "sha256-bRuWV3J9zoEzKzzaEb/gqMg+I5LjwGKjECLhCw5xzdE=";
    };
    "x86_64-darwin" = fetchurl {
      url = "${gcsBase}/darwin-x64/claude";
      hash = "sha256-1CK1zJdLO8Syj2mBRP0DFvPhd3S6vgvB63bCuwhY0Ko=";
    };
    "x86_64-linux" = fetchurl {
      url = "${gcsBase}/linux-x64/claude";
      hash = "sha256-4iMkUUln/y1en5Hw7jfkZ1v4tt/sJ/r7GcslzFsj/K8=";
    };
    "aarch64-linux" = fetchurl {
      url = "${gcsBase}/linux-arm64/claude";
      hash = "sha256-CN6z1WR3SW65LmJPSS4lsSP0Un3VZ09xr/9YpI7M2VM=";
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

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp "$src" "$out/bin/claude"
    chmod +wx "$out/bin/claude"
  '' + lib.optionalString stdenv.hostPlatform.isLinux ''
    patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" "$out/bin/claude"
  '' + ''
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
