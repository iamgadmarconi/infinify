// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from DriftWM (GPL-3.0-or-later)
//   repository: https://github.com/malbiruk/driftwm
//   commit:     352333a8fa1b22171492d4b71a54102045c9a19d
//   path:       src/window_ext.rs
//   sha-256:    efe14bca0888978d52e21b5bc4def7fa8970e44a7bdb49d30efb5138c99d464f (upstream file)
// Changes from upstream: this header; only the `WindowExt` trait is kept
// (upstream lines 45-68, unmodified). Left out, because each needs the
// Wayland stack: `set_tiled_states`, `unset_tiled_states` and
// `decoration_mode_to_wire` (lines 6-43), `impl WindowExt for Window`
// (lines 70-189), and the imports only they used
// (`smithay::desktop::Window`, `smithay::wayland::shell::xdg::ToplevelSurface`).
// The two remaining imports read `crate::platform::`.
// See PORT.md in the crate root for the full change log.

use crate::platform::reexports::wayland_server::protocol::wl_surface::WlSurface;
use crate::platform::utils::{Logical, Size};

/// Window operations not directly available on smithay's shape, or that
/// need to read xdg-toplevel surface state.
pub trait WindowExt {
    fn send_close(&self);
    fn app_id_or_class(&self) -> Option<String>;
    fn window_title(&self) -> Option<String>;
    /// Always false — SSD is negotiated via xdg-decoration.
    fn wants_ssd(&self) -> bool;
    fn enter_fullscreen_configure(&self, size: Size<i32, Logical>);
    fn exit_fullscreen_configure(&self, saved_size: Size<i32, Logical>);
    fn enter_fit_configure(&self, size: Size<i32, Logical>);
    fn exit_fit_configure(&self, saved_size: Size<i32, Logical>);
    fn parent_surface(&self) -> Option<WlSurface>;
    /// True only for xdg-dialog-v1 modal dialogs. Non-modal parented windows
    /// (palettes, find dialogs) return false.
    fn is_modal(&self) -> bool;
    /// Widgets are persistent canvas furniture (excluded from close, nudge,
    /// focus-cycle, etc).
    fn is_widget(&self) -> bool;
    /// True only for a compositor-drawn suspended window (no client surface).
    fn is_suspended(&self) -> bool {
        false
    }
}
