// SPDX-License-Identifier: GPL-3.0-or-later
//
// Infinify compositor — the renderer: deferred release, per-element caches,
// frame encoding, closing snapshots and offscreen export. See IFCompositor.h
// and COMPOSITOR-NOTES.md (under docs/). The cached-background chunk
// generation is described in BACKGROUND-NOTES.md (under docs/), section 17.3.
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "IFCompositor+Private.h"

#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <os/lock.h>

static NSString *const IFCErrorDomain = @"IFCompositorErrorDomain";

// CoreVideo keeps the Metal texture of a released wrapper, and through it the
// memory of the buffer's IOSurface, until the texture cache is flushed after
// the buffer has gone unused (released by everyone) for this many seconds.
// (CoreVideo's default, stated so the renderer can pace the flush that lets
// it go.)
static const double kIFCTextureCacheAge = 1.0;

// MARK: - Deferred release

// Textures a command buffer still samples must outlive it. Everything the
// renderer stops using goes through here and is released when every command
// buffer encoded up to that moment has completed. One completion block is
// created per renderer and reused for every frame.
@implementation IFCGraveyard {
    os_unfair_lock _lock;
    uint64_t _begun, _completed;
    NSMutableArray *_dead;
    NSMutableArray<NSNumber *> *_deadline;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _dead = [NSMutableArray array];
    _deadline = [NSMutableArray array];
    return self;
}

- (void)began {
    os_unfair_lock_lock(&_lock);
    _begun++;
    os_unfair_lock_unlock(&_lock);
}

- (void)bury:(id)object {
    if (!object) return;
    os_unfair_lock_lock(&_lock);
    if (_completed < _begun) {
        [_dead addObject:object];
        [_deadline addObject:@(_begun)];
    }
    os_unfair_lock_unlock(&_lock);
    // When nothing is in flight the caller's reference was the last one.
}

- (void)finished {
    // Metal's completion queue need not drain an autorelease pool after each
    // callback. Bound the lifetime of the temporary release array (and any
    // autoreleases made by a retired CV wrapper) to this completed GPU fence,
    // rather than leaving capture-pool surfaces held until a later queue drain.
    @autoreleasepool {
        __attribute__((objc_precise_lifetime)) NSArray *released = nil;
        os_unfair_lock_lock(&_lock);
        _completed++;
        NSUInteger count = 0;
        while (count < _dead.count && _deadline[count].unsignedLongLongValue <= _completed) count++;
        if (count) {
            // Deadlines are appended in order. Remove the completed prefix once,
            // rather than shifting both arrays for every retired window texture.
            NSRange range = NSMakeRange(0, count);
            released = [_dead subarrayWithRange:range];
            [_dead removeObjectsInRange:range];
            [_deadline removeObjectsInRange:range];
        }
        os_unfair_lock_unlock(&_lock);
        released = nil;  // dropped outside the lock
    }
}
@end

// MARK: - Per-element cache entry (interfaces in IFCompositor+Private.h)

@implementation IFCTextureCache
- (void)dealloc {
    if (ref) CFRelease(ref);
}
@end

@implementation IFCEntry
- (void)dealloc {
    if (cvTexture) CFRelease(cvTexture);
    if (buffer) CVPixelBufferRelease(buffer);
}
@end

// A replaced content wrapper on its way to the graveyard.
@interface IFCRetiredContent : NSObject {
  @public
    CVPixelBufferRef buffer;
    CVMetalTextureRef cvTexture;
    IFCTextureCache *cache;
    id<MTLTexture> texture;
}
@end

@implementation IFCRetiredContent
- (void)dealloc {
    if (cvTexture) CFRelease(cvTexture);
    if (buffer) CVPixelBufferRelease(buffer);
}
@end

// MARK: - Renderer

static void IFCReleaseBytes(void *info, const void *data, size_t size) {
    (void)info;
    (void)size;
    free((void *)data);
}

// BGRA8 bytes -> sRGB CGImage. Takes ownership of `bytes`.
static CGImageRef IFCCreateImage(uint8_t *bytes, NSUInteger w, NSUInteger h, BOOL alpha) CF_RETURNS_RETAINED {
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bytes, w * h * 4, IFCReleaseBytes);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = (CGBitmapInfo)kCGBitmapByteOrder32Little |
                        (CGBitmapInfo)(alpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, srgb, info, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(srgb);
    CGDataProviderRelease(provider);
    return image;
}

static void IFCCollectStale(const void *key, const void *value, void *context) {
    IFCStaleScan *scan = context;
    IFCEntry *entry = (__bridge IFCEntry *)value;
    if (entry->lastUsed == scan->generation) return;
    if (scan->count == scan->capacity) {
        NSUInteger capacity = scan->capacity ? scan->capacity * 2 : 64;
        uintptr_t *grown = realloc(scan->keys, capacity * sizeof(uintptr_t));
        if (!grown) return;
        scan->keys = grown;
        scan->capacity = capacity;
    }
    scan->keys[scan->count++] = (uintptr_t)key;
}

