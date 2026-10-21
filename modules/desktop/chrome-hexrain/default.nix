# chrome_hexrain — one shader, two render targets.
#
# body.glsl is the shared shader body (mainImage + helpers): DMS's
# multi-pass chrome_hexrain wallpaper as a single pass. uniforms.nix is
# the shared parameter set. This file assembles the two consumable
# variants:
#
#   halmasuitSource — GLSL ES 100 fragment source for halmasuit's
#     wallpaper engine (gnomon). Declares each parameter as a runtime
#     `uniform`; halmasuit feeds the values from
#     services.halmasuit.wallpaper.uniforms and injects its own
#     preamble (iTime/iResolution/etc).
#
#   androidSource — a self-contained `#version 300 es` shader for the
#     Shader Editor app on shrike (de.markusfisch.android.shadereditor).
#     Same body; parameters baked as consts (Shader Editor can't be fed
#     uniforms externally), iTime from the app's `runtime` (highp, keeps
#     counting across wallpaper pauses), iResolution from `resolution`,
#     fragCoord flipped to the body's y-down canvas, windowGeom collapsed
#     to the whole surface, bar zone off (no DMS bar on a phone), alpha
#     forced opaque.
#
# Edit body.glsl or uniforms.nix and both targets pick it up on their
# next rebuild (gnomon: `update`; shrike: `update`, then re-paste into
# Shader Editor — its shader storage is app-internal).
{lib}: rec {
  uniforms = import ./uniforms.nix;

  # 0.66 -> "0.660000" etc. Nix float toString output is valid GLSL.
  glslFloat = v: toString (v + 0.0);
  glslValue = v:
    if builtins.isList v
    then "vec4(${lib.concatMapStringsSep ", " glslFloat v})"
    else glslFloat v;
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

  androidSource = pkgs: let
    # Phone-specific parameter overrides. windowGeom is handled as a
    # macro below (it depends on the runtime resolution).
    phoneUniforms =
      builtins.removeAttrs uniforms ["windowGeom"]
      // {
        barZoneEnabled = 0.0;
      };
  in
    pkgs.writeText "chrome-hexrain-shadereditor.glsl" ''
      #version 300 es
      // Assembled by modules/desktop/chrome-hexrain (Shader Editor
      // target). Paste the whole file into a new shader in the Shader
      // Editor app, then: system wallpaper picker -> Live wallpapers ->
      // Shader Editor -> apply to home + lock screen. It renders at the
      // display's refresh rate (the app has no frame cap); if the
      // editor's FPS readout falls below that, lower the quality
      // spinner (render resolution).

      precision highp float;
      precision highp int;

      uniform highp float runtime;
      uniform vec2 resolution;
      out vec4 outColor;

      #define iTime runtime
      #define iResolution vec3(resolution, 1.0)
      #define windowGeom vec4(0.0, 0.0, resolution)

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
          name: v: "const ${glslType v} ${name} = ${glslValue v};"
        )
        phoneUniforms)}

      ${body}

      void main() {
          vec4 c;
          mainImage(c, vec2(gl_FragCoord.x, resolution.y - gl_FragCoord.y));
          outColor = vec4(c.rgb, 1.0);
      }
    '';
}
