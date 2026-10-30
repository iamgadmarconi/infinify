// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d, with the v0.21.0 additions from
// df3de27b26c7998e8a460cffd8a4925cbed3a322
// (src/ipc/{protocol,mod}.rs: Request::Cursor and cmd_cursor,
// the `pid` of WindowInfo, OutputFullscreen and OutputPinned, check_point,
// check_size, the camera and bookmark bounds of cmd_camera and cmd_bookmark):
// src/ipc/protocol.rs (every wire type: names, serde shapes and field order),
// src/ipc/mod.rs (dispatch, cmd_camera, cmd_zoom, cmd_layout, state_info, the
// selector rules, cmd_focus, cmd_action, cmd_bookmark, cmd_move, cmd_resize,
// camera_center, subscribe, broadcast_state_event) and src/canvas.rs
// (internal_to_rule, rule_to_internal). Close, Suspend and Relaunch are
// answered in lifecycle.rs, which also holds upstream's
// window_fully_in_viewport, Pin and Opacity in rules.rs, Screenshot in
// render.rs. The transport lives in the shell. Native frames already include
// their title bar, so chrome is zero.
use super::actions::Outcome;
use super::storage::{CAMERA_LIMIT, POSITION_LIMIT, valid_canvas_point};
use super::view_actions::{core_point, pixel_size};
use super::*;
use driftwm_core::canvas;

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
    /// The pointer in the global output layout (screen space, not canvas), plus
    /// the output it is on.
    Cursor,
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
    /// macOS visibility; unlike Suspend this never closes the native window.
    Minimize(Option<WindowSelector>),
    Deminimize(Option<WindowSelector>),
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
    Cursor {
        x: f64,
        y: f64,
        output: String,
    },
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
/// How a request that was not refused is answered.
enum Answer {
    /// Upstream's reply, now.
    Reply(Response),
    /// Not yet: the shell performs the effect and brings the reply's content.
    Pending,
}

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
    /// The process that owns the window's native source, from its bound
    /// identity. Absent with no source: a stand-in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct OutputFullscreen {
    pub id: u64,
    pub output: String,
    pub app_id: String,
    pub title: String,
    /// As [`WindowInfo::pid`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct OutputPinned {
    pub id: u64,
    pub output: String,
    pub app_id: String,
    pub title: String,
    pub position: [i32; 2],
    pub size: [i32; 2],
    /// As [`WindowInfo::pid`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct CanvasLayerInfo {
    pub app_id: String,
    pub position: [i32; 2],
    pub size: [i32; 2],
}

