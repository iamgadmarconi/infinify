// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer — see IFBackground.h and BACKGROUND-NOTES.md.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. The three built-in fragment
// shaders below are hand translations of upstream GLSL; each carries the
// upstream path and SHA-256 of the file it was translated from.

#import "IFBackground.h"
#import "IFBGTiffSource.h"
#import "DWMetalSupport.h"

#import <Accelerate/Accelerate.h>
#import <AppKit/NSImage.h>
#import <ImageIO/ImageIO.h>
#import <simd/simd.h>

#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *const IFBGErrorDomain = @"IFBackgroundErrorDomain";

// Largest 2D texture on every Apple-silicon GPU.
static const NSUInteger kIFBGMaxTextureSide = 16384;

// MARK: - Uniform block

// Must match `struct IFBGUniforms` in kIFBGCommonMSL (80 bytes, 16-byte aligned).
typedef struct {
    simd_float2 camera;        // u_camera
    simd_float2 size;          // `size` / u_output_size: visible canvas area in canvas pixels
    simd_float2 dest_px;       // element extent in physical pixels: v_coords = pixel centre / dest_px
    simd_float2 texture_size;  // u_tile_size / u_texture_size
    simd_float2 src_origin;    // sampled sub-rect of the image, normalised (wallpaper cover crop)
    simd_float2 src_size;
    float time;                // u_time
    float zoom;                // u_zoom
    float alpha;               // smithay's `alpha`: always 1.0 for a background
    float opaque;              // 1.0 when composited opaque (output alpha forced to 1)
    simd_float4 wallpaper_fill; // opaque macOS fill; alpha 0 preserves upstream image alpha
} IFBGUniforms;

_Static_assert(sizeof(IFBGUniforms) == 80, "IFBGUniforms layout must match the MSL struct");

// MARK: - Metal sources

// Shared by the built-in library and every translated user shader.
static NSString *const kIFBGCommonMSL =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct IFBGUniforms {\n"
     "    float2 camera;\n"
     "    float2 size;\n"
     "    float2 dest_px;\n"
     "    float2 texture_size;\n"
     "    float2 src_origin;\n"
     "    float2 src_size;\n"
     "    float time;\n"
     "    float zoom;\n"
     "    float alpha;\n"
     "    float opaque;\n"
     "    float4 wallpaper_fill;\n"
     "};\n"
     "struct IFBGVertexOut { float4 position [[position]]; };\n"
     // smithay's `v_coords`: the element's 0..1 extent mapped through its
     // texture matrix. Metal's [[position]] is the pixel centre, origin top-left.
     "static inline float2 ifbg_v_coords(float4 position, constant IFBGUniforms &U) {\n"
     "    return U.src_origin + (position.xy / U.dest_px) * U.src_size;\n"
     "}\n"
     // A background that is not transparent is composited opaque: upstream docs/shaders.md,
     // "The alpha component ... is ignored by default". On upstream's texture path
     // (tile, wallpaper, textured shader) smithay draws the element's opaque region
     // with blending off, so this is exactly what reaches the screen. On the plain
     // pixel-shader path smithay 0.7.0 leaves blending on, so a shader writing
     // alpha < 1 without `transparent_shader` blends over stale framebuffer
     // contents there; forcing alpha to 1 is a deliberate deviation (BACKGROUND-NOTES.md,
     // section 8).
     "static inline float4 ifbg_finish(float4 color, constant IFBGUniforms &U) {\n"
     "    return U.opaque > 0.5 ? float4(color.rgb, 1.0) : color;\n"
     "}\n";

static NSString *const kIFBGBuiltinMSL =
    // One triangle covering the target.
    @"vertex IFBGVertexOut ifbg_vertex(uint vid [[vertex_id]]) {\n"
     "    IFBGVertexOut out;\n"
     "    out.position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? -3.0 : 1.0, 0.0, 1.0);\n"
     "    return out;\n"
     "}\n"
     // GLSL mod(): x - y * floor(x / y). Not Metal's fmod(), which truncates.
     "static inline float2 ifbg_mod(float2 x, float y) { return x - y * floor(x / y); }\n"
     "static inline float2 ifbg_mod(float2 x, float2 y) { return x - y * floor(x / y); }\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/dot_grid.glsl
     // sha256 a2dde8d16cc974ab3d0192020b30c2f60da8620216952eb36fac0f72a83d5683
     // ------------------------------------------------------------------
     "fragment float4 ifbg_dot_grid(IFBGVertexOut in [[stage_in]],\n"
     "                              constant IFBGUniforms &U [[buffer(0)]]) {\n"
     "    const float4 BG_COLOR = float4(0.0, 0.0, 0.0, 1.0);\n"
     "    const float4 DOT_COLOR = float4(1.0, 1.0, 1.0, 1.0);\n"
     "    const float DOT_SPACING = 80.0;\n"
     "    const float DOT_RADIUS = 1.0;\n"
     "    float2 v_coords = ifbg_v_coords(in.position, U);\n"
     "    float2 size = U.size;\n"
     "    float2 u_camera = U.camera;\n"
     "\n"
     "    float2 screen_pixel = v_coords * size;\n"
     "    float2 canvas_pos = screen_pixel + ifbg_mod(u_camera, DOT_SPACING);\n"
     "\n"
     "    float2 grid = ifbg_mod(canvas_pos, DOT_SPACING);\n"
     "    float2 dist = min(grid, DOT_SPACING - grid);\n"
     "    float d = length(dist);\n"
     "\n"
     "    float dot_alpha = 1.0 - smoothstep(DOT_RADIUS - 0.5, DOT_RADIUS + 0.5, d);\n"
     "\n"
     "    return ifbg_finish(mix(BG_COLOR, DOT_COLOR, dot_alpha), U);\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/tile_bg.glsl
     // sha256 f30921426cc816cead08a580937db5edc30977448997e1819a9c2865c053e839
     // Two entry points for the two programs upstream compiles from it: plain,
     // and with `#define MIRROR` prepended. The NO_ALPHA variant is never
     // selected for a background (images are always uploaded as RGBA8).
     // ------------------------------------------------------------------
     "fragment float4 ifbg_tile(IFBGVertexOut in [[stage_in]],\n"
     "                          constant IFBGUniforms &U [[buffer(0)]],\n"
     "                          texture2d<float> tex [[texture(0)]],\n"
     "                          sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifbg_v_coords(in.position, U);\n"
     "    float alpha = U.alpha;\n"
     "    float2 u_camera = U.camera;\n"
     "    float2 u_tile_size = U.texture_size;\n"
     "    float2 u_output_size = U.size;\n"
     "\n"
     "    float2 screen_pixel = v_coords * u_output_size;\n"
     "    float2 canvas_pos = screen_pixel + ifbg_mod(u_camera, u_tile_size);\n"
     "    float2 centered = canvas_pos + floor(u_tile_size * 0.5);\n"
     "    float2 uv = ifbg_mod(centered, u_tile_size) / u_tile_size;\n"
     "    float4 color = tex.sample(smp, uv);\n"
     "    return ifbg_finish(color * alpha, U);\n"
     "}\n"
     "\n"
     "fragment float4 ifbg_tile_mirror(IFBGVertexOut in [[stage_in]],\n"
     "                                 constant IFBGUniforms &U [[buffer(0)]],\n"
     "                                 texture2d<float> tex [[texture(0)]],\n"
     "                                 sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifbg_v_coords(in.position, U);\n"
     "    float alpha = U.alpha;\n"
     "    float2 u_camera = U.camera;\n"
     "    float2 u_tile_size = U.texture_size;\n"
     "    float2 u_output_size = U.size;\n"
     "\n"
     "    float2 screen_pixel = v_coords * u_output_size;\n"
     "    float2 canvas_pos = screen_pixel + ifbg_mod(u_camera, 2.0 * u_tile_size);\n"
     "    float2 centered = canvas_pos + floor(u_tile_size * 0.5);\n"
     "    float2 uv = 1.0 - abs(1.0 - ifbg_mod(centered / u_tile_size, 2.0));\n"
     "    float4 color = tex.sample(smp, uv);\n"
     "    return ifbg_finish(color * alpha, U);\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/wallpaper_bg.glsl
     // sha256 50a2605d87382512f40d5cfe4207f837cb3c6a57afb5656af7b2d6d3a028f463
     // macOS extension: inherited fit/centre images have an opaque fill around
     // the image and beneath its alpha. Explicit images keep upstream alpha.
     // ------------------------------------------------------------------
     "fragment float4 ifbg_wallpaper(IFBGVertexOut in [[stage_in]],\n"
     "                               constant IFBGUniforms &U [[buffer(0)]],\n"
     "                               texture2d<float> tex [[texture(0)]],\n"
     "                               sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifbg_v_coords(in.position, U);\n"
     "    float alpha = U.alpha;\n"
     "\n"
     "    if (U.wallpaper_fill.a > 0.5 && (any(v_coords < 0.0) || any(v_coords > 1.0))) return U.wallpaper_fill;\n"
     "    float4 color = tex.sample(smp, v_coords);\n"
     "    if (U.wallpaper_fill.a > 0.5) color = float4(mix(U.wallpaper_fill.rgb, color.rgb, color.a), 1.0);\n"
     "    return ifbg_finish(color * alpha, U);\n"
     "}\n";

// Must match `struct IFBGChunkUniforms` in kIFBGChunkMSL (48 bytes).
typedef struct {
    simd_float4 dst;       // the chunk's rectangle in target pixels: x0, y0, x1, y1
    simd_float4 src;       // the texels it shows: origin, then size
    simd_float2 target;    // the render target's size in pixels
    simd_float2 tex_size;  // the texture's size in texels
} IFBGChunkUniforms;

_Static_assert(sizeof(IFBGChunkUniforms) == 48, "IFBGChunkUniforms layout must match the MSL struct");

// One cached chunk: a quad at its own rectangle of the target, where the other
// built-ins cover the target with one triangle. Appended to the built-in library.
static NSString *const kIFBGChunkMSL =
    @"struct IFBGChunkUniforms {\n"
     "    float4 dst;\n"
     "    float4 src;\n"
     "    float2 target;\n"
     "    float2 tex_size;\n"
     "};\n"
     "vertex IFBGVertexOut ifbg_chunk_vertex(uint vid [[vertex_id]],\n"
     "                                       constant IFBGChunkUniforms &C [[buffer(0)]]) {\n"
     "    IFBGVertexOut out;\n"
     "    float2 p = float2((vid & 1) != 0 ? C.dst.z : C.dst.x, (vid & 2) != 0 ? C.dst.w : C.dst.y);\n"
     "    out.position = float4(p.x / C.target.x * 2.0 - 1.0, 1.0 - p.y / C.target.y * 2.0, 0.0, 1.0);\n"
     "    return out;\n"
     "}\n"
     "\n"
     // ------------------------------------------------------------------
     // Hand translation of upstream src/shaders/chunk_bg.glsl
     // sha256 ee97fa3361ef758e155bbd440b2672865052073eea2a344bf8882737fa2e29a0
     // `alpha` is declared there by convention and not multiplied in: a chunk
     // is opaque whatever its texture holds.
     // ------------------------------------------------------------------
     "fragment float4 ifbg_chunk(IFBGVertexOut in [[stage_in]],\n"
     "                           constant IFBGChunkUniforms &C [[buffer(0)]],\n"
     "                           texture2d<float> tex [[texture(0)]],\n"
     "                           sampler smp [[sampler(0)]]) {\n"
     // smithay's `v_coords` for a textured element: the element's 0..1 extent
     // mapped onto its `src` rectangle of the texture, per fragment like
     // ifbg_v_coords above.
     "    float2 v_coords = (C.src.xy + (in.position.xy - C.dst.xy) / (C.dst.zw - C.dst.xy) * C.src.zw) / C.tex_size;\n"
     "\n"
     "    float3 color = tex.sample(smp, v_coords).rgb;\n"
     "    return float4(color, 1.0);\n"
     "}\n";

// GLSL ES 1.00 names for a translated user shader. Everything here is either a
// GLSL keyword or a GLSL built-in, so it cannot collide with a legal user name.
static NSString *IFBGUserPreludeMSL(void) {
    static NSString *prelude;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *s = [NSMutableString string];
        [s appendString:
            @"#define GL_ES 1\n"
             "#define GL_FRAGMENT_PRECISION_HIGH 1\n"
             "typedef float2 vec2; typedef float3 vec3; typedef float4 vec4;\n"
             "typedef int2 ivec2; typedef int3 ivec3; typedef int4 ivec4;\n"
             "typedef bool2 bvec2; typedef bool3 bvec3; typedef bool4 bvec4;\n"
             "typedef float2x2 mat2; typedef float3x3 mat3; typedef float4x4 mat4;\n"
             "struct sampler2D { int unit; };\n"
             "struct samplerCube { int unit; };\n"];
        NSArray<NSString *> *floats = @[@"float", @"float2", @"float3", @"float4"];
        for (NSString *t in floats) {
            // GLSL built-ins whose Metal spelling or semantics differ.
            [s appendFormat:@"static inline %1$@ mod(%1$@ x, %1$@ y) { return x - y * floor(x / y); }\n", t];
            [s appendFormat:@"static inline %1$@ atan(%1$@ y, %1$@ x) { return metal::atan2(y, x); }\n", t];
            [s appendFormat:@"static inline %1$@ inversesqrt(%1$@ x) { return metal::rsqrt(x); }\n", t];
            [s appendFormat:@"static inline %1$@ radians(%1$@ x) { return x * 0.017453292519943295; }\n", t];
            [s appendFormat:@"static inline %1$@ degrees(%1$@ x) { return x * 57.29577951308232; }\n", t];
            [s appendFormat:@"static inline %1$@ dFdx(%1$@ x) { return metal::dfdx(x); }\n", t];
            [s appendFormat:@"static inline %1$@ dFdy(%1$@ x) { return metal::dfdy(x); }\n", t];
            if (![t isEqualToString:@"float"]) {
                [s appendFormat:@"static inline %1$@ mod(%1$@ x, float y) { return x - y * floor(x / y); }\n", t];
            }
        }
        // genType geometric functions exist for scalars in GLSL but not in Metal.
        [s appendString:
            @"static inline float length(float x) { return metal::fabs(x); }\n"
             "static inline float distance(float a, float b) { return metal::fabs(a - b); }\n"
             "static inline float dot(float a, float b) { return a * b; }\n"
             "static inline float normalize(float x) { return metal::sign(x); }\n"
             "static inline float reflect(float i, float n) { return i - 2.0 * (n * i) * n; }\n"
             "static inline float faceforward(float n, float i, float nref) { return nref * i < 0.0 ? n : -n; }\n"
             "static inline mat2 matrixCompMult(mat2 a, mat2 b) { return mat2(a[0] * b[0], a[1] * b[1]); }\n"
             "static inline mat3 matrixCompMult(mat3 a, mat3 b) { return mat3(a[0] * b[0], a[1] * b[1], a[2] * b[2]); }\n"
             "static inline mat4 matrixCompMult(mat4 a, mat4 b) { return mat4(a[0] * b[0], a[1] * b[1], a[2] * b[2], a[3] * b[3]); }\n"];
        [s appendString:
            @"static inline float gl_if_f(float v) { return v; }\n"
             "static inline float gl_if_f(int v) { return float(v); }\n"
             "static inline float gl_if_f(bool v) { return v ? 1.0 : 0.0; }\n"
             "static inline int gl_if_i(float v) { return int(v); }\n"
             "static inline int gl_if_i(int v) { return v; }\n"
             "static inline int gl_if_i(bool v) { return v ? 1 : 0; }\n"
             "static inline bool gl_if_b(float v) { return v != 0.0; }\n"
             "static inline bool gl_if_b(int v) { return v != 0; }\n"
             "static inline bool gl_if_b(bool v) { return v; }\n"];
        // (Every conversion is declared before the first template that uses it.)
        for (int n = 2; n <= 4; n++) {
            [s appendFormat:@"static inline float%1$d gl_if_f(float%1$d v) { return v; }\n", n];
            [s appendFormat:@"static inline float%1$d gl_if_f(int%1$d v) { return float%1$d(v); }\n", n];
            [s appendFormat:@"static inline float%1$d gl_if_f(bool%1$d v) { return float%1$d(v); }\n", n];
            [s appendFormat:@"static inline int%1$d gl_if_i(float%1$d v) { return int%1$d(v); }\n", n];
            [s appendFormat:@"static inline int%1$d gl_if_i(int%1$d v) { return v; }\n", n];
            [s appendFormat:@"static inline int%1$d gl_if_i(bool%1$d v) { return int%1$d(v); }\n", n];
            [s appendFormat:@"static inline bool%1$d gl_if_b(float%1$d v) { return v != 0.0; }\n", n];
            [s appendFormat:@"static inline bool%1$d gl_if_b(int%1$d v) { return v != 0; }\n", n];
            [s appendFormat:@"static inline bool%1$d gl_if_b(bool%1$d v) { return v; }\n", n];
        }
        // Matrix constructors fill column-major from any mix of scalars and vectors.
        [s appendString:
            @"struct gl_if_acc { float v[16]; int n; };\n"
             "static inline void gl_if_put(thread gl_if_acc &a, float x) { if (a.n < 16) a.v[a.n] = x; a.n++; }\n"
             "static inline void gl_if_put(thread gl_if_acc &a, float2 x) { gl_if_put(a, x.x); gl_if_put(a, x.y); }\n"
             "static inline void gl_if_put(thread gl_if_acc &a, float3 x) { gl_if_put(a, x.xy); gl_if_put(a, x.z); }\n"
             "static inline void gl_if_put(thread gl_if_acc &a, float4 x) { gl_if_put(a, x.xy); gl_if_put(a, x.zw); }\n"
             "static inline mat2 gl_if_mat2(float a, float b, float c, float d) { return mat2(float2(a, b), float2(c, d)); }\n"
             "static inline mat2 gl_if_mat2(float2 a, float2 b) { return mat2(a, b); }\n"
             "static inline mat2 gl_if_mat2(float4 v) { return mat2(v.xy, v.zw); }\n"
             "static inline mat3 gl_if_mat3(float a, float b, float c, float d, float e, float f, float g, float h, float i) {"
             " return mat3(float3(a, b, c), float3(d, e, f), float3(g, h, i)); }\n"
             "static inline mat3 gl_if_mat3(float3 a, float3 b, float3 c) { return mat3(a, b, c); }\n"
             "static inline mat4 gl_if_mat4(float4 a, float4 b, float4 c, float4 d) { return mat4(a, b, c, d); }\n"
             "template <typename... A> static inline mat2 gl_if_mat2(A... a) {\n"
             "    gl_if_acc acc = {}; int each[] = {(gl_if_put(acc, gl_if_f(a)), 0)...}; (void)each;\n"
             "    return mat2(float2(acc.v[0], acc.v[1]), float2(acc.v[2], acc.v[3]));\n"
             "}\n"
             "template <typename... A> static inline mat3 gl_if_mat3(A... a) {\n"
             "    gl_if_acc acc = {}; int each[] = {(gl_if_put(acc, gl_if_f(a)), 0)...}; (void)each;\n"
             "    return mat3(float3(acc.v[0], acc.v[1], acc.v[2]), float3(acc.v[3], acc.v[4], acc.v[5]), float3(acc.v[6], acc.v[7], acc.v[8]));\n"
             "}\n"
             "template <typename... A> static inline mat4 gl_if_mat4(A... a) {\n"
             "    gl_if_acc acc = {}; int each[] = {(gl_if_put(acc, gl_if_f(a)), 0)...}; (void)each;\n"
             "    return mat4(float4(acc.v[0], acc.v[1], acc.v[2], acc.v[3]), float4(acc.v[4], acc.v[5], acc.v[6], acc.v[7]),\n"
             "                float4(acc.v[8], acc.v[9], acc.v[10], acc.v[11]), float4(acc.v[12], acc.v[13], acc.v[14], acc.v[15]));\n"
             "}\n"];
        NSArray<NSString *> *swizzle = @[@"", @"", @"xy", @"xyz", @"xyzw"];
        for (int n = 2; n <= 4; n++) {
            // Relational built-ins: Metal uses operators on vectors.
            for (NSString *base in @[@"float", @"int"]) {
                NSDictionary<NSString *, NSString *> *ops = @{
                    @"lessThan": @"<", @"lessThanEqual": @"<=", @"greaterThan": @">",
                    @"greaterThanEqual": @">=", @"equal": @"==", @"notEqual": @"!="};
                for (NSString *name in ops) {
                    [s appendFormat:@"static inline bool%1$d %2$@(%3$@%1$d a, %3$@%1$d b) { return a %4$@ b; }\n",
                                    n, name, base, ops[name]];
                }
            }
            [s appendFormat:@"static inline bool%1$d equal(bool%1$d a, bool%1$d b) { return a == b; }\n", n];
            [s appendFormat:@"static inline bool%1$d notEqual(bool%1$d a, bool%1$d b) { return a != b; }\n", n];
            // GLSL's built-in not(). `not` itself is C++'s spelling of `!`, so
            // the translator renames every `not` like any other reserved word.
            [s appendFormat:@"static inline bool%1$d not_glsl(bool%1$d v) { return !v; }\n", n];

            // Constructors. GLSL converts every argument to the constructed
            // type's component type (vec3(bvec2, 1) is legal) and, given one
            // vector, drops its extra components; Metal's constructors do
            // neither. The translator routes every vecN/ivecN/bvecN/matN
            // constructor call to these shims (see IFBGTranslateGLSL).
            // General form: any mix of scalars and vectors.
            [s appendFormat:@"template <typename... A> static inline float%1$d gl_if_vec%1$d(A... a) { return float%1$d(gl_if_f(a)...); }\n", n];
            [s appendFormat:@"template <typename... A> static inline int%1$d gl_if_ivec%1$d(A... a) { return int%1$d(gl_if_i(a)...); }\n", n];
            [s appendFormat:@"template <typename... A> static inline bool%1$d gl_if_bvec%1$d(A... a) { return bool%1$d(gl_if_b(a)...); }\n", n];
            // One argument: a scalar is splatted, a larger vector truncated.
            [s appendFormat:@"static inline float%1$d gl_if_vec%1$d(float v) { return float%1$d(v); }\n", n];
            [s appendFormat:@"static inline float%1$d gl_if_vec%1$d(int v) { return float%1$d(float(v)); }\n", n];
            [s appendFormat:@"static inline float%1$d gl_if_vec%1$d(bool v) { return float%1$d(v ? 1.0 : 0.0); }\n", n];
            [s appendFormat:@"static inline int%1$d gl_if_ivec%1$d(float v) { return int%1$d(int(v)); }\n", n];
            [s appendFormat:@"static inline int%1$d gl_if_ivec%1$d(int v) { return int%1$d(v); }\n", n];
            [s appendFormat:@"static inline int%1$d gl_if_ivec%1$d(bool v) { return int%1$d(v ? 1 : 0); }\n", n];
            [s appendFormat:@"static inline bool%1$d gl_if_bvec%1$d(float v) { return bool%1$d(v != 0.0); }\n", n];
            [s appendFormat:@"static inline bool%1$d gl_if_bvec%1$d(int v) { return bool%1$d(v != 0); }\n", n];
            [s appendFormat:@"static inline bool%1$d gl_if_bvec%1$d(bool v) { return bool%1$d(v); }\n", n];
            for (int m = n; m <= 4; m++) {
                NSString *sw = swizzle[n];
                [s appendFormat:@"static inline float%1$d gl_if_vec%1$d(float%2$d v) { return v.%3$@; }\n", n, m, sw];
                [s appendFormat:@"static inline float%1$d gl_if_vec%1$d(int%2$d v) { return float%1$d(v.%3$@); }\n", n, m, sw];
                [s appendFormat:@"static inline float%1$d gl_if_vec%1$d(bool%2$d v) { return float%1$d(v.%3$@); }\n", n, m, sw];
                [s appendFormat:@"static inline int%1$d gl_if_ivec%1$d(float%2$d v) { return int%1$d(v.%3$@); }\n", n, m, sw];
                [s appendFormat:@"static inline int%1$d gl_if_ivec%1$d(int%2$d v) { return v.%3$@; }\n", n, m, sw];
                [s appendFormat:@"static inline int%1$d gl_if_ivec%1$d(bool%2$d v) { return int%1$d(v.%3$@); }\n", n, m, sw];
                [s appendFormat:@"static inline bool%1$d gl_if_bvec%1$d(float%2$d v) { return v.%3$@ != 0.0; }\n", n, m, sw];
                [s appendFormat:@"static inline bool%1$d gl_if_bvec%1$d(int%2$d v) { return v.%3$@ != 0; }\n", n, m, sw];
                [s appendFormat:@"static inline bool%1$d gl_if_bvec%1$d(bool%2$d v) { return v.%3$@; }\n", n, m, sw];
            }
            // One scalar fills a matrix diagonal.
            [s appendFormat:@"static inline mat%1$d gl_if_mat%1$d(float v) { return mat%1$d(v); }\n", n];
            [s appendFormat:@"static inline mat%1$d gl_if_mat%1$d(int v) { return mat%1$d(float(v)); }\n", n];
            [s appendFormat:@"static inline mat%1$d gl_if_mat%1$d(mat%1$d v) { return v; }\n", n];
        }
        prelude = [s copy];
    });
    return prelude;
}

