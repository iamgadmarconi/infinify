// SPDX-License-Identifier: GPL-3.0-or-later
//
// Infinify compositor — the renderer's element drawing (windows, stand-ins,
// snapshots, chrome, outlines, error bar) and its render passes. See
// IFCompositor.h and docs/native/app/Canvas/COMPOSITOR-NOTES.md.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "IFCompositor+Private.h"

typedef NS_OPTIONS(NSUInteger, IFCChromePart) {
    IFCChromeShadow = 1 << 0,
    IFCChromeBorder = 1 << 1,
};

// shaders.rs `outer_corner_radius`.
static inline float IFCOuterCornerRadius(float inner, float borderWidth) {
    return inner > 0.0f ? inner + borderWidth : 0.0f;
}

// shaders.rs `border_area_for` + `border_uniforms_precise` + the element
// geometry `RescaleRenderElement<PixelShaderElement>` reports.
static BOOL IFCBorderGeometry(IFCRectD inner, long borderWidthLogical, float innerRadiusLogical, double s, double zoom,
                              IFCRectI *dst, IFCRectI *hole, IFCUniforms *u) {
    if (borderWidthLogical <= 0) return NO;
    double totalScale = s * zoom;
    // border_area_for(inner_logical, border_width_logical, output_scale.x * zoom)
    long innerX = IFCRound(inner.x), innerY = IFCRound(inner.y);
    long innerW = IFCRound(inner.w), innerH = IFCRound(inner.h);
    float borderWPhys = (float)fmax(round((double)borderWidthLogical * totalScale), 1.0);
    long pad = IFCCeil(((double)borderWPhys + 1.0) / totalScale);
    IFCRectI area = IFCRectIMake(innerX - pad, innerY - pad, innerW + 2 * pad, innerH + 2 * pad);

    // push_border_element
    IFCRectI innerPreZoom = IFCPaintedRect(inner, s);
    float innerRPhys = innerRadiusLogical * (float)s * (float)zoom;

    // border_uniforms_precise
    IFCRectI innerPost = IFCCornerRound(innerPreZoom, zoom);
    IFCRectI borderPre = IFCScaleRound(area, s);
    IFCRectI borderPost = IFCScaleRound(borderPre, zoom);
    double physW = (double)MAX(borderPost.w, 1L), physH = (double)MAX(borderPost.h, 1L);
    double logicalW = (double)MAX(area.w, 1L), logicalH = (double)MAX(area.h, 1L);
    double px = physW / logicalW, py = physH / logicalH;
    double ix = (double)(innerPost.x - borderPost.x) / px;
    double iy = (double)(innerPost.y - borderPost.y) / py;
    double iw = (double)innerPost.w / px;
    double ih = (double)innerPost.h / py;
    double innerRLogical = (double)innerRPhys / px;
    double borderWLogical = (double)borderWPhys / px;

    u->rect = simd_make_float4((float)ix, (float)iy, (float)iw, (float)ih);
    u->inner_radius = (float)innerRLogical;
    u->border_width = (float)borderWLogical;
    u->outer_radius = IFCOuterCornerRadius((float)innerRLogical, (float)borderWLogical);
    u->aa_scale = (float)px;
    // PixelShaderElement: `size` is the element's logical area.
    u->size = simd_make_float2((float)area.w, (float)area.h);
    *dst = borderPost;
    // Not upstream: where the stroke's coverage is exactly 0. `a_inner` is 0
    // from half a pixel inside the inner rounded rect; a pixel that is a whole
    // pixel inside its straight edges and clear of its corner squares is there.
    long inset = IFCCeil((double)innerRPhys) + 1;
    *hole = IFCRectIMake(innerPost.x + inset, innerPost.y + inset, innerPost.w - 2 * inset, innerPost.h - 2 * inset);
    return YES;
}

