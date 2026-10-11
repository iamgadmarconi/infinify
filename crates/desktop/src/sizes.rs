// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/resize.rs (step_resize_focused, resize_element_to, PendingResize,
// requested_element_size, placed_element_size), src/state/fit.rs
// (compute_fit_geometry, fit_window, unfit_window, fit_window_snapped,
// unfit_window_snapped, snap_rects_with_primary, shift_cluster_around_primary,
// snap_rect_at), src/state/fill.rs (compute_fill_geometry, fill_window,
// unfill_window, fill_restore_view), src/state/cluster_snapshot.rs
// (cluster_snapshot_for_resize_with_rects, apply_member_shifts,
// compute_shifts), src/state/recenter.rs (establish_exit_placement),
// src/state/window_frame.rs (visual_frame_center, frame_loc_for_center,
// configured_window_size as fit.rs and fill.rs read it),
// src/handlers/xdg_shell.rs (maximize_request), src/state/fit.rs
// (decoration_toggle_fit), src/state/navigation.rs (the RestoreFillElseReset leg of
// navigate_to_window_on), src/state/persistence.rs (window_mode),
// src/grabs/resize_grab.rs (SizeConstraints::clamp), src/input/actions.rs (the
// GrowWindow, ShrinkWindow, FitWindow, FitWindowSnapped, FillWindow and
// ZoomToFitSnapped arms, fit_to_bbox) and src/ipc/mod.rs (cmd_resize). The
// fill search, the cluster walk and the push cascade are not adapted: they
// are driftwm-core's `layout::fill::fill_rect` and `layout::cluster::
// {cluster_of, adjacent_side, resolve_cluster_shifts}`, upstream's own code.
// The restore state is driftwm-core `stage`'s per-entry `fit_saved_size`,
// `fill_saved` and `restore_size`, kept here by window ID because the scene
// is not that stage.
//
// Upstream writes a placement for the size it asks a client for and lets the
// client answer later. Here a size reaches a native window only through the
// size transaction of resize_transaction.rs, so an action asks, and what it
// would have written for the size the window then has is written when the
// result arrives. Native frames include their title bar, so chrome is zero;
// a native window's size limits are unknown, so only upstream's one-pixel
// floor is applied before asking. Every sizing action is a canvas window's
// (`is_canvas_window`, `Controller::on_canvas`): a widget and a screen-pinned
// window are passed over, IPC `resize` refuses to write them, and neither is
// an obstacle, a cluster member or a snap rectangle (`snap_rect_for`,
// `Scene::snaps`). See SIZES.md. fullscreen.rs asks for an output's size and
// for the size a window had before through `fullscreen_resize`, on this same
// transaction: FULLSCREEN.md.
use super::actions::Outcome;
use super::ipc::{WindowMode, frame, readable};
use super::navigation::Anchor;
use super::resize_transaction::ResizeSlot;
use super::view_actions::{ViewReturn, pixel, pixel_size};
use super::window_actions::Moved;
use super::*;
use driftwm_canvas::policy;
use driftwm_core::config::{Action, Direction};
use driftwm_core::layout::cluster::{
    ResizeClassification, Side, adjacent_side, cluster_of, resolve_cluster_shifts,
};
use driftwm_core::layout::fill::fill_rect;
use driftwm_core::layout::snap::SnapRect;
use std::collections::{HashSet, VecDeque};

/// A location or a size in upstream's whole logical pixels.
type Px = [i64; 2];

/// What `place_window` says for a move during a gesture: a sizing action is
/// refused the same way.
const GRABBED: &str = "a window is under an interactive move or resize";
/// Upstream cmd_resize's own words for a window a grab is driving.
const GRABBED_IPC: &str =
    "this window is under an interactive move or resize, or still settling one";
/// A stand-in has no native window whose size could change.
const NO_SOURCE_IPC: &str =
    "this window has no native size to set: it is a stand-in or has no live window";

