// SPDX-License-Identifier: GPL-3.0-or-later
//
// Infinify compositor — frosted-glass blur behind windows (blur.rs). See
// IFCompositor.h and docs/native/app/Canvas/COMPOSITOR-NOTES.md. The cached-background
// chunk generation is described in docs/native/app/Canvas/BACKGROUND-NOTES.md, section 17.3.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "IFCompositor+Private.h"

// blur.rs constants.
static const long kIFCBlurCacheStep = 64;             // CACHE_STEP
static const unsigned kIFCBlurKeepFrames = 60;        // PAD_KEEP_FRAMES, SCRATCH_KEEP_FRAMES
static const uint8_t kIFCBlurForceDirtyFrames = 2;    // BlurCache::force_dirty_frames
static const uint8_t kIFCBlurMaskWarmupCommits = 8;   // MASK_WARMUP_COMMITS
// `1u32 << (passes + 1)` (blur_pad) is defined up to here.
static const uint32_t kIFCBlurMaxPasses = 30;

// blur.rs `quantized_extent`: grow at once, give a step back only half a step
// past the point where it would be taken again.
static long IFCQuantizedExtent(long live, long current) {
    long step = kIFCBlurCacheStep;
    long wanted = ((MAX(live, 1L) + step - 1) / step) * step;
    if (wanted > current) return wanted;
    if (live <= current - step - step / 2) return wanted;
    return current;
}

// blur.rs `blur_pad`: `((offset * (1u32 << (passes + 1)) as f32).ceil() as i32).clamp(16, 256)`.
static long IFCBlurPad(float offset, uint32_t passes) {
    long reach = IFCTrunc((double)ceilf(offset * (float)(1u << (passes + 1))));
    return MIN(MAX(reach, 16L), 256L);
}

// mod.rs `compose_frame`, the `wants_blur` block: the rectangle a window's
// frost covers, in physical pixels — the content (and the title bar above it)
// truncated and rounded up in logical pixels after the zoom, then
// `painted_rect` at the output scale. Not the content's own rectangle
// (`corner_round_rect`): the two can differ by a pixel, as upstream's do.
static IFCRectI IFCBlurScreenRect(IFCGeom g, BOOL hasSSD, long titleBarHeight, double s) {
    double zoom = g.zoom;
    IFCRectD logical;
    if (hasSSD) {
        // screen_loc = ((render_loc.x * zoom) as i32, (render_loc.y * zoom) as i32),
        // moved up by (title_bar_height as f64 * zoom) as i32
        logical.x = (double)IFCTrunc(g.r.x * zoom);
        logical.y = (double)(IFCTrunc(g.r.y * zoom) - IFCTrunc((double)titleBarHeight * zoom));
        logical.w = (double)IFCCeil(g.r.w * zoom);
        logical.h = (double)IFCCeil((g.r.h + (double)titleBarHeight) * zoom);
    } else {
        logical.x = (double)IFCTrunc(g.r.x * zoom);
        logical.y = (double)IFCTrunc(g.r.y * zoom);
        logical.w = (double)IFCCeil(g.r.w * zoom);
        logical.h = (double)IFCCeil(g.r.h * zoom);
    }
    return IFCPaintedRect(logical, s);
}

@implementation IFCompositorRenderer (Blur)

// MARK: Blur (blur.rs)

