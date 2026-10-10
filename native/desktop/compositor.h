// SPDX-License-Identifier: GPL-3.0-or-later
// Carried into native/desktop/ unchanged from the standalone compositor port that was built, verified against upstream's shaders and independently reviewed outside this repository; only this line was added.
//
// Infinify compositor: one Metal renderer per output that draws the whole
// frame — canvas background, output outlines, and every window with its
// shadow, border, rounded/clipped content and opacity, plus compositor-drawn
// stand-ins for suspended windows — and can render the same frame offscreen.
//
// A port of DriftWM's per-output frame composition to Metal. Derived from
// DriftWM (GPL-3.0-or-later), upstream commit
// 352333a8fa1b22171492d4b71a54102045c9a19d:
//   src/shaders/{border,shadow,corner_clip}.glsl, src/render/shaders.rs,
//   src/render/elements.rs, src/render/chrome.rs, src/render/suspended.rs,
//   src/render/mod.rs (compose_frame, build_output_outline_elements),
//   src/decorations.rs, src/text.rs, src/canvas.rs (coverage,
//   visible_canvas_rect), src/state/suspended.rs (standin_body_rect),
//   src/config/types.rs (DecorationConfig, OutputOutlineSettings,
//   effective_*).
//
// The module depends only on background.h (the canvas background renderer)
// and system frameworks. See NOTES.md for the host protocol, the mapping from
// the shell's snapshot, and every deviation from upstream.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#import "background.h"

NS_ASSUME_NONNULL_BEGIN

// MARK: - Values

/// An upstream `[u8; 4]` colour: straight RGBA bytes as written in the config.
typedef struct IFCompositorColor {
    uint8_t r, g, b, a;
} IFCompositorColor;

static inline IFCompositorColor IFCompositorColorMake(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    IFCompositorColor c = {r, g, b, a};
    return c;
}

/// Upstream `DecorationMode`. `Client` and `Minimal` render identically (no
/// title bar; clip, border and shadow apply). `Server` adds the compositor's
/// title bar. `None` passes the content through untouched: no clip, no border,
/// no shadow, whatever the other fields say.
typedef NS_ENUM(NSInteger, IFCompositorDecorationMode) {
    IFCompositorDecorationModeClient = 0,
    IFCompositorDecorationModeServer,
    IFCompositorDecorationModeMinimal,
    IFCompositorDecorationModeNone,
};

/// The decoration one element is drawn with: the values upstream's
/// `effective_*` helpers return for the window, after `DrawnChrome::drawn`.
typedef struct IFCompositorDecoration {
    IFCompositorDecorationMode mode;      ///< `effective_decoration_mode`
    int32_t borderWidth;                  ///< `effective_border_width`, logical px; 0 = none
    IFCompositorColor borderColor;        ///< `effective_border_color`
    IFCompositorColor borderColorFocused; ///< `effective_border_color_focused`
    int32_t cornerRadius;                 ///< `effective_corner_radius`, logical px
    BOOL shadow;                          ///< `effective_shadow_enabled`
    float shadowRadius;                   ///< `DecorationConfig::SHADOW_RADIUS` (14.0): Gaussian extent = 3 sigma, logical px
    IFCompositorColor shadowColor;        ///< `DecorationConfig::SHADOW_COLOR` (00000066)
    double opacity;                       ///< `effective_opacity` (times any animation alpha)
} IFCompositorDecoration;

/// Upstream's `DecorationConfig::default()` resolved for a window without a
/// rule: client mode, no border, #303030 border colours, radius 10, shadow on
/// (radius 14, #00000066), opacity 1.
FOUNDATION_EXPORT IFCompositorDecoration IFCompositorDecorationDefault(void);

/// Upstream `canvas::Coverage`.
typedef NS_ENUM(NSInteger, IFCompositorCoverage) {
    IFCompositorCoverageNone = 0,  ///< an edge falls short of the usable area
    IFCompositorCoverageExact,     ///< flush with the usable area on every edge
    IFCompositorCoverageOverhang,  ///< covers it and spills past at least one edge
};

/// Upstream `canvas::coverage`: how a window's visual frame (output-local
/// points, after zoom) sits against the output's usable area.
FOUNDATION_EXPORT IFCompositorCoverage IFCompositorCoverageOfFrame(CGRect frame, CGRect usable);

