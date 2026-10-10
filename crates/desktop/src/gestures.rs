// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/gestures.rs (GestureState), src/input/gestures/swipe.rs
// (on_gesture_swipe_begin, _update and _end, build_swipe_threshold,
// has_swipe_direction_bindings, try_start_gesture_move,
// execute_threshold_action), src/input/gestures/pinch.rs
// (on_gesture_pinch_begin, _update and _end), src/input/gestures/hold.rs
// (on_gesture_hold_begin and _end) and src/input/gestures/device_config.rs
// (effective_send_events). The gesture table, the thresholds and
// `direction_from_vector` are driftwm-core's, upstream's own code. Not
// adapted: forwarding an unbound gesture to a client, the fullscreen legs, the
// pointer warps, the pinned and cross-output legs of a move, and the resize
// grab, which is gated here. gesture_target_under is adapted as far as that
// goes: a widget is grab-proof and a screen-pinned window is claimed and left
// where it is (RULES.md). What a continuous gesture drives is motion.rs's:
// a swipe pan is its timed pan (upstream's drift_pan_on) and its end is its
// pan_end (launch_momentum_on), a pinch zoom is its pinch, and a move is the
// pointer's own drag with its edge pan. The pending middle click and the
// set-trackpad action arm live in upstream files this port did not read:
// set-trackpad is taken from device_config.rs and docs/config.md.
//! Upstream's trackpad gesture dispatch, driven by libinput-shaped events.
//!
//! libinput hands upstream ready-made swipe, pinch and hold gestures. macOS has
//! no such stream, so the shell synthesizes one and sends it as `gesture_begin`,
//! `gesture_update` and `gesture_end`. The binding is chosen once, at begin, and
//! holds for the whole gesture, as upstream's `GestureState` does. See
//! GESTURES.md for the contract.
use super::actions::{Outcome, action_string, runs_here};
use super::motion::Pinch;
use super::*;
use driftwm_core::config::{
    Action, BindingContext, ContinuousAction, Direction, GestureBinding, GestureConfigEntry,
    GestureTrigger, SendEvents, ThresholdAction, TrackpadState,
};
use driftwm_core::input::gestures::direction_from_vector;

const RESIZE_NOTE: &str =
    "resize by gesture is not implemented on macOS yet: native layout resize is not available";
const PINNED_NOTE: &str =
    "a screen-pinned window is not moved by gesture: unpin it first (toggle-pin-to-screen)";

/// The gesture libinput would have reported.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GestureKind {
    Swipe,
    Pinch,
    Hold,
}
/// `gesture_begin` as decoded.
pub(crate) struct GestureStart {
    pub(crate) kind: GestureKind,
    pub(crate) fingers: u32,
    pub(crate) modifiers: MacModifiers,
    pub(crate) context: PointerContext,
    pub(crate) output: OutputId,
    pub(crate) pointer: Point,
    pub(crate) doubletap: bool,
    pub(crate) time_ms: f64,
}
/// A pinch that has not moved reports this scale.
pub(crate) fn unit_scale() -> f64 {
    1.0
}

