// SPDX-License-Identifier: GPL-3.0-or-later
//! IPC and action scenarios cross the exported C ABI and JSON decoder with
//! upstream-shaped requests, and the `msg` client is driven through its exported
//! symbol against a throwaway listener. They provide no native rendering,
//! capture, focus or input-delivery evidence, and never touch a real socket.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::{CString, c_char};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

#[path = "support/host.rs"]
mod host;
use host::Host;

impl Host {
    /// One upstream request with `output` active. Never a controller error.
    fn ipc_on(&mut self, output: Value, request: Value) -> Value {
        self.ok(json!({"op":"ipc","output":output,"request":request}))
    }
    fn ipc(&mut self, request: Value) -> Value {
        self.ipc_on(json!(1), request)
    }
    /// The `Ok` payload of a request that needs nothing from the shell.
    fn read(&mut self, request: Value) -> Value {
        let data = self.ipc(request);
        assert_eq!(data["effects"], json!([]), "{data}");
        assert_eq!(data["dirty"], false, "{data}");
        assert_eq!(data["navigation"], Value::Null, "{data}");
        assert!(data["reply"].get("Ok").is_some(), "{data}");
        data["reply"]["Ok"].clone()
    }
    /// A refused request: an `Err` reply, nothing for the shell, state untouched.
    fn refused(&mut self, output: Value, request: Value) -> String {
        let before = self.snapshot();
        let data = self.ipc_on(output, request.clone());
        assert_eq!(
            data,
            json!({"reply":{"Err":data["reply"]["Err"]},"effects":[],"dirty":false,"navigation":null}),
            "{request}"
        );
        assert_eq!(self.snapshot(), before, "{request}");
        data["reply"]["Err"]
            .as_str()
            .expect("an Err reply")
            .to_owned()
    }
    fn action_on(&mut self, output: Value, action: &str) -> Value {
        self.call(json!({"op":"action","output":output,"action":action}))
    }
    fn action(&mut self, action: &str) -> Value {
        let response = self.action_on(json!(1), action);
        assert_eq!(response["ok"], true, "{action}: {response}");
        response["data"].clone()
    }
}
/// Output 1's usable center in output-local points. The whole output's center
/// is (500, 400): the two conventions disagree by 10 points of height.
const CENTER: (f64, f64) = (500.0, 410.0);
/// The fixture's box is 2301 x 2901 and output 1's usable area 960 x 740, so the
/// 80 px padding leaves 580 px on the limiting axis.
const FIT: f64 = 580.0 / 2901.0;

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid})
}
fn register(h: &mut Host) {
    // Neither output starts at the global origin, and output 1's usable area is
    // asymmetric, so a global point or the wrong center would miss every target.
    for (id, bounds) in [
        ("view-a", rect(100.0, 50.0, 1000.0, 800.0)),
        ("view-b", rect(1200.0, 50.0, 800.0, 600.0)),
    ] {
        h.ok(json!({"op":"register_output","stable_id":id,"screen_bounds":bounds}));
    }
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(20.0,40.0,960.0,740.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
}
fn setup() -> Host {
    let mut h = Host::new();
    register(&mut h);
    // Window 1 becomes a detached placeholder that shares window 3's bundle id
    // and precedes it in stage order. The observed native rectangle is unrelated.
    for (wid, bundle, title, world) in [
        (
            1,
            "com.example.Terminal",
            "Stand-in",
            rect(0.0, 0.0, 300.0, 200.0),
        ),
        (
            2,
            "com.example.Editor",
            "Editor",
            rect(-1000.0, -2000.0, 600.0, 400.0),
        ),
        (
            3,
            "com.example.Terminal",
            "Shell",
            rect(700.0, 500.0, 601.0, 401.0),
        ),
    ] {
        h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":bundle,"title":title,"buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"world_rect":world}));
    }
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(1),"keep_placeholder":true}));
    // Output 1 rests at camera (300, 200), zoom 0.5: exactly representable.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":100.0,"y":50.0}}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":150.0,"y":100.0}}));
    h
}
fn pose(h: &mut Host, output: usize) -> Value {
    h.snapshot()["outputs"][output - 1].clone()
}
fn num(value: &Value) -> f64 {
    value.as_f64().unwrap()
}
fn close(actual: &Value, expected: f64) {
    assert!(
        (num(actual) - expected).abs() < 1e-9,
        "{actual} != {expected}"
    );
}
/// World point under output 1's usable center.
fn centered(h: &mut Host) -> (f64, f64) {
    let pose = pose(h, 1);
    let zoom = num(&pose["zoom"]);
    (
        num(&pose["camera"]["x"]) + CENTER.0 / zoom,
        num(&pose["camera"]["y"]) + CENTER.1 / zoom,
    )
}
fn settle(h: &mut Host, clock: &mut u64) {
    for _ in 0..600 {
        *clock += 16_666_667;
        let tick = h.ok(json!({"op":"tick_navigation","timestamp_ns":*clock}));
        assert!(
            !tick["changed_outputs"]
                .as_array()
                .unwrap()
                .contains(&json!(2)),
            "{tick}"
        );
        if tick["needs_frames"] == false {
            return;
        }
    }
    panic!("flight did not settle");
}
/// Fly an armed flight on output 1 to rest on its armed destination.
fn land(h: &mut Host, clock: &mut u64, armed: &Value) {
    assert_eq!(armed["animating"], true, "{armed}");
    assert_eq!(armed["output"], 1);
    settle(h, clock);
    let rest = pose(h, 1);
    assert_eq!(rest["camera"], armed["target_camera"]);
    assert_eq!(rest["zoom"], armed["target_zoom"]);
}
fn clock(h: &mut Host) -> u64 {
    let clock = 1_000_000_000;
    h.ok(json!({"op":"tick_navigation","timestamp_ns":clock}));
    clock
}

#[test]
fn state_camera_and_zoom_speak_center_y_up_over_the_whole_output() {
    let mut h = setup();
    let mut clock = clock(&mut h);
    let other = pose(&mut h, 2);

    // Camera (300, 200) at zoom 0.5 on a 1000 x 800 output: the viewport center
    // is (300 + 1000, -(200 + 800)). The usable center would read y = -1020.
    let state = h.read(json!("State"))["State"].clone();
    let keys: Vec<_> = state.as_object().unwrap().keys().cloned().collect();
    let mut expected = [
        "camera",
        "zoom",
        "layout",
        "layout_short",
        "windows",
        "fullscreen",
        "pinned",
        "layers",
        "canvas_layers",
        "outputs",
        "active_bookmark",
    ];
    expected.sort_unstable();
    assert_eq!(keys, expected);
    assert_eq!(
        state,
        json!({
            "camera":[1300.0,-1000.0],"zoom":0.5,"layout":"","layout_short":"",
            "windows":[
                {"id":1,"app_id":"com.example.Terminal","title":"Stand-in","position":[150,-100],"size":[300,200],"is_focused":false,"is_widget":false,"suspended":true,"mode":"Normal"},
                {"id":2,"app_id":"com.example.Editor","title":"Editor","position":[-700,1800],"size":[600,400],"is_focused":false,"is_widget":false,"suspended":false,"mode":"Normal","pid":123},
                {"id":3,"app_id":"com.example.Terminal","title":"Shell","position":[1000,-700],"size":[601,401],"is_focused":false,"is_widget":false,"suspended":false,"mode":"Normal","pid":123}
            ],
            "fullscreen":[],"pinned":[],"layers":[],"canvas_layers":[],
            "outputs":[
                {"name":"view-a","camera":[1300.0,-1000.0],"zoom":0.5,"size":[1000,800],"active":true,"active_bookmark":null},
                {"name":"view-b","camera":[400.0,-300.0],"zoom":1.0,"size":[800,600],"active":false,"active_bookmark":null}
            ],
            "active_bookmark":null
        })
    );
    // The active output is the request's, and with none the top-level pose has
    // nothing to describe.
    let second = h.ipc_on(json!(2), json!("State"))["reply"]["Ok"]["State"].clone();
    assert_eq!(second["camera"], json!([400.0, -300.0]));
    assert_eq!(second["outputs"][0]["active"], false);
    assert_eq!(second["outputs"][1]["active"], true);
    let none = h.ipc_on(Value::Null, json!("State"))["reply"]["Ok"]["State"].clone();
    assert_eq!(none["camera"], json!([0.0, 0.0]));
    assert_eq!(none["zoom"], 1.0);
    assert_eq!(none["windows"], state["windows"]);
    assert!(
        none["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .all(|o| o["active"] == false)
    );

    assert_eq!(
        h.read(json!({"Camera":null})),
        json!({"Camera":{"x":1300.0,"y":-1000.0}})
    );
    // Write: the reply echoes the request and the flight lands the viewport
    // center on it. Integers decode as upstream's f64 pair.
    let data = h.ipc(json!({"Camera":[500,300]}));
    assert_eq!(
        data["reply"],
        json!({"Ok":{"Camera":{"x":500.0,"y":300.0}}})
    );
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], false);
    assert_eq!(
        data["navigation"]["target_camera"],
        json!({"x":-500.0,"y":-1100.0})
    );
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    // Nothing moved yet: the write only armed a flight.
    assert_eq!(
        h.read(json!({"Camera":null})),
        json!({"Camera":{"x":1300.0,"y":-1000.0}})
    );
    land(&mut h, &mut clock, &data["navigation"]);
    assert_eq!(
        h.read(json!({"Camera":null})),
        json!({"Camera":{"x":500.0,"y":300.0}})
    );

    // Zoom anchors the world point under the usable center, like keyboard zoom.
    assert_eq!(h.read(json!({"Zoom":null})), json!({"Zoom":0.5}));
    let fixed = centered(&mut h);
    assert_eq!(fixed, (500.0, -280.0));
    let data = h.ipc(json!({"Zoom":0.8}));
    assert_eq!(data["reply"], json!({"Ok":{"Zoom":0.8}}));
    assert_eq!(data["dirty"], false);
    land(&mut h, &mut clock, &data["navigation"]);
    assert_eq!(h.read(json!({"Zoom":null})), json!({"Zoom":0.8}));
    let now = centered(&mut h);
    assert!(
        (now.0 - fixed.0).abs() < 1e-9 && (now.1 - fixed.1).abs() < 1e-9,
        "{now:?}"
    );
    // Clamped in to native size and out to half the fit zoom; the reply reports
    // what was applied.
    let data = h.ipc(json!({"Zoom":5}));
    assert_eq!(data["reply"], json!({"Ok":{"Zoom":1.0}}));
    land(&mut h, &mut clock, &data["navigation"]);
    let data = h.ipc(json!({"Zoom":0.0001}));
    close(&data["reply"]["Ok"]["Zoom"], FIT / 2.0);
    land(&mut h, &mut clock, &data["navigation"]);
    close(&h.read(json!({"Zoom":null}))["Zoom"], FIT / 2.0);

    for (request, error) in [
        (json!({"Zoom":0}), "zoom must be a positive number"),
        (json!({"Zoom":-0.5}), "zoom must be a positive number"),
    ] {
        assert_eq!(h.refused(json!(1), request), error);
    }
    for request in [
        json!({"Camera":null}),
        json!({"Camera":[1,2]}),
        json!({"Zoom":null}),
        json!({"Zoom":0.5}),
    ] {
        assert_eq!(h.refused(Value::Null, request.clone()), "no active output");
        assert_eq!(h.refused(json!(99), request), "unknown output");
    }
    assert_eq!(h.refused(json!(99), json!("State")), "unknown output");
    // A drag gesture refuses camera writes as it refuses every view action.
    h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    for request in [json!({"Camera":[0,0]}), json!({"Zoom":0.5})] {
        assert_eq!(
            h.refused(json!(1), request),
            "navigation during active gesture"
        );
    }
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(pose(&mut h, 2), other);

    // A viewport centered on a point whose Y is 0 reads a negative zero, as
    // upstream's own does: its viewport_center negates the Y-down center,
    // -(0.0) is -0.0, and its client prints that as `-0`. Nothing here
    // normalises what upstream does not.
    let data = h.ipc(json!({"Camera":[0,0]}));
    land(&mut h, &mut clock, &data["navigation"]);
    let read = h.read(json!({"Camera":null}))["Camera"].clone();
    let (x, y) = (num(&read["x"]), num(&read["y"]));
    assert!(x == 0.0 && x.is_sign_positive(), "{read}");
    assert!(y == 0.0 && y.is_sign_negative(), "{read}");
    assert_eq!(format!("{x} {y}"), "0 -0");
}

