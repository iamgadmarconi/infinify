// SPDX-License-Identifier: GPL-3.0-or-later
// Infinify canvas background renderer: the baked-shader chunk cache
// (`cache_shader`) of one output - see IFBackground.h and
// docs/native/app/Canvas/BACKGROUND-NOTES.md, section 17.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/render/shader_chunks.rs
// (ShaderChunkCache: apron_dims, interior_src, bake_chunk, render_elements,
// shrink, visible_chunks).
// Split from native/desktop/background.m at 37b27b1.

#import "IFBackground+Private.h"

#include <math.h>
#include <string.h>

// MARK: Baked shader (shader_chunks.rs)

// shader_chunks.rs `apron_dims`: the padded canvas span a chunk's bake renders,
// the square texture it lands in, and the border's width in canvas units.
static void IFBGApronDims(long chunkSize, long bakePx, long *areaCanvas, long *fboTexels, long *apronCanvas) {
    double scale = (double)bakePx / (double)chunkSize;
    long apron = MAX((long)ceil((double)kIFBGApronTexels / scale), 1L);
    long area = chunkSize + 2 * apron;
    *apronCanvas = apron;
    *areaCanvas = area;
    *fboTexels = (long)fmax(round((double)area * scale), 1.0);
}

@implementation IFBGShaderChunks {
    IFBGDeviceResources *_resources;
    id<MTLRenderPipelineState> _shader;
    long _bakePx;         // `bake_px`
    uint64_t _budget;     // `vram_budget_bytes`
    NSMutableDictionary<NSNumber *, IFBGChunk *> *_chunks;
    uint64_t _frameCounter;
    BOOL _hasLastTarget;
    uint32_t _lastTarget;  // `last_target_lod`
    BOOL _shrunk;
    BOOL _broken;          // a bake failed on the GPU: this cache draws nothing more
    BOOL _coverTooLarge;   // the last frame's coarse cover exceeded the budget by itself
    BOOL _degraded;        // `degraded`
    BOOL _hasPlan;
    BOOL _planSettled;
    IFBackgroundFrame _planFrame;
    NSArray<IFBGChunkDraw *> *_plan;
}

- (instancetype)initWithResources:(IFBGDeviceResources *)resources
                           shader:(id<MTLRenderPipelineState>)shader
                            scale:(double)scale
                           budget:(uint64_t)budget {
    if (!(self = [super init])) return nil;
    _resources = resources;
    _shader = shader;
    _scale = scale;
    // `((BASE_CHUNK_CANVAS as f64) * output_scale).round().max(1.0) as i32`
    _bakePx = (long)fmin(fmax(round((double)kIFBGBaseChunkCanvas * scale), 1.0), 2147483647.0);
    _budget = budget;
    _chunks = [NSMutableDictionary dictionary];
    return self;
}

- (uint64_t)chunkBytes:(long)chunkSize {
    long area, fbo, apron;
    IFBGApronDims(chunkSize, _bakePx, &area, &fbo, &apron);
    return (uint64_t)fbo * (uint64_t)fbo * 4;
}

// `shrink`: the sharp bakes go, the coarsest cover stays as the floor the next
// canvas frame refines from.
- (void)shrink {
    if (_shrunk) return;
    _shrunk = YES;
    _hasPlan = NO;
    _plan = nil;
    uint32_t coarsest = kIFBGShaderLODs - 1;
    _bytes = 0;
    for (NSNumber *key in _chunks.allKeys) {
        IFBGChunk *chunk = _chunks[key];
        if (chunk->lod == coarsest) {
            _bytes += chunk->bytes;  // `retain_lod_meta`: recounted, not zeroed
        } else {
            [_chunks removeObjectForKey:key];
            _generation++;
        }
    }
    _pendingCount = 0;
}

