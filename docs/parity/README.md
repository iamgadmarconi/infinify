# DriftWM parity contract

The completion requirement is exact feature parity with DriftWM. This directory
tracks the gap between that requirement and Infinify's experimental app. A useful
prototype, a successful build, or a passing reducer scenario does not satisfy it.

The comparison is pinned to DriftWM
[`df3de27b26c7998e8a460cffd8a4925cbed3a322`](https://github.com/malbiruk/driftwm/tree/df3de27b26c7998e8a460cffd8a4925cbed3a322),
tag `v0.21.0`. Later upstream changes require an explicit inventory refresh; they
must not silently change the acceptance target.

## Inventory and acceptance

[`inventory.json`](inventory.json) records source action variants, input action
families, IPC requests, reference-configuration entries (including commented
defaults and examples), configurable
structure fields, protocol families and cross-cutting behavior. Source references
and hashes make omissions and drift inspectable. Reference values are examples
or documented defaults; the runtime defaults and dispatch code remain authoritative.
An inventory row is a coverage obligation, not an executable specification or a
claim that every edge case has already been enumerated.

Rows use `missing`, `implemented_unverified`, `verified`, `blocked`, or
`out_of_scope`.
`implemented_unverified` includes partial implementations with known mismatches.
Every required row must acquire an exact behavioral contract, a production-path
test, saved evidence tied to its implementation revision, and independent review
before becoming `verified`. Evidence must identify OS, architecture and relevant
hardware. No percentage or completion claim follows from counting stubbed APIs.

The user clarified on 2026-10-09 that every behavior is required for native Mac
apps. Literal Wayland/X11 client hosting and wire-protocol compatibility are
outside scope. Those inventory entries remain visible with `required: false`
and `out_of_scope`; native equivalents of platform services remain required.
A platform equivalent must preserve the specified behavior. An unsupported API
does not turn its feature into a pass.

On 2026-10-11 the owner chose the Mac's existing settings for behavior macOS
already controls, including display modes, screen lock, volume, brightness and
device settings. Infinify must respect those settings; implementing a second
set of system controls is not part of the native port. In the subsequent
67-question review and its follow-up, the owner confirmed **65 Use macOS**
answers and excluded the **two tablet display-mapping** rows. Question 18
(`protocol.image_copy_capture`) is resolved: use existing Mac display/window
capture; no dedicated live Infinify canvas feed is required.
The exact answers are recorded under `scope_decision.host_owned_review` in
the inventory. The 65 delegated rows remain visible and unverified: no duplicate
control is queued, but the decisions supply no runtime acceptance evidence.
Native capture/input suppression around the system lock, safe restoration and
correct display reconciliation remain integration obligations. Tablet pressure,
tilt, proximity and tool-cursor forwarding remain required; only display mapping
was excluded. The review does not authorize tests, fixture launches, Mac settings
changes or experiments with other applications.

The owner also excluded features without a macOS equivalent on 2026-10-11,
including the Linux backend controls, XKB keyboard model, primary selection and
touchscreen-specific input. Those 67 rows are now `out_of_scope`, with their
upstream contracts and source references retained. This supplies no acceptance
evidence. The native green button must toggle fullscreen inside the canvas;
Option-click toggles fit and uses `decoration_fit_snapped`.

## Status

The counts below are computed from [`inventory.json`](inventory.json) (date `2026-10-29`, upstream
`df3de27b`). Regenerate them with:

```sh
python3 -c "import json,collections as c;r=json.load(open('docs/parity/inventory.json'))['rows'];print(c.Counter(x['status'] for x in r),len(r))"
```

| Category | `implemented_unverified` | `missing` | `out_of_scope` | All |
| --- | ---: | ---: | ---: | ---: |
| `action_or_policy_variant` | 90 | 0 | 4 | 94 |
| `ipc` | 23 | 0 | 0 | 23 |
| `configuration_structure` | 119 | 21 | 26 | 166 |
| `reference_configuration` | 203 | 36 | 39 | 278 |
| `protocol_family` | 6 | 11 | 5 | 22 |
| `behavior` | 32 | 2 | 9 | 43 |
| **All rows** | **473** | **70** | **83** | **626** |

543 of the 626 rows are required (`required: true`); the 83 `out_of_scope` rows are
the Wayland, X11, Linux-backend and no-macOS-equivalent entries that the owner's decisions above exclude. No row
is `verified` or `blocked`. A count says nothing about completion: `implemented_unverified` includes partial
implementations with known mismatches, each recorded in the row's `implementation_note`.

The 70 `missing` rows, by family:

- display arrangement: `[[outputs]]` scale, transform, position and mode, as typed fields and as reference
  entries (8);
- trackpad and mouse device settings, as typed fields and reference entries (25);
- keyboard layout, per-window layout memory and Caps Lock (8) and the cursor size (2);
- the volume, brightness, media and Print key bindings (12) and the two four-finger swipe examples whose
  command is a Linux program (2);
- Wayland protocol families that the rows keep visible: gamma control, output power,
  output management, image capture and copy, virtual keyboard, pointer constraints, idle inhibit and notify,
  session lock, and `protocol.layer_shell` (11), plus `platform.lock` (1);
- `platform.acceptance`, the acceptance pass on the target hardware and macOS 26 (1).

On 2026-10-11 the owner chose the Mac's existing settings for behaviour macOS already controls (see the decisions
above), so most of these rows are integration and acceptance accounting that queues no duplicate control;
`protocol.layer_shell`, `protocol.pointer_constraints` and `platform.acceptance` are real gaps.

