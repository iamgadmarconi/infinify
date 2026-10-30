// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm src/canvas.rs at
// 352333a8fa1b22171492d4b71a54102045c9a19d (GPL-3.0-or-later).
//! Pure upstream camera, selection, and momentum policies, without Scene mutation.
//!
//! Integer geometry preserves upstream rounding and arithmetic boundaries.
//! Callers must provide meaningful viewport/zoom values and integer geometry
//! whose coordinate sums fit i32, as upstream does. These helpers deliberately
//! do not apply Scene validation or infer native window state. See POLICY.md.
use crate::Point;
use std::collections::{BTreeMap, VecDeque};
use std::time::Duration;

/// Upstream absolute minimum zoom.
pub const MIN_ZOOM_FLOOR: f64 = 0.001;
/// Upstream maximum zoom (native size).
pub const MAX_ZOOM: f64 = 1.0;
/// Navigation drift default from upstream config/mod.rs.
pub const DEFAULT_DRIFT: f64 = 0.5;

/// An integer location in upstream logical pixels (Y down).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelPoint {
    /// Horizontal location.
    pub x: i32,
    /// Vertical location.
    pub y: i32,
}
impl From<(i32, i32)> for PixelPoint {
    fn from((x, y): (i32, i32)) -> Self {
        Self { x, y }
    }
}
/// An integer extent in upstream logical pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelSize {
    /// Width.
    pub w: i32,
    /// Height.
    pub h: i32,
}
impl From<(i32, i32)> for PixelSize {
    fn from((w, h): (i32, i32)) -> Self {
        Self { w, h }
    }
}
/// Integer rectangle used by upstream fit, culling, and visibility policies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelRect {
    /// Top-left location.
    pub loc: PixelPoint,
    /// Width and height.
    pub size: PixelSize,
}
impl PixelRect {
    /// Construct raw integer geometry without adding validation policy.
    pub const fn new(loc: PixelPoint, size: PixelSize) -> Self {
        Self { loc, size }
    }
}

/// The eight directions supported by upstream directional selection.
/// Separate from Scene's existing four-direction action API.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Negative Y.
    Up,
    /// Positive Y.
    Down,
    /// Negative X.
    Left,
    /// Positive X.
    Right,
    /// Negative X and Y.
    UpLeft,
    /// Positive X and negative Y.
    UpRight,
    /// Negative X and positive Y.
    DownLeft,
    /// Positive X and Y.
    DownRight,
}
impl Direction {
    /// Normalized vector from upstream config/types.rs::Direction::to_unit_vec.
    pub fn to_unit_vec(self) -> (f64, f64) {
        use std::f64::consts::FRAC_1_SQRT_2;
        match self {
            Self::Up => (0.0, -1.0),
            Self::Down => (0.0, 1.0),
            Self::Left => (-1.0, 0.0),
            Self::Right => (1.0, 0.0),
            Self::UpLeft => (-FRAC_1_SQRT_2, -FRAC_1_SQRT_2),
            Self::UpRight => (FRAC_1_SQRT_2, -FRAC_1_SQRT_2),
            Self::DownLeft => (-FRAC_1_SQRT_2, FRAC_1_SQRT_2),
            Self::DownRight => (FRAC_1_SQRT_2, FRAC_1_SQRT_2),
        }
    }
}
fn point((x, y): (f64, f64)) -> Point {
    Point::new(x, y)
}

/// The viewport center in canvas coords, in the user-facing convention (Y-up).
/// Shared by the state file and IPC so they can't drift. Inverse of
/// [`camera_for_center`].
#[inline]
pub fn viewport_center(camera: Point, zoom: f64, viewport: PixelSize) -> (f64, f64) {
    (
        camera.x + viewport.w as f64 / (2.0 * zoom),
        -(camera.y + viewport.h as f64 / (2.0 * zoom)),
    )
}

/// The camera (internal top-left, Y-down) that centers the viewport on the Y-up
/// point `(x, y)`. Inverse of [`viewport_center`].
#[inline]
pub fn camera_for_center(x: f64, y: f64, zoom: f64, viewport: PixelSize) -> Point {
    point((
        x - viewport.w as f64 / (2.0 * zoom),
        -y - viewport.h as f64 / (2.0 * zoom),
    ))
}

