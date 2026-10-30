// SPDX-License-Identifier: GPL-3.0-or-later
//
// Infinify compositor — implementation. See compositor.h and COMPOSITOR-NOTES.md.
// The cached-background chunk generation is described in BACKGROUND-NOTES.md,
// section 17.3.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "compositor.h"
#import "metal-support.h"

#import <CoreText/CoreText.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <simd/simd.h>

static NSString *const IFCErrorDomain = @"IFCompositorErrorDomain";

// Largest 2D texture on every Apple-silicon GPU.
static const NSUInteger kIFCMaxTextureSide = 16384;
// CoreVideo keeps the Metal texture of a released wrapper, and through it the
// memory of the buffer's IOSurface, until the texture cache is flushed after
// the buffer has gone unused (released by everyone) for this many seconds.
// (CoreVideo's default, stated so the renderer can pace the flush that lets
// it go.)
static const double kIFCTextureCacheAge = 1.0;

// blur.rs constants.
static const long kIFCBlurCacheStep = 64;             // CACHE_STEP
static const unsigned kIFCBlurKeepFrames = 60;        // PAD_KEEP_FRAMES, SCRATCH_KEEP_FRAMES
static const uint8_t kIFCBlurForceDirtyFrames = 2;    // BlurCache::force_dirty_frames
static const uint8_t kIFCBlurMaskWarmupCommits = 8;   // MASK_WARMUP_COMMITS
// `1u32 << (passes + 1)` (blur_pad) is defined up to here.
static const uint32_t kIFCBlurMaxPasses = 30;
// error_bar.rs constants.
static const float kIFCErrorBarFontPx = 11.0f;        // ERROR_BAR_FONT_PX, logical px (not points)
static const long kIFCErrorBarPadX = 12;              // ERROR_BAR_PAD_X
static const long kIFCErrorBarPadY = 6;               // ERROR_BAR_PAD_Y
// closing.rs DONE_EPSILON, window_animation.rs PROGRESS_DONE_EPSILON.
static const double kIFCAnimationDoneEpsilon = 0.01;

// MARK: - Rust numeric rules

// Rust `f64::round() as i32`: half away from zero (C `round`), saturating.
static inline long IFCRound(double v) {
    if (isnan(v)) return 0;
    v = round(v);
    if (v >= 2147483647.0) return 2147483647L;
    if (v <= -2147483648.0) return -2147483648L;
    return (long)v;
}

// Rust `f64 as i32`: truncation toward zero, saturating, NaN -> 0.
static inline long IFCTrunc(double v) {
    if (isnan(v)) return 0;
    if (v >= 2147483647.0) return 2147483647L;
    if (v <= -2147483648.0) return -2147483648L;
    return (long)v;
}

// Rust `f64::ceil() as i32`.
static inline long IFCCeil(double v) {
    return IFCTrunc(ceil(v));
}

// Rust `f64 as u8`: truncation, saturating, NaN -> 0.
static inline uint8_t IFCU8(double v) {
    if (!(v > 0.0)) return 0;
    if (v >= 255.0) return 255;
    return (uint8_t)v;
}

// MARK: - Integer rectangles (smithay `Rectangle<i32, _>`)

typedef struct {
    long x, y, w, h;
} IFCRectI;

static inline IFCRectI IFCRectIMake(long x, long y, long w, long h) {
    IFCRectI r = {x, y, w, h};
    return r;
}

// smithay `Rectangle::overlaps` (exclusive) and `Rectangle::intersection`.
static inline BOOL IFCRectIIntersect(IFCRectI a, IFCRectI b, IFCRectI *out) {
    if (!(a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h)) return NO;
    if (out) {
        long x0 = MAX(a.x, b.x), y0 = MAX(a.y, b.y);
        long x1 = MIN(a.x + a.w, b.x + b.w), y1 = MIN(a.y + a.h, b.y + b.h);
        *out = IFCRectIMake(x0, y0, x1 - x0, y1 - y0);
    }
    return YES;
}

// A logical rectangle in f64 (smithay `Rectangle<f64, Logical>`).
typedef struct {
    double x, y, w, h;
} IFCRectD;

// elements.rs `painted_size`: the pixel-centre rule with ties rounding DOWN.
static inline long IFCPaintedExtent(double size, double s) {
    const double EPS = 1e-3;
    double v = ceil(size * s - 0.5 - EPS);
    return IFCTrunc(v > 0.0 ? v : 0.0);
}

// elements.rs `painted_rect`.
static inline IFCRectI IFCPaintedRect(IFCRectD r, double s) {
    return IFCRectIMake(IFCRound(r.x * s), IFCRound(r.y * s), IFCPaintedExtent(r.w, s), IFCPaintedExtent(r.h, s));
}

// elements.rs `corner_round_rect` (`PixelSnapRescaleElement::geometry` with
// origin (0,0)): the two corners round independently.
static inline IFCRectI IFCCornerRound(IFCRectI r, double zoom) {
    long x0 = IFCRound((double)r.x * zoom), y0 = IFCRound((double)r.y * zoom);
    long x1 = IFCRound((double)(r.x + r.w) * zoom), y1 = IFCRound((double)(r.y + r.h) * zoom);
    return IFCRectIMake(x0, y0, MAX(x1 - x0, 0L), MAX(y1 - y0, 0L));
}

// smithay `Rectangle::to_f64().upscale(s).to_i32_round()` — location and size
// round independently. Used for `to_physical_precise_round` (s = output scale)
// and for `RescaleRenderElement::geometry` (s = zoom).
static inline IFCRectI IFCScaleRound(IFCRectI r, double s) {
    return IFCRectIMake(IFCRound((double)r.x * s), IFCRound((double)r.y * s), IFCRound((double)r.w * s), IFCRound((double)r.h * s));
}

// smithay `MemoryRenderBufferRenderElement::geometry`: location in physical
// f64, logical size; size = round(size * s + loc) - round(loc).
static inline IFCRectI IFCMemoryElementRect(double locX, double locY, long logicalW, long logicalH, double s) {
    long x = IFCRound(locX), y = IFCRound(locY);
    return IFCRectIMake(x, y, IFCRound((double)logicalW * s + locX) - x, IFCRound((double)logicalH * s + locY) - y);
}

// MARK: - Uniform block

// Must match `struct IFCUniforms` in kIFCMSL (240 bytes, 16-byte aligned).
typedef struct {
    simd_float4 dst;            // element rectangle in target pixels (x, y, w, h): v_coords = (pixel centre - xy) / wh
    simd_float4 quad;           // the part of `dst` this draw rasterises (all of it, or one strip around a hole)
    simd_float4 rect;           // border `u_inner_rect` / shadow `u_window_rect`
    simd_float4 color;          // `u_color`
    simd_float4 corner_radius;  // corner_clip `corner_radius` (tl, tr, br, bl)
    simd_float4 src;            // sampled sub-rect of the texture, normalised (x, y, w, h): smithay's tex_matrix
    simd_float4 m0, m1, m2;     // corner_clip `input_to_geo`, column-major
    simd_float4 uv_bounds;      // texel-centre bounds of `src` (min.xy, max.xy): sampling never leaves the content
    simd_float4 blur;           // blur_down / blur_up `u_halfpixel` (xy) and `u_offset` (z)
    simd_float2 target;         // target size in pixels
    simd_float2 size;           // pixel shaders' `size`
    simd_float2 geo_size;       // corner_clip `geo_size`
    float alpha;                // smithay's `alpha`
    float aa_scale;             // border `u_aa_scale` / corner_clip `aa_scale`
    float inner_radius;         // border `u_inner_radius`
    float border_width;         // border `u_border_width`
    float outer_radius;         // border `u_outer_radius`
    float radius;               // shadow `u_radius`
    float shadow_corner;        // shadow `u_corner_radius`
    float no_alpha;             // 1.0 selects the NO_ALPHA variant of a texture program
    float pad0, pad1;
} IFCUniforms;

_Static_assert(sizeof(IFCUniforms) == 240, "IFCUniforms layout must match the MSL struct");

// MARK: - Metal sources

static NSString *const kIFCMSL =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct IFCUniforms {\n"
     "    float4 dst;\n"
     "    float4 quad;\n"
     "    float4 rect;\n"
     "    float4 color;\n"
     "    float4 corner_radius;\n"
     "    float4 src;\n"
     "    float4 m0;\n"
     "    float4 m1;\n"
     "    float4 m2;\n"
     "    float4 uv_bounds;\n"
     "    float4 blur;\n"
     "    float2 target;\n"
     "    float2 size;\n"
     "    float2 geo_size;\n"
     "    float alpha;\n"
     "    float aa_scale;\n"
     "    float inner_radius;\n"
     "    float border_width;\n"
     "    float outer_radius;\n"
     "    float radius;\n"
     "    float shadow_corner;\n"
     "    float no_alpha;\n"
     "    float pad0;\n"
     "    float pad1;\n"
     "};\n"
     "struct IFCVertexOut { float4 position [[position]]; };\n"
     "\n"
     // smithay's quad: `vert` in 0..1 scaled and translated to the element's
     // destination rectangle, then projected. Four vertices, triangle strip.
     // `quad` is that rectangle or a part of it; the fragment stage always
     // measures from `dst`, so splitting an element changes no pixel.
     "vertex IFCVertexOut ifc_vertex(uint vid [[vertex_id]], constant IFCUniforms &U [[buffer(0)]]) {\n"
     "    float2 corner = float2(float(vid & 1u), float((vid >> 1) & 1u));\n"
     "    float2 p = U.quad.xy + corner * U.quad.zw;\n"
     "    IFCVertexOut out;\n"
     "    out.position = float4(p.x / U.target.x * 2.0 - 1.0, 1.0 - p.y / U.target.y * 2.0, 0.0, 1.0);\n"
     "    return out;\n"
     "}\n"
     // smithay's `v_coords` for a pixel shader: 0..1 across the element's
     // destination rectangle. Metal's [[position]] is the pixel centre, origin
     // top-left.
     "static inline float2 ifc_element_coords(float4 position, constant IFCUniforms &U) {\n"
     "    return (position.xy - U.dst.xy) / U.dst.zw;\n"
     "}\n"
     // smithay's `v_coords` for a texture shader: the element coordinate through
     // `tex_matrix`, i.e. the sampled sub-rect of the texture in UV.
     "static inline float2 ifc_texture_coords(float4 position, constant IFCUniforms &U) {\n"
     "    return U.src.xy + ifc_element_coords(position, U) * U.src.zw;\n"
     "}\n"
     // texture2D(tex, v_coords) under GL_CLAMP_TO_EDGE, with the edge being that
     // of the content sub-rect instead of the whole texture: for a buffer that
     // is all content the two are the same sample (COMPOSITOR-NOTES.md, deviations).
     "static inline float4 ifc_sample(texture2d<float> tex, sampler smp, float2 v_coords, constant IFCUniforms &U) {\n"
     "    return tex.sample(smp, clamp(v_coords, U.uv_bounds.xy, U.uv_bounds.zw));\n"
     "}\n"
     "\n"
     // Shared by border.glsl and shadow.glsl (identical in both).
     "static inline float sd_rounded_box(float2 p, float2 half_size, float r) {\n"
     "    float2 q = abs(p) - half_size + float2(r);\n"
     "    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/border.glsl
     // sha256 a2eb306cd658ece061a18d54dd499d2f2993630130ab52dc9882360c34f7f294
     // Uniform-thickness stroke around a rounded rectangle; the stroke sits
     // OUTSIDE the inner rect.
     // ------------------------------------------------------------------
     "fragment float4 ifc_border(IFCVertexOut in [[stage_in]],\n"
     "                           constant IFCUniforms &U [[buffer(0)]]) {\n"
     "    float2 v_coords = ifc_element_coords(in.position, U);\n"
     "    float alpha = U.alpha;\n"
     "    float2 size = U.size;\n"
     "    float4 u_inner_rect = U.rect;\n"
     "    float u_inner_radius = U.inner_radius;\n"
     "    float u_border_width = U.border_width;\n"
     "    float u_outer_radius = U.outer_radius;\n"
     "    float u_aa_scale = U.aa_scale;\n"
     "    float4 u_color = U.color;\n"
     "\n"
     "    float2 pixel = v_coords * size;\n"
     "    float2 inner_center = u_inner_rect.xy + u_inner_rect.zw * 0.5;\n"
     "    float2 inner_half = u_inner_rect.zw * 0.5;\n"
     "    float2 p = pixel - inner_center;\n"
     "\n"
     "    float2 outer_half = inner_half + float2(u_border_width);\n"
     "\n"
     "    float sd_inner = sd_rounded_box(p, inner_half, u_inner_radius);\n"
     "    float sd_outer = sd_rounded_box(p, outer_half, u_outer_radius);\n"
     "\n"
     "    float a_outer = clamp(0.5 - sd_outer * u_aa_scale, 0.0, 1.0);\n"
     "    float a_inner = clamp(0.5 + sd_inner * u_aa_scale, 0.0, 1.0);\n"
     "    float coverage = a_outer * a_inner;\n"
     "\n"
     "    return u_color * coverage * alpha;\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/shadow.glsl
     // sha256 0ee61e0f85be6fa1073db42c6ce00a936c5544b279bea4023506e443a7e12f66
     // ERF-based analytical Gaussian shadow.
     // ------------------------------------------------------------------
     "static inline float2 erf_approx(float2 v) {\n"
     "    float2 s = sign(v);\n"
     "    float2 a = abs(v);\n"
     "    float2 r1 = 1.0 + (0.278393 + (0.230389 + (0.000972 + 0.078108 * a) * a) * a) * a;\n"
     "    float2 r2 = r1 * r1;\n"
     "    return s - s / (r2 * r2);\n"
     "}\n"
     "static inline float gaussian(float x, float sigma) {\n"
     "    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * 3.14159265) * sigma);\n"
     "}\n"
     "static inline float blur_along_x(float x, float y, float sigma, float corner, float2 half_size) {\n"
     "    float delta = min(half_size.y - corner - abs(y), 0.0);\n"
     "    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));\n"
     "    float2 integral = 0.5 + 0.5 * erf_approx((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));\n"
     "    return integral.y - integral.x;\n"
     "}\n"
     "fragment float4 ifc_shadow(IFCVertexOut in [[stage_in]],\n"
     "                           constant IFCUniforms &U [[buffer(0)]]) {\n"
     "    float2 v_coords = ifc_element_coords(in.position, U);\n"
     "    float alpha = U.alpha;\n"
     "    float2 size = U.size;\n"
     "    float4 u_window_rect = U.rect;\n"
     "    float u_radius = U.radius;\n"
     "    float4 u_color = U.color;\n"
     "    float u_corner_radius = U.shadow_corner;\n"
     "\n"
     "    float2 pixel = v_coords * size;\n"
     "\n"
     "    float2 center = u_window_rect.xy + u_window_rect.zw * 0.5;\n"
     "    float2 half_size = u_window_rect.zw * 0.5;\n"
     "    float2 p = pixel - center;\n"
     "\n"
     "    float sigma = u_radius / 3.0;\n"
     "    float corner = u_corner_radius;\n"
     "\n"
     "    float low = p.y - half_size.y;\n"
     "    float high = p.y + half_size.y;\n"
     "    float start = clamp(-3.0 * sigma, low, high);\n"
     "    float end = clamp(3.0 * sigma, low, high);\n"
     "\n"
     "    float step_size = (end - start) / 4.0;\n"
     "    float y = start + step_size * 0.5;\n"
     "    float shadow = 0.0;\n"
     "    for (int i = 0; i < 4; i++) {\n"
     "        shadow += blur_along_x(p.x, p.y - y, sigma, corner, half_size)\n"
     "                * gaussian(y, sigma) * step_size;\n"
     "        y += step_size;\n"
     "    }\n"
     "\n"
     "    float dist = sd_rounded_box(p, half_size, corner);\n"
     "    float outside = step(0.0, dist);\n"
     "\n"
     "    return u_color * shadow * outside * alpha;\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/corner_clip.glsl
     // sha256 aa38e89961a02af57893e51f3c491e71bfc9aacd7d55d602c678432caae11b21
     // Per-element surface clipping to a rounded rectangle in geometry space.
     // NO_ALPHA is a uniform here instead of a second program; EXTERNAL
     // (samplerExternalOES) and DEBUG_FLAGS (tint) have no use on Metal.
     // ------------------------------------------------------------------
     "static inline float corner_alpha(float2 coords, float2 size, float4 r, float aa_scale) {\n"
     "    float2 center;\n"
     "    float radius;\n"
     "    if (coords.x < r.x && coords.y < r.x) {\n"
     "        radius = r.x;\n"
     "        center = float2(radius, radius);\n"
     "    } else if (size.x - r.y < coords.x && coords.y < r.y) {\n"
     "        radius = r.y;\n"
     "        center = float2(size.x - radius, radius);\n"
     "    } else if (size.x - r.z < coords.x && size.y - r.z < coords.y) {\n"
     "        radius = r.z;\n"
     "        center = float2(size.x - radius, size.y - radius);\n"
     "    } else if (coords.x < r.w && size.y - r.w < coords.y) {\n"
     "        radius = r.w;\n"
     "        center = float2(radius, size.y - radius);\n"
     "    } else {\n"
     "        return 1.0;\n"
     "    }\n"
     "    float dist = distance(coords, center);\n"
     "    float t = clamp((dist - radius) * aa_scale + 0.5, 0.0, 1.0);\n"
     "    return 1.0 - t * t * (3.0 - 2.0 * t);\n"
     "}\n"
     "fragment float4 ifc_corner_clip(IFCVertexOut in [[stage_in]],\n"
     "                                constant IFCUniforms &U [[buffer(0)]],\n"
     "                                texture2d<float> tex [[texture(0)]],\n"
     "                                sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifc_texture_coords(in.position, U);\n"
     "    float alpha = U.alpha;\n"
     "    float aa_scale = U.aa_scale;\n"
     "    float2 geo_size = U.geo_size;\n"
     "    float4 corner_radius = U.corner_radius;\n"
     "    float3x3 input_to_geo = float3x3(U.m0.xyz, U.m1.xyz, U.m2.xyz);\n"
     "\n"
     "    float3 coords_geo = input_to_geo * float3(v_coords, 1.0);\n"
     "\n"
     "    float4 color = ifc_sample(tex, smp, v_coords, U);\n"
     "    if (U.no_alpha > 0.5) {\n"
     "        color = float4(color.rgb, 1.0);\n"
     "    }\n"
     "\n"
     "    if (coords_geo.x < 0.0 || 1.0 < coords_geo.x\n"
     "            || coords_geo.y < 0.0 || 1.0 < coords_geo.y) {\n"
     "        color = float4(0.0);\n"
     "    } else {\n"
     "        color = color * corner_alpha(coords_geo.xy * geo_size, geo_size, corner_radius, aa_scale);\n"
     "    }\n"
     "\n"
     "    color = color * alpha;\n"
     "\n"
     "    return color;\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // smithay 0.7.0 src/backend/renderer/gles/shaders/implicit/texture.frag:
     // the default texture program every memory buffer (title bar, stand-in
     // body, label) and every unclipped surface is drawn with.
     // ------------------------------------------------------------------
     "fragment float4 ifc_texture(IFCVertexOut in [[stage_in]],\n"
     "                            constant IFCUniforms &U [[buffer(0)]],\n"
     "                            texture2d<float> tex [[texture(0)]],\n"
     "                            sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifc_texture_coords(in.position, U);\n"
     "    float4 color = ifc_sample(tex, smp, v_coords, U);\n"
     "    if (U.no_alpha > 0.5) {\n"
     "        color = float4(color.rgb, 1.0) * U.alpha;\n"
     "    } else {\n"
     "        color = color * U.alpha;\n"
     "    }\n"
     "    return color;\n"
     "}\n"
     "\n"
     // The same program over a buffer of one colour (upstream's outline strips
     // are solid-colour memory buffers): `texel * alpha` with a constant texel.
     "fragment float4 ifc_solid(IFCVertexOut in [[stage_in]],\n"
     "                          constant IFCUniforms &U [[buffer(0)]]) {\n"
     "    return U.color * U.alpha;\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/blur_down.glsl
     // sha256 dd87594ca3bf59d641607cbdede7b9c38dbe127a6e95a1a1690c6e01b5f27245
     // Dual-Kawase downsample: the centre tap four times, four diagonal taps.
     // `tex` is sampled exactly as upstream samples it — linear, wrapped by
     // the sampler (MIRRORED_REPEAT), and NOT clamped to the sub-rectangle the
     // pass reads: the taps do leave it (blur.rs `render_blur`). `alpha` is
     // declared upstream and unused; DEBUG_FLAGS (tint) has no use on Metal.
     // ------------------------------------------------------------------
     "fragment float4 ifc_blur_down(IFCVertexOut in [[stage_in]],\n"
     "                              constant IFCUniforms &U [[buffer(0)]],\n"
     "                              texture2d<float> tex [[texture(0)]],\n"
     "                              sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifc_texture_coords(in.position, U);\n"
     "    float2 u_halfpixel = U.blur.xy;\n"
     "    float u_offset = U.blur.z;\n"
     "\n"
     "    float4 sum = tex.sample(smp, v_coords) * 4.0;\n"
     "    sum += tex.sample(smp, v_coords - u_halfpixel * u_offset);\n"
     "    sum += tex.sample(smp, v_coords + u_halfpixel * u_offset);\n"
     "    sum += tex.sample(smp, v_coords + float2(u_halfpixel.x, -u_halfpixel.y) * u_offset);\n"
     "    sum += tex.sample(smp, v_coords - float2(u_halfpixel.x, -u_halfpixel.y) * u_offset);\n"
     "    return sum / 8.0;\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/blur_up.glsl
     // sha256 5a4bf2dc53f93b08ff3df2e9f3cb68bc2420c612f9bf7a92d1aa3b4acbabfbd9
     // Dual-Kawase upsample: four axis taps and four diagonal taps, the
     // diagonals twice. Sampled like blur_down.
     // ------------------------------------------------------------------
     "fragment float4 ifc_blur_up(IFCVertexOut in [[stage_in]],\n"
     "                            constant IFCUniforms &U [[buffer(0)]],\n"
     "                            texture2d<float> tex [[texture(0)]],\n"
     "                            sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifc_texture_coords(in.position, U);\n"
     "    float2 u_halfpixel = U.blur.xy;\n"
     "    float u_offset = U.blur.z;\n"
     "\n"
     "    float4 sum = tex.sample(smp, v_coords + float2(-u_halfpixel.x * 2.0, 0.0) * u_offset);\n"
     "    sum += tex.sample(smp, v_coords + float2(-u_halfpixel.x, u_halfpixel.y) * u_offset) * 2.0;\n"
     "    sum += tex.sample(smp, v_coords + float2(0.0, u_halfpixel.y * 2.0) * u_offset);\n"
     "    sum += tex.sample(smp, v_coords + float2(u_halfpixel.x, u_halfpixel.y) * u_offset) * 2.0;\n"
     "    sum += tex.sample(smp, v_coords + float2(u_halfpixel.x * 2.0, 0.0) * u_offset);\n"
     "    sum += tex.sample(smp, v_coords + float2(u_halfpixel.x, -u_halfpixel.y) * u_offset) * 2.0;\n"
     "    sum += tex.sample(smp, v_coords + float2(0.0, -u_halfpixel.y * 2.0) * u_offset);\n"
     "    sum += tex.sample(smp, v_coords + float2(-u_halfpixel.x, -u_halfpixel.y) * u_offset) * 2.0;\n"
     "    return sum / 12.0;\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/blur_mask.glsl
     // sha256 5d9b29e10ec0d8e532983b1cb6d2a61960e349a9018ab1f7e4e5a43364560289
     // The window's alpha shape, thresholded. Drawn with the blend function
     // upstream sets around it, (ZERO, SRC_ALPHA) on colour and alpha, so the
     // frost already in the target is multiplied by it.
     // ------------------------------------------------------------------
     "fragment float4 ifc_blur_mask(IFCVertexOut in [[stage_in]],\n"
     "                              constant IFCUniforms &U [[buffer(0)]],\n"
     "                              texture2d<float> tex [[texture(0)]],\n"
     "                              sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifc_texture_coords(in.position, U);\n"
     "    float alpha = U.alpha;\n"
     "\n"
     "    float a = step(0.001, tex.sample(smp, v_coords).a);\n"
     "    return float4(a) * alpha;\n"
     "}\n"
     "\n"
     // The crop of a backdrop capture that overhangs the output. Upstream
     // captures the part that has backdrop into a texture of exactly that size
     // and lets the crop read past its edges with MIRRORED_REPEAT, so real
     // backdrop is reflected back across the output boundary (blur.rs
     // `backdrop_capture`). Here the capture sits inside a texture of the
     // padded extent, at `rect` (texels), and this reflects about the edges of
     // `rect` itself: texel k of a row of n maps to k mod 2n, mirrored when
     // that is n or more — what GL_MIRRORED_REPEAT gives at texel centres.
     "fragment float4 ifc_mirror_copy(IFCVertexOut in [[stage_in]],\n"
     "                                constant IFCUniforms &U [[buffer(0)]],\n"
     "                                texture2d<float> tex [[texture(0)]],\n"
     "                                sampler smp [[sampler(0)]]) {\n"
     "    float2 n = U.rect.zw;\n"
     "    float2 q = in.position.xy - U.rect.xy;\n"
     "    float2 m = q - 2.0 * n * floor(q / (2.0 * n));\n"
     "    m = select(m, 2.0 * n - m, m > n);\n"
     "    return tex.sample(smp, (m + U.rect.xy) / U.size);\n"
     "}\n";

// MARK: - Per-device shared state

typedef NS_ENUM(NSUInteger, IFCPipe) {
    IFCPipeBorder = 0,
    IFCPipeShadow,
    IFCPipeCornerClip,
    IFCPipeTexture,
    IFCPipeSolid,
    IFCPipeAlphaOne,  // writes alpha = 1 only: completes a premultiplied blend over the opaque clear
    IFCPipeBlurDown,  // blending off: each Kawase pass replaces the region it draws
    IFCPipeBlurUp,
    IFCPipeBlurMask,  // (ZERO, SRC_ALPHA): multiplies the frost by the window's thresholded alpha
    IFCPipeMirrorCopy,  // blending off
    IFCPipeCount,
};

@interface IFCDeviceResources : NSObject
@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> queue;
@property (nonatomic, readonly) id<MTLSamplerState> sampler;
@property (nonatomic, readonly) id<MTLSamplerState> mirrorSampler;
@property (nonatomic, readonly, nullable) NSString *error;
+ (instancetype)resourcesForDevice:(id<MTLDevice>)device;
- (nullable id<MTLRenderPipelineState>)pipeline:(IFCPipe)pipe;
@end

@implementation IFCDeviceResources {
    id<MTLRenderPipelineState> _pipelines[IFCPipeCount];
}

+ (instancetype)resourcesForDevice:(id<MTLDevice>)device {
    return DWMetalSharedForDevice(self, device, ^id{ return [[IFCDeviceResources alloc] initWithDevice:device]; });
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _device = device;
    _queue = [device newCommandQueue];

    // The same math mode as the background module: IEEE arithmetic, so the
    // translated GLSL computes what it says.
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kIFCMSL options:DWMetalCompileOptions() error:&error];
    if (!library) {
        _error = [NSString stringWithFormat:@"compositor: shaders failed to compile: %@", error.localizedDescription];
        NSLog(@"%@", _error);
        return self;
    }
    id<MTLFunction> vertex = [library newFunctionWithName:@"ifc_vertex"];
    NSString *const names[IFCPipeCount] = {@"ifc_border", @"ifc_shadow", @"ifc_corner_clip", @"ifc_texture", @"ifc_solid", @"ifc_solid",
                                           @"ifc_blur_down", @"ifc_blur_up", @"ifc_blur_mask", @"ifc_mirror_copy"};
    for (NSUInteger i = 0; i < IFCPipeCount; i++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vertex;
        pd.fragmentFunction = [library newFunctionWithName:names[i]];
        // Not an _sRGB format: like upstream's GL framebuffer, values are
        // stored and blended as written (sRGB-encoded).
        MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0];
        ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
        if (i == IFCPipeAlphaOne) {
            ca.blendingEnabled = NO;
            ca.writeMask = MTLColorWriteMaskAlpha;
        } else if (i == IFCPipeBlurDown || i == IFCPipeBlurUp || i == IFCPipeMirrorCopy) {
            // Upstream clears the destination to transparent and draws with
            // premultiplied source-over, which leaves the source: no blending.
            ca.blendingEnabled = NO;
        } else if (i == IFCPipeBlurMask) {
            // blur.rs: gl.BlendFuncSeparate(ZERO, SRC_ALPHA, ZERO, SRC_ALPHA)
            ca.blendingEnabled = YES;
            ca.rgbBlendOperation = MTLBlendOperationAdd;
            ca.alphaBlendOperation = MTLBlendOperationAdd;
            ca.sourceRGBBlendFactor = MTLBlendFactorZero;
            ca.sourceAlphaBlendFactor = MTLBlendFactorZero;
            ca.destinationRGBBlendFactor = MTLBlendFactorSourceAlpha;
            ca.destinationAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        } else {
            // smithay: glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA) — premultiplied
            // source-over, on colour and alpha alike.
            ca.blendingEnabled = YES;
            ca.rgbBlendOperation = MTLBlendOperationAdd;
            ca.alphaBlendOperation = MTLBlendOperationAdd;
            ca.sourceRGBBlendFactor = MTLBlendFactorOne;
            ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
            ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        }
        _pipelines[i] = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!_pipelines[i]) {
            _error = [NSString stringWithFormat:@"compositor: pipeline %@ failed: %@", names[i], error.localizedDescription];
            NSLog(@"%@", _error);
        }
    }

    // smithay: GL_LINEAR minification and magnification, CLAMP_TO_EDGE, no mipmaps.
    _sampler = DWMetalLinearClampSampler(device);
    // blur.rs `backdrop_wrap_mode`: MIRRORED_REPEAT (the GLES 3 answer) on
    // every texture the blur samples past the edge of.
    _mirrorSampler = DWMetalLinearSampler(device, MTLSamplerAddressModeMirrorRepeat);
    return self;
}