## Gaps without a row

Two gaps have no row of their own. They are recorded in the
[pointer contract](../crates/desktop/POINTER.md#differences-from-upstream), not in the inventory.

- The cursor shape cannot follow the application under the pointer.
- Popups and menus in compositor (Dock-helper) mode: what is established, and what is still open
  (tooltips, popups with no window-server parent, a popup an application places from the pointer's screen
  position, the owner's real Mac and macOS 26), is in
  [COMPOSITOR-MODE.md](../native/app/CompositorMode/COMPOSITOR-MODE.md#popups-and-menus-of-a-transformed-window-full-desktop-dock-helper).

## Drag and drop in compositor mode

`protocol.data_device` and `platform.dnd` are `implemented_unverified` for compositor mode: neither row is
`verified`. What was measured, and its limits (a press within a window's title/toolbar band cannot start a drag
at zoom below 1; file promises, Mail or Photos sources, a second display, a physical pointer and the
capture/replica desktop are not covered), is in
[NATIVE-DRAG-ROUTING.md](../native/app/CompositorMode/NATIVE-DRAG-ROUTING.md#compositor-mode-dock-helper-drag-and-drop-measured-on-2026-10-30).

## Test oracles

Executable upstream oracles are compared against Infinify's code and pinned to `df3de27b`:
`crates/canvas/tests/snap_parity.rs` runs `Scene`'s snapping against `driftwm_core::layout::{snap,cluster}`
(upstream's files); `crates/canvas/tests/stage_parity.rs` runs the stage against the upstream stage copy in
`crates/canvas/tests/upstream/stage`; `crates/desktop/tests/upstream` (navigation) and
`crates/desktop/tests/resize_upstream` (resize) extract upstream's methods verbatim. Each directory's README says
which methods are executed. The oracles check behaviour against upstream, not against a running Mac app.

## Evidence boundary

The evidence boundary stands for every row, whatever its status. The original inventory evidence consisted of
controller scenarios, own-fixture probes and scripted `msg` sessions without Screen Recording access. Performance
runs on 2026-10-12 additionally captured real animated disposable fixture windows. That does not establish
third-party acceptance or verify the inventory rows. No completion claim follows from these counts.
