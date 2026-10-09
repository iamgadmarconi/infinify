# Controller focus and cycle boundary

This is a controller selection slice, not complete Alt-Tab. The native shell's
[experimental navigation path](../../native/desktop/README.md) connects camera
animation, focus dispatch and observed native focus. That integration has headless
checks; live focus and shortcut delivery remain unverified. No command here alone
changes a native app or proves compositing.

ABI_VERSION and SAVE_VERSION are independently fixed at 1. Existing `focus`
updates logical intent and raises the window. Its response now contains `effect`,
which is null for a detached placeholder, or a `focus_native_window` request:
`effect_id`, `window`, exact `identity` (including birth time and optional owner),
and binding `generation`. The adapter must revalidate before mutation and obtain
independent native readback before reporting success. An API return code alone
must not become `success: true`.

Additive ABI 1 commands:

- `cycle_focus`: required `backward` and `held` booleans. Selects and raises from
  frozen confirmed MRU history. Returns an effect, if a target exists. The first
  step selects index one even when backward, matching upstream; subsequent
  backward steps wrap. A focused placeholder outside history starts at its head.
- `end_focus_cycle`: commits an already confirmed current selection. If its
  request is pending, waits for that exact result. A modifier-less cycle
  (`held: false`) uses the same release behavior.
- `cancel_focus_cycle`: discards the cycle and invalidates its pending request.
- `focus_lost`: reports that native focus left the tracked window set. Clears
  native observation and pending effects and cancels the cycle, preserving logical
  intent and confirmed history.
- `focus_result`: required `effect_id`, `window`, `identity`, `generation`, and
  `success`. This is an adapter observation report, not controller proof of native
  focus. Only the current exact pending effect is accepted. Failure preserves the
  previous observation, changes no MRU entry, and cancels unresolved cycle commit.
- `observe_focus`: required `window`, `identity`, `generation`. Reports external
  native focus with current binding authority, terminates the old cycle, raises
  and promotes the newly observed window, and supersedes pending effects.

`snapshot.focused` remains the logical-intent alias. `snapshot.focus` exposes
`intent`, `observed_native`, `pending_effect`, `last_result`, `history`, `cycle`,
and `release_pending`. Attached sources expose their generation. There is only
one authoritative pending effect; an effect returned earlier becomes stale when
superseded. Snapshot reads do not allocate or acknowledge effects.

Ordinary focus first ends the old cycle, committing only a successfully confirmed
current selection; its own promotion waits for confirmation. Removing unrelated
windows clamps Stage's index exactly as upstream. If removal makes that index
refer to a different window, release cannot commit an unconfirmed replacement.
Losing the selected or observed binding cancels the cycle and pending effect.
Rebinding always allocates a new generation, even for identical source bytes.
All state is value-owned and cloned inside the existing command transaction.
Rejected commands preserve scene, bindings, MRU, counters, and pending effects.

Version 1 persistence explicitly retains the scene keys `windows`, `outputs`,
`focused`, and `bookmarks`. It preserves f64 geometry, order, and logical IDs.
Bindings, observed focus, history, cycles, effects, and results are absent and
empty after load. Same-controller `load` preserves monotonic effect/generation
counters so delayed pre-load reports cannot collide after identical rebinding.
New controller handles have independent request namespaces; reports must never
be routed to a different handle.

Modal parent relationships, widget/pin eligibility and fullscreen exclusion are
not represented by this slice. It deliberately neither infers relationships from
titles/PIDs nor claims those modes are supported. A future verified relationship
surface must apply upstream modal redirection and its ten-hop limit before native
focus and history selection. Camera navigation has a separate controller contract
and an experimental native-shell integration. Tests here use synthetic observations
through the actual exported C ABI and establish only these controller contracts.
