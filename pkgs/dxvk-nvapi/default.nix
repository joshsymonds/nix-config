# Cross-compiled dxvk-nvapi from joshsymonds/dxvk-nvapi (the fork that adds
# 5 NVIDIA-internal NVAPI function ID stubs for Blackwell + Streamline 2.x).
#
# Called twice in the gaming overlay (once per Wine target architecture):
#   - pkgsCross.mingwW64.callPackage → produces nvapi64.dll
#   - pkgsCross.mingw32.callPackage  → produces nvapi.dll
#
# proton-cachyos's postFixup overrides drop these DLLs over the bundled
# ones in $steamcompattool/files/lib/wine/{nvapi,nvidia-libs/nvapi}/.
#
# vcs_tag in meson.build falls back to the project version string when no
# .git/ is available (verified locally) — no extra plumbing needed.

{ stdenv, src, meson, ninja }:

stdenv.mkDerivation {
  pname = "dxvk-nvapi-josh";
  version = "blackwell-stubs-unstable";

  inherit src;

  nativeBuildInputs = [ meson ninja ];

  mesonFlags =
    if stdenv.hostPlatform.is64bit
    then [ "--cross-file=build-win64.txt" ]
    else [ "--cross-file=build-win32.txt" ];

  # Skip meson's install layout (would put DLLs under $out/bin/ for Windows
  # cross-builds); copy them to a flat $out so the proton-cachyos overlay
  # can install -m 0644 ${pkg}/nvapi64.dll … directly.
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp src/nvapi*.dll $out/
    runHook postInstall
  '';

  meta.description = "dxvk-nvapi fork with Blackwell/Streamline private NVAPI ID stubs";
}