@implementation IFCompositorRenderer

+ (instancetype)rendererWithDevice:(id<MTLDevice>)device {
    return [[self alloc] initWithDevice:device];
}

- (instancetype)init {
    return [self initWithDevice:nil];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    if (!device) device = MTLCreateSystemDefaultDevice();
    if (!device) return nil;
    _device = device;
    _resources = [IFCDeviceResources resourcesForDevice:device];
    _commandQueue = _resources.queue;
    _textureCache = [IFCTextureCache new];
    NSDictionary *cacheAttributes = @{(__bridge id)kCVMetalTextureCacheMaximumTextureAgeKey: @(kIFCTextureCacheAge)};
    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)cacheAttributes, device, NULL, &_textureCache->ref) !=
        kCVReturnSuccess) {
        _textureCache->ref = NULL;
    }
    _entries = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    _graveyard = [IFCGraveyard new];
    IFCGraveyard *graveyard = _graveyard;
    _completion = [^(id<MTLCommandBuffer> commandBuffer) {
        (void)commandBuffer;
        [graveyard finished];
    } copy];
    _pass = [MTLRenderPassDescriptor renderPassDescriptor];
    _pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    _pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    return self;
}

- (void)dealloc {
    [self purge];
    if (_entries) CFRelease(_entries);
    free(_scan.keys);
    free(_items);
}

static void IFCBuryEntry(const void *key, const void *value, void *context) {
    (void)key;
    [(__bridge IFCGraveyard *)context bury:(__bridge IFCEntry *)value];
}

- (void)purge {
    // Entries a command buffer may still sample are parked until it completes.
    if (_entries) {
        CFDictionaryApplyFunction(_entries, IFCBuryEntry, (__bridge void *)_graveyard);
        CFDictionaryRemoveAllValues(_entries);
    }
    if (_placeholderTexture) [_graveyard bury:_placeholderTexture];
    _placeholderTexture = nil;
    _placeholderTextureValid = NO;
    if (_errorBarTexture) [_graveyard bury:_errorBarTexture];
    _errorBarTexture = nil;
    _errorBarMessages = nil;
    if (_bgCopy) [_graveyard bury:_bgCopy];
    _bgCopy = nil;
    _bgTexture = nil;
    _bgTextureTried = NO;
    _hasBlurBeat = NO;
    if (_textureCache->ref) CVMetalTextureCacheFlush(_textureCache->ref, 0);
}

// The flushes in the encodes right after a retirement return the IOSurface to
// its pool, but they come too early to free anything: CoreVideo lets go of a
// wrapper's Metal texture, and the surface memory it keeps mapped, only in a
// flush made once the buffer has been unused for kIFCTextureCacheAge — and
// the buffer may be held by the host longer than by this renderer. So the
// cache is also flushed for age, at most once per that age and a half, at the
// end of an encode and when the layer skips a redraw: a scene that went
// static right after a window closed or became a stand-in gives the memory
// back on a later update of the host, drawn or not.
- (void)ifc_flushAgedTextures {
    CFTimeInterval now = CACurrentMediaTime();
    if (now < _nextAgedFlush) return;
    _nextAgedFlush = now + kIFCTextureCacheAge * 1.5;
    if (_textureCache->ref) CVMetalTextureCacheFlush(_textureCache->ref, 0);
}

// MARK: Cache

- (IFCEntry *)entryFor:(uint64_t)identifier {
    const void *key = (const void *)(uintptr_t)identifier;
    IFCEntry *entry = (__bridge IFCEntry *)CFDictionaryGetValue(_entries, key);
    if (!entry) {
        entry = [IFCEntry new];
        CFDictionarySetValue(_entries, key, (__bridge void *)entry);
    }
    if (entry->lastUsed != _generation) {
        entry->lastUsed = _generation;
        _touched++;
    }
    return entry;
}

- (void)retireContentOf:(IFCEntry *)entry {
    if (!entry->buffer && !entry->cvTexture && !entry->contentTexture) return;
    IFCRetiredContent *retired = [IFCRetiredContent new];
    retired->buffer = entry->buffer;
    retired->cvTexture = entry->cvTexture;
    retired->cache = entry->cache;
    retired->texture = entry->contentTexture;
    entry->buffer = NULL;
    entry->cvTexture = NULL;
    entry->cache = nil;
    entry->contentTexture = nil;
    [_graveyard bury:retired];
    // CoreVideo only lets go of an unused wrapper's backing when the cache is
    // flushed, and this one is released when its last frame completes: flush
    // at the end of this encode and of the next few.
    _flushCountdown = 3;
}

