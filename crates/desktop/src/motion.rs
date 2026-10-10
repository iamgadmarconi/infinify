// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/viewport_animation.rs (drift_pan_on, launch_momentum_on,
// MOMENTUM_LAUNCH_DELAY, cancel_animations_on, tick_scroll_momentum_on,
// tick_edge_pan_on), src/state/edge_pan.rs (the request, shared_edges_at,
// effective_edge_pan_velocity), src/grabs/move_grab.rs (edge_pan_velocity,
// update_edge_pan, and the grab placing its window again once the camera has
// panned under the pointer), src/grabs/pan_grab.rs (mouse_speed and the launch
// on release), src/input/mod.rs (cursor_edge_pan_velocity,
// refresh_cursor_edge_pan), src/input/pointer.rs (on_pointer_axis:
// trackpad_speed on a scroll pan and the wheel zoom),
// src/input/gestures/pinch.rs (the pinch zoom and its end snap) and
// src/input/actions.rs (ToggleCursorPan). Momentum itself is not adapted: it
// is driftwm-core's `canvas::MomentumState`, upstream's own code. The pointer
// is a global screen point the shell reports and is never warped, outputs meet
// where their `screen_bounds` do, and the frame clock is `tick_navigation`'s.
// A trackpad gesture (gestures.rs) comes through here too, as upstream's does:
// its swipe pan is `drift_pan` and `pan_end`, its pinch zoom is `pinch_begin`,
// `pinch_update` and `pinch_end`, and its move arms the drag's edge pan.
use super::navigation::{Anchor, ViewFlight};
use super::*;
use driftwm_canvas::policy;
use driftwm_core::canvas::MomentumState;
use serde::de::Error as _;
use std::time::Duration;

/// Upstream MOMENTUM_LAUNCH_DELAY: upstream's own timer launches momentum this
/// long after the last pan event, emptying the velocity tracker.
const MOMENTUM_LAUNCH_DELAY_MS: u32 = 50;
const EDGE_LEFT: u8 = 1 << 0;
const EDGE_RIGHT: u8 = 1 << 1;
const EDGE_TOP: u8 = 1 << 2;
const EDGE_BOTTOM: u8 = 1 << 3;

/// What moved the camera: upstream scales a scroll by `trackpad_speed`
/// whatever its axis source and a click-drag by `mouse_speed`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PanSource {
    Finger,
    Wheel,
    Continuous,
    Drag,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ZoomSource {
    Wheel,
    Pinch,
}
/// Where a pinch event sits in its gesture. Absent is an update.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PinchPhase {
    Begin,
    Update,
    End,
}

/// An event time as upstream's u32 milliseconds. A shell clock is seconds since
/// boot as a double, so a fraction is dropped and a value past 2^32 wraps, as
/// libinput's millisecond clock does; the velocity tracker subtracts wrapping.
pub(crate) fn time_ms<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<u32>, D::Error> {
    match Option::<f64>::deserialize(deserializer)? {
        None => Ok(None),
        Some(time) if time.is_finite() && time >= 0.0 => Ok(Some(time as u64 as u32)),
        Some(_) => Err(D::Error::custom("invalid time_ms")),
    }
}

