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

// Video frame processing. Matches VideoTransformUniforms in
// MetalTransformStage.swift.
struct VideoTransformUniforms {
    float4 mapX;
    float4 mapY;
    float2 sourceMin;
    float2 sourceMax;
    float2 stepU;
    float2 stepV;
};

// Resamples one plane. Output pixel centers map to normalized source
// coordinates through an affine transform; sampling stays inside the crop so
// pixels outside it never bleed in. Chroma planes use the same normalized
// mapping as luma, so 4:2:0 siting follows the source buffer's layout.
kernel void video_transform_plane(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant VideoTransformUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = destination.get_width();
    uint height = destination.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(width, height);
    float3 point = float3(uv, 1.0);
    float2 coordinate = float2(dot(uniforms.mapX.xyz, point), dot(uniforms.mapY.xyz, point));
    float2 halfTexel = 0.5 / float2(source.get_width(), source.get_height());
    float2 lower = uniforms.sourceMin + halfTexel;
    float2 upper = max(lower, uniforms.sourceMax - halfTexel);
    float4 value;
    if (any(uniforms.stepU != 0.0) || any(uniforms.stepV != 0.0)) {
        value = source.sample(bilinear, clamp(coordinate - uniforms.stepU - uniforms.stepV, lower, upper))
            + source.sample(bilinear, clamp(coordinate + uniforms.stepU - uniforms.stepV, lower, upper))
            + source.sample(bilinear, clamp(coordinate - uniforms.stepU + uniforms.stepV, lower, upper))
            + source.sample(bilinear, clamp(coordinate + uniforms.stepU + uniforms.stepV, lower, upper));
        value *= 0.25;
    } else {
        value = source.sample(bilinear, clamp(coordinate, lower, upper));
    }
    destination.write(value, gid);
}

// Matches VideoColorConversionUniforms in MetalRGBAConverter.swift.
struct VideoColorConversionUniforms {
    float4 coefficients;
    float lumaOffset;
    float lumaScale;
    float chromaOffset;
    float chromaScale;
};

// Bi-planar 4:2:0 Y'CbCr to RGBA. Removes the matrix and range only; the
// output keeps the source's transfer function and primaries.
kernel void video_ycbcr_to_rgba(
    texture2d<float, access::sample> luma [[texture(0)]],
    texture2d<float, access::sample> chroma [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant VideoColorConversionUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = destination.get_width();
    uint height = destination.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(width, height);
    float y = (luma.sample(bilinear, uv).r - uniforms.lumaOffset) * uniforms.lumaScale;
    float2 c = (chroma.sample(bilinear, uv).rg - uniforms.chromaOffset) * uniforms.chromaScale;
    float3 rgb = float3(
        y + uniforms.coefficients.x * c.y,
        y - uniforms.coefficients.y * c.x - uniforms.coefficients.z * c.y,
        y + uniforms.coefficients.w * c.x);
    destination.write(float4(saturate(rgb), 1.0), gid);
}

kernel void video_bgra_to_rgba(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    destination.write(source.read(gid), gid);
}

// ---------------------------------------------------------------------------
// Picture filters. Each kernel processes one plane of a bi-planar 4:2:0
// buffer, or the single plane of a BGRA buffer, reading `source` and writing
// `destination` at the same size.

// Matches PictureAdjustmentUniforms in PictureAdjustmentStage.swift.
struct PictureAdjustmentUniforms {
    float brightness;
    float contrast;
    float saturation;
    float gammaExponent;
    float hueCos;
    float hueSin;
    float lumaOffset;
    float lumaScale;
    float chromaOffset;
    float chromaScale;
    float padding0;
    float padding1;
};

static float adjust_luma(float y, constant PictureAdjustmentUniforms &u) {
    y = (y - 0.5) * u.contrast + 0.5 + u.brightness;
    // Sign-preserving gamma: video-range codes below black stay below black
    // instead of clipping as soon as any adjustment is active.
    return sign(y) * pow(abs(y), u.gammaExponent);
}

static float2 adjust_chroma(float2 c, constant PictureAdjustmentUniforms &u) {
    float2 rotated = float2(c.x * u.hueCos - c.y * u.hueSin, c.x * u.hueSin + c.y * u.hueCos);
    return rotated * u.saturation * u.contrast;
}

kernel void picture_adjust_luma(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant PictureAdjustmentUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
    float y = (source.read(gid).r - u.lumaOffset) * u.lumaScale;
    y = adjust_luma(y, u);
    destination.write(float4(saturate(y / u.lumaScale + u.lumaOffset)), gid);
}

kernel void picture_adjust_chroma(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant PictureAdjustmentUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
    float2 c = (source.read(gid).rg - u.chromaOffset) * u.chromaScale;
    c = adjust_chroma(c, u);
    float2 coded = saturate(c / u.chromaScale + u.chromaOffset);
    destination.write(float4(coded, 0.0, 1.0), gid);
}

// BGRA: adjust in BT.601 Y'CbCr, then return to RGB.
kernel void picture_adjust_rgb(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant PictureAdjustmentUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
    float4 color = source.read(gid);
    const float kr = 0.299, kb = 0.114, kg = 1.0 - kr - kb;
    float y = kr * color.r + kg * color.g + kb * color.b;
    float2 c = float2((color.b - y) / (2.0 * (1.0 - kb)), (color.r - y) / (2.0 * (1.0 - kr)));
    y = adjust_luma(y, u);
    c = adjust_chroma(c, u);
    float r = y + 2.0 * (1.0 - kr) * c.y;
    float b = y + 2.0 * (1.0 - kb) * c.x;
    float g = (y - kr * r - kb * b) / kg;
    destination.write(float4(saturate(float3(r, g, b)), color.a), gid);
}

// Contrast-adaptive sharpening (after AMD FidelityFX CAS): the weight falls as
// local contrast rises, so edges sharpen without ringing and flat areas are
// left alone. `strength` is 0...1.
struct SharpenUniforms {
    float strength;
    float padding0;
    float padding1;
    float padding2;
};

static float4 cas(texture2d<float, access::read> t, int2 p, float strength) {
    int2 limit = int2(t.get_width() - 1, t.get_height() - 1);
    float4 e = t.read(uint2(clamp(p, int2(0), limit)));
    float4 b = t.read(uint2(clamp(p + int2(0, -1), int2(0), limit)));
    float4 d = t.read(uint2(clamp(p + int2(-1, 0), int2(0), limit)));
    float4 f = t.read(uint2(clamp(p + int2(1, 0), int2(0), limit)));
    float4 h = t.read(uint2(clamp(p + int2(0, 1), int2(0), limit)));
    float4 mn = min(e, min(min(b, d), min(f, h)));
    float4 mx = max(e, max(max(b, d), max(f, h)));
    float4 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-5)));
    float4 w = amp * (-1.0 / mix(8.0, 5.0, strength));
    return saturate((b * w + d * w + f * w + h * w + e) / (1.0 + 4.0 * w));
}

