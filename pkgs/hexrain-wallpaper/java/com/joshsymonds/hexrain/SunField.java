package com.joshsymonds.hexrain;

import java.util.Map;

/**
 * Sun placement for the light pass: a port of DMS's
 * quickshell/Common/SunField.js. Every pixel of a frame shares the same sun
 * positions, so they are computed here once per frame and handed to the
 * shader as per-slot uniforms.
 *
 * <p>The hash and noise are the shaders' own in float32 (Java float
 * arithmetic rounds each operation like the JS port's Math.fround). Every
 * rate is constant here, so each clock SunField.advance integrates is
 * rate × scene time.
 */
final class SunField {
    /** Slots per category; the light pass declares this many uniforms per category. */
    static final int SLOTS = 10;

    // Per-category slot-id offsets: the same slot index in two categories
    // hashes to a different trajectory.
    private static final float BACK_ID = 7f;
    private static final float FAST_BACK_ID = 401f;
    private static final float BACK_NEG_ID = 101f;
    private static final float FRONT_ID = 211f;
    private static final float FRONT_NEG_ID = 307f;

    private static final float MARGIN = 0.18f;

    private SunField() {}

    static float fract(float x) {
        return x - (float) Math.floor(x);
    }

    static float clamp(float x, float lo, float hi) {
        return Math.min(Math.max(x, lo), hi);
    }

    static float mix(float a, float b, float t) {
        return a * (1f - t) + b * t;
    }

    static float smoothstep(float e0, float e1, float x) {
        float t = clamp((x - e0) / (e1 - e0), 0f, 1f);
        return t * t * (3f - 2f * t);
    }

    static float hash(float x, float y) {
        float px = fract(x * 123.34f);
        float py = fract(y * 456.21f);
        float d = px * (px + 45.32f) + py * (py + 45.32f);
        px += d;
        py += d;
        return fract(px * py);
    }

    static float noise(float x, float y) {
        float ix = (float) Math.floor(x);
        float iy = (float) Math.floor(y);
        float fx = fract(x);
        float fy = fract(y);
        fx = fx * fx * (3f - 2f * fx);
        fy = fy * fy * (3f - 2f * fy);
        return mix(mix(hash(ix, iy), hash(ix + 1f, iy), fx),
                   mix(hash(ix, iy + 1f), hash(ix + 1f, iy + 1f), fx),
                   fy);
    }

    /**
     * One sun appearance cycle: fade in at a hashed point, wander a 2D noise
     * path for `lifetime` seconds, fade out, then sit dark for (up to) `gap`
     * seconds before the slot respawns somewhere new. `cycles` counts
     * appearance cycles elapsed for the slot's category and `wander` how far
     * along the noise path it has drifted.
     *
     * @return {x, y, active, appearanceHash}: canvas position, 0..1
     *     visibility (smooth fade at the ends), and a per-appearance hash the
     *     shader uses to pick palette phase
     */
    static float[] placement(float slotId, float lifetime, float gap, double cycles, double wander,
                             float resX, float resY) {
        float period = Math.max(lifetime + gap, 0.05f);
        float seedX = slotId * 41f + 17f;
        // Per-slot phase (fraction of a cycle) so slots don't spawn together.
        double cyclePos = cycles - hash(seedX, 7.3f);
        double cycleIdx = Math.floor(cyclePos);
        float cycleT = (float) ((cyclePos - cycleIdx) * period);
        float seedY = (float) (cycleIdx * 31) + 5f;

        float life = cycleT - hash(seedX, seedY + 23f) * gap;
        float fInLife = clamp(life / Math.max(lifetime, 0.001f), 0f, 1f);
        float alive = (life >= 0f && lifetime >= life) ? 1f : 0f;
        float fade = smoothstep(0f, 0.08f, fInLife) * smoothstep(1f, 0.92f, fInLife);

        float ox = hash(seedX + 7f, seedY) * 100f;
        float oy = hash(seedX, seedY + 7f) * 100f;
        float drift = (float) wander;
        float wx = noise(drift + ox, slotId * 13f + 11f);
        float wy = noise(drift + oy, slotId * 13f + 91f);

        return new float[] {
            resX * mix(-MARGIN, 1f + MARGIN, wx),
            resY * mix(-MARGIN, 1f + MARGIN, wy),
            alive * fade,
            hash(seedX + 41f, seedY + 17f),
        };
    }

    /**
     * Placements for one category's slots at scene time `t`. A fractional
     * count fades its last slot in with the fraction; slots past the count
     * are zero.
     */
    private static float[][] category(Scene scene, String prefix, float baseId, double t, float resX, float resY) {
        double count = scene.get(prefix + "Count");
        int n = (int) Math.min(SLOTS, Math.max(0, Math.ceil(count - 1e-6)));
        float[][] out = new float[SLOTS][4];
        for (int s = 0; s < n; s++) {
            out[s] = categoryPlacement(scene, prefix, s + baseId, t, resX, resY);
            out[s][2] *= (float) Math.min(Math.max(count - s, 0), 1);
        }
        return out;
    }

    // Appearance cycles run at sunDriftSpeed / (lifetime + gap), the noise
    // path at sunDriftSpeed × speed.
    private static float[] categoryPlacement(Scene scene, String prefix, float slotId, double t,
                                             float resX, float resY) {
        double lifetime = scene.get(prefix + "Lifetime");
        double gap = scene.get(prefix + "Gap");
        double drift = scene.get("sunDriftSpeed");
        double cycles = t * drift / Math.max(lifetime + gap, 0.05);
        double wander = t * drift * scene.get(prefix + "Speed");
        return placement(slotId, (float) lifetime, (float) gap, cycles, wander, resX, resY);
    }

    /** Puts every sun slot uniform for scene time `t` into `values`. */
    static void field(Scene scene, double t, float resX, float resY, Map<String, float[]> values) {
        putSlots(values, "backSun", category(scene, "backSun", BACK_ID, t, resX, resY));
        putSlots(values, "backNegSun", category(scene, "backNegSun", BACK_NEG_ID, t, resX, resY));
        putSlots(values, "frontSun", category(scene, "frontSun", FRONT_ID, t, resX, resY));
        putSlots(values, "frontNegSun", category(scene, "frontNegSun", FRONT_NEG_ID, t, resX, resY));
        values.put("fastBackSun", categoryPlacement(scene, "fastBackSun", FAST_BACK_ID, t, resX, resY));
    }

    private static void putSlots(Map<String, float[]> values, String name, float[][] slots) {
        for (int s = 0; s < SLOTS; s++) {
            values.put(name + s, slots[s]);
        }
    }
}
