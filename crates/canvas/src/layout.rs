// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm src/layout/{snap,cluster}.rs at 352333a8fa1b22171492d4b71a54102045c9a19d.
// Retains strict perpendicular overlap and on-demand connected components.
// The legacy incremental API remains stateless; gestures.rs adds grab hysteresis.
use crate::{Error, Point, Rect, Scene, WindowId};
use std::collections::BTreeSet;

/// World-unit parameters for edge docking and connected groups.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SnapOptions {
    /// Desired gap between adjacent window edges.
    pub gap: f64,
    /// Maximum correction distance to engage a snap (zero disables snapping).
    pub threshold: f64,
    /// Allowed error around the gap when discovering an existing cluster.
    pub adjacency_tolerance: f64,
}
impl Default for SnapOptions {
    fn default() -> Self {
        Self {
            gap: 8.0,
            threshold: 12.0,
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
    /// Corner-only contact does not form a bond, even within tolerance.
    pub fn cluster(&self, id: WindowId, options: SnapOptions) -> Result<Vec<WindowId>, Error> {
        options.validate()?;
        if self.window(id).is_none() {
            return Err(Error::UnknownWindow(id));
        }
        let mut visited = BTreeSet::from([id]);
        let mut pending = vec![id];
        while let Some(next) = pending.pop() {
            let Some(current) = self.window(next) else {
                continue;
            };
            for window in self.windows() {
                if !visited.contains(&window.id)
                    && adjacent(current.world_rect, window.world_rect, options)
                {
                    visited.insert(window.id);
                    pending.push(window.id);
                }
            }
        }
        Ok(visited.into_iter().collect())
    }
    /// Translate the existing connected component rigidly. Returns moved IDs.
    pub fn move_cluster(
        &mut self,
        id: WindowId,
        delta: Point,
        options: SnapOptions,
    ) -> Result<Vec<WindowId>, Error> {
        let members = self.cluster(id, options)?;
        self.translate_members(&members, delta)?;
        Ok(members)
    }
    /// Move a window (or its pre-move cluster) and dock its nearest edges.
    /// The returned world displacement includes snap correction. Every member
    /// receives exactly that displacement; failed validation moves none of them.
    pub fn snap_move(
        &mut self,
        id: WindowId,
        delta: Point,
        options: SnapOptions,
        move_group: bool,
    ) -> Result<Point, Error> {
        options.validate()?;
        if !delta.valid() {
            return Err(Error::Invalid("move delta"));
        }
        let members = if move_group {
            self.cluster(id, options)?
        } else {
            if self.window(id).is_none() {
                return Err(Error::UnknownWindow(id));
            }
            vec![id]
        };
        let mut actual = delta;
        // Resolve X first, then use those final edges to determine Y eligibility.
        // This avoids a diagonal correction docking to a corner without overlap.
        for horizontal in [true, false] {
            let mut correction: Option<f64> = None;
            for moving in self.windows().iter().filter(|w| members.contains(&w.id)) {
                let rect = moving.world_rect.translated(actual);
                for fixed in self.windows().iter().filter(|w| !members.contains(&w.id)) {
                    for candidate in candidates(rect, fixed.world_rect, options.gap, horizontal)
                        .into_iter()
                        .flatten()
                    {
                        if candidate.abs() < options.threshold
                            && correction.is_none_or(|old| candidate.abs() < old.abs())
                        {
                            correction = Some(candidate);
                        }
                    }
                }
            }
            if let Some(correction) = correction {
                if horizontal {
                    actual.x += correction;
                } else {
                    actual.y += correction;
                }
            }
        }
        self.translate_members(&members, actual)?;
        Ok(actual)
    }
    fn translate_members(&mut self, members: &[WindowId], delta: Point) -> Result<(), Error> {
        if !delta.valid() {
            return Err(Error::Invalid("move delta"));
        }
        let updates: Result<Vec<_>, Error> = members
            .iter()
            .map(|&id| {
                let rect = self
                    .window(id)
                    .ok_or(Error::UnknownWindow(id))?
                    .world_rect
                    .translated(delta);
                if !rect.valid() {
                    return Err(Error::Invalid("moved window geometry"));
                }
                Ok((id, rect))
            })
            .collect();
        for (id, rect) in updates? {
            self.set_window_rect(id, rect)?;
        }
        Ok(())
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
pub(crate) fn candidates(a: Rect, b: Rect, gap: f64, horizontal: bool) -> [Option<f64>; 2] {
    if horizontal && a.origin.y < b.bottom() && b.origin.y < a.bottom() {
        [
            Some(b.origin.x - gap - a.right()),
            Some(b.right() + gap - a.origin.x),
        ]
    } else if !horizontal && a.origin.x < b.right() && b.origin.x < a.right() {
        [
            Some(b.origin.y - gap - a.bottom()),
            Some(b.bottom() + gap - a.origin.y),
        ]
    } else {
        [None, None]
    }
}
