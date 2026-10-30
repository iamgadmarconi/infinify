// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/placement.rs (cursor_placement_pos, auto_placement_pos,
// nearest_auto_anchor, place_adjacent_to, cascade_position),
// src/handlers/compositor.rs (a new toplevel's first sized commit: adopt or
// place, then raise, focus and navigate), src/handlers/xdg_shell.rs
// (toplevel_destroyed: the stand-in conversion and the focus-follow tiers),
// src/state/suspended.rs (adoption_target, adopt_relaunched, relaunch_suspended,
// dismiss_suspended, suspend_window, mark_real_close,
// resolve_suspend_conversion, convert_to_suspended), src/state/navigation.rs
// (window_fully_in_viewport, window_intersects_viewport_on,
// nearest_visible_window_on, first_spatially_related_in_history),
// src/state/output.rs (output_for_window), src/state/mod.rs
// (AUTO_PLACE_CLUSTER_THRESHOLD) and src/ipc/mod.rs (window_by_selector,
// suspended_by_selector, cmd_close, cmd_suspend, cmd_relaunch). The placement
// search itself is not adapted: it is driftwm-core's
// `layout::auto_placement::place_auto`, upstream's own code, as are
// `layout::cluster::cluster_of` and the window rules. Native frames already
// include their title bar, so chrome is zero. A window's size is its source
// rectangle's; its position is only ever the policy's. Upstream's marks and
// pending relaunches expire by wall clock; here they lapse on the clock
// `tick_navigation` brings. `depart` also follows v0.21.0 (df3de27b, read at
// third_party/driftwm): toplevel_destroyed's release_fit_push call, after the
// spatial pick and before the visibility checks, for a real close and never
// for a stand-in conversion (sizes.rs has release_fit_push).
use super::actions::Outcome;
use super::ipc::{WindowSelector, readable};
use super::rules::Pin;
use super::view_actions::pixel_size;
use super::window_actions::IN_VIEW_NOISE;
use super::*;
use driftwm_canvas::policy::{self, PixelPoint, PixelSize};
use driftwm_core::config::{AppliedWindowRule, WindowPlacement};
use driftwm_core::layout::auto_placement::{self, place_auto};
use driftwm_core::layout::cluster::cluster_of;
use driftwm_core::layout::snap::SnapRect;
use std::collections::{BTreeSet, HashSet};

/// Upstream AUTO_PLACE_CLUSTER_THRESHOLD: the share of a window that must be in
/// view for auto placement to anchor a new window to it.
const AUTO_PLACE_CLUSTER_THRESHOLD: f64 = 0.33;
/// Upstream MARK_TTL and RELAUNCH_TTL, measured on the `tick_navigation` clock.
/// Upstream's identity match closes after five seconds because its activation
/// token covers a slow launch; there is no token here, so the match stays open
/// for as long as the relaunch is pending.
const MARK_TTL_NS: u64 = 10_000_000_000;
const RELAUNCH_TTL_NS: u64 = 30_000_000_000;

/// What the next `window_closed` of a bound window means, whatever
/// `session.suspend_on_close` says. Upstream's real-close and suspend marks;
/// the later command replaces the earlier one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CloseMark {
    /// `close-window` and IPC `Close`: the window leaves the canvas.
    Close,
    /// `suspend-window` and IPC `Suspend`: a stand-in takes its place.
    Suspend,
}
/// Which windows are stand-ins, and what is in flight around them. Only
/// `standins` is saved.
#[derive(Clone, Debug, Default, Serialize)]
pub(crate) struct Lifecycle {
    /// False until the first `adoption_complete`: the shell is still reporting
    /// the windows that were already open at launch, which are adopted or
    /// placed without being focused or revealed.
    pub(crate) settled: bool,
    /// Upstream's suspended windows: detached placeholders that stand for a
    /// window that is gone. Dormant until relaunched. A detached placeholder
    /// outside this set is a slot whose own window may still come back.
    pub(crate) standins: BTreeSet<WindowId>,
    /// Stand-ins with a relaunch in flight, oldest first.
    pub(crate) relaunching: Vec<WindowId>,
    pub(crate) marks: BTreeMap<WindowId, CloseMark>,
    /// Waiting slots whose window the last discovery pass named as still
    /// existing though it could not be offered: minimized, hidden or on
    /// another Space. Only a window with the slot's own title takes one.
    #[serde(skip_serializing_if = "BTreeSet::is_empty")]
    pub(crate) held: BTreeSet<WindowId>,
    /// The clock at which each mark and each pending relaunch was first seen.
    /// Empty for a host that never ticks the clock: nothing lapses for it.
    #[serde(skip)]
    pub(crate) marked_at: BTreeMap<WindowId, u64>,
    #[serde(skip)]
    pub(crate) relaunched_at: BTreeMap<WindowId, u64>,
}
impl Lifecycle {
    /// Drop what no longer describes the scene: a mark needs a bound window; a
    /// stand-in, a relaunch and a held slot need a detached one. Then what has
    /// lapsed at `now`, the `tick_navigation` clock.
    pub(crate) fn prune(
        &mut self,
        scene: &Scene,
        sources: &BTreeMap<WindowId, Source>,
        now: Option<u64>,
    ) {
        let detached = |id: &WindowId| scene.window(*id).is_some() && !sources.contains_key(id);
        self.standins.retain(detached);
        self.relaunching.retain(detached);
        self.held.retain(detached);
        self.marks.retain(|id, _| sources.contains_key(id));
        // Upstream sweep_marks and sweep_pending_relaunches. Every command ends
        // here, `tick_navigation` included, so nothing lapsed is ever read.
        if let Some(now) = now {
            let (marked_at, relaunched_at) = (&mut self.marked_at, &mut self.relaunched_at);
            self.marks.retain(|id, _| {
                now.saturating_sub(*marked_at.entry(*id).or_insert(now)) < MARK_TTL_NS
            });
            self.relaunching.retain(|id| {
                now.saturating_sub(*relaunched_at.entry(*id).or_insert(now)) < RELAUNCH_TTL_NS
            });
        }
        // Last, so that what just lapsed leaves no stamp for a later ask to inherit.
        let (marks, relaunching) = (&self.marks, &self.relaunching);
        self.marked_at.retain(|id, _| marks.contains_key(id));
        self.relaunched_at.retain(|id, _| relaunching.contains(id));
    }
}
/// How a new window comes onto the canvas.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Arrival {
    /// It takes over a detached slot: the slot's id, frame and stacking.
    Adopt(WindowId),
    /// It is placed by `window_placement`, or by a rule's `position`.
    /// `background` says it was tucked beside the home of a fullscreen
    /// window, which keeps the focus and the screen.
    Place {
        rect: Rect,
        at_cursor: bool,
        background: bool,
    },
    /// A `pinned_to_screen` rule fixes it to an output's screen. `rect` is the
    /// canvas frame the pin shows right now.
    Pin { rect: Rect, pin: Pin },
}
/// Who takes the focus when the window that held it leaves.
enum Follow {
    Raise(WindowId),
    Fly(WindowId, OutputId),
    Nobody,
}

