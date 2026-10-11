// SPDX-License-Identifier: GPL-3.0-or-later
//! Exported C ABI contract only. Synthetic observations/capture acknowledgements
//! do not prove native mutation, pixels, or usable compositing.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::{
    ffi::CStr,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
    sync::OnceLock,
};
struct Host(*mut Controller);
impl Host {
    fn new() -> Self {
        Self(driftwm_desktop_create())
    }
    fn call(&mut self, command: Value) -> Value {
        let bytes = serde_json::to_vec(&json!({"version":1,"command":command})).unwrap();
        // SAFETY: owned live handle; response consumed once, then freed.
        unsafe {
            let ptr = driftwm_desktop_request(self.0, bytes.as_ptr(), bytes.len());
            let out = serde_json::from_slice(CStr::from_ptr(ptr).to_bytes()).unwrap();
            driftwm_desktop_response_free(ptr);
            out
        }
    }
    fn ok(&mut self, c: Value) -> Value {
        let r = self.call(c);
        assert_eq!(r["ok"], true, "{r}");
        r["data"].clone()
    }
    fn snap(&mut self) -> Value {
        self.ok(json!({"op":"snapshot"}))
    }
    fn rejects(&mut self, c: Value) {
        let before = self.snap();
        assert_eq!(self.call(c)["ok"], false);
        assert_eq!(self.snap(), before);
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        unsafe { driftwm_desktop_destroy(self.0) }
    }
}
fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn identity() -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":5,"wid":1})
}
fn attach(h: &mut Host, logical: Option<u64>, id: Value) -> Value {
    h.ok(json!({"op":"attach","identity":id,"bundle_id":"test","title":"window","buffer":{"width":400,"height":300},"source_rect":rect(10.,20.,200.,150.),"world_rect":if logical.is_none(){rect(100.,100.,200.,150.)}else{Value::Null},"logical_id":logical}))
}
fn setup() -> Host {
    let mut h = Host::new();
    h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(0.,0.,1000.,800.)}));
    attach(&mut h, None, identity());
    h
}
fn begin(h: &mut Host, edges: &str) -> Value {
    h.ok(json!({"op":"begin_native_resize","window":1,"output":1,"edges":edges,"start_screen":{"x":50.,"y":50.}}))["effect"].clone()
}
fn reply(e: &Value, outcome: &str, attempted: bool, observed: bool, w: f64, height: f64) -> Value {
    json!({"op":"native_resize_result","transaction":e["transaction"],"effect_id":e["effect_id"],"identity":e["identity"],"generation":e["generation"],"result":{"outcome":outcome,"ax_error":0,"mutation_attempted":attempted,"observed":observed,"requested":if e["requested"].is_null(){json!({"width":0.,"height":0.})}else{e["requested"].clone()},"actual_ax":rect(700.,500.,w,height),"actual_cg":rect(700.,500.,w,height)}})
}
fn ready(h: &mut Host, edges: &str) -> Value {
    let e = begin(h, edges);
    h.ok(reply(&e, "observed", false, true, 200., 150.));
    e
}
fn motion(h: &mut Host, t: &Value, x: f64, y: f64) -> Value {
    h.ok(json!({"op":"native_resize_to","transaction":t["transaction"],"screen":{"x":50.+x,"y":50.+y}}))["effect"].clone()
}
fn finish(h: &mut Host, t: &Value, cancel: bool) -> Value {
    h.ok(json!({"op":if cancel{"cancel_native_resize"}else{"end_native_resize"},"transaction":t["transaction"]}))["effect"].clone()
}
fn world(h: &mut Host) -> Value {
    h.snap()["windows"][0]["world_rect"].clone()
}
fn oracle(values: &str) -> Vec<f64> {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    let exe = EXE.get_or_init(|| {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let upstream = root.join("tests/resize_upstream");
        let checked = Command::new("shasum")
            .args(["-a", "256", "-c", "SHA256SUMS"])
            .current_dir(&upstream)
            .output()
            .unwrap();
        assert!(
            checked.status.success(),
            "{}",
            String::from_utf8_lossy(&checked.stdout)
        );
        let dir = std::env::temp_dir().join(format!("resize-oracle-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut shim = std::fs::read_to_string(root.join("tests/support/resize_oracle.rs"))
            .unwrap()
            .replace(
                "GEOMETRY_PATH",
                root.join("../canvas/tests/support/canvas_shim.rs")
                    .to_str()
                    .unwrap(),
            );
        let entries: Vec<Value> =
            serde_json::from_slice(&std::fs::read(upstream.join("BLOCKS.json")).unwrap()).unwrap();
        for e in entries {
            let source =
                std::fs::read_to_string(upstream.join(e["path"].as_str().unwrap())).unwrap();
            let body = &source[e["start_byte"].as_u64().unwrap() as usize
                ..e["end_byte"].as_u64().unwrap() as usize];
            let path = dir.join("block.rs");
            std::fs::write(&path, body).unwrap();
            let hash = Command::new("shasum")
                .args(["-a", "256"])
                .arg(path)
                .output()
                .unwrap();
            assert_eq!(
                String::from_utf8(hash.stdout)
                    .unwrap()
                    .split_whitespace()
                    .next()
                    .unwrap(),
                e["sha256"].as_str().unwrap()
            );
            shim = shim.replace(&format!("/*{}*/", e["name"].as_str().unwrap()), body);
        }
        let source = dir.join("oracle.rs");
        std::fs::write(&source, shim).unwrap();
        let exe = dir.join("oracle");
        let build = Command::new("rustc")
            .args(["--edition=2024", "-Awarnings"])
            .arg(source)
            .arg("-o")
            .arg(&exe)
            .output()
            .unwrap();
        assert!(
            build.status.success(),
            "{}",
            String::from_utf8_lossy(&build.stderr)
        );
        exe
    });
    let mut child = Command::new(exe)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(), "{values}").unwrap();
    let out = child.wait_with_output().unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout)
        .unwrap()
        .split_whitespace()
        .map(|s| s.parse().unwrap())
        .collect()
}
#[test]
fn eight_edges_match_original_request_and_incremental_settlement_blocks() {
    for (name, bits) in [
        ("left", 4),
        ("right", 8),
        ("top", 1),
        ("bottom", 2),
        ("top_left", 5),
        ("top_right", 9),
        ("bottom_left", 6),
        ("bottom_right", 10),
    ] {
        let mut h = setup();
        let initial = world(&mut h);
        let outputs = h.snap()["outputs"].clone();
        let t = ready(&mut h, name);
        let e = motion(&mut h, &t, 20., 30.);
        let expected = oracle(&format!("{bits} 20 30 1 200 150 200 150 175 135 150 170"));
        assert_eq!(
            e["requested"],
            json!({"width":expected[0],"height":expected[1]})
        );
        assert_eq!(world(&mut h), initial);
        finish(&mut h, &t, false);
        h.ok(json!({"op":"begin_drag","window":1,"output":1}));
        h.ok(json!({"op":"gesture_to","screen_delta":{"x":50.,"y":70.}}));
        h.ok(json!({"op":"end_gesture"}));
        let final_read = h.ok(reply(&e, "clamped", true, true, 175., 135.))["effect"].clone();
        assert_eq!(world(&mut h), rect(expected[2], expected[3], 175., 135.));
        h.ok(reply(&final_read, "observed", false, true, 175., 135.));
        assert_eq!(h.snap()["native_resize"]["phase"], "complete");
        assert_eq!(h.snap()["outputs"], outputs);
    }
}
#[test]
fn coalesces_latest_release_waits_and_focus_is_independent() {
    let mut h = setup();
    let t = ready(&mut h, "bottom_right");
    let e = motion(&mut h, &t, 10., 10.);
    for n in 20..100 {
        assert!(motion(&mut h, &t, n as f64, n as f64).is_null());
    }
    let focus = h.ok(json!({"op":"focus","window":1}))["effect"].clone();
    finish(&mut h, &t, false);
    let next = h.ok(reply(&e, "applied", true, true, 210., 160.))["effect"].clone();
    assert_eq!(next["requested"], json!({"width":299.,"height":249.}));
    assert_eq!(h.snap()["focus"]["pending_effect"], focus);
    let read = h.ok(reply(&next, "clamped", true, true, 250., 200.))["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source");
    h.ok(reply(&read, "observed", false, true, 250., 200.));
    assert_eq!(world(&mut h)["size"], json!({"width":250.,"height":200.}));
}
#[test]
fn cancel_and_output_removal_drain_already_sent_mutation() {
    for remove in [false, true] {
        let mut h = setup();
        let t = ready(&mut h, "top_left");
        let e = motion(&mut h, &t, 10., 10.);
        motion(&mut h, &t, 30., 30.);
        if remove {
            h.ok(json!({"op":"remove_output","output":1}));
        } else {
            finish(&mut h, &t, true);
        }
        let read = h.ok(reply(&e, "applied", true, true, 190., 140.))["effect"].clone();
        assert_eq!(read["op"], "observe_resize_source");
        h.ok(reply(&read, "observed", false, true, 190., 140.));
        assert_eq!(world(&mut h), rect(110., 110., 190., 140.));
        assert_eq!(h.snap()["native_resize"]["phase"], "failed");
    }
}
#[test]
fn capture_ack_gates_placements_and_input_and_legacy_observe_cannot_bypass() {
    let mut h = setup();
    let t = ready(&mut h, "right");
    let e = motion(&mut h, &t, 30., 0.);
    assert_eq!(h.snap()["placements"][0]["presentation_settled"], false);
    h.ok(reply(&e, "applied", true, true, 230., 150.));
    let read = finish(&mut h, &t, false);
    h.ok(reply(&read, "observed", false, true, 230., 150.));
    h.ok(json!({"op":"observe","window":1,"identity":identity(),"source_rect":rect(700.,500.,230.,150.),"buffer":{"width":400,"height":300}}));
    assert!(h.snap()["placements"][0]["buffer_crop"].is_null());
    let hit = json!({"op":"input","output":1,"screen":{"x":120.,"y":120.},"identity":identity()});
    h.rejects(hit.clone());
    let mut ack = json!({"op":"native_resize_capture_ready","window":1,"identity":identity(),"generation":t["generation"],"observation_revision":0,"buffer":{"width":460,"height":300}});
    h.rejects(ack.clone());
    ack["observation_revision"] = json!(1);
    h.ok(ack);
    assert_eq!(h.snap()["placements"][0]["presentation_settled"], true);
    let input = h.ok(hit);
    assert_eq!(input["hit"]["native_screen"], json!({"x":720.,"y":520.}));
}
#[test]
fn unobserved_timeout_stays_uncertain_after_read_and_requires_ended_lifetime() {
    let mut h = setup();
    let t = ready(&mut h, "left");
    let e = motion(&mut h, &t, 10., 0.);
    let original = world(&mut h);
    let read = h.ok(reply(&e, "timed_out", true, false, 0., 0.))["effect"].clone();
    assert_eq!(world(&mut h), original);
    assert_eq!(h.snap()["windows"][0]["source"]["observation_known"], false);
    h.rejects(json!({"op":"retire_native_resize_source","transaction":t["transaction"],"identity":identity(),"generation":t["generation"],"lifetime_ended":true}));
    h.ok(reply(&read, "observed", false, true, 190., 150.));
    assert_eq!(world(&mut h), rect(110., 100., 190., 150.));
    assert_eq!(h.snap()["native_resize"]["phase"], "needs_observation");
    for c in [
        json!({"op":"forget","window":1}),
        json!({"op":"remove_source","window":1,"identity":identity(),"keep_placeholder":true}),
        json!({"op":"native_resize_to","transaction":t["transaction"],"screen":{"x":20.,"y":30.}}),
        json!({"op":"native_resize_capture_ready","window":1,"identity":identity(),"generation":t["generation"],"observation_revision":1,"buffer":{"width":380,"height":300}}),
    ] {
        h.rejects(c);
    }
    h.ok(json!({"op":"retire_native_resize_source","transaction":t["transaction"],"identity":identity(),"generation":t["generation"],"lifetime_ended":true}));
    h.rejects(json!({"op":"attach","identity":identity(),"bundle_id":"test","title":"window","buffer":{"width":400,"height":300},"source_rect":rect(0.,0.,200.,150.),"logical_id":1}));
    let mut new_id = identity();
    new_id["birth_sec"] = json!(1800000001);
    attach(&mut h, Some(1), new_id);
    h.rejects(reply(&read, "observed", false, true, 190., 150.));
}
#[test]
fn stale_duplicate_and_invalid_commands_are_atomic() {
    let mut h = setup();
    h.rejects(json!({"op":"begin_native_resize","window":1,"output":1,"edges":"right","group":true,"start_screen":{"x":0.,"y":0.}}));
    let e = begin(&mut h, "right");
    let good = reply(&e, "observed", false, true, 200., 150.);
    for field in ["transaction", "effect_id", "generation"] {
        let mut bad = good.clone();
        bad[field] = json!(999);
        h.rejects(bad);
    }
    let mut bad = good.clone();
    bad["identity"]["birth_usec"] = json!(9);
    h.rejects(bad);
    bad = good.clone();
    bad["result"]["mutation_attempted"] = json!(true);
    h.rejects(bad);
    h.ok(good.clone());
    h.rejects(good);
    let e = motion(&mut h, &e, 10., 0.);
    let mut invalid = reply(&e, "applied", true, true, 210., 150.);
    invalid["result"]["actual_ax"]["size"]["width"] = json!(-1);
    h.rejects(invalid);
    let mut invalid = reply(&e, "applied", true, true, 210., 150.);
    invalid["result"]["actual_cg"]["origin"]["x"] = json!(900.);
    h.rejects(invalid);
    let mut invalid = reply(&e, "applied", true, true, 210., 150.);
    invalid["result"]["mutation_attempted"] = json!(false);
    h.rejects(invalid);
}
#[test]
fn rejected_actual_size_is_authority_and_unsupported_disables_binding() {
    for outcome in ["rejected", "unsupported"] {
        let mut h = setup();
        let t = ready(&mut h, "left");
        let e = motion(&mut h, &t, 20., 0.);
        let result = h.ok(reply(&e, outcome, outcome == "rejected", true, 200., 150.));
        assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
        if outcome == "unsupported" {
            assert_eq!(h.snap()["windows"][0]["source"]["resize_disabled"], true);
            h.ok(reply(
                &result["effect"],
                "observed",
                false,
                true,
                200.,
                150.,
            ));
        }
    }
}
#[test]
fn baseline_mismatch_rejects_and_start_zoom_freezes_displacement() {
    let mut h = setup();
    let e = begin(&mut h, "right");
    h.ok(reply(&e, "observed", false, true, 180., 150.));
    assert_eq!(h.snap()["native_resize"]["phase"], "failed");
    assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
    let mut h = setup();
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":0.,"y":0.}}));
    let t = ready(&mut h, "right");
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":30.,"y":50.}}));
    h.ok(json!({"op":"zoom","output":1,"zoom":1.,"anchor":{"x":0.,"y":0.}}));
    let outputs = h.snap()["outputs"].clone();
    let e = motion(&mut h, &t, 20., 0.);
    assert_eq!(e["requested"]["width"], 240.);
    h.ok(reply(&e, "applied", true, true, 210., 150.));
    assert_eq!(h.snap()["outputs"], outputs);
}
#[test]
fn save_committed_geometry_load_guard_and_monotonic_ids() {
    let path = std::env::temp_dir().join(format!("native-resize-save-{}.json", std::process::id()));
    let mut h = setup();
    let t = ready(&mut h, "right");
    let e = motion(&mut h, &t, 20., 0.);
    h.ok(json!({"op":"save","path":path}));
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let text = serde_json::to_string(&saved).unwrap();
    assert!(
        !text.contains("native_resize")
            && !text.contains("capture_revision")
            && !text.contains("pending_effect")
    ); // Persisted geometry checked by reopened snapshot below.
    h.rejects(json!({"op":"load","path":path}));
    h.rejects(json!({"op":"forget","window":1}));
    h.rejects(
        json!({"op":"remove_source","window":1,"identity":identity(),"keep_placeholder":true}),
    );
    finish(&mut h, &t, true);
    let read = h.ok(reply(&e, "applied", true, true, 220., 150.))["effect"].clone();
    h.ok(reply(&read, "observed", false, true, 220., 150.));
    h.ok(json!({"op":"load","path":path}));
    assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
    h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(0.,0.,1000.,800.)}));
    attach(&mut h, Some(1), identity());
    let next = begin(&mut h, "right");
    assert!(next["transaction"].as_u64() > t["transaction"].as_u64());
    assert!(next["effect_id"].as_u64() > e["effect_id"].as_u64());
    assert!(next["generation"].as_u64() > t["generation"].as_u64());
    h.rejects(reply(&e, "applied", true, true, 220., 150.));
    std::fs::remove_file(path).unwrap();
}

