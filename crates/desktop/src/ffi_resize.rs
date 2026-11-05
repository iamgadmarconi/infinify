// SPDX-License-Identifier: GPL-3.0-or-later
use super::{Controller, WindowId};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Allocation-free read-only query: may the shell remove `window` (every window when
/// `all_windows` is nonzero; `window` is then ignored) given the current size transaction?
/// Returns 1 and writes the Boolean to `*allowed` on success. Returns 0 and writes nothing for
/// null arguments or a panic: callers must then ask the command path, never assume permission.
/// Grants no native ownership.
///
/// # Safety
/// Pointers must be null or live and aligned for this call. Serialize access to the controller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_resize_removal_allowed(
    controller: *const Controller,
    all_windows: u8,
    window: u64,
    allowed: *mut u8,
) -> u8 {
    if controller.is_null() || allowed.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller holds a live controller with exclusive access.
        let controller = unsafe { &*controller };
        let window = (all_windows == 0).then_some(WindowId(window));
        let ok = controller.resize_removal_allowed(window);
        // SAFETY: allowed is live and aligned for writing.
        unsafe { allowed.write(u8::from(ok)) };
        1
    }))
    .unwrap_or(0)
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::driftwm_desktop_create;
    use serde_json::{Value, json};
    fn call(controller: *mut Controller, value: Value) -> Option<Value> {
        // SAFETY: the test owns the controller and accesses it exclusively.
        unsafe { &mut *controller }
            .request(&serde_json::to_vec(&json!({"version":1,"command":value})).unwrap())
            .ok()
    }
    fn query(controller: *const Controller, all: u8, window: u64) -> (u8, u8) {
        let mut allowed = 7;
        // SAFETY: live controller and output.
        let ok = unsafe {
            driftwm_desktop_resize_removal_allowed(controller, all, window, &mut allowed)
        };
        (ok, allowed)
    }
    /// The predicate the shell used to derive from a full snapshot.
    fn from_snapshot(controller: *mut Controller, window: Option<u64>) -> bool {
        let snapshot = call(controller, json!({"op":"snapshot"})).unwrap();
        let t = &snapshot["native_resize"];
        if !t.is_object() || window.is_some_and(|w| t["window"].as_u64() != Some(w)) {
            return true;
        }
        t["pending_effect"].is_null()
            && t["uncertain_mutation"] != json!(true)
            && matches!(t["phase"].as_str(), Some("complete" | "failed"))
    }
    fn agree(controller: *mut Controller, seen: &mut Vec<(bool, String)>) {
        let snapshot = call(controller, json!({"op":"snapshot"})).unwrap();
        let phase = format!(
            "{}/{}/{}",
            snapshot["native_resize"]["phase"],
            snapshot["native_resize"]["pending_effect"].is_null(),
            snapshot["native_resize"]["uncertain_mutation"]
        );
        for window in [None, Some(1), Some(2), Some(0), Some(99)] {
            let expected = from_snapshot(controller, window);
            let got = match window {
                None => query(controller, 1, 1),
                Some(w) => query(controller, 0, w),
            };
            assert_eq!(got, (1, u8::from(expected)), "{phase} window {window:?}");
            if window.is_none() {
                // The window is ignored for "all windows".
                assert_eq!(query(controller, 1, 77), got);
                seen.push((expected, phase.clone()));
            }
        }
    }
    fn unanswered(effect: &Value) -> Value {
        let setter = effect["requested"].is_object();
        let none = json!({"origin":{"x":0,"y":0},"size":{"width":0,"height":0}});
        json!({"op":"native_resize_result","transaction":effect["transaction"],
            "effect_id":effect["effect_id"],"identity":effect["identity"],
            "generation":effect["generation"],"result":{"outcome":"timed_out",
            "ax_error":-25204,"mutation_attempted":setter,"observed":false,
            "requested":if setter { effect["requested"].clone() } else { json!({"width":0,"height":0}) },
            "actual_ax":none,"actual_cg":none}})
    }
    #[test]
    fn typed_removal_query_equals_snapshot_predicate_across_transactions() {
        let controller = driftwm_desktop_create();
        let mut seen = Vec::new();
        call(
            controller,
            json!({"op":"register_output","stable_id":"removal","screen_bounds":{"origin":{"x":0,"y":0},"size":{"width":1000,"height":800}}}),
        );
        let rect = json!({"origin":{"x":0,"y":0},"size":{"width":300,"height":200}});
        for wid in 1..=2 {
            call(
                controller,
                json!({"op":"attach","identity":{"pid":123,"birth_sec":1800000000,"birth_usec":5,"wid":wid},"bundle_id":"test","title":"w","buffer":{"width":300,"height":200},"source_rect":rect,"world_rect":rect}),
            );
        }
        call(
            controller,
            json!({"op":"native_resize_capability","enabled":true}),
        );
        // No transaction: everything may be removed.
        agree(controller, &mut seen);
        assert_eq!(query(controller, 1, 0), (1, 1));
        // A size request: an effect is pending; walk it to the end, unanswered, so that a
        // setter's timeout leaves the mutation uncertain on the way.
        let reply = call(
            controller,
            json!({"op":"ipc","output":1,"request":{"Resize":{"window":1,"to":[320,200]}}}),
        )
        .unwrap();
        let mut effect = reply["effect"].clone();
        assert!(effect.is_object());
        agree(controller, &mut seen);
        assert_eq!(query(controller, 0, 1), (1, 0));
        assert_eq!(query(controller, 0, 2), (1, 1));
        // The baseline read is taken, so that the setter's timeout is an uncertain mutation.
        let observed = json!({"op":"native_resize_result","transaction":effect["transaction"],
            "effect_id":effect["effect_id"],"identity":effect["identity"],
            "generation":effect["generation"],"result":{"outcome":"observed",
            "ax_error":0,"mutation_attempted":false,"observed":true,
            "requested":{"width":0,"height":0},"actual_ax":rect,"actual_cg":rect}});
        effect = call(controller, observed).unwrap()["effect"].clone();
        agree(controller, &mut seen);
        for _ in 0..8 {
            if !effect.is_object() {
                break;
            }
            effect = call(controller, unanswered(&effect)).unwrap()["effect"].clone();
            agree(controller, &mut seen);
        }
        assert!(effect.is_null());
        // A pointer grab: held with no effect owed once its baseline is read.
        let reply = call(
            controller,
            json!({"op":"begin_native_resize","window":1,"output":1,"edges":"right","start_screen":{"x":50,"y":50}}),
        )
        .unwrap();
        let effect = reply["effect"].clone();
        agree(controller, &mut seen);
        let result = json!({"op":"native_resize_result","transaction":effect["transaction"],
            "effect_id":effect["effect_id"],"identity":effect["identity"],
            "generation":effect["generation"],"result":{"outcome":"observed",
            "ax_error":0,"mutation_attempted":false,"observed":true,
            "requested":{"width":0,"height":0},"actual_ax":rect,"actual_cg":rect}});
        let next = call(controller, result).unwrap();
        assert!(next["effect"].is_null());
        agree(controller, &mut seen);
        let snapshot = call(controller, json!({"op":"snapshot"})).unwrap();
        assert_eq!(snapshot["native_resize"]["phase"], "dragging");
        assert_eq!(query(controller, 1, 0), (1, 0));
        assert_eq!(query(controller, 0, 1), (1, 0));
        assert_eq!(query(controller, 0, 2), (1, 1));
        call(
            controller,
            json!({"op":"cancel_native_resize","transaction":snapshot["native_resize"]["transaction"]}),
        );
        agree(controller, &mut seen);
        // Both outcomes were exercised.
        assert!(seen.iter().any(|(ok, _)| *ok) && seen.iter().any(|(ok, _)| !*ok));
        assert!(
            seen.iter()
                .any(|(_, p)| p.ends_with("/true") && !p.contains("null")),
            "uncertain: {seen:?}"
        );
        // Null arguments and a missing output never authorize anything.
        let mut allowed = 7;
        // SAFETY: null arguments are rejected.
        unsafe {
            assert_eq!(
                driftwm_desktop_resize_removal_allowed(std::ptr::null(), 1, 0, &mut allowed),
                0
            );
            assert_eq!(
                driftwm_desktop_resize_removal_allowed(controller, 1, 0, std::ptr::null_mut()),
                0
            );
        }
        assert_eq!(allowed, 7);
    }
}
