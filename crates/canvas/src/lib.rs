// SPDX-License-Identifier: GPL-3.0-or-later
// Scene model is new macOS port code. Camera algorithms derive from
// https://github.com/malbiruk/driftwm src/canvas.rs at commit
// 352333a8fa1b22171492d4b71a54102045c9a19d, GPL-3.0-or-later.
//! Persistent window world geometry and independent per-output cameras.
//!
//! All coordinates are logical points, top-left origin, Y down. A camera is the
//! world point at an output's top-left. Moving a camera never moves windows.
//! Nothing here knows about native windows: a host maps its own identities to
//! [`WindowId`] and [`OutputId`].
#![forbid(unsafe_code)]
#![deny(missing_docs)]

mod cluster_resize;
mod geometry;
mod gestures;
mod layout;
mod stage;
pub use geometry::{Point, Rect, Size};
pub use gestures::{DragGesture, ResizeEdges, ResizeGesture};
pub use layout::SnapOptions;
pub use stage::Stage;

use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Smallest supported zoom, matching DriftWM's hard floor.
const MIN_ZOOM: f64 = 0.001;
/// Native resolution is the maximum zoom.
const MAX_ZOOM: f64 = 1.0;

/// Logical window identity, independent of a process lifetime.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct WindowId(pub u64);
/// Stable logical output identity (the host maps this to a display).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct OutputId(pub u64);
/// One window's persistent world-space frame.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(from = "WindowWire")]
pub struct Window {
    /// Logical identity.
    pub id: WindowId,
    /// Position and dimensions in world points, including native window chrome.
    pub world_rect: Rect,
}
/// An independent view onto the shared world.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Viewport {
    /// Output identity.
    pub id: OutputId,
    /// World coordinate at this output's top-left.
    pub camera: Point,
    /// Screen points per world point, from 0.001 to 1.0 (native resolution).
    pub zoom: f64,
    /// Global screen bounds in logical points, top-left origin and Y down.
    pub screen_bounds: Rect,
}
impl Viewport {
    /// Project a world point into global screen coordinates.
    pub fn world_to_screen(&self, world: Point) -> Point {
        self.screen_bounds.origin + (world - self.camera) * self.zoom
    }
    /// Inverse projection into world coordinates.
    pub fn screen_to_world(&self, screen: Point) -> Point {
        (screen - self.screen_bounds.origin) / self.zoom + self.camera
    }
    /// World rectangle currently covered by this viewport.
    pub fn world_bounds(&self) -> Rect {
        Rect {
            origin: self.camera,
            size: Size::new(
                self.screen_bounds.size.width / self.zoom,
                self.screen_bounds.size.height / self.zoom,
            ),
        }
    }
    fn valid(&self) -> bool {
        self.camera.valid()
            && valid_zoom(self.zoom)
            && self.screen_bounds.valid()
            && self.world_bounds().valid()
    }
}
/// A renderable instance of a window on one output. The same window may occur on multiple outputs.
#[derive(Debug, Clone, PartialEq)]
pub struct Placement {
    /// Logical window being rendered.
    pub window: WindowId,
    /// Output receiving this instance.
    pub output: OutputId,
    /// Full projected rectangle, before output clipping.
    pub screen_rect: Rect,
    /// Visible rectangle in global screen points.
    pub clip_rect: Rect,
    /// Visible region in unscaled window-local points, suitable for texture cropping.
    pub source_rect: Rect,
}
/// Validation or lookup failure.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Invalid geometry, identity, or consistency rule.
    #[error("invalid scene: {0}")]
    Invalid(&'static str),
    /// No matching window.
    #[error("unknown window {0:?}")]
    UnknownWindow(WindowId),
    /// No matching output.
    #[error("unknown output {0:?}")]
    UnknownOutput(OutputId),
}
/// Window world, z-order, output cameras and focus. All mutations are validated.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, try_from = "SceneWire", into = "SceneData")]
pub struct Scene {
    stage: Stage,
    outputs: Vec<Viewport>,
    focused: Option<WindowId>,
    /// Windows that take no part in snapping or clusters: DriftWM's widgets
    /// and screen-pinned windows, which its snap rectangles leave out.
    unsnapped: BTreeSet<WindowId>,
}
impl Scene {
    /// Empty scene.
    pub fn new() -> Self {
        Self::default()
    }
    /// Windows ordered bottom-to-top.
    pub fn windows(&self) -> &[Window] {
        self.stage.windows()
    }
    /// Window and focus-cycle state, owned by this scene.
    pub fn stage(&self) -> &Stage {
        &self.stage
    }
    /// Advance frozen MRU history and update logical intent.
    pub fn cycle_focus(&mut self, backward: bool) -> Result<Option<WindowId>, Error> {
        let selected = self.stage.cycle_step(backward, self.focused);
        if let Some(id) = selected {
            self.focus(id)?;
        }
        Ok(selected)
    }
    /// Promote confirmed native focus, retaining frozen history during cycling.
    pub fn confirm_focus(&mut self, id: WindowId) -> Result<(), Error> {
        if self.window(id).is_none() {
            return Err(Error::UnknownWindow(id));
        }
        if self.stage.cycle_state.is_none() {
            self.stage.push_focus(id);
        }
        Ok(())
    }
    /// Commit a confirmed cycle selection.
    pub fn end_cycle(&mut self) {
        self.stage.end_cycle();
    }
    /// Cancel a cycle without promotion.
    pub fn cancel_cycle(&mut self) {
        self.stage.cycle_state = None;
    }
    /// Remove an ineligible or detached window from native focus history.
    pub fn drop_focus_history(&mut self, id: WindowId) {
        self.stage.drop_history(id);
    }
    /// Independent output cameras in registration order.
    pub fn outputs(&self) -> &[Viewport] {
        &self.outputs
    }
    /// Find a window.
    pub fn window(&self, id: WindowId) -> Option<&Window> {
        self.stage.windows().iter().find(|w| w.id == id)
    }
    /// Find an output.
    pub fn output(&self, id: OutputId) -> Option<&Viewport> {
        self.outputs.iter().find(|o| o.id == id)
    }
    /// Current focus, if any.
    pub fn focused(&self) -> Option<WindowId> {
        self.focused
    }
    /// Register a new window at the top of the stack, without stealing focus.
    pub fn add_window(&mut self, window: Window) -> Result<(), Error> {
        validate_window(&window)?;
        if self.window(window.id).is_some() {
            return Err(Error::Invalid("duplicate window ID"));
        }
        self.stage.add(window);
        Ok(())
    }
    /// Remove a window; closing the focused window focuses the next topmost one.
    pub fn remove_window(&mut self, id: WindowId) -> Result<Window, Error> {
        let index = self
            .stage
            .windows()
            .iter()
            .position(|w| w.id == id)
            .ok_or(Error::UnknownWindow(id))?;
        let removed = self.stage.remove(index);
        self.unsnapped.remove(&id);
        if self.focused == Some(id) {
            self.focused = self.stage.windows().last().map(|w| w.id);
        }
        Ok(removed)
    }
    /// Register an independent output. Overlap with another output is allowed.
    pub fn add_output(&mut self, output: Viewport) -> Result<(), Error> {
        if !output.valid() {
            return Err(Error::Invalid("output geometry or zoom"));
        }
        if self.output(output.id).is_some() {
            return Err(Error::Invalid("duplicate output ID"));
        }
        self.outputs.push(output);
        Ok(())
    }
    /// Replace an output's bounds/camera, for display reconfiguration.
    pub fn update_output(&mut self, output: Viewport) -> Result<(), Error> {
        if !output.valid() {
            return Err(Error::Invalid("output geometry or zoom"));
        }
        let id = output.id;
        *self.output_mut(id)? = output;
        Ok(())
    }
    /// Disconnect an output without touching window geometry.
    pub fn remove_output(&mut self, id: OutputId) -> Result<Viewport, Error> {
        let index = self
            .outputs
            .iter()
            .position(|o| o.id == id)
            .ok_or(Error::UnknownOutput(id))?;
        Ok(self.outputs.remove(index))
    }
    /// Change one window's world frame, for a move or resize.
    pub fn set_window_rect(&mut self, id: WindowId, rect: Rect) -> Result<(), Error> {
        if !rect.valid() {
            return Err(Error::Invalid("window geometry"));
        }
        self.stage
            .window_mut(id)
            .ok_or(Error::UnknownWindow(id))?
            .world_rect = rect;
        Ok(())
    }
    /// Pan by a screen-space displacement of the camera (positive X reveals the right).
    pub fn pan(&mut self, id: OutputId, screen_delta: Point) -> Result<(), Error> {
        if !screen_delta.valid() {
            return Err(Error::Invalid("pan delta"));
        }
        let mut output = self.output(id).ok_or(Error::UnknownOutput(id))?.clone();
        output.camera = output.camera + screen_delta / output.zoom;
        self.update_output(output)
    }
    /// Set zoom while keeping the world point under a global screen anchor fixed.
    pub fn zoom_at(&mut self, id: OutputId, zoom: f64, anchor: Point) -> Result<(), Error> {
        if !valid_zoom(zoom) || !anchor.valid() {
            return Err(Error::Invalid("zoom or anchor"));
        }
        let mut output = self.output(id).ok_or(Error::UnknownOutput(id))?.clone();
        let world = output.screen_to_world(anchor);
        output.camera = world - (anchor - output.screen_bounds.origin) / zoom;
        output.zoom = zoom;
        self.update_output(output)
    }
    /// Visible instances in output order and bottom-to-top z-order within each output.
    pub fn placements(&self) -> Vec<Placement> {
        self.outputs
            .iter()
            .flat_map(|output| {
                self.stage.windows().iter().filter_map(move |window| {
                    let origin = output.world_to_screen(window.world_rect.origin);
                    let screen_rect = Rect {
                        origin,
                        size: Size::new(
                            window.world_rect.size.width * output.zoom,
                            window.world_rect.size.height * output.zoom,
                        ),
                    };
                    let clip_rect = screen_rect.intersection(output.screen_bounds)?;
                    let source_rect = Rect {
                        origin: (clip_rect.origin - screen_rect.origin) / output.zoom,
                        size: Size::new(
                            clip_rect.size.width / output.zoom,
                            clip_rect.size.height / output.zoom,
                        ),
                    };
                    Some(Placement {
                        window: window.id,
                        output: output.id,
                        screen_rect,
                        clip_rect,
                        source_rect,
                    })
                })
            })
            .collect()
    }
    /// Raise a window to the top of the global stack without focusing it.
    pub fn raise(&mut self, id: WindowId) -> Result<(), Error> {
        if self.window(id).is_none() {
            return Err(Error::UnknownWindow(id));
        }
        self.stage.raise(id);
        Ok(())
    }
    /// Whether a window takes part in snapping and clusters. Every window does
    /// until it is told otherwise.
    pub fn snaps(&self, id: WindowId) -> bool {
        !self.unsnapped.contains(&id)
    }
    /// Take a window out of snapping and clusters, or put it back. An excluded
    /// window attracts no dragged or resized edge, joins no cluster, and moved
    /// or resized as a group it is alone.
    pub fn set_snapping(&mut self, id: WindowId, snaps: bool) -> Result<(), Error> {
        if self.window(id).is_none() {
            return Err(Error::UnknownWindow(id));
        }
        if snaps {
            self.unsnapped.remove(&id);
        } else {
            self.unsnapped.insert(id);
        }
        Ok(())
    }
    /// Focus and raise a window to the top of the global stack.
    pub fn focus(&mut self, id: WindowId) -> Result<(), Error> {
        if self.window(id).is_none() {
            return Err(Error::UnknownWindow(id));
        }
        self.stage.raise(id);
        self.focused = Some(id);
        Ok(())
    }
    /// Focus a window where it stands: `focus` without the raise. Stacking
    /// order, focus history and an open cycle are untouched. DriftWM's hover
    /// focus, which moves the focus and restacks nothing.
    pub fn focus_in_place(&mut self, id: WindowId) -> Result<(), Error> {
        if self.window(id).is_none() {
            return Err(Error::UnknownWindow(id));
        }
        self.focused = Some(id);
        Ok(())
    }
    /// Leave no window focused. Stacking order and focus history are untouched.
    pub fn clear_focus(&mut self) {
        self.focused = None;
    }
    /// Validate all stored geometry, IDs and references, including deserialized data.
    pub fn validate(&self) -> Result<(), Error> {
        let mut windows = BTreeSet::new();
        for window in self.stage.windows() {
            validate_window(window)?;
            if !windows.insert(window.id) {
                return Err(Error::Invalid("duplicate window ID"));
            }
        }
        let mut outputs = BTreeSet::new();
        for output in &self.outputs {
            if !output.valid() {
                return Err(Error::Invalid("output geometry or zoom"));
            }
            if !outputs.insert(output.id) {
                return Err(Error::Invalid("duplicate output ID"));
            }
        }
        if self.focused.is_some_and(|id| !windows.contains(&id)) {
            return Err(Error::Invalid("dangling focus"));
        }
        Ok(())
    }
    fn output_mut(&mut self, id: OutputId) -> Result<&mut Viewport, Error> {
        self.outputs
            .iter_mut()
            .find(|o| o.id == id)
            .ok_or(Error::UnknownOutput(id))
    }
}
fn valid_zoom(zoom: f64) -> bool {
    zoom.is_finite() && (MIN_ZOOM..=MAX_ZOOM).contains(&zoom)
}
fn validate_window(window: &Window) -> Result<(), Error> {
    if !window.world_rect.valid() {
        return Err(Error::Invalid("window geometry"));
    }
    Ok(())
}