// shaders.rs `shadow_area_for` + `shadow_uniforms_precise`.
static void IFCShadowGeometry(IFCRectD body, float cornerRadiusLogical, float shadowRadius, double s, double zoom,
                              IFCRectI *dst, IFCRectI *hole, IFCUniforms *u) {
    // shadow_area_for
    long pad = IFCCeil((double)ceilf(shadowRadius));
    long bodyX = IFCRound(body.x), bodyY = IFCRound(body.y);
    long bodyW = IFCRound(body.w), bodyH = IFCRound(body.h);
    IFCRectI area = IFCRectIMake(bodyX - pad, bodyY - pad, bodyW + 2 * pad, bodyH + 2 * pad);

    // push_shadow_element
    IFCRectI bodyPreZoom = IFCPaintedRect(body, s);
    float cornerRPhys = cornerRadiusLogical * (float)s * (float)zoom;

    // shadow_uniforms_precise
    IFCRectI bodyPost = IFCCornerRound(bodyPreZoom, zoom);
    IFCRectI shadowPre = IFCScaleRound(area, s);
    IFCRectI shadowPost = IFCScaleRound(shadowPre, zoom);
    double physW = (double)MAX(shadowPost.w, 1L), physH = (double)MAX(shadowPost.h, 1L);
    double logicalW = (double)MAX(area.w, 1L), logicalH = (double)MAX(area.h, 1L);
    double px = physW / logicalW, py = physH / logicalH;
    double holeX = (double)(bodyPost.x - shadowPost.x) / px;
    double holeY = (double)(bodyPost.y - shadowPost.y) / py;
    double holeW = (double)bodyPost.w / px;
    double holeH = (double)bodyPost.h / py;
    double cornerLogical = (double)cornerRPhys / px;

    u->rect = simd_make_float4((float)holeX, (float)holeY, (float)holeW, (float)holeH);
    u->radius = shadowRadius;
    u->shadow_corner = (float)cornerLogical;
    u->size = simd_make_float2((float)area.w, (float)area.h);
    *dst = shadowPost;
    // Not upstream: where `outside` (step(0, dist)) is exactly 0 — inside the
    // body's rounded rect, here taken a whole pixel in from its straight edges
    // and clear of its corner squares.
    long inset = IFCCeil((double)cornerRPhys) + 1;
    *hole = IFCRectIMake(bodyPost.x + inset, bodyPost.y + inset, bodyPost.w - 2 * inset, bodyPost.h - 2 * inset);
}

// mod.rs `push_corner_clipped_elements` + elements.rs
// `RoundedCornerElement::compute_uniforms`. `element` is the surface element's
// pre-zoom physical rectangle, `geometry` the window geometry in pre-zoom
// logical coordinates, `source` the sampled sub-rect of a `bufW` x `bufH` buffer.
static void IFCCornerClipUniforms(IFCRectI element, IFCRectD geometry, const float radii[4], double s, double zoom,
                                  double bufW, double bufH, CGRect source, IFCUniforms *u) {
    // push_corner_clipped_elements
    float aaScale = (float)(s * zoom);
    float maxR = fmaxf((float)fmin(geometry.w, geometry.h) * 0.5f, 0.0f);
    float clamped[4];
    for (int i = 0; i < 4; i++) clamped[i] = fminf(fmaxf(radii[i], 0.0f), maxR);

    // compute_uniforms
    IFCRectI geo = IFCPaintedRect(geometry, s);
    float elemX = (float)element.x, elemY = (float)element.y;
    float elemW = (float)MAX(element.w, 1L), elemH = (float)MAX(element.h, 1L);
    float geoX = (float)geo.x, geoY = (float)geo.y;
    float geoW = (float)MAX(geo.w, 1L), geoH = (float)MAX(geo.h, 1L);
    float bufWf = (float)fmax(bufW, 1.0), bufHf = (float)fmax(bufH, 1.0);
    float srcX = (float)source.origin.x, srcY = (float)source.origin.y;
    float srcW = (float)fmax(source.size.width, 1.0), srcH = (float)fmax(source.size.height, 1.0);

    float sx = (bufWf / srcW) * (elemW / geoW);
    float sy = (bufHf / srcH) * (elemH / geoH);
    float tx = -(srcX / srcW) * (elemW / geoW) + (elemX - geoX) / geoW;
    float ty = -(srcY / srcH) * (elemH / geoH) + (elemY - geoY) / geoH;
    u->m0 = simd_make_float4(sx, 0, 0, 0);
    u->m1 = simd_make_float4(0, sy, 0, 0);
    u->m2 = simd_make_float4(tx, ty, 1, 0);
    u->aa_scale = aaScale;
    u->geo_size = simd_make_float2((float)geo.w / (float)s, (float)geo.h / (float)s);
    u->corner_radius = simd_make_float4(clamped[0], clamped[1], clamped[2], clamped[3]);
}

// The sampled sub-rect `source` (texels) of a `texW` x `texH` texture: smithay's
// tex_matrix, plus the centres of its outermost texels.
void IFCSetSource(IFCUniforms *u, CGRect source, double texW, double texH) {
    texW = fmax(texW, 1.0);
    texH = fmax(texH, 1.0);
    double x0 = source.origin.x, y0 = source.origin.y;
    double x1 = x0 + source.size.width, y1 = y0 + source.size.height;
    u->src = simd_make_float4((float)(x0 / texW), (float)(y0 / texH), (float)((x1 - x0) / texW), (float)((y1 - y0) / texH));
    double loX = x0 + 0.5, hiX = x1 - 0.5, loY = y0 + 0.5, hiY = y1 - 0.5;
    if (loX > hiX) loX = hiX = (x0 + x1) / 2.0;
    if (loY > hiY) loY = hiY = (y0 + y1) / 2.0;
    u->uv_bounds = simd_make_float4((float)(loX / texW), (float)(loY / texH), (float)(hiX / texW), (float)(hiY / texH));
}

