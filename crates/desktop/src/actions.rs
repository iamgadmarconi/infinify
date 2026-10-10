// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/actions.rs (execute_action's prelude, which ends an Alt-Tab cycle
// and stops scroll momentum, and its dispatch, exec_command, NudgeWindow,
// detect_terminal, detect_launcher). The grammar itself is not adapted: it is
// driftwm-core's `config::{Action, parse_action}`, upstream's own code. The
// camera, bookmark, window navigation, nudge, exec, reload, quit, close,
// suspend, output transfer, layout, toggle-cursor-pan and set-trackpad actions
// execute here, move-to-bookmark and toggle-pin-to-screen in rules.rs and
// zoom-to-fit-snapped in sizes.rs; grow-window, shrink-window, fit-window,
// fit-window-snapped and fill-window execute when the shell can deliver a size
// (sizes.rs); every other action parses and is then refused by name.
use super::keyboard_layout::switch_effect;
use super::window_actions::Moved;
use super::*;
use driftwm_core::config::{Action, Direction, LayoutSwitch, TrackpadState, parse_action};

/// Upstream's compositor-side toolkit fallbacks in `Config::child_env`
/// (src/config/mod.rs `TOOLKIT_DEFAULTS`). They select Wayland backends, which
/// would stop a Qt, SDL or GTK program from starting on macOS, so an `exec`
/// effect carries them only when the user's own `[env]` sets them.
const WAYLAND_TOOLKIT_ENV: [&str; 5] = [
    "MOZ_ENABLE_WAYLAND",
    "QT_QPA_PLATFORM",
    "SDL_VIDEODRIVER",
    "GDK_BACKEND",
    "ELECTRON_OZONE_PLATFORM_HINT",
];
/// What `exec-terminal` runs when `$TERMINAL` is unset: macOS always ships
/// Terminal, and opening a folder in it makes a new window, as upstream's
/// terminals do. Upstream's own fallback list is Linux binaries.
const DEFAULT_TERMINAL: &str = "open -a Terminal \"$HOME\"";
/// What `exec-launcher` runs when `$LAUNCHER` is unset: the system application
/// launcher of macOS 26 and later.
const DEFAULT_LAUNCHER: &str = "open -a Apps";

