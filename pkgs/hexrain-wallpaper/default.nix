# hexrain-wallpaper — DMS's hexrain wallpaper as an Android live wallpaper
# for shrike. Renders DMS's own three shaders (from the `dms` flake input,
# compiled to GLSL ES 300 by qsb) through the same three passes as
# quickshell/Widgets/HexrainEffect.qml, with the scene baked in from DMS's
# wallpaper.json, at 30 fps while visible.
#
# This builds the UNSIGNED, aligned APK, reproducibly and without Gradle:
# aapt2 (resources + manifest), javac + d8 (code), zipalign. The signed APK
# shrike installs is hosts/shrike/hexrain-wallpaper.apk, made by
# `nix run .#hexrain-wallpaper-release` with a key that never enters the
# store (see pkgs/hexrain-wallpaper/release.sh); checks.hexrain-wallpaper-
# sync fails when it drifts from this build.
#
# Building accepts the Android SDK license (androidenv's licenseAccepted),
# scoped to this package.
{
  lib,
  stdenvNoCC,
  androidenv,
  jdk17_headless,
  qt6,
  zip,
  dms,
}: let
  buildToolsVersion = "35.0.0";
  platformVersion = "35";
  sdk =
    ((androidenv.override {licenseAccepted = true;}).composeAndroidPackages {
      platformVersions = [platformVersion];
      buildToolsVersions = [buildToolsVersion];
      includeEmulator = false;
      includeSystemImages = false;
      includeNDK = false;
      includeSources = false;
    }).androidsdk;
  sdkRoot = "${sdk}/libexec/android-sdk";
  buildTools = "${sdkRoot}/build-tools/${buildToolsVersion}";
  androidJar = "${sdkRoot}/platforms/android-${platformVersion}/android.jar";
  version = lib.strings.trim (builtins.readFile ./version);
in
  stdenvNoCC.mkDerivation {
    pname = "hexrain-wallpaper-unsigned";
    inherit version;

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [./AndroidManifest.xml ./res ./java];
    };

    nativeBuildInputs = [jdk17_headless qt6.qtshadertools zip];
    # qsb wants a UTF-8 locale.
    LANG = "C.UTF-8";
    # qsb is a build tool here; nothing to wrap.
    dontWrapQtApps = true;

    buildPhase = ''
      runHook preBuild
      mkdir -p build/assets build/classes build/dex

      for s in chrome_hexrain chrome_hexrain_cells chrome_hexrain_light; do
        qsb --glsl "300 es" -o build/$s.qsb ${dms}/quickshell/Shaders/frag/$s.frag
        qsb -x "glsl,300 es" -o build/assets/$s.frag build/$s.qsb
      done
      cp ${dms}/quickshell/Shaders/scenes/wallpaper.json build/assets/scene.json

      ${buildTools}/aapt2 compile --dir res -o build/res.zip
      ${buildTools}/aapt2 link -o build/base.apk -I ${androidJar} \
        --manifest AndroidManifest.xml -A build/assets \
        --min-sdk-version 31 --target-sdk-version ${platformVersion} \
        --version-code ${version} --version-name ${version} \
        build/res.zip

      javac --release 11 -encoding UTF-8 -Xlint:all -Werror -classpath ${androidJar} -d build/classes \
        $(find java -name '*.java' | sort)
      ${buildTools}/d8 --release --min-api 31 --lib ${androidJar} --output build/dex \
        $(find build/classes -name '*.class' | sort)

      # Fixed timestamps so the archive is byte-for-byte reproducible.
      cp build/base.apk build/unaligned.apk
      touch -d @315532800 build/dex/classes.dex
      (cd build/dex && TZ=UTC zip -X -q ../unaligned.apk classes.dex)
      ${buildTools}/zipalign -P 16 -f 4 build/unaligned.apk build/hexrain-wallpaper-unsigned.apk
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp build/hexrain-wallpaper-unsigned.apk $out
      runHook postInstall
    '';

    passthru = {inherit buildTools;};
  }
