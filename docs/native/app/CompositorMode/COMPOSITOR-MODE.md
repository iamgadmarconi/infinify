<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Compositor mode (Dock helper)

Compositor mode presents the real application windows themselves. The window server draws each window, moved and scaled by a
transform that a helper inside the Dock sets, and the shell draws nothing of it. A normal run without this mode draws a captured picture of each
window instead (capture mode).

The helper, its launch daemon, its protocol, its journal and its recovery are in [docs/native/dock-helper/README.md](../../dock-helper/README.md).
How the app is put into this mode and kept there (`Infinify native-desktop`, the login default, the reload after a Dock restart) is in
[user-guide.md](../../user-guide.md#compositor-mode-at-login-and-dock-restarts); the launcher starts the app as
`Infinify --native-desktop-helper RUNTIME_DIR NONCE_FILE`, the explicit whole-desktop selection for this login user, which needs one
authenticated Apple Dock-hosted same-user helper with scope audit and per-window restoration, Accessibility access and Stage Manager
off, and cannot be combined with `--only-pid`, `--windowed` or `--manual`. Screen Recording is optional: the native primary needs none,
and with it additional display views get captured copies. The scoped development form of the same presentation
(`--windowed --only-pid` with `--native-helper`) is in
[README.md](README.md#native-presentation-through-a-cooperative-helper).

This file is the design as it stands and its limits. The parity contract keeps the features it describes at `implemented_unverified`
([docs/parity/README.md](../../../parity/README.md)); nothing here is `verified`. The dated runs, guest tables and build hashes that these sections once carried are not kept.

## Native presentation and one independent view per display

The canvas panel sits behind native windows and draws the background, stand-ins
and canvas overlays. A root visible on several displays keeps one real native
placement; additional placements use a shared live capture with each output's
camera, zoom and clip. The protocol v2 client sends the selected placements as transforms
and alpha values, plus the destination display's current ordinary Space when
the helper advertises that capability. Windows outside every output are parked beyond the union of
the physical displays. Native bounds are read independently of the transform,
so camera movement does not change world geometry, focus bounds or resize
readback. A helper frame limit is enforced before submission: exceeding it ends
presentation and restores the windows instead of silently omitting some.

The owner selected **one independent view per display** on 2026-10-11. `DWNativeViews.m` keeps a root's real placement
on its existing output while visible, then chooses the largest remaining visible
placement. It forgets that choice when the source identity changes. The other
placements share one on-demand ScreenCaptureKit stream per root; no duplicate
stream is created for each display. Capture demand uses only these extra views,
keeps the existing two-second idle grace and bounded recovery, and never asks for
a permission grant. Without Screen Recording access the native placement still
works, but additional views have no pixels. Capture errors retain the native
binding. A session departure stops these streams and clears their saved pixels;
reconnection obtains fresh shareable-window identities.

Replica mouse, scroll and hover delivery uses the existing scoped per-window
posting mechanism. `DWNativeReplicaInput.m` rechecks process birth, window owner
and untransformed bounds, and separates application-local points from the real
window's transformed screen location. It never forwards keyboard events. Each
press retains its original source for release, and tagged forwarded events bypass
the native gesture bridge. The green-button bridge also hit-tests extra display
placements and dispatches the existing canvas-fullscreen/Option-fit command.

This is not complete native multi-display acceptance. Choosing another output changes a window's transform and its reported screen
rectangle, but whether the native window is visible and hit-eligible on that display depends on its display Space membership, which
the handoff below transfers. Production handoff does not write native origins.

The handoff implementation adds negotiated `FRAME_SPACE` requests. The presenter resolves each exact physical viewport to its active
ordinary Space, includes it in placement acknowledgement correspondence, and parks roots whose display is unavailable. A root whose
complete family audit is unavailable is not parked: it keeps its placement and requests no Space move until the family is audited again
(see "A root whose family cannot be read" below). Withheld, parked and released records do not request a Space move. The helper admits
transfers only between active ordinary Spaces on distinct physical displays, journals original membership before moving, and checks
membership before acknowledging placement. It retains the original Space for restoration, including when a parent move carries a child.
Moving between desktops on the same display is refused.

On one display, the line `native presentation: window N of process P not placed: the window and destination do not have eligible display
Spaces` (helper status `SPACE`) does not mean that a newly opened window was left unplaced. In the traces recorded, every new window had the
display's current ordinary Space as its target from its first record, and the helper answered `APPLIED` on that first frame and on every
later frame while the document was open (`APPLIED` includes the helper's own readback that the window's membership equals the target). The
refusals came at the end of a window's life, when the document was closed: the window was absent from
`CGWindowListCopyWindowInfo(kCGWindowListOptionAll)`, its alpha read 0, `SLSGetWindowTransform` failed with 1000 and every
`SLSCopySpacesForWindows` selector returned an empty array, while the canvas kept sending it for a few frames. With no membership there is
nothing to journal or confirm, so the refusal is intended and the line is noise for a closing window.

`[zoom] reset_on_new_window` (on by default) flies the camera to each new window at 1:1, so after the first new document the canvas zoom is 1
and every later window is correctly placed with a unit-scale matrix. A meter that counts scale 1 as unplaced, such as the guest's `measure-opening N 0.5`,
which sets the zoom once, reports those windows as untouched for their whole life; with `reset_on_new_window = false` a `measure-opening 8 0.5` run gave all
eight at scale 2.000 and no `SPACE` line.

A handoff can make the application reflow the window (Safari's native frame changed during a handoff, and an ordinary size observation
incorrectly changed its world frame). A submitted new Space target therefore qualifies presentation-only source observations until a matching
family ACK and stable native frame settle (at least two seconds from submission and 250 ms without an observed frame change). Native input
ends that guard. The observed native basis still updates; equal later observations cannot adopt the same reflowed size into the world. A
subsequent actual application size change adopts normally. `DebugNative.space_reflows` retains the native before/after frames and explicitly
reports that native frame restoration is not owned: restoring Space, transform and alpha does not promise to undo AppKit's reflow.

## Arrival veil (full-desktop Dock helper)

Without the veil, a new application window is shown at its native size and place until the first frame places it (for its whole life when
placement does not work). With the explicit same-user Dock helper the shell asks, once admission has confirmed an empty restoration table, for
the helper's arrival veil (`dw_client_veil`, capability 128): the helper holds each window an application opens at alpha 0 from the window
server's own announcement of it, and the first frame the shell sends for it re-reads the window's transform and bounds (the application may
have moved it), has the helper journal that, applies the transform and then the record's alpha (or lifts the alpha). The shell does not decide
what is veiled and keeps no list of it. A helper that does not offer or refuses the veil leaves new windows as they were, and the session is not
refused for that.

A window the shell will not manage is let go instead of waiting for the helper's own bound of 1 s:
`DWWindowManager` tells its host (`-windowNotAdopted:pid:`), once per appearance and from the first discovery
pass on (a window that arrives while it runs is held back like any other), of a window of a non-regular application,
one the shareable windows or Accessibility do not count as a window, one a read settled as not real, and `Desktop`
tells it of a window `attach` refused, and of one `-windowAppeared:` could not take while the canvas was closing or had no
panels. If the helper does not answer the veil request in time, or answers unreadably, the shell assumes the veil may be on
and keeps releasing explicitly (a no-op record at worst) rather than leave such windows invisible for the helper's bound. The
presenter turns that into one release record for the exact process instance (`-declineWindow:`), sent with the next
frame (one frame is made for several declines together) and retired by any answer. A release of a window the
helper holds nothing of is a no-op, and one for a window the presenter already binds is never queued. A child
of a managed root (the TextEdit *Save* sheet) is placed by the family reconciliation; `-windowAppeared:` hands such a window to that path and does not
decline it. `-windowNotAdopted:` (the manager's decline of a window it does not take for a window of its own: a hover card, a completion
list) does the same when the window is, by the window server's own parent chain (`DWNativeWindowBelongsToRoot`), a member of a root that is placed: it asks
for a family reconciliation and releases the helper's veil for that window only 250 ms later (`DWFamilyChildGrace`), if nothing has placed it by then; the
presenter refuses a release for a window it has bound, so one the family placed meanwhile is never released.

Limits that were observed (meter readbacks in the macOS 27.0.1 guest, not optical capture): an application that animates its windows can lift
the veil itself (TextEdit's own open animation wrote alpha 1 about 0.5 s after a window's creation); the TextEdit *Save* sheet arrives mid-fade
(alpha 0.79 at first read) and is not veiled, so its fade-in still shows at native size for about 22 ms before it is placed; a Dock exit does not
undo an alpha the Dock set (a veiled window stayed at alpha 0 after `killall Dock` until the launcher's recovery handoff restored it). See
[`docs/native/dock-helper/Payload/README.md`](../../dock-helper/Payload/README.md#arrival-veil) for the helper's rules and tests.

## Dragging, resizing and context menus of a transformed window (full-desktop Dock helper)

The owner's first compositor-mode run (build `c49eae1`, real Mac) reported windows that jump when dragged and when resized, and a Finder window
that vanished under a right-click menu. This section is what was found and what changed. The measurements were made in the macOS 27.0.1 guest
(the owner's `com.apple.WindowManager` tiling settings, Stage Manager off) with real HID events posted by a small CGEvent program at
`kCGHIDEventTap` and read-only probes of `SLSGetWindowBounds`, `SLSGetWindowTransform`, the window list and `msg state`.

**Which presses reach the application.** A window the helper has transformed is drawn at a rectangle that is not its native frame. The early
session tap claims a press only where Accessibility confirms chrome (title region, green button) or the canvas resize border; every other press
is the application's, and `nativeMouseOwnershipChanged:` only records it (the window is withheld from helper frames until the release settles).
`DWNativeDecorationButtons` refuses an application whose chrome Accessibility does not confirm (`child_geometry_or_owner`,
`toolbar_root_geometry_or_owner`, `missing_top_toolbar`), and its presses stay the application's. Inside an accepted toolbar the exclusion
rectangles (controls, and groups to the extent of their children, see "Toolbar groups" below) are also native: a press at a Safari toolbar point
reported as `native_control` went to Safari.

**What macOS does with a native window drag of a transformed window.** WindowServer's own title drag starts from where the window is drawn, not
from its native frame, and the transform is re-applied relative to the moved frame when the button comes up: the drawn window leaves the pointer,
and adoption of the displayed displacement then moves the world window to the wrong place. macOS tiling reads the native place, which is not the
drawn one (the owner turned tiling off and the jumps remained, so tiling was not the cause).

**Takeover** (`-[Desktop takeOverNativeDrag:event:]`, `-[DWNativeInput takeNativeButton:]`, `DWNativeDragTakeover.h`). A press that was
left native on a transformed root and then shows the native origin moving with an unchanged extent, with more than 4 points of
pointer travel, is the application's own window drag (`DWNativeWindowDragStarted`). The first such drag packet takes the pair over: the
controller begins a window drag from the press point (`begin_drag`), the physical button becomes the canvas's (that packet and every later
one are swallowed and offered to the same consumer as a recognized title press), the native mouse owner ends without adopting anything,
and the window moves by the pointer from the press point exactly as after a recognized title press (`gesture_to`). Two measured facts
shaped it, both found by trying the obvious version first:

- WindowServer's drag is not driven by the events the taps see. With the tail swallowed, the native window (and, below zoom 1, its
  full-size picture) kept following the pointer. One release posted at the HID tap ends it (`CGEventPost` of a left-up from a
  private event source, carrying the source's lifetime tag, which both taps let through); posting the release to the
  application alone with the window number, the route a forwarded click takes (`SLEventPostToPid`), did not end it.
- That release also clears AppKit's combined button state while the finger is still down, so `-endLostInput` ended the taken-over
  gesture 50 ms later as "A button release never arrived", after a few points of motion. A gesture marked `takenOverAt` is now
  left to the tap while `-[DWNativeInput holdsCapturedButton:]` says it still owns the physical pair (bounded at ten minutes).

Resizes (the extent changes), content drags (no native motion), an identity placement (drawn where it is natively) and anything whose
binding, camera, zoom, output or generation changed since the press stay native. No region of the window is guessed: a press is
taken over only when the application itself starts moving the window, so tab drags, text selections and scrollbars that never move the
native frame are untouched. The packet that shows the motion has already reached the application, so up to a frame of native motion
can still be seen before the window is back under the pointer.

**Restore after a native-origin move.** The takeover above lets WindowServer's own title drag move the native frame before the shell takes the
pair over, so the native frame of a window dragged that way ends elsewhere than it started. What broke was the quit: the helper wrote back the
transform captured at the first touch, which draws the window at the origin it had then.

Root cause, and why it is in the helper rather than in the takeover: a window server transform maps the screen into the window's own space and so
carries the window's position (`[1,0,0,1,-x,-y]` untransformed); `SLSSetWindowTransform` writes it as given, whatever the frame is (the unchanged
build drew Ghostty at `(601,417)` with its frame at `(494,399)`), and a native move of the frame while a transform is set moved the drawn rectangle
with it on an owned fixture window moved through Accessibility (no shell running: placed rectangle `(125,820)` became `(162,843)` for a move of
`(+37,+23)`). The frame moves for reasons the shell cannot all prevent (the application, the takeover,
a toolbar re-layout), so the restore must not depend on where the frame is. It does not: the original the helper journals and writes back is the
window's placement-1 layer, relative to placement 0, which follows the native frame by itself (`docs/native/dock-helper/Payload/README.md`, "The
original is the layer"; until schema 4 it was the absolute matrix, re-based on the origin read at the write). The takeover is **not** changed to
put the native frame back. Reasons: (1) with the layer restore the quit is consistent whatever the
frame did (below); (2) putting the frame back is the shell's first native-origin write to a foreign window (the design says "production handoff does
not write native origins"), and the fixture measurement above says a native move shifts the drawn picture, so it would need the shell to re-assert
the transform in the same instant or show a one-frame jump of the window under the pointer (with the shell running, a parked Ghostty moved from
`(627,428)` to `(300,200)` through Accessibility kept its drawn rectangle at the park position at 50 ms and 1 s; whether the shell or the park state did
that was not separated); (3) the takeover is only for applications whose title bar the shell cannot recognise. The cost: such a window reappears at its
native frame as WindowServer left it, not at the one it had before the session.

**Toolbar groups** (Safari's address field at zoom 0.5). A press-drag on Safari's toolbar background did not move the window at zoom 0.5. Safari's
window has an `AXToolbar` whose centre child is an `AXGroup` holding the search button and the address field; the group is the toolbar's height,
its controls are not. `DWNativeDecorationButtons` excluded the whole group, so the press went to Safari. What Safari and WindowServer then do
depends on where the press falls: a band a few screen points under the top edge is neither a drag nor a control at either zoom, and the toolbar
background point of the measurement lies in it at zoom 0.5. Why Safari and WindowServer treat that band so is not explained.

Fix (`DWNativeToolbarExtent.h`, `decorationGroupExtent` in `DWNativeDecorations.m`): a toolbar item that is an `AXGroup` is native where its children
are, not as tall as the toolbar. It keeps its full width (a field's rounded ends and a segmented control's edges stay with the control) and its
vertical extent shrinks to the union of its children's frames, inflated by a point like every control. Best effort inside the lookup's 0.15 s budget
(a role and a children read per group item, a frame read per child; Safari: three groups, five children; no time left, an unreadable child, or one
outside the group keeps the whole group native as before; the cost was not measured inside the shell, the whole-tree `axdump` of Safari took 30 to 40 ms
including process start). The strip above Safari's address field is then the window's: the shell claims the press as a title press before the
application sees it (`native chrome owned window=#3 kind=title`) at every zoom, with no WindowServer drag and no takeover. The log after:
`native title miss local=917.5,14 excluded=540,10.5,755,39.5` for a press inside the field. Pure geometry is checked by `sh
tests/e2e/native-input-policy.sh` (Safari's measured numbers, the fail-safe cases).

**An unknown family parked its root** (a window that vanished for a moment while it was resized, and the Finder window under a
context menu). Frames for the Dock helper carry, per window, either its placement or a parking transform far off every display
(256 points beyond the displays' union). With Space frames, which the full-desktop helper uses, the presenter parked a root
whenever its audited family report was missing (`root->familyKnown` false). That report is dropped (`-forgetChildrenOf:reason:`,
printed once per root and reason as `native family #N unavailable: …`) whenever an audit fails: a native frame that cannot be read
for an instant (`-[Desktop track:info:]` calls `-forgetNativeFamily:` when `DWNativeBounds` fails), a member that changed while it
was being read (`inconsistent, duplicate or changed family member`), or a window the audit refuses. A window is then parked, off the display, until the next audit passes. In the unchanged build this parked the resized window during the shell's own edge and corner resizes, and the same `native family #N unavailable` line appeared for the Finder window after right-clicks. The root is now still drawn where the canvas puts it, but is not asked to change Space until a good audit again
(`windowSpaces` is only recorded with a known family), so a lost report no longer moves a window; with `INFINIFY_DEBUG`, one
`native park begin|end` line says when and why any window is parked. The presenter regression
`sh tests/e2e/native-presenter-readiness.sh` now checks that an unknown family still gets the placement matrix, not the park
matrix, and fails against the old rule.

In the guest, the fixed build left the dragged window under the pointer at the end of the drags measured (Ghostty at zoom 1 and 0.5, Safari at zoom 1 and
0.5, TextEdit), where the unchanged build ended 220 to 319 points off for Ghostty and 304 for Safari at zoom 1. Two canvas-handled Safari presses at zoom 0.5 ended
13 and 30 points from the pointer in the fixed build; a neighbouring window's `[snap]` is the likely cause and was not checked. In 30 resize cases (TextEdit,
Ghostty, Safari; zoom 1 and 0.5) the opposite edge or edges did not move and no sampled instant had the window parked; the moved edge ended within 3 points of
the pointer in 16 of 30, and in the other 14 the application granted no or part of the size, which was not investigated. A Finder right-click (file icon and
empty space) opened its menu at the pointer with the Finder window drawn where it was, in the unchanged and in the fixed build: the owner's disappearance was
**not reproduced**. What is claimed is only the rule change above and its in-memory regression.

## Dragging files, text, links and images between transformed windows (full-desktop Dock helper)

Measured in the macOS 27.0.1 guests with real HID events (2026-10-30; the numbers, the table of applications and the
reproduction are in [NATIVE-DRAG-ROUTING.md](NATIVE-DRAG-ROUTING.md#compositor-mode-dock-helper-drag-and-drop-measured-on-2026-10-30)).
No source changed for it. A drag between two application windows is macOS's own session (the source application creates it,
WindowServer carries it, the destination application accepts it); the helper only changes where the windows are drawn, and the
session honours that:

- **Destination.** The window under the pointer as DRAWN is the destination, and its `draggingLocation` is the window-local point
  of the drawn window, so the drop lands under the pointer at zoom 1, 0.75 and 0.5: a Finder file onto TextEdit's seventh line,
  a TextEdit word between two exact characters of another TextEdit window, Safari's image and link and Chrome's link onto the same
  line, a Finder file onto a Finder list row's folder. Nothing converts or re-posts the drop; no native frame is moved under the
  drawn window. A drop at a point inside the destination's native rectangle but outside its drawn one delivered nothing.
- **Drag image.** A full-display layer-500 window of the source application, at the size the application draws and centred on
  the pointer; the helper does not transform it.
- **Canvas space.** A file released over bare canvas did nothing: the session ended, the file stayed where it was.
- **The taps.** The press, drag packets and release of every drag in window content reached the application untouched
  (`native mouse owner ... begin` then `end=unchanged native click`); only the withheld-window rule applied to the source.
- **Limit.** A press whose distance from the window's top edge is inside the title/toolbar band in drawn points (about 28 for a
  plain title bar, 52 for Finder's toolbar, 89 for Safari's toolbar and tabs) starts WindowServer's window drag. At zoom z that
  band is the top band/z native points, so at zoom 0.5 the first rows of a Finder window or a link near the top of a Safari page
  are not drag sources: the takeover above ends the system drag and the canvas moves the window instead, with no payload. Zoom 1
  is unaffected, and so is any press below the band.

Not measured: file promises, Mail or Photos sources, drops on Dock icons, a second display, spring-loaded folders, a physical
pointing device, and the capture desktop. `tests/e2e/compositor-dnd.sh --live-guest pair|band|outside` repeats the fixture part.

## A root whose family cannot be read (the browser's main window "flashing")

The owner's report (build `c49eae1`, Aside, a Chromium browser, compositor mode): the browser "randomly flashes", other applications do not. It was
not the arrival veil. Google Chrome 156.0.8078.80 in the macOS 27.0.1 guests, the same Chromium window machinery, showed it (Aside itself opens on a
sign-in wall and was not driven, so nothing here is an observation of Aside): the main window's translation jumped to a parking position 256 points
beyond its display, and back, so it vanished for a few frames, at random, while the pointer moved over the page. In the run with diagnostics every one of
four parks followed a failed family read, then `native family forgotten`, then `native window parked` with `family_known=0`, within 6 ms (the diagnostic
lines were temporary and are not in the tree). The window server's family of a Chromium window includes windows that, for a few frames, have no parent or no size, so the exact audit
(`discoverOwnedFamily`) fails as a whole. `bound:family:` then forgot the family, and `describe:` placed a root only while `root->familyKnown` when
Space frames are on, so the root got the parking record until the next read. The veil was neither necessary nor a multiplier.

What changed. (1) `describe:` no longer parks a placed root because its family is unknown: it stays at its placement and requests no Space
move (the Space request is what needs the complete family); a root whose display has no Space is still parked. (2) `bound:family:` keeps the
last audited family, with its children placed and its receipt current, when a read cannot be made, for `DWNativeFamilyGraceMS` (500 ms) after that
audit; a report that is readable but names another window, or is unsound, is let go at once, as is one that stays unreadable past the grace.
(3) `-windowNotAdopted:` (above) leaves a window that belongs to a placed root's family to the family for 250 ms before it releases the
helper's veil for it. Regressions:
`DWNativePresenterTests.m` (an unknown family no longer parks its root, a failed read keeps the family, receipt and frame
inside the grace, lets go after it, a report for another window is not a failed read) and `DWPayloadArrivalTests.m` (a placed or released
window announced again is never veiled or written). The helper is unchanged.

## Popups and menus of a transformed window (full-desktop Dock helper)

The gap recorded in [`docs/crates/desktop/POINTER.md`](../../../crates/desktop/POINTER.md#differences-from-upstream) said that popups and menus open
at the native window's place, not where the canvas draws the window. In compositor mode the shell draws nothing of an application's window:
the window server draws it, moved and scaled by the helper's transform, and a popup is only where the canvas draws the window if the helper
transforms that popup too. The measurements were made in the macOS 27.0.1 (26A434) guests with a fixture window and the real TextEdit, Finder,
Safari and Google Chrome 156.0.8078.80.

**What was already true.**

- Every popup the window server names a child of the window (its `SLSWindowIteratorGetParentID` is the root) is a family member, whatever its
  level or alpha: context menus (level 101), pop-up button and pull-down menus (101), the combo box's list, popovers, sheets, child panels,
  completion lists (level 0), Chrome's omnibox list and hover card, Safari's address suggestions. Each is transformed with its root's scale and
  offset: drawn within 1.2 points of expected at zoom 1, 0.75 and 0.5 in every case measured while open with arrival placement off. So the premise
  of the gap, a popup left at the native place for its whole life, was not found for these. `describe:`'s offset (`m[4]-=dx`) and the window
  server's own parent chain agree.
- Input lands where the popup is drawn: with the fixture's context menu at zoom 1, 0.75 and 0.5 a click at the drawn position of item 3 selected
  item 3, the same for the pop-up button, the pull-down and the combo list, and the keyboard (Down three times, Return) selected item 3 at zoom 0.5.
  After a zoom change while the menu was open the popup followed its root within a frame. AppKit tracks a menu with the window server's own
  window-local events, so a transformed menu is hit-tested where it is drawn.
- Not touched, as required: the global menu bar's menus. TextEdit's Window menu opened from the menu bar was a level-101 window with no parent at its
  native place, transform untouched; a popup without a parent is no family member, so nothing here moves it.
- What was wrong was timing, not place. The menu windows are announced already at level 101 and already on screen, which the arrival veil does not
  hold (level 0, alpha 1 only), and sheets, popovers and completion lists are announced at alpha 0 to 0.9 under the application's own fade, which no
  alpha hold can keep. The shell's family frame came 23 to 40 ms after the announcement (announcement to the first row at the placed transform, the
  main-thread path through `windowsChanged:`, a worker observation and a frame), so a popup was on screen where the application put it, not where
  its window is drawn, for this long, and for as long as 81 to 191 ms for a pop-up button menu, a pull-down and a popover.

**What changed.** The helper places such a window itself, at the announcement: *arrival placement*
([`docs/native/dock-helper/Payload/README.md`](../../dock-helper/Payload/README.md#arrival-veil), `v2ArrivalPlace`). A window whose exact parent chain ends at a
root the shell has placed gets the root's transform with its translation moved by the window's native offset from the root, journalled
and read back like any placement, replaced by the shell's first frame naming it (an equal record writes nothing) and released like any
entry if no frame names it within 500 ms. The shell is unchanged apart from a comment: its family path is what claims the window.

With arrival placement none of the 24 newly opened popups measured with the final build was seen at the wrong place (0.0 ms, `placed_err` at most 1.2
points), the popup still followed its root during a zoom while open, and selections, highlights and the keyboard were as before. The probe's
resolution is its poll (about 0.5 ms) and the window list's 3 ms, and nothing there is an optical capture.

**Not established, and what is open.**

- Tooltips: no tooltip window appeared in any run (the fixture's `toolTip` with synthetic hover, in three attempts), so none was measured;
  Chrome's hover card, which is tooltip-like, was. Finder's toolbar menus, Chrome's three-dot menu and Safari's other popovers were not run.
- A popup an application positions from the pointer's *screen* position, not from its window, is displaced: the fixture's pointer-placed
  child panel (native top-left at the pointer, 1037,633 at zoom 0.5) is drawn at 998,710, 39 points left and 77 below the pointer, because the
  family offset is applied to a position that was already in drawn space (the same before and after the change). The standard AppKit
  popups measured derive their place from the window, so they are not affected; which applications place a popup from the pointer is not
  known, and no rule can tell such a popup from its native frame.
- A popup the shell never names within 500 ms (for example one the family audit does not list although the window server calls it a
  child) is released and shows where the application put it, 0.5 s after it opened. No such case was seen; nothing makes it impossible.
- A window the application or the helper has released and the application shows again (a Chromium pool window, an AppKit window
  reused after the shell dropped it) is in the helper's released table and is not placed by this path; the shell's family places it as before.
- Placement waits behind a frame being applied (one case, 26.5 ms). The hover cards Chromium announces at alpha 0.01 were placed at the
  announcement, so their fade now starts in place; whether Chromium's windows that come without a parent for a few frames are placed
  correctly was not separated from the existing family grace.
- Menu bar menus were measured once, in the unchanged build; the final build's arrival path cannot touch a window without a parent (a
  regression case, `DWPayloadArrivalTests.m`), but a live menu-bar run of the final build was not made. Aside, macOS 26, the owner's M5 Pro
  and macOS 27.2, a second display and Spaces were not run, and the real Finder context menu that the owner saw vanish under was not reproduced.
- **Found on the way, not a popup result.** After `quit-native` has restored every window correctly (alpha 1, scale 1, translation minus the
  native origin, read back), `killall Dock` leaves each window the helper ever touched with translation 0,0 and drawn at the top-left corner of
  the display (`cg=0,0,W,H`, `SLSGetWindowBounds` still reporting the native origin); a second `killall Dock` changes nothing, and the next
  helper session then takes that state as the window's original. With a new TextEdit window in a guest: before the helper
  -213,-86, in the session 2.0 scale, after `quit-native` -213,-86, after `killall Dock` 0,0 and drawn at 0,0. The shell's own Dock
  reload path (a `Dock payload reloaded; reconnecting` session) was not exercised here, and the guests' procedure (`quit-native`, `deploy`,
  `killall Dock`) does this to every window left open across it. Whether the owner's Mac does the same when the Dock restarts after
  Infinify has quit is not known.
  *Cause and fix (a later change):* the window server resets the entries a dead connection wrote, and `SLSSetWindowTransform` is
  placement 0, whose entry carries the window's position, so identity there is the corner. The helper now writes placement 1 (a
  relative layer whose reset is harmless) and reads the catenated transform; `docs/native/dock-helper/Payload/README.md`, "Placements", has the
  evidence and what was not run.

## Child windows, hits and cursors in additional display views

`DWNativeReplicaFamilies.m` captures each freshly parented child independently and
orders children by observed WindowServer stacking. Frame metadata supplies the
source pixel crop; native extents are normalized relative to the root for every
display's camera. Separate frame queues avoid waiting behind family discovery.
Capture size/rate changes update existing streams, and downsizing follows the
root's demand hysteresis. Observation and stream-start deadlines reject stale
work, with at most one uncancellable shareable-content request outstanding.
Permission loss, changed ancestry/bounds or retired generations withdraw child
images. The renderer carries image geometry only, includes children in closing
snapshots and window screenshots, and refuses invalid source crops.

Child capture keeps the existing two-second start-completion deadline and allows
two further seconds from successful start for its first fully validated image.
This uses the same bounded interval as existing capture requests; a successful
start alone no longer leaves an image-less stream alive indefinitely. Failures
back off from half a second to thirty seconds with per-binding jitter. At most
two streams start per completed observation, including new identities and
retries. At most four live attempts await a first valid image across the provider,
and at most two belong to one root. These are live-attempt bounds, not a count
of stopped ScreenCaptureKit objects whose asynchronous teardown is unfinished.
FIFO waiting tickets and rotating roots keep persistent eligible children ahead
of later replacements; native draw order is restored before publication. Healthy
streams and configuration updates bypass admission. A lone new child starts
immediately when observed with capacity available. Under saturation it can wait
for occupied slots' two-second start and two-second image budgets, further
observer turns and older eligible children. This tradeoff has not yet been
measured in live popup behavior. A valid first image resets
the failure count. Exact root/member identity, generation and bounds bind the
history and weak attempt watchdogs; stale or missing observations cannot erase
backoff. Only a fresh complete family observation prunes absent bindings, and
history is bounded to 64 records per root. Failure withdraws pixels and child
input eligibility. Diagnostic reasons distinguish no callback from callbacks
without a valid image; metadata rejection remains separate. The focused
`tests/e2e/native-family-recovery.sh` checks substituted lifecycle behavior,
not live capture cadence or native presentation.

Live captured families now share one validated ordering plan with pointer hit
detection. A complete on-screen native stacking observation can interleave roots and
children within one contiguous compositor bucket only when every captured
member matches and the observed root order agrees with the controller. Physical
native placements, stand-ins and closing snapshots are barriers. Missing or
incompatible evidence keeps the grouped order. Semantic order changes refresh
the existing output frames; unchanged video frames reuse the ordering plan.
Input reads that applied description and an exact child key, refusing stale
layout, source bindings, provider revisions or withdrawn images. This is not a
presentation acknowledgement or proof of physical popup behavior. Total stacking
between real windows and replicas and cross-family closing interleaving remain
open; closing snapshots preserve only
the applied relative order within the closing family.

One-shot screenshots now record a separate request-scoped stacking cohort and
opaque child keys, then re-read the complete family, bounds, relative order and
binding before composition. The renderer interleaves only complete ranked
families whose root order agrees with the frozen canvas snapshot. Offscreen or
otherwise unranked families still capture in a stable grouped order and act as
barriers. Stand-ins, widgets and canvas pin exclusion retain their existing
rules. Region clipping follows ordering, and an isolated window includes just
its complete family. Exports do not borrow live-stream ordering evidence.

An observed child can now remain visible in a display view after its root leaves
that viewport. The adapter adds a child-only replica placement using that
display's camera, without expanding the root's world rectangle or choosing it
as a real native owner. Its clipping envelope requests capture and rendering;
only an exact captured child hit can authorize input inside it. Fullscreen and
display-pin isolation still apply. Capture demand, drawing and pointer routing
share the derived presentation snapshot. Family reports are bound to the current
identity, generation, native bounds and session; delayed reports from a departed
or replaced session cannot restore them.

Replica hits retain the captured root generation and exact child identity.
Fresh root ownership and parent checks precede posting. A release returns to the
already-pressed identity even if its native bounds changed; it never retargets
another hit. A click waiting for native focus also retains its original root or
child identity, binding generation and output before focus changes. If the fresh
hit names another recipient, its queued down, drag and release are discarded
together. Source removal, session departure and capture cancellation also discard
pending clicks and their timers. Click navigation waits behind delivery rather than moving the view
while the initial press is pending. Child hover uses the freshly validated recipient even beyond its
root rectangle, while retaining controller pick/grab rules and application-owned
panel focus. `DWNativeTabletRouter.m` preserves physical pen/eraser payloads, pressure,
tilt, rotation and proximity. Admitted contact stays with its original recipient;
cancellation pairs held mouse buttons, pressure release and tool-out. A physical
enter is required for a tool already in proximity at startup. Tablet display
mapping is excluded by the owner's review. Replica cursor-image synchronization
and hardware delivery remain incomplete or unverified.

`DWNativePointerGrab.m` retains the original native root/member and output after
an admitted mouse press. Motion and releases map through that output's current
view even beyond tile/display bounds, without retargeting a different window.
Multiple buttons remain paired independently; cancellation releases the admitted
recipient and consumes the remaining physical tails. Stream failure, source
removal, display rebuild, event-tap disable and session departure cancel the
capture. Forwarded tags bypass the event bridge before physical-pair bookkeeping.
`DWNativeRelativeMotion.m` converts accelerated mouse deltas to application
points with fractional carry; raw unaccelerated fields and tablet data remain
unchanged. This supplies neither application-requested pointer lock/confinement
nor native cross-application drag-and-drop. No physical acceptance is claimed.

`DWCanvasCursor.m` now coordinates Infinify's own pointing-hand cursor for pick
targets, all eight border/drag resize cursors, and a closed hand during mouse
pan/move grabs. Only the actual canvas panel under the pointer can set them;
other applications, the Dock, menus and the chooser retain their cursor. Entry,
coalesced motion, scene changes and release refresh the policy. Session departure
and panel teardown withdraw it, restoring the saved application-local cursor
only while Infinify still owns the override. Unchanged cursor sets are suppressed.
Native-mode hover forwarding is enabled for captured views; physical native
recipients continue to answer `forward: false` and are not reposted. No physical
cursor or hover acceptance has been performed. A foreign application's cursor
image, hotspot, visibility and animation over a replica remain unimplemented;
neither the global cursor getter nor cursor pixels in a capture bind them to the
replica's exact recipient and remapped point.

Audited allowlist helpers bind only verified native roots. The read-only native
family adapter requires an acyclic WindowServer parent chain, one process birth
and finite untransformed bounds for every popup or sheet. Children follow the
root's canvas scale and placement and do not become independent world windows.
An invalid or changed report restores prior children; a removed child restores
its exact original transform and alpha. Creation, appearance and child-change
hints request an immediate serial worker read, coalesced to one follow-up when a
batch is already in flight. Cached associations cannot authorize input: a child
recipient must still pass fresh process, bounds and parent-chain checks. Its
canvas gestures use the root's binding context even outside the root tile.
The same path can be exercised by a cooperative owned host advertising fixture
family capability; this is preparation for broader support, not evidence of
usable third-party popup/sheet compositing. Native one-shot exports make a fresh
audited family plan, capture each member independently without implicit child
flattening, and compose children in their observed order. Normalized image offsets
preserve extents outside the root without changing its canvas geometry. A changed
identity, ancestry, native frame or family membership/order cancels the export.
The upstream target region still decides the crop; family pixels do not expand
the root's world rectangle or its screenshot contract.

Independent floating utility panels remain fixed to their display, as the owner
chose on 2026-10-11. Native discovery accepts the actual floating window level
only when Accessibility confirms `AXFloatingWindow`; no title or size heuristic
admits a panel. Its initial output-local position becomes a canvas screen pin
atomically during attachment. A saved pin retains its saved placement. Panel
arrival does not focus it, fly the camera or invoke root-window opening rules.
The generic canvas pin owns no native coordinates; the adapter supplies the
output and position. Popups and sheets remain members of their root's family.

The owner also chose to retain the application's native stacking and keyboard focus on 2026-10-11. The adapter leaves those with WindowServer and the
application; it does not apply synthetic exclusive focus or panel-level overrides.

Configured mouse gestures can also begin over the real window: the native input
bridge routes pan, world move, resize, center-nearest, actions and modifier scroll
through the same handlers as the canvas. It checks the actual destination window,
current process identity and canvas hit before taking a press. Ordinary app input
is delivered directly by macOS. A taken button's drag and release stay with their
original canvas view; scroll endings and momentum stay with a taken scroll.
Helper loss, a disabled event tap, shutdown and panel replacement cancel grabs.
The bridge uses existing Accessibility/input access and requests no permissions.
AppKit-convertible magnify events from the annotated event tap now enter the
same two-finger pinch bindings over a freshly validated native root or child.
The public all-events mask avoids inventing a private CG event number; keyboard
events and unrelated event kinds return unchanged. Admission is decided once
for each pinch: an unbound pinch stays with the application, and a taken pinch's
remaining phases stay swallowed after cancellation. This is compiled source
support, not evidence that macOS delivers magnify through that tap on the target
host. Raw multi-finger touch delivery over native windows remains open.

Native mouse motion also enters the existing coalesced hover frame/timer path.
At flush, the actual WindowServer recipient is resolved afresh to a current
logical source and binding generation, instead of trusting canvas stacking.
`focus_follows_mouse` can then focus that source in place. Ordinary mouse motion
continues to the application directly; the canvas never reposts it. Independent
floating panels keep their application's focus and stacking.

The native root's origin is a presentation basis, not a canvas position.
Application moves and macOS display reflow update that basis without relocating
the logical window. Native size observations still update its world size.
Canvas gestures and explicitly owned native mouse pairs supply movement intent;
after a native pair settles, its displayed displacement is converted through the
unchanged output and zoom. A display rebuild invalidates old observations and
prevents an existing pair from adopting across the topology change, while its
physical buttons and tails retain their original ownership. Native transform
and alpha restoration remain separate from application-owned native bounds.

## Session, sleep and the green control

Native session watching now includes native windowed runs. Leaving the user
session or sleeping cancels gestures and frame driving, ends helper placement
immediately and drains exact restoration on workers. Physical button-pair
bookkeeping remains until the swallowed down events have had their releases.
On return, worker preparation reuses only launch-time helper endpoints, nonces,
PIDs and birth timestamps. Every helper must authenticate and report its exact
disjoint enrolled scope again, and its probe must report an empty restore table.
Only then does main-thread admission start a fresh watchdog and re-observe
bindings. Retry backoff is bounded at 30 seconds; a stale completion or shutdown
discards its inert candidate. No helper is loaded or process implicitly enrolled.
Windowed canvas panels retain ordinary application ordering on return. Startup
also checks the current console/login state and active, awake main display before
creating outputs, input or discovery. A blocked launch keeps its saved scene and
autostart effects until admission; quitting before admission does not rewrite the
scene. Early wake readiness retries at most twice per second, while notification
holds still require their matching return.

Session sleep, display sleep and leaving the login session cancel canvas grabs,
pending focus and camera flights. A Space notification cannot restart them while
one of those states is still held. The existing system settings remain in charge;
the port requests no power, lock or permission changes. A helper whose lease ends
during sleep ends that presentation session; the separately audited reconnection
path above prepares a replacement session after return.
Screen-parameter notifications rebuild panels only when a display's identity,
full frame, backing scale, cadence or coordinate origin changed. A Dock usable-area
notice retains the existing panel, output and compositor layer. A genuine display
change ends the old frame driver before replacing its layer.

The native green control toggles fullscreen inside the canvas. Option-click
toggles fit, carrying snapped neighbours when `mouse.decoration_fit_snapped`
is enabled. A bounded worker reads the exact root's Accessibility fullscreen
or zoom button; input uses cached window-relative control bounds and fresh
process/native-bound checks. A resized root invalidates that geometry. The
clicked source identity and generation reach the controller directly, so focus
on another window cannot redirect the command. A taken press owns its release;
dragging off the control cancels it. No native fullscreen Space is requested.
`DebugDecoration` requires `--debug-pointer`, native presentation and an explicit
process scope. Its probe reads the actual control; its click calls the bridge
directly without posting input. It cannot establish physical event delivery.

## Screenshots

Native one-shot screenshot capture retries selected transient ScreenCaptureKit setup/connection failures twice, after 80 and 160 milliseconds, within
the original two-second request deadline. Each retry uses a fresh shareable-window list and repeats the existing identity, generation, native
parent-chain and own-bounds checks against the original family plan. Permission and configuration failures remain final; no stream or helper mutation
is added. Successful runtime recovery is unverified.

Native screenshots obtain one-shot ScreenCaptureKit images for the selected
bound windows, then compose those pixels into the canvas export. The PNG uses
the requested canvas scale, but native images have the pixel density of the
transformed window: zoomed-out images contain less detail. No transform is
temporarily undone to obtain sharper pixels. Increasing the requested screenshot dimensions does not fix replica sharpness.
This requires existing Screen Recording access, checks ownership and native size,
and has the same two-second deadline as overlay exports. Preparation returns the
IPC handler immediately and continues through callbacks, so cold capture setup
can use the main queue while other connections remain responsive. Timeout and
shutdown prevent late samples from being installed. Single-window snapshots
ignore display clipping. It creates no capture stream and changes no window
transform or live rendering budget. Without access the screenshot request
returns an error.

After composition, an immutable image moves to a serial worker for PNG compression
and file writing. The IPC reply waits for that write while input and frames can
continue. Offscreen Metal composition and readback still run on main. Requests
remain serialized so only one export image waits for compression.

## Quit and restore

Quit restores each original transform and alpha before the rest of shutdown.
The helper also restores on client loss or lease expiry. A separate watchdog
closes the session if the main run loop stops for ten seconds; protocol threads
never wait for the main thread to release their client. Helper loss is reported
once, leaves the IPC server responsive, and ends native presentation for that
run. Reconnection or a switch to capture is not automatic. See the
[helper's recovery contract](../../dock-helper/Payload/README.md#journal-and-strict-recovery).

Unbinding a live window queues restoration of that window's original transform
and alpha through the helper's negotiated per-window restore capability. Other
bound windows keep their placements. A pending release is retained until its
frame is acknowledged; retries use the helper's journal and recovery path.

A restore that waits for the window to settle: a late AppKit reflow can change the matrices after the helper has released its obligations. Space
restoration therefore remains pending for at least two seconds and until native bounds, membership and original transform/owed alpha stay stable for
500 ms. Samples precede corrective writes so those writes cannot conceal continued drift. Recovery clears a retained forward request to a Space that
has since been removed only when a complete display-Space inventory proves the target absent and the exact window is back on its original Space on
the saved display. Native frame changes remain separately recorded; this does not establish whole-desktop native-frame restoration.

The helper restores the window's original placement-1 layer, which does not depend on the native origin (see "Restore after a native-origin
move" above and [docs/native/dock-helper/Payload/README.md](../../dock-helper/Payload/README.md#the-original-is-the-layer)).

## Known limits

- **No native display-boundary clipping.** No shape write is enabled, because exact original-region snapshot/restoration is not implemented. Real Finder boundary checks excluded its root from
  the adjacent virtual output at the tested right, left, above and below edges; they do not prove arbitrary viewport clipping, child-family behavior,
  physical displays or macOS 26 compatibility..
- **Multi-display is not established.** The runs used a temporary second display in the macOS 27.0.1 guest, never physical displays; broader native
  transfer coverage, full-detail capture at different scales and frame pacing remain incomplete. A window moved to a smaller display can be reflowed by
  its application and not restored to its larger native extent: a Finder window changed from `2056x1130` to `1280x770`, and neither pre-scaling before the
  transfer nor an ordinary oversized Accessibility resize kept the larger size. Preserved world geometry does not establish preserved native content
  extent or detail.
- **A drag from a window's top band below zoom 1 is a window drag.** A press inside the title/toolbar band (about 28 drawn points for a plain title bar,
  52 for Finder's toolbar, 89 for Safari's toolbar and tabs) starts WindowServer's window drag; at zoom z that band is the top band/z native points, so
  at zoom 0.5 the first rows of a Finder window or a link near the top of a Safari page are not drag sources. See
  [NATIVE-DRAG-ROUTING.md](NATIVE-DRAG-ROUTING.md#compositor-mode-dock-helper-drag-and-drop-measured-on-2026-10-30).
- **Drag-and-drop was measured for the listed applications only**, as the section above says; file promises, Mail or Photos sources, drops on Dock icons,
  a second display, spring-loaded folders and a physical pointing device were not measured.
- **Physical input and gestures are unverified.** Raw multi-finger trackpad gestures over real windows, physical delivery of the magnify bridge, replica
  cursor images and hardware delivery of replica input are incomplete or unverified; so are Spaces gathering, native popup placement and ordering across
  applications, and total stacking between real windows and replicas.
- **The Finder window that vanished under a right-click menu in the owner's run was not reproduced**, and Aside, an Electron window, macOS Spaces, tiling on a
  real drag to a screen edge, macOS 26 and the owner's Mac (macOS 27.2) were not run for these sections.
- **Family reads on Chromium.** Whether the 500 ms and 250 ms bounds suit other applications is not known, nor why a family read that fails is not the same read
  that succeeds 4 to 100 ms later (the children Chromium keeps in its window pool come and go). The windows Chromium announces at alpha 0.01 or 0 (hover cards,
  the 22-point window) are not veiled and were still seen at the place the application put them for 2 to 120 ms, with and without the veil, before the
  family placed them. A window the application keeps re-announcing without a parent was never seen with a parent and is untouched. Every number is a
  window-server read, polled, not a frame on a display.
