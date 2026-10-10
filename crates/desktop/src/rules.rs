// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/handlers/compositor.rs (a new toplevel's first sized commit: the rules
// resolved once and stored, the pinned_to_screen and position arms, what a
// widget and `focus_on_open = false` leave out), src/state/pinned.rs
// (pin_window, unpin_window, sync_pinned_locs, send_pinned_to_output,
// reassign_orphaned_pinned, clamp_pin_frame), src/state/mod.rs
// (is_canvas_window), src/state/output.rs (output_for_window),
// src/state/persistence.rs (screen_space_inventory), src/input/actions.rs
// (toggle_pin_to_screen, MoveToBookmark), src/input/pointer.rs (the move and
// resize bindings pass over widgets; upstream drags and resizes a pinned
// window in screen space through try_pinned_button: the drag is
// passthrough.rs's, the resize is not adapted),
// src/ipc/mod.rs (cmd_pin, cmd_opacity) and src/canvas.rs
// (rule_to_screen_top_left, screen_top_left_to_rule). reassign_orphaned_pinned
// runs when the shell reports its outputs settled, not at each removal: the
// shell removes every output on any screen change and registers them again.
// The matcher, the merge and the opacity rule are not
// adapted: they are driftwm-core's `Config::resolve_window_rules`,
// `AppliedWindowRule` and `effective_opacity`, upstream's own code. The
// stacking rule is `Stage::enforce_stacking`, replayed on the scene. Native
// frames already include their title bar, so chrome is zero. A rule's `size`
// is asked of a newly placed window through sizes.rs's `request_window_size`
// when the shell can deliver one (`native_resize_capability`), and is recorded
// and not applied otherwise; `fullscreen` is recorded and never applied.
use super::actions::Outcome;
use super::ipc::{
    OutputPinned, Reply, Response, WindowSelector, frame, internal_to_rule, readable,
    rule_to_internal,
};
use super::lifecycle::Arrival;
use super::view_actions::pixel_size;
use super::*;
use driftwm_canvas::Placement;
use driftwm_canvas::policy::PixelSize;
use driftwm_core::config::{AppliedWindowRule, DecorationMode, PassList, effective_opacity};
use std::collections::BTreeSet;

/// Upstream pin_window's only refusal: a keybinding ignores it.
const NO_OUTPUT: &str = "no output to pin to";

/// Upstream PinnedSite: the output a window is fixed to and its top-left
/// there, in whole output-local points, Y down, whatever the zoom.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Pin {
    pub(crate) output: OutputId,
    pub(crate) screen_pos: [i32; 2],
}
/// DriftWM's per-window policy. Upstream keeps the first on the surface and
/// the second on the stage.
#[derive(Clone, Debug, Default)]
pub(crate) struct Policy {
    /// The rules a window matched when it mapped, merged. An IPC `Opacity`
    /// write lands here too, on an empty rule when none matched. Never saved:
    /// every window maps again at the next launch.
    pub(crate) applied: BTreeMap<WindowId, AppliedWindowRule>,
    /// The screen-pinned windows. Saved with their slots.
    pub(crate) pins: BTreeMap<WindowId, Pin>,
    /// The windows whose rule's `size` was asked of them as they mapped, or
    /// who had it already. Never saved.
    pub(crate) sized: BTreeSet<WindowId>,
}

