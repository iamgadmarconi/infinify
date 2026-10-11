<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Native display clipping: source contract still incomplete

The helper currently changes and journals only transforms and optional alpha.
Protocol v2 advertises no native clipping capability. The desktop's clip plan
describes desired content rectangles; it cannot acknowledge native visual or
event clipping. Independent display views still use one real placement and
captured replicas. This note records source research on 2026-10-11; no symbols
were called, windows changed, fixtures launched or runtime behavior verified.

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
