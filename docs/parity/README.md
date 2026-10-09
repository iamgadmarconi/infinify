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
- This milestone (commit pending) configures the default shell exactly as DriftWM
  is configured: one TOML file in upstream's grammar, parsed by `driftwm-core`,
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
  a bound source; one output only. Nineteen of upstream's default key bindings and
  four of its default mouse bindings name actions that still do not run, media
  keys are not registered, and trackpad and touch gesture bindings, window rules,
  decorations, effects, backgrounds, input-device settings and every other setting
  whose feature is absent are parsed and unused. See the
  [desktop shell notes](../../native/desktop/README.md#configuration) and the
  [configuration contract](../../crates/desktop/CONFIG.md).

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