/// Upstream `stage::FillSaved`, which is not `Clone` and names its output by
/// a string: what an unfill restores, and the view the fill grew inside.
#[derive(Clone, Debug)]
struct FillSaved {
    pre_fill_position: Px,
    pre_fill_size: Px,
    /// The output's usable area in canvas coordinates when the fill ran.
    viewport_bounds: SnapRect,
    viewport_output: OutputId,
    /// Where the fill put the window. The stored view describes it only there.
    filled_at: Px,
}
/// Upstream's per-entry `fit_saved_size` and `fill_saved`. A window is never
/// both: a fit ends a fill and a fill ends a fit.
#[derive(Clone, Debug)]
enum Restore {
    Fit {
        saved_size: Px,
        /// Upstream configured_window_size while fit: the size the fit asked
        /// for, which the size the window then took never replaces.
        configured: Px,
    },
    Fill(FillSaved),
}
/// Upstream PendingResize: the size a non-interactive resize last asked a
/// window for, and the size the window had when it was asked.
#[derive(Clone, Copy, Debug)]
struct Asked {
    requested: Px,
    at_request: Px,
}
impl Asked {
    /// Upstream is_live: the window's size still reads as an answer to this
    /// request, anywhere between what it had and what it was asked for.
    fn answered_by(&self, committed: Px) -> bool {
        let between = |c: i64, a: i64, b: i64| c >= a.min(b) && c <= a.max(b);
        between(committed[0], self.at_request[0], self.requested[0])
            && between(committed[1], self.at_request[1], self.requested[1])
    }
}
/// What upstream would have written when it sent the configure, kept until
/// the window's new size is known.
#[derive(Clone, Debug)]
enum Plan {
    /// `grow-window` and `shrink-window`. The transaction's edges hold the
    /// opposite edge still at every commit, whatever size is granted.
    Step,
    /// A step on a window that left fullscreen and is still owed its size.
    /// Its frame still has the output's size, which the transaction's own
    /// edge anchoring would measure from, so the transaction moves no edge
    /// and the plan holds the opposite one of the frame the exit restored,
    /// whatever size is granted: `loc` is that frame's top-left, `far` its
    /// bottom-right and `edges` the ones the step moves.
    StepRestored {
        loc: Px,
        far: Px,
        edges: Edges,
    },
    /// IPC `resize` and a rule's `size`: the top-left that keeps the center
    /// for the size asked. `by_hand` is false for the rule's, the one request
    /// of the two that sizes a widget and a screen-pinned window too.
    ///
    /// `basis` is readback mode's: the top-left and the size the request was
    /// measured from. Upstream clamps the size to its client's declared
    /// limits before it computes the top-left (src/ipc/mod.rs cmd_resize);
    /// Accessibility declares none, and the size the window took of the
    /// request is the only way they are learned, so the center is kept for
    /// that size.
    Absolute {
        loc: Px,
        by_hand: bool,
        basis: Option<(Px, Px)>,
    },
    Fit {
        loc: Px,
        saved_size: Px,
        /// `fit-window-snapped`: the frame before and the frame asked for.
        shove: Option<(SnapRect, SnapRect)>,
    },
    Unfit {
        loc: Px,
        pre_exit_size: Px,
        center: Point,
        shove: Option<(SnapRect, SnapRect)>,
    },
    Fill {
        loc: Px,
        saved: FillSaved,
    },
    Unfill {
        loc: Px,
        pre_exit_size: Px,
        center: Point,
    },
    /// fullscreen.rs's enter: the window is parked at its output's camera and
    /// asked for the output's size. The transaction's edges hold the parked
    /// top-left; fullscreen.rs centres whatever size the window then has.
    Fullscreen,
    /// fullscreen.rs's exit: the size the window had before, around the
    /// center of the frame the exit put back. `None` once something else has
    /// placed the window since: it then keeps its top-left.
    Unfullscreen {
        place: Option<(Px, Px, Point)>,
    },
}
/// What fullscreen.rs asks the one size transaction for.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Screen {
    /// Its output's whole size.
    Fill,
    /// The size it had before fullscreen, at the top-left the exit restored,
    /// or wherever the window has been placed since (`None`).
    Restore(Option<Px>),
}
impl Plan {
    /// Where the window's top-left goes once it has `actual` size, or `None`
    /// when the transaction's own edge anchoring places it.
    fn origin(&self, actual: Px) -> Option<Px> {
        match self {
            Self::Step | Self::Fullscreen | Self::Unfullscreen { place: None } => None,
            Self::StepRestored { loc, far, edges } => {
                let left = matches!(edges, Edges::Left | Edges::TopLeft | Edges::BottomLeft);
                let top = matches!(edges, Edges::Top | Edges::TopLeft | Edges::TopRight);
                Some([
                    if left { far[0] - actual[0] } else { loc[0] },
                    if top { far[1] - actual[1] } else { loc[1] },
                ])
            }
            Self::Absolute {
                basis: Some((position, current)),
                ..
            } => Some([
                position[0] + (current[0] - actual[0]) / 2,
                position[1] + (current[1] - actual[1]) / 2,
            ]),
            // Upstream places for the size it asks for and does not re-derive
            // the place from what the client then commits.
            Self::Absolute { loc, .. } | Self::Fit { loc, .. } | Self::Fill { loc, .. } => {
                Some(*loc)
            }
            // Upstream establish_exit_placement: a window that keeps its size
            // stays where it was mapped; one that changes is re-placed around
            // the center the exit preserved.
            Self::Unfit {
                loc,
                pre_exit_size,
                center,
                ..
            }
            | Self::Unfill {
                loc,
                pre_exit_size,
                center,
            }
            | Self::Unfullscreen {
                place: Some((loc, pre_exit_size, center)),
            } => Some(if actual == *pre_exit_size {
                *loc
            } else {
                loc_for_center(*center, actual)
            }),
        }
    }
}
/// The sizing action whose size transaction is in the slot.
#[derive(Clone, Debug)]
struct Pending {
    transaction: u64,
    window: WindowId,
    plan: Plan,
    asked: Asked,
    /// The restore state has been written for the plan in force.
    settled: bool,
    /// Where the plan last put the window: something else has moved it since
    /// when it is no longer there.
    placed: Option<Point>,
}
/// Sizing state. All of it is ephemeral, as upstream's stage entries are.
#[derive(Clone, Debug, Default)]
pub(crate) struct Sizes {
    /// The shell performs resize effects in this run: `native_resize_capability`.
    /// Every normal run's does.
    pub(crate) capability: bool,
    /// A size is settled by the native read alone; this run acknowledges no
    /// capture. Every normal run without `--experimental-native-resize`:
    /// NATIVE_RESIZE.md, "Readback mode".
    pub(crate) readback: bool,
    restore: BTreeMap<WindowId, Restore>,
    /// Upstream's per-entry `restore_size`: the size a window had before a fit
    /// or a fill changed it. A fit and a fill read it and never replace it; a
    /// step, an IPC resize and a resize drag end it, and the next fit or fill
    /// captures the size the window has by then.
    restore_size: BTreeMap<WindowId, Px>,
    asked: BTreeMap<WindowId, Asked>,
    /// Upstream configured_window_size: the size last asked of a window by a
    /// step, an IPC resize, a rule, a fit, a fill or the toggle back, which
    /// the size the window then took never replaces. A fit and a fill measure
    /// the window by it. A resize drag ends it, and until one is asked the
    /// window is measured by the size it has.
    configured: BTreeMap<WindowId, Px>,
    pending: Option<Pending>,
}
impl Sizes {
    pub(crate) fn observation_idle(&self) -> bool {
        self.readback && self.pending.is_none() && self.asked.is_empty()
    }
    /// Upstream window_mode, in the IPC inventory's spelling.
    pub(crate) fn mode(&self, window: WindowId) -> WindowMode {
        match self.restore.get(&window) {
            Some(Restore::Fit { .. }) => WindowMode::Fit,
            Some(Restore::Fill(_)) => WindowMode::Fill,
            None => WindowMode::Normal,
        }
    }
    /// The snapshot's `mode`: null, `fit` or `fill`.
    pub(crate) fn mode_name(&self, window: WindowId) -> Option<&'static str> {
        match self.mode(window) {
            WindowMode::Normal => None,
            WindowMode::Fit => Some("fit"),
            WindowMode::Fill => Some("fill"),
        }
    }
    /// Upstream clear_fill: a window that is re-anchored has no fill to undo.
    pub(crate) fn clear_fill(&mut self, window: WindowId) {
        if matches!(self.restore.get(&window), Some(Restore::Fill(_))) {
            self.restore.remove(&window);
        }
    }
    /// Upstream begin_client_resize: a resize drag ends fit and fill, and its
    /// sizes are no answer to an earlier request.
    pub(crate) fn resize_begun(&mut self, window: WindowId) {
        self.restore.remove(&window);
        self.restore_size.remove(&window);
        self.asked.remove(&window);
        self.configured.remove(&window);
    }
    /// A filled window that no longer sits where its fill put it was moved.
    /// Only a window that snaps is a member a resize can shift: one pinned to
    /// a screen since its fill follows its pin, and keeps its restore point.
    pub(crate) fn drop_moved_fills(&mut self, scene: &Scene) {
        self.restore.retain(|id, restore| {
            let Restore::Fill(saved) = restore else {
                return true;
            };
            !scene.snaps(*id)
                || scene
                    .window(*id)
                    .and_then(|window| frame(window.world_rect).ok())
                    .is_some_and(|(loc, _)| loc == saved.filled_at)
        });
    }
}

fn point_of(px: Px) -> Point {
    Point::new(px[0] as f64, px[1] as f64)
}
fn size_of(px: Px) -> Size {
    Size::new(px[0] as f64, px[1] as f64)
}
fn rect_at(loc: Px, size: Px) -> Rect {
    Rect {
        origin: point_of(loc),
        size: size_of(size),
    }
}
fn snap_rect(rect: Rect) -> SnapRect {
    SnapRect {
        x_low: rect.origin.x,
        x_high: rect.right(),
        y_low: rect.origin.y,
        y_high: rect.bottom(),
    }
}
/// Upstream snap_rect_at, with no title bar strip and no border to add.
fn snap_rect_at(loc: Px, size: Px) -> SnapRect {
    snap_rect(rect_at(loc, size))
}
/// Upstream visual_frame_center.
fn center_of(loc: Px, size: Px) -> Point {
    Point::new(
        loc[0] as f64 + size[0] as f64 / 2.0,
        loc[1] as f64 + size[1] as f64 / 2.0,
    )
}
/// Upstream frame_loc_for_center, whose `as i32` drops the fraction toward zero.
fn loc_for_center(center: Point, size: Px) -> Px {
    [
        (center.x - size[0] as f64 / 2.0) as i64,
        (center.y - size[1] as f64 / 2.0) as i64,
    ]
}
/// Upstream's usable area is whole pixels: its output-local top-left and size.
fn usable_px(usable: Rect) -> Result<(Px, Px), Error> {
    let size = pixel_size(usable.size)?;
    Ok((
        [
            pixel(usable.origin.x.round())?.into(),
            pixel(usable.origin.y.round())?.into(),
        ],
        [size.w.into(), size.h.into()],
    ))
}
/// The edges a step in `direction` moves. Upstream's unit vector is Y down.
fn step_edges(direction: &Direction) -> Edges {
    let (ux, uy) = direction.to_unit_vec();
    match (ux < 0.0, ux > 0.0, uy < 0.0, uy > 0.0) {
        (true, _, true, _) => Edges::TopLeft,
        (true, _, _, true) => Edges::BottomLeft,
        (true, ..) => Edges::Left,
        (_, true, true, _) => Edges::TopRight,
        (_, true, _, true) => Edges::BottomRight,
        (_, true, ..) => Edges::Right,
        (_, _, true, _) => Edges::Top,
        _ => Edges::Bottom,
    }
}
/// The actions that end by delivering a size to a native window, which a shell
/// that performs resize effects can do (`native_resize_capability`).
pub(crate) fn delivers_a_size(action: &Action) -> bool {
    matches!(
        action,
        Action::GrowWindow(_)
            | Action::ShrinkWindow(_)
            | Action::FitWindow
            | Action::FitWindowSnapped
            | Action::FillWindow
    )
}
/// A reply with the size transaction a sizing action began, under the keys
/// `begin_native_resize` answers with. A reply that began none is unchanged.
pub(crate) fn carry(mut reply: Value, resize: Option<Value>) -> Value {
    if let Some(mut resize) = resize.filter(|resize| resize["effect"].is_object()) {
        reply["transaction"] = resize["transaction"].take();
        reply["effect"] = resize["effect"].take();
    }
    reply
}

