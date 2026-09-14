/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "../Sources/RenderSupport/include/RenderSupportTypes.h"
#include <metal_stdlib>
using namespace metal;
struct MMRasterizerData {
    float4 position [[position]];
    float2 uv;
};
vertex MMRasterizerData RSRenderBlurVertex(uint id [[vertex_id]], constant RSRenderVertex2D *v [[buffer(0)]],
                                           constant uint2 *size [[buffer(1)]]) {
    MMRasterizerData o;
    float2 p = v[id].position;
    o.position = float4(p / (float2(*size) / 2), 0, 1);
    o.uv = v[id].textureCoordinate;
    return o;
}
fragment float4 RSRenderBlurAccumulate(MMRasterizerData in [[stage_in]],
                                       array<texture2d<half>, RS_RENDER_BLUR_MAX_SAMPLES> frames [[texture(0)]],
                                       constant int &count [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 out = 0;
    int n = min(count, RS_RENDER_BLUR_MAX_SAMPLES);
    for (int i = 0; i < n; i++)
        out += float4(frames[i].sample(s, in.uv));
    return n > 0 ? out / float(n) : float4(0);
}
