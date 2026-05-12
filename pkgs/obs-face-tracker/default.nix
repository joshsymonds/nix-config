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
  fetchurl,
  cmake,
  ninja,
  pkg-config,
  bzip2,
  obs-studio,
  dlib,
  qt6,
}: let
  # CNN face detector and 5-point landmark predictor — dlib's prebuilt
  # data files. The plugin loads these via obs_module_file() at filter-
  # activation time (see face-tracker-manager.cpp:466, 473 in upstream),
  # which searches the plugin's data dir
  # ($out/share/obs/obs-plugins/obs-face-tracker/). They are NOT in
  # nixpkgs (dlib's runtime models aren't packaged), so we fetch them
  # directly from dlib's canonical distribution.
  mmodFaceDetector = fetchurl {
    url = "http://dlib.net/files/mmod_human_face_detector.dat.bz2";
    sha256 = "15g6nm3zpay80a2qch9y81h55z972bk465m7dh1j45mcjx4cm3hw";
  };
  shapePredictor5 = fetchurl {
    url = "http://dlib.net/files/shape_predictor_5_face_landmarks.dat.bz2";
    sha256 = "0wm4bbwnja7ik7r28pv00qrl3i1h6811zkgnjfvzv7jwpyz7ny3f";
  };
in
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
    bzip2
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
    # ENABLE_DATAGEN=ON builds the small `face-detector-dlib-hog-datagen`
    # executable from src/face-detector-dlib-hog-datagen.cpp. The binary
    # just prints `dlib::get_serialized_frontal_faces()` to stdout — i.e.
    # the serialized form of dlib's built-in HOG frontal_face_detector.
    # postInstall below pipes that into the plugin's data dir.
    "-DENABLE_DATAGEN=ON"
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

  # The plugin looks up dlib data files relative to its own install dir via
  # obs_module_file() — searching subpaths `dlib_hog_model/`,
  # `dlib_cnn_model/`, `dlib_face_landmark_model/` under
  # $out/share/obs/obs-plugins/obs-face-tracker/ (see
  # face-tracker-manager.cpp lines 459/466/473 upstream). We populate all
  # three here:
  #   - frontal_face_detector.dat: serialized from dlib's built-in HOG
  #     detector at build time (no network fetch; deterministic output
  #     from `get_serialized_frontal_faces()`).
  #   - mmod_human_face_detector.dat + shape_predictor_5_face_landmarks.dat:
  #     bunzip2 the fetchurl'd archives into place.
  postInstall = ''
    pluginData="$out/share/obs/obs-plugins/obs-face-tracker"
    mkdir -p "$pluginData/dlib_hog_model" \
             "$pluginData/dlib_cnn_model" \
             "$pluginData/dlib_face_landmark_model"

    ./face-detector-dlib-hog-datagen \
      > "$pluginData/dlib_hog_model/frontal_face_detector.dat"

    bunzip2 -c ${mmodFaceDetector} \
      > "$pluginData/dlib_cnn_model/mmod_human_face_detector.dat"
    bunzip2 -c ${shapePredictor5} \
      > "$pluginData/dlib_face_landmark_model/shape_predictor_5_face_landmarks.dat"
  '';

  # Stable path that downstream modules (e.g. home-manager/obs/default.nix
  # configuring the face_tracker_filter) can reference instead of
  # hard-coding the layout above.
  passthru.modelDir = "share/obs/obs-plugins/obs-face-tracker";

  meta = {
    description = "OBS Studio plugin for face-tracking auto-crop / PTZ control";
    homepage = "https://github.com/norihiro/obs-face-tracker";
    license = lib.licenses.gpl2Plus;
    platforms = lib.platforms.linux;
    mainProgram = "obs-face-tracker";
  };
}