/// One output's scroll momentum.
#[derive(Clone)]
struct Coast {
    state: MomentumState,
    /// Event time of the last timed pan since the last launch or stop:
    /// upstream's pending auto-launch, less its delay.
    pending_ms: Option<u32>,
    /// A drag pan holds the pointer, as upstream's PanGrab does.
    panning: bool,
}
impl std::fmt::Debug for Coast {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Coast")
            .field("velocity", &self.state.velocity)
            .field("coasting", &self.state.coasting)
            .field("drift", &self.state.drift)
            .field("pending_ms", &self.pending_ms)
            .field("panning", &self.panning)
            .finish_non_exhaustive()
    }
}
/// Upstream's per-output edge-pan request: screen points per frame, and the
/// output-local pointer position it was computed at.
#[derive(Clone, Copy, Debug, Serialize)]
struct EdgePan {
    velocity: Point,
    screen: Point,
    /// The monitor-facing edges being held back and the frame time, in
    /// nanoseconds, at which the pointer reached them.
    #[serde(skip)]
    delay: Option<(u8, u64)>,
}
/// A pinch between its begin and its end: upstream's PinchZoom state.
#[derive(Clone, Copy, Debug, Serialize)]
pub(crate) struct Pinch {
    output: OutputId,
    initial_zoom: f64,
    min_zoom: f64,
    /// The gesture's scale less one: the sum of a `zoom_by` pinch's deltas.
    pub(crate) scale: f64,
}
/// Camera motion that is not a flight. Runtime state: never saved.
#[derive(Clone, Debug, Default)]
pub(crate) struct Motion {
    momentum: BTreeMap<OutputId, Coast>,
    edge_pans: BTreeMap<OutputId, EdgePan>,
    /// Upstream's runtime `cursor_edge_pan` flag.
    pub(crate) cursor_pan: bool,
    /// The last reported pointer: its output and its global screen point.
    pointer: Option<(OutputId, Point)>,
    /// The pinch a `zoom_by` began. A trackpad gesture keeps its own.
    pinch: Option<Pinch>,
}
impl Motion {
    /// An output that was removed or registered again starts with none of it.
    pub(crate) fn forget(&mut self, output: OutputId) {
        self.momentum.remove(&output);
        self.edge_pans.remove(&output);
        self.pointer = self.pointer.filter(|(at, _)| *at != output);
        self.pinch = self.pinch.filter(|pinch| pinch.output != output);
    }
    /// Upstream reload_config: a new `navigation.drift` reaches a coast in progress.
    pub(crate) fn set_drift(&mut self, drift: f64) {
        for coast in self.momentum.values_mut() {
            coast.state.drift = drift;
        }
    }
    pub(crate) fn clear_edge_pan(&mut self, output: OutputId) {
        self.edge_pans.remove(&output);
    }
    /// A pan has the pointer, for `hover`. A drag pan whose button is still
    /// down is upstream's PanGrab. A timed pan whose momentum is yet to launch
    /// is a scroll still under the fingers, or just let go: upstream's own
    /// timer launches it MOMENTUM_LAUNCH_DELAY after the last pan event, so at
    /// `now_ms`, a time on the pans' own event clock, a launch that late has
    /// happened there whether or not a `pan_end` reached this controller.
    /// Without a time it is pending until `pan_end` or a stop. A coast, an
    /// edge pan and a `zoom_by` pinch hold nothing.
    pub(crate) fn holds_pointer(&self, now_ms: Option<u32>) -> bool {
        self.momentum.values().any(|coast| {
            coast.panning
                || coast.pending_ms.is_some_and(|last| {
                    now_ms.is_none_or(|now| now.wrapping_sub(last) < MOMENTUM_LAUNCH_DELAY_MS)
                })
        })
    }
    /// The outputs whose cameras are coasting.
    pub(crate) fn coasting(&self) -> Vec<OutputId> {
        self.momentum
            .iter()
            .filter(|(_, coast)| coast.state.coasting)
            .map(|(output, _)| *output)
            .collect()
    }
    /// The snapshot's `navigation.momentum`, `edge_pans`, `cursor_pan` and `pinch`.
    pub(crate) fn snapshot(&self) -> [(&'static str, Value); 4] {
        let momentum: BTreeMap<OutputId, Value> = self
            .momentum
            .iter()
            .map(|(output, coast)| {
                let velocity = Point::new(coast.state.velocity.x, coast.state.velocity.y);
                (
                    *output,
                    json!({"coasting":coast.state.coasting,"velocity":velocity,"panning":coast.panning}),
                )
            })
            .collect();
        [
            ("momentum", json!(momentum)),
            ("edge_pans", json!(self.edge_pans)),
            (
                "cursor_pan",
                json!({"enabled":self.cursor_pan,"needs_pointer":self.cursor_pan}),
            ),
            ("pinch", json!(self.pinch)),
        ]
    }
}

/// Upstream MoveGrab::edge_pan_velocity: the deeper the pointer sits in the
/// zone the faster, like a joystick. None outside the zone.
fn edge_pan_velocity(
    screen: Point,
    size: Size,
    zone: f64,
    pan_min: f64,
    pan_max: f64,
) -> Option<Point> {
    let dist_left = screen.x;
    let dist_right = size.width - screen.x;
    let dist_top = screen.y;
    let dist_bottom = size.height - screen.y;
    let min_dist = dist_left.min(dist_right).min(dist_top).min(dist_bottom);
    if min_dist >= zone {
        return None;
    }
    // Depth into the zone: 0 at its boundary, 1 at the output's edge.
    let t = ((zone - min_dist) / zone).clamp(0.0, 1.0);
    let speed = pan_min + (pan_max - pan_min) * t * t;
    let mut vx = 0.0;
    let mut vy = 0.0;
    if dist_left < zone {
        vx -= speed * ((zone - dist_left) / zone);
    }
    if dist_right < zone {
        vx += speed * ((zone - dist_right) / zone);
    }
    if dist_top < zone {
        vy -= speed * ((zone - dist_top) / zone);
    }
    if dist_bottom < zone {
        vy += speed * ((zone - dist_bottom) / zone);
    }
    // A corner must not pan √2 faster.
    let len = (vx * vx + vy * vy).sqrt();
    if len > speed {
        vx = vx / len * speed;
        vy = vy / len * speed;
    }
    Some(Point::new(vx, vy))
}
/// Upstream cursor_edge_pan_velocity: a constant speed while the bare pointer
/// sits within `zone` of an edge of the usable area, and nothing outside that
/// area, so a reserved strip such as the menu bar never pans.
fn cursor_edge_pan_velocity(screen: Point, usable: Rect, zone: f64, speed: f64) -> Option<Point> {
    let (left, top, right, bottom) = (
        usable.origin.x,
        usable.origin.y,
        usable.right(),
        usable.bottom(),
    );
    if screen.x < left || screen.x > right || screen.y < top || screen.y > bottom {
        return None;
    }
    let mut vx: f64 = 0.0;
    let mut vy: f64 = 0.0;
    if screen.x - left < zone {
        vx -= 1.0;
    }
    if right - screen.x < zone {
        vx += 1.0;
    }
    if screen.y - top < zone {
        vy -= 1.0;
    }
    if bottom - screen.y < zone {
        vy += 1.0;
    }
    let len = (vx * vx + vy * vy).sqrt();
    if len == 0.0 {
        return None;
    }
    Some(Point::new(vx / len * speed, vy / len * speed))
}
/// Upstream shared_edges_at: the sides of `bounds` that touch `other` at the
/// output-local point `screen`. Spans are half-open and need a real overlap,
/// so outputs meeting only at a corner share nothing.
fn shared_edges_at(bounds: Rect, screen: Point, other: Rect) -> u8 {
    let (left, right, top, bottom) = (
        bounds.origin.x,
        bounds.right(),
        bounds.origin.y,
        bounds.bottom(),
    );
    let (other_left, other_right, other_top, other_bottom) = (
        other.origin.x,
        other.right(),
        other.origin.y,
        other.bottom(),
    );
    let layout = bounds.origin + screen;
    let on_shared_vertical_span =
        top.max(other_top) <= layout.y && layout.y < bottom.min(other_bottom);
    let on_shared_horizontal_span =
        left.max(other_left) <= layout.x && layout.x < right.min(other_right);
    let mut edges = 0;
    if on_shared_vertical_span && left == other_right {
        edges |= EDGE_LEFT;
    }
    if on_shared_vertical_span && right == other_left {
        edges |= EDGE_RIGHT;
    }
    if on_shared_horizontal_span && top == other_bottom {
        edges |= EDGE_TOP;
    }
    if on_shared_horizontal_span && bottom == other_top {
        edges |= EDGE_BOTTOM;
    }
    edges
}

impl Controller {
    fn coast(&mut self, output: OutputId) -> &mut Coast {
        let drift = self.config().drift;
        self.motion.momentum.entry(output).or_insert_with(|| Coast {
            state: MomentumState::new(drift),
            pending_ms: None,
            panning: false,
        })
    }
    /// Upstream `momentum.stop()`: the velocity, the samples behind it and a
    /// launch still pending for them.
    pub(crate) fn stop_momentum(&mut self, output: OutputId) {
        if let Some(coast) = self.motion.momentum.get_mut(&output) {
            coast.state.stop();
            coast.pending_ms = None;
        }
    }
    /// Upstream cancel_animations_on: the flight and the momentum feeding it.
    pub(crate) fn cancel_animations(&mut self, output: OutputId) {
        self.flights.remove(&output);
        self.stop_momentum(output);
    }
    /// `cancel_navigation` is upstream's cancel_animations_on, and the shell's
    /// answer to a press: a drag pan whose release was never reported stops
    /// holding the pointer too.
    pub(crate) fn cancel_navigation(&mut self, output: OutputId) {
        self.cancel_animations(output);
        if let Some(coast) = self.motion.momentum.get_mut(&output) {
            coast.panning = false;
        }
    }
    /// Upstream cancel_animations_everywhere, as a grab install needs.
    pub(crate) fn cancel_animations_everywhere(&mut self) {
        self.flights.clear();
        for coast in self.motion.momentum.values_mut() {
            coast.state.stop();
            coast.pending_ms = None;
        }
    }
    /// The gesture is over, however it ended. Upstream's move grab clears its
    /// output's edge pan on release and on unset, a pinned window's included.
    pub(crate) fn drop_gesture(&mut self) {
        if let Some(Gesture::Drag { output, .. } | Gesture::Pinned(PinnedDrag { output, .. })) =
            self.gesture.take()
        {
            self.motion.clear_edge_pan(output);
        }
    }
    pub(crate) fn needs_frames(&self) -> bool {
        !self.flights.is_empty()
            || !self.motion.edge_pans.is_empty()
            || self.motion.momentum.values().any(|c| c.state.coasting)
    }

