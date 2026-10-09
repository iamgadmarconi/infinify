// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/actions.rs (the SendToOutput and SendCursorToOutput arms of
// execute_action, less their fullscreen and pinned legs), src/state/output.rs
// (output_for_window, output_shows_canvas_point, output_showing_canvas_point,
// output_in_direction) and src/input/mod.rs (check_hot_corners: the binding
// lookup and the grab half of its dragging suppression; the pointer latch is
// the shell's). An output's layout position and size are its `screen_bounds`.
// Native frames include their title bar, so chrome is zero.
use super::actions::{Outcome, action_string};
use super::ipc::frame;
use super::view_actions::{pixel, pixel_size};
use super::*;
use driftwm_canvas::policy;
use driftwm_core::config::{Direction, HotCorner, HotCorners};

/// A corner of an output, as `[outputs.hot_corners]` names it.
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Corner {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}
impl From<Corner> for HotCorner {
    fn from(value: Corner) -> Self {
        match value {
            Corner::TopLeft => Self::TopLeft,
            Corner::TopRight => Self::TopRight,
            Corner::BottomLeft => Self::BottomLeft,
            Corner::BottomRight => Self::BottomRight,
        }
    }
}
const CORNERS: [(HotCorner, &str); 4] = [
    (HotCorner::TopLeft, "top_left"),
    (HotCorner::TopRight, "top_right"),
    (HotCorner::BottomLeft, "bottom_left"),
    (HotCorner::BottomRight, "bottom_right"),
];

