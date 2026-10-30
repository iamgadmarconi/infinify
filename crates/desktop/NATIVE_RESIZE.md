# Native resize controller protocol (ABI 1)

This module coordinates one bound ordinary window and all eight edges. It emits
requests for the native shell; it does not call AX, capture pixels, resize
third-party windows, or establish usable compositing. Existing `begin_resize`
remains the logical reducer API. Native group resize carries the snapped
cluster, while a rule's aspect ratio is kept instead ([Pointer resize](#pointer-resize)). Fullscreen uses the
same transaction ([FULLSCREEN.md](FULLSCREEN.md)); sizing actions and rules
are described in [SIZES.md](SIZES.md). Widgets refuse manual resizing.

Screen-pinned windows accept edge, bound-button and resize-gesture grabs in
output-local points, independent of canvas pan and zoom. Their native observed
size is authoritative. They neither snap nor carry a cluster, and left/top
commits derive the pin from its original anchor and observed size to retain the
opposite edge. Each result rounds the absolute position, avoiding accumulated
fractional drift. Independent pin movement before a delayed result rebases that
anchor and is preserved.
A delayed baseline rebases the grabbed edge just as for a canvas window.
The pin remains on its original output; another output cannot begin the grab.
Output removal cancels input while outstanding native results still drain.
Logical `begin_resize` remains a canvas operation; native pinned resizing uses
`begin_native_resize`.

## Commands and effects

