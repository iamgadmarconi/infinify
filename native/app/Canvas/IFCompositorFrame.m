// SPDX-License-Identifier: GPL-3.0-or-later
//
// Infinify compositor — the frame description: the public value helpers, chrome
// style, elements, lifecycle resolution and frames. See IFCompositor.h and
// COMPOSITOR-NOTES.md (under docs/).
//
// Derived from DriftWM (GPL-3.0-or-later), https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d. Each section names the upstream
// function it mirrors; expressions are kept in upstream's order and upstream's
// numeric types (f32 where upstream narrows to f32, Rust rounding and cast
// rules) so the two can be read side by side.

#import "IFCompositor+Private.h"
#import "DWMetalSupport.h"

#import <IOSurface/IOSurface.h>

// closing.rs DONE_EPSILON, window_animation.rs PROGRESS_DONE_EPSILON.
static const double kIFCAnimationDoneEpsilon = 0.01;

// MARK: - Public value helpers

IFCompositorDecoration IFCompositorDecorationDefault(void) {
    IFCompositorDecoration d;
    memset(&d, 0, sizeof d);
    d.mode = IFCompositorDecorationModeClient;                       // default_mode: DecorationMode::Client
    d.borderWidth = 0;                                               // border_width: 0
    d.borderColor = IFCompositorColorMake(0x30, 0x30, 0x30, 0xFF);   // border_color
    d.borderColorFocused = IFCompositorColorMake(0x30, 0x30, 0x30, 0xFF);
    d.cornerRadius = 10;                                             // corner_radius: 10
    d.shadow = YES;                                                  // shadow: true
    d.shadowRadius = 14.0f;                                          // DecorationConfig::SHADOW_RADIUS
    d.shadowColor = IFCompositorColorMake(0x00, 0x00, 0x00, 0x66);   // DecorationConfig::SHADOW_COLOR
    d.opacity = 1.0;                                                 // opacity / opacity_focused: 1.0
    return d;
}

IFCompositorOutlineSettings IFCompositorOutlineSettingsDefault(void) {
    IFCompositorOutlineSettings o;
    memset(&o, 0, sizeof o);
    o.color = IFCompositorColorMake(0xFF, 0xFF, 0xFF, 0xFF);
    o.thickness = 1;
    o.opacity = 0.5;
    return o;
}

// canvas.rs `coverage`.
IFCompositorCoverage IFCompositorCoverageOfFrame(CGRect frame, CGRect usable) {
    const double NOISE = 1e-6;
    const double shortfall[4] = {
        frame.origin.x - usable.origin.x,
        frame.origin.y - usable.origin.y,
        (usable.origin.x + usable.size.width) - (frame.origin.x + frame.size.width),
        (usable.origin.y + usable.size.height) - (frame.origin.y + frame.size.height),
    };
    BOOL any = NO;
    for (int i = 0; i < 4; i++) {
        if (!(shortfall[i] <= NOISE)) return IFCompositorCoverageNone;  // NaN reads as no coverage
        if (shortfall[i] < -NOISE) any = YES;
    }
    return any ? IFCompositorCoverageOverhang : IFCompositorCoverageExact;
}

// chrome.rs `DrawnChrome::drawn`.
IFCompositorDecoration IFCompositorDecorationDrawn(IFCompositorDecoration c, BOOL fullscreen, IFCompositorCoverage coverage) {
    if (fullscreen) {
        // DrawnChrome::NONE — no bar, no border, square, no shadow; the surface
        // is passed through unclipped.
        c.mode = IFCompositorDecorationModeNone;
        c.borderWidth = 0;
        c.cornerRadius = 0;
        c.shadow = NO;
        return c;
    }
    switch (coverage) {
        case IFCompositorCoverageNone:
            break;
        case IFCompositorCoverageExact:
            c.cornerRadius = 0;
            c.shadow = NO;
            break;
        case IFCompositorCoverageOverhang:
            c.borderWidth = 0;
            c.cornerRadius = 0;
            c.shadow = NO;
            break;
    }
    return c;
}

