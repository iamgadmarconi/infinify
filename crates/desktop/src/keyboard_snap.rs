// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm @
// df3de27b26c7998e8a460cffd8a4925cbed3a322 (v0.21.0),
// src/state/keyboard_snap.rs (move_to_snap_focused, keyboard_move_element, canvas_step,
// resize_to_snap_focused, stop_query, axis_of) and src/state/fill.rs
// (usable_canvas_bounds). The walk itself is not adapted: the stops, the
// nearest origin past a window and the grow and shrink lines are driftwm-core's
// `layout::snap::{StopQuery, next_origin, next_grow_line, next_shrink_line}`,
// upstream's own code with its own tests. What changes is where the numbers
// come from: a window's frame is the whole-pixel native frame (it has no title
// bar strip and no border to add, as in sizes.rs), "configured size" is
// sizes.rs's `configured_size`, and the camera that follows a move is the
// controller's flight (`arm_navigation`, `pan_minimally`) instead of the
// compositor's camera target. `resize-to-snap` ends in the same size
// transaction as `grow-window`: `step_resize` with the delta to the stop.
// Only world rectangles, output poses and the configuration are read, never
// native geometry. See SIZES.md ("Keyboard snapping").
use super::actions::Outcome;
use super::sizes::{Px, snap_rect_at, usable_px};
use super::window_actions::MinimalPan;
use super::*;
use driftwm_core::config::Direction;
use driftwm_core::layout::snap::{self, SnapRect, StopQuery};
use driftwm_core::platform::utils::{Logical, Point as CorePoint, Size as CoreSize};

/// `(horizontal, toward higher coordinates)` for a cardinal direction. The
/// diagonals never parse for these actions.
fn axis_of(dir: &Direction) -> Option<(bool, bool)> {
    match dir {
        Direction::Left => Some((true, false)),
        Direction::Right => Some((true, true)),
        Direction::Up => Some((false, false)),
        Direction::Down => Some((false, true)),
        _ => None,
    }
}

impl Controller {
    /// Upstream usable_canvas_bounds: `output`'s usable area as a canvas rect,
    /// through its own camera and zoom.
    pub(crate) fn usable_canvas_bounds(&self, output: OutputId) -> Result<SnapRect, Error> {
        let context = self.navigation_context(output)?;
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        let (at, extent) = usable_px(context.usable_rect_local)?;
        let low = viewport.camera + Point::new(at[0] as f64, at[1] as f64) / viewport.zoom;
        let high = viewport.camera
            + Point::new((at[0] + extent[0]) as f64, (at[1] + extent[1]) as f64) / viewport.zoom;
        Ok(SnapRect {
            x_low: low.x,
            x_high: high.x,
            y_low: low.y,
            y_high: high.y,
        })
    }

    /// Upstream stop_query: the query for `frame`'s stops along one axis, with
    /// the alignment band a drag at zoom 1 would use. The magnetism knobs tune
    /// a drag, not what the keyboard can reach.
    fn stop_query(&self, frame: &SnapRect, horizontal: bool) -> StopQuery {
        let (perp_low, perp_high) = if horizontal {
            (frame.y_low, frame.y_high)
        } else {
            (frame.x_low, frame.x_high)
        };
        let config = self.config();
        StopQuery {
            horizontal,
            perp_low,
            perp_high,
            gap: config.snap_gap,
            align_band: config.snap_gap + config.snap_distance,
            same_edge: true,
            edge_center: true,
            side_docks: false,
        }
    }

    /// Every other window that snaps: the obstacles and stops of a keyboard
    /// walk.
    fn snap_others(&self, window: WindowId) -> Vec<SnapRect> {
        self.snap_rects()
            .into_iter()
            .filter(|(other, _)| *other != window)
            .map(|(_, rect)| rect)
            .collect()
    }