/// A frame at upstream's integer boundary, or `None` when it does not fit.
fn pixel_frame(rect: Rect) -> Option<(PixelPoint, PixelSize)> {
    let fit = |value: f64| {
        let value = value.round();
        (f64::from(i32::MIN)..=f64::from(i32::MAX))
            .contains(&value)
            .then_some(value as i32)
    };
    let (x, y) = (fit(rect.origin.x)?, fit(rect.origin.y)?);
    let (w, h) = (fit(rect.size.width)?, fit(rect.size.height)?);
    x.checked_add(w)?;
    y.checked_add(h)?;
    Some(((x, y).into(), (w, h).into()))
}
fn snap_rect(rect: Rect) -> SnapRect {
    SnapRect {
        x_low: rect.origin.x,
        x_high: rect.right(),
        y_low: rect.origin.y,
        y_high: rect.bottom(),
    }
}

impl Controller {
    fn bundle(&self, window: WindowId) -> &str {
        self.metadata
            .get(&window)
            .map_or("", |m| m.bundle_id.as_str())
    }
    fn title(&self, window: WindowId) -> &str {
        self.metadata.get(&window).map_or("", |m| m.title.as_str())
    }
    /// A `[session]` flag as it resolves for one window: a matching window
    /// rule's override, else the section's value. The bundle identifier is the
    /// rule's `app_id`.
    fn session_flag(
        &self,
        window: WindowId,
        title: &str,
        default: bool,
        rule: fn(&driftwm_core::config::AppliedWindowRule) -> Option<bool>,
    ) -> bool {
        self.config()
            .resolve_window_rules(self.bundle(window), title)
            .and_then(|applied| rule(&applied))
            .unwrap_or(default)
    }