// blur.rs `render_blur` + `blur_pass`: `passes` downscale passes, then
// `passes` upscale passes, between two textures of the same extent. Each pass
// reads the top-left `alloc >> src_shift` of one and writes the top-left
// `alloc >> dst_shift` of the other; texture coordinates are normalised over
// the whole allocation. Returns the texture holding the result: `a`, after an
// even number of swaps.
//
// What a pass leaves outside the region it writes is read by the taps at the
// right and bottom edges of the next one. In `a` that is the captured
// backdrop, as upstream. In `b` upstream reads whatever `create_buffer`
// handed over — never written, undefined; here `b` is cleared to transparent
// by its first pass.
- (id<MTLTexture>)encodeKawaseOn:(id<MTLTexture>)a other:(id<MTLTexture>)b passes:(uint32_t)passes offset:(float)offset
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!a || (passes > 0 && !b)) return nil;
    long allocW = (long)a.width, allocH = (long)a.height;
    for (uint32_t n = 0; n < 2 * passes; n++) {
        BOOL downscale = n < passes;
        uint32_t i = downscale ? n : n - passes;
        // let (src_shift, dst_shift) = if downscale { (i, i + 1) } else { (passes - i, passes - i - 1) };
        uint32_t srcShift = downscale ? i : passes - i;
        uint32_t dstShift = downscale ? i + 1 : passes - i - 1;
        long srcW = MAX(allocW >> srcShift, 1L), srcH = MAX(allocH >> srcShift, 1L);
        long dstW = MAX(allocW >> dstShift, 1L), dstH = MAX(allocH >> dstShift, 1L);
        // The tap distance is a UV offset over the whole texture.
        simd_float2 halfPixel = downscale ? simd_make_float2(1.0f / (float)srcW, 1.0f / (float)srcH)
                                          : simd_make_float2(0.5f / (float)srcW, 0.5f / (float)srcH);
        float passOffset = offset / (float)(1 << srcShift);

        BOOL whole = dstW == allocW && dstH == allocH;
        MTLLoadAction load = n == 0 ? MTLLoadActionClear : (whole ? MTLLoadActionDontCare : MTLLoadActionLoad);
        if (![self beginPassOn:b width:dstW height:dstH load:load clear:MTLClearColorMake(0, 0, 0, 0) commandBuffer:commandBuffer]) return nil;
        [_encoder setFragmentSamplerState:_resources.mirrorSampler atIndex:0];
        IFCUniforms u = IFCUniformsZero();
        // src_buf = (0, 0, src_w, src_h) of a texture of `alloc`: smithay's tex_matrix.
        IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)srcW, (CGFloat)srcH), (double)allocW, (double)allocH);
        u.blur = simd_make_float4(halfPixel.x, halfPixel.y, passOffset, 0.0f);
        [self rawDraw:(downscale ? IFCPipeBlurDown : IFCPipeBlurUp) dst:IFCRectIMake(0, 0, dstW, dstH) uniforms:&u texture:a];
        [self endPass];
        id<MTLTexture> swap = a;
        a = b;
        b = swap;
    }
    return a;
}

// This encode's background, once, as a texture the backdrop passes draw from:
// the background module computes from the pixel position and cannot be
// relocated. The texture is the output's size and is kept between encodes.
- (void)ensureBackgroundCopy:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (_bgTextureTried) return;
    _bgTextureTried = YES;
    IFBackgroundProgram *background = frame.background;
    if (!background || background.kind == IFBackgroundKindNone) return;
    if (!_bgCopy || (long)_bgCopy.width != c->outW || (long)_bgCopy.height != c->outH) {
        if (_bgCopy) [_graveyard bury:_bgCopy];
        _bgCopy = [self newBlurTextureWidth:c->outW height:c->outH];
    }
    if (![self beginPassOn:_bgCopy width:c->outW height:c->outH load:MTLLoadActionClear clear:MTLClearColorMake(0, 0, 0, 0)
             commandBuffer:commandBuffer]) {
        return;
    }
    IFBackgroundFrame bg = {frame.cameraX, frame.cameraY, c->frameZoom, frame.size.width, frame.size.height, c->s, frame.time};
    BOOL drew = [background encodeFrame:bg inEncoder:_encoder];
    [self endPass];
    if (drew) _bgTexture = _bgCopy;
}

// blur.rs, the per-window capture: everything below item `k` — the
// background, the outlines and every lower element with all its chrome, and
// no frost — over opaque black, moved so that output pixel `origin` lands on
// the texture's (0, 0), and confined to `clip` (texture pixels): the part of
// it that is on the output. Returns the number of draws that reached it.
- (NSUInteger)encodeBackdropBelow:(NSUInteger)k into:(id<MTLTexture>)texture width:(long)width height:(long)height
                           origin:(IFCRectI)origin clip:(IFCRectI)clip frame:(IFCompositorFrame *)frame
                              ctx:(const IFCFrameCtx *)c commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    // dt.render_output(renderer, &mut target, 0, &relocated, [0.0, 0.0, 0.0, 1.0])
    if (![self beginPassOn:texture width:width height:height load:MTLLoadActionClear clear:MTLClearColorMake(0, 0, 0, 1)
             commandBuffer:commandBuffer]) {
        return 0;
    }
    _internal = YES;
    _originX = origin.x;
    _originY = origin.y;
    _clip = clip;
    _drawsSubmitted = 0;
    if (_bgTexture) {
        IFCUniforms u = IFCUniformsZero();
        IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)_bgTexture.width, (CGFloat)_bgTexture.height), (double)_bgTexture.width,
                     (double)_bgTexture.height);
        [self draw:IFCPipeTexture dst:IFCRectIMake(0, 0, c->outW, c->outH) uniforms:&u texture:_bgTexture
           element:nil];
    }
    [self drawOutlines:frame scale:c->s viewportW:c->viewportW viewportH:c->viewportH];
    for (NSUInteger j = 0; j < k; j++) [self drawItem:&_items[j] frame:frame ctx:c];
    NSUInteger draws = _drawsSubmitted;
    [self endPass];
    _originX = _originY = 0;
    _internal = NO;
    return draws;
}