// Opens the struct that wraps a translated shader. GLSL globals, uniforms and
// functions become its members, so helper functions can read uniforms and
// mutable globals exactly as they do in GLSL.
//
// The leading gl_if_* members are the values upstream provides. The generated
// entry point passes them in this order as the aggregate initialiser, and a
// contract declaration reads its value from them where it stands
// (`uniform float u_time;` becomes `float u_time = gl_if_time;`), so the value
// lives and dies with the declaration under the user's own #if / #ifdef.
static NSString *const kIFBGUserStructOpenMSL =
    @"struct gl_if_shader {\n"
     "    float2 gl_if_v_coords;\n"
     "    float2 gl_if_size;\n"
     "    float2 gl_if_camera;\n"
     "    float2 gl_if_texture_size;\n"
     "    float gl_if_time;\n"
     "    float gl_if_zoom;\n"
     "    float gl_if_alpha;\n"
     "    metal::texture2d<float> gl_if_tex;\n"
     "    metal::sampler gl_if_smp;\n"
     "    float4 gl_FragColor;\n"
     "    float4 gl_FragData[1];\n"
     "    float4 gl_FragCoord;\n"
     "    float2 gl_PointCoord;\n"
     "    bool gl_FrontFacing;\n"
     // Every sampler2D uniform reads texture unit 0 upstream (GL's default
     // uniform value), which is where smithay binds the configured image.
     "    float4 texture2D(sampler2D, float2 uv) { return gl_if_tex.sample(gl_if_smp, uv); }\n"
     "    float4 texture2D(sampler2D, float2 uv, float b) { return gl_if_tex.sample(gl_if_smp, uv, metal::bias(b)); }\n"
     "    float4 texture2DProj(sampler2D, float3 c) { return gl_if_tex.sample(gl_if_smp, c.xy / c.z); }\n"
     "    float4 texture2DProj(sampler2D, float4 c) { return gl_if_tex.sample(gl_if_smp, c.xy / c.w); }\n"
     "    float4 texture2DProj(sampler2D, float3 c, float b) { return gl_if_tex.sample(gl_if_smp, c.xy / c.z, metal::bias(b)); }\n"
     "    float4 texture2DProj(sampler2D, float4 c, float b) { return gl_if_tex.sample(gl_if_smp, c.xy / c.w, metal::bias(b)); }\n";

// MARK: - GLSL ES 1.00 -> MSL source translation

typedef NS_ENUM(uint8_t, IFBGTokenType) {
    IFBGTokenSpace,
    IFBGTokenNewline,
    IFBGTokenComment,
    IFBGTokenIdent,
    IFBGTokenNumber,
    IFBGTokenPunct,
    IFBGTokenHash,  // '#' plus the directive name
};

typedef struct {
    IFBGTokenType type;
    uint8_t directive;  // lies on a preprocessor line
    uint32_t start, length;
} IFBGToken;

typedef struct {
    const char *src;
    IFBGToken *tok;
    NSUInteger ntok;
    NSUInteger *sig;  // significant tokens outside preprocessor lines
    NSUInteger nsig;
    NSUInteger *all;  // significant tokens including preprocessor lines
    NSUInteger nall;
    uint8_t *blank;   // per token: replace with spaces (newlines kept)
} IFBGLex;

static BOOL IFBGIsIdentStart(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}
static BOOL IFBGIsDigit(char c) { return c >= '0' && c <= '9'; }
static BOOL IFBGIsIdentChar(char c) { return IFBGIsIdentStart(c) || IFBGIsDigit(c); }

static BOOL IFBGTokIs(const IFBGLex *L, NSUInteger ti, const char *text) {
    size_t n = strlen(text);
    return L->tok[ti].length == n && memcmp(L->src + L->tok[ti].start, text, n) == 0;
}
static BOOL IFBGTokIsPunct(const IFBGLex *L, NSUInteger ti, const char *text) {
    return L->tok[ti].type == IFBGTokenPunct && IFBGTokIs(L, ti, text);
}
static BOOL IFBGTokIsIdent(const IFBGLex *L, NSUInteger ti, const char *text) {
    return L->tok[ti].type == IFBGTokenIdent && IFBGTokIs(L, ti, text);
}
static NSString *IFBGTokText(const IFBGLex *L, NSUInteger ti) {
    return [[NSString alloc] initWithBytes:L->src + L->tok[ti].start
                                    length:L->tok[ti].length
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

static void IFBGTokenize(IFBGLex *L, const char *src, NSUInteger len) {
    L->src = src;
    L->tok = malloc(sizeof(IFBGToken) * (len + 1));
    L->ntok = 0;
    NSUInteger i = 0;
    BOOL lineStart = YES, inDirective = NO;
    while (i < len) {
        char c = src[i];
        NSUInteger start = i;
        IFBGTokenType type;
        if (c == '\n') {
            i++;
            L->tok[L->ntok++] = (IFBGToken){IFBGTokenNewline, 0, (uint32_t)start, 1};
            lineStart = YES;
            inDirective = NO;
            continue;
        }
        if (c == '\\' && i + 1 < len && (src[i + 1] == '\n' || (src[i + 1] == '\r' && i + 2 < len && src[i + 2] == '\n'))) {
            // Line splice: stays inside the current directive, if any.
            i += (src[i + 1] == '\n') ? 2 : 3;
            type = IFBGTokenSpace;
        } else if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v') {
            while (i < len && (src[i] == ' ' || src[i] == '\t' || src[i] == '\r' || src[i] == '\f' || src[i] == '\v')) i++;
            type = IFBGTokenSpace;
        } else if (c == '/' && i + 1 < len && src[i + 1] == '/') {
            while (i < len && src[i] != '\n') i++;
            type = IFBGTokenComment;
        } else if (c == '/' && i + 1 < len && src[i + 1] == '*') {
            i += 2;
            while (i < len && !(src[i] == '*' && i + 1 < len && src[i + 1] == '/')) i++;
            i = MIN(len, i + 2);
            type = IFBGTokenComment;
        } else if (c == '#' && lineStart) {
            i++;
            while (i < len && (src[i] == ' ' || src[i] == '\t')) i++;
            while (i < len && IFBGIsIdentChar(src[i])) i++;
            type = IFBGTokenHash;
            inDirective = YES;
        } else if (IFBGIsIdentStart(c)) {
            while (i < len && IFBGIsIdentChar(src[i])) i++;
            type = IFBGTokenIdent;
        } else if (IFBGIsDigit(c) || (c == '.' && i + 1 < len && IFBGIsDigit(src[i + 1]))) {
            BOOL hex = (c == '0' && i + 1 < len && (src[i + 1] == 'x' || src[i + 1] == 'X'));
            while (i < len) {
                char d = src[i];
                if (IFBGIsIdentChar(d) || d == '.') { i++; continue; }
                if ((d == '+' || d == '-') && !hex && (src[i - 1] == 'e' || src[i - 1] == 'E')) { i++; continue; }
                break;
            }
            type = IFBGTokenNumber;
        } else if ((unsigned char)c >= 0x80) {
            while (i < len && (unsigned char)src[i] >= 0x80) i++;
            type = IFBGTokenPunct;
        } else {
            static const char *const two[] = {"==", "!=", "<=", ">=", "&&", "||", "^^", "++", "--",
                                              "+=", "-=", "*=", "/=", "<<", ">>"};
            i++;
            if (i < len) {
                for (size_t t = 0; t < sizeof two / sizeof two[0]; t++) {
                    if (c == two[t][0] && src[i] == two[t][1]) { i++; break; }
                }
            }
            type = IFBGTokenPunct;
        }
        if (type != IFBGTokenSpace && type != IFBGTokenComment) lineStart = NO;
        L->tok[L->ntok++] = (IFBGToken){type, (uint8_t)(inDirective ? 1 : 0), (uint32_t)start, (uint32_t)(i - start)};
    }
    L->sig = malloc(sizeof(NSUInteger) * (L->ntok + 1));
    L->all = malloc(sizeof(NSUInteger) * (L->ntok + 1));
    L->nsig = L->nall = 0;
    for (NSUInteger t = 0; t < L->ntok; t++) {
        IFBGTokenType ty = L->tok[t].type;
        if (ty == IFBGTokenIdent || ty == IFBGTokenNumber || ty == IFBGTokenPunct) {
            L->all[L->nall++] = t;
            if (!L->tok[t].directive) L->sig[L->nsig++] = t;
        } else if (ty == IFBGTokenHash) {
            L->all[L->nall++] = t;
        }
    }
    L->blank = calloc(L->ntok + 1, 1);
}

static void IFBGLexFree(IFBGLex *L) {
    free(L->tok);
    free(L->sig);
    free(L->all);
    free(L->blank);
}

// Index (in `list`) of the bracket matching the opener at `open`, or NSNotFound.
static NSUInteger IFBGMatch(const IFBGLex *L, const NSUInteger *list, NSUInteger count, NSUInteger open,
                            const char *openText, const char *closeText) {
    NSInteger depth = 0;
    for (NSUInteger j = open; j < count; j++) {
        if (IFBGTokIsPunct(L, list[j], openText)) depth++;
        else if (IFBGTokIsPunct(L, list[j], closeText) && --depth == 0) return j;
    }
    return NSNotFound;
}

static BOOL IFBGIsPrecisionWord(const IFBGLex *L, NSUInteger ti) {
    return IFBGTokIsIdent(L, ti, "highp") || IFBGTokIsIdent(L, ti, "mediump") || IFBGTokIsIdent(L, ti, "lowp");
}

// Identifiers that are legal in GLSL ES 1.00 but are keywords in C++14 or
// Metal. (Words GLSL ES 1.00 itself reserves — class, template, half, … —
// cannot occur in a valid shader and are left for the compiler to reject.)
static NSSet<NSString *> *IFBGReservedWords(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            @"alignas", @"alignof", @"and", @"and_eq", @"auto", @"bitand", @"bitor", @"case", @"catch",
            @"char", @"char16_t", @"char32_t", @"compl", @"const_cast", @"constexpr", @"decltype",
            @"delete", @"dynamic_cast", @"explicit", @"export", @"friend", @"mutable", @"new",
            @"noexcept", @"not", @"not_eq", @"nullptr", @"operator", @"or", @"or_eq", @"private", @"protected",
            @"register", @"reinterpret_cast", @"signed", @"static_assert", @"static_cast",
            @"thread_local", @"throw", @"try", @"typeid", @"typename", @"virtual", @"wchar_t", @"xor",
            @"xor_eq",
            // Metal function and address-space qualifiers.
            @"kernel", @"vertex", @"fragment", @"constant", @"device", @"thread",
        ]];
    });
    return set;
}