- (id<MTLRenderPipelineState>)pipeline:(IFCPipe)pipe {
    return pipe < IFCPipeCount ? _pipelines[pipe] : nil;
}
@end

// MARK: - Deferred release

// Textures a command buffer still samples must outlive it. Everything the
// renderer stops using goes through here and is released when every command
// buffer encoded up to that moment has completed. One completion block is
// created per renderer and reused for every frame.
@interface IFCGraveyard : NSObject
- (void)began;
- (void)finished;
- (void)bury:(id)object;
@end

@implementation IFCGraveyard {
    os_unfair_lock _lock;
    uint64_t _begun, _completed;
    NSMutableArray *_dead;
    NSMutableArray<NSNumber *> *_deadline;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _dead = [NSMutableArray array];
    _deadline = [NSMutableArray array];
    return self;
}

- (void)began {
    os_unfair_lock_lock(&_lock);
    _begun++;
    os_unfair_lock_unlock(&_lock);
}

- (void)bury:(id)object {
    if (!object) return;
    os_unfair_lock_lock(&_lock);
    if (_completed < _begun) {
        [_dead addObject:object];
        [_deadline addObject:@(_begun)];
    }
    os_unfair_lock_unlock(&_lock);
    // When nothing is in flight the caller's reference was the last one.
}

- (void)finished {
    // Metal's completion queue need not drain an autorelease pool after each
    // callback. Bound the lifetime of the temporary release array (and any
    // autoreleases made by a retired CV wrapper) to this completed GPU fence,
    // rather than leaving capture-pool surfaces held until a later queue drain.
    @autoreleasepool {
        __attribute__((objc_precise_lifetime)) NSArray *released = nil;
        os_unfair_lock_lock(&_lock);
        _completed++;
        NSUInteger count = 0;
        while (count < _dead.count && _deadline[count].unsignedLongLongValue <= _completed) count++;
        if (count) {
            // Deadlines are appended in order. Remove the completed prefix once,
            // rather than shifting both arrays for every retired window texture.
            NSRange range = NSMakeRange(0, count);
            released = [_dead subarrayWithRange:range];
            [_dead removeObjectsInRange:range];
            [_deadline removeObjectsInRange:range];
        }
        os_unfair_lock_unlock(&_lock);
        released = nil;  // dropped outside the lock
    }
}
@end

// MARK: - Public value helpers

IFCompositorDecoration IFCompositorDecorationDefault(void) {
    IFCompositorDecoration d;
    memset(&d, 0, sizeof d);
    d.mode = IFCompositorDecorationModeClient;                       // default_mode: DecorationMode::Client
    d.borderWidth = 0;                                               // border_width: 0
    d.borderColor = IFCompositorColorMake(0x30, 0x30, 0x30, 0xFF);   // border_color
    d.borderColorFocused = IFCompositorColorMake(0x30, 0x30, 0x30, 0xFF);
    d.cornerRadius = 10;                                             // corner_radius: 10
    d.shadow = YES;                                                  // shadow: true
    d.shadowRadius = 14.0f;                                          // DecorationConfig::SHADOW_RADIUS
    d.shadowColor = IFCompositorColorMake(0x00, 0x00, 0x00, 0x66);   // DecorationConfig::SHADOW_COLOR
    d.opacity = 1.0;                                                 // opacity / opacity_focused: 1.0
    return d;
}

IFCompositorOutlineSettings IFCompositorOutlineSettingsDefault(void) {
    IFCompositorOutlineSettings o;
    memset(&o, 0, sizeof o);
    o.color = IFCompositorColorMake(0xFF, 0xFF, 0xFF, 0xFF);
    o.thickness = 1;
    o.opacity = 0.5;
    return o;
}

// canvas.rs `coverage`.
IFCompositorCoverage IFCompositorCoverageOfFrame(CGRect frame, CGRect usable) {
    const double NOISE = 1e-6;
    const double shortfall[4] = {
        frame.origin.x - usable.origin.x,
        frame.origin.y - usable.origin.y,
        (usable.origin.x + usable.size.width) - (frame.origin.x + frame.size.width),
        (usable.origin.y + usable.size.height) - (frame.origin.y + frame.size.height),
    };
    BOOL any = NO;
    for (int i = 0; i < 4; i++) {
        if (!(shortfall[i] <= NOISE)) return IFCompositorCoverageNone;  // NaN reads as no coverage
        if (shortfall[i] < -NOISE) any = YES;
    }
    return any ? IFCompositorCoverageOverhang : IFCompositorCoverageExact;
}

// chrome.rs `DrawnChrome::drawn`.
IFCompositorDecoration IFCompositorDecorationDrawn(IFCompositorDecoration c, BOOL fullscreen, IFCompositorCoverage coverage) {
    if (fullscreen) {
        // DrawnChrome::NONE — no bar, no border, square, no shadow; the surface
        // is passed through unclipped.
        c.mode = IFCompositorDecorationModeNone;
        c.borderWidth = 0;
        c.cornerRadius = 0;
        c.shadow = NO;
        return c;
    }
    switch (coverage) {
        case IFCompositorCoverageNone:
            break;
        case IFCompositorCoverageExact:
            c.cornerRadius = 0;
            c.shadow = NO;
            break;
        case IFCompositorCoverageOverhang:
            c.borderWidth = 0;
            c.cornerRadius = 0;
            c.shadow = NO;
            break;
    }
    return c;
}

// mod.rs `build_output_outline_elements` + canvas.rs `visible_canvas_rect`.
CGRect IFCompositorOutlineRect(double cameraX, double cameraY, double zoom,
                               double otherCameraX, double otherCameraY, CGSize otherSize, double otherZoom) {
    if (!(isfinite(otherZoom) && otherZoom > 0)) otherZoom = 1.0;
    // visible_canvas_rect(other_camera.to_i32_round(), other_size, other_zoom)
    long canvasX = IFCRound(otherCameraX), canvasY = IFCRound(otherCameraY);
    long canvasW = IFCCeil((double)IFCRound(otherSize.width) / otherZoom) + 2;
    long canvasH = IFCCeil((double)IFCRound(otherSize.height) / otherZoom) + 2;
    // ((other_canvas.loc.x as f64 - camera.x) * zoom) as i32 — truncation.
    long screenX = IFCTrunc(((double)canvasX - cameraX) * zoom);
    long screenY = IFCTrunc(((double)canvasY - cameraY) * zoom);
    long screenW = IFCTrunc((double)canvasW * zoom);
    long screenH = IFCTrunc((double)canvasH * zoom);
    return CGRectMake(screenX, screenY, screenW, screenH);
}

// state/suspended.rs `standin_body_rect`.
CGRect IFCompositorStandInBodyRect(CGRect windowRect, BOOL clientDecorated, NSInteger titleBarHeight) {
    if (!clientDecorated) return windowRect;
    double bar = (double)titleBarHeight;
    // let body_h = (rect.size.h - bar).max(1);
    double bodyH = fmax(windowRect.size.height - bar, 1.0);
    return CGRectMake(windowRect.origin.x, windowRect.origin.y + bar, windowRect.size.width, bodyH);
}

// config/types.rs `EffectsConfig::default`.
IFCompositorEffects IFCompositorEffectsDefault(void) {
    IFCompositorEffects e;
    memset(&e, 0, sizeof e);
    e.blurRadius = 2;
    e.blurStrength = 1.1;
    e.animateBlurFPS = 20;
    e.animationSpeed = 0.5;
    e.animationScale = 0.95;
    return e;
}

// config/parse_helpers.rs `unit_range_or_default`.
static double IFCUnitRangeOrDefault(double v, double fallback) {
    if (isnan(v) || v <= 0.0) return fallback;
    return fmin(v, 1.0);
}

// config/parse_helpers.rs `parse_effects_config`.
IFCompositorEffects IFCompositorEffectsSanitized(IFCompositorEffects e) {
    // non_negative(blur_strength): negative or NaN -> 0.
    if (!(e.blurStrength >= 0.0) || !isfinite(e.blurStrength)) e.blurStrength = 0.0;
    e.animateBlurFPS = MIN(e.animateBlurFPS, 144u);
    e.animationSpeed = IFCUnitRangeOrDefault(e.animationSpeed, 0.5);
    e.animationScale = IFCUnitRangeOrDefault(e.animationScale, 0.95);
    return e;
}

// window_animation_driver.rs `tick_window_animations_at`:
//   frame_factor = 1 - (1 - speed).powf(dt * 60);  progress += (1 - progress) * frame_factor
// so `1 - progress` is multiplied by (1 - speed)^(dt * 60) every tick, and
// after ticks adding up to `elapsed` it is (1 - speed)^(elapsed * 60).
double IFCompositorAnimationProgress(double elapsed, double animationSpeed) {
    if (!(elapsed > 0.0)) return 0.0;
    double speed = IFCUnitRangeOrDefault(animationSpeed, 0.5);
    return 1.0 - pow(1.0 - speed, elapsed * 60.0);
}

// closing.rs `ClosingSnapshot::is_done`, window_animation.rs `tick_entry`.
BOOL IFCompositorAnimationFinished(double progress) {
    return 1.0 - progress <= kIFCAnimationDoneEpsilon;
}

double IFCompositorAnimationDuration(double animationSpeed) {
    double speed = IFCUnitRangeOrDefault(animationSpeed, 0.5);
    if (speed >= 1.0) return 0.0;
    return log(kIFCAnimationDoneEpsilon) / (60.0 * log(1.0 - speed));
}

// closing.rs `fade_out_alpha`.
float IFCompositorCloseAlpha(double progress) {
    double p = fmin(fmax(progress, 0.0), 1.0);
    return (float)(1.0 - p * p);
}

// closing.rs `ClosingSnapshot::render_element` / `StandInFade::shrink_scale`.
double IFCompositorCloseScale(double progress, double amplitude) {
    return 1.0 - (1.0 - amplitude) * progress;
}

// window_animation.rs `open_alpha` (called with p clamped to 0..1).
float IFCompositorOpenAlpha(double progress) {
    double p = fmin(fmax(progress, 0.0), 1.0);
    return (float)(1.0 - (1.0 - p) * (1.0 - p));
}

// window_animation.rs `open_scale`.
double IFCompositorOpenScale(double progress, double amplitude) {
    return amplitude + (1.0 - amplitude) * progress;
}

// error_bar.rs `join_errors`: `m.split_whitespace().collect::<Vec<_>>().join(" ")`
// per message, the messages joined with SEPARATOR.
NSString *IFCompositorErrorBarText(NSArray<NSString *> *messages) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:messages.count];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSString *message in messages) {
        NSMutableArray<NSString *> *words = [NSMutableArray array];
        for (NSString *word in [message componentsSeparatedByCharactersInSet:whitespace]) {
            if (word.length) [words addObject:word];
        }
        [lines addObject:[words componentsJoinedByString:@" "]];
    }
    return [lines componentsJoinedByString:@"  \u2022  "];
}

// error_bar.rs: `ERROR_BAR_FONT_PX.ceil() as i32 + 2 * ERROR_BAR_PAD_Y`.
NSInteger IFCompositorErrorBarHeight(void) {
    return (NSInteger)(IFCTrunc((double)ceilf(kIFCErrorBarFontPx)) + 2 * kIFCErrorBarPadY);
}

// MARK: - Hashing (redraw gating, cache keys)

static inline void IFCMix(uint64_t *h, const void *bytes, size_t length) {
    const uint8_t *p = bytes;
    uint64_t v = *h;
    for (size_t i = 0; i < length; i++) {
        v ^= p[i];
        v *= 0x100000001b3ULL;  // FNV-1a
    }
    *h = v;
}

#define IFC_MIX(h, value)                         \
    do {                                          \
        __typeof__(value) ifc_v = (value);        \
        IFCMix((h), &ifc_v, sizeof ifc_v);        \
    } while (0)

// Every UTF-16 unit of the string, not -[NSString hash]: that one samples only
// the head, middle and tail of a string longer than 96 units, so a title that
// changed elsewhere would not redraw. Copies through the stack; no allocation.
static inline void IFCMixString(uint64_t *h, NSString *s) {
    NSUInteger length = s.length;
    uint64_t n = s ? (uint64_t)length : UINT64_MAX;
    IFCMix(h, &n, sizeof n);
    unichar units[128];
    for (NSUInteger at = 0; at < length;) {
        NSUInteger count = MIN(length - at, sizeof units / sizeof units[0]);
        [s getCharacters:units range:NSMakeRange(at, count)];
        IFCMix(h, units, count * sizeof units[0]);
        at += count;
    }
}

static uint64_t IFCStringFingerprint(NSString *s) {
    uint64_t h = 0xcbf29ce484222325ULL;
    IFCMixString(&h, s);
    return h;
}

static inline void IFCMixRect(uint64_t *h, CGRect r) {
    double v[4] = {r.origin.x, r.origin.y, r.size.width, r.size.height};
    IFCMix(h, v, sizeof v);
}

static inline void IFCMixColor(uint64_t *h, IFCompositorColor c) {
    uint8_t v[4] = {c.r, c.g, c.b, c.a};
    IFCMix(h, v, sizeof v);
}

// MARK: - Chrome style

@implementation IFCompositorChromeStyle

- (instancetype)init {
    if (!(self = [super init])) return nil;
    // config/types.rs `DecorationConfig::default()`
    _backgroundColor = IFCompositorColorMake(0x30, 0x30, 0x30, 0xFF);
    _foregroundColor = IFCompositorColorMake(0xFF, 0xFF, 0xFF, 0xFF);
    _cornerRadius = 10;
    _titleBarHeight = 25;
    _font = @"Adwaita Sans";
    _fontSize = 11;
    _fontWeight = IFCompositorFontWeightMedium;
    _titleAlign = IFCompositorTitleAlignCenter;
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    IFCompositorChromeStyle *c = [[IFCompositorChromeStyle allocWithZone:zone] init];
    c.backgroundColor = _backgroundColor;
    c.foregroundColor = _foregroundColor;
    c.cornerRadius = _cornerRadius;
    c.titleBarHeight = _titleBarHeight;
    c.font = _font;
    c.fontSize = _fontSize;
    c.fontWeight = _fontWeight;
    c.titleAlign = _titleAlign;
    return c;
}

- (void)setFont:(NSString *)font {
    _font = [font copy] ?: @"";
}

- (uint64_t)ifc_hash {
    uint64_t h = 0xcbf29ce484222325ULL;
    IFCMixColor(&h, _backgroundColor);
    IFCMixColor(&h, _foregroundColor);
    IFC_MIX(&h, (int64_t)_cornerRadius);
    IFC_MIX(&h, (int64_t)_titleBarHeight);
    IFCMixString(&h, _font);
    IFC_MIX(&h, (uint64_t)_fontSize);
    IFC_MIX(&h, (int64_t)_fontWeight);
    IFC_MIX(&h, (int64_t)_titleAlign);
    return h;
}
@end

// MARK: - Text (text.rs, on CoreText instead of cosmic-text)

// text.rs `weight_of`, as CoreText's -1..1 weight trait (the NSFontWeight
// values for CSS weights 100..900).
static CGFloat IFCWeightTrait(IFCompositorFontWeight weight) {
    switch (weight) {
        case IFCompositorFontWeightThin: return -0.8;
        case IFCompositorFontWeightExtraLight: return -0.6;
        case IFCompositorFontWeightLight: return -0.4;
        case IFCompositorFontWeightNormal: return 0.0;
        case IFCompositorFontWeightMedium: return 0.23;
        case IFCompositorFontWeightSemiBold: return 0.3;
        case IFCompositorFontWeightBold: return 0.4;
        case IFCompositorFontWeightExtraBold: return 0.56;
        case IFCompositorFontWeightBlack: return 0.62;
    }
    return 0.0;
}

// text.rs `family_of` + fontconfig's behaviour: the named family when it is
// installed, otherwise a generic sans (upstream: "otherwise a generic sans is
// substituted") — here the system UI font.
static CTFontRef IFCCreateFont(NSString *family, double px, IFCompositorFontWeight weight) CF_RETURNS_RETAINED {
    NSDictionary *traits = @{(__bridge id)kCTFontWeightTrait: @(IFCWeightTrait(weight))};
    NSString *name = family ?: @"";
    NSString *lower = name.lowercaseString;
    CTFontUIFontType generic = kCTFontUIFontSystem;
    if ([lower isEqualToString:@"monospace"]) {
        generic = kCTFontUIFontUserFixedPitch;
        name = @"";
    } else if ([lower isEqualToString:@"sans-serif"]) {
        name = @"";
    } else if ([lower isEqualToString:@"serif"]) {
        name = @"Times New Roman";
    } else if ([lower isEqualToString:@"cursive"]) {
        name = @"Apple Chancery";
    } else if ([lower isEqualToString:@"fantasy"]) {
        name = @"Papyrus";
    }
    CTFontRef font = NULL;
    if (name.length) {
        NSDictionary *attributes = @{(__bridge id)kCTFontFamilyNameAttribute: name, (__bridge id)kCTFontTraitsAttribute: traits};
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
        font = CTFontCreateWithFontDescriptor(descriptor, (CGFloat)px, NULL);
        CFRelease(descriptor);
        NSString *got = font ? CFBridgingRelease(CTFontCopyFamilyName(font)) : nil;
        if (!got || [got caseInsensitiveCompare:name] != NSOrderedSame) {
            // CoreText substituted another family: the request is not installed.
            if (font) CFRelease(font);
            font = NULL;
        }
    }
    if (!font) {
        CTFontRef base = CTFontCreateUIFontForLanguage(generic, (CGFloat)px, NULL);
        CTFontDescriptorRef baseDescriptor = CTFontCopyFontDescriptor(base);
        NSDictionary *attributes = @{(__bridge id)kCTFontTraitsAttribute: traits};
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(baseDescriptor, (__bridge CFDictionaryRef)attributes);
        font = CTFontCreateWithFontDescriptor(descriptor, (CGFloat)px, NULL);
        CFRelease(descriptor);
        CFRelease(baseDescriptor);
        CFRelease(base);
    }
    return font;
}

// text.rs `shape_line`: one unwrapped line.
static CTLineRef IFCCreateLine(NSString *text, CTFontRef font) CF_RETURNS_RETAINED {
    NSDictionary *attributes = @{(__bridge id)kCTFontAttributeName: (__bridge id)font,
                                 (__bridge id)kCTForegroundColorFromContextAttributeName: @YES};
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attributes];
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
}

// text.rs `measure`: pixel width, `ceil`ed; 0 for empty text.
static long IFCMeasure(NSString *text, CTFontRef font) {
    if (!text.length) return 0;
    CTLineRef line = IFCCreateLine(text, font);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return IFCCeil(width);
}

