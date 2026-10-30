# Input module

How trackpad gestures reach the canvas: the touch recogniser, the MultitouchSupport source and the Dock-control guard (code in `native/app/Input`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Trackpad gestures

Normal runs only. DriftWM is handed swipe, pinch and hold gestures by libinput and binds
them in the `[gestures]` tables. macOS has no such stream, so the shell makes
one and the controller dispatches it exactly as upstream dispatches libinput's:
[GESTURES.md](../../../crates/desktop/GESTURES.md) has the three commands
(`gesture_begin`, `gesture_update`, `gesture_end`), the dispatch and the default
table as it runs on a Mac. What a gesture then moves is
[Camera motion](../Navigation/README.md#camera-motion)'s, the same as for the pointer: a swipe that
pans is the timed pan of a two-finger scroll and drifts on the same momentum, a
pinch that zooms is scaled, limited and snapped by the controller, and a swipe
that moves a window is the drag of a bound button press, edge pan included.

| Fingers | Where the stream comes from |
| --- | --- |
| 3 or more | raw trackpad touches, recognised by `DWTrackpadGestures.m`: in desktop mode from MultitouchSupport wherever the pointer is, otherwise from the touches AppKit hands the canvas view under the pointer |
| 2, pinching | AppKit's magnify events, sent as a `pinch` of 2 fingers: its scale is the running product of each event's `1 + magnification`, with no rotation and no delta |
| 2, scrolling | not a gesture: the `trackpad-scroll` mouse binding above |

Every canvas view accepts indirect touches and hands each event's touches to one
recogniser, `DWTrackpadGestures`, a state machine with no AppKit in it, fed
`(identity, x, y, phase, time)` in millimetres and emitting the begin, update
and end events. Those AppKit touches arrive only while the pointer is over a
canvas view of the key window, and in desktop mode only through the session tap
(`DWGlobalTrackpadInput`); the MultitouchSupport source described below, under
"Touches from anywhere", does not depend on where the pointer is, and feeds the
same recogniser the same calls. Its rules and every constant are written out at the
top of `DWTrackpadGestures.m` beside the libinput behaviour each imitates. In
short:

- The finger count is fixed once a gesture has begun. Before that each landing
  or lift restarts recognition, and motion is not read for 50 ms after it. After
  it, a different count must last 100 ms, then the gesture ends cancelled and
  recognition starts over; all fingers lifting ends it at once, not cancelled.
- Fingers that move the same way are a swipe: `dx`, `dy` are the mean movement
  of all fingers, 10.5 units for each millimetre of travel, a constant standing
  in for libinput's accelerated pointer units. Upstream's `swipe_threshold` of
  12 is therefore a little over a millimetre.
- Fingers that close, open or turn against each other are a pinch: `scale` is
  the distance between the farthest and the nearest touch over what it was when
  the pinch was recognised, `rotation` the change of their angle in degrees.  Every finger counts toward that, not only the two touches
  `scale` is read from: when the fingers' mean distance from their own centre has
  grown or shrunk by 4 mm and by more than half of what the centre travelled, the
  touch is a pinch even if the farthest and the nearest finger drift the same way.
  A thumb and three fingers that spread while the hand slides (the shape of
  macOS's Show Desktop and Launchpad gestures, which are bound here as the
  four-finger pinches) are a pinch, not a four-finger swipe, even when the two touches'
  directions agree. In a sweep of synthetic hands (thumb-to-fingers
  separation 10, 20, 30 and 40 mm, hand drift 0 to 24 mm in steps of 4, 156 x 96 mm
  pad) the largest drift a spread could carry and still be a pinch was 4, 12,
  16 and 24 mm of drift; swipes of 3 to 12 mm and a 20 mm
  swipe with fingers fanning by up to 6 mm stayed swipes (a throwaway program,
  not kept; the regression keeps four of its hands). The rule is
  translated from Sunlight's Show Desktop reading (the header of
  `DWTrackpadGestures.m` has the lines); nobody has tried it on a hand.
- Fingers that have not moved more than 1 mm for 180 ms are a hold. Moving ends
  it cancelled; lifting ends it, which is when a hold binding fires.
- Three fingers that land and lift within 180 ms a step, without moving, are a
  tap. A swipe beginning within 300 ms of it carries `doubletap`, which is how
  upstream's `3-finger-doubletap-swipe` (move a window) is reached.
- A touch the system cancels, or one a frame no longer reports, ends the gesture
  cancelled.

Two misreads of these rules are known from scripted touch sequences and are
left in:

- Fingers closing on a thumb that stays still are not a pinch. Nothing is
  recognised while they move, and when they stop the touches become a hold. The
  same touches are two fingers scrolling above a resting thumb, which a pinch
  would zoom, so only the other half is a pinch: a thumb closing on fingers that
  stay still. Otherwise both must move.
- Three fingers side by side that slide more than a millimetre as they land and
  then lie still become a swipe at the next touch event after 150 ms, with
  almost no motion in it, and never the hold they were resting into.

`gesture_begin` carries the modifiers held, the output under the pointer and
whether a window or empty canvas is under it (a placeholder is a window), as a
press does. Each update and the end say whether a modifier is physically down
at that moment, which is what a hot key's action is told: a `cycle-windows` the
gesture fires then keeps its cycle open until the hold modifiers are let go
([Cycling and hold-to-commit](../Navigation/README.md#cycling-and-hold-to-commit)), and any other
action it fires ends one. A gesture begins only with the pointer over an
output and no button drag in progress; its begin withdraws a native focus
request still in flight and leaves a settled open cycle alone. A press on the
pad first ends an open cycle as every canvas press does, then ends the gesture
cancelled before it stops
camera motion, so a pan the press interrupts does not coast. While a swipe or
pinch of three or more fingers is running, scroll and magnify events are
dropped, in case macOS derives them from the same fingers. For the same case,
its begin ends a scroll those fingers had started: the drift that scroll was
about to launch is not launched, at its 50 ms delay or at its lift, so the
swipe's own end is the only launch. A magnify event is
sent to the controller once, as a gesture event and never as a `zoom_by` too.
The reply is an action's: a flight, a coasting camera or the edge pan under a
moved window keeps the frame timer running
(`needs_frames`), `dirty` saves the scene, a focus request (a move's, or that
of a window navigation action the gesture fired) goes to the navigation
coordinator like the request of any other reply
([What focusing does natively](../Navigation/README.md#what-focusing-does-natively)), and the status
line shows what a
threshold gesture fired (`Home`, `Zoom to fit`), the refusal of an action that
does not run here yet, and the note of a resize that is refused (a
screen-pinned window's).

**Touches from anywhere.** Desktop mode only; the windowed mode
keeps the views' touches. Implemented and compiled, **never run on a physical
trackpad**: no frame from MultitouchSupport has been received by this code on
any machine.

AppKit gives a view touches only while the pointer is over it, so three fingers
over a native window, or with another application key, reach no one that way.
The private MultitouchSupport framework, the one Mac gesture tools read, reports
every contact of every trackpad to a callback wherever the pointer is.
`DWMultitouchSource.m` loads it with `dlopen` and six `dlsym` lookups
(`MTDeviceCreateList`, `MTRegisterContactFrameCallback`,
`MTUnregisterContactFrameCallback`, `MTDeviceStart`, `MTDeviceStop`,
`MTDeviceGetSensorSurfaceDimensions`), so there is no link-time dependency, and
registers a callback on every device that can say how big its surface is. The
technique, the contact layout and the wake restart are
[Sunlight](https://github.com/spacefarm-digital/sunlight)'s (MIT, Copyright (c)
2026 spacefarm, commit `afeea74b18e70ca49bf462d6fe462cf65deb2b32`); the file's
header says which lines.

- A contact is a 96-byte record, of which four fields are read: the path index
  (offset 16, stable while the finger stays down), the state (20), x (32) and y
  (36), both 0 to 1 with y 0 at the bottom. Only the states make-touch (3) and
  touching (4) are fingers; hovering, breaking off and lingering contacts are
  not. Neither the layout nor the unit of the surface size (hundredths of a
  millimetre) has been checked against a record of a running device; the
  regression builds records with offsets written out a second time and shows
  only that the code reads what it was told to read.
- The callback decodes on the framework's thread, stamps the frame with
  `CACurrentMediaTime()` (the contact's own timestamp is not read: its clock was
  not checked), and queues it for the main thread, where frames arrive in the
  order they were made. The first device with a finger on it is followed until
  it has none, so two pads never make one fictitious gesture; a followed device
  that sends nothing for 30 s loses the claim.
- `DWMultitouchFeed` turns a frame into the recogniser's calls: millimetres are
  the position times the surface in millimetres, y flipped to run towards the
  user; the identity is the path index; a finger seen first is `Began`, after
  that `Moved`, and one that lifts while others stay is ended by name; one frame
  closes each callback, and the empty frame the last lift brings ends the
  gesture at once, uncancelled. Fingers before the third are counted and not
  passed on.
- The third finger of a fresh touch asks the same admission the session tap
  asks (a canvas under the pointer, no button down, no gesture on a view, no
  geometry transition under way); a refusal stands until every finger has
  lifted, and the system keeps that touch. Whichever of the two sources sees the
  third finger first answers for both, so the other does not end the gesture the
  first began. The presses that end gestures (see above) end this one too, and
  the rest of that touch is ignored until the fingers lift.
- **Resting and palm contacts are not told apart.** The NSTouch path leaves out
  what AppKit calls `resting`, and a contact record carries no such flag.
  `DWMultitouchSource.resting` is where a classifier would go; nothing in the
  tree sets it, since any threshold would be a guess with no trackpad to tune it
  on. So on this path a thumb resting on the pad counts as a finger, and three
  fingers with a thumb down are a four-finger gesture. The regression shows only
  that a contact the block names is left out of the frame, the recogniser and
  the Dock guard alike.
- The source takes over only once it **delivers**: from the first frame with a
  finger, and not before. Until then, and whenever the framework, a function or
  a device is missing (one line on stderr, the reason), the views' touches and
  the session tap's stay exactly as they were. Once it delivers, neither of them
  feeds the recogniser. The session tap keeps what it did besides: owning the
  touch's AppKit events once it admits the touch, and the pointer-press guards.
  `INFINIFY_NO_MULTITOUCH=1` keeps the source from starting at all.
- Devices are stopped and started again a second after wake, and the source
  stops delivering, with the gesture in progress ended cancelled, until the next
  frame. A start that finds no device is tried again every ten seconds; a
  second trackpad attached after the first was found is not noticed until the
  next wake or restart. A Magic Mouse reports through the same framework and is
  not told apart from a pad.

**macOS takes three- and four-finger touches for itself first.** Infinify
changes no system setting. The system reads the fingers the canvas reads as
Mission Control, App Exposé, a Spaces swipe or a Launchpad or Show Desktop
pinch, and drives the Dock with Dock-control events (event type 30). While the
touch source delivers, a session event tap of its own (`DWDockGuard.m`) drops
those events, and only those:

- while the fingers on the pad, counted on the framework's thread before the
  main thread has seen the frame, or the recogniser's gesture in progress, are a
  count that a `[gestures]` binding takes. The controller answers which with
  `gesture_fingers` ([GESTURES.md](../../../crates/desktop/GESTURES.md#the-finger-counts-a-run-binds)):
  the three tables as the config left them, whatever modifier a binding asks for,
  and the desktop's defaults; none while `set-trackpad` is off. The shell asks
  again after every config load and after any `set-trackpad` it sees run;
- and for 0.3 s after the last bound finger lifts or the gesture ends, since the
  system's swipe ends a beat later (Sunlight's tail).

Never for a count with no binding, and a touch that grows from a bound count to
an unbound one is handed back to the system at once, with no tail. Never when
the source is not delivering. Never for a touch the shell declined (a button
down, no canvas under the pointer, the canvas closed or the session away). The
decision is a plain function of a small state, `DWDockGuardDrops`, and the tap
runs on a thread of its own, so a busy main thread cannot make the system
disable it (a 5 s watchdog turns a tap the system disabled quietly back on).
Because a modifier is not part of the decision, a config that binds only
`alt+4-finger-swipe-up` still holds back the system's four-finger gestures
without Option.

The drop timing is Sunlight's, translated (`DWDockGuard.m`'s header maps each
function to its lines of `TrackpadPan.swift`): from the moment a bound count
lands until the last finger lifts the drop time is 0.3 s ahead of every report,
however the count moves in between, and the tail runs from the lift. Fingers lift
one by one, so the count passes through two and one on its way to none; an
earlier version of this guard decided by the count at each packet and started the
tail only when the count just before none was a bound one, which a staggered
lift never is. A stream of Dock-control packets (one gesture of the system's) is
also decided once, by its first packet, and the rest of it follows, so the Dock is
never given the middle or the end of a gesture whose beginning was dropped, nor
loses the end of one it was given the beginning of; a stream that goes a second
without a packet, or a packet of a format this code cannot decode that comes more
than 0.3 s after the last, is a new one. The packets of a Show Desktop or
Launchpad pinch may not be the DockSwipes the decoder knows (axis 1 to 3 of HID
type 23); they are then dropped or passed all the same, on the same decision.

Two taps ask the guard. `DWDockTap` is the one that exists for it. The session
tap `DWGlobalTrackpadInput` asks it too, for every Dock-control packet whatever
its format, so that a packet the first tap did not see, or was not installed to
see, is still decided (the second tap that sees a packet gets the first's answer).
Only when the guard has no live touch source (`undecided`) does the session tap
use its own rule: a DockSwipe whose beginning it saw while it owned an admitted
touch is dropped to its end, and since nothing else can be told apart, so is any
other Dock-control packet while it owns an admitted touch of three or more
fingers and for 0.3 s after. Neither session tap converts a type-30 packet to an `NSEvent`: AppKit's
"unrecognized type is 30" lines came from doing so, and `DWNativeInputTests.m`
counts the conversions.

The tap needs Accessibility, which a normal run already needs. Without it, one
line goes to stderr, nothing is dropped, and the system's gestures stay on;
it is tried again whenever the native input is configured. It holds back
Dock-control events and nothing else: the Look up tap, three-finger drag and
the page swipe are not Dock control.

**Diagnostics, `INFINIFY_DEBUG=1`.** Lines on stderr, all beginning `debug: `:

- `multitouch: delivering, from a frame of N finger(s) (M framework callbacks so
  far)` and `multitouch: stopped delivering after N frame(s)`: the source went live
  or not. `multitouch: touch begins with N finger(s); the framework has called back
  M times, ... records by state {3:.. 4:..}`, then `N frame(s) in 1.00 s (X/s), K
  finger(s) now, peak P` each second of a touch and `touch ends after T s, N
  frame(s), peak P finger(s)`. `callback #N with R record(s) and none on the
  surface` (every 2 s) when the framework calls back and no record is a finger,
  with the states it sent; `MTDeviceStart(device ...) returned R`; and `20 s after
  the start the framework has called back N time(s)`, which says to touch the pad if
  it is 0.
- `dock-tap: installed (...)`, `not installed: AXIsProcessTrusted=0|1 ...` (every
  30 s), `the system disabled the tap (timeout|user input); enabled again`,
  `the watchdog found the tap disabled; enabled again`, `stopped`; and
  `dock-guard: Dock control is held back for the finger counts [3,4]` and
  `a touch source delivers ... | no touch source delivers ...`.
- `dock-control #N via=dock-tap|global-tap|annotated-tap <began|changed|ended|other>
  verdict=DROP|pass|undecided reason=<why> fingers=F gesture=G bound=[...] live=L
  refused=R tail_ms=T reports=N (+K similar not written) real=.. hid=.. axis=..
  phase=.. [fields: f..=..]`: each stream's first and last packet and any change of
  verdict, otherwise at most one line a quarter second. Reasons are
  `source-not-delivering`, `count-not-bound`, `touch-refused`, `bound-fingers`,
  `bound-gesture`, `tail-after-lift`, `stream-began-dropped`,
  `stream-began-with-system`; the session tap's own rule says what it saw instead.
  `via=annotated-tap ... reached-annotated-tap` is a packet that got past both
  session taps. The first packet of a stream and every packet of an undecoded
  format also print their non-zero integer event fields (`f..~` is a double), which
  is how a Show Desktop or Launchpad packet of an unknown format gets decoded.
- `gestures: touch of N fingers admitted as the canvas's (path multitouch|global-tap)`
  or `refused: <reason>`; `gestures: gesture_begin kind=pinch fingers=4 path=multitouch
  guard{...}` and `gesture_end cancelled=0|1 path=... guard{...}`: the recogniser's
  gestures, with the source that fed them (`multitouch`, `global-tap` or
  `view-touches`) and the guard's state at that moment.

That is the whole mechanism, and none of it has run against a trackpad. If the
source is not delivering (the framework or a device is missing, the opt-out is
set, a windowed run), or for the gestures the tap does not touch, the earlier
advice stands. Turn these off yourself in System Settings (the names recent
macOS releases use; they were not checked against this release's panes):

- Trackpad > More Gestures: Mission Control, App Exposé, Swipe between
  full-screen applications, Launchpad, Show Desktop, and Swipe between pages if
  it is set to three fingers.
- Trackpad > Point & Click: Look up & data detectors, if it is set to "Tap with
  Three Fingers" (it would take the tap of a doubletap-swipe).
- Accessibility > Pointer Control > Trackpad Options: three-finger drag, which
  turns three fingers into a mouse drag.

Left on, a system gesture and the canvas both see the fingers until macOS takes
the touches, at which point they arrive cancelled and the gesture in progress
ends cancelled: a pan keeps what it moved and stops there, and a hold fires
nothing. Upstream's cancelled swipe coasts, because libinput cancels a swipe
when one finger lifts ahead of the others. Here such a swipe ends uncancelled
when the other fingers follow within 100 ms, and cancelled only after those
100 ms, too late to launch anything. So a pan that ends cancelled while still
moving has lost its touches, and the shell follows the end of every cancelled
pan with `cancel_navigation` on that display.

Not done: an unbound gesture is not forwarded to the application under it
(upstream forwards it to the client), so with the default table a bare
two-finger pinch over a window does nothing. `resize-window` by gesture begins the same resize grab a bound
press begins ([Resizing a window with the pointer](../Navigation/README.md#resizing-a-window-with-the-pointer));
it has been run in controller scenarios only, never with fingers.

- `set-trackpad off` (no default key; bind it, or `Infinify msg action
  set-trackpad off`) stops all of the above, the two-finger pinch included,
  until `on`, `toggle`, a config change of `[input.trackpad] enable`, or a
  restart. The pointer, clicks and two-finger scrolling stay on: they are
  macOS's.
- A malformed entry in a `[gestures]` table is reported in upstream's words,
  as every config problem is, and skipped; the rest of the file applies.
