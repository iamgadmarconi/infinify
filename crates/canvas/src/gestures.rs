// SPDX-License-Identifier: GPL-3.0-or-later
// Geometric adaptation of https://github.com/malbiruk/driftwm at
// 352333a8fa1b22171492d4b71a54102045c9a19d (GPL-3.0-or-later):
// src/layout/snap.rs::update_axis, src/state/cluster_snapshot.rs, and
// src/grabs/resize_grab.rs. No Smithay/native grab or configure protocol is ported.
use crate::cluster_resize::{ResizeMember, classify, resolve};
use crate::layout::{candidates, closest, edge_candidates};
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
    same_edge: bool,
    center: bool,
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
    resistance: f64,
    same_edge: bool,
    x: AxisState,
    y: AxisState,
}

impl DragGesture {
    /// Refresh world snap distances without resetting the latch or cooldown.
    /// Divide screen distances by the current zoom, independently of the
    /// gesture-start zoom used for pointer displacement.
    pub fn set_snap_distances(&mut self, threshold: f64, break_force: f64) -> Result<(), Error> {
        let options = SnapOptions {
            threshold,
            ..self.options
        };
        options.validate()?;
        validate_break_force(break_force)?;
        self.options = options;
        self.resistance = break_force;
        Ok(())
    }

    /// Enable upstream's optional same-edge/corner and midpoint alignment.
    /// Both default to false and require perpendicular adjacency without overlap.
    pub fn with_alignment(mut self, same_edge: bool, center: bool) -> Self {
        self.same_edge = same_edge;
        self.center = center;
        self
    }
}

impl ResizeGesture {
    /// Refresh world snap distances without resetting the latch or cooldown.
    /// Divide screen distances by the current zoom, independently of the
    /// gesture-start zoom used for pointer displacement.
    pub fn set_snap_distances(&mut self, threshold: f64, break_force: f64) -> Result<(), Error> {
        let options = SnapOptions {
            threshold,
            ..self.options
        };
        options.validate()?;
        validate_break_force(break_force)?;
        self.options = options;
        self.resistance = break_force;
        Ok(())
    }

    /// Enable upstream's optional same-edge/corner alignment (default false).
    pub fn with_same_edge(mut self, enabled: bool) -> Self {
        self.same_edge = enabled;
        self
    }

    /// Set the magnetic release distance in world points (default 32).
    /// Screen-driven callers divide the screen break force by zoom.
    pub fn with_break_force(mut self, break_force: f64) -> Result<Self, Error> {
        validate_break_force(break_force)?;
        self.resistance = break_force;
        Ok(self)
    }
}

fn validate_break_force(break_force: f64) -> Result<(), Error> {
    if !break_force.is_finite() || !(0.0..=1e6).contains(&break_force) {
        return Err(Error::Invalid("snap break force"));
    }
    Ok(())
}

impl Scene {
    /// Start a magnetic drag, optionally capturing the current connected group.
    /// All snap parameters and nonnegative `break_force` are in world points.
    /// Only the primary window's edges attract; the captured group
    /// follows rigidly. Targets outside the group use their current geometry.
    pub fn begin_drag(
        &self,
        id: WindowId,
        options: SnapOptions,
        break_force: f64,
        move_group: bool,
    ) -> Result<DragGesture, Error> {
        options.validate()?;
        validate_break_force(break_force)?;
        let primary = self.window(id).ok_or(Error::UnknownWindow(id))?.world_rect;
        let initial = self.gesture_members(id, options, move_group)?;
        Ok(DragGesture {
            primary,
            expected: initial.clone(),
            initial,
            options,
            resistance: break_force,
            same_edge: false,
            center: false,
            x: AxisState::default(),
            y: AxisState::default(),
        })
    }

