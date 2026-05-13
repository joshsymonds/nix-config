# Cross-compiled vkd3d-proton from joshsymonds/vkd3d-proton (the fork that
# refuses 0×0 DXGI ResizeBuffers when the previous swapchain dimensions were
# valid — see josh/refuse-zero-swapchain-resize).
#
# Called twice in the gaming overlay (once per Wine target architecture):
#   - pkgsCross.mingwW64.callPackage → produces x86_64 d3d12.dll + d3d12core.dll
#   - pkgsCross.mingw32.callPackage  → produces i686  d3d12.dll + d3d12core.dll
#
# proton-cachyos's postFixup overrides drop these DLLs over the bundled ones
# at $steamcompattool/files/lib/wine/vkd3d-proton/{x86_64,i386}-windows/.
#
# vcs_tag in meson.build has built-in fallbacks ('12345678', '300001') so
# the missing .git/ in the flake-fetched src isn't a problem.

{ stdenv, src, meson, ninja, glslang, perl, buildPackages }:

# wine provides `widl` (cross-arch IDL compiler used by vkd3d-proton's
# meson build to compile .idl → COM headers). Pull from buildPackages so
# we get the *native* wine, not a (nonsensical) mingw cross of wine. Use
# wine64Packages — the wow64 variant winePackages uses tries to drag in
# the i686 Linux package set, which fails to evaluate when the build
# host doesn't enable that cross system.
let wineForWidl = buildPackages.wine64Packages.minimal; in

stdenv.mkDerivation {
  pname = "vkd3d-proton-josh";
  version = "refuse-zero-swapchain-resize-unstable";

  inherit src;

  # glslang: native shader compiler, runs at build time to produce SPIR-V.
  # wineMinimal: provides `widl` (used to compile the .idl files into
  #   COM headers). meson.build line 73 looks for `widl` first, then falls
  #   back to the cross-file's `widl-mingw-tools-fallback` entry.
  # perl: a couple of header-generation scripts in subprojects use it.
  nativeBuildInputs = [ meson ninja glslang wineForWidl perl ];

  mesonFlags =
    if stdenv.hostPlatform.is64bit
    then [ "--cross-file=build-win64.txt" ]
    else [ "--cross-file=build-win32.txt" ];

  # Skip meson's install layout (would put DLLs under $out/bin/ for Windows
  # cross-builds and also install dev headers we don't use); copy the two
  # DLLs we actually need to a flat $out so the proton-cachyos overlay can
  # install -m 0644 ${pkg}/d3d12.dll … directly.
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp libs/d3d12/d3d12.dll $out/
    cp libs/d3d12core/d3d12core.dll $out/
    runHook postInstall
  '';

  meta.description = "vkd3d-proton fork that refuses 0×0 DXGI ResizeBuffers when prior dimensions were valid";
}
