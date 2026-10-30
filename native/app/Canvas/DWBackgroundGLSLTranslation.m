// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: the translation of a user's GLSL ES 1.00
// background shader into Metal Shading Language - see IFBackground.h and
// docs/native/app/Canvas/BACKGROUND-NOTES.md.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: the shader contract of
// src/render/background.rs (`references_uniform`) and src/render/shaders.rs
// (BG_UNIFORMS / BG_TEX_UNIFORMS), as the comments below cite.
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackground+Private.h"
#import "IFBGShaderDecl.h"

#include <stdlib.h>
#include <string.h>

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


// Upstream `references_uniform` (background.rs): a plain substring test on the
// raw source. Kept literally, comments and prefixes included, because it is
// what decides upstream's animated / camera / zoom / `tex` behaviour.
BOOL IFBGReferencesUniform(NSString *src, NSString *type, NSString *name) {
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
NSString *IFBGTranslateGLSL(NSString *source, BOOL textured, NSString **error) {
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
NSString *IFBGCondenseDiagnostics(NSString *text) {
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
