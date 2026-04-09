#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// ── Cursor ────────────────────────────────────────────────────────────────────

struct CursorUniforms {
    float2 normPos;    // quad top-left, normalized screen coords
    float2 normSize;   // quad size, normalized
    float  fadeAlpha;  // 1.0 = fully visible, 0.0 = invisible
};

vertex VertexOut cursor_vertex(uint vid [[vertex_id]],
                                constant CursorUniforms& u [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(0.0, 0.0), float2(1.0, 0.0),
        float2(0.0, 1.0), float2(1.0, 1.0),
    };
    const float2 uvs[4] = {
        float2(0.0, 0.0), float2(1.0, 0.0),
        float2(0.0, 1.0), float2(1.0, 1.0),
    };
    float2 norm = u.normPos + corners[vid] * u.normSize;
    float2 ndc  = float2(norm.x * 2.0 - 1.0, 1.0 - norm.y * 2.0);
    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 cursor_fragment(VertexOut in [[stage_in]],
                                 constant CursorUniforms& u [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    float4 color = tex.sample(s, in.uv);
    color.a *= u.fadeAlpha;
    return color;
}

// ── Ring ripple ───────────────────────────────────────────────────────────────

struct RingUniforms {
    float2 normCenter;    // hotspot in [0,1]x[0,1] screen coords (origin top-left)
    float  normRadius;    // ring radius in screen-HEIGHT-normalized units
    float  normThickness; // ring thickness in same units
    float  alpha;         // overall ring opacity
    float  aspectRatio;   // screenWidth / screenHeight (logical points)
    float  colorR;
    float  colorG;
    float  colorB;
    float  pad;
};

vertex VertexOut ring_vertex(uint vid [[vertex_id]],
                              constant RingUniforms& u [[buffer(0)]]) {
    // Quad centered on hotspot, large enough to contain ring + anti-alias margin.
    // padY is in height-normalized units; padX converts to width-normalized units.
    float padY = u.normRadius + u.normThickness * 3.0 + 0.002;
    float padX = padY / u.aspectRatio;
    const float2 corners[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0),
    };
    float2 norm = u.normCenter + corners[vid] * float2(padX, padY);
    float2 ndc  = float2(norm.x * 2.0 - 1.0, 1.0 - norm.y * 2.0);
    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    // UV: (0.5, 0.5) = center = hotspot; corners range from 0 to 1.
    out.uv = corners[vid] * 0.5 + 0.5;
    return out;
}

fragment float4 ring_fragment(VertexOut in [[stage_in]],
                               constant RingUniforms& u [[buffer(0)]]) {
    // Reconstruct offset in height-normalized units.
    // corners = (uv - 0.5) * 2; offset_x = corners.x * padX; corrected_x = offset_x * aspectRatio = corners.x * padY.
    // So both axes simplify to corners * padY — the aspect ratio cancels out perfectly.
    float  padY    = u.normRadius + u.normThickness * 3.0 + 0.002;
    float2 corners = (in.uv - float2(0.5)) * 2.0;
    float2 offset  = corners * padY;   // height-normalized, aspect-corrected
    float  dist    = length(offset);

    float outer = u.normRadius;
    float inner = outer - u.normThickness;
    float px    = 0.0008; // anti-alias width (~1px at 1440p)

    // Main ring band.
    float ring = smoothstep(inner - px, inner + px, dist)
               * smoothstep(outer + px, outer - px, dist);

    // Soft outer glow — wider, dimmer halo.
    float glow = smoothstep(inner, outer + u.normThickness * 1.5, dist)
               * smoothstep(outer + u.normThickness * 3.0, outer, dist)
               * 0.20;

    float a = clamp(ring + glow, 0.0, 1.0) * u.alpha;
    return float4(u.colorR, u.colorG, u.colorB, a);
}
