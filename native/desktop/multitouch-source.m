// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Sunlight, repository https://github.com/spacefarm-digital/sunlight, commit afeea74b18e70ca49bf462d6fe462cf65deb2b32
// (MIT, Copyright (c) 2026 spacefarm; notice in SUNLIGHT-NOTICE.txt), upstream path Sources/Canvas/TrackpadPan.swift;
// the line numbers below are those of that file at that commit. Translated function by function, with Sunlight's names where they fit:
//   TrackpadPan.shared, 65-66 ...................... activeSource: the framework's callback is a C function with no context pointer
//   TrackpadPan.start (wake observer), 97-102 ...... -[DWMultitouchSource start]: on NSWorkspaceDidWakeNotification, restartDevices a second later
//   TrackpadPan.startDevices, 118-138 .............. -[DWMultitouchSource startDevices] (was attach): the list of devices, each one's surface size in hundredths
//                                                    of a millimetre, a callback registered and the device started with 0
//   TrackpadPan.restartDevices, 140-151 ............ -[DWMultitouchSource restartDevices]: every device unregistered and stopped, the list let go, the
//                                                    gesture in progress ended, and startDevices again (stopDevices is the first half)
//   TrackpadPan.devices, 153-158 ................... the walk over the device list in startDevices and stopDevices
//   TrackpadPan.contactFrame, 160-165 .............. contactFrame
//   TrackpadPan.frame(device:contacts:count:), 168-192: -[DWMultitouchSource intake:count:device:surface:at:] and surfaceContacts(): a record is a finger
//                                                    when its state is on the surface, one finger per path, the point is x and y of the record, the time is
//                                                    taken when the callback runs. Sunlight's centroid and spread go to its recogniser; here the frame goes
//                                                    to DWMultitouchFeed and DWTrackpadGestures (trackpad-gestures.m, whose thumb and fingers rule has its own
//                                                    citation), and the finger count to the Dock guard (dock-guard.m, which has the drop timing).
//   Contact, 384-394 ............................... DWContactSize, DWContactPath, DWContactState, DWContactX, DWContactY and DWContactMake/Touching
//                                                    (multitouch-source.h): size 96, path 16, state 20, x 32, y 36, on the surface 3 to 4
//   MultitouchSupport, 396-429 ..................... loadMultitouch() and `mt`: dlopen of the framework's path, the symbols MTDeviceCreateList,
//                                                    MTRegisterContactFrameCallback, MTUnregisterContactFrameCallback, MTDeviceStart, MTDeviceStop and
//                                                    MTDeviceGetSensorSurfaceDimensions looked up with dlsym; the surface size is optional there and required here
// Deviations: the source follows one device at a time (the first with a finger on it, until it has none: two pads never make one gesture; Sunlight keeps
// a recogniser per device and ignores a second device only while the first has `device` set), a device that cannot give a surface size in millimetres is
// not registered (Sunlight falls back to a 0.62 height over width), frames reach the main thread in order through a queue and carry a generation so that a
// stale one is dropped, and the source `delivers` only once a frame with a finger has arrived. The offsets, the units and the claim that a frame arrives
// when a finger lifts are Sunlight's and nothing in this tree has checked them against hardware: the regression builds records with the same constants
// and proves only that the code reads what it was told to read.
// Under INFINIFY_DEBUG the source also says what it sees: the framework's own calls (they are counted before anything is
// decoded, so a framework that calls back with no finger the source accepts is told from one that never calls), the states
// of the records it receives, when it starts and stops delivering, and per touch the frames, their rate and the peak count.
#import "multitouch-source.h"
#import "trackpad-gestures.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <stdatomic.h>

@implementation DWMultitouchFrame
+ (instancetype)frameWithContacts:(NSArray<NSDictionary *> *)contacts surface:(CGSize)surface time:(NSTimeInterval)time contact:(uint32_t)contact generation:(NSUInteger)generation {
    DWMultitouchFrame *frame=[self new];frame->_contacts=[contacts copy];frame->_surface=surface;frame->_time=time;frame->_contact=contact;frame->_generation=generation;return frame;
}
@end

