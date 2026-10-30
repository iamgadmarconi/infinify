// SPDX-License-Identifier: GPL-3.0-or-later
// MRU algorithms adapted from https://github.com/malbiruk/driftwm
// src/stage/mod.rs, commit 352333a8fa1b22171492d4b71a54102045c9a19d.
use crate::{Window, WindowId};

/// Value-owned window geometry, stacking, and ephemeral MRU cycle state.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Stage {
    windows: Vec<Window>,
    history: Vec<WindowId>,
    pub(crate) cycle_state: Option<usize>,
}
impl Stage {
    pub(crate) fn windows(&self) -> &[Window] {
        &self.windows
    }
    pub(crate) fn into_windows(self) -> Vec<Window> {
        self.windows
    }
    pub(crate) fn add(&mut self, window: Window) {
        self.windows.push(window);
    }
    pub(crate) fn window_mut(&mut self, id: WindowId) -> Option<&mut Window> {
        self.windows.iter_mut().find(|w| w.id == id)
    }
    pub(crate) fn raise(&mut self, id: WindowId) {
        if let Some(index) = self.windows.iter().position(|w| w.id == id) {
            let window = self.windows.remove(index);
            self.windows.push(window);
        }
    }
    pub(crate) fn from_windows(windows: Vec<Window>) -> Self {
        Self {
            windows,
            ..Self::default()
        }
    }
    /// Confirmed native focus history, most recent first.
    pub fn focus_history(&self) -> &[WindowId] {
        &self.history
    }
    /// Selected index into frozen history.
    pub fn cycle_state(&self) -> Option<usize> {
        self.cycle_state
    }
    pub(crate) fn push_focus(&mut self, id: WindowId) {
        self.history.retain(|w| *w != id);
        self.history.insert(0, id);
    }
    pub(crate) fn remove(&mut self, index: usize) -> Window {
        let window = self.windows.remove(index);
        self.drop_history(window.id);
        window
    }
    pub(crate) fn drop_history(&mut self, id: WindowId) {
        self.history.retain(|w| *w != id);
        if let Some(index) = self.cycle_state {
            self.cycle_state =
                (!self.history.is_empty()).then(|| index.min(self.history.len() - 1));
        }
    }
    pub(crate) fn cycle_step(
        &mut self,
        backward: bool,
        focused: Option<WindowId>,
    ) -> Option<WindowId> {
        let len = self.history.len();
        if len == 0 {
            return None;
        }
        let index = match self.cycle_state {
            Some(i) => {
                if backward {
                    (i + len - 1) % len
                } else {
                    (i + 1) % len
                }
            }
            None if focused.is_some_and(|f| self.history.first() != Some(&f)) => 0,
            None => 1 % len,
        };
        self.cycle_state = Some(index);
        Some(self.history[index])
    }
    pub(crate) fn end_cycle(&mut self) {
        if let Some(index) = self.cycle_state.take()
            && let Some(id) = self.history.get(index).copied()
        {
            self.push_focus(id);
        }
    }
}