#[test]
fn bookmarks_round_trip_through_actions_ipc_and_the_save_file() {
    let mut h = setup();
    let mut clock = clock(&mut h);
    let start = pose(&mut h, 1);
    assert_eq!(start["camera"], json!({"x":300.0,"y":200.0}));
    assert_eq!(h.read(json!({"Bookmark":{}})), json!({"Bookmarks":{}}));

    // set-bookmark stores the point under the usable center, Y up:
    // (300 + 500 / 0.5, -(200 + 410 / 0.5)). Nothing flies; the shell must save.
    assert_eq!(
        h.action("set-bookmark 1"),
        json!({"navigation":null,"effects":[],"dirty":true})
    );
    assert_eq!(
        h.read(json!({"Bookmark":{"name":"1"}})),
        json!({"Bookmark":{"x":1300.0,"y":-1020.0}})
    );
    assert_eq!(pose(&mut h, 1), start);

    // A missing bookmark is no error and arms nothing: null navigation.
    let before = h.snapshot();
    assert_eq!(
        h.action("go-to-bookmark 2"),
        json!({"navigation":null,"effects":[],"dirty":false})
    );
    assert_eq!(h.snapshot(), before);

    // Away and back: the flight lands exactly where the bookmark was set, with
    // zoom untouched.
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":-333.0,"y":77.0}}));
    let data = h.action("go-to-bookmark 1");
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], false);
    assert_eq!(data["navigation"]["target_camera"], start["camera"]);
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    land(&mut h, &mut clock, &data["navigation"]);
    assert_eq!(pose(&mut h, 1), start);

    // At another zoom the same point lands under the usable center.
    h.ok(json!({"op":"zoom","output":1,"zoom":1.0,"anchor":{"x":100.0,"y":50.0}}));
    let data = h.action("go-to-bookmark 1");
    assert_eq!(
        data["navigation"]["target_camera"],
        json!({"x":800.0,"y":610.0})
    );
    land(&mut h, &mut clock, &data["navigation"]);
    assert_eq!(centered(&mut h), (1300.0, 1020.0));
    assert_eq!(pose(&mut h, 1)["zoom"], 1.0);

    // go-to-bookmark disarms a zoom-to-fit return, so the next fit press fits again.
    let fit = h.action("zoom-to-fit")["navigation"].clone();
    close(&fit["target_zoom"], FIT);
    land(&mut h, &mut clock, &fit);
    assert!(h.snapshot()["navigation"]["overview_returns"]["1"].is_object());
    let data = h.action("go-to-bookmark 1");
    assert_eq!(h.snapshot()["navigation"]["overview_returns"], json!({}));
    land(&mut h, &mut clock, &data["navigation"]);
    let now = centered(&mut h);
    assert!(
        (now.0 - 1300.0).abs() < 1e-9 && (now.1 - 1020.0).abs() < 1e-9,
        "{now:?}"
    );
    close(&pose(&mut h, 1)["zoom"], FIT);

    // set-bookmark captures a pending camera destination, not a mid-flight
    // frame: one pan step right from (300, 200) at zoom 0.5 ends at (500, 200).
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":100.0,"y":50.0}}));
    let back = h.action("go-to-bookmark 1")["navigation"].clone();
    land(&mut h, &mut clock, &back);
    assert_eq!(pose(&mut h, 1), start);
    let pan = h.action("pan-viewport right")["navigation"].clone();
    assert_eq!(pan["target_camera"], json!({"x":500.0,"y":200.0}));
    assert_eq!(h.action("set-bookmark 2")["dirty"], true);
    assert_eq!(pose(&mut h, 1), start);
    assert_eq!(
        h.read(json!({"Bookmark":{"name":"2"}})),
        json!({"Bookmark":{"x":1500.0,"y":-1020.0}})
    );
    land(&mut h, &mut clock, &pan);

    // IPC set / list (sorted by name) / get; a name may hold spaces.
    let data = h.ipc(json!({"Bookmark":{"name":"home","to":[0,0]}}));
    assert_eq!(
        data,
        json!({"reply":{"Ok":{"Bookmark":{"x":0.0,"y":0.0}}},"effects":[],"dirty":true,"navigation":null})
    );
    assert_eq!(h.action("set-bookmark my desk")["dirty"], true);
    let all = json!({"1":[1300.0,-1020.0],"2":[1500.0,-1020.0],"home":[0.0,0.0],"my desk":[1500.0,-1020.0]});
    assert_eq!(
        h.read(json!({"Bookmark":{}})),
        json!({"Bookmarks":all.clone()})
    );
    assert_eq!(h.snapshot()["bookmarks"], all);

    // v0.20: a bookmark jump sent during a zoom flight goes through the anchor
    // at the zoom the view is heading to (src/input/actions.rs
    // go_to_canvas_point), so it is no longer dropped by the flight's tick:
    // the origin lands under the usable center at zoom 1, not the live 0.5.
    let zoom = h.action("zoom-reset")["navigation"].clone();
    assert_eq!(zoom["target_zoom"], 1.0);
    let jump = h.action("go-to-bookmark home")["navigation"].clone();
    assert_eq!(jump["target_camera"], json!({"x":-500.0,"y":-410.0}));
    assert_eq!(jump["target_zoom"], 1.0);
    settle(&mut h, &mut clock);
    assert_eq!(pose(&mut h, 1)["camera"], jump["target_camera"]);
    // From rest the same jump lands, and the bookmark under the usable center
    // becomes that output's active bookmark. Output 2 still shows the origin.
    let data = h.action("go-to-bookmark home");
    land(&mut h, &mut clock, &data["navigation"]);
    assert_eq!(centered(&mut h), (0.0, 0.0));
    let state = h.read(json!("State"))["State"].clone();
    assert_eq!(state["active_bookmark"], "home");
    assert_eq!(state["outputs"][0]["active_bookmark"], "home");
    assert_eq!(state["outputs"][1]["active_bookmark"], "home");
    assert_eq!(
        h.snapshot()["navigation"]["active_bookmarks"],
        json!({"1":"home","2":"home"})
    );

    // Delete, and every refused form.
    let data = h.ipc(json!({"Bookmark":{"name":"2","delete":true}}));
    assert_eq!(
        data,
        json!({"reply":{"Ok":"Ok"},"effects":[],"dirty":true,"navigation":null})
    );
    for (request, error) in [
        (
            json!({"Bookmark":{"name":"2","delete":true}}),
            "no bookmark named '2'",
        ),
        (
            json!({"Bookmark":{"delete":true}}),
            "bookmark delete requires a name",
        ),
        (
            json!({"Bookmark":{"name":"1","to":[1,2],"delete":true}}),
            "bookmark delete does not take coordinates",
        ),
        (
            json!({"Bookmark":{"to":[1,2]}}),
            "bookmark coordinates require a name",
        ),
        (json!({"Bookmark":{"name":"2"}}), "no bookmark named '2'"),
    ] {
        // Bookmarks need no active output.
        assert_eq!(h.refused(Value::Null, request), error);
    }
    let kept = json!({"1":[1300.0,-1020.0],"home":[0.0,0.0],"my desk":[1500.0,-1020.0]});

    // Saved under schema 1, and restored by load.
    let path = std::env::temp_dir().join(format!("driftwm-ipc-flow-{}.json", std::process::id()));
    h.ok(json!({"op":"save","path":path}));
    let mut saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(saved["version"], 1);
    assert_eq!(saved["bookmarks"], kept);
    h.ok(json!({"op":"load","path":path}));
    assert_eq!(
        h.ipc_on(Value::Null, json!({"Bookmark":{}}))["reply"],
        json!({"Ok":{"Bookmarks":kept.clone()}})
    );
    // Incumbents are ephemeral: nothing is active until an output shows one.
    assert_eq!(h.snapshot()["navigation"]["active_bookmarks"], json!({}));
    register(&mut h);
    assert_eq!(
        h.read(json!("State"))["State"]["active_bookmark"],
        "home",
        "the restored camera still shows the origin"
    );

    // A file written before bookmarks existed has no such key and still loads.
    saved.as_object_mut().unwrap().remove("bookmarks").unwrap();
    std::fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
    h.ok(json!({"op":"load","path":path}));
    assert_eq!(
        h.ipc_on(Value::Null, json!({"Bookmark":{}}))["reply"],
        json!({"Ok":{"Bookmarks":{}}})
    );
    assert_eq!(h.snapshot()["windows"].as_array().unwrap().len(), 3);
    // With none to save the key is omitted, so such a file reads the same.
    h.ok(json!({"op":"save","path":path}));
    let empty: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert!(empty.get("bookmarks").is_none());
    std::fs::remove_file(path).unwrap();
}