    /// Does `output`'s view, where its flight lands, show the canvas point?
    fn landing_shows(&self, output: OutputId, center: Point) -> bool {
        let (Ok((camera, zoom)), Some(viewport)) =
            (self.landing_view(output), self.scene.output(output))
        else {
            return false;
        };
        let (Ok(x), Ok(y), Ok(w), Ok(h)) = (
            view_actions::pixel(camera.x.round()),
            view_actions::pixel(camera.y.round()),
            view_actions::pixel(viewport.screen_bounds.size.width.round()),
            view_actions::pixel(viewport.screen_bounds.size.height.round()),
        ) else {
            return false;
        };
        let visible = driftwm_core::canvas::visible_canvas_rect(
            CorePoint::<i32, Logical>::from((x, y)),
            CoreSize::<i32, Logical>::from((w, h)),
            zoom,
        );
        let (cx, cy) = (center.x as i32, center.y as i32);
        (visible.loc.x..visible.loc.x.saturating_add(visible.size.w)).contains(&cx)
            && (visible.loc.y..visible.loc.y.saturating_add(visible.size.h)).contains(&cy)
    }

    /// Upstream canvas_step: the canvas px that `step` screen px cover for
    /// `window`, keeping the sign and never rounding a nonzero step down to
    /// nothing. Measured at the landing zoom of the active output if that view
    /// shows the window's center (the view `move-to-snap` scrolls), else of the
    /// output that shows it (`home_output`), else at 1.
    pub(crate) fn canvas_step(&self, window: WindowId, active: Option<OutputId>, step: i32) -> i32 {
        if step == 0 {
            return 0;
        }
        let zoom = self
            .scene
            .window(window)
            .map(|found| found.world_rect.center())
            .and_then(|center| {
                active
                    .filter(|output| self.landing_shows(*output, center))
                    .or_else(|| self.home_output(window, active).ok().flatten())
            })
            .and_then(|output| self.landing_view(output).ok())
            .map_or(1.0, |(_, zoom)| zoom);
        step.signum() * ((f64::from(step.unsigned_abs()) / zoom).round() as i32).max(1)
    }

    /// Upstream move_to_snap_focused: move the focused canvas window along
    /// `dir` to the nearest stop past where it sits, and bring the camera along
    /// if that leaves the viewport. With no stop that way it nudges by
    /// `nudge_step` instead, the camera scrolling along with it once its
    /// leading edge reaches `outer_gap` from the usable edge.
    pub(crate) fn move_to_snap(
        &mut self,
        output: Option<OutputId>,
        dir: &Direction,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        let Some((horizontal, forward)) = axis_of(dir) else {
            return Ok(());
        };
        let Some(window) = self.scene.focused().filter(|id| self.on_canvas(*id)) else {
            return Ok(());
        };
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let (loc, committed) = self.px_frame(window)?;
        // The size the placement assumes, not committed geometry: the action
        // prelude may have just exited fullscreen, and the window goes on
        // reporting the output's size until its size comes back.
        let size = self.configured_size(window, committed);
        let others = self.snap_others(window);
        let frame = snap_rect_at(loc, size);
        let q = StopQuery {
            side_docks: true,
            ..self.stop_query(&frame, horizontal)
        };
        let (from, extent) = if horizontal {
            (frame.x_low, frame.x_high - frame.x_low)
        } else {
            (frame.y_low, frame.y_high - frame.y_low)
        };
        let stop = snap::next_origin(from, forward, extent, &others, &q);
        let new_loc: Px = match stop {
            Some(origin) if horizontal => [origin.round() as i64, loc[1]],
            Some(origin) => [loc[0], origin.round() as i64],
            // No clear stop means no window ahead in the perpendicular span:
            // the one reaching furthest that way would offer a clear far dock.
            // So the nudge can't land on a window either.
            None => {
                let step = self.canvas_step(window, output, self.config().nudge_step);
                if step == 0 {
                    return Ok(());
                }
                let step = i64::from(if forward { step } else { -step });
                if horizontal {
                    [loc[0].saturating_add(step), loc[1]]
                } else {
                    [loc[0], loc[1].saturating_add(step)]
                }
            }
        };
        // Upstream keyboard_move_element: the window is re-anchored, which ends
        // a fill restore point.
        let moved = Rect {
            origin: Point::new(new_loc[0] as f64, new_loc[1] as f64),
            size: rect.size,
        };
        self.place_window(window, moved).map_err(Error::Refused)?;
        outcome.dirty = true;

        let Some(output) = output else {
            return Ok(());
        };
        // Judged where a flight still under way lands, not at its current
        // frame: a pan heading for the previous stop would leave this one.
        let (camera, zoom) = self.landing_view(output)?;
        let landed = snap_rect_at(new_loc, size);
        if stop.is_some() {
            if !self.frame_fully_in_view_at(&landed, output, camera, zoom)? {
                outcome.navigation = self.arm_navigation(window, output, ZoomPolicy::Keep)?;
            }
            return Ok(());
        }
        // As an edge pan carries a dragged window: it rides the `outer_gap`
        // line while the canvas scrolls under it, only the way the window went,
        // where parking every step would throw the view around. Shown at the
        // size just judged, which a window that declined a resize is still
        // drawn at.
        let pan = MinimalPan::LeadingEdge {
            horizontal,
            forward,
        };
        if self.minimal_pan_moves(output, &landed, camera, zoom, pan)? {
            self.hover_parked();
            outcome.navigation = self.pan_minimally(output, &landed, camera, zoom, pan)?;
        }
        Ok(())
    }