    /// Upstream drift_pan_on, for a pan that carries its event time. The
    /// screen delta is scaled as upstream scales its source, becomes a world
    /// delta at the current zoom, feeds the velocity tracker and moves the
    /// camera. The flight, its anchor and a zoom-to-fit return end.
    pub(crate) fn drift_pan(
        &mut self,
        output: OutputId,
        screen_delta: Point,
        time_ms: u32,
        source: Option<PanSource>,
    ) -> Result<(), Error> {
        if !point_valid(screen_delta) {
            return Err(Error::Invalid("invalid pan delta"));
        }
        let mut viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .clone();
        let drag = source == Some(PanSource::Drag);
        // Upstream's scroll arm drops an event that scrolls nothing; a drag
        // event that has not moved is still a sample.
        if !drag && screen_delta == Point::default() {
            return Ok(());
        }
        let config = self.config();
        let speed = match source {
            Some(PanSource::Drag) => config.mouse_speed,
            Some(PanSource::Finger | PanSource::Wheel | PanSource::Continuous) => {
                config.trackpad_speed
            }
            None => 1.0,
        };
        let delta = Point::new(
            screen_delta.x * speed / viewport.zoom,
            screen_delta.y * speed / viewport.zoom,
        );
        self.flights.remove(&output);
        self.overview_returns.remove(&output);
        let coast = self.coast(output);
        // Upstream's timer has launched by now, into a held grab or under
        // resting fingers, and a launch empties the tracker: what moved before
        // the rest is no part of the next fling.
        if coast
            .pending_ms
            .is_some_and(|last| time_ms.wrapping_sub(last) >= MOMENTUM_LAUNCH_DELAY_MS)
        {
            coast.state.tracker.clear();
        }
        coast.state.accumulate((delta.x, delta.y).into(), time_ms);
        coast.pending_ms = Some(time_ms);
        coast.panning |= drag;
        viewport.camera = viewport.camera + delta;
        self.scene.update_output(viewport)?;
        self.sync_output(output)
    }
    /// Upstream launch_momentum_on: the fingers lifted or the button was
    /// released. Upstream's own timer launches MOMENTUM_LAUNCH_DELAY after the
    /// last pan event and empties the tracker, so a release later than that
    /// launches nothing. Given the end event's own time, the same holds here:
    /// a hand that had already stopped flings nothing when it lets go.
    pub(crate) fn pan_end(
        &mut self,
        output: OutputId,
        time_ms: Option<u32>,
    ) -> Result<Value, Error> {
        if self.scene.output(output).is_none() {
            return Err(Error::Invalid("unknown output"));
        }
        // An output no timed pan has moved has nothing to launch.
        if let Some(coast) = self.motion.momentum.get_mut(&output) {
            if let (Some(now), Some(last)) = (time_ms, coast.pending_ms)
                && now.wrapping_sub(last) >= MOMENTUM_LAUNCH_DELAY_MS
            {
                coast.state.tracker.clear();
            }
            coast.state.launch();
            coast.pending_ms = None;
            coast.panning = false;
        }
        Ok(json!({"needs_frames":self.needs_frames()}))
    }