    /// The detached slot a new window of this app takes instead of being
    /// placed. Upstream's identity match first: the oldest pending relaunch of
    /// the same app. Then the macOS rule, because applications outlive the
    /// canvas: a slot that is no stand-in is still waiting for its own window.
    /// It takes the window of its app with its title, and failing that the
    /// lowest such slot takes a retitled one, unless the slot is held for a
    /// window that still exists off screen: that one answers to its own title
    /// only. A dormant stand-in takes nothing, and a window without a bundle
    /// identifier adopts nothing.
    fn adoption_target(&self, bundle_id: &str, title: &str) -> Option<WindowId> {
        if bundle_id.is_empty() {
            return None;
        }
        let slot = |id: &WindowId| !self.sources.contains_key(id) && self.bundle(*id) == bundle_id;
        if let Some(id) = self.lifecycle.relaunching.iter().copied().find(slot) {
            return Some(id);
        }
        let mut waiting: Vec<WindowId> = self
            .scene
            .windows()
            .iter()
            .map(|w| w.id)
            .filter(|id| slot(id) && !self.lifecycle.standins.contains(id))
            .collect();
        waiting.sort();
        let titled = |id: &&WindowId| self.metadata.get(*id).is_some_and(|m| m.title == title);
        let free = |id: &&WindowId| !self.lifecycle.held.contains(*id);
        waiting
            .iter()
            .find(titled)
            .or_else(|| waiting.iter().find(free))
            .copied()
    }
    /// Upstream auto_placement_pos and place_adjacent_to: a slot beside the
    /// cluster of the focused window while enough of it is in view, else of the
    /// element nearest the usable center, stand-ins included. Every window is an
    /// obstacle, widgets and screen-pinned windows excepted: they anchor and
    /// obstruct nothing. `None` is upstream's fall back to the center.
    /// Upstream's blank-slate rule (suppress_auto_anchor: after a click on
    /// empty canvas a new window is centered, not docked) is not carried over:
    /// `clear_focus` leaves the nearest element in view to anchor like any
    /// unfocused state.
    fn auto_spawn(
        &self,
        viewport: &Viewport,
        usable: Rect,
        (w, h): (f64, f64),
    ) -> Result<Option<(f64, f64)>, Error> {
        let view = pixel_size(viewport.screen_bounds.size)?;
        // Upstream anchors to canvas elements only, and place_adjacent_to
        // leaves widgets and pinned windows out of its obstacles.
        let windows: Vec<&Window> = self
            .scene
            .windows()
            .iter()
            .filter(|w| self.on_canvas(w.id))
            .collect();
        let placed: Vec<Rect> = windows.iter().map(|w| self.placed_rect(w)).collect();
        let frames: Vec<_> = placed.iter().map(|rect| pixel_frame(*rect)).collect();
        let in_view = |index: &usize| {
            frames[*index].is_some_and(|(loc, size)| {
                policy::visible_fraction(loc, size, viewport.camera, view, viewport.zoom)
                    >= AUTO_PLACE_CLUSTER_THRESHOLD
            })
        };
        let center = viewport.camera + usable.center() / viewport.zoom;
        let focused = self
            .scene
            .focused()
            .and_then(|id| windows.iter().position(|w| w.id == id))
            .filter(in_view);
        // Top to bottom, and the first minimum is kept: the topmost of
        // equally near elements wins.
        let anchor = focused.or_else(|| {
            (0..windows.len())
                .rev()
                .filter(in_view)
                .filter_map(|index| {
                    let (loc, size) = frames[index]?;
                    let closest = policy::closest_point_on_rect(center, loc, size);
                    let (dx, dy) = (closest.x - center.x, closest.y - center.y);
                    Some((index, dx * dx + dy * dy))
                })
                .min_by(|a, b| a.1.total_cmp(&b.1))
                .map(|(index, _)| index)
        });
        let Some(anchor) = anchor else {
            return Ok(None);
        };
        let rects: Vec<auto_placement::Rect> = placed
            .iter()
            .map(|rect| auto_placement::Rect {
                x: rect.origin.x.round(),
                y: rect.origin.y.round(),
                w: rect.size.width.round(),
                h: rect.size.height.round(),
            })
            .collect();
        let eligible: HashSet<usize> = (0..rects.len()).collect();
        let gap = self.config().snap_gap;
        Ok(
            place_auto(&rects, anchor, &eligible, w, h, (center.x, center.y), gap)
                .map(|(x, y)| (x.round(), y.round())),
        )
    }
    /// Upstream's placement of a new toplevel at its first sized commit:
    /// `window_placement` picks the spot (cursor_placement_pos,
    /// auto_placement_pos, else the `focus_placement` point of the navigation
    /// that follows), and cascade_position walks it off any window whose
    /// top-left it would sit on. Without an active output upstream has no view
    /// to place in and uses the origin. The pointer is a global screen point,
    /// read through the active output's own bounds and camera.
    fn spawn(
        &self,
        output: Option<OutputId>,
        pointer: Option<Point>,
        size: Size,
    ) -> Result<Arrival, Error> {
        // Upstream geometry is whole pixels: the policy sees the rounded size,
        // the world frame keeps the true one.
        let (w, h) = (size.width.round(), size.height.round());
        let config = self.config();
        let (mut at, mut at_cursor) = ((0.0, 0.0), false);
        if let Some(output) = output {
            let viewport = self
                .scene
                .output(output)
                .ok_or(Error::Invalid("unknown output"))?;
            let context = self.navigation_context(output)?;
            let usable = context.usable_rect_local;
            let (camera, zoom) = (viewport.camera, viewport.zoom);
            let chosen = match config.window_placement {
                WindowPlacement::Center => None,
                WindowPlacement::Cursor => pointer.map(|pointer| {
                    let cursor = viewport.screen_to_world(pointer);
                    let low = camera + usable.origin / zoom;
                    let high = camera + Point::new(usable.right(), usable.bottom()) / zoom;
                    // An oversized frame keeps its top-left on the usable edge.
                    let x = (cursor.x - w / 2.0).clamp(low.x, (high.x - w).max(low.x));
                    let y = (cursor.y - h / 2.0).clamp(low.y, (high.y - h).max(low.y));
                    (x.round(), y.round())
                }),
                WindowPlacement::Auto => self.auto_spawn(viewport, usable, (w, h))?,
            };
            at_cursor = chosen.is_some() && config.window_placement == WindowPlacement::Cursor;
            at = chosen.unwrap_or_else(|| {
                // The align point takes the zoom the navigation lands at, the
                // canvas conversion the current one; halving is upstream's
                // integer division.
                let landing = if config.zoom_reset_on_new_window {
                    1.0
                } else {
                    zoom
                };
                let align = context.align_point(Size::new(w, h), landing);
                (
                    (camera.x + align.x / zoom).round() - (w / 2.0).trunc(),
                    (camera.y + align.y / zoom).round() - (h / 2.0).trunc(),
                )
            });
        }
        let step = f64::from(config.decorations.title_bar_height.max(1));
        while self.scene.windows().iter().any(|window| {
            let origin = self.placed_rect(window).origin;
            (origin.x.round() - at.0).abs() <= 2.0 && (origin.y.round() - at.1).abs() <= 2.0
        }) {
            at = (at.0 + step, at.1 + step);
        }
        let rect = Rect::new(at.0, at.1, size.width, size.height);
        readable(rect).map_err(Error::Refused)?;
        Ok(Arrival::Place {
            rect,
            at_cursor,
            background: false,
        })
    }
    /// A window has appeared: the slot it adopts, or where it is placed. `rule`
    /// is what its window rules merge to. An adopted window keeps its slot
    /// whatever the rule says of position or pinning, as upstream's does.
    pub(crate) fn arrival(
        &self,
        output: Option<OutputId>,
        pointer: Option<Point>,
        bundle_id: &str,
        title: &str,
        size: Size,
        rule: Option<&AppliedWindowRule>,
    ) -> Result<Arrival, Error> {
        if output.is_some_and(|output| self.scene.output(output).is_none()) {
            return Err(Error::Invalid("unknown output"));
        }
        if pointer.is_some_and(|pointer| !point_valid(pointer)) {
            return Err(Error::Invalid("invalid screen point"));
        }
        if let Some(slot) = self.adoption_target(bundle_id, title) {
            return Ok(Arrival::Adopt(slot));
        }
        // Upstream: a rule's pin or position comes before the placement policy,
        // and fullscreen before auto, cursor and center: a new window never
        // lands on a fullscreen one, and nothing cascades it.
        if let Some(arrival) = self.rule_arrival(output, size, rule)? {
            return Ok(arrival);
        }
        match self.fullscreen_background(output, size) {
            Some(rect) => Ok(Arrival::Place {
                rect,
                at_cursor: false,
                background: true,
            }),
            None => self.spawn(output, pointer, size),
        }
    }
    /// What upstream does once the new window is mapped. An adopted window
    /// keeps its slot's frame and stacking and the camera stays; it takes the
    /// focus only when its stand-in held it. A placed window is raised, focused
    /// and navigated to, resetting the zoom with `zoom.reset_on_new_window`;
    /// cursor placement stays put unless that reset has a zoomed-out view to
    /// rescue. A window pinned by its rule is raised and focused without a
    /// navigation; a widget, and a window whose rule says `focus_on_open =
    /// false`, is neither focused nor navigated to. During the launch pass
    /// nothing asks for native focus or moves a camera: those windows were
    /// already open, and nobody opened them here.
    pub(crate) fn settle_arrival(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        arrival: Arrival,
    ) -> Result<Value, Error> {
        let (mut effect, mut navigation) = (Value::Null, Value::Null);
        self.log_arrival(window, output, arrival)?;
        // Upstream: a widget and a `focus_on_open = false` window map without
        // taking the focus or moving the camera.
        let rule = self.policy.applied.get(&window);
        let quiet = rule.is_some_and(|r| r.widget || r.focus_on_open == Some(false));
        let focus_on_open_suppressed =
            self.lifecycle.settled && rule.is_some_and(|r| r.focus_on_open == Some(false));
        let reveal = self.lifecycle.settled && !quiet;
        match arrival {
            Arrival::Adopt(_) => {
                if self.scene.focused() == Some(window) {
                    if reveal {
                        effect = self.request_focus(window)?["effect"].take();
                    } else if !quiet {
                        // Nothing is asked during the launch pass, so no answer
                        // can come: the focus the slot kept enters the history
                        // as a request answered `focus_logical` does, unless
                        // the slot is screen-pinned. A widget, and a window
                        // whose rule says `focus_on_open = false`, asks for
                        // nothing and records nothing at any time.
                        self.confirm_focus(window)?;
                    }
                }
            }
            // A pinned window has no canvas position to navigate to: it is
            // raised and focused where it is.
            Arrival::Pin { .. } => {
                if reveal {
                    effect = self.raise_and_focus(window)?.effect;
                }
            }
            // Upstream: a window placed in the background never activates.
            Arrival::Place {
                at_cursor,
                background,
                ..
            } => {
                if let Some(output) = output.filter(|_| reveal && !background) {
                    let reset = self.config().zoom_reset_on_new_window;
                    let zoom = self
                        .scene
                        .output(output)
                        .ok_or(Error::Invalid("unknown output"))?
                        .zoom;
                    let stays = at_cursor && !(reset && zoom < 1.0 - 1e-9);
                    // A drag or resize in progress keeps its camera.
                    if !stays && self.gesture.is_none() {
                        let policy = if reset {
                            ZoomPolicy::Reset
                        } else {
                            ZoomPolicy::Keep
                        };
                        navigation = self.arm_navigation(window, output, policy)?;
                    }
                    effect = self.raise_and_focus(window)?.effect;
                }
            }
        }
        let adopted = matches!(arrival, Arrival::Adopt(_));
        let background = matches!(
            arrival,
            Arrival::Place {
                background: true,
                ..
            }
        );
        let mut reply = json!({"window":window,"adopted":adopted,"background":background,"effect":effect,"navigation":navigation,"dirty":true});
        // Native applications may activate themselves while opening. Only an
        // explicit post-launch rule supplies authority for the shell to correct
        // that initial activation; widgets and startup adoption do not.
        if focus_on_open_suppressed {
            reply["focus_on_open_suppressed"] = json!(true);
        }
        Ok(reply)
    }

