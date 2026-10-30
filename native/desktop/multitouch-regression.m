// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic contact frames through the real adapter into the real DWTrackpadGestures, and the Dock-control
// decision on synthetic states. No MultitouchSupport call, no event tap, no device, no window: the source is never
// started and the tap never installed. Passing shows that the code reads the 96-byte records the constants in
// multitouch-source.h describe and turns them into the recogniser's calls; it does not show that the framework
// delivers such records, that its offsets are right on this machine, or that anything is dropped on a trackpad.
#import "dock-guard.m"
#import "multitouch-source.m"

static void check(BOOL value,NSString *message) {
    if(!value){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static BOOL near(double a,double b) { return fabs(a-b)<1e-3; }

// A trackpad as the host reports one: 156 x 96 mm.
static const CGSize pad={156,96};
typedef struct { int path,state;double x,y; } Pt; // x, y in millimetres from the top left, as the recogniser takes them
static NSData *records(const Pt *points,int count) {
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)MAX(count,1)*96];
    for(int i=0;i<count;i++){
        uint8_t *record=(uint8_t *)data.mutableBytes+(size_t)i*96;
        int32_t path=points[i].path,state=points[i].state;float x=(float)(points[i].x/pad.width),y=(float)(1-points[i].y/pad.height);
        // The offsets written out again on purpose, from Sunlight's layout: the header's constants must agree with them.
        memcpy(record+16,&path,4);memcpy(record+20,&state,4);memcpy(record+32,&x,4);memcpy(record+36,&y,4);
    }
    return data;
}

// The whole chain as the shell builds it: source -> feed -> recogniser, with a guard on the side.
@interface Rig : NSObject
@property NSMutableArray<NSDictionary *> *events;
@property DWTrackpadGestures *recogniser;
@property DWMultitouchSource *source;
@property DWMultitouchFeed *feed;
@property DWDockGuard *guard;
@property NSUInteger asked;
@property BOOL admit;
@property NSTimeInterval now;
@end
@implementation Rig
- (instancetype)init {
    if((self=[super init])){
        _events=[NSMutableArray array];_admit=YES;_now=100;_guard=[DWDockGuard new];
        __weak Rig *weak=self;
        _recogniser=[[DWTrackpadGestures alloc]initWithEmit:^(NSDictionary *event){[weak.events addObject:event];}];
        _feed=[[DWMultitouchFeed alloc]initWithRecogniser:^DWTrackpadGestures *{return weak.recogniser;} admit:^BOOL(NSUInteger fingers){Rig *r=weak;r.asked++;(void)fingers;return r.admit;}];
        _source=[[DWMultitouchSource alloc]initWithGuard:_guard frames:^(DWMultitouchFrame *frame){[weak.feed consume:frame];}];
    }
    return self;
}
// One frame of the device, `dt` seconds after the last. Returns what the callback would have handed to the main thread.
- (DWMultitouchFrame *)frame:(const Pt *)points count:(int)count device:(uintptr_t)device after:(NSTimeInterval)dt {
    self.now+=dt;NSData *data=records(points,count);
    DWMultitouchFrame *frame=[self.source intake:data.bytes count:count device:device surface:pad at:self.now];
    if(frame)[self.source deliver:frame];
    return frame;
}
- (void)frame:(const Pt *)points count:(int)count { [self frame:points count:count device:1 after:.008]; }
- (NSArray<NSDictionary *> *)ops:(NSString *)op { return [self.events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"op == %@",op]]; }
@end

// `count` fingers in the given rest positions, all moved by (dx, dy) mm per frame for `frames` frames, 8 ms apart.
static void glide(Rig *rig,const Pt *start,int count,double dx,double dy,int frames) {
    Pt now[8];memcpy(now,start,sizeof(Pt)*(size_t)count);
    for(int k=0;k<frames;k++){for(int i=0;i<count;i++){now[i].x+=dx;now[i].y+=dy;}[rig frame:now count:count];}
}
static void lift(Rig *rig) { [rig frame:NULL count:0]; }

