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
#import "ipc-server.h"
#import "hotkeys.h"
#import "config-watcher.h"
#include <mach/mach_time.h>
#include <spawn.h>

static NSDictionary *pointJSON(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
static NSDictionary *rectJSON(CGRect r) { return @{@"origin":pointJSON(r.origin),@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}}; }
static CGRect jsonRect(NSDictionary *r) { return CGRectMake([r[@"origin"][@"x"] doubleValue],[r[@"origin"][@"y"] doubleValue],[r[@"size"][@"width"] doubleValue],[r[@"size"][@"height"] doubleValue]); }
static CGPoint jsonPoint(NSDictionary *p) { return CGPointMake([p[@"x"] doubleValue],[p[@"y"] doubleValue]); }
static CGFloat screenTop(void) { return NSMaxY(NSScreen.screens.firstObject.frame); }
static CGRect topRect(NSRect r) { return CGRectMake(r.origin.x,screenTop()-NSMaxY(r),r.size.width,r.size.height); }
static NSDictionary *asDict(id value) { return [value isKindOfClass:NSDictionary.class]?value:nil; }
// One past the JSON value at p. The input is the controller's own compact output.
static const char *jsonValueEnd(const char *p,const char *end) {
    for(NSInteger depth=0;p<end;p++){
        if(*p=='"'){for(p++;p<end&&*p!='"';p++)if(*p=='\\')p++;if(!depth)return p<end?p+1:end;}
        else if(*p=='{'||*p=='[')depth++;
        else if(*p=='}'||*p==']'){if(!depth)return p;if(!--depth)return p+1;}
        else if(*p==','&&!depth)return p;
    }
    return end;
}
// Raw bytes of one member of a JSON object: the controller's own number formatting
// and key order, which a round trip through NSJSONSerialization would rewrite.
static NSData *jsonMember(NSData *object,const char *key) {
    const char *p=object.bytes,*end=p+object.length;size_t length=strlen(key);
    if(p==end||*p!='{')return nil;
    for(p++;p<end&&*p=='"';){
        const char *name=p+1,*colon=jsonValueEnd(p,end);if(colon>=end||*colon!=':')return nil;
        const char *value=colon+1;p=jsonValueEnd(value,end);
        if((size_t)(colon-1-name)==length&&!memcmp(name,key,length))return [NSData dataWithBytes:value length:(NSUInteger)(p-value)];
        if(p<end&&*p==',')p++;
    }
    return nil;
}
static NSData *ipcError(NSString *message) { return [NSJSONSerialization dataWithJSONObject:@{@"Err":message} options:NSJSONWritingWithoutEscapingSlashes error:nil]; }
static NSArray *asArray(id value) { return [value isKindOfClass:NSArray.class]?value:@[]; }
static NSString *asString(id value) { return [value isKindOfClass:NSString.class]?value:nil; }
static NSNumber *asNumber(id value) { return [value isKindOfClass:NSNumber.class]?value:nil; }
// The first line and how many follow: the status line has room for one.
static NSString *summary(NSString *subject,NSArray<NSString *> *lines) { return [NSString stringWithFormat:@"%@: %@%@",subject,lines[0],lines.count>1?[NSString stringWithFormat:@" (+%lu more)",(unsigned long)lines.count-1]:@""]; }
// The exec effect, as upstream's exec_command: /bin/sh -c in a session of its own on
// /dev/null, with no other descriptor inherited and never waited on by the main loop.
// env overlays this process's environment; a null value removes the variable.
static NSString *execCommand(NSString *command,NSDictionary *env) {
    NSMutableDictionary<NSString *,NSString *> *environment=[NSProcessInfo.processInfo.environment mutableCopy];
    for(NSString *name in env){if(asString(env[name]))environment[name]=env[name];else [environment removeObjectForKey:name];}
    NSMutableData *pointers=[NSMutableData data];const char *end=NULL;
    for(NSString *name in environment){const char *entry=[NSString stringWithFormat:@"%@=%@",name,environment[name]].UTF8String;if(entry)[pointers appendBytes:&entry length:sizeof(entry)];}
    [pointers appendBytes:&end length:sizeof(end)];
    char *const arguments[]={"sh","-c",(char *)command.UTF8String,NULL};
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    for(int descriptor=0;descriptor<3;descriptor++)posix_spawn_file_actions_addopen(&actions,descriptor,"/dev/null",descriptor?O_WRONLY:O_RDONLY,0);
    posix_spawnattr_t attributes;posix_spawnattr_init(&attributes);sigset_t none,all;sigemptyset(&none);sigfillset(&all);
    posix_spawnattr_setsigmask(&attributes,&none);posix_spawnattr_setsigdefault(&attributes,&all);
    posix_spawnattr_setflags(&attributes,POSIX_SPAWN_SETSID|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF);
    pid_t pid=0;int error=posix_spawn(&pid,"/bin/sh",&actions,&attributes,arguments,(char *const *)pointers.bytes);
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attributes);
    if(error)return [NSString stringWithFormat:@"exec failed: %s",strerror(error)];
    // Reaped off the main queue whenever it exits.
    dispatch_source_t exited=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,(uintptr_t)pid,DISPATCH_PROC_EXIT,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_event_handler(exited,^{int status=0;waitpid(pid,&status,0);dispatch_source_cancel(exited);});
    dispatch_resume(exited);return nil;
}
// Probe, demo and owned-fixture runs: their fixed gestures and chords. A normal run
// builds its help from the bindings the config gives it.
static NSString *const helpText=@"Option-drag: pan · ⌘-wheel/pinch: zoom · ⌃⌥-drag: move · +Shift: cluster · ⌃⌥A: home · ⌃⌥W: fit · ⌃⌥=/-/0: zoom · ⌃⌥⌘-arrows: pan view · ⌃⌥1-4: bookmark (⇧ sets) · ⌃⌥Esc: exit";
// Toolbar view actions: title, upstream action, tooltip, and the fixed chord of the runs above.
static NSArray<NSArray<NSString *> *> *toolbarActions(void) {
    return @[@[@"Home",@"home-toggle",@"Home: origin at 1:1; again returns to the previous view",@"⌃⌥A"],@[@"Fit",@"zoom-to-fit",@"Zoom to fit every window; again returns to the previous view",@"⌃⌥W"],@[@"−",@"zoom-out",@"Zoom out",@"⌃⌥-"],@[@"1:1",@"zoom-reset",@"Zoom 1:1",@"⌃⌥0 or ⌃⌥Z"],@[@"+",@"zoom-in",@"Zoom in",@"⌃⌥="]];
}
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
@property int64_t pressedButton; // CGMouseButton held down in pressedSource
@property NSNumber *resizeTransaction;
@property NSInteger gesture; // 1 pan, 2 logical world drag, 3 native pointer, 4 native resize
@property NSInteger gestureButton; // NSEvent button number that began the gesture
@property CFTimeInterval lastScrollPan; // last finger scroll that panned, 0 for none
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
- (void)action:(NSString *)action output:(NSNumber *)output;
- (void)flashStatus:(NSString *)text;
// Normal runs only: keys, pointer gestures and settings come from the DriftWM config.
// Probe, demo and owned-fixture runs leave it off and keep the fixed chords and
// gestures they were validated with; they read no config and ask for no binding.
@property BOOL configured;
@property NSString *configPath; // --config; nil is the controller's default path
@property NSString *superChord; // --super; nil is ctrl+alt
@property DWHotKeys *hotKeys;
@property DWConfigWatcher *configWatcher;
@property NSString *configNote; // the config file's first problem and a count, upstream's error bar
@property NSString *help; // the chords registered, for the status line
@property BOOL dismissFree; // no binding claims ⌃⌥-click on a window
- (void)loadConfig:(BOOL)platform;
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window;
@property BOOL windowed;
@property NSSize windowSize;
@property DWIPCServer *ipc;
- (void)startIPC:(NSString *)path;

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
            if(!tile.sublayers.count){CATextLayer *text=[CATextLayer layer];text.string=[NSString stringWithFormat:@"Detached window %@\nChoose a source to rebind%@",p[@"window"],self.desktop.configured&&!self.desktop.dismissFree?@"":@"\n⌃⌥ click to dismiss"];text.fontSize=17;text.foregroundColor=NSColor.whiteColor.CGColor;text.wrapped=YES;text.frame=CGRectMake(12,12,MAX(40,clip.size.width-24),100);text.contentsScale=NSScreen.mainScreen.backingScaleFactor;[tile addSublayer:text];}
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
    CGEventType type=CGEventGetType(e);
    if((type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged)&&source!=self.pressedSource)return NO;
    NSDictionary *validated=[self.desktop call:@{@"op":@"input",@"output":output,@"screen":pointJSON(p),@"identity":source.identity}][@"hit"];
    if(![validated isKindOfClass:NSDictionary.class]||![source.router valid])return NO;
    if(activate)[self focusSource:source];
    CGPoint local=jsonPoint(validated[@"local"]);
    BOOL sent=[source.router post:e at:local];
    if(sent&&(type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown)){self.pressedSource=source;self.pressedLocal=local;self.pressedButton=CGEventGetIntegerValueField(e,kCGMouseEventButtonNumber);}
    if(sent&&self.pressedSource==source)self.pressedLocal=local;
    return sent;
}
// Native activation and logical focus of one source's window, as a click on it gives.
- (void)focusSource:(LiveSource *)source {
    NSRunningApplication *current=NSWorkspace.sharedWorkspace.frontmostApplication;
    if(current.processIdentifier!=source.router.pid){self.desktop.previousFocus=current;self.desktop.previousFocusBirth=current.launchDate;[[NSRunningApplication runningApplicationWithProcessIdentifier:source.router.pid] activateWithOptions:0];}
    [self.desktop call:@{@"op":@"focus",@"window":source.logical}];
}
// Edges as upstream's edges_from_position picks them: a 3×3 grid over the window,
// its centre resizing from the bottom right. The rect is the controller's placement.
- (void)beginResize:(NSNumber *)window snapped:(BOOL)snapped at:(CGPoint)p output:(NSNumber *)output {
    if(!self.desktop.resize){[self.desktop flashStatus:@"Window resize is gated behind --experimental-native-resize"];return;}
    for(NSDictionary *placement in [self.desktop call:@{@"op":@"snapshot"}][@"placements"])if([placement[@"output"]isEqual:output]&&[placement[@"window"]isEqual:window]){
        CGRect r=jsonRect(placement[@"screen_rect"]);CGFloat x=p.x-r.origin.x,y=p.y-r.origin.y;
        BOOL left=x<r.size.width/3,right=x>r.size.width*2/3,top=y<r.size.height/3,bottom=y>r.size.height*2/3;
        NSString *edges=left&&top?@"top_left":right&&top?@"top_right":left&&bottom?@"bottom_left":right&&bottom?@"bottom_right":left?@"left":right?@"right":top?@"top":bottom?@"bottom":@"bottom_right";
        NSDictionary *reply=[self.desktop.resize request:@{@"op":@"begin_native_resize",@"window":window,@"output":output,@"edges":edges,@"start_screen":pointJSON(p),@"group":@(snapped)}];
        if(reply){self.resizeTransaction=reply[@"transaction"];self.gesture=4;}return;
    }
}
// A normal run's press, dispatched as upstream's on_pointer_button does: the binding
// for the held modifiers in the window or canvas context, else the native window
// under the pointer. An unbound press on empty canvas means nothing to upstream either.
- (void)press:(NSEvent *)e button:(NSInteger)button hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)output {
    NSArray<NSString *> *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];LiveSource *source=hit?self.desktop.sources[hit[@"window"]]:nil;self.lastScrollPan=0;
    NSDictionary *binding=button<(NSInteger)triggers.count?[self.desktop mouseBinding:triggers[button] source:nil flags:e.modifierFlags window:hit!=nil]:nil;NSString *kind=asString(binding[@"kind"]),*action=asString(binding[@"action"]);
    BOOL move=[kind isEqual:@"move_window"]||[kind isEqual:@"move_snapped_windows"],resize=[kind isEqual:@"resize_window"]||[kind isEqual:@"resize_window_snapped"];
    // ⌃⌥-click still dismisses a detached placeholder while no binding claims that press.
    if(!binding&&!button&&hit&&!source&&(e.modifierFlags&NSEventModifierFlagControl)&&(e.modifierFlags&NSEventModifierFlagOption)){[self.desktop call:@{@"op":@"forget",@"window":hit[@"window"]}];[self.desktop render];[self.desktop saveScene];return;}
    if(move&&hit){if([self.desktop call:@{@"op":@"begin_drag",@"window":hit[@"window"],@"output":output,@"group":@([kind isEqual:@"move_snapped_windows"])}])self.gesture=2;}
    else if(resize&&hit)[self beginResize:hit[@"window"] snapped:[kind isEqual:@"resize_window_snapped"] at:p output:output];
    else if([kind isEqual:@"pan_viewport"])self.gesture=1;
    else if([kind isEqual:@"center_nearest"])[self.desktop flashStatus:@"center-nearest by pointer is not implemented yet"];
    // Upstream raises and focuses the window under the pointer, then runs the action on it.
    else if([kind isEqual:@"action"]&&action){if(source&&[source.router valid])[self focusSource:source];[self.desktop action:action output:output];return;}
    // Unbound, or bound to a gesture with nothing to act on here: the press is the native window's.
    else if(hit){self.gesture=3;CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output activate:YES];CFRelease(cg);}
    [self.desktop render];
}
- (void)mouseDown:(NSEvent *)e {
    if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;}
    // One gesture at a time: another button waits until the first is released.
    NSInteger button=self.desktop.configured?e.buttonNumber:0;if(self.gesture&&button!=self.gestureButton)return;
    [self.desktop cancelNavigation];
    if(self.desktop.resize&&![self.desktop.resize canRemove:nil]){[self.desktop.resize cancel];return;}
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.startPoint=self.lastPoint=p;self.dragOutput=self.lastOutput=output;self.gestureButton=button;
    if(!button&&self.desktop.experimentalResize&&!(e.modifierFlags&(NSEventModifierFlagControl|NSEventModifierFlagOption))){NSDictionary *snapshot=[self.desktop call:@{@"op":@"snapshot"}];
        for(NSDictionary *placement in [snapshot[@"placements"]reverseObjectEnumerator])if([placement[@"output"]isEqual:output]&&[placement[@"window"]isEqual:snapshot[@"focused"]]&&[placement[@"presentation_settled"]boolValue]){
            BOOL occluded=NO;for(NSDictionary *front in [snapshot[@"placements"]reverseObjectEnumerator]){if(front==placement)break;if([front[@"output"]isEqual:output]&&CGRectContainsPoint(jsonRect(front[@"clip_rect"]),p)){occluded=YES;break;}}if(occluded)continue;
            for(NSDictionary *h in DWResizeHandles(jsonRect(placement[@"screen_rect"]),jsonRect(placement[@"clip_rect"])))if(hypot(p.x-[h[@"x"]doubleValue],p.y-[h[@"y"]doubleValue])<=7){
                NSDictionary *reply=[self.desktop.resize request:@{@"op":@"begin_native_resize",@"window":placement[@"window"],@"output":output,@"edges":h[@"edge"],@"start_screen":pointJSON(p),@"group":(e.modifierFlags&NSEventModifierFlagShift)?@YES:@NO}];
                if(reply){self.resizeTransaction=reply[@"transaction"];self.gesture=4;}[self.desktop render];return;
            }
        }
    }
    // Internal resize probe never falls through into native click activation.
    if(self.desktop.ownedResizeProbe)return;
    NSDictionary *hit=[self hit:p output:output];BOOL isHit=[hit isKindOfClass:NSDictionary.class];
    if(self.desktop.configured){[self press:e button:button hit:isHit?hit:nil at:p output:output];return;}
    // Fixed gestures of probe, demo and owned-fixture runs.
    BOOL option=(e.modifierFlags&NSEventModifierFlagOption)!=0,control=(e.modifierFlags&NSEventModifierFlagControl)!=0;
    if(control&&option&&isHit&&!self.desktop.sources[hit[@"window"]]){[self.desktop call:@{@"op":@"forget",@"window":hit[@"window"]}];[self.desktop render];[self.desktop saveScene];return;}
    if(control&&option&&isHit){
        if([self.desktop call:@{@"op":@"begin_drag",@"window":hit[@"window"],@"output":output,@"group":(e.modifierFlags&NSEventModifierFlagShift)?@YES:@NO}])self.gesture=2;
    }else if(option||!isHit)self.gesture=1;
    else { self.gesture=3;CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output activate:YES];CFRelease(cg); }
    [self.desktop render];
}
- (void)rightMouseDown:(NSEvent *)e { if(self.desktop.configured)[self mouseDown:e];else [super rightMouseDown:e]; }
- (void)otherMouseDown:(NSEvent *)e { if(self.desktop.configured)[self mouseDown:e];else [super otherMouseDown:e]; }
- (void)rightMouseDragged:(NSEvent *)e { if(self.desktop.configured)[self mouseDragged:e];else [super rightMouseDragged:e]; }
- (void)otherMouseDragged:(NSEvent *)e { if(self.desktop.configured)[self mouseDragged:e];else [super otherMouseDragged:e]; }
- (void)rightMouseUp:(NSEvent *)e { if(self.desktop.configured)[self mouseUp:e];else [super rightMouseUp:e]; }
- (void)otherMouseUp:(NSEvent *)e { if(self.desktop.configured)[self mouseUp:e];else [super otherMouseUp:e]; }
- (void)mouseDragged:(NSEvent *)e {
    if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;}
    if(self.desktop.configured&&e.buttonNumber!=self.gestureButton)return;
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
        // The button that went down in the source is the one that comes up.
        CGMouseButton button=(CGMouseButton)self.pressedButton;CGEventType type=button==kCGMouseButtonLeft?kCGEventLeftMouseUp:button==kCGMouseButtonRight?kCGEventRightMouseUp:kCGEventOtherMouseUp;
        sig_atomic_t wasStopped=stopped;stopped=0;CGEventRef up=CGEventCreateMouseEvent(self.pressedSource.router.eventSource,type,CGPointZero,button);[self.pressedSource.router post:up at:self.pressedLocal];CFRelease(up);if(wasStopped)stopped=wasStopped;self.pressedSource=nil;}
}
- (void)mouseUp:(NSEvent *)e { if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;} if(self.desktop.configured&&e.buttonNumber!=self.gestureButton)return;if(self.gesture==4)[self.desktop.resize request:@{@"op":@"end_native_resize",@"transaction":self.resizeTransaction}];self.resizeTransaction=nil;[self releasePressed];if(self.gesture==2)[self.desktop call:@{@"op":@"end_gesture"}];self.gesture=0;[self.desktop saveScene]; }
- (void)zoom:(double)factor at:(CGPoint)p output:(NSNumber *)output { [self zoom:factor at:p output:output moving:NO]; }
// moving: a zoom the limit swallows sends nothing, and only one that changes the view ends a flight.
- (void)zoom:(double)factor at:(CGPoint)p output:(NSNumber *)output moving:(BOOL)moving {
    for(NSDictionary *o in [self.desktop call:@{@"op":@"snapshot"}][@"outputs"])if([o[@"id"] isEqual:output]){
        double zoom=[o[@"zoom"] doubleValue],target=MAX(.001,MIN(1,zoom*factor));
        if(moving){if(target==zoom)return;[self.desktop cancelNavigation];}
        [self.desktop call:@{@"op":@"zoom",@"output":output,@"zoom":@(target),@"anchor":pointJSON(p)}];break;}
    [self.desktop render];[self.desktop saveScene];
}
// A normal run's scroll, dispatched as upstream's on_pointer_axis does: a bound scroll
// pans or zooms the canvas and never reaches a window, an unbound one goes to the
// native window under it. Only a scroll that moves the camera ends a flight.
- (void)scroll:(NSEvent *)e {
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.lastOutput=output;BOOL precise=e.hasPreciseScrollingDeltas;
    // Upstream keeps a finger pan on the canvas for 150 ms, so a window sliding under the pointer cannot take the gesture.
    BOOL panning=self.lastScrollPan&&CACurrentMediaTime()-self.lastScrollPan<.15,window=!panning&&[[self hit:p output:output]isKindOfClass:NSDictionary.class];
    NSDictionary *binding=[self.desktop mouseBinding:@"scroll" source:precise?@"finger":@"wheel" flags:e.modifierFlags window:window];NSString *kind=asString(binding[@"kind"]);
    if(!binding){if(window){CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output activate:NO];CFRelease(cg);}return;}
    // Upstream's axis units: finger points as they are, one wheel line as one notch of 15.
    double sx=e.scrollingDeltaX,sy=e.scrollingDeltaY,dx=sx,dy=sy;
    if(!precise&&e.CGEvent){dx=15.0*CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis2);dy=15.0*CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis1);}
    // Speeds are the config's when the lookup reports them: upstream zooms by zoom.step^(notches/2 × zoom.mouse_speed) and pans by navigation.trackpad_speed.
    NSNumber *step=asNumber(binding[@"zoom_step"]),*zoomSpeed=asNumber(binding[@"zoom_mouse_speed"]),*panSpeed=asNumber(binding[@"trackpad_speed"]);
    if([kind isEqual:@"zoom"]){double factor=step&&zoomSpeed?pow(step.doubleValue,dy/30*zoomSpeed.doubleValue):exp(sy*.01);if(isfinite(factor)&&factor>0)[self zoom:factor at:p output:output moving:YES];}
    else if([kind isEqual:@"pan_viewport"]){
        CGPoint delta=panSpeed?CGPointMake(-dx*panSpeed.doubleValue,-dy*panSpeed.doubleValue):CGPointMake(-sx,-sy);if(!delta.x&&!delta.y)return;
        if(precise)self.lastScrollPan=CACurrentMediaTime();
        [self.desktop cancelNavigation];[self.desktop call:@{@"op":@"pan",@"output":output,@"screen_delta":pointJSON(delta)}];[self.desktop render];[self.desktop saveScene];
    }
}
- (void)scrollWheel:(NSEvent *)e {
    if(self.desktop.resize&&![self.desktop.resize canRemove:nil])return;
    if(self.desktop.probe){self.desktop.probeHumanInput=YES;return;}
    if(self.desktop.configured){[self scroll:e];return;}
    // Fixed gestures of probe, demo and owned-fixture runs.
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
// ⌃⌥Esc is the shell's own exit chord until a config binding claims it.
static NSNumber *exitChord(void) { return DWChord(53,controlKey|optionKey); }
// The fixed chords of an interactive --demo run, which reads no config; a normal run
// registers the config's bindings through DWHotKeys instead. ⌃⌥ stands in for upstream
// "mod", and ⌘ for the extra ctrl of upstream's mod+ctrl+arrow pan because Control is already part of the chord.
// Every row binds an upstream action string. Hot key id = row + 1; append rows without renumbering.
static const struct { UInt32 key,modifiers;const char *action; } viewKeys[]={
    {0,controlKey|optionKey,"home-toggle"},{13,controlKey|optionKey,"zoom-to-fit"},{24,controlKey|optionKey,"zoom-in"},{27,controlKey|optionKey,"zoom-out"},{29,controlKey|optionKey,"zoom-reset"},{6,controlKey|optionKey,"zoom-reset"},
    {123,controlKey|optionKey|cmdKey,"pan-viewport left"},{124,controlKey|optionKey|cmdKey,"pan-viewport right"},{125,controlKey|optionKey|cmdKey,"pan-viewport down"},{126,controlKey|optionKey|cmdKey,"pan-viewport up"},
    {18,controlKey|optionKey,"go-to-bookmark 1"},{19,controlKey|optionKey,"go-to-bookmark 2"},{20,controlKey|optionKey,"go-to-bookmark 3"},{21,controlKey|optionKey,"go-to-bookmark 4"},
    {18,controlKey|optionKey|shiftKey,"set-bookmark 1"},{19,controlKey|optionKey|shiftKey,"set-bookmark 2"},{20,controlKey|optionKey|shiftKey,"set-bookmark 3"},{21,controlKey|optionKey|shiftKey,"set-bookmark 4"}};
static OSStatus viewKey(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next;EventHotKeyID key={0};GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key);
    if(key.signature!='InfV'||key.id<1||key.id>sizeof(viewKeys)/sizeof(*viewKeys))return eventNotHandledErr;
    Desktop *desktop=(__bridge Desktop *)context;[desktop action:@(viewKeys[key.id-1].action) output:[desktop viewOutput]];return noErr;
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
    // Windowed mode registers no global hot key; Center, Previous and Next stay on the toolbar.
    if(self.windowed){[self.navigation frame];return;}
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
    else [self.navigation navigate:@{@"op":@"cycle_navigate",@"output":output,@"backward":sender.tag==1?@YES:@NO,@"held":@NO}];
}
- (void)cycleNavigation:(BOOL)backward {
    [self.hotKeys endRepeat];
    [self.resize cancel];if(self.resize&&![self.resize canRemove:nil])return;
    if(!self.navigation.focusAllowed||!self.nextHotkey||!self.previousHotkey)return;
    NSNumber *held=[self.navigationInput takeShortcut:backward];if(!held)return;
    NSNumber *output=[self navigationOutput:nil];if(output)[self.navigation navigate:@{@"op":@"cycle_navigate",@"output":output,@"backward":@(backward),@"held":held}];
}
// Hot key target and the IPC active output: the output under the pointer, else the panel
// under it (a panel's toolbar strip lies outside its output), else the first registered output.
- (NSNumber *)viewOutput {
    CGPoint point=pointer();
    for(DesktopView *view in self.views){NSNumber *output=[view outputAt:point];if(output)return output;}
    for(DesktopView *view in self.views)if(view.outputs.count&&CGRectContainsPoint(view.globalBounds,point))return [view actionOutput];
    for(DesktopView *view in self.views)if(view.outputs.count)return view.outputs[0];
    return nil;
}
- (void)flashStatus:(NSString *)text {
    self.statusText=text;NSUInteger token=++self.statusToken;__weak Desktop *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{Desktop *d=weak;if(d.statusToken!=token||d.cleaning||![d.statusText isEqual:text])return;d.statusText=[d restingStatus];[d render];});
}
// What the status line returns to: a problem in the config file stays up like upstream's error bar, else the help.
- (NSString *)restingStatus { return self.configured?self.configNote?:self.help?:@"":helpText; }
- (NSString *)actionFeedback:(NSString *)action flight:(NSDictionary *)flight output:(NSNumber *)output {
    BOOL home=[action isEqual:@"home-toggle"];
    if(home||[action isEqual:@"zoom-to-fit"]){
        if(!flight)return home?@"Already home":@"Nothing to fit";
        // The toggle keeps its return view while away; an armed flight without one is the way back.
        id returns=[self call:@{@"op":@"snapshot"}][@"navigation"][home?@"home_returns":@"overview_returns"];
        if([returns isKindOfClass:NSDictionary.class]&&!returns[output.stringValue])return @"Previous view";
        return home?@"Home":@"Zoom to fit";
    }
    if([action hasPrefix:@"pan-viewport "])return nil;
    if([action hasPrefix:@"set-bookmark "])return [NSString stringWithFormat:@"Bookmark %@ saved",[action substringFromIndex:13]];
    if([action hasPrefix:@"go-to-bookmark "])return [NSString stringWithFormat:@"Bookmark %@",[action substringFromIndex:15]];
    // Every other bound action, exec and nudge-window among them, reports only its errors.
    if(![@[@"zoom-in",@"zoom-out",@"zoom-reset"]containsObject:action])return nil;
    if(!flight)return @"Zoom limit reached";
    double zoom=[flight[@"target_zoom"]doubleValue];return zoom==1?@"Zoom 1:1":[NSString stringWithFormat:@"Zoom %.3g%%",zoom*100];
}
// Shared tail of every bound or scripted command: redraw, fly, persist, and the effects
// the shell owns: quit, exec, and a config reload.
- (void)applyReply:(NSDictionary *)reply {
    BOOL flight=asDict(reply[@"navigation"])!=nil;if(flight&&!self.navigation)self.flying=YES;
    [self render];if(flight)[self ensureFrames];
    if([reply[@"dirty"]isEqual:@YES])[self saveScene];
    for(id effect in asArray(reply[@"effects"])){NSDictionary *e=asDict(effect);NSString *op=asString(e[@"op"]);
        if([op isEqual:@"quit"])[self quit:nil];
        else if(!self.configured)continue;
        else if([op isEqual:@"exec"]&&asString(e[@"command"])){NSString *error=execCommand(e[@"command"],asDict(e[@"env"]));if(error)[self flashStatus:error];}
        // Deferred: a reload replaces the hot keys, and this may be running inside one of their handlers.
        else if([op isEqual:@"reload_config"]){__weak Desktop *weak=self;dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(d&&!d.cleaning)[d loadConfig:NO];});}
    }
}
// Every hot key and toolbar button runs an upstream action string. An existing flight
// is deliberately not cancelled first: pan-viewport extends its in-flight target.
- (void)action:(NSString *)action output:(NSNumber *)output {
    [self.resize cancel];if(self.resize&&![self.resize canRemove:nil])return;
    if(self.cleaning||!output)return;
    // Upstream's go-to-bookmark is silent on an unset name, so the bookmark table is asked first.
    NSString *name=[action hasPrefix:@"go-to-bookmark "]?[action substringFromIndex:15]:nil;
    BOOL unset=name&&!asDict(asDict([self call:@{@"op":@"ipc",@"output":output,@"request":@{@"Bookmark":@{@"name":name}}}])[@"reply"])[@"Ok"];
    NSDictionary *reply=[self call:@{@"op":@"action",@"output":output,@"action":action}];
    NSString *sets=self.configured?[self.hotKeys chords:[@"set-bookmark " stringByAppendingString:name?:@""]].firstObject:[@"⌃⌥⇧" stringByAppendingString:name?:@""];
    NSString *missing=[NSString stringWithFormat:@"No bookmark %@ yet%@",name,sets?[NSString stringWithFormat:@" — %@ sets it",sets]:@""];
    NSString *text=unset?missing:reply?[self actionFeedback:action flight:asDict(reply[@"navigation"]) output:output]:self.statusText;
    if(text)[self flashStatus:text];
    [self applyReply:reply];
}
- (void)viewButton:(NSButton *)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    DesktopView *view=[sender.superview isKindOfClass:DesktopView.class]?(DesktopView *)sender.superview:nil;
    [self action:sender.identifier output:[view actionOutput]];
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
- (void)configureExitKey {
    if(self.hotkeyHandler)return;
    EventTypeSpec type={kEventClassKeyboard,kEventHotKeyPressed};OSStatus handler=InstallApplicationEventHandler(exitKey,1,&type,(__bridge void *)self,&_hotkeyHandler);EventHotKeyID key={'Infi',1};
    if(handler!=noErr||RegisterEventHotKey(53,controlKey|optionKey,key,GetApplicationEventTarget(),0,&_exitHotkey)!=noErr)self.statusText=@"Exit shortcut unavailable; use the visible Quit button.";
}
- (void)stopExitKey { if(self.exitHotkey){UnregisterEventHotKey(self.exitHotkey);self.exitHotkey=NULL;}if(self.hotkeyHandler){RemoveEventHandler(self.hotkeyHandler);self.hotkeyHandler=NULL;} }
// A normal run's global hot keys: the config's bindings, then the exit chord unless one
// of them claimed it. Windowed mode registers none. Returns the chords macOS refused.
- (NSArray<NSString *> *)startKeys {
    if(self.windowed)return @[];
    NSArray<NSString *> *refused=[self.hotKeys start];if(![self.hotKeys holds:exitChord()])[self configureExitKey];
    return refused;
}
- (void)stopKeys { [self.hotKeys stop];[self stopExitKey]; }
// Upstream's binding lookup for one press or scroll: physical modifiers, trigger and
// context in; the bound gesture, or nil for none, out. The binding carries the config's
// pointer speeds. Modifiers are JSON booleans: a boxed comparison would be sent as 0 or 1.
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window {
    NSDictionary *modifiers=@{@"control":flags&NSEventModifierFlagControl?@YES:@NO,@"option":flags&NSEventModifierFlagOption?@YES:@NO,@"shift":flags&NSEventModifierFlagShift?@YES:@NO,@"command":flags&NSEventModifierFlagCommand?@YES:@NO};
    NSDictionary *reply=[self call:@{@"op":@"mouse_binding",@"trigger":trigger,@"source":source?:NSNull.null,@"modifiers":modifiers,@"context":window?@"window":@"canvas"}],*binding=asDict(reply[@"binding"]);
    return binding;
}
// The pointer half of the help line, read from the lookup itself: every modifier set is
// asked for each trigger in both contexts, lightest chord first, and each gesture shows
// the first chord found on empty canvas and the first found on a window.
- (NSArray<NSString *> *)pointerHelp {
    NSArray<NSArray *> *triggers=@[@[@"left",NSNull.null,@"drag"],@[@"scroll",@"finger",@"scroll"],@[@"scroll",@"wheel",@"wheel"],@[@"right",NSNull.null,@"right-drag"],@[@"middle",NSNull.null,@"middle-drag"]];
    NSArray<NSString *> *kinds=@[@"pan_viewport",@"zoom",@"move_window",@"move_snapped_windows",@"resize_window"],*words=@[@"pan",@"zoom",@"move",@"cluster",@"resize"];
    NSMutableDictionary<NSString *,NSMutableArray<NSString *> *> *found=[NSMutableDictionary dictionary];NSString *status=self.statusText;
    for(int held=0;held<=4;held++)for(unsigned mask=0;mask<16;mask++){
        if(__builtin_popcount(mask)!=held)continue;
        UInt32 carbon=(mask&1?controlKey:0)|(mask&2?optionKey:0)|(mask&4?shiftKey:0)|(mask&8?cmdKey:0);
        NSEventModifierFlags flags=(mask&1?NSEventModifierFlagControl:0)|(mask&2?NSEventModifierFlagOption:0)|(mask&4?NSEventModifierFlagShift:0)|(mask&8?NSEventModifierFlagCommand:0);
        for(NSArray *trigger in triggers){
            BOOL scroll=[trigger[0]isEqual:@"scroll"];NSString *label=held?[NSString stringWithFormat:@"%@-%@",DWModifierGlyphs(carbon),trigger[2]]:trigger[2];
            NSString *canvas=asString([self mouseBinding:trigger[0] source:asString(trigger[1]) flags:flags window:NO][@"kind"]),*window=asString([self mouseBinding:trigger[0] source:asString(trigger[1]) flags:flags window:YES][@"kind"]);
            for(int place=0;place<2;place++){
                NSString *kind=place?window:canvas;BOOL camera=[kind isEqual:@"pan_viewport"]||[kind isEqual:@"zoom"];
                // A scroll only pans or zooms, and a button never zooms.
                if(!kind||(scroll?!camera:[kind isEqual:@"zoom"]))continue;
                NSMutableArray<NSString *> *chords=found[kind]?:(found[kind]=[@[@"",@""]mutableCopy]);if(chords[place].length)continue;
                // A camera chord good in one place only says which.
                chords[place]=[canvas isEqual:window]||!camera?label:[NSString stringWithFormat:@"%@ %@",place?@"window":@"canvas",label];
            }
        }
    }
    self.statusText=status;NSMutableArray<NSString *> *parts=[NSMutableArray array];
    for(NSUInteger i=0;i<kinds.count;i++){
        NSArray<NSString *> *chords=found[kinds[i]];if(!chords||(i==4&&!self.experimentalResize))continue;
        NSString *both=chords[0].length&&chords[1].length&&![chords[0]isEqual:chords[1]]?[NSString stringWithFormat:@"%@ or %@",chords[0],chords[1]]:chords[0].length?chords[0]:chords[1];
        [parts addObject:[NSString stringWithFormat:@"%@: %@",both,words[i]]];
    }
    return parts;
}
// The status line's help: the chords this run answers to.
- (NSString *)helpLine {
    NSMutableArray<NSString *> *parts=[[self pointerHelp]mutableCopy];
    if(self.windowed){[parts insertObject:@"Windowed, no global shortcuts" atIndex:0];[parts addObject:@"toolbar or Infinify msg: view actions and bookmarks"];return [parts componentsJoinedByString:@" · "];}
    NSString *(^chord)(NSString *)=^NSString *(NSString *action){return [self.hotKeys chords:action].firstObject;};
    // Four arrows or digits on one modifier set read as a single entry.
    NSString *(^family)(NSString *,NSArray<NSString *> *,NSArray<NSString *> *,NSString *)=^NSString *(NSString *action,NSArray<NSString *> *arguments,NSArray<NSString *> *names,NSString *range){
        NSString *modifiers=nil;
        for(NSUInteger i=0;i<arguments.count;i++){
            NSDictionary *key=nil;NSString *full=[NSString stringWithFormat:@"%@ %@",action,arguments[i]];
            for(NSDictionary *k in self.hotKeys.keys)if([k[@"action"]isEqual:full]&&[k[@"key"]isEqual:names[i]]){key=k;break;}
            if(!key||(modifiers&&![modifiers isEqual:key[@"modifiers"]]))return nil;modifiers=key[@"modifiers"];
        }
        return [modifiers stringByAppendingString:range];
    };
    for(NSArray<NSString *> *row in @[@[@"home-toggle",@"home"],@[@"zoom-to-fit",@"fit"],@[@"zoom-in",@"zoom in"],@[@"zoom-out",@"zoom out"],@[@"zoom-reset",@"1:1"]])if(chord(row[0]))[parts addObject:[NSString stringWithFormat:@"%@: %@",chord(row[0]),row[1]]];
    NSArray<NSString *> *arrows=@[@"left",@"right",@"up",@"down"],*arrowKeys=@[@"←",@"→",@"↑",@"↓"],*digits=@[@"1",@"2",@"3",@"4"];
    NSString *pan=family(@"pan-viewport",arrows,arrowKeys,@"-arrows"),*go=family(@"go-to-bookmark",digits,digits,@"1-4"),*set=family(@"set-bookmark",digits,digits,@"1-4");
    if(pan)[parts addObject:[pan stringByAppendingString:@": pan view"]];if(go)[parts addObject:[go stringByAppendingString:@": bookmark"]];if(set)[parts addObject:[set stringByAppendingString:@": set"]];
    if(![self.hotKeys holds:exitChord()])[parts addObject:@"⌃⌥Esc: exit"];
    return [parts componentsJoinedByString:@" · "];
}
- (NSString *)quitTitle { return self.windowed||[self.hotKeys holds:exitChord()]?@"Quit":@"Quit ⌃⌥Esc"; }
// A toolbar tooltip names the chords bound to its action: the config's in a normal run, the fixed one otherwise.
- (NSString *)tooltip:(NSArray<NSString *> *)row {
    NSString *chords=self.configured?[[self.hotKeys chords:row[1]]componentsJoinedByString:@" or "]:row[3];
    return self.windowed||!chords.length?row[2]:[NSString stringWithFormat:@"%@ (%@)",row[2],chords];
}
// After a config load on an open canvas: the Quit title, the tooltips and the
// placeholder hint follow the chords now bound, and the toolbar is laid out again.
- (void)refreshChrome {
    for(DesktopView *view in self.views){
        CGFloat x=12;
        for(NSView *subview in view.subviews.copy){
            NSButton *button=[subview isKindOfClass:NSButton.class]?(NSButton *)subview:nil;if(!button)continue;
            if(button.action==@selector(quit:))button.title=[self quitTitle];
            for(NSArray<NSString *> *row in toolbarActions())if([row[1]isEqual:button.identifier])button.toolTip=[self tooltip:row];
            x=toolbarButton(view,button,x);
        }
        for(NSString *key in view.tiles)if(!view.surfaces[key])for(CALayer *child in view.tiles[key].sublayers.copy)[child removeFromSuperlayer];
    }
    [self render];
}
// The controller's binding table as hot keys, help and tooltips: after every config
// load, and again whenever the keyboard input source changes. Returns what was left out.
- (NSArray<NSString *> *)refreshBindings {
    NSString *status=self.statusText,*help=self.help;NSMutableArray<NSString *> *notes=[NSMutableArray array];
    NSDictionary *bindings=[self call:@{@"op":@"bindings"}];if(!bindings)[notes addObject:self.statusText?:@"bindings unavailable"];
    for(id warning in asArray(bindings[@"warnings"]))if(asString(warning))[notes addObject:warning];
    if(!self.hotKeys){__weak Desktop *weak=self;self.hotKeys=[[DWHotKeys alloc]initWithFire:^(NSString *action){[weak action:action output:[weak viewOutput]];}];self.hotKeys.changed=^{Desktop *d=weak;NSArray<NSString *> *left=[d refreshBindings];for(NSString *line in left)fprintf(stderr,"%s\n",line.UTF8String);if(left.count){d.statusText=summary(@"Bindings",left);[d render];}};}
    BOOL open=self.panels.count!=0;if(open)[self stopKeys];
    // Option-Tab and Option-Shift-Tab stay with experimental navigation while its flag is on.
    NSString *owner=self.experimentalNavigation&&!self.windowed?@"experimental navigation":nil;
    [self.hotKeys setBindings:bindings reserved:owner?@{DWChord(48,optionKey):owner,DWChord(48,optionKey|shiftKey):owner}:@{}];
    [notes addObjectsFromArray:self.hotKeys.notes];
    self.dismissFree=![self mouseBinding:@"left" source:nil flags:NSEventModifierFlagControl|NSEventModifierFlagOption window:YES];
    self.statusText=status;if(open)[notes addObjectsFromArray:[self startKeys]];
    self.help=[self helpLine];if(help&&[self.statusText isEqual:help])self.statusText=self.help;
    if(open)[self refreshChrome];
    return notes;
}
// Startup, a change of the config file, the reload-config action, and a canvas reopened
// after Return to desktop. Reload semantics are the controller's, which are upstream's:
// a file that fails to parse leaves the previous config in force and says why.
- (void)loadConfig:(BOOL)platform {
    NSMutableArray<NSString *> *problems=[NSMutableArray array];
    if(platform&&![self call:@{@"op":@"set_platform",@"super":self.superChord?:@"ctrl+alt"}])[problems addObject:self.statusText?:@"set_platform failed"];
    NSDictionary *loaded=[self call:@{@"op":@"load_config",@"path":self.configPath?:NSNull.null}];if(!loaded)[problems addObject:self.statusText?:@"load_config failed"];
    // A reload can change what is saved (config bookmarks); the launch load precedes the scene and saves nothing.
    if(!platform&&[loaded[@"dirty"]isEqual:@YES])[self saveScene];
    for(NSString *key in @[@"errors",@"warnings"])for(id message in asArray(loaded[key]))if(asString(message))[problems addObject:message];
    NSString *path=asString(loaded[@"path"])?:self.configPath;NSArray<NSString *> *all=[problems arrayByAddingObjectsFromArray:[self refreshBindings]];
    for(NSString *line in all)fprintf(stderr,"%s\n",line.UTF8String);
    NSString *note=all.count?summary(problems.count?[@"Config " stringByAppendingString:(path?:@"").stringByAbbreviatingWithTildeInPath]:@"Bindings",all):nil;
    self.configNote=problems.count?note:nil;self.statusText=note?:[self restingStatus];
    if(!self.configWatcher){__weak Desktop *weak=self;self.configWatcher=[[DWConfigWatcher alloc]initWithChanged:^{[weak loadConfig:NO];}];}
    [self.configWatcher watch:path];[self render];
}
- (NSDictionary *)call:(NSDictionary *)command { return [self call:command raw:NULL]; }
// raw receives the controller's own response bytes.
- (NSDictionary *)call:(NSDictionary *)command raw:(NSData *__autoreleasing *)raw {
    NSData *request=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command} options:0 error:nil];
    char *response=driftwm_desktop_request(self.controller,request.bytes,request.length);if(!response){self.statusText=@"Controller unavailable";return nil;}
    NSData *data=[NSData dataWithBytes:response length:strlen(response)];driftwm_desktop_response_free(response);if(raw)*raw=data;
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![reply[@"ok"]boolValue]){self.statusText=reply[@"error"]?:@"Controller error";return nil;}return reply[@"data"];
}
// One upstream Request line from a client in, one upstream Reply line out, on the main
// queue. Every refusal is an {"Err":…} line; an answer is the controller's own bytes.
// Before the canvas opens there is no active output and the controller says so itself;
// after Return to desktop the shell is inert, and a failed load must not take changes.
- (NSData *)ipcLine:(NSData *)line {
    if(self.cleaning)return ipcError(@"the canvas is closed");
    if(self.startupError)return ipcError(self.startupError);
    if(self.resize&&![self.resize canRemove:nil])return ipcError(@"a native resize is pending");
    id request=[NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:nil];
    NSDictionary *command=request?@{@"op":@"ipc",@"output":[self viewOutput]?:NSNull.null,@"request":request}:nil;
    if(!command||![NSJSONSerialization isValidJSONObject:command])return ipcError(@"invalid request");
    NSString *status=self.statusText;NSData *raw=nil;NSDictionary *data=[self call:command raw:&raw];
    // A controller-level refusal still answers the client and leaves the status line alone.
    if(!asDict(data[@"reply"])){NSString *error=data?@"invalid controller reply":self.statusText?:@"controller error";self.statusText=status;return ipcError(error);}
    [self applyReply:data];
    return jsonMember(jsonMember(raw,"data"),"reply")?:[NSJSONSerialization dataWithJSONObject:data[@"reply"] options:NSJSONWritingWithoutEscapingSlashes error:nil];
}
// Normal runs only: main() starts the server once and stops it before the final cleanup.
- (void)startIPC:(NSString *)path {
    __weak Desktop *weak=self;NSString *error=nil;
    self.ipc=[DWIPCServer serverAtPath:path handler:^NSData *(NSData *line){return [weak ipcLine:line];} error:&error];
    if(!self.ipc){self.statusText=[NSString stringWithFormat:@"Running without IPC: %@ (%@)",error,path];fprintf(stderr,"%s\n",self.statusText.UTF8String);}
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
    panel.releasedWhenClosed=NO;panel.level=self.windowed?NSNormalWindowLevel:NSFloatingWindowLevel;panel.animationBehavior=NSWindowAnimationBehaviorNone;panel.collectionBehavior=NSWindowCollectionBehaviorMoveToActiveSpace|NSWindowCollectionBehaviorFullScreenAuxiliary;
    DesktopView *view=[[DesktopView alloc]initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];view.desktop=self;view.globalBounds=topRect(frame);view.outputs=[NSMutableArray array];view.tiles=[NSMutableDictionary dictionary];view.surfaces=[NSMutableDictionary dictionary];view.wantsLayer=YES;view.layer.backgroundColor=[NSColor colorWithSRGBRed:.045 green:.065 blue:.10 alpha:1].CGColor;panel.contentView=view;
    for(NSUInteger i=0;i<rects.count;i++){NSNumber *output=[self call:@{@"op":@"register_output",@"stable_id":identities[i],@"screen_bounds":rects[i]}][@"output"];if(output)[view.outputs addObject:output];}
    NSArray *names=self.ownedResizeProbe?@[]:@[@"Choose windows",@"Return to desktop",@"Resize status",[self quitTitle]];
    if(self.ownedResizeProbe)[view addSubview:label(@"Noninteractive owned resize probe — supervisor signal or deadline exits",NSMakeRect(15,8,720,26))];
    SEL actions[]={@selector(showChooser:),@selector(returnDesktop:),@selector(resizeUnavailable:),@selector(quit:)};
    CGFloat x=12;for(NSUInteger i=0;i<names.count;i++)x=toolbarButton(view,[NSButton buttonWithTitle:names[i] target:self action:actions[i]],x);
    if(!self.ownedResizeProbe){
        // The accessory app is rarely active, so tooltips must not wait for activation.
        if(!self.probe)panel.allowsToolTipsWhenApplicationIsInactive=YES;
        for(NSArray<NSString *> *row in toolbarActions()){NSButton *button=[NSButton buttonWithTitle:row[0] target:self action:@selector(viewButton:)];button.identifier=row[1];button.toolTip=[self tooltip:row];x=toolbarButton(view,button,x);}}
    if(self.experimentalNavigation){NSArray *titles=@[@"Center selected",@"Previous",@"Next"];for(NSUInteger i=0;i<titles.count;i++){NSButton *button=[NSButton buttonWithTitle:titles[i] target:self action:@selector(navigateButton:)];button.tag=i;x=toolbarButton(view,button,x);}}
    view.status=label(self.statusText,NSMakeRect(15,37,MAX(100,frame.size.width-30),22));view.status.textColor=NSColor.lightGrayColor;view.status.font=[NSFont systemFontOfSize:11];[view addSubview:view.status];
    [self.panels addObject:panel];[self.views addObject:view];if(self.ownedResizeProbe&&!rpBeforeOrder(panel)){self.probeHumanInput=YES;return view;}[panel orderFrontRegardless];return view;
}
- (void)openPanels {
    if(self.panels.count)return;self.cleaning=NO;
    // Return to desktop stopped the config watcher and dropped the key table: read the config again.
    if(self.configured&&!self.configWatcher)[self loadConfig:NO];
    if(self.demo){NSRect frame=NSMakeRect(100,120,1040,600);CGRect global=topRect(frame);NSMutableArray *rects=[NSMutableArray array];for(int i=0;i<2;i++)[rects addObject:rectJSON(CGRectOffset(ports[i],global.origin.x,global.origin.y))];[self panel:frame outputRects:rects identities:@[@"fixture-view-a",@"fixture-view-b"]];}
    // The analogue of upstream's nested winit backend: one ordinary window, one output.
    else if(self.windowed){NSScreen *screen=NSScreen.mainScreen?:NSScreen.screens.firstObject;NSRect area=screen.visibleFrame;CGFloat width=MIN(self.windowSize.width,area.size.width),height=MIN(self.windowSize.height,area.size.height);
        NSRect frame=NSMakeRect(floor(NSMidX(area)-width/2),floor(NSMidY(area)-height/2),width,height);CGRect output=topRect(frame);output.origin.y+=64;output.size.height-=64;
        if(screen)[self panel:frame outputRects:@[rectJSON(output)] identities:@[@"windowed"]];}
    else for(NSScreen *screen in NSScreen.screens){NSNumber *display=screen.deviceDescription[@"NSScreenNumber"];CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display.unsignedIntValue);NSString *name=uuid?CFBridgingRelease(CFUUIDCreateString(NULL,uuid)):nil;if(uuid)CFRelease(uuid);if(!name)continue;CGRect output=topRect(screen.frame);output.origin.y+=64;output.size.height-=64;[self panel:screen.frame outputRects:@[rectJSON(output)] identities:@[name]];}
    // Windowed mode registers no global hot key: toolbar, pointer and IPC only.
    if(self.configured){NSArray<NSString *> *refused=[self startKeys];if(refused.count)self.statusText=summary(@"Shortcut unavailable",refused);}
    else {
    if(!self.probe&&!self.ownedResizeProbe&&!self.windowed)[self configureViewKeys];
    if(!self.ownedResizeProbe&&!self.windowed)[self configureExitKey];
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
    [self stopKeys];[self stopViewKeys];
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
    if(self.cleaning)return;self.cleaning=YES;
    // Inert from here until the canvas reopens: no config hot key, key repeat, input-source observer or config watch outlives this line.
    [self.hotKeys invalidate];self.hotKeys=nil;[self.configWatcher stop];self.configWatcher=nil;
    [self.resize shutdown];[self stopNavigation];
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
    [self stopKeys];[self stopViewKeys];
    if(self.resizeKeyMonitor){[NSEvent removeMonitor:self.resizeKeyMonitor];self.resizeKeyMonitor=nil;}
    if(self.resizeGlobalKeyMonitor){[NSEvent removeMonitor:self.resizeGlobalKeyMonitor];self.resizeGlobalKeyMonitor=nil;}
    if(!self.sources.count)self.resize=nil;

}
- (void)dealloc { [_ipc stop];[self stopNavigation];[self stopViewKeys];[_hotKeys invalidate];[_configWatcher stop];if(_controller)driftwm_desktop_destroy(_controller); }
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

