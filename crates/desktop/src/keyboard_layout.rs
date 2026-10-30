// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/actions.rs (the SwitchLayout arm of execute_action) and
// src/ipc/mod.rs (cmd_layout, active_layout_short). Upstream's layouts are the
// xkb groups of its own keymap; here they are the keyboard input sources the
// user has enabled, which only the shell can list and select, so the switch is
// an effect and the active layout is what the shell reports back.
use super::*;
use driftwm_core::config::LayoutSwitch;

/// The active keyboard layout among the enabled ones.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct KeyboardLayout {
    /// The display name: upstream's `active_layout`.
    name: String,
    /// A short code for status bars: upstream's `layout_short`.
    short: String,
    index: usize,
    count: usize,
}

/// Upstream SwitchLayout as a request to the shell. An index past the last
/// layout changes nothing upstream; the shell's list decides that here.
pub(crate) fn switch_effect(target: &LayoutSwitch) -> Value {
    let (target, index) = match target {
        LayoutSwitch::Next => ("next", None),
        LayoutSwitch::Prev => ("prev", None),
        LayoutSwitch::Index(index) => ("index", Some(*index)),
    };
    json!({"op":"switch_layout","target":target,"index":index})
}

impl Controller {
    pub(crate) fn layout_changed(
        &mut self,
        name: String,
        short: String,
        index: usize,
        count: usize,
    ) -> Result<Value, Error> {
        if !text_valid(&name, 1024) || !text_valid(&short, 1024) || index >= count {
            return Err(Error::Invalid("invalid keyboard layout"));
        }
        self.layout = Some(KeyboardLayout {
            name,
            short,
            index,
            count,
        });
        Ok(json!({}))
    }
    /// Upstream `active_layout`: empty until the shell has reported one.
    pub(crate) fn layout_name(&self) -> String {
        self.layout
            .as_ref()
            .map(|layout| layout.name.clone())
            .unwrap_or_default()
    }
    /// Upstream active_layout_short: the short code, else the display name.
    pub(crate) fn layout_short(&self) -> String {
        match &self.layout {
            Some(layout) if !layout.short.is_empty() => layout.short.clone(),
            _ => self.layout_name(),
        }
    }
}
