// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: the chunk layout of a tiled pyramidal
// TIFF (IFBGTileLayout) and its per-output chunk cache (IFBGTileChunks) - see
// IFBackgroundProgram.h, IFBGTiffSource.h and BACKGROUND-NOTES.md, section 17.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/render/tile_chunks.rs
// (BgChunkCache: new_from_tiff, ensure_visible_loaded, drain_responses, shrink;
// derive_chunk_layout, compute_aggregations, compute_k_range,
// chunks_intersecting, visibility_query, chunk_actual_size, chunk_canvas_origin,
// chunk_render_elements). The fallback level's size limit is DriftWM v0.21.0's
// `whole_lod` (https://github.com/malbiruk/driftwm @
// df3de27b26c7998e8a460cffd8a4925cbed3a322: src/render/tile_chunks_tiff.rs),
// reached through IFBGTiffWholeLevel.
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackgroundProgram+Private.h"
#import "IFBGTiffSource.h"

#include <math.h>
#include <stdatomic.h>
#include <string.h>

// MARK: Pyramidal TIFF (tile_chunks.rs)

@implementation IFBGTileLayout
@end

// `derive_chunk_layout`, `compute_aggregations` and the choice of the fallback
// LOD in `new_from_tiff`. Returns nil and sets `*error` to upstream's message.
IFBGTileLayout *IFBGTileLayoutMake(IFBGTiffSource *source, NSString **error) {
    NSUInteger pages = MIN(source.levelCount, (NSUInteger)kIFBGMaxTileLODs);
    IFBGTileLayout *layout = [IFBGTileLayout new];
    for (NSUInteger i = 0; i < pages; i++) {
        layout->levels[i] = [source levelAtIndex:i];
        if (layout->levels[i].tileWidth != layout->levels[i].tileHeight) {
            *error = [NSString stringWithFormat:@"LOD %lu: non-square tile dims (%u, %u) not supported", (unsigned long)i,
                                                layout->levels[i].tileWidth, layout->levels[i].tileHeight];
            return nil;
        }
    }
    if (!pages) {
        *error = @"TIFF has no LOD levels";
        return nil;
    }
    layout->imageW = layout->levels[0].imageWidth;
    layout->imageH = layout->levels[0].imageHeight;
    if (layout->imageW > INT32_MAX || layout->imageH > INT32_MAX) {
        *error = @"dimensions: the image is too large";
        return nil;
    }
    // The canvas span of one TIFF tile at each LOD. The pyramid is cut at the
    // first step that is not exactly 2x: vips can leave the last page a pixel off.
    long raw[kIFBGMaxTileLODs];
    NSUInteger usable = pages;
    for (NSUInteger i = 0; i < pages; i++) {
        double scale = (double)layout->imageW / (double)layout->levels[i].imageWidth;
        double span = round((double)layout->levels[i].tileWidth * scale);
        if (!(span > 0)) {
            *error = [NSString stringWithFormat:@"LOD %lu: derived canvas chunk size %ld <= 0", (unsigned long)i, (long)span];
            return nil;
        }
        raw[i] = (long)fmin(span, 2147483647.0);
    }
    for (NSUInteger i = 1; i < pages; i++) {
        if (raw[i] != 2 * raw[i - 1]) {
            NSLog(@"background: chunked tile-bg: LOD %lu raw canvas chunk size %ld != 2× LOD %lu (%ld); truncating pyramid to %lu usable LOD(s)",
                  (unsigned long)i, raw[i], (unsigned long)(i - 1), raw[i - 1], (unsigned long)i);
            usable = i;
            break;
        }
    }
    for (NSUInteger i = 0; i < usable; i++) {
        long target = i == 0 ? kIFBGLOD0TargetChunkCanvas : kIFBGTargetChunkCanvas;
        layout->aggregations[i] = (raw[i] > 0 && raw[i] < target) ? (uint32_t)MAX(target / raw[i], 1L) : 1;
        layout->sizes[i] = raw[i] * (long)layout->aggregations[i];
    }
    // The fallback plane is the finest LOD that fits FALLBACK_MAX_DIM, else the
    // coarsest, which has to be small enough to hold whole (v0.21.0 `whole_lod`:
    // past 16384 px a side it is an error and not an allocation that can abort);
    // the LODs past it are not used.
    NSUInteger fallback = IFBGTiffWholeLevel(layout->levels, usable, kIFBGFallbackMaxDim, error);
    if (fallback == NSNotFound) return nil;
    layout->lodCount = (uint32_t)fallback + 1;
    // `Point::from((-(image_dims.0 as i32) / 2, -(image_dims.1 as i32) / 2))`
    layout->positionX = -layout->imageW / 2;
    layout->positionY = -layout->imageH / 2;
    return layout;
}

