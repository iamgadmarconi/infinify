# DriftWM parity contract

The completion requirement is exact feature parity with DriftWM. This directory
tracks the gap between that requirement and Infinify's experimental app. A useful
prototype, a successful build, or a passing reducer scenario does not satisfy it.

The comparison is pinned to DriftWM
[`352333a8fa1b22171492d4b71a54102045c9a19d`](https://github.com/malbiruk/driftwm/tree/352333a8fa1b22171492d4b71a54102045c9a19d),
which was also the remote HEAD when checked on 2026-10-09. The initial target
checkpoint is `27a868e`. Later upstream changes require an explicit inventory
refresh; they must not silently change the acceptance target.

## Inventory and acceptance

[`inventory.json`](inventory.json) records source action variants, input action
families, IPC requests, reference-configuration entries (including commented
defaults and examples), configurable
structure fields, protocol families and cross-cutting behavior. Source references
and hashes make omissions and drift inspectable. Reference values are examples
or documented defaults; the runtime defaults and dispatch code remain authoritative.
An inventory row is a coverage obligation, not an executable specification or a
claim that every edge case has already been enumerated.

Rows use `missing`, `implemented_unverified`, `verified`, or `blocked`.
`implemented_unverified` includes partial implementations with known mismatches.
Every required row must acquire an exact behavioral contract, a production-path
test, saved evidence tied to its implementation revision, and independent review
before becoming `verified`. Evidence must identify OS, architecture and relevant
hardware. No percentage or completion claim follows from counting stubbed APIs.

The user clarified on 2026-10-09 that every behavior is required for native Mac
apps. Literal Wayland/X11 client hosting and wire-protocol compatibility are
outside scope. Those inventory entries remain visible with `required: false`
and `out_of_scope`; native equivalents of platform services remain required.
A platform equivalent must preserve the specified behavior. An unsupported API
does not turn its feature into a pass.

## Known differences at the initial checkpoint

| Behavior | DriftWM | Infinify checkpoint |
| --- | --- | --- |
| Snap defaults | gap 12, distance 24, break force 32 | gap 8, threshold 12, break force 24 |
| Snapping | opposite edges; optional same-edge/center; resize snaps | opposite-edge drag snapping; no resize snapping |
| Minimum zoom | hard floor 0.001 with layout-dependent effective minimum | static 0.001 floor |
| Camera motion | animation, velocity/coasting, edge pan | direct pan/zoom; unused momentum helper |
| Navigation | directional, MRU cycle, home, bookmarks, fit/fill, overview, fullscreen, output transfer | a few reducer primitives; app actions absent |
| Sessions | dormant windows, suspend, relaunch and adoption policies | saved geometry/cameras and manually rebound placeholders |
| Native surfaces | compositor-owned window and popup trees | selected independent-window capture streams |
| Input | full grabs, contexts and configurable device bindings | limited native left input/scroll; hardcoded app controls |
| Configuration and IPC | upstream config grammar and live Unix socket commands | diagnostic/scenario CLI and an internal controller ABI |
| Rendering | chrome, effects, pin/widget layers, backgrounds and screenshots | clipped live layers and placeholder tiles |

The existing app's earlier complete native-control proof belongs to its recorded
historical source. The current checkpoint has separate focused review-fix
regressions. See [desktop evidence](../../native/desktop/evidence/README.md).
The development host runs macOS 27.2. Building with deployment target 26.0 is not
evidence of runtime compatibility with macOS 26. Physical multiple-display and
device-specific behavior also need the corresponding hardware.

## Later bounded milestones

- `4ca7f5e` ports snap defaults and candidate/resize policies, checked against the
  unchanged pinned upstream algorithms. Fractional rounding, native constraints
  and complete desktop gesture behavior remain open; see
  [snapping limits](../../crates/canvas/SNAPPING.md).
- `e133f91` normalizes captured root families using frame metadata. Independent
  saved-pixel checks pass for a right-extending native panel and an in-bounds
  sheet through two clipped views. This does not establish left/up extents,
  parent discovery, interleaved stacking or native popup interaction; see the
  [family evidence](../../native/families/evidence/normalized-review.json).
- `2fb6218` adds upstream fit/minimum-zoom, navigation, bookmark and motion helper
  policies with an unchanged-source differential oracle. These helpers are not
  yet integrated into Scene/controller behavior; see
  [policy contracts](../../crates/canvas/POLICY.md).
- `2842602` integrates Stage ownership, confirmed MRU history and held cycling
  through the exported controller C ABI. Stale results after rebind/load are
  rejected. Camera navigation, native dispatch and modal/fullscreen/pin/widget
  policy remain separate requirements; see the
  [focus contract](../../crates/desktop/FOCUS.md).
- `21b454d` connects normal-window Keep/Reset navigation and held cycling to
  per-output camera animation, placements and hit mapping through the C ABI.
  Differential tests execute exact upstream method bodies. Native frame scheduling
  and the full center-window action remain unfinished; see
  [navigation contracts](../../crates/desktop/NAVIGATION.md).
- `f5007b8` adds single-window native resize transactions through the C ABI:
  coalesced requests, actual-size settlement, incremental edge anchoring and
  capture/input gates. Thirteen focused tests include an outcome-validation
  matrix, independently reviewed after fixing a contradictory-result defect.
  At that checkpoint the separately tested AX adapter was not connected through
  this transaction in the shell; see [resize contracts](../../crates/desktop/NATIVE_RESIZE.md).
- `9a190b1` connects normal-window focus/navigation to the native shell behind an
  explicit experimental launch flag. Headless checks exercise its real coordinator,
  event-order policy and Rust C ABI, including cancellation and delayed shortcuts.
  Independent review approved the corrected implementation. Native focus, real
  shortcut delivery and rendered animation remain unverified; see
  [integration evidence](../../native/desktop/evidence/navigation-headless.json).
- `6a49484` connects experimental native resize handles, the transaction, the AX
  adapter and a strict capture gate. Headless checks cover early motion, coalescing,
  cancellation, result draining, padded buffers, stale frames and source validation
  without new frames. Independent review fixes preserve final settlement and reject
  stale work. Actual handle-to-AX-to-renderer behavior, static-window refresh, groups
  and fractional upstream equivalence remain unproved; see
  [integration evidence](../../native/desktop/evidence/resize-headless.json).
- `7e9d59c` adds animated PanViewport, HomeToggle, ZoomIn, ZoomOut, ZoomReset and
  ZoomToFit to the default shell as camera-only controller commands on the existing
  flight tick, with toolbar buttons and Control-Option shortcuts, an Open canvas
  chooser entry that needs no capture, and an access request that runs only from the
  user's click. Coverage is a controller scenario through the exported C ABI and the
  headless coordinator regression. The toolbar, shortcut delivery and rendered
  animation have not been exercised live; chords, steps and fit padding are
  hardcoded and fullscreen interaction is absent. See
  [navigation contracts](../../crates/desktop/NAVIGATION.md).
- `6574ad1` routes every default-shell view and bookmark
  shortcut and view toolbar button through DriftWM's action-string grammar (Quit and
  Control-Option-Escape still call the shell's quit directly), adds a Unix-domain IPC socket with
  an `Infinify msg` client for the upstream requests that have a native meaning,
  controller bookmarks saved in the scene file (additive; older builds cannot read
  a file that contains them), and `--windowed`, a single nested development panel
  with no global shortcuts. Upstream actions and requests without a macOS
  implementation parse but answer a not-implemented error; focus writes are logical
  focus and camera navigation only, moves are logical world moves, and resize writes
  are refused. Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/ipc_flow.rs`) plus scripted sessions on 2026-10-09
  against the built app in `--windowed` mode on a private scene and socket (macOS
  27.2, Apple Silicon, three seeded detached placeholders), which left no saved
  evidence. Exercised there through the socket: state, camera and zoom reads and
  writes, the six view actions, bookmark set/get/list/delete/go-to, move, focus
  by id and by bundle identifier, the unknown, not-implemented and refused
  replies, the scene file after bookmark and move changes and after a restart, a stale socket,
  a second instance refused the same socket, and exit on `quit` and on SIGTERM.
  Evidence boundary: no rendered pixels, toolbar clicks, hot keys or status
  feedback were observed; no window had a bound source, so no native focus effect
  was produced and none is dispatched for IPC focus; one output only; the default
  socket path, the peer-user check and the server's connection limits were not
  exercised against the app. See the
  [desktop shell notes](../../native/desktop/README.md) and the
  [IPC contract](../../crates/desktop/IPC.md).
- `386d57e` adds `driftwm-core`: upstream's pure modules (`config`, `canvas`,
  `layout`, `session`, `stage` and the touch recognizer) carried over verbatim
  from the pinned commit, with their 675 upstream tests retained. It is source
  the app can call, not app behavior: nothing in the shell or controller used
  it at that commit.
- `4dd642b` configures the default shell exactly as DriftWM is configured: one
  TOML file in upstream's grammar, parsed by `driftwm-core`,
  decides key bindings, mouse bindings and settings. The controller holds the
  `Config`, replaces its own copy of the action grammar with upstream's, and maps
  upstream's modifiers and keysyms to a Mac keyboard (`ctrl` Control, `alt` Option,
  `super` a physical chord, Control-Option unless `--super` picks another, with
  displacement and deterministic collision handling). The shell loads the file at
  launch (`--config`), watches it and reloads on change, registers the reported
  bindings as global hot keys in place of its fixed table, repeats repeatable
  actions while held, and asks the controller for the binding of every press and
  scroll in place of its fixed gestures. Pan step, zoom step, fit padding, camera
  speed, nudge step, navigation anchors, config bookmarks, focus placement, the
  snap settings and the two session restore flags now come from the file.
  `nudge-window`, `exec`, `spawn`, `exec-terminal`, `exec-launcher` and
  `reload-config` run. Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/config_flow.rs`) plus one scripted session of two launches
  on 2026-10-09 against the built app in `--windowed` mode on a private scene, config and socket
  (macOS 27.2, Apple Silicon, three seeded detached placeholders), which left no
  saved evidence. Exercised there through the socket: the defaults with no file;
  a file created, edited and broken while running, each picked up without
  a restart (pan step, zoom step, fit padding, bookmark seeds; the broken file
  keeping its predecessor); an accepted file moved away and back, which kept the
  configuration and the runtime bookmarks and reported upstream's read failure;
  a relaunch with no file starting at a new output's camera and the seed
  bookmarks; `reload-config`; `nudge-window`; `spawn` and `exec`
  starting real processes with the `[env]` environment; the unknown and
  not-implemented replies; exit on SIGTERM. Evidence boundary: no hot key was
  registered (`--windowed` registers none) and none was pressed; key repeat, every
  pointer press, drag and scroll, right and middle button forwarding, key lookup
  on another keyboard layout inside the app (the lookup code alone was run in a
  scratch harness against installed layout tables, registering nothing), `--super`,
  `exec-terminal` and `exec-launcher` were not run; nothing drawn was observed (status line, tooltips, help); no window had
  a bound source; one output only. At that commit nineteen of upstream's default
  key bindings and four of its default mouse bindings named actions that did not
  run; media keys are not registered, and trackpad and touch gesture bindings,
  window rules, decorations, effects, backgrounds, input-device settings and every
  other setting whose feature is absent are parsed and unused. See the
  [desktop shell notes](../../native/desktop/README.md#configuration) and the
  [configuration contract](../../crates/desktop/CONFIG.md).
- `c11fece`, window navigation and focus, makes DriftWM's `center-window`,
  `center-nearest`, `cycle-windows` and `focus-center` run in the
  default shell through the action grammar, and so through key bindings, the
  toolbar (Center, Previous, Next) and `msg action`, with upstream's cycle prelude,
  `find_nearest` and visibility thresholds from `driftwm-core`, anchors as
  `center-nearest` targets, and new `activate`, `clear_focus` and `focus_logical`
  controller commands for click-to-focus and the completed click's reveal,
  followed native focus, the empty-canvas click, and focus that stays logical.
  The navigation coordinator and native focus driver, until now behind
  `--experimental-native-navigation`, run in every normal launch (the flag is
  accepted and ignored; `--no-native-focus` keeps focus logical). Native focus
  needs Accessibility only; hold-to-commit samples the modifier state instead of
  using an event tap, and the hard-coded Option-Tab hot keys are replaced by the
  configured binding. Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/navigation_actions_flow.rs`), the headless coordinator
  regression (`tests/e2e/desktop-navigation.sh`, injected focus driver, clock and
  scheduler), and four scripted launches on 2026-10-09 of the built app in
  `--windowed` mode on a private scene, config and socket (macOS 27.2, Apple
  Silicon, three seeded detached placeholders), which left no saved evidence.
  Exercised there through the socket: `center-nearest` right, left, up, down and
  up-right from known starting points with the focused window or the viewport
  centre as origin, at zoom 1 and with a kept zoom of 0.5, an anchor from a config
  file written while running, `center-window` with and without a focused window,
  `focus --id` followed by `center-window`, `cycle-windows`, upstream's messages
  for four malformed specs, both launch flags, and exit on SIGTERM. Evidence
  boundary: native focus of a real window was not exercised by any route; no
  window had a bound source, so no focus request was produced, and with
  placeholders only the focus history is empty, so `cycle-windows` replied Ok and
  changed nothing and no cycle that changes the order was seen in the app; no hot
  key, Option release, toolbar button, click, followed native focus or drawn
  frame was observed; one output only. Known mismatches: with native focus
  allowed the focus history is fed only by confirmed or observed native focus,
  so a window whose focus request fails or is superseded before it is confirmed
  stays out of it (without Accessibility or with `--no-native-focus` the shell
  answers each request `focus_logical` and the history follows logical focus, as
  upstream's follows keyboard focus); a click is forwarded while its native
  focus request is still in flight, not after it; `center-window` was always
  Reset because there was no fill (since the window sizing milestone below it
  returns to the fill's view for a window filled behind
  `--experimental-native-resize`, and is Reset in every default launch, where
  no fill can exist); `auto_navigate_on_click` pans at a completed
  click's release as upstream does, without upstream's title-bar double-click
  deferral; every canvas press ends an open cycle at the press; an IPC
  `cycle-windows` is always one committed step; the pointer `center-nearest`
  swipe and `focus_follows_mouse` were absent until the pointer policy
  milestone below, and so was `auto_navigate_on_close` until the window
  lifecycle milestone below. See the
  [desktop shell notes](../../native/desktop/README.md#window-navigation-and-native-focus)
  and the [navigation](../../crates/desktop/NAVIGATION.md#window-navigation-actions)
  and [focus](../../crates/desktop/FOCUS.md) contracts.
- `5812d6f` adds six independent behaviours to the default
  shell. Hot corners: an `[[outputs]]` entry (upstream's exact-name or `*` rule,
  matched against the display's stable id) binds actions to corners, the shell
  runs upstream's `check_hot_corners` latch over a polled pointer and the
  controller runs the action through the normal dispatch (`hot_corner`), with
  the pointer position and modifier state the corner fired under, so a corner
  bound to `focus-center` or `cycle-windows` behaves as that key binding does.
  `send-to-output` and `send-cursor-to-output`: upstream's `output_in_direction`
  over the outputs' `screen_bounds`, the focused window teleported to the target
  viewport's `focus_placement` point, and the cursor move returned as a
  `warp_pointer` effect the shell performs. `switch-layout`: a `switch_layout`
  effect, performed by selecting among the keyboard input sources the user has
  already enabled, with the selected source reported back (`layout_changed`) and
  answered by the IPC `Layout` request and `StateInfo.layout` / `layout_short`.
  The IPC event stream: `Subscribe` and `msg subscribe` with upstream's ack,
  snapshot, per-change `Event::State` lines, hash dedupe and two-slot coalescing.
  `autostart`: run once, 100 ms after launch, never on reload; each command,
  like every `exec`, is given `INFINIFY_SOCKET`, the socket the app serves, in
  place of upstream's `WAYLAND_DISPLAY`, so a `msg` in it reaches the instance
  that started it. Upstream's
  Linux-only default commands: a default binding whose program is not on `PATH`
  is replaced by a macOS equivalent (`mod+l` puts the displays to sleep with
  `pmset`), or left to macOS (volume, brightness and media keys), and a binding
  the user wrote is registered as written. Coverage is controller scenarios
  through the exported C ABI (`crates/desktop/tests/platform_actions_flow.rs`,
  additions to `config_flow.rs` and `ipc_flow.rs`, and one scenario in
  `navigation_actions_flow.rs` for a corner that runs window navigation) plus
  two launches on 2026-10-09 of the built app in `--windowed` mode on a private
  scene, config and
  socket (macOS 27.2, Apple Silicon, one display, one enabled input source, three
  seeded detached placeholders), which left no saved evidence. Exercised there
  through the socket: the event stream end to end (ack, first state, one line
  per frame of a flight and none while idle, no repeated line, eight subscribers
  and a ninth refused, requests on a subscribed connection, a clean end when the
  app exits); `msg layout` and `state` carrying the launch layout report; an
  autostart command starting once and not again on `reload-config` or a watched
  file change; in two further launches after review fixes, an autostart child
  and an IPC `exec` child carrying `INFINIFY_SOCKET` as the served socket path
  (the file's `[env]` value once it set one), and an autostart `msg` with no
  `--socket` answered through it; and the single-display answers of `send-to-output` (window
  unmoved) and `send-cursor-to-output` (no effect). Evidence boundary: no hot
  corner fired (no pointer was moved into one, and arming is not readable over
  the socket); the pointer was never warped and no window was sent to another
  display (one display); no input source was selected and no input-source change
  was reported (`switch-layout next` ran with one source enabled and selected
  nothing); `pmset displaysleepnow` was not run, and it locks the session only
  as far as the user's Lock Screen setting does; the hot keys for
  `send-to-output` were not registered (`--windowed` registers none); the
  30-second drop of a stalled subscriber, `subscribe` before the canvas opens and
  autostart in a chooser launch were not reached; nothing drawn was observed; no
  window had a bound source. Known mismatches: the pointer is sampled every 80 ms
  (60 Hz during a flight) instead of on every motion, and a corner is measured on
  the display's panel (toolbar strip included) rather than on the output;
  subscribers are capped at eight and a stalled one is dropped, where upstream
  does neither; a change of active output alone is found at the next idle poll
  (80 ms) rather than the next frame; an `[env]` `INFINIFY_SOCKET` wins over the
  one the shell adds, where upstream's `WAYLAND_DISPLAY` insert overwrites;
  `layout_short` is a language code, not an xkb token; fullscreen and pinned
  legs of the output actions do not exist; `[input.keyboard]` layout options and
  `[[outputs]]` `scale`, `transform`, `position` and `mode` stay read and
  unused. See the
  [desktop shell notes](../../native/desktop/README.md#displays-hot-corners-layouts-and-autostart),
  the [configuration contract](../../crates/desktop/CONFIG.md#outputs) and the
  [event stream contract](../../crates/desktop/IPC.md#event-stream).
- `1f44d0f`, window lifecycle: every ordinary application
  window is meant to live on the canvas by itself, as every toplevel is managed
  in DriftWM. The controller adopts a window that appears into a waiting slot of
  its application or places it with upstream's `window_placement` policy
  (`center`, `cursor`, or `auto` through `driftwm-core`'s own `place_auto`, with
  upstream's cascade), then raises, focuses and navigates to it with
  `zoom.reset_on_new_window`; `window_closed` removes it or leaves a stand-in by
  `session.suspend_on_close`, a window rule or a close/suspend mark that
  lapses after upstream's 10 seconds, with upstream's focus-follow tiers and
  `navigation.auto_navigate_on_close` read from the one focus history that
  `cycle-windows` walks, which a shell without native focus fills by answering
  each request `focus_logical`, so they need no report of native focus;
  `retitle` follows titles; `close-window`, `suspend-window` and the IPC
  `Close`, `Suspend` and `Relaunch` requests run and return `close_window` and
  `launch` effects, a relaunch staying pending for upstream's 30 seconds. The
  macOS rule that replaces upstream's session restore: applications outlive
  Infinify, so the scene file keeps one slot per window (stand-ins listed in an
  additive `standins` key), running windows are re-adopted into their slots by
  bundle identifier and title in a discovery pass at launch and whenever the
  canvas reopens, a slot whose titled window the pass names as existing off
  screen keeps waiting for it, and at `adoption_complete` the other unmatched
  slots are dropped unless `session.restore_windows` keeps them as stand-ins;
  a config file refused at launch decides nothing. The shell gains a window
  manager (discovery over the window list, ScreenCaptureKit streams started and
  stopped on demand, an Accessibility close-button press on a freshly validated
  identity, `NSWorkspace` launch), opens the canvas at launch when Screen
  Recording access exists, and keeps the chooser-first run as `--manual`.
  It lands on top of `c11fece` and `5812d6f`: the focus request of a new
  window and of the window that follows a close goes to the navigation
  coordinator like every other (performed natively, or answered
  `focus_logical`), the controller keeps one focus history for cycling and for
  the close tiers, the IPC event stream reports the windows that come and go,
  and `close-window` and `suspend-window` are reported as implemented by
  `bindings`, leaving six of upstream's default key bindings on actions that do
  not run.
  Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/lifecycle_flow.rs`, synthetic identities, expected
  positions derived by hand from upstream's rules, expiry driven by
  `tick_navigation` timestamps) plus ten short scripted launches on 2026-10-09
  of the built app on a private scene, config and socket (macOS 27.2, Apple
  Silicon), six on the build before the review fixes and four on the build with
  them, which left no saved evidence, and one more of the merged build on the
  same day (below). Those ten launches had neither Screen
  Recording nor Accessibility access. Exercised there: the windowed canvas
  opening and reporting on stderr that it manages nothing; `state` with seeded
  waiting slots (and, in the earlier six, one stand-in); `close`, `suspend`,
  `relaunch`, `close-window` and `suspend-window` on placeholders (dismissal,
  upstream's error replies, a relaunch of a bundle identifier with no
  application reported and survived, and in the later four a second request for
  it answering `ok` with no second attempt); the stand-in list in the scene
  file and after a restart (earlier six); `--manual` opening on the chooser
  with no canvas; exit on SIGTERM. The launch of the merged build, `--windowed`
  with no Screen Recording access (the missing-Accessibility note was not
  printed, so that access presumably existed; it was not checked), repeated on
  one build what the earlier milestones and this one had shown apart:
  `center-nearest right` landing on the seeded window at 1950 0,
  `pan-viewport right` moving the camera 100 points, `zoom-to-fit` and back,
  the not-managed line on stderr, three waiting slots in `state`,
  `focus --id` then `close-window` dismissing one, `suspend` and `relaunch`
  answering as above, an `exec` child and the autostart command both carrying
  `INFINIFY_SOCKET`, and a `subscribe` client receiving the state without the
  dismissed window; it exited 0 on SIGTERM with its socket removed.
  Evidence boundary: no window was discovered,
  adopted, placed, captured, retitled, closed or relaunched;
  `adoption_complete` was never sent, so the slot drop, held slots, the refused
  config rule and `restore_windows` were not exercised in the app; no mark or
  relaunch was seen to lapse there and no close was followed; the close-button
  press, on-demand capture and the launch of a real application are compiled
  and read only; no hot key (⌃⌥Q is now registered), status line or pixel was
  observed; one output only. Known mismatches: expiry is measured on the
  navigation clock the host ticks, not a wall clock, and the identity match of
  a pending relaunch stays open for the whole 30 seconds because there is no
  activation token; slot matching by title is a macOS addition and is greedy
  one window at a time; no parent, modal, widget, pin or fullscreen tiers;
  window rules apply only `suspend_on_close` and `restore_windows`; the native
  focus request for a new or follow-focused window has never been performed on
  a real window, and with native focus allowed a window whose request failed
  or was superseded is in no tier's history; upstream's blank-slate rule for
  auto placement after a click on empty canvas is not carried over; stand-ins
  have no upstream chrome and no click or Enter relaunch; a window that is off
  screen during a discovery pass keeps its slot only if it is titled and the
  slot has that exact title. See the
  [lifecycle contract](../../crates/desktop/LIFECYCLE.md) and the
  [desktop shell notes](../../native/desktop/README.md#managed-windows).
- `f083155`, camera motion, makes the camera move as DriftWM's does. The
  controller keeps upstream's own `MomentumState` (`driftwm-core`) per output and
  gains additive commands and fields: a timed `pan` scaled by
  `navigation.trackpad_speed` or `mouse_speed`, `pan_end`, a `pointer` report,
  `zoom_by` for wheel and pinch at the config's zoom speeds, and a pointer on
  `gesture_to`. Its frame tick runs scroll momentum, edge pan, zoom and camera in
  upstream's order. A released pan drifts by `navigation.drift`; a window dragged
  into the `[navigation.edge_pan]` zone pans the canvas beneath it with upstream's
  ramp and its wait at an edge that borders another output; `toggle-cursor-pan`
  runs, switching a cursor edge pan that `edge_pan.cursor_pan` seeds at launch.
  The shell stamps pans with their event time, ends them at the scroll phase's
  end, on release or 50 ms after the last pan (a scroll under a held drag pan
  ends with the release), drops macOS's own inertia events for canvas pans,
  passes the pointer with window drags, reports it while cursor pan is on and
  no button is held, and no longer computes zoom factors. The trackpad gestures
  of the next bullet pan, pinch and drag through these same paths, and the
  shell's pinch reaches the controller as a gesture, not as `zoom_by`. Coverage is nine controller
  scenarios through the exported C ABI (`crates/desktop/tests/motion_flow.rs`),
  in which momentum is compared bit for bit with upstream's `MomentumState` and
  edge pan, cursor pan and both zooms with values derived by hand from upstream's
  formulas; the headless coordinator regression; and one scripted session on
  2026-10-09 against the built app in `--windowed` mode on a private scene,
  config and socket (macOS 27.2, Apple Silicon, three seeded detached
  placeholders), which left no saved evidence. Exercised there through the
  socket: `toggle-cursor-pan` accepted twice; a config file setting `drift`, the
  pan and zoom speeds and every `[navigation.edge_pan]` key loaded, then replaced
  and reloaded, with nothing on stderr; `pan-viewport`, `zoom-in`, `zoom-reset`,
  `home-toggle`, `zoom-to-fit`, `go-to-bookmark` and a camera write each landing
  exactly through the reordered tick; `debug-counters`; exit on SIGTERM. The
  app built with the next bullet's gestures on top was driven once more the
  same way: the toggle accepted twice, a motion config loaded and reloaded with
  nothing on stderr, and the same actions landing exactly. Both were built on
  `4dd642b`. Merged onto `c11fece`, `5812d6f` and `1f44d0f`, the frame is the
  navigation coordinator's tick in every normal run, the action prelude ends
  an open cycle and stops momentum in one place for keys, IPC, hot corners and
  gestures, and the flights those commits arm (window navigation, a completed
  click's reveal, a new window, the follower after a close) stop a coast as
  every flight does; that build passed the motion, gesture, navigation,
  lifecycle, platform, config and IPC controller scenarios and the coordinator
  regression, and was driven once on 2026-10-10 in the same way (6.9 seconds,
  no Screen Recording access): the toggle accepted twice with the camera
  unmoved in between, a file with `drift`, the pan speeds, two edge-pan keys
  and `zoom.trackpad_speed` loaded with no config line on stderr,
  `center-nearest`, `center-window`, `pan-viewport`, `zoom-to-fit` and
  `home-toggle` landing exactly on that tick, and a `subscribe` client
  receiving 46 State lines, none repeated, over the 1.6 seconds of two of
  those flights.
  Evidence boundary: momentum, edge pan and cursor edge pan need real scroll and
  drag input, which cannot be injected, and were not exercised in the running
  app. Neither were wheel or pinch zoom, the config speeds on a real gesture, the
  dropping of macOS inertia events, the rule that tells a rest from a flick by
  event times, or the 50 ms launch delay inside the app (it was run alone in a
  throwaway harness). The cursor-pan flag cannot be read over the socket, so the
  toggle's acceptance was observed and its effect was not. Nothing drawn was
  observed, no hot key was registered, no window had a bound source, and there
  was one output, so the wait at a shared edge ran only in the controller
  scenarios. Known mismatches: a drag stays on the output it began on, zoom is
  refused during a window drag, only edge pan carries a dragged window, a resize
  gesture and touch arm no edge pan, the pointer is never warped, and edge pan
  speed is that of the shell's 60 Hz timer. See the
  [desktop shell notes](../../native/desktop/README.md#camera-motion) and the
  [motion contract](../../crates/desktop/MOTION.md).
- `f083155`, trackpad gestures, brings upstream's dispatch
  of libinput's swipe, pinch and hold gestures (`src/input/gestures/`) to the
  controller behind three additive commands, `gesture_begin`, `gesture_update`
  and `gesture_end`, resolved against the `[gestures]` tables with upstream's
  precedence: three-finger swipe pans and coasts, pinches zoom around the
  pointer or fire `zoom-to-fit` and `home-toggle` at the configured thresholds,
  a hold fires on release, a three-finger tap followed by a swipe moves the
  window under the pointer, and `set-trackpad` turns the dispatch off and on.
  It is built on the camera-motion milestone above and adds no camera
  machinery of its own: a swipe that pans is that milestone's timed pan and
  `pan_end`, on its one momentum per output; a pinch that zooms is its pinch,
  with the dynamic minimum and the end snap; and a swipe that moves a window
  drives the pointer's drag, edge pan included. macOS hands no such gestures to an
  application, so the shell stands where libinput stands: canvas views accept
  raw indirect touches, a new recogniser (`native/desktop/trackpad-gestures.m`)
  turns three or more fingers into those event streams by rules written out
  beside the libinput behaviour each imitates, and AppKit's two-finger magnify
  is routed through the same commands and no longer through `zoom_by`. Coverage is controller scenarios with
  synthetic event streams through the exported C ABI
  (`crates/desktop/tests/gesture_flow.rs`), in which a swipe's coast is compared
  bit for bit with the same deltas sent as that milestone's timed pans; the recogniser fed scripted touch
  sequences in throwaway command-line programs, once with its events passed on
  to the real controller library, which accepted every one; and scripted
  sessions on 2026-10-09 against the built app in `--windowed` mode on a private
  scene, config and socket (macOS 27.2, Apple Silicon, three seeded detached
  placeholders), the last of them on the build that holds both of these
  milestones. None of it left saved evidence. Exercised through the socket:
  a config with a `[gestures]` override loading cleanly, malformed gesture
  entries reported in upstream's words and skipped while the rest of the file
  applied, a `[gestures]` value of the wrong type refused whole with its
  predecessor kept, `set-trackpad on`, `off` and `toggle` and their argument
  errors, the view actions landing as before, and exit on SIGTERM; on the
  build with both milestones, a file holding motion settings and a `[gestures]`
  override loading and reloading cleanly, `set-trackpad` and
  `toggle-cursor-pan` answering, and the view actions landing as before. Those
  builds stood on `4dd642b`, where `center-nearest`, `center-window` and
  `cycle-windows` were still refused. Merged onto `c11fece`, `5812d6f` and
  `1f44d0f`, a gesture's threshold or hold action runs through the one action
  dispatch with the gesture's pointer and the modifier state of the event that
  fires it (a new optional `held` on `gesture_update` and `gesture_end`), so
  the four-finger swipe, the `mod` three-finger swipe and the two default
  holds run window navigation and a swipe bound to `cycle-windows` holds its
  cycle open or commits it as a key binding does; a move's drag ends, with its
  edge pan, when its window closes by itself; and in the shell a gesture
  reply's focus request goes to the navigation coordinator and a press ends an
  open cycle, then the gesture, then every flight and coast. `gesture_flow`
  covers these with synthetic streams, and reads upstream's 22 default gesture
  bindings one by one: 14 run, 6 are refused by name and the 2 resizes are
  gated (13 and 7 at this commit; `zoom-to-fit-snapped` runs since the window
  sizing milestone below). On 2026-10-10 that build was driven once over its socket (6.9
  seconds, private scene, config and socket): a `[gestures]` override with a
  named swipe bound to `cycle-windows forward` and a hold bound to
  `focus-center` loaded with no config line on stderr, `set-trackpad off`,
  `on` and `toggle` answered `ok` and `set-trackpad maybe` upstream's message,
  and `center-nearest right`, which the earlier sessions saw refused, flew to
  the seeded window and focused it. Evidence
  boundary: **no physical trackpad gesture was performed**, which an automated
  session cannot do. No gesture event has reached the merged app either: a
  gesture firing window navigation, `held`, hold-to-commit from a gesture and
  the merged press path are controller scenarios and compiled shell code. The recogniser's events were passed to the controller
  library before it was joined to camera motion, and not again since. The shell's touch forwarding, timers, magnify routing and
  gesture sink have only been compiled; whether macOS delivers three- and
  four-finger touches to the canvas panel, real-finger behaviour, how the
  recogniser's thresholds feel, and coexistence with macOS's own gestures
  (Mission Control, App Exposé, the full-screen swipe, Launchpad, Show Desktop,
  three-finger drag, which the user must turn off in System Settings; nothing
  here changes a setting) are untested; the recogniser's constants are from
  memory of libinput and were not checked against its source; expected values
  are derived by reading upstream's handlers, which were not executed as an
  oracle; nothing drawn was observed. Six of upstream's default gesture
  bindings name three actions that do not run in a default launch
  (`fit-window`, `fit-window-snapped`, `toggle-fullscreen`; the first two run
  behind `--experimental-native-resize`, and `zoom-to-fit-snapped`, the fourth
  at this commit, runs since the window sizing milestone below), gesture
  resize is gated with native resize, an unbound
  gesture is not forwarded to the application under it, a move gesture stays
  inside its output, three fingers resting
  mid-swipe do not start the drift that upstream's 50 ms timer starts,
  `set-trackpad off` cannot
  silence the pointer or two-finger scrolling, and `[touch.*]` stays unused. See
  the [gesture contract](../../crates/desktop/GESTURES.md) and the
  [desktop shell notes](../../native/desktop/README.md#trackpad-gestures).
- This milestone (commit pending), per-window policy: `[[window_rules]]`,
  widgets and screen-pinned windows. The controller resolves a window's rules
  once, when it maps, with `driftwm-core`'s own matcher and merge (the bundle
  identifier as `app_id`, the source title as `title`), and applies `position`
  (frame center, Y up, ahead of `window_placement`), `widget`,
  `pinned_to_screen` with `output` and its output-relative `position`,
  `focus_on_open` and `opacity`; a retitle and a config reload re-resolve
  nothing, as upstream documents. A widget stays below every window and out of
  the focus history, snapping, clusters, fitting and auto placement, and is
  refused by drags, resizes, nudges and IPC `Focus` and `Suspend`; a pinned
  window keeps a place and its own size on one output whatever the camera and
  zoom, above that output's canvas windows. `toggle-pin-to-screen` and
  `move-to-bookmark` run, IPC `Pin` and `Opacity` answer with upstream's shapes
  and refusals, `Move` and `Resize` refuse a pinned window, and `State` fills
  `pinned` and `is_widget`. `snapshot.placements` and `hit` follow upstream's
  layer order (widgets, canvas windows, pinned windows) and carry `widget`,
  `pinned` and `opacity`; the shell's compositor draws a widget below and a
  pinned window above the canvas windows, the pinned one from its screen
  rectangle at its own size, each at that opacity (the rendering milestone
  below; probe, demo and owned-fixture runs fade their layer tiles instead),
  and the shell starts
  no move or resize gesture on a widget or a pinned window (a widget still
  gets the press as a click), and after registering its displays it sends the
  one new command, `outputs_settled`, on which a pin whose display is gone
  moves to one that is there. A close never hands the focus to a widget or a
  pinned window. Widgets are never saved; a pin is saved with its slot in an
  additive `pins` key. Coverage is
  controller scenarios through the exported C ABI
  (`crates/desktop/tests/rules_flow.rs`, synthetic observations on two outputs,
  expected rectangles derived by hand from upstream's conventions) plus one
  scripted launch of the built app in `--windowed` mode on a private scene,
  config and socket (macOS 27.2, Apple Silicon), first on 2026-10-09 and
  repeated on 2026-10-10 on the build with the review fixes, which left no
  saved evidence; what follows is the repeat. That launch had no Screen
  Recording access, so no window was captured and every window was a
  placeholder; the two pins in it were made beforehand by a throwaway program
  driving the same controller in process with synthetic sources, one of them
  on an output the app never registers, and read from the scene file by the
  app. Exercised in the app through the socket: the pin saved on the missing
  output listed under `State.pinned` on the app's one output from the first
  read on, which with no discovery pass in that run is the shell's
  `outputs_settled`; both pins unchanged by a pan and a `move-to-bookmark`
  while the canvas points under them followed the camera (a zoom was run only
  on 2026-10-09); upstream's `Move` and `Resize` refusals for a pinned
  window; `Pin` and `Opacity` refusing placeholders (`stand-ins can't be
  pinned`, `no window with id N`) and `toggle-pin-to-screen` leaving a focused
  placeholder alone; `move-to-bookmark` centering a focused placeholder and
  passing over an unset name and the pinned one; rules in the config changing
  no window that did not map; upstream's unknown-decoration warning and its
  TOML error for an unknown rule key; the moved pin in the file saved at exit;
  exit on SIGTERM. After the renderer below was built in with it, one more
  one-second launch the same day read a scene with one pinned placeholder:
  listed under `State.pinned` unchanged by a pan and at zoom 0.5 while its
  canvas point followed the camera, absent from three viewport screenshots as
  upstream excludes a pinned window from canvas captures, alone in a `window`
  screenshot and outside the frame of `all`, with the same `Pin`, `Opacity`,
  `Move` and `Resize` refusals. Evidence boundary: rules, pinning and widgets were exercised
  live only on placeholders through the socket, and no captured window was
  involved. No rule was resolved in the app, no widget existed there, no live
  window was pinned, unpinned or given an opacity there (those ran only in the
  controller tests and the seeding program), no window closed there (the
  focus-follow rules ran only in the controller tests), and what the app's
  own panel draws was not observed: the layer order, the pinned space and a
  written opacity were seen only in frames an offscreen tool read back from
  the shell's renderer driven by this controller (the rendering milestone
  below); no pointer press was
  made, so the shell's refusal notes and click routing to a widget or a pinned
  window are compiled and read only; ⌃⌥T is now registered and was not
  pressed; one output only, so a screen change and Return to desktop with a
  pin in place were replayed only as controller commands in the shell's
  order. Known mismatches: a rule's `size` is recorded and not applied in
  every default launch, and is asked of a new canvas window only behind
  `--experimental-native-resize` (the window sizing milestone below), never
  of a widget or a pinned window; `fullscreen` is recorded and not applied;
  and `preserve_aspect_ratio`, `pass_keys`,
  `pass_mouse` and `layer_order` are recorded with no effect (`decoration`
  and the border, corner and shadow fields are drawn, see the rendering
  milestone below, and `blur` is frosted, see the effects milestone below);
  a pinned window
  cannot be dragged or resized at all, where upstream's move and resize
  bindings, gestures and title bar move and resize it in screen space and
  reassign its output when it is dragged across monitors (unimplemented
  here); a pin leaves a display that is gone only when the shell reports its
  displays settled (`outputs_settled`), where upstream rehomes it at the
  unplug, because the shell removes and re-registers every display on any
  screen change; a window pinned by toggle that closes has no spatial
  follower, where upstream tests the snap rectangle it had before the pin; the
  pin is saved with the slot, where upstream's session file holds none, and a
  saved pin is clamped onto its output at launch; a pin waiting on a slot no
  window has taken reads `stand-ins can't be pinned` while `State` lists it;
  upstream's pin dot is drawn only in a compositor title bar, which a Mac
  window has only under a `server` rule; a widget that maps does not hand the focus back to
  the head of the history; `[decorations] opacity` and `opacity_focused` follow
  the canvas's logical focus, not native keyboard focus. All of the above was
  built on `4dd642b` with the window lifecycle. Merged onto `c11fece`,
  `5812d6f`, `1f44d0f` and `f083155`, there is one focus history, which a
  widget and a pinned window never enter whoever answers their focus request
  (`focus_result`, `focus_logical`, `observe_focus`, a native activation); the
  candidates of `center-window`, `center-nearest`, `focus-center` and
  `cycle-windows` are the canvas windows, `center-nearest` does not anchor on a
  pinned window and `focus-center` passes over one; no completed click and no
  followed native focus flies to either; a move gesture over a widget falls
  back to a pan and over a pinned window is claimed and inert, and a gesture's
  drag is released when its slot maps as a widget; `send-to-output` leaves a
  widget and rebinds a pin to the adjacent display; `toggle-pin-to-screen` and
  `move-to-bookmark` run through the one action dispatch, whose prelude ends
  an open cycle and stops momentum, from keys, IPC, hot corners and gestures;
  the event stream carries `pinned` and `is_widget`; and `outputs_settled` is
  sent from the `openPanels` every launch, Open canvas, chooser attach and
  screen change goes through. Four scenarios added to `rules_flow` cover
  those joins against a layout with a widget and a pinned window in the way,
  each beside a control showing what an unfiltered search or grab would have
  taken; the earlier scenarios were restated for the one history. Asked with
  upstream's built-in defaults, the controller's `bindings` reply listed
  45 key bindings of which 41 ran, leaving four on actions that did not
  (`toggle-fullscreen`, `fit-window`, `fit-window-snapped`,
  `zoom-to-fit-snapped`), and of the 35 action names of upstream's grammar it
  refused seven by name (those four, `grow-window`, `shrink-window` and
  `fill-window`); the window sizing milestone below has the counts with
  `zoom-to-fit-snapped` running. The merged
  app was launched three times on 2026-10-10 as before (6, 16 and 8 seconds,
  three placeholders, no Screen Recording access, nothing saved): a
  placeholder pinned in the scene file stayed under `State.pinned` through a
  pan and a zoom and in all 463 lines of a `subscribe` stream, out of the
  viewport captures and alone in a `window` capture; `Pin`, `Opacity`, `Move`
  and `Resize` gave the same refusals; `toggle-pin-to-screen` left a focused
  placeholder alone and `move-to-bookmark` moved one; with the pinned
  placeholder focused, `center-nearest` and `center-window` chose a canvas
  placeholder. That adds nothing to the evidence boundary above but the event
  stream: the joined navigation, activation, gesture, hot-corner and
  `send-to-output` rules ran only as controller scenarios, with no live
  window, widget, second display, key, pointer press or gesture in the app.
  Further mismatches from the join: `focus-center` takes no widget, where
  upstream's walk reaches one and flies to it; a click raises a widget among
  the widgets, where upstream only focuses it; a move gesture does not move a
  pinned window, where upstream's does in screen space; `send-to-output` takes
  a pin's own output as its source, where upstream takes the output showing
  the pin's canvas frame. See the
  [rules contract](../../crates/desktop/RULES.md) and the
  [desktop shell notes](../../native/desktop/README.md#window-rules-widgets-and-pinned-windows).
- This milestone (commit pending), rendering: the canvas of a normal run is
  drawn the way DriftWM draws it. A Metal port of upstream's frame composition
  and canvas background (`native/desktop/compositor.{h,m}`,
  `background.{h,m}`; upstream's border, shadow and corner-clip shaders and its
  dot grid, tile and wallpaper shaders hand-translated, user GLSL shaders
  translated at load; built, checked against the unmodified upstream GLSL and
  independently reviewed outside the repository, then carried in with its
  notes) replaces the per-placement display layers on a flat colour: one layer
  per output draws the `[background]` in its five types, the outlines of the
  other outputs' viewports from `[output.outline]`, every window bottom to top
  with upstream's shadow, border, corner clip and opacity resolved by
  `driftwm-core`'s own `effective_*` helpers from `[decorations]` and the
  rule each window mapped with (the per-window policy above, an IPC `Opacity`
  write included: nothing is matched again when a frame is described),
  widgets in upstream's bucket below the canvas windows and screen-pinned
  windows in the one above, drawn from their screen rectangle at zoom 1
  whatever the camera, and upstream's stand-in (bar, close glyph, body, application
  name, `launching…`, always opaque) for a window without a source. The
  controller describes the frame in an additive `render` block and
  per-placement keys and bumps a revision on every accepted reload, so that
  the shell reads the background's shader and image files again as upstream
  does; `msg screenshot` runs with
  upstream's four targets, scale rule and refusals as a deferred effect the
  shell renders offscreen with the same compositor; a canvas capture holds no
  screen-pinned window and draws widgets below the other windows, `all`
  frames the canvas windows and stand-ins only, and a `window` capture takes
  a pinned window or a widget alone, all as upstream's does. macOS rule: a captured
  native window already draws its own title bar, so it is decorated as
  upstream decorates a client-side-decorated window unless a rule says
  otherwise. Probe, demo and owned-fixture modes keep the earlier drawing.
  Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/render_flow.rs`, regions and pixel sizes derived by
  hand from upstream's functions) plus three short scripted launches on
  2026-10-09 of the built app in `--windowed` mode on a private scene, config
  and socket (macOS 27.2, Apple Silicon, three seeded placeholders) and two
  more on 2026-10-10 after the review fixes, none of which left saved
  evidence; and, once built together with the per-window policy above, one
  scenario across both contracts in `crates/desktop/tests/rules_flow.rs`, an
  offscreen tool and two further launches the same day, described at the end
  of what was seen. Seen there, in the PNGs `msg screenshot` wrote, each
  opened and its pixels read: the stand-ins at their seeded canvas positions
  to the pixel at zoom 1 and after `zoom-to-fit`; application-name labels and
  the `launching…` label; the default dot grid, a static, an animated and
  a textured upstream shader, a tile with and without
  `mirror_tile`, a wallpaper and `none`, each adopted from a config rewrite
  without a restart; a missing and a non-compiling shader falling back to the
  dot grid with the reason on stderr; border width and both border colours
  with the focus following `msg focus`, corner radius, shadow on and off,
  chrome colours, bar height and font; all four
  targets, `--from-screen`, `--scale`, and the refusals including two
  unwritable paths; exit on SIGTERM. Seen in the two later launches, after a
  review had found each as a defect in the earlier build: stand-ins opaque
  under `[decorations] opacity = 0.5` (alpha 255 in a `window` capture, one
  body colour in `all`); `-o -` relaying bytes equal to a file capture of the
  same target; a shader file replaced behind an unchanged config picked up by
  `reload-config` alone, a broken one falling back after a `touch` of the
  config and the repaired one drawn again; a wallpaper lying only over the
  view's footprint in `region`, `all` and `--from-screen` captures and
  transparent elsewhere; and the count of Metal drawables in the running app
  staying at 1 over six seconds of an animated background. Seen with the
  per-window policy built in: in frames read back from the shell's renderer,
  linked with the compositor and this controller into a throwaway tool
  outside the repository (synthetic sources with plain-coloured buffers, one
  output off the global origin), a rule-pinned window at one output-local
  rectangle and size at zoom 0.5, after a pan and at zoom 1 while a canvas
  window and a widget moved and scaled, the widget under the canvas window
  and the pinned window over it, a written opacity of 0.5 as the blend it
  should give, and a pinned detached slot as an opaque stand-in; the
  controller's own capture effects performed by that renderer without the
  pinned window in `viewport`, `all` and `region` and with it alone in
  `window`; and in two more launches of the built app (3 and 1 seconds, three
  placeholders), the viewport, `zoom-to-fit`, `window`, `region`, `-o -` and
  missing-shader results as before, and a placeholder pinned in the scene
  file absent from viewport captures before and after a pan and at zoom 0.5,
  alone in a `window` capture and outside `all`'s frame. Evidence boundary:
  no launch had Screen Recording access, so every window was a stand-in and
  no captured window was ever drawn through the compositor: its colour,
  alpha, the sRGB stream setting, the kept last frame, frame-driven redraw
  and the opacity a live window is captured alone with are compiled and read
  only. A screenshot is an offscreen render: the layer in the app's
  own panels was not seen on a display (orientation and stacking were checked
  only on a throwaway panel built the same way, before integration), so the
  widget and pinned layers were never seen there either, nor were
  the status-line copy of a fallback, an animated background on screen, a
  second output and its outline, a window rule, `default_mode` or a `server`
  title bar in the app, the experimental native-resize presentation through
  the compositor, or any probe, demo or owned mode after the change. No pixel
  was compared with a pixel from DriftWM itself. Known mismatches: blur,
  `[effects]` and the open and close animations were not drawn by this
  milestone and are by the effects milestone below, and move and resize
  animations are not drawn at all; `cache_shader` is
  accepted and ignored (a shader always renders live) and gigapixel TIFF tiles
  are not supported; text is CoreText's,
  not cosmic-text's; a window whose rectangle lies just outside an output
  casts no shadow into it; a screenshot path's missing directories are not
  created; captures are not tiled; in a capture a wallpaper is cover-cropped
  to its output's footprint as on screen, where upstream's capture element
  samples the whole image across it; a stand-in's label needs the application
  installed to be a name rather than a bundle identifier; a `server` rule
  draws a second title bar above a Mac window's own; a detached slot that
  still holds a pin is drawn pinned and left out of canvas captures, a state
  upstream never has; no fullscreen, layer surfaces or popups. All of the
  above was built on `4dd642b` with the window lifecycle. Merged onto
  `c11fece`, `5812d6f`, `1f44d0f` and `f083155`, the shell has one drawing
  path and one frame timer: each redraw adopts the `render` settings, draws
  through the compositor, notes whether cursor edge pan wants the pointer and
  schedules the State event for subscribers; the timer runs while the
  controller reports camera motion (a flight, a coast, an edge pan) or a panel
  shows an animated background and stops when neither is left, ticking the
  camera and watching the hot corners only while it serves motion; the
  autorelease pool per turn of the main loop and per layer flush is kept; and
  a `Screenshot` is rendered and answered inside its own request, beside the
  long-lived `subscribe` connections. `render_flow` passes with the
  snapshot's `keyboard_layout` and `trackpad` keys beside `render`. Seen in
  the three launches of 2026-10-10 named under the per-window policy above:
  the viewport, `zoom-to-fit`, `window`, `region` and `-o -` captures and the
  missing-shader fallback as before; the focused border colour on the
  stand-in `center-nearest` had just flown to; three screenshots answered
  on other connections while a `subscribe` client went on receiving the
  frames of that flight (12, 24, 35 and at last 148 lines), with no
  consecutive line repeated in any stream; and, under an animated shader
  background, two captures half a second apart differing, a subscriber
  receiving nothing while only the background animated, and every flight
  landing exactly. Not seen: the panel on a display, so neither the layer
  there nor the timer's redraws of an animated background; a hot corner,
  cursor edge pan or a coast on the joined timer. See the
  [rendering contract](../../crates/desktop/RENDER.md), the
  [desktop shell notes](../../native/desktop/README.md#rendering) and the
  [compositor notes](../../native/desktop/COMPOSITOR-NOTES.md).
- This milestone (commit pending), pointer policy: what DriftWM does with a
  pointer that moves. Until now the shell handled no mouse-moved event, so an
  application under the canvas never saw the pointer move,
  `focus_follows_mouse` and `[zoom] interact_min` were read and ignored, and a
  press bound to the mouse action `center-nearest` only said it was not
  implemented. The controller gains `hover` (upstream's `maybe_hover_focus`:
  with `focus_follows_mouse` the topmost window under the pointer, a stand-in
  included, takes logical focus without being raised and without a flight;
  empty canvas keeps the focus; a drag or resize gesture, a native resize that
  has not drained and an open focus cycle hold it back; the reply also says
  whether the motion is the window's to receive), upstream's `pick_mode` per
  output from the live zoom and `zoom.interact_min` (reported by `hit`,
  `input`, `hover` and `snapshot.outputs[].pick`; `input` refuses a pick
  target, so nothing can be forwarded to it; `mouse_binding` takes a `pick`
  flag for upstream's held-modifier rule and its canvas-context retry of an
  unbound scroll), `pick` (upstream's `resolve_pick`: navigate to the window at
  zoom 1, landing per `focus_placement`; since the window sizing milestone
  below, a window filled behind `--experimental-native-resize` returns to its
  fill view instead when that view is at or above the threshold) and
  `pointer_nearest` (upstream's
  `NavigateGrab`: the 16 point dead zone, the octant of press minus pointer by
  `driftwm-core`'s `direction_from_vector`, then the `center-nearest` action).
  A native focus report that is only the echo of a hover's own request is
  recorded without a raise or a flight; a request that failed or was withdrawn
  unanswered stops counting as echoed 3 seconds after its hover, on the
  controller's tick clock. All of it is in one new module,
  `crates/desktop/src/pointer_policy.rs`; `ABI_VERSION` and every existing
  command shape are unchanged. The shell gains `native/desktop/pointer-hover.{h,m}`:
  a tracking area that is always active on each canvas panel of a normal run,
  one `hover` per 60 Hz frame while no button is down and no gesture runs,
  the reply's focus request handed to the navigation coordinator like a
  click's, the motion re-addressed to the window under the pointer through the
  route and validation a click takes, the pick-mode press, drag and release,
  and the swipe; `--no-hover-forwarding` turns off only the delivery of motion
  to applications.
  It was built on `1f44d0f`. Merged onto `f083155`, the pointer has one
  reading in the shell: while camera motion's frame timer runs, each frame
  carries the waiting hover, ahead of cursor edge pan's pointer report and the
  tick, and the hover's own timer runs only while that one does not. What
  holds the pointer now includes a drag pan whose button is down, a trackpad
  gesture between its begin and its end and a scroll pan whose momentum is
  yet to launch, which an optional `time_ms` on `hover` times on the pans' own
  event clock; a coast, a flight and cursor edge pan hold nothing, and no
  hover stops any of them. Below `interact_min` a scroll that finds a canvas
  binding is that milestone's timed pan or wheel `zoom_by`, a drag is a window
  drag with its edge pan, and a trackpad gesture is not changed, as upstream's
  gesture handlers never read pick mode. `pointer_nearest` runs its action
  once through the one action dispatch, with the pointer and a new optional
  `held`, so that dispatch's prelude ends an open cycle and stops the
  output's momentum.
  Merged onto the per-window policy and the rendering milestone above, both
  staged and not committed, the window under the pointer is the layered hit
  (the windows pinned to the output, the canvas windows, the widgets). With
  `focus_follows_mouse` a pinned window under the pointer has the priority and
  takes the focus where it stands, as upstream asks `pinned_window_under`
  first, and stays out of the focus history like every focus of a pinned
  window; a widget is passed over, pinned or not, and keeps the focus where it
  is (`hover_focus_window`); the motion is forwarded to either. The echo of a
  hover on a pinned window is recorded without a raise or a flight. A pick
  target is a canvas window or a stand-in: a pinned window stays interactive
  below `interact_min`, also over a target, a widget is never picked, `pick`
  does nothing with either, and `begin_drag` refuses both as at any zoom. The
  no-raise focus is now `Scene::focus_in_place` in `crates/canvas`, `focus`
  without its raise, in place of a rebuild of the scene through its saved
  form. In the shell the one frame timer carries the waiting hover and the
  pointer report on every frame, also while only an animated background keeps
  it running, a stand-in's hit carries `pick` only when its placement is
  neither pinned nor a widget, and the experimental resize handles are not
  drawn on an output in pick mode.
  Coverage is controller scenarios through the exported C ABI
  (`crates/desktop/tests/pointer_flow.rs`, sixteen scenarios with synthetic
  identities and focus results on an output whose origin is not the global
  origin, two of them for the rules merged from `f083155` and three for a
  pinned window and a widget under the pointer; expected values derived by
  hand from upstream's rules, not from an executed upstream oracle), one build
  that links both sides with
  `-Wall -Wextra -Werror`, and two short scripted launches on 2026-10-10 of the
  built app (`--windowed 1100x700 --manual`, private scene of three detached
  placeholders, config and socket; macOS 27.2, Apple Silicon), which left no
  saved evidence. Exercised there through the socket: a config with
  `focus_follows_mouse = true` and `[zoom] interact_min = 0.5` loading with
  nothing on stderr; eight `zoom-out` actions taking `msg zoom` from 1 to
  0.467, below the threshold, and `zoom-reset` back to 1; a reload with
  `focus_follows_mouse` flipped answering `ok` with nothing on stderr; the file
  watcher reporting upstream's `config: zoom.interact_min -1 below minimum 0,
  using 0` and `config: zoom.interact_min 5 above maximum 1, using 1`; a launch
  with `--no-hover-forwarding` starting and answering `state`, the flag given
  twice exiting 64; exit 0 on SIGTERM with the socket removed. The build
  merged onto `f083155` passed `pointer_flow` with the gesture, motion,
  navigation, lifecycle, platform, config, IPC and view scenarios and the
  coordinator regression, and was launched twice more the same day without
  `--manual` (9 seconds and 1 second, no Screen Recording access): the same
  config loaded with no config line on stderr, `center-nearest right` landed
  on the seeded window at 1950 0 and focused it, `pan-viewport right` moved
  the camera 100 points, `zoom-to-fit` went out and came back, eight
  `zoom-out` actions ended at 0.467 and `zoom-reset` at 1,
  `toggle-cursor-pan` twice and `set-trackpad off` and `on` answered `ok`, the
  reload and the two range warnings came as before, and a launch with
  `--no-hover-forwarding` answered `state`; both exited 0 with the socket
  removed. The build merged onto the per-window policy and rendering passed
  `pointer_flow` with the rules, render, gesture, motion, navigation,
  lifecycle, platform, config, IPC, view and controller scenarios and the
  coordinator regression, and was launched twice the same day (6 seconds and
  under a second, the same three detached placeholders, no Screen Recording
  access): the same config loaded with no config line on stderr,
  `center-nearest right` landed at 1950 0 with the seeded window focused,
  `pan-viewport right` moved the camera 100 points, `zoom-to-fit` went to
  0.2848 and came back, eight `zoom-out` actions ended at 0.4665, where a
  `msg screenshot` of the view showed the focused stand-in on the dot grid,
  `zoom-reset` returned to 1, the reload with `focus_follows_mouse` flipped
  answered `ok`, a `window` screenshot wrote the 900×600 stand-in,
  `toggle-cursor-pan` twice answered `ok`, `msg pin` on a stand-in was refused
  in upstream's words with and without `on`, and a launch with
  `--no-hover-forwarding` answered `state`; both exited 0 with the socket
  removed.
  Evidence boundary: the socket has no pointer and `msg` exposes neither pick
  mode nor `focus_follows_mouse`, so `hover`, sloppy focus, `pick` and
  `pointer_nearest` were exercised only through the controller's C ABI tests;
  in the app only the settings' loading and the zoom crossing the threshold
  were seen. No real pointer motion, no mouse-moved event at a canvas panel, no
  native focus change, no forwarded mouse-moved event, no pick-mode press and
  no swipe was observed in this session, and no window with a bound source was
  on the canvas. What the merges added in the shell (the hover carried by the
  frame timer, also while it serves an animated background alone, the pointer
  reading shared with cursor edge pan's report, the hover standing down for a
  trackpad gesture, a pick-mode scroll that drifts, the handles left off in
  pick mode, a stand-in's pick flag) is compiled and read only, and no pinned
  window and no widget was on the canvas of any launch: a stand-in cannot be
  pinned. Known mismatches: a trackpad gesture in progress
  and a scroll about to launch its momentum hold the pointer from hover,
  which are no pointer grab upstream; the cursor stays the canvas's own (no
  pointing hand over a pick target, no application cursor); no leave is
  delivered when the pointer moves off a window; the native request of a hover
  focus is a click's, so the real window is activated and raised natively
  although the canvas does not restack; the focus history is promoted when the
  request is answered, not at the hover; an open focus cycle blocks hover focus
  where upstream's hover would end the cycle; the echo rule has no upstream
  counterpart; a `pick` returns a filled window to its fill view as
  upstream's does (when that view is at or above the threshold) only behind
  `--experimental-native-resize`, since `fill-window` is gated, and lands at
  zoom 1 in every default launch; pick mode is per output,
  not the active output's; `pointer_nearest` decides from two points, so it is
  upstream's only because the shell sends it once at the first drag event 16
  points from the press; upstream's exclusions for layer surfaces, fullscreen
  and modal windows and client resize margins have nothing to apply to, and
  `pass_mouse` is recorded and never applied; a pinned window is not dragged
  in screen space, below the threshold or above it; a widget below the
  threshold keeps its pointer input, which follows from `input` refusing pick
  targets only and was not compared with upstream's pointer focus for a
  widget there. See the
  [pointer contract](../../crates/desktop/POINTER.md) and the
  [desktop shell notes](../../native/desktop/README.md#pointer-motion-sloppy-focus-and-pick-mode).
- This milestone (commit pending), window sizing, makes DriftWM's sizing
  actions controller policy (`crates/desktop/src/sizes.rs`, adapted from
  upstream's `src/state/{resize,fit,fill}.rs` with driftwm-core's own fill
  search and cluster shifts): `grow-window` and `shrink-window` with
  `[navigation] resize_step` and the opposite edge held, IPC `resize W H`
  keeping the centre, `fit-window` and `fit-window-snapped` with their camera
  flight, saved size and toggle back, `fill-window` with its restore point and
  the view `center-window` returns to, `zoom-to-fit-snapped`, and upstream's
  `Normal` / `Fit` / `Fill` window mode in the IPC state and the snapshot.
  `zoom-to-fit-snapped` moves a camera only and runs in every normal launch.
  The rest end by giving a native window a new size, which goes through the
  existing size-only native resize transaction (`f5007b8`, `6a49484`) started
  without a drag, and that path stays an explicit opt-in: a new command,
  `native_resize_capability`, which the shell sends only when started with
  `--experimental-native-resize`, turns them on, and without it every one of
  them and the IPC resize write answer byte for byte as before. A sizing
  action asks for a size and writes the place, the neighbours' shift and the
  fit or fill state when the native result arrives, for the size the window
  actually took. Evidence boundary: **no native window was resized.** Sizing
  ran only in controller scenarios through the exported C ABI
  (`crates/desktop/tests/sizes_flow.rs`, 21 scenarios when it was built on
  `f083155` alone, 30 with the joins below), in which the test plays
  the native side and answers each resize effect with a made-up result, with
  expected values worked out by hand from upstream's rules and upstream not
  executed as an oracle. Built together with the shell on 2026-10-10 (macOS
  27.2, Apple Silicon), the app was driven twice over a private socket on a
  private scene of three detached placeholders, with no Screen Recording
  access: without the flag the five actions and the resize write answered
  their previous refusals; with it `grow-window`, `shrink-window` and `resize`
  answered the stand-in refusals and the three toggles answered `ok` and
  changed nothing; in both, `zoom-to-fit-snapped` framed a two-window cluster
  at the expected camera and zoom and returned. That is as far as the socket
  reached: a stand-in begins no size transaction, so the shell's hook that
  hands a reply's resize effect to the resize coordinator, its relaxed gates
  during such a transaction, the hot keys, mouse bindings and gestures that
  fire these actions, key repeat on a step and anything drawn are compiled and
  read only, and nothing was saved as evidence. Known mismatches: placement is
  written at the result rather than at the request; one transaction at a time,
  so a second sizing action is continued, replaced or refused where upstream
  sizes any number of windows; native size limits are unknown before asking;
  a step or an IPC resize of a stand-in is refused where upstream resizes the
  stand-in's frame; restore points are lost with the window's source and are
  never saved; upstream's `restore_size` is captured at the first fit or fill
  rather than at a window's first commit, and its configured size is kept only
  for a fit, so a first fit after a step, an IPC resize or a fill the window
  clamped centres on the frame the window took; IPC resize does not raise the
  window; `toggle-fullscreen` is not here. All of the above was built on
  `f083155`. Merged with the three milestones above (per-window policy,
  rendering, pointer policy), every sizing action is a canvas window's, as
  upstream's `is_canvas_window` makes it: with a widget or a screen-pinned
  window focused the five actions and `zoom-to-fit-snapped` do nothing, IPC
  `Resize` answers upstream's `this window has no canvas size to set: …` for
  one before the gate is asked, no size transaction begins for one (the
  refusal `begin_native_resize` already gave), and neither is an obstacle to a
  fill, shoved by a snapped fit or framed by `zoom-to-fit-snapped`; a window
  pinned after a fit or fill keeps its restore point, as upstream's
  `pin_window` clears neither; `send-to-output` ends a canvas window's fill
  and only rebinds a pin; a window rule's `size` is asked of a new canvas
  window once it is placed, through the same entry as IPC resize, when the
  capability is on, and stays recorded and listed in `rule.not_applied`
  when it is off, for a widget, a pinned window and an adopted slot, and for
  a window that maps while another size is owed; a pick below
  `zoom.interact_min` returns a filled window to its fill view when that view
  is at or above the threshold (upstream's `resolve_pick`); `center-window`
  and `focus-center` restore a fill view for canvas windows only; a drag is
  refused in one place for a widget, a pinned window and a window owed its
  size, each in its own words; a size still owed holds the pointer for
  `hover` as a resize drag does; the snapshot's `mode` sits beside `widget`,
  `pinned` and `rule`; and the shell hands a reply's size transaction to the
  resize coordinator from one method, for every action, IPC, gesture and
  pointer reply and for the attach of a ruled window. Nine scenarios added to
  `sizes_flow` and one to `rules_flow` cover those joins, the test again
  playing the native side. Asked with upstream's built-in defaults, the merged
  controller's `bindings` reply lists 45 key bindings of which 42 run without
  the capability, leaving `toggle-fullscreen`, `fit-window` and
  `fit-window-snapped`, and 44 with it; of the 35 action names of upstream's
  grammar it refuses six by name without the capability (those three,
  `grow-window`, `shrink-window`, `fill-window`) and one with it. The same
  requests sent to the controller as it was before this merge and to the
  merged one, with the capability off, on a scene with a canvas window, a
  widget, a rule-pinned window and a ruled size, gave identical raw replies
  (168 and the saved file, read by a throwaway program outside the
  repository) but for `"mode": null` on each snapshot window and
  `zoom-to-fit-snapped` reported implemented. The merged app was launched
  five times on 2026-10-10 on three detached placeholders (private scene,
  config and socket, no Screen Recording access, nothing saved; the first
  ended at once on a mistake in the driving script, before anything was
  asked, and the two that follow were each run twice with the same answers,
  the second time on the final build): without the flag the five actions and the resize write answered
  their refusals unchanged, `zoom-to-fit-snapped` framed a two-placeholder
  cluster at camera `2236 -0` and zoom `0.6385869565217391`, a viewport
  screenshot of it was written and looked at, and `center-nearest`,
  `pan-viewport`, `zoom-to-fit`, `pin` and `opacity` answered as before; with
  the flag the three toggles answered `ok` and changed nothing and
  `grow-window`, `shrink-window` and `resize` answered the stand-in refusals.
  That adds nothing to the evidence boundary: no live window existed in any
  launch, so no size transaction ran in the app by an action or by a rule, no
  rule was resolved, no widget or pinned window existed there and no pointer
  event was sent; the joins ran only as controller scenarios. Further
  mismatches from the join: a rule's `size` is asked after the window is
  placed, where upstream configures it first, and never of a widget or a
  rule-pinned window, where upstream's size arm runs for both; with one
  transaction and nothing queued, of several ruled windows that map at once
  only the first is asked; a pinned window is not sized at all, where
  upstream resizes one in screen space. The feature stays behind
  `--experimental-native-resize` until a live native resize pass exists. See the
  [sizing contract](../../crates/desktop/SIZES.md) and the
  [desktop shell notes](../../native/desktop/README.md#window-sizing-actions).
- This milestone (commit pending), effects: DriftWM's background blur, its
  window open and close animations and stand-in fades, and its on-screen error
  bar. The compositor above is replaced by a superset of itself, built, checked
  against upstream's blur shaders and animation curves and independently
  reviewed outside the repository, then carried in with its notes; it is
  API-additive, and the one provenance line of each file is all that differs
  from that copy. The controller reports, all additive to ABI 1 and never
  saved: `render.effects`, the `[effects]` table as `driftwm-core`'s parser
  left it; `decoration.blur`, `driftwm-core`'s `effective_blur` over the rule
  a window mapped with, false for every stand-in; `render.errors`, upstream's
  config error source under upstream's rules (read failure, parse failure, the
  first warning with a count, cleared by a clean load), a changed message
  spending a render revision; and `lifecycle_events`, the last 32 window
  events upstream animates, each with a serial: `open`, `close`,
  `close_to_standin`, `standin_dismiss`, `standin_adopted`. The shell's
  renderer frosts a blurred window, shows the controller's message and the
  background program's own in upstream's source order in the bar, and plays
  each event once from the frame it last drew: a closing snapshot baked from
  the window's last picture at upstream's density and listed in upstream's
  closing order, alpha only over the stand-in a close leaves, the open
  animation from the window's first picture, and the two stand-in fades, all
  on the one frame timer, which stops when the last ends. macOS rules: the
  windows of the launch pass and a window that takes its own saved slot back
  open nothing, since none of them opened in the canvas; an opening window is
  held invisible until its stream delivers its first picture, a second at
  most. Probe, demo and owned-fixture modes are untouched. Coverage is
  controller scenarios through the exported C ABI
  (`crates/desktop/tests/effects_flow.rs`, against `driftwm-core`'s own parse
  and `effective_blur`), two throwaway offscreen tools outside the repository
  and one scripted launch of the built app on 2026-10-10 (macOS 27.2, Apple
  Silicon, `--windowed`, a private scene, config and socket, three seeded
  placeholders, about 3 seconds), none of which left saved evidence. Seen, in
  frames read back from the app's renderer linked with this controller's
  library and driven through the C ABI with real config files (PNGs opened,
  pixels read): the error bar with the text of an unknown-action warning, of
  three warnings as the first and ` (+2 more)`, of a TOML parse error run into
  one line, and of a config warning followed by a missing shader's message,
  and its absence after a clean reload; the changed `[effects]` values in the
  frame; a controller-placed window opening only from its first picture and
  frosted at opacity 0.6 over a stand-in; its close as a snapshot fading over
  0.71 s at `animation_speed = 0.1`; a close into a stand-in fading in place;
  a relaunched window's adoption crossfade from its first picture; a
  dismissed stand-in shrinking and fading, and nothing played for one the
  output did not show; no pixel buffer retained after a close or a reset.
  Seen with hand-written snapshots only: two outputs, the bake densities, the
  closing order, a pinned snapshot, `animation_speed = 1`. Seen in the app,
  over `msg` and on stderr only: upstream's wording of both config errors,
  viewport captures byte-identical with and without an error and with
  `[decorations] blur` on, two stand-ins dismissed with the app still
  answering, exit status 0 on SIGTERM with the socket removed, and a saved
  scene holding nothing of the effects. Evidence boundary: no run had Screen
  Recording access and nobody looked at the app's panel, so the bar, a frost,
  a fade and an opening window were never seen on a display, and no
  ScreenCaptureKit buffer was ever blurred, opened or closed: every picture
  was a plain-coloured synthetic buffer or a stand-in. `msg` reaches none of
  the three new keys, so in the app they are known only by their effects. The
  frame timer was imitated by a loop at about 25 ms a tick; timing at a
  display's refresh is unmeasured. No pixel was compared with a pixel from
  DriftWM itself. Known mismatches: upstream's keyboard error source does not
  exist (macOS owns the layouts); `animation_speed` reaches no move, resize,
  fit or fullscreen animation, which do not exist here; a window that takes
  its own waiting slot back is not crossfaded; a config file that is refused
  rebuilds the background program once where upstream redraws the bar only;
  each output bakes its own closing snapshot where upstream shares one, and
  upstream's one-second age limit on a closing window's pixels has no
  separate test; a new window is invisible for up to a second and takes
  clicks meanwhile; the error is shown in the status line as well; captures
  hold no closing snapshot or error bar, which was not checked against
  upstream's capture code (only that it omits blur). All of the above was
  built on per-window policy and rendering alone. Merged with pointer policy
  and window sizing, the joins are these. There is one frame timer, and a
  window that opens or leaves keeps it alive exactly as an animated
  background does: it is started without the camera-motion flag, so each of
  its frames carries the waiting hover and cursor edge pan's pointer report,
  ticks no camera and leaves the hot corners to the idle poll, and it ends
  itself with the last animation. A window that opens while a rule's `size`
  is being asked of it (the experimental flag) has no settled picture until
  that size transaction ends, so its opening, and a stand-in fade waiting
  with it, is held until the last of the transaction's effects is answered,
  which the renderer reads from the snapshot's `native_resize`, and for ten
  seconds at most; the milestone's renderer alone would have opened it on a
  picture of the size it was leaving, or after one second on an empty frame.
  `window_closed` for a window whose size is owed is refused and logs
  nothing, and the report accepted once the transaction has drained logs its
  close once. A refused reload answers with `focus_follows_mouse` beside the
  message that spends a render revision. The sizing state and the event log
  sit together in the controller, neither saved; the log, the error message
  and the capability survive a scene `load`. `decoration.blur` and
  `lifecycle_events` sit beside `mode`, `pick` and the policy keys. One
  addition was made with the merge: `forget`, the shell's ⌃⌥-click on a
  placeholder, now logs `standin_dismiss` for what is drawn as a stand-in, so
  that dismissal fades like the others; a bound window it removes logs
  nothing. Coverage of the joins: `effects_flow` gained the `forget` cases
  and a scenario for a size that is owed, the test playing the native side
  (one `open` at the map; `native_resize` naming the window with its pending
  effect through the baseline read and the setter; the refused close leaving
  the whole snapshot unchanged; one `close` after the adapter's
  `missing_window`; a delivered size logging nothing more), and the whole
  reply of a refused reload; the `forget` rule was broken two ways and the
  scenario failed each time. A throwaway offscreen tool outside the
  repository linked the merged `canvas-renderer.m`, the compositor and the
  background module, fed them hand-written snapshots and asked
  `-animates:draw:` whether an open had begun: with a size owed, not on a
  picture delivered during the baseline read, not 1.3 s on, not when the
  transaction had just ended without a settled picture, and then on the
  first settled picture, or at the next description that had one; with no
  size transaction, on the first picture or after a second, as before; after
  a transaction that left no picture, one second later; with an effect never
  answered, after ten seconds and one more. Built against the milestone's own
  renderer the same tool reported the open begun on the baseline-read picture
  and at one second on nothing. The tool drew no frame: it shows when the
  frame description says an animation runs, not a pixel. The merged app was
  launched once on 2026-10-10 (macOS 27.2, Apple Silicon, `--windowed
  1100x700`, a private scene, config and socket, three seeded placeholders, 6
  seconds, no Screen Recording access, nothing saved). `center-nearest
  right`, `pan-viewport right` and `zoom-to-fit` and back landed at `1950
  -0`, `2050 -0`, `750 -390` at 0.28484848484848485 and `2050 -0`;
  `zoom-to-fit-snapped` answered `ok` and framed the focused placeholder at
  `1950 -0`, zoom 0.7933333333333333, and back; the five sizing actions and
  `msg resize` answered their refusals without the flag. An unknown action in
  `[keybindings]` and `reload-config`: `config: invalid action
  'no-such-action': unknown action: no-such-action` on stderr, twice, and
  `state` still answered; a file with `[effects] blur_radius = 4`,
  `animation_speed = 0.25` and `[decorations] blur = true` reloaded with
  nothing more on stderr. Three viewport captures, before the error, with it
  and with blur on, were the same bytes, and the picture, looked at, is the
  focused stand-in on the dot grid with no bar and no frost. `focus --id 2`
  and `close-window` left two windows and no focus; a capture taken at once
  and one a second later were the same bytes, the dot grid alone. Exit status
  0 on SIGTERM, the socket removed, a saved scene of two windows holding
  nothing of the effects. That adds nothing to the evidence boundary: no live
  window existed, so nothing opened or closed in the app, no rule or size
  transaction ran there and the held opening exists only in the tool's
  hand-written snapshots; nobody looked at the panel, so the dismissal's fade
  is known only to have left the app answering; no pointer event was sent, so
  the ⌃⌥-click's fade, a hover on a frame that only an animation keeps alive
  and the timer stopping after one are compiled and read, not run; the app
  was not launched with `--experimental-native-resize` for this merge.
  Further mismatches from the join: an opening window waits for the size it
  is owed, ten seconds at most, and then opens as it is, where upstream has
  no such wait because a window's first sized commit already has its rule's
  size; a window whose picture is withheld when it closes (its size still
  owed, or left unsettled by the last resize) fades from nothing; a `forget`
  fades a placeholder but moves the focus by none of upstream's rules. See the
  [effects contract](../../crates/desktop/EFFECTS.md), the
  [desktop shell notes](../../native/desktop/README.md#blur-window-animations-and-the-error-bar)
  and the [compositor notes](../../native/desktop/COMPOSITOR-NOTES.md),
  Part II.

These milestones add evidence to partial rows. None satisfies an entire native
behavior row or changes the completion requirement.

## Native feasibility gates

Before expanding the capture architecture, prove its treatment of real native
window families: two windows in one app, child panels, sheets, menus, popovers,
modal dialogs and IME candidate surfaces. Test independent camera views,
clipping, input target/focus, outside-frame pointer grabs and lifecycle. Separate
actual pixels/native effects from successful API calls and logical projections.

The `desktopIndependentWindow` ScreenCaptureKit filter selects a specified window.
The owned macOS 27.2 experiment observed grouped parent/child pixels despite that
selection, so native geometry cannot be inferred from the selected window alone.
SDK documentation scopes `includeChildWindows` to display-bound window and
application sharing; setting it is not proof of arbitrary popup capture.
See [Apple's filter contract](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:))
and [child-window property](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/includechildwindows).

Native resizing requires exact fresh AX/native identity and observed accepted
geometry, including constraints, rejections and timeouts. A stretched capture is
not native layout resizing. A single WindowServer transform cannot provide two
different views of one window; a privileged path still needs an independently
verified surface and interaction model. Disabling SIP alone establishes none of
these capabilities.

Other unresolved authority gates are exclusive global gestures while an app owns
keyboard focus, relative/confined input, native cross-app drag-and-drop, secure
capture/input suppression around lock, and display mode/scale/rotation/power.
The available public APIs cover parts of these behaviors; missing public APIs
are not by themselves proof that private implementations are impossible.

## Work order

1. Maintain the source-pinned inventory and define each row's exact acceptance.
2. Run owned-fixture native family, input and geometry capability proofs.
3. Review those proofs before choosing the native family/input architecture.
4. Port policy semantics with differential traces against pinned upstream:
   snapping, constraints, cameras, navigation, focus, fullscreen and placement.
5. Integrate compatible configuration, IPC, sessions, renderer and native actions
   through stable module boundaries, with one integration owner.
6. Verify platform services and any required client compatibility.
7. Run acceptance on M5/macOS 26 and required physical displays/devices, plus
   representative native application families and failure/recovery cases.

Policy work can proceed while native feasibility remains open. A failed or
unproven native gate must remain visible; it cannot be hidden by progress in
unrelated features. Tests stay focused on changed paths and touched modules.
