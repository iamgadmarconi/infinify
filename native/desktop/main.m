// SPDX-License-Identifier: GPL-3.0-or-later
// The capture/router implementation is shared verbatim with our validated probe.
// Its private API provenance remains in native/captured-windows/captured.m.
#define main captured_probe_main
#include "../captured-windows/captured.m"
#undef main
#import <Carbon/Carbon.h>
#include "driftwm_desktop.h"
#import "focus-driver.h"
#import "resize-driver.h"
#import "resize-capture-policy.h"
#include <mach/mach_time.h>

static NSDictionary *pointJSON(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
static NSDictionary *rectJSON(CGRect r) { return @{@"origin":pointJSON(r.origin),@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}}; }
static CGRect jsonRect(NSDictionary *r) { return CGRectMake([r[@"origin"][@"x"] doubleValue],[r[@"origin"][@"y"] doubleValue],[r[@"size"][@"width"] doubleValue],[r[@"size"][@"height"] doubleValue]); }
static CGPoint jsonPoint(NSDictionary *p) { return CGPointMake([p[@"x"] doubleValue],[p[@"y"] doubleValue]); }
static CGFloat screenTop(void) { return NSMaxY(NSScreen.screens.firstObject.frame); }
static CGRect topRect(NSRect r) { return CGRectMake(r.origin.x,screenTop()-NSMaxY(r),r.size.width,r.size.height); }
static NSString *const helpText=@"Option-drag: pan · ⌘-wheel/pinch: zoom · ⌃⌥-drag: move · +Shift: cluster · ⌃⌥A: home · ⌃⌥W: fit · ⌃⌥=/-/0: zoom · ⌃⌥⌘-arrows: pan view · ⌃⌥Esc: exit";
// Fitted widths keep every toolbar button, experimental navigation included, inside the 1040 px demo panel.
static CGFloat toolbarButton(NSView *view,NSButton *button,CGFloat x) { button.frame=NSMakeRect(x,8,ceil(button.fittingSize.width),26);[view addSubview:button];return NSMaxX(button.frame)+4; }
#include "resize-isolation.inc.m"
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
@property (weak) DWResizeCoordinator *resize;
@property NSNumber *configuredRevision;
@property CMSampleBufferRef latestSample;
@property NSNumber *latestRevision;
@property BOOL resizeFailureHandled;
- (void)clearSample;
@end
@implementation LiveSource
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { dispatch_async(dispatch_get_main_queue(),^{if(stream!=self.stream||self.detached)return;self.error=error.localizedDescription;self.resizeFailureHandled=YES;[self.resize invalidate:self.logical];[self.resize cancel];}); }
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if(stream!=self.stream)return;
    if(self.detached||self.error||type!=SCStreamOutputTypeScreen||!CMSampleBufferIsValid(sample)||!CMSampleBufferGetImageBuffer(sample))return;
    if(self.resize){[self.resize accept:sample window:self.logical stream:stream install:^BOOL(CMSampleBufferRef accepted){return [self installSample:accepted];}];return;}
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(!a||!CFArrayGetCount(a))return;
    NSDictionary *info=(__bridge NSDictionary *)CFArrayGetValueAtIndex(a,0);
    if(![info[SCStreamFrameInfoStatus]isKindOfClass:NSNumber.class]||[info[SCStreamFrameInfoStatus]integerValue]!=SCFrameStatusComplete)return;
    [self installSample:sample];
}
- (BOOL)installSample:(CMSampleBufferRef)sample {
    if(self.resize){for(AVSampleBufferDisplayLayer *surface in self.surfaces)if(surface.hidden||surface.sampleBufferRenderer.status==AVQueuedSampleBufferRenderingStatusFailed||!surface.sampleBufferRenderer.readyForMoreMediaData)return NO;}
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,YES);if(attachments&&CFArrayGetCount(attachments))CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments,0),kCMSampleAttachmentKey_DisplayImmediately,kCFBooleanTrue);
    CVImageBufferRef buffer=CMSampleBufferGetImageBuffer(sample);self.buffer=CGSizeMake(CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer));
    for(AVSampleBufferDisplayLayer *surface in self.surfaces){if(surface.hidden)continue;if(surface.sampleBufferRenderer.status==AVQueuedSampleBufferRenderingStatusFailed)[surface.sampleBufferRenderer flush];if(surface.sampleBufferRenderer.readyForMoreMediaData)[surface.sampleBufferRenderer enqueueSampleBuffer:sample];}
    if(self.resize){[self clearSample];self.latestSample=(CMSampleBufferRef)CFRetain(sample);self.latestRevision=[self.resize captureState:self.logical][@"observation_revision"];}
    self.frames++;return YES;
}
- (void)clearSample {if(self.latestSample){CFRelease(self.latestSample);self.latestSample=NULL;}self.latestRevision=nil;}
- (void)dealloc { if(_latestSample)CFRelease(_latestSample);if(_router.eventSource)CFRelease(_router.eventSource); }
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
@property NSNumber *lastOutput; // most recently interacted output: toolbar view-action target
@property LiveSource *pressedSource;
@property CGPoint pressedLocal;
@property NSNumber *resizeTransaction;
@property NSInteger gesture; // 1 pan, 2 logical world drag, 3 native pointer
- (void)render:(NSDictionary *)snapshot;
- (NSNumber *)outputAt:(CGPoint)p;
- (NSNumber *)actionOutput;
- (BOOL)forward:(CGEventRef)event at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate;
@end
@interface Desktop : NSObject <NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate>
@property DriftDesktop *controller;
@property BOOL experimentalNavigation;
@property BOOL experimentalResize;
@property BOOL ownedResizeProbe;
@property DWNativeResizeDriver *ownedResizeDriver;
@property DWResizeCoordinator *resize;
@property id resizeKeyMonitor;
@property id resizeGlobalKeyMonitor;
@property NSNumber *resizeSavedTransaction;
- (void)configureResize;
@property DWNavigationCoordinator *navigation;
@property NSTimer *frameTimer;
@property CFTimeInterval lastObservation;
@property CFTimeInterval lastResizeObservation;
@property DWNavigationInput *navigationInput;
@property CFMachPortRef navigationTap;
@property CFRunLoopSourceRef navigationTapSource;
@property EventHotKeyRef nextHotkey, previousHotkey;
@property UInt32 nextNavigationKey, previousNavigationKey;
- (void)cancelNavigation;
@property EventHandlerRef navigationHandler;
- (void)configureNavigation;
- (void)stopNavigation;
- (void)navigateButton:(NSButton *)sender;
- (void)cycleNavigation:(BOOL)backward;
- (void)ensureFrames;
- (BOOL)cameraFrame;
@property BOOL flying;
@property EventHandlerRef viewHandler;
@property BOOL viewKeysWarned;
@property NSUInteger statusToken;
- (NSNumber *)viewOutput;
- (void)viewAction:(NSString *)op direction:(NSString *)direction output:(NSNumber *)output;

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
@property NSButton *grant;
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
- (void)openCanvas:(id)sender;
- (void)grantAccess:(id)sender;
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
- (NSNumber *)actionOutput { return [self.outputs containsObject:self.lastOutput]?self.lastOutput:self.outputs.firstObject; }
- (void)render:(NSDictionary *)snapshot {
    NSMutableSet *keys=[NSMutableSet set],*invalidate=[NSMutableSet set]; [CATransaction begin];[CATransaction setDisableActions:YES];
    for(NSDictionary *p in snapshot[@"placements"]){
        if(![self.outputs containsObject:p[@"output"]])continue;
        NSString *key=[NSString stringWithFormat:@"%@:%@",p[@"window"],p[@"output"]];[keys addObject:key];
        CALayer *tile=self.tiles[key];if(!tile){tile=[CALayer layer];tile.masksToBounds=YES;tile.backgroundColor=[NSColor colorWithWhite:.16 alpha:1].CGColor;[self.layer insertSublayer:tile atIndex:0];self.tiles[key]=tile;}
        CGRect full=jsonRect(p[@"screen_rect"]),clip=jsonRect(p[@"clip_rect"]);tile.frame=CGRectOffset(clip,-self.globalBounds.origin.x,-self.globalBounds.origin.y);
        LiveSource *source=self.desktop.sources[p[@"window"]];
        AVSampleBufferDisplayLayer *surface=self.surfaces[key];BOOL newSurface=surface==nil;
        if(source&&!source.detached){
            if(!surface){for(CALayer *child in tile.sublayers.copy)[child removeFromSuperlayer];surface=[AVSampleBufferDisplayLayer layer];surface.videoGravity=AVLayerVideoGravityResize;[tile addSublayer:surface];self.surfaces[key]=surface;[source.surfaces addObject:surface];}
            BOOL settled=!source.resize||[p[@"presentation_settled"]boolValue];
            surface.hidden=!settled;if(!settled){[source clearSample];[surface removeFromSuperlayer];[source.surfaces removeObject:surface];[self.surfaces removeObjectForKey:key];surface=nil;}
            if(source.resize&&settled){CGRect crop=jsonRect(p[@"buffer_crop"]);NSDictionary *buffer=p[@"source"][@"buffer"];CGFloat sx=clip.size.width/crop.size.width,sy=clip.size.height/crop.size.height;
                surface.frame=CGRectMake(-crop.origin.x*sx,-crop.origin.y*sy,[buffer[@"width"]doubleValue]*sx,[buffer[@"height"]doubleValue]*sy);
            }else surface.frame=CGRectMake(full.origin.x-clip.origin.x,full.origin.y-clip.origin.y,full.size.width,full.size.height);
            if(source.resize&&settled&&surface.sampleBufferRenderer.status==AVQueuedSampleBufferRenderingStatusFailed){surface.hidden=YES;[invalidate addObject:source.logical];}
            if(source.resize&&settled&&newSurface&&![source.resize.installingWindow isEqual:source.logical]){
                if(source.latestSample&&[source.latestRevision isEqual:p[@"source"][@"observation_revision"]]&&surface.sampleBufferRenderer.readyForMoreMediaData)[surface.sampleBufferRenderer enqueueSampleBuffer:source.latestSample];
                else {surface.hidden=YES;[invalidate addObject:source.logical];}
            }
        }else{
            if(surface){[surface.sampleBufferRenderer flush];[surface removeFromSuperlayer];[self.surfaces removeObjectForKey:key];}
            if(!tile.sublayers.count){CATextLayer *text=[CATextLayer layer];text.string=[NSString stringWithFormat:@"Detached window %@\nChoose a source to rebind\n⌃⌥ click to dismiss",p[@"window"]];text.fontSize=17;text.foregroundColor=NSColor.whiteColor.CGColor;text.wrapped=YES;text.frame=CGRectMake(12,12,MAX(40,clip.size.width-24),100);text.contentsScale=NSScreen.mainScreen.backingScaleFactor;[tile addSublayer:text];}
        }
        for(CALayer *child in tile.sublayers.copy)if([child.name isEqual:@"resize-handle"])[child removeFromSuperlayer];
        if(self.desktop.experimentalResize&&[snapshot[@"focused"]isEqual:p[@"window"]]&&[p[@"presentation_settled"]boolValue])for(NSDictionary *handle in DWResizeHandles(full,clip)){
            CALayer *h=[CALayer layer];h.name=@"resize-handle";h.backgroundColor=NSColor.systemOrangeColor.CGColor;h.frame=CGRectMake([handle[@"x"]doubleValue]-clip.origin.x-4,[handle[@"y"]doubleValue]-clip.origin.y-4,8,8);[tile addSublayer:h];
        }
        // Placement order is the controller's bottom-to-top world z order.
        [tile removeFromSuperlayer];[self.layer insertSublayer:tile atIndex:(unsigned)keys.count-1];
    }
    for(NSString *key in self.tiles.allKeys)if(![keys containsObject:key]){
        AVSampleBufferDisplayLayer *surface=self.surfaces[key];for(LiveSource *source in self.desktop.sources.allValues)[source.surfaces removeObject:surface];
        [self.tiles[key] removeFromSuperlayer];[self.tiles removeObjectForKey:key];[self.surfaces removeObjectForKey:key];
    }
    [CATransaction commit];self.status.stringValue=self.desktop.statusText?:@"";for(NSNumber *window in invalidate)[self.desktop.resize invalidate:window];
}
- (NSDictionary *)hit:(CGPoint)p output:(NSNumber *)output {
    // Controller input intentionally rejects placeholders. Find their geometry only
    // for the explicit dismiss action; this result never authorizes native delivery.
    NSDictionary *snapshot=[self.desktop call:@{@"op":@"snapshot"}];
    for(NSDictionary *placement in [snapshot[@"placements"] reverseObjectEnumerator])if([placement[@"output"]isEqual:output]&&CGRectContainsPoint(jsonRect(placement[@"clip_rect"]),p)){if(!self.desktop.sources[placement[@"window"]])return @{@"window":placement[@"window"],@"placeholder":@YES};break;}
    return [self.desktop call:@{@"op":@"hit",@"output":output,@"screen":pointJSON(p)}][@"hit"];
}
- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate {
    if(self.desktop.resize&&![self.desktop.resize canRemove:nil])return NO;
    if(activate)[self.desktop cancelNavigation];
    if(!e||!output)return NO;
    if(!AXIsProcessTrusted()){self.desktop.statusText=@"Input requires Accessibility access. Enable it in System Settings, then reopen.";return NO;}
    NSDictionary *hit=[self hit:p output:output];if(![hit isKindOfClass:NSDictionary.class])return NO;
    LiveSource *source=self.desktop.sources[hit[@"window"]];if(!source||![source.router valid]||(source.resize&&![source.resize validate:source.logical]))return NO;
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
    [self.desktop cancelNavigation];
    if(self.desktop.resize&&![self.desktop.resize canRemove:nil]){[self.desktop.resize cancel];return;}
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.startPoint=self.lastPoint=p;self.dragOutput=self.lastOutput=output;
    if(self.desktop.experimentalResize&&!(e.modifierFlags&(NSEventModifierFlagControl|NSEventModifierFlagOption))){NSDictionary *snapshot=[self.desktop call:@{@"op":@"snapshot"}];
        for(NSDictionary *placement in [snapshot[@"placements"]reverseObjectEnumerator])if([placement[@"output"]isEqual:output]&&[placement[@"window"]isEqual:snapshot[@"focused"]]&&[placement[@"presentation_settled"]boolValue]){
            BOOL occluded=NO;for(NSDictionary *front in [snapshot[@"placements"]reverseObjectEnumerator]){if(front==placement)break;if([front[@"output"]isEqual:output]&&CGRectContainsPoint(jsonRect(front[@"clip_rect"]),p)){occluded=YES;break;}}if(occluded)continue;
            for(NSDictionary *h in DWResizeHandles(jsonRect(placement[@"screen_rect"]),jsonRect(placement[@"clip_rect"])))if(hypot(p.x-[h[@"x"]doubleValue],p.y-[h[@"y"]doubleValue])<=7){
                NSDictionary *reply=[self.desktop.resize request:@{@"op":@"begin_native_resize",@"window":placement[@"window"],@"output":output,@"edges":h[@"edge"],@"start_screen":pointJSON(p),@"group":@((e.modifierFlags&NSEventModifierFlagShift)!=0)}];
                if(reply){self.resizeTransaction=reply[@"transaction"];self.gesture=4;}[self.desktop render];return;
            }
        }
    }
    // Internal resize probe never falls through into native click activation.
    if(self.desktop.ownedResizeProbe)return;
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
    if(self.gesture==4)[self.desktop.resize request:@{@"op":@"native_resize_to",@"transaction":self.resizeTransaction,@"screen":pointJSON(p)}];
    else if(self.gesture==1)[self.desktop call:@{@"op":@"pan",@"output":self.dragOutput,@"screen_delta":pointJSON(CGPointMake(self.lastPoint.x-p.x,self.lastPoint.y-p.y))}];
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
- (void)mouseUp:(NSEvent *)e { if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;} (void)e;if(self.gesture==4)[self.desktop.resize request:@{@"op":@"end_native_resize",@"transaction":self.resizeTransaction}];self.resizeTransaction=nil;[self releasePressed];if(self.gesture==2)[self.desktop call:@{@"op":@"end_gesture"}];self.gesture=0;[self.desktop saveScene]; }
- (void)zoom:(double)factor at:(CGPoint)p output:(NSNumber *)output {
    for(NSDictionary *o in [self.desktop call:@{@"op":@"snapshot"}][@"outputs"])if([o[@"id"] isEqual:output]){[self.desktop call:@{@"op":@"zoom",@"output":output,@"zoom":@(MAX(.001,MIN(1,[o[@"zoom"] doubleValue]*factor))),@"anchor":pointJSON(p)}];break;}
    [self.desktop render];[self.desktop saveScene];
}
- (void)scrollWheel:(NSEvent *)e {
    if(self.desktop.resize&&![self.desktop.resize canRemove:nil])return;
    if(self.desktop.probe){self.desktop.probeHumanInput=YES;return;}
    [self.desktop cancelNavigation];
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.lastOutput=output;
    if(e.modifierFlags&NSEventModifierFlagCommand)[self zoom:exp(e.scrollingDeltaY*.01) at:p output:output];
    else if((e.modifierFlags&NSEventModifierFlagOption)||![[self hit:p output:output]isKindOfClass:NSDictionary.class]){[self.desktop call:@{@"op":@"pan",@"output":output,@"screen_delta":pointJSON(CGPointMake(-e.scrollingDeltaX,-e.scrollingDeltaY))}];[self.desktop render];[self.desktop saveScene];}
    else {CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output activate:NO];CFRelease(cg);}
}
- (void)magnifyWithEvent:(NSEvent *)e { if(self.desktop.resize&&![self.desktop.resize canRemove:nil])return; [self.desktop cancelNavigation]; if(self.desktop.probe){self.desktop.probeHumanInput=YES;return;} CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(output){self.lastOutput=output;[self zoom:1+e.magnification at:p output:output];} }
@end
static CGEventRef navigationInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;Desktop *desktop=(__bridge Desktop *)context;
    if(type==kCGEventKeyDown&&CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==53)[desktop.resize cancel];
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){desktop.navigation.focusAllowed=NO;[desktop.navigationInput cancel];[desktop.navigation invalidate];return event;}
    CGEventFlags flags=CGEventGetFlags(event);
    NSUInteger modifiers=((flags&kCGEventFlagMaskAlternate)?1:0)|((flags&kCGEventFlagMaskShift)?2:0)|((flags&(kCGEventFlagMaskCommand|kCGEventFlagMaskControl|kCGEventFlagMaskSecondaryFn|kCGEventFlagMaskAlphaShift))?4:0);
    // Observed keys, modifiers and pointer events cancel focus work only. Camera flights,
    // view actions included, stop on a canvas press, scroll or pinch via -cancelNavigation.
    if(type==kCGEventFlagsChanged){NSInteger action=[desktop.navigationInput flagsChanged:modifiers];if(action==1)[desktop.navigation cancelFocus];else if(action==2)[desktop.navigation releaseCycle];return event;}
    if(CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)==48){
        if(type==kCGEventKeyDown&&[desktop.navigationInput tabDown:modifiers])return event;
        if(type==kCGEventKeyUp&&[desktop.navigationInput tabUp])return event;
    }
    [desktop.navigationInput cancel];[desktop.navigation cancelFocus];return event;
}
static OSStatus navigationKey(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    Desktop *desktop=(__bridge Desktop *)context;
    if(key.signature!='NavI'||(key.id!=desktop.nextNavigationKey&&key.id!=desktop.previousNavigationKey))return eventNotHandledErr;
    [desktop cycleNavigation:key.id==desktop.previousNavigationKey];return noErr;
}
static OSStatus exitKey(EventHandlerCallRef next,EventRef event,void *context) { (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);if(key.signature!='Infi'||key.id!=1)return eventNotHandledErr;[(__bridge Desktop *)context quit:nil];return noErr; }
// DriftWM view actions: ⌃⌥ stands in for upstream "mod", and ⌘ for the extra ctrl of
// upstream's mod+ctrl+arrow pan because Control is already part of the chord.
// Hot key id = row + 1; append rows (numbered bookmarks) without renumbering.
static const struct { UInt32 key,modifiers;const char *op,*direction; } viewKeys[]={
    {0,controlKey|optionKey,"home_toggle",NULL},{13,controlKey|optionKey,"zoom_to_fit",NULL},{24,controlKey|optionKey,"zoom_in",NULL},{27,controlKey|optionKey,"zoom_out",NULL},{29,controlKey|optionKey,"zoom_reset",NULL},{6,controlKey|optionKey,"zoom_reset",NULL},
    {123,controlKey|optionKey|cmdKey,"pan_viewport","left"},{124,controlKey|optionKey|cmdKey,"pan_viewport","right"},{125,controlKey|optionKey|cmdKey,"pan_viewport","down"},{126,controlKey|optionKey|cmdKey,"pan_viewport","up"}};
