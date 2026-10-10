// SPDX-License-Identifier: GPL-3.0-or-later
// Carried into native/desktop/ unchanged from the standalone compositor port that was built, verified against upstream's shaders and independently reviewed outside this repository; only this line was added.
//
// Infinify canvas background renderer.
//
// A port of DriftWM's per-output canvas background (the dot grid, user GLSL
// shaders, tiled images and cover-fit wallpapers) to Metal. Derived from
// DriftWM (GPL-3.0-or-later), upstream commit
// 352333a8fa1b22171492d4b71a54102045c9a19d:
//   src/render/background.rs, src/render/shaders.rs, src/render/elements.rs,
//   src/shaders/{dot_grid,tile_bg,wallpaper_bg}.glsl, docs/shaders.md.
//
// The module has no dependency on the rest of the app. See NOTES.md for the
// uniform mapping, the host driving protocol and every deviation from upstream.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// `[background] type`, upstream `BackgroundKind`.
typedef NS_ENUM(NSInteger, IFBackgroundType) {
    IFBackgroundTypeDefault = 0,  ///< built-in dot grid
    IFBackgroundTypeShader,       ///< user GLSL ES 1.00 fragment shader at `path`
    IFBackgroundTypeTile,         ///< PNG/JPEG at `path`, tiled over the canvas
    IFBackgroundTypeWallpaper,    ///< PNG/JPEG at `path`, cover-fit to the viewport
    IFBackgroundTypeNone,         ///< draw nothing
};

/// What a loaded program really renders. Differs from the requested type when
/// upstream's fallback rules replaced it with the dot grid.
typedef NS_ENUM(NSInteger, IFBackgroundKind) {
    IFBackgroundKindNone = 0,
    IFBackgroundKindDotGrid,
    IFBackgroundKindShader,
    IFBackgroundKindTexturedShader,
    IFBackgroundKindTile,
    IFBackgroundKindWallpaper,
};

/// The upstream `[background]` table (`BackgroundConfig`), field for field.
@interface IFBackgroundConfig : NSObject <NSCopying>
@property (nonatomic) IFBackgroundType type;            ///< `type`, default "default"
@property (nonatomic, copy, nullable) NSString *path;   ///< `path` (shader / tile / wallpaper source)
@property (nonatomic, copy, nullable) NSString *texture;///< `texture` (shader only, bound to `tex`)
@property (nonatomic) BOOL mirrorTile;                  ///< `mirror_tile`, default false
@property (nonatomic) BOOL cacheShader;                 ///< `cache_shader`, default false (accepted; no effect here)
@property (nonatomic) BOOL transparentShader;           ///< `transparent_shader`, default false
@property (nonatomic) NSUInteger cacheBudgetMB;         ///< `cache_budget_mb`, default 128 (accepted; no effect here)
@property (nonatomic) NSUInteger animateFPS;            ///< `animate_fps`, default 0, clamped to 1000

/// Upstream `resolve_background_kind`: builds a config from the raw TOML
/// strings. A missing `path` for shader/tile/wallpaper or an unknown type
/// yields the default dot grid and sets `*warning` to upstream's message.
/// `~` is expanded in `path` and `texture`.
+ (instancetype)configWithTypeString:(nullable NSString *)type
                                path:(nullable NSString *)path
                             texture:(nullable NSString *)texture
                             warning:(NSString *_Nullable *_Nullable)warning;
@end

/// One output's view of the canvas at one instant.
typedef struct IFBackgroundFrame {
    double cameraX, cameraY;  ///< world point at the output's top-left (Y down)
    double zoom;              ///< screen points per world point
    double width, height;     ///< output size in points
    double scale;             ///< backing scale (pixels per point)
    double time;              ///< seconds since the host started (`u_time`)
} IFBackgroundFrame;

/// A compiled background: shader pipeline and/or image for one device.
/// Immutable after creation and safe to share between any number of layers, so
/// a panel with several outputs loads the configuration once.
@interface IFBackgroundProgram : NSObject

