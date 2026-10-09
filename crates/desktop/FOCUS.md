# Controller focus and cycle boundary

The controller keeps three things apart: logical focus (the intent, which
raises a window at once), the request it hands the native adapter (`effect`),
and what the adapter or the shell's own observation reported back. The
[native shell](../../native/desktop/README.md) is the consumer: it performs
effects, reports results, and says which launches do so. No command here alone
changes a native app or proves compositing, and none of this crate's tests
exercises live focus or shortcut delivery.

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
- `end_focus_cycle`: commits a current selection whose request has already been
  answered, by a confirming `focus_result` or by `focus_logical`. If its
  request is pending, waits for that exact answer. A modifier-less cycle
  (`held: false`) uses the same release behavior.
- `cancel_focus_cycle`: discards the cycle and invalidates its pending request.
- `focus_lost`: reports that native focus left the tracked window set. Clears
  native observation and pending effects and cancels the cycle, preserving logical
  intent and confirmed history.
- `focus_result`: required `effect_id`, `window`, `identity`, `generation`, and
  `success`. This is an adapter observation report, not controller proof of native
  focus. Only the current exact pending effect is accepted. Failure preserves the
  previous observation, changes no MRU entry, and cancels unresolved cycle commit.
- `focus_logical`: required `effect_id`, `window`, `identity` and `generation`,
  the fields of `focus_result` without `success`. The answer of a shell that
  performs no native focus in this run (no Accessibility access, or
  `--no-native-focus`). Only the current exact pending effect is accepted; any
  other is refused as `stale or superseded focus result`. It settles the request
  by logical focus alone: the window enters the focus history as a confirmed
  focus does (a cycle in progress keeps the history frozen), a release that was
  waiting for the answer commits, and `observed_native` is left as it was.
  `last_result` records `success: false` and `logical: true`. It is not for a
  request an adapter tried and failed: that is `focus_result` with
  `success: false`, which cancels the cycle.
- `observe_focus`: required `window`, `identity`, `generation`. Reports external
  native focus with current binding authority, terminates the old cycle, raises
  and promotes the newly observed window, and supersedes pending effects.

## Upstream entry points

Upstream changes focus from four places, and each has a command here. Every
focus change that is not itself a cycle step ends a cycle in progress first, as
upstream's `focus_changed` and `execute_action` do.

- The four window navigation actions (`center-window`, `center-nearest`,
  `cycle-windows`, `focus-center`) through [`action`](IPC.md#action); their
  focus effect is in the reply's `effects`.
- `activate`: required `window` and `cause` (`click`, `click_release` or
  `native`), `output` (the active output, or null), optional `identity` and
  `generation`. A click's press returns
  `{"effect":<focus effect or null>,"navigation":null,"dirty":…}`. Its release
  as a completed click requests no focus and returns
  `{"navigation":…,"dirty":false}` with no `effect` key. A native activation
  records the shell's observation instead of asking for anything: `effect` is
  always null. All three are specified in
  [NAVIGATION.md](NAVIGATION.md#activate).
- `clear_focus`: no fields, replies `{"dirty":<a window was focused>}`.
  Upstream's click on empty canvas (`clear_focus_to_empty_canvas`): no window
  holds logical focus afterwards.
  The cycle ends, a pending effect is dropped (its late `focus_result` is then
  stale), stacking and history stay, and `snapshot.focused` is null. Nothing is
  asked of the adapter, because there is no native "focus nothing" to ask for,
  and `observed_native` keeps saying what was last observed. `center-nearest`
  landing on an anchor clears focus the same way.
- `end_focus_cycle`: upstream ends a held cycle when the `cycle_hold` modifiers
  are no longer all down (`src/input/keyboard.rs`). The controller sees no
  keys, so the shell watches them and sends this. [`bindings`](CONFIG.md#key-bindings)
  reports the modifiers as `cycle_hold`.

Every [`action`](IPC.md#action) other than `cycle-windows` also runs upstream's
prelude: it ends a cycle before it does anything else.

Differences from upstream, all following from one rule: a focus enters the
focus history when its request is answered, not when it is made.

- Upstream's history follows keyboard focus, which a compositor simply sets.
  Here a focus is a request, so the history is promoted by `focus_result` with
  `success: true`, by `focus_logical`, by `observe_focus`, and by `activate`
  with cause `native`, and by nothing else. A shell that performs native focus
  promotes what its adapter confirmed or observed. A shell that performs none
  answers every request `focus_logical`, and the history then follows logical
  focus as upstream's follows keyboard focus, with nothing recorded as observed.
  When no request is answered at all, or every result is a failure, the history
  stays empty, `cycle-windows` and `cycle_focus` select nothing, and logical
  focus, raising and every camera flight still work.
- "Ending a cycle commits its selection" therefore means: a selection whose
  effect was answered, confirmed or logical, moves to the head of the history;
  a selection whose effect is still pending is not promoted by the release or
  the prelude, but by its own `focus_result` or `focus_logical` if the same
  effect is still current, which then pushes it to the head as any answered
  focus is. If a new focus request superseded it first, that selection is never
  promoted, where upstream would have promoted it and then the new window on
  top. When the answer follows the request at once, as a shell that answers
  `focus_logical` can arrange, nothing supersedes it first.
- A request an adapter tried and failed (`focus_result` with `success: false`)
  cancels the cycle and promotes nothing. Upstream has no such outcome.
- A placeholder is upstream's stand-in: it can be focused and it anchors a
  cycle, it has no effect and never enters the history.
- Upstream's `raise_and_focus` redirects to a window's innermost modal child.
  No relationship between windows is known here, so nothing is redirected.

`snapshot.focused` remains the logical-intent alias. `snapshot.focus` exposes
`intent`, `observed_native`, `pending_effect`, `last_result`, `history`, `cycle`,
and `release_pending`. Attached sources expose their generation. There is only
one authoritative pending effect; an effect returned earlier becomes stale when
superseded. Snapshot reads do not allocate or acknowledge effects.

Ordinary focus first ends the old cycle, committing only a current selection
whose request was answered; its own promotion waits for its answer. Removing
unrelated windows clamps Stage's index exactly as upstream. If removal makes
that index refer to a different window, release cannot commit an unconfirmed
replacement.
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
focus and history selection. Camera navigation has a separate
[controller contract](NAVIGATION.md). Tests here (`focus_cycle_flow`, and
`navigation_actions_flow` for the upstream entry points) use synthetic
identities, results and observations through the actual exported C ABI and
establish only these controller contracts: they do not show that an effect
focuses a window, that a native focus change is observed, or that a modifier
release reaches `end_focus_cycle`.