- `begin_native_resize {window, output, edges, start_screen, group:false}` returns
  a transaction ID and `observe_resize_source` effect. It raises and focuses
  the window first, as upstream's resize press does ahead of its grab
  ([NAVIGATION.md](NAVIGATION.md#activate)): `effect` is the transaction's, so
  the focus request is the one entry of `effects`, where every reply that
  carries a size transaction keeps its focus request. A refused begin focuses
  nothing (the native shell then asks for the focus by itself, with
  `focus`). The host must supply a
  fresh result before any setter. A different observed baseline is adopted
  with the world top-left kept and the pointer anchor rebased. Motion during this asynchronous baseline read is coalesced
  into the existing latest-request slot without committing geometry. Release keeps
  that intent for baseline validation, setter, and final read; cancel drops it.
  Failed baselines never dispatch the queued setter. Beginning cancels
  camera flights on every output.
- `native_resize_to {transaction, screen}` resolves the absolute screen point
  through the current output camera and zoom and measures it from the canvas
  point grabbed at `start_screen`. A camera or zoom change during a grab keeps
  the pointer's offset from the moving edge. Live zoom also changes snap distances.
  The world anchor keeps its origin and local offset separately, preserving a
  fractional press at distant camera coordinates.
  The primary resize proposal advances snap intent without changing the Scene.
  `latest_requested` and `requested_outline` are presentation hints only.
- `resize_native_window` effects contain `requested:{width,height}` and
  `native_origin`, either `null` for ordinary sizing or `{x,y}` in native global
  screen points for a fullscreen frame restore. An `observe_resize_source`
  effect has both fields `null`. The native origin is never a world coordinate
  or a camera projection. There is one pending effect, with at most one latest
  coalesced request. Effects include transaction, effect ID, window, exact source
  identity and binding generation. Resize pending state is independent of focus
  pending state; effect IDs share a monotonic allocator.
- A fullscreen-enter setter additionally carries `native_action:"fill"`.
  This is an optional preference for an app-owned same-Space Fill action, not
  macOS fullscreen or an authorization to target another window. A capable
  native shell may elect that action; the requested size and observed-result
  validation remain unchanged. Reads, ordinary sizing and exact frame restores
  omit it. Retargeting an unsent enter to an exit clears the preference; an
  already outstanding action must drain before restoration. This metadata
  alone does not establish an available native action or animation behavior.
  The desktop native shell elects `dw_resize_fill`, resolving the app's exact
  `_zoomFill:` menu identifier with focused-window identity checks. Only
  `unsupported` with `mutation_attempted:false` permits an ordinary size-setter
  fallback; an attempted press or uncertain lookup never does. The presenter
  withholds the root's whole family from helper frames and retains its restore
  journal. Before ordinary Fill, the driver waits at most 0.5 seconds for a newer helper
  ACK confirming that omission; the adapter then has its existing 2-second
  deadline. During this handoff input cannot use intermediate geometry. Final
  placement requires a new family ACK. Headless dispatch/ACK checks do not prove
  that a third-party application's Fill animation is visually preserved.
  Aligned native/displayed frames (within one point) go directly to Fill.
  A translation-only, same-extent source with a freshly audited root-only family
  can now rebase its native origin to its displayed origin first. The original
  controller baseline remains the restore target. One `AXPosition` call has a
  350ms adapter limit, <=50ms AX timeouts, and a final local deadline check.
  `SLSDisableUpdate`/`SLSReenableUpdate` bracket this position write and a neutral
  helper transform: an exact APPLIED ACK, followed by a newer omission ACK,
  is required before the hold ends and Fill begins. All preparation shares a
  750ms deadline; the hold is capped at 650ms. An independent watchdog releases
  an acquired hold even if the AX worker or main queue stalls. Failed acquisition
  never enables an unknown hold; late successful acquisition immediately releases
  without AX. The synchronous private acquisition call itself is not cancellable.
  Failure preserves normalization mutation/timeout evidence and refuses Fill;
  no temporary ACK grants input or releases the helper's original journal.
  Scaled root-only presentations instead use a fresh raw ScreenCaptureKit image
  and a noninteractive AppKit panel. Before native mutation, the helper must
  acknowledge alpha-zero, then a neutral transform, then omission. The snapshot
  owns the visible AppKit frame animation; it survives native reveal until normal
  placement is acknowledged. These handoffs allow 2.5 seconds for preparation and
  seven seconds for the resize coordinator. Restore waits for the same hidden
  acknowledgement and sets the saved frame directly, without native Unfill:
  real TextEdit trials showed its animation could overwrite an exact correction
  after successful readback. AppKit's final panel frame may round each edge by
  less than one screen point; the native target retains the exact canvas mapping.
  Attached families and unavailable capture retain the ordinary size path.
  The private signatures and bracket precedent are pinned to yabai
  `dd845723416f5fe92af49fad5ebab00369e07edd`, `src/misc/extern.h:23–24` and
  `src/window_manager.c:618–699`; that implementation also uses proxies and a
  separate connection, so it does not prove this app-connection rebase is atomic.
  Actual TextEdit Fill from an aligned start was sampled without an offset jump;
  a translated start previously retained the old offset through the animation
  (`target/native-vm/real-desktop-20261021/textedit-fill-frame-samples.jsonl`).
  VM validation on macOS 27: two consecutive TextEdit cycles at 65% zoom restored
  native frame, world position/size, camera, zoom and displayed transform exactly;
  the recording shows the AppKit snapshot animation. A translated TextEdit cycle
  at 100% used native Fill and restored exactly. Already-screen-sized Safari at
  65% also restored exactly, with both animation/reveal handoffs acknowledged;
  its final recorder stalled, so that run is geometry/handoff evidence only.
  Evidence is under `target/native-vm/real-desktop-20261021/` (`hidden-textedit-*`,
  `live-unit-*`, `live-safari-*`). Physical title dragging was manually confirmed
  stable in the VM, including zoomed-out TextEdit and Finder. Physical double-click,
  attached families and broader application coverage remain separate checks.
- `native_resize_result {transaction, effect_id, identity, generation, result}`
  accepts native/resize/resize.h outcomes/fields: `outcome`, `ax_error`,
  `mutation_attempted`, `observed`, `requested`, `actual_ax`, `actual_cg`.
  AX/CG rectangles must be valid and agree within one point on each coordinate
  and dimension when observed. An `applied` result for an effect with
  `native_origin` must also place the AX origin within one point of that target
  on each axis. Contradictory outcomes, stale IDs, generations,
  identities, requested sizes and duplicates reject atomically. The reply's
  `transaction` and `effect` are the next effect to perform. When the result
  ends its transaction that can be the first effect of another one: the size
  transaction of the next window whose rule's `size` is still owed
  ([RULES.md](RULES.md#a-rules-size)), or the fullscreen frame restore after a
  cancelled transaction finishes draining.
- `end_native_resize {transaction}` drains the latest request and final read.
  `cancel_native_resize {transaction}` discards unsent intent, drains sent work
  and reads actual geometry. Cancelling a fullscreen enter ends the fullscreen
  and queues restoration of its saved frame after sent work drains. Cancellation
  itself does not roll back a native setter.
  Both reject subsequent motion. Removing the transaction's output cancels it
  while retaining reconciliation; any new read effect is returned by removal.

Observed actual dimensions, including clamped/rejected requests, commit to the
single authoritative `Window.world_rect`. Left/top anchoring adds the difference
between last committed and newly observed dimensions to the **current** world
origin. A world drag between release and delayed observation therefore survives.
Actual native origin updates only source observation. No result changes a camera.
Fullscreen records the enter's fresh native baseline separately from the world
top-left and camera. Its exit requests that native origin and the exact baseline
extent, including fractional dimensions, except that an explicit rule's deferred
`size` still takes precedence. A delayed enter baseline can update the restore
target after fullscreen has already ended, without dispatching the abandoned
fullscreen setter. See [fullscreen restoration](FULLSCREEN.md#leaving).
Native constraints remain explicitly unknown; no client minimum is inferred.
The existing proposal floor is one point. Out-of-adapter-range requests can be
rejected by the adapter; they do not create committed geometry.

## Uncertainty and lifecycle

An attempted setter without a trustworthy observation emits exactly one
read-only diagnostic effect. Its result ends the transaction: complete when
it observed the window, committing that actual size, otherwise failed with
`the window did not answer the size request in time`. This includes AX
CannotComplete (-25204). A setter may land later; that is an external native
size change, adopted by the next `observe`, rather than a promise that a
successful read proved future quiescence.

A fullscreen native-frame restore retains its obligation through the final read.
A wrong origin or failed final read leaves it owed for a later carrier, subject
to the three-transaction restore limit. Retrying always starts with a fresh read,
even when cached source geometry matches; a matching fresh frame ends without a
setter. Controller acceptance of these reports is not independent native evidence.

The shell answers an effect after three seconds if its adapter did not. It
reports `timed_out`, unobserved, and `mutation_attempted:true` for a setter.
Late completions cannot answer a discharged effect. An invalid adapter result
is replaced once with that unanswered result; if the controller rejects both,
the obligation is discharged and the orphan watchdog resolves its transaction.
A held grab resting without an effect is not an orphan.

Forget, source removal, rebind through removal, and same-handle load are blocked
while a transaction is live. Cancel drops unsent intent and drains every effect
already sent. No lifetime attestation command or retired-identity cache remains.

## Presentation and input

Resizing does not acknowledge or invalidate captures. The last observed native
rectangle remains the input mapping while a request is owed; observed actual
sizes commit immediately, and unobserved results retain that mapping. A bound
source carries `observation_known` as its mapping-validity marker. Placement
`presentation_settled` derives from that marker; a detached source has no
picture or input binding. The shell still validates current identity, process
birth, generation, native membership and actual image geometry before native
input or replica publication.

`observe` updates the observed native frame and buffer dimensions. With native
resize capability enabled, it adopts a native size that changed since the prior
source observation, with the world top-left kept, except during a gesture.
`observe_presentation` has the same identity, rectangle, buffer validation and
resize-transaction fences, but updates only the source/buffer basis. The native
adapter uses it for reflow caused by its own Space handoff, preserving canvas
geometry. An identical later `observe` does not undo that preserved world size;
a subsequent genuine native size change still adopts normally. The unchanged
observation fast path accepts an intentional world/native size mismatch only
when all its existing idle, gesture, policy and lifecycle guards pass.
Buffer coordinates stay independent of native coordinates.
Actual ScreenCaptureKit pixel crop, timestamp and image-generation
checks remain in the native capture adapters; no reducer acknowledgement
establishes pixel freshness. The retired `native_resize_capture_ready` and
`invalidate_native_capture` commands, and their revision handshake fields, are
absent from the strict pre-release schema.

## Persistence and evidence

Saves contain only committed scene geometry and existing metadata/output state,
never effects, requests, transactions, capture authority or live source identity.
Fresh loads are detached. Same-handle loads preserve monotonic window/output,
transaction, effect and binding generation counters.

`tests/native_resize_flow.rs` crosses the exported C ABI. Its hash-verified
original upstream request/clamp and ordinary settlement blocks come from
malbiruk/driftwm `df3de27b26c7998e8a460cffd8a4925cbed3a322` (v0.21.0,
GPL-3.0-or-later; they were byte-identical at the earlier pin
`352333a8fa1b22171492d4b71a54102045c9a19d`).
See `tests/resize_upstream/README.md` for the exact mechanical extraction scope.
The original Wayland release/configure/commit machinery does not execute here.
The existing snap oracle remains separate. The native transaction cuts the
displacement to whole units toward zero on each axis, as upstream's `as i32`
does, and holds the pointer inside its output; the logical reducer
(`begin_resize`, `gesture_to`) still takes the fractional displacement. No full
DriftWM/native macOS behavior parity is claimed.

## Readback mode

`{"op":"native_resize_capability","enabled":true}` announces that the shell
performs native readback effects. `enabled` must be a boolean. There is one
supported resize protocol: the old `readback` field and alternate capture mode
are rejected, with no default conversion or compatibility alias.

The native window is the authority for its size. A differing baseline is
adopted, including when a window changed itself before a poll. A baseline that
already has the requested size ends without a setter. `observe` similarly
adopts a newly changed native size outside a gesture and answers `{"resized":true}`;
a repeated presentation basis is not a size change.

Every new request asks a window again after `unsupported`: a sheet may have
closed or its size attribute become settable. No persistent disabled cache
blocks later requests. IPC `resize` and a rule's `size` preserve the center for
the size actually granted: `position + (current - granted) / 2`. That granted
size becomes the basis of the next request. Accessibility supplies no declared
client limits, so a repeated request beyond a window's maximum may be sent
again and leave the same actual geometry.

While a transaction is live the controller refuses `observe`, `observe_presentation`, `window_closed`,
`remove_source` and `forget` for its window; another window's size request is
refused while the first owns the slot. The shell's `busyWindow` and bounded
watchdog enforce this lifecycle without waiting for a frame.

Scenarios: the supported readback cases in `tests/sizes_flow.rs`,
`tests/fullscreen_flow.rs`, `tests/native_resize_flow.rs`, the headless native
coordinator and standalone metadata oracle in `native/desktop/resize-regression.m`,
and real owned fixture paths `tests/e2e/scoped-sizing.sh`,
`tests/e2e/scoped-resize-drag.sh`, and `tests/e2e/physical-resize-edge.sh`.

### Pointer resize

In readback mode `begin_native_resize`, `native_resize_to` and
`end_native_resize` are upstream's resize grab
(`src/grabs/resize_grab.rs`, `start_compositor_resize_with_edge`,
`handle_resize_commit`): the one a press bound to `resize-window` or
`resize-window-snapped` starts, a left press on the
[resize border](POINTER.md#the-resize-border), and a [resize gesture](GESTURES.md). It is the
transaction above, so there is one at a time and each ends in bounded time.

- **Begin.** `edges` may be left out: the edge is then where `start_screen`
  falls in the window, by upstream's `edges_from_position` (a 3×3 grid, `<`
  and `>` at the thirds, the centre resizing from the bottom right). Every
  refusal stands ahead of every side effect, as upstream's bails do; then the
  window is raised and focused, every flight is cancelled, fit and fill end,
  and one baseline read is emitted. No size is asked before motion.
  A previous unsupported result does not refuse: the window is asked again.
- **Motion.** The pointer is held inside the grab's output,
  `[0, w-1] × [0, h-1]`. The delta is the pointer's current canvas point minus
  its canvas anchor at the press, each axis cut to a whole number toward zero
  after normalizing floating-point projection roundoff at an integer. Left and top subtract it, right
  and bottom add it, the floor is 1, and the size is snapped by
  `Scene::resize_proposal`. With a rule's `preserve_aspect_ratio` the ratio
  the window has at the begin bends the size instead (`constrain_to_ratio`: an
  edge drives its own axis, a corner the axis that moved farther relative to
  the ratio), and there is no snap and no cluster.
- **One request at a time.** While an effect is owed, motion only replaces the
  one latest request; when the result arrives the latest is asked. A size is
  not asked when it is the size committed, or the size of the last setter
  sent: upstream configures a client only when the size differs from the last
  one it configured, so a window resting at a limit is not asked the same
  refused size again by motion that does not change it.
- **Commit.** The size read back is the size shown, whatever was asked. For a
  left or top edge the world origin moves by `committed − granted` on that
  axis, upstream's commit-time compensation, so the opposite edge stays on the
  canvas. The native window's own top-left is never written for this: a size
  write keeps it, and the native origin stays observation-only.
- **Cluster.** With `group` the windows snapped to the moving edges are
  captured at the begin (`Scene::begin_resize`) and translated at each commit
  from the granted rectangle (`Scene::resize_settle`); they are never resized
  and their native windows are not touched. A port decision: the cluster
  follows the size granted, one request behind the pointer, because a Mac
  window's limits are not known before asking. Upstream clamps to the
  client's declared limits ahead of its cluster step and ends in the same
  place.
- **A baseline that differs** is adopted as above, and the snap state, the
  cluster and the ratio are taken again from the adopted size. Its actual
  right/bottom edge shift rebases the pointer anchor, so queued motion retains
  the press's original offset from the moving edge instead of jumping by the
  baseline size difference. Left/top are unchanged by the baseline's top-left
  adoption. Every later size still comes from native readback.
- **End.** `end_native_resize` lets the latest request through and reads the
  window once more; the canvas then has the size the window has.
  `cancel_native_resize` drops what was not yet sent. Upstream has no cancel
  key for a resize and neither has a normal run.
- **What ends it without a release.** A window that is not settable answers
  `unsupported`: the transaction is cancelled, one read follows and it ends
  `failed`; later motion and the release are refused and change nothing. A
  window that closed or whose application does not answer ends it by the
  unobserved result of the next effect, as above; the shell cancels a grab
  whose pointer rests when it finds the window gone. The grab's output being
  removed cancels it.
- **While it lasts** every other size request is refused: a sizing action, a
  fullscreen toggle, an IPC resize of any window, a second begin.

Where a Mac window cannot follow upstream's client: its minimum and maximum
are unknown until a size past them was asked and refused (about 120 ms each
by the adapter's polling constants, not measured);
macOS grants no size past the screen's visible area; its own top-left does
not move for a left or top drag, so only the tile on the canvas keeps the
opposite edge; and what is drawn lags the pointer by one request, since the
canvas shows the size the window has, not the one asked.

Scenarios: `readback_grab_*` in `tests/native_resize_flow.rs`, the resize
swipes of `tests/gesture_flow.rs`, the ratio in `tests/rules_flow.rs`, and on
fixture windows `tests/e2e/scoped-resize-drag.sh`.

### Historical experimental desktop integration (headless evidence only)

The flag, orange-handle UI, executable live probe and unused capture-ack
protocol were removed on 2026-10-12. The following account is historical; its frozen evidence and
source provenance remain unchanged. It did not establish completed native
resize and independent pixel proof. The standalone synthetic frame-metadata oracle
and read-only saved-byte oracle remain.

The retired desktop flag `--experimental-native-resize` connects eight true-edge handles
to the native resize transaction C ABI through a serial adapter coordinator, in
the capture-acknowledged mode. It gates only those handles: the sizing actions,
IPC resize, a rule's size and fullscreen run without it, in
[readback mode](#readback-mode). See
`native/desktop/README.md` for dispatch, capture metadata, provenance, lifecycle,
and exact unrun native boundaries. `dw_resize_apply_guarded` preserves the original
`dw_resize_apply` wrapper while allowing a fresh root-only family policy veto before
the setter. A veto returns Unsupported with the real preflight observation and
`mutation_attempted=false`; this is policy refusal, not an AX capability finding.
Ownership/deadline are rechecked after the family query. No frozen live fixture
receipts or hashes were replaced; this guarded path has no live validation yet.

### First run on real windows, 2026-10-10

The owner's first run with the flag on real application windows (three Chrome
windows, two Electron applications, a terminal; one 2056x1329 display at 2x)
showed every adopted window as an empty tile, and every click refused with
`source presentation unsettled`: no capture was ever acknowledged for any of
them. Which check refused them is not known. The coordinator gave no reason,
and nothing in that run recorded one, so two things changed, neither of which
is the gate (the flag is as opt-in as it was, and a window still shows no
picture that was not acknowledged against its observed geometry):

- **One comparison was wrong by this contract's own terms.** A result is
  accepted when `actual_ax` and `actual_cg` agree within one point on each
  coordinate, and `actual_ax` becomes `observed_rect`. The coordinator then
  required the root extent, which is the WindowServer's rectangle, to equal
  `observed_rect` exactly, in `-validate:` and in `-accept:…`. A window whose
  two rectangles differ by a fraction of a point could therefore get no
  frame acknowledged, and no input, for as long as its transaction was
  unresolved. Now the extent matches when it is exactly `observed_rect`, or
  when it is within one point of it on each coordinate while a resize
  transaction of that window is unresolved. At rest the comparison is exact
  as before, and a difference of any size is still a native move that is
  mapped again with `observe`. This cannot be what refused the six windows:
  a freshly adopted window's `observed_rect` is the WindowServer's rectangle
  too. It is fixed because it is wrong, and the headless regression covers
  it (`disagreeing()` in `native/desktop/resize-regression.m`: it fails
  without the change).
- **Every refusal now has a reason a person can read.** The coordinator
  records why the last frame it was offered for a window was not
  acknowledged (`-refusal:detail:`): `family` (no root-only extent, with the
  family query's own account: how many native windows are in the family, or
  its error), `geometry` (the extent and `observed_rect`, both printed),
  `metadata` (the first check of the frame's own description that failed,
  with the values: status, display time against the cutoff, scale factors,
  the screen rectangle against the extent, the content rectangle against the
  extent and the buffer), `stale frame` (displayed before the cutoff, by how
  many milliseconds), `refused` (the controller did not take the
  acknowledgement) and `not installed`. The reason is forgotten when a
  capture is acknowledged and when the observation moves on. The shell adds
  three of its own: `stream` (the capture stream failed, with its error,
  which was silent before), `unobserved`, and `no frame` (none offered in two
  seconds). It prints one stderr line per window per change of reason, once
  the reason has stood for two readings half a second apart:
  `capture of #7 (com.google.Chrome) not acknowledged: family — no root-only
  extent: 3 native windows in its family (the window and 2 attached to it)`.
  A press on such a window says the short reason instead of `source
  presentation unsettled`: on stderr, since a normal run draws no status line
  (until 2026-10-10 it was shown there).

What reading suggests, without deciding it: `-rootExtent:` answers only for a
window that is alone in its native family, and an application window with any
attached child window is refused as `family` by design; a still window gets
one frame per configuration update, so a first frame refused for any reason
may be the only one (`stale frame` or `no frame` would then stand); and the
frame's screen rectangle must equal the extent exactly. The next run's stderr
says which. None of this was run: the build has no Screen Recording grant
from an agent's shell.

The capture rate of this path is unchanged, 30 frames a second at most, where
a window captured without the flag now follows the display's refresh rate.
Every frame offered to `-accept:…` is judged on the main thread: a controller
snapshot for every bound window in `-sync` and several more, and a
`-rootExtent:` family query, before the frame's own description is read. One
snapshot round trip was measured in review at about a quarter of a millisecond
with six windows (headless, against the release controller), so a refused
frame costs a few milliseconds of the thread that also serves hot keys, input
and the frame callback, and 120 frames a second from each redrawing window
would have been four times the 30 it was. The rate can follow the display
once a frame costs one snapshot instead of one per window.
