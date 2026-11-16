// SPDX-License-Identifier: GPL-3.0-or-later
//! Owner intent and arrival policy. Facts carry monotonic nanoseconds; this
//! implementation never reads a clock or drives a native window.
// Arrival settlement adapted from https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/handlers/compositor.rs (first sized commit: raise, focus, navigate).
// Activation adapted from the same upstream @
// df3de27b26c7998e8a460cffd8a4925cbed3a322 (v0.21.0),
// src/state/navigation.rs (activate_window_output_local, window_already_active,
// resolve_click_navigate, fire_click_navigate), src/input/pointer.rs
// (click-to-focus fallback), src/handlers/mod.rs (focus_changed cycle rule).
// Unsolicited sibling placement is product policy, using upstream's unchanged
// layout::auto_placement::place_auto search (see lifecycle.rs provenance).
use crate::ipc::readable;
use crate::lifecycle::Arrival;
use crate::window_actions::{MinimalPan, Moved};
use crate::*;
use driftwm_core::config::{AppliedWindowRule, WindowPlacement};
use driftwm_core::layout::auto_placement::{self, place_auto};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::collections::HashSet;

const FOCUSED_CLICK_NS: u64 = 750_000_000;

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(crate) struct Process {
    pid: i32,
    birth_sec: i64,
    birth_usec: i32,
}
impl From<&SourceIdentity> for Process {
    fn from(id: &SourceIdentity) -> Self {
        Self {
            pid: id.pid,
            birth_sec: id.birth_sec,
            birth_usec: id.birth_usec,
        }
    }
}
#[derive(Clone, Debug)]
struct Authorization {
    process: Process,
    activate_until: u64,
    attach_until: u64,
}
#[derive(Clone, Debug)]
struct Restore {
    count: u64,
    since: u64,
    failed: bool,
}
#[derive(Clone, Debug, Default)]
pub(crate) struct FocusPolicy {
    filter: bool,
    focus_allowed: bool,
    initial_observation_done: bool,
    family_observation: Option<(Binding, SourceIdentity)>,
    background: Option<Background>,
    correction: Option<Correction>,
    switch_held: bool,
    system_until: u64,
    focused_click_at: u64,
    confirmed_process: Option<Process>,
    bundles: BTreeMap<String, u64>,
    processes: BTreeMap<i32, Authorization>,
    restores: BTreeMap<i32, Restore>,
}
/// One fact stream at the existing command seam. The caller supplies both the
/// read time and (for delayed workspace/worker facts) the original event time.
#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum FocusFact {
    WindowArrived {
        identity: SourceIdentity,
        bundle: String,
    },
    Reply {
        reply: Value,
        protect: bool,
    },
    ClearBackground,
    ClearFamily,
    CancelBackground,
    Answer {
        effect_id: u64,
        success: bool,
    },
    Application {
        process: Process,
        bundle: Option<String>,
        event_at: u64,
        activated: bool,
    },
    ObservationReceipt {
        context: ObservationReceipt,
        reply: Option<Value>,
    },
    Observation {
        actual: SourceIdentity,
        family: Option<Binding>,
        event_at: u64,
        output: Option<crate::OutputId>,
    },

    Switch {
        held: bool,
    },
    SystemUi,
    LaunchIntent {
        bundle: String,
    },
    WindowClick {
        window: Option<crate::WindowId>,
    },
    Confirmed {
        identity: SourceIdentity,
    },
    ResetRestores,
}
impl FocusPolicy {
    pub(super) fn configure(&mut self, filter: bool, focus_allowed: bool) {
        self.filter = filter;
        self.focus_allowed = focus_allowed;
    }
    fn prune(&mut self, now: u64) {
        self.bundles.retain(|_, until| *until >= now);
        self.processes
            .retain(|_, a| a.attach_until >= now || a.activate_until >= now);
        self.restores
            .retain(|_, r| !(now > r.since && now - r.since > 5_000_000_000));
    }
}
impl Controller {
    pub(crate) fn focus_policy_fact(&mut self, now: u64, fact: FocusFact) -> Result<Value, Error> {
        match fact {
            FocusFact::WindowArrived { identity, bundle } => {
                if !self.focus.policy.filter {
                    return Ok(json!({"unsolicited":false,"cancel_work":false}));
                }
                let (authorized, cancel) = self.authorize_owner(
                    now,
                    IntentQuery {
                        process: Process::from(&identity),
                        bundle: Some(bundle),
                        event_at: now,
                        same_app: true,
                        attach: true,
                        consume: true,
                    },
                )?;
                return Ok(json!({"unsolicited":!authorized,"cancel_work":cancel}));
            }
            FocusFact::ClearBackground => self.clear_background(),
            FocusFact::ClearFamily => self.focus.policy.family_observation = None,
            FocusFact::CancelBackground => {
                let cancel = self.cancel_background();
                return Ok(json!({"cancel_work":cancel}));
            }
            FocusFact::Answer { effect_id, success } => {
                if let Some(c) = self
                    .focus
                    .policy
                    .correction
                    .clone()
                    .filter(|c| c.effect.effect_id == effect_id)
                {
                    if !success && c.intruder_pid > 0 {
                        self.focus.policy.restores.insert(
                            c.intruder_pid,
                            Restore {
                                count: 2,
                                since: now,
                                failed: true,
                            },
                        );
                    }
                    self.clear_background();
                }
            }
            FocusFact::Reply { reply, protect } => {
                if protect {
                    self.preserve_arrival(now, &reply);
                }
                let effect = reply.get("effect").filter(|v| v.is_object()).or_else(|| {
                    reply["effects"]
                        .as_array()
                        .and_then(|es| es.iter().rev().find(|e| e["op"] == "focus_native_window"))
                });
                if let Some(effect) = effect {
                    if let Some(c) = self
                        .focus
                        .policy
                        .correction
                        .as_ref()
                        .filter(|c| effect["effect_id"].as_u64() == Some(c.effect.effect_id))
                    {
                        return Ok(
                            json!({"correction":true,"observed":c.observed,"intruder_pid":c.intruder_pid,"started_at":c.started_at}),
                        );
                    }
                    self.clear_background();
                    self.focus.policy.restores.clear();
                }
                return Ok(json!({"correction":false}));
            }
            FocusFact::Application {
                process,
                bundle,
                event_at,
                activated,
            } => {
                if !self.focus.policy.filter {
                    return Ok(json!({}));
                }
                let (authorized, cancel) = self.authorize_owner(
                    now,
                    IntentQuery {
                        process: process.clone(),
                        bundle,
                        event_at,
                        same_app: activated,
                        attach: false,
                        consume: false,
                    },
                )?;
                if authorized {
                    return Ok(json!({"observe":activated,"cancel_work":cancel}));
                }
                if activated
                    && let Some(target) = self
                        .confirmed_live_binding()
                        .filter(|b| b.identity.pid != process.pid)
                    && let Some(reply) = self.plan_correction(
                        now,
                        target,
                        process.pid,
                        None,
                        event_at,
                        true,
                        RestoreFailure::None,
                    )?
                {
                    return Ok(steps(reply));
                }
            }
            FocusFact::ObservationReceipt { context, reply } => {
                return self.observation_receipt(now, context, reply);
            }
            FocusFact::Observation {
                actual,
                family,
                event_at,
                output,
            } => return self.observe_owner_focus(now, actual, family, event_at, output),

            FocusFact::WindowClick { window } => {
                if window.is_some()
                    && self.focus.observed_native.as_ref().map(|e| e.window) == window
                {
                    self.focus.policy.focused_click_at = now;
                } else {
                    let cancel = self.cancel_background();
                    return Ok(json!({"cancel_work":cancel}));
                }
            }
            FocusFact::Switch { held } => {
                if held {
                    let cancel = self.cancel_background();
                    self.focus.policy.restores.clear();
                    self.focus.policy.switch_held = true;
                    self.focus.policy.system_until = now.wrapping_add(2_500_000_000);
                    return Ok(json!({"cancel_work":cancel}));
                } else if self.focus.policy.switch_held {
                    self.focus.policy.switch_held = false;
                    self.focus.policy.system_until = now.wrapping_add(1_500_000_000);
                }
            }
            FocusFact::SystemUi => {
                let cancel = self.cancel_background();
                self.focus.policy.restores.clear();
                self.focus.policy.system_until = now.wrapping_add(2_000_000_000);
                return Ok(json!({"cancel_work":cancel}));
            }
            FocusFact::LaunchIntent { bundle } => {
                if !bundle.is_empty() {
                    let cancel = self.cancel_background();
                    self.focus.policy.restores.clear();
                    self.focus
                        .policy
                        .bundles
                        .insert(bundle, now.wrapping_add(30_000_000_000));
                    return Ok(json!({"cancel_work":cancel}));
                }
            }
            FocusFact::Confirmed { identity } => {
                self.focus.policy.confirmed_process = Some(Process::from(&identity));
            }
            FocusFact::ResetRestores => self.focus.policy.restores.clear(),
        }
        Ok(json!({}))
    }
}

