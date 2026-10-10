// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/mod.rs (maybe_hover_focus, hover_focus_window, pick_target_under,
// pointer_focus_under_pick), src/state/navigation.rs (pick_mode, resolve_pick),
// src/input/pointer.rs (try_pick_button, maybe_promote_pick, the pick-mode
// retry of on_pointer_axis in the canvas context, the MouseAction::CenterNearest
// arm), src/grabs/navigate_grab.rs (NavigateGrab: the dead zone and the negated
// drag), src/state/keyboard_focus.rs (set_window_focus, set_suspended_focus:
// focus with no raise) and src/handlers/mod.rs (focus_changed). The octant of a
// drag is driftwm-core's `input::gestures::direction_from_vector`, upstream's
// own code. A detached placeholder is upstream's stand-in. The window under the
// pointer is the layered hit of `rules` (`Controller::hit_window`): the windows
// pinned to the output, then the canvas windows, then the widgets. Hover focus
// takes a pinned window first and passes over a widget, as maybe_hover_focus
// and hover_focus_window do; a pick target is a canvas window or a stand-in
// (`Controller::on_canvas`), never a widget or a screen-pinned window, which
// keep their pointer below the threshold. Layer surfaces, fullscreen and modal
// windows, server-side chrome and client resize margins do not exist here, so
// the whole frame is the target. Only world rectangles, pins, output poses
// and the configuration are read, never native geometry.
use super::actions::Outcome;
use super::window_actions::Moved;
use super::*;
use driftwm_core::config::Action;
use driftwm_core::input::gestures::direction_from_vector;
use driftwm_core::platform::utils::{Logical, Point as CorePoint};

/// Upstream NavigateGrab THRESHOLD_SQ: a press bound to `center-nearest` takes
/// its direction once the pointer is 16 screen points from where it went down.
const NAVIGATE_THRESHOLD_SQ: f64 = 16.0 * 16.0;
/// How many unanswered hover requests are remembered for their echo.
const MAX_OPEN_HOVERS: usize = 16;
/// How long after it was made a hover's request can still be answered by an
/// observation: the shell's driver gives up after 1.5 s and reads native focus
/// every 0.5 s. Past that a report for its window is the user's activation.
const HOVER_ECHO_NS: u64 = 3_000_000_000;