#[test]
fn move_raises_a_live_window_without_changing_focus_or_cameras() {
    let mut h = setup();
    h.ipc(json!({"Focus":3}));
    let before = h.snapshot();
    let hit = |h: &mut Host| {
        h.ok(json!({"op":"hit","output":1,"screen":{"x":450.0,"y":300.0}}))["hit"]["window"].clone()
    };
    assert_eq!(hit(&mut h), 3);

    // Moving an off-screen client over the focused one raises it without
    // handing it focus. Repeating the same position after a focus raise must
    // raise it again even though its geometry no longer changes.
    for _ in 0..2 {
        h.ipc(json!({"Focus":3}));
        let focused = h.snapshot()["focus"].clone();
        assert_eq!(
            h.ipc_on(Value::Null, json!({"Move":{"window":2,"to":[1000,-700]}})),
            json!({"reply":{"Ok":{"Position":{"x":1000,"y":-700}}},"effects":[],"dirty":true,"navigation":null})
        );
        let snapshot = h.snapshot();
        let order: Vec<_> = snapshot["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w["window"].as_u64().unwrap())
            .collect();
        assert_eq!(order, [1, 3, 2]);
        assert_eq!(hit(&mut h), 2);
        assert_eq!(snapshot["focus"], focused);
        assert_eq!(snapshot["outputs"], before["outputs"]);
        for window in snapshot["windows"].as_array().unwrap() {
            let original = before["windows"]
                .as_array()
                .unwrap()
                .iter()
                .find(|w| w["window"] == window["window"])
                .unwrap();
            assert_eq!(window["source"], original["source"]);
        }
        let after = h.snapshot();
        assert_eq!(
            h.read(json!({"Move":{"window":3}})),
            json!({"Position":{"x":1000,"y":-700}})
        );
        assert_eq!(h.snapshot(), after, "a position read never raises");
    }
}

#[test]
fn move_preserves_a_detached_placeholders_stacking() {
    let mut h = setup();
    let before = h.snapshot();
    assert_eq!(
        h.ipc_on(Value::Null, json!({"Move":{"window":1,"to":[1000,-700]}})),
        json!({"reply":{"Ok":{"Position":{"x":1000,"y":-700}}},"effects":[],"dirty":true,"navigation":null})
    );
    let after = h.snapshot();
    assert_eq!(after["windows"][0]["window"], 1);
    assert_eq!(
        after["windows"][0]["world_rect"],
        rect(850.0, 600.0, 300.0, 200.0)
    );
    assert_eq!(
        after["windows"].as_array().unwrap()[1..],
        before["windows"].as_array().unwrap()[1..]
    );
    assert_eq!(after["focus"], before["focus"]);
    assert_eq!(after["outputs"], before["outputs"]);
    assert_eq!(
        h.ok(json!({"op":"hit","output":1,"screen":{"x":450.0,"y":300.0}}))["hit"]["window"],
        3
    );
}

#[test]
fn move_resize_and_focus_address_logical_windows() {
    let mut h = setup();
    let world = |h: &mut Host, window: u64| {
        h.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == window)
            .unwrap()["world_rect"]
            .clone()
    };

    // Nothing is focused, so the selector-less forms have no target.
    assert_eq!(h.read(json!({"Focus":null})), json!({"Focused":null}));
    for request in [json!({"Move":{}}), json!({"Resize":{}})] {
        assert_eq!(h.refused(json!(1), request), "no focused window");
    }
    // Read: the frame's center, Y up. 601 x 401 halves to 300 and 200.
    assert_eq!(
        h.read(json!({"Move":{"window":2}})),
        json!({"Position":{"x":-700,"y":1800}})
    );
    assert_eq!(
        h.read(json!({"Move":{"window":3}})),
        json!({"Position":{"x":1000,"y":-700}})
    );
    assert_eq!(
        h.read(json!({"Resize":{"window":3}})),
        json!({"Size":{"width":601,"height":401}})
    );
    // Write: a logical world move the shell must save. No output is needed.
    for (window, to, origin, size) in [
        (2, [100, -50], (-200.0, -150.0), (600.0, 400.0)),
        (3, [0, 0], (-300.0, -200.0), (601.0, 401.0)),
        (1, [-7, 9], (-157.0, -109.0), (300.0, 200.0)),
    ] {
        let data = h.ipc_on(Value::Null, json!({"Move":{"window":window,"to":to}}));
        assert_eq!(
            data,
            json!({"reply":{"Ok":{"Position":{"x":to[0],"y":to[1]}}},"effects":[],"dirty":true,"navigation":null})
        );
        assert_eq!(
            world(&mut h, window),
            rect(origin.0, origin.1, size.0, size.1)
        );
        assert_eq!(
            h.read(json!({"Move":{"window":window}})),
            json!({"Position":{"x":to[0],"y":to[1]}})
        );
    }
    // Bound windows 2 then 3 were raised; the placeholder kept its order.
    // Moving never transfers focus.
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["intent"], Value::Null);
    assert!(!snapshot.as_object().unwrap().contains_key("focused"));
    let order: Vec<_> = snapshot["windows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["window"].clone())
        .collect();
    assert_eq!(order, [json!(1), json!(2), json!(3)]);
    h.ipc(json!({"Move":{"window":2,"to":[-700,1800]}}));
    h.ipc(json!({"Move":{"window":3,"to":[1000,-700]}}));
    // v0.21.0 bounds a requested position at +-1,050,000,000 (upstream's
    // check_point, before the selector is even resolved), so the i32 edge a
    // request could once reach is out of range: nothing lands past the limit.
    for to in [
        [-2147483648i64, 0],
        [2147483647, 0],
        [0, 2147483647],
        [0, -2147483648],
        [1_050_000_001, 0],
        [0, -1_050_000_001],
    ] {
        assert_eq!(
            h.refused(Value::Null, json!({"Move":{"window":1,"to":to}})),
            "coordinates must be within ±1050000000"
        );
    }
    // The limit itself is a position, and the frame still reads back.
    let edge = json!({"Position":{"x":1050000000,"y":0}});
    assert_eq!(
        h.ipc(json!({"Move":{"window":1,"to":[1050000000,0]}}))["reply"]["Ok"],
        edge
    );
    assert_eq!(h.read(json!({"Move":{"window":1}})), edge);
    h.ipc(json!({"Move":{"window":1,"to":[-7,9]}}));

    // A gesture owns the rectangles it drags: every move is refused meanwhile.
    h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    for window in [2, 3] {
        assert_eq!(
            h.refused(json!(1), json!({"Move":{"window":window,"to":[5,5]}})),
            "a window is under an interactive move or resize"
        );
    }
    assert_eq!(
        h.read(json!({"Move":{"window":3}})),
        json!({"Position":{"x":1000,"y":-700}})
    );
    h.ok(json!({"op":"end_gesture"}));
    // Native layout resize is not there yet, and says so.
    assert_eq!(
        h.refused(json!(1), json!({"Resize":{"window":3,"to":[800,600]}})),
        "resize is not implemented on macOS yet: native layout resize is not available"
    );
    assert_eq!(
        h.refused(json!(1), json!({"Resize":{"window":3,"to":[0,600]}})),
        "size must be positive"
    );

    // An app id is a case-insensitive bundle-id substring, and the bound source
    // wins over the placeholder that precedes it in stage order. Window 3 is
    // fully inside output 1's usable area, so it is focused without a flight.
    let data = h.ipc(json!({"Focus":"TERMINAL"}));
    assert_eq!(
        data["reply"],
        json!({"Ok":{"Focused":{"id":3,"app_id":"com.example.Terminal"}}})
    );
    assert_eq!(data["navigation"], Value::Null);
    assert_eq!(data["dirty"], true);
    let effects = data["effects"].as_array().unwrap();
    assert_eq!(effects.len(), 1);
    assert_eq!(effects[0]["op"], "focus_native_window");
    assert_eq!(effects[0]["window"], 3);
    assert_eq!(effects[0]["identity"]["wid"], 3);
    let focus = h.snapshot()["focus"].clone();
    assert_eq!(focus["intent"], 3);
    assert_eq!(focus["pending_effect"], effects[0]);
    // The effect is a request: no native focus is claimed.
    assert_eq!(focus["observed_native"], Value::Null);
    assert_eq!(
        h.read(json!({"Focus":null})),
        json!({"Focused":{"id":3,"app_id":"com.example.Terminal"}})
    );
    assert_eq!(
        h.read(json!({"Move":{}})),
        json!({"Position":{"x":1000,"y":-700}})
    );
    // The focused window leads the inventory; the rest keep stage order.
    let windows = h.read(json!("State"))["State"]["windows"].clone();
    let ids: Vec<_> = windows
        .as_array()
        .unwrap()
        .iter()
        .map(|w| (w["id"].clone(), w["is_focused"].clone()))
        .collect();
    assert_eq!(
        ids,
        [
            (json!(3), json!(true)),
            (json!(1), json!(false)),
            (json!(2), json!(false))
        ]
    );

    // Window 2 is off screen: focusing it also flies there at zoom 1, its
    // center (-700, -1800) under the usable center.
    let data = h.ipc(json!({"Focus":2}));
    assert_eq!(
        data["reply"],
        json!({"Ok":{"Focused":{"id":2,"app_id":"com.example.Editor"}}})
    );
    assert_eq!(
        data["navigation"]["target_camera"],
        json!({"x":-1200.0,"y":-2210.0})
    );
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(data["effects"][0]["window"], 2);
    assert!(num(&data["effects"][0]["effect_id"]) > num(&effects[0]["effect_id"]));
    // A placeholder has no source to focus natively: logical focus only.
    let data = h.ipc(json!({"Focus":1}));
    assert_eq!(
        data["reply"],
        json!({"Ok":{"Focused":{"id":1,"app_id":"com.example.Terminal"}}})
    );
    assert_eq!(data["effects"], json!([]));
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
    // Upstream reveal_element on a stand-in (v0.20; reveal_suspended before):
    // an off-screen stand-in is panned to at the zoom the view is heading to,
    // here 1 from the focus of window 2 above, not the live 0.5, its center
    // (-7, -9) under the usable center.
    assert_eq!(pose(&mut h, 1)["zoom"], 0.5);
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(
        data["navigation"]["target_camera"],
        json!({"x":-507.0,"y":-419.0})
    );
    // With the bound source gone the same selector reaches the placeholder.
    h.ok(json!({"op":"remove_source","window":3,"identity":identity(3),"keep_placeholder":false}));
    assert_eq!(
        h.ipc(json!({"Focus":"terminal"}))["reply"]["Ok"]["Focused"]["id"],
        1
    );

    // Reading the focus or a size needs no active output either.
    assert_eq!(
        h.ipc_on(Value::Null, json!({"Focus":null}))["reply"]["Ok"]["Focused"]["id"],
        1
    );
    assert_eq!(
        h.ipc_on(Value::Null, json!({"Resize":{"window":2}}))["reply"],
        json!({"Ok":{"Size":{"width":600,"height":400}}})
    );
    for (output, request, error) in [
        (
            json!(1),
            json!({"Focus":"nope"}),
            "no window matching 'nope'",
        ),
        (json!(1), json!({"Focus":99}), "no window with id 99"),
        (
            json!(1),
            json!({"Move":{"window":99}}),
            "no window with id 99",
        ),
        (Value::Null, json!({"Focus":2}), "no active output"),
        (json!(99), json!({"Focus":2}), "unknown output"),
    ] {
        assert_eq!(h.refused(output, request), error);
    }
}

