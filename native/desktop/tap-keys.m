// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from DriftWM, repository https://github.com/malbiruk/driftwm, commit 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/keyboard.rs (TapTracker: update, taint, reset; is_modifier_keysym; and
// on_keyboard, where the tracker only observes and the chord it completes is looked
// up in the tap bindings) and src/input/mod.rs (process_input_event: a pointer
// button, an axis event or a gesture that begins on top of a held chord taints it,
// pointer motion does not). The tracker's rules are upstream's. Upstream is handed
// every key event; how this one learns of a key or a button on top is new (tap-keys.h).
#import "tap-keys.h"
#import "typed-value.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

static const NSEventModifierFlags chordFlags=NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagShift|NSEventModifierFlagCommand;
// What upstream's tracker is told by a key press or a pointer button event (either state) on top of the chord. A key let go under the chord with no
// press under it was down before the chord began: upstream's tracker is tainted by that earlier press, and the release is all that is left to count.
// A volume, brightness or media key, an ordinary key to upstream, is no key event on a Mac: it arrives system-defined (IOLLEvent.h: NX_SYSDEFINED, an
// aux control button), and so does a copy of every mouse button change.
// Never flagsChanged, which every modifier moves, and no scroll: macOS goes on sending its own momentum after the fingers have left.
static const CGEventType counted[]={kCGEventKeyDown,kCGEventKeyUp,(CGEventType)NSEventTypeSystemDefined,kCGEventLeftMouseDown,kCGEventLeftMouseUp,kCGEventRightMouseDown,kCGEventRightMouseUp,kCGEventOtherMouseDown,kCGEventOtherMouseUp};
typedef struct { uint32_t events[sizeof(counted)/sizeof(*counted)]; } DWTapCounters;
static DWTapCounters counters(void) {
    DWTapCounters now;for(size_t i=0;i<sizeof(counted)/sizeof(*counted);i++)now.events[i]=CGEventSourceCounterForEventType(kCGEventSourceStateCombinedSessionState,counted[i]);
    return now;
}
// The tracker is handed a change after it happened, and a key or a button pressed and let go in between (the main thread was busy) is in its first reading
// of the counters already. The session also keeps how long ago it last saw each kind; `then` is an NSEvent's timestamp, on the clock of systemUptime.
static BOOL seenSince(NSTimeInterval then) {
    NSTimeInterval ago=NSProcessInfo.processInfo.systemUptime-then;
    for(size_t i=0;i<sizeof(counted)/sizeof(*counted);i++)if(CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState,counted[i])<ago)return YES;
    return NO;
}
@implementation DWTapKeys {
    void (^_fire)(NSDictionary *);
    NSDictionary<NSNumber *,NSDictionary *> *_taps; // physical chord (NSEventModifierFlags) to its entry
    id _global,_local;
    NSEventModifierFlags _held; // the modifiers down at the last change seen
    NSEventModifierFlags _peak; // TapTracker.peak
    BOOL _tainted;              // TapTracker.tainted
    DWTapCounters _began;       // the counters when the chord began
    BOOL _trusted;
}
- (instancetype)initWithFire:(void (^)(NSDictionary *))fire { if((self=[super init])){_fire=[fire copy];_taps=@{};}return self; }
- (void)setBindings:(NSDictionary *)bindings {
    [self stop];NSMutableDictionary<NSNumber *,NSDictionary *> *taps=[NSMutableDictionary dictionary];
    for(id entry in DWTyped(DWTyped(bindings,NSDictionary.class)[@"taps"],NSArray.class)){
        NSDictionary *tap=DWTyped(entry,NSDictionary.class);NSDictionary<NSString *,NSNumber *> *held=DWTyped(tap[@"modifiers"],NSDictionary.class);
        // A chord whose action cannot run here is not watched for.
        if(!held||!DWTyped(tap[@"action"],NSString.class)||[DWTyped(tap[@"implemented"],NSNumber.class)isEqual:@NO])continue;
        NSEventModifierFlags chord=([DWTyped(held[@"control"],NSNumber.class)boolValue]?NSEventModifierFlagControl:0)|([DWTyped(held[@"option"],NSNumber.class)boolValue]?NSEventModifierFlagOption:0)|([DWTyped(held[@"shift"],NSNumber.class)boolValue]?NSEventModifierFlagShift:0)|([DWTyped(held[@"command"],NSNumber.class)boolValue]?NSEventModifierFlagCommand:0);
        if(chord&&!taps[@(chord)])taps[@(chord)]=tap;
    }
    _taps=taps;
}
- (void)start {
    if(_global||_local||!_taps.count)return;
    // A chord already held began unseen and is no tap: it never completes, and the next one begins once every modifier is up.
    _held=NSEvent.modifierFlags&chordFlags;_peak=_held;_tainted=_held!=0;_trusted=AXIsProcessTrusted();
    __weak DWTapKeys *weak=self;
    _global=[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^(NSEvent *event){[weak changed:event];}];
    _local=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event){[weak changed:event];return event;}];
}
// One flagsChanged, as TapTracker::update takes one key event of a modifier: `now` is upstream's `mods`, the state after the event.
- (void)changed:(NSEvent *)event {
    NSEventModifierFlags now=event.modifierFlags&chordFlags,pressed=now&~_held,released=_held&~now;_held=now;
    // No single key adds one modifier and removes another: events were missed, and what was held in between is unknown.
    if(pressed&&released){_peak=now;_tainted=YES;return;}
    // Pressed: the peak only grows. The counters are read as the chord begins, and what the session saw after the modifier went down is on top of it already.
    if(pressed){if(!_peak){_began=counters();if(seenSince(event.timestamp))_tainted=YES;}_peak|=now;return;}
    // The same modifiers as before: Caps Lock, an ordinary key here as in upstream's is_modifier_keysym, or Fn, or the second key of a modifier already held.
    if(!released){if(event.keyCode==kVK_CapsLock)[self taint];return;}
    // Released: the release that finishes an untainted chord completes it, bound or not, and the chord then stays spent until every modifier is up.
    NSDictionary *tap=nil;
    if(!_tainted&&_peak){DWTapCounters at=counters();if(!memcmp(&at,&_began,sizeof(at)))tap=_taps[@(_peak)];_tainted=YES;}
    if(!now){_peak=0;_tainted=NO;}
    // Last: the action may stop or restart this object.
    if(tap)_fire(tap);
}
- (void)taint { if(_peak)_tainted=YES; }
- (void)trusted:(BOOL)trusted {
    BOOL gained=trusted&&!_trusted;_trusted=trusted;
    if(gained&&(_global||_local)){[self stop];[self start];}
}
- (void)stop {
    if(_global){[NSEvent removeMonitor:_global];_global=nil;}
    if(_local){[NSEvent removeMonitor:_local];_local=nil;}
    _held=0;_peak=0;_tainted=NO;
}
- (void)dealloc { [self stop]; }
@end
