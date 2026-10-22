// SPDX-License-Identifier: GPL-3.0-or-later
//! Desktop scene controller. Native observations are ephemeral, never authority
//! to deliver an event. The native caller must validate ownership and process
//! birth immediately before and after event delivery.
mod actions;
mod bindings;
mod command_lookup;
mod effects;
mod ffi;
mod fullscreen;
mod gestures;
mod ipc;
mod ipc_client;
mod keyboard_layout;
mod lifecycle;
mod motion;
mod navigation;
mod observation;
mod output_actions;
mod passthrough;
mod pointer_policy;
mod render;
mod resize_transaction;
mod rules;
mod settings;
mod sizes;
mod storage;
mod taps;
mod view_actions;
mod window_actions;
use bindings::Platform;
pub use bindings::{MacModifiers, PointerContext, PointerTrigger, ScrollSource};
use effects::Effects;
pub use ffi::*;
use fullscreen::Fullscreen;
pub use gestures::GestureKind;
use gestures::{GestureStart, TrackpadGesture};
use keyboard_layout::KeyboardLayout;
use lifecycle::{Arrival, Lifecycle};
use motion::Motion;
pub use motion::{PanSource, PinchPhase, ZoomSource};
pub use navigation::{FocusPlacement, ZoomPolicy};
use navigation::{NavigationContext, ViewFlight};
pub use output_actions::Corner;
use passthrough::PinnedDrag;
use resize_transaction::NativeResizeTransaction;
pub use resize_transaction::{NativeResizeResult, ResizeOutcome};
use rules::Policy;
use settings::{CameraSeed, Settings};
use sizes::Sizes;
pub use view_actions::ViewDirection;
use view_actions::{ViewReturn, pixel_size};
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
        /// The pointer's total displacement, in screen points.
        delta: Point,
        /// World distance the camera has edge-panned under the held pointer.
        carried: Point,
        /// Which install this is: a move gesture drives only its own.
        serial: u64,
    },
    Resize {
        state: ResizeGesture,
        zoom: f64,
        output: OutputId,
        delta: Point,
    },
    /// The drag of a screen-pinned window, in screen space: the move
    /// binding's, and the move gesture's.
    Pinned(PinnedDrag),
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
    /// The requests hover focus made, oldest first, whose native answer may
    /// still arrive as an observation, each with the navigation clock it was
    /// made at. See `pointer_policy`.
    #[serde(skip)]
    hover: Vec<(FocusEffect, Option<u64>)>,
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
    /// Momentum, edge pans, cursor edge pan and a `zoom_by` pinch in progress.
    motion: Motion,
    /// The trackpad gesture in progress. Ephemeral, and apart from `gesture`,
    /// the pointer drag or resize a move gesture drives.
    trackpad_gesture: Option<TrackpadGesture>,
    /// Upstream's `trackpad_send_events`: a `set-trackpad` of this run, which
    /// outranks `[input.trackpad] enable`. Never saved.
    trackpad_override: Option<bool>,
    /// How many pointer drags have been installed: the serial of the latest.
    drags: u64,
    /// The window rules each window mapped with, and the screen-pinned windows.
    policy: Policy,
    /// Counts the accepted config reloads, the launch load when its file
    /// changed what the shell draws with, and every other load that changed
    /// the error bar's message. Not saved: it only tells the shell when to
    /// rebuild what it derived, the files it read included.
    render_revision: u64,
    /// The paths of the screenshot effects the shell has yet to answer,
    /// oldest first. Not saved.
    pending_screenshots: Vec<String>,
    /// Fit and fill restore points, the sizing action in flight and whether
    /// the shell can deliver a size at all. Ephemeral. See SIZES.md.
    sizes: Sizes,
    /// The error bar's message and the window events the shell animates.
    /// Not saved.
    effects: Effects,
    /// Each output's fullscreen window with what its exit restores, and the
    /// sizes exits still owe. Ephemeral. See FULLSCREEN.md.
    fullscreen: Fullscreen,
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
#[serde(rename_all = "snake_case")]
pub enum DecorationAction {
    Fit,
    Fullscreen,
    Fill,
    Restore,
    Center,
}
/// Adapter-chosen screen placement. It carries no native coordinate system or
/// ownership; `screen_pos` is local to the canvas output named here.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceScreenPin {
    pub output: OutputId,
    pub screen_pos: Point,
}
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Snapshot {},
    /// A native window control, addressed to its exact source rather than
    /// whichever window currently has canvas focus. Native geometry stays in
    /// the adapter that identified the control.
    NativeDecoration {
        window: WindowId,
        output: OutputId,
        identity: SourceIdentity,
        generation: u64,
        action: DecorationAction,
    },
    BeginNativeResize {
        window: WindowId,
        output: OutputId,
        /// The resize border's own edge. Absent, the edge is where in the
        /// window `start_screen` falls (upstream edges_from_position).
        #[serde(default)]
        edges: Option<Edges>,
        start_screen: Point,
        #[serde(default)]
        group: bool,
    },
    /// Upstream's resize border (`[mouse] resize_on_border`): is this screen
    /// point of `output` in the band around a window, and which edge is it.
    /// Read-only.
    ResizeBorder {
        output: OutputId,
        screen: Point,
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
    /// Whether the shell performs native readback resize effects in this run.
    /// False until startup announces it; never saved. See SIZES.md.
    NativeResizeCapability {
        enabled: bool,
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
    /// What the menu bar and the Dock leave of an output, in output-local
    /// points: upstream's usable area. Only the rectangle changes.
    SetUsableArea {
        output: OutputId,
        usable_rect_local: Rect,
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
    /// The shell's answer to a `screenshot` effect: the file it wrote and its
    /// pixel size, or why it wrote none.
    ScreenshotResult {
        #[serde(default)]
        path: Option<String>,
        #[serde(default)]
        width: Option<u32>,
        #[serde(default)]
        height: Option<u32>,
        #[serde(default)]
        error: Option<String>,
    },
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
    /// A bare modifier chord was pressed and released with nothing on top:
    /// run the tap binding on it. `modifiers` is the chord at its fullest.
    /// `pointer` and `held` are as `action` takes them.
    Tap {
        modifiers: MacModifiers,
        output: Option<OutputId>,
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
        /// The pointer is over a pick target in pick mode, as `hit` reported.
        #[serde(default)]
        pick: bool,
        /// The window under the pointer, as `hit` reports it: its
        /// `pass_mouse` may claim the trigger.
        #[serde(default)]
        window: Option<WindowId>,
    },
    /// The pointer moved over `output` with no button down, to the global
    /// point `screen`. `time_ms` is when, on the clock a timed `pan` carries:
    /// with it a scroll pan stops holding the pointer once its launch is due.
    Hover {
        output: OutputId,
        screen: Point,
        #[serde(default, deserialize_with = "motion::time_ms")]
        time_ms: Option<u32>,
    },
    /// A native adapter has freshly resolved the actual recipient to this
    /// bound source. Native stacking can differ from canvas stacking.
    HoverSource {
        window: WindowId,
        identity: SourceIdentity,
        generation: u64,
        output: OutputId,
        screen: Point,
        #[serde(default, deserialize_with = "motion::time_ms")]
        time_ms: Option<u32>,
        /// A captured view needs motion delivery after policy accepts it.
        /// The adapter still validates the exact native recipient at posting.
        #[serde(default)]
        forward_motion: bool,
    },
    /// A left click in pick mode, released without a drag.
    Pick {
        window: WindowId,
        output: OutputId,
    },
    /// A press bound to `center-nearest`, dragged from the global point
    /// `start` to `screen`. `held` is as `action` takes it.
    PointerNearest {
        output: OutputId,
        screen: Point,
        start: Point,
        #[serde(default)]
        held: bool,
    },
    RegisterOutput {
        stable_id: String,
        screen_bounds: Rect,
        /// The output's usable area, output-local. None is the whole output.
        #[serde(default)]
        usable_rect_local: Option<Rect>,
    },
    RemoveOutput {
        output: OutputId,
    },
    /// The shell has registered every display that exists: a pin whose own
    /// output is not among them moves to one that is.
    OutputsSettled {},
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
        /// An independently rooted overlay maps quietly in screen space.
        #[serde(default)]
        screen_pin: Option<SourceScreenPin>,
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
    /// Refresh the native presentation basis after an adapter-owned handoff
    /// without adopting its native size as a canvas resize.
    ObservePresentation {
        window: WindowId,
        identity: SourceIdentity,
        source_rect: Rect,
        buffer: BufferSize,
    },
    /// The source owner moved its unchanged-size window. The adapter supplies
    /// displacement in unscaled window units, separately from current native
    /// geometry. A deferred displacement is fenced against the world frame
    /// which first observed it, so later canvas placement supersedes it.
    RelocateSource {
        window: WindowId,
        identity: SourceIdentity,
        generation: u64,
        observed_rect: Rect,
        expected_world_rect: Rect,
        delta: Point,
    },
    RemoveSource {
        window: WindowId,
        identity: SourceIdentity,
        keep_placeholder: bool,
    },
    Forget {
        window: WindowId,
    },
    /// With `time_ms` the pan is upstream's drift_pan: scaled as its `source`
    /// is, and fed to momentum. Without it the camera moves by exactly
    /// `screen_delta / zoom` and nothing coasts.
    Pan {
        output: OutputId,
        screen_delta: Point,
        #[serde(default, deserialize_with = "motion::time_ms")]
        time_ms: Option<u32>,
        #[serde(default)]
        source: Option<PanSource>,
    },
    /// The fingers lifted or the button was released: launch momentum.
    PanEnd {
        output: OutputId,
        #[serde(default, deserialize_with = "motion::time_ms")]
        time_ms: Option<u32>,
    },
    /// Where the pointer is, for cursor edge pan. No `output` is no output.
    Pointer {
        output: Option<OutputId>,
        screen: Point,
    },
    /// Upstream's wheel or pinch zoom around the global screen point `anchor`.
    ZoomBy {
        output: OutputId,
        anchor: Point,
        delta: f64,
        source: ZoomSource,
        #[serde(default)]
        phase: Option<PinchPhase>,
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
        /// The pointer's global screen point: a window drag edge-pans by it.
        #[serde(default)]
        pointer: Option<Point>,
    },
    EndGesture {},
    /// A trackpad gesture as libinput reports one: it begins with a finger
    /// count, where the pointer is and what is held. See GESTURES.md.
    GestureBegin {
        kind: GestureKind,
        fingers: u32,
        modifiers: MacModifiers,
        context: PointerContext,
        output: OutputId,
        pointer: Point,
        /// A three-finger tap ended just before this swipe began.
        #[serde(default)]
        doubletap: bool,
        time_ms: f64,
    },
    /// A swipe's `dx` and `dy`; a pinch's `scale` since it began. `held` is
    /// as `action` takes it, for the action this event may fire.
    GestureUpdate {
        #[serde(default)]
        dx: f64,
        #[serde(default)]
        dy: f64,
        #[serde(default = "gestures::unit_scale")]
        scale: f64,
        #[serde(default)]
        rotation: f64,
        time_ms: f64,
        #[serde(default)]
        held: bool,
    },
    GestureEnd {
        #[serde(default)]
        cancelled: bool,
        time_ms: f64,
        #[serde(default)]
        held: bool,
    },
    Save {
        path: String,
    },
    Load {
        path: String,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
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
impl Edges {
    pub(crate) fn left(self) -> bool {
        matches!(self, Self::Left | Self::TopLeft | Self::BottomLeft)
    }
    pub(crate) fn right(self) -> bool {
        matches!(self, Self::Right | Self::TopRight | Self::BottomRight)
    }
    pub(crate) fn top(self) -> bool {
        matches!(self, Self::Top | Self::TopLeft | Self::TopRight)
    }
    pub(crate) fn bottom(self) -> bool {
        matches!(self, Self::Bottom | Self::BottomLeft | Self::BottomRight)
    }
    pub(crate) fn horizontal(self) -> bool {
        self.left() || self.right()
    }
    pub(crate) fn vertical(self) -> bool {
        self.top() || self.bottom()
    }
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
        if request.version != ABI_VERSION {
            return Err(Error::Invalid("unsupported desktop schema"));
        }
        // Construction and successful mutations leave state settled. These
        // queries borrow it directly, without cloning or changing the state
        // that the native caller may already have decoded from a snapshot.
        match &request.command {
            Command::Snapshot {} => return self.pointer_snapshot(),
            Command::Hit { output, screen } => return self.pointer_hit(*output, *screen, None),
            Command::Input {
                output,
                screen,
                identity,
            } => return self.pointer_hit(*output, *screen, Some(identity)),
            Command::ResizeBorder { output, screen } => {
                return Ok(json!({"border":self.resize_border(*output, *screen)}));
            }
            Command::TickNavigation { timestamp_ns } if self.navigation_clock_only() => {
                // No timed settlement or scene mutation is possible here.
                // Validate the clock before its sole write, without cloning
                // every window or revalidating an unchanged settled scene.
                return self.tick_navigation_clock(*timestamp_ns);
            }
            _ => {}
        }
        let mut next = self.clone();
        let carries = fullscreen::carries(&request.command);
        let mut result = next.apply(request.command)?;
        // A size a fullscreen exit still owes leaves with a reply the shell
        // performs size transactions from.
        if carries {
            next.carry_owed(&mut result);
        }
        next.settle_state()?;
        *self = next;
        Ok(result)
    }
    fn settle_state(&mut self) -> Result<(), Error> {
        // Fullscreen restoration reads close marks. Prune them first so an
        // expired mark is settled by the mutation that advances the clock,
        // without depending on a later snapshot to finish that transition.
        self.lifecycle
            .prune(&self.scene, &self.sources, self.navigation_clock);
        self.settle_fullscreen()?;
        self.settle_policy()?;
        self.scene.validate()?;
        self.refresh_active_bookmarks();
        self.prune_sizes();
        Ok(())
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
        // Upstream's execute_action prelude: a view action stops its output's
        // scroll momentum whether or not it then arms a flight.
        if let Command::PanViewport { output, .. }
        | Command::HomeToggle { output }
        | Command::ZoomIn { output }
        | Command::ZoomOut { output }
        | Command::ZoomReset { output }
        | Command::ZoomToFit { output } = &command
        {
            self.stop_momentum(*output);
            // Upstream's guard, as `run` applies it to the same six actions.
            let was_fullscreen = self.exit_fullscreen_on(*output);
            if let Command::HomeToggle { output } = &command {
                let mut outcome = actions::Outcome::default();
                let mut reply =
                    self.home_toggle_fullscreen(*output, was_fullscreen, &mut outcome)?;
                // A return into fullscreen asks the window for the focus and
                // the output's size: both leave with the reply, the size
                // transaction under the keys the action's reply has.
                if !outcome.effects.is_empty() {
                    reply["effects"] = Value::Array(outcome.effects);
                }
                return Ok(sizes::carry(reply, outcome.resize));
            }
        }
        // Upstream's pointer path: a bound pan or zoom and a grab end the
        // fullscreen of the output they act on, and run on the restored canvas.
        match &command {
            Command::Pan { output, .. }
            | Command::Zoom { output, .. }
            | Command::ZoomBy { output, .. } => self.fullscreen_grab(*output, None)?,
            Command::BeginDrag { window, output, .. }
            | Command::BeginResize { window, output, .. }
            | Command::BeginNativeResize { window, output, .. } => {
                self.fullscreen_grab(*output, Some(*window))?
            }
            _ => {}
        }
        match command {
            Command::Snapshot {} => return self.pointer_snapshot(),
            Command::NativeDecoration {
                window,
                output,
                identity,
                generation,
                action,
            } => return self.native_decoration(window, output, &identity, generation, &action),
            Command::BeginNativeResize {
                window,
                output,
                edges,
                start_screen,
                group,
            } => return self.begin_native_resize(window, output, edges, start_screen, group),
            Command::ResizeBorder { output, screen } => {
                return Ok(json!({"border":self.resize_border(output, screen)}));
            }
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
                return self.sizing_result(transaction, effect_id, identity, generation, result);
            }
            Command::NativeResizeCapability { enabled } => {
                self.sizes.capability = enabled;
                // No size can be delivered: no rule's `size` waits for one.
                if !enabled {
                    self.policy.sizing.clear();
                }
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
                self.cancel_navigation(output);
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
            Command::SetUsableArea {
                output,
                usable_rect_local,
            } => {
                self.set_usable_area(output, usable_rect_local)?;
                // Upstream re-clamps nothing: no saved state changes.
                return Ok(json!({"dirty": false}));
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
            Command::ScreenshotResult {
                path,
                width,
                height,
                error,
            } => return self.screenshot_result(path, width, height, error),
            Command::LoadConfig { path } => return self.pointer_config(path),
            Command::SetPlatform { super_chord } => return self.set_platform(&super_chord),
            Command::Bindings {} => return Ok(self.bindings()),
            Command::HotCorner {
                output,
                corner,
                pointer,
                held,
            } => return self.hot_corner(output, corner, valid_pointer(pointer)?, held),
            Command::Tap {
                modifiers,
                output,
                pointer,
                held,
            } => return self.tap(modifiers, output, valid_pointer(pointer)?, held),
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
                pick,
                window,
            } => {
                return Ok(self.pointer_binding(trigger, source, modifiers, context, pick, window));
            }
            Command::Hover {
                output,
                screen,
                time_ms,
            } => return self.hover(output, screen, time_ms),
            Command::HoverSource {
                window,
                identity,
                generation,
                output,
                screen,
                time_ms,
                forward_motion,
            } => {
                self.check_generation(window, &identity, generation)?;
                return self.hover_with_target(
                    output,
                    screen,
                    time_ms,
                    Some(window),
                    forward_motion,
                );
            }
            Command::Pick { window, output } => return self.pick(window, output),
            Command::PointerNearest {
                output,
                screen,
                start,
                held,
            } => return self.pointer_nearest(output, screen, start, held),
            Command::RegisterOutput {
                stable_id,
                screen_bounds,
                usable_rect_local,
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
                // A display that comes back as it was keeps its pins where
                // they are. One first seen in this run, or back at another
                // size, has them moved inward.
                let resized = saved.is_some_and(|o| {
                    pixel_size(o.viewport.screen_bounds.size).ok()
                        != pixel_size(screen_bounds.size).ok()
                });
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
                let connected = self.scene.output(id).is_none();
                if connected {
                    self.scene.add_output(viewport.clone())?;
                } else {
                    self.scene.update_output(viewport.clone())?;
                }
                self.flights.remove(&id);
                self.navigation_contexts.remove(&id);
                if let Some(usable) = usable_rect_local {
                    self.set_usable_area(id, usable)?;
                }
                self.motion.forget(id);
                self.outputs.insert(
                    id,
                    SavedOutput {
                        stable_id,
                        viewport,
                        seed,
                    },
                );
                if connected && (previous == Some(CameraSeed::File) || resized) {
                    self.output_connected(id);
                }
                return Ok(json!({"output": id}));
            }
            Command::OutputsSettled {} => {
                // A fullscreen whose output is gone ends first: its window may
                // be pinned again, to that output.
                let ended = self.fullscreen_outputs_settled();
                return Ok(json!({"dirty": self.rehome_pins() || ended}));
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
                self.drop_gesture();
                self.motion.forget(output);
                self.drop_output_gesture(output);
                // Its pins stay bound to it, drawn nowhere: the shell removes
                // every output on any reconfiguration, so only
                // `outputs_settled` knows which displays are really gone.
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
                screen_pin,
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
                // A caller that names the slot or the world frame decides both
                // itself. Otherwise a new window has appeared.
                // Upstream resolves a window's rules once, when it maps: the
                // bundle identifier is the rule's `app_id`.
                let rule = self.config().resolve_window_rules(&bundle_id, &title);
                // `ruled`: the window is placed for the size its rule names.
                let screen_arrival = screen_pin
                    .as_ref()
                    .map(|pin| self.screen_pin_arrival(pin, source_rect.size))
                    .transpose()?;
                let (mut arrival, ruled) = match (logical_id, world_rect) {
                    (None, None) => {
                        let (arrival, ruled) = self.arrival_by_rule(
                            output,
                            pointer,
                            &bundle_id,
                            &title,
                            source_rect.size,
                            rule.as_ref(),
                        )?;
                        (Some(arrival), ruled)
                    }
                    _ => (None, false),
                };
                if screen_arrival.is_some()
                    && logical_id.is_none()
                    && !matches!(arrival, Some(Arrival::Adopt(_)))
                {
                    arrival = screen_arrival;
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
                } else if let Some(Arrival::Adopt(id)) = arrival {
                    id
                } else {
                    self.next_window = self
                        .next_window
                        .checked_add(1)
                        .ok_or(Error::Invalid("window IDs exhausted"))?;
                    let id = WindowId(self.next_window);
                    let world_rect = match arrival {
                        Some(Arrival::Place { rect, .. } | Arrival::Pin { rect, .. }) => rect,
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
                    },
                );
                self.map_rule(id, rule, arrival);
                if let Some(Arrival::Pin { pin, rect }) = screen_arrival {
                    // A saved screen pin retains its display and position. New
                    // utility overlays do not activate, reveal or resize a
                    // window merely because it appeared.
                    self.policy.pins.entry(id).or_insert(pin);
                    self.scene.drop_focus_history(id);
                    let arrived = arrival.unwrap_or(Arrival::Pin { pin, rect });
                    self.log_arrival(id, output, arrived)?;
                    return Ok(
                        json!({"window":id,"adopted":matches!(arrived, Arrival::Adopt(_)),"effect":null,"navigation":null,"dirty":true}),
                    );
                }
                // A slot under a drag or resize that its window's rule has
                // just made a widget lets go of the gesture. A pinned slot
                // keeps its pin, and with it the drag that is moving it.
                if self.is_widget(id) {
                    self.release_gesture(id);
                }
                return match arrival {
                    Some(arrival) => {
                        // `own`: the window was placed for the size its
                        // rule names, and has this one.
                        let own = ruled.then_some(source_rect.size);
                        // Upstream's deferred fullscreen: a rule's
                        // `fullscreen` takes the place of the navigation,
                        // and of the size arm, whose size it then owes.
                        if let Some(reply) = self.fullscreen_by_rule(id, output, arrival, own) {
                            return Ok(reply);
                        }
                        let reply = self.settle_arrival(id, output, arrival)?;
                        // Upstream's size arm: a rule's `size`, placed for.
                        Ok(self.size_by_rule(id, output, own, reply))
                    }
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
            Command::RelocateSource {
                window,
                identity,
                generation,
                observed_rect,
                expected_world_rect,
                delta,
            } => {
                return self.relocate_source(
                    window,
                    &identity,
                    generation,
                    observed_rect,
                    expected_world_rect,
                    delta,
                );
            }
            Command::Observe {
                window,
                identity,
                source_rect,
                buffer,
            } => {
                return self.observe_source(window, &identity, source_rect, buffer, true);
            }
            Command::ObservePresentation {
                window,
                identity,
                source_rect,
                buffer,
            } => {
                return self.observe_source(window, &identity, source_rect, buffer, false);
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
                self.drop_gesture();
            }
            Command::Forget { window } => {
                self.guard_resize_structure(Some(window))?;
                // The shell's own dismissal of a placeholder. What is drawn
                // as a stand-in fades as a dismissed one does (effects.rs);
                // a bound window is none, and its removal animates nothing.
                let standin = !self.sources.contains_key(&window);
                self.scene.remove_window(window)?;
                if standin {
                    self.log_dismiss(window, None)?;
                }
                self.metadata.remove(&window);
                self.invalidate_focus(window);
                self.sources.remove(&window);
                self.drop_gesture();
            }
            Command::Pan {
                output,
                screen_delta,
                time_ms: Some(time_ms),
                source,
            } => self.drift_pan(output, screen_delta, time_ms, source)?,
            // A direct move of the camera: it ends a coast and banks none.
            Command::Pan {
                output,
                screen_delta,
                time_ms: None,
                ..
            } => {
                self.cancel_animations(output);
                self.overview_returns.remove(&output);
                self.scene.pan(output, screen_delta)?;
                self.sync_output(output)?;
            }
            Command::PanEnd { output, time_ms } => return self.pan_end(output, time_ms),
            Command::Pointer { output, screen } => return self.report_pointer(output, screen),
            Command::ZoomBy {
                output,
                anchor,
                delta,
                source,
                phase,
            } => return self.zoom_by(output, anchor, delta, source, phase),
            Command::Zoom {
                output,
                zoom,
                anchor,
            } => {
                self.cancel_animations(output);
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
                    self.confirm_focus(window)?;
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
                self.confirm_focus(window)?;
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
                self.confirm_focus(window)?;
                self.focus.observed_native = Some(FocusEffect {
                    op: "observed_native_focus",
                    effect_id: 0,
                    window,
                    identity,
                    generation,
                });
            }
            Command::Hit { output, screen } => return self.pointer_hit(output, screen, None),
            Command::Input {
                output,
                screen,
                identity,
            } => return self.pointer_hit(output, screen, Some(&identity)),
            Command::BeginDrag {
                window,
                output,
                group,
            } => {
                let effect = self.focus_for_grab(window)?;
                self.install_drag(window, output, group)?;
                return Ok(json!({"effect": effect}));
            }
            Command::BeginResize {
                window,
                output,
                edges,
                group,
            } => {
                let effect = self.focus_for_grab(window)?;
                self.guard_resize_structure(None)?;
                if self.gesture.is_some() {
                    return Err(Error::Invalid("gesture already active"));
                }
                self.movable(window)?;
                let zoom = self
                    .scene
                    .output(output)
                    .ok_or(Error::Invalid("unknown output"))?
                    .zoom;
                let snap = self.snap(zoom);
                self.cancel_animations_everywhere();
                self.gesture = Some(Gesture::Resize {
                    state: self
                        .scene
                        .begin_resize(window, edges.into(), snap.options, group)?
                        .with_break_force(snap.break_force)?
                        .with_same_edge(snap.corners),
                    zoom,
                    output,
                    delta: Point::default(),
                });
                // Upstream begin_client_resize: a resize drag ends fit and fill.
                self.sizes.resize_begun(window);
                // And a wait for a rule's `size`, as any sizing of the user's,
                // and the size a fullscreen exit still owed the window.
                self.policy.sizing.retain(|queued| *queued != window);
                self.fullscreen.restored(window);
                return Ok(json!({"effect": effect}));
            }
            Command::GestureTo {
                screen_delta,
                pointer,
            } => {
                self.pointer_gesture_to(screen_delta, pointer)?;
                return Ok(json!({"needs_frames":self.needs_frames()}));
            }
            Command::EndGesture {} => self.drop_gesture(),
            Command::GestureBegin {
                kind,
                fingers,
                modifiers,
                context,
                output,
                pointer,
                doubletap,
                time_ms,
            } => {
                return self.gesture_begin(GestureStart {
                    kind,
                    fingers,
                    modifiers,
                    context,
                    output,
                    pointer,
                    doubletap,
                    time_ms,
                });
            }
            Command::GestureUpdate {
                dx,
                dy,
                scale,
                rotation,
                time_ms,
                held,
            } => {
                return self.gesture_update(Point::new(dx, dy), scale, rotation, time_ms, held);
            }
            Command::GestureEnd {
                cancelled,
                time_ms,
                held,
            } => return self.gesture_end(cancelled, time_ms, held),
            Command::Save { path } => {
                self.save(&path)?;
            }
            Command::Load { path } => {
                self.guard_resize_structure(None)?;
                let mut loaded = Self::load(&path)?;
                loaded.next_window = loaded.next_window.max(self.next_window);
                loaded.next_output = loaded.next_output.max(self.next_output);
                loaded.next_resize = self.next_resize;
                loaded.next_effect = self.next_effect;
                loaded.next_navigation = self.next_navigation;
                loaded.next_generation = self.next_generation;
                // The launch pass happens once: a scene loaded after it brings
                // slots, which the next discovery pass decides, and windows
                // that appear are still focused and revealed.
                loaded.lifecycle.settled = self.lifecycle.settled;
                loaded.settings = self.settings.clone();
                loaded.render_revision = self.render_revision;
                loaded.pending_screenshots = std::mem::take(&mut self.pending_screenshots);
                loaded.effects = std::mem::take(&mut self.effects);
                loaded.platform = self.platform;
                loaded.configured = self.configured;
                loaded.layout = self.layout.clone();
                loaded.last_event = self.last_event;
                loaded.motion.cursor_pan = self.motion.cursor_pan;
                loaded.trackpad_override = self.trackpad_override;
                loaded.sizes.capability = self.sizes.capability;
                if loaded.configured {
                    loaded.seed_bookmarks();
                }
                *self = loaded;
            }
        }
        Ok(json!({}))
    }
    /// Install the pointer drag of one window, for a bound button press and
    /// for a move gesture alike. Upstream's grab install cancels every
    /// output's flight and momentum.
    fn install_drag(
        &mut self,
        window: WindowId,
        output: OutputId,
        group: bool,
    ) -> Result<(), Error> {
        if self.gesture.is_some() {
            return Err(Error::Invalid("gesture already active"));
        }
        // A screen-pinned window is dragged in screen space, unless it is a
        // widget too: a widget is refused on every path. `movable` is the
        // guard of everything else.
        let pinned = self.is_pinned(window) && !self.is_widget(window);
        if !pinned {
            self.movable(window)?;
        }
        let zoom = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .zoom;
        let snap = self.snap(zoom);
        // A sizing action still owed its size places this window itself: no
        // drag of it is installed meanwhile, a pinned one included. A pinned
        // window has no cluster to ask about.
        self.guard_sizing_drag(window, group && !pinned, snap.options)?;
        // Pick mode's drag-anywhere is this command too, sent without a
        // binding. A pinned window is never a pick target, and its drag is
        // the same below `zoom.interact_min` as above: it reads no zoom.
        if pinned {
            return self.install_pinned_drag(window, output);
        }
        self.cancel_animations_everywhere();
        self.drags += 1;
        self.gesture = Some(Gesture::Drag {
            state: self
                .scene
                .begin_drag(window, snap.options, snap.break_force, group)?
                .with_alignment(snap.corners, snap.centers),
            zoom,
            output,
            delta: Point::default(),
            carried: Point::default(),
            serial: self.drags,
        });
        // Upstream's move grabs: re-anchoring ends a fill restore point, the
        // dragged window's and that of every member dragged along.
        self.drag_begun(window, group, snap.options)?;
        Ok(())
    }
    /// Move the installed drag or resize to a total screen displacement from
    /// where it began. With `pointer`, the pointer's global screen point, a
    /// window drag then arms its edge pan, as upstream's move grab does for a
    /// held button and for a move gesture's warped cursor alike.
    fn pointer_gesture_to(
        &mut self,
        screen_delta: Point,
        pointer: Option<Point>,
    ) -> Result<(), Error> {
        if !point_valid(screen_delta) || pointer.is_some_and(|p| !point_valid(p)) {
            return Err(Error::Invalid("invalid gesture delta"));
        }
        match self.gesture.as_mut() {
            Some(Gesture::Drag { delta, .. } | Gesture::Resize { delta, .. }) => {
                *delta = screen_delta;
            }
            Some(Gesture::Pinned(_)) => return self.drag_pinned(screen_delta, pointer),
            None => return Err(Error::Invalid("no active gesture")),
        }
        self.drive_gesture()?;
        // Upstream's move grab: place the window, then arm the edge pan.
        if let (Some(Gesture::Drag { output, .. }), Some(pointer)) =
            (self.gesture.as_ref(), pointer)
        {
            let output = *output;
            let origin = self
                .scene
                .output(output)
                .ok_or(Error::Invalid("unknown gesture output"))?
                .screen_bounds
                .origin;
            self.arm_drag_edge_pan(output, pointer - origin)?;
        }
        Ok(())
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
    /// Upstream update_focus_history's eligibility: a focus the adapter
    /// confirmed or observed, or answered `focus_logical`, enters the focus
    /// history, the one `cycle-windows` walks and a close follows. A widget
    /// and a screen-pinned window take the focus without entering it; a
    /// fullscreen window enters it like any other.
    pub(crate) fn confirm_focus(&mut self, window: WindowId) -> Result<(), Error> {
        if self.in_history(window) {
            self.scene.confirm_focus(window)?;
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
    /// Place the gesture's windows for its last pointer displacement, at the
    /// zoom the gesture began at. A drag adds the world distance its output
    /// has edge-panned under the held pointer.
    fn drive_gesture(&mut self) -> Result<(), Error> {
        let output = match self.gesture.as_ref() {
            Some(Gesture::Drag { output, .. } | Gesture::Resize { output, .. }) => *output,
            // A pinned drag is placed by its own pointer reports alone.
            Some(Gesture::Pinned(_)) => return Ok(()),
            None => return Err(Error::Invalid("no active gesture")),
        };
        let current_zoom = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown gesture output"))?
            .zoom;
        let snap = self.snap(current_zoom);
        match self.gesture.as_mut().expect("gesture checked above") {
            Gesture::Drag {
                state,
                zoom,
                delta,
                carried,
                ..
            } => {
                state.set_snap_distances(snap.options.threshold, snap.break_force)?;
                self.scene.drag_to(state, *delta / *zoom + *carried)?;
            }
            Gesture::Resize {
                state, zoom, delta, ..
            } => {
                state.set_snap_distances(snap.options.threshold, snap.break_force)?;
                self.scene.resize_to(state, *delta / *zoom)?;
                // Upstream apply_member_shifts: a shifted member is re-anchored.
                self.sizes.drop_moved_fills(&self.scene);
            }
            Gesture::Pinned(_) => {}
        }
        Ok(())
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
        let Some((window, at)) = self.hit_window(output, screen) else {
            if expected.is_some() {
                return Err(Error::Invalid("input does not hit a source"));
            }
            return Ok(json!({"hit": null}));
        };
        let source = self
            .sources
            .get(&window)
            .ok_or(Error::Invalid("unbound source"))?;
        if !source.observation_known {
            return Err(Error::Invalid("source presentation unsettled"));
        }
        if let Some(identity) = expected {
            self.fresh(window, identity)?;
        }
        let world = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let local = scale_point(at, world.size, source.observed_rect.size);
        let buffer_local =
            source.content_rect.origin + scale_point(at, world.size, source.content_rect.size);
        Ok(
            json!({"hit": {"window": window, "output": output, "identity": source.identity, "local": local, "buffer_local": buffer_local, "native_screen": source.observed_rect.origin + local, "requires_native_revalidation": true, "widget": self.is_widget(window), "pinned": self.is_pinned(window)}}),
        )
    }
    fn snapshot(&self) -> Result<Value, Error> {
        // What each window is drawn with: additive keys of its entry, repeated
        // on each of its placements. A window on no output has no placement
        // and can still be captured, so the entry carries them too.
        let drawn: BTreeMap<WindowId, Value> = self
            .scene
            .windows()
            .iter()
            .map(|w| (w.id, self.drawn(w.id)))
            .collect();
        let describe = |mut entry: Value, window: WindowId| {
            if let (Some(entry), Some(Value::Object(drawn))) =
                (entry.as_object_mut(), drawn.get(&window))
            {
                entry.extend(drawn.clone());
            }
            entry
        };
        // Bottom to top within each output: widgets, canvas windows, the
        // windows pinned to it. `opacity` and `decoration.opacity` are one
        // function's answer.
        // A fullscreen output has one placement, its fullscreen window's, in
        // the output's screen space and marked `fullscreen`.
        let placements: Vec<_> = self.layered_placements().iter().map(|(p, pinned)| {
            let source = self.sources.get(&p.window);
            let world_size = self.scene.window(p.window).expect("placement references scene window").world_rect.size;
            let settled = source.is_some_and(|s| s.observation_known);
            let buffer_crop = source.filter(|_| settled).map(|s| { let mut crop = scale_rect(p.source_rect, world_size, s.content_rect.size); crop.origin = crop.origin + s.content_rect.origin; crop });
            let mut placement = json!({"window": p.window, "output": p.output, "screen_rect": p.screen_rect, "clip_rect": p.clip_rect, "world_local_crop": p.source_rect, "buffer_crop": buffer_crop, "presentation_settled": settled, "source": source, "pinned": pinned, "widget": self.is_widget(p.window), "opacity": self.opacity_of(p.window)});
            if self.fullscreen_on(p.output) == Some(p.window) { placement["fullscreen"] = json!(true); }
            describe(placement, p.window)
        }).collect();
        let windows: Vec<_> = self.scene.windows().iter().map(|w| {
            let (widget, pinned, rule) = self.policy_json(w.id);
            describe(json!({"window": w.id, "world_rect": w.world_rect, "metadata": self.metadata.get(&w.id), "source": self.sources.get(&w.id), "widget": widget, "pinned": pinned, "rule": rule, "mode": self.mode_name(w.id)}), w.id)
        }).collect();
        let mut navigation = json!({"flights": self.flights, "clock_ns": self.navigation_clock, "contexts": self.navigation_contexts, "home_returns": self.home_returns, "overview_returns": self.overview_returns, "active_bookmarks": self.active_bookmarks});
        for (key, value) in self.motion.snapshot() {
            navigation[key] = value;
        }
        Ok(
            json!({"evidence": "logical_controller_only", "capabilities": ["normal_window_navigation", "native_resize_controller_contract"], "render": self.render_block(), "native_resize": self.native_resize, "lifecycle": self.lifecycle, "lifecycle_events": self.lifecycle_events(), "navigation": navigation, "bookmarks": self.bookmarks, "keyboard_layout": self.layout, "trackpad": self.trackpad_snapshot(), "outputs": self.scene.outputs(), "windows": windows, "pass_keys": self.pass_keys(), "focus": {"intent": self.scene.focused(), "observed_native": self.focus.observed_native, "pending_effect": self.focus.pending_effect, "last_result": self.focus.last_result, "history": self.scene.stage().focus_history(), "cycle": self.scene.stage().cycle_state(), "release_pending": self.focus.release_pending}, "placements": placements}),
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
