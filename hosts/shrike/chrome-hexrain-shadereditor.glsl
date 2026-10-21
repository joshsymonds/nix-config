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

const float backNegSunCount = 4.000000;
const float backNegSunGap = 18.000000;
const float backNegSunLifetime = 35.000000;
const float backNegSunSize = 0.330000;
const float backNegSunSpeed = 0.020000;
const float backNegSunStrength = 0.430000;
const float backSunCount = 4.000000;
const float backSunGap = 15.000000;
const float backSunLifetime = 50.000000;
const float backSunPaletteSpeed = 0.840000;
const float backSunSize = 0.320000;
const float backSunSpeed = 0.015000;
const float backSunStrength = 1.000000;
const float barZoneAnchor = 2.000000;
const float barZoneElevation = 2.000000;
const float barZoneEnabled = 0.000000;
const float barZoneThickness = 80.000000;
const float cameraDistance = 6700.000000;
const float cellSize = 31.000000;
const vec4 colorPrimary = vec4(0.345098, 0.592157, 0.886275, 1.000000);
const vec4 colorPrimaryContainer = vec4(0.090196, 0.082353, 0.337255, 1.000000);
const vec4 colorSecondary = vec4(0.717647, 0.066667, 0.858824, 1.000000);
const vec4 colorTertiary = vec4(0.223529, 1.000000, 0.600000, 1.000000);
const float domeHeight = 8.000000;
const float domeStrength = 0.850000;
const float fastBackSunGap = 37.000000;
const float fastBackSunLifetime = 26.000000;
const float fastBackSunSize = 0.250000;
const float fastBackSunSpeed = 0.145000;
const float fastBackSunStrength = 1.120000;
const float frontNegSunCount = 4.000000;
const float frontNegSunGap = 15.000000;
const float frontNegSunLifetime = 30.000000;
const float frontNegSunSize = 0.430000;
const float frontNegSunSpeed = 0.025000;
const float frontNegSunStrength = 0.300000;
const float frontSunCount = 3.000000;
const float frontSunGap = 12.000000;
const float frontSunHeight = 500.000000;
const float frontSunLifetime = 45.000000;
const float frontSunPaletteSpeed = 0.500000;
const float frontSunSize = 0.570000;
const float frontSunSpeed = 0.052000;
const float frontSunStrength = 0.480000;
const float grainScale = 0.300000;
const float grainStrength = 0.000000;
const float heightAmount = 0.630000;
const float heightDriftSpeed = 1.600000;
const float heightRange = 10.750000;
const float hexBevel = 0.380000;
const float intensity = 0.760000;
const float keyLight = 0.600000;
const float matteness = 0.580000;
const float modeAmount = 0.710000;
const float occlusion = 0.600000;
const float scaleShadow = 0.700000;
const float seamBase = 0.300000;
const float seamGlow = 2.500000;
const float slabThickness = 4.000000;
const float sunDriftSpeed = 1.850000;
const float tiltDriftSpeed = 0.850000;
const float tiltMax = 0.120000;
const float timeScale = 0.250000;

// chrome_hexrain — single-pass body of DMS's hexrain wallpaper
// (quickshell/Shaders/frag/chrome_hexrain*.frag in the DMS fork) for
// renderers that run one fragment shader and nothing else: halmasuit's
// wallpaper engine and the Shader Editor app. DMS computes the per-cell
// data (cell pass), the sun field (light pass) and the sun placements
// (SunField.js) once per frame; here every fragment derives the ones it
// needs. Valid GLSL ES 100 and 300 es; the targets declare the
// parameters (uniforms.nix) and iTime / iResolution and call
// mainImage(fragColor, fragCoord) with fragCoord in canvas pixels, y down.
//
// The field is a layer of thin hexagonal scales floating over a glowing
// underlayer, seen through a perspective camera hung cameraDistance px
// above the centre of the canvas, looking straight down. Each scale has
// its own height and tilt; each fragment casts a ray against the scale
// under it and, near edges, its neighbours, then shades the nearest hit:
// domed matte faces, key light with the scales' drop shadows, front-sun
// light, and the underglow streaming out over a scale wherever a
// neighbour floats high enough above it to leave an opening, the seam
// beside it glowing to match. Rays that miss every scale show the
// underglow through the gap. A faint 2D layer of light streams along the
// hex edges blends in by 1 - modeAmount.
//
// DMS's palette-flip wave (and so the scales' rims, which show only while
// a scale turns over) is not carried: neither target has a palette change
// to animate. Every rate is constant, so each clock DMS integrates is
// rate × scene time, and scene time is iTime × timeScale.

const float PI3 = 1.04719755;        // π / 3
const float TWO_PI = 6.28318531;

// Key light: a soft fixed light from the upper left, about 45° up
// (unit vector toward the light; canvas y runs down).
const vec3 KEY_DIR = vec3(-0.45113, -0.55138, 0.70175);

// Px over which a face fades into the seam glow at an edge where light
// pours out of the gap (scaled by that opening). The glow is what the gap
// shows, so there the face's edge and the gap meet at the same colour and
// the bright seam can't alias; level edges get no fade band, just the
// gap's antialiased hairline.
const float HALO_PX = 1.0;

// Scales are ray-tested grown by this much so the pixels just outside an
// outline still find the face (see scaleField).
const float AA_PX = 0.75;

float sdHexagon(vec2 p, float i) {
    const vec3 k = vec3(-0.866025404, 0.5, 0.577350269);
    p = abs(p);
    p -= 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
    p -= vec2(clamp(p.x, -k.z * i, k.z * i), i);
    return length(p) * sign(p.y);
}

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 f = fract(p);
    vec2 i_ = floor(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(hash(i_ + vec2(0.0, 0.0)), hash(i_ + vec2(1.0, 0.0)), f.x),
        mix(hash(i_ + vec2(0.0, 1.0)), hash(i_ + vec2(1.0, 1.0)), f.x),
        f.y
    );
}

