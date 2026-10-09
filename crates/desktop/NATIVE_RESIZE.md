# Native resize controller contract (ABI 1 additive)

This module coordinates one bound ordinary window and all eight edges. It emits
requests for a future native shell; it does not call AX, capture pixels, resize
third-party windows, or establish usable compositing. Existing `begin_resize`
remains the logical reducer API. Native group resize is rejected. Pin, fullscreen,
fit/fill placement ownership and aspect ratio are outside this contract.

## Commands and effects

- `begin_native_resize {window, output, edges, start_screen, group:false}` returns
  a transaction ID and `observe_resize_source` effect. The host must supply a
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
  identities, requested sizes and duplicates reject atomically.
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
