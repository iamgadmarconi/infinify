// SPDX-License-Identifier: GPL-3.0-or-later
// Carried into native/desktop/ unchanged from the standalone compositor port that was built, verified against upstream's shaders and independently reviewed outside this repository; only this line was added.
//
// Infinify canvas background renderer — see background.h and NOTES.md.
//
// Derived from DriftWM (GPL-3.0-or-later), upstream commit
// 352333a8fa1b22171492d4b71a54102045c9a19d. The three built-in fragment
// shaders below are hand translations of upstream GLSL; each carries the
// upstream path and SHA-256 of the file it was translated from.

#import "background.h"

#import <Accelerate/Accelerate.h>
#import <ImageIO/ImageIO.h>
#import <simd/simd.h>

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *const IFBGErrorDomain = @"IFBackgroundErrorDomain";

// Largest 2D texture on every Apple-silicon GPU.
static const NSUInteger kIFBGMaxTextureSide = 16384;

// MARK: - Uniform block

// Must match `struct IFBGUniforms` in kIFBGCommonMSL (64 bytes, 8-byte aligned).
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
} IFBGUniforms;

_Static_assert(sizeof(IFBGUniforms) == 64, "IFBGUniforms layout must match the MSL struct");

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
     "};\n"
     "struct IFBGVertexOut { float4 position [[position]]; };\n"
     // smithay's `v_coords`: the element's 0..1 extent mapped through its
     // texture matrix. Metal's [[position]] is the pixel centre, origin top-left.
     "static inline float2 ifbg_v_coords(float4 position, constant IFBGUniforms &U) {\n"
     "    return U.src_origin + (position.xy / U.dest_px) * U.src_size;\n"
     "}\n"
     // A background that is not transparent is composited opaque: docs/shaders.md,
     // "The alpha component ... is ignored by default". On upstream's texture path
     // (tile, wallpaper, textured shader) smithay draws the element's opaque region
     // with blending off, so this is exactly what reaches the screen. On the plain
     // pixel-shader path smithay 0.7.0 leaves blending on, so a shader writing
     // alpha < 1 without `transparent_shader` blends over stale framebuffer
     // contents there; forcing alpha to 1 is a deliberate deviation (NOTES.md,
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
     // ------------------------------------------------------------------
     "fragment float4 ifbg_wallpaper(IFBGVertexOut in [[stage_in]],\n"
     "                               constant IFBGUniforms &U [[buffer(0)]],\n"
     "                               texture2d<float> tex [[texture(0)]],\n"
     "                               sampler smp [[sampler(0)]]) {\n"
     "    float2 v_coords = ifbg_v_coords(in.position, U);\n"
     "    float alpha = U.alpha;\n"
     "\n"
     "    float4 color = tex.sample(smp, v_coords);\n"
     "    return ifbg_finish(color * alpha, U);\n"
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
+ (MTLCompileOptions *)compileOptions;
- (nullable id<MTLRenderPipelineState>)builtinPipeline:(NSString *)fragmentName;
- (nullable id<MTLRenderPipelineState>)pipelineWithFragment:(id<MTLFunction>)fragment error:(NSError **)error;
@end

@implementation IFBGDeviceResources {
    id<MTLLibrary> _builtinLibrary;
    NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_builtinPipelines;
}

+ (instancetype)resourcesForDevice:(id<MTLDevice>)device {
    static NSMutableDictionary<NSNumber *, IFBGDeviceResources *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized(cache) {
        NSNumber *key = @(device.registryID);
        IFBGDeviceResources *r = cache[key];
        if (!r) {
            r = [[IFBGDeviceResources alloc] initWithDevice:device];
            cache[key] = r;
        }
        return r;
    }
}