// An entry serves one kind of element at a time. An element keeps its
// identifier when it turns from a live window into a stand-in or back (as
// upstream keeps the element id), and the entry stays alive because it is used
// every frame — so whatever the other kind cached has to be dropped by hand:
// the stand-in's body and label, and the title bar unless the window still
// draws one. (-retireContentOf: is the other half, called for a stand-in.)
- (void)retireChromeOf:(IFCEntry *)entry keepingBar:(BOOL)keepBar {
    if (entry->bodyValid) {
        if (entry->bodyTexture) [_graveyard bury:entry->bodyTexture];
        entry->bodyTexture = nil;
        entry->bodyValid = NO;
    }
    if (entry->labelValid) {
        if (entry->labelTexture) [_graveyard bury:entry->labelTexture];
        entry->labelTexture = nil;
        entry->labelText = nil;
        entry->labelValid = NO;
    }
    if (!keepBar && entry->barValid) {
        if (entry->barTexture) [_graveyard bury:entry->barTexture];
        entry->barTexture = nil;
        entry->barTitle = nil;
        entry->barValid = NO;
    }
}

// The frost goes with the request for it (upstream prunes `blur_cache` to the
// windows that asked this frame).
- (void)retirePadsOf:(IFCEntry *)entry {
    if (entry->padA) [_graveyard bury:entry->padA];
    if (entry->padB) [_graveyard bury:entry->padB];
    entry->padA = entry->padB = nil;
    entry->padW = entry->padH = 0;
    entry->padsIdle = 0;
}

- (void)retireFrostOf:(IFCEntry *)entry {
    if (!entry->frostTexture && !entry->maskTexture && !entry->padA && !entry->frostValid && !entry->frostInit) return;
    if (entry->frostTexture) [_graveyard bury:entry->frostTexture];
    if (entry->maskTexture) [_graveyard bury:entry->maskTexture];
    entry->frostTexture = nil;
    entry->maskTexture = nil;
    [self retirePadsOf:entry];
    entry->frostAllocW = entry->frostAllocH = 0;
    entry->frostValid = NO;
    entry->frostZeroed = NO;
    entry->frostInit = NO;
    entry->frostHasContentId = NO;
    entry->frostSeen = 0;
}

// The texture for an element's live content, and its size in pixels. nil
// while no frame has arrived.
- (id<MTLTexture>)contentTextureFor:(IFCompositorElement *)element {
    id<MTLTexture> texture = element.texture;
    CVPixelBufferRef buffer = element.pixelBuffer;
    if (texture || !buffer) {
        // No wrapper needed; drop one left from an earlier buffer.
        IFCEntry *existing = (__bridge IFCEntry *)CFDictionaryGetValue(_entries, (const void *)(uintptr_t)element.identifier);
        if (existing) [self retireContentOf:existing];
        return texture;
    }
    IFCEntry *entry = [self entryFor:element.identifier];
    if (entry->buffer == buffer && entry->contentTexture) return entry->contentTexture;
    [self retireContentOf:entry];
    if (!_textureCache->ref) return nil;
    if (CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA || !CVPixelBufferGetIOSurface(buffer)) {
        if (!_warnedFormat) {
            _warnedFormat = YES;
            NSLog(@"compositor: element %llu: content must be an IOSurface-backed kCVPixelFormatType_32BGRA buffer; drawing the placeholder",
                  (unsigned long long)element.identifier);
        }
        return nil;
    }
    CVMetalTextureRef cvTexture = NULL;
    // BGRA8Unorm, not _sRGB: texels are sampled as encoded, like a GL texture.
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache->ref, buffer, NULL, MTLPixelFormatBGRA8Unorm,
                                                                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture);
    if (status != kCVReturnSuccess || !cvTexture) return nil;
    id<MTLTexture> wrapped = CVMetalTextureGetTexture(cvTexture);
    if (!wrapped) {
        CFRelease(cvTexture);
        return nil;
    }
    entry->buffer = CVPixelBufferRetain(buffer);
    entry->cvTexture = cvTexture;
    entry->cache = _textureCache;
    entry->contentTexture = wrapped;
    return wrapped;
}

- (id<MTLTexture>)textureWithRGBA:(NSData *)data width:(long)w height:(long)h {
    if (!data || w <= 0 || h <= 0) return nil;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:(NSUInteger)w
                                                                                 height:(NSUInteger)h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:td];
    [texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h) mipmapLevel:0 withBytes:data.bytes bytesPerRow:(NSUInteger)w * 4];
    return texture;
}

// decorations.rs `WindowDecoration::update`: re-render when the width, pinned
// flag, scale, title, corner radius or style changed.
- (id<MTLTexture>)barTextureFor:(IFCEntry *)e width:(long)width scale:(long)scale title:(NSString *)title
                         pinned:(BOOL)pinned radius:(long)radius style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash {
    NSString *text = title ?: @"";
    if (e->barValid && e->barWidth == width && e->barScale == scale && e->barRadius == radius && e->barPinned == pinned &&
        e->barStyle == styleHash && [e->barTitle isEqualToString:text]) {
        return e->barTexture;
    }
    long w = 0, h = 0;
    NSData *pixels = IFCRenderTitleBar(width, scale, text, pinned, radius, style, &w, &h);
    if (e->barTexture) [_graveyard bury:e->barTexture];
    e->barTexture = [self textureWithRGBA:pixels width:w height:h];
    e->barValid = YES;
    e->barWidth = width;
    e->barScale = scale;
    e->barRadius = radius;
    e->barPinned = pinned;
    e->barStyle = styleHash;
    e->barTitle = [text copy];
    return e->barTexture;
}

