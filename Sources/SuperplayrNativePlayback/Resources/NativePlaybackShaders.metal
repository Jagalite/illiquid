#include <metal_stdlib>
using namespace metal;

struct ASSVertexIn {
    float2 position [[attribute(0)]];
    float2 textureCoordinate [[attribute(1)]];
    float4 color [[attribute(2)]];
};

struct ASSVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
    float4 color;
};

vertex ASSVertexOut ass_vertex(
    ASSVertexIn input [[stage_in]],
    constant float2 &viewport [[buffer(1)]])
{
    ASSVertexOut output;
    float2 unit = input.position / viewport;
    output.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);
    output.textureCoordinate = input.textureCoordinate;
    output.color = input.color;
    return output;
}

fragment float4 ass_r8_fragment(
    ASSVertexOut input [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]])
{
    float coverage = atlas.sample(atlasSampler, input.textureCoordinate).r;
    return float4(input.color.rgb, input.color.a * coverage);
}

fragment float4 ass_r8_premultiplied_fragment(
    ASSVertexOut input [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]])
{
    float alpha = input.color.a * atlas.sample(
        atlasSampler,
        input.textureCoordinate
    ).r;
    return float4(input.color.rgb * alpha, alpha);
}

fragment float4 ass_bgra_fragment(
    ASSVertexOut input [[stage_in]],
    texture2d<float> surface [[texture(0)]],
    sampler surfaceSampler [[sampler(0)]])
{
    return surface.sample(surfaceSampler, input.textureCoordinate);
}

struct PiPVideoVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex PiPVideoVertexOut pip_video_vertex(
    uint vertexID [[vertex_id]],
    constant float2 *coordinates [[buffer(0)]]) {
    const float2 positions[6] = {
        float2(-1.0,  1.0), float2(-1.0, -1.0), float2( 1.0,  1.0),
        float2( 1.0,  1.0), float2(-1.0, -1.0), float2( 1.0, -1.0)
    };
    PiPVideoVertexOut output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.textureCoordinate = coordinates[vertexID];
    return output;
}

fragment float4 pip_bgra_fragment(
    PiPVideoVertexOut input [[stage_in]],
    texture2d<float> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]])
{
    return source.sample(sourceSampler, input.textureCoordinate);
}

fragment float4 pip_nv12_fragment(
    PiPVideoVertexOut input [[stage_in]],
    texture2d<float> lumaTexture [[texture(0)]],
    texture2d<float> chromaTexture [[texture(1)]],
    sampler sourceSampler [[sampler(0)]],
    constant uint &sourceEncoding [[buffer(0)]],
    constant float4 &coefficients [[buffer(1)]])
{
    bool fullRange = (sourceEncoding & 1) != 0;
    bool tenBit = (sourceEncoding & 2) != 0;
    // P010 holds each ten-bit code in the high bits of a sixteen-bit sample.
    float codeScale = tenBit ? 65535.0 / 64.0 : 255.0;
    float bitScale = tenBit ? 4.0 : 1.0;
    float maximumCode = tenBit ? 1023.0 : 255.0;
    float y = lumaTexture.sample(sourceSampler, input.textureCoordinate).r * codeScale;
    float2 chroma = chromaTexture.sample(
        sourceSampler,
        input.textureCoordinate
    ).rg * codeScale - float2(128.0 * bitScale);
    y = fullRange ? y / maximumCode : (y - 16.0 * bitScale) / (219.0 * bitScale);
    chroma /= fullRange ? maximumCode : 224.0 * bitScale;
    float r = y + coefficients.x * chroma.y;
    float g = y + coefficients.y * chroma.x + coefficients.z * chroma.y;
    float b = y + coefficients.w * chroma.x;
    return float4(saturate(float3(r, g, b)), 1.0);
}

struct PiPSubtitleVertex {
    float2 position;
    float2 textureCoordinate;
    float4 color;
};