/// Upstream `GestureState`: decided at begin, locked for the gesture.
#[derive(Clone, Debug)]
enum GestureState {
    /// Continuous swipe: the camera follows through the output's timed pan,
    /// and its momentum launches when the swipe ends.
    SwipePan,
    /// The swipe drives the pointer drag it installed, `drag`. `at` is the
    /// virtual pointer, a global screen point, where upstream warps its cursor.
    SwipeMove {
        window: WindowId,
        at: Point,
        drag: u64,
    },
    /// Upstream's resize grab. Native layout resize is gated, so it is inert.
    SwipeResize { window: WindowId },
    /// Upstream's screen-space move of a pinned window, which is not adapted:
    /// the gesture is claimed, pans nothing and moves nothing.
    SwipePinned { window: WindowId },
    /// Accumulate the physical finger vector, pick a direction, fire once.
    SwipeThreshold {
        cumulative: Point,
        fired: bool,
        up: Option<ThresholdAction>,
        down: Option<ThresholdAction>,
        left: Option<ThresholdAction>,
        right: Option<ThresholdAction>,
        /// The `N-finger-swipe` entry: any direction no named trigger claims.
        directional: Option<ThresholdAction>,
    },
    /// Continuous pinch: zoom around the pointer, from the zoom and the
    /// dynamic minimum of its begin.
    PinchZoom { pinch: Pinch },
    PinchThreshold {
        fired_in: bool,
        fired_out: bool,
        action_in: Option<Action>,
        action_out: Option<Action>,
    },
    /// Fires on release.
    HoldAction { action: Action },
    /// Upstream forwards an unbound gesture to the client under the pointer.
    /// A native window's own gestures are not this overlay's to deliver.
    Unbound,
}
impl GestureState {
    fn name(&self) -> &'static str {
        match self {
            Self::SwipePan => "swipe_pan",
            Self::SwipeMove { .. } => "swipe_move",
            Self::SwipeResize { .. } => "swipe_resize",
            Self::SwipePinned { .. } => "swipe_pinned",
            Self::SwipeThreshold { .. } => "swipe_threshold",
            Self::PinchZoom { .. } => "pinch_zoom",
            Self::PinchThreshold { .. } => "pinch_threshold",
            Self::HoldAction { .. } => "hold",
            Self::Unbound => "unbound",
        }
    }
    fn window(&self) -> Option<WindowId> {
        match self {
            Self::SwipeMove { window, .. }
            | Self::SwipeResize { window }
            | Self::SwipePinned { window } => Some(*window),
            _ => None,
        }
    }
}
/// The gesture in progress. Ephemeral: never saved.
#[derive(Clone, Debug)]
pub(crate) struct TrackpadGesture {
    /// Upstream's `gesture_output`, pinned at begin.
    output: OutputId,
    /// The pointer at begin, a global screen point: the zoom anchor.
    pointer: Point,
    state: GestureState,
    /// A camera, a window or the focus changed, so the saved scene differs.
    changed: bool,
}
impl TrackpadGesture {
    fn describe(&self) -> Value {
        json!({"state":self.state.name(),"output":self.output,"window":self.state.window()})
    }
}
/// One binding a gesture resolved to.
struct Found {
    combo: String,
    entry: GestureConfigEntry,
}
impl Found {
    /// The action as a config file spells it, and whether it does anything here.
    fn describe(&self) -> Value {
        let (action, implemented) = match &self.entry {
            GestureConfigEntry::Continuous(action) => match action {
                ContinuousAction::PanViewport => ("pan-viewport".to_owned(), true),
                ContinuousAction::Zoom => ("zoom".to_owned(), true),
                ContinuousAction::MoveWindow => ("move-window".to_owned(), true),
                ContinuousAction::MoveSnappedWindows => ("move-snapped-windows".to_owned(), true),
                ContinuousAction::ResizeWindow => ("resize-window".to_owned(), false),
                ContinuousAction::ResizeWindowSnapped => {
                    ("resize-window-snapped".to_owned(), false)
                }
            },
            // The direction comes from the swipe; any one decides `implemented`.
            GestureConfigEntry::Threshold(ThresholdAction::CenterNearest) => (
                "center-nearest".to_owned(),
                runs_here(&Action::CenterNearest(Direction::Up)),
            ),
            GestureConfigEntry::Threshold(ThresholdAction::Fixed(action)) => {
                (action_string(action), runs_here(action))
            }
        };
        json!({"combo":self.combo,"action":action,"implemented":implemented})
    }
}
/// What one gesture event did beyond moving the session along.
#[derive(Default)]
struct Report {
    outcome: Outcome,
    fired: Value,
    note: Option<&'static str>,
}

