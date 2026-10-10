# Native resize controller contract (ABI 1 additive)

This module coordinates one bound ordinary window and all eight edges. It emits
requests for a future native shell; it does not call AX, capture pixels, resize
third-party windows, or establish usable compositing. Existing `begin_resize`
remains the logical reducer API. Native group resize is rejected. Pin
and aspect ratio are outside this contract; fullscreen runs this same
transaction ([FULLSCREEN.md](FULLSCREEN.md)). Fit, fill, the step actions, IPC
resize and a window rule's `size` run this same transaction without a drag:
[SIZES.md](SIZES.md) has what they ask for and what they write when its results
arrive. `begin_native_resize` takes no [widget and no screen-pinned
window](RULES.md#navigation-activation-gestures-and-outputs): it answers
`a widget is not moved or resized by hand` or
`a screen-pinned window is not moved or resized by hand`. The sized
transaction is begun for one of those by a single caller, the rule's `size`
the window mapped with ([RULES.md](RULES.md#a-rules-size)); every other
caller has passed it over or refused it first.

## Commands and effects

- `begin_native_resize {window, output, edges, start_screen, group:false}` returns
  a transaction ID and `observe_resize_source` effect. It raises and focuses
  the window first, as upstream's resize press does ahead of its grab
  ([NAVIGATION.md](NAVIGATION.md#activate)): `effect` is the transaction's, so
  the focus request is the one entry of `effects`, where every reply that
  carries a size transaction keeps its focus request. A refused begin focuses
  nothing (the native shell then asks for the focus by itself, with
  `focus`). The host must supply a
  fresh result before any setter; the actual frame size must exactly match
  committed world size. Motion during this asynchronous baseline read is coalesced
  into the existing latest-request slot without committing geometry. Release keeps
  that intent for baseline validation, setter, and final read; cancel drops it.
  Failed or mismatched baselines never dispatch the queued setter. A scaled/mismatched baseline fails explicitly. Beginning cancels
  camera flights on every output.
- `native_resize_to {transaction, screen}` uses absolute screen displacement from
  `start_screen`, divided by start zoom. Live zoom only changes snap distances.
  The primary resize proposal advances snap intent without changing the Scene.
  `latest_requested` and `requested_outline` are presentation hints only.
- `resize_native_window` effects contain size only. There is one pending effect,
  with at most one latest coalesced request. Effects include transaction, effect
  ID, window, exact source identity and binding generation. Resize pending state
  is independent of focus pending state; effect IDs share a monotonic allocator.
- `native_resize_result {transaction, effect_id, identity, generation, result}`
  accepts native/resize/resize.h outcomes/fields: `outcome`, `ax_error`,
  `mutation_attempted`, `observed`, `requested`, `actual_ax`, `actual_cg`.
  AX/CG rectangles must be valid and agree within one point on each coordinate
  and dimension when observed. Contradictory outcomes, stale IDs, generations,
  identities, requested sizes and duplicates reject atomically. The reply's
  `transaction` and `effect` are the next effect to perform. When the result
  ends its transaction that can be the first effect of another one: the size
  transaction of the next window whose rule's `size` is still owed
  ([RULES.md](RULES.md#a-rules-size)).
- `end_native_resize {transaction}` drains the latest request and final read.
  `cancel_native_resize {transaction}` discards unsent intent, drains sent work
  and reads actual geometry. Cancellation does not roll back a native setter.
  Both reject subsequent motion. Removing the transaction's output cancels it
  while retaining reconciliation; any new read effect is returned by removal.

Observed actual dimensions, including clamped/rejected requests, commit to the
single authoritative `Window.world_rect`. Left/top anchoring adds the difference
between last committed and newly observed dimensions to the **current** world
origin. A world drag between release and delayed observation therefore survives.
Actual native origin updates only source observation. No result changes a camera.
Native constraints remain explicitly unknown; no client minimum is inferred.
The existing proposal floor is one point. Out-of-adapter-range requests can be
rejected by the adapter; they do not create committed geometry.

## Uncertainty and lifecycle

An attempted setter without an observation enters `needs_observation`, disables
setters and emits one read-only diagnostic effect. A timed-out attempted setter
also stays uncertain even if a read succeeded: a late mutation remains possible.
This includes AX CannotComplete (-25204), which the adapter preserves in ax_error
even when its subsequent readback produces a settled outcome. The diagnostic
read updates actual geometry when available but cannot establish future
quiescence. There are no autonomous retries or arbitrary read-count completion.
Old observed rectangles remain labelled `observation_known:false` after failed
readback; they are historical data, not current input authority.

Forget, source removal, rebind through removal, and same-handle load are blocked
while a transaction is active or uncertain. Normal recovery is cancel, consume
every pending effect/result, then detach/load. For a genuinely ended native
lifetime the host may call
`retire_native_resize_source {transaction, identity, generation, lifetime_ended:true}`
**after the pending effect drains**. This is an explicit caller attestation,
not proof discovered by this controller. It detaches the source, retains the
world placeholder, invalidates focus authority and records a retired identity.
The same PID/birth/window tuple cannot reattach on this handle, including after
load; a genuinely new process lifetime can bind. Do not use this command merely
because a read timed out or because the UI stopped dragging. A lost result must
still be reported with the correct effect boundary; it cannot be silently erased.

## Capture and input

Dispatching a setter invalidates capture authority. Observed setter results
advance `observation_revision`, as do dimension changes on readback. Placements
then have `presentation_settled:false` and no `buffer_crop`; hit/input reject.
The shell must show an inert placeholder or otherwise withhold stale content.
AX sizes never synthesize capture buffer dimensions. Fresh actual pixels are the
host's responsibility, reported with
`native_resize_capture_ready {window, identity, generation, observation_revision, buffer, content_rect?}`.
The acknowledgement may also include `content_rect`, a finite, positive rectangle
wholly inside `buffer`, expressed in actual buffer pixels. Omission (or null)
means the whole buffer for compatibility with existing callers. Attach and rebind
also begin with the whole buffer. `Source.content_rect` is transient capture
metadata. Placement `buffer_crop` and hit `buffer_local` apply its offset and
scale; hit `local` and `native_screen` still map the full observed native frame,
independently of buffer padding.

The acknowledgement must match the current revision and a valid actual buffer,
with no pending setter or uncertain mutation. The host may invalidate capture
without changing any geometry using
`invalidate_native_capture {window, identity, generation}`. It validates the exact
binding (including owner), advances the checked `observation_revision`, clears
capture authority, and returns `{observation_revision}`. Repeated invalidations
advance again; callers should send them for actual state transitions. Revisions
therefore fence capture invalidation as well as size observations. Earlier
acknowledgements reject atomically, including those omitting `content_rect`.

Legacy `observe` never grants lost capture authority. An unchanged buffer size
and native frame size retain the acknowledged crop, including when native origin
moves. A change to either size resets crop metadata to the new whole buffer.
For a cropped capture or one already using observation revisions, that change
also advances the revision and clears authority; the reset crop stays inactive
until a new exact-revision acknowledgement. Original revision-zero whole-buffer
callers retain their existing synchronous `observe` behavior. Neither path copies
native coordinates into world geometry. Tests synthesize acknowledgements and do
not establish native frame freshness.

## Persistence and evidence

Saves contain only committed scene geometry and existing metadata/output state,
never effects, requests, transactions, capture authority or live source identity.
Fresh loads are detached. Same-handle loads preserve monotonic window/output,
transaction, effect and binding generation counters and retired identity guards.

`tests/native_resize_flow.rs` crosses the exported C ABI. Its hash-verified
original upstream request/clamp and ordinary settlement blocks come from
malbiruk/driftwm `352333a8fa1b22171492d4b71a54102045c9a19d` (GPL-3.0-or-later).
See `tests/resize_upstream/README.md` for the exact mechanical extraction scope.
The original Wayland release/configure/commit machinery does not execute here.
The existing snap oracle remains separate. Floating-point fractional displacement
is still the existing reducer behavior, whereas upstream truncates displacement
to integers; literal fractional parity is unresolved. No full DriftWM/native
macOS behavior parity is claimed.

### Experimental desktop integration (headless evidence only)

The desktop flag `--experimental-native-resize` now connects eight true-edge handles
to the native resize transaction C ABI through a serial adapter coordinator. See
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
