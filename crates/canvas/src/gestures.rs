// SPDX-License-Identifier: GPL-3.0-or-later
// Geometric adaptation of malbiruk/driftwm at
// 352333a8fa1b22171492d4b71a54102045c9a19d (GPL-3.0-or-later):
// src/layout/snap.rs::update_axis, src/state/cluster_snapshot.rs, and
// src/grabs/resize_grab.rs. No Smithay/native grab or configure protocol is ported.
use crate::cluster_resize::{ResizeMember, classify, resolve};
use crate::layout::candidates;
use crate::{Error, Point, Rect, Scene, SnapOptions, WindowId};

/// A side or corner to resize. Opposite edges stay fixed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResizeEdges {
    /// Move the left edge.
    Left,
    /// Move the right edge.
    Right,
    /// Move the top edge.
    Top,
    /// Move the bottom edge.
    Bottom,
    /// Move the top and left edges.
    TopLeft,
    /// Move the top and right edges.
    TopRight,
    /// Move the bottom and left edges.
    BottomLeft,
    /// Move the bottom and right edges.
    BottomRight,
}
impl ResizeEdges {
    pub(crate) fn left(self) -> bool {
        matches!(self, Self::Left | Self::TopLeft | Self::BottomLeft)
    }
    pub(crate) fn right(self) -> bool {
        matches!(self, Self::Right | Self::TopRight | Self::BottomRight)
    }
    pub(crate) fn top(self) -> bool {
        matches!(self, Self::Top | Self::TopLeft | Self::TopRight)
    }
    pub(crate) fn bottom(self) -> bool {
        matches!(self, Self::Bottom | Self::BottomLeft | Self::BottomRight)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct AxisSnap {
    snapped: f64,
    engaged: f64,
}
#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct AxisState {
    snap: Option<AxisSnap>,
    cooldown: Option<f64>,
}
impl AxisState {
    fn update(
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
                return natural;
            }
            return snap.snapped;
        }
        if self
            .cooldown
            .is_some_and(|position| (natural - position).abs() > threshold)
        {
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

/// Frozen membership and magnetic latch state for one drag.
///
/// Create with [`Scene::begin_drag`], update with [`Scene::drag_to`], and drop
/// when the gesture ends. Cloning permits speculative gestures on cloned scenes.
#[derive(Debug, Clone, PartialEq)]
pub struct DragGesture {
    primary: Rect,
    initial: Vec<(WindowId, Rect)>,
    expected: Vec<(WindowId, Rect)>,
    options: SnapOptions,
    resistance: f64,
    x: AxisState,
    y: AxisState,
}

/// Frozen cluster classification and collision bonds for one resize.
///
/// Create with [`Scene::begin_resize`], update with [`Scene::resize_to`], and
/// drop to end the gesture. Newly adjacent outside windows never join it.
#[derive(Debug, Clone, PartialEq)]
pub struct ResizeGesture {
    primary: (WindowId, Rect),
    expected: Vec<(WindowId, Rect)>,
    members: Vec<ResizeMember>,
    edges: ResizeEdges,
    options: SnapOptions,
    bonds: Vec<(usize, usize)>,
}

impl Scene {
    /// Start a magnetic drag, optionally capturing the current connected group.
    /// All snap parameters and positive `break_force` are in world points.
    /// Only the primary window's opposite edges attract; the captured group
    /// follows rigidly. Targets outside the group use their current geometry.
    pub fn begin_drag(
        &self,
        id: WindowId,
        options: SnapOptions,
        break_force: f64,
        move_group: bool,
    ) -> Result<DragGesture, Error> {
        options.validate()?;
        if !break_force.is_finite() || break_force <= 0.0 || break_force > 1e6 {
            return Err(Error::Invalid("snap break force"));
        }
        let primary = self.window(id).ok_or(Error::UnknownWindow(id))?.world_rect;
        let initial = self.gesture_members(id, options, move_group)?;
        Ok(DragGesture {
            primary,
            expected: initial.clone(),
            initial,
            options,
            resistance: break_force,
            x: AxisState::default(),
            y: AxisState::default(),
        })
    }

    /// Apply total unsnapped world displacement **from gesture start**, not
    /// since the last event. Returns total snapped world displacement.
    ///
    /// A screen-driven caller divides its total screen displacement by its
    /// gesture-start zoom. Likewise divide screen snap distance/break force by
    /// that zoom before `begin_drag`; the gap remains a world distance. Camera
    /// changes are independent. Repeated positions do not accumulate drift.
    ///
    /// Latches break on retreat from engagement or overshoot past the target by
    /// `break_force`. Re-engagement waits until the cursor leaves the snap band.
    /// Missing or externally changed captured windows, invalid deltas and
    /// invalid resulting geometry leave both scene and gesture unchanged.
    pub fn drag_to(&mut self, gesture: &mut DragGesture, delta: Point) -> Result<Point, Error> {
        if !delta.valid() {
            return Err(Error::Invalid("drag delta"));
        }
        let mut next = gesture.clone();
        let mut actual = delta;
        // Eligibility uses the visible held perpendicular position, as upstream.
        actual.y = next.y.snap.map_or(delta.y, |snap| snap.snapped);
        let candidate_x = self
            .drag_candidate(&next, actual, true)
            .map(|c| delta.x + c);
        actual.x = next.x.update(
            delta.x,
            candidate_x,
            next.options.threshold,
            next.resistance,
        );
        actual.y = delta.y;
        let candidate_y = self
            .drag_candidate(&next, actual, false)
            .map(|c| delta.y + c);
        actual.y = next.y.update(
            delta.y,
            candidate_y,
            next.options.threshold,
            next.resistance,
        );
        let updates: Vec<_> = next
            .initial
            .iter()
            .map(|&(id, rect)| (id, rect.translated(actual)))
            .collect();
        self.apply_gesture(&next.expected, &updates)?;
        next.expected = updates;
        *gesture = next;
        Ok(actual)
    }

    /// Capture a resize's initial geometry and connected component. Membership
    /// and per-side downstream classification remain fixed until it is dropped.
    /// `options.threshold` is unused: resize edge snapping is not implemented.
    pub fn begin_resize(
        &self,
        id: WindowId,
        edges: ResizeEdges,
        options: SnapOptions,
        resize_group: bool,
    ) -> Result<ResizeGesture, Error> {
        options.validate()?;
        let primary = (
            id,
            self.window(id).ok_or(Error::UnknownWindow(id))?.world_rect,
        );
        let expected = self.gesture_members(id, options, resize_group)?;
        let members = classify(primary, &expected, edges, options);
        Ok(ResizeGesture {
            primary,
            expected,
            members,
            edges,
            options,
            bonds: Vec::new(),
        })
    }

    /// Move the active edges by a total world delta **from gesture start**.
    /// Positive X/Y moves an edge right/down; it shrinks a left/top resize and
    /// grows a right/bottom resize. An inactive axis ignores its finite delta.
    /// For screen input divide total displacement by gesture-start zoom.
    ///
    /// Downstream members translate without resizing. Collisions can push other
    /// captured members, retaining directional bonds across motion reversals.
    /// Outside windows and all cameras remain unchanged. Nonpositive dimensions,
    /// nonfinite/out-of-range geometry, missing/externally changed members or an
    /// unsettled cascade fail atomically, including the gesture's bond state.
    pub fn resize_to(&mut self, gesture: &mut ResizeGesture, delta: Point) -> Result<Rect, Error> {
        if !delta.valid() {
            return Err(Error::Invalid("resize delta"));
        }
        let initial = gesture.primary.1;
        let mut rect = initial;
        if gesture.edges.left() {
            rect.origin.x += delta.x;
            rect.size.width -= delta.x;
        } else if gesture.edges.right() {
            rect.size.width += delta.x;
        }
        if gesture.edges.top() {
            rect.origin.y += delta.y;
            rect.size.height -= delta.y;
        } else if gesture.edges.bottom() {
            rect.size.height += delta.y;
        }
        if !rect.valid() {
            return Err(Error::Invalid("resized window geometry"));
        }
        let (shifts, bonds) = resolve(
            &gesture.members,
            initial,
            rect,
            gesture.options.gap,
            &gesture.bonds,
        )?;
        let mut updates = vec![(gesture.primary.0, rect)];
        updates.extend(
            gesture
                .members
                .iter()
                .zip(shifts)
                .map(|(member, delta)| (member.id, member.initial.translated(delta))),
        );
        self.apply_gesture(&gesture.expected, &updates)?;
        gesture.expected = updates;
        gesture.bonds = bonds;
        Ok(rect)
    }

    fn gesture_members(
        &self,
        id: WindowId,
        options: SnapOptions,
        group: bool,
    ) -> Result<Vec<(WindowId, Rect)>, Error> {
        let ids = if group {
            self.cluster(id, options)?
        } else {
            vec![id]
        };
        ids.into_iter()
            .map(|id| {
                self.window(id)
                    .map(|w| (id, w.world_rect))
                    .ok_or(Error::UnknownWindow(id))
            })
            .collect()
    }

    fn drag_candidate(&self, gesture: &DragGesture, delta: Point, horizontal: bool) -> Option<f64> {
        let rect = gesture.primary.translated(delta);
        self.windows()
            .iter()
            .filter(|w| !gesture.initial.iter().any(|(id, _)| *id == w.id))
            .flat_map(|w| candidates(rect, w.world_rect, gesture.options.gap, horizontal))
            .flatten()
            .filter(|c| c.abs() < gesture.options.threshold)
            .min_by(|a, b| a.abs().total_cmp(&b.abs()))
    }

    fn apply_gesture(
        &mut self,
        expected: &[(WindowId, Rect)],
        updates: &[(WindowId, Rect)],
    ) -> Result<(), Error> {
        for &(id, rect) in expected {
            let current = self.window(id).ok_or(Error::UnknownWindow(id))?;
            if current.world_rect != rect {
                return Err(Error::Invalid("gesture member geometry changed externally"));
            }
        }
        for &(id, rect) in updates {
            if self.window(id).is_none() {
                return Err(Error::UnknownWindow(id));
            }
            if !rect.valid() {
                return Err(Error::Invalid("gesture member geometry"));
            }
        }
        // Every lookup and geometry is validated before the first write.
        for window in &mut self.windows {
            if let Some((_, rect)) = updates.iter().find(|(id, _)| *id == window.id) {
                window.world_rect = *rect;
            }
        }
        Ok(())
    }
}