static NSSet<NSString *> *IFBGConstructorNames(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"vec2", @"vec3", @"vec4", @"ivec2", @"ivec3", @"ivec4", @"bvec2",
                                    @"bvec3", @"bvec4", @"mat2", @"mat3", @"mat4"]];
    });
    return set;
}

// Whether `#undef name` is something the Metal preprocessor accepts and this
// translation wants. Names with `__` and names starting with `GL_` are reserved
// in GLSL ES 1.00 (no valid shader declares or defines one) and hold the
// compiler's built-in macros and this module's GL_ES / GL_FRAGMENT_PRECISION_HIGH.
// `defined` and the C++ operator spellings cannot name a macro at all:
// `#undef not` is a hard error.
static BOOL IFBGCanUndef(NSString *name) {
    static NSSet<NSString *> *never;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        never = [NSSet setWithArray:@[@"defined", @"and", @"and_eq", @"bitand", @"bitor", @"compl", @"not",
                                      @"not_eq", @"or", @"or_eq", @"xor", @"xor_eq"]];
    });
    return ![name containsString:@"__"] && ![name hasPrefix:@"GL_"] && ![never containsObject:name];
}

@interface IFBGShaderDecl : NSObject
@property (nonatomic, copy) NSString *qualifier;  // uniform | varying | attribute
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger nameToken;       // index of the name in the token list
@property (nonatomic) BOOL isArray;
@end
@implementation IFBGShaderDecl
@end

// Upstream `references_uniform` (background.rs): a plain substring test on the
// raw source. Kept literally, comments and prefixes included, because it is
// what decides upstream's animated / camera / zoom / `tex` behaviour.
static BOOL IFBGReferencesUniform(NSString *src, NSString *type, NSString *name) {
    for (NSString *prec in @[@"", @"lowp ", @"mediump ", @"highp "]) {
        if ([src containsString:[NSString stringWithFormat:@"uniform %@%@ %@", prec, type, name]]) return YES;
    }
    return NO;
}

// Rewrites a parameter list in place: `in` disappears, `out` / `inout` become
// Metal references.
static void IFBGRewriteParams(const IFBGLex *L, NSUInteger open, NSUInteger close,
                              NSMutableDictionary<NSNumber *, NSString *> *repl) {
    NSUInteger a = open + 1;
    while (a < close) {
        NSUInteger b = a;
        NSInteger depth = 0;
        while (b < close) {
            NSUInteger ti = L->sig[b];
            if (IFBGTokIsPunct(L, ti, "(") || IFBGTokIsPunct(L, ti, "[")) depth++;
            else if (IFBGTokIsPunct(L, ti, ")") || IFBGTokIsPunct(L, ti, "]")) depth--;
            else if (depth == 0 && IFBGTokIsPunct(L, ti, ",")) break;
            b++;
        }
        BOOL byRef = NO;
        NSUInteger typeTok = NSNotFound, nameTok = NSNotFound, nameSig = NSNotFound;
        for (NSUInteger j = a; j < b; j++) {
            NSUInteger ti = L->sig[j];
            if (L->tok[ti].type != IFBGTokenIdent) {
                if (IFBGTokIsPunct(L, ti, "[")) break;  // array size expression
                continue;
            }
            if (IFBGTokIsIdent(L, ti, "in")) { L->blank[ti] = 1; continue; }
            if (IFBGTokIsIdent(L, ti, "out") || IFBGTokIsIdent(L, ti, "inout")) {
                repl[@(ti)] = @"thread";
                byRef = YES;
                continue;
            }
            if (IFBGTokIsIdent(L, ti, "const") || IFBGIsPrecisionWord(L, ti)) continue;
            if (typeTok == NSNotFound) typeTok = ti;
            else if (nameTok == NSNotFound) { nameTok = ti; nameSig = j; }
        }
        if (byRef) {
            if (nameTok != NSNotFound) {
                NSString *name = repl[@(nameTok)] ?: IFBGTokText(L, nameTok);
                BOOL isArray = nameSig + 1 < b && IFBGTokIsPunct(L, L->sig[nameSig + 1], "[");
                repl[@(nameTok)] = isArray ? [NSString stringWithFormat:@"(&%@)", name]
                                           : [@"&" stringByAppendingString:name];
            } else if (typeTok != NSNotFound) {
                NSString *type = repl[@(typeTok)] ?: IFBGTokText(L, typeTok);
                repl[@(typeTok)] = [type stringByAppendingString:@" &"];
            }
        }
        a = b + 1;
    }
}

/// Translates a GLSL ES 1.00 fragment shader written against upstream's
/// background contract into a complete Metal source with one fragment function,
/// `ifbg_user_fragment`. Line numbers of the user's file are preserved.
/// Returns nil and sets `*error` for constructs it can reject by itself.
static NSString *IFBGTranslateGLSL(NSString *source, BOOL textured, NSString **error) {
    // The lexer keeps pointers into these bytes until the output is assembled.
    NS_VALID_UNTIL_END_OF_SCOPE NSData *utf8 = [source dataUsingEncoding:NSUTF8StringEncoding];
    IFBGLex lex = {0};
    IFBGLex *L = &lex;
    IFBGTokenize(L, utf8.bytes, utf8.length);
    NSMutableDictionary<NSNumber *, NSString *> *repl = [NSMutableDictionary dictionary];
    NSMutableArray<IFBGShaderDecl *> *decls = [NSMutableArray array];
    // Every identifier the shader's text mentions, in order of first appearance.
    NSMutableOrderedSet<NSString *> *mentioned = [NSMutableOrderedSet orderedSet];
    NSString *failure = nil;
    BOOL hasMain = NO, usesFragData = NO;

    // 1. Preprocessor lines Metal has no use for.
    for (NSUInteger t = 0; t < L->ntok; t++) {
        if (L->tok[t].type != IFBGTokenHash) continue;
        NSString *name = [[IFBGTokText(L, t) substringFromIndex:1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([name isEqualToString:@"version"] || [name isEqualToString:@"extension"] ||
            [name isEqualToString:@"pragma"]) {
            for (NSUInteger u = t; u < L->ntok && L->tok[u].directive; u++) L->blank[u] = 1;
        }
    }

    // 2. Struct field names, so a field called `s` or `t` is not mistaken for
    //    a texture-coordinate swizzle.
    NSMutableSet<NSString *> *fields = [NSMutableSet set];
    for (NSUInteger k = 0; k < L->nsig; k++) {
        if (!IFBGTokIsIdent(L, L->sig[k], "struct")) continue;
        NSUInteger open = k + 1;
        while (open < L->nsig && !IFBGTokIsPunct(L, L->sig[open], "{") && !IFBGTokIsPunct(L, L->sig[open], ";")) open++;
        if (open >= L->nsig || !IFBGTokIsPunct(L, L->sig[open], "{")) continue;
        NSUInteger close = IFBGMatch(L, L->sig, L->nsig, open, "{", "}");
        if (close == NSNotFound) continue;
        for (NSUInteger j = open + 1; j + 1 <= close; j++) {
            NSUInteger ti = L->sig[j], next = L->sig[j + 1];
            if (L->tok[ti].type == IFBGTokenIdent &&
                (IFBGTokIsPunct(L, next, ",") || IFBGTokIsPunct(L, next, ";") || IFBGTokIsPunct(L, next, "["))) {
                [fields addObject:IFBGTokText(L, ti)];
            }
        }
    }

    // 3. Token-local rewrites, applied everywhere including macro bodies.
    NSSet<NSString *> *reserved = IFBGReservedWords(), *ctors = IFBGConstructorNames();
    for (NSUInteger a = 0; a < L->nall; a++) {
        NSUInteger ti = L->all[a];
        if (L->tok[ti].type == IFBGTokenPunct) {
            if (IFBGTokIs(L, ti, "^^")) repl[@(ti)] = @"!=";  // logical xor on bools
            continue;
        }
        if (L->tok[ti].type != IFBGTokenIdent) continue;
        NSString *text = IFBGTokText(L, ti);
        if (IFBGIsPrecisionWord(L, ti)) { L->blank[ti] = 1; continue; }
        if (!L->blank[ti] && IFBGCanUndef(text)) [mentioned addObject:text];
        if (a > 0 && IFBGTokIsPunct(L, L->all[a - 1], ".")) {
            // .stpq swizzles: Metal only has .xyzw and .rgba.
            BOOL stpq = text.length <= 4 && ![fields containsObject:text];
            for (NSUInteger c = 0; stpq && c < text.length; c++) {
                stpq = [@"stpq" rangeOfString:[text substringWithRange:NSMakeRange(c, 1)]].location != NSNotFound;
            }
            if (stpq) {
                NSMutableString *m = [NSMutableString string];
                for (NSUInteger c = 0; c < text.length; c++) {
                    NSUInteger idx = [@"stpq" rangeOfString:[text substringWithRange:NSMakeRange(c, 1)]].location;
                    [m appendString:[@"xyzw" substringWithRange:NSMakeRange(idx, 1)]];
                }
                repl[@(ti)] = m;
                continue;
            }
        }
        if ([text isEqualToString:@"discard"]) { repl[@(ti)] = @"discard_fragment()"; continue; }
        if ([text isEqualToString:@"__VERSION__"]) { repl[@(ti)] = @"100"; continue; }
        if ([text isEqualToString:@"gl_FragData"]) { usesFragData = YES; continue; }
        if ([ctors containsObject:text] && a + 1 < L->nall && IFBGTokIsPunct(L, L->all[a + 1], "(")) {
            // A constructor call (a declaration is `type name`, never `type (`).
            repl[@(ti)] = [@"gl_if_" stringByAppendingString:text];
            continue;
        }
        if ([reserved containsObject:text]) repl[@(ti)] = [text stringByAppendingString:@"_glsl"];
    }

    // 4. Top-level structure: precision statements, interface declarations,
    //    function prototypes and parameter qualifiers.
    NSUInteger k = 0;
    while (k < L->nsig && !failure) {
        NSUInteger ti = L->sig[k];
        if (IFBGTokIsPunct(L, ti, ";") || IFBGTokIsPunct(L, ti, "}")) { k++; continue; }
        if (IFBGTokIsIdent(L, ti, "precision")) {
            NSUInteger e = k;
            while (e < L->nsig && !IFBGTokIsPunct(L, L->sig[e], ";")) e++;
            for (NSUInteger j = k; j <= e && j < L->nsig; j++) L->blank[L->sig[j]] = 1;
            k = e + 1;
            continue;
        }
        NSUInteger q = k;
        NSString *qualifier = nil;
        BOOL invariant = NO;
        while (q < L->nsig) {
            NSUInteger tq = L->sig[q];
            if (IFBGTokIsIdent(L, tq, "invariant")) { invariant = YES; L->blank[tq] = 1; q++; continue; }
            if (IFBGTokIsIdent(L, tq, "uniform") || IFBGTokIsIdent(L, tq, "varying") ||
                IFBGTokIsIdent(L, tq, "attribute")) {
                qualifier = IFBGTokText(L, tq);
                L->blank[tq] = 1;
                q++;
                continue;
            }
            break;
        }
        NSInteger paren = 0, brace = 0;
        BOOL sawAssign = NO;
        NSUInteger fnOpen = NSNotFound, fnClose = NSNotFound, end = NSNotFound;
        for (NSUInteger j = q; j < L->nsig; j++) {
            NSUInteger tj = L->sig[j];
            if (L->tok[tj].type != IFBGTokenPunct) continue;
            if (IFBGTokIs(L, tj, "(")) {
                // `type name (` with no `=` before it opens a function declarator.
                if (paren == 0 && brace == 0 && !sawAssign && !qualifier && fnOpen == NSNotFound && j >= q + 2) fnOpen = j;
                paren++;
            } else if (IFBGTokIs(L, tj, ")")) {
                paren--;
                if (fnOpen != NSNotFound && paren == 0 && brace == 0) { fnClose = j; break; }
            } else if (IFBGTokIs(L, tj, "{")) {
                brace++;
            } else if (IFBGTokIs(L, tj, "}")) {
                brace--;
            } else if (IFBGTokIs(L, tj, "=")) {
                if (paren == 0 && brace == 0) sawAssign = YES;
            } else if (IFBGTokIs(L, tj, ";")) {
                if (paren == 0 && brace == 0) { end = j; break; }
            }
        }
        if (fnClose != NSNotFound) {
            NSUInteger next = fnClose + 1;
            if (next < L->nsig && IFBGTokIsPunct(L, L->sig[next], "{")) {
                IFBGRewriteParams(L, fnOpen, fnClose, repl);
                NSUInteger nameTok = L->sig[fnOpen - 1];
                if (IFBGTokIsIdent(L, nameTok, "main")) {
                    repl[@(nameTok)] = @"gl_if_main";
                    hasMain = YES;
                }
                NSUInteger bodyEnd = IFBGMatch(L, L->sig, L->nsig, next, "{", "}");
                k = (bodyEnd == NSNotFound) ? L->nsig : bodyEnd + 1;
            } else if (next < L->nsig && IFBGTokIsPunct(L, L->sig[next], ";")) {
                // A prototype. Members of a struct see each other regardless
                // of order, and a member may not be declared twice.
                for (NSUInteger j = k; j <= next; j++) L->blank[L->sig[j]] = 1;
                k = next + 1;
            } else {
                k = fnClose + 1;
            }
            continue;
        }
        if (end == NSNotFound) break;
        if (qualifier) {
            NSUInteger p = q;
            while (p < end && IFBGIsPrecisionWord(L, L->sig[p])) p++;
            NSString *type = p < end ? IFBGTokText(L, L->sig[p]) : @"";
            p++;
            NSInteger depth = 0;
            BOOL expectName = YES;
            for (; p < end; p++) {
                NSUInteger tp = L->sig[p];
                if (IFBGTokIsPunct(L, tp, "[") || IFBGTokIsPunct(L, tp, "(")) depth++;
                else if (IFBGTokIsPunct(L, tp, "]") || IFBGTokIsPunct(L, tp, ")")) depth--;
                else if (depth == 0 && IFBGTokIsPunct(L, tp, ",")) expectName = YES;
                else if (depth == 0 && expectName && L->tok[tp].type == IFBGTokenIdent) {
                    IFBGShaderDecl *d = [IFBGShaderDecl new];
                    d.qualifier = qualifier;
                    d.type = type;
                    d.name = IFBGTokText(L, tp);
                    d.nameToken = tp;
                    d.isArray = p + 1 < end && IFBGTokIsPunct(L, L->sig[p + 1], "[");
                    [decls addObject:d];
                    expectName = NO;
                }
            }
        } else if (invariant) {
            // `invariant gl_FragColor;` — meaningless here.
            for (NSUInteger j = q; j <= end; j++) L->blank[L->sig[j]] = 1;
        }
        k = end + 1;
    }

    // 5. The interface upstream provides (smithay's pixel / texture shader
    //    built-ins plus BG_UNIFORMS / BG_TEX_UNIFORMS in shaders.rs). Each
    //    declaration upstream would feed gets a default member initialiser
    //    reading the matching leading member of gl_if_shader, written where the
    //    declaration stands. A declaration the user's own preprocessor
    //    conditions remove therefore takes its value with it, as upstream's
    //    uniform push is a no-op for a uniform the compiled program lacks.
    NSDictionary<NSString *, NSArray<NSString *> *> *contract = textured
        ? @{@"alpha": @[@"float", @"gl_if_alpha"],
            @"u_camera": @[@"vec2", @"gl_if_camera"],
            @"u_time": @[@"float", @"gl_if_time"],
            @"u_zoom": @[@"float", @"gl_if_zoom"],
            @"u_output_size": @[@"vec2", @"gl_if_size"],
            @"u_texture_size": @[@"vec2", @"gl_if_texture_size"]}
        : @{@"size": @[@"vec2", @"gl_if_size"],
            @"alpha": @[@"float", @"gl_if_alpha"],
            @"u_camera": @[@"vec2", @"gl_if_camera"],
            @"u_time": @[@"float", @"gl_if_time"],
            @"u_zoom": @[@"float", @"gl_if_zoom"]};
    for (IFBGShaderDecl *d in decls) {
        if (failure) break;
        if ([d.qualifier isEqualToString:@"attribute"]) {
            failure = [NSString stringWithFormat:@"'attribute %@ %@' is not valid in a fragment shader", d.type, d.name];
        } else if ([d.qualifier isEqualToString:@"varying"]) {
            if ([d.name isEqualToString:@"v_coords"] && [d.type isEqualToString:@"vec2"] && !d.isArray) {
                repl[@(d.nameToken)] = @"v_coords = gl_if_v_coords";
                continue;
            }
            // The fixed vertex stage writes only v_coords. An unused extra
            // varying links upstream; one that is read does not.
            NSUInteger uses = 0;
            for (NSUInteger a = 0; a < L->nall; a++) {
                if (IFBGTokIsIdent(L, L->all[a], d.name.UTF8String)) uses++;
            }
            if (uses > 1) {
                failure = [NSString stringWithFormat:
                    @"varying '%@ %@' is read but the background vertex stage only writes `varying vec2 v_coords`",
                    d.type, d.name];
            }
        } else {
            NSArray<NSString *> *entry = contract[d.name];
            // A uniform upstream does not set (or sets with another type) keeps
            // GL's default value of zero, as do the zero-initialised members.
            if (entry && [entry[0] isEqualToString:d.type] && !d.isArray) {
                repl[@(d.nameToken)] = [NSString stringWithFormat:@"%@ = %@", d.name, entry[1]];
            }
        }
    }
    if (!failure && !hasMain) failure = @"the shader defines no `void main()`";

    NSMutableData *out = nil;
    if (!failure) {
        out = [NSMutableData dataWithCapacity:utf8.length + 256];
        for (NSUInteger t = 0; t < L->ntok; t++) {
            const char *p = L->src + L->tok[t].start;
            NSUInteger n = L->tok[t].length;
            NSString *r = repl[@(t)];
            if (L->blank[t]) {
                for (NSUInteger c = 0; c < n; c++) [out appendBytes:(p[c] == '\n' ? "\n" : " ") length:1];
            } else if (r) {
                [out appendData:[r dataUsingEncoding:NSUTF8StringEncoding]];
            } else {
                [out appendBytes:p length:n];
            }
        }
    }
    IFBGLexFree(L);
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    NSString *body = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    if (!body) {
        if (error) *error = @"the shader is not valid UTF-8 after translation";
        return nil;
    }

    // GLSL ES 1.00 predefines no macro beyond __LINE__, __FILE__, __VERSION__
    // and GL_ES, and a shader's own macros end with its text. Metal's library
    // defines many more (INFINITY, FLT_MAX, assert(), ...; the set depends on
    // the toolchain), and the generated entry point follows the shader in the
    // same translation unit. So every identifier the shader mentions is
    // #undef'd twice: before its first line, so that no Metal macro captures a
    // name the shader declares, and after its last line, so that none of the
    // shader's macros (`#define time u_time`, `#define s 0.75`) rewrites the
    // entry point. `#undef` of a name that is not a macro does nothing.
    NSMutableString *undefs = [NSMutableString string];
    for (NSString *name in mentioned) [undefs appendFormat:@"#undef %@\n", name];

    NSMutableString *msl = [NSMutableString string];
    [msl appendString:kIFBGCommonMSL];
    [msl appendString:IFBGUserPreludeMSL()];
    [msl appendString:kIFBGUserStructOpenMSL];
    [msl appendString:undefs];
    [msl appendString:@"#line 1 \"background.glsl\"\n"];
    [msl appendString:body];
    [msl appendString:@"\n};\n"];
    [msl appendString:undefs];
    [msl appendString:@"#line 1 \"ifbg_wrapper\"\n"];
    [msl appendString:
        @"fragment float4 ifbg_user_fragment(IFBGVertexOut in [[stage_in]],\n"
         "                                   constant IFBGUniforms &U [[buffer(0)]],\n"
         "                                   texture2d<float> ifbg_tex [[texture(0)]],\n"
         "                                   sampler ifbg_smp [[sampler(0)]]) {\n"
         // The leading members of gl_if_shader, in declaration order; every
         // other member takes its own initialiser or zero (GL's default for a
         // uniform nobody sets).
         "    gl_if_shader s = {ifbg_v_coords(in.position, U), U.size, U.camera, U.texture_size,\n"
         "                      U.time, U.zoom, U.alpha};\n"
         "    s.gl_if_tex = ifbg_tex;\n"
         "    s.gl_if_smp = ifbg_smp;\n"
         "    s.gl_FragCoord = float4(in.position.xy, 0.0, 1.0);\n"
         "    s.gl_FrontFacing = true;\n"];
    [msl appendString:@"    s.gl_if_main();\n"];
    [msl appendString:usesFragData ? @"    return ifbg_finish(s.gl_FragData[0], U);\n"
                                   : @"    return ifbg_finish(s.gl_FragColor, U);\n"];
    [msl appendString:@"}\n"];
    return msl;
}

// Keeps the compiler's error diagnostics and drops its warnings and the
// `note:` blocks listing overload candidates from Metal's own headers.
static NSString *IFBGCondenseDiagnostics(NSString *text) {
    NSRegularExpression *header = [NSRegularExpression
        regularExpressionWithPattern:@"^.*:\\d+:\\d+: (error|warning|note|fatal error): "
                             options:0
                               error:NULL];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    BOOL keep = YES, sawHeader = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *m = [header firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (m) {
            sawHeader = YES;
            NSString *level = [line substringWithRange:[m rangeAtIndex:1]];
            keep = [level isEqualToString:@"error"] || [level isEqualToString:@"fatal error"];
        }
        if ([line hasPrefix:@"note: "]) continue;  // candidate lists without a location
        if (keep && line.length) [kept addObject:line];
    }
    if (!sawHeader || kept.count == 0) return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [kept componentsJoinedByString:@"\n"];
}

// MARK: - Per-device shared state

@interface IFBGDeviceResources : NSObject
@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> queue;
@property (nonatomic, readonly, nullable) id<MTLFunction> vertexFunction;
@property (nonatomic, readonly) id<MTLSamplerState> sampler;
@property (nonatomic, readonly) id<MTLTexture> placeholderTexture;
@property (nonatomic, readonly, nullable) NSString *builtinError;
+ (instancetype)resourcesForDevice:(id<MTLDevice>)device;
- (nullable id<MTLRenderPipelineState>)builtinPipeline:(NSString *)fragmentName;
- (nullable id<MTLRenderPipelineState>)pipelineWithFragment:(id<MTLFunction>)fragment error:(NSError **)error;
/// The quad pipeline of a cached chunk (ifbg_chunk_vertex, ifbg_chunk).
- (nullable id<MTLRenderPipelineState>)chunkPipeline;
@end

@implementation IFBGDeviceResources {
    id<MTLLibrary> _builtinLibrary;
    NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_builtinPipelines;
    id<MTLRenderPipelineState> _chunkPipeline;
}

+ (instancetype)resourcesForDevice:(id<MTLDevice>)device {
    return DWMetalSharedForDevice(self, device, ^id{ return [[IFBGDeviceResources alloc] initWithDevice:device]; });
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _device = device;
    _queue = [device newCommandQueue];
    _builtinPipelines = [NSMutableDictionary dictionary];

    NSError *error = nil;
    _builtinLibrary = [device newLibraryWithSource:[[kIFBGCommonMSL stringByAppendingString:kIFBGBuiltinMSL] stringByAppendingString:kIFBGChunkMSL]
                                           options:DWMetalCompileOptions()
                                             error:&error];
    if (!_builtinLibrary) {
        // Upstream: "Default shader must compile".
        _builtinError = [NSString stringWithFormat:@"background: built-in shaders failed to compile: %@",
                                                   error.localizedDescription];
        NSLog(@"%@", _builtinError);
    }
    _vertexFunction = [_builtinLibrary newFunctionWithName:@"ifbg_vertex"];

    // smithay: GL_LINEAR minification and magnification, CLAMP_TO_EDGE, no mipmaps.
    _sampler = DWMetalLinearClampSampler(device);

    // Bound when a shader declares a sampler but no image is configured.
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:1
                                                                                 height:1
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    _placeholderTexture = [device newTextureWithDescriptor:td];
    const uint8_t zero[4] = {0, 0, 0, 0};
    [_placeholderTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:4];
    return self;
}

- (id<MTLRenderPipelineState>)pipelineWithFragment:(id<MTLFunction>)fragment error:(NSError **)error {
    if (!_vertexFunction) {
        if (error) *error = [NSError errorWithDomain:IFBGErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: _builtinError ?: @"no vertex function"}];
        return nil;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = _vertexFunction;
    pd.fragmentFunction = fragment;
    // Not an _sRGB format: like upstream's GL framebuffer, the shader's values
    // are stored as written and are already sRGB-encoded.
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].blendingEnabled = NO;
    return [_device newRenderPipelineStateWithDescriptor:pd error:error];
}

- (id<MTLRenderPipelineState>)builtinPipeline:(NSString *)fragmentName {
    @synchronized(self) {
        id<MTLRenderPipelineState> p = _builtinPipelines[fragmentName];
        if (p) return p;
        id<MTLFunction> f = [_builtinLibrary newFunctionWithName:fragmentName];
        if (!f) return nil;
        NSError *error = nil;
        p = [self pipelineWithFragment:f error:&error];
        if (!p) {
            NSLog(@"background: built-in pipeline %@ failed: %@", fragmentName, error.localizedDescription);
            return nil;
        }
        _builtinPipelines[fragmentName] = p;
        return p;
    }
}

- (id<MTLRenderPipelineState>)chunkPipeline {
    @synchronized(self) {
        if (_chunkPipeline) return _chunkPipeline;
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [_builtinLibrary newFunctionWithName:@"ifbg_chunk_vertex"];
        pd.fragmentFunction = [_builtinLibrary newFunctionWithName:@"ifbg_chunk"];
        if (!pd.vertexFunction || !pd.fragmentFunction) return nil;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = NO;
        NSError *error = nil;
        _chunkPipeline = [_device newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!_chunkPipeline) NSLog(@"background: chunk pipeline failed: %@", error.localizedDescription);
        return _chunkPipeline;
    }
}
@end

// MARK: - Files

static NSString *IFBGReadText(NSString *path, NSString **error) {
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) {
        if (error) *error = IFBGOSError(errno);
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) [data appendBytes:buf length:n];
    int readError = ferror(f) ? errno : 0;
    fclose(f);
    if (readError) {
        if (error) *error = IFBGOSError(readError);
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text && error) *error = @"stream did not contain valid UTF-8";
    return text;
}

