# Faster Fill transitions, 2026-10-22

The production v32 app was compared with v31 in the authorized macOS 27.0.1
(26A434) UTM guest, using the same existing TextEdit document and six-window
scene. Both runs entered and restored same-Space Fill at 1.0 and 0.75 zoom.

| Zoom | Operation | v31 | v32 |
| --- | --- | ---: | ---: |
| 1.0 | Fill | 0.944 s | 0.771 s |
| 1.0 | Restore | 3.027 s | 0.682 s |
| 0.75 | Fill | 1.475 s | 0.765 s |
| 0.75 | Restore | 3.165 s | 0.715 s |

These are host monotonic command-to-handoff-completion timings over SSH, not
optical latency or frame-rate measurements. Native timestamps measured the
visible panel animation at 85–103 ms. One-shot capture still took 147–217 ms,
and hiding/sizing before animation added 164–294 ms. The recorded screen also
shows other windows disappearing before the expansion begins; seamless
transitions and effectively immediate response remain unfinished.

New eligible Fill operations resize the hidden native root directly under a
fresh snapshot, then use one 100 ms ease-out animation. They do not create
AppKit Fill state, avoiding the previous roughly two-second Unfill wait.
Helper acknowledgements advance the active handoff immediately. Existing
identity, capture, hiding and exact-frame restoration gates remain in place.

All original world positions, sizes, modes, pinned Calculator placement,
focus, camera and zoom matched after the real-app round trips. The old app
quit cleanly and restored all six native transforms and Space memberships
before replacement. The v32 executable SHA-256 was
`cbdb6b19e57b2de76fff14e1011e778740fded0ab266f623837ed771217d1abc`.

The same build batches each decoration position/size read into one AX request.
Production title reports accepted TextEdit, Safari and Finder search chrome.
A 12-second idle pair measured app CPU at 6.00% then 3.86% of one guest core,
with RSS 98.25 then 99.44 MiB. A quiet repeat measured 5.66% app CPU and
99.44 MiB RSS, with WindowServer CPU close to the baseline. The initial large
CPU drop was not stable; these samples do not establish a strong overall
system-CPU win or isolate the contribution of batching.

The focused resize regression, 550 presenter checks, warning-clean production
build and independent source review passed. Physical mouse checks after this
deployment were blocked by the UTM control tool's `noWindowsAvailable` error;
this run does not establish title-click or drag behavior. Opening and native
minimization are separate unfinished paths.

Raw timing receipts, native logs, video and deployment checks are under the
ignored `target/native-vm/ux-flow-20261022/v3{1,2}-*` paths; performance samples
are in `target/performance/native-real-apps-20261022/`.
