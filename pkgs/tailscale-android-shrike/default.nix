# tailscale-android-shrike — Tailscale for Android 1.104.5 plus tailscale-
# android PR #901 (the multiTUN double-close fix), built as a release APK and
# signed with this repo's own agenix keystore. `nix run
# .#tailscale-android-shrike` does the work; see release.sh for the pins,
# the checks and the outputs. The script never writes into the repository.
#
# Building accepts the Android SDK license (androidenv's licenseAccepted),
# scoped to this package.
{
  lib,
  writeShellApplication,
  androidenv,
  jdk21_headless,
  age,
  bash,
  coreutils,
  curl,
  diffutils,
  findutils,
  gawk,
  gcc,
  git,
  gnumake,
  gnugrep,
  gnused,
  gnutar,
  gzip,
  unzip,
  zip,
}: let
  buildToolsVersion = "36.0.0";
  platformVersion = "36";
  sdk =
    ((androidenv.override {licenseAccepted = true;}).composeAndroidPackages {
      platformVersions = [platformVersion];
      buildToolsVersions = [buildToolsVersion];
      includeNDK = true;
      ndkVersions = ["23.1.7779620"];
      includeEmulator = false;
      includeSystemImages = false;
      includeSources = false;
    }).androidsdk;
  sdkRoot = "${sdk}/libexec/android-sdk";
  # multitun-test.sh finds multitun_test.go beside itself, so both go in one
  # store directory.
  multitunTest = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./multitun-test.sh ./multitun_test.go];
  };
in
  writeShellApplication {
    name = "tailscale-android-shrike";
    runtimeInputs = [
      age
      bash
      coreutils
      curl
      diffutils
      findutils
      gawk
      gcc
      git
      gnumake
      gnugrep
      gnused
      gnutar
      gzip
      jdk21_headless
      unzip
      zip
    ];
    runtimeEnv = {
      ANDROID_HOME = sdkRoot;
      ANDROID_SDK_ROOT = sdkRoot;
      JAVA_HOME = "${jdk21_headless}";
      TS_BUILD_TOOLS = "${sdkRoot}/build-tools/${buildToolsVersion}";
      TS_PATCH = "${./pr901-multitun.patch}";
      TS_SIGNER_PIN = "${./signer.sha256}";
      TS_KEYSTORE = "${../../secrets/user/tailscale-android-shrike-keystore.age}";
      TS_MULTITUN_TEST = "${multitunTest}/multitun-test.sh";
    };
    text = builtins.readFile ./release.sh;
  }
