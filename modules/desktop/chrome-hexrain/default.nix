# chrome_hexrain — DMS's hexrain wallpaper as a single fragment shader, for
# halmasuit's wallpaper engine (gnomon's greeter).
#
# body.glsl is the shader body (mainImage + helpers): DMS's multi-pass
# chrome_hexrain wallpaper as a single pass. uniforms.nix is the
# parameter set, synced from the live DMS scene. halmasuitSource is the
# GLSL ES 100 fragment source halmasuit compiles: each parameter a runtime
# `uniform`, fed from services.halmasuit.wallpaper.uniforms, with
# halmasuit's own preamble (iTime/iResolution/etc).
#
# Edit body.glsl or uniforms.nix and gnomon picks it up on its next
# `update`. shrike renders the same wallpaper through its own app
# (pkgs/hexrain-wallpaper), which runs DMS's shaders directly.
{lib}: rec {
  uniforms = import ./uniforms.nix;

  glslType = v:
    if builtins.isList v
    then "vec4"
    else "float";

  body = builtins.readFile ./body.glsl;

  halmasuitSource = pkgs:
    pkgs.writeText "chrome-hexrain-halmasuit.glsl" ''
      // Assembled by modules/desktop/chrome-hexrain (halmasuit target).
      // halmasuit's shader compiler prepends its GLSL ES 100 preamble
      // declaring iTime/iResolution/iTimeDelta/iFrame/iMouse and wraps
      // mainImage, passing gl_FragCoord.xy (y down: halmasuit renders
      // into scanout buffers top row first); uniform values arrive at
      // runtime from services.halmasuit.wallpaper.uniforms.

      precision highp float;
      precision highp int;

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
          name: v: "uniform ${glslType v} ${name};"
        )
        uniforms)}

      ${body}
    '';
}