    /// The output's viewport moved by a world delta, or None when it would
    /// leave the world: a frame must never fail on a pose it cannot apply, or
    /// every later frame would fail with it.
    fn panned(&self, output: OutputId, delta: Point) -> Result<Option<Viewport>, Error> {
        let mut viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .clone();
        viewport.camera = viewport.camera + delta;
        let size = viewport.screen_bounds.size;
        let far = viewport.camera + Point::new(size.width, size.height) / viewport.zoom;
        Ok((point_valid(viewport.camera) && point_valid(far)).then_some(viewport))
    }
    /// Upstream tick_scroll_momentum_on. Upstream's guard for a held PanGrab
    /// has no counterpart: a `pan_end` is taken for that grab's release, so
    /// the shell sends none for a scroll while a drag pan is held.
    pub(crate) fn tick_momentum(&mut self, output: OutputId, dt: Duration) -> Result<(), Error> {
        let Some(delta) = self
            .motion
            .momentum
            .get_mut(&output)
            .and_then(|coast| coast.state.tick(dt))
        else {
            return Ok(());
        };
        match self.panned(output, Point::new(delta.x, delta.y))? {
            Some(viewport) => {
                self.scene.update_output(viewport)?;
                self.sync_output(output)
            }
            None => {
                self.stop_momentum(output);
                Ok(())
            }
        }
    }

