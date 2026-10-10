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
            let mut correction: Option<(f64, f64)> = None;
            for moving in self.windows().iter().filter(|w| w.id == id) {
                let rect = moving.world_rect.translated(actual);
                for fixed in self
                    .windows()
                    .iter()
                    .filter(|w| !members.contains(&w.id) && self.snaps(w.id))
                {
                    for candidate in
                        candidates(rect, fixed.world_rect, options, horizontal, false, false)
                            .into_iter()
                            .flatten()
                    {
                        if candidate.1 < options.threshold
                            && correction.is_none_or(|old| candidate.1 < old.1)
                        {
                            correction = Some(candidate);
                        }
                    }
                }
            }
            if let Some((correction, _)) = correction {
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
/// Candidate correction and upstream ranking distance (not correction magnitude).
pub(crate) fn candidates(
    a: Rect,
    b: Rect,
    options: SnapOptions,
    horizontal: bool,
    same_edge: bool,
    center: bool,
) -> [Option<(f64, f64)>; 5] {
    let (low, high, perp_low, perp_high) = axis_edges(a, horizontal);
    let (other_low, other_high, other_perp_low, other_perp_high) = axis_edges(b, horizontal);
    let overlap = perp_high > other_perp_low && other_perp_high > perp_low;
    let aligned = !overlap
        && (other_perp_low - perp_high)
            .max(perp_low - other_perp_high)
            .max(0.0)
            < options.gap + options.threshold;
    [
        overlap.then_some((other_low - options.gap - high, (high - other_low).abs())),
        overlap.then_some((other_high + options.gap - low, (low - other_high).abs())),
        (same_edge && aligned).then_some((other_low - low, (low - other_low).abs())),
        (same_edge && aligned).then_some((other_high - high, (high - other_high).abs())),
        (center && aligned).then_some((
            (other_low + other_high - low - high) / 2.0,
            ((low + high - other_low - other_high) / 2.0).abs(),
        )),
    ]
}

pub(crate) fn axis_edges(rect: Rect, horizontal: bool) -> (f64, f64, f64, f64) {
    if horizontal {
        (rect.origin.x, rect.right(), rect.origin.y, rect.bottom())
    } else {
        (rect.origin.y, rect.bottom(), rect.origin.x, rect.right())
    }
}

pub(crate) fn edge_candidates(
    a: Rect,
    b: Rect,
    options: SnapOptions,
    horizontal: bool,
    high_edge: bool,
    same_edge: bool,
) -> [Option<(f64, f64)>; 2] {
    let (low, high, perp_low, perp_high) = axis_edges(a, horizontal);
    let (other_low, other_high, other_perp_low, other_perp_high) = axis_edges(b, horizontal);
    let overlap = perp_high > other_perp_low && other_perp_high > perp_low;
    let aligned = same_edge
        && !overlap
        && (other_perp_low - perp_high)
            .max(perp_low - other_perp_high)
            .max(0.0)
            < options.gap + options.threshold;
    if high_edge {
        [
            overlap.then_some((other_low - options.gap, (high - other_low).abs())),
            aligned.then_some((other_high, (high - other_high).abs())),
        ]
    } else {
        [
            overlap.then_some((other_high + options.gap, (low - other_high).abs())),
            aligned.then_some((other_low, (low - other_low).abs())),
        ]
    }
}

pub(crate) fn closest(candidates: impl Iterator<Item = (f64, f64)>, threshold: f64) -> Option<f64> {
    // Keep the first target on ties, matching upstream's strict comparison.
    candidates
        .fold(None, |best: Option<(f64, f64)>, candidate| {
            if candidate.1 < threshold && best.is_none_or(|old| candidate.1 < old.1) {
                Some(candidate)
            } else {
                best
            }
        })
        .map(|(position, _)| position)
}