impl Controller {
    /// The `[[outputs]]` hot corners in force on an output: the entry named
    /// after its stable id, else the `*` entry, else none.
    fn hot_corner_rule(&self, output: OutputId) -> Option<&HotCorners> {
        let stable_id = &self.outputs.get(&output)?.stable_id;
        Some(&self.config().output_config(stable_id)?.hot_corners)
    }
    /// Every registered output's armed corners, with what the shell's trigger
    /// needs: upstream's zone size and its dragging rule.
    pub(crate) fn hot_corners(&self) -> Value {
        let unarmed = HotCorners::default();
        self.scene
            .outputs()
            .iter()
            .map(|viewport| {
                let rule = self.hot_corner_rule(viewport.id).unwrap_or(&unarmed);
                let corners: serde_json::Map<String, Value> = CORNERS
                    .iter()
                    .filter_map(|(corner, name)| {
                        let action = rule.bindings.get(corner)?;
                        Some(((*name).to_owned(), json!(action_string(action))))
                    })
                    .collect();
                json!({
                    "output":viewport.id,
                    "stable_id":self.outputs.get(&viewport.id).map(|saved| &saved.stable_id),
                    "threshold":rule.threshold,
                    "disable_while_dragging":rule.disable_while_dragging,
                    "disable_when_fullscreen":rule.disable_when_fullscreen,
                    "corners":corners,
                })
            })
            .collect()
    }
    /// Upstream check_hot_corners once the pointer has entered `corner` of
    /// `output`: run its action with that output active. A pointer grab
    /// suppresses it under `disable_while_dragging`; the controller's gesture is
    /// that grab, and held buttons are the shell's to see. `pointer` and `held`
    /// are what `action` takes: upstream runs a corner's action through
    /// execute_action like any other.
    pub(crate) fn hot_corner(
        &mut self,
        output: OutputId,
        corner: Corner,
        pointer: Option<Point>,
        held: bool,
    ) -> Result<Value, Error> {
        if self.scene.output(output).is_none() {
            return Err(Error::Invalid("unknown output"));
        }
        let grabbed = self.gesture.is_some();
        let action = self
            .hot_corner_rule(output)
            .filter(|rule| !(rule.disable_while_dragging && grabbed))
            .and_then(|rule| rule.bindings.get(&corner.into()))
            .cloned();
        let outcome = match action {
            Some(action) => self.run(Some(output), &action, pointer, held)?,
            None => Outcome::default(),
        };
        Ok(outcome.reply())
    }
    /// Upstream output_showing_canvas_point: the first registered output whose
    /// viewport shows the canvas point. Viewports overlap freely, so the first
    /// match is registration order, not proximity.
    fn output_showing(&self, point: Point) -> Option<OutputId> {
        // Upstream truncates the point and rounds the camera to whole pixels.
        let (x, y) = (point.x as i64, point.y as i64);
        self.scene
            .outputs()
            .iter()
            .find(|viewport| {
                let (Ok(left), Ok(top), Ok(size)) = (
                    pixel(viewport.camera.x.round()),
                    pixel(viewport.camera.y.round()),
                    pixel_size(viewport.screen_bounds.size),
                ) else {
                    return false;
                };
                let visible = policy::visible_canvas_rect((left, top).into(), size, viewport.zoom);
                let (left, top) = (i64::from(visible.loc.x), i64::from(visible.loc.y));
                x >= left
                    && x < left + i64::from(visible.size.w)
                    && y >= top
                    && y < top + i64::from(visible.size.h)
            })
            .map(|viewport| viewport.id)
    }
    /// Upstream output_in_direction: the nearest other output whose center
    /// lies within about 60 degrees of `direction` from this one's. Up is the
    /// smaller y, as in upstream's layout space.
    fn output_in_direction(&self, from: OutputId, direction: &Direction) -> Option<OutputId> {
        let from_center = self.scene.output(from)?.screen_bounds.center();
        let (dx, dy) = direction.to_unit_vec();
        self.scene
            .outputs()
            .iter()
            .filter(|viewport| viewport.id != from)
            .filter_map(|viewport| {
                let to = viewport.screen_bounds.center() - from_center;
                let distance = (to.x * to.x + to.y * to.y).sqrt();
                if distance < 1.0 {
                    return None;
                }
                ((to.x * dx + to.y * dy) / distance > 0.5).then_some((viewport.id, distance))
            })
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(id, _)| id)
    }
    fn known_output(&self, output: OutputId) -> Result<&Viewport, Error> {
        self.scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))
    }
    /// Upstream SendToOutput for a canvas window: the focused window lands
    /// where a navigation on the adjacent output would park it, on that
    /// output's `focus_placement` point at the zoom it is already at, and is
    /// raised. A logical world move, applied at once. Returns whether anything
    /// moved: no focused window and no adjacent output are no error upstream.
    pub(crate) fn send_to_output(
        &mut self,
        active: Option<OutputId>,
        direction: &Direction,
    ) -> Result<bool, Error> {
        if let Some(active) = active {
            self.known_output(active)?;
        }
        let Some(window) = self.scene.focused() else {
            return Ok(false);
        };
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        // Upstream's integer frame: its center decides the source output.
        let (loc, size) = frame(rect).map_err(Error::Refused)?;
        let half = Point::new(size[0] as f64 / 2.0, size[1] as f64 / 2.0);
        let center = Point::new(loc[0] as f64, loc[1] as f64) + half;
        let from = match self.output_showing(center) {
            Some(output) => output,
            None => active.ok_or(Error::Invalid("no active output"))?,
        };
        let Some(target) = self.output_in_direction(from, direction) else {
            return Ok(false);
        };
        let (camera, zoom) = {
            let viewport = self.known_output(target)?;
            (viewport.camera, viewport.zoom)
        };
        let align = self.navigation_context(target)?.align_rect(rect, zoom);
        let center = camera + align / zoom;
        // Upstream's `as i32`: toward zero, not to nearest.
        let moved = Rect {
            origin: Point::new((center.x - half.x).trunc(), (center.y - half.y).trunc()),
            size: rect.size,
        };
        self.place_window(window, moved).map_err(Error::Refused)?;
        // Upstream raise_and_focus_element. The window already holds the
        // logical focus, so this raises it and asks nothing of native focus.
        self.scene.focus(window)?;
        Ok(true)
    }
    /// Upstream SendCursorToOutput: the cursor goes to the center of the
    /// adjacent output's usable area. Upstream warps to the canvas point that
    /// center shows, which on the screen is the center itself. The shell owns
    /// the pointer, so the move is its effect to perform.
    pub(crate) fn send_cursor_to_output(
        &self,
        active: OutputId,
        direction: &Direction,
    ) -> Result<Option<Value>, Error> {
        self.known_output(active)?;
        let Some(target) = self.output_in_direction(active, direction) else {
            return Ok(None);
        };
        let origin = self.known_output(target)?.screen_bounds.origin;
        let center = self.navigation_context(target)?.usable_rect_local.center();
        Ok(Some(
            json!({"op":"warp_pointer","screen":origin + center,"output":target}),
        ))
    }
}
