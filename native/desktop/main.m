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
#import "cycle-hold.h"
#import "hot-corners.h"
#import "input-sources.h"
#import "window-manager.h"
#import "pan-launch.h"
#import "trackpad-gestures.h"
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
// Is `named`, an identity the controller wrote, exactly the one this shell bound? The
// shell binds no WindowServer owner, so a named one never matches.
static BOOL boundIdentity(NSDictionary *bound,NSDictionary *named) {
    if(!bound||!asDict(named)||asNumber(named[@"owner"]))return NO;
    for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec",@"wid"])if(!asNumber(named[key])||![bound[key]isEqual:named[key]])return NO;
    return YES;
}
// An input event's time as upstream's libinput timestamp: milliseconds, wrapping at 32 bits.
static NSNumber *eventMillis(NSEvent *e) { return @((uint32_t)(uint64_t)(e.timestamp*1000)); }
// Physical modifiers as the controller reads them: JSON booleans, since a boxed comparison would be sent as 0 or 1.
static NSDictionary *modifiersJSON(NSEventModifierFlags flags) { return @{@"control":flags&NSEventModifierFlagControl?@YES:@NO,@"option":flags&NSEventModifierFlagOption?@YES:@NO,@"shift":flags&NSEventModifierFlagShift?@YES:@NO,@"command":flags&NSEventModifierFlagCommand?@YES:@NO}; }
// The first line and how many follow: the status line has room for one.
static NSString *summary(NSString *subject,NSArray<NSString *> *lines) { return [NSString stringWithFormat:@"%@: %@%@",subject,lines[0],lines.count>1?[NSString stringWithFormat:@" (+%lu more)",(unsigned long)lines.count-1]:@""]; }
// The exec effect, as upstream's exec_command: /bin/sh -c in a session of its own on
// /dev/null, with no other descriptor inherited and never waited on by the main loop.
// env overlays this process's environment; a null value removes the variable.
// `missing` runs on the main queue when sh exits as it does for a program it
// cannot find (127) or cannot execute (126).
static NSString *execCommand(NSString *command,NSDictionary *env,void (^missing)(void)) {
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
    dispatch_source_set_event_handler(exited,^{int status=0;pid_t reaped=waitpid(pid,&status,0);dispatch_source_cancel(exited);if(missing&&reaped==pid&&WIFEXITED(status)&&(WEXITSTATUS(status)==127||WEXITSTATUS(status)==126))dispatch_async(dispatch_get_main_queue(),missing);});
    dispatch_resume(exited);return nil;
}
// Said once per run, on stderr and in the status line, when a normal run has no Accessibility access.
static NSString *const focusAccessNote=@"Native window focus needs Accessibility access: focus is logical only; navigation still works.";
// Probe, demo and owned-fixture runs: their fixed gestures and chords. A normal run
// builds its help from the bindings the config gives it.
static NSString *const helpText=@"Option-drag: pan · ⌘-wheel/pinch: zoom · ⌃⌥-drag: move · +Shift: cluster · ⌃⌥A: home · ⌃⌥W: fit · ⌃⌥=/-/0: zoom · ⌃⌥⌘-arrows: pan view · ⌃⌥1-4: bookmark (⇧ sets) · ⌃⌥Esc: exit";
// Toolbar view actions: title, upstream action, tooltip, and the fixed chord of the runs above.
// A normal run adds window navigation: center-window and one cycle-windows step each way.
static NSArray<NSArray<NSString *> *> *toolbarActions(BOOL navigation) {
    NSArray<NSArray<NSString *> *> *view=@[@[@"Home",@"home-toggle",@"Home: origin at 1:1; again returns to the previous view",@"⌃⌥A"],@[@"Fit",@"zoom-to-fit",@"Zoom to fit every window; again returns to the previous view",@"⌃⌥W"],@[@"−",@"zoom-out",@"Zoom out",@"⌃⌥-"],@[@"1:1",@"zoom-reset",@"Zoom 1:1",@"⌃⌥0 or ⌃⌥Z"],@[@"+",@"zoom-in",@"Zoom in",@"⌃⌥="]];
    return navigation?[view arrayByAddingObjectsFromArray:@[@[@"Center",@"center-window",@"Center the focused window, or the one nearest the middle of the view, at 1:1",@""],@[@"Previous",@"cycle-windows backward",@"Previous window, most recently focused first",@""],@[@"Next",@"cycle-windows forward",@"Next window, most recently focused first",@""]]]:view;
}
// Fitted widths keep every toolbar button inside the 1040 px demo panel and, with window navigation, the 960 px windowed minimum.
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
// A managed run: the window the stream is made from, the title last reported, and
// whether the last frame is kept, while the stream runs, for a placement that returns.
@property SCWindow *window;
@property NSString *title;
@property BOOL keepSample;
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
    else if(self.keepSample){[self clearSample];self.latestSample=(CMSampleBufferRef)CFRetain(sample);}
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
@property BOOL clearsFocus; // a pan begun on empty canvas that has not moved 5 points yet: released so, it unfocuses
@property NSNumber *clickWindow; // the window an unbound press focused: released within 5 points, it is a completed click
@property NSNumber *scrollPan; // the output the trackpad scroll under way, or just lifted, panned; nil for none
@property NSTimeInterval scrollPanTime; // event time of that scroll's last pan, 0 once a press has ended it
@property NSTimeInterval lastDragPan; // event time of the last timed pan under this drag pan's button, its own or a scroll's; 0 for none
- (void)render:(NSDictionary *)snapshot;
- (NSNumber *)outputAt:(CGPoint)p;
- (NSNumber *)actionOutput;
- (BOOL)forward:(CGEventRef)event at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate;
@end
@interface Desktop : NSObject <NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate,DWWindowHost>
@property DriftDesktop *controller;
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
@property CFMachPortRef navigationTap;
@property CFRunLoopSourceRef navigationTapSource;
@property BOOL logicalFocus; // --no-native-focus: no native window is ever activated or raised
@property BOOL focusNoted; // the status line has said that native focus lacks Accessibility
@property DWCycleHold *cycleHold;
@property UInt32 cycleModifiers; // Carbon mask of upstream's cycle_hold
- (void)cancelNavigation;
- (void)configureNavigation;
- (void)stopNavigation;
- (void)activate:(NSNumber *)window output:(NSNumber *)output;
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output;
- (void)clearFocus;
- (void)ensureFrames;
- (BOOL)cameraFrame;
@property BOOL flying;
// Normal runs only: camera motion as DriftWM's. A released pan coasts in the controller;
// the shell says when a pan ends, and where the pointer is while cursor edge pan wants it.
@property DWPanLaunch *panLaunch;
@property NSArray<NSDictionary *> *pointerOutputs; // the latest snapshot's outputs while it asks for the pointer, else nil
- (void)panEnd:(NSNumber *)output;
@property EventHandlerRef viewHandler;
@property BOOL viewKeysWarned;
@property NSUInteger statusToken;
- (NSNumber *)viewOutput;
- (void)action:(NSString *)action output:(NSNumber *)output;
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held;
- (void)applyReply:(NSDictionary *)reply;
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
// Normal runs only: trackpad gestures by DriftWM's [gestures] tables. Three or more
// fingers arrive as raw touches, and DWTrackpadGestures makes libinput's swipe, pinch
// and hold of them; a two-finger pinch is AppKit's magnify stream. The controller
// holds one gesture at a time and decides what it does.
@property DWTrackpadGestures *trackpad;
@property NSTimer *trackpadTimer; // armed for trackpadDeadline, the recogniser's next: hold delay, finger-count debounce
@property NSTimeInterval trackpadDeadline;
@property NSInteger gestureOwner; // whose gesture the controller holds: 0 none, 1 the recogniser's, 2 magnify's
@property NSNumber *gestureOutput; // the output that gesture began on
@property BOOL magnifying; // a magnify stream is running, whether or not the controller took it
@property double magnifyScale; // its scale since it began
@property NSTimeInterval lastTouches; // when the last frame of touches came
- (void)touches:(NSEvent *)event;
- (void)magnify:(NSEvent *)event;
- (BOOL)padBusy:(NSEvent *)event;
- (void)cancelGestures;
@property BOOL windowed;
@property NSSize windowSize;
@property DWIPCServer *ipc;
- (void)startIPC:(NSString *)path;
@property NSString *socketPath; // the socket this instance serves; nil while IPC is not up
// Normal runs only, like the config they come from: hot corners, the keyboard
// layout report, the IPC event stream and autostart.
@property DWHotCorners *corners;
@property NSTimer *statePush; // the one pending event for IPC subscribers
@property CFTimeInterval lastStatePush;
@property NSArray *autostart; // the launch load's exec effects until they have run
- (void)watchCorners;
- (void)publishState;
- (void)runAutostart;
// A normal run without --manual: every ordinary application window lives on the
// canvas, as every toplevel does in DriftWM. The manager exists only while the canvas
// is open and Screen Recording access is granted; without it this run is the manual one.
@property BOOL managing;
@property DWWindowManager *manager;
@property BOOL adopted; // adoption_complete was sent for the manager in place
@property NSString *discoveryNote; // the failed-read note last written to stderr
@property BOOL sceneDirty; // a window came, went or was renamed: saved on the next poll