/// Fraction of a rectangle's area visible in the current viewport (0.0–1.0).
/// Returns 0.0 for zero-area rectangles.
pub fn visible_fraction(
    rect_loc: PixelPoint,
    rect_size: PixelSize,
    camera: Point,
    viewport_size: PixelSize,
    zoom: f64,
) -> f64 {
    let area = rect_size.w as f64 * rect_size.h as f64;
    if area <= 0.0 {
        return 0.0;
    }

    let vw = viewport_size.w as f64 / zoom;
    let vh = viewport_size.h as f64 / zoom;

    let ix_min = (rect_loc.x as f64).max(camera.x);
    let ix_max = ((rect_loc.x + rect_size.w) as f64).min(camera.x + vw);
    let iy_min = (rect_loc.y as f64).max(camera.y);
    let iy_max = ((rect_loc.y + rect_size.h) as f64).min(camera.y + vh);

    let iw = (ix_max - ix_min).max(0.0);
    let ih = (iy_max - iy_min).max(0.0);

    (iw * ih) / area
}

/// Check whether an arbitrary canvas point is visible in the current viewport.
/// At zoom < 1.0, the visible area is larger: viewport_size / zoom. Bounds are
/// inclusive on both edges (a point exactly on an edge counts as visible).
pub fn is_point_visible(point: Point, camera: Point, viewport_size: PixelSize, zoom: f64) -> bool {
    let visible_w = viewport_size.w as f64 / zoom;
    let visible_h = viewport_size.h as f64 / zoom;
    camera.x <= point.x
        && point.x <= camera.x + visible_w
        && camera.y <= point.y
        && point.y <= camera.y + visible_h
}

/// Check whether the canvas origin (0, 0) is visible in the current viewport.
pub fn is_origin_visible(camera: Point, viewport_size: PixelSize, zoom: f64) -> bool {
    is_point_visible(point((0.0, 0.0)), camera, viewport_size, zoom)
}

/// A rival bookmark must be at least this fraction of the incumbent's distance
/// to steal the active title — 10% closer. Damps flip-flop when two bookmarks
/// sit near-equidistant from the viewport center.
const ACTIVE_BOOKMARK_HYSTERESIS: f64 = 0.9;

/// The active bookmark for one output's viewport: the visible bookmark nearest
/// the usable-area center, with hysteresis favoring the incumbent (see
/// `ACTIVE_BOOKMARK_HYSTERESIS`). Ties break by name (BTreeMap order); `None`
/// when no bookmark is visible.
///
/// `bookmarks` are stored Y-up (user/rule/IPC convention) while the camera is
/// internal Y-down, so each bookmark's y is negated before comparison — the
/// same flip `go_to_canvas_point` applies. `usable_center` is the screen-space
/// center of the usable area (panels excluded, as `SetBookmark` uses); the
/// canvas-space target is `camera + usable_center / zoom`.
pub fn active_bookmark(
    bookmarks: &BTreeMap<String, [f64; 2]>,
    camera: Point,
    viewport_size: PixelSize,
    zoom: f64,
    usable_center: Point,
    incumbent: Option<&str>,
) -> Option<String> {
    let target = point((
        camera.x + usable_center.x / zoom,
        camera.y + usable_center.y / zoom,
    ));

    let mut best: Option<(&str, f64)> = None;
    let mut incumbent_dist: Option<f64> = None;
    for (name, &[x, y]) in bookmarks {
        let point = point((x, -y));
        if !is_point_visible(point, camera, viewport_size, zoom) {
            continue;
        }
        let dx = point.x - target.x;
        let dy = point.y - target.y;
        let dist = (dx * dx + dy * dy).sqrt();
        if incumbent == Some(name.as_str()) {
            incumbent_dist = Some(dist);
        }
        if best.is_none_or(|(_, d)| dist < d) {
            best = Some((name.as_str(), dist));
        }
    }

    let (best_name, best_dist) = best?;
    if let (Some(inc), Some(inc_dist)) = (incumbent, incumbent_dist) {
        // Incumbent still visible: keep it unless a rival is decisively closer.
        if best_name != inc && best_dist < ACTIVE_BOOKMARK_HYSTERESIS * inc_dist {
            return Some(best_name.to_owned());
        }
        return Some(inc.to_owned());
    }
    Some(best_name.to_owned())
}

