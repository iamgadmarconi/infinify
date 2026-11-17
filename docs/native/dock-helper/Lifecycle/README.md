# Helper lifecycle

The helper-lifecycle module owns runtime spelling, nonce creation/admission, launch and pause records, reuse/recover/load policy, retired-journal admission and endpoint parsing. It is linked into the app, loader and launch daemon; injection stays in the loader and the payload is unchanged.

`DWHelperLifecycle` accepts a filesystem-and-process adapter. `DWHelperMacEnvironment` preserves the original POSIX paths, libproc failure/errno semantics and boot UUID query. A later temporary-directory/fake-Dock adapter crosses this same seam; no test adapter or tests are added during the architecture refactor. Logical runtime names remain `/var/tmp/if-native.XXXXXX` or legacy `/tmp/if-native.XXXXXX`, independent of an adapter's physical path.

Admission returns `NO` on uncertainty and does not modify the old runtime. Journal bytes are returned unchanged only after private directory/file, no staging journal, exact schema-4 header, writer, user, boot and positive process-retirement checks pass. The loader still writes the recovery copy only after its original preflight, Dock, payload, runtime and nonce gates, and keeps its original readiness audit.

State-directory derivations stay distinct: the launcher adapter uses `$HOME/Library/Application Support/Infinify/native-desktop`, including an empty `HOME`; an unset `HOME` still fails at the unchanged shell `set -u` expansion before compiled code runs. App CLI/status/login records, setup's native pause reader and `main.m`'s reloader still use `DWDockReloadStateDirectory()` → `DWSupportDirectory()` → `NSHomeDirectory()`. `DWSystemTakeover` and setup/uninstall support state also keep `DWSupportDirectory()`. An overridden `HOME` can therefore disagree with app-side home resolution; that pre-existing distinction is not unified here.

The existing `DWDockReload*` file/endpoint entry points now have one implementation here. The app keeps crash counting, timings and observation. The daemon's stricter canonical-decimal request grammar and signed-caller admission remain in `DWLoaddRequest.m`; sharing runtime spelling does not relax those gates.

The launcher caller uses `DWHelperLauncherMain` through the app's `native-desktop launcher MODE` dispatch; existing external command forms still enter `launch.sh`. The wrapper passes only mode and inherited reload descriptor 3. The compiled implementation derives bundle/artifact paths from its own executable and recomputes the payload digest. `DWHelperLauncher -runMode:` accepts a `DWHelperLauncherEnvironment` adapter for filesystem mapping, state location, process/code identity, clock/randomness, subprocesses and final handoffs; a later temporary-directory/fake-Dock adapter can exercise decisions without the real helper.

A direct, undocumented `native-desktop launcher MODE` call can bypass the wrapper: the compiled launcher re-derives the executable's bundle and artifact paths, checks bundle components and regular files, manifest schema/source metadata and Info identity, and hashes the payload against its manifest entry, but does not repeat the other four manifest artifact path/digest/executable comparisons or the five pre-execution signature verifications; the loader and daemon still independently enforce privileged admission.

The wrapper preflight's executable text and order stay identical apart from its header comment and removal of the unused `native_valid_boot_uuid` and `native_loaded_payload` function definitions; after it, only the `launch-setup` mode mapping and compiled `exec` handoff are new.

## Integrity preflight (unchanged executable text and order)

Each check below **stays in launch.sh**, before app code executes; line numbers refer to this checkout's bundled wrapper source. The unused boot-UUID and loaded-payload function definitions moved out of shell.

| Check | Location |
| --- | --- |
| Mode/help/usage parsing | stays in launch.sh:12–34 |
| Refusal policy and setup handoff; reload descriptor | stays in launch.sh:36–57 |
| HOME state path and login log setup/rotation | stays in launch.sh:58–67 |
| Resolved bundle location/name, NativeDesktop location, path-component symlinks | stays in launch.sh:68–75 |
| Regular/non-symlink launcher, manifest, doctor, loader | stays in launch.sh:93–96 |
| Regular/non-symlink daemon, payload, app executable, Info.plist | stays in launch.sh:97–100 |
| Manifest lint/schema/source fingerprint/source commit; Info identity/executable | stays in launch.sh:101–107 |
| Artifact path, digest spelling, regular file, executable bit, digest equality | stays in launch.sh:109–120, applied at 122–126 |
| Manifest payload digest extraction | stays in launch.sh:127 |
| Doctor strict signature | stays in launch.sh:128 |
| Loader strict signature | stays in launch.sh:129 |
| Daemon strict signature | stays in launch.sh:130 |
| Payload strict signature | stays in launch.sh:131 |
| Bundle deep/strict signature | stays in launch.sh:132 |

## Guard relocation

| Original location | Lifecycle location or unchanged gate |
| --- | --- |
| Shell doctor policy, one-instance/parent gate, stable Dock pin, private state/lock, pause/pending record | `DWHelperLauncher -runMode:` (original order); signal cleanup releases only its own empty lock |
| Shell exact schema-3 ready record, boot/PID/birth/hash/runtime/nonce-path checks | `-runMode:`; prior-boot archive happens before runtime admission as before |
| Shell loaded payload/root stage hash/signature, signer/CDHash reuse and single recorded-Dock restart | `-loadedPayloadForRuntime:directory:sha256:`, `-parsePayloadIdentityAtPath:signer:cdhash:`, `-restartRecordedDockForReason:exitOut:` |
| Shell prior Dock proof; schema-4 journal and historical source/sidecar gates; archive and no-journal/old-schema handling | `-priorDockState`, `-validateRetiredJournalWithExit:`, `-archiveRetiredRecordWithExit:`, `-refuseUnrecoverableJournalWithExit:` |
| Shell fresh private runtime/nonce, pending before load, expected-Dock/retired-Dock arguments, ready promotion | `-runMode:`, `-writeLaunchRecordTo:outcome:exitOut:`; loader/daemon remain the actual load adapters |
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

Native mutation failures previously emitted utility stderr via `set -e`; they now emit one native diagnostic in the `Infinify native desktop:` form and return nonzero, including in login mode. Explicit policy refusals keep their original text and login/setup behavior. A failed manual pause removal still only warns and continues, matching the old `rm -f ... && printf ...` AND-list. File-utility subprocesses (`openssl`, `cp`, `chmod`, `plutil -insert`, `mktemp`, `mv`) are replaced with native operations; signed-code checks, doctor/loader/daemon commands and Dock restart remain subprocesses. Launch records remain XML schema 3 with the same nine typed keys; nonce remains 64 lowercase hexadecimal bytes plus newline. Partial records never acquire the final name; temporary-file cleanup after failure may now remove a file the old script left.

Compile-only verification is not evidence of a usable helper. No load, reload, recovery, setup or daemon path has been exercised for this refactor; the guest has no Developer ID identity, so its installed launch-daemon path cannot be exercised there.

## Deferred test migration

The setup assistant standalone compile list needs the lifecycle sources.
