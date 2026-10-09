// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/actions.rs (PanViewport, HomeToggle, ZoomIn, ZoomOut, ZoomReset,
// ZoomToFit, try_restore_overview, fit_to_bbox, zoom_to_anchored) and
// src/state/navigation.rs (min_zoom). Camera-only: fullscreen legs, nav anchors
// and pointer warps are absent, and no native geometry is read.
use super::navigation::Anchor;
use super::*;
use driftwm_canvas::policy::{self, PixelPoint, PixelSize};

/// Upstream src/config/mod.rs runtime default `navigation.pan_step`, screen points.
const PAN_STEP: f64 = 100.0;
/// Upstream src/config/mod.rs runtime default `zoom.step`.
const ZOOM_STEP: f64 = 1.1;
/// Upstream src/config/mod.rs runtime default `zoom.fit_padding`, screen points.
const ZOOM_FIT_PADDING: f64 = 80.0;

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ViewDirection {
    Up,
    Down,
    Left,
    Right,
    UpLeft,
    UpRight,
    DownLeft,
    DownRight,
}
impl From<ViewDirection> for policy::Direction {
    fn from(value: ViewDirection) -> Self {
        match value {
            ViewDirection::Up => Self::Up,
            ViewDirection::Down => Self::Down,
            ViewDirection::Left => Self::Left,
            ViewDirection::Right => Self::Right,
            ViewDirection::UpLeft => Self::UpLeft,
            ViewDirection::UpRight => Self::UpRight,
            ViewDirection::DownLeft => Self::DownLeft,
            ViewDirection::DownRight => Self::DownRight,
        }
    }
}
/// The pose a toggle flies back to. Ephemeral: never saved, dropped with its output.
#[derive(Clone, Copy, Debug, Serialize)]
pub(crate) struct ViewReturn {
    camera: Point,
    zoom: f64,
}

/// Upstream policy works in i32 logical pixels; reject rather than saturate.
fn pixel(value: f64) -> Result<i32, Error> {
    if (f64::from(i32::MIN)..=f64::from(i32::MAX)).contains(&value) {
        Ok(value as i32)
    } else {
        Err(Error::Invalid("view geometry exceeds integer range"))
    }
}
fn pixel_size(size: Size) -> Result<PixelSize, Error> {
    Ok((pixel(size.width.round())?, pixel(size.height.round())?).into())
}
fn idle() -> Result<Value, Error> {
    Ok(json!({"navigation": null}))
}

