// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/ipc/protocol.rs (every wire type: names, serde shapes and field order),
// src/ipc/mod.rs (dispatch, cmd_camera, cmd_zoom, state_info, the selector
// rules, cmd_focus, cmd_action, cmd_bookmark, cmd_move, cmd_resize,
// camera_center), src/canvas.rs (internal_to_rule, rule_to_internal) and
// src/state/navigation.rs (window_fully_in_viewport). The transport lives in
// the shell. Native frames already include their title bar, so chrome is zero.
use super::actions::Outcome;
use super::view_actions::pixel_size;
use super::*;
use driftwm_canvas::policy;

/// Selects a window: by stable id (JSON number) or case-insensitive `app_id`
/// substring (JSON string). Untagged, so the wire form is just `5` or `"term"`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub(crate) enum WindowSelector {
    Id(u64),
    AppId(String),
}

/// A command from a client. Variants carrying `Option<_>` read when `None` and
/// write when `Some`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) enum Request {
    /// Coordinates are the viewport center, Y-up.
    Camera(Option<(f64, f64)>),
    /// Set value is clamped to the supported range (out to fit-all, in to native).
    Zoom(Option<f64>),
    Layout {
        short: bool,
    },
    State,
    DebugCounters,
    Subscribe,
    Focus(Option<WindowSelector>),
    /// `window` `None` targets the focused window; `to` `None` reads. Coordinates
    /// are the visible-frame center, Y-up.
    Move {
        #[serde(default)]
        window: Option<WindowSelector>,
        #[serde(default)]
        to: Option<(i32, i32)>,
    },
    Resize {
        #[serde(default)]
        window: Option<WindowSelector>,
        #[serde(default)]
        to: Option<(i32, i32)>,
    },
    Opacity {
        #[serde(default)]
        window: Option<WindowSelector>,
        #[serde(default)]
        value: Option<f64>,
    },
    Pin {
        #[serde(default)]
        window: Option<WindowSelector>,
        #[serde(default)]
        value: Option<bool>,
    },
    Close(Option<WindowSelector>),
    Suspend(Option<WindowSelector>),
    Relaunch(Option<WindowSelector>),
    /// A config action by its config-grammar string.
    Action(String),
    /// No `name` and no `delete` lists; `name` alone gets; `name` and `to` set;
    /// `delete` and `name` remove. Never touches zoom.
    Bookmark {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        to: Option<(f64, f64)>,
        #[serde(default)]
        delete: bool,
    },
    Screenshot {
        target: ScreenshotTarget,
        scale: f64,
        path: String,
    },
}

/// What a [`Request::Screenshot`] captures.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) enum ScreenshotTarget {
    Viewport,
    Window {
        #[serde(default)]
        window: Option<WindowSelector>,
    },
    All,
    Region {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        from_screen: bool,
    },
}

/// A successful reply payload. Pairs with [`Request`] variants.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) enum Response {
    Camera {
        x: f64,
        y: f64,
    },
    Zoom(f64),
    Layout(String),
    State(Box<StateInfo>),
    DebugCounters(BTreeMap<String, usize>),
    Focused(Option<FocusedWindow>),
    /// Visible-frame center, Y-up coordinates.
    Position {
        x: i32,
        y: i32,
    },
    Size {
        width: i32,
        height: i32,
    },
    Opacity(f64),
    Pin(bool),
    Screenshot {
        path: String,
        width: u32,
        height: u32,
    },
    /// Every bookmark, name → [x, y] (Y-up), sorted by name.
    Bookmarks(BTreeMap<String, [f64; 2]>),
    /// One bookmark's canvas point (Y-up), echoed on get and set.
    Bookmark {
        x: f64,
        y: f64,
    },
    Ok,
}

/// The result of a request: `Ok(Response)` or a human-readable error string.
pub(crate) type Reply = Result<Response, String>;

/// The focused window in a [`Response::Focused`] reply.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct FocusedWindow {
    pub id: u64,
    pub app_id: Option<String>,
}

