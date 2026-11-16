# Controller focus and cycle boundary

## Focus and arrival policy

`src/focus_policy.rs` is the policy module: owner evidence, arrival placement,
focus restoration and activation response live together. Its interface is the
existing command seam's `focus_policy` command with `timestamp_ns`, `filter`,
`focus_allowed` and a tagged `fact`. The module reads no clock. `filter` is true
only for full-desktop managed runs; native drivers and geometry stay outside.
Transient policy state is skipped by serialization: snapshots and scene files
have no additional fields.

The native adapter reports switch held/released, system-UI intent, a clicked
logical window, launch intent, application launch/activation, window arrival,
native observation, returned focus work and its answer. Delayed application and
observation facts retain their event timestamp as well as the supplied read
timestamp. Replies contain decisions (`unsolicited`, `cancel_work`, `observe`,
`advance`, `changed`) or an ordered list of six driver steps: cancel click,
advance epoch, send command, answer/complete an effect (captured or current
epoch), perform the received reply, and changed. Ordinary observation facts
change policy-private state only; focus, MRU and camera change in the returned
command after the driver epoch was advanced. Its synchronous receipt selects
effect completion or the unchanged `observe_focus` fallback. A restore instead
sends `focus` before the advance; its receipt installs correction facts and the
adapter passes the same received reply object into `perform:` without another
policy call before its advance. Normally at most one receipt is used. Only the
old background-arrival failure followed by an ordinary restore can use two,
both on the same main-queue turn.
Bindings always include the exact identity and generation. Unknown bindings
do not authorize camera motion. Parse/refused-command failures retain the
existing command error path; a refused arrival fact means unauthorized, exactly
as the former nil native authorization did.

`DWNavigationCoordinator` is an adapter for execution, not a second policy:
it owns worker epochs, driver guards, click delivery and camera ticking.
`DWNavigationDriver` remains the seam with two adapters, `DWNativeFocusDriver`
and the existing in-memory driver. Main-thread facts must be submitted in
observation order. The one coordinator `attach:` entry point sends the arrival
fact, invalidates the returned worker epoch if requested, then attaches with
the returned `unsolicited` unchanged. It creates no pending-decision table.
An attach failure does not undo consumption. `perform:` installs protection
from the complete arrival reply before dispatching its focus work. Follow-up
for the typed-controller seam: **make arrival one typed call**, preserving this
non-transactional failure order. Also fold observation fact, command and receipt
into one call once that seam can cancel the driver's epoch from inside it.

The rule relocation (old coordinator methods below are in
`native/app/Navigation/DWNavigationCoordinator.m`):

| Rule, unchanged | Previous location | Current location in `focus_policy.rs` |
| --- | --- | --- |
| Full-desktop filter only; uncertain classification does not move focus/camera | coordinator application/observe gates | `focus_policy_fact`, `observe_owner_focus` (adapter still reports run eligibility) |
| Exact PID and birth of confirmed live process; retained through its own unadopted panel while live intent survives | `isConfirmedFocusedProcess:` | `classify_process`, `confirmed_live_binding` |
| Held switch authorizes unconditionally, records 2.5 s; release records 1.5 s | `noteSystemSwitchHeld:` | `FocusFact::Switch` |
| System-UI intent 2 s; bundle launch intent 30 s | native intent methods | `SystemUi`, `LaunchIntent` |
| Focused-window click 0.75 s, one cross-process use, only absent system/bundle intent | event-tap snapshot comparison, `authorizeProcess:` | `WindowClick`, `classify_process` |
| Process activation 4 s, attach 15 s; delayed facts check event or read time; PID reuse rejected | `authorizeProcess:` | `classify_process` |
| Intent consumed before attach; survives attach failure; driver epoch invalidated first | `Desktop+Windows.m` plus `consumeAttachIntentForPID:` | `WindowArrived`, `classify_process`; coordinator `attach:` relays cancellation then attaches |
| Consumed process attach authorization capped at now + 1.5 s; bundle consumed on authorization | `authorizeProcess:` | `classify_process` |
| Restore at most twice per PID per 5 s, age strictly greater than 5 s expires; failure stops retries | `startCorrectionTo:`, `complete:`, `pruneIntentsAt:` | `plan_correction`, `observation_receipt`, `Answer`, `prune` |
| Background cohorts, exact bindings, 1.5 s lifetime, input cancellation, family observations | native protection/observe methods | `preserve_arrival`, `cancel_background`, `observe_owner_focus` |
| Sibling placement else immediately outside viewport; stack below focused; suppress focus/navigation | `lifecycle.rs` unsolicited placement and settlement | `unsolicited_spawn`, `settle_arrival` |
| Observation epoch precedes focus/camera command; pending effects answered against captured epoch; nil fact reproduces nil-snapshot fall-through (cancel click, advance, `focus_lost`, changed) | coordinator `observe` | `observe_owner_focus`, `observation_receipt`; native six-step dispatch |
| Restore sends `focus` before epoch advance; only widened window is one in-process receipt call between focus and `perform:`'s advance (formerly assignments); no-effect fall-through retains consumed budget | coordinator restore/protection helpers | `plan_correction`, `observation_receipt`, `perform_reply` |
| Normal/rule placement, focus-on-open, fullscreen/utility exceptions | `lifecycle.rs` spawn/arrival settlement | `spawn`, `arrival`, `settle_arrival` (adoption search stays in lifecycle) |
| Activation no-pan uncertainty, clipped reveal, cycle/click rules and configured zoom | `window_actions.rs::activate` | `activate`, `activation_zoom` |