impl Controller {
    /// Restore points and remembered requests belong to a window with a
    /// source; upstream drops them when a client becomes a stand-in. The plan
    /// goes with its transaction: completed, failed, cancelled or retired.
    pub(crate) fn prune_sizes(&mut self) {
        let (scene, sources) = (&self.scene, &self.sources);
        let live = |id: &WindowId| sources.contains_key(id) && scene.window(*id).is_some();
        self.sizes.restore.retain(|id, _| live(id));
        self.sizes.restore_size.retain(|id, _| live(id));
        self.sizes.asked.retain(|id, _| live(id));
        self.sizes.configured.retain(|id, _| live(id));
        let slot = self.resize_slot().filter(|slot| slot.live);
        let current = |pending: &Pending| {
            slot.is_some_and(|slot| {
                slot.transaction == pending.transaction && slot.window == pending.window
            })
        };
        if !self.sizes.pending.as_ref().is_some_and(current) {
            self.sizes.pending = None;
        }
    }
    /// Upstream all_windows_with_snap_rects: every window that snaps, in
    /// stacking order. A widget and a screen-pinned window have no snap
    /// rectangle (snap_rect_for), so they are no obstacle to a fill and no
    /// member of a cluster.
    fn snap_rects(&self) -> Vec<(WindowId, SnapRect)> {
        self.scene
            .windows()
            .iter()
            .filter(|w| self.scene.snaps(w.id))
            .map(|w| (w.id, snap_rect(w.world_rect)))
            .collect()
    }
    /// Upstream's whole-pixel frame of a window: top-left and size. A window
    /// that has left fullscreen and is still owed its size back is measured
    /// by that size, upstream's restore authority: its frame still has the
    /// output's (src/tests/fullscreen_handoff.rs).
    fn px_frame(&self, window: WindowId) -> Result<(Px, Px), Error> {
        let (loc, size) = self.committed_frame(window)?;
        Ok((loc, self.fullscreen.restore_size(window).unwrap_or(size)))
    }
    /// The frame a window has: the size its last native observation committed.
    fn committed_frame(&self, window: WindowId) -> Result<(Px, Px), Error> {
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        frame(rect).map_err(Error::Refused)
    }
    /// A sizing action cannot begin while a size transaction is unresolved.
    pub(crate) fn busy(slot: ResizeSlot) -> String {
        format!(
            "a native resize of window {} is still pending",
            slot.window.0
        )
    }
    /// Upstream map_window for the element an action is aimed at: it goes to
    /// the top. True when the stacking, which is saved, changed.
    fn raise(&mut self, window: WindowId) -> Result<bool, Error> {
        let top = self.scene.windows().last().map(|w| w.id) == Some(window);
        self.scene.focus(window)?;
        Ok(!top)
    }
    /// Write where the plan puts the window at the size it has now. The size
    /// itself is never written here: only a native observation commits one.
    fn place(&mut self, window: WindowId, plan: &Plan) -> Option<Point> {
        let rect = self.scene.window(window)?.world_rect;
        let (_, actual) = frame(rect).ok()?;
        let placed = Rect {
            origin: point_of(plan.origin(actual)?),
            size: rect.size,
        };
        readable(placed).ok()?;
        self.scene.set_window_rect(window, placed).ok()?;
        Some(placed.origin)
    }
    /// Upstream configured_window_size: the size the window was last asked
    /// for, else the size it has. A fit centers on, and a fill grows from,
    /// the frame of that size at the window's top-left, whatever the window
    /// took of it (src/state/fit.rs compute_fit_geometry and
    /// fit_window_snapped, src/state/fill.rs compute_fill_geometry).
    ///
    /// Upstream's fullscreen exit configures the size from before, so that
    /// is what a window still owed it was last asked for, not the output's
    /// size its enter asked: the record follows the owed restore.
    fn configured_size(&self, window: WindowId, committed: Px) -> Px {
        if let Some(owed) = self.fullscreen.restore_size(window) {
            return owed;
        }
        let configured = self.sizes.configured.get(&window);
        configured.copied().unwrap_or(committed)
    }
    /// Record or clear the restore state as upstream does beside its configure.
    fn settle(&mut self, window: WindowId, plan: &Plan, asked: Asked) {
        self.sizes.configured.insert(window, asked.requested);
        match plan {
            // Upstream resize_element_to: clear_fit and clear_fill, and the
            // request becomes the one the next absolute resize measures from.
            Plan::Step | Plan::StepRestored { .. } | Plan::Absolute { .. } => {
                self.sizes.restore.remove(&window);
                self.sizes.restore_size.remove(&window);
                self.sizes.asked.insert(window, asked);
            }
            Plan::Fit {
                saved_size, shove, ..
            } => {
                if let Some((old, new)) = shove {
                    self.shove_cluster(window, *old, *new);
                }
                self.sizes.restore_size.entry(window).or_insert(*saved_size);
                // Upstream set_fit, then clear_fill. The size asked for is the
                // one the window is configured with for as long as it is fit.
                self.sizes.restore.insert(
                    window,
                    Restore::Fit {
                        saved_size: *saved_size,
                        configured: asked.requested,
                    },
                );
                self.sizes.asked.remove(&window);
            }
            Plan::Unfit { shove, .. } => {
                if let Some((old, new)) = shove {
                    self.shove_cluster(window, *old, *new);
                }
                self.sizes.restore.remove(&window);
                self.sizes.asked.remove(&window);
            }
            // Upstream set_fill, then clear_fit.
            Plan::Fill { saved, .. } => {
                self.sizes
                    .restore_size
                    .entry(window)
                    .or_insert(saved.pre_fill_size);
                self.sizes
                    .restore
                    .insert(window, Restore::Fill(saved.clone()));
                self.sizes.asked.remove(&window);
            }
            Plan::Unfill { .. } => {
                self.sizes.restore.remove(&window);
                self.sizes.asked.remove(&window);
            }
            // Fit and fill survive fullscreen, as upstream's stage entries do.
            Plan::Fullscreen => {
                self.fullscreen.answered(window);
                self.sizes.asked.remove(&window);
            }
            Plan::Unfullscreen { .. } => {
                self.fullscreen.restored(window);
                self.sizes.asked.remove(&window);
            }
        }
    }
    /// Ask the window for `target`. A window that already has that size needs
    /// nothing delivered: the plan is a logical placement, applied at once, as
    /// a move is. Otherwise a size transaction begins and the plan waits for
    /// its result.
    #[allow(clippy::too_many_arguments)]
    fn deliver(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        edges: Edges,
        target: Px,
        plan: Plan,
        asked: Asked,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        // Upstream's rule size is one-shot at the first commit, "so the user
        // can still resize": a window sized any other way is owed it no more.
        // `ask_ruled` has taken its window off the queue before it asks.
        self.policy.sizing.retain(|queued| *queued != window);
        let rect = self
            .scene
            .window(window)
            .ok_or(Error::Invalid("unknown window"))?
            .world_rect;
        // Refuse a frame no later request could read.
        if let Some(loc) = plan.origin(target) {
            readable(rect_at(loc, target)).map_err(Error::Refused)?;
        }
        // Upstream drop_owed_recenter: a size asked of a window that left
        // fullscreen replaces the one its exit still owed it.
        let restoring = matches!(plan, Plan::Unfullscreen { .. });
        if !restoring {
            self.fullscreen.restored(window);
        }
        // A window the adapter will not resize is asked nothing more: it is
        // fullscreen at the size it has, upstream's fixed-size client, and
        // fullscreen.rs centres it. Every other plan is still refused below.
        // Readback mode asks every time (`begin_sized_resize`), and the
        // setter's answer centres it as the first enter's does.
        let fixed = matches!(plan, Plan::Fullscreen)
            && !self.sizes.readback
            && self.sources.get(&window).is_some_and(|s| s.resize_disabled);
        if rect.size == size_of(target) || fixed {
            self.place(window, &plan);
            self.settle(window, &plan, asked);
            outcome.dirty = true;
            return Ok(());
        }
        // The transaction names an output only to end with it. A sizing action
        // needs none, so it rides on the active one when there is one.
        let output = output
            .or_else(|| self.scene.outputs().first().map(|o| o.id))
            .unwrap_or(OutputId(0));
        // A window pinned again by its exit is still handed its size back,
        // and a widget or a rule-pinned window the size its rule names.
        let by_hand = !restoring && !matches!(plan, Plan::Absolute { by_hand: false, .. });
        let began = self.begin_sized_resize(window, output, edges, size_of(target), by_hand)?;
        let transaction = self
            .resize_slot()
            .ok_or(Error::Invalid("resize transaction missing"))?
            .transaction;
        self.sizes.pending = Some(Pending {
            transaction,
            window,
            plan,
            asked,
            settled: false,
            placed: None,
        });
        outcome.resize = Some(began);
        Ok(())
    }
    /// The frame an absolute request that no observation has answered yet is
    /// taking `window` to: upstream writes that top-left beside its configure.
    pub(crate) fn owed_frame(&self, window: WindowId) -> Option<Rect> {
        let slot = self.resize_slot().filter(|slot| slot.live)?;
        let pending = self.sizes.pending.as_ref().filter(|p| !p.settled)?;
        if slot.window != window || slot.transaction != pending.transaction {
            return None;
        }
        let Plan::Absolute { loc, .. } = pending.plan else {
            return None;
        };
        Some(rect_at(loc, pending.asked.requested))
    }
    /// The pending request was walked back to the size the window has. The
    /// transaction sends no setter for a size already committed, and without
    /// one no result settles the plan, so what upstream writes beside its
    /// configure is written now, as `deliver` writes it for a window that
    /// already has the size asked for.
    fn settle_walked_back(&mut self, outcome: &mut Outcome) {
        let Some(mut pending) = self.sizes.pending.take() else {
            return;
        };
        let before = self
            .scene
            .window(pending.window)
            .map(|w| w.world_rect.origin);
        pending.placed = self.place(pending.window, &pending.plan);
        self.settle(pending.window, &pending.plan, pending.asked);
        pending.settled = true;
        outcome.dirty |= pending.placed.is_some() && pending.placed != before;
        self.sizes.pending = Some(pending);
    }
    /// A `native_resize_result`. The transaction commits the size the window
    /// actually has, exactly as for a drag; then, for a sizing action, what
    /// upstream would have written for that size: the placement, and once the
    /// setter has been attempted and observed, the restore state. A result
    /// that is valid for the transaction is never refused for a placement.
    ///
    /// A result that ends the transaction frees the one slot: the next
    /// window whose rule's `size` is still owed is asked in the same reply,
    /// whose `transaction` and `effect` are then that window's, the keys
    /// under which a transaction's own next effect comes back.
    pub(crate) fn sizing_result(
        &mut self,
        transaction: u64,
        effect_id: u64,
        identity: SourceIdentity,
        generation: u64,
        result: NativeResizeResult,
    ) -> Result<Value, Error> {
        let reply = self.planned_result(transaction, effect_id, identity, generation, result)?;
        if self.resize_slot().is_some_and(|slot| slot.live) {
            return Ok(reply);
        }
        let began = self.ask_ruled(None);
        Ok(carry(reply, began))
    }
    /// The transaction's own handling of a result, and the plan's.
    fn planned_result(
        &mut self,
        transaction: u64,
        effect_id: u64,
        identity: SourceIdentity,
        generation: u64,
        result: NativeResizeResult,
    ) -> Result<Value, Error> {
        let pending = self
            .sizes
            .pending
            .take()
            .filter(|pending| pending.transaction == transaction);
        let answer = self.resize_answer(transaction, effect_id);
        let (observed, attempted) = (result.observed, result.mutation_attempted);
        let size_before = pending
            .as_ref()
            .and_then(|pending| self.scene.window(pending.window))
            .map(|window| window.world_rect.size);
        let reply = self.native_resize_result(transaction, effect_id, identity, generation, result);
        let (Some(mut pending), Ok(reply)) = (pending.clone(), reply.as_ref()) else {
            // A refused result leaves the plan as it was.
            self.sizes.pending = pending;
            return reply;
        };
        let rect = self.scene.window(pending.window).map(|w| w.world_rect);
        if let (Some((requested, uncertain)), Some(rect), true) = (answer, rect, observed) {
            let setter = requested.is_some();
            // A setter sent before fullscreen.rs took the transaction over
            // asked for the other size, and its answer is none to the enter
            // or exit now in force unless the window has that one's size all
            // the same. The plan's own setter follows this result, or never
            // comes when the transaction was cancelled meanwhile: until one
            // has answered, the window is neither placed for the plan nor
            // counted as having its size.
            let asked = size_of(pending.asked.requested);
            let superseded = matches!(pending.plan, Plan::Fullscreen | Plan::Unfullscreen { .. })
                && requested.is_some_and(|size| size != asked)
                && rect.size != asked;
            // An attempted setter is behind this observation: its own result,
            // the read that follows an unresolved one, or a later read.
            if !superseded && ((setter && attempted) || uncertain || pending.settled) {
                let resized = size_before != Some(rect.size);
                let undisturbed = pending.placed.is_none_or(|at| at == rect.origin);
                if (!pending.settled || resized) && undisturbed {
                    pending.placed = self.place(pending.window, &pending.plan);
                }
                if !pending.settled {
                    // Readback mode, an absolute request the window took
                    // another size of: that size is the request upstream
                    // would have made of a client with these limits, and
                    // the one the next request is measured from.
                    if let Ok((_, actual)) = frame(rect)
                        && let Some(at) = pending.plan.origin(actual)
                        && let Plan::Absolute {
                            loc,
                            basis: Some(_),
                            ..
                        } = &mut pending.plan
                    {
                        *loc = at;
                        pending.asked.requested = actual;
                    }
                    self.settle(pending.window, &pending.plan, pending.asked);
                    pending.settled = true;
                }
            }
            // Readback mode: the baseline read found the window already at
            // the size asked for (it took it by itself before any `observe`
            // said so) and the transaction ended without a setter. The plan
            // is written as `deliver` writes it for a window that has the
            // size asked for.
            let ended = !self.resize_slot().is_some_and(|slot| slot.live);
            if self.sizes.readback && ended && !setter && !pending.settled && rect.size == asked {
                pending.placed = self.place(pending.window, &pending.plan);
                self.settle(pending.window, &pending.plan, pending.asked);
                pending.settled = true;
            }
        }
        self.sizes.pending = Some(pending);
        Ok(reply.clone())
    }