// IEEE-754 arithmetic (no reassociation, NaN and infinity honoured) so GLSL
// written for `precision highp float` computes what it says; library functions
// (sin, pow, ...) stay at the GPU's native precision, as on every GL driver.
// Measured on an Apple M5 Pro at 3456x2234: fast_smoke costs 8.6 ms of GPU time
// per frame this way against 20.6 ms with MTLMathFloatingPointFunctionsPrecise,
// and the precise variant draws a *different* noise pattern from the system
// GLSL compiler far from the canvas origin (see NOTES.md, "Math mode").
+ (MTLCompileOptions *)compileOptions {
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.mathMode = MTLMathModeSafe;
    options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
    return options;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _device = device;
    _queue = [device newCommandQueue];
    _builtinPipelines = [NSMutableDictionary dictionary];

    NSError *error = nil;
    _builtinLibrary = [device newLibraryWithSource:[kIFBGCommonMSL stringByAppendingString:kIFBGBuiltinMSL]
                                           options:[IFBGDeviceResources compileOptions]
                                             error:&error];
    if (!_builtinLibrary) {
        // Upstream: "Default shader must compile".
        _builtinError = [NSString stringWithFormat:@"background: built-in shaders failed to compile: %@",
                                                   error.localizedDescription];
        NSLog(@"%@", _builtinError);
    }
    _vertexFunction = [_builtinLibrary newFunctionWithName:@"ifbg_vertex"];

    // smithay: GL_LINEAR minification and magnification, CLAMP_TO_EDGE, no mipmaps.
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.mipFilter = MTLSamplerMipFilterNotMipmapped;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [device newSamplerStateWithDescriptor:sd];

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
@end

// MARK: - Files

// Rust-style description of an errno, as upstream prints it.
static NSString *IFBGOSError(int code) {
    return [NSString stringWithFormat:@"%s (os error %d)", strerror(code), code];
}

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
/// missing rows empty (measured, NOTES.md section 6). Upstream's decoder (the
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
/// `image` crate never reads it); the values are taken to be sRGB.
static id<MTLTexture> IFBGLoadImage(id<MTLDevice> device, NSString *path, CGSize *size,
                                    BOOL *hasTransparency, NSString **error) {
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
    if (!source || !([uti isEqualToString:@"public.png"] || [uti isEqualToString:@"public.jpeg"])) {
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
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
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
    BOOL grey = (model == kCGColorSpaceModelMonochrome);
    CGColorSpaceRef fallback = NULL;
    if (model != kCGColorSpaceModelRGB && !grey) {
        // CMYK and other exotic models: let CoreGraphics convert to sRGB.
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
        if (error) *error = fail([NSString stringWithFormat:@"the image could not be decoded (vImage error %ld)", (long)verr]);
        return nil;
    }
    if (status != kCGImageStatusComplete) {
        free(buffer.data);
        if (error) *error = fail([NSString stringWithFormat:@"%@ (the %@ is truncated or damaged, ImageIO status %d)",
                                     status == kCGImageStatusUnexpectedEOF ? @"unexpected end of file" : @"the image could not be decoded completely",
                                     png ? @"PNG" : @"JPEG", (int)status]);
        return nil;
    }

    uint8_t *rgba = malloc(w * h * 4);
    BOOL transparent = NO;
    for (size_t y = 0; y < h; y++) {
        const uint8_t *row = (const uint8_t *)buffer.data + y * buffer.rowBytes;
        uint8_t *dst = rgba + y * w * 4;
        if (grey) {
            for (size_t x = 0; x < w; x++) {
                dst[4 * x] = dst[4 * x + 1] = dst[4 * x + 2] = row[2 * x];
                dst[4 * x + 3] = row[2 * x + 1];
            }
        } else {
            memcpy(dst, row, w * 4);
        }
        for (size_t x = 0; x < w && !transparent; x++) transparent = dst[4 * x + 3] < 255;
    }
    free(buffer.data);

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:td];
    if (texture) [texture replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba bytesPerRow:w * 4];
    free(rgba);
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

// MARK: - Program

@interface IFBackgroundProgram ()
- (id<MTLCommandQueue>)commandQueue;
@end

@implementation IFBackgroundProgram {
    IFBGDeviceResources *_resources;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _texture;
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
    _translatedShaderSource = nil;
    _animated = NO;
    _usesCamera = YES;
    _usesZoom = NO;
    _transparent = _config.transparentShader;
}

- (id<MTLRenderPipelineState>)compileUserShader:(NSString *)source textured:(BOOL)textured error:(NSString **)error {
    NSString *translateError = nil;
    NSString *msl = IFBGTranslateGLSL(source, textured, &translateError);
    if (!msl) {
        if (error) *error = translateError;
        return nil;
    }
    _translatedShaderSource = msl;
    NSError *nsError = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:msl options:[IFBGDeviceResources compileOptions] error:&nsError];
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
            if (IFBGIsTIFFPath(path)) {
                [self useDotGrid];
                _errorText = wallpaper
                    ? [NSString stringWithFormat:@"wallpaper '%@': TIFF isn't supported in wallpaper mode (PNG/JPEG only) — use [background] type = \"tile\" for TIFF images", path]
                    // Deviation: upstream streams a tiled pyramidal TIFF in chunks here.
                    : [NSString stringWithFormat:@"tile bg '%@': tiled pyramidal TIFF (gigapixel) backgrounds are not supported by this port", path];
                return;
            }
            NSString *imageError = nil;
            BOOL hasTransparency = NO;
            CGSize size = CGSizeZero;
            id<MTLTexture> texture = IFBGLoadImage(_device, path, &size, &hasTransparency, &imageError);
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
            _usesCamera = !wallpaper;  // tile: uniforms move on every camera change
            _usesZoom = NO;
            _transparent = hasTransparency;  // images: detected from the alpha channel
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
        NSString *translated = _translatedShaderSource;
        NSString *imageError = nil;
        CGSize size = CGSizeZero;
        id<MTLTexture> texture = IFBGLoadImage(_device, texturePath, &size, NULL, &imageError);
        if (!texture) {
            [self useDotGrid];
            _errorText = imageError;
            return;
        }
        _kind = IFBackgroundKindTexturedShader;
        _pipeline = pipeline;
        _texture = texture;
        _textureSize = size;
        _translatedShaderSource = translated;
        _animated = IFBGReferencesUniform(source, @"float", @"u_time");
        _usesCamera = IFBGReferencesUniform(source, @"vec2", @"u_camera");
        _usesZoom = IFBGReferencesUniform(source, @"float", @"u_zoom");
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
    // init_shader_bg. (`cache_shader` would bake an eligible shader into
    // textures first; the live path below draws the same picture.)
    if (!source) {
        [self useDotGrid];
        _errorText = [NSString stringWithFormat:@"background shader '%@': %@", path, readError];
        return;
    }
    NSString *compileError = nil;
    id<MTLRenderPipelineState> pipeline = [self compileUserShader:source textured:NO error:&compileError];
    if (!pipeline) {
        [self useDotGrid];
        _errorText = [NSString stringWithFormat:@"background shader: compile error: %@", compileError];
        return;
    }
    NSString *translated = _translatedShaderSource;
    _kind = IFBackgroundKindShader;
    _pipeline = pipeline;
    _translatedShaderSource = translated;
    _animated = IFBGReferencesUniform(source, @"float", @"u_time");
    _usesCamera = IFBGReferencesUniform(source, @"vec2", @"u_camera");
    _usesZoom = IFBGReferencesUniform(source, @"float", @"u_zoom");
    _transparent = _config.transparentShader;
}

// Integer output size, as upstream's logical output size is integral.
static void IFBGPixelSize(IFBackgroundFrame f, long *logicalW, long *logicalH, NSUInteger *pxW, NSUInteger *pxH) {
    double scale = (isfinite(f.scale) && f.scale > 0) ? f.scale : 1.0;
    long lw = isfinite(f.width) ? lround(f.width) : 0, lh = isfinite(f.height) ? lround(f.height) : 0;
    lw = MAX(lw, 0L);
    lh = MAX(lh, 0L);
    if (logicalW) *logicalW = lw;
    if (logicalH) *logicalH = lh;
    if (pxW) *pxW = (NSUInteger)MAX(0L, lround((double)lw * scale));
    if (pxH) *pxH = (NSUInteger)MAX(0L, lround((double)lh * scale));
}

/// The uniform mapping. Every line cites the upstream expression it mirrors.
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
        // Viewport-fixed: the element covers the output and is not rescaled.
        // background.rs wallpaper_cover_src():
        double tw = MAX(_textureSize.width, 1.0), th = MAX(_textureSize.height, 1.0);
        double outputAspect = (double)outW / (double)outH;
        double subW, subH;
        if (tw / th > outputAspect) {
            subW = th * outputAspect;  // image relatively wider: crop the sides
            subH = th;
        } else {
            subW = tw;                 // image relatively taller: crop top/bottom
            subH = tw / outputAspect;
        }
        u.src_origin = simd_make_float2((float)((tw - subW) / 2.0 / tw), (float)((th - subH) / 2.0 / th));
        u.src_size = simd_make_float2((float)(subW / tw), (float)(subH / th));
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

- (void)encodeFrame:(IFBackgroundFrame)frame
        intoTexture:(id<MTLTexture>)target
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [self encodeFrame:frame inEncoder:encoder];
    [encoder endEncoding];
}

