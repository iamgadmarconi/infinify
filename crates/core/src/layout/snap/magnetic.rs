// SPDX-License-Identifier: GPL-3.0-or-later
//
// NEW FILE, not ported from upstream. Product magnetic snapping, moved from
// crates/canvas/src/{gestures,layout}.rs. Geometric adaptation of DriftWM
// (https://github.com/malbiruk/driftwm, GPL-3.0-or-later) at
// 352333a8fa1b22171492d4b71a54102045c9a19d, src/layout/snap.rs (update_axis and candidate discovery).
// Includes the product cooldown rule from 71246bf. See docs/crates/core/PORT.md.

use super::{Line, SnapRect, StopQuery, stops};

#[derive(Debug, Clone, Copy, PartialEq)]
struct AxisSnap {
    snapped: f64,
    engaged: f64,
}
/// Magnetic latch for one gesture axis; create a fresh state per gesture.
///
/// Feed natural motion and the closest eligible candidate in gesture order.
/// A broken stop remains in cooldown until motion leaves its threshold band
/// AND it is no longer the candidate. A different candidate may engage on the
/// breaking update. Inputs are finite world coordinates and nonnegative
/// threshold/resistance, validated by the owning gesture; no I/O or errors.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct AxisState {
    snap: Option<AxisSnap>,
    cooldown: Option<f64>,
}
impl AxisState {
    /// Held coordinate, for perpendicular candidate eligibility on the other axis.
    pub fn snapped(&self) -> Option<f64> {
        self.snap.map(|snap| snap.snapped)
    }

    pub fn update(
        &mut self,
        natural: f64,
        candidate: Option<f64>,
        threshold: f64,
        resistance: f64,
    ) -> f64 {
        if let Some(snap) = self.snap {
            let (retreat, overshoot) = if snap.snapped > snap.engaged {
                (snap.engaged - natural, natural - snap.snapped)
            } else {
                (natural - snap.engaged, snap.snapped - natural)
            };
            if retreat >= resistance || overshoot >= resistance {
                self.cooldown = Some(snap.snapped);
                self.snap = None;
                if let Some(snapped) = candidate
                    && snapped != snap.snapped
                {
                    self.snap = Some(AxisSnap {
                        snapped,
                        engaged: natural,
                    });
                    return snapped;
                }
                return natural;
            }
            return snap.snapped;
        }
        if self.cooldown.is_some_and(|position| {
            (natural - position).abs() > threshold && candidate != Some(position)
        }) {
            self.cooldown = None;
        }
        if self.cooldown.is_none()
            && let Some(snapped) = candidate
        {
            self.snap = Some(AxisSnap {
                snapped,
                engaged: natural,
            });
            return snapped;
        }
        natural
    }
}

/// Closest drag correction offered by the shared stops, in neighbor order.
///
/// `query` describes the primary's perpendicular span and enables families;
/// interactive callers use `side_docks: false` and `align_band: gap + threshold`.
/// Inputs are finite, ordered world rectangles with nonnegative parameters.
/// Distances are measured before the gap, strictly below `threshold`; ties keep
/// the first stop. Returns `None` when no candidate qualifies. No allocation/I/O.
pub fn drag_candidate(
    primary: SnapRect,
    others: impl IntoIterator<Item = SnapRect>,
    query: &StopQuery,
    threshold: f64,
) -> Option<f64> {
    let (low, high) = axis_edges(primary, query.horizontal);
    let mut best = None;
    for other in others {
        for stop in stops(std::slice::from_ref(&other), query) {
            let candidate = match stop.line {
                Line::Low => (stop.at - low, (low - stop.contact).abs()),
                Line::High => (stop.at - high, (high - stop.contact).abs()),
                Line::Center => {
                    let (other_low, other_high) = axis_edges(other, query.horizontal);
                    // Keep canvas's expression order: subtracting midpoint or
                    // extent instead can change fractional coordinates by a ULP.
                    (
                        (other_low + other_high - low - high) / 2.0,
                        ((low + high - other_low - other_high) / 2.0).abs(),
                    )
                }
            };
            nominate(&mut best, candidate, threshold);
        }
    }
    best.map(|(position, _)| position)
}

/// Closest coordinate offered to one resizing edge by the shared stops.
///
/// Same ordering, input and threshold contract as [`drag_candidate`]. Only the
/// active low/high edge is eligible; center stops never attract a resize.
pub fn resize_candidate(
    primary: SnapRect,
    others: impl IntoIterator<Item = SnapRect>,
    query: &StopQuery,
    threshold: f64,
    high_edge: bool,
) -> Option<f64> {
    let (low, high) = axis_edges(primary, query.horizontal);
    let (line, natural) = if high_edge {
        (Line::High, high)
    } else {
        (Line::Low, low)
    };
    let mut best = None;
    for other in others {
        for stop in stops(std::slice::from_ref(&other), query).filter(|stop| stop.line == line) {
            nominate(
                &mut best,
                (stop.at, (natural - stop.contact).abs()),
                threshold,
            );
        }
    }
    best.map(|(position, _)| position)
}

fn axis_edges(rect: SnapRect, horizontal: bool) -> (f64, f64) {
    if horizontal {
        (rect.x_low, rect.x_high)
    } else {
        (rect.y_low, rect.y_high)
    }
}

fn nominate(best: &mut Option<(f64, f64)>, candidate: (f64, f64), threshold: f64) {
    // Strict comparisons preserve canvas's first-target tie breaking.
    if candidate.1 < threshold && best.is_none_or(|old| candidate.1 < old.1) {
        *best = Some(candidate);
    }
}
