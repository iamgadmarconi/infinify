# Native family capture feasibility gate

This is an isolated diagnostic fixture, **not a supported native-family compositor**.
The saved capture evidence fails the independent-window placement gate. No exact
native input, focus, AX parent discovery, or third-party family parity is claimed.

## Build and run

```sh
./scripts/build-families.sh
./tests/e2e/native-families.sh
./tests/e2e/native-families.sh --lifecycle-only
```

Apple Silicon / macOS 26+, with existing Screen Recording and Accessibility access,
is required. Default/help does not initialize AppKit or request permissions. The
full test intentionally returns nonzero when the real capture gate fails. The
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
converted into saved PNGs. The candidate draws these pixels twice using independent
0.6/0.9 scale, pan, and hard clipping, preserving measured native positions. A
second experimental route uses a display-bound filter restricted to the owned app
with `includeChildWindows=YES` and a measured native-family crop. The flag is never
assumed to affect desktop-independent filters. Filter contentRect/pointPixelScale
and per-frame contentRect/contentScale/scaleFactor/screenRect/boundingRect are saved.

Ownership and IDs are independently checked against CGWindow and SCWindow.
AppKit-reported parent IDs establish **owned fixture setup only**. AX enumeration is
attempted but passive startup exposes no AX server on this host. No production
parent-discovery inference may be made from those fixture IDs.

## Observed boundary (2026-10-09)

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

Each original run's `verification.json` binds its implementation/binary hashes and
exported evidence hashes. These are historical runs, not claims that their source
hash matches the current file. The final lifecycle run tests the current native
implementation. The current verifier separately records its stricter reanalysis of
the older saved pixels in `evidence/reanalysis.json`. The later bounds-interruption
guard has strict-build and lifecycle coverage, but no successful full capture run.

## Integration recommendation

Keep this diagnostic out of the desktop feature path. Do not create one compositor
node per SCWindow until a capture adapter can identify and normalize the actual
captured family extent without double counting. Require real AX/native parentage,
measured z-order, transient lifetime invalidation (CG disappearance matters even
when SC entries linger), and separately proven native controls/focus. A display-app
fallback needs its own successful pixel proof and bounds-stability explanation.
