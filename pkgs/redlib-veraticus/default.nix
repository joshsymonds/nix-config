{
  pkgs,
  crane,
  redlibSrc,
  redlibRev ? "dirty",
  rustOverlay,
  lib ? pkgs.lib,
}: let
  pkgsWithRust = pkgs.extend (import rustOverlay);
  rustToolchain = pkgsWithRust.rust-bin.stable.latest.default;
  craneLib = (crane.mkLib pkgsWithRust).overrideToolchain rustToolchain;
  cleanedSrc = lib.cleanSourceWith {
    src = craneLib.path redlibSrc;
    filter = path: type:
      (lib.hasInfix "/templates/" path)
      || (lib.hasInfix "/static/" path)
      || (craneLib.filterCargoSources path type);
  };
in
  craneLib.buildPackage {
    pname = "redlib-veraticus";
    version = builtins.substring 0 8 redlibRev;

    src = cleanedSrc;
    strictDeps = true;
    doCheck = false;

    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.cmake
      pkgs.perl
      pkgs.libclang
      pkgs.git
    ];

    LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
    BINDGEN_EXTRA_CLANG_ARGS =
      "-isystem ${pkgs.glibc.dev}/include "
      + "-isystem ${pkgs.libclang.lib}/lib/clang/${lib.versions.major pkgs.libclang.version}/include";

    meta = {
      description = "Private Reddit front-end (joshsymonds fork)";
      homepage = "https://github.com/joshsymonds/redlib";
      license = lib.licenses.agpl3Only;
      mainProgram = "redlib";
      platforms = ["x86_64-linux"];
    };
  }