kernel void sharpen_plane(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant SharpenUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
    float4 value = cas(source, int2(gid), u.strength);
    value.a = source.read(gid).a;
    destination.write(value, gid);
}

// Hash-based noise; stable per pixel and seed.
static float noise(uint2 p, uint seed) {
    uint h = p.x * 1973u + p.y * 9277u + seed * 26699u;
    h = (h ^ 61u) ^ (h >> 16);
    h *= 9u;
    h ^= h >> 4;
    h *= 0x27d4eb2du;
    h ^= h >> 15;
    return float(h & 0x00ffffffu) / float(0x01000000u);
}

// Deband (after libplacebo): replace each pixel by the mean of four random
// samples at growing radii when every sample is within the threshold, i.e.
// the area is a smooth gradient rather than detail; then add fine grain to
// hide residual steps.
struct DebandUniforms {
    float threshold;
    float radius;
    float grain;
    uint iterations;
    uint seed;
    uint padding0;
    uint padding1;
    uint padding2;
};

kernel void deband_plane(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant DebandUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = destination.get_width();
    uint height = destination.get_height();
    if (gid.x >= width || gid.y >= height) { return; }
    constexpr sampler bilinear(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 center = float2(gid) + 0.5;
    float4 original = source.sample(bilinear, center);
    float4 value = original;
    for (uint i = 1; i <= u.iterations; i++) {
        float distance = noise(gid, u.seed + i * 2u) * u.radius * float(i) / float(u.iterations);
        float angle = noise(gid, u.seed + i * 2u + 1u) * 6.2831853;
        float2 o = float2(cos(angle), sin(angle)) * distance;
        float4 mean = (source.sample(bilinear, center + o) + source.sample(bilinear, center - o)
            + source.sample(bilinear, center + float2(-o.y, o.x))
            + source.sample(bilinear, center + float2(o.y, -o.x))) * 0.25;
        float4 difference = abs(original - mean);
        float limit = u.threshold / float(i);
        value = select(value, mean, difference < limit);
    }
    float grain = (noise(gid, u.seed + 97u) - 0.5) * u.grain;
    value.rgb = saturate(value.rgb + grain);
    value.a = original.a;
    destination.write(value, gid);
}

// Denoise: an edge-preserving 3x3 spatial smooth, then motion-adaptive
// temporal blending with the previous output. Pixels that changed a lot keep
// the current frame, so motion does not ghost.
struct DenoiseUniforms {
    float rangeSigma;
    float temporalSigma;
    float temporalStrength;
    uint hasHistory;
};

kernel void denoise_plane(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    texture2d<float, access::read> history [[texture(2)]],
    constant DenoiseUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = destination.get_width();
    uint height = destination.get_height();
    if (gid.x >= width || gid.y >= height) { return; }
    int2 limit = int2(width - 1, height - 1);
    float4 center = source.read(gid);
    float4 sum = 0.0;
    float4 weights = 0.0;
    float rangeScale = -0.5 / (u.rangeSigma * u.rangeSigma);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float4 v = source.read(uint2(clamp(int2(gid) + int2(dx, dy), int2(0), limit)));
            float spatial = (dx == 0 && dy == 0) ? 1.0 : ((dx == 0 || dy == 0) ? 0.6 : 0.36);
            float4 diff = v - center;
            float4 w = spatial * exp(diff * diff * rangeScale);
            sum += v * w;
            weights += w;
        }
    }
    float4 smoothed = sum / max(weights, 1e-5);
    if (u.hasHistory != 0) {
        float4 previous = history.read(gid);
        float4 change = smoothed - previous;
        float4 k = u.temporalStrength * exp(change * change * (-0.5 / (u.temporalSigma * u.temporalSigma)));
        smoothed = mix(smoothed, previous, k);
    }
    smoothed.a = center.a;
    destination.write(smoothed, gid);
}
