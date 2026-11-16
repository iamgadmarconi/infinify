// SPDX-License-Identifier: GPL-3.0-or-later
//
// NEW FILE, not ported from upstream. Product magnetic snapping, moved from
// crates/canvas/src/{gestures,layout}.rs. Geometric adaptation of DriftWM
// (https://github.com/malbiruk/driftwm, GPL-3.0-or-later) at
// 352333a8fa1b22171492d4b71a54102045c9a19d, src/layout/snap.rs::update_axis.
// Includes the product cooldown rule from 71246bf. See docs/crates/core/PORT.md.

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
