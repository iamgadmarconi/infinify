// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm @
// df3de27b26c7998e8a460cffd8a4925cbed3a322 (v0.21.0),
// src/state/{navigation,viewport,viewport_animation}.rs
// (landing_view, landing_view_on, set_camera_anchor, navigation_target_zoom).
// Native frame geometry includes the titlebar; there is no additional compositor border.
// `set_usable_area` follows src/state/viewport.rs (usable_area_on) and what
// src/handlers/layer_shell.rs (layer_destroyed) and src/handlers/compositor.rs
// (handle_layer_commit) do when a panel's exclusive zone changes: the layers
// are arranged again and the output owes a frame, nothing is moved or clamped.
use super::*;
use driftwm_core::config::FocusPlacement as ConfigFocusPlacement;

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
impl From<ConfigFocusPlacement> for FocusPlacement {
    fn from(value: ConfigFocusPlacement) -> Self {
        match value {
            ConfigFocusPlacement::Center => Self::Center,
            ConfigFocusPlacement::Top => Self::Top,
            ConfigFocusPlacement::Bottom => Self::Bottom,
            ConfigFocusPlacement::Left => Self::Left,
            ConfigFocusPlacement::Right => Self::Right,
            ConfigFocusPlacement::TopLeft => Self::TopLeft,
            ConfigFocusPlacement::TopRight => Self::TopRight,
            ConfigFocusPlacement::BottomLeft => Self::BottomLeft,
            ConfigFocusPlacement::BottomRight => Self::BottomRight,
        }
    }
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
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
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
    /// Upstream `snap.outer_gap` as this output measures it.
    pub(crate) fn outer_gap(&self) -> f64 {
        self.outer_gap
    }
    /// Upstream align_point_on for a window's world frame: the output-local
    /// point where a navigation landing at `zoom` parks the frame's center.
    pub(crate) fn align_rect(&self, visual_rect_world: Rect, zoom: f64) -> Point {
        let frame = NavigationFrame {
            visual_rect_world,
            extra_compositor_border: 0.0,
        };
        self.align(&frame, zoom)
    }
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
    /// Upstream align_point_on for a frame that is not on the canvas yet: where
    /// a navigation landing at `zoom` would park a window of `size`.
    pub(crate) fn align_point(&self, size: Size, zoom: f64) -> Point {
        let frame = NavigationFrame {
            visual_rect_world: Rect {
                origin: Point::default(),
                size,
            },
            extra_compositor_border: 0.0,
        };
        self.align(&frame, zoom)
    }
}

/// A usable rectangle is output-local and lies inside its output.
fn usable_fits(usable: Rect, output: Size) -> bool {
    usable.valid()
        && usable.origin.x >= 0.0
        && usable.origin.y >= 0.0
        && usable.right() <= output.width
        && usable.bottom() <= output.height
}

