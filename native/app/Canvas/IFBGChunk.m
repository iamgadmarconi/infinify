// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: what both chunk caches share (the chunk
// records, a frame's view in upstream's integers, the pixels a chunk covers,
// LOD choice, LRU eviction and the upload of a decoded block) - see
// IFBackgroundProgram.h and BACKGROUND-NOTES.md, section 17.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/render/tile_chunks.rs
// (pick_lod, evict_lru_to_budget), src/render/elements.rs (tile_corner_round
// and corner_round_rect: the pixels a chunk covers) and src/canvas.rs
// (visible_canvas_rect); the chunk-cache section of IFBackgroundProgram+Private.h
// carries the full list.
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackgroundProgram+Private.h"

#include <math.h>

// Upstream `import_memory` of a decoded block: the bytes as they are.
id<MTLTexture> IFBGUploadBlock(id<MTLDevice> device, IFBGTiffBlock *block) {
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
long IFBGDivFloor(long a, long b) {
    long q = a / b;
    return (a % b != 0 && a < 0) ? q - 1 : q;
}

// Rust's `f64::round() as i32`: half away from zero, saturating.
static long IFBGRoundI32(double v) {
    return (long)fmin(fmax(round(v), -2147483648.0), 2147483647.0);
}

// tile_chunks.rs `pick_lod`.
uint32_t IFBGPickLOD(double zoom, uint32_t lodCount) {
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

IFBGChunkView IFBGChunkViewMake(IFBackgroundFrame f) {
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
BOOL IFBGSameChunkView(IFBackgroundFrame a, IFBackgroundFrame b) {
    return a.cameraX == b.cameraX && a.cameraY == b.cameraY && a.zoom == b.zoom &&
           a.width == b.width && a.height == b.height && a.scale == b.scale;
}

// The pixels an element with this area covers. `x, y` are relative to
// `camera_i`. elements.rs `tile_corner_round` takes the area to physical
// pixels and `corner_round_rect` (PixelSnapRescaleElement, anchored at the
// output's origin) rescales that by zoom; both round the two corners
// separately, so two chunks that share a canvas edge share the pixel edge.
simd_float4 IFBGChunkDst(long x, long y, long w, long h, const IFBGChunkView *v) {
    double x0 = round((double)x * v->scale), y0 = round((double)y * v->scale);
    double x1 = fmax(round((double)(x + w) * v->scale), x0), y1 = fmax(round((double)(y + h) * v->scale), y0);
    double X0 = round(x0 * v->zoom), Y0 = round(y0 * v->zoom);
    double X1 = fmax(round(x1 * v->zoom), X0), Y1 = fmax(round(y1 * v->zoom), Y0);
    return simd_make_float4((float)X0, (float)Y0, (float)X1, (float)Y1);
}

@implementation IFBGChunk
@end
@implementation IFBGChunkDraw
@end

NSNumber *IFBGChunkKey(uint32_t lod, long cx, long cy) {
    return @(((uint64_t)lod << 56) | (((uint64_t)cx & 0xFFFFFFFull) << 28) | ((uint64_t)cy & 0xFFFFFFFull));
}

// tile_chunks.rs `evict_lru_to_budget`: least recently stamped first, until
// the cache fits. Returns how many were dropped.
NSUInteger IFBGEvictLRU(NSMutableDictionary<NSNumber *, IFBGChunk *> *chunks, uint64_t *bytes, uint64_t budget) {
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
NSArray<IFBGChunkDraw *> *IFBGSortDraws(NSArray<IFBGChunkDraw *> *draws) {
    return [draws sortedArrayUsingComparator:^NSComparisonResult(IFBGChunkDraw *a, IFBGChunkDraw *b) {
        return a->lod > b->lod ? NSOrderedAscending : a->lod < b->lod ? NSOrderedDescending : NSOrderedSame;
    }];
}

IFBGChunk *IFBGChunkMake(uint32_t lod, long cx, long cy) {
    IFBGChunk *chunk = [IFBGChunk new];
    chunk->lod = lod;
    chunk->cx = cx;
    chunk->cy = cy;
    return chunk;
}
