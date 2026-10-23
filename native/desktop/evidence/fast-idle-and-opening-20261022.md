# Settled Fill, opening and transition handoff, 2026-10-22

The v36 production bundle ran in the owner-authorized macOS 27.0.1 (26A434)
UTM guest with the same six real Calculator, Safari, TextEdit and Finder windows.
Executable SHA-256:
`cd49801ee22c0ac29fda9714ec8cc2211f510925d38a947544e00f486be4b98b`.
The existing Dock helper stayed loaded; no helper update or Dock restart occurred.

Three changes ran together:

- A fully settled Fill now permits unchanged controller observations and clock
  ticks to reuse their previous presentation. Pending resize/restore, changed
  output geometry, gestures, motion and lifecycle work still take the normal path.
- Native discovery starts its read-only AX role/title lookup during the existing
  50 ms geometry stability hold. Positive metadata is usable only for the same
  identity, native basis, appearance and title version, for at most 100 ms. The
  fresh native sample still gates admission; failed early reads do not spend a
  normal retry or invent a title.
- The transition panel is ordered, drawn and flushed before the helper may hide
  the real window. WindowServer metadata checks its owner, visibility, alpha and
  rounded bounds. That metadata is not a rendered-pixel acknowledgement.

Twelve-second quiet process-time samples, without video recording, measured:

| State | v35 app CPU | v36 app CPU | v35 WindowServer | v36 WindowServer |
| --- | ---: | ---: | ---: | ---: |
| Normal idle | 5.42% | 4.85% | 3.37% | 7.47% |
| Settled Fill | 7.88% | 5.41% | 7.14% | 7.54% |

CPU percentages are fractions of one guest core. The Fill app reduction is
2.47 percentage points, or 31.36%, in this single matched pair. Settled Fill
description flushes fell from 11.5–12 to 0.5–1 per second; redraw requests stayed
around 12 per second and no canvas frames were presented while idle. The reduced
flush work matches the targeted change. Co-shipped changes and one sample pair
prevent isolating all of the CPU difference. Normal WindowServer load differed
substantially, so the normal samples are not a convincing system-wide comparison.

RSS rose from about 100 to 133.4 MiB after the snapshot roundtrip. A later v36
`vmmap -summary` reported 34.0 MiB resident in `Malloc Large (empty)`, 5.88 MiB of
live malloc allocations, 119.1 MiB of IOSurfaces and 34.9 MiB of graphics memory.
This identifies freed allocator storage, not a demonstrated live-object leak.
Memory has not improved; surface ownership and a safe trimming policy remain
unresolved. Physical footprint was 206.7 MiB, with a 362.7 MiB peak.

Real TextEdit Fill/restore pairs measured:

| Starting zoom | Fill receipt | Restore receipt | Animation completion entry |
| --- | ---: | ---: | --- |
| 1.0 | 0.761 s | 0.578 s | 94 / 94 ms |
| 0.75 | 0.786 s | 0.593 s | 89 / 86 ms |

Receipts are host CLI-to-resumed-handoff times over SSH, not first-visible-frame
latency. Capture consumed 121–171 ms; hide-to-animation preparation consumed
107–292 ms. Completion entry is now logged before frame/basis readbacks, allowing
future stalls to be separated from readback time. The previous intermittent
roughly 500 ms stall did not occur in these four transitions and remains open.

Inspection of every original decoded frame around the 0.75 restore found no
exposed-desktop flash: the target stayed visible, shrank from movie time
6.800–6.883 s, and remained stable through 7.317 s. This validates that recorded
roundtrip, not every transition. Background windows and the pinned Calculator
remained visible during preparation.

Three newly opened empty TextEdit documents reached IPC observation in
329, 663 and 364 ms. Each was closed after observation. Those times include CLI,
application and polling delay; they neither isolate the 50 ms overlap change nor
prove immediate visible positioning. The first-visible native-position jump and
zero-delay opening are still acceptance gaps. Native minimize is also unfinished.

Twelve overview/return toggles were recorded on each build with the same pacing.
Recorded motion cadence is not native presentation FPS: the screen recorder itself
drops or coalesces frames. No maximum-FPS or stutter-free claim follows from these
recordings or the canvas frame counters.

Every original world position, size, mode, pin, focus, camera and zoom was restored
after the live scenarios. Calculator's native geometry, transform and level were
read independently around opening; motion also preserved its native geometry and
transform. Infinify remained running. Physical mouse testing is still unavailable
through the UTM tool because it returns `noWindowsAvailable`.

The integrated arm64 build was warning-clean. Focused checks passed: seven
navigation and nineteen observation tests, two fullscreen C-ABI scenarios,
targeted desktop check/clippy, native discovery/session/close regressions, and the
existing transition mailbox/input checks. These validate changed logic, not native
UX by themselves. No full suite ran.

Raw videos, scene receipts, deployment checks and logs are ignored under
`target/native-vm/ux-flow-20261022/v36-*` and `infinify-v36-*.mov`; process-time,
memory and optical reports are under
`target/performance/native-real-apps-20261022/`.