#[test]
fn timeout_error_with_observation_still_cannot_establish_quiescence() {
    let mut h = setup();
    let t = ready(&mut h, "right");
    let e = motion(&mut h, &t, 20., 0.);
    let mut r = reply(&e, "rejected", true, true, 200., 150.);
    r["result"]["ax_error"] = json!(-25204);
    let read = h.ok(r)["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source");
    h.ok(reply(&read, "observed", false, true, 220., 150.));
    assert_eq!(h.snap()["native_resize"]["uncertain_mutation"], true);
    assert_eq!(world(&mut h)["size"]["width"], 220.);
}
#[test]
fn begin_cancels_all_navigation_flights_and_end_before_baseline_drains() {
    let mut h = setup();
    h.ok(
        json!({"op":"register_output","stable_id":"two","screen_bounds":rect(1200.,0.,1000.,800.)}),
    );
    for output in [1, 2] {
        h.ok(json!({"op":"navigate_window","window":1,"output":output,"zoom_policy":"keep"}));
    }
    assert!(
        !h.snap()["navigation"]["flights"]
            .as_object()
            .unwrap()
            .is_empty()
    );
    let e = begin(&mut h, "right");
    assert!(
        h.snap()["navigation"]["flights"]
            .as_object()
            .unwrap()
            .is_empty()
    );
    finish(&mut h, &e, false);
    h.ok(reply(&e, "observed", false, true, 200., 150.));
    assert_eq!(h.snap()["native_resize"]["phase"], "complete");
}
#[test]
fn second_commit_anchors_against_last_actual_size_and_save_while_settling() {
    let mut h = setup();
    let t = ready(&mut h, "top_left");
    let first = motion(&mut h, &t, 20., 20.);
    h.ok(reply(&first, "clamped", true, true, 190., 140.));
    let second = motion(&mut h, &t, 40., 40.);
    finish(&mut h, &t, false);
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    h.ok(json!({"op":"gesture_to","screen_delta":{"x":50.,"y":70.}}));
    h.ok(json!({"op":"end_gesture"}));
    let expected = oracle("5 40 40 1 200 150 190 140 175 125 160 180");
    let read = h.ok(reply(&second, "clamped", true, true, 175., 125.))["effect"].clone();
    assert_eq!(world(&mut h), rect(expected[2], expected[3], 175., 125.));
    let path = std::env::temp_dir().join(format!(
        "native-resize-committed-{}.json",
        std::process::id()
    ));
    h.ok(json!({"op":"save","path":path}));
    h.ok(reply(&read, "observed", false, true, 175., 125.));
    h.ok(json!({"op":"load","path":path}));
    assert_eq!(world(&mut h), rect(expected[2], expected[3], 175., 125.));
    std::fs::remove_file(path).unwrap();
}

