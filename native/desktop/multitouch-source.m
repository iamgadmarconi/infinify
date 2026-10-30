// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from spacefarm-digital/sunlight afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright (c) 2026 spacefarm):
// Sources/Canvas/TrackpadPan.swift. Taken: the framework's path and the six symbols looked up at run time with dlopen
// and dlsym, MTDeviceCreateList, MTRegisterContactFrameCallback, MTUnregisterContactFrameCallback, MTDeviceStart,
// MTDeviceStop and MTDeviceGetSensorSurfaceDimensions, with the surface size in hundredths of a millimetre (lines
// 396-429); the 96-byte contact record and the offsets read from it, path 16, state 20, x 32 and y 36, with y 0 at the
// bottom and only states 3 and 4 on the surface (lines 384-394); starting every device of the list, and stopping and
// starting them again on wake after a second's wait (lines 96-102 and 118-152); the frame callback's static pointer to
// its owner, because the framework passes no context (lines 65-66 and 160-165), and decoding on the framework's own
// thread (lines 167-194). Not taken: Sunlight's four-finger recogniser; here the frames go to DWTrackpadGestures.
// The offsets, the units and the claim that a frame arrives when a finger lifts are Sunlight's and nothing in this tree
// has checked them against hardware: the regression builds records with the same constants and proves only that the
// code reads what it was told to read.
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
// Why the framework is not there, or nil. Looked up once.
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
}
- (instancetype)initWithGuard:(DWDockGuard *)guard frames:(void (^)(DWMultitouchFrame *))frames {
    if((self=[super init])){_guard=guard;_frames=[frames copy];_lock=OS_UNFAIR_LOCK_INIT;}return self;
}
- (BOOL)running { return _running; }
- (BOOL)delivering { return _delivering; }
- (DWMultitouchFrame *)intake:(const void *)records count:(int32_t)count device:(uintptr_t)device surface:(CGSize)surface at:(NSTimeInterval)now {
    NSArray *fingers=surfaceContacts(records,count,self.resting);BOOL skip=NO,ended=NO;
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
- (void)deliver:(DWMultitouchFrame *)frame {
    if(frame.generation!=atomic_load(&_generation))return;
    if(!_delivering&&frame.contacts.count){_delivering=YES;[_guard setLive:YES];if(_deliveringChanged)_deliveringChanged(YES);}
    if(_frames)_frames(frame);
}
- (BOOL)attach {
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
    for(NSValue *device in registered){mt.add(device.pointerValue,contactFrame);mt.start(device.pointerValue,0);}
    _running=YES;
    fprintf(stderr,"Multitouch source: %lu device(s), surface %s mm; the views' own touches are used until a frame arrives.\n",(unsigned long)registered.count,[sizes componentsJoinedByString:@", "].UTF8String);
    return YES;
}
- (void)detach {
    for(NSValue *device in _registered){mt.remove(device.pointerValue,contactFrame);mt.stop(device.pointerValue);}
    _registered=nil;if(_devices){CFRelease(_devices);_devices=NULL;}
    os_unfair_lock_lock(&_lock);_followed=0;os_unfair_lock_unlock(&_lock);
    atomic_fetch_add(&_generation,1);_running=NO;
    if(_delivering){_delivering=NO;[_guard setLive:NO];if(_deliveringChanged)_deliveringChanged(NO);}
}
- (BOOL)start {
    if(_running)return YES;
    activeSource=self;
    if(![self attach]){if(!_wake)activeSource=nil;return NO;}
    if(_wake)return YES;
    // The pad stops reporting across sleep: start over with whatever is attached a second after wake.
    __weak DWMultitouchSource *weak=self;
    _wake=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *wake){
        (void)wake;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak restart];});}];
    return YES;
}
- (void)restart {
    if(!_wake)return;
    [self detach];
    if(![self attach])fprintf(stderr,"Multitouch source: not restarted after wake; the views' own touches are used.\n");
}
- (void)stop {
    if(_wake){[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:_wake];_wake=nil;}
    [self detach];if(activeSource==self)activeSource=nil;
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
