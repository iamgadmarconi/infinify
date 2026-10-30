// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/input/actions.rs (PanViewport, HomeToggle, GoToBookmark, SetBookmark,
// ZoomIn, ZoomOut, ZoomReset, ZoomToFit, go_to_canvas_point,
// try_restore_overview, fit_to_bbox, zoom_to_anchored), src/state/navigation.rs
// (min_zoom) and src/state/viewport.rs (set_camera_target). Camera-only:
// pointer warps are absent and no native geometry is read. HomeToggle's
// fullscreen legs are fullscreen.rs's `home_toggle_fullscreen`, and no flight
// is armed on a fullscreen output, whose camera is parked.
// `navigation.pan_step`, `zoom.step`, `zoom.fit_padding` and
// `navigation.anchors` come from the configuration in force.
use super::navigation::Anchor;
use super::*;
use driftwm_canvas::policy::{self, PixelPoint, PixelSize};

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
    pub(crate) camera: Point,
    pub(crate) zoom: f64,
}

/// Upstream policy works in i32 logical pixels; reject rather than saturate.
pub(crate) fn pixel(value: f64) -> Result<i32, Error> {
    if (f64::from(i32::MIN)..=f64::from(i32::MAX)).contains(&value) {
        Ok(value as i32)
    } else {
        Err(Error::Invalid("view geometry exceeds integer range"))
    }
}
pub(crate) fn pixel_size(size: Size) -> Result<PixelSize, Error> {
    Ok((pixel(size.width.round())?, pixel(size.height.round())?).into())
}
fn idle() -> Result<Value, Error> {
    Ok(json!({"navigation": null}))
}

