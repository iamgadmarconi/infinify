# Exact selected native-window focus gate

Harness prepared for Apple Silicon / macOS 26+. **Live focus and native-input
verification has not been run.** Build success, pure geometry and read-only doctor
results establish no usable native-focus capability. No IME, menus, drag-and-drop,
unowned apps, or rendering/compositing capability is claimed by this gate.

## API

`focus.h` exports a C ABI. Enrollment binds PID + kernel process-birth seconds and
microseconds + CGWindowID. `dw_focus_observe` is read-only. `dw_focus_select` requires
an explicit caller guard, called before activation, each exact AX setter/raise,
and while polling. Guard cancellation, stale identity/bounds, missing or ambiguous
AX identity, AX errors, and a 1.5 second call deadline are distinct outcomes.

Successful selection requires current CG ownership, AX/CG bounds agreement,
system-wide AX focused application and its focused CGWindowID, the selected app's
AX focused CGWindowID, and the native foreground PID. The ordinary fixture's
AppKit key-window telemetry is a separate gate requirement. API return codes,
event target fields, and fixture self-reports alone cannot pass the gate.
The caller must independently establish ownership/authorization; enrollment is
not authorization. Private AX signature provenance is pinned in `focus.m`.

## Safe defaults and test window

```
./tests/e2e/native-focus.sh
```

Builds with warnings as errors, compiles the API from C, checks the pure camera
inverse contract and invalid/no-guard requests, then runs read-only doctor. It
never launches fixture windows, activates applications, injects input, requests
permissions, or changes settings.

Only after a concrete desktop test window has been approved:

```
./tests/e2e/native-focus.sh --live-owned-focus --scenario normal
```

The supervisor refuses startup unless existing AX and listen-event access are
available and HID input has been idle for three seconds. Each fixture has TWO
ordinary titled NSWindows with identical titles, actual NSButton/NSTextField
controls, and distinct CGWindowIDs. Both fixtures are owned direct children of the
Python supervisor. A third child runs the focus controller. Controller enrollment
is acknowledged by signed fixture telemetry before activation is permitted.

The live sequence is A1 -> A2 -> B1, repeated through two camera inverses (0.75x
and 1.5x with different pan/origins). At every step the controller explicitly
selects the bound identity, proves external AX focus, then waits for fresh native
key-window telemetry. Actual private native events exercise the check button,
select-all and text entry. Expected text is compared by SHA-256 only. Every other
window's button/text state must remain unchanged. All new events from both apps
must bear the session tag/controller PID, reach the selected native/key window,
and show the expected local mouse coordinates. Mapping and native focus are
reported separately. Camera points are generated probe inputs, not user clicks
on a rendered compositor; no rendered-canvas input claim is made here.

A listen-only event tap cancels on any non-session input (including motion,
modifiers, tablet and other buttons), tap disablement, pointer movement, signals,
or an unexpected foreground process. Fresh ownership/bounds and external native
focus are rechecked before each post. The fresh AX observation's bounds must
match the original mapping bounds. After the final guard (which may pump the run
loop), CG ownership/birth/bounds are checked again immediately before the scoped
post, with no intervening AX call, callback, or run-loop pumping. A changed frame
rejects the event; the router never silently remaps it. This narrows the race;
macOS supplies no atomic compare-bounds-and-post operation. Private PID/window routing signatures and
fields retain the Cantrip provenance in `probe.m`. There is no global injection
fallback or pointer warp. An unrelated foreground app is never reactivated by
the selection guard. During activation, only the previous foreground or selected
owned app is accepted; transient windows inside that owned app are not treated as
successful focus.

Fixture event records and snapshots are HMAC-SHA256 signed with an ephemeral
session key in a mode-0600 file inside a mode-0700 evidence directory. The
controller verifies signatures before using telemetry. The supervisor removes
the key during cleanup; retained signatures are audit markers, not independently
verifiable evidence after key deletion. The controller PID/tag is not a security
boundary against hostile same-user processes. No raw received human text is
recorded or forwarded to fixture controls. Only expected synthetic text hashes
are retained; event records contain no raw characters.

## Cleanup scenarios (also live, separately opt-in)

Use `--scenario signal`, `--scenario controller-death`, or `--scenario deadline`.
Each stops after the first proved native interaction and exercises controller
SIGINT, SIGKILL, or the controller's 15-second deadline respectively. The
supervisor always terminates/reaps all owned direct children and requires fixture
restoration receipts. A crashed controller cannot strand fixtures: each fixture
checks controller/supervisor process birth and has its own 25-second deadline.
A timer also runs in AppKit tracking mode and posts an **in-process** mouse-up
outside the control to wake a nested button-tracking loop before restoring owned
state. The input filter admits only the exact retained teardown event object,
once, while teardown is active, for the pending-down window and outside-control
location. A copied/forged event or an event carrying the normal session tag does
not gain this exception. Foreign human input still cancels the fixture. This
local teardown event is not input-routing evidence. Button highlight and original
window frames are also reset and checked in restoration receipts.

`--scenario partial-down-controller-death` exercises the vulnerable interval:
it posts exactly one native button-down, requires signed fixture evidence that
AppKit entered its event-tracking mode, and then SIGKILLs the controller before
any native mouse-up. The supervisor requires both fixtures to exit through their
own watchdogs within three seconds, **before** sending any cleanup signal. The
selected fixture must report one accepted internal teardown release, zero foreign
events, restored controls/frame, and a successful exit. This is prepared for the
next authorized test window; it has not been run.

`--scenario bounds-before-readback` and `--scenario bounds-after-guard` are
negative live gates. A signed hook moves only the selected owned fixture by a
known offset, first in the gap before the blocking AX observation, or second after
the final guard. They require rejection at the corresponding bounds check, zero
posted events, and unchanged control/audit state in both apps. These deterministic
interleavings exercise the stale-geometry paths; they do not claim to reproduce
all WindowServer scheduling races. Original fixture frames are restored during
cleanup. These scenarios also remain unrun.

Normal and signal cleanup conditionally restore the original foreground app
only while an owned fixture with unchanged birth is still foreground and the
original process birth still matches. Fixtures provide the same conditional
restore on controller/supervisor death; no unrelated foreground app is displaced.
All buttons, action counters, and text fields are reset before windows close.
Hard-killed/unresponsive fixtures without restoration receipts fail cleanup.
If the Python supervisor itself is SIGKILLed it cannot reap children; fixture
watchdogs exit and OS adoption/reaping applies. That path is instrumented by
fixture exit receipts but is not a supervisor-reaping success claim.

Evidence includes selected identities, external AX focus, fresh native key-window
state, per-camera input maps, control hashes/state, signed native event targets,
interference failures, cleanup receipts, direct-child exit statuses, and exact
source SHA-256 hashes. Live failures remain failures; no fallback widens scope.