static BOOL IFBGIsTIFFPath(NSString *path) {
    NSString *lower = path.lowercaseString;
    return [lower hasSuffix:@".tif"] || [lower hasSuffix:@".tiff"];
}

// CRC-32 as PNG uses it (ISO 3309, reflected polynomial 0xEDB88320).
static uint32_t IFBGCRC32(const uint8_t *bytes, size_t length) {
    static uint32_t table[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t n = 0; n < 256; n++) {
            uint32_t c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
    });
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < length; i++) c = table[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

/// Walks a PNG file's chunk list and returns what is wrong with it, or nil.
/// ImageIO decodes a truncated or damaged PNG without any sign of trouble: it
/// reports kCGImageStatusComplete before and after decoding and leaves the
/// missing rows empty (measured, BACKGROUND-NOTES.md section 6). Upstream's decoder (the
/// `png` crate behind `image::open`) reports an error for such a file, and the
/// background then falls back, so the container is checked here: every chunk
/// must be present in full up to and including IEND, and a critical chunk
/// (IHDR, PLTE, IDAT, IEND) must carry the CRC of its contents.
static NSString *IFBGPNGDefect(NSData *file) {
    const uint8_t *p = file.bytes;
    NSUInteger n = file.length, o = 8;  // past the signature ImageIO recognised
    NSString *last = nil;
    while (o <= n && n - o >= 8) {
        uint32_t length = ((uint32_t)p[o] << 24) | ((uint32_t)p[o + 1] << 16) | ((uint32_t)p[o + 2] << 8) | p[o + 3];
        const uint8_t *type = p + o + 4;
        BOOL letters = YES;
        for (int i = 0; i < 4; i++) letters = letters && ((type[i] | 0x20) >= 'a' && (type[i] | 0x20) <= 'z');
        NSString *name = letters ? [[NSString alloc] initWithBytes:type length:4 encoding:NSASCIIStringEncoding] : @"?";
        if ((NSUInteger)length > n - o - 8 || n - o - 8 - length < 4) {
            return [NSString stringWithFormat:@"unexpected end of file (the PNG is truncated in its %@ chunk)", name];
        }
        uint32_t stored = ((uint32_t)p[o + 8 + length] << 24) | ((uint32_t)p[o + 9 + length] << 16) |
                          ((uint32_t)p[o + 10 + length] << 8) | p[o + 11 + length];
        BOOL critical = (type[0] & 0x20) == 0;  // an ancillary chunk may be ignored, and so may its damage
        if (critical && IFBGCRC32(type, (size_t)length + 4) != stored) {
            return [NSString stringWithFormat:@"CRC error in the %@ chunk (the PNG is damaged)", name];
        }
        if (memcmp(type, "IEND", 4) == 0) return nil;
        last = name;
        o += 12 + (NSUInteger)length;
    }
    return last ? [NSString stringWithFormat:@"unexpected end of file (the PNG is truncated after its %@ chunk)", last]
                : @"unexpected end of file (the PNG is truncated after its signature)";
}

/// Upstream `load_image_to_texture`: decodes to straight-alpha RGBA8 and
/// uploads the bytes untouched. The file's colour profile is ignored (the
/// `image` crate never reads it); the values are taken to be sRGB. Inherited
/// macOS still images instead use ImageIO's formats, orientation and sRGB
/// conversion. A multi-image asset is not evidence of its active wallpaper.
static id<MTLTexture> IFBGLoadImage(id<MTLDevice> device, NSString *path, CGSize *size,
                                    BOOL inherited, BOOL *hasTransparency, NSString **error) {
    NSString *(^fail)(NSString *) = ^(NSString *why) {
        return [NSString stringWithFormat:@"background image '%@': %@", path, why];
    };
    if (access(path.fileSystemRepresentation, R_OK) != 0) {
        if (error) *error = fail(IFBGOSError(errno));
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    NSString *uti = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
    // Upstream builds the `image` crate with PNG and JPEG decoders only.
    if (!source || (!inherited && !([uti isEqualToString:@"public.png"] || [uti isEqualToString:@"public.jpeg"]))) {
        if (error) *error = fail(uti ? [NSString stringWithFormat:@"unsupported image format %@ (PNG/JPEG only)", uti]
                                     : @"The image format could not be determined");
        if (source) CFRelease(source);
        return nil;
    }
    BOOL png = [uti isEqualToString:@"public.png"];
    if (png) {
        NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
        NSString *defect = file ? IFBGPNGDefect(file) : @"the file could not be read";
        if (defect) {
            if (error) *error = fail(defect);
            CFRelease(source);
            return nil;
        }
    }
    NSDictionary *decode = nil;
    if (inherited) {
        if (CGImageSourceGetCount(source) != 1) {
            CFRelease(source);
            if (error) *error = fail(@"the active image of a dynamic or multi-image wallpaper is unavailable");
            return nil;
        }
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        // Reject an oversized still before allocating its decoded pixels. Do
        // not route an ordinary inherited TIFF into the tiled-canvas decoder.
        if (!isfinite(width) || !isfinite(height) || width < 1 || height < 1 ||
            width > kIFBGMaxTextureSide || height > kIFBGMaxTextureSide) {
            CFRelease(source);
            if (error) *error = fail(@"the still image has invalid dimensions or exceeds the texture limit");
            return nil;
        }
        decode = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                   (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                   (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(MAX(width, height)),
                   (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES};
    }
    CGImageRef image = inherited ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)decode)
                                 : CGImageSourceCreateImageAtIndex(source, 0, NULL);
    if (!image) {
        CFRelease(source);
        if (error) *error = fail(@"the image could not be decoded");
        return nil;
    }
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w == 0 || h == 0 || w > kIFBGMaxTextureSide || h > kIFBGMaxTextureSide) {
        CGImageRelease(image);
        CFRelease(source);
        if (error) *error = fail(@"upload failed (image likely too large) — gigapixel wallpapers need a tiled pyramidal TIFF");
        return nil;
    }

    // Convert without colour management: the destination uses the image's own
    // colour space (or, for palette images, its base space), so vImage only
    // repacks samples. Grey images are widened by hand for the same reason.
    CGColorSpaceRef space = CGImageGetColorSpace(image);
    CGColorSpaceModel model = space ? CGColorSpaceGetModel(space) : kCGColorSpaceModelUnknown;
    CGColorSpaceRef base = space;
    if (model == kCGColorSpaceModelIndexed) {
        base = CGColorSpaceGetBaseColorSpace(space);
        model = base ? CGColorSpaceGetModel(base) : kCGColorSpaceModelUnknown;
    }
    BOOL grey = !inherited && (model == kCGColorSpaceModelMonochrome);
    CGColorSpaceRef fallback = NULL;
    if (inherited || (model != kCGColorSpaceModelRGB && !grey)) {
        // macOS wallpapers retain their colour profile through this conversion;
        // custom CMYK and other exotic models also need an RGB destination.
        base = fallback = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    }
    vImage_CGImageFormat format = {
        .bitsPerComponent = 8,
        .bitsPerPixel = grey ? 16 : 32,
        .colorSpace = base,
        .bitmapInfo = (CGBitmapInfo)kCGImageAlphaLast | kCGBitmapByteOrderDefault,
        .version = 0,
        .decode = NULL,
        .renderingIntent = kCGRenderingIntentDefault,
    };
    vImage_Buffer buffer = {0};
    vImage_Error verr = vImageBuffer_InitWithCGImage(&buffer, &format, NULL, image, kvImageNoFlags);
    CGImageRelease(image);
    if (fallback) CGColorSpaceRelease(fallback);
    // The pixels are decoded by the call above, and only then does ImageIO know
    // whether the data ran out: a JPEG cut short reports
    // kCGImageStatusUnexpectedEOF from here on and Complete before (measured).
    // ImageIO fills what is missing with grey and returns the picture anyway.
    CGImageSourceStatus status = CGImageSourceGetStatusAtIndex(source, 0);
    CFRelease(source);
    if (verr != kvImageNoError) {
        free(buffer.data);
        if (error) *error = fail([NSString stringWithFormat:@"the image could not be decoded (vImage error %ld)", (long)verr]);
        return nil;
    }
    if (status != kCGImageStatusComplete) {
        free(buffer.data);
        if (error) *error = fail([NSString stringWithFormat:@"%@ (the %@ is truncated or damaged, ImageIO status %d)",
                                     status == kCGImageStatusUnexpectedEOF ? @"unexpected end of file" : @"the image could not be decoded completely",
                                     png ? @"PNG" : uti, (int)status]);
        return nil;
    }

    // vImage already produced straight RGBA8 for every non-grey image. Metal
    // accepts that buffer's padded row stride directly: do not allocate and
    // copy a second full image just to remove padding. Grey custom images
    // still need their upstream-preserving expansion from grey/alpha to RGBA.
    if (grey) {
        uint8_t *rgba = malloc(w * h * 4);
        if (!rgba) {
            free(buffer.data);
            if (error) *error = fail(@"not enough memory to decode the image");
            return nil;
        }
        for (size_t y = 0; y < h; y++) {
            const uint8_t *row = (const uint8_t *)buffer.data + y * buffer.rowBytes;
            uint8_t *dst = rgba + y * w * 4;
            for (size_t x = 0; x < w; x++) {
                dst[4 * x] = dst[4 * x + 1] = dst[4 * x + 2] = row[2 * x];
                dst[4 * x + 3] = row[2 * x + 1];
            }
        }
        free(buffer.data);
        buffer.data = rgba;
        buffer.rowBytes = w * 4;
    }
    BOOL transparent = NO;
    // Inherited wallpaper has an opaque fill; shader textures derive their
    // output alpha in the shader. Neither consumer needs an image-alpha scan.
    if (hasTransparency) for (size_t y = 0; y < h && !transparent; y++) {
        const uint8_t *row = (const uint8_t *)buffer.data + y * buffer.rowBytes;
        for (size_t x = 0; x < w && !transparent; x++) transparent = row[4 * x + 3] < 255;
    }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    if (texture) [texture replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:buffer.data bytesPerRow:buffer.rowBytes];
    free(buffer.data);
    if (!texture) {
        if (error) *error = fail(@"upload failed (image likely too large) — gigapixel wallpapers need a tiled pyramidal TIFF");
        return nil;
    }
    if (size) *size = CGSizeMake(w, h);
    if (hasTransparency) *hasTransparency = transparent;
    return texture;
}

// MARK: - Config

@implementation IFBackgroundConfig

- (instancetype)init {
    if ((self = [super init])) {
        _type = IFBackgroundTypeDefault;
        _cacheBudgetMB = 128;
        _parallax = YES;
        _wallpaperScaling = NSImageScaleProportionallyUpOrDown;
        _wallpaperClipping = YES;
        _wallpaperFillColor = @[@0, @0, @0, @1];
    }
    return self;
}

- (void)setAnimateFPS:(NSUInteger)animateFPS {
    _animateFPS = MIN(animateFPS, (NSUInteger)1000);  // config/mod.rs: `.min(1000)`
}

- (id)copyWithZone:(NSZone *)zone {
    IFBackgroundConfig *c = [[IFBackgroundConfig allocWithZone:zone] init];
    c.type = _type;
    c.path = _path;
    c.texture = _texture;
    c.mirrorTile = _mirrorTile;
    c.cacheShader = _cacheShader;
    c.transparentShader = _transparentShader;
    c.cacheBudgetMB = _cacheBudgetMB;
    c.animateFPS = _animateFPS;
    c.parallax = _parallax;
    c.inheritedWallpaper = _inheritedWallpaper;
    c.wallpaperScaling = _wallpaperScaling;
    c.wallpaperClipping = _wallpaperClipping;
    c.wallpaperFillColor = _wallpaperFillColor;
    return c;
}

+ (instancetype)configWithTypeString:(NSString *)type
                                path:(NSString *)path
                             texture:(NSString *)texture
                             warning:(NSString **)warning {
    IFBackgroundConfig *c = [IFBackgroundConfig new];
    if (warning) *warning = nil;
    if (!type) return c;  // no `type`: default, whatever else is set
    NSString *expandedPath = path.stringByExpandingTildeInPath;
    NSDictionary<NSString *, NSNumber *> *sourced = @{
        @"shader": @(IFBackgroundTypeShader),
        @"tile": @(IFBackgroundTypeTile),
        @"wallpaper": @(IFBackgroundTypeWallpaper)};
    if (sourced[type] && path) {
        c.type = sourced[type].integerValue;
        c.path = expandedPath;
        if (c.type == IFBackgroundTypeShader) c.texture = texture.stringByExpandingTildeInPath;
    } else if ([type isEqualToString:@"default"]) {
        c.type = IFBackgroundTypeDefault;
    } else if ([type isEqualToString:@"none"]) {
        c.type = IFBackgroundTypeNone;
    } else if (!path) {
        if (warning) *warning = [NSString stringWithFormat:@"config: [background] type=\"%@\" requires `path`, using default", type];
    } else {
        if (warning) *warning = [NSString stringWithFormat:@"config: [background] unknown type \"%@\", using default", type];
    }
    return c;
}
@end

// MARK: - Chunk caches
//
// Adapted from DriftWM, https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/render/shader_chunks.rs
// (ShaderChunkCache: apron_dims, interior_src, bake_chunk, render_elements,
// shrink, visible_chunks), src/render/tile_chunks.rs
// (BgChunkCache: new_from_tiff, ensure_visible_loaded, drain_responses, shrink;
// pick_lod, derive_chunk_layout, compute_aggregations, compute_k_range,
// chunks_intersecting, visibility_query, chunk_actual_size, chunk_canvas_origin,
// evict_lru_to_budget, chunk_render_elements), src/render/elements.rs
// (tile_corner_round and corner_round_rect: the pixels a chunk covers),
// src/canvas.rs (visible_canvas_rect) and src/render/mod.rs (the call site: the
// visible rectangle, and eight uploads a frame). Upstream's names are kept so
// the two can be read side by side. One cache serves one output.

static const long kIFBGBaseChunkCanvas = 1024;            // shader_chunks.rs BASE_CHUNK_CANVAS
static const uint32_t kIFBGShaderLODs = 8;                // N_LODS
static const NSUInteger kIFBGBakeBudget = 2;              // BAKE_BUDGET
static const NSUInteger kIFBGLODSwitchBakeBudget = 16;    // LOD_SWITCH_BAKE_BUDGET
static const long kIFBGApronTexels = 1;                   // APRON_TEXELS
static const uint32_t kIFBGFallbackMaxDim = 4096;         // tile_chunks.rs FALLBACK_MAX_DIM, capture_background.rs TIFF_LOD_CAP
static const long kIFBGTargetChunkCanvas = 2048;          // TARGET_CHUNK_CANVAS
static const long kIFBGLOD0TargetChunkCanvas = 1024;      // LOD0_TARGET_CHUNK_CANVAS
static const NSUInteger kIFBGUploadBudget = 8;            // render/mod.rs: `ensure_visible_loaded(visible_rect, renderer, zoom, 8)`
enum { kIFBGMaxTileLODs = 64 };

static void IFBGPixelSize(IFBackgroundFrame f, long *logicalW, long *logicalH, NSUInteger *pxW, NSUInteger *pxH);

// Upstream `import_memory` of a decoded block: the bytes as they are.
static id<MTLTexture> IFBGUploadBlock(id<MTLDevice> device, IFBGTiffBlock *block) {
    if (!block.width || !block.height || block.width > kIFBGMaxTextureSide || block.height > kIFBGMaxTextureSide) return nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:block.width
                                                                                 height:block.height
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    [texture replaceRegion:MTLRegionMake2D(0, 0, block.width, block.height) mipmapLevel:0 withBytes:block.rgba.bytes
               bytesPerRow:(NSUInteger)block.width * 4];
    return texture;
}

// Rust's `i32::div_euclid` for a positive divisor.
static long IFBGDivFloor(long a, long b) {
    long q = a / b;
    return (a % b != 0 && a < 0) ? q - 1 : q;
}

// Rust's `f64::round() as i32`: half away from zero, saturating.
static long IFBGRoundI32(double v) {
    return (long)fmin(fmax(round(v), -2147483648.0), 2147483647.0);
}

// tile_chunks.rs `pick_lod`.
static uint32_t IFBGPickLOD(double zoom, uint32_t lodCount) {
    if (lodCount == 0) return 0;
    uint32_t last = lodCount - 1;
    if (zoom >= 1.0 || !isfinite(zoom)) return 0;
    if (zoom <= 0.0) return last;
    double raw = -log2(zoom);
    if (!isfinite(raw) || raw < 0.0) return 0;
    uint32_t targetCeil = (uint32_t)fmin(ceil(raw), 4294967295.0);
    // If ceil would pick the fallback LOD but we're not yet past the
    // power-of-two boundary (`raw >= last - 1.0`), stay one step finer.
    if (targetCeil >= last && raw < (double)last - 1.0) return last ? last - 1 : 0;
    return MIN(targetCeil, last);
}

// What one frame shows, in upstream's integers.
typedef struct {
    double zoom, scale;
    long cameraX, cameraY;   // `camera_i`: camera.round() as i32
    long viewX, viewY;       // canvas.rs `visible_canvas_rect(camera.to_i32_round(), viewport_size, zoom)`
    long viewW, viewH;       //   ceil(output / zoom) + 2
    float targetW, targetH;  // the render target in pixels
} IFBGChunkView;

static IFBGChunkView IFBGChunkViewMake(IFBackgroundFrame f) {
    IFBGChunkView v;
    v.zoom = (isfinite(f.zoom) && f.zoom > 0) ? f.zoom : 1.0;
    v.scale = (isfinite(f.scale) && f.scale > 0) ? f.scale : 1.0;
    long outW, outH;
    NSUInteger pxW, pxH;
    IFBGPixelSize(f, &outW, &outH, &pxW, &pxH);
    v.cameraX = IFBGRoundI32(isfinite(f.cameraX) ? f.cameraX : 0.0);
    v.cameraY = IFBGRoundI32(isfinite(f.cameraY) ? f.cameraY : 0.0);
    v.viewX = v.cameraX;
    v.viewY = v.cameraY;
    v.viewW = (long)fmin(ceil((double)outW / v.zoom), 2147483645.0) + 2;
    v.viewH = (long)fmin(ceil((double)outH / v.zoom), 2147483645.0) + 2;
    v.targetW = (float)pxW;
    v.targetH = (float)pxH;
    return v;
}

// Baked shaders and TIFF chunks are static in canvas space. A new content
// frame can advance only time while the background's view is unchanged;
// settled caches then reuse their quads without rebuilding their working set.
// Keep the exact-instant check as well: a cache still filling may spend its
// bake/upload allowance only once for that instant.
static BOOL IFBGSameChunkView(IFBackgroundFrame a, IFBackgroundFrame b) {
    return a.cameraX == b.cameraX && a.cameraY == b.cameraY && a.zoom == b.zoom &&
           a.width == b.width && a.height == b.height && a.scale == b.scale;
}

// The pixels an element with this area covers. `x, y` are relative to
// `camera_i`. elements.rs `tile_corner_round` takes the area to physical
// pixels and `corner_round_rect` (PixelSnapRescaleElement, anchored at the
// output's origin) rescales that by zoom; both round the two corners
// separately, so two chunks that share a canvas edge share the pixel edge.
static simd_float4 IFBGChunkDst(long x, long y, long w, long h, const IFBGChunkView *v) {
    double x0 = round((double)x * v->scale), y0 = round((double)y * v->scale);
    double x1 = fmax(round((double)(x + w) * v->scale), x0), y1 = fmax(round((double)(y + h) * v->scale), y0);
    double X0 = round(x0 * v->zoom), Y0 = round(y0 * v->zoom);
    double X1 = fmax(round(x1 * v->zoom), X0), Y1 = fmax(round(y1 * v->zoom), Y0);
    return simd_make_float4((float)X0, (float)Y0, (float)X1, (float)Y1);
}

// A chunk texture and upstream's `ChunkMeta`.
@interface IFBGChunk : NSObject {
  @public
    id<MTLTexture> texture;
    uint64_t bytes;    // `bytes`
    uint64_t touched;  // `last_touched_frame`
    uint32_t lod;
    long cx, cy;
}
@end
@implementation IFBGChunk
@end

// One quad of a frame. It holds its texture, so a chunk evicted at the end of
// the frame that chose it is still drawn by that frame.
@interface IFBGChunkDraw : NSObject {
  @public
    id<MTLTexture> texture;
    IFBGChunkUniforms uniforms;
    uint32_t lod;
}
@end
@implementation IFBGChunkDraw
@end

static NSNumber *IFBGChunkKey(uint32_t lod, long cx, long cy) {
    return @(((uint64_t)lod << 56) | (((uint64_t)cx & 0xFFFFFFFull) << 28) | ((uint64_t)cy & 0xFFFFFFFull));
}

// tile_chunks.rs `evict_lru_to_budget`: least recently stamped first, until
// the cache fits. Returns how many were dropped.
static NSUInteger IFBGEvictLRU(NSMutableDictionary<NSNumber *, IFBGChunk *> *chunks, uint64_t *bytes, uint64_t budget) {
    if (*bytes <= budget) return 0;
    NSArray<NSNumber *> *byAge = [chunks keysSortedByValueUsingComparator:^NSComparisonResult(IFBGChunk *a, IFBGChunk *b) {
        return a->touched < b->touched ? NSOrderedAscending : a->touched > b->touched ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger evicted = 0;
    for (NSNumber *key in byAge) {
        if (*bytes <= budget) break;
        uint64_t freed = chunks[key]->bytes;
        *bytes = *bytes > freed ? *bytes - freed : 0;  // `saturating_sub`
        [chunks removeObjectForKey:key];
        evicted++;
    }
    return evicted;
}

// Upstream emits its elements topmost first (ascending LOD); a pass without
// blending wants them bottom first: the coarsest LOD, then each finer one.
static NSArray<IFBGChunkDraw *> *IFBGSortDraws(NSArray<IFBGChunkDraw *> *draws) {
    return [draws sortedArrayUsingComparator:^NSComparisonResult(IFBGChunkDraw *a, IFBGChunkDraw *b) {
        return a->lod > b->lod ? NSOrderedAscending : a->lod < b->lod ? NSOrderedDescending : NSOrderedSame;
    }];
}

// MARK: Baked shader (shader_chunks.rs)

// shader_chunks.rs `apron_dims`: the padded canvas span a chunk's bake renders,
// the square texture it lands in, and the border's width in canvas units.
static void IFBGApronDims(long chunkSize, long bakePx, long *areaCanvas, long *fboTexels, long *apronCanvas) {
    double scale = (double)bakePx / (double)chunkSize;
    long apron = MAX((long)ceil((double)kIFBGApronTexels / scale), 1L);
    long area = chunkSize + 2 * apron;
    *apronCanvas = apron;
    *areaCanvas = area;
    *fboTexels = (long)fmax(round((double)area * scale), 1.0);
}

@interface IFBGShaderChunks : NSObject
- (instancetype)initWithResources:(IFBGDeviceResources *)resources
                           shader:(id<MTLRenderPipelineState>)shader
                            scale:(double)scale
                           budget:(uint64_t)budget;
/// The output scale the chunks are baked for (upstream fixes `bake_px` when it
/// builds the cache and drops the cache when the output's scale changes).
@property (nonatomic, readonly) double scale;
/// `render_elements`: bakes what this frame may, and returns its quads bottom
/// first. nil when the coarse cover could not be baked: the caller draws live.
- (nullable NSArray<IFBGChunkDraw *> *)drawsForFrame:(IFBackgroundFrame)frame;
- (void)shrink;
@property (nonatomic, readonly) NSUInteger pendingCount;
@property (nonatomic, readonly) uint64_t bytes;
/// Changes whenever the cached chunks do: a bake or an upload, an eviction, a shrink that dropped something.
@property (nonatomic, readonly) uint64_t generation;
@end

@implementation IFBGShaderChunks {
    IFBGDeviceResources *_resources;
    id<MTLRenderPipelineState> _shader;
    long _bakePx;         // `bake_px`
    uint64_t _budget;     // `vram_budget_bytes`
    NSMutableDictionary<NSNumber *, IFBGChunk *> *_chunks;
    uint64_t _frameCounter;
    BOOL _hasLastTarget;
    uint32_t _lastTarget;  // `last_target_lod`
    BOOL _shrunk;
    BOOL _broken;          // a bake failed on the GPU: this cache draws nothing more
    BOOL _coverTooLarge;   // the last frame's coarse cover exceeded the budget by itself
    BOOL _degraded;        // `degraded`
    BOOL _hasPlan;
    BOOL _planSettled;
    IFBackgroundFrame _planFrame;
    NSArray<IFBGChunkDraw *> *_plan;
}

- (instancetype)initWithResources:(IFBGDeviceResources *)resources
                           shader:(id<MTLRenderPipelineState>)shader
                            scale:(double)scale
                           budget:(uint64_t)budget {
    if (!(self = [super init])) return nil;
    _resources = resources;
    _shader = shader;
    _scale = scale;
    // `((BASE_CHUNK_CANVAS as f64) * output_scale).round().max(1.0) as i32`
    _bakePx = (long)fmin(fmax(round((double)kIFBGBaseChunkCanvas * scale), 1.0), 2147483647.0);
    _budget = budget;
    _chunks = [NSMutableDictionary dictionary];
    return self;
}

- (uint64_t)chunkBytes:(long)chunkSize {
    long area, fbo, apron;
    IFBGApronDims(chunkSize, _bakePx, &area, &fbo, &apron);
    return (uint64_t)fbo * (uint64_t)fbo * 4;
}

// `shrink`: the sharp bakes go, the coarsest cover stays as the floor the next
// canvas frame refines from.
- (void)shrink {
    if (_shrunk) return;
    _shrunk = YES;
    _hasPlan = NO;
    _plan = nil;
    uint32_t coarsest = kIFBGShaderLODs - 1;
    _bytes = 0;
    for (NSNumber *key in _chunks.allKeys) {
        IFBGChunk *chunk = _chunks[key];
        if (chunk->lod == coarsest) {
            _bytes += chunk->bytes;  // `retain_lod_meta`: recounted, not zeroed
        } else {
            [_chunks removeObjectForKey:key];
            _generation++;
        }
    }
    _pendingCount = 0;
}

// `bake_chunk`, for every chunk this frame bakes, in one command buffer of the
// module's own queue that is complete before the frame samples the textures.
// The shader runs once over the chunk's canvas span plus its apron, with
// `size` that padded span and `u_camera` its top-left corner, through the
// same pipeline and uniform block as a live frame. A chunk whose texture
// cannot be made is left uncached.
- (void)bake:(NSArray<IFBGChunk *> *)wanted frame:(uint64_t)frame {
    if (!wanted.count) return;
    id<MTLCommandBuffer> commandBuffer = [_resources.queue commandBuffer];
    if (!commandBuffer) return;
    NSMutableArray<IFBGChunk *> *baked = [NSMutableArray array];
    for (IFBGChunk *chunk in wanted) {
        long chunkSize = kIFBGBaseChunkCanvas << chunk->lod, area, fbo, apron;
        IFBGApronDims(chunkSize, _bakePx, &area, &fbo, &apron);
        id<MTLTexture> texture = nil;
        if (fbo <= (long)kIFBGMaxTextureSide) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:(NSUInteger)fbo
                                                                                         height:(NSUInteger)fbo
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            texture = [_resources.device newTextureWithDescriptor:td];
        }
        if (!texture) {
            NSLog(@"background: shader-bake (LOD %u, %ld,%ld) create_buffer failed", chunk->lod, chunk->cx, chunk->cy);
            continue;
        }
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) continue;
        IFBGUniforms u;
        memset(&u, 0, sizeof u);
        // `Uniform::new("u_camera", ((origin.x - apron_canvas) as f32, (origin.y - apron_canvas) as f32))`
        u.camera = simd_make_float2((float)(chunk->cx * chunkSize - apron), (float)(chunk->cy * chunkSize - apron));
        // The PixelShaderElement's area is the padded span, and its geometry at
        // `bake_px / chunk_size` is the whole texture.
        u.size = simd_make_float2((float)area, (float)area);
        u.dest_px = simd_make_float2((float)fbo, (float)fbo);
        u.src_size = simd_make_float2(1, 1);
        u.time = 0.0f;  // `Uniform::new("u_time", 0.0f32)`
        u.zoom = 1.0f;  // `Uniform::new("u_zoom", 1.0f32)`
        u.alpha = 1.0f;
        u.opaque = 1.0f;  // a baked shader is never `transparent_shader`
        [encoder setRenderPipelineState:_shader];
        [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
        [encoder setFragmentTexture:_resources.placeholderTexture atIndex:0];
        [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        chunk->texture = texture;
        chunk->bytes = (uint64_t)fbo * (uint64_t)fbo * 4;
        chunk->touched = frame;
        [baked addObject:chunk];
    }
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        NSLog(@"background: shader-bake render_output failed: %@", commandBuffer.error.localizedDescription);
        _broken = YES;
        return;
    }
    for (IFBGChunk *chunk in baked) {
        _chunks[IFBGChunkKey(chunk->lod, chunk->cx, chunk->cy)] = chunk;
        _bytes += chunk->bytes;
        _generation++;
    }
}

static IFBGChunk *IFBGChunkMake(uint32_t lod, long cx, long cy) {
    IFBGChunk *chunk = [IFBGChunk new];
    chunk->lod = lod;
    chunk->cx = cx;
    chunk->cy = cy;
    return chunk;
}

- (NSArray<IFBGChunkDraw *> *)drawsForFrame:(IFBackgroundFrame)f {
    if (_broken) return nil;
    if (_hasPlan && (memcmp(&f, &_planFrame, sizeof f) == 0 ||
                     (_planSettled && IFBGSameChunkView(f, _planFrame)))) return _plan;
    _hasPlan = NO;
    _plan = nil;
    IFBGChunkView v = IFBGChunkViewMake(f);
    _shrunk = NO;
    uint64_t frame = ++_frameCounter;
    uint32_t target = IFBGPickLOD(v.zoom, kIFBGShaderLODs), coarsest = kIFBGShaderLODs - 1;
    NSMutableArray<IFBGChunk *> *bakes = [NSMutableArray array];

    // Resident coarse cover: baked unbudgeted, once, and stamped every frame.
    // `visible_chunks(viewport, size)`: the cells the visible rectangle touches.
    long coverSize = kIFBGBaseChunkCanvas << coarsest;
    long coverX0 = IFBGDivFloor(v.viewX, coverSize), coverX1 = IFBGDivFloor(v.viewX + v.viewW - 1, coverSize);
    long coverY0 = IFBGDivFloor(v.viewY, coverSize), coverY1 = IFBGDivFloor(v.viewY + v.viewH - 1, coverSize);
    // Not upstream: a cover that does not fit the budget by itself is not baked.
    // Upstream bakes it for every frame it draws and evicts it again when the
    // frame ends, however many cells a far zoom-out makes it; here such a frame
    // is the live shader's (BACKGROUND-NOTES.md, section 17).
    uint64_t coverBytes = (uint64_t)((coverX1 - coverX0 + 1) * (coverY1 - coverY0 + 1)) * [self chunkBytes:coverSize];
    if (coverBytes > _budget) {
        if (!_coverTooLarge) {
            NSLog(@"shader-bake: cache_budget_mb too low for this view's coarse cover (%llu MB > %llu MB budget); rendering the shader live. "
                   "Raise cache_budget_mb to bake it.", coverBytes / (1024 * 1024), _budget / (1024 * 1024));
        }
        _coverTooLarge = YES;
        _pendingCount = 0;
        return nil;
    }
    _coverTooLarge = NO;
    for (long cy = coverY0; cy <= coverY1; cy++) {
        for (long cx = coverX0; cx <= coverX1; cx++) {
            IFBGChunk *chunk = _chunks[IFBGChunkKey(coarsest, cx, cy)];
            if (chunk) {
                chunk->touched = frame;
            } else {
                [bakes addObject:IFBGChunkMake(coarsest, cx, cy)];
            }
        }
    }

    long targetSize = kIFBGBaseChunkCanvas << target;
    long x0 = IFBGDivFloor(v.viewX, targetSize), x1 = IFBGDivFloor(v.viewX + v.viewW - 1, targetSize);
    long y0 = IFBGDivFloor(v.viewY, targetSize), y1 = IFBGDivFloor(v.viewY + v.viewH - 1, targetSize);

    // Graceful degrade: when cover and sharp working set cannot both fit the
    // budget, the sharp chunks are not baked and the cover alone is shown.
    uint64_t workingSet = (uint64_t)((coverX1 - coverX0 + 1) * (coverY1 - coverY0 + 1)) * [self chunkBytes:coverSize] +
                          (uint64_t)((x1 - x0 + 1) * (y1 - y0 + 1)) * [self chunkBytes:targetSize];
    BOOL degraded = workingSet > _budget;
    if (degraded != _degraded) {
        _degraded = degraded;
        if (degraded) {
            NSLog(@"shader-bake: cache_budget_mb too low for this view (%llu MB working set > %llu MB budget); "
                   "showing coarse cover only. Raise cache_budget_mb for sharp detail.",
                  workingSet / (1024 * 1024), _budget / (1024 * 1024));
        }
    }

    // Budgeted fine refine at the target LOD, with the larger one-shot budget
    // on the frame the LOD changes.
    BOOL lodChanged = !_hasLastTarget || _lastTarget != target;
    NSUInteger budget = lodChanged ? kIFBGLODSwitchBakeBudget : kIFBGBakeBudget, baked = 0;
    _pendingCount = 0;
    if (target != coarsest && !degraded) {
        for (long cy = y0; cy <= y1; cy++) {
            for (long cx = x0; cx <= x1; cx++) {
                IFBGChunk *chunk = _chunks[IFBGChunkKey(target, cx, cy)];
                if (chunk) {
                    chunk->touched = frame;
                } else if (baked < budget) {
                    [bakes addObject:IFBGChunkMake(target, cx, cy)];
                    baked++;
                } else {
                    _pendingCount++;
                }
            }
        }
    }
    if (!degraded) {
        _lastTarget = target;
        _hasLastTarget = YES;
    }
    [self bake:bakes frame:frame];
    if (_broken) {
        _pendingCount = 0;
        return nil;
    }

    // Resolve coarse-to-fine: for each visible target cell the finest cached
    // chunk that covers it, stamped so that it survives this frame's eviction.
    NSMutableDictionary<NSNumber *, IFBGChunk *> *chosen = [NSMutableDictionary dictionary];
    BOOL covered = YES;
    for (long cy = y0; cy <= y1; cy++) {
        for (long cx = x0; cx <= x1; cx++) {
            long canvasX = cx * targetSize, canvasY = cy * targetSize;
            BOOL found = NO;
            for (uint32_t lod = target; lod <= coarsest && !found; lod++) {
                long size = kIFBGBaseChunkCanvas << lod;
                NSNumber *key = IFBGChunkKey(lod, IFBGDivFloor(canvasX, size), IFBGDivFloor(canvasY, size));
                IFBGChunk *chunk = _chunks[key];
                if (!chunk) continue;
                chunk->touched = frame;
                chosen[key] = chunk;
                found = YES;
            }
            covered = covered && found;
        }
    }
    if (!covered) {
        _pendingCount = 0;
        return nil;
    }

    NSMutableArray<IFBGChunkDraw *> *draws = [NSMutableArray arrayWithCapacity:chosen.count];
    for (IFBGChunk *chunk in chosen.allValues) {
        long chunkSize = kIFBGBaseChunkCanvas << chunk->lod, area, fbo, apron;
        IFBGApronDims(chunkSize, _bakePx, &area, &fbo, &apron);
        // `interior_src`: the chunk's own span inside its apron, in texels.
        double texelsPerCanvas = (double)fbo / (double)area;
        IFBGChunkDraw *draw = [IFBGChunkDraw new];
        draw->texture = chunk->texture;
        draw->lod = chunk->lod;
        draw->uniforms.dst = IFBGChunkDst(chunk->cx * chunkSize - v.cameraX, chunk->cy * chunkSize - v.cameraY, chunkSize, chunkSize, &v);
        draw->uniforms.src = simd_make_float4((float)((double)apron * texelsPerCanvas), (float)((double)apron * texelsPerCanvas),
                                              (float)((double)chunkSize * texelsPerCanvas), (float)((double)chunkSize * texelsPerCanvas));
        draw->uniforms.target = simd_make_float2(v.targetW, v.targetH);
        draw->uniforms.tex_size = simd_make_float2((float)fbo, (float)fbo);
        [draws addObject:draw];
    }

    // Evict last, so that the chunks chosen for this frame are protected.
    NSUInteger evicted = IFBGEvictLRU(_chunks, &_bytes, _budget);
    _generation += evicted;
    _plan = IFBGSortDraws(draws);
    _planFrame = f;
    _hasPlan = YES;
    // A failed texture allocation can leave a useful coarse plan despite a
    // bake attempt. Retry that attempt on a later frame instead of treating
    // it as settled merely because no allowance-limited bakes remain.
    _planSettled = bakes.count == 0 && _pendingCount == 0;
    return _plan;
}
@end

// MARK: Pyramidal TIFF (tile_chunks.rs)

// What `new_from_tiff` derives from the file once: shared by every output.
@interface IFBGTileLayout : NSObject {
  @public
    long imageW, imageH;                      // `image_dims`: LOD 0, the wrap period in canvas units
    long positionX, positionY;                // `image_position`: the image is centred on canvas (0, 0)
    uint32_t lodCount;                        // `n_lods()`: the last one is the fallback plane
    long sizes[kIFBGMaxTileLODs];             // `chunk_canvas_sizes`
    uint32_t aggregations[kIFBGMaxTileLODs];  // `aggregations`
    IFBGTiffLevel levels[kIFBGMaxTileLODs];
}
@end
@implementation IFBGTileLayout
@end

// `derive_chunk_layout`, `compute_aggregations` and the choice of the fallback
// LOD in `new_from_tiff`. Returns nil and sets `*error` to upstream's message.
static IFBGTileLayout *IFBGTileLayoutMake(IFBGTiffSource *source, NSString **error) {
    NSUInteger pages = MIN(source.levelCount, (NSUInteger)kIFBGMaxTileLODs);
    IFBGTileLayout *layout = [IFBGTileLayout new];
    for (NSUInteger i = 0; i < pages; i++) {
        layout->levels[i] = [source levelAtIndex:i];
        if (layout->levels[i].tileWidth != layout->levels[i].tileHeight) {
            *error = [NSString stringWithFormat:@"LOD %lu: non-square tile dims (%u, %u) not supported", (unsigned long)i,
                                                layout->levels[i].tileWidth, layout->levels[i].tileHeight];
            return nil;
        }
    }
    if (!pages) {
        *error = @"TIFF has no LOD levels";
        return nil;
    }
    layout->imageW = layout->levels[0].imageWidth;
    layout->imageH = layout->levels[0].imageHeight;
    if (layout->imageW > INT32_MAX || layout->imageH > INT32_MAX) {
        *error = @"dimensions: the image is too large";
        return nil;
    }
    // The canvas span of one TIFF tile at each LOD. The pyramid is cut at the
    // first step that is not exactly 2x: vips can leave the last page a pixel off.
    long raw[kIFBGMaxTileLODs];
    NSUInteger usable = pages;
    for (NSUInteger i = 0; i < pages; i++) {
        double scale = (double)layout->imageW / (double)layout->levels[i].imageWidth;
        double span = round((double)layout->levels[i].tileWidth * scale);
        if (!(span > 0)) {
            *error = [NSString stringWithFormat:@"LOD %lu: derived canvas chunk size %ld <= 0", (unsigned long)i, (long)span];
            return nil;
        }
        raw[i] = (long)fmin(span, 2147483647.0);
    }
    for (NSUInteger i = 1; i < pages; i++) {
        if (raw[i] != 2 * raw[i - 1]) {
            NSLog(@"background: chunked tile-bg: LOD %lu raw canvas chunk size %ld != 2× LOD %lu (%ld); truncating pyramid to %lu usable LOD(s)",
                  (unsigned long)i, raw[i], (unsigned long)(i - 1), raw[i - 1], (unsigned long)i);
            usable = i;
            break;
        }
    }
    for (NSUInteger i = 0; i < usable; i++) {
        long target = i == 0 ? kIFBGLOD0TargetChunkCanvas : kIFBGTargetChunkCanvas;
        layout->aggregations[i] = (raw[i] > 0 && raw[i] < target) ? (uint32_t)MAX(target / raw[i], 1L) : 1;
        layout->sizes[i] = raw[i] * (long)layout->aggregations[i];
    }
    // The fallback plane is the finest LOD that fits FALLBACK_MAX_DIM, else the
    // coarsest, which has to be small enough to hold whole (v0.21.0 `whole_lod`:
    // past 16384 px a side it is an error and not an allocation that can abort);
    // the LODs past it are not used.
    NSUInteger fallback = IFBGTiffWholeLevel(layout->levels, usable, kIFBGFallbackMaxDim, error);
    if (fallback == NSNotFound) return nil;
    layout->lodCount = (uint32_t)fallback + 1;
    // `Point::from((-(image_dims.0 as i32) / 2, -(image_dims.1 as i32) / 2))`
    layout->positionX = -layout->imageW / 2;
    layout->positionY = -layout->imageH / 2;
    return layout;
}

// The texels of chunk `(cx, cy)` at `lod`: `read_block`'s cropped block.
static void IFBGTileChunkTexels(const IFBGTileLayout *l, uint32_t lod, long cx, long cy, long *w, long *h) {
    IFBGTiffLevel level = l->levels[lod];
    long n = l->aggregations[lod], tile = level.tileWidth;
    long across = ((long)level.imageWidth + tile - 1) / tile, down = ((long)level.imageHeight + tile - 1) / tile;
    long endX = MIN(cx * n + n, across), endY = MIN(cy * n + n, down);
    *w = MAX(MIN(endX * tile, (long)level.imageWidth) - cx * n * tile, 0L);
    *h = MAX(MIN(endY * tile, (long)level.imageHeight) - cy * n * tile, 0L);
}

// `visibility_query`: every chunk `(cx, cy)` of every image instance
// `(kx, ky)` the visible rectangle touches (`compute_k_range`,
// `chunks_intersecting`). The image repeats with its own period; a chunk past
// its right or bottom edge is never listed. A NO result stops enumeration once
// a caller has exhausted its budget; subsequent cells would do no work.
static void IFBGVisibilityQuery(const IFBGChunkView *v, const IFBGTileLayout *l, long chunkSize,
                                BOOL (^each)(long cx, long cy, long kx, long ky)) {
    if (chunkSize <= 0 || v->viewW <= 0 || v->viewH <= 0 || l->imageW <= 0 || l->imageH <= 0) return;
    long kx0 = IFBGDivFloor(v->viewX - l->positionX, l->imageW), kx1 = IFBGDivFloor(v->viewX + v->viewW - 1 - l->positionX, l->imageW);
    long ky0 = IFBGDivFloor(v->viewY - l->positionY, l->imageH), ky1 = IFBGDivFloor(v->viewY + v->viewH - 1 - l->positionY, l->imageH);
    for (long ky = ky0; ky <= ky1; ky++) {
        for (long kx = kx0; kx <= kx1; kx++) {
            long relX = v->viewX - (l->positionX + kx * l->imageW), relY = v->viewY - (l->positionY + ky * l->imageH);
            long minX = MAX(relX, 0L), minY = MAX(relY, 0L);
            long maxX = MIN(relX + v->viewW, l->imageW), maxY = MIN(relY + v->viewH, l->imageH);
            if (minX >= maxX || minY >= maxY) continue;
            for (long cy = minY / chunkSize; cy <= (maxY - 1) / chunkSize; cy++) {
                for (long cx = minX / chunkSize; cx <= (maxX - 1) / chunkSize; cx++) {
                    if (!each(cx, cy, kx, ky)) return;
                }
            }
        }
    }
}

@interface IFBGTileChunks : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device
                        source:(IFBGTiffSource *)source
                        layout:(IFBGTileLayout *)layout
                        budget:(uint64_t)budget;
/// Main thread: a decoded chunk waits to be uploaded.
@property (nonatomic, copy, nullable) dispatch_block_t readyHandler;
/// `ensure_visible_loaded` and the per-tile part of `chunk_render_elements`:
/// uploads what this frame may, asks for what is missing, and returns the
/// quads of the chunks that are ready, bottom first. The fallback plane under
/// them is the caller's.
- (NSArray<IFBGChunkDraw *> *)drawsForFrame:(IFBackgroundFrame)frame;
- (void)shrink;
@property (nonatomic, readonly) NSUInteger pendingCount;
@property (nonatomic, readonly) uint64_t bytes;
/// Changes whenever the cached chunks do: a bake or an upload, an eviction, a shrink that dropped something.
@property (nonatomic, readonly) uint64_t generation;
@end

@implementation IFBGTileChunks {
    id<MTLDevice> _device;
    IFBGTileLayout *_layout;
    IFBGTileWorkerPool *_pool;
    uint64_t _budget;  // `vram_budget_bytes`
    NSMutableDictionary<NSNumber *, IFBGChunk *> *_chunks;
    NSMutableSet<NSNumber *> *_inFlight;  // `in_flight`
    NSMutableSet<NSNumber *> *_failed;    // `failed`
    uint64_t _frameCounter;
    BOOL _shrunk;
    atomic_bool _wakePosted;
    BOOL _degraded;  // the last frame's working set exceeded the budget
    BOOL _hasPlan;
    IFBackgroundFrame _planFrame;
    NSArray<IFBGChunkDraw *> *_plan;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                        source:(IFBGTiffSource *)source
                        layout:(IFBGTileLayout *)layout
                        budget:(uint64_t)budget {
    if (!(self = [super init])) return nil;
    _device = device;
    _layout = layout;
    _budget = budget;
    _chunks = [NSMutableDictionary dictionary];
    _inFlight = [NSMutableSet set];
    _failed = [NSMutableSet set];
    atomic_init(&_wakePosted, false);
    // The pool must not keep its cache alive: the decodes outlive nothing.
    __weak IFBGTileChunks *weak = self;
    _pool = [[IFBGTileWorkerPool alloc] initWithSource:source wake:^{ [weak wake]; }];
    return self;
}

- (void)dealloc {
    [_pool shutdown];
}

// `loop_signal.wakeup()`, from a decoder's thread: one message to the main
// thread however many chunks finish before it is delivered.
- (void)wake {
    if (atomic_exchange(&_wakePosted, true)) return;
    __weak IFBGTileChunks *weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        IFBGTileChunks *cache = weak;
        if (!cache) return;
        atomic_store(&cache->_wakePosted, false);
        // What arrived may change a frame already encoded for this instant.
        cache->_hasPlan = NO;
        dispatch_block_t handler = cache.readyHandler;
        if (handler) handler();
    });
}

// `has_pending_loads`: decodes asked for and not yet uploaded or failed.
- (NSUInteger)pendingCount {
    return _inFlight.count;
}

// `shrink`: every per-tile chunk goes, every request with it, and what a
// decoder still delivers is discarded. The failed set stays.
- (void)shrink {
    while ([_pool tryReceive]) {
    }
    if (_shrunk) return;
    _shrunk = YES;
    _hasPlan = NO;
    _plan = nil;
    _generation += _chunks.count;
    [_chunks removeAllObjects];
    _bytes = 0;
    [_pool drainPending];
    [_inFlight removeAllObjects];
}

// `drain_responses`: at most `budget` decoded blocks become textures.
- (void)drainResponses:(NSUInteger)budget frame:(uint64_t)frame {
    NSUInteger uploaded = 0;
    while (uploaded < budget) {
        IFBGTileResponse *response = [_pool tryReceive];
        if (!response) break;
        NSNumber *key = IFBGChunkKey(response.level, (long)response.cx, (long)response.cy);
        // A shrink dropped the request this answers.
        if (![_inFlight containsObject:key]) continue;
        [_inFlight removeObject:key];
        IFBGTiffBlock *block = response.block;
        if (!block) {
            NSLog(@"background: chunked tile (LOD %u, %u,%u) decode: %@", response.level, response.cx, response.cy, response.error);
            [_failed addObject:key];
            continue;
        }
        id<MTLTexture> texture = IFBGUploadBlock(_device, block);
        if (!texture) {
            NSLog(@"background: chunked tile (LOD %u, %u,%u) import_memory failed", response.level, response.cx, response.cy);
            [_failed addObject:key];
            continue;
        }
        IFBGChunk *chunk = IFBGChunkMake(response.level, (long)response.cx, (long)response.cy);
        chunk->texture = texture;
        chunk->bytes = (uint64_t)block.width * (uint64_t)block.height * 4;
        chunk->touched = frame;
        _chunks[key] = chunk;
        _bytes += chunk->bytes;
        _generation++;
        uploaded++;
    }
}

- (NSArray<IFBGChunkDraw *> *)drawsForFrame:(IFBackgroundFrame)f {
    if (_hasPlan && (memcmp(&f, &_planFrame, sizeof f) == 0 ||
                     (!_inFlight.count && IFBGSameChunkView(f, _planFrame)))) return _plan;
    _hasPlan = NO;
    _plan = nil;
    IFBGChunkView view = IFBGChunkViewMake(f);
    const IFBGChunkView *v = &view;
    IFBGTileLayout *l = _layout;

    // ensure_visible_loaded
    _shrunk = NO;
    uint64_t frame = ++_frameCounter;
    [self drainResponses:kIFBGUploadBudget frame:frame];
    uint32_t coarsest = l->lodCount - 1, target = IFBGPickLOD(v->zoom, l->lodCount);

    // Every LOD finer than the fallback plane, coarse first: the chunks the
    // view touches are stamped when cached, so that eviction cannot take the
    // coarse cover from under a fine LOD that is still loading, and asked of
    // the decoders when not. Upstream does the two in separate passes over the
    // same chunks.
    //
    // Not upstream: the chunks are counted against the budget as they are
    // met, and from the first one that no longer fits nothing is stamped or
    // asked for. Upstream asks for all of them; when they exceed the budget
    // every frame evicts chunks the next frame asks for again, and
    // `has_pending_loads` never clears (BACKGROUND-NOTES.md, section 17).
    __block uint64_t wanted = 0;
    __block BOOL over = NO;
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (uint32_t lod = coarsest; !over && lod-- > target;) {
        uint32_t aggregation = l->aggregations[lod];
        IFBGVisibilityQuery(v, l, l->sizes[lod], ^BOOL(long cx, long cy, long kx, long ky) {
            (void)kx;
            (void)ky;
            NSNumber *key = IFBGChunkKey(lod, cx, cy);
            if ([seen containsObject:key]) return YES;
            [seen addObject:key];
            long texelsW, texelsH;
            IFBGTileChunkTexels(l, lod, cx, cy, &texelsW, &texelsH);
            uint64_t bytes = (uint64_t)texelsW * (uint64_t)texelsH * 4;
            if (wanted + bytes > self->_budget) {
                over = YES;
                return NO;
            }
            wanted += bytes;
            IFBGChunk *chunk = self->_chunks[key];
            if (chunk) {
                chunk->touched = frame;
                return YES;
            }
            if ([self->_inFlight containsObject:key] || [self->_failed containsObject:key]) return YES;
            [self->_inFlight addObject:key];
            [self->_pool enqueueLevel:lod cx:(uint32_t)cx cy:(uint32_t)cy aggregation:aggregation];
            return YES;
        });
    }
    if (over != _degraded) {
        _degraded = over;
        if (over) {
            NSLog(@"chunked tile-bg: cache_budget_mb too low for this view (%llu MB budget); keeping the coarser levels that fit. "
                   "Raise cache_budget_mb for sharp detail.", _budget / (1024 * 1024));
        }
    }
    NSUInteger evicted = IFBGEvictLRU(_chunks, &_bytes, _budget);
    _generation += evicted;

    // chunk_render_elements: for each visible target cell of each image
    // instance, the finest cached chunk that covers it.
    NSMutableDictionary<NSString *, IFBGChunkDraw *> *chosen = [NSMutableDictionary dictionary];
    if (target < coarsest) {
        long targetSize = l->sizes[target];
        IFBGVisibilityQuery(v, l, targetSize, ^BOOL(long cxT, long cyT, long kx, long ky) {
            // (kx, ky) places the element; the coarser chunk is looked up on
            // the image's own grid.
            long canvasX = cxT * targetSize, canvasY = cyT * targetSize;
            for (uint32_t lod = target; lod < coarsest; lod++) {
                long size = l->sizes[lod], cx = IFBGDivFloor(canvasX, size), cy = IFBGDivFloor(canvasY, size);
                IFBGChunk *chunk = self->_chunks[IFBGChunkKey(lod, cx, cy)];
                if (!chunk) continue;
                NSString *key = [NSString stringWithFormat:@"%u/%ld/%ld/%ld/%ld", lod, cx, cy, kx, ky];
                if (chosen[key]) return YES;
                // `chunk_actual_size`: a chunk at the image's right or bottom
                // edge is as wide as what is left of the image.
                long w = MIN(MAX(l->imageW - cx * size, 0L), size), h = MIN(MAX(l->imageH - cy * size, 0L), size);
                // `chunk_canvas_origin`
                long originX = l->positionX + kx * l->imageW + cx * size, originY = l->positionY + ky * l->imageH + cy * size;
                IFBGChunkDraw *draw = [IFBGChunkDraw new];
                draw->texture = chunk->texture;
                draw->lod = lod;
                draw->uniforms.dst = IFBGChunkDst(originX - v->cameraX, originY - v->cameraY, w, h, v);
                // The whole texture, whose size in texels is the texture's own.
                draw->uniforms.src = simd_make_float4(0, 0, (float)chunk->texture.width, (float)chunk->texture.height);
                draw->uniforms.target = simd_make_float2(v->targetW, v->targetH);
                draw->uniforms.tex_size = simd_make_float2((float)chunk->texture.width, (float)chunk->texture.height);
                chosen[key] = draw;
                return YES;
            }
            return YES;
        });
    }
    _plan = IFBGSortDraws(chosen.allValues);
    _planFrame = f;
    _hasPlan = YES;
    return _plan;
}
@end

// MARK: - Program

@interface IFBackgroundProgram ()
- (id<MTLCommandQueue>)commandQueue;
@end

@implementation IFBackgroundProgram {
    IFBGDeviceResources *_resources;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _texture;
    simd_float4 _wallpaperFill;
    // A pyramidal TIFF, as every program of one load shares it: the open file,
    // what `new_from_tiff` derived from it, and (in `_texture`) its fallback level.
    IFBGTiffSource *_tiff;
    IFBGTileLayout *_layout;
    NSUInteger _fallbackHoles;   // tiles of the fallback level that could not be decoded
    BOOL _fallbackTransparency;  // some texel of it is not opaque
    IFBackgroundProgram *_captureTwin;
    // This program's own chunk cache, made by its first frame.
    IFBGShaderChunks *_shaderChunks;
    IFBGTileChunks *_tileChunks;
    // Image size in pixels for tile / wallpaper / textured shader, else zero.
    // For a pyramidal TIFF: the size of its full-resolution level.
    CGSize _textureSize;
}

+ (instancetype)programWithConfig:(IFBackgroundConfig *)config device:(id<MTLDevice>)device {
    if (!device) device = MTLCreateSystemDefaultDevice();
    if (!device) device = MTLCopyAllDevices().firstObject;
    return [[IFBackgroundProgram alloc] initWithConfig:config device:device];
}

- (instancetype)initWithConfig:(IFBackgroundConfig *)config device:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _config = [config copy];
    _device = device;
    _resources = device ? [IFBGDeviceResources resourcesForDevice:device] : nil;
    if (!_resources) {
        _kind = IFBackgroundKindNone;
        _errorText = @"background: no Metal device";
        return self;
    }
    [self load];
    if (_kind != IFBackgroundKindNone && !_pipeline) {
        _kind = IFBackgroundKindNone;
        _errorText = _resources.builtinError ?: _errorText ?: @"background: pipeline creation failed";
    }
    return self;
}

