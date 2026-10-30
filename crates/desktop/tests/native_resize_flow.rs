// SPDX-License-Identifier: GPL-3.0-or-later
//! Exported C ABI contract only. Synthetic native observations
//! do not prove native mutation, pixels, or usable compositing.
use serde_json::{Value, json};
use std::{
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
    sync::OnceLock,
};

#[path = "support/host.rs"]
mod host;
use host::Host;
impl Host {
    fn snap(&mut self) -> Value {
        self.ok(json!({"op":"snapshot"}))
    }
    fn rejects(&mut self, c: Value) {
        let before = self.snap();
        assert_eq!(self.call(c)["ok"], false);
        assert_eq!(self.snap(), before);
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
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
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
fn stale_duplicate_and_invalid_commands_are_atomic() {
    let mut h = setup();
    h.rejects(json!({"op":"begin_native_resize","window":1,"output":2,"edges":"right","group":true,"start_screen":{"x":0.,"y":0.}}));
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
fn rejected_actual_size_is_authority_and_unsupported_ends_the_grab() {
    for outcome in ["rejected", "unsupported"] {
        let mut h = setup();
        let t = ready(&mut h, "left");
        let e = motion(&mut h, &t, 20., 0.);
        let result = h.ok(reply(&e, outcome, outcome == "rejected", true, 200., 150.));
        assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
        if outcome == "unsupported" {
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
fn motion_tracks_the_current_viewport() {
    let mut h = setup();
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":0.,"y":0.}}));
    let t = h.ok(json!({"op":"begin_native_resize","window":1,"output":1,"edges":"right","start_screen":{"x":150.,"y":87.5}}))["effect"].clone();
    h.ok(reply(&t, "observed", false, true, 200., 150.));
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":30.,"y":50.}}));
    h.ok(json!({"op":"zoom","output":1,"zoom":1.,"anchor":{"x":0.,"y":0.}}));
    let outputs = h.snap()["outputs"].clone();
    let e = to(&mut h, &t, 170., 87.5);
    assert_eq!(e["requested"]["width"], 130.);
    h.ok(reply(&e, "applied", true, true, 130., 150.));
    assert_eq!(world(&mut h), rect(100., 100., 130., 150.));
    // The observed right edge projects to x=170 after the camera and zoom
    // changed; frozen start-zoom displacement would project it elsewhere.
    assert_eq!((100. + 130. - 60.) * 1., 170.);
    assert_eq!(h.snap()["outputs"], outputs);
}

#[test]
fn held_native_resize_rejects_navigation_and_release_unblocks_before_readback() {
    for cancel in [false, true] {
        for pinned in [false, true] {
            let mut h = setup();
            if pinned {
                h.ok(json!({"op":"focus","window":1}));
                h.ok(json!({"op":"action","output":1,"action":"toggle-pin-to-screen"}));
            }
            let t = begin(&mut h, "right");
            let blocked = [
                json!({"op":"zoom_by","output":1,"anchor":{"x":50.,"y":50.},"delta":15.,"source":"wheel"}),
                json!({"op":"zoom_by","output":1,"anchor":{"x":50.,"y":50.},"delta":0.1,"source":"pinch","phase":"begin"}),
                json!({"op":"pan_viewport","output":1,"direction":"right"}),
                json!({"op":"zoom_in","output":1}),
                json!({"op":"zoom_out","output":1}),
                json!({"op":"zoom_reset","output":1}),
                json!({"op":"zoom_to_fit","output":1}),
                json!({"op":"home_toggle","output":1}),
                json!({"op":"navigate_window","window":1,"output":1,"zoom_policy":"keep"}),
            ];
            for observed in [false, true] {
                if observed {
                    h.ok(reply(&t, "observed", false, true, 200., 150.));
                }
                for command in &blocked {
                    // A pinned window's navigate command only requests focus;
                    // there is no camera flight to refuse at that site.
                    if pinned && command["op"] == "navigate_window" {
                        continue;
                    }
                    let before = h.snap();
                    let result = h.call(command.clone());
                    assert_eq!(result["ok"], false, "{command}: {result}");
                    assert_eq!(result["error"], "navigation during active gesture");
                    assert_eq!(h.snap(), before);
                }
            }
            let setter = motion(&mut h, &t, 10., 0.);
            assert_eq!(setter["requested"], size(210., 150.));
            assert!(finish(&mut h, &t, cancel).is_null());
            assert_eq!(h.snap()["native_resize"]["pending_effect"], setter);
            // The physical grab ended. Its queued setter and final read still
            // drain, while a new navigation gesture can proceed immediately.
            h.ok(blocked[0].clone());
            let final_read =
                h.ok(reply(&setter, "applied", true, true, 210., 150.))["effect"].clone();
            assert_eq!(final_read["op"], "observe_resize_source");
            h.ok(json!({"op":"zoom_reset","output":1}));
            h.ok(reply(&final_read, "observed", false, true, 210., 150.));
            assert_eq!(
                h.snap()["native_resize"]["phase"],
                if cancel { "failed" } else { "complete" }
            );
        }
    }
}

#[test]
fn action_size_readback_does_not_own_navigation() {
    let mut h = setup();
    let read = h.ok(json!({"op":"ipc","output":1,"request":{"Resize":{"window":1,"to":[300,200]}}}))["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source");
    h.ok(
        json!({"op":"zoom_by","output":1,"anchor":{"x":50.,"y":50.},"delta":15.,"source":"wheel"}),
    );
    let setter = h.ok(reply(&read, "observed", false, true, 200., 150.))["effect"].clone();
    assert_eq!(setter["requested"], size(300., 200.));
    h.ok(json!({"op":"navigate_window","window":1,"output":1,"zoom_policy":"keep"}));
    let final_read = h.ok(reply(&setter, "applied", true, true, 300., 200.))["effect"].clone();
    h.ok(reply(&final_read, "observed", false, true, 300., 200.));
    assert_eq!(h.snap()["native_resize"]["phase"], "complete");
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
fn timeout_error_with_observation_ends_after_diagnostic_read() {
    let mut h = setup();
    let t = ready(&mut h, "right");
    let e = motion(&mut h, &t, 20., 0.);
    let mut r = reply(&e, "rejected", true, true, 200., 150.);
    r["result"]["ax_error"] = json!(-25204);
    let read = h.ok(r)["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source");
    h.ok(reply(&read, "observed", false, true, 220., 150.));
    assert_eq!(h.snap()["native_resize"]["uncertain_mutation"], false);
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
    // Enumerated from DWNativeResize.m: resolve/readback failures versus setter paths.
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

#[test]
fn native_resize_capability_is_strict_and_atomic() {
    let mut h = setup();
    for command in [
        json!({"op":"native_resize_capability"}),
        json!({"op":"native_resize_capability","enabled":null}),
    ] {
        h.rejects(command);
    }
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
fn failed_baseline_never_dispatches_queued_motion() {
    for (outcome, observed, width) in [
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
        assert_eq!(h.snap()["placements"][0]["presentation_settled"], true);
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

// Native readback is the supported resize protocol
// (NATIVE_RESIZE.md). The native window is the authority for its size.
fn readback() -> Host {
    setup()
}
fn observe(size: (f64, f64)) -> Value {
    json!({"op":"observe","window":1,"identity":identity(),"source_rect":rect(10.,20.,size.0,size.1),"buffer":{"width":400,"height":300}})
}
fn settled(h: &mut Host) {
    let source = h.snap()["windows"][0]["source"].clone();
    assert_eq!(source["observation_known"], true, "{source}");
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

// The pointer resize of a normal run: upstream's resize grab on the readback
// path. Output 1 is 1000 x 800 at the screen origin with the camera at the
// world origin, so a screen point is a world point; window 1 is at
// (100, 100) 200 x 150.
fn grab(h: &mut Host, at: (f64, f64), group: bool) -> Value {
    h.ok(json!({"op":"begin_native_resize","window":1,"output":1,"start_screen":{"x":at.0,"y":at.1},"group":group}))["effect"].clone()
}
fn to(h: &mut Host, t: &Value, x: f64, y: f64) -> Value {
    h.ok(json!({"op":"native_resize_to","transaction":t["transaction"],"screen":{"x":x,"y":y}}))["effect"].clone()
}
fn size(w: f64, h: f64) -> Value {
    json!({"width":w,"height":h})
}
#[test]
fn readback_grab_takes_its_edges_from_where_in_the_window_it_began() {
    // Upstream edges_from_position: thirds, strict, the centre resizing from
    // the bottom right. 200 / 3 = 66.7 and 150 / 3 = 50.
    for (at, edges) in [
        ((110.0, 110.0), "top_left"),
        ((200.0, 110.0), "top"),
        ((290.0, 110.0), "top_right"),
        ((110.0, 175.0), "left"),
        ((200.0, 175.0), "bottom_right"),
        ((290.0, 175.0), "right"),
        ((110.0, 240.0), "bottom_left"),
        ((200.0, 240.0), "bottom"),
        ((290.0, 240.0), "bottom_right"),
        // On the lines between the cells: `<` and `>`, so the centre.
        ((100.0 + 200.0 / 3.0 + 0.1, 150.0), "bottom_right"),
        ((100.0 + 200.0 / 3.0 - 0.1, 150.0), "left"),
    ] {
        let mut h = readback();
        grab(&mut h, at, false);
        assert_eq!(h.snap()["native_resize"]["edges"], edges, "{at:?}");
    }
    // An edge the caller names stands: the resize border's.
    let mut h = readback();
    h.ok(json!({"op":"begin_native_resize","window":1,"output":1,"edges":"top","start_screen":{"x":290.0,"y":240.0}}));
    assert_eq!(h.snap()["native_resize"]["edges"], "top");
}
#[test]
fn readback_grab_cuts_the_delta_to_whole_units_and_holds_the_pointer_on_its_output() {
    let mut h = readback();
    let t = grab(&mut h, (290.0, 240.0), false);
    h.ok(reply(&t, "observed", false, true, 200., 150.));
    // Upstream's `as i32`: toward zero on each axis.
    let e = to(&mut h, &t, 300.9, 236.3);
    assert_eq!(e["requested"], size(210., 147.));
    h.ok(reply(&e, "applied", true, true, 210., 147.));
    // Less than one unit of further motion asks nothing.
    assert_eq!(to(&mut h, &t, 300.2, 236.9), Value::Null);
    assert_eq!(
        h.snap()["native_resize"]["latest_requested"],
        size(210., 147.)
    );
    // The pointer cannot leave [0, 999] x [0, 799]: 999 - 290 and 0 - 240,
    // the height floored at 1.
    let e = to(&mut h, &t, 5000.0, -5000.0);
    assert_eq!(e["requested"], size(909., 1.));
}
#[test]
fn readback_grab_keeps_the_opposite_edge_for_the_size_the_window_took() {
    let mut h = readback();
    let t = grab(&mut h, (110.0, 110.0), false);
    h.ok(reply(&t, "observed", false, true, 200., 150.));
    let e = to(&mut h, &t, 80.0, 90.0);
    assert_eq!(e["requested"], size(230., 170.));
    // Nothing is shown before the window answers.
    assert_eq!(world(&mut h), rect(100., 100., 200., 150.));
    // It took less than was asked: the bottom right corner, (300, 250),
    // stays for the size it has.
    h.ok(reply(&e, "clamped", true, true, 220., 160.));
    assert_eq!(world(&mut h), rect(80., 90., 220., 160.));
    // Upstream configures a client only when the size differs from the last
    // one it configured: the size just bent is not asked again, another is.
    assert_eq!(to(&mut h, &t, 80.0, 90.0), Value::Null);
    assert_eq!(to(&mut h, &t, 79.6, 89.6), Value::Null);
    let e = to(&mut h, &t, 70.0, 90.0);
    assert_eq!(e["requested"], size(240., 170.));
    // Refused outright: the canvas keeps the size the window has.
    h.ok(reply(&e, "rejected", true, true, 220., 160.));
    assert_eq!(world(&mut h), rect(80., 90., 220., 160.));
    let last = finish(&mut h, &t, false);
    assert_eq!(last["op"], "observe_resize_source");
    h.ok(reply(&last, "observed", false, true, 220., 160.));
    assert_eq!(h.snap()["native_resize"]["phase"], "complete");
    assert_eq!(world(&mut h), rect(80., 90., 220., 160.));
}
#[test]
fn readback_grab_preserves_the_pressed_edge_after_a_changed_baseline() {
    let mut h = readback();
    let t = grab(&mut h, (290.0, 240.0), false);
    // Motion ahead of the answer waits in the one slot.
    assert_eq!(to(&mut h, &t, 300.0, 250.0), Value::Null);
    // The window had another size than the canvas: adopt its actual size,
    // top-left kept, but keep the pointer's original offset from the edge.
    let e = h.ok(reply(&t, "observed", false, true, 260., 190.))["effect"].clone();
    assert_eq!(world(&mut h), rect(100., 100., 260., 190.));
    assert_eq!(e["requested"], size(210., 160.));
    h.ok(reply(&e, "applied", true, true, 210., 160.));
    let e = to(&mut h, &t, 310.0, 240.0);
    assert_eq!(e["requested"], size(220., 150.));
}

// These cross the exported controller ABI and supply synthetic native results.
// They verify pointer/world geometry, not native input or compositor usability.
#[test]
fn zoomed_readback_edges_keep_the_pointer_offset_through_delayed_baselines() {
    for zoom in [0.2, 0.5, 0.8, 1.0] {
        for baseline in [(200., 150.), (260., 190.)] {
            for (edges, x, y) in [
                ("top_left", 100., 100.),
                ("top", 200., 100.),
                ("top_right", 300., 100.),
                ("right", 300., 175.),
                ("bottom_right", 300., 250.),
                ("bottom", 200., 250.),
                ("bottom_left", 100., 250.),
                ("left", 100., 175.),
            ] {
                let mut h = readback();
                // Nonzero display origin and asymmetric camera: screen and
                // native origins must never be mistaken for canvas points.
                h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(37.,53.,1000.,800.)}));
                h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":17.,"y":29.}}));
                h.ok(json!({"op":"zoom","output":1,"zoom":zoom,"anchor":{"x":37.,"y":53.}}));
                let left = edges.contains("left");
                let right = edges.contains("right");
                let top = edges.contains("top");
                let bottom = edges.contains("bottom");
                let sx = 37.
                    + (x - 17.) * zoom
                    + if left {
                        2.
                    } else if right {
                        -2.
                    } else {
                        0.
                    };
                let sy = 53.
                    + (y - 29.) * zoom
                    + if top {
                        2.
                    } else if bottom {
                        -2.
                    } else {
                        0.
                    };
                let dx = if left {
                    -40.
                } else if right {
                    40.
                } else {
                    0.
                };
                let dy = if top {
                    -24.
                } else if bottom {
                    24.
                } else {
                    0.
                };
                let t = h.ok(json!({"op":"begin_native_resize","window":1,"output":1,"edges":edges,"start_screen":{"x":sx,"y":sy}}))["effect"].clone();
                // Many motions/release may arrive while the baseline is owed.
                assert!(to(&mut h, &t, sx + dx * zoom / 2., sy + dy * zoom / 2.).is_null());
                assert!(to(&mut h, &t, sx + dx * zoom, sy + dy * zoom).is_null());
                assert!(finish(&mut h, &t, false).is_null());
                let e = h.ok(reply(&t, "observed", false, true, baseline.0, baseline.1))["effect"]
                    .clone();
                let width = if left {
                    baseline.0 + 40.
                } else if right {
                    240.
                } else {
                    baseline.0
                };
                let height = if top {
                    baseline.1 + 24.
                } else if bottom {
                    174.
                } else {
                    baseline.1
                };
                let context = format!("{edges} zoom={zoom} baseline={baseline:?}");
                assert_eq!(e["requested"], size(width, height), "{context}");
                let last = h.ok(reply(&e, "applied", true, true, width, height))["effect"].clone();
                h.ok(reply(&last, "observed", false, true, width, height));
                let expected = rect(
                    if left { 60. } else { 100. },
                    if top { 76. } else { 100. },
                    width,
                    height,
                );
                assert_eq!(world(&mut h), expected, "{context}");
                let rect = world(&mut h);
                if left || right {
                    let edge =
                        rect["origin"]["x"].as_f64().unwrap() + if right { width } else { 0. };
                    let offset = 37. + (edge - 17.) * zoom - (sx + dx * zoom);
                    assert!(
                        (offset - if right { 2. } else { -2. }).abs() <= zoom,
                        "{context}: x offset {offset}"
                    );
                }
                if top || bottom {
                    let edge =
                        rect["origin"]["y"].as_f64().unwrap() + if bottom { height } else { 0. };
                    let offset = 53. + (edge - 29.) * zoom - (sy + dy * zoom);
                    assert!(
                        (offset - if bottom { 2. } else { -2. }).abs() <= zoom,
                        "{context}: y offset {offset}"
                    );
                }
            }
        }
    }
}
#[test]
fn distant_world_cameras_preserve_whole_and_fractional_native_resize_motion() {
    for zoom in [0.2, 0.5, 0.8, 1.0] {
        for base in [-900_000_000_000., 900_000_000_000.] {
            for fraction in [0., 0.01] {
                let mut h = Host::new();
                h.ok(json!({"op":"native_resize_capability","enabled":true}));
                h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(37.,53.,1000.,800.)}));
                h.ok(json!({"op":"attach","identity":identity(),"bundle_id":"test","title":"distant window","buffer":{"width":400,"height":300},"source_rect":rect(10.,20.,200.,150.),"world_rect":rect(base+100.,-base+100.,200.,150.)}));
                h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":base,"y":-base}}));
                h.ok(json!({"op":"zoom","output":1,"zoom":zoom,"anchor":{"x":37.,"y":53.}}));
                // The inward offset is fractional in world units at zoom .8.
                // It must survive even at the largest supported world scale.
                let (sx, sy) = (37. + 300. * zoom - 2., 53. + 250. * zoom - 2.);
                let t = h.ok(json!({"op":"begin_native_resize","window":1,"output":1,"edges":"bottom_right","start_screen":{"x":sx,"y":sy}}))["effect"].clone();
                assert!(
                    to(
                        &mut h,
                        &t,
                        sx + (40. - fraction) * zoom,
                        sy + (24. - fraction) * zoom
                    )
                    .is_null()
                );
                let baseline = if fraction == 0. {
                    (260., 190.)
                } else {
                    (200., 150.)
                };
                let e = h.ok(reply(&t, "observed", false, true, baseline.0, baseline.1))["effect"]
                    .clone();
                let expected = size(
                    if fraction == 0. { 240. } else { 239. },
                    if fraction == 0. { 174. } else { 173. },
                );
                assert_eq!(
                    e["requested"], expected,
                    "base={base} zoom={zoom} fraction={fraction}"
                );
                h.ok(reply(
                    &e,
                    "applied",
                    true,
                    true,
                    expected["width"].as_f64().unwrap(),
                    expected["height"].as_f64().unwrap(),
                ));
                assert_eq!(
                    world(&mut h),
                    rect(
                        base + 100.,
                        -base + 100.,
                        expected["width"].as_f64().unwrap(),
                        expected["height"].as_f64().unwrap()
                    )
                );
            }
        }
    }
}
#[test]
fn readback_grab_carries_its_cluster_by_the_size_the_window_took() {
    let mut h = readback();
    // Window 2 a snap gap (12) to the right of window 1.
    h.ok(json!({"op":"attach","identity":{"pid":123,"birth_sec":1800000000,"birth_usec":5,"wid":2},"bundle_id":"test","title":"neighbour","buffer":{"width":400,"height":300},"source_rect":rect(900.,20.,200.,150.),"world_rect":rect(312.,100.,200.,150.),"logical_id":null}));
    let frame = |h: &mut Host, id: u64| {
        h.snap()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == id)
            .unwrap()["world_rect"]
            .clone()
    };
    let neighbour = |h: &mut Host| frame(h, 2);
    let t = grab(&mut h, (290.0, 175.0), true);
    assert_eq!(h.snap()["native_resize"]["group"], true);
    h.ok(reply(&t, "observed", false, true, 200., 150.));
    let e = to(&mut h, &t, 350.0, 175.0);
    assert_eq!(e["requested"], size(260., 150.));
    assert_eq!(e["window"], 1);
    assert_eq!(neighbour(&mut h), rect(312., 100., 200., 150.));
    h.ok(reply(&e, "clamped", true, true, 240., 150.));
    assert_eq!(frame(&mut h, 1), rect(100., 100., 240., 150.));
    assert_eq!(neighbour(&mut h), rect(352., 100., 200., 150.));
    // Back past the start: the neighbour comes back with the edge.
    let e = to(&mut h, &t, 270.0, 175.0);
    h.ok(reply(&e, "applied", true, true, 180., 150.));
    assert_eq!(neighbour(&mut h), rect(292., 100., 200., 150.));
}
#[test]
fn readback_grab_asks_again_of_a_window_that_was_not_settable() {
    let mut h = readback();
    let t = grab(&mut h, (290.0, 240.0), false);
    h.ok(reply(&t, "observed", false, true, 200., 150.));
    let e = to(&mut h, &t, 300.0, 250.0);
    // Not settable: the grab is over, and one read ends its transaction.
    let last = h.ok(reply(&e, "unsupported", false, true, 200., 150.))["effect"].clone();
    assert_eq!(last["op"], "observe_resize_source");
    // Motion meanwhile, and after, is refused and changes nothing.
    h.rejects(json!({"op":"native_resize_to","transaction":t["transaction"],"screen":{"x":320.0,"y":260.0}}));
    h.ok(reply(&last, "observed", false, true, 200., 150.));
    assert_eq!(h.snap()["native_resize"]["phase"], "failed");
    h.rejects(json!({"op":"native_resize_to","transaction":t["transaction"],"screen":{"x":320.0,"y":260.0}}));
    h.rejects(json!({"op":"end_native_resize","transaction":t["transaction"]}));
    // The next press asks again: a sheet may have closed since.
    let t = grab(&mut h, (290.0, 240.0), false);
    assert_eq!(t["op"], "observe_resize_source");
}
// One size transaction at a time: while a grab holds the slot, a sizing
// action, a fullscreen toggle and an IPC resize are refused and change
// nothing, whether or not an effect is owed.
#[test]
fn readback_grab_refuses_every_other_sizing_while_it_lasts() {
    let mut h = readback();
    let t = grab(&mut h, (290.0, 240.0), false);
    let others = [
        json!({"op":"action","output":1,"action":"grow-window right"}),
        json!({"op":"action","output":1,"action":"fit-window"}),
        json!({"op":"action","output":1,"action":"toggle-fullscreen"}),
        json!({"op":"ipc","output":1,"request":{"Resize":{"window":1,"to":[300,200]}}}),
        json!({"op":"begin_native_resize","window":1,"output":1,"start_screen":{"x":290.0,"y":240.0}}),
    ];
    // An action and a second grab are refused as commands; the socket's
    // Resize is answered, with the refusal as its reply.
    let refused = |h: &mut Host| {
        for c in &others {
            let before = h.snap();
            let answer = h.call(c.clone());
            if c["op"] == "ipc" {
                assert_eq!(
                    answer["data"]["reply"],
                    json!({"Err":"a native resize of window 1 is still pending"}),
                    "{answer}"
                );
            } else {
                assert_eq!(answer["ok"], false, "{c}: {answer}");
            }
            assert_eq!(h.snap(), before, "{c}");
        }
    };
    refused(&mut h);
    h.ok(reply(&t, "observed", false, true, 200., 150.));
    assert_eq!(h.snap()["native_resize"]["phase"], "dragging");
    refused(&mut h);
    let last = finish(&mut h, &t, false);
    h.ok(reply(&last, "observed", false, true, 200., 150.));
    h.ok(others[3].clone());
}

// Pinned sizes follow output-local pointer motion, never the canvas zoom.
#[test]
fn pinned_resize_tracks_all_edges_across_camera_changes_and_native_clamps() {
    for zoom in [0.2, 0.8, 1.0] {
        for (edges, x, y) in [
            ("top_left", 100., 100.),
            ("top", 200., 100.),
            ("top_right", 300., 100.),
            ("right", 300., 175.),
            ("bottom_right", 300., 250.),
            ("bottom", 200., 250.),
            ("bottom_left", 100., 250.),
            ("left", 100., 175.),
        ] {
            let mut h = readback();
            h.ok(json!({"op":"focus","window":1}));
            h.ok(json!({"op":"action","output":1,"action":"toggle-pin-to-screen"}));
            h.ok(json!({"op":"register_output","stable_id":"one","screen_bounds":rect(37.,53.,1000.,800.)}));
            h.ok(json!({"op":"zoom","output":1,"zoom":zoom,"anchor":{"x":37.,"y":53.}}));
            let read = grab(&mut h, (37. + x, 53. + y), true);
            assert_eq!(h.snap()["native_resize"]["edges"], edges);
            assert_eq!(h.snap()["native_resize"]["screen_space"], true);
            assert_eq!(h.snap()["native_resize"]["group"], false);
            h.ok(reply(&read, "observed", false, true, 200., 150.));
            // The viewport can move while another device holds the edge.
            h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":83.,"y":29.}}));
            h.ok(json!({"op":"zoom","output":1,"zoom":0.4,"anchor":{"x":37.,"y":53.}}));
            let left = edges.contains("left");
            let right = edges.contains("right");
            let top = edges.contains("top");
            let bottom = edges.contains("bottom");
            let dx = if left {
                -30.
            } else if right {
                30.
            } else {
                0.
            };
            let dy = if top {
                -20.
            } else if bottom {
                20.
            } else {
                0.
            };
            let set = to(&mut h, &read, 37. + x + dx, 53. + y + dy);
            let (w, ht) = (200. + dx.abs(), 150. + dy.abs());
            assert_eq!(set["requested"], size(w, ht), "{edges} zoom={zoom}");
            // A native size limit moves only the grabbed edge by the observed amount.
            let (w, ht) = (
                if dx != 0. { w - 4. } else { w },
                if dy != 0. { ht - 3. } else { ht },
            );
            h.ok(reply(&set, "clamped", true, true, w, ht));
            let pinned = h.snap()["windows"][0]["pinned"]["screen_rect"].clone();
            assert_eq!(
                pinned,
                rect(
                    137. - if left { w - 200. } else { 0. },
                    153. - if top { ht - 150. } else { 0. },
                    w,
                    ht
                )
            );
            let end = finish(&mut h, &read, false);
            h.ok(reply(&end, "observed", false, true, w, ht));
        }
    }
}

#[test]
fn pinned_resize_rebases_a_delayed_baseline_and_refuses_other_outputs() {
    let mut h = readback();
    h.ok(json!({"op":"focus","window":1}));
    h.ok(json!({"op":"action","output":1,"action":"toggle-pin-to-screen"}));
    h.ok(
        json!({"op":"register_output","stable_id":"two","screen_bounds":rect(1000.,0.,1000.,800.)}),
    );
    h.rejects(json!({"op":"begin_native_resize","window":1,"output":2,"start_screen":{"x":1200.,"y":200.}}));
    let read = grab(&mut h, (298., 248.), false);
    assert!(to(&mut h, &read, 328., 268.).is_null());
    let set = h.ok(reply(&read, "observed", false, true, 260., 190.))["effect"].clone();
    assert_eq!(set["requested"], size(230., 170.));
    h.ok(reply(&set, "applied", true, true, 230., 170.));
    assert_eq!(
        h.snap()["windows"][0]["pinned"]["screen_rect"],
        rect(100., 100., 230., 170.)
    );
    let end = finish(&mut h, &read, false);
    h.ok(reply(&end, "observed", false, true, 230., 170.));
}

#[test]
fn pinned_resize_fractional_readbacks_anchor_to_the_adopted_baseline() {
    for (width, height) in [(200.0, 150.0), (260.6, 190.4)] {
        let mut h = readback();
        h.ok(json!({"op":"focus","window":1}));
        h.ok(json!({"op":"action","output":1,"action":"toggle-pin-to-screen"}));
        h.ok(json!({"op":"zoom","output":1,"zoom":0.4,"anchor":{"x":0.,"y":0.}}));
        let read = grab(&mut h, (101., 101.), false);
        // Queue top-left motion before a baseline that may differ from the
        // displayed size. Adoption retains the pin's original top-left.
        assert!(to(&mut h, &read, 99., 99.).is_null());
        let mut set = h.ok(reply(&read, "observed", false, true, width, height))["effect"].clone();
        assert_eq!(set["requested"], size(width + 2., height + 2.));
        for (index, offset) in [0.6, 1.2, 1.8, 2.4, 3.0, 0.0].into_iter().enumerate() {
            let (actual_width, actual_height) = (width + offset, height + offset);
            h.ok(reply(
                &set,
                "clamped",
                true,
                true,
                actual_width,
                actual_height,
            ));
            let pinned = h.snap()["windows"][0]["pinned"]["screen_rect"].clone();
            let position = (100.0_f64 - offset).round();
            assert_eq!(
                pinned,
                rect(position, position, actual_width, actual_height)
            );
            // Integer pin positions allow at most half a point of rounding;
            // fractional native observations cannot compound that error.
            assert!((position + actual_width - (100. + width)).abs() <= 0.5);
            assert!((position + actual_height - (100. + height)).abs() <= 0.5);
            if index < 5 {
                let at = 101. - 2. * (index + 2) as f64;
                set = to(&mut h, &read, at, at);
                assert!(!set.is_null());
            }
        }
        let end = finish(&mut h, &read, false);
        h.ok(reply(&end, "observed", false, true, width, height));
        assert_eq!(
            h.snap()["windows"][0]["pinned"]["screen_rect"],
            rect(100., 100., width, height)
        );
    }
}

#[test]
fn pinned_resize_final_readback_preserves_an_independent_drag() {
    let mut h = readback();
    h.ok(json!({"op":"focus","window":1}));
    h.ok(json!({"op":"action","output":1,"action":"toggle-pin-to-screen"}));
    let read = grab(&mut h, (101., 101.), false);
    h.ok(reply(&read, "observed", false, true, 260.6, 190.4));
    let set = to(&mut h, &read, 96., 96.);
    h.ok(reply(&set, "clamped", true, true, 261.2, 191.0));
    let end = finish(&mut h, &read, false);
    assert_eq!(end["op"], "observe_resize_source");
    // Pointer transactions allow a new move after release while their final
    // observation is outstanding. This move must survive the late resize.
    h.ok(json!({"op":"begin_drag","window":1,"output":1,"group":false}));
    h.ok(json!({"op":"gesture_to","screen_delta":{"x":20.,"y":10.},"pointer":{"x":121.,"y":111.}}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(
        h.snap()["windows"][0]["pinned"]["screen_rect"],
        rect(119., 109., 261.2, 191.0)
    );
    h.ok(reply(&end, "observed", false, true, 262.4, 192.2));
    assert_eq!(
        h.snap()["windows"][0]["pinned"]["screen_rect"],
        rect(118., 108., 262.4, 192.2)
    );
    assert_eq!(h.snap()["native_resize"]["phase"], "complete");
}
