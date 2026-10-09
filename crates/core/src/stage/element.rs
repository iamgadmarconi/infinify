// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from DriftWM (GPL-3.0-or-later)
//   repository: https://github.com/malbiruk/driftwm
//   commit:     352333a8fa1b22171492d4b71a54102045c9a19d
//   path:       src/stage/element.rs
//   sha-256:    6fdfabbfc7189cc14a80014314e318203eb3e9129ef953b8fe5357a0c7f1f8aa (upstream file)
// Changes from upstream: this header; `impl StageElement for Window` (the
// Smithay Wayland window, upstream lines 20-34) is left out together with
// the imports only it used (`smithay::desktop::Window`,
// `smithay::utils::IsAlive`, `smithay::wayland::seat::WaylandFocus`); the
// remaining import reads `crate::platform::utils::{Logical, Size}`. The
// `StageElement` trait itself is unmodified.
// See PORT.md in the crate root for the full change log.

use crate::platform::utils::{Logical, Size};

use crate::window_ext::WindowExt;

/// The seam between [`Stage`](super::Stage) and the window type it manages.
/// Stage logic only ever queries windows through this trait (plus `WindowExt`),
/// so tests can drive the same logic with a mock. Add methods only when a real
/// callsite demands one.
pub trait StageElement: WindowExt + Clone + PartialEq {
    fn size(&self) -> Size<i32, Logical>;
    /// Named `is_alive` (not `alive`) to avoid ambiguity with smithay's
    /// `IsAlive::alive` at callsites that have both traits in scope.
    fn is_alive(&self) -> bool;
    /// True when `self`'s toplevel parent (xdg_toplevel.set_parent) is `parent`.
    fn is_child_of(&self, parent: &Self) -> bool;
}