    /// Upstream's five sizing actions on the focused canvas window; with none
    /// focused, or with a widget or a screen-pinned window focused, they do
    /// nothing, as upstream's do (`is_canvas_window` in each arm).
    pub(crate) fn run_sizing(
        &mut self,
        output: Option<OutputId>,
        action: &Action,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        let Some(window) = self.scene.focused().filter(|id| self.on_canvas(*id)) else {
            return Ok(());
        };
        // A gesture places its windows from its own anchors at every motion,
        // and holds the camera a fit would fly.
        if self.gesture.is_some() {
            return Err(Error::Refused(GRABBED.to_owned()));
        }
        let step = i64::from(self.config().resize_step);
        match action {
            Action::GrowWindow(direction) => {
                self.step_resize(window, output, "grow-window", direction, step, outcome)
            }
            Action::ShrinkWindow(direction) => {
                self.step_resize(window, output, "shrink-window", direction, -step, outcome)
            }
            Action::FitWindow => self.toggle_fit(window, output, false, outcome),
            Action::FitWindowSnapped => self.toggle_fit(window, output, true, outcome),
            Action::FillWindow => self.toggle_fill(window, output, outcome),
            _ => Ok(()),
        }
    }
    /// Upstream step_resize_focused: the named edge walks `step` outward, or
    /// inward for a negative step, and the opposite edge stays where it is. A
    /// diagonal moves both of its edges by the rounded share of the step. The
    /// shift that holds the opposite edge still comes from the size the window
    /// is observed to take, so a step it only partly grants still anchors.
    fn step_resize(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        name: &str,
        direction: &Direction,
        step: i64,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        // Upstream resizes a stand-in's own frame. Here that frame is where its
        // window comes back to, at a size nothing could then deliver.
        if !self.sources.contains_key(&window) {
            return Err(Error::Refused(format!(
                "{name} needs a live window: a stand-in has no native size to change"
            )));
        }
        let edges = step_edges(direction);
        let (loc, committed) = self.px_frame(window)?;
        // Upstream placed_element_size: while a size is still owed the next
        // step walks on from the size asked for, so a held key steps at the
        // repeat rate and not at the window's answering rate. Only a step that
        // moves the same edges can share the transaction's anchoring.
        let slot = self.resize_slot().filter(|slot| slot.live);
        let walking = match (slot, &self.sizes.pending) {
            (Some(slot), Some(pending))
                if slot.transaction == pending.transaction
                    && slot.window == window
                    && slot.accepting
                    && match pending.plan {
                        Plan::Step => slot.edges == edges,
                        Plan::StepRestored { edges: moved, .. } => moved == edges,
                        _ => false,
                    } =>
            {
                Some(pending.asked.requested)
            }
            (Some(slot), _) => return Err(Error::Refused(Self::busy(slot))),
            (None, _) => None,
        };
        let current = walking.unwrap_or(committed);
        let (ux, uy) = direction.to_unit_vec();
        let dw = (ux.abs() * step as f64).round() as i64;
        let dh = (uy.abs() * step as f64).round() as i64;
        // Upstream SizeConstraints::clamp for a client that declares nothing:
        // one pixel. An axis the direction does not name keeps its size.
        let target = [
            if dw == 0 {
                current[0]
            } else {
                current[0].saturating_add(dw).max(1)
            },
            if dh == 0 {
                current[1]
            } else {
                current[1].saturating_add(dh).max(1)
            },
        ];
        if target == current {
            return Ok(());
        }
        outcome.dirty |= self.raise(window)?;
        let asked = Asked {
            requested: target,
            at_request: committed,
        };
        if walking.is_some() {
            self.retarget_sized_resize(size_of(target))?;
            if let Some(pending) = self.sizes.pending.as_mut() {
                pending.asked = asked;
                pending.settled = false;
            }
            if target == committed {
                self.settle_walked_back(outcome);
            }
            return Ok(());
        }
        // Upstream step_resize_focused after an exit: the step starts from the
        // place the exit restored and the size it owes. The frame still has
        // the output's size, so the transaction's edge anchoring cannot hold
        // the opposite edge: the plan does. `deliver` ends the owed restore.
        if self.fullscreen.restore_size(window).is_some() {
            let far = [
                loc[0].saturating_add(committed[0]),
                loc[1].saturating_add(committed[1]),
            ];
            let plan = Plan::StepRestored { loc, far, edges };
            let still = Edges::BottomRight;
            return self.deliver(window, output, still, target, plan, asked, outcome);
        }
        self.deliver(window, output, edges, target, Plan::Step, asked, outcome)
    }
    pub(crate) fn native_decoration(
        &mut self,
        window: WindowId,
        output: OutputId,
        identity: &SourceIdentity,
        generation: u64,
        action: &DecorationAction,
    ) -> Result<Value, Error> {
        self.check_generation(window, identity, generation)?;
        self.navigation_context(output)?;
        if !self.sizes.capability {
            return Err(Error::Invalid("native sizing is unavailable"));
        }
        self.guard_resize_structure(Some(window))?;
        let mut outcome = Outcome::default();
        match action {
            DecorationAction::Fullscreen => {
                self.decoration_fullscreen(window, output, &mut outcome)?;
            }
            DecorationAction::Fit => {
                if self.is_widget(window) || self.is_pinned(window) {
                    return Err(Error::Invalid("only a canvas window can be fitted"));
                }
                if let Some(held) = self.fullscreen_output_of(window) {
                    outcome.dirty |= self.exit_fullscreen_on(held).is_some();
                }
                self.toggle_fit(
                    window,
                    Some(output),
                    self.config().decoration_fit_snapped,
                    &mut outcome,
                )?;
            }
        }
        Ok(outcome.reply())
    }
    /// Upstream toggle_fit_window and toggle_fit_window_snapped. A fit sizes
    /// the window to the active output's usable area less `snap.outer_gap` on
    /// every side, keeps its center where it is and flies the camera there at
    /// zoom 1: `focus_placement` plays no part. The camera and the focus are
    /// asked for now, as upstream asks beside its configure, and neither
    /// depends on the size the window then takes. An unfit only gives the
    /// saved size back, around the center of the frame the fit asked for at
    /// the top-left the window has by then.
    fn toggle_fit(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        snapped: bool,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        // Upstream's focused_window is a client: a stand-in is never fitted.
        if !self.sources.contains_key(&window) {
            return Ok(());
        }
        if let Some(slot) = self.resize_slot().filter(|slot| slot.live) {
            return Err(Error::Refused(Self::busy(slot)));
        }
        let (loc, committed) = self.px_frame(window)?;
        let fit = match self.sizes.restore.get(&window) {
            Some(Restore::Fit {
                saved_size,
                configured,
            }) => Some((*saved_size, *configured)),
            _ => None,
        };
        // Upstream configured_window_size: a fit window is measured by the
        // frame the fit asked for, whatever the window then took, and any
        // other by the size it was last asked for.
        let size = fit.map_or_else(
            || self.configured_size(window, committed),
            |(_, configured)| configured,
        );
        let center = center_of(loc, size);
        let shove = |to: Px, extent: Px| {
            snapped.then(|| (snap_rect_at(loc, size), snap_rect_at(to, extent)))
        };
        if let Some((saved_size, _)) = fit {
            let to = loc_for_center(center, saved_size);
            let plan = Plan::Unfit {
                loc: to,
                pre_exit_size: committed,
                center,
                shove: shove(to, saved_size),
            };
            let asked = Asked {
                requested: saved_size,
                at_request: committed,
            };
            outcome.dirty |= self.raise(window)?;
            return self.deliver(
                window,
                output,
                Edges::BottomRight,
                saved_size,
                plan,
                asked,
                outcome,
            );
        }
        let output = output.ok_or(Error::Invalid("no active output"))?;
        let (_, usable) = self.view(output)?;
        let inset = self.navigation_context(output)?.outer_gap();
        let (at, extent) = usable_px(usable)?;
        // Upstream compute_fit_geometry, `as i32` truncations included.
        let target = [
            (extent[0] - (2.0 * inset) as i64).max(1),
            (extent[1] - (2.0 * inset) as i64).max(1),
        ];
        let usable_center = center_of(at, extent);
        let camera = Point::new(
            (center.x - usable_center.x).round(),
            (center.y - usable_center.y).round(),
        );
        let to = [
            camera.x as i64 + at[0] + inset as i64,
            camera.y as i64 + at[1] + inset as i64,
        ];
        readable(rect_at(to, target)).map_err(Error::Refused)?;
        // Upstream raise_and_focus, set_overview_return(None), then the pan
        // and the zoom to 1 around the usable center.
        let moved = self.raise_and_focus(window)?;
        if !moved.effect.is_null() {
            outcome.effects.push(moved.effect);
        }
        outcome.dirty = true;
        self.overview_returns.remove(&output);
        let anchor = Anchor {
            canvas: camera + usable_center,
            screen: usable_center,
        };
        outcome.navigation = self.arm_view(output, camera, 1.0, Some(anchor))?["navigation"].take();
        // Upstream saves restore_size, and the size the window has only when
        // no fit or fill has captured one since it was last resized.
        let saved_size = self.sizes.restore_size.get(&window).copied();
        let plan = Plan::Fit {
            loc: to,
            saved_size: saved_size.unwrap_or(committed),
            shove: shove(to, target),
        };
        let asked = Asked {
            requested: target,
            at_request: committed,
        };
        self.deliver(
            window,
            Some(output),
            Edges::BottomRight,
            target,
            plan,
            asked,
            outcome,
        )
    }
    /// Upstream toggle_fill_window. A fill grows the window in place inside
    /// the usable area of the output that shows it, `snap.outer_gap` from the
    /// area's edge and `snap.gap` from every other window, and pulls back an
    /// edge that sticks out. No camera moves. An unfill restores the frame the
    /// fill replaced.
    fn toggle_fill(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        outcome: &mut Outcome,
    ) -> Result<(), Error> {
        if !self.sources.contains_key(&window) {
            return Ok(());
        }
        if let Some(slot) = self.resize_slot().filter(|slot| slot.live) {
            return Err(Error::Refused(Self::busy(slot)));
        }
        let (loc, committed) = self.px_frame(window)?;
        if let Some(Restore::Fill(saved)) = self.sizes.restore.get(&window).cloned() {
            let plan = Plan::Unfill {
                loc: saved.pre_fill_position,
                pre_exit_size: committed,
                center: center_of(saved.pre_fill_position, saved.pre_fill_size),
            };
            let asked = Asked {
                requested: saved.pre_fill_size,
                at_request: committed,
            };
            outcome.dirty |= self.raise(window)?;
            return self.deliver(
                window,
                output,
                Edges::BottomRight,
                saved.pre_fill_size,
                plan,
                asked,
                outcome,
            );
        }
        // Upstream configured_window_size, as in toggle_fit: the fill grows
        // from the frame the window was last asked for, a fit's included,
        // and is measured against it.
        let size = match self.sizes.restore.get(&window) {
            Some(Restore::Fit { configured, .. }) => *configured,
            _ => self.configured_size(window, committed),
        };
        // Upstream compute_fill_geometry. A window no output shows, one wholly
        // outside the usable area and one that already fills its space are
        // left alone, and no restore point is recorded.
        let Some(home) = self.home_output(window, output)? else {
            return Ok(());
        };
        let context = self.navigation_context(home)?;
        let viewport = self
            .scene
            .output(home)
            .ok_or(Error::Invalid("unknown output"))?;
        let (at, extent) = usable_px(context.usable_rect_local)?;
        let low = viewport.camera + point_of(at) / viewport.zoom;
        let high =
            viewport.camera + point_of([at[0] + extent[0], at[1] + extent[1]]) / viewport.zoom;
        let bounds = SnapRect {
            x_low: low.x,
            x_high: high.x,
            y_low: low.y,
            y_high: high.y,
        };
        let obstacles: Vec<SnapRect> = self
            .snap_rects()
            .into_iter()
            .filter(|(other, _)| *other != window)
            .map(|(_, rect)| rect)
            .collect();
        let Some(filled) = fill_rect(
            snap_rect_at(loc, size),
            &obstacles,
            bounds,
            context.outer_gap(),
            self.config().snap_gap,
            (0.0, 0.0),
            (0.0, 0.0),
        ) else {
            return Ok(());
        };
        let target = [
            ((filled.x_high - filled.x_low).round() as i64).max(1),
            ((filled.y_high - filled.y_low).round() as i64).max(1),
        ];
        let to = [filled.x_low.round() as i64, filled.y_low.round() as i64];
        if target == size && to == loc {
            return Ok(());
        }
        // A fill that takes a window out of fit restores the size it had
        // before the fit, around the fit frame's center, as an unfit would.
        // Any other saves upstream's restore_size where the window is.
        let (pre_fill_position, pre_fill_size) = match self.sizes.restore.get(&window) {
            Some(Restore::Fit { saved_size, .. }) => (
                loc_for_center(center_of(loc, size), *saved_size),
                *saved_size,
            ),
            _ => (
                loc,
                self.sizes
                    .restore_size
                    .get(&window)
                    .copied()
                    .unwrap_or(committed),
            ),
        };
        let plan = Plan::Fill {
            loc: to,
            saved: FillSaved {
                pre_fill_position,
                pre_fill_size,
                viewport_bounds: bounds,
                viewport_output: home,
                filled_at: to,
            },
        };
        let asked = Asked {
            requested: target,
            at_request: committed,
        };
        outcome.dirty |= self.raise(window)?;
        self.deliver(
            window,
            output,
            Edges::BottomRight,
            target,
            plan,
            asked,
            outcome,
        )
    }
    /// fullscreen.rs's two requests, on the one transaction. With the slot
    /// free the size is delivered like any other. While the transaction in
    /// the slot is this window's own enter or exit and still takes a size,
    /// the newer request replaces it: an exit pressed while the enter is
    /// pending takes the latest-request slot, so the window is never left at
    /// the output's size, and the other way about. False when the slot is
    /// held by anything else: nothing was asked.
    pub(crate) fn fullscreen_resize(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        target: Px,
        screen: Screen,
        outcome: &mut Outcome,
    ) -> Result<bool, Error> {
        let (_, committed) = self.committed_frame(window)?;
        let plan = match screen {
            Screen::Fill => Plan::Fullscreen,
            // Upstream establish_exit_placement's target_center.
            Screen::Restore(loc) => Plan::Unfullscreen {
                place: loc.map(|loc| (loc, committed, center_of(loc, target))),
            },
        };
        let asked = Asked {
            requested: target,
            at_request: committed,
        };
        let Some(slot) = self.resize_slot().filter(|slot| slot.live) else {
            self.deliver(
                window,
                output,
                Edges::BottomRight,
                target,
                plan,
                asked,
                outcome,
            )?;
            return Ok(true);
        };
        let own = self.sizes.pending.as_ref().is_some_and(|pending| {
            pending.transaction == slot.transaction
                && pending.window == window
                && matches!(pending.plan, Plan::Fullscreen | Plan::Unfullscreen { .. })
        });
        if !own || slot.window != window || !slot.accepting {
            return Ok(false);
        }
        self.retarget_sized_resize(size_of(target))?;
        if let Some(pending) = self.sizes.pending.as_mut() {
            pending.plan = plan;
            pending.asked = asked;
            pending.settled = false;
            pending.placed = None;
        }
        // Walked back only while nothing has been sent. With a setter in
        // flight the window is about to take that size, and the transaction
        // then asks for this one: the plan waits for that setter's result.
        if target == committed && !slot.setting {
            self.settle_walked_back(outcome);
        }
        Ok(true)
    }
    /// Is the transaction in the slot fullscreen.rs's own for this window?
    /// `Some(true)` for an exit's, `Some(false)` for an enter's.
    pub(crate) fn fullscreen_pending(&self, window: WindowId) -> Option<bool> {
        let slot = self.resize_slot().filter(|slot| slot.live)?;
        let pending = self.sizes.pending.as_ref()?;
        if pending.transaction != slot.transaction || pending.window != window {
            return None;
        }
        match pending.plan {
            Plan::Fullscreen => Some(false),
            Plan::Unfullscreen { .. } => Some(true),
            _ => None,
        }
    }
    /// Upstream enter_fullscreen's saved size: fit and fill survive
    /// fullscreen, so a fit window comes back at the size its fit asked for
    /// and a filled one at the size its fill asked for
    /// (configured_window_size, whatever the window took of it); any other
    /// at its `restore_size`, else the size it has.
    pub(crate) fn windowed_size(&self, window: WindowId, committed: Px) -> Px {
        match self.sizes.restore.get(&window) {
            Some(Restore::Fit { configured, .. }) => *configured,
            Some(Restore::Fill(_)) => self.configured_size(window, committed),
            None => self
                .sizes
                .restore_size
                .get(&window)
                .copied()
                .unwrap_or(committed),
        }
    }
    /// Give one window a size, keeping its center: upstream cmd_resize, and the
    /// entry point for any policy that sets a size outright, such as a window
    /// rule's `size`. The top-left moves by half the difference from the size
    /// last asked for, in whole pixels, and is written for the size asked: a
    /// window that grants less keeps that top-left, as upstream's does when
    /// its client commits another size than it was configured with. In
    /// readback mode the size granted is taken for the client's limits,
    /// which upstream clamps to first: the center is kept for that size and
    /// it is the request on record (`Plan::Absolute`).
    /// Stacking is the caller's: IPC `resize` raises the window, a rule's
    /// `size` leaves it where the map put it. A widget and a screen-pinned
    /// window are the caller's to refuse in its own words, as IPC `resize`
    /// does; only the rule they mapped with asks one, and says so with
    /// `by_hand` false. True when a size was asked or written, false for the
    /// request that repeats the last one.
    pub(crate) fn request_window_size(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        size: Px,
        by_hand: bool,
        outcome: &mut Outcome,
    ) -> Result<bool, String> {
        let text = |error: Error| error.to_string();
        if !self.sources.contains_key(&window) {
            return Err(NO_SOURCE_IPC.to_string());
        }
        if self.gesture.is_some() {
            return Err(GRABBED_IPC.to_string());
        }
        let (loc, committed) = self.px_frame(window).map_err(text)?;
        let size = [size[0].max(1), size[1].max(1)];
        // Upstream requested_element_size: the request still outstanding, else
        // the last one the window's size still answers, else its size.
        let slot = self.resize_slot().filter(|slot| slot.live);
        let (current, position, outstanding) = match (slot, &self.sizes.pending) {
            (Some(slot), Some(pending))
                if slot.transaction == pending.transaction
                    && slot.window == window
                    && slot.accepting =>
            {
                let Plan::Absolute { loc, .. } = pending.plan else {
                    return Err(Self::busy(slot));
                };
                (pending.asked.requested, loc, true)
            }
            (Some(slot), _) => return Err(Self::busy(slot)),
            (None, _) => {
                let asked = self.sizes.asked.get(&window);
                let live = asked.filter(|asked| asked.answered_by(committed));
                (live.map_or(committed, |asked| asked.requested), loc, false)
            }
        };
        // The user's own request, whatever it names, ends a wait for a rule's
        // `size` (see `deliver`): an identical one never gets that far.
        self.policy.sizing.retain(|queued| *queued != window);
        // An identical request is a no-op rather than a second shift.
        if size == current {
            return Ok(false);
        }
        let to = [
            position[0] + (current[0] - size[0]) / 2,
            position[1] + (current[1] - size[1]) / 2,
        ];
        readable(rect_at(to, size))?;
        let basis = self.sizes.readback.then_some((position, current));
        let asked = Asked {
            requested: size,
            at_request: committed,
        };
        if outstanding {
            self.retarget_sized_resize(size_of(size)).map_err(text)?;
            if let Some(pending) = self.sizes.pending.as_mut() {
                pending.plan = Plan::Absolute {
                    loc: to,
                    by_hand,
                    basis,
                };
                pending.asked = asked;
                pending.settled = false;
            }
            if size == committed {
                self.settle_walked_back(outcome);
            }
            return Ok(true);
        }
        let plan = Plan::Absolute {
            loc: to,
            by_hand,
            basis,
        };
        self.deliver(
            window,
            output,
            Edges::BottomRight,
            size,
            plan,
            asked,
            outcome,
        )
        .map_err(text)?;
        Ok(true)
    }

