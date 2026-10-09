// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/{navigation,viewport,viewport_animation}.rs. Native frame geometry
// includes the titlebar; there is no additional compositor border.
use super::*;

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ZoomPolicy {
    Keep,
    Reset,
}
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FocusPlacement {
    #[default]
    Center,
    Top,
    Bottom,
    Left,
    Right,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}
impl FocusPlacement {
    fn pull(self) -> (i8, i8) {
        match self {
            Self::Center => (0, 0),
            Self::Top => (0, -1),
            Self::Bottom => (0, 1),
            Self::Left => (-1, 0),
            Self::Right => (1, 0),
            Self::TopLeft => (-1, -1),
            Self::TopRight => (1, -1),
            Self::BottomLeft => (-1, 1),
            Self::BottomRight => (1, 1),
        }
    }
}
#[derive(Clone, Debug, Serialize)]
pub(crate) struct NavigationContext {
    pub(crate) usable_rect_local: Rect,
    focus_placement: FocusPlacement,
    camera_speed: f64,
    outer_gap: f64,
}
#[derive(Clone, Copy, Debug, Serialize)]
pub(crate) struct Anchor {
    pub(crate) canvas: Point,
    pub(crate) screen: Point,
}
#[derive(Clone, Debug, Serialize)]
pub(crate) struct ViewFlight {
    pub(crate) camera_target: Option<Point>,
    pub(crate) zoom_target: Option<f64>,
    pub(crate) zoom_animation_anchor: Option<Anchor>,
    pub(crate) generation: u64,
}
/// Derived per request: the native visible frame already includes its titlebar.
struct NavigationFrame {
    visual_rect_world: Rect,
    extra_compositor_border: f64,
}
impl NavigationFrame {
    fn from_window(window: &Window) -> Self {
        Self {
            visual_rect_world: window.world_rect,
            extra_compositor_border: 0.0,
        }
    }
}
impl NavigationContext {
    fn align(&self, frame: &NavigationFrame, zoom: f64) -> Point {
        let center = self.usable_rect_local.center();
        let (px, py) = self.focus_placement.pull();
        let inset = (self.outer_gap - frame.extra_compositor_border) * zoom;
        let placed = [
            (
                px,
                self.usable_rect_local.origin.x,
                self.usable_rect_local.size.width,
                frame.visual_rect_world.size.width,
                center.x,
            ),
            (
                py,
                self.usable_rect_local.origin.y,
                self.usable_rect_local.size.height,
                frame.visual_rect_world.size.height,
                center.y,
            ),
        ]
        .map(|(pull, low, span, extent, center)| {
            let extent = extent * zoom;
            if extent + 2.0 * inset > span {
                return center;
            }
            match pull {
                -1 => low + inset + extent / 2.0,
                1 => low + span - inset - extent / 2.0,
                _ => center,
            }
        });
        Point::new(placed[0], placed[1])
    }
}