typedef int (*DWMTFrameCallback)(void *device,const void *contacts,int32_t count,double timestamp,int32_t frame);
static struct {
    CFArrayRef (*list)(void);
    void (*add)(void *,DWMTFrameCallback);void (*remove)(void *,DWMTFrameCallback);
    int (*start)(void *,int);int (*stop)(void *);
    int (*size)(void *,int32_t *,int32_t *);
} mt;
// TrackpadPan's MultitouchSupport.init?, 396-429. Why the framework is not there, or nil. Looked up once.
static NSString *loadMultitouch(void) {
    static NSString *why;static dispatch_once_t once;
    dispatch_once(&once,^{
        void *lib=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_NOW);
        if(!lib){why=@"MultitouchSupport cannot be loaded";return;}
        *(void **)&mt.list=dlsym(lib,"MTDeviceCreateList");*(void **)&mt.add=dlsym(lib,"MTRegisterContactFrameCallback");
        *(void **)&mt.remove=dlsym(lib,"MTUnregisterContactFrameCallback");*(void **)&mt.start=dlsym(lib,"MTDeviceStart");
        *(void **)&mt.stop=dlsym(lib,"MTDeviceStop");*(void **)&mt.size=dlsym(lib,"MTDeviceGetSensorSurfaceDimensions");
        if(!mt.list||!mt.add||!mt.remove||!mt.start||!mt.stop||!mt.size)why=@"MultitouchSupport lacks a function this source needs";
    });
    return why;
}
// One line on stderr per reason, once per process: the shell asks again when it configures its input.
static void note(NSString *line) {
    static NSMutableSet *said;static dispatch_once_t once;dispatch_once(&once,^{said=[NSMutableSet set];});
    @synchronized(said){if([said containsObject:line])return;[said addObject:line];}
    fprintf(stderr,"%s\n",line.UTF8String);
}

// The contacts on the surface, minus what `resting` calls resting. A frame lists fingers that have lifted for a moment
// longer (states 5 to 7) and ones that hover (2): neither is a finger. A path seen twice counts once.
// The contact loop of TrackpadPan.frame, 171-179.
static NSArray<NSDictionary *> *surfaceContacts(const void *records,int32_t count,BOOL (^resting)(NSDictionary *)) {
    NSMutableArray *fingers=[NSMutableArray array];NSMutableSet *paths=[NSMutableSet set];
    for(int32_t i=0;records&&i<MIN(MAX(count,0),64);i++){
        const uint8_t *record=(const uint8_t *)records+(size_t)i*DWContactSize;int32_t path,state;float x,y;
        memcpy(&path,record+DWContactPath,4);memcpy(&state,record+DWContactState,4);memcpy(&x,record+DWContactX,4);memcpy(&y,record+DWContactY,4);
        if(state<DWContactMake||state>DWContactTouching||!isfinite(x)||!isfinite(y)||[paths containsObject:@(path)])continue;
        NSDictionary *contact=@{@"path":@(path),@"x":@(x),@"y":@(y),@"state":@(state)};
        if(resting&&resting(contact))continue;
        [paths addObject:@(path)];[fingers addObject:contact];
    }
    return fingers;
}

// A followed device that sends nothing for this long loses the claim to another one that does.
static const NSTimeInterval DWFollowTimeout=30;
static __weak DWMultitouchSource *activeSource;
@interface DWMultitouchSource ()
@property (atomic,copy) NSDictionary<NSNumber *,NSValue *> *surfaces; // device -> its surface in mm, replaced only while no callback is registered
@end
// TrackpadPan.contactFrame, 160-165.
static int contactFrame(void *device,const void *contacts,int32_t count,double timestamp,int32_t number) {
    (void)timestamp;(void)number;
    @autoreleasepool{
        NSTimeInterval now=CACurrentMediaTime();DWMultitouchSource *source=activeSource;
        NSValue *size=source.surfaces[@((uintptr_t)device)];if(!size)return 0;
        DWMultitouchFrame *frame=[source intake:contacts count:count device:(uintptr_t)device surface:size.sizeValue at:now];
        if(frame)dispatch_async(dispatch_get_main_queue(),^{[source deliver:frame];});
    }
    return 0;
}

