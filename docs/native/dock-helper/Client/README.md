# Helper protocol and client

Protocol v2 between the shell and the Dock helper, and the client library that speaks it (code in `native/dock-helper/Client`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Protocol v2

[`DWHelperProtocol.h`](../../../../native/dock-helper/Client/DWHelperProtocol.h) is the wire schema. All integers and floating
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
| 8 `FRAME_SPACE` | u32 count, u32 zero, count × 88-byte Space record | same frame reply, matching opcode |
| 9 `VEIL` | u32 mode (1 on, 0 off), u32 zero | u32 status (0, or 1 = refused), u32 bound in ms |

Capabilities are alpha=1, per-window restoration=2, enrollment audit=4, explicit
fixture family=8, inspection=16, Space migration=32, pinned sublevel=64 and
arrival veil=128. Scopes are cooperative=1, allowlist=2, and
same user=3. Queue is own=0: the helper runs its native calls on its own queue and always
reports 0 (clients accept 0 or 1). Current clients require the relevant current
capabilities and refuse unsupported helpers. Protocol v2 advertises no native clipping
capability and display-boundary clipping is not implemented.

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
snapshot=5, journal=6, not applied=7, restore pending=8, table full=9, malformed=10,
Space admission=11 (retryable without a setter).
An applied transform requires fresh readback equality after float rounding,
matching WindowServer transform storage, and a current final identity. A called
status-bearing scalar setter must also succeed. Space moves return no usable status
and cannot substitute for readback. A failed or differing set remains journaled because
it may have changed the window. A status or symbol alone is not evidence of
usable native presentation.
The helper revalidates exact process birth, owner connection, UID and scope
after journal persistence and immediately before each transform or alpha write,
then again before acknowledging the frame. Earlier batch admission cannot
authorize a window number replaced during disk I/O or another record's work.
Restoration also rechecks identity between its transform and alpha writes.
Previously verified unchanged transforms and alpha omit their setters only after
fresh native getters still equal the current request. A mismatch gets a new
identity fence before correction. The saved originals remain unchanged.

`FRAME_SPACE` adds `u64 target_space` after each unchanged 80-byte record.
Zero leaves membership untouched; `FRAME` is the same request without Space targets
and keeps the 80-byte record.
`dw_client_submit_space_frame` requires capability 32. Forward migration requires
singleton ordinary source membership and an ordinary target currently active on
a different active, awake physical display. It cannot gather windows from an
inactive Space or another Space on the same display. Already-on-target windows
receive no Space setter or new Space restoration obligation. A window that has no
Space membership at all is refused `SPACE` with no write and no journal change; the
guest showed this for a document being closed (destroyed in WindowServer, still
named by the owner cache) for the few frames before the client released it, and
`DWPayloadRestoreIdentityTests.m` covers that sequence with substituted calls. Duplicate WIDs in
an extended frame, or a nonzero target on a restoration record, are malformed.

Before a Space write, schema-4 entries optionally persist
`original_space: {id, display, pending_target}`; an entry without that key has no Space obligation. The
original singleton and display UUID never change. The void move API is accepted
only after exact membership readback; an unobserved pending target cannot be
superseded. Restoration returns to the original existing ordinary Space even if
inactive, and cannot report `RESTORED` with unconfirmed forward debt or differing
membership. Uncertain obligations survive lease loss and crash recovery. A root
move that carries a child preserves that child's independently journaled original.
Restoration may durably clear a deleted forward target only when a complete,
valid managed-Space inventory covers every active display, the target is absent,
and the exact window is back on its original Space on the saved display. A failed
per-Space getter alone does not establish deletion.

The Space-handoff runs in the macOS 27.0.1 guest (TextEdit at 1x and Finder at .5 scale on a temporary second display) do not establish native
content-extent/detail preservation, general child-family transfer, physical-display or macOS 26 acceptance.
