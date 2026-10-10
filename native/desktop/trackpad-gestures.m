// SPDX-License-Identifier: GPL-3.0-or-later
// DriftWM (malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d) is handed
// ready-made swipe, pinch and hold gestures by libinput; its src/input/gestures/
// {swipe,pinch,hold}.rs dispatch them. macOS hands a view raw touches, so this file
// stands where libinput stands. Taken from upstream itself: DOUBLE_TAP_WINDOW_MS
// (src/input/gestures.rs) and the three-finger tap that src/input/pointer.rs buffers
// as a pending middle click and src/input/gestures/swipe.rs turns into a
// doubletap-swipe. macOS has no tap-to-click middle button, so the tap is found here.
//
// The rules follow libinput's documented gesture semantics (its user guide's
// gestures page) as far as raw touches allow; each says which. How a swipe is told
// from a pinch, and every number, are this file's choices, made from memory of how
// libinput's touchpad code decides and of where its defaults sit. None was checked
// against libinput's source, and none was tuned on a trackpad.
//
// Units. A touch is in millimetres from the pad's top left, y towards the user.
//   Swipe and pinch deltas go out in the units libinput reports, pointer pixels:
//   unitsPerMM = 10.5 for each millimetre of finger travel, about what a touchpad at
//   libinput's default speed reports under an ordinary finger. libinput's deltas are
//   pointer-accelerated (fewer under a slow finger, more in a flick); here the factor
//   is constant. Upstream's [gestures] swipe_threshold of 12 is therefore a little
//   over a millimetre of travel after the swipe is recognised.
// Finger count. libinput: a gesture never changes its finger count; when the count
//   changes, the gesture ends and another may begin.
//   Until a gesture has begun the count is simply the fingers down: each landing or
//   lift restarts recognition, and motion is not read for settleTime = 50 ms after it,
//   so fingers that reach the pad a few milliseconds apart are counted together
//   before any of them can begin a gesture. That wait is this file's, not libinput's.
//   Once a gesture has begun, a different count must last switchTime = 100 ms, during
//   which nothing is reported; then the gesture ends cancelled and recognition starts
//   over with the new count. A count that comes back within that time changes nothing.
//   All fingers lifting ends the gesture at once, not cancelled.
// Hold. libinput: fingers placed without significant movement; it begins after an
//   implementation-defined delay, is cancelled when it turns into another
//   interaction, and may begin again once motion stops.
//   Once no finger has moved more than holdMove = 1 mm for holdTime = 180 ms and no
//   swipe or pinch is recognised, hold begins. A finger then moving more than
//   holdMove from where it rested ends the hold cancelled, before any swipe or pinch
//   begins, and a later rest begins a new one. Lifting ends it, not cancelled, which
//   is when upstream fires a hold binding. A hold has no update.
// Swipe or pinch. libinput: a swipe is fingers moving together in one direction, a
//   pinch is fingers changing their distance or their angle to each other.
//   Read from two touches, the one farthest from the user and the one nearest (the
//   thumb, when there is one), by how far each has moved since recognition started:
//   - both under undecided = 1 mm: nothing yet.
//   - the two within rowWidth = 40 mm and rowHeight = 7 mm of each other, so side by
//     side with no thumb below, and rowTime = 150 ms since recognition started: swipe.
//   - the near one moved 4 mm + 2 mm per finger beyond two while the far one moved
//     under 1.5 mm + 0.5 mm per finger beyond two: pinch (a thumb closing on resting fingers).
//   - either under 1.5 mm + 0.5 mm per finger beyond two: nothing yet.
//   - both further: swipe when they moved the same way (under 90 degrees apart), else pinch.
//   The choice is locked until the gesture ends.
//   Two misreads follow from these rules, and stay. Fingers closing on a touch that
//   does not move are not a pinch: nothing is recognised while they move, and once
//   they stop the touches are a hold. The same touches are two fingers scrolling
//   above a thumb at rest, which a pinch here would zoom; libinput, as remembered,
//   also takes the still touch for a resting thumb. And three fingers in a row that
//   slid more than undecided as they landed and then lay still are a swipe at the
//   first frame after rowTime, not the hold they would have become: travel counts
//   from where recognition started, not from where the fingers came to rest.
// Swipe. libinput: the delta is the movement of the fingers' logical centre.
//   dx, dy are the mean movement of every finger down since the previous frame.
//   Begin goes out with the first movement after recognition.
// Pinch. libinput: the scale is absolute, a multiple of the fingers' distance at the
//   start; the angle and the centre's movement are relative to the previous event.
//   scale is the distance between the two touches over their distance when the pinch
//   was recognised. rotation is the change of the angle between them since the
//   previous update, in degrees, clockwise positive. dx, dy are the movement of their
//   midpoint. Begin goes out with the first change.
// Tap. libinput reports a tap as a button, never as a hold or a swipe.
//   Three fingers that land and lift with no step slower than tapTime = 180 ms, none
//   moving more than tapMove = 1.3 mm and no gesture begun, are a three-finger tap.
//   Nothing is emitted for it. A swipe that begins within doubletapTime = 300 ms of
//   the last finger lifting (upstream's DOUBLE_TAP_WINDOW_MS) carries
//   "doubletap": true, and any swipe beginning uses the tap up, as upstream takes
//   its pending click.
// Cancel. libinput: a gesture is cancelled, not ended, when it stops being that
//   gesture; a thumb or palm it stops counting is a finger removed.
//   A touch the system cancels, or one a frame no longer reports, ends the gesture
//   cancelled; so does -cancel:. The fingers still down start over.
#import "trackpad-gestures.h"
#include <math.h>

