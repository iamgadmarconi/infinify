// SPDX-License-Identifier: GPL-3.0-or-later
//
// NEW FILE, not ported from upstream: the crate root of driftwm-core.
//
// It stands in for two upstream crate roots of malbiruk/driftwm at commit
// 352333a8fa1b22171492d4b71a54102045c9a19d (GPL-3.0-or-later):
//
//   src/lib.rs   (library crate `driftwm`):
//       pub mod canvas; pub mod config; pub mod desktop_entry; pub mod layout;
//       pub mod protocols; pub mod session; pub mod stage; pub mod text;
//       pub mod window_ext;
//   src/main.rs  (binary crate): `mod grabs; mod input;` among the compositor's
//       other modules.
//
// Declared here, with upstream's names so that upstream's `crate::…` paths
// resolve unchanged: `canvas`, `config`, `layout`, `session`, `stage`,
// `window_ext` (library), and `grabs`, `input` (binary; reduced to the pure
// touch recogniser and its one helper). `platform` is this port's stand-in for
// the Smithay/xkb types those modules name.
//
// Not declared (not ported): `desktop_entry`, `protocols`, `text`, and
// everything else in the binary crate.
// See PORT.md in the crate root for the full change log.
//! The pure, compositor-independent parts of DriftWM as one platform-neutral
//! crate: canvas math, configuration, layout, session store, the window stage
//! and the touch gesture recogniser.

pub mod canvas;
pub mod config;
pub mod grabs;
pub mod input;
pub mod layout;
pub mod platform;
pub mod session;
pub mod stage;
pub mod window_ext;