#[test]
fn adapter_outcome_flags_are_validated_atomically_for_reads_and_setters() {
    // Enumerated from resize.m: resolve/readback failures versus setter paths.
    // Bit order is (mutation_attempted, observed): FF, FT, TF, TT.
    for (outcome, read_flags, setter_flags) in [
        (
            "observed",
            [false, true, false, false],
            [false, false, false, false],
        ),
        (
            "applied",
            [false, false, false, false],
            [false, false, false, true],
        ),
        (
            "clamped",
            [false, false, false, false],
            [false, false, false, true],
        ),
        (
            "rejected",
            [false, false, false, false],
            [false, false, false, true],
        ),
        (
            "invalid_request",
            [false, false, false, false],
            [true, false, false, false],
        ),
        (
            "stale_identity",
            [true, false, false, false],
            [true, false, true, false],
        ),
        (
            "unavailable",
            [true, false, false, false],
            [true, false, false, false],
        ),
        (
            "missing_window",
            [true, false, false, false],
            [true, false, false, false],
        ),
        (
            "ambiguous_window",
            [true, false, false, false],
            [true, false, false, false],
        ),
        (
            "unsupported",
            [false, false, false, false],
            [false, true, false, false],
        ),
        (
            "readback_failed",
            [true, false, false, false],
            [true, false, true, false],
        ),
        (
            "timed_out",
            [true, false, false, false],
            [true, true, true, false],
        ),
    ] {
        for setter in [false, true] {
            for (index, (attempted, observed)) in
                [(false, false), (false, true), (true, false), (true, true)]
                    .into_iter()
                    .enumerate()
            {
                let mut h = setup();
                let effect = if setter {
                    let t = ready(&mut h, "right");
                    motion(&mut h, &t, 20., 0.)
                } else {
                    begin(&mut h, "right")
                };
                let response = reply(&effect, outcome, attempted, observed, 200., 150.);
                let allowed = if setter {
                    setter_flags[index]
                } else {
                    read_flags[index]
                };
                if allowed {
                    h.ok(response);
                } else {
                    h.rejects(response);
                    // A rejected result leaves the original effect usable.
                    h.ok(reply(
                        &effect,
                        if setter { "applied" } else { "observed" },
                        setter,
                        true,
                        if setter { 220. } else { 200. },
                        150.,
                    ));
                }
            }
        }
    }
}

