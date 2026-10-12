# Transform helper: protocol v2

This experimental native adapter targets Apple Silicon macOS 26 or later. Its
sole listener is binary protocol v2 on `RUNTIME/v2.sock`. Loading a payload starts
no transformation; a controller must name an exact in-scope process instance and
window in a `FRAME` request. There is no v1 listener, JSON request client, protocol
fallback, or second restoration state machine.

Default commands remain read-only. Build commands compile and sign artifacts but
do not load Dock or launch fixtures. Native mutation tests use only explicitly
spawned disposable fixture windows and restore their original transforms before
cleanup. These tests do not establish Dock-hosted authority or usable third-party
native-window compositing.

## Build and entrypoints

`./scripts/build-privileged.sh` builds the following in `target/privileged`:

- `doctor`: a read-only SIP and arm64e boot-policy report.
- `payload-arm64e.dylib`: the explicit Dock-targeted payload.
- `payload-arm64.dylib` and `host`: an ordinary cooperative fixture process.
- `dwclient.o` and `dwclient-arm64e.o`: the plain C/pthread v2 client library.
- `v2client`: a fixture driver for `bench`, `hold`, `enrollment`, and `inspect`.
- `loader-arm64e`: an opt-in Mach loader with authenticated v2 readiness checks.

`--doctor-only` builds only the doctor. `--production` omits the fixture payload,
host and driver. Production builds ad-hoc sign the doctor, arm64e payload and
loader; merely building never executes any of them. `scripts/build-app.sh`
packages those files and the standalone launcher into
`Infinify.app/Contents/Resources/NativeDesktop`, then signs and verifies the
complete app. Its plist manifest binds the final helper and launcher bytes;
`scripts/install-app.sh` checks the executable and helper hashes and deep app
signature after copying the already-signed build; it does not re-sign the copy.
The prior v1 JSON client and Dock spike
scripts, including their separate spike fixture, are retired. Supported
workflows are the owner-run [native desktop launcher](../../scripts/start-native-desktop.sh)
and the v2 disposable-fixture scenarios below; the retired spike's historical
receipts are not validation of this protocol or production compositing.

The cooperative host accepts:

```text
host ABS_PAYLOAD PRIVATE_RUNTIME NONCE64HEX [ALLOWLIST_JSON_FILE]
     [--windows N] [--v2-queue own|main] [--level 0..4] [--alpha 0..1]
     [--family popup|sheet|both|none]
```

The runtime must already be a current-user-owned directory with mode 0700. Keep
its path short: `RUNTIME/v2.sock` must fit macOS's Unix socket path limit. The host
creates 1..16 windows, with a 90-second watchdog. Optional family children count
toward that limit and are all listed explicitly. Capability bit 3 identifies this
finite native-family fixture mode; it expands no process or window authority.
Level and alpha options apply only to the newly created fixture windows.
`READY` is printed only after the sole v2 listener binds and its journal passes
startup validation. Failed startup prints no readiness receipt.

The current C driver can inspect an exact identity without holding it:

```text
v2client inspect RUNTIME NONCE64HEX PID WID BIRTH_SEC BIRTH_USEC
v2client enrollment RUNTIME NONCE64HEX
```

The desktop links the C library; the supported Rust runtime uses typed binary v2
requests. Both must authenticate the helper and audit scope before any frame.
Read-only probe/inspection never enrolls ordinary applications automatically.

## Explicit production launcher

The installed owner entrypoint is
`~/Applications/Infinify.app/Contents/MacOS/Infinify native-desktop`, run from a
terminal. Its `native-desktop --check` form validates the bundled manifest,
artifact hashes and deep app signature, then runs the doctor without sudo,
runtime creation, loading or app launch. The bundled launcher uses only macOS
system tools and files inside its own app, so it does not need Python, Homebrew,
or the checkout. It never changes SIP, permissions or settings, restarts Dock,
or retries an uncertain injection automatically.