    /// The window's frame on the output's screen, and the usable rectangle.
    fn on_screen(&self, window: WindowId, output: OutputId) -> Option<(Point, Point, Rect)> {
        let viewport = self.scene.output(output)?;
        let usable = self.navigation_context(output).ok()?.usable_rect_local;
        let rect = self.scene.window(window)?.world_rect;
        let corner = Point::new(rect.right(), rect.bottom());
        Some((
            (rect.origin - viewport.camera) * viewport.zoom,
            (corner - viewport.camera) * viewport.zoom,
            usable,
        ))
    }
    /// Upstream window_fully_in_viewport: the whole frame inside the output's
    /// usable area at its current pose.
    pub(crate) fn fully_on(&self, window: WindowId, output: OutputId) -> bool {
        self.on_screen(window, output)
            .is_some_and(|(low, high, usable)| {
                low.x >= usable.origin.x - IN_VIEW_NOISE
                    && low.y >= usable.origin.y - IN_VIEW_NOISE
                    && high.x <= usable.right() + IN_VIEW_NOISE
                    && high.y <= usable.bottom() + IN_VIEW_NOISE
            })
    }
    /// Upstream window_intersects_viewport_on: any part of it counts.
    fn partly_on(&self, window: WindowId, output: OutputId) -> bool {
        self.on_screen(window, output)
            .is_some_and(|(low, high, usable)| {
                low.x < usable.right()
                    && usable.origin.x < high.x
                    && low.y < usable.bottom()
                    && usable.origin.y < high.y
            })
    }
    /// Upstream first_spatially_related_in_history: the most recently focused
    /// live window in the departing frame's snap cluster, or overlapping it.
    /// The history is the stage's, the one `cycle-windows` walks: every focus
    /// the adapter confirmed or observed, or answered `focus_logical` when it
    /// performs no native focus. A request nobody answered is not in it.
    fn spatially_related(&self, window: WindowId, rect: Rect) -> Option<WindowId> {
        // Upstream: a widget or a screen-pinned window has no snap rectangle,
        // so nothing is spatially related to one that departs.
        if !self.on_canvas(window) {
            return None;
        }
        // Upstream's snap rectangles leave widgets and pinned windows out.
        let rects: Vec<(WindowId, SnapRect)> = self
            .scene
            .windows()
            .iter()
            .filter(|w| self.on_canvas(w.id))
            .map(|w| (w.id, snap_rect(w.world_rect)))
            .collect();
        let cluster = cluster_of(&window, &rects, self.config().snap_gap);
        let departing = snap_rect(rect);
        self.scene
            .stage()
            .focus_history()
            .iter()
            .copied()
            .filter(|id| *id != window && self.sources.contains_key(id))
            .find(|id| {
                cluster.contains(id)
                    || rects
                        .iter()
                        .any(|(other, rect)| other == id && departing.overlaps(rect))
            })
    }
    /// Upstream nearest_visible_window_on: the live window nearest `from` by
    /// its center among those at least partly on `output`. Widgets and
    /// screen-pinned windows are left out: upstream's have no snap rectangle,
    /// so its viewport test passes them over.
    fn nearest_visible(&self, from: Point, output: OutputId, except: WindowId) -> Option<WindowId> {
        let distance = |window: &Window| {
            let center = window.world_rect.center();
            (center.x - from.x).powi(2) + (center.y - from.y).powi(2)
        };
        self.scene
            .windows()
            .iter()
            .filter(|w| {
                w.id != except
                    && self.sources.contains_key(&w.id)
                    && self.on_canvas(w.id)
                    && self.partly_on(w.id, output)
            })
            .min_by(|a, b| distance(a).total_cmp(&distance(b)))
            .map(|w| w.id)
    }
    /// End the drag or resize in progress if `window` is one of the windows it
    /// captured; upstream ends no other window's grab when a toplevel goes. The
    /// canvas keeps a gesture's members to itself, so the gesture is tried,
    /// unmoved, on a copy of the scene without the window: it fails exactly
    /// when a captured window is missing.
    pub(crate) fn release_gesture(&mut self, window: WindowId) {
        let mut scene = self.scene.clone();
        let holds = scene.remove_window(window).is_ok()
            && match &self.gesture {
                Some(Gesture::Drag { state, .. }) => {
                    scene.drag_to(&mut state.clone(), Point::default()).is_err()
                }
                Some(Gesture::Resize { state, .. }) => scene
                    .resize_to(&mut state.clone(), Point::default())
                    .is_err(),
                Some(Gesture::Pinned(drag)) => drag.window == window,
                None => false,
            };
        // The drag ends as a release ends it: its edge pan goes with it. A
        // trackpad move that installed it finds its drag gone and moves nothing.
        if holds {
            self.drop_gesture();
        }
    }
    /// Take a window off the canvas and move the focus as upstream's
    /// toplevel_destroyed and dismiss_suspended do. Focus follows only when the
    /// departing window held it, or when a live window departs while nothing is
    /// focused; any other focused window, a stand-in included, keeps it.
    /// Upstream's third condition, the head of the focus history, is for a
    /// keyboard focus parked on a layer surface, which does not exist here. The
    /// follower is a spatially related window from the focus history,
    /// flown to when it is off screen and `navigation.auto_navigate_on_close`
    /// is on; else the most recent window still visible on the home output,
    /// else the nearest visible one, else nobody. A widget or a screen-pinned
    /// window is never the follower, and one that departs has no spatially
    /// related window. `output` is the active
    /// output; when the caller names none it is the home output: the one
    /// showing the departing frame's center, else the first. A drag or resize
    /// the departing window takes no part in goes on, and no navigation is
    /// armed during a gesture.
    fn depart(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
    ) -> Result<(Value, Value), Error> {
        if output.is_some_and(|output| self.scene.output(output).is_none()) {
            return Err(Error::Invalid("unknown output"));
        }
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let follows = match self.scene.focused() {
            Some(focused) => focused == window,
            None => self.sources.contains_key(&window),
        };
        // Upstream toplevel_destroyed: the pick reads the cluster around the
        // fit as it stands, then release_fit_push puts back the neighbours a
        // snapped fit pushed aside, and only then do the visibility checks
        // below see where they landed. A stand-in conversion never gets here.
        let picked = follows.then(|| self.spatially_related(window, rect));
        self.release_fit_push(window);
        let history = self.scene.stage().focus_history();
        let live = |id: &WindowId| self.sources.contains_key(id);
        let showing = self
            .scene
            .outputs()
            .iter()
            .find(|o| o.world_bounds().contains(rect.center()))
            .map(|o| o.id);
        let active = output
            .or(showing)
            .or_else(|| self.scene.outputs().first().map(|o| o.id));
        let home = showing.or(active);
        let seen = |id: WindowId| active.is_some_and(|output| self.fully_on(id, output));
        let follow = picked.map(|picked| {
            let related = picked.filter(|id| self.config().auto_navigate_on_close || seen(*id));
            match (related, active) {
                (Some(id), _) if seen(id) => Follow::Raise(id),
                (Some(id), Some(output)) => Follow::Fly(id, output),
                (Some(_), None) => Follow::Nobody,
                (None, _) => {
                    let recent = history.iter().copied().find(|id| *id != window && live(id));
                    match (home, recent) {
                        (Some(output), Some(id)) if self.partly_on(id, output) => Follow::Raise(id),
                        (Some(output), _) => self
                            .nearest_visible(rect.center(), output, window)
                            .map_or(Follow::Nobody, Follow::Raise),
                        (None, _) => Follow::Nobody,
                    }
                }
            }
        });
        self.release_gesture(window);
        self.invalidate_focus(window);
        self.sources.remove(&window);
        self.scene.remove_window(window)?;
        self.metadata.remove(&window);
        let mut navigation = Value::Null;
        let target = match follow {
            None => return Ok((Value::Null, navigation)),
            Some(Follow::Nobody) => {
                self.clear_focus();
                return Ok((Value::Null, navigation));
            }
            Some(Follow::Raise(target)) => target,
            // A follower that cannot be flown to, too far out or while a
            // gesture that goes on holds the camera, is still focused.
            Some(Follow::Fly(target, output)) => {
                navigation = self
                    .arm_navigation(target, output, ZoomPolicy::Keep)
                    .unwrap_or(Value::Null);
                target
            }
        };
        Ok((self.raise_and_focus(target)?.effect, navigation))
    }

