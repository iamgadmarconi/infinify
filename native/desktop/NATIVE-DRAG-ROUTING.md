# Native drag routing

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

Helper presentation supplies a real native ownership site for each window,
with the canvas panel behind ordinary native windows. A source-to-destination
drag between these real sites can remain with AppKit and WindowServer from
beginning through completion, with no Infinify pasteboard receiver or data
substitute. WindowServer owns the transformed destination's hit testing and
window-local conversion. Whether all third-party destinations correctly accept
that conversion under the helper's transform remains a runtime acceptance
requirement; compilation and transform readback cannot establish it.

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
covered. The former down-triggered source-observation hook has been removed.

This is source implementation, not runtime acceptance evidence. Fresh replica
capture remains blocked in the transformed fixture cases below. The existing
primary-site check does not establish replica handoff, captured-source sessions,
file promises or arbitrary third-party acceptance.

`native-input.m` now leaves an unclaimed original press addressed to a foreign
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
a guest observation recorded in [README.md](README.md#dragging-resizing-and-context-menus-of-a-transformed-window-full-desktop-dock-helper).
The takeover does not put the application's native frame back: WindowServer has already moved it (to where the window was drawn), and the
helper's restore re-bases the window's original transform on the native origin it reads at the write, so a taken-over window is restored consistent
with its frame (README section "Restore after a native-origin move"). A press on the empty strip of a toolbar group (Safari's address-field group,
for example) is the window's, not the application's, so it is claimed as a title press and never becomes a takeover.

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

`tests/e2e/native-drag-drop.sh --live-owned-fixture` creates one ordinary
AppKit window in each of two independent disposable processes. The host requires
a `source` or `destination` role argument; each process starts its own cooperative
binary-v2 helper with exactly its one window allowlisted. Separate private nonce
files authenticate the two runtime endpoints. The grouped native presenter
covers precisely both PID, process-birth and window-ID tuples, checked against
independent native owner connections, and presents both windows at half scale.

The source view accepts the first mouse click and starts a real
`NSDraggingSession` carrying a private file URL. The file's contents are a
separate fresh token; helper credentials never enter the pasteboard. The
independent destination validates those contents and records the complete
entered/prepare/perform/conclude callback sequence and window-local location.
Each process writes its own receipt. The driver requires AppKit's source
outside-application context as well as the distinct independently observed
process identities; it never substitutes destination callbacks or an open-file
command.

Before every input sample the driver checks the full birth/window identity and
native owner of both fixtures and its canvas, then checks the event-eligible
window at that point. Existing scoped benchmark ordering keeps these owned
windows above unrelated apps; no other application is moved or configured.
After quitting Infinify, the driver audits both helpers even if one fails:
independent WindowServer reads and helper INSPECT must match original identity,
owner, transform, bounds, alpha and screen rectangle, with no held/restoring
entries or pending journal. Both fixture processes remain alive until those
checks complete. The shell restores the cursor and bounds cleanup on every exit,
including a partial second-host launch.

The 2026-10-12 cross-process run passed against the packaged `c571a2e` app and
cooperative helper. The two fresh process/window identities had distinct native
owners. AppKit reported an outside-application source context and delivered the
file through the destination's complete callback sequence, with local drop
location `[208,131]` matching the independently observed half-scale hit point.
All 19 posted samples passed the current identity/owner/event-eligibility guard.
Both original native snapshots were restored exactly and both journals were
clear before all three owned children exited. The local evidence is
`target/ipc/native-drag.EekQSH/`, with summary log
`target/native-drag-drop-crossprocess.log`; generated evidence stays untracked.

This establishes the route between two exact owned primary-native AppKit
processes. File promises, arbitrary third-party applications and captured
replicas remain unverified or unsupported as specified above; this check is not
ordinary-application parity evidence.

## Replica capture blocker observed on 2026-10-12

The 2026-10-21 real-app follow-up also failed to obtain scaled content. In the
macOS 27.0.1 UTM guest, a signed Infinify diagnostic captured the exact TextEdit
window at 65% scale for 15 seconds through the reviewed raw capture route with
ignore-deformation enabled. Typing visibly changed the test document, but the
stream delivered zero Complete callbacks or images. It stopped and drained
cleanly. The diagnostic was removed from the app build; local evidence is in
`target/native-content-stream-contract/raw-real-app-20261021/`. It establishes
another negative capture result, not a working replica fallback.

The replica destination scenario stopped before physical input because its root
streams supplied `SCFrameStatusSuspended` without image buffers. Opt-in callback
counts showed that no complete frames reached the mailbox, rather than frames
being discarded there. The scoped run is recorded at
`target/ipc/native-drag.io0qil/`; both originals were restored and both journals
were durably empty before cleanup.

A separate one-process AppKit fixture isolated the capture behavior without
Infinify running. The same continuous desktop-independent window stream delivered
fresh green pixels at its original geometry, suspended while a root-only native
transform displayed the window at half scale, and resumed after exact restoration.
The window remained visible and nonminiaturized, and ScreenCaptureKit continued
to report it active and on screen. Its capture-created child identified itself
as `NSLocalWindowSharingWindow`; it was observed but never transformed. Thus this
is evidence for the root-only fixture case, not every coherent family transform.
The evidence is at `target/ipc/capture-transform.v91h47ub/`.

A second run updated the existing stream's filter using a fresh exact window
record after scaling. Its filter rectangle changed from 320×262 to 160×131 and
the update completed, but the next two seconds delivered no new images. Restoring
the native window resumed fresh complete frames. Refreshing the filter alone
does not fix this case. That run is at `target/ipc/capture-transform.q6ow31n5/`.
Both diagnostics preserved sequence/time provenance so retained pre-transform
pixels could not pass as fresh output. Each independently restored the original
root and verified the complete observed cohort, empty helper state and durable
journal before its owned process exited. No physical input was posted.

A display-style filter including only the exact owned root did produce fresh
complete pixels after its source crop was updated to the transformed screen
rectangle. The 640×524 image retained all four colored corner markers, but the
original half-point stripe contrast fell from 255 to 0.4375: it enlarged the
rendered half-size surface instead of preserving original backing detail. The
capture-created child also changed identity after the crop update, so the
scenario stopped before a restored-capture phase or any input. Cleanup verified
the exact root restoration and empty durable journal, recorded the vanished old
child separately, audited its replacement and reaped the owned process. The
evidence is at `target/ipc/capture-transform.snezhdpr/`. This route has not been
adopted for production replicas because its measured detail loss does not meet
their original-resolution contract.

Selecting `SCCaptureResolutionBest` on the desktop-independent stream also did
not fix the suspension. The untouched root delivered complete marker/stripe
images, its half-scale interval produced one suspended callback and no fresh
image, and exact restoration resumed complete images at the original contrast.
That case used no filter or configuration update and retained the same observed
root/child cohort throughout. Independent restoration and the durable empty
journal passed before the owned processes exited; no input was posted. Evidence:
`target/ipc/capture-transform.elq7irri/`.

A bounded private snapshot diagnostic used the existing four-argument
`SLSHWCaptureWindowList` interface and the exact ignore-global-clip, best-resolution
and full-size options used by
[AltTab at eb63ac1](https://github.com/lwouis/alt-tab-macos/blob/eb63ac15209b754600bacd2f1676fbf870aa7d19/src/events/WindowCaptureEvents.swift).
Installed-host disassembly corroborated the call shape and the CoreGraphics
reexport before either read. The original owned root produced a 640×524 image;
the half-scale read failed the diagnostic's image validation. That failure
code groups several conditions, so it does not establish whether the API
returned no image or another invalid result. The diagnostic stopped there,
restored the exact root and complete surviving cohort, verified an empty durable
journal and reaped every owned process. It posted no input. Evidence and this
instrumentation limit are in `target/ipc/hw-capture-transform.86bsqkcd/`.
No private capture path was added to the app, and this single-read interface
has not established fresh backing pixels or sustained rendering performance.

A subsequent diagnostic enrolled both the exact owned root and its stable
`NSLocalWindowSharingWindow` child before applying a coherent half-scale family
transform. Independent reads verified each member's matrix and screen rectangle.
The continuous desktop-independent stream still delivered no fresh complete image
and one suspended callback during the two-second transformed interval, including
after an explicit orange marker redraw. Exact restoration resumed 65 complete
images with the new violet marker, correct orientation and original stripe
contrast of 255. This rules out the untransformed sharing child as the sole cause
in this owned case; it does not establish behavior for arbitrary applications.
Both members restored exactly, the durable helper journal was empty, capture
stopped and every owned process exited, with no physical input or cursor change.
Evidence: `target/ipc/family._uzx79v4/`. The earlier attempt stopped before native
mutation because its Unix socket path was too long; the retry used a shorter path
and a byte-length preflight. No production capture path changed.

The production hover handoff requires actual fresh replica pixels. The old
down-triggered observation probe has been retired. Neither these diagnostics nor
successful capture startup validates a replica handoff or a captured-source drag
session.
