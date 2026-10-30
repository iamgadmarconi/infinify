<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# driftwm-core: provenance record

One platform-neutral crate holding the parts of DriftWM that Infinify uses:
canvas math, configuration, layout geometry, and one gesture helper. Every
ported file's header says "See docs/crates/core/PORT.md"; this is that file, kept under the repository's `docs/` tree with the rest of the Markdown.

- Upstream: [malbiruk/driftwm](https://github.com/malbiruk/driftwm), crate `driftwm` 0.21.0 (tag `v0.21.0`)
- Current pin: `df3de27b26c7998e8a460cffd8a4925cbed3a322` ("Bump version to v0.21.0", 2026-10-27).
- First port: `352333a8fa1b22171492d4b71a54102045c9a19d` (v0.19.0 plus three
  commits); see [Update to v0.21.0](#update-to-v0210). The headers of the new
  files written for the first port (`src/lib.rs`, `src/input/mod.rs`,
  `src/platform.rs`) still name that commit, because they are not ported text
  and were not rewritten.
- Licence: GPL-3.0-or-later, as upstream. The licence text is the `LICENSE` file
  at the repository root (upstream's file, unchanged).
- Third-party code and licences: see [Third-party material](#third-party-material).
  Smithay's licence text is `crates/core/SMITHAY-LICENSE.txt`.
- Edition 2024, `rust-version` 1.88 as upstream. The crate is a member of the
  repository workspace and has no `Cargo.lock` of its own.

All upstream code is upstream's text. It was changed only where it could not
compile without the Wayland stack, where Infinify never uses it (removed, see
[Removed](#removed-left-out)), and in one place by choice: the config file lives
in a directory named `infinify`. Every difference is listed under
[Deviations](#deviations).

One behaviour is a reimplementation instead of upstream's code: turning a key
name such as `Return` into a keysym (upstream calls libxkbcommon, a C library).
It has [its own section](#keysym-name-lookup).

## Update to v0.21.0

On 2026-10-29 the crate was moved from the first pin to
`df3de27b26c7998e8a460cffd8a4925cbed3a322` (243 commits later) by merging the
upstream change of each ported file into the ported text.

## Layout

```
Cargo.toml                    package (version, authors, repository mirror upstream's)
SMITHAY-LICENSE.txt           Smithay's MIT licence text (verbatim, Smithay 0.7.0)
config.reference.toml         upstream copy (config tests read it)
docs/window-rules.md          upstream copy, six links made absolute and one re-pointed (a test reads it); now docs/crates/core/window-rules.md at the repository root
proptest-regressions/layout/{fill,snap}.txt   upstream copies (saved proptest seeds)
src/lib.rs                    crate root (new)
src/canvas.rs                 ported
src/config/*.rs               ported (six files)
src/layout/*.rs               ported (five files)
src/input/mod.rs              new: declares gestures
src/input/gestures.rs         ported (one function)
src/platform.rs               the stand-ins for Smithay/xkb types (new)
src/platform/input/keyboard/keysyms.rs   generated keysym constants and name table (new)
tests/canvas_*_test.rs        upstream's three canvas integration tests
tests/config_*_test.rs, window_rules_test.rs   upstream's six config integration tests
tests/snap_test.rs            upstream's snap integration test
tests/platform_keysym_test.rs, config_path_test.rs   this crate's own tests
```

### Module map

Upstream is two crates in one package: the library `driftwm` (`src/lib.rs`) and
the compositor binary (`src/main.rs`), which names the library `driftwm::…`.
This crate keeps upstream's module names at the crate root so upstream's
`crate::…` paths resolve unchanged.

| Module here | Upstream | Upstream crate | Ported |
|---|---|---|---|
| `canvas` | `src/canvas.rs` | library | whole file |
| `config` | `src/config/` | library | whole module, less the items under [Removed](#removed-left-out) |
| `layout` | `src/layout/` | library | whole module, less `Side::opposite` |
| `input::gestures` | `src/input/gestures.rs` | binary | `direction_from_vector` only |
| `platform` | none | n/a | new: stand-ins |

Not ported: the library modules `desktop_entry`, `protocols`, `text`, `session`,
`stage` and `window_ext`, and everything else in the binary crate (including
`grabs`).

Public paths keep upstream's shape: `driftwm::config::Config` is
`driftwm_core::config::Config`.

## Files and upstream hashes

SHA-256 of the upstream original at the pinned commit
`df3de27b26c7998e8a460cffd8a4925cbed3a322`. Each ported Rust file has a leading
SPDX line and a provenance header (repository URL, commit, upstream path,
upstream SHA-256, "Changes from upstream"). To check one: fetch that commit of
the upstream repository, hash the upstream path, and diff the file below its
header; what remains is the entry under [Deviations](#deviations).

| File (same path upstream) | SHA-256 of upstream original | Below the header |
|---|---|---|
| `src/canvas.rs` | `becd67eaef83d761141822652f8f60519051f68455608b43b8d806c0d9d23aa4` | one import path |
| `src/config/mod.rs` | `ac10ef20e1d65098edbc730372124e8c15aa06ecc3c824c6ee6cb9b4be82177f` | changed, see Deviations |
| `src/config/types.rs` | `3a7a6be2a912c13a2a626527bd6a740e920a90de822abdc92132b7f883a15f8e` | changed, see Deviations |
| `src/config/parse.rs` | `4c123070660e17df07af21be03755cc000bd5b935dd716328f89b5c659ebf2cc` | changed, see Deviations |
| `src/config/parse_helpers.rs` | `57e32e373dae1d62e597f8903376b24dd08ace81c51198e0e886bd85778d3247` | changed, see Deviations |
| `src/config/toml.rs` | `6e67a2e41ba1c39a7a71fea7b340b32bfafc0ca1994af248ebdaaf39df2d024b` | changed, see Deviations |
| `src/config/defaults.rs` | `c2569a8d2db92dc3326238698c18b3c461dfc39835c4ae98d6b512856002dcd4` | one import path |
| `src/layout/mod.rs` | `30e14c74317edb70c7d93e8a0c5e873f2a31ef518bef29eef5deb931d3d99030` | identical |
| `src/layout/snap.rs` | `66df12387a8f9fc6af09356e3c46b4263863d956d76b83ea6dcd358976f6b1ae` | identical |
| `src/layout/cluster.rs` | `4190c07d8f09cc70fdee19e1745297713f1ff8e06ab2db4337c0e316ea351a1a` | `Side::opposite` removed |
| `src/layout/auto_placement.rs` | `d99fa9d5ca4a5e9d84e6ef6d6672e6ea531186f40187d88082b63285e8999806` | identical |
| `src/layout/fill.rs` | `5f210f68f61c21606f8786b8751c8b36a232357d4ebdcda6e470868a4f1a16b3` | identical |
| `src/input/gestures.rs` | `6a07e9e9a620b45bd5a52aa59136887775d609d00ad94b9c53d93c89ac3323d3` | an extract, see Deviations |
| `crates/core/tests/canvas_navigation_test.rs` | `231937c6c83cb17c24ac419f575cdd4de3474c60d87d27c1cf405a1198c0becf` | crate paths |
| `crates/core/tests/canvas_transforms_test.rs` | `6c8ec536dda510c849e8472bf4f5bdc88f371b402a810ebe3a142c58d2c6bb0f` | crate paths, two `#[rustfmt::skip]` |
| `crates/core/tests/canvas_zoom_test.rs` | `655b9efc5d056c2c626eea24377f5c81c38197bbf5d90c00f912b602dd8b5812` | crate paths |
| `crates/core/tests/config_bindings_test.rs` | `181f59507b1e6aa7f095d3ba390decdcba7d22bffa8d8a3d162e6d2f1475abac` | crate paths |
| `crates/core/tests/config_parse_test.rs` | `303fbb0df3922f9039d59d05f6c576fd7f0e7282b2a1d4f257fabe1c0b2e0107` | crate paths |
| `crates/core/tests/config_reference_test.rs` | `7aca0f3766a832a9c1ab4490aca00999d9abf8a7cc2cf621decf06234376cb86` | crate paths |
| `crates/core/tests/config_robustness_test.rs` | `a6b4d9d2014260240f8a743e704a53e72d8d31e235ae9ba469b0bf397c52fb65` | crate paths |
| `crates/core/tests/config_toml_test.rs` | `e489f62bb90048885ca552f4670c925c7540357c65998dd596ed458bc8121740` | crate paths, three tests removed |
| `crates/core/tests/window_rules_test.rs` | `20219f894820fab07bc07a3e40f9fce6e367c1112f659d3e4042c5d06a38f684` | crate paths, three tests removed |
| `crates/core/tests/snap_test.rs` | `0a0b2fa41a84c022a1fbf39f22863ff24977a22fd56795d9807e5c738db3d7f0` | crate paths |

Copies without a header (the format does not allow one, or a header would
change what a test reads):

| File (same path upstream) | SHA-256 of upstream original | Here |
|---|---|---|
| `config.reference.toml` | `a0e1e00eb1ce16bc797e97a1ad918af7fddef1d710fe8246e1fae55f867e4e84` | byte-identical |
| `docs/window-rules.md` | `2f69aa604ba0b060f560d656ab464323b3bf52f9e4a55a601aec277b852a7502` | six relative links made absolute and one re-pointed; the page is now `docs/crates/core/window-rules.md` at the repository root, see Deviations |
| `proptest-regressions/layout/fill.txt` | `3a48dbe099971bfcf69ecb6f5ca09d98fd93150cb00584f262dca36dae0bece1` | byte-identical |
| `proptest-regressions/layout/snap.txt` | `052ed99ab594e71bdadef03b8b3c33d861870db653871873889724fdd72358d6` | byte-identical |

The two seed files are read by proptest and a header would change their hash;
the reference config and the rules page are read by tests. Their origin is
recorded here instead.

Read but not copied:

| Upstream path | SHA-256 | Used for |
|---|---|---|
| `src/lib.rs` | `d8af65b7c94f6215075520d6c6f7e190c7e83369dce821de533942f5c0e031be` | module names and visibility |
| `src/main.rs` | `19718c9cb6ace32e42ad80e541c8a7f79b30d741231821e90fb9e47e0aaf2bdc` | how the binary declares `input` |
| `src/input/mod.rs` | `641698c9333168bff6e98e29e44c7baf2f927504d43fe138ac94c635dd78bcd3` | how it declares `gestures` |
| `Cargo.toml` | `4d775f9ea7203092cead48f53b7b431881abd9377dae05012a259a03444fab28` | dependency requirements, `[lints.clippy]`, version, authors |
| `Cargo.lock` | `c52ea2dfd3b6b6075b1e2660d15b4a573a4eccc9cb89f88c0229e14a4503dfbb` | locked dependency versions |
| `clippy.toml` | `279abecace52e683fe2fdee815ef71f5e48b186cdf3d7dfa9be0ba86da4376dd` | read; not carried (see Dropped upstream configuration) |

New files with no upstream original (each says so in its own header):
`src/lib.rs`, `src/input/mod.rs`, `src/platform.rs`,
`src/platform/input/keyboard/keysyms.rs` (generated), `crates/core/tests/platform_keysym_test.rs`,
`crates/core/tests/config_path_test.rs`, `Cargo.toml`,
`SMITHAY-LICENSE.txt`, this file.

## Deviations

### Changes inside the ported files

Every ported file gains a leading SPDX line and provenance header. Beyond that,
this is the complete list.

| File | Change |
|---|---|
| `src/canvas.rs` | `use smithay::utils::{Logical, Point, Rectangle, Size};` reads `crate::platform::utils` |
| `src/config/mod.rs` | 4 `smithay::` imports read `crate::platform::`; `pub use toml::config_path;` reads `pub use toml::{CONFIG_DIR_NAME, config_path};`; items removed (see [Removed](#removed-left-out)): `set_config_path` re-export, `Config::{load, load_collect, load_from, load_from_collect, check_from, outer_frame_inset, match_window_rule, match_window_rule_nth, resolve_window_rules_for_layer_instance}`, `TOOLKIT_DEFAULTS` and its seeding of `child_env`, the tests that covered the removed items |
| `src/config/types.rs` | 3 imports and 4 inline paths `smithay::` read `crate::platform::`; the `Keysym` import is dropped (no longer used); removed: `applied_rule`, `DEFAULT_SHADER`, `Action::ends_fullscreen`, `ThresholdAction::ends_fullscreen`, `Modifiers::{union, all_held}`, `ModKey::is_pressed`, `PassList::allows_raw`, `WindowRule::has_criteria`, `HotCorner::contains`, and the tests `action_ends_fullscreen`, `threshold_action_ends_fullscreen`, `all_held_requires_mod3_bit_too`, `union_combines_mod3_bit` |
| `src/config/parse.rs` | one `smithay::` import reads `crate::platform::`; the `go-to` migration arm of `parse_action`, `REMOVED_ACTIONS` and its use in `parse_threshold_action`, and the test `removed_actions_keep_their_migration_message_everywhere` are removed |
| `src/config/parse_helpers.rs` | one `smithay::` import reads `crate::platform::` |
| `src/config/defaults.rs` | one `smithay::` import reads `crate::platform::` |
| `src/config/toml.rs` | new `pub const CONFIG_DIR_NAME: &str = "infinify";`, and `config_path` joins `format!("{CONFIG_DIR_NAME}/config.toml")` where upstream joins `"driftwm/config.toml"`; `set_config_path`, `CONFIG_PATH_OVERRIDE` and its branch in `config_path` removed |
| `src/layout/{mod,snap,auto_placement,fill}.rs` | none |
| `src/layout/cluster.rs` | `impl Side { fn opposite }` removed |
| `src/input/gestures.rs` | an extract: `direction_from_vector` only (upstream lines 86-113, body unmodified), `pub(crate)` widened to `pub`; imports reduced to `crate::platform::utils::{Logical, Point}` and `crate::config::Direction`; lines 1-85 removed (see Removed) |
| `crates/core/tests/canvas_navigation_test.rs` | 2 imports `driftwm::` read `driftwm_core::`; 1 import `smithay::` reads `driftwm_core::platform::` |
| `crates/core/tests/canvas_transforms_test.rs` | 1 import `driftwm::` reads `driftwm_core::`; 1 import and 4 inline type paths `smithay::` read `driftwm_core::platform::`; two `#[rustfmt::skip]`, each with a two-line comment, on the `let delta_canvas…` statements |
| `crates/core/tests/canvas_zoom_test.rs` | 1 import `driftwm::` reads `driftwm_core::`; 1 import `smithay::` reads `driftwm_core::platform::` |
| `crates/core/tests/config_{bindings,parse,reference,robustness}_test.rs` | `driftwm::config` reads `driftwm_core::config`; `smithay::` reads `driftwm_core::platform::` |
| `crates/core/tests/config_toml_test.rs` | the same |
| `crates/core/tests/window_rules_test.rs` | the same; four `let combo = …Keysym::from(…KEY_q);` statements are wrapped over three lines (rustfmt, see below); the three `window_rule_has_criteria_*` tests removed |
| `crates/core/tests/snap_test.rs` | `use driftwm::layout::snap::*;` reads `use driftwm_core::layout::snap::*;` |
| `docs/window-rules.md` | six relative links point at the upstream repository at the pinned commit instead: `ipc.md#state-file`, `config.md#window-rules`, `config.md#background`, `config.md#decorations`, `session.md#restore_windows` (all under `docs/`) and `../extras/scripts/driftwm-decal` (`extras/scripts/driftwm-decal`), each as `https://github.com/malbiruk/driftwm/blob/df3de27b26c7998e8a460cffd8a4925cbed3a322/<path>`. The pages they name are not in this repository. A seventh link, to `config.reference.toml`, was relative to the crate (`../config.reference.toml`); the page now lives at `docs/crates/core/window-rules.md` and the link reads `../../../crates/core/config.reference.toml`. The TOML fences are untouched |

### Removed (left out)

Items of upstream files that are not here, and why. Nothing else in the public
or private API of a ported file was removed.

From the first ports:

| Item | Upstream location | Why |
|---|---|---|
| `config::applied_rule` | `src/config/types.rs` | reads an `AppliedWindowRule` out of a `wl_surface`'s Smithay data map. Nothing in the ported modules or tests calls it. `AppliedWindowRule` and everything that builds one are kept |
| submodules `device_config`, `hold`, `pinch`, `swipe` | `src/input/gestures.rs` 1-4 | libinput pointer-gesture handling on compositor state |
| `enum GestureState` | `src/input/gestures.rs` 13-48 | state of a pointer (trackpad) gesture. Pure data, but nothing ported uses it |
| `DOUBLE_TAP_WINDOW_MS` (`= 300`) | `src/input/gestures.rs` 50 | used by `src/input/pointer.rs` and `src/state/navigation.rs`, not by anything ported |
| `impl DriftWm { gesture_camera_zoom, gesture_output_or_active, gesture_output_fullscreen, cancel_animations }` | `src/input/gestures.rs` 52-84 | methods of the compositor state |

Release cleanup, 2026-10-30 (Infinify has no caller for any of these):

| Item | Upstream location | Why |
|---|---|---|
| module `session` (session store with versioned envelope, quarantine, a reader for older schema versions) | `src/session.rs` | the controller persists through `crates/canvas` and its own scene file; nothing called this module. Its default path was `$XDG_STATE_HOME/driftwm/session.json` |
| module `stage` (`Stage`, `StageElement`, mock, tests, saved proptest seeds `proptest-regressions/stage/tests.txt`) | `src/stage/` | the scene is `crates/canvas::Stage`. The one record the controller used, `FitPush { fitted, home }`, is now defined in `crates/desktop/src/sizes.rs` |
| module `window_ext` (`WindowExt`) | `src/window_ext.rs` | xdg-toplevel vocabulary; no implementor exists in Infinify |
| module `grabs::touch_recognizer` (and its tests) | `src/grabs/` | touchscreen recogniser; not used. Trackpad gestures are handled by the controller's `[gestures]` dispatch and the shell's own recogniser, and touchscreen input was declared out of scope on 2026-10-11. The `[touch]` config tables stay: they live in `config` |
| `src/shaders/dot_grid.glsl`, `config::DEFAULT_SHADER` | `src/shaders/dot_grid.glsl`, `src/config/types.rs` | no reader. The built-in dot grid is a hand translation to Metal in `native/app/Canvas/IFBGDeviceResources.m`. The `BackgroundKind::Shader` config grammar stays |
| `docs/config.md`, `tests/config_docs_test.rs` | `docs/config.md`, `tests/config_docs_test.rs` | the page is upstream's Linux user page (it names `~/.config/driftwm/config.toml` and `driftwm --check-config`), and its test only kept it in sync with `config.reference.toml`. Infinify's own config documentation is `docs/crates/desktop/CONFIG.md` |
| `Config::{load, load_collect, load_from, load_from_collect, check_from}` | `src/config/mod.rs` | upstream's file loader and `--check-config`. The controller parses through `Config::from_toml_collect` |
| `config::set_config_path`, `CONFIG_PATH_OVERRIDE` | `src/config/toml.rs` | upstream's `--config` flag; the Infinify shell reads its own `--config`. `$DRIFTWM_CONFIG` stays |
| `Config::outer_frame_inset` | `src/config/mod.rs` | a native frame has no border |
| `Config::{match_window_rule, match_window_rule_nth, resolve_window_rules_for_layer_instance}` | `src/config/mod.rs` | helpers for Wayland layer-shell surfaces; no caller. `resolve_window_rules` stays |
| `Action::ends_fullscreen`, `ThresholdAction::ends_fullscreen`, `Modifiers::{union, all_held}`, `ModKey::is_pressed`, `PassList::allows_raw`, `WindowRule::has_criteria`, `HotCorner::contains` | `src/config/types.rs` | no caller. Hot corners are `native/app/Input/DWHotCorners.m`. The test `pass_keys_written_in_upper_case_matches_the_pressed_key` in `crates/core/tests/platform_keysym_test.rs` now compares the parsed `PassList::Only` combos with the expected `KeyCombo`s |
| `TOOLKIT_DEFAULTS` | `src/config/mod.rs` | five Wayland toolkit variables (`MOZ_ENABLE_WAYLAND`, `QT_QPA_PLATFORM`, `SDL_VIDEODRIVER`, `GDK_BACKEND`, `ELECTRON_OZONE_PLATFORM_HINT`) that the controller stripped from `child_env` again, because they select Wayland backends |
| `Side::opposite` | `src/layout/cluster.rs` | `#[allow(dead_code)]`, no caller |
| `TouchSlot`, `WlSurface` stand-ins | `src/platform.rs` (this crate) | their only users were the removed modules |
| scripts that compared this crate with a vendored copy of upstream or regenerated ported files from it, the hash lists they read, a keysym differential experiment, a crate-local `.gitignore`, a second copy of `LICENSE` | `crates/core` | porting and comparison aids for a copy of upstream that is no longer in the repository; the hashes are in this file and in the file headers. The keysym lookup stays covered by `crates/core/tests/platform_keysym_test.rs` |

### Changed behaviour: config file location

`config_path()` keeps upstream's precedence, less the `--config` step:

1. `$DRIFTWM_CONFIG`, if set, with a leading `~/` expanded.
2. `$XDG_CONFIG_HOME/infinify/config.toml`.
3. `$HOME/.config/infinify/config.toml`.
4. `./.config/infinify/config.toml` when `HOME` is unset.

Only the directory name differs from upstream, and it is the single constant
`config::CONFIG_DIR_NAME`. The override variable keeps upstream's name
`DRIFTWM_CONFIG`.

### Changed behaviour: config keys

From the 2026-10-30 release cleanup. The renamed-key shims (`navigation.animation_speed`,
`navigation.friction`, `snap.same_edge`, `snap.edge_center`, `effects.animate_blur`) are
upstream's and stay: a config holding one loads and reports a warning.


- `go-to` is an ordinary unknown action. Before, it was rejected with a message
  that pointed at `go-to-bookmark`.
- `Config::child_env` is the cursor variables (`XCURSOR_THEME`, `XCURSOR_SIZE`,
  when configured) plus the user's `[env]`. The five Wayland toolkit variables
  are no longer seeded.

### Added

- `config::CONFIG_DIR_NAME` (above).
- `platform`, the stand-in module (next section).
- `platform::input::keyboard::keysyms` holds a `KEY_*` constant for all 2,576
  names in its table. Upstream's `keysyms` module (xkbcommon 0.9.0) has 2,402 of
  them, each with the same value here. The other 174 are names newer libxkbcommon
  releases know. Both statements held when the table was generated.
- This crate's own tests: `crates/core/tests/platform_keysym_test.rs`,
  `crates/core/tests/config_path_test.rs`, and two table-invariant unit tests in
  `platform::input::keyboard::xkb`.
- Two `#[rustfmt::skip]` attributes with comments (rustfmt below).

No config option, action, gesture, key-code mapping or macOS-specific item was
added.

### Visibility widened

Each widening is there because the consumer, the `driftwm-desktop` crate, is another crate.

| Item | Upstream | Here |
|---|---|---|
| `input::gestures::direction_from_vector` | `pub(crate) fn` | `pub fn`. Upstream also calls it from `src/input/gestures/swipe.rs` (pointer swipe) and `src/grabs/navigate_grab.rs`, both in the binary crate, so the desktop crate needs it too |
| module `input` | `mod input;` in `src/main.rs` | `pub mod input;` |
| module `input::gestures` | `pub(crate) mod gestures;` in `src/input/mod.rs` | `pub mod gestures;` |

### rustfmt

`cargo fmt -- --check` passes with rustfmt's defaults. There is no
`rustfmt.toml` (upstream has none either).

Changing a path prefix made rustfmt want a different layout in three places:

| Where | What rustfmt wanted | What was done |
|---|---|---|
| `crates/core/tests/canvas_transforms_test.rs`, two `let delta_canvas: Point<f64, …Logical> = Point::from(…);` | wrap the statement: the longer path makes it 101 and 103 columns | `#[rustfmt::skip]` on each statement, upstream's single line kept |
| `crates/core/tests/window_rules_test.rs`, four `let combo = …Keysym::from(…KEY_q);` | wrap the statement | wrapped by rustfmt |

Each skip is one attribute plus a two-line comment that starts `// driftwm-core:`.
Attributes were chosen over a `rustfmt.toml` so the files stay correct under any
rustfmt configuration of a workspace this crate may join.

### clippy

`cargo clippy --all-targets -- -D warnings` passes. No `#[allow]` was added.
Allows present in the crate: upstream's own `#[allow(clippy::type_complexity)]`
in `layout::cluster`, `#[allow(clippy::too_many_arguments)]` in
`layout::auto_placement` and `layout::snap`, and `#![allow(non_upper_case_globals)]`
on the generated `keysyms` module (as upstream's xkbcommon module has).
`[lints.clippy] significant_drop_in_scrutinee = "warn"` is carried over from
upstream's `Cargo.toml` and applies to the whole crate.

### Dropped upstream configuration

- `clippy.toml` (`disallowed-methods`): every entry names a Smithay path
  (`smithay::desktop::space::Space::*`, `Window::bbox`,
  `with_pointer_constraint`). None can occur here.
- `[profile.*]` settings (insta/similar opt-level, release LTO) and the Tracy
  features: they concern crates or build modes outside this port.
- Upstream's dev-dependencies other than `proptest` (`insta`, the Wayland
  client crates): used by tests of modules outside this port.

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
| `platform::input::keyboard::Keysym` | `smithay::input::keyboard::Keysym` | it is the same type: both are `xkeysym::Keysym` 0.2.1 | nothing |
| `platform::input::keyboard::ModifiersState` | `smithay::input::keyboard::ModifiersState` | the eight `bool` fields; derives `Copy, Clone, Debug, Default, PartialEq, Eq, Hash` | field `serialized: SerializedMods` (the `wl_keyboard` wire form) and the methods that read an xkb state |
| `platform::input::keyboard::keysyms` | `smithay::input::keyboard::keysyms` (`xkbcommon::xkb::keysyms`) | `KEY_<name>: u32` constants, same names and values | 174 more constants than upstream's module; see Added |
| `platform::input::keyboard::xkb` | `smithay::input::keyboard::xkb` (`xkbcommon::xkb`) | `keysym_from_name`, `KeysymFlags`, `KEYSYM_NO_FLAGS`, `KEYSYM_CASE_INSENSITIVE` | everything else in `xkb`; `keysym_from_name` is a reimplementation, see below |
| `platform::utils::Logical` | `smithay::utils::Logical` | unit marker, `Debug` | nothing |
| `platform::utils::Coordinate` | `smithay::utils::Coordinate` | the supertraits; `to_f64`, `non_negative`, `saturating_add`, `saturating_sub` | `ZERO`, `downscale`, `upscale`, `from_f64`, `min`, `max`, `abs`, `saturating_mul`. Implemented for `i32` and `f64` only (Smithay: every integer and float type), so the arithmetic, `to_f64` and the `Size` constructors exist for those two; a ported use of another coordinate type would fail to compile, and none does |
| `platform::utils::Point<N, Kind>` | `smithay::utils::Point` | `x`, `y`, `new`, `to_f64`, `From<(N, N)>`, `Add`, `Sub`, `AddAssign`, `Clone`, `Copy`, `PartialEq`, `Default`, `Debug`. Smithay's text | `SubAssign`, `Eq`, `From<Point> for (N, N)`, `Add`/`Sub` of a `Size`, `to_size`, scaling, `constrain`, rounding (`to_i32_round` …), coordinate-space conversions |
| `platform::utils::Size<N, Kind>` | `smithay::utils::Size` | `w`, `h`, `new` with its `debug_assert!`, `to_f64`, `From<(N, N)>`, `Clone`, `Copy`, `PartialEq`, `Default`, `Debug`. Smithay's text | arithmetic, `Eq`, `From<Size> for (N, N)`, `to_point`, `clamp`, `is_empty`, scaling, rounding, coordinate-space conversions |
| `platform::utils::Rectangle<N, Kind>` | `smithay::utils::Rectangle` | `loc`, `size`, `new`, `to_f64`, `Clone`, `Copy`, `PartialEq`, `Debug`. Smithay's text | `Eq`, `Default`, the other constructors, `contains`, `overlaps`, `intersection`, `merge`, `subtract_*`, scaling, rounding, coordinate-space conversions |
| `platform::utils::Transform` | `smithay::utils::Transform` | the eight variants; derives `Debug, PartialEq, Eq, Hash, Clone, Copy, Default` | all methods |

Smithay paths: `Logical`, `Coordinate`, `Point`, `Size`, `Rectangle` and
`Transform` are in `src/utils/geometry.rs`, `AxisSource` in
`src/backend/input/mod.rs`, `ModifiersState` in
`src/input/keyboard/modifiers_state.rs`.

Points that affect behaviour, all as in Smithay:

- `Point` addition and subtraction saturate for `i32` (`saturating_add`,
  `saturating_sub`) and are plain `+`/`-` for `f64`.
- `Size::new`, and so `Size::from((w, h))`, has
  `debug_assert!(w.non_negative() && h.non_negative(), …)`: a negative size
  panics in debug builds, including under `cargo test`, and passes in release.
- `Debug` prints the marker's type path, so `{:?}` shows
  `Point<driftwm_core::platform::utils::Logical>` where upstream shows
  Smithay's path. No ported test compares that text.

No libinput type is shimmed. The config module's `AccelProfile`, `SendEvents`
and `click_method` are upstream's own types.

## Keysym name lookup

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

- xkbcommon 0.9.0 ([rust-x-bindings/xkbcommon-rs](https://github.com/rust-x-bindings/xkbcommon-rs),
  `src/xkb/mod.rs`, `src/xkb/keysyms.rs`): the binding upstream compiles
  against. Read for the wrapper's behaviour and its `KEY_*` list.
- xkbcommon-rs 0.1.2 ([wysiwys/xkbcommon-rs](https://github.com/wysiwys/xkbcommon-rs)):
  a Rust port of libxkbcommon 1.7.0. Read for the algorithm and its name table,
  and run as an oracle.
- xkeysym 0.2.1 ([notgull/xkeysym](https://github.com/notgull/xkeysym)): source
  of the names and values.
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
distinct values, generated once, by a script that is not kept, from xkeysym 0.2.1,
whose constants carry the X.Org header macro names; libxkbcommon's own header
rule turns those into its names (`XK_Return` → `Return`, `XF86XK_AudioMute` →
`XF86AudioMute`). One name, `hpYdiaeresis`, is absent from xkeysym and taken
from xkbcommon 0.9.0. The inputs were crates.io sources that are not kept in this repository.

Checks the generator makes on every run:

- All 2,402 names in xkbcommon 0.9.0 are present with equal values.
- The table equals xkbcommon-rs 0.1.2's table (2,575 names) plus `hpYdiaeresis`.

Generator inputs (SHA-256):

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
   (`crates/core/tests/platform_keysym_test.rs` feeds one through
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

## Kept as upstream although tied to Linux or Wayland

Not deviations. Listed because a macOS consumer has to decide what they mean.

- `canvas::VelocityTracker` and `MomentumState` document their timestamps as
  libinput event times in milliseconds.
- `[xwayland]`, `[backend]` (DRM options), `[input.keyboard]` xkb layout
  strings, `[input.trackpad]` `click_method`, `[[outputs]]` connector names and
  transforms all parse and default exactly as upstream.
- `BTN_LEFT`/`BTN_RIGHT`/`BTN_MIDDLE` are the Linux evdev codes
  (`0x110`–`0x112`). Keysyms are X11/xkb keysym values.
- `ModifiersState::iso_level5_shift` is the `mod3` modifier, as in Smithay.
- `config.reference.toml` and `docs/window-rules.md` (now `docs/crates/core/window-rules.md` at the repository root) are upstream's text. They
  say `~/.config/driftwm/config.toml`, `driftwm --check-config` and
  `driftwm msg …`, and the `[env]` comment of the reference config still names
  upstream's Wayland toolkit defaults, which this crate no longer sets. They
  are kept because tests compare them with each other and with the compiled-in
  defaults. **The path they name is not the path this crate reads**
  (`…/infinify/config.toml`). `config.reference.toml` also refers to
  upstream's pages `docs/session.md` and `docs/shaders.md`, which are not in
  this repository; they are at
  <https://github.com/malbiruk/driftwm/tree/df3de27b26c7998e8a460cffd8a4925cbed3a322/docs>.
  The same holds for every `docs/*.md` page that other files name as upstream's.

## Dependencies

Requirements are upstream's for the crates the ported modules use. Versions are
locked by the workspace `Cargo.lock`.

| Crate | Requirement | Role |
|---|---|---|
| `serde` | `1`, feature `derive` | raw config structs |
| `toml` | `0.8` | TOML parser and its error text |
| `regex` | `1` | window-rule `/…/` patterns |
| `tracing` | `0.1` | upstream's `warn!`/`error!`/`debug!` calls, unchanged |
| `xkeysym` | `0.2.1` | the `Keysym` type; upstream gets it through smithay → xkbcommon |
| `proptest` (dev) | `1` | property tests in `layout::fill` and `layout::snap`, `crates/core/tests/config_robustness_test.rs` |
| `serde_json` (dev) | `1` | one config unit test (`every_config_field_is_documented`) |

All pure Rust. No Smithay, no Wayland crate, no C library, no build script, no
system dependency. `proptest` pulls `libc`/`rustix` (through `tempfile`,
`rusty-fork`, `getrandom`) into the dev tree only.

## Tests

- Upstream's tests that remain: the unit tests inside `src/canvas.rs`,
  `src/config/*.rs`, `src/layout/*.rs`, and `crates/core/tests/{canvas_*,config_*,window_rules,snap}_test.rs`
  (table above), less the tests named under Deviations. `tests/config_docs_test.rs`
  was removed with `docs/config.md`.
- Saved proptest cases: `proptest-regressions/layout/fill.txt` (for
  `src/layout/fill.rs`) and `proptest-regressions/layout/snap.txt` (for
  `src/layout/snap.rs`), both byte-identical copies. proptest reads them at the
  test file's path under `proptest-regressions/`.
- This crate's own tests: `crates/core/tests/platform_keysym_test.rs` (key names through
  `parse_key_combo`, `[keybindings]` and `pass_keys`: case, aliases, `XF86_`,
  numeric forms, rejected names including NUL), `crates/core/tests/config_path_test.rs`
  (the four-step location precedence with the `infinify` directory), and in
  `src/platform.rs` (`xkb::tests`) two tests: the name table is in the order
  the lookup needs, and every name resolves in exact, lower and upper case.
- The stand-ins (`Coordinate`, `Size`, `Rectangle`, the `Point` arithmetic)
  have no test of their own; they are Smithay's code and are exercised by
  upstream's canvas tests. Two of their behaviours are reached by no test:
  `i32` saturation at the numeric bounds and the negative-size `debug_assert!`.

## Third-party material

Everything here is under licences compatible with GPL-3.0-or-later. The
repository's `NOTICE` file carries the attributions; Smithay's licence text is
`crates/core/SMITHAY-LICENSE.txt`.

- **Smithay** ([Smithay/smithay](https://github.com/Smithay/smithay); MIT,
  © 2017 Victor Berger and Victoria Brekenfeld): the `Point`, `Size`,
  `Rectangle` and `Coordinate` code in `src/platform.rs` is taken from Smithay
  0.7.0 (git `a166cf4c94b5aedc332a65aa1dd753e8148829c3`, `src/utils/geometry.rs`);
  the shapes of `AxisSource` (`src/backend/input/mod.rs`), `ModifiersState`
  (`src/input/keyboard/modifiers_state.rs`) and `Transform`
  (`src/utils/geometry.rs`) follow it.
- **X.Org keysym names and values** (in the generated `keysyms.rs`), by way of
  xkeysym 0.2.1 ([notgull/xkeysym](https://github.com/notgull/xkeysym);
  MIT OR Apache-2.0 OR Zlib, © 2022-2023 John Nunley) and, for one constant,
  xkbcommon 0.9.0 ([rust-x-bindings/xkbcommon-rs](https://github.com/rust-x-bindings/xkbcommon-rs);
  MIT, © 2016 Remi Thebault). The underlying X.Org headers carry MIT/X11-style
  notices (The Open Group, Digital Equipment Corporation and others).
- **libxkbcommon** (MIT/X11-style; among others © 2009 Dan Nicholson, © 1985,
  1987, 1990, 1998 The Open Group): `xkb::keysym_from_name` reimplements its
  `xkb_keysym_from_name`, read through xkbcommon-rs 0.1.2
  ([wysiwys/xkbcommon-rs](https://github.com/wysiwys/xkbcommon-rs); same
  licence, © 2024 wysiwys).