    /// The native window is gone. Upstream toplevel_destroyed: a mark decides
    /// first, the later of two winning; with none, `session.suspend_on_close`
    /// as it resolves for the window decides, and only an app that can be
    /// relaunched is eligible. A stand-in takes the window's place in the
    /// stack and keeps the focus if the window held it; otherwise the window
    /// leaves the scene and the focus follows.
    pub(crate) fn window_closed(
        &mut self,
        window: WindowId,
        identity: SourceIdentity,
        output: Option<OutputId>,
    ) -> Result<Value, Error> {
        self.guard_resize_structure(Some(window))?;
        self.fresh(window, &identity)?;
        if output.is_some_and(|output| self.scene.output(output).is_none()) {
            return Err(Error::Invalid("unknown output"));
        }
        // Upstream toplevel_destroyed: a fullscreen window's output has its
        // view back before the focus is handed on, and what stays of the
        // window is seated at the frame it had before.
        self.fullscreen_window_gone(window, true);
        let standin = match self.lifecycle.marks.remove(&window) {
            Some(CloseMark::Close) => false,
            Some(CloseMark::Suspend) => true,
            None => {
                let default = self.config().session.suspend_on_close;
                // Upstream: a widget is never eligible.
                !self.bundle(window).is_empty()
                    && !self.is_widget(window)
                    && self.session_flag(window, self.title(window), default, |rule| {
                        rule.suspend_on_close
                    })
            }
        };
        let (mut effect, mut navigation) = (Value::Null, Value::Null);
        self.log_close(window, standin, output)?;
        if standin {
            self.release_gesture(window);
            self.invalidate_focus(window);
            self.sources.remove(&window);
            self.lifecycle.standins.insert(window);
            self.cap_standin(window);
        } else {
            (effect, navigation) = self.depart(window, output)?;
        }
        Ok(json!({"standin":standin,"effect":effect,"navigation":navigation,"dirty":true}))
    }
    /// Upstream standin_body_rect (v0.21.0, third_party/driftwm/src/state/
    /// suspended.rs): a body past the stand-in ceiling is cut to it, keeping
    /// its top-left. A window's native frame has no such limit, and a stand-in
    /// is drawn and saved at one that does: a larger one would be dropped by the
    /// next restore.
    fn cap_standin(&mut self, window: WindowId) {
        let Some(rect) = self.scene.window(window).map(|w| w.world_rect) else {
            return;
        };
        let ceiling = f64::from(super::storage::MAX_STANDIN_EXTENT);
        if rect.size.width <= ceiling && rect.size.height <= ceiling {
            return;
        }
        let capped = Rect {
            origin: rect.origin,
            size: Size::new(rect.size.width.min(ceiling), rect.size.height.min(ceiling)),
        };
        // A smaller frame at the same origin cannot leave the world.
        let _ = self.scene.set_window_rect(window, capped);
    }
    /// The window's title changed. Titles are saved: a slot is matched to its
    /// window by title at the next launch.
    pub(crate) fn retitle(
        &mut self,
        window: WindowId,
        identity: SourceIdentity,
        title: String,
    ) -> Result<Value, Error> {
        self.fresh(window, &identity)?;
        if !text_valid(&title, 16384) {
            return Err(Error::Invalid("invalid source metadata or rectangle"));
        }
        let metadata = self
            .metadata
            .get_mut(&window)
            .ok_or(Error::Invalid("missing window metadata"))?;
        let dirty = metadata.title != title;
        metadata.title = title;
        Ok(json!({"dirty":dirty}))
    }
    /// The shell has ended a discovery pass: the one at launch, or the one of a
    /// canvas that reopened. On Wayland the clients die with the compositor,
    /// so upstream's saved session holds stand-ins only; on macOS applications
    /// outlive the canvas, so the scene file keeps a slot for every window and
    /// the pass hands each window on screen its slot back. `present` names the
    /// windows that still exist but could not be offered: their slots keep
    /// waiting, held for a window with that very title. What is left belongs
    /// to a window that closed while nobody was looking: with
    /// `session.restore_windows`, as it resolves for the slot, it stays as a
    /// dormant stand-in, exactly as upstream restores a window that was open
    /// at the last save; without, it is dropped. Stand-ins are never dropped:
    /// upstream always restores them. Only the first call ends the launch
    /// pass, after which a window that appears is focused and revealed.
    pub(crate) fn adoption_complete(&mut self, present: &[PresentWindow]) -> Result<Value, Error> {
        self.lifecycle.settled = true;
        // Every output that exists has been registered by now: a fullscreen
        // whose output did not come back ends, and a saved pin whose output
        // did not come back moves to one that did.
        let ended = self.fullscreen_outputs_settled();
        let rehomed = self.rehome_pins() || ended;
        let mut waiting: Vec<WindowId> = self
            .scene
            .windows()
            .iter()
            .map(|w| w.id)
            .filter(|id| !self.sources.contains_key(id) && !self.lifecycle.standins.contains(id))
            .collect();
        waiting.sort();
        // Each pass says afresh which windows exist: a slot held by the last
        // one whose window has closed since is decided like any other.
        self.lifecycle.held.clear();
        for window in present.iter().filter(|w| !w.bundle_id.is_empty()) {
            let own = |id: &WindowId| {
                self.bundle(*id) == window.bundle_id && self.title(*id) == window.title
            };
            if let Some(index) = waiting.iter().position(own) {
                self.lifecycle.held.insert(waiting.remove(index));
            }
        }
        // A config file that was refused left the built-in defaults in force,
        // and they do not speak for the user's restore_windows: every slot
        // keeps waiting, and the next pass that has a config decides.
        if self.settings.refused {
            return Ok(json!({"dropped":[],"standins":[],"dirty":rehomed}));
        }
        let default = self.config().session.restore_windows;
        let focused = self.scene.focused();
        // Upstream asks twice: with the title when it decides whether an
        // open window is recorded, by app alone when it restores one.
        let restores = |id: &WindowId| {
            let flag = |title| self.session_flag(*id, title, default, |rule| rule.restore_windows);
            !self.bundle(*id).is_empty()
                && !self.is_widget(*id)
                && flag(self.title(*id))
                && flag("")
        };
        let (kept, dropped): (Vec<WindowId>, Vec<WindowId>) =
            waiting.into_iter().partition(restores);
        self.lifecycle.standins.extend(&kept);
        for id in &dropped {
            self.release_gesture(*id);
            self.scene.remove_window(*id)?;
            self.metadata.remove(id);
        }
        // Upstream starts unfocused when the focused window is not restored.
        if focused.is_some_and(|id| dropped.contains(&id)) {
            self.clear_focus();
        }
        let dirty = rehomed || !dropped.is_empty() || !kept.is_empty();
        Ok(json!({"dropped":dropped,"standins":kept,"dirty":dirty}))
    }