/// Closed decisions for the existing native driver adapter, not a command
/// language. Send is synchronous; only its first result can request a receipt.
#[derive(Clone, Debug, serde::Serialize, Deserialize)]
#[serde(tag = "step", rename_all = "snake_case")]
pub(crate) enum ObservationStep {
    CancelClick,
    Advance {
        release_hold: bool,
    },
    Send {
        command: Value,
        receipt: Option<ObservationReceipt>,
    },
    Answer {
        effect: Value,
        logical: bool,
        captured_epoch: bool,
    },
    PerformReply {
        correction: Value,
    },
    Changed,
}
#[derive(Clone, Debug, serde::Serialize, Deserialize)]
#[serde(tag = "receipt", rename_all = "snake_case")]
pub(crate) enum ObservationReceipt {
    Activated {
        binding: Binding,
        family: bool,
        actual: SourceIdentity,
    },
    Restore {
        target: Binding,
        observed: Option<SourceIdentity>,
        intruder_pid: i32,
        started_at: u64,
        made_at: u64,
        failure: Box<RestoreFailure>,
    },
}
#[derive(Clone, Debug, serde::Serialize, Deserialize)]
#[serde(tag = "failure", rename_all = "snake_case")]
pub(crate) enum RestoreFailure {
    None,
    Reject {
        focus_was_set: bool,
    },
    Arrival {
        actual: SourceIdentity,
        family: Option<Binding>,
        event_at: u64,
        output: Option<crate::OutputId>,
    },
}
fn steps(steps: Vec<ObservationStep>) -> Value {
    json!({"steps":steps})
}
fn send(command: Value) -> ObservationStep {
    ObservationStep::Send {
        command,
        receipt: None,
    }
}
fn advance() -> ObservationStep {
    ObservationStep::Advance {
        release_hold: false,
    }
}
fn cancellation(cancel: bool) -> Vec<ObservationStep> {
    if cancel {
        vec![
            ObservationStep::CancelClick,
            ObservationStep::Advance { release_hold: true },
            send(json!({"op":"cancel_focus_cycle"})),
        ]
    } else {
        vec![]
    }
}
fn reject_observation(focus_was_set: bool) -> Vec<ObservationStep> {
    let mut result = vec![ObservationStep::CancelClick, advance()];
    if focus_was_set {
        result.push(send(json!({"op":"focus_lost"})));
        result.push(ObservationStep::Changed);
    }
    result
}
fn binding_command(op: &str, binding: &Binding) -> Value {
    json!({"op":op,"window":binding.window,"identity":binding.identity,"generation":binding.generation})
}