// suspended.rs `ensure_body`.
- (id<MTLTexture>)bodyTextureFor:(IFCEntry *)e width:(long)bodyW height:(long)bodyH scale:(long)scale
                           style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash {
    if (e->bodyValid && e->bodyW == bodyW && e->bodyH == bodyH && e->bodyScale == scale && e->bodyStyle == styleHash) return e->bodyTexture;
    long w = 0, h = 0;
    NSData *pixels = IFCRenderBodyFill(bodyW, bodyH, scale, style, &w, &h);
    if (e->bodyTexture) [_graveyard bury:e->bodyTexture];
    e->bodyTexture = [self textureWithRGBA:pixels width:w height:h];
    e->bodyValid = YES;
    e->bodyW = bodyW;
    e->bodyH = bodyH;
    e->bodyScale = scale;
    e->bodyStyle = styleHash;
    return e->bodyTexture;
}

// suspended.rs `ensure_label`.
- (id<MTLTexture>)labelTextureFor:(IFCEntry *)e name:(NSString *)name launching:(BOOL)launching width:(long)bodyW height:(long)bodyH
                            scale:(long)scale style:(IFCompositorChromeStyle *)style styleHash:(uint64_t)styleHash {
    if (e->labelValid && e->labelBodyW == bodyW && e->labelBodyH == bodyH && e->labelScale == scale && e->labelLaunching == launching &&
        e->labelStyle == styleHash && [e->labelText isEqualToString:name]) {
        return e->labelTexture;
    }
    // format!("{} launching…", display_name)
    NSString *text = launching ? [name stringByAppendingString:@" launching\u2026"] : name;
    long w = 0, h = 0;
    IFCRectI rect;
    NSData *pixels = IFCRenderLabel(text, bodyW, bodyH, scale, style, &w, &h, &rect);
    if (e->labelTexture) [_graveyard bury:e->labelTexture];
    e->labelTexture = pixels ? [self textureWithRGBA:pixels width:w height:h] : nil;
    e->labelValid = YES;
    e->labelBodyW = bodyW;
    e->labelBodyH = bodyH;
    e->labelScale = scale;
    e->labelLaunching = launching;
    e->labelStyle = styleHash;
    e->labelText = [name copy];
    e->labelBufW = w;
    e->labelBufH = h;
    e->labelRect = rect;
    return e->labelTexture;
}

- (id<MTLTexture>)placeholderTextureForColor:(IFCompositorColor)color {
    if (_placeholderTextureValid && memcmp(&color, &_placeholderTextureColor, sizeof color) == 0) return _placeholderTexture;
    if (_placeholderTexture) [_graveyard bury:_placeholderTexture];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    _placeholderTexture = [_device newTextureWithDescriptor:td];
    // Premultiplied, as every texture this renderer samples.
    double a = (double)color.a / 255.0;
    const uint8_t texel[4] = {IFCU8((double)color.r * a), IFCU8((double)color.g * a), IFCU8((double)color.b * a), color.a};
    [_placeholderTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:texel bytesPerRow:4];
    _placeholderTextureColor = color;
    _placeholderTextureValid = YES;
    return _placeholderTexture;
}

- (id<MTLTexture>)newBlurTextureWidth:(long)width height:(long)height {
    if (width <= 0 || height <= 0 || (NSUInteger)width > kIFCMaxTextureSide || (NSUInteger)height > kIFCMaxTextureSide) return nil;
    // Abgr8888 offscreens upstream; BGRA8 here, like every other target.
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:(NSUInteger)width
                                                                                 height:(NSUInteger)height
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:td];
    return texture;
}

// MARK: Frame

static unsigned IFCStackBucket(IFCompositorElementKind kind, IFCompositorStackLayer layer) {
    if (kind == IFCompositorElementKindSnapshot) return 2;
    switch (layer) {
        case IFCompositorStackLayerWidget: return 0;
        case IFCompositorStackLayerClosing: return 2;
        case IFCompositorStackLayerPinned: return 3;
        case IFCompositorStackLayerNormal:
        default: return 1;
    }
}