/// One refusal per line: an upstream request | its `Err` reply.
const REFUSED: &str = r#"
{"Screenshot":{"target":"Viewport","scale":1.0,"path":"shot.png"}} | screenshot path must be absolute
{"Screenshot":{"target":{"Window":{"window":99}},"scale":2.0,"path":"/nonexistent/shot.png"}} | no window with id 99
{"Action":"frobnicate"} | unknown action: frobnicate
{"Action":"fill-window"} | action not implemented on macOS yet: fill-window
{"Action":"pan-viewport"} | pan-viewport requires a direction
"#;

#[test]
fn refused_unknown_and_unimplemented_requests_answer_err_and_change_nothing() {
    let mut h = setup();
    h.action("set-bookmark here");
    h.ipc(json!({"Focus":3}));
    for line in REFUSED.lines().filter(|line| !line.is_empty()) {
        let (request, error) = line.split_once(" | ").unwrap();
        let request: Value = serde_json::from_str(request).unwrap();
        assert_eq!(h.refused(json!(1), request), error);
    }
    // Anything that is not an upstream request is refused as one, never as a
    // controller error.
    for request in [
        json!({"Bogus":1}),
        json!("Nonsense"),
        json!(42),
        Value::Null,
        json!({}),
        json!({"Camera":"left"}),
        json!({"Camera":[1]}),
        json!({"Move":{"to":[1.5,2]}}),
        json!({"Move":{"window":1,"to":[100.0,200.0]}}),
        json!({"Focus":-3}),
        json!({"Layout":{}}),
        json!({"State":null,"Camera":null}),
    ] {
        let error = h.refused(json!(1), request.clone());
        assert!(error.starts_with("invalid request: "), "{request}: {error}");
    }
    // The command itself is still checked by the controller.
    let before = h.snapshot();
    for command in [
        json!({"op":"ipc","output":1}),
        json!({"op":"ipc","output":"one","request":"State"}),
        json!({"op":"ipc","output":1,"request":"State","extra":0}),
        json!({"op":"action","output":1}),
    ] {
        assert_eq!(h.call(command.clone())["ok"], false, "{command}");
        assert_eq!(h.snapshot(), before);
    }
    // So is a number no f64 holds: the command is parsed whole, request included.
    let response =
        h.raw(br#"{"version":1,"command":{"op":"ipc","output":1,"request":{"Camera":[1e999,0]}}}"#);
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(h.snapshot(), before);

    // Accepted requests carry what the shell must do next to the reply.
    let data = h.ipc(json!({"Action":"zoom-in"}));
    assert_eq!(data["reply"], json!({"Ok":"Ok"}));
    assert_eq!(data["navigation"]["animating"], true);
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], false);
    assert_eq!(
        h.ipc_on(Value::Null, json!({"Action":"quit"})),
        json!({"reply":{"Ok":"Ok"},"effects":[{"op":"quit"}],"dirty":false,"navigation":null})
    );
    assert_eq!(
        h.ipc(json!({"Action":"set-bookmark there"})),
        json!({"reply":{"Ok":"Ok"},"effects":[],"dirty":true,"navigation":null})
    );
    assert_eq!(
        h.ipc(json!({"Action":"go-to-bookmark nowhere"})),
        json!({"reply":{"Ok":"Ok"},"effects":[],"dirty":false,"navigation":null})
    );
    let counters = h.read(json!("DebugCounters"))["DebugCounters"].clone();
    for (key, count) in [
        ("bookmarks", 2),
        ("flights", 1),
        ("outputs", 2),
        ("sources", 2),
        ("windows", 3),
    ] {
        assert_eq!(counters[key], count, "{key}: {counters}");
    }
    assert!(counters.as_object().unwrap().values().all(Value::is_u64));
}