float fbm(vec2 p) {
    return 0.5 * noise(p) + 0.25 * noise(p * 2.0);
}

vec3 rotate(vec4 q, vec3 v) {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

// ── Suns ─────────────────────────────────────────────────────────────

// Smooth palette cycle: maps a continuous phase to a colour that morphs
// through primary → secondary → tertiary → primary as the phase walks
// 0 → 1 → 2 → 3.
vec3 paletteCycle(float phase) {
    phase = mod(phase, 3.0);
    float frac = fract(phase);
    if (phase < 1.0) return mix(colorPrimary.rgb, colorSecondary.rgb, frac);
    if (phase < 2.0) return mix(colorSecondary.rgb, colorTertiary.rgb, frac);
    return mix(colorTertiary.rgb, colorPrimary.rgb, frac);
}

// One sun appearance cycle for slot `slotId` at scene time t: fade in at
// a hashed point, wander a 2D noise path for `lifetime` seconds, fade
// out, then sit dark for (up to) `gap` seconds before the slot respawns
// somewhere new. Cycles run at sunDriftSpeed / (lifetime + gap), the
// noise path at sunDriftSpeed × speed.
//
// Returns (x, y, active, appearanceHash): canvas position, 0..1
// visibility (smooth fade at the ends), and a per-appearance hash the
// palette phase uses.
vec4 sunPlacement(float slotId, float lifetime, float gap, float speed, float t) {
    float period = max(lifetime + gap, 0.05);
    float seedX = slotId * 41.0 + 17.0;
    // Per-slot phase (fraction of a cycle) so slots don't spawn together.
    float cyclePos = t * sunDriftSpeed / period - hash(vec2(seedX, 7.3));
    float cycleIdx = floor(cyclePos);
    float cycleT = (cyclePos - cycleIdx) * period;
    float seedY = cycleIdx * 31.0 + 5.0;

    float life = cycleT - hash(vec2(seedX, seedY + 23.0)) * gap;
    float fInLife = clamp(life / max(lifetime, 0.001), 0.0, 1.0);
    float alive = (life >= 0.0 && lifetime >= life) ? 1.0 : 0.0;
    float fade = smoothstep(0.0, 0.08, fInLife) * smoothstep(1.0, 0.92, fInLife);

    float ox = hash(vec2(seedX + 7.0, seedY)) * 100.0;
    float oy = hash(vec2(seedX, seedY + 7.0)) * 100.0;
    float drift = t * sunDriftSpeed * speed;
    vec2 wander = vec2(noise(vec2(drift + ox, slotId * 13.0 + 11.0)),
                       noise(vec2(drift + oy, slotId * 13.0 + 91.0)));
    vec2 pos = iResolution.xy * mix(vec2(-0.18), vec2(1.18), wander);
    return vec4(pos, alive * fade, hash(vec2(seedX + 41.0, seedY + 17.0)));
}

// Slots a (possibly fractional) sun count touches; the last one fades in
// with the fraction (sunCountMask).
int sunSlots(float count) {
    return int(min(ceil(count - 1e-6), 10.0));
}

float sunCountMask(float count, int s) {
    return clamp(count - float(s), 0.0, 1.0);
}

// The sun field at one canvas point. Every sun is a gaussian hundreds to
// thousands of pixels wide, so evaluating it once per fragment (at the
// fragment's canvas point, rather than where its ray lands) is visually
// exact.
struct Light {
    vec3 underglow;    // back-sun light, hue-capped, dimmed by negative suns
    float frontReach;  // front-sun reach, summed and clamped
    vec3 frontColor;   // front-sun colour
    float frontDark;   // front-negative-sun darkness
    vec3 frontDir;     // dominant front-light direction (unit, toward the suns)
};

Light sunLight(vec2 px, float t) {
    Light l;
    float canvasMax = max(iResolution.x, iResolution.y);

    // Back suns: each slot owns a 1/count slice of the palette (so two
    // can't pile onto the same hue at spawn); the appearance hash dithers
    // within it and varies the slot's palette rate (0.6x..1.4x) so
    // neighbours drift past each other only briefly.
    float sigma = max(backSunSize * canvasMax, 1.0);
    float invSig2 = 1.0 / (sigma * sigma);
    int nBack = sunSlots(backSunCount);
    float segWidth = 3.0 / max(backSunCount, 1.0);
    vec3 lightRaw = vec3(0.0);
    for (int s = 0; s < 10; s++) {
        if (s >= nBack) break;
        vec4 place = sunPlacement(float(s) + 7.0, backSunLifetime, backSunGap, backSunSpeed, t);
        vec2 d = px - place.xy;
        float phase = t * backSunPaletteSpeed * 0.1 * (0.6 + place.w * 0.8)
                    + float(s) * segWidth + (place.w - 0.5) * segWidth * 0.8;
        lightRaw += paletteCycle(phase) * exp(-dot(d, d) * invSig2)
                  * place.z * sunCountMask(backSunCount, s);
    }
    lightRaw *= backSunStrength;

    // Fast back sun: one streak with its own clock, layered over the slow
    // pool before the hue cap so overlap saturates gracefully.
    if (fastBackSunStrength > 0.001) {
        vec4 place = sunPlacement(401.0, fastBackSunLifetime, fastBackSunGap, fastBackSunSpeed, t);
        float fbSigma = max(fastBackSunSize * canvasMax, 1.0);
        vec2 d = px - place.xy;
        lightRaw += paletteCycle(t * backSunPaletteSpeed * 0.1 + place.w * 3.0)
                  * exp(-dot(d, d) / (fbSigma * fbSigma)) * place.z * fastBackSunStrength;
    }

    // Hue-preserving cap: overlapping saturated suns would otherwise clip
    // to neutral white.
    l.underglow = lightRaw / max(max(lightRaw.r, max(lightRaw.g, lightRaw.b)), 1.0);

    // Negative back suns: drifting dark patches in the underglow.
    float negSigma = max(backNegSunSize * canvasMax, 1.0);
    float negInvSig2 = 1.0 / (negSigma * negSigma);
    int nBackNeg = sunSlots(backNegSunCount);
    for (int s = 0; s < 10; s++) {
        if (s >= nBackNeg) break;
        vec4 place = sunPlacement(float(s) + 101.0, backNegSunLifetime, backNegSunGap, backNegSunSpeed, t);
        vec2 d = place.xy - px;
        l.underglow *= 1.0 - clamp(exp(-dot(d, d) * negInvSig2) * backNegSunStrength
                                   * place.z * sunCountMask(backNegSunCount, s), 0.0, 0.98);
    }

    // Front suns: localised spotlights hanging frontSunHeight px above
    // the canvas.
    float frontSigma = max(frontSunSize * canvasMax * 0.5, 1.0);
    float frontInvSig2 = 1.0 / (frontSigma * frontSigma);
    int nFront = sunSlots(frontSunCount);
    l.frontReach = 0.0;
    vec3 dir = vec3(0.0);
    for (int s = 0; s < 10; s++) {
        if (s >= nFront) break;
        vec4 place = sunPlacement(float(s) + 211.0, frontSunLifetime, frontSunGap, frontSunSpeed, t);
        vec2 toSun = place.xy - px;
        float reach = exp(-dot(toSun, toSun) * frontInvSig2) * place.z * sunCountMask(frontSunCount, s);
        l.frontReach += reach;
        dir += normalize(vec3(toSun, frontSunHeight)) * reach;
    }
    l.frontReach = clamp(l.frontReach, 0.0, 1.0);
    l.frontDir = length(dir) > 1e-6 ? normalize(dir) : vec3(0.0, 0.0, 1.0);
    // Front-sun colour starts at colorTertiary and cycles at
    // frontSunPaletteSpeed.
    l.frontColor = paletteCycle(t * frontSunPaletteSpeed * 0.1 + 2.0);

    // Front-negative suns: anti-spots that darken scales in their reach.
    // The strongest wins (max, not sum) so overlaps can't pass the cap.
    float frontNegSigma = max(frontNegSunSize * canvasMax * 0.5, 1.0);
    float frontNegInvSig2 = 1.0 / (frontNegSigma * frontNegSigma);
    int nFrontNeg = sunSlots(frontNegSunCount);
    l.frontDark = 0.0;
    for (int s = 0; s < 10; s++) {
        if (s >= nFrontNeg) break;
        vec4 place = sunPlacement(float(s) + 307.0, frontNegSunLifetime, frontNegSunGap, frontNegSunSpeed, t);
        vec2 d = place.xy - px;
        l.frontDark = max(l.frontDark, exp(-dot(d, d) * frontNegInvSig2) * place.z
                                       * sunCountMask(frontNegSunCount, s) * frontNegSunStrength);
    }
    l.frontDark = clamp(l.frontDark, 0.0, 0.98);
    return l;
}

// ── Cells ────────────────────────────────────────────────────────────

// Centre of the cell at lattice index `cell` (odd rows shifted half a pitch).
vec2 latticeCenter(vec2 cell, float pitchX, float pitchY) {
    return vec2(cell.x * pitchX + mod(cell.y, 2.0) * pitchX * 0.5, cell.y * pitchY);
}

// Lattice index of neighbour k (angle k·60°). Odd rows sit half a pitch
// right, so the column step of the four diagonal neighbours depends on
// the row's parity.
vec2 neighbourIdx(vec2 cell, int k) {
    float odd = mod(cell.y, 2.0);
    if (k == 0) return cell + vec2(1.0, 0.0);
    if (k == 1) return cell + vec2(odd, 1.0);
    if (k == 2) return cell + vec2(odd - 1.0, 1.0);
    if (k == 3) return cell + vec2(-1.0, 0.0);
    if (k == 4) return cell + vec2(odd - 1.0, -1.0);
    return cell + vec2(odd, -1.0);
}

// Bar-zone elevation bump for a cell at the given canvas position: a band
// barZoneThickness px wide along one edge of this surface (anchor 0 =
// top, 1 = bottom, 2 = left, 3 = right). Cells outside the surface (the
// neighbours of its edge cells) get none.
float barElevationFor(vec2 worldPos) {
    if (barZoneEnabled < 0.5) return 0.0;
    vec2 local = worldPos - windowGeom.xy;
    int anchor = int(barZoneAnchor + 0.5);
    float distFromEdge;
    if      (anchor == 0) distFromEdge = local.y;
    else if (anchor == 1) distFromEdge = windowGeom.w - local.y;
    else if (anchor == 2) distFromEdge = local.x;
    else                  distFromEdge = windowGeom.z - local.x;
    return (distFromEdge >= 0.0 && distFromEdge < barZoneThickness) ? barZoneElevation : 0.0;
}

// Height (px above the canvas plane) of the scale centred at `center`: a
// broad spatial swell plus the scale's own slow bob, with its own phase
// and period (12-36 s at heightDriftSpeed 1) so neighbours drift above
// and below each other, plus the bar-zone bump.
float heightPx(vec2 center, float t) {
    float swell = noise(center * 0.005) * 2.0 - 1.0;
    float phase = hash(center * 0.07) * TWO_PI;
    float period = 12.0 + hash(center * 0.07 + vec2(13.7, 27.3)) * 24.0;
    float bob = sin(t * heightDriftSpeed * TWO_PI / period + phase);
    return (clamp(0.35 * swell + 0.65 * bob, -1.0, 1.0) + barElevationFor(center)) * heightRange;
}

// Orientation (unit quaternion, scale-local → world) of the scale centred
// at `center`: the direction and amount (≤ tiltMax rad) its normal leans,
// each component drifting on its own period (18-48 s at tiltDriftSpeed 1).
vec4 scaleOrientation(vec2 center, float t) {
    vec2 phase = vec2(hash(center * 0.11 + vec2(3.1, 7.7)),
                      hash(center * 0.13 + vec2(9.2, 1.4))) * TWO_PI;
    vec2 period = 18.0 + vec2(hash(center * 0.17 + vec2(5.5, 2.2)),
                              hash(center * 0.19 + vec2(8.8, 4.4))) * 30.0;
    vec2 tilt = sin(t * tiltDriftSpeed * TWO_PI / period + phase) * 0.70710678 * tiltMax;
    float lean = length(tilt);
    if (lean <= 1e-5) return vec4(0.0, 0.0, 0.0, 1.0);
    return vec4(vec3(-tilt.y, tilt.x, 0.0) / lean * sin(lean * 0.5), cos(lean * 0.5));
}

// Height differences (px) from the scale of `cell`, whose own height is
// `own`, to its neighbours: k = 0..3 in d03, 4, 5 in d45.
void neighbourDeltas(vec2 cell, float own, float t, float pitchX, float pitchY,
                     out vec4 d03, out vec2 d45) {
    d03 = vec4(heightPx(latticeCenter(neighbourIdx(cell, 0), pitchX, pitchY), t),
               heightPx(latticeCenter(neighbourIdx(cell, 1), pitchX, pitchY), t),
               heightPx(latticeCenter(neighbourIdx(cell, 2), pitchX, pitchY), t),
               heightPx(latticeCenter(neighbourIdx(cell, 3), pitchX, pitchY), t)) - own;
    d45 = vec2(heightPx(latticeCenter(neighbourIdx(cell, 4), pitchX, pitchY), t),
               heightPx(latticeCenter(neighbourIdx(cell, 5), pitchX, pitchY), t)) - own;
}

float deltaAt(vec4 d03, vec2 d45, int k) {
    if (k == 0) return d03.x;
    if (k == 1) return d03.y;
    if (k == 2) return d03.z;
    if (k == 3) return d03.w;
    if (k == 4) return d45.x;
    return d45.y;
}

// ── Scales ───────────────────────────────────────────────────────────

// Largest projection of p onto the three hex edge normals: p is inside a
// hex of inradius a when this is below a.
float hexExtent(vec2 p) {
    return max(abs(p.x), max(abs(dot(p, vec2(0.5, 0.8660254))),
                             abs(dot(p, vec2(-0.5, 0.8660254)))));
}

// Exact fraction of a unit pixel on the inner side of a straight edge
// whose unit normal is n, with the pixel centre `t` px inside it (box
// filter): linear across the middle, quadratic where the pixel's corners
// cross.
float edgeCoverage(float t, vec2 n) {
    float a = max(abs(n.x), abs(n.y));
    float b = min(abs(n.x), abs(n.y));
    float reach = 0.5 * (a + b);
    if (t >= reach) return 1.0;
    if (t <= -reach) return 0.0;
    if (abs(t) <= 0.5 * (a - b)) return 0.5 + t / a;
    float s = reach - abs(t);
    float corner = s * s / (2.0 * a * b);
    return t > 0.0 ? 1.0 - corner : corner;
}

// How much of the unit pixel centred at local point p a hex face of
// inradius a covers, judged against its nearest edge.
float hexCoverage(vec2 p, float a) {
    float e0 = abs(p.x);
    float e1 = abs(dot(p, vec2(0.5, 0.8660254)));
    float e2 = abs(dot(p, vec2(-0.5, 0.8660254)));
    vec2 normal = (e0 >= e1 && e0 >= e2) ? vec2(1.0, 0.0) : vec2(0.5, 0.8660254);
    return edgeCoverage(a - max(e0, max(e1, e2)), normal);
}

// How far (px) the scale of a neighbour centred at `nc`, `h` px high,
// can reach past the edge it shares with the cell centred at `c` (edge
// normal n, toward the neighbour), measured inward from that edge. Rays
// leave the camera at `eye`, so the neighbour shows only inside its
// silhouette projected onto the canvas plane from there: its corners lie
// within its inradius (grown by AA_PX, and a touch for tilt) of its
// centre along n, plus halfT·sin(tilt) from its thickness, at heights
// within h ± (halfT + corner·sin(tilt)). A bound on that projection,
// plus half a px for rounding.
float neighbourReach(vec2 c, vec2 nc, vec2 n, float h, vec3 eye, float i,
                     float apothem, float halfT) {
    float tiltSin = sin(tiltMax);
    float corner = (apothem + AA_PX) * 1.1547005;
    float zSpan = halfT + corner * tiltSin;
    float sLow = eye.z / max(eye.z - (h - zSpan), 1.0);
    float sHigh = eye.z / max(eye.z - (h + zSpan), 1.0);
    float extent = (apothem + AA_PX) * 1.02 + halfT * tiltSin;
    float toward = dot(nc - eye.xy, n);
    float nearest = dot(nc - c, n) - extent * max(sLow, sHigh)
                  + min(toward * (sLow - 1.0), toward * (sHigh - 1.0));
    return i - nearest + 0.5;
}

// Nearest scale hit along the current ray.
struct Hit {
    float t;        // ray distance (1e30 = none)
    vec2 cell;      // lattice index
    vec3 p;         // hit point, scale-local
    vec4 q;         // orientation (scale-local → world)
    float h;        // height (px)
};

// Ray (ro, rd) against the top face of the scale of `cell`: a hexagonal
// slab of inradius `apothem` and half-thickness `halfT` (edges facing the
// six neighbour directions), `h` px above its cell, tilted by its
// orientation. At rest a tilted rim would show only as sub-pixel slivers,
// so the face toward the camera stands for the scale. Keeps the two
// nearest hits in `best` and `next`.
void testScale(vec2 cell, float h, vec3 ro, vec3 rd, float pitchX, float pitchY,
               float apothem, float halfT, float t, inout Hit best, inout Hit next) {
    vec4 q = scaleOrientation(latticeCenter(cell, pitchX, pitchY), t);
    vec4 qInv = vec4(-q.xyz, q.w);
    vec3 o = rotate(qInv, ro - vec3(latticeCenter(cell, pitchX, pitchY), h));
    vec3 d = rotate(qInv, rd);
    float dz = abs(d.z) > 1e-6 ? d.z : -1e-6;
    float dist = (halfT - o.z) / dz;
    vec3 p = o + d * dist;
    if (!(dist > 0.0) || hexExtent(p.xy) > apothem)
        return;
    Hit hit = Hit(dist, cell, p, q, h);
    if (dist < best.t) {
        next = best;
        best = hit;
    } else if (dist < next.t) {
        next = hit;
    }
}

// Strength of the light streaming out through an opening of `opening` px
// between one scale's top and a neighbour's bottom (0 when closed).
float openingLight(float opening, float halfT) {
    return smoothstep(0.0, 2.0 * halfT + 2.0, opening);
}

// A light direction (unit, toward the light) raised to at least ~24° up:
// a lower light would throw shadows past the neighbour ring.
vec3 shadowLight(vec3 toLight) {
    return toLight.z < 0.4 ? normalize(vec3(toLight.xy, 0.0)) * 0.9165 + vec3(0.0, 0.0, 0.4) : toLight;
}

// How much the neighbours of the scale centred at `center` block the key
// light (x) and, when `withFront`, the front light along frontDir (y) at
// `point` on it (0..1 each). Only the neighbours lying toward a light can
// cast onto it. A neighbour that floats clear of this scale leaves an
// opening the underglow pours out of, brightening this scale along that
// edge, so its shadow gives way to that light as the opening widens: at
// any edge it's light from below or a shadow, never both.
// Each scale is treated as a flat hex at its top, so a neighbour's shadow
// is its hex shifted along the light by the height difference to the
// point (the neighbour deltas plus the point's own offset from this
// scale's top, `selfTop`); the test checks the point against it, with a
// penumbra that widens with the height difference.
vec2 heightShadows(vec3 point, vec3 frontDir, bool withFront, vec2 center,
                   vec4 d03, vec2 d45, float selfTop, float pitchX,
                   float apothem, float halfT) {
    vec3 key = shadowLight(KEY_DIR);
    vec3 front = shadowLight(frontDir);
    vec2 shadow = vec2(0.0);
    for (int k = 0; k < 6; k++) {
        float ang = float(k) * PI3;
        vec2 dir = vec2(cos(ang), sin(ang));
        bool keyFaces = dot(dir, key.xy) > 0.05;
        bool frontFaces = withFront && dot(dir, front.xy) > 0.05;
        if (!keyFaces && !frontFaces) continue;
        float delta = deltaAt(d03, d45, k);
        float open = openingLight(delta - 2.0 * halfT, halfT);
        if (open >= 1.0) continue;
        // Height difference only: the dome is shading curvature, and a
        // scale's rim (what shades its neighbour) sits at its flat top.
        float rise = delta + selfTop - point.z;
        if (rise <= 0.5) continue;
        vec2 rel = point.xy - center - dir * pitchX;
        float penumbra = 0.6 + rise * 0.12;
        if (keyFaces)
            shadow.x = max(shadow.x, smoothstep(-penumbra, penumbra,
                apothem - hexExtent(rel + key.xy * (rise / key.z))) * (1.0 - open));
        if (frontFaces)
            shadow.y = max(shadow.y, smoothstep(-penumbra, penumbra,
                apothem - hexExtent(rel + front.xy * (rise / front.z))) * (1.0 - open));
    }
    return shadow;
}

// How open the gap beside local point p of a scale is (0..1, see
// openingLight), from the two edges nearest p. Toward the corner between
// them the more open edge carries through, fading over 2 px: light from
// an open gap spills into the junction and a dim seam begins past it,
// rather than the dim seam eating into the end of the lit one.
float edgeOpening(vec4 d03, vec2 d45, vec2 p, float halfT) {
    float d0 = -1e9, d1 = -1e9;
    int k0 = 0, k1 = 0;
    for (int k = 0; k < 6; k++) {
        float ang = float(k) * PI3;
        float d = dot(p, vec2(cos(ang), sin(ang)));
        if (d > d0) {
            d1 = d0; k1 = k0;
            d0 = d; k0 = k;
        } else if (d > d1) {
            d1 = d; k1 = k;
        }
    }
    float open0 = openingLight(abs(deltaAt(d03, d45, k0)) - 2.0 * halfT, halfT);
    float open1 = openingLight(abs(deltaAt(d03, d45, k1)) - 2.0 * halfT, halfT);
    return max(open0, open1 * (1.0 - smoothstep(0.0, 2.0, d0 - d1)));
}

// The glowing underlayer seen through a gap `opening` open (edgeOpening).
// How much of it escapes follows the gap: a little always (seamBase), and
// fully where one scale floats clear of the other and the light streams
// out — the same opening that lights the lower scale's face, so a bright
// seam always comes with light on the scale beside it (and no shadow from
// that neighbour there; see heightShadows).
vec3 underlayer(Light l, float opening) {
    return l.underglow * seamGlow * mix(seamBase, 1.0, opening);
}

// Shade a scale hit; d03/d45 are its neighbour deltas.
vec3 shadeScale(Hit hit, vec3 ro, vec3 rd, vec4 d03, vec2 d45, Light l,
                float pitchX, float pitchY, float apothem, float halfT) {
    vec3 world = ro + rd * hit.t;

    // Domed face: z = halfT + domeHeight·(1 − r²/apothem²).
    vec3 nl = vec3(2.0 * domeHeight * hit.p.xy / (apothem * apothem), 1.0);
    float albedo = 1.0;
    // Matte grain in face coordinates, seeded per scale: a fine, soft
    // relief that tilts the normal so grazing light picks out the finish,
    // with only a faint albedo variation following it. One octave, its
    // frequency capped below Nyquist, so it doesn't shimmer.
    if (grainStrength > 0.0) {
        float scale = min(grainScale, 0.4);
        vec2 u = hit.p.xy * scale + hit.cell * 17.31;
        float e = 0.35;
        float g0 = noise(u);
        vec2 grad = vec2(noise(u + vec2(e, 0.0)) - g0, noise(u + vec2(0.0, e)) - g0) / e;
        nl.xy -= grad * grainStrength * scale * 0.8;
        albedo = 1.0 + (g0 - 0.5) * 0.25 * min(grainStrength, 2.0);
    }
    vec3 normal = rotate(hit.q, normalize(nl));

    // Underglow at each edge, by the opening to that neighbour: the gap
    // between its bottom and this face's top (both slabs are 2·halfT
    // thick). An open window lets light rising through the gap stream out
    // over this face — brighter and further the wider it is, fading over
    // the matte. A neighbour that doesn't clear this face lets none
    // through. Where this scale is the one floating clear, the same light
    // catches its overhanging lip instead, fading within a few px, so
    // light shows on both sides of an opening.
    float reachScale = mix(1.6, 0.35, matteness);
    float stream = 0.0;
    float lip = 0.0;
    for (int k = 0; k < 6; k++) {
        float delta = deltaAt(d03, d45, k);
        float ang = float(k) * PI3;
        float distIn = max(0.0, apothem - dot(hit.p.xy, vec2(cos(ang), sin(ang))));
        if (delta - 2.0 * halfT > 0.0)
            stream += openingLight(delta - 2.0 * halfT, halfT)
                    * exp(-distIn / ((2.0 + (delta - 2.0 * halfT) * 1.5) * reachScale));
        else if (-delta - 2.0 * halfT > 0.0)
            lip += openingLight(-delta - 2.0 * halfT, halfT) * exp(-distIn / 2.5);
    }
    float leak = clamp((stream + lip * 0.6) * heightAmount, 0.0, 1.0) * domeStrength;
    float lit = clamp((stream + lip) * 2.0, 0.0, 1.0);   // how much light streams in here
    // Depth: less light overall the lower the scale sits in its range.
    float lowness = clamp(0.5 - hit.h / max(heightRange, 0.001) * 0.5, 0.0, 1.0);
    float depthShade = 1.0 - occlusion * 0.45 * lowness;

    // Front suns: matte (wrapped Lambert) light from the dominant front
    // direction, gated by reach and shadowed by the scales standing toward
    // the suns, so the shadows swing round beneath each sun as it drifts.
    // The light itself stays modest (0.5×) so it never drowns the
    // underglow; the shadows are what show where a sun is. Taller
    // neighbours shadow the key light too, except where light from below
    // streams in and fills the shadow back in.
    float lambert = max(0.0, (dot(normal, l.frontDir) + 0.1) / 1.1);
    float frontLight = frontSunStrength * 0.5 * l.frontReach * lambert;
    vec2 shadows = scaleShadow * (1.0 - lit)
                 * heightShadows(world, l.frontDir,
                                 frontLight * max(l.frontColor.r, max(l.frontColor.g, l.frontColor.b)) > 0.01,
                                 latticeCenter(hit.cell, pitchX, pitchY), d03, d45,
                                 hit.h + halfT, pitchX, apothem, halfT);
    vec3 front = l.frontColor * frontLight * (1.0 - shadows.y);
    float keyLambert = max(0.0, (dot(normal, KEY_DIR) + 0.1) / 1.1);

    // Body: the matte tint under ambient + key light, plus front light,
    // all modulated by grain, depth and shadow, then eaten by front-
    // negative suns. Underglow arrives as the lip leak.
    vec3 tint = colorPrimaryContainer.rgb;
    vec3 body = (tint * (0.55 * (1.0 - 0.35 * shadows.x) + keyLight * 1.6 * keyLambert * (1.0 - shadows.x))
                 + front * (1.0 - 0.6 * shadows.x))
              * albedo * depthShade * (1.0 - l.frontDark);
    vec3 color = body + l.underglow * seamGlow * leak;
    float halo = 1.0 - smoothstep(0.0, HALO_PX, apothem - hexExtent(hit.p.xy));
    float pour = halo > 0.0 ? edgeOpening(d03, d45, hit.p.xy, halfT) : 0.0;
    if (pour > 0.0)
        color = mix(color, underlayer(l, pour), pour * halo);
    return color;
}

// A cheap stand-in for a scale covering the lesser part of an edge pixel
// shared with another scale: its matte tint under ambient and key light,
// sunk by its depth and taken as partly shadowed, lit near an opening
// like the full shading would light it.
vec3 standInScale(Hit hit, vec4 d03, vec2 d45, Light l, float apothem, float halfT) {
    float lowness = clamp(0.5 - hit.h / max(heightRange, 0.001) * 0.5, 0.0, 1.0);
    vec3 body = colorPrimaryContainer.rgb * (0.55 + keyLight * 0.8)
              * (1.0 - occlusion * 0.45 * lowness) * (1.0 - 0.35 * scaleShadow);
    float pour = edgeOpening(d03, d45, hit.p.xy, halfT);
    if (pour <= 0.0)
        return body;
    float distIn = max(apothem - hexExtent(hit.p.xy), 0.0);
    float reach = (2.0 + 3.0 * halfT) * mix(1.6, 0.35, matteness);
    body += underlayer(l, 1.0) * pour * exp(-distIn / reach) * heightAmount * domeStrength;
    return mix(body, underlayer(l, pour), pour * (1.0 - smoothstep(0.0, HALO_PX, distIn)));
}

// Neighbour deltas of the hit scale: the fragment's own cell's when it is
// that scale, otherwise worked out for it.
void hitDeltas(Hit hit, vec2 cell, vec4 cellD03, vec2 cellD45, float t,
               float pitchX, float pitchY, out vec4 d03, out vec2 d45) {
    if (all(equal(hit.cell, cell))) {
        d03 = cellD03;
        d45 = cellD45;
    } else {
        neighbourDeltas(hit.cell, hit.h, t, pitchX, pitchY, d03, d45);
    }
}

// Colour of the 3D scale field at canvas pixel px. One ray, tested
// against scales grown by AA_PX; its coverage of the pixel (from the
// distance to the true outline) blends it over what the ray meets next —
// the scale behind, or the underglow through the gap. That antialiases
// both sides of every outline, gaps and overlaps alike.
vec3 scaleField(vec2 px, float i, float pitchX, float pitchY, float t, Light l) {
    float seamWidth = max(0.1, hexBevel * i * 0.04);
    float apothem = i - seamWidth;
    float halfT = max(slabThickness, 0.1) * 0.5;

    // The flat-tiling cell under px: the scale under it before parallax.
    float row0 = floor(px.y / pitchY);
    vec2 c0 = vec2(floor((px.x - mod(row0, 2.0) * pitchX * 0.5) / pitchX + 0.5), row0);
    vec2 c1 = vec2(floor((px.x - mod(row0 + 1.0, 2.0) * pitchX * 0.5) / pitchX + 0.5), row0 + 1.0);
    vec2 v0 = px - latticeCenter(c0, pitchX, pitchY);
    vec2 v1 = px - latticeCenter(c1, pitchX, pitchY);
    bool nearRow0 = dot(v0, v0) < dot(v1, v1);
    vec2 cellIdx = nearRow0 ? c0 : c1;
    vec2 local = nearRow0 ? v0 : v1;
    vec2 center = px - local;

    vec3 ro = vec3(iResolution.xy * 0.5, max(cameraDistance, 100.0));
    vec3 rd = normalize(vec3(px, 0.0) - ro);

    // This scale and its neighbours' heights; a neighbour is tested only
    // where its silhouette can reach px.
    float own = heightPx(center, t);
    vec4 d03;
    vec2 d45;
    neighbourDeltas(cellIdx, own, t, pitchX, pitchY, d03, d45);
    Hit hit = Hit(1e30, vec2(0.0), vec3(0.0), vec4(0.0, 0.0, 0.0, 1.0), 0.0);
    Hit behind = hit;
    testScale(cellIdx, own, ro, rd, pitchX, pitchY, apothem + AA_PX, halfT, t, hit, behind);
    for (int k = 0; k < 6; k++) {
        float ang = float(k) * PI3;
        vec2 n = vec2(cos(ang), sin(ang));
        vec2 nb = neighbourIdx(cellIdx, k);
        float h = own + deltaAt(d03, d45, k);
        if (i - dot(local, n) < neighbourReach(center, latticeCenter(nb, pitchX, pitchY), n, h,
                                               ro, i, apothem, halfT))
            testScale(nb, h, ro, rd, pitchX, pitchY, apothem + AA_PX, halfT, t, hit, behind);
    }

    // Through the gaps: the underglow, as much as the gap beside the
    // nearest edge lets out.
    if (hit.t > 1e29)
        return underlayer(l, edgeOpening(d03, d45, local, halfT));

    // How much of the pixel each surface covers: the front scale its own
    // share, the next scale up to what the front leaves, and the gap
    // whatever remains.
    float coverage = hexCoverage(hit.p.xy, apothem);
    float behindCoverage = coverage < 1.0 && behind.t < 1e29
        ? min(hexCoverage(behind.p.xy, apothem), 1.0 - coverage) : 0.0;

    // The surface covering more of the pixel gets the full shading, the
    // other the cheap stand-in: a front scale found only through the
    // antialiasing margin mustn't push the scale actually filling the
    // pixel down to the stand-in.
    Hit major = hit;
    Hit minor = behind;
    float majorCoverage = coverage;
    float minorCoverage = behindCoverage;
    if (behindCoverage > coverage) {
        major = behind;
        minor = hit;
        majorCoverage = behindCoverage;
        minorCoverage = coverage;
    }
    vec4 h03;
    vec2 h45;
    hitDeltas(major, cellIdx, d03, d45, t, pitchX, pitchY, h03, h45);
    vec3 color = shadeScale(major, ro, rd, h03, h45, l, pitchX, pitchY, apothem, halfT) * majorCoverage;
    if (majorCoverage >= 1.0)
        return color;
    if (minorCoverage > 0.0) {
        hitDeltas(minor, cellIdx, d03, d45, t, pitchX, pitchY, h03, h45);
        color += standInScale(minor, h03, h45, l, apothem, halfT) * minorCoverage;
    }
    float gap = 1.0 - coverage - behindCoverage;
    if (gap > 0.0)
        color += underlayer(l, edgeOpening(d03, d45, local, halfT)) * gap;
    return color;
}

// ── 2D layer ─────────────────────────────────────────────────────────

// Stream activations (rgb = streams A, B, C) on edge `bucket` of the
// cell centred at `cellCenter`: three noise fields drifting at their own
// velocities behind the hexes, lighting an edge where any is over its
// threshold, boosted where the edge faces a pendulum "wind" so light
// progresses across each cell.
vec3 edgeStreams(vec2 cellCenter, float bucket, float i, float t) {
    float edgeAngle = bucket * PI3;
    vec2 edgeFaceDir = vec2(cos(edgeAngle), sin(edgeAngle));
    vec2 edgeWorld = cellCenter + edgeFaceDir * i;

    vec2 shuffleA = vec2(sin(t * 0.07), cos(t * 0.07)) * 0.30;
    float litA = smoothstep(0.50, 0.66, fbm(edgeWorld * 0.02 + shuffleA - vec2(t * 0.03, t * 0.022)));
    vec2 shuffleB = vec2(sin(t * 0.09 + 2.1), cos(t * 0.09 + 2.1)) * 0.25;
    float litB = smoothstep(0.52, 0.66, fbm(edgeWorld * 0.04 + shuffleB + vec2(t * 0.025, -t * 0.035)));
    vec2 shuffleC = vec2(sin(t * 0.06 + 4.3), cos(t * 0.06 + 4.3)) * 0.30;
    float litC = smoothstep(0.56, 0.72, fbm(edgeWorld * 0.04 + shuffleC + vec2(t * 0.04, t * 0.04)));

    float windAngle = 1.5707963 + sin(t * 0.25) * 1.2566371;   // π/2 ± 0.4π
    float windBoost = 0.30 + 0.70 * max(0.0, dot(edgeFaceDir, vec2(cos(windAngle), sin(windAngle))));
    return vec3(litA, litB, litC) * windBoost;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Map this surface's pixels into the canvas. For a single surface
    // windowGeom = (0, 0, iResolution.xy), so px = fragCoord.
    vec2 px = fragCoord / iResolution.xy * windowGeom.zw + windowGeom.xy;
    float i = max(1.0, cellSize);
    float pitchX = 2.0 * i;
    float pitchY = 1.7320508 * i;
    float t = iTime * timeScale;

    // ── Hex tiling ─────────────────────────────────────────────────
    float row0 = floor(px.y / pitchY);
    float row1 = row0 + 1.0;
    float xOff0 = mod(row0, 2.0) < 0.5 ? 0.0 : pitchX * 0.5;
    float xOff1 = mod(row1, 2.0) < 0.5 ? 0.0 : pitchX * 0.5;
    vec2 c0 = vec2(floor((px.x - xOff0) / pitchX + 0.5) * pitchX + xOff0, row0 * pitchY);
    vec2 c1 = vec2(floor((px.x - xOff1) / pitchX + 0.5) * pitchX + xOff1, row1 * pitchY);
    vec2 d0 = px - c0;
    vec2 d1 = px - c1;
    vec2 local = dot(d0, d0) < dot(d1, d1) ? d0 : d1;
    vec2 cellCenter = px - local;

    // ── 2D layer: light streaming along the hex edges ──────────────
    // The facing edge (one of six buckets every 60°) carries the stream
    // activations; hotCol pre-weights each colour by its own activation
    // so overlapping streams blend.
    float angle = atan(local.y, local.x);
    if (angle < 0.0) angle += TWO_PI;
    vec3 streams = edgeStreams(cellCenter, mod(floor(angle / PI3 + 0.5), 6.0), i, t);
    vec3 hotCol = colorPrimary.rgb * streams.r + colorSecondary.rgb * streams.g
                + colorTertiary.rgb * streams.b;
    float lit = clamp(streams.r + streams.g + streams.b, 0.0, 1.0);
    float distToEdge = sdHexagon(local.yx, i);
    float litGlowRaw = exp(-abs(distToEdge) * 0.6);
    // Faint always-on outline, sharper so the base network reads as thin
    // lines; interior, outline and lit layers sum (premultiplied).
    float outlineAlpha = exp(-abs(distToEdge) * 0.9) * 0.18;
    vec3 finalColor2D = colorPrimaryContainer.rgb * 0.55 + colorPrimary.rgb * outlineAlpha
                      + hotCol * litGlowRaw;
    float alpha2D = clamp(0.55 + outlineAlpha + lit * litGlowRaw, 0.0, 1.0);

    // ── 3D scale field ────────────────────────────────────────────
    vec3 color3D = modeAmount > 0.0 ? scaleField(px, i, pitchX, pitchY, t, sunLight(px, t)) : vec3(0.0);

    fragColor = vec4(mix(finalColor2D, color3D, modeAmount) * intensity,
                     mix(alpha2D, 1.0, modeAmount) * intensity);
}


void main() {
    vec4 c;
    mainImage(c, vec2(gl_FragCoord.x, resolution.y - gl_FragCoord.y));
    outColor = vec4(c.rgb, 1.0);
}