    /// Upstream resize_to_snap_focused: resize the focused canvas window by
    /// walking its right or bottom edge. `right` / `down` grow it out to the
    /// next stop, never past the usable area or over another window; `left` /
    /// `up` pull it back to the previous one, or by `resize_step` with none
    /// inside the window. The size is asked for like `grow-window`'s.
    pub(crate) fn resize_to_snap(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        dir: &Direction,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        let Some((horizontal, grow)) = axis_of(dir) else {
            return Ok(());
        };
        if !self.sources.contains_key(&window) {
            return Err(Error::Refused(
                "resize-to-snap needs a live window: a stand-in has no native size to change"
                    .to_owned(),
            ));
        }
        let (loc, committed) = self.px_frame(window)?;
        // Upstream step_start_rect: while a size is still owed the walk goes on
        // from the size asked for, so a held key steps at the repeat rate and
        // not at the window's answering rate.
        let current = self.owed_size(window).unwrap_or(committed);
        let others = self.snap_others(window);
        let frame = snap_rect_at(loc, current);
        let Some(home) = self.home_output(window, output)? else {
            return Ok(());
        };
        // The fence `fill-window` grows inside, refused the same way for a
        // window lying entirely outside it: `home_output` falls back to the
        // active output for a window no viewport shows, and that viewport's far
        // edge is no bound for a window screens away.
        let outer_gap = self.navigation_context(home)?.outer_gap();
        let fence = self.usable_canvas_bounds(home)?.inset(outer_gap);
        if !frame.overlaps(&fence) {
            return Ok(());
        }
        let q = self.stop_query(&frame, horizontal);
        let (edge, anchor, bound) = if horizontal {
            (frame.x_high, frame.x_low, fence.x_high)
        } else {
            (frame.y_high, frame.y_low, fence.y_high)
        };
        let target = if grow {
            snap::next_grow_line(edge, edge, bound, &others, &q)
        } else {
            // A zero step isn't a reliable no-op: from a declined request it
            // would ask for that request again.
            let step = self.canvas_step(window, output, self.config().resize_step);
            snap::next_shrink_line(edge, anchor, bound, &others, &q)
                .or_else(|| (step > 0).then_some(edge - f64::from(step)))
        };
        let Some(target) = target else {
            return Ok(());
        };
        let axis = if horizontal {
            Direction::Right
        } else {
            Direction::Down
        };
        self.step_resize(
            window,
            output,
            "resize-to-snap",
            &axis,
            (target - edge).round() as i64,
            outcome,
        )
    }
}