/// Upstream `DrawnChrome::drawn`: the chrome a window really wears. A
/// fullscreen window sheds all of it (mode becomes `None`); an exact cover
/// draws square and without shadow; an overhanging one also loses its border.
FOUNDATION_EXPORT IFCompositorDecoration IFCompositorDecorationDrawn(IFCompositorDecoration configured,
                                                                     BOOL fullscreen,
                                                                     IFCompositorCoverage coverage);

/// Upstream `OutputOutlineSettings` (`[output.outline]`).
typedef struct IFCompositorOutlineSettings {
    IFCompositorColor color;  ///< default #FFFFFF
    int32_t thickness;        ///< logical px, default 1; <= 0 disables
    double opacity;           ///< default 0.5; <= 0 disables
} IFCompositorOutlineSettings;

FOUNDATION_EXPORT IFCompositorOutlineSettings IFCompositorOutlineSettingsDefault(void);

/// Upstream's projection of another output's viewport onto this output
/// (`build_output_outline_elements`): `visible_canvas_rect` of the other
/// output, moved into this output's local points with upstream's integer
/// truncation. Pass the result to `-[IFCompositorFrame setOutlineRects:count:]`.
FOUNDATION_EXPORT CGRect IFCompositorOutlineRect(double cameraX, double cameraY, double zoom,
                                                 double otherCameraX, double otherCameraY,
                                                 CGSize otherSize, double otherZoom);

/// Upstream `FontWeight`.
typedef NS_ENUM(NSInteger, IFCompositorFontWeight) {
    IFCompositorFontWeightThin = 0,
    IFCompositorFontWeightExtraLight,
    IFCompositorFontWeightLight,
    IFCompositorFontWeightNormal,
    IFCompositorFontWeightMedium,
    IFCompositorFontWeightSemiBold,
    IFCompositorFontWeightBold,
    IFCompositorFontWeightExtraBold,
    IFCompositorFontWeightBlack,
};

/// Upstream `TitleAlign`.
typedef NS_ENUM(NSInteger, IFCompositorTitleAlign) {
    IFCompositorTitleAlignLeft = 0,
    IFCompositorTitleAlignCenter,
};

/// The part of upstream's `[decorations]` table that compositor-drawn chrome
/// (title bars, stand-in bodies and labels) is rasterised from. Global, not
/// per window. Defaults are upstream's.
@interface IFCompositorChromeStyle : NSObject <NSCopying>
@property (nonatomic) IFCompositorColor backgroundColor;   ///< `bg_color`, #303030
@property (nonatomic) IFCompositorColor foregroundColor;   ///< `fg_color`, #FFFFFF
@property (nonatomic) NSInteger cornerRadius;              ///< `corner_radius`, 10 (the stand-in body rounds to the configured radius)
@property (nonatomic) NSInteger titleBarHeight;            ///< `title_bar_height`, 25
@property (nonatomic, copy) NSString *font;                ///< `font`, "Adwaita Sans"
@property (nonatomic) NSUInteger fontSize;                 ///< `font_size`, 11 points
@property (nonatomic) IFCompositorFontWeight fontWeight;   ///< `font_weight`, medium
@property (nonatomic) IFCompositorTitleAlign titleAlign;   ///< `title_align`, center
@end

// MARK: - Elements

typedef NS_ENUM(NSInteger, IFCompositorElementKind) {
    IFCompositorElementKindWindow = 0,  ///< a live window: content texture plus chrome
    IFCompositorElementKindStandIn,     ///< upstream's suspended-window stand-in: bar, body fill, centred label
};

/// What `rect` is measured in.
typedef NS_ENUM(NSInteger, IFCompositorSpace) {
    /// Canvas (world) coordinates: the shell's `world_rect`. The default, and
    /// the only space that is pixel-exact against upstream: the renderer
    /// subtracts the camera itself, as upstream computes
    /// `render_loc = loc - camera`.
    IFCompositorSpaceCanvas = 0,
    /// Output-local points as shown on screen (after zoom): the shell's
    /// `screen_rect` minus the output's origin. Divided by the frame's zoom to
    /// recover upstream's pre-zoom rectangle. NOT pixel-exact against
    /// upstream: the division does not give back `loc - camera` to the last
    /// bit, so a window whose edge lands exactly on half a device pixel (a
    /// camera ending in .5 at 1x, .25 / .75 at 2x) can round the other way and
    /// sit one pixel off its neighbours and the background. Measured: 12 to 26
    /// of 150 integer-positioned windows at such cameras with zoom 0.8, 0.72
    /// or 0.37; none at zoom 1 or 0.5, or with an integer camera. Use it only
    /// for rectangles that have no canvas position.
    IFCompositorSpaceOutput,
    /// Output-local points drawn at zoom 1 whatever the frame's zoom:
    /// upstream's screen-pinned windows.
    IFCompositorSpacePinned,
};