// The dot grid, as a background of its own or as the fallback. Upstream
// `init_shader_bg` / `init_default_shader_bg` with DEFAULT_SHADER: it declares
// `u_camera` only, and honours `transparent_shader` like any other shader.
- (void)useDotGrid {
    _kind = IFBackgroundKindDotGrid;
    _pipeline = [_resources builtinPipeline:@"ifbg_dot_grid"];
    _texture = nil;
    _textureSize = CGSizeZero;
    _animated = NO;
    _transparent = _config.transparentShader;
}

- (id<MTLRenderPipelineState>)compileUserShader:(NSString *)source textured:(BOOL)textured error:(NSString **)error {
    NSString *translateError = nil;
    NSString *msl = IFBGTranslateGLSL(source, textured, &translateError);
    if (!msl) {
        if (error) *error = translateError;
        return nil;
    }
    NSError *nsError = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:msl options:DWMetalCompileOptions() error:&nsError];
    id<MTLFunction> fragment = [library newFunctionWithName:@"ifbg_user_fragment"];
    if (!fragment) {
        if (error) *error = IFBGCondenseDiagnostics(nsError.localizedDescription ?: @"no fragment function");
        return nil;
    }
    id<MTLRenderPipelineState> pipeline = [_resources pipelineWithFragment:fragment error:&nsError];
    if (!pipeline && error) *error = IFBGCondenseDiagnostics(nsError.localizedDescription ?: @"pipeline creation failed");
    return pipeline;
}

