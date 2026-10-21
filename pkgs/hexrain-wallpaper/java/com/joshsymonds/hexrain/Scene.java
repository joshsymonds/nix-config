package com.joshsymonds.hexrain;

import java.util.HashMap;
import java.util.Map;

/**
 * The wallpaper's uniform values: DMS's live scene (wallpaper.json, baked in
 * at build time) fitted to a phone screen.
 *
 * <p>DMS's values were tuned on gnomon: a 5120 px wide canvas at 1x scale.
 * Lengths that size the scales themselves (cell size, heights, thickness,
 * dome) are taken as dp, so the scales come out the size they are on the
 * desktop rather than a few phone pixels; lengths that set the perspective
 * (camera and front-sun heights) scale with the canvas, so the field is
 * seen at the same angles. The suns drift a fraction of the canvas per
 * second, and a phone canvas spans far fewer of those desktop-sized scales,
 * so their drift is sped up by the ratio to cross the scales at the
 * desktop's pace (their lifetimes stay). Everything else in the scene is
 * relative to the canvas or unitless already.
 */
final class Scene {
    private static final float DESKTOP_CANVAS = 5120f;
    private static final String[] SCALE_LENGTHS = {"cellSize", "heightRange", "slabThickness", "domeHeight"};
    private static final String[] VIEW_LENGTHS = {"cameraDistance", "frontSunHeight"};
    private static final String[] SUN_SPEEDS = {
        "backSunSpeed", "backNegSunSpeed", "frontSunSpeed", "frontNegSunSpeed", "fastBackSunSpeed",
    };

    private final Map<String, float[]> values;
    /** DMS's harness.speed: scene seconds per real second. */
    final double timeScale;

    /** `values` holds the scene's uniforms as DMS tuned them (floats, colours as rgba). */
    Scene(Map<String, float[]> values, double timeScale) {
        this.values = values;
        this.timeScale = timeScale;
    }

    double get(String key) {
        float[] v = values.get(key);
        if (v == null) {
            throw new IllegalArgumentException("scene has no " + key);
        }
        return v[0];
    }

    /**
     * The uniforms for a `width` × `height` screen of `density` px per dp:
     * one surface showing the whole canvas, no bar zone (there's no DMS bar
     * on a phone).
     */
    Scene forScreen(int width, int height, float density) {
        Map<String, float[]> out = new HashMap<>(values);
        for (String key : SCALE_LENGTHS) {
            out.put(key, new float[] {(float) get(key) * density});
        }
        out.put("grainScale", new float[] {(float) get("grainScale") / density});
        float canvas = Math.max(width, height) / DESKTOP_CANVAS;
        for (String key : VIEW_LENGTHS) {
            out.put(key, new float[] {(float) get(key) * canvas});
        }
        // Desktop canvas over this one, both in dp: how many times fewer
        // scales the suns have to cross here.
        float sunPace = DESKTOP_CANVAS * density / Math.max(width, height);
        for (String key : SUN_SPEEDS) {
            out.put(key, new float[] {(float) get(key) * sunPace});
        }
        out.put("barZoneEnabled", new float[] {0f});
        out.put("iResolution", new float[] {width, height, 1f});
        out.put("windowGeom", new float[] {0f, 0f, width, height});
        out.put("qt_Opacity", new float[] {1f});
        out.put("qt_Matrix", new float[] {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1});
        return new Scene(out, timeScale);
    }

    /**
     * Every uniform for the frame at scene time `t` (seconds): the scene's
     * values plus the clocks, the pre-pass geometry and the sun slots.
     */
    Map<String, float[]> frame(HexrainGrid grid, double t) {
        Map<String, float[]> out = new HashMap<>(values);
        out.put("iTime", new float[] {(float) t});
        out.put("heightClock", new float[] {(float) (t * get("heightDriftSpeed"))});
        out.put("tiltClock", new float[] {(float) (t * get("tiltDriftSpeed"))});
        out.put("backPaletteClock", new float[] {(float) (t * get("backSunPaletteSpeed"))});
        out.put("frontPaletteClock", new float[] {(float) (t * get("frontSunPaletteSpeed"))});
        out.put("gridCols", new float[] {grid.cols});
        out.put("gridRows", new float[] {grid.rows});
        out.put("gridMargin", new float[] {HexrainGrid.MARGIN});
        out.put("gridCellTexels", new float[] {HexrainGrid.CELL_TEXELS});
        out.put("lightCols", new float[] {grid.lightCols});
        out.put("lightRows", new float[] {grid.lightRows});
        out.put("lightTexelPx", new float[] {HexrainGrid.LIGHT_TEXEL_PX});
        float[] res = values.get("iResolution");
        SunField.field(this, t, res[0], res[1], out);
        return out;
    }
}