/// A trigger as a config file spells it.
fn trigger_name(trigger: &GestureTrigger) -> String {
    let (fingers, kind) = match trigger {
        GestureTrigger::Swipe { fingers } => (fingers, "swipe"),
        GestureTrigger::SwipeUp { fingers } => (fingers, "swipe-up"),
        GestureTrigger::SwipeDown { fingers } => (fingers, "swipe-down"),
        GestureTrigger::SwipeLeft { fingers } => (fingers, "swipe-left"),
        GestureTrigger::SwipeRight { fingers } => (fingers, "swipe-right"),
        GestureTrigger::DoubletapSwipe { fingers } => (fingers, "doubletap-swipe"),
        GestureTrigger::Pinch { fingers } => (fingers, "pinch"),
        GestureTrigger::PinchIn { fingers } => (fingers, "pinch-in"),
        GestureTrigger::PinchOut { fingers } => (fingers, "pinch-out"),
        GestureTrigger::Hold { fingers } => (fingers, "hold"),
        GestureTrigger::Tap { fingers } => (fingers, "tap"),
        GestureTrigger::Doubletap { fingers } => (fingers, "doubletap"),
        GestureTrigger::HoldSwipe { fingers } => (fingers, "hold-swipe"),
        GestureTrigger::DoubletapHoldSwipe { fingers } => (fingers, "doubletap-hold-swipe"),
    };
    format!("{fingers}-finger-{kind}")
}
/// libinput stamps events in `u32` milliseconds, which wrap.
fn event_ms(time_ms: f64) -> Result<u32, Error> {
    if !time_ms.is_finite() || time_ms < 0.0 {
        return Err(Error::Invalid("invalid gesture time"));
    }
    Ok(time_ms as u64 as u32)
}
fn fixed(found: &Found) -> Option<Action> {
    match &found.entry {
        GestureConfigEntry::Threshold(ThresholdAction::Fixed(action)) => Some(action.clone()),
        _ => None,
    }
}

