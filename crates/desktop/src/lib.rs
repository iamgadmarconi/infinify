// SPDX-License-Identifier: GPL-3.0-or-later
//! Desktop scene controller. Native observations are ephemeral, never authority
//! to deliver an event. The native caller must validate ownership and process
//! birth immediately before and after event delivery.
mod ffi;
mod navigation;
mod storage;
pub use ffi::*;
pub use navigation::{FocusPlacement, ZoomPolicy};
use navigation::{NavigationContext, ViewFlight};

use driftwm_canvas::{
    DragGesture, OutputId, Point, Rect, ResizeEdges, ResizeGesture, Scene, Size, SnapOptions,
    Viewport, Window, WindowId,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

pub const ABI_VERSION: u32 = 1;
pub const SAVE_VERSION: u32 = 1;
/// Compatibility alias for JSON ABI callers.
pub const VERSION: u32 = ABI_VERSION;
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Invalid(&'static str),
    #[error(transparent)]
    Scene(#[from] driftwm_canvas::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Ephemeral observation; must never be reconstructed from a saved session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceIdentity {
    pub pid: i32,
    pub birth_sec: i64,
    pub birth_usec: i32,
    pub wid: u32,
    #[serde(default)]
    pub owner: Option<u32>,
}
impl SourceIdentity {
    fn validate(&self) -> Result<(), Error> {
        if self.pid <= 0
            || self.wid == 0
            || self.birth_sec <= 0
            || !(0..1_000_000).contains(&self.birth_usec)
            || self.owner == Some(0)
        {
            return Err(Error::Invalid("invalid fresh source identity"));
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BufferSize {
    pub width: u32,
    pub height: u32,
}
impl BufferSize {
    fn validate(self) -> Result<(), Error> {
        if self.width == 0 || self.height == 0 || self.width > 65536 || self.height > 65536 {
            return Err(Error::Invalid("invalid buffer dimensions"));
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct Source {
    pub generation: u64,
    pub identity: SourceIdentity,
    pub buffer: BufferSize,
    pub original_rect: Rect,
    pub observed_rect: Rect,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Metadata {
    pub bundle_id: String,
    pub title: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SavedOutput {
    stable_id: String,
    viewport: Viewport,
}

#[derive(Clone, Debug)]
enum Gesture {
    Drag {
        state: DragGesture,
        zoom: f64,
        output: OutputId,
    },
    Resize {
        state: ResizeGesture,
        zoom: f64,
        output: OutputId,
    },
}
/// A request to the native adapter, never evidence that focus changed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FocusEffect {
    pub op: &'static str,
    pub effect_id: u64,
    pub window: WindowId,
    pub identity: SourceIdentity,
    pub generation: u64,
}
#[derive(Clone, Debug, Default, Serialize)]
struct FocusRuntime {
    observed_native: Option<FocusEffect>,
    pending_effect: Option<FocusEffect>,
    last_result: Option<Value>,
    release_pending: bool,
}
#[derive(Clone, Debug, Default)]
pub struct Controller {
    scene: Scene,
    metadata: BTreeMap<WindowId, Metadata>,
    sources: BTreeMap<WindowId, Source>,
    outputs: BTreeMap<OutputId, SavedOutput>,
    next_window: u64,
    next_output: u64,
    gesture: Option<Gesture>,
    focus: FocusRuntime,
    next_effect: u64,
    next_generation: u64,
    flights: BTreeMap<OutputId, ViewFlight>,
    navigation_contexts: BTreeMap<OutputId, NavigationContext>,
    navigation_clock: Option<u64>,
    next_navigation: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub command: Command,
}
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Snapshot {},
    NavigateWindow {
        window: WindowId,
        output: OutputId,
        zoom_policy: ZoomPolicy,
    },
    CycleNavigate {
        output: OutputId,
        backward: bool,
        held: bool,
    },
    TickNavigation {
        timestamp_ns: u64,
    },
    CancelNavigation {
        output: OutputId,
    },
    SetNavigationContext {
        output: OutputId,
        usable_rect_local: Rect,
        focus_placement: FocusPlacement,
        camera_speed: f64,
        outer_gap: f64,
    },
    RegisterOutput {
        stable_id: String,
        screen_bounds: Rect,
    },
    RemoveOutput {
        output: OutputId,
    },
    Attach {
        identity: SourceIdentity,
        bundle_id: String,
        title: String,
        buffer: BufferSize,
        source_rect: Rect,
        #[serde(default)]
        logical_id: Option<WindowId>,
        #[serde(default)]
        world_rect: Option<Rect>,
    },
    Observe {
        window: WindowId,
        identity: SourceIdentity,
        source_rect: Rect,
        buffer: BufferSize,
    },
    RemoveSource {
        window: WindowId,
        identity: SourceIdentity,
        keep_placeholder: bool,
    },
    Forget {
        window: WindowId,
    },
    Pan {
        output: OutputId,
        screen_delta: Point,
    },
    Zoom {
        output: OutputId,
        zoom: f64,
        anchor: Point,
    },
    Focus {
        window: WindowId,
    },
    CycleFocus {
        backward: bool,
        held: bool,
    },
    EndFocusCycle {},
    CancelFocusCycle {},
    FocusLost {},
    FocusResult {
        effect_id: u64,
        window: WindowId,
        identity: SourceIdentity,
        generation: u64,
        success: bool,
    },
    ObserveFocus {
        window: WindowId,
        identity: SourceIdentity,
        generation: u64,
    },
    Hit {
        output: OutputId,
        screen: Point,
    },
    Input {
        output: OutputId,
        screen: Point,
        identity: SourceIdentity,
    },
    BeginDrag {
        window: WindowId,
        output: OutputId,
        #[serde(default)]
        group: bool,
    },
    BeginResize {
        window: WindowId,
        output: OutputId,
        edges: Edges,
        #[serde(default)]
        group: bool,
    },
    GestureTo {
        screen_delta: Point,
    },
    EndGesture {},
    Save {
        path: String,
    },
    Load {
        path: String,
    },
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Edges {
    Left,
    Right,
    Top,
    Bottom,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}
impl From<Edges> for ResizeEdges {
    fn from(value: Edges) -> Self {
        match value {
            Edges::Left => Self::Left,
            Edges::Right => Self::Right,
            Edges::Top => Self::Top,
            Edges::Bottom => Self::Bottom,
            Edges::TopLeft => Self::TopLeft,
            Edges::TopRight => Self::TopRight,
            Edges::BottomLeft => Self::BottomLeft,
            Edges::BottomRight => Self::BottomRight,
        }
    }
}
fn text_valid(s: &str, max: usize) -> bool {
    !s.contains('\0') && s.len() <= max
}
fn point_valid(p: Point) -> bool {
    p.x.is_finite() && p.y.is_finite() && p.x.abs() <= 1e12 && p.y.abs() <= 1e12
}
fn rect_valid(r: Rect) -> bool {
    point_valid(r.origin)
        && point_valid(Point::new(r.right(), r.bottom()))
        && r.size.width.is_finite()
        && r.size.height.is_finite()
        && r.size.width > 0.0
        && r.size.height > 0.0
}
impl Controller {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn scene(&self) -> &Scene {
        &self.scene
    }
    /// Every rejected command leaves in-memory scene, bindings, and gesture intact.
    pub fn request(&mut self, bytes: &[u8]) -> Result<Value, Error> {
        if bytes.len() > MAX_REQUEST_BYTES {
            return Err(Error::Invalid("request exceeds 1 MiB"));
        }
        let request: Request = serde_json::from_slice(bytes)?;
        self.execute(request)
    }
    pub fn execute(&mut self, request: Request) -> Result<Value, Error> {
        if request.version != VERSION {
            return Err(Error::Invalid("unsupported desktop schema"));
        }
        let mut next = self.clone();
        let result = next.apply(request.command)?;
        next.scene.validate()?;
        *self = next;
        Ok(result)
    }
    fn fresh(&self, id: WindowId, identity: &SourceIdentity) -> Result<&Source, Error> {
        identity.validate()?;
        let source = self
            .sources
            .get(&id)
            .ok_or(Error::Invalid("unbound source"))?;
        if source.identity != *identity {
            return Err(Error::Invalid("stale source identity"));
        }
        Ok(source)
    }
    fn apply(&mut self, command: Command) -> Result<Value, Error> {
        match command {
            Command::Snapshot {} => return self.snapshot(),
            Command::NavigateWindow {
                window,
                output,
                zoom_policy,
            } => {
                let navigation = self.arm_navigation(window, output, zoom_policy)?;
                self.finish_cycle();
                self.scene.focus(window)?;
                let mut result = self.request_focus(window)?;
                result["navigation"] = navigation;
                return Ok(result);
            }
            Command::CycleNavigate {
                output,
                backward,
                held,
            } => {
                self.navigation_context(output)?;
                self.focus.release_pending = false;
                if let Some(window) = self.scene.cycle_focus(backward)? {
                    let navigation = self.arm_navigation(window, output, ZoomPolicy::Keep)?;
                    let mut result = self.request_focus(window)?;
                    if !held {
                        self.release_cycle();
                    }
                    result["navigation"] = navigation;
                    return Ok(result);
                }
            }
            Command::TickNavigation { timestamp_ns } => return self.tick_navigation(timestamp_ns),
            Command::CancelNavigation { output } => {
                self.navigation_context(output)?;
                self.flights.remove(&output);
            }
            Command::SetNavigationContext {
                output,
                usable_rect_local,
                focus_placement,
                camera_speed,
                outer_gap,
            } => {
                self.set_navigation_context(
                    output,
                    usable_rect_local,
                    focus_placement,
                    camera_speed,
                    outer_gap,
                )?;
            }
            Command::RegisterOutput {
                stable_id,
                screen_bounds,
            } => {
                if stable_id.trim().is_empty() || !text_valid(&stable_id, 1024) {
                    return Err(Error::Invalid("invalid stable output identity"));
                }
                let id = if let Some((&id, _)) =
                    self.outputs.iter().find(|(_, o)| o.stable_id == stable_id)
                {
                    id
                } else {
                    self.next_output = self
                        .next_output
                        .checked_add(1)
                        .ok_or(Error::Invalid("output IDs exhausted"))?;
                    OutputId(self.next_output)
                };
                let viewport = self.outputs.get(&id).map_or(
                    Viewport {
                        id,
                        camera: Point::default(),
                        zoom: 1.0,
                        screen_bounds,
                    },
                    |o| Viewport {
                        screen_bounds,
                        ..o.viewport.clone()
                    },
                );
                if self.scene.output(id).is_some() {
                    self.scene.update_output(viewport.clone())?;
                } else {
                    self.scene.add_output(viewport.clone())?;
                }
                self.flights.remove(&id);
                self.navigation_contexts.remove(&id);
                self.outputs.insert(
                    id,
                    SavedOutput {
                        stable_id,
                        viewport,
                    },
                );
                return Ok(json!({"output": id}));
            }
            Command::RemoveOutput { output } => {
                let viewport = self.scene.remove_output(output)?;
                self.flights.remove(&output);
                self.navigation_contexts.remove(&output);
                self.outputs
                    .get_mut(&output)
                    .ok_or(Error::Invalid("missing output metadata"))?
                    .viewport = viewport;
                self.gesture = None;
            }
            Command::Attach {
                identity,
                bundle_id,
                title,
                buffer,
                source_rect,
                logical_id,
                world_rect,
            } => {
                identity.validate()?;
                buffer.validate()?;
                if !rect_valid(source_rect)
                    || !text_valid(&bundle_id, 1024)
                    || !text_valid(&title, 16384)
                {
                    return Err(Error::Invalid("invalid source metadata or rectangle"));
                }
                // Window numbers can be reused: never permit two live bindings to one observed PID/window pair.
                if self
                    .sources
                    .values()
                    .any(|s| s.identity.pid == identity.pid && s.identity.wid == identity.wid)
                {
                    return Err(Error::Invalid("source already attached"));
                }
                let id = if let Some(id) = logical_id {
                    if world_rect.is_some() {
                        return Err(Error::Invalid("rebind cannot replace saved world geometry"));
                    }
                    if self.scene.window(id).is_none() {
                        return Err(Error::Invalid("unknown saved logical ID"));
                    }
                    if self.sources.contains_key(&id) {
                        return Err(Error::Invalid("logical window already bound"));
                    }
                    id
                } else {
                    self.next_window = self
                        .next_window
                        .checked_add(1)
                        .ok_or(Error::Invalid("window IDs exhausted"))?;
                    let id = WindowId(self.next_window);
                    self.scene.add_window(Window {
                        id,
                        world_rect: world_rect.unwrap_or(source_rect),
                        native: None,
                        title: title.clone(),
                    })?;
                    id
                };
                self.metadata.insert(id, Metadata { bundle_id, title });
                self.next_generation = self
                    .next_generation
                    .checked_add(1)
                    .ok_or(Error::Invalid("binding generations exhausted"))?;
                self.sources.insert(
                    id,
                    Source {
                        generation: self.next_generation,
                        identity,
                        buffer,
                        original_rect: source_rect,
                        observed_rect: source_rect,
                    },
                );
                return Ok(json!({"window": id}));
            }
            Command::Observe {
                window,
                identity,
                source_rect,
                buffer,
            } => {
                self.fresh(window, &identity)?;
                buffer.validate()?;
                if !rect_valid(source_rect) {
                    return Err(Error::Invalid("invalid observed source rectangle"));
                }
                let source = self
                    .sources
                    .get_mut(&window)
                    .ok_or(Error::Invalid("unbound source"))?;
                source.observed_rect = source_rect;
                source.buffer = buffer;
            }
            Command::RemoveSource {
                window,
                identity,
                keep_placeholder,
            } => {
                self.fresh(window, &identity)?;
                self.invalidate_focus(window);
                self.sources.remove(&window);
                if !keep_placeholder {
                    self.scene.remove_window(window)?;
                    self.metadata.remove(&window);
                }
                self.gesture = None;
            }
            Command::Forget { window } => {
                self.scene.remove_window(window)?;
                self.metadata.remove(&window);
                self.invalidate_focus(window);
                self.sources.remove(&window);
                self.gesture = None;
            }
            Command::Pan {
                output,
                screen_delta,
            } => {
                self.flights.remove(&output);
                self.scene.pan(output, screen_delta)?;
                self.sync_output(output)?;
            }
            Command::Zoom {
                output,
                zoom,
                anchor,
            } => {
                self.flights.remove(&output);
                self.scene.zoom_at(output, zoom, anchor)?;
                self.sync_output(output)?;
            }
            Command::Focus { window } => {
                self.finish_cycle();
                self.scene.focus(window)?;
                return self.request_focus(window);
            }
            Command::CycleFocus { backward, held } => {
                self.focus.release_pending = false;
                if let Some(window) = self.scene.cycle_focus(backward)? {
                    let result = self.request_focus(window)?;
                    if !held {
                        self.release_cycle();
                    }
                    return Ok(result);
                }
            }
            Command::EndFocusCycle {} => self.release_cycle(),
            Command::CancelFocusCycle {} => {
                self.scene.cancel_cycle();
                self.focus.pending_effect = None;
                self.focus.release_pending = false;
            }
            Command::FocusLost {} => {
                self.scene.cancel_cycle();
                self.focus.pending_effect = None;
                self.focus.observed_native = None;
                self.focus.release_pending = false;
            }
            Command::FocusResult {
                effect_id,
                window,
                identity,
                generation,
                success,
            } => {
                let expected = FocusEffect {
                    op: "focus_native_window",
                    effect_id,
                    window,
                    identity,
                    generation,
                };
                if self.focus.pending_effect.as_ref() != Some(&expected) {
                    return Err(Error::Invalid("stale or superseded focus result"));
                }
                self.check_generation(window, &expected.identity, generation)?;
                self.focus.pending_effect = None;
                self.focus.last_result = Some(json!({"effect": expected, "success": success}));
                if success {
                    self.focus.observed_native = Some(expected);
                    self.scene.confirm_focus(window)?;
                    if self.focus.release_pending {
                        self.finish_cycle();
                    }
                } else {
                    // A failed request does not claim a new observation.
                    self.scene.cancel_cycle();
                    self.focus.release_pending = false;
                }
            }
            Command::ObserveFocus {
                window,
                identity,
                generation,
            } => {
                self.check_generation(window, &identity, generation)?;
                self.finish_cycle();
                self.focus.pending_effect = None;
                self.scene.focus(window)?;
                self.scene.confirm_focus(window)?;
                self.focus.observed_native = Some(FocusEffect {
                    op: "observed_native_focus",
                    effect_id: 0,
                    window,
                    identity,
                    generation,
                });
            }
            Command::Hit { output, screen } => return self.hit(output, screen, None),
            Command::Input {
                output,
                screen,
                identity,
            } => return self.hit(output, screen, Some(&identity)),
            Command::BeginDrag {
                window,
                output,
                group,
            } => {
                if self.gesture.is_some() {
                    return Err(Error::Invalid("gesture already active"));
                }
                let zoom = self
                    .scene
                    .output(output)
                    .ok_or(Error::Invalid("unknown output"))?
                    .zoom;
                let options = SnapOptions {
                    threshold: 24.0 / zoom,
                    ..SnapOptions::default()
                };
                self.flights.clear();
                self.gesture = Some(Gesture::Drag {
                    state: self.scene.begin_drag(window, options, 32.0 / zoom, group)?,
                    zoom,
                    output,
                });
            }
            Command::BeginResize {
                window,
                output,
                edges,
                group,
            } => {
                if self.gesture.is_some() {
                    return Err(Error::Invalid("gesture already active"));
                }
                let zoom = self
                    .scene
                    .output(output)
                    .ok_or(Error::Invalid("unknown output"))?
                    .zoom;
                self.flights.clear();
                self.gesture = Some(Gesture::Resize {
                    state: self
                        .scene
                        .begin_resize(
                            window,
                            edges.into(),
                            SnapOptions {
                                threshold: 24.0 / zoom,
                                ..SnapOptions::default()
                            },
                            group,
                        )?
                        .with_break_force(32.0 / zoom)?,
                    zoom,
                    output,
                });
            }
            Command::GestureTo { screen_delta } => {
                if !point_valid(screen_delta) {
                    return Err(Error::Invalid("invalid gesture delta"));
                }
                match self
                    .gesture
                    .as_mut()
                    .ok_or(Error::Invalid("no active gesture"))?
                {
                    Gesture::Drag {
                        state,
                        zoom,
                        output,
                    } => {
                        let current_zoom = self
                            .scene
                            .output(*output)
                            .ok_or(Error::Invalid("unknown gesture output"))?
                            .zoom;
                        state.set_snap_distances(24.0 / current_zoom, 32.0 / current_zoom)?;
                        self.scene.drag_to(state, screen_delta / *zoom)?;
                    }
                    Gesture::Resize {
                        state,
                        zoom,
                        output,
                    } => {
                        let current_zoom = self
                            .scene
                            .output(*output)
                            .ok_or(Error::Invalid("unknown gesture output"))?
                            .zoom;
                        state.set_snap_distances(24.0 / current_zoom, 32.0 / current_zoom)?;
                        self.scene.resize_to(state, screen_delta / *zoom)?;
                    }
                }
            }
            Command::EndGesture {} => self.gesture = None,
            Command::Save { path } => {
                self.save(&path)?;
            }
            Command::Load { path } => {
                let mut loaded = Self::load(&path)?;
                loaded.next_effect = self.next_effect;
                loaded.next_navigation = self.next_navigation;
                loaded.next_generation = self.next_generation;
                *self = loaded;
            }
        }
        Ok(json!({}))
    }
    fn check_generation(
        &self,
        window: WindowId,
        identity: &SourceIdentity,
        generation: u64,
    ) -> Result<(), Error> {
        if self.fresh(window, identity)?.generation != generation {
            return Err(Error::Invalid("stale binding generation"));
        }
        Ok(())
    }
    fn request_focus(&mut self, window: WindowId) -> Result<Value, Error> {
        self.focus.pending_effect = None;
        let Some(source) = self.sources.get(&window) else {
            return Ok(json!({"effect": null}));
        };
        self.next_effect = self
            .next_effect
            .checked_add(1)
            .ok_or(Error::Invalid("focus effect IDs exhausted"))?;
        let effect = FocusEffect {
            op: "focus_native_window",
            effect_id: self.next_effect,
            window,
            identity: source.identity.clone(),
            generation: source.generation,
        };
        self.focus.pending_effect = Some(effect.clone());
        Ok(json!({"effect": effect}))
    }
    fn finish_cycle(&mut self) {
        // Only a confirmed current selection can be committed. A pending
        // selection must not accidentally promote the previous observation.
        if self.focus.pending_effect.is_none()
            && self
                .focus
                .observed_native
                .as_ref()
                .is_some_and(|f| Some(f.window) == self.scene.focused())
            && self
                .scene
                .stage()
                .cycle_state()
                .and_then(|i| self.scene.stage().focus_history().get(i))
                .copied()
                == self.scene.focused()
        {
            self.scene.end_cycle();
        } else {
            self.scene.cancel_cycle();
        }
        self.focus.release_pending = false;
    }
    fn release_cycle(&mut self) {
        if self.scene.stage().cycle_state().is_none() {
            return;
        }
        if self.focus.pending_effect.is_some() {
            self.focus.release_pending = true;
        } else {
            self.finish_cycle();
        }
    }
    fn invalidate_focus(&mut self, window: WindowId) {
        self.scene.drop_focus_history(window);
        if self.scene.focused() == Some(window)
            || self
                .focus
                .pending_effect
                .as_ref()
                .is_some_and(|f| f.window == window)
            || self
                .focus
                .observed_native
                .as_ref()
                .is_some_and(|f| f.window == window)
        {
            self.scene.cancel_cycle();
            self.focus.release_pending = false;
            self.focus.pending_effect = None;
        }
        if self
            .focus
            .observed_native
            .as_ref()
            .is_some_and(|f| f.window == window)
        {
            self.focus.observed_native = None;
        }
    }
    fn sync_output(&mut self, id: OutputId) -> Result<(), Error> {
        self.outputs
            .get_mut(&id)
            .ok_or(Error::Invalid("missing output metadata"))?
            .viewport = self
            .scene
            .output(id)
            .ok_or(Error::Invalid("unknown output"))?
            .clone();
        Ok(())
    }
    fn hit(
        &self,
        output: OutputId,
        screen: Point,
        expected: Option<&SourceIdentity>,
    ) -> Result<Value, Error> {
        if !point_valid(screen) {
            return Err(Error::Invalid("invalid screen point"));
        }
        if self.scene.output(output).is_none() {
            return Err(Error::Invalid("unknown output"));
        }
        let Some(hit) = self.scene.hit_test(output, screen) else {
            if expected.is_some() {
                return Err(Error::Invalid("input does not hit a source"));
            }
            return Ok(json!({"hit": null}));
        };
        let source = self
            .sources
            .get(&hit.window)
            .ok_or(Error::Invalid("unbound source"))?;
        if let Some(identity) = expected {
            self.fresh(hit.window, identity)?;
        }
        let world = self
            .scene
            .window(hit.window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let local = scale_point(hit.local, world.size, source.observed_rect.size);
        let buffer_local = scale_point(
            hit.local,
            world.size,
            Size::new(source.buffer.width as f64, source.buffer.height as f64),
        );
        Ok(
            json!({"hit": {"window": hit.window, "output": output, "identity": source.identity, "local": local, "buffer_local": buffer_local, "native_screen": source.observed_rect.origin + local, "requires_native_revalidation": true}}),
        )
    }
    fn snapshot(&self) -> Result<Value, Error> {
        let placements: Vec<_> = self.scene.placements().iter().map(|p| {
            let source = self.sources.get(&p.window);
            let world_size = self.scene.window(p.window).expect("placement references scene window").world_rect.size;
            let buffer_crop = source.map(|s| scale_rect(p.source_rect, world_size, Size::new(s.buffer.width as f64, s.buffer.height as f64)));
            json!({"window": p.window, "output": p.output, "screen_rect": p.screen_rect, "clip_rect": p.clip_rect, "world_local_crop": p.source_rect, "buffer_crop": buffer_crop, "source": source})
        }).collect();
        let windows: Vec<_> = self.scene.windows().iter().map(|w| json!({"window": w.id, "world_rect": w.world_rect, "metadata": self.metadata.get(&w.id), "source": self.sources.get(&w.id)})).collect();
        Ok(
            json!({"evidence": "logical_controller_only", "capabilities": ["normal_window_navigation"], "navigation": {"flights": self.flights, "clock_ns": self.navigation_clock, "contexts": self.navigation_contexts}, "outputs": self.scene.outputs(), "windows": windows, "focused": self.scene.focused(), "focus": {"intent": self.scene.focused(), "observed_native": self.focus.observed_native, "pending_effect": self.focus.pending_effect, "last_result": self.focus.last_result, "history": self.scene.stage().focus_history(), "cycle": self.scene.stage().cycle_state(), "release_pending": self.focus.release_pending}, "placements": placements}),
        )
    }
}
fn scale_point(p: Point, from: Size, to: Size) -> Point {
    Point::new(p.x / from.width * to.width, p.y / from.height * to.height)
}
fn scale_rect(r: Rect, from: Size, to: Size) -> Rect {
    Rect {
        origin: scale_point(r.origin, from, to),
        size: Size::new(
            r.size.width / from.width * to.width,
            r.size.height / from.height * to.height,
        ),
    }
}
