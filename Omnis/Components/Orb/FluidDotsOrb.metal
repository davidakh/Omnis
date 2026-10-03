#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

namespace omnis_orb {

constant float TAU = 6.28318530718;
constant int   N = 6;
constant float SMOOTH_K = 0.05;
constant float INTENSITY = 0.005;
constant float FALLOFF_P = 1.35;
constant float FADE_START = 0.02;
constant float FADE_END = 0.56;
constant float3 SPECTRAL = float3(0.0, 0.0065, 0.013);
constant float HUE_SPEED = 0.06;
constant float COLOR_K = 0.5;
constant float SAT = 0.25;
constant float HUE_SPAN = 0.667;
constant float MERGE_PERIOD = 6.0;
constant float STAGGER = 0.33;
constant float HOLD = 0.0;
constant float W = 4.6;
constant float L = 3.2;
constant float PIERCE = 0.005;
constant float RECOIL = 0.005;
constant float REC_LAG = 0.11;
constant float GATHER_HOLD = 0.8;
constant float GATHER_R = 0.008;
constant float GATHER_DIM = 0.85;
constant float GATHER_IN = 1.8;
constant float GATHER_IN_L = 7.5;
constant float BURST_W = 6.5;
constant float BURST_L = 4.0;
constant float CHARGE_T = 0.30;
constant float CHARGE_SHRK = 0.18;
constant float CHARGE_GLOW = 0.35;
constant float FLASH_GAIN = 1.2;
constant float FLASH_DECAY = 7.0;
constant float LENS = 0.62;
constant float DEPTH_DIM = 0.18;
constant float GAUGE_R = 0.195;
constant float GAUGE_W = 0.027;
// Square (recording) and circle (paused): the Figma "Glow" layer stack, bottom to top:
//   1. square, really strong blur      2. square, stronger blur, 76%     3. square, slight blur
//   4. white circle, blurred, Plus Lighter
//   5. Chromatic Aberration: blurred drop shadows, orange to the left and blue to the right
// Values fitted to Glow.png (a 52 pt orb; RMS error ≈ 2.9 / 255, colour included). They are in
// points at that size; GLOW_UNIT converts to orb space (the orb's radius, 0.4, spans 26 pt),
// and LIT_SCALE enlarges the whole stack.
constant float GLOW_UNIT = 0.4 / 26.0;
constant float LIT_SCALE = 1.2;
constant float LIT_HALF = 8.56;              // rounded square half-side …
constant float LIT_ROUND = 5.11;             // … and corner radius
constant float BLUR_STRONG = 9.97;           // 1. σ …
constant float BLUR_STRONG_ALPHA = 0.152;    //    … and opacity
constant float BLUR_STRONGER = 6.09;         // 2. σ (opacity 76%)
constant float BLUR_STRONGER_ALPHA = 0.76;
constant float BLUR_SLIGHT = 2.17;           // 3. σ (opaque)
constant float GLOW_RADIUS = 8.41;           // 4. circle radius …
constant float GLOW_BLUR = 7.44;             //    … blur σ …
constant float GLOW_ALPHA = 0.395;           //    … and opacity
constant float SHADOW_OFFSET = 2.09;         // 5. shadow offset (left / right) …
constant float SHADOW_BLUR = 4.59;           //    … blur σ …
constant float SHADOW_ALPHA = 0.205;         //    … and opacity
constant float3 SHADOW_ORANGE = float3(1.0, 0.658, 0.0);
constant float3 SHADOW_BLUE = float3(0.227, 0.534, 1.0);
constant float CIRCLE_R = 3.6;               // the small paused circle's radius
constant float SQUARE_PULSE_SPEED = 2.2;
constant float GLOW_BREATHE = 0.12;          // gentle pulse of the glow while recording
constant float HALO_GAIN = 0.25;
constant float HALO_R = 0.055;
constant float TRACK_GAIN = 0.16;
constant float TRACK_SOFT = 0.010;
constant float EXPOSURE = 2.0;
constant float GAIN = 1.13;
constant float SPREAD = 0.96;

float hash11(float n) {
    return fract(sin(n * 127.1 + 311.7) * 43758.5453);
}

float settleWL(float tau, float w, float l) {
    if (tau <= 0.0) {
        return 0.0;
    }
    return 1.0 - exp(-l * tau) * cos(w * tau);
}

float settle(float tau) {
    return settleWL(tau, W, L);
}

float settleCrit(float tau, float l) {
    if (tau <= 0.0) {
        return 0.0;
    }
    return 1.0 - exp(-l * tau) * (1.0 + l * tau);
}

float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float3 hue2rgb(float h) {
    h = fract(h);
    float r = clamp(abs(h * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    float g = clamp(2.0 - abs(h * 6.0 - 2.0), 0.0, 1.0);
    float b = clamp(2.0 - abs(h * 6.0 - 4.0), 0.0, 1.0);
    return float3(r, g, b);
}

float dotR(float fi, float seed, float t) {
    return 0.037 + 0.008 * sin(t * 1.3 + seed * TAU) + 0.004 * sin(t * 2.4 + fi * 1.3);
}

float dotSD(float2 p, float2 pos, float r, float t, float fi, float shapeDamp) {
    float2 d = p - pos;
    float sq = 0.075 * (0.5 + 0.5 * sin(t * 0.9 + fi * 2.0)) * shapeDamp;
    float ca = cos(t * 0.35 + fi);
    float sa = sin(t * 0.35 + fi);
    d = float2x2(ca, -sa, sa, ca) * d;
    d *= float2(1.0 + sq, 1.0 - sq);
    return length(d) - r;
}

float arcSD(float2 p, float radius, float halfWidth, float sweep) {
    float a = atan2(p.x, p.y);
    if (a < 0.0) {
        a += TAU;
    }
    float2 capA = float2(0.0, radius);
    float2 capB = float2(sin(sweep), cos(sweep)) * radius;
    float caps = min(length(p - capA), length(p - capB)) - halfWidth;
    if (sweep <= 0.0) {
        return length(p - capA) - halfWidth;
    }
    if (a <= sweep) {
        return min(abs(length(p) - radius) - halfWidth, caps);
    }
    return caps;
}

float roundBoxSD(float2 p, float halfSide, float radius) {
    float2 d = abs(p) - float2(halfSide) + float2(radius);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

/// A layer blurred by a gaussian of `sigma`, at signed distance `sd` from its edge
/// (Figma layer blur). Uses tanh as a close approximation of erf.
float blurredLayer(float sd, float sigma) {
    return 0.5 * (1.0 - tanh(1.2025 * sd / (1.41421356 * sigma)));
}

// Premultiplied compositing.
float4 over(float4 source, float4 destination) {
    return source + destination * (1.0 - source.a);
}
float4 plusLighter(float4 source, float4 destination) {
    return min(source + destination, float4(1.0));
}
float4 whiteLayer(float alpha) {
    return float4(alpha);
}
float4 tintedLayer(float3 color, float alpha) {
    return float4(color * alpha, alpha);
}

/// A gaussian-blurred square of `halfSide` (Figma layer blur), as the product of two
/// separable 1D blurs. Unlike an outline-distance blur, corners fade and round off
/// the way a real blur does.
float blurredSquare(float2 q, float halfSide, float sigma) {
    float k = 1.2025 / (1.41421356 * sigma);
    float bx = 0.5 * (tanh((halfSide - q.x) * k) + tanh((halfSide + q.x) * k));
    float by = 0.5 * (tanh((halfSide - q.y) * k) + tanh((halfSide + q.y) * k));
    return bx * by;
}

/// One blurred layer of the lit shape at design-space point `q` with outline distance `d`.
/// A true box blur for the square (blended in as the blur grows past the corner radius,
/// where the rounding stops mattering), and the outline blur for the circle and mid-morph,
/// so morphs stay fluid.
float litBlur(float2 q, float d, float sigma, float squareness) {
    float outline = blurredLayer(d, sigma);
    float box = blurredSquare(q, LIT_HALF, sigma);
    float w = squareness * smoothstep(0.5, 1.5, sigma / LIT_ROUND);
    return mix(outline, box, w);
}

/// The Figma "Glow" stack for a lit shape. `sd` holds its outline distance (orb units) at
/// `p`, and shifted right / left by the shadow offset (for the orange / blue drop shadows).
/// `squareness` is how fully the shape has become the square. Returns premultiplied colour
/// and alpha.
float4 litLayers(float3 sd, float2 p, float breathe, float squareness) {
    float unit = GLOW_UNIT * LIT_SCALE;
    float3 d = sd / unit;
    float2 q = p / unit;
    float2 shift = float2(SHADOW_OFFSET, 0.0);

    float4 c = whiteLayer(BLUR_STRONG_ALPHA * breathe * litBlur(q, d.x, BLUR_STRONG, squareness));
    c = over(whiteLayer(BLUR_STRONGER_ALPHA * litBlur(q, d.x, BLUR_STRONGER, squareness)), c);
    float4 slight = whiteLayer(litBlur(q, d.x, BLUR_SLIGHT, squareness));
    c = over(slight, c);

    float circle = length(q) - GLOW_RADIUS;
    c = plusLighter(whiteLayer(GLOW_ALPHA * breathe * blurredLayer(circle, GLOW_BLUR)), c);

    // Chromatic Aberration: its drop shadows sit beneath its own square.
    float orange = SHADOW_ALPHA * litBlur(q + shift, d.y, SHADOW_BLUR, squareness);
    float blue = SHADOW_ALPHA * litBlur(q - shift, d.z, SHADOW_BLUR, squareness);
    c = over(tintedLayer(SHADOW_ORANGE, orange), c);
    c = over(tintedLayer(SHADOW_BLUE, blue), c);
    return over(slight, c);
}

/// The dots / gauge look (pre tone-map rgb). `litSD` receives the outline distance of the
/// shape being morphed toward (at the point, then shifted for the orange and blue shadows),
/// which the lit square / circle are drawn from.
float3 scene(
    float2 p,
    float2 flatP,   // un-lensed position: the lit shapes are drawn flat, like the Figma design
    thread float3 &litSD,
    float t,
    float gather,
    float gaugeMix,
    float squareMix,
    float circleMix,
    float progress
) {
    float k = floor(t / MERGE_PERIOD);
    float te = fract(t / MERGE_PERIOD) * MERGE_PERIOD;

    float g = settleCrit(gather * GATHER_IN, GATHER_IN_L)
            - settleWL(gather - GATHER_HOLD, BURST_W, BURST_L);
    float gC = clamp(g, 0.0, 1.0);

    float tb = gather - GATHER_HOLD;
    float charge = smoothstep(-CHARGE_T, 0.0, min(tb, 0.0)) * gC;
    float flash = tb > 0.0 ? exp(-tb * FLASH_DECAY) : 0.0;
    float gBright = mix(1.0, GATHER_DIM, gC) * (1.0 + CHARGE_GLOW * charge + FLASH_GAIN * flash);


    float3 total3 = float3(1e5);
    float3 cAcc = float3(0.0);
    float wAcc = 1e-6;

    for (int i = 0; i < N; i++) {
        float fi = float(i);
        float seed = hash11(fi);
        float ang = fi / float(N) * TAU + t * 0.35;
        float2 dir = float2(cos(ang), sin(ang));
        float R = (GAUGE_R + 0.010 * sin(t * 1.0) + 0.007 * sin(t * 1.3 + seed * TAU)) * SPREAD;
        float pairId = fmod(fi, 3.0);
        float moverLow = fmod(k + pairId, 2.0);
        float isMover = (fi < 2.5) ? step(moverLow, 0.5) : step(0.5, moverLow);
        float goStart = pairId * STAGGER;
        float retStart = 3.0 * STAGGER + HOLD + pairId * STAGGER;
        float m = (settle(te - goStart) - settle(te - retStart)) * isMover;
        float rec = (settle(te - goStart - REC_LAG) - settle(te - retStart - REC_LAG)) * (1.0 - isMover);
        float rSelf = dotR(fi, seed, t);
        rSelf = mix(rSelf, 0.037, gC);
        rSelf *= 1.0 - CHARGE_SHRK * charge;
        float deep = -(R + RECOIL + PIERCE);
        float radial = mix(R, deep, m) + RECOIL * rec;
        radial = mix(radial, GATHER_R, g);
        float2 pos = radial * dir;
        float sdR = dotSD(p - SPECTRAL.r * dir, pos, rSelf, t, fi, 1.0 - gC);
        float sdG = dotSD(p - SPECTRAL.g * dir, pos, rSelf, t, fi, 1.0 - gC);
        float sdB = dotSD(p - SPECTRAL.b * dir, pos, rSelf, t, fi, 1.0 - gC);
        total3 = float3(smin(total3.r, sdR, SMOOTH_K),
                        smin(total3.g, sdG, SMOOTH_K),
                        smin(total3.b, sdB, SMOOTH_K));
        float hue = fract(fi / float(N) + t * HUE_SPEED) * HUE_SPAN;
        float3 dotCol = mix(float3(1.0), hue2rgb(hue), SAT);
        float w = exp(-sdG * COLOR_K);
        cAcc += w * dotCol;
        wAcc += w;
    }

    float gw = clamp(gaugeMix, 0.0, 1.0);
    float qw = clamp(squareMix, 0.0, 1.0);

    if (gw > 0.0) {
        float sweep = clamp(progress, 0.0, 1.0) * TAU;
        float3 gauge3 = float3(
            arcSD(p - SPECTRAL.r, GAUGE_R, GAUGE_W, sweep),
            arcSD(p - SPECTRAL.g, GAUGE_R, GAUGE_W, sweep),
            arcSD(p - SPECTRAL.b, GAUGE_R, GAUGE_W, sweep)
        );
        total3 = mix(total3, gauge3, gw);
    }

    float cw = clamp(circleMix, 0.0, 1.0);

    // The dots' outline morphs into the lit shape's, so the transition stays fluid.
    float unit = GLOW_UNIT * LIT_SCALE;
    float2 shift = float2(SHADOW_OFFSET * unit, 0.0);
    litSD = float3(total3.g);
    if (qw > 0.0) {
        float halfSide = LIT_HALF * unit, corner = LIT_ROUND * unit;
        float3 square = float3(
            roundBoxSD(flatP, halfSide, corner),
            roundBoxSD(flatP + shift, halfSide, corner),   // shape moved left: orange shadow
            roundBoxSD(flatP - shift, halfSide, corner)    // shape moved right: blue shadow
        );
        total3 = mix(total3, float3(square.x), qw);
        litSD = mix(litSD, square, qw);
    }
    if (cw > 0.0) {
        float r = CIRCLE_R * unit;
        float3 circle = float3(length(flatP) - r, length(flatP + shift) - r, length(flatP - shift) - r);
        total3 = mix(total3, float3(circle.x), cw);
        litSD = mix(litSD, circle, cw);
    }

    float3 sd3 = max(total3, float3(0.0)) + 1e-4;
    float3 core3 = clamp(INTENSITY / pow(sd3, float3(FALLOFF_P)), float3(0.0), float3(1.0));
    float3 edge3 = float3(1.0) - smoothstep(float3(FADE_START), float3(FADE_END), sd3);
    float3 bright = core3 * edge3 * gBright * GAIN;
    float halo = HALO_GAIN * exp(-sd3.g / HALO_R) * gBright;
    float trackSD = abs(length(p) - GAUGE_R) - GAUGE_W;
    float track = TRACK_GAIN * gw * (1.0 - smoothstep(0.0, TRACK_SOFT, trackSD));
    return max(bright + halo, float3(track)) * (cAcc / wAcc);
}

}

[[ stitchable ]] half4 fluidDotsOrb(
    float2 position,
    float2 size,
    float time,
    float gather,
    float opacity,
    float sphereRadius,
    float gaugeMix,
    float squareMix,
    float circleMix,
    float progress
) {
    using namespace omnis_orb;

    float minSide = max(min(size.x, size.y), 1.0);
    float2 centered = 2.0 * position - size;
    float2 p = float2(centered.x, -centered.y) / minSide;

    float t = max(time, 0.0);
    p /= 1.0 + 0.03 * sin(t * 1.0);

    float sphereR = max(sphereRadius, 1e-3);
    float rr = length(p) / sphereR;
    float z = sqrt(max(1.0 - rr * rr, 0.0));

    float2 pl = p * (1.0 + LENS * (1.0 - z));

    float3 litSD = float3(0.0);
    float3 col = scene(
        pl,
        p,
        litSD,
        t,
        gather,
        gaugeMix,
        squareMix,
        circleMix,
        progress
    );
    col *= 1.0 + 0.05 * sin(t * 1.0 + 1.0);
    col *= mix(1.0 - DEPTH_DIM, 1.0, z);

    col = float3(1.0) - exp(-max(col, float3(0.0)) * EXPOSURE);
    float alpha = max(max(col.r, col.g), col.b);

    // Square / circle: the Figma layer stack, drawn flat (no lens, depth dimming or tone map).
    float lit = clamp(max(squareMix, circleMix), 0.0, 1.0);
    if (lit > 0.0) {
        float breathe = 1.0 + GLOW_BREATHE * clamp(squareMix, 0.0, 1.0) * sin(t * SQUARE_PULSE_SPEED);
        // Fully square only once the morph has settled; the dots / circle use outline blurs.
        float squareness = clamp(squareMix, 0.0, 1.0);
        float4 layers = litLayers(litSD, p, breathe, squareness * squareness);
        col = mix(col, layers.rgb, lit);
        alpha = mix(alpha, layers.a, lit);
    }

    float n = fract(sin(dot(position, float2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) / 255.0;
    col = clamp(col, float3(0.0), float3(1.0));

    alpha = clamp(max(alpha, max(max(col.r, col.g), col.b)), 0.0, 1.0);
    float o = clamp(opacity, 0.0, 1.0);

    return half4(half3(col * o), half(alpha * o));
}