static OSStatus viewKey(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(key.signature!='InfV'||key.id<1||key.id>sizeof(viewKeys)/sizeof(*viewKeys))return eventNotHandledErr;
    Desktop *desktop=(__bridge Desktop *)context;const char *direction=viewKeys[key.id-1].direction;
    [desktop viewAction:@(viewKeys[key.id-1].op) direction:direction?@(direction):nil output:[desktop viewOutput]];return noErr;
}
@implementation Desktop { EventHotKeyRef _viewHotkeys[sizeof(viewKeys)/sizeof(*viewKeys)]; }
- (instancetype)init {
    if((self=[super init])){_controller=driftwm_desktop_create();_panels=[NSMutableArray array];_views=[NSMutableArray array];_sources=[NSMutableDictionary dictionary];_choices=[NSMutableArray array];_pendingStops=[NSMutableArray array];_statusText=helpText;}
    return self;
}
- (void)configureResize {
    if(!self.experimentalResize||self.resize)return;
    __weak Desktop *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.resize",DISPATCH_QUEUE_SERIAL);
    self.resize=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak call:c];} driver:self.ownedResizeDriver?:[DWNativeResizeDriver new] clock:^uint64_t{return mach_absolute_time();} worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.resize.enabled=YES;self.resize.changed=^{Desktop *d=weak;if(d.resize.failure)d.statusText=d.resize.failure;
        for(NSDictionary *w in [d call:@{@"op":@"snapshot"}][@"windows"]){LiveSource *source=d.sources[w[@"window"]];id state=w[@"source"];if(source&&[state isKindOfClass:NSDictionary.class]&&state[@"capture_revision"]==NSNull.null)[source clearSample];if(!source||![state isKindOfClass:NSDictionary.class]||![state[@"observation_known"]boolValue])continue;
            CGRect observed=jsonRect(state[@"observed_rect"]);source.router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observed));
            if(source.stream&&!source.error&&![source.configuredRevision isEqual:state[@"observation_revision"]]){source.configuredRevision=state[@"observation_revision"];
                SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)ceil(observed.size.width*2);config.height=(size_t)ceil(observed.size.height*2);config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=CMTimeMake(1,30);config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;
                SCStream *stream=source.stream;NSNumber *revision=source.configuredRevision;[stream updateConfiguration:config completionHandler:^(NSError *error){if(error)dispatch_async(dispatch_get_main_queue(),^{if(DWResizeConfigurationCurrent(stream,source.stream,revision,source.configuredRevision,source.detached)){source.error=error.localizedDescription;source.resizeFailureHandled=YES;[source.resize invalidate:source.logical];[source.resize cancel];}});}];
            }
        }id transaction=[d call:@{@"op":@"snapshot"}][@"native_resize"];if([transaction isKindOfClass:NSDictionary.class]&&[transaction[@"phase"]isEqual:@"needs_observation"])d.statusText=@"Native resize remains uncertain; source retained and input disabled.";if([transaction isKindOfClass:NSDictionary.class]&&[d.resize canRemove:nil]&&!d.resize.obligations&&![d.resizeSavedTransaction isEqual:transaction[@"transaction"]]){d.resizeSavedTransaction=transaction[@"transaction"];[d saveScene];}[d render];};
    if(!self.ownedResizeProbe){
    self.resizeKeyMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event){if(event.keyCode==53&&weak.resize&&![weak.resize canRemove:nil]){[weak.resize cancel];return nil;}return event;}];
    self.resizeGlobalKeyMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^(NSEvent *event){if(event.keyCode==53)[weak.resize cancel];}];
    }
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
    static UInt32 nextIdentifier=1;if(nextIdentifier>UINT32_MAX-2){self.navigation.focusAllowed=NO;return;}
    self.nextNavigationKey=nextIdentifier++;self.previousNavigationKey=nextIdentifier++;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};EventHotKeyID next={'NavI',self.nextNavigationKey},previous={'NavI',self.previousNavigationKey};
    if(!self.navigation.focusAllowed||InstallApplicationEventHandler(navigationKey,1,&type,(__bridge void *)self,&_navigationHandler)!=noErr||RegisterEventHotKey(48,optionKey,next,GetApplicationEventTarget(),0,&_nextHotkey)!=noErr||RegisterEventHotKey(48,optionKey|shiftKey,previous,GetApplicationEventTarget(),0,&_previousHotkey)!=noErr){
        if(self.nextHotkey){UnregisterEventHotKey(self.nextHotkey);self.nextHotkey=NULL;}if(self.previousHotkey){UnregisterEventHotKey(self.previousHotkey);self.previousHotkey=NULL;}
        self.statusText=@"Experimental held cycling unavailable; use navigation buttons. Native focus requires a working input observer.";
    }
    [self.navigation frame];
}
- (void)cancelNavigation {
    [self.navigationInput cancel];[self.navigation invalidate];
    // Without the coordinator, pointer intent still stops every view-action flight.
    if(!self.navigation)for(DesktopView *view in self.views)for(NSNumber *output in view.outputs)[self call:@{@"op":@"cancel_navigation",@"output":output}];
}
- (void)stopNavigation {
    self.nextNavigationKey=0;self.previousNavigationKey=0;
    [self.navigationInput cancel];self.navigationInput=nil;[self.navigation shutdown];self.navigation=nil;[self.frameTimer invalidate];self.frameTimer=nil;self.flying=NO;
    if(self.navigationTapSource){CFRunLoopRemoveSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);CFRelease(self.navigationTapSource);self.navigationTapSource=NULL;}
    if(self.navigationTap){CFMachPortInvalidate(self.navigationTap);CFRelease(self.navigationTap);self.navigationTap=NULL;}
    if(self.nextHotkey){UnregisterEventHotKey(self.nextHotkey);self.nextHotkey=NULL;}if(self.previousHotkey){UnregisterEventHotKey(self.previousHotkey);self.previousHotkey=NULL;}if(self.navigationHandler){RemoveEventHandler(self.navigationHandler);self.navigationHandler=NULL;}
}
// One camera frame for every armed flight. The experimental coordinator owns the tick
// when it exists; the default app ticks the controller itself on the same clock.
- (BOOL)cameraFrame {
    if(self.cleaning)return NO;
    if(self.navigation)return [self.navigation frame];
    NSDictionary *result=[self call:@{@"op":@"tick_navigation",@"timestamp_ns":@((uint64_t)(CACurrentMediaTime()*1e9))}];
    if([result[@"changed_outputs"]count])[self render];
    BOOL active=[result[@"needs_frames"]boolValue];if(!active&&self.flying)[self saveScene];self.flying=active;return active;
}
- (void)ensureFrames {
    if(self.frameTimer||self.cleaning)return;
    if(![[self call:@{@"op":@"snapshot"}][@"navigation"][@"flights"]count])return;
    __weak Desktop *weak=self;self.frameTimer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer){Desktop *desktop=weak;if(!desktop||![desktop cameraFrame]){[timer invalidate];desktop.frameTimer=nil;}}];
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
    [self.resize cancel];if(self.resize&&![self.resize canRemove:nil])return;
    NSNumber *output=[self navigationOutput:sender.superview];if(!output)return;
    if(sender.tag==0){id window=[self call:@{@"op":@"snapshot"}][@"focused"];if([window isKindOfClass:NSNumber.class])[self.navigation navigate:@{@"op":@"navigate_window",@"window":window,@"output":output,@"zoom_policy":@"reset"}];}
    else [self.navigation navigate:@{@"op":@"cycle_navigate",@"output":output,@"backward":@(sender.tag==1),@"held":@NO}];
}
- (void)cycleNavigation:(BOOL)backward {
    [self.resize cancel];if(self.resize&&![self.resize canRemove:nil])return;
    if(!self.navigation.focusAllowed||!self.nextHotkey||!self.previousHotkey)return;
    NSNumber *held=[self.navigationInput takeShortcut:backward];if(!held)return;
    NSNumber *output=[self navigationOutput:nil];if(output)[self.navigation navigate:@{@"op":@"cycle_navigate",@"output":output,@"backward":@(backward),@"held":held}];
}
// Hotkey target: the output under the pointer, else the panel under it (a display
// panel's toolbar strip lies outside its output), else the first registered output.
- (NSNumber *)viewOutput {
    CGPoint point=pointer();
    for(DesktopView *view in self.views){NSNumber *output=[view outputAt:point];if(output)return output;}
    for(DesktopView *view in self.views)if(view.outputs.count&&CGRectContainsPoint(view.globalBounds,point))return [view actionOutput];
    for(DesktopView *view in self.views)if(view.outputs.count)return view.outputs[0];
    return nil;
}
- (void)flashStatus:(NSString *)text {
    self.statusText=text;NSUInteger token=++self.statusToken;__weak Desktop *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{Desktop *d=weak;if(d.statusToken!=token||d.cleaning||![d.statusText isEqual:text])return;d.statusText=helpText;[d render];});
}
- (NSString *)viewFeedback:(NSString *)op flight:(NSDictionary *)flight output:(NSNumber *)output {
    BOOL home=[op isEqual:@"home_toggle"];
    if(home||[op isEqual:@"zoom_to_fit"]){
        if(!flight)return home?@"Already home":@"Nothing to fit";
        // The toggle keeps its return view while away; an armed flight without one is the way back.
        id returns=[self call:@{@"op":@"snapshot"}][@"navigation"][home?@"home_returns":@"overview_returns"];
        if([returns isKindOfClass:NSDictionary.class]&&!returns[output.stringValue])return @"Previous view";
        return home?@"Home":@"Zoom to fit";
    }
    if([op isEqual:@"pan_viewport"])return nil;
    if(!flight)return @"Zoom limit reached";
    double zoom=[flight[@"target_zoom"]doubleValue];return zoom==1?@"Zoom 1:1":[NSString stringWithFormat:@"Zoom %.3g%%",zoom*100];
}
// Camera-only DriftWM view actions. An existing flight is deliberately not cancelled
// first: pan_viewport extends its in-flight target.
- (void)viewAction:(NSString *)op direction:(NSString *)direction output:(NSNumber *)output {
    [self.resize cancel];if(self.resize&&![self.resize canRemove:nil])return;
    if(self.cleaning||!output)return;
    NSDictionary *reply=[self call:direction?@{@"op":op,@"output":output,@"direction":direction}:@{@"op":op,@"output":output}];
    NSDictionary *flight=[reply[@"navigation"]isKindOfClass:NSDictionary.class]?reply[@"navigation"]:nil;
    NSString *text=reply?[self viewFeedback:op flight:flight output:output]:self.statusText;if(text)[self flashStatus:text];
    if(flight&&!self.navigation)self.flying=YES;
    [self render];if(flight)[self ensureFrames];
}
- (void)viewButton:(NSButton *)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    DesktopView *view=[sender.superview isKindOfClass:DesktopView.class]?(DesktopView *)sender.superview:nil;
    [self viewAction:sender.identifier direction:nil output:[view actionOutput]];
}
- (void)configureViewKeys {
    if(self.viewHandler)return;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};BOOL missing=InstallApplicationEventHandler(viewKey,1,&type,(__bridge void *)self,&_viewHandler)!=noErr;
    // Non-fatal: every chord that did register stays live and the toolbar covers the rest.
    if(!missing)for(UInt32 i=0;i<sizeof(viewKeys)/sizeof(*viewKeys);i++){EventHotKeyID key={'InfV',i+1};if(RegisterEventHotKey(viewKeys[i].key,viewKeys[i].modifiers,key,GetApplicationEventTarget(),0,&_viewHotkeys[i])!=noErr){_viewHotkeys[i]=NULL;missing=YES;}}
    if(missing&&!self.viewKeysWarned){self.viewKeysWarned=YES;self.statusText=@"Some view shortcuts are unavailable; the Home, Fit and zoom buttons still work.";}
}
- (void)stopViewKeys {
    for(size_t i=0;i<sizeof(viewKeys)/sizeof(*viewKeys);i++)if(_viewHotkeys[i]){UnregisterEventHotKey(_viewHotkeys[i]);_viewHotkeys[i]=NULL;}
    if(_viewHandler){RemoveEventHandler(_viewHandler);_viewHandler=NULL;}
}
- (NSDictionary *)call:(NSDictionary *)command {
    NSData *request=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command} options:0 error:nil];
    char *response=driftwm_desktop_request(self.controller,request.bytes,request.length);if(!response){self.statusText=@"Controller unavailable";return nil;}
    NSData *data=[NSData dataWithBytes:response length:strlen(response)];driftwm_desktop_response_free(response);
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![reply[@"ok"]boolValue]){self.statusText=reply[@"error"]?:@"Controller error";return nil;}return reply[@"data"];
}
- (BOOL)loadScene:(NSString *)path {
    [self cancelNavigation];[self.resize cancel];if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize must settle before loading";return NO;}
    self.statePath=path;
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return YES;
    if([self call:@{@"op":@"load",@"path":path}])return YES;
    self.startupError=[NSString stringWithFormat:@"Saved scene could not be loaded: %@. Original file preserved. Quit and repair it, or restart with --state and a different path.",self.statusText];
    // Every save path, including quit and Return to desktop, is disabled.
    self.statePath=nil;return NO;
}
- (void)saveScene { if(self.statePath)[self call:@{@"op":@"save",@"path":self.statePath}]; }
- (void)render { NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];for(DesktopView *view in self.views)[view render:snapshot]; }
- (void)quit:(id)sender { (void)sender;[self.resize shutdown];[self stopNavigation];stopped=1; }
- (void)resizeUnavailable:(id)sender { if(self.probe&&sender){self.probeHumanInput=YES;return;} (void)sender;if(self.experimentalResize){self.statusText=@"Experimental: select one source, then drag an orange edge handle. Unknown family or capture mapping stays inert; Escape cancels shell input.";[self render];return;}self.statusText=@"Native layout resize is unavailable. Resize the original app on the desktop, then return; capture reconciles without changing world geometry.";[self render]; }
- (void)returnDesktop:(id)sender { [self.resize cancel];if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize is pending or unresolved; source retained";[self render];return;} if(self.probe&&sender){self.probeHumanInput=YES;return;} (void)sender;[self cleanup];[self showChooser:nil]; }
- (DesktopView *)panel:(NSRect)frame outputRects:(NSArray *)rects identities:(NSArray *)identities {
    NSPanel *panel=[[(self.ownedResizeProbe?RPIsolatedPanel.class:CanvasPanel.class) alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO;panel.level=NSFloatingWindowLevel;panel.animationBehavior=NSWindowAnimationBehaviorNone;panel.collectionBehavior=NSWindowCollectionBehaviorMoveToActiveSpace|NSWindowCollectionBehaviorFullScreenAuxiliary;
    DesktopView *view=[[DesktopView alloc]initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];view.desktop=self;view.globalBounds=topRect(frame);view.outputs=[NSMutableArray array];view.tiles=[NSMutableDictionary dictionary];view.surfaces=[NSMutableDictionary dictionary];view.wantsLayer=YES;view.layer.backgroundColor=[NSColor colorWithSRGBRed:.045 green:.065 blue:.10 alpha:1].CGColor;panel.contentView=view;
    for(NSUInteger i=0;i<rects.count;i++){NSNumber *output=[self call:@{@"op":@"register_output",@"stable_id":identities[i],@"screen_bounds":rects[i]}][@"output"];if(output)[view.outputs addObject:output];}
    NSArray *names=self.ownedResizeProbe?@[]:@[@"Choose windows",@"Return to desktop",@"Resize status",@"Quit ⌃⌥Esc"];
    if(self.ownedResizeProbe)[view addSubview:label(@"Noninteractive owned resize probe — supervisor signal or deadline exits",NSMakeRect(15,8,720,26))];
    SEL actions[]={@selector(showChooser:),@selector(returnDesktop:),@selector(resizeUnavailable:),@selector(quit:)};
    CGFloat x=12;for(NSUInteger i=0;i<names.count;i++)x=toolbarButton(view,[NSButton buttonWithTitle:names[i] target:self action:actions[i]],x);
    if(!self.ownedResizeProbe){NSArray *titles=@[@"Home",@"Fit",@"−",@"1:1",@"+"],*ops=@[@"home_toggle",@"zoom_to_fit",@"zoom_out",@"zoom_reset",@"zoom_in"],*tips=@[@"Home: origin at 1:1; again returns to the previous view (⌃⌥A)",@"Zoom to fit every window; again returns to the previous view (⌃⌥W)",@"Zoom out (⌃⌥-)",@"Zoom 1:1 (⌃⌥0 or ⌃⌥Z)",@"Zoom in (⌃⌥=)"];
        // The accessory app is rarely active, so tooltips must not wait for activation.
        if(!self.probe)panel.allowsToolTipsWhenApplicationIsInactive=YES;
        for(NSUInteger i=0;i<titles.count;i++){NSButton *button=[NSButton buttonWithTitle:titles[i] target:self action:@selector(viewButton:)];button.identifier=ops[i];button.toolTip=tips[i];x=toolbarButton(view,button,x);}}
    if(self.experimentalNavigation){NSArray *titles=@[@"Center selected",@"Previous",@"Next"];for(NSUInteger i=0;i<titles.count;i++){NSButton *button=[NSButton buttonWithTitle:titles[i] target:self action:@selector(navigateButton:)];button.tag=i;x=toolbarButton(view,button,x);}}
    view.status=label(self.statusText,NSMakeRect(15,37,MAX(100,frame.size.width-30),22));view.status.textColor=NSColor.lightGrayColor;view.status.font=[NSFont systemFontOfSize:11];[view addSubview:view.status];
    [self.panels addObject:panel];[self.views addObject:view];if(self.ownedResizeProbe&&!rpBeforeOrder(panel)){self.probeHumanInput=YES;return view;}[panel orderFrontRegardless];return view;
}
- (void)openPanels {
    if(self.panels.count)return;self.cleaning=NO;
    if(self.demo){NSRect frame=NSMakeRect(100,120,1040,600);CGRect global=topRect(frame);NSMutableArray *rects=[NSMutableArray array];for(int i=0;i<2;i++)[rects addObject:rectJSON(CGRectOffset(ports[i],global.origin.x,global.origin.y))];[self panel:frame outputRects:rects identities:@[@"fixture-view-a",@"fixture-view-b"]];}
    else for(NSScreen *screen in NSScreen.screens){NSNumber *display=screen.deviceDescription[@"NSScreenNumber"];CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display.unsignedIntValue);NSString *name=uuid?CFBridgingRelease(CFUUIDCreateString(NULL,uuid)):nil;if(uuid)CFRelease(uuid);if(!name)continue;CGRect output=topRect(screen.frame);output.origin.y+=64;output.size.height-=64;[self panel:screen.frame outputRects:@[rectJSON(output)] identities:@[name]];}
    if(!self.probe&&!self.ownedResizeProbe)[self configureViewKeys];
    if(!self.ownedResizeProbe){
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};OSStatus handler=InstallApplicationEventHandler(exitKey,1,&type,(__bridge void *)self,&_hotkeyHandler);EventHotKeyID key={'Infi',1};
    if(handler!=noErr||RegisterEventHotKey(53,controlKey|optionKey,key,GetApplicationEventTarget(),0,&_exitHotkey)!=noErr)self.statusText=@"Exit shortcut unavailable; use the visible Quit button.";
    }
    [self configureResize];[self configureNavigation];[self render];
}
- (void)refreshChoices:(id)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;[self.choices removeAllObjects];[self.table reloadData];
    if(self.startupError){self.chooserStatus.stringValue=self.startupError;return;}
    // The app asks macOS for a grant only from the user's own click on this button.
    BOOL capture=CGPreflightScreenCaptureAccess();self.grant.hidden=self.demo||(capture&&AXIsProcessTrusted());self.grant.title=capture?@"Allow input…":@"Allow screen recording…";
    if(!capture){self.chooserStatus.stringValue=@"No windows are listed: Infinify has no Screen Recording access. Click Allow screen recording…, enable Infinify in System Settings, then quit and reopen. Open canvas works without it.";return;}
    self.chooserStatus.stringValue=@"Reading available local windows…";
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){dispatch_async(dispatch_get_main_queue(),^{
        self.shareable=content.windows;[self.choices removeAllObjects];
        for(SCWindow *w in content.windows){NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:w.owningApplication.processID];if(self.demo&&w.owningApplication.processID!=self.fixturePID)continue;if(w.windowLayer!=0||w.owningApplication.processID==getpid()||w.frame.size.width<40||w.frame.size.height<40||(!self.demo&&app.activationPolicy!=NSApplicationActivationPolicyRegular))continue;
            [self.choices addObject:@{@"window":w,@"label":[NSString stringWithFormat:@"%@ — %@",w.owningApplication.applicationName,w.title.length?w.title:@"Untitled window"]}];}
        [self.table reloadData];self.chooserStatus.stringValue=error?error.localizedDescription:AXIsProcessTrusted()?@"Select a window explicitly. Native keyboard and IME stay with the selected application.":@"Viewing is available. Native input requires Accessibility access in System Settings.";
    });}];
}
- (void)showChooser:(id)sender {
    [self.resize cancel];if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize is pending or unresolved; source retained";[self render];return;}
    [self cancelNavigation];
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;
    if(!self.chooser){self.chooser=[[(self.ownedResizeProbe?RPIsolatedWindow.class:FixtureWindow.class) alloc]initWithContentRect:NSMakeRect(200,180,720,470) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];self.chooser.title=@"Infinify — choose native windows";self.chooser.level=NSFloatingWindowLevel+1;self.chooser.releasedWhenClosed=NO;self.chooser.delegate=self;
        NSView *v=self.chooser.contentView;NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(18,130,684,315)];scroll.hasVerticalScroller=YES;
        self.table=[[NSTableView alloc]initWithFrame:scroll.bounds];NSTableColumn *column=[[NSTableColumn alloc]initWithIdentifier:@"Window"];column.title=@"Application — native window";column.width=675;[self.table addTableColumn:column];self.table.dataSource=self;self.table.delegate=self;scroll.documentView=self.table;[v addSubview:scroll];
        self.chooserStatus=label(@"",NSMakeRect(18,55,480,60));self.chooserStatus.maximumNumberOfLines=3;[v addSubview:self.chooserStatus];
        self.grant=[NSButton buttonWithTitle:@"" target:self action:@selector(grantAccess:)];self.grant.frame=NSMakeRect(507,70,195,30);self.grant.hidden=YES;[v addSubview:self.grant];
        self.rebind=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(18,15,205,30) pullsDown:NO];[v addSubview:self.rebind];
        NSButton *attach=[NSButton buttonWithTitle:@"Add selected window" target:self action:@selector(attachChoice:)];attach.frame=NSMakeRect(229,15,170,30);[v addSubview:attach];
        NSButton *canvas=[NSButton buttonWithTitle:@"Open canvas" target:self action:@selector(openCanvas:)];canvas.frame=NSMakeRect(405,15,120,30);canvas.toolTip=@"Show the saved world without adding a window";[v addSubview:canvas];
        NSButton *refresh=[NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshChoices:)];refresh.frame=NSMakeRect(531,15,85,30);[v addSubview:refresh];
        NSButton *quit=[NSButton buttonWithTitle:@"Quit" target:self action:@selector(quit:)];quit.frame=NSMakeRect(622,15,80,30);[v addSubview:quit];}
    [self.rebind removeAllItems];[self.rebind addItemWithTitle:@"Create a new world window"];
    for(NSDictionary *w in [self call:@{@"op":@"snapshot"}][@"windows"])if(!self.sources[w[@"window"]]){[self.rebind addItemWithTitle:[NSString stringWithFormat:@"Rebind %@: %@",w[@"window"],w[@"metadata"][@"title"]?:@"window"]];self.rebind.lastItem.representedObject=w[@"window"];}
    if(self.ownedResizeProbe){if(!rpBeforeOrder(self.chooser)){self.probeHumanInput=YES;return;}[self.chooser orderFrontRegardless];}else {[self.chooser makeKeyAndOrderFront:nil];[NSApp activate];}[self refreshChoices:nil];
}
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window;if(!self.panels.count)stopped=1;return YES; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView;return self.choices.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {(void)tableView;(void)column;return self.choices[row][@"label"];}
// The saved world and its cameras need no capture: placeholders, navigation and
// view actions work before any source is chosen or any privacy grant exists.
- (void)openCanvas:(id)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;if(self.startupError){self.chooserStatus.stringValue=self.startupError;return;}
    [self openPanels];[self.chooser orderOut:nil];[self render];
}
- (void)grantAccess:(id)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;BOOL capture=CGPreflightScreenCaptureAccess();
    if(!capture)CGRequestScreenCaptureAccess();else AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt:@YES});
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:capture?@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility":@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    self.chooserStatus.stringValue=capture?@"Enable Infinify under Accessibility, then click Refresh.":@"Enable Infinify under Screen & System Audio Recording, then quit and reopen Infinify.";
}
- (void)attachChoice:(id)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;NSInteger row=self.table.selectedRow;if(row<0||row>=(NSInteger)self.choices.count){if(CGPreflightScreenCaptureAccess())self.chooserStatus.stringValue=@"Select a source window first.";else [self refreshChoices:nil];return;}
    [self openPanels];NSNumber *logical=self.rebind.selectedItem.representedObject;
    if([self attach:self.choices[row][@"window"] logical:logical world:nil]){[self.chooser orderOut:nil];[self saveScene];[self render];}else self.chooserStatus.stringValue=self.statusText;
}
- (BOOL)attach:(SCWindow *)window logical:(NSNumber *)logical world:(NSDictionary *)world {
    [self cancelNavigation];
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
    source.resize=self.resize;
    source.stream=[[SCStream alloc]initWithFilter:[[SCContentFilter alloc]initWithDesktopIndependentWindow:window] configuration:config delegate:source];[self.resize bind:source.logical stream:source.stream];NSError *error=nil;
    if(![source.stream addStreamOutput:source type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&error]){source.error=error.localizedDescription;[self detach:source];return NO;}
    SCStream *starting=source.stream;[starting startCaptureWithCompletionHandler:^(NSError *e){if(e)dispatch_async(dispatch_get_main_queue(),^{if(source.stream==starting&&!source.detached)source.error=e.localizedDescription;});}];
    if(!privateAvailable)self.statusText=@"Live view only: private per-window input is unavailable on this OS.";
    [self render];return YES;
}
- (void)detach:(LiveSource *)source {
    [self cancelNavigation];
    if(source.detached)return;[self.resize cancel];
    if(![self call:@{@"op":@"remove_source",@"window":source.logical,@"identity":source.identity,@"keep_placeholder":@YES}])return;
    for(DesktopView *view in self.views)if(view.pressedSource==source)[view releasePressed];source.detached=YES;[source clearSample];
    [self.pendingStops addObject:source];[source.stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{source.streamStopped=YES;source.stream=nil;[self.pendingStops removeObject:source];});}];[source.surfaces removeAllObjects];[self.sources removeObjectForKey:source.logical];
}
- (void)screensChanged:(NSNotification *)notification {
    (void)notification;if(self.demo||!self.panels.count)return;[self stopNavigation];
    for(DesktopView *view in self.views){[view releasePressed];for(NSNumber *output in view.outputs){NSDictionary *reply=[self call:@{@"op":@"remove_output",@"output":output}];[self.resize consume:reply];}}
    for(NSPanel *panel in self.panels){[panel orderOut:nil];[panel close];}
    [self.panels removeAllObjects];[self.views removeAllObjects];for(LiveSource *source in self.sources.allValues)[source.surfaces removeAllObjects];
    if(self.exitHotkey){UnregisterEventHotKey(self.exitHotkey);self.exitHotkey=NULL;}if(self.hotkeyHandler){RemoveEventHandler(self.hotkeyHandler);self.hotkeyHandler=NULL;}[self stopViewKeys];
    [self openPanels];[self saveScene];
}
- (void)poll {
    if(self.cleaning)return;
    if(self.resize&&CACurrentMediaTime()-self.lastResizeObservation>=.5){self.lastResizeObservation=CACurrentMediaTime();[self.resize observeBindings];}
    // Idle polling keeps the clock current; a flight found without its timer regains 60 Hz.
    if(!self.frameTimer&&[self cameraFrame])[self ensureFrames];
    if(self.navigation&&CACurrentMediaTime()-self.lastObservation>=.5){self.lastObservation=CACurrentMediaTime();[self.navigation observe];}
    for(LiveSource *source in self.sources.allValues){
        if(source.resize){if(source.error&&!source.resizeFailureHandled){source.resizeFailureHandled=YES;[self.resize invalidate:source.logical];[self.resize cancel];self.statusText=@"Capture failed; source retained until resize obligations settle";}continue;}
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
    if(self.cleaning)return;self.cleaning=YES;[self.resize shutdown];[self stopNavigation];
    while(self.resize.obligations){self.statusText=@"Quit pending: waiting for native resize result";[self render];pump(.01);}
    if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize uncertainty remains unresolved at shutdown";fprintf(stderr,"%s\n",self.statusText.UTF8String);}
    [self saveScene];
    for(DesktopView *view in self.views)[view releasePressed];
    NSArray *closing=self.sources.allValues;
    for(LiveSource *source in closing)[self detach:source];
    // Streaming lifetime is separate from controller removal: uncertainty retains
    // the binding but cannot leave callbacks alive across controller destruction.
    for(LiveSource *source in self.sources.allValues)if(source.stream&&![self.pendingStops containsObject:source]){
        source.detached=YES;[self.pendingStops addObject:source];
        [source.stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{source.streamStopped=YES;source.stream=nil;[self.pendingStops removeObject:source];});}];
    }
    while(self.pendingStops.count){self.statusText=@"Shutdown pending: waiting for capture streams";pump(.01);}
    for(DesktopView *view in self.views)for(NSNumber *output in view.outputs){NSDictionary *reply=[self call:@{@"op":@"remove_output",@"output":output}];[self.resize consume:reply];}
    for(NSPanel *panel in self.panels){[panel orderOut:nil];[panel close];}[self.panels removeAllObjects];[self.views removeAllObjects];
    if(self.exitHotkey){UnregisterEventHotKey(self.exitHotkey);self.exitHotkey=NULL;}if(self.hotkeyHandler){RemoveEventHandler(self.hotkeyHandler);self.hotkeyHandler=NULL;}[self stopViewKeys];
    if(self.resizeKeyMonitor){[NSEvent removeMonitor:self.resizeKeyMonitor];self.resizeKeyMonitor=nil;}
    if(self.resizeGlobalKeyMonitor){[NSEvent removeMonitor:self.resizeGlobalKeyMonitor];self.resizeGlobalKeyMonitor=nil;}
    if(!self.sources.count)self.resize=nil;

}
- (void)dealloc { [self stopNavigation];[self stopViewKeys];if(_controller)driftwm_desktop_destroy(_controller); }
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
#include "resize-fixture.inc.m"
#include "resize-probe.inc.m"