// Deserialize through an untrusted representation so even direct serde use
// cannot manufacture an invalid Scene and bypass the command invariants.
#[derive(Clone, Serialize)]
struct SceneData {
    windows: Vec<Window>,
    outputs: Vec<Viewport>,
    focused: Option<WindowId>,
}
// What a scene file may hold. A file written by an earlier build also carries a
// per-window `title`, a `bookmarks` table and an `unsnapped` list, which no
// longer belong to the scene; they are read and dropped so that file still
// loads, and are never written again.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SceneWire {
    windows: Vec<Window>,
    outputs: Vec<Viewport>,
    focused: Option<WindowId>,
    #[serde(default)]
    #[allow(dead_code)]
    bookmarks: serde::de::IgnoredAny,
    #[serde(default)]
    #[allow(dead_code)]
    unsnapped: serde::de::IgnoredAny,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WindowWire {
    id: WindowId,
    world_rect: Rect,
    #[serde(default)]
    #[allow(dead_code)]
    title: serde::de::IgnoredAny,
}
impl From<WindowWire> for Window {
    fn from(wire: WindowWire) -> Self {
        Self {
            id: wire.id,
            world_rect: wire.world_rect,
        }
    }
}
impl TryFrom<SceneWire> for Scene {
    type Error = Error;
    fn try_from(data: SceneWire) -> Result<Self, Error> {
        let scene = Self {
            stage: Stage::from_windows(data.windows),
            outputs: data.outputs,
            focused: data.focused,
            unsnapped: BTreeSet::new(),
        };
        scene.validate()?;
        Ok(scene)
    }
}

impl From<Scene> for SceneData {
    fn from(scene: Scene) -> Self {
        Self {
            windows: scene.stage.into_windows(),
            outputs: scene.outputs,
            focused: scene.focused,
        }
    }
}