/// Loads `config` (reads the shader / image from disk, compiles). Never fails:
/// on any error it falls back the way upstream does and sets `errorText`.
/// `device` nil means the system default device.
+ (instancetype)programWithConfig:(IFBackgroundConfig *)config
                           device:(nullable id<MTLDevice>)device;

@property (nonatomic, readonly, copy) IFBackgroundConfig *config;
@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) IFBackgroundKind kind;
/// Upstream's error-bar text when the requested background could not be
/// honoured (nil when it loaded cleanly).
@property (nonatomic, readonly, copy, nullable) NSString *errorText;
/// The shader reads `u_time`: the host must call update every frame.
@property (nonatomic, readonly, getter=isAnimated) BOOL animated;
/// The output changes when the camera moves (upstream `background_uses_camera`,
/// plus tile mode, which always scrolls).
@property (nonatomic, readonly) BOOL usesCamera;
/// The shader reads `u_zoom` (informational; every canvas-space kind is
/// redrawn on a zoom change regardless, as upstream resizes the element).
@property (nonatomic, readonly) BOOL usesZoom;
/// The output carries alpha that must be composited (premultiplied) over
/// whatever is below; otherwise it is opaque.
@property (nonatomic, readonly, getter=isTransparent) BOOL transparent;
/// Image size in pixels for tile / wallpaper / textured shader, else zero.
@property (nonatomic, readonly) CGSize textureSize;
/// The Metal source generated from the user's GLSL (nil for built-in kinds).
@property (nonatomic, readonly, copy, nullable) NSString *translatedShaderSource;

/// Encodes one render pass drawing `frame` into `target` (BGRA8Unorm).
- (void)encodeFrame:(IFBackgroundFrame)frame
        intoTexture:(id<MTLTexture>)target
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

/// Compositor hook (added in compositor-port; see its NOTES.md). Draws `frame`
/// into a render pass the caller already opened on a BGRA8Unorm target of
/// round(width*scale) x round(height*scale) pixels, with the full-target
/// viewport and scissor. Blending is off: the background replaces what the
/// pass cleared. Sets the pipeline, fragment buffer 0, fragment texture 0 and
/// fragment sampler 0 on `encoder` and leaves them set. Returns NO, drawing
/// nothing, for `none` or when no pipeline could be built.
- (BOOL)encodeFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder;

/// Offscreen render: no window, no layer, no privacy permission.
/// Returns an sRGB image of round(width*scale) x round(height*scale) pixels.
- (nullable CGImageRef)newImageForFrame:(IFBackgroundFrame)frame
                                  error:(NSError **)error CF_RETURNS_RETAINED;
- (BOOL)writePNGForFrame:(IFBackgroundFrame)frame
                   toURL:(NSURL *)url
                   error:(NSError **)error;
@end

/// Renders one output's background. Main thread only.
@interface IFBackgroundLayer : CAMetalLayer

/// The background to draw. Assigning marks the layer dirty.
@property (nonatomic, strong, nullable) IFBackgroundProgram *program;

/// Convenience for a single output: builds a private program on the system
/// default device.
- (void)setConfig:(IFBackgroundConfig *)config;

@property (nonatomic, readonly, getter=isAnimated) BOOL animated;
@property (nonatomic, readonly, copy, nullable) NSString *errorText;

/// Redraws if, and only if, something this background depends on changed
/// since the last drawn frame. Returns YES when a new frame was presented.
- (BOOL)updateWithFrame:(IFBackgroundFrame)frame;

/// Forces the next update to redraw.
- (void)setNeedsRedraw;

/// Frames presented so far (diagnostics).
@property (nonatomic, readonly) NSUInteger drawCount;

/// Diagnostics only: when YES the layer keeps a copy of each frame it draws
/// (and gives up `framebufferOnly`). Used by `bgrender --via-layer`.
@property (nonatomic) BOOL debugCaptureEnabled;
- (nullable CGImageRef)newDebugImageOfLastFrame CF_RETURNS_RETAINED;
@end

NS_ASSUME_NONNULL_END
