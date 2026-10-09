// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/config/types.rs (Action, LayoutSwitch, TrackpadState), src/config/parse.rs
// (parse_action, parse_direction) and src/input/actions.rs (execute_action's
// dispatch). The grammar is complete; only the camera, bookmark and quit
// actions execute. Every other action parses and is then refused by name.
use super::*;

/// Upstream `config::Action`, variant for variant. `Direction` is the existing
/// `ViewDirection`. Arguments of actions that parse but do not run yet are
/// grammar only, hence the allowance.
#[allow(dead_code)]
#[derive(Clone, Debug)]
pub(crate) enum Action {
    Exec(String),
    ExecTerminal,
    ExecLauncher,
    Spawn(String),
    CloseWindow,
    SuspendWindow,
    NudgeWindow(ViewDirection),
    GrowWindow(ViewDirection),
    ShrinkWindow(ViewDirection),
    PanViewport(ViewDirection),
    CenterWindow,
    CenterNearest(ViewDirection),
    CycleWindows { backward: bool },
    HomeToggle,
    GoToBookmark(String),
    SetBookmark(String),
    MoveToBookmark(String),
    ZoomIn,
    ZoomOut,
    ZoomReset,
    ZoomToFit,
    ZoomToFitSnapped,
    ToggleFullscreen,
    FitWindow,
    FitWindowSnapped,
    FillWindow,
    SendToOutput(ViewDirection),
    SendCursorToOutput(ViewDirection),
    FocusCenter,
    TogglePinToScreen,
    SwitchLayout(LayoutSwitch),
    ReloadConfig,
    ToggleCursorPan,
    SetTrackpad(TrackpadState),
    Quit,
}
/// Cycle relative to the active keyboard layout, or jump to a keymap index.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug)]
pub(crate) enum LayoutSwitch {
    Next,
    Prev,
    Index(usize),
}
/// Desired trackpad send-events state, as set by `set-trackpad`.
#[derive(Clone, Copy, Debug)]
pub(crate) enum TrackpadState {
    Toggle,
    On,
    Off,
}
impl Action {
    /// The name `parse_action` matched, as upstream's catalog spells it.
    fn name(&self) -> &'static str {
        match self {
            Self::Exec(_) => "exec",
            Self::ExecTerminal => "exec-terminal",
            Self::ExecLauncher => "exec-launcher",
            Self::Spawn(_) => "spawn",
            Self::CloseWindow => "close-window",
            Self::SuspendWindow => "suspend-window",
            Self::NudgeWindow(_) => "nudge-window",
            Self::GrowWindow(_) => "grow-window",
            Self::ShrinkWindow(_) => "shrink-window",
            Self::PanViewport(_) => "pan-viewport",
            Self::CenterWindow => "center-window",
            Self::CenterNearest(_) => "center-nearest",
            Self::CycleWindows { .. } => "cycle-windows",
            Self::HomeToggle => "home-toggle",
            Self::GoToBookmark(_) => "go-to-bookmark",
            Self::SetBookmark(_) => "set-bookmark",
            Self::MoveToBookmark(_) => "move-to-bookmark",
            Self::ZoomIn => "zoom-in",
            Self::ZoomOut => "zoom-out",
            Self::ZoomReset => "zoom-reset",
            Self::ZoomToFit => "zoom-to-fit",
            Self::ZoomToFitSnapped => "zoom-to-fit-snapped",
            Self::ToggleFullscreen => "toggle-fullscreen",
            Self::FitWindow => "fit-window",
            Self::FitWindowSnapped => "fit-window-snapped",
            Self::FillWindow => "fill-window",
            Self::SendToOutput(_) => "send-to-output",
            Self::SendCursorToOutput(_) => "send-cursor-to-output",
            Self::FocusCenter => "focus-center",
            Self::TogglePinToScreen => "toggle-pin-to-screen",
            Self::SwitchLayout(_) => "switch-layout",
            Self::ReloadConfig => "reload-config",
            Self::ToggleCursorPan => "toggle-cursor-pan",
            Self::SetTrackpad(_) => "set-trackpad",
            Self::Quit => "quit",
        }
    }
}

