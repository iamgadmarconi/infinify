// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop rendering: render, frame timer, panels and outputs, Mac wallpapers, native description, frame stats.
#import "Desktop+Private.h"
#import "CanvasPanel.h"
#import "DWDebugTrace.h"
#import "DWMacWallpaperCache.h"
#include "DWMacWallpaperRefresh.h"
#import "DWGeometryJSON.h"
#import "DesktopPanel.h"
// Menu/notch exclusion only. The Dock remains an overlay: neither its bottom
// reservation nor either side reservation from visibleFrame enters this area.
static CGRect screenUsableRect(NSScreen *screen) {
    NSRect frame=screen.frame;CGFloat top=MAX(screen.safeAreaInsets.top,MAX(0,NSMaxY(frame)-NSMaxY(screen.visibleFrame)));
    top=isfinite(top)?MIN(ceil(top),MAX(0,frame.size.height-1)):0;
    return CGRectMake(0,top,frame.size.width,frame.size.height-top);
}
static CGRect outputUsableRect(CGRect output) {
    CGRect usable=CGRectMake(0,0,output.size.width,output.size.height);CGFloat largest=0;
    for(NSScreen *screen in NSScreen.screens){CGRect bounds=topRect(screen.frame),overlap=CGRectIntersection(output,bounds);CGFloat area=CGRectIsNull(overlap)?0:overlap.size.width*overlap.size.height;
        if(area<=largest)continue;CGRect safe=screenUsableRect(screen);safe=CGRectOffset(safe,bounds.origin.x,bounds.origin.y);CGRect clipped=CGRectIntersection(output,safe);
        if(CGRectIsNull(clipped)||clipped.size.width<=0||clipped.size.height<=0)continue;
        largest=area;usable=CGRectOffset(clipped,-output.origin.x,-output.origin.y);
    }
    return usable;
}
static NSArray<NSDictionary *> *DWExportOrderedTokens(NSArray<NSDictionary *> *tokens,NSDictionary *cohort,NSDictionary *snapshot) {
    if(!cohort.count)return tokens;
    NSMutableDictionary *bindings=[NSMutableDictionary dictionary];for(NSDictionary *window in snapshot[@"windows"])if(DWTyped(window[@"source"],NSDictionary.class))bindings[window[@"window"]]=window[@"source"];
    NSMutableArray *result=nil;
    for(NSUInteger start=0;start<tokens.count;){
        NSDictionary *first=tokens[start];if([first[@"barrier"]boolValue]){start++;continue;}
        NSUInteger end=start+1;while(end<tokens.count&&![tokens[end][@"barrier"]boolValue]&&[first[@"bucket"]isEqual:tokens[end][@"bucket"]])end++;
        NSMutableSet *roots=[NSMutableSet set],*ranks=[NSMutableSet set];NSMutableDictionary *keys=[NSMutableDictionary dictionary];NSMutableArray *ranked=[NSMutableArray array];NSNumber *previous=nil;BOOL valid=YES;
        for(NSUInteger i=start;i<end;i++){
            NSDictionary *token=tokens[i],*family=cohort[token[@"window"]],*root=family[@"root"],*binding=bindings[token[@"window"]];NSString *key=DWTyped(token[@"key"],NSString.class);NSNumber *rank=key?family[@"children"][key]:root[@"stack_rank"];
            if(!root||!rank||![root[@"generation"]isEqual:binding[@"generation"]]||!boundIdentity(root[@"identity"],binding[@"identity"])||[ranks containsObject:rank]){valid=NO;break;}
            NSNumber *window=token[@"window"];NSMutableSet *children=keys[window];if(!children){children=[NSMutableSet set];keys[window]=children;}
            if(key){if([children containsObject:key]){valid=NO;break;}[children addObject:key];}
            else{if([roots containsObject:window]||(previous&&[previous compare:rank]!=NSOrderedDescending)){valid=NO;break;}[roots addObject:window];previous=rank;}
            [ranks addObject:rank];[ranked addObject:@[token,rank]];
        }
        if(valid)for(NSNumber *window in keys)if(![roots containsObject:window]||![keys[window]isEqualToSet:[NSSet setWithArray:[cohort[window][@"children"]allKeys]]]){valid=NO;break;}
        if(valid){[ranked sortUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){return [b[1]compare:a[1]];}];BOOL changed=NO;for(NSUInteger i=0;i<ranked.count;i++)if(ranked[i][0]!=tokens[start+i]){changed=YES;break;}
            if(changed){if(!result)result=[tokens mutableCopy];for(NSUInteger i=0;i<ranked.count;i++)result[start+i]=ranked[i][0];}}
        start=end;
    }
    return result?result.copy:tokens;
}
@implementation Desktop (Rendering)
// Animated backgrounds: is one on an open panel? draw: each such output's next frame is
// drawn when its animate_fps says it is due.
// An open or close animation of the compositor's counts the same way and is drawn on every frame.
// So does a background chunk cache that is still filling (a baked cache_shader, a pyramidal TIFF's chunks): its output is
// given one frame a tick, each spending upstream's per-frame allowances once, until a frame leaves nothing pending.
- (BOOL)animate:(BOOL)draw { BOOL any=NO;for(DesktopView *view in self.views)if(view.window.visible&&[self.compositor animates:view.outputs draw:draw])any=YES;return any; }
// The one frame timer, at the display's refresh rate: a display link (DWFrameDriver.h) of the
// fastest screen a canvas panel is on, 120 Hz on a ProMotion display, where upstream ticks
// from its output's frame loop. It runs while tick_navigation reports needs_frames (a
// flight, a coasting pan, an edge pan under a drag or the cursor) and, in a normal run,
// while the compositor animates something by itself on an open panel (-animate:): an
// animated background, a background chunk cache that is still filling, or a window that
// opens or leaves (an open or close animation, a
// stand-in's fade), and while windows' pictures arrive (-frameComing:). It ends itself when
// none of them is left, a quarter of a second after the last picture, so the frames of a window
// that opened stop with its animation. The link exists only between those two moments:
// nothing is drawn or ticked, and no display callback is asked for, while nothing needs it.
// Each of its frames ends with the compositor's one flush of that refresh: the camera's frame, the
// animations and every picture delivered since the last are drawn together, once.
// frameFlying says it is serving camera motion: each of its frames then watches the hot
// corners and ticks the controller, and the idle poll neither ticks nor draws. While it
// serves the compositor only, a background or a window's animation alike, the poll keeps
// ticking and watching the corners. It describes the scene again only when observation
// or a command changed it; the compositor already has the idle scene. No such frame
// ticks the camera. Either way every frame of this timer has the
// pointer's part first (-pointerFrame: the hover a tracking area has waiting, then cursor
// edge pan's report): while this timer runs pointer-hover arms none of its own, so a frame
// that served the compositor and skipped the pointer would leave hover to the idle poll.
// A frame that stopped the timer and started another (a quit, a screen change) leaves the new one alone.
- (void)startFrames {
    if(self.frameDriver||self.cleaning||self.sessionInactive||[self nativeUnavailable])return;self.frameQuiet=0;
    NSArray *screens=[self canvasScreens];
    __weak Desktop *weak=self;self.frameDriver=[DWFrameDriver driverOn:screens frame:^(DWFrameDriver *driver){Desktop *desktop=weak;
        if(!desktop||desktop.frameDriver!=driver){[driver invalidate];return;}
        [desktop endLostInput];
        if(desktop.frameFlying){[desktop watchCorners];desktop.frameFlying=[desktop cameraFrame];}
        else [desktop pointerFrame:YES];
        if(desktop.frameDriver!=driver){[driver invalidate];return;}
        // The one flush of this refresh, after the camera's frame is described and the animations are marked: whatever the
        // streams delivered since the last one, the camera's move and an animation's step are one pass over the scene.
        BOOL animating=[desktop animate:YES];[desktop.compositor flushFrameAtTime:driver.presentationTime refreshRate:driver.framesPerSecond];[desktop.native submit];
        // Pictures keep the timer too. They come when their windows draw, a video's every few refreshes, so the timer
        // outlasts the last of them by a quarter of a second: a display link is not made and ended between two frames of a film.
        if(desktop.frameOwed){desktop.frameOwed=NO;desktop.frameQuiet=0;}else desktop.frameQuiet++;
        if(!animating&&!desktop.frameFlying&&desktop.frameQuiet*4>driver.framesPerSecond){[driver invalidate];desktop.frameDriver=nil;}}];
}
// The compositor's question (DWCanvasRenderer.h, `frame`): will a frame of the timer flush what has just changed? start: a
// picture arrived, an animation stepped or a chunk was decoded, and the timer is started for it if it is not running.
// A timer that has not called back for a quarter of a second is not counted on (its display is asleep, or there is none):
// the answer is NO and the compositor flushes by itself, as the idle poll's own description does. One silent for a second
// is replaced, at most once a second, so a link that will never call again cannot keep the canvas waiting for it.
- (BOOL)frameComing:(BOOL)start {
    if(self.cleaning||!self.panels.count)return NO;
    CFTimeInterval silent=self.frameDriver?CACurrentMediaTime()-self.frameDriver.lastFrame:0;
    if(start){self.frameOwed=YES;if(silent>1&&!self.frameFlying){[self.frameDriver invalidate];self.frameDriver=nil;silent=0;}[self startFrames];}
    return self.frameDriver&&silent<.25;
}
// The screens the canvas panels are on: the frame timer follows the fastest, and a window is captured at its rate.
- (NSArray<NSScreen *> *)canvasScreens { NSMutableArray<NSScreen *> *screens=[NSMutableArray array];for(NSPanel *panel in self.panels)if(panel.screen&&![screens containsObject:panel.screen])[screens addObject:panel.screen];return screens; }
- (NSDictionary *)nativeDescription:(NSDictionary *)snapshot {
    if(!self.native||!snapshot)return nil;
    if(!self.nativeViews)self.nativeViews=[DWNativeViews new];
    BOOL enabled=!self.native.ended&&!self.sessionInactive&&!self.cleaning&&self.panels.count;
    if(self.nativeViewSnapshot==snapshot&&self.nativeViewPresenter==self.native&&self.nativeViewFamilyRevision==self.nativeFamilyRevision&&self.nativeViewEnabled==enabled&&self.nativeViewTransferRevision==self.nativeViews.transferRevision&&self.nativeViews.presentationSnapshot)return enabled?[self nativeFillBackground:self.nativeOwnerSnapshot]:self.nativeOwnerSnapshot;
    NSMutableDictionary *bound=[NSMutableDictionary dictionary],*families=[NSMutableDictionary dictionary];
    if(enabled)for(LiveSource *source in self.sources.allValues)if(!source.detached){bound[source.logical]=source.identity;if(source.nativeFamily)families[source.logical]=source.nativeFamily;}
    self.nativeOwnerSnapshot=[self.nativeViews describe:snapshot bound:bound families:families];
    self.nativeViewSnapshot=snapshot;self.nativeViewPresenter=self.native;self.nativeViewFamilyRevision=self.nativeFamilyRevision;self.nativeViewEnabled=enabled;self.nativeViewTransferRevision=self.nativeViews.transferRevision;
    // Admission repaints the copies but must preserve its newly checked ACK.
    // Only a staged/revoked request needs a causally newer helper submission.
    if(self.nativePlacementRequestRevision!=self.nativeViews.placementRequestRevision){
        self.nativePlacementRequestRevision=self.nativeViews.placementRequestRevision;
        [self.native requireFreshPlacementAcknowledgement];
    }
    // Preserve the already visible native background until the picture covers
    // its final extent. Recheck this uncached, presenter-only coverage on every
    // description; it creates no controller hit site or input authority.
    return enabled?[self nativeFillBackground:self.nativeOwnerSnapshot]:self.nativeOwnerSnapshot;
}
- (NSDictionary *)visualSnapshot { return self.controllerVisualSnapshot?:[self call:@{@"op":@"snapshot"}]; }
- (NSDictionary *)presentationSnapshot {
    NSDictionary *snapshot=[self visualSnapshot];
    if(!self.native){
        NSDictionary *families=self.nativeFamilies.descriptions;
        if(!families.count)return snapshot;
        if(self.overlayFamilyBase==snapshot&&self.overlayFamilyDescriptions==families)return self.overlayFamilySnapshot?:snapshot;
        NSMutableDictionary *bound=[NSMutableDictionary dictionary];for(LiveSource *source in self.sources.allValues)if(!source.detached)bound[source.logical]=source.identity;
        self.overlayFamilySnapshot=DWNativeFamilyPresentationSnapshot(snapshot,bound,families);self.overlayFamilyBase=snapshot;self.overlayFamilyDescriptions=families;
        return self.overlayFamilySnapshot?:snapshot;
    }
    [self nativeDescription:snapshot];return self.nativeViews.presentationSnapshot?:snapshot;
}
- (void)render {
    [self updateNativeFill];
    NSDictionary *snapshot=[self visualSnapshot];
    NSDictionary *nativeSnapshot=[self nativeDescription:snapshot];
    NSDictionary *presentation=self.native?(self.nativeViews.presentationSnapshot?:snapshot):[self presentationSnapshot];
    // The outputs the pointer is looked up on, and whether cursor edge pan wants it reported: on while the snapshot's navigation.cursor_pan.needs_pointer says so. See -pointerFrame.
    self.pointerOutputs=self.panels.count?asArray(snapshot[@"outputs"]):nil;
    // Also while sloppy focus owes the pointer's output a look because its view moved under the resting pointer (upstream's pull; navigation.hover_pull).
    self.pointerWanted=self.pointerOutputs&&([DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"cursor_pan"],NSDictionary.class)[@"needs_pointer"]isEqual:@YES]||[DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"hover_pull"],NSDictionary.class)[@"needs_pointer"]isEqual:@YES]);
    // pass_keys: every reply the shell applies is drawn from this snapshot, so what the focused window's rule passes is read here and nowhere else:
    // a bound or scripted command's (-applyReply:), a pointer policy press's and a hover's that moved the focus (-pointerApply:, -pointerFocused:),
    // a focus request's answer and a native focus report (the coordinator's `changed`), a size transaction's tail, each frame of a flight.
    // The hot keys act only when it changed: the passed chords stop being hot keys and reach the focused application from macOS itself.
    NSArray<NSString *> *refused=[self.hotKeys pass:DWFocusedStandIn(snapshot)?@NO:snapshot[@"pass_keys"]];if(refused.count)[self flashStatus:summary(@"Shortcut unavailable",refused)];for(NSString *line in refused)[self say:[@"Shortcut unavailable: " stringByAppendingString:line]];
    [self adoptRender:snapshot];self.compositor.nativeMenuBackground=self.native&&!self.windowed&&!self.sessionInactive&&!self.cleaning&&![self nativeUnavailable];
    for(DesktopView *view in self.views)[view render:presentation];
    [self updateStandInKeyboard:snapshot];
    self.renderedPresentation=presentation;self.renderedStatusText=self.statusText;
    // Native presentation: the same snapshot as one frame of window records. It goes with the frame timer's flush of this refresh
    // when one is coming, as the canvas's own drawing does, and at once when none is: a move asked over IPC, the idle poll.
    if(self.native&&self.panels.count&&!self.cleaning&&!self.sessionInactive){
        NSMutableDictionary<NSNumber *,NSDictionary *> *bound=[NSMutableDictionary dictionary];for(LiveSource *source in self.sources.allValues)if(!source.detached)bound[source.logical]=source.identity;
        [self.native describe:nativeSnapshot bound:bound];if(![self frameComing:NO])[self.native submit];}
    // What the resting status would show now, said once while it stays up. What it rests on is not news: the chords registered, and a config or background note that was written when it arose.
    // Back at rest, the note last said is forgotten: the next one like it is another event. A failed read of the windows is renewed every two
    // seconds or so, after its note expired, and keeps its own count of what was written (-discoveryFailed:).
    if([self.statusText isEqual:[self restingStatus]])self.said=nil;else if(![self.statusText isEqual:self.discoveryNote])[self say:self.statusText];
    // An animated background keeps the frame timer alive by itself, and so does an animation this description began: a window that opened with
    // its picture already there or closed, a stand-in that left. Neither is camera motion, so the timer is started without frameFlying.
    if(!self.frameDriver&&[self animate:NO])[self startFrames];
    [self publishState];
}
// The public desktop-image API exposes the current still URL and options, not
// the rendered frame of an Aerial/video wallpaper. No preference is modified.
- (IFBackgroundProgram *)macWallpaperForOutput:(NSNumber *)output description:(NSDictionary *)description base:(IFBackgroundProgram *)base {
    (void)output;if(!self.compositor.inheritsMacBackground){if(self.macWallpapers.count){self.wallpaperEpoch++;[self.macWallpapers removeAllObjects];}return base;}if(self.cleaning||self.sessionInactive)return base;
    CGRect bounds=DWRectFromJSON(description[@"screen_bounds"]);NSScreen *chosen=nil;CGFloat largest=0;
    for(NSScreen *screen in NSScreen.screens){CGRect overlap=CGRectIntersection(bounds,topRect(screen.frame));CGFloat area=CGRectIsNull(overlap)?0:overlap.size.width*overlap.size.height;if(area>largest){largest=area;chosen=screen;}}
    NSNumber *display=DWTyped(chosen.deviceDescription[@"NSScreenNumber"],NSNumber.class);if(!display)return base;
    CGSize pixels=CGSizeMake(round(chosen.frame.size.width*chosen.backingScaleFactor),round(chosen.frame.size.height*chosen.backingScaleFactor));
    NSArray *pixelKey=@[@(pixels.width),@(pixels.height)];
    if(!self.macWallpapers)self.macWallpapers=[NSMutableDictionary dictionary];NSMutableDictionary *prior=self.macWallpapers[display];
    // Rendering, exports and image-load completion reuse the last observation.
    // Only a host refresh, changed config or changed display raster queries
    // NSWorkspace. Repeated refreshes of the same display/config coalesce while
    // its decoder is pending; a newer refresh stays due after publication.
    BOOL sameBase=prior[@"base"]==base&&[prior[@"pixels"]isEqual:pixelKey];
    if(sameBase&&([prior[@"checking"]boolValue]||[prior[@"refresh"]unsignedLongLongValue]==self.wallpaperRefreshGeneration))return prior[@"program"]?:base;
    // AppKit requires these desktop-image queries on the main thread. File
    // metadata, missing-source cache lookup and texture decoding stay off it.
    CFTimeInterval observedAt=CACurrentMediaTime();
    NSWorkspace *workspace=NSWorkspace.sharedWorkspace;NSURL *url=[workspace desktopImageURLForScreen:chosen];
    NSDictionary *options=[workspace desktopImageOptionsForScreen:chosen]?:@{};
    // The system default wallpaper can expose a still URL but no options at
    // all, while macOS displays it edge to edge. Keep the canvas's cover
    // fallback for that unavailable metadata; an explicit fit/false remains
    // authoritative, as do AppKit's defaults in a populated options record.
    NSNumber *scaling=DWTyped(options[NSWorkspaceDesktopImageScalingKey],NSNumber.class)?:@(NSImageScaleProportionallyUpOrDown);
    NSNumber *clipping=DWTyped(options[NSWorkspaceDesktopImageAllowClippingKey],NSNumber.class)?:@(options.count==0);
    NSColor *color=[options[NSWorkspaceDesktopImageFillColorKey]isKindOfClass:NSColor.class]?options[NSWorkspaceDesktopImageFillColorKey]:NSColor.blackColor;
    color=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace]?:NSColor.blackColor;NSArray *fill=@[@(color.redComponent),@(color.greenComponent),@(color.blueComponent),@1];
    NSDictionary *desktop=@{@"url":url.absoluteString?:@"",@"scaling":scaling,@"clipping":clipping,@"fill":fill,@"pixels":pixelKey};
    NSDictionary *priorSignature=prior[@"signature"];
    IFBackgroundProgram *previous=[DWTyped(prior[@"desktop"],NSDictionary.class)[@"url"]isEqual:desktop[@"url"]]?prior[@"program"]:nil;
    if(previous.errorText||!previous.config.inheritedWallpaper)previous=nil;
    NSMutableDictionary *record=[@{@"base":base,@"desktop":desktop,@"pixels":pixelKey,@"refresh":@(self.wallpaperRefreshGeneration),@"observed_at":@(observedAt),@"checking":@YES,@"program":previous?:base}mutableCopy];self.macWallpapers[display]=record;
    IFBackgroundConfig *config=[base.config copy];config.type=IFBackgroundTypeWallpaper;config.path=url.path;config.inheritedWallpaper=YES;
    config.wallpaperScaling=scaling.integerValue;config.wallpaperClipping=clipping.boolValue;config.wallpaperFillColor=fill;
    if(!self.wallpaperWorker)self.wallpaperWorker=dispatch_queue_create("org.infinify.wallpaper",dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
    id<MTLDevice> device=base.device;uint64_t epoch=self.wallpaperEpoch;__weak Desktop *weak=self;
    dispatch_async(self.wallpaperWorker,^{
        id modified=nil,size=nil;if(url.isFileURL){NSURL *file=[NSURL fileURLWithPath:url.path];[file getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];[file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];}
        NSMutableDictionary *signature=[desktop mutableCopy];signature[@"modified"]=modified?:NSNull.null;signature[@"bytes"]=size?:NSNull.null;signature[@"retry"]=modified?@0:@((uint64_t)(CACurrentMediaTime()/60));
        BOOL unchanged=sameBase&&[priorSignature isEqual:signature],readable=url.isFileURL&&url.path.length;
        IFBackgroundProgram *loaded=nil;
        if(!unchanged&&readable){
            // A removed source can still be the active desktop image. Resolve
            // only its exact path-hashed, display-sized macOS cache rendition.
            if(access(config.path.fileSystemRepresentation,R_OK)!=0){NSURL *cached=DWMacCachedWallpaper(url,pixels);if(cached)config.path=cached.path;}
            loaded=[IFBackgroundProgram programWithConfig:config device:device];
        }
        NSDictionary *completedSignature=signature.copy;
        dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(!d||d.cleaning||d.wallpaperEpoch!=epoch||d.macWallpapers[display]!=record)return;
            record[@"signature"]=completedSignature;record[@"checking"]=@NO;
            // Failed inherited sources stay on the previous wallpaper or grid;
            // a missing macOS file must not become a permanent canvas error bar.
            if(!unchanged&&!readable)fprintf(stderr,"background: macOS exposes no readable still wallpaper for display %s; using canvas default\n",display.stringValue.UTF8String);
            else if(loaded.errorText)fprintf(stderr,"background: macOS wallpaper unavailable: %s\n",loaded.errorText.UTF8String);
            else if(loaded)record[@"program"]=loaded;
            [d.compositor refreshBackgrounds];});
    });
    return record[@"program"];
}
- (void)refreshMacWallpapers {
    if(!self.compositor.inheritsMacBackground||self.cleaning||self.sessionInactive)return;
    self.wallpaperRefreshGeneration++;
    NSMutableSet *alive=[NSMutableSet set];for(NSScreen *screen in NSScreen.screens){NSNumber *display=DWTyped(screen.deviceDescription[@"NSScreenNumber"],NSNumber.class);if(display)[alive addObject:display];}
    for(NSNumber *display in self.macWallpapers.allKeys)if(![alive containsObject:display])[self.macWallpapers removeObjectForKey:display];
    [self.compositor refreshBackgrounds];
}
- (void)watchMacWallpapers {
    if(self.wallpaperTimer)return;__weak Desktop *weak=self;
    self.wallpaperSpaceObserver=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification){(void)notification;[weak refreshMacWallpapers];}];
    // Public AppKit has no wallpaper-change notification. Its synchronous
    // queries can wait on WindowServer, so periodic checks also defer for video
    // or background frames, not only camera/input motion. A continuous producer
    // still gets an observation within thirty seconds; event refreshes above
    // and display/session/config changes do not use this postponement.
    self.wallpaperTimer=[NSTimer timerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer){
        Desktop *d=weak;if(!d||d.wallpaperTimer!=timer||(!d.panels.count&&!d.desktopUp)||!d.compositor.inheritsMacBackground||d.cleaning||d.sessionInactive)return;
        CFTimeInterval now=CACurrentMediaTime();
        BOOL frames=d.frameDriver&&now-d.frameDriver.lastFrame<.25;
        BOOL busy=frames||NSEvent.pressedMouseButtons||d.frameFlying||d.flying||d.magnifying||d.gestureOwner||d.trackpad.engaged||d.compositor.hasGeometryTransitions;
        // A changed raster on one display must not renew another display's
        // deadline. This display-count scan occurs only on the fallback timer.
        CFTimeInterval observedAt=0;BOOL first=YES;
        for(NSDictionary *record in d.macWallpapers.allValues){double value=[record[@"observed_at"]doubleValue];if(!isfinite(value)||value<=0){observedAt=0;break;}observedAt=first?value:fmin(observedAt,value);first=NO;}
        double delay=DWMacWallpaperRefreshDelay(now,observedAt,busy);
        if(delay>0){timer.fireDate=[NSDate dateWithTimeIntervalSinceNow:fmax(.01,delay)];return;}
        [d refreshMacWallpapers];timer.fireDate=[NSDate dateWithTimeIntervalSinceNow:5];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.wallpaperTimer forMode:NSRunLoopCommonModes];
}
- (void)stopMacWallpapers {
    self.wallpaperEpoch++;[self.wallpaperTimer invalidate];self.wallpaperTimer=nil;
    if(self.wallpaperSpaceObserver)[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self.wallpaperSpaceObserver];self.wallpaperSpaceObserver=nil;
    [self.macWallpapers removeAllObjects];self.macWallpapers=nil;
}
// A normal run's compositor, made when the canvas first draws or is first captured.
- (DWCanvasRenderer *)canvasRenderer {
    if(self.compositor||self.cleaning)return self.compositor;
    __weak Desktop *weak=self;
    self.compositor=[[DWCanvasRenderer alloc]initWithSource:^DWCanvasContent(NSNumber *window,NSDictionary *placement){
        LiveSource *source=weak.exportSources[window]?:weak.sources[window];DWCanvasContent none={NULL,0,CGRectNull};
        if(!source||source.detached||!source.pixels||(source.nativeReplica&&source.error))return none;
        (void)placement;return (DWCanvasContent){source.pixels,source.frames,source.contentRect};
    }];
    self.compositor.backgroundForOutput=^IFBackgroundProgram *(NSNumber *output,NSDictionary *description,IFBackgroundProgram *base){return [weak macWallpaperForOutput:output description:description base:base]?:base;};
    [self watchMacWallpapers];
    self.compositor.frame=^BOOL(BOOL start){return [weak frameComing:start];};
    self.compositor.exportAttachments=^NSArray<DWCanvasAttachment *> *(NSNumber *window){return [weak.exportAttachments[window]copy];};
    self.compositor.exportOrderRoot=^BOOL(NSNumber *window){return weak.exportOrdering[window]!=nil;};
    self.compositor.exportOrder=^NSArray<NSDictionary *> *(NSArray<NSDictionary *> *tokens,NSDictionary *effect,NSDictionary *snapshot){(void)effect;return DWExportOrderedTokens(tokens,weak.exportOrdering,snapshot);};
    self.compositor.nativeWindows=self.native!=nil;
    self.compositor.nativeReplica=^BOOL(NSNumber *window,NSNumber *output){return [weak.nativeViews replica:window output:output];};
    self.compositor.liveAttachments=^NSArray<DWCanvasAttachment *> *(NSNumber *window,NSNumber *output){LiveSource *source=weak.sources[window];return !weak.cleaning&&!weak.sessionInactive&&!weak.native.ended&&source.pixels&&!source.error&&!source.detached&&(!weak.native||[weak.nativeViews replica:window output:output])?[weak.nativeFamilies attachments:window]:@[];};
    self.compositor.liveOrder=^NSArray<NSDictionary *> *(NSArray<NSDictionary *> *tokens,NSNumber *output){(void)output;return [weak.nativeFamilies orderedTokens:tokens]?:tokens;};
    self.compositor.liveOrderRevision=^uint64_t(NSNumber *output){(void)output;return weak.nativeFamilies.orderRevision;};
    if(DWDebugTrace()){self.compositor.measured=YES;[self startFrameStats];}
    return self.compositor;
}
// INFINIFY_DEBUG: how long the main thread went without turning its run loop, the longest such stretch since it was last asked.
// Every activity of the loop is a mark, and so are its exit and its next entry, between which the idle poll runs; the stretch
// from one mark to the next is the time a callout held the thread, but for the one the loop slept through. Main thread only.
static CFTimeInterval DWTurnMark,DWTurnWorst;static BOOL DWTurnSlept;
static void DWTurnObserved(CFRunLoopObserverRef observer,CFRunLoopActivity activity,void *info) {
    (void)observer;(void)info;CFTimeInterval now=CACurrentMediaTime();
    if(DWTurnMark&&!DWTurnSlept)DWTurnWorst=fmax(DWTurnWorst,now-DWTurnMark);
    DWTurnMark=now;DWTurnSlept=activity==kCFRunLoopBeforeWaiting;
}
// INFINIFY_DEBUG, while the canvas is open, one stderr line every two seconds, every rate a second:
//   frames: 2.00s display=120 redraws=R flushes=F drawn=D presented=P flush_ms=MEAN/WORST main_gap_ms=G sources #ID=DELIVERED/ACCEPTED/SKIPPED ...
// display: the refresh rate the frame timer follows. redraws: changes that asked for a frame. flushes: the times the scene was gone
// through with an output to draw. drawn: frames encoded and handed to the display. presented: frames the display showed.
// flush_ms: how long one flush kept the main thread, mean and worst. main_gap_ms: the worst stretch the main thread was not at
// its run loop. Per bound window: frames its stream delivered, those kept, and those passed over as unchanged.
// Without the variable nothing is timed or observed and the renderer counts nothing; a source's three counters are added to and never read.
- (void)startFrameStats {
    if(self.statsTimer)return;
    CFRunLoopObserverRef observer=CFRunLoopObserverCreate(kCFAllocatorDefault,kCFRunLoopAllActivities,true,0,DWTurnObserved,NULL);CFRunLoopAddObserver(CFRunLoopGetMain(),observer,kCFRunLoopCommonModes);CFRelease(observer);
    __weak Desktop *weak=self;self.statsSince=CACurrentMediaTime();
    self.statsTimer=[NSTimer timerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){(void)timer;[weak frameStats];}];[NSRunLoop.mainRunLoop addTimer:self.statsTimer forMode:NSRunLoopCommonModes];
}
- (void)frameStats {
    // Nothing is taken while there is no line to print: a period that is not printed is in the next one that is.
    if(!self.compositor||!self.panels.count||self.cleaning)return;
    CFTimeInterval now=CACurrentMediaTime(),span=now-self.statsSince;if(span<=0)return;self.statsSince=now;double worst=DWTurnWorst;DWTurnWorst=0;
    DWCanvasCounts c=[self.compositor takeCounts];NSMutableString *sources=[NSMutableString string];
    for(NSNumber *window in [self.sources.allKeys sortedArrayUsingSelector:@selector(compare:)]){LiveSource *source=self.sources[window];
        [sources appendFormat:@" #%@=%.1f/%.1f/%.1f",window,source.delivered/span,source.accepted/span,source.skipped/span];source.delivered=source.accepted=source.skipped=0;}
    NSInteger rate=0;for(NSScreen *screen in [self canvasScreens])rate=MAX(rate,screen.maximumFramesPerSecond);
    fprintf(stderr,"frames: %.2fs display=%ld redraws=%.1f flushes=%.1f drawn=%.1f presented=%.1f flush_ms=%.2f/%.2f main_gap_ms=%.1f sources%s\n",span,(long)rate,c.requests/span,c.flushes/span,c.drawn/span,c.presented/span,
        c.flushes?c.flushSeconds/c.flushes*1000:0,c.flushWorst*1000,worst*1000,sources.length?sources.UTF8String:" none");
    NSMutableString *buffers=[NSMutableString string];for(NSNumber *window in [self.sources.allKeys sortedArrayUsingSelector:@selector(compare:)]){LiveSource *source=self.sources[window];[buffers appendFormat:@" #%@=%.0fx%.0f",window,source.buffer.width,source.buffer.height];}fprintf(stderr,"buffers:%s\n",buffers.length?buffers.UTF8String:" none");
    for(NSPanel *panel in self.panels){CALayer *layer=panel.contentView.layer;
        fprintf(stderr,"panel: wid=%ld level=%ld visible=%d unoccluded=%d alpha=%.3f layer_hidden=%d layer_opacity=%.3f size=%.0fx%.0f hides_inactive=%d can_hide=%d active_space=%d\n",(long)panel.windowNumber,(long)panel.level,panel.isVisible,(panel.occlusionState&NSWindowOcclusionStateVisible)!=0,panel.alphaValue,layer.hidden,layer.opacity,layer.bounds.size.width,layer.bounds.size.height,panel.hidesOnDeactivate,panel.canHide,panel.isOnActiveSpace);}
}
// What a config load changed in the background, the chrome or the outlines is adopted
// before any output is described, and a background that fell back says why, as
// upstream's error bar does. A config load the controller refused keeps the resting status.
- (void)adoptRender:(NSDictionary *)snapshot {
    if(!self.views.count)return;[[self canvasRenderer]configure:snapshot];
    NSString *note=self.compositor.note,*old=self.backgroundNote;if(note==old||[note isEqual:old])return;self.backgroundNote=note;
    if(note){fprintf(stderr,"%s\n",note.UTF8String);if(!self.configNote)self.statusText=note;}
    else if([self.statusText isEqual:old])self.statusText=[self restingStatus];
}
- (DesktopView *)panel:(NSRect)frame outputRects:(NSArray *)rects identities:(NSArray *)identities {
    BOOL desktop=!self.windowed; // a normal run's panel on a display: the display, whole
    NSPanel *panel=[[(desktop?DesktopPanel.class:CanvasPanel.class) alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO;panel.hidesOnDeactivate=NO;panel.canHide=!desktop&&!self.native;panel.level=self.windowed?NSNormalWindowLevel:NSFloatingWindowLevel;
    // A compositor canvas stays ordered when a managed application becomes
    // active. NSPanel otherwise defaults to hiding on app deactivation.
    // Native presentation: the canvas is the surface behind the windows it places. One level under the ordinary windows, in front
    // of whatever else is there: every window of level 0 is then above it, the managed ones and any other application's, and
    // nothing brings it over one, a click on it included. (A desktop run of this would sit just above the desktop icons; this is the windowed run's.)
    if(self.native)panel.level=NSNormalWindowLevel-1;panel.animationBehavior=NSWindowAnimationBehaviorNone;
    // A nonactivating native canvas cannot rely on activation to enter a
    // Space. Keep the owned canvas present and stationary on every Space.
    panel.collectionBehavior=(self.native?NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary:NSWindowCollectionBehaviorMoveToActiveSpace)|NSWindowCollectionBehaviorFullScreenAuxiliary;
    // The explicitly spawned scoped test's own canvas stays visible. Native
    // mode retains ordinary canvas input for its replica destinations; capture
    // throughput runs leave pointer handling off. No other window is reordered.
    BOOL nativePanel=self.native&&getenv("INFINIFY_DEBUG_NATIVE_PANEL")&&atoi(getenv("INFINIFY_DEBUG_NATIVE_PANEL"))==1;
    if(self.scope&&(!self.native||nativePanel)&&getenv("INFINIFY_DEBUG_TEST_PANEL")&&atoi(getenv("INFINIFY_DEBUG_TEST_PANEL"))==1){panel.level=NSFloatingWindowLevel;panel.ignoresMouseEvents=!self.native;panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary;}
    DesktopView *view=[[DesktopView alloc]initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];view.desktop=self;view.globalBounds=topRect(frame);view.outputs=[NSMutableArray array];view.wantsLayer=YES;view.layer.backgroundColor=[NSColor colorWithSRGBRed:.045 green:.065 blue:.10 alpha:1].CGColor;panel.contentView=view;
    if(self.native){NSMutableArray<NSPasteboardType> *types=[NSMutableArray arrayWithObjects:NSPasteboardTypeFileURL,NSPasteboardTypeURL,NSPasteboardTypeTIFF,NSPasteboardTypePNG,nil];
        [types addObjectsFromArray:NSFilePromiseReceiver.readableDraggedTypes];[view registerForDraggedTypes:types];}
    // A window wholly under an opaque window is told it is not visible, and applications stop drawing one that is not: a
    // window took typing under the canvas and its tile showed none of it, though the text was there once the canvas was
    // gone (owner's run, 2026-10-10). Every window a normal run shows is wholly under this panel. The window server
    // counts a panel as covering only at full alpha; declaring the panel and its layers non-opaque changed nothing, an alpha
    // value a thousandth short of one did (measured on a fixture window under a floating panel, the same day). At that alpha
    // nothing of what lies under the canvas shows through an 8-bit pixel.
    // Not under native presentation, where no window lies under the panel.
    if(!self.native)panel.alphaValue=.999;
    // The trackpad's raw touches, for gestures of three or more fingers.
    view.allowedTouchTypes=NSTouchTypeMaskIndirect;
    for(NSUInteger i=0;i<rects.count;i++){NSMutableDictionary *registration=[@{@"op":@"register_output",@"stable_id":identities[i],@"screen_bounds":rects[i]}mutableCopy];
        registration[@"usable_rect_local"]=DWRectJSON(outputUsableRect(DWRectFromJSON(rects[i])));
        NSNumber *output=[self call:registration][@"output"];if(output)[view.outputs addObject:output];}
    // Pointer motion over the canvas: hover, sloppy focus, pick mode.
    if(!self.canvasCursor)self.canvasCursor=[DWCanvasCursor new];view.hover=[[DWPointerHover alloc]initWithHost:view];view.hover.forwarding=!self.hoverUndelivered;
    // The view is the canvas alone. The desktop's panels are on every Space, a fullscreen application's included, and stay where
    // they are through Mission Control, like the desktop they replace.
    if(desktop)panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle|NSWindowCollectionBehaviorFullScreenAuxiliary;
    [self.panels addObject:panel];[self.views addObject:view];[panel orderFrontRegardless];return view;
}
- (void)openPanels {
    if(self.panels.count)return;self.cleaning=NO;
    // Notifications cannot report sleep that preceded this process. Establish
    // current admission before outputs, input, discovery or autostart exist;
    // unlike a departure, this unopened canvas has nothing to drain or save.
    if(!self.windowed||self.native){
        self.desktopUp=YES;
        if(!self.session){__weak Desktop *weak=self;self.session=[[DWSessionWatch alloc]initWithReturned:^{[weak returned];} left:^{[weak leftSession];}];self.sessionInactive=!self.session.ready;self.sessionAwaitingCanvas=self.sessionInactive;}
        if(self.sessionInactive)return;
    }
    // Return to desktop stopped the config watcher and dropped the key table: read the config again.
    if(!self.configWatcher)[self loadConfig:NO];
    if(!self.trackpad){__weak Desktop *weak=self;self.trackpad=[[DWTrackpadGestures alloc]initWithEmit:^(NSDictionary *event){[weak noteDockGesture:event];[weak gesture:event owner:1];}];}
    if(self.nativeEndpoints.count&&self.native.ended){self.nativeResumeWanted=YES;self.nativeResumeAfter=0;}
    // The analogue of upstream's nested winit backend: one ordinary window, one output.
    if(self.windowed){NSScreen *screen=NSScreen.mainScreen?:NSScreen.screens.firstObject;NSRect area=screen.visibleFrame;CGFloat width=MIN(self.windowSize.width,area.size.width),height=MIN(self.windowSize.height,area.size.height);
        NSRect frame=NSMakeRect(floor(NSMidX(area)-width/2),floor(NSMidY(area)-height/2),width,height);
        if(screen){
            // Scoped two-view runtime acceptance uses the ordinary renderer and
            // ownership adapter in one owned panel. No real display is changed.
            BOOL split=self.scope&&self.native&&self.debugPointer&&getenv("INFINIFY_DEBUG_NATIVE_PANEL")&&atoi(getenv("INFINIFY_DEBUG_NATIVE_PANEL"))==1
                &&getenv("INFINIFY_DEBUG_NATIVE_VIEWS")&&atoi(getenv("INFINIFY_DEBUG_NATIVE_VIEWS"))==2;
            CGRect canvas=topRect(frame);
            if(split){CGFloat half=floor(canvas.size.width/2);CGRect left=canvas,right=canvas;left.size.width=half;right.origin.x+=half;right.size.width-=half;
                [self panel:frame outputRects:@[DWRectJSON(left),DWRectJSON(right)] identities:@[@"fixture-view-a",@"fixture-view-b"]];}
            else [self panel:frame outputRects:@[DWRectJSON(canvas)] identities:@[@"windowed"]];}}
    // The desktop canvas still covers the whole display; fit/fullscreen geometry
    // excludes its menu/notch band, while the Dock draws over the panel.
    else for(NSScreen *screen in NSScreen.screens){NSNumber *display=screen.deviceDescription[@"NSScreenNumber"];CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display.unsignedIntValue);NSString *name=uuid?CFBridgingRelease(CFUUIDCreateString(NULL,uuid)):nil;if(uuid)CFRelease(uuid);if(!name)continue;[self panel:screen.frame outputRects:@[DWRectJSON(topRect(screen.frame))] identities:@[name]];}
    self.panelScreens=physicalScreens();
    if(self.panels.count)self.sessionAwaitingCanvas=NO;
    // Every display that exists is registered now. A screen change and Return to desktop remove them all first, so only here can the controller
    // tell a display that is gone from one that came straight back: a pin whose own display is missing moves to one that is there.
    if([DWTyped([self call:@{@"op":@"outputs_settled"}][@"dirty"],NSNumber.class)boolValue])self.sceneDirty=YES;
    // Windowed mode registers no global hot key: pointer and IPC only.
    NSArray<NSString *> *refused=[self startKeys];if(refused.count)self.statusText=summary(@"Shortcut unavailable",refused);[self armCorners:[self call:@{@"op":@"bindings"}]];
    // The status note names one: every chord macOS refused is named on stderr, as a reload names them.
    for(NSString *line in refused)[self say:[@"Shortcut unavailable: " stringByAppendingString:line]];
    [self configureResize];[self configureNavigation];
    // Capture overlays retain their Screen Recording gate. Authenticated native
    // presentation discovers metadata without asking for pictures or permission.
    // It says why; a more specific problem already in the resting status keeps its place there.
    // The Accessibility note of the same launch is not one: it follows this note.
    BOOL unmanaged=self.managing&&!self.manager&&!self.startupError;
    // Native discovery uses window metadata. Extra display views refresh shareable capture identities separately, only on demand.
    if(unmanaged&&!(self.manager=[DWWindowManager managerWithHost:self scope:self.scope mode:self.native?DWWindowDiscoveryModeNativePresentation:DWWindowDiscoveryModeCaptureOverlay])){
        NSString *note=@"Windows are not managed: Infinify has no Screen Recording access. A run without --windowed asks for it.";
        [self say:note];
        if([self.statusText isEqual:[self restingStatus]])self.statusText=note;
        else if([self.statusText isEqual:focusAccessNote])self.statusText=[NSString stringWithFormat:@"%@ · %@",note,focusAccessNote];}
    // --only-pid: which processes, and that without Screen Recording access their windows are bound but not pictured.
    else if(unmanaged&&self.scope)[self say:[NSString stringWithFormat:@"Managing only the windows of --only-pid %@.%@",[[self.scope.allKeys sortedArrayUsingSelector:@selector(compare:)]componentsJoinedByString:@","],self.native?@" Native presentation uses live copies for additional display views when Screen Recording access is already available.":self.manager.capturing?@"":@" No Screen Recording access: their tiles have no picture."]];
    self.manager.nativePanels=self.native!=nil;
    if(self.native&&self.scope&&getenv("INFINIFY_DEBUG_TEST_PANEL")&&atoi(getenv("INFINIFY_DEBUG_TEST_PANEL"))==1&&getenv("INFINIFY_DEBUG_NATIVE_PANEL")&&atoi(getenv("INFINIFY_DEBUG_NATIVE_PANEL"))==1)self.manager.testPanelWindowLevel=NSFloatingWindowLevel+1;
    [self render];[self configureNativeInput];
}
// A menu-bar-only screen notice changes fit/fullscreen geometry, not the panel,
// output identity, world placement or saved camera. Dock notices compare equal.
- (void)refreshOutputUsableAreas {
    if(self.cleaning||!self.views.count)return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*contexts=DWTyped(DWTyped(snapshot[@"navigation"],NSDictionary.class)[@"contexts"],NSDictionary.class);BOOL changed=NO;
    for(NSDictionary *output in snapshot[@"outputs"]){NSNumber *identifier=DWTyped(output[@"id"],NSNumber.class);if(!identifier)continue;
        CGRect usable=outputUsableRect(DWRectFromJSON(output[@"screen_bounds"]));NSDictionary *local=DWRectJSON(usable);
        if([DWTyped(contexts[identifier.stringValue],NSDictionary.class)[@"usable_rect_local"]isEqual:local])continue;
        NSDictionary *reply=[self call:@{@"op":@"set_usable_area",@"output":identifier,@"usable_rect_local":local}];if(reply&&!reply[@"error"]){[self consumeSize:reply];changed=YES;}
    }
    if(changed)[self render];
}
- (void)screensChanged:(NSNotification *)notification {
    // The desktop is rebuilt from no panel as well: its displays may all have gone for a moment (asleep, unplugged), and it is there again when one is.
    // Never while it is being closed: -cleanup handles events while it waits, and a display change then must not reopen what it is closing.
    (void)notification;if(self.cleaning||self.sessionInactive||!(self.panels.count||self.desktopUp))return;
    if([self.panelScreens isEqual:physicalScreens()]){[self refreshOutputUsableAreas];[self refreshMacWallpapers];return;}
    [self cancelCapturedInputForWindow:nil];
    // Observations and physical mouse pairs belong to the old display basis.
    // A fresh read still updates native bounds and size after the rebuild; it
    // must not adopt an old pair's screen displacement into the world. Keep
    // the native pair withheld until its real buttons and geometry settle.
    [self.windowObserver cancel];self.windowObserver=nil;self.windowObservationAgain=NO;
    for(LiveSource *source in self.sources.allValues){
        NSMutableDictionary *held=source.nativeMouseOwnership;
        if(held){held[@"topology_changed"]=@YES;[held removeObjectForKey:@"stable_since"];}
        source.observationToken=++self.observationEpoch;[source invalidateNativeButtons];
    }
    self.nativeViewSnapshot=nil;
    // A Metal offer driver retains a specific output layer; a screen driver
    // retains its display. Both must end before those panels are replaced.
    [self.frameDriver invalidate];self.frameDriver=nil;
    // The session tap owns physical button pairs, not output layers. Retain
    // it so a secondary down cannot start a new gesture during an old native
    // drag, and captured tails cannot reach an app without their down.
    [self cancelNativeInput];[self cancelGestures];[self stopNavigation];
    // A pan waiting to launch belongs to an output about to be removed, and so do a hover waiting to be sent and a policy press.
    [self.panLaunch cancel];self.pointerOutputs=nil;self.pointerWanted=NO;
    for(DesktopView *view in self.views)[view.hover stop];
    for(DesktopView *view in self.views){[view releasePressed];for(NSNumber *output in view.outputs){NSDictionary *reply=[self call:@{@"op":@"remove_output",@"output":output}];[self.resize consume:reply];}}
    for(NSPanel *panel in self.panels){[panel orderOut:nil];[panel close];}
    [self.panels removeAllObjects];[self.views removeAllObjects];
    // The outputs' compositor layers went with the panels; the rebuilt ones get new layers.
    [self.compositor reset];
    [self stopKeys];
    [self openPanels];[self saveScene];
}
@end
