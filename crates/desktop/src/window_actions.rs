// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/actions.rs (CenterWindow, FocusCenter, CenterNearest, CycleWindows),
// src/state/navigation.rs (navigate_to_window_on, resolve_click_navigate,
// fire_click_navigate, activate_window_output_local, window_already_active,
// nav_center, element_closest_point), src/state/viewport.rs (viewport_center_canvas,
// window_visible_at_least_on), src/state/output.rs (output_for_window,
// output_shows_canvas_point), src/state/keyboard_focus.rs (raise_and_focus,
// clear_focus_to_empty_canvas), src/state/suspended.rs (center_on_suspended:
// a stand-in is centered like a client), src/input/pointer.rs (the
// click-to-focus fallback) and src/handlers/mod.rs (focus_changed's cycle rule
// and the activation request's already-active rule). The directional search and the
// visibility measures are driftwm-core's `canvas::{find_nearest,
// visible_fraction, visible_canvas_rect}`, upstream's own code. A detached
// placeholder is upstream's stand-in. The candidates of every search here are
// upstream's canvas windows (`is_canvas_window`, `Controller::on_canvas`): no
// widget and no screen-pinned window, which are raised and focused where they
// are and never flown to (RULES.md). Fullscreen, modal and fill handling is
// absent. Only world rectangles, output poses and the navigation context are
// read, never native geometry.
use super::view_actions::{pixel, pixel_size};
use super::*;
use driftwm_core::canvas::{find_nearest, visible_canvas_rect, visible_fraction};
use driftwm_core::config::Direction;
use driftwm_core::platform::utils::{Logical, Point as CorePoint};

/// Upstream CENTER_NEAREST_ANCHOR_THRESHOLD: the focused window is the origin
/// of a directional search only while all of it is on the output.
const CENTER_NEAREST_ANCHOR_THRESHOLD: f64 = 1.0;
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
enum NavTarget {
    Window(WindowId),
    Anchor(Point),
}
fn core_point(point: Point) -> CorePoint<f64, Logical> {
    CorePoint::from((point.x, point.y))
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
            core_point(viewport.camera),
            (size.w, size.h).into(),
            viewport.zoom,
        ))
    }
    /// Upstream output_for_window: the first output, in registration order,
    /// whose viewport shows the frame's center (output_shows_canvas_point: the
    /// camera rounded, two spare pixels, the point truncated), else the active
    /// one. An output whose pose leaves the integer range shows nothing.
    fn home_output(
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
        let Some(window) = self.scene.cycle_focus(backward)? else {
            return Ok(None);
        };
        let navigation = self.arm_navigation(window, output, ZoomPolicy::Keep)?;
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
    /// nothing focused. Upstream's policy is RestoreFillElseReset; there is no
    /// fill here, so it is always Reset.
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
            Some(window) => self.navigate_to_window(window, output, ZoomPolicy::Reset),
            None => Ok(Moved::default()),
        }
    }
    /// Upstream FocusCenter: the topmost canvas window under the pointer, at
    /// zoom 1. A screen-pinned window there is passed over, as upstream's walk
    /// skips it, and a widget is no candidate. `pointer` is a global screen
    /// point; with none, or with no canvas window of `output` under it, nothing
    /// happens.
    pub(crate) fn focus_center(
        &mut self,
        output: OutputId,
        pointer: Option<Point>,
    ) -> Result<Moved, Error> {
        self.view(output)?;
        match pointer.and_then(|pointer| self.canvas_window_under(output, pointer)) {
            Some(window) => self.navigate_to_window(window, output, ZoomPolicy::Reset),
            None => Ok(Moved::default()),
        }
    }
    /// Upstream CenterNearest: the nearest canvas window or
    /// `navigation.anchors` point in a 90° cone. The search starts at the
    /// focused window while all of it is on the output and it is not
    /// screen-pinned, and at the viewport center otherwise. A window is
    /// flown to at the current zoom; an anchor clears focus, so that the next
    /// search starts from the viewport center, which is then that anchor.
    pub(crate) fn center_nearest(
        &mut self,
        output: OutputId,
        direction: &Direction,
    ) -> Result<Moved, Error> {
        let (viewport, usable) = self.view(output)?;
        let anchor = match self.scene.focused().filter(|id| !self.is_pinned(*id)) {
            Some(window)
                if self.visible_share(window, output)? >= CENTER_NEAREST_ANCHOR_THRESHOLD =>
            {
                Some(window)
            }
            _ => None,
        };
        let (origin, skip) = match anchor {
            Some(window) => (
                self.window_rect(window)?.center(),
                Some(NavTarget::Window(window)),
            ),
            None => (Self::viewport_center_canvas(&viewport, usable), None),
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
            .filter(|point| point_valid(*point))
            .map(|point| (NavTarget::Anchor(point), core_point(point)));
        let nearest = find_nearest(
            core_point(origin),
            direction,
            windows.chain(anchors),
            skip.as_ref(),
        );
        match nearest {
            Some(NavTarget::Window(window)) => {
                self.navigate_to_window(window, output, ZoomPolicy::Keep)
            }
            Some(NavTarget::Anchor(point)) => {
                let refocused = self.clear_focus();
                self.overview_returns.remove(&output);
                let target = point - usable.center() / viewport.zoom;
                Ok(Moved {
                    effect: Value::Null,
                    navigation: self.set_camera_target(output, target)?["navigation"].take(),
                    refocused,
                })
            }
            None => Ok(Moved::default()),
        }
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
                    Some(output)
                        if self.config().auto_navigate_on_click
                            && self.on_canvas(window)
                            && self.scene.focused() == Some(window)
                            && !self
                                .fully_in_viewport(window, output)
                                .map_err(Error::Refused)? =>
                    {
                        self.arm_navigation(window, output, ZoomPolicy::Keep)?
                    }
                    _ => Value::Null,
                };
                return Ok(json!({"navigation":navigation,"dirty":false}));
            }
            ActivationCause::Native => {
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
                let home = self.home_output(window, output)?;
                let share = match home {
                    Some(home) => self.visible_share(window, home)?,
                    None => 0.0,
                };
                // Upstream window_already_active: the window holds the keyboard
                // and is at least partly on screen, so the request asks for
                // what already holds.
                let holds_keyboard = self.focus.observed_native.as_ref().is_some_and(|held| {
                    held.window == window
                        && held.identity == observed.identity
                        && held.generation == observed.generation
                });
                if self.scene.focused() == Some(window)
                    && holds_keyboard
                    && share >= ACTIVATION_ONSCREEN_THRESHOLD
                {
                    return Ok(Moved::default().reply_with_dirty());
                }
                // The observation is the focus: nothing is asked of the adapter.
                self.finish_cycle();
                self.focus.pending_effect = None;
                self.focus.logical = None;
                self.scene.focus(window)?;
                self.confirm_focus(window)?;
                self.focus.observed_native = Some(observed);
                // Upstream activate_window_output_local: wholly visible on its
                // home output is focus only; any clipping pans that output. A
                // widget or a screen-pinned window is focused where it is.
                let navigation = match home {
                    Some(home)
                        if share < ACTIVATION_VISIBLE_THRESHOLD && self.on_canvas(window) =>
                    {
                        let policy = if self.config().zoom_reset_on_activation {
                            ZoomPolicy::Reset
                        } else {
                            ZoomPolicy::Keep
                        };
                        self.arm_navigation(window, home, policy)?
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