int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==3&&!strcmp(argv[1],"--owned-resize-check-restoration"))return ownedResizeCheckRestoration(@(argv[2]));
    if(argc==3&&!strcmp(argv[1],"--owned-resize-check-cleanup"))return ownedResizeCheckCleanup(@(argv[2]));
    if(argc>=2&&(!strcmp(argv[1],"--owned-resize-probe")||!strcmp(argv[1],"--owned-resize-fixture")))return ownedResizeEntry(argc,argv);
    BOOL experimental=NO,resize=NO;const char *filtered[argc+1];int count=0;
    for(int i=0;i<argc;i++){if(i>0&&!strcmp(argv[i],"--experimental-native-resize")){resize=YES;continue;}if(i>0&&!strcmp(argv[i],"--experimental-native-navigation")){experimental=YES;continue;}filtered[count++]=argv[i];}filtered[count]=NULL;argc=count;argv=filtered;

    if(argc==2&&!strcmp(argv[1],"--help")){puts("Infinify.app — macOS 26+ Apple Silicon native window canvas\nDefault: show chooser; only explicitly selected windows are captured. Open canvas shows the saved world without adding one.\n--owned-resize-probe EMPTY_DIRECTORY [SCENARIO]: explicit noninteractive owned-fixture resize probe (live)\n--demo EMPTY_DIRECTORY: disposable interactive fixture, bounded to 60 seconds\n--demo-probe EMPTY_DIRECTORY: automated own-fixture E2E, no permission prompts\n--demo-probe-guard EMPTY_DIRECTORY: own-fixture interruption regression (expected exit 2)\n--experimental-native-resize: experimental eight-handle size-only native resize\n--experimental-native-navigation: gated Center/Previous/Next and Option-Tab focus navigation\n--state ABSOLUTE_PATH: explicit persistent scene file (default Application Support/Infinify/scene.json)\n--source DIR SECONDS NONCE: internal disposable child only\nOption-drag / blank scroll: pan. Command-wheel / pinch: anchored zoom (max 1x).\nView actions animate one view's camera only (toolbar Home, Fit, -, 1:1, + or global shortcuts while the canvas is open):\n  Control-Option-A: home toggle (origin at 1:1, again to return). Control-Option-W: zoom-to-fit toggle.\n  Control-Option-Equals / Control-Option-Minus: zoom in / out. Control-Option-0 or Control-Option-Z: zoom 1:1.\n  Control-Option-Command-arrows: pan the view under the pointer.\nControl-Option-drag: world move/snap; add Shift: cluster.\nNative left-click/drag/scroll forwarded only to selected, freshly validated source.\nNative keyboard/IME remain with the real app. Control-Option-Escape or Quit exits.\nResize status explains unavailable native layout resizing. No SIP/settings changes.");return 0;}
    BOOL child=argc==5&&!strcmp(argv[1],"--source"),demo=argc==3&&!strcmp(argv[1],"--demo"),guard=argc==3&&!strcmp(argv[1],"--demo-probe-guard"),probe=argc==3&&!strcmp(argv[1],"--demo-probe"),state=argc==3&&!strcmp(argv[1],"--state");
    if(argc!=1&&!child&&!demo&&!probe&&!guard&&!state)return 64;
    if((experimental||resize)&&(child||probe||guard))return 64;
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [ProbeApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    if(child){char *end=NULL;double seconds=strtod(argv[3],&end);if(!end||*end||!isfinite(seconds)||seconds<1||seconds>65)return 64;return source(@(argv[2]),seconds,@(argv[4]));}
    Desktop *desktop=[Desktop new];desktop.experimentalNavigation=experimental;desktop.experimentalResize=resize;desktop.demo=demo||probe||guard;desktop.probe=probe||guard;desktop.interruptProbe=guard;
    if(demo||probe||guard){NSString *dir=@(argv[2]);BOOL isDir=NO;if(![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir]||!isDir||[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil].count)return 64;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];return runDemo(desktop,dir,probe||guard);}
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Infinify"];
    if(state){desktop.statePath=@(argv[2]);if(!desktop.statePath.isAbsolutePath)return 64;}
    else {if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])return 2;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];}
    [desktop loadScene:desktop.statePath];
    [[NSNotificationCenter defaultCenter]addObserver:desktop selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [desktop showChooser:nil];while(!stopped){[desktop poll];pump(.08);}[desktop cleanup];[desktop.chooser close];return 0;
} }