struct IntentQuery {
    process: Process,
    bundle: Option<String>,
    event_at: u64,
    same_app: bool,
    attach: bool,
    consume: bool,
}
/// Exact live binding, not an identity inferred from a stale native window id.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, Deserialize)]
pub(crate) struct Binding {
    window: crate::WindowId,
    identity: SourceIdentity,
    generation: u64,
}
impl Binding {
    fn of(effect: &crate::FocusEffect) -> Self {
        Self {
            window: effect.window,
            identity: effect.identity.clone(),
            generation: effect.generation,
        }
    }
}
#[derive(Clone, Debug)]
struct Background {
    target: Binding,
    output: Option<crate::OutputId>,
    deadline: u64,
    arrivals: BTreeMap<crate::WindowId, (Binding, u64)>,
}
#[derive(Clone, Debug)]
struct Correction {
    target: Binding,
    effect: crate::FocusEffect,
    observed: Option<SourceIdentity>,
    intruder_pid: i32,
    started_at: u64,
}
impl Controller {
    fn classify_process(&mut self, now: u64, query: IntentQuery) -> Result<Value, Error> {
        let IntentQuery {
            process,
            bundle,
            event_at,
            same_app,
            attach,
            consume,
        } = query;
        if process.pid <= 0 {
            return Ok(json!({"authorized":false}));
        }
        self.focus.policy.prune(now);
        let live = self.confirmed_live_binding().map(|b| b.identity);
        if same_app {
            let same = if let Some(ref id) = live {
                self.focus.policy.confirmed_process = Some(Process::from(id));
                Process::from(id) == process
            } else {
                // Keep the process through its own unadopted Open/Save
                // panel, but only while the exact live intent survives.
                self.focus.policy.confirmed_process.as_ref() == Some(&process)
                    && self.focus.observed_native.is_none()
                    && self.focus.pending_effect.is_none()
                    && self
                        .scene
                        .focused()
                        .and_then(|w| self.sources.get(&w))
                        .is_some_and(|s| Process::from(&s.identity) == process)
            };
            if same {
                self.focus.policy.restores.remove(&process.pid);
                if consume && let Some(entry) = self.focus.policy.processes.get_mut(&process.pid) {
                    entry.attach_until = entry.attach_until.min(now.wrapping_add(1_500_000_000));
                }
                return Ok(json!({"authorized":true,"cancel_background":true}));
            }
        }
        let existing = self
            .focus
            .policy
            .processes
            .get(&process.pid)
            .is_some_and(|a| {
                let limit = if attach {
                    a.attach_until
                } else {
                    a.activate_until
                };
                a.process == process && (event_at <= limit || now <= limit)
            });
        let mut cancel = false;
        let authorized = if existing {
            true
        } else {
            let policy = &mut self.focus.policy;
            let system =
                policy.switch_held || event_at <= policy.system_until || now <= policy.system_until;
            let bundle_intent = bundle.as_ref().filter(|s| !s.is_empty()).is_some_and(|b| {
                // Objective-C's nil NSNumber was zero, not absent.
                let until = policy.bundles.get(b).copied().unwrap_or(0);
                until >= event_at || until >= now
            });
            let click = FOCUSED_CLICK_NS > 0
                && !system
                && !bundle_intent
                && policy.focused_click_at > 0
                && event_at >= policy.focused_click_at
                && event_at - policy.focused_click_at <= FOCUSED_CLICK_NS
                && live.as_ref().is_none_or(|id| id.pid != process.pid);
            if click {
                policy.focused_click_at = 0;
            }
            if system || bundle_intent || click {
                cancel = true;
                policy.restores.remove(&process.pid);
                if bundle_intent && let Some(bundle) = bundle {
                    policy.bundles.remove(&bundle);
                }
                let base = now.max(event_at);
                policy.processes.insert(
                    process.pid,
                    Authorization {
                        process: process.clone(),
                        activate_until: base.wrapping_add(4_000_000_000),
                        attach_until: base.wrapping_add(15_000_000_000),
                    },
                );
                true
            } else {
                false
            }
        };
        if authorized
            && consume
            && let Some(entry) = self.focus.policy.processes.get_mut(&process.pid)
        {
            entry.attach_until = entry.attach_until.min(now.wrapping_add(1_500_000_000));
        }
        Ok(json!({"authorized":authorized,"cancel_background":cancel}))
    }
    fn binding_live(&self, b: &Binding) -> bool {
        self.sources
            .get(&b.window)
            .is_some_and(|s| s.identity == b.identity && s.generation == b.generation)
    }
    fn focus_binding(&self, window: crate::WindowId) -> Option<Binding> {
        self.sources.get(&window).map(|s| Binding {
            window,
            identity: s.identity.clone(),
            generation: s.generation,
        })
    }
    fn confirmed_live_binding(&self) -> Option<Binding> {
        if let Some(c) = &self.focus.policy.correction
            && self.focus.pending_effect.as_ref() == Some(&c.effect)
            && self.scene.focused() == Some(c.target.window)
            && self.binding_live(&c.target)
        {
            return Some(c.target.clone());
        }
        let observed = self.focus.observed_native.as_ref()?;
        (self.focus.pending_effect.is_none()
            && self.scene.focused() == Some(observed.window)
            && self.binding_live(&Binding::of(observed)))
        .then(|| Binding::of(observed))
    }
    fn clear_background(&mut self) {
        self.focus.policy.background = None;
        self.focus.policy.correction = None;
    }
    fn cancel_background(&mut self) -> bool {
        let correcting = self
            .focus
            .policy
            .correction
            .as_ref()
            .is_some_and(|c| self.focus.pending_effect.as_ref() == Some(&c.effect));
        self.clear_background();
        correcting
    }
    fn preserve_arrival(&mut self, now: u64, reply: &Value) {
        let quiet = reply["focus_on_open_suppressed"].as_bool() == Some(true);
        if !self.focus.policy.focus_allowed
            || (!quiet && reply["background"].as_bool() != Some(true))
        {
            return;
        }
        let Some(window) = reply["window"].as_u64().map(crate::WindowId) else {
            return;
        };
        let Some(focused) = self.scene.focused() else {
            return;
        };
        let output = self
            .outputs
            .keys()
            .copied()
            .find(|o| self.fullscreen_on(*o) == Some(focused));
        if output.is_none() && !quiet {
            return;
        }
        let (Some(target), Some(arrival)) =
            (self.focus_binding(focused), self.focus_binding(window))
        else {
            return;
        };
        if target.window == arrival.window {
            return;
        }
        if quiet && self.confirmed_live_binding().as_ref() != Some(&target) {
            return;
        }
        let same = self
            .focus
            .policy
            .background
            .as_ref()
            .is_some_and(|b| b.target == target && b.output == output && now <= b.deadline);
        if !same && self.focus.policy.correction.is_none() {
            self.clear_background();
        }
        let deadline = now.wrapping_add(1_500_000_000);
        let b = self
            .focus
            .policy
            .background
            .get_or_insert_with(|| Background {
                target: target.clone(),
                output,
                deadline,
                arrivals: BTreeMap::new(),
            });
        b.target = target;
        b.output = output;
        b.deadline = deadline;
        b.arrivals.insert(arrival.window, (arrival, deadline));
    }
    // Only private bookkeeping happens here. The returned focus command is
    // sent before perform:'s epoch advance, as in the original adapter.
    #[allow(clippy::too_many_arguments)]
    fn plan_correction(
        &mut self,
        now: u64,
        target: Binding,
        pid: i32,
        observed: Option<SourceIdentity>,
        started_at: u64,
        limited: bool,
        failure: RestoreFailure,
    ) -> Result<Option<Vec<ObservationStep>>, Error> {
        if !self.focus.policy.focus_allowed || pid <= 0 {
            return Ok(None);
        }
        if limited {
            self.focus.policy.prune(now);
            if self
                .focus
                .policy
                .restores
                .get(&pid)
                .is_some_and(|r| r.failed || r.count >= 2)
            {
                return Ok(None);
            }
        }
        if self.focus.policy.correction.as_ref().is_some_and(|c| {
            c.target == target && self.focus.pending_effect.as_ref() == Some(&c.effect)
        }) {
            return Ok(Some(vec![]));
        }
        if limited {
            let entry = self.focus.policy.restores.entry(pid).or_insert(Restore {
                count: 0,
                since: now,
                failed: false,
            });
            entry.count += 1;
            entry.failed = false;
        }
        let command = json!({"op":"focus","window":target.window});
        let receipt = ObservationReceipt::Restore {
            target,
            observed,
            intruder_pid: pid,
            started_at,
            made_at: now,
            failure: Box::new(failure),
        };
        Ok(Some(vec![ObservationStep::Send {
            command,
            receipt: Some(receipt),
        }]))
    }
    fn observation_receipt(
        &mut self,
        now: u64,
        context: ObservationReceipt,
        reply: Option<Value>,
    ) -> Result<Value, Error> {
        match context {
            ObservationReceipt::Activated {
                binding,
                family,
                actual,
            } => {
                if family && reply.is_some() {
                    self.focus.policy.family_observation = Some((binding.clone(), actual));
                }
                if let Some(effect) = reply
                    .as_ref()
                    .and_then(|r| r.get("effect"))
                    .filter(|e| e.is_object())
                {
                    return Ok(steps(vec![ObservationStep::Answer {
                        effect: effect.clone(),
                        logical: family,
                        captured_epoch: false,
                    }]));
                }
                if reply.is_none() && !family {
                    return Ok(steps(vec![send(binding_command(
                        "observe_focus",
                        &binding,
                    ))]));
                }
                Ok(steps(vec![]))
            }
            ObservationReceipt::Restore {
                target,
                observed,
                intruder_pid,
                started_at,
                made_at,
                failure,
            } => {
                let effect = reply
                    .as_ref()
                    .and_then(|r| r.get("effect"))
                    .filter(|e| e.is_object())
                    .and(self.focus.pending_effect.clone());
                if let Some(effect) = effect {
                    let arrival = matches!(*failure, RestoreFailure::Arrival { .. });
                    let started_at = if arrival {
                        now
                    } else if started_at == 0 {
                        made_at
                    } else {
                        started_at
                    };
                    self.focus.policy.correction = Some(Correction {
                        target: target.clone(),
                        effect,
                        observed: observed.clone(),
                        intruder_pid,
                        started_at,
                    });
                    let deadline =
                        (if arrival { now } else { made_at }).wrapping_add(1_500_000_000);
                    let background =
                        self.focus
                            .policy
                            .background
                            .get_or_insert_with(|| Background {
                                target: target.clone(),
                                output: None,
                                deadline,
                                arrivals: BTreeMap::new(),
                            });
                    background.target = target;
                    background.deadline = deadline;
                    let correction = json!({"correction":true,"observed":observed,"intruder_pid":intruder_pid,"started_at":started_at});
                    return Ok(steps(vec![
                        ObservationStep::PerformReply { correction },
                        ObservationStep::Changed,
                    ]));
                }
                match *failure {
                    RestoreFailure::None => Ok(steps(vec![])),
                    RestoreFailure::Reject { focus_was_set } => {
                        self.focus.policy.confirmed_process = None;
                        Ok(steps(reject_observation(focus_was_set)))
                    }
                    RestoreFailure::Arrival {
                        actual,
                        family,
                        event_at,
                        output,
                    } => {
                        self.clear_background();
                        self.observe_owner_focus_from(now, actual, family, event_at, output, true)
                    }
                }
            }
        }
    }
    fn observe_arrival(
        &mut self,
        now: u64,
        binding: Option<&Binding>,
        failure: RestoreFailure,
    ) -> Result<Option<Vec<ObservationStep>>, Error> {
        let Some(background) = self.focus.policy.background.clone() else {
            return Ok(None);
        };
        let fullscreen = background
            .output
            .is_none_or(|o| self.fullscreen_on(o) == Some(background.target.window));
        if !self.focus.policy.focus_allowed
            || now > background.deadline
            || !fullscreen
            || self.scene.focused() != Some(background.target.window)
            || !self.binding_live(&background.target)
        {
            self.clear_background();
            return Ok(None);
        }
        let entry = binding.and_then(|b| background.arrivals.get(&b.window));
        if let Some((_, deadline)) = entry
            && self.focus.policy.correction.is_none()
            && now > *deadline
        {
            if let Some(b) = &mut self.focus.policy.background
                && let Some(binding) = binding
            {
                b.arrivals.remove(&binding.window);
            }
            return Ok(None);
        }
        if entry.is_none_or(|(arrival, _)| Some(arrival) != binding || !self.binding_live(arrival))
        {
            if binding != Some(&background.target) {
                self.clear_background();
            }
            return Ok(None);
        }
        if let Some(c) = &self.focus.policy.correction {
            if self.focus.pending_effect.as_ref() == Some(&c.effect) {
                return Ok(Some(vec![]));
            }
            self.clear_background();
            return Ok(None);
        }
        let arrival = binding.expect("entry has exact binding");
        self.plan_correction(
            now,
            background.target,
            arrival.identity.pid,
            Some(arrival.identity.clone()),
            0,
            false,
            failure,
        )
    }
    fn authorize_owner(&mut self, now: u64, query: IntentQuery) -> Result<(bool, bool), Error> {
        let reply = self.classify_process(now, query)?;
        let cancel = reply["cancel_background"].as_bool() == Some(true);
        let cancel_work = cancel && self.cancel_background();
        Ok((reply["authorized"].as_bool() == Some(true), cancel_work))
    }
    fn observe_owner_focus(
        &mut self,
        now: u64,
        actual: SourceIdentity,
        family: Option<Binding>,
        event_at: u64,
        output: Option<crate::OutputId>,
    ) -> Result<Value, Error> {
        self.observe_owner_focus_from(now, actual, family, event_at, output, false)
    }
    fn observe_owner_focus_from(
        &mut self,
        now: u64,
        actual: SourceIdentity,
        family: Option<Binding>,
        event_at: u64,
        output: Option<crate::OutputId>,
        skip_arrival: bool,
    ) -> Result<Value, Error> {
        let is_family = family.is_some();
        let binding = if let Some(b) = family.clone() {
            if now.wrapping_sub(event_at) > 100_000_000 || !self.binding_live(&b) {
                return Ok(steps(vec![]));
            }
            Some(b)
        } else {
            self.focus.policy.family_observation = None;
            self.sources
                .iter()
                .find(|(_, s)| s.identity == actual)
                .map(|(&w, _)| self.focus_binding(w).expect("source exists"))
        };
        if binding.is_none()
            && self.sources.values().any(|s| {
                let mut plain = s.identity.clone();
                plain.owner = None;
                plain == actual
            })
        {
            return Ok(steps(vec![]));
        }
        if !is_family
            && self.focus.policy.background.is_some()
            && now.wrapping_sub(event_at) > 100_000_000
        {
            return Ok(steps(vec![]));
        }
        if !skip_arrival && !is_family && now.wrapping_sub(event_at) <= 100_000_000 {
            let failure = RestoreFailure::Arrival {
                actual: actual.clone(),
                family: family.clone(),
                event_at,
                output,
            };
            if let Some(result) = self.observe_arrival(now, binding.as_ref(), failure)? {
                return Ok(steps(result));
            }
        }
        if let Some(b) = &binding
            && self
                .focus
                .pending_effect
                .as_ref()
                .is_some_and(|e| Binding::of(e) == *b)
        {
            return Ok(steps(vec![ObservationStep::Answer {
                effect: json!(self.focus.pending_effect),
                logical: is_family,
                captured_epoch: true,
            }]));
        }
        // Read the internal logical marker: the snapshot never exported it,
        // which made the former native family-observation dedup unreachable.
        if is_family
            && self
                .focus
                .policy
                .family_observation
                .as_ref()
                .is_some_and(|(b, a)| Some(b) == binding.as_ref() && *a == actual)
            && self.focus.logical == binding.as_ref().map(|b| b.window)
            && self.focus.pending_effect.is_none()
        {
            return Ok(steps(vec![]));
        }
        if !is_family
            && binding.as_ref().is_some_and(|b| {
                self.focus
                    .observed_native
                    .as_ref()
                    .is_some_and(|e| Binding::of(e) == *b)
            })
        {
            self.focus.policy.confirmed_process = Some(Process::from(&actual));
            return Ok(steps(vec![]));
        }
        if binding.is_none()
            && self.focus.observed_native.is_none()
            && self.focus.pending_effect.is_none()
        {
            return Ok(steps(vec![]));
        }
        let mut prefix = vec![];
        if self.focus.policy.filter
            && let Some(b) = &binding
        {
            let first = !self.focus.policy.initial_observation_done;
            self.focus.policy.initial_observation_done = true;
            if !is_family
                && self.focus.observed_native.is_none()
                && self.focus.pending_effect.is_none()
                && (self.scene.focused() == Some(b.window)
                    || (first && self.scene.focused().is_none()))
            {
                self.focus.policy.confirmed_process = Some(Process::from(&b.identity));
                return Ok(steps(vec![
                    ObservationStep::CancelClick,
                    advance(),
                    send(binding_command("observe_focus", b)),
                    ObservationStep::Changed,
                ]));
            }
            let (solicited, cancel) = if self.scene.focused() == Some(b.window) {
                (true, false)
            } else {
                self.authorize_owner(
                    now,
                    IntentQuery {
                        process: Process::from(&actual),
                        bundle: None,
                        event_at,
                        same_app: true,
                        attach: false,
                        consume: false,
                    },
                )?
            };
            prefix = cancellation(cancel);
            if !solicited {
                let focus_was_set =
                    self.focus.observed_native.is_some() || self.focus.pending_effect.is_some();
                if let Some(target) = self
                    .confirmed_live_binding()
                    .filter(|t| t.window != b.window)
                    && let Some(result) = self.plan_correction(
                        now,
                        target,
                        actual.pid,
                        (!is_family).then_some(actual.clone()),
                        event_at,
                        true,
                        RestoreFailure::Reject { focus_was_set },
                    )?
                {
                    prefix.extend(result);
                    return Ok(steps(prefix));
                }
                self.focus.policy.confirmed_process = None;
                prefix.extend(reject_observation(focus_was_set));
                return Ok(steps(prefix));
            }
        }
        prefix.extend([ObservationStep::CancelClick, advance()]);
        if let Some(b) = binding {
            self.focus.policy.confirmed_process = Some(Process::from(&b.identity));
            let mut command = binding_command("activate", &b);
            command["cause"] = json!(if is_family { "native_family" } else { "native" });
            command["output"] = json!(output);
            prefix.push(ObservationStep::Send {
                command,
                receipt: Some(ObservationReceipt::Activated {
                    binding: b,
                    family: is_family,
                    actual,
                }),
            });
        } else {
            if self.focus.policy.confirmed_process.as_ref() != Some(&Process::from(&actual)) {
                self.focus.policy.confirmed_process = None;
            }
            prefix.push(send(json!({"op":"focus_lost"})));
        }
        prefix.push(ObservationStep::Changed);
        Ok(steps(prefix))
    }
}

