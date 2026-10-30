// SPDX-License-Identifier: GPL-3.0-or-later
//
// NEW FILE, not ported from upstream: the crate root of driftwm-core.
//
// It stands in for two upstream crate roots of malbiruk/driftwm
// (repository: https://github.com/malbiruk/driftwm, commit
// 352333a8fa1b22171492d4b71a54102045c9a19d, GPL-3.0-or-later):
//
//   src/lib.rs   (library crate `driftwm`):
//       pub mod canvas; pub mod config; pub mod desktop_entry; pub mod layout;
//       pub mod protocols; pub mod session; pub mod stage; pub mod text;
//       pub mod window_ext;
//   src/main.rs  (binary crate): `mod grabs; mod input;` among the compositor's
//       other modules.
//
// Declared here, with upstream's names so that upstream's `crate::…` paths
// resolve unchanged: `canvas`, `config`, `layout` (library) and `input`
// (binary; reduced to the one pure helper `gestures::direction_from_vector`).
// `platform` is this crate's stand-in for the Smithay/xkb types those modules
// name. Upstream's `session`, `stage`, `window_ext` and `grabs` modules are not
// carried: Infinify does not use them.
//
// Not declared (not ported): `desktop_entry`, `protocols`, `text`, and
// everything else in the binary crate.
// See docs/crates/core/PORT.md for the full change log.
//! The pure, compositor-independent parts of DriftWM as one platform-neutral
//! crate: canvas math, configuration and layout.

pub mod canvas;
pub mod config;
pub mod input;
pub mod layout;
pub mod platform;