// The texels of chunk `(cx, cy)` at `lod`: `read_block`'s cropped block.
static void IFBGTileChunkTexels(const IFBGTileLayout *l, uint32_t lod, long cx, long cy, long *w, long *h) {
    IFBGTiffLevel level = l->levels[lod];
    long n = l->aggregations[lod], tile = level.tileWidth;
    long across = ((long)level.imageWidth + tile - 1) / tile, down = ((long)level.imageHeight + tile - 1) / tile;
    long endX = MIN(cx * n + n, across), endY = MIN(cy * n + n, down);
    *w = MAX(MIN(endX * tile, (long)level.imageWidth) - cx * n * tile, 0L);
    *h = MAX(MIN(endY * tile, (long)level.imageHeight) - cy * n * tile, 0L);
}

// `visibility_query`: every chunk `(cx, cy)` of every image instance
// `(kx, ky)` the visible rectangle touches (`compute_k_range`,
// `chunks_intersecting`). The image repeats with its own period; a chunk past
// its right or bottom edge is never listed. A NO result stops enumeration once
// a caller has exhausted its budget; subsequent cells would do no work.
static void IFBGVisibilityQuery(const IFBGChunkView *v, const IFBGTileLayout *l, long chunkSize,
                                BOOL (^each)(long cx, long cy, long kx, long ky)) {
    if (chunkSize <= 0 || v->viewW <= 0 || v->viewH <= 0 || l->imageW <= 0 || l->imageH <= 0) return;
    long kx0 = IFBGDivFloor(v->viewX - l->positionX, l->imageW), kx1 = IFBGDivFloor(v->viewX + v->viewW - 1 - l->positionX, l->imageW);
    long ky0 = IFBGDivFloor(v->viewY - l->positionY, l->imageH), ky1 = IFBGDivFloor(v->viewY + v->viewH - 1 - l->positionY, l->imageH);
    for (long ky = ky0; ky <= ky1; ky++) {
        for (long kx = kx0; kx <= kx1; kx++) {
            long relX = v->viewX - (l->positionX + kx * l->imageW), relY = v->viewY - (l->positionY + ky * l->imageH);
            long minX = MAX(relX, 0L), minY = MAX(relY, 0L);
            long maxX = MIN(relX + v->viewW, l->imageW), maxY = MIN(relY + v->viewH, l->imageH);
            if (minX >= maxX || minY >= maxY) continue;
            for (long cy = minY / chunkSize; cy <= (maxY - 1) / chunkSize; cy++) {
                for (long cx = minX / chunkSize; cx <= (maxX - 1) / chunkSize; cx++) {
                    if (!each(cx, cy, kx, ky)) return;
                }
            }
        }
    }
}

@implementation IFBGTileChunks {
    id<MTLDevice> _device;
    IFBGTileLayout *_layout;
    IFBGTileWorkerPool *_pool;
    uint64_t _budget;  // `vram_budget_bytes`
    NSMutableDictionary<NSNumber *, IFBGChunk *> *_chunks;
    NSMutableSet<NSNumber *> *_inFlight;  // `in_flight`
    NSMutableSet<NSNumber *> *_failed;    // `failed`
    uint64_t _frameCounter;
    BOOL _shrunk;
    atomic_bool _wakePosted;
    BOOL _degraded;  // the last frame's working set exceeded the budget
    BOOL _hasPlan;
    IFBackgroundFrame _planFrame;
    NSArray<IFBGChunkDraw *> *_plan;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                        source:(IFBGTiffSource *)source
                        layout:(IFBGTileLayout *)layout
                        budget:(uint64_t)budget {
    if (!(self = [super init])) return nil;
    _device = device;
    _layout = layout;
    _budget = budget;
    _chunks = [NSMutableDictionary dictionary];
    _inFlight = [NSMutableSet set];
    _failed = [NSMutableSet set];
    atomic_init(&_wakePosted, false);
    // The pool must not keep its cache alive: the decodes outlive nothing.
    __weak IFBGTileChunks *weak = self;
    _pool = [[IFBGTileWorkerPool alloc] initWithSource:source wake:^{ [weak wake]; }];
    return self;
}

- (void)dealloc {
    [_pool shutdown];
}

// `loop_signal.wakeup()`, from a decoder's thread: one message to the main
// thread however many chunks finish before it is delivered.
- (void)wake {
    if (atomic_exchange(&_wakePosted, true)) return;
    __weak IFBGTileChunks *weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        IFBGTileChunks *cache = weak;
        if (!cache) return;
        atomic_store(&cache->_wakePosted, false);
        // What arrived may change a frame already encoded for this instant.
        cache->_hasPlan = NO;
        dispatch_block_t handler = cache.readyHandler;
        if (handler) handler();
    });
}

