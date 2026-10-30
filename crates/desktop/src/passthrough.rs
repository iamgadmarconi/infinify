// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/keyboard.rs (the pass_keys decision of a key press: the focused
// window's live rule, after the VT switch that is never passed, and skipped
// while a suspended window holds the focus), src/state/window_lifecycle.rs
// (live_rule_for), src/input/pointer.rs (pass_mouse_claims,
// pass_mouse_target_under, target_claims, pass_mouse_claims_notch and their
// call sites in on_pointer_button, try_pinned_button and on_pointer_axis, the
// pick-mode gate of each included; start_pinned_move),
// src/input/gestures/swipe.rs (gesture_target_under and the pinned arm of
// try_start_gesture_move: the move gesture installs the same grab),
// src/grabs/move_grab.rs (MoveGrab::new_pinned, apply_pinned_move, and what
// its release and unset do) and src/input/mod.rs (on_pointer_motion_relative:
// a cursor on no output is held on the one it was on) with src/canvas.rs
// (clamp_to_output), which is what bounds a pinned drag. The pass lists,
// their merge and `PassList::allows` are driftwm-core's, upstream's own code.
// The fullscreen legs: fullscreen_claims asks the fullscreen window with no
// pick-mode gate at the button, the notch and the scroll site alike, which
// here is `claimant` for the window `hit` reports on a fullscreen output, its
// fullscreen window alone (fullscreen.rs); `pass_keys` follows a fullscreen
// window like any other holder of the keyboard; and MoveGrab::motion freezes
// a drag while the cursor is over a fullscreen output, which culls everything
// else. What ends a fullscreen at each site is fullscreen.rs's: a grab, a
// bound pan or zoom scroll, and the guard of an action a notch runs.
// Not adapted: the screen-space resize
// of a pinned window (src/grabs/resize_grab.rs apply_pinned_resize), which
// needs native resize. `layer_order` is not adapted either, and has nothing
// to adapt: upstream orders layer-shell surfaces by it
// (src/state/layers.rs) and documents it as ignored for regular windows,
// which is every window here (rules.rs lists it in `not_applied`).
//! `pass_keys`, `pass_mouse` and the screen-space drag of a pinned window.
use super::bindings::{EXIT_KEY_CODE, combo_text, key_name, state};
use super::rules::Pin;
use super::*;
use driftwm_core::config::{
    Action, AppliedWindowRule, KeyCombo, Modifiers, MouseTrigger, PassList,
};

/// Control+Option, the modifiers of the shell's exit chord.
const EXIT_CHORD: MacModifiers = MacModifiers {
    control: true,
    option: true,
    shift: false,
    command: false,
};

/// May a focused window's `pass_keys` take this key binding from the canvas?
/// Upstream's one exemption is the VT switch, the way out of a compositor
/// that has handed every key to a game. A Mac has no VT, and no keysym of one
/// reaches the key table. The ways out of the canvas are the shell's exit
/// chord and `quit`, so those two are never passed: the binding on the exit
/// chord, whatever it runs, and every binding that runs `quit`.
pub(crate) fn passable(action: &Action, media: bool, key: u16, chord: MacModifiers) -> bool {
    let exit = !media && key == EXIT_KEY_CODE && chord == EXIT_CHORD;
    !exit && !matches!(action, Action::Quit)
}

/// Upstream MoveGrab::new_pinned: the drag of a screen-pinned window, which
/// the move binding's press installs and the move gesture too. Where upstream
/// keeps the offset from the cursor to the window, the shell reports the
/// pointer's displacement since the press, and a gesture its virtual
/// pointer's, so the frame's place at the press is kept instead: the two give
/// the same frame.
#[derive(Clone, Debug)]
pub(crate) struct PinnedDrag {
    pub(crate) window: WindowId,
    /// Upstream's `output`: the pin's own at the press, then whichever output
    /// the pointer is on.
    pub(crate) output: OutputId,
    /// The frame's top-left at the press, a global screen point.
    origin: Point,
    /// Which install this is, as a canvas drag's: a move gesture drives only
    /// its own.
    pub(crate) serial: u64,
}