impl Controller {
    /// Upstream effective_send_events as on or off: a `set-trackpad` of this
    /// run if there has been one, otherwise `[input.trackpad] enable`.
    /// `disable_on_external_mouse` counts as on: no device is watched here.
    pub(crate) fn trackpad_enabled(&self) -> bool {
        self.trackpad_override
            .unwrap_or(self.config().trackpad.send_events != SendEvents::Disabled)
    }
    /// Upstream `set-trackpad`: on, off, or the other of the two. True when a
    /// gesture it ended had changed the saved scene.
    pub(crate) fn set_trackpad(&mut self, state: &TrackpadState) -> Result<bool, Error> {
        let enabled = match state {
            TrackpadState::On => true,
            TrackpadState::Off => false,
            TrackpadState::Toggle => !self.trackpad_enabled(),
        };
        self.trackpad_override = Some(enabled);
        self.settle_trackpad()
    }
    /// A trackpad that has just gone off has no gesture in progress: the one
    /// there was ends cancelled, as a disabled device cancels its own. True
    /// when that gesture had changed the saved scene, which nothing else will
    /// now report.
    pub(crate) fn settle_trackpad(&mut self) -> Result<bool, Error> {
        let mut report = Report::default();
        if !self.trackpad_enabled()
            && let Some(session) = self.trackpad_gesture.take()
        {
            self.finish(session, true, None, false, &mut report)?;
        }
        Ok(report.outcome.dirty)
    }
    /// An output is gone: so is a gesture pinned to it.
    pub(crate) fn drop_output_gesture(&mut self, output: OutputId) {
        if self
            .trackpad_gesture
            .as_ref()
            .is_some_and(|session| session.output == output)
        {
            self.trackpad_gesture = None;
        }
    }
    pub(crate) fn trackpad_snapshot(&self) -> Value {
        json!({
            "enabled":self.trackpad_enabled(),
            "gesture":self.trackpad_gesture.as_ref().map(TrackpadGesture::describe),
            "coasting":self.motion.coasting(),
        })
    }
    /// Upstream gesture_lookup for a physical macOS chord, which may stand for
    /// more than one upstream modifier set. As for a pointer binding, every set
    /// is tried in combo order in the pointer's own context table before any is
    /// tried in `anywhere`.
    fn gesture_entry(
        &self,
        modifiers: MacModifiers,
        trigger: GestureTrigger,
        context: BindingContext,
    ) -> Option<Found> {
        let gestures = &self.config().gestures;
        let own = match context {
            BindingContext::OnWindow => &gestures.on_window,
            BindingContext::OnCanvas => &gestures.on_canvas,
            BindingContext::Anywhere => &gestures.anywhere,
        };
        let candidates = self.chord_candidates(modifiers, &trigger_name(&trigger));
        [own, &gestures.anywhere].into_iter().find_map(|table| {
            candidates.iter().find_map(|(combo, set)| {
                let key = GestureBinding {
                    modifiers: set.clone(),
                    trigger: trigger.clone(),
                };
                Some(Found {
                    combo: combo.clone(),
                    entry: table.get(&key)?.clone(),
                })
            })
        })
    }
    /// Upstream gesture_target_under: what a move or resize gesture landed on,
    /// in the order a press resolves (`hit_window`): the windows pinned to the
    /// output, the canvas windows, the widgets. A widget is grab-proof and
    /// ends the search: `None`, as for empty canvas, and nothing beneath it is
    /// reached. The flag says the window is screen-pinned.
    fn gesture_target(&self, output: OutputId, pointer: Point) -> Option<(WindowId, bool)> {
        let (window, _) = self.hit_window(output, pointer)?;
        (!self.is_widget(window)).then(|| (window, self.is_pinned(window)))
    }
    /// Upstream try_start_gesture_move: focus and raise the window under the
    /// pointer and install the drag a bound button press installs. `None` when
    /// nothing draggable is there, a widget included, so the caller can fall
    /// back to pan. A screen-pinned window is refused as `begin_drag` refuses
    /// it: upstream moves it in screen space, which is not adapted, so the
    /// gesture is claimed and left inert, and nothing is raised or focused.
    fn try_start_move(
        &mut self,
        output: OutputId,
        pointer: Point,
        cluster: bool,
        report: &mut Report,
    ) -> Result<Option<GestureState>, Error> {
        if self.gesture.is_some() {
            return Ok(None);
        }
        let Some((window, pinned)) = self.gesture_target(output, pointer) else {
            return Ok(None);
        };
        if pinned {
            report.note = Some(PINNED_NOTE);
            return Ok(Some(GestureState::SwipePinned { window }));
        }
        self.install_drag(window, output, cluster)?;
        let effect = self.raise_and_focus(window)?.effect;
        if !effect.is_null() {
            report.outcome.effects.push(effect);
        }
        Ok(Some(GestureState::SwipeMove {
            window,
            at: pointer,
            drag: self.drags,
        }))
    }
    /// Is the installed pointer drag still the one a move gesture installed?
    /// The pointer path may have ended it and begun a drag of its own.
    fn drives(&self, drag: u64) -> bool {
        matches!(self.gesture, Some(Gesture::Drag { serial, .. }) if serial == drag)
    }
    /// Upstream try_start_gesture_resize, gated: over a window, screen-pinned
    /// or not, the gesture is claimed and does nothing, and elsewhere, over a
    /// widget included, the caller falls back to pan.
    fn refuse_resize(
        &self,
        output: OutputId,
        pointer: Point,
        report: &mut Report,
    ) -> Option<GestureState> {
        let (window, _) = self.gesture_target(output, pointer)?;
        report.note = Some(RESIZE_NOTE);
        Some(GestureState::SwipeResize { window })
    }
    fn begin_swipe(
        &mut self,
        start: &GestureStart,
        context: BindingContext,
        found: &mut Vec<Value>,
        report: &mut Report,
    ) -> Result<GestureState, Error> {
        let (fingers, output, pointer) = (start.fingers, start.output, start.pointer);
        // Upstream's pending middle click: a three-finger tap just before the
        // swipe makes it a doubletap-swipe, which only grabs a window. With no
        // binding, or nothing under the pointer, it is a plain swipe.
        if start.doubletap {
            let trigger = GestureTrigger::DoubletapSwipe { fingers };
            if let Some(hit) = self.gesture_entry(start.modifiers, trigger, context) {
                self.cancel_animations(output);
                let state = match &hit.entry {
                    GestureConfigEntry::Continuous(ContinuousAction::MoveWindow) => {
                        self.try_start_move(output, pointer, false, report)?
                    }
                    GestureConfigEntry::Continuous(ContinuousAction::MoveSnappedWindows) => {
                        self.try_start_move(output, pointer, true, report)?
                    }
                    GestureConfigEntry::Continuous(
                        ContinuousAction::ResizeWindow | ContinuousAction::ResizeWindowSnapped,
                    ) => self.refuse_resize(output, pointer, report),
                    _ => None,
                };
                if let Some(state) = state {
                    found.push(hit.describe());
                    return Ok(state);
                }
            }
        }
        let trigger = GestureTrigger::Swipe { fingers };
        let Some(hit) = self.gesture_entry(start.modifiers, trigger, context) else {
            // Per-direction overrides stand without an `N-finger-swipe` entry.
            let state = self.swipe_threshold(start, context, None, found);
            if found.is_empty() {
                return Ok(GestureState::Unbound);
            }
            self.cancel_animations(output);
            return Ok(state);
        };
        self.cancel_animations(output);
        found.push(hit.describe());
        Ok(match hit.entry {
            GestureConfigEntry::Continuous(action) => match action {
                // A swipe has no scale, so upstream treats a bound zoom as pan.
                ContinuousAction::PanViewport | ContinuousAction::Zoom => None,
                ContinuousAction::MoveWindow => {
                    self.try_start_move(output, pointer, false, report)?
                }
                ContinuousAction::MoveSnappedWindows => {
                    self.try_start_move(output, pointer, true, report)?
                }
                ContinuousAction::ResizeWindow | ContinuousAction::ResizeWindowSnapped => {
                    self.refuse_resize(output, pointer, report)
                }
            }
            .unwrap_or(GestureState::SwipePan),
            GestureConfigEntry::Threshold(action) => {
                self.swipe_threshold(start, context, Some(action), found)
            }
        })
    }
    /// Upstream build_swipe_threshold: the named per-direction triggers of this
    /// finger count, over the `N-finger-swipe` fallback.
    fn swipe_threshold(
        &self,
        start: &GestureStart,
        context: BindingContext,
        directional: Option<ThresholdAction>,
        found: &mut Vec<Value>,
    ) -> GestureState {
        let fingers = start.fingers;
        let mut resolve = |trigger: GestureTrigger| {
            let hit = self.gesture_entry(start.modifiers, trigger, context)?;
            // A continuous action on a named direction is refused at parse time.
            let GestureConfigEntry::Threshold(action) = &hit.entry else {
                return None;
            };
            found.push(hit.describe());
            Some(action.clone())
        };
        GestureState::SwipeThreshold {
            cumulative: Point::default(),
            fired: false,
            up: resolve(GestureTrigger::SwipeUp { fingers }),
            down: resolve(GestureTrigger::SwipeDown { fingers }),
            left: resolve(GestureTrigger::SwipeLeft { fingers }),
            right: resolve(GestureTrigger::SwipeRight { fingers }),
            directional,
        }
    }
    fn begin_pinch(
        &mut self,
        start: &GestureStart,
        context: BindingContext,
        found: &mut Vec<Value>,
    ) -> Result<GestureState, Error> {
        let (fingers, output, modifiers) = (start.fingers, start.output, start.modifiers);
        // The continuous trigger first: a bare pinch is always zoom.
        if let Some(hit) = self.gesture_entry(modifiers, GestureTrigger::Pinch { fingers }, context)
            && matches!(
                hit.entry,
                GestureConfigEntry::Continuous(ContinuousAction::Zoom)
            )
        {
            let pinch = self.pinch_begin(output)?;
            found.push(hit.describe());
            return Ok(GestureState::PinchZoom { pinch });
        }
        let pinch_in = self.gesture_entry(modifiers, GestureTrigger::PinchIn { fingers }, context);
        let pinch_out =
            self.gesture_entry(modifiers, GestureTrigger::PinchOut { fingers }, context);
        let (action_in, action_out) = (
            pinch_in.as_ref().and_then(fixed),
            pinch_out.as_ref().and_then(fixed),
        );
        if action_in.is_none() && action_out.is_none() {
            return Ok(GestureState::Unbound);
        }
        found.extend(
            [pinch_in, pinch_out]
                .iter()
                .flatten()
                .filter(|hit| fixed(hit).is_some())
                .map(Found::describe),
        );
        self.cancel_animations(output);
        Ok(GestureState::PinchThreshold {
            fired_in: false,
            fired_out: false,
            action_in,
            action_out,
        })
    }
    fn begin_hold(
        &self,
        start: &GestureStart,
        context: BindingContext,
        found: &mut Vec<Value>,
    ) -> GestureState {
        let trigger = GestureTrigger::Hold {
            fingers: start.fingers,
        };
        let hit = self.gesture_entry(start.modifiers, trigger, context);
        match hit.as_ref().and_then(fixed) {
            Some(action) => {
                found.extend(hit.as_ref().map(Found::describe));
                GestureState::HoldAction { action }
            }
            None => GestureState::Unbound,
        }
    }
    pub(crate) fn gesture_begin(&mut self, start: GestureStart) -> Result<Value, Error> {
        let time = event_ms(start.time_ms)?;
        if !point_valid(start.pointer) {
            return Err(Error::Invalid("invalid gesture pointer"));
        }
        if self.scene.output(start.output).is_none() {
            return Err(Error::Invalid("unknown output"));
        }
        let mut report = Report::default();
        // libinput ends one gesture before it begins the next. An end the shell
        // lost must not lock every later gesture out.
        if let Some(stale) = self.trackpad_gesture.take() {
            self.finish(stale, true, Some(time), false, &mut report)?;
        }
        if !self.trackpad_enabled() {
            return Ok(self.gesture_reply(Value::Null, report));
        }
        let context = match start.context {
            PointerContext::Window => BindingContext::OnWindow,
            PointerContext::Canvas => BindingContext::OnCanvas,
        };
        let mut found = Vec::new();
        let state = match start.kind {
            GestureKind::Swipe => self.begin_swipe(&start, context, &mut found, &mut report)?,
            GestureKind::Pinch => self.begin_pinch(&start, context, &mut found)?,
            GestureKind::Hold => self.begin_hold(&start, context, &mut found),
        };
        let session = TrackpadGesture {
            output: start.output,
            pointer: start.pointer,
            // A move has already focused and raised its window.
            changed: matches!(state, GestureState::SwipeMove { .. }),
            state,
        };
        let mut description = session.describe();
        description["bindings"] = Value::Array(found);
        self.trackpad_gesture = Some(session);
        Ok(self.gesture_reply(description, report))
    }
    /// `dx` and `dy` are libinput's swipe delta, `scale` its pinch scale since
    /// the gesture began. A pinch's own delta and its rotation are what upstream
    /// forwards to a client and otherwise ignores. `held` is what `action`
    /// takes: a real modifier is physically down, should this event fire.
    pub(crate) fn gesture_update(
        &mut self,
        delta: Point,
        scale: f64,
        rotation: f64,
        time_ms: f64,
        held: bool,
    ) -> Result<Value, Error> {
        let time = event_ms(time_ms)?;
        if !point_valid(delta) || !scale.is_finite() || scale <= 0.0 || !rotation.is_finite() {
            return Err(Error::Invalid("invalid gesture update"));
        }
        let mut report = Report::default();
        let Some(mut session) = self.trackpad_gesture.take() else {
            return Ok(self.gesture_reply(Value::Null, report));
        };
        let output = session.output;
        let bounds = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown gesture output"))?
            .screen_bounds;
        match &mut session.state {
            // Upstream SwipePan: `-delta · navigation.trackpad_speed / zoom`
            // through drift_pan_on, so the canvas follows the fingers and the
            // output's momentum hears the delta at the event's own time. That
            // is the timed pan of a finger scroll.
            GestureState::SwipePan => {
                let pan = Point::new(-delta.x, -delta.y);
                self.drift_pan(output, pan, time, Some(PanSource::Finger))?;
                session.changed |= pan != Point::default();
            }
            // Upstream SwipeMove warps the cursor by the raw delta, held inside
            // the gesture's output, and the grab moves the window after it and
            // arms its edge pan from where the cursor then is.
            GestureState::SwipeMove { at, drag, .. } => {
                if self.drives(*drag) {
                    let local = *at - bounds.origin + delta;
                    *at = bounds.origin
                        + Point::new(
                            local.x.clamp(0.0, (bounds.size.width - 1.0).max(0.0)),
                            local.y.clamp(0.0, (bounds.size.height - 1.0).max(0.0)),
                        );
                    self.pointer_gesture_to(*at - session.pointer, Some(*at))?;
                }
            }
            GestureState::SwipeThreshold {
                cumulative,
                fired,
                up,
                down,
                left,
                right,
                directional,
            } => {
                if !*fired {
                    // The physical finger vector: a named direction fires in the
                    // direction the fingers moved.
                    *cumulative = *cumulative + delta;
                    let reach = self.config().gesture_thresholds.swipe_distance;
                    if cumulative.x.powi(2) + cumulative.y.powi(2) >= reach.powi(2) {
                        *fired = true;
                        let named = if cumulative.y.abs() > cumulative.x.abs() {
                            if cumulative.y < 0.0 { up } else { down }
                        } else if cumulative.x < 0.0 {
                            left
                        } else {
                            right
                        };
                        // center-nearest keeps pan orientation instead: fingers
                        // left look right, so the vector is negated.
                        let action = match named.clone().or(directional.clone()) {
                            Some(ThresholdAction::CenterNearest) => Some(Action::CenterNearest(
                                direction_from_vector((-cumulative.x, -cumulative.y).into()),
                            )),
                            Some(ThresholdAction::Fixed(action)) => Some(action),
                            None => None,
                        };
                        if let Some(action) = action {
                            self.fire(output, &action, session.pointer, held, &mut report);
                        }
                    }
                }
            }
            // Upstream PinchZoom: the scale since the gesture began, by
            // `zoom.trackpad_speed`, around the pointer.
            GestureState::PinchZoom { pinch } => {
                pinch.scale = scale - 1.0;
                session.changed |= self.pinch_update(*pinch, session.pointer)?;
            }
            GestureState::PinchThreshold {
                fired_in,
                fired_out,
                action_in,
                action_out,
            } => {
                let thresholds = &self.config().gesture_thresholds;
                let action = if !*fired_in && scale < thresholds.pinch_in_scale {
                    *fired_in = true;
                    action_in.clone()
                } else if !*fired_out && scale > thresholds.pinch_out_scale {
                    *fired_out = true;
                    action_out.clone()
                } else {
                    None
                };
                if let Some(action) = action {
                    self.fire(output, &action, session.pointer, held, &mut report);
                }
            }
            GestureState::SwipeResize { .. }
            | GestureState::SwipePinned { .. }
            | GestureState::HoldAction { .. }
            | GestureState::Unbound => {}
        }
        let description = session.describe();
        // An action the gesture fired may have turned the trackpad off.
        if self.trackpad_enabled() {
            self.trackpad_gesture = Some(session);
        } else {
            self.finish(session, true, Some(time), false, &mut report)?;
        }
        Ok(self.gesture_reply(description, report))
    }
    /// `held` is as `gesture_update` takes it, for a hold's action.
    pub(crate) fn gesture_end(
        &mut self,
        cancelled: bool,
        time_ms: f64,
        held: bool,
    ) -> Result<Value, Error> {
        let time = event_ms(time_ms)?;
        let mut report = Report::default();
        let Some(session) = self.trackpad_gesture.take() else {
            return Ok(self.gesture_reply(Value::Null, report));
        };
        let mut description = session.describe();
        description["cancelled"] = json!(cancelled);
        self.finish(session, cancelled, Some(time), held, &mut report)?;
        Ok(self.gesture_reply(description, report))
    }
    /// What upstream's `on_gesture_*_end` does with the state it takes. A
    /// cancelled gesture keeps what it already did and fires nothing more.
    fn finish(
        &mut self,
        session: TrackpadGesture,
        cancelled: bool,
        time: Option<u32>,
        held: bool,
        report: &mut Report,
    ) -> Result<(), Error> {
        let output = session.output;
        let mut changed = session.changed;
        let present = self.scene.output(output).is_some();
        match session.state {
            // Upstream launches whether or not the swipe was cancelled:
            // launch_momentum_on, at the end event's own time. A swipe ended
            // by the trackpad going off has no end event and launches nothing.
            GestureState::SwipePan => match time {
                Some(time) if present => {
                    self.pan_end(output, Some(time))?;
                }
                _ => self.stop_momentum(output),
            },
            // Upstream unsets the move grab, which clears its edge pan.
            GestureState::SwipeMove { drag, .. } => {
                if self.drives(drag) {
                    self.drop_gesture();
                }
            }
            // Upstream snaps a zoom that ends near 1.0, around the pointer.
            GestureState::PinchZoom { .. } => {
                if present {
                    changed |= self.pinch_end(output, session.pointer)?;
                }
            }
            GestureState::HoldAction { action } => {
                if !cancelled {
                    self.fire(output, &action, session.pointer, held, report);
                }
            }
            GestureState::SwipeResize { .. }
            | GestureState::SwipePinned { .. }
            | GestureState::SwipeThreshold { .. }
            | GestureState::PinchThreshold { .. }
            | GestureState::Unbound => {}
        }
        report.outcome.dirty |= changed;
        Ok(())
    }
    /// Run a threshold action through the action dispatch, as a key binding's
    /// runs: on the gesture's output, with the pointer where the gesture began
    /// and `held` as the event reported it. A refusal is reported, not raised:
    /// raising it would undo the gesture's own state, and the action would
    /// fire again on the next update.
    fn fire(
        &mut self,
        output: OutputId,
        action: &Action,
        pointer: Point,
        held: bool,
        report: &mut Report,
    ) {
        let mut next = self.clone();
        let error = match next.run(Some(output), action, Some(pointer), held) {
            Ok(outcome) => {
                *self = next;
                if !outcome.navigation.is_null() {
                    report.outcome.navigation = outcome.navigation;
                }
                report.outcome.effects.extend(outcome.effects);
                report.outcome.dirty |= outcome.dirty;
                None
            }
            Err(error) => Some(error.to_string()),
        };
        report.fired = json!({"action":action_string(action),"error":error});
    }
    fn gesture_reply(&self, gesture: Value, report: Report) -> Value {
        json!({
            "gesture":gesture,
            "fired":report.fired,
            "note":report.note,
            "navigation":report.outcome.navigation,
            "effects":report.outcome.effects,
            "dirty":report.outcome.dirty,
            "needs_frames":self.needs_frames(),
            "trackpad":self.trackpad_enabled(),
        })
    }
}