// `has_pending_loads`: decodes asked for and not yet uploaded or failed.
- (NSUInteger)pendingCount {
    return _inFlight.count;
}

// `shrink`: every per-tile chunk goes, every request with it, and what a
// decoder still delivers is discarded. The failed set stays.
- (void)shrink {
    while ([_pool tryReceive]) {
    }
    if (_shrunk) return;
    _shrunk = YES;
    _hasPlan = NO;
    _plan = nil;
    _generation += _chunks.count;
    [_chunks removeAllObjects];
    _bytes = 0;
    [_pool drainPending];
    [_inFlight removeAllObjects];
}

// `drain_responses`: at most `budget` decoded blocks become textures.
- (void)drainResponses:(NSUInteger)budget frame:(uint64_t)frame {
    NSUInteger uploaded = 0;
    while (uploaded < budget) {
        IFBGTileResponse *response = [_pool tryReceive];
        if (!response) break;
        NSNumber *key = IFBGChunkKey(response.level, (long)response.cx, (long)response.cy);
        // A shrink dropped the request this answers.
        if (![_inFlight containsObject:key]) continue;
        [_inFlight removeObject:key];
        IFBGTiffBlock *block = response.block;
        if (!block) {
            NSLog(@"background: chunked tile (LOD %u, %u,%u) decode: %@", response.level, response.cx, response.cy, response.error);
            [_failed addObject:key];
            continue;
        }
        id<MTLTexture> texture = IFBGUploadBlock(_device, block);
        if (!texture) {
            NSLog(@"background: chunked tile (LOD %u, %u,%u) import_memory failed", response.level, response.cx, response.cy);
            [_failed addObject:key];
            continue;
        }
        IFBGChunk *chunk = IFBGChunkMake(response.level, (long)response.cx, (long)response.cy);
        chunk->texture = texture;
        chunk->bytes = (uint64_t)block.width * (uint64_t)block.height * 4;
        chunk->touched = frame;
        _chunks[key] = chunk;
        _bytes += chunk->bytes;
        _generation++;
        uploaded++;
    }
}

