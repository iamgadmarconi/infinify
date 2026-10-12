<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Native display clipping: ABI established locally, boundary behavior incomplete

The helper currently changes and journals only transforms and optional alpha.
Protocol v2 advertises no native clipping capability. The desktop's clip plan
describes desired content rectangles; it cannot acknowledge native visual or
event clipping. Independent display views still use one real placement and
captured replicas. Source research began on 2026-10-11. The 2026-10-12 owned
fixture checks below establish a local serialization/restoration contract and
show why successful clip readback does not establish a display boundary.

## Pinned API evidence

- [NUIKit/CGSInternal, CGSWindow.h at
  c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf](https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSWindow.h)
  declares `CGSCopyWindowClipShape` with connection, window and output-region
  arguments, but declares `CGSSetWindowClipShape` with only window and region
  arguments. Its window-alpha declarations use `CGFloat`, unlike the `float`
  ABI cross-checked against yabai and used by this helper. These historical
  declarations are leads, not sufficient macOS 26+ ABI authority.
- [PoomSmart/IDAObjcTypes, CoreGraphics.h at
  b0585a2e045a5858f83dcc35f37214848b25f3b5](https://github.com/PoomSmart/IDAObjcTypes/blob/b0585a2e045a5858f83dcc35f37214848b25f3b5/CoreGraphics/CoreGraphics.h)
  declares the clip setter with connection, window and region arguments. It
  does not supply the matching clip-copy getter. The disagreement cannot be
  resolved by checking whether either symbol exists.
- [NUIKit/CGSInternal, CGSRegion.h at the same
  revision](https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSRegion.h)
  describes region copying, rectangle enumeration, equality and reconstruction
  from a rectangle list. It does not establish whether a copied window clip is
  unrestricted, absent or empty, nor how native event/shadow regions interact.
- The local SDK's `SkyLight.framework/Versions/A/SkyLight.tbd` lists
  `SLSCopyWindowClipShape`, `SLSCopyWindowShape`, `SLSCopyWindowAlphaShape` and
  `SLSSetWindowClipShape`. Its CoreGraphics stub also lists region-data symbols.
  Linker export lists supply neither argument/ownership declarations nor a
  persistence format. No `CGS`/`SLS` ABI equivalence is inferred from the names.

## Installed-host ABI and lossless snapshot

Read-only disassembly of the installed Apple Silicon shared cache resolves the
historical setter disagreement for **macOS 27.2, build 26B5091g only**. The cache
is `/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e`
and its subcaches. SkyLight's unslid base is `0x182695000`, image UUID
`4960cb24-a64f-3724-93ea-7d4c340f305d`; CoreGraphics' base is `0x181edd000`, UUID
`a480a558-2bf0-3055-a735-8365a08e0d1f`. These observations do not establish the
macOS 26 ABI or cross-version compatibility.

| Function | Unslid address | Observed contract |
| --- | --- | --- |
| `SLSSetWindowClipShape` | `0x1829ac354` | `CGError(int cid, uint32_t wid, region)`; client returns constant zero |
| `SLSCopyWindowClipShape` | `0x1829ac454` | `CGError(int cid, uint32_t wid, region *ownedOut)` |
| `CGSGetRegionData` | `0x181ef7164` | `CGError(region, const void **borrowedBytes, uint32_t *length)` |
| `CGSNewRegionWithData` | `0x181fb6dc0` | `CGError(const void *bytes, uint32_t length, region *ownedOut)`; validates and copies |
| `CGSCopyRegion` | `0x181ef682c` | Retains the same immutable region object into an owned reference |
| `CGSRegionsEqual` | `0x181f55a54` | Native semantic equality; both-null also compares equal |
| `CGSReleaseRegion` | `0x181ef0d08` | Null-safe `CFRelease` |
| `CGSIntersectRegionWithRect` | `0x181ef57d4` | `CGError(region, const CGRect *localRect, region *ownedOut)` |

The CoreGraphics export trie explicitly reexports the CGS clip setter/getter
to these SLS implementations. The setter is three arguments on this image;
the historical two-argument declaration is unsuitable here. Setter zero is
uninformative: the client can return it without a successful lookup/send.
Require a successful nonnull getter and native equality after every write.

Getter output is an owned region. Region-data bytes are borrowed from it and
must be copied before releasing the region; persist bounded bytes, never its
pointer. Reconstruction produces an owned region. Check native equality,
emptiness and byte-for-byte reserialization before mutation. `CGSRegionIsEmpty`
also returns true for null, so null cannot classify a valid empty clip. A failed
or null getter makes that window snapshot-ineligible; it does not mean
unrestricted. Native empty is an explicit nonnull 12-byte region stream with
int32 values `[-2147483648, 2, 2147483647]` on this host.

`CGXWindow::set_clip_shape_internal` at `0x1829ee658` intersects a nonnull input
with the base shape's width/height at local origin. Its null initialization path
normalizes the base shape to that origin. A normal owned titled NSWindow returned
the complete nonempty local clip `[0, 0, 320, 252]`, 36 native bytes. An owned
getter-only probe copied, reconstructed, reserialized and repeatedly reread that
region with equality on 2026-10-12. This is a normal-window baseline, not a general
absent/unrestricted sentinel contract.

Exact function sizes, hashes and pinned provenance are saved locally in ignored
`target/native-clip-contract/abi-evidence.json`. Getter-only results are
`receipt.json` and `supervisor.json` in that directory. No shipping API currently
exposes these process-local experimental operations.

## Owned optical and hit-query check: negative boundary evidence

The 2026-10-12 run `target/native-clip-contract/mutation-20261012T002743Z/`
created only a uniform gray background and one titled marker-painted foreground
NSWindow. Existing screen-capture permission passed preflight without prompting.
Captures were restricted to their owned rectangle `[160, 160, 640, 460]`; native
hit-query coverage and uniform-background/marker pixels verified the baseline
before any setter. Both windows belonged to PID 35682, birth
`1791764863.330078`, owner connection 18132531; foreground WID 120340 and
background WID 120339. Setters were bound only to the foreground.

Original clip bytes, transform, alpha, bounds and exact identity were durably
saved before the first write. Each desired crop intersected the immutable
original region, reconstructed/equal-checked its bytes, then required getter
equality after writing. Each case restored the reconstructed original clip and
exact original transform, checked native equality and byte equality, and compared
display pixels independently through bounded `screencapture` children.

- **Nonempty left/right/top/bottom crops changed the clip getter but did not
  change displayed pixels.** All four crop PNGs were byte-identical to baseline,
  retaining all 281,083 foreground marker pixels and the original shadow.
  Baseline/crop/restore PNG SHA-256:
  `a47b2c0b53292759fe24d1ecaad2af0491e91687cf33763d6e8cf8c1a8c9ed88`.
- **Explicit empty clip hid the foreground and its shadow.** Its screenshot had
  zero marker pixels and zero dark pixels against the owned background. Empty
  PNG SHA-256:
  `2adc0740f8f0f4143a2a4e6c2c96320805e1745b751c0c4e3c1d93b75ca38cb4`.
  Restoring the original returned the exact baseline PNG.
- **Geometry and event-eligible queries disagreed.** At removed portions,
  `SLSFindWindowByGeometry` returned the owned background while
  `SLSFindWindowAndOwner` still returned the foreground, including with an empty
  clip. These are read-only routing/geometry observations, not delivered mouse
  events or activation/drag coverage. No input events were posted.

Both query ABIs were checked against installed code at `0x1829a993c` and
`0x1829a9a64`: eight arguments, including pointers to screen point, local output
point, WID and owner. `SLSFindWindowAndOwner` is also declared in
[yabai's pinned extern.h](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h).

The run stopped before completing transform/clip ordering: requested transform
`[1.3333333333333333, 0, 0, 1.3333333333333333, -486.6666666666667,
-406.6666666666667]` failed the probe's absolute `1e-5` comparison. The first
probe did not record its observed matrix, so no observed value is inferred.
Installed `SLSSetWindowTransformAtPlacement` at `0x1829b6ad8` explicitly narrows
all six doubles to floats at `0x1829b6b70`, `0x1829b6b74`, `0x1829b6b7c`.
Subsequent probes must match `payload-v2.m`'s native float equality and record
requested/observed matrices. This diagnostic limitation does not invalidate the
independent untransformed crop screenshots.

Final exact clip/transform/bounds/alpha restoration succeeded; all earlier
restored screenshots also matched baseline. Both windows and every capture child
were closed, no signal/forced kill was needed, and no pending journal remained.
The probe receipt records 4.95 seconds and 19 native setter calls including
restoration. `receipt.json`, `supervisor.json`, PNGs and `interpretation.json`
preserve this evidence. This validates owned normal-exit restoration and an
exception-path restoration; it does not test persisted startup recovery after a
crash, foreign-window authorization, or lease/disconnect recovery.

The installed server handler `WSWindowSetClipShape` at `0x182a036c8` updates
local clip state, invalidates visible-shape differences and schedules displays;
separate `set_layer_clip_shape`/global-clip paths exist. The observed partial-clip
failure is consistent with a drawing/visibility-region distinction, but the
binary call chain alone does not identify the complete modern compositor mask.
No additional shape, event-region, shadow or global-clip state has been mutated.

## Narrow redraw and transform-order retry

`target/native-clip-contract/mutation-20261012T003723Z/` repeated the same scene
with a new owned PID 37969 and explicit content-view/window redraws after each
crop. It completed in 11.55 seconds with 23 setter calls including restoration;
the operation deadline reserved twelve seconds for cleanup within the authorized
sixty-second envelope. Existing capture permission, exact ownership and owned
baseline pixels were rechecked before mutation. Every crop still read back equal,
but **all four nonempty cropped/redrawn PNGs remained byte-identical to baseline**.
The original shadow remained visible. Empty/redrawn-empty again hid the entire
foreground and shadow. Event-eligible/geometry queries retained the same mismatch.

Both clip-first/transform-second and transform-first/clip-second completed using
the existing helper's float comparison. In both cases requested transform was
`[1.3333333333333333, 0, 0, 1.3333333333333333, -486.6666666666667,
-406.6666666666667]`; observed was
`[1.3333333730697632, 0, 0, 1.3333333730697632, -486.6666564941406,
-406.6666564941406]`. These match after the installed setter's float narrowing.
Final images for the two orders were identical to each other (zero changed
pixels), but both leaked 69,811 foreground marker pixels outside the requested
projected clip, retaining the uncropped scaled window and shadow. Final-order PNG
SHA-256: `0cce4303de7e101b84a267df4e3e3d81c3f409061f5b5e6c30c843ec8f47e137`.
Intermediate images also contain pixels outside the final viewport; the separate
writes establish no atomic display-boundary guarantee.

Read-only extra snapshots established three nonnull reconstructable originals
for this owned normal window:

| Getter | Region bounds | Meaning established from installed code |
| --- | --- | --- |
| `SLSCopyWindowShape` | `[280, 260, 320, 252]` | Base shape in global untransformed coordinates |
| `SLSCopySpecifiedWindowShape`, selector 9 | `[-4, -4, 328, 260]` | Stored raw event shape at window+272 |
| Same getter, selector 10 | `[-24, -17, 368, 300]` | Layer clip at window+296, including shadow extent |

All three had 36 native bytes, successful getter/reconstruction and native
equality. `SLSCopySpecifiedWindowShape` at `0x1829ade40` uses four arguments
`(cid, wid, selector, ownedOut)`. The server's exact selector jump table is at
`0x1826ac904`, implemented by `WSCreateSpecifiedWindowShape` at `0x182a03d5c`.
Failed/null results still collapse to status 1000, so default absence cannot be
classified from that error alone. Selector 10 does not establish the original
global-clip setter state: global clipping combines separate stored inputs before
producing derived layer state. No additional region writer was resolved/called.

All seven restored captures matched the original baseline exactly; final native
clip bytes, transform, alpha and bounds matched the original. Both windows and
all capture children exited normally, with no pending journal or forced signals.
Saved source, binary, receipts, PNGs and a SHA-256 manifest preserve the retry.
Complete shape/event/global-state restoration and a compositor-mask path still
need their own owned validation. **Do not advertise native display clipping from
the locally successful clip getter/setter/serialization contract.**

## Required adapter contract

Before adding a writer or negotiating a protocol capability, establish:

1. Exact supported-host getter/setter signatures, return conventions and region
   ownership, including reads of another allowlisted process's windows.
2. Original clip semantics in the untransformed member's coordinates, keeping
   unrestricted/absent and empty clips distinct. A content bounding rectangle
   cannot stand in for an arbitrary original shape.
3. Lossless bounded region serialization and reconstruction, with native
   equality checked before mutation. Native pointers cannot enter the journal.
4. How visual clips affect native shadows and event/activation/drag regions.
   Any additional touched state needs its own exact snapshot and restoration.
5. Persisted original state before the first write, under the existing exact
   PID/birth/window/owner and authenticated allowlist checks. A clip request
   must accompany the exact member bounds and transform that produced it.
6. Apply/readback and restore/readback checks for that state. Failed or partial
   writes stay journalled and block reuse until restored or the exact original
   process/window is gone; disconnect, lease expiry, unbind and startup recovery
   must retain the same obligations.

Once these contracts are available, clip the original region by the planned
display rectangle instead of replacing it with a guessed rectangle. Restore
the original when the member is again fully visible, and retain it in the
session journal until final restoration. Per-member clipping is necessary:
popups can extend outside their root, and must be clipped to the owning display
without using the root content rectangle as their boundary.

Runtime acceptance remains separate from ABI and compiler checks. Unsupported
hosts must advertise no clipping capability; an implementation cannot silently
move, hide or disable a partial native view to claim display-boundary parity.