// text.rs `fit_text`: tail-truncate with an ellipsis; the largest prefix (in
// Unicode scalar values, Rust `char`s) whose `prefix + …` still fits.
static NSString *IFCFitText(NSString *text, CTFontRef font, long maxWidth, long *outWidth) {
    long full = IFCMeasure(text, font);
    if (full <= maxWidth) {
        *outWidth = full;
        return text;
    }
    NSString *ellipsis = @"…";
    if (IFCMeasure(ellipsis, font) > maxWidth) {
        *outWidth = 0;
        return @"";
    }
    NSData *utf32 = [text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    const uint8_t *scalars = utf32.bytes;
    NSUInteger count = utf32.length / 4;
    NSString * (^candidate)(NSUInteger) = ^NSString *(NSUInteger n) {
        NSString *prefix = [[NSString alloc] initWithBytes:scalars length:n * 4 encoding:NSUTF32LittleEndianStringEncoding] ?: @"";
        return [prefix stringByAppendingString:ellipsis];
    };
    NSUInteger lo = 0, hi = count;
    while (lo + 1 < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (IFCMeasure(candidate(mid), font) <= maxWidth) lo = mid;
        else hi = mid;
    }
    NSString *result = candidate(lo);
    *outWidth = IFCMeasure(result, font);
    return result;
}

// text.rs `rasterize_into`: alpha-composite `text` onto an RGBA8 buffer,
// vertically centred within `bufH` by the line's ascent and descent, with
// upstream's per-pixel blend. The glyph coverage comes from CoreText.
static void IFCRasterizeInto(uint8_t *pixels, long bufW, long bufH, NSString *text, CTFontRef font, float size,
                             IFCompositorColor color, long originX) {
    if (!text.length || bufW <= 0 || bufH <= 0) return;
    uint8_t *coverage = calloc((size_t)bufW * (size_t)bufH, 1);
    if (!coverage) return;
    CGContextRef context = CGBitmapContextCreate(coverage, (size_t)bufW, (size_t)bufH, 8, (size_t)bufW, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (!context) {
        free(coverage);
        return;
    }
    CGContextSetShouldAntialias(context, true);
    CGContextSetAllowsFontSmoothing(context, false);
    CGContextSetShouldSmoothFonts(context, false);
    CGContextSetAllowsFontSubpixelPositioning(context, true);
    CGContextSetShouldSubpixelPositionFonts(context, true);
    CGContextSetGrayFillColor(context, 1.0, 1.0);

    CTLineRef line = IFCCreateLine(text, font);
    CGFloat lineAscent = 0, lineDescent = 0;
    CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, NULL);
    // `(ascent, descent)` of the laid-out line, else `(size * 0.8, size * 0.2)`.
    float ascent = (float)lineAscent, descent = (float)lineDescent;
    if (!(ascent + descent > 0.0f)) {
        ascent = size * 0.8f;
        descent = size * 0.2f;
    }
    // baseline = ((buf_h as f32 - (ascent + descent)) / 2.0 + ascent).round() as i32
    long baseline = IFCRound((double)(((float)bufH - (ascent + descent)) / 2.0f + ascent));
    // Core Graphics counts rows from the bottom.
    CGContextSetTextPosition(context, (CGFloat)originX, (CGFloat)(bufH - baseline));
    CTLineDraw(line, context);
    CFRelease(line);
    CGContextRelease(context);

    double colorAlpha = (double)color.a / 255.0;
    for (long y = 0; y < bufH; y++) {
        for (long x = 0; x < bufW; x++) {
            uint8_t c = coverage[y * bufW + x];
            if (!c) continue;
            double a = (double)c / 255.0 * colorAlpha;
            if (a <= 0.0) continue;
            uint8_t *p = pixels + (y * bufW + x) * 4;
            double inv = 1.0 - a;
            p[0] = IFCU8((double)color.r * a + (double)p[0] * inv);
            p[1] = IFCU8((double)color.g * a + (double)p[1] * inv);
            p[2] = IFCU8((double)color.b * a + (double)p[2] * inv);
            p[3] = IFCU8((double)p[3] + a * 255.0 * (1.0 - (double)p[3] / 255.0));
        }
    }
    free(coverage);
}

// MARK: - Chrome rasterisers (decorations.rs)

// Points -> logical pixels (96 dpi).
static const float kIFCPtToPx = 4.0f / 3.0f;
// decorations.rs constants.
static const long kIFCCloseBtnRightPad = 8;
static const long kIFCTitleTextGap = 6;
static const double kIFCCloseBtnStroke = 0.05;
// suspended.rs constant.
static const long kIFCLabelSidePad = 24;

// decorations.rs `corner_alpha_at`: top-left and top-right arcs.
static double IFCCornerAlphaAt(long x, long y, long w, double r) {
    if (r <= 0.0) return 1.0;
    double px = (double)x + 0.5, py = (double)y + 0.5;
    if (px < r && py < r) {
        double dx = r - px, dy = r - py;
        double dist = sqrt(dx * dx + dy * dy);
        double t = fmin(fmax(dist - r + 0.5, 0.0), 1.0);
        return 1.0 - t * t * (3.0 - 2.0 * t);
    }
    double rightEdge = (double)w;
    if (px > rightEdge - r && py < r) {
        double dx = px - (rightEdge - r), dy = r - py;
        double dist = sqrt(dx * dx + dy * dy);
        double t = fmin(fmax(dist - r + 0.5, 0.0), 1.0);
        return 1.0 - t * t * (3.0 - 2.0 * t);
    }
    return 1.0;
}

// decorations.rs `body_corner_alpha_at`: bottom corners only.
static double IFCBodyCornerAlphaAt(long x, long y, long w, long h, double r) {
    if (r <= 0.0) return 1.0;
    double px = (double)x + 0.5, py = (double)y + 0.5;
    double cx, cy;
    if (px < r) cx = r;
    else if (px > (double)w - r) cx = (double)w - r;
    else return 1.0;
    if (py > (double)h - r) cy = (double)h - r;
    else return 1.0;
    double dx = px - cx, dy = py - cy;
    double dist = sqrt(dx * dx + dy * dy);
    double t = fmin(fmax(dist - r + 0.5, 0.0), 1.0);
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

// The straight-alpha blend `draw_line` and `draw_filled_circle` share.
static inline void IFCBlendPixel(uint8_t *pixels, long length, long index, IFCompositorColor color, double coverage) {
    // Upstream indexes with `as usize` and checks only `idx + 3 < len`: a
    // negative index wraps out of range, a column past the stride wraps into
    // the next row.
    if (index < 0 || index + 3 >= length) return;
    double a = fmin((double)color.a / 255.0 * coverage, 1.0);
    double inv = 1.0 - a;
    uint8_t *p = pixels + index;
    p[0] = IFCU8((double)color.r * a + (double)p[0] * inv);
    p[1] = IFCU8((double)color.g * a + (double)p[1] * inv);
    p[2] = IFCU8((double)color.b * a + (double)p[2] * inv);
    p[3] = IFCU8((double)p[3] + a * 255.0 * (1.0 - (double)p[3] / 255.0));
}

// decorations.rs `draw_line`.
static void IFCDrawLine(uint8_t *pixels, long length, long stride, long x0, long y0, long x1, long y1,
                        IFCompositorColor color, double lineWidth) {
    long pad = IFCCeil(lineWidth * 0.5 + 1.0);
    long minX = MIN(x0, x1) - pad, maxX = MAX(x0, x1) + pad;
    long minY = MIN(y0, y1) - pad, maxY = MAX(y0, y1) + pad;
    double dx = (double)(x1 - x0), dy = (double)(y1 - y0);
    double len = sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    for (long py = minY; py <= maxY; py++) {
        for (long px = minX; px <= maxX; px++) {
            double t = (((double)px - (double)x0) * dx + ((double)py - (double)y0) * dy) / (len * len);
            t = fmin(fmax(t, 0.0), 1.0);
            double projX = (double)x0 + t * dx, projY = (double)y0 + t * dy;
            double dist = sqrt(pow((double)px - projX, 2) + pow((double)py - projY, 2));
            double aa = fmin(fmax(1.0 - fmax(dist - lineWidth * 0.5, 0.0) / 0.8, 0.0), 1.0);
            if (aa > 0.0) IFCBlendPixel(pixels, length, (py * stride + px) * 4, color, aa);
        }
    }
}

// decorations.rs `draw_filled_circle`.
static void IFCDrawFilledCircle(uint8_t *pixels, long length, long stride, double cx, double cy, double r, IFCompositorColor color) {
    long height = length / (stride * 4);
    long xMin = IFCTrunc(fmax(floor(cx - r - 1.0), 0.0));
    long xMax = IFCTrunc(fmin(ceil(cx + r + 1.0), (double)stride));
    long yMin = IFCTrunc(fmax(floor(cy - r - 1.0), 0.0));
    long yMax = IFCTrunc(fmin(ceil(cy + r + 1.0), (double)height));
    for (long py = yMin; py < yMax; py++) {
        for (long px = xMin; px < xMax; px++) {
            double dx = (double)px + 0.5 - cx, dy = (double)py + 0.5 - cy;
            double dist = sqrt(dx * dx + dy * dy);
            double cov = fmin(fmax(r + 0.5 - dist, 0.0), 1.0);
            if (cov <= 0.0) continue;
            IFCBlendPixel(pixels, length, (py * stride + px) * 4, color, cov);
        }
    }
}

// decorations.rs `render_title_bar`. Returns RGBA8 (`Abgr8888`) bytes of
// `*outW` x `*outH` pixels; the buffer scale is `scale`.
static NSMutableData *IFCRenderTitleBar(long width, long scale, NSString *title, BOOL pinned, long cornerRadius,
                                        IFCompositorChromeStyle *style, long *outW, long *outH) {
    long s = MAX(scale, 1L);
    long h = (long)style.titleBarHeight * s;
    long w = MAX(width, 1L) * s;
    if (h <= 0 || w <= 0 || (NSUInteger)w > kIFCMaxTextureSide || (NSUInteger)h > kIFCMaxTextureSide) return nil;
    IFCompositorColor bg = style.backgroundColor, fg = style.foregroundColor;
    double cr = fmin(fmin((double)(cornerRadius * s), (double)w / 2.0), (double)h);

    long length = w * h * 4;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    uint8_t *pixels = data.mutableBytes;

    // Fill with the background colour, masking the top corners.
    for (long y = 0; y < h; y++) {
        for (long x = 0; x < w; x++) {
            uint8_t *p = pixels + (y * w + x) * 4;
            double cornerAlpha = IFCCornerAlphaAt(x, y, w, cr);
            p[0] = IFCU8((double)bg.r * cornerAlpha);
            p[1] = IFCU8((double)bg.g * cornerAlpha);
            p[2] = IFCU8((double)bg.b * cornerAlpha);
            p[3] = IFCU8((double)bg.a * cornerAlpha);
        }
    }

    // The close button: two crossed lines, inset from the right edge.
    long btnSize = h;
    long btnX = w - btnSize - kIFCCloseBtnRightPad * s;
    long margin = IFCRound((double)btnSize * 0.37);
    long x0 = btnX + margin, y0 = margin;
    long x1 = btnX + btnSize - margin, y1 = h - margin;
    double lineW = (double)btnSize * kIFCCloseBtnStroke;
    IFCDrawLine(pixels, length, w, x0, y0, x1, y1, fg, lineW);
    IFCDrawLine(pixels, length, w, x0, y1, x1, y0, fg, lineW);

    long baseLeftPad = kIFCCloseBtnRightPad * s + margin;
    long leftPad = baseLeftPad;
    if (pinned) {
        double r = fmax(round((double)h * 0.16), 2.0);
        double cx = (double)baseLeftPad + r, cy = (double)h / 2.0;
        IFCDrawFilledCircle(pixels, length, w, cx, cy, r, fg);
        leftPad = baseLeftPad + IFCRound(2.0 * r) + kIFCTitleTextGap * s;
    }
    long rightLimit = btnX - kIFCTitleTextGap * s;
    long available = rightLimit - leftPad;
    if (available > 0 && title.length) {
        float fontPx = fmaxf((float)style.fontSize * kIFCPtToPx * (float)s, 1.0f);
        CTFontRef font = IFCCreateFont(style.font, (double)fontPx, style.fontWeight);
        long textW = 0;
        NSString *text = IFCFitText(title, font, available, &textW);
        long originX = leftPad;
        if (style.titleAlign == IFCompositorTitleAlignCenter) {
            // ((w - text_w) / 2).min(right_limit - text_w).max(left_pad)
            originX = MAX(MIN((w - textW) / 2, rightLimit - textW), leftPad);
        }
        IFCRasterizeInto(pixels, w, h, text, font, fontPx, fg, originX);
        CFRelease(font);
    }
    *outW = w;
    *outH = h;
    return data;
}

// decorations.rs `render_body_fill`: premultiplied, bottom corners rounded to
// the configured radius.
static NSMutableData *IFCRenderBodyFill(long width, long height, long scale, IFCompositorChromeStyle *style, long *outW, long *outH) {
    long s = MAX(scale, 1L);
    long w = MAX(width, 1L) * s, h = MAX(height, 1L) * s;
    if ((NSUInteger)w > kIFCMaxTextureSide || (NSUInteger)h > kIFCMaxTextureSide) return nil;
    IFCompositorColor bg = style.backgroundColor;
    double ba = (double)bg.a / 255.0;
    double cr = fmin(fmin((double)((long)style.cornerRadius * s), (double)w / 2.0), (double)h / 2.0);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(w * h * 4)];
    uint8_t *pixels = data.mutableBytes;
    for (long y = 0; y < h; y++) {
        for (long x = 0; x < w; x++) {
            uint8_t *p = pixels + (y * w + x) * 4;
            double a = IFCBodyCornerAlphaAt(x, y, w, h, cr) * ba;
            p[0] = IFCU8((double)bg.r * a);
            p[1] = IFCU8((double)bg.g * a);
            p[2] = IFCU8((double)bg.b * a);
            p[3] = IFCU8(255.0 * a);
        }
    }
    *outW = w;
    *outH = h;
    return data;
}

// suspended.rs `ensure_label`: the label buffer and its body-local rectangle.
// Returns nil (and a zero rect) when nothing fits.
static NSMutableData *IFCLabel(NSString *text, long bodyW, long bodyH, long scale, IFCompositorChromeStyle *style,
                                     long *outW, long *outH, IFCRectI *labelRect, BOOL rasterize) {
    *labelRect = IFCRectIMake(0, 0, 0, 0);
    long s = MAX(scale, 1L);
    float fontPx = fmaxf((float)style.fontSize * kIFCPtToPx * (float)s, 1.0f);
    long avail = MAX(bodyW - 2 * kIFCLabelSidePad, 1L) * s;
    CTFontRef font = IFCCreateFont(style.font, (double)fontPx, style.fontWeight);
    long textW = 0;
    NSString *fitted = IFCFitText(text ?: @"", font, avail, &textW);
    if (!fitted.length || textW <= 0) {
        CFRelease(font);
        return nil;
    }
    long bufW = textW;
    long bufH = IFCCeil((double)(fontPx * 1.5f));
    if (bufH <= 0 || (NSUInteger)bufW > kIFCMaxTextureSide || (NSUInteger)bufH > kIFCMaxTextureSide) {
        CFRelease(font);
        return nil;
    }
    NSMutableData *data = rasterize ? [NSMutableData dataWithLength:(NSUInteger)(bufW * bufH * 4)] : nil;
    if (rasterize) IFCRasterizeInto(data.mutableBytes, bufW, bufH, fitted, font, fontPx, style.foregroundColor, 0);
    CFRelease(font);
    // Centre within the bar+body footprint: shift up by half the bar.
    long lw = MAX(bufW / s, 1L), lh = MAX(bufH / s, 1L);
    *labelRect = IFCRectIMake((bodyW - lw) / 2, (bodyH - (long)style.titleBarHeight - lh) / 2, lw, lh);
    *outW = bufW;
    *outH = bufH;
    return data;
}

static NSMutableData *IFCRenderLabel(NSString *text, long bodyW, long bodyH, long scale, IFCompositorChromeStyle *style,
                                     long *outW, long *outH, IFCRectI *labelRect) {
    return IFCLabel(text,bodyW,bodyH,scale,style,outW,outH,labelRect,YES);
}
CGRect IFCompositorStandInLabelRect(NSString *name, BOOL launching, CGSize body, NSInteger scale, IFCompositorChromeStyle *style) {
    if(!style||!isfinite(body.width)||!isfinite(body.height)||body.width<=0||body.height<=0)return CGRectNull;
    long w=0,h=0;IFCRectI r;
    NSString *text=launching?[name stringByAppendingString:@" launching\u2026"]:name;
    IFCLabel(text,IFCRound(body.width),IFCRound(body.height),MAX(scale,1),style,&w,&h,&r,NO);
    return r.w>0&&r.h>0?CGRectMake(r.x,r.y,r.w,r.h):CGRectNull;
}

// MARK: - Element

@implementation IFCompositorElement {
    uint64_t _titleFingerprint, _appNameFingerprint;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _decoration = IFCompositorDecorationDefault();
    _contentRect = CGRectNull;
    _transform = (IFCompositorTransform){0, 0, 0, 0, 1, 1};
    _lifecycleStartTime = NAN;
    _titleFingerprint = _appNameFingerprint = IFCStringFingerprint(nil);
    return self;
}

- (void)dealloc {
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
}

- (void)setPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == _pixelBuffer) return;
    if (pixelBuffer) CVPixelBufferRetain(pixelBuffer);
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
    _pixelBuffer = pixelBuffer;
}

// These properties own immutable copies, so every UTF-16 unit needs hashing
// only when the text changes. Redraw and backdrop keys reuse the scalar on
// pixel/camera frames; NSString's sampled -hash would miss long-title edits.
- (void)setTitle:(NSString *)title {
    if (_title == title || (title && [_title isEqualToString:title])) return;
    _title = [title copy];
    _titleFingerprint = IFCStringFingerprint(_title);
}

- (void)setAppName:(NSString *)appName {
    if (_appName == appName || (appName && [_appName isEqualToString:appName])) return;
    _appName = [appName copy];
    _appNameFingerprint = IFCStringFingerprint(_appName);
}

// The identity of the content's pixels: the buffer object and its surface's
// change seed, or the texture object; plus the host's own generation counter.
- (void)ifc_mixContentIdentity:(uint64_t *)h {
    IFC_MIX(h, (uintptr_t)_pixelBuffer);
    if (_pixelBuffer) {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(_pixelBuffer);
        IFC_MIX(h, surface ? IOSurfaceGetID(surface) : 0u);
        IFC_MIX(h, surface ? IOSurfaceGetSeed(surface) : 0u);
    }
    IFC_MIX(h, (uintptr_t)(__bridge void *)_texture);
    IFC_MIX(h, _contentGeneration);
}

// Everything that decides how the element is drawn. With `content` NO the
// identity of the content's pixels is left out (whether there is content at
// all stays in): what a blurred window's own frost is keyed on, since the
// frost does not show the window's content, only its shape.
- (void)ifc_mix:(uint64_t *)h content:(BOOL)content {
    IFC_MIX(h, _identifier);
    IFC_MIX(h, (int64_t)_kind);
    IFCMixRect(h, _rect);
    IFC_MIX(h, (int64_t)_space);
    IFC_MIX(h, (int64_t)_layer);
    IFC_MIX(h, (uint8_t)_hasClipRect);
    if (_hasClipRect) IFCMixRect(h, _clipRect);
    IFC_MIX(h, (uint8_t)_focused);
    IFC_MIX(h, (int64_t)_decoration.mode);
    IFC_MIX(h, _decoration.borderWidth);
    IFCMixColor(h, _decoration.borderColor);
    IFCMixColor(h, _decoration.borderColorFocused);
    IFC_MIX(h, _decoration.cornerRadius);
    IFC_MIX(h, (uint8_t)_decoration.shadow);
    IFC_MIX(h, _decoration.shadowRadius);
    IFCMixColor(h, _decoration.shadowColor);
    IFC_MIX(h, _decoration.opacity);
    if (content) {
        [self ifc_mixContentIdentity:h];
    } else {
        IFC_MIX(h, (uint8_t)(_pixelBuffer != NULL));
        IFC_MIX(h, (uint8_t)(_texture != nil));
    }
    IFCMixRect(h, _contentRect);
    IFC_MIX(h, (uint8_t)_contentOpaque);
    IFC_MIX(h, _titleFingerprint);
    IFC_MIX(h, _appNameFingerprint);
    IFC_MIX(h, (uint8_t)_launching);
    IFC_MIX(h, (uint8_t)_showsPinnedIndicator);
    IFC_MIX(h, (uint8_t)_hasTransform);
    if (_hasTransform) IFCMix(h, &_transform, sizeof _transform);
    IFC_MIX(h, (uint8_t)_blur);
    // The lifecycle's own progress is mixed by the frame: it depends on its time.
    IFC_MIX(h, (int64_t)_lifecycle);
}
@end

// One element's lifecycle animation resolved for one frame.
typedef struct {
    IFCompositorLifecycle kind;  // None when the element has none, or when it is over (see `finished`)
    double progress;             // 0..1
    BOOL finished;               // the animation has run out (upstream would have dropped it)
    BOOL timed;                  // derived from `lifecycleStartTime`
} IFCLife;

static IFCLife IFCResolveLife(IFCompositorElement *element, double time, IFCompositorEffects effects) {
    IFCLife life = {element.lifecycle, 0.0, NO, NO};
    if (life.kind != IFCompositorLifecycleOpening && life.kind != IFCompositorLifecycleClosing &&
        life.kind != IFCompositorLifecycleClosingAlphaOnly) {
        life.kind = IFCompositorLifecycleNone;
        return life;
    }
    double start = element.lifecycleStartTime;
    double p;
    if (isnan(start)) {
        p = element.lifecycleProgress;
    } else {
        life.timed = YES;
        p = IFCompositorAnimationProgress(time - start, effects.animationSpeed);
    }
    if (isnan(p)) p = 0.0;
    life.progress = fmin(fmax(p, 0.0), 1.0);
    life.finished = IFCompositorAnimationFinished(life.progress);
    return life;
}

// MARK: - Frame

@interface IFCompositorFrame ()
- (uint64_t)ifc_fingerprint;
- (const CGRect *)ifc_outlineRects;
- (BOOL)ifc_backgroundAnimates;
@end

@implementation IFCompositorFrame {
    CGRect *_outlineRects;
    NSUInteger _outlineCount, _outlineCapacity;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _scale = 1.0;
    _zoom = 1.0;
    _chrome = [IFCompositorChromeStyle new];
    _placeholderColor = _chrome.backgroundColor;
    _elements = [NSMutableArray array];
    _outline = IFCompositorOutlineSettingsDefault();
    _effects = IFCompositorEffectsDefault();
    return self;
}

- (void)dealloc {
    free(_outlineRects);
}

- (void)setChrome:(IFCompositorChromeStyle *)chrome {
    _chrome = [chrome copy] ?: [IFCompositorChromeStyle new];
}

- (void)setOutlineRects:(const CGRect *)rects count:(NSUInteger)count {
    if (!rects) count = 0;
    if (count > _outlineCapacity) {
        CGRect *grown = realloc(_outlineRects, count * sizeof(CGRect));
        if (!grown) return;
        _outlineRects = grown;
        _outlineCapacity = count;
    }
    if (count) memcpy(_outlineRects, rects, count * sizeof(CGRect));
    _outlineCount = count;
}

- (NSUInteger)outlineRectCount {
    return _outlineCount;
}

- (const CGRect *)ifc_outlineRects {
    return _outlineRects;
}

// The background draws and moves on its own (upstream's animated shader).
- (BOOL)ifc_backgroundAnimates {
    return _background.isAnimated;
}

- (double)lifecycleProgressOfElement:(IFCompositorElement *)element {
    if (!element) return 0.0;
    return IFCResolveLife(element, _time, IFCompositorEffectsSanitized(_effects)).progress;
}

- (BOOL)lifecycleFinishedForElement:(IFCompositorElement *)element {
    if (!element) return YES;
    IFCLife life = IFCResolveLife(element, _time, IFCompositorEffectsSanitized(_effects));
    return life.kind == IFCompositorLifecycleNone || life.finished;
}

// An open / close animation that runs on the frame's clock is still running.
- (BOOL)ifc_lifecycleRuns {
    IFCompositorEffects effects = IFCompositorEffectsSanitized(_effects);
    for (IFCompositorElement *element in _elements) {
        if (element.lifecycle == IFCompositorLifecycleNone) continue;
        IFCLife life = IFCResolveLife(element, _time, effects);
        if (life.kind != IFCompositorLifecycleNone && life.timed && !life.finished) return YES;
    }
    return NO;
}

- (BOOL)needsContinuousRedraw {
    return [self ifc_backgroundAnimates] || [self ifc_lifecycleRuns];
}

// Everything that decides the picture except `time`. (`time` enters only
// through the progress of an animation that runs on it: the fingerprint then
// changes on every tick until the animation is over, and not after.)
- (uint64_t)ifc_fingerprint {
    uint64_t h = 0xcbf29ce484222325ULL;
    IFC_MIX(&h, _size.width);
    IFC_MIX(&h, _size.height);
    IFC_MIX(&h, _scale);
    IFC_MIX(&h, _cameraX);
    IFC_MIX(&h, _cameraY);
    IFC_MIX(&h, _zoom);
    IFC_MIX(&h, (uintptr_t)(__bridge void *)_background);
    IFC_MIX(&h, (int64_t)_clear);
    IFC_MIX(&h, [_chrome ifc_hash]);
    IFC_MIX(&h, (int64_t)_decorationScale);
    IFCMixColor(&h, _placeholderColor);
    IFCMixColor(&h, _outline.color);
    IFC_MIX(&h, _outline.thickness);
    IFC_MIX(&h, _outline.opacity);
    IFC_MIX(&h, (uint64_t)_outlineCount);
    for (NSUInteger i = 0; i < _outlineCount; i++) IFCMixRect(&h, _outlineRects[i]);
    IFCompositorEffects effects = IFCompositorEffectsSanitized(_effects);
    IFC_MIX(&h, effects.blurRadius);
    IFC_MIX(&h, effects.blurStrength);
    IFC_MIX(&h, effects.animateBlurFPS);
    IFC_MIX(&h, effects.animationSpeed);
    IFC_MIX(&h, effects.animationScale);
    IFC_MIX(&h, (uint64_t)_errorMessages.count);
    for (NSString *message in _errorMessages) IFCMixString(&h, message);
    IFC_MIX(&h, (uint64_t)_elements.count);
    for (IFCompositorElement *element in _elements) {
        [element ifc_mix:&h content:YES];
        if (element.lifecycle != IFCompositorLifecycleNone) {
            IFCLife life = IFCResolveLife(element, _time, effects);
            IFC_MIX(&h, (uint8_t)life.finished);
            IFC_MIX(&h, life.finished ? 1.0 : life.progress);
        }
    }
    return h;
}
@end

