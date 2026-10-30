// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/grabs/resize_grab.rs (constrain_to_ratio, locked_ratio_for, and the
// pointer clamp and integer delta of ResizeGrab::motion and apply_resize) and
// src/input/pointer.rs (edges_from_position). The grab itself is this file's
// transaction: upstream configures a client and draws what it commits, and
// here a size is asked of a native window and the size read back is drawn.
//! Native resize transactions. Effects are obligations, not native evidence.
use super::*;

/// Upstream edges_from_position: a 3×3 grid over the window, corners resizing
/// diagonally, edge strips along one axis, the centre from the bottom right.
/// Canvas coordinates, as upstream's.
fn edges_from_position(at: Point, rect: Rect) -> Edges {
    let (x, y) = (at.x - rect.origin.x, at.y - rect.origin.y);
    let (w, h) = (rect.size.width, rect.size.height);
    let (left, right) = (x < w / 3.0, x > w * 2.0 / 3.0);
    let (top, bottom) = (y < h / 3.0, y > h * 2.0 / 3.0);
    match (left, right, top, bottom) {
        (true, _, true, _) => Edges::TopLeft,
        (_, true, true, _) => Edges::TopRight,
        (true, _, _, true) => Edges::BottomLeft,
        (_, true, _, true) => Edges::BottomRight,
        (true, _, _, _) => Edges::Left,
        (_, true, _, _) => Edges::Right,
        (_, _, true, _) => Edges::Top,
        (_, _, _, true) => Edges::Bottom,
        _ => Edges::BottomRight,
    }
}
/// Upstream constrain_to_ratio: `target` bent to `ratio` (width / height). A
/// horizontal edge drives the width, a vertical edge the height, and a corner
/// the axis that moved farther from `initial` relative to the ratio, so the
/// driver does not flip as the pointer crosses the ratio ray. The other axis
/// is derived, rounded, and at least 1.
fn constrain_to_ratio(target: Size, initial: Size, ratio: f64, edges: Edges) -> Size {
    let width_drives = match (edges.horizontal(), edges.vertical()) {
        (true, false) => true,
        (false, true) => false,
        _ => {
            let dw = (target.width - initial.width).abs();
            let dh = (target.height - initial.height).abs();
            dw * initial.height >= dh * initial.width
        }
    };
    if width_drives {
        Size::new(target.width, (target.width / ratio).round().max(1.0))
    } else {
        Size::new((target.height * ratio).round().max(1.0), target.height)
    }
}

/// Whole native units toward zero, retaining a mathematically whole movement
/// after screen/world projection has introduced floating-point roundoff.
fn native_delta(value: f64, precision: f64) -> f64 {
    let whole = value.round();
    if (value - whole).abs() <= precision {
        whole
    } else {
        value.trunc()
    }
}

