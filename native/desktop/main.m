// SPDX-License-Identifier: GPL-3.0-or-later
// The capture/router implementation is shared verbatim with our validated probe.
// Its private API provenance remains in native/captured-windows/captured.m.
#define main captured_probe_main
#include "../captured-windows/captured.m"
#undef main
#import <Carbon/Carbon.h>
#include "driftwm_desktop.h"
#import "controller-hit.h"
#import "native-drag-takeover.h"
#import "focus-driver.h"
#import "resize-driver.h"
#import "ipc-server.h"
#import "scene-writer.h"
#import "hotkeys.h"
#import "tap-keys.h"
#import "config-watcher.h"
#import "cycle-hold.h"
#import "hot-corners.h"
#import "input-sources.h"
#import "window-manager.h"
#import "window-observer.h"
#import "window-events.h"
#import "pan-launch.h"
#import "trackpad-gestures.h"
#import "multitouch-source.h"
#import "dock-guard.h"
#import "pointer-hover.h"
#import "canvas-cursor.h"
#import "canvas-renderer.h"
#import "compositor.h"
#import "frame-driver.h"
#import "login-item.h"
#import "native-desktop-cli.h"
#import "dock-reload.h"
#import "onboarding.h"
#import "system-takeover.h"
#import "session-watch.h"
#import "native-presenter.h"
#import "native-display-space.h"
#import "native-transition.h"
#import "native-views.h"
#import "native-placement-validation.h"
#import "native-replica-input.h"
#import "native-replica-family.h"
#import "native-tablet.h"
#import "native-pointer-grab.h"
#import "native-relative-motion.h"
#import "native-family.h"
#import "native-decorations.h"
#import "native-input.h"
#import "mac-wallpaper-cache.h"
#include "mac-wallpaper-refresh.h"
#include "capture-configuration.h"
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <os/lock.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#import "../focus/focus.h"
#import "../resize/resize.h"

// AppKit services the main run loop while waiting for an event, including
// dispatch blocks and timer/display callbacks. Keep the production poll's one
// deadline instead of rearming the probe's alternating 5 ms waits at idle.
// Events wake this wait immediately; a nonblocking turn after delivery also
// services callbacks when a continuous event stream never lets AppKit wait.
static void DWDesktopPump(double seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:deadline inMode:NSDefaultRunLoopMode dequeue:YES];
        if(event){[NSApp sendEvent:event];CFRunLoopRunInMode(kCFRunLoopDefaultMode,0,true);}
    } while(!stopped&&deadline.timeIntervalSinceNow>0);
}

static NSDictionary *pointJSON(CGPoint p) { return @{@"x":@(p.x),@"y":@(p.y)}; }
static NSDictionary *rectJSON(CGRect r) { return @{@"origin":pointJSON(r.origin),@"size":@{@"width":@(r.size.width),@"height":@(r.size.height)}}; }
static CGRect jsonRect(NSDictionary *r) { return CGRectMake([r[@"origin"][@"x"] doubleValue],[r[@"origin"][@"y"] doubleValue],[r[@"size"][@"width"] doubleValue],[r[@"size"][@"height"] doubleValue]); }
static CGPoint jsonPoint(NSDictionary *p) { return CGPointMake([p[@"x"] doubleValue],[p[@"y"] doubleValue]); }
static CGFloat screenTop(void) { return NSMaxY(NSScreen.screens.firstObject.frame); }
static CGRect topRect(NSRect r) { return CGRectMake(r.origin.x,screenTop()-NSMaxY(r),r.size.width,r.size.height); }
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
// AppKit sends screen-parameter notices for changes such as the Dock's usable
// rectangle as well as actual display changes. Only physical display geometry,
// density or cadence changes require new output layers. In particular a
// windowed canvas must retain its panel through a visibleFrame-only notice.
static NSDictionary *physicalScreens(void) {
    NSMutableDictionary *displays=[NSMutableDictionary dictionary];
    for(NSScreen *screen in NSScreen.screens){NSNumber *number=screen.deviceDescription[@"NSScreenNumber"];if(!number)continue;
        displays[number]=@{@"frame":NSStringFromRect(screen.frame),@"scale":@(screen.backingScaleFactor),@"fps":@(screen.maximumFramesPerSecond)};}
    return @{@"displays":displays,@"top":@(screenTop())};
}
// Experimental narrow edge cover only; it neither parks nor admits a source.
// Its physical mouse packets end here instead of reaching a window underneath.
@interface DWCaptureEdgeGuardView : NSView
@end
@implementation DWCaptureEdgeGuardView
- (BOOL)acceptsFirstMouse:(NSEvent *)event {(void)event;return YES;}
- (BOOL)acceptsFirstResponder {return NO;}
- (BOOL)mouseDownCanMoveWindow {return NO;}
- (void)mouseDown:(NSEvent *)event {(void)event;}
- (void)mouseUp:(NSEvent *)event {(void)event;}
- (void)mouseDragged:(NSEvent *)event {(void)event;}
- (void)rightMouseDown:(NSEvent *)event {(void)event;}
- (void)rightMouseUp:(NSEvent *)event {(void)event;}
- (void)rightMouseDragged:(NSEvent *)event {(void)event;}
- (void)otherMouseDown:(NSEvent *)event {(void)event;}
- (void)otherMouseUp:(NSEvent *)event {(void)event;}
- (void)otherMouseDragged:(NSEvent *)event {(void)event;}
- (void)scrollWheel:(NSEvent *)event {(void)event;}
- (void)magnifyWithEvent:(NSEvent *)event {(void)event;}
- (void)rotateWithEvent:(NSEvent *)event {(void)event;}
- (void)swipeWithEvent:(NSEvent *)event {(void)event;}
- (void)tabletPoint:(NSEvent *)event {(void)event;}
- (void)tabletProximity:(NSEvent *)event {(void)event;}
- (NSMenu *)menuForEvent:(NSEvent *)event {(void)event;return nil;}
@end
@interface DWCaptureEdgeGuardPanel : NSPanel
@end
@implementation DWCaptureEdgeGuardPanel
- (BOOL)canBecomeKeyWindow {return NO;}
- (BOOL)canBecomeMainWindow {return NO;}
@end
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
// The effect of a native size transaction in a controller reply, or nil. A sizing action's reply carries it under "effect",
// the key begin_native_resize answers with; an entry of "effects" is read the same way, which is where the attach of a window
// whose rule names a size carries it, its "effect" being the focus request.
static NSDictionary *sizeEffect(NSDictionary *reply) {
    for(id effect in [@[reply[@"effect"]?:NSNull.null] arrayByAddingObjectsFromArray:asArray(reply[@"effects"])]){NSString *op=asString(asDict(effect)[@"op"]);if([op isEqual:@"observe_resize_source"]||[op isEqual:@"resize_native_window"])return effect;}
    return nil;
}
// An input event's time as upstream's libinput timestamp: milliseconds, wrapping at 32 bits.
static NSNumber *eventMillis(NSEvent *e) { return @((uint32_t)(uint64_t)(e.timestamp*1000)); }
// Physical modifiers as the controller reads them: JSON booleans, since a boxed comparison would be sent as 0 or 1.
static NSDictionary *modifiersJSON(NSEventModifierFlags flags) { return @{@"control":flags&NSEventModifierFlagControl?@YES:@NO,@"option":flags&NSEventModifierFlagOption?@YES:@NO,@"shift":flags&NSEventModifierFlagShift?@YES:@NO,@"command":flags&NSEventModifierFlagCommand?@YES:@NO}; }
// The first line and how many follow: the status line has room for one.
static NSString *summary(NSString *subject,NSArray<NSString *> *lines) { return [NSString stringWithFormat:@"%@: %@%@",subject,lines[0],lines.count>1?[NSString stringWithFormat:@" (+%lu more)",(unsigned long)lines.count-1]:@""]; }
// v0.21.0's raise_nofile_limit and prepare_child (df3de27b26c7998e8a460cffd8a4925cbed3a322,
// third_party/driftwm/src/state/mod.rs): every client connection of the IPC server holds a descriptor and macOS
// starts a process with a soft limit of 256, so the soft limit goes up to what the system allows (kern.maxfilesperproc;
// its hard limit is unlimited). The limit the app started with is kept, and a command it starts gets it back, since
// some programs still select() on descriptors below 1024. posix_spawn has no hook between fork and exec, so sh restores
// it first. A relaunch (execv) carries the original in INFINIFY_ORIGINAL_NOFILE, which no command inherits.
static rlim_t originalOpenFiles=0;
static void raiseOpenFileLimit(void) {
    struct rlimit limit;if(getrlimit(RLIMIT_NOFILE,&limit))return;
    const char *carried=getenv("INFINIFY_ORIGINAL_NOFILE");if(carried&&strtoull(carried,NULL,10)){originalOpenFiles=(rlim_t)strtoull(carried,NULL,10);return;}
    int perProcess=0;size_t size=sizeof(perProcess);rlim_t ceiling=limit.rlim_max;
    if(!sysctlbyname("kern.maxfilesperproc",&perProcess,&size,NULL,0)&&perProcess>0&&(ceiling==RLIM_INFINITY||(rlim_t)perProcess<ceiling))ceiling=(rlim_t)perProcess;
    if(ceiling==RLIM_INFINITY||ceiling<=limit.rlim_cur)return;
    rlim_t original=limit.rlim_cur;limit.rlim_cur=ceiling;
    if(setrlimit(RLIMIT_NOFILE,&limit)){fprintf(stderr,"Infinify: setrlimit(NOFILE): %s\n",strerror(errno));return;}
    originalOpenFiles=original;char text[24];snprintf(text,sizeof(text),"%llu",(unsigned long long)original);setenv("INFINIFY_ORIGINAL_NOFILE",text,1);
}
// The exec effect, as upstream's exec_command: /bin/sh -c in a session of its own on
// /dev/null, with no other descriptor inherited and never waited on by the main loop.
// env overlays this process's environment; a null value removes the variable.
// The config path and log filter this process was started with are not passed on (v0.21.0: "Spawned
// apps no longer inherit ... the DRIFTWM_CONFIG and RUST_LOG it was started with"), nor are the INFINIFY_ debug
// and test switches; what the caller's env adds is applied after, so an [env] entry or INFINIFY_SOCKET still arrives.
// `missing` runs on the main queue when sh exits as it does for a program it
// cannot find (127) or cannot execute (126).
static NSString *execCommand(NSString *command,NSDictionary *env,void (^missing)(void)) {
    NSMutableDictionary<NSString *,NSString *> *environment=[NSProcessInfo.processInfo.environment mutableCopy];
    for(NSString *name in environment.allKeys)if([name isEqual:@"DRIFTWM_CONFIG"]||[name isEqual:@"RUST_LOG"]||[name hasPrefix:@"INFINIFY_"])[environment removeObjectForKey:name];
    for(NSString *name in env){if(asString(env[name]))environment[name]=env[name];else [environment removeObjectForKey:name];}
    NSMutableData *pointers=[NSMutableData data];const char *end=NULL;
    for(NSString *name in environment){const char *entry=[NSString stringWithFormat:@"%@=%@",name,environment[name]].UTF8String;if(entry)[pointers appendBytes:&entry length:sizeof(entry)];}
    [pointers appendBytes:&end length:sizeof(end)];
    char original[24];snprintf(original,sizeof(original),"%llu",(unsigned long long)originalOpenFiles);
    char *const direct[]={"sh","-c",(char *)command.UTF8String,NULL};
    char *const restoring[]={"sh","-c","ulimit -Sn \"$0\" 2>/dev/null; exec sh -c \"$1\"",original,(char *)command.UTF8String,NULL};
    char *const *arguments=originalOpenFiles?restoring:direct;
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
@class Desktop, DesktopView, LiveSource;
// INFINIFY_DEBUG_SYNTH=RATE, in a run with --only-pid and in no other: a load to measure the frame path with from a process that
// has no Screen Recording access and so captures nothing. Every bound source is handed RATE frames a second, each an
// IOSurface-backed 32BGRA buffer of the window's own pixel size (its bounds times 2) on which a band has moved, made on a
// background queue and delivered on the main queue to -installSample:, which is where and how a stream's frame arrives.
// As a stream does with its queue depth, it makes no frame while two it made are still waiting for the main thread.
// The buffers are five, written in turn: the source keeps one, the compositor that one and the one before it, and two may be on
// their way. Only the band's rows are written, so the load is the frames and not the filling of them. It ends with its source.
@interface SynthLoad : NSObject
+ (instancetype)loadFor:(LiveSource *)source rate:(double)rate;
- (void)stop;
@end
// A distinct output object fences each stream lifetime. Only retained samples
// and their metadata cross this worker; the source and renderer stay on main.
@interface DWRootCaptureMailbox : NSObject <SCStreamOutput>
- (instancetype)initWithSource:(LiveSource *)source stream:(SCStream *)stream diagnostics:(BOOL)diagnostics;
@property(readonly) dispatch_queue_t queue;
// Transport availability of an actually published image in this exact stream.
// This is not a pixel-quality, native placement or input-admission proof.
@property(readonly) BOOL currentImageAvailable;
// Revoke retained/pending pre-transition images. A later Complete or an explicit
// post-fence screenshot seed must install pixels before availability returns.
- (void)requireFreshImage;
// A request-owned screenshot can bootstrap a stationary guarded backing. Its
// reserved sequence is distinct from stream callback/Complete statistics.
- (NSDictionary *)reserveSnapshotSeed;
- (BOOL)installSnapshotSeed:(CMSampleBufferRef)sample token:(NSDictionary *)token;
- (NSDictionary *)diagnosticSnapshot;
- (void)stream:(SCStream *)stream startCompleted:(BOOL)succeeded;
- (void)cancel;
@end
@interface LiveSource : NSObject <SCStreamOutput,SCStreamDelegate>
@property Router *router;
@property NSDictionary *identity;
@property NSNumber *logical;
@property(nonatomic) SCStream *stream; // main-only; its setter retires the prior mailbox
@property DWRootCaptureMailbox *captureMailbox;
@property NSMutableArray<AVSampleBufferDisplayLayer *> *surfaces;
@property NSUInteger frames;
@property CGSize buffer;
@property NSString *error;
@property(nonatomic) BOOL detached; // main-only; retirement drops queued capture immediately
@property BOOL streamStopped;
@property CMSampleBufferRef latestSample;
// A managed run: the window the stream is made from, the title last reported, and
// whether the last frame is kept, while the stream runs, for a placement that returns.
@property SCWindow *window;
@property NSString *title;
@property BOOL keepSample;
// When its application reported the window destroyed (window-events.h), until the window list agrees or shows it is still there; 0 for none.
@property CFTimeInterval destroyed;
// A normal run: the compositor draws the stream's latest pixel buffer, kept here until
// the next one, and no display layer is fed. `presented` runs when a new one was kept.
@property BOOL composited;
@property CVPixelBufferRef pixels;
// Pixel crop belongs to the retained picture, including across intentional stops.
// CGRectNull is reserved for explicit full-buffer synthetic/export installation.
@property CGRect contentRect;
@property (copy) void (^presented)(void);
// INFINIFY_DEBUG's frame line (-frameStats), since it was last printed: screen frames the stream handed over, frames kept, and
// complete frames passed over because nothing in them had changed.
@property NSUInteger delivered,accepted,skipped;
// The stream was started or given a new size and has had no frame kept since: its next complete frame is kept whatever it
// says of itself. The picture held is from before (-stopCapture: keeps it), so "nothing changed" is not about that one.
@property BOOL restarted;
// Capture pixels are a presentation budget, never the native or world size. Configuration changes are serialized.
@property CGSize captureSize,captureNativeSize,captureCandidate;
@property CFTimeInterval captureCandidateSince;
@property double captureDemandDensity;
@property CFTimeInterval captureDemandSince;
@property(nonatomic) DWCaptureConfiguration captureConfiguration;
@property BOOL captureConfigurationMeasured;
@property(readonly) BOOL captureUpdating;
// A system-interrupted capture keeps its logical binding and last picture.
// Retries obtain a new shareable-window identity rather than reuse a stale filter.
@property BOOL captureRecovering;
@property BOOL nativeReplica,replicaWanted;
// An experimental backing is not an ordinary native owner. Its gate remains
// installed through revocation so retained pixels cannot reopen replica input.
@property(copy) BOOL (^capturedInputGate)(void);
@property BOOL captureBackingPresented;
@property NSUInteger captureFailures;
@property CFTimeInterval captureRetryAt;
@property uint64_t observationToken;
@property BOOL nativeMinimized,nativeVisibilityHeld,nativeVisibilityWanted,nativeVisibilityWriting;
@property uint64_t nativeVisibilityRevision;
@property CFTimeInterval nativeVisibilityRetryAt,nativeVisibilityStableSince;
@property NSDictionary *nativeVisibilityEffect,*nativeVisibilityRestore,*nativeVisibilityStable;
// Audited worker geometry for presentation discovery only; capture and input
// still require their own fresh native identity/parent checks.
@property NSDictionary *nativeFamily;
@property NSMutableDictionary *nativeMouseOwnership;
@property BOOL nativeMouseAdopting;
@property BOOL nativeTransferFamilyWanted; // exact audited family requested for a replica ownership handoff
@property NSDictionary *nativeButtons;
// Not hit-test authority: an origin-only observation waits for an exact AXMoved hint.
@property NSDictionary *nativeButtonsMoveCandidate;
@property(copy) NSString *nativeTitleDebugReason; // last reported reason, retained across routine cache invalidation
@property uint64_t nativeButtonsRevision;
@property BOOL nativeButtonsReading;
@property CFTimeInterval nativeButtonsNext;
- (void)invalidateNativeButtons;
// INFINIFY_DEBUG_SYNTH under --only-pid: the frames this source is fed instead of waiting for a capture; nil otherwise.
@property SynthLoad *synth;
- (BOOL)installSample:(CMSampleBufferRef)sample;
- (BOOL)installPixels:(CVPixelBufferRef)pixels;
- (BOOL)installPixels:(CVPixelBufferRef)pixels contentRect:(CGRect)crop;
- (BOOL)installCompositedSample:(CMSampleBufferRef)sample;
- (BOOL)acceptCapturedSample:(CMSampleBufferRef)sample stream:(SCStream *)stream received:(NSUInteger)received forceInstall:(BOOL)force;
- (void)clearSample;
- (void)captureFailed:(NSError *)error;
- (uint64_t)beginCaptureConfiguration:(SCStreamConfiguration *)configuration;
- (BOOL)completeCaptureConfiguration:(uint64_t)serial success:(BOOL)success;
- (NSDictionary *)captureConfigurationStatus;
@end
// ScreenCaptureKit's ContentRect is in surface points; ScaleFactor converts it
// to pixels. ContentScale describes original-content scaling, not a second
// pixel multiplier. Match the child capture crop contract without guessing a
// native extent from an output raster or treating padding as window content.
static BOOL DWRootCaptureCrop(NSDictionary *info,CVPixelBufferRef pixels,CGRect *crop) {
    if(!pixels||![info isKindOfClass:NSDictionary.class])return NO;
    id scale=info[SCStreamFrameInfoScaleFactor],contentScale=info[SCStreamFrameInfoContentScale];
    for(id value in @[scale?:NSNull.null,contentScale?:NSNull.null])
        if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()
            ||!isfinite([value doubleValue])||[value doubleValue]<=0)return NO;
    NSDictionary *value=asDict(info[SCStreamFrameInfoContentRect]);
    for(NSString *key in @[@"X",@"Y",@"Width",@"Height"]){id number=value[key];
        if(![number isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)number)==CFBooleanGetTypeID()||!isfinite([number doubleValue]))return NO;}
    CGRect content=CGRectZero;
    if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)value,&content))return NO;
    double s=[scale doubleValue];CGRect result=CGRectMake(content.origin.x*s,content.origin.y*s,content.size.width*s,content.size.height*s);
    if(!isfinite(result.origin.x)||!isfinite(result.origin.y)||!isfinite(result.size.width)||!isfinite(result.size.height)
        ||!isfinite(CGRectGetMaxX(result))||!isfinite(CGRectGetMaxY(result))||result.origin.x<0||result.origin.y<0
        ||result.size.width<=0||result.size.height<=0||CGRectGetMaxX(result)>CVPixelBufferGetWidth(pixels)||CGRectGetMaxY(result)>CVPixelBufferGetHeight(pixels))return NO;
    *crop=result;return YES;
}
@implementation LiveSource
- (instancetype)init { if((self=[super init]))_contentRect=CGRectNull;return self; }
- (void)invalidateNativeButtons { self.nativeButtonsRevision++;self.nativeButtons=nil;self.nativeButtonsMoveCandidate=nil;self.nativeButtonsNext=0; }
@synthesize stream=_stream;
@synthesize detached=_detached;
- (void)setDetached:(BOOL)detached {
    NSAssert(NSThread.isMainThread,@"Capture retirement is main-only");
    if(detached)[_captureMailbox cancel];_detached=detached;
}
- (void)setStream:(SCStream *)stream {
    NSAssert(NSThread.isMainThread,@"Capture streams are main-only");
    if(_stream==stream)return;
    [_captureMailbox cancel];
    if(_captureMailbox&&_stream)[_stream removeStreamOutput:_captureMailbox type:SCStreamOutputTypeScreen error:nil];
    _captureMailbox=nil;_stream=stream;DWCaptureConfigurationReset(&_captureConfiguration);
}
- (BOOL)captureUpdating { return _captureConfiguration.pending; }
- (uint64_t)beginCaptureConfiguration:(SCStreamConfiguration *)configuration {
    return DWCaptureConfigurationBegin(&_captureConfiguration,CGSizeMake(configuration.width,configuration.height),configuration.minimumFrameInterval);
}
- (BOOL)completeCaptureConfiguration:(uint64_t)serial success:(BOOL)success {
    return DWCaptureConfigurationComplete(&_captureConfiguration,serial,success);
}
static id captureConfigurationJSON(uint64_t serial,CGSize pixels,CMTime interval) {
    if(!serial||!CMTIME_IS_NUMERIC(interval)||interval.value<=0||interval.timescale<=0)return NSNull.null;
    return @{@"serial":@(serial),@"pixels":@[@(pixels.width),@(pixels.height)],
        @"minimum_frame_interval":@{@"value":@(interval.value),@"timescale":@(interval.timescale)},
        @"maximum_requested_hz":@((double)interval.timescale/interval.value)};
}
- (NSDictionary *)captureConfigurationStatus {
    if(!self.captureConfigurationMeasured)return nil;
    DWCaptureConfiguration state=_captureConfiguration;
    return @{@"state":self.error?@"failed":!self.stream?@"stopped":state.pending?@"pending":state.acknowledgedSerial?@"acknowledged":@"unconfigured",
        @"requested":captureConfigurationJSON(state.serial,state.requestedPixels,state.requestedInterval),
        @"acknowledged":captureConfigurationJSON(state.acknowledgedSerial,state.acknowledgedPixels,state.acknowledgedInterval),
        @"note":@"Submitted and successfully completed configuration requests for this stream; not measured delivery or presentation cadence."};
}
static BOOL recoverableCaptureError(NSError *error) {
    if(![error.domain isEqual:SCStreamErrorDomain])return NO;
    switch(error.code){
        case SCStreamErrorFailedToStart:case SCStreamErrorFailedApplicationConnectionInvalid:
        case SCStreamErrorFailedApplicationConnectionInterrupted:case SCStreamErrorFailedNoMatchingApplicationContext:
        case SCStreamErrorAttemptToStartStreamState:case SCStreamErrorAttemptToStopStreamState:
        case SCStreamErrorAttemptToUpdateFilterState:case SCStreamErrorAttemptToConfigState:
        case SCStreamErrorInternalError:case SCStreamErrorNoWindowList:case SCStreamErrorNoDisplayList:
        case SCStreamErrorNoCaptureSource:case SCStreamErrorSystemStoppedStream:return YES;
        default:return NO; // A user stop/declined permission is never retried.
    }
}
- (void)captureFailed:(NSError *)error {
    [self.captureMailbox cancel];
    self.error=error.localizedDescription?:@"Capture failed";DWCaptureConfigurationReset(&_captureConfiguration);
    self.captureRecovering=recoverableCaptureError(error);
    if(self.captureRecovering){self.captureFailures=MIN(self.captureFailures+1,8u);self.captureRetryAt=CACurrentMediaTime()+MIN(30.,.25*exp2(self.captureFailures-1));}
    else self.captureRetryAt=0;
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { dispatch_async(dispatch_get_main_queue(),^{if(stream!=self.stream||self.detached)return;self.stream=nil;[self captureFailed:error];}); }
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if(type!=SCStreamOutputTypeScreen)return;
    [self acceptCapturedSample:sample stream:stream received:1 forceInstall:NO];
}
- (BOOL)acceptCapturedSample:(CMSampleBufferRef)sample stream:(SCStream *)stream received:(NSUInteger)received forceInstall:(BOOL)force {
    NSAssert(NSThread.isMainThread,@"Capture installation is main-only");
    if(stream!=self.stream)return NO;
    if(self.detached||self.error||!CMSampleBufferIsValid(sample)||!CMSampleBufferGetImageBuffer(sample))return NO;
    self.delivered+=received;
    CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
    if(!a||!CFArrayGetCount(a))return NO;
    NSDictionary *info=asDict((__bridge id)CFArrayGetValueAtIndex(a,0));if(!info)return NO;
    if(![info[SCStreamFrameInfoStatus]isKindOfClass:NSNumber.class]||[info[SCStreamFrameInfoStatus]integerValue]!=SCFrameStatusComplete)return NO;
    CGRect crop=CGRectNull;
    if(self.composited&&!DWRootCaptureCrop(info,CMSampleBufferGetImageBuffer(sample),&crop))return NO;
    // A complete frame that says nothing in it changed is the picture already kept: installing it would redraw the scene for
    // nothing. One that does not say (no dirty rectangles at all) is installed, and so is any frame while no picture is kept,
    // the first of a stream just started or resized, and one whose size is not the kept picture's.
    NSArray *dirty=info[SCStreamFrameInfoDirtyRects];CVImageBufferRef image=CMSampleBufferGetImageBuffer(sample);
    if(!force&&self.composited&&self.pixels&&!self.restarted&&CGRectEqualToRect(crop,self.contentRect)&&CVPixelBufferGetWidth(image)==CVPixelBufferGetWidth(self.pixels)&&CVPixelBufferGetHeight(image)==CVPixelBufferGetHeight(self.pixels)&&[dirty isKindOfClass:NSArray.class]&&!dirty.count){self.skipped++;return YES;}
    return [self installSample:sample];
}
- (BOOL)installCompositedSample:(CMSampleBufferRef)sample {
    if(!sample||!CMSampleBufferIsValid(sample))return NO;
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);CGRect crop=CGRectNull;
    // Synthetic load is an explicit full-buffer producer, never capture input.
    if(!self.synth){
        CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,NO);
        NSDictionary *info=attachments&&CFArrayGetCount(attachments)==1?asDict((__bridge id)CFArrayGetValueAtIndex(attachments,0)):nil;
        if(!DWRootCaptureCrop(info,pixels,&crop))return NO;
    }
    return [self installPixels:pixels contentRect:crop];
}
- (BOOL)installSample:(CMSampleBufferRef)sample {
    if(self.composited)return [self installCompositedSample:sample];
    CFArrayRef attachments=CMSampleBufferGetSampleAttachmentsArray(sample,YES);if(attachments&&CFArrayGetCount(attachments))CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments,0),kCMSampleAttachmentKey_DisplayImmediately,kCFBooleanTrue);
    CVImageBufferRef buffer=CMSampleBufferGetImageBuffer(sample);self.buffer=CGSizeMake(CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer));
    for(AVSampleBufferDisplayLayer *surface in self.surfaces){if(surface.hidden)continue;if(surface.sampleBufferRenderer.status==AVQueuedSampleBufferRenderingStatusFailed)[surface.sampleBufferRenderer flush];if(surface.sampleBufferRenderer.readyForMoreMediaData)[surface.sampleBufferRenderer enqueueSampleBuffer:sample];}
    if(self.keepSample){[self clearSample];self.latestSample=(CMSampleBufferRef)CFRetain(sample);}
    self.frames++;self.accepted++;self.captureFailures=0;self.captureRecovering=NO;self.captureRetryAt=0;return YES;
}
- (BOOL)installPixels:(CVPixelBufferRef)pixels {
    return [self installPixels:pixels contentRect:CGRectNull];
}
- (BOOL)installPixels:(CVPixelBufferRef)pixels contentRect:(CGRect)crop {
    if(!pixels)return NO;
    CGSize previous=self.buffer;self.buffer=CGSizeMake(CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels));
    if(!CGSizeEqualToSize(previous,self.buffer)&&getenv("INFINIFY_DEBUG"))fprintf(stderr,"capture: window=%s pixels=%.0fx%.0f\n",self.logical.stringValue.UTF8String,self.buffer.width,self.buffer.height);
    CVPixelBufferRetain(pixels);if(self.pixels)CVPixelBufferRelease(self.pixels);self.pixels=pixels;self.contentRect=crop;
    self.frames++;self.accepted++;self.restarted=NO;self.captureFailures=0;self.captureRecovering=NO;self.captureRetryAt=0;if(self.presented)self.presented();return YES;
}
- (void)clearSample {if(self.latestSample){CFRelease(self.latestSample);self.latestSample=NULL;}if(self.pixels){CVPixelBufferRelease(self.pixels);self.pixels=NULL;}self.contentRect=CGRectNull;}
- (void)dealloc { [_captureMailbox cancel];[_synth stop];if(_latestSample)CFRelease(_latestSample);if(_pixels)CVPixelBufferRelease(_pixels);if(_router.eventSource)CFRelease(_router.eventSource); }
@end
@implementation DWRootCaptureMailbox {
    __weak LiveSource *_source;
    __weak SCStream *_stream;
    os_unfair_lock _lock;
    CMSampleBufferRef _pending;
    BOOL _scheduled,_cancelled,_complete,_changed;
    uint64_t _callbackSequence,_pendingSequence,_publishedSequence,_unavailableSequence,_snapshotSequence;
    NSUInteger _received;
    BOOL _diagnostics,_hasLastStatus,_startCompleted,_startSucceeded;
    NSInteger _lastStatus;
    uint64_t _callbacks,_invalidSamples,_withoutImages,_withImages,_completeMetadata,_idleMetadata,_blankMetadata,
        _suspendedMetadata,_startedMetadata,_stoppedMetadata,_missingStatuses,_unknownStatuses,_staleCallbacks,
        _queuedSamples,_dequeuedSamples,_forwardedSamples,_staleDrains,_drains,_snapshotRequests,_snapshotPublished;
}
- (instancetype)initWithSource:(LiveSource *)source stream:(SCStream *)stream diagnostics:(BOOL)diagnostics {
    if((self=[super init])){_source=source;_stream=stream;_diagnostics=diagnostics;_lock=OS_UNFAIR_LOCK_INIT;
        dispatch_queue_attr_t attributes=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0);
        attributes=dispatch_queue_attr_make_with_autorelease_frequency(attributes,DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        _queue=dispatch_queue_create("org.infinify.root-capture",attributes);}
    return self;
}
- (BOOL)currentImageAvailable {
    NSAssert(NSThread.isMainThread,@"Capture availability is main-only");
    LiveSource *source=_source;SCStream *stream=_stream;
    if(!source||!stream||source.captureMailbox!=self||source.stream!=stream||source.detached||source.error)return NO;
    os_unfair_lock_lock(&_lock);BOOL available=!_cancelled&&_publishedSequence>_unavailableSequence;os_unfair_lock_unlock(&_lock);
    return available;
}
- (void)requireFreshImage {
    NSAssert(NSThread.isMainThread,@"Capture fencing is main-only");
    os_unfair_lock_lock(&_lock);
    _unavailableSequence=_callbackSequence==UINT64_MAX?UINT64_MAX:++_callbackSequence;
    os_unfair_lock_unlock(&_lock);
}
- (NSDictionary *)reserveSnapshotSeed {
    NSAssert(NSThread.isMainThread,@"Snapshot reservation is main-only");
    LiveSource *source=_source;SCStream *stream=_stream;
    if(!source||!stream||source.captureMailbox!=self||source.stream!=stream||source.detached||source.error)return nil;
    os_unfair_lock_lock(&_lock);NSDictionary *token=nil;
    if(!_cancelled&&_callbackSequence<UINT64_MAX&&_publishedSequence<=_unavailableSequence
        &&!(_pending&&_complete&&_pendingSequence>_unavailableSequence)){
        _snapshotSequence=++_callbackSequence;_snapshotRequests++;
        token=@{@"sequence":@(_snapshotSequence),@"floor":@(_unavailableSequence)};
    }
    os_unfair_lock_unlock(&_lock);return token;
}
- (BOOL)installSnapshotSeed:(CMSampleBufferRef)sample token:(NSDictionary *)token {
    NSAssert(NSThread.isMainThread,@"Snapshot publication is main-only");
    LiveSource *source=_source;SCStream *stream=_stream;
    if(!source||!stream||source.captureMailbox!=self||source.stream!=stream||source.detached||source.error
        ||!sample||!CMSampleBufferIsValid(sample)||!CMSampleBufferGetImageBuffer(sample))return NO;
    uint64_t sequence=[token[@"sequence"]unsignedLongLongValue],floor=[token[@"floor"]unsignedLongLongValue];
    os_unfair_lock_lock(&_lock);
    BOOL current=sequence&&sequence==_snapshotSequence&&sequence>floor&&!_cancelled&&floor==_unavailableSequence
        &&_publishedSequence<=floor&&!(_pending&&_complete&&_pendingSequence>floor);
    CMSampleBufferRef replaced=NULL;
    if(current){
        // A queued pre-fence Complete/Idle must not overwrite the new screenshot
        // after it becomes available. Keep an already scheduled drain's slot.
        replaced=_pending;_pending=NULL;_pendingSequence=0;_received=0;_complete=NO;_changed=NO;_snapshotSequence=0;
    }
    os_unfair_lock_unlock(&_lock);if(replaced)CFRelease(replaced);if(!current)return NO;
    BOOL installed=[source installSample:sample];
    os_unfair_lock_lock(&_lock);
    current=installed&&!_cancelled&&_stream==stream&&source.captureMailbox==self&&source.stream==stream
        &&!source.detached&&!source.error&&floor==_unavailableSequence&&_publishedSequence<=floor
        &&!(_pending&&_complete&&_pendingSequence>floor);
    if(current){_publishedSequence=sequence;_snapshotPublished++;}
    os_unfair_lock_unlock(&_lock);return current;
}
// Only the current stream's callback order matters. Idle preserves a published
// usable image; it cannot revive a revoked one. A new Complete needs publication,
// not just receipt, before the image can authorize an ownership request again.
- (uint64_t)observeAvailabilityLocked:(BOOL)valid image:(BOOL)image info:(NSDictionary *)info {
    uint64_t sequence=_callbackSequence==UINT64_MAX?UINT64_MAX:++_callbackSequence;
    NSNumber *status=[info[SCStreamFrameInfoStatus]isKindOfClass:NSNumber.class]?info[SCStreamFrameInfoStatus]:nil;
    BOOL known=valid&&status&&CFGetTypeID((__bridge CFTypeRef)status)!=CFBooleanGetTypeID()
        &&isfinite(status.doubleValue)&&floor(status.doubleValue)==status.doubleValue
        &&status.doubleValue>=SCFrameStatusComplete&&status.doubleValue<=SCFrameStatusStopped;
    if(sequence==UINT64_MAX||!known||(status.integerValue!=SCFrameStatusIdle&&!(status.integerValue==SCFrameStatusComplete&&image)))
        _unavailableSequence=sequence;
    return sequence;
}
// Instrumentation only, under the existing queue lock and explicitly enabled
// for scoped DebugCapture or opt-in native desktop stats. These counts do not
// claim frame acceptance or pixels.
- (void)recordCallbackLocked:(BOOL)valid image:(BOOL)image info:(NSDictionary *)info {
    _callbacks++;if(!valid)_invalidSamples++;else if(image)_withImages++;else _withoutImages++;
    NSNumber *status=[info[SCStreamFrameInfoStatus]isKindOfClass:NSNumber.class]?info[SCStreamFrameInfoStatus]:nil;
    _hasLastStatus=status&&isfinite(status.doubleValue)&&floor(status.doubleValue)==status.doubleValue
        &&status.doubleValue>=-0x1p63&&status.doubleValue<0x1p63;
    if(!_hasLastStatus){_missingStatuses++;return;}_lastStatus=status.integerValue;
    switch(_lastStatus){
        case SCFrameStatusComplete:_completeMetadata++;break;
        case SCFrameStatusIdle:_idleMetadata++;break;
        case SCFrameStatusBlank:_blankMetadata++;break;
        case SCFrameStatusSuspended:_suspendedMetadata++;break;
        case SCFrameStatusStarted:_startedMetadata++;break;
        case SCFrameStatusStopped:_stoppedMetadata++;break;
        default:_unknownStatuses++;break;
    }
}
- (NSDictionary *)diagnosticSnapshot {
    NSAssert(NSThread.isMainThread,@"Capture diagnostics are main-only");if(!_diagnostics)return nil;
    LiveSource *source=_source;SCStream *stream=_stream;BOOL current=source&&stream&&source.captureMailbox==self&&source.stream==stream;
    os_unfair_lock_lock(&_lock);
    NSDictionary *report=@{@"instrumentation_only":@YES,@"current_proxy":@(current),@"cancelled":@(_cancelled),
        @"start_completed":@(_startCompleted),@"start_succeeded":@(_startSucceeded),@"screen_callbacks":@(_callbacks),
        @"invalid_samples":@(_invalidSamples),@"valid_samples_without_image":@(_withoutImages),@"valid_samples_with_image":@(_withImages),
        @"last_status":_hasLastStatus?@(_lastStatus):NSNull.null,@"status_counts":@{@"complete":@(_completeMetadata),@"idle":@(_idleMetadata),
            @"blank":@(_blankMetadata),@"suspended":@(_suspendedMetadata),@"started":@(_startedMetadata),@"stopped":@(_stoppedMetadata),
            @"missing_or_invalid":@(_missingStatuses),@"unknown":@(_unknownStatuses)},
        @"stale_callbacks":@(_staleCallbacks),@"queued_samples":@(_queuedSamples),@"dequeued_samples":@(_dequeuedSamples),
        @"forwarded_to_source":@(_forwardedSamples),@"stale_drains":@(_staleDrains),@"drain_calls":@(_drains),
        @"snapshot_seed_requests":@(_snapshotRequests),@"snapshot_seed_published":@(_snapshotPublished),
        @"pending_sample":@(_pending!=NULL),@"drain_scheduled":@(_scheduled),@"pending_callbacks":@(_received)};
    NSMutableDictionary *availability=[report mutableCopy];availability[@"image_available"]=@(current&&!_cancelled&&_publishedSequence>_unavailableSequence);
    availability[@"callback_sequence"]=@(_callbackSequence);availability[@"published_callback_sequence"]=@(_publishedSequence);
    availability[@"unavailable_callback_sequence"]=@(_unavailableSequence);report=availability.copy;
    os_unfair_lock_unlock(&_lock);return report;
}
- (void)stream:(SCStream *)stream startCompleted:(BOOL)succeeded {
    if(!_diagnostics)return;os_unfair_lock_lock(&_lock);
    if(!_cancelled&&_stream==stream){_startCompleted=YES;_startSucceeded=succeeded;}
    os_unfair_lock_unlock(&_lock);
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if(type!=SCStreamOutputTypeScreen)return;
    BOOL valid=CMSampleBufferIsValid(sample),hasImage=valid&&CMSampleBufferGetImageBuffer(sample)!=NULL;
    CFArrayRef attachments=valid?CMSampleBufferGetSampleAttachmentsArray(sample,NO):NULL;
    NSDictionary *info=attachments&&CFArrayGetCount(attachments)?asDict((__bridge id)CFArrayGetValueAtIndex(attachments,0)):nil;
    if(!valid||!hasImage){
        os_unfair_lock_lock(&_lock);
        if(_diagnostics)[self recordCallbackLocked:valid image:hasImage info:info];
        if(!_cancelled&&_stream==stream)[self observeAvailabilityLocked:valid image:hasImage info:info];
        else if(_diagnostics)_staleCallbacks++;
        os_unfair_lock_unlock(&_lock);
        return;
    }
    BOOL complete=[info[SCStreamFrameInfoStatus]isKindOfClass:NSNumber.class]&&[info[SCStreamFrameInfoStatus]integerValue]==SCFrameStatusComplete;
    NSArray *dirty=info[SCStreamFrameInfoDirtyRects];BOOL changed=complete&&(![dirty isKindOfClass:NSArray.class]||dirty.count);
    CMSampleBufferRef replaced=NULL;
    os_unfair_lock_lock(&_lock);
    if(_diagnostics)[self recordCallbackLocked:valid image:hasImage info:info];
    if(_cancelled||_stream!=stream){if(_diagnostics)_staleCallbacks++;os_unfair_lock_unlock(&_lock);return;}
    CGRect crop=CGRectNull;
    BOOL geometry=!complete||DWRootCaptureCrop(info,CMSampleBufferGetImageBuffer(sample),&crop);
    uint64_t sequence=[self observeAvailabilityLocked:valid&&geometry image:hasImage info:info];
    _received++;
    // An idle/incomplete callback cannot evict a complete picture. Dirty-empty
    // means unchanged from its predecessor, which may itself be coalesced here.
    if(!_pending||complete||!_complete){
        if(_pending&&complete&&_complete){CVPixelBufferRef before=CMSampleBufferGetImageBuffer(_pending),after=CMSampleBufferGetImageBuffer(sample);
            changed|=CVPixelBufferGetWidth(before)!=CVPixelBufferGetWidth(after)||CVPixelBufferGetHeight(before)!=CVPixelBufferGetHeight(after);}
        replaced=_pending;_pending=(CMSampleBufferRef)CFRetain(sample);_pendingSequence=sequence;_complete=complete;_changed|=changed;if(_diagnostics)_queuedSamples++;
    }
    BOOL schedule=!_scheduled;_scheduled=YES;
    os_unfair_lock_unlock(&_lock);
    if(replaced)CFRelease(replaced);
    if(schedule)dispatch_async(dispatch_get_main_queue(),^{[self drain];});
}
- (void)drain {
    os_unfair_lock_lock(&_lock);
    CMSampleBufferRef sample=_pending;_pending=NULL;uint64_t sequence=_pendingSequence;_pendingSequence=0;
    NSUInteger received=_received;BOOL complete=_complete,changed=_changed||_publishedSequence<=_unavailableSequence;
    if(_diagnostics){_drains++;if(sample)_dequeuedSamples++;}
    _received=0;_complete=NO;_changed=NO;BOOL cancelled=_cancelled;
    os_unfair_lock_unlock(&_lock);
    // The proxy is also the stream generation: a late old drain can neither
    // publish into nor remove a newer proxy's pending picture.
    LiveSource *source=_source;SCStream *stream=_stream;
    BOOL forward=sample&&!cancelled&&source.captureMailbox==self&&stream&&source.stream==stream&&!source.detached&&!source.error;
    BOOL published=forward&&[source acceptCapturedSample:sample stream:stream received:received forceInstall:changed];
    BOOL hadSample=sample!=NULL;
    if(sample)CFRelease(sample);
    os_unfair_lock_lock(&_lock);
    if(published&&complete&&!_cancelled&&_stream==stream&&source.captureMailbox==self&&source.stream==stream
        &&!source.detached&&!source.error)_publishedSequence=MAX(_publishedSequence,sequence);
    if(_diagnostics&&hadSample){if(forward)_forwardedSamples++;else _staleDrains++;}
    BOOL again=!_cancelled&&_pending;if(!again)_scheduled=NO;
    os_unfair_lock_unlock(&_lock);
    // Keep the scheduled flag through installation, even if it enters a nested
    // run loop. At most one drain runs or waits, plus one pending latest sample.
    if(again)dispatch_async(dispatch_get_main_queue(),^{[self drain];});
}
- (void)cancel {
    os_unfair_lock_lock(&_lock);_cancelled=YES;CMSampleBufferRef sample=_pending;_pending=NULL;_pendingSequence=0;_received=0;_complete=NO;_changed=NO;os_unfair_lock_unlock(&_lock);
    if(sample)CFRelease(sample);
}
- (void)dealloc {if(_pending)CFRelease(_pending);}
@end
// Production composited input requires a currently published capture image.
// The separate AV fixture renderer has no worker mailbox; its existing native
// binding checks still apply. Synthetic load pixels never authorize app input.
static BOOL DWCapturedInputAvailable(LiveSource *source) {
    return source&&!source.detached&&!source.error&&!source.synth
        &&(!source.capturedInputGate||source.capturedInputGate())
        &&(!source.composited||(source.pixels&&source.captureMailbox.currentImageAvailable));
}
// A one-shot export completion may run on any queue. GCD transfers its retained
// result to the main thread; an expired request never installs a late sample.
@interface DWExportFrame : NSObject {
@public
    _Atomic BOOL completed;
    CMSampleBufferRef sample;
    CVPixelBufferRef pixels;
    NSString *failure;
    NSArray<NSDictionary *> *nativeItems;
    DWNativePresenter *presenter;
    BOOL nativeFamilies;
}
@end
@implementation DWExportFrame
- (void)dealloc {if(sample)CFRelease(sample);if(pixels)CVPixelBufferRelease(pixels);}
@end
// A returned bootstrap sample may wait for an unrelated whole-frame ACK,
// but only inside the same one-second request deadline and exact binding.
@interface DWCaptureBackingSeed : DWExportFrame
@property NSDictionary *descriptor,*token;
@property DWRootCaptureMailbox *mailbox;
@property SCStream *stream;
@property SCWindow *window;
@property uint64_t configuration;
@property CGSize pixelSize;
@property CFTimeInterval deadline;
@end
@implementation DWCaptureBackingSeed
@end
// Main-thread state for one experimental source. Replacing another root never
// transfers its capture freshness or its pending screenshot into this binding.
@interface DWCaptureBackingState : NSObject
@property NSDictionary *descriptor;
@property DWNativeAppliedParking *receipt;
@property DWRootCaptureMailbox *mailbox;
@property DWCaptureBackingSeed *seed;
@property BOOL witnessed;
@property NSDictionary *physicalObservation; // last bounded diagnostic; no extra native queries
@property NSDictionary *readinessObservation;
@end
@implementation DWCaptureBackingState
@end
// Cold one-shot capture can lose its temporary stream while the source remains
// valid. Retry only recoverable ScreenCaptureKit failures, inside the original
// request deadline; authorization/configuration failures are final.
static BOOL DWExportRetryable(NSError *error) {
    if(![error.domain isEqual:SCStreamErrorDomain])return NO;
    switch(error.code){
        case SCStreamErrorFailedToStart:case SCStreamErrorInternalError:
        case SCStreamErrorFailedApplicationConnectionInterrupted:
        case SCStreamErrorNoWindowList:case SCStreamErrorNoCaptureSource:
        case SCStreamErrorSystemStoppedStream:return YES;
        default:return NO;
    }
}
// Immutable native capture plan, made on a read-only worker. Geometry is kept
// here in native coordinates; the renderer receives normalized image offsets.
static NSArray<NSDictionary *> *DWNativeExportPlan(NSArray<NSDictionary *> *roots,BOOL families,NSString *__autoreleasing *why) {
    NSMutableDictionary<NSNumber *,NSNumber *> *rank=[NSMutableDictionary dictionary],*owners=[NSMutableDictionary dictionary];
    // Only OnScreenOnly promises front-to-back ordering. Offscreen families
    // remain capturable, but supply no authority to interleave export families.
    NSArray *ordered=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
    for(NSUInteger i=0;i<ordered.count;i++){NSNumber *wid=asNumber(ordered[i][(id)kCGWindowNumber]),*pid=asNumber(ordered[i][(id)kCGWindowOwnerPID]);if(wid&&pid){if(rank[wid]){*why=@"native export stacking observation has duplicate windows";return nil;}rank[wid]=@(i);owners[wid]=pid;}}
    NSMutableArray<NSMutableDictionary *> *items=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSDictionary *root in roots){NSDictionary *identity=root[@"identity"];CGRect own=CGRectZero;
        if(!asString(root[@"capture_key"]).length||!DWNativeBounds([identity[@"wid"]unsignedIntValue],&own)||!isfinite(own.size.width)||!isfinite(own.size.height)||own.size.width<=0||own.size.height<=0){*why=@"native export could not read the root's own bounds";return nil;}
        NSArray *members=nil;
        if(families){NSDictionary *family=DWNativeWindowFamily(identity,why);if(!family)return nil;members=family[@"members"];}
        else members=@[@{@"identity":identity,@"native_bounds":rectJSON(own)}];
        BOOL hasRoot=NO,rankedFamily=YES;for(NSDictionary *member in members){NSDictionary *named=member[@"identity"];NSNumber *wid=named[@"wid"];
            if((rank[wid]&&![owners[wid]isEqual:named[@"pid"]])||[seen containsObject:wid]){*why=@"native export family changed during the stacking read";return nil;}
            if(!rank[wid])rankedFamily=NO;
            [seen addObject:wid];if([named isEqual:identity])hasRoot=YES;}
        if(!hasRoot){*why=@"native export family omitted its root";return nil;}
        members=[members sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            NSNumber *aw=a[@"identity"][@"wid"],*bw=b[@"identity"][@"wid"];
            if([aw isEqual:bw])return NSOrderedSame;
            if([aw isEqual:identity[@"wid"]])return NSOrderedAscending;if([bw isEqual:identity[@"wid"]])return NSOrderedDescending;
            // Unranked families keep a stable root-then-child fallback; no
            // partial observed order can move them through another family.
            return rankedFamily?[rank[bw]compare:rank[aw]]:[aw compare:bw];
        }];
        NSUInteger memberIndex=0;for(NSDictionary *member in members){CGRect r=jsonRect(member[@"native_bounds"]);
            CGRect unit=CGRectMake((r.origin.x-own.origin.x)/own.size.width,(r.origin.y-own.origin.y)/own.size.height,r.size.width/own.size.width,r.size.height/own.size.height);
            NSMutableDictionary *item=[root mutableCopy];item[@"member"]=member[@"identity"];item[@"native_bounds"]=member[@"native_bounds"];item[@"root_bounds"]=rectJSON(own);item[@"unit_rect"]=rectJSON(unit);
            item[@"capture_member_key"]=[NSString stringWithFormat:@"%@:%lu",root[@"capture_key"],(unsigned long)memberIndex++];if(rankedFamily)item[@"stack_rank"]=rank[member[@"identity"][@"wid"]];
            [items addObject:item];}
    }
    // Compare only relative ranks inside this request. An unrelated window can
    // enter the desktop without invalidating otherwise identical captured order.
    NSMutableArray *eligible=[NSMutableArray array];for(NSDictionary *item in items)if(item[@"stack_rank"])[eligible addObject:item];
    NSArray *ranked=[eligible sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"stack_rank"]compare:b[@"stack_rank"]];}];
    for(NSUInteger i=0;i<ranked.count;i++)ranked[i][@"stack_rank"]=@(i);
    NSMutableArray *frozen=[NSMutableArray arrayWithCapacity:items.count];for(NSDictionary *item in items)[frozen addObject:item.copy];return frozen.copy;
}
// Frozen one-shot evidence is separate from the live replica stream cohort.
static NSDictionary *DWExportOrderCohort(NSArray<NSDictionary *> *items) {
    NSMutableDictionary *cohort=[NSMutableDictionary dictionary];
    for(NSDictionary *item in items){if(!item[@"stack_rank"])continue;NSNumber *window=item[@"window"];NSMutableDictionary *family=cohort[window];
        if(!family){family=[@{@"children":[NSMutableDictionary dictionary]}mutableCopy];cohort[window]=family;}
        if([item[@"member"]isEqual:item[@"identity"]])family[@"root"]=item;
        else family[@"children"][item[@"capture_member_key"]]=item[@"stack_rank"];
    }
    NSMutableDictionary *frozen=[NSMutableDictionary dictionary];for(NSNumber *window in cohort){NSDictionary *family=cohort[window];if(family[@"root"])frozen[window]=@{@"root":family[@"root"],@"children":[family[@"children"]copy]};}return frozen.copy;
}
static NSArray<NSDictionary *> *DWExportOrderedTokens(NSArray<NSDictionary *> *tokens,NSDictionary *cohort,NSDictionary *snapshot) {
    if(!cohort.count)return tokens;
    NSMutableDictionary *bindings=[NSMutableDictionary dictionary];for(NSDictionary *window in snapshot[@"windows"])if(asDict(window[@"source"]))bindings[window[@"window"]]=window[@"source"];
    NSMutableArray *result=nil;
    for(NSUInteger start=0;start<tokens.count;){
        NSDictionary *first=tokens[start];if([first[@"barrier"]boolValue]){start++;continue;}
        NSUInteger end=start+1;while(end<tokens.count&&![tokens[end][@"barrier"]boolValue]&&[first[@"bucket"]isEqual:tokens[end][@"bucket"]])end++;
        NSMutableSet *roots=[NSMutableSet set],*ranks=[NSMutableSet set];NSMutableDictionary *keys=[NSMutableDictionary dictionary];NSMutableArray *ranked=[NSMutableArray array];NSNumber *previous=nil;BOOL valid=YES;
        for(NSUInteger i=start;i<end;i++){
            NSDictionary *token=tokens[i],*family=cohort[token[@"window"]],*root=family[@"root"],*binding=bindings[token[@"window"]];NSString *key=asString(token[@"key"]);NSNumber *rank=key?family[@"children"][key]:root[@"stack_rank"];
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
static BOOL DWNativeExportCurrent(NSDictionary *item,BOOL families) {
    NSDictionary *root=item[@"identity"],*member=item[@"member"];
    NSArray *born=@[member[@"birth_sec"],member[@"birth_usec"]];CGRect own=CGRectZero,rootOwn=CGRectZero;
    if(![birth([member[@"pid"]intValue])isEqual:born]||[windowInfo([member[@"wid"]unsignedIntValue])[(id)kCGWindowOwnerPID]intValue]!=[member[@"pid"]intValue]
        ||!DWNativeBounds([member[@"wid"]unsignedIntValue],&own)||!DWNativeBounds([root[@"wid"]unsignedIntValue],&rootOwn)
        ||!CGRectEqualToRect(own,jsonRect(item[@"native_bounds"]))||!CGRectEqualToRect(rootOwn,jsonRect(item[@"root_bounds"])))return NO;
    return !families||DWNativeWindowBelongsToRoot(member,root);
}
// The macOS 26 screenshot API returns an image rather than a live-stream sample.
// Convert it on the completion queue to the renderer's sRGB, IOSurface-backed BGRA.
static CVPixelBufferRef DWExportPixels(CGImageRef image) {
    if(!image)return NULL;size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);CVPixelBufferRef pixels=NULL;
    NSDictionary *attributes=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if(!width||!height||width>16384||height>16384||CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&pixels)!=kCVReturnSuccess)return NULL;
    if(CVPixelBufferLockBaseAddress(pixels,0)!=kCVReturnSuccess){CVPixelBufferRelease(pixels);return NULL;}
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels),width,height,8,CVPixelBufferGetBytesPerRow(pixels),color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);CGColorSpaceRelease(color);
    if(context){CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGContextRelease(context);}
    CVPixelBufferUnlockBaseAddress(pixels,0);if(!context){CVPixelBufferRelease(pixels);return NULL;}return pixels;
}
// 0 unless INFINIFY_DEBUG_SYNTH names a rate; at most 240 a second.
static double DWSynthRate(void) { static double rate=-1;if(rate<0){const char *text=getenv("INFINIFY_DEBUG_SYNTH");double value=text?strtod(text,NULL):0;rate=isfinite(value)&&value>0?fmin(value,240):0;}return rate; }
enum { SynthBuffers=5,SynthBand=64 };
@implementation SynthLoad {
    __weak LiveSource *_source;dispatch_source_t _timer;
    CVPixelBufferRef _ring[SynthBuffers];long _band[SynthBuffers]; // each buffer, and the row its band was last drawn at (-1: none yet)
    size_t _wide,_high;NSUInteger _made;
    _Atomic int _waiting;_Atomic uint64_t _size; // frames made and not yet taken; the window's pixel size as the main thread last read it, width in the high half
}
static uint64_t synthSize(CGSize pixels) { return (uint64_t)MAX(pixels.width,1)<<32|(uint32_t)MAX(pixels.height,1); }
+ (instancetype)loadFor:(LiveSource *)source rate:(double)rate {
    SynthLoad *load=[self new];load->_source=source;atomic_store(&load->_size,synthSize(source.buffer));
    dispatch_queue_t queue=dispatch_queue_create("org.infinify.synth",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    uint64_t interval=(uint64_t)(NSEC_PER_SEC/rate);dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);load->_timer=timer;
    // Each source starts somewhere of its own within a frame: streams do not deliver in step with one another.
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)arc4random_uniform((uint32_t)MIN(interval,UINT32_MAX))),interval,0);
    // The handler keeps the load until the timer is cancelled, and the buffers are let go on the queue that writes them.
    dispatch_source_set_event_handler(timer,^{[load make];});
    dispatch_source_set_cancel_handler(timer,^{for(int i=0;i<SynthBuffers;i++)if(load->_ring[i]){CVPixelBufferRelease(load->_ring[i]);load->_ring[i]=NULL;}});
    dispatch_resume(timer);return load;
}
static void synthRows(uint32_t *base,size_t rowBytes,size_t wide,long from,long count,uint32_t colour) { for(long y=from;y<from+count;y++)memset_pattern4((uint8_t *)base+(size_t)y*rowBytes,&colour,wide*4); }
- (void)make {
    if(!_source||atomic_load(&_waiting)>=2)return;
    uint64_t size=atomic_load(&_size);size_t wide=size>>32,high=(uint32_t)size;
    if(wide!=_wide||high!=_high){for(int i=0;i<SynthBuffers;i++)if(_ring[i]){CVPixelBufferRelease(_ring[i]);_ring[i]=NULL;}_wide=wide;_high=high;}
    int slot=(int)(_made%SynthBuffers);CVPixelBufferRef buffer=_ring[slot];BOOL fresh=!buffer;
    if(fresh){
        NSDictionary *attributes=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
        if(CVPixelBufferCreate(kCFAllocatorDefault,wide,high,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&buffer)!=kCVReturnSuccess||!buffer)return;
        _ring[slot]=buffer;_band[slot]=-1;
    }
    // BGRA, opaque: a grey field and an orange band that comes down it eight rows a frame.
    long band=MIN(SynthBand,(long)high),row=high>(size_t)band?(long)(_made*8%(high-(size_t)band)):0;const uint32_t field=0xff3a3a3a,orange=0xffff8c1a;
    if(CVPixelBufferLockBaseAddress(buffer,0)!=kCVReturnSuccess)return;
    uint32_t *base=CVPixelBufferGetBaseAddress(buffer);size_t rowBytes=CVPixelBufferGetBytesPerRow(buffer);
    if(fresh)synthRows(base,rowBytes,wide,0,(long)high,field);else if(_band[slot]>=0)synthRows(base,rowBytes,wide,_band[slot],band,field);
    synthRows(base,rowBytes,wide,row,band,orange);_band[slot]=row;CVPixelBufferUnlockBaseAddress(buffer,0);_made++;
    CMVideoFormatDescriptionRef format=NULL;CMSampleBufferRef sample=NULL;CMSampleTimingInfo timing={kCMTimeInvalid,CMClockGetTime(CMClockGetHostTimeClock()),kCMTimeInvalid};
    if(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,buffer,&format)==noErr)CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,buffer,format,&timing,&sample);
    if(format)CFRelease(format);if(!sample)return;
    atomic_fetch_add(&_waiting,1);
    dispatch_async(dispatch_get_main_queue(),^{
        LiveSource *source=self->_source;
        if(source&&!source.detached&&source.synth==self){
            source.delivered++;[source installSample:sample];
            CGRect bounds=CGRectZero;if(CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&bounds))atomic_store(&self->_size,synthSize(CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2))));
        }
        CFRelease(sample);atomic_fetch_sub(&self->_waiting,1);});
}
- (void)stop { dispatch_source_t timer=_timer;_timer=nil;if(timer)dispatch_source_cancel(timer); }
- (void)dealloc { [self stop]; }
@end
// The compositor reads a stream's buffers as sRGB values, and holds the current one and
// the one before it until the frame that sampled it has completed: its stream says sRGB
// and has buffers to spare. The layer tiles of probe, demo and owned-fixture runs keep
// the configuration their evidence was recorded with.
static void compositedStream(SCStreamConfiguration *config,LiveSource *source) {
    if(source.composited){config.colorSpaceName=kCGColorSpaceSRGB;config.queueDepth=5;}
    // A second output needs the whole root even when the native placement is
    // clipped by its output. Children have separate native identities and must
    // not silently change this image's root-relative geometry.
    if(source.composited||source.nativeReplica){config.ignoreGlobalClipSingleWindow=YES;config.includeChildWindows=NO;}
}
@interface DesktopView : FlippedView
- (NSDictionary *)hit:(CGPoint)point output:(NSNumber *)output;
- (NSDictionary *)resizeBorderForButton:(NSInteger)button flags:(NSEventModifierFlags)flags hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)output;
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
@property NSDictionary *pressedTarget;
@property BOOL pressedTablet;
@property NSNumber *pressedTabletDevice;
@property BOOL pressedPointerGrab;
@property CGPoint pressedLocal;
@property int64_t pressedButton; // CGMouseButton held down in pressedSource
// An unbound press on a window whose native focus is still being asked for, kept back until that request is answered
// (-holdPress:window:intent:at:output:): the press, its exact recipient before focus changes, where and on which output it fell,
// its latest drag, whether its button is up again, and any navigation waiting for that click to finish.
@property NSEvent *heldPress,*heldDrag,*heldRelease;
@property NSNumber *heldWindow,*heldOutput;
@property NSDictionary *heldIntent;
@property BOOL heldNavigate;
@property CGPoint heldPoint,heldDragPoint;
@property BOOL heldReleased;
@property CFTimeInterval heldSince;
@property NSTimer *heldTimer;
@property NSNumber *resizeTransaction;
@property NSInteger gesture; // 1 pan, 2 logical world drag, 3 native pointer, 4 native resize
@property NSInteger gestureButton; // NSEvent button number that began the gesture
// An event intercepted above a real native window keeps its global Quartz point;
// its AppKit location belongs to that window, not to this canvas panel.
@property BOOL nativePointValid;
@property CGPoint nativePoint;
// Only for a freshly validated native child recipient outside its root's tile.
// This supplies the root's binding context, never synthetic app input.
@property NSDictionary *nativeFamilyHit;
// Only a positively identified native root drag region installs this intent.
// It keeps the binding/output of the swallowed physical pair, never app input.
@property NSDictionary *nativeTitlePress;
@property BOOL nativeTitleMoved,nativeTitleReleased;
- (BOOL)nativeTitlePressCurrent;
@property CFTimeInterval lastScrollPan; // last finger scroll that panned, 0 for none
@property BOOL clearsFocus; // a pan begun on empty canvas that has not moved 5 points yet: released so, it unfocuses
@property NSNumber *clickWindow; // the window an unbound press focused: released within 5 points, it is a completed click
@property NSNumber *scrollPan; // the output the trackpad scroll under way, or just lifted, panned; nil for none
@property NSTimeInterval scrollPanTime; // event time of that scroll's last pan, 0 once a press has ended it
@property NSTimeInterval lastDragPan; // event time of the last timed pan under this drag pan's button, its own or a scroll's; 0 for none
@property CFTimeInterval liftSeen; // when the gesture's button was first read as up while its gesture is still held; 0 while it is down
@property CFTimeInterval takenOverAt; // a native window drag taken over (-[Desktop takeOverNativeDrag:event:]): when; 0 for any other gesture
// --debug-pointer: a press the DebugPointer request made is down, with no physical button behind it; the timer ends one its test abandoned.
@property BOOL injected;
@property NSTimer *injectedTimer;
// That press: where it is now, a global screen point (where it went down, then where its last drag took it), where it went down, its
// button (0 left, 1 right, 2 middle) and the modifiers held with it.
@property CGPoint injectedPoint,injectedStart;
@property NSInteger injectedButton;
@property NSEventModifierFlags injectedFlags;
- (void)released:(CGPoint)p at:(NSTimeInterval)time;
- (void)render:(NSDictionary *)snapshot;
- (NSNumber *)outputAt:(CGPoint)p;
- (NSNumber *)actionOutput;
- (BOOL)forward:(CGEventRef)event at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate;
@end
@interface Desktop : NSObject <NSTableViewDataSource,NSTableViewDelegate,NSWindowDelegate,DWWindowHost>
@property DriftDesktop *controller;
@property DWCanvasCursor *canvasCursor;
@property DWResizeCoordinator *resize;
@property NSNumber *resizeSavedTransaction;
- (void)configureResize;
// Every normal run: DriftWM's sizing actions (grow-window, shrink-window, fit-window, fit-window-snapped, fill-window, IPC
// resize), a rule's size and fullscreen are size transactions the controller begins and continues by itself.
@property NSNumber *sizeTransaction; // the transaction a sizing action's effect last named
- (BOOL)sizing;
- (BOOL)resizes;
- (void)resizeCapability;
- (NSDictionary *)consumeSize:(NSDictionary *)reply;
@property DWNavigationCoordinator *navigation;
@property DWFrameDriver *frameDriver; // the frame timer: a display link, alive only while frames are wanted (-startFrames), and where the canvas is flushed
@property NSDictionary *panelScreens; // physical descriptors at the last panel/output creation
@property DWCaptureEdgeGuardPanel *captureEdgeGuard;
@property NSDictionary *captureEdgeGuardBasis,*captureEdgeGuardScreens;
@property CGRect captureEdgeGuardRect;
@property BOOL captureEdgeGuardDisabled;
@property uint64_t captureEdgeGuardEpoch;
@property NSMutableDictionary<NSNumber *,DWCaptureBackingState *> *captureBackings;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *captureBackingsRetiring,*captureBackingAdmissions;
@property NSMutableArray<NSDictionary *> *captureEdgeGuardLastBackings;
@property NSUInteger captureEdgeGuardWidth;
@property NSMutableArray<NSDictionary *> *retiredCaptureEdgeGuards;
- (BOOL)captureBackingEnabled;
- (NSArray<NSDictionary *> *)captureBackingMembers:(LiveSource *)source;
- (BOOL)captureBackingReady:(LiveSource *)source;
- (BOOL)captureBackingPlacementCurrent:(LiveSource *)source;
- (void)bootstrapCaptureBacking:(LiveSource *)source;
- (void)updateCaptureBacking:(NSDictionary *)snapshot;
- (void)revokeCaptureBacking;
- (void)revokeCaptureBackingForWindow:(NSNumber *)window;
- (NSDictionary<NSNumber *,NSDictionary *> *)captureBackingDescriptors;
- (void)drainRetiredCaptureEdgeGuards:(BOOL)finished;
- (void)configureCaptureEdgeGuard;
- (void)closeCaptureEdgeGuard:(BOOL)disable;
- (BOOL)captureEdgeGuardConsumes:(CGEventType)type event:(CGEventRef)event;
// A change of the compositor's asked for a frame since the frame timer last looked, and the frames it has since gone without one (-frameComing:).
@property BOOL frameOwed;
@property NSInteger frameQuiet;
@property CGPoint pointerReported; // where the pointer was when cursor edge pan was last told (-pointerFrame:)
@property NSTimer *statsTimer; // INFINIFY_DEBUG's frame line, every two seconds (-frameStats)
@property CFTimeInterval statsSince;
@property NSMutableDictionary<NSNumber *,LiveSource *> *exportSources; // one-shot export frames; native pixels retain the transformed window's density
@property NSMutableDictionary<NSNumber *,NSMutableArray<DWCanvasAttachment *> *> *exportAttachments;
@property NSDictionary *exportOrdering; // accepted immutable one-shot cohort only
@property BOOL frameFlying; // the frame timer serves camera motion, not only what the compositor animates by itself (a background, a window opening or leaving)
@property CFTimeInterval lastObservation;
@property CFTimeInterval lastResizeObservation;
@property CFTimeInterval lastPollTiming; // scoped debug: at most one slow-poll stage row per second
@property DWWindowObserver *windowObserver;
@property uint64_t observationEpoch;
@property BOOL windowObservationAgain; // one follow-up after a native family hint during an in-flight read
@property BOOL declineFrameQueued; // one frame is owed to windows the shell declined
@property CFMachPortRef navigationTap;
@property CFRunLoopSourceRef navigationTapSource;
@property BOOL logicalFocus; // --no-native-focus: no native window is ever activated or raised
@property BOOL focusNoted; // the status line has said that native focus lacks Accessibility
@property BOOL stageNoted; // stderr has said that Stage Manager is on, since it last was off
@property DWSystemTakeover *takeover; // a normal run only: Stage Manager and window tiling off while it is the desktop, put back at its end
@property DWCycleHold *cycleHold;
@property UInt32 cycleModifiers; // Carbon mask of upstream's cycle_hold
- (void)cancelNavigation;
- (void)configureNavigation;
- (void)stopNavigation;
- (void)activate:(NSNumber *)window output:(NSNumber *)output;
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output;
@property NSDictionary *nativeTitleClick;
@property NSTimer *nativeTitleClickTimer;
- (void)cancelNativeTitleClick;
- (void)deferNativeTitleClick:(NSDictionary *)intent;
- (void)fireNativeTitleClick:(NSTimer *)timer;
- (void)raiseFocus:(NSNumber *)window;
- (void)resizeFocus:(NSDictionary *)reply;
- (void)clearFocus;
- (void)ensureFrames;
- (BOOL)cameraFrame;
@property BOOL flying;
// Normal runs only: camera motion as DriftWM's. A released pan coasts in the controller;
// the shell says when a pan ends, and where the pointer is while cursor edge pan wants it.
@property DWPanLaunch *panLaunch;
// Normal runs only: where the pointer is has one reading (-outputUnderPointer:), for
// cursor edge pan's report and for hover alike, taken once a frame while the frame timer
// runs (-pointerFrame).
@property NSArray<NSDictionary *> *pointerOutputs; // the latest snapshot's outputs while panels are open, else nil
@property BOOL pointerWanted; // that snapshot asks for the pointer: cursor edge pan is on
- (NSNumber *)outputUnderPointer:(CGPoint)p;
- (void)panEnd:(NSNumber *)output;
@property EventHandlerRef viewHandler;
@property BOOL viewKeysWarned;
@property NSUInteger statusToken;
- (NSNumber *)viewOutput;
- (void)action:(NSString *)action output:(NSNumber *)output;
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held;
- (void)applyReply:(NSDictionary *)reply;
- (void)setNativeMinimized:(NSDictionary *)effect;
- (void)updateNativeVisibility;
- (void)requestVisibility:(LiveSource *)source;
- (void)observeVisibility:(DWWindowObservation *)observation source:(LiveSource *)source;
- (void)requestWindowObservation;
- (void)flashStatus:(NSString *)text;
// Normal runs only: keys, pointer gestures and settings come from the DriftWM config.
// Probe, demo and owned-fixture runs leave it off and keep the fixed chords and
// gestures they were validated with; they read no config and ask for no binding.
@property BOOL configured;
@property NSString *configPath; // --config; nil is the controller's default path
@property NSString *superChord; // --super; nil is ctrl+alt
@property DWHotKeys *hotKeys;
@property NSNumber *standinKeyboardWindow;
@property NSPanel *standinKeyboardPanel;
@property NSUInteger standinKeyboardSerial;
- (dispatch_block_t)standInEnter;
- (dispatch_block_t)nativeWindowControlKey:(DWNativeWindowControl)action;
- (void)updateStandInKeyboard:(NSDictionary *)snapshot;
@property DWTapKeys *tapKeys; // DriftWM's tap bindings, watched while the hot keys are registered
@property DWConfigWatcher *configWatcher;
@property NSString *configNote; // what a config load left for the status line and the error bar does not show: a --super chord or a load the controller refused
@property NSString *help; // the chords registered, for the status line
@property BOOL dismissFree; // no binding claims ⌃⌥-click on a window
- (void)loadConfig:(BOOL)platform;
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window;
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window under:(NSNumber *)under pick:(BOOL)pick;
// Normal runs only: trackpad gestures by DriftWM's [gestures] tables. Three or more
// fingers arrive as raw touches, and DWTrackpadGestures makes libinput's swipe, pinch
// and hold of them; a two-finger pinch is AppKit's magnify stream. The controller
// holds one gesture at a time and decides what it does.
@property DWTrackpadGestures *trackpad;
@property DWGlobalTrackpadInput *globalTrackpad;
@property BOOL globalTrackpadNoted,globalGestureDelivery,globalGestureContact;
// Desktop mode, where MultitouchSupport reports every contact wherever the pointer is: the touch source, its feed into the recogniser, and the tap that holds
// the system's Dock-control gestures back for the finger counts a [gestures] binding takes. While the source delivers, the NSTouch paths below feed nothing.
@property DWMultitouchSource *multitouch;
@property DWMultitouchFeed *touchFeed;
@property DWDockGuard *dockGuard;
@property DWDockTap *dockTap;
@property NSTimeInterval multitouchRetry;
@property (copy) NSString *touchPath; // INFINIFY_DEBUG: which source fed the recogniser last: multitouch, global-tap or view-touches
- (void)configureMultitouch;
- (void)multitouchFrame:(DWMultitouchFrame *)frame;
- (void)refreshGestureFingers;
- (void)configureGlobalTrackpad;
- (BOOL)globalGesturesEnabled;
- (BOOL)admitContact:(NSUInteger)fingers;
- (BOOL)admitGlobalTouches:(DWTrackpadTouchFrame *)frame;
- (void)globalTouches:(DWTrackpadTouchFrame *)frame;
- (BOOL)globalMagnify:(NSEvent *)event;
@property NSTimer *trackpadTimer; // armed for trackpadDeadline, the recogniser's next: hold delay, finger-count debounce
@property NSTimeInterval trackpadDeadline;
@property NSInteger gestureOwner; // whose gesture the controller holds: 0 none, 1 the recogniser's, 2 magnify's
@property NSNumber *gestureOutput; // the output that gesture began on
@property BOOL gestureWatched; // that gesture began with its output's panel under the pointer: while it is, the touches are the panel's
@property BOOL gestureMove; // the controller made a window move or resize of it: it holds a drag, or a resize grab, until its end
@property BOOL gestureResize; // that grab is a resize: a size transaction is held open for it (-configureResize)
- (void)endLostInput;
@property BOOL askingQueue; // -endLostInput is looking into the event queue for a release: a frame that runs inside that look does not look again
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
- (BOOL)startIPC:(NSString *)path;
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
// A normal run without --manual: every real application window (window-manager.h) lives on the
// canvas, as every toplevel does in DriftWM. The manager exists only while the canvas
// is open and Screen Recording access is granted; without it this run is the manual one.
@property BOOL managing;
@property DWWindowManager *manager;
// --only-pid: pid → that process's start time as read at launch (DWInScope), nil for none. With one, only windows of
// those processes are ever attached, and the manager exists without Screen Recording access too.
@property NSDictionary<NSNumber *,NSArray<NSNumber *> *> *scope;
@property BOOL debugPointer; // --debug-pointer: the DebugPointer request is served (-debugPointer:)
// --native-helper: the other way to present (native-presenter.h). The window server draws the real windows where the canvas places
// them and the panel draws none of them; nil in every other run, which is then the overlay and runs none of what this gates.
@property DWNativePresenter *native;
@property DWNativeViews *nativeViews;
@property DWNativeReplicaFamilies *nativeFamilies;
@property NSDictionary *overlayFamilySnapshot,*overlayFamilyBase,*overlayFamilyDescriptions;
@property NSDictionary *nativeViewSnapshot,*nativeOwnerSnapshot;
@property NSDictionary *nativeFillHandoff,*nativeRestoreDeferred;
@property NSArray *nativeFillBackgroundTrace;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *nativeFillHistory;
@property NSMutableSet<NSNumber *> *nativeFillRefusedTransactions;
@property DWNativeResizeDriver *nativeResizeDriver;
@property DWNativeHiddenRoot *nativeFillRoot;
@property DWNativeTransitionCapture *nativeFillCapture;
@property DWNativeTransition *nativeFillPicture;
@property BOOL nativeFillHiding,nativeFillAnimating,nativeFillAnimated,nativeFillRevealing;
@property CFTimeInterval nativeFillPresentationDeadline;
@property BOOL nativeFillResuming;
@property uint64_t nativeFillBlockedButtons;
@property BOOL nativeFillBlockedScroll;
@property (weak) LiveSource *nativeMouseOwner;
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons;
- (void)updateNativeMouseOwners;
- (void)prepareNativeFill:(NSDictionary *)effect;
- (BOOL)deferNativeRestore:(NSDictionary *)effect;
- (BOOL)nativeRestoreDeferredCurrent:(NSDictionary *)deferred snapshot:(NSDictionary *)snapshot;
- (void)retireDeferredNativeRestore;
- (void)updateDeferredNativeRestore;
- (void)clearNativeFillPresentation;
- (BOOL)nativeFillCurrent:(NSDictionary *)held snapshot:(NSDictionary *)snapshot;
- (void)updateNativeFill;
- (void)interruptFillForVisibility:(LiveSource *)source;
@property DWNativePresenter *nativeViewPresenter;
@property NSUInteger nativeFamilyRevision,nativeViewFamilyRevision;
@property BOOL nativeViewEnabled;
@property uint64_t nativeViewTransferRevision,nativePlacementRequestRevision;
@property NSTimer *nativeTransferTimer;
@property CFTimeInterval nativeTransferUntil,nativeTransferNextCheck;
@property NSUInteger nativeTransferCursor;
@property DWNativeViewTransfer *nativeOwnershipTransfer;
@property CFTimeInterval nativeOwnershipDeadline;
// Physical hover observation is coalesced in the tap; staging happens later.
@property NSDictionary *nativeHoverObservation;
@property NSDictionary *nativeHoverPresentation;
@property DWNativeViewTransfer *nativeHoverTransfer;
@property (weak) DesktopView *nativeHoverView;
@property BOOL nativeHoverQueued;
@property uint64_t nativeHoverEpoch;
@property CFTimeInterval nativeHoverUntil;
- (void)queueNativeHover:(CGEventRef)event;
- (void)updateNativeHover;
- (void)cancelNativeHoverForWindow:(NSNumber *)window;
- (BOOL)nativeHoverAllowed;
- (BOOL)nativeOwnershipReady:(LiveSource *)source;
- (BOOL)nativeHoverSite:(LiveSource *)source hit:(NSDictionary *)hit view:(DesktopView *)view output:(NSNumber *)output at:(CGPoint)point;
- (BOOL)queuedNativeHoverPress:(NSEvent *)event source:(LiveSource *)source hit:(NSDictionary *)hit view:(DesktopView *)view output:(NSNumber *)output at:(CGPoint)point;
- (DWNativeViewTransfer *)requestNativeOwnershipAt:(CGPoint)point view:(DesktopView *)view;
- (void)advanceNativeTransfers;
- (void)startNativeTransferTimer;
- (void)stopNativeTransferTimer;
- (NSDictionary *)nativeDescription:(NSDictionary *)snapshot;
- (NSDictionary *)presentationSnapshot;
- (void)forgetNativeFamily:(LiveSource *)source;
@property NSArray<NSDictionary *> *nativeEndpoints; // authenticated launch endpoints, never rediscovered
@property DWDockReloader *dockReloader; // compositor mode with the launch daemon on: loads the payload into a Dock that replaced the one the helper lived in
@property BOOL nativeDesktopMode; // explicit login-user desktop authority, never inferred from an empty scope
@property BOOL nativeRestoring,nativeResumeWanted,nativeResumeInFlight;
@property uint64_t nativeSessionEpoch;
@property NSUInteger nativeResumeFailures;
@property CFTimeInterval nativeResumeAfter;
@property NSString *nativeResumeNote;
- (BOOL)nativeUnavailable;
- (void)suspendPresentationLeavingSession:(BOOL)leaving;
- (void)resumeNative;
@property DWNativeInput *nativeInput;
@property DWNativeTabletRouter *tablet;
@property DWNativePointerGrab *pointerGrab;
@property DWNativeRelativeMotion *relativeMotion;
@property NSMutableSet<NSNumber *> *postingTags;
@property NSDictionary *controllerSnapshot,*controllerVisualSnapshot,*renderedPresentation;
@property (copy) NSString *renderedStatusText;
- (NSDictionary *)visualSnapshot;
- (BOOL)validateInputTarget:(NSDictionary *)target;
- (BOOL)postInput:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local;
- (BOOL)forwardTabletTail:(CGEventRef)event;
- (void)cancelCapturedInputForWindow:(NSNumber *)window;
- (NSDictionary *)resolveCapturedPointer:(NSDictionary *)target screen:(CGPoint)screen;
- (BOOL)forwardCapturedPointer:(CGEventRef)event screen:(CGPoint)screen;
@property DesktopView *nativeGestureView,*nativeScrollView;
@property DesktopView *nativeMagnifyView;
@property LiveSource *nativeMagnifySource;
@property BOOL nativePinchAccepted;
@property NSInteger nativeGestureButton;
@property NSTimeInterval nativeScrollTime;
@property BOOL nativeInputNoted;
// Set only while a fresh plain title down is evaluated at the session tap.
// The copied annotations select the common admission path; nothing is posted.
@property BOOL routingEarlyNativeTitle;
@property NSDictionary *nativeDecorationPress;
@property NSNumber *nativeButtonHover;
@property CFTimeInterval nativeButtonMotion;
@property dispatch_queue_t nativeButtonQueue;
@property BOOL screenshotBusy;
- (void)configureNativeInput;
- (void)cancelNativeInput;
- (BOOL)earlyNativeTitle:(CGEventType)type event:(CGEventRef)event;
- (BOOL)nativeInput:(CGEventType)type event:(CGEventRef)event;
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point;
- (void)refreshNativeButtons:(LiveSource *)source;
- (BOOL)nativeGreen:(LiveSource *)source at:(CGPoint)point;
- (BOOL)replicaGreen:(LiveSource *)source at:(CGPoint)point output:(NSNumber *)output;
- (void)prepareScreenshot:(NSDictionary *)effect completed:(void (^)(NSString *))completed;
- (void)captureExportWindows:(NSArray<NSNumber *> *)windows index:(NSUInteger)index content:(SCShareableContent *)content request:(DWExportFrame *)request completed:(void (^)(NSString *))completed;
- (void)captureNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt content:(SCShareableContent *)content completed:(void (^)(NSString *))completed;
- (void)requestNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt completed:(void (^)(NSString *))completed;
- (void)retryNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt error:(NSError *)error completed:(void (^)(NSString *))completed;
@property BOOL adopted; // adoption_complete was sent for the manager in place
@property NSString *discoveryNote; // the failed-read note last written to stderr
@property BOOL sceneDirty; // window or camera changes: coalesced into the next poll's save
@property DWSceneWriter *sceneWriter;
// Normal runs only: the canvas is drawn the way DriftWM draws it, one compositor layer
// per output. Probe, demo and owned-fixture runs keep the layer tiles their recorded
// evidence depends on and never create it.
@property DWCanvasRenderer *compositor;
- (DWCanvasRenderer *)canvasRenderer;
@property NSString *backgroundNote; // why the background is not the configured one, upstream's error bar
// Per-screen inherited stills. Workspace queries happen on refresh, image I/O
// and Metal upload on a worker; camera/video frames only reuse these programs.
@property NSMutableDictionary<NSNumber *,NSMutableDictionary *> *macWallpapers;
@property dispatch_queue_t wallpaperWorker;
@property NSTimer *wallpaperTimer;
@property id wallpaperSpaceObserver;
@property uint64_t wallpaperEpoch;
@property uint64_t wallpaperRefreshGeneration;

@property NSMutableArray<NSPanel *> *panels;
@property NSMutableArray<DesktopView *> *views;
@property NSMutableDictionary<NSNumber *,LiveSource *> *sources;
@property NSMutableArray<NSDictionary *> *choices;
@property NSMutableArray *pendingStops; // sources being detached, and streams stopped on demand
@property BOOL captureRecoveryReading;
@property NSUInteger captureRecoveryGeneration;
@property NSUInteger captureStopsTimedOut;
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
- (void)fillRebind:(BOOL)keep;
- (void)quit:(id)sender;
- (void)attachChoice:(id)sender;
- (void)openCanvas:(id)sender;
- (void)takeOverWindowSettings;
- (void)putBackWindowSettings;
- (void)grantAccess:(id)sender;
- (BOOL)attach:(DWWindowCandidate *)window logical:(NSNumber *)logical world:(NSDictionary *)world;
- (void)poll;
- (void)saveScene;
- (BOOL)loadScene:(NSString *)path;
- (void)detach:(LiveSource *)source;
- (void)track:(LiveSource *)source info:(NSDictionary *)info;
- (void)cleanup;
@end
// DriftWM's pointer policy (pointer-hover.h), normal runs only: every panel's view hosts
// one, and probe, demo and owned-fixture runs have none. DWPolicyPress is a view's
// `gesture` while a press is the policy's: one in pick mode, or one bound to center-nearest.
static const NSInteger DWPolicyPress=9;
// How long a window the manager does not take for its own, but that belongs to a placed root's family, is left to the family reconciliation before the helper's veil is released for it.
static const NSTimeInterval DWFamilyChildGrace=.25;
@interface DesktopView ()
@property DWPointerHover *hover;
@end
@interface DesktopView (Pointer) <DWPointerHost>
- (void)refreshCursor;
@end
@interface Desktop ()
@property BOOL hoverUndelivered; // --no-hover-forwarding: pointer motion never reaches an application
@end
// A normal run is the desktop, as DriftWM is the session: one panel per display covering all of it, on every Space, with
// no strip, toolbar, status line or chooser. Probe, demo and owned-fixture runs keep all four as their evidence recorded them.
@interface Desktop () <NSApplicationDelegate>
@property NSString *said; // the status note last written to stderr (-say:)
@property DWOnboarding *onboarding; // the one window of a launch that cannot open its canvas yet
@property BOOL relaunch; // that window's Relaunch: main() starts this run again once it has ended
@property DWSessionWatch *session; // while the panels are open: wake, the session and the Space coming back (-returned)
@property BOOL sessionInactive;
@property BOOL sessionAwaitingCanvas; // preserve the loaded scene until an initially blocked launch opens its outputs
@property BOOL desktopUp; // the desktop's canvas is open, on however many displays there are: with none there it has no panel and is still open
- (void)say:(NSString *)note;
- (void)onboard;
@end
// A normal run's panel covers its display whole, the part under the menu bar and the Dock included: AppKit is not to
// move it into the area those leave free. Its level stays NSFloatingWindowLevel (3), above every ordinary window and
// below the Dock (20) and the menu bar (24), which both keep drawing over the canvas.
@interface DesktopPanel : CanvasPanel
@property BOOL standinKeyboard;
@end
@implementation DesktopPanel
- (BOOL)canBecomeKeyWindow {return self.standinKeyboard;}
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen { (void)screen;return frame; }
@end
@implementation DesktopView (Pointer)
// Hover asks once a frame, and what the controller refuses it is not news for the status line.
- (NSDictionary *)pointerCommand:(NSDictionary *)command quiet:(BOOL)quiet {
    Desktop *d=self.desktop;NSDictionary *childHover=nil,*childBounds=nil;
    if([d nativeUnavailable])return nil;
    if(d.configured&&[command[@"op"]isEqual:@"hover"]){
        if(d.native.ended||d.sessionInactive)return nil;
        CGPoint point=jsonPoint(command[@"screen"]);CGWindowID top=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
        LiveSource *source=[d nativeSource:top at:point];NSDictionary *replicaMember=nil;
        if(!source&&top==(CGWindowID)self.window.windowNumber){
            if(d.configured&&![d.compositor appliedOrderForOutput:command[@"output"] snapshot:[d presentationSnapshot]])return nil;
            NSDictionary *hit=[self hit:point output:command[@"output"]],*member=asDict(hit[@"native_member"]);NSNumber *window=asNumber(hit[@"window"]);LiveSource *candidate=window?d.sources[window]:nil;
            if(member&&candidate&&[d.nativeFamilies contains:candidate.logical identity:member[@"identity"] generation:member[@"generation"] bounds:jsonRect(member[@"native_bounds"])]&&DWNativeWindowBelongsToRoot(member[@"identity"],candidate.identity)){source=candidate;replicaMember=member;}
        }
        if(source){NSDictionary *binding=nil;for(NSDictionary *window in [d call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical])binding=asDict(window[@"source"]);
            if(!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"])return nil;
            if(replicaMember&&(![replicaMember[@"generation"]isEqual:binding[@"generation"]]||![binding[@"observation_known"]boolValue]))return nil;
            if(replicaMember){childBounds=replicaMember[@"native_bounds"];childHover=@{@"window":source.logical,@"output":command[@"output"],@"generation":binding[@"generation"],@"identity":replicaMember[@"identity"],@"root_identity":source.identity,@"native_member":@YES};}
            NSMutableDictionary *native=[command mutableCopy];native[@"op"]=@"hover_source";native[@"window"]=source.logical;native[@"identity"]=source.identity;native[@"generation"]=binding[@"generation"];if(replicaMember)native[@"forward_motion"]=@YES;command=native;
        }else if(top!=(CGWindowID)self.window.windowNumber)return nil;
    }
    NSString *status=d.statusText;NSDictionary *reply=[d call:command],*effect=asDict(reply[@"effect"]);
    if(childHover&&[effect[@"op"]isEqual:@"focus_native_window"]){
        // Hover already changed focus in place. A captured child's root must
        // never reach the AX driver: native root focus can dismiss its popup.
        BOOL current=[effect[@"window"]isEqual:childHover[@"window"]]&&[effect[@"generation"]isEqual:childHover[@"generation"]]
            &&boundIdentity(childHover[@"root_identity"],asDict(effect[@"identity"]))&&[d validateInputTarget:childHover]
            &&[d.nativeFamilies contains:childHover[@"window"] identity:childHover[@"identity"] generation:childHover[@"generation"] bounds:jsonRect(childBounds)];
        NSMutableDictionary *answer=[effect mutableCopy];answer[@"op"]=current?@"focus_logical":@"focus_result";if(!current)answer[@"success"]=@NO;
        BOOL settled=[d call:answer]!=nil;NSMutableDictionary *logical=[reply mutableCopy];logical[@"effect"]=NSNull.null;
        if(!current||!settled)logical[@"forward"]=@NO;reply=logical;
    }
    if(quiet)d.statusText=status;return reply;
}
- (void)pointerApply:(NSDictionary *)reply { [self.desktop applyReply:reply]; }
// As a window that took the focus by itself: the request is the coordinator's, which answers it focus_logical
// under --no-native-focus, and with none only work for a request the controller has dropped is withdrawn.
// The focus is saved on the next poll.
- (void)pointerFocused:(NSDictionary *)effect { [self.desktop.navigation perform:effect?@{@"effect":effect}:@{}];self.desktop.sceneDirty=YES;[self.desktop render]; }
// Upstream's hover and its pointer delivery stand down under a pointer grab. Here that is whatever has the pointer or
// the pad: a button down anywhere; a press any panel is handling, which is every drag there is (a pan, a window move
// by a bound press or by a pick-mode press, a press in a native window, a policy press); a trackpad gesture the
// recogniser has made of the touches or the controller holds, a move gesture's drag among them, and a magnify stream;
// a native resize that has not drained. The controller refuses the same on its own account (POINTER.md): this
// only keeps the question from being asked.
- (BOOL)pointerBusy {
    Desktop *desktop=self.desktop;
    if(!desktop||desktop.cleaning||desktop.sessionInactive||NSEvent.pressedMouseButtons||desktop.gestureOwner||desktop.magnifying||desktop.trackpad.engaged||desktop.compositor.hasGeometryTransitions)return YES;
    for(DesktopView *view in desktop.views)if(view.gesture||view.pressedSource)return YES;
    return NO;
}
- (NSNumber *)pointerSample:(CGPoint *)screen { CGPoint p=pointer();NSNumber *output=[self.desktop outputUnderPointer:p];*screen=p;return [self.outputs containsObject:output]?output:nil; }
- (BOOL)pointerFramed { return self.desktop.frameDriver!=nil; }
- (BOOL)pointerHeld { return [DWCycleHold modifiersDown]!=0; }
- (void)refreshCursor {
    Desktop *desktop=self.desktop;
    // Fill owns interaction until the same native root is revealed. There is
    // no canvas cursor to admit against its intermediate snapshot geometry.
    if(desktop.nativeFillHandoff){[desktop.canvasCursor releaseOwner:self];return;}
    NSPoint location=NSEvent.mouseLocation;CGPoint point=CGPointMake(location.x,screenTop()-location.y);
    NSNumber *output=[self outputAt:point];
    if(desktop.native){
        BOOL grab=NO;for(DesktopView *view in desktop.views)if(view.gesture==1||view.gesture==2||view.gesture==4){grab=YES;break;}
        // Native camera frames move real windows over a stationary pointer.
        // With no custom canvas cursor to claim, withdraw only our override;
        // querying WindowServer just to choose its ordinary arrow would stall
        // every frame. Actual motion/cursor events still take pointerCursor's
        // fresh recipient check, as do render-time pick, border and grab states.
        if(!grab&&(!output||[self pointerBusy]
            ||(!DWPickOutput([desktop visualSnapshot],output)
                &&!asDict([self pointerCommand:@{@"op":@"resize_border",@"output":output,@"screen":pointJSON(point)} quiet:YES][@"border"])))){
            [desktop.canvasCursor releaseOwner:self];return;
        }
    }
    [self pointerCursor:point output:output reply:nil];
}
// Only a canvas panel that would receive a physical click owns an override.
// Real application windows, the menu bar, Dock and chooser keep their cursor.
// This policy never guesses the cursor requested by a captured application.
- (void)pointerCursor:(CGPoint)p output:(NSNumber *)output reply:(NSDictionary *)reply {
    Desktop *d=self.desktop;
    if(d.nativeFillHandoff||!d.configured||d.cleaning||d.sessionInactive||!output||![self.outputs containsObject:output]||!self.window.visible||self.window.ignoresMouseEvents||!CGRectContainsPoint(self.globalBounds,p)){
        [d.canvasCursor releaseOwner:self];return;
    }
    DesktopView *grab=nil;
    for(DesktopView *view in d.views)if(view.gesture==1||view.gesture==2||view.gesture==4){grab=view;break;}
    if(!grab&&[self pointerBusy]){[d.canvasCursor releaseOwner:self];return;}
    NSPoint appPoint=NSMakePoint(p.x,screenTop()-p.y);
    if([NSWindow windowNumberAtPoint:appPoint belowWindowWithWindowNumber:0]!=self.window.windowNumber){[d.canvasCursor releaseOwner:self];return;}
    NSCursor *cursor=NSCursor.arrowCursor;
    if(grab.gesture==1||grab.gesture==2)cursor=NSCursor.closedHandCursor;
    else if(grab.gesture==4){
        NSDictionary *resize=asDict([d call:@{@"op":@"snapshot"}][@"native_resize"]);
        if([resize[@"transaction"]isEqual:grab.resizeTransaction])cursor=DWCanvasResizeCursor(asString(resize[@"edges"]))?:cursor;
    }else {
        NSDictionary *hit=reply?asDict(reply[@"hit"]):[self hit:p output:output];
        BOOL pick=reply?[reply[@"pick"]boolValue]:[hit[@"pick"]boolValue];
        if(pick)cursor=NSCursor.pointingHandCursor;
        else if(!hit[@"native_member"]){
            NSDictionary *border=asDict([self pointerCommand:@{@"op":@"resize_border",@"output":output,@"screen":pointJSON(p)} quiet:YES][@"border"]);
            NSDictionary *recipient=border?[self hit:p output:output]:nil;
            if(!recipient[@"native_member"]&&(!recipient||[recipient[@"window"]isEqual:border[@"window"]]))cursor=DWCanvasResizeCursor(asString(border[@"edges"]))?:cursor;
        }
    }
    [d.canvasCursor setCursor:cursor owner:self];
}
// The motion itself, re-addressed like a click: -forward:… validates the source and maps the point into its window.
// Without Accessibility nothing is posted, and at this cadence nothing is said either.
- (void)pointerDeliver:(NSEvent *)motion at:(CGPoint)p output:(NSNumber *)output {
    if(!AXIsProcessTrusted()||self.desktop.compositor.hasGeometryTransitions)return;
    NSString *status=self.desktop.statusText;CGEventRef cg=motion.CGEvent?CGEventCreateCopy(motion.CGEvent):CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,p,kCGMouseButtonLeft);
    [self forward:cg at:p output:output activate:NO];if(cg)CFRelease(cg);self.desktop.statusText=status;
}
@end
// Is the native window behind a source gone: its process ended or was replaced, or the
// window list (`info`, for its window number) no longer has it under that owner?
static BOOL sourceGone(LiveSource *source,NSDictionary *info) { return ![birth(source.router.pid)isEqual:source.router.processBirth]||[info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid; }
@implementation DesktopView
- (BOOL)acceptsFirstResponder { return NO; }
// A real AppKit dragging session may ask us to bring its displayed destination
// to this output. The canvas never accepts the data or impersonates the target.
// Once the native site is in place, WindowServer/AppKit must rediscover that
// destination; its ordinary callbacks own types, operations and completion.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return [self draggingUpdated:sender]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if(sender.draggingDestinationWindow!=self.window||!self.desktop.native)return NSDragOperationNone;
    NSPoint point=[self convertPoint:sender.draggingLocation fromView:nil];
    [self.desktop cancelNativeHoverForWindow:nil];
    [self.desktop requestNativeOwnershipAt:CGPointMake(point.x+self.globalBounds.origin.x,point.y+self.globalBounds.origin.y) view:self];
    return NSDragOperationNone;
}
- (BOOL)wantsPeriodicDraggingUpdates { return YES; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { (void)sender;return NO; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { (void)sender;return NO; }
- (CGPoint)screenPoint:(NSEvent *)e { if(self.nativePointValid)return self.nativePoint;CGPoint p=[self convertPoint:e.locationInWindow fromView:nil]; return CGPointMake(p.x+self.globalBounds.origin.x,p.y+self.globalBounds.origin.y); }
- (NSNumber *)outputAt:(CGPoint)p {
    for(NSDictionary *o in [self.desktop call:@{@"op":@"snapshot"}][@"outputs"])if([self.outputs containsObject:o[@"id"]]&&CGRectContainsPoint(jsonRect(o[@"screen_bounds"]),p))return o[@"id"];
    return nil;
}
- (NSNumber *)actionOutput { return [self.outputs containsObject:self.lastOutput]?self.lastOutput:self.outputs.firstObject; }
// A normal run: one compositor layer per output draws the background, the outlines of
// the other outputs, the windows and the stand-ins from the snapshot: widgets below,
// screen-pinned windows above at their own size, each at the controller's opacity (a
// rule's, msg opacity's, or [decorations]').
- (void)compose:(NSDictionary *)snapshot {
    DWCanvasRenderer *canvas=[self.desktop canvasRenderer];CGPoint origin=self.globalBounds.origin;[CATransaction begin];[CATransaction setDisableActions:YES];
    CGFloat scale=self.window.backingScaleFactor,largest=scale;for(DesktopView *view in self.desktop.views)largest=MAX(largest,view.window.backingScaleFactor);
    [canvas render:snapshot outputs:self.outputs host:self.layer origin:origin scale:scale decorationScale:(NSInteger)ceil(largest)];
    // New or moved output layers commit their picture with their geometry; the frame timer serves later redraws.
    [canvas flushDescribed];
    [CATransaction commit];self.status.stringValue=self.desktop.statusText?:@"";
}
- (void)render:(NSDictionary *)snapshot {
    if(self.desktop.configured){[self compose:snapshot];[self refreshCursor];return;}
    NSMutableSet *keys=[NSMutableSet set]; [CATransaction begin];[CATransaction setDisableActions:YES];
    for(NSDictionary *p in snapshot[@"placements"]){
        if(![self.outputs containsObject:p[@"output"]])continue;
        NSString *key=[NSString stringWithFormat:@"%@:%@",p[@"window"],p[@"output"]];[keys addObject:key];
        CALayer *tile=self.tiles[key];if(!tile){tile=[CALayer layer];tile.masksToBounds=YES;tile.backgroundColor=[NSColor colorWithWhite:.16 alpha:1].CGColor;[self.layer insertSublayer:tile atIndex:0];self.tiles[key]=tile;}
        CGRect full=jsonRect(p[@"screen_rect"]),clip=jsonRect(p[@"clip_rect"]);tile.frame=CGRectOffset(clip,-self.globalBounds.origin.x,-self.globalBounds.origin.y);
        // The controller's opacity for the window, a rule's or msg opacity's, 1 without one: the tile and its picture fade as one.
        NSNumber *opacity=asNumber(p[@"opacity"]);tile.opacity=opacity?(float)MAX(0.0,MIN(1.0,opacity.doubleValue)):1;if(tile.opacity<1)tile.allowsGroupOpacity=YES;
        LiveSource *source=self.desktop.sources[p[@"window"]];
        AVSampleBufferDisplayLayer *surface=self.surfaces[key];BOOL newSurface=surface==nil;
        if(source&&!source.detached){
            if(!surface){for(CALayer *child in tile.sublayers.copy)[child removeFromSuperlayer];surface=[AVSampleBufferDisplayLayer layer];surface.videoGravity=AVLayerVideoGravityResize;[tile addSublayer:surface];self.surfaces[key]=surface;[source.surfaces addObject:surface];}
            surface.frame=CGRectMake(full.origin.x-clip.origin.x,full.origin.y-clip.origin.y,full.size.width,full.size.height);
            // A still window sends no frame: its kept one fills a placement that came back.
            if(newSurface&&source.latestSample&&surface.sampleBufferRenderer.readyForMoreMediaData)[surface.sampleBufferRenderer enqueueSampleBuffer:source.latestSample];
        }else{
            if(surface){[surface.sampleBufferRenderer flush];[surface removeFromSuperlayer];[self.surfaces removeObjectForKey:key];}
            if(!tile.sublayers.count){CATextLayer *text=[CATextLayer layer];text.string=[NSString stringWithFormat:@"Detached window %@\nChoose a source to rebind%@",p[@"window"],self.desktop.configured&&!self.desktop.dismissFree?@"":@"\n⌃⌥ click to dismiss"];text.fontSize=17;text.foregroundColor=NSColor.whiteColor.CGColor;text.wrapped=YES;text.frame=CGRectMake(12,12,MAX(40,clip.size.width-24),100);text.contentsScale=NSScreen.mainScreen.backingScaleFactor;[tile addSublayer:text];}
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
// The window of a hit the controller reported, for the binding lookup of a press or scroll over it. A stand-in's hit is
// built in -hit:output: and names none: upstream's pass_mouse_target_under answers only a client's content.
static NSDictionary *DWFocusedStandIn(NSDictionary *snapshot) {
    NSNumber *focused=asNumber(asDict(snapshot[@"focus"])[@"intent"]);
    if(!focused||asDict(asDict(snapshot[@"focus"])[@"pending_effect"])||asNumber(asDict(snapshot[@"focus"])[@"cycle"]))return nil;
    if(![asArray(asDict(snapshot[@"lifecycle"])[@"standins"])containsObject:focused])return nil;
    for(NSDictionary *window in asArray(snapshot[@"windows"]))if([window[@"window"]isEqual:focused])
        return [window[@"kind"]isEqual:@"standin"]&&!asDict(window[@"source"])?window:nil;
    return nil;
}
static NSNumber *liveHit(NSDictionary *hit) { return [hit[@"placeholder"]isEqual:@YES]?nil:asNumber(hit[@"window"]); }
static BOOL sameInputTarget(NSDictionary *a,NSDictionary *b) {
    if(!a||!b)return NO;
    for(NSString *key in @[@"window",@"output",@"generation",@"identity"])if(![a[key]isEqual:b[key]])return NO;
    return [(a[@"root_identity"]?:a[@"identity"])isEqual:(b[@"root_identity"]?:b[@"identity"])]&&[a[@"native_member"]boolValue]==[b[@"native_member"]boolValue];
}
// A held root press is authorized by its own completed focus request, not by
// the disappearance of any pending request. ObserveFocus may replace op/id while
// retaining the same observed binding, so only the result uses full effect equality.
static BOOL DWCapturedRootFocusCurrent(NSDictionary *intent,NSDictionary *focus,pid_t foreground,BOOL logicalOnly) {
    NSNumber *deadline=asNumber(intent[@"focus_deadline"]);double end=deadline.doubleValue;
    if(!deadline||!isfinite(end)||CACurrentMediaTime()>=end)return NO;
    // --no-native-focus deliberately retains the preexisting logical click path.
    if(logicalOnly)return YES;
    focus=asDict(focus);
    NSDictionary *effect=asDict(intent[@"focus_effect"]),*result=asDict(focus[@"last_result"]),*observed=asDict(focus[@"observed_native"]);
    if(![effect[@"op"]isEqual:@"focus_native_window"]||!asNumber(effect[@"effect_id"])
        ||![focus[@"intent"]isEqual:intent[@"window"]]
        ||asDict(focus[@"pending_effect"])||![asNumber(result[@"success"])isEqual:@YES]
        ||![result[@"effect"]isEqual:effect])return NO;
    for(NSString *key in @[@"window",@"generation"])
        if(![effect[key]isEqual:intent[key]]||![observed[key]isEqual:intent[key]])return NO;
    NSDictionary *identity=intent[@"root_identity"]?:intent[@"identity"];
    return boundIdentity(effect[@"identity"],identity)&&boundIdentity(observed[@"identity"],identity)
        &&foreground==[identity[@"pid"]intValue];
}
// A provisional click recipient, captured before raising/focusing the window.
// It prevents delayed delivery from changing recipients; posting still requires
// the current hit, binding and native ancestry checks in -forwardCaptured:.
- (NSDictionary *)inputIntentForHit:(NSDictionary *)hit output:(NSNumber *)output {
    NSNumber *windowID=liveHit(hit);if(!windowID)return nil;
    LiveSource *source=self.desktop.sources[windowID];if(!DWCapturedInputAvailable(source)||!output)return nil;
    NSDictionary *binding=nil;for(NSDictionary *window in [self.desktop presentationSnapshot][@"windows"])if([window[@"window"]isEqual:source.logical]){binding=asDict(window[@"source"]);break;}
    if(!binding[@"generation"]||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"observation_known"]boolValue])return nil;
    NSDictionary *member=asDict(hit[@"native_member"]),*identity=member?asDict(member[@"identity"]):source.identity;
    if(!identity||(member&&![member[@"generation"]isEqual:binding[@"generation"]]))return nil;
    return DWCapturedInputAvailable(source)?@{@"window":source.logical,@"output":output,@"generation":binding[@"generation"],@"identity":identity,@"root_identity":source.identity,@"native_member":@(member!=nil)}:nil;
}
- (NSDictionary *)hit:(CGPoint)p output:(NSNumber *)output {
    if(self.nativePointValid&&self.nativeFamilyHit)return self.nativeFamilyHit;
    // Controller input intentionally rejects placeholders. Find their geometry only
    // for the explicit dismiss action; this result never authorizes native delivery.
    NSDictionary *snapshot=[self.desktop presentationSnapshot];NSNumber *under=nil;
    BOOL inOutput=NO;for(NSDictionary *item in snapshot[@"outputs"])if([item[@"id"]isEqual:output]&&CGRectContainsPoint(jsonRect(item[@"screen_bounds"]),p))inOutput=YES;if(!inOutput)return nil;
    BOOL ordered=self.desktop.configured;
    NSArray *tokens=ordered?[self.desktop.compositor appliedOrderForOutput:output snapshot:snapshot]:snapshot[@"placements"];
    // Stale pixels/layout cannot authorize a differently ordered replica hit.
    if(ordered&&!tokens){
        if(self.desktop.routingEarlyNativeTitle&&getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native title hit refused output=#%s point=%g,%g reason=renderer_order\n",output.description.UTF8String,p.x,p.y);
        return nil;
    }
    NSMutableDictionary *placements=nil;if(ordered){placements=[NSMutableDictionary dictionary];for(NSDictionary *placement in snapshot[@"placements"])if([placement[@"output"]isEqual:output])placements[placement[@"window"]]=placement;}
    // Native replicas use exactly the renderer's described root/child order.
    // Placeholders still only authorize canvas actions, never native delivery.
    for(NSDictionary *token in [tokens reverseObjectEnumerator]){
        if(ordered&&!asNumber(token[@"window"]))continue;
        NSDictionary *placement=ordered?placements[token[@"window"]]:token;if(!placement||![placement[@"output"]isEqual:output])continue;
        NSString *key=ordered?asString(token[@"key"]):nil;
        LiveSource *source=self.desktop.sources[placement[@"window"]];CGRect site=jsonRect(placement[@"screen_rect"]),own=CGRectZero;
        if(source.router.bounds)CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&own);
        if((key||!ordered)&&source.pixels&&!source.error&&!source.detached&&(!self.desktop.native||[self.desktop.nativeViews replica:source.logical output:output])&&site.size.width>0&&site.size.height>0){
            CGPoint local=CGPointMake((p.x-site.origin.x)*own.size.width/site.size.width,(p.y-site.origin.y)*own.size.height/site.size.height);
            NSDictionary *member=key?[self.desktop.nativeFamilies hit:source.logical key:key local:local]:[self.desktop.nativeFamilies hit:source.logical local:local];
            if(member){NSMutableDictionary *context=[@{@"window":source.logical,@"local":pointJSON(local),@"native_member":member,@"generation":member[@"generation"]}mutableCopy];
                for(NSString *flag in @[@"widget",@"pinned"])if([asNumber(placement[flag])boolValue])context[flag]=@YES;
                return context[@"widget"]||context[@"pinned"]||[placement[@"fullscreen"]boolValue]?context:DWPickHit(context,snapshot,output);
            }
        }
        if(key)continue;
        // A family-only projection has no visible root content. Only an exact
        // captured child hit above can authorize a recipient in its clip.
        if([placement[@"family_only"]boolValue]||!CGRectContainsPoint(jsonRect(placement[@"clip_rect"]),p))continue;
        if(!source){NSMutableDictionary *held=[@{@"window":placement[@"window"],@"placeholder":@YES} mutableCopy];for(NSString *flag in @[@"widget",@"pinned"])if([asNumber(placement[flag])boolValue])held[flag]=@YES;return held[@"widget"]||held[@"pinned"]?held:DWPickHit(held,snapshot,output);}under=placement[@"window"];break;
    }
    if(ordered&&!under)return nil;
    NSDictionary *reply=[self.desktop call:@{@"op":@"hit",@"output":output,@"screen":pointJSON(p)}];
    return DWControllerHit(reply[@"hit"],ordered,under);
}
// INFINIFY_DEBUG in the environment: one stderr line for each click that goes to a window and each native focus request.
static BOOL DWInputTrace(void) { static int on=-1;if(on<0)on=getenv("INFINIFY_DEBUG")!=NULL;return on; }
// Fresh session-stage title admission only. These diagnostics use values already
// read by admission; they do not repeat native queries or change pair ownership.
static BOOL DWNativeTitleRefused(BOOL early,const char *reason,NSNumber *window,CGWindowID wid,CGPoint point,NSDictionary *detail) {
    if(early&&DWInputTrace()){
        NSData *data=detail?[NSJSONSerialization dataWithJSONObject:detail options:0 error:nil]:nil;
        NSString *json=data?[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]:nil;
        fprintf(stderr,"debug: native title admission refused window=#%s wid=%u point=%g,%g reason=%s detail=%s\n",window.description.UTF8String?:"?",wid,point.x,point.y,reason,json.UTF8String?:"{}");
    }
    return NO;
}
// This authorizes only our own chrome gesture, never forwarding content. The
// physical root must already be where the controller expects it, including the
// pin's unit scale; a stale capture/renderer receipt is immaterial to that fact.
static BOOL DWNativeChromeFrameMatches(CGRect own,CGRect displayed,NSDictionary *placement,NSDictionary *output,CGPoint point) {
    CGRect wanted=jsonRect(placement[@"screen_rect"]),clip=jsonRect(output[@"screen_bounds"]);
    double scale=[placement[@"pinned"]boolValue]?1:[output[@"zoom"]doubleValue];
    if(!isfinite(scale)||scale<=0||!isfinite(own.size.width)||!isfinite(own.size.height)||own.size.width<=0||own.size.height<=0
        ||!isfinite(displayed.origin.x)||!isfinite(displayed.origin.y)||!isfinite(displayed.size.width)||!isfinite(displayed.size.height)
        ||displayed.size.width<=0||displayed.size.height<=0||[placement[@"family_only"]boolValue]
        ||!CGRectContainsPoint(clip,point))return NO;
    return fabs(wanted.size.width-own.size.width*scale)<=1.01&&fabs(wanted.size.height-own.size.height*scale)<=1.01
        &&fabs(CGRectGetMinX(wanted)-CGRectGetMinX(displayed))<=1.01&&fabs(CGRectGetMaxX(wanted)-CGRectGetMaxX(displayed))<=1.01
        &&fabs(CGRectGetMinY(wanted)-CGRectGetMinY(displayed))<=1.01&&fabs(CGRectGetMaxY(wanted)-CGRectGetMaxY(displayed))<=1.01;
}
// Only the AXMoved callback may publish this translated cache. A generic
// observation may retain it privately, but cannot make it hit-test authority.
static NSDictionary *DWNativeMovedButtons(NSDictionary *report,NSDictionary *identity,CGRect native) {
    CGRect old=jsonRect(report[@"native_bounds"]);double sampled=[report[@"sampled_at"]doubleValue],age=CACurrentMediaTime()-sampled;
    if(!report||![report[@"identity"]isEqual:identity]||!isfinite(sampled)||sampled<=0||age<0||age>.5
        ||!isfinite(native.origin.x)||!isfinite(native.origin.y)||!isfinite(native.size.width)||!isfinite(native.size.height)
        ||native.size.width<=0||native.size.height<=0||!CGSizeEqualToSize(old.size,native.size))return nil;
    NSMutableDictionary *moved=[report mutableCopy];moved[@"native_bounds"]=rectJSON(native);return moved.copy;
}

// Failed AX refresh is not a new chrome observation. Only a still-public map
// can survive it, under its original title-hit age and exact native geometry.
// A returned report (including a negative title result) always supersedes it.
static NSDictionary *DWNativeButtonsAfterRefresh(NSDictionary *report,NSDictionary *current,NSDictionary *identity,
    CFTimeInterval now,BOOL nativeCurrent,CGRect native) {
    if(report)return now-[report[@"sampled_at"]doubleValue]<=.1?report:nil;
    double sampled=[current[@"sampled_at"]doubleValue],age=now-sampled;
    if(!current||!nativeCurrent||![current[@"identity"]isEqual:identity]||!isfinite(sampled)||sampled<=0
        ||!isfinite(age)||age<0||age>.5||!isfinite(native.origin.x)||!isfinite(native.origin.y)
        ||!isfinite(native.size.width)||!isfinite(native.size.height)||native.size.width<=0||native.size.height<=0
        ||!CGRectEqualToRect(jsonRect(current[@"native_bounds"]),native))return nil;
    return current;
}

// A child press may activate its application, but must never raise the root:
// doing so can dismiss an application's popup or take focus from its sheet.
- (BOOL)childPressCurrent:(NSDictionary *)intent {
    if(!asNumber(intent[@"window"])||![intent[@"native_member"]boolValue])return NO;
    Desktop *d=self.desktop;LiveSource *source=d.sources[intent[@"window"]];
    return source&&!source.detached
        &&![intent[@"identity"][@"wid"]isEqual:intent[@"root_identity"][@"wid"]]
        &&[d validateInputTarget:intent]&&DWNativeWindowBelongsToRoot(intent[@"identity"],source.identity);
}
- (BOOL)focusChildIntent:(NSDictionary *)intent {
    if(![self childPressCurrent:intent])return NO;Desktop *d=self.desktop;
    // Set canvas focus and settle the exact request logically before handing
    // any reply to the coordinator. This asserts no native root focus.
    NSDictionary *reply=[d call:@{@"op":@"focus",@"window":intent[@"window"]}],*effect=asDict(reply[@"effect"]);
    if(![effect[@"op"]isEqual:@"focus_native_window"]||![effect[@"window"]isEqual:intent[@"window"]]
        ||!boundIdentity(intent[@"root_identity"],asDict(effect[@"identity"]))||![effect[@"generation"]isEqual:intent[@"generation"]])return NO;
    NSMutableDictionary *ack=[effect mutableCopy];ack[@"op"]=@"focus_logical";NSDictionary *settled=[d call:ack];if(!settled)return NO;
    d.sceneDirty=YES;[d applyReply:settled];
    if(d.logicalFocus)return YES;
    LiveSource *source=d.sources[intent[@"window"]];NSRunningApplication *current=NSWorkspace.sharedWorkspace.frontmostApplication;
    if(current.processIdentifier==source.router.pid)return [self childPressCurrent:intent];
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:source.router.pid];
    // Validate process birth, current binding and ancestry immediately before
    // activating only this application's existing native focus/stack policy.
    if(!app||app.terminated||![self childPressCurrent:intent])return NO;
    d.previousFocus=current;d.previousFocusBirth=current.launchDate;return [app activateWithOptions:0];
}
// Whether the native focus request a click on `window` made is still unanswered.
- (BOOL)focusPending:(NSNumber *)window intent:(NSDictionary *)intent {
    if([intent[@"native_member"]boolValue]){
        if(self.desktop.logicalFocus)return NO;LiveSource *source=self.desktop.sources[window];
        if(!source||source.detached||!boundIdentity(source.identity,intent[@"root_identity"])||![birth(source.router.pid)isEqual:source.router.processBirth])return NO;
        return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=source.router.pid;
    }
    id pending=[self.desktop call:@{@"op":@"snapshot"}][@"focus"][@"pending_effect"];return asDict(intent[@"focus_effect"])&&[pending isEqual:intent[@"focus_effect"]];
}
// Upstream forwards the press of a click-to-focus to a client it has already focused. Here the focus is a request to another
// application that takes some tens of milliseconds, and until it has landed that application is not the active one: an
// event posted to it then is dropped by everything but a control that takes a first click (measured on a WKWebView and an
// Electron window, 2026-10-10: nothing arrived while inactive, every click did once active and key, covered or not). So
// a root press waits at most the focus coordinator's 1.5-second work budget; failure,
// supersession or expiry drops its whole unsent pair. Child activation keeps its
// existing half-second wait. Drags and release wait behind the same original press.
- (void)holdPress:(NSEvent *)e window:(NSNumber *)window intent:(NSDictionary *)intent at:(CGPoint)p output:(NSNumber *)output {
    [self deliverHeld];BOOL pending=[self focusPending:window intent:intent];
    if(!intent){self.clickWindow=nil;return;}
    CFTimeInterval now=CACurrentMediaTime();double wait=[intent[@"native_member"]boolValue]?.5:1.5;
    NSMutableDictionary *held=[intent mutableCopy];held[@"focus_deadline"]=@(now+wait);intent=held.copy;
    if(DWInputTrace()){LiveSource *s=self.desktop.sources[window];fprintf(stderr,"debug: press #%s pid=%d app=%s frontmost=%s focus_pending=%d\n",window.description.UTF8String,(int)s.router.pid,[NSRunningApplication runningApplicationWithProcessIdentifier:s.router.pid].bundleIdentifier.UTF8String?:"?",NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.UTF8String?:"?",(int)pending);}
    self.heldPress=e;self.heldWindow=window;self.heldIntent=intent;self.heldNavigate=NO;self.heldPoint=p;self.heldOutput=output;self.heldDrag=self.heldRelease=nil;self.heldReleased=NO;self.heldSince=now;
    if(!pending){[self deliverHeld];return;}
    __weak DesktopView *weak=self;self.heldTimer=[NSTimer timerWithTimeInterval:.005 repeats:YES block:^(NSTimer *timer){DesktopView *view=weak;if(!view){[timer invalidate];return;}
        if(view.heldPress&&(CACurrentMediaTime()>=[view.heldIntent[@"focus_deadline"]doubleValue]||![view focusPending:view.heldWindow intent:view.heldIntent]))[view deliverHeld];}];
    [NSRunLoop.mainRunLoop addTimer:self.heldTimer forMode:NSRunLoopCommonModes];
}
// The held press goes to its window now, then its latest drag, then its release if the button is already up. Nothing held: nothing.
- (void)deliverHeld {
    [self.heldTimer invalidate];self.heldTimer=nil;NSEvent *press=self.heldPress,*drag=self.heldDrag;if(!press)return;
    NSNumber *window=self.heldWindow,*output=self.heldOutput;NSDictionary *intent=self.heldIntent;BOOL released=self.heldReleased,navigate=self.heldNavigate;CGPoint p=self.heldPoint,d=self.heldDragPoint;NSEvent *release=self.heldRelease;
    self.heldPress=self.heldDrag=self.heldRelease=nil;self.heldWindow=self.heldOutput=nil;self.heldIntent=nil;self.heldReleased=self.heldNavigate=NO;
    BOOL child=[intent[@"native_member"]boolValue],ready=child?([self childPressCurrent:intent]&&![self focusPending:window intent:intent])
        :DWCapturedRootFocusCurrent(intent,[self.desktop call:@{@"op":@"snapshot"}][@"focus"],NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier,self.desktop.logicalFocus);
    CGEventRef cg=ready&&press.CGEvent?CGEventCreateCopy(press.CGEvent):NULL;BOOL sent=cg&&intent&&[self forward:cg at:p output:output activate:NO expected:intent];if(cg)CFRelease(cg);
    if(DWInputTrace()){LiveSource *s=self.desktop.sources[window];fprintf(stderr,"debug: press #%s delivered after %.0f ms sent=%d frontmost=%s source=%d valid=%d trusted=%d released=%d status=\"%s\"\n",window.description.UTF8String,(CACurrentMediaTime()-self.heldSince)*1000,(int)sent,NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.UTF8String?:"?",s!=nil,(int)[s.router valid],(int)AXIsProcessTrusted(),(int)released,sent?"":(self.desktop.statusText?:@"").UTF8String);}
    // No initial down means no queued drag/up or completed-click navigation.
    if(!sent){self.clickWindow=nil;return;}
    if(drag){cg=CGEventCreateCopy(drag.CGEvent);[self forward:cg at:d output:output activate:NO];CFRelease(cg);}
    if(released){if(release){cg=CGEventCreateCopy(release.CGEvent);BOOL posted=[self forward:cg at:[self screenPoint:release] output:output activate:NO];CFRelease(cg);if(posted){self.pressedSource=nil;self.pressedTarget=nil;self.pressedTablet=NO;self.pressedTabletDevice=nil;self.pressedPointerGrab=NO;}}[self releasePressed];}
    if(released&&navigate&&!child)[self.desktop clickReleased:window output:output];
}
- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate {
    return [self forward:e at:p output:output activate:activate expected:nil];
}
- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate expected:(NSDictionary *)expected {
    if([self.desktop.pointerGrab ownsEvent:e])return (!expected||sameInputTarget(expected,self.desktop.pointerGrab.target))&&[self.desktop forwardCapturedPointer:e screen:p];
    if([self.desktop.tablet ownsEvent:e])return (!expected||sameInputTarget(expected,[self.desktop.tablet capturedTargetForEvent:e]))&&[self.desktop forwardTabletTail:e];
    BOOL sent=[self forwardCaptured:e at:p output:output activate:activate expected:expected];
    if(!sent&&!expected&&DWNativeTabletEvent(e))sent=[self.desktop forwardTabletTail:e];
    return sent;
}
- (BOOL)forwardCaptured:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate expected:(NSDictionary *)expected {
    BOOL native=self.desktop.native!=nil;
    if(self.desktop.nativeFillHandoff)return NO;
    if(self.desktop.native.ended||self.desktop.sessionInactive||self.desktop.cleaning)return NO;
    if(activate)[self.desktop cancelNavigation];
    if(!e||!output)return NO;
    if(DWNativeTabletEvent(e)){
        if(!self.desktop.tablet)self.desktop.tablet=[DWNativeTabletRouter new];
        [self.desktop.tablet observeEvent:e];
        if(DWNativeTabletProximityEvent(e)&&!CGEventGetIntegerValueField(e,kCGTabletProximityEventEnterProximity))return !expected&&[self.desktop forwardTabletTail:e];
    }
    if(!AXIsProcessTrusted()){self.desktop.statusText=@"Input requires Accessibility access. Enable it in System Settings, then reopen.";return NO;}
    NSDictionary *hit=[self hit:p output:output];if(![hit isKindOfClass:NSDictionary.class]||[hit[@"pick"]boolValue])return NO;
    if(expected&&!sameInputTarget(expected,[self inputIntentForHit:hit output:output]))return NO;
    LiveSource *source=self.desktop.sources[hit[@"window"]];
    if(!DWCapturedInputAvailable(source))return NO;
    // The actual native placement gets ordinary WindowServer input. Only an
    // extra display's visible, successfully captured copy can use this route.
    if(native&&(![self.desktop.nativeViews replica:source.logical output:output]||!source.pixels||source.error||source.detached||!DWInScope(self.desktop.scope,source.router.pid)||![[self.desktop.native rootWindowFor:source.router.wid]isEqual:@(source.router.wid)]))return NO;
    // The window's frame may have changed since the poll last looked (a size request just made, a native drag): the same
    // window at its new frame is still the one to post to, as -releasePressed takes it. Its process and number are checked.
    BOOL routerCurrent=YES;
    if(!native&&source){routerCurrent=[source.router valid];if(!routerCurrent){NSDictionary *current=windowInfo(source.router.wid);
        if([birth(source.router.pid)isEqual:source.router.processBirth]&&[current[(id)kCGWindowOwnerPID]intValue]==source.router.pid&&current[(id)kCGWindowBounds])source.router.bounds=current[(id)kCGWindowBounds];
        routerCurrent=[source.router valid];}}
    if(!source||!routerCurrent)return NO;
    // Unsupported cross-source pointer capture must never retarget a held drag.
    CGEventType type=CGEventGetType(e);
    BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
    BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    if((drag||(up&&self.pressedSource))&&source!=self.pressedSource)return NO;
    NSDictionary *member=asDict(hit[@"native_member"]);
    NSDictionary *validated=member?hit:[self.desktop call:@{@"op":@"input",@"output":output,@"screen":pointJSON(p),@"identity":source.identity}][@"hit"];
    if(![validated isKindOfClass:NSDictionary.class]||(!native&&![source.router valid]))return NO;
    if(activate)[self focusSource:source];
    CGPoint local=jsonPoint(validated[@"local"]);
    CGRect own=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&own))return NO;
    NSDictionary *binding=nil;for(NSDictionary *window in [self.desktop call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical])binding=asDict(window[@"source"]);
    if(!binding[@"generation"]||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"observation_known"]boolValue])return NO;
    if(member&&(![member[@"generation"]isEqual:binding[@"generation"]]||![self.desktop.nativeFamilies contains:source.logical identity:member[@"identity"] generation:binding[@"generation"] bounds:jsonRect(member[@"native_bounds"])]))return NO;
    NSMutableDictionary *target=[@{@"window":source.logical,@"output":output,@"generation":binding[@"generation"],@"identity":source.identity,@"root_identity":source.identity,@"native_bounds":rectJSON(own)}mutableCopy];
    if(native||member){NSDictionary *placement=nil;for(NSDictionary *item in [self.desktop presentationSnapshot][@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:output]){placement=item;break;}CGRect site=jsonRect(placement[@"screen_rect"]);if(site.size.width>0&&site.size.height>0)target[@"motion_scale"]=pointJSON(CGPointMake(own.size.width/site.size.width,own.size.height/site.size.height));}
    if(member){target[@"identity"]=member[@"identity"];target[@"native_bounds"]=member[@"native_bounds"];target[@"native_member"]=@YES;local=jsonPoint(member[@"local"]);}
    if(expected&&!sameInputTarget(expected,target))return NO;
    if(self.pressedTarget&&(drag||up)&&![self.pressedTarget[@"identity"]isEqual:target[@"identity"]])return NO;
    if(!DWCapturedInputAvailable(source))return NO;
    if(expected&&![expected[@"native_member"]boolValue]
        &&!DWCapturedRootFocusCurrent(expected,[self.desktop call:@{@"op":@"snapshot"}][@"focus"],NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier,self.desktop.logicalFocus))return NO;
    BOOL sent;
    if(DWNativeTabletEvent(e)){__weak Desktop *weak=self.desktop;sent=[self.desktop.tablet forwardEvent:e target:target local:local validate:^BOOL(NSDictionary *value){return [weak validateInputTarget:value];} post:^BOOL(CGEventRef packet,NSDictionary *value,CGPoint point){return [weak postInput:packet target:value local:point];}];}
    else if(native||member)sent=[self.desktop validateInputTarget:target]&&[self.desktop postInput:e target:target local:local];
    else sent=[source.router post:e at:local];
    if(sent&&(type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown)){self.pressedSource=source;self.pressedTarget=target.copy;self.pressedTablet=DWNativeTabletEvent(e);self.pressedTabletDevice=self.pressedTablet?@(CGEventGetIntegerValueField(e,DWNativeTabletProximityEvent(e)?kCGTabletProximityEventDeviceID:kCGTabletEventDeviceID)):nil;self.pressedLocal=local;self.pressedButton=CGEventGetIntegerValueField(e,kCGMouseEventButtonNumber);}
    if(sent&&(native||member)&&!DWNativeTabletEvent(e)&&(type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown)){
        if(!self.desktop.pointerGrab)self.desktop.pointerGrab=[DWNativePointerGrab new];self.pressedPointerGrab=[self.desktop.pointerGrab admitEvent:e target:target local:local];
    }
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
// Upstream's resize grab, begun by a press bound to resize-window or resize-window-snapped, or by a left press on the resize border
// (`edges` is then the border's; nil lets the controller take them from where in the window the press fell, upstream's
// edges_from_position). In a normal run the grab is a native readback size transaction (crates/desktop/NATIVE_RESIZE.md): each size
// the drag asks is asked of the real window, and the canvas shows the size the window then has.
// Upstream raises and focuses the window first (raise_and_focus, then start_compositor_resize). A resize that begins carries that
// focus request in its reply. A begin that is turned away, by the resize path before the controller is asked or by the controller
// (a size transaction still settling, a window with no source), changed nothing: the press is left upstream's first half, the window
// raised and focused, and the refusal is shown in the controller's words.
- (void)beginResize:(NSNumber *)window edges:(NSString *)edges snapped:(BOOL)snapped at:(CGPoint)p output:(NSNumber *)output {
    NSMutableDictionary *command=[@{@"op":@"begin_native_resize",@"window":window,@"output":output,@"start_screen":pointJSON(p),@"group":snapped?@YES:@NO}mutableCopy];if(edges)command[@"edges"]=edges;
    NSString *status=self.desktop.statusText;NSDictionary *reply=[self.desktop.resize request:command];
    if(reply){self.resizeTransaction=reply[@"transaction"];self.gesture=4;[self.desktop resizeFocus:reply];
        if(DWInputTrace()){NSDictionary *t=asDict([self.desktop call:@{@"op":@"snapshot"}][@"native_resize"]);fprintf(stderr,"debug: resize grab transaction=%s window=#%s edges=%s group=%d ratio=%d\n",[t[@"transaction"]description].UTF8String,window.description.UTF8String,asString(t[@"edges"]).UTF8String?:"?",[asNumber(t[@"group"])boolValue],asNumber(t[@"ratio"])!=nil);}
        return;}
    NSString *refusal=[self.desktop.statusText isEqual:status]?nil:self.desktop.statusText;self.desktop.statusText=status;
    [self.desktop raiseFocus:window];if(refusal)[self.desktop flashStatus:[@"Window not resized: " stringByAppendingString:refusal]];
}
- (NSDictionary *)resizeBorderForButton:(NSInteger)button flags:(NSEventModifierFlags)flags hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)output {
    // Admission is shared by canvas presses and physical native-window presses.
    // The controller owns the band and pick/widget/pin/fullscreen policy; a native
    // child recipient and a modified window binding keep their existing input.
    if(button!=0||hit[@"native_member"])return nil;
    NSDictionary *border=asDict([self pointerCommand:@{@"op":@"resize_border",@"output":output,@"screen":pointJSON(p)} quiet:YES][@"border"]);
    if(!border||(hit&&![hit[@"window"]isEqual:border[@"window"]]))return nil;
    if((flags&(NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift|NSEventModifierFlagCommand))&&[self.desktop mouseBinding:@"left" source:nil flags:flags window:YES under:asNumber(border[@"window"]) pick:NO])return nil;
    return border;
}
// A title grab cannot be lent to a rebound source or a replacement output.
// Once cancelled, the tap still swallows this physical pair through its release.
- (BOOL)nativeTitlePressCurrent {
    NSDictionary *intent=self.nativeTitlePress;Desktop *d=self.desktop;LiveSource *source=intent?d.sources[intent[@"window"]]:nil;
    if(!intent||!d.native||[d nativeUnavailable]||d.cleaning||d.sessionInactive||!d.configured
        ||![d.views containsObject:self]||![self.outputs containsObject:intent[@"output"]]
        ||![self.dragOutput isEqual:intent[@"output"]]
        ||![[d.nativeViews desiredOwnerForWindow:intent[@"window"]]isEqual:intent[@"output"]]||!source||source.detached
        ||!boundIdentity(source.identity,intent[@"identity"])||!DWInScope(d.scope,source.router.pid)
        ||![birth(source.router.pid)isEqual:source.router.processBirth]
        ||![[d.native rootWindowFor:source.router.wid]isEqual:@(source.router.wid)])return NO;
    NSDictionary *snapshot=[d call:@{@"op":@"snapshot"}],*binding=nil;BOOL output=NO;
    for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:intent[@"window"]]){binding=asDict(window[@"source"]);break;}
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:intent[@"output"]]){output=YES;break;}
    return output&&boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:intent[@"generation"]];
}
// A normal run's press, dispatched as upstream's on_pointer_button does: the binding
// for the held modifiers in the window or canvas context, else the native window
// under the pointer. An unbound press on empty canvas means nothing to upstream either.
- (void)press:(NSEvent *)e button:(NSInteger)button hit:(NSDictionary *)hit at:(CGPoint)p output:(NSNumber *)output {
    if(self.desktop.nativeFillHandoff)return;
    NSArray<NSString *> *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];LiveSource *source=hit?self.desktop.sources[hit[@"window"]]:nil;self.lastScrollPan=0;self.clearsFocus=NO;
    // One lookup says all of it: the binding, or nil for none, for one the window under the pointer claims by its pass_mouse rule, and
    // over a pick target for a button whose modifiers are not held. A pick target claims nothing; a pinned window is never one, and keeps
    // its button claims below [zoom] interact_min (upstream's try_pinned_button, which stands ahead of try_pick_button).
    NSDictionary *binding=button<(NSInteger)triggers.count?[self.desktop mouseBinding:triggers[button] source:nil flags:e.modifierFlags window:hit!=nil under:liveHit(hit) pick:[hit[@"pick"]isEqual:@YES]]:nil;NSString *kind=asString(binding[@"kind"]),*action=asString(binding[@"action"]);
    BOOL move=[kind isEqual:@"move_window"]||[kind isEqual:@"move_snapped_windows"],resize=[kind isEqual:@"resize_window"]||[kind isEqual:@"resize_window_snapped"];
    // Upstream's resize border ([mouse] resize_on_border): a left press in the band across a window's visible edge raises and focuses that
    // window and resizes it by that edge, with the cluster when decoration_resize_snapped says so, unless a binding whose modifiers are
    // held claims the press on that window (on_pointer_button asks modifier_button_binding first). The controller says where the band is.
    // A press it does not take goes on as the canvas press it is to -hit:, where upstream would still count the band as the window.
    NSDictionary *border=[self resizeBorderForButton:button flags:e.modifierFlags hit:hit at:p output:output];
    if(border){
        if(DWInputTrace())fprintf(stderr,"debug: pointer down button=%ld trigger=left binding=none border=%s window=#%s\n",(long)button,asString(border[@"edges"]).UTF8String?:"?",[border[@"window"]description].UTF8String);
        [self beginResize:asNumber(border[@"window"]) edges:asString(border[@"edges"]) snapped:[asNumber(border[@"snapped"])boolValue] at:p output:output];[self.desktop render];return;}
    if(DWInputTrace())fprintf(stderr,"debug: pointer down button=%ld trigger=%s binding=%s window=%s\n",(long)button,button<(NSInteger)triggers.count?triggers[button].UTF8String:"?",kind.UTF8String?:"none",hit?[NSString stringWithFormat:@"#%@",hit[@"window"]].UTF8String:"none");
    // Upstream try_pick_button, ahead of everything but a binding whose modifiers are held, which is the only kind the
    // lookup answers over a pick target: below [zoom] interact_min a window or placeholder is one target, whatever the
    // button, and the press is never the application's.
    if([self.hover pickPress:hit button:button claimed:binding!=nil at:p output:output]){self.gesture=DWPolicyPress;return;}
    // ⌃⌥-click still dismisses a detached placeholder while no binding claims that press.
    if(!binding&&!button&&hit&&!source&&(e.modifierFlags&NSEventModifierFlagControl)&&(e.modifierFlags&NSEventModifierFlagOption)){[self.desktop call:@{@"op":@"forget",@"window":hit[@"window"]}];[self.desktop render];[self.desktop saveScene];return;}
    // pointer.rs try_suspended_button: modified bindings and pick mode won
    // above; the label relaunches, the bar moves, the body only focuses.
    if(!binding&&!button&&[hit[@"placeholder"]boolValue]){
        NSDictionary *snapshot=[self.desktop presentationSnapshot];
        NSString *part=[self.desktop.compositor standInPart:hit[@"window"] output:output screen:p snapshot:snapshot];
        if([part isEqual:@"close"]){self.gesture=DWPolicyPress;
            [self.desktop applyReply:[self.desktop call:@{@"op":@"ipc",@"output":output,@"request":@{@"Close":hit[@"window"]}}]];return;}
        if([part isEqual:@"label"]){self.gesture=DWPolicyPress;
            [self.desktop applyReply:[self.desktop call:@{@"op":@"focus",@"window":hit[@"window"]}]];
            [self.desktop applyReply:[self.desktop call:@{@"op":@"ipc",@"output":output,@"request":@{@"Relaunch":hit[@"window"]}}]];return;}
        if([part isEqual:@"title"])move=YES;
    }
    if(self.nativeTitlePress){
        // This is an internal, already intercepted native chrome press. A
        // refusal stays swallowed; it must not fall through to app forwarding.
        if(binding||button!=0||[hit[@"pick"]boolValue]||[hit[@"widget"]boolValue]||hit[@"native_member"]
            ||![hit[@"window"]isEqual:self.nativeTitlePress[@"window"]]||![self nativeTitlePressCurrent])return;
        move=YES;
    }
    // A widget ignores drags and resizes, as upstream's does: the bound press starts no gesture and goes to the widget as a plain click (upstream's move and resize arms fall through to click-to-focus and forward it).
    if((move||resize)&&[asNumber(hit[@"widget"])boolValue]){[self.desktop flashStatus:@"A widget stays where its rule puts it: drags and resizes are ignored"];move=resize=NO;}
    // Upstream on_pointer_button: raise_and_focus, then the move grab. The controller does both inside begin_drag, a pinned window's included, and its reply
    // carries the focus request an activate reply carries: the coordinator's to perform on the native window, as a click's is and a move gesture's.
    if(move&&hit){NSDictionary *begun=[self.desktop call:@{@"op":@"begin_drag",@"window":hit[@"window"],@"output":output,@"group":[kind isEqual:@"move_snapped_windows"]?@YES:@NO}];if(begun){self.gesture=2;[self.desktop.navigation perform:asDict(begun)];}}
    else if(resize&&hit)[self beginResize:hit[@"window"] edges:nil snapped:[kind isEqual:@"resize_window_snapped"] at:p output:output];
    // Upstream's pan grab remembers that it began on empty canvas: released without a drag, it unfocuses.
    else if([kind isEqual:@"pan_viewport"]){self.gesture=1;self.clearsFocus=!hit;}
    // Upstream's NavigateGrab: the drag, not the press, takes the direction.
    else if([kind isEqual:@"center_nearest"]){self.gesture=DWPolicyPress;[self.hover nearestPress:p output:output focus:[binding[@"focus"]isEqual:@YES]];}
    // Upstream raises and focuses the window under the pointer, stand-ins included, then runs the action on it.
    else if([kind isEqual:@"action"]&&action){if(hit)[self.desktop applyReply:[self.desktop call:@{@"op":@"focus",@"window":hit[@"window"]}]];[self.desktop action:action output:output at:p held:[DWCycleHold modifiersDown]!=0];return;}
    // Unbound, or bound to a gesture with nothing to act on here: click-to-focus, then the press is the native window's,
    // once the window has the focus that was asked for (-holdPress:window:intent:at:output:).
    else if(hit){NSDictionary *intent=[self inputIntentForHit:hit output:output];BOOL child=asDict(hit[@"native_member"])!=nil;self.gesture=3;self.clickWindow=child?nil:hit[@"window"];
        if(child){if(![self focusChildIntent:intent])return;}else {
            NSDictionary *reply=[self.desktop call:@{@"op":@"activate",@"window":hit[@"window"],@"output":output?:NSNull.null,@"cause":@"click"}];
            // Pin before applying the reply: completion/rendering must not lend
            // this physical press a later request for the same logical window.
            if(intent){NSMutableDictionary *held=[intent mutableCopy];held[@"focus_effect"]=asDict(reply[@"effect"])?:NSNull.null;intent=held.copy;}
            [self.desktop applyReply:reply];
        }
        [self.desktop render];if(![hit[@"placeholder"]boolValue])[self holdPress:e window:hit[@"window"] intent:intent at:p output:output];return;}
    [self.desktop render];
}
- (void)mouseDown:(NSEvent *)e {
    if(self.desktop.sessionInactive||[self.desktop nativeUnavailable])return;
    [self.desktop.compositor finishGeometryTransitions];
    if(self.desktop.compositor.hasGeometryTransitions)return;
    if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;}
    // One gesture at a time: another button waits until the first is released.
    NSInteger button=self.desktop.configured?e.buttonNumber:0;if(self.gesture&&button!=self.gestureButton){if([self.desktop.pointerGrab ownsEvent:e.CGEvent])[self.desktop forwardCapturedPointer:e.CGEvent screen:[self screenPoint:e]];return;}
    // A press still held for its window's focus goes first, before this one withdraws that request.
    [self deliverHeld];
    // A press is a fresh interaction, as upstream. It ends an open cycle as letting go of its modifiers does, committing a
    // settled selection as upstream's focus_changed commits it. The pad is one device: in a normal run the press then ends
    // a trackpad gesture in progress, cancelled, so that the coast a pan's end launches stops with the rest. Only then is
    // the focus request still in flight withdrawn and every flight and coast stopped, and a scroll pan still waiting to
    // launch never does, at its delay or at the lift of fingers still down.
    self.clickWindow=nil;[self.desktop.navigation releaseCycle];if(self.desktop.configured)[self.desktop cancelGestures];[self.desktop cancelNavigation];[self.desktop.panLaunch cancel];self.scrollPanTime=0;
    CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(!output)return;
    self.startPoint=self.lastPoint=p;self.dragOutput=self.lastOutput=output;self.gestureButton=button;self.lastDragPan=0;
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
    if([self.desktop nativeUnavailable])return;
    if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;}
    if(self.desktop.configured&&e.buttonNumber!=self.gestureButton)return;
    CGPoint p=[self screenPoint:e];
    if(self.nativeTitlePress){
        if(hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)>5)self.nativeTitleMoved=YES;
        // A title click owns the native pair but is not yet a window move.
        // Even a zero delta can magnetically snap and arm edge pan.
        if(!self.nativeTitleMoved){self.lastPoint=p;return;}
    }
    // A pick-mode press dragged past the click slop is a window move from here on, as upstream's grab starts where it is promoted.
    if(self.gesture==DWPolicyPress&&[self.hover pressDragged:p]){self.gesture=2;self.startPoint=p;}
    // Each drag event says where the pointer is; the controller asks one size at a time of the window and keeps only the latest while one
    // is out. A transaction that takes no more motion has ended by itself (its window will not be resized, closed, or stopped answering):
    // nothing more is sent for this press, which stays swallowed until its button lifts, as upstream's grab outlives a dead client.
    if(self.gesture==4){
        if(self.resizeTransaction){NSString *status=self.desktop.statusText;
            if([self.desktop.resize request:@{@"op":@"native_resize_to",@"transaction":self.resizeTransaction,@"screen":pointJSON(p)}]){
                // Success is consumed synchronously: resize.changed has already
                // described the current scene and arranged its frame flush.
                self.lastPoint=p;return;
            }
            self.resizeTransaction=nil;self.desktop.statusText=status;
        }
    }
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
    else if(self.gesture==3&&self.heldPress){self.heldDrag=e;self.heldDragPoint=p;}
    else if(self.gesture==3){CGEventRef cg=CGEventCreateCopy(e.CGEvent);[self forward:cg at:p output:self.dragOutput activate:NO];CFRelease(cg);}
    self.lastPoint=p;[self.desktop render];
}
- (void)releasePressed {
    if(self.pressedSource){
        if(self.pressedPointerGrab){__weak Desktop *weak=self.desktop;if(sameInputTarget(self.pressedTarget,self.desktop.pointerGrab.target))[self.desktop.pointerGrab cancelWithValidate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef event,NSDictionary *target,CGPoint local){return [weak postInput:event target:target local:local];}];[self.desktop.relativeMotion reset];self.pressedSource=nil;self.pressedTarget=nil;self.pressedPointerGrab=NO;return;}
        if(self.pressedTablet){NSDictionary *pressed=self.pressedTarget;__weak Desktop *weak=self.desktop;[self.desktop.tablet cancelTargetsMatching:^BOOL(NSDictionary *target){return [target[@"window"]isEqual:pressed[@"window"]]&&[target[@"output"]isEqual:pressed[@"output"]]&&[target[@"generation"]isEqual:pressed[@"generation"]]&&[target[@"identity"]isEqual:pressed[@"identity"]];} validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef event,NSDictionary *target,CGPoint local){return [weak postInput:event target:target local:local];}];self.pressedSource=nil;self.pressedTarget=nil;self.pressedTablet=NO;self.pressedTabletDevice=nil;self.pressedPointerGrab=NO;return;}
        Router *router=self.pressedSource.router;
        // A native title drag can move the real source before the polling tick.
        // Refresh only the already-pressed identity before releasing its button.
        NSDictionary *current=windowInfo(router.wid);
        if(!self.desktop.native&&[birth(router.pid)isEqual:router.processBirth]&&[current[(id)kCGWindowOwnerPID]intValue]==router.pid&&current[(id)kCGWindowBounds])router.bounds=current[(id)kCGWindowBounds];
        // The button that went down in the source is the one that comes up.
        CGMouseButton button=(CGMouseButton)self.pressedButton;CGEventType type=button==kCGMouseButtonLeft?kCGEventLeftMouseUp:button==kCGMouseButtonRight?kCGEventRightMouseUp:kCGEventOtherMouseUp;
        sig_atomic_t wasStopped=stopped;stopped=0;CGEventRef up=CGEventCreateMouseEvent(router.eventSource,type,CGPointZero,button);
        if(self.desktop.native||[self.pressedTarget[@"native_member"]boolValue]){if(self.pressedTarget&&[self.desktop validateInputTarget:self.pressedTarget])[self.desktop postInput:up target:self.pressedTarget local:self.pressedLocal];}
        else [router post:up at:self.pressedLocal];
        CFRelease(up);if(wasStopped)stopped=wasStopped;self.pressedSource=nil;self.pressedTarget=nil;self.pressedTablet=NO;self.pressedTabletDevice=nil;self.pressedPointerGrab=NO;}
}
- (void)mouseUp:(NSEvent *)e { if(self.desktop.probe&&!self.desktop.probeDrivingGesture){self.desktop.probeHumanInput=YES;return;} if(self.desktop.configured&&e.buttonNumber!=self.gestureButton)return;
    self.nativeTitleReleased=self.nativeTitlePress&&e.type==NSEventTypeLeftMouseUp;
    if(self.heldPress)self.heldRelease=e;
    else if(self.pressedSource){CGEventRef packet=CGEventCreateCopy(e.CGEvent);BOOL posted=[self forward:packet at:[self screenPoint:e] output:self.dragOutput activate:NO];CFRelease(packet);if(posted){self.pressedSource=nil;self.pressedTarget=nil;self.pressedTablet=NO;self.pressedTabletDevice=nil;self.pressedPointerGrab=NO;}}
    [self released:[self screenPoint:e] at:e.timestamp]; }
- (void)tabletPoint:(NSEvent *)event { if(self.desktop.sessionInactive||self.desktop.cleaning)return;CGEventRef packet=event.CGEvent?CGEventCreateCopy(event.CGEvent):NULL;if(packet){CGPoint at=[self screenPoint:event];[self forward:packet at:at output:[self outputAt:at] activate:NO];CFRelease(packet);} }
- (void)tabletProximity:(NSEvent *)event { [self tabletPoint:event]; }
// The end of a press, whatever it had become: at the global point and the event time of its release, or of the moment a release that never
// arrived was noticed (-[Desktop endLostInput]).
- (void)released:(CGPoint)p at:(NSTimeInterval)time { self.liftSeen=0;self.takenOverAt=0;
    NSDictionary *titleClick=self.nativeTitleReleased&&!self.nativeTitleMoved&&self.gesture==2&&self.gestureButton==0
        &&hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)<=5&&[[self outputAt:p]isEqual:self.dragOutput]
        &&[self nativeTitlePressCurrent]?self.nativeTitlePress:nil;
    self.nativeTitleReleased=NO;
    // Native title movement never reaches AppKit. After crossing click slop,
    // apply the final up through the same pointer-to-world mapping. An up may
    // be the first packet beyond slop; a stationary click must never snap.
    if(self.nativeTitlePress&&self.gesture==2&&(self.nativeTitleMoved||hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)>5)&&[self nativeTitlePressCurrent])
        [self.desktop call:@{@"op":@"gesture_to",@"screen_delta":pointJSON(CGPointMake(p.x-self.startPoint.x,p.y-self.startPoint.y)),@"pointer":pointJSON(p)}];
    self.nativeTitlePress=nil;
    // The release of a resize grab: the last size asked is let through, the window is read once more, and the canvas has the size it has.
    // A transaction that ended by itself meanwhile has nothing to release, and says so to nobody.
    if(self.gesture==4&&self.resizeTransaction){NSString *status=self.desktop.statusText;
        // The release may be farther than the last drag event. Keep its final
        // pointer position before draining the request, through the same grab.
        [self.desktop.resize request:@{@"op":@"native_resize_to",@"transaction":self.resizeTransaction,@"screen":pointJSON(p)}];
        if(![self.desktop.resize request:@{@"op":@"end_native_resize",@"transaction":self.resizeTransaction}])self.desktop.statusText=status;}
    self.resizeTransaction=nil;if(self.heldPress)self.heldReleased=YES;else [self releasePressed];
    // Upstream resolve_click_navigate follows delivery. A click still waiting for
    // native focus cannot move the camera before its original recipient is checked.
    NSNumber *clicked=self.clickWindow;self.clickWindow=nil;
    if(self.gesture==3&&clicked&&hypot(p.x-self.startPoint.x,p.y-self.startPoint.y)<=5&&[[self outputAt:p]isEqual:self.dragOutput]){if(self.heldPress)self.heldNavigate=YES;else [self.desktop clickReleased:clicked output:self.dragOutput];}
    // A policy press let go: a pick, or a center-nearest press that never left its dead zone.
    if(self.gesture==DWPolicyPress)[self.hover pressReleased:p];
    // A pick-mode press that became a move ends here like any other window drag.
    if(self.gesture==2)[self.desktop call:@{@"op":@"end_gesture"}];
    if(titleClick)[self.desktop deferNativeTitleClick:titleClick];
    // A normal run's drag pan coasts from its release, as upstream's pan grab launches momentum.
    // A drag that rested first does not: upstream's 50 ms delay has by then launched it into
    // the held grab, where nothing coasts, and the release finds no velocity left. The
    // second launch here is that one.
    if(self.gesture==1&&self.desktop.configured&&self.lastDragPan){[self.desktop panEnd:self.dragOutput];if(time-self.lastDragPan>=.05)[self.desktop panEnd:self.dragOutput];}
    if(self.gesture==1&&self.clearsFocus)[self.desktop clearFocus];self.clearsFocus=NO;self.gesture=0;
    for(DesktopView *view in self.desktop.views)[view refreshCursor];[self.desktop saveScene]; }
- (void)zoom:(double)factor at:(CGPoint)p output:(NSNumber *)output {
    for(NSDictionary *o in [self.desktop call:@{@"op":@"snapshot"}][@"outputs"])if([o[@"id"] isEqual:output]){[self.desktop call:@{@"op":@"zoom",@"output":output,@"zoom":@(MAX(.001,MIN(1,[o[@"zoom"] doubleValue]*factor))),@"anchor":pointJSON(p)}];break;}
    [self.desktop render];if(self.desktop.configured)self.desktop.sceneDirty=YES;else [self.desktop saveScene];
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
    // A held window move or resize owns the pointer; drop its zoom input quietly.
    if(!isfinite(delta)||!delta||self.gesture==2||self.gesture==4)return;
    NSDictionary *reply=[self.desktop call:@{@"op":@"zoom_by",@"output":output,@"anchor":pointJSON(p),@"delta":@(delta),@"source":@"wheel"}];BOOL frames=[reply[@"needs_frames"]boolValue];
    // A zoom the limit swallows is no input for a focus request in flight either.
    if(asDict(reply[@"navigation"]))[self.desktop.navigation interrupt];
    [self.desktop render];if(frames)[self.desktop ensureFrames];self.desktop.sceneDirty=YES;
}
// A normal run's scroll, dispatched as upstream's on_pointer_axis does: a bound scroll
// pans or zooms the canvas and never reaches a window, an unbound one goes to the
// native window under it. A pan or zoom ends its output's flight in the controller, which
// keeps the pan's velocity for the coast; the shell only withdraws a native focus request
// still in flight, as for any unrelated input. An open cycle whose selection has settled
// stays open until its modifiers are let go, as upstream's does.
- (void)scroll:(NSEvent *)e {
    BOOL coast=e.momentumPhase!=NSEventPhaseNone,lifted=(e.phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0;
    // Upstream: an axis event on top of a held modifier chord makes it a binding prefix, not a tap. libinput has no momentum of its own, so macOS's is none.
    if(!coast)[self.desktop.tapKeys taint];
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
    BOOL panning=self.lastScrollPan&&CACurrentMediaTime()-self.lastScrollPan<.15;NSDictionary *here=precise&&panning?nil:asDict([self hit:p output:output]);
    // Upstream's wheel-notch site (on_pointer_axis), ahead of the continuous lookup and for a wheel only: a finger has no notches. Its
    // context is the pointer's own, without the 150 ms canvas lock below. A notch bound to an action runs it once per notch, ten at most
    // for one event, and the event is consumed: it reaches no window and neither pans nor zooms. Any other answer (no notch binding, one
    // that is no action, one the window under the pointer claims by pass_mouse, which the lookup returns as none) leaves the event to the
    // continuous lookup, as upstream falls through. A wheel line is a notch here, as it is for the zoom: macOS reports whole lines.
    // While Shift is held AppKit hands a wheel's vertical lines over as horizontal ones (axis 1 is 0, axis 2 has them, sign kept), where
    // upstream's wheel stays vertical under any modifier: the notch is read back from axis 2 then, so a shift-qualified notch binding and
    // its claim are asked. A sideways wheel turned under Shift arrives as the same event and counts as a notch too, which upstream's does not.
    if(!precise&&e.CGEvent){
        int64_t lines=CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis1);
        if(!lines&&(e.modifierFlags&NSEventModifierFlagShift))lines=CGEventGetIntegerValueField(e.CGEvent,kCGScrollWheelEventDeltaAxis2);
        if(lines){
            NSDictionary *notch=[self.desktop mouseBinding:lines>0?@"wheel_up":@"wheel_down" source:nil flags:e.modifierFlags window:here!=nil under:liveHit(here) pick:[here[@"pick"]isEqual:@YES]];NSString *run=[asString(notch[@"kind"])isEqual:@"action"]?asString(notch[@"action"]):nil;
            if(run){int64_t notches=MIN(llabs(lines),10);BOOL held=[DWCycleHold modifiersDown]!=0;for(int64_t i=0;i<notches;i++)[self.desktop action:run output:output at:p held:held];return;}
        }
    }
    NSDictionary *under=panning?nil:here;BOOL window=under!=nil,pick=[under[@"pick"]isEqual:@YES];
    NSDictionary *binding=[self.desktop mouseBinding:@"scroll" source:source flags:e.modifierFlags window:window under:liveHit(under) pick:pick];NSString *kind=asString(binding[@"kind"]);
    // Upstream on_pointer_axis below [zoom] interact_min: the controller looks a scroll that finds no binding over a
    // pick target up again as one on empty canvas, so that it pans or zooms through the same paths as any bound
    // scroll, coast and all; with none there either it goes nowhere. It is never the application's: not its
    // end, and not macOS's inertia after it. A pick target claims no scroll either: pass_mouse is off for it.
    if(!binding&&pick)return;
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
        [self.desktop.navigation interrupt];[self pan:CGPointMake(h,v) output:output event:e source:source];if(self.gesture==1&&[output isEqual:self.dragOutput])self.lastDragPan=e.timestamp;else [self.desktop.panLaunch panned:output];[self.desktop render];self.desktop.sceneDirty=YES;
    }
}
- (void)scrollWheel:(NSEvent *)e {
    if([self.desktop nativeUnavailable])return;
    [self.desktop.compositor finishGeometryTransitions];
    if(self.desktop.compositor.hasGeometryTransitions)return;
    if(self.desktop.sessionInactive)return;
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
    if(self.desktop.sessionInactive||[self.desktop nativeUnavailable])return;
    // A normal run's pinch is a gesture binding: the [gestures] table decides what it does.
    if(self.desktop.configured){[self.desktop magnify:e];return;}
    // Fixed gesture of probe, demo and owned-fixture runs.
    [self.desktop cancelNavigation]; if(self.desktop.probe){self.desktop.probeHumanInput=YES;return;} CGPoint p=[self screenPoint:e];NSNumber *output=[self outputAt:p];if(output){self.lastOutput=output;[self zoom:1+e.magnification at:p output:output];}
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
// and nothing depends on it. A press on the canvas is its view's to handle.
// Key downs cancel only the bounded background-arrival correction; binding
// releases never cancel the normal native focus request they began.
static CGEventRef navigationInput(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;Desktop *desktop=(__bridge Desktop *)context;
    [desktop cancelNativeTitleClick];
    if(type==kCGEventTapDisabledByTimeout||type==kCGEventTapDisabledByUserInput){[desktop.navigation interrupt];if(desktop.navigationTap)CGEventTapEnable(desktop.navigationTap,true);return event;}
    [desktop.navigation cancelBackgroundArrival];
    if(type==kCGEventKeyDown)return event;
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
- (LiveSource *)nativeSource:(CGWindowID)window at:(CGPoint)point {
    if(!window||!self.native||self.native.ended||self.cleaning)return nil;
    NSNumber *root=[self.native rootWindowFor:window];if(!root)return nil;
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.wid==root.unsignedIntValue){
        if(!DWInScope(self.scope,source.router.pid)||![birth(source.router.pid)isEqual:source.router.processBirth])return nil;
        NSDictionary *info=windowInfo(window);CGRect bounds=CGRectZero;
        if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![info[(id)kCGWindowIsOnscreen]boolValue]
            ||[info[(id)kCGWindowAlpha]doubleValue]<=0||!info[(id)kCGWindowBounds]
            ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)
            ||!CGRectContainsPoint(bounds,point))return nil;
        if(window!=source.router.wid){NSMutableDictionary *member=[source.identity mutableCopy];member[@"wid"]=@(window);[member removeObjectForKey:@"owner"];if(!DWNativeWindowBelongsToRoot(member,source.identity))return nil;}
        return source;
    }
    return nil;
}
- (BOOL)globalGesturesEnabled {
    // Called for every tap packet, including pointer motion: no controller,
    // capture, WindowServer observation or AppKit window lookup here.
    return self.configured&&!self.windowed&&!self.cleaning&&!self.sessionInactive&&self.panels.count>0&&(!self.native||!self.native.ended);
}
- (void)configureGlobalTrackpad {
    if(![self globalGesturesEnabled]||self.globalTrackpad)return;
    __weak Desktop *weak=self;
    DWGlobalTrackpadInput *input=[[DWGlobalTrackpadInput alloc]initWithEnabled:^BOOL{return [weak globalGesturesEnabled];}
        admitTouches:^BOOL(DWTrackpadTouchFrame *frame){return [weak admitGlobalTouches:frame];}
        touches:^(DWTrackpadTouchFrame *frame){[weak globalTouches:frame];}
        magnify:^BOOL(NSEvent *event){return [weak globalMagnify:event];}
        ignoreEvent:^BOOL(CGEventRef event){int64_t tag=CGEventGetIntegerValueField(event,kCGEventSourceUserData);return tag&&[weak.postingTags containsObject:@(tag)];}
        cancelled:^{[weak cancelGestures];}];
    // While the touch source delivers, the guard decides Dock control for the bound finger counts only, and per stream: this tap asks it too, so that a Dock-control
    // packet the guard's own tap did not see (or was not installed to see) is still decided, and for every format. Without a source it applies its own rule.
    input.dockDecision=^DWDockControlVerdict(CGEventRef event){Desktop *d=weak;return d.dockGuard?[d.dockGuard decide:event via:"global-tap" at:CACurrentMediaTime()]:DWDockControlUndecided;};
    if([input start]){self.globalTrackpad=input;self.globalTrackpadNoted=NO;return;}
    if(!self.globalTrackpadNoted){self.globalTrackpadNoted=YES;[self say:@"Global trackpad takeover needs existing Accessibility/input access. macOS system gestures remain active until the session tap can start."];}
}
- (void)nativeMouseOwnershipChanged:(CGEventRef)event buttons:(NSIndexSet *)buttons {
    LiveSource *source=self.nativeMouseOwner;CFTimeInterval now=CACurrentMediaTime();
    if(source.nativeMouseOwnership){
        NSMutableDictionary *held=source.nativeMouseOwnership;
        if(!event){held[@"click_possible"]=@NO;[self.navigation cancelNativeClick];}
        else {
            CGEventType type=CGEventGetType(event);
            BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
            CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);
            if((drag&&hypot(point.x-start.x,point.y-start.y)>5)||buttons.count>1)held[@"click_possible"]=@NO;
            if(drag&&type==kCGEventLeftMouseDragged&&buttons.count==1&&[self takeOverNativeDrag:source event:event])return;
            if(!buttons.count){
                CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*binding=nil,*view=nil;
                for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical])binding=asDict(row[@"source"]);
                for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:held[@"output"]])view=row;
                BOOL click=type==kCGEventLeftMouseUp&&[held[@"click_possible"]boolValue]&&!held[@"topology_changed"]
                    &&[held[@"session"]unsignedLongLongValue]==self.nativeSessionEpoch&&hypot(point.x-start.x,point.y-start.y)<=5
                    &&boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
                    &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
                    &&CGRectContainsPoint(jsonRect(view[@"screen_bounds"]),point)&&[[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:held[@"output"]];
                [self.navigation endNativeClick:held[@"click_binding"] completed:click];
            }
        }
        if(buttons.count){held[@"buttons"]=buttons;[held removeObjectForKey:@"released"];held[@"last_packet"]=@(now);}
        else {
            if(event)held[@"released"]=@(now);else [held removeObjectForKey:@"released"];
            held[@"cancelled"]=@(event==NULL);self.nativeMouseOwner=nil;
        }
        return;
    }
    // Any fresh native recipient supersedes an earlier completed click, even
    // when this press belongs to the Dock or another unmanaged window.
    [self.navigation cancelNativeClick];
    [self cancelNativeTitleClick];
    if(!event||buttons.count!=1||![buttons containsIndex:0]||CGEventGetType(event)!=kCGEventLeftMouseDown
        ||self.cleaning||self.sessionInactive||!self.native||self.native.ended||self.nativeFillHandoff)return;
    CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer);
    source=[self nativeSource:wid at:CGEventGetLocation(event)];
    if(!source||[[self.resize busyWindow]isEqual:source.logical]||[self grabbed:source]
        ||self.nativeOwnershipTransfer||self.nativeHoverTransfer||[self.nativeViews requiresPlacementAdmissionForWindow:source.logical])return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*view=nil;NSNumber *output=[self.nativeViews desiredOwnerForWindow:source.logical];
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){record=row;break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    NSDictionary *binding=asDict(record[@"source"]);double zoom=[view[@"zoom"]doubleValue];
    if(source.nativeMouseOwnership){
        NSMutableDictionary *held=source.nativeMouseOwnership;held[@"buttons"]=buttons;[held removeObjectForKey:@"released"];self.nativeMouseOwner=source;
        BOOL root=wid==source.router.wid&&boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
            &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
            &&CGRectContainsPoint(jsonRect(view[@"screen_bounds"]),CGEventGetLocation(event));
        held[@"click_start"]=pointJSON(CGEventGetLocation(event));held[@"click_possible"]=@(root);
        if(root)[self.navigation beginNativeClick:held[@"click_binding"] output:output];return;
    }
    CGRect initialNative,initialScreen;NSDictionary *initialRow=windowInfo(source.router.wid);
    if(!DWNativeBounds(source.router.wid,&initialNative)||!initialRow[(id)kCGWindowBounds]
        ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)initialRow[(id)kCGWindowBounds],&initialScreen)
        ||!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"]||!view||!isfinite(zoom)||zoom<=0
        ||![self.native withholdWindow:source.identity])return;
    source.nativeMouseOwnership=[@{@"identity":source.identity.copy,@"generation":binding[@"generation"],@"output":output,@"session":@(self.nativeSessionEpoch),
        @"camera":view[@"camera"],@"zoom":view[@"zoom"],@"screen_bounds":view[@"screen_bounds"],@"buttons":buttons,@"last_packet":@(now),
        @"initial_native":rectJSON(initialNative),@"initial_screen":rectJSON(initialScreen)}mutableCopy];
    NSDictionary *clickBinding=@{@"window":source.logical,@"identity":binding[@"identity"],@"generation":binding[@"generation"]};
    BOOL root=wid==source.router.wid&&CGRectContainsPoint(jsonRect(view[@"screen_bounds"]),CGEventGetLocation(event));
    source.nativeMouseOwnership[@"click_binding"]=clickBinding;source.nativeMouseOwnership[@"click_start"]=pointJSON(CGEventGetLocation(event));source.nativeMouseOwnership[@"click_possible"]=@(root);source.nativeMouseOwnership[@"root"]=@(root);
    if(root)[self.navigation beginNativeClick:clickBinding output:output];
    source.observationToken=++self.observationEpoch;self.nativeMouseOwner=source;
    [self cancelNativeHoverForWindow:source.logical];self.nativeViewSnapshot=nil;
    // Omission preserves the current transform; it does not restore or rebase.
    // An already submitted frame can still drain before the omission ACK.
    [self render];
    if(DWInputTrace())fprintf(stderr,"debug: native mouse owner window=#%s begin buttons=%lu\n",source.logical.description.UTF8String,(unsigned long)buttons.count);
}
// A press that went to a transformed native window and became the application's own window drag. WindowServer moves the native
// frame from where the window is drawn (not from the native frame), keeps or drops the transform as it likes while the button
// is down, and puts the transform back at the release: measured in the guest, the window left the pointer at the first packet
// (it jumped, and at zoom below 1 changed size) and the release adopted a displaced origin; macOS tiling reads the native place.
// The first drag packet that shows the native origin moving with the extent unchanged takes the pair over instead: the application's
// drag is ended with a tagged release, the rest of the physical pair is the canvas's, and the window moves by the pointer from
// the press point exactly as after a recognized title press. Resizes and content drags (the extent or nothing changes) stay native.
- (BOOL)takeOverNativeDrag:(LiveSource *)source event:(CGEventRef)event {
    NSMutableDictionary *held=source.nativeMouseOwnership;
    if(!held||[held[@"taken"]boolValue]||![held[@"root"]boolValue]||!self.nativeInput||self.cleaning||self.sessionInactive||!self.native||self.native.ended||self.nativeFillHandoff
        ||source.detached||!boundIdentity(source.identity,held[@"identity"])||[held[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch)return NO;
    CGPoint point=CGEventGetLocation(event),start=jsonPoint(held[@"click_start"]);
    CGRect first=jsonRect(held[@"initial_native"]),drawn=jsonRect(held[@"initial_screen"]),native;
    if(hypot(point.x-start.x,point.y-start.y)<=4||!DWNativeBounds(source.router.wid,&native)||!DWNativeWindowDragStarted(first,drawn,native,start,point))return NO;
    NSNumber *output=held[@"output"];DesktopView *view=nil;
    for(DesktopView *candidate in self.views)if([[candidate outputAt:start]isEqual:output]){view=candidate;break;}
    if(!view||view.gesture||view.heldPress||view.pressedSource||view.pressedTablet||view.pressedPointerGrab||self.nativeGestureView||self.nativeOwnershipTransfer||self.nativeHoverTransfer
        ||[[self.resize busyWindow]isEqual:source.logical]||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output])return NO;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*pose=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){record=row;break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){pose=row;break;}
    NSDictionary *binding=asDict(record[@"source"]);
    if(!pose||[record[@"mode"]isEqual:@"fullscreen"]||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"generation"]isEqual:held[@"generation"]]
        ||![pose[@"camera"]isEqual:held[@"camera"]]||![pose[@"zoom"]isEqual:held[@"zoom"]]||![pose[@"screen_bounds"]isEqual:held[@"screen_bounds"]])return NO;
    NSDictionary *begun=[self call:@{@"op":@"begin_drag",@"window":source.logical,@"output":output,@"group":@NO}];
    if(!begun)return NO;
    // The drag the application started is WindowServer's own (the window follows the pointer whatever the event taps swallow), and
    // it ends when WindowServer sees the button come up. One release is posted at the HID tap for that, from a private event source so
    // that AppKit's combined button state keeps the physical button down: a release that cleared it made -endLostInput end the
    // taken-over gesture 50 ms later as a release that never arrived (measured in the guest). It carries the source's lifetime tag,
    // which both taps let through.
    CGEventSourceRef quiet=CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef up=quiet?CGEventCreateMouseEvent(quiet,kCGEventLeftMouseUp,point,kCGMouseButtonLeft):NULL;
    if(up){CGEventSetIntegerValueField(up,kCGEventSourceUserData,source.router.tag);CGEventSetIntegerValueField(up,kCGMouseEventClickState,1);CGEventPost(kCGHIDEventTap,up);CFRelease(up);}
    if(quiet)CFRelease(quiet);
    if(!up){[self call:@{@"op":@"end_gesture"}];return NO;}
    held[@"taken"]=@YES;
    [self.nativeInput takeNativeButton:0];
    NSDictionary *intent=@{@"window":source.logical,@"output":output,@"identity":source.identity.copy,@"generation":binding[@"generation"]};
    [self finishNativeMouseOwner:source reason:@"native window drag taken over"];
    // The same initialization as -earlyNativeTitle:event:, for a title press that began at the press point.
    view.clickWindow=nil;[self.navigation releaseCycle];[self cancelGestures];[self cancelNavigation];[self.panLaunch cancel];view.scrollPanTime=0;
    self.nativeGestureView=view;self.nativeGestureButton=0;
    view.startPoint=view.lastPoint=start;view.dragOutput=view.lastOutput=output;view.gestureButton=0;view.lastDragPan=0;view.lastScrollPan=0;view.clearsFocus=NO;
    view.nativeTitlePress=intent;view.nativeTitleMoved=YES;view.nativeTitleReleased=NO;view.takenOverAt=CACurrentMediaTime();
    view.gesture=2;[self.navigation perform:begun];
    if([[self call:@{@"op":@"gesture_to",@"screen_delta":pointJSON(CGPointMake(point.x-start.x,point.y-start.y)),@"pointer":pointJSON(point)}][@"needs_frames"]boolValue])[self ensureFrames];
    view.lastPoint=point;[self render];
    if(DWInputTrace())fprintf(stderr,"debug: native window drag taken over window=#%s native=%g,%g drawn=%g,%g\n",source.logical.description.UTF8String,native.origin.x,native.origin.y,drawn.origin.x,drawn.origin.y);
    return YES;
}
- (void)finishNativeMouseOwner:(LiveSource *)source reason:(NSString *)reason {
    NSDictionary *held=source.nativeMouseOwnership;if(!held)return;
    // A lost up can retire geometry after polling, but is never a completed
    // click. An actual up already classified above is left intact.
    [self.navigation endNativeClick:held[@"click_binding"] completed:NO];
    source.nativeMouseOwnership=nil;source.observationToken=++self.observationEpoch;
    if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;
    [self.native resumeWindow:held[@"identity"]];self.nativeViewSnapshot=nil;
    if(DWInputTrace())fprintf(stderr,"debug: native mouse owner window=#%s end=%s\n",source.logical.description.UTF8String,reason.UTF8String);
    [self render];
}
- (void)updateNativeMouseOwners {
    if(self.cleaning||self.sessionInactive||!self.native||self.native.ended)return;
    CFTimeInterval now=CACurrentMediaTime();
    for(LiveSource *source in self.sources.allValues.copy){
        NSMutableDictionary *held=source.nativeMouseOwnership;if(!held)continue;
        if([held[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch){
            source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.observationEpoch;
            if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;continue;
        }
        __block BOOL physical=NO;[(NSIndexSet *)held[@"buttons"]enumerateIndexesUsingBlock:^(NSUInteger button,BOOL *stop){(void)stop;if(CGEventSourceButtonState(kCGEventSourceStateHIDSystemState,(CGMouseButton)button))physical=YES;}];
        // Cancellation is not a release. Lost ups settle only after the stored
        // physical buttons are up; an additional button keeps the same owner.
        if(physical){[held removeObjectForKey:@"released"];[held removeObjectForKey:@"stable_since"];continue;}
        if(!held[@"released"]){if(now-[held[@"last_packet"]doubleValue]<.05)continue;held[@"released"]=@(now);if(self.nativeMouseOwner==source)self.nativeMouseOwner=nil;}
        if(source.detached||!boundIdentity(source.identity,held[@"identity"])||![birth(source.router.pid)isEqual:source.router.processBirth]){[self finishNativeMouseOwner:source reason:@"identity changed"];continue;}
        if([[self.resize busyWindow]isEqual:source.logical])continue;
        CGRect native,after,screen;NSDictionary *row=windowInfo(source.router.wid);
        if(!row||![row[(id)kCGWindowIsOnscreen]boolValue]){
            source.nativeMouseAdopting=YES;@try{[self track:source info:row];}@finally{source.nativeMouseAdopting=NO;}
            [self finishNativeMouseOwner:source reason:@"native window closed or hidden"];continue;
        }
        if(now-[held[@"released"]doubleValue]>2){[self finishNativeMouseOwner:source reason:@"final geometry did not settle within two seconds"];continue;}
        if(!DWNativeBounds(source.router.wid,&native)||[row[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![row[(id)kCGWindowIsOnscreen]boolValue]
            ||!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&screen)
            ||!DWNativeBounds(source.router.wid,&after)||!CGRectEqualToRect(native,after))continue;
        if(!isfinite(screen.origin.x)||!isfinite(screen.origin.y)||!isfinite(screen.size.width)||!isfinite(screen.size.height)||screen.size.width<=0||screen.size.height<=0)continue;
        if(CGRectEqualToRect(jsonRect(held[@"initial_native"]),native)&&CGRectEqualToRect(jsonRect(held[@"initial_screen"]),screen)){
            [self finishNativeMouseOwner:source reason:@"unchanged native click"];continue;
        }
        if(!held[@"stable_since"]||!CGRectEqualToRect(jsonRect(held[@"native"]),native)||!CGRectEqualToRect(jsonRect(held[@"screen"]),screen)){
            held[@"native"]=rectJSON(native);held[@"screen"]=rectJSON(screen);held[@"stable_since"]=@(now);continue;
        }
        if(now-[held[@"stable_since"]doubleValue]<.15)continue;
        source.observationToken=++self.observationEpoch;source.nativeMouseAdopting=YES;
        @try{[self track:source info:row];}@finally{source.nativeMouseAdopting=NO;}
        if([held[@"topology_changed"]boolValue]){[self finishNativeMouseOwner:source reason:@"display topology changed; native basis refreshed"];continue;}
        NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*view=nil,*placement=nil;
        for(NSDictionary *item in snapshot[@"windows"])if([item[@"window"]isEqual:source.logical]){record=item;break;}
        for(NSDictionary *item in snapshot[@"outputs"])if([item[@"id"]isEqual:held[@"output"]]){view=item;break;}
        for(NSDictionary *item in snapshot[@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:held[@"output"]]){placement=item;break;}
        NSDictionary *binding=asDict(record[@"source"]);double zoom=[view[@"zoom"]doubleValue];
        BOOL current=boundIdentity(source.identity,binding[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
            &&[[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:held[@"output"]]
            &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]]
            &&placement&&CGRectEqualToRect(jsonRect(binding[@"observed_rect"]),native)&&![record[@"mode"]isEqual:@"fullscreen"]&&isfinite(zoom)&&zoom>0;
        if(!current){[self finishNativeMouseOwner:source reason:@"adoption basis changed"];continue;}
        CGRect planned=jsonRect(placement[@"screen_rect"]);BOOL pinned=[placement[@"pinned"]boolValue];
        CGPoint delta=CGPointMake((screen.origin.x-planned.origin.x)/(pinned?1:zoom),(screen.origin.y-planned.origin.y)/(pinned?1:zoom));
        NSString *status=self.statusText;NSDictionary *moved=CGPointEqualToPoint(delta,CGPointZero)?@{@"moved":@YES}:[self call:@{@"op":@"relocate_source",@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"observed_rect":rectJSON(native),@"expected_world_rect":record[@"world_rect"],@"delta":pointJSON(delta)}];self.statusText=status;
        if([moved[@"deferred"]boolValue])continue;
        BOOL extent=fabs(screen.size.width-planned.size.width)<=1&&fabs(screen.size.height-planned.size.height)<=1;
        if([moved[@"moved"]boolValue])self.sceneDirty=YES;
        [self finishNativeMouseOwner:source reason:[moved[@"moved"]boolValue]?(extent?@"adopted displayed origin":@"adopted origin; displayed extent differs"):@"adoption refused"];
    }
}
- (BOOL)admitGlobalTouches:(DWTrackpadTouchFrame *)frame { return [self admitContact:frame.fingers]; }
// Whether a touch of `fingers` fingers is the canvas's, asked once per touch by whichever source sees its third finger first: the session tap's events
// or MultitouchSupport's frames. When both report one touch the first answer stands, so the second does not end the gesture the first began.
- (BOOL)admitContact:(NSUInteger)fingers {
    if(self.multitouch.delivering&&self.globalGestureContact)return YES;
    NSString *why=nil;
    if(![self globalGesturesEnabled])why=@"global gestures are off (canvas closed, session away or no panels)";
    else if(self.nativeFillHandoff)why=@"a native fill hand-off is in progress";
    else if(fingers<3)why=@"fewer than three fingers";
    // A native mouse press already owns its drag session, even when its pointer
    // crosses a canvas panel. Extra fingers cannot begin a new camera contact
    // that steals the original source's physical drag and release.
    else if(NSEvent.pressedMouseButtons||self.globalTrackpad.hasNativeMousePress)why=@"a mouse button is down";
    if(why){if(DWInputTrace()&&fingers>=3)fprintf(stderr,"debug: gestures: touch of %lu fingers refused: %s\n",(unsigned long)fingers,why.UTF8String);return NO;}
    CGPoint at=pointer();BOOL output=NO;
    for(DesktopView *view in self.views){if(view.gesture){if(DWInputTrace())fprintf(stderr,"debug: gestures: touch of %lu fingers refused: a view holds a gesture\n",(unsigned long)fingers);return NO;}if([view outputAt:at])output=YES;}
    if(!output){if(DWInputTrace())fprintf(stderr,"debug: gestures: touch of %lu fingers refused: the pointer (%.0f,%.0f) is over no output\n",(unsigned long)fingers,at.x,at.y);return NO;}
    [self.compositor finishGeometryTransitions];if(self.compositor.hasGeometryTransitions){if(DWInputTrace())fprintf(stderr,"debug: gestures: touch of %lu fingers refused: a geometry transition is running\n",(unsigned long)fingers);return NO;}
    [self cancelGestures];self.globalGestureContact=YES;
    if(DWInputTrace())fprintf(stderr,"debug: gestures: touch of %lu fingers admitted as the canvas's (path %s)\n",(unsigned long)fingers,self.multitouch.delivering?"multitouch":"global-tap");
    return YES;
}
- (void)globalTouches:(DWTrackpadTouchFrame *)frame {
    if(self.multitouch.delivering||!self.trackpad||![self globalGesturesEnabled])return;
    self.touchPath=@"global-tap";
    for(NSDictionary *touch in frame.touches)[self.trackpad touch:touch[@"identity"] x:[touch[@"x"]doubleValue] y:[touch[@"y"]doubleValue] phase:(DWTouchPhase)[touch[@"phase"]integerValue] time:frame.time];
    [self.trackpad frame:frame.time];self.lastTouches=frame.time;[self armTrackpad];
    if(!frame.fingers)self.globalGestureContact=NO;
}
- (BOOL)globalMagnify:(NSEvent *)event {
    if(![self globalGesturesEnabled])return NO;
    BOOL beginning=!self.magnifying;
    if(beginning){
        if(NSEvent.pressedMouseButtons||self.globalTrackpad.hasNativeMousePress)return NO;
        CGPoint at=pointer();BOOL output=NO;
        for(DesktopView *view in self.views){if(view.gesture)return NO;if([view outputAt:at])output=YES;}
        if(!output)return NO;
        self.nativePinchAccepted=NO;
    }
    self.globalGestureDelivery=YES;
    @try {[self magnify:event];} @finally {self.globalGestureDelivery=NO;}
    if(beginning&&!self.nativePinchAccepted){[self cancelGestures];return NO;}
    return YES;
}
// Desktop mode asks MultitouchSupport for every contact of the pad, wherever the pointer is, and holds the system's Dock-control gestures back for the finger
// counts a [gestures] binding takes. Asked again each time the native input is configured, about every second: a start that failed is tried again every ten
// seconds, and the tap, which needs Accessibility the run may not have yet, each time. INFINIFY_NO_MULTITOUCH=1 leaves the views' own touches in charge.
- (void)configureMultitouch {
    if(![self globalGesturesEnabled]||(getenv("INFINIFY_NO_MULTITOUCH")&&atoi(getenv("INFINIFY_NO_MULTITOUCH"))==1))return;
    if(!self.multitouch){
        if(CACurrentMediaTime()<self.multitouchRetry)return;
        self.multitouchRetry=CACurrentMediaTime()+10;
        __weak Desktop *weak=self;DWDockGuard *guard=[DWDockGuard new];
        DWMultitouchSource *source=[[DWMultitouchSource alloc]initWithGuard:guard frames:^(DWMultitouchFrame *frame){[weak multitouchFrame:frame];}];
        // Whichever path fed the recogniser until now is not the one that does from here (or the reverse): what it was holding is let go.
        source.deliveringChanged=^(BOOL delivering){(void)delivering;[weak cancelGestures];};
        if(![source start])return;
        self.dockGuard=guard;self.multitouch=source;self.dockTap=[[DWDockTap alloc]initWithGuard:guard];
        self.touchFeed=[[DWMultitouchFeed alloc]initWithRecogniser:^DWTrackpadGestures *{return weak.trackpad;} admit:^BOOL(NSUInteger fingers){return [weak admitContact:fingers];}];
        [self refreshGestureFingers];
    }
    // A source that lost its devices (a wake that found none) is started again, as a first start is retried.
    else if(!self.multitouch.running&&CACurrentMediaTime()>=self.multitouchRetry){self.multitouchRetry=CACurrentMediaTime()+10;[self.multitouch start];}
    if(self.multitouch.running&&!self.dockTap.running)[self.dockTap start];
}
// One frame of the pad from MultitouchSupport, in order, on the main thread: the recogniser's calls once the touch is admitted. A frame that comes while the
// canvas is closed or the session is away is nobody's, and ends what a touch had begun.
- (void)multitouchFrame:(DWMultitouchFrame *)frame {
    BOOL empty=!frame.contacts.count;
    if(!self.touchFeed||!self.trackpad||self.cleaning||self.sessionInactive||![self globalGesturesEnabled]){
        [self.touchFeed cancel:frame.time];if(empty)self.globalGestureContact=NO;else [self.dockGuard refuseContact:frame.contact];return;
    }
    self.touchPath=@"multitouch";
    BOOL fed=[self.touchFeed consume:frame];
    // The system keeps a touch the canvas declined; the guard learns it at once.
    if(self.touchFeed.refused)[self.dockGuard refuseContact:frame.contact];
    if(fed){self.lastTouches=frame.time;[self armTrackpad];}
    if(empty)self.globalGestureContact=NO;
}
// The finger counts a [gestures] binding takes, for the Dock guard: after every config load, and when set-trackpad switches gestures off or on.
- (void)refreshGestureFingers {
    if(!self.dockGuard)return;
    NSDictionary *reply=[self call:@{@"op":@"gesture_fingers"}];uint32_t mask=0;
    for(id count in asArray(reply[@"fingers"])){NSUInteger n=[asNumber(count)unsignedIntegerValue];if(n>0&&n<32)mask|=1u<<n;}
    [self.dockGuard setBound:mask];
}
// The recogniser's gesture in progress, for the Dock guard: it holds the system's gestures back for its finger count until it ends.
- (void)noteDockGesture:(NSDictionary *)event {
    NSString *op=event[@"op"];
    // INFINIFY_DEBUG: every gesture the recogniser begins or ends, with the source that fed it and what the guard held at that moment.
    if(DWInputTrace()&&([op isEqual:@"gesture_begin"]||[op isEqual:@"gesture_end"])){
        DWDockGuardState g=[self.dockGuard state];
        fprintf(stderr,"debug: gestures: %s%s%s fingers=%s path=%s%s guard{live=%d fingers=%u gesture=%u bound=0x%x refused=%d}\n",op.UTF8String,
            [op isEqual:@"gesture_begin"]?" kind=":"",[op isEqual:@"gesture_begin"]?[asString(event[@"kind"])UTF8String]?:"?":"",
            [op isEqual:@"gesture_begin"]?[[asNumber(event[@"fingers"])stringValue]UTF8String]?:"?":"-",self.touchPath.UTF8String?:"?",
            [op isEqual:@"gesture_end"]?([event[@"cancelled"]boolValue]?" cancelled=1":" cancelled=0"):"",
            g.live,g.fingers,g.gesture,g.bound,g.refused);
    }
    if([op isEqual:@"gesture_begin"])[self.dockGuard gesture:[asNumber(event[@"fingers"])unsignedIntegerValue] at:CACurrentMediaTime()];
    else if([op isEqual:@"gesture_end"])[self.dockGuard gesture:0 at:CACurrentMediaTime()];
}
- (BOOL)captureBackingEnabled {
    const char *flag=getenv("INFINIFY_DEBUG_CAPTURE_BACKING"),*guard=getenv("INFINIFY_DEBUG_CAPTURE_EDGE_GUARD"),*debug=getenv("INFINIFY_DEBUG");
    return self.nativeDesktopMode&&flag&&!strcmp(flag,"1")&&guard&&!strcmp(guard,"1")&&debug&&!strcmp(debug,"1");
}
- (NSArray<NSDictionary *> *)captureBackingMembers:(LiveSource *)source {
    NSDictionary *family=source.nativeFamily;NSArray *members=asArray(family[@"members"]);
    if(members.count<1||members.count>2)return nil;
    CGRect rootBounds=jsonRect(family[@"native_bounds"]);NSDictionary *root=nil,*control=nil;
    NSDictionary *capture=self.nativeFamilies.descriptions[source.logical];
    if(members.count==2&&(![capture[@"capture_controls"]isEqual:@YES]
        ||!boundIdentity(capture[@"identity"],family[@"identity"])
        ||![capture[@"generation"]isEqual:family[@"generation"]]
        ||!CGRectEqualToRect(jsonRect(capture[@"native_bounds"]),rootBounds)
        ||asArray(capture[@"members"]).count!=members.count))return nil;
    for(NSDictionary *member in members){
        if(boundIdentity(member[@"identity"],source.identity)){
            if(root||[member[@"parent"]unsignedIntValue]||!CGRectEqualToRect(jsonRect(member[@"native_bounds"]),rootBounds))return nil;
            root=member;continue;
        }
        if(control||[member[@"parent"]unsignedIntValue]!=source.router.wid)return nil;
        NSDictionary *matched=nil;
        for(NSDictionary *observed in asArray(capture[@"members"]))if(boundIdentity(observed[@"identity"],member[@"identity"])){
            if(matched)return nil;matched=observed;
        }
        CGRect bounds=jsonRect(member[@"native_bounds"]);
        if(![matched[@"capture_control"]isEqual:@YES]||![matched[@"parent"]isEqual:member[@"parent"]]
            ||!CGRectEqualToRect(jsonRect(matched[@"native_bounds"]),bounds)||!CGRectContainsRect(rootBounds,bounds))return nil;
        NSMutableDictionary *marked=[member mutableCopy];marked[@"capture_control"]=@YES;control=marked.copy;
    }
    // The capture worker classifies the OS sharing control. It remains part of
    // the native family and restoration journal, but is never captured again as
    // application content. All other children still require a different policy.
    return root?(control?@[root,control]:@[root]):nil;
}
- (NSDictionary<NSNumber *,NSDictionary *> *)captureBackingDescriptors {
    NSMutableDictionary *descriptors=[NSMutableDictionary dictionary];
    for(NSNumber *window in self.captureBackings)descriptors[window]=self.captureBackings[window].descriptor;
    return descriptors.copy;
}
- (void)retireCaptureBackingForWindow:(NSNumber *)window {
    DWCaptureBackingState *state=self.captureBackings[window];NSDictionary *backing=state.descriptor;if(!backing)return;
    if(state.seed)atomic_store(&state.seed->completed,YES);state.seed=nil;
    // Release owned input against the previous mapping before withdrawing it.
    // The gate remains installed until this root has a current safe successor.
    [self cancelCapturedInputForWindow:window];
    LiveSource *source=self.sources[window];[source.captureMailbox requireFreshImage];
    source.captureBackingPresented=NO;if(source)[self.compositor contentChanged:window];
    if(!self.captureBackingsRetiring)self.captureBackingsRetiring=[NSMutableDictionary dictionary];
    self.captureBackingsRetiring[window]=backing;[self.captureBackings removeObjectForKey:window];self.nativeViewSnapshot=nil;
    fprintf(stderr,"debug: capture backing revoked window=%s epoch=%s\n",window.description.UTF8String,[backing[@"guard_epoch"]description].UTF8String);
}
- (void)revokeCaptureBackingForWindow:(NSNumber *)window {
    [self retireCaptureBackingForWindow:window];[self.native setGuardedParkings:[self captureBackingDescriptors]];
}
- (void)revokeCaptureBacking {
    for(NSNumber *window in self.captureBackings.allKeys)[self retireCaptureBackingForWindow:window];
    [self.native setGuardedParkings:@{}];
}
- (BOOL)captureBackingStillAtEdge:(NSDictionary *)backing {
    NSDictionary *identity=backing[@"identity"];
    BOOL parked=[self.native isParkingAcknowledgedForWindow:backing[@"window"] identity:identity generation:backing[@"generation"]];
    NSNumber *owner=[self.nativeViews desiredOwnerForWindow:backing[@"window"]];
    DWNativeAppliedPlacement *placement=owner?[self.native acknowledgedPlacementForWindow:backing[@"window"] identity:identity generation:backing[@"generation"] output:owner]:nil;
    BOOL placed=placement&&[self.native isAcknowledgedPlacementCurrent:placement];
    NSArray *members=asArray(backing[@"members"]);if(!members.count)return YES;
    for(NSDictionary *member in members){
    identity=member[@"identity"];
    CFArrayRef queried=CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,[identity[@"wid"]unsignedIntValue]);
    if(!queried)return YES;NSArray *rows=CFBridgingRelease(queried);if(!rows.count)continue;
    NSDictionary *row=asDict(rows.firstObject);NSNumber *pid=asNumber(row[(id)kCGWindowOwnerPID]);if(!pid)return YES;
    if(pid.intValue!=[identity[@"pid"]intValue])continue;
    NSArray *currentBirth=birth(pid.intValue);if(!currentBirth)return YES;
    if(![currentBirth isEqual:@[identity[@"birth_sec"],identity[@"birth_usec"]]])continue;
    CGRect screen=CGRectNull;
    // Unknown geometry retains coverage. A changed frame can still expose an
    // edge; require a disjoint rectangle or an admitted ordinary native owner.
    if(!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&screen)
        ||!isfinite(screen.origin.x)||!isfinite(screen.origin.y)||!isfinite(screen.size.width)||!isfinite(screen.size.height))return YES;
    // A pre-transition screen read can race an older queued guarded frame.
    // Only a current successor ACK proves that writer ordering has passed it.
    if((parked||placed)&&CGRectIsEmpty(CGRectIntersection(screen,jsonRect(backing[@"guard_rect"]))))continue;
    BOOL ordinary=NO;
    if(placed)for(NSDictionary *current in placement.members)if(boundIdentity(current[@"identity"],identity)){
        NSArray *nativeValues=asArray(current[@"native_bounds"]),*matrix=asArray(current[@"requested_transform"]);
        if(nativeValues.count!=4||matrix.count!=6||[matrix[1]doubleValue]||[matrix[2]doubleValue]||[matrix[0]doubleValue]<=0||[matrix[3]doubleValue]<=0)break;
        CGRect native=CGRectMake([nativeValues[0]doubleValue],[nativeValues[1]doubleValue],[nativeValues[2]doubleValue],[nativeValues[3]doubleValue]);
        CGRect expected=CGRectMake(-[matrix[4]doubleValue]/[matrix[0]doubleValue],-[matrix[5]doubleValue]/[matrix[3]doubleValue],native.size.width/[matrix[0]doubleValue],native.size.height/[matrix[3]doubleValue]);
        ordinary=CGRectEqualToRect(expected,screen);break;
    }
    if(!ordinary)return YES;
    }
    return NO;
}
- (void)drainRetiredCaptureEdgeGuards:(BOOL)finished {
    for(NSDictionary *retired in self.retiredCaptureEdgeGuards.copy){
        DWCaptureEdgeGuardPanel *panel=retired[@"panel"];NSArray *backings=retired[@"backings"];
        BOOL replaced=self.captureEdgeGuard.isVisible&&NSContainsRect(self.captureEdgeGuard.frame,panel.frame);
        if(!finished&&!replaced){BOOL held=NO;for(NSDictionary *backing in backings)if([self captureBackingStillAtEdge:backing]){held=YES;break;}if(held)continue;}
        // A wider replacement inherits every covered obligation, including a
        // root still awaiting its ordinary-parking ACK after revocation.
        if(replaced&&!finished)for(NSDictionary *backing in backings)if(![self.captureEdgeGuardLastBackings containsObject:backing])[self.captureEdgeGuardLastBackings addObject:backing];
        [panel orderOut:nil];[panel close];[self.retiredCaptureEdgeGuards removeObject:retired];
        fprintf(stderr,"debug: capture edge guard retired wid=%ld\n",(long)panel.windowNumber);
    }
}
- (void)closeCaptureEdgeGuard:(BOOL)disable {
    if(disable)self.captureEdgeGuardDisabled=YES;
    [self revokeCaptureBacking];
    DWCaptureEdgeGuardPanel *panel=self.captureEdgeGuard;NSArray *backings=self.captureEdgeGuardLastBackings.copy;
    self.captureEdgeGuard=nil;self.captureEdgeGuardScreens=nil;self.captureEdgeGuardLastBackings=nil;
    self.captureEdgeGuardEpoch++;self.nativeViewSnapshot=nil;
    if(panel){
        // Clearing descriptors is asynchronous. Cover every former family
        // until a successor ACK plus observation clears it, or a superset guard
        // inherits all these obligations. Never shrink an existing guard.
        if(backings.count){if(!self.retiredCaptureEdgeGuards)self.retiredCaptureEdgeGuards=[NSMutableArray array];
            [self.retiredCaptureEdgeGuards addObject:@{@"panel":panel,@"backings":backings}];}
        else {[panel orderOut:nil];[panel close];}
        fprintf(stderr,"debug: capture edge guard closed wid=%ld disabled=%d retained=%lu\n",(long)panel.windowNumber,disable,(unsigned long)backings.count);
    }
    [self drainRetiredCaptureEdgeGuards:NO];
}
- (void)configureCaptureEdgeGuard {
    const char *flag=getenv("INFINIFY_DEBUG_CAPTURE_EDGE_GUARD"),*debug=getenv("INFINIFY_DEBUG");
    if(!flag||strcmp(flag,"1")||!debug||strcmp(debug,"1")||!self.nativeDesktopMode||!self.native||self.native.ended
        ||!self.nativeInput||!self.configured||self.cleaning||self.sessionInactive||self.captureEdgeGuardDisabled||self.captureEdgeGuard||!self.panels.count)return;
    CGDirectDisplayID display=CGMainDisplayID();CGRect bounds=CGDisplayBounds(display);NSScreen *main=nil;
    for(NSScreen *screen in NSScreen.screens)if([screen.deviceDescription[@"NSScreenNumber"]unsignedIntValue]==display){main=screen;break;}
    if(!main||!CGDisplayIsActive(display)||CGDisplayIsAsleep(display)||!isfinite(bounds.origin.x)||!isfinite(bounds.origin.y)
        ||!isfinite(bounds.size.width)||!isfinite(bounds.size.height)||bounds.size.width<1||bounds.size.height<1
        ||!isfinite(main.backingScaleFactor)||main.backingScaleFactor<=0||!CGSizeEqualToSize(bounds.size,NSSizeToCGSize(main.frame.size)))return;
    NSDictionary *basis=@{@"display":@(display),@"bounds":NSStringFromRect(NSRectFromCGRect(bounds)),@"frame":NSStringFromRect(main.frame),@"scale":@(main.backingScaleFactor)};
    if(!self.captureEdgeGuardBasis)self.captureEdgeGuardBasis=basis;
    if(![self.captureEdgeGuardBasis isEqual:basis])return;
    // The real-app trial supports the main display alone or one display to
    // its right. A left/overlapping/stacked display needs a different plan.
    if(NSScreen.screens.count>2)return;
    for(NSScreen *screen in NSScreen.screens)if(screen!=main){
        CGDirectDisplayID other=[screen.deviceDescription[@"NSScreenNumber"]unsignedIntValue];CGRect frame=CGDisplayBounds(other);
        if(!other||!CGDisplayIsActive(other)||CGDisplayIsAsleep(other)||!isfinite(frame.origin.x)||!isfinite(frame.origin.y)
            ||!isfinite(frame.size.width)||!isfinite(frame.size.height)||frame.size.width<=0||frame.size.height<=0
            ||CGRectGetMinX(frame)<CGRectGetMaxX(bounds))return;
    }
    NSInteger level=MIN(CGWindowLevelForKey(kCGDockWindowLevelKey),CGWindowLevelForKey(kCGMainMenuWindowLevelKey))-1;
    if(level<=NSNormalWindowLevel)return;
    NSUInteger width=MAX((NSUInteger)1,self.captureEdgeGuardWidth);if(width>=bounds.size.width)return;
    NSRect frame=NSMakeRect(NSMinX(main.frame),NSMinY(main.frame),width,main.frame.size.height);
    DWCaptureEdgeGuardPanel *panel=[[DWCaptureEdgeGuardPanel alloc]initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO;panel.hidesOnDeactivate=NO;panel.canHide=NO;panel.ignoresMouseEvents=NO;panel.acceptsMouseMovedEvents=NO;
    panel.becomesKeyOnlyIfNeeded=YES;panel.hasShadow=NO;panel.opaque=YES;panel.alphaValue=.999;
    panel.backgroundColor=[NSColor colorWithSRGBRed:.045 green:.065 blue:.10 alpha:1];panel.level=level;panel.animationBehavior=NSWindowAnimationBehaviorNone;
    panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorIgnoresCycle;
    panel.contentView=[[DWCaptureEdgeGuardView alloc]initWithFrame:NSMakeRect(0,0,width,frame.size.height)];
    [panel orderFrontRegardless];
    if(!panel.isVisible||!NSEqualRects(panel.frame,frame)){[panel orderOut:nil];[panel close];return;}
    self.captureEdgeGuard=panel;self.captureEdgeGuardScreens=physicalScreens();self.captureEdgeGuardRect=CGRectMake(bounds.origin.x,bounds.origin.y,width,bounds.size.height);
    self.captureEdgeGuardLastBackings=[NSMutableArray array];
    self.captureEdgeGuardEpoch++;self.nativeViewSnapshot=nil;[self drainRetiredCaptureEdgeGuards:NO];
    fprintf(stderr,"debug: capture edge guard shown wid=%ld display=%u screen=%s alpha=%.3f level=%ld\n",(long)panel.windowNumber,display,NSStringFromRect(NSRectFromCGRect(self.captureEdgeGuardRect)).UTF8String,panel.alphaValue,(long)level);
}
- (BOOL)captureEdgeGuardConsumes:(CGEventType)type event:(CGEventRef)event {
    if(!self.captureEdgeGuard&&!self.retiredCaptureEdgeGuards.count)return NO;
    if(CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)==getpid())return NO;
    if(type!=kCGEventLeftMouseDown&&type!=kCGEventRightMouseDown&&type!=kCGEventOtherMouseDown&&type!=kCGEventScrollWheel)return NO;
    if(self.captureEdgeGuard&&![self.captureEdgeGuardScreens isEqual:physicalScreens()])[self closeCaptureEdgeGuard:NO];
    CGPoint point=CGEventGetLocation(event);
    // Positive frontmost-recipient proof leaves Dock/menu input above the
    // guard untouched. Existing DWNativeInput owns every admitted down's tail.
    NSInteger recipient=[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
    if(self.captureEdgeGuard.isVisible&&CGRectContainsPoint(self.captureEdgeGuardRect,point)&&recipient==self.captureEdgeGuard.windowNumber)return YES;
    for(NSDictionary *retired in self.retiredCaptureEdgeGuards){NSPanel *panel=retired[@"panel"];if(panel.isVisible&&recipient==panel.windowNumber)return YES;}
    return NO;
}
- (BOOL)captureBackingReady:(LiveSource *)source {
    return [self captureBackingPlacementCurrent:source]&&source.captureMailbox.currentImageAvailable;
}
- (BOOL)captureBackingPhysicalCurrent:(LiveSource *)source {
    DWCaptureBackingState *state=self.captureBackings[source.logical];NSDictionary *backing=state.descriptor;
    if(!backing||![backing[@"window"]isEqual:source.logical]||!self.captureEdgeGuard.isVisible
        ||self.cleaning||self.sessionInactive||self.native.ended||self.captureEdgeGuardDisabled
        ||[backing[@"guard_epoch"]unsignedLongLongValue]!=self.captureEdgeGuardEpoch
        ||![self.captureEdgeGuardScreens isEqual:physicalScreens()]||source.detached||source.error){
        state.physicalObservation=@{@"reason":@"basis"};return NO;
    }
    if(![source.nativeFamily[@"generation"]isEqual:backing[@"generation"]]
        ||!boundIdentity(source.nativeFamily[@"identity"],backing[@"identity"])
        ||![[self captureBackingMembers:source]isEqual:backing[@"members"]]
        ||!CGRectEqualToRect(jsonRect(source.nativeFamily[@"native_bounds"]),jsonRect(backing[@"native_bounds"]))){
        state.physicalObservation=@{@"reason":@"family"};return NO;
    }
    CGRect main=NSRectToCGRect(NSRectFromString(self.captureEdgeGuardBasis[@"bounds"]?:@"")),rootNative=jsonRect(backing[@"native_bounds"]),rootScreen=jsonRect(backing[@"screen_rect"]);
    for(NSDictionary *member in backing[@"members"]){
    NSDictionary *identity=member[@"identity"];uint32_t wid=[identity[@"wid"]unsignedIntValue],parent=0;
    CGRect native=CGRectNull,screen=CGRectNull,wanted=jsonRect(member[@"native_bounds"]);
    CGRect expected=CGRectMake(rootScreen.origin.x+wanted.origin.x-rootNative.origin.x,rootScreen.origin.y+wanted.origin.y-rootNative.origin.y,wanted.size.width,wanted.size.height);
    NSDictionary *row=windowInfo(wid);
    if([row[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![birth(source.router.pid)isEqual:source.router.processBirth]
        ||!DWNativeWindowParent(identity,&parent)||parent!=[member[@"parent"]unsignedIntValue]){
        state.physicalObservation=@{@"reason":@"family",@"member":@(wid)};return NO;
    }
    if(!DWNativeBounds(wid,&native)||!CGRectEqualToRect(native,wanted)){
        state.physicalObservation=@{@"reason":@"memberNative",@"member":@(wid)};return NO;
    }
    if(!row[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&screen)
        ||!CGRectEqualToRect(screen,expected)){
        state.physicalObservation=@{@"reason":@"memberScreen",@"member":@(wid)};return NO;
    }
    if(!DWNativeWindowOnDisplaySpace(wid,main)){
        state.physicalObservation=@{@"reason":@"memberSpace",@"member":@(wid)};return NO;
    }
    }
    // Each root has an exclusive rightmost one-point lane if the observed
    // native order still matches the plan. A front root/order change gates this
    // source immediately; helper success alone does not prove visible backing.
    CGPoint point=CGPointMake(CGRectGetMaxX(rootScreen)-.5,CGRectGetMidY(rootScreen));NSPoint at=NSMakePoint(point.x,screenTop()-point.y);
    if(!CGRectContainsPoint(self.captureEdgeGuardRect,point)){
        state.physicalObservation=@{@"reason":@"guardHit",@"point":pointJSON(point)};return NO;
    }
    NSInteger top=[NSWindow windowNumberAtPoint:at belowWindowWithWindowNumber:0];
    if(top!=self.captureEdgeGuard.windowNumber){
        state.physicalObservation=@{@"reason":@"guardHit",@"point":pointJSON(point),@"top":@(top),@"guard":@(self.captureEdgeGuard.windowNumber)};return NO;
    }
    // Mouse hit tests include resize/event outsets beyond a window's visible
    // bounds. CGWindow.h guarantees front-to-back order for this below-window
    // option, so use it only as a conservative rectangular visibility witness.
    // The positive mouse hit on our guard above remains the input protection.
    NSInteger guardNumber=self.captureEdgeGuard.windowNumber;uint64_t guardEpoch=self.captureEdgeGuardEpoch;
    CFArrayRef copied=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenBelowWindow|kCGWindowListExcludeDesktopElements,(CGWindowID)guardNumber);
    NSArray *rows=copied?CFBridgingRelease(copied):nil;
    NSString *refusal=nil;NSDictionary *visible=nil;CGRect visibleFrame=CGRectNull;
    if(!rows||!rows.count||rows.count>=4096)refusal=@"unavailable_or_unbounded_list";
    NSMutableSet<NSNumber *> *seen=[NSMutableSet set];
    if(!refusal)for(id value in rows){
        NSDictionary *row=asDict(value),*bounds=asDict(row[(id)kCGWindowBounds]);
        NSNumber *wid=asNumber(row[(id)kCGWindowNumber]),*pid=asNumber(row[(id)kCGWindowOwnerPID]),*alpha=asNumber(row[(id)kCGWindowAlpha]);
        double w=wid.doubleValue,p=pid.doubleValue,a=alpha.doubleValue;CGRect frame=CGRectNull;
        if(!wid||!pid||!alpha||CFGetTypeID((__bridge CFTypeRef)wid)==CFBooleanGetTypeID()
            ||CFGetTypeID((__bridge CFTypeRef)pid)==CFBooleanGetTypeID()||CFGetTypeID((__bridge CFTypeRef)alpha)==CFBooleanGetTypeID()
            ||!isfinite(w)||w<1||w>UINT32_MAX||floor(w)!=w||!isfinite(p)||p<0||p>INT_MAX||floor(p)!=p
            ||!isfinite(a)||a<0||a>1||!bounds||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds,&frame)
            ||!isfinite(frame.origin.x)||!isfinite(frame.origin.y)||!isfinite(frame.size.width)||!isfinite(frame.size.height)
            ||frame.size.width<0||frame.size.height<0||!isfinite(CGRectGetMaxX(frame))||!isfinite(CGRectGetMaxY(frame))){refusal=@"malformed_row";break;}
        if([seen containsObject:wid]){refusal=@"duplicate_window";break;}[seen addObject:wid];
        // Zero-area system rows and alpha-zero rows cannot cover the witness.
        // No other window or same-family child is silently skipped.
        if(!visible&&a>0&&frame.size.width>0&&frame.size.height>0&&CGRectContainsPoint(frame,point)){visible=row;visibleFrame=frame;}
    }
    if(!refusal){
        if(!visible)refusal=@"missing_root";
        else if([visible[(id)kCGWindowNumber]unsignedIntValue]!=source.router.wid||[visible[(id)kCGWindowOwnerPID]intValue]!=source.router.pid)refusal=@"earlier_window";
        else if(!CGRectEqualToRect(visibleFrame,rootScreen))refusal=@"root_screen";
        else if(![birth(source.router.pid)isEqual:source.router.processBirth]||self.captureEdgeGuard.windowNumber!=guardNumber
            ||!self.captureEdgeGuard.isVisible||self.captureEdgeGuardEpoch!=guardEpoch
            ||![self.captureEdgeGuardScreens isEqual:physicalScreens()])refusal=@"source_or_guard_changed";
    }
    NSMutableDictionary *observation=[@{@"reason":refusal?@"visualOcclusion":@"ready",@"point":pointJSON(point),@"top":@(top),@"root":@(source.router.wid)}mutableCopy];
    if(refusal)observation[@"detail"]=refusal;
    if(visible){observation[@"visible_wid"]=visible[(id)kCGWindowNumber];observation[@"visible_pid"]=visible[(id)kCGWindowOwnerPID];observation[@"visible_screen"]=rectJSON(visibleFrame);}
    state.physicalObservation=observation.copy;
    return refusal==nil;
}
- (BOOL)captureBackingPlacementCurrent:(LiveSource *)source {
    if(!source)return NO;
    DWCaptureBackingState *state=self.captureBackings[source.logical];if(!state)return NO;
    BOOL physical=[self captureBackingPhysicalCurrent:source];
    if(physical!=state.witnessed){
        // A hidden/reordered lane cannot revive retained pixels when it comes
        // back. This fence is about independent native observation, not the
        // brief ACK gap caused by another root's complete helper submission.
        state.witnessed=physical;
        if(state.seed)atomic_store(&state.seed->completed,YES);state.seed=nil;
        [source.captureMailbox requireFreshImage];
        if(!physical)[self cancelCapturedInputForWindow:source.logical];
        if(source.captureBackingPresented){source.captureBackingPresented=NO;[self.compositor contentChanged:source.logical];}
    }
    BOOL mailboxMatches=source.captureMailbox==state.mailbox;
    NSNumber *storedSequence=state.receipt?@(state.receipt.sequence):nil;
    NSDictionary *backing=state.descriptor;
    // Helper ACKs arrive after updateCaptureBacking/render. The cached token
    // may name an older complete frame even though this exact unchanged
    // descriptor already has a current ACK. Reacquire it without resetting
    // capture freshness; pending/latest-frame ACKs still refuse admission.
    DWNativeAppliedParking *receipt=physical&&mailboxMatches?[self.native acknowledgedGuardedParkingForWindow:source.logical
        identity:backing[@"identity"] generation:backing[@"generation"] guardEpoch:[backing[@"guard_epoch"]unsignedLongLongValue]]:nil;
    BOOL acknowledged=receipt&&[self.native isAcknowledgedGuardedParkingCurrent:receipt];
    if(physical&&mailboxMatches)state.receipt=receipt;
    state.readinessObservation=@{@"physical":@(physical),@"mailbox_matches":@(mailboxMatches),@"mailbox_present":@(source.captureMailbox!=nil),
        @"stored_sequence":storedSequence?:NSNull.null,@"current_sequence":receipt?@(receipt.sequence):NSNull.null,@"ack_current":@(acknowledged)};
    return physical&&mailboxMatches&&acknowledged;
}
- (void)finishCaptureBackingSeed:(DWCaptureBackingSeed *)request source:(LiveSource *)source {
    if(atomic_load(&request->completed))return;
    DWCaptureBackingState *backingState=self.captureBackings[source.logical];DWCaptureConfiguration current=source.captureConfiguration;
    CGSize pixels=request.pixelSize;DWRootCaptureMailbox *mailbox=request.mailbox;
    BOOL bound=backingState.seed==request&&backingState.descriptor==request.descriptor&&backingState.mailbox==mailbox
        &&source.captureMailbox==mailbox&&source.stream==request.stream&&source.window==request.window&&CACurrentMediaTime()<request.deadline
        &&!current.pending&&current.serial==request.configuration&&current.acknowledgedSerial==request.configuration
        &&CGSizeEqualToSize(source.captureSize,pixels)&&CGSizeEqualToSize(current.acknowledgedPixels,pixels);
    BOOL placement=bound&&[self captureBackingPlacementCurrent:source];
    CVPixelBufferRef image=request->sample&&CMSampleBufferIsValid(request->sample)?CMSampleBufferGetImageBuffer(request->sample):NULL;
    BOOL sample=bound&&!request->failure&&image&&CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA
        &&CVPixelBufferGetWidth(image)==(size_t)pixels.width&&CVPixelBufferGetHeight(image)==(size_t)pixels.height;
    if(sample&&!placement&&backingState.witnessed&&!atomic_load(&request->completed)){
        // Another root can supersede a complete helper frame while this one
        // is returning. Retain this sample, never issue a second capture or
        // accept a missing ACK, and recheck all fences inside its original lease.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self finishCaptureBackingSeed:request source:source];});return;
    }
    if(atomic_exchange(&request->completed,YES))return;
    BOOL published=sample&&placement&&[mailbox installSnapshotSeed:request->sample token:request.token];
    if(request->sample){CFRelease(request->sample);request->sample=NULL;}
    fprintf(stderr,"debug: capture backing bootstrap result window=%s published=%d current=%d error=%s\n",source.logical.stringValue.UTF8String,published,placement,(request->failure?:@"none").UTF8String);
    if(published){source.captureBackingPresented=[self captureBackingReady:source];[self.compositor contentChanged:source.logical];[self startFrames];}
}
- (void)bootstrapCaptureBacking:(LiveSource *)source {
    DWCaptureBackingState *backingState=self.captureBackings[source.logical];
    if(!backingState||backingState.seed||![self captureBackingEnabled]||![self captureBackingPlacementCurrent:source]
        ||source.captureMailbox.currentImageAvailable||source.captureUpdating||!source.stream||!source.window
        ||source.window.windowID!=source.router.wid||source.window.owningApplication.processID!=source.router.pid)return;
    DWCaptureConfiguration state=source.captureConfiguration;CGSize pixels=source.captureSize;
    if(!state.acknowledgedSerial||state.serial!=state.acknowledgedSerial||!CGSizeEqualToSize(state.acknowledgedPixels,pixels)
        ||!isfinite(pixels.width)||!isfinite(pixels.height)||pixels.width<1||pixels.height<1
        ||pixels.width>16384||pixels.height>16384||floor(pixels.width)!=pixels.width||floor(pixels.height)!=pixels.height)return;
    DWRootCaptureMailbox *mailbox=source.captureMailbox;NSDictionary *token=[mailbox reserveSnapshotSeed];if(!token)return;
    DWCaptureBackingSeed *request=[DWCaptureBackingSeed new];backingState.seed=request;
    request.descriptor=backingState.descriptor;request.mailbox=mailbox;request.stream=source.stream;request.window=source.window;
    request.configuration=state.acknowledgedSerial;request.pixelSize=pixels;request.token=token;request.deadline=CACurrentMediaTime()+1;
    SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:source.window];
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)pixels.width;config.height=(size_t)pixels.height;
    config.pixelFormat=kCVPixelFormatType_32BGRA;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;compositedStream(config,source);
    fprintf(stderr,"debug: capture backing bootstrap requested window=%s seed=%llu\n",source.logical.stringValue.UTF8String,(unsigned long long)[token[@"sequence"]unsignedLongLongValue]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(!atomic_exchange(&request->completed,YES)){
            if(request->sample){CFRelease(request->sample);request->sample=NULL;}
            fprintf(stderr,"debug: capture backing bootstrap expired window=%s\n",source.logical.stringValue.UTF8String);
        }
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        if(atomic_load(&request->completed)||CACurrentMediaTime()>=request.deadline)return;
        BOOL permitted=CGPreflightScreenCaptureAccess();
        if(!permitted||atomic_load(&request->completed)||CACurrentMediaTime()>=request.deadline)return;
        [SCScreenshotManager captureSampleBufferWithFilter:filter configuration:config completionHandler:^(CMSampleBufferRef sample,NSError *error){
            if(atomic_load(&request->completed))return;
            DWExportFrame *result=[DWExportFrame new];if(sample)result->sample=(CMSampleBufferRef)CFRetain(sample);result->failure=error.localizedDescription;
            dispatch_async(dispatch_get_main_queue(),^{
                if(atomic_load(&request->completed))return;
                request->sample=result->sample?(CMSampleBufferRef)CFRetain(result->sample):NULL;request->failure=result->failure;
                [self finishCaptureBackingSeed:request source:source];
            });
        }];
    });
}
- (void)updateCaptureBacking:(NSDictionary *)snapshot {
    [self drainRetiredCaptureEdgeGuards:NO];
    if(![self captureBackingEnabled])return;
    if(!self.captureBackings)self.captureBackings=[NSMutableDictionary dictionary];
    if(!self.captureBackingsRetiring)self.captureBackingsRetiring=[NSMutableDictionary dictionary];
    self.captureBackingAdmissions=[NSMutableDictionary dictionary];
    BOOL guard=self.captureEdgeGuard.isVisible&&!self.captureEdgeGuardDisabled&&!self.cleaning&&!self.sessionInactive&&!self.native.ended
        &&[self.captureEdgeGuardScreens isEqual:physicalScreens()];
    CGRect main=NSRectToCGRect(NSRectFromString(self.captureEdgeGuardBasis[@"bounds"]?:@""));
    for(NSNumber *window in self.captureBackingsRetiring.allKeys){NSDictionary *retiring=self.captureBackingsRetiring[window];
        if(![self captureBackingStillAtEdge:retiring]){[self.captureBackingsRetiring removeObjectForKey:window];[self.captureEdgeGuardLastBackings removeObject:retiring];}}
    NSMutableDictionary<NSNumber *,NSDictionary *> *eligible=[NSMutableDictionary dictionary];
    for(NSNumber *window in [self.sources.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        LiveSource *source=self.sources[window];BOOL needsBacking=![self.nativeViews desiredOwnerForWindow:window];
        if(needsBacking&&!source.capturedInputGate){
            [self cancelCapturedInputForWindow:window];[source.captureMailbox requireFreshImage];
            source.captureBackingPresented=NO;[self.compositor contentChanged:window];
            __weak Desktop *weak=self;__weak LiveSource *weakSource=source;
            source.capturedInputGate=^BOOL{Desktop *desktop=weak;LiveSource *current=weakSource;return desktop&&current&&[desktop captureBackingReady:current];};
        }else if(!needsBacking&&source.capturedInputGate){[self cancelCapturedInputForWindow:window];[source.captureMailbox requireFreshImage];source.capturedInputGate=nil;source.captureBackingPresented=NO;[self.compositor contentChanged:window];}
        self.captureBackingAdmissions[window]=@{@"guard":@(guard),@"retiring":@(self.captureBackingsRetiring[window]!=nil),@"stage":@"ineligible"};
        if(!guard||!needsBacking||source.detached||source.error||source.nativeMouseOwnership
            ||![self.nativeViews.capturedWindows containsObject:window]||[[self.resize busyWindow]isEqual:window])continue;
        NSDictionary *binding=nil;for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:window]){binding=asDict(row[@"source"]);break;}
        NSDictionary *family=source.nativeFamily;NSArray *members=[self captureBackingMembers:source];NSDictionary *member=asDict(members.firstObject);
        CGRect own=jsonRect(binding[@"observed_rect"]),native=CGRectNull,after=CGRectNull;
        self.captureBackingAdmissions[window]=@{@"stage":@"family_or_native",@"binding":binding?:NSNull.null,@"family":family?:NSNull.null,
            @"capture_family":self.nativeFamilies.descriptions[window]?:NSNull.null,@"main":rectJSON(main)};
        if(![binding[@"observation_known"]boolValue]||!binding[@"generation"]||!boundIdentity(binding[@"identity"],source.identity)
            ||!boundIdentity(family[@"identity"],source.identity)||![family[@"generation"]isEqual:binding[@"generation"]]
            ||!members.count||!boundIdentity(member[@"identity"],source.identity)||[member[@"parent"]unsignedIntValue]!=0
            ||!CGRectEqualToRect(jsonRect(member[@"native_bounds"]),own)||!CGRectEqualToRect(jsonRect(family[@"native_bounds"]),own)
            ||!isfinite(own.origin.x)||!isfinite(own.origin.y)||!isfinite(own.size.width)||!isfinite(own.size.height)
            ||own.size.width<=1||own.size.height<=1||own.origin.y<CGRectGetMinY(main)||CGRectGetMaxY(own)>CGRectGetMaxY(main)
            ||![birth(source.router.pid)isEqual:source.router.processBirth]||!DWNativeBounds(source.router.wid,&native)||!CGRectEqualToRect(native,own)
            ||!DWNativeWindowOnDisplaySpace(source.router.wid,main)||!DWNativeBounds(source.router.wid,&after)||!CGRectEqualToRect(native,after)
            ||![birth(source.router.pid)isEqual:source.router.processBirth])continue;
        eligible[window]=@{@"window":window,@"identity":source.identity,@"generation":binding[@"generation"],@"native_bounds":rectJSON(own),@"members":members};
    }
    // The existing native order is authoritative. Front roots end at x=1,
    // then x=2, etc.; each back root has a one-point lane beyond all front roots.
    // Never infer order from logical IDs, and never reorder application windows.
    NSMutableArray<NSNumber *> *ranked=[NSMutableArray array];BOOL orderKnown=YES;
    if(eligible.count){
        CFArrayRef copied=CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID);
        NSArray *rows=copied?CFBridgingRelease(copied):nil;orderKnown=rows!=nil;
        NSMutableSet *seen=[NSMutableSet set];
        for(id value in rows){NSDictionary *row=asDict(value);NSNumber *wid=asNumber(row[(id)kCGWindowNumber]),*pid=asNumber(row[(id)kCGWindowOwnerPID]);
            if(!wid||!wid.unsignedIntValue||!pid||pid.intValue<0||[seen containsObject:wid]){orderKnown=NO;break;}[seen addObject:wid];
            for(NSNumber *window in eligible){NSDictionary *identity=eligible[window][@"identity"];
                if(![wid isEqual:identity[@"wid"]])continue;
                if(![pid isEqual:identity[@"pid"]]||[ranked containsObject:window]){orderKnown=NO;break;}
                [ranked addObject:window];
            }
            if(!orderKnown)break;
        }
        if(ranked.count!=eligible.count)orderKnown=NO;
    }
    if(orderKnown&&ranked.count>self.captureEdgeGuardRect.size.width){
        // Create a wider panel before retiring the old cover. Its obligation
        // list is inherited by the superset; roots first return to ordinary
        // parking and acquire a fresh per-root ACK/image for the new epoch.
        self.captureEdgeGuardWidth=MAX(self.captureEdgeGuardWidth,ranked.count);
        [self closeCaptureEdgeGuard:NO];[self configureCaptureEdgeGuard];return;
    }
    NSMutableDictionary<NSNumber *,NSDictionary *> *candidates=[NSMutableDictionary dictionary];
    if(orderKnown)for(NSUInteger index=0;index<ranked.count;index++){
        NSNumber *window=ranked[index];NSDictionary *base=eligible[window];CGRect own=jsonRect(base[@"native_bounds"]);CGFloat lane=index+1;
        if(own.size.width<=lane)continue;
        CGRect screen=CGRectMake(CGRectGetMinX(main)+lane-own.size.width,own.origin.y,own.size.width,own.size.height);
        CGRect visible=CGRectIntersection(screen,main);BOOL confined=CGRectContainsRect(self.captureEdgeGuardRect,visible)&&visible.size.width==lane;
        for(NSScreen *display in NSScreen.screens){CGRect bounds=CGDisplayBounds([display.deviceDescription[@"NSScreenNumber"]unsignedIntValue]);
            if(!CGRectEqualToRect(bounds,main)&&!CGRectIsEmpty(CGRectIntersection(screen,bounds)))confined=NO;}
        CGPoint point=CGPointMake(CGRectGetMaxX(screen)-.5,CGRectGetMidY(screen));
        NSInteger recipient=[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
        self.captureBackingAdmissions[window]=@{@"stage":@"lane",@"lane":@(lane),@"confined":@(confined),@"recipient":@(recipient),@"guard":@(self.captureEdgeGuard.windowNumber),@"point":pointJSON(point)};
        if(!confined||recipient!=self.captureEdgeGuard.windowNumber)continue;
        NSMutableDictionary *candidate=base.mutableCopy;candidate[@"screen_rect"]=rectJSON(screen);candidate[@"guard_rect"]=rectJSON(self.captureEdgeGuardRect);candidate[@"guard_epoch"]=@(self.captureEdgeGuardEpoch);
        candidates[window]=candidate.copy;
    }
    BOOL changed=NO;
    for(NSNumber *window in self.captureBackings.allKeys)if(![self.captureBackings[window].descriptor isEqual:candidates[window]]){
        [self retireCaptureBackingForWindow:window];changed=YES;
    }
    for(NSNumber *window in candidates){
        if(self.captureBackings[window]||self.captureBackingsRetiring[window])continue;
        NSDictionary *candidate=candidates[window];LiveSource *source=self.sources[window];
        [self cancelCapturedInputForWindow:window];[source.captureMailbox requireFreshImage];
        DWCaptureBackingState *state=[DWCaptureBackingState new];state.descriptor=candidate;self.captureBackings[window]=state;
        [self.captureEdgeGuardLastBackings addObject:candidate];changed=YES;self.nativeViewSnapshot=nil;
        fprintf(stderr,"debug: capture backing requested window=%s epoch=%s screen=%s\n",window.description.UTF8String,[candidate[@"guard_epoch"]description].UTF8String,NSStringFromRect(NSRectFromCGRect(jsonRect(candidate[@"screen_rect"]))).UTF8String);
    }
    if(changed)[self.native setGuardedParkings:[self captureBackingDescriptors]];
    for(NSNumber *window in self.captureBackings.allKeys){
        DWCaptureBackingState *state=self.captureBackings[window];NSDictionary *backing=state.descriptor;LiveSource *source=self.sources[window];
        DWNativeAppliedParking *receipt=[self.native acknowledgedGuardedParkingForWindow:window identity:backing[@"identity"] generation:backing[@"generation"] guardEpoch:[backing[@"guard_epoch"]unsignedLongLongValue]];
        if(!receipt){state.receipt=nil;if(source.captureBackingPresented){source.captureBackingPresented=NO;[self.compositor contentChanged:window];}continue;}
        // Fence each root at its first genuine ACK and on stream replacement.
        // An unrelated root's receipt must never authorize its image or seed.
        if(source.captureMailbox&&source.captureMailbox!=state.mailbox){
            if(state.seed)atomic_store(&state.seed->completed,YES);state.seed=nil;
            [source.captureMailbox requireFreshImage];state.mailbox=source.captureMailbox;
            fprintf(stderr,"debug: capture backing capture fenced window=%s sequence=%llu\n",window.description.UTF8String,(unsigned long long)receipt.sequence);
        }
        state.receipt=receipt;[self bootstrapCaptureBacking:source];
        BOOL ready=[self captureBackingReady:source];
        if(ready!=source.captureBackingPresented){source.captureBackingPresented=ready;[self.compositor contentChanged:window];}
    }
}
- (void)configureNativeInput {
    [self configureGlobalTrackpad];[self configureMultitouch];
    // The title session tap must be installed after the global session tap so
    // a later global retry cannot observe its down before title admission.
    if(self.native&&[self globalGesturesEnabled]&&!self.globalTrackpad.running)return;
    if(self.native.ended||self.sessionInactive||!self.configured||!self.panels.count||self.nativeInput)return;
    __weak Desktop *weak=self;
    DWNativeInput *input=[[DWNativeInput alloc]initWithConsume:^BOOL(CGEventType type,CGEventRef event){return [weak nativeInput:type event:event];} earlyConsume:^BOOL(CGEventType type,CGEventRef event){return [weak earlyNativeTitle:type event:event];} ignoreEvent:^BOOL(CGEventRef event){
        int64_t tag=CGEventGetIntegerValueField(event,kCGEventSourceUserData);if(!tag)return NO;
        if([weak.postingTags containsObject:@(tag)])return YES;
        for(LiveSource *source in weak.sources.allValues)if(source.router.tag==tag)return YES;
        return NO;
    } cancelled:^{[weak cancelCapturedInputForWindow:nil];[weak cancelNativeInput];}];
    input.nativeMouseOwnershipChanged=^(CGEventRef event,NSIndexSet *buttons){[weak nativeMouseOwnershipChanged:event buttons:buttons];};
    // INFINIFY_DEBUG: a Dock-control packet that gets as far as this tap was dropped by neither session tap; say so (the line is rate-limited like the others).
    if(DWInputTrace())input.dockControl=^(CGEventRef event){Desktop *d=weak;char detail[96];snprintf(detail,sizeof detail,"reached the annotated tap undropped; multitouch_delivering=%d dock_tap_running=%d",(int)d.multitouch.delivering,(int)d.dockTap.running);DWDockControlTrace("annotated-tap",event,DWDockControlClassify(event,NULL,NULL),DWDockControlPass,"reached-annotated-tap",detail);};
    if([input start]){self.nativeInput=input;self.nativeInputNoted=NO;return;}
    if(!self.nativeInputNoted){self.nativeInputNoted=YES;[self say:@"Native canvas gestures over windows need existing Accessibility/input access. IPC and gestures on empty canvas remain available."];}
}
- (void)refreshNativeButtons:(LiveSource *)source {
    CFTimeInterval now=CACurrentMediaTime();
    if(self.cleaning||self.sessionInactive||!self.configured||self.native.ended||!source||source.detached||source.nativeVisibilityHeld||source.nativeButtonsReading||source.nativeButtonsNext>now||!AXIsProcessTrusted()||!DWInScope(self.scope,source.router.pid))return;
    source.nativeButtonsReading=YES;source.nativeButtonsNext=now+.2;
    if(!self.nativeButtonQueue)self.nativeButtonQueue=dispatch_queue_create("org.infinify.native-decorations",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
    // Routine, unchanged window observations must not starve an AX chrome read.
    // Only source/chrome changes or a different native session invalidate it.
    NSDictionary *identity=[source.identity copy];uint64_t revision=source.nativeButtonsRevision,session=self.nativeSessionEpoch;__weak Desktop *weak=self;
    dispatch_async(self.nativeButtonQueue,^{@autoreleasepool{
        NSDictionary *report=DWNativeDecorationButtons(identity);
        dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;source.nativeButtonsReading=NO;
            if(!d||d.cleaning||d.sessionInactive||!d.configured||d.native.ended||d.nativeSessionEpoch!=session||d.sources[source.logical]!=source||source.detached||source.nativeButtonsRevision!=revision||![source.identity isEqual:identity]||!DWInScope(d.scope,source.router.pid))return;
            NSDictionary *current=source.nativeButtons;CGRect native=CGRectZero;BOOL nativeCurrent=NO;
            if(!report&&current){
                DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
                nativeCurrent=dw_focus_owner(selected,&native);
            }
            source.nativeButtons=DWNativeButtonsAfterRefresh(report,current,identity,CACurrentMediaTime(),nativeCurrent,native);
            source.nativeButtonsMoveCandidate=nil;
            if(DWInputTrace()){
                NSString *reason=asString(source.nativeButtons[@"title_reason"])?:report?@"stale_report":@"report_unavailable";
                if(![source.nativeTitleDebugReason isEqual:reason]){
                    source.nativeTitleDebugReason=reason;
                    NSDictionary *detail=asDict(source.nativeButtons[@"title_detail"]);
                    NSString *geometry=detail?[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:detail options:0 error:nil] encoding:NSUTF8StringEncoding]:nil;
                    fprintf(stderr,"debug: native title cache window=#%s pid=%d wid=%u region=%d reason=%s detail=%s\n",source.logical.description.UTF8String,source.router.pid,source.router.wid,asDict(source.nativeButtons[@"title"][@"region"])!=nil,reason.UTF8String,geometry.UTF8String?:"none");
                }
            }
        });
    }});
}
- (BOOL)nativeGreen:(LiveSource *)source at:(CGPoint)point {
    if(!source.nativeButtons||CACurrentMediaTime()-[source.nativeButtons[@"sampled_at"]doubleValue]>1||![birth(source.router.pid)isEqual:source.router.processBirth]||!DWInScope(self.scope,source.router.pid))return NO;
    if(self.native.familiesNeeded){uint32_t parent=0;if(!DWNativeWindowParent(source.identity,&parent)||parent)return NO;}
    NSDictionary *info=windowInfo(source.router.wid);CGRect displayed=CGRectZero,own=CGRectZero;
    if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||![info[(id)kCGWindowIsOnscreen]boolValue]||[info[(id)kCGWindowAlpha]doubleValue]<=0
        ||!info[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&displayed)||!DWNativeBounds(source.router.wid,&own))return NO;
    return DWNativeDecorationHit(source.nativeButtons,source.identity,own,displayed,point);
}
- (BOOL)replicaGreen:(LiveSource *)source at:(CGPoint)point output:(NSNumber *)output {
    if(!DWCapturedInputAvailable(source)||!source.pixels||(self.native&&![self.nativeViews replica:source.logical output:output])||!source.nativeButtons||CACurrentMediaTime()-[source.nativeButtons[@"sampled_at"]doubleValue]>1||!DWInScope(self.scope,source.router.pid)||![birth(source.router.pid)isEqual:source.router.processBirth])return NO;
    NSDictionary *placement=nil;for(NSDictionary *item in [self presentationSnapshot][@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:output]){placement=item;break;}
    if(!placement||[placement[@"family_only"]boolValue])return NO;CGRect own=CGRectZero;
    NSDictionary *info=windowInfo(source.router.wid);
    if([info[(id)kCGWindowOwnerPID]intValue]!=source.router.pid||!DWNativeBounds(source.router.wid,&own)||!CGRectContainsPoint(jsonRect(placement[@"clip_rect"]),point))return NO;
    if(!self.native||self.native.familiesNeeded){uint32_t parent=0;if(!DWNativeWindowParent(source.identity,&parent)||parent)return NO;}
    return DWCapturedInputAvailable(source)&&DWNativeDecorationHit(source.nativeButtons,source.identity,own,jsonRect(placement[@"screen_rect"]),point);
}
- (void)cancelNativeInput {
    [self cancelNativeTitleClick];
    [self.navigation cancelNativeClick];
    [self cancelNativeHoverForWindow:nil];
    self.nativeDecorationPress=nil;
    self.nativeButtonHover=nil;
    DesktopView *view=self.nativeGestureView;self.nativeGestureView=nil;
    if(view.gesture){view.clearsFocus=NO;view.lastDragPan=0;[view released:view.lastPoint at:NSProcessInfo.processInfo.systemUptime];}
    view.nativeTitlePress=nil;
    self.nativeScrollView.scrollPan=nil;self.nativeScrollView.scrollPanTime=0;self.nativeScrollView.lastScrollPan=0;
    self.nativeScrollView=nil;self.nativeScrollTime=0;[self.panLaunch cancel];
    if(self.nativeMagnifyView)[self cancelGestures];self.nativeMagnifyView=nil;self.nativeMagnifySource=nil;
}
// These are the actual window's events, observed before AppKit delivers them. Only
// a binding, pick-mode policy or normal resize border takes an annotated press;
// a qualified title down arrives earlier through the session-stage path. A
// plain interior click remains the app's.
// Once taken, the matching drag and release stay with this view even as a pan
// moves the window out from under the pointer. No global input is synthesized.
- (void)deliverNative:(NSEvent *)event type:(CGEventType)type view:(DesktopView *)view at:(CGPoint)point {
    [self deliverNative:event type:type view:view at:point familyHit:nil];
}
- (void)deliverNative:(NSEvent *)event type:(CGEventType)type view:(DesktopView *)view at:(CGPoint)point familyHit:(NSDictionary *)hit {
    BOOL saved=view.nativePointValid;CGPoint previous=view.nativePoint;NSDictionary *previousHit=view.nativeFamilyHit;view.nativePointValid=YES;view.nativePoint=point;view.nativeFamilyHit=hit;
    @try {
        switch(type){
            case kCGEventLeftMouseDown:case kCGEventRightMouseDown:case kCGEventOtherMouseDown:[view mouseDown:event];break;
            case kCGEventLeftMouseDragged:case kCGEventRightMouseDragged:case kCGEventOtherMouseDragged:[view mouseDragged:event];break;
            case kCGEventLeftMouseUp:case kCGEventRightMouseUp:case kCGEventOtherMouseUp:[view mouseUp:event];break;
            case kCGEventScrollWheel:[view scrollWheel:event];break;
            default:if(event.type==NSEventTypeMagnify)[view magnifyWithEvent:event];break;
        }
    } @finally {view.nativePointValid=saved;view.nativePoint=previous;view.nativeFamilyHit=previousHit;}
}
- (BOOL)validateInputTarget:(NSDictionary *)target {
    if(!target||self.cleaning||self.sessionInactive||self.native.ended||!AXIsProcessTrusted())return NO;
    LiveSource *source=self.sources[target[@"window"]];if(!source||source.detached)return NO;
    BOOL ownsOutput=NO;for(DesktopView *view in self.views)if([view.outputs containsObject:target[@"output"]])ownsOutput=YES;if(!ownsOutput)return NO;
    NSDictionary *binding=nil;for(NSDictionary *window in [self call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical])binding=asDict(window[@"source"]);
    if(![binding[@"generation"]isEqual:target[@"generation"]]||!boundIdentity(source.identity,binding[@"identity"])||!boundIdentity(source.identity,target[@"root_identity"]?:target[@"identity"]))return NO;
    if(!self.native&&![target[@"native_member"]boolValue])return boundIdentity(source.identity,target[@"identity"])&&[source.router valid];
    if(!DWInScope(self.scope,source.router.pid)||(self.native?![[self.native rootWindowFor:source.router.wid]isEqual:@(source.router.wid)]:![source.router valid]))return NO;
    // Admission from a copy also checks the active capture epoch in -forward:.
    // A release can outlive that capture geometry, but still belongs only to the
    // exact same freshly validated root binding and native descendant.
    return DWNativeWindowBelongsToRoot(target[@"identity"],source.identity);
}
- (BOOL)postInput:(CGEventRef)event target:(NSDictionary *)target local:(CGPoint)local {
    LiveSource *source=self.sources[target[@"window"]];if(!source||source.detached)return NO;
    if(!self.native&&![target[@"native_member"]boolValue])return [source.router post:event at:local];
    if(!event||![self validateInputTarget:target]){[self.relativeMotion reset];return NO;}
    CGRect bounds=jsonRect(target[@"native_bounds"]);CGEventType type=CGEventGetType(event);
    BOOL release=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp
        ||(DWNativeTabletProximityEvent(event)&&!CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity))
        ||(type==kCGEventTabletPointer&&CGEventGetDoubleValueField(event,kCGTabletEventPointPressure)==0&&!CGEventGetIntegerValueField(event,kCGTabletEventPointButtons));
    if(release){if(![self validateInputTarget:target]||!DWNativeBounds([target[@"identity"][@"wid"]unsignedIntValue],&bounds))return NO;}
    // Adapt a copy exactly once at the posting boundary. In particular the
    // physical event tap's packet must never inherit native coordinates or tags.
    CGEventRef packet=CGEventCreateCopy(event);if(!packet){[self.relativeMotion reset];return NO;}
    if(DWNativeRelativeMotionEvent(packet)){
        if(!self.relativeMotion)self.relativeMotion=[DWNativeRelativeMotion new];CGPoint scale=jsonPoint(target[@"motion_scale"]);
        if(![self.relativeMotion adjustEvent:packet target:target scaleX:scale.x scaleY:scale.y]){CFRelease(packet);return NO;}
    }
    if(!self.postingTags)self.postingTags=[NSMutableSet set];[self.postingTags addObject:@(source.router.tag)];
    BOOL sent=DWNativeReplicaPost(packet,source.router.eventSource,source.router.tag,target[@"identity"],bounds,local);
    CFRelease(packet);if(!sent)[self.relativeMotion reset];return sent;
}
- (NSDictionary *)resolveCapturedPointer:(NSDictionary *)target screen:(CGPoint)screen {
    if(![self validateInputTarget:target]||!isfinite(screen.x)||!isfinite(screen.y))return nil;
    NSDictionary *snapshot=[self presentationSnapshot],*placement=nil;
    LiveSource *source=self.sources[target[@"window"]];
    if(!DWCapturedInputAvailable(source)||!source.pixels||(self.native&&![self.nativeViews replica:source.logical output:target[@"output"]]))return nil;
    for(NSDictionary *item in snapshot[@"placements"])if([item[@"window"]isEqual:source.logical]&&[item[@"output"]isEqual:target[@"output"]]){placement=item;break;}
    NSDictionary *binding=nil;for(NSDictionary *window in [self call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical])binding=asDict(window[@"source"]);
    if(![binding[@"observation_known"]boolValue])return nil;
    CGRect own=CGRectZero,current=CGRectZero,site=jsonRect(placement[@"screen_rect"]);
    if(!source.router.bounds||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&own)
       ||!DWNativeBounds(source.router.wid,&current)||!CGRectEqualToRect(own,current)
       ||CGRectIsEmpty(own)||CGRectIsInfinite(own)||CGRectIsNull(own)
       ||CGRectIsEmpty(site)||CGRectIsInfinite(site)||CGRectIsNull(site))return nil;
    CGRect recipient=own;
    if([target[@"native_member"]boolValue]&&!DWNativeBounds([target[@"identity"][@"wid"]unsignedIntValue],&recipient))return nil;
    if(CGRectIsEmpty(recipient)||CGRectIsInfinite(recipient)||CGRectIsNull(recipient))return nil;
    // Keep the original output and recipient even beyond its viewport. A
    // moving camera changes this mapping, never the application's ownership.
    CGPoint scale=CGPointMake(own.size.width/site.size.width,own.size.height/site.size.height);
    CGPoint local=CGPointMake((screen.x-site.origin.x)*scale.x+own.origin.x-recipient.origin.x,
                             (screen.y-site.origin.y)*scale.y+own.origin.y-recipient.origin.y);
    if(!isfinite(scale.x)||!isfinite(scale.y)||!isfinite(local.x)||!isfinite(local.y))return nil;
    NSMutableDictionary *updated=[target mutableCopy];updated[@"native_bounds"]=rectJSON(recipient);updated[@"motion_scale"]=pointJSON(scale);
    return DWCapturedInputAvailable(source)?@{@"target":updated.copy,@"local":pointJSON(local)}:nil;
}
- (BOOL)forwardCapturedPointer:(CGEventRef)event screen:(CGPoint)screen {
    __weak Desktop *weak=self;
    BOOL sent=[self.pointerGrab forwardEvent:event screen:screen resolve:^NSDictionary *(NSDictionary *target,CGPoint point){return [weak resolveCapturedPointer:target screen:point];}
        validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];}
        post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
    if(!self.pointerGrab.active)[self.relativeMotion reset];return sent;
}
- (BOOL)forwardTabletTail:(CGEventRef)event {
    if(![self.tablet ownsEvent:event])return NO;
    __weak Desktop *weak=self;NSDictionary *captured=[self.tablet capturedTargetForEvent:event];
    if(captured&&!DWCapturedInputAvailable(self.sources[captured[@"window"]])){
        // Closing an admitted contact checks its original identity, not capture
        // availability. Suppress its physical tail, including additional downs.
        [self.tablet cancelTargetsMatching:^BOOL(NSDictionary *target){return sameInputTarget(target,captured);}
            validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];}
            post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
    }
    NSDictionary *resolved=nil;
    if(!DWNativeTabletProximityEvent(event)||CGEventGetIntegerValueField(event,kCGTabletProximityEventEnterProximity)){
        NSDictionary *target=[self.tablet capturedTargetForEvent:event];
        if(target)resolved=[self resolveCapturedPointer:target screen:CGEventGetLocation(event)];
    }
    // A held tool always retains its original root/member and output. A current
    // placement supplies the camera mapping even outside that display's clip.
    // Missing/stale geometry suppresses motion; release/tool-out still closes
    // the admitted recipient at its last validated application point.
    return [self.tablet forwardEvent:event target:resolved[@"target"] local:resolved?jsonPoint(resolved[@"local"]):CGPointZero validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
}
- (void)cancelCapturedInputForWindow:(NSNumber *)window {
    __weak Desktop *weak=self;
    [self cancelNativeHoverForWindow:window];
    // A held down has not reached any native recipient. Cancel its entire
    // queued sequence without synthesizing a release or completed click.
    for(DesktopView *view in self.views)if(view.heldPress&&(!window||[view.heldWindow isEqual:window])){
        [view.heldTimer invalidate];view.heldTimer=nil;view.heldPress=view.heldDrag=view.heldRelease=nil;
        view.heldWindow=view.heldOutput=nil;view.heldIntent=nil;view.heldReleased=view.heldNavigate=NO;view.clickWindow=nil;
    }
    [self.tablet cancelTargetsMatching:^BOOL(NSDictionary *target){return !window||[target[@"window"]isEqual:window];} validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef event,NSDictionary *target,CGPoint local){return [weak postInput:event target:target local:local];}];
    if(!window||[self.pointerGrab.target[@"window"]isEqual:window]){
        [self.pointerGrab cancelWithValidate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef event,NSDictionary *target,CGPoint local){return [weak postInput:event target:target local:local];}];
        [self.relativeMotion reset];
    }
}
- (BOOL)earlyNativeTitle:(CGEventType)type event:(CGEventRef)cg {
    if(!cg||type!=kCGEventLeftMouseDown||CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)!=0
        ||DWNativeTabletEvent(cg)||!self.native||[self nativeUnavailable]||!self.configured||self.cleaning||self.sessionInactive
        ||self.routingEarlyNativeTitle||self.nativeGestureView||self.nativeScrollView||self.nativeMagnifyView||self.pointerGrab.active
        ||self.gestureOwner||self.trackpad.engaged||self.globalGestureContact||self.globalTrackpad.ownsTouches
        ||self.globalTrackpad.hasNativeMousePress||self.magnifying||(NSEvent.pressedMouseButtons&~1UL))return NO;
    NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!event||event.subtype==NSEventSubtypeTouch)return NO;
    CGPoint point=CGEventGetLocation(cg);DesktopView *view=nil;NSNumber *output=nil;
    for(DesktopView *candidate in self.views){
        if(candidate.gesture||candidate.heldPress||candidate.pressedSource||candidate.pressedTablet||candidate.pressedPointerGrab)return NO;
        NSNumber *found=[candidate outputAt:point];if(found){if(view)return NO;view=candidate;output=found;}
    }
    if(!view)return NO;
    NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);CGWindowID wid=[recipient[@"wid"]unsignedIntValue];LiveSource *source=nil;
    // A temporary background has no current logical hit site. Refuse its
    // complete native family before title tracking, even without chrome data.
    NSNumber *root=[self.native rootWindowFor:wid];
    for(LiveSource *held in self.sources.allValues){NSDictionary *identity=held.identity;
        if(held.nativeVisibilityHeld&&!held.detached&&[root isEqual:identity[@"wid"]]
            &&[recipient[@"pid"]isEqual:identity[@"pid"]]&&[recipient[@"birth_sec"]isEqual:identity[@"birth_sec"]]
            &&[recipient[@"birth_usec"]isEqual:identity[@"birth_usec"]]&&DWInScope(self.scope,held.router.pid)){
            [self cancelNativeTitleClick];self.nativeFillBlockedButtons|=1;return YES;
        }
    }
    for(NSDictionary *placement in self.nativeFillHandoff[@"background"][@"placements"]){
        LiveSource *background=self.sources[placement[@"window"]];NSDictionary *identity=background.identity;
        if(background&&!background.detached&&[placement[@"output"]isEqual:self.nativeFillHandoff[@"output"]]
            &&boundIdentity(placement[@"source"][@"identity"],identity)&&[root isEqual:identity[@"wid"]]
            &&[recipient[@"pid"]isEqual:identity[@"pid"]]&&[recipient[@"birth_sec"]isEqual:identity[@"birth_sec"]]
            &&[recipient[@"birth_usec"]isEqual:identity[@"birth_usec"]]&&DWInScope(self.scope,background.router.pid)){
            [self cancelNativeTitleClick];self.nativeFillBlockedButtons|=1;return YES;
        }
    }
    for(LiveSource *candidate in self.sources.allValues)
        if(!candidate.detached&&candidate.router.wid==wid&&boundIdentity(recipient,candidate.identity)){source=candidate;break;}
    if(!source||!DWInScope(self.scope,source.router.pid))return NO;
    // Physical chrome recognition precedes logical/renderer admission. An
    // unavailable ACK or layout must never lend a recognized down to AppKit.
    BOOL title=DWNativeWindowDragHit(source.identity,source.nativeButtons,point);
    BOOL green=!title&&[self nativeGreen:source at:point];
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*record=nil,*placement=nil,*out=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){record=row;break;}
    for(NSDictionary *row in snapshot[@"placements"])if([row[@"window"]isEqual:source.logical]&&[row[@"output"]isEqual:output]){placement=row;break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){out=row;break;}
    NSDictionary *binding=asDict(record[@"source"]);CGRect own=CGRectZero,displayed=CGRectZero;NSDictionary *info=windowInfo(wid);
    BOOL frame=[info[(id)kCGWindowOwnerPID]intValue]==source.router.pid&&[info[(id)kCGWindowIsOnscreen]boolValue]&&[info[(id)kCGWindowAlpha]doubleValue]>0
        &&info[(id)kCGWindowBounds]&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&displayed)
        &&DWNativeBounds(wid,&own)&&DWNativeChromeFrameMatches(own,displayed,placement,out,point);
    NSMutableDictionary *context=[@{@"window":source.logical}mutableCopy];for(NSString *flag in @[@"pinned",@"widget"])if([placement[flag]boolValue])context[flag]=@YES;
    NSDictionary *hit=context[@"pinned"]||context[@"widget"]||[placement[@"fullscreen"]boolValue]?context:DWPickHit(context,snapshot,output);
    NSDictionary *border=frame?[view resizeBorderForButton:0 flags:event.modifierFlags hit:hit at:point output:output]:nil;
    if(border&&![border[@"window"]isEqual:source.logical])border=nil;
    if(!title&&!green&&!border)return NO; // Unknown content and native controls keep their original packets.
    [self cancelNativeTitleClick];[self.navigation cancelNativeClick];
    self.nativeGestureView=view;self.nativeGestureButton=0;
    const char *refusal=NULL;
    if(!frame)refusal="physical_frame";
    else if(!binding[@"generation"]||!boundIdentity(source.identity,binding[@"identity"]))refusal="binding";
    else if(![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output]||[self.nativeViews replica:source.logical output:output])refusal="native_owner";
    else if(self.nativeFillHandoff||source.nativeMouseOwnership||self.nativeOwnershipTransfer||self.nativeHoverTransfer||[[self.resize busyWindow]isEqual:source.logical])refusal="geometry_owned";
    else if([hit[@"widget"]boolValue])refusal="widget";
    if(refusal){DWNativeTitleRefused(YES,refusal,source.logical,wid,point,nil);return YES;}
    NSDictionary *intent=@{@"window":source.logical,@"output":output,@"identity":source.identity.copy,@"generation":binding[@"generation"]};
    NSEventModifierFlags modifiers=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift);
    NSDictionary *mouseBinding=[self mouseBinding:@"left" source:nil flags:event.modifierFlags window:YES under:source.logical pick:[hit[@"pick"]boolValue]];
    NSString *kind=asString(mouseBinding[@"kind"]);
    BOOL actionBinding=[@[@"pan_viewport",@"move_window",@"move_snapped_windows",@"resize_window",@"resize_window_snapped",@"center_nearest",@"action"]containsObject:kind?:@""];
    if((green&&!(modifiers&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagShift)))
        ||(title&&!modifiers&&!mouseBinding&&![hit[@"pick"]boolValue]&&event.clickCount==2)){
        NSMutableDictionary *press=[intent mutableCopy];press[@"action"]=(green&&(modifiers&NSEventModifierFlagOption))?@"fit":@"fullscreen";
        press[@"start"]=pointJSON(point);press[@"replica"]=@NO;if(title)press[@"title"]=@YES;
        self.nativeDecorationPress=press;return YES;
    }
    if(!border&&!actionBinding&&(!title||modifiers||mouseBinding||[hit[@"pick"]boolValue])){
        DWNativeTitleRefused(YES,"chrome_policy",source.logical,wid,point,nil);return YES;
    }
    // Same initialization as a canvas press, without a second renderer hit.
    // This dispatches controller gestures only; it cannot enter holdPress or
    // post a content click. Native/capture metadata is never rewritten.
    view.clickWindow=nil;[self.navigation releaseCycle];[self cancelGestures];[self cancelNavigation];[self.panLaunch cancel];view.scrollPanTime=0;
    NSDictionary *current=[self call:@{@"op":@"snapshot"}],*currentBinding=nil;
    for(NSDictionary *row in current[@"windows"])if([row[@"window"]isEqual:source.logical]){currentBinding=asDict(row[@"source"]);break;}
    if(self.cleaning||self.sessionInactive||self.native.ended||self.sources[source.logical]!=source||source.detached
        ||!boundIdentity(source.identity,currentBinding[@"identity"])||![binding[@"generation"]isEqual:currentBinding[@"generation"]]
        ||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output]||![recipient isEqual:DWNativeEventRecipientAtPoint(point)]){
        DWNativeTitleRefused(YES,"changed_before_chrome",source.logical,wid,point,nil);return YES;
    }
    view.startPoint=view.lastPoint=point;view.dragOutput=view.lastOutput=output;view.gestureButton=0;view.lastDragPan=0;view.lastScrollPan=0;view.clearsFocus=NO;
    if(border){[view beginResize:source.logical edges:asString(border[@"edges"]) snapped:[border[@"snapped"]boolValue] at:point output:output];[self render];}
    else if(actionBinding){
        // Use the already selected binding, with no ordinary-click fallback.
        // Re-entering press: could re-resolve policy and forward a native down.
        if([kind isEqual:@"move_window"]||[kind isEqual:@"move_snapped_windows"]){
            NSDictionary *begun=[self call:@{@"op":@"begin_drag",@"window":source.logical,@"output":output,@"group":@([kind isEqual:@"move_snapped_windows"])}];
            if(begun){view.gesture=2;[self.navigation perform:begun];}
        }else if([kind isEqual:@"resize_window"]||[kind isEqual:@"resize_window_snapped"])
            [view beginResize:source.logical edges:nil snapped:[kind isEqual:@"resize_window_snapped"] at:point output:output];
        else if([kind isEqual:@"pan_viewport"])view.gesture=1;
        else if([kind isEqual:@"center_nearest"]){view.gesture=DWPolicyPress;[view.hover nearestPress:point output:output focus:[mouseBinding[@"focus"]isEqual:@YES]];}
        else if([kind isEqual:@"action"]&&asString(mouseBinding[@"action"])){
            [self applyReply:[self call:@{@"op":@"focus",@"window":source.logical}]];
            [self action:mouseBinding[@"action"] output:output at:point held:[DWCycleHold modifiersDown]!=0];
        }
        [self render];
    }
    else {
        view.nativeTitlePress=intent;view.nativeTitleMoved=view.nativeTitleReleased=NO;
        NSDictionary *begun=[self call:@{@"op":@"begin_drag",@"window":source.logical,@"output":output,@"group":@NO}];
        if(begun){view.gesture=2;[self.navigation perform:begun];}[self render];
    }
    if(DWInputTrace())fprintf(stderr,"debug: native chrome owned window=#%s kind=%s gesture=%ld\n",source.logical.description.UTF8String,border?"resize":actionBinding?"binding":"title",(long)view.gesture);
    return YES;
}
// Is a mouse-moved packet at `point`, over the managed native window `root` (the window server's own answer to what is under the
// pointer), one the application must not get: below [zoom] interact_min (DWPickMotion, controller-hit.h) a canvas window is a pick target
// and a widget, a screen-pinned and a fullscreen window are not (upstream's pointer_focus_under_pick; their placement says which). The
// window server delivers the motion to the real window under the pointer by itself, so the tap dropping the packet is all that keeps
// hover from the application. Every moved packet comes here, so nothing in it calls the controller: the last render's outputs say
// whether the pointer's output is in pick mode, and only then is the last rendered presentation's placement of the window read.
- (BOOL)pickMotionAt:(CGPoint)point window:(NSNumber *)root {
    static NSDictionary *pick;if(!pick)pick=@{@"pick":@YES};
    return DWPickMotion(self.pointerOutputs,point,^NSDictionary *(NSNumber *output){
        for(NSNumber *logical in self.sources){LiveSource *source=self.sources[logical];
            if(source.detached||source.router.wid!=root.unsignedIntValue)continue;
            for(NSDictionary *placement in self.renderedPresentation[@"placements"])if([placement[@"window"]isEqual:logical]&&[placement[@"output"]isEqual:output])
                return [placement[@"widget"]boolValue]||[placement[@"pinned"]boolValue]||[placement[@"fullscreen"]boolValue]?nil:pick;
            return nil;}
        return nil;});
}
- (BOOL)nativeInput:(CGEventType)type event:(CGEventRef)cg {
    int64_t tag=CGEventGetIntegerValueField(cg,kCGEventSourceUserData);
    if(tag&&[self.postingTags containsObject:@(tag)])return NO;
    if(tag)for(LiveSource *source in self.sources.allValues)if(source.router.tag==tag)return NO;
    // Native Fill owns temporary geometry. Consume each refused button's whole
    // pair, including its tail after the handoff ends; never map an intermediate
    // app frame through the controller's already-final camera.
    NSInteger fillButton=CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber);
    BOOL fillDown=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
    if(fillDown)[self cancelNativeTitleClick];
    BOOL fillUp=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    BOOL fillDrag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
    uint64_t fillBit=fillButton>=0&&fillButton<64?UINT64_C(1)<<fillButton:0;
    // A fresh physical down retires a pair whose release was lost, just as
    // DWNativeInput retires its own capture before admitting a new press.
    if(fillDown)self.nativeFillBlockedButtons&=~fillBit;
    if(fillBit&&(self.nativeFillBlockedButtons&fillBit)&&(fillUp||fillDrag)){
        if(fillUp)self.nativeFillBlockedButtons&=~fillBit;return YES;
    }
    NSEvent *fillScroll=type==kCGEventScrollWheel?[NSEvent eventWithCGEvent:cg]:nil;
    BOOL fillScrollPhased=fillScroll.hasPreciseScrollingDeltas&&(fillScroll.phase!=NSEventPhaseNone||fillScroll.momentumPhase!=NSEventPhaseNone);
    BOOL fillScrollBegin=(fillScroll.phase&(NSEventPhaseBegan|NSEventPhaseMayBegin))!=0;
    BOOL fillScrollEnd=((fillScroll.phase|fillScroll.momentumPhase)&NSEventPhaseCancelled)||(fillScroll.momentumPhase&NSEventPhaseEnded);
    if(fillScrollPhased&&fillScrollBegin)self.nativeFillBlockedScroll=NO;
    if(fillScrollPhased&&self.nativeFillBlockedScroll){if(fillScrollEnd)self.nativeFillBlockedScroll=NO;return YES;}
    if(self.nativeFillHandoff&&(fillDown||type==kCGEventScrollWheel)){
        CGWindowID recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!recipient)recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        NSNumber *root=[self.native rootWindowFor:recipient];
        BOOL held=[root isEqual:self.nativeFillHandoff[@"identity"][@"wid"]];
        // Retained background windows are visual coverage only. Their current
        // fullscreen scene has no input site, so consume the complete pair.
        for(NSDictionary *placement in self.nativeFillHandoff[@"background"][@"placements"]){
            LiveSource *live=self.sources[placement[@"window"]];
            if(live&&!live.detached&&[placement[@"output"]isEqual:self.nativeFillHandoff[@"output"]]
                &&boundIdentity(placement[@"source"][@"identity"],live.identity)&&[root isEqual:live.identity[@"wid"]])held=YES;
        }
        for(DesktopView *view in self.views)if((CGWindowID)view.window.windowNumber==recipient)held=YES;
        if(held){if(fillDown)self.nativeFillBlockedButtons|=fillBit;if(fillScrollPhased&&!fillScrollEnd)self.nativeFillBlockedScroll=YES;return YES;}
    }
    if(fillDown||type==kCGEventScrollWheel){
        CGWindowID recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!recipient)recipient=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        NSNumber *root=[self.native rootWindowFor:recipient];
        for(LiveSource *source in self.sources.allValues)if(source.nativeVisibilityHeld&&[root isEqual:source.identity[@"wid"]]){
            if(fillDown)self.nativeFillBlockedButtons|=fillBit;if(fillScrollPhased&&!fillScrollEnd)self.nativeFillBlockedScroll=YES;return YES;
        }
    }
    // A shell-owned decoration/action pair predates any second button that
    // may have reached a captured child. That grab must not consume this up.
    BOOL nativePair=self.nativeGestureView&&!DWNativeTabletEvent(cg)
        &&CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)==self.nativeGestureButton
        &&(type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged
           ||type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp);
    if(!nativePair&&[self.pointerGrab ownsEvent:cg]){
        NSDictionary *target=self.pointerGrab.target;CGPoint point=CGEventGetLocation(cg);
        [self forwardCapturedPointer:cg screen:point];
        BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
        if(up)for(DesktopView *view in self.views)if(view.pressedPointerGrab&&(!target||sameInputTarget(view.pressedTarget,target))&&view.pressedButton==CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber)){
            // The adapter owns any other held buttons. End this view's gesture
            // without cancelling those independently paired native presses.
            view.pressedSource=nil;view.pressedTarget=nil;view.pressedPointerGrab=NO;
            [view released:point at:[NSEvent eventWithCGEvent:cg].timestamp];
        }
        return YES;
    }
    if(DWNativeTabletEvent(cg)){
        [self cancelNativeHoverForWindow:nil];
        if(!self.tablet)self.tablet=[DWNativeTabletRouter new];[self.tablet observeEvent:cg];
        if(self.cleaning||self.sessionInactive||self.native.ended){[self.tablet reset];return NO;}
        __weak Desktop *weak=self;
        NSDictionary *retired=[self.tablet retireReplacedToolForEvent:cg validate:^BOOL(NSDictionary *target){return [weak validateInputTarget:target];} post:^BOOL(CGEventRef packet,NSDictionary *target,CGPoint local){return [weak postInput:packet target:target local:local];}];
        NSNumber *device=@(CGEventGetIntegerValueField(cg,DWNativeTabletProximityEvent(cg)?kCGTabletProximityEventDeviceID:kCGTabletEventDeviceID));
        CGPoint point=CGEventGetLocation(cg);
        if(retired)for(DesktopView *view in self.views)if(view.pressedTablet&&[view.pressedTabletDevice isEqual:device]&&sameInputTarget(view.pressedTarget,retired)){
            view.pressedSource=nil;view.pressedTarget=nil;view.pressedTablet=NO;view.pressedTabletDevice=nil;view.clickWindow=nil;
            [view released:point at:[NSEvent eventWithCGEvent:cg].timestamp];
        }
        BOOL owned=[self.tablet ownsEvent:cg];
        NSDictionary *capturedTarget=[self.tablet capturedTargetForEvent:cg];
        BOOL toolOut=DWNativeTabletProximityEvent(cg)&&!CGEventGetIntegerValueField(cg,kCGTabletProximityEventEnterProximity);
        if(owned){
            // Ownership is established by the admitted tool, not today's hit.
            // Overlay and independent native views therefore share the same
            // contact tail even over another source, display or native app.
            [self forwardTabletTail:cg];
            BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
            if(up||toolOut)for(DesktopView *view in self.views)if(view.pressedTablet&&[view.pressedTabletDevice isEqual:device]&&(!capturedTarget||sameInputTarget(view.pressedTarget,capturedTarget))&&(toolOut||view.pressedButton==CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber))){
                // The router has already paired this release, or closed all
                // buttons on tool-out. Do not synthesize another plain up or
                // cancel additional admitted buttons when the primary lifts.
                view.pressedSource=nil;view.pressedTarget=nil;view.pressedTablet=NO;view.pressedTabletDevice=nil;if(toolOut)view.clickWindow=nil;
                [view released:point at:[NSEvent eventWithCGEvent:cg].timestamp];
            }
            return YES;
        }
        if(toolOut)return NO;
        // Below [zoom] interact_min (default 0.5, DriftWM v0.20.0) a window takes no pointer input, a pen's dedicated packets included
        // (upstream's pointer_focus_under_pick gives a pick target no tablet focus): the pen's mouse-subtype packets are the pick's
        // and its own packets must not reach the application either. Only packets over a pick target are taken; the rest stay as they were.
        if(self.native&&(type==kCGEventTabletPointer||type==kCGEventTabletProximity)){
            CGPoint at=CGEventGetLocation(cg);
            for(DesktopView *view in self.views){NSNumber *output=[view outputAt:at];if(!output)continue;
                if([asDict([view hit:at output:output])[@"pick"]isEqual:@YES])return YES;
                break;}
        }
        if(type==kCGEventTabletPointer||type==kCGEventTabletProximity){
            // The overlay's fresh packets still go through AppKit's normal
            // canvas admission. Observing proximity above does not authorize
            // intercepting a pen which is drawing in an unrelated native app.
            if(!self.native)return NO;
            // Dedicated tablet packets may omit mouse-only annotations. Fresh
            // admission still belongs to the actual canvas panel under the pen,
            // never a logical replica covered by another application.
            CGWindowID recipient=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
            for(DesktopView *view in self.views){NSNumber *output=[view outputAt:point];if(!output)continue;NSDictionary *hit=[view hit:point output:output];LiveSource *source=self.sources[hit[@"window"]];
                if(recipient!=(CGWindowID)view.window.windowNumber)return NO;
                if(!source||![self.nativeViews replica:source.logical output:output])return NO;
                BOOL old=view.nativePointValid;CGPoint previous=view.nativePoint;view.nativePointValid=YES;view.nativePoint=point;
                BOOL sent=NO;@try{sent=[view forward:cg at:point output:output activate:NO];}@finally{view.nativePointValid=old;view.nativePoint=previous;}return sent;
            }
            return NO;
        }
    }
    if(type!=kCGEventMouseMoved&&type!=kCGEventScrollWheel&&type!=kCGEventLeftMouseDown&&type!=kCGEventLeftMouseDragged&&type!=kCGEventLeftMouseUp
        &&type!=kCGEventRightMouseDown&&type!=kCGEventRightMouseDragged&&type!=kCGEventRightMouseUp&&type!=kCGEventOtherMouseDown&&type!=kCGEventOtherMouseDragged&&type!=kCGEventOtherMouseUp){
        NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!self.native||event.type!=NSEventTypeMagnify||self.globalTrackpad.running)return NO;
        BOOL over=(event.phase&(NSEventPhaseEnded|NSEventPhaseCancelled))!=0;
        if(event.phase&NSEventPhaseMayBegin)return NO;
        if(self.cleaning||self.sessionInactive||self.native.ended){if(self.nativeMagnifyView)[self cancelNativeInput];return NO;}
        // Magnify is not a CG mouse event: its mouse-specific window/location
        // fields need not be populated. Resolve the real pointer recipient.
        CGPoint point=pointer();DesktopView *view=self.nativeMagnifyView;LiveSource *source=self.nativeMagnifySource;
        if(view&&(source.detached||self.sources[source.logical]!=source||!DWInScope(self.scope,source.router.pid)||![self.views containsObject:view])){[self cancelNativeInput];return NO;}
        if(!view){
            if(over||self.gestureOwner||self.magnifying||NSEvent.pressedMouseButtons)return NO;
            CGWindowID wid=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
            source=[self nativeSource:wid at:point];if(!source)return NO;
            for(DesktopView *candidate in self.views)if([candidate outputAt:point]){view=candidate;break;}
            if(!view)return NO;self.nativePinchAccepted=NO;
            [self deliverNative:event type:type view:view at:point];
            if(!self.nativePinchAccepted){[self cancelGestures];return NO;}
            if(!over&&event.phase!=NSEventPhaseNone){self.nativeMagnifyView=view;self.nativeMagnifySource=source;}
            return YES;
        }
        [self deliverNative:event type:type view:view at:point];
        if(over||event.phase==NSEventPhaseNone){self.nativeMagnifyView=nil;self.nativeMagnifySource=nil;}
        return YES;
    }
    if(type==kCGEventMouseMoved){
        CFTimeInterval now=CACurrentMediaTime();if(self.cleaning||self.sessionInactive||self.native.ended)return NO;
        [self queueNativeHover:cg];
        CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
        if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
        if(!wid)wid=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(CGEventGetLocation(cg).x,screenTop()-CGEventGetLocation(cg).y) belowWindowWithWindowNumber:0];
        NSNumber *root=[self.native rootWindowFor:wid];CGPoint point=CGEventGetLocation(cg);
        if(root){NSEvent *motion=[NSEvent eventWithCGEvent:cg];if(motion)for(DesktopView *view in self.views)if([view outputAt:point]){[view.hover nativeMotion:motion];break;}}
        // Below [zoom] interact_min a window takes no pointer input, hover included (POINTER.md): the canvas has had this motion above, so
        // its own hover, sloppy focus and edge pan go on, and the packet goes no further. The window server has already moved the cursor.
        if(root&&[self pickMotionAt:point window:root])return YES;
        if(now-self.nativeButtonMotion<.1)return NO;self.nativeButtonMotion=now;self.nativeButtonHover=nil;
        for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.wid==root.unsignedIntValue){self.nativeButtonHover=source.logical;[self refreshNativeButtons:source];break;}
        if(!self.nativeButtonHover)for(DesktopView *view in self.views)if((CGWindowID)view.window.windowNumber==wid){
            NSNumber *output=[view outputAt:point];NSDictionary *hit=output?[view hit:point output:output]:nil;
            LiveSource *source=self.sources[hit[@"window"]];
            if(source&&!hit[@"native_member"]&&!source.detached&&(!self.native||[self.nativeViews replica:source.logical output:output])){self.nativeButtonHover=source.logical;[self refreshNativeButtons:source];}break;
        }
        return NO;
    }
    BOOL down=type==kCGEventLeftMouseDown||type==kCGEventRightMouseDown||type==kCGEventOtherMouseDown;
    BOOL up=type==kCGEventLeftMouseUp||type==kCGEventRightMouseUp||type==kCGEventOtherMouseUp;
    BOOL drag=type==kCGEventLeftMouseDragged||type==kCGEventRightMouseDragged||type==kCGEventOtherMouseDragged;
    CGPoint point=CGEventGetLocation(cg);NSEvent *event=[NSEvent eventWithCGEvent:cg];if(!event)return NO;
    NSInteger button=CGEventGetIntegerValueField(cg,kCGMouseEventButtonNumber);
    DesktopView *captured=self.nativeGestureView;
    if(down&&captured&&button==self.nativeGestureButton){[self cancelNativeInput];captured=nil;}
    if(captured&&(drag||up)&&button==self.nativeGestureButton){
        if(captured.nativeTitlePress&&![captured nativeTitlePressCurrent]){[self cancelNativeInput];return YES;}
        NSDictionary *press=self.nativeDecorationPress;
        if(press){
            CGPoint started=jsonPoint(press[@"start"]);if(drag&&hypot(point.x-started.x,point.y-started.y)>5)self.nativeDecorationPress=nil;
            if(up){self.nativeDecorationPress=nil;LiveSource *source=self.sources[press[@"window"]];
                BOOL green=[press[@"title"]boolValue]?DWNativeWindowDragHit(source.identity,source.nativeButtons,point):[press[@"replica"]boolValue]?[self replicaGreen:source at:point output:press[@"output"]]:[self nativeGreen:source at:point];
                if([press[@"replica"]boolValue]){
                    NSDictionary *hit=[captured hit:point output:press[@"output"]];
                    CGWindowID top=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
                    green&=top==(CGWindowID)captured.window.windowNumber&&[hit[@"window"]isEqual:press[@"window"]]&&!hit[@"native_member"];
                }
                if(!self.cleaning&&!self.sessionInactive&&!self.native.ended&&source&&!source.detached&&[self.views containsObject:captured]&&[captured.outputs containsObject:press[@"output"]]&&boundIdentity(source.identity,press[@"identity"])&&green){
                    NSMutableDictionary *command=[press mutableCopy];[command removeObjectForKey:@"start"];[command removeObjectForKey:@"replica"];[command removeObjectForKey:@"title"];command[@"op"]=@"native_decoration";[self applyReply:[self call:command]];
                }
            }
        }
        if(!self.cleaning&&!self.native.ended&&[self.views containsObject:captured]){
            // An action or a refused grab still owns its button pair, even if it
            // started no drag. Never let its release become an app's lone mouse-up.
            if(captured.gesture)[self deliverNative:event type:type view:captured at:point];
        }else if(captured.gesture){captured.clearsFocus=NO;captured.lastDragPan=0;[captured released:captured.lastPoint at:event.timestamp];}
        if(up){captured.nativeTitlePress=nil;self.nativeGestureView=nil;}
        return YES;
    }
    if(self.cleaning||self.sessionInactive||self.native.ended||(!down&&type!=kCGEventScrollWheel))return NO;
    // Overlay gestures and scrolling stay in AppKit. This tap additionally
    // claims only a positively identified green control and its button pair.
    if(!self.native&&!down)return NO;
    if(type==kCGEventScrollWheel&&self.nativeScrollView){
        BOOL begin=(event.phase&(NSEventPhaseBegan|NSEventPhaseMayBegin))!=0;
        BOOL tail=event.momentumPhase!=NSEventPhaseNone;
        if(!begin&&(tail||event.timestamp-self.nativeScrollTime<.35)&&[self.views containsObject:self.nativeScrollView]){
            DesktopView *view=self.nativeScrollView;self.nativeScrollTime=event.timestamp;
            [self deliverNative:event type:type view:view at:point];
            if(((event.phase|event.momentumPhase)&NSEventPhaseCancelled)||(event.momentumPhase&NSEventPhaseEnded))self.nativeScrollView=nil;
            return YES;
        }
        self.nativeScrollView=nil;
    }
    // Existing grabs/scrolls retain their recipient across the edge. Only a
    // fresh guard press is suppressed before source/chrome admission below.
    if([self captureEdgeGuardConsumes:type event:cg])return YES;
    CGWindowID wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    if(!wid)wid=(CGWindowID)CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer);
    if(!wid)wid=(CGWindowID)[NSWindow windowNumberAtPoint:NSMakePoint(point.x,screenTop()-point.y) belowWindowWithWindowNumber:0];
    LiveSource *source=[self nativeSource:wid at:point];BOOL replica=NO;
    if(!source)for(DesktopView *view in self.views)if((CGWindowID)view.window.windowNumber==wid){
        NSNumber *output=[view outputAt:point];NSDictionary *hit=output?[view hit:point output:output]:nil;LiveSource *candidate=self.sources[hit[@"window"]];
        BOOL covered=self.native&&down&&[self.nativeViews requiresPlacementAdmissionForWindow:candidate.logical];
        if(candidate&&(covered||!self.native||[self.nativeViews replica:candidate.logical output:output])
            &&(covered||(candidate.pixels&&!candidate.error))&&!candidate.detached){source=candidate;replica=YES;break;}
    }
    if(!source)return DWNativeTitleRefused(self.routingEarlyNativeTitle,"native_source",nil,wid,point,nil);
    // The session-stage copy may only install a title grab. Coverage refusal
    // and ordinary input policies remain at the annotated destination tap.
    if(self.routingEarlyNativeTitle){
        if(replica)return DWNativeTitleRefused(YES,"replica",source.logical,wid,point,nil);
        if(wid!=source.router.wid)return DWNativeTitleRefused(YES,"child",source.logical,wid,point,@{@"root_wid":@(source.router.wid)});
        if([self.nativeViews requiresPlacementAdmissionForWindow:source.logical])return DWNativeTitleRefused(YES,"placement_coverage",source.logical,wid,point,nil);
    }
    if(self.native&&down&&[self.nativeViews requiresPlacementAdmissionForWindow:source.logical]){
        // Even a cancelled transfer with no eligible recovery token still has
        // coverage. Its physically addressed root/member must get no down.
        pid_t expected=replica?getpid():source.router.pid;
        BOOL addressedCanvas=replica&&CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent)==wid
            &&CGEventGetIntegerValueField(cg,kCGEventTargetUnixProcessID)==getpid();
        // Refusing an already addressed canvas packet grants no input. A later
        // hit mismatch must not send this down into its captured forwarder.
        if(!addressedCanvas){NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);
            if(recipient){
                if([recipient[@"wid"]unsignedIntValue]!=wid||[recipient[@"pid"]intValue]!=expected
                    ||(!replica&&(![recipient[@"birth_sec"]isEqual:source.identity[@"birth_sec"]]
                        ||![recipient[@"birth_usec"]isEqual:source.identity[@"birth_usec"]])))return NO;
            }else if(CGEventGetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent)!=wid
                ||CGEventGetIntegerValueField(cg,kCGEventTargetUnixProcessID)!=expected)return NO;
        }
        [self cancelNativeHoverForWindow:source.logical];return YES;
    }
    if(self.native&&down&&!replica){
        DWNativeAppliedPlacement *placement=[self.nativeViews admittedPlacementForWindow:source.logical];
        if(placement){DWNativeViewTransfer *transfer=[self.nativeViews currentTransferForWindow:source.logical];
            NSDictionary *recipient=DWNativeEventRecipientAtPoint(point),*identity=nil;
            for(NSDictionary *member in placement.members)if([member[@"identity"][@"wid"]unsignedIntValue]==wid){identity=member[@"identity"];break;}
            const char *refused=NULL;
            if([recipient[@"wid"]unsignedIntValue]!=wid||!boundIdentity(recipient,identity))refused="placement_recipient";
            else if(![self.nativeViews isAdmissionCurrentForTransfer:transfer placement:placement])refused="placement_admission_before";
            else if(!DWNativeValidateAppliedPlacementInput(self.native,placement,recipient,point,NULL))refused="placement_input";
            else if(![self.nativeViews isAdmissionCurrentForTransfer:transfer placement:placement])refused="placement_admission_after";
            if(refused){DWNativeTitleRefused(self.routingEarlyNativeTitle,refused,source.logical,wid,point,@{@"recipient_wid":recipient[@"wid"]?:NSNull.null,@"recipient_pid":recipient[@"pid"]?:NSNull.null});return !self.routingEarlyNativeTitle;}
        }
    }
    for(DesktopView *view in self.views){
        if(!CGRectContainsPoint(view.globalBounds,point))continue;
        NSNumber *output=[view outputAt:point];if(!output)return DWNativeTitleRefused(self.routingEarlyNativeTitle,"output",source.logical,wid,point,nil);
        NSDictionary *hit=asDict([view hit:point output:output]),*familyHit=nil;
        if(!replica&&wid!=source.router.wid){
            NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
            for(NSDictionary *placement in snapshot[@"placements"])if([placement[@"window"]isEqual:source.logical]&&[placement[@"output"]isEqual:output]){
                NSMutableDictionary *context=[@{@"window":source.logical}mutableCopy];for(NSString *flag in @[@"widget",@"pinned"])if([placement[flag]boolValue])context[flag]=@YES;
                familyHit=DWPickHit(context,snapshot,output);hit=familyHit;break;
            }
        }
        if(![hit[@"window"]isEqual:source.logical])return DWNativeTitleRefused(self.routingEarlyNativeTitle,"controller_hit",source.logical,wid,point,@{@"output":output,@"hit_window":hit[@"window"]?:NSNull.null,@"hit_present":@(hit!=nil)});
        BOOL pick=[hit[@"pick"]isEqual:@YES],claimed=pick;
        if(down){
            if(captured||view.gesture)return DWNativeTitleRefused(self.routingEarlyNativeTitle,"existing_gesture",source.logical,wid,point,@{@"captured":@(captured!=nil),@"view_gesture":@(view.gesture)});
            NSArray *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];
            NSDictionary *binding=button>=0&&button<(NSInteger)triggers.count?[self mouseBinding:triggers[button] source:nil flags:event.modifierFlags window:YES under:source.logical pick:pick]:nil;
            if(self.routingEarlyNativeTitle){
                const char *refused=NULL;
                if(pick)refused="pick";else if(replica)refused="replica";else if(binding)refused="binding";
                else if([hit[@"widget"]boolValue])refused="widget";else if(hit[@"native_member"])refused="native_member";
                else if([view resizeBorderForButton:button flags:event.modifierFlags hit:hit at:point output:output])refused="resize_border";
                if(refused)return DWNativeTitleRefused(YES,refused,source.logical,wid,point,@{@"output":output,@"binding_kind":binding[@"kind"]?:NSNull.null});
            }
            if(replica&&[self queuedNativeHoverPress:event source:source hit:hit view:view output:output at:point]){
                [self cancelNativeHoverForWindow:source.logical];return YES;
            }
            NSEventModifierFlags extra=event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagShift);
            if(!self.routingEarlyNativeTitle&&button==0&&!extra&&!pick&&!hit[@"native_member"]&&![hit[@"widget"]boolValue]&&(replica?[self replicaGreen:source at:point output:output]:(wid==source.router.wid&&[self nativeGreen:source at:point]))){
                NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
                for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:source.logical]){NSDictionary *binding=asDict(window[@"source"]);
                    if(!boundIdentity(source.identity,binding[@"identity"]))return NO;
                    self.nativeDecorationPress=@{@"window":source.logical,@"output":output,@"identity":binding[@"identity"],@"generation":binding[@"generation"],@"action":(event.modifierFlags&NSEventModifierFlagOption)?@"fit":@"fullscreen",@"start":pointJSON(point),@"replica":@(replica)};
                    self.nativeGestureView=view;self.nativeGestureButton=button;return YES;
                }
            }
            if(!self.routingEarlyNativeTitle)[self refreshNativeButtons:source];
            if(replica)return NO; // Canvas view owns ordinary replica input and bound gestures.
            NSString *kind=asString(binding[@"kind"]);
            claimed|=[@[@"pan_viewport",@"move_window",@"move_snapped_windows",@"resize_window",@"resize_window_snapped",@"center_nearest",@"action"]containsObject:kind?:@""];
            if([hit[@"widget"]boolValue]&&([kind hasPrefix:@"move_"]||[kind hasPrefix:@"resize_"]))claimed=NO;
            // AppKit's own resize uses unscaled native coordinates. A transformed
            // root's normal edge press must enter the same pointer-anchored
            // transaction as the canvas, before the app owns its button pair.
            // Family members keep their independent native controls and drags.
            if(!self.routingEarlyNativeTitle&&wid==source.router.wid&&[view resizeBorderForButton:button flags:event.modifierFlags hit:hit at:point output:output])claimed=YES;
            // No late title fallback: annotation follows native chrome tracking.
            BOOL titleCandidate=self.routingEarlyNativeTitle&&!claimed&&!binding&&button==0&&!replica&&wid==source.router.wid&&!pick
                &&![hit[@"widget"]boolValue]&&!hit[@"native_member"]
                &&!(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift));
            BOOL titleHit=titleCandidate&&DWNativeWindowDragHit(source.identity,source.nativeButtons,point);
            if(DWInputTrace()&&titleCandidate)fprintf(stderr,"debug: native title window=#%s cached=%d age_ms=%.1f region=%d hit=%d reason=%s\n",source.logical.description.UTF8String,source.nativeButtons!=nil,source.nativeButtons?(CACurrentMediaTime()-[source.nativeButtons[@"sampled_at"]doubleValue])*1000:-1,asDict(source.nativeButtons[@"title"][@"region"])!=nil,titleHit,asString(source.nativeButtons[@"title_reason"]).UTF8String?:"no_current_report");
            if(titleHit){
                NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*current=nil;
                for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:source.logical]){current=asDict(window[@"source"]);break;}
                // A recognized region is never given back as half an AppKit
                // drag, including a binding which changed before installation.
                self.nativeGestureView=view;self.nativeGestureButton=button;
                if(!boundIdentity(source.identity,current[@"identity"])||!current[@"generation"]
                    ||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:output])return YES;
                if(event.clickCount==2){
                    self.nativeDecorationPress=@{@"window":source.logical,@"output":output,@"identity":current[@"identity"],@"generation":current[@"generation"],@"action":@"fullscreen",@"start":pointJSON(point),@"replica":@NO,@"title":@YES};
                    return YES;
                }
                view.nativeTitlePress=@{@"window":source.logical,@"output":output,@"identity":current[@"identity"],@"generation":current[@"generation"]};
                view.nativeTitleMoved=view.nativeTitleReleased=NO;
                claimed=YES;
            }
            if(!claimed)return NO;
            self.nativeGestureView=view;self.nativeGestureButton=button;
        }else{
            NSDictionary *binding=[self mouseBinding:@"scroll" source:event.hasPreciseScrollingDeltas?@"finger":@"wheel" flags:event.modifierFlags window:YES under:source.logical pick:pick];
            NSString *kind=asString(binding[@"kind"]);claimed|=[kind isEqual:@"pan_viewport"]||[kind isEqual:@"zoom"];
            if(!event.hasPreciseScrollingDeltas){
                int64_t lines=CGEventGetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis1);
                if(!lines&&(event.modifierFlags&NSEventModifierFlagShift))lines=CGEventGetIntegerValueField(cg,kCGScrollWheelEventDeltaAxis2);
                if(lines)claimed|=[asString([self mouseBinding:lines>0?@"wheel_up":@"wheel_down" source:nil flags:event.modifierFlags window:YES under:source.logical pick:pick][@"kind"])isEqual:@"action"];
            }
            if(!claimed)return NO;
            if(event.hasPreciseScrollingDeltas&&event.phase!=NSEventPhaseNone){self.nativeScrollView=view;self.nativeScrollTime=event.timestamp;}
        }
        [self deliverNative:event type:type view:view at:point familyHit:familyHit];return YES;
    }
    return DWNativeTitleRefused(self.routingEarlyNativeTitle,"view_bounds",source.logical,wid,point,nil);
}
- (instancetype)init {
    if((self=[super init])){_controller=driftwm_desktop_create();_panels=[NSMutableArray array];_views=[NSMutableArray array];_sources=[NSMutableDictionary dictionary];_choices=[NSMutableArray array];_pendingStops=[NSMutableArray array];_postingTags=[NSMutableSet set];_statusText=helpText;
        __weak Desktop *weak=self;_panLaunch=[[DWPanLaunch alloc]initWithLaunch:^(NSNumber *output){[weak panEnd:output];}];}
    return self;
}
- (void)configureResize {
    if(self.resize||![self resizes])return;
    __weak Desktop *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.resize",DISPATCH_QUEUE_SERIAL);
    DWNativeResizeDriver *driver=[DWNativeResizeDriver new];self.nativeResizeDriver=driver;
    driver.nativeFill=self.nativeDesktopMode&&self.native!=nil;
    driver.canPerform=^BOOL(NSDictionary *effect){
        Desktop *d=weak;LiveSource *source=d.sources[effect[@"window"]];
        if(!source||source.detached||source.nativeMouseOwnership||!boundIdentity(source.identity,effect[@"identity"]))return NO;
        if([effect[@"op"]isEqual:@"resize_native_window"]&&(source.nativeVisibilityWanted||source.nativeVisibilityWriting||source.nativeMinimized))return NO;
        // A worker may start after a newer handoff replaced its prepared read.
        // Only the controller's still-pending effect can enter native code.
        return [asDict([d call:@{@"op":@"snapshot"}][@"native_resize"])[@"pending_effect"]isEqual:effect];
    };
    driver.fillReady=^DWNativeFillReadiness(NSDictionary *effect){
        Desktop *d=weak;NSDictionary *held=d.nativeFillHandoff;
        if(!held||d.nativeFillResuming||d.cleaning||d.sessionInactive||d.native.ended
            ||![held[@"transaction"]isEqual:effect[@"transaction"]]||![held[@"generation"]isEqual:effect[@"generation"]]
            ||!boundIdentity(held[@"identity"],effect[@"identity"]))return DWNativeFillPending;
        if(![d nativeFillCurrent:held snapshot:[d call:@{@"op":@"snapshot"}]])return DWNativeFillPending;
        if([held[@"bridge_failed"]boolValue])return DWNativeFillUnsupportedGeometry;
        if(d.nativeFillRoot)return [d.native isTransitionHidden:d.nativeFillRoot]?DWNativeFillReadyForSnapshotFill:DWNativeFillPending;
        if(![d.native isWindowWithheld:held[@"identity"]])return DWNativeFillPending;
        // Fresh native/displayed geometry separates an aligned source, a
        // translation-only rebase, and unsupported scaling. Missing evidence
        // remains pending rather than authorizing an ordinary resize.
        NSDictionary *who=held[@"identity"];LiveSource *source=d.sources[held[@"window"]];
        if(!source||source.detached||!boundIdentity(source.identity,who))return DWNativeFillPending;
        DWFocusIdentity target={.pid=[who[@"pid"]intValue],.window=[who[@"wid"]unsignedIntValue],.seconds=[who[@"birth_sec"]unsignedLongLongValue],.microseconds=[who[@"birth_usec"]unsignedLongLongValue]};
        CGRect native,displayed,after;
        if(!dw_focus_owner(target,&native))return DWNativeFillPending;
        NSDictionary *row=windowInfo(target.window);
        if([row[(id)kCGWindowOwnerPID]intValue]!=target.pid||!row[(id)kCGWindowBounds]
            ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)
            ||!isfinite(displayed.origin.x)||!isfinite(displayed.origin.y)||!isfinite(displayed.size.width)||!isfinite(displayed.size.height)
            ||displayed.size.width<=0||displayed.size.height<=0||!dw_focus_owner(target,&after)||!CGRectEqualToRect(native,after))return DWNativeFillPending;
        BOOL aligned=fabs(native.origin.x-displayed.origin.x)<=1&&fabs(native.origin.y-displayed.origin.y)<=1
            &&fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;
        NSMutableDictionary *fresh=[held mutableCopy];fresh[@"native_baseline"]=rectJSON(native);fresh[@"displayed_baseline"]=rectJSON(displayed);d.nativeFillHandoff=fresh.copy;
        if(DWInputTrace())fprintf(stderr,"debug: native fill geometry window=#%s native=%g,%g %gx%g displayed=%g,%g %gx%g supported=%d\n",[held[@"window"]description].UTF8String,native.origin.x,native.origin.y,native.size.width,native.size.height,displayed.origin.x,displayed.origin.y,displayed.size.width,displayed.size.height,aligned);
        BOOL sameExtent=fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;
        return aligned?DWNativeFillReady:(sameExtent&&[d.native canRebaseWindow:who]?DWNativeFillNeedsRebase:DWNativeFillUnsupportedGeometry);
    };
    driver.restoreReady=^DWNativeFillReadiness(NSDictionary *effect){Desktop *d=weak;NSDictionary *held=d.nativeFillHandoff;
        if([d.nativeFillRefusedTransactions containsObject:effect[@"transaction"]]||[d.nativeRestoreDeferred[@"effect"][@"transaction"]isEqual:effect[@"transaction"]])return DWNativeFillPending;
        if(!held)return DWNativeFillUnsupportedGeometry;
        if(d.nativeFillResuming||d.cleaning||d.sessionInactive||d.native.ended
            ||![held[@"transaction"]isEqual:effect[@"transaction"]]||![held[@"generation"]isEqual:effect[@"generation"]]
            ||!boundIdentity(held[@"identity"],effect[@"identity"]))return DWNativeFillPending;
        if(![d nativeFillCurrent:held snapshot:[d call:@{@"op":@"snapshot"}]])return DWNativeFillPending;
        if([held[@"bridge_failed"]boolValue]||!d.nativeFillRoot)return DWNativeFillUnsupportedGeometry;
        // Keep the root hidden while qualified Restore clears AppKit's Fill
        // state, then corrects the exact saved frame after native settlement.
        // A frame setter alone leaves Fill active across display changes.
        return [d.native isTransitionHidden:d.nativeFillRoot]?DWNativeFillReady:DWNativeFillPending;
    };
    driver.screenUpdates=^CGError(BOOL enabled){return DWNativeScreenUpdates(enabled);};
    driver.fillRebase=^DWNativeFillRebase *(NSDictionary *effect){
        Desktop *d=weak;NSDictionary *held=d.nativeFillHandoff,*who=held[@"identity"];
        BOOL (^valid)(void)=^BOOL{Desktop *current=weak;NSDictionary *now=current.nativeFillHandoff;LiveSource *source=current.sources[effect[@"window"]];
            return current&&!current.cleaning&&!current.sessionInactive&&!current.nativeFillResuming&&!current.native.ended
                &&[now[@"transaction"]isEqual:effect[@"transaction"]]&&[now[@"generation"]isEqual:effect[@"generation"]]
                &&boundIdentity(now[@"identity"],effect[@"identity"])&&source&&!source.detached&&boundIdentity(source.identity,who)
                &&[current nativeFillCurrent:now snapshot:[current call:@{@"op":@"snapshot"}]];};
        BOOL current=valid(),canRebase=current&&[d.native canRebaseWindow:who];
        if(!current||!canRebase||!held[@"native_baseline"]||!held[@"displayed_baseline"]){
            if(DWInputTrace())fprintf(stderr,"debug: native fill rebase refused window=#%s current=%d can_rebase=%d baselines=%d\n",[effect[@"window"]description].UTF8String,current,canRebase,held[@"native_baseline"]!=nil&&held[@"displayed_baseline"]!=nil);
            return nil;
        }
        // Re-audit the known root-only scope before taking an update hold.
        NSString *familyWhy=nil;NSDictionary *family=DWNativeWindowFamily(who,&familyWhy);
        if([family[@"members"]count]!=1){
            if(DWInputTrace())fprintf(stderr,"debug: native fill rebase refused window=#%s family_members=%lu reason=%s\n",[effect[@"window"]description].UTF8String,(unsigned long)[family[@"members"]count],familyWhy.UTF8String?:"family_not_root_only");
            return nil;
        }
        DWNativeFillRebase *plan=[DWNativeFillRebase new];plan.native=jsonRect(held[@"native_baseline"]);plan.displayed=jsonRect(held[@"displayed_baseline"]);
        plan.publish=^BOOL(CGRect observed,BOOL (^authorized)(void)){Desktop *current=weak;if(!valid())return NO;
            NSDictionary *freshFamily=DWNativeWindowFamily(who,NULL);if([freshFamily[@"members"]count]!=1||!authorized())return NO;
            if(![current.native rebaseWindow:who bounds:observed])return NO;
            current.sources[effect[@"window"]].router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observed));
            [current render];return YES;};
        plan.ready=^BOOL{Desktop *current=weak;if(!valid())return NO;[current render];
            if(![current.native isWindowRebased:who])return NO;
            DWFocusIdentity target={.pid=[who[@"pid"]intValue],.window=[who[@"wid"]unsignedIntValue],.seconds=[who[@"birth_sec"]unsignedLongLongValue],.microseconds=[who[@"birth_usec"]unsignedLongLongValue]};
            CGRect native,displayed,after;NSDictionary *row=windowInfo(target.window);
            return dw_focus_owner(target,&native)&&[row[(id)kCGWindowOwnerPID]intValue]==target.pid&&row[(id)kCGWindowBounds]
                &&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&displayed)
                &&dw_focus_owner(target,&after)&&CGRectEqualToRect(native,after)
                &&fabs(native.origin.x-displayed.origin.x)<=1&&fabs(native.origin.y-displayed.origin.y)<=1
                &&fabs(native.size.width-displayed.size.width)<=1&&fabs(native.size.height-displayed.size.height)<=1;};
        plan.cancel=^{Desktop *current=weak;if(valid()){[current.native cancelRebaseWindow:who];[current render];}};
        return plan;
    };
    // On the worker queue. The process named is the effect's, which the controller built from a source -attach: bound.
    if(DWInputTrace())driver.didPerform=^(NSDictionary *e,NSDictionary *r){NSDictionary *i=e[@"identity"],*asked=asDict(e[@"requested"]),*actual=r[@"actual_ax"][@"size"];
        fprintf(stderr,"debug: native %s pid=%d wid=%u requested=%gx%g outcome=%s observed=%d actual=%gx%g moved=%d ax_error=%d attempted=%d transaction=%llu effect=%llu\n",asString(r[@"method"]).UTF8String?:"size read",[i[@"pid"]intValue],[i[@"wid"]unsignedIntValue],[asked[@"width"]doubleValue],[asked[@"height"]doubleValue],[r[@"outcome"]description].UTF8String,[r[@"observed"]boolValue],[actual[@"width"]doubleValue],[actual[@"height"]doubleValue],[r[@"moved"]boolValue],[r[@"ax_error"]intValue],[r[@"mutation_attempted"]boolValue],[e[@"transaction"]unsignedLongLongValue],[e[@"effect_id"]unsignedLongLongValue]);};
    self.resize=[[DWResizeCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak resizeCall:c];} driver:driver worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.resize.enabled=YES;

    // Native readback (crates/desktop/NATIVE_RESIZE.md): the size a window took is read back from it, no capture is acknowledged, no
    // picture is cleared. App-owned Fill separately holds placement/input until
    // its native animation and a fresh helper ACK settle. An effect unanswered after three seconds is reported as timed out, which ends its
    // transaction. When a transaction has ended, the window is looked at as the poll looks at it: its bounds, its stream's size
    // and the controller's observation follow the size it has, or it is found closed. Then the scene is saved, once.
    self.resize.timeout=3;
    // A resize grab whose pointer rests owes no effect and is no orphan: its press, or its swipe, ends it (-released:at:, gesture_end),
    // and a press or swipe whose end is lost is ended by -endLostInput.
    self.resize.deferred=^BOOL(NSDictionary *effect){Desktop *d=weak;NSDictionary *deferred=d.nativeRestoreDeferred;
        return [deferred[@"effect"]isEqual:effect]&&[d nativeRestoreDeferredCurrent:deferred snapshot:[d call:@{@"op":@"snapshot"}]];};
    self.resize.held=^BOOL(NSNumber *transaction){Desktop *d=weak;for(DesktopView *view in d.views)if(view.gesture==4&&[view.resizeTransaction isEqual:transaction])return YES;return d.gestureOwner&&d.gestureResize;};
    self.resize.changed=^{Desktop *d=weak;if(d.cleaning)return;if(d.resize.failure)d.statusText=d.resize.failure;
        NSDictionary *transaction=asDict([d call:@{@"op":@"snapshot"}][@"native_resize"]);
        if(transaction&&[d.resize canRemove:nil]&&!d.resize.obligations&&![d.resizeSavedTransaction isEqual:transaction[@"transaction"]]){d.resizeSavedTransaction=transaction[@"transaction"];
            if(DWInputTrace())fprintf(stderr,"debug: size transaction %s of #%s ended phase=%s\n",[transaction[@"transaction"]description].UTF8String,[transaction[@"window"]description].UTF8String,asString(transaction[@"phase"]).UTF8String?:"?");
            LiveSource *source=d.sources[transaction[@"window"]];if(source&&!source.detached)[d track:source];[d saveScene];}
        [d updateNativeFill];[d render];};
    if(self.configured)[self resizeCapability];
}
// Every normal run performs readback size effects; demo and probe runs do not.
- (BOOL)resizes { return !(self.demo||self.probe); }
// native_resize_capability: DriftWM's sizing actions, the IPC resize write, a rule's size and fullscreen reach a native window through
// the resize coordinator, which every normal run has. main() says so before the config is read, since the binding table marks the
// actions that run here and a chord whose action does not is never registered; the coordinator's creation says so again, after the
// scene load, which rebuilds the controller. A size is settled by the native read alone (crates/desktop/NATIVE_RESIZE.md).
- (void)resizeCapability {
    if(![self resizes])return;
    NSString *status=self.statusText;
    if(![self call:@{@"op":@"native_resize_capability",@"enabled":@YES}]){fprintf(stderr,"native_resize_capability: %s\n",self.statusText.UTF8String);self.statusText=status;}
}
// Is the resize transaction on record one a sizing action began, and certain? That one is the controller's: an action or an IPC
// request that arrives while it runs reaches the controller, which continues, coalesces or refuses it as upstream does for a
// window that still owes a configure. A resize the pointer began holds the canvas until it settles, as does every uncertain one.
- (BOOL)sizing {
    if(!self.resize||!self.sizeTransaction)return NO;
    NSDictionary *transaction=asDict([self call:@{@"op":@"snapshot"}][@"native_resize"]);
    return [transaction[@"transaction"]isEqual:self.sizeTransaction]&&![transaction[@"uncertain_mutation"]boolValue];
}
// The resize coordinator's commands. The native result of a sizing action's transaction is answered with that action's
// continuation: upstream's placement, camera and restore point for the size the window took, or why it took none. The reply
// then gets the tail of an action's reply, on a later turn of the main queue, once the coordinator has consumed its next effect.
// A result that ends its transaction, a pointer resize's included, can be answered with the first effect of another one: the size
// transaction of the next window whose rule's size is still owed (RULES.md), which may be waiting behind a fullscreen's enter or
// exit as behind any other. The coordinator performs it as it performs every effect a result reply carries; here the transaction
// it names becomes the one -sizing knows as the controller's own, like the one an attach reply begins, so that a press or an
// action does not cancel it and a msg request is not turned away for it. The effect that answers one of the controller's own
// results inside the same transaction is the controller's too, and needs nothing: a fullscreen that is left before the window has
// taken the output's size asks for the old size on the transaction it already has (FULLSCREEN.md), which -sizing still names.
- (NSDictionary *)resizeCall:(NSDictionary *)command {
    NSDictionary *reply=[self call:command];
    if(!reply||![command[@"op"]isEqual:@"native_resize_result"])return reply;
    NSDictionary *result=asDict(command[@"result"]);
    if(self.native&&[result[@"observed"]boolValue]){
        // Tracking skips a held resize grab. Refresh its native transform basis
        // at this accepted completion, before consume: can render or queue another
        // effect. The router and presenter have separate caches; always bind the
        // accepted observation, once per readback, even if the router is current.
        for(NSDictionary *window in [self call:@{@"op":@"snapshot"}][@"windows"]){
            NSDictionary *source=asDict(window[@"source"]);LiveSource *live=self.sources[window[@"window"]];
            if(!live||live.detached||!boundIdentity(live.identity,command[@"identity"])||!boundIdentity(live.identity,source[@"identity"])||![source[@"generation"]isEqual:command[@"generation"]]||![source[@"observation_known"]boolValue])continue;
            CGRect observed=jsonRect(source[@"observed_rect"]),prior=CGRectZero;
            if(!CGRectEqualToRect(observed,jsonRect(result[@"actual_ax"])))break;
            if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)live.router.bounds,&prior)||!CGRectEqualToRect(prior,observed))live.router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observed));
            [self.native bound:live.identity bounds:observed];break;
        }
    }
    BOOL own=self.sizeTransaction&&[command[@"transaction"]isEqual:self.sizeTransaction];
    NSNumber *next=asNumber(sizeEffect(reply)[@"transaction"]);if(next&&![next isEqual:command[@"transaction"]])self.sizeTransaction=next;
    if(!own)return reply;
    NSMutableDictionary *tail=[reply mutableCopy];[tail removeObjectForKey:@"effect"];__weak Desktop *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(!d||d.cleaning)return;NSString *failure=asString(tail[@"failure"]);if(failure)[d flashStatus:[@"Window not resized: " stringByAppendingString:failure]];[d applyReply:tail];});
    return reply;
}
// The navigation coordinator's commands. An activation the user made natively may leave fullscreen, as upstream exits before it
// activates another window of that output: the size transaction that takes the window back comes with the focus request and is
// the resize coordinator's to perform, like any other. The coordinator reads "effect" as a focus request, so a size
// transaction's is taken out of what it is handed, as in -applyReply:; no reply of its commands carried one before fullscreen.
- (NSDictionary *)navigationCall:(NSDictionary *)command {
    NSDictionary *reply=[self call:command],*sized=[self consumeSize:reply];if(!sized||reply[@"effect"]!=sized)return reply;
    NSMutableDictionary *rest=[reply mutableCopy];[rest removeObjectForKey:@"effect"];return rest;
}
// Every normal run: the coordinator ticks camera flights, performs the controller's focus
// requests on native windows and follows native focus the user moved. Probe, demo and
// owned-fixture runs have none and keep their fixed click activation.
- (void)configureNavigation {
    if(!self.configured||self.navigation)return;
    __weak Desktop *weak=self;dispatch_queue_t queue=dispatch_queue_create("org.infinify.navigation",DISPATCH_QUEUE_SERIAL);
    self.navigation=[[DWNavigationCoordinator alloc]initWithCommand:^NSDictionary *(NSDictionary *c){return [weak navigationCall:c];} driver:[DWNativeFocusDriver new] clock:^uint64_t{return (uint64_t)(CACurrentMediaTime()*1e9);} worker:^(DWJob job){dispatch_async(queue,job);} main:^(DWJob job){dispatch_async(dispatch_get_main_queue(),job);}];
    self.navigation.enabled=YES;self.cycleHold=[DWCycleHold new];
    self.navigation.changed=^{[weak render];[weak ensureFrames];};
    self.navigation.settled=^{[weak saveScene];};
    self.navigation.output=^NSNumber *{return [weak viewOutput];};
    self.navigation.nativeClickReleaseReady=^BOOL(NSDictionary *click){
        Desktop *d=weak;LiveSource *source=d.sources[click[@"window"]];
        if(!d||d.cleaning||d.sessionInactive||d.native.ended||!source||source.detached||source.nativeMouseOwnership
            ||!boundIdentity(source.identity,click[@"identity"])||![[d.nativeViews desiredOwnerForWindow:source.logical]isEqual:click[@"output"]])return NO;
        DWNativeAppliedPlacement *placed=[d.native acknowledgedPlacementForWindow:click[@"window"] identity:click[@"identity"] generation:click[@"generation"] output:click[@"output"]];
        return placed&&[d.native isAcknowledgedPlacementCurrent:placed];
    };
    self.navigation.observationBinding=^DWObservedBinding{
        Desktop *d=weak;if(!d||d.cleaning||d.native.ended||(d.native&&!d.native.familiesNeeded))return nil;
        NSMutableArray *roots=[NSMutableArray array];NSDictionary *snapshot=[d call:@{@"op":@"snapshot"}];
        for(NSDictionary *window in snapshot[@"windows"]){NSDictionary *source=asDict(window[@"source"]),*identity=asDict(source[@"identity"]);LiveSource *live=d.sources[window[@"window"]];
            if(!live||live.detached||!identity||!boundIdentity(live.identity,identity))continue;
            [roots addObject:@{@"window":window[@"window"],@"identity":[identity copy],@"generation":source[@"generation"]}];
        }
        NSArray *bindings=roots.copy;
        return ^NSDictionary *(NSDictionary *actual){
            for(NSDictionary *binding in bindings){NSDictionary *root=binding[@"identity"];BOOL same=YES;
                for(NSString *key in @[@"pid",@"birth_sec",@"birth_usec"])if(![actual[key]isEqual:root[key]])same=NO;
                if(same&&![actual[@"wid"]isEqual:root[@"wid"]]&&DWNativeWindowBelongsToRoot(actual,root))return binding;
            }
            return nil;
        };
    };
    [self refreshFocusAccess];
    // Never asked for: the observer exists only where the user has already granted Input Monitoring.
    if(!self.logicalFocus&&CGPreflightListenEventAccess()){
        CGEventMask mask=CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventScrollWheel)|CGEventMaskBit(kCGEventKeyDown);
        self.navigationTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,navigationInput,(__bridge void *)self);
        if(self.navigationTap){self.navigationTapSource=CFMachPortCreateRunLoopSource(NULL,self.navigationTap,0);if(self.navigationTapSource)CFRunLoopAddSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);}
    }
    [self.navigation frame];
}
// Native focus needs Accessibility, which can be granted while the app runs, and
// --no-native-focus turns it off. Without it focus is logical and navigation still works.
- (void)refreshFocusAccess {
    BOOL trusted=AXIsProcessTrusted();self.navigation.focusAllowed=trusted&&!self.logicalFocus;[self.tapKeys trusted:trusted];
    if(trusted)[self configureNativeInput];
    if(trusted||self.logicalFocus||self.focusNoted||!self.navigation)return;
    self.focusNoted=YES;NSString *note=focusAccessNote;
    // Said once, ahead of a notice already up; what a config load left for the status line returns as the resting status.
    [self say:note];self.statusText=!self.statusText.length||[self.statusText isEqual:self.help]?note:[NSString stringWithFormat:@"%@ · %@",note,self.statusText];
}
// Stage Manager can be switched on under a canvas that is already open, from Control Centre for one. A normal run switched it off
// itself when its canvas opened and does not fight the user over it: the run goes on and says once what its windows will look like
// until it is off again, and what it put back at its end leaves it on, as the user set it. Other runs never touched the setting.
- (void)refreshStageManager {
    BOOL on=self.manager&&DWStageManagerOn();if(on&&!self.stageNoted)[self say:self.takeover.engaged?DWStageManagerBackNote:DWStageManagerNote];
    self.stageNoted=on;
}
- (void)cancelNavigation {
    [self cancelNativeTitleClick];
    [self.navigation invalidate];
    // Without the coordinator, pointer intent still stops every view-action flight.
    if(!self.navigation)for(DesktopView *view in self.views)for(NSNumber *output in view.outputs)[self call:@{@"op":@"cancel_navigation",@"output":output}];
}
- (void)stopNavigation {
    [self cancelNativeTitleClick];
    [self.cycleHold stop];self.cycleHold=nil;[self.navigation shutdown];self.navigation=nil;[self.frameDriver invalidate];self.frameDriver=nil;self.frameFlying=NO;self.flying=NO;
    if(self.navigationTapSource){CFRunLoopRemoveSource(CFRunLoopGetMain(),self.navigationTapSource,kCFRunLoopCommonModes);CFRelease(self.navigationTapSource);self.navigationTapSource=NULL;}
    if(self.navigationTap){CFMachPortInvalidate(self.navigationTap);CFRelease(self.navigationTap);self.navigationTap=NULL;}
}
// Where the pointer is: its global point, and the output it is on. It is on an output only
// where a press would reach that output's panel, so a canvas behind another window (the
// chooser, a menu, in a windowed run another application) has no pointer, and neither has
// a panel's toolbar strip. One reading for everything that asks: cursor edge pan's report
// and hover. The outputs are the last snapshot's, so nothing is asked of the controller.
- (NSNumber *)outputUnderPointer:(CGPoint)p {
    if(!self.pointerOutputs.count)return nil;
    NSInteger top=[NSWindow windowNumberAtPoint:NSMakePoint(p.x,screenTop()-p.y) belowWindowWithWindowNumber:0];
    BOOL native=[self nativeSource:(CGWindowID)top at:p]!=nil;
    for(DesktopView *view in self.views)if(view.window.windowNumber==top||native)for(NSDictionary *o in self.pointerOutputs)if([view.outputs containsObject:o[@"id"]]&&CGRectContainsPoint(jsonRect(o[@"screen_bounds"]),p))return o[@"id"];
    return nil;
}
// The pointer's part of a frame, before the tick. It is read once, and only when one of its
// two readers wants it, then handed to both in upstream's order for one motion of the
// pointer (maybe_hover_focus, then refresh_cursor_edge_pan):
// - hover: while the frame timer runs, whichever it serves (camera motion, or only an
//   animated background or a window that opens or leaves), the motion a panel's tracking area has waiting goes with the frame,
//   so a moving pointer is one hover a frame and never a timer beside this one. With no
//   frame timer an idle poll's frame carries none: pointer-hover's own timer does, see there.
// - cursor edge pan: while the controller's snapshot asks for it, where the pointer is and
//   which output it is on. The answer is the controller's to use; a refusal leaves the
//   status line alone. Nothing is reported while a panel holds a button gesture:
//   upstream's refresh stands down under any pointer grab, and the controller knows only
//   its own, not a press forwarded to a native window.
- (void)pointerFrame { [self pointerFrame:NO]; }
// moved: the report is made only if the pointer is not where it was last reported. A frame of the timer that serves no camera
// motion asks so: such frames come at the display's rate for as long as a window's pictures do, the idle poll goes on beside
// them and reports a pointer at rest at its own pace, and a call into the controller per refresh would be for nothing.
- (void)pointerFrame:(BOOL)moved {
    if(self.cleaning||self.sessionInactive||[self nativeUnavailable])return;
    BOOL report=self.pointerWanted,hover=NO;
    for(DesktopView *view in self.views){if(view.gesture)report=NO;if(self.frameDriver&&view.hover.pending)hover=YES;}
    if(!report&&!hover)return;
    CGPoint p=pointer();NSNumber *output=[self outputUnderPointer:p];
    if(hover)for(DesktopView *view in self.views.copy)[view.hover frame:p output:[view.outputs containsObject:output]?output:nil];
    if(!report||(moved&&CGPointEqualToPoint(p,self.pointerReported)))return;self.pointerReported=p;
    NSString *status=self.statusText;NSDictionary *told=[self call:@{@"op":@"pointer",@"output":output?:NSNull.null,@"screen":pointJSON(p)}];self.statusText=status;
    // The pull moved the focus: a hover's effect, performed as a hover's is (-pointerFocused:).
    if([told[@"dirty"]isEqual:@YES]){NSDictionary *effect=asDict(told[@"effect"]);[self.navigation perform:effect?@{@"effect":effect}:@{}];self.sceneDirty=YES;[self render];}
}
// One frame of camera motion: every armed flight, a coasting pan, an edge pan. A normal
// run's coordinator owns the tick; probe, demo and owned-fixture runs tick the controller
// themselves on the same clock.
- (BOOL)cameraFrame {
    if(self.cleaning||self.sessionInactive||[self nativeUnavailable])return NO;
    [self pointerFrame];
    if(self.navigation)return [self.navigation frame];
    NSDictionary *result=[self call:@{@"op":@"tick_navigation",@"timestamp_ns":@((uint64_t)(CACurrentMediaTime()*1e9))}];
    if([result[@"changed_outputs"]count])[self render];
    BOOL active=[result[@"needs_frames"]boolValue];if(!active&&self.flying)[self saveScene];self.flying=active;return active;
}
// Animated backgrounds: is one on an open panel? draw: each such output's next frame is
// drawn when its animate_fps says it is due. Never in probe, demo and owned-fixture runs.
// An open or close animation of the compositor's counts the same way and is drawn on every frame.
// So does a background chunk cache that is still filling (a baked cache_shader, a pyramidal TIFF's chunks): its output is
// given one frame a tick, each spending upstream's per-frame allowances once, until a frame leaves nothing pending.
- (BOOL)animate:(BOOL)draw { BOOL any=NO;for(DesktopView *view in self.views)if(view.window.visible&&[self.compositor animates:view.outputs draw:draw])any=YES;return any; }
// The one frame timer, at the display's refresh rate: a display link (frame-driver.h) of the
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
    NSArray *screens=[self canvasScreens];NSScreen *clockScreen=nil;
    for(NSScreen *screen in screens)if(!clockScreen||screen.maximumFramesPerSecond>clockScreen.maximumFramesPerSecond)clockScreen=screen;
    IFCompositorLayer *clockLayer=nil;
    for(DesktopView *view in self.views)if(!clockLayer&&view.window.screen==clockScreen)for(NSNumber *output in view.outputs){CALayer *layer=[self.compositor layerForOutput:output];if([layer isKindOfClass:IFCompositorLayer.class]){clockLayer=(IFCompositorLayer *)layer;break;}}
    BOOL screenBaseline=self.scope&&getenv("INFINIFY_DEBUG_BENCH")&&atoi(getenv("INFINIFY_DEBUG_BENCH"))==1&&getenv("INFINIFY_DEBUG_SCREEN_CLOCK")&&atoi(getenv("INFINIFY_DEBUG_SCREEN_CLOCK"))==1;
    BOOL metalCandidate=self.scope&&getenv("INFINIFY_DEBUG_BENCH")&&atoi(getenv("INFINIFY_DEBUG_BENCH"))==1&&getenv("INFINIFY_DEBUG_METAL_CLOCK")&&atoi(getenv("INFINIFY_DEBUG_METAL_CLOCK"))==1;
    BOOL hardwareCandidate=!screenBaseline&&self.scope&&getenv("INFINIFY_DEBUG_BENCH")&&atoi(getenv("INFINIFY_DEBUG_BENCH"))==1&&getenv("INFINIFY_DEBUG_CV_CLOCK")&&atoi(getenv("INFINIFY_DEBUG_CV_CLOCK"))==1;
    if(!metalCandidate||screenBaseline||hardwareCandidate)clockLayer=nil;
    __weak Desktop *weak=self;self.frameDriver=[DWFrameDriver driverOn:screens layer:clockLayer hardwareClock:hardwareCandidate frame:^(DWFrameDriver *driver){Desktop *desktop=weak;
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
// The compositor's question (canvas-renderer.h, `frame`): will a frame of the timer flush what has just changed? start: a
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
// Something may be in motion: a frame per display refresh from the next one on. Only the
// controller knows what is, so that frame asks it, and the timer stops serving motion when nothing is.
- (void)ensureFrames { if(self.cleaning||self.sessionInactive||[self nativeUnavailable])return;self.frameFlying=YES;[self startFrames]; }
// The end of a burst of timed pans: upstream's launch_momentum_on. The clock is brought
// up to now first, so the coast's first frame spans one frame and not the idle poll's gap.
- (void)panEnd:(NSNumber *)output {
    if(self.cleaning||[self nativeUnavailable]||!output)return;
    if(!self.frameFlying)[self cameraFrame];
    [self call:@{@"op":@"pan_end",@"output":output}];[self ensureFrames];
}
// Hot key target and the IPC active output: the output under the pointer, else the panel
// under it (a fixture panel's toolbar strip lies outside its output), else the first registered output.
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
// What the status line returns to: a config load the controller refused, or its --super chord, stays up, else why the background fell back, else the help.
// A problem in the config file itself is the error bar's alone (-loadConfig:).
- (NSString *)restingStatus { return self.configured?self.configNote?:self.backgroundNote?:self.help?:@"":helpText; }
// A normal run draws no status line. A note that would have been shown there is one line on stderr instead, and is not
// written again while it stays up: one renewed before it expired is one line. Once the status is back at rest the same
// note is news again (-render forgets it there), so two refusals a minute apart are two lines.
- (void)say:(NSString *)note { if(!note.length||[note isEqual:self.said])return;self.said=note;fprintf(stderr,"%s\n",note.UTF8String); }
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
// A reply that began a native size transaction carries its effect: a sizing action's, an IPC resize's, a fullscreen's, or the attach
// of a window whose rule names a size. It is the resize coordinator's to perform, which every normal run has; a demo or a probe has
// none, and no such reply arrives there, because the controller was never told a size can be delivered.
// The transaction the effect names is the one -sizing knows as the controller's own. Returns the effect, or nil.
- (NSDictionary *)consumeSize:(NSDictionary *)reply {
    NSDictionary *sized=sizeEffect(reply);
    if(sized){
        if(self.nativeRestoreDeferred&&![self.nativeRestoreDeferred[@"effect"]isEqual:sized])[self retireDeferredNativeRestore];
        self.sizeTransaction=asNumber(sized[@"transaction"]);
        if(![self deferNativeRestore:sized]){[self prepareNativeFill:sized];[self.resize consume:@{@"effect":sized}];}
    }
    return sized;
}
// Restore can accompany a camera flight to a different window. Keep its exact
// initial read unconsumed while that flight runs: no capture, placement hold,
// worker or native watchdog exists yet, even with a slow configured camera.
- (BOOL)deferNativeRestore:(NSDictionary *)effect {
    if(self.nativeRestoreDeferred)return [self.nativeRestoreDeferred[@"effect"]isEqual:effect];
    if(!self.nativeDesktopMode||!self.native||self.native.ended||self.cleaning||self.sessionInactive
        ||self.nativeFillHandoff||self.resize.obligations||![effect[@"op"]isEqual:@"observe_resize_source"]
        ||[self.nativeFillRefusedTransactions containsObject:effect[@"transaction"]])return NO;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*transaction=asDict(snapshot[@"native_resize"]);
    if(![transaction[@"pending_effect"]isEqual:effect]||[transaction[@"interactive"]boolValue]
        ||[transaction[@"baseline_observed"]boolValue]||[transaction[@"cancelled"]boolValue]||[transaction[@"uncertain_mutation"]boolValue])return NO;
    for(NSDictionary *view in snapshot[@"outputs"])if([asDict(view[@"fullscreen"])[@"window"]isEqual:effect[@"window"]])return NO;
    NSDictionary *prior=self.nativeFillHistory[effect[@"window"]];
    BOOL remembered=boundIdentity(prior[@"identity"],effect[@"identity"])&&[prior[@"generation"]isEqual:effect[@"generation"]];
    if(!remembered&&![self.nativeResizeDriver hasNativeFillForEffect:effect])return NO;
    LiveSource *source=self.sources[effect[@"window"]];NSNumber *output=[self.nativeViews desiredOwnerForWindow:effect[@"window"]];
    NSDictionary *view=nil;for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    NSDictionary *flight=asDict(asDict(asDict(snapshot[@"navigation"])[@"flights"])[output.stringValue]);
    NSDictionary *camera=asDict(flight[@"camera_target"]);NSNumber *zoom=asNumber(flight[@"zoom_target"]);
    if(!source||source.detached||source.nativeMouseOwnership||!view||!flight||!asNumber(flight[@"generation"])
        ||!asNumber(camera[@"x"])||!asNumber(camera[@"y"])||!isfinite([camera[@"x"]doubleValue])||!isfinite([camera[@"y"]doubleValue])
        ||!zoom||!isfinite(zoom.doubleValue)||zoom.doubleValue<=0)return NO;
    // Presenter receipts use the shell's four-field bound identity. The
    // unchanged controller effect additionally serializes owner:null.
    NSDictionary *deferred=@{@"effect":effect.copy,@"identity":source.identity.copy,@"transaction_state":transaction.copy,@"presenter":self.native,
        @"session":@(self.nativeSessionEpoch),@"output":output,@"screen_bounds":view[@"screen_bounds"],
        @"flight_generation":flight[@"generation"],@"camera":camera.copy,@"zoom":zoom};
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:snapshot])return NO;
    self.nativeRestoreDeferred=deferred;
    if(DWInputTrace())fprintf(stderr,"debug: native restore deferred window=#%s transaction=%llu flight=%llu\n",[effect[@"window"]description].UTF8String,[effect[@"transaction"]unsignedLongLongValue],[flight[@"generation"]unsignedLongLongValue]);
    return YES;
}
- (BOOL)nativeRestoreDeferredCurrent:(NSDictionary *)deferred snapshot:(NSDictionary *)snapshot {
    NSDictionary *effect=deferred[@"effect"];LiveSource *source=self.sources[effect[@"window"]];
    if(!deferred||self.cleaning||stopped||self.sessionInactive||self.native.ended||deferred[@"presenter"]!=self.native
        ||[deferred[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch||!source||source.detached||source.nativeMouseOwnership
        ||source.nativeVisibilityWanted||![source.identity isEqual:deferred[@"identity"]]||!boundIdentity(source.identity,effect[@"identity"])
        ||![asDict(snapshot[@"native_resize"])isEqual:deferred[@"transaction_state"]])return NO;
    NSDictionary *binding=nil,*view=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:effect[@"window"]]){binding=asDict(row[@"source"]);break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:deferred[@"output"]]){view=row;break;}
    if(!boundIdentity(binding[@"identity"],effect[@"identity"])||![binding[@"generation"]isEqual:effect[@"generation"]]
        ||![[self.nativeViews desiredOwnerForWindow:effect[@"window"]]isEqual:deferred[@"output"]]
        ||![view[@"screen_bounds"]isEqual:deferred[@"screen_bounds"]])return NO;
    NSDictionary *flight=asDict(asDict(asDict(snapshot[@"navigation"])[@"flights"])[[deferred[@"output"]description]]);
    if(flight)return [flight[@"generation"]isEqual:deferred[@"flight_generation"]];
    return [view[@"camera"]isEqual:deferred[@"camera"]]&&[view[@"zoom"]isEqual:deferred[@"zoom"]]
        &&(!deferred[@"ready_deadline"]||CACurrentMediaTime()<[deferred[@"ready_deadline"]doubleValue]);
}
- (void)retireDeferredNativeRestore {
    NSDictionary *deferred=self.nativeRestoreDeferred;if(!deferred)return;
    self.nativeRestoreDeferred=nil; // finish can synchronously render/notify.
    NSDictionary *effect=deferred[@"effect"];
    if(!self.nativeFillRefusedTransactions)self.nativeFillRefusedTransactions=[NSMutableSet set];
    [self.nativeFillRefusedTransactions addObject:effect[@"transaction"]];
    if(DWInputTrace())fprintf(stderr,"debug: native restore deferral retired window=#%s transaction=%llu\n",[effect[@"window"]description].UTF8String,[effect[@"transaction"]unsignedLongLongValue]);
    [self.resize discardDeferredEffect:effect];
}
- (void)updateDeferredNativeRestore {
    NSDictionary *deferred=self.nativeRestoreDeferred;if(!deferred)return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:snapshot]){[self retireDeferredNativeRestore];return;}
    if(asDict(asDict(asDict(snapshot[@"navigation"])[@"flights"])[[deferred[@"output"]description]]))return;
    // Only the existing preparation allowance starts after the valid flight
    // lands. A missing helper ACK cannot keep a dead resize slot indefinitely.
    if(!deferred[@"ready_deadline"]){NSMutableDictionary *waiting=[deferred mutableCopy];waiting[@"ready_deadline"]=@(CACurrentMediaTime()+2.25);self.nativeRestoreDeferred=deferred=waiting.copy;}
    NSDictionary *effect=deferred[@"effect"],*placement=nil;
    for(NSDictionary *item in [self presentationSnapshot][@"placements"])if([item[@"window"]isEqual:effect[@"window"]]&&[item[@"output"]isEqual:deferred[@"output"]]){placement=item;break;}
    DWNativeAppliedPlacement *receipt=[self.native acknowledgedPlacementForWindow:effect[@"window"] identity:deferred[@"identity"] generation:effect[@"generation"] output:deferred[@"output"]];
    if(!placement||!receipt||!CGRectEqualToRect(receipt.requestedScreenRect,jsonRect(placement[@"screen_rect"]))
        ||!CGRectEqualToRect(receipt.requestedClipRect,jsonRect(placement[@"clip_rect"]))
        ||!CGRectEqualToRect(receipt.requestedViewport,jsonRect(deferred[@"screen_bounds"]))||![self.native isAcknowledgedPlacementCurrent:receipt])return;
    // presentationSnapshot may reconcile ownership. Recheck the saved action
    // after that reconciliation, before acquiring any native placement hold.
    if(![self nativeRestoreDeferredCurrent:deferred snapshot:[self call:@{@"op":@"snapshot"}]]){[self retireDeferredNativeRestore];return;}
    // Same main turn: acquire the normal capture/placement handoff, retire the
    // wait, then admit the original baseline once with ordinary deadlines.
    [self prepareNativeFill:effect];
    if(![self.nativeFillHandoff[@"transaction"]isEqual:effect[@"transaction"]])return;
    self.nativeRestoreDeferred=nil;
    if(DWInputTrace())fprintf(stderr,"debug: native restore deferral ready window=#%s transaction=%llu sequence=%llu\n",[effect[@"window"]description].UTF8String,[effect[@"transaction"]unsignedLongLongValue],(unsigned long long)receipt.sequence);
    [self.resize consume:@{@"effect":effect}];
}
// Withhold before the baseline worker starts: the logical fullscreen commit
// must not first park or jump its physical source. Only this one transaction
// owns the handoff; identity loss, cancellation and quit preserve normal restore.
- (void)clearNativeFillPresentation {
    [self retireDeferredNativeRestore];
    [self.nativeResizeDriver clearPreparedBaseline];
    // A cancelled prepared transaction must not become an unprepared fallback
    // when its already queued worker next consults readiness.
    if(self.nativeFillHandoff&&!self.nativeFillResuming){if(!self.nativeFillRefusedTransactions)self.nativeFillRefusedTransactions=[NSMutableSet set];[self.nativeFillRefusedTransactions addObject:self.nativeFillHandoff[@"transaction"]];}
    // Invalidate the callbacks before cancellation can synchronously complete.
    DWNativeTransitionCapture *capture=self.nativeFillCapture;DWNativeTransition *picture=self.nativeFillPicture;
    DWNativePresenter *presenter=self.nativeFillHandoff[@"presenter"];presenter.transitionFrameAcknowledged=nil;
    self.nativeFillHandoff=nil;self.nativeFillCapture=nil;self.nativeFillPicture=nil;self.nativeFillRoot=nil;self.nativeViewSnapshot=nil;self.nativeFillBackgroundTrace=nil;
    self.nativeFillResuming=NO;self.nativeFillHiding=NO;self.nativeFillAnimating=NO;self.nativeFillAnimated=NO;self.nativeFillRevealing=NO;self.nativeFillPresentationDeadline=0;
    self.nativeResizeDriver.fillPreparationTimeout=.75;self.resize.timeout=3;
    [capture cancel];[picture cancel];
}
- (BOOL)nativeFillCurrent:(NSDictionary *)held snapshot:(NSDictionary *)snapshot {
    LiveSource *source=self.sources[held[@"window"]];
    if(!held||self.cleaning||self.sessionInactive||self.native.ended||held[@"presenter"]!=self.native
        ||[held[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch||!source||source.detached||source.nativeVisibilityWanted||!boundIdentity(source.identity,held[@"identity"]))return NO;
    NSDictionary *binding=nil,*view=nil;
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:held[@"window"]]){binding=asDict(row[@"source"]);break;}
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:held[@"output"]]){view=row;break;}
    return boundIdentity(binding[@"identity"],held[@"identity"])&&[binding[@"generation"]isEqual:held[@"generation"]]
        &&[[self.nativeViews desiredOwnerForWindow:held[@"window"]]isEqual:held[@"output"]]
        &&[view[@"camera"]isEqual:held[@"camera"]]&&[view[@"zoom"]isEqual:held[@"zoom"]]&&[view[@"screen_bounds"]isEqual:held[@"screen_bounds"]];
}
- (void)prepareNativeFill:(NSDictionary *)effect {
    if(!self.nativeDesktopMode||!self.native||self.native.ended||self.cleaning||self.sessionInactive||self.nativeFillHandoff)return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*transaction=asDict(snapshot[@"native_resize"]);
    if(![transaction[@"transaction"]isEqual:effect[@"transaction"]]||[transaction[@"interactive"]boolValue])return;
    BOOL fullscreen=NO;for(NSDictionary *output in snapshot[@"outputs"]){NSDictionary *entry=asDict(output[@"fullscreen"]);if([entry[@"window"]isEqual:effect[@"window"]])fullscreen=YES;}
    NSDictionary *prior=self.nativeFillHistory[effect[@"window"]];
    BOOL remembered=boundIdentity(prior[@"identity"],effect[@"identity"])&&[prior[@"generation"]isEqual:effect[@"generation"]];
    BOOL restoring=!fullscreen&&([self.nativeResizeDriver hasNativeFillForEffect:effect]||remembered);
    LiveSource *source=self.sources[effect[@"window"]];if((!fullscreen&&!restoring)||!source||source.detached||source.nativeVisibilityWanted||source.nativeMinimized||source.nativeMouseOwnership||!boundIdentity(source.identity,effect[@"identity"]))return;
    NSNumber *output=[self.nativeViews desiredOwnerForWindow:source.logical];NSDictionary *view=nil,*binding=nil;
    for(NSDictionary *row in snapshot[@"outputs"])if([row[@"id"]isEqual:output]){view=row;break;}
    for(NSDictionary *row in snapshot[@"windows"])if([row[@"window"]isEqual:source.logical]){binding=asDict(row[@"source"]);break;}
    if(!view||!boundIdentity(binding[@"identity"],source.identity)||![binding[@"generation"]isEqual:effect[@"generation"]])return;
    NSDictionary *window=windowInfo(source.router.wid);CGRect native=CGRectZero,displayed=CGRectZero;
    BOOL geometry=DWNativeBounds(source.router.wid,&native)&&[window[(id)kCGWindowBounds]isKindOfClass:NSDictionary.class]
        &&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds],&displayed);
    // Infinify owns this transition at every zoom. A covered direct resize
    // avoids starting AppKit Fill and later waiting for its Unfill animation.
    // Unsupported families retain the existing withheld native fallback.
    DWNativeHiddenRoot *root=geometry?[self.native beginTransitionForWindow:source.identity]:nil;
    if(!root&&![self.native withholdWindow:source.identity])return;
    if(restoring)[self.nativeFillHistory removeObjectForKey:source.logical];
    else if(root){if(!self.nativeFillHistory)self.nativeFillHistory=[NSMutableDictionary dictionary];self.nativeFillHistory[source.logical]=@{@"identity":source.identity.copy,@"generation":effect[@"generation"]};}
    self.nativeFillRoot=root;self.nativeFillHiding=NO;self.nativeFillAnimating=NO;self.nativeFillAnimated=NO;self.nativeFillRevealing=NO;self.nativeFillPresentationDeadline=0;
    self.nativeFillHandoff=@{@"window":effect[@"window"],@"transaction":effect[@"transaction"],@"identity":source.identity.copy,@"generation":effect[@"generation"],@"restoring":@(restoring),@"presenter":self.native,@"session":@(self.nativeSessionEpoch),@"output":output,@"camera":view[@"camera"],@"zoom":view[@"zoom"],@"screen_bounds":view[@"screen_bounds"],@"background":root&&!restoring?(self.nativeOwnerSnapshot?:@{}):@{}};self.nativeFillResuming=NO;
    __weak Desktop *handoffDesktop=self;__weak DWNativePresenter *handoffPresenter=self.native;NSNumber *handoffTransaction=effect[@"transaction"];
    self.native.transitionFrameAcknowledged=^{Desktop *d=handoffDesktop;
        if(!d||d.cleaning||d.sessionInactive||d.native!=handoffPresenter||![d.nativeFillHandoff[@"transaction"]isEqual:handoffTransaction])return;
        [d render];};
    self.nativeResizeDriver.fillPreparationTimeout=root?2.5:.75;self.resize.timeout=root?7:3;
    [self cancelNativeHoverForWindow:nil];[self cancelCapturedInputForWindow:nil];self.nativeViewSnapshot=nil;
    if(DWInputTrace())fprintf(stderr,"debug: native fill handoff window=#%s native=%g,%g %gx%g displayed=%g,%g %gx%g snapshot=%d restore=%d\n",source.logical.description.UTF8String,native.origin.x,native.origin.y,native.size.width,native.size.height,displayed.origin.x,displayed.origin.y,displayed.size.width,displayed.size.height,root!=nil,restoring);
    if(root){
        __weak Desktop *weak=self;NSDictionary *held=self.nativeFillHandoff;
        BOOL (^valid)(void)=^BOOL{Desktop *d=weak;return d&&d.nativeFillRoot==root&&!d.nativeFillResuming
            &&[d.nativeFillHandoff[@"transaction"]isEqual:held[@"transaction"]]
            &&[d nativeFillCurrent:held snapshot:[d call:@{@"op":@"snapshot"}]];};
        // Snapshot preparation can occupy main longer than the ordinary
        // setter admission budget. Only this exact, read-only baseline may
        // wait for it; its effect, session and handoff are checked again then.
        [self.nativeResizeDriver prepareBaseline:effect validate:^BOOL{
            Desktop *d=weak;if(!valid())return NO;
            NSDictionary *current=asDict([d call:@{@"op":@"snapshot"}][@"native_resize"]);
            return ![current[@"cancelled"]boolValue]&&[current[@"pending_effect"]isEqual:effect]
                &&![d.nativeFillRefusedTransactions containsObject:effect[@"transaction"]];
        }];
        self.nativeFillCapture=[DWNativeTransitionCapture captureIdentity:root.identity nativeBounds:root.nativeBounds screenRect:root.screenRect validate:valid completion:^(DWNativeTransitionCaptureResult *result,NSString *failure){
            Desktop *d=weak;if(!valid())return;d.nativeFillCapture=nil;
            DWNativeTransition *picture=result?[[DWNativeTransition alloc]initWithImage:result.image screenRect:result.screenRect]:nil;
            if(picture&&[picture show]){d.nativeFillPicture=picture;[d updateNativeFill];[d render];}
            else {NSMutableDictionary *failed=[d.nativeFillHandoff mutableCopy];failed[@"bridge_failed"]=@YES;d.nativeFillHandoff=failed;
                if(DWInputTrace())fprintf(stderr,"debug: native transition capture refused window=#%s reason=%s\n",[held[@"window"]description].UTF8String,(failure?:@"snapshot panel unavailable").UTF8String);}
        }];
    }
}
- (void)interruptFillForVisibility:(LiveSource *)source {
    NSDictionary *held=self.nativeFillHandoff;
    if(!source||![held[@"window"]isEqual:source.logical]||!boundIdentity(held[@"identity"],source.identity))return;
    // Retire temporary hide/reveal phases without ever describing a resumed
    // frame. The same main turn keeps the family omitted and journalled.
    [self clearNativeFillPresentation]; // invalidate asynchronous capture/animation callbacks first
    if(held[@"presenter"]==self.native&&[held[@"session"]unsignedLongLongValue]==self.nativeSessionEpoch){
        [self.native resumeWindow:source.identity];source.nativeVisibilityHeld=[self.native withholdWindow:source.identity];
    }
}
- (void)updateNativeFill {
    [self updateDeferredNativeRestore];
    NSDictionary *held=self.nativeFillHandoff;if(!held)return;
    LiveSource *visibilitySource=self.sources[held[@"window"]];
    if(visibilitySource.nativeVisibilityWanted){[self interruptFillForVisibility:visibilitySource];return;}
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*transaction=asDict(snapshot[@"native_resize"]);
    BOOL gone=![self nativeFillCurrent:held snapshot:snapshot];
    BOOL finished=![transaction[@"transaction"]isEqual:held[@"transaction"]]||([self.resize canRemove:held[@"window"]]&&!self.resize.obligations);
    // A canvas transition can need no native setter (the app was already
    // screen-sized). Its resize transaction may finish before capture, but the
    // displayed projection still needs the same snapshot/hide/animate handoff.
    if(!gone&&finished&&self.nativeFillRoot&&self.nativeFillCapture&&!self.nativeFillCapture.completed)return;
    if(!gone&&self.nativeFillRoot&&self.nativeFillPicture&&!self.nativeFillHiding){
        if([self.native hideTransition:self.nativeFillRoot]){self.nativeFillHiding=YES;if(DWInputTrace())fprintf(stderr,"debug: native transition hide window=#%s\n",[held[@"window"]description].UTF8String);}
        else if(finished){
            // Capture and omission ACK arrive independently. A no-setter
            // transaction must not cancel its picture merely because the
            // presenter's initial omission is still in flight.
            if(!self.nativeFillPresentationDeadline)self.nativeFillPresentationDeadline=CACurrentMediaTime()+2.5;
            if(CACurrentMediaTime()<self.nativeFillPresentationDeadline)return;
        }
    }
    NSDictionary *finalPlacement=nil;
    if(finished)for(NSDictionary *item in [self presentationSnapshot][@"placements"])if([item[@"window"]isEqual:held[@"window"]]&&[item[@"output"]isEqual:held[@"output"]]){finalPlacement=item;break;}
    BOOL targetCurrent=!held[@"target"]||(finalPlacement&&CGRectEqualToRect(jsonRect(finalPlacement[@"screen_rect"]),jsonRect(held[@"target"])));
    BOOL bridge=finished&&!gone&&targetCurrent&&!self.nativeFillResuming&&self.nativeFillRoot&&self.nativeFillPicture&&self.nativeFillHiding;
    if(bridge){
        if(!self.nativeFillPresentationDeadline)self.nativeFillPresentationDeadline=CACurrentMediaTime()+2.5;
        if(![self.native isTransitionRevealed:self.nativeFillRoot]&&CACurrentMediaTime()<self.nativeFillPresentationDeadline){
            if(!self.nativeFillAnimating&&[self.native isTransitionHidden:self.nativeFillRoot]){
                NSDictionary *placement=finalPlacement;CGRect clip=jsonRect(placement[@"clip_rect"]);
                if(placement&&clip.size.width>0&&clip.size.height>0){
                    CGRect target=jsonRect(placement[@"screen_rect"]);
                    DWNativeHiddenRoot *root=self.nativeFillRoot;self.nativeFillAnimating=YES;__weak Desktop *weak=self;
                    NSMutableDictionary *frozen=[self.nativeFillHandoff mutableCopy];frozen[@"target"]=rectJSON(target);self.nativeFillHandoff=frozen.copy;
                    void (^reveal)(BOOL)=^(BOOL completed){Desktop *d=weak;if(!d||d.nativeFillRoot!=root||d.nativeFillResuming)return;
                        NSDictionary *now=[d call:@{@"op":@"snapshot"}];BOOL targetMatches=NO;
                        for(NSDictionary *item in [d presentationSnapshot][@"placements"])if([item[@"window"]isEqual:held[@"window"]]&&[item[@"output"]isEqual:held[@"output"]]&&CGRectEqualToRect(jsonRect(item[@"screen_rect"]),target))targetMatches=YES;
                        BOOL current=[d nativeFillCurrent:held snapshot:now];
                        if(!completed||!targetMatches||!current){if(DWInputTrace())fprintf(stderr,"debug: native transition completion refused window=#%s completed=%d target=%d current=%d\n",[held[@"window"]description].UTF8String,completed,targetMatches,current);d.nativeFillPresentationDeadline=CACurrentMediaTime();return;}
                        d.nativeFillAnimated=YES;d.nativeViewSnapshot=nil;
                        if(DWInputTrace())fprintf(stderr,"debug: native transition animated window=#%s\n",[held[@"window"]description].UTF8String);
                        [d render];};
                    BOOL accepted=[self.nativeFillPicture animateToScreenRect:target completion:reveal];
                    if(DWInputTrace())fprintf(stderr,"debug: native transition animate window=#%s target=%g,%g %gx%g accepted=%d\n",[held[@"window"]description].UTF8String,target.origin.x,target.origin.y,target.size.width,target.size.height,accepted);
                    if(!accepted)self.nativeFillPresentationDeadline=CACurrentMediaTime();
                }else self.nativeFillPresentationDeadline=0;
            }
            // Animation completion and the helper's global omission ACK can
            // arrive in either order. Keep the completed picture while waiting
            // for the same exact target to become revealable; do not restart
            // animation or extend the bounded presentation deadline.
            if(self.nativeFillAnimated&&!self.nativeFillRevealing&&finalPlacement){
                CGRect target=jsonRect(finalPlacement[@"screen_rect"]);
                double alpha=finalPlacement[@"opacity"]?[finalPlacement[@"opacity"]doubleValue]:1;
                self.nativeFillRevealing=[self.native revealTransition:self.nativeFillRoot screen:target alpha:alpha];
                if(self.nativeFillRevealing&&DWInputTrace())fprintf(stderr,"debug: native transition reveal window=#%s accepted=1\n",[held[@"window"]description].UTF8String);
            }
            if(self.nativeFillPresentationDeadline)return;
        }
    }
    if(!self.nativeFillResuming&&(gone||finished)){
        if(DWInputTrace())fprintf(stderr,"debug: native transition resume window=#%s gone=%d finished=%d placement=%d hidden=%d animating=%d revealing=%d\n",[held[@"window"]description].UTF8String,gone,finished,finalPlacement!=nil,self.nativeFillHiding,self.nativeFillAnimating,self.nativeFillRevealing);
        [self.nativeFillCapture cancel];self.nativeFillCapture=nil;
        if(held[@"presenter"]==self.native&&[held[@"session"]unsignedLongLongValue]==self.nativeSessionEpoch)[self.native resumeWindow:held[@"identity"]];
        self.nativeFillResuming=YES;self.nativeViewSnapshot=nil;
    }
    if(gone){if(!self.nativeFillRefusedTransactions)self.nativeFillRefusedTransactions=[NSMutableSet set];[self.nativeFillRefusedTransactions addObject:held[@"transaction"]];[self clearNativeFillPresentation];return;}
    if(self.nativeFillResuming){
        NSNumber *output=[self.nativeViews desiredOwnerForWindow:held[@"window"]];
        NSNumber *generation=nil;for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:held[@"window"]]&&boundIdentity(window[@"source"][@"identity"],held[@"identity"]))generation=window[@"source"][@"generation"];
        DWNativeAppliedPlacement *placed=[self.native acknowledgedPlacementForWindow:held[@"window"] identity:held[@"identity"] generation:generation output:output];
        if(placed||!output||!generation){[self clearNativeFillPresentation];
            if(DWInputTrace())fprintf(stderr,"debug: native fill handoff resumed window=#%s sequence=%llu\n",[held[@"window"]description].UTF8String,(unsigned long long)placed.sequence);}
    }
}
// Shared tail of every bound or scripted command: redraw, fly, persist, and the effects
// the shell owns: quit, exec, a config reload, a pointer warp, a keyboard layout switch,
// a window's close button and the launch of a stand-in's application.
- (void)applyReply:(NSDictionary *)reply {
    NSDictionary *sized=[self consumeSize:reply];
    // The navigation coordinator reads "effect" as a focus request. A reply that lists "effects" keeps its focus request there:
    // its "effect" is a size transaction's, or null without one, and is kept from that reading. The one reply whose "effect" stays
    // a focus request beside a size transaction is the attach's shape, the transaction as an entry of "effects": an activation or a
    // hover that leaves fullscreen may answer so, and its focus request is still the coordinator's.
    BOOL beside=sized&&reply[@"effect"]!=sized&&asDict(reply[@"effect"]);
    if(reply[@"effect"]&&!beside&&(sized||[reply[@"effects"]isKindOfClass:NSArray.class])){NSMutableDictionary *rest=[reply mutableCopy];[rest removeObjectForKey:@"effect"];reply=rest;}
    // A gesture reply says itself when frames are needed: a camera coasting after a swipe, or the edge pan under a move, is no flight.
    BOOL flight=asDict(reply[@"navigation"])!=nil||[reply[@"needs_frames"]isEqual:@YES];if(flight&&!self.navigation)self.flying=YES;
    // The reply's focus request, if any, is the coordinator's to perform on the native window.
    [self.navigation perform:reply];
    [self render];if(flight)[self ensureFrames];
    if([reply[@"dirty"]isEqual:@YES])self.sceneDirty=YES;
    for(id effect in asArray(reply[@"effects"])){NSDictionary *e=asDict(effect);NSString *op=asString(e[@"op"]);
        if([op isEqual:@"quit"])[self quit:nil];
        else if(!self.configured)continue;
        else if([op isEqual:@"exec"]&&asString(e[@"command"]))[self exec:e];
        // send-cursor-to-output, an explicit user action: the point is in the coordinates of screen_bounds.
        // Position only: this shell does not own an application's mouse/cursor association.
        else if([op isEqual:@"warp_pointer"]){NSDictionary *screen=asDict(e[@"screen"]);CGPoint to=jsonPoint(screen);if(asNumber(screen[@"x"])&&asNumber(screen[@"y"])&&isfinite(to.x)&&isfinite(to.y)){CGWarpMouseCursorPosition(to);}}
        // The selection is reported at once; the input-source notification reports it again.
        else if([op isEqual:@"switch_layout"]){NSString *error=DWSwitchLayout(e);if(error)[self flashStatus:error];[self reportLayout];}
        // Deferred: a reload replaces the hot keys, and this may be running inside one of their handlers.
        else if([op isEqual:@"reload_config"]){__weak Desktop *weak=self;dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;if(d&&!d.cleaning)[d loadConfig:NO];});}
        else if([op isEqual:@"close_window"])[self closeWindow:e];
        else if([op isEqual:@"set_minimized"])[self setNativeMinimized:e];
        else if([op isEqual:@"launch"])[self launch:asString(e[@"bundle_id"])];
    }
}
// Minimize retains the native identity, controller slot and helper journal.
// AX notifications request a bounded worker observation; they are not proof of
// visibility. Restores remain ineligible for input until a fresh placement ACK.
- (NSDictionary *)visibilityBinding:(LiveSource *)source {
    if(!source||source.detached||self.sources[source.logical]!=source)return nil;
    for(NSDictionary *row in [self call:@{@"op":@"snapshot"}][@"windows"])
        if([row[@"window"]isEqual:source.logical]&&boundIdentity(row[@"source"][@"identity"],source.identity))return asDict(row[@"source"]);
    return nil;
}
- (BOOL)visibilityTicketCurrent:(NSDictionary *)ticket source:(LiveSource *)source {
    if(!ticket||self.cleaning||self.sessionInactive||!self.native||self.native.ended||ticket[@"presenter"]!=self.native
        ||[ticket[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch||!source||source.detached
        ||self.sources[source.logical]!=source||!boundIdentity(source.identity,ticket[@"identity"]))return NO;
    NSDictionary *binding=[self visibilityBinding:source];
    return [binding[@"generation"]isEqual:ticket[@"generation"]];
}
- (void)requestVisibility:(LiveSource *)source {
    if(!source||source.detached)return;
    NSDictionary *binding=[self visibilityBinding:source];
    if(!binding||![self call:@{@"op":@"source_visibility_pending",@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"]}])return;
    source.nativeVisibilityRevision++;source.nativeVisibilityWanted=YES;source.nativeVisibilityRetryAt=0;
    source.nativeVisibilityStable=nil;source.nativeVisibilityRestore=nil;
    source.observationToken=++self.observationEpoch;[source invalidateNativeButtons];
    [self cancelNativeHoverForWindow:source.logical];[self cancelCapturedInputForWindow:source.logical];
    [self interruptFillForVisibility:source];
    if([[self.resize busyWindow]isEqual:source.logical])[self.resize cancel];
    if(self.native&&!self.nativeFillHandoff&&![[self.resize busyWindow]isEqual:source.logical]
        &&[self.native withholdWindow:source.identity])source.nativeVisibilityHeld=YES;
    self.nativeViewSnapshot=nil;self.windowObservationAgain=YES;[self render];[self requestWindowObservation];
}
- (void)windowVisibilityChanged:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning)return;
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&source.router.wid==window)[self requestVisibility:source];
}
- (void)setNativeMinimized:(NSDictionary *)effect {
    LiveSource *source=self.sources[effect[@"window"]];NSDictionary *binding=[self visibilityBinding:source];
    if(!self.native||!source||!boundIdentity(source.identity,effect[@"identity"])||![binding[@"generation"]isEqual:effect[@"generation"]]){
        [self flashStatus:@"Minimize skipped: native window binding is unavailable"];return;
    }
    if(source.nativeVisibilityEffect){[self flashStatus:@"A window visibility request is already pending"];return;}
    NSMutableDictionary *ticket=[effect mutableCopy];ticket[@"presenter"]=self.native;ticket[@"session"]=@(self.nativeSessionEpoch);ticket[@"deadline"]=@(CACurrentMediaTime()+8);ticket[@"revision"]=@(source.nativeVisibilityRevision);
    source.nativeVisibilityEffect=ticket.copy;[self updateNativeVisibility];
}
static bool DWVisibilityAllowed(DWFocusIdentity selected,void *context) {
    (void)selected;BOOL (^check)(void)=(__bridge id)context;__block BOOL allowed=NO;
    dispatch_sync(dispatch_get_main_queue(),^{allowed=check();});return allowed;
}
- (void)updateNativeVisibility {
    if(self.cleaning||self.sessionInactive||!self.native||self.native.ended)return;
    for(LiveSource *source in self.sources.allValues){
        NSDictionary *effect=source.nativeVisibilityEffect;
        if(effect&&!source.nativeVisibilityWriting){
            if(![self visibilityTicketCurrent:effect source:source]||[effect[@"revision"]unsignedLongLongValue]!=source.nativeVisibilityRevision||CACurrentMediaTime()>[effect[@"deadline"]doubleValue]){
                source.nativeVisibilityEffect=nil;[self requestVisibility:source];[self flashStatus:@"Window visibility request expired before native ownership settled"];continue;
            }
            // A Fill exit owns the same withhold/resume mechanism. Finish it,
            // including its helper ACK, before handing this window to AppKit.
            if(self.nativeFillHandoff||![self.resize canRemove:source.logical]||source.nativeMouseOwnership)continue;
            if(![self.native withholdWindow:source.identity])continue;
            source.nativeVisibilityHeld=YES;
            if(![self.native isWindowWithheld:source.identity]){[self render];continue;}
            source.nativeVisibilityWriting=YES;
            [source invalidateNativeButtons];[self cancelNativeHoverForWindow:source.logical];[self cancelCapturedInputForWindow:source.logical];
            __weak Desktop *weak=self;__weak LiveSource *live=source;
            BOOL (^valid)(void)=^BOOL{Desktop *d=weak;LiveSource *s=live;
                return d&&s&&s.nativeVisibilityEffect==effect&&[d visibilityTicketCurrent:effect source:s]
                    &&[effect[@"revision"]unsignedLongLongValue]==s.nativeVisibilityRevision&&CACurrentMediaTime()<[effect[@"deadline"]doubleValue]&&!d.nativeFillHandoff&&[d.resize canRemove:s.logical]
                    &&[d.native isWindowWithheld:s.identity];};
            NSDictionary *identity=source.identity;
            DWFocusIdentity selected={.pid=[identity[@"pid"]intValue],.window=[identity[@"wid"]unsignedIntValue],.seconds=[identity[@"birth_sec"]unsignedLongLongValue],.microseconds=[identity[@"birth_usec"]unsignedLongLongValue]};
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                DWFocusResult result=dw_focus_set_minimized(selected,[effect[@"minimized"]boolValue],DWVisibilityAllowed,(__bridge void *)valid);
                dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;LiveSource *s=live;if(!d||!s||d.sources[s.logical]!=s)return;
                    s.nativeVisibilityWriting=NO;if(s.nativeVisibilityEffect==effect)s.nativeVisibilityEffect=nil;
                    if(![d visibilityTicketCurrent:effect source:s])return;
                    // A successful setter is still only an attempt. Read the
                    // actual AX value through the existing observer worker.
                    [d requestVisibility:s];
                    if(result.outcome!=DWFocusObserved)[d flashStatus:[NSString stringWithFormat:@"Window visibility request: %s",dw_focus_outcome_name(result.outcome)]];
                    if(DWInputTrace())fprintf(stderr,"debug: native visibility write window=#%s minimized=%d attempted=%d outcome=%s\n",s.logical.description.UTF8String,[effect[@"minimized"]boolValue],result.mutation_attempted,dw_focus_outcome_name(result.outcome));
                });
            });
        }
        NSDictionary *restore=source.nativeVisibilityRestore;if(!restore)continue;
        if(![self visibilityTicketCurrent:restore source:source]||[restore[@"revision"]unsignedLongLongValue]!=source.nativeVisibilityRevision){source.nativeVisibilityRestore=nil;continue;}
        if(self.nativeFillHandoff||source.nativeVisibilityWanted||source.nativeVisibilityWriting)continue;
        NSNumber *output=[self.nativeViews desiredOwnerForWindow:source.logical];
        DWNativeAppliedPlacement *receipt=output?[self.native acknowledgedPlacementForWindow:source.logical identity:source.identity generation:restore[@"generation"] output:output]:nil;
        BOOL ready=output?(receipt&&[self.native isAcknowledgedPlacementCurrent:receipt]):[self.native isParkingAcknowledgedForWindow:source.logical identity:source.identity generation:restore[@"generation"]];
        if(!ready)continue;
        if(![self.resize canRemove:source.logical])continue;
        NSDictionary *binding=[self visibilityBinding:source];
        if([binding[@"visibility"]isEqual:@"restoring"]){
            NSDictionary *reply=[self call:@{@"op":@"source_visible",@"window":source.logical,@"identity":source.identity,@"generation":restore[@"generation"],@"visibility_revision":restore[@"visibility_revision"]}];
            if(!reply)continue;
            // External Fill minimization retained a size debt. Its first
            // acknowledged restore starts that guarded transaction; input
            // remains closed until a later ACK observes it fully settled.
            if(sizeEffect(reply)){[self applyReply:reply];continue;}
            if(![reply[@"visibility"]isEqual:@"visible"])continue;
        }else if(![binding[@"visibility"]isEqual:@"visible"])continue;
        source.nativeMinimized=NO;source.nativeVisibilityHeld=NO;source.nativeVisibilityRestore=nil;
        if(DWInputTrace())fprintf(stderr,"debug: native visibility ready window=#%s revision=%llu sequence=%llu parked=%d\n",source.logical.description.UTF8String,[restore[@"revision"]unsignedLongLongValue],(unsigned long long)receipt.sequence,!output);
        [self render];[self focusChanged];
    }
}
- (void)observeVisibility:(DWWindowObservation *)observation source:(LiveSource *)source {
    NSDictionary *request=observation.request;
    if(!request[@"visibility_revision"]||[request[@"visibility_revision"]unsignedLongLongValue]!=source.nativeVisibilityRevision||!source.nativeVisibilityWanted)return;
    source.nativeVisibilityRetryAt=CACurrentMediaTime()+.1;
    if(!observation.minimized||self.nativeFillHandoff||![self.resize canRemove:source.logical]||source.nativeVisibilityWriting)return;
    BOOL minimized=observation.minimized.boolValue;
    NSDictionary *binding=[self visibilityBinding:source];if(!binding)return;
    if(!minimized){
        // AppKit's deminiaturization owns its native animation. Two fresh,
        // unchanged native readings keep its moving geometry out of ours.
        // An off-canvas source can legitimately remain off screen.
        if(!observation.hasBounds){source.nativeVisibilityStable=nil;return;}
        NSDictionary *stable=@{@"bounds":rectJSON(observation.bounds),@"displayed":observation.info[(id)kCGWindowBounds]?:@{},@"onscreen":@([observation.info[(id)kCGWindowIsOnscreen]boolValue])};
        if(![source.nativeVisibilityStable isEqual:stable]){source.nativeVisibilityStable=stable;source.nativeVisibilityStableSince=CACurrentMediaTime();return;}
        if(CACurrentMediaTime()-source.nativeVisibilityStableSince<.05)return;
    }
    if(observation.hasBounds)[self.native bound:source.identity bounds:observation.bounds family:observation.family];
    if(![self.native withholdWindow:source.identity])return;
    source.nativeVisibilityHeld=YES;
    NSDictionary *reply=[self call:@{@"op":@"observe_visibility",@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"minimized":@(minimized)}];if(!reply)return;
    source.nativeVisibilityWanted=NO;source.nativeVisibilityStable=nil;
    source.nativeMinimized=minimized;
    if(minimized){if([reply[@"changed"]boolValue])self.sceneDirty=YES;source.nativeVisibilityRestore=nil;[self forgetNativeFamily:source];self.nativeViewSnapshot=nil;[self render];return;}
    // Rebind the fresh native basis while preserving the controller's world
    // rectangle. The restore placement is presentable but never a hit target.
    [self.native bound:source.identity bounds:observation.bounds family:observation.family];
    source.router.bounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(observation.bounds));
    [self call:@{@"op":@"observe_presentation",@"window":source.logical,@"identity":source.identity,@"source_rect":rectJSON(observation.bounds),@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)}}];
    binding=[self visibilityBinding:source];
    source.nativeVisibilityRestore=@{@"identity":source.identity.copy,@"generation":binding[@"generation"],@"visibility_revision":binding[@"visibility_revision"],@"revision":@(source.nativeVisibilityRevision),@"presenter":self.native,@"session":@(self.nativeSessionEpoch)};
    [self.native resumeWindow:source.identity];self.nativeViewSnapshot=nil;[self render];
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
// A stand-in has no native keyboard recipient. Take the existing canvas panel's
// keyboard focus once on that logical transition, without changing its order.
// Later rendering must never steal it back from an application the user chose.
- (void)updateStandInKeyboard:(NSDictionary *)snapshot {
    NSDictionary *standin=DWFocusedStandIn(snapshot);NSNumber *window=standin[@"window"];
    if(!self.configured||self.windowed||self.cleaning||self.sessionInactive)window=nil;
    if([window isEqual:self.standinKeyboardWindow]||(!window&&!self.standinKeyboardWindow))return;
    DesktopPanel *panel=nil;
    if(window)for(NSDictionary *placement in snapshot[@"placements"])if([placement[@"window"]isEqual:window]){
        for(DesktopView *view in self.views)if([view.outputs containsObject:placement[@"output"]]&&[view.window isKindOfClass:DesktopPanel.class]){panel=(DesktopPanel *)view.window;break;}
        if(panel)break;
    }
    if(window&&!panel)return;
    DesktopPanel *old=(DesktopPanel *)self.standinKeyboardPanel;old.standinKeyboard=NO;
    if(old.isKeyWindow)[old resignKeyWindow];
    self.standinKeyboardWindow=window;self.standinKeyboardPanel=panel;self.standinKeyboardSerial++;
    if(panel){panel.standinKeyboard=YES;[NSApp activate];[panel makeKeyWindow];}
}
- (dispatch_block_t)standInEnter {
    if(!self.configured||self.cleaning||self.sessionInactive||[self nativeUnavailable]||!NSApp.active
        ||!self.standinKeyboardPanel.isKeyWindow||NSApp.keyWindow!=self.standinKeyboardPanel
        ||![self.panels containsObject:self.standinKeyboardPanel]||NSEvent.pressedMouseButtons||self.gestureOwner||self.magnifying||self.trackpad.engaged||self.nativeFillHandoff)return nil;
    for(DesktopView *view in self.views)if(view.gesture||view.pressedSource)return nil;
    for(LiveSource *source in self.sources.allValues)if(source.nativeMouseOwnership)return nil;
    NSDictionary *standin=DWFocusedStandIn([self call:@{@"op":@"snapshot"}]);
    if(!standin||![standin[@"window"]isEqual:self.standinKeyboardWindow])return nil;
    NSUInteger serial=self.standinKeyboardSerial;NSNumber *window=standin[@"window"];__weak Desktop *weak=self;
    return ^{Desktop *d=weak;if(!d||d.standinKeyboardSerial!=serial||![d.standinKeyboardWindow isEqual:window]||![d standInEnter])return;
        [d.tapKeys taint];[d applyReply:[d call:@{@"op":@"ipc",@"request":@{@"Relaunch":window}}]];};
}
// A system window-control shortcut belongs to the exact managed native root that
// currently has keyboard focus. The controller's last observation alone cannot
// distinguish a new window in the same app; read only AXFocusedWindow here.
- (NSDictionary *)nativeWindowControlIntent {
    if(!self.native||!self.configured||self.windowed||self.cleaning||self.sessionInactive||[self nativeUnavailable])return nil;
    DWFocusIdentity target={0};if(!dw_focus_frontmost(&target))return nil;
    NSDictionary *observed=@{@"pid":@(target.pid),@"wid":@(target.window),@"birth_sec":@(target.seconds),@"birth_usec":@(target.microseconds)};
    LiveSource *source=nil;
    for(LiveSource *candidate in self.sources.allValues)if(boundIdentity(candidate.identity,observed)){source=candidate;break;}
    if(!source||source.detached||source.nativeVisibilityHeld||!DWInScope(self.scope,source.router.pid))return nil;
    NSNumber *window=source.logical;NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
    NSDictionary *binding=nil;
    for(NSDictionary *record in snapshot[@"windows"])if([record[@"window"]isEqual:window]){binding=asDict(record[@"source"]);break;}
    NSNumber *output=[self.nativeViews desiredOwnerForWindow:window];
    if(!output||[self.nativeViews replica:window output:output]||!asNumber(binding[@"generation"])||!boundIdentity(source.identity,binding[@"identity"]))return nil;
    NSDictionary *identity=source.identity.copy;
    return @{@"window":window,@"identity":identity,@"generation":binding[@"generation"],@"output":output,@"session":@(self.nativeSessionEpoch)};
}
- (dispatch_block_t)nativeWindowControlKey:(DWNativeWindowControl)action {
    NSDictionary *intent=[self nativeWindowControlIntent];if(!intent)return nil;__weak Desktop *weak=self;
    // The physical pair stays owned even if the target or geometry becomes
    // unavailable before dispatch. Never deliver a native fallback mid-pair.
    return ^{Desktop *d=weak;if(!d||![[d nativeWindowControlIntent]isEqual:intent])return;
        LiveSource *source=d.sources[intent[@"window"]];
        NSDictionary *focus=asDict([d call:@{@"op":@"snapshot"}][@"focus"]);
        if(asDict(focus[@"pending_effect"])||d.nativeFillHandoff||source.nativeMouseOwnership||d.nativeOwnershipTransfer||d.nativeHoverTransfer
            ||d.nativeGestureView||d.nativeScrollView||d.nativeMagnifyView||d.pointerGrab.active||d.gestureOwner||d.magnifying
            ||d.trackpad.engaged||d.globalGestureContact||d.globalTrackpad.ownsTouches||d.globalTrackpad.hasNativeMousePress
            ||NSEvent.pressedMouseButtons||[[d.resize busyWindow]isEqual:source.logical])return;
        for(DesktopView *view in d.views)if(view.gesture||view.heldPress||view.pressedSource||view.pressedTablet||view.pressedPointerGrab)return;
        NSString *name=nil;
        switch(action){
            case DWNativeWindowControlToggleFullscreen:name=@"fullscreen";break;
            case DWNativeWindowControlFill:name=@"fill";break;
            case DWNativeWindowControlRestore:name=@"restore";break;
            case DWNativeWindowControlCenter:name=@"center";break;
            case DWNativeWindowControlSuppressTiling:
                [d.tapKeys taint];[d cancelNativeTitleClick];[d flashStatus:@"Use the canvas to arrange windows"];[d render];return;
        }
        if(!name)return;
        NSMutableDictionary *command=[intent mutableCopy];[command removeObjectForKey:@"session"];command[@"op"]=@"native_decoration";command[@"action"]=name;
        [d.tapKeys taint];[d cancelNativeTitleClick];[d applyReply:[d call:command]];
        if(DWInputTrace())fprintf(stderr,"debug: native window control key action=%s window=#%s\n",name.UTF8String,source.logical.description.UTF8String);
    };
}
- (void)launch:(NSString *)bundle {
    __weak Desktop *weak=self;
    DWLaunchApplication(bundle,^(NSString *reason){Desktop *d=weak;if(!d||d.cleaning)return;NSString *note=[@"Relaunch failed: " stringByAppendingString:reason];[d say:note];[d flashStatus:note];[d render];});
}
// Which corners are bound depends on the outputs registered: read from the bindings
// after every config load, and again whenever panels open.
- (void)armCorners:(NSDictionary *)bindings { if(!self.corners)self.corners=[DWHotCorners new];[self.corners arm:asArray(bindings[@"hot_corners"])]; }
// Is a window fullscreen on this output, by the outputs of the snapshot last drawn (-render)?
- (BOOL)fullscreenOn:(NSNumber *)output { for(NSDictionary *o in self.pointerOutputs)if([o[@"id"]isEqual:output])return asDict(o[@"fullscreen"])!=nil;return NO; }
// Upstream checks hot corners on every pointer motion. Here the pointer is read at
// the poll and frame cadence, and only while some corner is bound. A display's
// corners are its panel's, which are the output's and the display's own: the true
// corners, where the pointer comes to rest. The controller picks and runs the action.
// An entry upstream suppresses is not sent at all, under a held button as on an output
// that is fullscreen with disable_when_fullscreen: the status line then reports no
// action that did not run. The controller's hot_corner applies the fullscreen rule too.
- (void)watchCorners {
    if(self.cleaning||self.sessionInactive||!self.corners.armed)return;
    CGPoint p=pointer();BOOL dragging=NSEvent.pressedMouseButtons!=0;
    for(DesktopView *view in self.views)if(view.gesture||view.pressedSource)dragging=YES;
    for(DesktopView *view in self.views){
        CGRect display=view.globalBounds;if(view.outputs.count!=1||!CGRectContainsPoint(display,p))continue;
        // Upstream's nested backend sees only the motion its own window is sent: an ordinary window
        // covered at the pointer, or left on another Space, has no pointer in its corner. Not asked of
        // the full-screen panels, whose top corners lie under the menu bar.
        if(self.windowed&&[NSWindow windowNumberAtPoint:NSMakePoint(p.x,screenTop()-p.y) belowWindowWithWindowNumber:0]!=view.window.windowNumber)continue;
        NSNumber *output=view.outputs[0];NSString *corner=[self.corners enter:CGPointMake(p.x-display.origin.x,p.y-display.origin.y) size:display.size output:output fullscreen:[self fullscreenOn:output] dragging:dragging];
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
    if(self.sessionInactive)return; // retain launch effects until the unopened canvas can admit its session
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
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held corner:(NSString *)corner { [self action:action output:output at:point held:held corner:corner tap:nil]; }
// So is a tap binding's, which the controller looks up by the chord: `tap` is the physical modifiers of the chord just completed, as the
// bindings reply gave them. Upstream runs a tap's action as it runs a key's (keyboard.rs: pending_tap_action through execute_action).
- (void)action:(NSString *)action output:(NSNumber *)output at:(CGPoint)point held:(BOOL)held corner:(NSString *)corner tap:(NSDictionary *)tap {
    if(self.sessionInactive||([self nativeUnavailable]&&![action isEqual:@"quit"]))return;
    // An action cancels a resize the pointer began and is dropped while that is unresolved. A sizing action's own transaction is
    // not cancelled and drops nothing: the next action, a held grow-window's repeat among them, is the controller's to answer.
    if(self.cleaning||!output)return;
    // Upstream's go-to-bookmark is silent on an unset name, so the bookmark table is asked first.
    NSString *name=[action hasPrefix:@"go-to-bookmark "]?[action substringFromIndex:15]:nil;
    // The question is an ipc reply like any other: a size transaction the controller began with it, the size a fullscreen exit still owed its window, is performed.
    NSDictionary *known=name?[self call:@{@"op":@"ipc",@"output":output,@"request":@{@"Bookmark":@{@"name":name}}}]:nil;[self consumeSize:known];
    BOOL unset=name&&!asDict(known[@"reply"])[@"Ok"];
    NSMutableDictionary *command=[(tap?@{@"op":@"tap",@"modifiers":tap,@"output":output}:corner?@{@"op":@"hot_corner",@"output":output,@"corner":corner}:@{@"op":@"action",@"output":output,@"action":action})mutableCopy];
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
// gesture fired and a note when it is refused (a resize of a screen-pinned window).
- (void)gesture:(NSDictionary *)event owner:(NSInteger)owner {
    NSString *op=event[@"op"];
    // Cancellation receipts still drain the old gesture; no new/update event can
    // move the logical scene while its native owner is unavailable.
    if([self nativeUnavailable]&&(![op isEqual:@"gesture_end"]||![event[@"cancelled"]boolValue]))return;
    BOOL begin=[op isEqual:@"gesture_begin"],end=[op isEqual:@"gesture_end"],held=[DWCycleHold modifiersDown]!=0;NSMutableDictionary *command=[event mutableCopy];
    if(begin){
        [self cancelNativeTitleClick];
        // Upstream: a gesture that begins on top of a held modifier chord makes it a binding prefix, not a tap, whatever becomes of the gesture.
        [self.tapKeys taint];
        // The controller holds one gesture: a pinch that gains a third finger ends before the swipe it became begins.
        if(self.gestureOwner)[self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":event[@"time_ms"]} owner:self.gestureOwner];
        if(self.cleaning||self.sessionInactive)return;
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
        self.gestureOwner=owner;self.gestureOutput=output;self.gestureWatched=!self.globalGestureContact&&!self.globalGestureDelivery&&[[self outputUnderPointer:p]isEqual:output];self.gestureMove=self.gestureResize=NO;
    }else if(owner!=self.gestureOwner)return;
    else command[@"held"]=held?@YES:@NO;
    if(end)self.gestureOwner=0;
    NSDictionary *reply=[self call:command];
    if(begin&&owner==2){NSString *state=asString(asDict(reply[@"gesture"])[@"state"]);self.nativePinchAccepted=state&&![state isEqual:@"unbound"];}
    // A refusal is said once and ends the gesture on both sides. That end is a gesture reply too: a size transaction it carries is performed.
    if(!reply){
        NSString *error=self.statusText;if(!begin&&!end)[self consumeSize:[self call:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":event[@"time_ms"]}]];
        self.gestureOwner=0;[self flashStatus:error];[self render];return;
    }
    // A pan that ends cancelled while still moving lost its touches: macOS took them, a button was pressed, the panels went away. (A finger lifting ahead of the others waits out the recogniser's count debounce, too long to launch.) The canvas stops there instead of coasting on as upstream's cancelled swipe does.
    if(end&&[command[@"cancelled"]isEqual:@YES]&&self.gestureOutput&&[asString(asDict(reply[@"gesture"])[@"state"])isEqual:@"swipe_pan"])[self call:@{@"op":@"cancel_navigation",@"output":self.gestureOutput}];
    // No gesture in the reply: trackpad gestures are off (set-trackpad), and the rest of this one has nowhere to go.
    if(begin&&!asDict(reply[@"gesture"]))self.gestureOwner=0;
    if(begin){NSString *state=asString(asDict(reply[@"gesture"])[@"state"]);self.gestureResize=[state isEqual:@"swipe_resize"];self.gestureMove=self.gestureResize||[state isEqual:@"swipe_move"];}
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
    if(self.globalTrackpad.running||self.multitouch.delivering)return;
    if(!self.trackpad||self.cleaning||self.sessionInactive)return;
    self.touchPath=@"view-touches";
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
    if(self.nativeFillHandoff)return;
    if(self.globalTrackpad.running&&!self.globalGestureDelivery)return;
    [self.compositor finishGeometryTransitions];
    if(self.compositor.hasGeometryTransitions)return;
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
    [self.globalTrackpad cancel];self.globalGestureContact=NO;
    NSTimeInterval now=CACurrentMediaTime();
    [self.trackpadTimer invalidate];self.trackpadTimer=nil;self.trackpadDeadline=0;self.magnifying=NO;[self.trackpad cancel:now];[self.touchFeed cancel:now];
    if(self.gestureOwner)[self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":DWGestureTime(now)} owner:self.gestureOwner];
}
// macOS platform rule: input whose end never arrived. Upstream's grabs end with their release and libinput ends every gesture it begins; here an end
// can be lost, and what it would have ended is then held for good: the controller refuses every flight while it holds a drag, and a window move resting
// in navigation.edge_pan's zone goes on being carried by the pan beneath it, a frame's worth every frame, without bound. Every frame of the frame timer
// and every poll of a normal run therefore look, and what they find lost ends through the path its own end takes:
// - a press whose release never reached its view (the button came up over another application, inside a menu or a drag session of macOS, or while
//   the panels were being rebuilt): macOS says which buttons are down, and a gesture whose own button has been up for 50 ms, with no release of
//   it waiting in the event queue, is released at the pointer (-[DesktopView released:at:]). The queue is asked because the 50 ms are wall time:
//   a poll that takes as long leaves a real release queued behind this reading, and that release ends its press itself, at its own point and time;
// - a trackpad gesture of the recogniser's whose touches stopped coming without an end or a cancel. Touches go to the view under the pointer, so once
//   the gesture's output is no longer what a press there would reach (Mission Control, another window, a menu over the canvas) its touches are not
//   this panel's any more, and the gesture ends cancelled as a touch macOS cancels does (-cancelGestures). And a move gesture, the one that holds a
//   drag, whose fingers have sent nothing at all for thirty seconds is taken for lost. Still fingers send no touches either and nothing tells the
//   two apart, so thirty seconds is also the longest a move can rest in the edge zone without the least movement of a finger, and only the
//   controller's gesture is ended then: the recogniser keeps its fingers and its swipe, whose later updates and end find no owner (-gesture:owner:),
//   so fingers that were only resting cannot begin another gesture until they lift.
// Probe, demo and owned-fixture runs drive presses no button backs and take no touches: they are left alone.
- (void)endLostInput {
    if(!self.configured||self.cleaning||self.askingQueue)return;
    [self.nativeInput cancelIdleEarlyMousePress];
    NSUInteger down=NSEvent.pressedMouseButtons;CFTimeInterval now=CACurrentMediaTime();
    for(DesktopView *view in self.views.copy){
        // A chrome down swallowed before session annotation never enters
        // AppKit's combined button state or its release queue. Its tap owns the
        // pair and bounds silent lost input above, retaining cancelled tails.
        if(view.gesture&&view==self.nativeGestureView&&self.nativeInput.hasEarlyMousePress){
            view.liftSeen=0;continue;
        }
        // A taken-over native drag ended the application's own press with a posted release, so the system says the button is up while
        // the finger is down. The tap still owns that physical pair until its release, which ends the gesture; ten minutes bound a lost one.
        if(view.gesture&&view.takenOverAt&&now-view.takenOverAt<600&&[self.nativeInput holdsCapturedButton:(NSUInteger)view.gestureButton]){view.liftSeen=0;continue;}
        // A press the DebugPointer request made has no button behind it: its own request or its timer ends it.
        if(!view.gesture||view.injected||(down&(1UL<<view.gestureButton))){view.liftSeen=0;continue;}
        if(!view.liftSeen){view.liftSeen=now;continue;}
        if(now-view.liftSeen<.05)continue;
        // Looked at, not taken: the release stays for its own turn. The look is a turn of the run loop, in which a frame or a timer may run: a frame
        // that does asks nothing itself (askingQueue), and the press is read again once the look is over.
        NSEventMask up=view.gestureButton==0?NSEventMaskLeftMouseUp:view.gestureButton==1?NSEventMaskRightMouseUp:NSEventMaskOtherMouseUp;
        self.askingQueue=YES;NSEvent *queued=[NSApp nextEventMatchingMask:up untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:NO];self.askingQueue=NO;
        if(queued||!view.gesture||self.cleaning||![self.views containsObject:view])continue;
        fprintf(stderr,"A button release never arrived: the press it belonged to is ended here.\n");
        [view released:pointer() at:NSProcessInfo.processInfo.systemUptime];[self render];
    }
    if(self.gestureOwner!=1)return;
    BOOL covered=self.gestureWatched&&![[self outputUnderPointer:pointer()]isEqual:self.gestureOutput],silent=self.gestureMove&&now-self.lastTouches>30;
    if(!covered&&!silent)return;
    fprintf(stderr,"A trackpad gesture lost its touches (%s): ended cancelled.\n",covered?"the canvas is no longer under the pointer":"none for thirty seconds during a window move or resize");
    if(covered)[self cancelGestures];else [self gesture:@{@"op":@"gesture_end",@"cancelled":@YES,@"time_ms":DWGestureTime(now)} owner:1];
    [self render];
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
- (void)clickReleased:(NSNumber *)window output:(NSNumber *)output { if([self nativeUnavailable])return;[self applyReply:[self call:@{@"op":@"activate",@"window":window,@"output":output?:NSNull.null,@"cause":@"click_release"}]]; }
// Pinned upstream pointer.rs title-bar branch and navigation.rs resolve_click_navigate:
// a stationary title grab is still a click; wait past its competing double-click.
- (void)cancelNativeTitleClick { [self.nativeTitleClickTimer invalidate];self.nativeTitleClickTimer=nil;self.nativeTitleClick=nil; }
- (void)deferNativeTitleClick:(NSDictionary *)intent {
    [self cancelNativeTitleClick];NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*pose=nil;
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:intent[@"output"]])pose=view;
    if(!pose)return;
    NSMutableDictionary *click=[intent mutableCopy];click[@"pose"]=@{@"camera":pose[@"camera"],@"zoom":pose[@"zoom"],@"screen_bounds":pose[@"screen_bounds"]};click[@"session"]=@(self.nativeSessionEpoch);self.nativeTitleClick=click.copy;
    __weak Desktop *weak=self;
    self.nativeTitleClickTimer=[NSTimer timerWithTimeInterval:MAX(.3,NSEvent.doubleClickInterval) repeats:NO block:^(NSTimer *timer){[weak fireNativeTitleClick:timer];}];
    [NSRunLoop.mainRunLoop addTimer:self.nativeTitleClickTimer forMode:NSRunLoopCommonModes];
}
- (void)fireNativeTitleClick:(NSTimer *)timer {
    if(!timer||timer!=self.nativeTitleClickTimer)return;
    NSDictionary *click=self.nativeTitleClick;[self cancelNativeTitleClick];
    LiveSource *source=self.sources[click[@"window"]];
    if(!click||!source||source.detached||!self.configured||self.cleaning||self.sessionInactive||[self nativeUnavailable]||self.nativeFillHandoff
        ||[click[@"session"]unsignedLongLongValue]!=self.nativeSessionEpoch||!boundIdentity(source.identity,click[@"identity"])
        ||![birth(source.router.pid)isEqual:source.router.processBirth]
        ||![[self.nativeViews desiredOwnerForWindow:source.logical]isEqual:click[@"output"]])return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*binding=nil,*pose=nil,*focus=asDict(snapshot[@"focus"]);
    for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:click[@"window"]])binding=asDict(window[@"source"]);
    for(NSDictionary *view in snapshot[@"outputs"])if([view[@"id"]isEqual:click[@"output"]])pose=view;
    if(!pose||![binding[@"generation"]isEqual:click[@"generation"]]||!boundIdentity(binding[@"identity"],click[@"identity"])
        ||![focus[@"intent"]isEqual:click[@"window"]]||asDict(focus[@"pending_effect"]))return;
    for(NSString *key in @[@"camera",@"zoom",@"screen_bounds"])if(![pose[key]isEqual:click[@"pose"][key]])return;
    if(!self.logicalFocus){NSDictionary *observed=asDict(focus[@"observed_native"]);
        if(![observed[@"window"]isEqual:click[@"window"]]||![observed[@"generation"]isEqual:click[@"generation"]]
            ||!boundIdentity(observed[@"identity"],click[@"identity"])||NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier!=source.router.pid)return;}
    NSMutableDictionary *command=[click mutableCopy];[command removeObjectsForKeys:@[@"pose",@"session"]];command[@"op"]=@"activate";command[@"cause"]=@"click_release";
    [self applyReply:[self call:command]];
}
// Upstream's raise_and_focus by itself, for a press bound to a resize that begins nothing: the gate is off or the begin was
// turned away (-beginResize:…), or the window is screen-pinned (-press:…).
- (void)raiseFocus:(NSNumber *)window { [self applyReply:[self call:@{@"op":@"focus",@"window":window}]]; }
// The reply to a resize the pointer began, at a handle or by a press bound to resize-window. Upstream raises and focuses the window
// ahead of its resize grab, and the controller does so inside begin_native_resize. That reply's "effect" is the size transaction's,
// which the resize coordinator has consumed, so the focus request is among its "effects", as in a sizing action's reply, and is the
// navigation coordinator's to perform. Probe, demo and owned-fixture runs have no such coordinator, and nothing is read.
- (void)resizeFocus:(NSDictionary *)reply { if(!self.navigation)return;NSMutableDictionary *rest=[reply mutableCopy];[rest removeObjectForKey:@"effect"];[self.navigation perform:rest]; }
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
    if(handler!=noErr||RegisterEventHotKey(53,controlKey|optionKey,key,GetApplicationEventTarget(),0,&_exitHotkey)!=noErr)self.statusText=self.configured?@"Exit shortcut unavailable; quit with a key bound to quit or with Infinify msg action quit.":@"Exit shortcut unavailable; use the visible Quit button.";
}
- (void)stopExitKey { if(self.exitHotkey){UnregisterEventHotKey(self.exitHotkey);self.exitHotkey=NULL;}if(self.hotkeyHandler){RemoveEventHandler(self.hotkeyHandler);self.hotkeyHandler=NULL;} }
// A normal run's global hot keys: the config's bindings, then the exit chord unless one
// of them claimed it. Windowed mode registers none. Returns the chords macOS refused.
// The config's tap bindings are watched for exactly as long as its keys are registered.
- (NSArray<NSString *> *)startKeys {
    if(self.windowed)return @[];
    NSArray<NSString *> *refused=[self.hotKeys start];if(![self.hotKeys holds:exitChord()])[self configureExitKey];
    [self.tapKeys start];
    return refused;
}
- (void)stopKeys { [self.hotKeys stop];[self.tapKeys stop];[self stopExitKey]; }
// Upstream's binding lookup for one press or scroll: physical modifiers, trigger and
// context in; the bound gesture, or nil for none, out. The binding carries the config's
// pointer speeds.
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window { return [self mouseBinding:trigger source:source flags:flags window:window under:nil pick:NO]; }
// The lookup of a real press or scroll also names the window it is over, and says whether that window is a pick target.
// under: upstream's pass_mouse (src/input/pointer.rs: pass_mouse_claims, pass_mouse_claims_notch). Where that window's rule claims the
// trigger the controller answers {"binding": null, "passed": true}, and the trigger is unbound here exactly as it is there: nil, and the
// press or scroll goes on to the window. nil for a placeholder, which has no application to pass anything to.
// pick: that window is a pick target, as its hit says, and the lookup is upstream's below [zoom] interact_min (POINTER.md); it then
// claims nothing.
- (NSDictionary *)mouseBinding:(NSString *)trigger source:(NSString *)source flags:(NSEventModifierFlags)flags window:(BOOL)window under:(NSNumber *)under pick:(BOOL)pick {
    NSMutableDictionary *command=[@{@"op":@"mouse_binding",@"trigger":trigger,@"source":source?:NSNull.null,@"modifiers":modifiersJSON(flags),@"context":window?@"window":@"canvas",@"pick":pick?@YES:@NO}mutableCopy];if(under)command[@"window"]=under;
    NSDictionary *reply=[self call:command],*binding=asDict(reply[@"binding"]);
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
        NSArray<NSString *> *chords=found[kinds[i]];if(!chords)continue;
        NSString *both=chords[0].length&&chords[1].length&&![chords[0]isEqual:chords[1]]?[NSString stringWithFormat:@"%@ or %@",chords[0],chords[1]]:chords[0].length?chords[0]:chords[1];
        [parts addObject:[NSString stringWithFormat:@"%@: %@",both,words[i]]];
    }
    return parts;
}
// The status line's help: the chords this run answers to.
- (NSString *)helpLine {
    NSMutableArray<NSString *> *parts=[[self pointerHelp]mutableCopy];
    if(self.windowed){[parts insertObject:@"Windowed, no global shortcuts" atIndex:0];[parts addObject:@"Infinify msg: view, window and bookmark actions"];return [parts componentsJoinedByString:@" · "];}
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
    // A key that fires as a binding is a key on top of whatever modifier chord is held: that chord is no tap.
    if(!self.hotKeys){__weak Desktop *weak=self;self.hotKeys=[[DWHotKeys alloc]initWithFire:^(NSString *action){[weak.tapKeys taint];[weak action:action output:[weak viewOutput]];}];self.hotKeys.kept=exitChord();self.hotKeys.standinEnter=^dispatch_block_t{return [weak standInEnter];};self.hotKeys.nativeWindowControl=^dispatch_block_t(DWNativeWindowControl action){return [weak nativeWindowControlKey:action];};self.hotKeys.changed=^{Desktop *d=weak;NSArray<NSString *> *left=[d refreshBindings];for(NSString *line in left)fprintf(stderr,"%s\n",line.UTF8String);if(left.count){d.statusText=summary(@"Bindings",left);[d render];}};}
    // A tap binding's chord, completed, goes back to the controller as it came, to be looked up and run there. The output, the pointer and the modifiers
    // still down are those of the moment, as a hot key's: the release that completes a chord of two leaves one of them held.
    if(!self.tapKeys){__weak Desktop *weak=self;self.tapKeys=[[DWTapKeys alloc]initWithFire:^(NSDictionary *tap){NSDictionary *chord=asDict(tap[@"modifiers"]);if(chord)[weak action:asString(tap[@"action"]) output:[weak viewOutput] at:pointer() held:[DWCycleHold modifiersDown]!=0 corner:nil tap:chord];}];}
    BOOL open=self.panels.count!=0;if(open)[self stopKeys];
    [self.hotKeys setBindings:bindings];[self.tapKeys setBindings:bindings];
    // INFINIFY_DEBUG: which key bindings run here, and so are registered as hot keys in a run that registers any, and which stay with the applications.
    if(DWInputTrace()){NSMutableArray<NSString *> *run=[NSMutableArray array],*inert=[NSMutableArray array];
        for(id entry in asArray(bindings[@"keys"])){NSDictionary *key=asDict(entry);if(asString(key[@"action"]))[([asNumber(key[@"implemented"])isEqual:@NO]?inert:run) addObject:[NSString stringWithFormat:@"%@=%@",asString(key[@"combo"])?:@"?",key[@"action"]]];}
        fprintf(stderr,"debug: key bindings that run here: %s\ndebug: key bindings that do not run here: %s\n",[run componentsJoinedByString:@"; "].UTF8String,[inert componentsJoinedByString:@"; "].UTF8String);}
    [notes addObjectsFromArray:self.hotKeys.notes];
    // Upstream's cycle_hold as the controller reports it, else as upstream derives it: the modifiers of the cycle-windows forward binding, Option when it has none.
    NSDictionary *hold=asDict(bindings[@"cycle_hold"]);UInt32 mask=([hold[@"control"]isEqual:@YES]?controlKey:0)|([hold[@"option"]isEqual:@YES]?optionKey:0)|([hold[@"shift"]isEqual:@YES]?shiftKey:0)|([hold[@"command"]isEqual:@YES]?cmdKey:0);
    if(!mask)for(NSDictionary *key in self.hotKeys.keys)if([key[@"action"]isEqual:@"cycle-windows forward"]){mask=[key[@"chord"]unsignedIntValue]&(controlKey|optionKey|shiftKey|cmdKey);break;}
    self.cycleModifiers=mask?:optionKey;
    [self refreshGestureFingers];
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
// What the file itself has wrong, the load's errors and warnings, is shown where upstream shows it and nowhere else: in the
// error bar, which the compositor draws from the controller's own message (snapshot.render.errors). Here those lines go to
// stderr and never to the status line. The status line keeps what the bar does not show: a --super chord or a load the
// controller refused (`problems`), and the bindings that were left out.
- (void)loadConfig:(BOOL)platform {
    NSMutableArray<NSString *> *problems=[NSMutableArray array],*file=[NSMutableArray array];
    if(platform&&![self call:@{@"op":@"set_platform",@"super":self.superChord?:@"ctrl+alt"}])[problems addObject:self.statusText?:@"set_platform failed"];
    NSDictionary *loaded=[self call:@{@"op":@"load_config",@"path":self.configPath?:NSNull.null}];if(!loaded)[problems addObject:self.statusText?:@"load_config failed"];
    // A reload can change what is saved (config bookmarks); the launch load precedes the scene and saves nothing.
    if(!platform&&[loaded[@"dirty"]isEqual:@YES])[self saveScene];
    // The launch load's effects are the config's autostart commands: kept for main() to run once. A reload's are never looked at.
    if(platform)self.autostart=asArray(loaded[@"effects"]);
    for(NSString *key in @[@"errors",@"warnings"])for(id message in asArray(loaded[key]))if(asString(message))[file addObject:message];
    // The reply lists a load's warnings in the parser's order, which for a hash-mapped table differs between two loads of one file. They are
    // printed in byte order, the order the controller picks the bar's one line in, so the first line is the one the bar names at every load.
    [file sortUsingComparator:^NSComparisonResult(NSString *a,NSString *b){int order=strcmp(a.UTF8String,b.UTF8String);return order<0?NSOrderedAscending:order>0?NSOrderedDescending:NSOrderedSame;}];
    NSString *path=asString(loaded[@"path"])?:self.configPath;NSArray<NSString *> *left=[self refreshBindings],*all=[problems arrayByAddingObjectsFromArray:left];
    for(NSArray<NSString *> *lines in @[problems,file,left])for(NSString *line in lines)fprintf(stderr,"%s\n",line.UTF8String);
    NSString *note=all.count?summary(problems.count?[@"Config " stringByAppendingString:(path?:@"").stringByAbbreviatingWithTildeInPath]:@"Bindings",all):nil;
    self.configNote=problems.count?note:nil;self.statusText=note?:[self restingStatus];
    if(!self.configWatcher){__weak Desktop *weak=self;self.configWatcher=[[DWConfigWatcher alloc]initWithChanged:^{[weak loadConfig:NO];}];}
    [self.configWatcher watch:path];[self render];
}
- (NSDictionary *)call:(NSDictionary *)command { return [self call:command raw:NULL]; }
// raw receives the controller's own response bytes.
- (NSDictionary *)call:(NSDictionary *)command raw:(NSData *__autoreleasing *)raw {
    // These four queries execute on &self before the controller's transaction
    // clone. Every other request invalidates the cache BEFORE it can change
    // state. Retain one immutable decoded snapshot, without raw bytes.
    BOOL snapshot=command.count==1&&[command[@"op"]isEqual:@"snapshot"];
    if(snapshot&&!raw&&self.controllerSnapshot)return self.controllerSnapshot;
    NSString *operation=asString(command[@"op"]);
    BOOL query=snapshot||[operation isEqual:@"hit"]||[operation isEqual:@"input"]||[operation isEqual:@"resize_border"]||[operation isEqual:@"gesture_fingers"];
    BOOL tick=[operation isEqual:@"tick_navigation"];
    NSDictionary *before=tick?self.controllerSnapshot:nil,*visual=tick?self.controllerVisualSnapshot:nil;
    if(!query){self.controllerSnapshot=nil;self.controllerVisualSnapshot=nil;}
    NSData *request=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"command":command} options:0 error:nil];
    char *response=driftwm_desktop_request(self.controller,request.bytes,request.length);if(!response){self.statusText=@"Controller unavailable";return nil;}
    NSData *data=[NSData dataWithBytes:response length:strlen(response)];driftwm_desktop_response_free(response);if(raw)*raw=data;
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![reply[@"ok"]boolValue]){self.statusText=reply[@"error"]?:@"Controller error";return nil;}
    NSDictionary *result=asDict(reply[@"data"]); // every controller reply is an object; a null or other JSON value is no reply
    if(DWInputTrace()){
        NSMutableArray *effects=[asArray(result[@"effects"])mutableCopy]?:[NSMutableArray array];
        if(asDict(result[@"effect"]))[effects addObject:result[@"effect"]];
        for(NSDictionary *effect in effects)if([effect[@"op"]isEqual:@"observe_resize_source"]||[effect[@"op"]isEqual:@"resize_native_window"]){
            id ipc=command[@"request"];NSString *variant=asString(ipc)?:asDict(ipc).allKeys.firstObject?:@"none";
            NSString *action=asString(command[@"action"])?:asString(asDict(ipc)[@"Action"]);
            if(![@[@"toggle-fullscreen",@"fullscreen",@"fill",@"restore",@"center",@"fit"]containsObject:action?:@""])action=@"other";
            fprintf(stderr,"debug: native resize origin operation=%s ipc=%s action=%s transaction=%llu effect=%llu window=%llu\n",operation.UTF8String,variant.UTF8String,action.UTF8String,[effect[@"transaction"]unsignedLongLongValue],[effect[@"effect_id"]unsignedLongLongValue],[effect[@"window"]unsignedLongLongValue]);
        }
    }
    // set-trackpad switches every gesture off or on: the finger counts the system's own gestures are held back for follow it. A key, a gesture, a corner or `msg action` may run it.
    if(self.dockGuard&&!query){NSString *ran=asString(command[@"action"])?:asString(asDict(command[@"request"])[@"Action"])?:asString(asDict(result[@"fired"])[@"action"]);if([ran hasPrefix:@"set-trackpad"])[self refreshGestureFingers];}
    if(snapshot){self.controllerSnapshot=result;if(!self.controllerVisualSnapshot)self.controllerVisualSnapshot=result;}
    else if(tick&&[result[@"clock_only"]isEqual:@YES]){
        // This successful tick changed only clock_ns. Never mutate a retained
        // dictionary: ordinary Snapshot readers see the current clock, while
        // rendering/capture keep the same proven-unchanged geometry projection.
        if(before){NSMutableDictionary *next=[before mutableCopy],*navigation=[asDict(before[@"navigation"])mutableCopy];navigation[@"clock_ns"]=command[@"timestamp_ns"];next[@"navigation"]=navigation.copy;self.controllerSnapshot=next.copy;}
        self.controllerVisualSnapshot=visual;
    }
    return result;
}
// One upstream Request line from a client in, one upstream Reply line out, on the main
// queue. Every refusal is an {"Err":…} line; an answer is the controller's own bytes.
// Before the canvas opens there is no active output and the controller says so itself;
// after Return to desktop the shell is inert, and a failed load must not take changes.
// The controller answers Subscribe with a subscribe effect carrying the current
// State event: the connection is then kept, and that line follows the ack.
- (NSData *)ipcLine:(NSData *)line subscribe:(BOOL *)subscribe event:(NSData *__autoreleasing *)event deferred:(void (^)(NSData *))deferred {
    if(self.cleaning)return ipcError(@"the canvas is closed");
    if(self.startupError)return ipcError(self.startupError);
    // A request that arrives during a sizing action's transaction is the controller's to answer, as an action is.
    id request=[NSJSONSerialization JSONObjectWithData:line options:NSJSONReadingFragmentsAllowed error:nil];
    if([self nativeUnavailable]){
        // Keep inspection/subscription and quitting available, but refuse scene
        // mutations rather than answer success while no native frame can apply.
        NSDictionary *object=asDict(request);
        BOOL read=[request isEqual:@"State"]||[request isEqual:@"DebugCounters"]||[request isEqual:@"Subscribe"]||object[@"Layout"];
        BOOL debug=self.debugPointer&&(asDict(object[@"DebugNative"])||asDict(object[@"DebugCapture"]));
        BOOL quit=[object[@"Action"]isEqual:@"quit"];
        if(!read&&!debug&&!quit)return ipcError(@"native presentation is restoring or reconnecting; retry when ready");
    }
    if(self.screenshotBusy&&asDict(asDict(request)[@"Screenshot"]))return ipcError(@"another screenshot is preparing");
    // Without --debug-pointer the line goes on to the controller, which knows no such request and refuses it.
    if(self.debugPointer&&asDict(asDict(request)[@"DebugPointer"]))return [self debugPointer:asDict(request)[@"DebugPointer"]];
    if(self.debugPointer&&self.native&&asDict(asDict(request)[@"DebugDecoration"]))return [self debugDecoration:asDict(request)[@"DebugDecoration"]];
    // {"DebugNative":{}} with --debug-pointer under native presentation: what was sent to the helper and what the helper says it holds.
    if(self.debugPointer&&self.native&&asDict(asDict(request)[@"DebugNative"]))return [self.native debug:asDict(request)[@"DebugNative"]];
    if(self.debugPointer&&asDict(asDict(request)[@"DebugCapture"]))return [self debugCapture:asDict(request)[@"DebugCapture"]];
    NSDictionary *command=request?@{@"op":@"ipc",@"output":[self viewOutput]?:NSNull.null,@"request":request,@"pointer":pointJSON(pointer())}:nil;
    if(!command||![NSJSONSerialization isValidJSONObject:command])return ipcError(@"invalid request");
    NSString *status=self.statusText;NSData *raw=nil;NSDictionary *data=[self call:command raw:&raw];
    // Screenshot is answered in two steps: the controller's reply is null and names the
    // capture as an effect, the compositor renders it offscreen and writes the PNG, and
    // what screenshot_result returns for the outcome is the client's reply.
    NSDictionary *capture=nil;if(data&&!asDict(data[@"reply"]))for(id effect in asArray(data[@"effects"]))if([asString(asDict(effect)[@"op"])isEqual:@"screenshot"])capture=effect;
    if(capture){
        self.screenshotBusy=YES;NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
        [self prepareScreenshot:capture completed:^(NSString *preparation){
            if(self.cleaning){self.exportSources=nil;self.exportAttachments=nil;self.exportOrdering=nil;self.screenshotBusy=NO;deferred(ipcError(@"screenshot cancelled during shutdown"));return;}
            void (^finish)(NSDictionary *)=^(NSDictionary *rendered){
                self.exportSources=nil;self.exportAttachments=nil;self.exportOrdering=nil;self.screenshotBusy=NO;
                if(self.cleaning){deferred(ipcError(@"screenshot cancelled during shutdown"));return;}
                NSMutableDictionary *result=[rendered mutableCopy];result[@"op"]=@"screenshot_result";
                NSData *response=nil;NSDictionary *answered=[self call:result raw:&response];
                if(!asDict(answered[@"reply"])){NSString *error=answered?@"invalid controller reply":self.statusText?:@"controller error";self.statusText=status;deferred(ipcError(error));return;}
                [self applyReply:data];
                deferred(jsonMember(jsonMember(response,"data"),"reply")?:[NSJSONSerialization dataWithJSONObject:answered[@"reply"] options:NSJSONWritingWithoutEscapingSlashes error:nil]);
            };
            DWCanvasRenderer *renderer=[self canvasRenderer];
            if(preparation||!renderer)finish(@{@"error":preparation?:@"no renderer available for capture"});
            else [renderer screenshot:capture snapshot:snapshot completed:finish];
        }];
        return nil;
    }
    // A controller-level refusal still answers the client and leaves the status line alone.
    if(!asDict(data[@"reply"])){NSString *error=data?@"invalid controller reply":self.statusText?:@"controller error";self.statusText=status;return ipcError(error);}
    [self applyReply:data];
    for(id effect in asArray(data[@"effects"])){NSString *first=asString(asDict(effect)[@"line"]);if([asDict(effect)[@"op"]isEqual:@"subscribe"]&&first){*subscribe=YES;*event=[first dataUsingEncoding:NSUTF8StringEncoding];}}
    // That snapshot is the current State. The broadcast is brought up to it before the connection joins:
    // earlier subscribers get a change not yet sent to them, and the new one is not sent its snapshot twice.
    if(*subscribe)[self broadcastState];
    return jsonMember(jsonMember(raw,"data"),"reply")?:[NSJSONSerialization dataWithJSONObject:data[@"reply"] options:NSJSONWritingWithoutEscapingSlashes error:nil];
}
// --debug-pointer, which needs --only-pid: a press, a drag and a release on a managed window, for a test that cannot move the pointer.
// Scoped handler exercise only: the read-only probe returns the actual AX green
// control projected through fresh native bounds. A click calls the native bridge
// directly, posts no event and is not evidence of WindowServer input delivery.
- (NSData *)debugDecoration:(NSDictionary *)request {
    if(!self.scope||self.native.ended)return ipcError(@"DebugDecoration needs a live --native-helper and an explicit --only-pid scope");
    NSString *phase=asString(request[@"phase"]),*action=asString(request[@"action"])?:@"fullscreen";
    if(![@[@"probe",@"click"]containsObject:phase]||![@[@"fullscreen",@"fit"]containsObject:action])return ipcError(@"DebugDecoration needs phase probe or click and action fullscreen or fit");
    NSNumber *logical=asNumber(request[@"window"]);if(!logical)return ipcError(@"DebugDecoration needs a window id");
    LiveSource *source=self.sources[logical];if(!source||source.detached||!DWInScope(self.scope,source.router.pid))return ipcError(@"DebugDecoration needs an exact bound source in the scope");
    [self refreshNativeButtons:source];
    if(!source.nativeButtons)return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugDecoration":@{@"ready":@NO}}} options:0 error:nil];
    NSDictionary *info=windowInfo(source.router.wid);CGRect displayed=CGRectZero,own=CGRectZero;
    if(!info[(id)kCGWindowBounds]||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&displayed)||!DWNativeBounds(source.router.wid,&own))return ipcError(@"DebugDecoration bounds are unavailable");
    NSDictionary *button=[asArray(source.nativeButtons[@"buttons"])firstObject];if(!button)return ipcError(@"this source exposes no enabled native green control");
    CGRect local=jsonRect(button);CGPoint point=CGPointMake(displayed.origin.x+CGRectGetMidX(local)*displayed.size.width/own.size.width,displayed.origin.y+CGRectGetMidY(local)*displayed.size.height/own.size.height);
    if(![self nativeGreen:source at:point])return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugDecoration":@{@"ready":@NO}}} options:0 error:nil];
    NSNumber *output=nil;NSDictionary *hit=nil;for(DesktopView *view in self.views)if(CGRectContainsPoint(view.globalBounds,point)){output=[view outputAt:point];if(output)hit=[view hit:point output:output];break;}
    BOOL eligible=[hit[@"window"]isEqual:source.logical]&&![hit[@"pick"]boolValue]&&![hit[@"widget"]boolValue]&&[self nativeSource:source.router.wid at:point]==source;
    if(!eligible)return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugDecoration":@{@"ready":@NO,@"screen":@[@(point.x),@(point.y)],@"output":output?:NSNull.null,@"canvas_hit":hit?:NSNull.null}}} options:0 error:nil];
    if([phase isEqual:@"click"]){
        if(self.nativeGestureView||self.nativeScrollView)return ipcError(@"another native input sequence is active");
        CGEventRef down=CGEventCreateMouseEvent(source.router.eventSource,kCGEventLeftMouseDown,point,kCGMouseButtonLeft),up=CGEventCreateMouseEvent(source.router.eventSource,kCGEventLeftMouseUp,point,kCGMouseButtonLeft);
        if(!down||!up){if(down)CFRelease(down);if(up)CFRelease(up);return ipcError(@"DebugDecoration could not create its private handler events");}
        CGEventFlags flags=[action isEqual:@"fit"]?kCGEventFlagMaskAlternate:0;
        for(int i=0;i<2;i++){CGEventRef event=i?up:down;CGEventSetFlags(event,flags);CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer,source.router.wid);CGEventSetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,source.router.wid);}
        BOOL consumed=[self nativeInput:kCGEventLeftMouseDown event:down],taken=consumed&&self.nativeDecorationPress!=nil;
        BOOL released=taken&&[self nativeInput:kCGEventLeftMouseUp event:up];
        NSString *why=nil;if(!taken||!released){NSMutableArray *grabs=[NSMutableArray array];for(DesktopView *view in self.views)[grabs addObject:@(view.gesture)];NSEvent *made=[NSEvent eventWithCGEvent:down];CGPoint after=CGEventGetLocation(down);
            why=[NSString stringWithFormat:@"the native bridge refused the green-control button pair (consumed=%d captured=%d released=%d wid=%lld type=%lu button=%lld flags=%lx point=%g,%g grabs=%@ green=%d source=%d inactive=%d)",consumed,taken,released,(long long)CGEventGetIntegerValueField(down,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent),(unsigned long)made.type,(long long)CGEventGetIntegerValueField(down,kCGMouseEventButtonNumber),(unsigned long)made.modifierFlags,after.x,after.y,grabs,[self nativeGreen:source at:after],[self nativeSource:source.router.wid at:after]==source,self.sessionInactive];}
        CFRelease(down);CFRelease(up);if(why){[self cancelNativeInput];return ipcError(why);}
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugDecoration":@{@"ready":@YES,@"screen":@[@(point.x),@(point.y)],@"window":source.logical,@"identity":source.identity,@"native_buttons":source.nativeButtons,@"handler_only":@YES}}} options:NSJSONWritingWithoutEscapingSlashes error:nil];
}
// {"DebugPointer":{"phase":"probe"|"down"|"drag"|"up","window":ID,"at":[fx,fy],"offset":[ox,oy],"button":"left"|"right"|"middle",
// "modifiers":["alt","shift","ctrl","super"],"to":[dx,dy]}}.
// down: the point is that fraction of the window's placement on its output, plus `offset` screen points when one is given, which is
// how a point of the resize border just outside the frame is named. `button` (left when absent) and `modifiers` are the event's.
// drag: needs a press that is down; the point is where that press went down plus `to` screen points (a fraction of a tile that is
// changing size names no steady point), and it must be on the canvas panel. up: with `window` and `at`, the release goes to that
// fraction of the window's placement as it is now; without them, to where the press last was, which is how a drag ends and the only
// way to release over a window that has closed.
// Nothing is posted anywhere and the pointer stays where it is: an NSEvent of the matching type is made and handed to the view's own
// -mouseDown:, -mouseDragged: or -mouseUp: (the right and middle buttons' equivalents for those), so everything a person's press,
// drag and release run from there on runs: the binding lookup, the controller's focus request, the hold for native focus, the
// forward to the window, a window drag, a resize grab with every size it asks, the release. Those handlers read the event's button
// number, modifiers, location and time, all of which the made event carries; its CGEvent is read only where a press is forwarded to
// a window. What this does not exercise is the window server delivering a click or a drag to the panel. A point that is clipped,
// off the panel or under another window is refused, never moved. `probe` only answers where the point is and what is under it.
- (void)injected:(DesktopView *)view phase:(int)phase {
    static const NSEventType types[3][3]={{NSEventTypeLeftMouseDown,NSEventTypeRightMouseDown,NSEventTypeOtherMouseDown},{NSEventTypeLeftMouseDragged,NSEventTypeRightMouseDragged,NSEventTypeOtherMouseDragged},{NSEventTypeLeftMouseUp,NSEventTypeRightMouseUp,NSEventTypeOtherMouseUp}};
    NSInteger b=view.injectedButton;CGPoint s=view.injectedPoint;
    NSEvent *e=[NSEvent mouseEventWithType:types[phase][b] location:[view convertPoint:CGPointMake(s.x-view.globalBounds.origin.x,s.y-view.globalBounds.origin.y) toView:nil] modifierFlags:view.injectedFlags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:phase==2?0:1];
    // +mouseEventWithType: has no button parameter and numbers every event it makes 0, a right or middle one too, where the event of a
    // real right or middle button says 1 or 2 and the handlers go by that number. So the event's own Quartz event is copied, given the
    // number its type means, and made an NSEvent again: still posted nowhere, with the same window, location, modifiers and time.
    if(b&&e.buttonNumber!=b){CGEventRef cg=e.CGEvent?CGEventCreateCopy(e.CGEvent):NULL;if(cg){CGEventSetIntegerValueField(cg,kCGMouseEventButtonNumber,b);NSEvent *numbered=[NSEvent eventWithCGEvent:cg];CFRelease(cg);if(numbered)e=numbered;}}
    if(phase==0){if(b==0)[view mouseDown:e];else if(b==1)[view rightMouseDown:e];else [view otherMouseDown:e];}
    else if(phase==1){if(b==0)[view mouseDragged:e];else if(b==1)[view rightMouseDragged:e];else [view otherMouseDragged:e];}
    else{if(b==0)[view mouseUp:e];else if(b==1)[view rightMouseUp:e];else [view otherMouseUp:e];}
}
// A press its test never released is let go where it last was, five seconds after its last event, with the button it went down with.
- (void)armInjected:(DesktopView *)view {
    [view.injectedTimer invalidate];__weak DesktopView *weak=view;__weak Desktop *desktop=self;
    view.injectedTimer=[NSTimer timerWithTimeInterval:5 repeats:NO block:^(NSTimer *timer){(void)timer;DesktopView *v=weak;if(!v.injected)return;v.injected=NO;v.injectedTimer=nil;[desktop injected:v phase:2];}];
    [NSRunLoop.mainRunLoop addTimer:view.injectedTimer forMode:NSRunLoopCommonModes];
}
- (NSData *)debugCapture:(NSDictionary *)request {
    NSNumber *window=asNumber(request[@"window"]);if(!window)return ipcError(@"DebugCapture needs a window id");
    LiveSource *source=self.sources[window];NSString *phase=asString(request[@"phase"]);
    if(!source||source.detached||source.synth||!self.scope||!DWInScope(self.scope,source.router.pid)||sourceGone(source,windowInfo(source.router.wid)))return ipcError(@"DebugCapture requires a currently bound capture from --only-pid");
    // A native replica can report its capture lifecycle, but interrupting it
    // would change representation during an ownership transfer. Status is only
    // a diagnostic snapshot, never native placement or input authorization.
    if(self.native&&![phase isEqual:@"status"])return ipcError(@"Native replica DebugCapture is read-only; use phase status");
    if([phase isEqual:@"interrupt"]){
        if(!source.stream)return ipcError(@"that window has no active capture stream");
        [self stopCapture:source];[source captureFailed:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorSystemStoppedStream userInfo:@{NSLocalizedDescriptionKey:@"Scoped diagnostic interrupted this capture stream"}]];
    }else if(![phase isEqual:@"status"])return ipcError(@"DebugCapture needs phase status or interrupt");
    NSMutableArray *replicas=[NSMutableArray array];for(NSDictionary *output in self.pointerOutputs)if([self.nativeViews replica:source.logical output:output[@"id"]])[replicas addObject:output[@"id"]];
    return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugCapture":@{@"window":source.logical,@"identity":source.identity,@"native_family":source.nativeFamily?:NSNull.null,@"stream":@(source.stream!=nil),@"shareable":@(source.window!=nil),@"pixels":@(source.pixels!=NULL),@"capture_restarted":@(source.restarted),@"captured_frames":@(source.frames),@"mailbox":source.captureMailbox.diagnosticSnapshot?:NSNull.null,@"session_inactive":@(self.sessionInactive),@"capture_updating":@(source.captureUpdating),@"configuration":source.captureConfigurationStatus?:NSNull.null,@"native_replica":@(source.nativeReplica),@"replica_wanted":@(source.replicaWanted),@"described_replica_outputs":replicas,@"screen_capture_access":@(CGPreflightScreenCaptureAccess()),@"recovering":@(source.captureRecovering),@"failures":@(source.captureFailures),@"accepted":@(source.accepted),@"retry_in":@(MAX(0,source.captureRetryAt-CACurrentMediaTime())),@"reading":@(self.captureRecoveryReading),@"error":source.error?:NSNull.null}}} options:0 error:nil];
}
- (NSData *)debugPointer:(NSDictionary *)request {
    NSString *phase=asString(request[@"phase"]),*status=self.statusText;NSNumber *window=asNumber(request[@"window"]);NSArray *at=asArray(request[@"at"]),*offset=request[@"offset"]?asArray(request[@"offset"]):nil,*to=asArray(request[@"to"]);
    double fx=at.count==2?[asNumber(at[0])?:@(-1) doubleValue]:-1,fy=at.count==2?[asNumber(at[1])?:@(-1) doubleValue]:-1;
    BOOL up=[phase isEqual:@"up"],drag=[phase isEqual:@"drag"],placed=window&&fx>=0&&fx<=1&&fy>=0&&fy<=1;
    if(![@[@"probe",@"down",@"drag",@"up"]containsObject:phase]||(!drag&&!up&&!placed)||(up&&(window||at.count)&&!placed))return ipcError(@"DebugPointer needs phase probe, down, drag or up; for probe and down a window id and at [fx, fy] within 0 and 1; for drag to [dx, dy]");
    if(drag||(up&&!placed)){
        DesktopView *view=nil;for(DesktopView *v in self.views)if(v.injected)view=v;
        if(!view)return ipcError(@"no DebugPointer press is down");
        if(drag){
            if(to.count!=2||!asNumber(to[0])||!asNumber(to[1]))return ipcError(@"DebugPointer drag needs to [dx, dy], screen points from where the press went down");
            CGPoint s=CGPointMake(view.injectedStart.x+[to[0]doubleValue],view.injectedStart.y+[to[1]doubleValue]);
            if(!CGRectContainsPoint(view.globalBounds,s))return ipcError(@"that point is not on the canvas");
            view.injectedPoint=s;[self injected:view phase:1];[self armInjected:view];
        }else{[view.injectedTimer invalidate];view.injectedTimer=nil;view.injected=NO;[self injected:view phase:2];}
        return [NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugPointer":@{@"screen":@[@(view.injectedPoint.x),@(view.injectedPoint.y)]}}} options:NSJSONWritingWithoutEscapingSlashes error:nil];
    }
    NSString *named=asString(request[@"button"])?:@"left";NSUInteger button=[@[@"left",@"right",@"middle"]indexOfObject:named];NSEventModifierFlags flags=0;
    if(button==NSNotFound||(request[@"button"]&&!asString(request[@"button"])))return ipcError(@"DebugPointer button is left, right or middle");
    for(id name in asArray(request[@"modifiers"])){NSNumber *flag=@{@"alt":@(NSEventModifierFlagOption),@"shift":@(NSEventModifierFlagShift),@"ctrl":@(NSEventModifierFlagControl),@"super":@(NSEventModifierFlagCommand)}[asString(name)?:@""];if(!flag)return ipcError(@"DebugPointer modifiers are alt, shift, ctrl and super");flags|=flag.unsignedIntegerValue;}
    if(offset&&(offset.count!=2||!asNumber(offset[0])||!asNumber(offset[1])))return ipcError(@"DebugPointer offset is [ox, oy], screen points");
    NSDictionary *placement=nil;for(NSDictionary *p in [self call:@{@"op":@"snapshot"}][@"placements"])if([p[@"window"]isEqual:window]){placement=p;break;}
    DesktopView *view=nil;for(DesktopView *v in self.views)if([v.outputs containsObject:placement[@"output"]])view=v;
    if(!placement||!view)return ipcError(@"that window has no placement on an output");
    CGRect rect=jsonRect(placement[@"screen_rect"]),clip=jsonRect(placement[@"clip_rect"]);CGPoint s=CGPointMake(rect.origin.x+fx*rect.size.width+(offset?[offset[0]doubleValue]:0),rect.origin.y+fy*rect.size.height+(offset?[offset[1]doubleValue]:0));
    if((!offset&&!CGRectContainsPoint(clip,s))||!CGRectContainsPoint(view.globalBounds,s))return ipcError(@"that point of the window is not on the canvas");
    // A release is not asked what lies under it: it goes to the same fraction of the window's placement as it is now, whatever has come over that point since.
    NSDictionary *hit=up?nil:asDict([view hit:s output:placement[@"output"]]);
    // A point named by an offset is one of the window's resize border, or of the window itself: the controller says which.
    NSDictionary *border=!up&&offset&&!hit?asDict([view pointerCommand:@{@"op":@"resize_border",@"output":placement[@"output"],@"screen":pointJSON(s)} quiet:YES][@"border"]):nil;self.statusText=status;
    if(!up&&![hit[@"window"]isEqual:window]&&![border[@"window"]isEqual:window])return ipcError(hit?[NSString stringWithFormat:@"window #%@ is under that point",hit[@"window"]]:border?[NSString stringWithFormat:@"the resize border of window #%@ is under that point",border[@"window"]]:@"no window takes a press at that point");
    NSData *reply=[NSJSONSerialization dataWithJSONObject:@{@"Ok":@{@"DebugPointer":@{@"screen":@[@(s.x),@(s.y)],@"screen_rect":placement[@"screen_rect"],@"clip_rect":placement[@"clip_rect"],@"hit":up||!hit?NSNull.null:hit[@"window"],@"border":border?border[@"edges"]:NSNull.null}}} options:NSJSONWritingWithoutEscapingSlashes error:nil];
    if([phase isEqual:@"probe"])return reply;
    if(up?!view.injected:(view.gesture||view.injected))return ipcError(up?@"no DebugPointer press is down":@"a press is already down");
    [view.injectedTimer invalidate];view.injectedTimer=nil;
    if(up){view.injected=NO;view.injectedPoint=s;[self injected:view phase:2];return reply;}
    view.injected=YES;view.injectedPoint=view.injectedStart=s;view.injectedButton=(NSInteger)button;view.injectedFlags=flags;[self injected:view phase:0];
    [self armInjected:view];
    return reply;
}
// Normal runs only: main() starts the server once and stops it before the final cleanup.
- (BOOL)startIPC:(NSString *)path {
    __weak Desktop *weak=self;NSString *error=nil;
    self.ipc=[DWIPCServer serverAtPath:path asyncHandler:^(NSData *line,DWIPCReply completed){
        Desktop *desktop=weak;if(!desktop){completed(nil,NO,nil);return;}
        BOOL subscribe=NO;NSData *event=nil,*reply=[desktop ipcLine:line subscribe:&subscribe event:&event deferred:^(NSData *response){completed(response,NO,nil);}];
        if(reply)completed(reply,subscribe,event);
    } error:&error];
    if(!self.ipc){fprintf(stderr,"Infinify: cannot start IPC: %s (%s)\n",error.UTF8String,path.fileSystemRepresentation);return NO;}
    self.socketPath=path;return YES;
}
- (BOOL)loadScene:(NSString *)path {
    [self.sceneWriter drain];
    [self cancelNavigation];[self.resize cancel];if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize must settle before loading";return NO;}
    self.statePath=path;
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return YES;
    if([self call:@{@"op":@"load",@"path":path}])return YES;
    self.startupError=[NSString stringWithFormat:@"Saved scene could not be loaded: %@. Original file preserved. Quit and repair it, or restart with --state and a different path.",self.statusText];
    // Every save path, including quit and Return to desktop, is disabled.
    self.statePath=nil;return NO;
}
- (void)saveScene {
    if(self.sessionAwaitingCanvas)return;
    if(!self.statePath)return;
    if(self.configured&&!self.cleaning){
        if(!self.sceneWriter){self.sceneWriter=[DWSceneWriter new];__weak Desktop *weak=self;
            self.sceneWriter.failed=^(NSString *reason){Desktop *desktop=weak;if(!desktop||desktop.cleaning)return;desktop.sceneDirty=YES;desktop.statusText=reason;};}
        if([self.sceneWriter submit:self.controller path:self.statePath])self.sceneDirty=NO;
        else {self.sceneDirty=YES;self.statusText=@"Scene save could not prepare an independent controller copy";}
        return;
    }
    // Shutdown/probes keep synchronous completion. Drain older snapshots first
    // so they cannot overwrite the final scene after its atomic commit.
    [self.sceneWriter drain];
    if([self call:@{@"op":@"save",@"path":self.statePath}])self.sceneDirty=NO;
}
- (void)forgetNativeFamily:(LiveSource *)source {
    if(source.nativeFamily){if(self.captureBackings[source.logical])[self revokeCaptureBackingForWindow:source.logical];source.nativeFamily=nil;self.nativeFamilyRevision++;}
}
- (NSDictionary *)nativeFillBackground:(NSDictionary *)snapshot {
    NSDictionary *held=self.nativeFillHandoff,*prior=held[@"background"];
    if(!prior.count||!self.nativeFillRoot||self.nativeFillAnimated||self.nativeFillResuming||[held[@"bridge_failed"]boolValue])return snapshot;
    void (^trace)(NSString *,NSDictionary *)=^(NSString *reason,NSDictionary *counts){
        if(!DWInputTrace())return;NSArray *entry=@[held[@"transaction"],reason,counts];if([self.nativeFillBackgroundTrace isEqual:entry])return;
        self.nativeFillBackgroundTrace=entry;NSData *encoded=[NSJSONSerialization dataWithJSONObject:counts options:0 error:nil];
        fprintf(stderr,"debug: native transition background window=#%s transaction=%llu reason=%s counts=%s time=%.6f\n",[held[@"window"]description].UTF8String,[held[@"transaction"]unsignedLongLongValue],reason.UTF8String,[[NSString alloc]initWithData:encoded encoding:NSUTF8StringEncoding].UTF8String,CACurrentMediaTime());
    };
    if(![self nativeFillCurrent:held snapshot:snapshot]){trace(@"handoff_changed",@{});return snapshot;}
    NSDictionary *oldOutput=nil;for(NSDictionary *row in prior[@"outputs"])if([row[@"id"]isEqual:held[@"output"]]){oldOutput=row;break;}
    // Fullscreen deliberately rounds its parked camera and sets zoom to one.
    // Keep the prior SCREEN placements across that logical change; requiring
    // the old camera/zoom to equal the parked view discarded every scaled hold.
    // nativeFillCurrent above still fences any later parked-view change.
    if(!oldOutput||![oldOutput[@"screen_bounds"]isEqual:held[@"screen_bounds"]]){trace(@"output_changed",@{});return snapshot;}
    NSMutableDictionary *before=[NSMutableDictionary dictionary],*now=[NSMutableDictionary dictionary];
    for(NSDictionary *row in prior[@"windows"])if(row[@"window"])before[row[@"window"]]=row;
    for(NSDictionary *row in snapshot[@"windows"])if(row[@"window"])now[row[@"window"]]=row;
    NSMutableArray *placements=[asArray(snapshot[@"placements"])mutableCopy];NSMutableSet *placed=[NSMutableSet set];
    for(NSDictionary *row in placements)if(row[@"window"])[placed addObject:row[@"window"]];
    NSUInteger excluded=0,changedSource=0,changedWindow=0,retained=0;
    for(NSDictionary *placement in prior[@"placements"]){
        NSNumber *window=placement[@"window"];NSDictionary *old=before[window],*current=now[window],*source=asDict(current[@"source"]);LiveSource *live=self.sources[window];
        if(!window||[window isEqual:held[@"window"]]||[placed containsObject:window]||![placement[@"output"]isEqual:held[@"output"]]){excluded++;continue;}
        if(!old||!current||!live||live.detached||live.nativeMouseOwnership||!boundIdentity(source[@"identity"],live.identity)
            ||![source isEqual:placement[@"source"]]){changedSource++;continue;}
        BOOL pinned=[placement[@"pinned"]boolValue]&&asDict(old[@"pinned"]);
        BOOL same=YES;for(NSString *key in @[@"source",@"world_rect",@"pinned",@"widget",@"mode",@"kind"]){
            // A pin's world rectangle follows the parked camera; its exact
            // output/screen pin descriptor is the physical projection basis.
            if(pinned&&[key isEqual:@"world_rect"])continue;
            if(![(old[key]?:NSNull.null)isEqual:current[key]?:NSNull.null]){same=NO;break;}
        }
        if(same){[placements addObject:placement];[placed addObject:window];retained++;}else changedWindow++;
    }
    trace(@"projected",@{@"prior":@([prior[@"placements"]count]),@"current":@([snapshot[@"placements"]count]),@"retained":@(retained),@"excluded":@(excluded),@"changed_source":@(changedSource),@"changed_window":@(changedWindow)});
    if(placements.count==[snapshot[@"placements"]count])return snapshot;
    NSMutableDictionary *covered=[snapshot mutableCopy];covered[@"placements"]=placements.copy;return covered.copy;
}
- (NSDictionary *)nativeDescription:(NSDictionary *)snapshot {
    if(!self.native||!snapshot)return nil;
    if(!self.nativeViews)self.nativeViews=[DWNativeViews new];
    // Still experimental: fully off-screen parking froze Finder. The guarded
    // path requires an independently visible guarded lane for each no-owner root.
    BOOL backing=[self captureBackingEnabled];self.nativeViews.requiresNativeExtentFit=backing;
    BOOL enabled=!self.native.ended&&!self.sessionInactive&&!self.cleaning&&self.panels.count;
    if(!backing&&self.nativeViewSnapshot==snapshot&&self.nativeViewPresenter==self.native&&self.nativeViewFamilyRevision==self.nativeFamilyRevision&&self.nativeViewEnabled==enabled&&self.nativeViewTransferRevision==self.nativeViews.transferRevision&&self.nativeViews.presentationSnapshot)return enabled?[self nativeFillBackground:self.nativeOwnerSnapshot]:self.nativeOwnerSnapshot;
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
    if(backing)[self updateCaptureBacking:snapshot];
    // Preserve the already visible native background until the picture covers
    // its final extent. Recheck this uncached, presenter-only coverage on every
    // description; it creates no controller hit site or input authority.
    return enabled?[self nativeFillBackground:self.nativeOwnerSnapshot]:self.nativeOwnerSnapshot;
}
// Hover observes real mouse motion without taking it. Native reads, family
// discovery, rendering and placement requests all happen after the tap returns.
- (BOOL)nativeHoverAllowed {
    if(!self.native||self.nativeFillHandoff||self.native.ended||!self.configured||self.cleaning||self.sessionInactive
        ||NSEvent.pressedMouseButtons||self.globalTrackpad.hasNativeMousePress||self.globalTrackpad.ownsTouches
        ||self.nativeGestureView||self.pointerGrab.active||self.gestureOwner||self.trackpad.engaged
        ||self.globalGestureContact||self.magnifying||self.flying||self.frameFlying||self.compositor.hasGeometryTransitions)return NO;
    for(DesktopView *view in self.views)if(view.gesture||view.heldPress||view.pressedTablet)return NO;
    return YES;
}
- (BOOL)nativeOwnershipReady:(LiveSource *)source {
    return DWCapturedInputAvailable(source)&&self.sources[source.logical]==source&&!source.captureRecovering
        &&!source.restarted&&!source.captureUpdating&&source.stream&&source.pixels&&source.frames
        &&DWInScope(self.scope,source.router.pid)&&[birth(source.router.pid)isEqual:source.router.processBirth]
        &&[windowInfo(source.router.wid)[(id)kCGWindowOwnerPID]intValue]==source.router.pid;
}
- (BOOL)nativeHoverSite:(LiveSource *)source hit:(NSDictionary *)hit view:(DesktopView *)view output:(NSNumber *)output at:(CGPoint)point {
    // A full replica can remain a replica by policy. Do not consume its press
    // for an ownership request that the view plan will refuse.
    // A cooperative singleton first needs the family observation requested by
    // requestNativeOwnershipAt:. Eligibility is checked again after that audit.
    if(source.nativeFamily&&![self.nativeViews canTransferWindow:source.logical output:output])return NO;
    NSDictionary *intent=[view inputIntentForHit:hit output:output],*site=[self.nativeViews placement:source.logical output:output],*drawn=nil,*observed=nil;
    for(NSDictionary *placement in self.renderedPresentation[@"placements"])if([placement[@"window"]isEqual:source.logical]&&[placement[@"output"]isEqual:output]){drawn=placement;break;}
    for(NSDictionary *placement in self.nativeHoverPresentation[@"placements"])if([placement[@"window"]isEqual:source.logical]&&[placement[@"output"]isEqual:output]){observed=placement;break;}
    return intent&&site&&drawn&&observed&&![site[@"family_only"]boolValue]&&![drawn[@"family_only"]boolValue]
        &&boundIdentity(intent[@"identity"],source.identity)&&[drawn[@"source"]isEqual:site[@"source"]]
        &&[observed[@"source"]isEqual:drawn[@"source"]]
        &&CGRectEqualToRect(jsonRect(observed[@"screen_rect"]),jsonRect(drawn[@"screen_rect"]))
        &&CGRectEqualToRect(jsonRect(observed[@"clip_rect"]),jsonRect(drawn[@"clip_rect"]))
        &&CGRectEqualToRect(jsonRect(drawn[@"screen_rect"]),jsonRect(site[@"screen_rect"]))
        &&CGRectEqualToRect(jsonRect(drawn[@"clip_rect"]),jsonRect(site[@"clip_rect"]))
        &&CGRectEqualToRect(jsonRect(site[@"screen_rect"]),jsonRect(site[@"clip_rect"]))
        &&CGRectContainsPoint(jsonRect(site[@"clip_rect"]),point);
}
- (void)cancelNativeHoverForWindow:(NSNumber *)window {
    DWNativeViewTransfer *transfer=self.nativeHoverTransfer;
    // A queued packet has no admitted binding yet. A source invalidation must
    // invalidate it too, rather than let deferred work rediscover a replacement.
    if(window&&transfer&&transfer.window!=window.unsignedLongLongValue)return;
    self.nativeHoverEpoch++;self.nativeHoverQueued=NO;self.nativeHoverObservation=nil;self.nativeHoverPresentation=nil;
    self.nativeHoverTransfer=nil;self.nativeHoverView=nil;self.nativeHoverUntil=0;
    DWNativeAppliedPlacement *placed=transfer?[self.nativeViews admittedPlacementForWindow:@(transfer.window)]:nil;
    if(transfer&&![self.nativeViews isAdmissionCurrentForTransfer:transfer placement:placed]
        &&[self.nativeViews isTransferCurrent:transfer]){
        [self.nativeViews cancelTransfer:transfer];
        if(self.nativeOwnershipTransfer==transfer)self.nativeOwnershipTransfer=nil;
    }
    // Completed ownership persists on hover departure. Pending cancellation
    // keeps both copies covered until existing geometry-only recovery settles.
}
- (void)queueNativeHover:(CGEventRef)event {
    NSEvent *motion=[NSEvent eventWithCGEvent:event];CGPoint point=CGEventGetLocation(event);
    int64_t eligible=CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    BOOL canvas=NO;for(DesktopView *view in self.views)if(view.window.windowNumber==eligible&&eligible>0){canvas=YES;break;}
    if(!canvas&&!self.nativeHoverObservation&&!self.nativeHoverTransfer)return;
    BOOL plain=self.native&&CGEventGetType(event)==kCGEventMouseMoved&&!DWNativeTabletEvent(event)
        &&motion.subtype==NSEventSubtypeMouseEvent&&CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID)!=getpid()
        &&!NSEvent.pressedMouseButtons&&isfinite(point.x)&&isfinite(point.y);
    self.nativeHoverObservation=plain?@{@"point":pointJSON(point),@"flags":@(motion.modifierFlags),
        @"eligible_window":@(eligible)}:nil;
    self.nativeHoverPresentation=plain?self.renderedPresentation:nil;
    self.nativeHoverUntil=plain?CACurrentMediaTime()+.75:0;
    if(self.nativeHoverQueued)return;
    self.nativeHoverQueued=YES;uint64_t epoch=self.nativeHoverEpoch;__weak Desktop *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{Desktop *desktop=weak;if(!desktop||desktop.nativeHoverEpoch!=epoch)return;
        desktop.nativeHoverQueued=NO;[desktop updateNativeHover];});
}
- (BOOL)queuedNativeHoverPress:(NSEvent *)event source:(LiveSource *)source hit:(NSDictionary *)hit view:(DesktopView *)view output:(NSNumber *)output at:(CGPoint)point {
    NSDictionary *observation=self.nativeHoverObservation;
    NSArray *triggers=@[@"left",@"right",@"middle",@"back",@"forward"];NSInteger button=event.buttonNumber;
    NSDictionary *binding=button>=0&&button<(NSInteger)triggers.count?[self mouseBinding:triggers[button] source:nil flags:event.modifierFlags window:YES under:source.logical pick:NO]:nil;
    if(!observation||self.nativeHoverTransfer||CACurrentMediaTime()>=self.nativeHoverUntil
        ||![observation[@"eligible_window"]isEqual:@(view.window.windowNumber)]
        ||!CGPointEqualToPoint(point,jsonPoint(observation[@"point"]))||button<0||button>=32
        ||event.subtype!=NSEventSubtypeMouseEvent||[hit[@"pick"]boolValue]||[hit[@"widget"]boolValue]
        ||[hit[@"placeholder"]boolValue]||hit[@"native_member"]||![self nativeOwnershipReady:source]
        ||CGEventGetIntegerValueField(event.CGEvent,kCGEventTargetUnixProcessID)!=getpid()
        ||CGEventGetIntegerValueField(event.CGEvent,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent)!=view.window.windowNumber
        ||binding.count||[view resizeBorderForButton:button flags:event.modifierFlags hit:hit at:point output:output]
        ||(button==0&&[self replicaGreen:source at:point output:output]))return NO;
    return [self nativeHoverSite:source hit:hit view:view output:output at:point];
}
- (void)updateNativeHover {
    NSDictionary *observation=self.nativeHoverObservation;CGPoint point=pointer();
    if(!observation||CACurrentMediaTime()>=self.nativeHoverUntil||![self nativeHoverAllowed]
        ||(([observation[@"flags"]unsignedLongLongValue]^NSEvent.modifierFlags)&NSEventModifierFlagDeviceIndependentFlagsMask)
        ||!CGPointEqualToPoint(point,jsonPoint(observation[@"point"]))){[self cancelNativeHoverForWindow:nil];return;}
    [self nativeDescription:[self visualSnapshot]];
    NSDictionary *recipient=DWNativeEventRecipientAtPoint(point);
    DWNativeViewTransfer *held=self.nativeHoverTransfer;
    if(held){
        DWNativeAppliedPlacement *placed=[self.nativeViews admittedPlacementForWindow:@(held.window)];
        if([self.nativeViews isAdmissionCurrentForTransfer:held placement:placed]){[self cancelNativeHoverForWindow:nil];return;}
        LiveSource *source=self.sources[@(held.window)];DesktopView *view=self.nativeHoverView;
        BOOL atCanvas=recipient&&[recipient[@"pid"]intValue]==getpid()&&[recipient[@"wid"]longLongValue]==view.window.windowNumber;
        BOOL atMember=NO;for(NSDictionary *member in held.members)if(boundIdentity(recipient,member[@"identity"]))atMember=YES;
        if(!view||![self.views containsObject:view]||![view.outputs containsObject:@(held.output)]||![self nativeOwnershipReady:source]
            ||![self.nativeViews isTransferCurrent:held]||!boundIdentity(source.identity,held.identity)
            ||!CGRectContainsPoint(held.clipRect,point)||(!atCanvas&&!atMember)){[self cancelNativeHoverForWindow:nil];return;}
        if(atCanvas){NSDictionary *hit=[view hit:point output:@(held.output)];
            if(![hit[@"window"]isEqual:source.logical]||hit[@"native_member"]||[hit[@"pick"]boolValue]){[self cancelNativeHoverForWindow:nil];return;}}
        return;
    }
    DesktopView *view=nil;for(DesktopView *candidate in self.views)if(candidate.window.windowNumber==[recipient[@"wid"]longLongValue]
        &&[recipient[@"pid"]intValue]==getpid()){view=candidate;break;}
    if(!view||![observation[@"eligible_window"]isEqual:@(view.window.windowNumber)]){[self cancelNativeHoverForWindow:nil];return;}
    NSNumber *output=[view outputAt:point];NSDictionary *hit=output?[view hit:point output:output]:nil;
    NSNumber *logical=liveHit(hit);LiveSource *source=logical?self.sources[logical]:nil;NSEventModifierFlags flags=[observation[@"flags"]unsignedLongLongValue];
    if(!output||![self nativeOwnershipReady:source]||![self.nativeViews replica:source.logical output:output]
        ||[hit[@"pick"]boolValue]||[hit[@"widget"]boolValue]||[hit[@"placeholder"]boolValue]||hit[@"native_member"]
        ||self.nativeOwnershipTransfer||[self.nativeViews requiresPlacementAdmissionForWindow:source.logical]
        ||[self mouseBinding:@"left" source:nil flags:flags window:YES under:source.logical pick:NO].count
        ||[view resizeBorderForButton:0 flags:flags hit:hit at:point output:output]
        ||[self replicaGreen:source at:point output:output]){[self cancelNativeHoverForWindow:nil];return;}
    if(![self nativeHoverSite:source hit:hit view:view output:output at:point]){[self cancelNativeHoverForWindow:nil];return;}
    DWNativeViewTransfer *transfer=[self requestNativeOwnershipAt:point view:view];
    if(transfer){self.nativeHoverTransfer=transfer;self.nativeHoverView=view;}
    else if(source.nativeFamily)[self cancelNativeHoverForWindow:nil];
}
// Canonical ownership request for hover and an actual AppKit drag destination.
// No pasteboard access, source activation, synthetic mouse packet or global
// window ordering is involved. Capture, identity and complete-family rules all
// remain applicable to the prospective destination.
- (DWNativeViewTransfer *)requestNativeOwnershipAt:(CGPoint)point view:(DesktopView *)view {
    if(!self.native||self.native.ended||self.cleaning||self.sessionInactive||![self.views containsObject:view])return nil;
    NSNumber *output=[view outputAt:point];if(!output)return nil;
    NSDictionary *hit=[view hit:point output:output];NSNumber *window=liveHit(hit);
    LiveSource *source=window?self.sources[window]:nil;
    if(![self nativeOwnershipReady:source]||[hit[@"pick"]boolValue]
        ||![self.nativeViews replica:window output:output])return nil;
    // Cooperative singleton helpers normally need no family polling. A transfer
    // does; ask the existing bounded observation worker, never invent root-only.
    if(!source.nativeFamily){if(!source.nativeTransferFamilyWanted){source.nativeTransferFamilyWanted=YES;self.windowObservationAgain=YES;[self requestWindowObservation];}
        if(self.nativeHoverObservation){self.nativeTransferUntil=MAX(self.nativeTransferUntil,self.nativeHoverUntil);[self startNativeTransferTimer];}return nil;}
    DWNativeViewTransfer *current=[self.nativeViews currentTransferForWindow:window];
    if(current&&[self.nativeViews isTransferCurrent:current]&&current.output==output.unsignedLongLongValue)return current;
    if(self.nativeOwnershipTransfer&&[self.nativeViews isTransferCurrent:self.nativeOwnershipTransfer])
        [self.nativeViews cancelTransfer:self.nativeOwnershipTransfer];
    DWNativeViewTransfer *transfer=[self.nativeViews requestTransferForWindow:window output:output];
    if(!transfer)return nil;self.nativeOwnershipTransfer=transfer;self.nativeOwnershipDeadline=CACurrentMediaTime()+.75;
    self.nativeTransferUntil=CACurrentMediaTime()+2;self.nativeTransferNextCheck=0;
    [self render];[self captureDemand];
    [self startNativeTransferTimer];return transfer;
}
- (void)startNativeTransferTimer {
    if(!self.nativeTransferTimer){__weak Desktop *weak=self;
        self.nativeTransferTimer=[NSTimer timerWithTimeInterval:.02 repeats:YES block:^(NSTimer *timer){Desktop *desktop=weak;if(!desktop){[timer invalidate];return;}[desktop advanceNativeTransfers];}];
        [NSRunLoop.mainRunLoop addTimer:self.nativeTransferTimer forMode:NSRunLoopCommonModes];}
}
- (void)stopNativeTransferTimer { [self.nativeTransferTimer invalidate];self.nativeTransferTimer=nil; }
- (void)advanceNativeTransfers {
    if(!self.native||self.native.ended||self.cleaning||self.sessionInactive){[self cancelNativeHoverForWindow:nil];[self stopNativeTransferTimer];return;}
    CFTimeInterval now=CACurrentMediaTime();if(now<self.nativeTransferNextCheck)return;
    self.nativeTransferNextCheck=now+.02;
    NSDictionary *snapshot=[self visualSnapshot];[self nativeDescription:snapshot];
    // A transfer can lose every eligible native site while its copies remain.
    // End that coverage only on a genuine current whole-family parking ACK.
    // This runs before the no-transfer return and also at ordinary idle polls,
    // so a delayed/failed ACK cannot strand replicas or create a fast retry loop.
    BOOL parkingCompleted=NO;
    for(NSDictionary *row in snapshot[@"windows"]){NSNumber *window=row[@"window"];LiveSource *source=self.sources[window];NSDictionary *binding=asDict(row[@"source"]);
        if(!source||source.detached||![self.nativeViews requiresPlacementAdmissionForWindow:window])continue;
        parkingCompleted|=[self.nativeViews completeParkingForWindow:window identity:source.identity generation:binding[@"generation"] current:^BOOL{
            return (![self captureBackingEnabled]||[self captureBackingReady:source])
                &&[self.native isParkingAcknowledgedForWindow:window identity:source.identity generation:binding[@"generation"]];
        }];
    }
    if(parkingCompleted){[self render];[self captureDemand];}
    if(self.nativeHoverObservation||self.nativeHoverTransfer)[self updateNativeHover];
    NSArray<DWNativeViewTransfer *> *pending=self.nativeViews.pendingTransfers;
    if(!pending.count){if(!self.nativeHoverObservation)[self stopNativeTransferTimer];self.nativeOwnershipTransfer=nil;return;}
    if(self.nativeOwnershipTransfer&&now>=self.nativeOwnershipDeadline&&[pending containsObject:self.nativeOwnershipTransfer]){
        if(self.nativeOwnershipTransfer==self.nativeHoverTransfer)[self cancelNativeHoverForWindow:nil];
        else [self.nativeViews cancelTransfer:self.nativeOwnershipTransfer];
        self.nativeOwnershipTransfer=nil;[self render];
        pending=self.nativeViews.pendingTransfers;
    }
    // One synchronous geometry check per turn. Unlike camera frames this is a
    // bounded handoff; ordinary idle/primary rendering executes no native reads.
    NSUInteger count=pending.count,start=count?self.nativeTransferCursor%count:0;
    for(NSUInteger index=0;index<count;index++){
        NSUInteger slot=(start+index)%count;DWNativeViewTransfer *transfer=pending[slot];
        DWNativeAppliedPlacement *placement=[self.native acknowledgedPlacementForWindow:@(transfer.window) identity:transfer.identity generation:@(transfer.generation) output:@(transfer.output)];
        if(!placement)continue;self.nativeTransferCursor=slot+1;__weak Desktop *weak=self;
        BOOL complete=[self.nativeViews completeTransfer:transfer placement:placement current:^BOOL(DWNativeAppliedPlacement *receipt){return [weak.native isAcknowledgedPlacementCurrent:receipt];}
            validateGeometry:^BOOL(DWNativeAppliedPlacement *receipt){
                if(!DWNativeValidateAppliedPlacementGeometry(weak.native,receipt,NULL))return NO;
                if(weak.nativeHoverTransfer==transfer){[weak updateNativeHover];return weak.nativeHoverTransfer==transfer;}
                return YES;
            }];
        if(complete){if(self.nativeOwnershipTransfer==transfer)self.nativeOwnershipTransfer=nil;
            if(self.nativeHoverTransfer==transfer)[self cancelNativeHoverForWindow:nil];
            [self render];[self captureDemand];}
        else self.nativeTransferNextCheck=now+.05;
        break;
    }
    // A failed recovery remains visibly covered and is retried at the ordinary
    // reconciliation pace, without an unbounded fast timer or fake admission.
    if(now>=self.nativeTransferUntil||!self.nativeViews.pendingTransfers.count)[self stopNativeTransferTimer];
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
    self.pointerOutputs=self.configured&&self.panels.count?asArray(snapshot[@"outputs"]):nil;
    // Also while sloppy focus owes the pointer's output a look because its view moved under the resting pointer (upstream's pull; navigation.hover_pull).
    self.pointerWanted=self.pointerOutputs&&([asDict(asDict(snapshot[@"navigation"])[@"cursor_pan"])[@"needs_pointer"]isEqual:@YES]||[asDict(asDict(snapshot[@"navigation"])[@"hover_pull"])[@"needs_pointer"]isEqual:@YES]);
    // pass_keys: every reply the shell applies is drawn from this snapshot, so what the focused window's rule passes is read here and nowhere else:
    // a bound or scripted command's (-applyReply:), a pointer policy press's and a hover's that moved the focus (-pointerApply:, -pointerFocused:),
    // a focus request's answer and a native focus report (the coordinator's `changed`), a size transaction's tail, each frame of a flight.
    // The hot keys act only when it changed: the passed chords stop being hot keys and reach the focused application from macOS itself.
    if(self.configured){NSArray<NSString *> *refused=[self.hotKeys pass:DWFocusedStandIn(snapshot)?@NO:snapshot[@"pass_keys"]];if(refused.count)[self flashStatus:summary(@"Shortcut unavailable",refused)];for(NSString *line in refused)[self say:[@"Shortcut unavailable: " stringByAppendingString:line]];}
    [self adoptRender:snapshot];self.compositor.nativeMenuBackground=self.native&&!self.windowed&&!self.sessionInactive&&!self.cleaning&&![self nativeUnavailable];
    for(DesktopView *view in self.views)[view render:presentation];
    [self updateStandInKeyboard:snapshot];
    self.renderedPresentation=presentation;self.renderedStatusText=self.statusText;
    // Native presentation: the same snapshot as one frame of window records. It goes with the frame timer's flush of this refresh
    // when one is coming, as the canvas's own drawing does, and at once when none is: a move asked over IPC, the idle poll.
    if(self.native&&self.panels.count&&!self.cleaning&&!self.sessionInactive){
        NSMutableDictionary<NSNumber *,NSDictionary *> *bound=[NSMutableDictionary dictionary];for(LiveSource *source in self.sources.allValues)if(!source.detached)bound[source.logical]=source.identity;
        [self.native describe:nativeSnapshot bound:bound];if(![self frameComing:NO])[self.native submit];}
    // What the status line would show now, said once while it stays up. What it rests on is not news: the chords registered, and a config or background note that was written when it arose.
    // Back at rest, the note last said is forgotten: the next one like it is another event. A failed read of the windows is renewed every two
    // seconds or so, after its note expired, and keeps its own count of what was written (-discoveryFailed:).
    if(self.configured){if([self.statusText isEqual:[self restingStatus]])self.said=nil;else if(![self.statusText isEqual:self.discoveryNote])[self say:self.statusText];}
    // An animated background keeps the frame timer alive by itself, and so does an animation this description began: a window that opened with
    // its picture already there or closed, a stand-in that left. Neither is camera motion, so the timer is started without frameFlying.
    if(!self.frameDriver&&[self animate:NO])[self startFrames];
    [self publishState];
}
// The public desktop-image API exposes the current still URL and options, not
// the rendered frame of an Aerial/video wallpaper. No preference is modified.
- (IFBackgroundProgram *)macWallpaperForOutput:(NSNumber *)output description:(NSDictionary *)description base:(IFBackgroundProgram *)base {
    (void)output;if(!self.compositor.inheritsMacBackground){if(self.macWallpapers.count){self.wallpaperEpoch++;[self.macWallpapers removeAllObjects];}return base;}if(self.cleaning||self.sessionInactive)return base;
    CGRect bounds=jsonRect(description[@"screen_bounds"]);NSScreen *chosen=nil;CGFloat largest=0;
    for(NSScreen *screen in NSScreen.screens){CGRect overlap=CGRectIntersection(bounds,topRect(screen.frame));CGFloat area=CGRectIsNull(overlap)?0:overlap.size.width*overlap.size.height;if(area>largest){largest=area;chosen=screen;}}
    NSNumber *display=asNumber(chosen.deviceDescription[@"NSScreenNumber"]);if(!display)return base;
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
    NSNumber *scaling=asNumber(options[NSWorkspaceDesktopImageScalingKey])?:@(NSImageScaleProportionallyUpOrDown);
    NSNumber *clipping=asNumber(options[NSWorkspaceDesktopImageAllowClippingKey])?:@(options.count==0);
    NSColor *color=[options[NSWorkspaceDesktopImageFillColorKey]isKindOfClass:NSColor.class]?options[NSWorkspaceDesktopImageFillColorKey]:NSColor.blackColor;
    color=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace]?:NSColor.blackColor;NSArray *fill=@[@(color.redComponent),@(color.greenComponent),@(color.blueComponent),@1];
    NSDictionary *desktop=@{@"url":url.absoluteString?:@"",@"scaling":scaling,@"clipping":clipping,@"fill":fill,@"pixels":pixelKey};
    NSDictionary *priorSignature=prior[@"signature"];
    IFBackgroundProgram *previous=[asDict(prior[@"desktop"])[@"url"]isEqual:desktop[@"url"]]?prior[@"program"]:nil;
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
    NSMutableSet *alive=[NSMutableSet set];for(NSScreen *screen in NSScreen.screens){NSNumber *display=asNumber(screen.deviceDescription[@"NSScreenNumber"]);if(display)[alive addObject:display];}
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
    if(self.compositor||!self.configured||self.cleaning)return self.compositor;
    __weak Desktop *weak=self;
    self.compositor=[[DWCanvasRenderer alloc]initWithSource:^DWCanvasContent(NSNumber *window,NSDictionary *placement){
        LiveSource *source=weak.exportSources[window]?:weak.sources[window];DWCanvasContent none={NULL,0,CGRectNull};
        if(!source||source.detached||!source.pixels||(source.nativeReplica&&source.error)
            ||(source.capturedInputGate&&!source.capturedInputGate()))return none;
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
    self.compositor.liveAttachments=^NSArray<DWCanvasAttachment *> *(NSNumber *window,NSNumber *output){LiveSource *source=weak.sources[window];return !weak.cleaning&&!weak.sessionInactive&&!weak.native.ended&&source.pixels&&!source.error&&!source.detached&&(!source.capturedInputGate||source.capturedInputGate())&&(!weak.native||[weak.nativeViews replica:window output:output])?[weak.nativeFamilies attachments:window]:@[];};
    self.compositor.liveOrder=^NSArray<NSDictionary *> *(NSArray<NSDictionary *> *tokens,NSNumber *output){(void)output;return [weak.nativeFamilies orderedTokens:tokens]?:tokens;};
    self.compositor.liveOrderRevision=^uint64_t(NSNumber *output){(void)output;return weak.nativeFamilies.orderRevision;};
    self.compositor.synchronousDrawables=self.scope&&getenv("INFINIFY_DEBUG_SYNC_DRAWABLE")&&atoi(getenv("INFINIFY_DEBUG_SYNC_DRAWABLE"))==1;
    if(DWInputTrace()){self.compositor.measured=YES;[self startFrameStats];}
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
// its run loop. Per bound window: frames its stream (or INFINIFY_DEBUG_SYNTH) delivered, those kept, and those passed over as unchanged.
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
    const char *callbacks=getenv("INFINIFY_DEBUG_CAPTURE_CALLBACKS"),*configuration=getenv("INFINIFY_DEBUG_CAPTURE_CONFIG");
    BOOL captureDiagnostics=(self.nativeDesktopMode||(self.scope&&self.debugPointer))
        &&((callbacks&&strcmp(callbacks,"1")==0)||(configuration&&strcmp(configuration,"1")==0));
    if(captureDiagnostics){NSTimeInterval wall=NSDate.date.timeIntervalSince1970;
        for(NSNumber *window in [self.sources.allKeys sortedArrayUsingSelector:@selector(compare:)]){LiveSource *source=self.sources[window];
            NSDictionary *snapshot=@{@"event":@"capture_diagnostics",@"window":window,@"pid":@(source.router.pid),@"wid":@(source.router.wid),
                @"wall_time_unix":@(wall),@"media_time":@(now),@"captured_frames":@(source.frames),@"replica_wanted":@(source.replicaWanted),
                @"stream_status":source.error?@"failed":!source.stream?@"absent":source.captureUpdating?@"configuration_pending":@"present",
                @"recovering":@(source.captureRecovering),@"error":source.error?:NSNull.null,
                @"guarded_backing":@{ @"required":@(source.capturedInputGate!=nil),@"selected":@(self.captureBackings[window]!=nil),
                    @"ready":@([self captureBackingReady:source]),@"epoch":@(self.captureEdgeGuardEpoch),
                    @"admission":self.captureBackingAdmissions[window]?:NSNull.null,
                    @"physical":self.captureBackings[window].physicalObservation?:NSNull.null,
                    @"readiness":self.captureBackings[window].readinessObservation?:NSNull.null,
                    @"ack_sequence":self.captureBackings[window].receipt?@(self.captureBackings[window].receipt.sequence):NSNull.null },
                @"mailbox":source.captureMailbox.diagnosticSnapshot?:NSNull.null,@"configuration":source.captureConfigurationStatus?:NSNull.null};
            NSData *json=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
            if(json){fputs("capture-diagnostics: ",stderr);fwrite(json.bytes,1,json.length,stderr);fputc('\n',stderr);}
        }
    }
    for(NSPanel *panel in self.panels){CALayer *layer=panel.contentView.layer;
        fprintf(stderr,"panel: wid=%ld level=%ld visible=%d unoccluded=%d alpha=%.3f layer_hidden=%d layer_opacity=%.3f size=%.0fx%.0f hides_inactive=%d can_hide=%d active_space=%d\n",(long)panel.windowNumber,(long)panel.level,panel.isVisible,(panel.occlusionState&NSWindowOcclusionStateVisible)!=0,panel.alphaValue,layer.hidden,layer.opacity,layer.bounds.size.width,layer.bounds.size.height,panel.hidesOnDeactivate,panel.canHide,panel.isOnActiveSpace);}
}
// What a config load changed in the background, the chrome or the outlines is adopted
// before any output is described, and a background that fell back says why, as
// upstream's error bar does. A config load the controller refused keeps the status line.
- (void)adoptRender:(NSDictionary *)snapshot {
    if(!self.views.count)return;[[self canvasRenderer]configure:snapshot];
    NSString *note=self.compositor.note,*old=self.backgroundNote;if(note==old||[note isEqual:old])return;self.backgroundNote=note;
    if(note){fprintf(stderr,"%s\n",note.UTF8String);if(!self.configNote)self.statusText=note;}
    else if([self.statusText isEqual:old])self.statusText=[self restingStatus];
}
// A size transaction of the controller's own is left to run: the quit action ends a fullscreen first, and its reply carries the
// transaction that hands the window its size back. -cleanup performs it to its end, then shuts the coordinator down as before.
- (void)quit:(id)sender { (void)sender;if(![self sizing])[self.resize shutdown];[self stopNavigation];stopped=1; }
- (void)resizeUnavailable:(id)sender { if(self.probe&&sender){self.probeHumanInput=YES;return;} (void)sender;self.statusText=@"Native layout resize is unavailable. Resize the original app on the desktop, then return; capture reconciles without changing world geometry.";[self render]; }
- (void)returnDesktop:(id)sender { if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize is pending or unresolved; source retained";[self render];return;} if(self.probe&&sender){self.probeHumanInput=YES;return;} (void)sender;[self cleanup];[self showChooser:nil]; }
- (DesktopView *)panel:(NSRect)frame outputRects:(NSArray *)rects identities:(NSArray *)identities {
    BOOL desktop=self.configured&&!self.windowed; // a normal run's panel on a display: the display, whole
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
    // The explicitly spawned scoped benchmark's own canvas stays visible. Native
    // mode retains ordinary canvas input for its replica destinations; capture
    // throughput runs leave pointer handling off. No other window is reordered.
    BOOL nativeBench=self.native&&getenv("INFINIFY_DEBUG_NATIVE_BENCH")&&atoi(getenv("INFINIFY_DEBUG_NATIVE_BENCH"))==1;
    if(self.scope&&(!self.native||nativeBench)&&getenv("INFINIFY_DEBUG_BENCH")&&atoi(getenv("INFINIFY_DEBUG_BENCH"))==1){panel.level=NSFloatingWindowLevel;panel.ignoresMouseEvents=!self.native;panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary;}
    DesktopView *view=[[DesktopView alloc]initWithFrame:NSMakeRect(0,0,frame.size.width,frame.size.height)];view.desktop=self;view.globalBounds=topRect(frame);view.outputs=[NSMutableArray array];view.tiles=[NSMutableDictionary dictionary];view.surfaces=[NSMutableDictionary dictionary];view.wantsLayer=YES;view.layer.backgroundColor=[NSColor colorWithSRGBRed:.045 green:.065 blue:.10 alpha:1].CGColor;panel.contentView=view;
    if(self.native){NSMutableArray<NSPasteboardType> *types=[NSMutableArray arrayWithObjects:NSPasteboardTypeFileURL,NSPasteboardTypeURL,NSPasteboardTypeTIFF,NSPasteboardTypePNG,nil];
        [types addObjectsFromArray:NSFilePromiseReceiver.readableDraggedTypes];[view registerForDraggedTypes:types];}
    // A window wholly under an opaque window is told it is not visible, and applications stop drawing one that is not: a
    // window took typing under the canvas and its tile showed none of it, though the text was there once the canvas was
    // gone (owner's run, 2026-10-10). Every window a normal run shows is wholly under this panel. The window server
    // counts a panel as covering only at full alpha; declaring the panel and its layers non-opaque changed nothing, an alpha
    // value a thousandth short of one did (measured on a fixture window under a floating panel, the same day). At that alpha
    // nothing of what lies under the canvas shows through an 8-bit pixel.
    // Not under native presentation, where no window lies under the panel.
    if(self.configured&&!self.native)panel.alphaValue=.999;
    // Normal runs only: the trackpad's raw touches, for gestures of three or more fingers.
    if(self.configured)view.allowedTouchTypes=NSTouchTypeMaskIndirect;
    for(NSUInteger i=0;i<rects.count;i++){NSMutableDictionary *registration=[@{@"op":@"register_output",@"stable_id":identities[i],@"screen_bounds":rects[i]}mutableCopy];
        if(self.configured)registration[@"usable_rect_local"]=rectJSON(outputUsableRect(jsonRect(rects[i])));
        NSNumber *output=[self call:registration][@"output"];if(output)[view.outputs addObject:output];}
    // Pointer motion over the canvas: hover, sloppy focus, pick mode. The fixture modes have none of it.
    if(self.configured){if(!self.canvasCursor)self.canvasCursor=[DWCanvasCursor new];view.hover=[[DWPointerHover alloc]initWithHost:view];view.hover.forwarding=!self.hoverUndelivered;}
    // A normal run ends here: its view is the canvas alone, and the strip, toolbar and status line below are the fixture modes'. The desktop's
    // panels are on every Space, a fullscreen application's included, and stay where they are through Mission Control, like the desktop they replace.
    if(desktop)panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle|NSWindowCollectionBehaviorFullScreenAuxiliary;
    if(self.configured){[self.panels addObject:panel];[self.views addObject:view];[panel orderFrontRegardless];return view;}
    NSArray *names=@[@"Choose windows",@"Return to desktop",@"Resize status",[self quitTitle]];
    SEL actions[]={@selector(showChooser:),@selector(returnDesktop:),@selector(resizeUnavailable:),@selector(quit:)};
    CGFloat x=12;for(NSUInteger i=0;i<names.count;i++)x=toolbarButton(view,[NSButton buttonWithTitle:names[i] target:self action:actions[i]],x);
        // The accessory app is rarely active, so tooltips must not wait for activation.
        if(!self.probe)panel.allowsToolTipsWhenApplicationIsInactive=YES;
        for(NSArray<NSString *> *row in toolbarActions(self.configured)){NSButton *button=[NSButton buttonWithTitle:row[0] target:self action:@selector(viewButton:)];button.identifier=row[1];button.toolTip=[self tooltip:row];x=toolbarButton(view,button,x);}
    view.status=label(self.statusText,NSMakeRect(15,37,MAX(100,frame.size.width-30),22));view.status.textColor=NSColor.lightGrayColor;view.status.font=[NSFont systemFontOfSize:11];[view addSubview:view.status];
    [self.panels addObject:panel];[self.views addObject:view];[panel orderFrontRegardless];return view;
}
- (void)openPanels {
    if(self.panels.count)return;self.cleaning=NO;
    // Notifications cannot report sleep that preceded this process. Establish
    // current admission before outputs, input, discovery or autostart exist;
    // unlike a departure, this unopened canvas has nothing to drain or save.
    if(self.configured&&(!self.windowed||self.native)){
        self.desktopUp=YES;
        if(!self.session){__weak Desktop *weak=self;self.session=[[DWSessionWatch alloc]initWithReturned:^{[weak returned];} left:^{[weak leftSession];}];self.sessionInactive=!self.session.ready;self.sessionAwaitingCanvas=self.sessionInactive;}
        if(self.sessionInactive)return;
    }
    // Return to desktop stopped the config watcher and dropped the key table: read the config again.
    if(self.configured&&!self.configWatcher)[self loadConfig:NO];
    if(self.configured&&!self.trackpad){__weak Desktop *weak=self;self.trackpad=[[DWTrackpadGestures alloc]initWithEmit:^(NSDictionary *event){[weak noteDockGesture:event];[weak gesture:event owner:1];}];}
    if(self.nativeEndpoints.count&&self.native.ended){self.nativeResumeWanted=YES;self.nativeResumeAfter=0;}
    if(self.demo){NSRect frame=NSMakeRect(100,120,1040,600);CGRect global=topRect(frame);NSMutableArray *rects=[NSMutableArray array];for(int i=0;i<2;i++)[rects addObject:rectJSON(CGRectOffset(ports[i],global.origin.x,global.origin.y))];[self panel:frame outputRects:rects identities:@[@"fixture-view-a",@"fixture-view-b"]];}
    // The analogue of upstream's nested winit backend: one ordinary window, one output.
    else if(self.windowed){NSScreen *screen=NSScreen.mainScreen?:NSScreen.screens.firstObject;NSRect area=screen.visibleFrame;CGFloat width=MIN(self.windowSize.width,area.size.width),height=MIN(self.windowSize.height,area.size.height);
        NSRect frame=NSMakeRect(floor(NSMidX(area)-width/2),floor(NSMidY(area)-height/2),width,height);
        if(screen){
            // Scoped two-view runtime acceptance uses the ordinary renderer and
            // ownership adapter in one owned panel. No real display is changed.
            BOOL split=self.scope&&self.native&&self.debugPointer&&getenv("INFINIFY_DEBUG_NATIVE_BENCH")&&atoi(getenv("INFINIFY_DEBUG_NATIVE_BENCH"))==1
                &&getenv("INFINIFY_DEBUG_NATIVE_VIEWS")&&atoi(getenv("INFINIFY_DEBUG_NATIVE_VIEWS"))==2;
            CGRect canvas=topRect(frame);
            if(split){CGFloat half=floor(canvas.size.width/2);CGRect left=canvas,right=canvas;left.size.width=half;right.origin.x+=half;right.size.width-=half;
                [self panel:frame outputRects:@[rectJSON(left),rectJSON(right)] identities:@[@"fixture-view-a",@"fixture-view-b"]];}
            else [self panel:frame outputRects:@[rectJSON(canvas)] identities:@[@"windowed"]];}}
    // The desktop canvas still covers the whole display; fit/fullscreen geometry
    // excludes its menu/notch band, while the Dock draws over the panel.
    else for(NSScreen *screen in NSScreen.screens){NSNumber *display=screen.deviceDescription[@"NSScreenNumber"];CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(display.unsignedIntValue);NSString *name=uuid?CFBridgingRelease(CFUUIDCreateString(NULL,uuid)):nil;if(uuid)CFRelease(uuid);if(!name)continue;[self panel:screen.frame outputRects:@[rectJSON(topRect(screen.frame))] identities:@[name]];}
    self.panelScreens=physicalScreens();
    if(self.panels.count)self.sessionAwaitingCanvas=NO;
    // Every display that exists is registered now. A screen change and Return to desktop remove them all first, so only here can the controller
    // tell a display that is gone from one that came straight back: a pin whose own display is missing moves to one that is there.
    if([asNumber([self call:@{@"op":@"outputs_settled"}][@"dirty"])boolValue])self.sceneDirty=YES;
    // Windowed mode registers no global hot key: pointer and IPC only.
    if(self.configured){NSArray<NSString *> *refused=[self startKeys];if(refused.count)self.statusText=summary(@"Shortcut unavailable",refused);[self armCorners:[self call:@{@"op":@"bindings"}]];
        // The status note names one: every chord macOS refused is named on stderr, as a reload names them.
        for(NSString *line in refused)[self say:[@"Shortcut unavailable: " stringByAppendingString:line]];}
    else {
    if(!self.probe&&!self.windowed)[self configureViewKeys];
    if(!self.windowed)[self configureExitKey];
    }
    [self configureResize];[self configureNavigation];
    // Capture overlays retain their Screen Recording gate. Authenticated native
    // presentation discovers metadata without asking for pictures or permission.
    // It says why; a more specific problem already in the status line keeps its place there.
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
    if(self.native&&self.scope&&getenv("INFINIFY_DEBUG_BENCH")&&atoi(getenv("INFINIFY_DEBUG_BENCH"))==1&&getenv("INFINIFY_DEBUG_NATIVE_BENCH")&&atoi(getenv("INFINIFY_DEBUG_NATIVE_BENCH"))==1)self.manager.benchmarkWindowLevel=NSFloatingWindowLevel+1;
    [self render];[self configureNativeInput];[self configureCaptureEdgeGuard];
}
// A menu-bar-only screen notice changes fit/fullscreen geometry, not the panel,
// output identity, world placement or saved camera. Dock notices compare equal.
- (void)refreshOutputUsableAreas {
    if(!self.configured||self.cleaning||!self.views.count)return;
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*contexts=asDict(asDict(snapshot[@"navigation"])[@"contexts"]);BOOL changed=NO;
    for(NSDictionary *output in snapshot[@"outputs"]){NSNumber *identifier=asNumber(output[@"id"]);if(!identifier)continue;
        CGRect usable=outputUsableRect(jsonRect(output[@"screen_bounds"]));NSDictionary *local=rectJSON(usable);
        if([asDict(contexts[identifier.stringValue])[@"usable_rect_local"]isEqual:local])continue;
        NSDictionary *reply=[self call:@{@"op":@"set_usable_area",@"output":identifier,@"usable_rect_local":local}];if(reply&&!reply[@"error"]){[self consumeSize:reply];changed=YES;}
    }
    if(changed)[self render];
}
- (void)refreshChoices:(id)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;if(self.configured&&self.chooser)[self fillRebind:YES];[self.choices removeAllObjects];[self.table reloadData];
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
// The Rebind drop-down: a new world window, or one of the world windows that has no source now. A --manual run's chooser stays open
// above the canvas, so there the list is made again by Refresh and after every Add (keep: what is chosen stays chosen while it can still be rebound).
- (void)fillRebind:(BOOL)keep {
    NSNumber *chosen=keep?self.rebind.selectedItem.representedObject:nil;
    [self.rebind removeAllItems];[self.rebind addItemWithTitle:@"Create a new world window"];
    for(NSDictionary *w in [self call:@{@"op":@"snapshot"}][@"windows"])if(!self.sources[w[@"window"]]){[self.rebind addItemWithTitle:[NSString stringWithFormat:@"Rebind %@: %@",w[@"window"],w[@"metadata"][@"title"]?:@"window"]];self.rebind.lastItem.representedObject=w[@"window"];}
    NSInteger kept=chosen?[self.rebind indexOfItemWithRepresentedObject:chosen]:-1;if(kept>=0)[self.rebind selectItemAtIndex:kept];
}
- (void)showChooser:(id)sender {
    if(self.resize&&![self.resize canRemove:nil]){self.statusText=@"Resize is pending or unresolved; source retained";[self render];return;}
    [self cancelNavigation];
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;
    if(!self.chooser){self.chooser=[[(FixtureWindow.class) alloc]initWithContentRect:NSMakeRect(200,180,720,470) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];self.chooser.title=@"Infinify — choose native windows";self.chooser.level=NSFloatingWindowLevel+1;self.chooser.releasedWhenClosed=NO;self.chooser.delegate=self;
        NSView *v=self.chooser.contentView;NSScrollView *scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(18,130,684,315)];scroll.hasVerticalScroller=YES;
        self.table=[[NSTableView alloc]initWithFrame:scroll.bounds];NSTableColumn *column=[[NSTableColumn alloc]initWithIdentifier:@"Window"];column.title=@"Application — native window";column.width=675;[self.table addTableColumn:column];self.table.dataSource=self;self.table.delegate=self;scroll.documentView=self.table;[v addSubview:scroll];
        self.chooserStatus=label(@"",NSMakeRect(18,55,480,60));self.chooserStatus.maximumNumberOfLines=3;[v addSubview:self.chooserStatus];
        self.grant=[NSButton buttonWithTitle:@"" target:self action:@selector(grantAccess:)];self.grant.frame=NSMakeRect(507,70,195,30);self.grant.hidden=YES;[v addSubview:self.grant];
        self.rebind=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(18,15,205,30) pullsDown:NO];[v addSubview:self.rebind];
        NSButton *attach=[NSButton buttonWithTitle:@"Add selected window" target:self action:@selector(attachChoice:)];attach.frame=NSMakeRect(229,15,170,30);[v addSubview:attach];
        NSButton *canvas=[NSButton buttonWithTitle:@"Open canvas" target:self action:@selector(openCanvas:)];canvas.frame=NSMakeRect(405,15,120,30);canvas.toolTip=@"Show the saved world without adding a window";[v addSubview:canvas];
        NSButton *refresh=[NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshChoices:)];refresh.frame=NSMakeRect(531,15,85,30);[v addSubview:refresh];
        NSButton *quit=[NSButton buttonWithTitle:@"Quit" target:self action:@selector(quit:)];quit.frame=NSMakeRect(622,15,80,30);[v addSubview:quit];}
    [self fillRebind:NO];
    [self.chooser makeKeyAndOrderFront:nil];[NSApp activate];[self refreshChoices:nil];
}
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window;if(!self.panels.count)stopped=1;return YES; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView;return self.choices.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {(void)tableView;(void)column;return self.choices[row][@"label"];}
// The saved world and its cameras need no capture: placeholders, navigation and
// view actions work before any source is chosen or any privacy grant exists.
// A normal run's takeover of Stage Manager and window tiling (system-takeover.m): its own stderr line says what changed. Idempotent.
// Said before the canvas opens, so a launch that failed to switch them off tells the user why windows may still be thumbnails.
- (void)takeOverWindowSettings {
    NSString *note=nil;[self.takeover engage:&note];if(note.length)fprintf(stderr,"%s\n",note.UTF8String);
}
// Put back after everything else has ended, so no window is still parked or scaled when Stage Manager comes back on. Idempotent.
- (void)putBackWindowSettings {
    NSString *note=nil;[self.takeover restore:&note];if(note.length)fprintf(stderr,"%s\n",note.UTF8String);
}
- (void)openCanvas:(id)sender {
    if(self.probe&&sender){self.probeHumanInput=YES;return;}
    (void)sender;if(self.startupError){self.chooserStatus.stringValue=self.startupError;return;}
    // The canvas about to open must find windows as the user left them, not thumbnails or tiles: macOS follows the change live.
    [self takeOverWindowSettings];
    // A --manual run has no strip to bring the chooser back from: it stays open above the canvas, the one place a window is added or rebound from.
    [self openPanels];if(!self.configured)[self.chooser orderOut:nil];[self render];
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
    BOOL added=[self attach:[DWWindowCandidate candidateWithShareable:self.choices[row][@"window"]] logical:logical world:nil];if(self.configured)[self fillRebind:YES];
    if(added){if(!self.configured)[self.chooser orderOut:nil];[self saveScene];[self render];}else self.chooserStatus.stringValue=self.statusText;
}
- (BOOL)attach:(DWWindowCandidate *)window logical:(NSNumber *)logical world:(NSDictionary *)world { return [self attach:window logical:logical world:world placed:NO]; }
// placed: a window that appeared by itself. It is sent with neither a logical id nor a
// world rectangle, so the controller adopts it into a matching slot or places it by
// window_placement around the active output and the pointer. Only its size is native.
// The one place a native window is bound: the only LiveSource, Router and identity made in a run that is no demo, and the
// only attach command sent. Under --only-pid a window of any other process is refused here before any of them exists, so
// nothing that acts on a native window (native focus, a forwarded press or motion, close, native resize) has one to act on.
- (BOOL)attach:(DWWindowCandidate *)window logical:(NSNumber *)logical world:(NSDictionary *)world placed:(BOOL)placed {
    if([self nativeUnavailable]){self.statusText=@"Native presentation is reconnecting; window discovery will retry";return NO;}
    if(!placed)[self cancelNavigation];
    pid_t pid=window.pid;uint32_t wid=window.window;
    if(!DWInScope(self.scope,pid)){self.statusText=@"Not attached: its process is outside --only-pid";return NO;}
    // Under a scope the start time is the one DWInScope has just matched, not a second reading that another process could answer.
    NSArray *processBirth=self.scope?self.scope[@(pid)]:birth(pid);NSDictionary *info=windowInfo(wid);CGRect bounds=CGRectZero;
    NSDictionary *created=window.nativeIdentity;
    if(created&&(![created[@"pid"]isEqual:@(pid)]||![created[@"wid"]isEqual:@(wid)]||processBirth.count!=2||
        ![created[@"birth_sec"]isEqual:processBirth[0]]||![created[@"birth_usec"]isEqual:processBirth[1]])){self.statusText=@"Source identity changed after its creation notification";return NO;}
    if(!processBirth||[info[(id)kCGWindowOwnerPID]intValue]!=pid||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds],&bounds)){self.statusText=@"Source closed or identity changed; refresh the chooser.";return NO;}
    if(window.displayFixed&&(!self.native||[info[(id)kCGWindowLayer]integerValue]!=NSFloatingWindowLevel)){self.statusText=@"Utility panel changed its native level before adoption";return NO;}
    // Native presentation: the window's own frame, not where the helper may still be drawing it for a run that ended without restoring.
    NSDictionary *frame=info[(id)kCGWindowBounds];
    if(self.native){if(!DWNativeBounds(wid,&bounds)){self.statusText=@"Not attached: the window server did not give the window's own frame";return NO;}frame=CFBridgingRelease(CGRectCreateDictionaryRepresentation(bounds));}
    for(LiveSource *existing in self.sources.allValues)if(existing.router.pid==pid&&existing.router.wid==wid){self.statusText=@"This source is already attached; every display can view the same world window.";return NO;}
    LiveSource *source=[LiveSource new];source.router=[Router new];source.router.pid=pid;source.router.wid=wid;source.router.processBirth=processBirth;source.router.bounds=frame;source.router.deadline=NSDate.distantFuture;source.router.sent=[NSMutableArray array];source.router.tag=(int64_t)(arc4random_uniform(0x7fffff)+1)*100;source.router.eventSource=CGEventSourceCreate(kCGEventSourceStatePrivate);source.router.usePrivate=YES;
    [self.postingTags addObject:@(source.router.tag)];
    BOOL privateAvailable=[source.router loadPrivate];source.identity=@{@"pid":@(pid),@"birth_sec":processBirth[0],@"birth_usec":processBirth[1],@"wid":@(wid)};
    if(self.native&&![self.native allowsWindow:source.identity])return NO;
    source.buffer=CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2));source.surfaces=[NSMutableArray array];source.composited=self.configured;
    NSMutableDictionary *command=[@{@"op":@"attach",@"identity":source.identity,@"bundle_id":window.bundleIdentifier?:@"",@"title":window.title?:@"Untitled",@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)},@"source_rect":rectJSON(bounds)} mutableCopy];
    if(placed){NSNumber *output=[self viewOutput];if(output)command[@"output"]=output;command[@"pointer"]=pointJSON(pointer());}
    else if(logical)command[@"logical_id"]=logical;else {if(!world){NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];NSDictionary *o=[snapshot[@"outputs"]firstObject];double zoom=[o[@"zoom"]doubleValue];CGPoint camera=jsonPoint(o[@"camera"]);world=rectJSON(CGRectMake(camera.x+30/MAX(.001,zoom),camera.y+30/MAX(.001,zoom),bounds.size.width,bounds.size.height));}command[@"world_rect"]=world;}
    if(window.displayFixed){
        NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}],*chosen=nil;double best=INFINITY;
        CGPoint center=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));
        for(NSDictionary *output in snapshot[@"outputs"]){CGRect screen=jsonRect(output[@"screen_bounds"]);if(CGRectIsEmpty(screen))continue;
            double dx=center.x-fmin(CGRectGetMaxX(screen),fmax(CGRectGetMinX(screen),center.x)),dy=center.y-fmin(CGRectGetMaxY(screen),fmax(CGRectGetMinY(screen),center.y));double distance=dx*dx+dy*dy;
            if(distance<best){best=distance;chosen=output;}}
        if(!chosen){self.statusText=@"Utility panel has no live display to pin to";return NO;}
        CGRect screen=jsonRect(chosen[@"screen_bounds"]);
        command[@"screen_pin"]=@{@"output":chosen[@"id"],@"screen_pos":pointJSON(CGPointMake(bounds.origin.x-screen.origin.x,bounds.origin.y-screen.origin.y))};
    }
    NSDictionary *reply=[self call:command];source.logical=reply[@"window"];if(!source.logical)return NO;source.observationToken=++self.observationEpoch;self.sources[source.logical]=source;
    source.window=self.native?nil:window.shareable;source.nativeReplica=self.native!=nil;[self.native bound:source.identity bounds:bounds];source.title=asString(info[(id)kCGWindowName])?:command[@"title"];
    [self refreshNativeButtons:source];
    // A new frame redraws only the outputs that show this window. The first picture of a window that just opened begins its open animation, which the frame timer plays.
    if(source.composited){__weak Desktop *weak=self;NSNumber *logical=source.logical;source.presented=^{Desktop *d=weak;if([d.compositor contentChanged:logical])[d startFrames];};}
    // INFINIFY_DEBUG_SYNTH: only a run that names its processes is fed made-up frames, and only what it draws itself.
    if(self.scope&&source.composited&&!self.native&&DWSynthRate()>0)source.synth=[SynthLoad loadFor:source rate:DWSynthRate()];
    // A window rule's size: the controller began its size transaction with the attach, and the coordinator performs it as it
    // performs a sizing action's. Its result reaches the controller on a later turn of the main queue, after this method.
    // Until it has settled the compositor is given no picture of the window, so its open animation waits with it (-render: there).
    if(placed)[self consumeSize:reply];
    // A managed run captures on demand: -captureDemand starts the stream once the window has a placement.
    if(self.manager)source.keepSample=YES;
    else if(![self startCapture:source size:source.buffer interval:[self captureInterval]]&&!source.captureRecovering){[self detach:source];return NO;}
    if(!privateAvailable)self.statusText=@"Live view only: private per-window input is unavailable on this OS.";
    if(placed){if(self.navigationTap&&self.navigationTapSource&&CGEventTapIsEnabled(self.navigationTap))[self.navigation preserveBackgroundArrival:reply];[self follow:reply];}
    [self render];return YES;
}
// How often a window's picture is asked for, at most: as often as the display it is shown on refreshes, the fastest screen a canvas panel is on,
// and 60 times a second at least. Rate changes are reconciled independently of pixel-size changes. Frame-status and dirty-rectangle
// checks skip frames that explicitly report no changed content; some streams still report complete frames at the full requested rate.
- (CMTime)captureInterval {NSInteger rate=60;for(NSScreen *screen in [self canvasScreens])rate=MAX(rate,screen.maximumFramesPerSecond);return CMTimeMake(1,(int32_t)rate); }
// One stream for a source at a pixel size. NO leaves the reason in source.error.
- (BOOL)startCapture:(LiveSource *)source size:(CGSize)pixels interval:(CMTime)interval {
    // An --only-pid run without Screen Recording access has no shareable window to make a filter of. -captureDemand never comes here for one.
    // The one NO that leaves source.error alone: a reason there would have -track: detach a source that nothing is wrong with.
    if(!source.window||source.detached||self.cleaning)return NO;
    source.error=nil;source.captureRecovering=NO;source.captureRetryAt=0;
    BOOL diagnosticsAllowed=self.nativeDesktopMode||(self.scope&&self.debugPointer);
    const char *diagnostics=getenv("INFINIFY_DEBUG_CAPTURE_CONFIG");source.captureConfigurationMeasured=diagnosticsAllowed&&diagnostics&&strcmp(diagnostics,"1")==0;
    source.captureSize=pixels;CGRect native=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&native);source.captureNativeSize=native.size;source.captureCandidateSince=0;
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)pixels.width;config.height=(size_t)pixels.height;config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=interval;config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;compositedStream(config,source);
    source.stream=[[SCStream alloc]initWithFilter:[[SCContentFilter alloc]initWithDesktopIndependentWindow:source.window] configuration:config delegate:source];source.restarted=YES;NSError *error=nil;
    id<SCStreamOutput> output=source;dispatch_queue_t samples=dispatch_get_main_queue();
    if(source.composited){const char *callbacks=getenv("INFINIFY_DEBUG_CAPTURE_CALLBACKS");source.captureMailbox=[[DWRootCaptureMailbox alloc]initWithSource:source stream:source.stream diagnostics:diagnosticsAllowed&&callbacks&&strcmp(callbacks,"1")==0];output=source.captureMailbox;samples=source.captureMailbox.queue;}
    if(![source.stream addStreamOutput:output type:SCStreamOutputTypeScreen sampleHandlerQueue:samples error:&error]){source.stream=nil;[source captureFailed:error];return NO;}
    uint64_t serial=[source beginCaptureConfiguration:config];
    SCStream *starting=source.stream;[starting startCaptureWithCompletionHandler:^(NSError *e){dispatch_async(dispatch_get_main_queue(),^{if(source.stream!=starting||source.detached||self.cleaning||![source completeCaptureConfiguration:serial success:e==nil])return;[source.captureMailbox stream:starting startCompleted:e==nil];if(e){source.stream=nil;[source captureFailed:e];if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: capture start failed window=%s pid=%d wid=%u: %s (%ld)\n",source.logical.stringValue.UTF8String,source.router.pid,source.router.wid,e.localizedDescription.UTF8String,(long)e.code);}});}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(source.stream!=starting||source.detached||self.cleaning||!DWCaptureConfigurationPending(source.captureConfiguration,serial))return;[self stopCapture:source];[source captureFailed:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorFailedToStart userInfo:@{NSLocalizedDescriptionKey:@"Capture start timed out"}]];});
    return YES;
}
// An intentional stop is no error: the stream is forgotten first, so nothing it still
// reports is read, and cleanup waits for the stop like any other. The compositor keeps
// the last picture, so a window whose placement returns is not blank until its stream
// delivers again.
- (void)stopCapture:(LiveSource *)source {
    SCStream *stream=source.stream;if(!stream)return;source.stream=nil;source.captureCandidateSince=0;if(!source.composited)[source clearSample];
    [self.pendingStops addObject:stream];[stream stopCaptureWithCompletionHandler:^(NSError *error){(void)error;dispatch_async(dispatch_get_main_queue(),^{[self.pendingStops removeObject:stream];});}];
}
// A larger tile needs sharper pixels immediately. Density buckets grow by sqrt(2), limiting their area slack to 2x
// instead of 4x just above each power of two. Smaller tiles change buckets after half a second of
// stable actual density as well as bucket demand. Continuous zoom may linger in a bucket longer than that; it must not
// repeatedly shrink and regrow all streams while the scale is still moving. The largest placement across all outputs
// wins, including pinned windows and widgets. Cropping does not lower density. Native ownership and world geometry are unchanged.
- (CGSize)capturePixels:(LiveSource *)source native:(CGSize)native placements:(NSArray *)placements scales:(NSDictionary *)scales demandDensity:(double *)demand {
    if(self.scope&&getenv("INFINIFY_DEBUG_FULL_CAPTURE")&&atoi(getenv("INFINIFY_DEBUG_FULL_CAPTURE"))==1){if(demand)*demand=2;return CGSizeMake(ceil(native.width*2),ceil(native.height*2));}
    double density=0;
    for(NSDictionary *p in placements)if([p[@"window"]isEqual:source.logical]){CGRect r=jsonRect(p[@"screen_rect"]);if(CGRectIsNull(r))continue;double scale=[scales[p[@"output"]]doubleValue];density=fmax(density,fmax(r.size.width/native.width,r.size.height/native.height)*(scale>0?scale:2));}
    if(density<=0)density=source.captureNativeSize.width>0?source.captureSize.width/source.captureNativeSize.width:2;
    density=fmin(2,fmax(1.0/32,density));if(demand)*demand=density;
    density=fmax(density,exp2(ceil(2*log2(density))*.5));
    return CGSizeMake(MAX(2,ceil(native.width*density)),MAX(2,ceil(native.height*density)));
}
- (void)updateCapture:(LiveSource *)source size:(CGSize)pixels native:(CGSize)native interval:(CMTime)interval {
    if(!source.stream||source.captureUpdating||source.error||source.detached)return;
    // A rate-only update preserves the current picture and a pending shrink's
    // stability clock. Only a changed raster/native size needs a fresh image.
    if(!CGSizeEqualToSize(pixels,source.captureSize)||!CGSizeEqualToSize(native,source.captureNativeSize)){source.captureCandidateSince=0;source.restarted=YES;}
    source.captureSize=pixels;source.captureNativeSize=native;
    SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)pixels.width;config.height=(size_t)pixels.height;config.pixelFormat=kCVPixelFormatType_32BGRA;config.minimumFrameInterval=interval;config.queueDepth=3;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;compositedStream(config,source);
    uint64_t serial=[source beginCaptureConfiguration:config];
    SCStream *stream=source.stream;[stream updateConfiguration:config completionHandler:^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{if(source.stream!=stream||source.detached||self.cleaning||![source completeCaptureConfiguration:serial success:error==nil])return;if(error){[self stopCapture:source];[source captureFailed:error];}});}];
}
// Capture on demand, in a managed run: a stream runs while its window has a placement
// on some output and for two seconds after the last one went, and starts again when one
// returns. Transient failures keep their binding for -captureRecovery.
- (void)captureDemand {
    if(!self.manager||!self.sources.count||self.sessionInactive){[self.nativeFamilies reset];return;}
    if(self.native.ended){[self.nativeFamilies reset];for(LiveSource *source in self.sources.allValues){source.replicaWanted=NO;[self stopCapture:source];}return;}
    NSDictionary *snapshot=[self presentationSnapshot];if(!snapshot)return;
    if(self.native&&!self.nativeViews.capturedWindows.count){
        BOOL draining=NO;for(LiveSource *source in self.sources.allValues)if(source.stream||source.replicaWanted){draining=YES;break;}
        if(!draining){[self.nativeFamilies reset];return;}
    }
    NSMutableDictionary *outputs=[NSMutableDictionary dictionary],*captureSites=[NSMutableDictionary dictionary],*scales=[NSMutableDictionary dictionary];
    for(NSDictionary *output in snapshot[@"outputs"])if(output[@"id"])outputs[output[@"id"]]=output;
    for(DesktopView *view in self.views)for(NSNumber *output in view.outputs)scales[output]=@(view.window.backingScaleFactor);
    NSMutableSet<NSNumber *> *placed=[NSMutableSet set];NSMutableArray *pictures=[NSMutableArray array];
    for(NSDictionary *p in snapshot[@"placements"])if(!self.native||[self.nativeViews replica:p[@"window"] output:p[@"output"]]){
        NSNumber *window=p[@"window"];[placed addObject:window];[pictures addObject:p];
        if(!captureSites[window])captureSites[window]=[NSMutableArray array];
        // The viewport is the output, not the root's clip: a child may extend
        // into it from outside its root, including family-only placements.
        NSDictionary *output=outputs[p[@"output"]];double scale=[scales[p[@"output"]]doubleValue],zoom=[p[@"pinned"]boolValue]?1:[output[@"zoom"]doubleValue];
        // Surface origin/extent round before zoom, then both final corners
        // round again. Include that error plus a physical pixel of fringe.
        NSNumber *margin=scale>0&&isfinite(scale)&&zoom>0&&isfinite(zoom)?@((MAX(1,zoom)+1)/scale):nil;
        [captureSites[window]addObject:@{@"screen_rect":p[@"screen_rect"]?:NSNull.null,@"viewport":output[@"screen_bounds"]?:NSNull.null,@"pixel_margin":margin?:NSNull.null}];
    }
    BOOL captureAll=self.compositor.hasFamilyGeometryTransitions;
    NSMutableDictionary *bindings=[NSMutableDictionary dictionary];for(NSDictionary *window in snapshot[@"windows"])if(asDict(window[@"source"]))bindings[window[@"window"]]=window[@"source"];
    CMTime interval=[self captureInterval];
    NSMutableArray *familyRoots=[NSMutableArray array];NSInteger familyRate=(NSInteger)llround(1/CMTimeGetSeconds(interval));
    for(LiveSource *source in self.sources.allValues){
        if(source.error)[self cancelCapturedInputForWindow:source.logical];
        BOOL wanted=[self.manager capture:source.logical placed:[placed containsObject:source.logical]],running=source.stream!=nil;
        source.replicaWanted=wanted;
        if(!wanted){if(running)[self stopCapture:source];continue;}
        if(self.native&&!source.window&&!source.error&&!source.captureRecovering){source.captureRecovering=YES;source.captureRetryAt=0;}
        // Bound without a shareable window (--only-pid without Screen Recording access): there is nothing to capture, and no
        // failure either, which would detach the window at the next look.
        // The synthetic benchmark measures frame delivery and rendering alone. Starting a real stream too would double
        // its load on a host with Screen Recording access and make the two hosts' measurements incomparable.
        if(!source.window||source.synth)continue;
        if(source.error)continue;
        CGRect bounds=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&bounds)||bounds.size.width<=0||bounds.size.height<=0)continue;
        double densityDemand=0;CGSize pixels=[self capturePixels:source native:bounds.size placements:pictures scales:scales demandDensity:&densityDemand];
        CFTimeInterval demandTime=CACurrentMediaTime();
        if(source.captureDemandDensity!=densityDemand){source.captureDemandDensity=densityDemand;source.captureDemandSince=demandTime;}
        NSDictionary *binding=bindings[source.logical];
        if(self.native&&[placed containsObject:source.logical]&&boundIdentity(source.identity,binding[@"identity"])&&binding[@"generation"]){
            double density=running&&source.captureSize.width>0?source.captureSize.width/bounds.size.width:pixels.width/bounds.size.width;
            [familyRoots addObject:@{@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"native_bounds":rectJSON(bounds),@"density":@(density),@"capture_sites":[captureSites[source.logical]copy]?:@[],@"capture_all":@(captureAll),@"capture_controls":@([self captureBackingEnabled])}];
        }
        if(!running){[self startCapture:source size:pixels interval:interval];continue;}
        if(source.captureUpdating)continue;
        BOOL samePixels=CGSizeEqualToSize(pixels,source.captureSize),resizeReady=samePixels;
        if(samePixels)source.captureCandidateSince=0;
        else {
            resizeReady=pixels.width>source.captureSize.width||pixels.height>source.captureSize.height||!CGSizeEqualToSize(bounds.size,source.captureNativeSize);
            if(!resizeReady){if(!source.captureCandidateSince||!CGSizeEqualToSize(pixels,source.captureCandidate)){source.captureCandidate=pixels;source.captureCandidateSince=demandTime;}
                resizeReady=demandTime-source.captureCandidateSince>=.5&&demandTime-source.captureDemandSince>=.5;}
        }
        CGSize configured;
        if(DWCaptureConfigurationUpdate(source.captureConfiguration,pixels,interval,resizeReady,&configured))
            [self updateCapture:source size:configured native:bounds.size interval:interval];
    }
    // Overlay roots need geometry observations even outside the current view:
    // a child can extend into a display while its root is offscreen. Only
    // placements request capture; observation alone starts no child stream.
    if(!self.native)for(LiveSource *source in self.sources.allValues){
        NSDictionary *binding=bindings[source.logical];CGRect bounds=CGRectZero;
        if(source.detached||source.synth||source.error||!source.router.bounds||!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"]
           ||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&bounds)||CGRectIsEmpty(bounds)||CGRectIsInfinite(bounds))continue;
        CGSize pixels=[self capturePixels:source native:bounds.size placements:pictures scales:scales demandDensity:NULL];
        double density=pixels.width/bounds.size.width;
        [familyRoots addObject:@{@"window":source.logical,@"identity":source.identity,@"generation":binding[@"generation"],@"native_bounds":rectJSON(bounds),@"density":@(density),@"capture":@(source.replicaWanted),@"capture_sites":[captureSites[source.logical]copy]?:@[],@"capture_all":@(captureAll),@"capture_controls":@([self captureBackingEnabled])}];
    }
    if(!self.nativeFamilies){__weak Desktop *weak=self;self.nativeFamilies=[[DWNativeReplicaFamilies alloc]initWithChanged:^(NSNumber *window){Desktop *d=weak;if(!d||d.cleaning||d.sessionInactive)return;
        if(!d.native&&d.overlayFamilyDescriptions!=d.nativeFamilies.descriptions){[d render];return;}
        if([d.compositor contentChanged:window])[d startFrames];}];}
    [self.nativeFamilies describe:familyRoots rate:familyRate];
}
// One bounded shareable-content refresh for every due, visible failed source.
// No permission request, stale filter reuse, or window mutation is involved.
// A late answer cannot replace a newer retry, detached binding or reused PID/WID.
- (void)captureRecovery {
    if(self.cleaning||self.sessionInactive||self.native.ended||self.captureRecoveryReading)return;
    CFTimeInterval now=CACurrentMediaTime();NSMutableArray<LiveSource *> *due=[NSMutableArray array];
    for(LiveSource *source in self.sources.allValues)if(source.captureRecovering&&!source.detached&&!source.synth&&(!self.native||source.replicaWanted)&&source.captureRetryAt<=now)[due addObject:source];
    if(!due.count)return;
    if(self.manager){
        NSMutableSet *placed=[NSMutableSet set];for(NSDictionary *p in [self presentationSnapshot][@"placements"])if(!self.native||[self.nativeViews replica:p[@"window"] output:p[@"output"]])[placed addObject:p[@"window"]];
        for(LiveSource *source in due.copy)if(![self.manager capture:source.logical placed:[placed containsObject:source.logical]])[due removeObject:source];
    }
    if(!due.count)return;
    if(!CGPreflightScreenCaptureAccess()){
        NSError *error=[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorUserDeclined userInfo:@{NSLocalizedDescriptionKey:@"Screen Recording access is no longer available"}];
        for(LiveSource *source in due)[source captureFailed:error];return;
    }
    self.captureRecoveryReading=YES;NSUInteger generation=++self.captureRecoveryGeneration;NSArray<LiveSource *> *asked=due.copy;__weak Desktop *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        Desktop *d=weak;if(!d||d.cleaning||!d.captureRecoveryReading||d.captureRecoveryGeneration!=generation)return;
        d.captureRecoveryReading=NO;d.captureRecoveryGeneration++;
        NSError *error=[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorFailedToStart userInfo:@{NSLocalizedDescriptionKey:@"Refreshing the capture source timed out"}];
        for(LiveSource *source in asked)if(d.sources[source.logical]==source&&!source.detached&&source.captureRecovering)[source captureFailed:error];
    });
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){dispatch_async(dispatch_get_main_queue(),^{
        Desktop *d=weak;if(!d||d.cleaning||!d.captureRecoveryReading||d.captureRecoveryGeneration!=generation)return;d.captureRecoveryReading=NO;
        NSMutableDictionary<NSNumber *,SCWindow *> *windows=[NSMutableDictionary dictionary];for(SCWindow *window in content.windows)windows[@(window.windowID)]=window;
        for(LiveSource *source in asked){
            if(d.sources[source.logical]!=source||source.detached||!source.captureRecovering||source.stream||d.sessionInactive||d.native.ended||(d.native&&!source.replicaWanted))continue;
            NSDictionary *info=windowInfo(source.router.wid);
            if(sourceGone(source,info)||!DWInScope(d.scope,source.router.pid)){[d track:source info:info];continue;}
            if(error){[source captureFailed:error];continue;}
            SCWindow *window=windows[@(source.router.wid)];
            if(!window||window.owningApplication.processID!=source.router.pid){[source captureFailed:[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorNoCaptureSource userInfo:@{NSLocalizedDescriptionKey:@"The capture window is not available yet"}]];continue;}
            source.window=window;CGSize pixels=source.captureSize;
            if(pixels.width<1||pixels.height<1)pixels=source.buffer;
            [d startCapture:source size:pixels interval:[d captureInterval]];
        }
    });}];
}
// Exports draw at canvas scale, independent of zoom. Native one-shot capture sees
// the transformed window's pixel density; request that raster instead of padding
// it to an untransformed size. It cannot recover detail lost at an overview zoom.
// Cold ScreenCaptureKit setup
// can require the main queue: return the IPC handler before waiting for it. The
// request owns its snapshots, leaves live-stream configuration alone, and expires
// after two seconds. Late completions cannot install pixels or answer twice.
- (void)prepareScreenshot:(NSDictionary *)effect completed:(void (^)(NSString *))completed {
    if(!self.manager){completed(nil);return;}
    if(self.exportSources){completed(@"another screenshot is preparing");return;}
    if(!CGPreflightScreenCaptureAccess()){completed(@"Screen Recording access is unavailable; no snapshot requested");return;}
    if(self.native.ended){completed(@"native presentation has ended");return;}
    NSDictionary *alone=asDict(asDict(effect[@"target"])[@"Window"]);NSDictionary *focus=asDict([self call:@{@"op":@"snapshot"}][@"focus"]);NSNumber *wanted=alone?(asNumber(alone[@"window"])?:asNumber(focus[@"intent"])):nil;
    NSArray *windows=alone?(wanted?@[wanted]:@[]):self.sources.allKeys;self.exportSources=[NSMutableDictionary dictionary];self.exportAttachments=[NSMutableDictionary dictionary];self.exportOrdering=nil;
    DWExportFrame *request=[DWExportFrame new];
    void (^finish)(NSString *)=^(NSString *failure){if(atomic_exchange(&request->completed,YES))return;completed(failure);};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{finish(@"full-resolution snapshot did not arrive within two seconds");});
    // Native presentation has neither an SCWindow nor a capture stream. Enumerate
    // once, then select only the fresh identities already bound by this run.
    if(windows.count){
        NSMutableArray *roots=[NSMutableArray array];NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
        for(NSNumber *logical in windows){LiveSource *source=self.sources[logical];if(!source||source.synth)continue;NSDictionary *binding=nil;
            for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:logical])binding=asDict(window[@"source"]);
            if(source.detached||!DWInScope(self.scope,source.router.pid)||!boundIdentity(source.identity,binding[@"identity"])||!binding[@"generation"]){finish(@"native screenshot binding expired");return;}
            [roots addObject:@{@"window":logical,@"source":source,@"identity":[source.identity copy],@"generation":binding[@"generation"],@"capture_key":NSUUID.UUID.UUIDString}];}
        NSArray *asked=roots.copy;request->presenter=self.native;request->nativeFamilies=!self.native||self.native.familiesNeeded;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *failure=nil;NSArray *plan=DWNativeExportPlan(asked,request->nativeFamilies,&failure);
            if(!plan){dispatch_async(dispatch_get_main_queue(),^{if(!atomic_load(&request->completed))finish(failure?:@"native screenshot family is unavailable");});return;}
            if(atomic_load(&request->completed))return;
            dispatch_async(dispatch_get_main_queue(),^{if(atomic_load(&request->completed))return;
                request->nativeItems=plan;[self requestNativeExport:request index:0 attempt:0 completed:finish];});
        });
    }else [self captureExportWindows:windows index:0 content:nil request:request completed:finish];
}
- (void)retryNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt error:(NSError *)error completed:(void (^)(NSString *))completed {
    if(atomic_load(&request->completed))return;
    if(attempt>=2||!DWExportRetryable(error)){completed(error.localizedDescription?:@"native screenshot capture failed");return;}
    // Re-enumeration never changes the audited family plan or its bindings.
    // Each new attempt repeats identity, parent-chain and own-bounds checks.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.08*(1u<<attempt)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(!atomic_load(&request->completed))[self requestNativeExport:request index:index attempt:attempt+1 completed:completed];});
}
- (void)requestNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt completed:(void (^)(NSString *))completed {
    if(atomic_load(&request->completed))return;
    if(self.cleaning||stopped||self.sessionInactive||self.native!=request->presenter||self.native.ended){completed(@"native screenshot cancelled or its session ended");return;}
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{if(atomic_load(&request->completed))return;
            if(error){[self retryNativeExport:request index:index attempt:attempt error:error completed:completed];return;}
            if(!content){completed(@"native screenshot supplied no window list");return;}
            [self captureNativeExport:request index:index attempt:attempt content:content completed:completed];});
    }];
}
- (void)captureNativeExport:(DWExportFrame *)request index:(NSUInteger)index attempt:(NSUInteger)attempt content:(SCShareableContent *)content completed:(void (^)(NSString *))completed {
    if(atomic_load(&request->completed))return;
    if(self.cleaning||stopped||self.sessionInactive||self.native!=request->presenter||self.native.ended){completed(@"native screenshot cancelled or its session ended");return;}
    NSDictionary *snapshot=[self call:@{@"op":@"snapshot"}];
    for(NSDictionary *item in request->nativeItems){LiveSource *source=item[@"source"];NSDictionary *binding=nil;
        for(NSDictionary *window in snapshot[@"windows"])if([window[@"window"]isEqual:item[@"window"]])binding=asDict(window[@"source"]);
        if(self.sources[item[@"window"]]!=source||source.detached||!DWInScope(self.scope,source.router.pid)||!boundIdentity(source.identity,item[@"identity"])
            ||!boundIdentity(source.identity,binding[@"identity"])||![binding[@"generation"]isEqual:item[@"generation"]]){completed(@"native screenshot binding changed during capture");return;}}
    if(index>=request->nativeItems.count){
        // Re-read the complete family before composition. A new/removed child,
        // changed bounds or changed child order cannot silently produce a partial
        // family from captures made earlier in this request.
        NSMutableArray *roots=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
        for(NSDictionary *item in request->nativeItems)if(![seen containsObject:item[@"window"]]){
            [seen addObject:item[@"window"]];[roots addObject:@{@"window":item[@"window"],@"source":item[@"source"],@"identity":item[@"identity"],@"generation":item[@"generation"],@"capture_key":item[@"capture_key"]}];}
        NSArray *asked=roots.copy;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *failure=nil;NSArray *fresh=DWNativeExportPlan(asked,request->nativeFamilies,&failure);BOOL same=[fresh isEqual:request->nativeItems];
            dispatch_async(dispatch_get_main_queue(),^{if(atomic_load(&request->completed))return;
                if(self.cleaning||stopped||self.sessionInactive||self.native!=request->presenter||self.native.ended){completed(@"native screenshot cancelled or its session ended");return;}
                NSDictionary *current=[self call:@{@"op":@"snapshot"}];NSMutableDictionary *bindings=[NSMutableDictionary dictionary];for(NSDictionary *window in current[@"windows"])if(asDict(window[@"source"]))bindings[window[@"window"]]=window[@"source"];
                for(NSDictionary *item in request->nativeItems){NSDictionary *binding=bindings[item[@"window"]];LiveSource *source=item[@"source"];
                    if(self.sources[item[@"window"]]!=source||source.detached||!DWInScope(self.scope,source.router.pid)||!boundIdentity(source.identity,item[@"identity"])||!boundIdentity(item[@"identity"],binding[@"identity"])||![item[@"generation"]isEqual:binding[@"generation"]]){completed(@"native screenshot source changed before composition");return;}}
                if(same)self.exportOrdering=DWExportOrderCohort(request->nativeItems);
                completed(same?nil:failure?:@"native screenshot family changed before composition");
            });
        });return;
    }
    NSDictionary *item=request->nativeItems[index],*identity=item[@"member"];LiveSource *source=item[@"source"];NSNumber *logical=item[@"window"];
    SCWindow *capturable=nil;
    for(SCWindow *candidate in content.windows)if(candidate.windowID==[identity[@"wid"]unsignedIntValue]&&candidate.owningApplication.processID==[identity[@"pid"]intValue]){capturable=candidate;break;}
    if(!capturable){
        NSError *missing=[NSError errorWithDomain:SCStreamErrorDomain code:SCStreamErrorNoCaptureSource userInfo:@{NSLocalizedDescriptionKey:@"native family member is unavailable for screenshot capture"}];
        [self retryNativeExport:request index:index attempt:attempt error:missing completed:completed];return;
    }
    CGRect bounds=jsonRect(item[@"native_bounds"]);SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:capturable];
    CGRect area=filter.contentRect;double density=filter.pointPixelScale;
    if(!(isfinite(area.size.width)&&isfinite(area.size.height)&&area.size.width>0&&area.size.height>0&&isfinite(density)&&density>0)){completed(@"native screenshot has no capturable pixel area");return;}
    CGSize available=CGSizeMake(ceil(area.size.width*density),ceil(area.size.height*density));
    double shrink=fmin(1,fmin(ceil(bounds.size.width*2)/available.width,ceil(bounds.size.height*2)/available.height));
    CGSize pixels=CGSizeMake(MAX(1,floor(available.width*shrink)),MAX(1,floor(available.height*shrink)));
    if(pixels.width>16384||pixels.height>16384){completed(@"window snapshot exceeds the 16384px per-side limit");return;}
    SCScreenshotConfiguration *config=[SCScreenshotConfiguration new];config.width=(NSInteger)pixels.width;config.height=(NSInteger)pixels.height;config.destinationRect=CGRectMake(0,0,pixels.width,pixels.height);config.showsCursor=NO;config.ignoreShadows=YES;config.ignoreClipping=YES;config.includeChildWindows=NO;config.dynamicRange=SCScreenshotDynamicRangeSDR;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        if(atomic_load(&request->completed))return;
        if(!DWNativeExportCurrent(item,request->nativeFamilies)){dispatch_async(dispatch_get_main_queue(),^{if(!atomic_load(&request->completed))completed(@"native family member changed before screenshot capture");});return;}
        [SCScreenshotManager captureScreenshotWithFilter:filter configuration:config completionHandler:^(SCScreenshotOutput *output,NSError *error){
            if(atomic_load(&request->completed))return;
            DWExportFrame *result=[DWExportFrame new];result->failure=error.localizedDescription;
            if(!result->failure&&!DWNativeExportCurrent(item,request->nativeFamilies))result->failure=@"native family member changed identity, ancestry or own bounds during capture";
            if(!result->failure)result->pixels=DWExportPixels(output.sdrImage);
            if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"export: native window=%s member=%s requested=%.0fx%.0f image=%zux%zu\n",logical.stringValue.UTF8String,[identity[@"wid"]stringValue].UTF8String,pixels.width,pixels.height,output.sdrImage?CGImageGetWidth(output.sdrImage):0,output.sdrImage?CGImageGetHeight(output.sdrImage):0);
            dispatch_async(dispatch_get_main_queue(),^{
                if(atomic_load(&request->completed))return;
                if(self.cleaning||stopped||source.detached||self.sources[logical]!=source||self.native!=request->presenter||self.native.ended){completed(@"native screenshot source or session ended during capture");return;}
                if(error){[self retryNativeExport:request index:index attempt:attempt error:error completed:completed];return;}
                if(result->failure){completed(result->failure);return;}
                if(!result->pixels||CVPixelBufferGetWidth(result->pixels)<pixels.width||CVPixelBufferGetHeight(result->pixels)<pixels.height){completed(@"native snapshot supplied fewer pixels than requested");return;}
                if([identity[@"wid"]isEqual:item[@"identity"][@"wid"]]){
                    LiveSource *export=[LiveSource new];export.composited=YES;export.logical=logical;export.frames=source.frames;[export installPixels:result->pixels];self.exportSources[logical]=export;
                }else{DWCanvasAttachment *image=[DWCanvasAttachment new];image.key=item[@"capture_member_key"];image.buffer=result->pixels;image.unitRect=jsonRect(item[@"unit_rect"]);
                    NSMutableArray *family=self.exportAttachments[logical];if(!family){family=[NSMutableArray array];self.exportAttachments[logical]=family;}[family addObject:image];}
                [self captureNativeExport:request index:index+1 attempt:0 content:content completed:completed];
            });
        }];
    });
}
- (void)captureExportWindows:(NSArray<NSNumber *> *)windows index:(NSUInteger)index content:(SCShareableContent *)content request:(DWExportFrame *)request completed:(void (^)(NSString *))completed {
    (void)content; // Native exports use the separately audited family plan above.
    if(atomic_load(&request->completed))return;
    if(self.cleaning||stopped){completed(@"screenshot cancelled during shutdown");return;}
    while(index<windows.count){
        NSNumber *window=windows[index++];LiveSource *source=self.sources[window];if(!source||source.synth||source.error||!source.window)continue;
        CGRect bounds=CGRectZero;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&bounds))continue;
        CGSize pixels=CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2));
        if(source.pixels&&source.buffer.width>=pixels.width&&source.buffer.height>=pixels.height)continue;
        if(pixels.width>16384||pixels.height>16384){completed(@"window snapshot exceeds the 16384px per-side limit");return;}
        SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:source.window];
        SCStreamConfiguration *config=[SCStreamConfiguration new];config.width=(size_t)pixels.width;config.height=(size_t)pixels.height;config.pixelFormat=kCVPixelFormatType_32BGRA;config.showsCursor=NO;config.ignoreShadowsSingleWindow=YES;config.ignoreGlobalClipSingleWindow=YES;compositedStream(config,source);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            [SCScreenshotManager captureSampleBufferWithFilter:filter configuration:config completionHandler:^(CMSampleBufferRef sample,NSError *error){
                if(atomic_load(&request->completed))return;
                DWExportFrame *result=[DWExportFrame new];if(sample)result->sample=(CMSampleBufferRef)CFRetain(sample);result->failure=error.localizedDescription;
                dispatch_async(dispatch_get_main_queue(),^{
                    if(atomic_load(&request->completed))return;
                    if(source.detached||self.cleaning||stopped){completed(@"window closed or screenshot cancelled during capture");return;}
                    if(result->failure){completed(result->failure);return;}
                    CVPixelBufferRef image=result->sample&&CMSampleBufferIsValid(result->sample)?CMSampleBufferGetImageBuffer(result->sample):NULL;
                    if(!image){completed(@"snapshot supplied no valid pixels");return;}
                    if(CVPixelBufferGetWidth(image)<pixels.width||CVPixelBufferGetHeight(image)<pixels.height){completed(@"snapshot supplied fewer pixels than requested");return;}
                    LiveSource *export=[LiveSource new];export.composited=YES;export.logical=window;export.frames=source.frames;[export installPixels:image];self.exportSources[window]=export;
                    [self captureExportWindows:windows index:index content:nil request:request completed:completed];
                });
            }];
        });return;
    }
    completed(nil);
}
// A window that came, went or was renamed by itself: the flight its reply armed is
// flown, and the scene is saved on the next poll unless the reply says nothing changed.
// Its focus request, for a new window or for the one that follows a close, is the
// coordinator's to perform on the native window or to answer focus_logical, like the
// request of any other reply; a reply without one withdraws only work in flight for a
// request the controller has dropped. Such a reply carries no other effect, but for the size transaction of a window whose
// rule names a size, which -attach:logical:world:placed: hands to the resize coordinator itself.
- (void)follow:(NSDictionary *)reply {
    NSDictionary *effect=asDict(reply[@"effect"]);[self.navigation perform:effect?@{@"effect":effect}:@{}];
    if(asDict(reply[@"navigation"])){if(!self.navigation)self.flying=YES;[self ensureFrames];}
    if(![reply[@"dirty"]isEqual:@NO])self.sceneDirty=YES;
}
// Native readback: is a size transaction of this window live with no effect owed? Only a resize grab is, between two sizes it asks: the
// controller takes no close, removal or observation of the window meanwhile, exactly as while a result is owed.
- (BOOL)grabbed:(LiveSource *)source { return self.resize&&![[self.resize busyWindow]isEqual:source.logical]&&![self.resize canRemove:source.logical]; }
- (void)detach:(LiveSource *)source {
    [self cancelNavigation];
    // Only this window's transaction is cancelled: its last read is then all that is waited for.
    // A resize grab of this window at rest owes no result and is cancelled the same way: one read follows, and ends it.
    if(source.detached)return;if([[self.resize busyWindow]isEqual:source.logical]||[self grabbed:source])[self.resize cancel];
    [self cancelCapturedInputForWindow:source.logical];
    for(DesktopView *view in self.views)if(view.pressedSource==source)[view releasePressed];
    if(![self call:@{@"op":@"remove_source",@"window":source.logical,@"identity":source.identity,@"keep_placeholder":@YES}])return;
    [self drop:source];
}
// The shell's half of a source the controller no longer binds: held button, kept frame, stream and table.
- (void)drop:(LiveSource *)source {
    [self cancelCapturedInputForWindow:source.logical];
    [self forgetNativeFamily:source];
    for(DesktopView *view in self.views)if(view.pressedSource==source)[view releasePressed];source.detached=YES;[self.native unbound:source.identity];[source.synth stop];source.synth=nil;[source clearSample];[self.manager forget:source.logical];
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
- (void)windowAppeared:(DWWindowCandidate *)window {
    // The manager has marked it offered and will not offer it again while it stays: a window nothing here can adopt now is let go.
    if(self.cleaning||!self.panels.count){[self windowNotAdopted:window.window pid:window.pid];return;}
    // A positively identified child belongs to its already managed native
    // parent. Do not also adopt it as an independent canvas root.
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.pid==window.pid&&source.router.wid!=window.window){
        NSMutableDictionary *identity=[source.identity mutableCopy];identity[@"wid"]=@(window.window);
        if(DWNativeWindowBelongsToRoot(identity,source.identity)){[self windowFamilyChanged:window.pid];return;}
    }
    // Its focus event may have come before it was bound, and no other follows: native focus is read again at the next poll, not a reconciliation later.
    if([self attach:window logical:nil world:nil placed:YES]){self.lastObservation=0;return;}
    // Nobody chose this window: a refusal is a passing note.
    NSString *note=[NSString stringWithFormat:@"%@ window not adopted: %@",window.applicationName?:@"A",self.statusText?:@"refused"];
    [self say:note];[self flashStatus:note];[self render];
    [self windowNotAdopted:window.window pid:window.pid];
}
// The helper's arrival veil holds a new window invisible until a frame places it; one that is never to be placed is let go at once
// rather than at the helper's own bound. Several arrive together at times, so the frame that carries their releases is made once.
- (void)windowNotAdopted:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning||!self.native||self.native.ended)return;
    // A window the manager does not take for a window of its own may still be a child of a root that is placed (a hover card, a completion list,
    // a sheet): the family reconciliation places it with its root, which also lifts the helper's veil. Releasing it at once would show it where
    // the application put it, not where the browser is drawn. It is released after DWFamilyChildGrace if nothing has placed it by then.
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&source.router.pid==pid&&source.router.wid!=window){
        NSMutableDictionary *identity=[source.identity mutableCopy];identity[@"wid"]=@(window);
        if(!DWNativeWindowBelongsToRoot(identity,source.identity))continue;
        if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native decline deferred pid=%d wid=%u root=%u at=%.6f\n",(int)pid,(unsigned)window,(unsigned)source.router.wid,NSProcessInfo.processInfo.systemUptime);
        [self windowFamilyChanged:pid];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(DWFamilyChildGrace*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self releaseUnplacedWindow:window pid:pid];});
        return;
    }
    [self releaseUnplacedWindow:window pid:pid];
}
// The release itself. The presenter refuses it for a window it has bound, so one the family placed in the meantime is never released.
- (void)releaseUnplacedWindow:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning||!self.native||self.native.ended)return;
    NSArray *born=birth(pid);if(born.count!=2)return;
    if(getenv("INFINIFY_DEBUG"))fprintf(stderr,"debug: native decline pid=%d wid=%u at=%.6f\n",(int)pid,(unsigned)window,NSProcessInfo.processInfo.systemUptime);
    [self.native declineWindow:@{@"pid":@(pid),@"wid":@(window),@"birth_sec":born[0],@"birth_usec":born[1]}];
    if(self.declineFrameQueued)return;
    self.declineFrameQueued=YES;
    dispatch_async(dispatch_get_main_queue(),^{self.declineFrameQueued=NO;if(!self.cleaning&&!self.sessionInactive&&self.native&&!self.native.ended)[self render];});
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
    if(![note isEqual:self.discoveryNote]){self.discoveryNote=note;[self say:note];}
    [self flashStatus:note];[self render];
}
// Did close-window or suspend-window ask this window to close? The controller's mark.
- (BOOL)marked:(LiveSource *)source { return asDict([self call:@{@"op":@"snapshot"}][@"lifecycle"][@"marks"])[source.logical.stringValue]!=nil; }
// Session departure and unexpected native loss cancel the same input/frame
// state and drain the existing helper. Outputs and world geometry stay in place.
- (BOOL)nativeUnavailable { return self.native&&(self.native.ended||self.nativeResumeWanted||self.nativeRestoring||self.nativeResumeInFlight); }
- (void)suspendPresentationLeavingSession:(BOOL)leaving {
    [self closeCaptureEdgeGuard:YES];
    [self clearNativeFillPresentation];
    self.compositor.nativeMenuBackground=NO;
    self.nativeMouseOwner=nil;
    for(LiveSource *source in self.sources.allValues){source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.observationEpoch;}
    [self cancelCapturedInputForWindow:nil];
    [self cancelGestures];[self cancelNativeInput];[self.panLaunch cancel];
    for(DesktopView *view in self.views){view.scrollPan=nil;view.scrollPanTime=0;view.lastScrollPan=0;if(view.gesture){view.clearsFocus=NO;view.lastDragPan=0;[view released:view.lastPoint at:NSProcessInfo.processInfo.systemUptime];}}
    if(![self sizing])[self.resize cancel];
    [self.navigation invalidate];self.navigation.enabled=NO;
    [self.frameDriver invalidate];self.frameDriver=nil;self.frameFlying=NO;self.flying=NO;self.pointerWanted=NO;
    // Held input is cancelled first; departure is inactive before any native
    // drain/completion can ask to reconnect, even if that completion is immediate.
    if(leaving)self.sessionInactive=YES;
    [self stopNativeTransferTimer];self.nativeOwnershipTransfer=nil;[self.canvasCursor reset];[self saveScene];
    [self.nativeFamilies reset];self.overlayFamilySnapshot=self.overlayFamilyBase=self.overlayFamilyDescriptions=nil;
    // Capture work stops with presentation in both backends. Retain overlay
    // bindings/shareable windows so normal demand can resume them on return.
    self.captureRecoveryGeneration++;self.captureRecoveryReading=NO;
    for(LiveSource *source in self.sources.allValues){source.replicaWanted=NO;[self stopCapture:source];}
    if(self.native){[self.nativeViews reset];for(LiveSource *source in self.sources.allValues){source.observationToken=++self.observationEpoch;[self forgetNativeFamily:source];source.window=nil;[source clearSample];}}
    self.nativeSessionEpoch++;
    if(self.nativeEndpoints.count){
        // Keep the input bridge's physical button-pair bookkeeping alive: a
        // cancelled grab's drag/up still belongs to its swallowed down event.
        self.nativeResumeWanted=YES;self.nativeResumeFailures=0;self.nativeResumeAfter=0;
        if(!self.nativeRestoring){self.nativeRestoring=YES;__weak Desktop *weak=self;
            [self.native suspendWithCompletion:^{Desktop *d=weak;if(!d)return;d.nativeRestoring=NO;[d resumeNative];}];}
    }
}
- (void)leftSession {
    if(self.cleaning||self.sessionInactive)return;
    [self suspendPresentationLeavingSession:YES];
}
- (void)resumeNative {
    if(self.cleaning||stopped)return;
    if(self.native.ended&&self.nativeEndpoints.count&&!self.nativeResumeWanted&&!self.sessionInactive){
        // Loss can occur with the desktop still active. Enter the same drain and
        // authenticated re-admission used after session return, once per loss.
        self.statusText=@"Native presentation lost; restoring and reconnecting";[self say:self.statusText];
        [self suspendPresentationLeavingSession:NO];[self render];
    }
    if(self.sessionInactive||!self.panels.count||!self.nativeResumeWanted||self.nativeRestoring||self.nativeResumeInFlight||CACurrentMediaTime()<self.nativeResumeAfter)return;
    // The Dock was replaced: the old endpoint is gone with it, and the reloader says when a new one answers (-adoptEndpoint:).
    if(self.dockReloader.awaitingEndpoint)return;
    // Preserve the endpoint, credentials and authority selected at launch.
    // Scoped recovery pins the original process births; desktop recovery
    // reaudits its Dock peer. Candidates stay inert until this main turn.
    NSArray *endpoints=self.nativeEndpoints;NSDictionary *scope=self.scope;uint64_t epoch=self.nativeSessionEpoch;BOOL desktopMode=self.nativeDesktopMode;
    self.nativeResumeInFlight=YES;__weak Desktop *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *failure=nil;NSDictionary *endpoint=endpoints.firstObject;
        DWNativePresenter *candidate=desktopMode?[DWNativePresenter reconnectedDesktopPresenterAt:endpoint[@"runtime"] nonce:endpoint[@"nonce"] why:&failure]
            :[DWNativePresenter reconnectedPresentersAt:endpoints scope:scope why:&failure];
        dispatch_async(dispatch_get_main_queue(),^{Desktop *d=weak;
            if(d)d.nativeResumeInFlight=NO;
            if(!d||d.cleaning||stopped||d.sessionInactive||epoch!=d.nativeSessionEpoch||!d.nativeResumeWanted){[candidate suspendWithCompletion:nil];return;}
            if(!candidate||![candidate activate]){
                [candidate suspendWithCompletion:nil];d.nativeResumeFailures++;
                d.nativeResumeAfter=CACurrentMediaTime()+fmin(30,.25*pow(2,MIN(d.nativeResumeFailures-1,7u)));
                NSString *note=[@"Native session waiting: " stringByAppendingString:failure?:@"a helper was lost before admission"];
                if(![d.nativeResumeNote isEqual:note]){d.nativeResumeNote=note;[d say:note];}return;
            }
            d.native=candidate;d.nativeResumeWanted=NO;d.nativeResumeFailures=0;d.nativeResumeNote=nil;
            [d say:@"Native presentation reconnected after authenticated restoration audit"];d.statusText=[d restingStatus];
            d.navigation.enabled=YES;d.lastObservation=0;
            for(LiveSource *source in d.sources.allValues){source.observationToken=++d.observationEpoch;[source invalidateNativeButtons];
                if(source.nativeMinimized||source.nativeVisibilityHeld){source.nativeVisibilityRevision++;source.nativeVisibilityWanted=YES;source.nativeVisibilityRetryAt=0;source.nativeVisibilityStable=nil;source.nativeVisibilityRestore=nil;}}
            d.windowObservationAgain=YES;[d requestWindowObservation];[d configureNativeInput];[d render];
        });
    });
}
- (void)returned {
    if(self.cleaning||!self.desktopUp||!self.session.ready)return;
    self.sessionInactive=NO;self.navigation.enabled=!self.native||!self.native.ended;self.lastObservation=0;[self resumeNative];
    if(!self.panels.count){[self openPanels];if(!self.panels.count)return;[self runAutostart];}
    for(LiveSource *source in self.sources.allValues)if(source.captureRecovering)source.captureRetryAt=CACurrentMediaTime();
    for(LiveSource *source in self.sources.allValues)if(source.nativeMinimized||source.nativeVisibilityHeld)[self requestVisibility:source];
    BOOL screensChanged=![self.panelScreens isEqual:physicalScreens()];
    if(screensChanged)[self screensChanged:nil];
    // Unmanaged fixture canvases do not have captureDemand. Resume their
    // existing sources explicitly, using the current screens' capture rate.
    if(!self.native&&!self.manager)for(LiveSource *source in self.sources.allValues)if(!source.stream&&!source.detached&&!source.synth&&!source.error&&!source.captureRecovering&&source.window){
        CGSize pixels=source.captureSize;if(pixels.width<1||pixels.height<1)pixels=source.buffer;
        [self startCapture:source size:pixels interval:[self captureInterval]];
    }
    if(screensChanged)return;[self refreshOutputUsableAreas];[self refreshMacWallpapers];
    [self windowDiscoveryRequested];
    if(self.windowed){[self render];return;}
    for(NSUInteger i=0;i<self.panels.count&&i<self.views.count;i++){NSPanel *panel=self.panels[i];NSRect frame=topRect(self.views[i].globalBounds);if(!NSEqualRects(panel.frame,frame))[panel setFrame:frame display:YES];[panel orderFrontRegardless];}
    [self render];
}
// A launch that cannot open its canvas: a grant is missing, or the saved scene could not be loaded (the window then
// says that and offers Quit alone). The canvas opens from the window itself once required grants are there, and autostart
// runs then: a Relaunch from the window is this run started again, whose config load hands the autostart commands over
// once more, so they must not have run here already.
- (void)onboard {
    __weak Desktop *weak=self;
    if(!self.onboarding)self.onboarding=[[DWOnboarding alloc]initWithProceed:^{[weak openCanvas:nil];[weak runAutostart];} relaunch:^{weak.relaunch=YES;[weak quit:nil];} quit:^{[weak quit:nil];} requiresScreenCapture:self.native==nil];
    [self.onboarding show:self.startupError];
}
// Log out, restart and shut down ask an application to quit through AppKit, whose terminate: ends the process where it
// stands: no fullscreen ended, nothing saved. The quit is performed here to its end, as main() performs any other, and
// AppKit then exits with status 0. A quit already under way (SIGTERM came first: launchd sends it at log out as well)
// is waiting further down this very stack, since -cleanup handles events while it waits, and cannot go on until this
// returns: what it had left is given up but for the save, and the process ends here.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;if(self.cleaning){[self saveScene];return NSTerminateNow;}
    [self quit:nil];[self.ipc stop];self.ipc=nil;[self cleanup];[self.chooser close];[self.onboarding close];return NSTerminateNow;
}
- (void)screensChanged:(NSNotification *)notification {
    // The desktop is rebuilt from no panel as well: its displays may all have gone for a moment (asleep, unplugged), and it is there again when one is.
    // Never while it is being closed: -cleanup handles events while it waits, and a display change then must not reopen what it is closing.
    (void)notification;if(self.demo||self.cleaning||self.sessionInactive||!(self.panels.count||self.desktopUp))return;
    if([self.panelScreens isEqual:physicalScreens()]){[self refreshOutputUsableAreas];[self refreshMacWallpapers];return;}
    [self closeCaptureEdgeGuard:NO];
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
    [self.panels removeAllObjects];[self.views removeAllObjects];for(LiveSource *source in self.sources.allValues)[source.surfaces removeAllObjects];
    // The outputs' compositor layers went with the panels; the rebuilt ones get new layers.
    [self.compositor reset];
    [self stopKeys];[self stopViewKeys];
    [self openPanels];[self saveScene];
}
- (void)requestWindowObservation {
    if(self.cleaning||self.sessionInactive||self.native.ended||!self.manager)return;
    if(!self.windowObserver)self.windowObserver=[DWWindowObserver new];if(self.windowObserver.inFlight)return;
    self.windowObservationAgain=NO;
    NSMutableArray *requests=[NSMutableArray array];
    for(LiveSource *source in self.sources.allValues)if(!source.detached){
        NSMutableDictionary *request=[@{@"logical":source.logical,@"generation":@(source.observationToken),@"identity":source.identity,@"native_bounds":@(self.native!=nil),@"families":@(self.native.familiesNeeded||source.nativeTransferFamilyWanted)}mutableCopy];
        if(source.nativeVisibilityWanted&&CACurrentMediaTime()>=source.nativeVisibilityRetryAt)request[@"visibility_revision"]=@(source.nativeVisibilityRevision);
        if(source.router.bounds)request[@"prior_bounds"]=source.router.bounds;[requests addObject:request];
    }
    DWWindowManager *manager=self.manager;DWNativePresenter *presenter=self.native;uint64_t session=self.nativeSessionEpoch;__weak Desktop *weak=self;__block BOOL reconcile=NO;
    [self.windowObserver requestSources:requests scope:self.scope nativeDiscoveryExclusions:self.native?manager.offeredWindows:nil discovery:^(DWWindowObservationSnapshot *snapshot){
        Desktop *d=weak;CFTimeInterval now=CACurrentMediaTime();
        if(!d||d.cleaning||d.sessionInactive||d.manager!=manager||d.native!=presenter||d.native.ended||d.nativeSessionEpoch!=session
            ||!snapshot.listSucceeded||now-snapshot.startedAt>.1||now-snapshot.finishedAt>.1)return;
        // Timely discovery does not wait behind audits of already bound roots.
        // Adoption still performs its fresh native identity/authority checks.
        reconcile=[manager pollWithWindowRecords:snapshot.orderedOnScreen nativeCandidateBases:snapshot.nativeCandidateBases sampledAt:snapshot.startedAt];
    } completion:^(DWWindowObservationSnapshot *snapshot){
        Desktop *d=weak;CFTimeInterval now=CACurrentMediaTime();
        if(!d||d.cleaning||d.sessionInactive||d.manager!=manager||d.native!=presenter||d.native.ended||d.nativeSessionEpoch!=session)return;
        @try {
        if(!snapshot.listSucceeded||now-snapshot.startedAt>.1||now-snapshot.finishedAt>.1){
            BOOL changed=NO;
            for(DWWindowObservation *observation in snapshot.sources){NSDictionary *request=observation.request;LiveSource *source=d.sources[request[@"logical"]];
                if(source&&source.observationToken==[request[@"generation"]unsignedLongLongValue]&&[source.identity isEqual:request[@"identity"]]&&source.nativeFamily){
                    // This cache has no age-based lifetime. A late, successful
                    // read of exactly the same complete family is a missed
                    // refresh, not evidence that the previous audit changed.
                    // Adopt nothing from it; ordinary idle reconciliation will
                    // retry. Failed or changed reads still revoke the cache.
                    NSDictionary *cached=source.nativeFamily;
                    BOOL unchanged=snapshot.listSucceeded&&observation.state==DWWindowObservationPresent&&observation.hasBounds
                        &&[source.router.bounds isEqual:request[@"prior_bounds"]]
                        &&boundIdentity(cached[@"identity"],source.identity)&&boundIdentity(observation.family[@"identity"],source.identity)
                        &&[observation.family[@"root"]isEqual:source.identity[@"wid"]]
                        &&CGRectEqualToRect(jsonRect(cached[@"native_bounds"]),observation.bounds)
                        &&[asArray(cached[@"members"])isEqual:asArray(observation.family[@"members"])];
                    if(unchanged)continue;
                    [d forgetNativeFamily:source];changed=YES;}}
            if(changed&&!d.frameFlying)[d render];return;
        }
        BOOL describe=NO;
        for(DWWindowObservation *observation in snapshot.sources){
            NSDictionary *request=observation.request;LiveSource *source=d.sources[request[@"logical"]];
            if(!source||source.detached||source.observationToken!=[request[@"generation"]unsignedLongLongValue]||![source.identity isEqual:request[@"identity"]]||![source.router.bounds isEqual:request[@"prior_bounds"]]||CACurrentMediaTime()-observation.sampledAt>.1)continue;
            // Discovery can stay eager after an appearance hint without asking
            // the controller to observe every unchanged overlay root again.
            if(!presenter&&!reconcile&&!source.error&&!source.destroyed)continue;
            [d observeVisibility:observation source:source];
            if(observation.state==DWWindowObservationReadFailed){[d forgetNativeFamily:source];continue;}
            if(observation.state!=DWWindowObservationPresent){[d track:source];describe=YES;continue;}
            if(!DWInScope(d.scope,source.router.pid))continue;
            [d track:source info:observation.info observation:observation];describe=YES;
        }
        if(!d.frameFlying&&(describe||d.sceneDirty))[d render];
        } @finally {if(!d.cleaning&&d.windowObservationAgain)[d requestWindowObservation];}
    }];
}
- (void)poll {
    [self.session poll]; // blocked startup/early wake retries before the inactive early return
    [self updateNativeMouseOwners];
    [self updateNativeFill];
    [self updateNativeVisibility];
    if(self.cleaning||self.sessionInactive)return;
    [self resumeNative];
    if([self nativeUnavailable]){
        // Registered receipts/watchdogs run on main independently of this poll.
        // Keep orphan settlement too, without allowing new input or camera work.
        if(self.resize&&CACurrentMediaTime()-self.lastResizeObservation>=1){self.lastResizeObservation=CACurrentMediaTime();[self.resize reap];}
        return;
    }
    BOOL timing=self.scope&&getenv("INFINIFY_DEBUG")&&atoi(getenv("INFINIFY_DEBUG"))==1;
    CFTimeInterval stages[7]={0};if(timing)stages[0]=CACurrentMediaTime();
    if(self.nativeButtonHover)[self refreshNativeButtons:self.sources[self.nativeButtonHover]];
    if(self.resize&&CACurrentMediaTime()-self.lastResizeObservation>=1){self.lastResizeObservation=CACurrentMediaTime();[self.resize reap];}
    [self endLostInput];
    [self watchCorners];
    if(timing)stages[1]=CACurrentMediaTime();
    // Idle polling keeps the clock current and, while cursor edge pan wants it, the pointer reported; motion found while the timer does not serve it regains the display's rate.
    // A display link calls back only while its display refreshes. Motion it has not served for a quarter of a second (a display asleep, no screen to follow)
    // is ticked here instead, at the poll's pace, so a flight still arrives and a frame timer that never fires cannot hold the canvas still.
    BOOL stalled=self.frameFlying&&CACurrentMediaTime()-self.frameDriver.lastFrame>.25;
    if(!self.frameFlying||stalled){if([self cameraFrame])[self ensureFrames];else if(stalled)self.frameFlying=NO;}
    if(timing)stages[2]=CACurrentMediaTime();
    // Where the observers report native focus (-focusChanged) the focus poll is a reconciliation, once a second.
    if(self.navigation&&CACurrentMediaTime()-self.lastObservation>=(self.manager.live?1:.5)){self.lastObservation=CACurrentMediaTime();[self refreshFocusAccess];[self refreshStageManager];[self.navigation observe];}
    if(timing)stages[3]=CACurrentMediaTime();
    // Managed discovery and reconciliation share one bounded worker observation.
    // Appearance storms can request at the idle poll's pace but never enumerate
    // on the frame thread or queue more than one read. Event/input/resize paths
    // retain their own fresh validation; unmanaged manual sources retain their poll.
    BOOL reconcile=!self.manager;
    if(self.manager){BOOL due=[self.manager reconciliationDue];for(LiveSource *source in self.sources.allValues)if(source.error||source.destroyed||(source.nativeVisibilityWanted&&CACurrentMediaTime()>=source.nativeVisibilityRetryAt))due=YES;if(due)[self requestWindowObservation];}
    BOOL describe=reconcile;
    if(reconcile)for(LiveSource *source in self.sources.allValues)[self track:source];
    if(timing)stages[4]=CACurrentMediaTime();
    [self captureDemand];
    [self captureRecovery];
    [self advanceNativeTransfers];
    // A stopped display link is ordinary idle, not a reason to reserialize
    // every window and rebuild every layer. Clock-only ticks retain this
    // projection; any other command or native family/owner change replaces it.
    NSDictionary *presentation=[self presentationSnapshot];
    describe=describe||self.sceneDirty||!presentation||self.renderedPresentation!=presentation||![self.renderedStatusText?:@"" isEqual:self.statusText?:@""];
    if(self.sceneDirty)[self saveScene];
    if(timing)stages[5]=CACurrentMediaTime();
    // An active compositor already animates the current description at display
    // rate. Preserve reconciliation, exceptional sources and every scene change,
    // without copying/serializing the same idle controller on each poll.
    if(!self.frameFlying){
        if(describe)[self render];
        else if(![self frameComing:NO]){
            // Retry an owed drawable or native restore/rebind without making
            // a new description. Each owner keeps its existing retry fence.
            [self.compositor flushDescribed];[self.native submit];
        }
    }
    if(timing){stages[6]=CACurrentMediaTime();if(stages[6]-stages[0]>=.004&&stages[6]-self.lastPollTiming>=1){self.lastPollTiming=stages[6];
        fprintf(stderr,"poll: total_ms=%.3f input_resize_ms=%.3f camera_ms=%.3f focus_ms=%.3f reconcile_track_ms=%.3f demand_save_ms=%.3f render_ms=%.3f reconcile=%d\n",(stages[6]-stages[0])*1000,(stages[1]-stages[0])*1000,(stages[2]-stages[1])*1000,(stages[3]-stages[2])*1000,(stages[4]-stages[3])*1000,(stages[5]-stages[4])*1000,(stages[6]-stages[5])*1000,reconcile);}}
}
// One look at one bound window: is it gone, was it retitled, where and how large is it now. The poll's look and an event's are this one
// method. Events read afresh; poll observations carry a bounded worker read with
// an unchanged source identity/generation/previous-bounds fence. A second look
// that finds nothing new sends no window_closed and no retitle.
- (void)track:(LiveSource *)source { [self track:source info:windowInfo(source.router.wid)]; }
- (void)track:(LiveSource *)source info:(NSDictionary *)w { [self track:source info:w observation:nil]; }
- (void)track:(LiveSource *)source info:(NSDictionary *)w observation:(DWWindowObservation *)observation {
        source.observationToken=++self.observationEpoch;
        if(self.native&&(self.sessionInactive||self.native.ended)){[self forgetNativeFamily:source];return;}
        // Miniaturization can temporarily remove a WindowServer record. A
        // live process without a destroy hint keeps its minimized binding.
        if(!w&&(source.nativeMinimized||(source.nativeVisibilityHeld&&source.nativeVisibilityWanted))&&!source.destroyed
            &&[birth(source.router.pid)isEqual:source.router.processBirth])return;
        BOOL gone=sourceGone(source,w)||[self destroyed:source info:w];
        if(gone)[self forgetNativeFamily:source];
        // WindowServer owns the complete physical pair and final settling.
        // Neither raw-origin reconciliation nor presenter bounds may race it.
        if(source.nativeMouseOwnership&&!source.nativeMouseAdopting&&!gone)return;
        // Titles follow in a managed run, under native resize too. A refused title is not offered again.
        NSString *title=self.manager&&!gone?asString(w[(id)kCGWindowName]):nil;
        if(title&&![title isEqual:source.title]){[source invalidateNativeButtons];source.title=title;NSString *status=self.statusText;NSDictionary *reply=[self call:@{@"op":@"retitle",@"window":source.logical,@"identity":source.identity,@"title":title}];if(reply)[self follow:reply];else self.statusText=status;}

        // A managed run tells a window that closed from a capture that failed: only the second keeps today's placeholder.
        // A manual run does so for a window close-window or suspend-window asked to close: the controller's mark decides what is left.
        // A size request of this window is still owed its result. The controller takes no close, removal or observation of the window until
        // it has one (bounded: the adapter's deadline, then the coordinator's watchdog), and the end of the transaction looks at the window
        // again (-configureResize). Its bounds are not read meanwhile either: the look that follows the transaction reports them.
        BOOL busy=[[self.resize busyWindow]isEqual:source.logical];
        if(gone&&busy)return;
        // A resize grab of this window whose pointer rests: no result is owed that would find the window gone, so the grab is cancelled
        // here. The one read that follows fails, the transaction ends, and its end looks at the window again and finds it closed. While
        // the window is there its frame is the transaction's to read, not this look's.
        if([self grabbed:source]){if(gone)[self.resize cancel];return;}
        if(gone&&(self.manager||[self marked:source])){[self closed:source];return;}
        if((source.error&&!source.captureRecovering&&!source.nativeReplica)||gone){self.statusText=source.error?:@"A source closed. Its world placeholder is retained for explicit rebind.";[self detach:source];return;}
        if(source.nativeMinimized&&!source.nativeVisibilityWanted&&[w[(id)kCGWindowIsOnscreen]boolValue]){
            [self requestVisibility:source];return; // bounded recovery for a missed deminiaturized hint
        }
        if(source.nativeMinimized||source.nativeVisibilityHeld)return;
        CGRect bounds=CGRectZero;NSDictionary *frame=w[(id)kCGWindowBounds],*family=nil;
        // Native presentation: the window list's bounds are where the helper draws the window, at the size the zoom gives it. Observed
        // as the window's size they would become its world size, drawn smaller again on the next frame, and so on. The window's own
        // frame is read instead, which no transform changes, and the presenter draws from it.
        if(self.native){
            if(busy)return;
            // A deliberately unrequested family is different from a requested
            // audit that failed. Only explicit families:false permits nil; a
            // missing flag or failed requested report still revokes readiness.
            BOOL familyRequested=observation?![observation.request[@"families"]isEqual:@NO]:(self.native.familiesNeeded||source.nativeTransferFamilyWanted);
            if(observation){if(!observation.hasBounds){[self forgetNativeFamily:source];return;}bounds=observation.bounds;family=observation.family;}
            else {if(!DWNativeBounds(source.router.wid,&bounds)){[self forgetNativeFamily:source];return;}if(familyRequested)family=DWNativeWindowFamily(source.identity,NULL);}
            frame=CFBridgingRelease(CGRectCreateDictionaryRepresentation(bounds));[self.native bound:source.identity bounds:bounds family:family?:(familyRequested?@{}:nil)];
        }
        else if(busy||!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)frame,&bounds))return;
        // The application's origin is a presentation basis, not a canvas
        // movement. Display reflow and AppKit tiling can change it without a
        // user drag. Only our gesture path or the explicitly owned native
        // mouse pair may relocate the logical window.
        CGRect prior=CGRectZero;
        if(self.native&&DWInputTrace()&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&prior)
            &&!CGPointEqualToPoint(prior.origin,bounds.origin))
            fprintf(stderr,"debug: native origin window=#%s pid=%d wid=%u old=(%g,%g,%g,%g) new=(%g,%g,%g,%g) raw_delta=(%g,%g) reconcile=basis_only\n",source.logical.description.UTF8String,source.router.pid,source.router.wid,prior.origin.x,prior.origin.y,prior.size.width,prior.size.height,bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height,bounds.origin.x-prior.origin.x,bounds.origin.y-prior.origin.y);
        if(![source.router.bounds isEqual:frame]){
            NSDictionary *candidate=source.nativeButtons?:source.nativeButtonsMoveCandidate;
            // A poll can observe a move before AXMoved is delivered. Retain no
            // public cache until that hint certifies this origin-only change.
            if(!self.native||!DWNativeMovedButtons(candidate,source.identity,bounds))candidate=nil;
            [source invalidateNativeButtons];source.nativeButtonsMoveCandidate=candidate;
            source.router.bounds=frame;
        }
        // Manual sources retry the latest native size after an earlier configuration completes too.
        if(!self.manager&&source.stream&&!CGSizeEqualToSize(source.captureNativeSize,bounds.size))[self updateCapture:source size:CGSizeMake(ceil(bounds.size.width*2),ceil(bounds.size.height*2)) native:bounds.size interval:[self captureInterval]];
        // A helper Space handoff can make AppKit reflow its own frame. Refresh
        // the true native basis without treating that presentation side effect
        // as a world resize. Explicit native mouse ownership remains user intent.
        BOOL spaceReflow=self.native&&[self.native observeSpaceReflow:source.identity bounds:bounds nativeInput:source.nativeMouseAdopting];
        if(spaceReflow&&DWInputTrace()&&!CGSizeEqualToSize(prior.size,bounds.size))
            fprintf(stderr,"debug: native Space reflow window=#%s pid=%d wid=%u before=%gx%g observed=%gx%g world_size=preserved native_frame_restore=unowned\n",source.logical.description.UTF8String,source.router.pid,source.router.wid,prior.size.width,prior.size.height,bounds.size.width,bounds.size.height);
        DriftDesktopObservation controllerObservation={.window=source.logical.unsignedLongLongValue,.birth_sec=[source.identity[@"birth_sec"]longLongValue],.x=bounds.origin.x,.y=bounds.origin.y,.width=bounds.size.width,.height=bounds.size.height,.pid=[source.identity[@"pid"]intValue],.birth_usec=[source.identity[@"birth_usec"]intValue],.wid=[source.identity[@"wid"]unsignedIntValue],.owner=[source.identity[@"owner"]unsignedIntValue],.buffer_width=(uint32_t)source.buffer.width,.buffer_height=(uint32_t)source.buffer.height};
        BOOL current=self.native&&driftwm_desktop_observation_current(self.controller,&controllerObservation);
        if(!current){
            NSDictionary *seen=[self call:@{@"op":spaceReflow?@"observe_presentation":@"observe",@"window":source.logical,@"identity":source.identity,@"source_rect":rectJSON(bounds),@"buffer":@{@"width":@(source.buffer.width),@"height":@(source.buffer.height)}}];
            if([asNumber(seen[@"resized"])boolValue])self.sceneDirty=YES;
        }
        if(self.native){
            NSDictionary *binding=nil;if(family)for(NSDictionary *window in [self call:@{@"op":@"snapshot"}][@"windows"])if([window[@"window"]isEqual:source.logical]){binding=asDict(window[@"source"]);break;}
            if(family&&boundIdentity(family[@"identity"],source.identity)&&boundIdentity(binding[@"identity"],source.identity)&&binding[@"generation"]&&[binding[@"observation_known"]boolValue]&&CGRectEqualToRect(jsonRect(binding[@"observed_rect"]),bounds)){
                NSDictionary *description=@{@"identity":source.identity,@"generation":binding[@"generation"],@"native_bounds":rectJSON(bounds),@"members":asArray(family[@"members"])?:@[]};
                if(![source.nativeFamily isEqual:description]){if(self.captureBackings[source.logical])[self revokeCaptureBackingForWindow:source.logical];source.nativeFamily=description;self.nativeFamilyRevision++;}
            }else [self forgetNativeFamily:source];
        }
        // Event history is probe evidence, not an unbounded production log.
        if(!self.probe&&source.router.sent.count>128)[source.router.sent removeAllObjects];
}
// A window its application reported destroyed is gone once it is also off screen, whether or not the window list still has its number: the
// list may drop it a moment after the report, and may keep it when the application keeps the window object to show again. Until then it
// is looked at on every poll. While the window is still on screen nothing is concluded, and a report still contradicted a second later is
// forgotten. Not observed on a real window: which applications report a window they keep as destroyed is not known.
- (BOOL)destroyed:(LiveSource *)source info:(NSDictionary *)info {
    if(!source.destroyed)return NO;
    if(![info[(id)kCGWindowIsOnscreen]boolValue])return YES;
    if(CACurrentMediaTime()-source.destroyed>1)source.destroyed=0;
    return NO;
}
// DWWindowHost, from the observers: the look the poll takes, taken now and at the windows concerned only.
- (void)windowMoved:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning)return;BOOL matched=NO,changed=NO;
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&source.router.wid==window){
        matched=YES;NSDictionary *report=source.nativeButtons?:source.nativeButtonsMoveCandidate,*identity=source.identity.copy;
        NSString *title=source.title;NSDictionary *prior=source.router.bounds;
        [source invalidateNativeButtons];[self track:source];
        CGRect native=CGRectZero,current=CGRectZero;NSDictionary *info=windowInfo(window);
        if(self.native&&!self.sessionInactive&&!self.native.ended&&self.sources[source.logical]==source&&!source.detached
            &&[source.identity isEqual:identity]&&[source.title isEqual:title]&&[birth(pid)isEqual:source.router.processBirth]
            &&DWInScope(self.scope,pid)&&[info[(id)kCGWindowOwnerPID]intValue]==pid
            &&DWNativeBounds(window,&native)&&CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)source.router.bounds,&current)
            &&CGRectEqualToRect(native,current))source.nativeButtons=DWNativeMovedButtons(report,identity,native);
        [self refreshNativeButtons:source];if(source.title!=title||source.router.bounds!=prior)changed=YES;
    }
    if(!matched)[self windowFamilyChanged:pid];
    if(changed&&!self.frameFlying)[self render];
}
- (void)windowChanged:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning)return;BOOL changed=NO,matched=NO;
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&(!window||source.router.wid==window)){
        matched=YES;
        [source invalidateNativeButtons];
        NSString *title=source.title;NSDictionary *bounds=source.router.bounds;[self track:source];[self refreshNativeButtons:source];if(source.title!=title||source.router.bounds!=bounds)changed=YES;}
    if(!matched)[self windowFamilyChanged:pid];
    // A window that closed was drawn by -closed:. A look that found nothing new draws nothing: the reports of one busy application come 12 times a second.
    if(changed&&!self.frameFlying)[self render];
}
- (void)windowDestroyed:(CGWindowID)window pid:(pid_t)pid {
    if(self.cleaning)return;BOOL matched=NO;
    for(LiveSource *source in self.sources.allValues)if(source.router.pid==pid&&source.router.wid==window){matched=YES;[source invalidateNativeButtons];source.destroyed=CACurrentMediaTime();[self track:source];}
    if(!matched)[self windowFamilyChanged:pid];
}
- (void)windowFamilyChanged:(pid_t)pid {
    if(self.cleaning||self.sessionInactive||self.native.ended||(pid&&!DWInScope(self.scope,pid)))return;
    if(self.native&&!self.native.familiesNeeded){[self windowDiscoveryRequested];return;}
    [self.nativeFamilies invalidatePID:pid];
    if(!self.native){[self captureDemand];[self render];return;}
    for(LiveSource *source in self.sources.allValues)if(!source.detached&&(!pid||source.router.pid==pid)){[self forgetNativeFamily:source];source.observationToken=++self.observationEpoch;[source invalidateNativeButtons];[self refreshNativeButtons:source];}
    // An application's first window has no bound source to invalidate. Its
    // creation hint still requests discovery now, through the same single-flight
    // observer; a hint during a read queues at most one fresh follow-up batch.
    [self windowDiscoveryRequested];
}
- (void)windowDiscoveryRequested {
    if(self.cleaning||self.sessionInactive||self.native.ended||!self.manager)return;
    self.windowObservationAgain=YES;[self requestWindowObservation];
}
// Native focus may have moved (Command-Tab, a click on another window): read now, through the coordinator's own path.
- (void)focusChanged { if(self.cleaning||[self nativeUnavailable]||!self.navigation)return;self.lastObservation=CACurrentMediaTime();[self refreshFocusAccess];[self.navigation observe]; }
// macOS platform rule: applications outlive Infinify, where upstream's clients end with the compositor. A window still fullscreen, or
// still owed its size by a fullscreen that has ended, would keep the display's size after the canvas is gone, so each fullscreen is
// ended and its size transaction performed to its end before anything is shut down, one at a time, the slot being one. Upstream's
// quit ends fullscreen first too. The snapshot is read again before every step: toggle-fullscreen ends the focused window's
// fullscreen before the named output's, and on an output that has none it would enter one. With no fullscreen left, one read-only
// ipc request carries a size still owed. A resize the pointer began is cancelled first; the controller's own finishes. Bounded: an
// unanswered or uncertain resize is left to the shutdown that follows, and the scene then saves the size the window has.
- (void)endFullscreens {
    if(!self.resize||!self.configured)return;
    if(![self sizing])[self.resize cancel];
    CFTimeInterval deadline=CACurrentMediaTime()+3;
    for(int step=0;step<16;step++){
        while((self.resize.obligations||![self.resize canRemove:nil])&&CACurrentMediaTime()<deadline){self.statusText=@"Quit pending: waiting for native resize result";[self render];pump(.01);}
        if(self.resize.obligations||![self.resize canRemove:nil])return;
        NSArray *outputs=asArray([self call:@{@"op":@"snapshot"}][@"outputs"]);NSNumber *held=nil;
        for(id o in outputs)if(asDict(asDict(o)[@"fullscreen"])){held=asNumber(asDict(o)[@"id"]);break;}
        NSNumber *output=held?:asNumber(asDict(outputs.firstObject)[@"id"]);if(!output)return;
        NSString *status=self.statusText;
        NSDictionary *reply=[self call:held?@{@"op":@"action",@"output":held,@"action":@"toggle-fullscreen"}:@{@"op":@"ipc",@"output":output,@"request":@"State"}];
        if(!reply){self.statusText=status;return;}
        if(![self consumeSize:reply]&&!held)return;
    }
}
- (void)cleanup {
    if(self.cleaning)return;
    [self.dockReloader stop];self.dockReloader=nil;
    [self closeCaptureEdgeGuard:YES];
    self.compositor.nativeMenuBackground=NO;
    [self stopMacWallpapers];
    [self cancelCapturedInputForWindow:nil];
    self.cleaning=YES;[self clearNativeFillPresentation];[self stopNativeTransferTimer];self.nativeOwnershipTransfer=nil;[self.canvasCursor reset];self.captureRecoveryGeneration++;self.captureRecoveryReading=NO;
    self.nativeMouseOwner=nil;
    for(LiveSource *source in self.sources.allValues){source.nativeMouseOwnership=nil;source.nativeMouseAdopting=NO;source.observationToken=++self.observationEpoch;}
    [self.nativeFamilies reset];self.nativeFamilies=nil;self.nativeViewSnapshot=nil;self.nativeOwnerSnapshot=nil;self.nativeViewPresenter=nil;self.overlayFamilySnapshot=self.overlayFamilyBase=self.overlayFamilyDescriptions=nil;
    self.nativeSessionEpoch++;self.nativeResumeWanted=NO;
    [self.windowObserver cancel];self.windowObserver=nil;
    [self.globalTrackpad stop];self.globalTrackpad=nil;
    [self.multitouch stop];self.multitouch=nil;self.touchFeed=nil;[self.dockTap stop];self.dockTap=nil;self.dockGuard=nil;
    [self.nativeInput stop];self.nativeInput=nil;[self.pointerGrab reset];[self.relativeMotion reset];[self.tablet reset];
    // Native presentation ends first, while the canvas is still there: every window is put back where and as it was before anything
    // else is shut down, so no wait further down (a size owed, a fullscreen ending) is spent with a window parked or scaled.
    [self.native finish];
    CFTimeInterval restoredBy=CACurrentMediaTime()+2.1;
    while(self.nativeRestoring&&CACurrentMediaTime()<restoredBy)pump(.01);
    // No window is discovered and no read answers from here on; a reopened canvas gets a new manager, which ends a pass of its own.
    [self.manager stop];self.manager=nil;self.adopted=NO;
    // Nor is a panel put back in front or rebuilt: the session watch ends with the canvas, and a reopened one makes its own.
    [self.session stop];self.session=nil;self.desktopUp=NO;self.sessionInactive=NO;
    // Inert from here until the canvas reopens: no config hot key, tap watch, key repeat, input-source observer, config watch, hot corner, pending event, pan launch or pointer report outlives this line.
    [self.hotKeys invalidate];self.hotKeys=nil;[self.tapKeys stop];self.tapKeys=nil;[self.configWatcher stop];self.configWatcher=nil;self.corners=nil;[self.statePush invalidate];self.statePush=nil;[self.panLaunch cancel];self.pointerOutputs=nil;self.pointerWanted=NO;
    // A trackpad gesture in progress ends cancelled while its output still exists; no touch or hold timer outlives this line either.
    [self cancelGestures];self.trackpad=nil;
    // Nor a tracking area or a pending hover: cleanup keeps handling events while it waits for streams.
    for(DesktopView *view in self.views)[view.hover stop];
    [self endFullscreens];
    [self.resize shutdown];[self stopNavigation];
    // Effects are answered within the watchdog's three seconds; shutdown still has a five-second bound.
    CFTimeInterval drained=CACurrentMediaTime()+5;
    while(self.resize.obligations&&CACurrentMediaTime()<drained){self.statusText=@"Quit pending: waiting for native resize result";[self render];pump(.01);}
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
    CFTimeInterval stopDeadline=CACurrentMediaTime()+2;
    while(self.pendingStops.count&&CACurrentMediaTime()<stopDeadline){self.statusText=@"Shutdown pending: waiting for capture streams";pump(.01);}
    if(self.pendingStops.count){self.captureStopsTimedOut=self.pendingStops.count;fprintf(stderr,"Infinify: %lu capture stops did not complete within 2 s; detached callbacks are ignored during process exit\n",(unsigned long)self.captureStopsTimedOut);[self.pendingStops removeAllObjects];}
    for(DesktopView *view in self.views)for(NSNumber *output in view.outputs){NSDictionary *reply=[self call:@{@"op":@"remove_output",@"output":output}];[self.resize consume:reply];}
    for(NSPanel *panel in self.panels){[panel orderOut:nil];[panel close];}[self.panels removeAllObjects];[self.views removeAllObjects];
    [self drainRetiredCaptureEdgeGuards:YES];
    // Every compositor layer, kept pixel buffer and background program goes with the panels.
    [self.compositor reset];self.compositor=nil;self.backgroundNote=nil;
    [self stopKeys];[self stopViewKeys];
    if(!self.sources.count)self.resize=nil;
    [self putBackWindowSettings];
}
- (void)dealloc { [self stopMacWallpapers];[_ipc stop];[_manager stop];[_session stop];[_onboarding close];[self stopNavigation];[self stopViewKeys];[_hotKeys invalidate];[_tapKeys stop];[_configWatcher stop];[_statePush invalidate];[_panLaunch cancel];[_trackpadTimer invalidate];[_multitouch stop];[_dockTap stop];[_sceneWriter drain];if(_controller)driftwm_desktop_destroy(_controller); }
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
            CGPoint anchor=projected(desktop,source.logical,first,CGPointMake(120,120));NSDictionary *hitBefore=asDict([desktop call:@{@"op":@"hit",@"output":first,@"screen":pointJSON(anchor)}][@"hit"]);
            [view zoom:.8 at:anchor output:first];NSDictionary *hitAfter=asDict([desktop call:@{@"op":@"hit",@"output":first,@"screen":pointJSON(anchor)}][@"hit"]);
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
    [desktop cleanup];pump(.2);report[@"panels_closed"]=@(desktop.panels.count==0);report[@"sources_detached"]=@(desktop.sources.count==0);report[@"streams_stopped"]=@(desktop.pendingStops.count==0&&!desktop.captureStopsTimedOut);
    BOOL restore=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==child.processIdentifier&&!previous.terminated&&[previous.launchDate isEqual:previousBirth];report[@"foreground_restore_attempted"]=@(restore);if(restore)[previous activateWithOptions:0];
    if(child.running)[child terminate];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];while(child.running&&deadline.timeIntervalSinceNow>0)usleep(10000);if(child.running)kill(child.processIdentifier,SIGKILL);[child waitUntilExit];
    report[@"source_reaped"]=@(!child.running);report[@"source_exit_status"]=@(child.terminationStatus);report[@"pointer_unchanged"]=@(CGPointEqualToPoint(initialPointer,pointer()));
    BOOL pass=enrolled;if(probe){for(NSString *key in @[@"invalid_scene_preserved",@"orphan_native_drag_rejected",@"chooser_selection_attached",@"world_drag_changed_only_world",@"separate_live_layers",@"world_fixed_during_camera_changes",@"pointer_anchor_stable",@"independent_second_camera",@"native_bounds_unchanged",@"reopen_unbound",@"detached_input_rejected",@"panels_closed",@"sources_detached",@"streams_stopped",@"source_reaped"])pass&=[report[key]boolValue];
        pass&=[report[@"controls"]count]==2;for(NSDictionary *attempt in report[@"controls"])pass&=[attempt[@"button"]boolValue]&&[attempt[@"text"]boolValue]&&[attempt[@"scroll"]boolValue]&&[attempt[@"native_key_focus"]boolValue];
        for(int view=0;view<2;view++){BOOL red=NO,blue=NO;for(NSDictionary *frame in report[@"frames"]){NSArray *views=frame[@"views"];if(views.count!=2)continue;red|=[views[view][@"red"]integerValue]>500;blue|=[views[view][@"blue"]integerValue]>500;pass&=[views[view][@"outside_clip"]integerValue]==0;}pass&=red&&blue;}
    }report[@"passed"]=@(pass);save(report,receipt);return pass?0:2;
}

// WIDTHxHEIGHT in points, digits only. The least is 960x480, as it was when the window carried a toolbar.
static BOOL parseWindowSize(const char *text,NSSize *size) {
    char *end=NULL;unsigned long width=strtoul(text,&end,10);if(*end!='x'||!isdigit((unsigned char)end[1]))return NO;
    unsigned long height=strtoul(end+1,&end,10);if(*end||width<960||width>16384||height<480||height>16384)return NO;
    *size=NSMakeSize(width,height);return YES;
}
// --only-pid: the start time of a process the run may be told to manage, as [seconds, microseconds]; nil for one that does
// not exist or is another user's. Read once, at launch: DWInScope compares against it for as long as the run lasts.
static NSArray<NSNumber *> *scopeBirth(pid_t pid) {
    struct proc_bsdinfo p={0};if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&p,sizeof(p))!=sizeof(p)||p.pbi_uid!=getuid())return nil;
    return @[@(p.pbi_start_tvsec),@(p.pbi_start_tvusec)];
}
// --native-helper NONCE_FILE: the helper's nonce, 64 hexadecimal characters and at most a newline after them, in a regular file that is
// this user's and nobody else's to read. It is read from there so that it is never on a command line, where every process could see it.
static NSString *helperNonce(const char *path,const char **why) {
    struct stat st;int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);char text[66]={0};
    if(fd<0||fstat(fd,&st)){if(fd>=0)close(fd);*why="names a nonce file that cannot be opened";return nil;}
    ssize_t n=S_ISREG(st.st_mode)&&st.st_uid==getuid()&&(st.st_mode&0777)==0600?read(fd,text,sizeof(text)):-2;close(fd);
    if(n==-2){*why="needs a nonce file that is a regular file of this user's with mode 0600";return nil;}
    if(n==65&&text[64]=='\n')n=64;
    if(n!=64||strspn(text,"0123456789abcdefABCDEF")!=64){*why="needs a nonce file holding 64 hexadecimal characters";return nil;}
    return [[NSString alloc]initWithBytes:text length:64 encoding:NSASCIIStringEncoding];
}
static int helperRefused(const char *why) { fprintf(stderr,"Infinify: native helper %s\n",why);return 64; }
static int scopeRefused(const char *why,const char *value) { if(value)fprintf(stderr,"Infinify: --only-pid %s %s\n",value,why);else fprintf(stderr,"Infinify: --only-pid %s\n",why);return 64; }
// The normal run's settings takeover, for an exit() that does not come back through main(): it puts them back there too (idempotent).
static DWSystemTakeover *takeoverAtExit;
static void putBackAtExit(void) { NSString *note=nil;[takeoverAtExit restore:&note];if(note.length)fprintf(stderr,"%s\n",note.UTF8String); }
int main(int argc,const char **argv) { @autoreleasepool {
    // The IPC client runs before any AppKit initialisation: no window, no privacy grant.
    if(argc>=2&&!strcmp(argv[1],"msg"))return driftwm_desktop_msg(argc-2,argv+2);
    // So does the login item: registered, unregistered or read, and nothing else of the app starts.
    if(argc>=2&&!strcmp(argv[1],"login-item"))return DWLoginItemCommand(argc-2,argv+2);
    // native-desktop starts the bundle's audited native bootstrap (an explicit terminal command, or the login item when the owner
    // enabled compositor mode) or manages that default. It replaces this process before AppKit, so the ordinary-instance guard
    // cannot mistake it for a running canvas. No checkout fallback.
    if(argc>=2&&!strcmp(argv[1],"native-desktop"))return DWNativeDesktopCommand(argc-2,argv+2);
    // The login item's program: compositor mode when the owner enabled it, else the capture-mode start it always was.
    if(argc==2&&!strcmp(argv[1],"login-start")){
        if(DWNativeLoginIsCompositor()){const char *login[]={"--login"};return DWNativeDesktopCommand(1,login);}
        argc=1;
    }
    raiseOpenFileLimit();
    const char **launched=argv; // as given, for the onboarding window's Relaunch
    BOOL windowed=NO,logical=NO,manual=NO;const char *socket=NULL,*config=NULL,*chord=NULL;NSSize windowSize=NSMakeSize(1200,800);const char *filtered[argc+1];int count=0;
    BOOL undelivered=NO; // --no-hover-forwarding
    BOOL scoped=NO,debugPointer=NO,nativeDesktop=NO;NSMutableDictionary<NSNumber *,NSArray<NSNumber *> *> *scope=[NSMutableDictionary dictionary]; // --only-pid, --debug-pointer
    NSMutableArray<NSMutableDictionary *> *helperEndpoints=[NSMutableArray array]; // --native-helper, at most four explicit sessions
    for(int i=0;i<argc;i++){
        if(i>0&&!strcmp(argv[i],"--no-native-focus")){if(logical)return 64;logical=YES;continue;}
        if(i>0&&!strcmp(argv[i],"--no-hover-forwarding")){if(undelivered)return 64;undelivered=YES;continue;}
        if(i>0&&!strcmp(argv[i],"--socket")){if(socket||i+1>=argc||argv[i+1][0]!='/')return 64;socket=argv[++i];continue;}
        if(i>0&&!strcmp(argv[i],"--config")){if(config||i+1>=argc||argv[i+1][0]!='/')return 64;config=argv[++i];continue;}
        // The chord's grammar is the controller's; one it rejects is reported in the status line.
        if(i>0&&!strcmp(argv[i],"--super")){if(chord||i+1>=argc||!argv[i+1][0])return 64;chord=argv[++i];continue;}
        if(i>0&&!strcmp(argv[i],"--manual")){if(manual)return 64;manual=YES;continue;}
        // Every process named is looked at here, before anything opens: a scope that names nothing real must not become no scope.
        if(i>0&&!strcmp(argv[i],"--only-pid")){if(i+1>=argc)return scopeRefused("needs a process id",NULL);scoped=YES;const char *list=argv[++i],*at=list;
            for(;;){char *end=NULL;errno=0;long pid=isdigit((unsigned char)*at)?strtol(at,&end,10):0;
                if(!end||end==at||(*end&&*end!=',')||errno||pid<=0||pid>INT_MAX)return scopeRefused("is not a list of process ids",list);
                if(pid==getpid())return scopeRefused("names Infinify itself",list);
                if(scope[@(pid)])return scopeRefused("names a process twice",list);
                NSArray<NSNumber *> *born=scopeBirth((pid_t)pid);if(!born)return scopeRefused("names a process that is not running, or not one of this user's",list);
                scope[@(pid)]=born;if(!*end)break;at=end+1;}
            continue;}
        if(i>0&&!strcmp(argv[i],"--debug-pointer")){if(debugPointer)return 64;debugPointer=YES;continue;}
        if(i>0&&(!strcmp(argv[i],"--native-helper")||!strcmp(argv[i],"--native-desktop-helper"))){
            BOOL desktopSelection=!strcmp(argv[i],"--native-desktop-helper");
            if(nativeDesktop||(desktopSelection&&helperEndpoints.count))return helperRefused("desktop mode needs exactly one endpoint and cannot be combined with --native-helper");
            nativeDesktop=desktopSelection;
            if(helperEndpoints.count>=4)return helperRefused("accepts at most four explicit helper endpoints");if(i+2>=argc)return helperRefused("needs RUNTIME_DIR and NONCE_FILE");
            const char *runtime=argv[++i],*file=argv[++i];if(runtime[0]!='/'||file[0]!='/')return helperRefused("needs two absolute paths, RUNTIME_DIR and NONCE_FILE");
            NSString *canonical=[@(runtime)stringByResolvingSymlinksInPath];for(NSDictionary *endpoint in helperEndpoints)if([canonical isEqual:[endpoint[@"runtime"]stringByResolvingSymlinksInPath]])return helperRefused("names a runtime directory twice");
            [helperEndpoints addObject:[@{@"runtime":@(runtime),@"nonce_file":@(file)} mutableCopy]];continue;}
        if(i>0&&!strcmp(argv[i],"--windowed")){if(windowed)return 64;windowed=YES;if(i+1<argc&&isdigit((unsigned char)argv[i+1][0])&&!parseWindowSize(argv[++i],&windowSize))return 64;continue;}
        filtered[count++]=argv[i];}filtered[count]=NULL;argc=count;argv=filtered;

    if(argc==2&&!strcmp(argv[1],"--help")){puts("Infinify.app — macOS 26+ Apple Silicon: DriftWM's canvas as the desktop of native Mac windows\nDefault: the desktop. One canvas panel per display covers the whole display on every Space, under the menu bar and the Dock, which both stay; there is no toolbar, no status line and no chooser. Every real application window on screen (by Accessibility a standard window or a dialog, never a popup or a helper window; without Accessibility every window but an untitled one under 200x150) lives on the canvas: existing windows are adopted, a new one is placed by window_placement, a closed one leaves (or leaves a stand-in under session.suspend_on_close). This needs Screen Recording and Accessibility access: while one is missing a small window says so and offers the Allow buttons, Relaunch (Screen Recording reaches only a newly started app) and Quit, and the canvas opens once nothing is in the way. While the canvas is open the run switches off Stage Manager (it keeps every window outside the current stage as a thumbnail) and macOS window tiling (edge drag, top edge, option accelerator) in com.apple.WindowManager, with one line on stderr, and puts the user's own settings back when it ends (quit, SIGTERM, SIGINT, SIGHUP, log out); a run that was killed has them put back at the next launch from ~/Library/Application Support/Infinify/window-prefs-snapshot.plist. --windowed, --manual, --only-pid and the demos leave the settings alone.\nStatus notes go to stderr, one line each; what a config file has wrong is drawn in the error bar.\n--only-pid PID[,PID…] (may repeat): manage only the windows of these processes, each of which must be running and this user's; needs --windowed, and refuses --manual. It works without Screen Recording access too: the windows are then bound, focused and clicked as ever and their tiles have no picture.\n--debug-pointer: with --only-pid, serve the DebugPointer IPC request, by which a test presses and releases on a window without the pointer.\n--native-helper RUNTIME_DIR NONCE_FILE: with --only-pid, native presentation: the window server draws the managed windows themselves where the canvas places them, moved and scaled by the transform helper whose socket is in RUNTIME_DIR (its nonce is read from NONCE_FILE, mode 0600), and the canvas, behind them, draws live copies for additional independently zoomed display views when Screen Recording access is already available. Popup/sheet copies, metadata cropping and scoped member input are implemented but unverified; native display-boundary clipping remains incomplete. A cooperative helper inside its named process, or an authenticated exact helper allowlist of the named process instances, must match --only-pid. Repeat this pair for up to four explicit helpers: each must audit its own disjoint process subset, and their union must exactly match --only-pid. Same-user helpers and allowlists that cannot be audited are refused; nothing is looked for or loaded. Losing one grouped helper ends presentation and restores its siblings. Without a native helper flag every run is the overlay.\n--native-desktop-helper RUNTIME_DIR NONCE_FILE: explicit whole-desktop native presentation for this login user, including newly opened applications. Requires one authenticated Apple Dock-hosted SAME_USER helper with scope audit and per-window restoration; cannot combine with --only-pid, --windowed, --manual or fixture modes. This only connects to a helper you already started; nothing is injected or installed by the app. Requires Accessibility access and Stage Manager off. Screen Recording is optional for the native primary and enables captured replicas on additional independent display views. Native clipping and application compatibility still need validation.\n--manual: show the chooser first and capture only explicitly selected windows; no window is adopted automatically. Open canvas shows the saved world without adding one. The chooser stays open above the canvas; closed there, it is gone for the run.\n--demo EMPTY_DIRECTORY: disposable interactive fixture, bounded to 60 seconds\n--demo-probe EMPTY_DIRECTORY: automated own-fixture E2E, no permission prompts\n--demo-probe-guard EMPTY_DIRECTORY: own-fixture interruption regression (expected exit 2)\n--no-native-focus: window focus stays logical; no native window is activated or raised\n--no-hover-forwarding: pointer motion over a window is not delivered to its application; focus_follows_mouse and pick mode still follow the pointer\n--state ABSOLUTE_PATH: explicit persistent scene file (default Application Support/Infinify/scene.json)\n--socket ABSOLUTE_PATH: IPC socket of a normal run (default Application Support/Infinify/infinify.sock)\n--windowed [WIDTHxHEIGHT]: open the canvas at launch in one ordinary window instead, all of it canvas (default 1200x800, at least 960x480), with no global shortcuts and whatever access there is; with --manual the chooser comes up above it; msg action quit or Control-C in its terminal ends it\n--config ABSOLUTE_PATH: DriftWM config file of a normal run (default $XDG_CONFIG_HOME/infinify/config.toml, else ~/.config/infinify/config.toml; DriftWM's built-in defaults when it is missing); read again whenever it changes\n--super CHORD: the physical keys of DriftWM's super/mod, a +-joined subset of ctrl|alt|cmd (default ctrl+alt; --super cmd restores Command bindings)\nmsg [--json] [--socket PATH] COMMAND ...: DriftWM-style IPC client for the running app; opens no window\nnative-desktop [--check | --help | enable | disable | status]: run the bundled native desktop launcher from a terminal; enable makes compositor mode the login default (launch daemon approved once in Login Items, reload after Dock restarts), disable reverts it, status reports it. --check only verifies the package and reports policy; the explicit start authenticates or loads the helper through its sudo step, then starts native mode. It changes no SIP or settings and refuses an uncertain earlier load.\nlogin-item on | off | status: register, unregister or report the login item, a LaunchAgent inside the bundle that starts Infinify at login and again after a crash, never after a quit. on starts it at once, off ends the instance it started, status only reads; opens no window. For the installed copy: scripts/install-app.sh puts a signed bundle in ~/Applications\n--source DIR SECONDS NONCE: internal disposable child only\nKeys and pointer gestures are DriftWM's bindings from the config file: ctrl is Control, alt is Option, super (mod) is the --super chord. With no config file the canvas uses Control-Option, leaving native Command editing and Command-Tab with macOS. Explicit --super cmd and config bindings keep their authored choices. The registered defaults are:\n  Drag or two-finger scroll on empty canvas, Control-Option-drag anywhere, three-finger swipe: pan; a released pan coasts (navigation.drift). Hold Super (Control-Option by default) and scroll with a wheel or two fingers to zoom anywhere. Wheel or two-finger pinch on empty canvas, Control-Option-pinch anywhere, three-finger pinch: anchored zoom (max 1x).\n  Option-drag on a window: world move/snap; add Shift: cluster. Held at the view's edge, a move pans the canvas under the window (navigation.edge_pan).\n  Trackpad gestures use DriftWM's [gestures] bindings with Mac defaults: four-finger swipe up toggles overview; other directions select the nearest window. Four-finger hold: center the focused window. Four-finger pinch in / out: zoom-to-fit / home toggle. Three-finger swipe or drag pans over windows as well as empty canvas. Two-finger pinch zooms over windows too.\n  Desktop mode intercepts recognized trackpad and Dock swipe streams for canvas navigation; stopping releases interception without changing System Settings. Unknown system gesture formats pass through; hardware behavior needs runtime validation. Where MultitouchSupport reports the trackpad, three or more fingers are read from it wherever the pointer is, and the system's Dock-control gestures are held back only for finger counts a [gestures] binding takes, with a short tail (INFINIFY_NO_MULTITOUCH=1 leaves the views' own touches in charge; not yet run on a physical trackpad). Windowed mode keeps local gestures only.\n  View actions animate one view's camera only (global shortcuts while the canvas is open, or msg action; held zoom, pan and nudge keys repeat):\n  Control-Option-A: home toggle (origin at 1:1, again to return). Control-Option-Tab or F3: overview toggle (again returns). Control-Option-W: the same zoom-to-fit toggle. Control-Option-Shift-W: the same over the focused window's snap cluster.\n  Control-Option-Equals / Control-Option-Minus: zoom in / out. Control-Option-0 or Control-Option-Z: zoom 1:1.\n  Control-Option-Command-arrows: pan the view under the pointer. Control-Option-Shift-arrows: nudge the focused window.\n  Control-Option-1 to 4: fly to bookmark 1 to 4. Control-Option-Shift-1 to 4: set it.\n  Window navigation flies the camera and focuses the window, natively when Infinify has Accessibility access:\n  Option-Tab / Option-Shift-Tab: cycle windows, most recently focused first; letting go of Option commits the choice.\n  Control-Option-arrows: the nearest window in that direction. Control-Option-C: center the focused window. Control-Option-X: center the window under the pointer.\n  A click on a window gives it canvas focus and starts its native focus, then the click is forwarded; a click on empty canvas unfocuses. Focusing a canvas window in its own application is followed.\n  Pointer motion over a window is delivered to its application; with focus_follows_mouse = true it also focuses that window without raising it, a screen-pinned one before the canvas beneath it and never a widget.\n  Below [zoom] interact_min (off by default) a window on the canvas is one target: a click flies to it, a drag moves it, and no click, scroll or motion reaches its application. A screen-pinned window and a widget are not picked and keep their pointer.\n  Control-Option-Command-drag: center-nearest by pointer, DriftWM's swipe; the direction is taken 16 points from the press.\n  Control-Option-Return: exec-terminal ($TERMINAL, else a new Terminal window). Control-Option-D: exec-launcher ($LAUNCHER, else Apps).\n  Control-Option-Shift-Command-arrows: send-to-output, the focused window to the display on that side (a world move; nothing with one display).\n  The default Control-Option-L lock binding and default volume, brightness, media and screenshot program bindings are left to macOS; their Linux commands are never substituted or started.\n  macOS's Lock Screen and screenshot shortcuts stay available. Explicit config bindings still run exactly as authored.\n  Control-Option-Q: close-window. The focused window's own close button is pressed through Accessibility; a focused placeholder is dismissed.\nThe fixture modes (--demo*) read no config and keep Option-drag pan, Command-wheel and pinch zoom and Control-Option-drag move; they take no trackpad touches. They keep their toolbar strip, status line and chooser, and their Resize status button explains unavailable native layout resizing.\nAn unbound click, drag or scroll on a window (left, right or middle button) is forwarded only to its selected, freshly validated source.\nNative keyboard/IME remain with the real app. Control-Option-Escape (until a binding takes that chord), Control-Option-Command-Shift-Q (quit), msg action quit or SIGTERM ends the run with exit status 0 and returns the native desktop: fullscreens ended, scene saved, panels closed, capture stopped, hot keys released.\nNo SIP/settings changes.");return 0;}
    BOOL child=argc==5&&!strcmp(argv[1],"--source"),demo=argc==3&&!strcmp(argv[1],"--demo"),guard=argc==3&&!strcmp(argv[1],"--demo-probe-guard"),probe=argc==3&&!strcmp(argv[1],"--demo-probe"),state=argc==3&&!strcmp(argv[1],"--state");
    if(argc!=1&&!child&&!demo&&!probe&&!guard&&!state)return 64;
    if((windowed||socket||config||chord||logical||manual)&&(child||demo||probe||guard))return 64;
    if(undelivered&&(child||demo||probe||guard))return 64;
    // A scope is for a windowed run that manages by itself. Without --windowed a launch without Screen Recording access would go to
    // the onboarding window; --manual's chooser attaches whatever is picked.
    if(scoped&&(child||demo||probe||guard))return 64;
    if(scoped&&!windowed)return scopeRefused("needs --windowed",NULL);
    // A scoped run settles adoption with only its own windows present: on the default scene that would drop every saved slot of a real window.
    if(scoped&&!state)return scopeRefused("needs --state",NULL);
    if(scoped&&manual)return scopeRefused("cannot be combined with --manual",NULL);
    if(debugPointer&&!scoped){fputs("Infinify: --debug-pointer needs --only-pid\n",stderr);return 64;}
    // Native authority is explicit: exact --only-pid instances, or the login
    // user's desktop through a separately audited Dock helper. Missing scope
    // never silently expands a scoped launch into desktop authority.
    if(helperEndpoints.count&&(child||demo||probe||guard))return helperRefused("cannot be combined with a fixture mode");
    if(nativeDesktop&&(scoped||windowed||manual))return helperRefused("--native-desktop-helper cannot be combined with --only-pid, --windowed or --manual");
    if(helperEndpoints.count&&!scoped&&!nativeDesktop)return helperRefused("needs --only-pid; use --native-desktop-helper explicitly for the desktop");
    for(NSMutableDictionary *endpoint in helperEndpoints){struct stat st;const char *why=NULL;
        if(stat([endpoint[@"runtime"]fileSystemRepresentation],&st)||!S_ISDIR(st.st_mode))return helperRefused("names a runtime directory that is not a directory");
        NSString *nonce=helperNonce([endpoint[@"nonce_file"]fileSystemRepresentation],&why);if(!nonce)return helperRefused(why);
        endpoint[@"nonce"]=nonce;[endpoint removeObjectForKey:@"nonce_file"];}
    // Before AppKit, helper admission, scene/config load or autostart. Keep both
    // leases through final native cleanup and scene save; CLOEXEC releases them
    // only when a requested relaunch replaces this fully cleaned process.
    __attribute__((objc_precise_lifetime)) DWRunOwnership *ownership=nil;
    if(!child&&!demo&&!probe&&!guard){
        NSString *dir=[NSHomeDirectory()stringByAppendingPathComponent:@"Library/Application Support/Infinify"];
        if(state&&![@(argv[2])isAbsolutePath])return 64;
        if(!state||!socket){NSError *error=nil;if(![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]){fprintf(stderr,"Infinify: cannot create support directory: %s\n",error.localizedDescription.UTF8String);return 73;}}
        BOOL duplicate=NO;NSString *error=nil;
        ownership=[DWRunOwnership acquireSocket:socket?@(socket):[dir stringByAppendingPathComponent:@"infinify.sock"] state:state?@(argv[2]):[dir stringByAppendingPathComponent:@"scene.json"] duplicate:&duplicate error:&error];
        if(!ownership){fprintf(stderr,"Infinify: %s\n",error.UTF8String);return duplicate?0:73;}
    }
    signal(SIGTERM,stopSignal);signal(SIGINT,stopSignal);signal(SIGHUP,stopSignal);
    [ProbeApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
    if(child){char *end=NULL;double seconds=strtod(argv[3],&end);if(!end||*end||!isfinite(seconds)||seconds<1||seconds>65)return 64;return source(@(argv[2]),seconds,@(argv[4]));}
    Desktop *desktop=[Desktop new];desktop.logicalFocus=logical;desktop.demo=demo||probe||guard;desktop.probe=probe||guard;desktop.interruptProbe=guard;desktop.windowed=windowed;desktop.windowSize=windowSize;
    desktop.hoverUndelivered=undelivered;desktop.scope=scoped?[scope copy]:nil;desktop.debugPointer=debugPointer;desktop.nativeDesktopMode=nativeDesktop;
    // Do not continue after a socket setup failure. No helper or scene has been
    // admitted yet, so refusal must not run cleanup/save on another run's scene.
    if(ownership&&![desktop startIPC:ownership.socketPath])return 73;
    // The helper is asked for its session now: one that is not there, refuses, or is not this run's to drive ends the launch here,
    // with nothing opened (EX_UNAVAILABLE). From here on native focus and sizing read a window's own frame, as the presenter does:
    // their checks compare it with what Accessibility reports, which the window list's transformed bounds would never match.
    if(helperEndpoints.count){NSString *why=nil;NSDictionary *endpoint=helperEndpoints.firstObject;
        desktop.native=nativeDesktop?[DWNativePresenter desktopPresenterAt:endpoint[@"runtime"] nonce:endpoint[@"nonce"] why:&why]
            :[DWNativePresenter presentersAt:helperEndpoints scope:desktop.scope why:&why];
        if(!desktop.native){fprintf(stderr,"Infinify: native helper %s\n",why.UTF8String);[desktop.ipc stop];return 69;}
        NSMutableArray *savedEndpoints=[NSMutableArray array];for(NSDictionary *endpoint in helperEndpoints)[savedEndpoints addObject:@{@"runtime":endpoint[@"runtime"],@"nonce":endpoint[@"nonce"]}];desktop.nativeEndpoints=savedEndpoints.copy;
        dw_focus_set_bounds(DWNativeBounds);dw_resize_set_bounds(DWNativeBounds);
        // Compositor mode with the launch daemon on (the launcher says so by environment): the Dock is watched, and the payload that
        // went with a Dock that restarted is loaded into the new one by the launcher's --reload, whose helper then replaces the lost
        // endpoint and the ordinary authenticated re-admission puts the windows back (dock-reload.h).
        const char *reload=getenv("INFINIFY_DOCK_RELOAD"),*payloadSHA=getenv("INFINIFY_NATIVE_PAYLOAD_SHA256"),*loadedAt=getenv("INFINIFY_NATIVE_LOADED_AT");
        NSString *launcher=[NSBundle.mainBundle pathForResource:@"launch" ofType:@"sh" inDirectory:@"NativeDesktop"];
        if(nativeDesktop&&reload&&!strcmp(reload,"1")&&payloadSHA&&strlen(payloadSHA)==64&&launcher){
            DWDockReloader *reloader=[[DWDockReloader alloc]initWithLauncher:launcher payloadSHA256:@(payloadSHA) stateDirectory:DWDockReloadStateDirectory() loadedAt:loadedAt?atof(loadedAt):0];
            __weak Desktop *weak=desktop;
            reloader.onNote=^(NSString *note){[weak say:note];};
            reloader.onEndpoint=^(NSString *runtime,NSString *nonceFile){Desktop *d=weak;if(!d)return;
                const char *failure=NULL;NSString *nonce=helperNonce(nonceFile.fileSystemRepresentation,&failure);
                if(!nonce){[d say:[NSString stringWithFormat:@"The reloaded helper's nonce is unusable: %s",failure]];return;}
                d.nativeEndpoints=@[@{@"runtime":runtime,@"nonce":nonce}];d.nativeResumeFailures=0;d.nativeResumeAfter=0;[d say:@"Dock payload reloaded; reconnecting"];};
            reloader.onPaused=^{Desktop *d=weak;[d say:@"Compositor mode stops here. The Dock that restarted left the windows drawn at the screen's top-left corner (it reset their transforms); Infinify native-desktop, run by hand, restores them from its journal and tries again"];[d quit:nil];};
            desktop.dockReloader=reloader;[reloader watch:YES];
        }}
    if(demo||probe||guard){NSString *dir=@(argv[2]);BOOL isDir=NO;if(![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir]||!isDir||[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil].count)return 64;desktop.statePath=[dir stringByAppendingPathComponent:@"scene.json"];return runDemo(desktop,dir,probe||guard);}
    desktop.statePath=ownership.statePath;
    // A normal run is the desktop and switches Stage Manager and window tiling off for as long as its canvas is open (-openCanvas:);
    // windowed, --manual and scoped runs and the demos leave the user's settings alone. Whatever an earlier run that did not end
    // left changed is put back now, after the single-instance lease above (a second launch never touches a running one's settings)
    // and whether or not this launch gets as far as a canvas. Every end after this one puts them back: the quit action, the exit chord,
    // SIGTERM, SIGINT, SIGHUP and a logout reach -cleanup; exit() from anywhere else reaches the atexit handler. Only a kill that
    // cannot be caught leaves them to the next launch.
    if(!windowed&&!manual&&!scoped){desktop.takeover=[DWSystemTakeover system];takeoverAtExit=desktop.takeover;atexit(putBackAtExit);
        NSString *note=nil;[desktop.takeover restore:&note];if(note.length)fprintf(stderr,"%s\n",note.UTF8String);}
    // Before the config: its binding table counts DriftWM's sizing actions and toggle-fullscreen among those that run here.
    [desktop resizeCapability];
    // Before the scene: the config decides what a load restores.
    desktop.configured=YES;desktop.configPath=config?@(config):nil;desktop.superChord=chord?@(chord):nil;[desktop loadConfig:YES];
    [desktop loadScene:desktop.statePath];
    [[NSNotificationCenter defaultCenter]addObserver:desktop selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    // A quit that AppKit is asked for (log out, restart, shut down) ends like every other: -applicationShouldTerminate:.
    NSApp.delegate=desktop;
    // A desktop launch adopts existing toplevels when its required access is ready.
    // Capture overlays require Screen Recording and Accessibility; authenticated
    // native primary windows require Accessibility, with recording optional for
    // additional captured views. Onboarding waits for these prerequisites or
    // reports a failed scene load; Stage Manager is no prerequisite, a normal run
    // switches it off when the canvas opens (-takeOverWindowSettings). A windowed
    // run still opens immediately, and --manual keeps its chooser above it.
    desktop.managing=!manual;
    if(!desktop.startupError&&(windowed||(desktop.managing&&DWDesktopAccessReady(desktop.native==nil,CGPreflightScreenCaptureAccess(),AXIsProcessTrusted())))){[desktop openCanvas:nil];if(manual)[desktop showChooser:nil];}
    else if(manual)[desktop showChooser:nil];
    else [desktop onboard];
    // Upstream runs autostart on every backend, its nested one included: a managed, a windowed and a chooser-first launch all do.
    // A launch held at the onboarding window runs it when its canvas opens (-onboard).
    if(!desktop.onboarding)[desktop runAutostart];
    // A pool per turn: what a poll, its controller calls and the events it pumps autorelease ends with the turn.
    while(!stopped){@autoreleasepool{[desktop poll];DWDesktopPump(.08);}}
    // Stopped first: the pending quit reply is written, and no request can arrive during cleanup.
    [desktop.ipc stop];desktop.ipc=nil;[desktop cleanup];[desktop.chooser close];[desktop.onboarding close];[desktop putBackWindowSettings];
    // Relaunch: the same executable with the same arguments in this very process, once everything above has ended and the socket is free again.
    // The process keeps its place: under launchd it is still the login item's job, in a terminal still that terminal's. Not after a signal, which
    // asked for an end. The lines after execv are reached only if it failed.
    if(desktop.relaunch&&stopped==1){execv(NSBundle.mainBundle.executablePath.fileSystemRepresentation,(char *const *)launched);perror("Infinify: relaunch");return 1;}
    // The quit action, msg action quit, the exit chord and SIGTERM all end here, with status 0: launchd starts the login item again only after an end that is not this one.
    return 0;
} }
