// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm @
// df3de27b26c7998e8a460cffd8a4925cbed3a322 (v0.21.0): src/input/actions.rs
// (CenterWindow, FocusCenter, CenterNearest, FocusNearest,
// nearest_in_direction, center_on_anchor, CycleWindows),
// src/state/navigation.rs (navigate_to_window_on, reveal_element,
// RevealPan, MinimalPan, minimal_pan_camera, pan_minimally_to_element,
// reveal_frame, related_to_focus, spatial_relatives, window_fully_in_view_at,
// window_shown_as_fully_at, resolve_click_navigate,
// fire_click_navigate, activate_window_output_local, window_already_active,
// nav_center, element_closest_point), src/state/viewport.rs (viewport_center_canvas,
// window_visible_at_least_on), src/state/output.rs (output_for_window,
// output_shows_canvas_point), src/state/keyboard_focus.rs (raise_and_focus,
// clear_focus_to_empty_canvas), src/state/suspended.rs (center_on_suspended:
// a stand-in is centered like a client), src/input/pointer.rs (the
// click-to-focus fallback, and the raise_and_focus that the move and resize
// arms of on_pointer_button and of try_pinned_button run ahead of their grab)
// and src/handlers/mod.rs (focus_changed's cycle rule
// and the activation request's already-active rule). The directional search and the
// visibility measures are driftwm-core's `canvas::{find_nearest,
// visible_fraction, visible_canvas_rect, minimal_reveal_camera,
// leading_edge_camera}`, upstream's own code. A detached
// placeholder is upstream's stand-in. The candidates of every search here are
// upstream's canvas windows (`is_canvas_window`, `Controller::on_canvas`): no
// widget and no screen-pinned window, which are raised and focused where they
// are and never flown to (docs/crates/desktop/RULES.md). A fullscreen window is no canvas window
// either: it is focused on its own output and no target from any other
// (docs/crates/desktop/FULLSCREEN.md). Modal handling is absent; a filled window's view restore
// is sizes.rs's `navigate_restoring_fill`.
// Only world rectangles, output poses and the navigation context are read,
// never native geometry.
use super::ipc::frame;
use super::navigation::Anchor;
use super::sizes::{snap_rect, snap_rect_at, usable_px};
use super::view_actions::{core_point, pixel, pixel_size};
use super::*;
use driftwm_core::canvas::{
    find_nearest, leading_edge_camera, minimal_reveal_camera, visible_canvas_rect, visible_fraction,
};
use driftwm_core::config::Direction;
use driftwm_core::layout::cluster::cluster_of;
use driftwm_core::layout::snap::SnapRect;
use driftwm_core::platform::utils::{
    Point as CorePoint, Rectangle as CoreRectangle, Size as CoreSize,
};

/// Upstream NEAREST_ANCHOR_THRESHOLD: the focused window is the origin of a
/// directional search only while all of it is on the output (or, too big for
/// that, shown as fully as it fits).
const NEAREST_ANCHOR_THRESHOLD: f64 = 1.0;
/// Upstream IN_VIEW_NOISE: how far (screen px) a frame may sit past the usable
/// edge, or the line a minimal pan holds it on, and still count as inside it.
/// A pan that lands a frame flush on an edge carries float rounding through the
/// camera anchor, and a hair's overhang must not read as clipped.
pub(crate) const IN_VIEW_NOISE: f64 = 1e-6;
/// Upstream ACTIVATION_VISIBLE_THRESHOLD: an activated window that is clipped
/// at all is brought fully into view.
const ACTIVATION_VISIBLE_THRESHOLD: f64 = 1.0;
/// Upstream ACTIVATION_ONSCREEN_THRESHOLD: separates clipped to a hair from
/// off screen entirely.
const ACTIVATION_ONSCREEN_THRESHOLD: f64 = f64::EPSILON;

