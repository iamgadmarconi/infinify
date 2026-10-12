# Explicit Scene/native runtime boundary

`driftwm-runtime` connects the persistent `driftwm-canvas::Scene` to an already
running helper. The default command and `--help` are read-only. The runtime never
injects a payload, changes permissions or settings, discovers/adopts desktop
windows, or infers authorization from saved Scene native IDs.

```sh
cargo build -p driftwm-runtime --locked
./target/debug/driftwm-runtime --help
./tests/e2e/runtime-canvas.sh
```

The E2E starts its own disposable cooperative NSWindow and exercises the real Rust
Scene, binary protocol v2, helper and SkyLight path. A separate parent process reads
screen bounds independently. Isolated protocol-fault peers also exercise sequence,
inspection and false-ack rejection; those peers do not contribute native evidence.
Evidence is written under `/tmp/runtime-*/evidence.json`; the nonce file is deleted
on exit and is never included in evidence. This proves the scoped fixture path, not
third-party control or complete window management.

## Selected-window API

`Session::enroll(directory, nonce, scene, selected, identity)` requires an explicit
logical window and fresh complete identity `{pid,birth_sec,birth_usec,wid,owner}`.
The helper validates the current process birth time, window owner and UID before
snapshotting. Callers must obtain and select this identity outside persisted
Scene data. Fixture tests obtain it from the scoped host's probe and compare its
PID to the child they spawned. Production callers must implement an authorized
window-selection flow; this crate does not provide one.

`set_desired(scene)` advances the desired revision independently of native state.
Camera pan/zoom should modify a cloned Scene through its existing reducer methods,
then replace desired state. `apply()` acknowledges a `Presented` revision only
after native matrix, screen rectangle and unchanged actual bounds are checked.
A pending desired revision can coexist with an earlier acknowledged presentation.
`presented()` returns `None` after a connection, heartbeat or verification failure.
Persist only `desired()` using `Scene::save_atomic`; native enrollment must be fresh
on each restored session.

A single enrolled window must have exactly one completely visible placement.
Clipping, duplicate instances on independent outputs, hiding an enrolled window,
and visible un-enrolled windows fail explicitly before mutation. Other offscreen
world entries remain in the desired Scene. No window is relocated to simulate
hiding. Original native matrices with rotation, shear or reflection are rejected.

SLS transforms map global **screen coordinates into window buffer coordinates**.
The runtime validates the observed original matrix/screen dimensions against actual
native bounds, and constructs the inverse projection from the desired Scene
rectangle. It does not assume the original matrix is identity (a normal fixture
starts with translation `[-window_x, -window_y]`). Actual native/world bounds remain
unchanged by camera operations.

`close()` returns verified restoration or an error, then closes the connection.
`Drop` attempts the same restoration; failures cannot be returned from Drop.
`disconnect()` closes without claiming restoration, for helper recovery testing.
The helper also restores on controller death and lease expiry. After a helper crash,
the durable v2 journal remains; the next helper startup on that runtime attempts
identity- and scope-checked recovery before accepting a client.
The runtime sends heartbeats every 400 ms even while stdin/UI is idle; each verifies
native readback against the acknowledged state. A failed heartbeat invalidates
presentation and disconnects. A dead helper cannot restore while it is absent.

## CLI session

```text
driftwm-runtime probe PRIVATE_DIRECTORY NONCE_FILE
driftwm-runtime session PRIVATE_DIRECTORY NONCE_FILE IDENTITY_FILE SCENE_FILE LOGICAL_WINDOW_ID
```

The private directory must be owned by the current UID with mode 0700. The native
socket is `PRIVATE_DIRECTORY/v2.sock`, a same-UID mode-0600 socket. The client
authenticates the connected server with Darwin `getpeereid` and `LOCAL_PEERPID`, then
negotiates protocol v2 using the private 64-character nonce. It requires restoration,
scope-audit and read-only native-inspection capabilities. Native messages use the
little-endian v2 header `{u32 body_length, u16 type, u16 flags=0, u64 sequence}`;
replies must match both type and sequence. Each exchange has an absolute one-second
deadline. The nonce never appears in CLI responses.

The `probe` command returns the negotiated v2 scope, server PID and counters, plus
each cooperative fixture's full identity and independent native readback. Probe does
not enroll, mutate or adopt a window. The session's newline-delimited JSON commands
below are the CLI interface; they are not the native socket protocol.

The session accepts newline-terminated commands, each at most 4096 bytes:

```json
{"op":"pan","output":1,"delta":[20,10]}
{"op":"zoom","output":1,"zoom":0.5,"anchor":[400,300]}
{"op":"apply"}
{"op":"readback"}
{"op":"save","path":"/explicit/destination/scene.json"}
{"op":"close"}
```

Pan/zoom only change desired state. Every response identifies desired and presented
revisions or the specific lifecycle/readback event. EOF restores and closes.
Errors return nonzero; a successful FRAME status alone is insufficient: the runtime
issues a fresh INSPECT and rejects an unchanged matrix or mismatched screen rectangle.
`{"op":"disconnect"}` is a recovery-test operation whose response explicitly does
not confirm restoration. Commands do not provide native input, focus or UI tracking.

Verification is deliberately focused: package fmt/clippy and
`tests/e2e/runtime-canvas.sh`. The latter covers real pan/anchored zoom, unchanged
world and actual native bounds, scene save/reload, heartbeat retention beyond the
2-second lease, explicit close, EOF, disconnect and SIGKILL restoration, unsupported
clipping/duplicate/offscreen states, missing helper, malformed reply sequence,
inspection refusal, and a v2 false-ack peer whose unchanged INSPECT readback rejects
the claimed native no-op. A changed pre-frame inspection is rejected before any
FRAME is sent. All 14 cases passed on 2026-10-12 using the owned cooperative host
and separate binary-protocol fault peers; this is not third-party app validation.