// `bake_chunk`, for every chunk this frame bakes, in one command buffer of the
// module's own queue that is complete before the frame samples the textures.
// The shader runs once over the chunk's canvas span plus its apron, with
// `size` that padded span and `u_camera` its top-left corner, through the
// same pipeline and uniform block as a live frame. A chunk whose texture
// cannot be made is left uncached.
- (void)bake:(NSArray<IFBGChunk *> *)wanted frame:(uint64_t)frame {
    if (!wanted.count) return;
    id<MTLCommandBuffer> commandBuffer = [_resources.queue commandBuffer];
    if (!commandBuffer) return;
    NSMutableArray<IFBGChunk *> *baked = [NSMutableArray array];
    for (IFBGChunk *chunk in wanted) {
        long chunkSize = kIFBGBaseChunkCanvas << chunk->lod, area, fbo, apron;
        IFBGApronDims(chunkSize, _bakePx, &area, &fbo, &apron);
        id<MTLTexture> texture = nil;
        if (fbo <= (long)kIFBGMaxTextureSide) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:(NSUInteger)fbo
                                                                                         height:(NSUInteger)fbo
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            texture = [_resources.device newTextureWithDescriptor:td];
        }
        if (!texture) {
            NSLog(@"background: shader-bake (LOD %u, %ld,%ld) create_buffer failed", chunk->lod, chunk->cx, chunk->cy);
            continue;
        }
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) continue;
        IFBGUniforms u;
        memset(&u, 0, sizeof u);
        // `Uniform::new("u_camera", ((origin.x - apron_canvas) as f32, (origin.y - apron_canvas) as f32))`
        u.camera = simd_make_float2((float)(chunk->cx * chunkSize - apron), (float)(chunk->cy * chunkSize - apron));
        // The PixelShaderElement's area is the padded span, and its geometry at
        // `bake_px / chunk_size` is the whole texture.
        u.size = simd_make_float2((float)area, (float)area);
        u.dest_px = simd_make_float2((float)fbo, (float)fbo);
        u.src_size = simd_make_float2(1, 1);
        u.time = 0.0f;  // `Uniform::new("u_time", 0.0f32)`
        u.zoom = 1.0f;  // `Uniform::new("u_zoom", 1.0f32)`
        u.alpha = 1.0f;
        u.opaque = 1.0f;  // a baked shader is never `transparent_shader`
        [encoder setRenderPipelineState:_shader];
        [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
        [encoder setFragmentTexture:_resources.placeholderTexture atIndex:0];
        [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        chunk->texture = texture;
        chunk->bytes = (uint64_t)fbo * (uint64_t)fbo * 4;
        chunk->touched = frame;
        [baked addObject:chunk];
    }
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        NSLog(@"background: shader-bake render_output failed: %@", commandBuffer.error.localizedDescription);
        _broken = YES;
        return;
    }
    for (IFBGChunk *chunk in baked) {
        _chunks[IFBGChunkKey(chunk->lod, chunk->cx, chunk->cy)] = chunk;
        _bytes += chunk->bytes;
        _generation++;
    }
}

