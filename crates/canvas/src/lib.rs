// SPDX-License-Identifier: GPL-3.0-or-later
// Scene model is new macOS port code. Camera/focus algorithms derive from
// malbiruk/driftwm src/canvas.rs at commit 352333a8fa1b22171492d4b71a54102045c9a19d, GPL-3.0-or-later.
//! Persistent window world geometry and independent per-output cameras.
//!
//! All coordinates are logical points, top-left origin, Y down. A camera is the
//! world point at an output's top-left. Moving a camera never moves windows.
//! Native identities are observations, not durable permission to control a PID;
//! consumers must revalidate them against the running application after restore.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

mod cluster_resize;
mod geometry;
mod gestures;
mod layout;
mod momentum;
pub mod policy;
mod session;
pub use geometry::{Point, Rect, Size};
pub use gestures::{DragGesture, ResizeEdges, ResizeGesture};
pub use layout::SnapOptions;
pub use momentum::Momentum;
pub use session::SESSION_VERSION;

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Smallest supported zoom, matching DriftWM's hard floor.
pub const MIN_ZOOM: f64 = 0.001;
/// Native resolution is the maximum zoom.
pub const MAX_ZOOM: f64 = 1.0;

/// Logical window identity, independent of a process lifetime.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct WindowId(pub u64);
/// Stable logical output identity (the host maps this to a display).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct OutputId(pub u64);
/// A currently observed native window identity. Must be reconciled after restart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativeIdentity {
    /// Owning macOS process ID.
    pub pid: i32,
    /// Core Graphics window number.
    pub window_id: u32,
}
/// One window's persistent world-space frame.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Window {
    /// Logical identity.
    pub id: WindowId,
    /// Position and dimensions in world points, including native window chrome.
    pub world_rect: Rect,
    /// Ephemeral native binding; omitted from serialization and cleared on restore.
    #[serde(skip)]
    pub native: Option<NativeIdentity>,
    /// Last observed window title.
    pub title: String,
}
/// An independent view onto the shared world.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Viewport {
    /// Output identity.
    pub id: OutputId,
    /// World coordinate at this output's top-left.
    pub camera: Point,
    /// Screen points per world point, between [`MIN_ZOOM`] and [`MAX_ZOOM`].
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
/// Cardinal focus-navigation direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Negative X.
    Left,
    /// Positive X.
    Right,
    /// Negative Y.
    Up,
    /// Positive Y.
    Down,
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
/// Topmost hit and coordinates for native event forwarding.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Hit {
    /// Hit window identity.
    pub window: WindowId,
    /// Unscaled window-local coordinates including chrome.
    pub local: Point,
}
/// Saved camera and zoom, reusable on any output.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bookmark {
    /// World point shown at the viewport top-left.
    pub camera: Point,
    /// Zoom at capture time.
    pub zoom: f64,
}
/// Validation, lookup, serialization, or durable-storage failure.
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
    /// No matching bookmark.
    #[error("unknown bookmark {0}")]
    UnknownBookmark(String),
    /// Session version is not understood by this build.
    #[error("unsupported session schema {0}")]
    UnsupportedVersion(u32),
    /// JSON parsing or encoding failed.
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    /// File operation failed. A failed load never replaces the input file.
    #[error(transparent)]
    Io(#[from] std::io::Error),
}
/// Window world, z-order, output cameras and bookmarks. All mutations are validated.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, try_from = "SceneData")]
pub struct Scene {
    windows: Vec<Window>,
    outputs: Vec<Viewport>,
    focused: Option<WindowId>,
    bookmarks: BTreeMap<String, Bookmark>,
}
impl Scene {
    /// Empty scene.
    pub fn new() -> Self {
        Self::default()
    }
    /// Windows ordered bottom-to-top.
    pub fn windows(&self) -> &[Window] {
        &self.windows
    }
    /// Independent output cameras in registration order.
    pub fn outputs(&self) -> &[Viewport] {
        &self.outputs
    }
    /// Find a window.
    pub fn window(&self, id: WindowId) -> Option<&Window> {
        self.windows.iter().find(|w| w.id == id)
    }
    /// Find an output.
    pub fn output(&self, id: OutputId) -> Option<&Viewport> {
        self.outputs.iter().find(|o| o.id == id)
    }
    /// Current focus, if any.
    pub fn focused(&self) -> Option<WindowId> {
        self.focused
    }
    /// Named camera bookmarks.
    pub fn bookmarks(&self) -> &BTreeMap<String, Bookmark> {
        &self.bookmarks
    }
    /// Register a new window at the top of the stack, without stealing focus.
    pub fn add_window(&mut self, window: Window) -> Result<(), Error> {
        validate_window(&window)?;
        if self.window(window.id).is_some() {
            return Err(Error::Invalid("duplicate window ID"));
        }
        if window.native.is_some() && self.windows.iter().any(|w| w.native == window.native) {
            return Err(Error::Invalid("duplicate native identity"));
        }
        self.windows.push(window);
        Ok(())
    }
    /// Attach a freshly verified native identity, or detach with `None`.
    /// The host must verify current process ownership; this method only checks
    /// numeric validity and that no other logical window already owns the binding.
    pub fn bind_native(
        &mut self,
        id: WindowId,
        native: Option<NativeIdentity>,
    ) -> Result<(), Error> {
        if self.window(id).is_none() {
            return Err(Error::UnknownWindow(id));
        }
        if native.is_some_and(|n| n.pid <= 0 || n.window_id == 0) {
            return Err(Error::Invalid("native identity"));
        }
        if native.is_some()
            && self
                .windows
                .iter()
                .any(|w| w.id != id && w.native == native)
        {
            return Err(Error::Invalid("duplicate native identity"));
        }
        if let Some(window) = self.windows.iter_mut().find(|w| w.id == id) {
            window.native = native;
        }
        Ok(())
    }
    /// Remove a window; closing the focused window focuses the next topmost one.
    pub fn remove_window(&mut self, id: WindowId) -> Result<Window, Error> {
        let index = self
            .windows
            .iter()
            .position(|w| w.id == id)
            .ok_or(Error::UnknownWindow(id))?;
        let removed = self.windows.remove(index);
        if self.focused == Some(id) {
            self.focused = self.windows.last().map(|w| w.id);
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
        self.windows
            .iter_mut()
            .find(|w| w.id == id)
            .ok_or(Error::UnknownWindow(id))?
            .world_rect = rect;
        Ok(())
    }
    /// Translate one window in world units.
    pub fn move_window(&mut self, id: WindowId, delta: Point) -> Result<(), Error> {
        let rect = self
            .window(id)
            .ok_or(Error::UnknownWindow(id))?
            .world_rect
            .translated(delta);
        self.set_window_rect(id, rect)
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
                self.windows.iter().filter_map(move |window| {
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
    /// Hit-test on a specific output, returning the topmost window and inverse coordinates.
    pub fn hit_test(&self, id: OutputId, screen: Point) -> Option<Hit> {
        let output = self.output(id)?;
        if !output.screen_bounds.contains(screen) {
            return None;
        }
        let world = output.screen_to_world(screen);
        self.windows
            .iter()
            .rev()
            .find(|w| w.world_rect.contains(world))
            .map(|w| Hit {
                window: w.id,
                local: world - w.world_rect.origin,
            })
    }
    /// Focus and raise a window to the top of the global stack.
    pub fn focus(&mut self, id: WindowId) -> Result<(), Error> {
        let index = self
            .windows
            .iter()
            .position(|w| w.id == id)
            .ok_or(Error::UnknownWindow(id))?;
        let window = self.windows.remove(index);
        self.windows.push(window);
        self.focused = Some(id);
        Ok(())
    }
    /// Find and focus the nearest center within a ±45° directional cone.
    /// Starts at the focused window, or the viewport center if nothing is focused.
    pub fn directional_focus(
        &mut self,
        output: OutputId,
        direction: Direction,
    ) -> Result<Option<WindowId>, Error> {
        let viewport = self.output(output).ok_or(Error::UnknownOutput(output))?;
        let origin = self.focused.and_then(|id| self.window(id)).map_or_else(
            || viewport.world_bounds().center(),
            |w| w.world_rect.center(),
        );
        let unit = match direction {
            Direction::Left => Point::new(-1.0, 0.0),
            Direction::Right => Point::new(1.0, 0.0),
            Direction::Up => Point::new(0.0, -1.0),
            Direction::Down => Point::new(0.0, 1.0),
        };
        let mut best: Option<(WindowId, f64)> = None;
        for window in self
            .windows
            .iter()
            .rev()
            .filter(|w| Some(w.id) != self.focused)
        {
            let delta = window.world_rect.center() - origin;
            let dot = delta.x * unit.x + delta.y * unit.y;
            let cross = (delta.x * unit.y - delta.y * unit.x).abs();
            if dot > 0.0 && cross <= dot {
                let score = (delta.x * delta.x + delta.y * delta.y) / dot;
                if best.is_none_or(|(_, previous)| score < previous) {
                    best = Some((window.id, score));
                }
            }
        }
        if let Some((id, _)) = best {
            self.focus(id)?;
        }
        Ok(best.map(|(id, _)| id))
    }
    /// Capture an output camera in a named bookmark, replacing the same name.
    pub fn save_bookmark(&mut self, name: &str, output: OutputId) -> Result<(), Error> {
        if name.trim().is_empty() || name.len() > 256 {
            return Err(Error::Invalid("bookmark name"));
        }
        let viewport = self.output(output).ok_or(Error::UnknownOutput(output))?;
        self.bookmarks.insert(
            name.to_owned(),
            Bookmark {
                camera: viewport.camera,
                zoom: viewport.zoom,
            },
        );
        Ok(())
    }
    /// Restore a named camera onto one output.
    pub fn restore_bookmark(&mut self, name: &str, output: OutputId) -> Result<(), Error> {
        let bookmark = *self
            .bookmarks
            .get(name)
            .ok_or_else(|| Error::UnknownBookmark(name.to_owned()))?;
        let mut viewport = self
            .output(output)
            .ok_or(Error::UnknownOutput(output))?
            .clone();
        viewport.camera = bookmark.camera;
        viewport.zoom = bookmark.zoom;
        self.update_output(viewport)
    }
    /// Remove a named bookmark; returns whether it existed.
    pub fn remove_bookmark(&mut self, name: &str) -> bool {
        self.bookmarks.remove(name).is_some()
    }
    /// Validate all stored geometry, IDs and references, including deserialized data.
    pub fn validate(&self) -> Result<(), Error> {
        let mut windows = BTreeSet::new();
        let mut natives = BTreeSet::new();
        for window in &self.windows {
            validate_window(window)?;
            if !windows.insert(window.id) {
                return Err(Error::Invalid("duplicate window ID"));
            }
            if window
                .native
                .is_some_and(|native| !natives.insert((native.pid, native.window_id)))
            {
                return Err(Error::Invalid("duplicate native identity"));
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
        for (name, bookmark) in &self.bookmarks {
            if name.trim().is_empty()
                || name.len() > 256
                || !bookmark.camera.valid()
                || !valid_zoom(bookmark.zoom)
            {
                return Err(Error::Invalid("bookmark"));
            }
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
    if window
        .native
        .is_some_and(|n| n.pid <= 0 || n.window_id == 0)
    {
        return Err(Error::Invalid("native identity"));
    }
    Ok(())
}

// Deserialize through an untrusted representation so even direct serde use
// cannot manufacture an invalid Scene and bypass the command invariants.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SceneData {
    windows: Vec<Window>,
    outputs: Vec<Viewport>,
    focused: Option<WindowId>,
    bookmarks: BTreeMap<String, Bookmark>,
}
impl TryFrom<SceneData> for Scene {
    type Error = Error;
    fn try_from(data: SceneData) -> Result<Self, Error> {
        let scene = Self {
            windows: data.windows,
            outputs: data.outputs,
            focused: data.focused,
            bookmarks: data.bookmarks,
        };
        scene.validate()?;
        Ok(scene)
    }
}
