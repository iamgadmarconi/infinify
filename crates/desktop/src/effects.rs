// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/errors.rs (ErrorSource and its order, summarize_config_errors, and
// set_error's no-op for an unchanged message), src/state/reload.rs
// (reload_config: which outcome of a load sets the config source and which
// clears it, and what sets the keyboard source), src/state/init.rs (the launch
// load reports the same messages), and what decides which window events are
// animated: src/handlers/compositor.rs (a new toplevel's first sized commit
// starts the open animation unless the window adopted a stand-in, a widget and
// a `focus_on_open = false` window included), src/handlers/xdg_shell.rs
// (toplevel_destroyed: one closing snapshot, alpha only when the close turns
// into a stand-in), src/state/suspended.rs (the two StandInFade pushes:
// adopt_relaunched's crossfade and dismiss_suspended's shrinking fade) and
// src/state/window_animation_driver.rs (start_window_open_animation and
// snapshot_closing_window: the skips for a window no output can draw and for
// stale pixels, which are the shell's to make). The curves, the frost and the
// bar are drawn by the shell's compositor. `[effects]` is not adapted: it is
// driftwm-core's `EffectsConfig` as its `parse_effects_config` left it (an
// infinite `blur_strength` apart, which no JSON number is), and a window's
// blur is its `effective_blur`, upstream's own code.
use super::lifecycle::Arrival;
use super::*;
use driftwm_core::config::effective_blur;

/// How many lifecycle events the snapshot lists. The shell plays each one
/// once, by serial; an event older than the list is lost.
const MAX_EVENTS: usize = 32;

/// A window event upstream animates, under the snapshot's spelling.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum LifecycleEvent {
    /// A new window mapped: upstream's open scale and fade.
    Open,
    /// A window closed and left the canvas: upstream's closing snapshot.
    Close,
    /// A window closed into a stand-in: the snapshot fades in place over it.
    CloseToStandin,
    /// A stand-in was dismissed: upstream's shrinking StandInFade.
    StandinDismiss,
    /// A relaunched window took its stand-in's slot: the crossfade.
    StandinAdopted,
}
#[derive(Clone, Debug, Serialize)]
struct Logged {
    serial: u64,
    window: WindowId,
    event: LifecycleEvent,
    /// The active output the command named, not where the window is drawn.
    output: Option<OutputId>,
}
/// What the shell shows that is no part of the scene: the error bar's message
/// and the window events it animates. Never saved, and kept across a `load`.
#[derive(Clone, Debug, Default)]
pub(crate) struct Effects {
    /// Upstream's `ErrorSource::Config` message. Of its other two sources the
    /// background's is the shell's, whose background program reports it, and
    /// the keyboard's is never set: upstream raises it when xkb refuses the
    /// config's layout, and here `[input.keyboard] layout` is read and unused,
    /// macOS owning the layout list (CONFIG.md, Keyboard layouts).
    config_error: Option<String>,
    /// The most recent events, oldest first.
    events: Vec<Logged>,
    /// The serial of the last event logged in this run.
    serial: u64,
}

/// Upstream summarize_config_errors: the bar has room for one line per source,
/// so the first warning stands for the rest. Which one is first is this
/// port's choice, not upstream's: upstream takes the parser's first, and its
/// parser collects the warnings of the tables it reads into a hash map in an
/// order that differs between two loads of one file. The least of them in
/// byte order, the head of the sorted list, is the same at every load.
fn summarize_config_errors(warnings: &[String]) -> Option<String> {
    let first = warnings.iter().min()?;
    Some(match warnings.len() {
        1 => first.clone(),
        n => format!("{first} (+{} more)", n - 1),
    })
}