    fn update_edge_pan_request(
        &mut self,
        output: OutputId,
        velocity: Option<Point>,
        screen: Point,
    ) {
        match velocity {
            Some(velocity) => {
                let delay = self.motion.edge_pans.get(&output).and_then(|r| r.delay);
                self.motion.edge_pans.insert(
                    output,
                    EdgePan {
                        velocity,
                        screen,
                        delay,
                    },
                );
            }
            None => self.motion.clear_edge_pan(output),
        }
    }
    /// Upstream MoveGrab::update_edge_pan, at a window drag's pointer position
    /// local to its output. Upstream's pointer cannot leave its output without
    /// the grab following it there; here the drag stays on its output, and a
    /// pointer that has left it pans nothing.
    pub(crate) fn arm_drag_edge_pan(
        &mut self,
        output: OutputId,
        screen: Point,
    ) -> Result<(), Error> {
        let bounds = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown gesture output"))?
            .screen_bounds;
        let inside = (0.0..=bounds.size.width).contains(&screen.x)
            && (0.0..=bounds.size.height).contains(&screen.y);
        let config = self.config();
        let velocity = inside
            .then(|| {
                edge_pan_velocity(
                    screen,
                    bounds.size,
                    config.edge_zone,
                    config.edge_pan_min,
                    config.edge_pan_max,
                )
            })
            .flatten();
        self.update_edge_pan_request(output, velocity, screen);
        Ok(())
    }
    /// Upstream monitor_facing_edges_at, over the connected outputs' global bounds.
    fn monitor_facing_edges_at(&self, output: OutputId, screen: Point) -> u8 {
        let Some(bounds) = self.scene.output(output).map(|o| o.screen_bounds) else {
            return 0;
        };
        self.scene
            .outputs()
            .iter()
            .filter(|other| other.id != output)
            .fold(0, |edges, other| {
                edges | shared_edges_at(bounds, screen, other.screen_bounds)
            })
    }
    /// Upstream effective_edge_pan_velocity: a component pushing at an edge
    /// that borders another output waits `edge_pan.latency_ms`, so a pointer on
    /// its way to that output crosses instead of dragging the canvas along. An
    /// outer edge is immediate, at a mixed corner too.
    fn effective_edge_pan_velocity(&mut self, output: OutputId, now_ns: u64) -> Option<Point> {
        let latency_ns = self.config().edge_pan_latency_ms.saturating_mul(1_000_000);
        let request = *self.motion.edge_pans.get(&output)?;
        let requested = request.velocity;
        let monitor_edges = self.monitor_facing_edges_at(output, request.screen);
        let mut immediate = requested;
        let mut delayed_edges = 0;
        if requested.x < 0.0 && monitor_edges & EDGE_LEFT != 0 {
            immediate.x = 0.0;
            delayed_edges |= EDGE_LEFT;
        } else if requested.x > 0.0 && monitor_edges & EDGE_RIGHT != 0 {
            immediate.x = 0.0;
            delayed_edges |= EDGE_RIGHT;
        }
        if requested.y < 0.0 && monitor_edges & EDGE_TOP != 0 {
            immediate.y = 0.0;
            delayed_edges |= EDGE_TOP;
        } else if requested.y > 0.0 && monitor_edges & EDGE_BOTTOM != 0 {
            immediate.y = 0.0;
            delayed_edges |= EDGE_BOTTOM;
        }
        let slot = self.motion.edge_pans.get_mut(&output)?;
        if delayed_edges == 0 || latency_ns == 0 {
            slot.delay = None;
            return Some(requested);
        }
        let entered_at = match slot.delay {
            Some((edges, entered_at)) if edges == delayed_edges => entered_at,
            _ => {
                slot.delay = Some((delayed_edges, now_ns));
                now_ns
            }
        };
        if now_ns.saturating_sub(entered_at) >= latency_ns {
            Some(requested)
        } else if immediate.x != 0.0 || immediate.y != 0.0 {
            Some(immediate)
        } else {
            None
        }
    }
    /// Upstream tick_edge_pan_on. The velocity is screen points per frame, not
    /// per second. Where upstream warps the grabbed pointer by the same world
    /// delta and its move grab places the window under it and arms the pan
    /// again, the drag's window is carried by that delta, so it stays under
    /// the held pointer, and the request becomes the drag's own.
    pub(crate) fn tick_edge_pan(&mut self, output: OutputId, now_ns: u64) -> Result<(), Error> {
        let Some(velocity) = self.effective_edge_pan_velocity(output, now_ns) else {
            return Ok(());
        };
        let held =
            matches!(self.gesture, Some(Gesture::Drag { output: held, .. }) if held == output);
        let zoom = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .zoom;
        let delta = Point::new(velocity.x / zoom, velocity.y / zoom);
        // A pan that cannot be applied is disarmed, not retried every frame.
        let Some(viewport) = self.panned(output, delta)? else {
            self.motion.clear_edge_pan(output);
            return Ok(());
        };
        if held && let Some(Gesture::Drag { carried, .. }) = self.gesture.as_mut() {
            let before = *carried;
            *carried = before + delta;
            // A window that cannot follow leaves the camera where it is.
            if self.drive_gesture().is_err() {
                if let Some(Gesture::Drag { carried, .. }) = self.gesture.as_mut() {
                    *carried = before;
                }
                self.motion.clear_edge_pan(output);
                return Ok(());
            }
        }
        self.scene.update_output(viewport)?;
        self.sync_output(output)?;
        match self.motion.edge_pans.get(&output) {
            Some(request) if held => self.arm_drag_edge_pan(output, request.screen),
            _ => Ok(()),
        }
    }