// Mirrors `init_background` and its helpers in upstream background.rs,
// including every fallback and the wording of each error.
- (void)load {
    NSString *path = _config.path.stringByExpandingTildeInPath;
    NSString *texturePath = _config.texture.stringByExpandingTildeInPath;
    switch (_config.type) {
        case IFBackgroundTypeNone:
            _kind = IFBackgroundKindNone;  // init_none_bg
            return;
        case IFBackgroundTypeDefault:
            [self useDotGrid];
            return;
        case IFBackgroundTypeTile:
        case IFBackgroundTypeWallpaper: {
            BOOL wallpaper = _config.type == IFBackgroundTypeWallpaper;
            if (!path) {
                [self useDotGrid];
                _errorText = [NSString stringWithFormat:@"config: [background] type=\"%@\" requires `path`, using default",
                                                        wallpaper ? @"wallpaper" : @"tile"];
                return;
            }
            if (IFBGIsTIFFPath(path) && !(wallpaper && _config.inheritedWallpaper)) {
                if (wallpaper) {
                    [self useDotGrid];
                    _errorText = [NSString stringWithFormat:@"wallpaper '%@': TIFF isn't supported in wallpaper mode (PNG/JPEG only) — use [background] type = \"tile\" for TIFF images", path];
                    return;
                }
                // tile_chunks_or_shader_fallback: a tiled pyramidal TIFF is drawn
                // from its levels chunk by chunk, or not at all.
                NSString *pyramidError = [self loadPyramid:path];
                if (pyramidError) {
                    [self useDotGrid];
                    _errorText = [NSString stringWithFormat:@"tile bg '%@': %@", path, pyramidError];
                }
                return;
            }
            NSString *imageError = nil;
            BOOL hasTransparency = NO;
            CGSize size = CGSizeZero;
            BOOL inherited = wallpaper && _config.inheritedWallpaper;
            id<MTLTexture> texture = IFBGLoadImage(_device, path, &size, inherited, inherited ? NULL : &hasTransparency, &imageError);
            NSString *fragment = wallpaper ? @"ifbg_wallpaper" : (_config.mirrorTile ? @"ifbg_tile_mirror" : @"ifbg_tile");
            id<MTLRenderPipelineState> pipeline = texture ? [_resources builtinPipeline:fragment] : nil;
            if (!texture || !pipeline) {
                [self useDotGrid];
                _errorText = imageError ?: [NSString stringWithFormat:@"background: %@ shader failed to compile", wallpaper ? @"wallpaper" : @"tile"];
                return;
            }
            _kind = wallpaper ? IFBackgroundKindWallpaper : IFBackgroundKindTile;
            _pipeline = pipeline;
            _texture = texture;
            _textureSize = size;
            _animated = NO;
            _transparent = hasTransparency && !inherited;
            if (inherited) {
                _wallpaperFill = simd_make_float4(0, 0, 0, 1);
                NSArray<NSNumber *> *fill = _config.wallpaperFillColor;
                if (fill.count >= 3) for (NSUInteger i = 0; i < 3; i++) {
                    double component = [fill[i] doubleValue];
                    _wallpaperFill[i] = isfinite(component) ? (float)fmin(fmax(component, 0.0), 1.0) : 0.0f;
                }
            }
            return;
        }
        case IFBackgroundTypeShader:
            break;
    }

    if (!path) {
        [self useDotGrid];
        _errorText = @"config: [background] type=\"shader\" requires `path`, using default";
        return;
    }
    NSString *readError = nil;
    NSString *source = IFBGReadText(path, &readError);

    if (texturePath) {
        // textured_shader_or_fallback: read, compile, then load the image; any
        // failure draws the dot grid.
        if (!source) {
            [self useDotGrid];
            _errorText = [NSString stringWithFormat:@"background shader '%@': %@", path, readError];
            return;
        }
        NSString *compileError = nil;
        id<MTLRenderPipelineState> pipeline = [self compileUserShader:source textured:YES error:&compileError];
        if (!pipeline) {
            [self useDotGrid];
            _errorText = [NSString stringWithFormat:@"background shader '%@': compile error: %@", path, compileError];
            return;
        }
        NSString *imageError = nil;
        CGSize size = CGSizeZero;
        id<MTLTexture> texture = IFBGLoadImage(_device, texturePath, &size, NO, NULL, &imageError);
        if (!texture) {
            [self useDotGrid];
            _errorText = imageError;
            return;
        }
        _kind = IFBackgroundKindTexturedShader;
        _pipeline = pipeline;
        _texture = texture;
        _textureSize = size;
        _animated = IFBGReferencesUniform(source, @"float", @"u_time");
        _transparent = _config.transparentShader;  // the texture's alpha does not decide
        return;
    }

    // shader_no_texture_dispatch
    if (source && IFBGReferencesUniform(source, @"sampler2D", @"tex")) {
        [self useDotGrid];
        _errorText = [NSString stringWithFormat:
            @"background shader '%@': samples `tex` but no `texture` is set — add a `texture` path under [background]", path];
        return;
    }
    // init_shader_bg, or with `cache_shader` shader_chunks_or_live first.
    if (!source) {
        [self useDotGrid];
        _errorText = [NSString stringWithFormat:@"background shader '%@': %@", path, readError];
        return;
    }
    // try_init_shader_chunks: `cache_shader` bakes a shader that is a rigid
    // function of the canvas, one that reads `u_camera` and neither `u_time`
    // nor `u_zoom`. A shader without `u_camera` is fixed to the screen, and
    // baking it into canvas chunks would make it scroll. Every other shader is
    // drawn live, and so is every shader under `transparent_shader`: a chunk
    // cannot carry transparency.
    BOOL bake = _config.cacheShader && !_config.transparentShader && IFBGReferencesUniform(source, @"vec2", @"u_camera") &&
                !IFBGReferencesUniform(source, @"float", @"u_time") && !IFBGReferencesUniform(source, @"float", @"u_zoom");
    NSString *compileError = nil;
    id<MTLRenderPipelineState> pipeline = [self compileUserShader:source textured:NO error:&compileError];
    if (!pipeline) {
        [self useDotGrid];
        // try_init_shader_chunks names the file, init_shader_bg does not.
        _errorText = bake ? [NSString stringWithFormat:@"background shader '%@': compile error: %@", path, compileError]
                          : [NSString stringWithFormat:@"background shader: compile error: %@", compileError];
        return;
    }
    _kind = IFBackgroundKindShader;
    _pipeline = pipeline;
    _animated = IFBGReferencesUniform(source, @"float", @"u_time");
    _transparent = _config.transparentShader;
    if (!bake) return;
    // The shader itself stays compiled: the bake draws through it, and so does
    // a capture.
    if ([_resources chunkPipeline]) {
        _cache = IFBackgroundCacheShaderBake;
    } else {
        _errorText = [NSString stringWithFormat:@"background shader '%@': chunk_bg compile error: the built-in chunk shader could not be built", path];
    }
}

