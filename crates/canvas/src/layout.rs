// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm src/layout/{snap,cluster}.rs
// at 352333a8fa1b22171492d4b71a54102045c9a19d.
// Retains strict perpendicular overlap and on-demand connected components.
// Magnetic stop discovery and latching live in driftwm_core::layout::snap;
// gestures.rs owns frozen membership and gesture geometry.
use crate::{Error, Rect, Scene, WindowId};
use std::collections::BTreeSet;

/// World-unit parameters for edge docking and connected groups.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SnapOptions {
    /// Desired gap between adjacent window edges.
    pub gap: f64,
    /// Distance from the neighboring edge before applying the gap (zero disables snapping).
    pub threshold: f64,
    /// Allowed error around the gap when discovering an existing cluster.
    pub adjacency_tolerance: f64,
}
impl Default for SnapOptions {
    fn default() -> Self {
        Self {
            gap: 12.0,
            threshold: 24.0,
            adjacency_tolerance: 1.0,
        }
    }
}
impl SnapOptions {
    pub(crate) fn validate(self) -> Result<(), Error> {
        if [self.gap, self.threshold, self.adjacency_tolerance]
            .iter()
            .any(|v| !v.is_finite() || *v < 0.0 || *v > 1e6)
        {
            return Err(Error::Invalid("snap parameters"));
        }
        Ok(())
    }
}
impl Scene {
    /// Find the connected edge-adjacent component containing a window.
    /// Corner-only contact does not form a bond, even within tolerance. A
    /// window excluded from snapping is alone, and joins no other's component.
    pub fn cluster(&self, id: WindowId, options: SnapOptions) -> Result<Vec<WindowId>, Error> {
        options.validate()?;
        if self.window(id).is_none() {
            return Err(Error::UnknownWindow(id));
        }
        let mut visited = BTreeSet::from([id]);
        let mut pending = if self.snaps(id) { vec![id] } else { Vec::new() };
        while let Some(next) = pending.pop() {
            let Some(current) = self.window(next) else {
                continue;
            };
            for window in self.windows() {
                if !visited.contains(&window.id)
                    && self.snaps(window.id)
                    && adjacent(current.world_rect, window.world_rect, options)
                {
                    visited.insert(window.id);
                    pending.push(window.id);
                }
            }
        }
        Ok(visited.into_iter().collect())
    }
}

pub(crate) fn adjacent(a: Rect, b: Rect, options: SnapOptions) -> bool {
    let y_overlap = a.origin.y < b.bottom() && b.origin.y < a.bottom();
    let x_overlap = a.origin.x < b.right() && b.origin.x < a.right();
    (y_overlap
        && ((a.right() + options.gap - b.origin.x).abs() <= options.adjacency_tolerance
            || (b.right() + options.gap - a.origin.x).abs() <= options.adjacency_tolerance))
        || (x_overlap
            && ((a.bottom() + options.gap - b.origin.y).abs() <= options.adjacency_tolerance
                || (b.bottom() + options.gap - a.origin.y).abs() <= options.adjacency_tolerance))
}