static inline simd_float4 IFCColorVector(IFCompositorColor c) {
    return simd_make_float4((float)c.r / 255.0f, (float)c.g / 255.0f, (float)c.b / 255.0f, (float)c.a / 255.0f);
}

@implementation IFCompositorRenderer (Draw)

// MARK: Draw submission

// elements.rs `WindowTransformElement::transform_rect`.
IFCRectI IFCTransformRect(IFCRectI r, IFCompositorTransform t) {
    double x0 = t.originX + ((double)r.x - t.originX) * t.scaleX + t.offsetX;
    double y0 = t.originY + ((double)r.y - t.originY) * t.scaleY + t.offsetY;
    double x1 = t.originX + ((double)(r.x + r.w) - t.originX) * t.scaleX + t.offsetX;
    double y1 = t.originY + ((double)(r.y + r.h) - t.originY) * t.scaleY + t.offsetY;
    return IFCRectIMake(IFCRound(x0), IFCRound(y0), MAX(IFCRound(x1) - IFCRound(x0), 0L), MAX(IFCRound(y1) - IFCRound(y0), 0L));
}

- (void)draw:(IFCPipe)pipe dst:(IFCRectI)dst uniforms:(IFCUniforms *)u texture:(id<MTLTexture>)texture
     element:(IFCompositorElement *)element {
    [self draw:pipe dst:dst hole:IFCRectIMake(0, 0, 0, 0) uniforms:u texture:texture element:element];
}

// `hole` is a rectangle inside `dst` where the fragment shader is known to
// return exactly zero (the window body under its shadow, the content under its
// border). Under premultiplied source-over a zero fragment leaves the target
// unchanged, so those fragments are not rasterised at all: the element is
// drawn as up to four strips around the hole. Same pixels, far less fill.
- (void)draw:(IFCPipe)pipe dst:(IFCRectI)dst hole:(IFCRectI)hole uniforms:(IFCUniforms *)u
     texture:(id<MTLTexture>)texture element:(IFCompositorElement *)element {
    if (_hasXform) {
        dst = IFCTransformRect(dst, _xform);
        if (hole.w > 0 && hole.h > 0) {
            // One pixel of slack for the transform's own rounding.
            hole = IFCTransformRect(hole, _xform);
            hole = IFCRectIMake(hole.x + 1, hole.y + 1, hole.w - 2, hole.h - 2);
        }
    }
    // A pass into an intermediate texture (a blurred window's backdrop or
    // mask) draws the frame's own rectangles moved by a whole number of
    // pixels, as upstream's `RelocateRenderElement` does: every pixel gets the
    // value it has in the frame.
    dst.x -= _originX;
    dst.y -= _originY;
    hole.x -= _originX;
    hole.y -= _originY;
    IFCRectI scissor = element ? _elementScissor : _clip;
    if (dst.w <= 0 || dst.h <= 0 || !IFCRectIIntersect(dst, scissor, NULL)) return;
    id<MTLRenderPipelineState> pipeline = [_resources pipeline:pipe];
    if (!pipeline) return;

    IFCRectI parts[4];
    int partCount = 0;
    BOOL split = hole.w > 0 && hole.h > 0 && hole.x >= dst.x && hole.y >= dst.y && hole.x + hole.w <= dst.x + dst.w &&
                 hole.y + hole.h <= dst.y + dst.h;
    if (split) {
        long holeRight = hole.x + hole.w, holeBottom = hole.y + hole.h;
        parts[partCount++] = IFCRectIMake(dst.x, dst.y, dst.w, hole.y - dst.y);                        // above
        parts[partCount++] = IFCRectIMake(dst.x, holeBottom, dst.w, dst.y + dst.h - holeBottom);       // below
        parts[partCount++] = IFCRectIMake(dst.x, hole.y, hole.x - dst.x, hole.h);                      // left
        parts[partCount++] = IFCRectIMake(holeRight, hole.y, dst.x + dst.w - holeRight, hole.h);       // right
    } else {
        parts[partCount++] = dst;
    }

    u->dst = simd_make_float4((float)dst.x, (float)dst.y, (float)dst.w, (float)dst.h);
    u->target = simd_make_float2((float)_target.w, (float)_target.h);
    if (pipeline != _boundPipeline) {
        [_encoder setRenderPipelineState:pipeline];
        _boundPipeline = pipeline;
    }
    if (memcmp(&scissor, &_boundScissor, sizeof scissor) != 0) {
        [_encoder setScissorRect:(MTLScissorRect){(NSUInteger)scissor.x, (NSUInteger)scissor.y, (NSUInteger)scissor.w, (NSUInteger)scissor.h}];
        _boundScissor = scissor;
    }
    if (texture) [_encoder setFragmentTexture:texture atIndex:0];
    BOOL fragmentUniformsBound = NO;
    for (int i = 0; i < partCount; i++) {
        IFCRectI part = parts[i];
        if (part.w <= 0 || part.h <= 0 || !IFCRectIIntersect(part, scissor, NULL)) continue;
        u->quad = simd_make_float4((float)part.x, (float)part.y, (float)part.w, (float)part.h);
        [_encoder setVertexBytes:u length:sizeof *u atIndex:0];
        // Only the vertex shader reads quad. A split shadow/border changes
        // that rectangle per strip, but every strip shares its fragment data.
        if (!fragmentUniformsBound) {
            [_encoder setFragmentBytes:u length:sizeof *u atIndex:0];
            fragmentUniformsBound = YES;
        }
        [_encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        _drawsSubmitted++;
    }
}

// mod.rs `push_shadow_element` / `push_border_element`, shared by windows and
// stand-ins. `inner` is the rectangle the border wraps (content, or title bar
// plus content); the shadow is cast by `inner` grown by the border.
- (void)drawChromeAround:(IFCRectD)inner decoration:(IFCompositorDecoration)deco borderWidth:(long)bw radius:(long)radius
                  shadow:(BOOL)shadow focused:(BOOL)focused alpha:(float)alpha scale:(double)s zoom:(double)zoom
                   parts:(IFCChromePart)parts element:(IFCompositorElement *)element {
    if (shadow && !_skipShadow && (parts & IFCChromeShadow)) {
        // The footprint grows by border_width so the shadow grades from the
        // border's outer edge; the radius follows `outer_corner_radius`.
        // (closing.rs `flatten` hands `bake_shadow_element` the body as it is,
        // not grown: a baked shadow starts under the border.)
        double b = _bake ? 0.0 : (double)bw;
        IFCRectD body = {inner.x - b, inner.y - b, inner.w + 2.0 * b, inner.h + 2.0 * b};
        IFCUniforms u = IFCUniformsZero();
        IFCRectI dst, hole;
        IFCShadowGeometry(body, IFCOuterCornerRadius((float)radius, (float)bw), deco.shadowRadius, s, zoom, &dst, &hole, &u);
        u.color = IFCColorVector(deco.shadowColor);
        u.alpha = alpha;
        [self draw:IFCPipeShadow dst:dst hole:hole uniforms:&u texture:nil element:element];
    }
    if (bw > 0 && (parts & IFCChromeBorder)) {
        IFCUniforms u = IFCUniformsZero();
        IFCRectI dst, hole;
        if (IFCBorderGeometry(inner, bw, (float)radius, s, zoom, &dst, &hole, &u)) {
            u.color = IFCColorVector(focused ? deco.borderColorFocused : deco.borderColor);
            u.alpha = alpha;
            [self draw:IFCPipeBorder dst:dst hole:hole uniforms:&u texture:nil element:element];
        }
    }
}

// A memory buffer drawn through smithay's default texture program into `dst`
// (pre-zoom physical), pixel-snapped by `zoom` (`PixelSnapRescaleElement`).
- (void)drawBuffer:(id<MTLTexture>)texture preZoom:(IFCRectI)rect zoom:(double)zoom alpha:(float)alpha
           element:(IFCompositorElement *)element {
    if (!texture) return;
    IFCUniforms u = IFCUniformsZero();
    u.alpha = alpha;
    IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)texture.width, (CGFloat)texture.height), (double)texture.width, (double)texture.height);
    [self draw:IFCPipeTexture dst:IFCCornerRound(rect, zoom) uniforms:&u texture:texture element:element];
}