/// The canvas rectangle visible at the current camera + zoom.
/// Used to cull windows outside the viewport for `render_elements_for_region`.
///
/// `camera_i32` must be `camera.to_i32_round()` — the same rounding used by
/// `update_output_from_camera` — so that element position offsets match the
/// output mapping used for input hit-testing.
pub fn visible_canvas_rect(
    camera_i32: PixelPoint,
    viewport_size: PixelSize,
    zoom: f64,
) -> PixelRect {
    let w = (viewport_size.w as f64 / zoom).ceil() as i32 + 2;
    let h = (viewport_size.h as f64 / zoom).ceil() as i32 + 2;
    PixelRect::new(camera_i32, (w, h).into())
}

/// Bounding box of all windows. Returns None if the iterator is empty.
pub fn all_windows_bbox(
    windows: impl Iterator<Item = (PixelPoint, PixelSize)>,
) -> Option<PixelRect> {
    let mut min_x = i32::MAX;
    let mut min_y = i32::MAX;
    let mut max_x = i32::MIN;
    let mut max_y = i32::MIN;
    let mut any = false;

    for (loc, size) in windows {
        any = true;
        min_x = min_x.min(loc.x);
        min_y = min_y.min(loc.y);
        max_x = max_x.max(loc.x + size.w);
        max_y = max_y.max(loc.y + size.h);
    }

    if any {
        Some(PixelRect::new(
            (min_x, min_y).into(),
            (max_x - min_x, max_y - min_y).into(),
        ))
    } else {
        None
    }
}

/// Zoom level that fits `bbox` inside `viewport` with `padding` viewport pixels
/// on each side. Padding is screen-space so the gutter stays constant regardless
/// of the resulting zoom.
/// Clamped to [MIN_ZOOM_FLOOR, MAX_ZOOM] — zooms out as far as needed to fit.
pub fn zoom_to_fit(bbox: PixelRect, viewport_size: PixelSize, padding: f64) -> f64 {
    let avail_w = (viewport_size.w as f64 - padding * 2.0).max(1.0);
    let avail_h = (viewport_size.h as f64 - padding * 2.0).max(1.0);
    let zoom_x = avail_w / bbox.size.w.max(1) as f64;
    let zoom_y = avail_h / bbox.size.h.max(1) as f64;
    zoom_x.min(zoom_y).clamp(MIN_ZOOM_FLOOR, MAX_ZOOM)
}

/// Dynamic minimum zoom based on the current window layout.
/// Uses a virtual 5x5 window at the origin as baseline when no windows exist,
/// so the limit stays consistent as the first window appears.
pub fn dynamic_min_zoom(
    windows: impl Iterator<Item = (PixelPoint, PixelSize)>,
    viewport_size: PixelSize,
    padding: f64,
) -> f64 {
    let bbox =
        all_windows_bbox(windows).unwrap_or_else(|| PixelRect::new((-2, -2).into(), (5, 5).into()));
    // Allow zooming out to 50% beyond the fit zoom for breathing room
    let fit = zoom_to_fit(bbox, viewport_size, padding);
    (fit * 0.5).max(MIN_ZOOM_FLOOR)
}

/// Camera position that keeps `anchor_canvas` at `anchor_screen` after a zoom change.
/// Derived from: screen = (canvas - camera) * zoom  ⟹  camera = canvas - screen / zoom.
pub fn zoom_anchor_camera(anchor_canvas: Point, anchor_screen: Point, new_zoom: f64) -> Point {
    point((
        anchor_canvas.x - anchor_screen.x / new_zoom,
        anchor_canvas.y - anchor_screen.y / new_zoom,
    ))
}

/// Snap zoom to 1.0 if within ±0.05 dead zone (avoids stuck-near-1.0 feel).
pub fn snap_zoom(z: f64) -> f64 {
    if (z - 1.0).abs() < 0.05 { 1.0 } else { z }
}

/// Closest point on an axis-aligned rect to `origin`.
/// If origin is inside the rect, returns origin itself (distance 0).
///
/// v0.21.0 (third_party/driftwm/src/canvas.rs closest_point_on_rect): the far
/// edge is summed in f64. An i32 sum can wrap below `loc`, and `f64::clamp`
/// panics on min > max.
pub fn closest_point_on_rect(origin: Point, loc: PixelPoint, size: PixelSize) -> Point {
    point((
        origin.x.clamp(loc.x as f64, loc.x as f64 + size.w as f64),
        origin.y.clamp(loc.y as f64, loc.y as f64 + size.h as f64),
    ))
}

