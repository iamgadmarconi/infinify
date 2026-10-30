// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
// Holds the system's own three- and four-finger gestures back while the fingers on the
// pad are ones the loaded [gestures] tables bind, and for no other count. macOS reads
// the same fingers as Mission Control, Spaces, App Exposé or Launchpad and drives the
// Dock with Dock-control events (CGS event type 30); a session tap that drops them
// while those fingers are down keeps the swipe the canvas's own. Changes no setting.
//
// The decision is a plain function of a small state (DWDockGuardState), so it needs
// neither a tap nor a trackpad to be read: DWDockGuard is that state behind a lock, fed
// by three threads (the touch source's, the main thread and the tap's), and DWDockTap
// is the tap on its own thread, which asks it per event. Nothing here drops anything
// unless a touch source says it is delivering (`live`), and a count with no binding is
// never held back.
//
// A Dock-control stream is one gesture of the system's (a Show Desktop spread, a Mission
// Control swipe): the Dock must see all of it or none. The finger count is read for the
// first packet of a stream, or for a packet that follows a pause, and the rest of the
// stream follows that verdict however the count changes meanwhile: fingers lift one by
// one, and a hand that began as a bound four-finger pinch must not hand the Dock the
// middle and the end of a gesture whose beginning was dropped (or take the end of one
// the Dock was given the beginning of).
#import "DWDockControl.h"
typedef struct {
    uint32_t bound;    // bit n is set when a [gestures] binding takes n fingers
    uint32_t fingers;  // fingers on the pad now, as the touch source counts them
    uint32_t gesture;  // fingers of the recogniser's gesture in progress, 0 for none
    uint32_t contact;  // which touch the fingers belong to: counts up each time the pad goes from empty to touched
    BOOL live;         // a touch source is delivering frames
    BOOL refused;      // the shell declined this contact (a button was down, no canvas under the pointer): the system keeps it
    NSTimeInterval until; // Sunlight's dropDockControlUntil: Dock control is dropped until then; it moves on with every report of a bound touch, and the tail starts at the lift
    BOOL boundTouch;   // Sunlight's fourFingerTouch: from a bound count landing until the last finger lifts, however the count moves meanwhile (not once it has grown past every bound count)
    BOOL runOpen,runDrop; // a Dock-control stream is in progress, and its beginning was dropped (runDrop) or given to the system
    NSTimeInterval runAt; // when the stream's last packet came
} DWDockGuardState;
// How long after the fingers lift, or the gesture ends, Dock control is still dropped:
// the system's swipe ends a beat later.
extern const NSTimeInterval DWDockTail;
// Why a decision came out as it did: logged under INFINIFY_DEBUG and asserted by the regression.
typedef NS_ENUM(NSInteger,DWDockReason){
    DWDockReasonNotLive,    // no touch source delivers: nothing is held back
    DWDockReasonUnbound,    // the fingers on the pad (none, or a count no [gestures] binding takes) are the system's
    DWDockReasonRefused,    // the shell declined this touch: the system keeps it
    DWDockReasonFingers,    // the fingers on the pad are a bound count
    DWDockReasonGesture,    // the recogniser's gesture in progress is a bound count
    DWDockReasonTail,       // the fingers lifted, or the gesture ended, a beat ago
    DWDockReasonRunDropped, // the stream this packet belongs to began dropped
    DWDockReasonRunPassed,  // the stream this packet belongs to began with the system
};
const char *DWDockReasonName(DWDockReason reason);
// Whether fingers or a gesture of a bound count are there, ignoring the tail.
BOOL DWDockGuardHolds(const DWDockGuardState *state);
// The decision for a Dock-control event at `now`, taken on its own and ignoring streams: held, or inside the tail, and live.
BOOL DWDockGuardDrops(const DWDockGuardState *state,NSTimeInterval now);
// The same with its reason.
DWDockReason DWDockGuardReason(const DWDockGuardState *state,NSTimeInterval now,BOOL *drop);
// The decision for one packet of `kind` and what the state must remember of it: a beginning, and a packet after a pause (a
// second, or the tail for a packet that is not a DockSwipe and so has no beginning), takes the count's decision; the rest of the
// stream takes the beginning's. The end of a stream closes it.
BOOL DWDockGuardDecide(DWDockGuardState *state,DWDockControlKind kind,NSTimeInterval now,DWDockReason *reason);
// The pad now has `fingers` fingers on it. The tail starts when the last one lifts after
// bound ones; a change to a count with no binding starts none, and holds nothing back.
void DWDockGuardFingers(DWDockGuardState *state,NSUInteger fingers,NSTimeInterval now);
// The recogniser's gesture of `fingers` fingers began, or (0) ended: the tail starts at its end.
void DWDockGuardGesture(DWDockGuardState *state,NSUInteger fingers,NSTimeInterval now);
// The shell declined touch number `contact`; a later touch is not covered by it.
void DWDockGuardRefuse(DWDockGuardState *state,uint32_t contact);
void DWDockGuardBound(DWDockGuardState *state,uint32_t mask);
// A touch source starts or stops delivering. Stopping forgets the fingers and the tail.
void DWDockGuardLive(DWDockGuardState *state,BOOL live);

// The state behind a lock. Any thread; every call is a few instructions.
@interface DWDockGuard : NSObject
- (void)setBound:(uint32_t)mask;
// The decision for a Dock-control packet seen by tap `via` ("dock-tap", "global-tap"), with its trace line. Undecided when no
// touch source delivers, which leaves the tap to its own rules. A packet the other tap decided a moment ago is not decided twice.
- (DWDockControlVerdict)decide:(CGEventRef)event via:(const char *)via at:(NSTimeInterval)now;
// Reports from the touch source so far: how many frames told the guard a finger count, for the log.
@property (readonly) NSUInteger reports;
- (void)setLive:(BOOL)live;
// Returns the number of the touch the fingers belong to.
- (uint32_t)fingers:(NSUInteger)fingers at:(NSTimeInterval)now;
- (void)gesture:(NSUInteger)fingers at:(NSTimeInterval)now;
- (void)refuseContact:(uint32_t)contact;
- (BOOL)dropsAt:(NSTimeInterval)now;
- (DWDockGuardState)state;
@end

// A session event tap on a thread of its own, so that a busy main thread never makes the
// system disable it and let a Dock-control event through. It sees nothing but event type
// 30 and drops what the guard says to. It needs Accessibility, which normal runs already
// need; without it, one line goes to stderr and nothing is dropped. Main thread.
@interface DWDockTap : NSObject
- (instancetype)initWithGuard:(DWDockGuard *)guard;
@property (readonly) BOOL running;
// YES when the tap is installed. Idempotent, and quiet after the first refusal.
- (BOOL)start;
- (void)stop;
// The tap's callback: the event to pass on, or NULL to drop it. Any thread.
- (CGEventRef)filter:(CGEventType)type event:(CGEventRef)event at:(NSTimeInterval)now;
@end