/// Placement policy for a window that appeared without owner launch/switch intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum UnsolicitedPlacement {
    /// Group with existing canvas windows of the same `bundle_id`, else place
    /// just outside the active viewport's right edge.
    SiblingOrOutsideViewport,
    /// Group with off-screen siblings of the same `bundle_id`, else use normal
    /// `window_placement`.
    #[allow(dead_code)]
    SiblingOffscreenOrConfigured,
    /// Use normal `window_placement` unchanged.
    #[allow(dead_code)]
    Configured,
}
const UNSOLICITED_PLACEMENT: UnsolicitedPlacement = UnsolicitedPlacement::SiblingOrOutsideViewport;

fn rects_overlap(a: auto_placement::Rect, b: auto_placement::Rect) -> bool {
    a.x < b.x_high() && b.x < a.x_high() && a.y < b.y_high() && b.y < a.y_high()
}

impl Controller {
    /// Placement of an unsolicited post-launch window (isolated by
    /// `UNSOLICITED_PLACEMENT`): groups with an existing canvas window of the
    /// same `bundle_id`, or places just outside the active viewport's right
    /// edge so background launches do not cover the active workspace.
    pub(super) fn unsolicited_spawn(
        &self,
        output: Option<OutputId>,
        pointer: Option<Point>,
        bundle_id: &str,
        size: Size,
    ) -> Result<Arrival, Error> {
        if UNSOLICITED_PLACEMENT == UnsolicitedPlacement::Configured {
            return self.spawn(output, pointer, size);
        }
        let (w, h) = (size.width.round(), size.height.round());
        let config = self.config();
        let gap = config.snap_gap;
        let step = f64::from(config.decorations.title_bar_height.max(1));
        let view_info = if let Some(output) = output {
            let viewport = self
                .scene
                .output(output)
                .ok_or(Error::Invalid("unknown output"))?;
            let context = self.navigation_context(output)?;
            let zoom = viewport.zoom.max(1e-6);
            let view_w = viewport.screen_bounds.size.width / zoom;
            let view_h = viewport.screen_bounds.size.height / zoom;
            let margin = gap.max(context.outer_gap()).max(48.0);
            let raw_view = auto_placement::Rect {
                x: viewport.camera.x.floor(),
                y: viewport.camera.y.floor(),
                w: view_w.ceil(),
                h: view_h.ceil(),
            };
            let protected_view = auto_placement::Rect {
                x: (viewport.camera.x - margin).floor(),
                y: (viewport.camera.y - margin).floor(),
                w: (view_w + 2.0 * margin).ceil(),
                h: (view_h + 2.0 * margin).ceil(),
            };
            let mid_y = viewport.camera.y + context.usable_rect_local.center().y / zoom;
            Some((raw_view, protected_view, mid_y))
        } else {
            None
        };
        let canvas_windows: Vec<&Window> = self
            .scene
            .windows()
            .iter()
            .filter(|win| self.on_canvas(win.id))
            .collect();
        let window_rects: Vec<auto_placement::Rect> = canvas_windows
            .iter()
            .map(|win| {
                let r = self.placed_rect(win);
                auto_placement::Rect {
                    x: r.origin.x.round(),
                    y: r.origin.y.round(),
                    w: r.size.width.round(),
                    h: r.size.height.round(),
                }
            })
            .collect();
        let sibling_indices: Vec<usize> = (0..canvas_windows.len())
            .filter(|&i| !bundle_id.is_empty() && self.bundle(canvas_windows[i].id) == bundle_id)
            .collect();
        let chosen_sibling = match UNSOLICITED_PLACEMENT {
            UnsolicitedPlacement::SiblingOrOutsideViewport => sibling_indices
                .iter()
                .rev()
                .copied()
                .find(|&i| view_info.is_none_or(|(_, pv, _)| !rects_overlap(window_rects[i], pv)))
                .or_else(|| sibling_indices.last().copied()),
            UnsolicitedPlacement::SiblingOffscreenOrConfigured => {
                let any_visible = sibling_indices.iter().any(|&i| {
                    view_info.is_some_and(|(rv, _, _)| rects_overlap(window_rects[i], rv))
                });
                if any_visible || sibling_indices.is_empty() {
                    return self.spawn(output, pointer, size);
                }
                sibling_indices.last().copied()
            }
            UnsolicitedPlacement::Configured => None,
        };
        let mut at = if let Some(sibling_idx) = chosen_sibling {
            let anchor = window_rects[sibling_idx];
            let mut rects = window_rects.clone();
            let eligible: HashSet<usize> = (0..rects.len()).collect();
            if let Some((_, pv, _)) = view_info
                && !rects_overlap(anchor, pv)
            {
                // Keep the sibling's cluster growth out of the active viewport.
                rects.push(pv);
            }
            place_auto(
                &rects,
                sibling_idx,
                &eligible,
                w,
                h,
                (anchor.cx(), anchor.cy()),
                gap,
            )
            .map(|(x, y)| (x.round(), y.round()))
            .unwrap_or((anchor.x, (anchor.y_high() + gap).round()))
        } else if let Some((_, pv, mid_y)) = view_info {
            let mut rects = Vec::with_capacity(1 + window_rects.len());
            rects.push(pv);
            rects.extend_from_slice(&window_rects);
            let eligible: HashSet<usize> = (0..rects.len()).collect();
            let park_x = pv.x_high() + gap.round();
            let park_y = (mid_y - (h / 2.0).trunc()).round();
            let bias = (park_x + w / 2.0 + 16.0, mid_y);
            place_auto(&rects, 0, &eligible, w, h, bias, gap)
                .map(|(x, y)| (x.round(), y.round()))
                .unwrap_or((park_x, park_y))
        } else {
            (0.0, 0.0)
        };
        while self.scene.windows().iter().any(|window| {
            let origin = self.placed_rect(window).origin;
            (origin.x.round() - at.0).abs() <= 2.0 && (origin.y.round() - at.1).abs() <= 2.0
        }) {
            at = (at.0 + step, at.1 + step);
        }
        let rect = Rect::new(at.0, at.1, size.width, size.height);
        readable(rect).map_err(Error::Refused)?;
        Ok(Arrival::Place {
            rect,
            at_cursor: false,
            background: false,
        })
    }
    /// Upstream's placement of a new toplevel at its first sized commit:
    /// `window_placement` picks the spot (cursor_placement_pos,
    /// auto_placement_pos, else the `focus_placement` point of the navigation
    /// that follows), and cascade_position walks it off any window whose
    /// top-left it would sit on. Without an active output upstream has no view
    /// to place in and uses the origin. The pointer is a global screen point,
    /// read through the active output's own bounds and camera.
    fn spawn(
        &self,
        output: Option<OutputId>,
        pointer: Option<Point>,
        size: Size,
    ) -> Result<Arrival, Error> {
        // Upstream geometry is whole pixels: the policy sees the rounded size,
        // the world frame keeps the true one.
        let (w, h) = (size.width.round(), size.height.round());
        let config = self.config();
        let (mut at, mut at_cursor) = ((0.0, 0.0), false);
        if let Some(output) = output {
            let viewport = self
                .scene
                .output(output)
                .ok_or(Error::Invalid("unknown output"))?;
            let context = self.navigation_context(output)?;
            let usable = context.usable_rect_local;
            let (camera, zoom) = (viewport.camera, viewport.zoom);
            let chosen = match config.window_placement {
                WindowPlacement::Center => None,
                WindowPlacement::Cursor => pointer.map(|pointer| {
                    let cursor = viewport.screen_to_world(pointer);
                    let low = camera + usable.origin / zoom;
                    let high = camera + Point::new(usable.right(), usable.bottom()) / zoom;
                    // An oversized frame keeps its top-left on the usable edge.
                    let x = (cursor.x - w / 2.0).clamp(low.x, (high.x - w).max(low.x));
                    let y = (cursor.y - h / 2.0).clamp(low.y, (high.y - h).max(low.y));
                    (x.round(), y.round())
                }),
                WindowPlacement::Auto => self.auto_spawn(viewport, usable, (w, h))?,
            };
            at_cursor = chosen.is_some() && config.window_placement == WindowPlacement::Cursor;
            at = chosen.unwrap_or_else(|| {
                // The align point takes the zoom the navigation lands at, the
                // canvas conversion the current one; halving is upstream's
                // integer division.
                let landing = if config.zoom_reset_on_new_window {
                    1.0
                } else {
                    zoom
                };
                let align = context.align_point(Size::new(w, h), landing);
                (
                    (camera.x + align.x / zoom).round() - (w / 2.0).trunc(),
                    (camera.y + align.y / zoom).round() - (h / 2.0).trunc(),
                )
            });
        }
        let step = f64::from(config.decorations.title_bar_height.max(1));
        while self.scene.windows().iter().any(|window| {
            let origin = self.placed_rect(window).origin;
            (origin.x.round() - at.0).abs() <= 2.0 && (origin.y.round() - at.1).abs() <= 2.0
        }) {
            at = (at.0 + step, at.1 + step);
        }
        let rect = Rect::new(at.0, at.1, size.width, size.height);
        readable(rect).map_err(Error::Refused)?;
        Ok(Arrival::Place {
            rect,
            at_cursor,
            background: false,
        })
    }
    /// A window has appeared: the slot it adopts, or where it is placed. `rule`
    /// is what its window rules merge to. An adopted window keeps its slot
    /// whatever the rule says of position or pinning, as upstream's does.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn arrival(
        &self,
        output: Option<OutputId>,
        pointer: Option<Point>,
        bundle_id: &str,
        title: &str,
        size: Size,
        rule: Option<&AppliedWindowRule>,
        unsolicited: bool,
    ) -> Result<Arrival, Error> {
        if output.is_some_and(|output| self.scene.output(output).is_none()) {
            return Err(Error::Invalid("unknown output"));
        }
        if pointer.is_some_and(|pointer| !pointer.valid()) {
            return Err(Error::Invalid("invalid screen point"));
        }
        if let Some(slot) = self.adoption_target(bundle_id, title) {
            return Ok(Arrival::Adopt(slot));
        }
        // Upstream: a rule's pin or position comes before the placement policy,
        // and fullscreen before auto, cursor and center: a new window never
        // lands on a fullscreen one, and nothing cascades it.
        if let Some(arrival) = self.rule_arrival(output, size, rule)? {
            return Ok(arrival);
        }
        if unsolicited && self.lifecycle.settled {
            return self.unsolicited_spawn(output, pointer, bundle_id, size);
        }
        match self.fullscreen_background(output, size) {
            Some(rect) => Ok(Arrival::Place {
                rect,
                at_cursor: false,
                background: true,
            }),
            None => self.spawn(output, pointer, size),
        }
    }
    /// What upstream does once the new window is mapped. An adopted window
    /// keeps its slot's frame and stacking and the camera stays; it takes the
    /// focus only when its stand-in held it. A placed window is raised, focused
    /// and navigated to, resetting the zoom with `zoom.reset_on_new_window`;
    /// cursor placement stays put unless that reset has a zoomed-out view to
    /// rescue. A window pinned by its rule is raised and focused without a
    /// navigation; a widget, a window whose rule says `focus_on_open = false`,
    /// or an unsolicited window is neither focused nor navigated to. During the
    /// launch pass nothing asks for native focus or moves a camera: those
    /// windows were already open, and nobody opened them here.
    pub(crate) fn settle_arrival(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        arrival: Arrival,
        unsolicited: bool,
    ) -> Result<Value, Error> {
        let (mut effect, mut navigation) = (Value::Null, Value::Null);
        self.log_arrival(window, output, arrival)?;
        // Upstream: a widget and a `focus_on_open = false` window map without
        // taking the focus or moving the camera; unsolicited arrivals do too.
        let rule = self.policy.applied.get(&window);
        let is_widget = rule.is_some_and(|r| r.widget);
        let quiet =
            unsolicited || is_widget || rule.is_some_and(|r| r.focus_on_open == Some(false));
        let focus_on_open_suppressed = self.lifecycle.settled
            && !is_widget
            && (unsolicited || rule.is_some_and(|r| r.focus_on_open == Some(false)));
        let reveal = self.lifecycle.settled && !quiet;
        match arrival {
            Arrival::Adopt(_) => {
                if self.scene.focused() == Some(window) {
                    if reveal {
                        effect = self.request_focus(window)?["effect"].take();
                    } else if !quiet {
                        // Nothing is asked during the launch pass, so no answer
                        // can come: the focus the slot kept enters the history
                        // as a request answered `focus_logical` does, unless
                        // the slot is screen-pinned. A widget, and a window
                        // whose rule says `focus_on_open = false`, asks for
                        // nothing and records nothing at any time.
                        self.confirm_focus(window)?;
                    }
                }
            }
            // A pinned window has no canvas position to navigate to: it is
            // raised and focused where it is.
            Arrival::Pin { .. } => {
                if reveal {
                    effect = self.raise_and_focus(window)?.effect;
                }
            }
            // Upstream: a window placed in the background never activates.
            Arrival::Place {
                at_cursor,
                background,
                ..
            } => {
                if let Some(output) = output.filter(|_| reveal && !background) {
                    let reset = self.config().zoom_reset_on_new_window;
                    let zoom = self
                        .scene
                        .output(output)
                        .ok_or(Error::Invalid("unknown output"))?
                        .zoom;
                    let stays = at_cursor && !(reset && zoom < 1.0 - 1e-9);
                    // A drag or resize in progress keeps its camera.
                    if !stays && self.gesture.is_none() {
                        let policy = if reset {
                            ZoomPolicy::Reset
                        } else {
                            ZoomPolicy::Keep
                        };
                        navigation = self.arm_navigation(window, output, policy)?;
                    }
                    effect = self.raise_and_focus(window)?.effect;
                }
            }
        }
        let adopted = matches!(arrival, Arrival::Adopt(_));
        let background = matches!(
            arrival,
            Arrival::Place {
                background: true,
                ..
            }
        );
        let mut reply = json!({"window":window,"adopted":adopted,"background":background,"effect":effect,"navigation":navigation,"dirty":true});
        // Native applications may activate themselves while opening. Only an
        // explicit post-launch rule supplies authority for the shell to correct
        // that initial activation; widgets and startup adoption do not.
        if focus_on_open_suppressed {
            reply["focus_on_open_suppressed"] = json!(true);
        }
        Ok(reply)
    }
}