/// The full state snapshot: the payload of a [`Response::State`] reply and of a
/// subscription [`Event::State`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct StateInfo {
    pub camera: (f64, f64),
    pub zoom: f64,
    #[serde(default)]
    pub layout: String,
    #[serde(default)]
    pub layout_short: String,
    pub windows: Vec<WindowInfo>,
    #[serde(default)]
    pub fullscreen: Vec<OutputFullscreen>,
    #[serde(default)]
    pub pinned: Vec<OutputPinned>,
    #[serde(default)]
    pub layers: Vec<String>,
    #[serde(default)]
    pub canvas_layers: Vec<CanvasLayerInfo>,
    /// Per-output camera state. `camera` is the viewport center, Y-up.
    #[serde(default)]
    pub outputs: Vec<OutputInfo>,
    /// The active output's active bookmark, or `None` when none is in view.
    #[serde(default)]
    pub active_bookmark: Option<String>,
}

/// One output's viewport in the `state` reply.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct OutputInfo {
    pub name: String,
    pub camera: (f64, f64),
    pub zoom: f64,
    pub size: [i32; 2],
    pub active: bool,
    #[serde(default)]
    pub active_bookmark: Option<String>,
}

/// A line pushed to a subscribed connection. Not wrapped in a `Reply`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) enum Event {
    State(StateInfo),
}

/// Which size mode a canvas window is in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub(crate) enum WindowMode {
    #[default]
    Normal,
    Fit,
    Fill,
}

