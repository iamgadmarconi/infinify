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
// follows the size arm of that first commit and the placement of the commit
// after it: when the shell can deliver a size (`native_resize_capability`) the
// new window, a widget and a rule-pinned one included, is placed for the size
// its rule names and asked for it through sizes.rs's `request_window_size`,
// one window at a time in map order; otherwise the size is recorded and not
// applied. `fullscreen` is applied by fullscreen.rs under the same condition,
// after that placement and in place of that request: the rule's size is then
// the one the window comes back to.
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
use std::collections::{BTreeSet, VecDeque};

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
    /// The windows whose rule's `size` is still to be asked, in map order:
    /// there is one size transaction, and each waits for it. Never saved.
    pub(crate) sizing: VecDeque<WindowId>,
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
/// of the window when it mapped, `fullscreened` that its `fullscreen` was
/// applied then. `layer_order` is among them by upstream's own rule: it
/// orders layer-shell surfaces and is "Ignored for regular windows"
/// (docs/config.md), and every window here is a regular one.
fn rule_json(rule: &AppliedWindowRule, sized: bool, fullscreened: bool) -> Value {
    let not_applied: Vec<&str> = [
        (rule.size.is_some() && !sized, "size"),
        (rule.fullscreen.is_some() && !fullscreened, "fullscreen"),
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
pub(crate) fn clamp_pin(at: [i64; 2], size: PixelSize, output: PixelSize) -> [i32; 2] {
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
    /// Upstream's `preserve_aspect_ratio`: the window's interactive resizes
    /// keep the width / height it has when one begins (resize_transaction.rs).
    pub(crate) fn keeps_ratio(&self, window: WindowId) -> bool {
        self.policy
            .applied
            .get(&window)
            .is_some_and(|r| r.preserve_aspect_ratio)
    }
    pub(crate) fn is_pinned(&self, window: WindowId) -> bool {
        self.policy.pins.contains_key(&window)
    }
    /// Upstream is_canvas_window: neither a widget nor screen-pinned nor
    /// fullscreen. The test for navigation, snapping, fitting and placement.
    pub(crate) fn on_canvas(&self, window: WindowId) -> bool {
        self.in_history(window) && !self.is_fullscreen(window)
    }
    /// Upstream update_focus_history's eligibility: neither a widget nor
    /// screen-pinned. A fullscreen window, whose pin is put away, is in it.
    pub(crate) fn in_history(&self, window: WindowId) -> bool {
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
    /// the logical focus for upstream's keyboard focus. A fullscreen window
    /// stays opaque unless its rule or an IPC `Opacity` pins a value.
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
            self.is_fullscreen(window),
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
    pub(crate) fn output_named(&self, name: &str) -> Option<OutputId> {
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
            background: false,
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
        self.policy.sizing.retain(|queued| *queued != window);
        if let Some(Arrival::Pin { pin, .. }) = arrival {
            self.policy.pins.insert(window, pin);
        }
    }
    /// Upstream configures a rule's `size` at a new toplevel's first commit
    /// and places the window on the commit that follows, for the size it then
    /// has: the pin, the `position` and the placement policy all take that
    /// frame, for a widget and a rule-pinned window like any other. So when
    /// the shell can deliver a size, a new window's arrival is computed for
    /// the size its rule names. True when it was. A window that takes over a
    /// slot keeps the slot's frame, as upstream's adopted window does, and a
    /// frame that cannot be placed for the size asked is placed for its own:
    /// neither is asked anything.
    pub(crate) fn arrival_by_rule(
        &self,
        output: Option<OutputId>,
        pointer: Option<Point>,
        bundle_id: &str,
        title: &str,
        own: Size,
        rule: Option<&AppliedWindowRule>,
    ) -> Result<(Arrival, bool), Error> {
        let size = rule.and_then(|rule| rule.size);
        if let Some((width, height)) = size.filter(|_| self.sizes.capability) {
            // Upstream's one-pixel floor, as IPC `resize` applies it.
            let asked = Size::new(width.max(1).into(), height.max(1).into());
            let placed = self.arrival(output, pointer, bundle_id, title, asked, rule);
            if let Ok(arrival @ (Arrival::Place { .. } | Arrival::Pin { .. })) = placed {
                return Ok((arrival, true));
            }
        }
        let arrival = self.arrival(output, pointer, bundle_id, title, own, rule)?;
        Ok((arrival, false))
    }
    /// Upstream's size arm of a new toplevel's first commit: a rule's `size`
    /// is asked of the window as it maps. `own` is the size the window has,
    /// for a window `arrival_by_rule` placed for the size its rule names; the
    /// scene holds that frame, which the arrival's flight was aimed at.
    ///
    /// Only a native observation commits a size, so until the window answers
    /// it has its own, centered in the frame asked for: the request keeps
    /// the center (`request_window_size`), and upstream's truncating halving
    /// then lands it on that frame's top-left exactly. A pinned window stands
    /// at its pin, which was computed for the size asked. A window that
    /// grants another size keeps that top-left, as IPC `resize` leaves it.
    ///
    /// There is one size transaction, so the windows are asked one at a time
    /// in map order (`ask_ruled`). `reply` is `settle_arrival`'s and gains
    /// the transaction that began with this map, this window's or that of
    /// one that was waiting: `transaction`, and its effect as the one entry
    /// of `effects`, because `effect` is the focus request there.
    pub(crate) fn size_by_rule(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        own: Option<Size>,
        mut reply: Value,
    ) -> Value {
        if let (Some(own), Some(rect)) = (own, self.scene.window(window).map(|w| w.world_rect)) {
            // What the frame asked for has over the window's own size.
            let spare = match (frame(rect), pixel_size(own)) {
                (Ok((_, asked)), Ok(whole)) => {
                    Some([asked[0] - i64::from(whole.w), asked[1] - i64::from(whole.h)])
                }
                _ => None,
            };
            let centered = spare
                .filter(|_| !self.is_pinned(window))
                .map(|[w, h]| rect.origin + Point::new((w / 2) as f64, (h / 2) as f64));
            let standing = Rect {
                origin: centered.unwrap_or(rect.origin),
                size: own,
            };
            if self.scene.set_window_rect(window, standing).is_ok() {
                // A window that has the size already is asked nothing.
                if spare == Some([0, 0]) {
                    self.policy.sized.insert(window);
                } else {
                    self.policy.sizing.push_back(window);
                }
            }
        }
        if let Some(mut began) = self.ask_ruled(output) {
            reply["transaction"] = began["transaction"].take();
            reply["effects"] = json!([began["effect"].take()]);
        }
        reply
    }
    /// The frame a new window is placed against. Upstream's stage holds a
    /// ruled window at the frame it was placed for, of the size its rule
    /// names; here one stands inside that frame at its own size until it has
    /// answered, so the cascade and the auto placement of a later arrival
    /// read the frame it is becoming: the one its request named once asked,
    /// and while it waits its turn the one `request_window_size` will name,
    /// which keeps the center in whole pixels. A pinned window has no canvas
    /// frame to read.
    pub(crate) fn placed_rect(&self, window: &Window) -> Rect {
        let rect = window.world_rect;
        if self.is_pinned(window.id) {
            return rect;
        }
        if self.policy.sized.contains(&window.id)
            && let Some(owed) = self.owed_frame(window.id)
        {
            return owed;
        }
        if !self.policy.sizing.contains(&window.id) {
            return rect;
        }
        let size = self.policy.applied.get(&window.id).and_then(|r| r.size);
        match (size, frame(rect)) {
            (Some((width, height)), Ok((loc, own))) => {
                let asked = [i64::from(width).max(1), i64::from(height).max(1)];
                Rect::new(
                    (loc[0] + (own[0] - asked[0]) / 2) as f64,
                    (loc[1] + (own[1] - asked[1]) / 2) as f64,
                    asked[0] as f64,
                    asked[1] as f64,
                )
            }
            _ => rect,
        }
    }
    /// Ask the next window whose rule's `size` is still owed, if the one size
    /// transaction is free: the head of the queue, so in map order. `None`
    /// when nothing began. While a drag, a resize or another transaction is
    /// unresolved the head waits, and `rule.not_applied` goes on naming
    /// `size` for every window still queued. A window that has the size
    /// already needs nothing delivered, and one that cannot be asked (its
    /// resize is unsupported, the frame would leave the integer range)
    /// leaves the queue with `size` still named; the next is then tried. A
    /// refusal leaves nothing half written.
    ///
    /// Upstream's rule size is one-shot at the first commit (`pending_size`,
    /// src/handlers/compositor.rs: "so the user can still resize"), so a
    /// window the user sizes before its turn (IPC `resize`, a step, a fit, a
    /// fill, a resize drag) is taken off the queue where that sizing begins,
    /// with `size` still named: it was never asked.
    ///
    /// The transaction that begins is returned for a reply the shell hands
    /// to its resize coordinator: the `attach` of a new window, and the
    /// `native_resize_result` that ended the transaction before it.
    pub(crate) fn ask_ruled(&mut self, output: Option<OutputId>) -> Option<Value> {
        while let Some(&window) = self.policy.sizing.front() {
            let busy = self.resize_slot().is_some_and(|slot| slot.live);
            if busy || self.gesture.is_some() {
                return None;
            }
            self.policy.sizing.pop_front();
            let size = self.policy.applied.get(&window).and_then(|r| r.size);
            let Some((width, height)) = size else {
                continue;
            };
            let mut next = self.clone();
            let mut outcome = Outcome::default();
            let size = [width.into(), height.into()];
            if next
                .request_window_size(window, output, size, false, &mut outcome)
                .is_err()
            {
                continue;
            }
            next.policy.sized.insert(window);
            *self = next;
            if let Some(began) = outcome.resize.filter(|r| r["effect"].is_object()) {
                return Some(began);
            }
        }
        None
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
    /// Platform adapters can place an independent overlay directly in screen
    /// space without choosing it as the focused window or moving the camera.
    /// The pin and output-removal behavior remain the upstream pinned policy.
    pub(crate) fn screen_pin_arrival(
        &self,
        placement: &SourceScreenPin,
        size: Size,
    ) -> Result<Arrival, Error> {
        let SourceScreenPin { output, screen_pos } = placement;
        if !(screen_pos.x.is_finite() && screen_pos.y.is_finite())
            || screen_pos.x.abs() > f64::from(i32::MAX)
            || screen_pos.y.abs() > f64::from(i32::MAX)
        {
            return Err(Error::Invalid("pin coordinates exceed integer range"));
        }
        let viewport = self
            .scene
            .output(*output)
            .ok_or(Error::Invalid("unknown output"))?;
        let pin = Pin {
            output: *output,
            screen_pos: clamp_pin(
                [screen_pos.x.round() as i64, screen_pos.y.round() as i64],
                pixel_size(size)?,
                pixel_size(viewport.screen_bounds.size)?,
            ),
        };
        Ok(Arrival::Pin {
            rect: Rect {
                origin: pin_canvas(viewport, pin.screen_pos),
                size,
            },
            pin,
        })
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
        // Fullscreen holds the pin for as long as it lasts. The action has
        // ended the active output's; one on another output stays as it is.
        if self.is_fullscreen(window) {
            return Ok(false);
        }
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
        // As IPC `Move`: a window still owed its size from before fullscreen
        // is centered by that size (upstream map_window_to_rule_point).
        let extent = self.fullscreen.restore_size(window).unwrap_or(extent);
        let origin = rule_to_internal(x.round() as i32, y.round() as i32, extent);
        let moved = Rect {
            origin,
            size: rect.size,
        };
        self.place_window(window, moved).map_err(Error::Refused)?;
        self.fullscreen
            .reaimed(window, [origin.x as i64, origin.y as i64]);
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
        // Upstream: the enter put the pin away and the exit puts it back, so
        // neither direction can be set until the window leaves fullscreen.
        if self.is_fullscreen(window) {
            return Err("fullscreen windows can't be pinned".to_string());
        }
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
        // A window that closed, or lost its source, waits for no size.
        self.policy
            .sizing
            .retain(|id| applied.contains_key(id) && sources.contains_key(id));
        self.settle_pinned_drag();
        let order: Vec<WindowId> = self.scene.windows().iter().map(|w| w.id).collect();
        for id in &order {
            // A fullscreen window snaps to nothing and stays in the history.
            let snaps = self.on_canvas(*id);
            if !self.in_history(*id) {
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
        // A fullscreen output shows its fullscreen window alone, and that
        // window is on no other output.
        if let Some(hit) = self.fullscreen_hit(viewport, screen) {
            return hit;
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
                .filter(|w| !self.is_fullscreen(w.id))
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
        self.fullscreen_layers(layered)
    }
    /// A window's policy as the snapshot reports it: `widget`, `pinned` and
    /// `rule`.
    pub(crate) fn policy_json(&self, window: WindowId) -> (bool, Value, Value) {
        let pinned = self.policy.pins.get(&window).map(|pin| {
            let screen_rect = self.pinned_rect(window).map(|(_, rect)| rect);
            json!({"output":pin.output,"screen_rect":screen_rect})
        });
        let sized = self.policy.sized.contains(&window);
        let fullscreened = self.fullscreen.rule_applied(window);
        let rule = self
            .policy
            .applied
            .get(&window)
            .map(|rule| rule_json(rule, sized, fullscreened));
        (self.is_widget(window), json!(pinned), json!(rule))
    }
}
