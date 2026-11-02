# Native tests

The regressions and fixture programs under `tests/native`, the end-to-end scripts in `tests/e2e/` that build and run them, and the focused fixture validation of the Dock helper.

Run the regression a change touches, not the whole set. The scripts build what they need (`xcrun clang`, some also `cargo build -p driftwm-desktop --release`) and need an Apple Silicon Mac. The controller scenarios are `crates/desktop/tests/*_flow.rs` (`cargo test -p driftwm-desktop`), driven through the exported C ABI.

**In memory.** No window, event tap, permission request or application launch; they prove the policy or decision they name with substituted native calls, not that a real application accepts it.

| Script | What it covers |
| --- | --- |
| `tests/e2e/background-tiff.sh` | Crafted TIFF files and a fixed-seed mutation run through the real tile source and background program: a picture, or an error and the dot grid, never a crash |
| `tests/e2e/capture-configuration.sh` | The capture request and rate state |
| `tests/e2e/compositor-lifetime.sh` | The production CPU lifetime fence of the compositor's resources, and per-axis stale-frame destination/source geometry and uncovered placeholder strips |
| `tests/e2e/controller-hit.sh` | The real controller's `{"hit": null}` answer through the shell's hit-reply helper, and pick-mode motion (`DWPickMotion`) |
| `tests/e2e/desktop-navigation.sh`, `tests/e2e/desktop-resize.sh` | The navigation coordinator and the resize coordinator and driver, with the real Rust library |
| `tests/e2e/family-geometry.sh` | Production renderer queries on family geometry |
| `tests/e2e/ipc-limits.sh` | DriftWM v0.21.0's IPC limits and the screenshot write, on the production IPC server and PNG writer |
| `tests/e2e/mac-wallpaper-refresh.sh` | The wallpaper refresh timing policy |
| `tests/e2e/multitouch-source.sh` | Synthetic MultitouchSupport contact records through the adapter into the recogniser, and the Dock-control decision |
| `tests/e2e/native-daemon.sh` | The launch daemon's and the Dock reloader's decisions |
| `tests/e2e/native-display-space-cache.sh`, `tests/e2e/native-placement-validation.sh`, `tests/e2e/native-presenter-readiness.sh`, `tests/e2e/native-view-transfer.sh`, `tests/e2e/native-family-recovery.sh`, `tests/e2e/root-capture-mailbox.sh` | The presenter and its verifiers: display queries, placement validation, ACK readiness, whole-family frame caps and ranking (`DWNativePresenterFrameLimitTests.m` in `native-presenter-readiness.sh`), snapshot retry for existing/absent windows (`DWNativePresenterTests.m`), view transfer, family recovery, the capture mailbox and stale-frame point-size/jitter/reset checks (`root-capture-mailbox.sh`) |
| `tests/e2e/native-focus.sh`, `tests/e2e/native-frame-restore.sh` | The shipped focus adapter's refusals through its C ABI, and the resize adapter's frame regression |
| `tests/e2e/native-decorations.sh` | The title-region classifier over Accessibility shapes recorded in the guest (Chrome tab strip, Chrome with vertical tabs, TextEdit, Finder) and Aside's tab-sidebar window as dumped on its owner's Mac, AX calls substituted (179 checks) |
| `tests/e2e/native-input-policy.sh` | The adapter's packet policy, including the native-drag takeover |
| `tests/e2e/native-launcher.sh` | The bundled launcher's modes against a signed stand-in bundle built from `tests/native/dock-helper/Loader/NativeLauncherFixture.c` (it skips itself where an Infinify process is running) |
| `tests/e2e/privileged-regression.sh` | The Dock helper payload and its C client |
| `tests/e2e/system-takeover.sh` | The Stage Manager and window-tiling takeover against an in-memory preferences store |
| `tests/e2e/window-discovery.sh`, `tests/e2e/window-events.sh` | Window metadata and scheduling, the application/KVO lifecycle, and per-PID lane ordering, independent progress, idle release/recreation, caller-PID unwatch and off-main teardown (`DWWindowEventsQueueTests.m` in `window-events.sh`) |

The frame-limit, PID-lane, snapshot-retry and stale-frame checks are headless,
not proof of usable third-party native-window compositing. Snapshot-retry checks
query real window metadata read-only; submissions stay in memory.

**Live.** They start disposable fixture applications of their own and end them on every exit; each prints `LIVE NOT RUN` without its flag.