/// Find the nearest item in a 90° cone from `origin` in the given direction.
///
/// Uses dot/cross product against the direction unit vector: a candidate is
/// in the cone when `dot > 0 && |cross| <= dot` (i.e. within ±45° of the
/// direction). Scores by `distance / cos(angle)` — targets aligned with the
/// exact direction are preferred even if further away.
///
/// Generic over the item type so it works with `Window` in production and
/// simple types (e.g. `&str`) in tests.
pub fn find_nearest<W: PartialEq>(
    origin: Point,
    dir: &Direction,
    items: impl Iterator<Item = (W, Point)>,
    skip: Option<&W>,
) -> Option<W> {
    let (ux, uy) = dir.to_unit_vec();
    let mut best: Option<(W, f64)> = None;

    for (item, center) in items {
        if skip.is_some_and(|s| s == &item) {
            continue;
        }
        let dx = center.x - origin.x;
        let dy = center.y - origin.y;
        let dot = dx * ux + dy * uy;
        let cross = (dx * uy - dy * ux).abs();
        if dot > 0.0 && cross <= dot {
            // score = dist² / dot ∝ dist / cos(angle), avoids sqrt
            let dist_sq = dx * dx + dy * dy;
            let score = dist_sq / dot;
            if best.as_ref().is_none_or(|(_, d)| score < *d) {
                best = Some((item, score));
            }
        }
    }

    best.map(|(w, _)| w)
}

/// Sliding-window velocity tracker for scroll/gesture input.
/// Computes launch velocity from recent displacement over a fixed time window,
/// avoiding the EMA bias where the last 1-2 events dominate.
///
/// Timestamps are libinput event times (ms), not processing time: under CPU
/// load the event loop can drain a burst of events with near-identical
/// processing times, which collapses `elapsed` and explodes the launch velocity.
/// Event times are stamped when the input occurred, so they retain real spacing.
#[derive(Clone, Default)]
pub struct VelocityTracker {
    samples: VecDeque<(u32, Point)>,
}

const VELOCITY_WINDOW_MS: u32 = 80;

impl VelocityTracker {
    /// Create an empty 80 ms displacement tracker.
    pub fn new() -> Self {
        Self::default()
    }

    /// Record an event-time sample, evicting samples older than 80 ms.
    pub fn push(&mut self, time_ms: u32, delta: Point) {
        self.samples.push_back((time_ms, delta));
        // wrapping_sub keeps eviction correct across the u32 ms wrap (~49.7 days).
        while self
            .samples
            .front()
            .is_some_and(|(t, _)| time_ms.wrapping_sub(*t) > VELOCITY_WINDOW_MS)
        {
            self.samples.pop_front();
        }
    }

    /// Total displacement / elapsed time = px/sec. Zero if < 2 samples.
    pub fn launch_velocity(&self) -> Point {
        if self.samples.len() < 2 {
            return point((0.0, 0.0));
        }
        let (Some((first_time, _)), Some((last_time, _))) =
            (self.samples.front(), self.samples.back())
        else {
            return point((0.0, 0.0));
        };
        let elapsed_ms = last_time.wrapping_sub(*first_time);
        // Event times are ms-quantized, so a sub-ms window (only reachable by a
        // sub-millisecond flick on a >1000Hz device) would divide by zero. Guard
        // the clock resolution, not a device rate: any real fling spans many ms,
        // so no device is throttled.
        if elapsed_ms == 0 {
            return point((0.0, 0.0));
        }
        let elapsed = elapsed_ms as f64 / 1000.0;
        let total: Point = self.samples.iter().fold(point((0.0, 0.0)), |acc, (_, d)| {
            point((acc.x + d.x, acc.y + d.y))
        });
        point((total.x / elapsed, total.y / elapsed))
    }

    /// Discard all samples.
    pub fn clear(&mut self) {
        self.samples.clear();
    }
}

/// Stop threshold in px/sec (15 px/sec ≈ 0.25 px/frame at 60Hz)
const MOMENTUM_STOP_THRESHOLD: f64 = 15.0;