The controller keeps three things apart: logical focus (the intent, which
raises a window at once), the request it hands the native adapter (`effect`),
and what the adapter or the shell's own observation reported back. The
[native shell](../../native/app/Navigation/README.md) is the consumer: it performs
effects, reports results, and says which launches do so. No command here alone
changes a native app or proves compositing, and none of this crate's tests
exercises live focus or shortcut delivery.

`focus` updates logical intent and raises the window. Its response contains
`effect`, which is null for a detached placeholder, or a `focus_native_window` request:
`effect_id`, `window`, exact `identity` (including birth time and optional owner),
and binding `generation`. The adapter must revalidate before mutation and obtain
independent native readback before reporting success. An API return code alone
must not become `success: true`.

Focus commands:

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

Upstream changes focus from five places, and each has a command here. Every
focus change that is not itself a cycle step ends a cycle in progress first, as
upstream's `focus_changed` and `execute_action` do; the hover below is held
back by an open cycle instead.

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
  [NAVIGATION.md](NAVIGATION.md#activate); what a native activation that is
  repeated, or names a window that is not bound, is answered is in
  [LIFECYCLE.md](LIFECYCLE.md#event-delivery). A press that a binding turns into
  a window move or resize is the same raise and focus, made by `begin_drag`,
  `begin_resize` and `begin_native_resize` themselves ahead of their grab, as
  upstream's `on_pointer_button` and `try_pinned_button` do: the request is
  the reply's `effect`, or the one entry of `effects` where `effect` is the
  resize transaction's.
- `clear_focus`: no fields, replies `{"dirty":<a window was focused>}`.
  Upstream's click on empty canvas (`clear_focus_to_empty_canvas`): no window
  holds logical focus afterwards.
  The cycle ends, a pending effect is dropped (its late `focus_result` is then
  stale), stacking and history stay, and `snapshot.focus.intent` is null. Nothing is
  asked of the adapter, because there is no native "focus nothing" to ask for,
  and `observed_native` keeps saying what was last observed. `center-nearest`
  landing on an anchor clears focus the same way.
- [`hover`](POINTER.md#sloppy-focus): with `focus_follows_mouse`, the window
  under the pointer takes logical focus without being raised, the one focus
  here that does not restack: a screen-pinned window before the canvas
  beneath it, and never a widget
  ([POINTER.md](POINTER.md#screen-pinned-windows-and-widgets)). Its reply has
  an `effect` only when the focus moved. `pick`, the left click of pick mode,
  is a window navigation like the four above.
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
  with cause `native`, and by nothing else that asks. The one focus that never
  asks is a window [adopted during the launch pass](LIFECYCLE.md#1-adoption)
  into the slot that held the focus: no request is made for it, so it is
  promoted as it is adopted. A shell that performs native focus
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

`snapshot.focus` exposes `intent`, `observed_native`, `pending_effect`,
`last_result`, `history`, `cycle`, and `release_pending`. `intent` is the logical
focus; `history` is the one focus history: the cycle walks it,
and so do the tiers that decide
[who follows a closed window](LIFECYCLE.md#a-window-closes). Attached sources expose their generation. There is only
one authoritative pending effect; an effect returned earlier becomes stale when
superseded. Snapshot reads do not allocate or acknowledge effects.
The redundant top-level `snapshot.focused` field is removed; consumers read
logical focus from `snapshot.focus.intent`.

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

Widget and pin eligibility is upstream's since [RULES.md](RULES.md): a widget
and a screen-pinned window can hold the focus by every entry point above,
`activate` and the answers to its requests included, and never enter
`history`; a window leaves it when it is pinned, and a cycle step taken from
one starts at the head. Neither is a candidate of `center-window`,
`center-nearest` or `focus-center`, and neither is flown to. Modal parent
relationships and fullscreen exclusion are not represented by this slice. It
deliberately neither infers relationships from titles/PIDs nor claims those
modes are supported. A future verified relationship
surface must apply upstream modal redirection and its ten-hop limit before native
focus and history selection. Camera navigation has a separate
[controller contract](NAVIGATION.md). Tests here (`focus_cycle_flow`, and
`navigation_actions_flow` for the upstream entry points) use synthetic
identities, results and observations through the actual exported C ABI and
establish only these controller contracts: they do not show that an effect
focuses a window, that a native focus change is observed, or that a modifier
release reaches `end_focus_cycle`.

Known behaviour deliberately retained: the former native family-observation
deduplication checked `snapshot.focus.logical`, which the snapshot does not
export. Repeated child observations are therefore not newly deduplicated here;
using the controller's internal logical marker would be a separate bug fix.
