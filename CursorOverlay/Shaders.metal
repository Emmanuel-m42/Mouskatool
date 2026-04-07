#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Passed from CPU each frame
struct CursorUniforms {
    float2 normPos;   // cursor top-left, normalized (0=left/top, 1=right/bottom)
    float2 normSize;  // cursor size, normalized
};

vertex VertexOut cursor_vertex(uint vid [[vertex_id]],
                                constant CursorUniforms& u [[buffer(0)]]) {
    // Triangle strip: TL, TR, BL, BR
    const float2 corners[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };
    const float2 uvs[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 1.0),
    };

    // Position in normalized screen space (0,0)=top-left, (1,1)=bottom-right
    float2 norm = u.normPos + corners[vid] * u.normSize;

    // Convert to Metal NDC: x [-1,1], y [1,-1] (Y flipped)
    float2 ndc = float2(norm.x * 2.0 - 1.0, 1.0 - norm.y * 2.0);

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 cursor_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);
    return tex.sample(s, in.uv);
}