// Whether a lower element can put a pixel into `capture` (output pixels).
// Generous: its content grown by border, shadow and title bar, with slack for
// rounding; anything animated counts.
static BOOL IFCItemMayReach(const IFCItem *item, IFCRectI capture, double s, long titleBarHeight) {
    if (item->hasXform || item->element.kind == IFCompositorElementKindSnapshot) return YES;
    IFCompositorDecoration d = item->element.decoration;
    double k = s * item->g.zoom;
    double margin = (fabs((double)d.borderWidth) + ceil(fabs((double)d.shadowRadius)) + 3.0) * k + 4.0;
    double bar = (double)MAX(titleBarHeight, 0L) * k;
    double x0 = item->g.r.x * k - margin, y0 = item->g.r.y * k - margin - bar;
    double x1 = (item->g.r.x + item->g.r.w) * k + margin, y1 = (item->g.r.y + item->g.r.h) * k + margin;
    return x0 < (double)(capture.x + capture.w) && (double)capture.x < x1 && y0 < (double)(capture.y + capture.h) && (double)capture.y < y1;
}

// blur.rs `backdrop_fingerprint` + `ViewStamp` + the geometry generation:
// everything a window's frost is computed from. The window's own content is
// left out (the frost shows its shape, not its pixels), and so is every lower
// element that cannot reach the padded capture.
- (uint64_t)frostKeyForItem:(NSUInteger)k screen:(IFCRectI)screen capture:(IFCRectI)capture pad:(long)pad passes:(uint32_t)passes
                     offset:(float)offset frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    uint64_t h = 0xcbf29ce484222325ULL;
    IFC_MIX(&h, frame.size.width);
    IFC_MIX(&h, frame.size.height);
    IFC_MIX(&h, c->s);
    IFC_MIX(&h, frame.cameraX);
    IFC_MIX(&h, frame.cameraY);
    IFC_MIX(&h, c->frameZoom);
    IFC_MIX(&h, c->outW);
    IFC_MIX(&h, c->outH);
    IFC_MIX(&h, (uintptr_t)(__bridge void *)frame.background);
    IFC_MIX(&h, c->backgroundGeneration);
    IFC_MIX(&h, c->styleHash);
    IFC_MIX(&h, c->decorationScale);
    IFCMixColor(&h, frame.placeholderColor);
    IFCompositorOutlineSettings outline = frame.outline;
    IFCMixColor(&h, outline.color);
    IFC_MIX(&h, outline.thickness);
    IFC_MIX(&h, outline.opacity);
    NSUInteger outlineCount = frame.outlineRectCount;
    const CGRect *outlineRects = [frame ifc_outlineRects];
    IFC_MIX(&h, (uint64_t)outlineCount);
    for (NSUInteger i = 0; i < outlineCount; i++) IFCMixRect(&h, outlineRects[i]);
    IFC_MIX(&h, passes);
    IFC_MIX(&h, offset);
    IFC_MIX(&h, pad);
    IFCMix(&h, &screen, sizeof screen);
    IFCMix(&h, &capture, sizeof capture);

    const IFCItem *own = &_items[k];
    [own->element ifc_mix:&h content:NO];
    IFCMix(&h, &own->scissor, sizeof own->scissor);
    IFC_MIX(&h, (uint8_t)own->hasXform);
    if (own->hasXform) IFCMix(&h, &own->xform, sizeof own->xform);
    IFC_MIX(&h, own->lifeAlpha);

    long titleBarHeight = (long)frame.chrome.titleBarHeight;
    uint64_t lower = 0;
    for (NSUInteger j = 0; j < k; j++) {
        const IFCItem *item = &_items[j];
        if (!IFCItemMayReach(item, capture, c->s, titleBarHeight)) continue;
        lower++;
        [item->element ifc_mix:&h content:YES];
        IFCMix(&h, &item->scissor, sizeof item->scissor);
        IFC_MIX(&h, (uint8_t)item->hasXform);
        if (item->hasXform) IFCMix(&h, &item->xform, sizeof item->xform);
        IFC_MIX(&h, item->lifeAlpha);
        IFC_MIX(&h, item->progress);
        IFC_MIX(&h, (uint8_t)item->alphaOnly);
    }
    IFC_MIX(&h, lower);
    return h;
}