impl Controller {
    pub(crate) fn navigation_context(&self, output: OutputId) -> Result<NavigationContext, Error> {
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        Ok(self
            .navigation_contexts
            .get(&output)
            .cloned()
            .unwrap_or(NavigationContext {
                usable_rect_local: Rect::new(
                    0.0,
                    0.0,
                    viewport.screen_bounds.size.width,
                    viewport.screen_bounds.size.height,
                ),
                focus_placement: FocusPlacement::Center,
                camera_speed: 0.3,
                outer_gap: 0.0,
            }))
    }
    pub(crate) fn set_navigation_context(
        &mut self,
        output: OutputId,
        usable_rect_local: Rect,
        focus_placement: FocusPlacement,
        camera_speed: f64,
        outer_gap: f64,
    ) -> Result<(), Error> {
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        if !rect_valid(usable_rect_local)
            || usable_rect_local.origin.x < 0.0
            || usable_rect_local.origin.y < 0.0
            || usable_rect_local.right() > viewport.screen_bounds.size.width
            || usable_rect_local.bottom() > viewport.screen_bounds.size.height
            || !camera_speed.is_finite()
            || camera_speed <= 0.0
            || camera_speed > 1.0
            || !outer_gap.is_finite()
            || !(0.0..=1e12).contains(&outer_gap)
        {
            return Err(Error::Invalid("invalid navigation context"));
        }
        self.flights.remove(&output);
        self.navigation_contexts.insert(
            output,
            NavigationContext {
                usable_rect_local,
                focus_placement,
                camera_speed,
                outer_gap,
            },
        );
        Ok(())
    }
    pub(crate) fn arm_navigation(
        &mut self,
        window: WindowId,
        output: OutputId,
        policy: ZoomPolicy,
    ) -> Result<Value, Error> {
        if self.gesture.is_some() {
            return Err(Error::Invalid("navigation during active gesture"));
        }
        let context = self.navigation_context(output)?;
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        let zoom = match policy {
            ZoomPolicy::Keep => viewport.zoom,
            ZoomPolicy::Reset => 1.0,
        };
        let frame = NavigationFrame::from_window(
            self.scene
                .window(window)
                .ok_or(Error::Invalid("unknown window"))?,
        );
        let anchor = Anchor {
            canvas: frame.visual_rect_world.center(),
            screen: context.align(&frame, zoom),
        };
        let target = anchor.canvas - anchor.screen / zoom;
        if !point_valid(target) {
            return Err(Error::Invalid("navigation target out of bounds"));
        }
        self.next_navigation = self
            .next_navigation
            .checked_add(1)
            .ok_or(Error::Invalid("navigation generations exhausted"))?;
        // Upstream set_camera_anchor: window navigation disarms a zoom-to-fit return.
        self.overview_returns.remove(&output);
        self.flights.insert(
            output,
            ViewFlight {
                camera_target: Some(target),
                zoom_target: Some(zoom),
                zoom_animation_anchor: Some(anchor),
                generation: self.next_navigation,
            },
        );
        Ok(
            json!({"output":output,"generation":self.next_navigation,"target_camera":target,"target_zoom":zoom,"animating":true}),
        )
    }
    pub(crate) fn tick_navigation(&mut self, timestamp_ns: u64) -> Result<Value, Error> {
        let elapsed = match self.navigation_clock {
            Some(previous) => timestamp_ns
                .checked_sub(previous)
                .ok_or(Error::Invalid("navigation clock decreased"))?,
            None => 0,
        };
        self.navigation_clock = Some(timestamp_ns);
        let dt = std::time::Duration::from_nanos(elapsed.min(33_000_000)).as_secs_f64();
        let mut changed = Vec::new();
        for output in self.flights.keys().copied().collect::<Vec<_>>() {
            let context = self.navigation_context(output)?;
            let factor = 1.0 - (1.0 - context.camera_speed).powf(dt * 60.0);
            let mut viewport = self
                .scene
                .output(output)
                .ok_or(Error::Invalid("unknown output"))?
                .clone();
            let old = viewport.clone();
            let flight = self.flights.get_mut(&output).expect("flight exists");
            // Upstream multi-output order: zoom tick, then camera tick.
            if let Some(target) = flight.zoom_target {
                let dz = target - old.zoom;
                let zoom_close = dz.abs() < 0.001;
                viewport.zoom = if zoom_close {
                    target
                } else {
                    old.zoom + dz * factor
                };
                if let Some(anchor) = flight.zoom_animation_anchor {
                    let current_anchor = old.camera + anchor.screen / old.zoom;
                    let delta = anchor.canvas - current_anchor;
                    let center = current_anchor + delta * factor;
                    viewport.camera = center - anchor.screen / viewport.zoom;
                    flight.camera_target = None;
                    if zoom_close && delta.x * delta.x + delta.y * delta.y < 0.25 {
                        viewport.camera = anchor.canvas - anchor.screen / viewport.zoom;
                        flight.zoom_target = None;
                        flight.zoom_animation_anchor = None;
                    }
                } else if zoom_close {
                    flight.zoom_target = None;
                }
            }
            if let Some(target) = flight.camera_target {
                let delta = target - viewport.camera;
                viewport.camera = if delta.x * delta.x + delta.y * delta.y < 0.25 {
                    flight.camera_target = None;
                    target
                } else {
                    viewport.camera + delta * factor
                };
            }
            if viewport.camera != old.camera || viewport.zoom != old.zoom {
                changed.push(output);
            }
            if flight.camera_target.is_none() && flight.zoom_target.is_none() {
                self.flights.remove(&output);
            }
            self.scene.update_output(viewport)?;
            self.sync_output(output)?;
        }
        Ok(json!({"changed_outputs":changed,"needs_frames":!self.flights.is_empty()}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // Pure boundary unreachable through ABI: native windows add no compositor border.
    #[test]
    fn negative_border_inset_and_exact_fit() {
        let context = NavigationContext {
            usable_rect_local: Rect::new(23.0, 47.0, 920.0, 700.0),
            focus_placement: FocusPlacement::TopLeft,
            camera_speed: 0.3,
            outer_gap: 0.0,
        };
        let frame = NavigationFrame {
            visual_rect_world: Rect::new(0.0, 0.0, 208.0, 108.0),
            extra_compositor_border: 4.0,
        };
        assert_eq!(context.align(&frame, 1.0), Point::new(123.0, 97.0));
        let exact = NavigationFrame {
            visual_rect_world: Rect::new(0.0, 0.0, 928.0, 108.0),
            extra_compositor_border: 4.0,
        };
        assert_eq!(context.align(&exact, 1.0), Point::new(483.0, 97.0));
    }
}
