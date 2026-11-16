# Helper lifecycle

The helper-lifecycle module owns runtime spelling, private nonce admission, retired-journal admission, persisted pauses and endpoint parsing. It is linked into the app, loader and launch daemon; injection stays in the loader and the payload is unchanged.

`DWHelperLifecycle` accepts a filesystem-and-process adapter. `DWHelperMacEnvironment` preserves the original POSIX paths, libproc failure/errno semantics and boot UUID query. A later temporary-directory/fake-Dock adapter crosses this same seam; no test adapter or tests are added during the architecture refactor. Logical runtime names remain `/var/tmp/if-native.XXXXXX` or legacy `/tmp/if-native.XXXXXX`, independent of an adapter's physical path.

Admission returns `NO` on uncertainty and does not modify the old runtime. Journal bytes are returned unchanged only after private directory/file, no staging journal, exact schema-4 header, writer, user, boot and positive process-retirement checks pass. The loader still writes the recovery copy only after its original preflight, Dock, payload, runtime and nonce gates, and keeps its original readiness audit.

The existing `DWDockReload*` file/endpoint entry points now have one implementation here. The app keeps crash counting, timings and observation. The daemon's stricter canonical-decimal request grammar and signed-caller admission remain in `DWLoaddRequest.m`; sharing runtime spelling does not relax those gates.

## Guard relocation

| Original location | Lifecycle location or unchanged gate |
| --- | --- |
| `DWLoader.m:boot_session_uuid` | `DWHelperBootSessionUUID` through the environment |
| `DWLoader.m:private_runtime_suffix`, daemon `runtimeSuffix`, reloader endpoint prefix loop | `DWHelperRuntimeSuffix`; NSString callers also retain exact ASCII length |
| `DWLoader.m:read_nonce_file`, `valid_nonce` | `DWHelperReadNonceFile` (raw filesystem bytes retained) |
| `DWLoader.m:retired_process` | `-retiredProcess:birthSec:birthUsec:`; uncertain lookups still refuse |
| `DWLoader.m:recovery_journal` | `-recoveryJournal:runtime:dock:expectedPID:expectedSec:expectedUsec:sourceBytes:recoveryFields:` |
| `DWDockReloader.m` pause record read/write/remove | `DWDockReloadPaused`, `DWDockReloadPause`, `DWDockReloadResume` |
| `DWDockReloader.m` endpoint parser | `DWDockReloadParseEndpoint` |
| daemon caller signature, hardening, audit token, environment, console-user checks | Unchanged in `Daemon.m` and `DWLoaddRequest.m` |
| daemon request shape, artifact pinning, Dock pin, root staging | Unchanged, except the shared runtime spelling predicate |
| loader SIP/arm64e, current Dock pin, payload/staged ownership, runtime mode, empty-runtime gates, recovery copy persistence, sidecar, authenticated readiness | Unchanged in `DWLoader.m` in the same order |

Compile-only verification is not evidence of a usable helper. No load, reload, recovery, setup or daemon path has been exercised for this refactor; the guest has no Developer ID identity, so its installed launch-daemon path cannot be exercised there.

## Deferred test migration

No test is run or changed in this phase. `tests/e2e/native-daemon.sh` and `tests/e2e/setup-assistant.sh` have standalone compile lists that now need the lifecycle sources. Their existing Objective-C cases can cross the lifecycle interface instead of relying on reloader/request translation units to supply the shared definitions. `tests/e2e/native-launcher.sh` and `NativeLauncherFixture.c` assume the shell owns all decisions; replace that decision harness with a temporary-directory/fake-Dock launcher adapter, retaining separate wrapper integrity checks. Existing legacy `/tmp` creation expectations in that script were already stale before this refactor.