#[test]
fn action_strings_follow_upstream_grammar() {
    let mut h = setup();
    // Implemented: each arms a flight on the given output, or reports the one
    // persisted change. Directions are case-insensitive; names are not.
    for action in [
        "pan-viewport up",
        "pan-viewport DOWN-right",
        "  pan-viewport   up-left  ",
        "home-toggle",
        "zoom-in",
        "zoom-out",
        "zoom-reset",
        "zoom-to-fit",
    ] {
        let data = h.action(action);
        assert_eq!(data["navigation"]["output"], 1, "{action}: {data}");
        assert_eq!(data["effects"], json!([]), "{action}");
        assert_eq!(data["dirty"], false, "{action}");
    }
    // The whole trimmed remainder is a bookmark's name.
    assert_eq!(h.action("set-bookmark  my desk ")["dirty"], true);
    assert_eq!(
        h.ipc(json!({"Bookmark":{"name":"my desk"}}))["reply"]["Ok"]["Bookmark"]
            .as_object()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        h.action("go-to-bookmark my desk")["navigation"]["output"],
        1
    );
    // Quitting is the shell's effect, and needs no output.
    let response = h.action_on(Value::Null, "quit");
    assert_eq!(
        response["data"],
        json!({"navigation":null,"effects":[{"op":"quit"}],"dirty":false})
    );

    // Refusals leave everything as it was.
    let before = h.snapshot();
    let mut refuse = |output: Value, action: &str| {
        let response = h.action_on(output, action);
        assert_eq!(response["ok"], false, "{action}: {response}");
        assert_eq!(h.snapshot(), before, "{action}");
        response["error"].as_str().unwrap().to_owned()
    };
    // Every other name upstream binds parses, and is refused by that name.
    // exec, spawn, exec-terminal, exec-launcher, nudge-window and reload-config
    // run now: tests/config_flow.rs covers them. So do center-window,
    // center-nearest, cycle-windows and focus-center:
    // tests/navigation_actions_flow.rs covers those. So do send-to-output,
    // send-cursor-to-output and switch-layout: tests/platform_actions_flow.rs.
    // close-window and suspend-window run too: tests/lifecycle_flow.rs covers
    // those. toggle-cursor-pan runs too: tests/motion_flow.rs covers it. So
    // does set-trackpad: tests/gesture_flow.rs covers it. tests/rules_flow.rs
    // covers move-to-bookmark, toggle-pin-to-screen and the Opacity and Pin
    // requests, tests/render_flow.rs the Screenshot request. zoom-to-fit-snapped
    // runs too, and the five actions that deliver a size run once the shell
    // says it can: tests/sizes_flow.rs covers those. This shell has not.
    for (name, sample) in [
        ("fill-window", "fill-window"),
        ("fit-window", "fit-window"),
        ("fit-window-snapped", "fit-window-snapped"),
        ("grow-window", "grow-window up"),
        ("shrink-window", "shrink-window up"),
        ("toggle-fullscreen", "toggle-fullscreen"),
    ] {
        let expected = format!("action not implemented on macOS yet: {name}");
        assert_eq!(refuse(json!(1), sample), expected);
        // Known beats the missing output: the answer does not depend on it.
        assert_eq!(refuse(Value::Null, sample), expected);
    }
    // Unknown strings and malformed arguments, in upstream's words.
    for (action, error) in [
        ("frobnicate", "unknown action: frobnicate"),
        ("", "unknown action: "),
        ("Zoom-In", "unknown action: Zoom-In"),
        ("zoom_in", "unknown action: zoom_in"),
        ("zoom", "unknown action: zoom"),
        ("move-window", "unknown action: move-window"),
        ("pan-viewport", "pan-viewport requires a direction"),
        ("pan-viewport north", "unknown direction: north"),
        ("pan-viewport up_left", "unknown direction: up_left"),
        ("nudge-window", "nudge-window requires a direction"),
        ("go-to-bookmark", "go-to-bookmark requires a bookmark name"),
        ("set-bookmark   ", "set-bookmark requires a bookmark name"),
        (
            "move-to-bookmark",
            "move-to-bookmark requires a bookmark name",
        ),
        (
            "cycle-windows",
            "cycle-windows requires forward or backward",
        ),
        (
            "cycle-windows sideways",
            "cycle-windows: expected forward or backward, got 'sideways'",
        ),
        (
            "switch-layout",
            "switch-layout requires next, prev, or a layout index",
        ),
        (
            "switch-layout x",
            "switch-layout: expected next, prev, or an index, got 'x'",
        ),
        ("set-trackpad", "set-trackpad requires on, off, or toggle"),
        (
            "set-trackpad maybe",
            "set-trackpad: expected on, off, or toggle, got 'maybe'",
        ),
        ("exec", "exec requires a command argument"),
        ("spawn", "spawn requires a command argument"),
        (
            "resize-window",
            "resize-window is a drag action for mouse, gesture and touch bindings — on a keybinding use grow-window <dir> or shrink-window <dir>",
        ),
    ] {
        assert_eq!(refuse(json!(1), action), error, "{action:?}");
    }
    // An action that needs an output says so, and names a stale one.
    for action in [
        "pan-viewport up",
        "home-toggle",
        "zoom-in",
        "zoom-out",
        "zoom-reset",
        "zoom-to-fit",
        "go-to-bookmark my desk",
        "set-bookmark x",
        "center-window",
        "center-nearest up",
        "cycle-windows forward",
        "cycle-windows backward",
        "focus-center",
    ] {
        assert_eq!(refuse(Value::Null, action), "no active output", "{action}");
        assert_eq!(refuse(json!(99), action), "unknown output", "{action}");
    }
    assert_eq!(
        refuse(json!(99), "send-cursor-to-output up"),
        "unknown output"
    );
    // Cursor output selection falls back to the first display. It has no
    // neighbour above it, so parsing succeeds without a warp or mutation.
    let before = h.snapshot();
    let response = h.action_on(Value::Null, "send-cursor-to-output up");
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"],
        json!({"effects":[],"dirty":false,"navigation":null})
    );
    assert_eq!(h.snapshot(), before);
    // Flights are refused during a gesture exactly as the direct commands are.
    h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    let response = h.action_on(json!(1), "zoom-in");
    assert_eq!(response["error"], "navigation during active gesture");
    let response = h.action_on(json!(1), "go-to-bookmark my desk");
    assert_eq!(response["error"], "navigation during active gesture");
}

