// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/compositor.m at 37b27b1.
//
// Infinify compositor — internal declarations shared by the compositor's
// implementation files; not API. See IFCompositor.h and docs/native/app/Canvas/COMPOSITOR-NOTES.md
// (under docs/).
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "IFCompositor.h"

#import <simd/simd.h>

// Everything below moved verbatim from the former compositor.m, a main file,
// where clang does not check nullability completeness. Two `nullable`s in
// IFCDeviceResources would otherwise make every unannotated pointer in this
// header an error.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

// Largest 2D texture on every Apple-silicon GPU.
static const NSUInteger kIFCMaxTextureSide = 16384;
// error_bar.rs constants.
static const float kIFCErrorBarFontPx = 11.0f;        // ERROR_BAR_FONT_PX, logical px (not points)
static const long kIFCErrorBarPadX = 12;              // ERROR_BAR_PAD_X
static const long kIFCErrorBarPadY = 6;               // ERROR_BAR_PAD_Y

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

// MARK: - Per-device shared state (IFCDeviceResources.m)

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

// MARK: - Deferred release (IFCompositorRenderer.m)

@interface IFCGraveyard : NSObject
- (void)began;
- (void)finished;
- (void)bury:(id)object;
@end

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

static inline void IFCMixRect(uint64_t *h, CGRect r) {
    double v[4] = {r.origin.x, r.origin.y, r.size.width, r.size.height};
    IFCMix(h, v, sizeof v);
}

static inline void IFCMixColor(uint64_t *h, IFCompositorColor c) {
    uint8_t v[4] = {c.r, c.g, c.b, c.a};
    IFCMix(h, v, sizeof v);
}

// MARK: - Internal methods of the public classes

@interface IFCompositorChromeStyle ()
- (uint64_t)ifc_hash;
@end

@interface IFCompositorElement ()
- (void)ifc_mixContentIdentity:(uint64_t *)h;
- (void)ifc_mix:(uint64_t *)h content:(BOOL)content;
@end

// One element's lifecycle animation resolved for one frame.
typedef struct {
    IFCompositorLifecycle kind;  // None when the element has none, or when it is over (see `finished`)
    double progress;             // 0..1
    BOOL finished;               // the animation has run out (upstream would have dropped it)
    BOOL timed;                  // derived from `lifecycleStartTime`
} IFCLife;

// IFCompositorFrame.m.
IFCLife IFCResolveLife(IFCompositorElement *element, double time, IFCompositorEffects effects);

@interface IFCompositorFrame ()
- (uint64_t)ifc_fingerprint;
- (const CGRect *)ifc_outlineRects;
- (BOOL)ifc_backgroundAnimates;
@end

// Integer output size (IFCompositorFrame.m).
void IFCPixelSize(IFCompositorFrame *f, long *logicalW, long *logicalH, NSUInteger *pxW, NSUInteger *pxH);

// MARK: - Rasterisers (DWCompositorRasterizers.m)

NSMutableData *IFCRenderTitleBar(long width, long scale, NSString *title, BOOL pinned, long cornerRadius,
                                 IFCompositorChromeStyle *style, long *outW, long *outH);
NSMutableData *IFCRenderBodyFill(long width, long height, long scale, IFCompositorChromeStyle *style, long *outW, long *outH);
NSMutableData *IFCRenderLabel(NSString *text, long bodyW, long bodyH, long scale, IFCompositorChromeStyle *style,
                              long *outW, long *outH, IFCRectI *labelRect);
NSMutableData *IFCRenderErrorBar(NSString *text, long width, long barHeight, long scale, long *outW, long *outH);

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

// MARK: - Uniform helpers (IFCompositorRenderer+Draw.m)

void IFCSetSource(IFCUniforms *u, CGRect source, double texW, double texH);
IFCRectI IFCTransformRect(IFCRectI r, IFCompositorTransform t);

// MARK: - Renderer internals

typedef struct {
    uintptr_t *keys;
    NSUInteger count, capacity;
    uint64_t generation;
} IFCStaleScan;

@interface IFCompositorRenderer () {
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
- (void)ifc_flushAgedTextures;
// Per-element caches and allocation (IFCompositorRenderer.m).
- (IFCEntry *)entryFor:(uint64_t)identifier;
- (void)retireContentOf:(IFCEntry *)entry;
- (void)retireChromeOf:(IFCEntry *)entry keepingBar:(BOOL)keepBar;
- (void)retirePadsOf:(IFCEntry *)entry;
- (void)retireFrostOf:(IFCEntry *)entry;
- (id<MTLTexture>)contentTextureFor:(IFCompositorElement *)element;
- (id<MTLTexture>)textureWithRGBA:(NSData *)data width:(long)w height:(long)h;
- (id<MTLTexture>)barTextureFor:(IFCEntry *)e width:(long)width scale:(long)scale title:(NSString *)title
                         pinned:(BOOL)pinned radius:(long)radius style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash;
- (id<MTLTexture>)bodyTextureFor:(IFCEntry *)e width:(long)bodyW height:(long)bodyH scale:(long)scale
                           style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash;
- (id<MTLTexture>)labelTextureFor:(IFCEntry *)e name:(NSString *)name launching:(BOOL)launching width:(long)bodyW height:(long)bodyH
                            scale:(long)scale style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash;
- (id<MTLTexture>)placeholderTextureForColor:(IFCompositorColor)color;
- (id<MTLTexture>)newBlurTextureWidth:(long)width height:(long)height;
@end

static inline IFCUniforms IFCUniformsZero(void) {
    IFCUniforms u;
    memset(&u, 0, sizeof u);
    u.src = simd_make_float4(0, 0, 1, 1);
    u.uv_bounds = simd_make_float4(0, 0, 1, 1);
    u.alpha = 1.0f;
    return u;
}

// Element drawing and render passes (IFCompositorRenderer+Draw.m).
@interface IFCompositorRenderer (Draw)
- (void)draw:(IFCPipe)pipe dst:(IFCRectI)dst uniforms:(IFCUniforms *)u texture:(id<MTLTexture>)texture
     element:(IFCompositorElement *)element;
- (void)drawItem:(const IFCItem *)item frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c;
- (void)drawErrorBar:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c;
- (void)drawOutlines:(IFCompositorFrame *)frame scale:(double)s viewportW:(long)viewportW viewportH:(long)viewportH;
- (BOOL)beginPassOn:(id<MTLTexture>)texture width:(long)width height:(long)height load:(MTLLoadAction)load
              clear:(MTLClearColor)clear commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
- (void)endPass;
- (void)rawDraw:(IFCPipe)pipe dst:(IFCRectI)dst uniforms:(IFCUniforms *)u texture:(id<MTLTexture>)texture;
@end

// Frosted-glass blur (IFCompositorRenderer+Blur.m).
@interface IFCompositorRenderer (Blur)
- (void)prepareFrosts:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
@end

#pragma clang diagnostic pop