The repository wrapper `./scripts/start-native-desktop.sh` is checkout-aware.
It verifies the selected bundle against current source and the standard app's
`target/app/BUILD.json` schema 2 record before calling its bundled launcher.
That record binds the post-sign app executable, native manifest, payload and
complete tracked/nonignored source snapshot. Pass `--app /absolute/path/Infinify.app`
to check an installed bundle; `--build` explicitly rebuilds production artifacts
and the app first. A stale bundle requires a rebuild. This checks delivery
freshness, not native usability.

The bundled launcher obtains Dock's exact PID, process birth, UID and boot
identity from the loader's read-only `--dock-identity` query. It pins the current
Dock during the explicit loader step and binds the `pending`/`ready` launch
record (schema 2) to the bundled payload SHA-256. Reuse also hashes the actual
private runtime payload and requires it to match both the bundle and record. A
ready record for the exact same Dock instance can be reused after the runtime
payload checks pass.

For a retired Dock, the launcher accepts only a committed schema-3 journal
written by the recorded Dock process, same login UID and same boot. The loader
rechecks the journal's private file and directory, exact writer identity,
positive old-process retirement and schema-3 header, then copies its bytes to
the new private runtime as `recovery-source.json`. The sidecar binds the copy by
SHA-256 and recorded writer identity; the payload validates its complete schema
and identities before any restore setter. On first import, the fresh runtime has
no committed journal yet, so this exact source supplies the initial recovery
state. The payload commits that state under the new writer before any restore
setter. On later starts, the new runtime's committed `v2-journal.json` is the
replay authority; a malformed committed journal never falls back to the older
source. When that runtime is retired, its own current journal is the only handoff
input. Any retained `recovery-source.json` is hash-checked historical provenance,
never merged or used as a fallback.

The launcher keeps the previous ready record until the recovery loader reports
authenticated readiness. A private `launch.pending.plist` marker blocks any
retry after an interrupted or uncertain recovery. On success, the old record is
archived byte-for-byte and the new ready record is promoted. The old runtime and
journal remain untouched. Schema-2 and unknown journals are refused because
they lack the retained originals needed for safe connection handoff; the
launcher never reconstructs transforms from native bounds. Unresolved recovery,
a live or uncertain prior Dock, invalid payloads, or changed boot identity also
block startup and preserve all state. There is no compatibility fallback or
automatic injection retry. The launcher runs only the loader through sudo and
starts the app as the login user. The regular LaunchAgent remains the
capture-mode startup and does not invoke this explicit helper path.

An earlier UTM run established that a new helper could start after an empty
schema-2 journal, but it did not cover a window whose transform had been touched
by the retiring Dock. A later read-only receipt showed Calculator WID 183 at
transform `[-510,-554]` with `windows: []` before Dock exit, then at identity
transform before the replacement helper was injected. The old empty journal had
already discarded the original transform. Schema-3 retained-original recovery
is the source fix for that case; its production guest path remains unvalidated.
Receipts are under `target/native-vm/pending-restore-inspect/`.

Direct loader invocation also requires explicit prepared-machine authorization:

```text
loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME
  --nonce-file ABS_NONCE_FILE --only-pid PID
  [--expected-dock PID BIRTH_SEC BIRTH_USEC]

loader-arm64e --inject-dock ABS_PAYLOAD ABS_PRIVATE_RUNTIME
  --nonce-file ABS_NONCE_FILE --desktop --expected-dock PID BIRTH_SEC BIRTH_USEC
  --recover-journal ABS_OLD_RUNTIME/v2-journal.json
  --expected-retired-dock OLD_PID OLD_BIRTH_SEC OLD_BIRTH_USEC
```

