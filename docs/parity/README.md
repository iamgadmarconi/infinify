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
- This milestone (commit pending), window lifecycle: every ordinary application
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
