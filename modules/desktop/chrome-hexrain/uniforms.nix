# chrome_hexrain wallpaper parameters — the single source of values for
# BOTH render targets (halmasuit on gnomon feeds these as runtime
# uniforms; shrike's Shader Editor export bakes them as consts). Synced
# byte-equivalently from the user's live DMS scene-editor state; floats
# only (GLSL ES uniform floats), vec4s as 4-element lists.
{
  intensity = 0.66;
  cellSize = 29.0;

  colorPrimary = [0.345098 0.592157 0.886275 1.0]; # #5897e2
  colorSecondary = [0.717647 0.066667 0.858824 1.0]; # #b711db
  colorPrimaryContainer = [0.090196 0.082353 0.337255 1.0]; # #171556
  colorTertiary = [0.223529 1.000000 0.600000 1.0]; # #39ff99

  colorPrimaryNext = [0.223529 1.000000 0.600000 1.0]; # #39ff99
  colorSecondaryNext = [1.000000 0.466667 0.200000 1.0]; # #ff7733
  colorPrimaryContainerNext = [0.337255 0.082353 0.082353 1.0]; # #561515
  colorTertiaryNext = [1.000000 0.847059 0.290196 1.0]; # #ffd84a
  flipOriginX = 200.0;
  flipOriginY = 700.0;
  flipStartTime = 1.0e9; # far future — flip wave inert
  flipPropDelay = 0.12;
  flipDuration = 1.6;

  modeAmount = 0.77;
  domeStrength = 0.78;
  seamGlow = 2.26;
  sunDriftSpeed = 1.8;
  heightAmount = 0.55;
  matteness = 0.42;
  bleedBack = 0.18;
  hexBevel = 0.6;
  heightDriftSpeed = 0.75;

  frontSunStrength = 0.62;
  frontSunSize = 0.57;
  frontSunLifetime = 45.0;
  frontSunGap = 12.0;
  frontSunSpeed = 0.02;
  frontSunShadowLength = 2.5;
  frontSunShadowDarkness = 2.3;
  backSunSize = 0.32;
  backSunStrength = 1.0;
  backSunLifetime = 50.0;
  backSunGap = 15.0;
  backSunSpeed = 0.015;
  backNegSunSize = 0.33;
  backNegSunStrength = 0.43;
  backNegSunLifetime = 35.0;
  backNegSunGap = 18.0;
  backNegSunSpeed = 0.02;
  backSunPaletteSpeed = 0.84;
  frontSunPaletteSpeed = 0.5;
  backSunCount = 4.0;
  backNegSunCount = 4.0;
  frontSunCount = 4.0;
  frontNegSunCount = 4.0;
  frontNegSunStrength = 0.3;
  frontNegSunSize = 0.43;
  frontNegSunLifetime = 30.0;
  frontNegSunGap = 15.0;
  frontNegSunSpeed = 0.025;
  fastBackSunStrength = 1.12;
  fastBackSunSize = 0.25;
  fastBackSunLifetime = 26.0;
  fastBackSunGap = 37.0;
  fastBackSunSpeed = 0.145;

  # Single-monitor mode: windowGeom = (0, 0, width, height). The
  # actual resolution is filled in at runtime by the wallpaper
  # engine — but we declare it here so the uniform exists.
  # gnomon's DP-2/DP-3 are both 2560x1440.
  windowGeom = [0.0 0.0 2560.0 1440.0];

  barZoneEnabled = 1.0; # DMS scene has it on; barZoneScreens
  # = [ "DP-2" ] is Quickshell-side only.
  barZoneAnchor = 2.0;
  barZoneThickness = 80.0;
  barZoneElevation = 2.0;
}