// blur.rs, the splice at the end of `process_blur_requests`: the frost as a
// `TextureRenderElement` at `screen_rect.loc`, `src = texel_src(win_size)`,
// logical size `round(win_size / output_scale)`, alpha 1 — whatever the
// window's opacity is.
- (void)drawFrostOf:(IFCompositorElement *)element entry:(IFCEntry *)entry scale:(double)s {
    if (!entry || !entry->frostValid || entry->frostZeroed || !entry->frostTexture || entry->frostSeen != _generation) return;
    IFCUniforms u = IFCUniformsZero();
    IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)entry->frostW, (CGFloat)entry->frostH), (double)entry->frostAllocW, (double)entry->frostAllocH);
    IFCRectI r = entry->frostRect;
    IFCRectI dst = IFCMemoryElementRect((double)r.x, (double)r.y, IFCRound((double)r.w / s), IFCRound((double)r.h / s), s);
    // `screen_rect` already went through the window's animation
    // (`transform_phys_rect`); the frost element is not wrapped in one.
    BOOL hadXform = _hasXform;
    _hasXform = NO;
    [self draw:IFCPipeTexture dst:dst uniforms:&u texture:entry->frostTexture element:element];
    _hasXform = hadXform;
}

// mod.rs `compose_frame`, one client window.
- (void)drawWindow:(const IFCItem *)item frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    IFCompositorElement *element = item->element;
    IFCGeom g = item->g;
    double s = c->s;
    long decorationScale = c->decorationScale;
    uint64_t styleHash = c->styleHash;
    IFCompositorDecoration deco = element.decoration;
    double zoom = g.zoom;
    // `decoration = "none"` hard-vetoes compositor chrome (the effective_*
    // helpers return 0 / false for it), and a fullscreen window draws through
    // the same branch.
    BOOL bare = deco.mode == IFCompositorDecorationModeNone;
    BOOL hasSSD = deco.mode == IFCompositorDecorationModeServer;
    long bw = bare ? 0 : MAX((long)deco.borderWidth, 0L);
    long radius = bare ? 0 : MAX((long)deco.cornerRadius, 0L);
    BOOL shadow = !bare && deco.shadow;
    float opacity = (float)fmin(fmax(deco.opacity, 0.0), 1.0);
    // An open or close fade: `effective_opacity(..) * visual_alpha as f64`.
    if (item->lifeAlpha != 1.0f) opacity = (float)((double)opacity * (double)item->lifeAlpha);
    // closing.rs: the bake is drawn at alpha 1; the snapshot is faded as one piece.
    if (_bake) opacity = 1.0f;
    IFCompositorChromeStyle *style = frame.chrome;

    // What this identifier cached as a stand-in, or as a window with a bar.
    IFCEntry *existing = (__bridge IFCEntry *)CFDictionaryGetValue(_entries, (const void *)(uintptr_t)element.identifier);
    if (existing) {
        [self retireChromeOf:existing keepingBar:hasSSD];
        if (!_internal && !element.blur) [self retireFrostOf:existing];
    }

    // loc_phys = render_loc.to_physical_precise_round(scale)
    long locX = IFCRound(g.r.x * s), locY = IFCRound(g.r.y * s);
    // The surface element: WaylandSurfaceRenderElement::geometry.
    IFCRectI surface = IFCRectIMake(locX, locY, IFCRound(g.r.w * s), IFCRound(g.r.h * s));

    // Snap the title-bar band to whole physical pixels and share it across the
    // bar, border and shadow.
    double barHPhys = hasSSD ? round((double)style.titleBarHeight * s) : 0.0;
    double barHLogical = barHPhys / s;
    IFCRectD inner = {g.r.x, g.r.y - barHLogical, g.r.w, g.r.h + barHLogical};

    // Bottom to top: shadow, frost, border, content, title bar (upstream
    // pushes them top to bottom: bar, content, border, [frost], shadow).
    [self drawChromeAround:inner decoration:deco borderWidth:bw radius:radius shadow:shadow focused:element.focused
                     alpha:opacity scale:s zoom:zoom parts:IFCChromeShadow element:element];
    // No frost in a backdrop, a mask or a bake: upstream captures them from
    // the element list before any frost is spliced into it.
    if (element.blur && !_internal) [self drawFrostOf:element entry:existing scale:s];
    [self drawChromeAround:inner decoration:deco borderWidth:bw radius:radius shadow:shadow focused:element.focused
                     alpha:opacity scale:s zoom:zoom parts:IFCChromeBorder element:element];

    id<MTLTexture> content = [self contentTextureFor:element];
    BOOL placeholder = content == nil;
    if (placeholder && frame.placeholderColor.a > 0) content = [self placeholderTextureForColor:frame.placeholderColor];
    if (content) {
        double bufW = (double)content.width, bufH = (double)content.height;
        CGRect source = CGRectMake(0, 0, bufW, bufH);
        if (!placeholder && !CGRectIsNull(element.contentRect) && element.contentRect.size.width > 0 && element.contentRect.size.height > 0) {
            source = element.contentRect;
        }
        IFCUniforms u = IFCUniformsZero();
        u.alpha = opacity;
        u.no_alpha = (!placeholder && element.contentOpaque) ? 1.0f : 0.0f;
        IFCSetSource(&u, source, bufW, bufH);
        IFCRectI dst = IFCCornerRound(surface, zoom);
        // SSD clips only when there is something to clip against; CSD always
        // clips to the geometry; bare and fullscreen pass through.
        BOOL clip = !bare && (!hasSSD || bw > 0 || radius > 0);
        if (clip) {
            float r = (float)radius;
            // Only the bottom corners round under a title bar.
            const float radii[4] = {hasSSD ? 0.0f : r, hasSSD ? 0.0f : r, r, r};
            IFCCornerClipUniforms(surface, g.r, radii, s, zoom, bufW, bufH, source, &u);
            [self draw:IFCPipeCornerClip dst:dst uniforms:&u texture:content element:element];
        } else {
            [self draw:IFCPipeTexture dst:dst uniforms:&u texture:content element:element];
        }
    }

    if (hasSSD) {
        long width = IFCRound(g.r.w);
        IFCEntry *entry = [self entryFor:element.identifier];
        id<MTLTexture> bar = [self barTextureFor:entry width:width scale:decorationScale title:element.title
                                          pinned:element.showsPinnedIndicator radius:radius style:style styleHash:styleHash];
        // The bar takes the border's inner width so it stops where the content does.
        IFCRectI barDst = IFCRectIMake(locX, locY - IFCTrunc(barHPhys), IFCPaintedExtent(g.r.w, s), IFCPaintedExtent(barHLogical, s));
        [self drawBuffer:bar preZoom:barDst zoom:zoom alpha:opacity element:element];
    }
}

