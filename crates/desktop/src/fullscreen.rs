// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/fullscreen.rs (resolve_fullscreen_output, enter_fullscreen,
// exit_fullscreen_on, restore_fullscreen_view, reap_dead_fullscreen,
// resize_fullscreen_for_output, recentre_fullscreen_window),
// src/input/actions.rs (execute_action's fullscreen guard, the
// ToggleFullscreen and HomeToggle arms and SendToOutput's fullscreen leg),
// src/state/recenter.rs (establish_exit_placement), src/state/placement.rs
// (fullscreen_background_pos), src/state/navigation.rs (navigate_to_window_on
// and activate_window_output_local's fullscreen rules), src/state/output.rs
// (output removal, window_render_transform's own-output rule),
// src/state/viewport.rs (set_camera_on, set_zoom: the parked camera),
// src/state/window_animation_driver.rs (fullscreen_conceals_canvas),
// src/state/mod.rs (is_canvas_window), src/state/persistence.rs
// (screen_space_inventory), src/state/session_store.rs (live_window_rect),
// src/input/mod.rs (check_hot_corners' fullscreen suppression,
// maybe_hover_focus' fullscreen branch, the own-output hit-test isolation),
// src/input/pointer.rs and src/input/gestures/{swipe,pinch,hold}.rs (what a
// press, a scroll and a gesture do on a fullscreen output), src/ipc/mod.rs
// (cmd_camera, cmd_zoom, cmd_move, cmd_pin, cmd_suspend) and
// src/handlers/{xdg_shell,compositor}.rs (toplevel_destroyed, a new
// toplevel's background placement and its rule's `fullscreen`). Which action
// leaves fullscreen first is driftwm-core's `Action::runs_during_fullscreen`,
// and the search for a background slot its
// `layout::auto_placement::place_auto`, upstream's own code. The per-output
// record is driftwm-core `stage::FullscreenEntry` with upstream's
// `FullscreenReturn`, kept here by window ID because the scene is not that
// stage and the controller is cloned for every command.
//
// Upstream sends a client a configure and lets it answer. Here the output's
// size, and the size a window had before, reach a native window only through
// the size transaction of sizes.rs, which exists only when the shell reported
// `native_resize_capability`: without it nothing in this file is reachable.
// Native frames include their title bar, so chrome is zero. A fullscreen
// window is drawn in its output's screen space from world rectangles, the
// output's `screen_bounds` and the parked camera alone, never native geometry.
// See FULLSCREEN.md.
use super::actions::Outcome;
use super::ipc::{OutputFullscreen, frame, readable};
use super::lifecycle::Arrival;
use super::rules::{Pin, clamp_pin};
use super::sizes::Screen;
use super::view_actions::{ViewReturn, pixel, pixel_size};
use super::*;
use driftwm_canvas::Placement;
use driftwm_core::config::{Action, Direction};
use driftwm_core::layout::auto_placement::{self, place_auto};
use std::collections::{BTreeSet, HashSet};

/// A location or a size in upstream's whole logical pixels.
type Px = [i64; 2];

/// Upstream MIN_RESTORE_FLOOR: a saved size under this on either axis is a
/// throwaway first frame, and the window comes back at half the output.
const MIN_RESTORE_FLOOR: i64 = 100;
/// What sizes.rs says to a sizing action during a drag or resize gesture.
const GRABBED: &str = "a window is under an interactive move or resize";
const HELD: &str = "a fullscreen window is not moved or resized by hand";
/// How many size transactions one exit may begin for the size it owes. One
/// that ended without ever asking the window (cancelled before its setter, a
/// failed read, an adapter that was not available) leaves the size owed, and
/// the next carrier asks again; a failure that repeats ends here.
const RESTORE_TRIES: u8 = 3;