static const double unitsPerMM=10.5,undecided=1,rowWidth=40,rowHeight=7,holdMove=1,tapMove=1.3;
static const NSTimeInterval settleTime=.05,switchTime=.1,holdTime=.18,rowTime=.15,tapTime=.18,doubletapTime=.3;

NSNumber *DWGestureTime(NSTimeInterval seconds) { return @(floor(MAX(0,seconds)*1000)); }

// x, y now; px, py at the previous frame; ix, iy when recognition started; hx, hy where it rests; lx, ly where it landed.
@interface DWTouchPoint : NSObject { @public double x,y,px,py,ix,iy,hx,hy,lx,ly;BOOL seen; }
@end
@implementation DWTouchPoint
@end
typedef NS_ENUM(NSInteger,DWGesturePhase){DWGestureNone,DWGestureUnknown,DWGestureHold,DWGestureSwipe,DWGesturePinch};

@implementation DWTrackpadGestures {
    void (^_emit)(NSDictionary *);
    NSMutableDictionary<id<NSCopying>,DWTouchPoint *> *_touches;
    DWTouchPoint *_far,*_near; // the two touches motion is read from
    DWGesturePhase _phase;
    NSUInteger _fingers,_pending; // the count recognition runs on, and a different one waiting out switchTime
    BOOL _begun,_framing,_lost,_changed; // begin emitted; inside a frame; a touch went without an end; a landing or lift this frame
    NSTimeInterval _since,_hold,_switch; // recognition start; hold and count-switch deadlines, 0 for none
    double _distance,_angle,_scale,_cx,_cy; // pinch: distance at recognition, then the last angle, scale and midpoint
    NSUInteger _most;BOOL _tapping;NSTimeInterval _step,_tapped; // most fingers of this contact; still a tap; last landing or lift; when a three-finger tap ended
}
- (instancetype)initWithEmit:(void (^)(NSDictionary *))emit { if((self=[super init])){_emit=[emit copy];_touches=[NSMutableDictionary dictionary];}return self; }
- (BOOL)engaged { return _begun&&_phase!=DWGestureHold; }
- (NSTimeInterval)deadline { NSTimeInterval hold=_phase==DWGestureUnknown&&!_pending?_hold:0;return _switch&&(!hold||_switch<hold)?_switch:hold; }
- (void)begin:(NSString *)kind at:(NSTimeInterval)time {
    NSMutableDictionary *event=[@{@"op":@"gesture_begin",@"kind":kind,@"fingers":@(_fingers),@"time_ms":DWGestureTime(time)}mutableCopy];
    if([kind isEqual:@"swipe"]&&_tapped){if(time-_tapped<=doubletapTime)event[@"doubletap"]=@YES;_tapped=0;}
    _begun=YES;_tapping=NO;_emit(event);
}
- (void)finish:(BOOL)cancelled at:(NSTimeInterval)time { if(_begun){_begun=NO;_emit(@{@"op":@"gesture_end",@"cancelled":cancelled?@YES:@NO,@"time_ms":DWGestureTime(time)});} }
- (void)reset:(BOOL)cancelled at:(NSTimeInterval)time { [self finish:cancelled at:time];_phase=DWGestureNone;_hold=0;_far=_near=nil; }
// Recognition starts from where the fingers are now.
- (void)pair:(NSTimeInterval)time {
    _far=_near=nil;_since=time;
    for(DWTouchPoint *touch in _touches.objectEnumerator){touch->ix=touch->x;touch->iy=touch->y;if(!_far||touch->y<_far->y)_far=touch;}
    for(DWTouchPoint *touch in _touches.objectEnumerator)if(touch!=_far&&(!_near||touch->y>=_near->y))_near=touch;
}
// The hold delay runs from where the fingers are now.
- (void)rest:(NSTimeInterval)time { _hold=time+holdTime;for(DWTouchPoint *touch in _touches.objectEnumerator){touch->hx=touch->x;touch->hy=touch->y;} }
- (BOOL)resting { for(DWTouchPoint *touch in _touches.objectEnumerator)if(hypot(touch->x-touch->hx,touch->y-touch->hy)>holdMove)return NO;return YES; }
- (BOOL)paired { NSArray *down=_touches.allValues;return _far&&_near&&[down indexOfObjectIdenticalTo:_far]!=NSNotFound&&[down indexOfObjectIdenticalTo:_near]!=NSNotFound; }
// Whether the two touches have moved together or against each other, once that can be told.
- (DWGesturePhase)motion:(NSTimeInterval)time {
    if(time<_since+settleTime||!_far||!_near)return DWGestureNone;
    double fx=_far->x-_far->ix,fy=_far->y-_far->iy,nx=_near->x-_near->ix,ny=_near->y-_near->iy,far=hypot(fx,fy),near=hypot(nx,ny);
    double least=1.5+.5*(_fingers-2),most=4+2.0*(_fingers-2);
    if(far<undecided&&near<undecided)return DWGestureNone;
    if(fabs(_far->x-_near->x)<rowWidth&&fabs(_far->y-_near->y)<rowHeight&&time>_since+rowTime)return DWGestureSwipe;
    if(near>=most&&far<least)return DWGesturePinch;
    if(far<least||near<least)return DWGestureNone;
    return fx*nx+fy*ny>0?DWGestureSwipe:DWGesturePinch;
}
// One step for the fingers now down: start recognition, read their motion, report the gesture it settled on.
- (void)recognise:(NSTimeInterval)time {
    if(_fingers<3||_pending)return;
    if(_phase==DWGestureNone){[self pair:time];[self rest:time];_phase=DWGestureUnknown;return;}
    // A hold that starts to move ends cancelled, whether or not the motion becomes a swipe or a pinch.
    if(_phase==DWGestureHold&&![self resting]){[self finish:YES at:time];[self rest:time];_phase=DWGestureUnknown;}
    if(_phase==DWGestureUnknown||_phase==DWGestureHold){
        DWGesturePhase motion=[self motion:time];if(motion==DWGestureNone)return;
        [self finish:YES at:time];_hold=0;_phase=motion;
        if(motion==DWGesturePinch){_distance=hypot(_near->x-_far->x,_near->y-_far->y);_angle=atan2(_near->y-_far->y,_near->x-_far->x)*180/M_PI;_scale=1;_cx=(_far->x+_near->x)/2;_cy=(_far->y+_near->y)/2;}
    }
    if(_phase==DWGestureSwipe){
        double dx=0,dy=0;for(DWTouchPoint *touch in _touches.objectEnumerator){dx+=touch->x-touch->px;dy+=touch->y-touch->py;}
        dx*=unitsPerMM/_touches.count;dy*=unitsPerMM/_touches.count;if(!dx&&!dy)return;
        if(!_begun)[self begin:@"swipe" at:time];
        _emit(@{@"op":@"gesture_update",@"dx":@(dx),@"dy":@(dy),@"time_ms":DWGestureTime(time)});
    }else if(_phase==DWGesturePinch){
        double distance=hypot(_near->x-_far->x,_near->y-_far->y),angle=atan2(_near->y-_far->y,_near->x-_far->x)*180/M_PI,cx=(_far->x+_near->x)/2,cy=(_far->y+_near->y)/2;
        if(_distance<=0||distance<=0)return;
        double scale=distance/_distance,turn=angle-_angle,dx=(cx-_cx)*unitsPerMM,dy=(cy-_cy)*unitsPerMM;
        if(turn>180)turn-=360;else if(turn<-180)turn+=360;
        if(scale==_scale&&!turn&&!dx&&!dy)return;
        _scale=scale;_angle=angle;_cx=cx;_cy=cy;
        if(!_begun)[self begin:@"pinch" at:time];
        _emit(@{@"op":@"gesture_update",@"dx":@(dx),@"dy":@(dy),@"scale":@(scale),@"rotation":@(turn),@"time_ms":DWGestureTime(time)});
    }
}
- (void)advance:(NSTimeInterval)time {
    if(_switch&&time>=_switch){NSTimeInterval at=_switch;_switch=0;[self reset:YES at:at];_fingers=_pending;_pending=0;[self recognise:at];}
    while(_hold&&_phase==DWGestureUnknown&&!_pending&&time>=_hold){
        NSTimeInterval at=_hold;
        // Fingers that moved in the meantime have not rested yet. Motion out of a hold is read from where it rests.
        if([self resting]){_hold=0;_phase=DWGestureHold;[self pair:at];[self begin:@"hold" at:at];}else [self rest:at];
    }
}
- (void)touch:(id<NSCopying>)identity x:(double)x y:(double)y phase:(DWTouchPhase)phase time:(NSTimeInterval)time {
    // Deadlines that passed before this frame are met before it is read.
    if(!_framing){_framing=YES;[self advance:time];}
    DWTouchPoint *touch=_touches[identity];
    if(phase==DWTouchEnded||phase==DWTouchCancelled){if(touch){[_touches removeObjectForKey:identity];_changed=YES;if(phase==DWTouchCancelled)_lost=YES;}return;}
    // A finger first seen moving landed where no frame reported it.
    if(!touch){
        if(!_touches.count){_tapping=YES;_most=0;_step=time;}
        touch=[DWTouchPoint new];touch->x=touch->px=touch->ix=touch->hx=touch->lx=x;touch->y=touch->py=touch->iy=touch->hy=touch->ly=y;_touches[identity]=touch;_changed=YES;
    }
    touch->x=x;touch->y=y;touch->seen=YES;
    if(hypot(x-touch->lx,y-touch->ly)>tapMove)_tapping=NO;
}
- (void)frame:(NSTimeInterval)time {
    if(!_framing)[self advance:time];
    _framing=NO;
    for(id<NSCopying> identity in _touches.allKeys){DWTouchPoint *touch=_touches[identity];if(touch->seen)touch->seen=NO;else {[_touches removeObjectForKey:identity];_lost=_changed=YES;}}
    if(_changed){if(time-_step>tapTime)_tapping=NO;_step=time;}
    NSUInteger down=_touches.count;if(down>_most)_most=down;
    if(_lost){[self reset:YES at:time];_pending=0;_switch=0;_tapping=NO;}
    if(down!=_fingers){
        // All fingers up ends the gesture at once; before a gesture has begun the new count simply takes over.
        if(!down||!_begun){[self reset:NO at:time];_fingers=down;_pending=0;_switch=0;}
        else if(down!=_pending){_pending=down;_switch=time+switchTime;}
        if(!down){if(_tapping&&_most==3)_tapped=time;_tapping=NO;}
    }else{
        _pending=0;_switch=0;
        // The count came back, but with another finger in place of one the gesture was read from.
        if(_phase!=DWGestureNone&&_phase!=DWGestureSwipe&&![self paired]){if(_phase==DWGesturePinch)[self reset:YES at:time];else [self pair:time];}
    }
    [self recognise:time];
    for(DWTouchPoint *touch in _touches.objectEnumerator){touch->px=touch->x;touch->py=touch->y;}
    _lost=_changed=NO;
}
- (void)cancel:(NSTimeInterval)time { [self reset:YES at:time];[_touches removeAllObjects];_fingers=_pending=_most=0;_switch=_tapped=0;_framing=_lost=_changed=_tapping=NO; }
@end
