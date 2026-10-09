# Native family capture feasibility gate

This is an isolated diagnostic fixture, **not a supported native-family compositor**.
The archived metadata-normalized root-family experiment passes for one right-extending
AppKit panel and one sheet inside its parent on macOS 27.2 (26B5091g). The current
private-parentage/left-up extension is implemented but its first run was interrupted
before discovery or capture; it is not yet proven. The older
independent-child and display-filter failures remain archived unchanged. Native input,
focus, production parent discovery, and third-party parity are not claimed.

## Build and run

```sh
./scripts/build-families.sh
./tests/e2e/native-families.sh
./tests/e2e/native-families.sh --lifecycle-only
```

Apple Silicon / macOS 26+, with existing Screen Recording and Accessibility access,
is required. Default/help does not initialize AppKit or request permissions. The
full test returns nonzero when the real capture gate fails. The
lifecycle-only test proves cleanup; it makes no capture capability assertion.
Do not run beside other native probes. Stop on foreground/input/bounds interference.

## What is real

The owned child process creates two ordinary titled NSWindows in one application,
an NSPanel attached with `addChildWindow:ordered:`, and a sheet with `beginSheet:`.
Native NSButtons exist to create/dismiss the transients. For the passive capture
sequence, fixture timers invoke those actual AppKit actions: baseline, panel,
dismissal, sheet, dismissal. This is expressly fixture setup, not native input
proof. There is no action RPC, exported custom surface, or reconstructed popup.

Each surface has a changing colored patch. Actual SCStream CVPixelBuffers are
converted into saved PNGs. The root-family candidate creates exactly two streams, one
for each explicitly enrolled ordinary root, and no stream for a child. Each root
family is drawn once in each independently clipped 0.6/0.75-scale camera.
The archived normalized pass used 0.6/0.9 instead.

The buffer allocation uses the initial filter contentRect times pointPixelScale.
For every complete frame, contentRect times scaleFactor gives the buffer's content
pixel rectangle. contentRect.size divided by contentScale gives the original
captured extent size. The archived candidate anchors that extent at screenRect.origin.
That origin rule was tested only for the right-extending panel and in-bounds sheet;
left/up expansion was not established. The current unverified extension uses the
WindowServer-associated CG union for the origin, as described below. No fixture parent IDs or expected child
rectangles feed the compositor's extent calculation.

Per-frame screenRect/contentRect/contentScale/scaleFactor/boundingRect, CV buffer
size, normalized mapping, and extent transitions are recorded. During the panel
phase screenRect remains the 360-by-272 root, while contentScale becomes roughly
0.734694 and the derived extent becomes 490-by-272. Drawing the content rectangle
at this extent preserves the parent's world size rather than shrinking it.

The native fixture's two roots are initially separated to avoid interleaved z-order.
Cross-root overlap or a child interleaved with another root remains unproved.
The old display-bound fallback is removed from the current executable.

Ownership and IDs are independently checked against CGWindow and SCWindow.
AppKit-reported parent IDs establish **owned fixture setup only**. AX enumeration is
attempted but passive startup exposes no AX server on this host. No production
parent-discovery inference may be made from those fixture IDs.

## Earlier failure boundary (2026-10-09)

- `evidence/independent-complete`: all five native phases completed with unchanged
  foreground and top-level bounds, followed by clean reaping. Child CGWindow IDs
  disappeared after dismissal; SCShareableContent retained stale child entries.
- Independent parent/child filters returned grouped family pixels. During the panel
  phase, the parent marker occupied `(15,141)-(73,185)` instead of its native
  `(20,192)-(100,252)` pixel rectangle. Child images also included the parent.
  `panel-1.png` and `sheet-1.png` visibly duplicate/shrink the family when individual
  window bounds are used. The gate rejects this; stream success alone is insufficient.
- `evidence/display-failed`: the owned-app display stream produced zero complete
  frames. Native CG bounds then changed from x=221 to x=2250/2306, despite no source
  repositioning calls in the capture harness. SC/CG identity comparison aborted.
  The cause is unresolved; this is not evidence that the API universally fails.