// suspended.rs `push_suspended_element`.
- (void)drawStandIn:(const IFCItem *)item frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    IFCompositorElement *element = item->element;
    IFCGeom g = item->g;
    double s = c->s;
    long decorationScale = c->decorationScale;
    uint64_t styleHash = c->styleHash;
    IFCompositorDecoration deco = element.decoration;
    IFCompositorChromeStyle *style = frame.chrome;
    double zoom = g.zoom;
    // Upstream's stand-in size is an integer logical size.
    long sizeW = MAX(IFCRound(g.r.w), 0L), sizeH = MAX(IFCRound(g.r.h), 0L);
    long bw = MAX((long)deco.borderWidth, 0L);
    long radius = MAX((long)deco.cornerRadius, 0L);
    float alpha = (float)fmin(fmax(deco.opacity, 0.0), 1.0);
    // closing.rs `StandInFade::alpha`: a departing stand-in fades as a whole.
    if (item->lifeAlpha != 1.0f) alpha = (float)((double)alpha * (double)item->lifeAlpha);

    long locX = IFCRound(g.r.x * s), locY = IFCRound(g.r.y * s);
    double barHPhys = round((double)style.titleBarHeight * s);
    double barHLogical = barHPhys / s;
    IFCEntry *entry = [self entryFor:element.identifier];
    [self retireFrostOf:entry];
    // A stand-in draws no content: let go of the capture buffer and its Metal
    // wrapper this identifier held as a live window (whatever the element's
    // own `pixelBuffer` still says).
    [self retireContentOf:entry];

    // Bottom to top: shadow, border, title bar, body, label.
    IFCRectD inner = {g.r.x, g.r.y - barHLogical, (double)sizeW, (double)sizeH + barHLogical};
    [self drawChromeAround:inner decoration:deco borderWidth:bw radius:radius shadow:deco.shadow focused:element.focused
                     alpha:alpha scale:s zoom:zoom parts:(IFCChromeShadow | IFCChromeBorder) element:element];

    // Title bar via the windowless rasteriser, textless: the centred label
    // already names the app. It rounds to the element's radius like its border.
    id<MTLTexture> bar = [self barTextureFor:entry width:sizeW scale:decorationScale title:@"" pinned:NO radius:radius
                                       style:style styleHash:styleHash];
    IFCRectI barDst = IFCRectIMake(locX, locY - IFCTrunc(barHPhys), IFCPaintedExtent((double)sizeW, s), IFCPaintedExtent(barHLogical, s));
    [self drawBuffer:bar preZoom:barDst zoom:zoom alpha:alpha element:element];

    // Rounded body fill in the SSD background colour, trimmed to the painted rect.
    id<MTLTexture> body = [self bodyTextureFor:entry width:sizeW height:sizeH scale:decorationScale style:style styleHash:styleHash];
    IFCRectI bodyDst = IFCRectIMake(locX, locY, IFCPaintedExtent((double)sizeW, s), IFCPaintedExtent((double)sizeH, s));
    [self drawBuffer:body preZoom:bodyDst zoom:zoom alpha:alpha element:element];

    // Centred app-name label.
    NSString *name = element.appName.length ? element.appName : (element.title ?: @"");
    id<MTLTexture> label = [self labelTextureFor:entry name:name launching:element.launching width:sizeW height:sizeH
                                           scale:decorationScale style:style styleHash:styleHash];
    if (label) {
        double labelX = g.r.x + (double)entry->labelRect.x, labelY = g.r.y + (double)entry->labelRect.y;
        // The memory element's logical size: buffer size over buffer scale.
        IFCRectI labelDst = IFCMemoryElementRect(labelX * s, labelY * s, entry->labelBufW / decorationScale, entry->labelBufH / decorationScale, s);
        [self drawBuffer:label preZoom:labelDst zoom:zoom alpha:alpha element:element];
    }
}