impl Controller {
    /// The output's current pose and its output-local usable rectangle, whose
    /// center is upstream's usable_center_screen.
    fn view(&self, output: OutputId) -> Result<(Viewport, Rect), Error> {
        if self.gesture.is_some() {
            return Err(Error::Invalid("navigation during active gesture"));
        }
        let usable = self.navigation_context(output)?.usable_rect_local;
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        Ok((viewport.clone(), usable))
    }
    /// Every scene frame, detached placeholders included, at the integer boundary
    /// crates/canvas/POLICY.md leaves to the caller: floor the origin and ceil
    /// the far edge, so a fit never clips a fractional frame.
    fn pixel_windows(&self) -> Result<Vec<(PixelPoint, PixelSize)>, Error> {
        let (mut low, mut high) = ((i32::MAX, i32::MAX), (i32::MIN, i32::MIN));
        let mut windows = Vec::with_capacity(self.scene.windows().len());
        for window in self.scene.windows() {
            let rect = window.world_rect;
            let (x, y) = (pixel(rect.origin.x.floor())?, pixel(rect.origin.y.floor())?);
            let (right, bottom) = (pixel(rect.right().ceil())?, pixel(rect.bottom().ceil())?);
            low = (low.0.min(x), low.1.min(y));
            high = (high.0.max(right), high.1.max(bottom));
            // The bounding box subtracts these extremes in i32, as each size does.
            if high.0.checked_sub(low.0).is_none() || high.1.checked_sub(low.1).is_none() {
                return Err(Error::Invalid("view geometry exceeds integer range"));
            }
            windows.push(((x, y).into(), (right - x, bottom - y).into()));
        }
        Ok(windows)
    }
    /// Replace the output's flight. An anchored flight animates zoom around the
    /// anchor; without one only the camera travels and `zoom` is the current zoom.
    fn arm_view(
        &mut self,
        output: OutputId,
        target: Point,
        zoom: f64,
        anchor: Option<Anchor>,
    ) -> Result<Value, Error> {
        // The destination viewport's far corner must stay in the world as well: a
        // flight that cannot land would fail every later tick, for every output.
        let size = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .screen_bounds
            .size;
        if !point_valid(target) || !point_valid(target + Point::new(size.width, size.height) / zoom)
        {
            return Err(Error::Invalid("navigation target out of bounds"));
        }
        self.next_navigation = self
            .next_navigation
            .checked_add(1)
            .ok_or(Error::Invalid("navigation generations exhausted"))?;
        self.flights.insert(
            output,
            ViewFlight {
                camera_target: Some(target),
                zoom_target: anchor.map(|_| zoom),
                zoom_animation_anchor: anchor,
                generation: self.next_navigation,
            },
        );
        Ok(
            json!({"navigation":{"output":output,"generation":self.next_navigation,"target_camera":target,"target_zoom":zoom,"animating":true}}),
        )
    }
    fn restore_view(
        &mut self,
        output: OutputId,
        ret: ViewReturn,
        center: Point,
    ) -> Result<Value, Error> {
        let anchor = Anchor {
            canvas: ret.camera + center / ret.zoom,
            screen: center,
        };
        self.arm_view(output, ret.camera, ret.zoom, Some(anchor))
    }
    pub(crate) fn pan_viewport(
        &mut self,
        output: OutputId,
        direction: ViewDirection,
    ) -> Result<Value, Error> {
        let (viewport, _) = self.view(output)?;
        self.overview_returns.remove(&output);
        let step = PAN_STEP / viewport.zoom;
        let (ux, uy) = policy::Direction::from(direction).to_unit_vec();
        // Repeated presses extend the destination instead of restarting from the
        // partially animated camera. A zoom flight stops at the current zoom.
        let from = self
            .flights
            .get(&output)
            .and_then(|flight| flight.camera_target)
            .unwrap_or(viewport.camera);
        let target = from + Point::new(ux * step, uy * step);
        self.arm_view(output, target, viewport.zoom, None)
    }
    pub(crate) fn home_toggle(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let center = usable.center();
        // At home means zoom ≈ 1.0 and the world origin visible on the whole output.
        let full = pixel_size(viewport.screen_bounds.size)?;
        if (viewport.zoom - 1.0).abs() < 0.01
            && policy::is_origin_visible(viewport.camera, full, viewport.zoom)
        {
            return match self.home_returns.remove(&output) {
                Some(ret) => self.restore_view(output, ret, center),
                None => idle(),
            };
        }
        self.home_returns.insert(
            output,
            ViewReturn {
                camera: viewport.camera,
                zoom: viewport.zoom,
            },
        );
        self.overview_returns.remove(&output);
        let anchor = Anchor {
            canvas: Point::default(),
            screen: center,
        };
        self.arm_view(output, Point::new(-center.x, -center.y), 1.0, Some(anchor))
    }
    /// Animate to `target`, keeping the world point under the usable center fixed.
    fn zoom_to_anchored(
        &mut self,
        output: OutputId,
        viewport: &Viewport,
        center: Point,
        target: f64,
    ) -> Result<Value, Error> {
        self.overview_returns.remove(&output);
        let anchor = Anchor {
            canvas: viewport.camera + center / viewport.zoom,
            screen: center,
        };
        let camera = policy::zoom_anchor_camera(anchor.canvas, center, target);
        self.arm_view(output, camera, target, Some(anchor))
    }
    pub(crate) fn zoom_in(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let target = policy::snap_zoom((viewport.zoom * ZOOM_STEP).min(policy::MAX_ZOOM));
        self.zoom_to_anchored(output, &viewport, usable.center(), target)
    }
    pub(crate) fn zoom_out(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let min = policy::dynamic_min_zoom(
            self.pixel_windows()?.into_iter(),
            pixel_size(usable.size)?,
            ZOOM_FIT_PADDING,
        );
        let target = policy::snap_zoom((viewport.zoom / ZOOM_STEP).max(min));
        // Deviation: pinch and scroll zoom keep the static 0.001 floor, so the
        // pose may already sit below the dynamic minimum. Never zoom in from there.
        if target > viewport.zoom {
            return idle();
        }
        self.zoom_to_anchored(output, &viewport, usable.center(), target)
    }
    pub(crate) fn zoom_reset(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        self.zoom_to_anchored(output, &viewport, usable.center(), 1.0)
    }
    /// A toggle: restore a pending overview return, otherwise fit every window
    /// and remember the pose being left.
    pub(crate) fn zoom_to_fit(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let center = usable.center();
        if let Some(ret) = self.overview_returns.remove(&output) {
            return self.restore_view(output, ret, center);
        }
        let Some(bbox) = policy::all_windows_bbox(self.pixel_windows()?.into_iter()) else {
            return idle();
        };
        let fit = policy::zoom_to_fit(bbox, pixel_size(usable.size)?, ZOOM_FIT_PADDING);
        let anchor = Anchor {
            canvas: Point::new(
                f64::from(bbox.loc.x) + f64::from(bbox.size.w) / 2.0,
                f64::from(bbox.loc.y) + f64::from(bbox.size.h) / 2.0,
            ),
            screen: center,
        };
        self.overview_returns.insert(
            output,
            ViewReturn {
                camera: viewport.camera,
                zoom: viewport.zoom,
            },
        );
        self.arm_view(output, anchor.canvas - center / fit, fit, Some(anchor))
    }
}