/// Upstream `stage::FullscreenEntry` and the output's `FullscreenReturn`.
#[derive(Clone, Debug)]
struct Entry {
    window: WindowId,
    saved_location: Px,
    saved_size: Px,
    /// The whole-pixel camera the output is parked at: the window's top-left
    /// while it has the output's size. Upstream reads it back as the window's
    /// position less its `centre_offset`.
    park: Px,
    /// The size last asked of the window: the output's as it was then.
    offered: Px,
    /// Upstream `awaiting_size`: the window has not answered the size it was
    /// offered, so it is not centred yet.
    awaiting: bool,
    camera: Point,
    zoom: f64,
    /// Upstream `FullscreenReturn::pinned`: the pin the exit puts back.
    pinned: Option<Pin>,
}
/// The size a window that left fullscreen is to have again, upstream's exit
/// configure, until the size transaction that delivers it has answered.
#[derive(Clone, Debug)]
struct Restore {
    loc: Px,
    size: Px,
    /// The window still sits where the exit put it. Upstream
    /// drop_owed_recenter: a later placement keeps its own top-left.
    placed: bool,
    /// A transaction carries it; until then it is owed.
    delivered: bool,
    /// The transactions begun for it so far.
    tries: u8,
}
/// Fullscreen state. All of it is ephemeral, as upstream's is.
#[derive(Clone, Debug, Default)]
pub(crate) struct Fullscreen {
    /// The fullscreen window of each output. An output the shell has removed
    /// keeps its entry until the shell says which outputs exist.
    entries: BTreeMap<OutputId, Entry>,
    restores: BTreeMap<WindowId, Restore>,
    /// Upstream `HomeReturn::fullscreen_window`: the window a `home-toggle`
    /// took out of fullscreen, which its return puts back.
    home: BTreeMap<OutputId, WindowId>,
    /// The windows whose rule's `fullscreen` was applied as they mapped.
    ruled: BTreeSet<WindowId>,
}
impl Fullscreen {
    fn output_of(&self, window: WindowId) -> Option<OutputId> {
        self.entries
            .iter()
            .find(|(_, entry)| entry.window == window)
            .map(|(output, _)| *output)
    }
    /// The size a window that left fullscreen is still to be handed back.
    pub(crate) fn restore_size(&self, window: WindowId) -> Option<[i64; 2]> {
        self.restores.get(&window).map(|restore| restore.size)
    }
    /// The window has answered the output's size it was offered.
    pub(crate) fn answered(&mut self, window: WindowId) {
        for entry in self.entries.values_mut() {
            if entry.window == window {
                entry.awaiting = false;
            }
        }
    }
    /// The window has its size back, or something else has sized it since.
    pub(crate) fn restored(&mut self, window: WindowId) {
        self.restores.remove(&window);
    }
    /// Something else has placed the window: its size still comes back, at
    /// the top-left it has by then.
    pub(crate) fn moved(&mut self, window: WindowId) {
        if let Some(restore) = self.restores.get_mut(&window) {
            restore.placed = false;
        }
    }
    /// Upstream map_window_to_rule_point: a placement that is itself a center
    /// re-aims what the exit owes instead of dropping it. The window was put
    /// at `loc` for the size it is owed, and comes back around that frame.
    pub(crate) fn reaimed(&mut self, window: WindowId, loc: [i64; 2]) {
        if let Some(restore) = self.restores.get_mut(&window) {
            (restore.loc, restore.placed) = (loc, true);
        }
    }
    pub(crate) fn rule_applied(&self, window: WindowId) -> bool {
        self.ruled.contains(&window)
    }
    /// The pin each fullscreen window had before, which a save keeps.
    pub(crate) fn stashed_pins(&self) -> impl Iterator<Item = (WindowId, Pin)> + '_ {
        self.entries
            .values()
            .filter_map(|entry| Some((entry.window, entry.pinned?)))
    }
}

fn point_of(px: Px) -> Point {
    Point::new(px[0] as f64, px[1] as f64)
}
/// Upstream recentre_fullscreen_window's offset: half the shortfall on each
/// axis, and none for a window larger than its output.
fn centre(viewport: Px, size: Px) -> Px {
    [
        ((viewport[0] - size[0]) / 2).max(0),
        ((viewport[1] - size[1]) / 2).max(0),
    ]
}
/// Does the shell pass this command's reply through the hook that performs a
/// size transaction (`-consumeSize:`, the first step of `-applyReply:`)? A
/// size still owed after a fullscreen exit leaves with the first such reply
/// that has room for it. `hover` is not one: the shell reads a hover reply's
/// `forward`, `dirty` and focus request and nothing else, so a transaction
/// begun there would never be performed.
pub(crate) fn carries(command: &Command) -> bool {
    matches!(
        command,
        Command::Action { .. }
            | Command::HotCorner { .. }
            | Command::Ipc { .. }
            | Command::Activate { .. }
            | Command::ClearFocus {}
            | Command::Pick { .. }
            | Command::PointerNearest { .. }
            | Command::GestureBegin { .. }
            | Command::GestureUpdate { .. }
            | Command::GestureEnd { .. }
    )
}