// closing.rs `ClosingSnapshot::render_element`: the baked window as one
// texture, faded by `fade_out_alpha` and shrunk about the centre of the
// rectangle it covers.
- (void)drawSnapshot:(const IFCItem *)item ctx:(const IFCFrameCtx *)c {
    IFCompositorElement *element = item->element;
    // What this identifier cached as a live window or a stand-in.
    IFCEntry *existing = (__bridge IFCEntry *)CFDictionaryGetValue(_entries, (const void *)(uintptr_t)element.identifier);
    if (existing) {
        [self retireChromeOf:existing keepingBar:NO];
        [self retireFrostOf:existing];
    }
    id<MTLTexture> texture = [self contentTextureFor:element];
    if (!texture) return;
    IFCGeom g = item->g;
    double s = c->s;
    double p = item->progress;
    float alpha = IFCompositorCloseAlpha(p);
    // let close_scale = if self.alpha_only { 1.0 } else { 1.0 - (1.0 - self.scale_amplitude) * self.progress };
    double closeScale = item->alphaOnly ? 1.0 : IFCompositorCloseScale(p, c->effects.animationScale);

    // (canvas_rect.loc - camera) * zoom and canvas_rect.size * zoom for a canvas
    // snapshot; the screen rectangle itself (zoom 1) for a pinned one.
    double screenX = g.r.x * g.zoom, screenY = g.r.y * g.zoom;
    double screenW = g.r.w * g.zoom, screenH = g.r.h * g.zoom;
    double locX = screenX * s, locY = screenY * s;
    double sizeW = screenW * s, sizeH = screenH * s;
    // TextureRenderElement at loc_phys, logical size screen_size.to_i32_round(),
    // inside WindowTransformElement(center, offset 0, close_scale).
    IFCompositorTransform t = {locX + sizeW / 2.0, locY + sizeH / 2.0, 0.0, 0.0, closeScale, closeScale};
    IFCRectI dst = IFCTransformRect(IFCMemoryElementRect(locX, locY, IFCRound(screenW), IFCRound(screenH), s), t);

    double bufW = (double)texture.width, bufH = (double)texture.height;
    CGRect source = CGRectMake(0, 0, bufW, bufH);  // texel_src(self.texels)
    if (!CGRectIsNull(element.contentRect) && element.contentRect.size.width > 0 && element.contentRect.size.height > 0) {
        source = element.contentRect;
    }
    IFCUniforms u = IFCUniformsZero();
    // Upstream: `Some(alpha)`. The element's opacity (1 for a bake) multiplies it.
    double opacity = fmin(fmax(element.decoration.opacity, 0.0), 1.0);
    u.alpha = opacity == 1.0 ? alpha : (float)((double)alpha * opacity);
    u.no_alpha = element.contentOpaque ? 1.0f : 0.0f;
    IFCSetSource(&u, source, bufW, bufH);
    [self draw:IFCPipeTexture dst:dst uniforms:&u texture:texture element:element];
}