// Compositor hook (the only change against the reviewed background-port copy):
// the draw of -encodeFrame:intoTexture:commandBuffer:, without the render pass
// around it, so the compositor can put the background first in its own pass.
- (BOOL)encodeFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder {
    if (_kind == IFBackgroundKindNone || !_pipeline) return NO;
    IFBGUniforms u = [self uniformsForFrame:frame];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
    [encoder setFragmentTexture:_texture ?: _resources.placeholderTexture atIndex:0];
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    return YES;
}

- (id<MTLCommandQueue>)commandQueue {
    return _resources.queue;
}

static void IFBGReleaseBytes(void *info, const void *data, size_t size) {
    (void)info;
    (void)size;
    free((void *)data);
}

// BGRA8 texture -> sRGB CGImage. Transparent backgrounds keep their
// (premultiplied) alpha; opaque ones are written without an alpha channel.
static CGImageRef IFBGCreateImage(id<MTLTexture> texture, BOOL transparent) CF_RETURNS_RETAINED {
    NSUInteger w = texture.width, h = texture.height;
    uint8_t *bytes = malloc(w * h * 4);
    [texture getBytes:bytes bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bytes, w * h * 4, IFBGReleaseBytes);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = (CGBitmapInfo)kCGBitmapByteOrder32Little |
                        (CGBitmapInfo)(transparent ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, srgb, info, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(srgb);
    CGDataProviderRelease(provider);
    return image;
}

- (CGImageRef)newImageForFrame:(IFBackgroundFrame)frame error:(NSError **)error {
    NSUInteger w, h;
    IFBGPixelSize(frame, NULL, NULL, &w, &h);
    if (!_resources || w == 0 || h == 0 || w > kIFBGMaxTextureSide || h > kIFBGMaxTextureSide) {
        if (error) *error = [NSError errorWithDomain:IFBGErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:
            _resources ? [NSString stringWithFormat:@"invalid render size %lux%lu pixels", (unsigned long)w, (unsigned long)h]
                       : @"no Metal device"}];
        return NULL;
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> commandBuffer = [_resources.queue commandBuffer];
    if (!target || !commandBuffer) {
        if (error) *error = [NSError errorWithDomain:IFBGErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: @"could not allocate the render target"}];
        return NULL;
    }
    [self encodeFrame:frame intoTexture:target commandBuffer:commandBuffer];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = commandBuffer.error ?: [NSError errorWithDomain:IFBGErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey: @"the render did not complete"}];
        return NULL;
    }
    // `none` has nothing to be opaque about: its image is fully transparent.
    return IFBGCreateImage(target, _transparent || _kind == IFBackgroundKindNone);
}

