# Infinify

A GPL-3.0-or-later Rust/macOS development port of [DriftWM](https://github.com/malbiruk/driftwm), targeting Apple Silicon and macOS 26+. The objective is a persistent infinite canvas containing live native Mac windows, with independent output cameras, pan/zoom, correct native input, focus, and recovery.

**An experimental native app is available.** It displays live captured Mac windows on a persistent canvas, with an independent camera for each connected display. Panning and zooming change the views while the original windows remain in place. The same source can appear through multiple cameras. The app uses a Rust canvas/controller and an Objective-C desktop shell.

Disposable AppKit fixtures verify live content, clipping, camera gestures and native button, text and scroll input. Broad third-party application compatibility and physical multi-display behavior remain unverified. This is a development build, not a complete replacement for the macOS desktop.

The completion requirement is **exact DriftWM behavior for native Mac apps**.
The [source-pinned parity contract](docs/parity/README.md) tracks known differences
and required proof. Literal Wayland/X11 client hosting is outside the agreed scope.

## Run the app

From `/Users/gad/Documents/code/personal/infinify`:

```sh
./scripts/build-app.sh
open target/app/Infinify.app
```

Choose the windows to add. Drag blank canvas or Option-drag to pan, use Command-scroll or pinch to zoom, and Control-Option-drag a window to move it in the world. Normal clicks and scrolling reach its native application; that application retains keyboard focus. Return to desktop closes the canvas panels. Quit with the visible button or Control-Option-Escape.

Screen Recording access is needed for capture and Accessibility access for native input. The chooser explains missing access. The build and tests do not change privacy settings or SIP. The capture-based app does not require disabling SIP; its private input path still needs validation on each supported macOS release.

Saved scenes retain world positions and display cameras. On restart, windows appear as detached placeholders and must be explicitly rebound through the chooser. Native resizing, popovers, context menus and richer pointer interactions are unfinished. See the [desktop app guide](native/desktop/README.md) for the disposable demo, exact controls, persistence and limitations.

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
  checks pass; its live focus and cleanup scenarios remain unrun.
- [Window family diagnostic](native/families/README.md): genuine native panels
  and sheets exposed a failed capture-placement assumption. Metadata normalization
  now passes saved-pixel checks for a right-extending panel and an in-bounds sheet
  through two views. Parent discovery, other popup extents and native interaction
  remain unproved; this is not a supported popup compositor.

A complete deliverable still requires broader native application compatibility, native layout resizing, popovers and dialogs, richer input, and validation of display hotplug, hidden/minimized sources and multiple physical displays. Overlapping independent output cameras require separate live surface instances for the same window; one global WindowServer transform cannot satisfy that requirement. The capture app implements those separate instances, while the transform helper remains a separate experiment. The development host runs macOS 27.2, so a deployment target of 26.0 does not establish runtime verification on macOS 26. Private WindowServer interfaces require runtime validation for each supported macOS release; this repository does not claim that SIP-enabled or SIP-disabled third-party control is already proven.

The code separates the canvas (`crates/canvas`), platform boundary (`crates/macos-backend`, `native`), and CLI (`crates/driftwm`). See [NOTICE](NOTICE) for the pinned upstream baseline and provenance, and [LICENSE](LICENSE) for GPL terms.