/// Why the shell activates a window.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivationCause {
    /// A press on the window's instance on the canvas.
    Click,
    /// That press let go as a completed click: the pointer stayed within
    /// upstream's 5 px slop on the same output, which the shell decides.
    ClickRelease,
    /// The shell observed that native focus moved to the window by itself.
    Native,
    /// A freshly validated native child holds focus for this logical root.
    /// Canvas focus follows, without asserting that the root itself holds it.
    NativeFamily,
}
/// What one window navigation leaves for its caller to report.
#[derive(Debug, Default)]
pub(crate) struct Moved {
    /// The focus request, or null: nothing with a bound source was focused.
    pub(crate) effect: Value,
    /// The armed flight, or null.
    pub(crate) navigation: Value,
    /// Logical focus or stacking was written, both of which are saved.
    pub(crate) refocused: bool,
}
impl Moved {
    pub(crate) fn reply(self) -> Value {
        json!({"effect":self.effect,"navigation":self.navigation})
    }
    /// As `reply`, and whether saved state changed, for the shell to save.
    pub(crate) fn reply_with_dirty(self) -> Value {
        json!({"effect":self.effect,"navigation":self.navigation,"dirty":self.refocused})
    }
}
/// A candidate of the directional search: upstream's NavTarget.
#[derive(Clone, Copy, PartialEq)]
pub(crate) enum NavTarget {
    Window(WindowId),
    Anchor(Point),
}
/// Upstream RevealPan: how a reveal pans to a target that is not fully on
/// screen.
#[derive(Clone, Copy, Debug)]
pub(crate) enum RevealPan {
    /// Park it on the `focus_placement` point, as a jump does.
    Park(ZoomPolicy),
    /// The least pan that shows it whole, at the landing zoom: a directional
    /// walk, where parking each step would throw the view around.
    Minimal,
}
/// Upstream MinimalPan: what a minimal pan keeps in view, `outer_gap` in from
/// the usable edge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MinimalPan {
    /// The whole frame, centered on an axis it is too big for.
    Whole,
    /// The edge leading a move, along x if `horizontal` and toward higher
    /// coordinates if `forward`, held on the line; the camera's course on the
    /// other axis is left as it was.
    LeadingEdge { horizontal: bool, forward: bool },
}

