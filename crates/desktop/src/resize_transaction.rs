// SPDX-License-Identifier: GPL-3.0-or-later
//! Size-only native transactions. Effects are obligations, not native evidence.
use super::*;

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
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Preparing,
    Dragging,
    Settling,
    NeedsObservation,
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
    start_screen: Point,
    start_zoom: f64,
    initial_size: Size,
    last_committed_size: Size,
    /// Native min/max are not supplied by AX; no constraints are inferred.
    native_constraints: Option<Size>,
    latest_requested: Option<Size>,
    requested_outline: Option<Rect>,
    coalesced_latest: Option<Size>,
    pending_effect: Option<ResizeEffect>,
    phase: Phase,
    baseline_observed: bool,
    released: bool,
    cancelled: bool,
    /// A timed-out setter can still execute later. Reads cannot discharge this.
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
impl Controller {
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
    pub(crate) fn begin_native_resize(
        &mut self,
        window: WindowId,
        output: OutputId,
        edges: Edges,
        start_screen: Point,
        group: bool,
    ) -> Result<Value, Error> {
        self.guard_resize_structure(None)?;
        if group || self.gesture.is_some() || !point_valid(start_screen) {
            return Err(Error::Invalid(
                "native resize requires one ordinary window and valid screen point",
            ));
        }
        let source = self
            .sources
            .get(&window)
            .ok_or(Error::Invalid("unbound source"))?;
        if source.resize_disabled
            || !source.observation_known
            || source.capture_revision != Some(source.observation_revision)
        {
            return Err(Error::Invalid(
                "source resize unsupported or presentation unsettled",
            ));
        }
        let zoom = self
            .scene
            .output(output)
            .ok_or(Error::Invalid("unknown output"))?
            .zoom;
        let size = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect
            .size;
        let snap_intent = self
            .scene
            .begin_resize(
                window,
                edges.into(),
                SnapOptions {
                    threshold: 24.0 / zoom,
                    ..SnapOptions::default()
                },
                false,
            )?
            .with_break_force(32.0 / zoom)?;
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
            start_screen,
            start_zoom: zoom,
            initial_size: size,
            last_committed_size: size,
            native_constraints: None,
            latest_requested: None,
            requested_outline: None,
            coalesced_latest: None,
            pending_effect: None,
            phase: Phase::Preparing,
            baseline_observed: false,
            released: false,
            cancelled: false,
            uncertain_mutation: false,
            last_result: None,
            snap_intent,
        });
        self.flights.clear();
        self.emit_resize(None)
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
        };
        t.pending_effect = Some(effect.clone());
        if requested.is_some() {
            self.sources
                .get_mut(&t.window)
                .expect("bound source")
                .capture_revision = None;
        }
        Ok(json!({"transaction":t.transaction,"effect":effect}))
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
        if (t.phase != Phase::Dragging && !waiting_for_baseline)
            || t.released
            || !point_valid(screen)
        {
            return Err(Error::Invalid("resize is not accepting motion"));
        }
        let zoom = self
            .scene
            .output(t.output)
            .ok_or(Error::Invalid("unknown resize output"))?
            .zoom;
        let t = self.native_resize.as_mut().expect("resize exists");
        t.snap_intent.set_snap_distances(24.0 / zoom, 32.0 / zoom)?;
        let outline = self
            .scene
            .resize_proposal(&mut t.snap_intent, (screen - t.start_screen) / t.start_zoom)?;
        t.requested_outline = Some(outline);
        let requested = outline.size;
        t.latest_requested = Some(requested);
        if let Some(effect) = &t.pending_effect {
            t.coalesced_latest = (effect.requested != Some(requested)).then_some(requested);
            return Ok(json!({"transaction":transaction,"effect":null}));
        }
        if requested == t.last_committed_size {
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
            || (result.observed && (!rect_valid(result.actual_ax) || !rect_valid(result.actual_cg)))
            || effect.requested.is_some_and(|s| s != result.requested)
        {
            return Err(Error::Invalid("invalid resize result contract"));
        }
        let preparing = !t.baseline_observed;
        let t = self.native_resize.as_mut().expect("resize exists");
        t.pending_effect = None;
        t.last_result = Some(result.clone());
        let source = self.sources.get_mut(&t.window).expect("binding validated");
        if result.outcome == ResizeOutcome::Unsupported {
            source.resize_disabled = true;
            t.cancelled = true;
        }
        if result.observed {
            source.observed_rect = result.actual_ax;
            source.observation_known = true;
            if preparing && result.actual_ax.size != t.initial_size {
                t.phase = Phase::Failed;
                t.coalesced_latest = None;
                source.capture_revision = None;
                return Ok(
                    json!({"effect":null,"failure":"baseline size differs from committed logical size"}),
                );
            }
            t.baseline_observed = true;
            let mut rect = self
                .scene
                .window(t.window)
                .expect("bound window")
                .world_rect;
            let actual = result.actual_ax.size;
            if effect.requested.is_some() || actual != t.last_committed_size {
                source.observation_revision = source
                    .observation_revision
                    .checked_add(1)
                    .ok_or(Error::Invalid("observation revisions exhausted"))?;
                source.capture_revision = None;
            }
            if actual != t.last_committed_size {
                if matches!(t.edges, Edges::Left | Edges::TopLeft | Edges::BottomLeft) {
                    rect.origin.x += t.last_committed_size.width - actual.width;
                }
                if matches!(t.edges, Edges::Top | Edges::TopLeft | Edges::TopRight) {
                    rect.origin.y += t.last_committed_size.height - actual.height;
                }
                rect.size = actual;
                self.scene.set_window_rect(t.window, rect)?;
                t.last_committed_size = actual;
                source.capture_revision = None;
            }
        } else {
            source.observation_known = false;
            source.capture_revision = None;
        }
        if result.mutation_attempted
            && (!result.observed
                || result.outcome == ResizeOutcome::TimedOut
                || result.ax_error == -25204)
        {
            t.uncertain_mutation = true;
        }
        if t.uncertain_mutation {
            t.phase = Phase::NeedsObservation;
            t.coalesced_latest = None;
            // Exactly one diagnostic read after the ambiguous setter; its result
            // never proves that a late setter cannot still run.
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
        if t.cancelled {
            t.coalesced_latest = None;
        }
        if let Some(size) = t.coalesced_latest.take() {
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
    /// Explicit host attestation of lifetime end, not a controller observation.
    /// Results must first drain so no effect can later target a replacement.
    pub(crate) fn retire_native_resize_source(
        &mut self,
        transaction: u64,
        identity: SourceIdentity,
        generation: u64,
        lifetime_ended: bool,
    ) -> Result<Value, Error> {
        let t = self.resize_id(transaction)?;
        if !lifetime_ended
            || t.identity != identity
            || t.generation != generation
            || t.pending_effect.is_some()
        {
            return Err(Error::Invalid(
                "retirement requires exact ended lifetime and drained effect",
            ));
        }
        self.check_generation(t.window, &identity, generation)?;
        let window = t.window;
        self.retired_resize_identities.push(identity);
        self.sources.remove(&window);
        self.invalidate_focus(window);
        let t = self.native_resize.as_mut().expect("resize exists");
        t.uncertain_mutation = false;
        t.coalesced_latest = None;
        t.cancelled = true;
        t.phase = Phase::Failed;
        Ok(json!({"window":window,"retired":true,"evidence":"caller_reported_lifetime_end"}))
    }
    pub(crate) fn native_resize_capture_ready(
        &mut self,
        window: WindowId,
        identity: SourceIdentity,
        generation: u64,
        observation_revision: u64,
        buffer: BufferSize,
        content_rect: Option<Rect>,
    ) -> Result<Value, Error> {
        self.check_generation(window, &identity, generation)?;
        buffer.validate()?;
        let content_rect = content_rect.unwrap_or_else(|| buffer.full_rect());
        if !rect_valid(content_rect)
            || content_rect.origin.x < 0.0
            || content_rect.origin.y < 0.0
            || content_rect.origin.x + content_rect.size.width > buffer.width as f64
            || content_rect.origin.y + content_rect.size.height > buffer.height as f64
        {
            return Err(Error::Invalid("capture content rectangle outside buffer"));
        }
        if self.native_resize.as_ref().is_some_and(|t| {
            t.window == window
                && (t.uncertain_mutation
                    || t.pending_effect
                        .as_ref()
                        .is_some_and(|e| e.requested.is_some()))
        }) {
            return Err(Error::Invalid("native resize mutation is unresolved"));
        }
        let source = self.sources.get_mut(&window).expect("binding validated");
        if !source.observation_known || source.observation_revision != observation_revision {
            return Err(Error::Invalid("stale resize capture observation"));
        }
        source.buffer = buffer;
        source.content_rect = content_rect;
        source.capture_revision = Some(observation_revision);
        Ok(json!({}))
    }
}
