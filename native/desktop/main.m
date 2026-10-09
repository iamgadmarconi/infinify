// SPDX-License-Identifier: GPL-3.0-or-later
// The capture/router implementation is shared verbatim with our validated probe.
// Its private API provenance remains in native/captured-windows/captured.m.
#define main captured_probe_main
#include "../captured-windows/captured.m"
#undef main
#import <Carbon/Carbon.h>
#include "driftwm_desktop.h"
#import "focus-driver.h"

static NSDictionary *pointJSON(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
static NSDictionary *rectJSON(CGRect r) { return @{@"origin":pointJSON(r.origin),@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}}; }
static CGRect jsonRect(NSDictionary *r) { return CGRectMake([r[@"origin"][@"x"] doubleValue],[r[@"origin"][@"y"] doubleValue],[r[@"size"][@"width"] doubleValue],[r[@"size"][@"height"] doubleValue]); }
static CGPoint jsonPoint(NSDictionary *p) { return CGPointMake([p[@"x"] doubleValue],[p[@"y"] doubleValue]); }
static CGFloat screenTop(void) { return NSMaxY(NSScreen.screens.firstObject.frame); }
static CGRect topRect(NSRect r) { return CGRectMake(r.origin.x,screenTop()-NSMaxY(r),r.size.width,r.size.height); }
@class Desktop, DesktopView;
@interface LiveSource : NSObject <SCStreamOutput,SCStreamDelegate>
@property Router *router;
@property NSDictionary *identity;
@property NSNumber *logical;
@property SCStream *stream;
@property NSMutableArray<AVSampleBufferDisplayLayer *> *surfaces;
@property NSUInteger frames;
@property CGSize buffer;
@property NSString *error;
@property BOOL detached;
@property BOOL streamStopped;
@end
@implementation LiveSource
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { (void)stream; self.error=error.localizedDescription; }
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)stream;
    if(self.detached||type!=SCStreamOutputTypeScreen||!CMSampleBufferIsValid(sample)||!CMSampleBufferGetImageBuffer(sample))return;
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(a&&CFArrayGetCount(a)){NSDictionary *info=(__bridge NSDictionary *)CFArrayGetValueAtIndex(a,0);if([info[SCStreamFrameInfoStatus] integerValue]!=SCFrameStatusComplete)return;}
    CVImageBufferRef buffer=CMSampleBufferGetImageBuffer(sample); self.buffer=CGSizeMake(CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer));
    CMSampleBufferRef copy=NULL;if(CMSampleBufferCreateCopy(kCFAllocatorDefault,sample,&copy)!=noErr)return;
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(copy,YES);
    if(attachments&&CFArrayGetCount(attachments))CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments,0),kCMSampleAttachmentKey_DisplayImmediately,kCFBooleanTrue);
    for(AVSampleBufferDisplayLayer *surface in self.surfaces){if(surface.sampleBufferRenderer.status==AVQueuedSampleBufferRenderingStatusFailed)[surface.sampleBufferRenderer flush];if(surface.sampleBufferRenderer.readyForMoreMediaData)[surface.sampleBufferRenderer enqueueSampleBuffer:copy];}
    self.frames++;CFRelease(copy);
}
- (void)dealloc { if(_router.eventSource)CFRelease(_router.eventSource); }
@end
@interface DesktopView : FlippedView
@property (weak) Desktop *desktop;
@property NSMutableArray<NSNumber *> *outputs;
@property NSMutableDictionary<NSString *,CALayer *> *tiles;
@property NSMutableDictionary<NSString *,AVSampleBufferDisplayLayer *> *surfaces;
@property NSTextField *status;
@property CGRect globalBounds;
@property CGPoint startPoint;
@property CGPoint lastPoint;
@property NSNumber *dragOutput;
@property LiveSource *pressedSource;
@property CGPoint pressedLocal;
@property NSInteger gesture; // 1 pan, 2 logical world drag, 3 native pointer
- (void)render:(NSDictionary *)snapshot;
- (NSNumber *)outputAt:(CGPoint)p;
- (BOOL)forward:(CGEventRef)event at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate;
@end
@interface Desktop : NSObject <NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate>
@property DriftDesktop *controller;
@property BOOL experimentalNavigation;
@property DWNavigationCoordinator *navigation;
@property NSTimer *frameTimer;
@property CFTimeInterval lastObservation;
@property DWNavigationInput *navigationInput;
@property CFMachPortRef navigationTap;
@property CFRunLoopSourceRef navigationTapSource;
@property EventHotKeyRef nextHotkey, previousHotkey;
@property EventHandlerRef navigationHandler;
- (void)configureNavigation;
- (void)stopNavigation;
- (void)navigateButton:(NSButton *)sender;
- (void)cycleNavigation:(BOOL)backward;
- (void)ensureFrames;

