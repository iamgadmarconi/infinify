# Production event loop and early opening, 2026-10-22

Three parallel work lanes produced the v37–v39 iterations: idle CPU and memory,
transition latency, and new-window admission. Real-app runs used the same six
windows in the owner-authorized macOS 27.0.1 (26A434) UTM guest. The existing Dock
helper stayed loaded, with no helper update or Dock restart.

The production event pump now waits against one 80 ms polling deadline rather
than repeatedly rearming alternating 5 ms waits. AppKit continues to service
dispatch, timers and display callbacks while waiting; actual events are delivered
immediately. Shared probe and shutdown pumps are unchanged.

Matched 12-second process-time samples around this change measured:

| State | v37 app CPU | v38 app CPU | Relative reduction |
| --- | ---: | ---: | ---: |
| Warm normal idle | 5.009% | 1.152% | 77.0% |
| Settled Fill | 5.088% | 2.050% | 59.7% |

Percentages are fractions of one guest core. The normal v38 sample was repeated
after startup; the initial sample was 1.398%. WindowServer load was not matched in
normal mode (8.05% versus 16.70% warm), so no whole-system improvement is claimed.
The Fill WindowServer samples were 6.81% and 7.30%. Description flushes remained
0.5–1 per second, with about 12–13 redraw requests per second and no idle canvas
frames. This is one baseline per state and one warm repeat, not a distribution.
Memory and native presentation FPS have not been shown to improve.

Frame restoration now skips its final size setter only when the post-position
AX and native CG extents both exactly match the saved size. If positioning changes
either extent, the corrective write remains. Existing identity, readback and
deadline checks remain. No isolated saved-millisecond claim is supported.

The v37 run reproduced the intermittent stall: original video frames held the
same intermediate snapshot size from 6.750–7.233 s. Animation completion entry was
555 ms after start; its readbacks took less than 0.1 ms. A further 502 ms elapsed
between reveal submission and resume. Thus this was a visible midpoint freeze,
not merely slow completion readbacks. A sampled repeat and the subsequent v38
recording were clean; neither establishes the cause or a fix.

During a native Fill handoff, v39 releases the canvas cursor override before
pointer/output lookup or synchronous WindowServer hit routing. Input is already
blocked during that handoff. This removes a measured synchronous query from the
animation path; it is not proof that the intermittent freeze is fixed.

After startup, positively identified standard windows can bypass the remaining
50 ms admission hold only when a fresh worker-side post-AX read exactly matches
the initial identity, bounds and canonical native transform. Metadata must still
be current and title-bearing. Global Space changes, appearance/basis changes,
window events and stale replies invalidate the ticket. Other cases retain the
ordinary hold. No native mutation occurs before normal attach/ownership checks.
The path still begins after on-screen discovery, so it cannot guarantee placement
before the first native frame.

The integrated v39 executable SHA-256 is
`ca3a95354bd61e586120fa53a2800fc59024bf73ba1190d7fb63cc2d05767f65`.
Real Fill/restore roundtrips took 0.719/0.603 s at zoom 1 and 0.815/0.646 s at
zoom 0.75, measured from host CLI submission to resumed handoff over SSH.
Animation completion entry ranged from 89–100 ms. Three new empty TextEdit
documents reached IPC observation in 388, 403 and 381 ms. Those are not optical
opening times or evidence of zero delay.

Every original world position, size, mode, pin, focus, camera and zoom was
restored after each scenario. Calculator's native geometry and transform were
checked independently. Restart checks verified an empty helper journal, restored
original transforms/sublevels and unchanged Space membership for all six windows.
Startup focus recentered the camera on some restarts; the saved camera was
explicitly restored before measurement. Infinify was left running.

Warning-clean production builds and focused frame-restore, discovery, mailbox
and input checks passed, with independent cross-review. No full suite ran.
These checks do not substitute for the recorded native behavior. Raw receipts,
videos, original-frame contacts and deployment records are ignored under
`target/native-vm/ux-flow-20261022/v37-*`, `v38-*`, `v39-*` and matching movies;
CPU, memory and sampling reports are in
`target/performance/native-real-apps-20261022/`.

Final v39 checks: a further 12-second quiet sample measured 1.070% app CPU and
164.6 MiB RSS; WindowServer was 14.89%. Original decoded restore frames show
changing geometry from 6.783–6.883 s, then a stable result through 7.400 s. No
desktop flash or v37-style midpoint hold appeared in this recording; one source
frame interval was 50 ms. The physical UTM drag tool still returned
`noWindowsAvailable`, so no new physical-drag acceptance is claimed.

The opening comparison used original decoded frames and actual video timestamps,
with the same event pump in v38 and v39. First-native-visible to first wholly
relocated target was 117/167/150 ms on v38 and 67/100/167 ms on v39. The first two
trials improved by 50/67 ms. The third v39 transition contains an 83 ms recording
gap, leaving an 83–200 ms latency bracket. The small-sample median fell from
150 to 100 ms, but consistent improvement is not established. All six openings
still visibly appeared at the native position and then jumped. Effectively
immediate opening, reliable stutter-free motion and custom minimize remain open.
