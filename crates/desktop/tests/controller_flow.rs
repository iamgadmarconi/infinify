// SPDX-License-Identifier: GPL-3.0-or-later
//! Controller integration scenarios cross the exported C ABI and JSON decoder.
//! They provide no native rendering, capture, or input-delivery evidence.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;

#[path = "support/host.rs"]
mod host;
use host::Host;

impl Host {}
fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn identity() -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":50,"wid":456,"owner":789})
}
fn attach(world: Value) -> Value {
    json!({"op":"attach","identity":identity(),"bundle_id":"org.example.fixture","title":"Observed title","buffer":{"width":400,"height":200},"source_rect":rect(100.0,200.0,200.0,100.0),"world_rect":world})
}
fn output(host: &mut Host, name: &str, bounds: Value) -> Value {
    host.ok(json!({"op":"register_output","stable_id":name,"screen_bounds":bounds}))["output"]
        .clone()
}
fn hit(host: &mut Host, output: &Value, x: f64, y: f64) -> Value {
    host.ok(json!({"op":"hit","output":output,"screen":{"x":x,"y":y}}))["hit"].clone()
}

#[test]
fn two_outputs_clipping_inverse_input_and_world_gestures() {
    let mut host = Host::new();
    let a = output(&mut host, "display-a", rect(0.0, 0.0, 100.0, 100.0));
    let b = output(&mut host, "display-b", rect(100.0, 0.0, 100.0, 100.0));
    let window = host.ok(attach(rect(50.0, 10.0, 200.0, 100.0)))["window"].clone();
    let snapshot = host.snapshot();
    let placements = snapshot["placements"].as_array().unwrap();
    assert_eq!(placements.len(), 2);
    assert_eq!(placements[0]["window"], placements[1]["window"]);
    assert_eq!(placements[0]["screen_rect"], rect(50.0, 10.0, 200.0, 100.0));
    assert_eq!(
        placements[1]["screen_rect"],
        rect(150.0, 10.0, 200.0, 100.0)
    );
    assert_eq!(placements[0]["buffer_crop"], rect(0.0, 0.0, 100.0, 180.0));
    assert_eq!(
        hit(&mut host, &a, 75.0, 25.0)["local"],
        json!({"x":25.0,"y":15.0})
    );
    assert_eq!(
        hit(&mut host, &b, 175.0, 25.0)["local"],
        json!({"x":25.0,"y":15.0})
    );
    host.ok(json!({"op":"zoom","output":a,"zoom":0.5,"anchor":{"x":75.0,"y":25.0}}));
    assert_eq!(
        hit(&mut host, &a, 75.0, 25.0)["local"],
        json!({"x":25.0,"y":15.0})
    );
    assert_eq!(host.snapshot()["outputs"][1]["zoom"], 1.0);
    host.ok(json!({"op":"observe","window":window,"identity":identity(),"source_rect":rect(900.0,700.0,400.0,200.0),"buffer":{"width":800,"height":400}}));
    assert_eq!(
        host.snapshot()["windows"][0]["world_rect"],
        rect(50.0, 10.0, 200.0, 100.0)
    );
    let h = hit(&mut host, &a, 75.0, 25.0);
    assert_eq!(h["local"], json!({"x":50.0,"y":30.0}));
    assert_eq!(h["native_screen"], json!({"x":950.0,"y":730.0}));
    assert_eq!(
        host.snapshot()["windows"][0]["source"]["original_rect"],
        rect(100.0, 200.0, 200.0, 100.0)
    );
    let mut stale = identity();
    stale["birth_usec"] = json!(51);
    assert_eq!(
        host.call(json!({"op":"input","output":a,"screen":{"x":75.0,"y":25.0},"identity":stale}))["ok"],
        false
    );
    host.ok(json!({"op":"input","output":a,"screen":{"x":75.0,"y":25.0},"identity":identity()}));
    host.ok(json!({"op":"begin_drag","window":window,"output":a}));
    host.ok(json!({"op":"gesture_to","screen_delta":{"x":20.0,"y":10.0}}));
    host.ok(json!({"op":"gesture_to","screen_delta":{"x":20.0,"y":10.0}}));
    host.ok(json!({"op":"end_gesture"}));
    assert_eq!(
        host.snapshot()["windows"][0]["world_rect"],
        rect(90.0, 30.0, 200.0, 100.0)
    );
    host.ok(json!({"op":"begin_resize","window":window,"output":a,"edges":"bottom_right"}));
    host.ok(json!({"op":"gesture_to","screen_delta":{"x":10.0,"y":5.0}}));
    let before = host.snapshot();
    assert_eq!(
        host.call(json!({"op":"gesture_to","screen_delta":{"x":1e12,"y":0.0}}))["ok"],
        false
    );
    assert_eq!(host.snapshot(), before);
    host.ok(json!({"op":"gesture_to","screen_delta":{"x":10.0,"y":5.0}}));
    host.ok(json!({"op":"end_gesture"}));
    assert_eq!(
        host.snapshot()["windows"][0]["world_rect"],
        rect(90.0, 30.0, 220.0, 110.0)
    );
    // A separate source covers the original on the second output until focus raises it.
    let mut other = attach(rect(90.0, 30.0, 220.0, 110.0));
    other["identity"]["wid"] = json!(457);
    let second = host.ok(other)["window"].clone();
    assert_eq!(hit(&mut host, &b, 195.0, 35.0)["window"], second);
    host.ok(json!({"op":"focus","window":window}));
    assert_eq!(hit(&mut host, &b, 195.0, 35.0)["window"], window);
}

