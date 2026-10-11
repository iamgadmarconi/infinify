// SPDX-License-Identifier: GPL-3.0-or-later
// Carried into native/desktop/ from the standalone compositor port that was built, verified against upstream's shaders and independently reviewed outside this repository. Changed here since: the two chunk caches, `cache_shader` and tiled pyramidal TIFF tiles (BACKGROUND-NOTES.md, section 17).
//
// Infinify canvas background renderer.
//
// A port of DriftWM's per-output canvas background (the dot grid, user GLSL
// shaders, tiled images and cover-fit wallpapers) to Metal. Derived from
// DriftWM (GPL-3.0-or-later), upstream commit
// 352333a8fa1b22171492d4b71a54102045c9a19d:
//   src/render/background.rs, src/render/shaders.rs, src/render/elements.rs,
//   src/shaders/{dot_grid,tile_bg,wallpaper_bg}.glsl, docs/shaders.md.
// The two chunk caches (`cache_shader` and tiled pyramidal TIFF tiles) are
// adapted from the same commit's src/render/shader_chunks.rs,
// src/render/tile_chunks.rs, src/render/capture_background.rs,
// src/shaders/chunk_bg.glsl and docs/gigapixel-wallpapers.md, with
// background-tiff.{h,m} beside this file (NOTES.md, section 17).
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
    IFBackgroundTypeTile,         ///< PNG/JPEG at `path`, tiled over the canvas; a `.tif` / `.tiff` path is a tiled pyramidal TIFF
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

/// Where a program's picture comes from on screen. Upstream keeps a chunk
/// cache per output for the last two (`cached_shader_chunks`,
/// `cached_tile_chunks`); see `-programForOutput`.
typedef NS_ENUM(NSInteger, IFBackgroundCache) {
    IFBackgroundCacheNone = 0,     ///< drawn live, every frame
    IFBackgroundCacheShaderBake,   ///< `cache_shader`: a static shader baked once into canvas-space chunk textures
    IFBackgroundCacheTileChunks,   ///< a tiled pyramidal TIFF, drawn from its levels chunk by chunk
};

/// The upstream `[background]` table (`BackgroundConfig`) and macOS wallpaper
/// options. The latter do not change tile or user-shader coordinates.
@interface IFBackgroundConfig : NSObject <NSCopying>
@property (nonatomic) IFBackgroundType type;            ///< `type`, default "default"
@property (nonatomic, copy, nullable) NSString *path;   ///< `path` (shader / tile / wallpaper source)
@property (nonatomic, copy, nullable) NSString *texture;///< `texture` (shader only, bound to `tex`)
@property (nonatomic) BOOL mirrorTile;                  ///< `mirror_tile`, default false
@property (nonatomic) BOOL cacheShader;                 ///< `cache_shader`, default false
@property (nonatomic) BOOL transparentShader;           ///< `transparent_shader`, default false
@property (nonatomic) NSUInteger cacheBudgetMB;         ///< `cache_budget_mb`, default 128: the ceiling of each output's chunk cache
@property (nonatomic) NSUInteger animateFPS;            ///< `animate_fps`, default 0, clamped to 1000
@property (nonatomic) BOOL parallax;                    ///< `parallax`, default true: wallpaper follows camera/zoom at a bounded depth
@property (nonatomic) BOOL inheritedWallpaper;          ///< macOS still image; permits ImageIO formats and honours the following options
@property (nonatomic) NSInteger wallpaperScaling;       ///< NSImageScaling, default proportionally up or down (3)
@property (nonatomic) BOOL wallpaperClipping;            ///< proportional image covers the output; default true (resolver supplies NSWorkspace's value)
@property (nonatomic, copy) NSArray<NSNumber *> *wallpaperFillColor; ///< opaque sRGB RGBA, default black; inherited wallpaper only

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
/// plus tile mode and wallpapers with parallax enabled).
@property (nonatomic, readonly) BOOL usesCamera;
/// The shader reads `u_zoom` (informational; every canvas-space kind is
/// redrawn on a zoom change regardless, as upstream resizes the element).
/// Wallpapers with parallax enabled also report YES.
@property (nonatomic, readonly) BOOL usesZoom;
/// The output carries alpha that must be composited (premultiplied) over
/// whatever is below; otherwise it is opaque.
@property (nonatomic, readonly, getter=isTransparent) BOOL transparent;
/// Image size in pixels for tile / wallpaper / textured shader, else zero.
/// For a pyramidal TIFF: the size of its full-resolution level.
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
/// fragment sampler 0 on `encoder` and leaves them set; a program with a chunk
/// cache also sets vertex buffer 0, and first bakes or uploads the chunks this
/// frame may (see `-programForOutput`). Returns NO, drawing nothing, for
/// `none` or when no pipeline could be built.
- (BOOL)encodeFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder;