// Integer output size, as upstream's logical output size is integral.
static void IFCPixelSize(IFCompositorFrame *f, long *logicalW, long *logicalH, NSUInteger *pxW, NSUInteger *pxH) {
    DWMetalPixelSize(f.size.width, f.size.height, f.scale, logicalW, logicalH, pxW, pxH);
}

// MARK: - Per-element cache entry

// A CVMetalTexture must not outlive the cache it came from (CoreVideo tells
// the cache when a texture's backing is released), and retired textures are
// released whenever the GPU is done with them, possibly after the renderer is
// gone. Everything that holds a CVMetalTexture therefore also holds this.
@interface IFCTextureCache : NSObject {
  @public
    CVMetalTextureCacheRef ref;
}
@end

@implementation IFCTextureCache
- (void)dealloc {
    if (ref) CFRelease(ref);
}
@end

@interface IFCEntry : NSObject {
  @public
    uint64_t lastUsed;

    // Live content: the wrapper for the buffer currently shown, and nothing else
    // (a ScreenCaptureKit pool surface must not be pinned once it is replaced).
    CVPixelBufferRef buffer;
    CVMetalTextureRef cvTexture;
    IFCTextureCache *cache;  // released after cvTexture: ARC destroys ivars once -dealloc has returned
    id<MTLTexture> contentTexture;

    // Title bar (decorations.rs `WindowDecoration`).
    id<MTLTexture> barTexture;
    BOOL barValid;
    long barWidth, barScale, barRadius;
    BOOL barPinned;
    NSString *barTitle;
    uint64_t barStyle;

    // Stand-in body (suspended.rs `ensure_body`).
    id<MTLTexture> bodyTexture;
    BOOL bodyValid;
    long bodyW, bodyH, bodyScale;
    uint64_t bodyStyle;

    // Stand-in label (suspended.rs `ensure_label`).
    id<MTLTexture> labelTexture;
    BOOL labelValid;
    long labelBodyW, labelBodyH, labelScale;
    BOOL labelLaunching;
    NSString *labelText;
    uint64_t labelStyle;
    long labelBufW, labelBufH;
    IFCRectI labelRect;

    // Frost (blur.rs `BlurCache`): the blurred backdrop of a blurred window,
    // masked to the window's shape.
    id<MTLTexture> frostTexture;   // allocated at a quantised extent; the live extent sits at its top-left
    long frostAllocW, frostAllocH; // `BlurCache::alloc`
    long frostW, frostH;           // the live extent: the size of `frostRect`
    IFCRectI frostRect;            // the screen rectangle the frost was computed for, physical pixels
    uint64_t frostKey;             // what the frost was computed from (`last_backdrop_hash`, `last_view`, geometry)
    BOOL frostInit;                // the countdowns below were armed (`BlurCache::new`)
    BOOL frostValid;               // `frostKey` describes what `frostTexture` holds, or that it holds nothing
    BOOL frostZeroed;              // nothing lies beneath the window: no frost is drawn (`BlurCache::zeroed`)
    uint8_t frostForceFrames;      // `force_dirty_frames`
    uint8_t frostWarmup;           // `mask_warmup_commits`
    BOOL frostHasContentId;
    uint64_t frostContentId;       // `mask_commits`: the content the current mask was drawn from
    uint64_t frostSeen;            // the encode in which this frost was brought up to date
    id<MTLTexture> maskTexture;    // `BlurCache::mask`: the window's own alpha shape, same allocation as the frost
    // `BlurCache::pads`: the padded ping-pong pair the backdrop is captured
    // into and blurred in. Exactly the padded extent, never quantised; freed
    // once the window has gone kIFCBlurKeepFrames encodes without recomputing.
    id<MTLTexture> padA, padB;
    long padW, padH;
    unsigned padsIdle;             // `pads_idle_frames`
}
@end

@implementation IFCEntry
- (void)dealloc {
    if (cvTexture) CFRelease(cvTexture);
    if (buffer) CVPixelBufferRelease(buffer);
}
@end

// A replaced content wrapper on its way to the graveyard.
@interface IFCRetiredContent : NSObject {
  @public
    CVPixelBufferRef buffer;
    CVMetalTextureRef cvTexture;
    IFCTextureCache *cache;
    id<MTLTexture> texture;
}
@end

@implementation IFCRetiredContent
- (void)dealloc {
    if (cvTexture) CFRelease(cvTexture);
    if (buffer) CVPixelBufferRelease(buffer);
}
@end

// MARK: - Resolved geometry

// One element in upstream's terms: `render_loc` and the window's logical size
// before zoom, and the zoom its elements are rescaled by.
typedef struct {
    IFCRectD r;
    double zoom;
} IFCGeom;

// One element as one encode draws it: its geometry, its clip in output
// pixels, and what its lifecycle animation makes of it.
typedef struct {
    __unsafe_unretained IFCompositorElement *element;
    IFCGeom g;
    IFCRectI scissor;             // the element's clip (or the whole output), output pixels
    BOOL hasXform;                // upstream `WindowRenderAnimation`
    IFCompositorTransform xform;
    float lifeAlpha;              // open / close fade; 1 when there is none
    double progress;              // a snapshot's close progress
    BOOL alphaOnly;               // a snapshot that fades in place
} IFCItem;

// What every pass of one encode shares.
typedef struct {
    double s;                     // output scale
    double frameZoom;
    long viewportW, viewportH;    // output size, logical
    long outW, outH;              // output size, pixels
    long decorationScale;
    uint64_t styleHash;
    IFCompositorEffects effects;  // sanitized
    uint64_t backgroundGeneration;  // the chunks a cached background draws this frame from; 0 without a cache
} IFCFrameCtx;

typedef NS_OPTIONS(NSUInteger, IFCChromePart) {
    IFCChromeShadow = 1 << 0,
    IFCChromeBorder = 1 << 1,
};

// blur.rs `quantized_extent`: grow at once, give a step back only half a step
// past the point where it would be taken again.
static long IFCQuantizedExtent(long live, long current) {
    long step = kIFCBlurCacheStep;
    long wanted = ((MAX(live, 1L) + step - 1) / step) * step;
    if (wanted > current) return wanted;
    if (live <= current - step - step / 2) return wanted;
    return current;
}

// blur.rs `blur_pad`: `((offset * (1u32 << (passes + 1)) as f32).ceil() as i32).clamp(16, 256)`.
static long IFCBlurPad(float offset, uint32_t passes) {
    long reach = IFCTrunc((double)ceilf(offset * (float)(1u << (passes + 1))));
    return MIN(MAX(reach, 16L), 256L);
}

// mod.rs `compose_frame`, the `wants_blur` block: the rectangle a window's
// frost covers, in physical pixels — the content (and the title bar above it)
// truncated and rounded up in logical pixels after the zoom, then
// `painted_rect` at the output scale. Not the content's own rectangle
// (`corner_round_rect`): the two can differ by a pixel, as upstream's do.
static IFCRectI IFCBlurScreenRect(IFCGeom g, BOOL hasSSD, long titleBarHeight, double s) {
    double zoom = g.zoom;
    IFCRectD logical;
    if (hasSSD) {
        // screen_loc = ((render_loc.x * zoom) as i32, (render_loc.y * zoom) as i32),
        // moved up by (title_bar_height as f64 * zoom) as i32
        logical.x = (double)IFCTrunc(g.r.x * zoom);
        logical.y = (double)(IFCTrunc(g.r.y * zoom) - IFCTrunc((double)titleBarHeight * zoom));
        logical.w = (double)IFCCeil(g.r.w * zoom);
        logical.h = (double)IFCCeil((g.r.h + (double)titleBarHeight) * zoom);
    } else {
        logical.x = (double)IFCTrunc(g.r.x * zoom);
        logical.y = (double)IFCTrunc(g.r.y * zoom);
        logical.w = (double)IFCCeil(g.r.w * zoom);
        logical.h = (double)IFCCeil(g.r.h * zoom);
    }
    return IFCPaintedRect(logical, s);
}

// shaders.rs `outer_corner_radius`.
static inline float IFCOuterCornerRadius(float inner, float borderWidth) {
    return inner > 0.0f ? inner + borderWidth : 0.0f;
}

// shaders.rs `border_area_for` + `border_uniforms_precise` + the element
// geometry `RescaleRenderElement<PixelShaderElement>` reports.
static BOOL IFCBorderGeometry(IFCRectD inner, long borderWidthLogical, float innerRadiusLogical, double s, double zoom,
                              IFCRectI *dst, IFCRectI *hole, IFCUniforms *u) {
    if (borderWidthLogical <= 0) return NO;
    double totalScale = s * zoom;
    // border_area_for(inner_logical, border_width_logical, output_scale.x * zoom)
    long innerX = IFCRound(inner.x), innerY = IFCRound(inner.y);
    long innerW = IFCRound(inner.w), innerH = IFCRound(inner.h);
    float borderWPhys = (float)fmax(round((double)borderWidthLogical * totalScale), 1.0);
    long pad = IFCCeil(((double)borderWPhys + 1.0) / totalScale);
    IFCRectI area = IFCRectIMake(innerX - pad, innerY - pad, innerW + 2 * pad, innerH + 2 * pad);

    // push_border_element
    IFCRectI innerPreZoom = IFCPaintedRect(inner, s);
    float innerRPhys = innerRadiusLogical * (float)s * (float)zoom;

    // border_uniforms_precise
    IFCRectI innerPost = IFCCornerRound(innerPreZoom, zoom);
    IFCRectI borderPre = IFCScaleRound(area, s);
    IFCRectI borderPost = IFCScaleRound(borderPre, zoom);
    double physW = (double)MAX(borderPost.w, 1L), physH = (double)MAX(borderPost.h, 1L);
    double logicalW = (double)MAX(area.w, 1L), logicalH = (double)MAX(area.h, 1L);
    double px = physW / logicalW, py = physH / logicalH;
    double ix = (double)(innerPost.x - borderPost.x) / px;
    double iy = (double)(innerPost.y - borderPost.y) / py;
    double iw = (double)innerPost.w / px;
    double ih = (double)innerPost.h / py;
    double innerRLogical = (double)innerRPhys / px;
    double borderWLogical = (double)borderWPhys / px;

    u->rect = simd_make_float4((float)ix, (float)iy, (float)iw, (float)ih);
    u->inner_radius = (float)innerRLogical;
    u->border_width = (float)borderWLogical;
    u->outer_radius = IFCOuterCornerRadius((float)innerRLogical, (float)borderWLogical);
    u->aa_scale = (float)px;
    // PixelShaderElement: `size` is the element's logical area.
    u->size = simd_make_float2((float)area.w, (float)area.h);
    *dst = borderPost;
    // Not upstream: where the stroke's coverage is exactly 0. `a_inner` is 0
    // from half a pixel inside the inner rounded rect; a pixel that is a whole
    // pixel inside its straight edges and clear of its corner squares is there.
    long inset = IFCCeil((double)innerRPhys) + 1;
    *hole = IFCRectIMake(innerPost.x + inset, innerPost.y + inset, innerPost.w - 2 * inset, innerPost.h - 2 * inset);
    return YES;
}

// shaders.rs `shadow_area_for` + `shadow_uniforms_precise`.
static void IFCShadowGeometry(IFCRectD body, float cornerRadiusLogical, float shadowRadius, double s, double zoom,
                              IFCRectI *dst, IFCRectI *hole, IFCUniforms *u) {
    // shadow_area_for
    long pad = IFCCeil((double)ceilf(shadowRadius));
    long bodyX = IFCRound(body.x), bodyY = IFCRound(body.y);
    long bodyW = IFCRound(body.w), bodyH = IFCRound(body.h);
    IFCRectI area = IFCRectIMake(bodyX - pad, bodyY - pad, bodyW + 2 * pad, bodyH + 2 * pad);

    // push_shadow_element
    IFCRectI bodyPreZoom = IFCPaintedRect(body, s);
    float cornerRPhys = cornerRadiusLogical * (float)s * (float)zoom;

    // shadow_uniforms_precise
    IFCRectI bodyPost = IFCCornerRound(bodyPreZoom, zoom);
    IFCRectI shadowPre = IFCScaleRound(area, s);
    IFCRectI shadowPost = IFCScaleRound(shadowPre, zoom);
    double physW = (double)MAX(shadowPost.w, 1L), physH = (double)MAX(shadowPost.h, 1L);
    double logicalW = (double)MAX(area.w, 1L), logicalH = (double)MAX(area.h, 1L);
    double px = physW / logicalW, py = physH / logicalH;
    double holeX = (double)(bodyPost.x - shadowPost.x) / px;
    double holeY = (double)(bodyPost.y - shadowPost.y) / py;
    double holeW = (double)bodyPost.w / px;
    double holeH = (double)bodyPost.h / py;
    double cornerLogical = (double)cornerRPhys / px;

    u->rect = simd_make_float4((float)holeX, (float)holeY, (float)holeW, (float)holeH);
    u->radius = shadowRadius;
    u->shadow_corner = (float)cornerLogical;
    u->size = simd_make_float2((float)area.w, (float)area.h);
    *dst = shadowPost;
    // Not upstream: where `outside` (step(0, dist)) is exactly 0 — inside the
    // body's rounded rect, here taken a whole pixel in from its straight edges
    // and clear of its corner squares.
    long inset = IFCCeil((double)cornerRPhys) + 1;
    *hole = IFCRectIMake(bodyPost.x + inset, bodyPost.y + inset, bodyPost.w - 2 * inset, bodyPost.h - 2 * inset);
}

// mod.rs `push_corner_clipped_elements` + elements.rs
// `RoundedCornerElement::compute_uniforms`. `element` is the surface element's
// pre-zoom physical rectangle, `geometry` the window geometry in pre-zoom
// logical coordinates, `source` the sampled sub-rect of a `bufW` x `bufH` buffer.
static void IFCCornerClipUniforms(IFCRectI element, IFCRectD geometry, const float radii[4], double s, double zoom,
                                  double bufW, double bufH, CGRect source, IFCUniforms *u) {
    // push_corner_clipped_elements
    float aaScale = (float)(s * zoom);
    float maxR = fmaxf((float)fmin(geometry.w, geometry.h) * 0.5f, 0.0f);
    float clamped[4];
    for (int i = 0; i < 4; i++) clamped[i] = fminf(fmaxf(radii[i], 0.0f), maxR);

    // compute_uniforms
    IFCRectI geo = IFCPaintedRect(geometry, s);
    float elemX = (float)element.x, elemY = (float)element.y;
    float elemW = (float)MAX(element.w, 1L), elemH = (float)MAX(element.h, 1L);
    float geoX = (float)geo.x, geoY = (float)geo.y;
    float geoW = (float)MAX(geo.w, 1L), geoH = (float)MAX(geo.h, 1L);
    float bufWf = (float)fmax(bufW, 1.0), bufHf = (float)fmax(bufH, 1.0);
    float srcX = (float)source.origin.x, srcY = (float)source.origin.y;
    float srcW = (float)fmax(source.size.width, 1.0), srcH = (float)fmax(source.size.height, 1.0);

    float sx = (bufWf / srcW) * (elemW / geoW);
    float sy = (bufHf / srcH) * (elemH / geoH);
    float tx = -(srcX / srcW) * (elemW / geoW) + (elemX - geoX) / geoW;
    float ty = -(srcY / srcH) * (elemH / geoH) + (elemY - geoY) / geoH;
    u->m0 = simd_make_float4(sx, 0, 0, 0);
    u->m1 = simd_make_float4(0, sy, 0, 0);
    u->m2 = simd_make_float4(tx, ty, 1, 0);
    u->aa_scale = aaScale;
    u->geo_size = simd_make_float2((float)geo.w / (float)s, (float)geo.h / (float)s);
    u->corner_radius = simd_make_float4(clamped[0], clamped[1], clamped[2], clamped[3]);
}

// The sampled sub-rect `source` (texels) of a `texW` x `texH` texture: smithay's
// tex_matrix, plus the centres of its outermost texels.
static void IFCSetSource(IFCUniforms *u, CGRect source, double texW, double texH) {
    texW = fmax(texW, 1.0);
    texH = fmax(texH, 1.0);
    double x0 = source.origin.x, y0 = source.origin.y;
    double x1 = x0 + source.size.width, y1 = y0 + source.size.height;
    u->src = simd_make_float4((float)(x0 / texW), (float)(y0 / texH), (float)((x1 - x0) / texW), (float)((y1 - y0) / texH));
    double loX = x0 + 0.5, hiX = x1 - 0.5, loY = y0 + 0.5, hiY = y1 - 0.5;
    if (loX > hiX) loX = hiX = (x0 + x1) / 2.0;
    if (loY > hiY) loY = hiY = (y0 + y1) / 2.0;
    u->uv_bounds = simd_make_float4((float)(loX / texW), (float)(loY / texH), (float)(hiX / texW), (float)(hiY / texH));
}

static inline simd_float4 IFCColorVector(IFCompositorColor c) {
    return simd_make_float4((float)c.r / 255.0f, (float)c.g / 255.0f, (float)c.b / 255.0f, (float)c.a / 255.0f);
}

// MARK: - Renderer

static void IFCReleaseBytes(void *info, const void *data, size_t size) {
    (void)info;
    (void)size;
    free((void *)data);
}

// BGRA8 bytes -> sRGB CGImage. Takes ownership of `bytes`.
static CGImageRef IFCCreateImage(uint8_t *bytes, NSUInteger w, NSUInteger h, BOOL alpha) CF_RETURNS_RETAINED {
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bytes, w * h * 4, IFCReleaseBytes);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = (CGBitmapInfo)kCGBitmapByteOrder32Little |
                        (CGBitmapInfo)(alpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, srgb, info, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(srgb);
    CGDataProviderRelease(provider);
    return image;
}

typedef struct {
    uintptr_t *keys;
    NSUInteger count, capacity;
    uint64_t generation;
} IFCStaleScan;

static void IFCCollectStale(const void *key, const void *value, void *context) {
    IFCStaleScan *scan = context;
    IFCEntry *entry = (__bridge IFCEntry *)value;
    if (entry->lastUsed == scan->generation) return;
    if (scan->count == scan->capacity) {
        NSUInteger capacity = scan->capacity ? scan->capacity * 2 : 64;
        uintptr_t *grown = realloc(scan->keys, capacity * sizeof(uintptr_t));
        if (!grown) return;
        scan->keys = grown;
        scan->capacity = capacity;
    }
    scan->keys[scan->count++] = (uintptr_t)key;
}

@interface IFCompositorRenderer ()
- (void)ifc_flushAgedTextures;
@end

@implementation IFCompositorRenderer {
    IFCDeviceResources *_resources;
    IFCTextureCache *_textureCache;
    CFMutableDictionaryRef _entries;  // element identifier -> IFCEntry
    IFCGraveyard *_graveyard;
    void (^_completion)(id<MTLCommandBuffer>);
    MTLRenderPassDescriptor *_pass;
    uint64_t _generation;
    NSUInteger _touched;
    int _flushCountdown;  // encodes left in which the texture cache is flushed
    CFTimeInterval _nextAgedFlush;  // the texture cache is not flushed for age again before this time
    IFCStaleScan _scan;
    BOOL _warnedFormat;

    id<MTLTexture> _placeholderTexture;
    IFCompositorColor _placeholderTextureColor;
    BOOL _placeholderTextureValid;

    // Error bar (error_bar.rs `ErrorBarCache`).
    id<MTLTexture> _errorBarTexture;
    NSArray<NSString *> *_errorBarMessages;
    long _errorBarWidth, _errorBarScale;

    // Blur: this output's copy of the background for the backdrop passes, and
    // the cadence an animated background's frost follows (blur.rs `SharedBlur`).
    id<MTLTexture> _bgCopy;         // output-sized; kept between encodes, dropped after kIFCBlurKeepFrames unused
    unsigned _bgCopyIdle;
    id<MTLTexture> _bgTexture;      // `_bgCopy` once this encode has drawn the background into it
    BOOL _bgTextureTried;
    BOOL _hasBlurBeat;
    double _blurBeatTime;
    uint64_t _blurBeatView;

    // State of the encode in progress.
    id<MTLRenderCommandEncoder> _encoder;
    id<MTLRenderPipelineState> _boundPipeline;
    IFCRectI _target, _boundScissor, _elementScissor;
    IFCRectI _clip;                 // what the pass may draw into: `_target`, or the part of a backdrop that is on the output
    BOOL _skipShadow;               // the blur mask leaves the window's shadow out
    BOOL _hasXform;                 // the element being drawn carries `_xform`
    IFCompositorTransform _xform;
    long _originX, _originY;        // output pixel that lands on the pass's (0, 0)
    BOOL _internal;                 // a pass into an intermediate texture (backdrop, mask, bake)
    BOOL _bake;                     // a closing snapshot is being baked
    NSUInteger _drawsSubmitted;
    IFCItem *_items;                // this encode's elements, bottom to top
    NSUInteger _itemCount, _itemCapacity;
    BOOL _blurRequested;
}

+ (instancetype)rendererWithDevice:(id<MTLDevice>)device {
    return [[self alloc] initWithDevice:device];
}

- (instancetype)init {
    return [self initWithDevice:nil];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    if (!device) device = MTLCreateSystemDefaultDevice();
    if (!device) return nil;
    _device = device;
    _resources = [IFCDeviceResources resourcesForDevice:device];
    _commandQueue = _resources.queue;
    _textureCache = [IFCTextureCache new];
    NSDictionary *cacheAttributes = @{(__bridge id)kCVMetalTextureCacheMaximumTextureAgeKey: @(kIFCTextureCacheAge)};
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)cacheAttributes, device, NULL, &_textureCache->ref) !=
        kCVReturnSuccess) {
        _textureCache->ref = NULL;
    }
    _entries = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    _graveyard = [IFCGraveyard new];
    IFCGraveyard *graveyard = _graveyard;
    _completion = [^(id<MTLCommandBuffer> commandBuffer) {
        (void)commandBuffer;
        [graveyard finished];
    } copy];
    _pass = [MTLRenderPassDescriptor renderPassDescriptor];
    _pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    _pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    return self;
}

- (void)dealloc {
    [self purge];
    if (_entries) CFRelease(_entries);
    free(_scan.keys);
    free(_items);
}

static void IFCBuryEntry(const void *key, const void *value, void *context) {
    (void)key;
    [(__bridge IFCGraveyard *)context bury:(__bridge IFCEntry *)value];
}

- (void)purge {
    // Entries a command buffer may still sample are parked until it completes.
    if (_entries) {
        CFDictionaryApplyFunction(_entries, IFCBuryEntry, (__bridge void *)_graveyard);
        CFDictionaryRemoveAllValues(_entries);
    }
    if (_placeholderTexture) [_graveyard bury:_placeholderTexture];
    _placeholderTexture = nil;
    _placeholderTextureValid = NO;
    if (_errorBarTexture) [_graveyard bury:_errorBarTexture];
    _errorBarTexture = nil;
    _errorBarMessages = nil;
    if (_bgCopy) [_graveyard bury:_bgCopy];
    _bgCopy = nil;
    _bgTexture = nil;
    _bgTextureTried = NO;
    _hasBlurBeat = NO;
    if (_textureCache->ref) CVMetalTextureCacheFlush(_textureCache->ref, 0);
}

// The flushes in the encodes right after a retirement return the IOSurface to
// its pool, but they come too early to free anything: CoreVideo lets go of a
// wrapper's Metal texture, and the surface memory it keeps mapped, only in a
// flush made once the buffer has been unused for kIFCTextureCacheAge — and
// the buffer may be held by the host longer than by this renderer. So the
// cache is also flushed for age, at most once per that age and a half, at the
// end of an encode and when the layer skips a redraw: a scene that went
// static right after a window closed or became a stand-in gives the memory
// back on a later update of the host, drawn or not.
- (void)ifc_flushAgedTextures {
    CFTimeInterval now = CACurrentMediaTime();
    if (now < _nextAgedFlush) return;
    _nextAgedFlush = now + kIFCTextureCacheAge * 1.5;
    if (_textureCache->ref) CVMetalTextureCacheFlush(_textureCache->ref, 0);
}

// MARK: Cache