@property NSMutableArray<NSPanel *> *panels;
@property NSMutableArray<DesktopView *> *views;
@property NSMutableDictionary<NSNumber *,LiveSource *> *sources;
@property NSMutableArray<NSDictionary *> *choices;
@property NSMutableArray<LiveSource *> *pendingStops;
@property NSArray<SCWindow *> *shareable;
@property NSWindow *chooser;
@property NSTableView *table;
@property NSTextField *chooserStatus;
@property NSPopUpButton *rebind;
@property NSString *statePath;
@property NSString *startupError;
@property NSString *statusText;
@property BOOL demo;
@property BOOL probe;
@property BOOL probeHumanInput;
@property BOOL interruptProbe;
@property BOOL probeDrivingGesture;
@property pid_t fixturePID;
@property BOOL cleaning;
@property NSRunningApplication *previousFocus;
@property NSDate *previousFocusBirth;
@property EventHotKeyRef exitHotkey;
@property EventHandlerRef hotkeyHandler;
- (NSDictionary *)call:(NSDictionary *)command;
- (void)render;
- (void)showChooser:(id)sender;
- (void)quit:(id)sender;
- (void)attachChoice:(id)sender;
- (BOOL)attach:(SCWindow *)window logical:(NSNumber *)logical world:(NSDictionary *)world;
- (void)poll;
- (void)saveScene;
- (BOOL)loadScene:(NSString *)path;
- (void)detach:(LiveSource *)source;
- (void)cleanup;
@end
@implementation DesktopView
- (BOOL)acceptsFirstResponder { return NO; }
- (CGPoint)screenPoint:(NSEvent *)e { CGPoint p=[self convertPoint:e.locationInWindow fromView:nil]; return CGPointMake(p.x+self.globalBounds.origin.x,p.y+self.globalBounds.origin.y); }
- (NSNumber *)outputAt:(CGPoint)p {
    for(NSDictionary *o in [self.desktop call:@{@"op":@"snapshot"}][@"outputs"])if([self.outputs containsObject:o[@"id"]]&&CGRectContainsPoint(jsonRect(o[@"screen_bounds"]),p))return o[@"id"];
    return nil;
}
- (void)render:(NSDictionary *)snapshot {
    NSMutableSet *keys=[NSMutableSet set]; [CATransaction begin];[CATransaction setDisableActions:YES];
    for(NSDictionary *p in snapshot[@"placements"]){
        if(![self.outputs containsObject:p[@"output"]])continue;
        NSString *key=[NSString stringWithFormat:@"%@:%@",p[@"window"],p[@"output"]];[keys addObject:key];
        CALayer *tile=self.tiles[key];if(!tile){tile=[CALayer layer];tile.masksToBounds=YES;tile.backgroundColor=[NSColor colorWithWhite:.16 alpha:1].CGColor;[self.layer insertSublayer:tile atIndex:0];self.tiles[key]=tile;}
        CGRect full=jsonRect(p[@"screen_rect"]),clip=jsonRect(p[@"clip_rect"]);tile.frame=CGRectOffset(clip,-self.globalBounds.origin.x,-self.globalBounds.origin.y);
        LiveSource *source=self.desktop.sources[p[@"window"]];
        AVSampleBufferDisplayLayer *surface=self.surfaces[key];
        if(source&&!source.detached){
            if(!surface){for(CALayer *child in tile.sublayers.copy)[child removeFromSuperlayer];surface=[AVSampleBufferDisplayLayer layer];surface.videoGravity=AVLayerVideoGravityResize;[tile addSublayer:surface];self.surfaces[key]=surface;[source.surfaces addObject:surface];}
            surface.frame=CGRectMake(full.origin.x-clip.origin.x,full.origin.y-clip.origin.y,full.size.width,full.size.height);
        }else{
            if(surface){[surface.sampleBufferRenderer flush];[surface removeFromSuperlayer];[self.surfaces removeObjectForKey:key];}
            if(!tile.sublayers.count){CATextLayer *text=[CATextLayer layer];text.string=[NSString stringWithFormat:@"Detached window %@\nChoose a source to rebind\n⌃⌥ click to dismiss",p[@"window"]];text.fontSize=17;text.foregroundColor=NSColor.whiteColor.CGColor;text.wrapped=YES;text.frame=CGRectMake(12,12,MAX(40,clip.size.width-24),100);text.contentsScale=NSScreen.mainScreen.backingScaleFactor;[tile addSublayer:text];}
        }
        // Placement order is the controller's bottom-to-top world z order.
        [tile removeFromSuperlayer];[self.layer insertSublayer:tile atIndex:(unsigned)keys.count-1];
    }
    for(NSString *key in self.tiles.allKeys)if(![keys containsObject:key]){
        AVSampleBufferDisplayLayer *surface=self.surfaces[key];for(LiveSource *source in self.desktop.sources.allValues)[source.surfaces removeObject:surface];
        [self.tiles[key] removeFromSuperlayer];[self.tiles removeObjectForKey:key];[self.surfaces removeObjectForKey:key];
    }
    [CATransaction commit];self.status.stringValue=self.desktop.statusText?:@"";
}
- (NSDictionary *)hit:(CGPoint)p output:(NSNumber *)output {
    // Controller input intentionally rejects placeholders. Find their geometry only
    // for the explicit dismiss action; this result never authorizes native delivery.
    NSDictionary *snapshot=[self.desktop call:@{@"op":@"snapshot"}];
    for(NSDictionary *placement in [snapshot[@"placements"] reverseObjectEnumerator])if([placement[@"output"]isEqual:output]&&CGRectContainsPoint(jsonRect(placement[@"clip_rect"]),p)){if(!self.desktop.sources[placement[@"window"]])return @{@"window":placement[@"window"],@"placeholder":@YES};break;}
    return [self.desktop call:@{@"op":@"hit",@"output":output,@"screen":pointJSON(p)}][@"hit"];
}
- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate {
    if(activate)[self.desktop.navigation invalidate];
    if(!e||!output)return NO;
    if(!AXIsProcessTrusted()){self.desktop.statusText=@"Input requires Accessibility access. Enable it in System Settings, then reopen.";return NO;}
    NSDictionary *hit=[self hit:p output:output];if(![hit isKindOfClass:NSDictionary.class])return NO;
    LiveSource *source=self.desktop.sources[hit[@"window"]];if(!source||![source.router valid])return NO;
    // Unsupported cross-source pointer capture must never retarget a held drag.
    if(CGEventGetType(e)==kCGEventLeftMouseDragged&&source!=self.pressedSource)return NO;
    NSDictionary *validated=[self.desktop call:@{@"op":@"input",@"output":output,@"screen":pointJSON(p),@"identity":source.identity}][@"hit"];
    if(![validated isKindOfClass:NSDictionary.class]||![source.router valid])return NO;
    if(activate){
        NSRunningApplication *current=NSWorkspace.sharedWorkspace.frontmostApplication;
        if(current.processIdentifier!=source.router.pid){self.desktop.previousFocus=current;self.desktop.previousFocusBirth=current.launchDate;[[NSRunningApplication runningApplicationWithProcessIdentifier:source.router.pid] activateWithOptions:0];}
        [self.desktop call:@{@"op":@"focus",@"window":source.logical}];
    }
    CGPoint local=jsonPoint(validated[@"local"]);
    BOOL sent=[source.router post:e at:local];
    if(sent && CGEventGetType(e)==kCGEventLeftMouseDown){self.pressedSource=source;self.pressedLocal=local;}
    if(sent&&self.pressedSource==source)self.pressedLocal=local;
    return sent;
}
- (void)mouseDown:(NSEvent *)e {
    if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;}
    [self.desktop.navigation invalidate];
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.startPoint=self.lastPoint=p;self.dragOutput=output;
    NSDictionary *hit=[self hit:p output:output];BOOL isHit=[hit isKindOfClass:NSDictionary.class];
    BOOL option=(e.modifierFlags&NSEventModifierFlagOption)!=0,control=(e.modifierFlags&NSEventModifierFlagControl)!=0;
    if(control&&option&&isHit&&!self.desktop.sources[hit[@"window"]]){[self.desktop call:@{@"op":@"forget",@"window":hit[@"window"]}];[self.desktop render];[self.desktop saveScene];return;}
    if(control&&option&&isHit){
        if([self.desktop call:@{@"op":@"begin_drag",@"window":hit[@"window"],@"output":output,@"group":(e.modifierFlags&NSEventModifierFlagShift)?@YES:@NO}])self.gesture=2;
    }else if(option||!isHit)self.gesture=1;
    else { self.gesture=3;CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output activate:YES];CFRelease(cg); }
    [self.desktop render];
}
- (void)mouseDragged:(NSEvent *)e {
    if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;}
    CGPoint p=[self screenPoint:e];
    if(self.gesture==1)[self.desktop call:@{@"op":@"pan",@"output":self.dragOutput,@"screen_delta":pointJSON(CGPointMake(self.lastPoint.x-p.x,self.lastPoint.y-p.y))}];
    else if(self.gesture==2)[self.desktop call:@{@"op":@"gesture_to",@"screen_delta":pointJSON(CGPointMake(p.x-self.startPoint.x,p.y-self.startPoint.y))}];
    else if(self.gesture==3){CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:self.dragOutput activate:NO];CFRelease(cg);}
    self.lastPoint=p;[self.desktop render];
}
- (void)releasePressed {
    if(self.pressedSource){
        Router *router=self.pressedSource.router;
        // A native title drag can move the real source before the polling tick.
        // Refresh only the already-pressed identity before releasing its button.
        NSDictionary *current=windowInfo(router.wid);
        if([birth(router.pid)isEqual:router.processBirth]&&[current[(id)kCGWindowOwnerPID]intValue]==router.pid&&current[(id)kCGWindowBounds])router.bounds=current[(id)kCGWindowBounds];
        sig_atomic_t wasStopped=stopped;stopped=0;CGEventRef up=CGEventCreateMouseEvent(self.pressedSource.router.eventSource,kCGEventLeftMouseUp,CGPointZero,kCGMouseButtonLeft);[self.pressedSource.router post:up at:self.pressedLocal];CFRelease(up);if(wasStopped)stopped=wasStopped;self.pressedSource=nil;}
}
- (void)mouseUp:(NSEvent *)e { if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;} (void)e;[self releasePressed];if(self.gesture==2)[self.desktop call:@{@"op":@"end_gesture"}];self.gesture=0;[self.desktop saveScene]; }
- (void)zoom:(double)factor at:(CGPoint)p output:(NSNumber *)output {
    for(NSDictionary *o in [self.desktop call:@{@"op":@"snapshot"}][@"outputs"])if([o[@"id"] isEqual:output]){[self.desktop call:@{@"op":@"zoom",@"output":output,@"zoom":@(MAX(.001,MIN(1,[o[@"zoom"] doubleValue]*factor))),@"anchor":pointJSON(p)}];break;}
    [self.desktop render];[self.desktop saveScene];
}
- (void)scrollWheel:(NSEvent *)e {
    if(self.desktop.probe){self.desktop.probeHumanInput=YES;return;}
    [self.desktop.navigation invalidate];
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    if(e.modifierFlags&NSEventModifierFlagCommand)[self zoom:exp(e.scrollingDeltaY*.01) at:p output:output];
    else if((e.modifierFlags&NSEventModifierFlagOption)||![[self hit:p output:output]isKindOfClass:NSDictionary.class]){[self.desktop call:@{@"op":@"pan",@"output":output,@"screen_delta":pointJSON(CGPointMake(-e.scrollingDeltaX,-e.scrollingDeltaY))}];[self.desktop render];[self.desktop saveScene];}
    else {CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output activate:NO];CFRelease(cg);}
}
- (void)magnifyWithEvent:(NSEvent *)e { [self.desktop.navigation invalidate]; if(self.desktop.probe){self.desktop.probeHumanInput=YES;return;} CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(output)[self zoom:1+e.magnification at:p output:output]; }
@end
static CGEventRef navigationInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;Desktop *desktop=(__bridge Desktop *)context;
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){desktop.navigation.focusAllowed=NO;[desktop.navigationInput cancel];[desktop.navigation invalidate];return event;}
    CGEventFlags flags=CGEventGetFlags(event);
    NSUInteger modifiers=((flags&kCGEventFlagMaskAlternate)?1:0)|((flags&kCGEventFlagMaskShift)?2:0)|((flags&(kCGEventFlagMaskCommand|kCGEventFlagMaskControl|kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskAlphaShift))?4:0);
    if(type==kCGEventFlagsChanged){NSInteger action=[desktop.navigationInput flagsChanged:modifiers];if(action==1)[desktop.navigation invalidate];else if(action==2)[desktop.navigation releaseCycle];return event;}
    if(CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==48){
        if(type==kCGEventKeyDown&&[desktop.navigationInput tabDown:modifiers])return event;
        if(type==kCGEventKeyUp&&[desktop.navigationInput tabUp])return event;
    }
    [desktop.navigationInput cancel];[desktop.navigation invalidate];return event;
}
static OSStatus navigationKey(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(key.signature!='NavI'||(key.id!=1&&key.id!=2))return eventNotHandledErr;
    [(__bridge Desktop *)context cycleNavigation:key.id==2];return noErr;
}
static OSStatus exitKey(EventHandlerCallRef next,EventRef event,void *context) { (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);if(key.signature!='Infi'||key.id!=1)return eventNotHandledErr;[(__bridge Desktop *)context quit:nil];return noErr; }
@implementation Desktop
- (instancetype)init {
    if((self=[super init])){_controller=driftwm_desktop_create();_panels=[NSMutableArray array];_views=[NSMutableArray array];_sources=[NSMutableDictionary dictionary];_choices=[NSMutableArray array];_pendingStops=[NSMutableArray array];_statusText=@"Option-drag: pan · ⌘-wheel/pinch: zoom · ⌃⌥-drag: move · +Shift: cluster · ⌃⌥Esc: exit";}
    return self;
}
- (void)configureNavigation {
    if(!self.experimentalNavigation||self.navigation)return;
    __weak Desktop *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.navigation",DISPATCH_QUEUE_SERIAL);
    self.navigation=[[DWNavigationCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak call:c];} driver:[DWNativeFocusDriver new] clock:^uint64_t{return (uint64_t)(CACurrentMediaTime()*1e9);} worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.navigation.enabled=YES;self.navigationInput=[DWNavigationInput new];
    self.navigation.changed=^{[weak render];[weak ensureFrames];};
    self.navigation.settled=^{[weak saveScene];};
    CGEventMask mask=CGEventMaskBit(kCGEventFlagsChanged)|CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp)|CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventScrollWheel)|CGEventMaskBit(kCGEventMouseMoved)|CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventRightMouseDragged)|CGEventMaskBit(kCGEventOtherMouseDragged)|CGEventMaskBit(kCGEventLeftMouseUp)|CGEventMaskBit(kCGEventRightMouseUp)|CGEventMaskBit(kCGEventOtherMouseUp);
    self.navigationTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,navigationInput,(__bridge void *)self);
    if(self.navigationTap){self.navigationTapSource=CFMachPortCreateRunLoopSource(NULL,self.navigationTap,0);if(self.navigationTapSource){CFRunLoopAddSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);self.navigation.focusAllowed=YES;}}
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};EventHotKeyID next={'NavI',1},previous={'NavI',2};
    if(!self.navigation.focusAllowed||InstallApplicationEventHandler(navigationKey,1,&type,(__bridge void *)self,&_navigationHandler)!=noErr||RegisterEventHotKey(48,optionKey,next,GetApplicationEventTarget(),0,&_nextHotkey)!=noErr||RegisterEventHotKey(48,optionKey|shiftKey,previous,GetApplicationEventTarget(),0,&_previousHotkey)!=noErr){
        if(self.nextHotkey){UnregisterEventHotKey(self.nextHotkey);self.nextHotkey=NULL;}if(self.previousHotkey){UnregisterEventHotKey(self.previousHotkey);self.previousHotkey=NULL;}
        self.statusText=@"Experimental held cycling unavailable; use navigation buttons. Native focus requires a working input observer.";
    }
    [self.navigation frame];
}
- (void)stopNavigation {
    [self.navigationInput cancel];self.navigationInput=nil;[self.navigation shutdown];self.navigation=nil;[self.frameTimer invalidate];self.frameTimer=nil;
    if(self.navigationTapSource){CFRunLoopRemoveSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);CFRelease(self.navigationTapSource);self.navigationTapSource=NULL;}
    if(self.navigationTap){CFMachPortInvalidate(self.navigationTap);CFRelease(self.navigationTap);self.navigationTap=NULL;}
    if(self.nextHotkey){UnregisterEventHotKey(self.nextHotkey);self.nextHotkey=NULL;}if(self.previousHotkey){UnregisterEventHotKey(self.previousHotkey);self.previousHotkey=NULL;}if(self.navigationHandler){RemoveEventHandler(self.navigationHandler);self.navigationHandler=NULL;}
}
- (void)ensureFrames {
    if(self.frameTimer||!self.navigation)return;
    if(![[self call:@{@"op":@"snapshot"}][@"navigation"][@"flights"]count])return;
    __weak Desktop *weak=self;self.frameTimer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer){Desktop *desktop=weak;if(!desktop||![desktop.navigation frame]){[timer invalidate];desktop.frameTimer=nil;}}];
    [[NSRunLoop mainRunLoop]addTimer:self.frameTimer forMode:NSRunLoopCommonModes];
}
- (NSNumber *)navigationOutput:(NSView *)view {
    DesktopView *canvas=[view isKindOfClass:DesktopView.class]?(DesktopView *)view:nil;
    if(canvas.outputs.count==1)return canvas.outputs[0];
    // A multi-output demo toolbar has no unique output; use the pointer only.
    CGEventRef event=CGEventCreate(NULL);CGPoint point=CGEventGetLocation(event);CFRelease(event);
    for(DesktopView *v in self.views){NSNumber *output=[v outputAt:point];if(output)return output;}return nil;
}
- (void)navigateButton:(NSButton *)sender {
    NSNumber *output=[self navigationOutput:sender.superview];if(!output)return;
    if(sender.tag==0){id window=[self call:@{@"op":@"snapshot"}][@"focused"];if([window isKindOfClass:NSNumber.class])[self.navigation navigate:@{@"op":@"navigate_window",@"window":window,@"output":output,@"zoom_policy":@"reset"}];}
    else [self.navigation navigate:@{@"op":@"cycle_navigate",@"output":output,@"backward":@(sender.tag==1),@"held":@NO}];
}
- (void)cycleNavigation:(BOOL)backward {
    if(!self.navigation.focusAllowed||!self.nextHotkey||!self.previousHotkey)return;
    NSNumber *held=[self.navigationInput takeShortcut:backward];if(!held)return;
    NSNumber *output=[self navigationOutput:nil];if(output)[self.navigation navigate:@{@"op":@"cycle_navigate",@"output":output,@"backward":@(backward),@"held":held}];
}
- (NSDictionary *)call:(NSDictionary *)command {
    NSData *request=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command} options:0 error:nil];
    char *response=driftwm_desktop_request(self.controller,request.bytes,request.length);if(!response){self.statusText=@"Controller unavailable";return nil;}
    NSData *data=[NSData dataWithBytes:response length:strlen(response)];driftwm_desktop_response_free(response);
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![reply[@"ok"]boolValue]){self.statusText=reply[@"error"]?:@"Controller error";return nil;}return reply[@"data"];
}
- (BOOL)loadScene:(NSString *)path {
    [self.navigation invalidate];
    self.statePath=path;
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return YES;
    if([self call:@{@"op":@"load",@"path":path}])return YES;
    self.startupError=[NSString stringWithFormat:@"Saved scene could not be loaded: %@. Original file preserved. Quit and repair it, or restart with --state and a different path.",self.statusText];
    // Every save path, including quit and Return to desktop, is disabled.
    self.statePath=nil;return NO;
}
- (void)saveScene { if(self.statePath)[self call:@{@"op":@"save",@"path":self.statePath}]; }
- (void)render { NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];for(DesktopView *view in self.views)[view render:snapshot]; }
- (void)quit:(id)sender { (void)sender;[self stopNavigation];stopped=1; }
- (void)resizeUnavailable:(id)sender { if(self.probe&&sender){self.probeHumanInput=YES;return;} (void)sender;self.statusText=@"Native layout resize is unavailable. Resize the original app on the desktop, then return; capture reconciles without changing world geometry.";[self render]; }
- (void)returnDesktop:(id)sender { if(self.probe&&sender){self.probeHumanInput=YES;return;} (void)sender;[self cleanup];[self showChooser:nil]; }
- (DesktopView *)panel:(NSRect)frame outputRects:(NSArray *)rects identities:(NSArray *)identities {
    NSPanel *panel=[[CanvasPanel alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO;panel.level=NSFloatingWindowLevel;panel.animationBehavior=NSWindowAnimationBehaviorNone;panel.collectionBehavior=NSWindowCollectionBehaviorMoveToActiveSpace|NSWindowCollectionBehaviorFullScreenAuxiliary;
    DesktopView *view=[[DesktopView alloc]initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];view.desktop=self;view.globalBounds=topRect(frame);view.outputs=[NSMutableArray array];view.tiles=[NSMutableDictionary dictionary];view.surfaces=[NSMutableDictionary dictionary];view.wantsLayer=YES;view.layer.backgroundColor=[NSColor colorWithSRGBRed:.045 green:.065 blue:.10 alpha:1].CGColor;panel.contentView=view;
    for(NSUInteger i=0;i<rects.count;i++){NSNumber *output=[self call:@{@"op":@"register_output",@"stable_id":identities[i],@"screen_bounds":rects[i]}][@"output"];if(output)[view.outputs addObject:output];}
    NSArray *names=@[@"Choose windows",@"Return to desktop",@"Resize status",@"Quit ⌃⌥Esc"];
    SEL actions[]={@selector(showChooser:),@selector(returnDesktop:),@selector(resizeUnavailable:),@selector(quit:)};
    CGFloat x=12;for(NSUInteger i=0;i<names.count;i++){NSButton *b=[NSButton buttonWithTitle:names[i] target:self action:actions[i]];b.frame=NSMakeRect(x,8,i==1?155:135,26);[view addSubview:b];x+=i==1?163:143;}
    if(self.experimentalNavigation){NSArray *titles=@[@"Center selected",@"Previous",@"Next"];for(NSUInteger i=0;i<titles.count;i++){NSButton *button=[NSButton buttonWithTitle:titles[i] target:self action:@selector(navigateButton:)];button.tag=i;button.frame=NSMakeRect(x,8,i==0?125:80,26);[view addSubview:button];x+=i==0?130:85;}}
    view.status=label(self.statusText,NSMakeRect(15,37,MAX(100,frame.size.width-30),22));view.status.textColor=NSColor.lightGrayColor;view.status.font=[NSFont systemFontOfSize:11];[view addSubview:view.status];
    [self.panels addObject:panel];[self.views addObject:view];[panel orderFrontRegardless];return view;
}
- (void)openPanels {
    if(self.panels.count)return;self.cleaning=NO;
    if(self.demo){NSRect frame=NSMakeRect(100,120,1040,600);CGRect global=topRect(frame);NSMutableArray *rects=[NSMutableArray array];for(int i=0;i<2;i++)[rects addObject:rectJSON(CGRectOffset(ports[i],global.origin.x,global.origin.y))];[self panel:frame outputRects:rects identities:@[@"fixture-view-a",@"fixture-view-b"]];}
    else for(NSScreen *screen in NSScreen.screens){NSNumber *display=screen.deviceDescription[@"NSScreenNumber"];CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display.unsignedIntValue);NSString *name=uuid?CFBridgingRelease(CFUUIDCreateString(NULL,uuid)):nil;if(uuid)CFRelease(uuid);if(!name)continue;CGRect output=topRect(screen.frame);output.origin.y+=64;output.size.height-=64;[self panel:screen.frame outputRects:@[rectJSON(output)] identities:@[name]];}
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};OSStatus handler=InstallApplicationEventHandler(exitKey,1,&type,(__bridge void *)self,&_hotkeyHandler);EventHotKeyID key={'Infi',1};
    if(handler!=noErr||RegisterEventHotKey(53,controlKey|optionKey,key,GetApplicationEventTarget(),0,&_exitHotkey)!=noErr)self.statusText=@"Exit shortcut unavailable; use the visible Quit button.";
    [self configureNavigation];[self render];
}
- (void)refreshChoices:(id)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;[self.choices removeAllObjects];[self.table reloadData];
    if(self.startupError){self.chooserStatus.stringValue=self.startupError;return;}
    if(!CGPreflightScreenCaptureAccess()){self.chooserStatus.stringValue=@"Screen Recording access is required. Enable Infinify in System Settings → Privacy & Security, then reopen. No permission request was made.";return;}
    self.chooserStatus.stringValue=@"Reading available local windows…";
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){dispatch_async(dispatch_get_main_queue(),^{
        self.shareable=content.windows;[self.choices removeAllObjects];
        for(SCWindow *w in content.windows){NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.owningApplication.processID];if(self.demo&&w.owningApplication.processID!=self.fixturePID)continue;if(w.windowLayer!=0||w.owningApplication.processID==getpid()||w.frame.size.width<40||w.frame.size.height<40||(!self.demo&&app.activationPolicy!=NSApplicationActivationPolicyRegular))continue;
            [self.choices addObject:@{@"window":w,@"label":[NSString stringWithFormat:@"%@ — %@",w.owningApplication.applicationName,w.title.length?w.title:@"Untitled window"]}];}
        [self.table reloadData];self.chooserStatus.stringValue=error?error.localizedDescription:AXIsProcessTrusted()?@"Select a window explicitly. Native keyboard and IME stay with the selected application.":@"Viewing is available. Native input requires Accessibility access in System Settings.";
    });}];
}
- (void)showChooser:(id)sender {
    [self.navigation invalidate];
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;
    if(!self.chooser){self.chooser=[[FixtureWindow alloc]initWithContentRect:NSMakeRect(200,180,720,470) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];self.chooser.title=@"Infinify — choose native windows";self.chooser.level=NSFloatingWindowLevel+1;self.chooser.releasedWhenClosed=NO;self.chooser.delegate=self;
        NSView *v=self.chooser.contentView;NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(18,130,684,315)];scroll.hasVerticalScroller=YES;
        self.table=[[NSTableView alloc]initWithFrame:scroll.bounds];NSTableColumn *column=[[NSTableColumn alloc]initWithIdentifier:@"Window"];column.title=@"Application — native window";column.width=675;[self.table addTableColumn:column];self.table.dataSource=self;self.table.delegate=self;scroll.documentView=self.table;[v addSubview:scroll];
        self.chooserStatus=label(@"",NSMakeRect(18,55,684,60));self.chooserStatus.maximumNumberOfLines=3;[v addSubview:self.chooserStatus];
        self.rebind=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(18,15,265,30) pullsDown:NO];[v addSubview:self.rebind];
        NSButton *attach=[NSButton buttonWithTitle:@"Add selected window" target:self action:@selector(attachChoice:)];attach.frame=NSMakeRect(295,15,180,30);[v addSubview:attach];
        NSButton *refresh=[NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshChoices:)];refresh.frame=NSMakeRect(485,15,95,30);[v addSubview:refresh];
        NSButton *quit=[NSButton buttonWithTitle:@"Quit" target:self action:@selector(quit:)];quit.frame=NSMakeRect(590,15,95,30);[v addSubview:quit];}
    [self.rebind removeAllItems];[self.rebind addItemWithTitle:@"Create a new world window"];
    for(NSDictionary *w in [self call:@{@"op":@"snapshot"}][@"windows"])if(!self.sources[w[@"window"]]){[self.rebind addItemWithTitle:[NSString stringWithFormat:@"Rebind %@: %@",w[@"window"],w[@"metadata"][@"title"]?:@"window"]];self.rebind.lastItem.representedObject=w[@"window"];}
    [self.chooser makeKeyAndOrderFront:nil];[NSApp activate];[self refreshChoices:nil];
}
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window;if(!self.panels.count)stopped=1;return YES; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView;return self.choices.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {(void)tableView;(void)column;return self.choices[row][@"label"];}
- (void)attachChoice:(id)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;NSInteger row=self.table.selectedRow;if(row<0||row>=(NSInteger)self.choices.count){self.chooserStatus.stringValue=@"Select a source window first.";return;}
    [self openPanels];NSNumber *logical=self.rebind.selectedItem.representedObject;
    if([self attach:self.choices[row][@"window"] logical:logical world:nil]){[self.chooser orderOut:nil];[self saveScene];[self render];}else self.chooserStatus.stringValue=self.statusText;
}
- (BOOL)attach:(SCWindow *)window logical:(NSNumber *)logical world:(NSDictionary *)world {
    [self.navigation invalidate];
    pid_t pid=window.owningApplication.processID;uint32_t wid=window.windowID;NSArray *processBirth=birth(pid);NSDictionary *info=windowInfo(wid);CGRect bounds=CGRectZero;
    if(!processBirth||[info[(id)kCGWindowOwnerPID]intValue]!=pid||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)){self.statusText=@"Source closed or identity changed; refresh the chooser.";return NO;}
    for(LiveSource *existing in self.sources.allValues)if(existing.router.pid==pid&&existing.router.wid==wid){self.statusText=@"This source is already attached; every display can view the same world window.";return NO;}
    LiveSource *source=[LiveSource new];source.router=[Router new];source.router.pid=pid;source.router.wid=wid;source.router.processBirth=processBirth;source.router.bounds=info[(id)kCGWindowBounds];source.router.deadline=NSDate.distantFuture;source.router.sent=[NSMutableArray array];source.router.tag=(int64_t)(arc4random_uniform(0x7fffff)+1)*100;source.router.eventSource=CGEventSourceCreate(kCGEventSourceStatePrivate);source.router.usePrivate=YES;
    BOOL privateAvailable=[source.router loadPrivate];source.identity=@{@"pid":@(pid),@"birth_sec":processBirth[0],@"birth_usec":processBirth[1],@"wid":@(wid)};
    source.buffer=CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2));source.surfaces=[NSMutableArray array];
    NSMutableDictionary *command=[@{@"op":@"attach",@"identity":source.identity,@"bundle_id":window.owningApplication.bundleIdentifier?:@"",@"title":window.title?:@"Untitled",@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)},@"source_rect":rectJSON(bounds)} mutableCopy];
    if(logical)command[@"logical_id"]=logical;else {if(!world){NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];NSDictionary *o=[snapshot[@"outputs"]firstObject];double zoom=[o[@"zoom"]doubleValue];CGPoint camera=jsonPoint(o[@"camera"]);world=rectJSON(CGRectMake(camera.x+30/MAX(.001,zoom),camera.y+30/MAX(.001,zoom),bounds.size.width,bounds.size.height));}command[@"world_rect"]=world;}
    source.logical=[self call:command][@"window"];if(!source.logical)return NO;self.sources[source.logical]=source;
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)source.buffer.width;config.height=(size_t)source.buffer.height;config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=CMTimeMake(1,30);config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;
    source.stream=[[SCStream alloc]initWithFilter:[[SCContentFilter alloc]initWithDesktopIndependentWindow:window] configuration:config delegate:source];NSError *error=nil;
    if(![source.stream addStreamOutput:source type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&error]){source.error=error.localizedDescription;[self detach:source];return NO;}
    [source.stream startCaptureWithCompletionHandler:^(NSError *e){if(e)dispatch_async(dispatch_get_main_queue(),^{source.error=e.localizedDescription;});}];
    if(!privateAvailable)self.statusText=@"Live view only: private per-window input is unavailable on this OS.";
    [self render];return YES;
}
- (void)detach:(LiveSource *)source {
    [self.navigation invalidate];
    if(source.detached)return;for(DesktopView *view in self.views)if(view.pressedSource==source)[view releasePressed];source.detached=YES;
    [self call:@{@"op":@"remove_source",@"window":source.logical,@"identity":source.identity,@"keep_placeholder":@YES}];
    [self.pendingStops addObject:source];[source.stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{source.streamStopped=YES;source.stream=nil;[self.pendingStops removeObject:source];});}];[source.surfaces removeAllObjects];[self.sources removeObjectForKey:source.logical];
}
- (void)screensChanged:(NSNotification *)notification {
    (void)notification;if(self.demo||!self.panels.count)return;[self stopNavigation];
    for(DesktopView *view in self.views){[view releasePressed];for(NSNumber *output in view.outputs)[self call:@{@"op":@"remove_output",@"output":output}];}
    for(NSPanel *panel in self.panels){[panel orderOut:nil];[panel close];}
    [self.panels removeAllObjects];[self.views removeAllObjects];for(LiveSource *source in self.sources.allValues)[source.surfaces removeAllObjects];
    if(self.exitHotkey){UnregisterEventHotKey(self.exitHotkey);self.exitHotkey=NULL;}if(self.hotkeyHandler){RemoveEventHandler(self.hotkeyHandler);self.hotkeyHandler=NULL;}
    [self openPanels];[self saveScene];
}
- (void)poll {
    if(self.cleaning)return;
    if(self.navigation&&!self.frameTimer)[self.navigation frame];
    if(self.navigation&&CACurrentMediaTime()-self.lastObservation>=.5){self.lastObservation=CACurrentMediaTime();[self.navigation observe];}
    for(LiveSource *source in self.sources.allValues){
        NSDictionary *w=windowInfo(source.router.wid);if(source.error||![birth(source.router.pid)isEqual:source.router.processBirth]||[w[(id)kCGWindowOwnerPID]intValue]!=source.router.pid){self.statusText=source.error?:@"A source closed. Its world placeholder is retained for explicit rebind.";[self detach:source];continue;}
        CGRect bounds=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&bounds))continue;
        if(![source.router.bounds isEqual:w[(id)kCGWindowBounds]]){
            CGRect old=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&old);source.router.bounds=w[(id)kCGWindowBounds];
            if(!CGSizeEqualToSize(old.size,bounds.size)){SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)ceil(bounds.size.width*2);config.height=(size_t)ceil(bounds.size.height*2);config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=CMTimeMake(1,30);config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;[source.stream updateConfiguration:config completionHandler:^(NSError *e){if(e)dispatch_async(dispatch_get_main_queue(),^{source.error=e.localizedDescription;});}];}
        }
        [self call:@{@"op":@"observe",@"window":source.logical,@"identity":source.identity,@"source_rect":rectJSON(bounds),@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)}}];
        // Event history is probe evidence, not an unbounded production log.
        if(!self.probe&&source.router.sent.count>128)[source.router.sent removeAllObjects];
    }
    if(!self.frameTimer)[self render];
}
- (void)cleanup {
    if(self.cleaning)return;self.cleaning=YES;[self stopNavigation];[self saveScene];
    for(DesktopView *view in self.views)[view releasePressed];
    NSArray *closing=self.sources.allValues;
    for(LiveSource *source in closing)[self detach:source];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while(deadline.timeIntervalSinceNow>0){BOOL done=self.pendingStops.count==0;if(done)break;pump(.01);}
    for(DesktopView *view in self.views)for(NSNumber *output in view.outputs)[self call:@{@"op":@"remove_output",@"output":output}];
    for(NSPanel *panel in self.panels){[panel orderOut:nil];[panel close];}[self.panels removeAllObjects];[self.views removeAllObjects];
    if(self.exitHotkey){UnregisterEventHotKey(self.exitHotkey);self.exitHotkey=NULL;}if(self.hotkeyHandler){RemoveEventHandler(self.hotkeyHandler);self.hotkeyHandler=NULL;}

}
- (void)dealloc { [self stopNavigation];if(_controller)driftwm_desktop_destroy(_controller); }
@end
static CGPoint projected(Desktop *desktop,NSNumber *window,NSNumber *output,CGPoint sourcePoint) {
    for(NSDictionary *p in [desktop call:@{@"op":@"snapshot"}][@"placements"])if([p[@"window"]isEqual:window]&&[p[@"output"]isEqual:output]){
        CGRect r=jsonRect(p[@"screen_rect"]),native=jsonRect(p[@"source"][@"observed_rect"]);return CGPointMake(r.origin.x+sourcePoint.x/native.size.width*r.size.width,r.origin.y+sourcePoint.y/native.size.height*r.size.height);
    }
    return CGPointMake(-1,-1);
}
static BOOL probeClick(DesktopView *view,NSNumber *output,CGPoint point) {
    CGEventRef down=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDown,CGPointZero,kCGMouseButtonLeft);CGEventSetIntegerValueField(down,kCGMouseEventClickState,1);
    BOOL sent=[view forward:down at:point output:output activate:!view.desktop.probe];CFRelease(down);pump(.08);[view releasePressed];pump(.2);return sent;
}
static BOOL fixtureUntouched(Desktop *desktop,NSString *directory,pid_t foreground,NSMutableDictionary *report) {
    if(stopped||desktop.probeHumanInput){report[@"human_interrupted"]=@YES;report[@"interruption_reason"]=stopped?@"signal_or_quit":@"physical_canvas_input";return NO;}
    NSDictionary *state=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
    if(!state||[state[@"untagged_events"]unsignedIntegerValue]){report[@"human_interrupted"]=@YES;report[@"interruption_reason"]=@"missing_telemetry_or_untagged_source_event";return NO;}
    if(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=foreground){report[@"foreground_interrupted"]=@YES;report[@"interruption_reason"]=@"foreground_changed";return NO;}
    return YES;
}
static int runDemo(Desktop *desktop,NSString *directory,BOOL probe) {
    NSMutableDictionary *report=[@{@"kind":@"Infinify packaged desktop fixture E2E",@"permission_requests":@0,@"global_input_posts":@0,@"native_moves":@0,@"native_resize":@"explicitly unsupported",@"screen_capture":@(CGPreflightScreenCaptureAccess()),@"accessibility":@(AXIsProcessTrusted())}mutableCopy];
    NSString *receipt=[directory stringByAppendingPathComponent:@"desktop-receipt.json"];
    if(!CGPreflightScreenCaptureAccess()||!AXIsProcessTrusted()){report[@"error"]=@"Existing Screen Recording and Accessibility grants required; no permission prompt requested.";save(report,receipt);return 2;}
    NSString *nonce=NSUUID.UUID.UUIDString;NSTask *child=[NSTask new];child.executableURL=NSBundle.mainBundle.executableURL;child.arguments=@[@"--source",directory,@"65",nonce];NSError *error=nil;
    NSRunningApplication *previous=NSWorkspace.sharedWorkspace.frontmostApplication;NSDate *previousBirth=previous.launchDate;CGPoint initialPointer=pointer();
    if(![child launchAndReturnError:&error]){report[@"error"]=error.localizedDescription;save(report,receipt);return 2;}
    NSDate *start=NSDate.date;NSDictionary *ready=nil;
    while(child.running&&!stopped&&-start.timeIntervalSinceNow<4){ready=readJSON([directory stringByAppendingPathComponent:@"source.json"]);if([ready[@"nonce"]isEqual:nonce]&&[ready[@"pid"]intValue]==child.processIdentifier&&[ready[@"window"]unsignedIntValue]&&[ready[@"bounds"]count])break;pump(.02);}
    SCWindow *window=findWindow(child.processIdentifier,[ready[@"window"]unsignedIntValue]);BOOL enrolled=window&&[ready[@"birth"]isEqual:birth(child.processIdentifier)];
    report[@"enrolled"]=@(enrolled);report[@"source_pid"]=@(child.processIdentifier);report[@"source_initial"]=ready?:@{};
    if(enrolled){
        desktop.fixturePID=child.processIdentifier;
        [desktop showChooser:nil];NSDate *chooserDeadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while(!desktop.choices.count&&!stopped&&chooserDeadline.timeIntervalSinceNow>0)pump(.02);
        NSInteger row=-1;for(NSUInteger i=0;i<desktop.choices.count;i++){SCWindow *candidate=desktop.choices[i][@"window"];if(candidate.windowID==window.windowID&&candidate.owningApplication.processID==child.processIdentifier){row=(NSInteger)i;break;}}
        if(row>=0){[desktop.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row]byExtendingSelection:NO];[desktop attachChoice:nil];}
        report[@"chooser_selection_attached"]=@(row>=0&&desktop.sources.count==1&&!desktop.chooser.visible);
        DesktopView *view=desktop.views.firstObject;LiveSource *source=desktop.sources.allValues.firstObject;
        for(NSUInteger i=0;i<view.outputs.count;i++){NSNumber *output=view.outputs[i];CGRect bounds=CGRectZero;for(NSDictionary *o in [desktop call:@{@"op":@"snapshot"}][@"outputs"])if([o[@"id"]isEqual:output])bounds=jsonRect(o[@"screen_bounds"]);[desktop call:@{@"op":@"zoom",@"output":output,@"zoom":i?@.72:@.80,@"anchor":pointJSON(bounds.origin)}];}
        [desktop render];pump(.8);[desktop poll];
        if(probe&&source&&view.outputs.count==2){
            if(desktop.interruptProbe){
                // Deterministic safety regression: untagged input goes only to
                // this enrolled disposable fixture, never the global session.
                int64_t tag=source.router.tag;source.router.tag=0;[source.router click:CGPointMake(120,120)];source.router.tag=tag;pump(.2);
                report[@"self_test_untagged_injection"]=@YES;
            }
            pid_t captureForeground=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;report[@"capture_foreground_pid"]=@(captureForeground);
            SCWindow *host=findWindow(getpid(),(uint32_t)desktop.panels.firstObject.windowNumber);SCContentFilter *filter=host?[[SCContentFilter alloc]initWithDesktopIndependentWindow:host]:nil;
            NSMutableArray *frames=[NSMutableArray array];
            for(int i=0;i<6&&!stopped;i++){
                if(!fixtureUntouched(desktop,directory,captureForeground,report))break;
                pump(.72);[desktop poll];if(!fixtureUntouched(desktop,directory,captureForeground,report))break;
                if(filter)[frames addObject:captureHost(filter,[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"desktop-frame-%d.png",i]])];
                if(!fixtureUntouched(desktop,directory,captureForeground,report))break;
            }
            report[@"frames"]=frames;report[@"separate_live_layers"]=@(source.surfaces.count==2);
            NSDictionary *before=[desktop call:@{@"op":@"snapshot"}];NSNumber *first=view.outputs.firstObject;
            CGPoint anchor=projected(desktop,source.logical,first,CGPointMake(120,120));NSDictionary *hitBefore=[desktop call:@{@"op":@"hit",@"output":first,@"screen":pointJSON(anchor)}][@"hit"];
            [view zoom:.8 at:anchor output:first];NSDictionary *hitAfter=[desktop call:@{@"op":@"hit",@"output":first,@"screen":pointJSON(anchor)}][@"hit"];
            [desktop call:@{@"op":@"pan",@"output":first,@"screen_delta":pointJSON(CGPointMake(14,9))}];[desktop render];
            NSDictionary *after=[desktop call:@{@"op":@"snapshot"}];report[@"world_fixed_during_camera_changes"]=@([before[@"windows"] isEqual:after[@"windows"]]);
            CGPoint ba=jsonPoint(hitBefore[@"local"]),aa=jsonPoint(hitAfter[@"local"]);report[@"pointer_anchor_stable"]=@(hypot(ba.x-aa.x,ba.y-aa.y)<.00001);report[@"independent_second_camera"]=@([before[@"outputs"][1]isEqual:after[@"outputs"][1]]);
            report[@"snapshot_before"]=before;report[@"snapshot_after"]=after;
            CGPoint dragStart=projected(desktop,source.logical,first,CGPointMake(80,80));
            CGPoint localStart=CGPointMake(dragStart.x-view.globalBounds.origin.x,view.frame.size.height-(dragStart.y-view.globalBounds.origin.y));
            NSEventModifierFlags flags=NSEventModifierFlagControl|NSEventModifierFlagOption;
            NSEvent *down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:localStart modifierFlags:flags timestamp:0 windowNumber:view.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
            NSEvent *drag=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged location:NSMakePoint(localStart.x+20,localStart.y-15) modifierFlags:flags timestamp:.1 windowNumber:view.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];
            report[@"drag_test_event"]=@{@"expected_screen":pointJSON(dragStart),@"actual_screen":pointJSON([view screenPoint:down]),@"flags":@(down.modifierFlags),@"hit":[view hit:[view screenPoint:down] output:first]?:@{},@"output":[view outputAt:[view screenPoint:down]]?:@0};desktop.probeDrivingGesture=YES;[view mouseDown:down];report[@"drag_mode"]=@(view.gesture);[view mouseDragged:drag];[view mouseUp:drag];desktop.probeDrivingGesture=NO;
            NSDictionary *moved=[desktop call:@{@"op":@"snapshot"}];
            report[@"world_drag_changed_only_world"]=@(![after[@"windows"][0][@"world_rect"]isEqual:moved[@"windows"][0][@"world_rect"]]&&[after[@"outputs"]isEqual:moved[@"outputs"]]&&[source.router valid]);
            NSMutableArray *attempts=[NSMutableArray array];
            BOOL controlsAllowed=![report[@"human_interrupted"]boolValue]&&![report[@"foreground_interrupted"]boolValue]&&fixtureUntouched(desktop,directory,captureForeground,report);
            if(controlsAllowed&&[source.router valid])[[NSRunningApplication runningApplicationWithProcessIdentifier:source.router.pid]activateWithOptions:0];
            if(controlsAllowed)pump(.25);
            report[@"source_active_before_controls"]=@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==source.router.pid);
            for(NSNumber *output in view.outputs){
                if(!controlsAllowed||!fixtureUntouched(desktop,directory,source.router.pid,report))break;
                NSDictionary *b=readJSON([directory stringByAppendingPathComponent:@"source.json"]);source.router.tag++;
                BOOL delivered=probeClick(view,output,projected(desktop,source.logical,output,CGPointMake(120,120)));pump(.2);
                NSDictionary *button=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
                if(!fixtureUntouched(desktop,directory,source.router.pid,report))break;
                probeClick(view,output,projected(desktop,source.logical,output,CGPointMake(170,195)));pump(.2);
                if(!fixtureUntouched(desktop,directory,source.router.pid,report))break;NSString *typed=[NSString stringWithFormat:@"Infinify-native-view-%@",output];[source.router type:typed at:CGPointMake(170,195)];pump(.3);
                NSDictionary *textResult=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
                if(!fixtureUntouched(desktop,directory,source.router.pid,report))break;
                CGEventRef scroll=CGEventCreateScrollWheelEvent(source.router.eventSource,kCGScrollEventUnitPixel,1,-100);BOOL sc=[view forward:scroll at:projected(desktop,source.logical,output,CGPointMake(200,300)) output:output activate:NO];CFRelease(scroll);pump(.4);
                NSDictionary *result=readJSON([directory stringByAppendingPathComponent:@"source.json"]);
                if(!fixtureUntouched(desktop,directory,source.router.pid,report))break;
                BOOL clean=[b[@"untagged_events"]unsignedIntegerValue]==[result[@"untagged_events"]unsignedIntegerValue];
                [attempts addObject:@{@"output":output,@"button":@(clean&&delivered&&[button[@"clicks"]integerValue]>[b[@"clicks"]integerValue]),@"text":@(clean&&[textResult[@"text_sha256"]isEqual:digest(typed)]),@"scroll":@(clean&&sc&&[result[@"scroll_y"]doubleValue]>[textResult[@"scroll_y"]doubleValue]),@"native_key_focus":result[@"key_window"]?:@NO,@"uncontaminated":@(clean),@"after":result?:@{}}];
                if(!clean){report[@"human_interrupted"]=@YES;break;}
            }
            if([report[@"human_interrupted"]boolValue]||[report[@"foreground_interrupted"]boolValue]){
                for(NSDictionary *frame in frames)if(frame[@"png"])[NSFileManager.defaultManager removeItemAtPath:frame[@"png"] error:nil];
                [frames removeAllObjects];report[@"screenshots_suppressed"]=@YES;
            }
            report[@"controls"]=attempts;report[@"stream_frames"]=@(source.frames);report[@"native_bounds_unchanged"]=@([source.router valid]&&[windowInfo(source.router.wid)[(id)kCGWindowBounds]isEqual:ready[@"bounds"]]);
            [desktop saveScene];Desktop *reopened=[Desktop new];[reopened call:@{@"op":@"load",@"path":desktop.statePath}];NSDictionary *restored=[reopened call:@{@"op":@"snapshot"}];report[@"reopened_snapshot"]=restored;BOOL unbound=[restored[@"windows"]count]==1&&[restored[@"windows"][0][@"source"]isEqual:NSNull.null];report[@"reopen_unbound"]=@(unbound);
            NSString *invalidPath=[directory stringByAppendingPathComponent:@"invalid-scene.json"];
            NSData *invalid=[@"{broken original scene" dataUsingEncoding:NSUTF8StringEncoding];[invalid writeToFile:invalidPath atomically:YES];
            Desktop *invalidLoad=[Desktop new];BOOL rejected=![invalidLoad loadScene:invalidPath];[invalidLoad cleanup];
            report[@"invalid_scene_preserved"]=@(rejected&&invalidLoad.startupError.length&&[invalid isEqual:[NSData dataWithContentsOfFile:invalidPath]]);
            // A drag entering a native source without a matching shell down
            // must not be delivered. The same production guard locks cross-source drags.
            NSUInteger sentBefore=source.router.sent.count;CGEventRef orphan=CGEventCreateMouseEvent(source.router.eventSource,kCGEventLeftMouseDragged,CGPointZero,kCGMouseButtonLeft);
            BOOL orphanSent=[view forward:orphan at:projected(desktop,source.logical,first,CGPointMake(120,120)) output:first activate:NO];CFRelease(orphan);
            report[@"orphan_native_drag_rejected"]=@(!orphanSent&&source.router.sent.count==sentBefore);
            // Exercise removal while selected, then reject the exact old input identity.
            [desktop detach:source];NSDictionary *stale=[desktop call:@{@"op":@"input",@"output":first,@"screen":pointJSON(anchor),@"identity":source.identity}];report[@"detached_input_rejected"]=@(stale==nil);
        }else if(!probe)while(!stopped&&child.running&&-start.timeIntervalSinceNow<60){[desktop poll];pump(.05);}
    }
    report[@"source_final"]=readJSON([directory stringByAppendingPathComponent:@"source.json"])?:@{};
    [desktop cleanup];pump(.2);report[@"panels_closed"]=@(desktop.panels.count==0);report[@"sources_detached"]=@(desktop.sources.count==0);report[@"streams_stopped"]=@(desktop.pendingStops.count==0);
    BOOL restore=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==child.processIdentifier&&!previous.terminated&&[previous.launchDate isEqual:previousBirth];report[@"foreground_restore_attempted"]=@(restore);if(restore)[previous activateWithOptions:0];
    if(child.running)[child terminate];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];while(child.running&&deadline.timeIntervalSinceNow>0)usleep(10000);if(child.running)kill(child.processIdentifier,SIGKILL);[child waitUntilExit];
    report[@"source_reaped"]=@(!child.running);report[@"source_exit_status"]=@(child.terminationStatus);report[@"pointer_unchanged"]=@(CGPointEqualToPoint(initialPointer,pointer()));
    BOOL pass=enrolled;if(probe){for(NSString *key in @[@"invalid_scene_preserved",@"orphan_native_drag_rejected",@"chooser_selection_attached",@"world_drag_changed_only_world",@"separate_live_layers",@"world_fixed_during_camera_changes",@"pointer_anchor_stable",@"independent_second_camera",@"native_bounds_unchanged",@"reopen_unbound",@"detached_input_rejected",@"panels_closed",@"sources_detached",@"streams_stopped",@"source_reaped"])pass&=[report[key]boolValue];
        pass&=[report[@"controls"]count]==2;for(NSDictionary *attempt in report[@"controls"])pass&=[attempt[@"button"]boolValue]&&[attempt[@"text"]boolValue]&&[attempt[@"scroll"]boolValue]&&[attempt[@"native_key_focus"]boolValue];
        for(int view=0;view<2;view++){BOOL red=NO,blue=NO;for(NSDictionary *frame in report[@"frames"]){NSArray *views=frame[@"views"];if(views.count!=2)continue;red|=[views[view][@"red"]integerValue]>500;blue|=[views[view][@"blue"]integerValue]>500;pass&=[views[view][@"outside_clip"]integerValue]==0;}pass&=red&&blue;}
    }report[@"passed"]=@(pass);save(report,receipt);return pass?0:2;
}
int main(int argc,const char **argv) { @autoreleasepool {
    BOOL experimental=NO;const char *filtered[argc+1];int count=0;
    for(int i=0;i<argc;i++){if(i>0&&!strcmp(argv[i],"--experimental-native-navigation")){experimental=YES;continue;}filtered[count++]=argv[i];}filtered[count]=NULL;argc=count;argv=filtered;

    if(argc==2&&!strcmp(argv[1],"--help")){puts("Infinify.app — macOS 26+ Apple Silicon native window canvas\nDefault: show chooser; only explicitly selected windows are captured.\n--demo EMPTY_DIRECTORY: disposable interactive fixture, bounded to 60 seconds\n--demo-probe EMPTY_DIRECTORY: automated own-fixture E2E, no permission prompts\n--demo-probe-guard EMPTY_DIRECTORY: own-fixture interruption regression (expected exit 2)\n--experimental-native-navigation: gated Center/Previous/Next and Option-Tab focus navigation\n--state ABSOLUTE_PATH: explicit persistent scene file (default Application Support/Infinify/scene.json)\n--source DIR SECONDS NONCE: internal disposable child only\nOption-drag / blank scroll: pan. Command-wheel / pinch: anchored zoom (max 1x).\nControl-Option-drag: world move/snap; add Shift: cluster.\nNative left-click/drag/scroll forwarded only to selected, freshly validated source.\nNative keyboard/IME remain with the real app. Control-Option-Escape or Quit exits.\nResize status explains unavailable native layout resizing. No SIP/settings changes.");return 0;}
    BOOL child=argc==5&&!strcmp(argv[1],"--source"),demo=argc==3&&!strcmp(argv[1],"--demo"),guard=argc==3&&!strcmp(argv[1],"--demo-probe-guard"),probe=argc==3&&!strcmp(argv[1],"--demo-probe"),state=argc==3&&!strcmp(argv[1],"--state");
    if(argc!=1&&!child&&!demo&&!probe&&!guard&&!state)return 64;
    if(experimental&&(child||probe||guard))return 64;
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [ProbeApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    if(child){char *end=NULL;double seconds=strtod(argv[3],&end);if(!end||*end||!isfinite(seconds)||seconds<1||seconds>65)return 64;return source(@(argv[2]),seconds,@(argv[4]));}
    Desktop *desktop=[Desktop new];desktop.experimentalNavigation=experimental;desktop.demo=demo||probe||guard;desktop.probe=probe||guard;desktop.interruptProbe=guard;
    if(demo||probe||guard){NSString *dir=@(argv[2]);BOOL isDir=NO;if(![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir]||!isDir||[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil].count)return 64;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];return runDemo(desktop,dir,probe||guard);}
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Infinify"];
    if(state){desktop.statePath=@(argv[2]);if(!desktop.statePath.isAbsolutePath)return 64;}
    else {if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])return 2;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];}
    [desktop loadScene:desktop.statePath];
    [[NSNotificationCenter defaultCenter]addObserver:desktop selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [desktop showChooser:nil];while(!stopped){[desktop poll];pump(.08);}[desktop cleanup];[desktop.chooser close];return 0;
} }