/// A world point kept as an origin and a local offset. Adding a fractional
/// press offset to a distant camera would discard precision before motion.
#[derive(Clone, Debug, Default, Serialize)]
struct ResizePointerAnchor {
    origin: Point,
    offset: Point,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ResizeOutcome {
    Observed,
    Applied,
    Clamped,
    Rejected,
    InvalidRequest,
    StaleIdentity,
    Unavailable,
    MissingWindow,
    AmbiguousWindow,
    Unsupported,
    ReadbackFailed,
    TimedOut,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NativeResizeResult {
    pub outcome: ResizeOutcome,
    pub ax_error: i32,
    pub mutation_attempted: bool,
    pub observed: bool,
    pub requested: Size,
    pub actual_ax: Rect,
    pub actual_cg: Rect,
}
#[derive(Clone, Debug, Serialize)]
pub struct ResizeEffect {
    pub op: &'static str,
    pub transaction: u64,
    pub effect_id: u64,
    pub window: WindowId,
    pub identity: SourceIdentity,
    pub generation: u64,
    pub requested: Option<Size>,
    /// Native screen coordinates, used only when restoring a fullscreen frame.
    pub native_origin: Option<Point>,
    /// Optional app-owned same-Space Fill, elected only by a capable native shell.
    /// Reads and exact frame restoration never carry this intent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native_action: Option<&'static str>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Preparing,
    Dragging,
    Settling,
    Failed,
    Complete,
}
#[derive(Clone, Debug, Serialize)]
pub struct NativeResizeTransaction {
    transaction: u64,
    window: WindowId,
    identity: SourceIdentity,
    generation: u64,
    output: OutputId,
    edges: Edges,
    /// Pointer grabs follow observed native sizes without a presentation tween.
    /// Action sizing may animate that observed geometry independently of AX.
    interactive: bool,
    /// Pinned windows resize in output-local points, independent of the camera.
    screen_space: bool,
    /// Pin's output-local origin before the first native read. Its adopted
    /// baseline size supplies the fixed far edge; commits round the absolute
    /// position, so fractional readbacks never accumulate rounding drift.
    pin_origin: Option<[i32; 2]>,
    /// Canvas point grabbed at the press. Motion resolves the pointer through
    /// the current viewport, so a changed camera/zoom cannot separate the edge
    /// from the pointer. A fresh baseline rebases this by its moving-edge shift.
    pointer_anchor: ResizePointerAnchor,
    /// Where the pointer last was, for a grab that has moved.
    pointer: Option<Point>,
    initial_size: Size,
    last_committed_size: Size,
    /// Upstream's cluster resize: the windows snapped to the moving edges
    /// follow each committed size (`resize_settle`). Native readback.
    group: bool,
    /// Upstream's locked_ratio: width / height at the start, for a window
    /// whose rule has `preserve_aspect_ratio`. Such a resize neither snaps
    /// nor carries a cluster.
    ratio: Option<f64>,
    latest_requested: Option<Size>,
    /// The size of the last setter sent. Upstream configures a client only
    /// when the size differs from the last one it configured
    /// (`last_window_size`): motion that asks the size a window has just
    /// refused or bent asks nothing, and costs no refusal.
    last_sent: Option<Size>,
    requested_outline: Option<Rect>,
    coalesced_latest: Option<Size>,
    native_origin: Option<Point>,
    #[serde(skip)]
    native_fill: bool,
    pending_effect: Option<ResizeEffect>,
    phase: Phase,
    baseline_observed: bool,
    /// A later read/refusal must not erase an earlier setter attempt.
    #[serde(skip)]
    mutation_attempted: bool,
    // The enter's initial read may arrive after its fullscreen already ended.
    #[serde(skip)]
    capture_fullscreen_baseline: bool,
    released: bool,
    cancelled: bool,
    /// A timed-out setter can still execute later. The one diagnostic read that
    /// follows the setter does: a setter that lands after it is a native size
    /// change like any other, which `observe` adopts.
    uncertain_mutation: bool,
    last_result: Option<NativeResizeResult>,
    #[serde(skip)]
    snap_intent: ResizeGesture,
}
impl NativeResizeTransaction {
    fn live(&self) -> bool {
        self.pending_effect.is_some()
            || self.uncertain_mutation
            || matches!(
                self.phase,
                Phase::Preparing | Phase::Dragging | Phase::Settling
            )
    }
}
/// What a sizing action may read of the transaction in the slot. See sizes.rs.
#[derive(Clone, Copy, Debug)]
pub(crate) struct ResizeSlot {
    pub(crate) transaction: u64,
    pub(crate) window: WindowId,
    pub(crate) edges: Edges,
    /// An effect is outstanding or a mutation is unresolved.
    pub(crate) live: bool,
    /// A result is owed and nothing is cancelled or uncertain: a newer target
    /// size can still take the latest-request slot.
    pub(crate) accepting: bool,
    /// A setter is in flight: the window is about to take another size.
    pub(crate) setting: bool,
}
impl Controller {
    /// An unobserved refusal ended the transaction before any native mutation.
    pub(crate) fn resize_failed_without_mutation(&self, transaction: u64) -> bool {
        self.native_resize.as_ref().is_some_and(|resize| {
            resize.transaction == transaction
                && resize.phase == Phase::Failed
                && !resize.mutation_attempted
                && (!resize.baseline_observed
                    || (!resize.cancelled
                        && resize
                            .last_result
                            .as_ref()
                            .is_some_and(|result| !result.observed)))
                && !resize.live()
        })
    }
    pub(crate) fn cancelled_resize_window(&self) -> Option<WindowId> {
        self.native_resize
            .as_ref()
            .filter(|resize| resize.cancelled)
            .map(|resize| resize.window)
    }
    /// A pointer resize owns navigation until its button or touch releases,
    /// not until the native effects finish draining. Action sizing never owns
    /// that pointer, and a cancelled or failed transaction is no live grab.
    pub(crate) fn native_resize_grab_output(&self) -> Option<OutputId> {
        self.native_resize
            .as_ref()
            .filter(|t| t.interactive && !t.released && !t.cancelled && t.live())
            .map(|t| t.output)
    }

    pub(crate) fn resize_slot(&self) -> Option<ResizeSlot> {
        self.native_resize.as_ref().map(|t| ResizeSlot {
            transaction: t.transaction,
            window: t.window,
            edges: t.edges,
            live: t.live(),
            accepting: t.pending_effect.is_some()
                && !t.cancelled
                && !t.uncertain_mutation
                && matches!(t.phase, Phase::Preparing | Phase::Settling),
            setting: t
                .pending_effect
                .as_ref()
                .is_some_and(|e| e.requested.is_some()),
        })
    }
    /// The effect a result is about to answer: the size it asked for when it
    /// is a setter, and whether an attempted setter was already unresolved
    /// before it.
    pub(crate) fn resize_answer(
        &self,
        transaction: u64,
        effect_id: u64,
    ) -> Option<(Option<Size>, bool)> {
        let t = self.resize_id(transaction).ok()?;
        let effect = t
            .pending_effect
            .as_ref()
            .filter(|e| e.effect_id == effect_id)?;
        Some((effect.requested, t.uncertain_mutation))
    }
    /// A size transaction with no drag behind it. `target` takes the place of
    /// the motion a release during the baseline read leaves queued, so the
    /// same phases run: baseline read, one setter, final read. `edges` anchors
    /// every commit exactly as a drag of those edges does. Nothing here is
    /// read from a pointer, and no camera flight is cancelled: upstream's
    /// non-interactive resize cancels none. Capture authority is not required
    /// either: no pointer is mapped through the picture, and a held key must
    /// not wait for a frame between two steps. With native readback (sizes.rs) no
    /// capture exists to wait for at all, the baseline read adopts a size
    /// the window changed by itself, and every transaction ends in bounded
    /// time: docs/crates/desktop/NATIVE_RESIZE.md.
    ///
    /// `by_hand` is false for the two requests that are not a sizing by
    /// hand: the rule's `size` a window mapped with, which upstream
    /// configures for a widget and a rule-pinned window like any other
    /// (rules.rs), and a fullscreen exit, which hands a window its size back
    /// after it has pinned it to its screen again (docs/crates/desktop/FULLSCREEN.md).
    pub(crate) fn begin_sized_resize(
        &mut self,
        window: WindowId,
        output: OutputId,
        edges: Edges,
        target: Size,
        by_hand: bool,
    ) -> Result<Value, Error> {
        if by_hand
            || !self.source_presentable(window)
            || self
                .sources
                .get(&window)
                .is_some_and(|source| source.visibility_pending)
        {
            self.require_source_interactive(window)?;
        }
        self.guard_resize_structure(None)?;
        if self.gesture.is_some() {
            return Err(Error::Invalid("native resize during active gesture"));
        }
        // A widget and a screen-pinned window are sized by those two requests
        // only. Every other caller has passed them over or refused them in
        // upstream's words before this; the transaction holds the rule all
        // the same, as a drag's does.
        if by_hand {
            self.movable(window)?;
        }
        let source = self
            .sources
            .get(&window)
            .ok_or(Error::Invalid("unbound source"))?;
        let size = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect
            .size;
        let snap = self.snap(1.0);
        let snap_intent = self
            .scene
            .begin_resize(window, edges.into(), snap.options, false)?
            .with_break_force(snap.break_force)?
            .with_same_edge(snap.corners);
        self.next_resize = self
            .next_resize
            .checked_add(1)
            .ok_or(Error::Invalid("resize IDs exhausted"))?;
        self.native_resize = Some(NativeResizeTransaction {
            transaction: self.next_resize,
            window,
            identity: source.identity.clone(),
            generation: source.generation,
            output,
            edges,
            interactive: false,
            screen_space: self.is_pinned(window),
            pin_origin: self.policy.pins.get(&window).map(|pin| pin.screen_pos),
            pointer_anchor: ResizePointerAnchor::default(),
            pointer: None,
            initial_size: size,
            last_committed_size: size,
            group: false,
            ratio: None,
            latest_requested: Some(target),
            last_sent: None,
            requested_outline: None,
            coalesced_latest: Some(target),
            native_origin: None,
            native_fill: false,
            pending_effect: None,
            phase: Phase::Preparing,
            baseline_observed: false,
            mutation_attempted: false,
            capture_fullscreen_baseline: self.is_fullscreen(window),
            released: true,
            cancelled: false,
            uncertain_mutation: false,
            last_result: None,
            snap_intent,
        });
        self.emit_resize(None)
    }
    /// A newer target for the sized transaction in the slot: it takes the one
    /// latest-request slot, as a later `native_resize_to` takes it from an
    /// earlier one. Nothing new is dispatched before the owed result arrives.
    pub(crate) fn retarget_sized_resize(&mut self, target: Size) -> Result<(), Error> {
        let accepting = self.resize_slot().is_some_and(|slot| slot.accepting);
        let t = self
            .native_resize
            .as_mut()
            .filter(|_| accepting)
            .ok_or(Error::Invalid("resize is not accepting a new size"))?;
        t.latest_requested = Some(target);
        let sent = t.pending_effect.as_ref();
        t.coalesced_latest = (!sent.is_some_and(|effect| {
            effect.requested == Some(target) && effect.native_origin == t.native_origin
        }))
        .then_some(target);
        Ok(())
    }
    pub(crate) fn set_resize_native_origin(&mut self, origin: Option<Point>) {
        if let Some(resize) = self.native_resize.as_mut() {
            resize.native_origin = origin;
        }
    }
    pub(crate) fn set_resize_native_fill(&mut self, fill: bool) {
        if let Some(resize) = self.native_resize.as_mut() {
            resize.native_fill = fill;
        }
    }
    pub(crate) fn guard_resize_structure(&self, window: Option<WindowId>) -> Result<(), Error> {
        if self
            .native_resize
            .as_ref()
            .is_some_and(|t| (window.is_none() || window == Some(t.window)) && t.live())
        {
            return Err(Error::Invalid(
                "resize must drain before structural change; cancel and reconcile pending effects",
            ));
        }
        Ok(())
    }
    pub(crate) fn resize_output_removed(
        &mut self,
        output: OutputId,
    ) -> Result<Option<Value>, Error> {
        if let Some(t) = &self.native_resize
            && t.output == output
            && t.live()
        {
            return self.finish_native_resize(t.transaction, true).map(Some);
        }
        Ok(None)
    }
    /// Upstream start_compositor_resize_with_edge and begin_client_resize: the
    /// resize grab of a bound press, of the resize border and of a resize
    /// gesture. `edges` is the border's own edge; `None` takes it from where
    /// in the window the grab was taken. Every refusal stands ahead of every
    /// side effect, as upstream's bails do: a gesture whose resize is refused
    /// pans instead, in the same command, and must find nothing raised,
    /// focused or cancelled for it.
    pub(crate) fn begin_native_resize(
        &mut self,
        window: WindowId,
        output: OutputId,
        edges: Option<Edges>,
        start_screen: Point,
        group: bool,
    ) -> Result<Value, Error> {
        self.require_source_interactive(window)?;
        self.guard_resize_structure(None)?;
        if self.gesture.is_some() || !start_screen.valid() {
            return Err(Error::Invalid(
                "native resize requires one ordinary window and valid screen point",
            ));
        }
        let screen_space = self.is_pinned(window) && !self.is_widget(window);
        if !screen_space {
            self.movable(window)?;
        } else if self.pin_output(window) != Some(output) {
            return Err(Error::Invalid("pinned resize must use its own output"));
        }
        let source = self
            .sources
            .get(&window)
            .ok_or(Error::Invalid("unbound source"))?;
        if !source.observation_known {
            return Err(Error::Invalid("source mapping is unknown"));
        }
        let (identity, generation) = (source.identity.clone(), source.generation);
        let viewport = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?;
        let zoom = if screen_space { 1.0 } else { viewport.zoom };
        let pointer_anchor = ResizePointerAnchor {
            origin: if screen_space {
                Point::default()
            } else {
                viewport.camera
            },
            offset: (start_screen - viewport.screen_bounds.origin) / zoom,
        };
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let size = rect.size;
        let edges = edges.unwrap_or_else(|| {
            if screen_space {
                let pin = self.policy.pins[&window];
                let origin = viewport.screen_bounds.origin
                    + Point::new(f64::from(pin.screen_pos[0]), f64::from(pin.screen_pos[1]));
                edges_from_position(start_screen, Rect { origin, ..rect })
            } else {
                edges_from_position(viewport.screen_to_world(start_screen), rect)
            }
        });
        // Upstream locked_ratio_for. A locked resize is one window's.
        let ratio = (self.keeps_ratio(window) && size.width > 0.0 && size.height > 0.0)
            .then(|| size.width / size.height);
        let group = group && ratio.is_none() && !screen_space;
        let snap = self.snap(zoom);
        let snap_intent = self
            .scene
            .begin_resize(window, edges.into(), snap.options, group)?
            .with_break_force(snap.break_force)?
            .with_same_edge(snap.corners);
        let transaction = self
            .next_resize
            .checked_add(1)
            .ok_or(Error::Invalid("resize IDs exhausted"))?;
        // Upstream's resize press raises and focuses the window ahead of its
        // grab (`focus_for_grab`). `effect` is the transaction's here, so the
        // focus request is the one entry of `effects`, where every reply that
        // carries a size transaction keeps its focus request.
        let focus = self.focus_for_grab(window)?;
        self.next_resize = transaction;
        self.native_resize = Some(NativeResizeTransaction {
            transaction,
            window,
            identity,
            generation,
            output,
            edges,
            interactive: true,
            screen_space,
            pin_origin: self.policy.pins.get(&window).map(|pin| pin.screen_pos),
            pointer_anchor,
            pointer: None,
            initial_size: size,
            last_committed_size: size,
            group,
            ratio,
            latest_requested: None,
            last_sent: None,
            requested_outline: None,
            coalesced_latest: None,
            native_origin: None,
            native_fill: false,
            pending_effect: None,
            phase: Phase::Preparing,
            baseline_observed: false,
            mutation_attempted: false,
            capture_fullscreen_baseline: false,
            released: false,
            cancelled: false,
            uncertain_mutation: false,
            last_result: None,
            snap_intent,
        });
        self.cancel_animations_everywhere();
        // The native grab cannot follow a camera edge pan between physical
        // motions. Retire every old cursor request along with the flights;
        // after release only a fresh pointer report may arm another one.
        self.cancel_edge_pan_everywhere();
        // Upstream begin_client_resize: a resize drag ends fit and fill.
        self.sizes.resize_begun(window);
        // And a wait for a rule's `size`, as any sizing of the user's, and
        // the size a fullscreen exit still owed the window.
        self.policy.sizing.retain(|queued| *queued != window);
        self.fullscreen.restored(window);
        let mut reply = self.emit_resize(None)?;
        reply["effects"] = json!([focus]);
        Ok(reply)
    }
    fn resize_id(&self, transaction: u64) -> Result<&NativeResizeTransaction, Error> {
        self.native_resize
            .as_ref()
            .filter(|t| t.transaction == transaction)
            .ok_or(Error::Invalid("stale resize transaction"))
    }
    fn emit_resize(&mut self, requested: Option<Size>) -> Result<Value, Error> {
        self.next_effect = self
            .next_effect
            .checked_add(1)
            .ok_or(Error::Invalid("effect IDs exhausted"))?;
        let t = self.native_resize.as_mut().expect("resize exists");
        let effect = ResizeEffect {
            op: if requested.is_some() {
                "resize_native_window"
            } else {
                "observe_resize_source"
            },
            transaction: t.transaction,
            effect_id: self.next_effect,
            window: t.window,
            identity: t.identity.clone(),
            generation: t.generation,
            requested,
            native_origin: requested.and(t.native_origin),
            native_action: (requested.is_some() && t.native_fill && t.native_origin.is_none())
                .then_some("fill"),
        };
        t.pending_effect = Some(effect.clone());
        if requested.is_some() {
            t.last_sent = requested;
        }
        Ok(json!({"transaction":t.transaction,"effect":effect}))
    }
    /// The size a grab asks with the pointer at `screen`, a global screen
    /// point: upstream's apply_resize up to its configure. The outline and
    /// the latest request are the transaction's from here on.
    fn resize_request(&mut self, screen: Point) -> Result<Size, Error> {
        let t = self.native_resize.as_ref().expect("resize exists");
        let viewport = self
            .scene
            .output(t.output)
            .ok_or(Error::Invalid("unknown resize output"))?;
        let (zoom, camera) = if t.screen_space {
            (1.0, Point::default())
        } else {
            (viewport.zoom, viewport.camera)
        };
        let bounds = viewport.screen_bounds;
        let outline_scale = if t.screen_space { viewport.zoom } else { 1.0 };
        let current = self
            .scene
            .window(t.window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        let snap = self.snap(zoom);
        let t = self.native_resize.as_mut().expect("resize exists");
        // Upstream ResizeGrab::motion: the pointer is held inside the grab's
        // output, `[0, w-1] × [0, h-1]`, so an edge cannot be dragged past
        // what the output shows. Resolve the pointer in the current viewport,
        // independently of native ownership and coordinates. Unlike upstream's
        // frozen start zoom, this keeps the grabbed edge under the pointer when
        // another input changes the canvas camera or zoom during the grab.
        // Native size requests still cut each axis toward zero (its `as i32`).
        let local = screen - bounds.origin;
        let screen = bounds.origin
            + Point::new(
                local.x.clamp(0.0, (bounds.size.width - 1.0).max(0.0)),
                local.y.clamp(0.0, (bounds.size.height - 1.0).max(0.0)),
            );
        let anchor =
            bounds.origin + ((t.pointer_anchor.origin - camera) + t.pointer_anchor.offset) * zoom;
        let delta = (screen - anchor) / zoom;
        // Subtract in screen space to avoid cancellation of large world
        // coordinates. Normalize only projection roundoff at an integer: a
        // physical 24-point resize at zoom .2 must not become 23 native units.
        let precision = Point::new(
            (screen.x.abs() + anchor.x.abs()) * 8.0 * f64::EPSILON / zoom,
            (screen.y.abs() + anchor.y.abs()) * 8.0 * f64::EPSILON / zoom,
        );
        let delta = Point::new(
            native_delta(delta.x, precision.x),
            native_delta(delta.y, precision.y),
        );
        let outline = if t.ratio.is_some() || t.screen_space {
            // Upstream: the ratio bends the size ahead of the client's bounds,
            // and a locked resize neither snaps nor carries a cluster. The
            // far edges are where the commits have kept them.
            let initial = t.initial_size;
            let target = Size::new(
                initial.width
                    + if t.edges.left() {
                        -delta.x
                    } else if t.edges.right() {
                        delta.x
                    } else {
                        0.0
                    },
                initial.height
                    + if t.edges.top() {
                        -delta.y
                    } else if t.edges.bottom() {
                        delta.y
                    } else {
                        0.0
                    },
            );
            // Bent first, floored after, as upstream clamps to the client's
            // bounds only once the ratio has chosen its driving axis.
            let size = t.ratio.map_or(target, |ratio| {
                constrain_to_ratio(target, initial, ratio, t.edges)
            });
            let size = Size::new(size.width.max(1.0), size.height.max(1.0));
            let mut outline = Rect { size, ..current };
            // The hint remains in canvas coordinates even when the pointer
            // delta and pinned dimensions are in display points.
            if t.edges.left() {
                outline.origin.x += (current.size.width - size.width) / outline_scale;
            }
            if t.edges.top() {
                outline.origin.y += (current.size.height - size.height) / outline_scale;
            }
            outline
        } else {
            t.snap_intent
                .set_snap_distances(snap.options.threshold, snap.break_force)?;
            self.scene.resize_proposal(&mut t.snap_intent, delta)?
        };
        t.requested_outline = Some(outline);
        let requested = outline.size;
        t.latest_requested = Some(requested);
        t.pointer = Some(screen);
        Ok(requested)
    }
    pub(crate) fn native_resize_to(
        &mut self,
        transaction: u64,
        screen: Point,
    ) -> Result<Value, Error> {
        let t = self.resize_id(transaction)?;
        let waiting_for_baseline = t.phase == Phase::Preparing
            && !t.baseline_observed
            && t.pending_effect
                .as_ref()
                .is_some_and(|e| e.requested.is_none());
        if (t.phase != Phase::Dragging && !waiting_for_baseline) || t.released || !screen.valid() {
            return Err(Error::Invalid("resize is not accepting motion"));
        }
        let requested = self.resize_request(screen)?;
        let t = self.native_resize.as_mut().expect("resize exists");
        if let Some(effect) = &t.pending_effect {
            t.coalesced_latest = (effect.requested != Some(requested)).then_some(requested);
            return Ok(json!({"transaction":transaction,"effect":null}));
        }
        if requested == t.last_committed_size || Some(requested) == t.last_sent {
            return Ok(json!({"transaction":transaction,"effect":null}));
        }
        self.emit_resize(Some(requested))
    }
    pub(crate) fn finish_native_resize(
        &mut self,
        transaction: u64,
        cancel: bool,
    ) -> Result<Value, Error> {
        let t = self.resize_id(transaction)?;
        if !t.live() {
            return Err(Error::Invalid("resize already ended"));
        }
        if cancel {
            let window = t.window;
            if let Some(output) = self.fullscreen_output_of(window) {
                self.exit_fullscreen_on(output);
            }
        }
        let t = self.native_resize.as_mut().expect("resize exists");
        t.released = true;
        t.cancelled |= cancel;
        if cancel {
            t.coalesced_latest = None;
        }
        if !t.uncertain_mutation {
            t.phase = Phase::Settling;
        }
        if t.pending_effect.is_some() || t.uncertain_mutation {
            return Ok(json!({"effect":null}));
        }
        self.emit_resize(None)
    }
    pub(crate) fn native_resize_result(
        &mut self,
        transaction: u64,
        effect_id: u64,
        identity: SourceIdentity,
        generation: u64,
        result: NativeResizeResult,
    ) -> Result<Value, Error> {
        let t = self.resize_id(transaction)?;
        let effect = t
            .pending_effect
            .as_ref()
            .filter(|e| {
                e.effect_id == effect_id && e.identity == identity && e.generation == generation
            })
            .ok_or(Error::Invalid("stale or duplicate resize result"))?
            .clone();
        self.check_generation(t.window, &identity, generation)?;
        let agrees = (result.actual_ax.origin.x - result.actual_cg.origin.x).abs() <= 1.0
            && (result.actual_ax.origin.y - result.actual_cg.origin.y).abs() <= 1.0
            && (result.actual_ax.size.width - result.actual_cg.size.width).abs() <= 1.0
            && (result.actual_ax.size.height - result.actual_cg.size.height).abs() <= 1.0;
        // Match the actual adapter paths: resolve failures have no observation;
        // unsupported and pre-setter timeouts can retain the successful preflight
        // read. Post-setter successful reads always become a settled outcome.
        let setter = effect.requested.is_some();
        let flags_valid = match result.outcome {
            ResizeOutcome::Observed => !setter && result.observed && !result.mutation_attempted,
            ResizeOutcome::Applied | ResizeOutcome::Clamped | ResizeOutcome::Rejected => {
                setter && result.observed && result.mutation_attempted
            }
            ResizeOutcome::Unsupported => setter && result.observed && !result.mutation_attempted,
            ResizeOutcome::InvalidRequest => {
                setter && !result.observed && !result.mutation_attempted
            }
            ResizeOutcome::Unavailable
            | ResizeOutcome::MissingWindow
            | ResizeOutcome::AmbiguousWindow => !result.observed && !result.mutation_attempted,
            ResizeOutcome::StaleIdentity | ResizeOutcome::ReadbackFailed => {
                !result.observed && (setter || !result.mutation_attempted)
            }
            ResizeOutcome::TimedOut => {
                if result.observed {
                    setter && !result.mutation_attempted
                } else {
                    setter || !result.mutation_attempted
                }
            }
        };
        if !flags_valid
            || (result.observed && !agrees)
            || (effect.requested.is_none() && result.mutation_attempted)
            || (result.observed && (!result.actual_ax.valid() || !result.actual_cg.valid()))
            || effect.requested.is_some_and(|s| s != result.requested)
            || (result.outcome == ResizeOutcome::Applied
                && effect.native_origin.is_some_and(|origin| {
                    (origin.x - result.actual_ax.origin.x).abs() > 1.0
                        || (origin.y - result.actual_ax.origin.y).abs() > 1.0
                }))
        {
            return Err(Error::Invalid("invalid resize result contract"));
        }
        let preparing = !t.baseline_observed;
        let capture_fullscreen_baseline = t.capture_fullscreen_baseline;
        let window = t.window;
        let output = t.output;
        if preparing && result.observed {
            self.fullscreen.capture_native(
                window,
                result.actual_ax,
                capture_fullscreen_baseline,
            )?;
            if let Some(origin) = self.fullscreen.restore_native_origin(window) {
                self.set_resize_native_origin(Some(origin));
            }
            if capture_fullscreen_baseline
                && let Some(extent) = self.fullscreen.restore_extent(window)
                && let Some(resize) = self.native_resize.as_mut()
            {
                resize.latest_requested = Some(extent);
                resize.coalesced_latest = Some(extent);
            }
        }
        let mut adopted = false;
        // Output removal cancels the grab, but its outstanding native result
        // must still drain. No pointer request uses this fallback snap scale.
        let zoom = self
            .scene
            .output(output)
            .map_or(1.0, |viewport| viewport.zoom);
        let snap = self.snap(zoom);
        let t = self.native_resize.as_mut().expect("resize exists");
        t.pending_effect = None;
        t.mutation_attempted |= result.mutation_attempted;
        t.last_result = Some(result.clone());
        let source = self.sources.get_mut(&t.window).expect("binding validated");
        if result.outcome == ResizeOutcome::Unsupported {
            t.cancelled = true;
        }
        if result.observed {
            source.observed_rect = result.actual_ax;
            source.observation_known = true;
            if preparing && result.actual_ax.size != t.initial_size {
                // The window changed its size by itself and no `observe`
                // has said so yet, or a rebind kept the saved slot's size:
                // the size it has is the baseline. Nobody knows which
                // edge moved, so the top-left is kept. The queued target
                // is then asked of it as of any other baseline.
                let mut rect = self
                    .scene
                    .window(t.window)
                    .expect("bound window")
                    .world_rect;
                if t.interactive {
                    // The press was on the displayed edge, not the size a
                    // delayed baseline later found. Adoption keeps the
                    // top-left, so right/bottom move by the observed size
                    // difference. Rebase their anchor by that exact amount
                    // to retain the original pointer-to-edge offset. Left
                    // and top do not move during adoption.
                    if t.edges.right() {
                        t.pointer_anchor.offset.x += result.actual_ax.size.width - rect.size.width;
                    }
                    if t.edges.bottom() {
                        t.pointer_anchor.offset.y +=
                            result.actual_ax.size.height - rect.size.height;
                    }
                }
                rect.size = result.actual_ax.size;
                self.scene.set_window_rect(t.window, rect)?;
                t.initial_size = rect.size;
                t.last_committed_size = rect.size;
                // What the drag measures from is this size: its snap
                // state, its cluster and its ratio were taken from the
                // size the canvas had, and are taken again.
                t.snap_intent = self
                    .scene
                    .begin_resize(t.window, t.edges.into(), snap.options, t.group)?
                    .with_break_force(snap.break_force)?
                    .with_same_edge(snap.corners);
                if t.ratio.is_some() {
                    t.ratio = Some(rect.size.width / rect.size.height);
                }
                adopted = true;
            }
            t.baseline_observed = true;
            let mut rect = self
                .scene
                .window(t.window)
                .expect("bound window")
                .world_rect;
            let actual = result.actual_ax.size;
            if actual != t.last_committed_size {
                // Upstream handle_resize_commit: a left or top resize moves the
                // window by what the committed size changed, so the opposite
                // edge stays where it is on screen. On the canvas only: a size
                // write keeps a native window's own top-left.
                if t.screen_space {
                    let pin = self
                        .policy
                        .pins
                        .get_mut(&t.window)
                        .ok_or(Error::Invalid("resize lost its screen pin"))?;
                    let origin = t
                        .pin_origin
                        .ok_or(Error::Invalid("resize lost its pin anchor"))?;
                    let position =
                        |origin: i32, baseline: f64, actual: f64| -> Result<i32, Error> {
                            // Round from the fixed baseline, never from an already
                            // rounded previous commit. Delayed baseline adoption
                            // retains this origin and replaces `initial_size`.
                            let value = (f64::from(origin) + baseline - actual).round();
                            if !(f64::from(i32::MIN)..=f64::from(i32::MAX)).contains(&value) {
                                return Err(Error::Invalid("resized pin exceeds integer range"));
                            }
                            Ok(value as i32)
                        };
                    // After release an independent drag may move this pin
                    // while the last native result is still owed. Rebase by
                    // that translation, measured against our last rounded
                    // position, without treating rounding as fresh movement.
                    let translated = |axis: usize, moving: bool, baseline: f64, last: f64| {
                        let previous = if moving {
                            position(origin[axis], baseline, last)?
                        } else {
                            origin[axis]
                        };
                        i32::try_from(
                            i64::from(origin[axis]) + i64::from(pin.screen_pos[axis])
                                - i64::from(previous),
                        )
                        .map_err(|_| Error::Invalid("resized pin anchor exceeds integer range"))
                    };
                    let origin = [
                        translated(
                            0,
                            t.edges.left(),
                            t.initial_size.width,
                            t.last_committed_size.width,
                        )?,
                        translated(
                            1,
                            t.edges.top(),
                            t.initial_size.height,
                            t.last_committed_size.height,
                        )?,
                    ];
                    t.pin_origin = Some(origin);
                    if t.edges.left() {
                        pin.screen_pos[0] =
                            position(origin[0], t.initial_size.width, actual.width)?;
                    }
                    if t.edges.top() {
                        pin.screen_pos[1] =
                            position(origin[1], t.initial_size.height, actual.height)?;
                    }
                } else {
                    if t.edges.left() {
                        rect.origin.x += t.last_committed_size.width - actual.width;
                    }
                    if t.edges.top() {
                        rect.origin.y += t.last_committed_size.height - actual.height;
                    }
                }
                rect.size = actual;
                // A cluster follows the size the window took, not the one
                // asked: a window that stops at a limit stops its neighbours
                // too, as upstream's do by clamping ahead of the cluster.
                // A cluster that can no longer be moved as it was captured (a
                // member is not where the last settle left it) is let go of
                // for the rest of the grab, and the transaction says so: every
                // later settle would fail on the same member.
                if !t.group || self.scene.resize_settle(&mut t.snap_intent, rect).is_err() {
                    self.scene.set_window_rect(t.window, rect)?;
                    t.group = false;
                }
                t.last_committed_size = actual;
            }
        }
        // An unobserved native readback: the last rectangle the window was seen
        // at stays what it is mapped by. The window is gone, which the shell
        // reports next, or did not answer, and is usable where it was.
        if result.mutation_attempted
            && (!result.observed
                || result.outcome == ResizeOutcome::TimedOut
                || result.ax_error == -25204)
        {
            t.uncertain_mutation = true;
        }
        if t.uncertain_mutation && effect.requested.is_none() {
            // The diagnostic read's answer ends the transaction either way:
            // the size it found is committed above, and a setter that lands
            // after it is a native size change, which `observe` adopts.
            t.uncertain_mutation = false;
            t.coalesced_latest = None;
            t.phase = if result.observed && !t.cancelled {
                Phase::Complete
            } else {
                Phase::Failed
            };
            return Ok(if result.observed {
                json!({"effect":null})
            } else {
                json!({"effect":null,"failure":"the window did not answer the size request in time"})
            });
        }
        if t.uncertain_mutation {
            t.coalesced_latest = None;
            // Exactly one diagnostic read follows an ambiguous setter.
            if effect.requested.is_some() {
                return self.emit_resize(None);
            }
            return Ok(json!({"effect":null,"uncertain_mutation":true}));
        }
        if !result.observed {
            t.phase = Phase::Failed;
            t.coalesced_latest = None;
            return Ok(json!({"effect":null}));
        }
        // Motion that waited for the baseline was measured from the size the
        // canvas had. It is measured again, from the size adopted.
        if adopted && let Some(pointer) = self.native_resize.as_ref().and_then(|t| t.pointer) {
            let size = self.resize_request(pointer)?;
            let t = self.native_resize.as_mut().expect("resize exists");
            t.coalesced_latest = Some(size);
        }
        let t = self.native_resize.as_mut().expect("resize exists");
        if t.cancelled {
            t.coalesced_latest = None;
        }
        if let Some(size) = t.coalesced_latest.take()
            && (size != t.last_committed_size
                || t.native_origin.is_some_and(|origin| {
                    (origin.x - result.actual_ax.origin.x).abs() > 1.0
                        || (origin.y - result.actual_ax.origin.y).abs() > 1.0
                }))
        {
            // Baseline validation may release motion queued during Preparing.
            // Continue accepting motion only while the pointer remains held.
            t.phase = if t.released {
                Phase::Settling
            } else {
                Phase::Dragging
            };
            return self.emit_resize(Some(size));
        }
        if t.released || t.cancelled {
            if effect.requested.is_some() {
                t.phase = Phase::Settling;
                return self.emit_resize(None);
            }
            t.phase = if t.cancelled {
                Phase::Failed
            } else {
                Phase::Complete
            };
        } else {
            t.phase = Phase::Dragging;
        }
        Ok(json!({"effect":null}))
    }
}