`--desktop` selects same-login-user scope instead of a finite `--only-pid` scope.
The nonce is a cryptographically random 32-byte value encoded as 64 lowercase
hexadecimal characters, in a login-user-owned regular file with mode 0600; one
trailing newline is accepted. Nonce bytes are never accepted in the loader's
argv. A private, adjacent `ABS_PAYLOAD.json` sidecar opts in the constructor with
runtime, nonce and optional exact-process allowlist. No sidecar means no listener.
The recovery form accepts only a committed same-boot schema-3 journal from the
positively retired Dock recorded by the launcher. It copies those exact bytes to
the fresh runtime and binds their digest and writer identity in the sidecar. The
payload validates the complete journal, then commits the new writer's journal
before any restore setter. Later recovery uses that committed journal; if it is
malformed, the retained import source is not a fallback. The launcher adds a
private pending marker before sudo and promotes its ready record only after
authenticated readiness; an interrupted or uncertain handoff blocks retry.
Schema-2 journals are refused because their original-window ledger was not
retained.
After loading, readiness authenticates v2, verifies scope/process identity,
required restoration/scope/inspection capabilities, `held=restoring=table_count=0`
and `journal_pending=0`, then disconnects without submitting a frame. A missing
or failed v2 listener is startup failure, with no alternate server.

## Protocol v2

[`protocol2.h`](protocol2.h) is the sole wire schema. All integers and floating
values are little-endian, matching the fixed arm64 layouts. A 16-byte header is
`{u32 length, u16 type, u16 flags=0, u64 seq}`, followed by `length` body bytes
(maximum 131072). Replies carry `type|0x8000` and the request's sequence. Bad
headers, unknown types, wrong lengths, or non-increasing frame sequences close
the control connection and schedule restoration. The socket is mode 0600 inside
the retained private runtime directory; both ends check peer UID. The client also
matches the reported helper PID with the kernel socket peer PID.

| Type | Request | Reply |
|---|---|---|
| 1 `HELLO` | `DWv2`, u16 version 2, u16 role, 64-byte nonce, 16-byte token | status, lease 2000 ms, record/body limits, capabilities, scope, queue, server PID, session token |
| 2 `FRAME` | u32 count, u32 zero, count × 80-byte record | disposition, count, superseded, zero, u64 applied-frame count, count status bytes |
| 3 `HEARTBEAT` | empty | status, lease, held, restoring |
| 4 `RESTORE_ALL` | empty | count, pending, journal_persisted, zero, count × 32-byte restore result |
| 5 `PROBE` | empty | 72-byte summary, table entries, then explicit cooperative fixture identities |
| 6 `ENROLLMENT` | empty | scope, count, server PID, zero, count × 24-byte process instance |
| 7 `INSPECT` | one 24-byte window identity | one 144-byte inspection result |

Capabilities are alpha=1, per-window restoration=2, enrollment audit=4, explicit
fixture family=8, and inspection=16. Scopes are cooperative=1, allowlist=2, and
same user=3. Queue is own=0 or main=1. Current clients require the relevant current
capabilities and refuse unsupported helpers; there is no old-capability bypass.

A window identity is `{i32 pid, u32 wid, u64 birth_sec, u64 birth_usec}`. The helper
resolves its current WindowServer owner connection and process birth itself,
checks the user and scope, and never trusts a numeric window ID alone. Cooperative
scope admits only the host's explicitly created windows. An allowlist pins exact
PID/birth pairs; same-user scope requires the helper's login UID. `ENROLLMENT`
returns the cooperative host instance or finite allowlist; same-user scope has no
finite process list. It does not hold any window.

`INSPECT` reads transform, native bounds and screen rectangle for an unheld or
held window. Its fixed reply is identity (24 bytes), u32 status, i32 owner,
f64 transform[6], bounds[4] and screen_rect[4]. Scope is checked before lookup;
identity, owner and UID are resolved before all native getters and revalidated
afterward. The requested identity is echoed. Success is status 0; refusal is scope
1, identity 2 or snapshot 5 with owner and all geometry zero. Inspection is
serialized on the native queue and neither mutates nor journals. It provides
original geometry before the first frame and authoritative readback after table
removal. It is not visual validation.