impl Controller {
    /// Upstream pick_mode, per output: its content is too small to touch, so a
    /// click picks a window instead of reaching it. A pure function of the
    /// output's live zoom, a flight's frames included, and of
    /// `zoom.interact_min`, whose 0 is off.
    pub(crate) fn pick_mode(&self, output: OutputId) -> bool {
        let threshold = self.config().zoom_interact_min;
        threshold > 0.0
            && self
                .scene
                .output(output)
                .is_some_and(|viewport| viewport.zoom < threshold)
    }
    /// Upstream's pointer grab, which stops hover focus and pointer delivery
    /// alike: a drag or resize gesture, or a native resize that has not
    /// drained. The drag is whichever is installed, a bound press's, a
    /// pick-mode press's or a move gesture's, with the edge pan it arms. A drag
    /// pan whose button is down is upstream's PanGrab. Two more are held to be
    /// grabs here, which upstream's code does not make one: a trackpad gesture
    /// between its begin and its end, whatever it resolved to, and a scroll pan
    /// whose momentum is yet to launch at `time_ms` (`Motion::holds_pointer`).
    /// While either lasts the pad is busy and the canvas may be sliding under
    /// a pointer that a separate event stream moves. A coast, a flight and
    /// cursor edge pan are no grab: upstream's motion runs maybe_hover_focus
    /// and then refresh_cursor_edge_pan.
    fn pointer_grabbed(&self, time_ms: Option<u32>) -> bool {
        self.gesture.is_some()
            || self.guard_resize_structure(None).is_err()
            || self.trackpad_gesture.is_some()
            || self.motion.holds_pointer(time_ms)
    }
    /// Upstream pick_target_under: in pick mode the window under the pointer
    /// is a pick target when it is a canvas window, a stand-in included. A
    /// screen-pinned window is drawn at its own size whatever the zoom and
    /// stays interactive, and a widget is never picked: neither is a target,
    /// and a pinned window lying over a canvas window keeps the press.
    fn pick_target(&self, output: OutputId, under: Option<WindowId>) -> bool {
        under.is_some_and(|window| self.on_canvas(window)) && self.pick_mode(output)
    }
    /// `hit` and `input` with upstream's pick mode: `pick` says the hit is a
    /// pick target, on the reply and on the hit object alike, and `input`, the
    /// validation of a press about to be forwarded, refuses one. Upstream
    /// pointer_focus_under_pick gives such a window no pointer focus at all.
    /// The hit is the layered one, so a screen-pinned window and a widget
    /// answer `pick: false` below the threshold and `input` still passes them.
    pub(crate) fn pointer_hit(
        &self,
        output: OutputId,
        screen: Point,
        expected: Option<&SourceIdentity>,
    ) -> Result<Value, Error> {
        let mut reply = self.hit(output, screen, expected)?;
        let under = reply["hit"]["window"].as_u64().map(WindowId);
        let pick = self.pick_target(output, under);
        if pick && expected.is_some() {
            return Err(Error::Invalid(
                "pick mode: below zoom.interact_min a window takes no pointer input",
            ));
        }
        if let Some(hit) = reply["hit"].as_object_mut() {
            hit.insert("pick".to_owned(), json!(pick));
        }
        reply["pick"] = json!(pick);
        Ok(reply)
    }
    /// `snapshot`, each output saying whether it is in pick mode.
    pub(crate) fn pointer_snapshot(&self) -> Result<Value, Error> {
        let mut snapshot = self.snapshot()?;
        if let Some(outputs) = snapshot["outputs"].as_array_mut() {
            for (entry, viewport) in outputs.iter_mut().zip(self.scene.outputs()) {
                entry["pick"] = json!(self.pick_mode(viewport.id));
            }
        }
        Ok(snapshot)
    }
    /// `load_config`, saying whether the configuration now in force has sloppy
    /// focus on. Nothing depends on the shell reading it: `hover` decides.
    pub(crate) fn pointer_config(&mut self, path: Option<String>) -> Result<Value, Error> {
        let mut reply = self.load_config(path)?;
        reply["focus_follows_mouse"] = json!(self.config().focus_follows_mouse);
        Ok(reply)
    }
    /// `mouse_binding`. `window` is the window under the pointer, whose
    /// `pass_mouse` may claim what the lookup found (passthrough.rs), and
    /// `pick` says it is a pick target, with which the lookup is what upstream
    /// does over one. A pick target claims nothing: upstream's gate, by which
    /// a screen-pinned window, never a pick target, keeps its button claims
    /// below the threshold (`claimant`).
    ///
    /// Over a pick target a press is the pick's unless a held-modifier binding
    /// claims it (try_pick_button: a bare button bound on a window does not).
    /// A scroll that finds no binding is looked up again in the canvas context,
    /// so that it pans or zooms instead of dying on a window that cannot
    /// receive it (on_pointer_axis). A wheel notch is neither: upstream's notch
    /// site sits ahead of both, with no modifier gate and no retry, so its
    /// lookup is the plain one.
    pub(crate) fn pointer_binding(
        &self,
        trigger: PointerTrigger,
        source: Option<ScrollSource>,
        modifiers: MacModifiers,
        context: PointerContext,
        pick: bool,
        window: Option<WindowId>,
    ) -> Value {
        let claimant = self.claimant(window, trigger, pick);
        let found = self.mouse_binding(trigger, source, modifiers, context, claimant);
        if !pick || !matches!(context, PointerContext::Window) {
            return found;
        }
        match trigger {
            PointerTrigger::Scroll if found["binding"].is_null() => {
                self.mouse_binding(trigger, source, modifiers, PointerContext::Canvas, None)
            }
            PointerTrigger::Scroll | PointerTrigger::WheelUp | PointerTrigger::WheelDown => found,
            _ if modifiers == MacModifiers::default() => json!({"binding":null}),
            _ => found,
        }
    }
    /// Upstream set_window_focus and set_suspended_focus: logical focus moves
    /// and nothing is restacked. `Scene::focus_in_place` is `Scene::focus`
    /// without its raise: the stacking, the frames, the native bindings, the
    /// focus history, the snapping exclusions, the outputs and the bookmarks
    /// are not touched, and the rules and pins live outside the scene.
    fn focus_in_place(&mut self, window: WindowId) -> Result<(), Error> {
        Ok(self.scene.focus_in_place(window)?)
    }
    /// The pointer moved over `output` with no button down. `hit` is what the
    /// `hit` command answers at that point, or null where it refuses (a
    /// stand-in, a source whose presentation is unsettled). `pick` says a pick
    /// target is under the pointer, a stand-in included. `forward` says the
    /// motion is the window's: upstream delivers it to the surface under the
    /// pointer whoever holds the keyboard, and not during a grab or to a pick
    /// target.
    ///
    /// Upstream maybe_hover_focus, with `focus_follows_mouse`: the window
    /// under the pointer takes the focus without being raised, a stand-in
    /// included. That window is the layered hit, so one pinned to the output
    /// has priority over the canvas beneath it, as upstream asks
    /// pinned_window_under first. A widget is passed over
    /// (hover_focus_window), a pinned one too, and so is empty canvas: the
    /// focus stays where it is, and nothing under a pinned widget takes it. A
    /// window that already holds the focus intent is left alone, whatever
    /// became of its native request. A gesture or native resize in progress is
    /// upstream's pointer grab, and so is what `pointer_grabbed` adds to it;
    /// an open focus cycle is held to be one too.
    /// The native request is `focus`'s own, so the window enters the focus
    /// history when it is answered, like every focus here, and only if
    /// `confirm_focus` lets it: a screen-pinned window holds the focus and
    /// stays out. `effect` is in the reply only when the focus moved, and is
    /// null for a stand-in. No camera moves: a hover arms no flight.
    ///
    /// The motion is forwarded whoever takes the focus: a widget's and a
    /// pinned window's application sees it like any live window's.
    ///
    /// `time_ms` is when the motion is reported, on the event clock a timed
    /// `pan` carries. A hover stops nothing: no flight, no coast and no pan
    /// waiting to launch is touched, whether it moves the focus or not.
    pub(crate) fn hover(
        &mut self,
        output: OutputId,
        screen: Point,
        time_ms: Option<u32>,
    ) -> Result<Value, Error> {
        if !point_valid(screen) {
            return Err(Error::Invalid("invalid screen point"));
        }
        if self.scene.output(output).is_none() {
            return Err(Error::Invalid("unknown output"));
        }
        let under = self.hit_window(output, screen).map(|(window, _)| window);
        let pick = self.pick_target(output, under);
        let hit = self
            .pointer_hit(output, screen, None)
            .map_or(Value::Null, |mut reply| reply["hit"].take());
        let grabbed = self.pointer_grabbed(time_ms);
        let forward = !hit.is_null() && !pick && !grabbed;
        let mut reply = json!({"dirty":false,"pick":pick,"hit":hit,"forward":forward});
        let follows = self.config().focus_follows_mouse
            && !grabbed
            && self.scene.stage().cycle_state().is_none();
        if let Some(window) = under.filter(|window| {
            follows && !self.is_widget(*window) && self.scene.focused() != Some(*window)
        }) {
            let last = self.next_effect;
            self.focus_in_place(window)?;
            reply["effect"] = self.request_focus(window)?["effect"].take();
            if let Some(asked) = self.focus.pending_effect.clone() {
                self.open_hovers(last);
                self.focus.hover.push((asked, self.navigation_clock));
                // A shell that answers nothing must not grow this without end.
                let excess = self.focus.hover.len().saturating_sub(MAX_OPEN_HOVERS);
                self.focus.hover.drain(..excess);
            }
            reply["dirty"] = json!(true);
        }
        Ok(reply)
    }
    /// Forget the hover requests whose answer can no longer arrive as an
    /// observation. `last` is the newest focus request made so far: when it is
    /// not a hover's, a click, an action or a cycle step has taken over and
    /// every report is an activation again. A request answered with success, or
    /// with `focus_logical` (nothing was asked of the native window), closes
    /// itself and every hover before it. A failed one stays open, and so does
    /// one withdrawn unanswered: the native window may still take the keyboard
    /// after the adapter gave up. Either way a request is open for
    /// `HOVER_ECHO_NS` at most, after which a report is an activation again
    /// however the hover ended.
    fn open_hovers(&mut self, last: u64) {
        if self
            .focus
            .hover
            .last()
            .is_some_and(|(asked, _)| asked.effect_id != last)
        {
            self.focus.hover.clear();
        }
        let answered = self
            .focus
            .last_result
            .as_ref()
            .filter(|result| result["success"] == true || result["logical"] == true)
            .and_then(|result| result["effect"]["effect_id"].as_u64());
        if let Some(answered) = answered {
            self.focus
                .hover
                .retain(|(asked, _)| asked.effect_id > answered);
        }
        // The controller's only clock is `tick_navigation`'s. A host that never
        // ticks has none, and nothing expires.
        if let Some(now) = self.navigation_clock {
            self.focus.hover.retain(|(_, made)| {
                made.is_none_or(|made| now.saturating_sub(made) < HOVER_ECHO_NS)
            });
        }
    }
    /// A native focus report for a window a hover asked the adapter to focus,
    /// while that request is still open: the hover's own answer, arriving as an
    /// observation. This has no upstream counterpart, where hover focus is the
    /// compositor's own and nothing reports it back. The observation is the
    /// focus, as for every native report, but it is recorded where the window
    /// stands: logical focus follows it without a raise, the window enters the
    /// focus history as a `focus_result` enters it (a screen-pinned window
    /// does not: `confirm_focus`), and nothing is flown to,
    /// because upstream's hover neither restacks nor moves the camera. That
    /// holds for a hover the pointer has since left as well, whose request
    /// outlived it. `None` for any other report, which `activate` then treats
    /// as upstream treats an activation.
    pub(crate) fn hover_echo(&mut self, observed: &FocusEffect) -> Result<Option<Value>, Error> {
        self.open_hovers(self.next_effect);
        let window = observed.window;
        let Some(index) = self.focus.hover.iter().rposition(|(asked, _)| {
            asked.window == window
                && asked.identity == observed.identity
                && asked.generation == observed.generation
        }) else {
            return Ok(None);
        };
        self.focus.hover.drain(..=index);
        self.finish_cycle();
        let refocused = self.scene.focused() != Some(window);
        if refocused {
            self.focus_in_place(window)?;
        }
        self.focus.pending_effect = None;
        self.focus.logical = None;
        self.confirm_focus(window)?;
        self.focus.observed_native = Some(observed.clone());
        let recorded = Moved {
            refocused,
            ..Moved::default()
        };
        Ok(Some(recorded.reply_with_dirty()))
    }
    /// Upstream resolve_pick: a left click on a pick target, let go without a
    /// drag, navigates to it as `center-window` would, at zoom 1, which carries
    /// the output back above the threshold: a pick is one navigation, not a
    /// mode. Zoomed back above the threshold while the button was down, the
    /// deliberate zoom stands and nothing happens; the reply then has no
    /// `effect`, as `activate`'s `click_release` has none. A window still in
    /// `fill` returns to the camera and zoom its fill ran in instead
    /// (`navigate_restoring_fill`), provided that zoom is itself at or above
    /// the threshold: a view that left the output in pick mode would make the
    /// pick a mode, so such a window is centered at zoom 1 like any other. A
    /// stand-in has no fill. A widget and a screen-pinned window are no pick
    /// target: the command does nothing with one, whatever the zoom.
    pub(crate) fn pick(&mut self, window: WindowId, output: OutputId) -> Result<Value, Error> {
        if self.scene.window(window).is_none() {
            return Err(Error::Invalid("unknown window"));
        }
        self.navigation_context(output)?;
        if !self.pick_target(output, Some(window)) {
            return Ok(json!({"navigation":null,"dirty":false}));
        }
        let threshold = self.config().zoom_interact_min;
        let restores = self
            .fill_restore_view(window, output)
            .is_some_and(|(_, zoom)| zoom >= threshold);
        let moved = if restores {
            self.navigate_restoring_fill(window, output)?
        } else {
            self.navigate_to_window(window, output, ZoomPolicy::Reset)?
        };
        Ok(moved.reply_with_dirty())
    }
    /// Upstream's MouseAction::CenterNearest press, a NavigateGrab: the drag
    /// pulls the canvas, so the vector is the press minus the pointer, and
    /// dragging right goes to the nearest window on the left. Inside the 16
    /// point dead zone nothing happens, a plain click included. Past it the
    /// octant of the vector is the direction of one `center-nearest`. Upstream
    /// fires that once, on the first motion past the dead zone, and ignores the
    /// rest of the drag: `screen` is meant to be that motion's point.
    ///
    /// The action runs once, through the one dispatch every action takes
    /// (`run`), so its prelude is that dispatch's: an open cycle ends and the
    /// output's scroll momentum stops. `screen` is the pointer it is given and
    /// `held` is as `action` takes it. Inside the dead zone no action runs,
    /// and no prelude either.
    pub(crate) fn pointer_nearest(
        &mut self,
        output: OutputId,
        screen: Point,
        start: Point,
        held: bool,
    ) -> Result<Value, Error> {
        if !point_valid(screen) || !point_valid(start) {
            return Err(Error::Invalid("invalid screen point"));
        }
        if self.scene.output(output).is_none() {
            return Err(Error::Invalid("unknown output"));
        }
        let pulled = start - screen;
        if pulled.x * pulled.x + pulled.y * pulled.y < NAVIGATE_THRESHOLD_SQ {
            return Ok(Outcome::default().reply());
        }
        let vector: CorePoint<f64, Logical> = CorePoint::from((pulled.x, pulled.y));
        let action = Action::CenterNearest(direction_from_vector(vector));
        Ok(self.run(Some(output), &action, Some(screen), held)?.reply())
    }
}