- `evidence/lifecycle`: deadline, SIGTERM, SIGINT, and host SIGKILL/parent-death checks
  pass. Every source was gone before credential redaction and final artifact hashes.

Earlier startup experiments calling `finishLaunching` activated the source despite
no explicit activation request and were aborted before controls. The final source
omits `finishLaunching`. Native AXPress, pointer, keyboard, and focus behavior remain
unproved. There were no additional activation experiments after this boundary.


## Private parentage and left/up extension: unverified

The current executable adds read-only WindowServer discovery through dynamically
resolved SLSCopyAssociatedWindows and exact single-window query/iterator APIs. ABI
provenance is pinned to yabai dd845723416f5fe92af49fad5ebab00369e07edd; its MIT notice
is retained in `YABAI-NOTICE.txt`. No mutation or scripting-addition APIs are loaded.

Every query is scoped to the disposable PID and its enrolled birth identity. CG
ownership is checked before and after parent queries; returned iterator IDs/counts
must be exact. Associated children must have nonzero native parents and complete,
acyclic chains to the selected root. Missing, ambiguous, vanished, foreign-owned,
or contradictory relationships fail closed. AppKit fixture parent IDs appear only
in the independent verifier's oracle, never in discovery or extent calculation.

The candidate anchors the captured extent using the native union of these verified
associated-window CG bounds, while independently requiring the size to match frame
contentRect.size / contentScale. A genuine left/up-extending panel and dismissal are
added after the earlier five stages. Camera pan/scale/clip rectangles now exercise
left, top, right, and bottom clipping. The verifier also checks the private parent IDs
against the owned AppKit oracle and keeps the unrelated root out of the family.

`evidence/parentage-interrupted` records the first attempted run. At baseline, the
ordinary windows were actively scaled/moved between snapshots (roughly 139-by-105
then 136-by-103 instead of their 360-by-272 native setup). SC and fresh CG bounds
disagreed, so enrollment aborted before any stream or parent/association query.
Foreground stayed unchanged and all sources were reaped before redaction/hashing.
No retry was made while the desktop was changing. Strict build and syntax checks
pass, but the new private API path and left/up pixel test remain unverified. The
prior normalized pass below applies only to its archived implementation snapshots.

## Archived bounded pass (2026-10-09)

`evidence/normalized-pass` records the full default E2E pass. The independent
`verify_normalized.py` checks 40 saved camera views across five native stages:

- Parent and unrelated root markers remain 80-by-60 native points (2-point tolerance
  for capture resampling); the panel and sheet retain their measured CG offsets.
- Each colored native identity appears once in each camera at its expected bounds.
  Real sheet occlusion of parent content is respected. No child stream is created.
- Both live patch phases appear in the saved native pixels, view clipping is checked,
  and child colors disappear after native dismissal. Native root bounds stay fixed.
- Source deadline, SIGTERM, SIGINT, and host-SIGKILL parent-death checks pass. Every
  source was reaped before credential redaction and final-byte evidence hashing.

The root extent transitions 360-by-272 → 490-by-272 → 360-by-272 around the panel;
the sheet stays within the root extent. SCShareableContent still retains dismissed
child entries after CGWindow disappearance. The stable foreground PID and zero
input/activation counters substantiate passive execution only.

Every original run's `verification.json` binds its implementation/binary and saved
artifact hashes. Historical manifests are not claims that old source hashes match
the current implementation. The new normalized run additionally includes the exact
implementation source files and verification scripts under `implementation/`, plus
the base Git revision. `normalized-review.json` records the inspected saved images
and the review host version. Earlier `reanalysis.json` describes the old failure.

## Integration recommendation

Keep this diagnostic out of the desktop feature path pending runtime verification
of parent discovery and left/up extents. Independent source review does not
establish those native capabilities.
The observed grouped behavior is not a public cross-version guarantee. A root-family
capture adapter using measured scale/extent is promising for this fixture, but
screenRect alone is insufficient and the left/up origin rule needs its own test.
Do not create one compositor node per SCWindow: that double counts grouped pixels.
Require genuine API parentage, selection/lifetime policy, left/up extent evidence,
interleaved z-order handling, and separately proven native controls/focus before
integrating a general family compositor. No display-filter fallback is claimed.
