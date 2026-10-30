// SPDX-License-Identifier: GPL-3.0-or-later
//
// Infinify compositor — the Metal shaders (kIFCMSL) and the per-device pipelines
// and samplers built from them. See IFCompositor.h and COMPOSITOR-NOTES.md
// (under docs/).
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "IFCompositor+Private.h"
#import "DWMetalSupport.h"

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
