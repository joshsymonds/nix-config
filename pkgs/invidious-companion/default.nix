{
  lib,
  stdenv,
  fetchurl,
}:
stdenv.mkDerivation {
  pname = "invidious-companion";
  version = "oauth-fix";

  # Using fork with OAuth fix until upstream PR is merged:
  # https://github.com/iv-org/invidious-companion/pull/263
  src = fetchurl {
    url = "https://github.com/joshsymonds/invidious-companion/releases/download/oauth-fix/invidious_companion-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-5JTsTnRGWzytO+elJ0S9pq3d7/9Ix7cRh5Hn0P+To8U=";
  };

  # Deno-compiled binaries embed code in a custom ELF section that any
  # binary modification (patchelf, strip, autoPatchelf) corrupts. The binary
  # also reads /proc/self/exe to find its embedded section, so ld.so wrappers
  # don't work either. Requires nix-ld on the host for the dynamic linker.
  dontAutoPatchelf = true;
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  sourceRoot = ".";

  installPhase = ''
    install -Dm755 invidious_companion $out/bin/invidious-companion
  '';

  meta = with lib; {
    description = "Invidious companion for handling YouTube video streams via youtube.js";
    homepage = "https://github.com/iv-org/invidious-companion";
    license = licenses.agpl3Only;
    platforms = ["x86_64-linux"];
    mainProgram = "invidious-companion";
  };
}