- (IFCEntry *)entryFor:(uint64_t)identifier {
    const void *key = (const void *)(uintptr_t)identifier;
    IFCEntry *entry = (__bridge IFCEntry *)CFDictionaryGetValue(_entries, key);
    if (!entry) {
        entry = [IFCEntry new];
        CFDictionarySetValue(_entries, key, (__bridge void *)entry);
    }
    if (entry->lastUsed != _generation) {
        entry->lastUsed = _generation;
        _touched++;
    }
    return entry;
}

- (void)retireContentOf:(IFCEntry *)entry {
    if (!entry->buffer && !entry->cvTexture && !entry->contentTexture) return;
    IFCRetiredContent *retired = [IFCRetiredContent new];
    retired->buffer = entry->buffer;
    retired->cvTexture = entry->cvTexture;
    retired->cache = entry->cache;
    retired->texture = entry->contentTexture;
    entry->buffer = NULL;
    entry->cvTexture = NULL;
    entry->cache = nil;
    entry->contentTexture = nil;
    [_graveyard bury:retired];
    // CoreVideo only lets go of an unused wrapper's backing when the cache is
    // flushed, and this one is released when its last frame completes: flush
    // at the end of this encode and of the next few.
    _flushCountdown = 3;
}

// An entry serves one kind of element at a time. An element keeps its
// identifier when it turns from a live window into a stand-in or back (as
// upstream keeps the element id), and the entry stays alive because it is used
// every frame — so whatever the other kind cached has to be dropped by hand:
// the stand-in's body and label, and the title bar unless the window still
// draws one. (-retireContentOf: is the other half, called for a stand-in.)
- (void)retireChromeOf:(IFCEntry *)entry keepingBar:(BOOL)keepBar {
    if (entry->bodyValid) {
        if (entry->bodyTexture) [_graveyard bury:entry->bodyTexture];
        entry->bodyTexture = nil;
        entry->bodyValid = NO;
    }
    if (entry->labelValid) {
        if (entry->labelTexture) [_graveyard bury:entry->labelTexture];
        entry->labelTexture = nil;
        entry->labelText = nil;
        entry->labelValid = NO;
    }
    if (!keepBar && entry->barValid) {
        if (entry->barTexture) [_graveyard bury:entry->barTexture];
        entry->barTexture = nil;
        entry->barTitle = nil;
        entry->barValid = NO;
    }
}

// The frost goes with the request for it (upstream prunes `blur_cache` to the
// windows that asked this frame).
- (void)retirePadsOf:(IFCEntry *)entry {
    if (entry->padA) [_graveyard bury:entry->padA];
    if (entry->padB) [_graveyard bury:entry->padB];
    entry->padA = entry->padB = nil;
    entry->padW = entry->padH = 0;
    entry->padsIdle = 0;
}

- (void)retireFrostOf:(IFCEntry *)entry {
    if (!entry->frostTexture && !entry->maskTexture && !entry->padA && !entry->frostValid && !entry->frostInit) return;
    if (entry->frostTexture) [_graveyard bury:entry->frostTexture];
    if (entry->maskTexture) [_graveyard bury:entry->maskTexture];
    entry->frostTexture = nil;
    entry->maskTexture = nil;
    [self retirePadsOf:entry];
    entry->frostAllocW = entry->frostAllocH = 0;
    entry->frostValid = NO;
    entry->frostZeroed = NO;
    entry->frostInit = NO;
    entry->frostHasContentId = NO;
    entry->frostSeen = 0;
}

// The texture for an element's live content, and its size in pixels. nil
// while no frame has arrived.
- (id<MTLTexture>)contentTextureFor:(IFCompositorElement *)element {
    id<MTLTexture> texture = element.texture;
    CVPixelBufferRef buffer = element.pixelBuffer;
    if (texture || !buffer) {
        // No wrapper needed; drop one left from an earlier buffer.
        IFCEntry *existing = (__bridge IFCEntry *)CFDictionaryGetValue(_entries, (const void *)(uintptr_t)element.identifier);
        if (existing) [self retireContentOf:existing];
        return texture;
    }
    IFCEntry *entry = [self entryFor:element.identifier];
    if (entry->buffer == buffer && entry->contentTexture) return entry->contentTexture;
    [self retireContentOf:entry];
    if (!_textureCache->ref) return nil;
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA || !CVPixelBufferGetIOSurface(buffer)) {
        if (!_warnedFormat) {
            _warnedFormat = YES;
            NSLog(@"compositor: element %llu: content must be an IOSurface-backed kCVPixelFormatType_32BGRA buffer; drawing the placeholder",
                  (unsigned long long)element.identifier);
        }
        return nil;
    }
    CVMetalTextureRef cvTexture = NULL;
    // BGRA8Unorm, not _sRGB: texels are sampled as encoded, like a GL texture.
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache->ref, buffer, NULL, MTLPixelFormatBGRA8Unorm,
                                                                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture);
    if (status != kCVReturnSuccess || !cvTexture) return nil;
    id<MTLTexture> wrapped = CVMetalTextureGetTexture(cvTexture);
    if (!wrapped) {
        CFRelease(cvTexture);
        return nil;
    }
    entry->buffer = CVPixelBufferRetain(buffer);
    entry->cvTexture = cvTexture;
    entry->cache = _textureCache;
    entry->contentTexture = wrapped;
    return wrapped;
}

- (id<MTLTexture>)textureWithRGBA:(NSData *)data width:(long)w height:(long)h {
    if (!data || w <= 0 || h <= 0) return nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:(NSUInteger)w
                                                                                 height:(NSUInteger)h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:td];
    [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h) mipmapLevel:0 withBytes:data.bytes bytesPerRow:(NSUInteger)w * 4];
    return texture;
}

// decorations.rs `WindowDecoration::update`: re-render when the width, pinned
// flag, scale, title, corner radius or style changed.
- (id<MTLTexture>)barTextureFor:(IFCEntry *)e width:(long)width scale:(long)scale title:(NSString *)title
                         pinned:(BOOL)pinned radius:(long)radius style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash {
    NSString *text = title ?: @"";
    if (e->barValid && e->barWidth == width && e->barScale == scale && e->barRadius == radius && e->barPinned == pinned &&
        e->barStyle == styleHash && [e->barTitle isEqualToString:text]) {
        return e->barTexture;
    }
    long w = 0, h = 0;
    NSData *pixels = IFCRenderTitleBar(width, scale, text, pinned, radius, style, &w, &h);
    if (e->barTexture) [_graveyard bury:e->barTexture];
    e->barTexture = [self textureWithRGBA:pixels width:w height:h];
    e->barValid = YES;
    e->barWidth = width;
    e->barScale = scale;
    e->barRadius = radius;
    e->barPinned = pinned;
    e->barStyle = styleHash;
    e->barTitle = [text copy];
    return e->barTexture;
}

// suspended.rs `ensure_body`.
- (id<MTLTexture>)bodyTextureFor:(IFCEntry *)e width:(long)bodyW height:(long)bodyH scale:(long)scale
                           style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash {
    if (e->bodyValid && e->bodyW == bodyW && e->bodyH == bodyH && e->bodyScale == scale && e->bodyStyle == styleHash) return e->bodyTexture;
    long w = 0, h = 0;
    NSData *pixels = IFCRenderBodyFill(bodyW, bodyH, scale, style, &w, &h);
    if (e->bodyTexture) [_graveyard bury:e->bodyTexture];
    e->bodyTexture = [self textureWithRGBA:pixels width:w height:h];
    e->bodyValid = YES;
    e->bodyW = bodyW;
    e->bodyH = bodyH;
    e->bodyScale = scale;
    e->bodyStyle = styleHash;
    return e->bodyTexture;
}

// suspended.rs `ensure_label`.
- (id<MTLTexture>)labelTextureFor:(IFCEntry *)e name:(NSString *)name launching:(BOOL)launching width:(long)bodyW height:(long)bodyH
                            scale:(long)scale style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash {
    if (e->labelValid && e->labelBodyW == bodyW && e->labelBodyH == bodyH && e->labelScale == scale && e->labelLaunching == launching &&
        e->labelStyle == styleHash && [e->labelText isEqualToString:name]) {
        return e->labelTexture;
    }
    // format!("{} launching…", display_name)
    NSString *text = launching ? [name stringByAppendingString:@" launching\u2026"] : name;
    long w = 0, h = 0;
    IFCRectI rect;
    NSData *pixels = IFCRenderLabel(text, bodyW, bodyH, scale, style, &w, &h, &rect);
    if (e->labelTexture) [_graveyard bury:e->labelTexture];
    e->labelTexture = pixels ? [self textureWithRGBA:pixels width:w height:h] : nil;
    e->labelValid = YES;
    e->labelBodyW = bodyW;
    e->labelBodyH = bodyH;
    e->labelScale = scale;
    e->labelLaunching = launching;
    e->labelStyle = styleHash;
    e->labelText = [name copy];
    e->labelBufW = w;
    e->labelBufH = h;
    e->labelRect = rect;
    return e->labelTexture;
}

- (id<MTLTexture>)placeholderTextureForColor:(IFCompositorColor)color {
    if (_placeholderTextureValid && memcmp(&color, &_placeholderTextureColor, sizeof color) == 0) return _placeholderTexture;
    if (_placeholderTexture) [_graveyard bury:_placeholderTexture];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    _placeholderTexture = [_device newTextureWithDescriptor:td];
    // Premultiplied, as every texture this renderer samples.
    double a = (double)color.a / 255.0;
    const uint8_t texel[4] = {IFCU8((double)color.r * a), IFCU8((double)color.g * a), IFCU8((double)color.b * a), color.a};
    [_placeholderTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:texel bytesPerRow:4];
    _placeholderTextureColor = color;
    _placeholderTextureValid = YES;
    return _placeholderTexture;
}

// MARK: Draw submission

// elements.rs `WindowTransformElement::transform_rect`.
static IFCRectI IFCTransformRect(IFCRectI r, IFCompositorTransform t) {
    double x0 = t.originX + ((double)r.x - t.originX) * t.scaleX + t.offsetX;
    double y0 = t.originY + ((double)r.y - t.originY) * t.scaleY + t.offsetY;
    double x1 = t.originX + ((double)(r.x + r.w) - t.originX) * t.scaleX + t.offsetX;
    double y1 = t.originY + ((double)(r.y + r.h) - t.originY) * t.scaleY + t.offsetY;
    return IFCRectIMake(IFCRound(x0), IFCRound(y0), MAX(IFCRound(x1) - IFCRound(x0), 0L), MAX(IFCRound(y1) - IFCRound(y0), 0L));
}

- (void)draw:(IFCPipe)pipe dst:(IFCRectI)dst uniforms:(IFCUniforms *)u texture:(id<MTLTexture>)texture
     element:(IFCompositorElement *)element {
    [self draw:pipe dst:dst hole:IFCRectIMake(0, 0, 0, 0) uniforms:u texture:texture element:element];
}

// `hole` is a rectangle inside `dst` where the fragment shader is known to
// return exactly zero (the window body under its shadow, the content under its
// border). Under premultiplied source-over a zero fragment leaves the target
// unchanged, so those fragments are not rasterised at all: the element is
// drawn as up to four strips around the hole. Same pixels, far less fill.
- (void)draw:(IFCPipe)pipe dst:(IFCRectI)dst hole:(IFCRectI)hole uniforms:(IFCUniforms *)u
     texture:(id<MTLTexture>)texture element:(IFCompositorElement *)element {
    if (_hasXform) {
        dst = IFCTransformRect(dst, _xform);
        if (hole.w > 0 && hole.h > 0) {
            // One pixel of slack for the transform's own rounding.
            hole = IFCTransformRect(hole, _xform);
            hole = IFCRectIMake(hole.x + 1, hole.y + 1, hole.w - 2, hole.h - 2);
        }
    }
    // A pass into an intermediate texture (a blurred window's backdrop or
    // mask) draws the frame's own rectangles moved by a whole number of
    // pixels, as upstream's `RelocateRenderElement` does: every pixel gets the
    // value it has in the frame.
    dst.x -= _originX;
    dst.y -= _originY;
    hole.x -= _originX;
    hole.y -= _originY;
    IFCRectI scissor = element ? _elementScissor : _clip;
    if (dst.w <= 0 || dst.h <= 0 || !IFCRectIIntersect(dst, scissor, NULL)) return;
    id<MTLRenderPipelineState> pipeline = [_resources pipeline:pipe];
    if (!pipeline) return;

    IFCRectI parts[4];
    int partCount = 0;
    BOOL split = hole.w > 0 && hole.h > 0 && hole.x >= dst.x && hole.y >= dst.y && hole.x + hole.w <= dst.x + dst.w &&
                 hole.y + hole.h <= dst.y + dst.h;
    if (split) {
        long holeRight = hole.x + hole.w, holeBottom = hole.y + hole.h;
        parts[partCount++] = IFCRectIMake(dst.x, dst.y, dst.w, hole.y - dst.y);                        // above
        parts[partCount++] = IFCRectIMake(dst.x, holeBottom, dst.w, dst.y + dst.h - holeBottom);       // below
        parts[partCount++] = IFCRectIMake(dst.x, hole.y, hole.x - dst.x, hole.h);                      // left
        parts[partCount++] = IFCRectIMake(holeRight, hole.y, dst.x + dst.w - holeRight, hole.h);       // right
    } else {
        parts[partCount++] = dst;
    }

    u->dst = simd_make_float4((float)dst.x, (float)dst.y, (float)dst.w, (float)dst.h);
    u->target = simd_make_float2((float)_target.w, (float)_target.h);
    if (pipeline != _boundPipeline) {
        [_encoder setRenderPipelineState:pipeline];
        _boundPipeline = pipeline;
    }
    if (memcmp(&scissor, &_boundScissor, sizeof scissor) != 0) {
        [_encoder setScissorRect:(MTLScissorRect){(NSUInteger)scissor.x, (NSUInteger)scissor.y, (NSUInteger)scissor.w, (NSUInteger)scissor.h}];
        _boundScissor = scissor;
    }
    if (texture) [_encoder setFragmentTexture:texture atIndex:0];
    BOOL fragmentUniformsBound = NO;
    for (int i = 0; i < partCount; i++) {
        IFCRectI part = parts[i];
        if (part.w <= 0 || part.h <= 0 || !IFCRectIIntersect(part, scissor, NULL)) continue;
        u->quad = simd_make_float4((float)part.x, (float)part.y, (float)part.w, (float)part.h);
        [_encoder setVertexBytes:u length:sizeof *u atIndex:0];
        // Only the vertex shader reads quad. A split shadow/border changes
        // that rectangle per strip, but every strip shares its fragment data.
        if (!fragmentUniformsBound) {
            [_encoder setFragmentBytes:u length:sizeof *u atIndex:0];
            fragmentUniformsBound = YES;
        }
        [_encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        _drawsSubmitted++;
    }
}

static inline IFCUniforms IFCUniformsZero(void) {
    IFCUniforms u;
    memset(&u, 0, sizeof u);
    u.src = simd_make_float4(0, 0, 1, 1);
    u.uv_bounds = simd_make_float4(0, 0, 1, 1);
    u.alpha = 1.0f;
    return u;
}

// mod.rs `push_shadow_element` / `push_border_element`, shared by windows and
// stand-ins. `inner` is the rectangle the border wraps (content, or title bar
// plus content); the shadow is cast by `inner` grown by the border.
- (void)drawChromeAround:(IFCRectD)inner decoration:(IFCompositorDecoration)deco borderWidth:(long)bw radius:(long)radius
                  shadow:(BOOL)shadow focused:(BOOL)focused alpha:(float)alpha scale:(double)s zoom:(double)zoom
                   parts:(IFCChromePart)parts element:(IFCompositorElement *)element {
    if (shadow && !_skipShadow && (parts & IFCChromeShadow)) {
        // The footprint grows by border_width so the shadow grades from the
        // border's outer edge; the radius follows `outer_corner_radius`.
        // (closing.rs `flatten` hands `bake_shadow_element` the body as it is,
        // not grown: a baked shadow starts under the border.)
        double b = _bake ? 0.0 : (double)bw;
        IFCRectD body = {inner.x - b, inner.y - b, inner.w + 2.0 * b, inner.h + 2.0 * b};
        IFCUniforms u = IFCUniformsZero();
        IFCRectI dst, hole;
        IFCShadowGeometry(body, IFCOuterCornerRadius((float)radius, (float)bw), deco.shadowRadius, s, zoom, &dst, &hole, &u);
        u.color = IFCColorVector(deco.shadowColor);
        u.alpha = alpha;
        [self draw:IFCPipeShadow dst:dst hole:hole uniforms:&u texture:nil element:element];
    }
    if (bw > 0 && (parts & IFCChromeBorder)) {
        IFCUniforms u = IFCUniformsZero();
        IFCRectI dst, hole;
        if (IFCBorderGeometry(inner, bw, (float)radius, s, zoom, &dst, &hole, &u)) {
            u.color = IFCColorVector(focused ? deco.borderColorFocused : deco.borderColor);
            u.alpha = alpha;
            [self draw:IFCPipeBorder dst:dst hole:hole uniforms:&u texture:nil element:element];
        }
    }
}

// A memory buffer drawn through smithay's default texture program into `dst`
// (pre-zoom physical), pixel-snapped by `zoom` (`PixelSnapRescaleElement`).
- (void)drawBuffer:(id<MTLTexture>)texture preZoom:(IFCRectI)rect zoom:(double)zoom alpha:(float)alpha
           element:(IFCompositorElement *)element {
    if (!texture) return;
    IFCUniforms u = IFCUniformsZero();
    u.alpha = alpha;
    IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)texture.width, (CGFloat)texture.height), (double)texture.width, (double)texture.height);
    [self draw:IFCPipeTexture dst:IFCCornerRound(rect, zoom) uniforms:&u texture:texture element:element];
}

// blur.rs, the splice at the end of `process_blur_requests`: the frost as a
// `TextureRenderElement` at `screen_rect.loc`, `src = texel_src(win_size)`,
// logical size `round(win_size / output_scale)`, alpha 1 — whatever the
// window's opacity is.
- (void)drawFrostOf:(IFCompositorElement *)element entry:(IFCEntry *)entry scale:(double)s {
    if (!entry || !entry->frostValid || entry->frostZeroed || !entry->frostTexture || entry->frostSeen != _generation) return;
    IFCUniforms u = IFCUniformsZero();
    IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)entry->frostW, (CGFloat)entry->frostH), (double)entry->frostAllocW, (double)entry->frostAllocH);
    IFCRectI r = entry->frostRect;
    IFCRectI dst = IFCMemoryElementRect((double)r.x, (double)r.y, IFCRound((double)r.w / s), IFCRound((double)r.h / s), s);
    // `screen_rect` already went through the window's animation
    // (`transform_phys_rect`); the frost element is not wrapped in one.
    BOOL hadXform = _hasXform;
    _hasXform = NO;
    [self draw:IFCPipeTexture dst:dst uniforms:&u texture:entry->frostTexture element:element];
    _hasXform = hadXform;
}

// mod.rs `compose_frame`, one client window.
- (void)drawWindow:(const IFCItem *)item frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    IFCompositorElement *element = item->element;
    IFCGeom g = item->g;
    double s = c->s;
    long decorationScale = c->decorationScale;
    uint64_t styleHash = c->styleHash;
    IFCompositorDecoration deco = element.decoration;
    double zoom = g.zoom;
    // `decoration = "none"` hard-vetoes compositor chrome (the effective_*
    // helpers return 0 / false for it), and a fullscreen window draws through
    // the same branch.
    BOOL bare = deco.mode == IFCompositorDecorationModeNone;
    BOOL hasSSD = deco.mode == IFCompositorDecorationModeServer;
    long bw = bare ? 0 : MAX((long)deco.borderWidth, 0L);
    long radius = bare ? 0 : MAX((long)deco.cornerRadius, 0L);
    BOOL shadow = !bare && deco.shadow;
    float opacity = (float)fmin(fmax(deco.opacity, 0.0), 1.0);
    // An open or close fade: `effective_opacity(..) * visual_alpha as f64`.
    if (item->lifeAlpha != 1.0f) opacity = (float)((double)opacity * (double)item->lifeAlpha);
    // closing.rs: the bake is drawn at alpha 1; the snapshot is faded as one piece.
    if (_bake) opacity = 1.0f;
    IFCompositorChromeStyle *style = frame.chrome;

    // What this identifier cached as a stand-in, or as a window with a bar.
    IFCEntry *existing = (__bridge IFCEntry *)CFDictionaryGetValue(_entries, (const void *)(uintptr_t)element.identifier);
    if (existing) {
        [self retireChromeOf:existing keepingBar:hasSSD];
        if (!_internal && !element.blur) [self retireFrostOf:existing];
    }

    // loc_phys = render_loc.to_physical_precise_round(scale)
    long locX = IFCRound(g.r.x * s), locY = IFCRound(g.r.y * s);
    // The surface element: WaylandSurfaceRenderElement::geometry.
    IFCRectI surface = IFCRectIMake(locX, locY, IFCRound(g.r.w * s), IFCRound(g.r.h * s));

    // Snap the title-bar band to whole physical pixels and share it across the
    // bar, border and shadow.
    double barHPhys = hasSSD ? round((double)style.titleBarHeight * s) : 0.0;
    double barHLogical = barHPhys / s;
    IFCRectD inner = {g.r.x, g.r.y - barHLogical, g.r.w, g.r.h + barHLogical};

    // Bottom to top: shadow, frost, border, content, title bar (upstream
    // pushes them top to bottom: bar, content, border, [frost], shadow).
    [self drawChromeAround:inner decoration:deco borderWidth:bw radius:radius shadow:shadow focused:element.focused
                     alpha:opacity scale:s zoom:zoom parts:IFCChromeShadow element:element];
    // No frost in a backdrop, a mask or a bake: upstream captures them from
    // the element list before any frost is spliced into it.
    if (element.blur && !_internal) [self drawFrostOf:element entry:existing scale:s];
    [self drawChromeAround:inner decoration:deco borderWidth:bw radius:radius shadow:shadow focused:element.focused
                     alpha:opacity scale:s zoom:zoom parts:IFCChromeBorder element:element];

    id<MTLTexture> content = [self contentTextureFor:element];
    BOOL placeholder = content == nil;
    if (placeholder && frame.placeholderColor.a > 0) content = [self placeholderTextureForColor:frame.placeholderColor];
    if (content) {
        double bufW = (double)content.width, bufH = (double)content.height;
        CGRect source = CGRectMake(0, 0, bufW, bufH);
        if (!placeholder && !CGRectIsNull(element.contentRect) && element.contentRect.size.width > 0 && element.contentRect.size.height > 0) {
            source = element.contentRect;
        }
        IFCUniforms u = IFCUniformsZero();
        u.alpha = opacity;
        u.no_alpha = (!placeholder && element.contentOpaque) ? 1.0f : 0.0f;
        IFCSetSource(&u, source, bufW, bufH);
        IFCRectI dst = IFCCornerRound(surface, zoom);
        // SSD clips only when there is something to clip against; CSD always
        // clips to the geometry; bare and fullscreen pass through.
        BOOL clip = !bare && (!hasSSD || bw > 0 || radius > 0);
        if (clip) {
            float r = (float)radius;
            // Only the bottom corners round under a title bar.
            const float radii[4] = {hasSSD ? 0.0f : r, hasSSD ? 0.0f : r, r, r};
            IFCCornerClipUniforms(surface, g.r, radii, s, zoom, bufW, bufH, source, &u);
            [self draw:IFCPipeCornerClip dst:dst uniforms:&u texture:content element:element];
        } else {
            [self draw:IFCPipeTexture dst:dst uniforms:&u texture:content element:element];
        }
    }

    if (hasSSD) {
        long width = IFCRound(g.r.w);
        IFCEntry *entry = [self entryFor:element.identifier];
        id<MTLTexture> bar = [self barTextureFor:entry width:width scale:decorationScale title:element.title
                                          pinned:element.showsPinnedIndicator radius:radius style:style styleHash:styleHash];
        // The bar takes the border's inner width so it stops where the content does.
        IFCRectI barDst = IFCRectIMake(locX, locY - IFCTrunc(barHPhys), IFCPaintedExtent(g.r.w, s), IFCPaintedExtent(barHLogical, s));
        [self drawBuffer:bar preZoom:barDst zoom:zoom alpha:opacity element:element];
    }
}

