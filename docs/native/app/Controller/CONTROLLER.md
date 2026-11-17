# Typed controller seam

`DWController` owns the in-process Rust controller, transport, snapshot cache and schema interpretation. Internal callers use semantic methods and immutable scene/reply projections; public IPC and persisted scene files retain their existing JSON schemas.

## Equivalence constraints

- A mutation invalidates cached scene state **before** entering Rust, including when Rust refuses it. Queries and focus-policy facts do not invalidate scene sections.
- Projections are lazy views of the decoded dictionary, not an eager scene conversion. Cached scene identity follows the old snapshot identity. Geometry consumers retain the visual scene across a clock-only navigation tick; ordinary scene readers see the new clock.
- Effect equality includes every decoded field, including unknown fields. An effect projected twice from the same reply retains meaningful pointer identity.
- A failed call is `nil` and reports the same status text. Absent fields, explicit nulls and malformed values remain distinct where the old reader distinguished them. Wrongly typed values retain the old `DWTyped` fall-through.
- Controller source identity and generation are logical facts, not native-window authority. Native adapters still validate PID/birth/window/owner and current geometry around native operations.
- `DWSizeTransition` retains its existing lifetime: it is absent before the first panel opens and after cleanup. A size effect arriving without a display in that interval is still dropped; this refactor does not create a longer-lived transition owner.

## Focus ordering

Arrival and native observation are single caller-facing operations. They are not made into an atomic Rust scene transaction: arrival authorization must remain consumed even if attachment fails. Synchronous execution hooks retain the driver epoch advance before ordinary observation commands; restoration retains its existing focus-command, receipt, perform/advance order. The policy rules remain in `docs/crates/desktop/FOCUS.md`.

## Size-presentation validity

The presentation checks validity on its existing display tick. Controller facts are the size transaction id, phase, pending effect and uncertain flag, the window source identity/generation, and the output camera/zoom/screen bounds. Placement screen rectangle and alpha are **presentation** facts (native overlays), not a second controller projection. Native source/session/presenter ownership checks remain in the shell adapter.

## Baseline inventory

Baseline: `d012329`. The read-only investigation counted 151 literal operation fields (61 unique operation names), 49 literal snapshot operations, and 114 Objective-C `call:` message sends (123 broad token occurrences). A broader scene-variable expression counted 129 direct subscripts. These are lexical inventories, not runtime call counts: dynamic builders and injected coordinator blocks must also be migrated. Temporary foundation bridges are migration scaffolding, not the completed interface.

## Hot-path accounting

These are source-level paths, not measured runtime timings. A cached scene read never enters Rust; an invalidated internal scene read uses the existing delta transport, including its existing full-resynchronization fallback.

| Path | Baseline controller work | Preservation requirement |
| --- | --- | --- |
| Navigation tick | One request; a clock-only success patches only the ordinary snapshot clock and retains visual geometry | Same request count and visual identity; lazy wrappers only |
| Hit / input / border | One read-only request; no snapshot invalidation | Same request count; no eager scene projection |
| Render | Zero snapshot requests when cached; one delta read after invalidation | No additional request or whole-scene conversion |
| Gesture update reply | One mutation request; existing reply/effect consumers may ask for the invalidated snapshot | Same consumer order; share the rebuilt scene |
| Hidden resize picture tick | Existing snapshot-backed transaction/source/output read plus presentation placement read | Narrow typed facts on the same tick; placement remains presentation-derived |
| Cached chrome content refusal | No controller calls or snapshot rebuilds (chrome-poll scheduling) | Read cached visual scene only |

Verification for this work is compile-only in the macOS guest. No tests or fixtures are run, written or edited during the architecture migration.

## Completed interface and retained transport

Public consumers depend on `DWSceneController`, `DWInputController`,
`DWNavigationCommands` / `DWNavigationController`, `DWResizeController`,
`DWWindowController`, `DWOutputController`, `DWConfigurationController`,
`DWActionController` and `DWPersistenceController`. Command replies expose
immutable field projections and separated focus, size and shell effects. The
navigation coordinator receives execution hooks, not JSON or a controller handle.
Native identities, capture-site records and family/handoff records remain native
adapter data; `DWControllerNative` is their explicit bridge.

The old `Desktop -call:`/`-call:raw:` and the internal legacy-command shim are
removed. The old query-name allowlist is removed: each semantic method chooses
the query or mutation transport, and Rust classifies owned `Command` values into
`ReadCommand`, `PolicyFactCommand`, navigation ticks, or scene transactions.
Policy facts roll back only policy state on error, without cloning/settling the
scene. Reply stripping is no longer a caller responsibility; exact legacy
continuations (including unknown fields, explicit nulls and raw effect pointer
comparison) are private value-layer transformations.

Stage 2 is deliberately deferred. No new typed FFI is introduced without
behavioral tests. The narrow resize validity API is implemented in stage 1 over
the same cached scene query and same tick, not a new notification or stale
side-cache. Arrival and observation are one typed call from the consumer, with
unchanged underlying fact/command/receipt calls and synchronous epoch hooks.
They are not claimed to be one Rust round trip.

`clock_only` patching and `DWSnapshotMirror` remain, now inside Controller, because
removing them while JSON remains would rebuild geometry on idle ticks or lose
delta transport. The existing C output/source/removal queries remain underneath
typed methods; scene persistence retains its worker-copy C path. External IPC
alone imports `DWController+External`; it keeps raw reply bytes and the existing
JSON request/response forms. Native CLI entry points that do not instantiate the
shell are unchanged.