int main(void) {@autoreleasepool {
    // --- Decoding: what the callback reads from a record.
    Rig *rig=[Rig new];
    Pt mixed[]={{7,4,39,24},{8,3,78,48},{9,2,10,10},{10,5,20,20},{11,6,30,30},{12,7,40,40},{13,1,50,50},{14,0,60,60}};
    DWMultitouchFrame *frame=[rig frame:mixed count:8 device:1 after:0];
    check(frame.contacts.count==2,@"only make-touch and touching contacts are fingers; hover, break, linger, range and not-tracking are not");
    check([frame.contacts[0][@"path"]intValue]==7&&near([frame.contacts[0][@"x"]doubleValue],.25)&&near([frame.contacts[0][@"y"]doubleValue],.75),@"path, x left to right and y bottom to top are read from their offsets");
    check([frame.contacts[1][@"path"]intValue]==8&&[frame.contacts[1][@"state"]intValue]==DWContactMake,@"a contact making touch is a finger");
    check(near(frame.surface.width,156)&&near(frame.surface.height,96),@"the frame carries the surface in millimetres");
    lift(rig);
    float nan=NAN;NSMutableData *bad=[records((Pt[]){{1,4,10,10}},1)mutableCopy];memcpy((uint8_t *)bad.mutableBytes+DWContactX,&nan,4);
    check([rig.source intake:bad.bytes count:1 device:1 surface:pad at:1]==nil,@"a non-finite position is no finger, and an empty frame from a device nobody follows is no news");
    Pt twice[]={{5,4,10,10},{5,4,12,12},{6,4,50,50}};
    check([rig frame:twice count:3 device:1 after:.008].contacts.count==2,@"a path listed twice in one frame is one finger");
    lift(rig);
    check([rig.source intake:NULL count:3 device:1 surface:pad at:1]==nil,@"a frame without records is empty");

    // --- A three-finger swipe to the right: begin, updates in the recogniser's units, a clean end.
    rig=[Rig new];
    Pt row3[]={{1,4,50,60},{2,4,65,60},{3,4,80,60}};
    [rig frame:row3 count:3];
    check(rig.asked==1,@"the third finger of a fresh touch asks for admission once");
    glide(rig,row3,3,1,0,12);
    check([rig.events.firstObject[@"op"]isEqual:@"gesture_begin"]&&[rig.events.firstObject[@"kind"]isEqual:@"swipe"]&&[rig.events.firstObject[@"fingers"]intValue]==3,@"three fingers moving together begin a three-finger swipe");
    NSArray *updates=[rig ops:@"gesture_update"];
    check(updates.count>=4,@"the swipe updates frame by frame");
    for(NSDictionary *update in updates)check(near([update[@"dx"]doubleValue],10.5)&&near([update[@"dy"]doubleValue],0),@"one millimetre of finger travel is 10.5 units, to the right, whatever the pad's size");
    check(rig.asked==1,@"admission is not asked again within the touch");
    lift(rig);
    check([rig.events.lastObject[@"op"]isEqual:@"gesture_end"]&&[rig.events.lastObject[@"cancelled"]isEqual:@NO],@"all fingers lifting ends the swipe at once, not cancelled");
    check([rig ops:@"gesture_begin"].count==1&&[rig ops:@"gesture_end"].count==1,@"one begin and one end");
    check([rig.events.firstObject[@"time_ms"]doubleValue]>=100000,@"the frame's time reaches the recogniser in milliseconds");
    // Up the pad is away from the user: MultitouchSupport's y grows, the recogniser's shrinks.
    rig=[Rig new];[rig frame:row3 count:3];glide(rig,row3,3,0,-1,12);
    check([rig ops:@"gesture_update"].count&&near([[rig ops:@"gesture_update"].firstObject[@"dy"]doubleValue],-10.5),@"fingers moving up the pad move away from the user");

    // --- Four fingers.
    rig=[Rig new];
    Pt row4[]={{1,4,40,60},{2,4,60,60},{3,4,80,60},{4,4,100,60}};
    [rig frame:row4 count:4];glide(rig,row4,4,1,0,12);lift(rig);
    check([rig.events.firstObject[@"kind"]isEqual:@"swipe"]&&[rig.events.firstObject[@"fingers"]intValue]==4,@"four fingers moving together are a four-finger swipe");
    check([rig.events.lastObject[@"op"]isEqual:@"gesture_end"]&&[rig.events.lastObject[@"cancelled"]isEqual:@NO],@"and end uncancelled");

    // A finger that lifts while others stay is ended by name, not left out of the frames: the recogniser
    // waits out its count debounce and does not take the gesture for lost at once.
    rig=[Rig new];[rig frame:row4 count:4];glide(rig,row4,4,1,0,12);
    NSUInteger running=rig.events.count;check([rig ops:@"gesture_begin"].count==1&&running>1,@"a four-finger swipe is running");
    Pt after[]={{1,4,52,60},{2,4,72,60},{3,4,92,60}};
    for(int k=1;k<=5;k++){for(int i=0;i<3;i++)after[i].x+=1;[rig frame:after count:3];}
    check([rig ops:@"gesture_end"].count==0,@"one lifted finger of four does not end the swipe within the 100 ms the count must last");
    glide(rig,after,3,1,0,15);
    check([rig ops:@"gesture_end"].count==1&&[[rig ops:@"gesture_end"].firstObject[@"cancelled"]isEqual:@YES],@"a count that lasts ends the four-finger gesture, cancelled");
    lift(rig);

    // --- Pinch: the nearest finger closes away from the rest, which stay.
    rig=[Rig new];
    Pt pinch3[]={{1,4,60,20},{2,4,60,50},{3,4,90,35}};
    [rig frame:pinch3 count:3];
    Pt move3[]={{1,4,60,20},{2,4,60,50},{3,4,90,35}};
    for(int k=1;k<=12;k++){move3[1].y=50+1.5*k;[rig frame:move3 count:3];}
    lift(rig);
    NSDictionary *begun=[rig ops:@"gesture_begin"].firstObject;
    check([begun[@"kind"]isEqual:@"pinch"]&&[begun[@"fingers"]intValue]==3,@"one finger moving away from fingers that stay is a three-finger pinch");
    NSDictionary *lastPinch=[rig ops:@"gesture_update"].lastObject;
    check(near([lastPinch[@"scale"]doubleValue],48/40.5),@"the pinch scale is the distance now over the distance when the pinch was recognised (48 mm over 40.5)");
    check([rig.events.lastObject[@"cancelled"]isEqual:@NO],@"a pinch ends uncancelled when the fingers lift");
    rig=[Rig new];
    Pt pinch4[]={{1,4,60,20},{2,4,60,50},{3,4,80,35},{4,4,100,35}};
    [rig frame:pinch4 count:4];
    Pt move4[]={{1,4,60,20},{2,4,60,50},{3,4,80,35},{4,4,100,35}};
    for(int k=1;k<=12;k++){move4[1].y=50+2*k;[rig frame:move4 count:4];}
    lift(rig);
    begun=[rig ops:@"gesture_begin"].firstObject;
    check([begun[@"kind"]isEqual:@"pinch"]&&[begun[@"fingers"]intValue]==4,@"and a four-finger pinch with four");

    // --- A cancel ends the gesture cancelled and the rest of the touch is nobody's; the next touch is.
    rig=[Rig new];[rig frame:row3 count:3];glide(rig,row3,3,1,0,12);
    NSUInteger before=rig.events.count;
    [rig.feed cancel:rig.now];
    check([rig.events.lastObject[@"op"]isEqual:@"gesture_end"]&&[rig.events.lastObject[@"cancelled"]isEqual:@YES]&&rig.events.count==before+1,@"cancel ends the gesture in progress, cancelled");
    glide(rig,(Pt[]){{1,4,62,60},{2,4,77,60},{3,4,92,60}},3,1,0,12);
    check(rig.events.count==before+1,@"the fingers still down start nothing after a cancel");
    lift(rig);
    check(rig.events.count==before+1,@"and lifting them ends nothing twice");
    [rig frame:row3 count:3];glide(rig,row3,3,1,0,12);
    check([rig ops:@"gesture_begin"].count==2&&rig.asked==2,@"a new touch is admitted afresh and swipes");
    lift(rig);

    // --- A resting finger: left out where the policy says so, as the NSTouch path leaves out a resting touch.
    Pt withThumb[]={{1,4,50,40},{2,4,65,40},{3,4,80,40},{9,4,60,88}};
    rig=[Rig new];rig.source.resting=^BOOL(NSDictionary *contact){return [contact[@"path"]intValue]==9;};
    [rig frame:withThumb count:4];glide(rig,withThumb,4,1,0,12);
    check([rig ops:@"gesture_begin"].count==1&&[[rig ops:@"gesture_begin"].firstObject[@"fingers"]intValue]==3,@"a resting thumb beside three moving fingers is not a fourth finger");
    check([rig.guard state].fingers==3,@"nor does the Dock guard count it");
    lift(rig);
    rig=[Rig new];
    [rig frame:withThumb count:4];glide(rig,withThumb,4,1,0,12);
    check([[rig ops:@"gesture_begin"].firstObject[@"fingers"]intValue]==4,@"with no policy the same contacts are four fingers: nothing in-tree classifies resting contacts");

    // --- Admission declined: nothing reaches the recogniser until the next touch.
    rig=[Rig new];rig.admit=NO;
    Pt two[]={{1,4,50,60},{2,4,65,60}};
    [rig frame:two count:2];glide(rig,two,2,1,0,4);
    check(rig.asked==0,@"one and two fingers ask nothing");
    [rig frame:row3 count:3];glide(rig,row3,3,1,0,12);
    check(rig.asked==1&&rig.events.count==0&&rig.feed.refused,@"a declined touch is asked once and reaches the recogniser not at all");
    lift(rig);rig.admit=YES;
    [rig frame:row3 count:3];glide(rig,row3,3,1,0,12);
    check(rig.asked==2&&[rig ops:@"gesture_begin"].count==1&&!rig.feed.refused,@"the touch after it is asked afresh");
    lift(rig);

    // --- Two pads: the one that is followed is the only one heard.
    rig=[Rig new];
    [rig frame:row3 count:3 device:1 after:.008];
    check([rig frame:row3 count:3 device:2 after:.001]==nil,@"a second device is ignored while the first has a finger down");
    check([rig frame:NULL count:0 device:2 after:.001]==nil,@"and its lift is not the first's");
    glide(rig,row3,3,1,0,12);lift(rig);
    check([rig ops:@"gesture_begin"].count==1&&[rig ops:@"gesture_end"].count==1,@"one gesture from the one pad");
    check([rig frame:row3 count:3 device:2 after:.1]!=nil,@"once the first has lifted the other may be followed");
    [rig frame:NULL count:0 device:2 after:.01];

    // A pad that went quiet with a finger down (unplugged, its radio dropped) is not followed for ever.
    rig=[Rig new];
    [rig frame:row3 count:3 device:1 after:.008];
    check([rig frame:row3 count:3 device:2 after:20]==nil,@"a pad quiet for 20 s still holds the claim");
    check([rig frame:row3 count:3 device:2 after:11]!=nil,@"and one quiet for more than 30 s loses it");
    [rig frame:NULL count:0 device:2 after:.01];

    // --- The source: delivery order, staleness and the delivering flag.
    rig=[Rig new];
    __block NSMutableArray<NSNumber *> *changes=[NSMutableArray array];
    rig.source.deliveringChanged=^(BOOL delivering){[changes addObject:@(delivering)];};
    check(!rig.source.delivering,@"nothing is delivering before a frame");
    DWMultitouchFrame *stale=[DWMultitouchFrame frameWithContacts:@[@{@"path":@1,@"x":@.5,@"y":@.5,@"state":@4}] surface:pad time:1 contact:1 generation:99];
    [rig.source deliver:stale];
    check(!rig.source.delivering&&changes.count==0,@"a frame of an earlier start is dropped");
    [rig frame:row3 count:3];
    check(rig.source.delivering&&changes.count==1&&[changes[0]boolValue],@"the first frame with a finger makes the source deliver");
    lift(rig);

    // --- The Dock guard: a pure decision.
    uint32_t three4=(1u<<3)|(1u<<4);
    DWDockGuardState s={0};DWDockGuardBound(&s,three4);
    DWDockGuardFingers(&s,3,10);
    check(!DWDockGuardDrops(&s,10),@"nothing is dropped while no touch source delivers");
    DWDockGuardLive(&s,YES);
    check(DWDockGuardDrops(&s,10)&&DWDockGuardHolds(&s),@"three fingers, a bound count, hold Dock control back once a source delivers");
    DWDockGuardFingers(&s,4,10.1);check(DWDockGuardDrops(&s,10.1),@"and four");
    DWDockGuardFingers(&s,5,10.2);check(!DWDockGuardDrops(&s,10.2)&&!DWDockGuardDrops(&s,10.3),@"five fingers are not bound: neither held back nor given a tail");
    DWDockGuardFingers(&s,2,10.4);check(!DWDockGuardDrops(&s,10.4),@"two are not bound");
    DWDockGuardFingers(&s,0,10.5);check(!DWDockGuardDrops(&s,10.5)&&!DWDockGuardDrops(&s,10.7),@"a touch that was never bound leaves no tail");
    DWDockGuardFingers(&s,3,11);DWDockGuardFingers(&s,0,11.2);
    check(DWDockGuardDrops(&s,11.2)&&DWDockGuardDrops(&s,11.2+DWDockTail-.001),@"after bound fingers lift the tail still drops");
    check(!DWDockGuardDrops(&s,11.2+DWDockTail)&&!DWDockGuardDrops(&s,12),@"and expires");
    DWDockGuardFingers(&s,3,13);DWDockGuardFingers(&s,4,13.001);DWDockGuardFingers(&s,5,13.002);
    check(!DWDockGuardDrops(&s,13.003),@"a touch that grows to an unbound count is given back to the system at once");
    DWDockGuardFingers(&s,0,13.1);check(!DWDockGuardDrops(&s,13.1),@"and has no tail");
    // Only three bound: a fourth finger frees the touch.
    DWDockGuardBound(&s,1u<<3);DWDockGuardFingers(&s,3,14);check(DWDockGuardDrops(&s,14),@"three bound");
    DWDockGuardFingers(&s,4,14.05);check(!DWDockGuardDrops(&s,14.05)&&!DWDockGuardDrops(&s,14.1),@"four not bound when only three are: no drop, and no tail from the three");
    DWDockGuardFingers(&s,0,14.2);
    // A gesture in progress holds on after a finger lifts, and its end starts the tail.
    DWDockGuardBound(&s,three4);DWDockGuardFingers(&s,3,15);DWDockGuardGesture(&s,3,15.1);DWDockGuardFingers(&s,2,15.2);
    check(DWDockGuardDrops(&s,15.3),@"a bound gesture still in progress holds when a finger has lifted");
    DWDockGuardGesture(&s,0,15.4);
    check(DWDockGuardDrops(&s,15.5)&&!DWDockGuardDrops(&s,15.4+DWDockTail),@"its end starts the tail");
    DWDockGuardFingers(&s,0,15.6);
    // The shell declined a touch: the system keeps it, and only that one.
    DWDockGuardFingers(&s,3,20);uint32_t mine=s.contact;DWDockGuardRefuse(&s,mine);
    check(!DWDockGuardDrops(&s,20)&&s.refused,@"a refused touch is the system's");
    DWDockGuardFingers(&s,0,20.1);check(!DWDockGuardDrops(&s,20.1),@"and has no tail");
    DWDockGuardFingers(&s,3,21);DWDockGuardRefuse(&s,mine);check(DWDockGuardDrops(&s,21),@"a refusal that arrives after its touch is over refuses nothing of the next");
    DWDockGuardFingers(&s,0,21.1);
    DWDockGuardFingers(&s,3,22);DWDockGuardLive(&s,NO);check(!DWDockGuardDrops(&s,22)&&!DWDockGuardDrops(&s,22.1)&&!s.fingers,@"a source that stops delivering holds nothing back, tail included");
    DWDockGuardLive(&s,YES);
    // Unconfigured: no binding, no drop.
    DWDockGuardBound(&s,0);DWDockGuardFingers(&s,3,30);check(!DWDockGuardDrops(&s,30),@"no binding, no drop");
    DWDockGuardFingers(&s,0,30.1);

    // --- The guard fed by the source as the shell wires it: counts from the callback's side, liveness from the main thread's.
    rig=[Rig new];[rig.guard setBound:three4];
    rig.now=200;
    Pt three[]={{1,4,50,60},{2,4,65,60},{3,4,80,60}};
    NSData *landing=records(three,3);
    DWMultitouchFrame *first=[rig.source intake:landing.bytes count:3 device:1 surface:pad at:rig.now];
    check(first&&![rig.guard dropsAt:rig.now],@"the callback has counted three fingers but the source is not yet delivering: nothing dropped");
    [rig.source deliver:first];
    check([rig.guard dropsAt:rig.now],@"the first delivered frame makes the source live and Dock control is dropped");
    glide(rig,three,3,1,0,3);
    [rig frame:NULL count:0 device:1 after:.008];
    check([rig.guard dropsAt:rig.now+.1]&&![rig.guard dropsAt:rig.now+DWDockTail+.001],@"after the lift the tail runs");
    // The recogniser's gesture, as the shell notes it: it holds with the pad empty, and its end starts a tail.
    [rig.guard gesture:3 at:rig.now+1];
    check([rig.guard dropsAt:rig.now+1.2],@"a bound gesture in progress holds Dock control back");
    [rig.guard gesture:0 at:rig.now+1.5];
    check([rig.guard dropsAt:rig.now+1.6]&&![rig.guard dropsAt:rig.now+1.5+DWDockTail+.01],@"and its end starts a tail");

    // --- The tap's filter: only event type 30, only when the guard says so, and no tap is installed.
    DWDockGuard *guard=[DWDockGuard new];DWDockTap *tap=[[DWDockTap alloc]initWithGuard:guard];
    CGEventRef dock=CGEventCreate(NULL),other=CGEventCreate(NULL);check(dock&&other,@"in-memory events");
    CGEventSetType(dock,(CGEventType)30);CGEventSetType(other,kCGEventLeftMouseDown);
    check(!tap.running,@"a tap that was never started is not running");
    [guard setBound:three4];[guard fingers:3 at:50];
    check([tap filter:(CGEventType)30 event:dock at:50]==dock,@"a source that is not delivering lets Dock control through");
    [guard setLive:YES];
    check([tap filter:(CGEventType)30 event:dock at:50]==NULL,@"three bound fingers drop a Dock-control event");
    check([tap filter:kCGEventLeftMouseDown event:other at:50]==other&&[tap filter:kCGEventScrollWheel event:other at:50]==other,@"nothing else is touched");
    check([tap filter:kCGEventTapDisabledByTimeout event:NULL at:50]==NULL,@"a disabled-tap notice carries no event and is passed as it came");
    [guard fingers:2 at:50.1];
    check([tap filter:(CGEventType)30 event:dock at:50.1]==dock,@"two fingers are not bound: the event goes through");
    [guard fingers:4 at:50.2];[guard fingers:0 at:50.3];
    check([tap filter:(CGEventType)30 event:dock at:50.4]==NULL&&[tap filter:(CGEventType)30 event:dock at:50.3+DWDockTail+.01]==dock,@"the tail drops and then ends");
    CFRelease(dock);CFRelease(other);
    puts("multitouch: contact decoding, adapter, recogniser events and the Dock-control decision passed on synthetic input; no MultitouchSupport, tap, device or trackpad was involved");
}return 0;}