    /// Apply total unsnapped world displacement **from gesture start**, not
    /// since the last event. Returns total snapped world displacement.
    ///
    /// A screen-driven caller divides its total screen displacement by its
    /// gesture-start zoom. Divide screen snap distance/break force by current
    /// zoom via `set_snap_distances`; the gap remains a world distance. Camera
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
    /// Active edges snap to outside windows and stationary cluster members.
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
            resistance: 32.0,
            same_edge: false,
            x: AxisState::default(),
            y: AxisState::default(),
        })
    }

    /// Move the active edges by a total world delta **from gesture start**.
    /// Positive X/Y moves an edge right/down; it shrinks a left/top resize and
    /// grows a right/bottom resize. An inactive axis ignores its finite delta.
    /// For screen input divide total displacement by gesture-start zoom.
    ///
    /// Downstream members translate without resizing. Collisions can push other
    /// captured members, retaining directional bonds across motion reversals.
    /// Outside windows and all cameras remain unchanged. Dimensions floor at
    /// one point before snapping. Invalid deltas,
    /// nonfinite/out-of-range geometry, missing/externally changed members or an
    /// unsettled cascade fail atomically, including the gesture's bond state.
    pub fn resize_to(&mut self, gesture: &mut ResizeGesture, delta: Point) -> Result<Rect, Error> {
        let mut next = gesture.clone();
        let initial = next.primary.1;
        let rect = self.resize_proposal(&mut next, delta)?;
        let (shifts, bonds) = resolve(&next.members, initial, rect, next.options.gap, &next.bonds)?;
        let mut updates = vec![(next.primary.0, rect)];
        updates.extend(
            next.members
                .iter()
                .zip(shifts)
                .map(|(member, delta)| (member.id, member.initial.translated(delta))),
        );
        self.apply_gesture(&next.expected, &updates)?;
        next.expected = updates;
        next.bonds = bonds;
        *gesture = next;
        Ok(rect)
    }

    /// Commit a primary rectangle the gesture did not choose: the size a native
    /// window granted for the one `resize_proposal` asked. Captured members
    /// follow it exactly as they follow `resize_to`'s own rectangle, from their
    /// positions at gesture start, so a window that stops at a limit stops its
    /// members with it. The snap latches are the proposal's and are left alone.
    /// Fails atomically like `resize_to`.
    pub fn resize_settle(&mut self, gesture: &mut ResizeGesture, rect: Rect) -> Result<(), Error> {
        if !rect.valid() {
            return Err(Error::Invalid("resized window geometry"));
        }
        let mut next = gesture.clone();
        let initial = next.primary.1;
        let (shifts, bonds) = resolve(&next.members, initial, rect, next.options.gap, &next.bonds)?;
        let mut updates = vec![(next.primary.0, rect)];
        updates.extend(
            next.members
                .iter()
                .zip(shifts)
                .map(|(member, delta)| (member.id, member.initial.translated(delta))),
        );
        self.apply_gesture(&next.expected, &updates)?;
        next.expected = updates;
        next.bonds = bonds;
        *gesture = next;
        Ok(())
    }

    /// Advance the single-window snap intent without changing committed geometry.
    /// Native callers must settle actual dimensions separately. This method
    /// computes the primary rectangle only; it does not propagate group members.
    pub fn resize_proposal(
        &self,
        gesture: &mut ResizeGesture,
        delta: Point,
    ) -> Result<Rect, Error> {
        if !delta.valid() {
            return Err(Error::Invalid("resize delta"));
        }
        let mut next = gesture.clone();
        let initial = next.primary.1;
        let width = initial.size.width
            + if next.edges.left() {
                -delta.x
            } else if next.edges.right() {
                delta.x
            } else {
                0.0
            };
        let height = initial.size.height
            + if next.edges.top() {
                -delta.y
            } else if next.edges.bottom() {
                delta.y
            } else {
                0.0
            };
        let mut rect = Rect::new(
            initial.origin.x,
            initial.origin.y,
            width.max(1.0),
            height.max(1.0),
        );
        if next.edges.left() {
            rect.origin.x = initial.right() - rect.size.width;
        }
        if next.edges.top() {
            rect.origin.y = initial.bottom() - rect.size.height;
        }

        // X uses the held Y edge, then Y uses the just-resolved X range.
        let mut visual = rect;
        if let Some(snap) = next.y.snap {
            if next.edges.top() {
                visual.origin.y = snap.snapped;
                visual.size.height = initial.bottom() - snap.snapped;
            } else if next.edges.bottom() {
                visual.size.height = snap.snapped - initial.origin.y;
            }
        }
        if next.edges.left() || next.edges.right() {
            let high = next.edges.right();
            let natural = if high { rect.right() } else { rect.origin.x };
            let candidate = self.resize_candidate(&next, visual, true, high);
            let edge = next
                .x
                .update(natural, candidate, next.options.threshold, next.resistance);
            rect.size.width = if high {
                edge - initial.origin.x
            } else {
                initial.right() - edge
            };
            if !high {
                rect.origin.x = edge;
            }
        }
        if next.edges.top() || next.edges.bottom() {
            let high = next.edges.bottom();
            let natural = if high { rect.bottom() } else { rect.origin.y };
            let candidate = self.resize_candidate(&next, rect, false, high);
            let edge = next
                .y
                .update(natural, candidate, next.options.threshold, next.resistance);
            rect.size.height = if high {
                edge - initial.origin.y
            } else {
                initial.bottom() - edge
            };
            if !high {
                rect.origin.y = edge;
            }
        }
        rect.size.width = rect.size.width.max(1.0);
        rect.size.height = rect.size.height.max(1.0);
        if next.edges.left() {
            rect.origin.x = initial.right() - rect.size.width;
        }
        if next.edges.top() {
            rect.origin.y = initial.bottom() - rect.size.height;
        }
        if !rect.valid() {
            return Err(Error::Invalid("resized window geometry"));
        }
        *gesture = next;
        Ok(rect)
    }

    fn resize_candidate(
        &self,
        gesture: &ResizeGesture,
        rect: Rect,
        horizontal: bool,
        high: bool,
    ) -> Option<f64> {
        closest(
            self.windows()
                .iter()
                .filter(|w| {
                    w.id != gesture.primary.0
                        && self.snaps(w.id)
                        && !gesture
                            .members
                            .iter()
                            .any(|m| m.id == w.id && m.is_shifted())
                })
                .flat_map(|w| {
                    edge_candidates(
                        rect,
                        w.world_rect,
                        gesture.options,
                        horizontal,
                        high,
                        gesture.same_edge,
                    )
                })
                .flatten(),
            gesture.options.threshold,
        )
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
        closest(
            self.windows()
                .iter()
                .filter(|w| self.snaps(w.id) && !gesture.initial.iter().any(|(id, _)| *id == w.id))
                .flat_map(|w| {
                    candidates(
                        rect,
                        w.world_rect,
                        gesture.options,
                        horizontal,
                        gesture.same_edge,
                        gesture.center,
                    )
                })
                .flatten(),
            gesture.options.threshold,
        )
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
        for &(id, rect) in updates {
            self.stage
                .window_mut(id)
                .expect("validated gesture member")
                .world_rect = rect;
        }
        Ok(())
    }
}