// mod.rs `build_output_outline_elements` + canvas.rs `visible_canvas_rect`.
CGRect IFCompositorOutlineRect(double cameraX, double cameraY, double zoom,
                               double otherCameraX, double otherCameraY, CGSize otherSize, double otherZoom) {
    if (!(isfinite(otherZoom) && otherZoom > 0)) otherZoom = 1.0;
    // visible_canvas_rect(other_camera.to_i32_round(), other_size, other_zoom)
    long canvasX = IFCRound(otherCameraX), canvasY = IFCRound(otherCameraY);
    long canvasW = IFCCeil((double)IFCRound(otherSize.width) / otherZoom) + 2;
    long canvasH = IFCCeil((double)IFCRound(otherSize.height) / otherZoom) + 2;
    // ((other_canvas.loc.x as f64 - camera.x) * zoom) as i32 — truncation.
    long screenX = IFCTrunc(((double)canvasX - cameraX) * zoom);
    long screenY = IFCTrunc(((double)canvasY - cameraY) * zoom);
    long screenW = IFCTrunc((double)canvasW * zoom);
    long screenH = IFCTrunc((double)canvasH * zoom);
    return CGRectMake(screenX, screenY, screenW, screenH);
}

// state/suspended.rs `standin_body_rect`.
CGRect IFCompositorStandInBodyRect(CGRect windowRect, BOOL clientDecorated, NSInteger titleBarHeight) {
    if (!clientDecorated) return windowRect;
    double bar = (double)titleBarHeight;
    // let body_h = (rect.size.h - bar).max(1);
    double bodyH = fmax(windowRect.size.height - bar, 1.0);
    return CGRectMake(windowRect.origin.x, windowRect.origin.y + bar, windowRect.size.width, bodyH);
}

// config/types.rs `EffectsConfig::default`.
IFCompositorEffects IFCompositorEffectsDefault(void) {
    IFCompositorEffects e;
    memset(&e, 0, sizeof e);
    e.blurRadius = 2;
    e.blurStrength = 1.1;
    e.animateBlurFPS = 20;
    e.animationSpeed = 0.5;
    e.animationScale = 0.95;
    return e;
}

// config/parse_helpers.rs `unit_range_or_default`.
static double IFCUnitRangeOrDefault(double v, double fallback) {
    if (isnan(v) || v <= 0.0) return fallback;
    return fmin(v, 1.0);
}

// config/parse_helpers.rs `parse_effects_config`.
IFCompositorEffects IFCompositorEffectsSanitized(IFCompositorEffects e) {
    // non_negative(blur_strength): negative or NaN -> 0.
    if (!(e.blurStrength >= 0.0) || !isfinite(e.blurStrength)) e.blurStrength = 0.0;
    e.animateBlurFPS = MIN(e.animateBlurFPS, 144u);
    e.animationSpeed = IFCUnitRangeOrDefault(e.animationSpeed, 0.5);
    e.animationScale = IFCUnitRangeOrDefault(e.animationScale, 0.95);
    return e;
}

// window_animation_driver.rs `tick_window_animations_at`:
//   frame_factor = 1 - (1 - speed).powf(dt * 60);  progress += (1 - progress) * frame_factor
// so `1 - progress` is multiplied by (1 - speed)^(dt * 60) every tick, and
// after ticks adding up to `elapsed` it is (1 - speed)^(elapsed * 60).
double IFCompositorAnimationProgress(double elapsed, double animationSpeed) {
    if (!(elapsed > 0.0)) return 0.0;
    double speed = IFCUnitRangeOrDefault(animationSpeed, 0.5);
    return 1.0 - pow(1.0 - speed, elapsed * 60.0);
}

// closing.rs `ClosingSnapshot::is_done`, window_animation.rs `tick_entry`.
BOOL IFCompositorAnimationFinished(double progress) {
    return 1.0 - progress <= kIFCAnimationDoneEpsilon;
}

double IFCompositorAnimationDuration(double animationSpeed) {
    double speed = IFCUnitRangeOrDefault(animationSpeed, 0.5);
    if (speed >= 1.0) return 0.0;
    return log(kIFCAnimationDoneEpsilon) / (60.0 * log(1.0 - speed));
}

// closing.rs `fade_out_alpha`.
float IFCompositorCloseAlpha(double progress) {
    double p = fmin(fmax(progress, 0.0), 1.0);
    return (float)(1.0 - p * p);
}

// closing.rs `ClosingSnapshot::render_element` / `StandInFade::shrink_scale`.
double IFCompositorCloseScale(double progress, double amplitude) {
    return 1.0 - (1.0 - amplitude) * progress;
}

// window_animation.rs `open_alpha` (called with p clamped to 0..1).
float IFCompositorOpenAlpha(double progress) {
    double p = fmin(fmax(progress, 0.0), 1.0);
    return (float)(1.0 - (1.0 - p) * (1.0 - p));
}