// One element, in whichever pass is open: the frame itself, the backdrop of a
// blurred window above it, or its own mask.
- (void)drawItem:(const IFCItem *)item frame:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    IFCRectI scissor = item->scissor;
    scissor.x -= _originX;
    scissor.y -= _originY;
    if (!IFCRectIIntersect(scissor, _clip, &_elementScissor)) return;
    _hasXform = item->hasXform;
    _xform = item->xform;
    switch (item->element.kind) {
        case IFCompositorElementKindStandIn:
            [self drawStandIn:item frame:frame ctx:c];
            break;
        case IFCompositorElementKindSnapshot:
            [self drawSnapshot:item ctx:c];
            break;
        case IFCompositorElementKindWindow:
        default:
            [self drawWindow:item frame:frame ctx:c];
            break;
    }
    _hasXform = NO;
}

// error_bar.rs `build_error_bar_elements`: above every window, across the
// bottom edge of the output. Not zoomed.
- (void)drawErrorBar:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    NSArray<NSString *> *messages = frame.errorMessages;
    if (!messages.count) {
        // `state.render.cached_error_bar.remove(&name)`
        if (_errorBarTexture) [_graveyard bury:_errorBarTexture];
        _errorBarTexture = nil;
        _errorBarMessages = nil;
        return;
    }
    long width = MAX(c->viewportW, 1L), scale = MAX(c->decorationScale, 1L), barHeight = (long)IFCompositorErrorBarHeight();
    // Keyed by (text, width, scale), as upstream's cache is.
    if (!_errorBarMessages || width != _errorBarWidth || scale != _errorBarScale ||
        (messages != _errorBarMessages && ![messages isEqualToArray:_errorBarMessages])) {
        long w = 0, h = 0;
        NSData *pixels = IFCRenderErrorBar(IFCompositorErrorBarText(messages), width, barHeight, scale, &w, &h);
        if (_errorBarTexture) [_graveyard bury:_errorBarTexture];
        _errorBarTexture = [self textureWithRGBA:pixels width:w height:h];
        _errorBarWidth = width;
        _errorBarScale = scale;
    }
    _errorBarMessages = messages;
    if (!_errorBarTexture) return;
    // loc = (0, viewport.h - bar_height) in logical pixels, to_physical(output_scale);
    // the buffer's logical size is its pixel size over its scale.
    IFCRectI dst = IFCMemoryElementRect(0.0, (double)(c->viewportH - barHeight) * c->s, width, barHeight, c->s);
    IFCUniforms u = IFCUniformsZero();
    IFCSetSource(&u, CGRectMake(0, 0, (CGFloat)_errorBarTexture.width, (CGFloat)_errorBarTexture.height),
                 (double)_errorBarTexture.width, (double)_errorBarTexture.height);
    // PixelSnapRescaleElement with a rescale of 1.0: unchanged.
    [self draw:IFCPipeTexture dst:dst uniforms:&u texture:_errorBarTexture element:nil];
}

