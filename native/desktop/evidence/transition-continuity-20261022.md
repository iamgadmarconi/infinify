# Transition continuity and discovery, 2026-10-22

The v35 production bundle ran against the existing six real app windows in the
owner-authorized macOS 27.0.1 (26A434) UTM guest. No helper update or Dock restart
was needed. Executable SHA-256:
`4d9fa74b7f2da02ae01861db51abbd2bef41dddc78e7125786183d5d10330797`.

Fill now retains unchanged background native windows at their previous physical
screen placements while preparing and expanding the snapshot. This also covers
fractional cameras and zoom 0.75: a pin uses its exact output/screen descriptor,
so the logical camera reset does not prematurely remove Calculator. The recorded
screen confirms Calculator and ordinary windows stay visible during preparation.
The extra placements are presenter-only; presses and phased scroll tails remain
blocked through the handoff, including attached native children.

A rapid Fill/restore pair at zoom 1.0, followed by a pair at 0.75, measured:

| Zoom | Fill | Restore | Reported panel duration |
| --- | ---: | ---: | --- |
| 1.0 | 0.844 s | 0.882 s | 93 / 94 ms |
| 0.75 | 0.750 s | 0.642 s | 95 / 91 ms |

Total times are host monotonic CLI-to-handoff receipts over SSH, not optical
latency. The first pair ran with simultaneous Infinify and WindowServer sampling.
Capture alone took 154–310 ms. Panel-duration diagnostics include completion
readbacks and are not a display-frame clock. The earlier v34 run showed a 559 ms
panel/completion interval and a further roughly 504 ms reveal wait. That outlier
remains unexplained: the matched v35 rapid pair preserved the approximately
150 ms enter-to-restore gap but did not reproduce the stall. Neither the clean
sample nor the 60 Hz video container establishes stutter-free presentation.

Window discovery now confines an unavailable-title retry to that exact native
window appearance and basis. Previously, one such candidate delayed unrelated
windows globally for two seconds. Fresh title evidence and matching window-change
notifications retire the ticket; stale AX replies cannot re-arm it.

A new real TextEdit document was observed by IPC 338 ms after the CLI open call
(v32's one earlier sample was 450 ms). This is a normal-path check, not an isolated
performance comparison of the retry fix. Video still shows the initial native
window location before managed placement and camera movement; effectively
immediate opening remains unfinished. Only the new document was closed.

After both live scenarios, every original logical position, size, mode, pin,
focus, camera and zoom was restored. Calculator's native geometry was independently
read before and after opening. Before the same-bundle profiling restart, helper
journal cleanup and all six original native transforms/sublevels were checked.
Infinify was left running. Physical mouse validation remains unavailable because
the UTM control tool returns `noWindowsAvailable`.

The warning-clean arm64 production build and focused discovery/input regressions
passed. Those checks protect the changed logic; the real-app observations above
are the runtime evidence. Raw video, logs, scene/cleanup receipts and deployment
records are under ignored `target/native-vm/ux-flow-20261022/v35-*` and
`infinify-v35-*.mov`; paired process samples are under
`target/performance/native-real-apps-20261022/v35-rapid-restore-*`.
