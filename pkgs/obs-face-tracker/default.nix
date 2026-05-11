# OBS Studio plugin: Norihiro Kamae's face tracker.
#
# Detects faces with dlib (HOG by default) on a worker thread, smooths the
# crop rect with a Kalman-style filter, and applies a GPU resample via OBS's
# effect system. Drives the V1 auto-zoom-follow ("Center Stage") behavior.
#
# Source pinned to upstream norihiro/obs-face-tracker 0.9.1 for now. Once we
# add an OpenCV DNN detector backend (V2 prerequisite — better small-face
# recall, GPU-capable, drops the dlib-HOG dependency on CPU-only single-
# thread inference), switch this to fetchFromGitHub joshsymonds/obs-face-
# tracker. The fork lives in ~/Personal/obs-face-tracker.
#
# Build choices:
#   -DWITH_DLIB_SUBMODULE=OFF — link against nixpkgs `dlib` instead of
#     the upstream's vendored ~200 MB submodule. Saves source close, saves
#     a from-source dlib build per kernel/compiler bump.
#   -DWITH_PTZ_TCP=OFF — disables the libvisca PTZ-over-TCP integration
#     for hardware PTZ cameras (no Visca camera on this host).
#   -DWITH_DOCK=ON (default) — keep the Qt6 dock so live parameter tuning
#     works without recompiling.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  obs-studio,
  dlib,
  qt6,
}:
stdenv.mkDerivation rec {
  pname = "obs-face-tracker";
  version = "0.9.1";

  src = fetchFromGitHub {
    owner = "norihiro";
    repo = "obs-face-tracker";
    rev = version;
    hash = "sha256-eXh8zjbDP6mrWxCMHWFtNjQyRlRKocjThYOZqBi0ik8=";
    # fetchSubmodules=false: we use system dlib via WITH_DLIB_SUBMODULE=OFF
    # below, and libvisca is excluded by WITH_PTZ_TCP=OFF.
    fetchSubmodules = false;
  };

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    qt6.wrapQtAppsHook
  ];

  buildInputs = [
    obs-studio
    dlib
    qt6.qtbase
  ];

  # The dock UI's obsgui-helper.hpp includes <qpa/qplatformnativeinterface.h>
  # (a Qt platform-private header), so Qt::GuiPrivate is genuinely needed.
  # But the plugin's find_qt() call only asks for `Widgets Core Gui`, so
  # the GuiPrivate target is never imported into CMake's target graph and
  # the subsequent target_link_libraries fails to resolve it. Add
  # GuiPrivate to the COMPONENTS list so the private include path is
  # propagated correctly.
  postPatch = ''
    substituteInPlace CMakeLists.txt \
      --replace-fail "find_qt(VERSION \''${QT_VERSION} COMPONENTS Widgets Core Gui)" \
                     "find_qt(VERSION \''${QT_VERSION} COMPONENTS Widgets Core Gui GuiPrivate)"
  '';

  cmakeFlags = [
    "-DWITH_DLIB_SUBMODULE=OFF"
    "-DWITH_PTZ_TCP=OFF"
    "-DENABLE_DATAGEN=OFF"
    # The plugin's bundled ObsPluginHelpers.cmake defaults QT_VERSION to 5;
    # obs-studio in nixpkgs is Qt6-only, so force the Qt6 path explicitly.
    "-DQT_VERSION=6"
    # LINUX_PORTABLE=ON (the helpers' default) installs to
    # $out/obs-plugins/64bit/*.so + $out/data/. wrapOBS expects the
    # FHS-style $out/lib/obs-plugins/*.so + $out/share/obs/obs-plugins/.
    # Switch to the non-portable layout so the wrapper's symlinkJoin
    # finds the plugin without any postInstall acrobatics.
    "-DLINUX_PORTABLE=OFF"
  ];

  meta = {
    description = "OBS Studio plugin for face-tracking auto-crop / PTZ control";
    homepage = "https://github.com/norihiro/obs-face-tracker";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
    mainProgram = "obs-face-tracker";
  };
}
