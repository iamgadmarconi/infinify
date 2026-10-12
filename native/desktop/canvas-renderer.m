// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/ipc/mod.rs (cmd_screenshot, resolve_screenshot_region, window_visual_rect,
// snap_rect_to_rect, union_rect: what each screenshot target captures),
// src/render/screenshot.rs (capture_region_to_png: the scale rule, the 16384 px
// limit and their refusals), src/state/mod.rs (output_viewport_rect),
// src/canvas.rs (rule_to_internal), src/render/capture_background.rs (wallpaper_dest
// and the Wallpaper arm of tile_elements: where a capture shows a wallpaper) and
// src/render/mod.rs (compose_capture_elements: the opacity of a window captured
// alone; what a canvas capture leaves out: a screen-pinned window is never in one,
// a widget is drawn below the other windows). The frame description is the host
// protocol of the compositor port (compositor.h): canvas-space elements bottom to
// top from the controller's placements, a widget in the widget layer and a
// screen-pinned window in the pinned layer and the pinned space (upstream
// compose_frame's zoomed_widgets and zoomed_pinned buckets, and
// window_render_transform in src/state/output.rs: a pin's output-relative point at
// zoom 1), DrawnChrome's coverage rule per output, upstream's stand-in body
// rectangle and its projection of the other outputs' viewports. The effects are the
// same port's (COMPOSITOR-NOTES.md, section 18), with src/state/errors.rs (ErrorSource:
// the order of the error bar's messages) and src/state/window_animation_driver.rs
// (start_window_open_animation, snapshot_closing_window, flatten_scale_for_canvas_rect:
// an event on no output animates nothing, and the density a closing window is baked
// at). The background's chunk caches (a baked cache_shader, a pyramidal TIFF's chunks)
// are the background module's (BACKGROUND-NOTES.md, section 17); from here come
// upstream's one cache per output and its shrink while a fullscreen window conceals the
// canvas (src/render/mod.rs, the bg_elements of compose_frame), the frames that keep
// coming while a cache fills (has_pending_bakes and has_pending_loads, as
// src/backend/udev.rs asks them) and what a capture draws instead of a cache
// (src/render/capture_background.rs, CaptureBackground::prepare).
// New code over the controller's snapshot; cameras, world rectangles and pinned
// screen rectangles are the controller's, and no native window geometry is read.
#import "canvas-renderer.h"
#import "compositor.h"
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <fcntl.h>

static NSDictionary *dict(id value) { return [value isKindOfClass:NSDictionary.class]?value:nil; }
static NSArray *list(id value) { return [value isKindOfClass:NSArray.class]?value:@[]; }
static NSString *text(id value) { return [value isKindOfClass:NSString.class]?value:nil; }
static NSNumber *number(id value) { return [value isKindOfClass:NSNumber.class]?value:nil; }
static BOOL finiteImageRect(CGRect r) { return isfinite(r.origin.x)&&isfinite(r.origin.y)&&isfinite(r.size.width)&&isfinite(r.size.height)&&r.size.width>0&&r.size.height>0&&isfinite(CGRectGetMaxX(r))&&isfinite(CGRectGetMaxY(r)); }
static BOOL validAttachment(DWCanvasAttachment *image) {
    if(![image isKindOfClass:DWCanvasAttachment.class]||!image.buffer||!finiteImageRect(image.unitRect))return NO;
    CGRect crop=image.contentRect;if(CGRectIsNull(crop))return YES;
    return finiteImageRect(crop)&&crop.origin.x>=0&&crop.origin.y>=0&&CGRectGetMaxX(crop)<=CVPixelBufferGetWidth(image.buffer)&&CGRectGetMaxY(crop)<=CVPixelBufferGetHeight(image.buffer);
}
static CGPoint pointOf(id value) { NSDictionary *p=dict(value);return CGPointMake([number(p[@"x"])doubleValue],[number(p[@"y"])doubleValue]); }
// The controller's {origin:{x,y},size:{width,height}}; CGRectNull for anything else.
static CGRect rectOf(id value) {
    NSDictionary *r=dict(value),*origin=dict(r[@"origin"]),*size=dict(r[@"size"]);if(!number(origin[@"x"])||!number(origin[@"y"])||!number(size[@"width"])||!number(size[@"height"]))return CGRectNull;
    return CGRectMake([number(origin[@"x"])doubleValue],[number(origin[@"y"])doubleValue],[number(size[@"width"])doubleValue],[number(size[@"height"])doubleValue]);
}
static BOOL drawableOutput(NSDictionary *output) {
    NSDictionary *camera=dict(output[@"camera"]);NSNumber *zoom=number(output[@"zoom"]),*identifier=number(output[@"id"]);
    return identifier&&isfinite(identifier.doubleValue)&&identifier.doubleValue>0&&floor(identifier.doubleValue)==identifier.doubleValue&&identifier.unsignedLongLongValue>0&&finiteImageRect(rectOf(output[@"screen_bounds"]))&&number(camera[@"x"])&&number(camera[@"y"])&&isfinite([camera[@"x"]doubleValue])&&isfinite([camera[@"y"]doubleValue])&&isfinite(zoom.doubleValue)&&zoom.doubleValue>0;
}
// Upstream output_viewport_rect: size / zoom canvas units from the rounded camera. CGRectNull without an output.
static CGRect viewportOf(NSDictionary *o) {
    CGRect bounds=rectOf(o[@"screen_bounds"]);if(!o||CGRectIsNull(bounds))return CGRectNull;
    CGPoint camera=pointOf(o[@"camera"]);double zoom=[number(o[@"zoom"])doubleValue];if(!(isfinite(zoom)&&zoom>0))zoom=1;
    return CGRectMake(round(camera.x),round(camera.y),round(round(bounds.size.width)/zoom),round(round(bounds.size.height)/zoom));
}
// A straight-alpha sRGB [r,g,b,a] in 0..1 back to upstream's [u8; 4].
static IFCompositorColor colorOf(id value,IFCompositorColor fallback) {
    NSArray *c=list(value);uint8_t bytes[4];if(c.count!=4)return fallback;
    for(NSUInteger i=0;i<4;i++){NSNumber *n=number(c[i]);if(!n)return fallback;bytes[i]=(uint8_t)lround(fmin(fmax(n.doubleValue,0),1)*255);}
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
    NSString *mode=text(d[@"mode"]);
    v.mode=[mode isEqual:@"server"]?IFCompositorDecorationModeServer:[mode isEqual:@"minimal"]?IFCompositorDecorationModeMinimal:[mode isEqual:@"none"]?IFCompositorDecorationModeNone:IFCompositorDecorationModeClient;
    if(number(d[@"border_width"]))v.borderWidth=(int32_t)lround([d[@"border_width"]doubleValue]);
    v.borderColor=colorOf(d[@"border_color"],v.borderColor);v.borderColorFocused=colorOf(d[@"border_color_focused"],v.borderColorFocused);
    if(number(d[@"corner_radius"]))v.cornerRadius=(int32_t)lround([d[@"corner_radius"]doubleValue]);
    if(number(d[@"shadow"]))v.shadow=[d[@"shadow"]boolValue];
    if(number(d[@"shadow_radius"]))v.shadowRadius=[d[@"shadow_radius"]floatValue];
    v.shadowColor=colorOf(d[@"shadow_color"],v.shadowColor);
    if(number(d[@"opacity"]))v.opacity=[d[@"opacity"]doubleValue];
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
static double canvasTime(void) { static CFTimeInterval start;static dispatch_once_t once;dispatch_once(&once,^{start=CACurrentMediaTime();});return CACurrentMediaTime()-start; }
static NSDictionary *refusal(NSString *message) { return @{@"error":message}; }

// The offscreen render owns these immutable pixels independently of the canvas.
// Compression and filesystem writes need no renderer, source or native window.
static NSDictionary *writeScreenshotPixels(NSDictionary *pixels) {
    if(pixels[@"error"])return pixels;
    NSString *path=pixels[@"path"];CGImageRef image=(__bridge CGImageRef)pixels[@"image"];
    // Write only the client's path, preserving the synchronous export contract.
    NSMutableData *png=[NSMutableData data];CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL);
    BOOL encoded=NO;if(destination){CGImageDestinationAddImage(destination,image,NULL);encoded=CGImageDestinationFinalize(destination);CFRelease(destination);}
    if(!encoded)return refusal([NSString stringWithFormat:@"cannot write %@: the image could not be encoded",path]);
    int file=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC,0666),failure=file<0?errno:0;const char *bytes=png.bytes;
    for(size_t left=png.length;!failure&&left;){ssize_t n=write(file,bytes,left);if(n>0){bytes+=n;left-=(size_t)n;}else if(n==0||errno!=EINTR)failure=n?errno:EIO;}
    if(file>=0&&close(file)&&!failure)failure=errno;
    if(failure)return refusal([NSString stringWithFormat:@"cannot write %@: %s (os error %d)",path,strerror(failure),failure]);
    return @{@"path":path,@"width":pixels[@"width"],@"height":pixels[@"height"]};
}

// Generic family image geometry and stable compositor elements. The shell owns
// the provider's opaque key; this cache knows only its root and output placement.
@interface DWCanvasChild : NSObject
@property IFCompositorElement *element;
@property(copy) NSString *key;
@property CGRect unitRect;
@end
@implementation DWCanvasChild
@end
@interface DWCanvasFamily : NSObject
@property NSMutableDictionary<NSString *,DWCanvasChild *> *images;
@property NSArray<DWCanvasChild *> *ordered;
@end
@implementation DWCanvasFamily
@end

// Presentation only: an action's native resize is asynchronous, but the frames
// between two observed geometries run on the display clock. Keeping this outside
// the controller leaves native size/readback and input authority unchanged.
@interface DWCanvasGeometry : NSObject
@property CGRect from,target,screen;
@property IFCompositorSpace space;
@property double start,end;
@property BOOL active,drawn,fullscreen,actionLive;
@property NSDictionary *identity;
@property NSNumber *generation,*transaction,*blockedTransaction;
@end
@implementation DWCanvasGeometry
@end
static CGRect geometryRect(DWCanvasGeometry *geometry,double now) {
    if(!geometry.active||now>=geometry.end)return geometry.target;
    double t=fmin(1,fmax(0,(now-geometry.start)/(geometry.end-geometry.start))),p=t*t*(3-2*t);
    CGRect a=geometry.from,b=geometry.target;
    return CGRectMake(a.origin.x+(b.origin.x-a.origin.x)*p,a.origin.y+(b.origin.y-a.origin.y)*p,
                      a.size.width+(b.size.width-a.size.width)*p,a.size.height+(b.size.height-a.size.height)*p);
}
static CGRect geometryScreen(CGRect rect,IFCompositorSpace space,IFCompositorFrame *frame) {
    if(space==IFCompositorSpaceCanvas)return CGRectMake((rect.origin.x-frame.cameraX)*frame.zoom,(rect.origin.y-frame.cameraY)*frame.zoom,rect.size.width*frame.zoom,rect.size.height*frame.zoom);
    return rect;
}
static CGRect geometryFromScreen(CGRect rect,IFCompositorSpace space,IFCompositorFrame *frame) {
    if(space==IFCompositorSpaceCanvas)return CGRectMake(rect.origin.x/frame.zoom+frame.cameraX,rect.origin.y/frame.zoom+frame.cameraY,rect.size.width/frame.zoom,rect.size.height/frame.zoom);
    return rect;
}

