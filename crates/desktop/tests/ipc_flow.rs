// SPDX-License-Identifier: GPL-3.0-or-later
//! IPC and action scenarios cross the exported C ABI and JSON decoder with
//! upstream-shaped requests, and the `msg` client is driven through its exported
//! symbol against a throwaway listener. They provide no native rendering,
//! capture, focus or input-delivery evidence, and never touch a real socket.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::{CStr, CString, c_char};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

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
impl Drop for Host {
    fn drop(&mut self) {
        unsafe {
            driftwm_desktop_destroy(self.0);
        }
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
                {"id":2,"app_id":"com.example.Editor","title":"Editor","position":[-700,1800],"size":[600,400],"is_focused":false,"is_widget":false,"suspended":false,"mode":"Normal"},
                {"id":3,"app_id":"com.example.Terminal","title":"Shell","position":[1000,-700],"size":[601,401],"is_focused":false,"is_widget":false,"suspended":false,"mode":"Normal"}
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

    // go-to disarms a zoom-to-fit return, so the next fit press fits again.
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

    // Upstream's tick lets an anchored zoom flight overrule a camera target set
    // during it: the bookmark jump is dropped and the zoom lands on its anchor.
    let zoom = h.action("zoom-reset")["navigation"].clone();
    let dropped = h.action("go-to-bookmark home")["navigation"].clone();
    assert_eq!(dropped["target_camera"], json!({"x":-1000.0,"y":-820.0}));
    assert_eq!(dropped["target_zoom"], 1.0);
    settle(&mut h, &mut clock);
    assert_eq!(pose(&mut h, 1)["camera"], zoom["target_camera"]);
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

    // Saved under schema 1 as an additive key, and restored by load.
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
fn move_resize_and_focus_address_logical_windows() {
    let mut h = setup();
    let world = |h: &mut Host, window: usize| h.snapshot()["windows"][window]["world_rect"].clone();

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
    for (window, index, to, origin, size) in [
        (2, 1, [100, -50], (-200.0, -150.0), (600.0, 400.0)),
        (3, 2, [0, 0], (-300.0, -200.0), (601.0, 401.0)),
        (1, 0, [-7, 9], (-157.0, -109.0), (300.0, 200.0)),
    ] {
        let data = h.ipc_on(Value::Null, json!({"Move":{"window":window,"to":to}}));
        assert_eq!(
            data,
            json!({"reply":{"Ok":{"Position":{"x":to[0],"y":to[1]}}},"effects":[],"dirty":true,"navigation":null})
        );
        assert_eq!(
            world(&mut h, index),
            rect(origin.0, origin.1, size.0, size.1)
        );
        assert_eq!(
            h.read(json!({"Move":{"window":window}})),
            json!({"Position":{"x":to[0],"y":to[1]}})
        );
    }
    // Stacking and focus are untouched by a move.
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focused"], Value::Null);
    let order: Vec<_> = snapshot["windows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["window"].clone())
        .collect();
    assert_eq!(order, [json!(1), json!(2), json!(3)]);
    h.ipc(json!({"Move":{"window":2,"to":[-700,1800]}}));
    h.ipc(json!({"Move":{"window":3,"to":[1000,-700]}}));
    // A destination no later request could read is refused: a top-left below
    // i32, or a center in range whose far edge (150 or 100 further) is not.
    for to in [
        [-2147483648i64, 0],
        [2147483647, 0],
        [0, 2147483647],
        [0, -2147483648],
    ] {
        assert_eq!(
            h.refused(Value::Null, json!({"Move":{"window":1,"to":to}})),
            "window geometry exceeds integer range"
        );
    }
    // The far edge may sit on i32::MAX itself, and the frame still reads back.
    let edge = json!({"Position":{"x":2147483497,"y":0}});
    assert_eq!(
        h.ipc(json!({"Move":{"window":1,"to":[2147483497,0]}}))["reply"]["Ok"],
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
    assert_eq!(h.snapshot()["focused"], 1);
    // Upstream reveal_suspended: an off-screen stand-in is panned to at the
    // zoom in effect (0.5 here), its center (-7, -9) under the usable center.
    assert_eq!(pose(&mut h, 1)["zoom"], 0.5);
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    assert_eq!(
        data["navigation"]["target_camera"],
        json!({"x":-1007.0,"y":-829.0})
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
"Subscribe" | subscribe is not implemented on macOS yet
{"Layout":{"short":false}} | layout is not implemented on macOS yet
{"Opacity":{}} | opacity is not implemented on macOS yet
{"Opacity":{"window":3,"value":0.5}} | opacity is not implemented on macOS yet
{"Pin":{}} | pin is not implemented on macOS yet
{"Pin":{"window":"terminal","value":true}} | pin is not implemented on macOS yet
{"Close":null} | close is not implemented on macOS yet
{"Close":3} | close is not implemented on macOS yet
{"Suspend":"terminal"} | suspend is not implemented on macOS yet
{"Relaunch":null} | relaunch is not implemented on macOS yet
{"Screenshot":{"target":"Viewport","scale":1.0,"path":"/nonexistent/shot.png"}} | screenshot is not implemented on macOS yet
{"Screenshot":{"target":{"Window":{}},"scale":2.0,"path":"/nonexistent/shot.png"}} | screenshot is not implemented on macOS yet
{"Action":"frobnicate"} | unknown action: frobnicate
{"Action":"close-window"} | action not implemented on macOS yet: close-window
{"Action":"pan-viewport"} | pan-viewport requires a direction
{"Action":"go-to 0 0"} | go-to was removed — save the point as a bookmark and use go-to-bookmark <name>
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
    for (name, sample) in [
        ("center-nearest", "center-nearest up"),
        ("center-window", "center-window"),
        ("close-window", "close-window"),
        ("cycle-windows", "cycle-windows forward"),
        ("cycle-windows", "cycle-windows backward"),
        ("exec", "exec open -a Terminal"),
        ("exec-launcher", "exec-launcher"),
        ("exec-terminal", "exec-terminal"),
        ("fill-window", "fill-window"),
        ("fit-window", "fit-window"),
        ("fit-window-snapped", "fit-window-snapped"),
        ("focus-center", "focus-center"),
        ("grow-window", "grow-window up"),
        ("move-to-bookmark", "move-to-bookmark 1"),
        ("nudge-window", "nudge-window Up-Left"),
        ("reload-config", "reload-config"),
        ("send-cursor-to-output", "send-cursor-to-output up"),
        ("send-to-output", "send-to-output up"),
        ("set-trackpad", "set-trackpad toggle"),
        ("set-trackpad", "set-trackpad OFF"),
        ("shrink-window", "shrink-window up"),
        ("spawn", "spawn foo"),
        ("suspend-window", "suspend-window"),
        ("switch-layout", "switch-layout next"),
        ("switch-layout", "switch-layout PREVIOUS"),
        ("switch-layout", "switch-layout 2"),
        ("toggle-cursor-pan", "toggle-cursor-pan"),
        ("toggle-fullscreen", "toggle-fullscreen"),
        ("toggle-pin-to-screen", "toggle-pin-to-screen"),
        ("zoom-to-fit-snapped", "zoom-to-fit-snapped"),
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
        (
            "go-to 100 200",
            "go-to was removed — save the point as a bookmark and use go-to-bookmark <name>",
        ),
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
    ] {
        assert_eq!(refuse(Value::Null, action), "no active output", "{action}");
        assert_eq!(refuse(json!(99), action), "unknown output", "{action}");
    }
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
suspend | {"Suspend":null} | {"Err":"suspend is not implemented on macOS yet"} | 1
relaunch --id 9 | {"Relaunch":9} | {"Ok":"Ok"} | 0
bookmark | {"Bookmark":{"name":null,"to":null,"delete":false}} | {"Ok":{"Bookmarks":{"home":[0.0,0.0]}}} | 0
bookmark inbox 500 -300 | {"Bookmark":{"name":"inbox","to":[500.0,-300.0],"delete":false}} | {"Ok":{"Bookmark":{"x":500.0,"y":-300.0}}} | 0
bookmark inbox --delete | {"Bookmark":{"name":"inbox","to":null,"delete":true}} | {"Ok":"Ok"} | 0
layout --short | {"Layout":{"short":true}} | {"Ok":{"Layout":"us"}} | 0
action go-to-bookmark my desk | {"Action":"go-to-bookmark my desk"} | {"Ok":"Ok"} | 0
action exec say --json -1 | {"Action":"exec say --json -1"} | {"Err":"action not implemented on macOS yet: exec"} | 1
screenshot region 1,2 30x40 --from-screen -o /nonexistent/shot.png --scale 2 | {"Screenshot":{"target":{"Region":{"x":1,"y":2,"w":30,"h":40,"from_screen":true}},"scale":2.0,"path":"/nonexistent/shot.png"}} | {"Err":"screenshot is not implemented on macOS yet"} | 1
screenshot window --id 2 --output=/nonexistent/w.png | {"Screenshot":{"target":{"Window":{"window":2}},"scale":1.0,"path":"/nonexistent/w.png"}} | {"Err":"screenshot is not implemented on macOS yet"} | 1
subscribe | "Subscribe" | {"Err":"subscribe is not implemented on macOS yet"} | 1
--json subscribe | "Subscribe" | {"Err":"subscribe is not implemented on macOS yet"} | 1
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
    assert_eq!(
        snapshot["windows"][1]["world_rect"],
        rect(-307.0, -209.0, 600.0, 400.0)
    );
    let (status, snapshot) = run(&["focus", "editor"]);
    assert_eq!(status, 0);
    assert_eq!(snapshot["focused"], 2);
    let (status, snapshot) = run(&["camera", "0", "0"]);
    assert_eq!(status, 0);
    assert_eq!(
        snapshot["navigation"]["flights"]["1"]["camera_target"],
        json!({"x":-1000.0,"y":-800.0})
    );
    assert_eq!(server.join().unwrap().len(), 9);
    std::fs::remove_file(path).unwrap();
}