// This encode's elements, bottom to top: widgets, normal, closing, pinned
// (upstream's `all_elements` read backwards), each with its geometry and what
// its lifecycle animation makes of it.
- (void)collectItems:(IFCompositorFrame *)frame ctx:(const IFCFrameCtx *)c {
    _itemCount = 0;
    _blurRequested = NO;
    NSArray<IFCompositorElement *> *elements = frame.elements;
    NSUInteger count = elements.count;
    if (count > _itemCapacity) {
        IFCItem *grown = realloc(_items, count * sizeof(IFCItem));
        if (!grown) return;
        _items = grown;
        _itemCapacity = count;
    }
    double s = c->s, frameZoom = c->frameZoom;
    IFCRectI output = IFCRectIMake(0, 0, c->outW, c->outH);
    // The canvas normally supplies its already-applied stack order. Verify it
    // against current kind/layer values, then collect directly instead of
    // enumerating every element once per bucket. Arbitrary caller order keeps
    // the original stable four-pass partition; no order is cached across frames.
    BOOL ordered = YES;
    unsigned previous = 0;
    if (count > 1) for (IFCompositorElement *element in elements) {
        unsigned bucket = IFCStackBucket(element.kind, element.layer);
        if (bucket < previous) { ordered = NO; break; }
        previous = bucket;
    }
    for (unsigned bucket = 0; bucket < (ordered ? 1u : 4u); bucket++) {
        for (IFCompositorElement *element in elements) {
            IFCompositorElementKind kind = element.kind;
            if (!ordered && IFCStackBucket(kind, element.layer) != bucket) continue;

            IFCGeom g;
            CGRect rect = element.rect;
            switch (element.space) {
                case IFCompositorSpacePinned:
                    g.r = (IFCRectD){rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
                    g.zoom = 1.0;
                    break;
                case IFCompositorSpaceOutput:
                    // Not upstream's arithmetic: the quotient is not `loc - camera`
                    // to the last bit and can lose a rounding tie (deviation 10).
                    g.r = (IFCRectD){rect.origin.x / frameZoom, rect.origin.y / frameZoom, rect.size.width / frameZoom, rect.size.height / frameZoom};
                    g.zoom = frameZoom;
                    break;
                case IFCompositorSpaceCanvas:
                default:
                    // render_loc = loc - camera
                    g.r = (IFCRectD){rect.origin.x - frame.cameraX, rect.origin.y - frame.cameraY, rect.size.width, rect.size.height};
                    g.zoom = frameZoom;
                    break;
            }
            if (!isfinite(g.r.x) || !isfinite(g.r.y) || !isfinite(g.r.w) || !isfinite(g.r.h) || g.r.w <= 0 || g.r.h <= 0) continue;

            IFCItem item;
            memset(&item, 0, sizeof item);
            item.element = element;
            item.g = g;
            item.scissor = output;
            item.lifeAlpha = 1.0f;
            if (element.hasClipRect) {
                CGRect clip = element.clipRect;
                long x0 = IFCRound(clip.origin.x * s), y0 = IFCRound(clip.origin.y * s);
                long x1 = IFCRound((clip.origin.x + clip.size.width) * s), y1 = IFCRound((clip.origin.y + clip.size.height) * s);
                if (!IFCRectIIntersect(IFCRectIMake(x0, y0, x1 - x0, y1 - y0), output, &item.scissor)) continue;
            }
            if (element.hasTransform) {
                item.hasXform = YES;
                item.xform = element.transform;
            }

            if (kind == IFCompositorElementKindSnapshot) {
                // The snapshot's transform is its own shrink.
                item.hasXform = NO;
            }
            if (element.lifecycle != IFCompositorLifecycleNone) {
                IFCLife life = IFCResolveLife(element, frame.time, c->effects);
                BOOL closing = life.kind == IFCompositorLifecycleClosing || life.kind == IFCompositorLifecycleClosingAlphaOnly;
                // A close that has run out is gone, as upstream drops the
                // snapshot (or the fade); an open that has run out is the
                // plain window.
                if (closing && life.finished) continue;
                if (kind == IFCompositorElementKindSnapshot) {
                    if (closing) {
                        item.progress = life.progress;
                        item.alphaOnly = life.kind == IFCompositorLifecycleClosingAlphaOnly;
                    }
                } else if (closing) {
                    // closing.rs `StandInFade` (mod.rs `FadeRender`): fade, and
                    // shrink toward the centre of the frame it occupied — the
                    // body plus the bar strip above it.
                    item.lifeAlpha = IFCompositorCloseAlpha(life.progress);
                    double shrink = life.kind == IFCompositorLifecycleClosingAlphaOnly
                                        ? 1.0
                                        : IFCompositorCloseScale(life.progress, c->effects.animationScale);
                    item.hasXform = NO;
                    if (shrink < 1.0) {
                        BOOL barAbove = kind == IFCompositorElementKindStandIn || element.decoration.mode == IFCompositorDecorationModeServer;
                        double bar = barAbove ? (double)frame.chrome.titleBarHeight : 0.0;
                        double w = g.r.w, h = g.r.h;
                        if (kind == IFCompositorElementKindStandIn) {
                            w = (double)MAX(IFCRound(w), 0L);
                            h = (double)MAX(IFCRound(h), 0L);
                        }
                        item.hasXform = YES;
                        item.xform = (IFCompositorTransform){(g.r.x + w / 2.0) * g.zoom * s, (g.r.y - bar / 2.0 + h / 2.0) * g.zoom * s,
                                                             0.0, 0.0, shrink, shrink};
                    }
                } else if (life.kind == IFCompositorLifecycleOpening && kind == IFCompositorElementKindWindow && !life.finished) {
                    // window_animation.rs `animated_visual`, the Open entry, and
                    // mod.rs `compose_frame`'s `WindowRenderAnimation` from it.
                    double scale = IFCompositorOpenScale(life.progress, c->effects.animationScale);
                    // scaled_about_centre(Rectangle::new(target_loc, target_size), scale)
                    double vw = g.r.w * scale, vh = g.r.h * scale;
                    double vx = g.r.x + (g.r.w - vw) / 2.0, vy = g.r.y + (g.r.h - vh) / 2.0;
                    float alpha = IFCompositorOpenAlpha(life.progress);
                    if (vx != g.r.x || vy != g.r.y || vw != g.r.w || vh != g.r.h || alpha != 1.0f) {
                        double physicalZoom = s * g.zoom;
                        item.hasXform = YES;
                        // origin: the content's top-left; offset: how far the visual
                        // rect moved; scale: content_scale(v.size, target_size, false)
                        item.xform = (IFCompositorTransform){g.r.x * physicalZoom, g.r.y * physicalZoom,
                                                             (vx - g.r.x) * physicalZoom, (vy - g.r.y) * physicalZoom,
                                                             vw / fmax(g.r.w, 1.0), vh / fmax(g.r.h, 1.0)};
                        item.lifeAlpha = alpha;
                    }
                }
            }
            if (element.blur && kind == IFCompositorElementKindWindow) _blurRequested = YES;
            _items[_itemCount++] = item;
        }
    }
}

- (BOOL)encodeFrame:(IFCompositorFrame *)frame intoTexture:(id<MTLTexture>)target commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (!frame || !target || !commandBuffer || _resources.error) return NO;
    double s = (isfinite(frame.scale) && frame.scale > 0) ? frame.scale : 1.0;
    double frameZoom = (isfinite(frame.zoom) && frame.zoom > 0) ? frame.zoom : 1.0;
    long viewportW, viewportH;
    IFCPixelSize(frame, &viewportW, &viewportH, NULL, NULL);

    // From here on the command buffer samples this renderer's textures: what
    // is retired during or after this encode waits for it to complete.
    _generation++;
    _touched = 0;
    [_graveyard began];
    [commandBuffer addCompletedHandler:_completion];
    _skipShadow = NO;
    _hasXform = NO;
    _originX = _originY = 0;
    _internal = NO;
    _bake = NO;

    IFCFrameCtx ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.s = s;
    ctx.frameZoom = frameZoom;
    ctx.viewportW = viewportW;
    ctx.viewportH = viewportH;
    ctx.outW = (long)target.width;
    ctx.outH = (long)target.height;
    ctx.decorationScale = frame.decorationScale > 0 ? (long)frame.decorationScale : MAX(IFCCeil(s), 1L);
    ctx.styleHash = [frame.chrome ifc_hash];
    ctx.effects = IFCompositorEffectsSanitized(frame.effects);

    // Windows, bottom to top: widgets, normal, closing, pinned.
    [self collectItems:frame ctx:&ctx];

    // The frost of every blurred window, into textures of its own, before the
    // frame's pass opens. Nothing here runs unless an element asks for it.
    if (_blurRequested) {
        // A background with a chunk cache bakes or uploads inside its encode,
        // which comes after the frost keys: its chunk work for this frame is
        // done here instead, so that the frame a chunk lands in is the frame
        // that refreshes the frost. The same frame, field for field, as the
        // two encodes below: the cache answers each instant once.
        IFBackgroundFrame bg = {frame.cameraX, frame.cameraY, frameZoom, frame.size.width, frame.size.height, s, frame.time};
        ctx.backgroundGeneration = [frame.background chunkGenerationForFrame:bg];
        [self prepareFrosts:frame ctx:&ctx commandBuffer:commandBuffer];
    } else if (_hasBlurBeat || _bgCopy) {
        // No request left on this output: upstream's `remove_blur_caches`.
        _hasBlurBeat = NO;
        if (_bgCopy) [_graveyard bury:_bgCopy];
        _bgCopy = nil;
    }

    BOOL opaqueClear = frame.clear == IFCompositorClearOpaqueBlack;
    _pass.colorAttachments[0].texture = target;
    _pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, opaqueClear ? 1 : 0);
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:_pass];
    _pass.colorAttachments[0].texture = nil;
    if (!encoder) return NO;

    _encoder = encoder;
    _boundPipeline = nil;
    _target = IFCRectIMake(0, 0, (long)target.width, (long)target.height);
    _clip = _target;
    _boundScissor = _target;

    // Background (upstream's `bg_elements`), replacing the cleared pixels.
    IFBackgroundProgram *background = frame.background;
    if (background) {
        IFBackgroundFrame bg = {frame.cameraX, frame.cameraY, frameZoom, frame.size.width, frame.size.height, s, frame.time};
        if ([background encodeFrame:bg inEncoder:encoder] && opaqueClear && background.isTransparent) {
            // The background wrote premultiplied colour with its own alpha;
            // over the opaque clear a source-over blend leaves alpha at 1.
            _boundPipeline = nil;
            IFCUniforms u = IFCUniformsZero();
            u.color = simd_make_float4(0, 0, 0, 1);
            [self draw:IFCPipeAlphaOne dst:_target uniforms:&u texture:nil element:nil];
        }
        _boundPipeline = nil;
    }
    [encoder setFragmentSamplerState:_resources.sampler atIndex:0];

    // Outlines of other outputs' viewports: above the background, below every window.
    [self drawOutlines:frame scale:s viewportW:viewportW viewportH:viewportH];

    for (NSUInteger i = 0; i < _itemCount; i++) [self drawItem:&_items[i] frame:frame ctx:&ctx];

    // The error bar: above every window (and, upstream, every layer surface).
    [self drawErrorBar:frame ctx:&ctx];

    [encoder endEncoding];
    _encoder = nil;
    _boundPipeline = nil;
    _itemCount = 0;

    // Drop what this output no longer shows.
    if ((NSUInteger)CFDictionaryGetCount(_entries) > _touched) {
        _scan.count = 0;
        _scan.generation = _generation;
        CFDictionaryApplyFunction(_entries, IFCCollectStale, &_scan);
        for (NSUInteger i = 0; i < _scan.count; i++) {
            const void *key = (const void *)_scan.keys[i];
            [_graveyard bury:(__bridge IFCEntry *)CFDictionaryGetValue(_entries, key)];
            CFDictionaryRemoveValue(_entries, key);
        }
        _flushCountdown = 3;
    }
    if (_flushCountdown > 0) {
        _flushCountdown--;
        if (_textureCache->ref) CVMetalTextureCacheFlush(_textureCache->ref, 0);
    }
    [self ifc_flushAgedTextures];
    return YES;
}