/// Upstream's z buckets. The renderer draws all widgets, then all normal
/// elements, then all pinned ones, keeping the host's order within a bucket.
typedef NS_ENUM(NSInteger, IFCompositorStackLayer) {
    IFCompositorStackLayerNormal = 0,
    IFCompositorStackLayerWidget,  ///< below normal windows (`zoomed_widgets`)
    IFCompositorStackLayerPinned,  ///< above normal windows (`zoomed_pinned`)
};

/// Upstream `WindowRenderAnimation`: a per-element affine applied after the
/// zoom, in physical pixels of the output. Each drawn rectangle `r` becomes
/// `origin + (r - origin) * scale + offset`, corners rounded independently.
typedef struct IFCompositorTransform {
    double originX, originY;
    double offsetX, offsetY;
    double scaleX, scaleY;
} IFCompositorTransform;

/// One window or stand-in. A plain mutable object: the host keeps one per
/// placement and updates it in place, so a steady frame allocates nothing.
@interface IFCompositorElement : NSObject
/// Stable identity (per window per output), unique within a frame. Keys the
/// renderer's caches. A window that becomes a stand-in (or the reverse) keeps
/// its identifier, as upstream keeps the element id; the renderer then drops
/// what it cached for the other kind.
@property (nonatomic) uint64_t identifier;
@property (nonatomic) IFCompositorElementKind kind;

/// The window's content rectangle (upstream: the window geometry), without
/// any chrome. May extend beyond the output. See `space`.
/// For a stand-in this is its BODY: the title bar is drawn above it, outside
/// `rect`. A stand-in that replaces a window which carried its own title bar
/// (every macOS window) therefore does not take the window's rectangle but
/// `IFCompositorStandInBodyRect(windowRect, YES, chrome.titleBarHeight)`.
@property (nonatomic) CGRect rect;
@property (nonatomic) IFCompositorSpace space;
@property (nonatomic) IFCompositorStackLayer layer;

/// Optional scissor in output-local points (as on screen). Clips everything
/// this element draws, chrome included. Not an upstream concept; the output
/// itself always clips, so the shell's per-placement `clip_rect` is NOT needed
/// here (passing it would cut off the shadow and border).
@property (nonatomic) BOOL hasClipRect;
@property (nonatomic) CGRect clipRect;

@property (nonatomic) BOOL focused;
@property (nonatomic) IFCompositorDecoration decoration;

/// Live content, one of the two; both nil while no frame has arrived. A
/// stand-in draws none and the renderer keeps nothing of it (set both to nil
/// so the element does not hold the last capture buffer either).
/// `pixelBuffer` must be IOSurface-backed `kCVPixelFormatType_32BGRA`
/// (what ScreenCaptureKit delivers); it is retained while set. `texture` is
/// sampled as is (BGRA8Unorm or RGBA8Unorm, not an _sRGB format) and must
/// belong to the renderer's device; it wins when both are set.
/// Either way the texels are premultiplied alpha in sRGB encoding.
@property (nonatomic, nullable) CVPixelBufferRef pixelBuffer;
@property (nonatomic, strong, nullable) id<MTLTexture> texture;
/// Bump whenever the content's pixels change without the buffer object
/// changing (a recycled pool buffer, a texture rendered to again). The layer
/// compares it to decide whether to redraw.
@property (nonatomic) uint64_t contentGeneration;
/// The sub-rectangle of the buffer that holds the window content, in buffer
/// pixels, origin top-left. `CGRectNull` (the default) means the whole buffer.
@property (nonatomic) CGRect contentRect;
/// The content has no meaningful alpha (upstream's XRGB `NO_ALPHA` path):
/// sampled alpha is replaced by 1.
@property (nonatomic) BOOL contentOpaque;