impl From<&Direction> for ViewDirection {
    fn from(value: &Direction) -> Self {
        match value {
            Direction::Up => Self::Up,
            Direction::Down => Self::Down,
            Direction::Left => Self::Left,
            Direction::Right => Self::Right,
            Direction::UpLeft => Self::UpLeft,
            Direction::UpRight => Self::UpRight,
            Direction::DownLeft => Self::DownLeft,
            Direction::DownRight => Self::DownRight,
        }
    }
}
/// The name `parse_action` matched, as upstream's catalog spells it.
fn action_name(action: &Action) -> &'static str {
    match action {
        Action::Exec(_) => "exec",
        Action::ExecTerminal => "exec-terminal",
        Action::ExecLauncher => "exec-launcher",
        Action::Spawn(_) => "spawn",
        Action::CloseWindow => "close-window",
        Action::SuspendWindow => "suspend-window",
        Action::NudgeWindow(_) => "nudge-window",
        Action::GrowWindow(_) => "grow-window",
        Action::ShrinkWindow(_) => "shrink-window",
        Action::PanViewport(_) => "pan-viewport",
        Action::CenterWindow => "center-window",
        Action::CenterNearest(_) => "center-nearest",
        Action::CycleWindows { .. } => "cycle-windows",
        Action::HomeToggle => "home-toggle",
        Action::GoToBookmark(_) => "go-to-bookmark",
        Action::SetBookmark(_) => "set-bookmark",
        Action::MoveToBookmark(_) => "move-to-bookmark",
        Action::ZoomIn => "zoom-in",
        Action::ZoomOut => "zoom-out",
        Action::ZoomReset => "zoom-reset",
        Action::ZoomToFit => "zoom-to-fit",
        Action::ZoomToFitSnapped => "zoom-to-fit-snapped",
        Action::ToggleFullscreen => "toggle-fullscreen",
        Action::FitWindow => "fit-window",
        Action::FitWindowSnapped => "fit-window-snapped",
        Action::FillWindow => "fill-window",
        Action::SendToOutput(_) => "send-to-output",
        Action::SendCursorToOutput(_) => "send-cursor-to-output",
        Action::FocusCenter => "focus-center",
        Action::TogglePinToScreen => "toggle-pin-to-screen",
        Action::SwitchLayout(_) => "switch-layout",
        Action::ReloadConfig => "reload-config",
        Action::ToggleCursorPan => "toggle-cursor-pan",
        Action::SetTrackpad(_) => "set-trackpad",
        Action::Quit => "quit",
    }
}
fn direction_name(direction: &Direction) -> &'static str {
    match direction {
        Direction::Up => "up",
        Direction::Down => "down",
        Direction::Left => "left",
        Direction::Right => "right",
        Direction::UpLeft => "up-left",
        Direction::UpRight => "up-right",
        Direction::DownLeft => "down-left",
        Direction::DownRight => "down-right",
    }
}
/// The canonical config string of an action: `parse_action` reads it back as
/// the same action.
pub(crate) fn action_string(action: &Action) -> String {
    let name = action_name(action);
    let argument = match action {
        Action::Exec(text)
        | Action::Spawn(text)
        | Action::GoToBookmark(text)
        | Action::SetBookmark(text)
        | Action::MoveToBookmark(text) => text.clone(),
        Action::NudgeWindow(direction)
        | Action::GrowWindow(direction)
        | Action::ShrinkWindow(direction)
        | Action::PanViewport(direction)
        | Action::CenterNearest(direction)
        | Action::SendToOutput(direction)
        | Action::SendCursorToOutput(direction) => direction_name(direction).to_owned(),
        Action::CycleWindows { backward: false } => "forward".to_owned(),
        Action::CycleWindows { backward: true } => "backward".to_owned(),
        Action::SwitchLayout(LayoutSwitch::Next) => "next".to_owned(),
        Action::SwitchLayout(LayoutSwitch::Prev) => "prev".to_owned(),
        Action::SwitchLayout(LayoutSwitch::Index(index)) => index.to_string(),
        Action::SetTrackpad(TrackpadState::On) => "on".to_owned(),
        Action::SetTrackpad(TrackpadState::Off) => "off".to_owned(),
        Action::SetTrackpad(TrackpadState::Toggle) => "toggle".to_owned(),
        _ => return name.to_owned(),
    };
    format!("{name} {argument}")
}
/// Does `run_action` execute this action whatever the shell can do, or refuse
/// it by name? `Controller::runs` adds the actions that deliver a size.
fn runs_here(action: &Action) -> bool {
    matches!(
        action,
        Action::Quit
            | Action::ReloadConfig
            | Action::Exec(_)
            | Action::Spawn(_)
            | Action::ExecTerminal
            | Action::ExecLauncher
            | Action::CloseWindow
            | Action::SuspendWindow
            | Action::NudgeWindow(_)
            | Action::PanViewport(_)
            | Action::CenterWindow
            | Action::CenterNearest(_)
            | Action::CycleWindows { .. }
            | Action::FocusCenter
            | Action::HomeToggle
            | Action::ZoomIn
            | Action::ZoomOut
            | Action::ZoomReset
            | Action::ZoomToFit
            | Action::ZoomToFitSnapped
            | Action::GoToBookmark(_)
            | Action::SetBookmark(_)
            | Action::MoveToBookmark(_)
            | Action::SendToOutput(_)
            | Action::SendCursorToOutput(_)
            | Action::TogglePinToScreen
            | Action::SwitchLayout(_)
            | Action::ToggleCursorPan
            | Action::SetTrackpad(_)
    )
}
/// Upstream detect_terminal / detect_launcher, less their probe of installed
/// Linux programs: the user's environment variable, else the macOS default.
fn from_environment(variable: &str, fallback: &str) -> String {
    std::env::var(variable)
        .ok()
        .filter(|command| !command.is_empty())
        .unwrap_or_else(|| fallback.to_owned())
}