impl Controller {
    /// Upstream live_rule_for: the window's rules against the config and the
    /// title of this moment, not the rule it mapped with, so a reload and a
    /// retitle take effect at once. Only a window with a client has one: a
    /// stand-in and a detached slot have nobody to pass anything to.
    fn live_rule(&self, window: WindowId) -> Option<AppliedWindowRule> {
        let metadata = self.metadata.get(&window)?;
        self.sources.get(&window)?;
        self.config()
            .resolve_window_rules(&metadata.bundle_id, &metadata.title)
    }
    /// Upstream's `focused_window` is the window that holds the keyboard. Here
    /// that is the logically focused window once its focus is settled: the
    /// adapter confirmed or observed it natively, or answered `focus_logical`.
    /// A key that is passed is not delivered by this controller, it reaches
    /// whatever holds the keyboard natively, so while a focus request is in
    /// flight, after one failed, and after `focus_lost`, nothing is passed.
    fn keyboard_window(&self) -> Option<WindowId> {
        let window = self.scene.focused()?;
        let native = self.focus.observed_native.as_ref();
        (native.is_some_and(|held| held.window == window) || self.focus.logical == Some(window))
            .then_some(window)
    }
    /// A pass list's combo in the spelling `bindings` gives a key binding's
    /// `combo`, so the two compare as text. A keysym outside the key table has
    /// the name the config file gave it, and one no binding names is written
    /// as its number: no binding can be on it.
    fn key_combo_text(&self, combo: &KeyCombo) -> String {
        let sym = combo.sym.raw();
        let extra = &self.settings.extra_keysyms;
        let name = key_name(sym)
            .map(str::to_owned)
            .or_else(|| {
                let named = extra.iter().find(|(known, _)| *known == sym);
                named.map(|(_, name)| name.clone())
            })
            .unwrap_or_else(|| format!("0x{sym:x}"));
        combo_text(&combo.modifiers, self.config().mod_key, Some(&name))
    }
    /// The snapshot's `pass_keys`: what upstream's key filter would forward to
    /// the window that holds the keyboard instead of running the binding.
    /// `true` is every key binding, a list the bindings on those combos, null
    /// nothing. Upstream skips the test while a suspended window holds the
    /// focus, and so does `live_rule`. Which bindings may be taken at all is
    /// `passable`, in the `bindings` reply.
    pub(crate) fn pass_keys(&self) -> Value {
        let rule = self.keyboard_window().and_then(|id| self.live_rule(id));
        match rule.map(|rule| rule.pass_keys) {
            Some(PassList::All) => json!(true),
            Some(PassList::Only(combos)) => combos
                .iter()
                .map(|combo| self.key_combo_text(combo))
                .collect(),
            Some(PassList::None) | None => Value::Null,
        }
    }
    /// Upstream target_claims, for a binding that has matched: does the
    /// window whose content is under the pointer claim this trigger? `window`
    /// is that window as `hit` reports it, which is upstream's subject too:
    /// the pinned window first, then the topmost one, never the focused one.
    /// Upstream asks only in the on-window context, which here is `context`,
    /// whichever table the binding came from. `modifiers` is the upstream set
    /// the binding matched under, the one a physical chord resolved to.
    ///
    /// Chrome is never `pass_mouse`'s to give, and none can be hit here: `hit`
    /// tests a window's frame, a `server` window's drawn title bar lies
    /// outside it, and no resize band is drawn for a live window.
    pub(crate) fn pass_mouse_claims(
        &self,
        window: Option<WindowId>,
        context: PointerContext,
        modifiers: &Modifiers,
        trigger: MouseTrigger,
    ) -> bool {
        let Some(window) = window.filter(|_| matches!(context, PointerContext::Window)) else {
            return false;
        };
        self.live_rule(window)
            .is_some_and(|rule| rule.pass_mouse.allows(&state(modifiers), trigger))
    }
    /// Upstream's pick-mode gate on a claim, which each call site owns. Below
    /// `zoom.interact_min` a canvas window has no pointer focus to forward
    /// to, so its claims are ignored and the canvas's bindings stay live:
    /// `pick` says the window is such a pick target, as `hit` reports it. A
    /// screen-pinned window is drawn at its own size and stays interactive
    /// there, and try_pinned_button asks its claim with no gate: its button
    /// claims still apply. Its scroll and notch claims do not: on_pointer_axis
    /// and pass_mouse_claims_notch both ask `!pick_mode()`, whatever is under
    /// the pointer. A pin's output is the one the pointer is on, so its pick
    /// mode is read from the pin. `None` is nobody to ask.
    ///
    /// A fullscreen window's claims apply with no gate at all: upstream's
    /// fullscreen_claims asks its `pass_mouse` at the button, the notch and
    /// the scroll site alike, ahead of every pick-mode test. It is never a
    /// pick target, so `pick` is false for it (`pointer_binding` holds that
    /// whatever its caller says), and it has no pin while it is fullscreen:
    /// it gets through both tests below.
    ///
    /// A widget that is not pinned is the one case left open: upstream's
    /// button and scroll sites drop its claim below the threshold too, and
    /// neither argument says which output the pointer is on (docs/crates/desktop/RULES.md).
    pub(crate) fn claimant(
        &self,
        window: Option<WindowId>,
        trigger: PointerTrigger,
        pick: bool,
    ) -> Option<WindowId> {
        let window = window.filter(|_| !pick)?;
        let button = !matches!(
            trigger,
            PointerTrigger::Scroll | PointerTrigger::WheelUp | PointerTrigger::WheelDown
        );
        let pin = self.policy.pins.get(&window);
        let below = pin.is_some_and(|pin| self.pick_mode(pin.output));
        (button || !below).then_some(window)
    }