    /// Upstream dismiss_suspended: the stand-in leaves the canvas, a relaunch
    /// in flight is cancelled, and the focus follows as after a real close.
    fn dismiss(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        self.guard_resize_structure(Some(window))?;
        self.log_dismiss(window, output)?;
        let (effect, navigation) = self.depart(window, output)?;
        if !effect.is_null() {
            outcome.effects.push(effect);
        }
        outcome.navigation = navigation;
        outcome.dirty = true;
        Ok(())
    }
    /// Ask the shell to close a bound window, remembering what its going will
    /// mean. False for a detached one, which has nothing to close.
    fn request_close(&mut self, window: WindowId, mark: CloseMark, outcome: &mut Outcome) -> bool {
        let Some(source) = self.sources.get(&window) else {
            return false;
        };
        outcome.effects.push(json!({"op":"close_window","window":window,"identity":source.identity,"generation":source.generation}));
        self.lifecycle.marks.insert(window, mark);
        // The later command starts its own ten seconds.
        self.lifecycle.marked_at.remove(&window);
        true
    }
    /// Upstream CloseWindow and cmd_close: a bound window is asked to close for
    /// real, so `suspend_on_close` leaves no stand-in; a stand-in is dismissed.
    pub(crate) fn close_window(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        if self.request_close(window, CloseMark::Close, outcome) {
            return Ok(());
        }
        self.dismiss(window, output, outcome)
    }
    /// Upstream SuspendWindow: a bound window is asked to close and a stand-in
    /// takes its place once it has; an app that could not be relaunched closes
    /// for real instead. A second press, on the stand-in, dismisses it.
    pub(crate) fn suspend_window(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        let mark = if self.bundle(window).is_empty() {
            CloseMark::Close
        } else {
            CloseMark::Suspend
        };
        if self.request_close(window, mark, outcome) {
            return Ok(());
        }
        self.dismiss(window, output, outcome)
    }
    /// Upstream relaunch_suspended: ask the shell to open the stand-in's app.
    /// The next window of that app takes the slot. A relaunch already in
    /// flight is left alone, as upstream leaves it: it lapses by itself.
    fn relaunch(&mut self, window: WindowId, outcome: &mut Outcome) -> Result<(), String> {
        let bundle_id = self.bundle(window).to_owned();
        if bundle_id.is_empty() {
            return Err("the app has no bundle identifier to relaunch".to_string());
        }
        if self.lifecycle.relaunching.contains(&window) {
            return Ok(());
        }
        self.lifecycle.relaunching.push(window);
        outcome
            .effects
            .push(json!({"op":"launch","bundle_id":bundle_id,"window":window}));
        Ok(())
    }