// suspended.rs `push_suspended_element`.
- (void)drawStandIn:(const IFCItem *)item frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    IFCompositorElement *element = item->element;
    IFCGeom g = item->g;
    double s = c->s;
    long decorationScale = c->decorationScale;
    uint64_t styleHash = c->styleHash;
    IFCompositorDecoration deco = element.decoration;
    IFCompositorChromeStyle *style = frame.chrome;
    double zoom = g.zoom;
    // Upstream's stand-in size is an integer logical size.
    long sizeW = MAX(IFCRound(g.r.w), 0L), sizeH = MAX(IFCRound(g.r.h), 0L);
    long bw = MAX((long)deco.borderWidth, 0L);
    long radius = MAX((long)deco.cornerRadius, 0L);
    float alpha = (float)fmin(fmax(deco.opacity, 0.0), 1.0);
    // closing.rs `StandInFade::alpha`: a departing stand-in fades as a whole.
    if (item->lifeAlpha != 1.0f) alpha = (float)((double)alpha * (double)item->lifeAlpha);

    long locX = IFCRound(g.r.x * s), locY = IFCRound(g.r.y * s);
    double barHPhys = round((double)style.titleBarHeight * s);
    double barHLogical = barHPhys / s;
    IFCEntry *entry = [self entryFor:element.identifier];
    [self retireFrostOf:entry];
    // A stand-in draws no content: let go of the capture buffer and its Metal
    // wrapper this identifier held as a live window (whatever the element's
    // own `pixelBuffer` still says).
    [self retireContentOf:entry];

    // Bottom to top: shadow, border, title bar, body, label.
    IFCRectD inner = {g.r.x, g.r.y - barHLogical, (double)sizeW, (double)sizeH + barHLogical};
    [self drawChromeAround:inner decoration:deco borderWidth:bw radius:radius shadow:deco.shadow focused:element.focused
                     alpha:alpha scale:s zoom:zoom parts:(IFCChromeShadow | IFCChromeBorder) element:element];

    // Title bar via the windowless rasteriser, textless: the centred label
    // already names the app. It rounds to the element's radius like its border.
    id<MTLTexture> bar = [self barTextureFor:entry width:sizeW scale:decorationScale title:@"" pinned:NO radius:radius
                                       style:style styleHash:styleHash];
    IFCRectI barDst = IFCRectIMake(locX, locY - IFCTrunc(barHPhys), IFCPaintedExtent((double)sizeW, s), IFCPaintedExtent(barHLogical, s));
    [self drawBuffer:bar preZoom:barDst zoom:zoom alpha:alpha element:element];

    // Rounded body fill in the SSD background colour, trimmed to the painted rect.
    id<MTLTexture> body = [self bodyTextureFor:entry width:sizeW height:sizeH scale:decorationScale style:style styleHash:styleHash];
    IFCRectI bodyDst = IFCRectIMake(locX, locY, IFCPaintedExtent((double)sizeW, s), IFCPaintedExtent((double)sizeH, s));
    [self drawBuffer:body preZoom:bodyDst zoom:zoom alpha:alpha element:element];

    // Centred app-name label.
    NSString *name = element.appName.length ? element.appName : (element.title ?: @"");
    id<MTLTexture> label = [self labelTextureFor:entry name:name launching:element.launching width:sizeW height:sizeH
                                           scale:decorationScale style:style styleHash:styleHash];
    if (label) {
        double labelX = g.r.x + (double)entry->labelRect.x, labelY = g.r.y + (double)entry->labelRect.y;
        // The memory element's logical size: buffer size over buffer scale.
        IFCRectI labelDst = IFCMemoryElementRect(labelX * s, labelY * s, entry->labelBufW / decorationScale, entry->labelBufH / decorationScale, s);
        [self drawBuffer:label preZoom:labelDst zoom:zoom alpha:alpha element:element];
    }
}

// closing.rs `ClosingSnapshot::render_element`: the baked window as one
// texture, faded by `fade_out_alpha` and shrunk about the centre of the
// rectangle it covers.
- (void)drawSnapshot:(const IFCItem *)item ctx:(const IFCFrameCtx *)c {
    IFCompositorElement *element = item->element;
    // What this identifier cached as a live window or a stand-in.
    IFCEntry *existing = (__bridge IFCEntry *)CFDictionaryGetValue(_entries, (const void *)(uintptr_t)element.identifier);
    if (existing) {
        [self retireChromeOf:existing keepingBar:NO];
        [self retireFrostOf:existing];
    }
    id<MTLTexture> texture = [self contentTextureFor:element];
    if (!texture) return;
    IFCGeom g = item->g;
    double s = c->s;
    double p = item->progress;
    float alpha = IFCompositorCloseAlpha(p);
    // let close_scale = if self.alpha_only { 1.0 } else { 1.0 - (1.0 - self.scale_amplitude) * self.progress };
    double closeScale = item->alphaOnly ? 1.0 : IFCompositorCloseScale(p, c->effects.animationScale);

    // (canvas_rect.loc - camera) * zoom and canvas_rect.size * zoom for a canvas
    // snapshot; the screen rectangle itself (zoom 1) for a pinned one.
    double screenX = g.r.x * g.zoom, screenY = g.r.y * g.zoom;
    double screenW = g.r.w * g.zoom, screenH = g.r.h * g.zoom;
    double locX = screenX * s, locY = screenY * s;
    double sizeW = screenW * s, sizeH = screenH * s;
    // TextureRenderElement at loc_phys, logical size screen_size.to_i32_round(),
    // inside WindowTransformElement(center, offset 0, close_scale).
    IFCompositorTransform t = {locX + sizeW / 2.0, locY + sizeH / 2.0, 0.0, 0.0, closeScale, closeScale};
    IFCRectI dst = IFCTransformRect(IFCMemoryElementRect(locX, locY, IFCRound(screenW), IFCRound(screenH), s), t);

    double bufW = (double)texture.width, bufH = (double)texture.height;
    CGRect source = CGRectMake(0, 0, bufW, bufH);  // texel_src(self.texels)
    if (!CGRectIsNull(element.contentRect) && element.contentRect.size.width > 0 && element.contentRect.size.height > 0) {
        source = element.contentRect;
    }
    IFCUniforms u = IFCUniformsZero();
    // Upstream: `Some(alpha)`. The element's opacity (1 for a bake) multiplies it.
    double opacity = fmin(fmax(element.decoration.opacity, 0.0), 1.0);
    u.alpha = opacity == 1.0 ? alpha : (float)((double)alpha * opacity);
    u.no_alpha = element.contentOpaque ? 1.0f : 0.0f;
    IFCSetSource(&u, source, bufW, bufH);
    [self draw:IFCPipeTexture dst:dst uniforms:&u texture:texture element:element];
}

// One element, in whichever pass is open: the frame itself, the backdrop of a
// blurred window above it, or its own mask.
- (void)drawItem:(const IFCItem *)item frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    IFCRectI scissor = item->scissor;
    scissor.x -= _originX;
    scissor.y -= _originY;
    if (!IFCRectIIntersect(scissor, _clip, &_elementScissor)) return;
    _hasXform = item->hasXform;
    _xform = item->xform;
    switch (item->element.kind) {
        case IFCompositorElementKindStandIn:
            [self drawStandIn:item frame:frame ctx:c];
            break;
        case IFCompositorElementKindSnapshot:
            [self drawSnapshot:item ctx:c];
            break;
        case IFCompositorElementKindWindow:
        default:
            [self drawWindow:item frame:frame ctx:c];
            break;
    }
    _hasXform = NO;
}

// error_bar.rs `render_error_bar`: opaque black, the joined messages in white
// monospace, tail-ellipsised between the side insets. RGBA8 (`Abgr8888`), at
// buffer scale `scale`.
static NSMutableData *IFCRenderErrorBar(NSString *text, long width, long barHeight, long scale, long *outW, long *outH) {
    long s = MAX(scale, 1L);
    long w = MAX(MAX(width, 1L) * s, 1L), h = MAX(MAX(barHeight, 1L) * s, 1L);
    if ((NSUInteger)w > kIFCMaxTextureSide || (NSUInteger)h > kIFCMaxTextureSide) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(w * h * 4)];
    uint8_t *pixels = data.mutableBytes;
    for (long i = 0; i < w * h; i++) pixels[i * 4 + 3] = 255;

    float fontPx = kIFCErrorBarFontPx * (float)s;
    long padX = kIFCErrorBarPadX * s;
    long available = w - 2 * padX;
    if (available > 0) {
        CTFontRef font = IFCCreateFont(@"monospace", (double)fontPx, IFCompositorFontWeightNormal);
        long textW = 0;
        NSString *fitted = IFCFitText(text ?: @"", font, available, &textW);
        IFCRasterizeInto(pixels, w, h, fitted, font, fontPx, IFCompositorColorMake(255, 255, 255, 255), padX);
        CFRelease(font);
    }
    *outW = w;
    *outH = h;
    return data;
}

// error_bar.rs `build_error_bar_elements`: above every window, across the
// bottom edge of the output. Not zoomed.
- (void)drawErrorBar:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    NSArray<NSString *> *messages = frame.errorMessages;
    if (!messages.count) {
        // `state.render.cached_error_bar.remove(&name)`
        if (_errorBarTexture) [_graveyard bury:_errorBarTexture];
        _errorBarTexture = nil;
        _errorBarMessages = nil;
        return;
    }
    long width = MAX(c->viewportW, 1L), scale = MAX(c->decorationScale, 1L), barHeight = (long)IFCompositorErrorBarHeight();
    // Keyed by (text, width, scale), as upstream's cache is.
    if (!_errorBarMessages || width != _errorBarWidth || scale != _errorBarScale ||
        (messages != _errorBarMessages && ![messages isEqualToArray:_errorBarMessages])) {
        long w = 0, h = 0;
        NSData *pixels = IFCRenderErrorBar(IFCompositorErrorBarText(messages), width, barHeight, scale, &w, &h);
        if (_errorBarTexture) [_graveyard bury:_errorBarTexture];
        _errorBarTexture = [self textureWithRGBA:pixels width:w height:h];
        _errorBarWidth = width;
        _errorBarScale = scale;
    }
    _errorBarMessages = messages;
    if (!_errorBarTexture) return;
    // loc = (0, viewport.h - bar_height) in logical pixels, to_physical(output_scale);
    // the buffer's logical size is its pixel size over its scale.
    IFCRectI dst = IFCMemoryElementRect(0.0, (double)(c->viewportH - barHeight) * c->s, width, barHeight, c->s);
    IFCUniforms u = IFCUniformsZero();
    IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)_errorBarTexture.width, (CGFloat)_errorBarTexture.height),
                 (double)_errorBarTexture.width, (double)_errorBarTexture.height);
    // PixelSnapRescaleElement with a rescale of 1.0: unchanged.
    [self draw:IFCPipeTexture dst:dst uniforms:&u texture:_errorBarTexture element:nil];
}

// mod.rs `outline_edge_strips` + `build_output_outline_elements`.
- (void)drawOutlines:(IFCompositorFrame *)frame scale:(double)s viewportW:(long)viewportW viewportH:(long)viewportH {
    IFCompositorOutlineSettings settings = frame.outline;
    long thickness = settings.thickness;
    float opacity = (float)settings.opacity;
    NSUInteger count = frame.outlineRectCount;
    if (thickness <= 0 || !(opacity > 0.0f) || !count) return;
    const CGRect *rects = [frame ifc_outlineRects];
    IFCRectI viewport = IFCRectIMake(0, 0, viewportW, viewportH);
    IFCUniforms u = IFCUniformsZero();
    // The strip buffer holds the configured colour bytes; the element's alpha
    // is the configured opacity.
    u.color = IFCColorVector(settings.color);
    u.alpha = fminf(opacity, 1.0f);
    // Upstream's list is top to bottom; draw it back to front.
    for (NSUInteger i = count; i-- > 0;) {
        IFCRectI outline = IFCRectIMake(IFCTrunc(rects[i].origin.x), IFCTrunc(rects[i].origin.y),
                                        IFCTrunc(rects[i].size.width), IFCTrunc(rects[i].size.height));
        if (!IFCRectIIntersect(viewport, outline, NULL)) continue;
        const IFCRectI edges[4] = {
            IFCRectIMake(outline.x, outline.y, outline.w, thickness),
            IFCRectIMake(outline.x, outline.y + outline.h - thickness, outline.w, thickness),
            IFCRectIMake(outline.x, outline.y, thickness, outline.h),
            IFCRectIMake(outline.x + outline.w - thickness, outline.y, thickness, outline.h),
        };
        for (int e = 3; e >= 0; e--) {
            IFCRectI strip;
            if (!IFCRectIIntersect(edges[e], viewport, &strip)) continue;
            // loc = strip.loc.to_f64().to_physical(scale); the buffer is at scale 1.
            IFCRectI dst = IFCMemoryElementRect((double)strip.x * s, (double)strip.y * s, strip.w, strip.h, s);
            // PixelSnapRescaleElement with a rescale of 1.0: unchanged.
            [self draw:IFCPipeSolid dst:dst uniforms:&u texture:nil element:nil];
        }
    }
}

// MARK: Intermediate passes

// Opens a render pass on `texture` whose viewport is its top-left
// `width` x `height` pixels (smithay's `renderer.render(target, size, ..)`:
// `glViewport(0, 0, w, h)` and the matching scissor).
- (BOOL)beginPassOn:(id<MTLTexture>)texture width:(long)width height:(long)height load:(MTLLoadAction)load
              clear:(MTLClearColor)clear commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!texture || width <= 0 || height <= 0) return NO;
    _pass.colorAttachments[0].texture = texture;
    _pass.colorAttachments[0].loadAction = load;
    _pass.colorAttachments[0].clearColor = clear;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:_pass];
    _pass.colorAttachments[0].texture = nil;
    _pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    if (!encoder) return NO;
    _encoder = encoder;
    _boundPipeline = nil;
    _target = IFCRectIMake(0, 0, width, height);
    _clip = _target;
    if ((NSUInteger)width != texture.width || (NSUInteger)height != texture.height) {
        [encoder setViewport:(MTLViewport){0, 0, (double)width, (double)height, 0, 1}];
        [encoder setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)width, (NSUInteger)height}];
    }
    _boundScissor = _target;
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
    return YES;
}

- (void)endPass {
    [_encoder endEncoding];
    _encoder = nil;
    _boundPipeline = nil;
}

// One quad over `dst` of the open pass, with none of the per-element state.
- (void)rawDraw:(IFCPipe)pipe dst:(IFCRectI)dst uniforms:(IFCUniforms *)u texture:(id<MTLTexture>)texture {
    id<MTLRenderPipelineState> pipeline = [_resources pipeline:pipe];
    if (!pipeline || !_encoder) return;
    u->dst = simd_make_float4((float)dst.x, (float)dst.y, (float)dst.w, (float)dst.h);
    u->quad = u->dst;
    u->target = simd_make_float2((float)_target.w, (float)_target.h);
    [_encoder setRenderPipelineState:pipeline];
    _boundPipeline = pipeline;
    if (texture) [_encoder setFragmentTexture:texture atIndex:0];
    [_encoder setVertexBytes:u length:sizeof *u atIndex:0];
    [_encoder setFragmentBytes:u length:sizeof *u atIndex:0];
    [_encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// MARK: Blur (blur.rs)

- (id<MTLTexture>)newBlurTextureWidth:(long)width height:(long)height {
    if (width <= 0 || height <= 0 || (NSUInteger)width > kIFCMaxTextureSide || (NSUInteger)height > kIFCMaxTextureSide) return nil;
    // Abgr8888 offscreens upstream; BGRA8 here, like every other target.
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:(NSUInteger)width
                                                                                 height:(NSUInteger)height
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:td];
    return texture;
}

// blur.rs `render_blur` + `blur_pass`: `passes` downscale passes, then
// `passes` upscale passes, between two textures of the same extent. Each pass
// reads the top-left `alloc >> src_shift` of one and writes the top-left
// `alloc >> dst_shift` of the other; texture coordinates are normalised over
// the whole allocation. Returns the texture holding the result: `a`, after an
// even number of swaps.
//
// What a pass leaves outside the region it writes is read by the taps at the
// right and bottom edges of the next one. In `a` that is the captured
// backdrop, as upstream. In `b` upstream reads whatever `create_buffer`
// handed over — never written, undefined; here `b` is cleared to transparent
// by its first pass.
- (id<MTLTexture>)encodeKawaseOn:(id<MTLTexture>)a other:(id<MTLTexture>)b passes:(uint32_t)passes offset:(float)offset
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!a || (passes > 0 && !b)) return nil;
    long allocW = (long)a.width, allocH = (long)a.height;
    for (uint32_t n = 0; n < 2 * passes; n++) {
        BOOL downscale = n < passes;
        uint32_t i = downscale ? n : n - passes;
        // let (src_shift, dst_shift) = if downscale { (i, i + 1) } else { (passes - i, passes - i - 1) };
        uint32_t srcShift = downscale ? i : passes - i;
        uint32_t dstShift = downscale ? i + 1 : passes - i - 1;
        long srcW = MAX(allocW >> srcShift, 1L), srcH = MAX(allocH >> srcShift, 1L);
        long dstW = MAX(allocW >> dstShift, 1L), dstH = MAX(allocH >> dstShift, 1L);
        // The tap distance is a UV offset over the whole texture.
        simd_float2 halfPixel = downscale ? simd_make_float2(1.0f / (float)srcW, 1.0f / (float)srcH)
                                          : simd_make_float2(0.5f / (float)srcW, 0.5f / (float)srcH);
        float passOffset = offset / (float)(1 << srcShift);

        BOOL whole = dstW == allocW && dstH == allocH;
        MTLLoadAction load = n == 0 ? MTLLoadActionClear : (whole ? MTLLoadActionDontCare : MTLLoadActionLoad);
        if (![self beginPassOn:b width:dstW height:dstH load:load clear:MTLClearColorMake(0, 0, 0, 0) commandBuffer:commandBuffer]) return nil;
        [_encoder setFragmentSamplerState:_resources.mirrorSampler atIndex:0];
        IFCUniforms u = IFCUniformsZero();
        // src_buf = (0, 0, src_w, src_h) of a texture of `alloc`: smithay's tex_matrix.
        IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)srcW, (CGFloat)srcH), (double)allocW, (double)allocH);
        u.blur = simd_make_float4(halfPixel.x, halfPixel.y, passOffset, 0.0f);
        [self rawDraw:(downscale ? IFCPipeBlurDown : IFCPipeBlurUp) dst:IFCRectIMake(0, 0, dstW, dstH) uniforms:&u texture:a];
        [self endPass];
        id<MTLTexture> swap = a;
        a = b;
        b = swap;
    }
    return a;
}

// This encode's background, once, as a texture the backdrop passes draw from:
// the background module computes from the pixel position and cannot be
// relocated. The texture is the output's size and is kept between encodes.
- (void)ensureBackgroundCopy:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (_bgTextureTried) return;
    _bgTextureTried = YES;
    IFBackgroundProgram *background = frame.background;
    if (!background || background.kind == IFBackgroundKindNone) return;
    if (!_bgCopy || (long)_bgCopy.width != c->outW || (long)_bgCopy.height != c->outH) {
        if (_bgCopy) [_graveyard bury:_bgCopy];
        _bgCopy = [self newBlurTextureWidth:c->outW height:c->outH];
    }
    if (![self beginPassOn:_bgCopy width:c->outW height:c->outH load:MTLLoadActionClear clear:MTLClearColorMake(0, 0, 0, 0)
             commandBuffer:commandBuffer]) {
        return;
    }
    IFBackgroundFrame bg = {frame.cameraX, frame.cameraY, c->frameZoom, frame.size.width, frame.size.height, c->s, frame.time};
    BOOL drew = [background encodeFrame:bg inEncoder:_encoder];
    [self endPass];
    if (drew) _bgTexture = _bgCopy;
}

// blur.rs, the per-window capture: everything below item `k` — the
// background, the outlines and every lower element with all its chrome, and
// no frost — over opaque black, moved so that output pixel `origin` lands on
// the texture's (0, 0), and confined to `clip` (texture pixels): the part of
// it that is on the output. Returns the number of draws that reached it.
- (NSUInteger)encodeBackdropBelow:(NSUInteger)k into:(id<MTLTexture>)texture width:(long)width height:(long)height
                           origin:(IFCRectI)origin clip:(IFCRectI)clip frame:(IFCompositorFrame *)frame
                              ctx:(const IFCFrameCtx *)c commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    // dt.render_output(renderer, &mut target, 0, &relocated, [0.0, 0.0, 0.0, 1.0])
    if (![self beginPassOn:texture width:width height:height load:MTLLoadActionClear clear:MTLClearColorMake(0, 0, 0, 1)
             commandBuffer:commandBuffer]) {
        return 0;
    }
    _internal = YES;
    _originX = origin.x;
    _originY = origin.y;
    _clip = clip;
    _drawsSubmitted = 0;
    if (_bgTexture) {
        IFCUniforms u = IFCUniformsZero();
        IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)_bgTexture.width, (CGFloat)_bgTexture.height), (double)_bgTexture.width,
                     (double)_bgTexture.height);
        [self draw:IFCPipeTexture dst:IFCRectIMake(0, 0, c->outW, c->outH) uniforms:&u texture:_bgTexture
           element:nil];
    }
    [self drawOutlines:frame scale:c->s viewportW:c->viewportW viewportH:c->viewportH];
    for (NSUInteger j = 0; j < k; j++) [self drawItem:&_items[j] frame:frame ctx:c];
    NSUInteger draws = _drawsSubmitted;
    [self endPass];
    _originX = _originY = 0;
    _internal = NO;
    return draws;
}

// Whether a lower element can put a pixel into `capture` (output pixels).
// Generous: its content grown by border, shadow and title bar, with slack for
// rounding; anything animated counts.
static BOOL IFCItemMayReach(const IFCItem *item, IFCRectI capture, double s, long titleBarHeight) {
    if (item->hasXform || item->element.kind == IFCompositorElementKindSnapshot) return YES;
    IFCompositorDecoration d = item->element.decoration;
    double k = s * item->g.zoom;
    double margin = (fabs((double)d.borderWidth) + ceil(fabs((double)d.shadowRadius)) + 3.0) * k + 4.0;
    double bar = (double)MAX(titleBarHeight, 0L) * k;
    double x0 = item->g.r.x * k - margin, y0 = item->g.r.y * k - margin - bar;
    double x1 = (item->g.r.x + item->g.r.w) * k + margin, y1 = (item->g.r.y + item->g.r.h) * k + margin;
    return x0 < (double)(capture.x + capture.w) && (double)capture.x < x1 && y0 < (double)(capture.y + capture.h) && (double)capture.y < y1;
}

// blur.rs `backdrop_fingerprint` + `ViewStamp` + the geometry generation:
// everything a window's frost is computed from. The window's own content is
// left out (the frost shows its shape, not its pixels), and so is every lower
// element that cannot reach the padded capture.
- (uint64_t)frostKeyForItem:(NSUInteger)k screen:(IFCRectI)screen capture:(IFCRectI)capture pad:(long)pad passes:(uint32_t)passes
                     offset:(float)offset frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    uint64_t h = 0xcbf29ce484222325ULL;
    IFC_MIX(&h, frame.size.width);
    IFC_MIX(&h, frame.size.height);
    IFC_MIX(&h, c->s);
    IFC_MIX(&h, frame.cameraX);
    IFC_MIX(&h, frame.cameraY);
    IFC_MIX(&h, c->frameZoom);
    IFC_MIX(&h, c->outW);
    IFC_MIX(&h, c->outH);
    IFC_MIX(&h, (uintptr_t)(__bridge void *)frame.background);
    IFC_MIX(&h, c->backgroundGeneration);
    IFC_MIX(&h, c->styleHash);
    IFC_MIX(&h, c->decorationScale);
    IFCMixColor(&h, frame.placeholderColor);
    IFCompositorOutlineSettings outline = frame.outline;
    IFCMixColor(&h, outline.color);
    IFC_MIX(&h, outline.thickness);
    IFC_MIX(&h, outline.opacity);
    NSUInteger outlineCount = frame.outlineRectCount;
    const CGRect *outlineRects = [frame ifc_outlineRects];
    IFC_MIX(&h, (uint64_t)outlineCount);
    for (NSUInteger i = 0; i < outlineCount; i++) IFCMixRect(&h, outlineRects[i]);
    IFC_MIX(&h, passes);
    IFC_MIX(&h, offset);
    IFC_MIX(&h, pad);
    IFCMix(&h, &screen, sizeof screen);
    IFCMix(&h, &capture, sizeof capture);

    const IFCItem *own = &_items[k];
    [own->element ifc_mix:&h content:NO];
    IFCMix(&h, &own->scissor, sizeof own->scissor);
    IFC_MIX(&h, (uint8_t)own->hasXform);
    if (own->hasXform) IFCMix(&h, &own->xform, sizeof own->xform);
    IFC_MIX(&h, own->lifeAlpha);

    long titleBarHeight = (long)frame.chrome.titleBarHeight;
    uint64_t lower = 0;
    for (NSUInteger j = 0; j < k; j++) {
        const IFCItem *item = &_items[j];
        if (!IFCItemMayReach(item, capture, c->s, titleBarHeight)) continue;
        lower++;
        [item->element ifc_mix:&h content:YES];
        IFCMix(&h, &item->scissor, sizeof item->scissor);
        IFC_MIX(&h, (uint8_t)item->hasXform);
        if (item->hasXform) IFCMix(&h, &item->xform, sizeof item->xform);
        IFC_MIX(&h, item->lifeAlpha);
        IFC_MIX(&h, item->progress);
        IFC_MIX(&h, (uint8_t)item->alphaOnly);
    }
    IFC_MIX(&h, lower);
    return h;
}