    /// Upstream start_pinned_move: the drag is installed on the pin's own
    /// output, and not at all while that output is gone. Like every move grab
    /// it takes each output out of flight. `group` means nothing to it: a
    /// pinned window has no cluster.
    ///
    /// Nor while that output is fullscreen: it draws its fullscreen window
    /// alone, and upstream's pinned_window_under finds no pinned window there
    /// ("fullscreen covers pinned windows on that output"). A press on that
    /// output never gets this far: `begin_drag` has ended its fullscreen
    /// first (`fullscreen_grab`), and the pinned windows are back.
    pub(crate) fn install_pinned_drag(
        &mut self,
        window: WindowId,
        output: OutputId,
    ) -> Result<(), Error> {
        if self.scene.output(output).is_none() {
            return Err(Error::Invalid("unknown output"));
        }
        let pin = self
            .policy
            .pins
            .get(&window)
            .ok_or(Error::Invalid("the window is not screen-pinned"))?;
        let viewport = self
            .scene
            .output(pin.output)
            .ok_or(Error::Invalid("the window's output is not connected"))?;
        if self.fullscreen_on(pin.output).is_some() {
            return Err(Error::Invalid("the window's output is fullscreen"));
        }
        let at = Point::new(f64::from(pin.screen_pos[0]), f64::from(pin.screen_pos[1]));
        let origin = viewport.screen_bounds.origin + at;
        let on = pin.output;
        self.cancel_animations_everywhere();
        self.drags += 1;
        self.gesture = Some(Gesture::Pinned(PinnedDrag {
            window,
            output: on,
            origin,
            serial: self.drags,
        }));
        Ok(())
    }
    /// Upstream apply_pinned_move: the frame follows the pointer in screen
    /// space, so by the pointer's displacement in screen points whatever the
    /// zoom, rounded to a whole point. The pin is bound to the output the
    /// pointer is on, else the one it was on, and is written unclamped, as
    /// upstream's is. A frame can be dragged part of the way off its output,
    /// never all of the way: a pointer on no output is held at the edge of
    /// the one it was on, as upstream's cursor is, so the point the frame was
    /// taken by stays on an output. No snap, no cluster, no edge pan. The
    /// canvas frame follows at the end of the command (`settle_policy`).
    ///
    /// Upstream MoveGrab::motion: a fullscreen output draws only its
    /// fullscreen window, so a window dragged there would just vanish. The
    /// drag is frozen while the pointer is over one, the pin staying where
    /// it was, and goes on from wherever the pointer leaves it again. No
    /// output becomes fullscreen under a drag: an enter is refused while one
    /// is in progress (fullscreen.rs).
    pub(crate) fn drag_pinned(
        &mut self,
        screen_delta: Point,
        pointer: Option<Point>,
    ) -> Result<(), Error> {
        let Some(Gesture::Pinned(drag)) = self.gesture.as_ref() else {
            return Err(Error::Invalid("no active gesture"));
        };
        let (window, origin, last) = (drag.window, drag.origin, drag.output);
        let under = pointer.and_then(|at| {
            let on = |o: &&Viewport| o.screen_bounds.contains(at);
            self.scene.outputs().iter().find(on)
        });
        let viewport = under
            .or_else(|| self.scene.output(last))
            .ok_or(Error::Invalid("unknown gesture output"))?;
        if under.is_some_and(|on| self.fullscreen_on(on.id).is_some()) {
            return Ok(());
        }
        // Upstream on_pointer_motion_relative: the cursor never leaves an
        // output. Off every one it is held on the one it was on
        // (clamp_to_output, the far bound one short of the edge). The shell's
        // pointer is not confined, so it is held here the same way: `pointer`
        // is the press point plus `screen_delta`, and what overshoots comes
        // off the delta.
        let bounds = viewport.screen_bounds;
        let overshoot = pointer.filter(|_| under.is_none()).map(|at| {
            let hold = |at: f64, low: f64, high: f64| at.clamp(low, (high - 1.0).max(low));
            let held = Point::new(
                hold(at.x, bounds.origin.x, bounds.right()),
                hold(at.y, bounds.origin.y, bounds.bottom()),
            );
            at - held
        });
        let at = origin + screen_delta - overshoot.unwrap_or_default() - bounds.origin;
        let whole = |value: f64| {
            let value = value.round();
            (f64::from(i32::MIN)..=f64::from(i32::MAX))
                .contains(&value)
                .then_some(value as i32)
        };
        let (Some(x), Some(y)) = (whole(at.x), whole(at.y)) else {
            return Err(Error::Invalid("window geometry exceeds integer range"));
        };
        let output = viewport.id;
        // Guarded as upstream's is: a pin that has gone is not put back.
        if let Some(pin) = self.policy.pins.get_mut(&window) {
            *pin = Pin {
                output,
                screen_pos: [x, y],
            };
        }
        if let Some(Gesture::Pinned(drag)) = self.gesture.as_mut() {
            drag.output = output;
        }
        Ok(())
    }
    /// A pinned drag moves a pin, and is over once its window has none.
    /// Upstream's grab outlives a pin toggled off under it; here a pin waits
    /// for the gesture to end, so the one way to lose it under a drag is to
    /// become a stand-in: by a close, or a slot `adoption_complete` keeps.
    pub(crate) fn settle_pinned_drag(&mut self) {
        if let Some(Gesture::Pinned(drag)) = &self.gesture
            && !self.is_pinned(drag.window)
        {
            self.drop_gesture();
        }
    }
}