    /// Upstream refresh_cursor_edge_pan: arm the pointer's output from where
    /// the pointer is now, and disarm every other output.
    pub(crate) fn refresh_cursor_edge_pan(&mut self) {
        // A grab owns the request: a window move arms its own, and a resize
        // or a drag pan leaves it as it stood when the button went down.
        if self.gesture.is_some() || self.motion.momentum.values().any(|c| c.panning) {
            return;
        }
        if !self.motion.cursor_pan {
            return;
        }
        let active = self
            .motion
            .pointer
            .filter(|(output, _)| self.scene.output(*output).is_some());
        self.motion
            .edge_pans
            .retain(|output, _| active.is_some_and(|(at, _)| at == *output));
        let Some((output, pointer)) = active else {
            return;
        };
        let (Some(viewport), Ok(context)) =
            (self.scene.output(output), self.navigation_context(output))
        else {
            return;
        };
        let screen = pointer - viewport.screen_bounds.origin;
        let config = self.config();
        let velocity = cursor_edge_pan_velocity(
            screen,
            context.usable_rect_local,
            config.edge_pan_cursor_zone,
            config.edge_pan_max,
        );
        self.update_edge_pan_request(output, velocity, screen);
    }
    /// The pointer's output and global position. Only cursor edge pan reads
    /// it, so it is kept only while that is on.
    pub(crate) fn report_pointer(
        &mut self,
        output: Option<OutputId>,
        screen: Point,
    ) -> Result<Value, Error> {
        if !point_valid(screen) {
            return Err(Error::Invalid("invalid screen point"));
        }
        if output.is_some_and(|output| self.scene.output(output).is_none()) {
            return Err(Error::Invalid("unknown output"));
        }
        if self.motion.cursor_pan {
            self.motion.pointer = output.map(|output| (output, screen));
            self.refresh_cursor_edge_pan();
        }
        Ok(json!({"needs_pointer":self.motion.cursor_pan,"needs_frames":self.needs_frames()}))
    }
    /// Upstream ToggleCursorPan: flip the runtime flag, and stop every edge
    /// pan in progress when it goes off. The pointer is asked for afresh.
    pub(crate) fn toggle_cursor_pan(&mut self) {
        self.motion.cursor_pan = !self.motion.cursor_pan;
        self.motion.pointer = None;
        if !self.motion.cursor_pan {
            self.motion.edge_pans.clear();
        }
    }