@property NSMutableArray<NSPanel *> *panels;
@property NSMutableArray<DesktopView *> *views;
@property NSMutableDictionary<NSNumber *,LiveSource *> *sources;
@property NSMutableArray<NSDictionary *> *choices;
@property NSMutableArray *pendingStops; // sources being detached, and streams stopped on demand
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
// Is the native window behind a source gone: its process ended or was replaced, or the
// window list (`info`, for its window number) no longer has it under that owner?
static BOOL sourceGone(LiveSource *source,NSDictionary *info) { return ![birth(source.router.pid)isEqual:source.router.processBirth]||[info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid; }
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
            // A still window sends no frame: its kept one fills a placement that came back.
            if(!source.resize&&newSurface&&source.latestSample&&surface.sampleBufferRenderer.readyForMoreMediaData)[surface.sampleBufferRenderer enqueueSampleBuffer:source.latestSample];
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
// Probe, demo and owned-fixture runs: app activation and logical focus of one source's
// window. A normal run's click goes through -[Desktop activate:output:] instead.
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
    NSArray<NSString *> *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];LiveSource *source=hit?self.desktop.sources[hit[@"window"]]:nil;self.lastScrollPan=0;self.clearsFocus=NO;
    NSDictionary *binding=button<(NSInteger)triggers.count?[self.desktop mouseBinding:triggers[button] source:nil flags:e.modifierFlags window:hit!=nil]:nil;NSString *kind=asString(binding[@"kind"]),*action=asString(binding[@"action"]);
    BOOL move=[kind isEqual:@"move_window"]||[kind isEqual:@"move_snapped_windows"],resize=[kind isEqual:@"resize_window"]||[kind isEqual:@"resize_window_snapped"];
    // ⌃⌥-click still dismisses a detached placeholder while no binding claims that press.
    if(!binding&&!button&&hit&&!source&&(e.modifierFlags&NSEventModifierFlagControl)&&(e.modifierFlags&NSEventModifierFlagOption)){[self.desktop call:@{@"op":@"forget",@"window":hit[@"window"]}];[self.desktop render];[self.desktop saveScene];return;}
    if(move&&hit){if([self.desktop call:@{@"op":@"begin_drag",@"window":hit[@"window"],@"output":output,@"group":@([kind isEqual:@"move_snapped_windows"])}])self.gesture=2;}
    else if(resize&&hit)[self beginResize:hit[@"window"] snapped:[kind isEqual:@"resize_window_snapped"] at:p output:output];
    // Upstream's pan grab remembers that it began on empty canvas: released without a drag, it unfocuses.
    else if([kind isEqual:@"pan_viewport"]){self.gesture=1;self.clearsFocus=!hit;}
    else if([kind isEqual:@"center_nearest"])[self.desktop flashStatus:@"center-nearest by pointer is not implemented yet"];
    // Upstream raises and focuses the window under the pointer, stand-ins included, then runs the action on it.
    else if([kind isEqual:@"action"]&&action){if(hit)[self.desktop applyReply:[self.desktop call:@{@"op":@"focus",@"window":hit[@"window"]}]];[self.desktop action:action output:output at:p held:[DWCycleHold modifiersDown]!=0];return;}
    // Unbound, or bound to a gesture with nothing to act on here: click-to-focus, then the press is the native window's.
    else if(hit){self.gesture=3;self.clickWindow=hit[@"window"];[self.desktop activate:hit[@"window"] output:output];CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output activate:NO];CFRelease(cg);}
    [self.desktop render];
}
- (void)mouseDown:(NSEvent *)e {
    if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;}
    // One gesture at a time: another button waits until the first is released.
    NSInteger button=self.desktop.configured?e.buttonNumber:0;if(self.gesture&&button!=self.gestureButton)return;
    // A press is a fresh interaction, as upstream. It ends an open cycle as letting go of its modifiers does, committing a
    // settled selection as upstream's focus_changed commits it. The pad is one device: in a normal run the press then ends
    // a trackpad gesture in progress, cancelled, so that the coast a pan's end launches stops with the rest. Only then is
    // the focus request still in flight withdrawn and every flight and coast stopped, and a scroll pan still waiting to
    // launch never does, at its delay or at the lift of fingers still down.
    self.clickWindow=nil;[self.desktop.navigation releaseCycle];if(self.desktop.configured)[self.desktop cancelGestures];[self.desktop cancelNavigation];[self.desktop.panLaunch cancel];self.scrollPanTime=0;
    if(self.desktop.resize&&![self.desktop.resize canRemove:nil]){[self.desktop.resize cancel];return;}
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.startPoint=self.lastPoint=p;self.dragOutput=self.lastOutput=output;self.gestureButton=button;self.lastDragPan=0;
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
    else if(self.gesture==1){
        if(hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)>=5)self.clearsFocus=NO;
        // A normal run's drag pan is timed, for the coast its release launches.
        if(self.desktop.configured){[self pan:CGPointMake(self.lastPoint.x-p.x,self.lastPoint.y-p.y) output:self.dragOutput event:e source:@"drag"];self.lastDragPan=e.timestamp;}
        else [self.desktop call:@{@"op":@"pan",@"output":self.dragOutput,@"screen_delta":pointJSON(CGPointMake(self.lastPoint.x-p.x,self.lastPoint.y-p.y))}];
    }
    // A normal run's window drag says where the pointer is: inside navigation.edge_pan's zone
    // the controller pans under the window frame by frame, also while the pointer rests there.
    else if(self.gesture==2&&self.desktop.configured){if([[self.desktop call:@{@"op":@"gesture_to",@"screen_delta":pointJSON(CGPointMake(p.x-self.startPoint.x,p.y-self.startPoint.y)),@"pointer":pointJSON(p)}][@"needs_frames"]boolValue])[self.desktop ensureFrames];}
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
- (void)mouseUp:(NSEvent *)e { if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;} if(self.desktop.configured&&e.buttonNumber!=self.gestureButton)return;if(self.gesture==4)[self.desktop.resize request:@{@"op":@"end_native_resize",@"transaction":self.resizeTransaction}];self.resizeTransaction=nil;[self releasePressed];
    // Upstream resolve_click_navigate, after the release is forwarded: the button lifted within 5 points of its press, on the same output.
    NSNumber *clicked=self.clickWindow;self.clickWindow=nil;CGPoint p=[self screenPoint:e];
    if(self.gesture==3&&clicked&&hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)<=5&&[[self outputAt:p]isEqual:self.dragOutput])[self.desktop clickReleased:clicked output:self.dragOutput];
    if(self.gesture==2)[self.desktop call:@{@"op":@"end_gesture"}];
    // A normal run's drag pan coasts from its release, as upstream's pan grab launches momentum.
    // A drag that rested first does not: upstream's 50 ms delay has by then launched it into
    // the held grab, where nothing coasts, and the release finds no velocity left. The
    // second launch here is that one.
    if(self.gesture==1&&self.desktop.configured&&self.lastDragPan){[self.desktop panEnd:self.dragOutput];if(e.timestamp-self.lastDragPan>=.05)[self.desktop panEnd:self.dragOutput];}
    if(self.gesture==1&&self.clearsFocus)[self.desktop clearFocus];self.clearsFocus=NO;self.gesture=0;[self.desktop saveScene]; }