/// A listener on a short throwaway path. Never the default or a live socket.
fn bind() -> (UnixListener, PathBuf) {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let path = std::env::temp_dir().join(format!(
        "ifm-{}-{}.sock",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).unwrap();
    listener.set_nonblocking(true).unwrap();
    (listener, path)
}
/// Answer `count` connections, one request line each, with `reply`'s line.
/// `init` builds the server's state on its own thread.
fn serve<S>(
    listener: UnixListener,
    count: usize,
    init: impl FnOnce() -> S + Send + 'static,
    mut reply: impl FnMut(&mut S, &str) -> String + Send + 'static,
) -> std::thread::JoinHandle<Vec<String>> {
    std::thread::spawn(move || {
        let mut state = init();
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut lines = Vec::new();
        while lines.len() < count && Instant::now() < deadline {
            let Ok((stream, _)) = listener.accept() else {
                std::thread::sleep(Duration::from_millis(2));
                continue;
            };
            stream.set_nonblocking(false).unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            assert!(line.ends_with('\n'), "one request line: {line:?}");
            let line = line.trim_end().to_owned();
            let mut answer = reply(&mut state, &line);
            answer.push('\n');
            reader.get_mut().write_all(answer.as_bytes()).unwrap();
            lines.push(line);
        }
        lines
    })
}
/// The exported client, as the shell's `msg` dispatch calls it.
fn msg(args: &[&str]) -> i32 {
    let owned: Vec<CString> = args.iter().map(|a| CString::new(*a).unwrap()).collect();
    let argv: Vec<*const c_char> = owned.iter().map(|a| a.as_ptr()).collect();
    // SAFETY: argv holds argc live NUL-terminated strings for the whole call.
    unsafe { driftwm_desktop_msg(argv.len() as i32, argv.as_ptr()) }
}

/// One case per line: arguments | the one line that must arrive | the reply
/// line | exit status. Everything after `action` is its spec, flags and negative
/// numbers included. The last two replies are not replies at all.
const EXCHANGES: &str = r#"
state | "State" | {"Ok":{"State":{"camera":[1300.0,-1000.0],"zoom":0.5,"windows":[{"id":3,"app_id":"com.example.Terminal","title":"Shell","position":[1000,-700],"size":[601,401],"is_focused":true,"is_widget":false}],"outputs":[{"name":"view-a","camera":[1300.0,-1000.0],"zoom":0.5,"size":[1000,800],"active":true}]}}} | 0
--json state | "State" | {"Ok":{"State":{"camera":[0.0,0.0],"zoom":1.0,"windows":[]}}} | 0
debug-counters | "DebugCounters" | {"Ok":{"DebugCounters":{"windows":3}}} | 0
camera | {"Camera":null} | {"Ok":{"Camera":{"x":1.5,"y":-2.0}}} | 0
camera -500 300.5 | {"Camera":[-500.0,300.5]} | {"Ok":{"Camera":{"x":-500.0,"y":300.5}}} | 0
zoom | {"Zoom":null} | {"Ok":{"Zoom":0.5}} | 0
zoom 0.5 | {"Zoom":0.5} | {"Ok":{"Zoom":0.5}} | 0
focus | {"Focus":null} | {"Ok":{"Focused":null}} | 0
focus Term | {"Focus":"Term"} | {"Ok":{"Focused":{"id":3,"app_id":"com.example.Terminal"}}} | 0
focus --id 5 | {"Focus":5} | {"Err":"no window with id 5"} | 1
--json focus --id=5 | {"Focus":5} | {"Err":"no window with id 5"} | 1
move | {"Move":{"window":null,"to":null}} | {"Ok":{"Position":{"x":100,"y":200}}} | 0
move -400 200 --id 5 | {"Move":{"window":5,"to":[-400,200]}} | {"Ok":{"Position":{"x":-400,"y":200}}} | 0
resize 800 600 | {"Resize":{"window":null,"to":[800,600]}} | {"Err":"resize is not implemented on macOS yet: native layout resize is not available"} | 1
opacity 0.85 --id 5 | {"Opacity":{"window":5,"value":0.85}} | {"Ok":{"Opacity":0.85}} | 0
pin ON --id 3 | {"Pin":{"window":3,"value":true}} | {"Ok":{"Pin":true}} | 0
pin 0 | {"Pin":{"window":null,"value":false}} | {"Ok":{"Pin":false}} | 0
close firefox | {"Close":"firefox"} | {"Ok":"Ok"} | 0
minimize --id 5 | {"Minimize":5} | {"Ok":"Ok"} | 0
deminimize Term | {"Deminimize":"Term"} | {"Ok":"Ok"} | 0
suspend | {"Suspend":null} | {"Err":"no focused window"} | 1
relaunch --id 9 | {"Relaunch":9} | {"Ok":"Ok"} | 0
bookmark | {"Bookmark":{"name":null,"to":null,"delete":false}} | {"Ok":{"Bookmarks":{"home":[0.0,0.0]}}} | 0
bookmark inbox 500 -300 | {"Bookmark":{"name":"inbox","to":[500.0,-300.0],"delete":false}} | {"Ok":{"Bookmark":{"x":500.0,"y":-300.0}}} | 0
bookmark inbox --delete | {"Bookmark":{"name":"inbox","to":null,"delete":true}} | {"Ok":"Ok"} | 0
layout --short | {"Layout":{"short":true}} | {"Ok":{"Layout":"us"}} | 0
action go-to-bookmark my desk | {"Action":"go-to-bookmark my desk"} | {"Ok":"Ok"} | 0
action exec say --json -1 | {"Action":"exec say --json -1"} | {"Err":"action not implemented on macOS yet: exec"} | 1
screenshot region 1,2 30x40 --from-screen -o /nonexistent/shot.png --scale 2 | {"Screenshot":{"target":{"Region":{"x":1,"y":2,"w":30,"h":40,"from_screen":true}},"scale":2.0,"path":"/nonexistent/shot.png"}} | {"Err":"no output for the screen region"} | 1
screenshot window --id 2 --output=/nonexistent/w.png | {"Screenshot":{"target":{"Window":{"window":2}},"scale":1.0,"path":"/nonexistent/w.png"}} | {"Ok":{"Screenshot":{"path":"/nonexistent/w.png","width":628,"height":428}}} | 0
subscribe | "Subscribe" | {"Err":"cannot subscribe: too many subscribers"} | 1
--json subscribe | "Subscribe" | {"Err":"cannot subscribe: too many subscribers"} | 1
zoom | {"Zoom":null} | not json | 1
zoom | {"Zoom":null} |  | 1
"#;
/// Arguments that never reach a socket, by exit status: 2 is a usage error, 1 a
/// request the client will not send, 0 help.
const UNSENT: &[(&str, i32)] = &[
    ("", 2),
    ("frobnicate", 2),
    ("--bogus state", 2),
    ("state extra", 2),
    ("camera 1 2 3", 2),
    ("zoom abc", 2),
    ("focus term --id 5", 2),
    ("focus --id five", 2),
    ("move --id", 2),
    ("move 1 2 --id 5 --id 6", 2),
    ("resize -5 5", 2),
    ("pin maybe", 2),
    ("bookmark --delete", 2),
    ("bookmark name 5", 2),
    ("bookmark name 5 6 --delete", 2),
    ("layout --long", 2),
    ("action", 2),
    ("screenshot everything", 2),
    ("screenshot all --id 2", 2),
    ("screenshot region", 2),
    ("camera 5", 1),
    ("move 7", 1),
    ("resize 800", 1),
    ("resize 0 600", 1),
    ("opacity nan", 1),
    ("zoom nan", 1),
    ("zoom inf", 1),
    ("camera inf 0", 1),
    ("camera 0 nan", 1),
    ("bookmark name inf 0", 1),
    ("screenshot region 1 2 3", 1),
    ("--help", 0),
    ("state --help", 0),
    ("action --help", 0),
];

#[test]
fn msg_client_sends_upstream_request_lines_and_reports_by_exit_status() {
    let cases: Vec<Vec<&str>> = EXCHANGES
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| line.split(" | ").collect())
        .collect();
    assert!(cases.iter().all(|case| case.len() == 4));
    let (listener, path) = bind();
    let socket = path.to_str().unwrap().to_owned();
    let replies: Vec<String> = cases.iter().map(|case| case[2].to_owned()).collect();
    let server = serve(
        listener,
        cases.len(),
        move || replies.into_iter(),
        |next, _| next.next().unwrap(),
    );
    for (index, case) in cases.iter().enumerate() {
        // The socket option is accepted before the command and after it.
        let mut argv: Vec<&str> = case[0].split_whitespace().collect();
        if index % 2 == 0 || argv[0] == "action" {
            argv.splice(0..0, ["--socket", socket.as_str()]);
        } else {
            argv.extend(["--socket", socket.as_str()]);
        }
        assert_eq!(msg(&argv).to_string(), case[3], "{}", case[0]);
    }
    let lines = server.join().unwrap();
    let expected: Vec<_> = cases.iter().map(|case| case[1]).collect();
    assert_eq!(lines, expected);

    let (listener, path) = bind();
    let socket = path.to_str().unwrap();
    for (args, status) in UNSENT {
        let mut argv = vec!["--socket", socket];
        argv.extend(args.split_whitespace());
        assert_eq!(msg(&argv), *status, "{args:?}");
        assert_eq!(
            listener.accept().err().map(|e| e.kind()),
            Some(std::io::ErrorKind::WouldBlock),
            "{args:?} must not connect"
        );
    }
    drop(listener);
    std::fs::remove_file(&path).unwrap();
    // Nothing listens there any more: a connection failure.
    assert_eq!(msg(&["--socket", socket, "state"]), 1);
    assert_eq!(msg(&["--socket"]), 2);
}

