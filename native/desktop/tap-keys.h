// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// DriftWM's tap bindings: a [keybindings] entry that is a bare modifier chord
// ("alt+shift" = "switch-layout next") fires when the chord is pressed and let go
// with nothing else pressed on top. The "taps" of the controller's
// {"op":"bindings"} reply are the chords, as physical modifiers. Main thread only.
//
// The tracker is upstream's TapTracker: the peak is every modifier held since the
// chord began; anything else that lands on top taints it; the first release of an
// untainted chord completes it, bound or not; nothing completes again until every
// modifier is up.
//
// Upstream is handed every key and button event. Here:
// - Modifiers are observed, never intercepted: flagsChanged through one NSEvent
//   global monitor (another application is active) and one local monitor (this one
//   is). Control, Option, Shift and Command are the modifiers. Caps Lock is an
//   ordinary key, as upstream's lock keys are, and taints. Fn is no key at all.
// - A key or a mouse button on top is not listened for. The login session's event
//   counters (CGEventSourceCounterForEventType: key down and up, each mouse button
//   down and up, and the system-defined events that IOLLEvent.h gives a volume,
//   brightness or media key; none was pressed in this project to see it) are read
//   when the chord begins and again at its release, and a counter that moved
//   taints. Reading them needs no permission and observes no event.
// - The tracker hears of a change after it happened, later still when the main
//   thread is busy, and a key pressed and let go in between is in the first reading
//   already. So the session is also asked how long ago it last saw each counted
//   kind (CGEventSourceSecondsSinceLastEventType): one seen since the timestamp of
//   the change that begins the chord taints it. That timestamp and systemUptime
//   are taken for one clock, as Apple documents them and no real event has shown
//   here: were one to read older than it is, its chord would never complete.
// - Input the counters do not count or cannot tell apart is the shell's to report
//   with -taint: see there.
//
// Permission. Apple documents that a global monitor is sent key-related events only
// while the process is trusted for Accessibility, and names no exception for
// flagsChanged. What an untrusted process is sent was not observed in this project.
// Without those events a tap fires only while this application is itself active
// (the local monitor); nothing is said and nothing else is affected. The counters
// and the local monitor need no grant.
//
// Differences from upstream:
// - Two keys of one modifier (both Shifts) read as one: such a chord completes when
//   the last of them is let go, upstream's when the first is.
// - A key that was already down when the chord began taints it by being let go
//   under it, as it nearly always does upstream (which forgets such a key only if
//   something else was let go, with no modifier down, since it went down). Held
//   throughout, it is not seen, and the chord completes where upstream's first
//   chord over a held key does not.
// - The release is heard of late as well, and a key or a button that lands after
//   it, before the tracker is told, taints a chord upstream would have completed.
// - Whatever else macOS sends as a system-defined event taints as a media key
//   does. Sticky Keys and Slow Keys announce a key with one (IOLLEvent.h): with
//   either on, no chord is expected to complete. Not observed.
// - A chord that was already held when watching began (-start), or across a change
//   that both adds and removes a modifier (events were missed: secure input, the
//   lock screen), never completes. Upstream forgets such a chord (reset) and lets
//   the modifiers still held begin a new one.
@interface DWTapKeys : NSObject
// fire receives the entry of "taps" whose chord was just completed.
- (instancetype)initWithFire:(void (^)(NSDictionary *tap))fire;
// Stops, then takes the reply's "taps": [{"combo":…,"modifiers":{"control":BOOL,
// "option":BOOL,"shift":BOOL,"command":BOOL},"action":…,"implemented":BOOL}]. An
// entry marked "implemented": false is left out, as a key is, and so is any entry
// after the first on one chord.
- (void)setBindings:(NSDictionary *)bindings;
// Watches the modifiers until -stop. Nothing is installed while no tap is bound.
// No-op while started.
- (void)start;
// Something that is no modifier landed on top of a held chord, which is then no
// tap: upstream's TapTracker::taint. For what the shell knows and the counters do
// not count or cannot tell apart: a hot key that fired, a scroll that is not
// macOS's own momentum, a trackpad gesture that began.
- (void)taint;
// The shell's reading of AXIsProcessTrusted(), whenever it takes one. Monitors
// installed before trust was granted are installed again once it is.
- (void)trusted:(BOOL)trusted;
// Removes both monitors and forgets the chord. Required before release.
- (void)stop;
@end