    pub(crate) fn zoom_by(
        &mut self,
        output: OutputId,
        anchor: Point,
        delta: f64,
        source: ZoomSource,
        phase: Option<PinchPhase>,
    ) -> Result<Value, Error> {
        if !point_valid(anchor) || !delta.is_finite() {
            return Err(Error::Invalid("invalid zoom anchor or delta"));
        }
        let navigation = match source {
            ZoomSource::Wheel => self.wheel_zoom(output, anchor, delta)?,
            ZoomSource::Pinch => {
                self.pinch_zoom(output, anchor, delta, phase)?;
                Value::Null
            }
        };
        Ok(json!({"navigation":navigation,"needs_frames":self.needs_frames()}))
    }
    /// Upstream on_pointer_axis, the Zoom arm: `delta` is upstream's vertical
    /// axis amount, and `zoom.step ^ (-delta / 30 · zoom.mouse_speed)` scales
    /// the zoom the output is already heading for. The zoom animates around
    /// the world point under the pointer; nothing snaps to 1.
    fn wheel_zoom(&mut self, output: OutputId, anchor: Point, delta: f64) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let config = self.config();
        let steps = -delta / 30.0 * config.zoom_mouse_speed;
        let factor = config.zoom_step.powf(steps);
        let base = self
            .flights
            .get(&output)
            .and_then(|flight| flight.zoom_target)
            .unwrap_or(viewport.zoom);
        let target = (base * factor).clamp(self.min_zoom(usable)?, policy::MAX_ZOOM);
        if delta == 0.0 || target == base || target.is_nan() {
            return Ok(Value::Null);
        }
        let screen = anchor - viewport.screen_bounds.origin;
        let anchor = Anchor {
            canvas: viewport.camera + screen / viewport.zoom,
            screen,
        };
        let camera = policy::zoom_anchor_camera(anchor.canvas, screen, target);
        // As arm_view: a destination no frame could apply is never armed.
        let size = viewport.screen_bounds.size;
        if !point_valid(camera)
            || !point_valid(camera + Point::new(size.width, size.height) / target)
        {
            return Err(Error::Invalid("navigation target out of bounds"));
        }
        self.next_navigation = self
            .next_navigation
            .checked_add(1)
            .ok_or(Error::Invalid("navigation generations exhausted"))?;
        self.overview_returns.remove(&output);
        self.stop_momentum(output);
        self.flights.insert(
            output,
            ViewFlight {
                camera_target: None,
                zoom_target: Some(target),
                zoom_animation_anchor: Some(anchor),
                generation: self.next_navigation,
            },
        );
        Ok(
            json!({"output":output,"generation":self.next_navigation,"target_camera":camera,"target_zoom":target,"animating":true}),
        )
    }
    /// Upstream on_gesture_pinch_begin: the flight and momentum stop, and the
    /// gesture remembers the zoom it starts at and the dynamic minimum of that
    /// moment.
    pub(crate) fn pinch_begin(&mut self, output: OutputId) -> Result<Pinch, Error> {
        let usable = self.navigation_context(output)?.usable_rect_local;
        let initial_zoom = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .zoom;
        let min_zoom = self.min_zoom(usable)?;
        self.cancel_animations(output);
        Ok(Pinch {
            output,
            initial_zoom,
            min_zoom,
            scale: 0.0,
        })
    }
    /// Upstream on_gesture_pinch_update, for a gesture whose scale is one plus
    /// `pinch.scale`: `initial_zoom · (1 + (scale - 1) · zoom.trackpad_speed)`,
    /// held between the gesture's minimum and 1, applied at once around the
    /// global screen point `anchor`. True when the zoom changed.
    pub(crate) fn pinch_update(&mut self, pinch: Pinch, anchor: Point) -> Result<bool, Error> {
        let current = self
            .scene
            .output(pinch.output)
            .ok_or(Error::Invalid("unknown output"))?
            .zoom;
        let scaled = 1.0 + pinch.scale * self.config().zoom_trackpad_speed;
        let zoom = (pinch.initial_zoom * scaled).clamp(pinch.min_zoom, policy::MAX_ZOOM);
        if zoom == current {
            return Ok(false);
        }
        self.overview_returns.remove(&pinch.output);
        self.scene.zoom_at(pinch.output, zoom, anchor)?;
        self.sync_output(pinch.output)?;
        Ok(true)
    }
    /// Upstream on_gesture_pinch_end: a zoom within 0.05 of 1 snaps onto it,
    /// around `anchor`. True when it did.
    pub(crate) fn pinch_end(&mut self, output: OutputId, anchor: Point) -> Result<bool, Error> {
        let current = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .zoom;
        let snapped = policy::snap_zoom(current);
        if snapped == current {
            return Ok(false);
        }
        self.scene.zoom_at(output, snapped, anchor)?;
        self.sync_output(output)?;
        Ok(true)
    }
    /// Upstream's pinch gesture as `zoom_by` sends it, one event at a time.
    /// `delta` is the change in the gesture's scale, so the scale upstream
    /// reads is one plus the deltas since `begin`. `end` applies its own delta
    /// and then snaps. An event outside a begun gesture is a whole gesture of
    /// its own, less the snap.
    fn pinch_zoom(
        &mut self,
        output: OutputId,
        anchor: Point,
        delta: f64,
        phase: Option<PinchPhase>,
    ) -> Result<(), Error> {
        // Refused during a drag or resize gesture, as every flight is.
        self.view(output)?;
        let held = self.motion.pinch.filter(|pinch| pinch.output == output);
        let mut pinch = match held {
            Some(pinch) if phase != Some(PinchPhase::Begin) => pinch,
            _ => self.pinch_begin(output)?,
        };
        pinch.scale += delta;
        self.pinch_update(pinch, anchor)?;
        match phase {
            Some(PinchPhase::End) => {
                self.pinch_end(output, anchor)?;
                self.motion.pinch = self.motion.pinch.filter(|held| held.output != output);
            }
            Some(PinchPhase::Begin) => self.motion.pinch = Some(pinch),
            Some(PinchPhase::Update) | None => {
                if held.is_some() {
                    self.motion.pinch = Some(pinch);
                }
            }
        }
        Ok(())
    }
}