/// Scroll momentum physics with time-based drift.
/// Velocity is in px/sec; drift is applied via `powf(dt * 60)` for
/// frame-rate independence.
#[derive(Clone)]
pub struct MomentumState {
    /// Current velocity in canvas points per second.
    pub velocity: Point,
    /// Recent input samples used at launch.
    pub tracker: VelocityTracker,
    /// Upstream drift knob; zero disables retention, one is the longest coast.
    pub drift: f64,
    /// Whether a launch is currently coasting.
    pub coasting: bool,
}

impl MomentumState {
    /// Create stopped momentum with an explicit upstream drift knob.
    pub fn new(drift: f64) -> Self {
        Self {
            velocity: point((0.0, 0.0)),
            tracker: VelocityTracker::new(),
            drift,
            coasting: false,
        }
    }

    /// Record an input delta. Resets coasting — we're receiving live input.
    /// `time_ms` is the libinput event timestamp, not processing time.
    pub fn accumulate(&mut self, delta: Point, time_ms: u32) {
        self.tracker.push(time_ms, delta);
        self.coasting = false;
    }

    /// Snapshot launch velocity from the tracker and begin coasting.
    pub fn launch(&mut self) {
        self.velocity = self.tracker.launch_velocity();
        self.coasting = true;
        self.tracker.clear();
    }

    /// Advance momentum by `dt`. Returns Some(canvas delta) to apply, or None.
    pub fn tick(&mut self, dt: Duration) -> Option<Point> {
        if !self.coasting {
            return None;
        }
        let speed = (self.velocity.x.powi(2) + self.velocity.y.powi(2)).sqrt();
        if speed < MOMENTUM_STOP_THRESHOLD {
            self.velocity = point((0.0, 0.0));
            self.coasting = false;
            return None;
        }

        let dt_secs = dt.as_secs_f64();

        // Speed-dependent drift: gentle scrolls stop quickly, fast flings coast longer
        let effective_drift = speed_dependent_drift(self.drift, speed);
        let decay = effective_drift.powf(dt_secs * 60.0);
        let delta = point((self.velocity.x * dt_secs, self.velocity.y * dt_secs));
        self.velocity = point((self.velocity.x * decay, self.velocity.y * decay));
        Some(delta)
    }

    /// Stop coasting, zero velocity, and clear the input history.
    pub fn stop(&mut self) {
        self.velocity = point((0.0, 0.0));
        self.tracker.clear();
        self.coasting = false;
    }
}

/// Per-frame velocity retention for momentum coasting, from the user's `drift`
/// knob (0 = off … 1 = floatiest) and the current `speed`.
///
/// The knob is log-spaced in coast time: each step multiplies how long a fling
/// coasts by a roughly constant factor, so the slider feels perceptually even
/// instead of cramming every usable value into 0.9–1.0. Gentle scrolls (low
/// speed) stop sooner than hard flings (high speed). The result is normalized to
/// 60fps; `tick` applies `powf(dt * 60)` for frame-rate independence.
fn speed_dependent_drift(drift: f64, speed: f64) -> f64 {
    if drift <= 0.0 {
        return 0.0; // momentum disabled
    }
    // Fling coast time as a velocity half-life (seconds), spaced geometrically
    // across the knob. Endpoints and the default (0.5) are tuned so 0.5
    // reproduces the original feel (≈0.88 slow / ≈0.965 fast retention).
    const FLING_HALFLIFE_MIN: f64 = 0.05;
    const FLING_HALFLIFE_MAX: f64 = 2.3;
    const SLOW_COAST_RATIO: f64 = 0.28; // gentle scrolls coast ~1/3.6 as long
    let fling = FLING_HALFLIFE_MIN * (FLING_HALFLIFE_MAX / FLING_HALFLIFE_MIN).powf(drift.min(1.0));
    let reference_speed = 2500.0; // px/sec; at or above this, full fling coast
    let t = (speed / reference_speed).min(1.0);
    let half_life = fling * SLOW_COAST_RATIO.powf(1.0 - t);
    // Retention that halves the velocity every `half_life` seconds.
    0.5_f64.powf(1.0 / (60.0 * half_life)).min(0.995)
}

impl Default for MomentumState {
    fn default() -> Self {
        Self::new(DEFAULT_DRIFT)
    }
}
