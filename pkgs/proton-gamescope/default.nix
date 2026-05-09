{
  stdenvNoCC,
  lib,
  proton-ge-bin,
  gamescope,
  bash,
}: let
  protonGe = proton-ge-bin.steamcompattool;
in
  stdenvNoCC.mkDerivation {
    pname = "proton-gamescope";
    version = "0.1.0";

    src = ./.;

    # Mirrors proton-ge-bin's two-output shape: 'out' is a marker that
    # complains if anyone installs the package normally; Steam consumes
    # 'steamcompattool' via STEAM_EXTRA_COMPAT_TOOLS_PATHS.
    outputs = ["out" "steamcompattool"];

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      cat > $out <<EOF
      proton-gamescope is a Steam compatibility tool. Add it to programs.steam.extraCompatPackages alongside proton-ge-bin instead of installing as a package.
      EOF

      mkdir -p $steamcompattool

      cat > $steamcompattool/compatibilitytool.vdf <<'VDF'
      "compatibilitytools"
      {
        "compat_tools"
        {
          "Proton-Gamescope"
          {
            "install_path" "."
            "display_name" "Proton (Gamescope)"
            "from_oslist"  "windows"
            "to_oslist"    "linux"
          }
        }
      }
      VDF

      # No require_tool_appid here. Modern Steam wraps every compat
      # tool launch in the Steam Linux Runtime sniper container
      # automatically (declaring it ourselves would be redundant), and
      # this mirrors the proven-working per-game `gamescope ... -- %command%`
      # launch-option pattern: gamescope inside the sniper, Proton inside
      # gamescope.
      cat > $steamcompattool/toolmanifest.vdf <<'VDF'
      "manifest"
      {
        "version" "2"
        "commandline" "/run.sh %verb%"
        "use_sessions" "1"
      }
      VDF

      install -Dm755 $src/run.sh $steamcompattool/run.sh
      substituteInPlace $steamcompattool/run.sh \
        --replace-fail '@bash@' '${bash}' \
        --replace-fail '@proton@' '${protonGe}/proton' \
        --replace-fail '@gamescope@' '${gamescope}/bin/gamescope'

      runHook postInstall
    '';

    meta = with lib; {
      description = "Steam compatibility tool that runs Proton-GE inside niri-friendly gamescope";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  }