| Script | What it covers | Needs |
| --- | --- | --- |
| `tests/e2e/scoped-windows.sh --live-owned-fixture` | The managed product on fixture windows (`--only-pid`): focus, clicks through `DebugPointer` | Accessibility; takes the foreground |
| `tests/e2e/scoped-sizing.sh --live-owned-fixture`, `tests/e2e/scoped-resize-drag.sh --live-owned-fixture` | Sizing actions, `msg resize`, a rule's size and `toggle-fullscreen`; the pointer resize | As above |
| `tests/e2e/scoped-native.sh --live-owned-fixture`, `tests/e2e/native-drag-drop.sh --live-owned-fixture` | Native presentation against the cooperative host of `tests/native/dock-helper/Payload/HostFixture.m`; a drag between two owned processes | Owned fixtures, WindowServer reads |
| `tests/e2e/scoped-native-decorations.py`, `-family.py`, `-group.py`, `-panels.py` (`--live-owned-fixture`) | The green control, a root with a popup and a sheet, two cooperative helpers, an owned utility panel | As above |
| `tests/e2e/physical-resize-edge.sh --live-owned-fixture` | One guarded physical right-edge drag per mode, on owned windows | Real CGEvents |
| `tests/e2e/privileged-fixture.sh --live-owned-fixture` | The protocol v2 server on hosts holding only owned fixture windows | Owned fixtures |
| `tests/e2e/compositor-dnd.sh --live-guest` | Real-HID drag-and-drop between two fixtures drawn away from their native frames, driven by `tests/native/app/CompositorMode/CompositorDnDHIDFixture.c` | A disposable guest running Infinify in compositor mode (`DND_GSSH`, `DND_GSCP`) |
| `tests/e2e/native-frame-cap.sh --live-guest` | The whole-family frame cap under `INFINIFY_DEBUG_NATIVE_MAX_RECORDS=3` (four host windows: presentation continues, three records, a focused omitted window joins and is drawn at its placement, each omitted family logged once, under 2 frames/s at rest) and an oversized focused family under a limit of 1 (presentation ends with the record-limit line, every window restored) | A disposable guest (`GUEST_SSH`, optional `GUEST_INFINIFY`); scoped native presentation of the cooperative host |
| `tests/e2e/native-snapshot-race.sh --live-guest` | Windows of the cooperative host (`--churn 8`) closing while camera pans keep frames naming them: presentation continues, no closed window stays in the frame, the rest stay placed, under 2 frames/s at rest; exit 3 (NOT REACHED) when the helper never answered `DW2_SNAPSHOT` | As above |
| `tests/e2e/capture-stale-frame.sh --live-guest` | Capture overlay: `StaleFrameFixture.m` grows and shrinks itself after a scoped `DebugCapture` interrupt while `CanvasRecorderFixture.m` records Infinify's panel at 60 fps; no recorded frame scales the 40-point markers, stale pictures stay top-left anchored and cropped; exit 3 when no stale frame was recorded. `msg screenshot` cannot show retained pictures (it takes fresh snapshots) | As above; Screen Recording for the guest's ssh session |
| `tests/e2e/zero-screen-keys.sh --live-guest` | `INFINIFY_DEBUG_HIDE_SCREENS` on a `--manual` desktop run: no key at all before a panel ever opened, the full set with panels, own keys only (no system key filter) after a runtime loss of every display, and a posted Control-Option-Escape (`ExitChordFixture.c`) quitting then; the chooser's Open canvas is clicked with `ChooserClickFixture.c` | As above; HID events in the guest |

The four `--live-guest` scripts share `tests/e2e/live-guest-lib.sh` and run
`tests/e2e/stability-guest-driver.py` inside the guest, in a fresh
`/tmp/infinify-NAME.PID` holding the fixtures; the driver starts the fixtures and
Infinify there, ends them on every exit, and the script removes the directory
and its processes and copies the evidence back under `target/ipc/`. They expect an
Infinify build in the guest (`$HOME/infinify-port/target/app/Infinify.app` by
default); `scripts/build-app.sh` needs a git checkout and Xcode's `actool`, so a
bundle built on the host can be copied there. Exit 3 means not run or not reached.

## Focused fixture validation

`./tests/e2e/privileged-fixture.sh` builds only by default. Passing
`--live-owned-fixture` explicitly runs `DWPayloadFixtureTests.py` against spawned,
finite-window cooperative hosts. Individual scenarios can be selected directly
with `--inspect`, `--startup`, `--release-window`, or `--enrollment` after building.
`--client-restore` checks only C restore exit status; `--recovery` selects recovery
and read-only audit groups. `--client-and-recovery` also runs the C-client groups
without repeating the frames/lease groups. Its C-driver checks require a successful durable restore
to exit zero; a staging obstruction produces nonzero exit even when native
geometry has already been restored, until autonomous persistence retry completes.
The harness cleans up its children on all exits, independently reads transforms
and screen rectangles through its own WindowServer connection, and checks the
journal on disk.

Relevant scenarios cover multiwindow frames and alpha, malformed identities,
newest-frame bursts, disconnect and lease restoration, client/helper loss, the
C client, per-window release, process-scope audit, read-only inspection before
first touch and after restoration, strict startup refusals with byte preservation,
and a filesystem obstruction that leaves an empty table with a pending journal.
`DWPayloadRestoreIdentityTests.m` (also the arrival veil cases) compiles the actual apply/restore code with native
call substitutes to check unavailable enumeration, owner/process lookup, changed
identity/scope, and retention of the original in the table and durable journal.
It also replaces the simulated owner after journal fsync and between setters,
checking that no later property write or successful frame acknowledgement reaches
that replacement. This regression creates no window and is not native API evidence.

The current tests do not inject into Dock, change policy or settings, enroll
another user's applications, or prove third-party visual/input usability. Native
restore API failure and startup restoration of a still-live foreign window remain
separate evidence requirements.

The headless tests, which need no window and no Dock, are `DWPayloadRestoreIdentityTests.m`, `DWPayloadForwardOperationsTests.m`
(alpha de-duplication, drift correction, failed readback, identity loss during an alpha readback, veil ordering and exact restoration),
`DWLoaddRequestTests.m` and `DWHelperClientTests.py`.