`PROBE`'s 72-byte summary is scope/caps/queue/lease, i32 server PID,
held/restoring/journal_pending, four u64 counters (received/applied/superseded
frames and journal writes), and table_count/fixture_count. `journal_pending` is
0 or 1 and means the in-memory table or restoration receipt is not yet durable.
An empty table with this flag set is not an empty recovery obligation. Each table
entry is a 112-byte identity/state/alpha/current-transform/current-screen-rect
record. Only cooperative scope appends up to 16 fixture identities. Probe table
readbacks can be unavailable; use `INSPECT` for a validated geometry result.

A frame record contains identity, f64 affine transform `[a,b,c,d,tx,ty]`, f32
alpha and u32 flags. The affine maps global top-left screen points to window-local
points. Matrix values must be finite and within ±1,000,000, with determinant
magnitude at least 1e-8. Alpha must be finite in 0..1 when flag 1 requests it.
Flag 2 alone requests restoration of that identity's journaled original; its
matrix/alpha are ignored. Combining flags is malformed. Restoration wins over a
transform of the same window in the same frame.

Record statuses are applied=0, scope=1, identity=2, matrix=3, alpha=4,
snapshot=5, journal=6, not applied=7, restore pending=8, table full=9, malformed=10.
An applied transform requires both native set success and readback equality after
float rounding, matching WindowServer transform storage. A failed or differing
set remains journaled because it may have changed the window. A status or symbol
alone is not evidence of usable native presentation.
The helper revalidates exact process birth, owner connection, UID and scope
after journal persistence and immediately before each transform or alpha write,
then again before acknowledging the frame. Earlier batch admission cannot
authorize a window number replaced during disk I/O or another record's work.
Restoration also rechecks identity between its transform and alpha writes.

One control `HELLO` creates the session and a random token. A second heartbeat
connection uses that token; requests on either renew the 2000 ms lease. The C
client heartbeats every quarter lease; Rust runtime heartbeats every 400 ms.
Control disconnect, malformed control request or lease expiry restores all held
windows. Closing only a heartbeat connection does not end the session. An alive
C heartbeat thread can retain windows while its caller stalls. A fully stopped
client expires; a fully stopped helper cannot restore until it runs again.

Frames use one newest-frame slot, limited to 1024 records. Waiting frames are
superseded instead of building a queue; the next frame reply counts them. One bad
record does not prevent the others. `RESTORE_ALL` discards a waiting frame;
a later frame is processed afterward. Probe, inspect, restore, native calls,
table changes and journal writes run serially on the helper's own queue by
default. `DW_V2_MAIN_QUEUE=1` at build time, a sidecar `v2_queue` of `own`/`main`,
or the fixture's `--v2-queue` can select the main queue. Socket parsing, heartbeats
and lease checks run on connection threads. Acceptance of own-queue native calls
inside Dock still requires scoped real-host evidence.

## Journal and strict recovery

Schema-3 `v2-journal.json` preserves the current Dock writer identity and each
first-touch identity, owner, original transform, alpha, alpha-restoration
obligation and native bounds. Its `released_windows` table retains exact original
records after a successful restore, because a later Dock replacement may reset
WindowServer transforms again. When retiring a runtime, its current journal is
the handoff input. A fresh recovery runtime initially imports the exact staged
`recovery-source.json`; the payload commits a journal under its new writer before
any native setter. From then on that committed journal is the replay authority,
and a malformed one never falls back to the import source. The source and its
sidecar digest remain provenance only after import. Originals are captured before
any change. The entire new-window batch is journaled before applying any of it;
unchanged held windows require no journal write. A first alpha change is journaled
before setting it. Persistence uses exclusive no-follow mode-0600
`v2-journal.next`, file fsync, rename and directory fsync. Failed persistence
blocks unjournaled mutation and leaves `journal_pending=1` until a durable retry.

