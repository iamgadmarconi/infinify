// SPDX-License-Identifier: GPL-3.0-or-later
//! Controller integration scenarios cross the exported C ABI and JSON decoder.
//! They provide no native rendering, capture, or input-delivery evidence.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;

struct Host(*mut Controller);
impl Host {
    fn new() -> Self {
        let handle = driftwm_desktop_create();
        assert!(!handle.is_null());
        Self(handle)
    }
    fn raw(&mut self, bytes: &[u8]) -> Value {
        // SAFETY: live exclusive handle, valid bytes, response freed exactly once.
        unsafe {
            let response = driftwm_desktop_request(self.0, bytes.as_ptr(), bytes.len());
            assert!(!response.is_null());
            let result = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            driftwm_desktop_response_free(response);
            result
        }
    }
    fn call(&mut self, command: Value) -> Value {
        self.raw(&serde_json::to_vec(&json!({"version":1,"command":command})).unwrap())
    }
    fn ok(&mut self, command: Value) -> Value {
        let response = self.call(command);
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }
    fn snapshot(&mut self) -> Value {
        self.ok(json!({"op":"snapshot"}))
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        unsafe {
            driftwm_desktop_destroy(self.0);
        }
    }
}
fn identity(id: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":50,"wid":id,"owner":789})
}
fn attach(host: &mut Host, id: u64, logical: Option<u64>) -> Value {
    host.ok(json!({"op":"attach","identity":identity(id),"bundle_id":"test","title":"fixture","buffer":{"width":100,"height":100},"source_rect":{"origin":{"x":0.25,"y":0.5},"size":{"width":100.125,"height":100.75}},"logical_id":logical}))["window"].clone()
}
fn result(effect: &Value, success: bool) -> Value {
    json!({"op":"focus_result","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"],"success":success})
}
fn focus(host: &mut Host, id: u64) -> Value {
    host.ok(json!({"op":"focus","window":id}))["effect"].clone()
}
fn cycle(host: &mut Host, backward: bool, held: bool) -> Value {
    host.ok(json!({"op":"cycle_focus","backward":backward,"held":held}))["effect"].clone()
}
fn populated() -> Host {
    let mut host = Host::new();
    for id in 1..=3 {
        attach(&mut host, id, None);
        let effect = focus(&mut host, id);
        host.ok(result(&effect, true));
    }
    assert_eq!(host.snapshot()["focus"]["history"], json!([3, 2, 1]));
    host
}
#[test]
fn frozen_cycle_supersession_release_failure_and_external_focus() {
    let mut host = populated();
    let first = cycle(&mut host, false, true);
    assert_eq!(first["window"], 2);
    let second = cycle(&mut host, false, true);
    assert_eq!(second["window"], 1);
    let before = host.snapshot();
    assert_eq!(before["focus"]["history"], json!([3, 2, 1]));
    assert_eq!(before["focus"]["observed_native"]["window"], 3);
    assert_eq!(host.call(result(&first, true))["ok"], false);
    assert_eq!(before, host.snapshot());
    host.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(host.snapshot()["focus"]["history"], json!([3, 2, 1]));
    host.ok(result(&second, true));
    assert_eq!(host.snapshot()["focus"]["history"], json!([1, 3, 2]));
    let failed = cycle(&mut host, true, false);
    assert_eq!(failed["window"], 3); // fresh backward is upstream index one
    host.ok(result(&failed, false));
    let state = host.snapshot();
    assert_eq!(state["focus"]["intent"], 3);
    assert_eq!(state["focus"]["observed_native"]["window"], 1);
    assert_eq!(state["focus"]["history"], json!([1, 3, 2]));
    assert!(state["focus"]["cycle"].is_null());
    let old = cycle(&mut host, false, true);
    let normal = focus(&mut host, 2);
    assert_eq!(host.call(result(&old, true))["ok"], false);
    host.ok(result(&normal, true));
    assert_eq!(host.snapshot()["focus"]["history"], json!([2, 1, 3]));
    let old = cycle(&mut host, false, true);
    host.ok(json!({"op":"observe_focus","window":3,"identity":identity(3),"generation":3}));
    assert_eq!(host.snapshot()["focus"]["history"], json!([3, 2, 1]));
    assert_eq!(host.call(result(&old, true))["ok"], false);
    let selected = cycle(&mut host, false, true);
    host.ok(result(&selected, true));
    let normal = focus(&mut host, 1); // commits successful selection 2, then awaits 1
    assert_eq!(host.snapshot()["focus"]["history"], json!([2, 3, 1]));
    host.ok(result(&normal, true));
    assert_eq!(host.snapshot()["focus"]["history"], json!([1, 2, 3]));
}
#[test]
fn detach_rebind_cancel_and_rejected_commands_are_atomic() {
    let mut host = populated();
    let old = cycle(&mut host, false, true);
    let before = host.snapshot();
    assert_eq!(host.call(json!({"op":"focus","window":999}))["ok"], false);
    assert_eq!(before, host.snapshot());
    host.ok(
        json!({"op":"remove_source","window":2,"identity":identity(2),"keep_placeholder":true}),
    );
    assert_eq!(host.call(result(&old, true))["ok"], false);
    assert!(focus(&mut host, 2).is_null());
    assert_eq!(host.snapshot()["focus"]["history"], json!([3, 1]));
    let head = cycle(&mut host, false, true);
    assert_eq!(head["window"], 3); // detached intent is outside MRU
    host.ok(json!({"op":"cancel_focus_cycle"}));
    assert_eq!(host.call(result(&head, true))["ok"], false);
    attach(&mut host, 2, Some(2)); // exact same identity, new generation
    let replacement = focus(&mut host, 2);
    assert_ne!(replacement["generation"], old["generation"]);
    let mut stale = result(&replacement, true);
    stale["generation"] = old["generation"].clone();
    let before = host.snapshot();
    assert_eq!(host.call(stale)["ok"], false);
    assert_eq!(before, host.snapshot());
    host.ok(result(&replacement, true));
    assert_eq!(host.snapshot()["focus"]["history"], json!([2, 3, 1]));
}
#[test]
fn version_one_roundtrip_preserves_geometry_order_intent_and_clears_authority() {
    let mut host = populated();
    let old = cycle(&mut host, false, true);
    let before = host.snapshot();
    let path = std::env::temp_dir().join(format!("stage-focus-save-{}.json", std::process::id()));
    host.ok(json!({"op":"save","path":path}));
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(saved["version"], 1);
    let keys = saved["scene"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(keys, vec!["bookmarks", "focused", "outputs", "windows"]);
    assert!(!saved.to_string().contains("generation"));
    host.ok(json!({"op":"load","path":path}));
    std::fs::remove_file(path).unwrap();
    let after = host.snapshot();
    assert_eq!(before["focus"]["intent"], after["focus"]["intent"]);
    for (a, b) in before["windows"]
        .as_array()
        .unwrap()
        .iter()
        .zip(after["windows"].as_array().unwrap())
    {
        assert_eq!(a["window"], b["window"]);
        assert_eq!(a["world_rect"], b["world_rect"]);
        assert!(b["source"].is_null());
    }
    for key in ["observed_native", "pending_effect", "last_result", "cycle"] {
        assert!(after["focus"][key].is_null());
    }
    assert_eq!(after["focus"]["history"], json!([]));
    assert_eq!(host.call(result(&old, true))["ok"], false);
    attach(&mut host, 2, Some(2));
    let new = focus(&mut host, 2);
    assert!(new["effect_id"].as_u64() > old["effect_id"].as_u64());
    assert!(new["generation"].as_u64() > old["generation"].as_u64());
    let before_stale = host.snapshot();
    assert_eq!(host.call(result(&old, true))["ok"], false);
    assert_eq!(before_stale, host.snapshot());
    host.ok(result(&new, true));
}

#[test]
fn removal_clamps_frozen_history_without_losing_unrelated_request() {
    let mut host = populated();
    cycle(&mut host, false, true);
    let selected = cycle(&mut host, false, true);
    assert_eq!(selected["window"], 1);
    host.ok(json!({"op":"forget","window":2}));
    let snapshot = host.snapshot();
    assert_eq!(snapshot["focus"]["history"], json!([3, 1]));
    assert_eq!(snapshot["focus"]["cycle"], 1);
    assert_eq!(snapshot["focus"]["pending_effect"], selected);
    host.ok(result(&selected, true));
    host.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(host.snapshot()["focus"]["history"], json!([1, 3]));
}

#[test]
fn native_focus_ownership_loss_cancels_without_fabricating_history() {
    let mut host = populated();
    let pending = cycle(&mut host, false, true);
    host.ok(json!({"op":"focus_lost"}));
    let snapshot = host.snapshot();
    assert_eq!(snapshot["focus"]["intent"], 2);
    assert_eq!(snapshot["focus"]["history"], json!([3, 2, 1]));
    for key in ["observed_native", "pending_effect", "cycle"] {
        assert!(snapshot["focus"][key].is_null());
    }
    assert_eq!(host.call(result(&pending, true))["ok"], false);
    assert_eq!(snapshot, host.snapshot());
}