impl Controller {
    /// The output's usable rectangle, and how navigation places and animates.
    /// Once a config is loaded the placement, camera speed and outer gap are
    /// the config's: `focus_placement` (an `[[outputs]]` entry named after the
    /// output's stable id, or `*`, overrides it as upstream's per-output rule
    /// does), `navigation.camera_speed` and `snap.outer_gap`. Before that they
    /// are what `set_navigation_context` supplied.
    pub(crate) fn navigation_context(&self, output: OutputId) -> Result<NavigationContext, Error> {
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        let mut context =
            self.navigation_contexts
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
                });
        if self.configured {
            let config = self.config();
            context.focus_placement = self
                .outputs
                .get(&output)
                .and_then(|saved| config.output_config(&saved.stable_id))
                .and_then(|rule| rule.focus_placement)
                .unwrap_or(config.focus_placement)
                .into();
            context.camera_speed = config.camera_speed;
            context.outer_gap = config.snap_outer_gap.min(1e12);
        }
        Ok(context)
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
        if !usable_fits(usable_rect_local, viewport.screen_bounds.size)
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
    /// Upstream's non_exclusive_zone of one output: what its panels leave,
    /// here what the menu bar and the Dock leave. Only the rectangle is
    /// written. Upstream re-arranges its layer surfaces when a panel's
    /// exclusive zone changes and owes the output a frame, and nothing else:
    /// no camera, window or pin moves, and a flight keeps the anchor it was
    /// armed with. Every reader measures the new rectangle from its next
    /// request on, and the active bookmark as this command ends.
    pub(crate) fn set_usable_area(
        &mut self,
        output: OutputId,
        usable_rect_local: Rect,
    ) -> Result<(), Error> {
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        if !usable_fits(usable_rect_local, viewport.screen_bounds.size) {
            return Err(Error::Invalid("invalid usable area"));
        }
        self.navigation_contexts
            .entry(output)
            .or_insert(NavigationContext {
                usable_rect_local,
                focus_placement: FocusPlacement::Center,
                camera_speed: 0.3,
                outer_gap: 0.0,
            })
            .usable_rect_local = usable_rect_local;
        Ok(())
    }
    /// Where a navigation to `window` on `output` lands: the camera, the zoom
    /// and the anchor the zoom animates around.
    fn navigation_target(
        &self,
        window: WindowId,
        output: OutputId,
        policy: ZoomPolicy,
    ) -> Result<(Point, f64, Anchor), Error> {
        let context = self.navigation_context(output)?;
        // Upstream navigation_target_zoom: the zoom the view is heading to, as
        // the live one would stop a zoom animation where this frame caught it.
        let zoom = match policy {
            ZoomPolicy::Keep => self.landing_view(output)?.1,
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
        if !target.valid() {
            return Err(Error::Invalid("navigation target out of bounds"));
        }
        Ok((target, zoom, anchor))
    }
    /// Whether `output` is already flying where a navigation to `window`
    /// under `policy` would send it: the flight that navigation armed, still
    /// in the air and not retargeted since. The anchor and the zoom say so:
    /// a flight keeps both until it lands, and gives up its camera target at
    /// its first frame.
    pub(crate) fn flying_to(&self, window: WindowId, output: OutputId, policy: ZoomPolicy) -> bool {
        let Ok((_, zoom, anchor)) = self.navigation_target(window, output, policy) else {
            return false;
        };
        self.flights.get(&output).is_some_and(|flight| {
            flight.zoom_target == Some(zoom) && flight.zoom_animation_anchor == Some(anchor)
        })
    }
    /// Upstream landing_view_on: `output`'s camera and zoom once its flight
    /// lands, the live view when nothing is in the air. Momentum is no flight:
    /// it has no destination. The zoom tick steers by the anchor and clears the
    /// camera target, so while an anchor is armed it alone says where the camera
    /// lands.
    pub(crate) fn landing_view(&self, output: OutputId) -> Result<(Point, f64), Error> {
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        let flight = self.flights.get(&output);
        let zoom = flight
            .and_then(|flight| flight.zoom_target)
            .unwrap_or(viewport.zoom);
        let camera = match flight.and_then(|flight| flight.zoom_animation_anchor) {
            Some(anchor) => anchor.canvas - anchor.screen / zoom,
            None => flight
                .and_then(|flight| flight.camera_target)
                .unwrap_or(viewport.camera),
        };
        Ok((camera, zoom))
    }
    pub(crate) fn arm_navigation(
        &mut self,
        window: WindowId,
        output: OutputId,
        policy: ZoomPolicy,
    ) -> Result<Value, Error> {
        if self.gesture.is_some() || self.native_resize_grab_output().is_some() {
            return Err(Error::Invalid("navigation during active gesture"));
        }
        let (_, zoom, anchor) = self.navigation_target(window, output, policy)?;
        self.arm_anchor(output, anchor, zoom)
    }
    /// Upstream set_camera_anchor: fly `output` until `anchor.canvas` sits at
    /// `anchor.screen` at `zoom`. The zoom tick lands the camera at
    /// `anchor.canvas - anchor.screen / zoom`, so the anchor is what arrives.
    pub(crate) fn arm_anchor(
        &mut self,
        output: OutputId,
        anchor: Anchor,
        zoom: f64,
    ) -> Result<Value, Error> {
        if self.gesture.is_some() || self.native_resize_grab_output().is_some() {
            return Err(Error::Invalid("navigation during active gesture"));
        }
        let target = anchor.canvas - anchor.screen / zoom;
        if !target.valid() {
            return Err(Error::Invalid("navigation target out of bounds"));
        }
        // Upstream set_camera_on: a fullscreen output's camera does not move.
        if self.fullscreen_on(output).is_some() {
            return Ok(Value::Null);
        }
        self.next_navigation = self
            .next_navigation
            .checked_add(1)
            .ok_or(Error::Invalid("navigation generations exhausted"))?;
        // Upstream set_camera_anchor: window navigation disarms a zoom-to-fit
        // return and stops scroll momentum.
        self.overview_returns.remove(&output);
        self.stop_momentum(output);
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
    pub(crate) fn navigation_clock_only(&self) -> bool {
        // Successful mutations and public load already settle the controller.
        // Without motion or pending timed/structural work, a tick changes only
        // navigation.clock_ns and needs no transaction or settlement. Keep
        // this conservative: a zero-displacement first flight or delayed edge
        // pan is not idle. The shell uses the same proof for visual reuse.
        self.flights.is_empty()
            && self.motion.clock_idle()
            && self.gesture.is_none()
            && self.trackpad_gesture.is_none()
            && self.focus.hover.is_empty()
            && self.resize_slot().is_none_or(|slot| !slot.live)
            && self.sizes.observation_idle()
            && self.fullscreen_observation_idle()
            && self.lifecycle.marks.is_empty()
            && self.lifecycle.relaunching.is_empty()
    }
    fn navigation_elapsed(&self, timestamp_ns: u64) -> Result<u64, Error> {
        match self.navigation_clock {
            Some(previous) => timestamp_ns
                .checked_sub(previous)
                .ok_or(Error::Invalid("navigation clock decreased")),
            None => Ok(0),
        }
    }
    /// Called only after `navigation_clock_only` proved there is no other work.
    pub(crate) fn tick_navigation_clock(&mut self, timestamp_ns: u64) -> Result<Value, Error> {
        self.navigation_elapsed(timestamp_ns)?;
        self.navigation_clock = Some(timestamp_ns);
        Ok(
            json!({"changed_outputs":[],"needs_frames":false,"needs_pointer":false,"clock_only":true}),
        )
    }
    pub(crate) fn tick_navigation(&mut self, timestamp_ns: u64) -> Result<Value, Error> {
        let elapsed = self.navigation_elapsed(timestamp_ns)?;
        let clock_only = self.navigation_clock_only();
        self.navigation_clock = Some(timestamp_ns);
        let dt = std::time::Duration::from_nanos(elapsed.min(33_000_000));
        // Upstream tick_all_animations: the cursor's edge pan is armed again
        // from where the pointer is, then every output runs scroll momentum,
        // edge pan, zoom and camera, in that order.
        self.refresh_cursor_edge_pan();
        let mut outputs: Vec<OutputId> = self.scene.outputs().iter().map(|o| o.id).collect();
        outputs.sort();
        let mut changed = Vec::new();
        for output in outputs {
            let pose = |scene: &Scene| scene.output(output).map(|o| (o.camera, o.zoom));
            let before = pose(&self.scene);
            self.tick_momentum(output, dt)?;
            self.tick_edge_pan(output, timestamp_ns)?;
            self.tick_flight(output, dt.as_secs_f64())?;
            if pose(&self.scene) != before {
                changed.push(output);
            }
        }
        Ok(
            json!({"changed_outputs":changed,"needs_frames":self.needs_frames(),"needs_pointer":self.motion.cursor_pan,"clock_only":clock_only}),
        )
    }
    /// One frame of the output's flight, if it has one.
    fn tick_flight(&mut self, output: OutputId, dt: f64) -> Result<(), Error> {
        if !self.flights.contains_key(&output) {
            return Ok(());
        }
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
        if flight.camera_target.is_none() && flight.zoom_target.is_none() {
            self.flights.remove(&output);
        }
        self.scene.update_output(viewport)?;
        self.sync_output(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(controller: &mut Controller, command: Value) -> Value {
        controller
            .execute(serde_json::from_value(json!({"version":1,"command":command})).unwrap())
            .unwrap()
    }
    fn idle_controller() -> Controller {
        let mut controller = Controller::new();
        for (name, x) in [("one", 0.0), ("two", 1000.0)] {
            command(
                &mut controller,
                json!({"op":"register_output","stable_id":name,"screen_bounds":Rect::new(x,0.0,1000.0,800.0)}),
            );
        }
        for wid in 1..=6 {
            let frame = Rect::new(40.0 * wid as f64, 80.0, 300.0, 200.0);
            command(
                &mut controller,
                json!({"op":"attach","identity":{"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid},"bundle_id":"test","title":"fixture","buffer":{"width":600,"height":400},"source_rect":frame,"world_rect":frame}),
            );
        }
        command(
            &mut controller,
            json!({"op":"native_resize_capability","enabled":true}),
        );
        controller
    }
    fn compare_transaction(controller: &mut Controller, timestamp_ns: u64) -> Value {
        // Retain the full reducer and settlement as an independent reference
        // for the execute shortcut, including state omitted by Snapshot.
        let mut reference = controller.clone();
        let expected = reference
            .apply(Command::TickNavigation { timestamp_ns })
            .unwrap();
        reference.settle_state().unwrap();
        let actual = controller
            .execute(Request {
                version: ABI_VERSION,
                command: Command::TickNavigation { timestamp_ns },
            })
            .unwrap();
        assert_eq!(actual, expected);
        assert_eq!(format!("{controller:?}"), format!("{reference:?}"));
        actual
    }
    #[test]
    fn clock_only_matches_full_transaction_with_pins_bookmarks_and_stopped_momentum() {
        let mut controller = idle_controller();
        command(
            &mut controller,
            json!({"op":"ipc","output":1,"request":{"Pin":{"window":1,"value":true}}}),
        );
        command(
            &mut controller,
            json!({"op":"action","output":1,"action":"set-bookmark desk"}),
        );
        command(
            &mut controller,
            json!({"op":"pan","output":2,"screen_delta":{"x":10,"y":0},"time_ms":100,"source":"finger"}),
        );
        command(
            &mut controller,
            json!({"op":"cancel_navigation","output":2}),
        );
        for timestamp in [0, 80_000_000, 80_000_000, u64::MAX] {
            assert_eq!(
                compare_transaction(&mut controller, timestamp)["clock_only"],
                true
            );
        }
    }
    #[test]
    fn clock_only_matches_full_transaction_after_loading_detached_pinned_state() {
        let mut controller = idle_controller();
        command(
            &mut controller,
            json!({"op":"ipc","output":1,"request":{"Pin":{"window":1,"value":true}}}),
        );
        let path = std::env::temp_dir().join(format!(
            "infinify-clock-only-load-{}.json",
            std::process::id()
        ));
        controller.save(&path).unwrap();
        let loaded = Controller::load(&path);
        std::fs::remove_file(path).unwrap();
        let mut loaded = loaded.unwrap();
        command(
            &mut loaded,
            json!({"op":"native_resize_capability","enabled":true}),
        );
        for timestamp in [0, 80_000_000, 20_000_000_000] {
            assert_eq!(
                compare_transaction(&mut loaded, timestamp)["clock_only"],
                true
            );
        }
    }
    fn finish_fullscreen_resize(controller: &mut Controller, reply: Value, took: Size) {
        let mut effect = reply["effect"].clone();
        let before = controller.sources[&WindowId(1)].observed_rect.size;
        for (outcome, attempted, size) in [
            ("observed", false, before),
            ("applied", true, took),
            ("observed", false, took),
        ] {
            let actual = Rect {
                origin: Point::new(4000.0, 3000.0),
                size,
            };
            let requested = if effect["requested"].is_null() {
                json!({"width":0.0,"height":0.0})
            } else {
                effect["requested"].clone()
            };
            effect = command(
                controller,
                json!({"op":"native_resize_result","transaction":effect["transaction"],
                    "effect_id":effect["effect_id"],"identity":effect["identity"],
                    "generation":effect["generation"],"result":{"outcome":outcome,
                    "ax_error":0,"mutation_attempted":attempted,"observed":true,
                    "requested":requested,"actual_ax":actual,"actual_cg":actual}}),
            )["effect"]
                .clone();
        }
        assert!(effect.is_null());
    }
    fn settled_fullscreen_controller(took: Size, pinned: bool) -> Controller {
        let mut controller = idle_controller();
        command(
            &mut controller,
            json!({"op":"zoom","output":1,"zoom":0.75,"anchor":{"x":31.5,"y":47.25}}),
        );
        if pinned {
            command(
                &mut controller,
                json!({"op":"ipc","output":1,"request":{"Pin":{"window":1,"value":true}}}),
            );
        }
        command(&mut controller, json!({"op":"focus","window":1}));
        let reply = command(
            &mut controller,
            json!({"op":"action","output":1,"action":"toggle-fullscreen"}),
        );
        assert!(!controller.navigation_clock_only());
        finish_fullscreen_resize(&mut controller, reply, took);
        controller
    }
    #[test]
    fn settled_fullscreen_ticks_and_observations_match_full_transactions() {
        for took in [Size::new(1000.0, 800.0), Size::new(750.0, 500.0)] {
            for pinned in [false, true] {
                let mut controller = settled_fullscreen_controller(took, pinned);
                for timestamp in [0, 80_000_000, 20_000_000_000] {
                    assert_eq!(
                        compare_transaction(&mut controller, timestamp)["clock_only"],
                        true
                    );
                }
                for (&window, source) in &controller.sources {
                    let mut reference = controller.clone();
                    reference
                        .apply(Command::Observe {
                            window,
                            identity: source.identity.clone(),
                            source_rect: source.observed_rect,
                            buffer: source.buffer,
                        })
                        .unwrap();
                    reference.settle_state().unwrap();
                    assert_eq!(format!("{reference:?}"), format!("{controller:?}"));
                    assert!(controller.observation_current(
                        window,
                        &source.identity,
                        source.observed_rect,
                        source.buffer,
                    ));
                    let mut stale = source.identity.clone();
                    stale.birth_sec += 1;
                    assert!(!controller.observation_current(
                        window,
                        &stale,
                        source.observed_rect,
                        source.buffer,
                    ));
                }
                command(
                    &mut controller,
                    json!({"op":"action","output":1,"action":"toggle-fullscreen"}),
                );
                assert_eq!(
                    compare_transaction(&mut controller, 21_000_000_000)["clock_only"],
                    false
                );
                let source = &controller.sources[&WindowId(1)];
                assert!(!controller.observation_current(
                    WindowId(1),
                    &source.identity,
                    source.observed_rect,
                    source.buffer,
                ));
            }
        }
    }
    #[test]
    fn settled_fullscreen_pending_output_resize_and_other_output_motion_do_not_skip_work() {
        let settled = settled_fullscreen_controller(Size::new(1000.0, 800.0), true);
        for pending in [
            json!({"op":"set_usable_area","output":1,"usable_rect_local":Rect::new(0.0,30.0,900.0,700.0)}),
            json!({"op":"navigate_window","window":2,"output":2,"zoom_policy":"keep"}),
            json!({"op":"begin_drag","window":2,"output":2}),
        ] {
            let mut controller = settled.clone();
            command(&mut controller, pending.clone());
            assert_eq!(
                compare_transaction(&mut controller, 80_000_000)["clock_only"],
                false,
                "{pending}"
            );
        }
    }
    #[test]
    fn pending_navigation_resize_and_lifecycle_keep_full_transactions() {
        for pending in [
            json!({"op":"native_resize_capability","enabled":false}),
            json!({"op":"navigate_window","window":1,"output":1,"zoom_policy":"keep"}),
            json!({"op":"pan","output":1,"screen_delta":{"x":10,"y":0},"time_ms":100,"source":"finger"}),
            json!({"op":"action","output":1,"action":"toggle-cursor-pan"}),
            json!({"op":"begin_drag","window":1,"output":1}),
            json!({"op":"begin_native_resize","window":1,"output":1,"edges":"right","start_screen":{"x":340,"y":180}}),
            json!({"op":"action","output":1,"action":"toggle-fullscreen"}),
            json!({"op":"action","output":1,"action":"close-window"}),
        ] {
            let mut controller = idle_controller();
            command(&mut controller, json!({"op":"focus","window":1}));
            command(&mut controller, pending.clone());
            for timestamp in [0, 16_666_667, 10_000_000_000] {
                assert_eq!(
                    compare_transaction(&mut controller, timestamp)["clock_only"],
                    false,
                    "{pending}"
                );
            }
        }
    }
    #[test]
    fn clock_only_rejects_schema_and_backward_time_before_writing() {
        let mut controller = idle_controller();
        compare_transaction(&mut controller, 80_000_000);
        let before = format!("{controller:?}");
        for (version, timestamp_ns, message) in [
            (ABI_VERSION, 79_999_999, "navigation clock decreased"),
            (ABI_VERSION + 1, 160_000_000, "unsupported desktop schema"),
            (ABI_VERSION + 1, 0, "unsupported desktop schema"),
        ] {
            let error = controller
                .execute(Request {
                    version,
                    command: Command::TickNavigation { timestamp_ns },
                })
                .unwrap_err();
            assert_eq!(error.to_string(), message);
            assert_eq!(format!("{controller:?}"), before);
        }
    }
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