// window_animation.rs `open_scale`.
double IFCompositorOpenScale(double progress, double amplitude) {
    return amplitude + (1.0 - amplitude) * progress;
}

// error_bar.rs `join_errors`: `m.split_whitespace().collect::<Vec<_>>().join(" ")`
// per message, the messages joined with SEPARATOR.
NSString *IFCompositorErrorBarText(NSArray<NSString *> *messages) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:messages.count];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSString *message in messages) {
        NSMutableArray<NSString *> *words = [NSMutableArray array];
        for (NSString *word in [message componentsSeparatedByCharactersInSet:whitespace]) {
            if (word.length) [words addObject:word];
        }
        [lines addObject:[words componentsJoinedByString:@" "]];
    }
    return [lines componentsJoinedByString:@"  \u2022  "];
}

// error_bar.rs: `ERROR_BAR_FONT_PX.ceil() as i32 + 2 * ERROR_BAR_PAD_Y`.
NSInteger IFCompositorErrorBarHeight(void) {
    return (NSInteger)(IFCTrunc((double)ceilf(kIFCErrorBarFontPx)) + 2 * kIFCErrorBarPadY);
}

static uint64_t IFCStringFingerprint(NSString *s) {
    uint64_t h = 0xcbf29ce484222325ULL;
    IFCMixString(&h, s);
    return h;
}

// MARK: - Chrome style

@implementation IFCompositorChromeStyle

- (instancetype)init {
    if (!(self = [super init])) return nil;
    // config/types.rs `DecorationConfig::default()`
    _backgroundColor = IFCompositorColorMake(0x30, 0x30, 0x30, 0xFF);
    _foregroundColor = IFCompositorColorMake(0xFF, 0xFF, 0xFF, 0xFF);
    _cornerRadius = 10;
    _titleBarHeight = 25;
    _font = @"Adwaita Sans";
    _fontSize = 11;
    _fontWeight = IFCompositorFontWeightMedium;
    _titleAlign = IFCompositorTitleAlignCenter;
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    IFCompositorChromeStyle *c = [[IFCompositorChromeStyle allocWithZone:zone] init];
    c.backgroundColor = _backgroundColor;
    c.foregroundColor = _foregroundColor;
    c.cornerRadius = _cornerRadius;
    c.titleBarHeight = _titleBarHeight;
    c.font = _font;
    c.fontSize = _fontSize;
    c.fontWeight = _fontWeight;
    c.titleAlign = _titleAlign;
    return c;
}

- (void)setFont:(NSString *)font {
    _font = [font copy] ?: @"";
}

- (uint64_t)ifc_hash {
    uint64_t h = 0xcbf29ce484222325ULL;
    IFCMixColor(&h, _backgroundColor);
    IFCMixColor(&h, _foregroundColor);
    IFC_MIX(&h, (int64_t)_cornerRadius);
    IFC_MIX(&h, (int64_t)_titleBarHeight);
    IFCMixString(&h, _font);
    IFC_MIX(&h, (uint64_t)_fontSize);
    IFC_MIX(&h, (int64_t)_fontWeight);
    IFC_MIX(&h, (int64_t)_titleAlign);
    return h;
}
@end

// MARK: - Element

@implementation IFCompositorElement {
    uint64_t _titleFingerprint, _appNameFingerprint;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _decoration = IFCompositorDecorationDefault();
    _contentRect = CGRectNull;
    _transform = (IFCompositorTransform){0, 0, 0, 0, 1, 1};
    _lifecycleStartTime = NAN;
    _titleFingerprint = _appNameFingerprint = IFCStringFingerprint(nil);
    return self;
}

- (void)dealloc {
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
}

- (void)setPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (pixelBuffer == _pixelBuffer) return;
    if (pixelBuffer) CVPixelBufferRetain(pixelBuffer);
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
    _pixelBuffer = pixelBuffer;
}

// These properties own immutable copies, so every UTF-16 unit needs hashing
// only when the text changes. Redraw and backdrop keys reuse the scalar on
// pixel/camera frames; NSString's sampled -hash would miss long-title edits.
- (void)setTitle:(NSString *)title {
    if (_title == title || (title && [_title isEqualToString:title])) return;
    _title = [title copy];
    _titleFingerprint = IFCStringFingerprint(_title);
}

- (void)setAppName:(NSString *)appName {
    if (_appName == appName || (appName && [_appName isEqualToString:appName])) return;
    _appName = [appName copy];
    _appNameFingerprint = IFCStringFingerprint(_appName);
}