/// A world frame at upstream's integer boundary: top-left and size, each
/// rounded to the nearest logical pixel. Out-of-range geometry is refused.
pub(crate) fn frame(rect: Rect) -> Result<([i64; 2], [i64; 2]), String> {
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
pub(crate) fn internal_to_rule(loc: [i64; 2], size: [i64; 2]) -> Result<[i32; 2], String> {
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
pub(crate) fn rule_to_internal(x: i32, y: i32, size: [i64; 2]) -> Point {
    Point::new(
        (i64::from(x) - size[0] / 2) as f64,
        (-i64::from(y) - size[1] / 2) as f64,
    )
}
/// Can every later request read this frame? The top-left must round into
/// `i32` (State, Move, Resize) and so must the far edge (the enclosing integer
/// rectangle the fit and zoom policy takes).
pub(crate) fn readable(rect: Rect) -> Result<(), String> {
    frame(rect)?;
    if rect.right().ceil() > f64::from(i32::MAX) || rect.bottom().ceil() > f64::from(i32::MAX) {
        return Err("window geometry exceeds integer range".to_string());
    }
    Ok(())
}
/// Upstream `SIZE_LIMIT`: the largest size a request may ask for, a looser
/// outer gate than the stand-in ceiling, which clamps a suspended window
/// afterward.
const SIZE_LIMIT: i32 = 32767;
/// Upstream `check_point`: coordinates share the position limit of a restored
/// session.
pub(crate) fn check_point(x: i32, y: i32) -> Result<(), String> {
    let range = -POSITION_LIMIT..=POSITION_LIMIT;
    if range.contains(&x) && range.contains(&y) {
        Ok(())
    } else {
        Err(format!("coordinates must be within ±{POSITION_LIMIT}"))
    }
}
/// Upstream `check_size`.
pub(crate) fn check_size(w: i32, h: i32) -> Result<(), String> {
    if w <= SIZE_LIMIT && h <= SIZE_LIMIT {
        Ok(())
    } else {
        Err(format!("sizes must be at most {SIZE_LIMIT}"))
    }
}
fn text(error: Error) -> String {
    error.to_string()
}

impl Controller {
    /// Answer one upstream request. A request that does not decode or is
    /// refused becomes `{"Err":…}` in `reply` and leaves every bit of
    /// controller state as it was; it is never a controller-level error.
    pub(crate) fn ipc(
        &mut self,
        output: Option<OutputId>,
        request: Value,
        pointer: Option<Point>,
    ) -> Value {
        let mut next = self.clone();
        let mut outcome = Outcome::default();
        let answer = serde_json::from_value::<Request>(request)
            .map_err(|e| format!("invalid request: {e}"))
            .and_then(|request| next.dispatch(output, request, pointer, &mut outcome))
            .and_then(|answer| {
                next.scene
                    .validate()
                    .map(|()| answer)
                    .map_err(|e| e.to_string())
            });
        // A pending answer is `null`: the shell replies to its client only
        // after the effect, with what `screenshot_result` returns.
        let reply = match answer {
            Ok(answer) => {
                *self = next;
                match answer {
                    Answer::Reply(response) => json!(Reply::Ok(response)),
                    Answer::Pending => Value::Null,
                }
            }
            Err(error) => {
                outcome = Outcome::default();
                json!(Reply::Err(error))
            }
        };
        let data = json!({"reply":reply,"effects":outcome.effects,"dirty":outcome.dirty,"navigation":outcome.navigation});
        super::sizes::carry(data, outcome.resize)
    }
    fn dispatch(
        &mut self,
        output: Option<OutputId>,
        request: Request,
        pointer: Option<Point>,
        outcome: &mut Outcome,
    ) -> Result<Answer, String> {
        let active = || output.ok_or_else(|| "no active output".to_string());
        let reply: Reply = match request {
            Request::Screenshot {
                target,
                scale,
                path,
            } => {
                return self
                    .cmd_screenshot(output, &target, scale, &path, outcome)
                    .map(|()| Answer::Pending);
            }
            Request::Camera(arg) => self.cmd_camera(active()?, arg, outcome),
            Request::Cursor => self.cmd_cursor(output, pointer),
            Request::Zoom(arg) => self.cmd_zoom(active()?, arg, outcome),
            Request::State => Ok(Response::State(Box::new(self.state_info(output)?))),
            Request::DebugCounters => Ok(Response::DebugCounters(self.debug_counters())),
            Request::Focus(None) => Ok(Response::Focused(
                self.scene.focused().map(|id| self.focused_info(id)),
            )),
            Request::Focus(Some(selector)) => self.cmd_focus(active()?, &selector, outcome),
            Request::Move { window, to } => self.cmd_move(window.as_ref(), to, outcome),
            Request::Resize { window, to } => self.cmd_resize(output, window.as_ref(), to, outcome),
            Request::Opacity { window, value } => self.cmd_opacity(window.as_ref(), value),
            Request::Pin { window, value } => self.cmd_pin(output, window.as_ref(), value, outcome),
            Request::Action(spec) => {
                // A request has no key held under it: a cycle step commits.
                *outcome = self
                    .run_action(output, &spec, pointer, false)
                    .map_err(text)?;
                Ok(Response::Ok)
            }
            Request::Bookmark { name, to, delete } => self.cmd_bookmark(name, to, delete, outcome),
            // Upstream cmd_close asks the window to close, or dismisses the
            // stand-in, and ends no fullscreen: a fullscreen window's own
            // going does, in `window_closed`.
            Request::Close(selector) => self
                .cmd_close(output, selector.as_ref(), outcome)
                .map(|()| Response::Ok),
            // Upstream runs it through its action, whose guard ends the active
            // output's fullscreen. A refusal rolls that back.
            Request::Suspend(selector) => {
                outcome.dirty |= output.is_some_and(|o| self.exit_fullscreen_on(o).is_some());
                self.cmd_suspend(output, selector.as_ref(), outcome)
                    .map(|()| Response::Ok)
            }
            Request::Relaunch(selector) => self
                .cmd_relaunch(selector.as_ref(), outcome)
                .map(|()| Response::Ok),
            Request::Minimize(selector) => self
                .cmd_minimize(selector.as_ref(), true, outcome)
                .map(|()| Response::Ok),
            Request::Deminimize(selector) => self
                .cmd_minimize(selector.as_ref(), false, outcome)
                .map(|()| Response::Ok),
            Request::Layout { short: true } => Ok(Response::Layout(self.layout_short())),
            Request::Layout { short: false } => Ok(Response::Layout(self.layout_name())),
            // Upstream subscribe: the ack, then the current snapshot on the same
            // connection, which only the shell can write to.
            Request::Subscribe => {
                let line = self.event_line(output)?;
                outcome.effects.push(json!({"op":"subscribe","line":line}));
                Ok(Response::Ok)
            }
        };
        reply.map(Answer::Reply)
    }
    /// One pushed line: upstream's `Event::State` serialized from the typed
    /// value, so its members keep upstream's order and its floats their form.
    fn event_line(&self, output: Option<OutputId>) -> Result<String, String> {
        serde_json::to_string(&Event::State(self.state_info(output)?)).map_err(|e| e.to_string())
    }
    /// Upstream broadcast_state_event: the current State event line, or null
    /// when it is the one this command returned last. A snapshot that
    /// serializes to the same bytes carries no information and is not resent;
    /// upstream compares a hash of those bytes, and so does this.
    pub(crate) fn state_event(&mut self, output: Option<OutputId>) -> Result<Value, Error> {
        use std::hash::{Hash, Hasher};
        let line = self.event_line(output).map_err(Error::Refused)?;
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        line.hash(&mut hasher);
        let digest = hasher.finish();
        if self.last_event == Some(digest) {
            return Ok(json!({"line":null}));
        }
        self.last_event = Some(digest);
        Ok(json!({"line":line}))
    }
    /// The viewport center, Y-up, over the whole output: upstream camera_center.
    fn camera_center(viewport: &Viewport) -> Result<(f64, f64), String> {
        let size = pixel_size(viewport.screen_bounds.size).map_err(text)?;
        Ok(canvas::viewport_center(
            core_point(viewport.camera),
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
        // Upstream cmd_camera: a point past the camera's range is refused before
        // anything is touched, a fullscreen exit included.
        if !valid_canvas_point(x, y) {
            return Err(format!(
                "camera coordinates must be within ±{CAMERA_LIMIT:e}"
            ));
        }
        // Upstream: a fullscreen output refuses camera moves and is parked at
        // zoom 1, so it ends first, after the request is known to be sound.
        outcome.dirty |= self.exit_fullscreen_on(output).is_some();
        // v0.20: through the anchor, at the zoom the view is heading to. A
        // flight still under way steers by its anchor every tick, which would
        // drop a bare camera target, so `msg zoom 0.5` then `msg camera X Y`
        // lands at both. (x, y) is the output's center, Y up.
        let (viewport, _) = self.view(output).map_err(text)?;
        let size = pixel_size(viewport.screen_bounds.size).map_err(text)?;
        let zoom = self.landing_view(output).map_err(text)?.1;
        self.user_moved_camera();
        let anchor = crate::navigation::Anchor {
            canvas: Point::new(x, -y),
            screen: Point::new(f64::from(size.w) / 2.0, f64::from(size.h) / 2.0),
        };
        outcome.navigation = self.arm_anchor(output, anchor, zoom).map_err(text)?;
        Ok(Response::Camera { x, y })
    }
    /// Upstream cmd_cursor: the pointer in the global output layout (the space
    /// `screen_bounds` and a `from_screen` screenshot region are given in) and
    /// the output the request is for, which is the one under the pointer. The
    /// controller keeps no pointer of its own: the shell sends the point with
    /// the request, as it does for `focus-center`.
    fn cmd_cursor(&self, output: Option<OutputId>, pointer: Option<Point>) -> Reply {
        let pointer = pointer.ok_or("no pointer")?;
        let output = output.ok_or("no output")?;
        self.viewport(output)?;
        Ok(Response::Cursor {
            x: pointer.x,
            y: pointer.y,
            output: self
                .outputs
                .get(&output)
                .map(|o| o.stable_id.clone())
                .unwrap_or_default(),
        })
    }
    /// The `pid` of the window's bound source, which upstream reads from the
    /// socket credentials of the client connection. A stand-in has none.
    pub(crate) fn window_pid(&self, window: WindowId) -> Option<u32> {
        self.sources
            .get(&window)
            .and_then(|source| u32::try_from(source.identity.pid).ok())
    }
    fn cmd_zoom(&mut self, output: OutputId, arg: Option<f64>, outcome: &mut Outcome) -> Reply {
        let Some(zoom) = arg else {
            return Ok(Response::Zoom(self.viewport(output)?.zoom));
        };
        if !zoom.is_finite() || zoom <= 0.0 {
            return Err("zoom must be a positive number".to_string());
        }
        // As in `cmd_camera`: the anchor is the camera the exit restores.
        outcome.dirty |= self.exit_fullscreen_on(output).is_some();
        // Same bounds and usable-center anchor as keyboard zoom; the reply
        // reports what was applied.
        let (viewport, usable) = self.view(output).map_err(text)?;
        let clamped = zoom.clamp(self.min_zoom(usable).map_err(text)?, canvas::MAX_ZOOM);
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
            ("durable_bookmarks", self.durable_bookmarks.len()),
            ("flights", self.flights.len()),
            ("home_returns", self.home_returns.len()),
            ("metadata", self.metadata.len()),
            ("navigation_contexts", self.navigation_contexts.len()),
            ("outputs", self.scene.outputs().len()),
            ("overview_returns", self.overview_returns.len()),
            ("pending_screenshots", self.pending_screenshots.len()),
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
            // Upstream: a pinned window and a fullscreen one live in screen
            // space and are reported under `pinned` and `fullscreen` instead.
            if self.is_pinned(window.id) || self.is_fullscreen(window.id) {
                continue;
            }
            let metadata = self.metadata.get(&window.id);
            let (loc, size) = frame(window.world_rect)?;
            let info = WindowInfo {
                id: window.id.0,
                app_id: metadata.map(|m| m.bundle_id.clone()).unwrap_or_default(),
                title: metadata.map(|m| m.title.clone()).unwrap_or_default(),
                position: internal_to_rule(loc, size)?,
                size: [size[0] as i32, size[1] as i32],
                is_focused: focused == Some(window.id),
                is_widget: self.is_widget(window.id),
                // A detached placeholder is Infinify's stand-in.
                suspended: !self.sources.contains_key(&window.id),
                mode: self.sizes.mode(window.id),
                pid: self.window_pid(window.id),
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
            layout: self.layout_name(),
            layout_short: self.layout_short(),
            windows,
            fullscreen: self.fullscreen_inventory(),
            pinned: self.pinned_inventory()?,
            layers: Vec::new(),
            canvas_layers: Vec::new(),
            outputs,
            active_bookmark: output.and_then(|id| self.active_bookmarks.get(&id).cloned()),
        })
    }
    /// `None` is the focused window. An id is exact, and reaches a widget. An
    /// app id is a case-insensitive bundle-id substring that passes over
    /// widgets, and a window with a bound source wins over a detached
    /// placeholder: upstream's live client over stand-in.
    pub(crate) fn select(&self, selector: Option<&WindowSelector>) -> Result<WindowId, String> {
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
                            && !self.is_widget(*id)
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
    pub(crate) fn fully_in_viewport(
        &self,
        window: WindowId,
        output: OutputId,
    ) -> Result<bool, String> {
        self.viewport(output)?;
        self.navigation_context(output).map_err(text)?;
        self.scene
            .window(window)
            .ok_or_else(|| "unknown window".to_string())?;
        Ok(self.fully_on(window, output))
    }
    /// Logical focus plus upstream's camera rule: a window already fully on
    /// screen is only raised and focused; a window with a bound source is
    /// navigated to at zoom 1, or at the current zoom with
    /// `zoom.reset_on_activation` off;
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
        // Only an id reaches a widget, and a widget cannot take the focus.
        if self.is_widget(window) {
            return Err(format!(
                "window #{} is a widget and cannot be focused",
                window.0
            ));
        }
        let info = self.focused_info(window);
        // Upstream navigate_to_window_on: a fullscreen window is shown on its
        // own output only. From any other it is no target at all: nothing is
        // focused and no camera moves. On its own it is focused where it is.
        let fullscreen = self.fullscreen_output_of(window);
        // v0.20: judged where the view lands, so a window that a flight under way
        // is about to leave behind is panned to, and one it will show whole
        // lets it land (upstream reveal_element).
        let (camera, zoom) = self.landing_view(output).map_err(text)?;
        let visible = self.is_pinned(window)
            || self
                .window_fully_in_view_at(window, output, camera, zoom)
                .map_err(text)?;
        if !visible && fullscreen.is_some_and(|own| own != output) {
            return Ok(Response::Focused(Some(info)));
        }
        // A pinned window is always on screen and has no canvas position.
        if !visible && fullscreen.is_none() {
            let reset = self.config().zoom_reset_on_activation;
            let policy = if reset && self.sources.contains_key(&window) {
                ZoomPolicy::Reset
            } else {
                ZoomPolicy::Keep
            };
            outcome.navigation = self.arm_navigation(window, output, policy).map_err(text)?;
        }
        self.finish_cycle();
        self.scene.focus(window).map_err(|e| e.to_string())?;
        // As in navigate_to_window_on: this navigation's own pan, or a flight
        // still under way when it makes none, must not hand the focus just set
        // to whatever slides under a resting pointer.
        self.hover_parked();
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
                self.store_bookmark(name, [x, y])?;
                outcome.dirty = true;
                Ok(Response::Bookmark { x, y })
            }
        }
    }
    /// A logical world move: the frame's top-left lands on whole pixels and its
    /// size is kept. A bound source is raised without changing focus; a detached
    /// placeholder keeps its stacking. A destination outside the `i32` range is
    /// refused, as an unreadable frame is.
    /// A pinned window reads and is not moved; a widget is moved by nothing else.
    fn cmd_move(
        &mut self,
        selector: Option<&WindowSelector>,
        to: Option<(i32, i32)>,
        outcome: &mut Outcome,
    ) -> Reply {
        // Upstream cmd_move: a destination past the position range is refused
        // before the selector is resolved.
        if let Some((x, y)) = to {
            check_point(x, y)?;
        }
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
        // A pinned window is drawn at its pin and a fullscreen one at its
        // output's parked camera: a canvas position written under either
        // would silently do nothing, or displace the park.
        if self.is_pinned(window) || self.is_fullscreen(window) {
            return Err(
                "this window has no canvas position to move: it is pinned, fullscreen, or \
                 not on screen yet"
                    .to_string(),
            );
        }
        // Upstream map_window_to_rule_point: a window still owed the size it
        // had before fullscreen is centered by that size, not by the frame
        // that still has the output's, and comes back around that center.
        let size = self.fullscreen.restore_size(window).unwrap_or(size);
        let origin = rule_to_internal(x, y, size);
        let moved = Rect {
            origin,
            size: rect.size,
        };
        self.place_window(window, moved)?;
        // Upstream's live-client map raises even at the same position; its
        // stand-in set_position does not. settle_policy keeps widgets below
        // ordinary windows after every command, including this raise.
        if self.sources.contains_key(&window) {
            self.scene.raise(window).map_err(|e| e.to_string())?;
        }
        self.fullscreen
            .reaimed(window, [origin.x as i64, origin.y as i64]);
        outcome.dirty = true;
        Ok(Response::Position { x, y })
    }
    /// Give a window a new world frame outside any gesture: `Move` and
    /// `nudge-window` both end here.
    pub(crate) fn place_window(&mut self, window: WindowId, moved: Rect) -> Result<(), String> {
        // A live gesture recomputes rectangles from its own start anchors on
        // every motion, so anything written mid-drag would be erased or fought.
        if self.gesture.is_some() {
            return Err("a window is under an interactive move or resize".to_string());
        }
        self.guard_resize_structure(Some(window)).map_err(text)?;
        // Refuse a destination no later request could read.
        readable(moved)?;
        self.scene
            .set_window_rect(window, moved)
            .map_err(|e| e.to_string())?;
        // Upstream NudgeWindow, SendToOutput and map_window_to_rule_point:
        // re-anchoring the window ends a fill restore point. A fit survives.
        self.sizes.clear_fill(window);
        self.fullscreen.moved(window);
        Ok(())
    }
    fn cmd_resize(
        &mut self,
        output: Option<OutputId>,
        selector: Option<&WindowSelector>,
        to: Option<(i32, i32)>,
        outcome: &mut Outcome,
    ) -> Reply {
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
        check_size(width, height)?;
        // Upstream refuses these whatever else it can resize, and before it
        // asks whether a grab holds the window.
        if !self.on_canvas(window) {
            return Err(
                "this window has no canvas size to set: it is pinned, fullscreen, a widget, or \
                 not on screen yet"
                    .to_string(),
            );
        }
        if !self.sizes.capability {
            return Err(
                "resize is not implemented on macOS yet: native layout resize is not available"
                    .to_string(),
            );
        }
        let size = [width.into(), height.into()];
        let written = self.request_window_size(window, output, size, true, outcome)?;
        // Upstream resize_element_to raises a client it resizes and hands it
        // no focus: a selector reaches any window. A request identical to the
        // one outstanding returns before its map and restacks nothing.
        if written && self.scene.windows().last().map(|top| top.id) != Some(window) {
            self.scene.raise(window).map_err(|e| e.to_string())?;
            outcome.dirty = true;
        }
        Ok(Response::Size { width, height })
    }
}