// One output on screen: its layer, the frame description refilled in place, and the
// elements and placements of the windows it shows.
@interface DWCanvasOutput : NSObject
@property IFCompositorLayer *layer;
@property IFCompositorFrame *frame;
// The background as this output draws it: its own chunk cache when the program has one, else the program itself.
@property IFBackgroundProgram *background;
@property NSMutableDictionary<NSNumber *,IFCompositorElement *> *elements;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *placements;
@property NSMutableDictionary<NSNumber *,DWCanvasFamily *> *attachments;
@property NSMutableDictionary<NSNumber *,DWCanvasGeometry *> *geometry;
@property BOOL geometryAnimating;
@property BOOL geometryNeedsSettledDraw;
@property CGRect geometryBounds;
// Includes physical placements absent from `elements`: their tokens are barriers.
@property NSArray<NSDictionary *> *orderPlacements;
@property NSDictionary *orderOutput;
@property NSDictionary *orderSnapshot;
@property NSDictionary *orderMatchedSnapshot;
@property NSArray<NSDictionary *> *orderBinding;
@property NSArray<NSDictionary *> *orderBase,*orderApplied;
@property NSDictionary<NSDictionary *,IFCompositorElement *> *orderElements;
@property id orderProvider,orderRevisionProvider;
@property uint64_t orderRevision;
@property BOOL orderDirty;
// Separate caches for family closing bakes. The compositor's per-device command
// queue is shared with this output, so a committed bake precedes its next draw.
@property IFCompositorRenderer *attachmentRenderer;
@property uint64_t attachmentSerial;
@property NSUInteger style; // the configuration its frame carries
@property BOOL dirty;
// Upstream's closing bucket as this output lists it, bottom to top: the fading stand-ins, newest first, then the closing snapshots, newest first.
@property NSMutableArray<IFCompositorElement *> *leaving;
// Upstream opens a window, and fades the stand-in it adopted, at the window's first sized commit: the first frame it has a
// picture for. A window that maps here has none until its stream delivers. Until then, and for a second at most, what its
// picture starts is held at its first instant: its own opening, which is invisible, and the stand-in of its slot, whole.
@property NSMutableDictionary<NSNumber *,NSNumber *> *unseen; // such windows: when each began to wait
@property NSMutableDictionary<NSNumber *,IFCompositorElement *> *adopted; // the stand-in fade that waits with one
// A window whose size the controller is still changing (snapshot.native_resize with an effect outstanding: a rule's size asked as the window
// maps, or a sizing action) is given no settled picture by the shell until that is over, so for it the second above has not begun: it begins
// when the last effect is answered. A window that is held for its size is held even when it has a picture, which the setter is about to
// withdraw. The shell's adapter allows each effect of a transaction two seconds, and a transaction that sets one size has four at most (a
// read, the setter, a read, and one more after a setter that stays unresolved): sizeHold, above them, is the most a window is held for it.
@property NSMutableDictionary<NSNumber *,NSNumber *> *owed; // of the unseen windows, those held for their size: since when
@property uint64_t serial; // the newest lifecycle event this output was described with
@property double presented; // the time of the last frame its layer drew
// A filling chunk cache is given one frame per tick of the shell's frame timer, as upstream's allowances are per output frame. drawn: the layer drew since
// the last tick asked (-animates:draw:) for a reason of its own (the camera frame of a flight, a window's picture, a decoded chunk's wake-up), and that draw
// is the tick's frame. forced: the redraw a tick asked for itself, which is no such reason.
@property BOOL drawn,forced;
@property BOOL awaitingDrawable;
@property NSUInteger taken; // of its layer's presentedCount, what -takeCounts has reported
@end
@implementation DWCanvasOutput
@end
@implementation DWCanvasAttachment
- (instancetype)init {if((self=[super init]))_contentRect=CGRectNull;return self;}
- (void)setBuffer:(CVPixelBufferRef)buffer {
    if(buffer==_buffer)return;if(buffer)CVPixelBufferRetain(buffer);if(_buffer)CVPixelBufferRelease(_buffer);_buffer=buffer;
}
- (void)dealloc {if(_buffer)CVPixelBufferRelease(_buffer);}
@end
@interface DWCanvasRenderer ()
@property (copy) DWCanvasSource source;
@property NSMutableDictionary<NSNumber *,DWCanvasOutput *> *states;
@property IFBackgroundProgram *program;
@property(readwrite) BOOL inheritsMacBackground;
@property IFCompositorChromeStyle *chrome;
@property IFCompositorOutlineSettings outline;
@property NSNumber *revision;
@property NSUInteger style; // counts configurations
@property (readwrite) NSString *note;
@property BOOL pending;
@property IFCompositorEffects effects;
@property NSArray<NSString *> *errors; // the error bar's messages in upstream's source order, nil for none
@property uint64_t played; // the newest lifecycle event played
@property BOOL following; // the first frame described has set that mark
@property uint64_t marks; // counts the identifiers of closing-bucket elements
@property NSNumber *sizing; // the window the controller owes a size, as the snapshot last described had it
@property BOOL paced; // inside -flushFrame: the display link's own frame, which the layers may present by themselves
@property BOOL placed; // an output described since the last flush is new, or its layer changed its place, size or scale
@property CFTimeInterval frameTarget; // the current display tick's upcoming refresh, also valid for a drawable retry
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
- (BOOL)configure:(NSDictionary *)snapshot {
    NSDictionary *render=dict(snapshot[@"render"]);NSNumber *revision=number(render[@"revision"]);
    // An unanswered snapshot changes nothing; the first call builds upstream's defaults at least.
    if(self.program&&(!snapshot||revision==self.revision||[revision isEqual:self.revision]))return NO;
    self.revision=revision;self.style++;
    NSDictionary *b=dict(render[@"background"]),*c=dict(render[@"chrome"]),*o=dict(render[@"outline"]);NSString *warning=nil;
    self.inheritsMacBackground=[number(b[@"inherit_macos"])boolValue];
    // Upstream BackgroundConfig, field for field; the module expands ~ and falls back by itself.
    IFBackgroundConfig *config=[IFBackgroundConfig configWithTypeString:text(b[@"type"]) path:text(b[@"path"]) texture:text(b[@"texture"]) warning:&warning];
    config.mirrorTile=[number(b[@"mirror_tile"])boolValue];config.transparentShader=[number(b[@"transparent_shader"])boolValue];config.cacheShader=[number(b[@"cache_shader"])boolValue];
    if(number(b[@"parallax"]))config.parallax=[number(b[@"parallax"])boolValue];
    config.animateFPS=(NSUInteger)lround(fmin(fmax([number(b[@"animate_fps"])doubleValue],0),1000));
    // Upstream's u32 of megabytes; a controller that does not report the key leaves upstream's default of 128.
    if(number(b[@"cache_budget_mb"]))config.cacheBudgetMB=(NSUInteger)llround(fmin(fmax([b[@"cache_budget_mb"]doubleValue],0),UINT32_MAX));
    self.program=[IFBackgroundProgram programWithConfig:config device:nil];self.note=self.program.errorText?:warning;
    IFCompositorChromeStyle *style=[IFCompositorChromeStyle new];
    style.backgroundColor=colorOf(c[@"background"],style.backgroundColor);style.foregroundColor=colorOf(c[@"foreground"],style.foregroundColor);
    if(number(c[@"corner_radius"]))style.cornerRadius=lround([c[@"corner_radius"]doubleValue]);
    if(number(c[@"title_bar_height"]))style.titleBarHeight=lround([c[@"title_bar_height"]doubleValue]);
    if(text(c[@"font"]).length)style.font=c[@"font"];
    if(number(c[@"font_size"]))style.fontSize=(NSUInteger)lround(fmax([c[@"font_size"]doubleValue],0));
    if(text(c[@"font_weight"]))style.fontWeight=weightOf(c[@"font_weight"]);
    if(text(c[@"title_align"]))style.titleAlign=[c[@"title_align"]isEqual:@"left"]?IFCompositorTitleAlignLeft:IFCompositorTitleAlignCenter;
    self.chrome=style;
    IFCompositorOutlineSettings outline=IFCompositorOutlineSettingsDefault();outline.color=colorOf(o[@"color"],outline.color);
    if(number(o[@"thickness"]))outline.thickness=(int32_t)lround([o[@"thickness"]doubleValue]);
    if(number(o[@"opacity"]))outline.opacity=[o[@"opacity"]doubleValue];
    self.outline=outline;
    // Upstream EffectsConfig, field for field, as the controller's parser left it; the compositor's own copy of upstream's parse rules changes nothing in it.
    NSDictionary *e=dict(render[@"effects"]);IFCompositorEffects effects=IFCompositorEffectsDefault();
    if(number(e[@"blur_radius"]))effects.blurRadius=(uint32_t)lround(fmin(fmax([e[@"blur_radius"]doubleValue],0),UINT32_MAX));
    if(number(e[@"blur_strength"]))effects.blurStrength=[e[@"blur_strength"]doubleValue];
    if(number(e[@"animate_blur_fps"]))effects.animateBlurFPS=(uint32_t)lround(fmin(fmax([e[@"animate_blur_fps"]doubleValue],0),UINT32_MAX));
    if(number(e[@"animation_speed"]))effects.animationSpeed=[e[@"animation_speed"]doubleValue];
    if(number(e[@"animation_scale"]))effects.animationScale=[e[@"animation_scale"]doubleValue];
    self.effects=IFCompositorEffectsSanitized(effects);
    // Upstream's error bar shows state.errors in the order of ErrorSource: config, background, keyboard. The controller sends its own
    // sources' messages in that order, config first, and the background's is this program's, so it follows the first of them.
    NSMutableArray<NSString *> *errors=[NSMutableArray array];for(id message in list(render[@"errors"]))if(text(message))[errors addObject:message];
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
    IFBackgroundProgram *base=self.backgroundForOutput?self.backgroundForOutput(number(description[@"id"]),description,self.program):nil;
    base=base?:self.program;state.background=[base programForOutput];if(state.background==base)return;
    __weak DWCanvasRenderer *weak=self;__weak DWCanvasOutput *output=state;
    state.background.chunkReadyHandler=^{DWCanvasOutput *shown=output;if(!shown.frame.background){[shown.background shrinkChunkCache];return;}shown.dirty=YES;[shown.layer setNeedsRedraw];[weak setNeedsFlush];};
}
- (void)refreshBackgrounds {
    if(!self.program||!self.backgroundForOutput)return;BOOL changed=NO;
    for(DWCanvasOutput *state in self.states.allValues){
        IFBackgroundProgram *prior=state.background;[self cache:state output:state.orderOutput];if(state.background==prior)continue;
        [prior shrinkChunkCache];NSDictionary *full=dict(state.orderOutput[@"fullscreen"]);
        state.frame.background=full&&![text(full[@"backdrop"])isEqual:@"canvas"]?nil:state.background;
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
static BOOL pinnedOf(NSDictionary *p) { return [number(p[@"pinned"])boolValue]||dict(p[@"pinned"])!=nil; }
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
- (void)fill:(IFCompositorElement *)element window:(NSNumber *)window placement:(NSDictionary *)p snapshot:(NSDictionary *)snapshot rect:(CGRect)world onScreen:(BOOL)onScreen {
    NSString *kind=text(p[@"kind"]),*title=text(p[@"title"]),*app=displayName(text(p[@"app_name"]));BOOL standin=kind?[kind isEqual:@"standin"]:!dict(p[@"source"]);
    element.identifier=window.unsignedLongLongValue;element.kind=standin?IFCompositorElementKindStandIn:IFCompositorElementKindWindow;
    element.space=onScreen?IFCompositorSpacePinned:IFCompositorSpaceCanvas;
    element.layer=onScreen?IFCompositorStackLayerPinned:[number(p[@"widget"])boolValue]?IFCompositorStackLayerWidget:IFCompositorStackLayerNormal;
    // Upstream's dot at the left of a pinned window's title bar. The compositor draws it in a `server` bar only: a stand-in's bar and a client-decorated window show none.
    element.showsPinnedIndicator=pinnedOf(p);
    element.focused=number(p[@"focused"])?[p[@"focused"]boolValue]:[snapshot[@"focused"]isEqual:window];
    element.decoration=decorationOf(dict(p[@"decoration"]),self.chrome.cornerRadius);
    element.appName=app;element.launching=[number(p[@"launching"])boolValue];
    if(standin){element.title=title;element.rect=IFCompositorStandInBodyRect(world,YES,self.chrome.titleBarHeight);element.pixelBuffer=NULL;element.texture=nil;element.contentGeneration=0;element.contentRect=CGRectNull;return;}
    // A server title bar shows the title, else the application's name, as upstream falls back to the app id.
    element.title=title.length?title:app?:@"";element.rect=world;
    [self content:element window:window placement:p];
}
// When an animation that begins now began, on this output's clock. Upstream advances every animation before it draws, so the
// first frame that shows one is already a tick in: the time of the last frame presented. This canvas draws on demand, so
// that frame can be long past, and the animation would be over before it was seen: never more than one 60 Hz tick ago.
static double began(DWCanvasOutput *state,double now) { return fmax(state.presented,now-1.0/60); }
static BOOL pictured(IFCompositorElement *element) { return element.pixelBuffer||element.texture; }
static const double sizeHold=10;
// A closing-bucket element stays in the frame beside whatever keeps its window's identifier, so it carries one of its own.
- (uint64_t)mark { return 1ULL<<63|++self.marks; }
// The hit order is tied to the output and its ordered placements, including each
// exact source/generation binding. Hover can decode another equivalent snapshot;
// its focused flag alone does not change this geometry or attachment membership.
static NSArray<NSDictionary *> *orderBinding(NSDictionary *snapshot,NSNumber *output) {
    NSMutableArray *placements=[NSMutableArray array];
    for(id entry in list(snapshot[@"placements"])){
        NSDictionary *p=dict(entry);if(![p[@"output"]isEqual:output])continue;
        if(p[@"focused"]){NSMutableDictionary *binding=[p mutableCopy];[binding removeObjectForKey:@"focused"];[placements addObject:binding.copy];}
        else [placements addObject:p];
    }
    return placements.copy;
}
// Accept only the complete original tokens. Roots retain controller order and a
// child cannot move between compositor buckets or through a physical/stand-in/
// closing barrier. Provider dictionaries carry no additional ordering authority.
static NSArray<NSDictionary *> *validatedOrder(NSArray<NSDictionary *> *candidate,NSArray<NSDictionary *> *base) {
    if(![candidate isKindOfClass:NSArray.class]||candidate.count!=base.count)return base;
    NSSet *expected=[NSSet setWithArray:base];NSMutableSet *seen=[NSMutableSet set];
    NSMutableDictionary<NSDictionary *,NSNumber *> *segments=[NSMutableDictionary dictionary];
    NSMutableArray *roots=[NSMutableArray array],*nextRoots=[NSMutableArray array],*accepted=[NSMutableArray array];NSUInteger segment=0;NSNumber *bucket=nil;
    for(NSDictionary *token in base){
        if(![bucket isEqual:token[@"bucket"]]){bucket=token[@"bucket"];segment++;}
        if([token[@"barrier"]boolValue])segment++;
        segments[token]=@(segment);
        if(token[@"window"]&&!token[@"key"])[roots addObject:token];
        if([token[@"barrier"]boolValue])segment++;
    }
    for(NSUInteger i=0;i<candidate.count;i++){
        NSDictionary *token=dict(candidate[i]),*original=base[i];
        if(!token||![expected containsObject:token]||[seen containsObject:token]||![token[@"bucket"]isEqual:original[@"bucket"]])return base;
        if([original[@"barrier"]boolValue]?![token isEqual:original]:[token[@"barrier"]boolValue]||![segments[token]isEqual:segments[original]])return base;
        [seen addObject:token];[accepted addObject:[expected member:token]];if(token[@"window"]&&!token[@"key"])[nextRoots addObject:token];
    }
    // Retain our immutable original tokens, never a provider's mutable copies.
    return [roots isEqualToArray:nextRoots]?accepted.copy:base;
}
- (void)rebuildOrderForState:(DWCanvasOutput *)state {
    NSMutableArray<NSDictionary *> *tokens=[NSMutableArray array];NSMutableDictionary<NSDictionary *,IFCompositorElement *> *elements=[NSMutableDictionary dictionary];
    static const IFCompositorStackLayer buckets[]={IFCompositorStackLayerWidget,IFCompositorStackLayerNormal,IFCompositorStackLayerClosing,IFCompositorStackLayerPinned};
    for(NSUInteger i=0;i<sizeof(buckets)/sizeof(*buckets);i++){
        IFCompositorStackLayer bucket=buckets[i];
        for(NSDictionary *p in state.orderPlacements){
            NSNumber *window=p[@"window"];IFCompositorElement *root=state.elements[window];
            IFCompositorStackLayer layer=root?root.layer:[number(p[@"pinned"])boolValue]?IFCompositorStackLayerPinned:[number(p[@"widget"])boolValue]?IFCompositorStackLayerWidget:IFCompositorStackLayerNormal;
            if(layer!=bucket)continue;
            BOOL barrier=!root||root.kind==IFCompositorElementKindStandIn;
            NSDictionary *token=barrier?@{@"window":window,@"bucket":@(bucket),@"barrier":@YES}:@{@"window":window,@"bucket":@(bucket)};
            [tokens addObject:token];if(root)elements[token]=root;
            for(DWCanvasChild *child in state.attachments[window].ordered){
                NSDictionary *member=@{@"window":window,@"key":child.key,@"bucket":@(bucket)};
                [tokens addObject:member];elements[member]=child.element;
            }
        }
        if(bucket==IFCompositorStackLayerClosing)for(IFCompositorElement *element in state.leaving){
            if(![state.frame.elements containsObject:element])continue;
            NSDictionary *token=@{@"mark":@(element.identifier),@"bucket":@(bucket),@"barrier":@YES};[tokens addObject:token];elements[token]=element;
        }
    }
    state.orderBase=tokens.copy;state.orderElements=elements.copy;state.orderDirty=NO;
}
// The base token list is cached across video frames. A coherent provider cohort
// can change order even when this output shows none of the callback's root, so
// every content callback checks revisions on every output before skipping it.
- (BOOL)applyOrderForOutput:(NSNumber *)output state:(DWCanvasOutput *)state {
    uint64_t revision=self.liveOrderRevision?self.liveOrderRevision(output):0;
    if(!state.orderDirty&&state.orderProvider==self.liveOrder&&state.orderRevisionProvider==self.liveOrderRevision&&(!self.liveOrder||(self.liveOrderRevision&&state.orderRevision==revision)))return NO;
    if(state.orderDirty)[self rebuildOrderForState:state];
    NSArray *order=validatedOrder(self.liveOrder?self.liveOrder(state.orderBase,output):nil,state.orderBase);
    NSMutableArray<IFCompositorElement *> *elements=[NSMutableArray array];for(NSDictionary *token in order)if(state.orderElements[token])[elements addObject:state.orderElements[token]];
    // A missing description is never a usable hit order. It cannot silently drop
    // a visual element should a future compositor element lack a token adapter.
    if(elements.count!=state.frame.elements.count){state.orderApplied=nil;return NO;}
    BOOL changed=![state.frame.elements isEqualToArray:elements];if(changed)[state.frame.elements setArray:elements];
    state.orderApplied=order;state.orderRevision=revision;state.orderProvider=self.liveOrder;state.orderRevisionProvider=self.liveOrderRevision;
    return changed;
}
- (NSArray<NSDictionary *> *)appliedOrderForOutput:(NSNumber *)output snapshot:(NSDictionary *)snapshot {
    DWCanvasOutput *state=self.states[output];if(!state.orderApplied||!snapshot||state.orderDirty||state.geometryAnimating||state.geometryNeedsSettledDraw||state.orderProvider!=self.liveOrder||state.orderRevisionProvider!=self.liveOrderRevision)return nil;
    if(self.liveOrderRevision){if(state.orderRevision!=self.liveOrderRevision(output))return nil;}
    else if(![state.orderApplied isEqualToArray:validatedOrder(self.liveOrder?self.liveOrder(state.orderBase,output):nil,state.orderBase)])return nil;
    if(snapshot!=state.orderSnapshot&&snapshot!=state.orderMatchedSnapshot){
        NSDictionary *current=nil;for(id entry in list(snapshot[@"outputs"])){NSDictionary *o=dict(entry);if(drawableOutput(o)&&[o[@"id"]isEqual:output]){current=o;break;}}
        if(![state.orderOutput isEqual:current]||![state.orderBinding isEqualToArray:orderBinding(snapshot,output)])return nil;
        state.orderMatchedSnapshot=snapshot;
    }
    // Keys that no longer name retained live images cannot authorize input, even
    // if an unchanged provider revision incorrectly accompanies the withdrawal.
    for(NSDictionary *token in state.orderApplied)if(token[@"key"]){DWCanvasChild *child=state.attachments[token[@"window"]].images[token[@"key"]];if(!child||!child.element.pixelBuffer||child.element!=state.orderElements[token])return nil;}
    return state.orderApplied;
}
// Children inherit the final root geometry, including fullscreen and screen
// pins. An opening scales the whole family about the root's centre: giving each
// child its own Opening lifecycle would incorrectly grow it about its own centre.
- (void)geometryForFamily:(DWCanvasFamily *)family root:(IFCompositorElement *)root frame:(IFCompositorFrame *)frame {
    CGRect world=root.rect;IFCompositorDecoration decoration=IFCompositorDecorationDefault();
    decoration.mode=IFCompositorDecorationModeNone;decoration.borderWidth=0;decoration.cornerRadius=0;decoration.shadow=NO;decoration.opacity=root.decoration.opacity;
    BOOL transformed=root.hasTransform;IFCompositorTransform transform=root.transform;
    if(root.lifecycle==IFCompositorLifecycleOpening&&![frame lifecycleFinishedForElement:root]){
        double progress=[frame lifecycleProgressOfElement:root],scale=IFCompositorOpenScale(progress,frame.effects.animationScale);
        double zoom=root.space==IFCompositorSpacePinned?1:frame.zoom,density=frame.scale*zoom;
        double x=root.space==IFCompositorSpaceCanvas?world.origin.x-frame.cameraX:world.origin.x,y=root.space==IFCompositorSpaceCanvas?world.origin.y-frame.cameraY:world.origin.y;
        if(root.space==IFCompositorSpaceOutput){x/=zoom;y/=zoom;}
        double w=world.size.width,h=world.size.height;if(root.space==IFCompositorSpaceOutput){w/=zoom;h/=zoom;}
        transform=(IFCompositorTransform){x*density,y*density,(w-w*scale)/2*density,(h-h*scale)/2*density,w*scale/fmax(w,1),h*scale/fmax(h,1)};
        transformed=YES;decoration.opacity*=IFCompositorOpenAlpha(progress);
    }
    for(DWCanvasChild *image in family.ordered){
        IFCompositorElement *child=image.element;CGRect r=image.unitRect;
        child.rect=CGRectMake(world.origin.x+r.origin.x*world.size.width,world.origin.y+r.origin.y*world.size.height,r.size.width*world.size.width,r.size.height*world.size.height);
        child.space=root.space;child.layer=root.layer;child.decoration=decoration;child.hasTransform=transformed;child.transform=transform;
        child.hasClipRect=root.hasClipRect;child.clipRect=root.clipRect;
    }
}
// Refresh just this root's live family in the existing frame. Elements and their
// mark identifiers survive frames by opaque key; a withdrawn image releases its
// retained pixels immediately, including if a provider reuses its key later.
- (void)attachmentsForWindow:(NSNumber *)window output:(NSNumber *)output state:(DWCanvasOutput *)state {
    IFCompositorElement *root=state.elements[window];DWCanvasFamily *family=state.attachments[window];
    NSArray<DWCanvasAttachment *> *supplied=root.kind==IFCompositorElementKindWindow&&self.liveAttachments?self.liveAttachments(window,output):nil;
    if(!family&&!supplied.count)return;
    if(!family){family=[DWCanvasFamily new];family.images=[NSMutableDictionary dictionary];family.ordered=@[];state.attachments[window]=family;}
    NSArray<DWCanvasChild *> *ordered=family.ordered;
    // Ordinary capture and camera frames keep the same family. Validate every
    // current image and its ordered key before reusing the list; no provider
    // array/object identity or prior validity can keep withdrawn pixels alive.
    // The existing ordered keys are unique, so an exact match also excludes a
    // duplicate without allocating another set for every pixel frame.
    BOOL same=supplied.count==ordered.count;
    if(same)for(NSUInteger i=0;i<supplied.count;i++){
        DWCanvasAttachment *image=supplied[i];
        if(!validAttachment(image)||![ordered[i].key isEqual:image.key]){same=NO;break;}
    }
    if(same){
        for(NSUInteger i=0;i<supplied.count;i++){
            DWCanvasAttachment *image=supplied[i];DWCanvasChild *child=ordered[i];
            child.unitRect=image.unitRect;child.element.pixelBuffer=image.buffer;child.element.texture=nil;child.element.contentGeneration=image.generation;child.element.contentRect=image.contentRect;
        }
    }else{
        NSMutableArray<DWCanvasChild *> *next=[NSMutableArray array];NSMutableSet<NSString *> *keys=[NSMutableSet set];
        for(DWCanvasAttachment *image in supplied){
            if(!validAttachment(image))continue;NSString *key=image.key;CGRect r=image.unitRect;
            if(!key.length||[keys containsObject:key])continue;
            [keys addObject:key];DWCanvasChild *child=family.images[key];
            if(!child){child=[DWCanvasChild new];child.key=key;child.element=[IFCompositorElement new];child.element.identifier=[self mark];child.element.kind=IFCompositorElementKindWindow;family.images[key]=child;}
            child.unitRect=r;child.element.pixelBuffer=image.buffer;child.element.texture=nil;child.element.contentGeneration=image.generation;child.element.contentRect=image.contentRect;
            [next addObject:child];
        }
        for(NSString *key in family.images.allKeys)if(![keys containsObject:key]){
            DWCanvasChild *child=family.images[key];child.element.pixelBuffer=NULL;child.element.texture=nil;child.element.contentGeneration=0;[family.images removeObjectForKey:key];
        }
        ordered=next;
    }
    // On a description the frame was emptied; on a content callback only a
    // changed family order or membership needs to splice the element list.
    BOOL present=family.ordered.count&&[state.frame.elements containsObject:family.ordered.firstObject.element];
    if(!present||![family.ordered isEqualToArray:ordered]){
        state.orderDirty=YES;
        for(DWCanvasChild *child in family.ordered)[state.frame.elements removeObject:child.element];
        NSUInteger at=[state.frame.elements indexOfObjectIdenticalTo:root];
        if(at!=NSNotFound)for(DWCanvasChild *child in ordered)[state.frame.elements insertObject:child.element atIndex:++at];
    }
    family.ordered=ordered;
    if(ordered.count)[self geometryForFamily:family root:root frame:state.frame];else [state.attachments removeObjectForKey:window];
}
// Flatten the family once, retaining immutable textures rather than capture
// buffers after it closes. First use the compositor's exact chrome bake for the
// root and every child, then compose their currently applied relative order at
// zoom 1. Flattening a family cannot preserve interleaving with another family.
// The temporary renderer has its own caches and the output's device/queue; it
// cannot evict the output's live-window caches or require a main-thread GPU wait.
- (IFCompositorElement *)closingFamily:(NSNumber *)window state:(DWCanvasOutput *)state flattenScale:(double)flattenScale {
    IFCompositorElement *root=state.elements[window];DWCanvasFamily *family=state.attachments[window];IFCompositorRenderer *output=state.layer.renderer;
    if(!family.ordered.count)return [output closingSnapshotOfElement:root inFrame:state.frame flattenScale:flattenScale];
    if(!state.attachmentRenderer)state.attachmentRenderer=[IFCompositorRenderer rendererWithDevice:output.device];
    IFCompositorRenderer *renderer=state.attachmentRenderer;if(!renderer||renderer.commandQueue!=output.commandQueue)return nil;
    double scale=isfinite(flattenScale)&&flattenScale>1?flattenScale:1,zoom=isfinite(state.frame.zoom)&&state.frame.zoom>0?state.frame.zoom:1;
    double unit=root.space==IFCompositorSpaceOutput?zoom:1;
    NSMutableArray<IFCompositorElement *> *baked=[NSMutableArray array];CGRect bounds=CGRectNull;CGPoint centre=CGPointZero;
    NSMutableSet<IFCompositorElement *> *members=[NSMutableSet setWithObject:root];for(DWCanvasChild *child in family.ordered)[members addObject:child.element];
    NSMutableArray<IFCompositorElement *> *images=[NSMutableArray array];for(IFCompositorElement *element in state.frame.elements)if([members containsObject:element])[images addObject:element];
    if(images.count!=members.count)return nil;
    for(IFCompositorElement *image in images){
        IFCompositorElement *picture=[renderer closingSnapshotOfElement:image inFrame:state.frame flattenScale:scale];
        if(!picture){[renderer purge];return nil;}
        CGRect rect=picture.rect;rect=CGRectMake(rect.origin.x/unit,rect.origin.y/unit,rect.size.width/unit,rect.size.height/unit);
        if(!finiteImageRect(rect)){[renderer purge];return nil;}
        picture.rect=rect;picture.space=IFCompositorSpaceCanvas;picture.hasClipRect=NO;picture.lifecycle=IFCompositorLifecycleClosingAlphaOnly;picture.lifecycleStartTime=NAN;picture.lifecycleProgress=0;picture.contentGeneration=image.contentGeneration;
        if(image==root)centre=CGPointMake(CGRectGetMidX(rect),CGRectGetMidY(rect));bounds=CGRectUnion(bounds,rect);[baked addObject:picture];
    }
    // Keep upstream's root closing pivot even when a popup extends far beyond
    // one side. Transparent padding on the opposite side keeps the family from
    // shifting as its one texture shrinks; it is never clipped to the root.
    double halfWidth=fmax(centre.x-CGRectGetMinX(bounds),CGRectGetMaxX(bounds)-centre.x),halfHeight=fmax(centre.y-CGRectGetMinY(bounds),CGRectGetMaxY(bounds)-centre.y);
    double width=ceil(2*halfWidth*scale),height=ceil(2*halfHeight*scale);
    if(!isfinite(width)||!isfinite(height)||width<=0||height<=0||width>16384||height>16384){[renderer purge];return nil;}
    bounds=CGRectMake(centre.x-width/scale/2,centre.y-height/scale/2,width/scale,height/scale);
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)width height:(NSUInteger)height mipmapped:NO];
    descriptor.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;descriptor.storageMode=MTLStorageModePrivate;
    id<MTLTexture> texture=[renderer.device newTextureWithDescriptor:descriptor];id<MTLCommandBuffer> command=[renderer.commandQueue commandBuffer];
    if(!texture||!command){[renderer purge];return nil;}
    IFCompositorFrame *frame=[IFCompositorFrame new];frame.size=bounds.size;frame.scale=scale;frame.cameraX=bounds.origin.x;frame.cameraY=bounds.origin.y;frame.zoom=1;frame.clear=IFCompositorClearTransparent;
    frame.chrome=state.frame.chrome;frame.decorationScale=state.frame.decorationScale;frame.effects=state.frame.effects;frame.time=state.frame.time;[frame.elements addObjectsFromArray:baked];
    BOOL encoded=[renderer encodeFrame:frame intoTexture:texture commandBuffer:command];[command commit];[renderer purge];if(!encoded)return nil;
    IFCompositorElement *snapshot=[IFCompositorElement new];snapshot.identifier=root.identifier;snapshot.kind=IFCompositorElementKindSnapshot;snapshot.space=root.space;snapshot.layer=IFCompositorStackLayerClosing;
    snapshot.rect=CGRectMake(bounds.origin.x*unit,bounds.origin.y*unit,bounds.size.width*unit,bounds.size.height*unit);snapshot.hasClipRect=root.hasClipRect;snapshot.clipRect=root.clipRect;
    snapshot.texture=texture;snapshot.contentGeneration=++state.attachmentSerial;snapshot.lifecycle=IFCompositorLifecycleClosing;snapshot.lifecycleProgress=0;return snapshot;
}
// A window closed (upstream snapshot_closing_window): on each output that drew it, the element of the frame last described is
// baked with all its chrome and live attachments into one texture, and that snapshot shrinks and fades in the closing bucket, or with inPlace fades
// where it stood, over the stand-in the window left (upstream's alpha_only). That element still retains the pixel buffer it
// drew, whatever the shell did with the window's stream since, until this output is described again: the bake comes first.
// Upstream's skips: a window no output showed has no element here; one that never had a picture has nothing to bake; and its
// age test, pixels of a window hidden more than a second ago, cannot come up, since what is baked is what the last frame showed.
// The density is upstream's flatten scale: the largest backing scale times zoom among the outputs showing a canvas window, the
// backing scale of its output for a pinned one, at least 1. Each output bakes its own copy at it, with the chrome it drew.
- (void)close:(NSNumber *)window inPlace:(BOOL)inPlace now:(double)now {
    double density=1;
    for(DWCanvasOutput *state in self.states.allValues){IFCompositorElement *element=state.elements[window];if(element.kind==IFCompositorElementKindWindow&&element.space!=IFCompositorSpacePinned&&pictured(element))density=fmax(density,state.frame.scale*state.frame.zoom);}
    for(DWCanvasOutput *state in self.states.allValues){
        IFCompositorElement *element=state.elements[window],*snapshot=nil;if(!element||element.kind!=IFCompositorElementKindWindow||!pictured(element))continue;
        @autoreleasepool{snapshot=[self closingFamily:window state:state flattenScale:element.space==IFCompositorSpacePinned?state.frame.scale:density];}
        if(!snapshot)continue;
        snapshot.identifier=[self mark];snapshot.lifecycle=inPlace?IFCompositorLifecycleClosingAlphaOnly:IFCompositorLifecycleClosing;snapshot.lifecycleStartTime=began(state,now);
        // Upstream's order: in front of the first snapshot in the list, so beneath every snapshot still running and above every fading stand-in.
        NSUInteger at=0;while(at<state.leaving.count&&state.leaving[at].kind!=IFCompositorElementKindSnapshot)at++;
        [state.leaving insertObject:snapshot atIndex:at];
    }
}
// A stand-in left (upstream StandInFade): the stand-in of the frame last described fades in the closing bucket, shrinking when
// it was dismissed and, with inPlace, where it stood over the window that adopted its slot, from that window's first picture.
// Beneath every snapshot and every older fade: first in the list.
- (void)fade:(NSNumber *)window inPlace:(BOOL)inPlace now:(double)now {
    for(DWCanvasOutput *state in self.states.allValues){
        IFCompositorElement *old=state.elements[window];if(!old||old.kind!=IFCompositorElementKindStandIn)continue;
        IFCompositorElement *fade=[IFCompositorElement new];fade.identifier=[self mark];fade.kind=IFCompositorElementKindStandIn;fade.rect=old.rect;fade.space=old.space;fade.layer=IFCompositorStackLayerClosing;
        fade.focused=old.focused;fade.decoration=old.decoration;fade.title=old.title;fade.appName=old.appName;fade.launching=old.launching;fade.showsPinnedIndicator=old.showsPinnedIndicator;
        fade.lifecycle=inPlace?IFCompositorLifecycleClosingAlphaOnly:IFCompositorLifecycleClosing;
        // One fade waits per window: an earlier one that still does goes now.
        if(inPlace){state.adopted[window].lifecycleStartTime=began(state,now);state.unseen[window]=@(now);state.adopted[window]=fade;}else fade.lifecycleStartTime=began(state,now);
        [state.leaving insertObject:fade atIndex:0];
    }
}
// snapshot.lifecycle_events: the window events upstream animates, oldest first, each with a serial that only grows. Every
// event newer than the last one played is played once, here, before any output is described again, while each output still
// holds the elements of its last frame. What the list held when this renderer described its first frame happened before
// there was a frame to animate. An opening is the output's own to start, in -render:. With animation_speed 1 upstream's
// animations are over on their first tick, and nothing is played.
- (void)play:(NSDictionary *)snapshot now:(double)now {
    NSArray *events=list(snapshot[@"lifecycle_events"]);uint64_t played=self.played,newest=played;
    for(id event in events)newest=MAX(newest,[number(dict(event)[@"serial"])unsignedLongLongValue]);
    self.played=newest;if(!self.following){self.following=YES;return;}
    if(newest==played||self.effects.animationSpeed>=1)return;
    for(id entry in events){
        NSDictionary *event=dict(entry);NSNumber *window=number(event[@"window"]);NSString *name=text(event[@"event"]);
        if(!window||[number(event[@"serial"])unsignedLongLongValue]<=played)continue;
        if([name isEqual:@"close"]||[name isEqual:@"close_to_standin"])[self close:window inPlace:[name isEqual:@"close_to_standin"] now:now];
        else if([name isEqual:@"standin_dismiss"]||[name isEqual:@"standin_adopted"])[self fade:window inPlace:[name isEqual:@"standin_adopted"] now:now];
    }
}
// An authoritative snapshot can remove an output without a shell-wide reset.
// Stop its drawable worker and release every root/family image and closing bake,
// including cached wrappers after commands already encoded have finished.
- (void)stopOutput:(DWCanvasOutput *)state {
    [state.layer stopDrawing];[state.layer removeFromSuperlayer];state.frame.background=nil;[state.background shrinkChunkCache];
    for(IFCompositorElement *element in state.frame.elements){element.pixelBuffer=NULL;element.texture=nil;}
    [state.frame.elements removeAllObjects];[state.elements removeAllObjects];[state.placements removeAllObjects];[state.attachments removeAllObjects];[state.geometry removeAllObjects];state.geometryAnimating=NO;[state.leaving removeAllObjects];[state.adopted removeAllObjects];[state.unseen removeAllObjects];[state.owed removeAllObjects];
    state.orderPlacements=nil;state.orderOutput=nil;state.orderSnapshot=nil;state.orderMatchedSnapshot=nil;state.orderBinding=nil;state.orderBase=nil;state.orderApplied=nil;state.orderElements=nil;state.orderProvider=nil;state.orderRevisionProvider=nil;
    [state.layer.renderer purge];[state.attachmentRenderer purge];
}
- (void)describeGeometry:(NSDictionary *)snapshot state:(DWCanvasOutput *)state now:(double)now {
    BOOL wasAnimating=state.geometryAnimating;
    state.geometryAnimating=NO;
    // Physical WindowServer windows must keep the geometry submitted to their
    // native presenter; this overlay animation cannot move those windows.
    if(self.nativeWindows){[state.geometry removeAllObjects];state.geometryNeedsSettledDraw|=wasAnimating;return;}
    if(!state.geometry)state.geometry=[NSMutableDictionary dictionary];
    CGRect bounds=rectOf(state.orderOutput[@"screen_bounds"]);
    if(!CGRectEqualToRect(bounds,state.geometryBounds)){[state.geometry removeAllObjects];state.geometryBounds=bounds;}
    NSDictionary *resize=dict(snapshot[@"native_resize"]);NSString *phase=text(resize[@"phase"]);
    BOOL live=dict(resize[@"pending_effect"])||[phase isEqual:@"preparing"]||[phase isEqual:@"dragging"]||[phase isEqual:@"settling"];
    double duration=fmin(.35,fmax(.20,IFCompositorAnimationDuration(self.effects.animationSpeed)));
    for(NSNumber *window in state.geometry.allKeys)if(!state.elements[window])[state.geometry removeObjectForKey:window];
    for(NSNumber *window in state.elements){
        IFCompositorElement *element=state.elements[window];NSDictionary *p=state.placements[window],*source=dict(p[@"source"]),*identity=dict(source[@"identity"]);NSNumber *generation=number(source[@"generation"]);
        if(element.kind!=IFCompositorElementKindWindow||!identity||!generation||!finiteImageRect(element.rect)){[state.geometry removeObjectForKey:window];continue;}
        DWCanvasGeometry *geometry=state.geometry[window];BOOL known=geometry&&[geometry.identity isEqual:identity]&&[geometry.generation isEqual:generation];
        BOOL full=[number(p[@"fullscreen"])boolValue];
        BOOL action=[resize[@"window"]isEqual:window]&&number(resize[@"interactive"])&&![resize[@"interactive"]boolValue]&&[resize[@"identity"]isEqual:identity]&&[resize[@"generation"]isEqual:generation];
        NSNumber *transaction=action?number(resize[@"transaction"]):nil;CGRect target=element.rect;
        if(!known){geometry=[DWCanvasGeometry new];geometry.identity=identity;geometry.generation=generation;geometry.target=target;geometry.space=element.space;geometry.screen=geometryScreen(target,element.space,state.frame);state.geometry[window]=geometry;}
        BOOL changed=geometry.space!=element.space||!CGRectEqualToRect(geometry.target,target);
        BOOL permitted=(geometry.active||geometry.fullscreen!=full||(action&&(live||geometry.actionLive||![geometry.transaction isEqual:transaction])))&&!(action&&[geometry.blockedTransaction isEqual:transaction]);
        BOOL animate=known&&geometry.drawn&&pictured(element)&&element.lifecycle==IFCompositorLifecycleNone&&self.effects.animationSpeed<1&&!NSEvent.pressedMouseButtons;
        if(changed&&permitted&&animate){
            // A canvas/fullscreen space switch starts where the last frame drew
            // the window. Ordinary fit sizing stays in world space, so the
            // controller's already-smooth camera flight is not delayed again.
            CGRect from=geometry.space==element.space?geometryRect(geometry,now):geometryFromScreen(geometry.screen,element.space,state.frame);
            double end=geometry.active&&now<geometry.end?fmax(geometry.end,now+.04):now+duration;
            geometry.from=from;geometry.start=now;geometry.end=end;geometry.active=finiteImageRect(from)&&!CGRectEqualToRect(from,target);
        }else if(changed||!animate||now>=geometry.end)geometry.active=NO;
        geometry.target=target;geometry.space=element.space;geometry.fullscreen=full;geometry.actionLive=action&&live;geometry.transaction=transaction;
        element.rect=geometryRect(geometry,now);state.geometryAnimating|=geometry.active;
    }
    state.geometryNeedsSettledDraw|=wasAnimating&&!state.geometryAnimating;
}
- (void)advanceGeometry:(DWCanvasOutput *)state now:(double)now {
    if(!state.geometryAnimating)return;state.geometryAnimating=NO;
    for(NSNumber *window in state.geometry){DWCanvasGeometry *geometry=state.geometry[window];if(!geometry.active)continue;
        IFCompositorElement *element=state.elements[window];if(!element){geometry.active=NO;continue;}
        element.rect=geometryRect(geometry,now);if(now>=geometry.end)geometry.active=NO;state.geometryAnimating|=geometry.active;
    }
    state.geometryNeedsSettledDraw|=!state.geometryAnimating;
}
- (BOOL)hasGeometryTransitions {for(DWCanvasOutput *state in self.states.allValues)if(state.geometryAnimating||state.geometryNeedsSettledDraw)return YES;return NO;}
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
    if(!snapshot)return;
    // Reconcile against all snapshot outputs, not just this host's subset: a
    // separate host will describe the other displays in the same shell turn.
    NSMutableArray<NSDictionary *> *all=[NSMutableArray array];NSMutableSet<NSNumber *> *alive=[NSMutableSet set];
    for(id entry in list(snapshot[@"outputs"])){NSDictionary *output=dict(entry);if(drawableOutput(output)&&![alive containsObject:output[@"id"]]){[all addObject:output];[alive addObject:output[@"id"]];}}
    for(NSNumber *output in self.states.allKeys)if(![alive containsObject:output]){[self stopOutput:self.states[output]];[self.states removeObjectForKey:output];}
    if(!host)return;[self configure:snapshot];double now=canvasTime();[self play:snapshot now:now];
    // The windows an `open` event of this snapshot names, and the serial of each: an output that has not been described with it yet opens the window.
    NSMutableDictionary<NSNumber *,NSNumber *> *opened=[NSMutableDictionary dictionary];
    for(id entry in list(snapshot[@"lifecycle_events"])){NSDictionary *event=dict(entry);if(number(event[@"window"])&&number(event[@"serial"])&&[event[@"event"]isEqual:@"open"])opened[event[@"window"]]=event[@"serial"];}
    // The window the controller owes a size: its one size transaction, while an effect of it is outstanding. Null in a run that cannot deliver a size.
    NSDictionary *resize=dict(snapshot[@"native_resize"]);self.sizing=dict(resize[@"pending_effect"])?number(resize[@"window"]):nil;
    NSMutableDictionary<NSNumber *,id> *worlds=[NSMutableDictionary dictionary];
    for(NSDictionary *w in list(snapshot[@"windows"]))if(number(w[@"window"])&&w[@"world_rect"])worlds[w[@"window"]]=w[@"world_rect"];
    for(NSDictionary *o in all){
        NSNumber *output=number(o[@"id"]);CGRect bounds=rectOf(o[@"screen_bounds"]);if(![alive containsObject:output]||![outputs containsObject:output])continue;
        DWCanvasOutput *state=self.states[output];
        // An output that is new shows no event that came before it: nothing was on it to open.
        if(!state){state=self.states[output]=[DWCanvasOutput new];state.layer=[[IFCompositorLayer alloc]initWithRenderer:nil];state.frame=[IFCompositorFrame new];state.elements=[NSMutableDictionary dictionary];state.placements=[NSMutableDictionary dictionary];state.attachments=[NSMutableDictionary dictionary];state.leaving=[NSMutableArray array];state.unseen=[NSMutableDictionary dictionary];state.adopted=[NSMutableDictionary dictionary];state.owed=[NSMutableDictionary dictionary];state.serial=self.played;state.layer.countsPresented=self.measured;state.layer.asynchronousDrawables=!self.synchronousDrawables;__weak DWCanvasRenderer *weak=self;state.layer.drawableReady=^{[weak retryDrawable:output];};self.placed=YES;}
        // Below the toolbar and the status line, as the window tiles were.
        if(state.layer.superlayer!=host){[host insertSublayer:state.layer atIndex:0];self.placed=YES;}
        CGRect place=CGRectOffset(bounds,-origin.x,-origin.y);if(!CGRectEqualToRect(state.layer.frame,place)){state.layer.frame=place;self.placed=YES;}
        IFCompositorFrame *frame=state.frame;CGPoint camera=pointOf(o[@"camera"]);double zoom=[number(o[@"zoom"])doubleValue];
        if(frame.scale!=(scale>0?scale:1))self.placed=YES;
        frame.size=bounds.size;frame.scale=scale>0?scale:1;frame.cameraX=camera.x;frame.cameraY=camera.y;frame.zoom=zoom;frame.clear=IFCompositorClearOpaqueBlack;frame.decorationScale=decorationScale;
        if(state.style!=self.style||!CGRectEqualToRect(bounds,rectOf(state.orderOutput[@"screen_bounds"]))){state.style=self.style;[self cache:state output:o];frame.background=state.background;frame.chrome=self.chrome;frame.placeholderColor=self.chrome.backgroundColor;frame.outline=self.outline;frame.effects=self.effects;frame.errorMessages=[self backgroundErrors:state.background];}
        // The other outputs' viewports, projected as upstream's build_output_outline_elements does.
        NSMutableData *outlines=[NSMutableData data];
        for(NSDictionary *other in all){
            if(other==o||!number(other[@"id"])||[other[@"id"]isEqual:output])continue;
            CGPoint otherCamera=pointOf(other[@"camera"]);CGRect otherBounds=rectOf(other[@"screen_bounds"]);if(CGRectIsNull(otherBounds))continue;
            CGRect outline=IFCompositorOutlineRect(camera.x,camera.y,zoom,otherCamera.x,otherCamera.y,otherBounds.size,[number(other[@"zoom"])doubleValue]);[outlines appendBytes:&outline length:sizeof(outline)];
        }
        [frame setOutlineRects:outlines.bytes count:outlines.length/sizeof(CGRect)];
        // Placement order is the controller's bottom-to-top z order: this output's widgets, its canvas
        // windows, then the windows pinned to it. The compositor draws the three layers in that order too
        // and keeps this order within each.
        NSMutableDictionary<NSNumber *,IFCompositorElement *> *elements=[NSMutableDictionary dictionary];NSMutableDictionary<NSNumber *,NSDictionary *> *placements=[NSMutableDictionary dictionary];[frame.elements removeAllObjects];
        NSMutableArray<NSDictionary *> *orderedPlacements=[NSMutableArray array];NSMutableSet<NSNumber *> *seenPlacements=[NSMutableSet set];
        NSMutableDictionary<NSNumber *,NSNumber *> *unseen=[NSMutableDictionary dictionary],*owed=[NSMutableDictionary dictionary];
        for(NSDictionary *p in list(snapshot[@"placements"])){
            NSNumber *window=number(p[@"window"]);if(!window||![p[@"output"]isEqual:output]||[seenPlacements containsObject:window])continue;
            // A screen-pinned placement has no canvas position to draw from: its screen_rect is its pin's, in
            // global screen points at the window's own size whatever the camera and the zoom, and the pinned
            // space takes it in this output's own points. Its world rectangle is bookkeeping and is not read.
            BOOL pinned=[number(p[@"pinned"])boolValue];CGRect world;
            if(pinned){world=rectOf(p[@"screen_rect"]);if(CGRectIsNull(world))continue;world=CGRectOffset(world,-bounds.origin.x,-bounds.origin.y);}
            else {world=rectOf(p[@"world_rect"]);if(CGRectIsNull(world))world=rectOf(worlds[window]);if(CGRectIsNull(world))continue;}
            [seenPlacements addObject:window];[orderedPlacements addObject:p];
            // Preserve physical roots in the complete order as barriers even
            // though WindowServer, rather than this frame, draws their pixels.
            NSString *kind=text(p[@"kind"]);BOOL standin=kind?[kind isEqual:@"standin"]:!dict(p[@"source"]);
            if(self.nativeWindows&&!standin&&!(self.nativeReplica&&self.nativeReplica(window,output)))continue;
            IFCompositorElement *element=state.elements[window]?:[IFCompositorElement new];
            [self fill:element window:window placement:p snapshot:snapshot rect:world onScreen:pinned];
            if(element.kind==IFCompositorElementKindWindow){
                // Upstream DrawnChrome::drawn: the chrome a window wears depends on how its visual
                // frame covers the output. A stand-in is not subject to it. A pinned window's frame
                // is its screen site at zoom 1, as upstream's window_render_transform gives it.
                IFCompositorDecoration d=element.decoration;double bw=d.mode==IFCompositorDecorationModeNone?0:MAX(d.borderWidth,0),bar=d.mode==IFCompositorDecorationModeServer?self.chrome.titleBarHeight:0;
                double left=pinned?world.origin.x:world.origin.x-camera.x,top=pinned?world.origin.y:world.origin.y-camera.y,z=pinned?1:zoom;
                CGRect visual=CGRectMake((left-bw)*z,(top-bar-bw)*z,(world.size.width+2*bw)*z,(world.size.height+bar+2*bw)*z);
                element.decoration=IFCompositorDecorationDrawn(d,NO,IFCompositorCoverageOfFrame(visual,CGRectMake(0,0,bounds.size.width,bounds.size.height)));
                // Upstream's effective_blur, the controller's answer: a plain flag that the coverage rule does not touch. Never set for a capture.
                element.blur=[number(dict(p[@"decoration"])[@"blur"])boolValue];
                // Upstream's open animation, for a window an `open` event names that this output has not shown opening. It runs from the
                // window's first picture: here when it has one, or has waited a second for it, else in -contentChanged:. While its size is
                // owed (`owed`, above) the wait is renewed instead, so that second starts when the size transaction has ended.
                // Not for a window that is fullscreen here (a rule's `fullscreen` as it mapped): the size it is owed is its output's, the
                // controller has marked the output at once and nothing else is drawn on it, so a held window would leave it black for as
                // long as the application takes. It is drawn from its first picture at the size it has (FULLSCREEN.md, No transition).
                NSNumber *since=state.unseen[window];
                if([opened[window]unsignedLongLongValue]>state.serial&&self.effects.animationSpeed<1){since=@(now);element.lifecycle=IFCompositorLifecycleOpening;element.lifecycleStartTime=NAN;element.lifecycleProgress=0;}
                NSNumber *held=since&&[self.sizing isEqual:window]&&![number(p[@"fullscreen"])boolValue]?(state.owed[window]?:@(now)):nil;
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
        // fullscreen app": COMPOSITOR-NOTES.md 18.2, When not to). They are left out of that output's frame and run out unseen on the
        // clock they began on, as upstream's lists do: -flush drops each when it is over, and what is left is back with the canvas.
        if(!dict(o[@"fullscreen"]))[frame.elements addObjectsFromArray:state.leaving];
        state.elements=elements;state.placements=placements;state.unseen=unseen;state.owed=owed;state.serial=self.played;state.dirty=YES;
        state.orderPlacements=orderedPlacements.copy;state.orderOutput=o;state.orderSnapshot=snapshot;state.orderMatchedSnapshot=nil;state.orderBinding=orderBinding(snapshot,output);state.orderDirty=YES;
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
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/fullscreen.rs (enter_fullscreen: the window fills its output at zoom 1 from
// the output's own corner; recentre_fullscreen_window: one that took another size sits
// in the middle of it), src/render/chrome.rs (DrawnChrome::drawn: a fullscreen window
// sheds bar, border, corners and shadow) and src/tests/translucent_fullscreen.rs
// (fullscreen_conceals_canvas: an opaque fullscreen window conceals the background and
// the outlines of the other outputs, also where a smaller one leaves a band, which stays
// the clear colour; one drawn see-through leaves both drawn under it). Which window is
// fullscreen where, what else its output still shows and where the window sits are the
// controller's: outputs[].fullscreen, the placements it lists for that output and the
// screen_rect of the one it marks fullscreen. No native window geometry is read.
//
// One output's fullscreen, applied to the frame -render: has just described. The marked
// placement is drawn at its screen_rect, global screen points at zoom 1 whatever the
// output's camera and zoom, and bare. That is the compositor's pinned space: output-local
// points at zoom 1, which its output space only approximates by dividing by the frame's
// zoom (COMPOSITOR-NOTES.md, deviation 10); at zoom 1 the two are the same arithmetic.
// The window keeps its place in the list and its layer. Run for every output on every
// describe, so the background and the outlines are back with the first frame after the exit.
//
// A fullscreen output shows a screen-space window, not a canvas viewport, so it projects no
// outline onto the others (upstream build_output_outline_elements passes over one that is
// visually fullscreen, opaque or see-through): an output with such a neighbour has its
// outlines described again here, from the snapshot's outputs, without that neighbour's.
- (void)fullscreen:(NSDictionary *)o among:(NSArray<NSDictionary *> *)all state:(DWCanvasOutput *)state {
    IFCompositorFrame *frame=state.frame;NSDictionary *full=dict(o[@"fullscreen"]);CGPoint corner=rectOf(o[@"screen_bounds"]).origin;
    // "black": nothing but the clear colour lies behind the window. "canvas": its opacity is below 1 and the canvas shows through it.
    BOOL concealed=full&&![text(full[@"backdrop"])isEqual:@"canvas"],parked=NO;
    for(NSDictionary *other in all)if(other!=o&&dict(other[@"fullscreen"]))parked=YES;
    // Upstream shrinks a concealed output's chunk cache on every such frame: it frees its chunks, keeps its floor and has nothing pending.
    frame.background=concealed?nil:state.background;if(concealed){[state.background shrinkChunkCache];[frame setOutlineRects:NULL count:0];}
    else if(parked){
        NSMutableData *outlines=[NSMutableData data];
        for(NSDictionary *other in all){
            if(other==o||!number(other[@"id"])||[other[@"id"]isEqual:o[@"id"]]||dict(other[@"fullscreen"]))continue;
            CGPoint otherCamera=pointOf(other[@"camera"]);CGRect otherBounds=rectOf(other[@"screen_bounds"]);if(CGRectIsNull(otherBounds))continue;
            CGRect outline=IFCompositorOutlineRect(frame.cameraX,frame.cameraY,frame.zoom,otherCamera.x,otherCamera.y,otherBounds.size,[number(other[@"zoom"])doubleValue]);[outlines appendBytes:&outline length:sizeof(outline)];
        }
        [frame setOutlineRects:outlines.bytes count:outlines.length/sizeof(CGRect)];
    }
    for(NSNumber *window in state.placements){
        NSDictionary *p=state.placements[window];IFCompositorElement *element=state.elements[window];CGRect screen=rectOf(p[@"screen_rect"]);
        // The controller refuses a stand-in fullscreen; one marked so all the same is drawn as the stand-in it is.
        if(![number(p[@"fullscreen"])boolValue]||element.kind!=IFCompositorElementKindWindow||CGRectIsNull(screen))continue;
        element.rect=CGRectOffset(screen,-corner.x,-corner.y);element.space=IFCompositorSpacePinned;
        element.decoration=IFCompositorDecorationDrawn(element.decoration,YES,IFCompositorCoverageNone);
    }
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
        if(!state.unseen[window]||!pictured(element)||([self.sizing isEqual:window]&&![number(state.placements[window][@"fullscreen"])boolValue]))continue;
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
        any=YES;if(draw){BOOL had=state.drawn;state.drawn=NO;state.dirty=YES;if(filling&&!had){state.forced=YES;[state.layer setNeedsRedraw];}[self setNeedsFlush];}
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
- (void)flushFrame {[self flushFrameAtTime:0 refreshRate:0];}
- (void)flushFrameAtTime:(CFTimeInterval)time refreshRate:(NSInteger)rate {
    self.frameTarget=time;self.paced=YES;for(DWCanvasOutput *state in self.states.allValues){state.layer.presentationTime=time;state.layer.presentationInterval=rate>0?1.0/rate:0;}[self flush];self.paced=NO;
}
- (void)flush {
    BOOL placed=self.placed;self.pending=NO;self.placed=NO;double now=canvasTime();CFTimeInterval began=self.measured?CACurrentMediaTime():0;BOOL any=NO;
    for(DWCanvasOutput *state in self.states.allValues){
        if(!state.dirty)continue;
        if(self.paced&&!placed&&state.layer.drawablePending){state.awaitingDrawable=YES;continue;}
        state.awaitingDrawable=NO;state.dirty=NO;any=YES;IFCompositorFrame *frame=state.frame;frame.time=now;[self advanceGeometry:state now:now];
        for(NSNumber *window in state.attachments)[self geometryForFamily:state.attachments[window] root:state.elements[window] frame:frame];
        if(state.geometryNeedsSettledDraw)[state.layer setNeedsRedraw];
        BOOL forced=state.forced;state.forced=NO;state.layer.paced=self.paced;@autoreleasepool{if([state.layer updateWithFrame:frame]){state.geometryNeedsSettledDraw=NO;state.presented=now;_counts.drawn++;if(!forced)state.drawn=YES;
            for(NSNumber *window in state.geometry){DWCanvasGeometry *geometry=state.geometry[window];IFCompositorElement *element=state.elements[window];geometry.screen=geometryScreen(element.rect,element.space,frame);geometry.drawn=YES;}}}
        // A frame that had no drawable is still owed: the output stays marked, and what was owed inside the layer's transaction stays so.
        if(state.layer.missed){state.dirty=YES;if(forced)state.forced=YES;if(placed)self.placed=YES;}
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
// What a capture frames for one element, bounds rounded outward. A live window:
// upstream's window_visual_rect, its content with a server title bar above and the
// border and the shadow radius all round. A stand-in: its visual frame, bar and body
// with the border, as snap_rect_to_rect rounds it.
- (CGRect)visual:(IFCompositorElement *)element {
    IFCompositorDecoration d=element.decoration;CGRect r=element.rect;BOOL bare=d.mode==IFCompositorDecorationModeNone,standin=element.kind==IFCompositorElementKindStandIn;
    double edge=bare?0:MAX(d.borderWidth,0),bar=standin||d.mode==IFCompositorDecorationModeServer?self.chrome.titleBarHeight:0;
    if(!standin&&!bare&&d.shadow)edge+=ceil(d.shadowRadius);
    double x=floor(r.origin.x-edge),y=floor(r.origin.y-bar-edge);
    return CGRectMake(x,y,MAX(ceil(CGRectGetMaxX(r)+edge)-x,1),MAX(ceil(CGRectGetMaxY(r)+edge)-y,1));
}
// Upstream resolve_screenshot_region, for an effect that names its target only. The
// controller's own `region`, when the effect carries one, is used instead: it knows
// zoom.fit_padding and the decoration of windows that are on no output.
- (CGRect)region:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot elements:(NSArray<IFCompositorElement *> *)elements isolate:(IFCompositorElement *)isolate refusal:(NSString *__autoreleasing *)refused {
    NSArray<NSDictionary *> *outputs=list(snapshot[@"outputs"]);NSDictionary *active=nil;id target=effect[@"target"];NSDictionary *r=dict(dict(target)[@"Region"]);
    for(NSDictionary *o in outputs)if(number(effect[@"output"])&&[o[@"id"]isEqual:effect[@"output"]])active=o;
    if(isolate)return [self visual:isolate];
    if([target isEqual:@"Viewport"]){
        if(!active){*refused=@"no active output to capture";return CGRectNull;}
        return viewportOf(active);
    }
    if([target isEqual:@"All"]){
        // The union of every canvas window and stand-in, framed by zoom.fit_padding canvas units (upstream's default
        // without one). `elements` holds no pinned window; a widget is drawn and not framed, as upstream's is_canvas_window says.
        CGRect all=CGRectNull;for(IFCompositorElement *element in elements)if(element.layer!=IFCompositorStackLayerWidget)all=CGRectUnion(all,[self visual:element]);
        if(CGRectIsNull(all)){*refused=@"no windows to capture";return CGRectNull;}
        double pad=round(fmax(number(effect[@"fit_padding"])?[effect[@"fit_padding"]doubleValue]:80,0));return CGRectInset(all,-pad,-pad);
    }
    if(!r){*refused=@"unknown screenshot target";return CGRectNull;}
    long x=[number(r[@"x"])longValue],y=[number(r[@"y"])longValue],w=[number(r[@"w"])longValue],h=[number(r[@"h"])longValue];
    if(w<=0||h<=0){*refused=@"region width and height must be positive";return CGRectNull;}
    // rule_to_internal: the rectangle is centred on a Y-up canvas point.
    if(![number(r[@"from_screen"])boolValue])return CGRectMake(x-w/2,-y-h/2,w,h);
    // Screen points, mapped through the output they lie on, else the active one.
    NSDictionary *output=nil;for(NSDictionary *o in outputs)if(!output&&CGRectContainsPoint(rectOf(o[@"screen_bounds"]),CGPointMake(x,y)))output=o;
    if(!output)output=active;if(!output){*refused=@"no output for the screen region";return CGRectNull;}
    CGPoint camera=pointOf(output[@"camera"]),corner=rectOf(output[@"screen_bounds"]).origin;double zoom=[number(output[@"zoom"])doubleValue];if(!(isfinite(zoom)&&zoom>0))zoom=1;
    return CGRectMake(round(camera.x+(x-corner.x)/zoom),round(camera.y+(y-corner.y)/zoom),round(w/zoom),round(h/zoom));
}
- (NSDictionary *)screenshotPixels:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
    NSString *path=text(effect[@"path"]),*refused=nil;double scale=number(effect[@"scale"])?[effect[@"scale"]doubleValue]:NAN;
    if(!path.isAbsolutePath)return refusal(@"screenshot path must be absolute");
    if(!snapshot)return refusal(@"no renderer available for capture");
    [self configure:snapshot];
    // A window target is composed alone on transparency, its shadow included. The controller resolved the selector.
    id target=effect[@"target"];IFCompositorElement *isolate=nil;NSDictionary *alone=dict(dict(target)[@"Window"]);
    NSNumber *wanted=alone?number(alone[@"window"])?:number(snapshot[@"focused"]):nil;
    // Every world window bottom to top at its canvas rectangle, described by its placement on any
    // output; one that is on no output is described by its entry of the window list. Upstream
    // compose_capture_elements: a canvas capture never includes a screen-pinned window
    // (window_render_transform gives it no place without an output), and draws the widgets below the
    // other windows; only a window captured alone is drawn whatever it is, at its stage position,
    // which for a pinned window is the canvas frame its pin shows.
    NSMutableDictionary<NSNumber *,NSDictionary *> *placed=[NSMutableDictionary dictionary];
    for(NSDictionary *p in list(snapshot[@"placements"]))if(number(p[@"window"])&&(!placed[p[@"window"]]||[p[@"output"]isEqual:effect[@"output"]]))placed[p[@"window"]]=p;
    NSMutableArray<IFCompositorElement *> *elements=[NSMutableArray array];
    NSMutableDictionary<NSNumber *,NSArray<IFCompositorElement *> *> *attachments=[NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *exportTokens=self.exportOrder?[NSMutableArray array]:nil;
    NSMutableDictionary<NSDictionary *,IFCompositorElement *> *exportElements=self.exportOrder?[NSMutableDictionary dictionary]:nil;
    for(NSDictionary *w in list(snapshot[@"windows"])){
        NSNumber *window=number(w[@"window"]);CGRect world=rectOf(w[@"world_rect"]);NSDictionary *p=placed[window],*source=dict(w[@"source"]),*metadata=dict(w[@"metadata"]);
        // Upstream's windows are at least one pixel in each direction.
        if(!window||CGRectIsNull(world)||world.size.width<=0||world.size.height<=0)continue;
        // An isolated export has exactly this family's token set. Other roots
        // neither constrain its order nor borrow pixels into this composition.
        if(alone&&![window isEqual:wanted])continue;
        if(pinnedOf(w)&&![window isEqual:wanted])continue;
        if(!p){NSMutableDictionary *described=[w mutableCopy];BOOL settled=source&&[number(source[@"observation_known"])boolValue];
            described[@"presentation_settled"]=settled?@YES:@NO;if(!described[@"title"])described[@"title"]=text(metadata[@"title"])?:@"";if(!described[@"app_name"])described[@"app_name"]=text(metadata[@"bundle_id"])?:@"";p=described;}
        // Native presentation omits live pictures from the on-screen canvas, but
        // an export supplies separate one-shot pixels through the source provider.
        IFCompositorElement *element=[IFCompositorElement new];[self fill:element window:window placement:p snapshot:snapshot rect:world onScreen:NO];[elements addObject:element];
        if(exportTokens){BOOL barrier=element.kind==IFCompositorElementKindStandIn||!self.exportOrderRoot||!self.exportOrderRoot(window);
            NSDictionary *token=barrier?@{@"window":window,@"bucket":@(element.layer),@"barrier":@YES}:@{@"window":window,@"bucket":@(element.layer)};
            [exportTokens addObject:token];exportElements[token]=element;}
        // A one-shot family is authoritative when provided. Otherwise a live
        // family's matching output may supply pixels when no one-shot ordering
        // contract is installed. Never borrow live observations into an ordered
        // one-shot export, or another output's geometry/capture generation.
        NSArray<DWCanvasAttachment *> *familyImages=element.kind==IFCompositorElementKindWindow?(self.exportAttachments?self.exportAttachments(window):!self.exportOrder&&self.liveAttachments&&number(p[@"output"])?self.liveAttachments(window,p[@"output"]):nil):nil;
        if(familyImages.count){NSMutableArray *family=[NSMutableArray array];NSMutableSet<NSString *> *keys=exportTokens?[NSMutableSet set]:nil;
            for(DWCanvasAttachment *image in familyImages){
                if(!validAttachment(image))return refusal(@"capture attachment has no valid image geometry or source-pixel crop");
                if(exportTokens){if(!image.key.length||[keys containsObject:image.key])return refusal(@"capture attachment has no unique opaque ordering key");[keys addObject:image.key];}
                CGRect r=image.unitRect;
                IFCompositorElement *child=[IFCompositorElement new];child.identifier=[self mark];child.kind=IFCompositorElementKindWindow;child.space=IFCompositorSpaceCanvas;child.layer=element.layer;
                child.rect=CGRectMake(world.origin.x+r.origin.x*world.size.width,world.origin.y+r.origin.y*world.size.height,r.size.width*world.size.width,r.size.height*world.size.height);
                IFCompositorDecoration d=IFCompositorDecorationDefault();d.mode=IFCompositorDecorationModeNone;d.borderWidth=0;d.cornerRadius=0;d.shadow=NO;d.opacity=element.decoration.opacity;child.decoration=d;
                child.pixelBuffer=image.buffer;child.contentRect=image.contentRect;child.contentGeneration=image.generation;[family addObject:child];[elements addObject:child];
                if(exportTokens){NSDictionary *token=@{@"window":window,@"key":image.key,@"bucket":@(child.layer)};[exportTokens addObject:token];exportElements[token]=child;}
            }
            if(family.count)attachments[window]=family.copy;
        }
    }
    if(exportTokens){
        // Capture composition has no pinned or closing bucket. Use the same
        // order the compositor actually draws, before region culling can hide
        // a root needed to validate its complete captured family membership.
        NSMutableArray<NSDictionary *> *base=[NSMutableArray array];
        for(NSNumber *bucket in @[@(IFCompositorStackLayerWidget),@(IFCompositorStackLayerNormal)])for(NSDictionary *token in exportTokens)if([token[@"bucket"]isEqual:bucket])[base addObject:token];
        NSArray *order=validatedOrder(self.exportOrder(base.copy,effect,snapshot),base.copy);
        NSMutableArray<IFCompositorElement *> *ordered=[NSMutableArray arrayWithCapacity:elements.count];for(NSDictionary *token in order)if(exportElements[token])[ordered addObject:exportElements[token]];
        if(ordered.count!=elements.count)return refusal(@"capture ordering does not describe every exported image");
        elements=ordered;
    }
    if(alone){
        NSNumber *window=wanted;
        for(IFCompositorElement *element in elements)if(window&&element.identifier==window.unsignedLongLongValue)isolate=element;
        if(!isolate)return refusal(window?@"window has no capturable area":@"no window matching selector");
        // Upstream compose_capture_elements: a window captured alone is drawn as itself, at its rule's
        // opacity or 1, not at the opacity its focus gives it on screen. The controller resolved which.
        NSNumber *opacity=number(dict(dict(target)[@"Window"])[@"opacity"]);if(opacity){IFCompositorDecoration d=isolate.decoration;d.opacity=opacity.doubleValue;isolate.decoration=d;
            for(IFCompositorElement *child in attachments[window]){IFCompositorDecoration d=child.decoration;d.opacity=opacity.doubleValue;child.decoration=d;}}
    }
    CGRect region=rectOf(effect[@"region"]);if(CGRectIsNull(region))region=[self region:effect snapshot:snapshot elements:elements isolate:isolate refusal:&refused];
    if(refused)return refusal(refused);
    // A Window effect's controller-supplied region describes the root's chrome;
    // attached popups and sheets can lie outside it. Include the complete family
    // for that target. Viewport and Region targets keep their requested clipping.
    if(isolate)for(IFCompositorElement *child in attachments[wanted])region=CGRectUnion(region,[self visual:child]);
    IFCompositorRenderer *renderer=[IFCompositorRenderer rendererWithDevice:nil];if(!renderer)return refusal(@"no renderer available for capture");
    // capture_region_to_png: `scale` pixels per canvas unit, whatever any output's zoom is.
    if(!(isfinite(scale)&&scale>0))return refusal(@"scale must be a positive number");
    if(!(region.size.width>0&&region.size.height>0))return refusal(@"capture region is empty");
    double width=fmin(round(region.size.width*scale),INT32_MAX),height=fmin(round(region.size.height*scale),INT32_MAX);
    if(width<=0||height<=0)return refusal(@"capture resolves to zero pixels");
    if(width>16384||height>16384)return refusal([NSString stringWithFormat:@"capture %.0fx%.0fpx exceeds the 16384px per-side limit — lower --scale or shrink the region",width,height]);
    // Upstream capture_background.rs (wallpaper_dest and the Wallpaper arm of tile_elements): a wallpaper is
    // fixed to the screen, so a capture shows it over the canvas footprint of the output the region's centre
    // lies on, else of the active output. The region crops it and the rest stays transparent; with no such
    // output there is no background.
    CGPoint backgroundCentre=CGPointMake(region.origin.x+trunc(region.size.width/2),region.origin.y+trunc(region.size.height/2));NSDictionary *backgroundOutput=nil,*activeBackgroundOutput=nil;
    for(NSDictionary *output in list(snapshot[@"outputs"])){if(!backgroundOutput&&CGRectContainsPoint(viewportOf(output),backgroundCentre))backgroundOutput=output;if([output[@"id"]isEqual:effect[@"output"]])activeBackgroundOutput=output;}
    backgroundOutput=backgroundOutput?:activeBackgroundOutput;
    IFBackgroundProgram *backgroundProgram=!isolate&&self.backgroundForOutput&&backgroundOutput?self.backgroundForOutput(number(backgroundOutput[@"id"]),backgroundOutput,self.program):nil;backgroundProgram=backgroundProgram?:self.program;
    BOOL wallpaper=!isolate&&backgroundProgram.kind==IFBackgroundKindWallpaper;CGRect dest=CGRectNull;
    if(wallpaper){
        dest=viewportOf(backgroundOutput);
        // The upstream fixed cover-fit image can use the bare viewport's one
        // pass. Mac sizing/parallax still needs its real output sampling pose.
        if(CGRectEqualToRect(dest,region)&&!backgroundProgram.config.parallax&&!backgroundProgram.config.inheritedWallpaper)wallpaper=NO;
    }
    // Upstream's capture: zoom 1, a transparent target, no outlines, and the background
    // under every scene but not under a window captured alone. A capture draws no chunk
    // cache: a baked shader is rendered live and a pyramidal TIFF from one level of at
    // most 4096 pixels, whatever the outputs have loaded (the module's captureProgram).
    IFCompositorFrame *frame=[IFCompositorFrame new];
    frame.size=region.size;frame.scale=scale;frame.cameraX=region.origin.x;frame.cameraY=region.origin.y;frame.zoom=1;frame.time=canvasTime();frame.clear=IFCompositorClearTransparent;
    frame.chrome=self.chrome;frame.placeholderColor=self.chrome.backgroundColor;frame.background=isolate||wallpaper?nil:backgroundProgram.captureProgram;
    for(IFCompositorElement *element in elements){
        // Nothing of an element farther away than its bar, border and shadow reaches the region.
        double reach=ceil(element.decoration.shadowRadius)+1;
        if(isolate?element==isolate||[attachments[wanted]containsObject:element]:CGRectIntersectsRect(CGRectInset([self visual:element],-reach,-reach),region))[frame.elements addObject:element];
    }
    NSError *error=nil;CGImageRef image=[renderer newImageForFrame:frame error:&error];if(!image)return refusal(error.localizedDescription?:@"the render did not complete");
    if(wallpaper&&!CGRectIsEmpty(CGRectIntersection(dest,region))){
        // The picture that output shows, drawn by the same module at the capture's density (one texture at
        // most), laid under the scene at whole pixels. Core Graphics counts rows from the bottom.
        IFCompositorFrame *under=[IFCompositorFrame new];size_t wide=CGImageGetWidth(image),high=CGImageGetHeight(image);
        CGRect paperBounds=rectOf(backgroundOutput[@"screen_bounds"]);CGPoint paperCamera=pointOf(backgroundOutput[@"camera"]);double paperZoom=[number(backgroundOutput[@"zoom"])doubleValue];
        under.size=paperBounds.size;under.scale=fmin(scale/paperZoom,16384/fmax(paperBounds.size.width,paperBounds.size.height));under.cameraX=paperCamera.x;under.cameraY=paperCamera.y;under.zoom=paperZoom;under.time=frame.time;under.clear=IFCompositorClearTransparent;under.background=backgroundProgram;
        CGImageRef paper=[renderer newImageForFrame:under error:&error];CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=paper?CGBitmapContextCreate(NULL,wide,high,8,0,srgb,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little):NULL;CGColorSpaceRelease(srgb);
        if(!context){CGImageRelease(paper);CGImageRelease(image);return refusal(error.localizedDescription?:@"the render did not complete");}
        double x0=round((CGRectGetMinX(dest)-region.origin.x)*scale),x1=round((CGRectGetMaxX(dest)-region.origin.x)*scale),y0=round((CGRectGetMinY(dest)-region.origin.y)*scale),y1=round((CGRectGetMaxY(dest)-region.origin.y)*scale);
        CGContextDrawImage(context,CGRectMake(x0,high-y1,x1-x0,y1-y0),paper);CGContextDrawImage(context,CGRectMake(0,0,wide,high),image);
        CGImageRelease(paper);CGImageRelease(image);image=CGBitmapContextCreateImage(context);CGContextRelease(context);
        if(!image)return refusal(@"the render did not complete");
    }
    long pixelsWide=(long)CGImageGetWidth(image),pixelsHigh=(long)CGImageGetHeight(image);
    return @{@"image":CFBridgingRelease(image),@"path":path,@"width":@(pixelsWide),@"height":@(pixelsHigh)};
}
- (NSDictionary *)screenshot:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
    return writeScreenshotPixels([self screenshotPixels:effect snapshot:snapshot]);
}
- (void)screenshot:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot completed:(void (^)(NSDictionary *))completed {
    NSDictionary *pixels=[self screenshotPixels:effect snapshot:snapshot];
    if(pixels[@"error"]){completed(pixels);return;}
    if(!_exportWorker)_exportWorker=dispatch_queue_create("org.infinify.screenshot-writer",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    dispatch_async(_exportWorker,^{@autoreleasepool{
        NSDictionary *result=writeScreenshotPixels(pixels);
        dispatch_async(dispatch_get_main_queue(),^{completed(result);});
    }});
}
@end