// The identity of the content's pixels: the buffer object and its surface's
// change seed, or the texture object; plus the host's own generation counter.
- (void)ifc_mixContentIdentity:(uint64_t *)h {
    IFC_MIX(h, (uintptr_t)_pixelBuffer);
    if (_pixelBuffer) {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(_pixelBuffer);
        IFC_MIX(h, surface ? IOSurfaceGetID(surface) : 0u);
        IFC_MIX(h, surface ? IOSurfaceGetSeed(surface) : 0u);
    }
    IFC_MIX(h, (uintptr_t)(__bridge void *)_texture);
    IFC_MIX(h, _contentGeneration);
}

// Everything that decides how the element is drawn. With `content` NO the
// identity of the content's pixels is left out (whether there is content at
// all stays in): what a blurred window's own frost is keyed on, since the
// frost does not show the window's content, only its shape.
- (void)ifc_mix:(uint64_t *)h content:(BOOL)content {
    IFC_MIX(h, _identifier);
    IFC_MIX(h, (int64_t)_kind);
    IFCMixRect(h, _rect);
    IFC_MIX(h, (int64_t)_space);
    IFC_MIX(h, (int64_t)_layer);
    IFC_MIX(h, (uint8_t)_hasClipRect);
    if (_hasClipRect) IFCMixRect(h, _clipRect);
    IFC_MIX(h, (uint8_t)_focused);
    IFC_MIX(h, (int64_t)_decoration.mode);
    IFC_MIX(h, _decoration.borderWidth);
    IFCMixColor(h, _decoration.borderColor);
    IFCMixColor(h, _decoration.borderColorFocused);
    IFC_MIX(h, _decoration.cornerRadius);
    IFC_MIX(h, (uint8_t)_decoration.shadow);
    IFC_MIX(h, _decoration.shadowRadius);
    IFCMixColor(h, _decoration.shadowColor);
    IFC_MIX(h, _decoration.opacity);
    if (content) {
        [self ifc_mixContentIdentity:h];
    } else {
        IFC_MIX(h, (uint8_t)(_pixelBuffer != NULL));
        IFC_MIX(h, (uint8_t)(_texture != nil));
    }
    IFCMixRect(h, _contentRect);
    IFC_MIX(h, (uint8_t)_contentOpaque);
    IFC_MIX(h, _titleFingerprint);
    IFC_MIX(h, _appNameFingerprint);
    IFC_MIX(h, (uint8_t)_launching);
    IFC_MIX(h, (uint8_t)_showsPinnedIndicator);
    IFC_MIX(h, (uint8_t)_hasTransform);
    if (_hasTransform) IFCMix(h, &_transform, sizeof _transform);
    IFC_MIX(h, (uint8_t)_blur);
    // The lifecycle's own progress is mixed by the frame: it depends on its time.
    IFC_MIX(h, (int64_t)_lifecycle);
}
@end

IFCLife IFCResolveLife(IFCompositorElement *element, double time, IFCompositorEffects effects) {
    IFCLife life = {element.lifecycle, 0.0, NO, NO};
    if (life.kind != IFCompositorLifecycleOpening && life.kind != IFCompositorLifecycleClosing &&
        life.kind != IFCompositorLifecycleClosingAlphaOnly) {
        life.kind = IFCompositorLifecycleNone;
        return life;
    }
    double start = element.lifecycleStartTime;
    double p;
    if (isnan(start)) {
        p = element.lifecycleProgress;
    } else {
        life.timed = YES;
        p = IFCompositorAnimationProgress(time - start, effects.animationSpeed);
    }
    if (isnan(p)) p = 0.0;
    life.progress = fmin(fmax(p, 0.0), 1.0);
    life.finished = IFCompositorAnimationFinished(life.progress);
    return life;
}

// MARK: - Frame

@implementation IFCompositorFrame {
    CGRect *_outlineRects;
    NSUInteger _outlineCount, _outlineCapacity;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _scale = 1.0;
    _zoom = 1.0;
    _chrome = [IFCompositorChromeStyle new];
    _placeholderColor = _chrome.backgroundColor;
    _elements = [NSMutableArray array];
    _outline = IFCompositorOutlineSettingsDefault();
    _effects = IFCompositorEffectsDefault();
    return self;
}

- (void)dealloc {
    free(_outlineRects);
}

- (void)setChrome:(IFCompositorChromeStyle *)chrome {
    _chrome = [chrome copy] ?: [IFCompositorChromeStyle new];
}