- (BOOL)writePNGForFrame:(IFBackgroundFrame)frame toURL:(NSURL *)url error:(NSError **)error {
    CGImageRef image = [self newImageForFrame:frame error:error];
    if (!image) return NO;
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    BOOL ok = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    if (!ok && error) {
        *error = [NSError errorWithDomain:IFBGErrorDomain code:5 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"could not write %@", url.path]}];
    }
    return ok;
}
@end

// MARK: - Layer

@implementation IFBackgroundLayer {
    BOOL _dirty;
    BOOL _hasLast;
    IFBackgroundFrame _last;       // the frame last drawn
    BOOL _hasAnimateStamp;
    double _lastAnimate;           // upstream `background_last_animate`, in frame time
    id<MTLTexture> _debugCopy;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    // The shader's values are sRGB-encoded (see NOTES.md, "Colour").
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    self.colorspace = srgb;
    CGColorSpaceRelease(srgb);
    self.opaque = YES;
    // Presents inside the host's CATransaction so the background and the
    // window tiles it sits behind move in the same display frame.
    self.presentsWithTransaction = YES;
    self.allowsNextDrawableTimeout = YES;
    self.needsDisplayOnBoundsChange = NO;
    // Never animate geometry or contents implicitly.
    self.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"contents": NSNull.null,
                     @"contentsScale": NSNull.null, @"hidden": NSNull.null, @"opacity": NSNull.null};
    _dirty = YES;
    return self;
}

