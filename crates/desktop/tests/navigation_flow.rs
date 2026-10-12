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
fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn setup() -> Host {
    let mut h = Host::new();
    for (id, x) in [("one", 100.0), ("two", 1200.0)] {
        h.ok(json!({"op":"register_output","stable_id":id,"screen_bounds":rect(x,50.0,1000.0,800.0)}));
    }
    for (id, x, y, w, height) in [
        (1, 2000.0, 1000.0, 200.0, 100.0),
        (2, 10.0, 20.0, 1200.0, 500.0),
    ] {
        h.ok(json!({"op":"attach","identity":{"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":id},"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(x,y,w,height),"world_rect":rect(x,y,w,height)}));
    }
    h
}
fn nav(h: &mut Host, window: u64, output: u64, policy: &str) -> Value {
    h.ok(json!({"op":"navigate_window","window":window,"output":output,"zoom_policy":policy}))
}
fn tick(h: &mut Host, ns: u64) -> Value {
    h.ok(json!({"op":"tick_navigation","timestamp_ns":ns}))
}
fn idle_host() -> Host {
    let mut h = setup();
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    h
}
#[test]
fn clock_only_ticks_change_only_the_snapshot_clock_and_keep_rejections_transactional() {
    let mut h = idle_host();
    let before = h.snapshot();
    for now in [0, 80_000_000, 80_000_000, 20_000_000_000] {
        assert_eq!(tick(&mut h, now)["clock_only"], true);
        let mut expected = before.clone();
        expected["navigation"]["clock_ns"] = json!(now);
        assert_eq!(h.snapshot(), expected);
    }
    let before = h.snapshot();
    assert_eq!(
        h.call(json!({"op":"tick_navigation","timestamp_ns":1}))["ok"],
        false
    );
    assert_eq!(h.snapshot(), before);
}
#[test]
fn clock_only_excludes_first_flight_pending_pan_cursor_pan_and_pointer_grabs() {
    let mut flight = idle_host();
    nav(&mut flight, 1, 1, "keep");
    let first = tick(&mut flight, 0);
    assert_eq!(first["changed_outputs"], json!([]));
    assert_eq!(first["clock_only"], false);
    for command in [
        json!({"op":"pan","output":1,"screen_delta":{"x":10,"y":0},"time_ms":100,"source":"finger"}),
        json!({"op":"action","output":1,"action":"toggle-cursor-pan"}),
        json!({"op":"begin_drag","window":1,"output":1}),
        json!({"op":"begin_resize","window":1,"output":1,"edges":"right"}),
    ] {
        let mut h = idle_host();
        h.ok(command.clone());
        assert_eq!(tick(&mut h, 1)["clock_only"], false, "{command}");
    }
}
#[test]
fn clock_only_excludes_native_resize_and_fullscreen_settlement() {
    let mut resize = idle_host();
    resize.ok(json!({"op":"begin_native_resize","window":1,"output":1,"edges":"right","start_screen":{"x":50,"y":50}}));
    assert_eq!(tick(&mut resize, 0)["clock_only"], false);

    let mut fullscreen = idle_host();
    fullscreen.ok(json!({"op":"focus","window":1}));
    fullscreen.ok(json!({"op":"action","output":1,"action":"toggle-fullscreen"}));
    assert_eq!(tick(&mut fullscreen, 0)["clock_only"], false);
}
#[test]
fn clock_only_excludes_the_tick_that_expires_a_close_mark() {
    let mut h = idle_host();
    h.ok(json!({"op":"focus","window":1}));
    tick(&mut h, 0);
    h.ok(json!({"op":"action","output":1,"action":"close-window"}));
    assert_eq!(h.snapshot()["lifecycle"]["marks"]["1"], "close");
    assert_eq!(tick(&mut h, 9_000_000_000)["clock_only"], false);
    assert_eq!(tick(&mut h, 10_000_000_000)["clock_only"], false);
    assert_eq!(h.snapshot()["lifecycle"]["marks"], json!({}));
    assert_eq!(tick(&mut h, 10_080_000_000)["clock_only"], true);
}
#[test]
fn clock_only_excludes_pending_relaunch_expiry() {
    let mut h = idle_host();
    h.ok(json!({"op":"focus","window":1}));
    tick(&mut h, 0);
    h.ok(json!({"op":"action","output":1,"action":"suspend-window"}));
    let snapshot = h.snapshot();
    let identity = &snapshot["windows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|window| window["window"] == 1)
        .unwrap()["source"]["identity"];
    h.ok(json!({"op":"window_closed","window":1,"identity":identity,"output":1}));
    for output in [1, 2] {
        h.ok(json!({"op":"cancel_navigation","output":output}));
    }
    h.ok(json!({"op":"ipc","output":1,"request":{"Relaunch":1}}));
    assert_eq!(h.snapshot()["lifecycle"]["relaunching"], json!([1]));
    assert_eq!(tick(&mut h, 29_000_000_000)["clock_only"], false);
    assert_eq!(tick(&mut h, 30_000_000_000)["clock_only"], false);
    assert_eq!(h.snapshot()["lifecycle"]["relaunching"], json!([]));
    assert_eq!(tick(&mut h, 30_080_000_000)["clock_only"], true);
}
fn pose(h: &mut Host, output: usize) -> Value {
    h.snapshot()["outputs"][output - 1].clone()
}
fn close(actual: f64, expected: f64) {
    assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
}
fn trace_pose(h: &mut Host) -> Value {
    let mut current = pose(h, 1);
    current["animating"] = json!(h.snapshot()["navigation"]["flights"].get("1").is_some());
    current
}
fn compare_pose(actual: &Value, expected: &Value) {
    if let Some(animating) = actual.get("animating") {
        assert_eq!(animating, &expected["animating"]);
    }
    close(
        actual["camera"]["x"].as_f64().unwrap(),
        expected["x"].as_f64().unwrap(),
    );
    close(
        actual["camera"]["y"].as_f64().unwrap(),
        expected["y"].as_f64().unwrap(),
    );
    close(
        actual["zoom"].as_f64().unwrap(),
        expected["zoom"].as_f64().unwrap(),
    );
}
fn oracle(trace: &str) -> Vec<Value> {
    use std::{
        io::Write,
        process::{Command, Stdio},
    };
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let upstream = root.join("tests/upstream");
    let verified = Command::new("shasum")
        .args(["-a", "256", "-c", "SHA256SUMS"])
        .current_dir(&upstream)
        .output()
        .unwrap();
    assert!(
        verified.status.success(),
        "{}",
        String::from_utf8_lossy(&verified.stdout)
    );
    let dir = std::env::temp_dir().join(format!(
        "navigation-oracle-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let mut shim = std::fs::read_to_string(root.join("tests/support/navigation_oracle.rs"))
        .unwrap()
        .replace(
            "GEOMETRY_PATH",
            root.join("../canvas/tests/support/canvas_shim.rs")
                .to_str()
                .unwrap(),
        );
    let entries: Vec<Value> =
        serde_json::from_slice(&std::fs::read(upstream.join("METHODS.json")).unwrap()).unwrap();
    let mut methods = String::new();
    for entry in entries {
        let source =
            std::fs::read_to_string(upstream.join(entry["path"].as_str().unwrap())).unwrap();
        let start = entry["start"].as_u64().unwrap() as usize;
        let end = entry["end"].as_u64().unwrap() as usize;
        let body = source
            .split_inclusive('\n')
            .skip(start - 1)
            .take(end - start + 1)
            .collect::<String>();
        let part = dir.join("method.rs");
        std::fs::write(&part, &body).unwrap();
        let hash = Command::new("shasum")
            .args(["-a", "256"])
            .arg(&part)
            .output()
            .unwrap();
        assert!(hash.status.success());
        assert_eq!(
            String::from_utf8(hash.stdout)
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap(),
            entry["sha256"].as_str().unwrap()
        );
        let marker = match entry["name"].as_str().unwrap() {
            "frame_size" => Some("/*FRAME_SIZE*/"),
            "outer_frame_inset" => Some("/*OUTER_FRAME_INSET*/"),
            "pull" => Some("/*PULL*/"),
            "visual_frame_center" => Some("/*VISUAL_FRAME_CENTER*/"),
            _ => None,
        };
        if let Some(marker) = marker {
            shim = shim.replace(marker, &body);
        } else {
            methods.push_str(&body);
        }
    }
    shim = shim.replace("/*METHODS*/", &methods);
    let source = dir.join("oracle.rs");
    std::fs::write(&source, shim).unwrap();
    let binary = dir.join("oracle");
    assert!(
        Command::new("rustc")
            .args(["--edition=2024", "--crate-name", "navigation_oracle"])
            .arg(source)
            .arg("-o")
            .arg(&binary)
            .status()
            .unwrap()
            .success()
    );
    let mut child = Command::new(binary)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(trace.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    std::fs::remove_dir_all(dir).unwrap();
    String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect()
}
#[test]
fn source_parity_keep_reset_placements_timing_and_retarget() {
    let placements = [
        "center",
        "top",
        "bottom",
        "left",
        "right",
        "top_left",
        "top_right",
        "bottom_left",
        "bottom_right",
    ];
    let mut trace = String::new();
    let mut actual = Vec::new();
    for (index, placement) in placements.iter().enumerate() {
        for window in [1, 2] {
            for policy in ["keep", "reset"] {
                let mut h = setup();
                h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":100,"y":50}}));
                trace.push_str("pose 0 0 0.5\n");
                actual.push(trace_pose(&mut h));
                h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(23.0,47.0,920.0,700.0),"focus_placement":placement,"camera_speed":0.3,"outer_gap":17.0}));
                trace.push_str(&format!("context 23 47 920 700 {index} 0.3 17\n"));
                actual.push(trace_pose(&mut h));
                tick(&mut h, 100);
                nav(&mut h, window, 1, policy);
                let frame = if window == 1 {
                    "2000 1000 200 100"
                } else {
                    "10 20 1200 500"
                };
                trace.push_str(&format!(
                    "navigate {frame} {}\n",
                    u8::from(policy == "reset")
                ));
                actual.push(trace_pose(&mut h));
                let mut clock = 100;
                for dt in [0, 8_333_333, 16_666_667, 90_000_000, 0, 16_666_667] {
                    clock += dt;
                    tick(&mut h, clock);
                    trace.push_str(&format!("tick {}\n", dt.min(33_000_000)));
                    actual.push(trace_pose(&mut h));
                }
                nav(&mut h, 1, 1, "keep");
                trace.push_str("navigate 2000 1000 200 100 0\n");
                actual.push(trace_pose(&mut h));
                for _ in 0..60 {
                    clock += 16_666_667;
                    tick(&mut h, clock);
                    trace.push_str("tick 16666667\n");
                    actual.push(trace_pose(&mut h));
                }
                assert!(
                    h.snapshot()["navigation"]["flights"]
                        .as_object()
                        .unwrap()
                        .is_empty()
                );
            }
        }
    }
    let expected = oracle(&trace);
    assert_eq!(expected.len(), actual.len());
    for (i, (actual, expected)) in actual.iter().zip(&expected).enumerate() {
        compare_pose(actual, expected);
        assert!(expected["zoom"].is_number(), "row {i}");
    }
}
#[test]
fn transactional_cancellation_focus_outputs_hits_and_persistence() {
    let mut h = setup();
    let first = nav(&mut h, 1, 1, "keep");
    nav(&mut h, 2, 2, "keep");
    let initial = pose(&mut h, 1);
    assert_eq!(tick(&mut h, 1)["changed_outputs"], json!([]));
    assert_eq!(initial, pose(&mut h, 1));
    assert_eq!(tick(&mut h, 16_666_668)["changed_outputs"], json!([1, 2]));
    let before = h.snapshot();
    for command in [
        json!({"op":"tick_navigation","timestamp_ns":0}),
        json!({"op":"navigate_window","window":999,"output":1,"zoom_policy":"keep"}),
        json!({"op":"cycle_navigate","output":99,"backward":false,"held":true}),
        json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,0.0,1000.0,800.0),"focus_placement":"left","camera_speed":0,"outer_gap":0}),
        json!({"op":"pan","output":99,"screen_delta":{"x":1,"y":1}}),
    ] {
        assert_eq!(h.call(command)["ok"], false);
        assert_eq!(before, h.snapshot());
    }
    let second = nav(&mut h, 1, 1, "reset");
    let effect = &first["effect"];
    let focus_result = |e: &Value, success| json!({"op":"focus_result","effect_id":e["effect_id"],"window":e["window"],"identity":e["identity"],"generation":e["generation"],"success":success});
    let before = h.snapshot();
    assert_eq!(h.call(focus_result(effect, true))["ok"], false);
    assert_eq!(before, h.snapshot());
    h.ok(focus_result(&second["effect"], false));
    assert_eq!(before["navigation"], h.snapshot()["navigation"]);
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":10,"y":0}}));
    assert!(h.snapshot()["navigation"]["flights"].get("1").is_none());
    assert!(h.snapshot()["navigation"]["flights"].get("2").is_some());
    h.ok(json!({"op":"zoom","output":2,"zoom":0.8,"anchor":{"x":1200,"y":50}}));
    assert_eq!(tick(&mut h, 20_000_000)["needs_frames"], false);
    for op in ["begin_drag", "begin_resize"] {
        nav(&mut h, 1, 1, "keep");
        nav(&mut h, 2, 2, "keep");
        let mut command = json!({"op":op,"window":1,"output":1});
        if op == "begin_resize" {
            command["edges"] = json!("right");
        }
        h.ok(command);
        assert!(
            h.snapshot()["navigation"]["flights"]
                .as_object()
                .unwrap()
                .is_empty()
        );
        h.ok(json!({"op":"end_gesture"}));
    }
    let flight = nav(&mut h, 1, 1, "reset");
    tick(&mut h, 40_000_000);
    let saved_pose = pose(&mut h, 1);
    assert_ne!(saved_pose["camera"], flight["navigation"]["target_camera"]);
    let path = std::env::temp_dir().join(format!("navigation-save-{}.json", std::process::id()));
    h.ok(json!({"op":"save","path":path}));
    let saved = std::fs::read_to_string(&path).unwrap();
    for excluded in [
        "camera_target",
        "zoom_target",
        "clock_ns",
        "navigation_contexts",
        "next_navigation",
    ] {
        assert!(!saved.contains(excluded));
    }
    h.ok(json!({"op":"load","path":path}));
    std::fs::remove_file(path).unwrap();
    h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(100.0,50.0,1000.0,800.0)}));
    assert_eq!(pose(&mut h, 1), saved_pose);
    assert_eq!(tick(&mut h, 0)["needs_frames"], false);
    // Fresh bindings are required after load, and generation/effect counters remain protected.
    h.ok(json!({"op":"attach","logical_id":1,"identity":{"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":1},"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(2000.0,1000.0,200.0,100.0)}));
    let new = nav(&mut h, 1, 1, "reset");
    assert!(new["navigation"]["generation"].as_u64() > flight["navigation"]["generation"].as_u64());
    for i in 1..100 {
        tick(&mut h, i * 16_666_667);
    }
    let snapshot = h.snapshot();
    let placement = snapshot["placements"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["window"] == 1 && p["output"] == 1)
        .unwrap();
    let screen = &placement["screen_rect"];
    let x = screen["origin"]["x"].as_f64().unwrap() + 10.0;
    let y = screen["origin"]["y"].as_f64().unwrap() + 10.0;
    assert_eq!(
        h.ok(json!({"op":"hit","output":1,"screen":{"x":x,"y":y}}))["hit"]["window"],
        1
    );
    nav(&mut h, 2, 1, "keep");
    h.ok(json!({"op":"remove_output","output":1}));
    h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(100.0,50.0,1000.0,800.0)}));
    assert_eq!(tick(&mut h, 2_000_000_000)["needs_frames"], false);
}
#[test]
fn strict_arrival_boundaries_fractional_frames_and_negative_inset_oracle() {
    let mut trace = String::new();
    let mut actual = Vec::new();
    // Place a fractional native frame so the initial anchor displacement is
    // immediately below, exactly at, and immediately above the strict 0.5 threshold.
    for delta in [0.499999, 0.5, 0.500001] {
        let mut h = setup();
        h.ok(json!({"op":"attach","identity":{"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":3},"bundle_id":"test","title":"fractional","buffer":{"width":200,"height":100},"source_rect":rect(400.0+delta,350.0,200.0,100.0),"world_rect":rect(400.0+delta,350.0,200.0,100.0)}));
        trace.push_str("pose 0 0 1\n");
        actual.push(trace_pose(&mut h));
        trace.push_str(&format!("anchor {} 400 500 400 1\n", 500.0 + delta));
        nav(&mut h, 3, 1, "keep");
        actual.push(trace_pose(&mut h));
        for ns in [0, 0, 16_666_667, 33_333_334] {
            let previous = h.snapshot()["navigation"]["clock_ns"]
                .as_u64()
                .unwrap_or(ns);
            trace.push_str(&format!("tick {}\n", ns - previous));
            tick(&mut h, ns);
            actual.push(trace_pose(&mut h));
        }
    }
    for zoom in [0.998999, 0.999, 0.999001] {
        let mut h = setup();
        h.ok(json!({"op":"zoom","output":1,"zoom":zoom,"anchor":{"x":100,"y":50}}));
        trace.push_str(&format!("pose 0 0 {zoom}\n"));
        actual.push(trace_pose(&mut h));
        nav(&mut h, 1, 1, "reset");
        trace.push_str("navigate 2000 1000 200 100 1\n");
        actual.push(trace_pose(&mut h));
        tick(&mut h, 0);
        trace.push_str("tick 0\n");
        actual.push(trace_pose(&mut h));
    }
    for (actual, expected) in actual.iter().zip(oracle(&trace)) {
        compare_pose(actual, &expected);
    }
    let expected = oracle("context 23 47 920 700 5 0.3 0\nalign 200 100 4 1\nalign 920 100 4 1\n");
    assert_eq!(expected[1], json!({"x":123,"y":97}));
    assert_eq!(expected[2], json!({"x":483,"y":97}));
}
#[test]
fn cycle_navigation_context_and_explicit_cancel() {
    let mut h = setup();
    for window in [1, 2] {
        let effect = h.ok(json!({"op":"focus","window":window}))["effect"].clone();
        h.ok(json!({"op":"focus_result","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"],"success":true}));
    }
    let result = h.ok(json!({"op":"cycle_navigate","output":1,"backward":false,"held":true}));
    assert_eq!(result["effect"]["window"], 1);
    assert_eq!(result["navigation"]["target_zoom"], 1.0);
    let before = h.snapshot();
    assert_eq!(before["focus"]["history"], json!([2, 1]));
    h.ok(json!({"op":"cancel_navigation","output":1}));
    assert_eq!(h.snapshot()["focus"], before["focus"]);
    nav(&mut h, 1, 1, "keep");
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(10.0,30.0,950.0,740.0),"focus_placement":"bottom_right","camera_speed":1.0,"outer_gap":0.0}));
    assert!(
        h.snapshot()["navigation"]["flights"]
            .as_object()
            .unwrap()
            .is_empty()
    );
    let result = nav(&mut h, 1, 1, "keep");
    tick(&mut h, 0);
    tick(&mut h, 16_666_667);
    assert_eq!(
        pose(&mut h, 1)["camera"],
        result["navigation"]["target_camera"]
    );
    assert_eq!(tick(&mut h, 16_666_667)["needs_frames"], false);
}
#[test]
fn shared_clock_and_hits_track_intermediate_camera() {
    let mut h = setup();
    tick(&mut h, 0);
    let destination = nav(&mut h, 1, 1, "keep");
    nav(&mut h, 1, 2, "keep");
    for i in 1..=5 {
        assert_eq!(
            tick(&mut h, i * 16_666_667)["changed_outputs"],
            json!([1, 2])
        );
    }
    let first = pose(&mut h, 1);
    let second = pose(&mut h, 2);
    assert_eq!(first["camera"], second["camera"]);
    assert_ne!(first["camera"], destination["navigation"]["target_camera"]);
    let snapshot = h.snapshot();
    let placement = snapshot["placements"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["window"] == 1 && p["output"] == 1)
        .unwrap();
    let screen = &placement["screen_rect"];
    let x = screen["origin"]["x"].as_f64().unwrap() + 10.0;
    let y = screen["origin"]["y"].as_f64().unwrap() + 10.0;
    let hit = h.ok(json!({"op":"hit","output":1,"screen":{"x":x,"y":y}}));
    assert_eq!(hit["hit"]["window"], 1);
    close(hit["hit"]["local"]["x"].as_f64().unwrap(), 10.0);
    let before = h.snapshot();
    for speed in [-1.0, 1.0001] {
        assert_eq!(h.call(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,0.0,1000.0,800.0),"focus_placement":"center","camera_speed":speed,"outer_gap":0.0}))["ok"],false);
        assert_eq!(h.snapshot(), before);
    }
}