// blur.rs `process_blur_requests` for one window: bring its frost up to date.
- (void)prepareFrostOfItem:(NSUInteger)k frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c beat:(BOOL)beat
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    const IFCItem *item = &_items[k];
    IFCompositorElement *element = item->element;
    BOOL hasSSD = element.decoration.mode == IFCompositorDecorationModeServer;
    IFCEntry *entry = [self entryFor:element.identifier];
    entry->frostSeen = 0;
    if (!entry->frostInit) {
        // BlurCache::new
        entry->frostInit = YES;
        entry->frostForceFrames = kIFCBlurForceDirtyFrames;
        entry->frostWarmup = kIFCBlurMaskWarmupCommits;
        entry->frostHasContentId = NO;
    }

    IFCRectI screen = IFCBlurScreenRect(item->g, hasSSD, (long)frame.chrome.titleBarHeight, c->s);
    // window_animation.map_or(screen_rect, |anim| anim.transform_phys_rect(screen_rect))
    if (item->hasXform) screen = IFCTransformRect(screen, item->xform);
    // "no frost: the window has no on-screen extent"
    if (screen.w <= 0 || screen.h <= 0) return;
    // BlurCache::age_pads: reset below on the encodes that recompute.
    if (entry->padA && ++entry->padsIdle > kIFCBlurKeepFrames) [self retirePadsOf:entry];

    uint32_t passes = MIN(c->effects.blurRadius, kIFCBlurMaxPasses);
    // let blur_offset = state.config.effects.blur_strength as f32 * output_scale as f32;
    float offset = (float)c->effects.blurStrength * (float)c->s;
    long pad = IFCBlurPad(offset, passes);
    // pad_extent / padded_rect: the window's rectangle grown by the blur's reach.
    long padW = screen.w + 2 * pad, padH = screen.h + 2 * pad;
    if ((NSUInteger)padW > kIFCMaxTextureSide || (NSUInteger)padH > kIFCMaxTextureSide) return;
    IFCRectI padded = IFCRectIMake(screen.x - pad, screen.y - pad, padW, padH);
    // backdrop_capture: the part of it that has backdrop behind it.
    IFCRectI clipped;
    if (!IFCRectIIntersect(padded, IFCRectIMake(0, 0, c->outW, c->outH), &clipped)) {
        // "frost left unrendered: the padded capture is entirely off the output"
        return;
    }
    BOOL direct = clipped.x == padded.x && clipped.y == padded.y && clipped.w == padded.w && clipped.h == padded.h;

    uint64_t key = [self frostKeyForItem:k screen:screen capture:clipped pad:pad passes:passes offset:offset frame:frame ctx:c];
    uint64_t contentId = 0xcbf29ce484222325ULL;
    [element ifc_mixContentIdentity:&contentId];
    // Two re-capture budgets, as upstream: composed frames for a content that
    // arrives late, the window's own new content for a transparent first one.
    BOOL painted = entry->frostWarmup > 0 && entry->frostHasContentId && entry->frostContentId != contentId;
    BOOL forced = entry->frostForceFrames > 0 || painted;
    if (entry->frostForceFrames > 0) entry->frostForceFrames--;
    BOOL dirty = !entry->frostValid || entry->frostKey != key || beat || forced;

    if (!dirty) {
        entry->frostSeen = _generation;
        return;
    }

    // The window's own content as of this mask (`mask_commits`).
    if (entry->frostHasContentId && entry->frostContentId != contentId && entry->frostWarmup > 0) entry->frostWarmup--;
    entry->frostContentId = contentId;
    entry->frostHasContentId = YES;

    [self ensureBackgroundCopy:frame ctx:c commandBuffer:commandBuffer];
    // BlurCache::ensure_pads: the padded ping-pong pair, exactly the padded
    // extent and never quantised — the mip chain and the mirror are taken from
    // the textures' own extent. Reallocated only when that extent changes.
    if (!entry->padA || !entry->padB || entry->padW != padW || entry->padH != padH) {
        [self retirePadsOf:entry];
        entry->padA = [self newBlurTextureWidth:padW height:padH];
        entry->padB = [self newBlurTextureWidth:padW height:padH];
        if (!entry->padA || !entry->padB) {
            // "frost left unrendered: the padded ping-pong pair could not be allocated"
            entry->padA = entry->padB = nil;
            return;
        }
        entry->padW = padW;
        entry->padH = padH;
    }
    entry->padsIdle = 0;
    id<MTLTexture> padA = entry->padA, padB = entry->padB;
    NSUInteger draws = 0;
    if (direct) {
        // The padded rect fits on the output: capture straight into the pad.
        draws = [self encodeBackdropBelow:k into:padA width:padW height:padH origin:padded clip:IFCRectIMake(0, 0, padW, padH)
                                    frame:frame ctx:c commandBuffer:commandBuffer];
    } else {
        // It overhangs: capture the part that has backdrop, and fill the pad
        // from it mirrored about the output boundary. Upstream captures that
        // part into a scratch texture of exactly its size (one per extent,
        // so one per frame while such a window moves) and crops it with
        // MIRRORED_REPEAT; here it is captured in place inside the second pad
        // texture and reflected by `ifc_mirror_copy` — the same texels.
        IFCRectI part = IFCRectIMake(clipped.x - padded.x, clipped.y - padded.y, clipped.w, clipped.h);
        draws = [self encodeBackdropBelow:k into:padB width:padW height:padH origin:padded clip:part frame:frame ctx:c
                            commandBuffer:commandBuffer];
        if (draws && [self beginPassOn:padA width:padW height:padH load:MTLLoadActionDontCare clear:MTLClearColorMake(0, 0, 0, 0)
                         commandBuffer:commandBuffer]) {
            IFCUniforms u = IFCUniformsZero();
            u.rect = simd_make_float4((float)part.x, (float)part.y, (float)part.w, (float)part.h);
            u.size = simd_make_float2((float)padW, (float)padH);
            [self rawDraw:IFCPipeMirrorCopy dst:IFCRectIMake(0, 0, padW, padH) uniforms:&u texture:padB];
            [self endPass];
        } else {
            draws = 0;
        }
    }
    if (!draws) {
        // "frost zeroed: nothing is drawn beneath this surface to capture":
        // the capture would be the clear colour blurred into a black slab.
        entry->frostZeroed = YES;
        entry->frostValid = YES;
        entry->frostKey = key;
        entry->frostSeen = _generation;
        return;
    }

    id<MTLTexture> blurred = [self encodeKawaseOn:padA other:padB passes:passes offset:offset commandBuffer:commandBuffer];

    // The frost and the mask: the window's extent, allocated in steps so that
    // a zoom does not reallocate them on every frame (`quantized_alloc`).
    long allocW = IFCQuantizedExtent(screen.w, entry->frostAllocW), allocH = IFCQuantizedExtent(screen.h, entry->frostAllocH);
    if (!entry->frostTexture || !entry->maskTexture || allocW != entry->frostAllocW || allocH != entry->frostAllocH) {
        if (entry->frostTexture) [_graveyard bury:entry->frostTexture];
        if (entry->maskTexture) [_graveyard bury:entry->maskTexture];
        entry->frostTexture = [self newBlurTextureWidth:allocW height:allocH];
        entry->maskTexture = [self newBlurTextureWidth:allocW height:allocH];
        BOOL allocated = entry->frostTexture && entry->maskTexture;
        entry->frostAllocW = allocated ? allocW : 0;
        entry->frostAllocH = allocated ? allocH : 0;
    }
    id<MTLTexture> mask = entry->frostTexture ? entry->maskTexture : nil;
    BOOL built = NO;
    if (blurred && entry->frostTexture && mask) {
        // Keep only the centre: the window-sized region at (pad, pad).
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit copyFromTexture:blurred sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake((NSUInteger)pad, (NSUInteger)pad, 0)
                   sourceSize:MTLSizeMake((NSUInteger)screen.w, (NSUInteger)screen.h, 1) toTexture:entry->frostTexture
             destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];

        // The mask: the window's own elements — border, content, title bar,
        // not its shadow — drawn into a window-sized texture with the window's
        // origin at (0, 0), over transparent.
        if ([self beginPassOn:mask width:screen.w height:screen.h load:MTLLoadActionClear clear:MTLClearColorMake(0, 0, 0, 0)
                commandBuffer:commandBuffer]) {
            _skipShadow = YES;
            _internal = YES;
            _originX = screen.x;
            _originY = screen.y;
            [self drawItem:item frame:frame ctx:c];
            [self endPass];
            _originX = _originY = 0;
            _internal = NO;
            _skipShadow = NO;

            // Threshold its alpha and multiply the frost by it.
            if ([self beginPassOn:entry->frostTexture width:screen.w height:screen.h load:MTLLoadActionLoad
                            clear:MTLClearColorMake(0, 0, 0, 0) commandBuffer:commandBuffer]) {
                IFCUniforms u = IFCUniformsZero();
                IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)screen.w, (CGFloat)screen.h), (double)allocW, (double)allocH);
                [self rawDraw:IFCPipeBlurMask dst:IFCRectIMake(0, 0, screen.w, screen.h) uniforms:&u texture:mask];
                [self endPass];
                built = YES;
            }
        }
    }
    if (!built) {
        entry->frostValid = NO;
        return;
    }
    entry->frostW = screen.w;
    entry->frostH = screen.h;
    entry->frostRect = screen;
    entry->frostKey = key;
    entry->frostValid = YES;
    entry->frostZeroed = NO;
    entry->frostSeen = _generation;
}

// The frosts of this encode, before its own pass opens.
- (void)prepareFrosts:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    // blur.rs `shared_refresh_due`: the cadence every blurred window follows.
    // A change of view or of the background itself is always due; a
    // background that only moves on its own is due `animate_blur_fps` times
    // a second, and never at 0.
    uint64_t view = 0xcbf29ce484222325ULL;
    IFC_MIX(&view, frame.cameraX);
    IFC_MIX(&view, frame.cameraY);
    IFC_MIX(&view, c->frameZoom);
    IFC_MIX(&view, c->outW);
    IFC_MIX(&view, c->outH);
    IFC_MIX(&view, c->s);
    IFC_MIX(&view, (uintptr_t)(__bridge void *)frame.background);
    // blur.rs `background_structure_changed`, uncapped as the view is: a chunk
    // baked, uploaded or evicted is a background element added or removed.
    IFC_MIX(&view, c->backgroundGeneration);
    BOOL due = !_hasBlurBeat || view != _blurBeatView;
    uint32_t fps = c->effects.animateBlurFPS;
    if (!due && fps > 0 && frame.background.isAnimated && frame.time != _blurBeatTime) {
        // since_refresh >= Duration::from_secs_f64(1.0 / fps). Upstream measures
        // wall time; here the host's frame times are compared, and a tenth of
        // a millisecond of slack keeps a sum of display intervals (3 x 1/60 s
        // against 1/20 s) from falling short by a rounding error.
        due = frame.time < _blurBeatTime || frame.time - _blurBeatTime >= 1.0 / (double)fps - 1e-4;
    }
    if (due) {
        _hasBlurBeat = YES;
        _blurBeatView = view;
        _blurBeatTime = frame.time;
    }

    for (NSUInteger k = 0; k < _itemCount; k++) {
        IFCompositorElement *element = _items[k].element;
        if (!element.blur || element.kind != IFCompositorElementKindWindow) continue;
        [self prepareFrostOfItem:k frame:frame ctx:c beat:due commandBuffer:commandBuffer];
    }
    // The background copy is kept while frosts keep being recomputed from it.
    if (_bgTextureTried) {
        _bgCopyIdle = 0;
    } else if (_bgCopy && ++_bgCopyIdle > kIFCBlurKeepFrames) {
        [_graveyard bury:_bgCopy];
        _bgCopy = nil;
    }
    _bgTexture = nil;
    _bgTextureTried = NO;
}

// MARK: Frame

static unsigned IFCStackBucket(IFCompositorElementKind kind, IFCompositorStackLayer layer) {
    if (kind == IFCompositorElementKindSnapshot) return 2;
    switch (layer) {
        case IFCompositorStackLayerWidget: return 0;
        case IFCompositorStackLayerClosing: return 2;
        case IFCompositorStackLayerPinned: return 3;
        case IFCompositorStackLayerNormal:
        default: return 1;
    }
}

// This encode's elements, bottom to top: widgets, normal, closing, pinned
// (upstream's `all_elements` read backwards), each with its geometry and what
// its lifecycle animation makes of it.
- (void)collectItems:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    _itemCount = 0;
    _blurRequested = NO;
    NSArray<IFCompositorElement *> *elements = frame.elements;
    NSUInteger count = elements.count;
    if (count > _itemCapacity) {
        IFCItem *grown = realloc(_items, count * sizeof(IFCItem));
        if (!grown) return;
        _items = grown;
        _itemCapacity = count;
    }
    double s = c->s, frameZoom = c->frameZoom;
    IFCRectI output = IFCRectIMake(0, 0, c->outW, c->outH);
    // The canvas normally supplies its already-applied stack order. Verify it
    // against current kind/layer values, then collect directly instead of
    // enumerating every element once per bucket. Arbitrary caller order keeps
    // the original stable four-pass partition; no order is cached across frames.
    BOOL ordered = YES;
    unsigned previous = 0;
    if (count > 1) for (IFCompositorElement *element in elements) {
        unsigned bucket = IFCStackBucket(element.kind, element.layer);
        if (bucket < previous) { ordered = NO; break; }
        previous = bucket;
    }
    for (unsigned bucket = 0; bucket < (ordered ? 1u : 4u); bucket++) {
        for (IFCompositorElement *element in elements) {
            IFCompositorElementKind kind = element.kind;
            if (!ordered && IFCStackBucket(kind, element.layer) != bucket) continue;

            IFCGeom g;
            CGRect rect = element.rect;
            switch (element.space) {
                case IFCompositorSpacePinned:
                    g.r = (IFCRectD){rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
                    g.zoom = 1.0;
                    break;
                case IFCompositorSpaceOutput:
                    // Not upstream's arithmetic: the quotient is not `loc - camera`
                    // to the last bit and can lose a rounding tie (deviation 10).
                    g.r = (IFCRectD){rect.origin.x / frameZoom, rect.origin.y / frameZoom, rect.size.width / frameZoom, rect.size.height / frameZoom};
                    g.zoom = frameZoom;
                    break;
                case IFCompositorSpaceCanvas:
                default:
                    // render_loc = loc - camera
                    g.r = (IFCRectD){rect.origin.x - frame.cameraX, rect.origin.y - frame.cameraY, rect.size.width, rect.size.height};
                    g.zoom = frameZoom;
                    break;
            }
            if (!isfinite(g.r.x) || !isfinite(g.r.y) || !isfinite(g.r.w) || !isfinite(g.r.h) || g.r.w <= 0 || g.r.h <= 0) continue;

            IFCItem item;
            memset(&item, 0, sizeof item);
            item.element = element;
            item.g = g;
            item.scissor = output;
            item.lifeAlpha = 1.0f;
            if (element.hasClipRect) {
                CGRect clip = element.clipRect;
                long x0 = IFCRound(clip.origin.x * s), y0 = IFCRound(clip.origin.y * s);
                long x1 = IFCRound((clip.origin.x + clip.size.width) * s), y1 = IFCRound((clip.origin.y + clip.size.height) * s);
                if (!IFCRectIIntersect(IFCRectIMake(x0, y0, x1 - x0, y1 - y0), output, &item.scissor)) continue;
            }
            if (element.hasTransform) {
                item.hasXform = YES;
                item.xform = element.transform;
            }

            if (kind == IFCompositorElementKindSnapshot) {
                // The snapshot's transform is its own shrink.
                item.hasXform = NO;
            }
            if (element.lifecycle != IFCompositorLifecycleNone) {
                IFCLife life = IFCResolveLife(element, frame.time, c->effects);
                BOOL closing = life.kind == IFCompositorLifecycleClosing || life.kind == IFCompositorLifecycleClosingAlphaOnly;
                // A close that has run out is gone, as upstream drops the
                // snapshot (or the fade); an open that has run out is the
                // plain window.
                if (closing && life.finished) continue;
                if (kind == IFCompositorElementKindSnapshot) {
                    if (closing) {
                        item.progress = life.progress;
                        item.alphaOnly = life.kind == IFCompositorLifecycleClosingAlphaOnly;
                    }
                } else if (closing) {
                    // closing.rs `StandInFade` (mod.rs `FadeRender`): fade, and
                    // shrink toward the centre of the frame it occupied — the
                    // body plus the bar strip above it.
                    item.lifeAlpha = IFCompositorCloseAlpha(life.progress);
                    double shrink = life.kind == IFCompositorLifecycleClosingAlphaOnly
                                        ? 1.0
                                        : IFCompositorCloseScale(life.progress, c->effects.animationScale);
                    item.hasXform = NO;
                    if (shrink < 1.0) {
                        BOOL barAbove = kind == IFCompositorElementKindStandIn || element.decoration.mode == IFCompositorDecorationModeServer;
                        double bar = barAbove ? (double)frame.chrome.titleBarHeight : 0.0;
                        double w = g.r.w, h = g.r.h;
                        if (kind == IFCompositorElementKindStandIn) {
                            w = (double)MAX(IFCRound(w), 0L);
                            h = (double)MAX(IFCRound(h), 0L);
                        }
                        item.hasXform = YES;
                        item.xform = (IFCompositorTransform){(g.r.x + w / 2.0) * g.zoom * s, (g.r.y - bar / 2.0 + h / 2.0) * g.zoom * s,
                                                             0.0, 0.0, shrink, shrink};
                    }
                } else if (life.kind == IFCompositorLifecycleOpening && kind == IFCompositorElementKindWindow && !life.finished) {
                    // window_animation.rs `animated_visual`, the Open entry, and
                    // mod.rs `compose_frame`'s `WindowRenderAnimation` from it.
                    double scale = IFCompositorOpenScale(life.progress, c->effects.animationScale);
                    // scaled_about_centre(Rectangle::new(target_loc, target_size), scale)
                    double vw = g.r.w * scale, vh = g.r.h * scale;
                    double vx = g.r.x + (g.r.w - vw) / 2.0, vy = g.r.y + (g.r.h - vh) / 2.0;
                    float alpha = IFCompositorOpenAlpha(life.progress);
                    if (vx != g.r.x || vy != g.r.y || vw != g.r.w || vh != g.r.h || alpha != 1.0f) {
                        double physicalZoom = s * g.zoom;
                        item.hasXform = YES;
                        // origin: the content's top-left; offset: how far the visual
                        // rect moved; scale: content_scale(v.size, target_size, false)
                        item.xform = (IFCompositorTransform){g.r.x * physicalZoom, g.r.y * physicalZoom,
                                                             (vx - g.r.x) * physicalZoom, (vy - g.r.y) * physicalZoom,
                                                             vw / fmax(g.r.w, 1.0), vh / fmax(g.r.h, 1.0)};
                        item.lifeAlpha = alpha;
                    }
                }
            }
            if (element.blur && kind == IFCompositorElementKindWindow) _blurRequested = YES;
            _items[_itemCount++] = item;
        }
    }
}

- (BOOL)encodeFrame:(IFCompositorFrame *)frame intoTexture:(id<MTLTexture>)target commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!frame || !target || !commandBuffer || _resources.error) return NO;
    double s = (isfinite(frame.scale) && frame.scale > 0) ? frame.scale : 1.0;
    double frameZoom = (isfinite(frame.zoom) && frame.zoom > 0) ? frame.zoom : 1.0;
    long viewportW, viewportH;
    IFCPixelSize(frame, &viewportW, &viewportH, NULL, NULL);

    // From here on the command buffer samples this renderer's textures: what
    // is retired during or after this encode waits for it to complete.
    _generation++;
    _touched = 0;
    [_graveyard began];
    [commandBuffer addCompletedHandler:_completion];
    _skipShadow = NO;
    _hasXform = NO;
    _originX = _originY = 0;
    _internal = NO;
    _bake = NO;

    IFCFrameCtx ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.s = s;
    ctx.frameZoom = frameZoom;
    ctx.viewportW = viewportW;
    ctx.viewportH = viewportH;
    ctx.outW = (long)target.width;
    ctx.outH = (long)target.height;
    ctx.decorationScale = frame.decorationScale > 0 ? (long)frame.decorationScale : MAX(IFCCeil(s), 1L);
    ctx.styleHash = [frame.chrome ifc_hash];
    ctx.effects = IFCompositorEffectsSanitized(frame.effects);

    // Windows, bottom to top: widgets, normal, closing, pinned.
    [self collectItems:frame ctx:&ctx];

    // The frost of every blurred window, into textures of its own, before the
    // frame's pass opens. Nothing here runs unless an element asks for it.
    if (_blurRequested) {
        // A background with a chunk cache bakes or uploads inside its encode,
        // which comes after the frost keys: its chunk work for this frame is
        // done here instead, so that the frame a chunk lands in is the frame
        // that refreshes the frost. The same frame, field for field, as the
        // two encodes below: the cache answers each instant once.
        IFBackgroundFrame bg = {frame.cameraX, frame.cameraY, frameZoom, frame.size.width, frame.size.height, s, frame.time};
        ctx.backgroundGeneration = [frame.background chunkGenerationForFrame:bg];
        [self prepareFrosts:frame ctx:&ctx commandBuffer:commandBuffer];
    } else if (_hasBlurBeat || _bgCopy) {
        // No request left on this output: upstream's `remove_blur_caches`.
        _hasBlurBeat = NO;
        if (_bgCopy) [_graveyard bury:_bgCopy];
        _bgCopy = nil;
    }

    BOOL opaqueClear = frame.clear == IFCompositorClearOpaqueBlack;
    _pass.colorAttachments[0].texture = target;
    _pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, opaqueClear ? 1 : 0);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:_pass];
    _pass.colorAttachments[0].texture = nil;
    if (!encoder) return NO;

    _encoder = encoder;
    _boundPipeline = nil;
    _target = IFCRectIMake(0, 0, (long)target.width, (long)target.height);
    _clip = _target;
    _boundScissor = _target;

    // Background (upstream's `bg_elements`), replacing the cleared pixels.
    IFBackgroundProgram *background = frame.background;
    if (background) {
        IFBackgroundFrame bg = {frame.cameraX, frame.cameraY, frameZoom, frame.size.width, frame.size.height, s, frame.time};
        if ([background encodeFrame:bg inEncoder:encoder] && opaqueClear && background.isTransparent) {
            // The background wrote premultiplied colour with its own alpha;
            // over the opaque clear a source-over blend leaves alpha at 1.
            _boundPipeline = nil;
            IFCUniforms u = IFCUniformsZero();
            u.color = simd_make_float4(0, 0, 0, 1);
            [self draw:IFCPipeAlphaOne dst:_target uniforms:&u texture:nil element:nil];
        }
        _boundPipeline = nil;
    }
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];

    // Outlines of other outputs' viewports: above the background, below every window.
    [self drawOutlines:frame scale:s viewportW:viewportW viewportH:viewportH];

    for (NSUInteger i = 0; i < _itemCount; i++) [self drawItem:&_items[i] frame:frame ctx:&ctx];

    // The error bar: above every window (and, upstream, every layer surface).
    [self drawErrorBar:frame ctx:&ctx];

    [encoder endEncoding];
    _encoder = nil;
    _boundPipeline = nil;
    _itemCount = 0;

    // Drop what this output no longer shows.
    if ((NSUInteger)CFDictionaryGetCount(_entries) > _touched) {
        _scan.count = 0;
        _scan.generation = _generation;
        CFDictionaryApplyFunction(_entries, IFCCollectStale, &_scan);
        for (NSUInteger i = 0; i < _scan.count; i++) {
            const void *key = (const void *)_scan.keys[i];
            [_graveyard bury:(__bridge IFCEntry *)CFDictionaryGetValue(_entries, key)];
            CFDictionaryRemoveValue(_entries, key);
        }
        _flushCountdown = 3;
    }
    if (_flushCountdown > 0) {
        _flushCountdown--;
        if (_textureCache->ref) CVMetalTextureCacheFlush(_textureCache->ref, 0);
    }
    [self ifc_flushAgedTextures];
    return YES;
}

// MARK: Closing snapshot (closing.rs)

static IFCRectD IFCMergeRects(IFCRectD a, IFCRectD b) {
    double x0 = fmin(a.x, b.x), y0 = fmin(a.y, b.y);
    double x1 = fmax(a.x + a.w, b.x + b.w), y1 = fmax(a.y + a.h, b.y + b.h);
    return (IFCRectD){x0, y0, x1 - x0, y1 - y0};
}

