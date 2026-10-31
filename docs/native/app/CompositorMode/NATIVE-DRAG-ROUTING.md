# Native drag routing

In compositor mode (the full-desktop Dock helper, the shipping mode) every application window stays a real native window that the helper only draws away from its native frame, so macOS itself carries every drag between application windows. The section [Compositor mode](#compositor-mode-dock-helper-drag-and-drop-measured-on-2026-10-30) records what was measured there and the one limit found: a press in the title/toolbar band of a scaled window starts WindowServer's window drag. The second part, "Captured pictures", is about the surfaces that show only pictures of windows (the capture desktop, and an additional display's replica in compositor mode), where no drag session can reach a picture.

Helper presentation supplies a real native ownership site for each window,
with the canvas panel behind ordinary native windows. A source-to-destination
drag between these real sites can remain with AppKit and WindowServer from
beginning through completion, with no Infinify pasteboard receiver or data
substitute. WindowServer owns the transformed destination's hit testing and
window-local conversion. Whether all third-party destinations correctly accept
that conversion under the helper's transform remains a runtime acceptance
requirement; compilation and transform readback cannot establish it. For the
applications and zooms listed in the section below it was observed to hold, with
one limit at the top edge of a scaled window.

## Compositor mode (Dock helper): drag and drop measured on 2026-10-30

Everything in this section was observed in the disposable macOS 27.0.1 (26A434) UTM guests (SIP off, tiling and Stage
Manager as the owner's), with Infinify in compositor mode (`Infinify native-desktop`, `INFINIFY_DEBUG=1`) from a
build that changes no native source. Input was real HID events posted at `kCGHIDEventTap` by a small CGEvent program;
reads were `SLSGetWindowBounds`, `SLSGetWindowTransform`, the window list, `msg state`, the applications' own text and the
file system. No claim is made beyond the applications, points and zooms below; nothing here is `verified`.

**What is established: destinations honour the transforms.** A window the helper draws away from its native frame (native
rectangle and drawn rectangle differed by hundreds of points at every zoom, with transform scale 1, 1.33 and 2 at
zoom 1, 0.75 and 0.5) is the destination WindowServer picks for a drag when the pointer is over the DRAWN window, and the
destination's own `NSDraggingInfo.draggingLocation` is the window-local point of the drawn window, not of its native frame.

The cases measured (two disposable AppKit fixtures, Finder, TextEdit, Safari and Chrome; zoom 1, 0.75 and 0.5; a file URL, a selected word, an image and links) are not tabulated here. For the fixtures the destination's `draggingLocation` equalled the `mouseDown` location the same window reported for an ordinary click at the same screen point; in the real applications each drop landed under the pointer; a file released over bare canvas did nothing. No claim is made beyond those applications, points and zooms.

Where AppKit's own conversion from the window's native frame (`-[NSWindow convertPointToScreen:]`) was asked for the same
drop, it was hundreds of points from the pointer (916,443 against 908,649 at zoom 0.5): the destinations are correct because
WindowServer hands them window-local points computed through the transform, so nothing in Infinify translates or needs to
translate a drop. No native origin has to be moved under the drawn window and no window has to be presented at identity
scale during a session; neither was implemented.

**The drag image** is a full-display window at layer 500 owned by the SOURCE application, never transformed by the helper.
It follows the pointer in screen space at the size its application draws: the fixture's 120 by 60 point image stayed centred
on the pointer at zoom 0.5, Safari's image drag showed the page image at the size it is drawn in the scaled window (about
half of its 240 by 160 native points). The source's layer-500 window was gone one second after every release. In the harness
runs the DESTINATION fixture also owned a layer-500 window while the pointer was over its top half (which is its own drag-source
area) and still one second after the two drops there, never after a drop on its lower half; the source had logged
`endedAtPoint:` and the window was gone before the next drag started. Why is not known, and no real application showed it.

**What the taps do.** For each completed drag of the matrix (dozens of runs, fixtures and applications) the debug log has one `native mouse owner window=#N begin buttons=1`
and one `end=unchanged native click` for the SOURCE window: the press, every drag packet and the release reached the
application untouched (the tap only records an unclaimed native pair and withholds that window from helper frames until the
release settles, as before), and no takeover happened except for the band presses below. The source's `endedAtPoint:`
arrived in every fixture run, and the destination fixture's complete callback sequence (entered, updated, prepare, perform,
conclude) in every drop.

