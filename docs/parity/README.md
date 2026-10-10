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
  focus request is still in flight, not after it; `center-window` is always
  Reset because there is no fill; `auto_navigate_on_click` pans at a completed
  click's release as upstream does, without upstream's title-bar double-click
  deferral; every canvas press ends an open cycle at the press; an IPC
  `cycle-windows` is always one committed step; the pointer `center-nearest`
  swipe and `focus_follows_mouse` are absent, and so was
  `auto_navigate_on_close` until the window lifecycle milestone below. See the
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
- `f083155`, camera motion, makes the camera move as
  DriftWM's does. The
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
  bindings one by one: 13 run, 7 are refused by name and the 2 resizes are
  gated. On 2026-10-10 that build was driven once over its socket (6.9
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
  oracle; nothing drawn was observed. Seven of upstream's default gesture
  bindings name four actions that still do not run (`zoom-to-fit-snapped`,
  `fit-window`, `fit-window-snapped`, `toggle-fullscreen`), gesture resize is
  gated with native resize, an unbound
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
  order. Known mismatches: a rule's `size` and `fullscreen` are recorded
  and not applied (native resize is gated), and `blur`,
  `preserve_aspect_ratio`, `pass_keys`,
  `pass_mouse` and `layer_order` are recorded with no effect (`decoration`
  and the border, corner and shadow fields are drawn, see the rendering
  milestone below); a pinned window
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
  upstream's built-in defaults, the merged controller's `bindings` reply lists
  45 key bindings of which 41 run, leaving four on actions that do not
  (`toggle-fullscreen`, `fit-window`, `fit-window-snapped`,
  `zoom-to-fit-snapped`), and of the 35 action names of upstream's grammar it
  refuses seven by name (those four, `grow-window`, `shrink-window` and
  `fill-window`). The merged
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
  `[effects]` and every window animation are not drawn; `cache_shader` is
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