fn capture_ack(revision: u64, content: Option<Value>) -> Value {
    let mut command = json!({"op":"native_resize_capture_ready","window":1,"identity":identity(),"generation":1,"observation_revision":revision,"buffer":{"width":400,"height":300}});
    if let Some(content) = content {
        command["content_rect"] = content;
    }
    command
}
fn invalidate_capture(h: &mut Host) -> u64 {
    h.ok(json!({"op":"invalidate_native_capture","window":1,"identity":identity(),"generation":1}))
        ["observation_revision"]
        .as_u64()
        .unwrap()
}
fn capture_input() -> Value {
    json!({"op":"input","output":1,"screen":{"x":150.,"y":175.},"identity":identity()})
}
fn observe_capture(source_rect: Value, width: u32, height: u32) -> Value {
    json!({"op":"observe","window":1,"identity":identity(),"source_rect":source_rect,"buffer":{"width":width,"height":height}})
}
#[test]
fn padded_capture_maps_clipped_pixels_without_changing_native_coordinates() {
    let mut h = setup();
    h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(0.,0.,250.,200.)}));
    let world_before = world(&mut h);
    let crop = rect(10.5, 20.25, 300.5, 201.75);
    h.ok(capture_ack(0, Some(crop.clone())));
    let snapshot = h.snap();
    assert_eq!(snapshot["windows"][0]["source"]["content_rect"], crop);
    assert_eq!(
        snapshot["placements"][0]["buffer_crop"],
        rect(10.5, 20.25, 225.375, 134.5)
    );
    let hit = h.ok(capture_input())["hit"].clone();
    assert_eq!(hit["buffer_local"], json!({"x":85.625,"y":121.125}));
    assert_eq!(hit["local"], json!({"x":50.,"y":75.}));
    assert_eq!(hit["native_screen"], json!({"x":60.,"y":95.}));
    assert_eq!(world(&mut h), world_before);
    h.ok(capture_ack(0, None));
    assert_eq!(
        h.snap()["windows"][0]["source"]["content_rect"],
        rect(0., 0., 400., 300.)
    );
    assert_eq!(
        h.ok(capture_input())["hit"]["buffer_local"],
        json!({"x":100.,"y":150.})
    );
}
#[test]
fn capture_content_validation_rejects_invalid_and_out_of_buffer_rectangles_atomically() {
    let mut h = setup();
    for crop in [
        rect(-0.1, 0., 10., 10.),
        rect(0., -0.1, 10., 10.),
        rect(0., 0., 0., 10.),
        rect(0., 0., 10., -1.),
        rect(399.5, 0., 1., 10.),
        rect(0., 299.5, 10., 1.),
        rect(0., 0., 1e100, 10.),
        json!({"origin":{"x":"NaN","y":0},"size":{"width":10,"height":10}}),
        json!({"origin":{"x":null,"y":0},"size":{"width":10,"height":10}}),
    ] {
        h.rejects(capture_ack(0, Some(crop)));
    }
    let mut bad_buffer = capture_ack(0, Some(rect(0., 0., 10., 10.)));
    bad_buffer["buffer"]["width"] = json!(0);
    h.rejects(bad_buffer);
    h.ok(capture_ack(0, Some(rect(0.25, 0.5, 399.75, 299.5))));
}
#[test]
fn invalidation_fences_old_capture_ack_without_moving_geometry() {
    let mut h = setup();
    h.ok(capture_ack(0, Some(rect(10., 10., 380., 280.))));
    let before = h.snap();
    let old = capture_ack(0, None);
    assert_eq!(invalidate_capture(&mut h), 1);
    assert_eq!(invalidate_capture(&mut h), 2);
    let invalidated = h.snap();
    assert_eq!(invalidated["outputs"], before["outputs"]);
    assert_eq!(
        invalidated["windows"][0]["world_rect"],
        before["windows"][0]["world_rect"]
    );
    assert_eq!(
        invalidated["windows"][0]["source"]["observed_rect"],
        before["windows"][0]["source"]["observed_rect"]
    );
    assert_eq!(
        invalidated["windows"][0]["source"]["observation_known"],
        true
    );
    assert_eq!(invalidated["placements"][0]["presentation_settled"], false);
    assert!(invalidated["placements"][0]["buffer_crop"].is_null());
    h.rejects(capture_input());
    h.rejects(old);
    h.rejects(capture_ack(1, Some(rect(10., 10., 380., 280.))));
    h.ok(capture_ack(2, Some(rect(10., 10., 380., 280.))));
    assert_eq!(h.snap()["placements"][0]["presentation_settled"], true);
    h.ok(capture_input());
}
#[test]
fn capture_binding_generation_and_owner_must_match_after_rebind() {
    let mut h = setup();
    let invalidation =
        json!({"op":"invalidate_native_capture","window":1,"identity":identity(),"generation":1});
    for mut command in [capture_ack(0, None), invalidation.clone()] {
        command["identity"]["owner"] = json!(900);
        h.rejects(command);
    }
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(),"keep_placeholder":true}));
    attach(&mut h, Some(1), identity());
    assert_eq!(
        h.snap()["windows"][0]["source"]["content_rect"],
        rect(0., 0., 400., 300.)
    );
    h.rejects(invalidation.clone());
    h.rejects(capture_ack(0, None));
    let mut current = invalidation;
    current["generation"] = json!(2);
    assert_eq!(h.ok(current)["observation_revision"], 1);
    let mut ack = capture_ack(1, Some(rect(20., 20., 360., 260.)));
    ack["generation"] = json!(2);
    h.ok(ack);
}
#[test]
fn legacy_observe_preserves_crop_but_changed_capture_metadata_requires_ack() {
    let mut h = setup();
    let crop = rect(10.5, 20.25, 300.5, 201.75);
    h.ok(capture_ack(0, Some(crop.clone())));
    h.ok(observe_capture(rect(10., 20., 200., 150.), 400, 300));
    assert_eq!(h.snap()["windows"][0]["source"]["content_rect"], crop);
    h.ok(observe_capture(rect(30., 40., 200., 150.), 400, 300));
    assert_eq!(
        h.ok(capture_input())["hit"]["native_screen"],
        json!({"x":80.,"y":115.})
    );
    assert_eq!(h.snap()["windows"][0]["source"]["content_rect"], crop);
    h.ok(observe_capture(rect(30., 40., 200., 150.), 800, 600));
    assert_eq!(h.snap()["windows"][0]["source"]["observation_revision"], 1);
    assert_eq!(
        h.snap()["windows"][0]["source"]["content_rect"],
        rect(0., 0., 800., 600.)
    );
    h.rejects(capture_input());
    h.rejects(capture_ack(0, Some(crop)));
    h.ok(observe_capture(rect(30., 40., 200., 150.), 800, 600));
    h.rejects(capture_input());
    let mut ack = capture_ack(1, None);
    ack["buffer"] = json!({"width":800,"height":600});
    h.ok(ack);
    h.ok(observe_capture(rect(30., 40., 400., 300.), 800, 600));
    assert_eq!(h.snap()["windows"][0]["source"]["observation_revision"], 2);
    h.rejects(capture_input());
    let mut ack = capture_ack(2, Some(rect(20., 20., 760., 560.)));
    ack["buffer"] = json!({"width":800,"height":600});
    h.ok(ack);
    assert_eq!(
        h.ok(capture_input())["hit"]["local"],
        json!({"x":100.,"y":150.})
    );
    assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
    // Existing ABI callers that never opted into crop/revision authority retain
    // whole-buffer observe semantics.
    let mut legacy = setup();
    legacy.ok(observe_capture(rect(30., 40., 400., 300.), 800, 600));
    assert_eq!(
        legacy.snap()["windows"][0]["source"]["observation_revision"],
        0
    );
    assert_eq!(
        legacy.ok(capture_input())["hit"]["buffer_local"],
        json!({"x":200.,"y":300.})
    );
}
#[test]
fn capture_contract_is_transient_and_does_not_bypass_uncertain_setter() {
    let mut h = setup();
    let path =
        std::env::temp_dir().join(format!("capture-contract-save-{}.json", std::process::id()));
    h.ok(json!({"op":"save","path":path}));
    let saved = std::fs::read(&path).unwrap();
    let revision = invalidate_capture(&mut h);
    h.ok(capture_ack(revision, Some(rect(10., 20., 380., 270.))));
    h.ok(json!({"op":"save","path":path}));
    assert_eq!(std::fs::read(&path).unwrap(), saved);
    let t = ready(&mut h, "right");
    let e = motion(&mut h, &t, 20., 0.);
    let revision = invalidate_capture(&mut h);
    h.rejects(capture_ack(revision, Some(rect(10., 20., 380., 270.))));
    let read = h.ok(reply(&e, "timed_out", true, false, 0., 0.))["effect"].clone();
    h.ok(reply(&read, "observed", false, true, 220., 150.));
    let revision = h.snap()["windows"][0]["source"]["observation_revision"]
        .as_u64()
        .unwrap();
    h.rejects(capture_ack(revision, None));
    std::fs::remove_file(path).unwrap();
}

