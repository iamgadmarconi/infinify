# Effects contract, ABI 1

DriftWM frosts the backdrop of a window that asks for it, scales and fades a
window in when it opens and out when it closes, fades a stand-in that leaves,
and shows its own errors in a bar along the bottom of every output. The
controller draws none of this. It says what the shell's compositor needs to
know: the `[effects]` table, which windows are blurred, the messages of the
error bar, and which window events upstream animates. How the shell turns that
into frames is the compositor's host protocol,
[docs/native/app/Canvas/COMPOSITOR-NOTES.md](../../native/app/Canvas/COMPOSITOR-NOTES.md),
sections 17 to 23; this file is the controller's half.

Adapted from <https://github.com/malbiruk/driftwm> at
`352333a8fa1b22171492d4b71a54102045c9a19d`:
`src/state/errors.rs` (`ErrorSource`, `summarize_config_errors`, `set_error`
and `clear_error`), the calls of those two in `src/state/reload.rs` and
`src/state/init.rs`, and what decides which window events are animated: the
`start_window_open_animation` call at a new toplevel's first sized commit in
`src/handlers/compositor.rs`, the two `snapshot_closing_window` calls of
`toplevel_destroyed` in `src/handlers/xdg_shell.rs`, the two `StandInFade`
pushes and `reveal_deferred_adopt` in `src/state/suspended.rs`, and
`start_window_open_animation` and the head of `snapshot_closing_window` in
`src/state/window_animation_driver.rs`. The `[effects]` table and a window's
blur are not adapted: they are `driftwm-core`'s `EffectsConfig`,
`parse_effects_config` and `effective_blur`, upstream's own code.

This contract has no command of its own; three keys carry it:

| Key | Where |
| --- | --- |
| `effects` | a key of the snapshot's `render` block |
| `errors` | a key of the snapshot's `render` block |
| `lifecycle_events` | a key of the snapshot |

Two values to note:

- `decoration.blur` is false for every window without a source: a stand-in is
  never frosted by `[decorations] blur`, as upstream never frosts one.
