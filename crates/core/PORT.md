<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# driftwm-core: port record

One platform-neutral crate holding the pure, compositor-independent parts of
DriftWM: canvas math, configuration, layout, the session store, the window
stage, and the touch gesture recogniser.

- Upstream: [malbiruk/driftwm](https://github.com/malbiruk/driftwm), crate `driftwm` 0.21.0 (tag `v0.21.0`)
- Commit: `df3de27b26c7998e8a460cffd8a4925cbed3a322` ("Bump version to v0.21.0", 2026-10-27). The
  first version of this crate was ported from `352333a8fa1b22171492d4b71a54102045c9a19d`
  (v0.19.0 plus three commits); see [Update to v0.21.0](#update-to-v0210).
- Verbatim snapshot in this repository: [`third_party/driftwm`](../../third_party/driftwm/VENDORED.md)
  at the same commit. `tools/diff-upstream.sh` compares against it by default.
- Licence: GPL-3.0-or-later, as upstream. `LICENSE` is upstream's file, unchanged.
- Assembled on 2026-10-09 with Rust 1.96.0 (`aarch64-apple-darwin`, macOS 27.2;
  clippy 0.1.96, rustfmt 1.9.0). Updated to v0.21.0 on 2026-10-29 with the same
  toolchain.

It merges two earlier ports and adds four modules:

| Part | Source |
|---|---|
| `config` (+ its `platform` stand-ins and keysym lookup) | the driftwm-config port, moved in |
| `layout`, `session` | the driftwm-layout port, moved in |
| `canvas`, `stage`, `window_ext`, `grabs::touch_recognizer`, `input::gestures` | ported here from upstream |

All upstream code is upstream's text. It was changed only where it could not
compile without the Wayland stack, plus one change inherited from the config
port: the config file lives in a directory named `infinify`. Every difference
is listed under [Deviations](#deviations), and `tools/diff-upstream.sh` prints
all of them.

One behaviour is a reimplementation instead of upstream's code: turning a key
name such as `Return` into a keysym (upstream calls libxkbcommon, a C library).
That comes from the config port and has [its own section](#keysym-name-lookup).

## Update to v0.21.0

On 2026-10-29 the owner asked for DriftWM v0.21.0 (commit
`df3de27b26c7998e8a460cffd8a4925cbed3a322`; 243 commits after the first pin,
v0.19.0 plus three). The procedure was the one the crate was made with, applied
to the changed files only: for each ported file the upstream change between the
two commits was merged into the ported text (`git merge-file`, ported text as
"ours", the old upstream file as base, the new one as "theirs", headers set
aside), conflicts were resolved by hand, the header's commit and SHA-256 were
set to the new ones, and `tools/diff-upstream.sh` confirmed that the remaining
differences are the ones in [Deviations](#deviations). Nothing was rewritten.

What upstream changed in the ported files:

| Area | Files | Change in v0.20.0 / v0.21.0 |
|---|---|---|
| defaults | `config/{mod,types,parse_helpers,defaults}.rs` | `window_placement` `auto`; `[session] restore_*` on; `[zoom] reset_on_new_window` off, `interact_min` 0.5; `[snap] corners` on, `outer_gap` 12; `decoration_resize_snapped` / `decoration_fit_snapped` on; decoration colours; blur 5 / 1.5; new default bindings (focus-nearest, move-to-snap, snapped resize and fit, `fill-window` on mod+middle, holds `focus-center`, mod+shift+q `suspend-window`, mod+e / mod+z / alt+2-finger pinch / alt+3-finger pinch removed) |
| actions | `config/{types,parse}.rs` | `Action::{FocusNearest, MoveToSnap, ResizeToSnap}`, `MouseAction::FocusNearest`, `ThresholdAction::FocusNearest`; `parse_cardinal` (the snap actions take four directions); `reject_bare_directional` |
| config file | `config/toml.rs`, `config/mod.rs` | `set_config_path` (upstream's `--config`) |
| snapping | `layout/snap.rs` | `SnapRect::inset`; the stop model (`Line`, `Family`, `Stop`, `StopQuery`, `stops`), `next_origin`, `next_grow_line`, `next_shrink_line`; `find_snap_candidate` and `find_edge_snap` rewritten over `stops` (behaviour kept); 31 tests |
| fill | `layout/fill.rs` | `fill_rect` insets its bounds with `SnapRect::inset` |
| canvas | `canvas.rs` | `minimal_reveal_camera`, `leading_edge_camera`; `closest_point_on_rect` sums in f64 |
| stage | `stage/{mod,tests}.rs` | `FitPush` and the fit-push record that a closing snapped fit uses |
| session | `session.rs` | owner-only files, position limits |
| recogniser | `grabs/touch_recognizer{,/tests}.rs` | bare 4-finger and mod+3-finger swipes name focus-nearest in the threshold tables; two tests |
| tests | `tests/config_{bindings,parse,reference,toml}_test.rs` | the new defaults and actions |
| docs, seeds | `config.reference.toml`, `docs/config.md`, `docs/window-rules.md`, `proptest-regressions/layout/snap.txt` | upstream copies; the reference config was rewritten to one line per option |

Deviations added by the update, all in the lists above: `src/window_ext.rs`
leaves out two more functions (`decoration_mode_to_kde_manager`,
`decoration_mode_to_kde`, the KDE server-decoration protocol); the line numbers
of the kept trait moved; `config::set_config_path` is ported unchanged and is
unused by Infinify. No other textual deviation was added: no new `smithay::`
path appeared in a ported file, and no `#[rustfmt::skip]` was needed.

Changed upstream but not ported, because they need the Wayland stack (the
files are outside this crate's module map): `src/region.rs` (opaque and blur
region caps), `src/desktop_entry.rs`, `src/protocols/*` (gamma and virtual
keyboard memfd checks, screencopy, image-copy-capture), `src/render/*`
(screenshot temp file, blur, TIFF), `src/state/*` and `src/input/*` (the
compositor's side of focus-nearest, move-to-snap, the hardening items). The
controller adapts the ones that have a macOS meaning; `crates/desktop/README.md`
lists what it took and what it left out. Upstream's `src/tests/*` is a
headless-compositor harness and is not part of this port, as before.

## Layout

```
Cargo.toml  Cargo.lock        self-contained package, empty [workspace] table
LICENSE                       upstream's GPL-3 text, byte-identical
SHA256SUMS                    hashes of the eight byte-identical copies
config.reference.toml         upstream copy (config tests read it)
docs/config.md                upstream copy (a test reads it)
docs/window-rules.md          upstream copy (a test reads it)
proptest-regressions/layout/fill.txt   upstream copy (saved proptest seeds)
proptest-regressions/layout/snap.txt   upstream copy (saved proptest seeds; new in v0.21.0)
proptest-regressions/stage/tests.txt   upstream copy (saved proptest seeds)
src/lib.rs                    crate root (new)
src/canvas.rs                 ported
src/config/*.rs               ported (six files)
src/layout/*.rs               ported (five files)
src/session.rs                ported
src/stage/{mod,element,mock,tests}.rs   ported
src/window_ext.rs             ported (the trait only)
src/grabs/mod.rs              new: declares touch_recognizer
src/grabs/touch_recognizer.rs, touch_recognizer/tests.rs   ported
src/input/mod.rs              new: declares gestures
src/input/gestures.rs         ported (one function)
src/shaders/dot_grid.glsl     upstream copy (`config::DEFAULT_SHADER`)
src/platform.rs               the stand-ins for Smithay/xkb types (new)
src/platform/input/keyboard/keysyms.rs   generated keysym constants and name table
tests/canvas_*_test.rs        upstream's three canvas integration tests
tests/config_*_test.rs, window_rules_test.rs   upstream's seven config integration tests
tests/snap_test.rs            upstream's snap integration test
tests/platform_keysym_test.rs, config_path_test.rs   the config port's own tests
tools/                        not built: upstream diff, port script, stand-in check,
                              keysym generator, keysym oracle
```

### Module map

Upstream is two crates in one package: the library `driftwm` (`src/lib.rs`) and
the compositor binary (`src/main.rs`), which names the library `driftwm::…`.
This crate keeps upstream's module names at the crate root so upstream's
`crate::…` paths resolve unchanged.

| Module here | Upstream | Upstream crate | Ported |
|---|---|---|---|
| `canvas` | `src/canvas.rs` | library | whole file |
| `config` | `src/config/` | library | whole module, less `applied_rule` |
| `layout` | `src/layout/` | library | whole module |
| `session` | `src/session.rs` | library | whole file |
| `stage` | `src/stage/` | library | whole module, less `impl StageElement for Window` |
| `window_ext` | `src/window_ext.rs` | library | the `WindowExt` trait only |
| `grabs::touch_recognizer` | `src/grabs/touch_recognizer.rs` (+ `/tests.rs`) | binary | whole file |
| `input::gestures` | `src/input/gestures.rs` | binary | `direction_from_vector` only |
| `platform` | none | n/a | new: stand-ins |

Not ported: the library modules `desktop_entry`, `protocols`, `text`, and
everything else in the binary crate.

Public paths keep upstream's shape: `driftwm::config::Config` is
`driftwm_core::config::Config`, `driftwm::stage::Stage` is
`driftwm_core::stage::Stage`.

## Files and upstream hashes

SHA-256 of the upstream original at the pinned commit. The same list is in
`tools/upstream.sha256`, which `tools/diff-upstream.sh` checks against a tree
(`third_party/driftwm` by default).

Ported Rust files. Each has a leading SPDX line and provenance comment; "Body"
says what `tools/diff-upstream.sh` prints for it (lines removed / added against
upstream, below the header).

| File (same path upstream) | SHA-256 of upstream original | Body |
|---|---|---|
| `src/canvas.rs` | `becd67eaef83d761141822652f8f60519051f68455608b43b8d806c0d9d23aa4` | -1 +1 |
| `src/config/mod.rs` | `ac10ef20e1d65098edbc730372124e8c15aa06ecc3c824c6ee6cb9b4be82177f` | -6 +6 |
| `src/config/types.rs` | `3a7a6be2a912c13a2a626527bd6a740e920a90de822abdc92132b7f883a15f8e` | -19 +7 |
| `src/config/parse.rs` | `4c123070660e17df07af21be03755cc000bd5b935dd716328f89b5c659ebf2cc` | -1 +1 |
| `src/config/parse_helpers.rs` | `57e32e373dae1d62e597f8903376b24dd08ace81c51198e0e886bd85778d3247` | -1 +1 |
| `src/config/toml.rs` | `6e67a2e41ba1c39a7a71fea7b340b32bfafc0ca1994af248ebdaaf39df2d024b` | -1 +4 |
| `src/config/defaults.rs` | `c2569a8d2db92dc3326238698c18b3c461dfc39835c4ae98d6b512856002dcd4` | -1 +1 |
| `src/layout/mod.rs` | `30e14c74317edb70c7d93e8a0c5e873f2a31ef518bef29eef5deb931d3d99030` | identical |
| `src/layout/snap.rs` | `66df12387a8f9fc6af09356e3c46b4263863d956d76b83ea6dcd358976f6b1ae` | identical |
| `src/layout/cluster.rs` | `4190c07d8f09cc70fdee19e1745297713f1ff8e06ab2db4337c0e316ea351a1a` | identical |
| `src/layout/auto_placement.rs` | `d99fa9d5ca4a5e9d84e6ef6d6672e6ea531186f40187d88082b63285e8999806` | identical |
| `src/layout/fill.rs` | `5f210f68f61c21606f8786b8751c8b36a232357d4ebdcda6e470868a4f1a16b3` | identical |
| `src/session.rs` | `53b1022983bcc75ccbbf628c459342e7039eec47e868a2acbbf1df58821c74df` | identical |
| `src/stage/mod.rs` | `5182313dd65f17c4ea3917ac70b01c253160273199e8b177719f60a0d95e97ad` | -1 +1 |
| `src/stage/element.rs` | `6fdfabbfc7189cc14a80014314e318203eb3e9129ef953b8fe5357a0c7f1f8aa` | -16 +1 |
| `src/stage/mock.rs` | `4b7117c342a887c3d06c94870c6032dd42d037c4bb47dc1249018d89b20ad91a` | -2 +2 |
| `src/stage/tests.rs` | `d93728e879894075547a0dff6738edcdb7fca431db3b0f1008ee28499bc52757` | -2 +5 |
| `src/window_ext.rs` | `2e8009ba4dd6fed15eebc66f51429c1dd6ebbe94f22b0747b60aaf1325851821` | -170 +2 |
| `src/grabs/touch_recognizer.rs` | `0b0bdf9229b6b581ab28c9a5425c220bf19e1d5837dab8b1763a14696c846e55` | -5 +5 |
| `src/grabs/touch_recognizer/tests.rs` | `e8e319d0de7c102b774b9529b52cdf61db0d9030ade6dfcec090584b904ecb13` | -3 +6 |
| `src/input/gestures.rs` | `6a07e9e9a620b45bd5a52aa59136887775d609d00ad94b9c53d93c89ac3323d3` | -76 +3 |
| `tests/canvas_navigation_test.rs` | `231937c6c83cb17c24ac419f575cdd4de3474c60d87d27c1cf405a1198c0becf` | -3 +3 |
| `tests/canvas_transforms_test.rs` | `6c8ec536dda510c849e8472bf4f5bdc88f371b402a810ebe3a142c58d2c6bb0f` | -6 +12 |
| `tests/canvas_zoom_test.rs` | `655b9efc5d056c2c626eea24377f5c81c38197bbf5d90c00f912b602dd8b5812` | -2 +2 |
| `tests/config_bindings_test.rs` | `181f59507b1e6aa7f095d3ba390decdcba7d22bffa8d8a3d162e6d2f1475abac` | -2 +2 |
| `tests/config_docs_test.rs` | `183fc6ff97b345a0bc2fd8cb6a5d8bf207ae8d61a44fecdac49e75eb590a00ad` | identical |
| `tests/config_parse_test.rs` | `303fbb0df3922f9039d59d05f6c576fd7f0e7282b2a1d4f257fabe1c0b2e0107` | -30 +30 |
| `tests/config_reference_test.rs` | `7aca0f3766a832a9c1ab4490aca00999d9abf8a7cc2cf621decf06234376cb86` | -1 +1 |
| `tests/config_robustness_test.rs` | `a6b4d9d2014260240f8a743e704a53e72d8d31e235ae9ba469b0bf397c52fb65` | -1 +1 |
| `tests/config_toml_test.rs` | `e489f62bb90048885ca552f4670c925c7540357c65998dd596ed458bc8121740` | -3 +3 |
| `tests/window_rules_test.rs` | `20219f894820fab07bc07a3e40f9fce6e367c1112f659d3e4042c5d06a38f684` | -17 +25 |
| `tests/snap_test.rs` | `0a0b2fa41a84c022a1fbf39f22863ff24977a22fd56795d9807e5c738db3d7f0` | -1 +1 |

32 files: 7 identical below the header, 25 with changes. Of the 32, 12 are
byte-identical between the two upstream commits (`src/layout/{mod,cluster,auto_placement}.rs`,
`src/stage/{element,mock}.rs`, `src/input/gestures.rs`, `tests/canvas_{navigation,transforms,zoom}_test.rs`,
`tests/config_{docs,robustness}_test.rs`, `tests/window_rules_test.rs`, `tests/snap_test.rs`;
their upstream hash is the same as before and only the commit in the header
changed).

Byte-identical copies, no header (`shasum -a 256 -c SHA256SUMS` verifies them):

| File (same path upstream) | SHA-256 |
|---|---|
| `config.reference.toml` | `a0e1e00eb1ce16bc797e97a1ad918af7fddef1d710fe8246e1fae55f867e4e84` |
| `docs/config.md` | `30a532929d9b06b673b234628b7d392fbe93f98093705e02de1405834e3210a4` |
| `docs/window-rules.md` | `2f69aa604ba0b060f560d656ab464323b3bf52f9e4a55a601aec277b852a7502` |
| `src/shaders/dot_grid.glsl` | `a2dde8d16cc974ab3d0192020b30c2f60da8620216952eb36fac0f72a83d5683` |
| `LICENSE` | `ff3dae1cabc80d5a2b57bc9dfb6f2ee332beaa6dce9fac53168e412de09ca70f` |
| `proptest-regressions/layout/fill.txt` | `3a48dbe099971bfcf69ecb6f5ca09d98fd93150cb00584f262dca36dae0bece1` |
| `proptest-regressions/layout/snap.txt` | `052ed99ab594e71bdadef03b8b3c33d861870db653871873889724fdd72358d6` |
| `proptest-regressions/stage/tests.txt` | `ccacd3861b6673ff007b4ccf2cdc653cc8decdb5dbb3d182b9636ae503a4bc2c` |

They carry no SPDX header on purpose: `LICENSE` is the licence text; the two
seed files are read by proptest and a header would change their hash; the docs,
the reference config and the shader are compared with each other or compiled in
by tests. Their origin is recorded here instead.

Four more files have no SPDX line, because a tool reads or writes them:
`Cargo.lock` and `tools/keysym-oracle/Cargo.lock` (generated by cargo, which
would rewrite them), and `SHA256SUMS` and `tools/upstream.sha256` (read by
`shasum -c`, which reports any other line as malformed). Every other file in
the crate starts with one.

Read but not copied:

| Upstream path | SHA-256 | Used for |
|---|---|---|
| `src/lib.rs` | `d8af65b7c94f6215075520d6c6f7e190c7e83369dce821de533942f5c0e031be` | module names and visibility |
| `src/main.rs` | `19718c9cb6ace32e42ad80e541c8a7f79b30d741231821e90fb9e47e0aaf2bdc` | how the binary declares `grabs` and `input` |
| `src/grabs/mod.rs` | `9689afdadbfab33986b89ebe5440730a7e42d32a780918e160fa9d8ef0063e41` | how it declares `touch_recognizer` |
| `src/input/mod.rs` | `641698c9333168bff6e98e29e44c7baf2f927504d43fe138ac94c635dd78bcd3` | how it declares `gestures` |
| `Cargo.toml` | `4d775f9ea7203092cead48f53b7b431881abd9377dae05012a259a03444fab28` | dependency requirements, `[lints.clippy]`, version, authors |
| `Cargo.lock` | `c52ea2dfd3b6b6075b1e2660d15b4a573a4eccc9cb89f88c0229e14a4503dfbb` | locked dependency versions |
| `clippy.toml` | `279abecace52e683fe2fdee815ef71f5e48b186cdf3d7dfa9be0ba86da4376dd` | read; not carried (see Dropped). Unchanged since the first port; the vendored snapshot leaves it out (its copy rules) |

New files with no upstream original (each says so in its own header):
`src/lib.rs`, `src/grabs/mod.rs`, `src/input/mod.rs`, `src/platform.rs`,
`src/platform/input/keyboard/keysyms.rs` (generated),
`tests/platform_keysym_test.rs`, `tests/config_path_test.rs`, `tools/*`,
`Cargo.toml`, `Cargo.lock`, `SHA256SUMS`, `.gitignore`, this file.

## Deviations

### Changes inside the ported files

Every ported file gains a leading SPDX line and provenance comment. Beyond
that, this is the complete list; `tools/diff-upstream.sh` prints the same.

| File | Change |
|---|---|
| `src/canvas.rs` | `use smithay::utils::{Logical, Point, Rectangle, Size};` reads `crate::platform::utils` |
| `src/config/mod.rs` | 4 `smithay::` imports read `crate::platform::`; `pub use toml::config_path;` reads `pub use toml::{CONFIG_DIR_NAME, config_path};`; the doc comment of `Config::load` names `infinify` where it named `driftwm` |
| `src/config/types.rs` | 3 imports and 4 inline paths `smithay::` read `crate::platform::`; `pub fn applied_rule` removed (13 lines) |
| `src/config/parse.rs`, `parse_helpers.rs`, `defaults.rs` | one `smithay::` import each reads `crate::platform::` |
| `src/config/toml.rs` | new `pub const CONFIG_DIR_NAME: &str = "infinify";`, and `config_path` joins `format!("{CONFIG_DIR_NAME}/config.toml")` where upstream joins `"driftwm/config.toml"` |
| `src/layout/*`, `src/session.rs` | none |
| `src/stage/mod.rs` | `use smithay::utils::{Logical, Point, Size};` reads `crate::platform::utils` |
| `src/stage/element.rs` | `impl StageElement for Window` removed (upstream lines 20-34) with the three imports only it used; the remaining import reads `crate::platform::utils::{Logical, Size}`. The trait is unmodified |
| `src/stage/mock.rs` | 2 `smithay::` imports read `crate::platform::` |
| `src/stage/tests.rs` | 2 `smithay::utils` imports read `crate::platform::utils`; one `#[rustfmt::skip]` with a two-line comment on `use proptest::prelude::*;` in `mod harness` |
| `src/window_ext.rs` | only the `WindowExt` trait is kept (upstream lines 67-90, unmodified); 2 imports read `crate::platform::`; the rest is removed (see Removed) |
| `src/grabs/touch_recognizer.rs` | 2 imports `smithay::` read `crate::platform::`; `driftwm::config` reads `crate::config` in 1 import and 2 inline paths in `swipe_threshold_for` |
| `src/grabs/touch_recognizer/tests.rs` | 2 imports `smithay::` read `crate::platform::`; 1 import `driftwm::config` reads `crate::config`; one `#[rustfmt::skip]` with a two-line comment on `use proptest::prelude::*;` |
| `src/input/gestures.rs` | an extract: `direction_from_vector` only (upstream lines 86-113, body unmodified), `pub(crate)` widened to `pub`; imports reduced to `crate::platform::utils::{Logical, Point}` and `crate::config::Direction`; lines 1-85 removed (see Removed) |
| `tests/canvas_navigation_test.rs` | 2 imports `driftwm::` read `driftwm_core::`; 1 import `smithay::` reads `driftwm_core::platform::` |
| `tests/canvas_transforms_test.rs` | 1 import `driftwm::` reads `driftwm_core::`; 1 import and 4 inline type paths `smithay::` read `driftwm_core::platform::`; two `#[rustfmt::skip]`, each with a two-line comment, on the `let delta_canvas…` statements |
| `tests/canvas_zoom_test.rs` | 1 import `driftwm::` reads `driftwm_core::`; 1 import `smithay::` reads `driftwm_core::platform::` |
| seven config test files | `driftwm::config` reads `driftwm_core::config`; `smithay::` reads `driftwm_core::platform::` |
| `tests/window_rules_test.rs` | also: four `let combo = …Keysym::from(…KEY_q);` statements are wrapped over three lines (inherited from the config port, see rustfmt below) |
| `tests/config_docs_test.rs` | none |
| `tests/snap_test.rs` | `use driftwm::layout::snap::*;` reads `use driftwm_core::layout::snap::*;` |

### Removed (left out)

Items of ported files that are not here, and why.

| Item | Upstream location | Why |
|---|---|---|
| `config::applied_rule` | `src/config/types.rs` | reads an `AppliedWindowRule` out of a `wl_surface`'s Smithay data map. Nothing in the ported modules or tests calls it. `AppliedWindowRule` and everything that builds one are kept |
| `impl StageElement for Window` | `src/stage/element.rs` 20-34 | implements the trait for Smithay's Wayland window. The native window type implements `StageElement` in the backend crate instead |
| `impl WindowExt for Window` | `src/window_ext.rs` 92-211 | reads and writes xdg-toplevel state of a Smithay window |
| `decoration_mode_to_kde_manager`, `decoration_mode_to_kde` (new in v0.21.0) | `src/window_ext.rs` 45-65 | map `config::DecorationMode` to the `org_kde_kwin_server_decoration` Wayland enums (`Client` → `Client`, anything else → `Server`) for the KDE server-decoration protocol, which only a Wayland client speaks. There is no macOS counterpart (see the controller docs) |
| `set_tiled_states`, `unset_tiled_states` | `src/window_ext.rs` 6-32 | take a Smithay `ToplevelSurface` and set xdg-toplevel `Tiled*` states |
| `decoration_mode_to_wire` | `src/window_ext.rs` 34-43 | maps `config::DecorationMode` to the xdg-decoration wire enum (`Client` → `ClientSide`, anything else → `ServerSide`). The mapping is pure but its return type is a Wayland protocol type |
| submodules `device_config`, `hold`, `pinch`, `swipe` | `src/input/gestures.rs` 1-4 | libinput pointer-gesture handling on compositor state |
| `enum GestureState` | `src/input/gestures.rs` 13-48 | state of a pointer (trackpad) gesture. It is pure data, but nothing ported uses it and the brief asked for the one helper |
| `DOUBLE_TAP_WINDOW_MS` (`= 300`) | `src/input/gestures.rs` 50 | used by `src/input/pointer.rs` and `src/state/navigation.rs`, not by anything ported; unused here it would be dead code |
| `impl DriftWm { gesture_camera_zoom, gesture_output_or_active, gesture_output_fullscreen, cancel_animations }` | `src/input/gestures.rs` 52-84 | methods of the compositor state |

`window_ext` therefore holds no helper function: all three free functions in
upstream's file touch Wayland protocol types.

Nothing else in the public or private API of a ported file was removed.

### Changed behaviour: config file location

Inherited from the config port, unchanged here. `config_path()` keeps
upstream's precedence:

0. (v0.21.0) the path `config::set_config_path` was given, held in-process so
   children do not inherit it (upstream's `--config`). Ported verbatim; the
   Infinify shell reads its own `--config` and does not call it.
1. `$DRIFTWM_CONFIG`, if set, with a leading `~/` expanded.
2. `$XDG_CONFIG_HOME/infinify/config.toml`.
3. `$HOME/.config/infinify/config.toml`.
4. `./.config/infinify/config.toml` when `HOME` is unset.

Only the directory name differs from upstream, and it is the single constant
`config::CONFIG_DIR_NAME` (`toml.rs` now carries it above `CONFIG_PATH_OVERRIDE`). The override variable is still named
`DRIFTWM_CONFIG`; whether it should become `INFINIFY_CONFIG` is an open
decision.

### Added

- `config::CONFIG_DIR_NAME` (above).
- `platform`, the stand-in module (next section).
- `platform::input::keyboard::keysyms` holds a `KEY_*` constant for all 2,576
  names in its table. Upstream's `keysyms` module (xkbcommon 0.9.0) has 2,402 of
  them, each with the same value here. The other 174 are names newer libxkbcommon
  releases know. `tools/gen_keysyms.py` checks both statements when it runs.
- The config port's own tests: `tests/platform_keysym_test.rs` (8),
  `tests/config_path_test.rs` (1), and two table-invariant unit tests in
  `platform::input::keyboard::xkb`.
- Four `#[rustfmt::skip]` attributes with comments (rustfmt below).

No config option, action, gesture, key-code mapping or macOS-specific item was
added. No test was added for the new modules: upstream's own tests are the
tests.

### Visibility widened

Each widening is there because the native backend is another crate.

| Item | Upstream | Here |
|---|---|---|
| `input::gestures::direction_from_vector` | `pub(crate) fn` | `pub fn`. Upstream also calls it from `src/input/gestures/swipe.rs` (pointer swipe) and `src/grabs/navigate_grab.rs`, both in the binary crate, so a backend needs it too |
| module `grabs` | `mod grabs;` in `src/main.rs` | `pub mod grabs;` |
| module `grabs::touch_recognizer` | `mod touch_recognizer;` in `src/grabs/mod.rs` | `pub mod touch_recognizer;` |
| module `input` | `mod input;` in `src/main.rs` | `pub mod input;` |
| module `input::gestures` | `pub(crate) mod gestures;` in `src/input/mod.rs` | `pub mod gestures;` |

Nothing inside `touch_recognizer.rs` was widened. Upstream already declares
`Plan`, `TouchInput`, `TouchKind`, `Decision`, `TapOutcome`, `TouchRecognizer`
and `TouchRecognizer::{new, finger_count, screen_pos, centroid, process}` as
`pub`; `Plan`'s fields and the other methods stay private.

Not widened, although a backend might want them:

- `stage::mock` (`TestWindow`, `SentConfigure`) stays `#[cfg(test)]` and private
  to the crate, as upstream. Another crate cannot reuse the mock for its tests.
- `stage::element` stays a private module with `pub use element::StageElement`,
  as upstream.
- `TouchRecognizer::deadline_elapsed` stays `#[cfg(test)]`.

### rustfmt

`cargo fmt -- --check` passes with rustfmt's defaults. There is no
`rustfmt.toml` (upstream has none either).

Upstream's files are rustfmt-clean under this toolchain
(`rustfmt --edition 2024 --check` on the originals prints nothing), so the
formatting of the ported files is upstream's. Changing a path prefix made
rustfmt want a different layout in eight places:

| Where | What rustfmt wanted | What was done |
|---|---|---|
| `src/stage/tests.rs`, `mod harness` | move `use crate::platform::utils::…;` above `use proptest::prelude::*;` (it sorts `crate::` paths first; upstream's `smithay::` sorted after `proptest::`) | `#[rustfmt::skip]` on `use proptest::prelude::*;`, upstream's order kept |
| `src/grabs/touch_recognizer/tests.rs`, top | the same, for two `crate::platform` imports | `#[rustfmt::skip]` on `use proptest::prelude::*;`, upstream's order kept |
| `tests/canvas_transforms_test.rs`, two `let delta_canvas: Point<f64, …Logical> = Point::from(…);` | wrap the statement: the longer path makes it 101 and 103 columns | `#[rustfmt::skip]` on each statement, upstream's single line kept |
| `tests/window_rules_test.rs`, four `let combo = …Keysym::from(…KEY_q);` | wrap the statement | wrapped by rustfmt. This is the config port's choice, kept as moved; the statements still need the wrap with the `driftwm_core` name |

So two ways of handling the same problem coexist: the four statements that came
with the config port are re-wrapped, the four sites ported here carry a skip.
Each skip is one attribute plus a two-line comment that starts `// driftwm-core:`.
Attributes were chosen over a `rustfmt.toml` so the files stay correct under any
rustfmt configuration of a workspace this crate may join.

### clippy

`cargo clippy --all-targets -- -D warnings` passes. No `#[allow]` was added.
Allows present in the crate: upstream's own
`#[allow(clippy::too_many_arguments)]` on `TouchRecognizer::down`, and
`#![allow(non_upper_case_globals)]` on the generated `keysyms` module (as
upstream's xkbcommon module has). `[lints.clippy]
significant_drop_in_scrutinee = "warn"` is carried over from upstream's
`Cargo.toml` and applies to the whole crate; it does not fire.

### Dropped upstream configuration

- `clippy.toml` (`disallowed-methods`): every entry names a Smithay path
  (`smithay::desktop::space::Space::*`, `Window::bbox`,
  `with_pointer_constraint`). None can occur here.
- `[profile.*]` settings (insta/similar opt-level, release LTO) and the Tracy
  features: they concern crates or build modes outside this port.
- Upstream's dev-dependencies other than `proptest` (`insta`, the Wayland
  client crates): used by tests of modules outside this port.

### What changed against the two earlier ports

"Moved in unchanged" holds with these exceptions, all forced by the merge:

| What | Change |
|---|---|
| crate name in tests | `driftwm_config::` and `driftwm_layout::` read `driftwm_core::` (code and the header comments that quote the paths) |
| `src/config/mod.rs` | `crate::platform::canvas::MAX_ZOOM` is `crate::canvas::MAX_ZOOM` again, as upstream: the real `canvas` module is here. Its header says so. This removes a deviation the config port had |
| `src/platform.rs` | `platform::canvas` (the `MAX_ZOOM` stand-in) removed; `TouchSlot`, `Coordinate`, `Size`, `Rectangle`, `WlSurface` added; `Point` gained `Add`, `Sub`, `AddAssign`, `Default`, `to_f64`; header rewritten |
| `src/lib.rs` | replaced by this crate's root |
| `Cargo.toml` | new. `serde_json` is a normal dependency (it was one in the layout port and a dev-dependency in the config port); `[lints.clippy]` now also covers `layout` and `session`, which the layout port built without it |
| `Cargo.lock` | the config port's lock with the root package renamed; no third-party entry changed |
| `SHA256SUMS` | two seed files added |
| `tools/diff-upstream.sh` | rewritten to cover all 32 files |
| `tools/keysym-oracle` | depends on `driftwm-core`; its `Cargo.lock` was updated by cargo for that; its `Cargo.toml` gained an SPDX line |
| `.gitignore` | gained an SPDX line |
| headers | kept as they were. Two styles therefore coexist: the config port's (three or more `//` lines, no blank line after) and the layout port's (fields for repository, commit, path and SHA-256, then a blank line). The files ported here use the second |

Everything else from the two ports is byte-identical to what they delivered
(checked with `cmp` file by file).

## The `platform` stand-ins

`src/platform.rs` mirrors the upstream paths, so ported code differs only by
the path prefix (`smithay::` → `crate::platform::`). It provides what the ported
modules and their tests name, no more.

Type shapes were taken from the Smithay 0.7.0 release on crates.io (git
`a166cf4c94b5aedc332a65aa1dd753e8148829c3`). Upstream locks Smithay at git
revision `4cf0b62028039661477d482ec4758b687d8f4392`, also versioned 0.7.0. That
revision was not fetched, so the comparison is against the release, not the
exact locked revision.

| Stand-in | Upstream item | Kept | Left out or different |
|---|---|---|---|
| `platform::backend::input::AxisSource` | `smithay::backend::input::AxisSource` | variants `Finger`, `Continuous`, `Wheel`, `WheelTilt`; derives `Debug, PartialEq, Eq, Clone, Copy` | nothing |
| `platform::backend::input::TouchSlot` (new) | `smithay::backend::input::TouchSlot` | private field `id: Option<u32>`; derives `Default, Debug, Clone, Copy, PartialEq, Eq, Hash`; `From<Option<u32>>`; `From<TouchSlot> for i32` (`-1` for `None`). Smithay's text | nothing |
| `platform::input::keyboard::Keysym` | `smithay::input::keyboard::Keysym` | it is the same type: both are `xkeysym::Keysym` 0.2.1 | nothing |
| `platform::input::keyboard::ModifiersState` | `smithay::input::keyboard::ModifiersState` | the eight `bool` fields; derives `Copy, Clone, Debug, Default, PartialEq, Eq, Hash` | field `serialized: SerializedMods` (the `wl_keyboard` wire form) and the methods that read an xkb state |
| `platform::input::keyboard::keysyms` | `smithay::input::keyboard::keysyms` (`xkbcommon::xkb::keysyms`) | `KEY_<name>: u32` constants, same names and values | 174 more constants than upstream's module; see Added |
| `platform::input::keyboard::xkb` | `smithay::input::keyboard::xkb` (`xkbcommon::xkb`) | `keysym_from_name`, `KeysymFlags`, `KEYSYM_NO_FLAGS`, `KEYSYM_CASE_INSENSITIVE` | everything else in `xkb`; `keysym_from_name` is a reimplementation, see below |
| `platform::utils::Logical` | `smithay::utils::Logical` | unit marker, `Debug` | nothing |
| `platform::utils::Coordinate` (new) | `smithay::utils::Coordinate` | the supertraits; `to_f64`, `non_negative`, `saturating_add`, `saturating_sub` | `ZERO`, `downscale`, `upscale`, `from_f64`, `min`, `max`, `abs`, `saturating_mul`. Implemented for `i32` and `f64` only (Smithay: every integer and float type), so the arithmetic, `to_f64` and the `Size` constructors exist for those two; a ported use of another coordinate type would fail to compile, and none does |
| `platform::utils::Point<N, Kind>` (extended) | `smithay::utils::Point` | `x`, `y`, `new`, `to_f64`, `From<(N, N)>`, `Add`, `Sub`, `AddAssign`, `Clone`, `Copy`, `PartialEq`, `Default`, `Debug`. Smithay's text | `SubAssign`, `Eq`, `From<Point> for (N, N)`, `Add`/`Sub` of a `Size`, `to_size`, scaling, `constrain`, rounding (`to_i32_round` …), coordinate-space conversions |
| `platform::utils::Size<N, Kind>` (new) | `smithay::utils::Size` | `w`, `h`, `new` with its `debug_assert!`, `to_f64`, `From<(N, N)>`, `Clone`, `Copy`, `PartialEq`, `Default`, `Debug`. Smithay's text | arithmetic, `Eq`, `From<Size> for (N, N)`, `to_point`, `clamp`, `is_empty`, scaling, rounding, coordinate-space conversions |
| `platform::utils::Rectangle<N, Kind>` (new) | `smithay::utils::Rectangle` | `loc`, `size`, `new`, `to_f64`, `Clone`, `Copy`, `PartialEq`, `Debug`. Smithay's text | `Eq`, `Default`, the other constructors, `contains`, `overlaps`, `intersection`, `merge`, `subtract_*`, scaling, rounding, coordinate-space conversions |
| `platform::utils::Transform` | `smithay::utils::Transform` | the eight variants; derives `Debug, PartialEq, Eq, Hash, Clone, Copy, Default` | all methods |
| `platform::reexports::wayland_server::protocol::wl_surface::WlSurface` (new) | the `wayland-server` type of that path | the name; derives `Debug, Clone, PartialEq, Eq, Hash` (the traits the generated type implements) | it is an empty enum: it has no values. See below |

Points that affect behaviour, all as in Smithay:

- `Point` addition and subtraction saturate for `i32` (`saturating_add`,
  `saturating_sub`) and are plain `+`/`-` for `f64`.
- `Size::new`, and so `Size::from((w, h))`, has
  `debug_assert!(w.non_negative() && h.non_negative(), …)`: a negative size
  panics in debug builds, including under `cargo test`, and passes in release.
- `Debug` prints the marker's type path, so `{:?}` shows
  `Point<driftwm_core::platform::utils::Logical>` where upstream shows
  Smithay's path. No ported test compares that text.

`tools/check-standins.py <smithay-0.7.0>` compares each item of
`platform::utils` and `TouchSlot` with Smithay's source, ignoring comments and
whitespace: 31 of 36 items occur there character for character. The five that
do not are the reduced `Coordinate` trait and its two impls, `Rectangle::new`
(the same function, alone in its impl block here), and `Transform` (one derive
attribute here, two there).

**`WlSurface`.** Upstream names the type in one ported signature,
`WindowExt::parent_surface(&self) -> Option<WlSurface>`, and nothing ported
builds or reads one: upstream's test mock returns `None`. The stand-in is an
empty enum, so `Option<WlSurface>` can only be `None` and an implementation off
Wayland cannot pretend to hold a surface. The stage does not use
`parent_surface`; it asks `StageElement::is_child_of`, which upstream's
`Window` impl answered by comparing `parent_surface()` with the parent's
surface. A native implementation answers `is_child_of` directly. If a backend
needs `parent_surface` to carry a real handle, this stand-in is the thing to
change.

No libinput type is shimmed. The config module's `AccelProfile`, `SendEvents`
and `click_method` are upstream's own types.

## Keysym name lookup

This section is the config port's record. Nothing in it changed here. What was
re-run for this crate is marked.

**What upstream does.** `parse_key_combo` calls
`xkb::keysym_from_name(name, xkb::KEYSYM_CASE_INSENSITIVE)`. That is the
xkbcommon 0.9.0 binding, which calls C `xkb_keysym_from_name` in whichever
libxkbcommon is installed on the user's machine. Upstream does not pin the C
library's version.

**What this crate does.** `platform::input::keyboard::xkb::keysym_from_name`
has the same signature and reimplements the lookup in Rust, following
libxkbcommon 1.7.0. `xkeysym` supplies the `Keysym` type and the data, but it
has no name lookup.

**What was consulted, and what was not.**

- xkbcommon 0.9.0 (`src/xkb/mod.rs`, `src/xkb/keysyms.rs`): the binding upstream
  compiles against. Read for the wrapper's behaviour and its `KEY_*` list.
- xkbcommon-rs 0.1.2: a Rust port of libxkbcommon 1.7.0. Read for the algorithm
  and its name table, and run as an oracle (below).
- xkeysym 0.2.1: source of the names and values.
- **The libxkbcommon C source was not read and the C library was not run.**
  "Follows libxkbcommon 1.7.0" therefore means: as ported by xkbcommon-rs 0.1.2
  and as documented by the binding.

**Rules implemented**, in order:

1. Unknown bits in `flags` give `NoSymbol`.
2. Table lookup. Exact case without the flag. With `KEYSYM_CASE_INSENSITIVE`,
   ASCII letters fold and, where several names differ only by case, the last one
   in table order is returned. The table is ordered by folded name, then by
   name, so that is the lower-case spelling: `Q` and `q` both give `KEY_q`.
3. `U<hex>` (also `u<hex>` with the flag), one to eight hex digits: a Unicode
   code point. Below `0x20` and `0x7f`–`0x9f` give `NoSymbol`; up to `0xff` the
   value itself; above `0x10ffff` `NoSymbol`; otherwise `value | 0x01000000`.
   A name starting with `U`/`u` that fails this parse is `NoSymbol`.
4. `0x<hex>` (also `0X` with the flag), one to eight hex digits: the raw value,
   `NoSymbol` above `0x1fffffff`.
5. A name starting with `XF86_` (any case with the flag) is looked up again
   without the underscore.
6. Otherwise `NoSymbol`, which `parse_key_combo` reports as
   `unknown keysym: <name>`.

**The name table.** The parity target is the table libxkbcommon consults at run
time, not the `KEY_*` constants upstream compiles against. 2,576 names, 2,446
distinct values, generated by `tools/gen_keysyms.py` from xkeysym 0.2.1, whose
constants carry the X.Org header macro names; libxkbcommon's own header rule
turns those into its names (`XK_Return` → `Return`, `XF86XK_AudioMute` →
`XF86AudioMute`). One name, `hpYdiaeresis`, is absent from xkeysym and taken
from xkbcommon 0.9.0.

Checks the generator makes on every run:

- All 2,402 names in xkbcommon 0.9.0 are present with equal values.
- The table equals xkbcommon-rs 0.1.2's table (2,575 names) plus `hpYdiaeresis`.

*Re-run here:* the generator, on the same three inputs, writes a file
byte-identical to the committed `keysyms.rs`.

Generator inputs (SHA-256, re-checked here):

| Input | SHA-256 |
|---|---|
| `xkeysym-0.2.1/src/automatically_generated.rs` | `3a7126cd6dffccb2857f39801c0aa615aab572bce5cc07ab34fd1e3c88945ee1` |
| `xkbcommon-0.9.0/src/xkb/keysyms.rs` | `657eae53339075091e62cc33263ca56b8d7f0d6ca186e228da496c3b54d6c8a5` |
| `xkbcommon-rs-0.1.2/src/keysyms_generated_phf.rs` | `268f7699327eda364349b66c442b620c5bbbe7e0a1c89957f957ce5223d76169` |

**Where it differs from upstream, or may.**

1. *A NUL in a key name.* Upstream panics: the binding does
   `CString::new(name).unwrap()` (xkbcommon 0.9.0 `src/xkb/mod.rs` line 334).
   Here the name is not a keysym and the binding is reported as
   `unknown keysym`. A TOML key can contain `\u0000`
   (`tests/platform_keysym_test.rs` feeds one through
   `Config::from_toml_collect` and gets a warning). That upstream panics on the
   same file follows from reading the binding; it was not observed, since
   upstream cannot be built here. This is the one deliberate behaviour
   difference in the lookup, and it was a choice of the config port: compiling
   did not force it. Its reasons: the panic lives in the binding, not in
   upstream's module, and upstream's `config_robustness_test` states the
   contract the other way ("`Config::from_toml_collect` must never panic").
   Reproducing the panic would be a one-line change in
   `platform::input::keyboard::xkb::keysym_from_name`.
2. *libxkbcommon version.* Upstream's result depends on the installed C
   library; this crate's does not. A name added to libxkbcommon after 1.7.0 is
   unknown here. A system with a libxkbcommon older than the table rejects names
   this crate accepts. Releases other than 1.7.0 were not examined.
3. *Names that differ only by case but are not one letter in two cases.* There
   are 340 groups of names equal ignoring case. For the letter pairs the
   documented contract applies (lower case wins). These 19 groups are different
   keys that happen to share a spelling, and the result is whatever the table
   order gives, which is the lower-case spelling:

   | Written as any of | Resolves to |
   |---|---|
   | `dead_A`/`dead_a`, and likewise `E`, `I`, `O`, `U`, `SCHWA` | `dead_a` etc. |
   | `kana_A`/`kana_a`, and likewise `E`, `I`, `O`, `U`, `TSU`, `TU`, `YA`, `YO`, `YU` | `kana_a` etc. (the small kana) |
   | `CH`/`Ch`/`ch` | `ch` |
   | `C_H`/`C_h`/`c_h` | `c_h` |
   | `XF86ScreenSaver`/`XF86Screensaver` | `XF86Screensaver` (`0x10081245`), not `XF86ScreenSaver` (`0x1008ff2d`) |

   xkbcommon-rs gives the same answers. Whether C libxkbcommon 1.7.0 does was
   not checked against C.
4. *Non-ASCII input.* Only ASCII letters fold. A name with a non-ASCII
   character never matches a table name. This is how a byte-wise C comparison
   behaves; it was not checked against the C source.

**The oracle run.** `tools/keysym-oracle` compares this crate's lookup with
xkbcommon-rs 0.1.2's on 421,719 inputs, each with and without the
case-insensitive flag (843,438 lookups): every table name in five spellings,
near misses, legacy `XF86_` spellings, 91 hand-picked numeric and malformed
forms, 300,000 random identifiers and 100,000 random numeric forms.

*Re-run here* against `driftwm-core`: 12 disagreements, the same twelve the
config port recorded, all explained.

- 9 are `hpYdiaeresis` in various spellings: xkbcommon-rs's table lacks the
  name; xkbcommon 0.9.0's has it. This is a gap in the oracle.
- 1 is `"K"` (U+212A KELVIN SIGN) with the flag: xkbcommon-rs lower-cases with
  Unicode rules and answers `k`; this crate answers `NoSymbol`.
- 2 are `"XF86é"` and `"日本語"` with the flag: xkbcommon-rs panics slicing a
  string off a character boundary; this crate answers `NoSymbol`.

The oracle is a port of the C library, not the C library. Agreement with it is
evidence for parity with libxkbcommon 1.7.0, not proof.

## Kept as upstream although tied to Linux or Wayland

Not deviations. Listed because a macOS consumer has to decide what they mean.

- `WindowExt` is xdg-shell vocabulary: `enter_fullscreen_configure`,
  `exit_fullscreen_configure`, `enter_fit_configure`, `exit_fit_configure`
  (upstream sends an xdg-toplevel configure and the client answers with a
  commit), `wants_ssd` ("always false": negotiated through xdg-decoration),
  `is_modal` (xdg-dialog-v1), `parent_surface` (see `WlSurface` above),
  `app_id_or_class`. A native implementation has to give each a meaning.
- The stage records decisions and never touches protocol state; its doc
  comments still describe the callers as `DriftWm` methods and compare its
  behaviour with Smithay's `Space`. The text is upstream's.
- `TouchRecognizer` takes screen-space positions in logical pixels, event times
  as `u32` milliseconds and a `px_per_mm` density, and identifies fingers by
  `TouchSlot` (libinput's multi-touch slot). `Decision` names what the
  compositor adapter did with each event (`Forward` to the app, `Hold`,
  `CancelAppSequence`, …); the adapter is not ported.
- `canvas::VelocityTracker` and `MomentumState` document their timestamps as
  libinput event times in milliseconds.
- `Config::child_env` is still built from `TOOLKIT_DEFAULTS`
  (`MOZ_ENABLE_WAYLAND`, `QT_QPA_PLATFORM`, `SDL_VIDEODRIVER`, `GDK_BACKEND`,
  `ELECTRON_OZONE_PLATFORM_HINT`) and `XCURSOR_THEME`/`XCURSOR_SIZE`.
- `[xwayland]`, `[backend]` (DRM options), `[input.keyboard]` xkb layout
  strings, `[input.trackpad]` `click_method`, `[[outputs]]` connector names and
  transforms all parse and default exactly as upstream.
- `BTN_LEFT`/`BTN_RIGHT`/`BTN_MIDDLE` are the Linux evdev codes
  (`0x110`–`0x112`). Keysyms are X11/xkb keysym values.
- `DEFAULT_SHADER` is upstream's GLSL ES source.
- `ModifiersState::iso_level5_shift` is the `mod3` modifier, as in Smithay.
- `session::default_session_path()` is upstream's:
  `$XDG_STATE_HOME/driftwm/session.json`, else
  `$HOME/.local/state/driftwm/session.json`. **The directory is still named
  `driftwm`**, while the config directory is `infinify`. The layout port moved
  `session.rs` byte for byte and this merge kept it so; `read` and `write` take
  the path as an argument, so a caller can pass its own. Whether the default
  should follow the config directory is an open decision.
- `config.reference.toml`, `docs/config.md` and `docs/window-rules.md` are
  upstream's text. They say `~/.config/driftwm/config.toml`, `driftwm
  --check-config` and `driftwm msg …`. They are byte-identical because tests
  compare them with each other and with the compiled-in defaults. **The path
  they name is not the path this crate reads** (`…/infinify/config.toml`).

## Dependencies

Requirements are upstream's for the crates the ported modules use.
`Cargo.lock` has 61 third-party packages, each at a version upstream's
`Cargo.lock` has for it (checked by script against upstream's lock).

| Crate | Requirement | Locked | Role |
|---|---|---|---|
| `serde` | `1`, feature `derive` | 1.0.228 | raw config structs, session envelope |
| `serde_json` | `1` | 1.0.149 | `session.rs` reads and writes `session.json`; one embedded config test |
| `toml` | `0.8` | 0.8.23 | TOML parser and its error text |
| `regex` | `1` | 1.12.3 | window-rule `/…/` patterns |
| `tracing` | `0.1` | 0.1.44 | upstream's `info!`/`warn!`/`error!`/`debug!` calls, unchanged |
| `xkeysym` | `0.2.1` | 0.2.1 | the `Keysym` type; upstream gets it through smithay → xkbcommon |
| `proptest` (dev) | `1` | 1.11.0 | property tests in `layout::fill`, `stage`, the touch recogniser, `tests/config_robustness_test.rs` |

All pure Rust. No Smithay, no Wayland crate, no C library, no build script, no
system dependency. `proptest` pulls `libc`/`rustix` (through `tempfile`,
`rusty-fork`, `getrandom`) into the dev tree only.

If this crate becomes a member of another workspace, that workspace's lockfile
decides the versions, not this one, and the empty `[workspace]` table has to go.

## Tests

### Upstream tests

All of them were brought over. None was dropped, ignored or altered beyond the
path prefixes and the four `#[rustfmt::skip]` attributes above.

| File | Upstream `#[test]` | Here | Passed |
|---|---|---|---|
| `src/canvas.rs` | 51 | 51 | 51 |
| `src/config/mod.rs` | 87 | 87 | 87 |
| `src/config/types.rs` | 7 | 7 | 7 |
| `src/config/parse.rs` | 9 | 9 | 9 |
| `src/config/parse_helpers.rs` | 20 | 20 | 20 |
| `src/layout/auto_placement.rs` | 18 | 18 | 18 |
| `src/layout/cluster.rs` | 35 | 35 | 35 |
| `src/layout/fill.rs` | 28 (3 proptest) | 28 | 28 |
| `src/layout/snap.rs` | 31 (1 `proptest!` block) | 31 | 31 |
| `src/session.rs` | 13 | 13 | 13 |
| `src/stage/tests.rs` | 38 (2 proptest) | 38 | 38 |
| `src/grabs/touch_recognizer/tests.rs` | 32 (6 proptest) | 32 | 32 |
| `tests/canvas_navigation_test.rs` | 25 | 25 | 25 |
| `tests/canvas_transforms_test.rs` | 30 | 30 | 30 |
| `tests/canvas_zoom_test.rs` | 25 | 25 | 25 |
| `tests/config_bindings_test.rs` | 25 | 25 | 25 |
| `tests/config_docs_test.rs` | 1 | 1 | 1 |
| `tests/config_parse_test.rs` | 81 | 81 | 81 |
| `tests/config_reference_test.rs` | 10 | 10 | 10 |
| `tests/config_robustness_test.rs` | 3 (proptest) | 3 | 3 |
| `tests/config_toml_test.rs` | 57 | 57 | 57 |
| `tests/snap_test.rs` | 18 | 18 | 18 |
| `tests/window_rules_test.rs` | 79 | 79 | 79 |
| **Total** | **723** | **723** | **723** |

Upstream tests dropped: **none**. Ignored: none.

The counts are `#[test]` attributes in the upstream file and in the ported file
(equal for every file), and the "passed" column is the test harness's count per
module. `src/stage/mod.rs`, `mock.rs`, `element.rs`, `src/window_ext.rs`,
`src/grabs/touch_recognizer.rs` and `src/input/gestures.rs` have no embedded
tests upstream (`src/layout/snap.rs` has 31 since v0.21.0, with the keyboard
stops it gained). Upstream has no test of its own for
`direction_from_vector`; the recogniser's tests reach it through navigate
swipes.

Upstream's binary crate also has `src/tests/` (a headless-compositor harness
with Wayland clients). It tests the compositor, needs the Wayland stack and is
not part of this port.

### Saved proptest cases

proptest looks for saved failure seeds next to the source root, at the test
file's path under `proptest-regressions/`.

| Seed file | For | Upstream has it | Here |
|---|---|---|---|
| `proptest-regressions/layout/fill.txt` | `src/layout/fill.rs` | yes, 1 seed | byte-identical copy |
| `proptest-regressions/layout/snap.txt` | `src/layout/snap.rs` | yes, new in v0.21.0 | byte-identical copy |
| `proptest-regressions/stage/tests.txt` | `src/stage/tests.rs` | yes, 8 seeds | byte-identical copy |
| `proptest-regressions/grabs/touch_recognizer/tests.txt` | `src/grabs/touch_recognizer/tests.rs` | no | none |

That proptest reads exactly these three paths (the 0.19 layout; `layout/snap.txt` is the fourth, found by the same rule and not probed separately) was observed: in a scratch copy
of the crate an unparsable line was appended to each (and written to the third),
and the test run reported `proptest: …/proptest-regressions/stage/tests.txt:15:
unparsable line, ignoring`, and likewise `layout/fill.txt:8` and
`grabs/touch_recognizer/tests.txt:1`. The scratch copy was deleted.

A seed replays the case upstream saved only while the strategy and proptest
agree with upstream's. Both do: the strategies are upstream's text and proptest
is 1.11.0 in both lockfiles. `cargo test` created no new seed file, which it
would have on a property failure.

### This port's tests

| File | Tests | Covers |
|---|---|---|
| `tests/platform_keysym_test.rs` | 8 | key names through `parse_key_combo`, `[keybindings]` and `pass_keys`: case, aliases, `XF86_`, numeric forms, rejected names including NUL |
| `tests/config_path_test.rs` | 1 | the four-step location precedence with the `infinify` directory |
| `src/platform.rs` (`xkb::tests`) | 2 | the name table is in the order the lookup needs; every name resolves in exact, lower and upper case |

All eleven come from the config port. The stand-ins added here (`TouchSlot`,
`Coordinate`, `Size`, `Rectangle`, the `Point` arithmetic, `WlSurface`) have no
test of their own. They are Smithay's code (`tools/check-standins.py`) and are
exercised by upstream's canvas, stage and recogniser tests, but three of their
behaviours are reached by no test: `i32` saturation at the numeric bounds, the
negative-size `debug_assert!`, and `i32::from(TouchSlot)` for a slot-less
device (`-1`).

## Commands run

From the crate directory (`crates/core`), on the final sources, 2026-10-29,
rustc 1.96.0 / clippy 0.1.96 / rustfmt 1.9.0 on `aarch64-apple-darwin`. The
workspace's `target/` was reused (not removed), and the root `Cargo.lock` is the
workspace's; this crate's own `Cargo.lock` was not consulted.

```
$ cargo fmt -- --check
(no output, exit 0)

$ cargo clippy --all-targets -- -D warnings
    Checking driftwm-core v0.21.0
    Finished `dev` profile [unoptimized + debuginfo] target(s)
(no warnings, exit 0)

$ cargo test
unittests src/lib.rs               371 passed; 0 failed; 0 ignored
tests/canvas_navigation_test.rs     25 passed; 0 failed; 0 ignored
tests/canvas_transforms_test.rs     30 passed; 0 failed; 0 ignored
tests/canvas_zoom_test.rs           25 passed; 0 failed; 0 ignored
tests/config_bindings_test.rs       25 passed; 0 failed; 0 ignored
tests/config_docs_test.rs            1 passed; 0 failed; 0 ignored
tests/config_parse_test.rs          81 passed; 0 failed; 0 ignored
tests/config_path_test.rs            1 passed; 0 failed; 0 ignored
tests/config_reference_test.rs      10 passed; 0 failed; 0 ignored
tests/config_robustness_test.rs      3 passed; 0 failed; 0 ignored
tests/config_toml_test.rs           57 passed; 0 failed; 0 ignored
tests/platform_keysym_test.rs        8 passed; 0 failed; 0 ignored
tests/snap_test.rs                  18 passed; 0 failed; 0 ignored
tests/window_rules_test.rs          79 passed; 0 failed; 0 ignored
Doc-tests driftwm_core               0 passed; 0 failed; 0 ignored
(exit 0; 734 passed, 0 failed, 0 ignored: 723 upstream + 11 of the config port)
```

Unit tests by module: `canvas` 51, `config` 123, `grabs` 32, `layout` 112,
`platform` 2, `session` 13, `stage` 38 (371).

Also run:

```
$ tools/diff-upstream.sh <tree of df3de27b, a git archive of the tag>
(40 upstream originals: OK; 32 ported files: 7 identical below the header, 25
with the changes tabled under Deviations; 8 byte-identical copies: OK; exit 0.
The tree was `git archive v0.21.0` output. `third_party/driftwm` is the same
files: the 13 files of the three test oracles were compared with `cmp`, and
the vendor lane's `SHA256SUMS` is the check of the rest.)

$ tools/port-new-files.py <same tree>
(check mode: the 12 files ported here are byte-identical to what the script
produces from upstream; exit 0. It reported `src/window_ext.rs` as different
until its two line ranges and header text were updated for the three new
lines of v0.21.0 that sit in front of the trait; the script, not the file, was
edited, then run with --write to regenerate it.)

$ tools/check-standins.py ~/.cargo/registry/src/index.crates.io-*/smithay-0.7.0
36 items: 31 SAME, 5 DIFF
the DIFFs are the five expected ones
(exit 0)

$ python3 -I tools/gen_keysyms.py --xkeysym … --xkbcommon … --xkbcommon-rs … --out <scratch file>
xkeysym 0.2.1: 2575 names
xkbcommon 0.9.0: 2402 names
names taken from xkbcommon 0.9.0 only: ['hpYdiaeresis']
names not in xkbcommon 0.9.0: 174
xkbcommon-rs 0.1.2: 2575 names; only here ['hpYdiaeresis']; only there []; value mismatches []
total: 2576 names, 2446 distinct values
names differing only by case: 340 groups
(the scratch file is byte-identical to src/platform/input/keyboard/keysyms.rs)

$ cargo run --offline --manifest-path tools/keysym-oracle/Cargo.toml
table names: 2576
compared     182 lookups: hand-picked
compared    2040 lookups: legacy XF86_ spellings
compared   15456 lookups: near misses
compared  600000 lookups: random identifiers
compared  200000 lookups: random numeric forms
compared   25760 lookups: table name spellings
mismatches: 12
(the 12 listed under "The oracle run")

$ cargo +1.90.0 test --offline --locked
(exit 0; 686 passed, 0 failed, 0 ignored, with Rust 1.90.0)

$ cargo doc --no-deps --offline
(no warnings)

$ rustfmt --edition 2024 --check <upstream originals: src/canvas.rs, src/stage/mod.rs,
    src/window_ext.rs, src/grabs/touch_recognizer.rs, src/input/gestures.rs, the three
    canvas tests; rustfmt follows their `mod` lines into stage/{element,mock,tests}.rs,
    touch_recognizer/tests.rs and gestures/*.rs>
(no output, exit 0: upstream's files are rustfmt-clean under this toolchain)
```

Build products (`target/`, `tools/keysym-oracle/target/`) were deleted after
these runs.

## Not run, not verified

- Upstream's own test suite was not run in upstream's tree. It needs the
  Wayland, DRM and libinput system libraries and does not build on macOS. That
  these 675 tests pass upstream is assumed, not observed.
- No comparison against C libxkbcommon, in any version.
- The stand-in types were compared with the Smithay 0.7.0 release, not with the
  git revision upstream locks. Whether the two differ in `geometry.rs` or
  `TouchSlot` was not checked.
- Rust 1.88, the declared minimum (upstream's `rust-version`), was not tried:
  that toolchain is not installed here. 1.90.0 and 1.96.0 were.
- Only `aarch64-apple-darwin` was used. Linux and other architectures were not
  tried.
- The crate was not built as a member of the Infinify workspace, and the empty
  `[workspace]` table was not tested against an enclosing workspace (the output
  directory is not inside one).
- Nothing in the Infinify repository was built, run or modified.
- `UPDATE_CONFIG_DOCS=1` (regenerating `docs/config.md`) was not exercised.
- `tools/keysym-oracle`, `tools/gen_keysyms.py`, `tools/check-standins.py` and
  `tools/port-new-files.py` are not part of `cargo test`; each was run by hand
  as shown above.
- The binary crate was not surveyed for further pure code beyond what the brief
  named. Candidates noticed in passing, none ported: `GestureState` and
  `DOUBLE_TAP_WINDOW_MS` (`src/input/gestures.rs`); and two pure mappings whose
  result is a Wayland protocol enum, `edge_from_origin`
  (`src/grabs/touch_gesture_grab.rs`, a 3×3 grid to an xdg resize edge) and
  `decoration_mode_to_wire`.

## Re-verifying

```sh
shasum -a 256 -c SHA256SUMS
tools/diff-upstream.sh                       # against ../../third_party/driftwm
tools/diff-upstream.sh /path/to/driftwm-tree # or any tree of the pinned commit
tools/port-new-files.py /path/to/driftwm-tree # check mode, writes nothing
cargo fmt -- --check && cargo clippy --all-targets -- -D warnings && cargo test
tools/check-standins.py /path/to/smithay-0.7.0             # optional
cargo run --manifest-path tools/keysym-oracle/Cargo.toml   # optional, needs xkbcommon-rs
```

`tools/keysym-oracle` is a separate package with its own `[workspace]` table
and lockfile (not pinned to upstream's versions). It pulls in xkbcommon-rs and
its parser-generator dependencies, which this crate does not depend on. It can
be deleted without affecting the crate.

## Third-party material

Everything here is under licences compatible with GPL-3.0-or-later.

- **Smithay** (MIT, © 2017 Victor Berger and Victoria Brekenfeld): `TouchSlot`
  and the `Point`, `Size`, `Rectangle` and `Coordinate` code in
  `src/platform.rs` are taken from Smithay 0.7.0 (`src/backend/input/mod.rs`,
  `src/utils/geometry.rs`); the shapes of `AxisSource`, `ModifiersState` and
  `Transform` follow it.
- **wayland-server** (MIT): the name and trait set of `WlSurface`. No code.
- **X.Org keysym names and values** (in the generated `keysyms.rs`), by way of
  xkeysym 0.2.1 (MIT OR Apache-2.0 OR Zlib, © 2022-2023 John Nunley) and, for
  one constant, xkbcommon 0.9.0 (MIT, © 2016 Remi Thebault). The underlying
  X.Org headers carry MIT/X11-style notices (The Open Group, Digital Equipment
  Corporation and others).
- **libxkbcommon** (MIT/X11-style; among others © 2009 Dan Nicholson, © 1985,
  1987, 1990, 1998 The Open Group): `xkb::keysym_from_name` reimplements its
  `xkb_keysym_from_name`, read through xkbcommon-rs 0.1.2 (same licence,
  © 2024 wysiwys).

When this crate lands in a repository with a `NOTICE` file, these belong in it.