/// Upstream ACTIVATION_VISIBLE_THRESHOLD: an activated window that is clipped
/// at all is brought fully into view.
const ACTIVATION_VISIBLE_THRESHOLD: f64 = 1.0;
/// Upstream ACTIVATION_ONSCREEN_THRESHOLD: separates clipped to a hair from
/// off screen entirely.
const ACTIVATION_ONSCREEN_THRESHOLD: f64 = f64::EPSILON;

impl Controller {
    /// The zoom an activation's reveal lands at: `zoom.reset_on_activation`.
    fn activation_zoom(&self) -> ZoomPolicy {
        match self.config().zoom_reset_on_activation {
            true => ZoomPolicy::Reset,
            false => ZoomPolicy::Keep,
        }
    }
    /// What upstream does when a window is clicked or asks to be activated:
    /// the command's reply.
    pub(crate) fn activate(
        &mut self,
        window: WindowId,
        output: Option<OutputId>,
        cause: ActivationCause,
        identity: Option<SourceIdentity>,
        generation: Option<u64>,
    ) -> Result<Value, Error> {
        self.window_rect(window)?;
        self.require_source_interactive(window)?;
        if let Some(output) = output {
            self.navigation_context(output)?;
        }
        if let Some(identity) = &identity {
            self.fresh(window, identity)?;
        }
        if let Some(generation) = generation {
            let source = self
                .sources
                .get(&window)
                .ok_or(Error::Invalid("unbound source"))?;
            if source.generation != generation {
                return Err(Error::Invalid("stale binding generation"));
            }
        }
        let moved = match cause {
            // Upstream's click-to-focus fallback: raise and focus at the press.
            // The camera stays, so the press and its drags reach the window
            // where the pointer is.
            ActivationCause::Click => self.raise_and_focus(window)?,
            // Upstream resolve_click_navigate and fire_click_navigate: with
            // `auto_navigate_on_click`, a completed click on a window that
            // still holds focus and is not wholly inside the usable area
            // brings it into view at the current zoom. No focus is requested,
            // so the reply has no `effect`: the press's request stays as it is.
            ActivationCause::ClickRelease => {
                let navigation = match output {
                    // Upstream arms no click navigation for a widget, and a
                    // pinned window has no canvas position to bring into view.
                    // v0.20: judged at the live view the click was made on,
                    // not the landing view, so a window shown whole leaves a
                    // flight under way alone, and the click scrolls the
                    // window just far enough to show it whole instead of
                    // centering it, so that it stays near the pointer.
                    Some(output)
                        if self.config().auto_navigate_on_click
                            && self.on_canvas(window)
                            && self.scene.focused() == Some(window)
                            && !self
                                .fully_in_viewport(window, output)
                                .map_err(Error::Refused)? =>
                    {
                        let (camera, zoom) = self.landing_view(output)?;
                        match self.reveal_frame(window) {
                            Some(frame) => {
                                self.hover_parked();
                                self.pan_minimally(output, &frame, camera, zoom, MinimalPan::Whole)?
                            }
                            None => Value::Null,
                        }
                    }
                    _ => Value::Null,
                };
                return Ok(json!({"navigation":navigation,"dirty":false}));
            }
            ActivationCause::Native | ActivationCause::NativeFamily => {
                let family = cause == ActivationCause::NativeFamily;
                let source = self
                    .sources
                    .get(&window)
                    .ok_or(Error::Invalid("unbound source"))?;
                let observed = FocusEffect {
                    op: "observed_native_focus",
                    effect_id: 0,
                    window,
                    identity: source.identity.clone(),
                    generation: source.generation,
                };
                // A fullscreen window's home is the output it fills, whatever
                // other camera happens to show the canvas it is parked on.
                let home = match self.fullscreen_output_of(window) {
                    Some(own) => Some(own).filter(|own| self.scene.output(*own).is_some()),
                    None => self.home_output(window, output)?,
                };
                let shown = |controller: &Self| match home {
                    Some(home) => controller.visible_share(window, home),
                    None => Ok(0.0),
                };
                let share = shown(self)?;
                // Upstream window_already_active: the window holds the keyboard
                // and is at least partly on screen, so the request asks for
                // what already holds.
                let holds_keyboard = if family {
                    self.focus.logical == Some(window)
                } else {
                    self.focus.observed_native.as_ref().is_some_and(|held| {
                        held.window == window
                            && held.identity == observed.identity
                            && held.generation == observed.generation
                    })
                };
                // Event delivery (docs/crates/desktop/LIFECYCLE.md): the same report again while
                // the window is still off screen and the flight the first one
                // armed is in the air asks for what is already under way.
                // Upstream's repeat sets the camera target it already has.
                let revealing = home.is_some_and(|home| {
                    self.on_canvas(window) && self.flying_to(window, home, self.activation_zoom())
                });
                if self.scene.focused() == Some(window)
                    && holds_keyboard
                    && (share >= ACTIVATION_ONSCREEN_THRESHOLD || revealing)
                {
                    return Ok(Moved::default().reply_with_dirty());
                }
                // A hover focus's own echo: recorded where the window stands.
                if !family && let Some(echo) = self.hover_echo(&observed)? {
                    return Ok(echo);
                }
                // Upstream activate_window_output_local: another window being
                // activated on a fullscreen output ends that fullscreen first,
                // so the target is not focused behind it and what is visible
                // is judged by the restored camera, not the parked one.
                let ended = home
                    .filter(|home| self.fullscreen_on(*home).is_some_and(|held| held != window))
                    .and_then(|home| self.exit_fullscreen_on(home));
                let share = match ended {
                    Some(_) => shown(self)?,
                    None => share,
                };
                // The observation is the focus: nothing is asked of the adapter.
                self.finish_cycle();
                self.focus.pending_effect = None;
                self.focus.logical = family.then_some(window);
                self.scene.focus(window)?;
                self.confirm_focus(window)?;
                self.focus.observed_native = (!family).then_some(observed);
                // Upstream activate_window_output_local: wholly visible on its
                // home output is focus only; any clipping pans that output. A
                // widget or a screen-pinned window is focused where it is.
                let navigation = match home {
                    Some(home)
                        if share < ACTIVATION_VISIBLE_THRESHOLD && self.on_canvas(window) =>
                    {
                        self.arm_navigation(window, home, self.activation_zoom())?
                    }
                    _ => Value::Null,
                };
                Moved {
                    effect: Value::Null,
                    navigation,
                    refocused: true,
                }
            }
        };
        Ok(moved.reply_with_dirty())
    }
}