@implementation DWMultitouchSource {
    DWDockGuard *_guard;void (^_frames)(DWMultitouchFrame *);
    CFArrayRef _devices;NSMutableArray<NSValue *> *_registered;
    os_unfair_lock _lock;uintptr_t _followed;NSTimeInterval _followedAt; // the device whose contacts are being passed on, 0 for none, and when it last had a finger down
    _Atomic NSUInteger _generation;
    BOOL _running,_delivering;id _wake;
    // Diagnostics. The first three are written on the framework's thread, the rest on the main thread.
    _Atomic NSUInteger _callbacks,_records,_noFinger;_Atomic NSTimeInterval _noFingerAt;_Atomic NSUInteger _states[16];
    NSUInteger _delivered,_touchFrames,_statFrames,_peak;BOOL _touching;NSTimeInterval _touchAt,_statAt;
}
- (instancetype)initWithGuard:(DWDockGuard *)guard frames:(void (^)(DWMultitouchFrame *))frames {
    if((self=[super init])){_guard=guard;_frames=[frames copy];_lock=OS_UNFAIR_LOCK_INIT;}return self;
}
- (BOOL)running { return _running; }
- (BOOL)delivering { return _delivering; }
// TrackpadPan.frame(device:contacts:count:), 168-192, on the framework's thread.
- (DWMultitouchFrame *)intake:(const void *)records count:(int32_t)count device:(uintptr_t)device surface:(CGSize)surface at:(NSTimeInterval)now {
    NSArray *fingers=surfaceContacts(records,count,self.resting);BOOL skip=NO,ended=NO;
    atomic_fetch_add(&_callbacks,1);
    if(DWDebugTrace()&&records){
        // Which states the framework's records carry, so that a firmware whose numbering differs from Sunlight's (touching is 4) shows up as records and no fingers.
        int32_t n=MIN(MAX(count,0),64);atomic_fetch_add(&_records,(NSUInteger)n);
        for(int32_t i=0;i<n;i++){int32_t state;memcpy(&state,(const uint8_t *)records+(size_t)i*DWContactSize+DWContactState,4);atomic_fetch_add(&_states[state>=0&&state<15?state:15],1);}
        if(n&&!fingers.count&&now-atomic_load(&_noFingerAt)>=2){
            atomic_store(&_noFingerAt,now);atomic_fetch_add(&_noFinger,1);
            fprintf(stderr,"debug: multitouch: callback #%lu with %d record(s) and none on the surface (hovering, lifting or an unknown state); records seen by state %s\n",(unsigned long)atomic_load(&_callbacks),(int)n,[self stateHistogram].UTF8String);
        }
    }
    os_unfair_lock_lock(&_lock);
    // The first device with a finger on it is followed until that has none: two pads never make one fictitious gesture. A
    // device that goes quiet for the length of a held breath (it was unplugged, or its radio dropped) is not followed for ever.
    if(_followed&&_followed!=device&&now-_followedAt>DWFollowTimeout)_followed=0;
    if(_followed&&_followed!=device)skip=YES;
    else if(fingers.count){_followed=device;_followedAt=now;}
    else {ended=_followed==device;_followed=0;}
    os_unfair_lock_unlock(&_lock);
    // An empty frame is news only as the lift of the last finger.
    if(skip||(!fingers.count&&!ended))return nil;
    // Before the main thread has seen the frame: the system's own gesture needs no wait for it.
    uint32_t contact=[_guard fingers:fingers.count at:now];
    return [DWMultitouchFrame frameWithContacts:fingers surface:surface time:now contact:contact generation:atomic_load(&_generation)];
}
- (NSString *)stateHistogram {
    NSMutableArray *parts=[NSMutableArray array];
    for(int i=0;i<16;i++){NSUInteger n=atomic_load(&_states[i]);if(n)[parts addObject:[NSString stringWithFormat:@"%@:%lu",i==15?@"other":@(i).stringValue,(unsigned long)n]];}
    return parts.count?[NSString stringWithFormat:@"{%@}",[parts componentsJoinedByString:@" "]]:@"{}";
}
// Main thread: the delivered frames of a touch, summed up. One line when the touch begins, one a second while it lasts, one when it ends.
- (void)trace:(DWMultitouchFrame *)frame {
    NSUInteger fingers=frame.contacts.count;_delivered++;
    if(fingers&&!_touching){
        _touching=YES;_touchAt=_statAt=frame.time;_touchFrames=_statFrames=0;_peak=0;
        fprintf(stderr,"debug: multitouch: touch begins with %lu finger(s); the framework has called back %lu times, %lu frames delivered, records by state %s\n",(unsigned long)fingers,(unsigned long)atomic_load(&_callbacks),(unsigned long)_delivered,[self stateHistogram].UTF8String);
    }
    if(!_touching)return;
    _touchFrames++;_statFrames++;_peak=MAX(_peak,fingers);
    if(frame.time-_statAt>=1){fprintf(stderr,"debug: multitouch: %lu frame(s) in %.2f s (%.0f/s), %lu finger(s) now, peak %lu\n",(unsigned long)_statFrames,frame.time-_statAt,_statFrames/(frame.time-_statAt),(unsigned long)fingers,(unsigned long)_peak);_statAt=frame.time;_statFrames=0;}
    if(!fingers){fprintf(stderr,"debug: multitouch: touch ends after %.2f s, %lu frame(s), peak %lu finger(s)\n",frame.time-_touchAt,(unsigned long)_touchFrames,(unsigned long)_peak);_touching=NO;}
}
- (void)deliver:(DWMultitouchFrame *)frame {
    if(frame.generation!=atomic_load(&_generation))return;
    if(!_delivering&&frame.contacts.count){
        _delivering=YES;[_guard setLive:YES];
        if(DWDebugTrace())fprintf(stderr,"debug: multitouch: delivering, from a frame of %lu finger(s) (%lu framework callbacks so far); the views' own touches no longer feed the recogniser\n",(unsigned long)frame.contacts.count,(unsigned long)atomic_load(&_callbacks));
        if(_deliveringChanged)_deliveringChanged(YES);
    }
    if(DWDebugTrace())[self trace:frame];
    if(_frames)_frames(frame);
}
// TrackpadPan.startDevices, 118-138.
- (BOOL)startDevices {
    NSString *missing=loadMultitouch();if(missing){note([missing stringByAppendingString:@": trackpad gestures use the views' own touches."]);return NO;}
    CFArrayRef list=mt.list();
    if(!list||!CFArrayGetCount(list)){if(list)CFRelease(list);note(@"MultitouchSupport lists no trackpad: trackpad gestures use the views' own touches.");return NO;}
    NSMutableDictionary *surfaces=[NSMutableDictionary dictionary];NSMutableArray *registered=[NSMutableArray array];NSMutableArray *sizes=[NSMutableArray array];
    for(CFIndex i=0;i<CFArrayGetCount(list);i++){
        void *device=(void *)CFArrayGetValueAtIndex(list,i);int32_t w=0,h=0;
        mt.size(device,&w,&h);
        // Hundredths of a millimetre. A device that cannot say how big it is cannot be put into millimetres.
        if(w<=0||h<=0)continue;
        surfaces[@((uintptr_t)device)]=[NSValue valueWithSize:NSMakeSize(w/100.,h/100.)];
        [registered addObject:[NSValue valueWithPointer:device]];[sizes addObject:[NSString stringWithFormat:@"%.0fx%.0f",w/100.,h/100.]];
    }
    if(!registered.count){CFRelease(list);note(@"MultitouchSupport reports no surface size for its devices: trackpad gestures use the views' own touches.");return NO;}
    _devices=list;_registered=registered;self.surfaces=surfaces;
    for(NSValue *device in registered){
        mt.add(device.pointerValue,contactFrame);int rc=mt.start(device.pointerValue,0);
        // The return value says nothing Sunlight acts on; it is shown because a start that failed would otherwise be silent.
        if(rc||DWDebugTrace())fprintf(stderr,"%sMultitouch source: MTDeviceStart(device %p) returned %d\n",rc?"":"debug: ",device.pointerValue,rc);
    }
    _running=YES;
    if(DWDebugTrace()){
        // An untouched pad sends nothing, so silence proves nothing yet: the line says what to do.
        __weak DWMultitouchSource *weakSelf=self;NSUInteger generation=atomic_load(&_generation);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            DWMultitouchSource *source=weakSelf;if(!source||atomic_load(&source->_generation)!=generation||!source->_running)return;
            NSUInteger callbacks=atomic_load(&source->_callbacks);
            fprintf(stderr,"debug: multitouch: 20 s after the start the framework has called back %lu time(s), %lu frame(s) delivered%s\n",(unsigned long)callbacks,(unsigned long)source->_delivered,callbacks?"":" (touch the pad with three fingers: if this stays 0 the framework delivers nothing to this process)");
        });
    }
    fprintf(stderr,"Multitouch source: %lu device(s), surface %s mm; the views' own touches are used until a frame arrives.\n",(unsigned long)registered.count,[sizes componentsJoinedByString:@", "].UTF8String);
    return YES;
}
// The first half of TrackpadPan.restartDevices, 140-151.
- (void)stopDevices {
    for(NSValue *device in _registered){mt.remove(device.pointerValue,contactFrame);mt.stop(device.pointerValue);}
    _registered=nil;if(_devices){CFRelease(_devices);_devices=NULL;}
    os_unfair_lock_lock(&_lock);_followed=0;os_unfair_lock_unlock(&_lock);
    atomic_fetch_add(&_generation,1);_running=NO;
    if(_delivering){
        _delivering=NO;[_guard setLive:NO];
        if(DWDebugTrace())fprintf(stderr,"debug: multitouch: stopped delivering after %lu frame(s) (%lu framework callbacks)\n",(unsigned long)_delivered,(unsigned long)atomic_load(&_callbacks));
        if(_deliveringChanged)_deliveringChanged(NO);
    }
    _touching=NO;
}
- (BOOL)start {
    if(_running)return YES;
    activeSource=self;
    if(![self startDevices]){if(!_wake)activeSource=nil;return NO;}
    if(_wake)return YES;
    // The pad stops reporting across sleep: start over with whatever is attached a second after wake.
    __weak DWMultitouchSource *weak=self;
    _wake=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *wake){
        (void)wake;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak restartDevices];});}];
    return YES;
}
// TrackpadPan.restartDevices, 140-151.
- (void)restartDevices {
    if(!_wake)return;
    [self stopDevices];
    if(![self startDevices])fprintf(stderr,"Multitouch source: not restarted after wake; the views' own touches are used.\n");
}
- (void)stop {
    if(_wake){[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:_wake];_wake=nil;}
    [self stopDevices];if(activeSource==self)activeSource=nil;
}
- (void)dealloc { [self stop]; }
@end