// MARK: Closing snapshot (closing.rs)

static IFCRectD IFCMergeRects(IFCRectD a, IFCRectD b) {
    double x0 = fmin(a.x, b.x), y0 = fmin(a.y, b.y);
    double x1 = fmax(a.x + a.w, b.x + b.w), y1 = fmax(a.y + a.h, b.y + b.h);
    return (IFCRectD){x0, y0, x1 - x0, y1 - y0};
}

- (IFCompositorElement *)closingSnapshotOfElement:(IFCompositorElement *)element inFrame:(IFCompositorFrame *)frame
                                     flattenScale:(double)flattenScale {
    if (!element || !frame || _resources.error || element.kind != IFCompositorElementKindWindow) return nil;
    // flatten(renderer, pixels, flatten_scale.max(1.0), chrome)
    double scale = (isfinite(flattenScale) && flattenScale > 1.0) ? flattenScale : 1.0;
    double frameZoom = (isfinite(frame.zoom) && frame.zoom > 0) ? frame.zoom : 1.0;
    CGRect rect = element.rect;
    // The window's geometry in logical pixels before any zoom.
    double unit = element.space == IFCompositorSpaceOutput ? frameZoom : 1.0;
    double w = rect.size.width / unit, h = rect.size.height / unit;
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) || !isfinite(w) || !isfinite(h) || w <= 0 || h <= 0) return nil;

    IFCompositorDecoration deco = element.decoration;
    BOOL bare = deco.mode == IFCompositorDecorationModeNone;
    BOOL hasSSD = deco.mode == IFCompositorDecorationModeServer;
    long bw = bare ? 0 : MAX((long)deco.borderWidth, 0L);
    BOOL shadow = !bare && deco.shadow;
    IFCompositorChromeStyle *style = frame.chrome;

    // The picture's extent, with the content's top-left at the origin: the
    // body (content plus the SSD bar strip above it), the shadow's area and
    // the border's area. A bare window bakes its content alone.
    double bar = hasSSD ? (double)style.titleBarHeight : 0.0;
    IFCRectD body = {0.0, -bar, w, h + bar};
    IFCRectD bounds = body;
    if (shadow) {
        // shaders.rs `shadow_area_for(body)`
        long pad = IFCCeil((double)ceilf(deco.shadowRadius));
        IFCRectD area = {(double)(IFCRound(body.x) - pad), (double)(IFCRound(body.y) - pad), (double)(IFCRound(body.w) + 2 * pad),
                         (double)(IFCRound(body.h) + 2 * pad)};
        bounds = IFCMergeRects(bounds, area);
    }
    if (bw > 0) {
        // shaders.rs `border_area_for(body, border_width, scale)`
        float borderWPhys = (float)fmax(round((double)bw * scale), 1.0);
        long pad = IFCCeil(((double)borderWPhys + 1.0) / scale);
        IFCRectD area = {(double)(IFCRound(body.x) - pad), (double)(IFCRound(body.y) - pad), (double)(IFCRound(body.w) + 2 * pad),
                         (double)(IFCRound(body.h) + 2 * pad)};
        bounds = IFCMergeRects(bounds, area);
    }
    // closing.rs `phys_size_of`
    long physW = IFCCeil(bounds.w * scale), physH = IFCCeil(bounds.h * scale);
    if (physW <= 0 || physH <= 0 || (NSUInteger)physW > kIFCMaxTextureSide || (NSUInteger)physH > kIFCMaxTextureSide) return nil;

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:(NSUInteger)physW
                                                                                 height:(NSUInteger)physH
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!texture || !commandBuffer) return nil;
    [_graveyard began];
    [commandBuffer addCompletedHandler:_completion];

    // Painter's order: shadow, border, content, bar, over transparent — the
    // window as a frame at zoom 1 and alpha 1 would draw it.
    BOOL began = [self beginPassOn:texture width:physW height:physH load:MTLLoadActionClear clear:MTLClearColorMake(0, 0, 0, 0)
                     commandBuffer:commandBuffer];
    if (began) {
        IFCFrameCtx ctx;
        memset(&ctx, 0, sizeof ctx);
        ctx.s = scale;
        ctx.frameZoom = 1.0;
        ctx.outW = physW;
        ctx.outH = physH;
        double frameScale = (isfinite(frame.scale) && frame.scale > 0) ? frame.scale : 1.0;
        ctx.decorationScale = frame.decorationScale > 0 ? (long)frame.decorationScale : MAX(IFCCeil(frameScale), 1L);
        ctx.styleHash = [style ifc_hash];
        ctx.effects = IFCompositorEffectsSanitized(frame.effects);
        IFCItem item;
        memset(&item, 0, sizeof item);
        item.element = element;
        item.g = (IFCGeom){{-bounds.x, -bounds.y, w, h}, 1.0};
        item.scissor = IFCRectIMake(0, 0, physW, physH);
        item.lifeAlpha = 1.0f;
        _skipShadow = NO;
        _originX = _originY = 0;
        _internal = YES;
        _bake = YES;
        [self drawItem:&item frame:frame ctx:&ctx];
        _internal = NO;
        _bake = NO;
        [self endPass];
    }
    [commandBuffer commit];
    if (!began) return nil;

    IFCompositorElement *snapshot = [IFCompositorElement new];
    snapshot.identifier = element.identifier;
    snapshot.kind = IFCompositorElementKindSnapshot;
    snapshot.space = element.space;
    snapshot.layer = IFCompositorStackLayerClosing;
    if (element.space == IFCompositorSpacePinned) {
        // snapshot_screen: screen_origin + bounds.loc.round(), bounds.size.to_i32_round()
        snapshot.rect = CGRectMake(rect.origin.x + round(bounds.x), rect.origin.y + round(bounds.y), (CGFloat)IFCRound(bounds.w),
                                   (CGFloat)IFCRound(bounds.h));
    } else {
        // snapshot_canvas: Rectangle::new(window_origin + bounds.loc, bounds.size)
        snapshot.rect = CGRectMake(rect.origin.x + bounds.x * unit, rect.origin.y + bounds.y * unit, bounds.w * unit, bounds.h * unit);
    }
    snapshot.hasClipRect = element.hasClipRect;
    snapshot.clipRect = element.clipRect;
    snapshot.texture = texture;
    snapshot.lifecycle = IFCompositorLifecycleClosing;
    snapshot.lifecycleProgress = 0.0;
    return snapshot;
}