impl Controller {
    fn window_rect(&self, window: WindowId) -> Result<Rect, Error> {
        Ok(self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect)
    }
    /// Upstream viewport_center_canvas: the world point under the usable center.
    fn viewport_center_canvas(viewport: &Viewport, usable: Rect) -> Point {
        viewport.camera + usable.center() / viewport.zoom
    }
    /// Upstream window_visible_at_least_on's measure: the share of the frame's
    /// area inside the whole output, panels included. Upstream frames sit on
    /// whole pixels and these are fractional, so the frame is measured by the
    /// largest whole-pixel rectangle inside it: a frame that navigation has
    /// just parked flush against an edge still counts as entirely visible.
    fn visible_share(&self, window: WindowId, output: OutputId) -> Result<f64, Error> {
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        self.visible_share_at(window, output, viewport.camera, viewport.zoom)
    }
    /// As `visible_share`, at `camera` and `zoom` instead of the live view
    /// (upstream window_visible_at_least_at).
    fn visible_share_at(
        &self,
        window: WindowId,
        output: OutputId,
        camera: Point,
        zoom: f64,
    ) -> Result<f64, Error> {
        let rect = self.window_rect(window)?;
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        let (x, y) = (pixel(rect.origin.x.ceil())?, pixel(rect.origin.y.ceil())?);
        let (right, bottom) = (pixel(rect.right().floor())?, pixel(rect.bottom().floor())?);
        let size = pixel_size(viewport.screen_bounds.size)?;
        // A frame under a pixel across has no whole pixel to measure.
        let (Some(width), Some(height)) = (
            right.checked_sub(x).filter(|width| *width > 0),
            bottom.checked_sub(y).filter(|height| *height > 0),
        ) else {
            return Ok(0.0);
        };
        Ok(visible_fraction(
            (x, y).into(),
            (width, height).into(),
            core_point(camera),
            (size.w, size.h).into(),
            zoom,
        ))
    }
    /// Upstream output_for_window: the first output, in registration order,
    /// whose viewport shows the frame's center (output_shows_canvas_point: the
    /// camera rounded, two spare pixels, the point truncated), else the active
    /// one. An output whose pose leaves the integer range shows nothing.
    pub(crate) fn home_output(
        &self,
        window: WindowId,
        active: Option<OutputId>,
    ) -> Result<Option<OutputId>, Error> {
        let center = self.window_rect(window)?.center();
        let (x, y) = (i64::from(center.x as i32), i64::from(center.y as i32));
        let shows = |viewport: &Viewport| -> Option<bool> {
            let size = pixel_size(viewport.screen_bounds.size).ok()?;
            // visible_canvas_rect widens each extent by two pixels in i32.
            pixel((f64::from(size.w) / viewport.zoom).ceil() + 2.0).ok()?;
            pixel((f64::from(size.h) / viewport.zoom).ceil() + 2.0).ok()?;
            let camera = (
                pixel(viewport.camera.x.round()).ok()?,
                pixel(viewport.camera.y.round()).ok()?,
            );
            let visible =
                visible_canvas_rect(camera.into(), (size.w, size.h).into(), viewport.zoom);
            let (left, top) = (i64::from(visible.loc.x), i64::from(visible.loc.y));
            Some(
                (left..left + i64::from(visible.size.w)).contains(&x)
                    && (top..top + i64::from(visible.size.h)).contains(&y),
            )
        };
        Ok(self
            .scene
            .outputs()
            .iter()
            .find(|viewport| shows(viewport) == Some(true))
            .map(|viewport| viewport.id)
            .or(active))
    }
    /// Upstream raise_and_focus. A focus change that is not a cycle step ends a
    /// cycle in progress first, as upstream's focus_changed does.
    pub(crate) fn raise_and_focus(&mut self, window: WindowId) -> Result<Moved, Error> {
        self.finish_cycle();
        self.scene.focus(window)?;
        Ok(Moved {
            effect: self.request_focus(window)?["effect"].take(),
            navigation: Value::Null,
            refocused: true,
        })
    }
    /// Upstream's press bound to `move-window`, `move-snapped-windows`,
    /// `resize-window` or `resize-window-snapped`: on_pointer_button's arms
    /// for a canvas window and try_pinned_button's for a screen-pinned one
    /// raise and focus the window under the pointer, and then install their
    /// grab. The focus request is the reply's, as a click's is; it is null
    /// for a stand-in. The caller installs the grab next, in upstream's
    /// order. A grab that is refused rejects the whole command, so nothing
    /// is focused for it: a widget, which upstream's arms pass over for the
    /// click-to-focus fallback, and the refusals that are this port's own
    /// and have no upstream counterpart, such as a size still owed.
    pub(crate) fn focus_for_grab(&mut self, window: WindowId) -> Result<Value, Error> {
        Ok(self.raise_and_focus(window)?.effect)
    }
    /// Upstream navigate_to_window_on: raise, focus, and fly `output`'s camera
    /// until the frame sits on the focus placement point. A screen-pinned
    /// window lives in screen space and a widget is no navigation target:
    /// either is raised and focused where it is, and no camera moves.
    pub(crate) fn navigate_to_window(
        &mut self,
        window: WindowId,
        output: OutputId,
        policy: ZoomPolicy,
    ) -> Result<Moved, Error> {
        // A fullscreen window lives in screen space on its own output. There
        // it is focused and the parked camera stays; from any other output it
        // is invisible and no target: nothing is focused and nothing moves.
        if let Some(own) = self.fullscreen_output_of(window) {
            self.navigation_context(output)?;
            return match own == output {
                true => self.raise_and_focus(window),
                false => Ok(Moved::default()),
            };
        }
        if !self.on_canvas(window) {
            self.navigation_context(output)?;
            return self.raise_and_focus(window);
        }
        let navigation = self.arm_navigation(window, output, policy)?;
        Ok(Moved {
            navigation,
            ..self.raise_and_focus(window)?
        })
    }
    /// Upstream CycleWindows: one step through the frozen focus history, flown
    /// to at the current zoom. `held` is upstream's "a real modifier is
    /// physically down": the session then stays open until `end_focus_cycle`.
    /// Otherwise the step is committed as a release would commit it. `None`
    /// when the history is empty.
    pub(crate) fn cycle_navigate(
        &mut self,
        output: OutputId,
        backward: bool,
        held: bool,
    ) -> Result<Option<Moved>, Error> {
        self.navigation_context(output)?;
        self.focus.release_pending = false;
        // Upstream cycle_step passes over a fullscreen window.
        let Some(window) = self.cycle_past_fullscreen(backward)? else {
            return Ok(None);
        };
        // Upstream step_cycle is reveal_element(Park(Keep)): a window the view
        // lands on already shows whole is only focused, and a clipped one is
        // parked at the `focus_placement` point.
        let (camera, zoom) = self.landing_view(output)?;
        let navigation = if self.window_fully_in_view_at(window, output, camera, zoom)? {
            self.hover_parked();
            Value::Null
        } else {
            self.arm_navigation(window, output, ZoomPolicy::Keep)?
        };
        let effect = self.request_focus(window)?["effect"].take();
        if !held {
            self.release_cycle();
        }
        Ok(Some(Moved {
            effect,
            navigation,
            refocused: true,
        }))
    }
    /// Upstream CenterWindow: the focused canvas window, else the canvas
    /// window whose center is nearest the viewport center, at zoom 1. With a
    /// widget or a screen-pinned window focused it is the nearest one, as with
    /// nothing focused. Upstream's policy is RestoreFillElseReset: a window
    /// still filled returns to the camera and zoom it was filled in instead.
    pub(crate) fn center_window(&mut self, output: OutputId) -> Result<Moved, Error> {
        let (viewport, usable) = self.view(output)?;
        let center = Self::viewport_center_canvas(&viewport, usable);
        let distance = |window: &Window| {
            let offset = window.world_rect.center() - center;
            offset.x * offset.x + offset.y * offset.y
        };
        let focused = self.scene.focused().filter(|id| self.on_canvas(*id));
        let target = focused.or_else(|| {
            self.scene
                .windows()
                .iter()
                .filter(|window| self.on_canvas(window.id))
                .min_by(|a, b| distance(a).total_cmp(&distance(b)))
                .map(|window| window.id)
        });
        match target {
            Some(window) => self.navigate_restoring_fill(window, output),
            None => Ok(Moved::default()),
        }
    }
    /// Upstream FocusCenter: the topmost canvas window under the pointer, at
    /// zoom 1, with the same fill exception as CenterWindow. A screen-pinned
    /// window under the pointer is focused and the view stays where it is
    /// (upstream's `pinned_owner_under` arm), and with nothing under it, or no
    /// pointer, the action is `center-window`: the focused window is centered,
    /// else the nearest. `pointer` is a global screen point. A widget is no
    /// candidate and the canvas walk passes through a pin to the window it
    /// covers.
    pub(crate) fn focus_center(
        &mut self,
        output: OutputId,
        pointer: Option<Point>,
    ) -> Result<Moved, Error> {
        self.view(output)?;
        if let Some(pin) = pointer
            .and_then(|pointer| self.hit_window(output, pointer))
            .map(|(window, _)| window)
            .filter(|window| self.is_pinned(*window) && !self.is_widget(*window))
        {
            // Hover skips a pin's resize band for the window behind it, so a
            // flight under way would take this focus back.
            self.hover_parked();
            return self.raise_and_focus(pin);
        }
        match pointer.and_then(|pointer| self.canvas_window_under(output, pointer)) {
            Some(window) => self.navigate_restoring_fill(window, output),
            None => self.center_window(output),
        }
    }
    /// Upstream nearest_in_direction, the cone search `center-nearest` and
    /// `focus-nearest` share: the nearest canvas window or `navigation.anchors`
    /// point in a 90° cone. The search starts at the focused window while all
    /// of it is on the output (or, too big for that, shown as fully as it
    /// fits) and it is not screen-pinned, and at the viewport center
    /// otherwise, both judged where the view lands, so a step taken while the
    /// last one's pan is under way searches from where that pan ends. A window
    /// the action just took out of fullscreen anchors the search wherever the
    /// restored view placed it.
    fn nearest_in_direction(
        &self,
        output: OutputId,
        direction: &Direction,
        was_fullscreen: Option<WindowId>,
    ) -> Result<Option<NavTarget>, Error> {
        let (_, usable) = self.view(output)?;
        let (camera, zoom) = self.landing_view(output)?;
        let anchor = was_fullscreen.or_else(|| {
            // A window too big for the view never reads as fully visible;
            // searched for from the viewport center it would be the nearest
            // hit again and again.
            self.scene
                .focused()
                .filter(|id| !self.is_pinned(*id))
                .filter(|window| {
                    self.visible_share_at(*window, output, camera, zoom)
                        .is_ok_and(|share| share >= NEAREST_ANCHOR_THRESHOLD)
                        || self.window_shown_as_fully_at(*window, output, camera, zoom)
                })
        });
        let (origin, skip) = match anchor {
            Some(window) => (
                self.window_rect(window)?.center(),
                Some(NavTarget::Window(window)),
            ),
            None => (camera + usable.center() / zoom, None),
        };
        let canvas = |window: &&Window| self.on_canvas(window.id);
        let windows = self.scene.windows().iter().filter(canvas).map(|window| {
            // Upstream element_closest_point. A point on the origin has no
            // direction, so a frame that holds the origin is found by its center.
            let rect = window.world_rect;
            let closest = Point::new(
                origin.x.clamp(rect.origin.x, rect.right()),
                origin.y.clamp(rect.origin.y, rect.bottom()),
            );
            let point = if closest == origin {
                rect.center()
            } else {
                closest
            };
            (NavTarget::Window(window.id), core_point(point))
        });
        // An anchor outside the world could be chosen and never flown to.
        let anchors = self
            .config()
            .nav_anchors
            .iter()
            .map(|point| Point::new(point.x, point.y))
            .filter(|point| point.valid())
            .map(|point| (NavTarget::Anchor(point), core_point(point)));
        Ok(find_nearest(
            core_point(origin),
            direction,
            windows.chain(anchors),
            skip.as_ref(),
        ))
    }
    /// Upstream center_on_anchor: land the camera on a bare anchor point,
    /// through the anchor so that a flight under way cannot steer it back.
    /// Unfocuses, so that the next directional step searches from the viewport
    /// center, which is now the anchor.
    fn center_on_anchor(&mut self, output: OutputId, point: Point) -> Result<Moved, Error> {
        let (_, usable) = self.view(output)?;
        let refocused = self.clear_focus();
        // As the window arms do: otherwise the pull hands focus to whatever
        // the pan leaves under the resting cursor, undoing the unfocus.
        self.hover_parked();
        let zoom = self.landing_view(output)?.1;
        let anchor = Anchor {
            canvas: point,
            screen: usable.center(),
        };
        Ok(Moved {
            effect: Value::Null,
            navigation: self.arm_anchor(output, anchor, zoom)?,
            refocused,
        })
    }
    /// Upstream CenterNearest: the nearest window in `direction`, always
    /// centered (parked at the `focus_placement` point) at the zoom the view
    /// is heading to. An anchor clears focus.
    pub(crate) fn center_nearest(
        &mut self,
        output: OutputId,
        direction: &Direction,
        was_fullscreen: Option<WindowId>,
    ) -> Result<Moved, Error> {
        match self.nearest_in_direction(output, direction, was_fullscreen)? {
            Some(NavTarget::Window(window)) => {
                self.navigate_to_window(window, output, ZoomPolicy::Keep)
            }
            Some(NavTarget::Anchor(point)) => {
                self.overview_returns.remove(&output);
                self.center_on_anchor(output, point)
            }
            None => Ok(Moved::default()),
        }
    }
    /// Upstream FocusNearest: the nearest window in `direction`, focused with
    /// the view left alone when it is fully on screen. Clipped, it scrolls just
    /// far enough to show it when it belongs to the focused window's snap
    /// cluster or overlaps it, and parks at `focus_placement` otherwise, as a
    /// jump does.
    pub(crate) fn focus_nearest(
        &mut self,
        output: OutputId,
        direction: &Direction,
        was_fullscreen: Option<WindowId>,
    ) -> Result<Moved, Error> {
        match self.nearest_in_direction(output, direction, was_fullscreen)? {
            Some(NavTarget::Window(window)) => {
                // A step to an unrelated window is a jump, and jumps park.
                let pan = if self.related_to_focus(window, was_fullscreen) {
                    RevealPan::Minimal
                } else {
                    RevealPan::Park(ZoomPolicy::Keep)
                };
                self.reveal_window(window, output, pan)
            }
            Some(NavTarget::Anchor(point)) => self.center_on_anchor(output, point),
            None => Ok(Moved::default()),
        }
    }
    /// Upstream reveal_element: focus and raise `window`, panning the camera to
    /// it only when it is not fully on screen where the view lands, unlike the
    /// centering navigations, which always park. Judged there, not at the
    /// frame of a flight still under way: a step onto a window the flight is
    /// about to leave behind re-targets it, and one onto a window it will show
    /// lets it land, zoom included.
    pub(crate) fn reveal_window(
        &mut self,
        window: WindowId,
        output: OutputId,
        pan: RevealPan,
    ) -> Result<Moved, Error> {
        self.navigation_context(output)?;
        let (camera, zoom) = self.landing_view(output)?;
        if self.window_fully_in_view_at(window, output, camera, zoom)? {
            // As in navigate_to_window_on.
            self.hover_parked();
            return self.raise_and_focus(window);
        }
        match pan {
            RevealPan::Park(policy) => self.navigate_to_window(window, output, policy),
            RevealPan::Minimal => {
                let Some(frame) = self.reveal_frame(window) else {
                    return self.raise_and_focus(window);
                };
                let navigation =
                    self.pan_minimally(output, &frame, camera, zoom, MinimalPan::Whole)?;
                self.hover_parked();
                Ok(Moved {
                    navigation,
                    ..self.raise_and_focus(window)?
                })
            }
        }
    }
    /// Upstream reveal_frame: the frame a minimal reveal brings into view,
    /// sized as configured, not as committed, the way the park measures it, so
    /// a window riding an unacked size lands where it is about to be. Native
    /// frames include their title bar; there is no border to add.
    pub(crate) fn reveal_frame(&self, window: WindowId) -> Option<SnapRect> {
        let (loc, committed) = frame(self.scene.window(window)?.world_rect).ok()?;
        let size = self.configured_size(window, committed);
        Some(snap_rect_at(loc, size))
    }
    /// Upstream frame_fully_in_view_at: is the canvas rect inside `output`'s
    /// usable area at `camera` and `zoom`?
    pub(crate) fn frame_fully_in_view_at(
        &self,
        rect: &SnapRect,
        output: OutputId,
        camera: Point,
        zoom: f64,
    ) -> Result<bool, Error> {
        let usable = self.navigation_context(output)?.usable_rect_local;
        let low = (
            (rect.x_low - camera.x) * zoom,
            (rect.y_low - camera.y) * zoom,
        );
        let high = (
            (rect.x_high - camera.x) * zoom,
            (rect.y_high - camera.y) * zoom,
        );
        Ok(low.0 >= usable.origin.x - IN_VIEW_NOISE
            && low.1 >= usable.origin.y - IN_VIEW_NOISE
            && high.0 <= usable.right() + IN_VIEW_NOISE
            && high.1 <= usable.bottom() + IN_VIEW_NOISE)
    }
    /// Upstream window_fully_in_view_at. A window that is no canvas window has
    /// no meaningful relation to the view, and reads as not in it.
    pub(crate) fn window_fully_in_view_at(
        &self,
        window: WindowId,
        output: OutputId,
        camera: Point,
        zoom: f64,
    ) -> Result<bool, Error> {
        if !self.on_canvas(window) {
            return Ok(false);
        }
        let rect = snap_rect(self.window_rect(window)?);
        self.frame_fully_in_view_at(&rect, output, camera, zoom)
    }
    /// Upstream window_shown_as_fully_at: does the view at `camera` and `zoom`
    /// show `window` as fully as any pan could, its frame inside the usable
    /// area or centered on an axis it is too big for, as a `focus-nearest`
    /// reveal leaves it?
    fn window_shown_as_fully_at(
        &self,
        window: WindowId,
        output: OutputId,
        camera: Point,
        zoom: f64,
    ) -> bool {
        let Some(frame) = self.reveal_frame(window) else {
            return false;
        };
        let Ok(reveal) =
            self.minimal_pan_camera(output, &frame, camera, zoom, MinimalPan::Whole, 0.0)
        else {
            return false;
        };
        (reveal.x - camera.x).abs() * zoom <= IN_VIEW_NOISE
            && (reveal.y - camera.y).abs() * zoom <= IN_VIEW_NOISE
    }
    /// Where `output`'s camera goes from `camera` at `zoom` when it pans the
    /// least that keeps `frame` in view as `pan` says, `inset` canvas px clear
    /// of the usable edge (upstream minimal_pan_camera; its inset is
    /// `outer_frame_inset(border)`, and a native frame has no border).
    fn minimal_pan_camera(
        &self,
        output: OutputId,
        frame: &SnapRect,
        camera: Point,
        zoom: f64,
        pan: MinimalPan,
        inset: f64,
    ) -> Result<Point, Error> {
        let usable = self.navigation_context(output)?.usable_rect_local;
        let (at, extent) = usable_px(usable)?;
        let usable = CoreRectangle::new(
            CorePoint::from((pixel(at[0] as f64)?, pixel(at[1] as f64)?)),
            CoreSize::from((pixel(extent[0] as f64)?, pixel(extent[1] as f64)?)),
        );
        let camera = core_point(camera);
        let reveal = match pan {
            MinimalPan::Whole => minimal_reveal_camera(frame, camera, zoom, usable, inset),
            MinimalPan::LeadingEdge {
                horizontal,
                forward,
            } => leading_edge_camera(frame, camera, zoom, usable, inset, horizontal, forward),
        };
        Ok(Point::new(reveal.x, reveal.y))
    }
    /// Whether the view at `camera` and `zoom` has to move for `pan` to keep
    /// `frame` in view (upstream minimal_pan_moves).
    pub(crate) fn minimal_pan_moves(
        &self,
        output: OutputId,
        frame: &SnapRect,
        camera: Point,
        zoom: f64,
        pan: MinimalPan,
    ) -> Result<bool, Error> {
        let inset = self.navigation_context(output)?.outer_gap().max(0.0);
        let target = self.minimal_pan_camera(output, frame, camera, zoom, pan, inset)?;
        Ok((target.x - camera.x).abs().max((target.y - camera.y).abs()) * zoom > IN_VIEW_NOISE)
    }
    /// Upstream pan_minimally_to_element, less the focus it also sets: pan
    /// `output`'s view from `camera` at `zoom`, where any flight under way
    /// lands, by the least amount that keeps `frame` in view as `pan` says,
    /// through the anchor so that a flight under way cannot steer it back.
    pub(crate) fn pan_minimally(
        &mut self,
        output: OutputId,
        frame: &SnapRect,
        camera: Point,
        zoom: f64,
        pan: MinimalPan,
    ) -> Result<Value, Error> {
        let inset = self.navigation_context(output)?.outer_gap().max(0.0);
        let target = self.minimal_pan_camera(output, frame, camera, zoom, pan, inset)?;
        let anchor = match pan {
            MinimalPan::Whole => {
                let center = Point::new(
                    (frame.x_low + frame.x_high) / 2.0,
                    (frame.y_low + frame.y_high) / 2.0,
                );
                Anchor {
                    canvas: center,
                    screen: (center - target) * zoom,
                }
            }
            // Steering by a point far off screen would swing the camera there
            // with whatever zoom is left to fly, so the move steers by its
            // leading edge, which lands on screen however big the frame, and
            // the held axis keeps the anchor of any flight under way, and so
            // its course. Every zoom flight arms an anchor, so with none the
            // zoom holds and the camera's own origin serves.
            MinimalPan::LeadingEdge {
                horizontal,
                forward,
            } => {
                let held = self
                    .flights
                    .get(&output)
                    .and_then(|flight| flight.zoom_animation_anchor)
                    .unwrap_or(Anchor {
                        canvas: camera,
                        screen: Point::new(0.0, 0.0),
                    });
                if horizontal {
                    let edge = if forward { frame.x_high } else { frame.x_low };
                    Anchor {
                        canvas: Point::new(edge, held.canvas.y),
                        screen: Point::new((edge - target.x) * zoom, held.screen.y),
                    }
                } else {
                    let edge = if forward { frame.y_high } else { frame.y_low };
                    Anchor {
                        canvas: Point::new(held.canvas.x, edge),
                        screen: Point::new(held.screen.x, (edge - target.y) * zoom),
                    }
                }
            }
        };
        self.arm_anchor(output, anchor, zoom)
    }
    /// Upstream related_to_focus: is `target` spatially related to the focused
    /// window, in its snap cluster or overlapping its frame, at their live
    /// frames? Nothing focused, or a focused window with no canvas frame
    /// (pinned), relates to nothing. `left_fullscreen` is a window this action
    /// took out of fullscreen: until its size comes back it is measured at the
    /// size the exit asked for.
    fn related_to_focus(&self, target: WindowId, left_fullscreen: Option<WindowId>) -> bool {
        let Some(focused) = self.scene.focused().filter(|id| self.on_canvas(*id)) else {
            return false;
        };
        let rects = self.snap_rects();
        let Some(live) = rects
            .iter()
            .find(|(window, _)| *window == focused)
            .map(|(_, rect)| *rect)
        else {
            return false;
        };
        let exit_unanswered =
            left_fullscreen == Some(focused) && self.fullscreen.restore_size(focused).is_some();
        let frame = if exit_unanswered {
            self.reveal_frame(focused).unwrap_or(live)
        } else {
            live
        };
        // Upstream spatial_relatives: the members of its snap cluster and every
        // element overlapping `frame`, `focused` itself included.
        let rects: Vec<(WindowId, SnapRect)> = rects
            .into_iter()
            .map(|(window, rect)| (window, if window == focused { frame } else { rect }))
            .collect();
        let mut related = cluster_of(&focused, &rects, self.config().snap_gap);
        related.extend(
            rects
                .iter()
                .filter(|(_, rect)| frame.overlaps(rect))
                .map(|(window, _)| *window),
        );
        related.contains(&target)
    }
    /// Upstream clear_focus_to_empty_canvas and set_window_focus(None): no
    /// window holds logical focus. A cycle in progress ends first and a pending
    /// focus request is dropped. Nothing is asked of the native adapter, and
    /// what it last observed stays as it was. True when a window held focus.
    pub(crate) fn clear_focus(&mut self) -> bool {
        let focused = self.scene.focused().is_some();
        self.finish_cycle();
        self.focus.pending_effect = None;
        self.focus.logical = None;
        self.scene.clear_focus();
        focused
    }
    /// The zoom an activation's reveal lands at: `zoom.reset_on_activation`.
    fn activation_zoom(&self) -> ZoomPolicy {
        match self.config().zoom_reset_on_activation {
            true => ZoomPolicy::Reset,
            false => ZoomPolicy::Keep,
        }
    }
    /// What upstream does when a window is clicked or asks to be activated:
    /// the command's reply.
    pub(crate) fn activate(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        cause: ActivationCause,
        identity: Option<SourceIdentity>,
        generation: Option<u64>,
    ) -> Result<Value, Error> {
        self.window_rect(window)?;
        self.require_source_interactive(window)?;
        if let Some(output) = output {
            self.navigation_context(output)?;
        }
        if let Some(identity) = &identity {
            self.fresh(window, identity)?;
        }
        if let Some(generation) = generation {
            let source = self
                .sources
                .get(&window)
                .ok_or(Error::Invalid("unbound source"))?;
            if source.generation != generation {
                return Err(Error::Invalid("stale binding generation"));
            }
        }
        let moved = match cause {
            // Upstream's click-to-focus fallback: raise and focus at the press.
            // The camera stays, so the press and its drags reach the window
            // where the pointer is.
            ActivationCause::Click => self.raise_and_focus(window)?,
            // Upstream resolve_click_navigate and fire_click_navigate: with
            // `auto_navigate_on_click`, a completed click on a window that
            // still holds focus and is not wholly inside the usable area
            // brings it into view at the current zoom. No focus is requested,
            // so the reply has no `effect`: the press's request stays as it is.
            ActivationCause::ClickRelease => {
                let navigation = match output {
                    // Upstream arms no click navigation for a widget, and a
                    // pinned window has no canvas position to bring into view.
                    // v0.20: judged at the live view the click was made on,
                    // not the landing view, so a window shown whole leaves a
                    // flight under way alone, and the click scrolls the
                    // window just far enough to show it whole instead of
                    // centering it, so that it stays near the pointer.
                    Some(output)
                        if self.config().auto_navigate_on_click
                            && self.on_canvas(window)
                            && self.scene.focused() == Some(window)
                            && !self
                                .fully_in_viewport(window, output)
                                .map_err(Error::Refused)? =>
                    {
                        let (camera, zoom) = self.landing_view(output)?;
                        match self.reveal_frame(window) {
                            Some(frame) => {
                                self.hover_parked();
                                self.pan_minimally(output, &frame, camera, zoom, MinimalPan::Whole)?
                            }
                            None => Value::Null,
                        }
                    }
                    _ => Value::Null,
                };
                return Ok(json!({"navigation":navigation,"dirty":false}));
            }
            ActivationCause::Native | ActivationCause::NativeFamily => {
                let family = cause == ActivationCause::NativeFamily;
                let source = self
                    .sources
                    .get(&window)
                    .ok_or(Error::Invalid("unbound source"))?;
                let observed = FocusEffect {
                    op: "observed_native_focus",
                    effect_id: 0,
                    window,
                    identity: source.identity.clone(),
                    generation: source.generation,
                };
                // A fullscreen window's home is the output it fills, whatever
                // other camera happens to show the canvas it is parked on.
                let home = match self.fullscreen_output_of(window) {
                    Some(own) => Some(own).filter(|own| self.scene.output(*own).is_some()),
                    None => self.home_output(window, output)?,
                };
                let shown = |controller: &Self| match home {
                    Some(home) => controller.visible_share(window, home),
                    None => Ok(0.0),
                };
                let share = shown(self)?;
                // Upstream window_already_active: the window holds the keyboard
                // and is at least partly on screen, so the request asks for
                // what already holds.
                let holds_keyboard = if family {
                    self.focus.logical == Some(window)
                } else {
                    self.focus.observed_native.as_ref().is_some_and(|held| {
                        held.window == window
                            && held.identity == observed.identity
                            && held.generation == observed.generation
                    })
                };
                // Event delivery (docs/crates/desktop/LIFECYCLE.md): the same report again while
                // the window is still off screen and the flight the first one
                // armed is in the air asks for what is already under way.
                // Upstream's repeat sets the camera target it already has.
                let revealing = home.is_some_and(|home| {
                    self.on_canvas(window) && self.flying_to(window, home, self.activation_zoom())
                });
                if self.scene.focused() == Some(window)
                    && holds_keyboard
                    && (share >= ACTIVATION_ONSCREEN_THRESHOLD || revealing)
                {
                    return Ok(Moved::default().reply_with_dirty());
                }
                // A hover focus's own echo: recorded where the window stands.
                if !family && let Some(echo) = self.hover_echo(&observed)? {
                    return Ok(echo);
                }
                // Upstream activate_window_output_local: another window being
                // activated on a fullscreen output ends that fullscreen first,
                // so the target is not focused behind it and what is visible
                // is judged by the restored camera, not the parked one.
                let ended = home
                    .filter(|home| self.fullscreen_on(*home).is_some_and(|held| held != window))
                    .and_then(|home| self.exit_fullscreen_on(home));
                let share = match ended {
                    Some(_) => shown(self)?,
                    None => share,
                };
                // The observation is the focus: nothing is asked of the adapter.
                self.finish_cycle();
                self.focus.pending_effect = None;
                self.focus.logical = family.then_some(window);
                self.scene.focus(window)?;
                self.confirm_focus(window)?;
                self.focus.observed_native = (!family).then_some(observed);
                // Upstream activate_window_output_local: wholly visible on its
                // home output is focus only; any clipping pans that output. A
                // widget or a screen-pinned window is focused where it is.
                let navigation = match home {
                    Some(home)
                        if share < ACTIVATION_VISIBLE_THRESHOLD && self.on_canvas(window) =>
                    {
                        self.arm_navigation(window, home, self.activation_zoom())?
                    }
                    _ => Value::Null,
                };
                Moved {
                    effect: Value::Null,
                    navigation,
                    refocused: true,
                }
            }
        };
        Ok(moved.reply_with_dirty())
    }
}