// WIDTHxHEIGHT in points, digits only. 960 wide keeps every toolbar button and the status line visible.
static BOOL parseWindowSize(const char *text,NSSize *size) {
    char *end=NULL;unsigned long width=strtoul(text,&end,10);if(*end!='x'||!isdigit((unsigned char)end[1]))return NO;
    unsigned long height=strtoul(end+1,&end,10);if(*end||width<960||width>16384||height<480||height>16384)return NO;
    *size=NSMakeSize(width,height);return YES;
}
int main(int argc,const char **argv) { @autoreleasepool {
    // The IPC client runs before any AppKit initialisation: no window, no privacy grant.
    if(argc>=2&&!strcmp(argv[1],"msg"))return driftwm_desktop_msg(argc-2,argv+2);
    if(argc>=2&&!strncmp(argv[1],"--owned-resize-",15))for(int i=2;i<argc;i++)if(!strcmp(argv[i],"--windowed")||!strcmp(argv[i],"--socket")||!strcmp(argv[i],"--config")||!strcmp(argv[i],"--super"))return 64;
    if(argc==3&&!strcmp(argv[1],"--owned-resize-check-restoration"))return ownedResizeCheckRestoration(@(argv[2]));
    if(argc==3&&!strcmp(argv[1],"--owned-resize-check-cleanup"))return ownedResizeCheckCleanup(@(argv[2]));
    if(argc>=2&&(!strcmp(argv[1],"--owned-resize-probe")||!strcmp(argv[1],"--owned-resize-fixture")))return ownedResizeEntry(argc,argv);
    BOOL experimental=NO,resize=NO,windowed=NO;const char *socket=NULL,*config=NULL,*chord=NULL;NSSize windowSize=NSMakeSize(1200,800);const char *filtered[argc+1];int count=0;
    for(int i=0;i<argc;i++){if(i>0&&!strcmp(argv[i],"--experimental-native-resize")){resize=YES;continue;}if(i>0&&!strcmp(argv[i],"--experimental-native-navigation")){experimental=YES;continue;}
        if(i>0&&!strcmp(argv[i],"--socket")){if(socket||i+1>=argc||argv[i+1][0]!='/')return 64;socket=argv[++i];continue;}
        if(i>0&&!strcmp(argv[i],"--config")){if(config||i+1>=argc||argv[i+1][0]!='/')return 64;config=argv[++i];continue;}
        // The chord's grammar is the controller's; one it rejects is reported in the status line.
        if(i>0&&!strcmp(argv[i],"--super")){if(chord||i+1>=argc||!argv[i+1][0])return 64;chord=argv[++i];continue;}
        if(i>0&&!strcmp(argv[i],"--windowed")){if(windowed)return 64;windowed=YES;if(i+1<argc&&isdigit((unsigned char)argv[i+1][0])&&!parseWindowSize(argv[++i],&windowSize))return 64;continue;}
        filtered[count++]=argv[i];}filtered[count]=NULL;argc=count;argv=filtered;

    if(argc==2&&!strcmp(argv[1],"--help")){puts("Infinify.app — macOS 26+ Apple Silicon native window canvas\nDefault: show chooser; only explicitly selected windows are captured. Open canvas shows the saved world without adding one.\n--owned-resize-probe EMPTY_DIRECTORY [SCENARIO]: explicit noninteractive owned-fixture resize probe (live)\n--demo EMPTY_DIRECTORY: disposable interactive fixture, bounded to 60 seconds\n--demo-probe EMPTY_DIRECTORY: automated own-fixture E2E, no permission prompts\n--demo-probe-guard EMPTY_DIRECTORY: own-fixture interruption regression (expected exit 2)\n--experimental-native-resize: experimental eight-handle size-only native resize\n--experimental-native-navigation: gated Center/Previous/Next and Option-Tab focus navigation\n--state ABSOLUTE_PATH: explicit persistent scene file (default Application Support/Infinify/scene.json)\n--socket ABSOLUTE_PATH: IPC socket of a normal run (default Application Support/Infinify/infinify.sock)\n--windowed [WIDTHxHEIGHT]: open the canvas at launch in one ordinary window (default 1200x800, at least 960x480) with no global shortcuts\n--config ABSOLUTE_PATH: DriftWM config file of a normal run (default $XDG_CONFIG_HOME/infinify/config.toml, else ~/.config/infinify/config.toml; DriftWM's built-in defaults when it is missing); read again whenever it changes\n--super CHORD: the physical keys of DriftWM's super/mod, a +-joined subset of ctrl|alt|cmd (default ctrl+alt)\nmsg [--json] [--socket PATH] COMMAND ...: DriftWM-style IPC client for the running app; opens no window\n--source DIR SECONDS NONCE: internal disposable child only\nKeys and pointer gestures are DriftWM's bindings from the config file: ctrl is Control, alt is Option, super (mod) is the --super chord. The status line shows the pointer, view, pan and bookmark chords registered, and each toolbar tooltip its own action's. With no config file and --super ctrl+alt the registered chords are:\n  Drag or two-finger scroll on empty canvas, Control-Option-drag or -scroll anywhere: pan. Wheel on empty canvas, Control-Option-wheel anywhere, pinch: anchored zoom (max 1x).\n  Option-drag on a window: world move/snap; add Shift: cluster.\n  View actions animate one view's camera only (toolbar Home, Fit, -, 1:1, + or global shortcuts while the canvas is open; held zoom, pan and nudge keys repeat):\n  Control-Option-A: home toggle (origin at 1:1, again to return). Control-Option-W: zoom-to-fit toggle.\n  Control-Option-Equals / Control-Option-Minus: zoom in / out. Control-Option-0 or Control-Option-Z: zoom 1:1.\n  Control-Option-Command-arrows: pan the view under the pointer. Control-Option-Shift-arrows: nudge the focused window.\n  Control-Option-1 to 4: fly to bookmark 1 to 4. Control-Option-Shift-1 to 4: set it.\n  Control-Option-Return: exec-terminal ($TERMINAL, else a new Terminal window). Control-Option-D: exec-launcher ($LAUNCHER, else Apps).\n  Control-Option-L: spawn swaylock -f -c 000000 -kl, DriftWM's default lock command, which macOS lacks; it repeats while held. Rebind or unbind it in the config file.\nThe fixture modes (--demo*, --owned-resize-*) read no config and keep Option-drag pan, Command-wheel zoom and Control-Option-drag move.\nAn unbound click, drag or scroll on a window (left, right or middle button) is forwarded only to its selected, freshly validated source.\nNative keyboard/IME remain with the real app. Control-Option-Escape (until a binding takes that chord), Control-Option-Command-Shift-Q or Quit exits.\nResize status explains unavailable native layout resizing. No SIP/settings changes.");return 0;}
    BOOL child=argc==5&&!strcmp(argv[1],"--source"),demo=argc==3&&!strcmp(argv[1],"--demo"),guard=argc==3&&!strcmp(argv[1],"--demo-probe-guard"),probe=argc==3&&!strcmp(argv[1],"--demo-probe"),state=argc==3&&!strcmp(argv[1],"--state");
    if(argc!=1&&!child&&!demo&&!probe&&!guard&&!state)return 64;
    if((experimental||resize)&&(child||probe||guard))return 64;
    if((windowed||socket||config||chord)&&(child||demo||probe||guard))return 64;
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [ProbeApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    if(child){char *end=NULL;double seconds=strtod(argv[3],&end);if(!end||*end||!isfinite(seconds)||seconds<1||seconds>65)return 64;return source(@(argv[2]),seconds,@(argv[4]));}
    Desktop *desktop=[Desktop new];desktop.experimentalNavigation=experimental;desktop.experimentalResize=resize;desktop.demo=demo||probe||guard;desktop.probe=probe||guard;desktop.interruptProbe=guard;desktop.windowed=windowed;desktop.windowSize=windowSize;
    if(demo||probe||guard){NSString *dir=@(argv[2]);BOOL isDir=NO;if(![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir]||!isDir||[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil].count)return 64;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];return runDemo(desktop,dir,probe||guard);}
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Infinify"];
    if(state){desktop.statePath=@(argv[2]);if(!desktop.statePath.isAbsolutePath)return 64;if(!socket)[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];}
    else {if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])return 2;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];}
    // Before the scene: the config decides what a load restores.
    desktop.configured=YES;desktop.configPath=config?@(config):nil;desktop.superChord=chord?@(chord):nil;[desktop loadConfig:YES];
    [desktop loadScene:desktop.statePath];
    // The app serves --socket or the default path only; INFINIFY_SOCKET is the client's.
    [desktop startIPC:socket?@(socket):[dir stringByAppendingPathComponent:@"infinify.sock"]];
    [[NSNotificationCenter defaultCenter]addObserver:desktop selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    if(windowed&&!desktop.startupError)[desktop openCanvas:nil];else [desktop showChooser:nil];
    while(!stopped){[desktop poll];pump(.08);}
    // Stopped first: the pending quit reply is written, and no request can arrive during cleanup.
    [desktop.ipc stop];desktop.ipc=nil;[desktop cleanup];[desktop.chooser close];return 0;
} }