#[test]
fn quick_drag_release_queues_only_latest_motion_until_baseline_is_validated() {
    let mut h = setup();
    let initial = world(&mut h);
    let baseline = begin(&mut h, "bottom_right");
    for delta in [10., 25., 40.] {
        assert!(motion(&mut h, &baseline, delta, delta).is_null());
        assert_eq!(h.snap()["native_resize"]["pending_effect"], baseline);
        assert_eq!(world(&mut h), initial);
    }
    assert!(finish(&mut h, &baseline, false).is_null());
    h.rejects(json!({"op":"native_resize_to","transaction":baseline["transaction"],"screen":{"x":100.,"y":100.}}));
    let setter = h.ok(reply(&baseline, "observed", false, true, 200., 150.))["effect"].clone();
    assert_eq!(setter["op"], "resize_native_window");
    assert_eq!(setter["requested"], json!({"width":240.,"height":190.}));
    assert_eq!(h.snap()["native_resize"]["phase"], "settling");
    let read = h.ok(reply(&setter, "applied", true, true, 240., 190.))["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source");
    h.ok(reply(&read, "observed", false, true, 240., 190.));
    assert_eq!(h.snap()["native_resize"]["phase"], "complete");
    assert_eq!(world(&mut h), rect(100., 100., 240., 190.));
}
#[test]
fn cancellation_before_baseline_discards_unsent_motion() {
    let mut h = setup();
    let baseline = begin(&mut h, "left");
    assert!(motion(&mut h, &baseline, 30., 0.).is_null());
    assert!(finish(&mut h, &baseline, true).is_null());
    let response = h.ok(reply(&baseline, "observed", false, true, 200., 150.));
    assert!(response["effect"].is_null());
    assert!(h.snap()["native_resize"]["coalesced_latest"].is_null());
    assert_eq!(h.snap()["native_resize"]["phase"], "failed");
    assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
}
#[test]
fn failed_or_mismatched_baseline_never_dispatches_queued_motion() {
    for (outcome, observed, width) in [
        ("observed", true, 180.),
        ("timed_out", false, 0.),
        ("readback_failed", false, 0.),
        ("stale_identity", false, 0.),
        ("unavailable", false, 0.),
        ("missing_window", false, 0.),
        ("ambiguous_window", false, 0.),
    ] {
        let mut h = setup();
        let baseline = begin(&mut h, "right");
        assert!(motion(&mut h, &baseline, 30., 0.).is_null());
        finish(&mut h, &baseline, false);
        let response = h.ok(reply(&baseline, outcome, false, observed, width, 150.));
        assert!(response["effect"].is_null());
        let state = h.snap()["native_resize"].clone();
        assert_eq!(state["phase"], "failed");
        assert!(state["pending_effect"].is_null());
        assert!(state["coalesced_latest"].is_null());
        assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
    }
}
#[test]
fn baseline_releases_queued_motion_and_continues_accepting_held_drag() {
    let mut h = setup();
    let baseline = begin(&mut h, "right");
    motion(&mut h, &baseline, 20., 0.);
    let first = h.ok(reply(&baseline, "observed", false, true, 200., 150.))["effect"].clone();
    assert_eq!(h.snap()["native_resize"]["phase"], "dragging");
    assert!(motion(&mut h, &baseline, 40., 0.).is_null());
    let second = h.ok(reply(&first, "applied", true, true, 220., 150.))["effect"].clone();
    assert_eq!(second["requested"], json!({"width":240.,"height":150.}));
    h.ok(reply(&second, "applied", true, true, 240., 150.));
    let read = finish(&mut h, &baseline, false);
    h.ok(reply(&read, "observed", false, true, 240., 150.));
    assert_eq!(h.snap()["native_resize"]["phase"], "complete");
}