- (NSArray<IFBGChunkDraw *> *)drawsForFrame:(IFBackgroundFrame)f {
    if (_hasPlan && (memcmp(&f, &_planFrame, sizeof f) == 0 ||
                     (!_inFlight.count && IFBGSameChunkView(f, _planFrame)))) return _plan;
    _hasPlan = NO;
    _plan = nil;
    IFBGChunkView view = IFBGChunkViewMake(f);
    const IFBGChunkView *v = &view;
    IFBGTileLayout *l = _layout;

    // ensure_visible_loaded
    _shrunk = NO;
    uint64_t frame = ++_frameCounter;
    [self drainResponses:kIFBGUploadBudget frame:frame];
    uint32_t coarsest = l->lodCount - 1, target = IFBGPickLOD(v->zoom, l->lodCount);

    // Every LOD finer than the fallback plane, coarse first: the chunks the
    // view touches are stamped when cached, so that eviction cannot take the
    // coarse cover from under a fine LOD that is still loading, and asked of
    // the decoders when not. Upstream does the two in separate passes over the
    // same chunks.
    //
    // Not upstream: the chunks are counted against the budget as they are
    // met, and from the first one that no longer fits nothing is stamped or
    // asked for. Upstream asks for all of them; when they exceed the budget
    // every frame evicts chunks the next frame asks for again, and
    // `has_pending_loads` never clears (BACKGROUND-NOTES.md, section 17).
    __block uint64_t wanted = 0;
    __block BOOL over = NO;
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (uint32_t lod = coarsest; !over && lod-- > target;) {
        uint32_t aggregation = l->aggregations[lod];
        IFBGVisibilityQuery(v, l, l->sizes[lod], ^BOOL(long cx, long cy, long kx, long ky) {
            (void)kx;
            (void)ky;
            NSNumber *key = IFBGChunkKey(lod, cx, cy);
            if ([seen containsObject:key]) return YES;
            [seen addObject:key];
            long texelsW, texelsH;
            IFBGTileChunkTexels(l, lod, cx, cy, &texelsW, &texelsH);
            uint64_t bytes = (uint64_t)texelsW * (uint64_t)texelsH * 4;
            if (wanted + bytes > self->_budget) {
                over = YES;
                return NO;
            }
            wanted += bytes;
            IFBGChunk *chunk = self->_chunks[key];
            if (chunk) {
                chunk->touched = frame;
                return YES;
            }
            if ([self->_inFlight containsObject:key] || [self->_failed containsObject:key]) return YES;
            [self->_inFlight addObject:key];
            [self->_pool enqueueLevel:lod cx:(uint32_t)cx cy:(uint32_t)cy aggregation:aggregation];
            return YES;
        });
    }
    if (over != _degraded) {
        _degraded = over;
        if (over) {
            NSLog(@"chunked tile-bg: cache_budget_mb too low for this view (%llu MB budget); keeping the coarser levels that fit. "
                   "Raise cache_budget_mb for sharp detail.", _budget / (1024 * 1024));
        }
    }
    NSUInteger evicted = IFBGEvictLRU(_chunks, &_bytes, _budget);
    _generation += evicted;

    // chunk_render_elements: for each visible target cell of each image
    // instance, the finest cached chunk that covers it.
    NSMutableDictionary<NSString *, IFBGChunkDraw *> *chosen = [NSMutableDictionary dictionary];
    if (target < coarsest) {
        long targetSize = l->sizes[target];
        IFBGVisibilityQuery(v, l, targetSize, ^BOOL(long cxT, long cyT, long kx, long ky) {
            // (kx, ky) places the element; the coarser chunk is looked up on
            // the image's own grid.
            long canvasX = cxT * targetSize, canvasY = cyT * targetSize;
            for (uint32_t lod = target; lod < coarsest; lod++) {
                long size = l->sizes[lod], cx = IFBGDivFloor(canvasX, size), cy = IFBGDivFloor(canvasY, size);
                IFBGChunk *chunk = self->_chunks[IFBGChunkKey(lod, cx, cy)];
                if (!chunk) continue;
                NSString *key = [NSString stringWithFormat:@"%u/%ld/%ld/%ld/%ld", lod, cx, cy, kx, ky];
                if (chosen[key]) return YES;
                // `chunk_actual_size`: a chunk at the image's right or bottom
                // edge is as wide as what is left of the image.
                long w = MIN(MAX(l->imageW - cx * size, 0L), size), h = MIN(MAX(l->imageH - cy * size, 0L), size);
                // `chunk_canvas_origin`
                long originX = l->positionX + kx * l->imageW + cx * size, originY = l->positionY + ky * l->imageH + cy * size;
                IFBGChunkDraw *draw = [IFBGChunkDraw new];
                draw->texture = chunk->texture;
                draw->lod = lod;
                draw->uniforms.dst = IFBGChunkDst(originX - v->cameraX, originY - v->cameraY, w, h, v);
                // The whole texture, whose size in texels is the texture's own.
                draw->uniforms.src = simd_make_float4(0, 0, (float)chunk->texture.width, (float)chunk->texture.height);
                draw->uniforms.target = simd_make_float2(v->targetW, v->targetH);
                draw->uniforms.tex_size = simd_make_float2((float)chunk->texture.width, (float)chunk->texture.height);
                chosen[key] = draw;
                return YES;
            }
            return YES;
        });
    }
    _plan = IFBGSortDraws(chosen.allValues);
    _planFrame = f;
    _hasPlan = YES;
    return _plan;
}
@end
