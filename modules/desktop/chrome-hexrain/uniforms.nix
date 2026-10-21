# chrome_hexrain wallpaper parameters for halmasuit (gnomon's greeter),
# which feeds them to body.glsl as runtime uniforms. Synced
# from the live DMS scene (quickshell/Shaders/scenes/wallpaper.json in
# the DMS fork); floats only (GLSL ES uniform floats), vec4s as
# 4-element lists. Scene keys body.glsl doesn't read are left out: the
# palette-flip set (flip*, color*Next) and rimGlow, which only show
# while a scale turns over; barZoneScreens, a Quickshell-side filter.
{
  # Scene clock rate: DMS's harness.speed, which scales the time it
  # feeds the shader.
  timeScale = 0.25;

  intensity = 0.76;
  cellSize = 31.0;

  colorPrimary = [0.345098 0.592157 0.886275 1.000000]; # #5897e2
  colorSecondary = [0.717647 0.066667 0.858824 1.000000]; # #b711db
  colorPrimaryContainer = [0.090196 0.082353 0.337255 1.000000]; # #171556
  colorTertiary = [0.223529 1.000000 0.600000 1.000000]; # #39ff99

  # Field
  modeAmount = 0.71;
  domeStrength = 0.85;
  seamGlow = 2.5;
  seamBase = 0.3;
  sunDriftSpeed = 1.85;
  heightAmount = 0.63;
  matteness = 0.58;
  hexBevel = 0.38;

  # Scales
  heightRange = 10.75;
  heightDriftSpeed = 1.6;
  tiltMax = 0.12;
  tiltDriftSpeed = 0.85;
  slabThickness = 4.0;
  domeHeight = 8.0;
  cameraDistance = 6700.0;

  # Material
  grainScale = 0.3;
  grainStrength = 0.0;
  keyLight = 0.6;
  scaleShadow = 0.7;
  occlusion = 0.6;

  # Front suns
  frontSunStrength = 0.48;
  frontSunSize = 0.57;
  frontSunLifetime = 45.0;
  frontSunGap = 12.0;
  frontSunSpeed = 0.052;
  frontSunCount = 3.0;
  frontSunHeight = 500.0;
  frontSunPaletteSpeed = 0.5;

  # Front-negative suns
  frontNegSunStrength = 0.3;
  frontNegSunSize = 0.43;
  frontNegSunLifetime = 30.0;
  frontNegSunGap = 15.0;
  frontNegSunSpeed = 0.025;
  frontNegSunCount = 4.0;

  # Back suns
  backSunStrength = 1.0;
  backSunSize = 0.32;
  backSunLifetime = 50.0;
  backSunGap = 15.0;
  backSunSpeed = 0.015;
  backSunCount = 4.0;
  backSunPaletteSpeed = 0.84;

  # Back-negative suns
  backNegSunStrength = 0.43;
  backNegSunSize = 0.33;
  backNegSunLifetime = 35.0;
  backNegSunGap = 18.0;
  backNegSunSpeed = 0.02;
  backNegSunCount = 4.0;

  # Fast back sun
  fastBackSunStrength = 1.12;
  fastBackSunSize = 0.25;
  fastBackSunLifetime = 26.0;
  fastBackSunGap = 37.0;
  fastBackSunSpeed = 0.145;

  # Single-surface mode: windowGeom = (0, 0, width, height). The
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