**The limit: a press near the top edge of a scaled window is a window drag.** WindowServer starts its own window drag for a
left press whose distance from the window's top edge is inside the title/toolbar band measured in DRAWN points, whatever the
application would do with the point. At zoom z that band covers the top band/z native points of the window, so at zoom 0.5 a
file icon in the first rows of a Finder window, a link near the top of a Safari page or a fixture press 40 points below the
window top is not a drag source: the native frame moves, the application also sees the press (the fixture's
`beginDraggingSession` ran), and `-[Desktop takeOverNativeDrag:event:]` ends WindowServer's drag with its tagged release,
which also ends the application's session before it can drop. The window then moves with the pointer under canvas control
(no jump), exactly as for a title press; no payload is delivered.

The 28 and 52 point bands are read from the same numbers and from screenshots, not from a WindowServer interface; that
WindowServer rather than AppKit makes the decision is inferred, because the application's own press location was correct
(a press at the same native point at zoom 1 starts its session). A fix needs either a WindowServer-level change of that
band under a transform, or presenting the pressed window so the pointer's offset from its top edge is outside the band while
the content point under the pointer is unchanged. The second has to be in place before the press, since the decision is made
on it, so it means rescaling or moving a window under the pointer on hover; and rewriting the press location in the tap
would make the application see a different content point. None of these was attempted.

**One unreproduced stuck session.** Once, after a Finder takeover and with source and destination being the same overlapping
TextEdit window, TextEdit's text drag session stayed up (its layer-500 window and its blocked Apple events) until a further
mouse-up was posted. It did not recur in the other runs of the matrix, which all ended their sessions, and it is not
explained.