- (NSArray<IFBGChunkDraw *> *)drawsForFrame:(IFBackgroundFrame)f {
    if (_broken) return nil;
    if (_hasPlan && (memcmp(&f, &_planFrame, sizeof f) == 0 ||
                     (_planSettled && IFBGSameChunkView(f, _planFrame)))) return _plan;
    _hasPlan = NO;
    _plan = nil;
    IFBGChunkView v = IFBGChunkViewMake(f);
    _shrunk = NO;
    uint64_t frame = ++_frameCounter;
    uint32_t target = IFBGPickLOD(v.zoom, kIFBGShaderLODs), coarsest = kIFBGShaderLODs - 1;
    NSMutableArray<IFBGChunk *> *bakes = [NSMutableArray array];

    // Resident coarse cover: baked unbudgeted, once, and stamped every frame.
    // `visible_chunks(viewport, size)`: the cells the visible rectangle touches.
    long coverSize = kIFBGBaseChunkCanvas << coarsest;
    long coverX0 = IFBGDivFloor(v.viewX, coverSize), coverX1 = IFBGDivFloor(v.viewX + v.viewW - 1, coverSize);
    long coverY0 = IFBGDivFloor(v.viewY, coverSize), coverY1 = IFBGDivFloor(v.viewY + v.viewH - 1, coverSize);
    // Not upstream: a cover that does not fit the budget by itself is not baked.
    // Upstream bakes it for every frame it draws and evicts it again when the
    // frame ends, however many cells a far zoom-out makes it; here such a frame
    // is the live shader's (docs/native/app/Canvas/BACKGROUND-NOTES.md, section 17).
    uint64_t coverBytes = (uint64_t)((coverX1 - coverX0 + 1) * (coverY1 - coverY0 + 1)) * [self chunkBytes:coverSize];
    if (coverBytes > _budget) {
        if (!_coverTooLarge) {
            NSLog(@"shader-bake: cache_budget_mb too low for this view's coarse cover (%llu MB > %llu MB budget); rendering the shader live. "
                   "Raise cache_budget_mb to bake it.", coverBytes / (1024 * 1024), _budget / (1024 * 1024));
        }
        _coverTooLarge = YES;
        _pendingCount = 0;
        return nil;
    }
    _coverTooLarge = NO;
    for (long cy = coverY0; cy <= coverY1; cy++) {
        for (long cx = coverX0; cx <= coverX1; cx++) {
            IFBGChunk *chunk = _chunks[IFBGChunkKey(coarsest, cx, cy)];
            if (chunk) {
                chunk->touched = frame;
            } else {
                [bakes addObject:IFBGChunkMake(coarsest, cx, cy)];
            }
        }
    }

    long targetSize = kIFBGBaseChunkCanvas << target;
    long x0 = IFBGDivFloor(v.viewX, targetSize), x1 = IFBGDivFloor(v.viewX + v.viewW - 1, targetSize);
    long y0 = IFBGDivFloor(v.viewY, targetSize), y1 = IFBGDivFloor(v.viewY + v.viewH - 1, targetSize);

    // Graceful degrade: when cover and sharp working set cannot both fit the
    // budget, the sharp chunks are not baked and the cover alone is shown.
    uint64_t workingSet = (uint64_t)((coverX1 - coverX0 + 1) * (coverY1 - coverY0 + 1)) * [self chunkBytes:coverSize] +
                          (uint64_t)((x1 - x0 + 1) * (y1 - y0 + 1)) * [self chunkBytes:targetSize];
    BOOL degraded = workingSet > _budget;
    if (degraded != _degraded) {
        _degraded = degraded;
        if (degraded) {
            NSLog(@"shader-bake: cache_budget_mb too low for this view (%llu MB working set > %llu MB budget); "
                   "showing coarse cover only. Raise cache_budget_mb for sharp detail.",
                  workingSet / (1024 * 1024), _budget / (1024 * 1024));
        }
    }

    // Budgeted fine refine at the target LOD, with the larger one-shot budget
    // on the frame the LOD changes.
    BOOL lodChanged = !_hasLastTarget || _lastTarget != target;
    NSUInteger budget = lodChanged ? kIFBGLODSwitchBakeBudget : kIFBGBakeBudget, baked = 0;
    _pendingCount = 0;
    if (target != coarsest && !degraded) {
        for (long cy = y0; cy <= y1; cy++) {
            for (long cx = x0; cx <= x1; cx++) {
                IFBGChunk *chunk = _chunks[IFBGChunkKey(target, cx, cy)];
                if (chunk) {
                    chunk->touched = frame;
                } else if (baked < budget) {
                    [bakes addObject:IFBGChunkMake(target, cx, cy)];
                    baked++;
                } else {
                    _pendingCount++;
                }
            }
        }
    }
    if (!degraded) {
        _lastTarget = target;
        _hasLastTarget = YES;
    }
    [self bake:bakes frame:frame];
    if (_broken) {
        _pendingCount = 0;
        return nil;
    }

    // Resolve coarse-to-fine: for each visible target cell the finest cached
    // chunk that covers it, stamped so that it survives this frame's eviction.
    NSMutableDictionary<NSNumber *, IFBGChunk *> *chosen = [NSMutableDictionary dictionary];
    BOOL covered = YES;
    for (long cy = y0; cy <= y1; cy++) {
        for (long cx = x0; cx <= x1; cx++) {
            long canvasX = cx * targetSize, canvasY = cy * targetSize;
            BOOL found = NO;
            for (uint32_t lod = target; lod <= coarsest && !found; lod++) {
                long size = kIFBGBaseChunkCanvas << lod;
                NSNumber *key = IFBGChunkKey(lod, IFBGDivFloor(canvasX, size), IFBGDivFloor(canvasY, size));
                IFBGChunk *chunk = _chunks[key];
                if (!chunk) continue;
                chunk->touched = frame;
                chosen[key] = chunk;
                found = YES;
            }
            covered = covered && found;
        }
    }
    if (!covered) {
        _pendingCount = 0;
        return nil;
    }

    NSMutableArray<IFBGChunkDraw *> *draws = [NSMutableArray arrayWithCapacity:chosen.count];
    for (IFBGChunk *chunk in chosen.allValues) {
        long chunkSize = kIFBGBaseChunkCanvas << chunk->lod, area, fbo, apron;
        IFBGApronDims(chunkSize, _bakePx, &area, &fbo, &apron);
        // `interior_src`: the chunk's own span inside its apron, in texels.
        double texelsPerCanvas = (double)fbo / (double)area;
        IFBGChunkDraw *draw = [IFBGChunkDraw new];
        draw->texture = chunk->texture;
        draw->lod = chunk->lod;
        draw->uniforms.dst = IFBGChunkDst(chunk->cx * chunkSize - v.cameraX, chunk->cy * chunkSize - v.cameraY, chunkSize, chunkSize, &v);
        draw->uniforms.src = simd_make_float4((float)((double)apron * texelsPerCanvas), (float)((double)apron * texelsPerCanvas),
                                              (float)((double)chunkSize * texelsPerCanvas), (float)((double)chunkSize * texelsPerCanvas));
        draw->uniforms.target = simd_make_float2(v.targetW, v.targetH);
        draw->uniforms.tex_size = simd_make_float2((float)fbo, (float)fbo);
        [draws addObject:draw];
    }

    // Evict last, so that the chunks chosen for this frame are protected.
    NSUInteger evicted = IFBGEvictLRU(_chunks, &_bytes, _budget);
    _generation += evicted;
    _plan = IFBGSortDraws(draws);
    _planFrame = f;
    _hasPlan = YES;
    // A failed texture allocation can leave a useful coarse plan despite a
    // bake attempt. Retry that attempt on a later frame instead of treating
    // it as settled merely because no allowance-limited bakes remain.
    _planSettled = bakes.count == 0 && _pendingCount == 0;
    return _plan;
}
@end