struct PiPSubtitleVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
    float4 color;
};

vertex PiPSubtitleVertexOut pip_subtitle_vertex(
    device const PiPSubtitleVertex *vertices [[buffer(0)]],
    constant float2 &viewport [[buffer(1)]],
    uint vertexID [[vertex_id]])
{
    PiPSubtitleVertex input = vertices[vertexID];
    float2 unit = input.position / viewport;
    PiPSubtitleVertexOut output;
    output.position = float4(
        unit.x * 2.0 - 1.0,
        1.0 - unit.y * 2.0,
        0.0,
        1.0
    );
    output.textureCoordinate = input.textureCoordinate;
    output.color = input.color;
    return output;
}

fragment float4 pip_subtitle_fragment(
    PiPSubtitleVertexOut input [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]])
{
    float coverage = atlas.sample(atlasSampler, input.textureCoordinate).r;
    return float4(input.color.rgb, input.color.a * coverage);
}

fragment float4 pip_bitmap_subtitle_fragment(
    PiPSubtitleVertexOut input [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]])
{
    return atlas.sample(atlasSampler, input.textureCoordinate);
}

// HDR PiP works in display-linear RGB with 1.0 = 203 cd/m2 graphics white.
// BT.2100 PQ is absolute. HLG uses the 1000-nit, gamma-1.2 reference display;
// inverse encoding restores HLG for the system's actual display adaptation.
float3 pip_hdr_weights(uint primaries) {
    return primaries == 9 ? float3(0.2627, 0.6780, 0.0593) : float3(0.2126, 0.7152, 0.0722);
}
float3 pip_hdr_to_linear(float3 encoded, uint transfer, uint primaries) {
    encoded = saturate(encoded);
    if (transfer == 16) {
        float3 p = pow(encoded, float3(1.0 / 78.84375));
        return pow(max(p - 0.8359375, 0.0) / max(18.8515625 - 18.6875 * p, 1e-7),
                   float3(1.0 / 0.1593017578125)) * (10000.0 / 203.0);
    }
    float3 scene = select(encoded * encoded / 3.0,
        (exp((encoded - 0.55991073) / 0.17883277) + 0.28466892) / 12.0, encoded > 0.5);
    return scene * pow(max(dot(scene, pip_hdr_weights(primaries)), 0.0), 0.2) * (1000.0 / 203.0);
}
float3 pip_hdr_from_linear(float3 linear, uint transfer, uint primaries) {
    linear = max(linear, 0.0);
    if (transfer == 16) {
        float3 p = pow(linear * (203.0 / 10000.0), float3(0.1593017578125));
        return saturate(pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), float3(78.84375)));
    }
    float3 display = linear * (203.0 / 1000.0);
    float luma = dot(display, pip_hdr_weights(primaries));
    float3 scene = display / max(pow(max(luma, 0.0), 1.0 / 6.0), 1e-7);
    return saturate(select(sqrt(3.0 * scene),
        0.17883277 * log(max(12.0 * scene - 0.28466892, 1e-7)) + 0.55991073, scene > 1.0 / 12.0));
}
float3 pip_hdr_graphics(float3 srgb, uint primaries) {
    float3 linear = select(srgb / 12.92, pow((srgb + 0.055) / 1.055, float3(2.4)), srgb > 0.04045);
    if (primaries == 9) {
        return float3(dot(linear, float3(0.6274040, 0.3292820, 0.0433136)),
                      dot(linear, float3(0.0690970, 0.9195400, 0.0113612)),
                      dot(linear, float3(0.0163916, 0.0880132, 0.8955950)));
    }
    return linear;
}
fragment float4 pip_hdr_video_fragment(PiPVideoVertexOut input [[stage_in]],
    texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]],
    sampler sourceSampler [[sampler(0)]], constant uint &encoding [[buffer(0)]],
    constant float4 &coefficients [[buffer(1)]], constant uint &transfer [[buffer(2)]],
    constant uint &primaries [[buffer(3)]]) {
    bool full = (encoding & 1) != 0;
    float y = luma.sample(sourceSampler, input.textureCoordinate).r * (65535.0 / 64.0);
    float2 c = chroma.sample(sourceSampler, input.textureCoordinate).rg * (65535.0 / 64.0) - 512.0;
    y = full ? y / 1023.0 : (y - 64.0) / 876.0;
    c /= full ? 1023.0 : 896.0;
    float3 rgb(y + coefficients.x * c.y, y + coefficients.y * c.x + coefficients.z * c.y,
               y + coefficients.w * c.x);
    return float4(pip_hdr_to_linear(rgb, transfer, primaries), 1.0);
}
fragment float4 pip_hdr_text_fragment(PiPSubtitleVertexOut input [[stage_in]],
    texture2d<float> atlas [[texture(0)]], sampler sourceSampler [[sampler(0)]],
    constant uint &primaries [[buffer(3)]]) {
    return float4(pip_hdr_graphics(input.color.rgb, primaries),
                  input.color.a * atlas.sample(sourceSampler, input.textureCoordinate).r);
}
fragment float4 pip_hdr_bitmap_fragment(PiPSubtitleVertexOut input [[stage_in]],
    texture2d<float> atlas [[texture(0)]], sampler sourceSampler [[sampler(0)]],
    constant uint &primaries [[buffer(3)]]) {
    float4 pixel = atlas.sample(sourceSampler, input.textureCoordinate);
    return float4(pip_hdr_graphics(pixel.rgb / max(pixel.a, 1e-7), primaries) * pixel.a, pixel.a);
}
float3 pip_hdr_yuv(float3 rgb, float4 coefficients) {
    float kr = 1.0 - coefficients.x / 2.0, kb = 1.0 - coefficients.w / 2.0;
    float y = dot(rgb, float3(kr, 1.0 - kr - kb, kb));
    return float3(y, (rgb.b - y) / coefficients.w, (rgb.r - y) / coefficients.x);
}
fragment float pip_hdr_luma_fragment(PiPVideoVertexOut input [[stage_in]],
    texture2d<float> linear [[texture(0)]], constant uint &encoding [[buffer(0)]],
    constant float4 &coefficients [[buffer(1)]], constant uint &transfer [[buffer(2)]],
    constant uint &primaries [[buffer(3)]]) {
    uint2 p = min(uint2(input.position.xy), uint2(linear.get_width()-1, linear.get_height()-1));
    float y = pip_hdr_yuv(pip_hdr_from_linear(linear.read(p).rgb, transfer, primaries), coefficients).x;
    float code = (encoding & 1) != 0 ? y * 1023.0 : y * 876.0 + 64.0;
    return round(clamp(code, 0.0, 1023.0)) * (64.0 / 65535.0);
}
fragment float2 pip_hdr_chroma_fragment(PiPVideoVertexOut input [[stage_in]],
    texture2d<float> linear [[texture(0)]], constant uint &encoding [[buffer(0)]],
    constant float4 &coefficients [[buffer(1)]], constant uint &transfer [[buffer(2)]],
    constant uint &primaries [[buffer(3)]]) {
    uint2 p = uint2(input.position.xy) * 2;
    uint2 limit(linear.get_width()-1, linear.get_height()-1);
    float3 rgb(0.0);
    for (uint y = 0; y < 2; ++y) for (uint x = 0; x < 2; ++x)
        rgb += pip_hdr_from_linear(linear.read(min(p + uint2(x,y), limit)).rgb, transfer, primaries) * 0.25;
    float2 c = pip_hdr_yuv(rgb, coefficients).yz;
    float2 code = c * ((encoding & 1) != 0 ? 1023.0 : 896.0) + 512.0;
    return round(clamp(code, 0.0, 1023.0)) * (64.0 / 65535.0);
}