impl Controller {
    /// The output's current pose and its output-local usable rectangle, whose
    /// center is upstream's usable_center_screen.
    pub(crate) fn view(&self, output: OutputId) -> Result<(Viewport, Rect), Error> {
        if self.gesture.is_some() || self.native_resize_grab_output().is_some() {
            return Err(Error::Invalid("navigation during active gesture"));
        }
        let usable = self.navigation_context(output)?.usable_rect_local;
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        Ok((viewport.clone(), usable))
    }
    /// Every canvas frame, detached placeholders included and widgets and
    /// screen-pinned windows left out, at the integer boundary
    /// crates/canvas/POLICY.md leaves to the caller: floor the origin and ceil
    /// the far edge, so a fit never clips a fractional frame. With `anchors`,
    /// upstream ZoomToFit's `navigation.anchors` follow as zero-size points,
    /// truncated to whole pixels as upstream's `as i32` does.
    fn pixel_windows(&self, anchors: bool) -> Result<Vec<(PixelPoint, PixelSize)>, Error> {
        let mut frames = Vec::with_capacity(self.scene.windows().len());
        for window in self.scene.windows() {
            // Upstream fits and bounds the zoom by canvas windows only.
            if !self.on_canvas(window.id) {
                continue;
            }
            let rect = window.world_rect;
            frames.push((
                (pixel(rect.origin.x.floor())?, pixel(rect.origin.y.floor())?),
                (pixel(rect.right().ceil())?, pixel(rect.bottom().ceil())?),
            ));
        }
        if anchors {
            frames.extend(self.config().nav_anchors.iter().map(|point| {
                let at = (point.x as i32, point.y as i32);
                (at, at)
            }));
        }
        let (mut low, mut high) = ((i32::MAX, i32::MAX), (i32::MIN, i32::MIN));
        let mut windows = Vec::with_capacity(frames.len());
        for ((x, y), (right, bottom)) in frames {
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
    pub(crate) fn arm_view(
        &mut self,
        output: OutputId,
        target: Point,
        zoom: f64,
        anchor: Option<Anchor>,
    ) -> Result<Value, Error> {
        if self.gesture.is_some() || self.native_resize_grab_output().is_some() {
            return Err(Error::Invalid("navigation during active gesture"));
        }
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
        // Upstream set_camera_on: a fullscreen output's camera does not move.
        if self.fullscreen_on(output).is_some() {
            return idle();
        }
        self.next_navigation = self
            .next_navigation
            .checked_add(1)
            .ok_or(Error::Invalid("navigation generations exhausted"))?;
        self.stop_momentum(output);
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
    pub(crate) fn restore_view(
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
        self.user_moved_camera();
        self.overview_returns.remove(&output);
        let step = self.config().pan_step / viewport.zoom;
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
    /// At home means zoom ≈ 1.0 and the world origin visible on the whole output.
    pub(crate) fn at_home(&self, viewport: &Viewport) -> Result<bool, Error> {
        let full = pixel_size(viewport.screen_bounds.size)?;
        Ok((viewport.zoom - 1.0).abs() < 0.01
            && policy::is_origin_visible(viewport.camera, full, viewport.zoom))
    }
    pub(crate) fn home_toggle(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        self.user_moved_camera();
        let center = usable.center();
        if self.at_home(&viewport)? {
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
    pub(crate) fn zoom_to_anchored(
        &mut self,
        output: OutputId,
        viewport: &Viewport,
        center: Point,
        target: f64,
    ) -> Result<Value, Error> {
        self.user_moved_camera();
        self.overview_returns.remove(&output);
        let anchor = Anchor {
            canvas: viewport.camera + center / viewport.zoom,
            screen: center,
        };
        let camera = policy::zoom_anchor_camera(anchor.canvas, center, target);
        self.arm_view(output, camera, target, Some(anchor))
    }
    /// Upstream min_zoom: far enough out to see every window in the usable area.
    pub(crate) fn min_zoom(&self, usable: Rect) -> Result<f64, Error> {
        Ok(policy::dynamic_min_zoom(
            self.pixel_windows(false)?.into_iter(),
            pixel_size(usable.size)?,
            self.config().zoom_fit_padding,
        ))
    }
    pub(crate) fn zoom_in(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let step = self.config().zoom_step;
        // Upstream has no lower bound here. A `zoom.step` below 1 zooms out, and
        // a target under the scene's floor could never land.
        let target = policy::snap_zoom(
            (viewport.zoom * step).clamp(policy::MIN_ZOOM_FLOOR, policy::MAX_ZOOM),
        );
        self.zoom_to_anchored(output, &viewport, usable.center(), target)
    }
    pub(crate) fn zoom_out(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let step = self.config().zoom_step;
        let target = policy::snap_zoom((viewport.zoom / step).max(self.min_zoom(usable)?));
        // Deviation: the direct `zoom` command keeps the static 0.001 floor and
        // moving windows can raise the dynamic minimum, so the pose may already
        // sit below it. Never zoom in from there.
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
        self.user_moved_camera();
        let center = usable.center();
        if let Some(ret) = self.overview_returns.remove(&output) {
            return self.restore_view(output, ret, center);
        }
        let Some(bbox) = policy::all_windows_bbox(self.pixel_windows(true)?.into_iter()) else {
            return idle();
        };
        let padding = self.config().zoom_fit_padding;
        let fit = policy::zoom_to_fit(bbox, pixel_size(usable.size)?, padding);
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
    /// Fly the camera until the usable center shows the Y-up canvas point
    /// `(x, y)`, at the zoom the view is heading to, and disarm a zoom-to-fit
    /// return. Through the anchor, not a bare camera target (v0.20): the anchor
    /// of a flight still under way would steer the camera back every tick, so
    /// `zoom 0.5` then `go-to-bookmark` lands, zoom and all.
    fn go_to_canvas_point(&mut self, output: OutputId, x: f64, y: f64) -> Result<Value, Error> {
        let (_, usable) = self.view(output)?;
        self.user_moved_camera();
        let zoom = self.landing_view(output)?.1;
        let anchor = Anchor {
            canvas: Point::new(x, -y),
            screen: usable.center(),
        };
        Ok(json!({"navigation":self.arm_anchor(output, anchor, zoom)?}))
    }
    /// A missing bookmark is not an error upstream: nothing is armed.
    pub(crate) fn go_to_bookmark(&mut self, output: OutputId, name: &str) -> Result<Value, Error> {
        self.view(output)?;
        match self.bookmarks.get(name) {
            Some(&[x, y]) => self.go_to_canvas_point(output, x, y),
            None => idle(),
        }
    }
    /// Remember the canvas point under the usable center. A pending camera
    /// target is captured instead of a mid-flight frame, so set-bookmark then
    /// go-to-bookmark lands where the flight was heading: the exact inverse of
    /// go_to_canvas_point. Only a camera-only flight keeps that target: an
    /// anchored zoom tick drops it, here as upstream, and the frame is captured.
    pub(crate) fn set_bookmark(&mut self, output: OutputId, name: &str) -> Result<Value, Error> {
        let center = self.navigation_context(output)?.usable_rect_local.center();
        // v0.20: where the flight under way lands, camera and zoom, not the
        // spot it passes through.
        let (camera, zoom) = self.landing_view(output)?;
        let point = [camera.x + center.x / zoom, -(camera.y + center.y / zoom)];
        // Upstream's set-bookmark logs a refusal (an overlong name, a registry
        // at its cap, a view past the camera's range) and changes nothing; this
        // controller has no log to write it to.
        let _ = self.store_bookmark(name.to_owned(), point);
        idle()
    }
    /// Upstream refreshes each output's active bookmark once per rendered
    /// frame; here every accepted command is that frame. Hysteresis favors the
    /// incumbent, so the result depends on the poses the camera passed through.
    pub(crate) fn refresh_active_bookmarks(&mut self) {
        let mut active = BTreeMap::new();
        if !self.bookmarks.is_empty() {
            for viewport in self.scene.outputs() {
                let (Ok(context), Ok(size)) = (
                    self.navigation_context(viewport.id),
                    pixel_size(viewport.screen_bounds.size),
                ) else {
                    continue;
                };
                let incumbent = self.active_bookmarks.get(&viewport.id).map(String::as_str);
                if let Some(name) = policy::active_bookmark(
                    &self.bookmarks,
                    viewport.camera,
                    size,
                    viewport.zoom,
                    context.usable_rect_local.center(),
                    incumbent,
                ) {
                    active.insert(viewport.id, name);
                }
            }
        }
        self.active_bookmarks = active;
    }
}