// MARK: Offscreen export

- (id<MTLTexture>)renderOffscreen:(IFCompositorFrame *)frame error:(NSError **)error {
    NSUInteger w, h;
    IFCPixelSize(frame, NULL, NULL, &w, &h);
    if (_resources.error || w == 0 || h == 0 || w > kIFCMaxTextureSide || h > kIFCMaxTextureSide) {
        if (error) *error = [NSError errorWithDomain:IFCErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:
            _resources.error ?: [NSString stringWithFormat:@"invalid render size %lux%lu pixels", (unsigned long)w, (unsigned long)h]}];
        return nil;
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!target || !commandBuffer) {
        if (error) *error = [NSError errorWithDomain:IFCErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: @"could not allocate the render target"}];
        return nil;
    }
    BOOL encoded = [self encodeFrame:frame intoTexture:target commandBuffer:commandBuffer];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (!encoded || commandBuffer.status != MTLCommandBufferStatusCompleted) {
        if (error) *error = commandBuffer.error ?: [NSError errorWithDomain:IFCErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey: @"the render did not complete"}];
        return nil;
    }
    return target;
}

static uint8_t *IFCCopyBytes(id<MTLTexture> texture) {
    NSUInteger w = texture.width, h = texture.height;
    uint8_t *bytes = malloc(w * h * 4);
    if (bytes) [texture getBytes:bytes bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    return bytes;
}

- (CGImageRef)newImageForFrame:(IFCompositorFrame *)frame error:(NSError **)error {
    id<MTLTexture> target = [self renderOffscreen:frame error:error];
    if (!target) return NULL;
    uint8_t *bytes = IFCCopyBytes(target);
    if (!bytes) return NULL;
    return IFCCreateImage(bytes, target.width, target.height, frame.clear == IFCompositorClearTransparent);
}
@end
