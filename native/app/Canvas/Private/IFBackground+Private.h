// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: the declarations the module's own files
// share (the uniform blocks of the built-in shaders, the chunk-cache constants
// and records, the internal classes, and the functions one file defines for
// another). Private to the background module's implementation files; everything
// else imports IFBackground.h.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: the uniform blocks follow the
// built-in shaders' (src/shaders/*.glsl, see IFBGDeviceResources.m); the
// chunk-cache section below names the upstream paths its constants and records
// follow (src/render/shader_chunks.rs, src/render/tile_chunks.rs, ...).
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackground.h"
#import "IFBGTiffSource.h"

#import <Metal/Metal.h>
#import <simd/simd.h>
#import "DWMetalSupport.h"

// Everything up to the prototypes is moved verbatim from background.m, a main
// file, where clang never checks nullability completeness. Keep it as it was:
// a pointer without an annotation stays unspecified (not NS_ASSUME_NONNULL,
// which would make NULL arguments such as IFBGPixelSize(f, &w, &h, NULL, NULL)
// -Wnonnull errors).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"

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

// Must match `struct IFBGChunkUniforms` in kIFBGChunkMSL (48 bytes).
typedef struct {
    simd_float4 dst;       // the chunk's rectangle in target pixels: x0, y0, x1, y1
    simd_float4 src;       // the texels it shows: origin, then size
    simd_float2 target;    // the render target's size in pixels
    simd_float2 tex_size;  // the texture's size in texels
} IFBGChunkUniforms;

_Static_assert(sizeof(IFBGChunkUniforms) == 48, "IFBGChunkUniforms layout must match the MSL struct");

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


// What one frame shows, in upstream's integers.
typedef struct {
    double zoom, scale;
    long cameraX, cameraY;   // `camera_i`: camera.round() as i32
    long viewX, viewY;       // canvas.rs `visible_canvas_rect(camera.to_i32_round(), viewport_size, zoom)`
    long viewW, viewH;       //   ceil(output / zoom) + 2
    float targetW, targetH;  // the render target in pixels
} IFBGChunkView;

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

// One quad of a frame. It holds its texture, so a chunk evicted at the end of
// the frame that chose it is still drawn by that frame.
@interface IFBGChunkDraw : NSObject {
  @public
    id<MTLTexture> texture;
    IFBGChunkUniforms uniforms;
    uint32_t lod;
}
@end
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

// MARK: - Functions shared by the files of the module

// Small helpers that were file-static in background.m: static inline here, so they are not exported.
// Integer output size, as upstream's logical output size is integral.
static inline void IFBGPixelSize(IFBackgroundFrame f, long *logicalW, long *logicalH, NSUInteger *pxW, NSUInteger *pxH) {
    DWMetalPixelSize(f.width, f.height, f.scale, logicalW, logicalH, pxW, pxH);
}

// Upstream `import_memory` of a decoded block: the bytes as they are.
static inline id<MTLTexture> IFBGUploadBlock(id<MTLDevice> device, IFBGTiffBlock *block) {
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
static inline long IFBGDivFloor(long a, long b) {
    long q = a / b;
    return (a % b != 0 && a < 0) ? q - 1 : q;
}

// Rust's `f64::round() as i32`: half away from zero, saturating.
static inline long IFBGRoundI32(double v) {
    return (long)fmin(fmax(round(v), -2147483648.0), 2147483647.0);
}

// tile_chunks.rs `pick_lod`.
static inline uint32_t IFBGPickLOD(double zoom, uint32_t lodCount) {
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

static inline IFBGChunkView IFBGChunkViewMake(IFBackgroundFrame f) {
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
static inline BOOL IFBGSameChunkView(IFBackgroundFrame a, IFBackgroundFrame b) {
    return a.cameraX == b.cameraX && a.cameraY == b.cameraY && a.zoom == b.zoom &&
           a.width == b.width && a.height == b.height && a.scale == b.scale;
}

// The pixels an element with this area covers. `x, y` are relative to
// `camera_i`. elements.rs `tile_corner_round` takes the area to physical
// pixels and `corner_round_rect` (PixelSnapRescaleElement, anchored at the
// output's origin) rescales that by zoom; both round the two corners
// separately, so two chunks that share a canvas edge share the pixel edge.
static inline simd_float4 IFBGChunkDst(long x, long y, long w, long h, const IFBGChunkView *v) {
    double x0 = round((double)x * v->scale), y0 = round((double)y * v->scale);
    double x1 = fmax(round((double)(x + w) * v->scale), x0), y1 = fmax(round((double)(y + h) * v->scale), y0);
    double X0 = round(x0 * v->zoom), Y0 = round(y0 * v->zoom);
    double X1 = fmax(round(x1 * v->zoom), X0), Y1 = fmax(round(y1 * v->zoom), Y0);
    return simd_make_float4((float)X0, (float)Y0, (float)X1, (float)Y1);
}

static inline NSNumber *IFBGChunkKey(uint32_t lod, long cx, long cy) {
    return @(((uint64_t)lod << 56) | (((uint64_t)cx & 0xFFFFFFFull) << 28) | ((uint64_t)cy & 0xFFFFFFFull));
}

// tile_chunks.rs `evict_lru_to_budget`: least recently stamped first, until
// the cache fits. Returns how many were dropped.
static inline NSUInteger IFBGEvictLRU(NSMutableDictionary<NSNumber *, IFBGChunk *> *chunks, uint64_t *bytes, uint64_t budget) {
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
static inline NSArray<IFBGChunkDraw *> *IFBGSortDraws(NSArray<IFBGChunkDraw *> *draws) {
    return [draws sortedArrayUsingComparator:^NSComparisonResult(IFBGChunkDraw *a, IFBGChunkDraw *b) {
        return a->lod > b->lod ? NSOrderedAscending : a->lod < b->lod ? NSOrderedDescending : NSOrderedSame;
    }];
}

static inline IFBGChunk *IFBGChunkMake(uint32_t lod, long cx, long cy) {
    IFBGChunk *chunk = [IFBGChunk new];
    chunk->lod = lod;
    chunk->cx = cx;
    chunk->cy = cy;
    return chunk;
}

// Larger bodies stay external under their IFBG names, each defined once:
// IFBGDeviceResources.m
extern NSString *const kIFBGCommonMSL;

// DWBackgroundGLSLTranslation.m
BOOL IFBGReferencesUniform(NSString *src, NSString *type, NSString *name);
NSString *IFBGTranslateGLSL(NSString *source, BOOL textured, NSString **error);
NSString *IFBGCondenseDiagnostics(NSString *text);

// DWBackgroundFiles.m
NSString *IFBGReadText(NSString *path, NSString **error);
BOOL IFBGIsTIFFPath(NSString *path);
id<MTLTexture> IFBGLoadImage(id<MTLDevice> device, NSString *path, CGSize *size,
                             BOOL inherited, BOOL *hasTransparency, NSString **error);

// IFBGTileChunks.m
IFBGTileLayout *IFBGTileLayoutMake(IFBGTiffSource *source, NSString **error);

#pragma clang diagnostic pop