#[test]
fn queued_return_to_origin_skips_setter_after_baseline_for_held_and_released_drag() {
    for released in [false, true] {
        let mut h = setup();
        let baseline = begin(&mut h, "right");
        assert!(motion(&mut h, &baseline, 20., 0.).is_null());
        assert!(motion(&mut h, &baseline, 0., 0.).is_null());
        if released {
            finish(&mut h, &baseline, false);
        }
        let result = h.ok(reply(&baseline, "observed", false, true, 200., 150.));
        assert!(result["effect"].is_null());
        let state = h.snap()["native_resize"].clone();
        assert!(state["pending_effect"].is_null());
        assert!(state["coalesced_latest"].is_null());
        assert_eq!(
            state["phase"],
            if released { "complete" } else { "dragging" }
        );
        assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
        assert_eq!(h.snap()["windows"][0]["source"]["capture_revision"], 0);
        if !released {
            let setter = motion(&mut h, &baseline, 30., 0.);
            assert_eq!(setter["requested"], json!({"width":230.,"height":150.}));
        }
    }
}
#[test]
fn skipping_coalesced_size_already_observed_still_drains_final_read_after_setter() {
    let mut h = setup();
    let t = ready(&mut h, "right");
    let first = motion(&mut h, &t, 20., 0.);
    assert!(motion(&mut h, &t, 40., 0.).is_null());
    finish(&mut h, &t, false);
    let final_read = h.ok(reply(&first, "clamped", true, true, 240., 150.))["effect"].clone();
    assert_eq!(final_read["op"], "observe_resize_source");
    assert!(h.snap()["native_resize"]["coalesced_latest"].is_null());
    h.ok(reply(&final_read, "observed", false, true, 240., 150.));
    assert_eq!(h.snap()["native_resize"]["phase"], "complete");
}

