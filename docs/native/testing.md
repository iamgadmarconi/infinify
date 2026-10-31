# Native tests

The regressions and fixture programs under `tests/native`, the end-to-end scripts in `tests/e2e/` that build and run them, and the focused fixture validation of the Dock helper.

Run the regression a change touches, not the whole set. The scripts build what they need (`xcrun clang`, some also `cargo build -p driftwm-desktop --release`) and need an Apple Silicon Mac. The controller scenarios are `crates/desktop/tests/*_flow.rs` (`cargo test -p driftwm-desktop`), driven through the exported C ABI.

**In memory.** No window, event tap, permission request or application launch; they prove the policy or decision they name with substituted native calls, not that a real application accepts it.

| Script | What it covers |
| --- | --- |
| `tests/e2e/background-tiff.sh` | Crafted TIFF files and a fixed-seed mutation run through the real tile source and background program: a picture, or an error and the dot grid, never a crash |
| `tests/e2e/capture-configuration.sh` | The capture request and rate state |
| `tests/e2e/compositor-lifetime.sh` | The production CPU lifetime fence of the compositor's resources |
| `tests/e2e/controller-hit.sh` | The real controller's `{"hit": null}` answer through the shell's hit-reply helper, and pick-mode motion (`DWPickMotion`) |
| `tests/e2e/desktop-navigation.sh`, `tests/e2e/desktop-resize.sh` | The navigation coordinator and the resize coordinator and driver, with the real Rust library |
| `tests/e2e/family-geometry.sh` | Production renderer queries on family geometry |
| `tests/e2e/ipc-limits.sh` | DriftWM v0.21.0's IPC limits and the screenshot write, on the production IPC server and PNG writer |
| `tests/e2e/mac-wallpaper-refresh.sh` | The wallpaper refresh timing policy |
| `tests/e2e/multitouch-source.sh` | Synthetic MultitouchSupport contact records through the adapter into the recogniser, and the Dock-control decision |
| `tests/e2e/native-daemon.sh` | The launch daemon's and the Dock reloader's decisions |
| `tests/e2e/native-display-space-cache.sh`, `tests/e2e/native-placement-validation.sh`, `tests/e2e/native-presenter-readiness.sh`, `tests/e2e/native-view-transfer.sh`, `tests/e2e/native-family-recovery.sh`, `tests/e2e/root-capture-mailbox.sh` | The presenter and its verifiers with substituted reads: display queries, placement validation, ACK readiness, view transfer, family recovery, the capture mailbox |
| `tests/e2e/native-focus.sh`, `tests/e2e/native-frame-restore.sh` | The shipped focus adapter's refusals through its C ABI, and the resize adapter's frame regression |
| `tests/e2e/native-decorations.sh` | The title-region classifier over Accessibility shapes recorded in the guest (Chrome tab strip, Chrome with vertical tabs, TextEdit, Finder) and Aside's tab-sidebar window as dumped on its owner's Mac, AX calls substituted (179 checks) |
| `tests/e2e/native-input-policy.sh` | The adapter's packet policy, including the native-drag takeover |
| `tests/e2e/native-launcher.sh` | The bundled launcher's modes against a signed stand-in bundle built from `tests/native/dock-helper/Loader/NativeLauncherFixture.c` (it skips itself where an Infinify process is running) |
| `tests/e2e/privileged-regression.sh` | The Dock helper payload and its C client |
| `tests/e2e/system-takeover.sh` | The Stage Manager and window-tiling takeover against an in-memory preferences store |
| `tests/e2e/window-discovery.sh`, `tests/e2e/window-events.sh` | Window metadata and scheduling, and the application/KVO lifecycle |

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