    /// Upstream shift_cluster_around_primary: the snapped neighbours of a
    /// window follow its edges from `old` to `new`, in two passes over the
    /// resize cluster: right and bottom, then left and top. Each member moves
    /// by whole pixels and loses its fill restore point. Members keep their
    /// stacking, which upstream's re-map raises.
    fn shove_cluster(&mut self, primary: WindowId, old: SnapRect, new: SnapRect) {
        let dx_right = (new.x_high - old.x_high) as i32;
        let dx_left = (new.x_low - old.x_low) as i32;
        let dy_bottom = (new.y_high - old.y_high) as i32;
        let dy_top = (new.y_low - old.y_low) as i32;
        if dx_right == 0 && dx_left == 0 && dy_bottom == 0 && dy_top == 0 {
            return;
        }
        self.shove_pass(primary, old, true, dx_right, dy_bottom);
        self.shove_pass(primary, old, false, -dx_left, -dy_top);
    }
    /// One pass: upstream cluster_snapshot_for_resize_with_rects classifies the
    /// cluster against the frame the deltas are measured from, and
    /// apply_member_shifts moves whoever `resolve_cluster_shifts` shifts.
    fn shove_pass(
        &mut self,
        primary: WindowId,
        old: SnapRect,
        right_bottom: bool,
        width_delta: i32,
        height_delta: i32,
    ) {
        let gap = self.config().snap_gap;
        // Upstream snap_rects_with_primary: the primary counts where it was.
        let rects: Vec<(WindowId, SnapRect)> = self
            .snap_rects()
            .into_iter()
            .map(|(id, rect)| (id, if id == primary { old } else { rect }))
            .collect();
        let full = cluster_of(&primary, &rects, gap);
        // The primary's direct neighbours on a side, then every member of the
        // cluster reached through them that lies beyond that side.
        let shift_set = |side: Side| -> HashSet<WindowId> {
            let mut set = HashSet::new();
            let mut queue = VecDeque::new();
            for (id, rect) in &rects {
                if *id != primary && adjacent_side(&old, rect, gap) == Some(side) {
                    set.insert(*id);
                    queue.push_back(*id);
                }
            }
            let downstream = |rect: &SnapRect| match side {
                Side::Right => rect.x_low >= old.x_high,
                Side::Left => rect.x_high <= old.x_low,
                Side::Bottom => rect.y_low >= old.y_high,
                Side::Top => rect.y_high <= old.y_low,
            };
            while let Some(current) = queue.pop_front() {
                let Some((_, from)) = rects.iter().find(|(id, _)| *id == current) else {
                    continue;
                };
                for (id, rect) in &rects {
                    if *id != primary
                        && !set.contains(id)
                        && full.contains(id)
                        && adjacent_side(from, rect, gap).is_some()
                        && downstream(rect)
                    {
                        set.insert(*id);
                        queue.push_back(*id);
                    }
                }
            }
            set
        };
        let (x_side, y_side) = if right_bottom {
            (Side::Right, Side::Bottom)
        } else {
            (Side::Left, Side::Top)
        };
        let (x_set, y_set) = (shift_set(x_side), shift_set(y_side));
        // Stacking order, so that the cascade does not depend on a hash.
        let members: Vec<(WindowId, SnapRect)> = rects
            .iter()
            .filter(|(id, _)| *id != primary && full.contains(id))
            .copied()
            .collect();
        let classes: Vec<ResizeClassification> = members
            .iter()
            .map(|(id, rect)| ResizeClassification {
                axis_x: x_set.contains(id).then_some(x_side),
                axis_y: y_set.contains(id).then_some(y_side),
                initial_rect: *rect,
            })
            .collect();
        let mut current = old;
        if right_bottom {
            current.x_high += f64::from(width_delta);
            current.y_high += f64::from(height_delta);
        } else {
            current.x_low -= f64::from(width_delta);
            current.y_low -= f64::from(height_delta);
        }
        let (shifts, _) = resolve_cluster_shifts(
            &classes,
            width_delta,
            height_delta,
            gap,
            &[],
            Some((old, current)),
        );
        let mut shifts: Vec<(usize, (i32, i32))> = shifts.into_iter().collect();
        shifts.sort_by_key(|(index, _)| *index);
        for (index, (dx, dy)) in shifts {
            let id = members[index].0;
            let Some(rect) = self.scene.window(id).map(|w| w.world_rect) else {
                continue;
            };
            let moved = rect.translated(Point::new(dx.into(), dy.into()));
            if readable(moved).is_ok() && self.scene.set_window_rect(id, moved).is_ok() {
                self.sizes.clear_fill(id);
            }
        }
    }