Restoration re-resolves the exact identity, owner, UID and scope, sets the captured
original transform/alpha, and requires exact float readback. Confirmed restored
or gone windows leave the table; uncertain windows remain restoring. Failed owner,
window enumeration or process-birth queries cannot establish absence. A still-live
matching original outside the new helper's scope is retained as pending too.
Retries run
after 250 ms, 500 ms, 1 second and then every 2 seconds without an abandonment
deadline. If native restoration completes but its journal update fails, the table
can be empty while `journal_pending=1`. Controllers must require both native
emptiness and a durable receipt before admitting new presentation. Removing the
persistence obstruction permits autonomous retry without another request.

On restart, the helper validates the entire committed journal before deleting any
interrupted staging file or replaying it: exact schema/version and keys, integral
bounded identities/counters, no duplicate windows, valid transform/bounds/alpha,
consistent states, and valid restoration receipts. It refuses unknown or malformed
journals and preserves their bytes. A replay restores only still-matching windows
within the new helper's scope; changed or gone identities are left alone. An
alpha obligation is refused if the required native symbols are unavailable.
Only a private regular staging file may be removed after successful validation,
or when no committed journal could have authorized a mutation.

Legacy `recovery.json`, `recovery.next`, or `helper.sock` artifacts are never
replayed, cleared or converted automatically. Any presence refuses startup and
preserves the files, including a purportedly clean legacy receipt. Existing
`v2.sock` also refuses startup. Bind/listen and journal validation must succeed
before readiness. A process crash, machine failure or stalled helper cannot run
in-process restoration; preserved journals require exact-identity reconciliation,
not blind reinjection or deletion.

## Focused fixture validation

`./tests/e2e/privileged-fixture.sh` builds only by default. Passing
`--live-owned-fixture` explicitly runs `fixture_v2_test.py` against spawned,
finite-window cooperative hosts. Individual scenarios can be selected directly
with `--inspect`, `--startup`, `--release-window`, or `--enrollment` after building.
`--client-restore` checks only C restore exit status; `--recovery` selects recovery
and read-only audit groups. `--client-and-recovery` also runs the C benchmark
groups without repeating the frames/lease groups. Its C-driver checks require a successful durable restore
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
`restore_identity_test.m` compiles the actual apply/restore code with native
call substitutes to check unavailable enumeration, owner/process lookup, changed
identity/scope, and retention of the original in the table and durable journal.
It also replaces the simulated owner after journal fsync and between setters,
checking that no later property write or successful frame acknowledgement reaches
that replacement. This regression creates no window and is not native API evidence.
The `4063db2` helper also passed the existing `--release-window` scenario on
2026-10-12: eight owned windows, transform/alpha writes, per-window release,
rebind and exact restoration, with the host and client closed afterward.
Local hashes and scope are in `target/helper-identity-readiness.json`; the log
is `target/helper-identity-live-release.log`. This does not establish foreign-app
or optical presentation behavior.
The current tests do not inject into Dock, change policy or settings, enroll
another user's applications, or prove third-party visual/input usability. Native
restore API failure and startup restoration of a still-live foreign window remain
separate evidence requirements. Historical files under `evidence/` record their
original runs; they are not receipts for later protocol revisions.

## Attribution and provenance

Original helper/protocol code is GPL-3.0-or-later. Private ABI declarations were
cross-checked against yabai commit
[`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd):
`src/osax/payload.m` and `src/misc/extern.h` (alpha declarations at lines 16, 17
and 79). The loader is adapted from that exact revision's `src/osax/loader.m`,
with the MIT notice retained in [`YABAI-LICENSE.txt`](YABAI-LICENSE.txt). Ad-hoc
signing follows `src/sa.m`'s `scripting_addition_prepare_binaries` at the same
revision (`codesign -f -s -`). The source notices and exact pinned upstream
provenance remain attached to the implementation.