/// `Server` mode: the title-bar text (upstream falls back to the app id, then
/// blank — resolve that before setting). Stand-in: kept for the host's use;
/// upstream draws a stand-in's bar textless and this module does too. It is
/// used as the label only when `appName` is empty.
@property (nonatomic, copy, nullable) NSString *title;
/// Stand-in: the centred label (upstream `identity.display_name`).
@property (nonatomic, copy, nullable) NSString *appName;
/// Stand-in: appends upstream's " launching…" to the label.
@property (nonatomic) BOOL launching;
/// `Server` mode: draw the screen-pinned dot at the bar's left edge.
@property (nonatomic) BOOL showsPinnedIndicator;

/// Per-element animation transform (open/move/resize, stand-in dismiss).
@property (nonatomic) BOOL hasTransform;
@property (nonatomic) IFCompositorTransform transform;
@end

/// Upstream `standin_body_rect` (src/state/suspended.rs): the `rect` of the
/// stand-in that takes the place of a window whose content rectangle was
/// `windowRect`. A server-decorated window (`clientDecorated` NO) keeps its
/// rectangle: the compositor's bar already sat above it. A client-decorated
/// one shrinks under a bar of `titleBarHeight` (`chrome.titleBarHeight`), so
/// bar + body cover exactly the window that was there:
/// `(x, y + bar, w, max(h - bar, 1))`; a window shorter than the bar keeps a
/// 1 px body and grows by the shortfall. `windowRect` is in the pre-zoom
/// units of `IFCompositorSpaceCanvas` or `IFCompositorSpacePinned`.
FOUNDATION_EXPORT CGRect IFCompositorStandInBodyRect(CGRect windowRect, BOOL clientDecorated, NSInteger titleBarHeight);

// MARK: - Frame

/// What the target holds before anything is drawn.
typedef NS_ENUM(NSInteger, IFCompositorClear) {
    /// Opaque black: upstream's live output (`render_frame` with [0,0,0,1]).
    IFCompositorClearOpaqueBlack = 0,
    /// Transparent: upstream's `msg screenshot` target, so a capture without a
    /// background keeps alpha.
    IFCompositorClearTransparent,
};

/// Diagnostics: restrict a frame to some of its passes (0 = everything).
typedef NS_OPTIONS(NSUInteger, IFCompositorPass) {
    IFCompositorPassBackground = 1 << 0,
    IFCompositorPassOutline = 1 << 1,
    IFCompositorPassShadow = 1 << 2,
    IFCompositorPassBorder = 1 << 3,
    IFCompositorPassContent = 1 << 4,
    IFCompositorPassTitleBar = 1 << 5,
    IFCompositorPassStandInBody = 1 << 6,
    IFCompositorPassLabel = 1 << 7,
};

/// Everything one output shows at one instant. The host owns one per output,
/// refills it and hands it to the layer; nothing in it is retained by the
/// renderer beyond the call.
@interface IFCompositorFrame : NSObject
@property (nonatomic) CGSize size;        ///< output size in points
@property (nonatomic) double scale;       ///< backing scale (pixels per point)
@property (nonatomic) double cameraX;     ///< world point at the output's top-left (Y down)
@property (nonatomic) double cameraY;
@property (nonatomic) double zoom;        ///< screen points per world point
@property (nonatomic) double time;        ///< seconds since the host started (`u_time`)

/// The canvas background, or nil for none. Share one program between outputs.
@property (nonatomic, strong, nullable) IFBackgroundProgram *background;
@property (nonatomic) IFCompositorClear clear;

/// Global chrome style; defaults to upstream's `[decorations]` defaults.
@property (nonatomic, copy) IFCompositorChromeStyle *chrome;
/// Upstream `decoration_scale`: `ceil` of the largest backing scale among all
/// outputs. 0 (the default) means `ceil(scale)` of this frame.
@property (nonatomic) NSInteger decorationScale;
/// Fill for a window whose content has not arrived (both sources nil). Not an
/// upstream concept. Default: the chrome background colour (#303030). Alpha 0
/// draws nothing there.
@property (nonatomic) IFCompositorColor placeholderColor;

/// Elements, bottom to top.
@property (nonatomic, readonly) NSMutableArray<IFCompositorElement *> *elements;

/// Outlines of other outputs' viewports, in this output's local points (see
/// `IFCompositorOutlineRect`). Copied; drawn below every element.
@property (nonatomic) IFCompositorOutlineSettings outline;
- (void)setOutlineRects:(nullable const CGRect *)rects count:(NSUInteger)count;
@property (nonatomic, readonly) NSUInteger outlineRectCount;
- (CGRect)outlineRectAtIndex:(NSUInteger)index;