#[test]
fn msg_client_reaches_a_controller_through_the_ipc_command() {
    // The test stands in for the shell: each request line goes through
    // {"op":"ipc"} on a real controller and its reply goes back on the wire.
    let (listener, path) = bind();
    let socket = path.to_str().unwrap().to_owned();
    let (done, finished) = std::sync::mpsc::channel();
    let server = serve(listener, 9, setup, move |h, line| {
        let reply = match serde_json::from_str::<Value>(line) {
            Ok(request) => h.ipc(request)["reply"].clone(),
            Err(_) => json!({"Err":"invalid request"}),
        };
        done.send(h.snapshot()).unwrap();
        reply.to_string()
    });
    let run = |args: &[&str]| {
        let mut argv = vec!["--socket", socket.as_str()];
        argv.extend_from_slice(args);
        let status = msg(&argv);
        (status, finished.recv().unwrap())
    };
    let (status, _) = run(&["bookmark", "home", "10", "-20"]);
    assert_eq!(status, 0);
    let (status, snapshot) = run(&["action", "set-bookmark", "my", "desk"]);
    assert_eq!(status, 0);
    assert_eq!(
        snapshot["bookmarks"],
        json!({"home":[10.0,-20.0],"my desk":[1300.0,-1020.0]})
    );
    assert_eq!(run(&["--json", "bookmark", "home"]).0, 0);
    assert_eq!(run(&["bookmark", "missing"]).0, 1);
    assert_eq!(run(&["--json", "action", "frobnicate"]).0, 1);
    assert_eq!(run(&["action", "toggle-fullscreen"]).0, 1);
    let (status, snapshot) = run(&["move", "-7", "9", "--id", "2"]);
    assert_eq!(status, 0);
    let moved = snapshot["windows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["window"] == 2)
        .unwrap();
    assert_eq!(moved["world_rect"], rect(-307.0, -209.0, 600.0, 400.0));
    assert_eq!(snapshot["windows"].as_array().unwrap().last(), Some(moved));
    let (status, snapshot) = run(&["focus", "editor"]);
    assert_eq!(status, 0);
    assert_eq!(snapshot["focus"]["intent"], 2);
    let (status, snapshot) = run(&["camera", "0", "0"]);
    assert_eq!(status, 0);
    // v0.20: the camera is set through the anchor, at the zoom the view is
    // heading to: the focus above flies to window 2 at zoom 1, so the origin
    // lands under the center at 1, not at the live 0.5.
    assert_eq!(
        snapshot["navigation"]["flights"]["1"]["camera_target"],
        json!({"x":-500.0,"y":-400.0})
    );
    assert_eq!(server.join().unwrap().len(), 9);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn msg_subscribe_streams_the_controllers_event_lines_until_the_server_hangs_up() {
    // The test stands in for the shell: the ack, the snapshot the `subscribe`
    // effect carries, then every line `state_event` hands out, each on a line of
    // its own, and a hang-up, on which upstream's client exits 0.
    let (listener, path) = bind();
    let socket = path.to_str().unwrap().to_owned();
    let (sent, answers) = std::sync::mpsc::channel();
    let server = serve(
        listener,
        2,
        || (setup(), 0),
        move |(h, connection), line| {
            assert_eq!(line, "\"Subscribe\"");
            let data = h.ipc(json!("Subscribe"));
            let mut answer = vec![
                data["reply"].to_string(),
                data["effects"][0]["line"].as_str().unwrap().to_owned(),
            ];
            for step in 0..3 {
                if step == 1 {
                    h.ipc(json!({"Move":{"window":2,"to":[40 + *connection,-60]}}));
                }
                let event = h.ok(json!({"op":"state_event","output":1}))["line"].clone();
                answer.extend(event.as_str().map(str::to_owned));
            }
            *connection += 1;
            sent.send(answer.clone()).unwrap();
            answer.join("\n")
        },
    );
    // The human-readable form decodes every line as upstream's typed event, so
    // exit status 0 says each one was an event upstream's own client accepts.
    assert_eq!(msg(&["--socket", &socket, "subscribe"]), 0);
    assert_eq!(msg(&["--json", "--socket", &socket, "subscribe"]), 0);
    assert_eq!(server.join().unwrap(), ["\"Subscribe\"", "\"Subscribe\""]);
    let answers: Vec<Vec<String>> = answers.try_iter().collect();
    // The first subscriber gets the first broadcast of the run and the move;
    // an unchanged state is never sent again. The second gets its snapshot and
    // then only its own move.
    assert_eq!(answers[0].len(), 4, "{:?}", answers[0]);
    assert_eq!(answers[1].len(), 3, "{:?}", answers[1]);
    for (connection, answer) in answers.iter().enumerate() {
        assert_eq!(answer[0], "{\"Ok\":\"Ok\"}");
        for line in &answer[1..] {
            assert!(line.starts_with("{\"State\":{\"camera\":["), "{line}");
            assert!(!line.contains('\n'));
        }
        let last: Value = serde_json::from_str(answer.last().unwrap()).unwrap();
        let moved = last["State"]["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|window| window["id"] == 2)
            .unwrap();
        assert_eq!(moved["position"], json!([40 + connection, -60]));
    }
    std::fs::remove_file(path).unwrap();

    // A pushed line that is no event stops the human form with an error, while
    // --json relays lines as they come, as upstream's client does.
    let (listener, path) = bind();
    let socket = path.to_str().unwrap().to_owned();
    let server = serve(
        listener,
        2,
        || (),
        |_, _| "{\"Ok\":\"Ok\"}\n{\"State\":{\"camera\":\"here\"}}".to_owned(),
    );
    assert_eq!(msg(&["--socket", &socket, "subscribe"]), 1);
    assert_eq!(msg(&["--json", "--socket", &socket, "subscribe"]), 0);
    assert_eq!(server.join().unwrap().len(), 2);
    std::fs::remove_file(path).unwrap();
}

// DriftWM v0.21.0 additions (df3de27b26c7998e8a460cffd8a4925cbed3a322): the `pid`
// of a window in `state`, `msg cursor`, the bounds on what a request may ask for
// and the private file `screenshot -o -` is relayed through. Same boundary as
// the scenarios above: the exported ABI and the exported `msg` client, no
// native window, no pointer and no real socket of the app.

#[test]
fn state_names_the_process_of_a_bound_window_pinned_and_fullscreen_and_none_for_a_stand_in() {
    let mut h = setup();
    let state = h.read(json!("State"))["State"].clone();
    let by_id = |state: &Value, id: u64| {
        state["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["id"] == id)
            .cloned()
            .unwrap_or_else(|| panic!("no window {id} in {state}"))
    };
    // Window 1 is a stand-in: it has no source, so no process, and the member
    // is left out rather than null, as upstream's `skip_serializing_if` does.
    assert!(by_id(&state, 1).get("pid").is_none(), "{state}");
    assert_eq!(by_id(&state, 2)["pid"], 123);
    assert_eq!(by_id(&state, 3)["pid"], 123);
    // The typed form the `msg` client re-serializes keeps the member last.
    let json = h.read(json!("State"));
    assert!(
        serde_json::to_string(&json)
            .unwrap()
            .contains(r#""mode":"Normal","pid":123"#)
    );

    // A window pinned to the screen moves to `pinned`, still with its process.
    let data = h.ipc(json!({"Pin":{"window":3,"value":true}}));
    assert_eq!(data["reply"], json!({"Ok":{"Pin":true}}));
    let state = h.read(json!("State"))["State"].clone();
    assert_eq!(state["pinned"][0]["id"], 3);
    assert_eq!(state["pinned"][0]["pid"], 123, "{state}");
    assert!(
        state["windows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|w| w["id"] != 3)
    );

    // So does a fullscreen window, which is reported under `fullscreen`.
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    h.ok(json!({"op":"focus","window":2}));
    let entered = h.action("toggle-fullscreen");
    assert!(entered["effect"].is_object(), "{entered}");
    let state = h.read(json!("State"))["State"].clone();
    assert_eq!(state["fullscreen"][0]["id"], 2, "{state}");
    assert_eq!(state["fullscreen"][0]["pid"], 123, "{state}");
    assert_eq!(state["fullscreen"][0]["output"], "view-a");
}

#[test]
fn cursor_is_the_pointer_in_the_global_layout_and_the_output_the_request_is_for() {
    let mut h = setup();
    // The shell sends the pointer with every request, in the global screen
    // space `screen_bounds` are in: output 2 starts at (1200, 50).
    let at = |h: &mut Host, output: Value, pointer: Value| {
        h.ok(json!({"op":"ipc","output":output,"request":"Cursor","pointer":pointer}))
    };
    let data = at(&mut h, json!(2), json!({"x":1500.5,"y":212.25}));
    assert_eq!(
        data["reply"],
        json!({"Ok":{"Cursor":{"x":1500.5,"y":212.25,"output":"view-b"}}})
    );
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], false);
    assert_eq!(data["navigation"], Value::Null);
    let data = at(&mut h, json!(1), json!({"x":-30.0,"y":0.0}));
    assert_eq!(
        data["reply"],
        json!({"Ok":{"Cursor":{"x":-30.0,"y":0.0,"output":"view-a"}}}),
        "the layout's own coordinates, not output-local ones"
    );
    // Upstream's order of refusals: no pointer, then no output.
    let before = h.snapshot();
    let data = h.ok(json!({"op":"ipc","output":1,"request":"Cursor"}));
    assert_eq!(data["reply"], json!({"Err":"no pointer"}));
    let data = at(&mut h, Value::Null, json!({"x":1.0,"y":2.0}));
    assert_eq!(data["reply"], json!({"Err":"no output"}));
    let data = at(&mut h, json!(9), json!({"x":1.0,"y":2.0}));
    assert_eq!(data["reply"], json!({"Err":"unknown output"}));
    assert_eq!(h.snapshot(), before);
}

#[test]
fn msg_cursor_sends_the_unit_request_and_prints_the_reply() {
    let (listener, path) = bind();
    let socket = path.to_str().unwrap().to_owned();
    let (done, finished) = std::sync::mpsc::channel();
    let server = serve(listener, 3, setup, move |h, line| {
        let reply = match serde_json::from_str::<Value>(line) {
            Ok(request) => h.ok(
                json!({"op":"ipc","output":2,"request":request,"pointer":{"x":1401.0,"y":99.5}}),
            )["reply"]
                .clone(),
            Err(_) => json!({"Err":"invalid request"}),
        };
        done.send(line.to_owned()).unwrap();
        reply.to_string()
    });
    assert_eq!(msg(&["--socket", &socket, "cursor"]), 0);
    assert_eq!(finished.recv().unwrap(), "\"Cursor\"");
    assert_eq!(msg(&["--json", "--socket", &socket, "cursor"]), 0);
    assert_eq!(
        msg(&["--socket", &socket, "cursor", "extra"]),
        2,
        "no arguments"
    );
    assert_eq!(msg(&["--socket", &socket, "cursor", "--help"]), 0);
    // The third connection answers the help-less retry below.
    assert_eq!(msg(&["cursor", "--socket", &socket]), 0);
    assert_eq!(server.join().unwrap().len(), 3);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn requests_are_bounded_as_v0_21_0_bounds_them() {
    let mut h = setup();
    // `Camera`: within +-1e9, and refused before the fullscreen exit it would
    // otherwise cause or any state is touched.
    for to in [[1_000_000_001.0, 0.0], [0.0, -1e12], [2e9, 2e9]] {
        assert_eq!(
            h.refused(json!(1), json!({"Camera":to})),
            "camera coordinates must be within ±1e9"
        );
    }
    assert_eq!(
        h.refused(json!(1), json!({"Camera":[1e300,0.0]})),
        "camera coordinates must be within ±1e9"
    );
    let at_limit = h.ipc(json!({"Camera":[1_000_000_000.0, -1_000_000_000.0]}));
    assert_eq!(
        at_limit["reply"],
        json!({"Ok":{"Camera":{"x":1e9,"y":-1e9}}})
    );
    // Back to the origin: a bookmark is taken where the view is heading.
    h.ipc(json!({"Camera":[0.0, 0.0]}));

    // `Move`: +-1,050,000,000 whatever the selector, even one that names nothing.
    assert_eq!(
        h.refused(
            json!(1),
            json!({"Move":{"window":99,"to":[1_050_000_001,0]}})
        ),
        "coordinates must be within ±1050000000"
    );
    assert_eq!(
        h.refused(json!(1), json!({"Move":{"window":99,"to":[0,0]}})),
        "no window with id 99"
    );

    // `Resize`: sizes at most 32767, after the positive test and ahead of the
    // capability gate. 32767 itself gets as far as that gate.
    assert_eq!(
        h.refused(json!(1), json!({"Resize":{"window":3,"to":[0,10]}})),
        "size must be positive"
    );
    assert_eq!(
        h.refused(json!(1), json!({"Resize":{"window":3,"to":[32768,10]}})),
        "sizes must be at most 32767"
    );
    assert_eq!(
        h.refused(json!(1), json!({"Resize":{"window":3,"to":[10,40000]}})),
        "sizes must be at most 32767"
    );
    assert_eq!(
        h.refused(json!(1), json!({"Resize":{"window":3,"to":[32767,32767]}})),
        "resize is not implemented on macOS yet: native layout resize is not available"
    );

    // `Bookmark`: finite, within +-1e9, a name of at most 256 bytes, and a
    // registry of at most 256 names, an existing one always replaceable.
    assert_eq!(
        h.refused(
            json!(1),
            json!({"Bookmark":{"name":"far","to":[1_000_000_001.0,0.0]}})
        ),
        "bookmark coordinates must be within ±1e9"
    );
    let long = "n".repeat(257);
    assert_eq!(
        h.refused(json!(1), json!({"Bookmark":{"name":long,"to":[0.0,0.0]}})),
        "bookmark names are at most 256 bytes"
    );
    let longest = "n".repeat(256);
    assert!(
        h.ipc(json!({"Bookmark":{"name":longest,"to":[1e9,-1e9]}}))["reply"]
            .get("Ok")
            .is_some()
    );
    for index in 1..256 {
        let data = h.ipc(json!({"Bookmark":{"name":format!("b{index}"),"to":[index,0]}}));
        assert!(data["reply"].get("Ok").is_some(), "{index}: {data}");
    }
    assert_eq!(
        h.refused(
            json!(1),
            json!({"Bookmark":{"name":"one more","to":[0.0,0.0]}})
        ),
        "at most 256 bookmarks can be set; delete one first"
    );
    // The same cap holds for the `set-bookmark` action, which logs the refusal
    // upstream and here changes nothing; an existing name is replaced.
    let before = h.snapshot()["bookmarks"].clone();
    assert_eq!(before.as_object().unwrap().len(), 256);
    h.action("set-bookmark one-more");
    assert_eq!(h.snapshot()["bookmarks"], before);
    h.action("set-bookmark b1");
    assert_ne!(h.snapshot()["bookmarks"]["b1"], before["b1"]);
    assert_eq!(h.snapshot()["bookmarks"].as_object().unwrap().len(), 256);
    // Deleting one makes room.
    assert_eq!(
        h.ipc(json!({"Bookmark":{"name":"b1","delete":true}}))["reply"],
        json!({"Ok":"Ok"})
    );
    assert!(
        h.ipc(json!({"Bookmark":{"name":"one more","to":[0.0,0.0]}}))["reply"]
            .get("Ok")
            .is_some()
    );
}

#[test]
fn a_screenshot_region_is_bounded_before_a_pixel_is_drawn() {
    let mut h = setup();
    let region = |x: i64, y: i64, w: i64, h: i64, from_screen: bool| json!({"Screenshot":{"target":{"Region":{"x":x,"y":y,"w":w,"h":h,"from_screen":from_screen}},"scale":1.0,"path":"/nonexistent/shot.png"}});
    for from_screen in [false, true] {
        assert_eq!(
            h.refused(json!(1), region(1_050_000_001, 0, 10, 10, from_screen)),
            "coordinates must be within ±1050000000"
        );
        assert_eq!(
            h.refused(json!(1), region(0, -1_050_000_001, 10, 10, from_screen)),
            "coordinates must be within ±1050000000"
        );
        assert_eq!(
            h.refused(json!(1), region(0, 0, 32768, 10, from_screen)),
            "sizes must be at most 32767"
        );
    }
    // A width in the bound that the capture limit then refuses is that limit's
    // to refuse, with its own words.
    let error = h.refused(json!(1), region(0, 0, 32767, 10, false));
    assert!(error.contains("per-side limit"), "{error}");

    // Zoomed far out, a screen point in range lands on the canvas far past it:
    // 5e8 points at zoom 0.01 are 5e10 canvas points.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.01,"anchor":{"x":500.0,"y":410.0}}));
    assert_eq!(pose(&mut h, 1)["zoom"], 0.01);
    assert_eq!(
        h.refused(json!(1), region(500_000_000, 0, 10, 10, true)),
        "region lies past the canvas range"
    );
    // The same point in canvas coordinates is a legal one.
    let data = h.ipc(region(500_000_000, 0, 10, 10, false));
    assert!(data["reply"].is_null(), "{data}");
    assert_eq!(data["effects"][0]["op"], "screenshot");
}

/// The files `screenshot -o -` reserved in `dir` that are still there.
fn captures(dir: &std::path::Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| {
                    name.starts_with(&format!("screenshot-{}-", std::process::id()))
                })
        })
        .collect()
}

#[test]
fn screenshot_to_stdout_goes_through_a_private_file_the_client_reserved() {
    use std::os::unix::fs::PermissionsExt;
    let (listener, path) = bind();
    let socket = path.to_str().unwrap().to_owned();
    let dir = path.parent().unwrap().to_owned();
    let (seen, requests) = std::sync::mpsc::channel();
    let server = serve(
        listener,
        2,
        || (),
        move |_, line| {
            let request: Value = serde_json::from_str(line).unwrap();
            let target = request["Screenshot"]["path"].as_str().unwrap().to_owned();
            let file = PathBuf::from(&target);
            // Reserved by the client before it asked: new, empty, this user's
            // alone, beside the socket, and not a path anyone else could pick.
            let mode = std::fs::metadata(&file).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
            assert_eq!(std::fs::metadata(&file).unwrap().len(), 0);
            seen.send((file.clone(), line.to_owned())).unwrap();
            if line.contains("\"scale\":2.0") {
                return r#"{"Err":"capture refused"}"#.to_owned();
            }
            // The app writes beside the target and renames it into place, as
            // DWScreenshotWriter.m does; the client reads that, not the reply.
            let temporary = file.with_file_name(".written.tmp");
            std::fs::write(&temporary, b"infinify-test-png\n").unwrap();
            std::fs::rename(&temporary, &file).unwrap();
            // A reply naming some other file must not be believed.
            r#"{"Ok":{"Screenshot":{"path":"/etc/hosts","width":2,"height":3}}}"#.to_owned()
        },
    );
    assert!(captures(&dir).is_empty());
    assert_eq!(
        msg(&["--socket", &socket, "screenshot", "-o", "-"]),
        0,
        "the relay succeeds with the file the client reserved"
    );
    let (reserved, line) = requests.recv().unwrap();
    assert_eq!(reserved.parent(), Some(dir.as_path()));
    assert!(
        line.contains(reserved.to_str().unwrap()),
        "the request names the reserved file: {line}"
    );
    assert!(!reserved.exists(), "the file goes with its guard");
    // A refused capture leaves nothing behind either.
    assert_eq!(
        msg(&["--socket", &socket, "screenshot", "--scale", "2", "-o", "-"]),
        1
    );
    let (reserved, _) = requests.recv().unwrap();
    assert!(!reserved.exists());
    assert!(captures(&dir).is_empty());
    assert_eq!(server.join().unwrap().len(), 2);
    std::fs::remove_file(path).unwrap();
}

/// A scene file as the first builds wrote it: a title on every window, a
/// bookmark table and an `unsnapped` list in the scene, and none of the
/// top-level `bookmarks`, `standins` and `pins` keys. It still loads.
#[test]
fn a_scene_file_from_an_earlier_build_still_loads() {
    let legacy = json!({
        "version": 1,
        "scene": {
            "windows": [{
                "id": 20,
                "world_rect": {"origin": {"x": -2065.5, "y": -828.5},
                               "size": {"width": 1782.0, "height": 1291.0}},
                "title": "an earlier build kept the title here"
            }],
            "outputs": [],
            "focused": 20,
            "bookmarks": {},
            "unsnapped": []
        },
        "metadata": {"20": {"bundle_id": "app.term", "title": "alpha"}},
        "outputs": {"1": {
            "stable_id": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            "viewport": {"id": 1, "camera": {"x": 534.0, "y": 97.0}, "zoom": 1.0,
                         "screen_bounds": {"origin": {"x": 0.0, "y": 0.0},
                                           "size": {"width": 2056.0, "height": 1329.0}}}
        }},
        "next_window": 21,
        "next_output": 2
    });
    let path = std::env::temp_dir().join(format!("driftwm-ipc-legacy-{}.json", std::process::id()));
    std::fs::write(&path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":path}));
    let windows = h.snapshot()["windows"].as_array().unwrap().clone();
    assert_eq!(windows.len(), 1, "{windows:?}");
    assert_eq!(windows[0]["window"], 20);
    std::fs::remove_file(path).unwrap();
}