**Reproduce.** `tests/e2e/compositor-dnd.sh --live-guest pair|band|outside` builds the fixture and the HID tool, runs two
fixture processes in a disposable guest reached through `DND_GSSH`/`DND_GSCP` while Infinify already runs there in compositor
mode, and writes JSON evidence under `target/ipc/`. `pair` fails if a drop's window-local point differs by more than 1.5 points
from its own click or from the drawn-rectangle point, or if a source session never ended; `band` fails if the two controls
(press 70 points down at zoom 0.5, 40 points down at zoom 1) do not drop or are taken over, and only reports the two band
cases; `outside` drops inside the destination's native rectangle but outside its drawn one at zoom 0.5 and fails if anything
is delivered (a point at 838,186 with the native rectangle 760,118 520x452 and the drawn one 1048,512 260x227: no drop, the
source's session ran). Without the flag it prints `LIVE NOT RUN`. The real-application rows above
were driven by scripts that are not in the repository and are not reproduced by it. Not measured: file promises, Mail or
Photos sources, drops onto Dock icons, a second display, tabs torn out of Safari or Chrome, spring-loaded folders, a physical
trackpad or mouse, and the capture/replica desktop.

The helper restores the placement-1 layer, which does not depend on the native origin, see [COMPOSITOR-MODE.md](COMPOSITOR-MODE.md#dragging-resizing-and-context-menus-of-a-transformed-window-full-desktop-dock-helper).

## Captured pictures: the capture desktop and additional-display replicas

The capture desktop currently forwards mouse packets into the selected native
recipient. That is enough to route a button press, but it is not a foreign
AppKit drag-and-drop session bridge. A destination in another application must
negotiate the original session's types, operations, promises, drop location and
completion with its source. Reading file URLs from the drag pasteboard, pasting
them or asking an application to open them does not preserve that contract.

Apple's [`NSDraggingSession`](https://developer.apple.com/documentation/appkit/nsdraggingsession)
is created by an application's source view. Its destination callbacks are
delivered to the registered destination view/window; its
[`NSDraggingInfo`](https://developer.apple.com/documentation/appkit/nsdragginginfo)
supplies that destination's location and the source's allowed operations.
[`File promises`](https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises)
also keep a source/destination conversation alive after the pointer release.
Those APIs do not provide this controller with a supported way to take an
arbitrary foreign session and deliver it into another process at a remapped
captured-image coordinate.

An extra display's captured replica has no second real native destination.
Simply making its panel transparent or hiding it would reveal whichever native
window lies underneath, at its own native position. That would neither prove
the displayed replica's identity nor map its drop location. Correct replica
support needs either a proven foreign-session routing contract or a settled
native ownership transfer to the exact displayed destination, including its
process birth, binding generation, current member ancestry, native bounds,
output clip and helper acknowledgement before release. Neither is implemented
by the mouse-pair preservation change.

The native adapter now implements a request-only destination handoff for a real
AppKit drag over an additional display's captured copy. The canvas registers
file URL, URL, image and file-promise types, but returns `NSDragOperationNone`
and refuses `prepareForDragOperation:` / `performDragOperation:`. It reads no
pasteboard contents. The exact rendered hit can request movement of the real
window family to that output. This is restricted to a complete audited family
wholly inside the output, since native clipping is still unsupported.

Both sites retain captured coverage until a causally fresh complete helper ACK
and independent identity, ancestry, bounds, transform, alpha and screen reads
agree with the immutable request. Cancellation stages a new recovery request;
it never assumes the previous native position has returned. Ordinary primary
camera motion remains outside this admission path. The original physical drag
and release remain untouched, and AppKit must rediscover the actual destination
before a native drop can work. The canvas cannot accept a drop on its behalf.

Captured sources now use the same ownership request before a press. Unbuttoned
physical hover over an eligible replica queues a coalesced main-thread check;
the event tap leaves the original motion untouched. The check requires fresh
real capture pixels, unchanged rendered identity and geometry, a complete family
wholly inside the output, and an independently read event-eligible recipient.
Active buttons, gestures, resizing and camera transitions prevent a new request.
It neither activates the source nor posts a replacement press.

Retaining a picture is insufficient evidence that its stream is still usable.
The mailbox tracks callback order separately from successful image publication.
Suspended, blank, stopped, invalid and otherwise unavailable callbacks revoke
readiness, including callbacks without an image. Idle preserves an already usable
picture but cannot revive one. An older queued Complete cannot undo a later
revocation; a new Complete must actually publish before ownership can be requested.
Status-only callbacks update the mailbox state without scheduling main-thread
work. The headless mailbox regression exercises the actual production methods
with sample storage and dispatch substituted; it is not live capture evidence.

The same availability check gates captured clicks, scrolling, green-button
actions, pointer mapping and tablet forwarding, including a second check after
focus or geometry work. A click waiting for focus loses its entire unsent pair
if capture becomes unavailable. Already admitted mouse and tablet contacts close
through the original identity-validated recipient; their remaining physical
events stay suppressed. This does not change ordinary input at the actual native
window. Synthetic load images cannot authorize application input. Run
`sh tests/e2e/root-capture-mailbox.sh` for the mailbox and extracted production
consumer scenarios; native posting and capture transport are substituted.

A press arriving while coverage still requires admission is refused as an entire
button pair, including when a cancelled request has no eligible recovery token.
After a fresh complete helper ACK and independent placement validation settle
ownership, the next original press must still match the current native recipient
and admitted placement. Completed ownership remains at that output when the
pointer leaves; an unfinished hover request is cancelled and recovery stays
covered.

This is source implementation, not runtime acceptance evidence. Fresh replica
capture remains blocked in the transformed fixture cases below. The existing
primary-site check does not establish replica handoff, captured-source sessions,
file promises or arbitrary third-party acceptance.

`DWNativeInput.m` now leaves an unclaimed original press addressed to a foreign
native window, its drag/motion packets and its release untouched even after
the pointer crosses the canvas or another application. Each physical button
has its own ownership; a second button cannot start a canvas action in that
native drag. Known lifetime-tagged posted copies bypass bookkeeping, and a tap
disable retains physically held native buttons and retires only released ones;
stop clears reservations. A swallowed canvas down
still suppresses its physical release after cancellation, so another
application cannot receive an unpaired up.

The desktop also withholds that window from helper placement for the entire
native-owned pair. Frame reconciliation and native resize do not write to it
while macOS owns the gesture. After physical release, it waits for settled
geometry and adopts the displayed displacement into world coordinates before
resuming helper placement. A captured titlebar pair remains canvas-owned from
down through up. Tap cancellation cannot start the release deadline while a
physical button is still held, or admit a competing second-button canvas action.
In the macOS 27 VM, the owner manually dragged TextEdit and
Finder repeatedly, including after zooming out, and reported stable dragging.
That confirms those real-app gestures; it does not establish every native
fallback drag or cross-display transfer.

One exception ends a native pair early. When an unclaimed press on a transformed root becomes the application's own window
drag (the native origin moves, the extent does not, and the pointer has travelled more than 4 points), WindowServer drags the
frame from where the window is drawn and the drawn window leaves the pointer. The consumer then calls
`-[DWNativeInput takeNativeButton:]` from the ownership callback: that packet and the rest of the physical pair are swallowed and
offered to the consumer, and the consumer ends WindowServer's drag with one left-up posted at the HID tap from a private event
source, carrying the source's lifetime tag (which both taps let through, as for every posted copy); the canvas's hold on the
physical pair (`-holdsCapturedButton:`) keeps the shell's lost-release watchdog from ending the gesture because the system's button
state now reads up. Other native pairs, including content drags, resizes and
drag-and-drop sessions, are untouched: only a press whose own application starts moving the native window is taken. The adapter
test `sh tests/e2e/native-input-policy.sh` covers the packet policy only (the packet that is taken is swallowed, the tails
are offered to the consumer, the next press is native again); that the application and WindowServer accept the tagged release is
a guest observation recorded in [COMPOSITOR-MODE.md](COMPOSITOR-MODE.md#dragging-resizing-and-context-menus-of-a-transformed-window-full-desktop-dock-helper).
The takeover does not put the application's native frame back: WindowServer has already moved it (to where the window was drawn), and the
helper restores the window's original placement-1 layer, which is relative to the native frame, so a taken-over window is restored consistent
with its frame (COMPOSITOR-MODE.md section "Restore after a native-origin move"). The takeover decides "transformed" from the placement the controller drew (`planned_screen`, read when the press is owned), not from the window list's bounds, which read back the native frame for some windows (Finder drawn at half size) and so hid the transform; see [COMPOSITOR-MODE.md](COMPOSITOR-MODE.md#dragging-resizing-and-context-menus-of-a-transformed-window-full-desktop-dock-helper) for the flicker it caused and what remains. A press on the empty strip of a toolbar group (Safari's address-field group,
for example) is the window's, not the application's, so it is claimed as a title press and never becomes a takeover.

**Chromium's caption (tab strip).** Chrome (and Aside, which is the same toolkit) draws its own title bar: the tab strip row. AppKit
reports no title element, and the window's own children hold no `AXToolbar` (it sits several wrapper groups down), so the unified-toolbar
audit answered `missing_top_toolbar` and a press on the empty strip went to the application, which calls
`-[NSWindow performWindowDragWithEvent:]` on it. WindowServer then dragged the transformed window from where it is drawn: the picture was at scale 1
for 11 (fast) and 27 (slow) drag samples at zoom 0.5 before the takeover, the native frame moved (105 and 240 points), and a plain single click
without motion moved it too (native origin -45,408 to -190,466 at zoom 0.5, 205,159 to 360,97 at zoom 1: the pointer's offset from the top edge
is read from where the window is drawn, not from its native frame). `AXUIElementCopyElementAtPosition` cannot separate caption from tab: a
point on a tab and a point on the empty strip both return an unlabelled leaf `AXGroup` (Chrome 156, recorded in the guest). The classifier
(`decorationBrowserCaption` in `DWNativeDecorations.m`, entered where `missing_top_toolbar` was returned) therefore reads frames. It walks
only the elements that start above the traffic lights' bottom, finds exactly one `AXTabGroup` whose top is the window's top (its bottom
is the strip row's bottom, never a guessed height), and takes the row from the window's top edge to that bottom, full width, as the
caption, minus: the traffic lights, the whole `AXTabGroup` (tabs, their close buttons, tab-group chips), every other control in the row
(tab search, New Tab and any other button, pop-up, text field or checkbox) and any leaf group with a press action. What is left is the space
around the traffic lights, the empty strip and the space right of New Tab. The toolbar (omnibox, buttons), infobars and web content start
below the row and stay the application's. The audit rejects, exactly as before, on: no tab group (`missing_top_toolbar`), several tab groups,
a web area, scroll area, toolbar, split group or text area inside the row, a tab group that is not the top row, an element inside the
row that is unreadable or belongs to another window, a measured element below the lights that reaches into the row, a node or time
budget exhausted (96 nodes, the lookup's 150 ms), or more than 64 children of a group. An accepted caption is reported as
`reason=accepted_browser_caption`. The press path is the unchanged title press: a drag moves the window on the canvas, a click focuses
it and delivers nothing to the application, and a double-click runs the canvas's own title double-click action (Fill).

Measured in the macOS 27.0.1 guest (vm2) on Google Chrome 156 with a 1200x1036 window of three tabs, real HID at `kCGHIDEventTap`, a press on the empty strip
at window-local (1100,20), sampling the placement-0/1 and catenated transforms and the native bounds every 0.5 ms; before = this tree without the
caption audit, after = with it (`INFINIFY_DEBUG=1`, `AppleActionOnDoubleClick` `None` throughout):

| Chrome, empty strip | before | after |
| --- | --- | --- |
| zoom 0.5 drag, fast (15 steps, 60 ms), samples at scale 1 | 24, 7, 11 (three runs) | 0 |
| zoom 0.5 drag, slow (60 steps, 960 ms), samples at scale 1 | 22, 21, 27 (three runs) | 0 |
| zoom 0.5 drag, native frame moved by WindowServer (max over the run) | 105 and 240 points (last run) | 0 and 0 |
| zoom 1 drag (nothing to flicker), native frame moved | 550 and 145 points | 0 and 0 |
| zoom 0.5 single click, no motion | native -45,408 to -190,466 (-145, +58); `native title miss ... reason=no_region`, `end=final geometry did not settle within two seconds` | native unchanged; `native chrome owned window=#42 kind=title` |
| zoom 1 single click | native 205,159 to 360,97 | native unchanged |
| zoom 0.5 and 1 double-click | native frame unchanged (the macOS action is off), two `end=unchanged native click`; no canvas action | `native resize origin operation=native_decoration action=fullscreen` (Fill): native 360,97 1200x1036 to 0,30 1920x1080 at both zooms |
| click on the second tab (local 480,20) | selected (AX: Tab two selected) | selected (it is excluded: `native title miss ... excluded=113,-1,734,43`) |
| click in the omnibox (local 600,63) | focused (AX `AXFocused`) | focused (`outside title=0,0,1200,41`) |
| TextEdit title (586x488), zoom 0.5 and 1, fast and slow | 0 samples at scale 1, native moved 0 (4 of 4) | the same (4 of 4) |
| Finder title (700x500, unified toolbar), zoom 0.5, fast and slow | 0 samples, native moved 0 | the same |

The `before` double-click and tab/omnibox rows show that the application kept getting its own presses; the single-click rows are the owner's
"a click moves the window" symptom. Finder at zoom 1 was also run (0 samples before and after) but the harness's window pick at that zoom is not
reliable, so that row is not claimed. Not measured: Aside's browser window (the guest's Aside only reached its sign-in screen), Electron windows with a hidden
title bar, a window with many tabs (the 150 ms lookup was not timed; no `title_deadline` reason was logged in the after run with three tabs), and the owner's Mac.

`sh tests/e2e/native-decorations.sh` runs the classifier over the Accessibility shapes recorded in the guest (Chrome with three tabs, one tab and an infobar, Aside's sign-in window, TextEdit, Finder; 57 checks: caption points owned, tab, close button, New Tab, tab search, traffic lights, omnibox, toolbar and web content points the application's, the TextEdit and Finder cases unchanged, and mutations of the Chrome tree that must keep the old rejection). With the audit disabled 16 of those checks fail. It substitutes the AX calls, so it is a statement about the classifier, not about a live press.

COMPOSITOR-MODE.md's numbers row for the drag lane lists "Chrome tab strip" at 0 samples before and after at zoom 0.5; the points of that row are not
recorded, and the empty-strip points of this section are the ones that showed 11 and 27.

Electron windows with a hidden title bar (Orca, Marengo) and Aside's real browser window are NOT covered or measured: an Electron page draws its
drag area with CSS (`-webkit-app-region`), which Accessibility does not expose, so there is no caption signal to read, and such a window keeps
today's rejection; Aside was only reachable at its sign-in window in the guest (no tab group, close button outside the window: rejected as before).

Managed root chrome now has a separate session-stage ownership decision.
An independently recognized titlebar or green button, or a controller-qualified
resize border at the exact native recipient, reserves the entire mouse pair
before AppKit receives its down. Controller movement uses the current source
identity, generation, output and displayed frame; it does not wait for captured
pixels or renderer ordering. A refused chrome action stays swallowed through
release instead of becoming a native drag. Secondary buttons cannot start a
competing action during that pair. Titlebar double-click and green-button
presses use the existing Infinify Fill path.

Only a separately reported, validated AX move may translate a recent titlebar
map without discarding it. Its original age and local control exclusions remain
unchanged; size, title, mixed and unknown changes still invalidate the map.
A failed AX refresh can retain the currently published map only within its
original half-second lifetime and after a fresh identity and exact-frame check.
It cannot revive an invalidated map or extend its lifetime; a successful negative
titlebar report replaces it.
Control-Command-F and Fn-F use the same canvas Fill path when a fresh bounded
native focus read identifies a currently managed root. Admission starts with the
actual focused window rather than the asynchronous logical focus observation;
the deferred action rechecks its identity, binding, session and output. Authored
bindings and explicit key passthrough retain precedence. Fn-Control-F enters
Fill, Fn-Control-R restores it, and Fn-Control-C centers the camera on that exact
target without resizing it. Repeated Fill or Restore presses cannot toggle the
opposite state. The documented Fn-Control-arrow tiling chords, including their
Shift and Option-Shift variants, are consumed for admitted managed roots so
macOS cannot rearrange their backing windows. Unmanaged or unverified targets
retain native input.
Unknown chrome, green hover popovers and application menus remain separate
native paths. These changes do not claim blanket suppression of
every application's window controls. Physical gesture acceptance must be checked
in the running VM; policy checks and compilation alone are insufficient.

Native-origin changes alone never move a canvas window: macOS can reflow an
application's frame when displays change. Observations still refresh the native
basis and size. Output rebuilds cancel stale observations but retain the session
tap's physical button ownership; an existing native pair settles without
adopting displacement across the topology change. This leaves the helper's saved
transform and alpha obligations intact and does not restore native bounds.

The earlier global trackpad tap records unowned original buttons and refuses a
new touch, Dock or magnify contact during them. An already admitted three-finger
canvas contact retains its generated mouse pair and can pan over windows. If
macOS delivers an application mouse-down before the first decodable three-finger
contact, the existing native pair stays native until release. Taking its tails
would steal an application drag that has already begun. Physical ordering of
macOS's accessibility three-finger-drag packets is unverified; the regression
checks both orderings as adapter policy and does not claim hardware parity.

Run `sh tests/e2e/native-input-policy.sh` for isolated packet-policy coverage.
It installs no event tap, creates no window or native session, reads no
pasteboard and posts no events. Its packet and decoded-contact substitutions
remain within that test process; its already-admitted-contact case seeds prior
ownership on the test object because no live tap exists. It does not establish usable cross-application
drag-and-drop through either real helper surfaces or captured replicas.

## Owned native session check

`tests/e2e/native-drag-drop.sh --live-owned-fixture` creates one ordinary AppKit window in each of two independent disposable processes, each with its own cooperative binary-v2 helper allowlisting exactly its one window, presented at half scale by the grouped native presenter. The source view starts a real `NSDraggingSession` carrying a private file URL; the independent destination validates the file's contents and records the complete entered/prepare/perform/conclude callback sequence and window-local location. The driver requires AppKit's source outside-application context, checks both fixtures' birth/window identity and native owner before every input sample, and after quitting Infinify audits both helpers' restoration (independent WindowServer reads and helper INSPECT against the original identity, owner, transform, bounds, alpha and screen rectangle, no held entries or pending journal). With `--replica-destination` the destination is a captured replica on a second view; that scenario stopped at the capture blocker below.

It establishes the route between two exact owned primary-native AppKit processes. File promises, arbitrary third-party applications and captured replicas remain unverified or unsupported as specified above; this check is not ordinary-application parity evidence.

## Replica capture blocker

Fresh scaled content for a replica of a transformed window could not be obtained in any recorded diagnostic. The replica destination scenario stopped before physical input because its root streams supplied `SCFrameStatusSuspended` without image buffers. In a one-process AppKit fixture the continuous desktop-independent window stream delivered fresh pixels at the original geometry, suspended while a root-only native transform displayed the window at half scale, and resumed after exact restoration; refreshing the filter alone, a display-style filter (fresh pixels but the original detail lost), `SCCaptureResolutionBest`, one private window-list snapshot and a coherent family transform did not give fresh full-detail pixels, and a real TextEdit window at 65% scale in the macOS 27.0.1 guest delivered zero Complete callbacks. These are negative capture results, not a working replica fallback. The production hover handoff requires actual fresh replica pixels; neither these diagnostics nor successful capture startup validates a replica handoff or a captured-source drag session.
