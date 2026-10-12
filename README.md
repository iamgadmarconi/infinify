# Infinify

A GPL-3.0-or-later Rust/macOS development port of [DriftWM](https://github.com/malbiruk/driftwm), targeting Apple Silicon and macOS 26+. The objective is a persistent infinite canvas containing live native Mac windows, with independent output cameras, pan/zoom, correct native input, focus, and recovery.

**An experimental native app is available.** It displays live captured Mac windows on a persistent canvas, with an independent camera for each connected display. Panning and zooming change the views while the original windows remain in place. The same source can appear through multiple cameras. The app uses a Rust canvas/controller and an Objective-C desktop shell.

Disposable AppKit fixtures verify live content, clipping, camera gestures and native button, text and scroll input. Broad third-party application compatibility and physical multi-display behavior remain unverified. A normal run now takes the place of the desktop ([Using Infinify as your desktop](#using-infinify-as-your-desktop)), but this is a development build and not yet a complete replacement for it.

The completion requirement is **exact DriftWM behavior for native Mac apps**.
The [source-pinned parity contract](docs/parity/README.md) tracks known differences
and required proof. Literal Wayland/X11 client hosting is outside the agreed scope.

## Run the app

From `/Users/gad/Documents/code/personal/infinify`:

```sh
./scripts/build-app.sh
open target/app/Infinify.app
```

A normal run is the desktop: one canvas panel covers each display whole, on every Space, under the menu bar and the Dock, with no toolbar, no status line and no chooser. With Screen Recording and Accessibility access the canvas opens at once and every real application window on screen (a standard window or a dialog, not a popup or a helper window) joins it by itself; while either is missing one small window names it and offers its Allow button, and the canvas opens once both are there. Stage Manager has to be off as well: it keeps every window outside the current stage as a thumbnail in its strip, which is then all a canvas could show of it, blurred and still, and a click meant for the window lands on the thumbnail. The same small window says so and offers a button that opens Desktop & Dock; Infinify reads the setting and never changes it, and the canvas opens as soon as it is off. Switched on under a running canvas, it is named once on stderr. With `--manual` the chooser comes first and only the windows chosen there are added, and `--windowed` opens the canvas in one ordinary window instead. Owned-fixture capture and native geometry checks have run with Screen Recording access; broad third-party acceptance remains open. See [Desktop mode](native/desktop/README.md#desktop-mode) and [Managed windows](native/desktop/README.md#managed-windows). With no config file, DriftWM's default bindings apply under the default super key (Command): drag blank canvas or Command-drag anywhere to pan; use the mouse wheel on blank canvas, Command-scroll anywhere, or pinch to zoom; and Option-drag a window to move it in the world (add Shift to move its snapped cluster). A DriftWM-grammar config file or `--super` changes these; see [Configuration](native/desktop/README.md#configuration). Unmodified clicks and scrolling on a window reach its native application; that application retains keyboard focus. Quit with Control-Option-Escape, Control-Command-Shift-Q or `Infinify msg action quit`: quitting closes the canvas panels and returns the native desktop.

Screen Recording access is needed for capture and Accessibility access for native input. The permission window explains missing access. The build and tests do not change privacy settings or SIP. The capture-based app does not require disabling SIP; its private input path still needs validation on each supported macOS release.

Saved scenes retain world positions. Display cameras are saved too, but are restored on restart only with `[session] restore_camera = true`; with DriftWM's default (off) each display starts with its top-left corner on the world origin at zoom 1. On restart a managed launch returns running windows to their saved slots, matched by application and title, places the others as new windows, and drops the slots nothing matched unless `[session] restore_windows = true` keeps them as stand-ins; with `--manual`, saved windows appear as detached placeholders and are rebound through its chooser. Without Screen Recording access a normal run shows the permission window instead of the canvas, and a `--windowed` run shows the placeholders with no way to rebind them. Native resizing, popovers, context menus and richer pointer interactions are unfinished. See the [desktop app guide](native/desktop/README.md) for the disposable demo, exact controls, persistence and limitations.

Window navigation is part of every normal launch: Command-arrows jump to the
nearest window, Command-C centres the focused one, Option-Tab cycles windows
most recently focused first, and a click focuses the window it lands on. With
Accessibility access the focused window's real window is activated and raised;
`--no-native-focus` keeps focus logical. The actions were driven live through the IPC socket on detached
placeholders. Native focus and click forwarding now also pass on disposable
scoped fixture windows; physical hot keys and event delivery still need desktop
validation. See
[Window navigation and native focus](native/desktop/README.md#window-navigation-and-native-focus).

DriftWM's sizing actions (Command-M fits the focused window,
`grow-window`, `shrink-window`, `fill-window`, `Infinify msg resize W H`), a
window rule's `size` and fullscreen (Command-F) act on the real window in
every normal run: the size is asked through Accessibility and read back, and the
canvas takes the size the application allowed. They have been run end to end on
disposable fixture windows and an Electron window
(`tests/e2e/scoped-sizing.sh`), not yet on real applications. See
[Window sizing actions](native/desktop/README.md#window-sizing-actions) and
[Fullscreen](native/desktop/README.md#fullscreen).

Pointer borders and configured resize gestures use the same readback path in
every normal run. Owned physical and scoped resize scenarios cover the supported
path; arbitrary application behavior and independent display-boundary clipping
still need validation. The former orange-handle mode and its UI-driving probe
have been removed. Their failed attempts remain as
[historical resize evidence](native/desktop/README.md#experimental-native-resizing).

## Using Infinify as your desktop

The [cooperative native presentation backend](native/desktop/README.md#native-presentation-through-a-cooperative-helper)
can now present real fixture windows with pan, zoom, focus, resize and recovery.
Its scoped end-to-end test passed three times on macOS 27.2, including independent
transform and alpha restoration checks. Finite helper scopes remain available for owned fixtures. The owner-run `native-desktop` command and `scripts/start-native-desktop.sh` prepare whole-desktop admission through an authenticated Dock helper; normal startup does not inject one. The installed command uses only signed files inside its `.app` bundle, while the repository script also checks that a selected bundle matches the current checkout. Third-party native compositing and native clipping remain unvalidated, and the current host has not passed injection preflight.

DriftWM is the session, not an app one launches, and a normal run of Infinify is meant the same way: installed, started at login, and there until you quit it. These four steps are for you to run; no script or agent here installs, signs with your identity or registers a login item, and none of the four has been run yet. The login item remains the regular capture-mode startup. Full-desktop helper mode is a separate explicit terminal action and is not started at login.

1. **Install.** `INFINIFY_SIGN_IDENTITY="<your signing identity>" ./scripts/install-app.sh` builds the app with that identity, then copies the exact signed bundle to `~/Applications/Infinify.app`. The bundle carries the doctor, arm64e loader, payload, and standalone launcher; installation verifies the outer signature, executable hash, and helper hashes. `security find-identity -v -p codesigning` lists identities. Without the variable the build is signed ad hoc, and macOS drops both grants on each reinstall. With `--built`, the installer preserves the identity already used for that build.
2. **Grant access once.** `open ~/Applications/Infinify.app`. A small window names what is missing: click Allow screen recording… and Allow input…, switch Infinify on in the two System Settings panes they open, then click Relaunch (macOS gives Screen Recording only to a newly started app). The canvas opens over the whole display, under the menu bar and the Dock, and takes the windows that are open. Quit it again with Control-Option-Escape before the next step.
3. **Turn the login item on.** `~/Applications/Infinify.app/Contents/MacOS/Infinify login-item on` starts Infinify now, at every login, and again after a crash; macOS may ask you to allow it under System Settings > General > Login Items & Extensions. `login-item status` reports it and `login-item off` removes it and ends the instance it started.
4. **Quit** with Control-Option-Escape, Control-Command-Shift-Q or `~/Applications/Infinify.app/Contents/MacOS/Infinify msg action quit`. The scene is saved, the panels close and the native desktop is back; a quit is not restarted. Infinify starts again at the next login, or at once with `launchctl kickstart gui/$(id -u)/com.marengox.infinify.agent`.

To opt into full-desktop helper mode, first quit any regular Infinify instance,
then run `~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop`
from a terminal. Its `native-desktop --check` form verifies the bundle and runs
the read-only doctor without sudo, runtime creation, helper loading, or app
launch. The launch command may ask for the owner’s explicit sudo authorization
for the loader; only that loader runs as root, and the app then runs as the login
user. `scripts/start-native-desktop.sh --app /absolute/path/Infinify.app` is the
checkout-aware alternative; it also requires the bundle to match the current
source snapshot. Neither entrypoint establishes ordinary third-party compositing
or native clipping readiness.

There are no buttons and no status line: keys, pointer gestures and `Infinify msg` do everything, and status notes go to stderr, which a run started at login does not show. Windows may sit under the menu bar and the Dock, which both stay. The [desktop app guide](native/desktop/README.md#desktop-mode) lists what else changes and the known limits, among them that a window whose capture macOS stops across sleep is not captured again by itself, and that nothing prevents a second instance (which is why step 2 ends with a quit).

## Build and inspect

Install Rust (1.88+), Xcode command-line tools, and the macOS SDK on an Apple Silicon Mac running macOS 26+. The build sets `MACOSX_DEPLOYMENT_TARGET=26.0`.

```sh
./scripts/build-macos.sh
./target/release/driftwm doctor --json
./target/release/driftwm windows --json
./target/release/driftwm --help
```

Build verification on 2026-10-09: release build, `cargo check -p driftwm-macos`, targeted CLI clippy, and all five `cli_scenarios` tests passed on arm64 macOS 27.2 with Rust 1.96.0. The release binary reports Mach-O minimum macOS 26.0; macOS 26 runtime execution remains untested. Release stripping is disabled because this host toolchain produced procedural-macro libraries with a misaligned Mach-O LINKEDIT string pool when stripping was enabled.

`doctor` and `windows` are read-only and do not request permissions or change system settings. Doctor reports the actual host and backend observations, including limitations. Window metadata visibility depends on macOS permissions. No SIP state change is performed by this project.

## Canvas scenarios

Replay runs the actual `driftwm-canvas` reducer and persistence code. It never changes native application windows. Use an existing state directory to keep saved scenes separate from the source fixtures:

```sh
mkdir -p /tmp/driftwm-scene
cargo run -p driftwm-macos --bin driftwm -- scenario tests/e2e/scenarios/pan_zoom_persist.json --state-dir /tmp/driftwm-scene --json
cargo run -p driftwm-macos --bin driftwm -- scenario tests/e2e/scenarios/multiple_outputs.json --json
cargo test -p driftwm-macos --test cli_scenarios
cargo check -p driftwm-macos
cargo clippy -p driftwm-macos --all-targets --locked -- -D warnings
```

A scenario is JSON with `version: 1`, `name`, and an `operations` array. The checked-in fixtures are executable examples. `scene` is an alias for `scenario`. Rectangles use `[x, y, width, height]`, points use `[x, y]`, and identifiers are unsigned integers.

| Operation | Fields |
|---|---|
| `add_window` | `id`, `rect`, optional `title` |
| `add_output` | `id`, `bounds`, `camera`, `zoom` |
| `pan` | `output`, `delta` in screen points; positive X reveals the right |
| `zoom` | `output`, absolute `zoom` (0.001–1.0), global screen `anchor` |
| `set_window_rect` | `window`, `rect` in world points |
| `assert_positions` | exhaustive `placements`, each with `window`, `output`, `screen`, optional `clip` and `source` |
| `assert_hit` | `output`, global screen `point`, expected `window` or `null`, optional unscaled `local` |
| `save`, `load` | relative `path` under the state directory (scenario directory by default) |

Assertions use a 0.000001-point tolerance. Failures exit nonzero and identify the operation. Unknown fields and unsupported versions fail. The output labels its evidence `canvas_reducer_and_persistence_only`; scene persistence contains logical state and does not establish identity across application relaunches. A persisted CGWindowID or PID is a transient observation, never sufficient on its own to adopt a window after restore. Runtime restoration must reconcile fresh application identity and reject stale or reused native IDs. Treat scenario files as trusted local input: they can replace scene files in the selected state directory.

## Native fixture probe

```sh
cargo build -p driftwm-macos-backend --bins
cargo run -p driftwm-macos --bin driftwm -- fixture-probe --json
```

The native probe is a bounded experiment against an explicitly created disposable fixture. Read the returned evidence and errors before drawing conclusions. It is not a command to control arbitrary desktop applications. The native boundary reports capabilities separately from verified operation; missing permissions or unavailable private APIs remain blockers rather than simulated passes.

## Components and verification

Additional experimental paths are available separately:

- [Transform helper](native/privileged/README.md): explicit native enrollment,
  authenticated local IPC, durable original-state records and lease restoration.
  Its cooperative fixture passes; Dock injection and control of ordinary
  applications remain untested.
- [Scene/runtime bridge](crates/runtime/README.md): applies camera projections to
  one enrolled native window and verifies actual screen geometry. Live tests
  preserve world coordinates and restore after controller termination.
- [Live surface views](native/surfaces/README.md): two independent views of a
  cooperating process's live Core Animation content, verified through changing
  pixels, scaling and clipping. Acquiring an ordinary application's window
  surface and routing input through those views remain separate work.
- [Captured native windows](native/captured-windows/README.md): live per-window
  streams shown through two views while the source stays at its original desktop
  position. Disposable AppKit fixtures verify native button, text and scrolling
  input. This is a separate rendering path from the cooperative layer experiment;
  it does not require the source to export its own layer context.
- [Desktop controller](crates/desktop/README.md): a Rust library and C interface
  joining real canvas geometry, camera gestures, transient source bindings,
  clipped placements, input coordinates and persistent unbound placeholders.
  Its [focus contract](crates/desktop/FOCUS.md) adds one window/stacking authority,
  confirmed focus history and held cycling, with stale native results rejected.
  [Normal-window navigation](crates/desktop/NAVIGATION.md) adds animated camera
  targets, cancellation and current-camera persistence through the same C API;
  native shell dispatch and frame scheduling remain unfinished.
- [Native desktop app](native/desktop/README.md): a signed local app bundle,
  explicit source chooser, per-display panels, shared live streams, native input,
  world dragging, camera controls and saved scenes.
- [Native resize adapter](native/resize/README.md): exact AX window identity,
  observed accepted geometry, constraints/rejection and restoration, verified on
  disposable windows. The [controller transaction](crates/desktop/NATIVE_RESIZE.md)
  adds coalescing, actual-size settlement and capture/input gates; native shell
  integration and an end-to-end run through both components remain unfinished.
- [Native focus adapter](native/focus/README.md): exact selected-window requests,
  external focus readback and guarded input checks. Source review and nonmutating
  checks pass. Live normal-path attempts pass the repaired readiness handshake
  but stop before focus/input at the activity guard; cleanup-specific scenarios
  remain unrun. Failed attempts are retained as evidence.
- [Window family diagnostic](native/families/README.md): genuine native panels
  and sheets exposed a failed capture-placement assumption. Metadata normalization
  now passes saved-pixel checks for a right-extending panel and an in-bounds sheet
  through two views. Parent discovery, other popup extents and native interaction
  remain unproved; this is not a supported popup compositor.

A complete deliverable still requires broader native application compatibility, native layout resizing, popovers and dialogs, richer input, and validation of display hotplug, hidden/minimized sources and multiple physical displays. Overlapping independent output cameras require separate live surface instances for the same window; one global WindowServer transform cannot satisfy that requirement. The capture app implements those separate instances, while the transform helper remains a separate experiment. The development host runs macOS 27.2, so a deployment target of 26.0 does not establish runtime verification on macOS 26. Private WindowServer interfaces require runtime validation for each supported macOS release; this repository does not claim that SIP-enabled or SIP-disabled third-party control is already proven.

The code separates the canvas (`crates/canvas`), platform boundary (`crates/macos-backend`, `native`), and CLI (`crates/driftwm`). See [NOTICE](NOTICE) for the pinned upstream baseline and provenance, and [LICENSE](LICENSE) for GPL terms.
