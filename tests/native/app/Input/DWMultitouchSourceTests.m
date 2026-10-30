// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic contact frames through the real adapter into the real DWTrackpadGestures, and the Dock-control
// decision on synthetic states and on in-memory type-30 packets. No MultitouchSupport call, no event tap, no device,
// no window: the source is never started and the tap never installed. Passing shows that the code reads the 96-byte
// records the constants in DWMultitouchSource.h describe and turns them into the recogniser's calls, and what the
// guard decides about a packet given the counts it was told; it does not show that the framework delivers such
// records, that its offsets are right on this machine, that the Dock-control packets of a Show Desktop or Launchpad
// pinch look like the ones built here, or that anything is dropped on a trackpad.
#import "DWDockGuard.m"
#import "DWMultitouchSource.m"

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
// A Dock-control packet as the system's DockSwipe stream makes them (axis 3 is the pinch, 1 and 2 the swipes). `stamp` makes it a packet of its own.
static CGEventRef dockSwipe(NSInteger axis,NSInteger phase,uint64_t stamp) {
    CGEventRef event=CGEventCreate(NULL);check(event!=NULL,@"in-memory Dock-control packet");
    CGEventSetType(event,DWDockControlType);CGEventSetIntegerValueField(event,DWGestureRealType,30);CGEventSetIntegerValueField(event,DWGestureHIDType,23);
    CGEventSetIntegerValueField(event,DWGestureAxis,axis);CGEventSetIntegerValueField(event,DWGesturePhase,phase);CGEventSetTimestamp(event,stamp);return event;
}
// A packet of a format the decoder does not know: the shape a Show Desktop or Launchpad pinch may have, which has never been seen.
static CGEventRef dockOther(uint64_t stamp) { CGEventRef event=dockSwipe(3,kCGGesturePhaseChanged,stamp);CGEventSetIntegerValueField(event,DWGestureHIDType,8);return event; }
// Thumb and three fingers on the pad, as a hand makes them: the three land first and the thumb a few frames later, then everything rests for 64 ms.
static void landHand(Rig *rig,const Pt hand[4]) {
    Pt now[4];memcpy(now,hand,sizeof now);
    for(int k=0;k<3;k++)[rig frame:now count:3];
    for(int k=0;k<8;k++)[rig frame:now count:4];
}
// The hand moves from `from` to `to` in `steps` frames, 8 ms apart.
static void moveHand(Rig *rig,const Pt from[4],const Pt to[4],int steps) {
    Pt now[4];
    for(int k=1;k<=steps;k++){double f=(double)k/steps;for(int i=0;i<4;i++){now[i]=from[i];now[i].x=from[i].x+(to[i].x-from[i].x)*f;now[i].y=from[i].y+(to[i].y-from[i].y)*f;}[rig frame:now count:4];}
}

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
    // Sunlight's drop time (TrackpadPan.swift 298-299): it moves on with every report of a touch that reached a bound count, whatever the count has become since,
    // and the flag goes with the last finger.
    DWDockGuardState t={0};DWDockGuardBound(&t,three4);DWDockGuardLive(&t,YES);
    DWDockGuardFingers(&t,4,40);DWDockGuardFingers(&t,2,40.2);
    check(DWDockGuardDrops(&t,40.2+DWDockTail-.001)&&!DWDockGuardDrops(&t,40.2+DWDockTail+.001),@"a touch at a bound count that fell to two fingers is dropped for the tail from the last report");
    DWDockGuardFingers(&t,2,40.4);check(DWDockGuardDrops(&t,40.4+DWDockTail-.001),@"and the drop time moves on with each report while any finger is down");
    DWDockGuardFingers(&t,0,40.5);check(DWDockGuardDrops(&t,40.5+DWDockTail-.001)&&!DWDockGuardDrops(&t,40.5+DWDockTail+.001)&&!t.boundTouch,@"the lift ends the flag and starts the tail from the lift");
    DWDockGuardFingers(&t,2,41);check(!DWDockGuardDrops(&t,41),@"two fingers of the next touch are not bound");
    DWDockGuardFingers(&t,0,41.1);
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
    [guard fingers:0 at:50.5];[guard fingers:2 at:51];
    check([tap filter:(CGEventType)30 event:dock at:51]==dock,@"two fingers on a fresh touch are not bound: a packet after a pause goes through");
    [guard fingers:4 at:51.2];[guard fingers:0 at:51.3];
    check([tap filter:(CGEventType)30 event:dock at:51.4]==NULL,@"the tail drops");
    check([tap filter:(CGEventType)30 event:dock at:51.9]==dock,@"and then ends");
    CFRelease(dock);CFRelease(other);

    // --- Thumb and three fingers, pinching and spreading: MultitouchSupport counts the thumb, so the guard and the recogniser both see four.
    // Pad coordinates in mm, y towards the user: three fingertips in a row above the thumb, which lies lower and to the side.
    Pt together[4]={{1,4,70,38},{2,4,82,34},{3,4,94,37},{9,4,52,70}};
    Pt apart[4]={{1,4,86,18},{2,4,98,14},{3,4,110,17},{9,4,34,86}};
    // Show Desktop: the thumb and the fingers spread.
    rig=[Rig new];[rig.guard setBound:three4];landHand(rig,together);moveHand(rig,together,apart,20);lift(rig);
    begun=[rig ops:@"gesture_begin"].firstObject;
    check([rig ops:@"gesture_begin"].count==1&&[begun[@"kind"]isEqual:@"pinch"]&&[begun[@"fingers"]intValue]==4,@"a thumb and three fingers spreading are one four-finger pinch");
    check([[rig ops:@"gesture_update"].lastObject[@"scale"]doubleValue]>1.5,@"whose scale grows: the pinch-out binding's");
    check([rig.events.lastObject[@"op"]isEqual:@"gesture_end"]&&[rig.events.lastObject[@"cancelled"]isEqual:@NO],@"and ends when the fingers lift");
    // Launchpad: the same hand, closing.
    rig=[Rig new];[rig.guard setBound:three4];landHand(rig,apart);moveHand(rig,apart,together,20);lift(rig);
    begun=[rig ops:@"gesture_begin"].firstObject;
    check([rig ops:@"gesture_begin"].count==1&&[begun[@"kind"]isEqual:@"pinch"]&&[begun[@"fingers"]intValue]==4&&[[rig ops:@"gesture_update"].lastObject[@"scale"]doubleValue]<.7,@"a thumb and three fingers closing are a four-finger pinch whose scale shrinks: the pinch-in binding's");
    // The hand drifts while it spreads: 20 mm of thumb-to-finger separation and 12 mm of drift, up and to the left. The fingers and the thumb
    // that move apart also move the same way, which the two-touch rules read as a swipe (nothing here is wrong with that for a plain swipe).
    Pt drifted[4];for(int i=0;i<4;i++){double along=i<3?8:-12,ux=30/hypot(30,36),uy=-36/hypot(30,36);drifted[i]=together[i];drifted[i].x+=ux*along-9.6;drifted[i].y+=uy*along-7.2;}
    rig=[Rig new];[rig.guard setBound:three4];landHand(rig,together);moveHand(rig,together,drifted,20);lift(rig);
    check([rig ops:@"gesture_begin"].count==1&&[[rig ops:@"gesture_begin"].firstObject[@"kind"]isEqual:@"pinch"],@"a spread that drifts along with the hand is still a pinch: every finger's distance from their centre is read, not the two touches' directions");
    // A four-finger swipe that fans a little stays a swipe.
    Pt fanned[4];for(int i=0;i<4;i++){fanned[i]=together[i];fanned[i].x+=20+(i-1.5)*2;fanned[i].y+=(i<3?-1:1)*1.5;}
    rig=[Rig new];[rig.guard setBound:three4];landHand(rig,together);moveHand(rig,together,fanned,20);lift(rig);
    check([rig ops:@"gesture_begin"].count==1&&[[rig ops:@"gesture_begin"].firstObject[@"kind"]isEqual:@"swipe"]&&[[rig ops:@"gesture_begin"].firstObject[@"fingers"]intValue]==4,@"while four fingers that translate and fan a little stay a four-finger swipe");

    // --- The guard holds from the finger count, before the recogniser has recognised anything: the system's pinch begins as soon as the hand moves.
    rig=[Rig new];[rig.guard setBound:three4];
    Pt cut[4];memcpy(cut,together,sizeof cut);
    for(int k=0;k<2;k++)[rig frame:cut count:2];
    check(![rig.guard dropsAt:rig.now]&&rig.source.delivering,@"two fingers: the source delivers and nothing is held back");
    [rig frame:cut count:3];
    check([rig.guard dropsAt:rig.now]&&rig.events.count==0,@"the third finger holds Dock control back before the recogniser has begun anything");
    [rig frame:cut count:4];
    check([rig.guard dropsAt:rig.now]&&rig.events.count==0&&[rig.guard state].fingers==4,@"and the thumb makes four, still before any gesture: the thumb counts, as it does for the system");
    lift(rig);

    // --- Dock-control streams follow their beginning, whatever the count does meanwhile, because the Dock must see all of a gesture or none.
    // Show Desktop as the system sends it: a begin when four contacts have moved, changes, an end after the fingers have lifted one by one.
    rig=[Rig new];[rig.guard setBound:three4];tap=[[DWDockTap alloc]initWithGuard:rig.guard];
    landHand(rig,together);
    CGEventRef began=dockSwipe(3,kCGGesturePhaseBegan,1),changed=dockSwipe(3,kCGGesturePhaseChanged,2),changedLate=dockSwipe(3,kCGGesturePhaseChanged,3),ended=dockSwipe(3,kCGGesturePhaseEnded,4);
    check([tap filter:DWDockControlType event:began at:rig.now]==NULL,@"the beginning of the system's pinch with four contacts down is dropped");
    Pt rest3[3]={{1,4,86,18},{2,4,98,14},{3,4,110,17}};
    [rig frame:rest3 count:3 device:1 after:.02];
    check([tap filter:DWDockControlType event:changed at:rig.now]==NULL,@"a change with three left is dropped");
    [rig frame:rest3 count:2 device:1 after:.02];[rig frame:rest3 count:1 device:1 after:.02];
    check([rig.guard state].fingers==1&&[tap filter:DWDockControlType event:changedLate at:rig.now]==NULL,@"a change with one finger left is dropped although one is no bound count: the touch was held to its end, and the stream began dropped");
    lift(rig);rig.now+=DWDockTail+.4;
    check(![rig.guard dropsAt:rig.now]&&[tap filter:DWDockControlType event:ended at:rig.now]==NULL,@"the end of the stream, long after the tail, is dropped with the rest: the Dock is never given an end without a beginning");
    CGEventRef next=dockSwipe(3,kCGGesturePhaseChanged,5);rig.now+=.1;
    check([tap filter:DWDockControlType event:next at:rig.now]==next,@"and the stream is over: a later packet is judged by the count (none)");
    CFRelease(began);CFRelease(changed);CFRelease(changedLate);CFRelease(ended);CFRelease(next);

    // A stream that began with the system keeps going to it, even when the count passes through a bound one on its way down.
    rig=[Rig new];[rig.guard setBound:three4];tap=[[DWDockTap alloc]initWithGuard:rig.guard];
    Pt five[5]={{1,4,50,30},{2,4,62,28},{3,4,74,30},{4,4,86,32},{5,4,40,70}};
    for(int k=0;k<8;k++)[rig frame:five count:5];
    began=dockSwipe(2,kCGGesturePhaseBegan,11);changed=dockSwipe(2,kCGGesturePhaseChanged,12);ended=dockSwipe(2,kCGGesturePhaseEnded,13);
    check([tap filter:DWDockControlType event:began at:rig.now]==began,@"five contacts are no bound count: the system's gesture begins with the system");
    [rig frame:five count:4 device:1 after:.02];
    check([rig.guard dropsAt:rig.now]&&[tap filter:DWDockControlType event:changed at:rig.now]==changed,@"a finger lifting brings a bound count, which would drop a stream beginning now, but this one began with the system and goes on with it");
    lift(rig);
    check([tap filter:DWDockControlType event:ended at:rig.now+.05]==ended,@"and its end");
    CFRelease(began);CFRelease(changed);CFRelease(ended);

    // A packet of a format nobody has decoded: judged by the count at its first packet, then as a run while the packets keep coming.
    rig=[Rig new];[rig.guard setBound:three4];tap=[[DWDockTap alloc]initWithGuard:rig.guard];
    landHand(rig,together);
    CGEventRef a1=dockOther(21),a2=dockOther(22),a3=dockOther(23),a4=dockOther(24);
    check([tap filter:DWDockControlType event:a1 at:rig.now]==NULL,@"an undecoded packet with four contacts down is dropped");
    [rig frame:rest3 count:2 device:1 after:.1];
    check([tap filter:DWDockControlType event:a2 at:rig.now]==NULL,@"the next, a tenth of a second later with two left, belongs to the same run");
    [rig frame:rest3 count:1 device:1 after:.1];lift(rig);
    check([tap filter:DWDockControlType event:a3 at:rig.now+.1]==NULL,@"and one after the fingers have all lifted, within the tail a touch at a bound count owes whatever the count did on the way down");
    check([tap filter:DWDockControlType event:a4 at:rig.now+.1+DWDockTail+.2]==a4,@"but not after a pause longer than the tail");
    CFRelease(a1);CFRelease(a2);CFRelease(a3);CFRelease(a4);
    // The tail is owed to a touch that was at a bound count however the count fell: fingers lift one by one, so the last count before none is rarely a bound one.
    rig=[Rig new];[rig.guard setBound:three4];tap=[[DWDockTap alloc]initWithGuard:rig.guard];
    landHand(rig,together);[rig frame:rest3 count:3 device:1 after:.02];[rig frame:rest3 count:2 device:1 after:.02];[rig frame:rest3 count:1 device:1 after:.02];lift(rig);
    CGEventRef b1=dockOther(26),b2=dockOther(27);
    check([tap filter:DWDockControlType event:b1 at:rig.now+.1]==NULL&&[tap filter:DWDockControlType event:b2 at:rig.now+.1+DWDockTail+.2]==b2,@"four fingers lifting one by one owe the tail, which then ends");
    CFRelease(b1);CFRelease(b2);
    // A touch that grew past every bound count was the system's, and owes it nothing.
    rig=[Rig new];[rig.guard setBound:three4];tap=[[DWDockTap alloc]initWithGuard:rig.guard];
    for(int k=0;k<2;k++)[rig frame:five count:3];for(int k=0;k<2;k++)[rig frame:five count:4];for(int k=0;k<6;k++)[rig frame:five count:5];
    [rig frame:five count:3 device:1 after:.02];[rig frame:five count:1 device:1 after:.02];lift(rig);
    b1=dockOther(28);
    check([tap filter:DWDockControlType event:b1 at:rig.now+.1]==NULL,@"a hand that went from five fingers down to none through the bound counts is held for its tail, as a staggered lift of any hand is");
    CFRelease(b1);
    rig=[Rig new];[rig.guard setBound:three4];tap=[[DWDockTap alloc]initWithGuard:rig.guard];
    for(int k=0;k<2;k++)[rig frame:five count:3];for(int k=0;k<2;k++)[rig frame:five count:4];for(int k=0;k<6;k++)[rig frame:five count:5];lift(rig);
    b1=dockOther(29);
    check([tap filter:DWDockControlType event:b1 at:rig.now+.1]==b1,@"but one lifted from five at once owes none");
    CFRelease(b1);
    // The stream of a touch the shell declined is the system's.
    rig=[Rig new];[rig.guard setBound:three4];tap=[[DWDockTap alloc]initWithGuard:rig.guard];
    DWMultitouchFrame *refusedFrame=[rig frame:together count:4 device:1 after:.01];[rig.guard refuseContact:refusedFrame.contact];
    began=dockSwipe(3,kCGGesturePhaseBegan,31);
    check([tap filter:DWDockControlType event:began at:rig.now]==began,@"a touch the shell declined keeps its Dock-control stream");
    CFRelease(began);
    // A beginning always starts afresh, and a stream that never ended is forgotten after a second.
    rig=[Rig new];[rig.guard setBound:three4];tap=[[DWDockTap alloc]initWithGuard:rig.guard];
    landHand(rig,together);
    began=dockSwipe(3,kCGGesturePhaseBegan,41);changed=dockSwipe(3,kCGGesturePhaseChanged,42);CGEventRef again=dockSwipe(3,kCGGesturePhaseBegan,43);
    [tap filter:DWDockControlType event:began at:rig.now];lift(rig);rig.now+=2;
    check([tap filter:DWDockControlType event:changed at:rig.now]==changed,@"a stream that went a second without a packet is over: a change is judged by the count");
    [rig frame:together count:4 device:1 after:.5];[rig.guard fingers:4 at:rig.now];
    check([tap filter:DWDockControlType event:again at:rig.now]==NULL,@"and a new beginning is judged afresh");
    CFRelease(began);CFRelease(changed);CFRelease(again);

    // The guard in two taps: the packet the first tap decided is not decided again by the second, which gets the same answer.
    rig=[Rig new];[rig.guard setBound:three4];landHand(rig,together);
    CGEventRef both=dockSwipe(3,kCGGesturePhaseBegan,51);
    check([rig.guard decide:both via:"dock-tap" at:rig.now]==DWDockControlDrop&&[rig.guard decide:both via:"global-tap" at:rig.now+.001]==DWDockControlDrop,@"the second tap that sees a packet gets the first tap's verdict");
    lift(rig);rig.now+=DWDockTail+.1;
    check([rig.guard decide:both via:"dock-tap" at:rig.now]==DWDockControlPass,@"and the same packet judged again by the same tap is judged afresh");
    CFRelease(both);
    DWDockGuard *idle=[DWDockGuard new];[idle setBound:three4];[idle fingers:4 at:1];CGEventRef notLive=dockSwipe(3,kCGGesturePhaseBegan,61);
    check([idle decide:notLive via:"dock-tap" at:1]==DWDockControlUndecided,@"with no touch source delivering the guard leaves the packet to the tap's own rules");
    CFRelease(notLive);
    // The reasons the log gives.
    DWDockGuardState r={0};DWDockGuardBound(&r,three4);DWDockReason why;
    DWDockGuardDecide(&r,DWDockControlBegan,1,&why);check(why==DWDockReasonNotLive,@"reason: not delivering");
    DWDockGuardLive(&r,YES);DWDockGuardDecide(&r,DWDockControlBegan,2,&why);check(why==DWDockReasonUnbound,@"reason: no fingers");
    DWDockGuardFingers(&r,4,2.2);check(!strcmp(DWDockReasonName(why),"count-not-bound")&&!DWDockGuardDecide(&r,DWDockControlChanged,2.4,&why)&&why==DWDockReasonRunPassed,@"reason: the stream began with the system");
    DWDockGuardDecide(&r,DWDockControlBegan,3.1,&why);check(why==DWDockReasonFingers,@"reason: bound fingers");
    DWDockGuardFingers(&r,2,3.2);DWDockGuardDecide(&r,DWDockControlChanged,3.2,&why);check(why==DWDockReasonRunDropped,@"reason: the stream began dropped");
    DWDockGuardDecide(&r,DWDockControlEnded,3.3,&why);DWDockGuardGesture(&r,3,3.4);DWDockGuardDecide(&r,DWDockControlBegan,3.5,&why);check(why==DWDockReasonGesture,@"reason: a bound gesture");
    DWDockGuardGesture(&r,0,3.6);DWDockGuardDecide(&r,DWDockControlBegan,3.7,&why);check(why==DWDockReasonTail,@"reason: tail");
    puts("multitouch: contact decoding, adapter, recogniser events and the Dock-control decision passed on synthetic input; no MultitouchSupport, tap, device or trackpad was involved");
}return 0;}