/// A decoration mode under upstream's config spelling: the snapshot's
/// `rule.decoration` and `decoration.mode`.
pub(crate) fn decoration_name(mode: &DecorationMode) -> &'static str {
    match mode {
        DecorationMode::Client => "client",
        DecorationMode::Server => "server",
        DecorationMode::Minimal => "minimal",
        DecorationMode::None => "none",
    }
}
fn pass_name<C>(list: &PassList<C>) -> &'static str {
    match list {
        PassList::None => "none",
        PassList::All => "all",
        PassList::Only(_) => "only",
    }
}
/// The applied rule under upstream's field names. `not_applied` names the set
/// fields that change nothing here. `sized` says the rule's `size` was asked
/// of the window when it mapped. `layer_order` is among them by upstream's
/// own rule: it orders layer-shell surfaces and is "Ignored for regular
/// windows" (docs/config.md), and every window here is a regular one.
fn rule_json(rule: &AppliedWindowRule, sized: bool) -> Value {
    let not_applied: Vec<&str> = [
        (rule.size.is_some() && !sized, "size"),
        (rule.fullscreen.is_some(), "fullscreen"),
        (rule.preserve_aspect_ratio, "preserve_aspect_ratio"),
        (rule.layer_order.is_some(), "layer_order"),
    ]
    .into_iter()
    .filter_map(|(set, name)| set.then_some(name))
    .collect();
    json!({
        "opacity":rule.opacity,
        "decoration":rule.decoration.as_ref().map(decoration_name),
        "blur":rule.blur,
        "widget":rule.widget,
        "pinned_to_screen":rule.pinned_to_screen,
        "position":rule.position,
        "size":rule.size,
        "output":rule.output,
        "fullscreen":rule.fullscreen,
        "focus_on_open":rule.focus_on_open,
        "suspend_on_close":rule.suspend_on_close,
        "restore_windows":rule.restore_windows,
        "preserve_aspect_ratio":rule.preserve_aspect_ratio,
        "pass_keys":pass_name(&rule.pass_keys),
        "pass_mouse":pass_name(&rule.pass_mouse),
        "border_width":rule.border_width,
        "border_color":rule.border_color,
        "border_color_focused":rule.border_color_focused,
        "corner_radius":rule.corner_radius,
        "shadow":rule.shadow,
        "layer_order":rule.layer_order,
        "not_applied":not_applied,
    })
}
/// Upstream clamp_pin_frame: the whole frame stays on the output, and one too
/// large for it parks its top-left at the output's origin.
fn clamp_pin(at: [i64; 2], size: PixelSize, output: PixelSize) -> [i32; 2] {
    let fit = |at: i64, extent: i32, span: i32| {
        at.clamp(0, i64::from(span.saturating_sub(extent).max(0)))
    };
    [
        fit(at[0], size.w, output.w) as i32,
        fit(at[1], size.h, output.h) as i32,
    ]
}
/// Upstream screen_to_canvas, rounded as every pin caller rounds it: the
/// canvas point the pin's top-left shows on its output right now.
fn pin_canvas(viewport: &Viewport, at: [i32; 2]) -> Point {
    let canvas = viewport.camera + Point::new(f64::from(at[0]), f64::from(at[1])) / viewport.zoom;
    Point::new(canvas.x.round(), canvas.y.round())
}