/// YES when the frame must be redrawn on every display tick even if the host
/// changes nothing: today, an animated background.
@property (nonatomic, readonly) BOOL needsContinuousRedraw;

@property (nonatomic) IFCompositorPass debugPasses;
@end

// MARK: - Renderer

/// Draws frames for one output and owns that output's caches (content texture
/// wrappers, rasterised title bars, bodies and labels). Not thread-safe: use
/// one renderer from one thread at a time.
@interface IFCompositorRenderer : NSObject

/// `device` nil means the system default device. Returns nil without Metal.
+ (nullable instancetype)rendererWithDevice:(nullable id<MTLDevice>)device;

@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;

/// Encodes one render pass drawing `frame` into `target`, which must be
/// BGRA8Unorm and round(size * scale) pixels. Returns NO if nothing could be
/// encoded. The caller commits `commandBuffer`; it should come from
/// `commandQueue`, because textures the renderer stops using are released
/// when the command buffers encoded so far have completed, in order.
- (BOOL)encodeFrame:(IFCompositorFrame *)frame
        intoTexture:(id<MTLTexture>)target
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

/// Offscreen render: no window, no layer, no privacy permission. Returns an
/// sRGB image of round(width*scale) x round(height*scale) pixels; it carries
/// (premultiplied) alpha only when `frame.clear` is transparent.
- (nullable CGImageRef)newImageForFrame:(IFCompositorFrame *)frame
                                  error:(NSError **)error CF_RETURNS_RETAINED;
- (BOOL)writePNGForFrame:(IFCompositorFrame *)frame
                   toURL:(NSURL *)url
                   error:(NSError **)error;
/// The exact framebuffer of an offscreen render: tightly packed BGRA8 rows,
/// top row first, premultiplied.
- (nullable NSData *)BGRADataForFrame:(IFCompositorFrame *)frame
                                error:(NSError **)error;

/// Drops every cached texture. The next frame rebuilds what it needs.
- (void)purge;
/// Cached per-element entries (diagnostics).
@property (nonatomic, readonly) NSUInteger cacheEntryCount;
/// Chrome rasterisations and content-texture wrappers created so far
/// (diagnostics: both stay constant across steady frames).
@property (nonatomic, readonly) NSUInteger chromeRasterCount;
@property (nonatomic, readonly) NSUInteger contentWrapCount;

/// Diagnostics: called once per draw with the pass name, the destination
/// rectangle in pixels and the uniforms. Costs allocations; leave nil.
@property (nonatomic, copy, nullable) void (^debugDrawHandler)(NSDictionary<NSString *, id> *draw);
@end

// MARK: - Layer

/// One output on screen. Main thread only. The host sets `frame` (the layer's
/// geometry) and calls `-updateWithFrame:`; the layer sets its own
/// `drawableSize` and `contentsScale`.
@interface IFCompositorLayer : CAMetalLayer

/// `renderer` nil builds a private one on the system default device.
- (instancetype)initWithRenderer:(nullable IFCompositorRenderer *)renderer;
/// nil only when the machine has no Metal device.
@property (nonatomic, readonly, nullable) IFCompositorRenderer *renderer;

/// Redraws if, and only if, the frame description or a content buffer changed
/// since the last drawn frame, or an animated background is due. Returns YES
/// when a new frame was presented. A call that does not redraw touches no
/// GPU state; at most once every 1.5 s it flushes the renderer's texture
/// cache, which is what frees the surface of a capture buffer released a
/// second or more ago (a window that closed or became a stand-in).
- (BOOL)updateWithFrame:(IFCompositorFrame *)frame;

/// Forces the next update to redraw.
- (void)setNeedsRedraw;

/// From the last frame passed to `-updateWithFrame:`: the host must keep
/// calling it on every display tick (with an advancing `time`).
@property (nonatomic, readonly) BOOL needsContinuousRedraw;

/// Frames presented so far (diagnostics).
@property (nonatomic, readonly) NSUInteger drawCount;

/// Diagnostics only: keep a copy of each presented frame (gives up
/// `framebufferOnly`). Used by `comprender --via-layer`.
@property (nonatomic) BOOL debugCaptureEnabled;
- (nullable CGImageRef)newDebugImageOfLastFrame CF_RETURNS_RETAINED;
- (nullable NSData *)debugBGRADataOfLastFrame;
@end

NS_ASSUME_NONNULL_END
