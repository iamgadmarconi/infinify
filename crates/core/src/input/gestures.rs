// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ported from DriftWM (GPL-3.0-or-later)
//   repository: https://github.com/malbiruk/driftwm
//   commit:     df3de27b26c7998e8a460cffd8a4925cbed3a322
//   path:       src/input/gestures.rs
//   sha-256:    6a07e9e9a620b45bd5a52aa59136887775d609d00ad94b9c53d93c89ac3323d3 (upstream file)
// This is an EXTRACT, not the whole file. Kept: `direction_from_vector`
// (upstream lines 86-113, body unmodified), the pure helper that maps a
// vector to one of eight directions; the Infinify controller
// (crates/desktop) calls it. Changes from upstream:
//   - visibility widened from `pub(crate)` to `pub`: upstream also calls
//     it from `src/input/gestures/swipe.rs` and `src/grabs/navigate_grab.rs`
//     (binary crate), so the driftwm-desktop crate needs to reach it;
//   - imports reduced to what the function uses, with the prefixes
//     `smithay::` -> `crate::platform::` and `driftwm::` -> `crate::`
//     (`use smithay::utils::{Logical, Point};`,
//     `use driftwm::config::{Action, Direction, ThresholdAction};`);
//   - left out (lines 1-85): the submodules `device_config`, `hold`,
//     `pinch`, `swipe`; `enum GestureState`; `DOUBLE_TAP_WINDOW_MS`; and
//     `impl DriftWm { gesture_camera_zoom, gesture_output_or_active,
//     gesture_output_fullscreen, cancel_animations }`, which are compositor
//     state or libinput pointer-gesture handling.
// See docs/crates/core/PORT.md for the full change log.

use crate::platform::utils::{Logical, Point};

use crate::config::Direction;

/// Map a 2D vector to the nearest of 8 directions (4 cardinal + 4 diagonal).
/// Uses 45° octants: tan(22.5°) ≈ 0.4142 as the minor/major axis ratio threshold.
pub fn direction_from_vector(v: Point<f64, Logical>) -> Direction {
    let ax = v.x.abs();
    let ay = v.y.abs();
    let minor = ax.min(ay);
    let major = ax.max(ay);

    // If the minor axis is > 41.4% of the major axis, the vector is diagonal
    if major > 0.0 && minor > major * 0.4142 {
        match (v.x > 0.0, v.y > 0.0) {
            (true, true) => Direction::DownRight,
            (true, false) => Direction::UpRight,
            (false, true) => Direction::DownLeft,
            (false, false) => Direction::UpLeft,
        }
    } else if ax > ay {
        if v.x > 0.0 {
            Direction::Right
        } else {
            Direction::Left
        }
    } else if v.y > 0.0 {
        Direction::Down
    } else {
        Direction::Up
    }
}
