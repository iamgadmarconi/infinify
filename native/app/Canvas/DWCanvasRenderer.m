// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from DriftWM, https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/ipc/mod.rs (cmd_screenshot,
// resolve_screenshot_region, window_visual_rect, snap_rect_to_rect, union_rect:
// what each screenshot target captures),
// src/render/screenshot.rs (capture_region_to_png: the scale rule, the 16384 px
// limit and their refusals), src/state/mod.rs (output_viewport_rect),
// src/canvas.rs (rule_to_internal), src/render/capture_background.rs (wallpaper_dest
// and the Wallpaper arm of tile_elements: where a capture shows a wallpaper) and
// src/render/mod.rs (compose_capture_elements: the opacity of a window captured
// alone; what a canvas capture leaves out: a screen-pinned window is never in one,
// a widget is drawn below the other windows). The frame description is the host
// protocol of the compositor (IFCompositor.h): canvas-space elements bottom to
// top from the controller's placements, a widget in the widget layer and a
// screen-pinned window in the pinned layer and the pinned space (upstream
// compose_frame's zoomed_widgets and zoomed_pinned buckets, and
// window_render_transform in src/state/output.rs: a pin's output-relative point at
// zoom 1), DrawnChrome's coverage rule per output, upstream's stand-in body
// rectangle and its projection of the other outputs' viewports. The effects are the
// compositor's (docs/native/app/Canvas/COMPOSITOR-NOTES.md, section 18), with src/state/errors.rs (ErrorSource:
// the order of the error bar's messages) and src/state/window_animation_driver.rs
// (start_window_open_animation, snapshot_closing_window, flatten_scale_for_canvas_rect:
// an event on no output animates nothing, and the density a closing window is baked
// at). The background's chunk caches (a baked cache_shader, a pyramidal TIFF's chunks)
// are the background module's (docs/native/app/Canvas/BACKGROUND-NOTES.md, section 17); from here come
// upstream's one cache per output and its shrink while a fullscreen window conceals the
// canvas (src/render/mod.rs, the bg_elements of compose_frame), the frames that keep
// coming while a cache fills (has_pending_bakes and has_pending_loads, as
// src/backend/udev.rs asks them) and what a capture draws instead of a cache
// (src/render/capture_background.rs, CaptureBackground::prepare).
// New code over the controller's snapshot; cameras, world rectangles and pinned
// screen rectangles are the controller's, and no native window geometry is read.
#import "DWCanvasRenderer+Private.h"
#import "DWTypedValue.h"
#import "DWGeometryJSON.h"
#import <AppKit/AppKit.h>
#import "DWScreenshotWriter.h"

NSArray *list(id value) { return [value isKindOfClass:NSArray.class]?value:@[]; }
BOOL validAttachment(DWCanvasAttachment *image) {
    if(![image isKindOfClass:DWCanvasAttachment.class]||!image.buffer||!DWFiniteRect(image.unitRect))return NO;
    CGRect crop=image.contentRect;if(CGRectIsNull(crop))return YES;
    return DWFiniteRect(crop)&&crop.origin.x>=0&&crop.origin.y>=0&&CGRectGetMaxX(crop)<=CVPixelBufferGetWidth(image.buffer)&&CGRectGetMaxY(crop)<=CVPixelBufferGetHeight(image.buffer);
}
CGPoint pointOf(id value) { NSDictionary *p=DWTyped(value,NSDictionary.class);return CGPointMake([DWTyped(p[@"x"],NSNumber.class)doubleValue],[DWTyped(p[@"y"],NSNumber.class)doubleValue]); }
// The controller's {origin:{x,y},size:{width,height}}; CGRectNull for anything else.
CGRect rectOf(id value) {
    NSDictionary *r=DWTyped(value,NSDictionary.class),*origin=DWTyped(r[@"origin"],NSDictionary.class),*size=DWTyped(r[@"size"],NSDictionary.class);if(!DWTyped(origin[@"x"],NSNumber.class)||!DWTyped(origin[@"y"],NSNumber.class)||!DWTyped(size[@"width"],NSNumber.class)||!DWTyped(size[@"height"],NSNumber.class))return CGRectNull;
    return CGRectMake([DWTyped(origin[@"x"],NSNumber.class)doubleValue],[DWTyped(origin[@"y"],NSNumber.class)doubleValue],[DWTyped(size[@"width"],NSNumber.class)doubleValue],[DWTyped(size[@"height"],NSNumber.class)doubleValue]);
}
BOOL currentDrawnPlacement(NSDictionary *p) {
    NSString *kind=DWTyped(p[@"kind"],NSString.class);
    return ([kind isEqual:@"window"]||[kind isEqual:@"standin"])&&DWTyped(p[@"focused"],NSNumber.class)&&DWFiniteRect(rectOf(p[@"world_rect"]));
}
BOOL currentOutputPlacement(NSDictionary *p) {
    return currentDrawnPlacement(p)&&DWTyped(p[@"window"],NSNumber.class)&&DWTyped(p[@"output"],NSNumber.class);
}
BOOL currentOutputPlacements(id value) {
    if(![value isKindOfClass:NSArray.class])return NO;
    for(id entry in value)if(!currentOutputPlacement(DWTyped(entry,NSDictionary.class)))return NO;
    return YES;
}
static BOOL drawableOutput(NSDictionary *output) {
    NSDictionary *camera=DWTyped(output[@"camera"],NSDictionary.class);NSNumber *zoom=DWTyped(output[@"zoom"],NSNumber.class),*identifier=DWTyped(output[@"id"],NSNumber.class);
    return identifier&&isfinite(identifier.doubleValue)&&identifier.doubleValue>0&&floor(identifier.doubleValue)==identifier.doubleValue&&identifier.unsignedLongLongValue>0&&DWFiniteRect(rectOf(output[@"screen_bounds"]))&&DWTyped(camera[@"x"],NSNumber.class)&&DWTyped(camera[@"y"],NSNumber.class)&&isfinite([camera[@"x"]doubleValue])&&isfinite([camera[@"y"]doubleValue])&&isfinite(zoom.doubleValue)&&zoom.doubleValue>0;
}
// A straight-alpha sRGB [r,g,b,a] in 0..1 back to upstream's [u8; 4].
static IFCompositorColor colorOf(id value,IFCompositorColor fallback) {
    NSArray *c=list(value);uint8_t bytes[4];if(c.count!=4)return fallback;
    for(NSUInteger i=0;i<4;i++){NSNumber *n=DWTyped(c[i],NSNumber.class);if(!n)return fallback;bytes[i]=(uint8_t)lround(fmin(fmax(n.doubleValue,0),1)*255);}
    return IFCompositorColorMake(bytes[0],bytes[1],bytes[2],bytes[3]);
}
// Upstream FontWeight by any of the names its config accepts, however the word is joined.
static IFCompositorFontWeight weightOf(NSString *name) {
    NSString *word=name.lowercaseString?:@"";for(NSString *joint in @[@"-",@"_",@" "])word=[word stringByReplacingOccurrencesOfString:joint withString:@""];
    NSDictionary<NSString *,NSNumber *> *weights=@{@"thin":@(IFCompositorFontWeightThin),@"hairline":@(IFCompositorFontWeightThin),@"extralight":@(IFCompositorFontWeightExtraLight),@"ultralight":@(IFCompositorFontWeightExtraLight),@"light":@(IFCompositorFontWeightLight),@"normal":@(IFCompositorFontWeightNormal),@"regular":@(IFCompositorFontWeightNormal),@"medium":@(IFCompositorFontWeightMedium),@"semibold":@(IFCompositorFontWeightSemiBold),@"demibold":@(IFCompositorFontWeightSemiBold),@"bold":@(IFCompositorFontWeightBold),@"extrabold":@(IFCompositorFontWeightExtraBold),@"ultrabold":@(IFCompositorFontWeightExtraBold),@"black":@(IFCompositorFontWeightBlack),@"heavy":@(IFCompositorFontWeightBlack)};
    NSNumber *weight=weights[word];return weight?(IFCompositorFontWeight)weight.integerValue:IFCompositorFontWeightMedium;
}
// A placement's resolved decoration. Without one: upstream's defaults at the configured radius.
static IFCompositorDecoration decorationOf(NSDictionary *d,NSInteger radius) {
    IFCompositorDecoration v=IFCompositorDecorationDefault();v.cornerRadius=(int32_t)radius;if(!d)return v;
    NSString *mode=DWTyped(d[@"mode"],NSString.class);
    v.mode=[mode isEqual:@"server"]?IFCompositorDecorationModeServer:[mode isEqual:@"minimal"]?IFCompositorDecorationModeMinimal:[mode isEqual:@"none"]?IFCompositorDecorationModeNone:IFCompositorDecorationModeClient;
    if(DWTyped(d[@"border_width"],NSNumber.class))v.borderWidth=(int32_t)lround([d[@"border_width"]doubleValue]);
    v.borderColor=colorOf(d[@"border_color"],v.borderColor);v.borderColorFocused=colorOf(d[@"border_color_focused"],v.borderColorFocused);
    if(DWTyped(d[@"corner_radius"],NSNumber.class))v.cornerRadius=(int32_t)lround([d[@"corner_radius"]doubleValue]);
    if(DWTyped(d[@"shadow"],NSNumber.class))v.shadow=[d[@"shadow"]boolValue];
    if(DWTyped(d[@"shadow_radius"],NSNumber.class))v.shadowRadius=[d[@"shadow_radius"]floatValue];
    v.shadowColor=colorOf(d[@"shadow_color"],v.shadowColor);
    if(DWTyped(d[@"opacity"],NSNumber.class))v.opacity=[d[@"opacity"]doubleValue];
    return v;
}
// Upstream labels a stand-in with its desktop entry's name and falls back to the
// desktop id. The controller sends the bundle identifier, which is that id here; the
// name is the application's as the Finder shows it. Asked once per identifier.
static NSString *displayName(NSString *app) {
    static NSMutableDictionary<NSString *,NSString *> *names;if(!names)names=[NSMutableDictionary dictionary];
    if(!app.length)return app;if(names[app])return names[app];
    NSURL *url=[NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:app];NSString *name=url?[NSFileManager.defaultManager displayNameAtPath:url.path]:nil;
    if([name.pathExtension isEqual:@"app"])name=name.stringByDeletingPathExtension;
    return names[app]=name.length?name:app;
}
// One clock for every output and every screenshot: seconds since the first frame was described.
double canvasTime(void) { static CFTimeInterval start;static dispatch_once_t once;dispatch_once(&once,^{start=CACurrentMediaTime();});return CACurrentMediaTime()-start; }