/// Parse a keyboard action string like "exec foot" or "center-nearest up".
pub(crate) fn parse_action(s: &str) -> Result<Action, String> {
    let s = s.trim();
    let (name, arg) = match s.split_once(char::is_whitespace) {
        Some((n, a)) => (n, Some(a.trim())),
        None => (s, None),
    };
    let direction = |arg: Option<&str>| {
        parse_direction(arg.ok_or_else(|| format!("{name} requires a direction"))?)
    };
    let bookmark = |arg: Option<&str>| {
        arg.filter(|a| !a.is_empty())
            .map(str::to_string)
            .ok_or_else(|| format!("{name} requires a bookmark name"))
    };
    match name {
        "exec" => Ok(Action::Exec(
            arg.ok_or("exec requires a command argument")?.to_string(),
        )),
        "spawn" => Ok(Action::Spawn(
            arg.ok_or("spawn requires a command argument")?.to_string(),
        )),
        "exec-terminal" => Ok(Action::ExecTerminal),
        "exec-launcher" => Ok(Action::ExecLauncher),
        "close-window" => Ok(Action::CloseWindow),
        "suspend-window" => Ok(Action::SuspendWindow),
        "nudge-window" => Ok(Action::NudgeWindow(direction(arg)?)),
        // Upstream reaches this only from a keybinding: its mouse and gesture
        // parsers match these as continuous actions first.
        "resize-window" | "resize-window-snapped" => Err(format!(
            "{name} is a drag action for mouse, gesture and touch bindings — on a keybinding use \
             grow-window <dir> or shrink-window <dir>"
        )),
        "grow-window" => Ok(Action::GrowWindow(direction(arg)?)),
        "shrink-window" => Ok(Action::ShrinkWindow(direction(arg)?)),
        "pan-viewport" => Ok(Action::PanViewport(direction(arg)?)),
        "center-window" => Ok(Action::CenterWindow),
        "focus-center" => Ok(Action::FocusCenter),
        "center-nearest" => Ok(Action::CenterNearest(direction(arg)?)),
        "cycle-windows" => match arg.ok_or("cycle-windows requires forward or backward")? {
            "forward" => Ok(Action::CycleWindows { backward: false }),
            "backward" => Ok(Action::CycleWindows { backward: true }),
            other => Err(format!(
                "cycle-windows: expected forward or backward, got '{other}'"
            )),
        },
        "home-toggle" => Ok(Action::HomeToggle),
        "go-to" => Err(
            "go-to was removed — save the point as a bookmark and use go-to-bookmark <name>"
                .to_string(),
        ),
        "go-to-bookmark" => Ok(Action::GoToBookmark(bookmark(arg)?)),
        "set-bookmark" => Ok(Action::SetBookmark(bookmark(arg)?)),
        "move-to-bookmark" => Ok(Action::MoveToBookmark(bookmark(arg)?)),
        "zoom-in" => Ok(Action::ZoomIn),
        "zoom-out" => Ok(Action::ZoomOut),
        "zoom-reset" => Ok(Action::ZoomReset),
        "zoom-to-fit" => Ok(Action::ZoomToFit),
        "zoom-to-fit-snapped" => Ok(Action::ZoomToFitSnapped),
        "toggle-fullscreen" => Ok(Action::ToggleFullscreen),
        "fit-window" => Ok(Action::FitWindow),
        "fit-window-snapped" => Ok(Action::FitWindowSnapped),
        "fill-window" => Ok(Action::FillWindow),
        "send-to-output" => Ok(Action::SendToOutput(direction(arg)?)),
        "send-cursor-to-output" => Ok(Action::SendCursorToOutput(direction(arg)?)),
        "switch-layout" => {
            let arg = arg.ok_or("switch-layout requires next, prev, or a layout index")?;
            Ok(Action::SwitchLayout(
                match arg.trim().to_lowercase().as_str() {
                    "next" => LayoutSwitch::Next,
                    "prev" | "previous" => LayoutSwitch::Prev,
                    other => LayoutSwitch::Index(other.parse().map_err(|_| {
                        format!("switch-layout: expected next, prev, or an index, got '{other}'")
                    })?),
                },
            ))
        }
        "toggle-pin-to-screen" => Ok(Action::TogglePinToScreen),
        "reload-config" => Ok(Action::ReloadConfig),
        "toggle-cursor-pan" => Ok(Action::ToggleCursorPan),
        "set-trackpad" => Ok(Action::SetTrackpad(match arg {
            None => return Err("set-trackpad requires on, off, or toggle".to_string()),
            Some(a) if a.eq_ignore_ascii_case("on") => TrackpadState::On,
            Some(a) if a.eq_ignore_ascii_case("off") => TrackpadState::Off,
            Some(a) if a.eq_ignore_ascii_case("toggle") => TrackpadState::Toggle,
            Some(other) => {
                return Err(format!(
                    "set-trackpad: expected on, off, or toggle, got '{other}'"
                ));
            }
        })),
        "quit" => Ok(Action::Quit),
        other => Err(format!("unknown action: {other}")),
    }
}
/// Parse a direction string (case-insensitive).
fn parse_direction(s: &str) -> Result<ViewDirection, String> {
    match s.trim().to_lowercase().as_str() {
        "up" => Ok(ViewDirection::Up),
        "down" => Ok(ViewDirection::Down),
        "left" => Ok(ViewDirection::Left),
        "right" => Ok(ViewDirection::Right),
        "up-left" => Ok(ViewDirection::UpLeft),
        "up-right" => Ok(ViewDirection::UpRight),
        "down-left" => Ok(ViewDirection::DownLeft),
        "down-right" => Ok(ViewDirection::DownRight),
        other => Err(format!("unknown direction: {other}")),
    }
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
}
impl Controller {
    pub(crate) fn action(&mut self, output: Option<OutputId>, spec: &str) -> Result<Value, Error> {
        let outcome = self.run_action(output, spec)?;
        Ok(json!({"navigation":outcome.navigation,"effects":outcome.effects,"dirty":outcome.dirty}))
    }
    /// Parse and execute one action string. An unknown string, a known action
    /// that does not run here yet, and a missing active output are three
    /// different refusals, checked in that order.
    pub(crate) fn run_action(
        &mut self,
        output: Option<OutputId>,
        spec: &str,
    ) -> Result<Outcome, Error> {
        let action = parse_action(spec).map_err(Error::Refused)?;
        let mut outcome = Outcome::default();
        let active = || output.ok_or(Error::Invalid("no active output"));
        let mut reply = match &action {
            // The shell owns the process: quitting is its effect to perform.
            Action::Quit => {
                outcome.effects.push(json!({"op":"quit"}));
                return Ok(outcome);
            }
            Action::PanViewport(direction) => self.pan_viewport(active()?, *direction)?,
            Action::HomeToggle => self.home_toggle(active()?)?,
            Action::ZoomIn => self.zoom_in(active()?)?,
            Action::ZoomOut => self.zoom_out(active()?)?,
            Action::ZoomReset => self.zoom_reset(active()?)?,
            Action::ZoomToFit => self.zoom_to_fit(active()?)?,
            Action::GoToBookmark(name) => self.go_to_bookmark(active()?, name)?,
            Action::SetBookmark(name) => {
                outcome.dirty = true;
                self.set_bookmark(active()?, name)?
            }
            _ => {
                return Err(Error::Refused(format!(
                    "action not implemented on macOS yet: {}",
                    action.name()
                )));
            }
        };
        outcome.navigation = reply["navigation"].take();
        Ok(outcome)
    }
}