// init_tile_chunks_bg and BgChunkCache::new_from_tiff: opens the file, derives
// the chunk layout and decodes the whole fallback level. Returns upstream's
// message (what follows its `tile bg '<path>': `), or nil when the program is
// ready. The decode pool is each output's own and starts with its first frame.
- (NSString *)loadPyramid:(NSString *)path {
    NSString *error = nil;
    IFBGTiffSource *source = [IFBGTiffSource sourceWithPath:path error:&error];
    if (!source) return error;
    if (![_resources chunkPipeline]) return @"chunk_bg shader compile: the built-in chunk shader could not be built";
    // The fallback plane reuses tile_bg.glsl, never its mirrored variant:
    // `mirror_tile` is a no-op on a pyramidal TIFF.
    id<MTLRenderPipelineState> plane = [_resources builtinPipeline:@"ifbg_tile"];
    if (!plane) return @"tile_bg shader compile failed";
    IFBGTileLayout *layout = IFBGTileLayoutMake(source, &error);
    if (!layout) return error;
    IFBGTiffBlock *fallback = [source readWholeLevel:layout->lodCount - 1 error:&error];
    if (!fallback) return error;
    id<MTLTexture> texture = IFBGUploadBlock(_device, fallback);
    if (!texture) {
        return [NSString stringWithFormat:@"fallback texture upload: a texture of %u×%u pixels could not be made", fallback.width, fallback.height];
    }
    _kind = IFBackgroundKindTile;
    _cache = IFBackgroundCacheTileChunks;
    _pipeline = plane;
    _texture = texture;
    _textureSize = CGSizeMake(layout->imageW, layout->imageH);  // `u_tile_size`: the wrap period, not the fallback level's size
    _tiff = source;
    _layout = layout;
    _fallbackHoles = fallback.failedTileCount;
    _fallbackTransparency = fallback.hasTransparency;
    _animated = NO;
    // Opaque whatever the file's alpha: chunk_bg.glsl writes alpha 1, and the
    // fallback plane claims its whole area opaque.
    _transparent = NO;
    return nil;
}

