// SPDX-License-Identifier: GPL-3.0-or-later
//! Desktop scene controller. Native observations are ephemeral, never authority
//! to deliver an event. The native caller must validate ownership and process
//! birth immediately before and after event delivery.
mod actions;
mod bindings;
mod default_commands;
mod ffi;
mod ipc;
mod ipc_client;
mod keyboard_layout;
mod lifecycle;
mod navigation;
mod output_actions;
mod resize_transaction;
mod settings;
mod storage;
mod view_actions;
mod window_actions;
use bindings::Platform;
pub use bindings::{MacModifiers, PointerContext, PointerTrigger, ScrollSource};
pub use ffi::*;
use keyboard_layout::KeyboardLayout;
use lifecycle::{Arrival, Lifecycle};
pub use navigation::{FocusPlacement, ZoomPolicy};
use navigation::{NavigationContext, ViewFlight};
pub use output_actions::Corner;
use resize_transaction::NativeResizeTransaction;
pub use resize_transaction::{NativeResizeResult, ResizeOutcome};
use settings::{CameraSeed, Settings};
pub use view_actions::ViewDirection;
use view_actions::ViewReturn;
pub use window_actions::ActivationCause;

use driftwm_canvas::{
    DragGesture, OutputId, Point, Rect, ResizeEdges, ResizeGesture, Scene, Size, SnapOptions,
    Viewport, Window, WindowId,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;

pub const ABI_VERSION: u32 = 1;
pub const SAVE_VERSION: u32 = 1;
/// Compatibility alias for JSON ABI callers.
pub const VERSION: u32 = ABI_VERSION;
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Invalid(&'static str),
    /// A refusal whose text names the offending input, such as an action string.
    #[error("{0}")]
    Refused(String),
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
    fn full_rect(self) -> Rect {
        Rect::new(0.0, 0.0, self.width as f64, self.height as f64)
    }
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
    pub content_rect: Rect,
    pub original_rect: Rect,
    pub observed_rect: Rect,
    pub observation_known: bool,
    pub observation_revision: u64,
    pub capture_revision: Option<u64>,
    pub resize_disabled: bool,
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
    #[serde(skip)]
    seed: CameraSeed,
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
    /// The focused window whose request the adapter answered `focus_logical`:
    /// logical focus stands in for a native confirmation that cannot come.
    logical: Option<WindowId>,
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
    home_returns: BTreeMap<OutputId, ViewReturn>,
    overview_returns: BTreeMap<OutputId, ViewReturn>,
    /// Upstream bookmarks: name to the canvas point under the usable center,
    /// Y up. Saved. Unrelated to `Scene`'s camera-and-zoom bookmark map.
    bookmarks: BTreeMap<String, [f64; 2]>,
    /// Each output's active-bookmark incumbent. Ephemeral, like upstream's.
    active_bookmarks: BTreeMap<OutputId, String>,
    native_resize: Option<NativeResizeTransaction>,
    next_resize: u64,
    retired_resize_identities: Vec<SourceIdentity>,
    /// Upstream's configuration, the built-in defaults until a file is loaded.
    settings: Arc<Settings>,
    /// False until the first `load_config`. Until then nothing is seeded from
    /// the config and a scene file restores its bookmarks and cameras, as
    /// before configuration existed. From then on upstream's session rules hold.
    configured: bool,
    /// The physical chord of upstream's `logo` modifier.
    platform: Platform,
    /// The scene file's bookmark registry. With `session.restore_bookmarks` off
    /// runtime edits are ephemeral and a save carries this forward untouched.
    durable_bookmarks: BTreeMap<String, [f64; 2]>,
    /// The keyboard layout the shell last reported. Ephemeral, never saved.
    layout: Option<KeyboardLayout>,
    /// Upstream's `ipc_last_event_hash`: the last State event `state_event`
    /// returned. Ephemeral.
    last_event: Option<u64>,
    /// Stand-ins, close marks, pending relaunches and the launch adoption pass.
    lifecycle: Lifecycle,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub command: Command,
}
/// A window that exists but could not be offered, as `adoption_complete` names
/// it: by application and title, never by a native identity.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PresentWindow {
    pub bundle_id: String,
    pub title: String,
}
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Snapshot {},
    BeginNativeResize {
        window: WindowId,
        output: OutputId,
        edges: Edges,
        start_screen: Point,
        #[serde(default)]
        group: bool,
    },
    NativeResizeTo {
        transaction: u64,
        screen: Point,
    },
    EndNativeResize {
        transaction: u64,
    },
    CancelNativeResize {
        transaction: u64,
    },
    NativeResizeResult {
        transaction: u64,
        effect_id: u64,
        identity: SourceIdentity,
        generation: u64,
        result: NativeResizeResult,
    },
    RetireNativeResizeSource {
        transaction: u64,
        identity: SourceIdentity,
        generation: u64,
        lifetime_ended: bool,
    },
    InvalidateNativeCapture {
        window: WindowId,
        identity: SourceIdentity,
        generation: u64,
    },
    NativeResizeCaptureReady {
        window: WindowId,
        identity: SourceIdentity,
        generation: u64,
        observation_revision: u64,
        buffer: BufferSize,
        #[serde(default)]
        content_rect: Option<Rect>,
    },
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
    PanViewport {
        output: OutputId,
        direction: ViewDirection,
    },
    HomeToggle {
        output: OutputId,
    },
    ZoomIn {
        output: OutputId,
    },
    ZoomOut {
        output: OutputId,
    },
    ZoomReset {
        output: OutputId,
    },
    ZoomToFit {
        output: OutputId,
    },
    /// One upstream action string, as a key binding or `msg action` spells it.
    /// `pointer` is the pointer's global screen point. `held` says a real
    /// modifier is physically down as the action fires.
    Action {
        output: Option<OutputId>,
        action: String,
        #[serde(default)]
        pointer: Option<Point>,
        #[serde(default)]
        held: bool,
    },
    /// One upstream IPC request. `output` is the active output and `pointer`
    /// the pointer's global screen point.
    Ipc {
        output: Option<OutputId>,
        request: Value,
        #[serde(default)]
        pointer: Option<Point>,
    },
    /// A press on a window of the canvas, that press released as a completed
    /// click, or native focus the shell saw move to the window. `output` is
    /// the active output. `identity` and `generation`, when given, must be the
    /// window's current binding.
    Activate {
        window: WindowId,
        output: Option<OutputId>,
        cause: ActivationCause,
        #[serde(default)]
        identity: Option<SourceIdentity>,
        #[serde(default)]
        generation: Option<u64>,
    },
    /// A click on empty canvas: no window holds logical focus.
    ClearFocus {},
    /// Read upstream's config file. No `path` is upstream's own default path.
    LoadConfig {
        path: Option<String>,
    },
    /// Choose the physical chord of upstream's `logo` modifier.
    SetPlatform {
        #[serde(rename = "super")]
        super_chord: String,
    },
    /// The key bindings as macOS chords, and each output's armed hot corners.
    Bindings {},
    /// Run the action bound to one hot corner of one output. `pointer` and
    /// `held` are as `action` takes them.
    HotCorner {
        output: OutputId,
        corner: Corner,
        #[serde(default)]
        pointer: Option<Point>,
        #[serde(default)]
        held: bool,
    },
    /// The keyboard layout now in force, as the shell observed it.
    LayoutChanged {
        name: String,
        short: String,
        index: usize,
        count: usize,
    },
    /// The State event line for subscribers, when it changed. `output` is the
    /// active output.
    StateEvent {
        output: Option<OutputId>,
    },
    /// The pointer binding of one physical chord, button or scroll, and context.
    #[serde(rename = "mouse_binding")]
    PointerBinding {
        trigger: PointerTrigger,
        #[serde(default)]
        source: Option<ScrollSource>,
        modifiers: MacModifiers,
        context: PointerContext,
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
        /// The active output and the pointer, a global screen point. Read only
        /// for a new window: an attach with neither `logical_id` nor
        /// `world_rect`, which adopts a slot or is placed by the config.
        #[serde(default)]
        output: Option<OutputId>,
        #[serde(default)]
        pointer: Option<Point>,
    },
    /// The native window is gone. `output` is the active output, if known.
    WindowClosed {
        window: WindowId,
        identity: SourceIdentity,
        #[serde(default)]
        output: Option<OutputId>,
    },
    Retitle {
        window: WindowId,
        identity: SourceIdentity,
        title: String,
    },
    /// The shell has ended a discovery pass: every window on screen was
    /// offered. `present` names the windows that still exist but were not
    /// offered because they are not on screen: their slots keep waiting.
    AdoptionComplete {
        #[serde(default)]
        present: Vec<PresentWindow>,
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
    /// The adapter performs no native focus in this run (no Accessibility
    /// access, or `--no-native-focus`): the pending request is settled by
    /// logical focus alone. Nothing is claimed or recorded about native focus.
    FocusLogical {
        effect_id: u64,
        window: WindowId,
        identity: SourceIdentity,
        generation: u64,
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
#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
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
fn valid_pointer(pointer: Option<Point>) -> Result<Option<Point>, Error> {
    match pointer {
        Some(point) if !point_valid(point) => Err(Error::Invalid("invalid pointer")),
        pointer => Ok(pointer),
    }
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
        next.refresh_active_bookmarks();
        next.lifecycle
            .prune(&next.scene, &next.sources, next.navigation_clock);
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
            Command::BeginNativeResize {
                window,
                output,
                edges,
                start_screen,
                group,
            } => return self.begin_native_resize(window, output, edges, start_screen, group),
            Command::NativeResizeTo {
                transaction,
                screen,
            } => return self.native_resize_to(transaction, screen),
            Command::EndNativeResize { transaction } => {
                return self.finish_native_resize(transaction, false);
            }
            Command::CancelNativeResize { transaction } => {
                return self.finish_native_resize(transaction, true);
            }
            Command::NativeResizeResult {
                transaction,
                effect_id,
                identity,
                generation,
                result,
            } => {
                return self.native_resize_result(
                    transaction,
                    effect_id,
                    identity,
                    generation,
                    result,
                );
            }
            Command::RetireNativeResizeSource {
                transaction,
                identity,
                generation,
                lifetime_ended,
            } => {
                return self.retire_native_resize_source(
                    transaction,
                    identity,
                    generation,
                    lifetime_ended,
                );
            }
            Command::InvalidateNativeCapture {
                window,
                identity,
                generation,
            } => {
                self.check_generation(window, &identity, generation)?;
                let source = self.sources.get_mut(&window).expect("binding validated");
                // Revisions also fence capture authority loss without changing geometry.
                source.observation_revision = source
                    .observation_revision
                    .checked_add(1)
                    .ok_or(Error::Invalid("observation revisions exhausted"))?;
                source.capture_revision = None;
                return Ok(json!({"observation_revision":source.observation_revision}));
            }
            Command::NativeResizeCaptureReady {
                window,
                identity,
                generation,
                observation_revision,
                buffer,
                content_rect,
            } => {
                return self.native_resize_capture_ready(
                    window,
                    identity,
                    generation,
                    observation_revision,
                    buffer,
                    content_rect,
                );
            }
            Command::NavigateWindow {
                window,
                output,
                zoom_policy,
            } => {
                return Ok(self
                    .navigate_to_window(window, output, zoom_policy)?
                    .reply());
            }
            Command::CycleNavigate {
                output,
                backward,
                held,
            } => {
                if let Some(moved) = self.cycle_navigate(output, backward, held)? {
                    return Ok(moved.reply());
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
            Command::PanViewport { output, direction } => {
                return self.pan_viewport(output, direction);
            }
            Command::HomeToggle { output } => return self.home_toggle(output),
            Command::ZoomIn { output } => return self.zoom_in(output),
            Command::ZoomOut { output } => return self.zoom_out(output),
            Command::ZoomReset { output } => return self.zoom_reset(output),
            Command::ZoomToFit { output } => return self.zoom_to_fit(output),
            Command::Action {
                output,
                action,
                pointer,
                held,
            } => return self.action(output, &action, valid_pointer(pointer)?, held),
            Command::Ipc {
                output,
                request,
                pointer,
            } => return Ok(self.ipc(output, request, valid_pointer(pointer)?)),
            Command::Activate {
                window,
                output,
                cause,
                identity,
                generation,
            } => return self.activate(window, output, cause, identity, generation),
            Command::ClearFocus {} => return Ok(json!({"dirty":self.clear_focus()})),
            Command::LoadConfig { path } => return self.load_config(path),
            Command::SetPlatform { super_chord } => return self.set_platform(&super_chord),
            Command::Bindings {} => return Ok(self.bindings()),
            Command::HotCorner {
                output,
                corner,
                pointer,
                held,
            } => return self.hot_corner(output, corner, valid_pointer(pointer)?, held),
            Command::LayoutChanged {
                name,
                short,
                index,
                count,
            } => return self.layout_changed(name, short, index, count),
            Command::StateEvent { output } => return self.state_event(output),
            Command::PointerBinding {
                trigger,
                source,
                modifiers,
                context,
            } => return Ok(self.mouse_binding(trigger, source, modifiers, context)),
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
                // Upstream saved_camera_state: a camera read from the scene
                // file seeds its output only while `session.restore_camera` is
                // on. A camera of this session always survives a reconnect.
                let saved = self.outputs.get(&id);
                let previous = saved.map(|o| o.seed);
                let withheld = previous == Some(CameraSeed::File)
                    && self.configured
                    && !self.config().session.restore_camera;
                let viewport = match saved {
                    Some(o) if !withheld => Viewport {
                        screen_bounds,
                        ..o.viewport.clone()
                    },
                    _ => Viewport {
                        id,
                        camera: Point::default(),
                        zoom: 1.0,
                        screen_bounds,
                    },
                };
                // Shown before any config: the first config may still withhold it.
                let seed = match previous {
                    Some(CameraSeed::File | CameraSeed::FileShown) if !self.configured => {
                        CameraSeed::FileShown
                    }
                    _ => CameraSeed::Live,
                };
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
                        seed,
                    },
                );
                return Ok(json!({"output": id}));
            }
            Command::RemoveOutput { output } => {
                let resize = self.resize_output_removed(output)?;
                let viewport = self.scene.remove_output(output)?;
                self.flights.remove(&output);
                self.navigation_contexts.remove(&output);
                self.home_returns.remove(&output);
                self.overview_returns.remove(&output);
                self.outputs
                    .get_mut(&output)
                    .ok_or(Error::Invalid("missing output metadata"))?
                    .viewport = viewport;
                self.gesture = None;
                if let Some(result) = resize {
                    return Ok(result);
                }
            }
            Command::Attach {
                identity,
                bundle_id,
                title,
                buffer,
                source_rect,
                logical_id,
                world_rect,
                output,
                pointer,
            } => {
                identity.validate()?;
                if self.retired_resize_identities.iter().any(|old| {
                    old.pid == identity.pid
                        && old.birth_sec == identity.birth_sec
                        && old.birth_usec == identity.birth_usec
                        && old.wid == identity.wid
                }) {
                    return Err(Error::Invalid("source lifetime was retired"));
                }
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
                // A caller that names the slot or the world frame decides both
                // itself. Otherwise a new window has appeared.
                let arrival = match (logical_id, world_rect) {
                    (None, None) => {
                        Some(self.arrival(output, pointer, &bundle_id, &title, source_rect.size)?)
                    }
                    _ => None,
                };
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
                } else if let Some(Arrival::Adopt(id)) = arrival {
                    id
                } else {
                    self.next_window = self
                        .next_window
                        .checked_add(1)
                        .ok_or(Error::Invalid("window IDs exhausted"))?;
                    let id = WindowId(self.next_window);
                    let world_rect = match arrival {
                        Some(Arrival::Place { rect, .. }) => rect,
                        _ => world_rect.unwrap_or(source_rect),
                    };
                    self.scene.add_window(Window {
                        id,
                        world_rect,
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
                        content_rect: buffer.full_rect(),
                        original_rect: source_rect,
                        observed_rect: source_rect,
                        observation_known: true,
                        observation_revision: 0,
                        capture_revision: Some(0),
                        resize_disabled: false,
                    },
                );
                return match arrival {
                    Some(arrival) => self.settle_arrival(id, output, arrival),
                    None => Ok(json!({"window": id})),
                };
            }
            Command::WindowClosed {
                window,
                identity,
                output,
            } => return self.window_closed(window, identity, output),
            Command::Retitle {
                window,
                identity,
                title,
            } => return self.retitle(window, identity, title),
            Command::AdoptionComplete { present } => return self.adoption_complete(&present),
            Command::Observe {
                window,
                identity,
                source_rect,
                buffer,
            } => {
                self.guard_resize_structure(Some(window))?;
                self.fresh(window, &identity)?;
                buffer.validate()?;
                if !rect_valid(source_rect) {
                    return Err(Error::Invalid("invalid observed source rectangle"));
                }
                let source = self
                    .sources
                    .get_mut(&window)
                    .ok_or(Error::Invalid("unbound source"))?;
                let capture_metadata_changed = source.buffer.width != buffer.width
                    || source.buffer.height != buffer.height
                    || source.observed_rect.size != source_rect.size;
                let managed_capture = source.observation_revision > 0
                    || source.content_rect != source.buffer.full_rect();
                if capture_metadata_changed && managed_capture {
                    source.observation_revision = source
                        .observation_revision
                        .checked_add(1)
                        .ok_or(Error::Invalid("observation revisions exhausted"))?;
                    source.capture_revision = None;
                }
                // Unchanged observations retain the acknowledged crop. Legacy
                // full-buffer captures may reset synchronously; managed/cropped
                // captures require a new revision acknowledgement after change.
                if capture_metadata_changed {
                    source.content_rect = buffer.full_rect();
                }
                source.observed_rect = source_rect;
                source.buffer = buffer;
            }
            Command::RemoveSource {
                window,
                identity,
                keep_placeholder,
            } => {
                self.guard_resize_structure(Some(window))?;
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
                self.guard_resize_structure(Some(window))?;
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
                self.overview_returns.remove(&output);
                self.scene.pan(output, screen_delta)?;
                self.sync_output(output)?;
            }
            Command::Zoom {
                output,
                zoom,
                anchor,
            } => {
                self.flights.remove(&output);
                self.overview_returns.remove(&output);
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
                self.focus.logical = None;
                self.focus.release_pending = false;
            }
            Command::FocusLost {} => {
                self.scene.cancel_cycle();
                self.focus.pending_effect = None;
                self.focus.logical = None;
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
            Command::FocusLogical {
                effect_id,
                window,
                identity,
                generation,
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
                self.focus.last_result =
                    Some(json!({"effect": expected, "success": false, "logical": true}));
                // Upstream focus_changed: the focused window enters the history,
                // which a cycle in progress keeps frozen. `observed_native` is
                // left as it was.
                self.focus.logical = Some(window);
                self.scene.confirm_focus(window)?;
                if self.focus.release_pending {
                    self.finish_cycle();
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
                self.focus.logical = None;
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
                let snap = self.snap(zoom);
                self.flights.clear();
                self.gesture = Some(Gesture::Drag {
                    state: self
                        .scene
                        .begin_drag(window, snap.options, snap.break_force, group)?
                        .with_alignment(snap.corners, snap.centers),
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
                self.guard_resize_structure(None)?;
                if self.gesture.is_some() {
                    return Err(Error::Invalid("gesture already active"));
                }
                let zoom = self
                    .scene
                    .output(output)
                    .ok_or(Error::Invalid("unknown output"))?
                    .zoom;
                let snap = self.snap(zoom);
                self.flights.clear();
                self.gesture = Some(Gesture::Resize {
                    state: self
                        .scene
                        .begin_resize(window, edges.into(), snap.options, group)?
                        .with_break_force(snap.break_force)?
                        .with_same_edge(snap.corners),
                    zoom,
                    output,
                });
            }
            Command::GestureTo { screen_delta } => {
                if !point_valid(screen_delta) {
                    return Err(Error::Invalid("invalid gesture delta"));
                }
                let output = match self.gesture.as_ref() {
                    Some(Gesture::Drag { output, .. } | Gesture::Resize { output, .. }) => *output,
                    None => return Err(Error::Invalid("no active gesture")),
                };
                let current_zoom = self
                    .scene
                    .output(output)
                    .ok_or(Error::Invalid("unknown gesture output"))?
                    .zoom;
                let snap = self.snap(current_zoom);
                match self.gesture.as_mut().expect("gesture checked above") {
                    Gesture::Drag { state, zoom, .. } => {
                        state.set_snap_distances(snap.options.threshold, snap.break_force)?;
                        self.scene.drag_to(state, screen_delta / *zoom)?;
                    }
                    Gesture::Resize { state, zoom, .. } => {
                        state.set_snap_distances(snap.options.threshold, snap.break_force)?;
                        self.scene.resize_to(state, screen_delta / *zoom)?;
                    }
                }
            }
            Command::EndGesture {} => self.gesture = None,
            Command::Save { path } => {
                self.save(&path)?;
            }
            Command::Load { path } => {
                self.guard_resize_structure(None)?;
                let mut loaded = Self::load(&path)?;
                loaded.next_window = loaded.next_window.max(self.next_window);
                loaded.next_output = loaded.next_output.max(self.next_output);
                loaded.next_resize = self.next_resize;
                loaded.retired_resize_identities = self.retired_resize_identities.clone();
                loaded.next_effect = self.next_effect;
                loaded.next_navigation = self.next_navigation;
                loaded.next_generation = self.next_generation;
                // The launch pass happens once: a scene loaded after it brings
                // slots, which the next discovery pass decides, and windows
                // that appear are still focused and revealed.
                loaded.lifecycle.settled = self.lifecycle.settled;
                loaded.settings = self.settings.clone();
                loaded.platform = self.platform;
                loaded.configured = self.configured;
                loaded.layout = self.layout.clone();
                loaded.last_event = self.last_event;
                if loaded.configured {
                    loaded.seed_bookmarks();
                }
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
        self.focus.logical = None;
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
        // Only a confirmed current selection can be committed: one the adapter
        // observed, or one it answered `focus_logical`. A pending selection
        // must not accidentally promote the previous observation.
        let focused = self.scene.focused();
        if self.focus.pending_effect.is_none()
            && (self
                .focus
                .observed_native
                .as_ref()
                .is_some_and(|f| Some(f.window) == focused)
                || (focused.is_some() && self.focus.logical == focused))
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
        if self.focus.logical == Some(window) {
            self.focus.logical = None;
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
        if !source.observation_known || source.capture_revision != Some(source.observation_revision)
        {
            return Err(Error::Invalid("source presentation unsettled"));
        }
        if let Some(identity) = expected {
            self.fresh(hit.window, identity)?;
        }
        let world = self
            .scene
            .window(hit.window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let local = scale_point(hit.local, world.size, source.observed_rect.size);
        let buffer_local = source.content_rect.origin
            + scale_point(hit.local, world.size, source.content_rect.size);
        Ok(
            json!({"hit": {"window": hit.window, "output": output, "identity": source.identity, "local": local, "buffer_local": buffer_local, "native_screen": source.observed_rect.origin + local, "requires_native_revalidation": true}}),
        )
    }
    fn snapshot(&self) -> Result<Value, Error> {
        let placements: Vec<_> = self.scene.placements().iter().map(|p| {
            let source = self.sources.get(&p.window);
            let world_size = self.scene.window(p.window).expect("placement references scene window").world_rect.size;
            let settled = source.is_some_and(|s| s.observation_known && s.capture_revision == Some(s.observation_revision));
            let buffer_crop = source.filter(|_| settled).map(|s| { let mut crop = scale_rect(p.source_rect, world_size, s.content_rect.size); crop.origin = crop.origin + s.content_rect.origin; crop });
            json!({"window": p.window, "output": p.output, "screen_rect": p.screen_rect, "clip_rect": p.clip_rect, "world_local_crop": p.source_rect, "buffer_crop": buffer_crop, "presentation_settled": settled, "source": source})
        }).collect();
        let windows: Vec<_> = self.scene.windows().iter().map(|w| json!({"window": w.id, "world_rect": w.world_rect, "metadata": self.metadata.get(&w.id), "source": self.sources.get(&w.id)})).collect();
        Ok(
            json!({"evidence": "logical_controller_only", "capabilities": ["normal_window_navigation", "native_resize_controller_contract"], "native_resize": self.native_resize, "lifecycle": self.lifecycle, "navigation": {"flights": self.flights, "clock_ns": self.navigation_clock, "contexts": self.navigation_contexts, "home_returns": self.home_returns, "overview_returns": self.overview_returns, "active_bookmarks": self.active_bookmarks}, "bookmarks": self.bookmarks, "keyboard_layout": self.layout, "outputs": self.scene.outputs(), "windows": windows, "focused": self.scene.focused(), "focus": {"intent": self.scene.focused(), "observed_native": self.focus.observed_native, "pending_effect": self.focus.pending_effect, "last_result": self.focus.last_result, "history": self.scene.stage().focus_history(), "cycle": self.scene.stage().cycle_state(), "release_pending": self.focus.release_pending}, "placements": placements}),
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
