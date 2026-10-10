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
// at). New code over the controller's snapshot; cameras, world rectangles and pinned
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
static CGPoint pointOf(id value) { NSDictionary *p=dict(value);return CGPointMake([number(p[@"x"])doubleValue],[number(p[@"y"])doubleValue]); }
// The controller's {origin:{x,y},size:{width,height}}; CGRectNull for anything else.
static CGRect rectOf(id value) {
    NSDictionary *r=dict(value),*origin=dict(r[@"origin"]),*size=dict(r[@"size"]);if(!origin||!size)return CGRectNull;
    return CGRectMake([number(origin[@"x"])doubleValue],[number(origin[@"y"])doubleValue],[number(size[@"width"])doubleValue],[number(size[@"height"])doubleValue]);
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

// One output on screen: its layer, the frame description refilled in place, and the
// elements and placements of the windows it shows.
@interface DWCanvasOutput : NSObject
@property IFCompositorLayer *layer;
@property IFCompositorFrame *frame;
@property NSMutableDictionary<NSNumber *,IFCompositorElement *> *elements;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *placements;
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
@end
@implementation DWCanvasOutput
@end
@interface DWCanvasRenderer ()
@property (copy) DWCanvasSource source;
@property NSMutableDictionary<NSNumber *,DWCanvasOutput *> *states;
@property IFBackgroundProgram *program;
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
@end
@implementation DWCanvasRenderer
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
    // Upstream BackgroundConfig, field for field; the module expands ~ and falls back by itself.
    IFBackgroundConfig *config=[IFBackgroundConfig configWithTypeString:text(b[@"type"]) path:text(b[@"path"]) texture:text(b[@"texture"]) warning:&warning];
    config.mirrorTile=[number(b[@"mirror_tile"])boolValue];config.transparentShader=[number(b[@"transparent_shader"])boolValue];config.cacheShader=[number(b[@"cache_shader"])boolValue];
    config.animateFPS=(NSUInteger)lround(fmin(fmax([number(b[@"animate_fps"])doubleValue],0),1000));
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
// A window closed (upstream snapshot_closing_window): on each output that drew it, the element of the frame last described is
// baked with all its chrome into one texture, and that snapshot shrinks and fades in the closing bucket, or with inPlace fades
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
        @autoreleasepool{snapshot=[state.layer.renderer closingSnapshotOfElement:element inFrame:state.frame flattenScale:element.space==IFCompositorSpacePinned?state.frame.scale:density];}
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
- (void)render:(NSDictionary *)snapshot outputs:(NSArray<NSNumber *> *)outputs host:(CALayer *)host origin:(CGPoint)origin scale:(CGFloat)scale decorationScale:(NSInteger)decorationScale {
    if(!snapshot||!host)return;[self configure:snapshot];double now=canvasTime();[self play:snapshot now:now];
    // The windows an `open` event of this snapshot names, and the serial of each: an output that has not been described with it yet opens the window.
    NSMutableDictionary<NSNumber *,NSNumber *> *opened=[NSMutableDictionary dictionary];
    for(id entry in list(snapshot[@"lifecycle_events"])){NSDictionary *event=dict(entry);if(number(event[@"window"])&&number(event[@"serial"])&&[event[@"event"]isEqual:@"open"])opened[event[@"window"]]=event[@"serial"];}
    // The window the controller owes a size: its one size transaction, while an effect of it is outstanding. Null in a run that cannot deliver a size.
    NSDictionary *resize=dict(snapshot[@"native_resize"]);self.sizing=dict(resize[@"pending_effect"])?number(resize[@"window"]):nil;
    NSArray<NSDictionary *> *all=list(snapshot[@"outputs"]);NSMutableDictionary<NSNumber *,id> *worlds=[NSMutableDictionary dictionary];
    for(NSDictionary *w in list(snapshot[@"windows"]))if(number(w[@"window"])&&w[@"world_rect"])worlds[w[@"window"]]=w[@"world_rect"];
    for(NSDictionary *o in all){
        NSNumber *output=number(o[@"id"]);CGRect bounds=rectOf(o[@"screen_bounds"]);if(!output||![outputs containsObject:output]||CGRectIsNull(bounds))continue;
        DWCanvasOutput *state=self.states[output];
        // An output that is new shows no event that came before it: nothing was on it to open.
        if(!state){state=self.states[output]=[DWCanvasOutput new];state.layer=[[IFCompositorLayer alloc]initWithRenderer:nil];state.frame=[IFCompositorFrame new];state.elements=[NSMutableDictionary dictionary];state.placements=[NSMutableDictionary dictionary];state.leaving=[NSMutableArray array];state.unseen=[NSMutableDictionary dictionary];state.adopted=[NSMutableDictionary dictionary];state.owed=[NSMutableDictionary dictionary];state.serial=self.played;}
        // Below the toolbar and the status line, as the window tiles were.
        if(state.layer.superlayer!=host)[host insertSublayer:state.layer atIndex:0];
        CGRect place=CGRectOffset(bounds,-origin.x,-origin.y);if(!CGRectEqualToRect(state.layer.frame,place))state.layer.frame=place;
        IFCompositorFrame *frame=state.frame;CGPoint camera=pointOf(o[@"camera"]);double zoom=[number(o[@"zoom"])doubleValue];
        frame.size=bounds.size;frame.scale=scale>0?scale:1;frame.cameraX=camera.x;frame.cameraY=camera.y;frame.zoom=zoom;frame.clear=IFCompositorClearOpaqueBlack;frame.decorationScale=decorationScale;
        if(state.style!=self.style){state.style=self.style;frame.background=self.program;frame.chrome=self.chrome;frame.placeholderColor=self.chrome.backgroundColor;frame.outline=self.outline;frame.effects=self.effects;frame.errorMessages=self.errors;}
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
        NSMutableDictionary<NSNumber *,NSNumber *> *unseen=[NSMutableDictionary dictionary],*owed=[NSMutableDictionary dictionary];
        for(NSDictionary *p in list(snapshot[@"placements"])){
            NSNumber *window=number(p[@"window"]);if(!window||![p[@"output"]isEqual:output]||elements[window])continue;
            // A screen-pinned placement has no canvas position to draw from: its screen_rect is its pin's, in
            // global screen points at the window's own size whatever the camera and the zoom, and the pinned
            // space takes it in this output's own points. Its world rectangle is bookkeeping and is not read.
            BOOL pinned=[number(p[@"pinned"])boolValue];CGRect world;
            if(pinned){world=rectOf(p[@"screen_rect"]);if(CGRectIsNull(world))continue;world=CGRectOffset(world,-bounds.origin.x,-bounds.origin.y);}
            else {world=rectOf(p[@"world_rect"]);if(CGRectIsNull(world))world=rectOf(worlds[window]);if(CGRectIsNull(world))continue;}
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
                NSNumber *since=state.unseen[window];
                if([opened[window]unsignedLongLongValue]>state.serial&&self.effects.animationSpeed<1){since=@(now);element.lifecycle=IFCompositorLifecycleOpening;element.lifecycleStartTime=NAN;element.lifecycleProgress=0;}
                NSNumber *held=since&&[self.sizing isEqual:window]?(state.owed[window]?:@(now)):nil;
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
        [frame.elements addObjectsFromArray:state.leaving];
        state.elements=elements;state.placements=placements;state.unseen=unseen;state.owed=owed;state.serial=self.played;state.dirty=YES;
    }
    [self setNeedsFlush];
}
- (CALayer *)layerForOutput:(NSNumber *)output { return self.states[output].layer; }
- (BOOL)contentChanged:(NSNumber *)window {
    BOOL opening=NO;
    for(DWCanvasOutput *state in self.states.allValues){
        IFCompositorElement *element=state.elements[window];if(!element||element.kind!=IFCompositorElementKindWindow)continue;
        [self content:element window:window placement:state.placements[window]];state.dirty=YES;[self setNeedsFlush];
        // The first picture of a window that was waited for: its opening, and the fade of the stand-in whose slot it adopted, begin.
        // Not while the window's size is owed: that picture is of the size it is leaving, and -render: starts both when the size has settled.
        if(!state.unseen[window]||!pictured(element)||[self.sizing isEqual:window])continue;
        [state.unseen removeObjectForKey:window];IFCompositorElement *fade=state.adopted[window];double start=began(state,canvasTime());
        if(element.lifecycle==IFCompositorLifecycleOpening&&isnan(element.lifecycleStartTime)){element.lifecycleStartTime=start;opening=YES;}
        if(fade){fade.lifecycleStartTime=start;[state.adopted removeObjectForKey:window];opening=YES;}
    }
    return opening;
}
- (BOOL)animates:(NSArray<NSNumber *> *)outputs draw:(BOOL)draw {
    BOOL any=NO;
    for(NSNumber *output in outputs){DWCanvasOutput *state=self.states[output];if(!state.layer.renderer||!state.frame.needsContinuousRedraw)continue;any=YES;if(draw){state.dirty=YES;[self setNeedsFlush];}}
    return any;
}
// A burst of stream frames and animation ticks in one turn of the run loop describes
// each output to its layer once, unless the shell flushed in between; the layer itself
// draws only when the description, a pixel buffer, the animated background's clock or
// the progress of an open or close animation changed.
- (void)setNeedsFlush {
    if(self.pending)return;self.pending=YES;__weak DWCanvasRenderer *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{[weak flush];});
}
// Metal hands out autoreleased drawables and encoder contexts; a caller outside a run-loop
// callout (the launch's first frame, the quit-pending loop) has no pool of its own to end them.
- (void)flush {
    self.pending=NO;double now=canvasTime();
    for(DWCanvasOutput *state in self.states.allValues){
        if(!state.dirty)continue;state.dirty=NO;IFCompositorFrame *frame=state.frame;frame.time=now;@autoreleasepool{if([state.layer updateWithFrame:frame])state.presented=now;}
        // An animation that has run out at this frame's time, which the frame no longer showed: upstream drops the snapshot or the fade, and a window that has opened is the plain window.
        for(IFCompositorElement *element in state.leaving.count?state.leaving.copy:nil)if([frame lifecycleFinishedForElement:element]){[state.leaving removeObject:element];[frame.elements removeObject:element];}
        for(IFCompositorElement *element in frame.elements)if(element.lifecycle==IFCompositorLifecycleOpening&&[frame lifecycleFinishedForElement:element]){element.lifecycle=IFCompositorLifecycleNone;element.lifecycleStartTime=NAN;}
    }
}
- (void)reset {
    for(DWCanvasOutput *state in self.states.allValues){[state.layer removeFromSuperlayer];[state.frame.elements removeAllObjects];[state.leaving removeAllObjects];}
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
- (NSDictionary *)screenshot:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot {
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
    for(NSDictionary *p in list(snapshot[@"placements"]))if(number(p[@"window"])&&!placed[p[@"window"]])placed[p[@"window"]]=p;
    NSMutableArray<IFCompositorElement *> *elements=[NSMutableArray array];
    for(NSDictionary *w in list(snapshot[@"windows"])){
        NSNumber *window=number(w[@"window"]);CGRect world=rectOf(w[@"world_rect"]);NSDictionary *p=placed[window],*source=dict(w[@"source"]),*metadata=dict(w[@"metadata"]);
        // Upstream's windows are at least one pixel in each direction.
        if(!window||CGRectIsNull(world)||world.size.width<=0||world.size.height<=0)continue;
        if(pinnedOf(w)&&![window isEqual:wanted])continue;
        if(!p){NSMutableDictionary *described=[w mutableCopy];BOOL settled=source&&[number(source[@"observation_known"])boolValue]&&[source[@"capture_revision"]isEqual:source[@"observation_revision"]];
            described[@"presentation_settled"]=settled?@YES:@NO;if(!described[@"title"])described[@"title"]=text(metadata[@"title"])?:@"";if(!described[@"app_name"])described[@"app_name"]=text(metadata[@"bundle_id"])?:@"";p=described;}
        IFCompositorElement *element=[IFCompositorElement new];[self fill:element window:window placement:p snapshot:snapshot rect:world onScreen:NO];[elements addObject:element];
    }
    if(alone){
        NSNumber *window=wanted;
        for(IFCompositorElement *element in elements)if(window&&element.identifier==window.unsignedLongLongValue)isolate=element;
        if(!isolate)return refusal(window?@"window has no capturable area":@"no window matching selector");
        // Upstream compose_capture_elements: a window captured alone is drawn as itself, at its rule's
        // opacity or 1, not at the opacity its focus gives it on screen. The controller resolved which.
        NSNumber *opacity=number(dict(dict(target)[@"Window"])[@"opacity"]);if(opacity){IFCompositorDecoration d=isolate.decoration;d.opacity=opacity.doubleValue;isolate.decoration=d;}
    }
    CGRect region=rectOf(effect[@"region"]);if(CGRectIsNull(region))region=[self region:effect snapshot:snapshot elements:elements isolate:isolate refusal:&refused];
    if(refused)return refusal(refused);
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
    BOOL wallpaper=!isolate&&self.program.kind==IFBackgroundKindWallpaper;CGRect dest=CGRectNull;
    if(wallpaper){
        CGPoint centre=CGPointMake(region.origin.x+trunc(region.size.width/2),region.origin.y+trunc(region.size.height/2));NSDictionary *on=nil,*active=nil;
        for(id o in list(snapshot[@"outputs"])){if(!on&&CGRectContainsPoint(viewportOf(dict(o)),centre))on=o;if(!active&&number(effect[@"output"])&&[dict(o)[@"id"]isEqual:effect[@"output"]])active=o;}
        dest=viewportOf(on?:active);
        // The region is that footprint itself (the bare viewport capture): one pass, as on screen.
        if(CGRectEqualToRect(dest,region))wallpaper=NO;
    }
    // Upstream's capture: zoom 1, a transparent target, no outlines, and the background
    // under every scene but not under a window captured alone.
    IFCompositorFrame *frame=[IFCompositorFrame new];
    frame.size=region.size;frame.scale=scale;frame.cameraX=region.origin.x;frame.cameraY=region.origin.y;frame.zoom=1;frame.time=canvasTime();frame.clear=IFCompositorClearTransparent;
    frame.chrome=self.chrome;frame.placeholderColor=self.chrome.backgroundColor;frame.background=isolate||wallpaper?nil:self.program;
    for(IFCompositorElement *element in elements){
        // Nothing of an element farther away than its bar, border and shadow reaches the region.
        double reach=ceil(element.decoration.shadowRadius)+1;
        if(isolate?element==isolate:CGRectIntersectsRect(CGRectInset([self visual:element],-reach,-reach),region))[frame.elements addObject:element];
    }
    NSError *error=nil;CGImageRef image=[renderer newImageForFrame:frame error:&error];if(!image)return refusal(error.localizedDescription?:@"the render did not complete");
    if(wallpaper&&!CGRectIsEmpty(CGRectIntersection(dest,region))){
        // The picture that output shows, drawn by the same module at the capture's density (one texture at
        // most), laid under the scene at whole pixels. Core Graphics counts rows from the bottom.
        IFCompositorFrame *under=[IFCompositorFrame new];size_t wide=CGImageGetWidth(image),high=CGImageGetHeight(image);
        under.size=dest.size;under.scale=fmin(scale,16384/fmax(dest.size.width,dest.size.height));under.cameraX=dest.origin.x;under.cameraY=dest.origin.y;under.zoom=1;under.time=frame.time;under.clear=IFCompositorClearTransparent;under.background=self.program;
        CGImageRef paper=[renderer newImageForFrame:under error:&error];CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=paper?CGBitmapContextCreate(NULL,wide,high,8,0,srgb,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little):NULL;CGColorSpaceRelease(srgb);
        if(!context){CGImageRelease(paper);CGImageRelease(image);return refusal(error.localizedDescription?:@"the render did not complete");}
        double x0=round((CGRectGetMinX(dest)-region.origin.x)*scale),x1=round((CGRectGetMaxX(dest)-region.origin.x)*scale),y0=round((CGRectGetMinY(dest)-region.origin.y)*scale),y1=round((CGRectGetMaxY(dest)-region.origin.y)*scale);
        CGContextDrawImage(context,CGRectMake(x0,high-y1,x1-x0,y1-y0),paper);CGContextDrawImage(context,CGRectMake(0,0,wide,high),image);
        CGImageRelease(paper);CGImageRelease(image);image=CGBitmapContextCreateImage(context);CGContextRelease(context);
        if(!image)return refusal(@"the render did not complete");
    }
    // Encoded in memory and written to the client's path alone: no directory is made and
    // no temporary file beside it, so one that upstream's writer would create is refused here.
    NSMutableData *png=[NSMutableData data];CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL);
    BOOL encoded=NO;if(destination){CGImageDestinationAddImage(destination,image,NULL);encoded=CGImageDestinationFinalize(destination);CFRelease(destination);}
    long pixelsWide=(long)CGImageGetWidth(image),pixelsHigh=(long)CGImageGetHeight(image);CGImageRelease(image);
    if(!encoded)return refusal([NSString stringWithFormat:@"cannot write %@: the image could not be encoded",path]);
    int file=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC,0666),failure=file<0?errno:0;const char *bytes=png.bytes;
    for(size_t left=png.length;!failure&&left;){ssize_t n=write(file,bytes,left);if(n>0){bytes+=n;left-=(size_t)n;}else if(n==0||errno!=EINTR)failure=n?errno:EIO;}
    if(file>=0&&close(file)&&!failure)failure=errno;
    if(failure)return refusal([NSString stringWithFormat:@"cannot write %@: %s (os error %d)",path,strerror(failure),failure]);
    // The size reported is the size of the image written.
    return @{@"path":path,@"width":@(pixelsWide),@"height":@(pixelsHigh)};
}
@end