impl Controller {
    /// Upstream is_widget: the rule the window mapped with says so.
    pub(crate) fn is_widget(&self, window: WindowId) -> bool {
        self.policy.applied.get(&window).is_some_and(|r| r.widget)
    }
    pub(crate) fn is_pinned(&self, window: WindowId) -> bool {
        self.policy.pins.contains_key(&window)
    }
    /// Upstream is_canvas_window: neither a widget nor screen-pinned. The test
    /// for navigation, the focus history, snapping, fitting and placement.
    pub(crate) fn on_canvas(&self, window: WindowId) -> bool {
        !self.is_widget(window) && !self.is_pinned(window)
    }
    /// Upstream's move and resize bindings pass over a widget. A
    /// screen-pinned window is refused here too: this is the guard of a
    /// resize, which upstream does in screen space
    /// (start_compositor_resize_with_edge) and which needs native resize. A
    /// move of one never asks: `install_drag` drags it in screen space instead.
    pub(crate) fn movable(&self, window: WindowId) -> Result<(), Error> {
        if self.is_widget(window) {
            return Err(Error::Invalid("a widget is not moved or resized by hand"));
        }
        if self.is_pinned(window) {
            return Err(Error::Invalid(
                "a screen-pinned window is not moved or resized by hand",
            ));
        }
        Ok(())
    }
    /// The rule a window is drawn with: the one it mapped with, an IPC
    /// `Opacity` write included. Only a bound window has one: a stand-in and
    /// a detached slot have no client to carry a rule, and upstream draws a
    /// stand-in from the global table alone. The one source for the
    /// snapshot's `opacity`, its `decoration` and a `Window` capture.
    pub(crate) fn drawn_rule(&self, window: WindowId) -> Option<&AppliedWindowRule> {
        self.policy
            .applied
            .get(&window)
            .filter(|_| self.sources.contains_key(&window))
    }
    /// The opacity a window is drawn at: upstream's effective_opacity, with
    /// the logical focus for upstream's keyboard focus. Nothing is fullscreen.
    /// A window without a source is opaque: upstream's push_suspended_element
    /// resolves no opacity, and its `alpha` is 1.0 outside the adoption
    /// crossfade, which the shell plays (effects.rs).
    pub(crate) fn opacity_of(&self, window: WindowId) -> f64 {
        if !self.sources.contains_key(&window) {
            return 1.0;
        }
        effective_opacity(
            self.drawn_rule(window),
            &self.config().decorations,
            self.scene.focused() == Some(window),
            false,
        )
    }
    /// A pinned window's output and its rectangle in global screen points. Its
    /// size is its own at every zoom. `None` while its output is disconnected.
    fn pinned_rect(&self, window: WindowId) -> Option<(OutputId, Rect)> {
        let pin = self.policy.pins.get(&window)?;
        let viewport = self.scene.output(pin.output)?;
        let at = Point::new(f64::from(pin.screen_pos[0]), f64::from(pin.screen_pos[1]));
        Some((
            pin.output,
            Rect {
                origin: viewport.screen_bounds.origin + at,
                size: self.scene.window(window)?.world_rect.size,
            },
        ))
    }
    /// A connected output by upstream's output name, the stable id here.
    fn output_named(&self, name: &str) -> Option<OutputId> {
        self.outputs
            .iter()
            .find(|(id, saved)| saved.stable_id == name && self.scene.output(**id).is_some())
            .map(|(id, _)| *id)
    }
    /// Upstream's rule arms of a new toplevel's placement, tried before
    /// `window_placement`. `pinned_to_screen` fixes the frame to the rule's
    /// `output`, else the active one: `position` is the frame's center from
    /// the output's center, Y up, the output's center without one, and the
    /// frame is clamped onto the output. With no output to pin to, and for
    /// every other window, a `position` is the frame's center on the canvas,
    /// Y up, and nothing cascades. `None` leaves the placement to the policy.
    pub(crate) fn rule_arrival(
        &self,
        active: Option<OutputId>,
        size: Size,
        rule: Option<&AppliedWindowRule>,
    ) -> Result<Option<Arrival>, Error> {
        let Some(rule) = rule else {
            return Ok(None);
        };
        // Upstream geometry is whole pixels; the world frame keeps the true size.
        let whole = pixel_size(size)?;
        let extent = [i64::from(whole.w), i64::from(whole.h)];
        let output = rule
            .output
            .as_deref()
            .and_then(|name| self.output_named(name))
            .or(active)
            .and_then(|id| self.scene.output(id));
        if let Some(viewport) = output.filter(|_| rule.pinned_to_screen) {
            let on = pixel_size(viewport.screen_bounds.size)?;
            let (x, y) = rule.position.unwrap_or((0, 0));
            let corner = rule_to_internal(x, y, extent);
            let at = [
                i64::from(on.w / 2) + corner.x as i64,
                i64::from(on.h / 2) + corner.y as i64,
            ];
            let pin = Pin {
                output: viewport.id,
                screen_pos: clamp_pin(at, whole, on),
            };
            let rect = Rect {
                origin: pin_canvas(viewport, pin.screen_pos),
                size,
            };
            readable(rect).map_err(Error::Refused)?;
            return Ok(Some(Arrival::Pin { rect, pin }));
        }
        let Some((x, y)) = rule.position else {
            return Ok(None);
        };
        let rect = Rect {
            origin: rule_to_internal(x, y, extent),
            size,
        };
        readable(rect).map_err(Error::Refused)?;
        Ok(Some(Arrival::Place {
            rect,
            at_cursor: false,
        }))
    }
    /// Upstream stores the merged rule on the surface each time a window maps,
    /// a window that takes over a slot included; a window no rule matches
    /// carries none. A rule-pinned window gets its site.
    pub(crate) fn map_rule(
        &mut self,
        window: WindowId,
        rule: Option<AppliedWindowRule>,
        arrival: Option<Arrival>,
    ) {
        match rule {
            Some(rule) => self.policy.applied.insert(window, rule),
            None => self.policy.applied.remove(&window),
        };
        self.policy.sized.remove(&window);
        if let Some(Arrival::Pin { pin, .. }) = arrival {
            self.policy.pins.insert(window, pin);
        }
    }
    /// Upstream's size arm of a new toplevel's first commit: a rule's `size`
    /// is asked of the window as it maps. Upstream configures the client
    /// first and places it on the follow-up commit; here the window is placed
    /// at its own size and the rule's is then asked through
    /// `request_window_size`, which keeps the frame's center, so a ruled
    /// `position`, the placement policy and the arrival's flight aim at the
    /// same point either way. `reply` is `settle_arrival`'s and gains the
    /// size transaction when one began: `transaction`, and its effect as the
    /// one entry of `effects`, because `effect` is the focus request there.
    ///
    /// Only a shell that can deliver a size is asked. A window that takes
    /// over a slot keeps the slot's frame, as upstream's adopted window does.
    /// A widget and a window the rule pinned are not canvas windows and are
    /// never asked, whatever size they have, which is a gap: upstream's size
    /// arm runs before its pin and widget arms. A size that cannot be asked
    /// right now leaves the window mapped at its own size too: a drag or
    /// another size transaction in progress (there is one slot, and nothing
    /// is queued), or a window whose native resize is unsupported. In each of
    /// those cases `rule.not_applied` keeps `size`; a canvas window that maps
    /// with the rule's size already needs nothing.
    pub(crate) fn size_by_rule(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        arrival: Arrival,
        mut reply: Value,
    ) -> Value {
        let size = self.policy.applied.get(&window).and_then(|r| r.size);
        let (Some((width, height)), Arrival::Place { .. }, true) =
            (size, arrival, self.sizes.capability)
        else {
            return reply;
        };
        if !self.on_canvas(window) {
            return reply;
        }
        // A refusal must leave nothing half written, and never fails the map.
        let mut next = self.clone();
        let mut outcome = Outcome::default();
        let size = [width.into(), height.into()];
        if next
            .request_window_size(window, output, size, &mut outcome)
            .is_err()
        {
            return reply;
        }
        next.policy.sized.insert(window);
        *self = next;
        if let Some(mut began) = outcome.resize.filter(|r| r["effect"].is_object()) {
            reply["transaction"] = began["transaction"].take();
            reply["effects"] = json!([began["effect"].take()]);
        }
        reply
    }
    /// A pin changes which space a frame lives in, so it waits for a drag or
    /// resize to end, as `place_window` does.
    fn pin_guard(&self, window: WindowId) -> Result<(), String> {
        if self.gesture.is_some() {
            return Err("a window is under an interactive move or resize".to_string());
        }
        self.guard_resize_structure(Some(window))
            .map_err(|e| e.to_string())
    }
    /// Upstream pin_window: pin the window where it is drawn right now, on
    /// the output showing its center, else the active one. Its top-left keeps
    /// its place on the screen; its size becomes its own at every zoom. A
    /// pinned window leaves the focus history.
    pub(crate) fn pin_window(
        &mut self,
        window: WindowId,
        active: Option<OutputId>,
    ) -> Result<(), String> {
        if self.is_pinned(window) {
            return Ok(());
        }
        self.pin_guard(window)?;
        let rect = self
            .scene
            .window(window)
            .ok_or_else(|| "unknown window".to_string())?
            .world_rect;
        let viewport = self
            .scene
            .outputs()
            .iter()
            .find(|o| o.world_bounds().contains(rect.center()))
            .or_else(|| active.and_then(|id| self.scene.output(id)))
            .ok_or_else(|| NO_OUTPUT.to_string())?;
        let screen = (rect.origin - viewport.camera) * viewport.zoom;
        let whole = |value: f64| {
            let value = value.round();
            (f64::from(i32::MIN)..=f64::from(i32::MAX))
                .contains(&value)
                .then_some(value as i32)
        };
        let (Some(x), Some(y)) = (whole(screen.x), whole(screen.y)) else {
            return Err("window geometry exceeds integer range".to_string());
        };
        let pin = Pin {
            output: viewport.id,
            screen_pos: [x, y],
        };
        self.scene.drop_focus_history(window);
        self.policy.pins.insert(window, pin);
        Ok(())
    }
    /// Upstream unpin_window: back to the canvas at the point the pin shows
    /// under the current camera and zoom, so its top-left does not move on
    /// screen, and raised as upstream's re-map raises it. `activate` puts the
    /// focused window back in the focus history. With its output gone the
    /// frame stays where the pin last showed it.
    pub(crate) fn unpin_window(&mut self, window: WindowId, activate: bool) -> Result<(), String> {
        let Some(pin) = self.policy.pins.get(&window).copied() else {
            return Ok(());
        };
        self.pin_guard(window)?;
        let text = |e: driftwm_canvas::Error| e.to_string();
        let landing = match (self.scene.output(pin.output), self.scene.window(window)) {
            (Some(viewport), Some(pinned)) => Some(Rect {
                origin: pin_canvas(viewport, pin.screen_pos),
                size: pinned.world_rect.size,
            }),
            _ => None,
        };
        if let Some(rect) = landing {
            readable(rect)?;
            self.scene.set_window_rect(window, rect).map_err(text)?;
            self.scene.raise(window).map_err(text)?;
        }
        self.policy.pins.remove(&window);
        // The history takes it back under its own rule: a focus the adapter
        // confirmed, observed or answered `focus_logical`, and never a widget.
        if landing.is_some() && activate {
            let native = self.focus.observed_native.as_ref();
            if native.is_some_and(|f| f.window == window) || self.focus.logical == Some(window) {
                self.confirm_focus(window).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
    /// Upstream toggle_pin_to_screen: the focused live window. A stand-in and
    /// a window with no output to pin to stay as they are.
    pub(crate) fn toggle_pin(&mut self, active: Option<OutputId>) -> Result<bool, Error> {
        let live = |id: &WindowId| self.sources.contains_key(id);
        let Some(window) = self.scene.focused().filter(live) else {
            return Ok(false);
        };
        if self.is_pinned(window) {
            self.unpin_window(window, true).map_err(Error::Refused)?;
            return Ok(true);
        }
        match self.pin_window(window, active) {
            Ok(()) => Ok(true),
            Err(error) if error == NO_OUTPUT => Ok(false),
            Err(error) => Err(Error::Refused(error)),
        }
    }
    /// Upstream MoveToBookmark: the focused window's frame is centered on the
    /// bookmark's canvas point, rounded to whole pixels, and raised. A missing
    /// bookmark, a widget and a pinned window are passed over without an
    /// error. A focused stand-in moves in place, unraised.
    pub(crate) fn move_to_bookmark(&mut self, name: &str) -> Result<bool, Error> {
        let Some(&[x, y]) = self.bookmarks.get(name) else {
            return Ok(false);
        };
        let Some(window) = self.scene.focused().filter(|id| !self.is_widget(*id)) else {
            return Ok(false);
        };
        if self.is_pinned(window) {
            return Ok(false);
        }
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let (_, extent) = frame(rect).map_err(Error::Refused)?;
        let moved = Rect {
            origin: rule_to_internal(x.round() as i32, y.round() as i32, extent),
            size: rect.size,
        };
        self.place_window(window, moved).map_err(Error::Refused)?;
        if self.sources.contains_key(&window) {
            self.scene.raise(window)?;
        }
        Ok(true)
    }
    /// Upstream cmd_pin: `toggle-pin-to-screen` as a bool, for any live window.
    pub(crate) fn cmd_pin(
        &mut self,
        active: Option<OutputId>,
        selector: Option<&WindowSelector>,
        value: Option<bool>,
        outcome: &mut Outcome,
    ) -> Reply {
        let window = self.select(selector)?;
        if !self.sources.contains_key(&window) {
            return Err("stand-ins can't be pinned".to_string());
        }
        let pinned = self.is_pinned(window);
        let Some(value) = value else {
            return Ok(Response::Pin(pinned));
        };
        if value == pinned {
            return Ok(Response::Pin(value));
        }
        if value {
            self.pin_window(window, active)?;
        } else {
            // Only the window that holds the focus is activated; a widget never is.
            let activate = self.scene.focused() == Some(window) && !self.is_widget(window);
            self.unpin_window(window, activate)?;
        }
        outcome.dirty = true;
        Ok(Response::Pin(value))
    }
    /// Upstream cmd_opacity: a live window's opacity. A write pins it, in both
    /// focus states and for a widget or a pinned window alike, until the
    /// window is gone; out of range is refused, not clamped.
    pub(crate) fn cmd_opacity(
        &mut self,
        selector: Option<&WindowSelector>,
        value: Option<f64>,
    ) -> Reply {
        let window = self.select_live(selector)?;
        let Some(value) = value else {
            return Ok(Response::Opacity(self.opacity_of(window)));
        };
        if !value.is_finite() || !(0.0..=1.0).contains(&value) {
            return Err("opacity must be between 0.0 and 1.0".to_string());
        }
        self.policy.applied.entry(window).or_default().opacity = Some(value);
        Ok(Response::Opacity(value))
    }
    /// Upstream screen_space_inventory: the pinned windows of the connected
    /// outputs, each with the `position` and `size` a `pinned_to_screen` rule
    /// takes, sorted by output name and position.
    pub(crate) fn pinned_inventory(&self) -> Result<Vec<OutputPinned>, String> {
        let mut pinned = Vec::new();
        for window in self.scene.windows() {
            let Some(pin) = self.policy.pins.get(&window.id) else {
                continue;
            };
            let Some(viewport) = self.scene.output(pin.output) else {
                continue;
            };
            let on = pixel_size(viewport.screen_bounds.size).map_err(|e| e.to_string())?;
            let (_, size) = frame(window.world_rect)?;
            let from_center = [
                i64::from(pin.screen_pos[0]) - i64::from(on.w / 2),
                i64::from(pin.screen_pos[1]) - i64::from(on.h / 2),
            ];
            let metadata = self.metadata.get(&window.id);
            pinned.push(OutputPinned {
                id: window.id.0,
                output: self
                    .outputs
                    .get(&pin.output)
                    .map(|o| o.stable_id.clone())
                    .unwrap_or_default(),
                app_id: metadata.map(|m| m.bundle_id.clone()).unwrap_or_default(),
                title: metadata.map(|m| m.title.clone()).unwrap_or_default(),
                position: internal_to_rule(from_center, size)?,
                size: [size[0] as i32, size[1] as i32],
            });
        }
        pinned.sort_by(|a, b| (&a.output, a.position).cmp(&(&b.output, b.position)));
        Ok(pinned)
    }
    /// Upstream send_pinned_to_output: bind a pin to `to`, keeping its place
    /// on the screen as far as the whole frame fits there.
    fn rebind_pin(&mut self, window: WindowId, to: OutputId) {
        let (Some(viewport), Some(pinned)) = (self.scene.output(to), self.scene.window(window))
        else {
            return;
        };
        let (Ok(on), Ok(size)) = (
            pixel_size(viewport.screen_bounds.size),
            pixel_size(pinned.world_rect.size),
        ) else {
            return;
        };
        if let Some(pin) = self.policy.pins.get_mut(&window) {
            let at = pin.screen_pos.map(i64::from);
            *pin = Pin {
                output: to,
                screen_pos: clamp_pin(at, size, on),
            };
        }
    }
    /// The output a screen-pinned window is fixed to, connected or not.
    pub(crate) fn pin_output(&self, window: WindowId) -> Option<OutputId> {
        self.policy.pins.get(&window).map(|pin| pin.output)
    }
    /// Upstream send_pinned_to_output, for `send-to-output`: the pin is bound
    /// to `to` and keeps its place on the screen, clamped until the whole
    /// frame is on that output. Nothing is raised or focused: a pinned window
    /// is outside the focus history and already holds the focus. Like a pin
    /// or an unpin it waits for a drag or resize to end. True when the pin
    /// changed.
    pub(crate) fn send_pinned_to_output(
        &mut self,
        window: WindowId,
        to: OutputId,
    ) -> Result<bool, String> {
        let Some(pin) = self.policy.pins.get(&window).copied() else {
            return Ok(false);
        };
        if pin.output == to {
            return Ok(false);
        }
        self.pin_guard(window)?;
        self.rebind_pin(window, to);
        Ok(self.policy.pins.get(&window) != Some(&pin))
    }
    /// An output has connected for the first time in this run, or at another
    /// size than it had: its own pins are clamped into its bounds. No pin of
    /// another output is taken here.
    pub(crate) fn output_connected(&mut self, to: OutputId) {
        let own: Vec<WindowId> = self
            .policy
            .pins
            .iter()
            .filter(|(_, pin)| pin.output == to)
            .map(|(id, _)| *id)
            .collect();
        for window in own {
            self.rebind_pin(window, to);
        }
    }
    /// Upstream reassign_orphaned_pinned: the pins whose output is not
    /// connected move to the first one that is, clamped into its bounds.
    /// Upstream runs it as an output is unplugged. The shell removes every
    /// output on any screen change and registers the current ones again, so
    /// here it waits for the shell to say they are all registered
    /// (`outputs_settled`), or for a discovery pass to end. True when a pin
    /// moved.
    pub(crate) fn rehome_pins(&mut self) -> bool {
        let Some(to) = self.scene.outputs().first().map(|o| o.id) else {
            return false;
        };
        let homeless: Vec<WindowId> = self
            .policy
            .pins
            .iter()
            .filter(|(_, pin)| self.scene.output(pin.output).is_none())
            .map(|(id, _)| *id)
            .collect();
        for window in &homeless {
            self.rebind_pin(*window, to);
        }
        !homeless.is_empty()
    }
    /// Re-assert what every command must leave true, as upstream does after
    /// each change. A window that is gone has no rule and no pin. Each pinned
    /// window's canvas frame is re-anchored to the point its pin shows
    /// (sync_pinned_locs), so the frame an unpin, a stand-in or a save takes
    /// is the one on screen. A stand-in is neither pinned nor a widget: it
    /// keeps that frame. Widgets and pinned windows stay out of the focus
    /// history and out of snapping, and every other window is stacked above
    /// the widgets (enforce_stacking).
    pub(crate) fn settle_policy(&mut self) -> Result<(), Error> {
        let scene = &self.scene;
        self.policy
            .applied
            .retain(|id, _| scene.window(*id).is_some());
        self.policy.pins.retain(|id, _| scene.window(*id).is_some());
        let synced: Vec<(WindowId, Rect)> = self
            .policy
            .pins
            .iter()
            .filter_map(|(id, pin)| {
                let viewport = self.scene.output(pin.output)?;
                let rect = self.scene.window(*id)?.world_rect;
                let synced = Rect {
                    origin: pin_canvas(viewport, pin.screen_pos),
                    size: rect.size,
                };
                (synced != rect && readable(synced).is_ok()).then_some((*id, synced))
            })
            .collect();
        for (id, rect) in synced {
            self.scene.set_window_rect(id, rect)?;
        }
        // A stand-in that a relaunched window has just taken over is listed
        // until the lifecycle is pruned, and is no stand-in any more.
        let (standins, sources) = (&self.lifecycle.standins, &self.sources);
        let live = |id: &WindowId| !standins.contains(id) || sources.contains_key(id);
        self.policy.pins.retain(|id, _| live(id));
        self.policy.applied.retain(|id, _| live(id));
        let applied = &self.policy.applied;
        self.policy.sized.retain(|id| applied.contains_key(id));
        self.settle_pinned_drag();
        let order: Vec<WindowId> = self.scene.windows().iter().map(|w| w.id).collect();
        for id in &order {
            let snaps = self.on_canvas(*id);
            if !snaps {
                self.scene.drop_focus_history(*id);
            }
            if self.scene.snaps(*id) != snaps {
                self.scene.set_snapping(*id, snaps)?;
            }
        }
        let above: Vec<WindowId> = order
            .iter()
            .copied()
            .skip_while(|id| self.is_widget(*id))
            .collect();
        if above.iter().any(|id| self.is_widget(*id)) {
            let raised: Vec<WindowId> = above
                .into_iter()
                .filter(|id| !self.is_widget(*id))
                .collect();
            for id in raised {
                self.scene.raise(id)?;
            }
        }
        Ok(())
    }
    /// The topmost window under a global screen point of `output`, and the
    /// point in its frame. Upstream's order: the windows pinned to this
    /// output, then the canvas windows, then the widgets.
    pub(crate) fn hit_window(&self, output: OutputId, screen: Point) -> Option<(WindowId, Point)> {
        let viewport = self.scene.output(output)?;
        if !viewport.screen_bounds.contains(screen) {
            return None;
        }
        let windows = self.scene.windows();
        let pinned = windows.iter().rev().find_map(|w| {
            let (on, rect) = self.pinned_rect(w.id)?;
            (on == output && rect.contains(screen)).then(|| (w.id, screen - rect.origin))
        });
        let world = viewport.screen_to_world(screen);
        let under = |widgets: bool| {
            windows
                .iter()
                .rev()
                .filter(|w| !self.is_pinned(w.id) && self.is_widget(w.id) == widgets)
                .find(|w| w.world_rect.contains(world))
                .map(|w| (w.id, world - w.world_rect.origin))
        };
        pinned.or_else(|| under(false)).or_else(|| under(true))
    }
    /// The topmost canvas window under a global screen point of `output`:
    /// upstream's canvas-space walk, which skips a screen-pinned window, less
    /// the widgets, which are no navigation target. For `focus-center`.
    pub(crate) fn canvas_window_under(&self, output: OutputId, screen: Point) -> Option<WindowId> {
        let viewport = self.scene.output(output)?;
        if !viewport.screen_bounds.contains(screen) {
            return None;
        }
        let world = viewport.screen_to_world(screen);
        self.scene
            .windows()
            .iter()
            .rev()
            .find(|w| self.on_canvas(w.id) && w.world_rect.contains(world))
            .map(|w| w.id)
    }
    /// What to draw, bottom to top within each output: the widgets, the canvas
    /// windows, then the windows pinned to that output, each in stacking
    /// order. A pinned window's rectangle is its pin's, in screen space at its
    /// own size; it is drawn on no other output.
    pub(crate) fn layered_placements(&self) -> Vec<(Placement, bool)> {
        let projected = self.scene.placements();
        let mut layered = Vec::with_capacity(projected.len());
        for viewport in self.scene.outputs() {
            for widgets in [true, false] {
                layered.extend(
                    projected
                        .iter()
                        .filter(|p| {
                            p.output == viewport.id
                                && !self.is_pinned(p.window)
                                && self.is_widget(p.window) == widgets
                        })
                        .map(|p| (p.clone(), false)),
                );
            }
            for window in self.scene.windows() {
                let Some((on, screen_rect)) = self.pinned_rect(window.id) else {
                    continue;
                };
                let Some(clip_rect) = screen_rect
                    .intersection(viewport.screen_bounds)
                    .filter(|_| on == viewport.id)
                else {
                    continue;
                };
                let source_rect = Rect {
                    origin: clip_rect.origin - screen_rect.origin,
                    size: clip_rect.size,
                };
                layered.push((
                    Placement {
                        window: window.id,
                        output: on,
                        screen_rect,
                        clip_rect,
                        source_rect,
                    },
                    true,
                ));
            }
        }
        layered
    }
    /// A window's policy as the snapshot reports it: `widget`, `pinned` and
    /// `rule`.
    pub(crate) fn policy_json(&self, window: WindowId) -> (bool, Value, Value) {
        let pinned = self.policy.pins.get(&window).map(|pin| {
            let screen_rect = self.pinned_rect(window).map(|(_, rect)| rect);
            json!({"output":pin.output,"screen_rect":screen_rect})
        });
        let sized = self.policy.sized.contains(&window);
        let rule = self
            .policy
            .applied
            .get(&window)
            .map(|rule| rule_json(rule, sized));
        (self.is_widget(window), json!(pinned), json!(rule))
    }
}