- (void)setOutlineRects:(const CGRect *)rects count:(NSUInteger)count {
    if (!rects) count = 0;
    if (count > _outlineCapacity) {
        CGRect *grown = realloc(_outlineRects, count * sizeof(CGRect));
        if (!grown) return;
        _outlineRects = grown;
        _outlineCapacity = count;
    }
    if (count) memcpy(_outlineRects, rects, count * sizeof(CGRect));
    _outlineCount = count;
}

- (NSUInteger)outlineRectCount {
    return _outlineCount;
}

- (const CGRect *)ifc_outlineRects {
    return _outlineRects;
}

// The background draws and moves on its own (upstream's animated shader).
- (BOOL)ifc_backgroundAnimates {
    return _background.isAnimated;
}

- (double)lifecycleProgressOfElement:(IFCompositorElement *)element {
    if (!element) return 0.0;
    return IFCResolveLife(element, _time, IFCompositorEffectsSanitized(_effects)).progress;
}

- (BOOL)lifecycleFinishedForElement:(IFCompositorElement *)element {
    if (!element) return YES;
    IFCLife life = IFCResolveLife(element, _time, IFCompositorEffectsSanitized(_effects));
    return life.kind == IFCompositorLifecycleNone || life.finished;
}

// An open / close animation that runs on the frame's clock is still running.
- (BOOL)ifc_lifecycleRuns {
    IFCompositorEffects effects = IFCompositorEffectsSanitized(_effects);
    for (IFCompositorElement *element in _elements) {
        if (element.lifecycle == IFCompositorLifecycleNone) continue;
        IFCLife life = IFCResolveLife(element, _time, effects);
        if (life.kind != IFCompositorLifecycleNone && life.timed && !life.finished) return YES;
    }
    return NO;
}

- (BOOL)needsContinuousRedraw {
    return [self ifc_backgroundAnimates] || [self ifc_lifecycleRuns];
}

// Everything that decides the picture except `time`. (`time` enters only
// through the progress of an animation that runs on it: the fingerprint then
// changes on every tick until the animation is over, and not after.)
- (uint64_t)ifc_fingerprint {
    uint64_t h = 0xcbf29ce484222325ULL;
    IFC_MIX(&h, _size.width);
    IFC_MIX(&h, _size.height);
    IFC_MIX(&h, _scale);
    IFC_MIX(&h, _cameraX);
    IFC_MIX(&h, _cameraY);
    IFC_MIX(&h, _zoom);
    IFC_MIX(&h, (uintptr_t)(__bridge void *)_background);
    IFC_MIX(&h, (int64_t)_clear);
    IFC_MIX(&h, [_chrome ifc_hash]);
    IFC_MIX(&h, (int64_t)_decorationScale);
    IFCMixColor(&h, _placeholderColor);
    IFCMixColor(&h, _outline.color);
    IFC_MIX(&h, _outline.thickness);
    IFC_MIX(&h, _outline.opacity);
    IFC_MIX(&h, (uint64_t)_outlineCount);
    for (NSUInteger i = 0; i < _outlineCount; i++) IFCMixRect(&h, _outlineRects[i]);
    IFCompositorEffects effects = IFCompositorEffectsSanitized(_effects);
    IFC_MIX(&h, effects.blurRadius);
    IFC_MIX(&h, effects.blurStrength);
    IFC_MIX(&h, effects.animateBlurFPS);
    IFC_MIX(&h, effects.animationSpeed);
    IFC_MIX(&h, effects.animationScale);
    IFC_MIX(&h, (uint64_t)_errorMessages.count);
    for (NSString *message in _errorMessages) IFCMixString(&h, message);
    IFC_MIX(&h, (uint64_t)_elements.count);
    for (IFCompositorElement *element in _elements) {
        [element ifc_mix:&h content:YES];
        if (element.lifecycle != IFCompositorLifecycleNone) {
            IFCLife life = IFCResolveLife(element, _time, effects);
            IFC_MIX(&h, (uint8_t)life.finished);
            IFC_MIX(&h, life.finished ? 1.0 : life.progress);
        }
    }
    return h;
}
@end

// Integer output size, as upstream's logical output size is integral.
void IFCPixelSize(IFCompositorFrame *f, long *logicalW, long *logicalH, NSUInteger *pxW, NSUInteger *pxH) {
    DWMetalPixelSize(f.size.width, f.size.height, f.scale, logicalW, logicalH, pxW, pxH);
}