    /// Upstream window_by_selector: live windows only. An id reaches a widget;
    /// an app id passes over one.
    pub(crate) fn select_live(
        &self,
        selector: Option<&WindowSelector>,
    ) -> Result<WindowId, String> {
        let live = |id: &WindowId| self.sources.contains_key(id);
        match selector {
            None => self.scene.focused().filter(live),
            Some(WindowSelector::Id(n)) => {
                self.scene.window(WindowId(*n)).map(|w| w.id).filter(live)
            }
            Some(WindowSelector::AppId(_)) => self.select_app(selector, true),
        }
        .ok_or_else(|| match selector {
            None => "no focused window".to_string(),
            Some(WindowSelector::Id(n)) => format!("no window with id {n}"),
            Some(WindowSelector::AppId(s)) => format!("no window matching '{}'", s.to_lowercase()),
        })
    }
    /// Upstream suspended_by_selector: detached windows only.
    fn select_standin(&self, selector: Option<&WindowSelector>) -> Option<WindowId> {
        let detached = |id: &WindowId| !self.sources.contains_key(id);
        match selector {
            None => self.scene.focused().filter(detached),
            Some(WindowSelector::Id(n)) => self
                .scene
                .window(WindowId(*n))
                .map(|w| w.id)
                .filter(detached),
            Some(WindowSelector::AppId(_)) => self.select_app(selector, false),
        }
    }
    /// The first window, bottom to top, whose bundle identifier contains the
    /// selector's text, among the bound or among the detached. No widget.
    fn select_app(&self, selector: Option<&WindowSelector>, live: bool) -> Option<WindowId> {
        let Some(WindowSelector::AppId(text)) = selector else {
            return None;
        };
        let needle = text.to_lowercase();
        self.scene.windows().iter().map(|w| w.id).find(|id| {
            self.sources.contains_key(id) == live
                && !self.is_widget(*id)
                && self.bundle(*id).to_lowercase().contains(&needle)
        })
    }
    /// Upstream cmd_close: a real close of a live window, else the dismissal
    /// of the stand-in the selector names.
    pub(crate) fn cmd_close(
        &mut self,
        output: Option<OutputId>,
        selector: Option<&WindowSelector>,
        outcome: &mut Outcome,
    ) -> Result<(), String> {
        let window = match self.select_live(selector) {
            Ok(window) => window,
            Err(error) => self.select_standin(selector).ok_or(error)?,
        };
        self.close_window(window, output, outcome)
            .map_err(|e| e.to_string())
    }
    /// Upstream cmd_suspend: focus the window without moving the camera, then
    /// the `suspend-window` action.
    pub(crate) fn cmd_suspend(
        &mut self,
        output: Option<OutputId>,
        selector: Option<&WindowSelector>,
        outcome: &mut Outcome,
    ) -> Result<(), String> {
        let window = match self.select_live(selector) {
            Ok(window) => window,
            Err(error) => {
                return Err(match self.select_standin(selector) {
                    Some(_) => "window is already suspended".to_string(),
                    None => error,
                });
            }
        };
        if self.is_widget(window) {
            return Err("widgets cannot be suspended".to_string());
        }
        let text = |e: Error| e.to_string();
        if self.scene.focused() != Some(window) {
            let effect = self.raise_and_focus(window).map_err(text)?.effect;
            if !effect.is_null() {
                outcome.effects.push(effect);
            }
            outcome.dirty = true;
        }
        self.suspend_window(window, output, outcome).map_err(text)
    }
    /// Upstream cmd_relaunch: the stand-in the selector names, the focused one
    /// without a selector.
    pub(crate) fn cmd_relaunch(
        &mut self,
        selector: Option<&WindowSelector>,
        outcome: &mut Outcome,
    ) -> Result<(), String> {
        let window = self
            .select_standin(selector)
            .ok_or_else(|| "no suspended window matching selector".to_string())?;
        self.relaunch(window, outcome)
    }
}