    /// Upstream fill_restore_view: the camera and zoom a window's fill was
    /// computed in, on `output`, or `None` when the stored view no longer
    /// applies: another output, a window that has moved, a usable area of
    /// another shape, or a zoom the canvas cannot hold. Asked for canvas
    /// windows only: upstream's navigation returns for a pinned window before
    /// it asks, and so do `center_window`, `focus_center` and `pick` here.
    pub(crate) fn fill_restore_view(
        &self,
        window: WindowId,
        output: OutputId,
    ) -> Option<(Point, f64)> {
        let Some(Restore::Fill(saved)) = self.sizes.restore.get(&window) else {
            return None;
        };
        if saved.viewport_output != output || self.px_frame(window).ok()?.0 != saved.filled_at {
            return None;
        }
        let bounds = saved.viewport_bounds;
        let (width, height) = (bounds.x_high - bounds.x_low, bounds.y_high - bounds.y_low);
        if !(width > 0.0 && height > 0.0 && width.is_finite() && height.is_finite()) {
            return None;
        }
        let usable = self.navigation_context(output).ok()?.usable_rect_local;
        let (at, extent) = usable_px(usable).ok()?;
        if extent[0] <= 0 || extent[1] <= 0 {
            return None;
        }
        let (zoom_x, zoom_y) = (extent[0] as f64 / width, extent[1] as f64 / height);
        if (zoom_x - zoom_y).abs() > 1e-6 * zoom_x.max(zoom_y) || zoom_x > policy::MAX_ZOOM + 1e-9 {
            return None;
        }
        let zoom = zoom_x.min(policy::MAX_ZOOM);
        if zoom < policy::MIN_ZOOM_FLOOR {
            return None;
        }
        Some((
            Point::new(
                bounds.x_low - at[0] as f64 / zoom,
                bounds.y_low - at[1] as f64 / zoom,
            ),
            zoom,
        ))
    }
    /// Upstream's RestoreFillElseReset navigation, `center-window`'s and
    /// `focus-center`'s: a window still filled returns to the camera and zoom
    /// its fill ran in, which `focus_placement` does not re-aim; any other is
    /// brought to the focus placement point at zoom 1.
    pub(crate) fn navigate_restoring_fill(
        &mut self,
        window: WindowId,
        output: OutputId,
    ) -> Result<Moved, Error> {
        let Some((camera, zoom)) = self.fill_restore_view(window, output) else {
            return self.navigate_to_window(window, output, ZoomPolicy::Reset);
        };
        let (_, usable) = self.view(output)?;
        let screen = usable.center();
        let anchor = Anchor {
            canvas: camera + screen / zoom,
            screen,
        };
        self.overview_returns.remove(&output);
        let navigation = self.arm_view(output, camera, zoom, Some(anchor))?["navigation"].take();
        Ok(Moved {
            navigation,
            ..self.raise_and_focus(window)?
        })
    }
    /// Upstream ZoomToFitSnapped: a toggle like `zoom-to-fit`, over the focused
    /// canvas window's snap cluster only, stand-ins included. With no focused
    /// window, or with a widget or a screen-pinned window focused, and no
    /// return pending nothing happens. The cluster is of the windows that
    /// snap: no widget and no screen-pinned window is a member. Only cameras
    /// move, so this needs nothing of the shell's resize path.
    pub(crate) fn zoom_to_fit_snapped(&mut self, output: OutputId) -> Result<Value, Error> {
        let (viewport, usable) = self.view(output)?;
        let center = usable.center();
        if let Some(ret) = self.overview_returns.remove(&output) {
            return self.restore_view(output, ret, center);
        }
        let Some(focused) = self.scene.focused().filter(|id| self.on_canvas(*id)) else {
            return Ok(json!({"navigation": null}));
        };
        let cluster = cluster_of(&focused, &self.snap_rects(), self.config().snap_gap);
        // The frames at the integer boundary `zoom-to-fit` uses: floor the
        // origin and ceil the far edge, so a fractional frame is never clipped.
        let mut members = Vec::new();
        let (mut low, mut high) = ((i32::MAX, i32::MAX), (i32::MIN, i32::MIN));
        for window in self.scene.windows() {
            if !cluster.contains(&window.id) {
                continue;
            }
            let rect = window.world_rect;
            let (x, y) = (pixel(rect.origin.x.floor())?, pixel(rect.origin.y.floor())?);
            let (right, bottom) = (pixel(rect.right().ceil())?, pixel(rect.bottom().ceil())?);
            low = (low.0.min(x), low.1.min(y));
            high = (high.0.max(right), high.1.max(bottom));
            if high.0.checked_sub(low.0).is_none() || high.1.checked_sub(low.1).is_none() {
                return Err(Error::Invalid("view geometry exceeds integer range"));
            }
            members.push(((x, y).into(), (right - x, bottom - y).into()));
        }
        let Some(bbox) = policy::all_windows_bbox(members.into_iter()) else {
            return Ok(json!({"navigation": null}));
        };
        // Upstream fit_to_bbox.
        let fit = policy::zoom_to_fit(
            bbox,
            pixel_size(usable.size)?,
            self.config().zoom_fit_padding,
        );
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
    /// A window whose sizing action is still owed its size is placed by that
    /// action's plan when the result arrives, over wherever a drag had put it
    /// by then. So no drag takes it, alone or as a member dragged along. A
    /// transaction the pointer began is not this: NATIVE_RESIZE.md lets a
    /// world drag run while its last observation is still owed.
    pub(crate) fn guard_sizing_drag(
        &self,
        window: WindowId,
        group: bool,
        options: SnapOptions,
    ) -> Result<(), Error> {
        let slot = self.resize_slot().filter(|slot| slot.live);
        let (Some(slot), Some(pending)) = (slot, &self.sizes.pending) else {
            return Ok(());
        };
        if slot.transaction != pending.transaction {
            return Ok(());
        }
        if pending.window == window
            || (group
                && self
                    .scene
                    .cluster(window, options)?
                    .contains(&pending.window))
        {
            return Err(Error::Refused(Self::busy(slot)));
        }
        Ok(())
    }
    /// Upstream's move grabs: the dragged window, and with `group` every
    /// member of its cluster, is re-anchored and loses its fill restore point.
    pub(crate) fn drag_begun(
        &mut self,
        window: WindowId,
        group: bool,
        options: SnapOptions,
    ) -> Result<(), Error> {
        self.sizes.clear_fill(window);
        self.fullscreen.moved(window);
        if group {
            for member in self.scene.cluster(window, options)? {
                self.sizes.clear_fill(member);
                self.fullscreen.moved(member);
            }
        }
        Ok(())
    }
}