/// What one action or IPC request asks of the shell beyond its own reply.
#[derive(Debug, Default)]
pub(crate) struct Outcome {
    /// The armed flight, or null when nothing flies.
    pub(crate) navigation: Value,
    /// Requests to the native adapter, never evidence that they happened.
    pub(crate) effects: Vec<Value>,
    /// Saved state changed, so the shell should save.
    pub(crate) dirty: bool,
    /// The size transaction a sizing action began: its `transaction` and
    /// `effect`, which the reply carries under those same keys.
    pub(crate) resize: Option<Value>,
}
impl Outcome {
    /// A window navigation: its flight, its focus request as an effect, and
    /// the focus and stacking it wrote as saved state.
    fn moved(mut self, moved: Moved) -> Self {
        self.navigation = moved.navigation;
        if !moved.effect.is_null() {
            self.effects.push(moved.effect);
        }
        self.dirty |= moved.refocused;
        self
    }
    /// The reply of `action` and `hot_corner`.
    pub(crate) fn reply(self) -> Value {
        let reply = json!({"navigation":self.navigation,"effects":self.effects,"dirty":self.dirty});
        super::sizes::carry(reply, self.resize)
    }
}
impl Controller {
    /// Does `run_action` execute this action in this run, or refuse it by name?
    pub(crate) fn runs(&self, action: &Action) -> bool {
        runs_here(action) || (self.sizes.capability && super::sizes::delivers_a_size(action))
    }
    pub(crate) fn action(
        &mut self,
        output: Option<OutputId>,
        spec: &str,
        pointer: Option<Point>,
        held: bool,
    ) -> Result<Value, Error> {
        Ok(self.run_action(output, spec, pointer, held)?.reply())
    }
    /// Upstream spawn_command as a request to the shell: `sh -c command` with
    /// the config's child environment, less the Wayland toolkit fallbacks.
    pub(crate) fn exec_effect(&self, command: &str) -> Value {
        let config = self.config();
        let env: BTreeMap<&String, &String> = config
            .child_env
            .iter()
            .filter(|(key, _)| {
                config.env.contains_key(*key) || !WAYLAND_TOOLKIT_ENV.contains(&key.as_str())
            })
            .collect();
        json!({"op":"exec","command":command,"env":env})
    }
    /// Upstream NudgeWindow: the focused window moves by `navigation.nudge_step`
    /// world points, each axis rounded. A logical world move, applied at once:
    /// upstream animates the frame from its old place. Its fill restore point
    /// ends in `place_window`, as upstream clears it. No focused window is no
    /// error upstream.
    fn nudge_window(&mut self, direction: &Direction) -> Result<bool, Error> {
        // Upstream nudges a canvas window only: not a widget, not a pinned one.
        let Some(window) = self.scene.focused().filter(|id| self.on_canvas(*id)) else {
            return Ok(false);
        };
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let step = f64::from(self.config().nudge_step);
        let (ux, uy) = direction.to_unit_vec();
        let moved = Rect {
            origin: rect.origin + Point::new((ux * step).round(), (uy * step).round()),
            size: rect.size,
        };
        self.place_window(window, moved).map_err(Error::Refused)?;
        Ok(true)
    }
    /// Parse and execute one action string. An unknown string, a known action
    /// that does not run here yet, and a missing active output are three
    /// different refusals, checked in that order. `pointer` is the pointer's
    /// global screen point, for `focus-center`. `held` is upstream's "a real
    /// modifier is physically down" as a `cycle-windows` fires.
    pub(crate) fn run_action(
        &mut self,
        output: Option<OutputId>,
        spec: &str,
        pointer: Option<Point>,
        held: bool,
    ) -> Result<Outcome, Error> {
        let action = parse_action(spec).map_err(Error::Refused)?;
        self.run(output, &action, pointer, held)
    }
    /// Execute one parsed action: a key binding's, an IPC request's, a hot
    /// corner's or a trackpad gesture's. `pointer` and `held` are as
    /// `run_action` takes them.
    pub(crate) fn run(
        &mut self,
        output: Option<OutputId>,
        action: &Action,
        pointer: Option<Point>,
        held: bool,
    ) -> Result<Outcome, Error> {
        // Upstream's execute_action prelude. A non-cycle action ends an
        // Alt-Tab cycle in progress before it runs, and every action stops the
        // active output's scroll momentum first. A refused action is rolled
        // back with both.
        if !matches!(action, Action::CycleWindows { .. })
            && self.scene.stage().cycle_state().is_some()
        {
            self.finish_cycle();
        }
        if let Some(output) = output {
            self.stop_momentum(output);
        }
        let mut outcome = Outcome::default();
        let active = || output.ok_or(Error::Invalid("no active output"));
        let mut reply = match action {
            // The shell owns the process: quitting, running a command and
            // re-reading the config file are its effects to perform.
            Action::Quit => {
                outcome.effects.push(json!({"op":"quit"}));
                return Ok(outcome);
            }
            Action::ReloadConfig => {
                outcome.effects.push(json!({"op":"reload_config"}));
                return Ok(outcome);
            }
            // Upstream's exec also reveals the cursor; there is none to hide here.
            Action::Exec(command) | Action::Spawn(command) => {
                outcome.effects.push(self.exec_effect(command));
                return Ok(outcome);
            }
            Action::ExecTerminal => {
                let command = from_environment("TERMINAL", DEFAULT_TERMINAL);
                outcome.effects.push(self.exec_effect(&command));
                return Ok(outcome);
            }
            Action::ExecLauncher => {
                let command = from_environment("LAUNCHER", DEFAULT_LAUNCHER);
                outcome.effects.push(self.exec_effect(&command));
                return Ok(outcome);
            }
            // Upstream acts on the focused element and does nothing without
            // one, or on a widget.
            Action::CloseWindow => {
                if let Some(window) = self.scene.focused().filter(|id| !self.is_widget(*id)) {
                    self.close_window(window, output, &mut outcome)?;
                }
                return Ok(outcome);
            }
            Action::SuspendWindow => {
                if let Some(window) = self.scene.focused().filter(|id| !self.is_widget(*id)) {
                    self.suspend_window(window, output, &mut outcome)?;
                }
                return Ok(outcome);
            }
            Action::NudgeWindow(direction) => {
                outcome.dirty = self.nudge_window(direction)?;
                return Ok(outcome);
            }
            Action::MoveToBookmark(name) => {
                outcome.dirty = self.move_to_bookmark(name)?;
                return Ok(outcome);
            }
            Action::TogglePinToScreen => {
                outcome.dirty = self.toggle_pin(output)?;
                return Ok(outcome);
            }
            Action::CenterWindow => return Ok(outcome.moved(self.center_window(active()?)?)),
            Action::FocusCenter => {
                return Ok(outcome.moved(self.focus_center(active()?, pointer)?));
            }
            Action::CenterNearest(direction) => {
                return Ok(outcome.moved(self.center_nearest(active()?, direction)?));
            }
            Action::CycleWindows { backward } => {
                let moved = self.cycle_navigate(active()?, *backward, held)?;
                return Ok(outcome.moved(moved.unwrap_or_default()));
            }
            Action::SendToOutput(direction) => {
                outcome.dirty = self.send_to_output(output, direction)?;
                return Ok(outcome);
            }
            Action::SendCursorToOutput(direction) => {
                let warp = self.send_cursor_to_output(active()?, direction)?;
                outcome.effects.extend(warp);
                return Ok(outcome);
            }
            // The enabled input sources are the shell's to list and select.
            Action::SwitchLayout(target) => {
                outcome.effects.push(switch_effect(target));
                return Ok(outcome);
            }
            // Upstream reports nothing: the flag is the snapshot's `cursor_pan`.
            Action::ToggleCursorPan => {
                self.toggle_cursor_pan();
                return Ok(outcome);
            }
            // Upstream turns every trackpad's events off or on. Here that is
            // the gesture dispatch: see GESTURES.md.
            Action::SetTrackpad(state) => {
                outcome.dirty = self.set_trackpad(state)?;
                return Ok(outcome);
            }
            Action::PanViewport(direction) => self.pan_viewport(active()?, direction.into())?,
            Action::HomeToggle => self.home_toggle(active()?)?,
            Action::ZoomIn => self.zoom_in(active()?)?,
            Action::ZoomOut => self.zoom_out(active()?)?,
            Action::ZoomReset => self.zoom_reset(active()?)?,
            Action::ZoomToFit => self.zoom_to_fit(active()?)?,
            Action::ZoomToFitSnapped => self.zoom_to_fit_snapped(active()?)?,
            // These deliver a size to a native window, which only a shell
            // started with --experimental-native-resize can do: SIZES.md.
            action if self.sizes.capability && super::sizes::delivers_a_size(action) => {
                self.run_sizing(output, action, &mut outcome)?;
                return Ok(outcome);
            }
            Action::GoToBookmark(name) => self.go_to_bookmark(active()?, name)?,
            Action::SetBookmark(name) => {
                outcome.dirty = true;
                self.set_bookmark(active()?, name)?
            }
            _ => {
                return Err(Error::Refused(format!(
                    "action not implemented on macOS yet: {}",
                    action_name(action)
                )));
            }
        };
        outcome.navigation = reply["navigation"].take();
        Ok(outcome)
    }
}