impl Controller {
    /// `render.effects`: upstream's `[effects]` table as its parser sanitised it.
    /// Its `non_negative` lets `blur_strength = inf` through, the one value of
    /// the five JSON cannot carry (it would be written as null): the block
    /// says 0, what the shell's compositor makes of an infinite strength
    /// (native/desktop/COMPOSITOR-NOTES.md, deviation 31).
    pub(crate) fn effects_block(&self) -> Value {
        let effects = &self.config().effects;
        let blur_strength = match effects.blur_strength.is_finite() {
            true => effects.blur_strength,
            false => 0.0,
        };
        json!({"blur_radius":effects.blur_radius,"blur_strength":blur_strength,"animate_blur_fps":effects.animate_blur_fps,"animation_speed":effects.animation_speed,"animation_scale":effects.animation_scale})
    }
    /// `render.errors`: the controller's messages for the error bar, in the
    /// order of upstream's sources. The config source is the only one here.
    pub(crate) fn error_messages(&self) -> Vec<&str> {
        self.effects
            .config_error
            .iter()
            .map(String::as_str)
            .collect()
    }
    /// The snapshot's `lifecycle_events`.
    pub(crate) fn lifecycle_events(&self) -> Value {
        json!(self.effects.events)
    }
    /// Whether one element's backdrop is frosted: `effective_blur` over the
    /// rule the window mapped with, for a bound window only. Upstream requests
    /// blur for client windows and never for a stand-in, whatever
    /// `[decorations] blur` says (native/desktop/COMPOSITOR-NOTES.md, 18.1).
    /// A fullscreen window is frosted by its own rule's `blur` alone, never
    /// by the global one: `effective_blur`'s `is_fullscreen`.
    pub(crate) fn blur_of(&self, window: WindowId) -> bool {
        let fullscreen = self.is_fullscreen(window);
        self.sources.contains_key(&window)
            && effective_blur(
                self.drawn_rule(window),
                &self.config().decorations,
                fullscreen,
            )
    }
    /// A config load has ended with these `errors` and `warnings`: upstream's
    /// rules for the config source, at launch and on a reload alike. A file
    /// that could not be read or parsed sets its message and one that loaded
    /// with warnings sets their summary; a clean load clears it. A message
    /// that changes spends a render revision, unless this load already spent
    /// one: `before` is the revision it started from. The same message again
    /// changes nothing, as upstream's set_error redraws nothing for it.
    pub(crate) fn note_config(
        &mut self,
        errors: &[String],
        warnings: &[String],
        before: u64,
    ) -> Result<(), Error> {
        let message = errors
            .first()
            .cloned()
            .or_else(|| summarize_config_errors(warnings));
        if message == self.effects.config_error {
            return Ok(());
        }
        self.effects.config_error = message;
        if self.render_revision == before {
            self.render_revision = before
                .checked_add(1)
                .ok_or(Error::Invalid("render revisions exhausted"))?;
        }
        Ok(())
    }
    /// Log one event for the shell to play once. The visibility, pixel-age and
    /// `animation_speed` skips are the shell's: nothing is withheld for them.
    fn log_lifecycle(
        &mut self,
        window: WindowId,
        event: LifecycleEvent,
        output: Option<OutputId>,
    ) -> Result<(), Error> {
        let effects = &mut self.effects;
        effects.serial = effects
            .serial
            .checked_add(1)
            .ok_or(Error::Invalid("lifecycle event serials exhausted"))?;
        if effects.events.len() >= MAX_EVENTS {
            effects.events.remove(0);
        }
        effects.events.push(Logged {
            serial: effects.serial,
            window,
            event,
            output,
        });
        Ok(())
    }
    /// A new window has mapped. Upstream opens every toplevel that did not
    /// adopt a stand-in, a widget and a `focus_on_open = false` window
    /// included, and crossfades the stand-in over the one that did
    /// (adopt_relaunched, its identity match: a pending relaunch). A waiting
    /// slot that takes its own window back is the macOS rule, which upstream
    /// has not, and animates nothing. Nor does a window of the launch pass:
    /// it was open before the canvas was, and nobody opened it here. Called
    /// before the lifecycle is pruned, while the relaunch is still listed.
    pub(crate) fn log_arrival(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        arrival: Arrival,
    ) -> Result<(), Error> {
        let event = match arrival {
            Arrival::Adopt(_) if self.lifecycle.relaunching.contains(&window) => {
                LifecycleEvent::StandinAdopted
            }
            Arrival::Adopt(_) => return Ok(()),
            Arrival::Place { .. } | Arrival::Pin { .. } if self.lifecycle.settled => {
                LifecycleEvent::Open
            }
            Arrival::Place { .. } | Arrival::Pin { .. } => return Ok(()),
        };
        self.log_lifecycle(window, event, output)
    }
    /// The native window is gone. Upstream toplevel_destroyed snapshots the
    /// dying window either way: alpha only over the stand-in that takes its
    /// place, scaled and faded when it leaves the canvas.
    pub(crate) fn log_close(
        &mut self,
        window: WindowId,
        standin: bool,
        output: Option<OutputId>,
    ) -> Result<(), Error> {
        let event = match standin {
            true => LifecycleEvent::CloseToStandin,
            false => LifecycleEvent::Close,
        };
        self.log_lifecycle(window, event, output)
    }
    /// Upstream dismiss_suspended: the stand-in fades and shrinks where it stood.
    /// The `forget` command, the shell's own removal of a placeholder, logs
    /// the same for what is drawn as a stand-in, and names no output.
    pub(crate) fn log_dismiss(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
    ) -> Result<(), Error> {
        self.log_lifecycle(window, LifecycleEvent::StandinDismiss, output)
    }
}
