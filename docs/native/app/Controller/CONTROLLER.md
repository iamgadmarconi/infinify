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