/// Offscreen render: no window, no layer, no privacy permission.
/// Returns an sRGB image of round(width*scale) x round(height*scale) pixels.
- (nullable CGImageRef)newImageForFrame:(IFBackgroundFrame)frame
                                  error:(NSError **)error CF_RETURNS_RETAINED;
- (BOOL)writePNGForFrame:(IFBackgroundFrame)frame
                   toURL:(NSURL *)url
                   error:(NSError **)error;

// MARK: Chunk caches (NOTES.md, section 17)

/// What this program draws from: `IFBackgroundCacheNone` for every kind that is
/// rendered live. A cached program has `kind` Shader (a baked shader) or Tile
/// (a pyramidal TIFF), and `usesCamera` YES.
@property (nonatomic, readonly) IFBackgroundCache cache;

/// Upstream keeps one chunk cache per output: its chunks are baked at that
/// output's scale, and its budget, its bake allowance and its decode pool are
/// its own. For a cached program this returns a program that shares everything
/// loaded (the compiled shader, the open pyramid and its fallback level) and
/// owns a chunk cache; ask once per output and keep the result. For every
/// other program it returns the receiver. The program `+programWithConfig:`
/// returned also works by itself, as one such output.
///
/// A program that owns a cache is no longer immutable: its frames are encoded
/// on the main thread only. Encoding a frame bakes or uploads what that frame
/// may (upstream's per-frame allowances) before it draws, on the module's own
/// command queue, and draws what is ready: a baked shader is never blank (its
/// coarsest level is baked at once), a TIFF shows its fallback level under the
/// chunks still loading. Each instant is one frame: encoding the same frame
/// again, `time` included, draws the same chunks and spends nothing more.
- (IFBackgroundProgram *)programForOutput;

/// What an offscreen capture draws (upstream capture_background.rs): never a
/// chunk cache. A baked shader is rendered live; a pyramidal TIFF is one level,
/// the finest that is at most 4096 pixels on its longer side, tiled at the
/// full-resolution image's extent, or nothing at all when that level cannot be
/// read. Every other program is the receiver.
- (IFBackgroundProgram *)captureProgram;

/// Chunks the last encoded frame wanted and could not draw yet: baked-shader
/// cells left for a later frame, TIFF chunks being decoded or waiting to be
/// uploaded. While it is not zero the host keeps redrawing, at its display
/// rate, with an advancing `time` (upstream: `has_pending_bakes`,
/// `has_pending_loads`). Zero for a program without a cache.
@property (nonatomic, readonly) NSUInteger pendingChunkCount;

/// The chunk work of `frame` without its draw: bakes or uploads what
/// `-encodeFrame:inEncoder:` would first, so that encoding the same frame
/// afterwards spends nothing more, and returns a number that changes whenever
/// the chunks a frame draws from did (a bake, an upload, an eviction, a
/// shrink). Upstream's blur keys its frost on the set of background elements
/// (blur.rs `background_structure_changed`), and each drawn chunk is one: a
/// compositor that keeps anything computed from the background mixes this
/// number into its key. Always 0 for a program without a cache.
- (uint64_t)chunkGenerationForFrame:(IFBackgroundFrame)frame;

/// Called on the main thread when a decoded TIFF chunk waits to be uploaded
/// (upstream's `loop_signal.wakeup()`): the host redraws this output. Not
/// called for a baked shader, whose work happens inside a frame.
@property (nonatomic, copy, nullable) dispatch_block_t chunkReadyHandler;

/// Upstream `shrink`, called for every frame a fullscreen window conceals the
/// canvas on this output: a baked shader keeps its coarsest level only, a TIFF
/// drops every chunk and every outstanding request and keeps its fallback
/// level. Nothing is pending afterwards.
- (void)shrinkChunkCache;

/// Diagnostics: chunk textures this cache holds and their bytes (what
/// `cache_budget_mb` bounds; a TIFF's fallback level is not counted, as
/// upstream does not count it), chunks baked or uploaded so far, chunks
/// evicted so far, and whether the last frame's working set exceeded the
/// budget (a baked shader then shows its coarsest level only; a TIFF keeps
/// the coarser levels that fit).
@property (nonatomic, readonly) NSUInteger chunkCount;
@property (nonatomic, readonly) uint64_t chunkBytes;
@property (nonatomic, readonly) NSUInteger chunkLoadCount;
@property (nonatomic, readonly) NSUInteger chunkEvictionCount;
@property (nonatomic, readonly, getter=isChunkCacheDegraded) BOOL chunkCacheDegraded;
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
