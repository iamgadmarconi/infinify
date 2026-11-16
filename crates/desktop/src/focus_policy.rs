// SPDX-License-Identifier: GPL-3.0-or-later
//! Owner intent and arrival policy. Facts carry monotonic nanoseconds; this
//! implementation never reads a clock or drives a native window.
use crate::{Controller, Error, SourceIdentity};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;

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
    Switch {
        held: bool,
    },
    SystemUi,
    LaunchIntent {
        bundle: String,
    },
    FocusedClick,
    Authorize {
        process: Process,
        bundle: Option<String>,
        event_at: u64,
        same_app: bool,
        attach: bool,
        #[serde(default)]
        consume: bool,
        /// A native correction in flight still preserves confirmed authority.
        correction: Option<SourceIdentity>,
    },
    Confirmed {
        identity: SourceIdentity,
    },
    ClearConfirmed {
        actual: Option<SourceIdentity>,
    },
    ResetRestores,
    RestoreAllowed {
        pid: i32,
    },
    RestoreAttempt {
        pid: i32,
    },
    RestoreFailed {
        pid: i32,
    },
}
impl FocusPolicy {
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
            FocusFact::Switch { held } => {
                if held {
                    self.focus.policy.restores.clear();
                    self.focus.policy.switch_held = true;
                    self.focus.policy.system_until = now.wrapping_add(2_500_000_000);
                } else if self.focus.policy.switch_held {
                    self.focus.policy.switch_held = false;
                    self.focus.policy.system_until = now.wrapping_add(1_500_000_000);
                }
            }
            FocusFact::SystemUi => {
                self.focus.policy.restores.clear();
                self.focus.policy.system_until = now.wrapping_add(2_000_000_000);
            }
            FocusFact::LaunchIntent { bundle } => {
                if !bundle.is_empty() {
                    self.focus.policy.restores.clear();
                    self.focus
                        .policy
                        .bundles
                        .insert(bundle, now.wrapping_add(30_000_000_000));
                }
            }
            FocusFact::FocusedClick => self.focus.policy.focused_click_at = now,
            FocusFact::Confirmed { identity } => {
                self.focus.policy.confirmed_process = Some(Process::from(&identity));
            }
            FocusFact::ClearConfirmed { actual } => {
                if actual.as_ref().map(Process::from) != self.focus.policy.confirmed_process {
                    self.focus.policy.confirmed_process = None;
                }
            }
            FocusFact::ResetRestores => self.focus.policy.restores.clear(),
            FocusFact::RestoreAllowed { pid } => {
                self.focus.policy.prune(now);
                return Ok(
                    json!({"allowed": pid > 0 && self.focus.policy.restores.get(&pid).is_none_or(|r| !r.failed && r.count < 2)}),
                );
            }
            FocusFact::RestoreAttempt { pid } => {
                let r = self.focus.policy.restores.entry(pid).or_insert(Restore {
                    count: 0,
                    since: now,
                    failed: false,
                });
                r.count += 1;
                r.failed = false;
            }
            FocusFact::RestoreFailed { pid } => {
                self.focus.policy.restores.insert(
                    pid,
                    Restore {
                        count: 2,
                        since: now,
                        failed: true,
                    },
                );
            }
            FocusFact::Authorize {
                process,
                bundle,
                event_at,
                same_app,
                attach,
                consume,
                correction,
            } => {
                if process.pid <= 0 {
                    return Ok(json!({"authorized":false}));
                }
                self.focus.policy.prune(now);
                let live = self.confirmed_focus_identity().cloned().or(correction);
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
                    let system = policy.switch_held
                        || event_at <= policy.system_until
                        || now <= policy.system_until;
                    let bundle_intent =
                        bundle.as_ref().filter(|s| !s.is_empty()).is_some_and(|b| {
                            // Objective-C's nil NSNumber was zero, not absent.
                            let until = policy.bundles.get(b).copied().unwrap_or(0);
                            until >= event_at || until >= now
                        });
                    let click = !system
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
                return Ok(json!({"authorized":authorized,"cancel_background":cancel}));
            }
        }
        Ok(json!({}))
    }
    fn confirmed_focus_identity(&self) -> Option<&SourceIdentity> {
        let observed = self.focus.observed_native.as_ref()?;
        let source = self.sources.get(&observed.window)?;
        (self.focus.pending_effect.is_none()
            && self.scene.focused() == Some(observed.window)
            && source.generation == observed.generation
            && source.identity == observed.identity)
            .then_some(&source.identity)
    }
}
