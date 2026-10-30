# Dock payload

The payload the Dock loads: the arrival veil, the journal and strict recovery, and why transforms are written at placement 1 (code in `native/dock-helper/Payload`). The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Arrival veil

A window an application opens is shown at its native size and place until the shell has listed
it and the first frame has placed it: about 20 to 30 ms when placement works and for its whole life
when it is refused. The `VEIL` request (capability 128) closes that gap from inside the Dock. It is an
adaptation of the idea Sunlight uses (see [Attribution and provenance](../README.md#attribution-and-provenance)), as an alpha write instead of a window level.

- **Offered** only by the explicit same-user helper (not an allowlist or cooperative one) that has
  alpha getters/setters and could register for the window server's announcement of a window added to
  a Space (SkyLight connection notification 1325; payload: Space id u64, then window id u32). A control
  session asks with mode 1 and is answered status 0 and the bound (`DW2_VEIL_TIMEOUT_MS`, 1000 ms), or
  status 1 (refused: no capability, or the client's own process could not be read from the socket); mode 0 ends
  it and releases what is held. A malformed request ends the session like any other. It ends with
  the session. The desktop shell asks after its empty-table audit and carries on without it if refused.
- **Which windows.** The Dock's main thread only receives the announcement and hands its window id to v2q;
  every native call and the journal write run on v2q, the helper's own queue. A window is
  veiled when it is at layer 0, at alpha exactly 1, at least 40x40 native points (the shell's own candidate
  floor), of the login user, in scope, with a process birth that resolves, not in the table or released
  table, and not a window of the Dock or of the client's process (the control connection's `LOCAL_PEERPID`).
  A window below alpha 1 is fading in under its application's own animation (a TextEdit
  *Save* sheet was read at 0.79, and its next animation frames overwrote the veil); it is left alone, and a
  fractional alpha is never taken for an original. The window need not be on screen: the announcement
  comes before it is ordered in, and its row has no on-screen key yet.
- **How.** A veiled window is an ordinary table entry with its original transform, bounds and alpha
  (and `alpha_touched`), journalled (the whole table, fsync, rename, directory fsync) **before** alpha 0 is
  written and read back. Two optional journal keys mark what the veil has and has not touched:
  `veil_bare` (only alpha was changed, so no transform is owed) and `veil_alpha` (the alpha obligation is the
  veil's, so it is put back only while the window still reads alpha 0). If the record cannot be written nothing
  is changed and the journal is retried. If the write or readback fails or identity changes, the ordinary
  release runs. A full table first prunes released windows proven gone, like a frame; if it is still full the
  window is not veiled.
- **Ways out.** (a) A frame record for it. The first one re-reads the window's transform and bounds, because
  the application may have moved or resized it since the announcement, and writes one journal record
  (the fresh values, `veil_bare` cleared, `veil_alpha` cleared too if the record carries an alpha) **before any
  write**; if that record cannot be written the status is `JOURNAL`, nothing is written, and the window stays
  veiled with what it was read as. Then the transform, then the record's alpha, or, when it has none, the original
  alpha lifted only if the window still reads 0 (an application that has taken the alpha over is not
  overwritten). The window is never left invisible by a transform that did not take. Later frames write no journal
  and no alpha for it. (b) A `RESTORE` record for it, or `RESTORE_ALL`, the end of the session or `VEIL` mode 0: the
  ordinary release. (c) `DW2_VEIL_TIMEOUT_MS` after it was veiled, if still veiled and held: the same release. The
  timer lives in the Dock: if the Dock dies there is no bound and no release until recovery. (d) A window that closes or
  is replaced is dropped by the identity logic of the release, with no write. A crash or lost helper is covered by
  the journal replay like any entry. A release of a window that was only veiled (`veil_bare`) writes no transform
  (the window server's transform follows the window's position): it reads the transform and takes it as the
  original, and a replay of such an entry does the same. After the first frame the journal says a transform is
  owed, with the values read then. An alpha obligation with `veil_alpha` is written back only while alpha reads 0, so
  a window that was placed with no alpha of its own is never written again, and a window an application has taken
  over keeps its alpha; an alpha the shell asked for is its own obligation and is put back as before. `veiled`
  (whether alpha is being held now) is memory only.
- **Not covered.** Windows not at layer 0 (utility panels at the floating level, menus, popovers) are not veiled; a child of a window the
  shell has placed gets *arrival placement* instead (next bullet).
  A window already known to the window server that is announced again for a Space change and not managed by the shell
  is held for up to the bound (while the Dock lives). A window the application animates (TextEdit's document windows, sheets) can have the veil
  overwritten by the application: TextEdit's own open animation wrote alpha 1 about 0.5 s after creation (measured
  501 to 533 ms), before the bound, when nothing placed the window. The veil is not an optical result.
- **Arrival placement: a child of a placed root.** The veil holds a window by alpha, and only at layer 0 and alpha 1. A context menu is
  announced already at level 101 and on screen (the notification arrives with layer 101, ordered in, alpha 1), and the shell's family frame placed it 23 to 40 ms after the announcement (four timed cases). A sheet, a
  popover or a completion list is announced at alpha 0 to 0.9 under the application's own fade, which no veil can hold. Without
  this path, 12 of 12 such popups in a guest were on screen where the application
  put them, not where their root is drawn, for 1.3 to 191.3 ms: context menus 10.9 to 36.2 ms, pop-up button and pull-down menus 81.4 and
  114.6 ms, a popover 191.3 ms (fading in), a sheet 13.2 ms (alpha up to 0.16), a combo list 1.3 ms. So for such a window the helper does
  not hide it: at the announcement it gives it the placement the shell gives every member of its root's family. Conditions, all read fresh
  on v2q: the window's exact WindowServer parent chain (the single-window query the shell's family audit uses, `v2ParentOf`; every link one
  process instance of the login user) ends at a root that is a held table entry the shell has placed (`appliedTransformKnown`, not
  restoring, not merely veiled, its transform still the one applied, no rotation), the window is in scope and is neither the Dock's nor the
  client's, it is in neither the table nor the released table, and the placement differs from what it has. The placement is the root's
  transform with its translation moved by the window's native offset from the root (the shell's `m[4]-=dx, m[5]-=dy`, DWNativePresenter+Frames.m
  `-describe:`), both bounds read now. The entry is an ordinary one: original transform, bounds and alpha journalled before the write, the
  write read back (a transform that does not take is released at once), no alpha touched. The first frame that names the window claims it and
  replaces the placement (normally by an equal one: a repeated record writes nothing); otherwise `DW2_ARRIVAL_TIMEOUT_MS` (500 ms) after the
  announcement, RESTORE, RESTORE_ALL, the end of the veil (mode 0 or the session) or a closed window release it by the ordinary release, which
  puts the original transform back. Nothing else is touched: a window with no parent (the global menu bar's menus, status items, every
  application's own windows) is left alone, as is a child of a window the shell has not placed. It is gated by the veil request. Announcement to the read-back placement took 1.0 to 3.4 ms for 27 of 29 windows in the trace
  build and 22.6 and 26.5 ms for two opened while frames were being applied (the helper's queue is serial). A window that the helper has
  released and the application shows again (Chromium and AppKit reuse windows) is in `v2Released` and is not placed again by this path.
  No wire change. Results with the shell running are in [the shell's account](../../app/CompositorMode/COMPOSITOR-MODE.md#popups-and-menus-of-a-transformed-window-full-desktop-dock-helper).
- **The shell** (`DWNativePresenter+Families.m`, `DWWindowManager.m`, `Desktop+Windows.m`) asks after admission, and lets go at once
  of a window it will not manage: `-windowNotAdopted:pid:` is sent once per appearance, from the first discovery
  pass on, for a window of a non-regular application, a window the shareable windows or Accessibility do not count as
  a window, one a read of which settled as not real, one `attach` refused, and one `-windowAppeared:` could not take
  because the canvas was closing or had no panels. The presenter queues one `RESTORE` record for that exact process
  instance (`-declineWindow:`); any reply retires it, since the helper's bound is the backstop. A window the helper
  holds nothing of answers a release with a no-op status 0. If the veil request gets no answer in time or an
  unreadable one, the shell assumes the veil may be on and keeps releasing explicitly: a wrong "on" costs a no-op record,
  a wrong "off" would leave such a window invisible for the whole bound.

`DWPayloadRestoreIdentityTests.m` and `DWPayloadForwardOperationsTests.m` use substituted native calls for every rule above (eligibility
refusals, journal before alpha with a failing journal changing nothing, transform-then-alpha, decline/bound/end/recovery, closed and replaced
windows, the request and the announcement payload through the real handler on a socket pair), and `DWPayloadArrivalTests.m`
covers the arrival placement cases (`arrivalCases`). `DWHelperClientTests.py` checks the C client's request, refusal and invalid-reply
handling against a fake peer. These are not native evidence.

One control `HELLO` creates the session and a random token. A second heartbeat
connection uses that token; requests on either renew the 2000 ms lease. The C
client heartbeats every quarter lease.
Control disconnect, malformed control request or lease expiry restores all held
windows. Closing only a heartbeat connection does not end the session. An alive
C heartbeat thread can retain windows while its caller stalls. A fully stopped
client expires; a fully stopped helper cannot restore until it runs again.

Frames use one newest-frame slot, limited to 1024 records. Waiting frames are
superseded instead of building a queue; the next frame reply counts them. One bad
record does not prevent the others. `RESTORE_ALL` discards a waiting frame;
a later frame is processed afterward. Probe, inspect, restore, native calls,
table changes and journal writes run serially on the helper's own queue. Socket parsing, heartbeats
and lease checks run on connection threads. Acceptance of own-queue native calls
inside Dock still requires scoped real-host evidence.

## Journal and strict recovery

Schema-4 `v2-journal.json` preserves the current Dock writer identity and each
first-touch identity, owner, original `layer` (the window's placement-1 transform, normally the identity; see
"The original is the layer" below), alpha, alpha-restoration
obligation and native bounds. Its `released_windows` table retains exact original
records after a successful restore, because a later Dock replacement may reset
WindowServer transforms again. When retiring a runtime, its current journal is
the handoff input. A fresh recovery runtime initially imports the exact staged
`recovery-source.json`; the payload commits a journal under its new writer before
any native setter. From then on that committed journal is the replay authority,
and a malformed one never falls back to the import source. The source and its
sidecar digest remain provenance only after import. Originals are captured before
any change. The entire new-window batch is journaled before applying any of it;
unchanged held windows require no journal write. A first alpha change is journaled
before setting it. Persistence uses exclusive no-follow mode-0600
`v2-journal.next`, file fsync, rename and directory fsync. Failed persistence
blocks unjournaled mutation and leaves `journal_pending=1` until a durable retry.

Restoration re-resolves the exact identity, owner, UID and scope, sets the captured
original layer (written at placement 1 and read back as the placement-1 layer, see "Placements") and alpha,
and requires a readback equal after float rounding (`v2SameTransform`; a layer read back alone is exact). A real cross-display
quit exposed late AppKit reflow after an immediate successful readback. Entries
with a Space obligation remain pending for at least two seconds from the
start of restoration and until native bounds, original membership and exact
layer/owed alpha stay stable for 500 ms. Samples precede corrective writes;
settlement checks run every 250 ms, and their transient timing evidence is never
imported from a journal. This waits for native reflow without promising to restore
the original native bounds. Confirmed restored or gone windows leave the table;
uncertain windows remain restoring. Failed owner, window enumeration or
process-birth queries cannot establish absence. A still-live
matching original outside the new helper's scope is retained as pending too.
Other retries run after 250 ms, 500 ms, 1 second and then every 2 seconds without
an abandonment deadline. If native restoration completes but its journal update
fails, the table can be empty while `journal_pending=1`. Controllers must require both native
emptiness and a durable receipt before admitting new presentation. Removing the
persistence obstruction permits autonomous retry without another request.

On restart, the helper validates the entire committed journal before deleting any
interrupted staging file or replaying it: exact schema/version and keys, integral
bounded identities/counters, no duplicate windows, valid layer/bounds/alpha,
consistent states, and valid restoration receipts. It refuses unknown or malformed
journals and preserves their bytes. A replay restores only still-matching windows
within the new helper's scope; changed or gone identities are left alone. An
alpha obligation is refused if the required native symbols are unavailable.
Only a private regular staging file may be removed after successful validation,
or when no committed journal could have authorized a mutation.

`recovery.json`, `recovery.next` or `helper.sock` artifacts left by an earlier
helper are never replayed, cleared or converted automatically. Any presence
refuses startup and preserves the files, including a purportedly clean receipt.
Existing `v2.sock` also refuses startup. Bind/listen and journal validation must succeed
before readiness. A process crash, machine failure or stalled helper cannot run
in-process restoration; preserved journals require exact-identity reconciliation,
not blind reinjection or deletion.

### The original is the layer

A window's original is its **placement-1 layer** (`SLSGetWindowTransformAtPlacement(cid, wid, 1, NULL, &t)`, `dwReadLayer`),
captured at first touch and journalled as `layer`. Restoration writes exactly that layer back at placement 1 (`dwWriteLayer`) and
verifies the **layer** on readback, never the catenated matrix. Schema 3 held the absolute catenated matrix instead, which is the
sum of placement 0 (the position, following the native frame), the helper's layer and every other placement some other writer
holds, and that had two failures:

- *Foreign placements.* Measured on the guest (vm1, 2026-10-30): a Finder window adopted while macOS still had its open-animation
  contribution on another placement (catenated `[0.999,0,0,1,0.5,-201]`) was journalled with that as its original, restored to it
  at quit (log: `native presentation: window 66 of process 392 not placed: the set failed or read back differently`), and after
  `killall Dock` no state the reattachment guard accepted matched the entry, so the recovery readiness audit failed, the entry
  stayed `reattaching` with `last_restore` pending, and the launcher's pending marker blocked every later start. The layer is
  not affected by other placements, so the original of such a window is the identity, as for every other.
- *A moved native frame.* A catenated original contains the position of the window when it was captured, so it had to be re-based
  on the origin read at the write (`v2RestoreTransform`, with a before/after origin read and a stricter reattachment guard). A
  layer is relative to placement 0, which follows the native frame by itself, so none of that is needed and it is gone: a window
  the application or a drag moved meanwhile is natural where it now is, and restoration writes the same layer however far it moved.

What remains of the earlier rules:

- **Reattachment guard** (a released original taken up again after the Dock was replaced): the window's identity is current, and its layer
  either still the original or the identity the death of the writer's connection reset it to. Anything else was written by someone
  since and is not undone. Where the window is does not matter (a layer is relative to placement 0), so a released window moved
  after its release converges too; the retained bounds are refreshed at each release and are not a fence. A window already natural (layer identity) after the death therefore converges to restored at once and
  leaves no entry behind; the entries never stay pending for want of a catenated match.
- A veil-only release (`veil_bare`) adopts the layer in force; the Space settlement samples compare the layer.
- The absolute shims (`getTransform`, `setTransform`, below) are what frames use to place windows. An arrival placement also reads the
  absolute matrix once, to see whether the window is already where its root's family puts it. The shim read is placement 0 composed
  with placement 1, not the catenated read of every placement, so a window the system is animating open (a further placement of
  another writer) reads back as applied as soon as its own layer took, instead of as not applied until the animation ends; the guest
  showed that difference (below).
- The pending receipt's `diagnostic` carries `saved_layer`, `actual_layer`, `layer_set_status`, `layer_get_status` and
  `layer_matches`; it is informational, and a receipt is valid without it.
- A window an earlier build left with placement 0 reset to the corner (`[1,0,0,1,0,0]`) keeps whatever placement 0 says: the helper
  never writes placement 0, so restoration cannot move it. Only its application's restart does (see "Placements").

**Schema 4 and older journals.** The payload accepts only `v: 4`; a journal of an older schema, or one with the old `transform` field,
is refused whole and untouched. There is no migration: the launcher (`scripts/native-desktop-launcher.sh`) reads the retired helper
journal's `v` first and, when it is not 4, prints that nothing was recovered, archives the launch record and the journal under
`retired-launch.*` in its state directory, leaves the retired runtime alone and starts fresh, so an old journal never blocks later
starts (`tests/e2e/native-launcher.sh`). The loader refuses a recovery journal that is not `v: 4`.

`DWPayloadLayerTests.m` covers this on the modelled window server of `DWPayloadPlacementTests.m` (placement 0 following the native
frame, the helper's layer, an extra placement of another writer): adoption with a non-natural foreign placement, a native move while
held, a non-identity original layer, a layer the server does not take, a Dock reset of a held entry and of a released one, a foreign
layer written since, and the refusal of previous-schema journals. These are not native evidence.

**What the guest showed for the layer original** (vm1, macOS 27.0.1 26A434, 2026-10-30, Finder windows only; the reader was a small
tool reading placements 0 and 1, `SLSGetCatenatedWindowTransform` and `SLSGetWindowBounds` from an ordinary process; evidence in
`target/lane-helper/guest.txt` of the working tree that made this change, not in the repository):

- An untouched Finder window reads placement 1 = identity with status 0 (so the original can always be read). `open ~` while Infinify
  ran: the window server's open animation was visible as a catenated transform with placements 0 and 1 natural
  (`[1.02041,0,0,1.02041,-10.2041,-212.245]` falling to `[1,0,0,1,0,-201]` over about 8 back-to-back samples; the failing smoke's
  `[0.999,0,0,1,0.5,-201]` is one of its samples, `[0.999001,0,0,0.998573,0.499501,-200.214]`). The helper adopted the window during that
  animation (10 samples with a foreign contribution while the window was adopted) and the journal row read `layer [1,0,0,1,0,0]`, state
  `held`, schema `v 4`, never the catenated matrix. At zoom 0.5 the window read placement 1 `[2,0,0,2,-1556,-529]`; after `quit-native`
  placement 1 was the identity and the catenated transform `[1,0,0,1,0,-201]` on every layer-0 window (4 of 4), and the log had no
  "not placed" line. (With the first version's catenated read, 5 reopen cycles that overlapped the animation logged three "not placed"
  lines at placement time and none at quit; with the placement-0-composed-with-1 read, a run with the same overlap logged none.)
- `killall Dock` during a session with two placed windows (`[2,0,0,2,..]`): 8 s later both read layer identity and natural, Infinify
  reported the helper lost. After `quit-native` and a new start the launcher took the retired Dock's schema-4 journal (two `held` rows),
  the loader recovered it, the payload's `last_restore` read `connection handoff`, `restored`, `restored`, readiness was established and
  no `launch.pending.plist` existed. A released window from an earlier session (the guest's failing case) likewise ended
  `restored` at the handoff.
- `quit-native`, then `killall Dock` with Infinify not running: all 5 layer-0 windows natural afterwards, and the next start was not
  blocked.

The owned-fixture native evidence is `DWPayloadFixtureTests.py --native-move` (opt-in, needs Accessibility for the test process).
The whole-desktop evidence is in the shell's README section "Restore after a native-origin move".

## Placements: why transforms are written at placement 1

Established on the disposable guest vm1 (macOS 27.0.1 26A434, SIP off) on 2026-10-30; nothing here was run on another build or on
the owner's Mac. The problem and the placement semantics below are what the investigation measured (probe payloads loaded into the
Dock; its notes are not in this repository); "What the guest showed" is this change's own run.

**The problem.** After `quit-native` had restored every window correctly, `killall Dock` drew every window the helper had ever
written at the top-left corner of the display (`SLSGetWindowTransform` = `[1,0,0,1,0,0]`, `SLSGetWindowBounds` still the native
origin) until its application was restarted, and the next helper session took that state as the window's original. The window
server keeps one transform entry per window **per placement**; each entry remembers the connection that last wrote it, and when
that connection dies (here the Dock: `killall`, `kill -9` and `abort()` behaved alike) the window server resets its entries to
identity. `SLSSetWindowTransform` is placement 0 (its disassembly is a tail call into
`SLSSetWindowTransformAtPlacement(cid, wid, 0, 0, &t)`), and the placement-0 entry encodes the window's position: untransformed it
reads `[1,0,0,1,-x,-y]`, so identity there means "drawn at (0,0)". No repair from outside the Dock's connection restored such a
window (Accessibility position and size writes, the application's own `setFrame`, hide/unhide, minimize, fullscreen, `AXRaise`,
`SLSMoveWindow`, `SLSTransactionResetWindow`, `SLSResetWindows`, a window-server drag, Mission Control, screen lock); only a
placement-0 write from a Dock connection did, and that claims the entry again for the next death. A second connection's
placement-0 write was silently ignored (status 0, no effect).

**What is written instead.** A placement of 1 or more is a layer applied after placement 0 whose identity means "as placement 0
has it". A reset layer is therefore harmless: the window is where its native frame is. Every helper write is now
`SLSSetWindowTransformAtPlacement(cid, wid, 1, 0, &layer)` (flags 0, relative) and the absolute read is placement 0 composed with
placement 1 (the first version of this change read `SLSGetCatenatedWindowTransform`, the disassembly of which is
`SLSGetWindowTransformAtPlacement` with placement `0x7fffff00`, the matrix of every placement; see "The original is the layer" for why
that was narrowed). `DWPayloadState.m` keeps its call sites' meaning, an absolute matrix (the whole map from the screen into the window's space), in
two functions, `dwReadAbsolute` and `dwWriteAbsolute`, which `getTransform` and `setTransform` point to:

- `dwWriteAbsolute(A)` reads placement 0 (`T0`, which follows the native frame) and writes the layer `L = A after T0^-1`
  (`CGAffineTransformConcat(CGAffineTransformInvert(T0), A)`; for a plain `T0 = [1,0,0,1,-x,-y]` this is `A.t - M*T0.t`, linear
  part unchanged). A layer within 1/256 pt of the identity is written as exactly the identity, so a natural window's restore writes
  `identity` at placement 1. Placement 0 is never written; `SLSSetWindowTransform` is not even resolved, and a missing
  placement symbol refuses the helper's start rather than falling back to it.
- `dwReadAbsolute` reads placements 0 and 1 and composes them (placement 0 first). The window server composes the layers in float, so a request read back after a layered
  write can differ by a rounding: `v2SameTransform` (every readback check, the repeated-frame skip, reattachment and the Space
  settlement) accepts a translation within 1/256 pt and a linear part within 1e-6.
- Originals are not absolute: they are the placement-1 layer (`dwReadLayer`, `dwWriteLayer`), journalled in schema 4, see "The
  original is the layer". (The first version of this change kept absolute originals and the journal at schema 3; that is what the
  foreign-placement failure above showed to be wrong.) There is no optional transaction or list-batch transform path in the tree (`SLSTransactionSetWindowTransform`,
  `SLSSetWindowTransforms` are not used), so none had to be moved.

**What the guest showed** (real TextEdit, Safari and Finder windows, build of this change, read from an ordinary process with
`SLSGetWindowTransformAtPlacement` for placements 0 and 1, `SLSGetCatenatedWindowTransform`, `SLSGetWindowBounds` and
`SLSGetScreenRectForWindow`):

- Session at zoom 0.5: the five placed windows read placement 0 = `[1,0,0,1,-x,-y]` (unchanged), placement 1 = `[2,0,0,2,..]`, and
  catenated equal to placement 0 composed with placement 1 on every one of them (the order assumed above; only a translation-only
  placement 0 was observed). After `quit-native`: placement 1 identity and catenated `[1,0,0,1,-x,-y]` on all eight windows
  (five placed, three untouched). Then `killall Dock` with Infinify not running: all eight unchanged, and the screenshot shows
  the windows where they were. (The investigation measured the unchanged build leaving three such windows at `[1,0,0,1,0,0]`
  after that step.)
- `killall Dock` during a session: six reads, the first about 1.5 s after the kill and then every 1.5 s, all show the three polled
  windows natural (placement 1 identity, catenated `[1,0,0,1,-x,-y]`, drawn at their native rectangle), not at the corner; an
  earlier read was not taken. Infinify reported "native presentation lost (no heartbeat
  was answered for a whole lease)" and was left waiting for a helper; the guest has no launch daemon, so nothing reloaded the
  payload. After `quit-native` and a manual `run-native` the same windows were placed again with the same layers.
- Ordinary acceptance points in that session: a new TextEdit window read `alpha=0.00` from its first on-screen sample (bounds
  set, 51.7 ms after the first sample) and `alpha=1.00` only at 199.8 ms, when it was already drawn at the placed rectangle
  (the 3 ms poll of `kCGWindowListOptionAll`; before that sample its bounds were 0x0 and it was off screen); a real HID title drag of
  (-300,+150) moved a window's drawn rectangle from (881,518) to (581,668), exactly that; a real right click opened the context
  menu at the drawn window (native frame (615,433), drawn at (728,797) for a click at (728,800)); real clicks on two drawn
  windows focused them in turn (TextEdit's front window and Infinify's focus both followed); `quit-native` put every window back to natural.
- `tests/native/dock-helper/Payload/DWPayloadFixtureTests.py` (51 cases) and `--native-move` pass on the guest; the cooperative host (an ordinary process
  writing its own windows) writes placement 1 as well.

**Not established.** Windows already broken by an earlier build (placement 0 = identity) are drawn natural by a session of this
build (the layer carries the difference) and restored to natural, but that is only modelled (`DWPayloadPlacementTests.m`,
`placementCases`), not run on the guest, and they return to the corner at the next Dock death: only the application's restart fixes
them. Whether the composition order holds for a placement 0 that is not a translation was not observed. While a new window
animates open (TextEdit, the first ~250 ms) the catenated read differs from placement 0 composed with placement 1 (both identity or
natural): some further placement, the application's or the window server's, contributes (measured in "The original is the layer" above). With
the catenated read this version started with, a frame in that interval read back as not applied and the shell logged "not placed ...
the set failed or read back differently" until the animation ended; the absolute read is now placement 0 composed with placement 1, which
does not see it. Other writers of placement 1 (Mission Control, Stage Manager, tiling animations) were not looked for:
placement 1 read identity on every window at rest. The in-app Dock reload path and the launch daemon, a second display, Spaces and
the owner's Mac were not exercised for this change.