## Allocation accounting

Source inspection only, not a measured performance claim. JSON decoding,
command dictionaries and existing native/render allocations are excluded.

- New scene: one `DWScene`; no container copy or scene traversal. Shared-section
  seeding performs nine raw pointer comparisons, allocates at most one scene
  projection-cache dictionary, and retains already-materialized shared views.
- Repeated scalar reads/rendering of an already projected scene: zero additional
  typed objects.
- First traversal of changed windows `N`, placements `P`, outputs `O` and lifecycle
  events `L`: one scene, one scene cache, at most four lazy array objects, and
  `N+P+O+L` record objects. For `P=N, O=1`, at most `7+2N+L` Objective-C objects,
  before nested child views/configuration. Index-addressed caches allocate at
  most four C slot buffers totalling `8*(N+P+O+L)` bytes on arm64, on first access.
  Zero-initializing a newly accessed changed array is O(array length), once.
- Each requested child projection adds one object; the first cached child on its
  parent adds one parent-cache dictionary. Scalars and geometry structs allocate
  nothing. This adds `C+D` for `C` child projections on `D` newly caching parents.
- Hit reply plus hit view: three objects (reply, cache, hit), plus two if identity
  is read. Input hit plus binding: four, plus two for a requested primary effect
  (effect/alias list), plus two if its identity is requested.
- Hover reply without an effect: one reply object. With a requested primary
  effect: three, plus two if identity is requested. Navigation effect extraction
  adds one reply-cache dictionary. Plural effects add an array and C slot buffer,
  plus lazily requested effect wrappers, sharing a reply-local alias list.

There are no process-global weak interning tables, boxed array indexes, or raw
container copies in projection construction. Owned mutable overlay/factory
records are frozen once before publication. Effect identity is materialized on
the main queue before native resize worker dispatch; scalar worker reads are
pure. Arbitrary concurrent scene lazy access is not a supported API.

## Test-phase migration (not executed here)

- Navigation coordinator fakes should implement `DWNavigationController` and its
  execution hooks instead of supplying dictionary command blocks. Preserve the
  focus ordering table, failed attach consumption and nil-receipt cases.
- Resize coordinator/driver/presentation fixtures should supply typed size
  effects/results and `DWResizeController`; cover native coercing geometry,
  orphan equality, null pending effects and the display-tick validity facts.
- Canvas/native view/presenter fixtures should construct typed
  values through test adapters or a real in-memory controller; include scene
  pointer identity, overlays, full unknown-field equality and malformed shapes.
- Desktop captured-input/chrome/root-capture tests need typed scene/hit/effect
  fakes; source-slicing assertions must follow the new owner rather than search
  for operation literals. E2E compile lists need Controller sources.
- A later runtime pass must exercise drag/resize, Fill/Restore handoff, arrivals,
  repeated native-family observations, hover/capture, render/config updates,
  screenshots, and raw IPC/persistence compatibility.

No test files were changed by this migration.

## Final source inventory

Recounted against both `d012329` and chrome-poll main `954dd89` (same baseline
counts). Outside Controller:

| Lexical metric | Before | After |
| --- | ---: | ---: |
| Objective-C `call:` message sends | 114 | 0 |
| Literal `op` dictionary fields | 151 / 61 names | 1 / 1 name, external IPC only |
| Explicit snapshot operation literals | 49 | 0 |
| `snapshot/snap/scene/prior/now` direct keyed reads | 129 | 15, all native handoff/wallpaper records |

The IPC completion assignment also names `screenshot_result`; it is deliberately
not an internal semantic caller. Semantic audit found no remaining controller
scene schema reads outside Controller. The residual 15 lexical occurrences are
`prior`/`now` native records, not snapshots. `Desktop` no longer owns
`controllerSnapshot`, `controllerVisualSnapshot` or `snapshotMirror`; its raw
`DriftDesktop *` is replaced by `DWController *`. Removed methods are `call:`,
`call:raw:` and `navigationCall:`. Existing shell scene accessors now return
`DWScene` and do not expose JSON.

The final per-path call/rebuild accounting is unchanged:

| Path | Controller calls before → after | Snapshot rebuilds before → after |
| --- | --- | --- |
| Navigation tick | 1 → 1 | clock-only 0 → 0; same visual identity |
| Hit/input/border | 1 → 1 | 0 → 0 |
| Hover with child ACK | 1 plus conditional 1 → same | same conditional cached source query |
| Render | cached 0 / invalidated 1 → same | cached 0 / invalidated 1 → same |
| Gesture begin/update/end | 1 each → 1 each | same consumer-triggered rebuild |
| Hidden resize picture validity | cached 0 / invalidated 1 → same | cached 0 / invalidated 1 → same |
| Cached chrome content refusal | 0 → 0 | 0 → 0 |
| Protected arrival | fact + attach, 2 → 2 | same command continuation queries |
| Observation duplicate | 1 → 1 | 0 → 0 |
| Bound activation observation | fact + command + receipt, 3 → 3 | same result/answer validation queries |

Allocation and call counts above are code-reading bounds, not measured native
window usability or runtime performance evidence. Compile-only verification
cannot establish behavior parity; the later test phase remains required.