#[test]
fn save_reload_detaches_and_explicit_rebind_retains_world_and_cameras() {
    let mut host = Host::new();
    let a = output(&mut host, "persisted-display", rect(0.0, 0.0, 100.0, 100.0));
    let window = host.ok(attach(rect(0.0, 0.0, 200.0, 100.0)))["window"].clone();
    host.ok(json!({"op":"zoom","output":a,"zoom":0.5,"anchor":{"x":0.0,"y":0.0}}));
    host.ok(json!({"op":"pan","output":a,"screen_delta":{"x":5.0,"y":10.0}}));
    host.ok(json!({"op":"remove_output","output":a}));
    let path = std::env::temp_dir().join(format!("driftwm-controller-{}.json", std::process::id()));
    host.ok(json!({"op":"save","path":path}));
    let saved = std::fs::read_to_string(&path).unwrap();
    for forbidden in [
        "\"pid\"",
        "\"wid\"",
        "\"owner\"",
        "\"birth_sec\"",
        "\"identity\"",
        "\"source\"",
    ] {
        assert!(!saved.contains(forbidden), "{forbidden}");
    }
    let mut restored = Host::new();
    restored.ok(json!({"op":"load","path":path}));
    assert!(
        restored.snapshot()["outputs"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(restored.snapshot()["windows"][0]["source"], Value::Null);
    let again = output(
        &mut restored,
        "persisted-display",
        rect(200.0, 0.0, 100.0, 100.0),
    );
    assert_eq!(again, a);
    assert_eq!(
        restored.snapshot()["outputs"][0]["camera"],
        json!({"x":10.0,"y":20.0})
    );
    assert_eq!(restored.snapshot()["outputs"][0]["zoom"], 0.5);
    assert_eq!(
        restored.call(
            json!({"op":"input","output":a,"screen":{"x":210.0,"y":10.0},"identity":identity()})
        )["ok"],
        false
    );
    // Matching title/application without an explicit logical ID never rebinds.
    let second = restored.ok(attach(rect(900.0, 900.0, 10.0, 10.0)))["window"].clone();
    assert_ne!(second, window);
    assert_eq!(restored.snapshot()["windows"][0]["source"], Value::Null);
    restored.ok(json!({"op":"forget","window":second}));
    let mut rebind = attach(rect(900.0, 900.0, 10.0, 10.0));
    rebind.as_object_mut().unwrap().remove("world_rect");
    rebind["logical_id"] = window.clone();
    rebind["identity"]["pid"] = json!(999);
    restored.ok(rebind.clone());
    assert_eq!(
        restored.snapshot()["windows"][0]["world_rect"],
        rect(0.0, 0.0, 200.0, 100.0)
    );
    let h = hit(&mut restored, &a, 210.0, 10.0);
    assert_eq!(h["identity"]["pid"], 999);
    restored.ok(json!({"op":"remove_source","window":window,"identity":rebind["identity"],"keep_placeholder":true}));
    assert_eq!(
        restored.call(json!({"op":"hit","output":a,"screen":{"x":210.0,"y":10.0}}))["ok"],
        false
    );
    // Corrupted load is rejected without changing the active controller.
    let before = restored.snapshot();
    let bad = saved.replace("\"version\": 1", "\"version\": 2");
    std::fs::write(&path, bad).unwrap();
    assert_eq!(restored.call(json!({"op":"load","path":path}))["ok"], false);
    assert_eq!(restored.snapshot(), before);
    std::fs::remove_file(path).unwrap();
    restored.ok(json!({"op":"forget","window":window}));
    assert!(
        restored.snapshot()["windows"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn strict_schema_numeric_failures_and_ffi_limits_are_atomic() {
    let mut host = Host::new();
    let a = output(&mut host, "display", rect(0.0, 0.0, 100.0, 100.0));
    let before = host.snapshot();
    for bytes in [
        br#"{"version":1,"extra":0,"command":{"op":"snapshot"}}"#.as_slice(),
        br#"{"version":1,"command":{"op":"snapshot","extra":0}}"#,
        br#"{"version":1,"command":{"op":"pan","output":1,"screen_delta":{"x":1e999,"y":0}}}"#,
        br#"{"version":1,"command":{"op":"pan","output":1,"screen_delta":{"x":0,"y":0,"z":0}}}"#,
        br#"{"version":1,"version":1,"command":{"op":"snapshot"}}"#,
        br#"{"version":1,"command":{"op":"zoom","output":1,"zoom":NaN,"anchor":{"x":0,"y":0}}}"#,
    ] {
        assert_eq!(
            host.raw(bytes)["ok"],
            false,
            "{}",
            String::from_utf8_lossy(bytes)
        );
        assert_eq!(host.snapshot(), before);
    }
    for zoom in [-1.0, 0.0, 0.0009, 1.1] {
        assert_eq!(
            host.call(json!({"op":"zoom","output":a,"zoom":zoom,"anchor":{"x":0.0,"y":0.0}}))["ok"],
            false
        );
        assert_eq!(host.snapshot(), before);
    }
    host.ok(json!({"op":"zoom","output":a,"zoom":0.001,"anchor":{"x":0.0,"y":0.0}}));
    host.ok(json!({"op":"zoom","output":a,"zoom":1.0,"anchor":{"x":0.0,"y":0.0}}));
    assert_eq!(host.snapshot(), before);
    let huge = vec![b' '; MAX_REQUEST_BYTES + 1];
    assert_eq!(host.raw(&huge)["ok"], false);
    unsafe {
        let response = driftwm_desktop_request(host.0, std::ptr::null(), 0);
        let value: Value = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
        assert_eq!(value["ok"], false);
        driftwm_desktop_response_free(response);
        driftwm_desktop_response_free(std::ptr::null_mut());
        driftwm_desktop_destroy(std::ptr::null_mut());
    }
}

#[test]
fn snap_defaults_use_current_zoom_while_displacement_keeps_start_zoom() {
    // config/mod.rs defaults: gap=12 world, distance=24 screen, break=32 screen.
    // snap.rs measures raw edge distance, then applies the gap. The current
    // output zoom changes the latch distances (cluster_snapshot.rs and resize_grab.rs).
    for op in ["begin_drag", "begin_resize"] {
        let mut host = Host::new();
        let display = output(&mut host, "snap-display", rect(0.0, 0.0, 800.0, 600.0));
        let window = host.ok(attach(rect(0.0, 0.0, 100.0, 100.0)))["window"].clone();
        let mut neighbor = attach(rect(150.0, 0.0, 100.0, 100.0));
        neighbor["identity"]["wid"] = json!(457);
        host.ok(neighbor);
        host.ok(json!({"op":"zoom","output":display,"zoom":0.5,"anchor":{"x":0.0,"y":0.0}}));
        let mut begin = json!({"op":op,"window":window,"output":display});
        if op == "begin_resize" {
            begin["edges"] = json!("right");
        }
        // The press raises and focuses the window ahead of its grab, as
        // upstream's does: it is on top of its neighbour from here on, and
        // the reply carries the focus request a click's carries.
        let begun = host.ok(begin);
        assert_eq!(begun["effect"]["op"], "focus_native_window", "{begun}");
        assert_eq!(begun["effect"]["window"], window, "{begun}");
        let stacked = host.snapshot();
        assert_eq!(stacked["focus"]["intent"], window);
        assert_eq!(stacked["focus"]["pending_effect"], begun["effect"]);
        assert_eq!(stacked["windows"][1]["window"], window);
        for (zoom, screen_delta, expected_delta) in [
            (1.0, 2.0, 4.0),
            (0.5, 2.0, 38.0),
            (1.0, 34.5, 38.0),
            (1.0, 35.0, 70.0),
        ] {
            host.ok(json!({"op":"zoom","output":display,"zoom":zoom,"anchor":{"x":0.0,"y":0.0}}));
            host.ok(json!({"op":"gesture_to","screen_delta":{"x":screen_delta,"y":0.0}}));
            let expected = if op == "begin_drag" {
                rect(expected_delta, 0.0, 100.0, 100.0)
            } else {
                rect(0.0, 0.0, 100.0 + expected_delta, 100.0)
            };
            assert_eq!(
                host.snapshot()["windows"][1]["world_rect"],
                expected,
                "{op} zoom={zoom} screen_delta={screen_delta}"
            );
            assert_eq!(
                host.snapshot()["windows"][0]["world_rect"],
                rect(150.0, 0.0, 100.0, 100.0)
            );
        }
    }
}