typedef NS_ENUM(NSInteger,DWFeedState){DWFeedIdle,DWFeedUndecided,DWFeedAdmitted,DWFeedRefused};
@implementation DWMultitouchFeed {
    DWTrackpadGestures *(^_recogniser)(void);BOOL (^_admit)(NSUInteger);
    NSMutableDictionary<NSNumber *,NSValue *> *_fed; // path -> where it was last passed on, in mm
    DWFeedState _state;BOOL _admitting;NSUInteger _fingers;
}
- (instancetype)initWithRecogniser:(DWTrackpadGestures *(^)(void))recogniser admit:(BOOL (^)(NSUInteger))admit {
    if((self=[super init])){_recogniser=[recogniser copy];_admit=[admit copy];_fed=[NSMutableDictionary dictionary];}return self;
}
- (NSUInteger)fingers { return _fingers; }
- (BOOL)refused { return _state==DWFeedRefused; }
- (BOOL)consume:(DWMultitouchFrame *)frame {
    NSArray<NSDictionary *> *contacts=frame.contacts;_fingers=contacts.count;
    if(!_fingers){
        // The last finger lifted: what it ends is ended now, not on a timer.
        BOOL fed=_state==DWFeedAdmitted;DWTrackpadGestures *recogniser=fed?_recogniser():nil;
        if(recogniser){for(NSNumber *path in _fed.allKeys){NSPoint at=_fed[path].pointValue;[recogniser touch:path x:at.x y:at.y phase:DWTouchEnded time:frame.time];}[recogniser frame:frame.time];}
        _state=DWFeedIdle;[_fed removeAllObjects];return recogniser!=nil;
    }
    if(_state==DWFeedIdle)_state=DWFeedUndecided;
    if(_state==DWFeedUndecided&&_fingers>=3){
        // The answer may call -cancel: (the shell ends gestures it was holding before it takes this one): that is not this touch's.
        _admitting=YES;BOOL taken=_admit&&_admit(_fingers);_admitting=NO;
        _state=taken?DWFeedAdmitted:DWFeedRefused;
    }
    if(_state!=DWFeedAdmitted)return NO;
    DWTrackpadGestures *recogniser=_recogniser();if(!recogniser)return NO;
    NSMutableSet *now=[NSMutableSet set];
    for(NSDictionary *contact in contacts){
        NSNumber *path=contact[@"path"];[now addObject:path];
        // Millimetres from the pad's top left, y towards the user; MultitouchSupport's y is 0 at the bottom.
        double x=[contact[@"x"]doubleValue]*frame.surface.width,y=(1-[contact[@"y"]doubleValue])*frame.surface.height;
        [recogniser touch:path x:x y:y phase:_fed[path]?DWTouchMoved:DWTouchBegan time:frame.time];_fed[path]=[NSValue valueWithPoint:NSMakePoint(x,y)];
    }
    for(NSNumber *path in _fed.allKeys)if(![now containsObject:path]){NSPoint at=_fed[path].pointValue;[recogniser touch:path x:at.x y:at.y phase:DWTouchEnded time:frame.time];[_fed removeObjectForKey:path];}
    [recogniser frame:frame.time];return YES;
}
- (void)cancel:(NSTimeInterval)time {
    DWTrackpadGestures *recogniser=_recogniser?_recogniser():nil;[recogniser cancel:time];[_fed removeAllObjects];
    if(_state==DWFeedAdmitted&&!_admitting)_state=DWFeedRefused;
}
@end