// mod.rs `outline_edge_strips` + `build_output_outline_elements`.
- (void)drawOutlines:(IFCompositorFrame *)frame scale:(double)s viewportW:(long)viewportW viewportH:(long)viewportH {
    IFCompositorOutlineSettings settings = frame.outline;
    long thickness = settings.thickness;
    float opacity = (float)settings.opacity;
    NSUInteger count = frame.outlineRectCount;
    if (thickness <= 0 || !(opacity > 0.0f) || !count) return;
    const CGRect *rects = [frame ifc_outlineRects];
    IFCRectI viewport = IFCRectIMake(0, 0, viewportW, viewportH);
    IFCUniforms u = IFCUniformsZero();
    // The strip buffer holds the configured colour bytes; the element's alpha
    // is the configured opacity.
    u.color = IFCColorVector(settings.color);
    u.alpha = fminf(opacity, 1.0f);
    // Upstream's list is top to bottom; draw it back to front.
    for (NSUInteger i = count; i-- > 0;) {
        IFCRectI outline = IFCRectIMake(IFCTrunc(rects[i].origin.x), IFCTrunc(rects[i].origin.y),
                                        IFCTrunc(rects[i].size.width), IFCTrunc(rects[i].size.height));
        if (!IFCRectIIntersect(viewport, outline, NULL)) continue;
        const IFCRectI edges[4] = {
            IFCRectIMake(outline.x, outline.y, outline.w, thickness),
            IFCRectIMake(outline.x, outline.y + outline.h - thickness, outline.w, thickness),
            IFCRectIMake(outline.x, outline.y, thickness, outline.h),
            IFCRectIMake(outline.x + outline.w - thickness, outline.y, thickness, outline.h),
        };
        for (int e = 3; e >= 0; e--) {
            IFCRectI strip;
            if (!IFCRectIIntersect(edges[e], viewport, &strip)) continue;
            // loc = strip.loc.to_f64().to_physical(scale); the buffer is at scale 1.
            IFCRectI dst = IFCMemoryElementRect((double)strip.x * s, (double)strip.y * s, strip.w, strip.h, s);
            // PixelSnapRescaleElement with a rescale of 1.0: unchanged.
            [self draw:IFCPipeSolid dst:dst uniforms:&u texture:nil element:nil];
        }
    }
}

// MARK: Intermediate passes

// Opens a render pass on `texture` whose viewport is its top-left
// `width` x `height` pixels (smithay's `renderer.render(target, size, ..)`:
// `glViewport(0, 0, w, h)` and the matching scissor).
- (BOOL)beginPassOn:(id<MTLTexture>)texture width:(long)width height:(long)height load:(MTLLoadAction)load
              clear:(MTLClearColor)clear commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!texture || width <= 0 || height <= 0) return NO;
    _pass.colorAttachments[0].texture = texture;
    _pass.colorAttachments[0].loadAction = load;
    _pass.colorAttachments[0].clearColor = clear;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:_pass];
    _pass.colorAttachments[0].texture = nil;
    _pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    if (!encoder) return NO;
    _encoder = encoder;
    _boundPipeline = nil;
    _target = IFCRectIMake(0, 0, width, height);
    _clip = _target;
    if ((NSUInteger)width != texture.width || (NSUInteger)height != texture.height) {
        [encoder setViewport:(MTLViewport){0, 0, (double)width, (double)height, 0, 1}];
        [encoder setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)width, (NSUInteger)height}];
    }
    _boundScissor = _target;
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];
    return YES;
}

- (void)endPass {
    [_encoder endEncoding];
    _encoder = nil;
    _boundPipeline = nil;
}

// One quad over `dst` of the open pass, with none of the per-element state.
- (void)rawDraw:(IFCPipe)pipe dst:(IFCRectI)dst uniforms:(IFCUniforms *)u texture:(id<MTLTexture>)texture {
    id<MTLRenderPipelineState> pipeline = [_resources pipeline:pipe];
    if (!pipeline || !_encoder) return;
    u->dst = simd_make_float4((float)dst.x, (float)dst.y, (float)dst.w, (float)dst.h);
    u->quad = u->dst;
    u->target = simd_make_float2((float)_target.w, (float)_target.h);
    [_encoder setRenderPipelineState:pipeline];
    _boundPipeline = pipeline;
    if (texture) [_encoder setFragmentTexture:texture atIndex:0];
    [_encoder setVertexBytes:u length:sizeof *u atIndex:0];
    [_encoder setFragmentBytes:u length:sizeof *u atIndex:0];
    [_encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

@end