- (void)setProgram:(IFBackgroundProgram *)program {
    if (_program == program) return;
    _program = program;
    if (program.device) self.device = program.device;
    // `none` clears to transparent so nothing of an earlier background remains.
    self.opaque = program && !program.isTransparent && program.kind != IFBackgroundKindNone;
    _dirty = YES;
    _hasAnimateStamp = NO;
}

- (void)setConfig:(IFBackgroundConfig *)config {
    self.program = [IFBackgroundProgram programWithConfig:config device:nil];
}

- (BOOL)isAnimated {
    return _program.isAnimated;
}

- (NSString *)errorText {
    return _program.errorText;
}

- (void)setNeedsRedraw {
    _dirty = YES;
}

- (void)setDebugCaptureEnabled:(BOOL)enabled {
    _debugCaptureEnabled = enabled;
    self.framebufferOnly = !enabled;
    if (!enabled) _debugCopy = nil;
}

- (BOOL)updateWithFrame:(IFBackgroundFrame)frame {
    IFBackgroundProgram *program = _program;
    if (!program) return NO;
    long logicalW, logicalH;
    NSUInteger pxW, pxH;
    IFBGPixelSize(frame, &logicalW, &logicalH, &pxW, &pxH);
    if (pxW == 0 || pxH == 0 || pxW > kIFBGMaxTextureSide || pxH > kIFBGMaxTextureSide) return NO;

    IFBackgroundKind kind = program.kind;
    BOOL canvasSpace = kind != IFBackgroundKindNone && kind != IFBackgroundKindWallpaper;
    BOOL need = _dirty || !_hasLast;
    if (!need) {
        long lastW, lastH;
        IFBGPixelSize(_last, &lastW, &lastH, NULL, NULL);
        // Output resized or moved to a display with another backing scale.
        need = lastW != logicalW || lastH != logicalH || _last.scale != frame.scale;
    }
    if (!need && kind != IFBackgroundKindNone) {
        // Upstream: a zoom change resizes and rescales every canvas-space
        // element; the camera only matters to a background that reads it.
        BOOL zoomChanged = canvasSpace && _last.zoom != frame.zoom;
        BOOL cameraMoved = canvasSpace && program.usesCamera &&
                           (_last.cameraX != frame.cameraX || _last.cameraY != frame.cameraY);
        need = zoomChanged || cameraMoved;
    }
    // state/redraw.rs background_animation_due(): every frame, or at most
    // `animate_fps` times a second.
    BOOL animateDue = NO;
    if (program.isAnimated && (!_hasLast || _last.time != frame.time)) {
        NSUInteger fps = program.config.animateFPS;
        animateDue = fps == 0 || !_hasAnimateStamp || frame.time < _lastAnimate ||
                     frame.time - _lastAnimate >= 1.0 / (double)fps;
    }
    if (!need && !animateDue) return NO;

    if (self.contentsScale != frame.scale && frame.scale > 0) self.contentsScale = frame.scale;
    CGSize drawableSize = CGSizeMake(pxW, pxH);
    if (!CGSizeEqualToSize(self.drawableSize, drawableSize)) self.drawableSize = drawableSize;

    id<CAMetalDrawable> drawable = [self nextDrawable];
    id<MTLCommandBuffer> commandBuffer = [[program commandQueue] commandBuffer];
    if (!drawable || !commandBuffer) return NO;  // still dirty: the next update retries
    [program encodeFrame:frame intoTexture:drawable.texture commandBuffer:commandBuffer];

    id<MTLTexture> copy = nil;
    if (_debugCaptureEnabled) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:pxW
                                                                                     height:pxH
                                                                                  mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        copy = [program.device newTextureWithDescriptor:td];
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(pxW, pxH, 1) toTexture:copy destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
    }

    if (self.presentsWithTransaction) {
        [commandBuffer commit];
        [commandBuffer waitUntilScheduled];
        [drawable present];
    } else {
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
    if (copy) {
        [commandBuffer waitUntilCompleted];
        _debugCopy = copy;
    }

    if (animateDue) {
        _lastAnimate = frame.time;
        _hasAnimateStamp = YES;
    }
    _last = frame;
    _hasLast = YES;
    _dirty = NO;
    _drawCount++;
    return YES;
}

- (CGImageRef)newDebugImageOfLastFrame {
    if (!_debugCopy) return NULL;
    return IFBGCreateImage(_debugCopy, _program.isTransparent || _program.kind == IFBackgroundKindNone);
}
@end