/// One window in the canvas inventory. `position` is the visible frame's
/// center, Y-up; `size` is that frame.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct WindowInfo {
    pub id: u64,
    pub app_id: String,
    pub title: String,
    pub position: [i32; 2],
    pub size: [i32; 2],
    pub is_focused: bool,
    pub is_widget: bool,
    #[serde(default)]
    pub suspended: bool,
    #[serde(default)]
    pub mode: WindowMode,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct OutputFullscreen {
    pub id: u64,
    pub output: String,
    pub app_id: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct OutputPinned {
    pub id: u64,
    pub output: String,
    pub app_id: String,
    pub title: String,
    pub position: [i32; 2],
    pub size: [i32; 2],
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct CanvasLayerInfo {
    pub app_id: String,
    pub position: [i32; 2],
    pub size: [i32; 2],
}

/// A world frame at upstream's integer boundary: top-left and size, each
/// rounded to the nearest logical pixel. Out-of-range geometry is refused.
fn frame(rect: Rect) -> Result<([i64; 2], [i64; 2]), String> {
    let round = |value: f64| {
        let value = value.round();
        if (f64::from(i32::MIN)..=f64::from(i32::MAX)).contains(&value) {
            Ok(value as i64)
        } else {
            Err("window geometry exceeds integer range".to_string())
        }
    };
    Ok((
        [round(rect.origin.x)?, round(rect.origin.y)?],
        [round(rect.size.width)?, round(rect.size.height)?],
    ))
}
/// Upstream internal_to_rule: the frame's center, Y-up, with its truncating
/// integer halving.
fn internal_to_rule(loc: [i64; 2], size: [i64; 2]) -> Result<[i32; 2], String> {
    let narrow = |value: i64| {
        i32::try_from(value).map_err(|_| "window geometry exceeds integer range".to_string())
    };
    Ok([
        narrow(loc[0] + size[0] / 2)?,
        narrow(-(loc[1] + size[1] / 2))?,
    ])
}
/// Upstream rule_to_internal, the inverse: the top-left that centers a frame of
/// `size` on the Y-up point `(x, y)`.
fn rule_to_internal(x: i32, y: i32, size: [i64; 2]) -> Point {
    Point::new(
        (i64::from(x) - size[0] / 2) as f64,
        (-i64::from(y) - size[1] / 2) as f64,
    )
}
fn not_implemented(name: &str) -> Reply {
    Err(format!("{name} is not implemented on macOS yet"))
}
fn text(error: Error) -> String {
    error.to_string()
}

impl Controller {
    /// Answer one upstream request. A request that does not decode or is
    /// refused becomes `{"Err":…}` in `reply` and leaves every bit of
    /// controller state as it was; it is never a controller-level error.
    pub(crate) fn ipc(&mut self, output: Option<OutputId>, request: Value) -> Value {
        let mut next = self.clone();
        let mut outcome = Outcome::default();
        let reply: Reply = serde_json::from_value::<Request>(request)
            .map_err(|e| format!("invalid request: {e}"))
            .and_then(|request| next.dispatch(output, request, &mut outcome))
            .and_then(|response| {
                next.scene
                    .validate()
                    .map(|()| response)
                    .map_err(|e| e.to_string())
            });
        if reply.is_ok() {
            *self = next;
        } else {
            outcome = Outcome::default();
        }
        json!({"reply":reply,"effects":outcome.effects,"dirty":outcome.dirty,"navigation":outcome.navigation})
    }
    fn dispatch(
        &mut self,
        output: Option<OutputId>,
        request: Request,
        outcome: &mut Outcome,
    ) -> Reply {
        let active = || output.ok_or_else(|| "no active output".to_string());
        match request {
            Request::Camera(arg) => self.cmd_camera(active()?, arg, outcome),
            Request::Zoom(arg) => self.cmd_zoom(active()?, arg, outcome),
            Request::State => Ok(Response::State(Box::new(self.state_info(output)?))),
            Request::DebugCounters => Ok(Response::DebugCounters(self.debug_counters())),
            Request::Focus(None) => Ok(Response::Focused(
                self.scene.focused().map(|id| self.focused_info(id)),
            )),
            Request::Focus(Some(selector)) => self.cmd_focus(active()?, &selector, outcome),
            Request::Move { window, to } => self.cmd_move(window.as_ref(), to, outcome),
            Request::Resize { window, to } => self.cmd_resize(window.as_ref(), to),
            Request::Action(spec) => {
                *outcome = self.run_action(output, &spec).map_err(text)?;
                Ok(Response::Ok)
            }
            Request::Bookmark { name, to, delete } => self.cmd_bookmark(name, to, delete, outcome),
            Request::Layout { .. } => not_implemented("layout"),
            Request::Opacity { .. } => not_implemented("opacity"),
            Request::Pin { .. } => not_implemented("pin"),
            Request::Close(_) => not_implemented("close"),
            Request::Suspend(_) => not_implemented("suspend"),
            Request::Relaunch(_) => not_implemented("relaunch"),
            Request::Screenshot { .. } => not_implemented("screenshot"),
            Request::Subscribe => not_implemented("subscribe"),
        }
    }
    /// The viewport center, Y-up, over the whole output: upstream camera_center.
    fn camera_center(viewport: &Viewport) -> Result<(f64, f64), String> {
        let size = pixel_size(viewport.screen_bounds.size).map_err(text)?;
        Ok(policy::viewport_center(
            viewport.camera,
            viewport.zoom,
            size,
        ))
    }
    fn viewport(&self, output: OutputId) -> Result<&Viewport, String> {
        self.scene
            .output(output)
            .ok_or_else(|| "unknown output".to_string())
    }
    fn cmd_camera(
        &mut self,
        output: OutputId,
        arg: Option<(f64, f64)>,
        outcome: &mut Outcome,
    ) -> Reply {
        let Some((x, y)) = arg else {
            let (x, y) = Self::camera_center(self.viewport(output)?)?;
            return Ok(Response::Camera { x, y });
        };
        if !x.is_finite() || !y.is_finite() {
            return Err("camera coordinates must be finite numbers".to_string());
        }
        // The target derives from the current zoom, and only the camera target
        // is written: a pending zoom flight and a zoom-to-fit return survive.
        let (viewport, _) = self.view(output).map_err(text)?;
        let size = pixel_size(viewport.screen_bounds.size).map_err(text)?;
        let target = policy::camera_for_center(x, y, viewport.zoom, size);
        outcome.navigation =
            self.set_camera_target(output, target).map_err(text)?["navigation"].take();
        Ok(Response::Camera { x, y })
    }
    fn cmd_zoom(&mut self, output: OutputId, arg: Option<f64>, outcome: &mut Outcome) -> Reply {
        let Some(zoom) = arg else {
            return Ok(Response::Zoom(self.viewport(output)?.zoom));
        };
        if !zoom.is_finite() || zoom <= 0.0 {
            return Err("zoom must be a positive number".to_string());
        }
        // Same bounds and usable-center anchor as keyboard zoom; the reply
        // reports what was applied.
        let (viewport, usable) = self.view(output).map_err(text)?;
        let clamped = zoom.clamp(self.min_zoom(usable).map_err(text)?, policy::MAX_ZOOM);
        outcome.navigation = self
            .zoom_to_anchored(output, &viewport, usable.center(), clamped)
            .map_err(text)?["navigation"]
            .take();
        Ok(Response::Zoom(clamped))
    }
    /// Sizes of the controller's own collections, keyed by field name. Unstable.
    fn debug_counters(&self) -> BTreeMap<String, usize> {
        [
            ("active_bookmarks", self.active_bookmarks.len()),
            ("bookmarks", self.bookmarks.len()),
            ("flights", self.flights.len()),
            ("home_returns", self.home_returns.len()),
            ("metadata", self.metadata.len()),
            ("navigation_contexts", self.navigation_contexts.len()),
            ("outputs", self.scene.outputs().len()),
            ("overview_returns", self.overview_returns.len()),
            (
                "retired_resize_identities",
                self.retired_resize_identities.len(),
            ),
            ("saved_outputs", self.outputs.len()),
            ("sources", self.sources.len()),
            ("windows", self.scene.windows().len()),
        ]
        .into_iter()
        .map(|(key, value)| (key.to_string(), value))
        .collect()
    }
    /// With no active output the top-level camera and zoom have nothing to
    /// describe: they read as the origin at zoom 1 and no output is active.
    fn state_info(&self, output: Option<OutputId>) -> Result<StateInfo, String> {
        let (camera, zoom) = match output {
            Some(id) => {
                let viewport = self.viewport(id)?;
                (Self::camera_center(viewport)?, viewport.zoom)
            }
            None => ((0.0, 0.0), 1.0),
        };
        let focused = self.scene.focused();
        let mut windows = Vec::with_capacity(self.scene.windows().len());
        for window in self.scene.windows() {
            let metadata = self.metadata.get(&window.id);
            let (loc, size) = frame(window.world_rect)?;
            let info = WindowInfo {
                id: window.id.0,
                app_id: metadata.map(|m| m.bundle_id.clone()).unwrap_or_default(),
                title: metadata.map(|m| m.title.clone()).unwrap_or_default(),
                position: internal_to_rule(loc, size)?,
                size: [size[0] as i32, size[1] as i32],
                is_focused: focused == Some(window.id),
                is_widget: false,
                // A detached placeholder is Infinify's stand-in.
                suspended: !self.sources.contains_key(&window.id),
                mode: WindowMode::Normal,
            };
            // Focused window first, the rest in stage order.
            if info.is_focused {
                windows.insert(0, info);
            } else {
                windows.push(info);
            }
        }
        let mut outputs = Vec::with_capacity(self.scene.outputs().len());
        for viewport in self.scene.outputs() {
            let size = pixel_size(viewport.screen_bounds.size).map_err(text)?;
            outputs.push(OutputInfo {
                name: self
                    .outputs
                    .get(&viewport.id)
                    .map(|o| o.stable_id.clone())
                    .unwrap_or_default(),
                camera: Self::camera_center(viewport)?,
                zoom: viewport.zoom,
                size: [size.w, size.h],
                active: output == Some(viewport.id),
                active_bookmark: self.active_bookmarks.get(&viewport.id).cloned(),
            });
        }
        Ok(StateInfo {
            camera,
            zoom,
            layout: String::new(),
            layout_short: String::new(),
            windows,
            fullscreen: Vec::new(),
            pinned: Vec::new(),
            layers: Vec::new(),
            canvas_layers: Vec::new(),
            outputs,
            active_bookmark: output.and_then(|id| self.active_bookmarks.get(&id).cloned()),
        })
    }
    /// `None` is the focused window. An id is exact. An app id is a
    /// case-insensitive bundle-id substring, and a window with a bound source
    /// wins over a detached placeholder: upstream's live client over stand-in.
    fn select(&self, selector: Option<&WindowSelector>) -> Result<WindowId, String> {
        match selector {
            None => self
                .scene
                .focused()
                .ok_or_else(|| "no focused window".to_string()),
            Some(WindowSelector::Id(n)) => self
                .scene
                .window(WindowId(*n))
                .map(|w| w.id)
                .ok_or_else(|| format!("no window with id {n}")),
            Some(WindowSelector::AppId(s)) => {
                let needle = s.to_lowercase();
                let matching = |live: bool| {
                    self.scene.windows().iter().map(|w| w.id).find(|id| {
                        self.sources.contains_key(id) == live
                            && self
                                .metadata
                                .get(id)
                                .is_some_and(|m| m.bundle_id.to_lowercase().contains(&needle))
                    })
                };
                matching(true)
                    .or_else(|| matching(false))
                    .ok_or_else(|| format!("no window matching '{needle}'"))
            }
        }
    }
    fn focused_info(&self, id: WindowId) -> FocusedWindow {
        FocusedWindow {
            id: id.0,
            app_id: self.metadata.get(&id).map(|m| m.bundle_id.clone()),
        }
    }
    /// Is the whole frame inside the output's usable area at its current pose?
    fn fully_in_viewport(&self, window: WindowId, output: OutputId) -> Result<bool, String> {
        let viewport = self.viewport(output)?;
        let usable = self
            .navigation_context(output)
            .map_err(text)?
            .usable_rect_local;
        let rect = self
            .scene
            .window(window)
            .ok_or_else(|| "unknown window".to_string())?
            .world_rect;
        let low = (rect.origin - viewport.camera) * viewport.zoom;
        let high = (Point::new(rect.right(), rect.bottom()) - viewport.camera) * viewport.zoom;
        Ok(low.x >= usable.origin.x
            && low.y >= usable.origin.y
            && high.x <= usable.right()
            && high.y <= usable.bottom())
    }
    /// Logical focus plus upstream's camera rule: a window already fully on
    /// screen is only raised and focused; a window with a bound source is
    /// navigated to at zoom 1 (upstream's default `zoom.reset_on_activation`);
    /// a detached placeholder is panned to at the current zoom (upstream's
    /// `reveal_suspended`). The native focus effect is a request to the shell,
    /// never a claim that native focus changed.
    fn cmd_focus(
        &mut self,
        output: OutputId,
        selector: &WindowSelector,
        outcome: &mut Outcome,
    ) -> Reply {
        let window = self.select(Some(selector))?;
        let info = self.focused_info(window);
        if !self.fully_in_viewport(window, output)? {
            let policy = if self.sources.contains_key(&window) {
                ZoomPolicy::Reset
            } else {
                ZoomPolicy::Keep
            };
            outcome.navigation = self.arm_navigation(window, output, policy).map_err(text)?;
        }
        self.finish_cycle();
        self.scene.focus(window).map_err(|e| e.to_string())?;
        let effect = self.request_focus(window).map_err(text)?["effect"].take();
        if !effect.is_null() {
            outcome.effects.push(effect);
        }
        // Focus and stacking order are saved with the scene.
        outcome.dirty = true;
        Ok(Response::Focused(Some(info)))
    }
    /// List / get / set / delete bookmarks: a flat name → [x, y] (Y-up) map.
    /// Never touches zoom or the camera.
    fn cmd_bookmark(
        &mut self,
        name: Option<String>,
        to: Option<(f64, f64)>,
        delete: bool,
        outcome: &mut Outcome,
    ) -> Reply {
        if delete {
            let name = name.ok_or_else(|| "bookmark delete requires a name".to_string())?;
            if to.is_some() {
                return Err("bookmark delete does not take coordinates".to_string());
            }
            if self.bookmarks.remove(&name).is_none() {
                return Err(format!("no bookmark named '{name}'"));
            }
            outcome.dirty = true;
            return Ok(Response::Ok);
        }
        match (name, to) {
            (None, None) => Ok(Response::Bookmarks(self.bookmarks.clone())),
            (None, Some(_)) => Err("bookmark coordinates require a name".to_string()),
            (Some(name), None) => {
                let &[x, y] = self
                    .bookmarks
                    .get(&name)
                    .ok_or_else(|| format!("no bookmark named '{name}'"))?;
                Ok(Response::Bookmark { x, y })
            }
            (Some(name), Some((x, y))) => {
                if !x.is_finite() || !y.is_finite() {
                    return Err("bookmark coordinates must be finite".to_string());
                }
                self.bookmarks.insert(name, [x, y]);
                outcome.dirty = true;
                Ok(Response::Bookmark { x, y })
            }
        }
    }
    /// A logical world move: the frame's top-left lands on whole pixels and its
    /// size is kept. Stacking is untouched, unlike upstream's raising map. A
    /// destination outside the `i32` range is refused, as an unreadable frame is.
    fn cmd_move(
        &mut self,
        selector: Option<&WindowSelector>,
        to: Option<(i32, i32)>,
        outcome: &mut Outcome,
    ) -> Reply {
        let window = self.select(selector)?;
        let rect = self
            .scene
            .window(window)
            .ok_or_else(|| "unknown window".to_string())?
            .world_rect;
        let (loc, size) = frame(rect)?;
        let Some((x, y)) = to else {
            let [x, y] = internal_to_rule(loc, size)?;
            return Ok(Response::Position { x, y });
        };
        // A live gesture recomputes rectangles from its own start anchors on
        // every motion, so anything written mid-drag would be erased or fought.
        if self.gesture.is_some() {
            return Err("a window is under an interactive move or resize".to_string());
        }
        self.guard_resize_structure(Some(window)).map_err(text)?;
        let moved = Rect {
            origin: rule_to_internal(x, y, size),
            size: rect.size,
        };
        // Refuse a destination no later request could read: the top-left must
        // round into i32 (State, Move, Resize) and so must the far edge (the
        // enclosing integer rectangle the fit and zoom policy takes).
        frame(moved)?;
        if moved.right().ceil() > f64::from(i32::MAX) || moved.bottom().ceil() > f64::from(i32::MAX)
        {
            return Err("window geometry exceeds integer range".to_string());
        }
        self.scene
            .set_window_rect(window, moved)
            .map_err(|e| e.to_string())?;
        outcome.dirty = true;
        Ok(Response::Position { x, y })
    }
    fn cmd_resize(&self, selector: Option<&WindowSelector>, to: Option<(i32, i32)>) -> Reply {
        let window = self.select(selector)?;
        let Some((width, height)) = to else {
            let rect = self
                .scene
                .window(window)
                .ok_or_else(|| "unknown window".to_string())?
                .world_rect;
            let (_, size) = frame(rect)?;
            return Ok(Response::Size {
                width: size[0] as i32,
                height: size[1] as i32,
            });
        };
        if width <= 0 || height <= 0 {
            return Err("size must be positive".to_string());
        }
        Err(
            "resize is not implemented on macOS yet: native layout resize is not available"
                .to_string(),
        )
    }
}