- (void)zoom:(double)factor at:(CGPoint)p output:(NSNumber *)output {
    for(NSDictionary *o in [self.desktop call:@{@"op":@"snapshot"}][@"outputs"])if([o[@"id"] isEqual:output]){[self.desktop call:@{@"op":@"zoom",@"output":output,@"zoom":@(MAX(.001,MIN(1,[o[@"zoom"] doubleValue]*factor))),@"anchor":pointJSON(p)}];break;}
    [self.desktop render];[self.desktop saveScene];
}
// A normal run's pan, timed: the controller scales it by the config speed of its source
// (navigation.trackpad_speed for a scroll, navigation.mouse_speed for a drag), clears the
// output's flight as every pan does, and tracks its velocity for the coast that follows.
- (void)pan:(CGPoint)delta output:(NSNumber *)output event:(NSEvent *)e source:(NSString *)source {
    [self.desktop call:@{@"op":@"pan",@"output":output,@"screen_delta":pointJSON(delta),@"time_ms":eventMillis(e),@"source":source}];
}
// A normal run's wheel zoom: zoom.step, zoom.mouse_speed and the zoom limits are the
// controller's, as upstream's. delta is upstream's vertical axis amount (positive scrolls
// down and zooms out). A wheel zoom is a flight that later notches extend, so no flight is
// cancelled first. A pinch is not sent here: it is a gesture, see -magnifyWithEvent:.
- (void)wheelZoom:(double)delta at:(CGPoint)p output:(NSNumber *)output {
    // The controller refuses a pointer zoom while it holds a window drag; the input is dropped, not sent to fail.
    if(!isfinite(delta)||!delta||self.gesture==2)return;
    NSDictionary *reply=[self.desktop call:@{@"op":@"zoom_by",@"output":output,@"anchor":pointJSON(p),@"delta":@(delta),@"source":@"wheel"}];BOOL frames=[reply[@"needs_frames"]boolValue];
    // A zoom the limit swallows is no input for a focus request in flight either.
    if(asDict(reply[@"navigation"]))[self.desktop.navigation interrupt];
    [self.desktop render];if(frames)[self.desktop ensureFrames];[self.desktop saveScene];
}
// A normal run's scroll, dispatched as upstream's on_pointer_axis does: a bound scroll
// pans or zooms the canvas and never reaches a window, an unbound one goes to the
// native window under it. A pan or zoom ends its output's flight in the controller, which
// keeps the pan's velocity for the coast; the shell only withdraws a native focus request
// still in flight, as for any unrelated input. An open cycle whose selection has settled
// stays open until its modifiers are let go, as upstream's does.
- (void)scroll:(NSEvent *)e {
    BOOL coast=e.momentumPhase!=NSEventPhaseNone,lifted=(e.phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0;
    // Upstream computes momentum itself from the finger's deltas. Once a trackpad scroll has
    // panned the canvas its lift launches the coast, and the momentum events macOS adds
    // after it are dropped whole, wherever the pointer is by then. A lift that follows a
    // rest comes after the 50 ms delay has launched, and upstream's stop then launches the
    // emptied tracker: what was left of the coast ends. The second launch here is that one.
    // Under a held drag pan neither is sent: see where the scroll pans.
    if(self.scrollPan&&(coast||lifted)){
        if(lifted){[self.desktop.panLaunch end];if(self.scrollPanTime&&e.timestamp-self.scrollPanTime>=.05&&!(self.gesture==1&&[self.scrollPan isEqual:self.dragOutput]))[self.desktop panEnd:self.scrollPan];}
        else if(e.momentumPhase&(NSEventPhaseEnded|NSEventPhaseCancelled))self.scrollPan=nil;
        return;
    }
    if(e.phase&(NSEventPhaseBegan|NSEventPhaseMayBegin))self.scrollPan=nil;
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.lastOutput=output;BOOL precise=e.hasPreciseScrollingDeltas;NSString *source=precise?@"finger":@"wheel";
    // A swipe or pinch of three or more fingers is the recogniser's: a scroll macOS makes of the same fingers pans nothing.
    if(precise&&[self.desktop padBusy:e])return;
    // Upstream keeps a finger pan on the canvas for 150 ms, so a window sliding under the pointer cannot take the gesture.
    BOOL panning=self.lastScrollPan&&CACurrentMediaTime()-self.lastScrollPan<.15,window=!panning&&[[self hit:p output:output]isKindOfClass:NSDictionary.class];
    NSDictionary *binding=[self.desktop mouseBinding:@"scroll" source:source flags:e.modifierFlags window:window];NSString *kind=asString(binding[@"kind"]);
    // A window that takes over a trackpad scroll which panned first takes the rest of it: its end and macOS's inertia are forwarded too.
    if(!binding){if(window){if(e.phase!=NSEventPhaseNone){self.scrollPan=nil;self.scrollPanTime=0;}CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:output activate:NO];CFRelease(cg);}return;}
    // Upstream's axis amounts: positive scrolls right and down, finger points as they are, one wheel line as one notch of 15.
    double h=-e.scrollingDeltaX,v=-e.scrollingDeltaY;
    if(!precise&&e.CGEvent){h=-15.0*CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis2);v=-15.0*CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis1);}
    if([kind isEqual:@"zoom"])[self wheelZoom:v at:p output:output];
    // A momentum event of macOS never pans the canvas: not the tail of a scroll that began in a window either.
    else if([kind isEqual:@"pan_viewport"]&&!coast&&(h||v)){
        if(precise)self.lastScrollPan=CACurrentMediaTime();
        if(e.phase!=NSEventPhaseNone){self.scrollPan=output;self.scrollPanTime=e.timestamp;}
        // A scroll under a held drag pan launches nothing of its own: upstream's pan grab holds the coast
        // until its release, so the pan counts as the drag's last and the release's pan_end is the launch.
        [self.desktop.navigation interrupt];[self pan:CGPointMake(h,v) output:output event:e source:source];if(self.gesture==1&&[output isEqual:self.dragOutput])self.lastDragPan=e.timestamp;else [self.desktop.panLaunch panned:output];[self.desktop render];[self.desktop saveScene];
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
- (void)magnifyWithEvent:(NSEvent *)e {
    // A normal run's pinch is a gesture binding: the [gestures] table decides what it does.
    if(self.desktop.configured){[self.desktop magnify:e];return;}
    // Fixed gesture of probe, demo and owned-fixture runs.
    if(self.desktop.resize&&![self.desktop.resize canRemove:nil])return; [self.desktop cancelNavigation]; if(self.desktop.probe){self.desktop.probeHumanInput=YES;return;} CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(output){self.lastOutput=output;[self zoom:1+e.magnification at:p output:output];}
}
// Raw trackpad touches reach a view only in a normal run, which alone asks for them.
- (void)touchesBeganWithEvent:(NSEvent *)e { if(self.desktop.configured)[self.desktop touches:e];else [super touchesBeganWithEvent:e]; }
- (void)touchesMovedWithEvent:(NSEvent *)e { if(self.desktop.configured)[self.desktop touches:e];else [super touchesMovedWithEvent:e]; }
- (void)touchesEndedWithEvent:(NSEvent *)e { if(self.desktop.configured)[self.desktop touches:e];else [super touchesEndedWithEvent:e]; }
// macOS took the touches for a gesture of its own: each arrives cancelled, which ends ours cancelled.
- (void)touchesCancelledWithEvent:(NSEvent *)e { if(self.desktop.configured)[self.desktop touches:e];else [super touchesCancelledWithEvent:e]; }
@end
// Optional, and only where Input Monitoring is already granted: a press or scroll outside
// the canvas while a native focus request is in flight withdraws that request. Listen-only,
// and nothing depends on it. A press on the canvas is its view's to handle; keys and
// modifiers are never observed, so a binding's own release cannot cancel what it began.
static CGEventRef navigationInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;Desktop *desktop=(__bridge Desktop *)context;
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){[desktop.navigation interrupt];if(desktop.navigationTap)CGEventTapEnable(desktop.navigationTap,true);return event;}
    CGPoint point=CGEventGetLocation(event);for(DesktopView *view in desktop.views)if(CGRectContainsPoint(view.globalBounds,point))return event;
    [desktop.navigation interrupt];return event;
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
    if((self=[super init])){_controller=driftwm_desktop_create();_panels=[NSMutableArray array];_views=[NSMutableArray array];_sources=[NSMutableDictionary dictionary];_choices=[NSMutableArray array];_pendingStops=[NSMutableArray array];_statusText=helpText;
        __weak Desktop *weak=self;_panLaunch=[[DWPanLaunch alloc]initWithLaunch:^(NSNumber *output){[weak panEnd:output];}];}
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
// Every normal run: the coordinator ticks camera flights, performs the controller's focus
// requests on native windows and follows native focus the user moved. Probe, demo and
// owned-fixture runs have none and keep their fixed click activation.
- (void)configureNavigation {
    if(!self.configured||self.navigation)return;
    __weak Desktop *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.navigation",DISPATCH_QUEUE_SERIAL);
    self.navigation=[[DWNavigationCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak call:c];} driver:[DWNativeFocusDriver new] clock:^uint64_t{return (uint64_t)(CACurrentMediaTime()*1e9);} worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.navigation.enabled=YES;self.cycleHold=[DWCycleHold new];
    self.navigation.changed=^{[weak render];[weak ensureFrames];};
    self.navigation.settled=^{[weak saveScene];};
    self.navigation.output=^NSNumber *{return [weak viewOutput];};
    [self refreshFocusAccess];
    // Never asked for: the observer exists only where the user has already granted Input Monitoring.
    if(!self.logicalFocus&&CGPreflightListenEventAccess()){
        CGEventMask mask=CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventScrollWheel);
        self.navigationTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,navigationInput,(__bridge void *)self);
        if(self.navigationTap){self.navigationTapSource=CFMachPortCreateRunLoopSource(NULL,self.navigationTap,0);if(self.navigationTapSource)CFRunLoopAddSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);}
    }
    [self.navigation frame];
}
// Native focus needs Accessibility, which can be granted while the app runs, and
// --no-native-focus turns it off. Without it focus is logical and navigation still works.
- (void)refreshFocusAccess {
    BOOL trusted=AXIsProcessTrusted();self.navigation.focusAllowed=trusted&&!self.logicalFocus;
    if(trusted||self.logicalFocus||self.focusNoted||!self.navigation)return;
    self.focusNoted=YES;NSString *note=focusAccessNote;
    // Said once, ahead of a notice already up; the config's own problem returns as the resting status.
    fprintf(stderr,"%s\n",note.UTF8String);self.statusText=!self.statusText.length||[self.statusText isEqual:self.help]?note:[NSString stringWithFormat:@"%@ · %@",note,self.statusText];
}
- (void)cancelNavigation {
    [self.navigation invalidate];
    // Without the coordinator, pointer intent still stops every view-action flight.
    if(!self.navigation)for(DesktopView *view in self.views)for(NSNumber *output in view.outputs)[self call:@{@"op":@"cancel_navigation",@"output":output}];
}
- (void)stopNavigation {
    [self.cycleHold stop];self.cycleHold=nil;[self.navigation shutdown];self.navigation=nil;[self.frameTimer invalidate];self.frameTimer=nil;self.flying=NO;
    if(self.navigationTapSource){CFRunLoopRemoveSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);CFRelease(self.navigationTapSource);self.navigationTapSource=NULL;}
    if(self.navigationTap){CFMachPortInvalidate(self.navigationTap);CFRelease(self.navigationTap);self.navigationTap=NULL;}
}
// Cursor edge pan: while the controller's snapshot asks for it, where the pointer is and
// which output it is on, before each tick. It is on an output only where a press would
// reach that output's panel, so a canvas behind another window does not pan. The answer
// is the controller's to use; a refusal leaves the status line alone. Nothing is reported
// while a panel holds a button gesture: upstream's refresh stands down under any pointer
// grab, and the controller knows only its own, not a press forwarded to a native window.
- (void)reportPointer {
    if(!self.pointerOutputs)return;
    for(DesktopView *view in self.views)if(view.gesture)return;
    CGPoint p=pointer();id output=NSNull.null;NSString *status=self.statusText;
    NSInteger top=[NSWindow windowNumberAtPoint:NSEvent.mouseLocation belowWindowWithWindowNumber:0];
    for(DesktopView *view in self.views)if(view.window.windowNumber==top)for(NSDictionary *o in self.pointerOutputs)if([view.outputs containsObject:o[@"id"]]&&CGRectContainsPoint(jsonRect(o[@"screen_bounds"]),p))output=o[@"id"];
    [self call:@{@"op":@"pointer",@"output":output,@"screen":pointJSON(p)}];self.statusText=status;
}
// One frame of camera motion: every armed flight, a coasting pan, an edge pan. A normal
// run's coordinator owns the tick; probe, demo and owned-fixture runs tick the controller
// themselves on the same clock.
- (BOOL)cameraFrame {
    if(self.cleaning)return NO;
    [self reportPointer];
    if(self.navigation)return [self.navigation frame];
    NSDictionary *result=[self call:@{@"op":@"tick_navigation",@"timestamp_ns":@((uint64_t)(CACurrentMediaTime()*1e9))}];
    if([result[@"changed_outputs"]count])[self render];
    BOOL active=[result[@"needs_frames"]boolValue];if(!active&&self.flying)[self saveScene];self.flying=active;return active;
}
// 60 Hz from the next frame on, for as long as tick_navigation reports needs_frames. Only
// the controller knows what is in motion, so the first frame asks it and stops the timer
// when nothing is.
- (void)ensureFrames {
    if(self.frameTimer||self.cleaning)return;
    __weak Desktop *weak=self;self.frameTimer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer){Desktop *desktop=weak;[desktop watchCorners];if(!desktop||![desktop cameraFrame]){[timer invalidate];desktop.frameTimer=nil;}}];
    [[NSRunLoop mainRunLoop]addTimer:self.frameTimer forMode:NSRunLoopCommonModes];
}
// The end of a burst of timed pans: upstream's launch_momentum_on. The clock is brought
// up to now first, so the coast's first frame spans one frame and not the idle poll's gap.
- (void)panEnd:(NSNumber *)output {
    if(self.cleaning||!output)return;
    if(!self.frameTimer)[self cameraFrame];
    [self call:@{@"op":@"pan_end",@"output":output}];[self ensureFrames];
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
// One exec effect. A command sh cannot find or run says so on the status line and
// ends the key repeat in progress: a held chord never starts a missing program
// over and over.
- (void)exec:(NSDictionary *)effect {
    NSString *command=effect[@"command"];__weak Desktop *weak=self;
    // Upstream puts WAYLAND_DISPLAY in every child's environment and its msg client derives the
    // socket from it; the served socket path stands for it here. An [env] entry of that name wins.
    NSMutableDictionary *env=[asDict(effect[@"env"]) mutableCopy]?:[NSMutableDictionary dictionary];
    if(self.ipc&&self.socketPath&&env[@"INFINIFY_SOCKET"]==nil)env[@"INFINIFY_SOCKET"]=self.socketPath;
    NSString *error=execCommand(command,env,^{Desktop *d=weak;if(!d||d.cleaning)return;[d.hotKeys endRepeat];[d flashStatus:[@"sh could not run: " stringByAppendingString:command]];[d render];});
    if(error)[self flashStatus:error];
}
// macOS's selected keyboard input source, for the controller's Layout and State answers.
- (void)reportLayout {
    NSMutableDictionary *command=[DWCurrentLayout()mutableCopy];if(!command)return;
    NSString *status=self.statusText;command[@"op"]=@"layout_changed";
    if(![self call:command]){fprintf(stderr,"layout_changed: %s\n",self.statusText.UTF8String);self.statusText=status;}
    [self publishState];
}
// Shared tail of every bound or scripted command: redraw, fly, persist, and the effects
// the shell owns: quit, exec, a config reload, a pointer warp, a keyboard layout switch,
// a window's close button and the launch of a stand-in's application.
- (void)applyReply:(NSDictionary *)reply {
    // A gesture reply says itself when frames are needed: a camera coasting after a swipe, or the edge pan under a move, is no flight.
    BOOL flight=asDict(reply[@"navigation"])!=nil||[reply[@"needs_frames"]isEqual:@YES];if(flight&&!self.navigation)self.flying=YES;
    // The reply's focus request, if any, is the coordinator's to perform on the native window.
    [self.navigation perform:reply];
    [self render];if(flight)[self ensureFrames];
    if([reply[@"dirty"]isEqual:@YES])[self saveScene];
    for(id effect in asArray(reply[@"effects"])){NSDictionary *e=asDict(effect);NSString *op=asString(e[@"op"]);
        if([op isEqual:@"quit"])[self quit:nil];
        else if(!self.configured)continue;
        else if([op isEqual:@"exec"]&&asString(e[@"command"]))[self exec:e];
        // send-cursor-to-output, an explicit user action: the point is in the coordinates of screen_bounds.
        // Re-associating lifts the pause macOS puts on pointer movement after a warp.
        else if([op isEqual:@"warp_pointer"]){NSDictionary *screen=asDict(e[@"screen"]);CGPoint to=jsonPoint(screen);if(asNumber(screen[@"x"])&&asNumber(screen[@"y"])&&isfinite(to.x)&&isfinite(to.y)){CGWarpMouseCursorPosition(to);CGAssociateMouseAndMouseCursorPosition(true);}}
        // The selection is reported at once; the input-source notification reports it again.
        else if([op isEqual:@"switch_layout"]){NSString *error=DWSwitchLayout(e);if(error)[self flashStatus:error];[self reportLayout];}
        // Deferred: a reload replaces the hot keys, and this may be running inside one of their handlers.
        else if([op isEqual:@"reload_config"]){__weak Desktop *weak=self;dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(d&&!d.cleaning)[d loadConfig:NO];});}
        else if([op isEqual:@"close_window"])[self closeWindow:e];
        else if([op isEqual:@"launch"])[self launch:asString(e[@"bundle_id"])];
    }
}
// The close_window effect of close-window and suspend-window. It is taken only from the
// reply to a binding, a toolbar action or an IPC request, never from a window that came
// or went by itself, and only for the binding the controller named: this shell's own
// source for that window, still bound by the controller at that generation. The window
// stays bound until it is gone; -poll then reports window_closed and the controller's
// mark decides between a real close and a stand-in. The press is validated afresh and
// sent off the main thread.
- (void)closeWindow:(NSDictionary *)effect {
    NSNumber *window=asNumber(effect[@"window"]);LiveSource *source=window?self.sources[window]:nil;NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];id binding=nil;
    for(NSDictionary *w in snapshot[@"windows"])if([w[@"window"]isEqual:window])binding=w[@"source"];
    NSDictionary *bound=asDict(binding),*identity=source.identity;
    if(!source||source.detached||!bound||!boundIdentity(identity,effect[@"identity"])||!boundIdentity(identity,bound[@"identity"])||![bound[@"generation"]isEqual:effect[@"generation"]]){[self flashStatus:@"Close skipped: the window is no longer the one that was bound"];[self render];return;}
    if(!AXIsProcessTrusted()){[self flashStatus:@"Closing a window requires Accessibility access. Enable it in System Settings, then reopen."];[self render];return;}
    __weak Desktop *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString *error=DWCloseWindow(identity);if(error)dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(!d||d.cleaning)return;[d flashStatus:[@"Window not closed: " stringByAppendingString:error]];[d render];});});
}
// The launch effect of relaunching a stand-in. The window it opens is found like any
// other and adopted into the stand-in's slot by the controller.
- (void)launch:(NSString *)bundle {
    __weak Desktop *weak=self;
    DWLaunchApplication(bundle,^(NSString *reason){Desktop *d=weak;if(!d||d.cleaning)return;NSString *note=[@"Relaunch failed: " stringByAppendingString:reason];fprintf(stderr,"%s\n",note.UTF8String);[d flashStatus:note];[d render];});
}
// Which corners are bound depends on the outputs registered: read from the bindings
// after every config load, and again whenever panels open.
- (void)armCorners:(NSDictionary *)bindings { if(!self.corners)self.corners=[DWHotCorners new];[self.corners arm:asArray(bindings[@"hot_corners"])]; }
// Upstream checks hot corners on every pointer motion. Here the pointer is read at
// the poll and frame cadence, and only while some corner is bound. A display's
// corners are its panel's: the output and the shell's own toolbar strip above it,
// which is where the pointer comes to rest. The controller picks and runs the action.
- (void)watchCorners {
    if(self.cleaning||!self.corners.armed)return;
    CGPoint p=pointer();BOOL dragging=NSEvent.pressedMouseButtons!=0;
    for(DesktopView *view in self.views)if(view.gesture||view.pressedSource)dragging=YES;
    for(DesktopView *view in self.views){
        CGRect display=view.globalBounds;if(view.outputs.count!=1||!CGRectContainsPoint(display,p))continue;
        // Upstream's nested backend sees only the motion its own window is sent: an ordinary window
        // covered at the pointer, or left on another Space, has no pointer in its corner. Not asked of
        // the full-screen panels, whose top corners lie under the menu bar.
        if(self.windowed&&[NSWindow windowNumberAtPoint:NSMakePoint(p.x,screenTop()-p.y) belowWindowWithWindowNumber:0]!=view.window.windowNumber)continue;
        NSNumber *output=view.outputs[0];NSString *corner=[self.corners enter:CGPointMake(p.x-display.origin.x,p.y-display.origin.y) size:display.size output:output dragging:dragging];
        if(corner)[self action:[self.corners action:corner output:output] output:output at:p held:[DWCycleHold modifiersDown]!=0 corner:corner];
        return;
    }
    [self.corners leave];
}
// Upstream's broadcast: the controller's state_event returns the State event line
// only when it differs from the last one it returned, and that line goes to every
// subscriber. Without an active output there is no State, which is no news for the status line.
- (void)broadcastState {
    NSString *status=self.statusText,*line=asString([self call:@{@"op":@"state_event",@"output":[self viewOutput]?:NSNull.null}][@"line"]);self.statusText=status;
    if(line)[self.ipc publish:[line dataUsingEncoding:NSUTF8StringEncoding]];
}
// Subscribers get the State after anything that may have changed what it reports:
// asked for by every redraw, broadcast at most once a frame, and on a later turn
// of the main queue so that a request's own reply is written first. Nothing is
// asked of the controller while nobody subscribes.
- (void)publishState {
    if(self.statePush||self.cleaning||!self.ipc.subscribers)return;
    __weak Desktop *weak=self;
    self.statePush=[NSTimer timerWithTimeInterval:MAX(0,self.lastStatePush+1.0/60-CACurrentMediaTime()) repeats:NO block:^(NSTimer *timer){
        Desktop *d=weak;if(!d||d.statePush!=timer)return;
        d.statePush=nil;d.lastStatePush=CACurrentMediaTime();if(!d.cleaning&&d.ipc.subscribers)[d broadcastState];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.statePush forMode:NSRunLoopCommonModes];
}
// Upstream's autostart: once, a moment after startup, when the socket already
// answers a command that talks to this app: exec: hands every child the served
// socket as INFINIFY_SOCKET, so `Infinify msg` in a command reaches this instance.
- (void)runAutostart {
    NSArray *effects=self.autostart;self.autostart=nil;if(!effects.count)return;
    __weak Desktop *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        Desktop *d=weak;if(!d||stopped)return;
        for(id effect in effects){NSDictionary *e=asDict(effect);if([e[@"op"]isEqual:@"exec"]&&asString(e[@"command"]))[d exec:e];}
    });
}
// Hold-to-commit, after an action ran, whatever fired it: a held cycle-windows step keeps the session open
// until the hold modifiers are let go; any other action has ended it.
- (void)holdCycle:(NSString *)action held:(BOOL)held {
    BOOL cycle=[action hasPrefix:@"cycle-windows "];
    if(cycle&&held&&self.navigation){__weak Desktop *weak=self;[self.navigation hold:self.cycleModifiers?:optionKey];[self.cycleHold start:^BOOL(uint32_t down){return [weak.navigation poll:down];}];}
    else if(!cycle){[self.navigation hold:0];[self.cycleHold stop];}
}
// A hot key's pointer and modifiers are the physical ones at the moment it fires.
- (void)action:(NSString *)action output:(NSNumber *)output { [self action:action output:output at:pointer() held:[DWCycleHold modifiersDown]!=0]; }
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held { [self action:action output:output at:point held:held corner:nil]; }
// Every hot key, toolbar button and hot corner runs an upstream action string. An existing
// flight is deliberately not cancelled first: pan-viewport extends its in-flight target.
// A normal run also says where the pointer is, for focus-center, and whether a real
// modifier is down: upstream then keeps a cycle-windows session open until the hold
// modifiers are let go, and commits a modifier-less step at once.
// A hot corner's action is the controller's to pick and run: `action` is then only what
// the status line reports and what decides whether a cycle session is held open.
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held corner:(NSString *)corner {
    [self.resize cancel];if(self.resize&&![self.resize canRemove:nil])return;
    if(self.cleaning||!output)return;
    // Upstream's go-to-bookmark is silent on an unset name, so the bookmark table is asked first.
    NSString *name=[action hasPrefix:@"go-to-bookmark "]?[action substringFromIndex:15]:nil;
    BOOL unset=name&&!asDict(asDict([self call:@{@"op":@"ipc",@"output":output,@"request":@{@"Bookmark":@{@"name":name}}}])[@"reply"])[@"Ok"];
    NSMutableDictionary *command=[(corner?@{@"op":@"hot_corner",@"output":output,@"corner":corner}:@{@"op":@"action",@"output":output,@"action":action})mutableCopy];
    if(self.configured){command[@"pointer"]=pointJSON(point);command[@"held"]=held?@YES:@NO;}
    NSDictionary *reply=[self call:command];
    if(reply)[self holdCycle:action held:held];
    NSString *sets=self.configured?[self.hotKeys chords:[@"set-bookmark " stringByAppendingString:name?:@""]].firstObject:[@"⌃⌥⇧" stringByAppendingString:name?:@""];
    NSString *missing=[NSString stringWithFormat:@"No bookmark %@ yet%@",name,sets?[NSString stringWithFormat:@" — %@ sets it",sets]:@""];
    NSString *text=unset?missing:reply?[self actionFeedback:action flight:asDict(reply[@"navigation"]) output:output]:self.statusText;
    if(text)[self flashStatus:text];
    [self applyReply:reply];
}
// One libinput-shaped event, from the recogniser or the magnify stream, to the
// controller. gesture_begin gains what only the shell knows: the modifiers held, the
// output and the window-or-canvas context under the pointer, and the pointer itself.
// An update or an end, which may fire an action, says whether a real modifier is down
// as it does, as a hot key's action does. The reply is an action's, with what the
// gesture fired and a note when it is gated.
- (void)gesture:(NSDictionary *)event owner:(NSInteger)owner {
    NSString *op=event[@"op"];BOOL begin=[op isEqual:@"gesture_begin"],end=[op isEqual:@"gesture_end"],held=[DWCycleHold modifiersDown]!=0;NSMutableDictionary *command=[event mutableCopy];
    if(begin){
        // The controller holds one gesture: a pinch that gains a third finger ends before the swipe it became begins.
        if(self.gestureOwner)[self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":event[@"time_ms"]} owner:self.gestureOwner];
        if(self.cleaning||(self.resize&&![self.resize canRemove:nil]))return;
        // Where a press or a scroll would land: over an output, and not during a button drag.
        CGPoint p=pointer();DesktopView *under=nil;NSNumber *output=nil;
        for(DesktopView *view in self.views){if(view.gesture)return;if(!output&&(output=[view outputAt:p]))under=view;}
        if(!output)return;
        // New input withdraws a native focus request still in flight, as a scroll does. An open cycle whose selection has settled
        // stays open, for a swipe bound to cycle-windows to step. Flights are the controller's to stop: upstream cancels them only for a bound gesture.
        under.lastOutput=output;[self.navigation interrupt];
        // A swipe or pinch of the recogniser's takes the fingers from a scroll they were making. Its later pans are held
        // back (-padBusy:); the rest of it goes here, as at a press: the 50 ms launch still pending, and the pan_end its
        // lift would send. Either launches the momentum the swipe pans with and empties its tracker, and the swipe's own
        // end, or whichever of the two comes second, would then launch nothing. scrollPan stays: macOS's inertia is still
        // swallowed. A two-finger pinch and a hold hold no scroll back, and end none.
        if(owner==1&&self.trackpad.engaged){[self.panLaunch cancel];for(DesktopView *view in self.views)view.scrollPanTime=0;}
        command[@"modifiers"]=modifiersJSON(NSEvent.modifierFlags);command[@"context"]=[[under hit:p output:output]isKindOfClass:NSDictionary.class]?@"window":@"canvas";command[@"output"]=output;command[@"pointer"]=pointJSON(p);
        self.gestureOwner=owner;self.gestureOutput=output;
    }else if(owner!=self.gestureOwner)return;
    else command[@"held"]=held?@YES:@NO;
    if(end)self.gestureOwner=0;
    NSDictionary *reply=[self call:command];
    // A refusal is said once and ends the gesture on both sides.
    if(!reply){
        NSString *error=self.statusText;if(!begin&&!end)[self call:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":event[@"time_ms"]}];
        self.gestureOwner=0;[self flashStatus:error];[self render];return;
    }
    // A pan that ends cancelled while still moving lost its touches: macOS took them, a button was pressed, the panels went away. (A finger lifting ahead of the others waits out the recogniser's count debounce, too long to launch.) The canvas stops there instead of coasting on as upstream's cancelled swipe does.
    if(end&&[command[@"cancelled"]isEqual:@YES]&&self.gestureOutput&&[asString(asDict(reply[@"gesture"])[@"state"])isEqual:@"swipe_pan"])[self call:@{@"op":@"cancel_navigation",@"output":self.gestureOutput}];
    // No gesture in the reply: trackpad gestures are off (set-trackpad), and the rest of this one has nowhere to go.
    if(begin&&!asDict(reply[@"gesture"]))self.gestureOwner=0;
    NSDictionary *fired=asDict(reply[@"fired"]);NSString *action=asString(fired[@"action"]);
    // An action the gesture fired and the controller ran holds a cycle open, or ends one, as a hot key's does.
    if(action&&!asString(fired[@"error"]))[self holdCycle:action held:held];
    NSString *text=asString(reply[@"note"])?:asString(fired[@"error"])?:action?[self actionFeedback:action flight:asDict(reply[@"navigation"]) output:self.gestureOutput]:nil;
    if(text)[self flashStatus:text];
    [self applyReply:reply];
}
// Resting fingers send no events, so the recogniser's hold delay and finger-count debounce are met by a timer.
- (void)armTrackpad {
    NSTimeInterval deadline=self.cleaning?0:self.trackpad.deadline;if(deadline==self.trackpadDeadline)return;
    [self.trackpadTimer invalidate];self.trackpadTimer=nil;self.trackpadDeadline=deadline;if(!deadline)return;
    __weak Desktop *weak=self;
    self.trackpadTimer=[NSTimer timerWithTimeInterval:MAX(0,deadline-CACurrentMediaTime()) repeats:NO block:^(NSTimer *timer){(void)timer;Desktop *d=weak;d.trackpadTimer=nil;d.trackpadDeadline=0;[d.trackpad advance:CACurrentMediaTime()];[d armTrackpad];}];
    [[NSRunLoop mainRunLoop]addTimer:self.trackpadTimer forMode:NSRunLoopCommonModes];
}
// One frame of raw touches for the recogniser: every touch of the event, in
// millimetres from the pad's top left (a touch is normalised over a pad sized in
// points). A resting touch is left out, which the recogniser reads as a finger gone.
- (void)touches:(NSEvent *)e {
    if(!self.trackpad||self.cleaning)return;
    for(NSTouch *touch in [e touchesMatchingPhase:NSTouchPhaseAny inView:nil]){
        if(touch.type!=NSTouchTypeIndirect||touch.resting)continue;
        NSPoint p=touch.normalizedPosition;NSSize pad=touch.deviceSize;NSTouchPhase phase=touch.phase;
        [self.trackpad touch:touch.identity x:p.x*pad.width*25.4/72 y:(1-p.y)*pad.height*25.4/72 phase:phase&NSTouchPhaseCancelled?DWTouchCancelled:phase&NSTouchPhaseEnded?DWTouchEnded:phase&NSTouchPhaseBegan?DWTouchBegan:DWTouchMoved time:e.timestamp];
    }
    [self.trackpad frame:e.timestamp];self.lastTouches=e.timestamp;[self armTrackpad];
}
// A swipe or pinch of three or more fingers is the recogniser's: a scroll or a
// magnify macOS makes of the same fingers would be that gesture twice. Moving fingers
// keep sending touches, so an event long after the last of them is not theirs, and
// is never held back.
- (BOOL)padBusy:(NSEvent *)e { return self.trackpad.engaged&&e.timestamp-self.lastTouches<.25; }
// AppKit's two-finger pinch as libinput's: the scale is absolute from the gesture's
// start, the running product of each event's 1 + magnification. No rotation, no delta.
- (void)magnify:(NSEvent *)e {
    NSEventPhase phase=e.phase;NSNumber *time=DWGestureTime(e.timestamp);BOOL over=(phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0;
    if([self padBusy:e]){if(self.magnifying){self.magnifying=NO;[self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":time} owner:2];}return;}
    if(phase&NSEventPhaseMayBegin)return;
    if(!self.magnifying){if(over)return;self.magnifying=YES;self.magnifyScale=1;[self gesture:@{@"op":@"gesture_begin",@"kind":@"pinch",@"fingers":@2,@"time_ms":time} owner:2];}
    if(e.magnification){self.magnifyScale*=MAX(.01,1+e.magnification);[self gesture:@{@"op":@"gesture_update",@"dx":@0,@"dy":@0,@"scale":@(self.magnifyScale),@"rotation":@0,@"time_ms":time} owner:2];}
    // An event with no phase is a whole gesture.
    if(over||phase==NSEventPhaseNone){self.magnifying=NO;[self gesture:@{@"op":@"gesture_end",@"cancelled":phase&NSEventPhaseCancelled?@YES:@NO,@"time_ms":time} owner:2];}
}
// The touches stop being a gesture's: a press on the pad, or the panels going away.
// The recogniser forgets its fingers, and a gesture the controller holds ends cancelled.
- (void)cancelGestures {
    NSTimeInterval now=CACurrentMediaTime();
    [self.trackpadTimer invalidate];self.trackpadTimer=nil;self.trackpadDeadline=0;self.magnifying=NO;[self.trackpad cancel:now];
    if(self.gestureOwner)[self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":DWGestureTime(now)} owner:self.gestureOwner];
}
- (void)viewButton:(NSButton *)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    DesktopView *view=[sender.superview isKindOfClass:DesktopView.class]?(DesktopView *)sender.superview:nil;
    // A button is a modifier-less fire: Previous and Next are single committed steps.
    [self action:sender.identifier output:[view actionOutput] at:pointer() held:NO];
}
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d, src/input/pointer.rs
// (on_pointer_button's click-to-focus fallback: raise_and_focus, then the press is forwarded)
// and src/state/navigation.rs (arm_click_navigate, resolve_click_navigate, fire_click_navigate).
// Logical focus and raising are done when this returns. The native focus request is only
// handed to the coordinator, which performs it on the freshly validated window on its worker:
// the press is forwarded while that request is in flight, not after it.
- (void)activate:(NSNumber *)window output:(NSNumber *)output { [self applyReply:[self call:@{@"op":@"activate",@"window":window,@"output":output?:NSNull.null,@"cause":@"click"}]]; }
// That press released as a completed click. With auto_navigate_on_click the controller flies
// to a window that still holds focus and is not wholly in view. The reply carries a flight or
// nothing, never a focus request, so the press's request stays the coordinator's.
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output { [self applyReply:[self call:@{@"op":@"activate",@"window":window,@"output":output?:NSNull.null,@"cause":@"click_release"}]]; }
// Upstream src/grabs/pan_grab.rs: a press on empty canvas released within 5 points leaves
// no window focused. Logical only: nothing is asked of any native application.
- (void)clearFocus { [self applyReply:[self call:@{@"op":@"clear_focus"}]]; }
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
// pointer speeds.
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window {
    NSDictionary *reply=[self call:@{@"op":@"mouse_binding",@"trigger":trigger,@"source":source?:NSNull.null,@"modifiers":modifiersJSON(flags),@"context":window?@"window":@"canvas"}],*binding=asDict(reply[@"binding"]);
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
    if(self.windowed){[parts insertObject:@"Windowed, no global shortcuts" atIndex:0];[parts addObject:@"toolbar or Infinify msg: view, window and bookmark actions"];return [parts componentsJoinedByString:@" · "];}
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
    for(NSArray<NSString *> *row in @[@[@"cycle-windows forward",@"cycle"],@[@"center-window",@"center"],@[@"home-toggle",@"home"],@[@"zoom-to-fit",@"fit"],@[@"zoom-in",@"zoom in"],@[@"zoom-out",@"zoom out"],@[@"zoom-reset",@"1:1"]])if(chord(row[0]))[parts addObject:[NSString stringWithFormat:@"%@: %@",chord(row[0]),row[1]]];
    NSArray<NSString *> *arrows=@[@"left",@"right",@"up",@"down"],*arrowKeys=@[@"←",@"→",@"↑",@"↓"],*digits=@[@"1",@"2",@"3",@"4"];
    NSString *near=family(@"center-nearest",arrows,arrowKeys,@"-arrows"),*pan=family(@"pan-viewport",arrows,arrowKeys,@"-arrows"),*go=family(@"go-to-bookmark",digits,digits,@"1-4"),*set=family(@"set-bookmark",digits,digits,@"1-4");
    if(near)[parts addObject:[near stringByAppendingString:@": nearest window"]];
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
            for(NSArray<NSString *> *row in toolbarActions(self.configured))if([row[1]isEqual:button.identifier])button.toolTip=[self tooltip:row];
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
    [self.hotKeys setBindings:bindings];
    [notes addObjectsFromArray:self.hotKeys.notes];
    // Upstream's cycle_hold as the controller reports it, else as upstream derives it: the modifiers of the cycle-windows forward binding, Option when it has none.
    NSDictionary *hold=asDict(bindings[@"cycle_hold"]);UInt32 mask=([hold[@"control"]isEqual:@YES]?controlKey:0)|([hold[@"option"]isEqual:@YES]?optionKey:0)|([hold[@"shift"]isEqual:@YES]?shiftKey:0)|([hold[@"command"]isEqual:@YES]?cmdKey:0);
    if(!mask)for(NSDictionary *key in self.hotKeys.keys)if([key[@"action"]isEqual:@"cycle-windows forward"]){mask=[key[@"chord"]unsignedIntValue]&(controlKey|optionKey|shiftKey|cmdKey);break;}
    self.cycleModifiers=mask?:optionKey;
    self.dismissFree=![self mouseBinding:@"left" source:nil flags:NSEventModifierFlagControl|NSEventModifierFlagOption window:YES];
    [self armCorners:bindings];
    self.statusText=status;if(open)[notes addObjectsFromArray:[self startKeys]];
    self.help=[self helpLine];if(help&&[self.statusText isEqual:help])self.statusText=self.help;
    if(open)[self refreshChrome];
    // Startup, and every change of the input source, also tell the controller the layout.
    [self reportLayout];
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
    // The launch load's effects are the config's autostart commands: kept for main() to run once. A reload's are never looked at.
    if(platform)self.autostart=asArray(loaded[@"effects"]);
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
// The controller answers Subscribe with a subscribe effect carrying the current
// State event: the connection is then kept, and that line follows the ack.
- (NSData *)ipcLine:(NSData *)line subscribe:(BOOL *)subscribe event:(NSData *__autoreleasing *)event {
    if(self.cleaning)return ipcError(@"the canvas is closed");
    if(self.startupError)return ipcError(self.startupError);
    if(self.resize&&![self.resize canRemove:nil])return ipcError(@"a native resize is pending");
    id request=[NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:nil];
    NSDictionary *command=request?@{@"op":@"ipc",@"output":[self viewOutput]?:NSNull.null,@"request":request,@"pointer":pointJSON(pointer())}:nil;
    if(!command||![NSJSONSerialization isValidJSONObject:command])return ipcError(@"invalid request");
    NSString *status=self.statusText;NSData *raw=nil;NSDictionary *data=[self call:command raw:&raw];
    // A controller-level refusal still answers the client and leaves the status line alone.
    if(!asDict(data[@"reply"])){NSString *error=data?@"invalid controller reply":self.statusText?:@"controller error";self.statusText=status;return ipcError(error);}
    [self applyReply:data];
    for(id effect in asArray(data[@"effects"])){NSString *first=asString(asDict(effect)[@"line"]);if([asDict(effect)[@"op"]isEqual:@"subscribe"]&&first){*subscribe=YES;*event=[first dataUsingEncoding:NSUTF8StringEncoding];}}
    // That snapshot is the current State. The broadcast is brought up to it before the connection joins:
    // earlier subscribers get a change not yet sent to them, and the new one is not sent its snapshot twice.
    if(*subscribe)[self broadcastState];
    return jsonMember(jsonMember(raw,"data"),"reply")?:[NSJSONSerialization dataWithJSONObject:data[@"reply"] options:NSJSONWritingWithoutEscapingSlashes error:nil];
}
// Normal runs only: main() starts the server once and stops it before the final cleanup.
- (void)startIPC:(NSString *)path {
    __weak Desktop *weak=self;NSString *error=nil;
    self.ipc=[DWIPCServer serverAtPath:path handler:^NSData *(NSData *line,BOOL *subscribe,NSData *__autoreleasing *event){return [weak ipcLine:line subscribe:subscribe event:event];} error:&error];
    if(!self.ipc){self.statusText=[NSString stringWithFormat:@"Running without IPC: %@ (%@)",error,path];fprintf(stderr,"%s\n",self.statusText.UTF8String);}
    else self.socketPath=path;
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
- (void)render {
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
    // Cursor edge pan is on while the snapshot's navigation.cursor_pan.needs_pointer says so; see -reportPointer.
    self.pointerOutputs=self.configured&&[asDict(asDict(snapshot[@"navigation"])[@"cursor_pan"])[@"needs_pointer"]isEqual:@YES]?asArray(snapshot[@"outputs"]):nil;
    for(DesktopView *view in self.views)[view render:snapshot];
    [self publishState];
}
- (void)quit:(id)sender { (void)sender;[self.resize shutdown];[self stopNavigation];stopped=1; }
- (void)resizeUnavailable:(id)sender { if(self.probe&&sender){self.probeHumanInput=YES;return;} (void)sender;if(self.experimentalResize){self.statusText=@"Experimental: select one source, then drag an orange edge handle. Unknown family or capture mapping stays inert; Escape cancels shell input.";[self render];return;}self.statusText=@"Native layout resize is unavailable. Resize the original app on the desktop, then return; capture reconciles without changing world geometry.";[self render]; }
- (void)returnDesktop:(id)sender { [self.resize cancel];if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize is pending or unresolved; source retained";[self render];return;} if(self.probe&&sender){self.probeHumanInput=YES;return;} (void)sender;[self cleanup];[self showChooser:nil]; }
- (DesktopView *)panel:(NSRect)frame outputRects:(NSArray *)rects identities:(NSArray *)identities {
    NSPanel *panel=[[(self.ownedResizeProbe?RPIsolatedPanel.class:CanvasPanel.class) alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO;panel.level=self.windowed?NSNormalWindowLevel:NSFloatingWindowLevel;panel.animationBehavior=NSWindowAnimationBehaviorNone;panel.collectionBehavior=NSWindowCollectionBehaviorMoveToActiveSpace|NSWindowCollectionBehaviorFullScreenAuxiliary;
    DesktopView *view=[[DesktopView alloc]initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];view.desktop=self;view.globalBounds=topRect(frame);view.outputs=[NSMutableArray array];view.tiles=[NSMutableDictionary dictionary];view.surfaces=[NSMutableDictionary dictionary];view.wantsLayer=YES;view.layer.backgroundColor=[NSColor colorWithSRGBRed:.045 green:.065 blue:.10 alpha:1].CGColor;panel.contentView=view;
    // Normal runs only: the trackpad's raw touches, for gestures of three or more fingers.
    if(self.configured)view.allowedTouchTypes=NSTouchTypeMaskIndirect;
    for(NSUInteger i=0;i<rects.count;i++){NSNumber *output=[self call:@{@"op":@"register_output",@"stable_id":identities[i],@"screen_bounds":rects[i]}][@"output"];if(output)[view.outputs addObject:output];}
    NSArray *names=self.ownedResizeProbe?@[]:@[@"Choose windows",@"Return to desktop",@"Resize status",[self quitTitle]];
    if(self.ownedResizeProbe)[view addSubview:label(@"Noninteractive owned resize probe — supervisor signal or deadline exits",NSMakeRect(15,8,720,26))];
    SEL actions[]={@selector(showChooser:),@selector(returnDesktop:),@selector(resizeUnavailable:),@selector(quit:)};
    CGFloat x=12;for(NSUInteger i=0;i<names.count;i++)x=toolbarButton(view,[NSButton buttonWithTitle:names[i] target:self action:actions[i]],x);
    if(!self.ownedResizeProbe){
        // The accessory app is rarely active, so tooltips must not wait for activation.
        if(!self.probe)panel.allowsToolTipsWhenApplicationIsInactive=YES;
        for(NSArray<NSString *> *row in toolbarActions(self.configured)){NSButton *button=[NSButton buttonWithTitle:row[0] target:self action:@selector(viewButton:)];button.identifier=row[1];button.toolTip=[self tooltip:row];x=toolbarButton(view,button,x);}}
    view.status=label(self.statusText,NSMakeRect(15,37,MAX(100,frame.size.width-30),22));view.status.textColor=NSColor.lightGrayColor;view.status.font=[NSFont systemFontOfSize:11];[view addSubview:view.status];
    [self.panels addObject:panel];[self.views addObject:view];if(self.ownedResizeProbe&&!rpBeforeOrder(panel)){self.probeHumanInput=YES;return view;}[panel orderFrontRegardless];return view;
}
- (void)openPanels {
    if(self.panels.count)return;self.cleaning=NO;
    // Return to desktop stopped the config watcher and dropped the key table: read the config again.
    if(self.configured&&!self.configWatcher)[self loadConfig:NO];
    if(self.configured&&!self.trackpad){__weak Desktop *weak=self;self.trackpad=[[DWTrackpadGestures alloc]initWithEmit:^(NSDictionary *event){[weak gesture:event owner:1];}];}
    if(self.demo){NSRect frame=NSMakeRect(100,120,1040,600);CGRect global=topRect(frame);NSMutableArray *rects=[NSMutableArray array];for(int i=0;i<2;i++)[rects addObject:rectJSON(CGRectOffset(ports[i],global.origin.x,global.origin.y))];[self panel:frame outputRects:rects identities:@[@"fixture-view-a",@"fixture-view-b"]];}
    // The analogue of upstream's nested winit backend: one ordinary window, one output.
    else if(self.windowed){NSScreen *screen=NSScreen.mainScreen?:NSScreen.screens.firstObject;NSRect area=screen.visibleFrame;CGFloat width=MIN(self.windowSize.width,area.size.width),height=MIN(self.windowSize.height,area.size.height);
        NSRect frame=NSMakeRect(floor(NSMidX(area)-width/2),floor(NSMidY(area)-height/2),width,height);CGRect output=topRect(frame);output.origin.y+=64;output.size.height-=64;
        if(screen)[self panel:frame outputRects:@[rectJSON(output)] identities:@[@"windowed"]];}
    else for(NSScreen *screen in NSScreen.screens){NSNumber *display=screen.deviceDescription[@"NSScreenNumber"];CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display.unsignedIntValue);NSString *name=uuid?CFBridgingRelease(CFUUIDCreateString(NULL,uuid)):nil;if(uuid)CFRelease(uuid);if(!name)continue;CGRect output=topRect(screen.frame);output.origin.y+=64;output.size.height-=64;[self panel:screen.frame outputRects:@[rectJSON(output)] identities:@[name]];}
    // Windowed mode registers no global hot key: toolbar, pointer and IPC only.
    if(self.configured){NSArray<NSString *> *refused=[self startKeys];if(refused.count)self.statusText=summary(@"Shortcut unavailable",refused);[self armCorners:[self call:@{@"op":@"bindings"}]];}
    else {
    if(!self.probe&&!self.ownedResizeProbe&&!self.windowed)[self configureViewKeys];
    if(!self.ownedResizeProbe&&!self.windowed)[self configureExitKey];
    }
    [self configureResize];[self configureNavigation];
    // Inert without Screen Recording access: no manager, no prompt, and this run is the manual one.
    // It says why; a more specific problem already in the status line keeps its place there.
    // The Accessibility note of the same launch is not one: it follows this note.
    if(self.managing&&!self.manager&&!self.startupError&&!(self.manager=[DWWindowManager managerWithHost:self])){
        NSString *note=@"Windows are not managed: Infinify has no Screen Recording access. Choose windows offers Allow screen recording…; then quit and reopen.";
        fprintf(stderr,"%s\n",note.UTF8String);
        if([self.statusText isEqual:[self restingStatus]])self.statusText=note;
        else if([self.statusText isEqual:focusAccessNote])self.statusText=[NSString stringWithFormat:@"%@ · %@",note,focusAccessNote];}
    [self render];
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
- (BOOL)attach:(SCWindow *)window logical:(NSNumber *)logical world:(NSDictionary *)world { return [self attach:window logical:logical world:world placed:NO]; }
// placed: a window that appeared by itself. It is sent with neither a logical id nor a
// world rectangle, so the controller adopts it into a matching slot or places it by
// window_placement around the active output and the pointer. Only its size is native.
- (BOOL)attach:(SCWindow *)window logical:(NSNumber *)logical world:(NSDictionary *)world placed:(BOOL)placed {
    if(!placed)[self cancelNavigation];
    pid_t pid=window.owningApplication.processID;uint32_t wid=window.windowID;NSArray *processBirth=birth(pid);NSDictionary *info=windowInfo(wid);CGRect bounds=CGRectZero;
    if(!processBirth||[info[(id)kCGWindowOwnerPID]intValue]!=pid||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)){self.statusText=@"Source closed or identity changed; refresh the chooser.";return NO;}
    for(LiveSource *existing in self.sources.allValues)if(existing.router.pid==pid&&existing.router.wid==wid){self.statusText=@"This source is already attached; every display can view the same world window.";return NO;}
    LiveSource *source=[LiveSource new];source.router=[Router new];source.router.pid=pid;source.router.wid=wid;source.router.processBirth=processBirth;source.router.bounds=info[(id)kCGWindowBounds];source.router.deadline=NSDate.distantFuture;source.router.sent=[NSMutableArray array];source.router.tag=(int64_t)(arc4random_uniform(0x7fffff)+1)*100;source.router.eventSource=CGEventSourceCreate(kCGEventSourceStatePrivate);source.router.usePrivate=YES;
    BOOL privateAvailable=[source.router loadPrivate];source.identity=@{@"pid":@(pid),@"birth_sec":processBirth[0],@"birth_usec":processBirth[1],@"wid":@(wid)};
    source.buffer=CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2));source.surfaces=[NSMutableArray array];
    NSMutableDictionary *command=[@{@"op":@"attach",@"identity":source.identity,@"bundle_id":window.owningApplication.bundleIdentifier?:@"",@"title":window.title?:@"Untitled",@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)},@"source_rect":rectJSON(bounds)} mutableCopy];
    if(placed){NSNumber *output=[self viewOutput];if(output)command[@"output"]=output;command[@"pointer"]=pointJSON(pointer());}
    else if(logical)command[@"logical_id"]=logical;else {if(!world){NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];NSDictionary *o=[snapshot[@"outputs"]firstObject];double zoom=[o[@"zoom"]doubleValue];CGPoint camera=jsonPoint(o[@"camera"]);world=rectJSON(CGRectMake(camera.x+30/MAX(.001,zoom),camera.y+30/MAX(.001,zoom),bounds.size.width,bounds.size.height));}command[@"world_rect"]=world;}
    NSDictionary *reply=[self call:command];source.logical=reply[@"window"];if(!source.logical)return NO;self.sources[source.logical]=source;
    source.window=window;source.title=asString(info[(id)kCGWindowName])?:command[@"title"];source.resize=self.resize;
    // A managed run captures on demand: -captureDemand starts the stream once the window has a placement.
    if(self.manager&&!self.resize)source.keepSample=YES;
    else if(![self startCapture:source size:source.buffer]){[self detach:source];return NO;}
    if(!privateAvailable)self.statusText=@"Live view only: private per-window input is unavailable on this OS.";
    if(placed)[self follow:reply];
    [self render];return YES;
}
// One stream for a source at a pixel size. NO leaves the reason in source.error.
- (BOOL)startCapture:(LiveSource *)source size:(CGSize)pixels {
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)pixels.width;config.height=(size_t)pixels.height;config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=CMTimeMake(1,30);config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;
    source.stream=[[SCStream alloc]initWithFilter:[[SCContentFilter alloc]initWithDesktopIndependentWindow:source.window] configuration:config delegate:source];[self.resize bind:source.logical stream:source.stream];NSError *error=nil;
    if(![source.stream addStreamOutput:source type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&error]){source.error=error.localizedDescription;return NO;}
    SCStream *starting=source.stream;[starting startCaptureWithCompletionHandler:^(NSError *e){if(e)dispatch_async(dispatch_get_main_queue(),^{if(source.stream==starting&&!source.detached)source.error=e.localizedDescription;});}];
    return YES;
}
// An intentional stop is no error: the stream is forgotten first, so nothing it still
// reports is read, and cleanup waits for the stop like any other.
- (void)stopCapture:(LiveSource *)source {
    SCStream *stream=source.stream;if(!stream)return;source.stream=nil;[source clearSample];
    [self.pendingStops addObject:stream];[stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{[self.pendingStops removeObject:stream];});}];
}
// Capture on demand, in a managed run: a stream runs while its window has a placement
// on some output and for two seconds after the last one went, and starts again when one
// returns. A failed source keeps its error for -poll; native resize keeps every stream.
- (void)captureDemand {
    if(!self.manager||self.resize||!self.sources.count)return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];if(!snapshot)return;
    NSMutableSet<NSNumber *> *placed=[NSMutableSet set];for(NSDictionary *p in snapshot[@"placements"])[placed addObject:p[@"window"]];
    for(LiveSource *source in self.sources.allValues){
        BOOL wanted=[self.manager capture:source.logical placed:[placed containsObject:source.logical]],running=source.stream!=nil;
        if(source.error||wanted==running)continue;
        if(!wanted){[self stopCapture:source];continue;}
        // The stream's size is the window's as it is now; nothing else is read from it.
        CGRect bounds=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)windowInfo(source.router.wid)[(id)kCGWindowBounds],&bounds))continue;
        [self startCapture:source size:CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2))];
    }
}
// A window that came, went or was renamed by itself: the flight its reply armed is
// flown, and the scene is saved on the next poll unless the reply says nothing changed.
// Its focus request, for a new window or for the one that follows a close, is the
// coordinator's to perform on the native window or to answer focus_logical, like the
// request of any other reply; a reply without one withdraws only work in flight for a
// request the controller has dropped. Such a reply carries no other effect.
- (void)follow:(NSDictionary *)reply {
    NSDictionary *effect=asDict(reply[@"effect"]);[self.navigation perform:effect?@{@"effect":effect}:@{}];
    if(asDict(reply[@"navigation"])){if(!self.navigation)self.flying=YES;[self ensureFrames];}
    if(![reply[@"dirty"]isEqual:@NO])self.sceneDirty=YES;
}
- (void)detach:(LiveSource *)source {
    [self cancelNavigation];
    if(source.detached)return;[self.resize cancel];
    if(![self call:@{@"op":@"remove_source",@"window":source.logical,@"identity":source.identity,@"keep_placeholder":@YES}])return;
    [self drop:source];
}
// The shell's half of a source the controller no longer binds: held button, kept frame, stream and table.
- (void)drop:(LiveSource *)source {
    for(DesktopView *view in self.views)if(view.pressedSource==source)[view releasePressed];source.detached=YES;[source clearSample];[self.manager forget:source.logical];
    // Capture on demand may have stopped the stream already: only a stop that was asked for is waited on.
    if(source.stream){[self.pendingStops addObject:source];[source.stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{source.streamStopped=YES;source.stream=nil;[self.pendingStops removeObject:source];});}];}else source.streamStopped=YES;
    [source.surfaces removeAllObjects];[self.sources removeObjectForKey:source.logical];
}
// The native window is gone. The controller takes its world window off the canvas, or
// leaves a stand-in under session.suspend_on_close, and moves focus as upstream's
// toplevel_destroyed does, flying on the active output when auto_navigate_on_close asks.
// A refusal keeps the world place the way a lost source always did.
- (void)closed:(LiveSource *)source {
    if(source.detached)return;
    NSMutableDictionary *command=[@{@"op":@"window_closed",@"window":source.logical,@"identity":source.identity}mutableCopy];NSNumber *output=[self viewOutput];if(output)command[@"output"]=output;
    NSDictionary *reply=[self call:command];
    if(!reply){[self detach:source];return;}
    [self drop:source];[self follow:reply];[self render];
}
- (BOOL)managesWindow:(CGWindowID)window pid:(pid_t)pid {
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&source.router.wid==window)return YES;
    return NO;
}
- (void)windowAppeared:(SCWindow *)window {
    if(self.cleaning||!self.panels.count)return;
    if([self attach:window logical:nil world:nil placed:YES])return;
    // Nobody chose this window: a refusal is a passing note.
    NSString *note=[NSString stringWithFormat:@"%@ window not adopted: %@",window.owningApplication.applicationName?:@"A",self.statusText?:@"refused"];
    fprintf(stderr,"%s\n",note.UTF8String);[self flashStatus:note];[self render];
}
// macOS platform rule: on Wayland quitting the compositor ends its clients, here
// applications outlive Infinify. The saved scene keeps one slot per window, the windows
// on screen were just adopted into theirs, `present` names the ones that exist off
// screen, whose slots keep waiting, and the controller now drops the slots nothing
// matched unless session.restore_windows keeps them as dormant stand-ins.
// Sent once per manager, and always: at launch, where until it arrives the controller
// treats every window as one that was already open and neither focuses nor reveals it,
// and again by a canvas reopened after Return to desktop, whose windows returned to
// their slots while one that closed in between left its slot behind.
- (void)discoveryCompleted:(NSArray<NSDictionary *> *)present {
    if(self.adopted||self.cleaning)return;self.adopted=YES;
    NSString *status=self.statusText;NSDictionary *reply=[self call:@{@"op":@"adoption_complete",@"present":present?:@[]}];
    if(!reply){fprintf(stderr,"adoption_complete: %s\n",self.statusText.UTF8String);self.statusText=status;return;}
    [self follow:reply];[self render];
}
// The manager reads again about every two seconds: the status note is renewed each
// time, stderr gets each distinct reason once.
- (void)discoveryFailed:(NSString *)reason {
    NSString *note=[@"Windows could not be listed: " stringByAppendingString:reason];
    if(![note isEqual:self.discoveryNote]){self.discoveryNote=note;fprintf(stderr,"%s\n",note.UTF8String);}
    [self flashStatus:note];[self render];
}
// Did close-window or suspend-window ask this window to close? The controller's mark.
- (BOOL)marked:(LiveSource *)source { return asDict([self call:@{@"op":@"snapshot"}][@"lifecycle"][@"marks"])[source.logical.stringValue]!=nil; }
- (void)screensChanged:(NSNotification *)notification {
    (void)notification;if(self.demo||!self.panels.count)return;[self cancelGestures];[self stopNavigation];
    // A pan waiting to launch belongs to an output about to be removed.
    [self.panLaunch cancel];self.pointerOutputs=nil;
    for(DesktopView *view in self.views){[view releasePressed];for(NSNumber *output in view.outputs){NSDictionary *reply=[self call:@{@"op":@"remove_output",@"output":output}];[self.resize consume:reply];}}
    for(NSPanel *panel in self.panels){[panel orderOut:nil];[panel close];}
    [self.panels removeAllObjects];[self.views removeAllObjects];for(LiveSource *source in self.sources.allValues)[source.surfaces removeAllObjects];
    [self stopKeys];[self stopViewKeys];
    [self openPanels];[self saveScene];
}
- (void)poll {
    if(self.cleaning)return;
    if(self.resize&&CACurrentMediaTime()-self.lastResizeObservation>=.5){self.lastResizeObservation=CACurrentMediaTime();[self.resize observeBindings];}
    [self watchCorners];
    // Idle polling keeps the clock current and, while cursor edge pan wants it, the pointer reported; motion found without its timer regains 60 Hz.
    if(!self.frameTimer&&[self cameraFrame])[self ensureFrames];
    if(self.navigation&&CACurrentMediaTime()-self.lastObservation>=.5){self.lastObservation=CACurrentMediaTime();[self refreshFocusAccess];[self.navigation observe];}
    // Discovery first: a window that appeared is attached before this tick observes and draws.
    [self.manager poll];
    for(LiveSource *source in self.sources.allValues){
        NSDictionary *w=windowInfo(source.router.wid);BOOL gone=sourceGone(source,w);
        // Titles follow in a managed run, under native resize too. A refused title is not offered again.
        NSString *title=self.manager&&!gone?asString(w[(id)kCGWindowName]):nil;
        if(title&&![title isEqual:source.title]){source.title=title;NSString *status=self.statusText;NSDictionary *reply=[self call:@{@"op":@"retitle",@"window":source.logical,@"identity":source.identity,@"title":title}];if(reply)[self follow:reply];else self.statusText=status;}
        if(source.resize){if(source.error&&!source.resizeFailureHandled){source.resizeFailureHandled=YES;[self.resize invalidate:source.logical];[self.resize cancel];self.statusText=@"Capture failed; source retained until resize obligations settle";}
            // A window that is gone, managed or asked to close, leaves once its resize transaction lets it.
            if(gone&&[self.resize canRemove:source.logical]&&(self.manager||[self marked:source]))[self closed:source];
            continue;}
        // A managed run tells a window that closed from a capture that failed: only the second keeps today's placeholder.
        // A manual run does so for a window close-window or suspend-window asked to close: the controller's mark decides what is left.
        if(gone&&(self.manager||[self marked:source])){[self closed:source];continue;}
        if(source.error||gone){self.statusText=source.error?:@"A source closed. Its world placeholder is retained for explicit rebind.";[self detach:source];continue;}
        CGRect bounds=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&bounds))continue;
        if(![source.router.bounds isEqual:w[(id)kCGWindowBounds]]){
            CGRect old=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&old);source.router.bounds=w[(id)kCGWindowBounds];
            if(!CGSizeEqualToSize(old.size,bounds.size)){SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)ceil(bounds.size.width*2);config.height=(size_t)ceil(bounds.size.height*2);config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=CMTimeMake(1,30);config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;[source.stream updateConfiguration:config completionHandler:^(NSError *e){if(e)dispatch_async(dispatch_get_main_queue(),^{source.error=e.localizedDescription;});}];}
        }
        [self call:@{@"op":@"observe",@"window":source.logical,@"identity":source.identity,@"source_rect":rectJSON(bounds),@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)}}];
        // Event history is probe evidence, not an unbounded production log.
        if(!self.probe&&source.router.sent.count>128)[source.router.sent removeAllObjects];
    }
    [self captureDemand];
    if(self.sceneDirty){self.sceneDirty=NO;[self saveScene];}
    if(!self.frameTimer)[self render];
}
- (void)cleanup {
    if(self.cleaning)return;self.cleaning=YES;
    // No window is discovered and no read answers from here on; a reopened canvas gets a new manager, which ends a pass of its own.
    [self.manager stop];self.manager=nil;self.adopted=NO;
    // Inert from here until the canvas reopens: no config hot key, key repeat, input-source observer, config watch, hot corner, pending event, pan launch or pointer report outlives this line.
    [self.hotKeys invalidate];self.hotKeys=nil;[self.configWatcher stop];self.configWatcher=nil;self.corners=nil;[self.statePush invalidate];self.statePush=nil;[self.panLaunch cancel];self.pointerOutputs=nil;
    // A trackpad gesture in progress ends cancelled while its output still exists; no touch or hold timer outlives this line either.
    [self cancelGestures];self.trackpad=nil;
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
- (void)dealloc { [_ipc stop];[_manager stop];[self stopNavigation];[self stopViewKeys];[_hotKeys invalidate];[_configWatcher stop];[_statePush invalidate];[_panLaunch cancel];[_trackpadTimer invalidate];if(_controller)driftwm_desktop_destroy(_controller); }
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
    if(argc>=2&&!strncmp(argv[1],"--owned-resize-",15))for(int i=2;i<argc;i++)if(!strcmp(argv[i],"--windowed")||!strcmp(argv[i],"--socket")||!strcmp(argv[i],"--config")||!strcmp(argv[i],"--super")||!strcmp(argv[i],"--no-native-focus")||!strcmp(argv[i],"--manual"))return 64;
    if(argc==3&&!strcmp(argv[1],"--owned-resize-check-restoration"))return ownedResizeCheckRestoration(@(argv[2]));
    if(argc==3&&!strcmp(argv[1],"--owned-resize-check-cleanup"))return ownedResizeCheckCleanup(@(argv[2]));
    if(argc>=2&&(!strcmp(argv[1],"--owned-resize-probe")||!strcmp(argv[1],"--owned-resize-fixture")))return ownedResizeEntry(argc,argv);
    BOOL experimental=NO,resize=NO,windowed=NO,logical=NO,manual=NO;const char *socket=NULL,*config=NULL,*chord=NULL;NSSize windowSize=NSMakeSize(1200,800);const char *filtered[argc+1];int count=0;
    for(int i=0;i<argc;i++){if(i>0&&!strcmp(argv[i],"--experimental-native-resize")){resize=YES;continue;}if(i>0&&!strcmp(argv[i],"--experimental-native-navigation")){experimental=YES;continue;}
        if(i>0&&!strcmp(argv[i],"--no-native-focus")){if(logical)return 64;logical=YES;continue;}
        if(i>0&&!strcmp(argv[i],"--socket")){if(socket||i+1>=argc||argv[i+1][0]!='/')return 64;socket=argv[++i];continue;}
        if(i>0&&!strcmp(argv[i],"--config")){if(config||i+1>=argc||argv[i+1][0]!='/')return 64;config=argv[++i];continue;}
        // The chord's grammar is the controller's; one it rejects is reported in the status line.
        if(i>0&&!strcmp(argv[i],"--super")){if(chord||i+1>=argc||!argv[i+1][0])return 64;chord=argv[++i];continue;}
        if(i>0&&!strcmp(argv[i],"--manual")){if(manual)return 64;manual=YES;continue;}
        if(i>0&&!strcmp(argv[i],"--windowed")){if(windowed)return 64;windowed=YES;if(i+1<argc&&isdigit((unsigned char)argv[i+1][0])&&!parseWindowSize(argv[++i],&windowSize))return 64;continue;}
        filtered[count++]=argv[i];}filtered[count]=NULL;argc=count;argv=filtered;

    if(argc==2&&!strcmp(argv[1],"--help")){puts("Infinify.app — macOS 26+ Apple Silicon native window canvas\nDefault: with Screen Recording access the canvas opens and every ordinary application window on screen lives on it: existing windows are adopted, a new one is placed by window_placement, a closed one leaves (or leaves a stand-in under session.suspend_on_close). Without that access the chooser is shown and nothing is captured.\n--manual: show the chooser first and capture only explicitly selected windows; no window is adopted automatically. Open canvas shows the saved world without adding one.\n--owned-resize-probe EMPTY_DIRECTORY [SCENARIO]: explicit noninteractive owned-fixture resize probe (live)\n--demo EMPTY_DIRECTORY: disposable interactive fixture, bounded to 60 seconds\n--demo-probe EMPTY_DIRECTORY: automated own-fixture E2E, no permission prompts\n--demo-probe-guard EMPTY_DIRECTORY: own-fixture interruption regression (expected exit 2)\n--experimental-native-resize: experimental eight-handle size-only native resize\n--experimental-native-navigation: accepted and ignored; window navigation and native focus are part of every normal run\n--no-native-focus: window focus stays logical; no native window is activated or raised\n--state ABSOLUTE_PATH: explicit persistent scene file (default Application Support/Infinify/scene.json)\n--socket ABSOLUTE_PATH: IPC socket of a normal run (default Application Support/Infinify/infinify.sock)\n--windowed [WIDTHxHEIGHT]: open the canvas at launch in one ordinary window (default 1200x800, at least 960x480) with no global shortcuts\n--config ABSOLUTE_PATH: DriftWM config file of a normal run (default $XDG_CONFIG_HOME/infinify/config.toml, else ~/.config/infinify/config.toml; DriftWM's built-in defaults when it is missing); read again whenever it changes\n--super CHORD: the physical keys of DriftWM's super/mod, a +-joined subset of ctrl|alt|cmd (default ctrl+alt)\nmsg [--json] [--socket PATH] COMMAND ...: DriftWM-style IPC client for the running app; opens no window\n--source DIR SECONDS NONCE: internal disposable child only\nKeys and pointer gestures are DriftWM's bindings from the config file: ctrl is Control, alt is Option, super (mod) is the --super chord. The status line shows the pointer, view, pan and bookmark chords registered, and each toolbar tooltip its own action's. With no config file and --super ctrl+alt the registered chords are:\n  Drag or two-finger scroll on empty canvas, Control-Option-drag or -scroll anywhere, three-finger swipe: pan; a released pan coasts (navigation.drift). Wheel or two-finger pinch on empty canvas, Control-Option-wheel or -pinch anywhere, three-finger pinch: anchored zoom (max 1x).\n  Option-drag on a window: world move/snap; add Shift: cluster. Held at the view's edge, a move pans the canvas under the window (navigation.edge_pan).\n  Trackpad gestures are DriftWM's [gestures] bindings: four-finger swipe: the nearest window that way. Four-finger hold: center the focused window. Four-finger pinch in / out: zoom-to-fit / home toggle. Three-finger tap, then three-finger swipe on a window: move it.\n  macOS takes three- and four-finger touches for its own gestures first: turn off Mission Control, App Expose, the full-screen swipe, Launchpad, Show Desktop and three-finger drag in System Settings for the canvas to receive them. Infinify changes no setting.\n  View actions animate one view's camera only (toolbar Home, Fit, -, 1:1, + or global shortcuts while the canvas is open; held zoom, pan and nudge keys repeat):\n  Control-Option-A: home toggle (origin at 1:1, again to return). Control-Option-W: zoom-to-fit toggle.\n  Control-Option-Equals / Control-Option-Minus: zoom in / out. Control-Option-0 or Control-Option-Z: zoom 1:1.\n  Control-Option-Command-arrows: pan the view under the pointer. Control-Option-Shift-arrows: nudge the focused window.\n  Control-Option-1 to 4: fly to bookmark 1 to 4. Control-Option-Shift-1 to 4: set it.\n  Window navigation flies the camera and focuses the window, natively when Infinify has Accessibility access (toolbar Center, Previous, Next):\n  Option-Tab / Option-Shift-Tab: cycle windows, most recently focused first; letting go of Option commits the choice.\n  Control-Option-arrows: the nearest window in that direction. Control-Option-C: center the focused window. Control-Option-X: center the window under the pointer.\n  A click on a window gives it canvas focus and starts its native focus, then the click is forwarded; a click on empty canvas unfocuses. Focusing a canvas window in its own application is followed.\n  Control-Option-Return: exec-terminal ($TERMINAL, else a new Terminal window). Control-Option-D: exec-launcher ($LAUNCHER, else Apps).\n  Control-Option-Command-Shift-arrows: send-to-output, the focused window to the display on that side (a world move; nothing with one display).\n  Control-Option-L: DriftWM's lock binding. Its swaylock is a Linux program: where that is not installed the displays are put to sleep instead, and macOS asks for the password as its Lock Screen setting says.\n  DriftWM's volume, brightness and media key defaults run Linux programs too: without those installed the keys stay with macOS.\n  Control-Option-Q: close-window. The focused window's own close button is pressed through Accessibility; a focused placeholder is dismissed.\nThe fixture modes (--demo*, --owned-resize-*) read no config and keep Option-drag pan, Command-wheel and pinch zoom and Control-Option-drag move; they take no trackpad touches.\nAn unbound click, drag or scroll on a window (left, right or middle button) is forwarded only to its selected, freshly validated source.\nNative keyboard/IME remain with the real app. Control-Option-Escape (until a binding takes that chord), Control-Option-Command-Shift-Q or Quit exits.\nResize status explains unavailable native layout resizing. No SIP/settings changes.");return 0;}
    BOOL child=argc==5&&!strcmp(argv[1],"--source"),demo=argc==3&&!strcmp(argv[1],"--demo"),guard=argc==3&&!strcmp(argv[1],"--demo-probe-guard"),probe=argc==3&&!strcmp(argv[1],"--demo-probe"),state=argc==3&&!strcmp(argv[1],"--state");
    if(argc!=1&&!child&&!demo&&!probe&&!guard&&!state)return 64;
    if((experimental||resize)&&(child||probe||guard))return 64;
    if((windowed||socket||config||chord||logical||manual)&&(child||demo||probe||guard))return 64;
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [ProbeApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    if(child){char *end=NULL;double seconds=strtod(argv[3],&end);if(!end||*end||!isfinite(seconds)||seconds<1||seconds>65)return 64;return source(@(argv[2]),seconds,@(argv[4]));}
    Desktop *desktop=[Desktop new];desktop.experimentalResize=resize;desktop.logicalFocus=logical;desktop.demo=demo||probe||guard;desktop.probe=probe||guard;desktop.interruptProbe=guard;desktop.windowed=windowed;desktop.windowSize=windowSize;
    if(demo||probe||guard){NSString *dir=@(argv[2]);BOOL isDir=NO;if(![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir]||!isDir||[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil].count)return 64;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];return runDemo(desktop,dir,probe||guard);}
    NSString *dir=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Infinify"];
    if(state){desktop.statePath=@(argv[2]);if(!desktop.statePath.isAbsolutePath)return 64;if(!socket)[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];}
    else {if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])return 2;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];}
    // Before the scene: the config decides what a load restores.
    desktop.configured=YES;desktop.configPath=config?@(config):nil;desktop.superChord=chord?@(chord):nil;[desktop loadConfig:YES];
    [desktop loadScene:desktop.statePath];
    // The app serves --socket or the default path only. INFINIFY_SOCKET is the client's: the app
    // never reads it, and sets it to the served path for the commands it starts.
    [desktop startIPC:socket?@(socket):[dir stringByAppendingPathComponent:@"infinify.sock"]];
    [[NSNotificationCenter defaultCenter]addObserver:desktop selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    // As DriftWM manages every toplevel: with Screen Recording access the canvas opens at
    // once and adopts the windows that exist. Without it, or with --manual, the chooser
    // comes first as it always did, and a windowed run still opens its canvas.
    desktop.managing=!manual;
    if(!desktop.startupError&&(windowed||(desktop.managing&&CGPreflightScreenCaptureAccess())))[desktop openCanvas:nil];else [desktop showChooser:nil];
    // Upstream runs autostart on every backend, its nested one included: a managed, a windowed and a chooser-first launch all do.
    [desktop runAutostart];
    while(!stopped){[desktop poll];pump(.08);}
    // Stopped first: the pending quit reply is written, and no request can arrive during cleanup.
    [desktop.ipc stop];desktop.ipc=nil;[desktop cleanup];[desktop.chooser close];return 0;
} }
