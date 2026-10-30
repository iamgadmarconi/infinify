// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: the built-in Metal sources and the
// per-device shared state (IFBGDeviceResources) - see IFBackgroundProgram.h and
// BACKGROUND-NOTES.md.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. The three built-in fragment
// shaders below are hand translations of upstream GLSL; each carries the
// upstream path and SHA-256 of the file it was translated from.
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackgroundProgram+Private.h"
#import "DWMetalSupport.h"

static NSString *const IFBGErrorDomain = @"IFBackgroundErrorDomain";

// MARK: - Metal sources

// Shared by the built-in library and every translated user shader.
NSString *const kIFBGCommonMSL =
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