@implementation DWCanvasOutput
@end
@implementation DWCanvasRenderer { DWCanvasCounts _counts;dispatch_queue_t _exportWorker; }
- (DWCanvasCounts)takeCounts {
    DWCanvasCounts counts=_counts;_counts=(DWCanvasCounts){0};
    for(NSNumber *output in self.states){DWCanvasOutput *state=self.states[output];NSUInteger shown=state.layer.presentedCount;counts.presented+=shown-state.taken;state.taken=shown;
        if(self.measured){
            IFCompositorPresentationStats s=[state.layer takePresentationStats];
            fprintf(stderr,"presentation: output=%s frames=%lu intervals=%lu gap_ms=%.3f/%.3f/%.3f missed=%lu latency_ms=%.3f/%.3f late_ms=%.3f gpu_ms=%.3f/%.3f errors=%lu overflow=%lu camera_updates=%lu camera_repeats=%lu silence_ms=%.3f duplicate_time=%lu reordered_time=%lu\n",output.stringValue.UTF8String,(unsigned long)s.frames,(unsigned long)s.intervals,s.gapMean*1000,s.gapP99*1000,s.gapWorst*1000,(unsigned long)s.missed,s.latencyMean*1000,s.latencyWorst*1000,s.lateWorst*1000,s.gpuMean*1000,s.gpuWorst*1000,(unsigned long)s.errors,(unsigned long)s.overflow,(unsigned long)s.cameraChanged,(unsigned long)s.cameraRepeated,s.presentationSilence*1000,(unsigned long)s.duplicateTime,(unsigned long)s.reorderedTime);
            fprintf(stderr,"drawable: output=%s acquisitions=%lu timeouts=%lu acquire_ms=%.3f/%.3f queue_ms=%.3f publish_ms=%.3f completed=%lu completion_ms=%.3f/%.3f not_presented=%lu notify_ms=%.3f\n",output.stringValue.UTF8String,(unsigned long)s.acquisitions,(unsigned long)s.acquireTimeouts,s.acquireMean*1000,s.acquireWorst*1000,s.acquireQueueWorst*1000,s.publishWorst*1000,(unsigned long)s.commandCompleted,s.completionMean*1000,s.completionWorst*1000,(unsigned long)s.notPresented,s.notificationWorst*1000);
        }}
    return counts;
}
- (instancetype)initWithSource:(DWCanvasSource)source {
    if((self=[super init])){_source=[source copy];_states=[NSMutableDictionary dictionary];canvasTime();}
    return self;
}
- (void)setNativeMenuBackground:(BOOL)enabled {
    if(_nativeMenuBackground==enabled)return;_nativeMenuBackground=enabled;
    if(!enabled)for(DWCanvasOutput *state in self.states.allValues)[self stopMenuBackground:state];
}
- (BOOL)configure:(NSDictionary *)snapshot {
    NSDictionary *render=DWTyped(snapshot[@"render"],NSDictionary.class);NSNumber *revision=DWTyped(render[@"revision"],NSNumber.class);
    // An unanswered snapshot changes nothing; the first call builds upstream's defaults at least.
    if(self.program&&(!snapshot||revision==self.revision||[revision isEqual:self.revision]))return NO;
    self.revision=revision;self.style++;
    NSDictionary *b=DWTyped(render[@"background"],NSDictionary.class),*c=DWTyped(render[@"chrome"],NSDictionary.class),*o=DWTyped(render[@"outline"],NSDictionary.class);NSString *warning=nil;
    self.inheritsMacBackground=[DWTyped(b[@"inherit_macos"],NSNumber.class)boolValue];
    // Upstream BackgroundConfig, field for field; the module expands ~ and falls back by itself.
    IFBackgroundConfig *config=[IFBackgroundConfig configWithTypeString:DWTyped(b[@"type"],NSString.class) path:DWTyped(b[@"path"],NSString.class) texture:DWTyped(b[@"texture"],NSString.class) warning:&warning];
    config.mirrorTile=[DWTyped(b[@"mirror_tile"],NSNumber.class)boolValue];config.transparentShader=[DWTyped(b[@"transparent_shader"],NSNumber.class)boolValue];config.cacheShader=[DWTyped(b[@"cache_shader"],NSNumber.class)boolValue];
    if(DWTyped(b[@"parallax"],NSNumber.class))config.parallax=[DWTyped(b[@"parallax"],NSNumber.class)boolValue];
    config.animateFPS=(NSUInteger)lround(fmin(fmax([DWTyped(b[@"animate_fps"],NSNumber.class)doubleValue],0),1000));
    // Upstream's u32 of megabytes; a controller that does not report the key leaves upstream's default of 128.
    if(DWTyped(b[@"cache_budget_mb"],NSNumber.class))config.cacheBudgetMB=(NSUInteger)llround(fmin(fmax([b[@"cache_budget_mb"]doubleValue],0),UINT32_MAX));
    self.program=[IFBackgroundProgram programWithConfig:config device:nil];self.note=self.program.errorText?:warning;
    IFCompositorChromeStyle *style=[IFCompositorChromeStyle new];
    style.backgroundColor=colorOf(c[@"background"],style.backgroundColor);style.foregroundColor=colorOf(c[@"foreground"],style.foregroundColor);
    if(DWTyped(c[@"corner_radius"],NSNumber.class))style.cornerRadius=lround([c[@"corner_radius"]doubleValue]);
    if(DWTyped(c[@"title_bar_height"],NSNumber.class))style.titleBarHeight=lround([c[@"title_bar_height"]doubleValue]);
    if(((NSString *)DWTyped(c[@"font"],NSString.class)).length)style.font=c[@"font"];
    if(DWTyped(c[@"font_size"],NSNumber.class))style.fontSize=(NSUInteger)lround(fmax([c[@"font_size"]doubleValue],0));
    if(DWTyped(c[@"font_weight"],NSString.class))style.fontWeight=weightOf(c[@"font_weight"]);
    if(DWTyped(c[@"title_align"],NSString.class))style.titleAlign=[c[@"title_align"]isEqual:@"left"]?IFCompositorTitleAlignLeft:IFCompositorTitleAlignCenter;
    self.chrome=style;
    IFCompositorOutlineSettings outline=IFCompositorOutlineSettingsDefault();outline.color=colorOf(o[@"color"],outline.color);
    if(DWTyped(o[@"thickness"],NSNumber.class))outline.thickness=(int32_t)lround([o[@"thickness"]doubleValue]);
    if(DWTyped(o[@"opacity"],NSNumber.class))outline.opacity=[o[@"opacity"]doubleValue];
    self.outline=outline;
    // Upstream EffectsConfig, field for field, as the controller's parser left it; the compositor's own copy of upstream's parse rules changes nothing in it.
    NSDictionary *e=DWTyped(render[@"effects"],NSDictionary.class);IFCompositorEffects effects=IFCompositorEffectsDefault();
    if(DWTyped(e[@"blur_radius"],NSNumber.class))effects.blurRadius=(uint32_t)lround(fmin(fmax([e[@"blur_radius"]doubleValue],0),UINT32_MAX));
    if(DWTyped(e[@"blur_strength"],NSNumber.class))effects.blurStrength=[e[@"blur_strength"]doubleValue];
    if(DWTyped(e[@"animate_blur_fps"],NSNumber.class))effects.animateBlurFPS=(uint32_t)lround(fmin(fmax([e[@"animate_blur_fps"]doubleValue],0),UINT32_MAX));
    if(DWTyped(e[@"animation_speed"],NSNumber.class))effects.animationSpeed=[e[@"animation_speed"]doubleValue];
    if(DWTyped(e[@"animation_scale"],NSNumber.class))effects.animationScale=[e[@"animation_scale"]doubleValue];
    self.effects=IFCompositorEffectsSanitized(effects);
    // Upstream's error bar shows state.errors in the order of ErrorSource: config, background, keyboard. The controller sends its own
    // sources' messages in that order, config first, and the background's is this program's, so it follows the first of them.
    NSMutableArray<NSString *> *errors=[NSMutableArray array];for(id message in list(render[@"errors"]))if(DWTyped(message,NSString.class))[errors addObject:message];
    if(self.program.errorText)[errors insertObject:self.program.errorText atIndex:MIN(errors.count,(NSUInteger)1)];
    self.errors=errors.count?errors:nil;return YES;
}
// Upstream keeps a background's chunk cache per output (cached_shader_chunks, cached_tile_chunks): each output draws from a program
// of its own, which for a background without a cache is the shared one. A chunk decoded off the main thread redraws that output alone,
// unless a fullscreen window conceals its canvas; the frame is forced, since nothing in its description changed. Under such a window
// the chunk is one a decoder was still working on when the cache was shrunk: it is discarded at once, as upstream's shrink on every
// frame of that session does, where nothing here would drain it until the output is next described.
- (NSArray<NSString *> *)backgroundErrors:(IFBackgroundProgram *)program {
    if(!program.errorText||[self.errors containsObject:program.errorText])return self.errors;
    NSMutableArray *errors=[self.errors mutableCopy]?:[NSMutableArray array];[errors insertObject:program.errorText atIndex:MIN(errors.count,(NSUInteger)1)];return errors.copy;
}
- (void)cache:(DWCanvasOutput *)state output:(NSDictionary *)description {
    IFBackgroundProgram *base=self.backgroundForOutput?self.backgroundForOutput(DWTyped(description[@"id"],NSNumber.class),description,self.program):nil;
    base=base?:self.program;state.background=[base programForOutput];if(state.background==base)return;
    __weak DWCanvasRenderer *weak=self;__weak DWCanvasOutput *output=state;
    state.background.chunkReadyHandler=^{DWCanvasOutput *shown=output;if(!shown.frame.background){[shown.background shrinkChunkCache];return;}shown.dirty=YES;[shown.layer setNeedsRedraw];shown.menuDirty=shown.menuLayer!=nil;[shown.menuLayer setNeedsRedraw];[weak setNeedsFlush];};
}
- (void)refreshBackgrounds {
    if(!self.program||!self.backgroundForOutput)return;BOOL changed=NO;
    for(DWCanvasOutput *state in self.states.allValues){
        IFBackgroundProgram *prior=state.background;[self cache:state output:state.orderOutput];if(state.background==prior)continue;
        [prior shrinkChunkCache];NSDictionary *full=DWTyped(state.orderOutput[@"fullscreen"],NSDictionary.class);
        state.frame.background=!self.nativeWindows&&full&&![DWTyped(full[@"backdrop"],NSString.class)isEqual:@"canvas"]?nil:state.background;
        state.menuFrame.background=state.background;state.menuDirty=state.menuLayer!=nil;
        state.frame.errorMessages=[self backgroundErrors:state.background];state.dirty=YES;changed=YES;
    }
    if(changed)[self setNeedsFlush];
}
// The live picture of one window element, or none.
- (void)content:(IFCompositorElement *)element window:(NSNumber *)window placement:(NSDictionary *)placement {
    DWCanvasContent content=self.source?self.source(window,placement):(DWCanvasContent){NULL,0,CGRectNull};
    element.pixelBuffer=content.buffer;element.contentGeneration=content.buffer?content.generation:0;element.contentRect=content.buffer?content.rect:CGRectNull;
}
// Is the window of this placement, or of this entry of the window list, screen-pinned?
// A placement says so with a boolean, a window entry with its pin ({output, screen_rect}).
BOOL pinnedOf(NSDictionary *p) { return [DWTyped(p[@"pinned"],NSNumber.class)boolValue]||DWTyped(p[@"pinned"],NSDictionary.class)!=nil; }
// One placement as a compositor element. `rect` is the window's rectangle: its canvas
// rectangle, or with `onScreen` its pin's rectangle in the output's own points, which
// the compositor draws at zoom 1 whatever the camera (upstream's screen-pinned
// windows). Upstream's buckets: a pinned window drawn on its output goes above the
// canvas windows, a widget below them, and pinned is tested first, so a pinned widget
// is drawn with the pinned windows. A capture draws on the canvas only (`onScreen` NO),
// where nothing is in the pinned bucket. A window that
// becomes a stand-in, or the reverse, keeps its identifier, as upstream keeps the
// element id. macOS platform rule: a native window carries its own title bar, so the
// stand-in that replaces it is upstream's stand-in for a client-decorated window,
// whose bar and body together cover exactly the window's rectangle.
- (BOOL)fill:(IFCompositorElement *)element window:(NSNumber *)window placement:(NSDictionary *)p rect:(CGRect)world onScreen:(BOOL)onScreen {
    if(!currentDrawnPlacement(p))return NO;
    NSString *kind=DWTyped(p[@"kind"],NSString.class),*title=DWTyped(p[@"title"],NSString.class),*app=displayName(DWTyped(p[@"app_name"],NSString.class));BOOL standin=[kind isEqual:@"standin"];
    element.identifier=window.unsignedLongLongValue;element.kind=standin?IFCompositorElementKindStandIn:IFCompositorElementKindWindow;
    element.space=onScreen?IFCompositorSpacePinned:IFCompositorSpaceCanvas;
    element.layer=onScreen?IFCompositorStackLayerPinned:[DWTyped(p[@"widget"],NSNumber.class)boolValue]?IFCompositorStackLayerWidget:IFCompositorStackLayerNormal;
    // Upstream's dot at the left of a pinned window's title bar. The compositor draws it in a `server` bar only: a stand-in's bar and a client-decorated window show none.
    element.showsPinnedIndicator=pinnedOf(p);
    element.focused=[DWTyped(p[@"focused"],NSNumber.class)boolValue];
    element.decoration=decorationOf(DWTyped(p[@"decoration"],NSDictionary.class),self.chrome.cornerRadius);
    element.appName=app;element.launching=[DWTyped(p[@"launching"],NSNumber.class)boolValue];
    if(standin){element.title=title;element.rect=IFCompositorStandInBodyRect(world,YES,self.chrome.titleBarHeight);element.pixelBuffer=NULL;element.texture=nil;element.contentGeneration=0;element.contentRect=CGRectNull;return YES;}
    // A server title bar shows the title, else the application's name, as upstream falls back to the app id.
    element.title=title.length?title:app?:@"";element.rect=world;
    [self content:element window:window placement:p];
    return YES;
}
// When an animation that begins now began, on this output's clock. Upstream advances every animation before it draws, so the
// first frame that shows one is already a tick in: the time of the last frame presented. This canvas draws on demand, so
// that frame can be long past, and the animation would be over before it was seen: never more than one 60 Hz tick ago.
double began(DWCanvasOutput *state,double now) { return fmax(state.presented,now-1.0/60); }
BOOL pictured(IFCompositorElement *element) { return element.pixelBuffer||element.texture; }
static const double sizeHold=10;
// A closing-bucket element stays in the frame beside whatever keeps its window's identifier, so it carries one of its own.
- (uint64_t)mark { return 1ULL<<63|++self.marks; }
// The hit order is tied to the output and its ordered placements, including each
// exact source/generation binding. Hover can decode another equivalent snapshot;
// its focused flag alone does not change this geometry or attachment membership.
static NSArray<NSDictionary *> *orderBinding(NSDictionary *snapshot,NSNumber *output) {
    NSMutableArray *placements=[NSMutableArray array];
    for(id entry in list(snapshot[@"placements"])){
        NSDictionary *p=DWTyped(entry,NSDictionary.class);if(![p[@"output"]isEqual:output])continue;
        if(p[@"focused"]){NSMutableDictionary *binding=[p mutableCopy];[binding removeObjectForKey:@"focused"];[placements addObject:binding.copy];}
        else [placements addObject:p];
    }
    return placements.copy;
}
- (NSArray<NSDictionary *> *)appliedOrderForOutput:(NSNumber *)output snapshot:(NSDictionary *)snapshot {
    if(!currentOutputPlacements(snapshot[@"placements"]))return nil;
    DWCanvasOutput *state=self.states[output];if(!state.orderApplied||!snapshot||state.orderDirty||state.geometryAnimating||state.geometryNeedsSettledDraw||state.orderProvider!=self.liveOrder||state.orderRevisionProvider!=self.liveOrderRevision)return nil;
    if(self.liveOrderRevision){if(state.orderRevision!=self.liveOrderRevision(output))return nil;}
    else if(![state.orderApplied isEqualToArray:validatedOrder(self.liveOrder?self.liveOrder(state.orderBase,output):nil,state.orderBase)])return nil;
    if(snapshot!=state.orderSnapshot&&snapshot!=state.orderMatchedSnapshot){
        NSDictionary *current=nil;for(id entry in list(snapshot[@"outputs"])){NSDictionary *o=DWTyped(entry,NSDictionary.class);if(drawableOutput(o)&&[o[@"id"]isEqual:output]){current=o;break;}}
        if(![state.orderOutput isEqual:current]||![state.orderBinding isEqualToArray:orderBinding(snapshot,output)])return nil;
        state.orderMatchedSnapshot=snapshot;
    }
    // Keys that no longer name retained live images cannot authorize input, even
    // if an unchanged provider revision incorrectly accompanies the withdrawal.
    for(NSDictionary *token in state.orderApplied)if(token[@"key"]){DWCanvasChild *child=state.attachments[token[@"window"]].images[token[@"key"]];if(!child||!child.element.pixelBuffer||child.element!=state.orderElements[token])return nil;}
    return state.orderApplied;
}
// An authoritative snapshot can remove an output without a shell-wide reset.
// Stop its drawable worker and release every root/family image and closing bake,
// including cached wrappers after commands already encoded have finished.
- (void)stopOutput:(DWCanvasOutput *)state {
    [self stopMenuBackground:state];
    [state.layer stopDrawing];[state.layer removeFromSuperlayer];state.frame.background=nil;[state.background shrinkChunkCache];
    for(IFCompositorElement *element in state.frame.elements){element.pixelBuffer=NULL;element.texture=nil;}
    [state.frame.elements removeAllObjects];[state.elements removeAllObjects];[state.placements removeAllObjects];[state.attachments removeAllObjects];[state.geometry removeAllObjects];state.geometryAnimating=NO;[state.leaving removeAllObjects];[state.adopted removeAllObjects];[state.unseen removeAllObjects];[state.owed removeAllObjects];
    state.orderPlacements=nil;state.orderOutput=nil;state.orderSnapshot=nil;state.orderMatchedSnapshot=nil;state.orderBinding=nil;state.orderBase=nil;state.orderApplied=nil;state.orderElements=nil;state.orderProvider=nil;state.orderRevisionProvider=nil;
    [state.layer.renderer purge];[state.attachmentRenderer purge];
}
- (BOOL)hasGeometryTransitions {for(DWCanvasOutput *state in self.states.allValues)if(state.geometryAnimating||state.geometryNeedsSettledDraw)return YES;return NO;}
- (BOOL)hasFamilyGeometryTransitions {
    if(self.hasGeometryTransitions)return YES;
    for(DWCanvasOutput *state in self.states.allValues)for(IFCompositorElement *root in state.elements.allValues)
        if(root.kind==IFCompositorElementKindWindow&&root.lifecycle==IFCompositorLifecycleOpening&&![state.frame lifecycleFinishedForElement:root])return YES;
    return NO;
}
- (void)finishGeometryTransitions {
    BOOL changed=NO;
    for(DWCanvasOutput *state in self.states.allValues){
        // Finishing before input also fences a native answer still in flight:
        // that same transaction cannot start another tween under the new grab.
        for(DWCanvasGeometry *geometry in state.geometry.allValues)geometry.blockedTransaction=geometry.transaction;
        if(!state.geometryAnimating&&!state.geometryNeedsSettledDraw)continue;state.geometryAnimating=NO;state.geometryNeedsSettledDraw=YES;state.dirty=YES;changed=YES;
        for(NSNumber *window in state.geometry){DWCanvasGeometry *geometry=state.geometry[window];if(!geometry.active)continue;geometry.active=NO;state.elements[window].rect=geometry.target;}
        for(NSNumber *window in state.attachments)[self geometryForFamily:state.attachments[window] root:state.elements[window] frame:state.frame];
    }
    if(changed)[self flush];
}
- (void)render:(NSDictionary *)snapshot outputs:(NSArray<NSNumber *> *)outputs host:(CALayer *)host origin:(CGPoint)origin scale:(CGFloat)scale decorationScale:(NSInteger)decorationScale {
    if(!snapshot||!currentOutputPlacements(snapshot[@"placements"]))return;
    // Reconcile against all snapshot outputs, not just this host's subset: a
    // separate host will describe the other displays in the same shell turn.
    NSMutableArray<NSDictionary *> *all=[NSMutableArray array];NSMutableSet<NSNumber *> *alive=[NSMutableSet set];
    for(id entry in list(snapshot[@"outputs"])){NSDictionary *output=DWTyped(entry,NSDictionary.class);if(drawableOutput(output)&&![alive containsObject:output[@"id"]]){[all addObject:output];[alive addObject:output[@"id"]];}}
    for(NSNumber *output in self.states.allKeys)if(![alive containsObject:output]){[self stopOutput:self.states[output]];[self.states removeObjectForKey:output];}
    if(!host)return;[self configure:snapshot];double now=canvasTime();[self play:snapshot now:now];
    // The windows an `open` event of this snapshot names, and the serial of each: an output that has not been described with it yet opens the window.
    NSMutableDictionary<NSNumber *,NSNumber *> *opened=[NSMutableDictionary dictionary];
    for(id entry in list(snapshot[@"lifecycle_events"])){NSDictionary *event=DWTyped(entry,NSDictionary.class);if(DWTyped(event[@"window"],NSNumber.class)&&DWTyped(event[@"serial"],NSNumber.class)&&[event[@"event"]isEqual:@"open"])opened[event[@"window"]]=event[@"serial"];}
    // The window the controller owes a size: its one size transaction, while an effect of it is outstanding. Null in a run that cannot deliver a size.
    NSDictionary *resize=DWTyped(snapshot[@"native_resize"],NSDictionary.class);self.sizing=DWTyped(resize[@"pending_effect"],NSDictionary.class)?DWTyped(resize[@"window"],NSNumber.class):nil;
    for(NSDictionary *o in all){
        NSNumber *output=DWTyped(o[@"id"],NSNumber.class);CGRect bounds=rectOf(o[@"screen_bounds"]);if(![alive containsObject:output]||![outputs containsObject:output])continue;
        DWCanvasOutput *state=self.states[output];
        // An output that is new shows no event that came before it: nothing was on it to open.
        if(!state){state=self.states[output]=[DWCanvasOutput new];state.layer=[[IFCompositorLayer alloc]initWithRenderer:nil];state.frame=[IFCompositorFrame new];state.elements=[NSMutableDictionary dictionary];state.placements=[NSMutableDictionary dictionary];state.attachments=[NSMutableDictionary dictionary];state.leaving=[NSMutableArray array];state.unseen=[NSMutableDictionary dictionary];state.adopted=[NSMutableDictionary dictionary];state.owed=[NSMutableDictionary dictionary];state.serial=self.played;state.layer.countsPresented=self.measured;__weak DWCanvasRenderer *weak=self;state.layer.drawableReady=^{[weak retryDrawable:output];};self.placed=YES;}
        if(state.layer.superlayer!=host){[host insertSublayer:state.layer atIndex:0];self.placed=YES;}
        CGRect place=CGRectOffset(bounds,-origin.x,-origin.y);if(!CGRectEqualToRect(state.layer.frame,place)){state.layer.frame=place;self.placed=YES;}
        IFCompositorFrame *frame=state.frame;CGPoint camera=pointOf(o[@"camera"]);double zoom=[DWTyped(o[@"zoom"],NSNumber.class)doubleValue];
        if(frame.scale!=(scale>0?scale:1))self.placed=YES;
        frame.size=bounds.size;frame.scale=scale>0?scale:1;frame.cameraX=camera.x;frame.cameraY=camera.y;frame.zoom=zoom;frame.clear=IFCompositorClearOpaqueBlack;frame.decorationScale=decorationScale;
        if(state.style!=self.style||!CGRectEqualToRect(bounds,rectOf(state.orderOutput[@"screen_bounds"]))){state.style=self.style;[self cache:state output:o];frame.background=state.background;frame.chrome=self.chrome;frame.placeholderColor=self.chrome.backgroundColor;frame.outline=self.outline;frame.effects=self.effects;frame.errorMessages=[self backgroundErrors:state.background];}
        // The other outputs' viewports, projected as upstream's build_output_outline_elements does.
        NSMutableData *outlines=[NSMutableData data];
        for(NSDictionary *other in all){
            if(other==o||!DWTyped(other[@"id"],NSNumber.class)||[other[@"id"]isEqual:output])continue;
            CGPoint otherCamera=pointOf(other[@"camera"]);CGRect otherBounds=rectOf(other[@"screen_bounds"]);if(CGRectIsNull(otherBounds))continue;
            CGRect outline=IFCompositorOutlineRect(camera.x,camera.y,zoom,otherCamera.x,otherCamera.y,otherBounds.size,[DWTyped(other[@"zoom"],NSNumber.class)doubleValue]);[outlines appendBytes:&outline length:sizeof(outline)];
        }
        [frame setOutlineRects:outlines.bytes count:outlines.length/sizeof(CGRect)];
        // Placement order is the controller's bottom-to-top z order: this output's widgets, its canvas
        // windows, then the windows pinned to it. The compositor draws the three layers in that order too
        // and keeps this order within each.
        NSMutableDictionary<NSNumber *,IFCompositorElement *> *elements=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSDictionary *> *placements=[NSMutableDictionary dictionary];[frame.elements removeAllObjects];
        NSMutableArray<NSDictionary *> *orderedPlacements=[NSMutableArray array];NSMutableSet<NSNumber *> *seenPlacements=[NSMutableSet set];
        NSMutableDictionary<NSNumber *,NSNumber *> *unseen=[NSMutableDictionary dictionary],*owed=[NSMutableDictionary dictionary];
        for(id entry in list(snapshot[@"placements"])){
            NSDictionary *p=DWTyped(entry,NSDictionary.class);if(!currentOutputPlacement(p))continue;
            NSNumber *window=DWTyped(p[@"window"],NSNumber.class);if(!window||![p[@"output"]isEqual:output]||[seenPlacements containsObject:window])continue;
            // A screen-pinned placement has no canvas position to draw from: its screen_rect is its pin's, in
            // global screen points at the window's own size whatever the camera and the zoom, and the pinned
            // space takes it in this output's own points. Its world rectangle is bookkeeping and is not read.
            BOOL pinned=[DWTyped(p[@"pinned"],NSNumber.class)boolValue];CGRect world;
            if(pinned){world=rectOf(p[@"screen_rect"]);if(CGRectIsNull(world))continue;world=CGRectOffset(world,-bounds.origin.x,-bounds.origin.y);}
            else {world=rectOf(p[@"world_rect"]);if(CGRectIsNull(world))continue;}
            [seenPlacements addObject:window];[orderedPlacements addObject:p];
            // Preserve physical roots in the complete order as barriers even
            // though WindowServer, rather than this frame, draws their pixels.
            BOOL standin=[DWTyped(p[@"kind"],NSString.class)isEqual:@"standin"];
            if(self.nativeWindows&&!standin&&!(self.nativeReplica&&self.nativeReplica(window,output)))continue;
            IFCompositorElement *element=state.elements[window]?:[IFCompositorElement new];
            if(![self fill:element window:window placement:p rect:world onScreen:pinned])continue;
            if(element.kind==IFCompositorElementKindWindow){
                // Upstream DrawnChrome::drawn: the chrome a window wears depends on how its visual
                // frame covers the output. A stand-in is not subject to it. A pinned window's frame
                // is its screen site at zoom 1, as upstream's window_render_transform gives it.
                IFCompositorDecoration d=element.decoration;double bw=d.mode==IFCompositorDecorationModeNone?0:MAX(d.borderWidth,0),bar=d.mode==IFCompositorDecorationModeServer?self.chrome.titleBarHeight:0;
                double left=pinned?world.origin.x:world.origin.x-camera.x,top=pinned?world.origin.y:world.origin.y-camera.y,z=pinned?1:zoom;
                CGRect visual=CGRectMake((left-bw)*z,(top-bar-bw)*z,(world.size.width+2*bw)*z,(world.size.height+bar+2*bw)*z);
                element.decoration=IFCompositorDecorationDrawn(d,NO,IFCompositorCoverageOfFrame(visual,CGRectMake(0,0,bounds.size.width,bounds.size.height)));
                // Upstream's effective_blur, the controller's answer: a plain flag that the coverage rule does not touch. Never set for a capture.
                element.blur=[DWTyped(DWTyped(p[@"decoration"],NSDictionary.class)[@"blur"],NSNumber.class)boolValue];
                // Upstream's open animation, for a window an `open` event names that this output has not shown opening. It runs from the
                // window's first picture: here when it has one, or has waited a second for it, else in -contentChanged:. While its size is
                // owed (`owed`, above) the wait is renewed instead, so that second starts when the size transaction has ended.
                // Not for a window that is fullscreen here (a rule's `fullscreen` as it mapped): the size it is owed is its output's, the
                // controller has marked the output at once and nothing else is drawn on it, so a held window would leave it black for as
                // long as the application takes. It is drawn from its first picture at the size it has (docs/crates/desktop/FULLSCREEN.md, No transition).
                NSNumber *since=state.unseen[window];
                if([opened[window]unsignedLongLongValue]>state.serial&&self.effects.animationSpeed<1){since=@(now);element.lifecycle=IFCompositorLifecycleOpening;element.lifecycleStartTime=NAN;element.lifecycleProgress=0;}
                NSNumber *held=since&&[self.sizing isEqual:window]&&![DWTyped(p[@"fullscreen"],NSNumber.class)boolValue]?(state.owed[window]?:@(now)):nil;
                if(held)owed[window]=held;
                if(held&&now-held.doubleValue<sizeHold)unseen[window]=@(now);
                else if(since&&!pictured(element)&&now-since.doubleValue<1)unseen[window]=since;
                else if(element.lifecycle==IFCompositorLifecycleOpening&&isnan(element.lifecycleStartTime))element.lifecycleStartTime=began(state,now);
            }
            // A stand-in neither opens nor is frosted, whatever the window it stands for was doing.
            else {element.blur=NO;element.lifecycle=IFCompositorLifecycleNone;element.lifecycleStartTime=NAN;}
            elements[window]=element;placements[window]=p;[frame.elements addObject:element];
        }
        // The stand-in of an adopted slot fades once its window is no longer waited for: it has its picture, a second has passed, or it is not drawn here as a window.
        for(NSNumber *window in state.adopted.allKeys)if(!unseen[window]){state.adopted[window].lifecycleStartTime=began(state,now);[state.adopted removeObjectForKey:window];}
        // Where the closing bucket sits among the windows makes no difference: the compositor draws it above the canvas windows and below the pinned ones.
        // Upstream draws no closing snapshot and no stand-in fade on an output that is visually fullscreen ("no dying-window flash over a
        // fullscreen app": docs/native/app/Canvas/COMPOSITOR-NOTES.md 18.2, When not to). They are left out of that output's frame and run out unseen on the
        // clock they began on, as upstream's lists do: -flush drops each when it is over, and what is left is back with the canvas.
        if(!DWTyped(o[@"fullscreen"],NSDictionary.class))[frame.elements addObjectsFromArray:state.leaving];
        state.elements=elements;state.placements=placements;state.unseen=unseen;state.owed=owed;state.serial=self.played;state.dirty=YES;
        state.orderPlacements=orderedPlacements.copy;state.orderOutput=o;state.orderSnapshot=snapshot;state.orderMatchedSnapshot=nil;state.orderBinding=orderBinding(snapshot,output);state.orderDirty=YES;
        [self describeMenuBackground:state output:o snapshot:snapshot];
        [self fullscreen:o among:all state:state];
        [self describeGeometry:snapshot state:state now:now];
        // With the root's final space and rectangle known, insert each family
        // immediately above it. A root no longer drawn here retains no child.
        for(NSNumber *window in state.attachments.allKeys)if(!elements[window]||elements[window].kind!=IFCompositorElementKindWindow){
            for(DWCanvasChild *child in state.attachments[window].ordered){child.element.pixelBuffer=NULL;child.element.texture=nil;}
            [state.attachments removeObjectForKey:window];
        }
        for(NSNumber *window in elements)if(elements[window].kind==IFCompositorElementKindWindow)[self attachmentsForWindow:window output:output state:state];
        [self applyOrderForOutput:output state:state];
    }
}
- (NSString *)standInPart:(NSNumber *)window output:(NSNumber *)output screen:(CGPoint)point snapshot:(NSDictionary *)snapshot {
    if(![self appliedOrderForOutput:output snapshot:snapshot])return nil;
    DWCanvasOutput *state=self.states[output];IFCompositorElement *element=state.elements[window];NSDictionary *p=state.placements[window];
    if(!element||element.kind!=IFCompositorElementKindStandIn||!CGRectContainsPoint(rectOf(p[@"clip_rect"]),point))return nil;
    CGRect screen=rectOf(p[@"screen_rect"]),body=element.rect;
    double total=body.size.height+self.chrome.titleBarHeight;
    if(screen.size.width<=0||screen.size.height<=0||body.size.width<=0||total<=0)return nil;
    CGPoint local=CGPointMake((point.x-screen.origin.x)*body.size.width/screen.size.width,(point.y-screen.origin.y)*total/screen.size.height);
    if(local.y<self.chrome.titleBarHeight){
        double bar=self.chrome.titleBarHeight;
        return local.x>=body.size.width-bar-8&&local.x<body.size.width-8?@"close":@"title";
    }
    local.y-=self.chrome.titleBarHeight;
    NSString *name=element.appName.length?element.appName:element.title?:@"";
    CGRect label=IFCompositorStandInLabelRect(name,element.launching,body.size,state.frame.decorationScale,self.chrome);
    return !CGRectIsNull(label)&&CGRectContainsPoint(label,local)?@"label":@"body";
}
- (CALayer *)layerForOutput:(NSNumber *)output { return self.states[output].layer; }
- (BOOL)contentChanged:(NSNumber *)window {
    BOOL opening=NO;
    for(NSNumber *output in self.states){
        DWCanvasOutput *state=self.states[output];
        IFCompositorElement *element=state.elements[window];BOOL shown=element&&element.kind==IFCompositorElementKindWindow;
        if(shown){[self content:element window:window placement:state.placements[window]];[self attachmentsForWindow:window output:output state:state];}
        BOOL reordered=[self applyOrderForOutput:output state:state];
        if(shown||reordered){state.dirty=YES;[self setNeedsFlush];}
        if(!shown)continue;
        // The first picture of a window that was waited for: its opening, and the fade of the stand-in whose slot it adopted, begin.
        // Not while the window's size is owed: that picture is of the size it is leaving, and -render: starts both when the size has settled.
        // A window that is fullscreen here is not held for the output's size (-render:).
        if(!state.unseen[window]||!pictured(element)||([self.sizing isEqual:window]&&![DWTyped(state.placements[window][@"fullscreen"],NSNumber.class)boolValue]))continue;
        [state.unseen removeObjectForKey:window];IFCompositorElement *fade=state.adopted[window];double start=began(state,canvasTime());
        if(element.lifecycle==IFCompositorLifecycleOpening&&isnan(element.lifecycleStartTime)){element.lifecycleStartTime=start;opening=YES;}
        if(fade){fade.lifecycleStartTime=start;[state.adopted removeObjectForKey:window];opening=YES;}
    }
    return opening;
}
- (BOOL)animates:(NSArray<NSNumber *> *)outputs draw:(BOOL)draw {
    BOOL any=NO;
    for(NSNumber *output in outputs){
        DWCanvasOutput *state=self.states[output];if(!state.layer.renderer)continue;
        // A chunk cache that is still filling (cells of a baked shader left for the next frame, chunks of a TIFF being decoded) is drawn
        // again as an animation is, until nothing is pending. That frame is forced: its description is the one already drawn.
        BOOL filling=state.frame.background.pendingChunkCount>0;if(!filling&&!state.frame.needsContinuousRedraw&&!state.geometryAnimating&&!state.geometryNeedsSettledDraw)continue;
        // Every frame drawn spends the cache's allowances (two bakes, eight uploads), which upstream grants once per output frame. An output that has drawn since
        // the last tick (a description the shell flushed by itself, as for a layer that moved) has had this tick's frame: forcing another would spend
        // them twice a tick, and on a 120 Hz display link draw the output twice in 8 ms. A flight's camera frame is described before this is asked and
        // drawn after it, by the tick's one flush, forced or not.
        any=YES;if(draw){BOOL had=state.drawn;state.drawn=NO;state.dirty=YES;if(filling&&!had){state.forced=YES;[state.layer setNeedsRedraw];state.menuDirty=state.menuLayer!=nil;[state.menuLayer setNeedsRedraw];}[self setNeedsFlush];}
    }
    return any;
}
// Stream frames, animation ticks and decoded chunks describe each output to its layer once per refresh of the display: the
// shell's frame timer flushes (`frame`). Each stream delivers on a turn of the main queue of its own, at a moment of its own,
// so a flush per turn was a flush per window per frame, several to a refresh. Without a timer they are flushed once per turn
// of the run loop, unless the shell flushed in between. The layer itself draws only when the description, a pixel buffer, the
// animated background's clock or the progress of an open or close animation changed.
- (void)setNeedsFlush {
    _counts.requests+=self.measured;if(self.frame&&self.frame(YES))return;
    if(self.pending)return;self.pending=YES;__weak DWCanvasRenderer *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{[weak flush];});
}
// An acquisition can return just after the screen callback found an empty
// pool. Use the rest of that refresh to encode the latest owed scene, and
// wait for the next tick only once that presentation budget has expired.
- (void)retryDrawable:(NSNumber *)output {
    DWCanvasOutput *state=self.states[output];
    if(!state||!state.dirty||(!state.awaitingDrawable&&!state.layer.missed))return;
    double target=self.frameTarget;
    if(self.placed||self.paced||target<=0||CACurrentMediaTime()>=target-.0005){[self setNeedsFlush];return;}
    _counts.requests+=self.measured;if(self.frame&&!self.frame(YES)){[self setNeedsFlush];return;}
    self.paced=YES;[self flush];self.paced=NO;
}
- (void)flushDescribed { _counts.requests+=self.measured;if(self.placed||!(self.frame&&self.frame(NO)))[self flush]; }
// Metal hands out autoreleased drawables and encoder contexts; a caller outside a run-loop
// callout (the launch's first frame, the quit-pending loop) has no pool of its own to end them.
- (void)flushFrameAtTime:(CFTimeInterval)time refreshRate:(NSInteger)rate {
    self.frameTarget=time;self.paced=YES;for(DWCanvasOutput *state in self.states.allValues){state.layer.presentationTime=time;state.layer.presentationInterval=rate>0?1.0/rate:0;state.menuLayer.presentationTime=time;state.menuLayer.presentationInterval=state.layer.presentationInterval;}[self flush];self.paced=NO;
}
- (void)flush {
    BOOL placed=self.placed;self.pending=NO;self.placed=NO;double now=canvasTime();CFTimeInterval began=self.measured?CACurrentMediaTime():0;BOOL any=NO;
    for(DWCanvasOutput *state in self.states.allValues){
        if(!state.dirty){if(state.menuDirty)[self flushMenuBackground:state];continue;}
        if(self.paced&&!placed&&state.layer.drawablePending){state.awaitingDrawable=YES;if(state.menuDirty)[self flushMenuBackground:state];continue;}
        state.awaitingDrawable=NO;state.dirty=NO;any=YES;IFCompositorFrame *frame=state.frame;frame.time=now;[self advanceGeometry:state now:now];
        for(NSNumber *window in state.attachments)[self geometryForFamily:state.attachments[window] root:state.elements[window] frame:frame];
        if(state.geometryNeedsSettledDraw)[state.layer setNeedsRedraw];
        BOOL forced=state.forced;state.forced=NO;state.layer.paced=self.paced;@autoreleasepool{if([state.layer updateWithFrame:frame]){state.geometryNeedsSettledDraw=NO;state.presented=now;_counts.drawn++;if(!forced)state.drawn=YES;
            for(NSNumber *window in state.geometry){DWCanvasGeometry *geometry=state.geometry[window];IFCompositorElement *element=state.elements[window];geometry.screen=geometryScreen(element.rect,element.space,frame);geometry.drawn=YES;}}}
        // A frame that had no drawable is still owed: the output stays marked, and what was owed inside the layer's transaction stays so.
        if(state.layer.missed){state.dirty=YES;if(forced)state.forced=YES;if(placed)self.placed=YES;}
        [self flushMenuBackground:state];
        // An animation that has run out at this frame's time, which the frame no longer showed: upstream drops the snapshot or the fade, and a window that has opened is the plain window.
        for(IFCompositorElement *element in state.leaving.count?state.leaving.copy:nil)if([frame lifecycleFinishedForElement:element]){[state.leaving removeObject:element];[frame.elements removeObject:element];state.orderDirty=YES;}
        if(state.orderDirty)[self applyOrderForOutput:state.orderOutput[@"id"] state:state];
        for(IFCompositorElement *element in frame.elements)if(element.lifecycle==IFCompositorLifecycleOpening&&[frame lifecycleFinishedForElement:element]){element.lifecycle=IFCompositorLifecycleNone;element.lifecycleStartTime=NAN;}
    }
    if(began&&any){double took=CACurrentMediaTime()-began;_counts.flushes++;_counts.flushSeconds+=took;_counts.flushWorst=fmax(_counts.flushWorst,took);}
}
- (void)reset {
    for(DWCanvasOutput *state in self.states.allValues)[self stopOutput:state];
    [self.states removeAllObjects];
}
- (NSDictionary *)screenshot:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
    return DWWriteScreenshotPixels([self screenshotPixels:effect snapshot:snapshot]);
}
- (void)screenshot:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot completed:(void (^)(NSDictionary *))completed {
    NSDictionary *pixels=[self screenshotPixels:effect snapshot:snapshot];
    if(pixels[@"error"]){completed(pixels);return;}
    if(!_exportWorker)_exportWorker=dispatch_queue_create("org.infinify.screenshot-writer",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    dispatch_async(_exportWorker,^{@autoreleasepool{
        NSDictionary *result=DWWriteScreenshotPixels(pixels);
        dispatch_async(dispatch_get_main_queue(),^{completed(result);});
    }});
}
@end