// blur.rs `process_blur_requests` for one window: bring its frost up to date.
- (void)prepareFrostOfItem:(NSUInteger)k frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c beat:(BOOL)beat
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    const IFCItem *item = &_items[k];
    IFCompositorElement *element = item->element;
    BOOL hasSSD = element.decoration.mode == IFCompositorDecorationModeServer;
    IFCEntry *entry = [self entryFor:element.identifier];
    entry->frostSeen = 0;
    if (!entry->frostInit) {
        // BlurCache::new
        entry->frostInit = YES;
        entry->frostForceFrames = kIFCBlurForceDirtyFrames;
        entry->frostWarmup = kIFCBlurMaskWarmupCommits;
        entry->frostHasContentId = NO;
    }

    IFCRectI screen = IFCBlurScreenRect(item->g, hasSSD, (long)frame.chrome.titleBarHeight, c->s);
    // window_animation.map_or(screen_rect, |anim| anim.transform_phys_rect(screen_rect))
    if (item->hasXform) screen = IFCTransformRect(screen, item->xform);
    // "no frost: the window has no on-screen extent"
    if (screen.w <= 0 || screen.h <= 0) return;
    // BlurCache::age_pads: reset below on the encodes that recompute.
    if (entry->padA && ++entry->padsIdle > kIFCBlurKeepFrames) [self retirePadsOf:entry];

    uint32_t passes = MIN(c->effects.blurRadius, kIFCBlurMaxPasses);
    // let blur_offset = state.config.effects.blur_strength as f32 * output_scale as f32;
    float offset = (float)c->effects.blurStrength * (float)c->s;
    long pad = IFCBlurPad(offset, passes);
    // pad_extent / padded_rect: the window's rectangle grown by the blur's reach.
    long padW = screen.w + 2 * pad, padH = screen.h + 2 * pad;
    if ((NSUInteger)padW > kIFCMaxTextureSide || (NSUInteger)padH > kIFCMaxTextureSide) return;
    IFCRectI padded = IFCRectIMake(screen.x - pad, screen.y - pad, padW, padH);
    // backdrop_capture: the part of it that has backdrop behind it.
    IFCRectI clipped;
    if (!IFCRectIIntersect(padded, IFCRectIMake(0, 0, c->outW, c->outH), &clipped)) {
        // "frost left unrendered: the padded capture is entirely off the output"
        return;
    }
    BOOL direct = clipped.x == padded.x && clipped.y == padded.y && clipped.w == padded.w && clipped.h == padded.h;

    uint64_t key = [self frostKeyForItem:k screen:screen capture:clipped pad:pad passes:passes offset:offset frame:frame ctx:c];
    uint64_t contentId = 0xcbf29ce484222325ULL;
    [element ifc_mixContentIdentity:&contentId];
    // Two re-capture budgets, as upstream: composed frames for a content that
    // arrives late, the window's own new content for a transparent first one.
    BOOL painted = entry->frostWarmup > 0 && entry->frostHasContentId && entry->frostContentId != contentId;
    BOOL forced = entry->frostForceFrames > 0 || painted;
    if (entry->frostForceFrames > 0) entry->frostForceFrames--;
    BOOL dirty = !entry->frostValid || entry->frostKey != key || beat || forced;

    if (!dirty) {
        entry->frostSeen = _generation;
        return;
    }

    // The window's own content as of this mask (`mask_commits`).
    if (entry->frostHasContentId && entry->frostContentId != contentId && entry->frostWarmup > 0) entry->frostWarmup--;
    entry->frostContentId = contentId;
    entry->frostHasContentId = YES;

    [self ensureBackgroundCopy:frame ctx:c commandBuffer:commandBuffer];
    // BlurCache::ensure_pads: the padded ping-pong pair, exactly the padded
    // extent and never quantised — the mip chain and the mirror are taken from
    // the textures' own extent. Reallocated only when that extent changes.
    if (!entry->padA || !entry->padB || entry->padW != padW || entry->padH != padH) {
        [self retirePadsOf:entry];
        entry->padA = [self newBlurTextureWidth:padW height:padH];
        entry->padB = [self newBlurTextureWidth:padW height:padH];
        if (!entry->padA || !entry->padB) {
            // "frost left unrendered: the padded ping-pong pair could not be allocated"
            entry->padA = entry->padB = nil;
            return;
        }
        entry->padW = padW;
        entry->padH = padH;
    }
    entry->padsIdle = 0;
    id<MTLTexture> padA = entry->padA, padB = entry->padB;
    NSUInteger draws = 0;
    if (direct) {
        // The padded rect fits on the output: capture straight into the pad.
        draws = [self encodeBackdropBelow:k into:padA width:padW height:padH origin:padded clip:IFCRectIMake(0, 0, padW, padH)
                                    frame:frame ctx:c commandBuffer:commandBuffer];
    } else {
        // It overhangs: capture the part that has backdrop, and fill the pad
        // from it mirrored about the output boundary. Upstream captures that
        // part into a scratch texture of exactly its size (one per extent,
        // so one per frame while such a window moves) and crops it with
        // MIRRORED_REPEAT; here it is captured in place inside the second pad
        // texture and reflected by `ifc_mirror_copy` — the same texels.
        IFCRectI part = IFCRectIMake(clipped.x - padded.x, clipped.y - padded.y, clipped.w, clipped.h);
        draws = [self encodeBackdropBelow:k into:padB width:padW height:padH origin:padded clip:part frame:frame ctx:c
                            commandBuffer:commandBuffer];
        if (draws && [self beginPassOn:padA width:padW height:padH load:MTLLoadActionDontCare clear:MTLClearColorMake(0, 0, 0, 0)
                         commandBuffer:commandBuffer]) {
            IFCUniforms u = IFCUniformsZero();
            u.rect = simd_make_float4((float)part.x, (float)part.y, (float)part.w, (float)part.h);
            u.size = simd_make_float2((float)padW, (float)padH);
            [self rawDraw:IFCPipeMirrorCopy dst:IFCRectIMake(0, 0, padW, padH) uniforms:&u texture:padB];
            [self endPass];
        } else {
            draws = 0;
        }
    }
    if (!draws) {
        // "frost zeroed: nothing is drawn beneath this surface to capture":
        // the capture would be the clear colour blurred into a black slab.
        entry->frostZeroed = YES;
        entry->frostValid = YES;
        entry->frostKey = key;
        entry->frostSeen = _generation;
        return;
    }

    id<MTLTexture> blurred = [self encodeKawaseOn:padA other:padB passes:passes offset:offset commandBuffer:commandBuffer];

    // The frost and the mask: the window's extent, allocated in steps so that
    // a zoom does not reallocate them on every frame (`quantized_alloc`).
    long allocW = IFCQuantizedExtent(screen.w, entry->frostAllocW), allocH = IFCQuantizedExtent(screen.h, entry->frostAllocH);
    if (!entry->frostTexture || !entry->maskTexture || allocW != entry->frostAllocW || allocH != entry->frostAllocH) {
        if (entry->frostTexture) [_graveyard bury:entry->frostTexture];
        if (entry->maskTexture) [_graveyard bury:entry->maskTexture];
        entry->frostTexture = [self newBlurTextureWidth:allocW height:allocH];
        entry->maskTexture = [self newBlurTextureWidth:allocW height:allocH];
        BOOL allocated = entry->frostTexture && entry->maskTexture;
        entry->frostAllocW = allocated ? allocW : 0;
        entry->frostAllocH = allocated ? allocH : 0;
    }
    id<MTLTexture> mask = entry->frostTexture ? entry->maskTexture : nil;
    BOOL built = NO;
    if (blurred && entry->frostTexture && mask) {
        // Keep only the centre: the window-sized region at (pad, pad).
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit copyFromTexture:blurred sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake((NSUInteger)pad, (NSUInteger)pad, 0)
                   sourceSize:MTLSizeMake((NSUInteger)screen.w, (NSUInteger)screen.h, 1) toTexture:entry->frostTexture
             destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];

        // The mask: the window's own elements — border, content, title bar,
        // not its shadow — drawn into a window-sized texture with the window's
        // origin at (0, 0), over transparent.
        if ([self beginPassOn:mask width:screen.w height:screen.h load:MTLLoadActionClear clear:MTLClearColorMake(0, 0, 0, 0)
                commandBuffer:commandBuffer]) {
            _skipShadow = YES;
            _internal = YES;
            _originX = screen.x;
            _originY = screen.y;
            [self drawItem:item frame:frame ctx:c];
            [self endPass];
            _originX = _originY = 0;
            _internal = NO;
            _skipShadow = NO;

            // Threshold its alpha and multiply the frost by it.
            if ([self beginPassOn:entry->frostTexture width:screen.w height:screen.h load:MTLLoadActionLoad
                            clear:MTLClearColorMake(0, 0, 0, 0) commandBuffer:commandBuffer]) {
                IFCUniforms u = IFCUniformsZero();
                IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)screen.w, (CGFloat)screen.h), (double)allocW, (double)allocH);
                [self rawDraw:IFCPipeBlurMask dst:IFCRectIMake(0, 0, screen.w, screen.h) uniforms:&u texture:mask];
                [self endPass];
                built = YES;
            }
        }
    }
    if (!built) {
        entry->frostValid = NO;
        return;
    }
    entry->frostW = screen.w;
    entry->frostH = screen.h;
    entry->frostRect = screen;
    entry->frostKey = key;
    entry->frostValid = YES;
    entry->frostZeroed = NO;
    entry->frostSeen = _generation;
}

