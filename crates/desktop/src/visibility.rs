// SPDX-License-Identifier: GPL-3.0-or-later
// Native minimization is an ephemeral visibility change, not DriftWM's
// close-and-stand-in suspension. The live source and canvas slot remain bound.
use super::*;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceVisibility {
    #[default]
    Visible,
    Minimized,
    /// Its native owner restored the window; placement is still unacknowledged.
    Restoring,
}

impl Controller {
    pub(crate) fn cmd_minimize(
        &mut self,
        selector: Option<&ipc::WindowSelector>,
        minimized: bool,
        outcome: &mut actions::Outcome,
    ) -> Result<(), String> {
        let window = self.select_live(selector)?;
        self.guard_resize_structure(Some(window))
            .map_err(|e| e.to_string())?;
        if minimized {
            self.require_source_interactive(window)
                .map_err(|e| e.to_string())?;
            if let Some(output) = self.fullscreen_output_of(window) {
                outcome.dirty |= self.exit_fullscreen_on(output).is_some();
            }
        } else if self.sources[&window].visibility != SourceVisibility::Minimized {
            return Err("window is not minimized".to_string());
        }
        let source = &self.sources[&window];
        outcome.effects.push(json!({"op":"set_minimized","window":window,"identity":source.identity,"generation":source.generation,"minimized":minimized}));
        Ok(())
    }
    pub(crate) fn source_interactive(&self, window: WindowId) -> bool {
        self.sources.get(&window).is_none_or(|source| {
            source.visibility == SourceVisibility::Visible && !source.visibility_pending
        })
    }

    pub(crate) fn source_presentable(&self, window: WindowId) -> bool {
        self.sources
            .get(&window)
            .is_none_or(|source| source.visibility != SourceVisibility::Minimized)
    }

    pub(crate) fn require_source_interactive(&self, window: WindowId) -> Result<(), Error> {
        if !self.source_interactive(window) {
            return Err(Error::Invalid("source is minimized or restoring"));
        }
        Ok(())
    }

    pub(crate) fn observe_visibility(
        &mut self,
        window: WindowId,
        identity: &SourceIdentity,
        generation: u64,
        minimized: bool,
    ) -> Result<Value, Error> {
        self.check_generation(window, identity, generation)?;
        self.guard_resize_structure(Some(window))?;
        let prior = self.sources[&window].visibility;
        let pending = self.sources[&window].visibility_pending;
        let next = if minimized {
            SourceVisibility::Minimized
        } else if prior == SourceVisibility::Minimized || pending {
            SourceVisibility::Restoring
        } else {
            prior
        };
        if prior == next && !pending {
            return Ok(json!({"changed":false,"visibility":next}));
        }
        let source = self.sources.get_mut(&window).expect("validated source");
        source.visibility = next;
        source.visibility_pending = false;
        source.visibility_placement_ready = false;
        source.visibility_revision = source
            .visibility_revision
            .checked_add(1)
            .ok_or(Error::Invalid("visibility revisions exhausted"))?;
        if minimized {
            self.minimize_fullscreen(window);
            self.release_gesture(window);
            self.invalidate_focus(window);
            if self.scene.focused() == Some(window) {
                self.clear_focus();
            }
        }
        Ok(json!({"changed":true,"visibility":next}))
    }

    pub(crate) fn source_visible(
        &mut self,
        window: WindowId,
        identity: &SourceIdentity,
        generation: u64,
        visibility_revision: u64,
    ) -> Result<Value, Error> {
        self.check_generation(window, identity, generation)?;
        self.guard_resize_structure(Some(window))?;
        let source = self.sources.get_mut(&window).expect("validated source");
        if source.visibility != SourceVisibility::Restoring
            || source.visibility_pending
            || source.visibility_revision != visibility_revision
        {
            return Err(Error::Invalid("source has no pending visibility restore"));
        }
        if self.fullscreen_restore_owed(window) {
            self.sources
                .get_mut(&window)
                .expect("validated source")
                .visibility_placement_ready = true;
            return Ok(json!({"changed":false,"visibility":SourceVisibility::Restoring}));
        }
        let source = self.sources.get_mut(&window).expect("validated source");
        source.visibility = SourceVisibility::Visible;
        source.visibility_placement_ready = false;
        Ok(json!({"changed":true,"visibility":source.visibility}))
    }
}
