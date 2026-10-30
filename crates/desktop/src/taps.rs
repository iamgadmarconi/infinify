// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/keyboard.rs (on_keyboard: the chord TapTracker completes is looked
// up with Config::tap_lookup ahead of the pass_keys decision, on a release,
// which that decision never sees; its action then runs through execute_action
// once the key event has been forwarded) and src/config/mod.rs (tap_lookup).
// The tracker itself (TapTracker: the peak, the taint, one fire per chord) is
// not adapted here: modifier events reach the shell, which keeps it. The
// bindings are driftwm-core's, upstream's own code. The macOS chord of a tap
// is the key bindings' modifier mapping (bindings.rs), which is new.
//! Tap-modifier bindings: a bare modifier chord, pressed and released with no
//! other key or button on top.
//!
//! A `[keybindings]` entry with no keysym, `"alt+shift" = "switch-layout
//! next"`, is a tap binding. Its upstream modifier set maps to a macOS chord
//! exactly as a key binding's does: `logo` is the super chord, and a `ctrl` or
//! `alt` the super chord already holds is displaced. A set with no chord is
//! skipped, and so is every tap after the first, in combo order, on one chord.
use super::actions::action_string;
use super::bindings::{combo_text, modifier_sets};
use super::*;
use driftwm_core::config::Action;

/// One tap binding of the config: its combo as a file spells it, and its
/// macOS chord or why it has none.
struct Tap<'a> {
    combo: String,
    chord: Result<MacModifiers, String>,
    action: &'a Action,
}

impl Controller {
    /// Every tap binding of the config, sorted by combo text. The table is
    /// private to driftwm-core, so each of the 32 modifier sets is asked for.
    /// The first tap on a chord keeps it, as the first key binding does.
    fn tap_bindings(&self) -> Vec<Tap<'_>> {
        let config = self.config();
        let mut bound: Vec<Tap<'_>> = modifier_sets()
            .filter_map(|modifiers| {
                Some(Tap {
                    action: config.tap_lookup(&modifiers)?,
                    combo: combo_text(&modifiers, config.mod_key, None),
                    chord: self.platform.physical(&modifiers),
                })
            })
            .collect();
        bound.sort_by(|a, b| a.combo.cmp(&b.combo));
        let mut claimed: BTreeMap<MacModifiers, String> = BTreeMap::new();
        for tap in &mut bound {
            let Ok(chord) = tap.chord else {
                continue;
            };
            match claimed.get(&chord) {
                Some(winner) => {
                    tap.chord = Err(format!("'{winner}' already holds this macOS chord"));
                }
                None => {
                    claimed.insert(chord, tap.combo.clone());
                }
            }
        }
        bound
    }
    /// The `taps` list of the `bindings` reply: each tap binding that has a
    /// macOS chord, for the shell to watch the modifiers for. A tap without
    /// one is handed to `skip`, as a key binding without a chord is.
    pub(crate) fn taps(&self, skip: &mut dyn FnMut(&str, &Action, String, bool)) -> Vec<Value> {
        let mut taps = Vec::new();
        for tap in self.tap_bindings() {
            match tap.chord {
                Ok(chord) => taps.push(json!({
                    "combo":tap.combo,
                    "modifiers":chord,
                    "action":action_string(tap.action),
                    "implemented":self.runs(tap.action),
                })),
                Err(reason) => skip(&tap.combo, tap.action, reason, true),
            }
        }
        taps
    }
    /// Upstream's tap leg of on_keyboard: the action bound to the completed
    /// chord runs as any binding's does, through `run` and its prelude.
    /// `modifiers` is the chord at its fullest, as physical modifiers. No
    /// window's `pass_keys` takes a tap: upstream decides it on a release,
    /// ahead of the pass test, which asks key presses only. A chord with no
    /// tap binding is refused. `pointer` and `held` are as `run` takes them.
    pub(crate) fn tap(
        &mut self,
        modifiers: MacModifiers,
        output: Option<OutputId>,
        pointer: Option<Point>,
        held: bool,
    ) -> Result<Value, Error> {
        let bound = self
            .tap_bindings()
            .into_iter()
            .find(|tap| tap.chord == Ok(modifiers))
            .map(|tap| tap.action.clone());
        let Some(action) = bound else {
            let chord = modifiers.symbols();
            return Err(Error::Refused(if chord.is_empty() {
                "a tap needs a modifier".to_owned()
            } else {
                format!("no tap binding on {chord}")
            }));
        };
        Ok(self.run(output, &action, pointer, held)?.reply())
    }
}