// The frosts of this encode, before its own pass opens.
- (void)prepareFrosts:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    // blur.rs `shared_refresh_due`: the cadence every blurred window follows.
    // A change of view or of the background itself is always due; a
    // background that only moves on its own is due `animate_blur_fps` times
    // a second, and never at 0.
    uint64_t view = 0xcbf29ce484222325ULL;
    IFC_MIX(&view, frame.cameraX);
    IFC_MIX(&view, frame.cameraY);
    IFC_MIX(&view, c->frameZoom);
    IFC_MIX(&view, c->outW);
    IFC_MIX(&view, c->outH);
    IFC_MIX(&view, c->s);
    IFC_MIX(&view, (uintptr_t)(__bridge void *)frame.background);
    // blur.rs `background_structure_changed`, uncapped as the view is: a chunk
    // baked, uploaded or evicted is a background element added or removed.
    IFC_MIX(&view, c->backgroundGeneration);
    BOOL due = !_hasBlurBeat || view != _blurBeatView;
    uint32_t fps = c->effects.animateBlurFPS;
    if (!due && fps > 0 && frame.background.isAnimated && frame.time != _blurBeatTime) {
        // since_refresh >= Duration::from_secs_f64(1.0 / fps). Upstream measures
        // wall time; here the host's frame times are compared, and a tenth of
        // a millisecond of slack keeps a sum of display intervals (3 x 1/60 s
        // against 1/20 s) from falling short by a rounding error.
        due = frame.time < _blurBeatTime || frame.time - _blurBeatTime >= 1.0 / (double)fps - 1e-4;
    }
    if (due) {
        _hasBlurBeat = YES;
        _blurBeatView = view;
        _blurBeatTime = frame.time;
    }

    for (NSUInteger k = 0; k < _itemCount; k++) {
        IFCompositorElement *element = _items[k].element;
        if (!element.blur || element.kind != IFCompositorElementKindWindow) continue;
        [self prepareFrostOfItem:k frame:frame ctx:c beat:due commandBuffer:commandBuffer];
    }
    // The background copy is kept while frosts keep being recomputed from it.
    if (_bgTextureTried) {
        _bgCopyIdle = 0;
    } else if (_bgCopy && ++_bgCopyIdle > kIFCBlurKeepFrames) {
        [_graveyard bury:_bgCopy];
        _bgCopy = nil;
    }
    _bgTexture = nil;
    _bgTextureTried = NO;
}

@end