impl Controller {
    /// Upstream is_window_fullscreen.
    pub(crate) fn is_fullscreen(&self, window: WindowId) -> bool {
        self.fullscreen.output_of(window).is_some()
    }
    pub(crate) fn fullscreen_output_of(&self, window: WindowId) -> Option<OutputId> {
        self.fullscreen.output_of(window)
    }
    /// Upstream fullscreen_window_on, and with it is_output_fullscreen.
    pub(crate) fn fullscreen_on(&self, output: OutputId) -> Option<WindowId> {
        self.fullscreen.entries.get(&output).map(|e| e.window)
    }
    /// The snapshot's `mode`: `fullscreen` over the fit or fill that survives
    /// beneath it.
    pub(crate) fn mode_name(&self, window: WindowId) -> Option<&'static str> {
        if self.is_fullscreen(window) {
            return Some("fullscreen");
        }
        self.sizes.mode_name(window)
    }
    fn output_px(&self, output: OutputId) -> Option<Px> {
        let size = pixel_size(self.scene.output(output)?.screen_bounds.size).ok()?;
        Some([size.w.into(), size.h.into()])
    }
    /// Upstream resolve_fullscreen_output: the rule's `output` when it is
    /// connected, then the output of the window's pin, then the active one. A
    /// native window asks for no output of its own.
    fn resolve_fullscreen_output(
        &self,
        window: WindowId,
        active: Option<OutputId>,
    ) -> Option<OutputId> {
        let connected = |output: &OutputId| self.scene.output(*output).is_some();
        self.policy
            .applied
            .get(&window)
            .and_then(|rule| rule.output.as_deref())
            .and_then(|name| self.output_named(name))
            .or_else(|| self.pin_output(window).filter(connected))
            .or(active)
            .filter(connected)
    }
    /// Upstream's ToggleFullscreen arm. The focused live window leaves the
    /// fullscreen it is in, wherever that is; else the active output's
    /// fullscreen ends; else the focused window enters. A widget never does,
    /// and a stand-in is no client: with one focused only the middle leg runs.
    pub(crate) fn toggle_fullscreen(
        &mut self,
        active: Option<OutputId>,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        let focused = self
            .scene
            .focused()
            .filter(|id| self.sources.contains_key(id) && !self.is_widget(*id));
        let held = focused
            .and_then(|window| self.fullscreen_output_of(window))
            .or_else(|| active.filter(|output| self.fullscreen_on(*output).is_some()));
        if let Some(output) = held {
            self.exit_fullscreen_on(output);
            outcome.dirty = true;
        } else if let Some(window) = focused {
            let target = self.resolve_fullscreen_output(window, active);
            self.enter_fullscreen(window, target, outcome)?;
        }
        Ok(())
    }
    /// Upstream enter_fullscreen. The window's place and size, the output's
    /// camera and zoom and the window's pin are saved; the output is marked at
    /// once, parked at its whole-pixel camera and zoom 1 with every animation
    /// stopped; the window is put at that camera, raised and focused; and the
    /// output's size is asked of it. False when nothing was entered: a
    /// widget, a stand-in, no output, or the window already fullscreen there.
    fn enter_fullscreen(
        &mut self,
        window: WindowId,
        target: Option<OutputId>,
        outcome: &mut Outcome,
    ) -> Result<bool, Error> {
        if self.is_widget(window) || !self.sources.contains_key(&window) {
            return Ok(false);
        }
        let Some(output) = target.filter(|output| self.scene.output(*output).is_some()) else {
            return Ok(false);
        };
        if self.fullscreen_on(output) == Some(window) {
            return Ok(false);
        }
        // The camera is parked and the window placed from here on, which a
        // drag or resize in progress would fight.
        if self.gesture.is_some() {
            return Err(Error::Refused(GRABBED.to_owned()));
        }
        // Fullscreen on another output: that one is torn down first, so the
        // size saved below is the windowed one. Then whoever holds this one.
        if let Some(other) = self.fullscreen_output_of(window) {
            self.exit_fullscreen_on(other);
        }
        self.exit_fullscreen_on(output);
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .clone();
        let view = self
            .output_px(output)
            .ok_or(Error::Invalid("view geometry exceeds integer range"))?;
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let (mut saved_location, committed) = frame(rect).map_err(Error::Refused)?;
        // A size an exit still owes the window is the one it comes back to.
        let mut saved_size = match self.fullscreen.restores.remove(&window) {
            Some(restore) => restore.size,
            None => self.windowed_size(window, committed),
        };
        if saved_size[0] < MIN_RESTORE_FLOOR || saved_size[1] < MIN_RESTORE_FLOOR {
            let half = [view[0] / 2, view[1] / 2];
            let middle = viewport.camera + point_of(view) / 2.0 / viewport.zoom;
            saved_location = [middle.x as i64 - half[0] / 2, middle.y as i64 - half[1] / 2];
            saved_size = half;
        }
        let park = [
            i64::from(pixel(viewport.camera.x.round())?),
            i64::from(pixel(viewport.camera.y.round())?),
        ];
        let parked = Rect {
            origin: point_of(park),
            size: rect.size,
        };
        readable(parked).map_err(Error::Refused)?;
        // Unpinned into the fullscreen viewport; the exit pins it again.
        let pinned = self.policy.pins.remove(&window);
        self.fullscreen.entries.insert(
            output,
            Entry {
                window,
                saved_location,
                saved_size,
                park,
                offered: view,
                awaiting: true,
                camera: viewport.camera,
                zoom: viewport.zoom,
                pinned,
            },
        );
        self.park(output)?;
        self.scene.set_window_rect(window, parked)?;
        let moved = self.raise_and_focus(window)?;
        if !moved.effect.is_null() {
            outcome.effects.push(moved.effect);
        }
        outcome.dirty = true;
        if !self.fullscreen_resize(window, Some(output), view, Screen::Fill, outcome)? {
            let slot = self
                .resize_slot()
                .ok_or(Error::Invalid("resize transaction missing"))?;
            return Err(Error::Refused(Self::busy(slot)));
        }
        Ok(true)
    }
    /// Upstream's viewport lock: a fullscreen output sits at the camera its
    /// window is parked at, at zoom 1, with no flight, momentum, edge pan or
    /// zoom-to-fit return. Upstream's set_camera_on and set_zoom refuse to
    /// move it and its tick clears the targets; here it is put back.
    fn park(&mut self, output: OutputId) -> Result<(), Error> {
        let Some(entry) = self.fullscreen.entries.get(&output) else {
            return Ok(());
        };
        let camera = point_of(entry.park);
        self.cancel_animations(output);
        self.motion.clear_edge_pan(output);
        self.overview_returns.remove(&output);
        let Some(viewport) = self.scene.output(output) else {
            return Ok(());
        };
        if viewport.camera != camera || viewport.zoom != 1.0 {
            let mut parked = viewport.clone();
            (parked.camera, parked.zoom) = (camera, 1.0);
            self.scene.update_output(parked)?;
            self.sync_output(output)?;
        }
        Ok(())
    }
    /// Upstream exit_fullscreen_on: the window is back at the place it was
    /// saved at and pinned again if it was, and the output has its camera and
    /// zoom back, at once. The size it had before is owed to it. Nothing here
    /// can be refused: an exit is a consequence of something that happened.
    pub(crate) fn exit_fullscreen_on(&mut self, output: OutputId) -> Option<WindowId> {
        let entry = self.fullscreen.entries.remove(&output)?;
        let window = entry.window;
        if let Some(rect) = self.scene.window(window).map(|w| w.world_rect) {
            let at = Rect {
                origin: point_of(entry.saved_location),
                size: rect.size,
            };
            let _ = self.scene.set_window_rect(window, at);
            if self.sources.contains_key(&window) {
                let restore = Restore {
                    loc: entry.saved_location,
                    size: entry.saved_size,
                    placed: true,
                    delivered: false,
                    tries: 0,
                };
                self.fullscreen.restores.insert(window, restore);
            }
            // It may have entered the focus history while it was fullscreen.
            if let Some(pin) = entry.pinned {
                self.scene.drop_focus_history(window);
                self.policy.pins.insert(window, pin);
            }
        }
        self.restore_fullscreen_view(output, entry.camera, entry.zoom);
        Some(window)
    }
    /// Upstream restore_fullscreen_view: the camera and zoom from before, and
    /// nothing aimed at the parked view survives. An output the shell has
    /// removed takes them where its camera is kept. The pointer needs no
    /// warp: it is the system's, in screen space.
    fn restore_fullscreen_view(&mut self, output: OutputId, camera: Point, zoom: f64) {
        self.cancel_animations(output);
        match self.scene.output(output).cloned() {
            Some(mut viewport) => {
                (viewport.camera, viewport.zoom) = (camera, zoom);
                if self.scene.update_output(viewport).is_ok() {
                    let _ = self.sync_output(output);
                }
            }
            None => {
                if let Some(saved) = self.outputs.get_mut(&output) {
                    (saved.viewport.camera, saved.viewport.zoom) = (camera, zoom);
                }
            }
        }
    }
    /// Upstream toplevel_destroyed and reap_dead_fullscreen: a fullscreen
    /// window that is gone, or has become a stand-in or a detached slot,
    /// gives its output its view back, and what is left of it takes the
    /// place it had before, pin included. A window that `closed` is seated
    /// at the size from before too, as upstream seats the stand-in, also
    /// when it goes while that size is still owed. One that only lost its
    /// source lives on at the size it has, where upstream's clients end with
    /// the compositor: its slot keeps that size, the only one a native
    /// observation committed, so the window that is adopted into it again
    /// can be sized.
    pub(crate) fn fullscreen_window_gone(&mut self, window: WindowId, closed: bool) {
        let held = self.scene.window(window).map(|w| w.world_rect.size);
        let frame_of = |loc: Px, size: Px| Rect {
            origin: point_of(loc),
            size: match held {
                Some(held) if !closed => held,
                _ => Size::new(size[0] as f64, size[1] as f64),
            },
        };
        if let Some(output) = self.fullscreen_output_of(window)
            && let Some(entry) = self.fullscreen.entries.remove(&output)
        {
            if self.scene.window(window).is_some() {
                let rect = frame_of(entry.saved_location, entry.saved_size);
                let _ = self.scene.set_window_rect(window, rect);
                if let Some(pin) = entry.pinned {
                    self.policy.pins.insert(window, pin);
                }
            }
            self.restore_fullscreen_view(output, entry.camera, entry.zoom);
        }
        if let Some(restore) = self.fullscreen.restores.remove(&window)
            && let Some(rect) = self.scene.window(window).map(|w| w.world_rect)
        {
            let loc = match restore.placed {
                true => restore.loc,
                false => frame(rect).map_or(restore.loc, |(loc, _)| loc),
            };
            let _ = self
                .scene
                .set_window_rect(window, frame_of(loc, restore.size));
        }
    }
    /// The shell has said which outputs exist. Upstream ends a fullscreen
    /// with its output; the shell removes every output on any screen change
    /// and registers the present ones again, so only now is it known which
    /// are gone. True when a fullscreen ended or a pin it put away moved.
    pub(crate) fn fullscreen_outputs_settled(&mut self) -> bool {
        let gone: Vec<OutputId> = self
            .fullscreen
            .entries
            .keys()
            .copied()
            .filter(|output| self.scene.output(*output).is_none())
            .collect();
        for output in &gone {
            self.exit_fullscreen_on(*output);
        }
        // Upstream reassign_orphaned_pinned: a pin put away by a fullscreen
        // that stays is none of the pins `rehome_pins` walks. It moves with
        // them to the first connected output, clamped for the size the window
        // comes back to, or the exit would pin the window to an output that
        // is gone.
        let first = self.scene.outputs().first();
        let to = first.and_then(|o| Some((o.id, pixel_size(o.screen_bounds.size).ok()?)));
        let connected: BTreeSet<OutputId> = self.scene.outputs().iter().map(|o| o.id).collect();
        let mut rebound = false;
        for entry in self.fullscreen.entries.values_mut() {
            let size = Size::new(entry.saved_size[0] as f64, entry.saved_size[1] as f64);
            if let (Some(pin), Some((to, on)), Ok(size)) =
                (entry.pinned.as_mut(), to, pixel_size(size))
                && !connected.contains(&pin.output)
            {
                let at = pin.screen_pos.map(i64::from);
                (pin.output, pin.screen_pos) = (to, clamp_pin(at, size, on));
                rebound = true;
            }
        }
        !gone.is_empty() || rebound
    }
    /// What every command must leave true. A fullscreen window that is gone
    /// or has lost its source is reaped. Each fullscreen output is parked.
    /// A window that has answered the size it was offered, or whose
    /// transaction ended without an answer, sits in the middle of its output
    /// when it is smaller and at the parked corner when it is not: upstream
    /// recentre_fullscreen_window, which moves the mapped position so that
    /// what is drawn and what is hit are one rectangle.
    pub(crate) fn settle_fullscreen(&mut self) -> Result<(), Error> {
        let live = |controller: &Self, window: WindowId| {
            controller.scene.window(window).is_some() && controller.sources.contains_key(&window)
        };
        let dead: Vec<WindowId> = self
            .fullscreen
            .entries
            .values()
            .map(|entry| entry.window)
            .chain(self.fullscreen.restores.keys().copied())
            .filter(|window| !live(self, *window))
            .collect();
        for window in dead {
            self.fullscreen_window_gone(window, false);
        }
        // A size whose window was asked for it is gone by now: `settle` drops
        // it at the first observation behind an attempted setter. One still
        // here after its transaction ended was never asked (cancelled before
        // the setter, a failed read, an adapter that was not available), so
        // it is owed again and leaves with the next carrier, `RESTORE_TRIES`
        // times at most. A window that was asked to close keeps the record
        // as it is: its transaction ends unanswered when the window goes
        // first, and what stays of it is seated from the frame it had before
        // (upstream's suspend mark carries that rect:
        // focused_fullscreen_restore_rect).
        let ended: Vec<WindowId> = self
            .fullscreen
            .restores
            .iter()
            .filter(|(window, restore)| {
                restore.delivered
                    && self.fullscreen_pending(**window) != Some(true)
                    && !self.lifecycle.marks.contains_key(*window)
            })
            .map(|(window, _)| *window)
            .collect();
        for window in ended {
            match self.fullscreen.restores.get_mut(&window) {
                Some(restore) if restore.tries < RESTORE_TRIES => restore.delivered = false,
                _ => self.fullscreen.restored(window),
            }
        }
        let outputs: Vec<OutputId> = self.fullscreen.entries.keys().copied().collect();
        for output in outputs {
            self.park(output)?;
            let Some(view) = self.output_px(output) else {
                continue;
            };
            let Some(entry) = self.fullscreen.entries.get(&output).cloned() else {
                continue;
            };
            let awaiting = entry.awaiting && self.fullscreen_pending(entry.window) == Some(false);
            if let Some(entry) = self.fullscreen.entries.get_mut(&output) {
                entry.awaiting = awaiting;
            }
            let Some(rect) = self.scene.window(entry.window).map(|w| w.world_rect) else {
                continue;
            };
            let Ok((loc, size)) = frame(rect) else {
                continue;
            };
            let offset = centre(view, size);
            let at = [entry.park[0] + offset[0], entry.park[1] + offset[1]];
            if !awaiting && loc != at {
                let centred = Rect {
                    origin: point_of(at),
                    size: rect.size,
                };
                if readable(centred).is_ok() {
                    self.scene.set_window_rect(entry.window, centred)?;
                }
            }
        }
        let windows = &self.scene;
        self.fullscreen
            .home
            .retain(|_, window| windows.window(*window).is_some());
        self.fullscreen
            .ruled
            .retain(|window| windows.window(*window).is_some());
        Ok(())
    }
    /// Begin what is owed and can be begun now: the size of a window that
    /// left fullscreen, then the new size of an output that changed under its
    /// fullscreen window (upstream resize_fullscreen_for_output). One
    /// transaction at most, the slot being one. Returns its `transaction` and
    /// `effect`, and whether saved geometry was written.
    fn flush_owed(&mut self) -> (Option<Value>, bool) {
        let mut outcome = Outcome::default();
        // A gesture places its windows itself; what is owed waits for its end.
        if self.gesture.is_some() {
            return (None, false);
        }
        let owed: Vec<(WindowId, Restore)> = self
            .fullscreen
            .restores
            .iter()
            .filter(|(_, restore)| !restore.delivered)
            .map(|(window, restore)| (*window, restore.clone()))
            .collect();
        for (window, restore) in owed {
            // A refusal must leave nothing half written.
            let mut next = self.clone();
            let screen = Screen::Restore(restore.placed.then_some(restore.loc));
            match next.fullscreen_resize(window, None, restore.size, screen, &mut outcome) {
                Ok(true) => {
                    if let Some(restore) = next.fullscreen.restores.get_mut(&window) {
                        restore.delivered = true;
                        restore.tries += 1;
                    }
                    *self = next;
                }
                // The slot is another transaction's: still owed.
                Ok(false) => {}
                // A window that cannot be sized is owed nothing more.
                Err(_) => self.fullscreen.restored(window),
            }
        }
        let resized: Vec<(OutputId, WindowId, Px)> = self
            .fullscreen
            .entries
            .iter()
            .filter_map(|(output, entry)| {
                let view = self.output_px(*output)?;
                (view != entry.offered).then_some((*output, entry.window, view))
            })
            .collect();
        for (output, window, view) in resized {
            let mut next = self.clone();
            let asked =
                next.fullscreen_resize(window, Some(output), view, Screen::Fill, &mut outcome);
            if let (Ok(true), Some(entry)) = (asked, next.fullscreen.entries.get_mut(&output)) {
                (entry.offered, entry.awaiting) = (view, true);
                *self = next;
            }
        }
        let began = outcome.resize.filter(|began| began["effect"].is_object());
        (began, outcome.dirty)
    }
    /// Hand a reply the size transaction `flush_owed` began, where the shell
    /// looks for one. A reply that lists `effects` carries it as a sizing
    /// action's does, under `transaction` and `effect`. One whose `effect` is
    /// its focus request (`activate`, `pick`), or that has neither key
    /// (`clear_focus`), gains `transaction` and an `effects` list of that
    /// request, if any, and the transaction's effect, which is where the
    /// shell then reads both. A reply that already carries a transaction is
    /// left alone: the slot is taken.
    pub(crate) fn carry_owed(&mut self, reply: &mut Value) {
        if !reply.is_object() || !reply["transaction"].is_null() {
            return;
        }
        let (began, dirty) = self.flush_owed();
        if dirty && reply["dirty"].is_boolean() {
            reply["dirty"] = json!(true);
        }
        let Some(mut began) = began else {
            return;
        };
        reply["transaction"] = began["transaction"].take();
        if reply["effects"].is_array() {
            reply["effect"] = began["effect"].take();
        } else {
            let focus = Some(reply["effect"].clone()).filter(Value::is_object);
            let effects: Vec<Value> = focus.into_iter().chain([began["effect"].take()]).collect();
            reply["effects"] = Value::Array(effects);
        }
    }
    /// Upstream execute_action's guard: an action that does not run during
    /// fullscreen ends the active output's first. Which do is upstream's own
    /// list (`runs_during_fullscreen`): toggle-fullscreen, spawn but not
    /// exec, reload-config, switch-layout, toggle-cursor-pan, set-trackpad
    /// and send-to-output stay. Returns upstream's `was_fullscreen`.
    pub(crate) fn fullscreen_prelude(
        &mut self,
        output: Option<OutputId>,
        action: &Action,
    ) -> Option<WindowId> {
        if action.runs_during_fullscreen() {
            return None;
        }
        self.exit_fullscreen_on(output?)
    }
    /// Upstream's pointer and gesture paths: a press bound to a grab, a bound
    /// pan or zoom scroll and a continuous gesture end the fullscreen of the
    /// output they act on and run on the restored canvas. A window that is
    /// fullscreen on another output is not theirs to take.
    pub(crate) fn fullscreen_grab(
        &mut self,
        output: OutputId,
        window: Option<WindowId>,
    ) -> Result<(), Error> {
        self.exit_fullscreen_on(output);
        match window.filter(|window| self.is_fullscreen(*window)) {
            Some(_) => Err(Error::Invalid(HELD)),
            None => Ok(()),
        }
    }
    /// Upstream's HomeToggle arm around a fullscreen window. Pressed out of
    /// fullscreen and away from home, the guard has already ended it: the
    /// restored view becomes the return, the window is remembered, and the
    /// output snaps home at zoom 1 without a flight. Pressed at home with
    /// that window still open, the view is put back in one step and the
    /// window is fullscreen again. Every other press is `home_toggle`.
    pub(crate) fn home_toggle_fullscreen(
        &mut self,
        output: OutputId,
        was_fullscreen: Option<WindowId>,
        outcome: &mut Outcome,
    ) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let at_home = self.at_home(&viewport)?;
        let remembered = self.fullscreen.home.remove(&output);
        if at_home {
            let back = remembered.filter(|window| {
                self.home_returns.contains_key(&output) && self.sources.contains_key(window)
            });
            let (Some(window), Some(ret)) = (back, self.home_returns.get(&output).copied()) else {
                return self.home_toggle(output);
            };
            self.home_returns.remove(&output);
            self.cancel_animations(output);
            let mut restored = viewport;
            (restored.camera, restored.zoom) = (ret.camera, ret.zoom);
            self.scene.update_output(restored)?;
            self.sync_output(output)?;
            self.enter_fullscreen(window, Some(output), outcome)?;
            return Ok(json!({"navigation":null}));
        }
        let Some(window) = was_fullscreen else {
            return self.home_toggle(output);
        };
        self.home_returns.insert(
            output,
            ViewReturn {
                camera: viewport.camera,
                zoom: viewport.zoom,
            },
        );
        self.fullscreen.home.insert(output, window);
        self.overview_returns.remove(&output);
        self.cancel_animations(output);
        let center = usable.center();
        let mut home = viewport;
        (home.camera, home.zoom) = (Point::new(-center.x, -center.y), 1.0);
        self.scene.update_output(home)?;
        self.sync_output(output)?;
        Ok(json!({"navigation":null}))
    }
    /// Upstream SendToOutput's fullscreen leg: the focused fullscreen window
    /// becomes fullscreen on the output adjacent to its own, which tears the
    /// old one down and gives that output its view back. `None` when the
    /// focused window is not fullscreen: the canvas and pinned legs follow.
    pub(crate) fn send_fullscreen_to_output(
        &mut self,
        direction: &Direction,
        outcome: &mut Outcome,
    ) -> Result<Option<bool>, Error> {
        let focused = self.scene.focused().filter(|id| !self.is_widget(*id));
        let Some((window, from)) =
            focused.and_then(|window| Some((window, self.fullscreen_output_of(window)?)))
        else {
            return Ok(None);
        };
        let Some(target) = self.output_in_direction(from, direction) else {
            return Ok(Some(false));
        };
        self.enter_fullscreen(window, Some(target), outcome)
            .map(Some)
    }
    /// Upstream's rule `fullscreen = true` on a new toplevel: once it is
    /// mapped it enters fullscreen on the rule's `output`, else its pin's,
    /// else the active one, displacing whoever is fullscreen there. The
    /// arrival's own navigation is left out, as upstream leaves it out for a
    /// deferred fullscreen; entering raises and focuses. The window opens
    /// all the same (effects.rs), on the output it fills.
    ///
    /// A rule that names a `size` too follows upstream's order: the size is
    /// configured at the first commit, the window is placed for it on the
    /// next, and the deferred fullscreen then saves that frame. `own` is the
    /// size the window has, for a window `arrival_by_rule` placed for the
    /// size its rule names, a rule-pinned one included: the frame it was
    /// placed for is where it comes back to, at the rule's size, which is
    /// owed like any exit's and never asked before the output's. Only a
    /// native observation commits a size, so the window enters at its own.
    /// It is counted as sized, and waits in no queue for a rule's `size`.
    ///
    /// `None` leaves the arrival to `settle_arrival` and `size_by_rule`: no
    /// rule, no shell that can deliver a size, a window that took over a
    /// slot, the launch pass, or an enter that cannot begin now, in which
    /// case `rule.not_applied` keeps `fullscreen`.
    pub(crate) fn fullscreen_by_rule(
        &mut self,
        window: WindowId,
        active: Option<OutputId>,
        arrival: Arrival,
        own: Option<Size>,
    ) -> Option<Value> {
        let rule = self.policy.applied.get(&window)?;
        if rule.fullscreen != Some(true)
            || rule.widget
            || !self.sizes.capability
            || !self.lifecycle.settled
            || matches!(arrival, Arrival::Adopt(_))
        {
            return None;
        }
        let size = rule.size.zip(own);
        let mut next = self.clone();
        if let Some(((width, height), own)) = size {
            let rect = next.scene.window(window)?.world_rect;
            let (loc, _) = frame(rect).ok()?;
            let size = [i64::from(width).max(1), i64::from(height).max(1)];
            let at = Rect {
                origin: rect.origin,
                size: own,
            };
            next.scene.set_window_rect(window, at).ok()?;
            let restore = Restore {
                loc,
                size,
                placed: true,
                delivered: false,
                tries: 0,
            };
            next.fullscreen.restores.insert(window, restore);
        }
        let mut outcome = Outcome::default();
        let target = next.resolve_fullscreen_output(window, active);
        if !matches!(
            next.enter_fullscreen(window, target, &mut outcome),
            Ok(true)
        ) {
            return None;
        }
        next.fullscreen.ruled.insert(window);
        if size.is_some() {
            next.policy.sized.insert(window);
        }
        next.log_arrival(window, active, arrival).ok()?;
        *self = next;
        let focus = outcome.effects.pop().unwrap_or(Value::Null);
        let mut reply =
            json!({"window":window,"adopted":false,"effect":focus,"navigation":null,"dirty":true});
        if let Some(mut began) = outcome.resize.filter(|r| r["effect"].is_object()) {
            reply["transaction"] = began["transaction"].take();
            reply["effects"] = json!([began["effect"].take()]);
        }
        Some(reply)
    }
    /// Upstream fullscreen_background_pos: a new window never lands on a
    /// fullscreen one. It is tucked beside the place that window comes back
    /// to: the fullscreen window that holds the focus, else the active
    /// output's. A slot beside that saved frame among the canvas windows,
    /// biased toward its center; with none, just below it by `snap.gap`.
    pub(crate) fn fullscreen_background(
        &self,
        active: Option<OutputId>,
        size: Size,
    ) -> Option<Rect> {
        let focused = self
            .scene
            .focused()
            .and_then(|window| self.fullscreen_output_of(window));
        let entry = self.fullscreen.entries.get(&focused.or(active)?)?;
        let anchor = auto_placement::Rect {
            x: entry.saved_location[0] as f64,
            y: entry.saved_location[1] as f64,
            w: entry.saved_size[0] as f64,
            h: entry.saved_size[1] as f64,
        };
        let mut rects = vec![anchor];
        rects.extend(
            self.scene
                .windows()
                .iter()
                .filter(|w| w.id != entry.window && self.on_canvas(w.id))
                // The frame each is becoming, as every placement reads a
                // window still owed its rule's `size` (`placed_rect`).
                .map(|w| self.placed_rect(w))
                .map(|rect| auto_placement::Rect {
                    x: rect.origin.x.round(),
                    y: rect.origin.y.round(),
                    w: rect.size.width.round(),
                    h: rect.size.height.round(),
                }),
        );
        let eligible: HashSet<usize> = (0..rects.len()).collect();
        let (w, h) = (size.width.round(), size.height.round());
        let middle = (anchor.x + anchor.w / 2.0, anchor.y + anchor.h / 2.0);
        let gap = self.config().snap_gap;
        let (x, y) = place_auto(&rects, 0, &eligible, w, h, middle, gap)
            .map(|(x, y)| (x.round(), y.round()))
            .unwrap_or((anchor.x, anchor.y + anchor.h + gap.round()));
        let rect = Rect::new(x, y, size.width, size.height);
        readable(rect).ok().map(|()| rect)
    }
    /// Upstream draws on a fullscreen output its fullscreen window and
    /// nothing else: no other window, no widget and no pinned one, with or
    /// without a translucent rule. That window is drawn on no other output,
    /// its own being disconnected or not. Its rectangle is its output's
    /// screen rectangle moved by how far it sits from the parked camera, at
    /// its own size: the output's zoom and camera play no part.
    pub(crate) fn fullscreen_layers(
        &self,
        layered: Vec<(Placement, bool)>,
    ) -> Vec<(Placement, bool)> {
        if self.fullscreen.entries.is_empty() {
            return layered;
        }
        let mut kept = Vec::with_capacity(layered.len());
        for viewport in self.scene.outputs() {
            if self.fullscreen.entries.contains_key(&viewport.id) {
                kept.extend(self.fullscreen_placement(viewport).map(|p| (p, false)));
                continue;
            }
            kept.extend(
                layered
                    .iter()
                    .filter(|(p, _)| p.output == viewport.id && !self.is_fullscreen(p.window))
                    .cloned(),
            );
        }
        kept
    }
    /// The fullscreen window's rectangle on its output, in global screen
    /// points, or `None` for an output that is not fullscreen.
    fn fullscreen_rect(&self, viewport: &Viewport) -> Option<(WindowId, Rect)> {
        let entry = self.fullscreen.entries.get(&viewport.id)?;
        let rect = self.scene.window(entry.window)?.world_rect;
        let offset = rect.origin - point_of(entry.park);
        Some((
            entry.window,
            Rect {
                origin: viewport.screen_bounds.origin + offset,
                size: rect.size,
            },
        ))
    }
    fn fullscreen_placement(&self, viewport: &Viewport) -> Option<Placement> {
        let (window, screen_rect) = self.fullscreen_rect(viewport)?;
        let clip_rect = screen_rect.intersection(viewport.screen_bounds)?;
        Some(Placement {
            window,
            output: viewport.id,
            screen_rect,
            clip_rect,
            source_rect: Rect {
                origin: clip_rect.origin - screen_rect.origin,
                size: clip_rect.size,
            },
        })
    }
    /// What the pointer can reach on a fullscreen output: its fullscreen
    /// window where that is drawn, and nothing in the band a smaller window
    /// leaves. `None` for an output that is not fullscreen.
    pub(crate) fn fullscreen_hit(
        &self,
        viewport: &Viewport,
        screen: Point,
    ) -> Option<Option<(WindowId, Point)>> {
        self.fullscreen.entries.get(&viewport.id)?;
        Some(
            self.fullscreen_rect(viewport)
                .filter(|(_, rect)| rect.contains(screen))
                .map(|(window, rect)| (window, screen - rect.origin)),
        )
    }
    /// Upstream fullscreen_conceals_canvas: an opaque fullscreen window hides
    /// the canvas, so the output clears to black behind it; one whose rule or
    /// IPC `Opacity` is below 1 shows the background and the outlines of the
    /// other outputs through it. Under-fill alone conceals all the same.
    fn fullscreen_backdrop(&self, window: WindowId) -> &'static str {
        let opacity = self.drawn_rule(window).and_then(|rule| rule.opacity);
        match opacity.unwrap_or(1.0) >= 1.0 {
            true => "black",
            false => "canvas",
        }
    }
    /// The snapshot's per-output `fullscreen`: null, or the window and what
    /// is behind it.
    pub(crate) fn fullscreen_snapshot(&self, snapshot: &mut Value) {
        let Some(outputs) = snapshot["outputs"].as_array_mut() else {
            return;
        };
        for (entry, viewport) in outputs.iter_mut().zip(self.scene.outputs()) {
            entry["fullscreen"] = match self.fullscreen_on(viewport.id) {
                Some(window) => {
                    json!({"window":window,"backdrop":self.fullscreen_backdrop(window)})
                }
                None => Value::Null,
            };
        }
    }
    /// Upstream screen_space_inventory's fullscreen half: one entry per
    /// fullscreen output, sorted by output name and app id. A window without
    /// an app id is left out, as upstream leaves it out.
    pub(crate) fn fullscreen_inventory(&self) -> Vec<OutputFullscreen> {
        let mut fullscreen: Vec<OutputFullscreen> = self
            .fullscreen
            .entries
            .iter()
            .filter(|(output, _)| self.scene.output(**output).is_some())
            .filter_map(|(output, entry)| {
                let metadata = self.metadata.get(&entry.window)?;
                let name = self.outputs.get(output)?.stable_id.clone();
                (!metadata.bundle_id.is_empty()).then(|| OutputFullscreen {
                    id: entry.window.0,
                    output: name,
                    app_id: metadata.bundle_id.clone(),
                    title: metadata.title.clone(),
                })
            })
            .collect();
        fullscreen.sort_by(|a, b| (&a.output, &a.app_id).cmp(&(&b.output, &b.app_id)));
        fullscreen
    }
    /// Upstream live_window_rect keeps a fullscreen window at the frame it
    /// had before, for a client that ends with the compositor and maps again
    /// at the saved size. A native window lives on at the size it has, so a
    /// save keeps the place from before and that size: the only one a native
    /// observation committed, and the one a later size transaction is
    /// measured from. A window still owed its size already sits where its
    /// exit put it, at the size it has.
    pub(crate) fn fullscreen_saved_frames(&self) -> Vec<(WindowId, Rect)> {
        self.fullscreen
            .entries
            .values()
            .filter_map(|entry| {
                let size = self.scene.window(entry.window)?.world_rect.size;
                let origin = point_of(entry.saved_location);
                Some((entry.window, Rect { origin, size }))
            })
            .collect()
    }
    /// Upstream cycle_step passes over a fullscreen window: it is on screen
    /// on its own output only, and there it is not a place to fly to. The
    /// stage here steps one at a time and raises what it selects, so the
    /// step is repeated on a copy until it lands, and the windows passed over
    /// are put back where they were stacked. `None` when the history holds
    /// nothing else: no step is taken.
    pub(crate) fn cycle_past_fullscreen(
        &mut self,
        backward: bool,
    ) -> Result<Option<WindowId>, Error> {
        if self.fullscreen.entries.is_empty() {
            return Ok(self.scene.cycle_focus(backward)?);
        }
        let order: Vec<WindowId> = self.scene.windows().iter().map(|w| w.id).collect();
        let mut scene = self.scene.clone();
        let mut selected = scene.cycle_focus(backward)?;
        let mut steps = 1;
        while selected.is_some_and(|window| self.is_fullscreen(window))
            && steps < scene.stage().focus_history().len()
        {
            selected = scene.cycle_focus(backward)?;
            steps += 1;
        }
        let Some(window) = selected.filter(|window| !self.is_fullscreen(*window)) else {
            return Ok(None);
        };
        if steps > 1 {
            for id in order {
                scene.raise(id)?;
            }
            scene.focus(window)?;
        }
        self.scene = scene;
        Ok(Some(window))
    }
}