// Integer output size, as upstream's logical output size is integral.
static void IFBGPixelSize(IFBackgroundFrame f, long *logicalW, long *logicalH, NSUInteger *pxW, NSUInteger *pxH) {
    DWMetalPixelSize(f.width, f.height, f.scale, logicalW, logicalH, pxW, pxH);
}

/// The uniform mapping, including the macOS wallpaper extension below.
- (IFBGUniforms)uniformsForFrame:(IFBackgroundFrame)f {
    IFBGUniforms u;
    memset(&u, 0, sizeof u);
    double zoom = (isfinite(f.zoom) && f.zoom > 0) ? f.zoom : 1.0;
    double scale = (isfinite(f.scale) && f.scale > 0) ? f.scale : 1.0;
    long outW, outH;
    IFBGPixelSize(f, &outW, &outH, NULL, NULL);
    outW = MAX(outW, 1L);
    outH = MAX(outH, 1L);

    // background.rs update(): `Uniform::new("u_camera", (f.camera.x as f32, f.camera.y as f32))`
    u.camera = simd_make_float2((float)f.cameraX, (float)f.cameraY);
    u.time = (float)f.time;  // `state.start_time.elapsed().as_secs_f32()`
    u.zoom = (float)zoom;    // `Uniform::new("u_zoom", f.zoom as f32)`
    u.alpha = 1.0f;          // element alpha, always 1.0 for a background
    u.opaque = _transparent ? 0.0f : 1.0f;
    u.texture_size = simd_make_float2((float)_textureSize.width, (float)_textureSize.height);

    if (_kind == IFBackgroundKindWallpaper) {
        // Upstream wallpaper_cover_src(), or NSWorkspace's centred fit/fill,
        // stretch or unscaled still image. Fill is opaque outside image UVs.
        double tw = MAX(_textureSize.width, 1.0), th = MAX(_textureSize.height, 1.0);
        double factorX = (double)outW / tw, factorY = (double)outH / th;
        double imageScale = MAX(factorX, factorY);
        BOOL stretch = NO;
        if (_config.inheritedWallpaper) {
            switch (_config.wallpaperScaling) {
                case NSImageScaleAxesIndependently:
                    stretch = YES;
                    break;
                case NSImageScaleNone:
                    imageScale = 1.0;
                    break;
                case NSImageScaleProportionallyDown:
                    imageScale = MIN(_config.wallpaperClipping ? MAX(factorX, factorY) : MIN(factorX, factorY), 1.0);
                    break;
                case NSImageScaleProportionallyUpOrDown:
                default:
                    imageScale = _config.wallpaperClipping ? MAX(factorX, factorY) : MIN(factorX, factorY);
                    break;
            }
        }
        double baseX = stretch ? 1.0 : factorX / imageScale;
        double baseY = stretch ? 1.0 : factorY / imageScale;
        double cropX = baseX, cropY = baseY, panX = 0.0, panY = 0.0;
        if (_config.parallax) {
            // A shallow, bounded depth: 4..12% overscan changes smoothly with
            // zoom. Camera movement uses only its overscan margin, so a cover
            // image cannot run out, repeat, or expose clamped border pixels.
            // Use the world centre to keep a centred zoom from panning as well.
            double overscan = 1.04 + 0.08 * (2.0 / M_PI) * atan(zoom);
            cropX /= overscan;
            cropY /= overscan;
            double cameraX = isfinite(f.cameraX) ? f.cameraX : 0.0;
            double cameraY = isfinite(f.cameraY) ? f.cameraY : 0.0;
            double centreX = cameraX / (double)outW + 0.5 * (1.0 / zoom - 1.0);
            double centreY = cameraY / (double)outH + 0.5 * (1.0 / zoom - 1.0);
            panX = tanh(2.0 * centreX) * (baseX - cropX) * 0.5;
            panY = tanh(2.0 * centreY) * (baseY - cropY) * 0.5;
        }
        u.src_origin = simd_make_float2((float)((1.0 - cropX) * 0.5 + panX), (float)((1.0 - cropY) * 0.5 + panY));
        u.src_size = simd_make_float2((float)cropX, (float)cropY);
        u.wallpaper_fill = _wallpaperFill;
        u.dest_px = simd_make_float2((float)MAX(1.0, round((double)outW * scale)), (float)MAX(1.0, round((double)outH * scale)));
        u.size = simd_make_float2((float)outW, (float)outH);
        return u;
    }

    // background.rs update_background_element():
    //   canvas_w = (output_size.w as f64 / cur_zoom).ceil() as i32
    double canvasW = ceil((double)outW / zoom), canvasH = ceil((double)outH / zoom);
    canvasW = MIN(MAX(canvasW, 1.0), 2147483647.0);
    canvasH = MIN(MAX(canvasH, 1.0), 2147483647.0);
    // `size` (PixelShaderElement area) and `u_output_size` both carry the canvas area.
    u.size = simd_make_float2((float)canvasW, (float)canvasH);
    // The element's physical extent: geometry(scale) rounds canvas * scale,
    // RescaleRenderElement then rounds that * zoom. v_coords runs 0..1 over it.
    u.dest_px = simd_make_float2((float)MAX(1.0, round(round(canvasW * scale) * zoom)),
                                 (float)MAX(1.0, round(round(canvasH * scale) * zoom)));
    u.src_origin = simd_make_float2(0, 0);
    u.src_size = simd_make_float2(1, 1);
    return u;
}

// Draws the frame into a render pass the caller already opened, so that the
// compositor can put the background first in its own pass.
- (BOOL)encodeFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder {
    if (_kind == IFBackgroundKindNone || !_pipeline) return NO;
    if (_cache != IFBackgroundCacheNone && [self encodeChunksOfFrame:frame inEncoder:encoder]) return YES;
    IFBGUniforms u = [self uniformsForFrame:frame];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
    [encoder setFragmentTexture:_texture ?: _resources.placeholderTexture atIndex:0];
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    return YES;
}

// MARK: Chunk caches

// The fallback plane of a pyramidal TIFF, tile_chunks.rs
// `chunk_render_elements`: tile_bg.glsl over the visible rectangle, sampling
// the fallback level with the full-resolution image as the wrap period. Unlike
// the chunks above it, it follows the unrounded camera.
- (IFBGUniforms)planeUniformsForFrame:(IFBackgroundFrame)f {
    IFBGChunkView v = IFBGChunkViewMake(f);
    IFBGUniforms u;
    memset(&u, 0, sizeof u);
    u.camera = simd_make_float2((float)f.cameraX, (float)f.cameraY);  // `Uniform::new("u_camera", (camera.x as f32, camera.y as f32))`
    u.texture_size = simd_make_float2((float)_textureSize.width, (float)_textureSize.height);  // `u_tile_size`: image_dims
    u.size = simd_make_float2((float)MAX(v.viewW, 1L), (float)MAX(v.viewH, 1L));  // `u_output_size`: (canvas_w, canvas_h)
    // The element's area is the visible rectangle at the output's origin.
    simd_float4 dst = IFBGChunkDst(0, 0, MAX(v.viewW, 1L), MAX(v.viewH, 1L), &v);
    u.dest_px = simd_make_float2(fmaxf(dst.z, 1.0f), fmaxf(dst.w, 1.0f));
    u.src_size = simd_make_float2(1, 1);
    u.time = (float)f.time;
    u.zoom = (float)v.zoom;
    u.alpha = 1.0f;
    u.opaque = 1.0f;
    return u;
}

// The chunk work of one frame and the quads it draws, bottom first: what both
// the draw below and -chunkGenerationForFrame: ask, and each cache answers once
// per frame. nil when the live path draws instead.
- (nullable NSArray<IFBGChunkDraw *> *)chunkDrawsForFrame:(IFBackgroundFrame)frame {
    NSUInteger pxW, pxH;
    IFBGPixelSize(frame, NULL, NULL, &pxW, &pxH);
    if (pxW == 0 || pxH == 0 || ![_resources chunkPipeline]) return nil;
    // `state.config.background.cache_budget_mb as u64 * 1024 * 1024`
    uint64_t budget = (uint64_t)_config.cacheBudgetMB * 1024 * 1024;
    if (_cache == IFBackgroundCacheShaderBake) {
        // The chunks are baked for one output scale: at another the cache
        // starts again (upstream drops an output's cache when its scale changes).
        double scale = (isfinite(frame.scale) && frame.scale > 0) ? frame.scale : 1.0;
        if (!_shaderChunks || _shaderChunks.scale != scale) {
            _shaderChunks = [[IFBGShaderChunks alloc] initWithResources:_resources shader:_pipeline scale:scale budget:budget];
        }
        return [_shaderChunks drawsForFrame:frame];
    }
    if (!_tiff || !_layout) return nil;
    if (!_tileChunks) {
        _tileChunks = [[IFBGTileChunks alloc] initWithDevice:_device source:_tiff layout:_layout budget:budget];
        _tileChunks.readyHandler = _chunkReadyHandler;
    }
    return [_tileChunks drawsForFrame:frame] ?: @[];
}

- (uint64_t)chunkGenerationForFrame:(IFBackgroundFrame)frame {
    if (_cache == IFBackgroundCacheNone || _kind == IFBackgroundKindNone || !_pipeline) return 0;
    [self chunkDrawsForFrame:frame];
    return _shaderChunks.generation + _tileChunks.generation;
}

// One frame of a cached program: its chunk cache decides what is drawn, after
// baking or uploading what this frame may. NO when nothing was drawn and the
// live path below should draw instead (no cache could be made, or a baked
// shader's coarse cover could not be baked).
- (BOOL)encodeChunksOfFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder {
    id<MTLRenderPipelineState> quad = [_resources chunkPipeline];
    NSArray<IFBGChunkDraw *> *draws = [self chunkDrawsForFrame:frame];
    if (!draws) return NO;
    if (_cache == IFBackgroundCacheTileChunks) {
        // Bottom: the fallback plane, one draw whatever the number of image
        // instances in view. No region of the output is ever blank.
        IFBGUniforms u = [self planeUniformsForFrame:frame];
        [encoder setRenderPipelineState:_pipeline];
        [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
        [encoder setFragmentTexture:_texture atIndex:0];
        [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    if (!draws.count) return YES;
    [encoder setRenderPipelineState:quad];
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
    for (IFBGChunkDraw *draw in draws) {
        [encoder setVertexBytes:&draw->uniforms length:sizeof draw->uniforms atIndex:0];
        [encoder setFragmentBytes:&draw->uniforms length:sizeof draw->uniforms atIndex:0];
        [encoder setFragmentTexture:draw->texture atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    return YES;
}

// Everything `base` loaded, and no chunk cache yet.
- (instancetype)initSharing:(IFBackgroundProgram *)base {
    if (!(self = [super init])) return nil;
    _config = base->_config;
    _device = base->_device;
    _resources = base->_resources;
    _kind = base->_kind;
    _errorText = base->_errorText;
    _animated = base->_animated;
    _transparent = base->_transparent;
    _textureSize = base->_textureSize;
    _pipeline = base->_pipeline;
    _texture = base->_texture;
    _wallpaperFill = base->_wallpaperFill;
    _cache = base->_cache;
    _tiff = base->_tiff;
    _layout = base->_layout;
    _fallbackHoles = base->_fallbackHoles;
    _fallbackTransparency = base->_fallbackTransparency;
    return self;
}

- (IFBackgroundProgram *)programForOutput {
    if (_cache == IFBackgroundCacheNone) return self;
    return [[IFBackgroundProgram alloc] initSharing:self];
}

// capture_background.rs `CaptureBackground::prepare`: a capture is a virtual
// viewport, so it never draws from an output's chunk cache. `shader_bg` hands
// it the compiled shader itself, `tiff_tile_bg` one level of the pyramid as a
// plain tile.
- (IFBackgroundProgram *)captureProgram {
    if (_cache == IFBackgroundCacheNone) return self;
    @synchronized(self) {
        if (_captureTwin) return _captureTwin;
        IFBackgroundProgram *twin = [[IFBackgroundProgram alloc] initSharing:self];
        twin->_cache = IFBackgroundCacheNone;
        if (_cache == IFBackgroundCacheTileChunks) {
            // The finest level that fits one bounded texture, else the coarsest,
            // among every page of the file; stretched over the full-resolution
            // extent by `_textureSize`, so it lands where the chunks would.
            // capture_background.rs prepare_tiff: `whole_lod(&lods, TIFF_LOD_CAP)`, and a level
            // past the whole-decode limit leaves the capture without a background.
            NSUInteger count = _tiff.levelCount;
            IFBGTiffLevel levels[kIFBGMaxTileLODs];
            for (NSUInteger i = 0; i < count && i < kIFBGMaxTileLODs; i++) levels[i] = [_tiff levelAtIndex:i];
            NSString *whole = nil;
            NSUInteger lod = IFBGTiffWholeLevel(levels, MIN(count, (NSUInteger)kIFBGMaxTileLODs), kIFBGFallbackMaxDim, &whole);
            if (lod == NSNotFound) {
                NSLog(@"background: capture background '%@': %@", _config.path, whole);
                twin->_kind = IFBackgroundKindNone;
                twin->_pipeline = nil;
                twin->_texture = nil;
            } else if (lod == (NSUInteger)_layout->lodCount - 1 && _fallbackHoles == 0) {
                // The fallback plane's level, whole: the texture already loaded.
                twin->_transparent = _fallbackTransparency;
            } else {
                // `source.read_block(lod_idx, 0, 0, n).ok()?`: any tile that
                // cannot be decoded leaves the capture without a background.
                IFBGTiffLevel level = [_tiff levelAtIndex:lod];
                uint32_t across = (level.imageWidth + level.tileWidth - 1) / level.tileWidth;
                uint32_t down = (level.imageHeight + level.tileHeight - 1) / level.tileHeight;
                IFBGTiffBlock *block = [_tiff readBlockAtLevel:lod gx:0 gy:0 aggregation:MAX(across, down) error:NULL];
                id<MTLTexture> texture = block ? IFBGUploadBlock(_device, block) : nil;
                if (texture) {
                    twin->_texture = texture;
                    twin->_transparent = block.hasTransparency;
                } else {
                    twin->_kind = IFBackgroundKindNone;
                    twin->_pipeline = nil;
                    twin->_texture = nil;
                }
            }
        }
        _captureTwin = twin;
        return twin;
    }
}

- (void)setChunkReadyHandler:(dispatch_block_t)handler {
    _chunkReadyHandler = [handler copy];
    _tileChunks.readyHandler = _chunkReadyHandler;
}

- (NSUInteger)pendingChunkCount {
    return _shaderChunks.pendingCount + _tileChunks.pendingCount;
}

- (void)shrinkChunkCache {
    [_shaderChunks shrink];
    [_tileChunks shrink];
}

- (id<MTLCommandQueue>)commandQueue {
    return _resources.queue;
}
@end