- (IFCompositorElement *)closingSnapshotOfElement:(IFCompositorElement *)element inFrame:(IFCompositorFrame *)frame
                                     flattenScale:(double)flattenScale {
    if (!element || !frame || _resources.error || element.kind != IFCompositorElementKindWindow) return nil;
    // flatten(renderer, pixels, flatten_scale.max(1.0), chrome)
    double scale = (isfinite(flattenScale) && flattenScale > 1.0) ? flattenScale : 1.0;
    double frameZoom = (isfinite(frame.zoom) && frame.zoom > 0) ? frame.zoom : 1.0;
    CGRect rect = element.rect;
    // The window's geometry in logical pixels before any zoom.
    double unit = element.space == IFCompositorSpaceOutput ? frameZoom : 1.0;
    double w = rect.size.width / unit, h = rect.size.height / unit;
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(w) || !isfinite(h) || w <= 0 || h <= 0) return nil;

    IFCompositorDecoration deco = element.decoration;
    BOOL bare = deco.mode == IFCompositorDecorationModeNone;
    BOOL hasSSD = deco.mode == IFCompositorDecorationModeServer;
    long bw = bare ? 0 : MAX((long)deco.borderWidth, 0L);
    BOOL shadow = !bare && deco.shadow;
    IFCompositorChromeStyle *style = frame.chrome;

    // The picture's extent, with the content's top-left at the origin: the
    // body (content plus the SSD bar strip above it), the shadow's area and
    // the border's area. A bare window bakes its content alone.
    double bar = hasSSD ? (double)style.titleBarHeight : 0.0;
    IFCRectD body = {0.0, -bar, w, h + bar};
    IFCRectD bounds = body;
    if (shadow) {
        // shaders.rs `shadow_area_for(body)`
        long pad = IFCCeil((double)ceilf(deco.shadowRadius));
        IFCRectD area = {(double)(IFCRound(body.x) - pad), (double)(IFCRound(body.y) - pad), (double)(IFCRound(body.w) + 2 * pad),
                         (double)(IFCRound(body.h) + 2 * pad)};
        bounds = IFCMergeRects(bounds, area);
    }
    if (bw > 0) {
        // shaders.rs `border_area_for(body, border_width, scale)`
        float borderWPhys = (float)fmax(round((double)bw * scale), 1.0);
        long pad = IFCCeil(((double)borderWPhys + 1.0) / scale);
        IFCRectD area = {(double)(IFCRound(body.x) - pad), (double)(IFCRound(body.y) - pad), (double)(IFCRound(body.w) + 2 * pad),
                         (double)(IFCRound(body.h) + 2 * pad)};
        bounds = IFCMergeRects(bounds, area);
    }
    // closing.rs `phys_size_of`
    long physW = IFCCeil(bounds.w * scale), physH = IFCCeil(bounds.h * scale);
    if (physW <= 0 || physH <= 0 || (NSUInteger)physW > kIFCMaxTextureSide || (NSUInteger)physH > kIFCMaxTextureSide) return nil;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:(NSUInteger)physW
                                                                                 height:(NSUInteger)physH
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!texture || !commandBuffer) return nil;
    [_graveyard began];
    [commandBuffer addCompletedHandler:_completion];

    // Painter's order: shadow, border, content, bar, over transparent — the
    // window as a frame at zoom 1 and alpha 1 would draw it.
    BOOL began = [self beginPassOn:texture width:physW height:physH load:MTLLoadActionClear clear:MTLClearColorMake(0, 0, 0, 0)
                     commandBuffer:commandBuffer];
    if (began) {
        IFCFrameCtx ctx;
        memset(&ctx, 0, sizeof ctx);
        ctx.s = scale;
        ctx.frameZoom = 1.0;
        ctx.outW = physW;
        ctx.outH = physH;
        double frameScale = (isfinite(frame.scale) && frame.scale > 0) ? frame.scale : 1.0;
        ctx.decorationScale = frame.decorationScale > 0 ? (long)frame.decorationScale : MAX(IFCCeil(frameScale), 1L);
        ctx.styleHash = [style ifc_hash];
        ctx.effects = IFCompositorEffectsSanitized(frame.effects);
        IFCItem item;
        memset(&item, 0, sizeof item);
        item.element = element;
        item.g = (IFCGeom){{-bounds.x, -bounds.y, w, h}, 1.0};
        item.scissor = IFCRectIMake(0, 0, physW, physH);
        item.lifeAlpha = 1.0f;
        _skipShadow = NO;
        _originX = _originY = 0;
        _internal = YES;
        _bake = YES;
        [self drawItem:&item frame:frame ctx:&ctx];
        _internal = NO;
        _bake = NO;
        [self endPass];
    }
    [commandBuffer commit];
    if (!began) return nil;

    IFCompositorElement *snapshot = [IFCompositorElement new];
    snapshot.identifier = element.identifier;
    snapshot.kind = IFCompositorElementKindSnapshot;
    snapshot.space = element.space;
    snapshot.layer = IFCompositorStackLayerClosing;
    if (element.space == IFCompositorSpacePinned) {
        // snapshot_screen: screen_origin + bounds.loc.round(), bounds.size.to_i32_round()
        snapshot.rect = CGRectMake(rect.origin.x + round(bounds.x), rect.origin.y + round(bounds.y), (CGFloat)IFCRound(bounds.w),
                                   (CGFloat)IFCRound(bounds.h));
    } else {
        // snapshot_canvas: Rectangle::new(window_origin + bounds.loc, bounds.size)
        snapshot.rect = CGRectMake(rect.origin.x + bounds.x * unit, rect.origin.y + bounds.y * unit, bounds.w * unit, bounds.h * unit);
    }
    snapshot.hasClipRect = element.hasClipRect;
    snapshot.clipRect = element.clipRect;
    snapshot.texture = texture;
    snapshot.lifecycle = IFCompositorLifecycleClosing;
    snapshot.lifecycleProgress = 0.0;
    return snapshot;
}

// MARK: Offscreen export

- (id<MTLTexture>)renderOffscreen:(IFCompositorFrame *)frame error:(NSError **)error {
    NSUInteger w, h;
    IFCPixelSize(frame, NULL, NULL, &w, &h);
    if (_resources.error || w == 0 || h == 0 || w > kIFCMaxTextureSide || h > kIFCMaxTextureSide) {
        if (error) *error = [NSError errorWithDomain:IFCErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:
            _resources.error ?: [NSString stringWithFormat:@"invalid render size %lux%lu pixels", (unsigned long)w, (unsigned long)h]}];
        return nil;
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!target || !commandBuffer) {
        if (error) *error = [NSError errorWithDomain:IFCErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: @"could not allocate the render target"}];
        return nil;
    }
    BOOL encoded = [self encodeFrame:frame intoTexture:target commandBuffer:commandBuffer];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (!encoded || commandBuffer.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = commandBuffer.error ?: [NSError errorWithDomain:IFCErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey: @"the render did not complete"}];
        return nil;
    }
    return target;
}

static uint8_t *IFCCopyBytes(id<MTLTexture> texture) {
    NSUInteger w = texture.width, h = texture.height;
    uint8_t *bytes = malloc(w * h * 4);
    if (bytes) [texture getBytes:bytes bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    return bytes;
}

- (CGImageRef)newImageForFrame:(IFCompositorFrame *)frame error:(NSError **)error {
    id<MTLTexture> target = [self renderOffscreen:frame error:error];
    if (!target) return NULL;
    uint8_t *bytes = IFCCopyBytes(target);
    if (!bytes) return NULL;
    return IFCCreateImage(bytes, target.width, target.height, frame.clear == IFCompositorClearTransparent);
}
@end

// MARK: - Layer

// Frames the display took, counted where the presented handlers run. Keep the
// sample collection independent of the layer, whose last release stays on main.
typedef struct { double time,submitted,target,cameraX,cameraY,zoom; } IFCPresentationSample;
static const NSUInteger kIFCPresentationSamples=2048;
static int IFCComparePresentation(const void *a,const void *b) {
    double x=((const IFCPresentationSample *)a)->time,y=((const IFCPresentationSample *)b)->time;return (x>y)-(x<y);
}
static int IFCCompareInterval(const void *a,const void *b) {double x=*(const double *)a,y=*(const double *)b;return (x>y)-(x<y);}
@interface IFCPresentedCount : NSObject {
@public
    _Atomic NSUInteger shown;
    os_unfair_lock lock;
    IFCPresentationSample samples[2048];
    NSUInteger sampleCount,overflow,completed,errors,commandCompleted,notPresented;
    double previous,gpuSeconds,gpuWorst,previousCameraX,previousCameraY,previousZoom,completionSeconds,completionWorst;
    BOOL hasCamera;
}
- (IFCompositorPresentationStats)take:(double)interval;
@end
@implementation IFCPresentedCount
- (IFCompositorPresentationStats)take:(double)interval {
    IFCPresentationSample taken[2048];IFCompositorPresentationStats stats={0};double gpuTotal,completionTotal;
    os_unfair_lock_lock(&lock);stats.frames=sampleCount;memcpy(taken,samples,sampleCount*sizeof(*taken));sampleCount=0;
    stats.overflow=overflow;overflow=0;stats.completed=completed;completed=0;stats.errors=errors;errors=0;stats.notPresented=notPresented;notPresented=0;
    gpuTotal=gpuSeconds;gpuSeconds=0;stats.gpuWorst=gpuWorst;gpuWorst=0;
    stats.commandCompleted=commandCompleted;commandCompleted=0;completionTotal=completionSeconds;completionSeconds=0;stats.completionWorst=completionWorst;completionWorst=0;os_unfair_lock_unlock(&lock);
    // A GPU callback need not arrive in presentation order. Sort the actual
    // times before comparing refresh gaps; do not infer them from callback time.
    qsort(taken,stats.frames,sizeof(*taken),IFCComparePresentation);double gaps[2048],sum=0,latency=0;
    for(NSUInteger i=0;i<stats.frames;i++){
        IFCPresentationSample sample=taken[i];double gap=sample.time-previous;
        // Positive callbacks alone do not establish distinct display refreshes.
        // Keep repeated timestamps and callbacks older than the preceding batch
        // explicit; neither can manufacture a new presentation interval.
        if(previous>0){stats.duplicateTime+=gap==0;stats.reorderedTime+=gap<0;}
        if(previous>0&&gap>0){gaps[stats.intervals++]=gap;sum+=gap;stats.gapWorst=fmax(stats.gapWorst,gap);if(interval>0&&gap>interval*1.5)stats.missed+=(NSUInteger)llround(gap/interval)-1;}
        previous=fmax(previous,sample.time);double age=fmax(0,sample.time-sample.submitted);latency+=age;stats.latencyWorst=fmax(stats.latencyWorst,age);
        if(sample.target>0)stats.lateWorst=fmax(stats.lateWorst,sample.time-sample.target);
        if(hasCamera){if(sample.cameraX!=previousCameraX||sample.cameraY!=previousCameraY||sample.zoom!=previousZoom)stats.cameraChanged++;else stats.cameraRepeated++;}
        previousCameraX=sample.cameraX;previousCameraY=sample.cameraY;previousZoom=sample.zoom;hasCamera=YES;
    }
    if(stats.intervals){qsort(gaps,stats.intervals,sizeof(*gaps),IFCCompareInterval);stats.gapMean=sum/stats.intervals;stats.gapP99=gaps[(NSUInteger)ceil(stats.intervals*.99)-1];}
    if(previous>0)stats.presentationSilence=fmax(0,CACurrentMediaTime()-previous);
    if(stats.frames)stats.latencyMean=latency/stats.frames;if(stats.completed)stats.gpuMean=gpuTotal/stats.completed;
    if(stats.commandCompleted)stats.completionMean=completionTotal/stats.commandCompleted;return stats;
}
@end

// Acquire drawables away from input and the main run loop. Publish the ready
// set under a short lock on that worker: a display callback can consume it even
// when its main-queue notification has not run. Layer ownership stays on main,
// with at most one nextDrawable call pending and no queued scene descriptions.
@interface IFCDrawablePool : NSObject
- (instancetype)initWithLayer:(IFCompositorLayer *)layer;
- (id<CAMetalDrawable>)takeFrom:(IFCompositorLayer *)layer;
- (BOOL)waiting;
- (void)takeStats:(IFCompositorPresentationStats *)stats;
- (void)cancel;
@end
@implementation IFCDrawablePool {
    __weak IFCompositorLayer *_layer;
    dispatch_queue_t _queue;
    NSMutableArray<id<CAMetalDrawable>> *_ready;
    os_unfair_lock _lock;
    CGSize _size;
    uint64_t _generation;
    BOOL _transaction,_working,_cancelled,_notificationPending;
    NSUInteger _acquisitions,_timeouts;
    double _acquireSeconds,_acquireWorst,_acquireQueueWorst,_publishWorst,_notificationWorst;
}
- (instancetype)initWithLayer:(IFCompositorLayer *)layer {
    if(!(self=[super init]))return nil;
    _layer=layer;_ready=[NSMutableArray array];_size=layer.drawableSize;_transaction=layer.presentsWithTransaction;
    _queue=dispatch_queue_create("org.infinify.drawable",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    return self;
}
- (void)fill:(IFCompositorLayer *)layer {
    if(!layer)return;
    NSUInteger capacity=MIN((NSUInteger)2,MAX((NSUInteger)1,layer.maximumDrawableCount-1));
    os_unfair_lock_lock(&_lock);
    if(_cancelled||_working||_ready.count>=capacity){os_unfair_lock_unlock(&_lock);return;}
    _working=YES;uint64_t generation=_generation;CGSize wanted=_size;os_unfair_lock_unlock(&_lock);
    BOOL measured=layer.countsPresented;double queued=measured?CACurrentMediaTime():0;
    // Shared storage is cleared on main after the acquisition returns, so a
    // retired CALayer's final release cannot occur on the worker queue.
    __block IFCompositorLayer *held=layer;
    dispatch_async(_queue,^{@autoreleasepool{
        BOOL needsDemand=NO;
        // Replenish the bounded ready set without waiting for main to turn its
        // notification queue. A busy idle reconciliation must not delay the
        // next acquisition after the worker has already published one drawable.
        // The batch is bounded too; it never loops indefinitely holding a layer.
        for(NSUInteger attempt=0;attempt<capacity;attempt++){@autoreleasepool{
            os_unfair_lock_lock(&self->_lock);
            BOOL needed=!self->_cancelled&&generation==self->_generation&&self->_ready.count<capacity;
            os_unfair_lock_unlock(&self->_lock);if(!needed)break;
            double began=measured?CACurrentMediaTime():0;
            id<CAMetalDrawable> drawable=[held nextDrawable];
            double acquired=measured?CACurrentMediaTime():0;
            os_unfair_lock_lock(&self->_lock);
            BOOL valid=!self->_cancelled&&generation==self->_generation&&drawable&&drawable.texture.width==(NSUInteger)wanted.width&&drawable.texture.height==(NSUInteger)wanted.height;
            if(valid)[self->_ready addObject:drawable];
            BOOL notify=valid&&!self->_notificationPending;
            if(notify)self->_notificationPending=YES;
            if(measured){double wait=acquired-began;self->_acquisitions++;self->_timeouts+=!drawable;self->_acquireSeconds+=wait;self->_acquireWorst=fmax(self->_acquireWorst,wait);if(!attempt)self->_acquireQueueWorst=fmax(self->_acquireQueueWorst,began-queued);self->_publishWorst=fmax(self->_publishWorst,CACurrentMediaTime()-acquired);}
            os_unfair_lock_unlock(&self->_lock);
            if(!valid){needsDemand=YES;break;}
            if(notify)dispatch_async(dispatch_get_main_queue(),^{
                os_unfair_lock_lock(&self->_lock);self->_notificationPending=NO;BOOL available=!self->_cancelled&&self->_ready.count;
                if(measured)self->_notificationWorst=fmax(self->_notificationWorst,CACurrentMediaTime()-acquired);os_unfair_lock_unlock(&self->_lock);
                IFCompositorLayer *current=self->_layer;
                if(available&&current.drawableReady)current.drawableReady();
            });
        }}
        os_unfair_lock_lock(&self->_lock);self->_working=NO;os_unfair_lock_unlock(&self->_lock);
        dispatch_async(dispatch_get_main_queue(),^{
            held=nil;IFCompositorLayer *current=self->_layer;
            if(needsDemand){
                // A covered/asleep layer can return nil; a resized layer can
                // return an old size. Ask the owner to retry only if a scene
                // is still owed, rather than acquiring forever after the
                // frame driver stops or retrying an invalid size in a loop.
                if(current.drawableReady)current.drawableReady();
            }else [self fill:current];
        });
    }});
}
- (id<CAMetalDrawable>)takeFrom:(IFCompositorLayer *)layer {
    os_unfair_lock_lock(&_lock);
    if(_cancelled){os_unfair_lock_unlock(&_lock);return nil;}
    if(!CGSizeEqualToSize(_size,layer.drawableSize)||_transaction!=layer.presentsWithTransaction){_size=layer.drawableSize;_transaction=layer.presentsWithTransaction;_generation++;[_ready removeAllObjects];}
    id<CAMetalDrawable> drawable=_ready.firstObject;if(drawable)[_ready removeObjectAtIndex:0];
    os_unfair_lock_unlock(&_lock);[self fill:layer];return drawable;
}
- (BOOL)waiting {os_unfair_lock_lock(&_lock);BOOL waiting=!_cancelled&&_working&&!_ready.count;os_unfair_lock_unlock(&_lock);return waiting;}
- (void)takeStats:(IFCompositorPresentationStats *)stats {
    os_unfair_lock_lock(&_lock);
    stats->acquisitions=_acquisitions;stats->acquireTimeouts=_timeouts;stats->acquireMean=_acquisitions?_acquireSeconds/_acquisitions:0;stats->acquireWorst=_acquireWorst;stats->acquireQueueWorst=_acquireQueueWorst;stats->publishWorst=_publishWorst;stats->notificationWorst=_notificationWorst;
    _acquisitions=_timeouts=0;_acquireSeconds=_acquireWorst=_acquireQueueWorst=_publishWorst=_notificationWorst=0;os_unfair_lock_unlock(&_lock);
}
- (void)cancel {os_unfair_lock_lock(&_lock);_cancelled=YES;_generation++;[_ready removeAllObjects];os_unfair_lock_unlock(&_lock);_layer=nil;}
@end

@implementation IFCompositorLayer {
    BOOL _dirty;
    BOOL _hasLast;
    uint64_t _lastFingerprint;
    double _lastTime;
    BOOL _hasAnimateStamp;
    double _lastAnimate;  // upstream `background_last_animate`, in frame time
    IFCPresentedCount *_presented;  // made with the first handler; nil until `countsPresented`
    IFCDrawablePool *_drawables;
    BOOL _stopped;
}

- (NSUInteger)presentedCount {
    return _presented ? atomic_load(&_presented->shown) : 0;
}
- (IFCompositorPresentationStats)takePresentationStats {IFCompositorPresentationStats stats=_presented?[_presented take:_presentationInterval]:(IFCompositorPresentationStats){0};[_drawables takeStats:&stats];return stats;}
- (BOOL)drawablePending {return [_drawables waiting];}

- (instancetype)init {
    return [self initWithRenderer:nil];
}

- (instancetype)initWithRenderer:(IFCompositorRenderer *)renderer {
    if (!(self = [super init])) return nil;
    _renderer = renderer ?: [IFCompositorRenderer rendererWithDevice:nil];
    if (_renderer) self.device = _renderer.device;
    self.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    // The framebuffer holds sRGB-encoded values (see COMPOSITOR-NOTES.md, "Colour").
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    self.colorspace = srgb;
    CGColorSpaceRelease(srgb);
    self.opaque = YES;
    // Until the first frame is drawn; -updateWithFrame: decides it for each frame.
    self.presentsWithTransaction = YES;
    self.allowsNextDrawableTimeout = YES;
    self.needsDisplayOnBoundsChange = NO;
    self.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"contents": NSNull.null,
                     @"contentsScale": NSNull.null, @"hidden": NSNull.null, @"opacity": NSNull.null};
    _dirty = YES;
    return self;
}

// CALayer copies presentation layers through -initWithLayer:.
- (instancetype)initWithLayer:(id)layer {
    if (!(self = [super initWithLayer:layer])) return nil;
    if ([layer isKindOfClass:IFCompositorLayer.class]) _renderer = ((IFCompositorLayer *)layer)->_renderer;
    return self;
}

- (void)setNeedsRedraw {
    _dirty = YES;
}

- (void)stopDrawing { _stopped=YES;self.drawableReady=nil;[_drawables cancel];_drawables=nil; }

- (BOOL)updateWithFrame:(IFCompositorFrame *)frame {
    _missed = NO;
    if (_stopped || !frame || !_renderer) return NO;
    NSUInteger pxW, pxH;
    IFCPixelSize(frame, NULL, NULL, &pxW, &pxH);
    _needsContinuousRedraw = frame.needsContinuousRedraw;
    if (pxW == 0 || pxH == 0 || pxW > kIFCMaxTextureSide || pxH > kIFCMaxTextureSide) return NO;

    uint64_t fingerprint = [frame ifc_fingerprint];
    BOOL need = _dirty || !_hasLast || fingerprint != _lastFingerprint;
    // state/redraw.rs `background_animation_due`: every tick, or at most
    // `animate_fps` times a second.
    BOOL animateDue = NO;
    if ([frame ifc_backgroundAnimates] && (!_hasLast || _lastTime != frame.time)) {
        NSUInteger fps = frame.background.config.animateFPS;
        animateDue = fps == 0 || !_hasAnimateStamp || frame.time < _lastAnimate || frame.time - _lastAnimate >= 1.0 / (double)fps;
    }
    if (!need && !animateDue) {
        [_renderer ifc_flushAgedTextures];
        return NO;
    }

    CGSize drawableSize = CGSizeMake(pxW, pxH);
    // A first, resized or unpaced frame presents inside the host's
    // CATransaction. A paced, unchanged frame presents by command buffer
    // without waiting for scheduling.
    BOOL resized = !_hasLast || !CGSizeEqualToSize(self.drawableSize, drawableSize) || (frame.scale > 0 && self.contentsScale != frame.scale);
    BOOL transaction = resized || !_paced;
    if (self.presentsWithTransaction != transaction) self.presentsWithTransaction = transaction;
    if (self.contentsScale != frame.scale && frame.scale > 0) self.contentsScale = frame.scale;
    if (!CGSizeEqualToSize(self.drawableSize, drawableSize)) self.drawableSize = drawableSize;
    BOOL opaque = frame.clear == IFCompositorClearOpaqueBlack;
    if (self.opaque != opaque) self.opaque = opaque;

    double presentationTarget=_presentationTime;
    if(!_drawables)_drawables=[[IFCDrawablePool alloc]initWithLayer:self];
    id<CAMetalDrawable> drawable=[_drawables takeFrom:self];
    if(!drawable){_missed=YES;return NO;}
    id<MTLCommandBuffer> commandBuffer = [_renderer.commandQueue commandBuffer];
    if (!commandBuffer) {  // still dirty: the next update retries
        _missed = YES;
        return NO;
    }
    if (![_renderer encodeFrame:frame intoTexture:drawable.texture commandBuffer:commandBuffer]) {
        [commandBuffer commit];
        return NO;
    }

    if (_countsPresented) {
        // The handler runs off the main thread and keeps the count, not the layer: a layer's last release stays the host's.
        if (!_presented) _presented = [IFCPresentedCount new];
        IFCPresentedCount *count = _presented;
        double submitted=CACurrentMediaTime(),target=_paced?presentationTarget:0;
        // Copy the camera used to encode, not its later mutable description.
        // A new background clock or captured buffer is not a new camera step.
        double cameraX=frame.cameraX,cameraY=frame.cameraY,zoom=frame.zoom;
        [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
            if(shown.presentedTime<=0){os_unfair_lock_lock(&count->lock);count->notPresented++;os_unfair_lock_unlock(&count->lock);return;}atomic_fetch_add(&count->shown,1);
            os_unfair_lock_lock(&count->lock);
            if(count->sampleCount<kIFCPresentationSamples)count->samples[count->sampleCount++]=(IFCPresentationSample){shown.presentedTime,submitted,target,cameraX,cameraY,zoom};else count->overflow++;
            os_unfair_lock_unlock(&count->lock);
        }];
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> done){double elapsed=done.GPUEndTime-done.GPUStartTime,completion=fmax(0,CACurrentMediaTime()-submitted);
            os_unfair_lock_lock(&count->lock);if(done.status==MTLCommandBufferStatusError)count->errors++;
            count->commandCompleted++;count->completionSeconds+=completion;count->completionWorst=fmax(count->completionWorst,completion);
            if(elapsed>0){count->completed++;count->gpuSeconds+=elapsed;count->gpuWorst=fmax(count->gpuWorst,elapsed);}os_unfair_lock_unlock(&count->lock);
        }];
    }
    if (self.presentsWithTransaction) {
        [commandBuffer commit];
        [commandBuffer waitUntilScheduled];
        [drawable present];
    } else {
        if(presentationTarget>0)[commandBuffer presentDrawable:drawable atTime:presentationTarget];else [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
    if (animateDue) {
        _lastAnimate = frame.time;
        _hasAnimateStamp = YES;
    }
    _lastFingerprint = fingerprint;
    _lastTime = frame.time;
    _hasLast = YES;
    _dirty = NO;
    _drawCount++;
    return YES;
}
@end