// Readback mode: what every normal run without the flag reports
// (NATIVE_RESIZE.md). The native window is the authority for its size.
fn readback() -> Host {
    let mut h = setup();
    h.ok(json!({"op":"native_resize_capability","enabled":true,"readback":true}));
    h
}
fn observe(size: (f64, f64)) -> Value {
    json!({"op":"observe","window":1,"identity":identity(),"source_rect":rect(10.,20.,size.0,size.1),"buffer":{"width":400,"height":300}})
}
fn settled(h: &mut Host) {
    let source = h.snap()["windows"][0]["source"].clone();
    assert_eq!(source["observation_known"], true, "{source}");
    assert_eq!(
        source["capture_revision"], source["observation_revision"],
        "{source}"
    );
    h.ok(json!({"op":"input","output":1,"screen":{"x":150.,"y":150.},"identity":identity()}));
}
#[test]
fn readback_observe_adopts_a_size_the_window_changed_and_says_so() {
    let mut h = readback();
    assert_eq!(h.ok(observe((200., 150.))), json!({}));
    assert_eq!(h.ok(observe((260., 190.))), json!({"resized":true}));
    // Top-left kept: nobody knows which edge moved.
    assert_eq!(world(&mut h), rect(100., 100., 260., 190.));
    settled(&mut h);
    assert_eq!(h.ok(observe((260., 190.))), json!({}));
    // The acknowledged mode maps the picture again and leaves the world alone.
    let mut h = setup();
    assert_eq!(h.ok(observe((260., 190.))), json!({}));
    assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
}
#[test]
fn readback_holds_structure_only_while_the_transaction_is_live() {
    let mut h = readback();
    let reply =
        h.ok(json!({"op":"ipc","output":1,"request":{"Resize":{"window":1,"to":[300,200]}}}));
    let read = reply["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source", "{reply}");
    let setter = h.ok(self::reply(&read, "observed", false, true, 200., 150.))["effect"].clone();
    assert_eq!(setter["op"], "resize_native_window");
    settled(&mut h);
    for c in [
        observe((300., 200.)),
        json!({"op":"window_closed","window":1,"identity":identity(),"output":1}),
        json!({"op":"remove_source","window":1,"identity":identity(),"keep_placeholder":true}),
    ] {
        h.rejects(c);
    }
    // The window went away under the setter: one diagnostic read, and its
    // answer ends the transaction.
    let read = h.ok(self::reply(&setter, "stale_identity", true, false, 0., 0.))["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source");
    settled(&mut h);
    h.rejects(observe((300., 200.)));
    let end = h.ok(self::reply(&read, "stale_identity", false, false, 0., 0.));
    assert_eq!(end["effect"], Value::Null);
    let slot = h.snap()["native_resize"].clone();
    assert_eq!(slot["phase"], "failed", "{slot}");
    assert_eq!(slot["uncertain_mutation"], false);
    settled(&mut h);
    assert_eq!(h.ok(observe((200., 150.))), json!({}));
    h.ok(json!({"op":"window_closed","window":1,"identity":identity(),"output":1}));
}
#[test]
fn readback_survives_a_scene_load_with_the_capability() {
    let path = std::env::temp_dir().join(format!("native-readback-{}.json", std::process::id()));
    let mut h = readback();
    h.ok(json!({"op":"save","path":path}));
    h.ok(json!({"op":"load","path":path}));
    h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(0.,0.,1000.,800.)}));
    attach(&mut h, Some(1), identity());
    assert_eq!(h.ok(observe((260., 190.))), json!({"resized":true}));
    let reply =
        h.ok(json!({"op":"ipc","output":1,"request":{"Resize":{"window":1,"to":[300,200]}}}));
    assert_eq!(reply["effect"]["op"], "observe_resize_source", "{reply}");
    std::fs::remove_file(path).unwrap();
}