- `render.revision` also moves when `render.errors` changes, so a config file
  that is refused spends one ([Errors](#errors)).

## `render.effects`

```json
"effects": {"blur_radius":2,"blur_strength":1.1,"animate_blur_fps":20,
            "animation_speed":0.5,"animation_scale":0.95}
```

Upstream's `[effects]` table as its own parser left it, field for field. The
values shown are upstream's defaults, which the block holds until a config
file says otherwise. The controller validates nothing itself, and rewrites one
value, an infinite `blur_strength`, because JSON has no number for it:

| Key | Default | Upstream's parse rule |
| --- | --- | --- |
| `blur_radius` | 2 | a non-negative integer, the number of Kawase passes; no upper bound |
| `blur_strength` | 1.1 | negative or not a number is 0, with the warning `config: effects.blur_strength <v> is negative, using 0`. `inf` passes upstream's parser without a warning and is reported here as 0, what the shell's compositor makes of an infinite strength (COMPOSITOR-NOTES, deviation 31); the key is always a number |
| `animate_blur_fps` | 20 | above 144 is 144, without a warning; 0 turns the frost's own refresh off |
| `animation_speed` | 0.5 | in (0, 1]: 0, a negative value or not a number is the default, with `config: effects.animation_speed <v> must be in (0, 1], using 0.5`; above 1 is 1, with `… above maximum 1, using 1`. 1 is instant |
| `animation_scale` | 0.95 | the same rule with its own default. 1 fades without scaling |

A value of the wrong type (`blur_radius = -1`, a string) and a key upstream
does not have are parse failures: the whole file is refused and the table in
force stays ([CONFIG.md](CONFIG.md)). `animate_blur`, which upstream retired,
is such a key.

A change spends a render revision as every other drawn table does
([RENDER.md](RENDER.md#render)): each accepted reload spends one whatever it
changed, and the launch load spends one when its `[effects]` differs from the
defaults.

What the shell does with the five numbers is COMPOSITOR-NOTES 18.1 to 18.3.

## Blur

`decoration.blur`, on every entry of `placements` and of `windows`
([RENDER.md](RENDER.md#placements)), is upstream's `effective_blur`:

- a bound window whose rule says `blur = true`: true, always. The rule is the
  one the window mapped with ([RULES.md](RULES.md#matching)): a reload that
  drops the rule from the file leaves the window blurred until it is gone;
- any other bound window: `[decorations] blur`, as the config in force has it
  now. A widget and a screen-pinned window are no exception;
- a window without a source, whether a suspended stand-in or a waiting slot:
  false. Upstream requests blur for client windows only, and the rule of the
  window a slot is waiting for is not in force while the slot waits.

A fullscreen window ([FULLSCREEN.md](FULLSCREEN.md)) is the one bound window
the global flag does not reach: `effective_blur` is called with
`is_fullscreen` for it, so only its own rule's `blur` frosts it. Every other
bound window is asked with `false`.

The `screenshot` effect is unchanged and carries nothing about blur.
Upstream's screenshot composer omits it, and so must the shell in a capture
(COMPOSITOR-NOTES 18.1); the flag in the snapshot stays what it is.

## Errors

```json
"errors": ["config error: TOML parse error at line 1, column 9\n  |\n1 | [effects\n…"]
```

The controller's messages for upstream's error bar, in the order of upstream's
sources: config, background, keyboard. Each source has at most one message.
The background source is the shell's, whose background program reports it,
and belongs between the other two; the keyboard source is never set here
([below](#differences-from-upstream)). So the list holds the config message or
nothing, and the shell's own message goes after it.

The config source follows upstream at launch and on a reload alike. Every
`load_config` ends in one of these:

| The load | `errors` |
| --- | --- |
| no file, while none was ever accepted: the built-in defaults | empty |
| the file cannot be read, or has gone missing after one was accepted | `config: failed to read <path>: <reason>` |
| the file does not parse | `config error: <the TOML error>`, several lines long as the parser writes it; the bar collapses its whitespace into one line (COMPOSITOR-NOTES 19.3) |
| accepted with warnings | one warning; with more than one, the first of them in sorted order followed by ` (+N more)` |
| accepted without a warning | empty |

Which warning stands for the rest is this port's choice: the least of them in
byte order, the head of the sorted list. Upstream's `summarize_config_errors`
takes the first the parser returned, and `driftwm-core`'s parser, upstream's
own, collects the warnings of the tables it reads into a hash map,
`[keybindings]` among them, in an order that is not fixed: one file with
several unknown actions names a different one first from one load to the
next. Taken as upstream takes it, the message of a file that did not change
would change between two loads of it, and the bar would be redrawn for
nothing. Sorted, a file has one message. The format is upstream's.

They are the texts of `load_config`'s own `errors` and `warnings`, which are
unchanged: the reply's `warnings` are in the parser's order, whatever that was
for this load. A shell that prints them sorts them the same way if its lines
are to come in one order at every load, the bar's warning first; the macOS
shell does, for stderr. A file that is refused leaves the last good configuration in force,
as before; only the message is new. A file larger than 4 MiB is refused as
unreadable, with `file exceeds 4 MiB` for a reason: that bound is not
upstream's.

**The revision.** The shell builds what it derived from `render` again only
when `render.revision` moves, so a message it has not seen needs a new number.
A load that changes the message spends one revision, unless it already spent
one as an accepted reload does: a clean reload that clears a message moves the
number by one, not two. A load that fails with the message already shown moves
nothing, as upstream's `set_error` redraws nothing for an unchanged message.
At launch a refused file, or one accepted with a warning, spends the first
revision even though the drawn tables are the defaults.

The messages are not saved, and a `load` of a scene file leaves them and the
revision alone.

## Lifecycle events

```json
"lifecycle_events": [
  {"serial":41,"window":7,"event":"open","output":1},
  {"serial":42,"window":7,"event":"close_to_standin","output":1},
  {"serial":43,"window":7,"event":"standin_adopted","output":null}
]
```

The most recent window events that upstream animates, oldest first, at most
32. The shell remembers the highest `serial` it has played and plays each
newer event once.

| `event` | Logged when | Upstream |
| --- | --- | --- |
| `open` | an `attach` with neither `logical_id` nor `world_rect` places a window, by `window_placement` or by a rule's `position` or `pinned_to_screen`, after the [launch pass](LIFECYCLE.md#slots-and-re-adoption-the-macos-rule) | `start_window_open_animation` at the first sized commit of every toplevel that adopted no stand-in. A widget and a `focus_on_open = false` window open like any other: that call is outside the block that leaves them unfocused |
| `close` | `window_closed` takes the window off the canvas (`standin: false`) | `snapshot_closing_window`, scaled and faded |
| `close_to_standin` | `window_closed` leaves a stand-in (`standin: true`), by a suspend mark or `suspend_on_close` | the same snapshot, alpha only, over the stand-in that takes the window's rectangle |
| `standin_dismiss` | `close-window`, `suspend-window` or IPC `Close` dismisses a detached placeholder, or `forget` removes one | `dismiss_suspended`'s `StandInFade`, which shrinks to `animation_scale` |
| `standin_adopted` | an `attach` adopts the slot of a pending relaunch, [adoption](LIFECYCLE.md#1-adoption) step 1 | `adopt_relaunched`'s `StandInFade`, which fades without moving over the window that took the slot |

Not logged, because upstream has no animation for it:

- a window of the launch pass, adopted or placed: it was open before the
  canvas was;
- a window that takes its own waiting slot back, adoption steps 2 and 3, at
  any time. That is the macOS rule, which upstream has not;
- an `attach` with a `logical_id` or a `world_rect`, `remove_source`, a
  `forget` of a bound window, and the slots `adoption_complete` drops or turns
  into stand-ins;
- a relaunch that is asked for, lapses or is cancelled; a retitle; a pin;
- anything a refused command would have logged: a refusal leaves the list and
  the serial as they were, like every other bit of state.

The fields:

- `serial` starts at 1 and grows by one per event for as long as the
  controller lives. It is not saved, and a scene `load` neither empties the
  list nor starts the serials again. An event that falls off the front of the
  list before the shell reads a snapshot is lost.
- `window` is the logical id. By the time the shell reads the event the
  snapshot already shows what came after it: a closed window has no entry, a
  window that closed into a stand-in is `kind: "standin"`, an adopted stand-in
  is `kind: "window"`. What the event animates from is what the shell drew
  last, which it must still hold.
- `output` is the active output the command named: `attach`'s,
  `window_closed`'s, or the `action` or `ipc` request's that dismissed the
  stand-in. `null` when it named none, and always for a `forget`, which has
  no such field. It says where the user was, not where
  the window is drawn: a canvas window may show on several outputs or on
  none, and a screen-pinned window on its pin's output only.

One window can have several events in the list, and two of them may arrive in
one snapshot (a window that closes into a stand-in which is then dismissed):
they are played in serial order.

The controller withholds nothing for what it cannot see. Upstream skips an
animation that no output would show and a closing snapshot whose pixels are
more than a second old, and at `animation_speed = 1` an animation is over on
its first tick. Those are the shell's to check (COMPOSITOR-NOTES 18.2): an
event is logged whether or not any of them holds.

### Beside a size that is owed

Under a shell that can deliver a size, an `attach` whose rule names one
begins a size transaction in the reply that maps the window, or, while
another transaction is unresolved, leaves the window waiting its turn
([RULES.md](RULES.md#a-rules-size)), and a sizing action begins one at any
time ([SIZES.md](SIZES.md)). The log knows nothing of either:

- the window's `open` is logged once, with the map, whatever becomes of the
  size. Nothing is logged when the transaction ends, completes or fails;
- while an effect of the transaction is outstanding the snapshot's
  `native_resize` names the window and holds a `pending_effect`, and from the
  setter on its placement is not `presentation_settled`. That is what a shell
  waits on before it plays the `open`: upstream opens a window at its first
  sized commit, with the size its rule gave it, and the app's shell holds the
  animation until the last effect is answered
  ([its notes](../../native/app/Canvas/README.md#blur-window-animations-and-the-error-bar));
- `window_closed` for a window whose size is owed is refused, as it is for a
  drag ([SIZES.md](SIZES.md#other-interactions)), and a refusal logs nothing. The shell
  reports the close again once the transaction has drained, and that one is
  logged: one `close` or `close_to_standin`, never two and never none. A
  `forget` is refused the same way;
- a window that is waiting its turn has its `open` logged with its map like
  any other, and nothing in the snapshot says it waits: `native_resize`
  names the window whose transaction is in the slot. A shell that holds the
  `open` for the size holds it from the moment that window's own transaction
  begins, so one of several ruled windows that map together may be seen
  opening at its own size and growing afterwards, where upstream shows each
  at the size its rule gave it. Its `window_closed` is accepted while it
  waits: it leaves the queue.

## Differences from upstream

- **Events are logged, not played.** Upstream starts an animation inside the
  handler that maps or destroys the window. Here the controller records that
  the event happened and the shell animates from the frame it last drew.
- **The launch pass opens nothing.** Upstream starts with no clients, so every
  window it ever shows has opened in it. Here the windows of the launch pass
  were already open, as [LIFECYCLE.md](LIFECYCLE.md#slots-and-re-adoption-the-macos-rule)
  has it, and none of them scales in when the canvas appears, whether it took
  a slot or was placed. A shell that never sends `adoption_complete` gets no
  `open` at all.
- **A waiting slot's window comes back unanimated.** A slot that is no
  stand-in is drawn as one, and when its own window returns (a minimized
  window shown again, a capture that failed and recovered) the picture changes
  without a crossfade. Upstream has no such state; only its identity match, a
  pending relaunch, is an adoption it animates.
- **`standin_dismiss` is for any detached placeholder**, a waiting slot
  included: every one of them is drawn as a stand-in and dismissed by the same
  commands.
- **`forget` fades a placeholder too.** Upstream has no such command: it
  removes a window without upstream's focus rules, and the app's shell uses it
  for a ⌃⌥-click on a placeholder. What it removes there is drawn as a
  stand-in, so it is logged as `standin_dismiss`, with no output, and fades as
  a dismissed one does. A bound window it removes was drawn as a window:
  nothing is logged, and it disappears at once.
- **The keyboard source is never set.** Upstream raises it when xkb refuses
  the config's layout, variant, options or model, and clears it on the next
  reload that parses. Here `[input.keyboard] layout` and its siblings are read
  and unused, because macOS owns the layout list
  ([CONFIG.md](CONFIG.md#keyboard-layouts)): nothing compiles a keymap, so
  nothing can fail to.
- **The background source is the shell's.** Upstream sets and clears it where
  it loads the background image; the controller never opens that file
  ([RENDER.md](RENDER.md#render)).
- **Which warning the bar names.** Of several, the first in sorted order;
  upstream names the parser's first, which for a hash-mapped table is not the
  same from one load to the next ([above](#errors)). A file whose warnings
  the parser returns in a fixed order can so name another one here than
  upstream does: the three range warnings of the scenario below come back as
  `navigation.camera_speed`, `effects.blur_strength`, `effects.animation_scale`,
  and the bar names the third.
- **A refused config spends a revision.** Upstream's failed reload redraws the
  bar and drops no cache. Here the new number also makes the shell build its
  background program and chrome style again, from the same tables.
- **A reload that finds no file while none was ever accepted** clears the
  message, as it is the built-in defaults again
  ([RENDER.md](RENDER.md#differences-from-upstream)); upstream's reload stops
  at the read failure and shows it.
- **`output`** is this ABI's active output. Upstream's snapshot decides its
  own outputs from the window's rectangle or its pin.
- **`animation_speed` reaches less.** Upstream's is the factor of its window
  move, resize, fit and fullscreen animations as well. None of those exists
  here, and a camera flight has its own `[navigation] camera_speed`
  ([NAVIGATION.md](NAVIGATION.md)).
- **An infinite `blur_strength` is reported as 0.** Upstream's parser keeps
  it and multiplies it into the blur's sample offset. JSON cannot carry it,
  and the compositor port draws it as 0 (COMPOSITOR-NOTES, deviation 31), so
  that is what the block says. Nothing is added to `render.errors` for it:
  upstream warns of nothing.
- **On a fullscreen output the events are the same and the shell draws
  less.** A window that maps straight into fullscreen by its rule logs its
  `open`, and a fullscreen window that closes its `close` or
  `close_to_standin`, like any other: the controller withholds nothing for
  it, as it withholds nothing for visibility. What upstream leaves out is
  the shell's to leave out: no closing snapshot and no stand-in fade is
  drawn on an output that is fullscreen, a fullscreen window's own snapshot
  is baked bare as it was drawn, and a window that opens fullscreen is not
  held for the size it is owed
  ([shell notes](../../native/app/Navigation/README.md#what-a-fullscreen-display-shows)).
  Upstream's fullscreen entry and exit animations do not exist here
  ([FULLSCREEN.md](FULLSCREEN.md#differences-from-upstream)).
- **An open under an interactive grab** is skipped upstream. A new window is
  never under one here, and a slot that is being dragged is adopted, not
  opened.

## Verification boundary

`crates/desktop/tests/effects_flow.rs` drives the exported C ABI with config files in a
throwaway directory:

- `render.effects` against `driftwm-core`'s `EffectsConfig::default()` and its
  parse of an empty file, before any config and after a launch file without
  the table; a reload that sets every key, one at the edges of upstream's
  ranges, one with every out-of-range value upstream mends, one with `nan`
  and one with the retired key, each against `driftwm-core`'s own parse of
  the same text, its warnings included, with the revision after each; a value
  of the wrong type and an unknown key, each refused with the table kept; an
  infinite `blur_strength`, which `driftwm-core` parses as infinite and the
  block reports as 0, without a warning; a launch file that changes the table,
  and one that restates the defaults;
- `decoration.blur` for a window whose rule sets it and one no rule matches,
  in the placement and in the window list, against `driftwm-core`'s
  `effective_blur` over the rule it resolves; the same two after `[decorations]
  blur` is turned on and off again; the stand-in each leaves on a close, a
  waiting slot, a stand-in with a relaunch pending, and the window that takes
  each slot back;
- `render.errors` and the revision after a launch with no file, an accepted
  file, a file that does not parse (with the last good table still in force),
  the same failure again, another failure, the file removed, a scene save and
  `load`, a clean reload, a file with one warning and one with three, whose
  message names the least of the three in byte order, the parser's third, a
  failure after those, and at launch a refused file and a file with a warning;
  and a file with three unknown actions in `[keybindings]` loaded two dozen
  times, the reply's `warnings` arriving in more than one order and the
  message naming the same one every time;
- `lifecycle_events` after a launch pass that adopts one window and places
  another; a new window, a widget, a `focus_on_open = false` window, a
  rule-pinned one and one attached without an output; an explicit attach, a
  lost source and its re-adoption, a rebind, a `forget` of a bound window and
  a refused `window_closed`, none of which logs; three closes, one of them a
  widget's and one without an output; a close into a stand-in by a rule and by
  a suspend mark; a relaunch and the adoption that follows; a dismissal by IPC
  `Close` and by `close-window` without an output; a `forget` of a suspended
  stand-in and of a waiting slot, each logged as `standin_dismiss` with a null
  output, and a `forget` of a window that is gone, refused; 24 more events,
  after which the list is the 32 most recent; a scene save, whose file holds
  none of it, and a `load`, after which the list is unchanged and the next
  serial follows;
- beside a size that is owed, under `native_resize_capability`: a window whose
  rule names a size maps with one `open` and its size transaction in the same
  reply; the snapshot's `native_resize` names it with the pending effect
  through the baseline read and the setter, and in the capture-acknowledged
  mode its placement is unsettled from the setter on (in
  [readback mode](NATIVE_RESIZE.md#readback-mode) it never is); `window_closed` is refused meanwhile and the snapshot,
  the list included, is unchanged; after the adapter's `missing_window` the
  same report is accepted and logs one `close`, and a third is refused; a
  second such window whose size is delivered logs its `open` and nothing else,
  and owes nothing after the final read;
- a refused reload's whole reply, with `focus_follows_mouse` still the last
  good file's beside the message that spent the revision.

`crates/desktop/tests/render_flow.rs` carries the two new keys in every whole-block
comparison, and its refused reload now moves the revision by one.

Naming the parser's first warning again failed the scenario too. Each of six
other rules was broken by hand once, and the scenario that covers it
failed: a stand-in taking `[decorations] blur`, an `open` during the launch
pass, a changed message that spends no revision, a crossfade for every
adoption, a list of 64, and an infinite `blur_strength` sent as it was parsed
(the block then held `null`). The `forget` rule was broken two ways, logging
nothing and logging for a bound window too, and the scenario failed each time.

These are controller scenarios. Nothing is blurred, animated or drawn in
them, and no event is played: they are not evidence that the compositor
frosts a backdrop, that a closing snapshot is baked from a window's last
buffer, that an animation has upstream's curve or length, that the frame timer
stops when the last one ends, or that the error bar appears. Upstream's own
sources are not executed: which events are logged comes from reading the
functions named at the top, and only those parts of them. Of
`window_animation_driver.rs` that is `canvas_rect_drawable`,
`start_window_open_animation` and `snapshot_closing_window` down to its
`drawable` test; of `window_animation.rs`, nothing.

What the shell does with this contract was written at the same time by other
hands. The two halves were then built into one app without a change to either
and run together: a throwaway tool handed this controller's snapshots, after
real `load_config`, `attach`, `window_closed` and `ipc` requests, to the app's
renderer offscreen, which drew the bar with these messages, the frost for
`decoration.blur` and each of the five events once; and the app itself was
driven through a failing and a mended config and two dismissals over `msg`,
where none of the three keys can be read back and nothing was looked at.
The [shell notes](../../native/app/Canvas/README.md) have both, and what neither
showed: the app's panel on a display and a captured window.
