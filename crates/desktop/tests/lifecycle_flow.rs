// SPDX-License-Identifier: GPL-3.0-or-later
//! Window lifecycle scenarios cross the exported C ABI and JSON decoder with
//! synthetic observations. Expected positions are derived by hand from
//! upstream's placement rules, not read back from the controller. They provide
//! no evidence that a native window is discovered, captured, focused, closed
//! or launched: every effect here is a request nobody performs.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

struct Host(*mut Controller);
impl Host {
    fn new() -> Self {
        let handle = driftwm_desktop_create();
        assert!(!handle.is_null());
        Self(handle)
    }
    fn call(&mut self, command: Value) -> Value {
        let bytes = serde_json::to_vec(&json!({"version":1,"command":command})).unwrap();
        // SAFETY: live exclusive handle, valid bytes, response freed exactly once.
        unsafe {
            let response = driftwm_desktop_request(self.0, bytes.as_ptr(), bytes.len());
            assert!(!response.is_null());
            let result = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            driftwm_desktop_response_free(response);
            result
        }
    }
    fn ok(&mut self, command: Value) -> Value {
        let response = self.call(command.clone());
        assert_eq!(response["ok"], true, "{command}: {response}");
        response["data"].clone()
    }
    /// A refused command: an error, and nothing changed.
    fn error(&mut self, command: Value) -> String {
        let before = self.snapshot();
        let response = self.call(command.clone());
        assert_eq!(response["ok"], false, "{command}: {response}");
        assert_eq!(self.snapshot(), before, "{command}");
        response["error"].as_str().unwrap().to_owned()
    }
    fn snapshot(&mut self) -> Value {
        self.ok(json!({"op":"snapshot"}))
    }
    fn action(&mut self, action: &str) -> Value {
        self.ok(json!({"op":"action","output":1,"action":action}))
    }
    fn ipc(&mut self, request: Value) -> Value {
        self.ok(json!({"op":"ipc","output":1,"request":request}))
    }
    /// A refused request: an `Err` reply, nothing for the shell, state untouched.
    fn refused(&mut self, request: Value) -> String {
        let before = self.snapshot();
        let data = self.ipc(request.clone());
        assert_eq!(
            data,
            json!({"reply":{"Err":data["reply"]["Err"]},"effects":[],"dirty":false,"navigation":null}),
            "{request}"
        );
        assert_eq!(self.snapshot(), before, "{request}");
        data["reply"]["Err"].as_str().unwrap().to_owned()
    }
    fn window(&mut self, id: u64) -> Value {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == id)
            .unwrap_or_else(|| panic!("no window {id}"))
            .clone()
    }
    fn world(&mut self, id: u64) -> Value {
        self.window(id)["world_rect"].clone()
    }
    /// Logical ids in stacking order, bottom to top.
    fn stack(&mut self) -> Vec<u64> {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w["window"].as_u64().unwrap())
            .collect()
    }
    fn focused(&mut self) -> Value {
        self.snapshot()["focus"]["intent"].clone()
    }
    fn lifecycle(&mut self) -> Value {
        self.snapshot()["lifecycle"].clone()
    }
    fn camera(&mut self) -> Value {
        self.snapshot()["outputs"][0]["camera"].clone()
    }
    /// Report native focus on a bound window: logical focus, raise and history.
    fn observe_focus(&mut self, id: u64) {
        let source = self.window(id)["source"].clone();
        self.ok(json!({"op":"observe_focus","window":id,"identity":source["identity"],"generation":source["generation"]}));
    }
    /// Answer a focus request as a shell that performs no native focus does.
    fn logical(&mut self, effect: &Value) {
        self.ok(json!({"op":"focus_logical","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"]}));
    }
    /// Focus a bound window and answer its request `focus_logical`.
    fn focus_logically(&mut self, id: u64) {
        let effect = self.ok(json!({"op":"focus","window":id}))["effect"].clone();
        self.logical(&effect);
    }
    fn closed(&mut self, id: u64) -> Value {
        let identity = self.window(id)["source"]["identity"].clone();
        self.ok(json!({"op":"window_closed","window":id,"identity":identity}))
    }
    fn events(&mut self) -> Value {
        self.snapshot()["lifecycle_events"].clone()
    }
    /// Native focus the shell saw move to a bound window, named by the
    /// window's current binding as the shell's coordinator names it.
    fn native(&mut self, id: u64) -> Value {
        let source = self.window(id)["source"].clone();
        self.ok(native(id, &source["identity"], &source["generation"]))
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        unsafe {
            driftwm_desktop_destroy(self.0);
        }
    }
}

/// A directory of this test's own, removed when the test ends.
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "infinify-lifecycle-flow-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn point(x: f64, y: f64) -> Value {
    json!({"x":x,"y":y})
}
/// A fresh observation as the controller reports it back, `owner` and all.
fn identity(wid: u64) -> Value {
    json!({"pid":4242,"birth_sec":1800000000,"birth_usec":77,"wid":wid,"owner":null})
}
/// Where every fixture's native window sits on the desktop. No world position
/// may ever derive from it.
const NATIVE: (f64, f64) = (4000.0, 3000.0);
/// The pointer over the middle of the output, as a global screen point.
const POINTER: (f64, f64) = (700.0, 500.0);

/// One output of 1000 x 800 whose top-left is the global point (200, 100), and
/// whose usable area leaves a 50-point bar at the top: its center is the
/// output-local point (500, 425). A global point read as a local one, or the
/// output's center read as the usable one, misses every expectation below.
fn open(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"main","screen_bounds":rect(200.0,100.0,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,50.0,1000.0,750.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
}
fn load_config(h: &mut Host, scratch: &Scratch, toml: &str) {
    let path = scratch.path("config.toml");
    std::fs::write(&path, toml).unwrap();
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(reply["warnings"], json!([]), "{reply}");
}
/// The output, the given config file, and the launch pass already over: a
/// window that appears now is a new one.
fn running(scratch: &Scratch, toml: &str) -> Host {
    let mut h = Host::new();
    open(&mut h);
    load_config(&mut h, scratch, toml);
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[],"dirty":false})
    );
    h
}
/// Half the zoom and a camera off the origin: (1000, -200).
fn zoom_out(h: &mut Host) {
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":point(200.0,100.0)}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(500.0,-100.0)}));
    assert_eq!(h.camera(), point(1000.0, -200.0));
    assert_eq!(h.snapshot()["outputs"][0]["zoom"], 0.5);
}
/// A window that appeared by itself: neither a world rectangle nor a logical
/// id, with the active output and the pointer.
fn appear_at(h: &mut Host, wid: u64, app: &str, title: &str, size: (f64, f64), at: Value) -> Value {
    h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":title,"buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,size.0,size.1),"output":1,"pointer":at}))
}
fn appear(h: &mut Host, wid: u64, app: &str, title: &str, size: (f64, f64)) -> Value {
    appear_at(h, wid, app, title, size, point(POINTER.0, POINTER.1))
}
/// A window the caller puts at a world rectangle, as the chooser does.
fn put(h: &mut Host, wid: u64, app: &str, title: &str, world: Value) -> u64 {
    let reply = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":title,"buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,300.0,200.0),"world_rect":world}));
    assert_eq!(reply, json!({"window":reply["window"]}), "{reply}");
    reply["window"].as_u64().unwrap()
}
fn flight(camera: (f64, f64), zoom: f64) -> Value {
    json!({"target_camera":point(camera.0,camera.1),"target_zoom":zoom})
}
/// The destination of the flight a reply armed.
fn armed(reply: &Value) -> Value {
    let navigation = &reply["navigation"];
    assert_eq!(navigation["output"], 1, "{reply}");
    assert_eq!(navigation["animating"], true, "{reply}");
    json!({"target_camera":navigation["target_camera"],"target_zoom":navigation["target_zoom"]})
}
/// A native focus report for `window`, naming one binding of it.
fn native(window: u64, identity: &Value, generation: &Value) -> Value {
    json!({"op":"activate","window":window,"output":1,"cause":"native","identity":identity,"generation":generation})
}
/// One entry of the snapshot's `lifecycle_events`.
fn logged(serial: u64, window: u64, event: &str, output: Value) -> Value {
    json!({"serial":serial,"window":window,"event":event,"output":output})
}
fn focus_effect(reply: &Value, window: u64, wid: u64) {
    let effect = &reply["effect"];
    assert_eq!(effect["op"], "focus_native_window", "{reply}");
    assert_eq!(effect["window"], window, "{reply}");
    assert_eq!(effect["identity"], identity(wid), "{reply}");
}

#[test]
fn a_new_window_is_centered_under_the_focus_placement_point_and_cascades() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "window_placement = \"center\"\n");
    // The usable center is (500, 425) and the camera is at the origin: a
    // 400 x 300 frame centered there has its top-left at (300, 275).
    let a = appear(&mut h, 1, "app.a", "A", (400.0, 300.0));
    assert_eq!(a["window"], 1);
    assert_eq!(a["adopted"], false);
    assert_eq!(a["dirty"], true);
    assert_eq!(h.world(1), rect(300.0, 275.0, 400.0, 300.0));
    // Mapped as upstream maps it: focused, with a native focus request, and
    // navigated to at zoom 1. It is already where the navigation parks it.
    focus_effect(&a, 1, 1);
    assert_eq!(armed(&a), flight((0.0, 0.0), 1.0));
    assert_eq!(h.focused(), 1);
    assert_eq!(h.snapshot()["focus"]["pending_effect"], a["effect"]);
    // The same spot is taken: one title-bar step (25) down the diagonal.
    let b = appear(&mut h, 2, "app.b", "B", (400.0, 300.0));
    assert_eq!(h.world(2), rect(325.0, 300.0, 400.0, 300.0));
    assert_eq!(armed(&b), flight((25.0, 25.0), 1.0));
    assert_eq!((h.focused(), h.stack()), (json!(2), vec![1, 2]));
    // Upstream halves in integers: 401 / 2 is 200, so (300, 275) again, which
    // A holds; then B's spot; then a free one.
    appear(&mut h, 3, "app.c", "C", (401.0, 301.0));
    assert_eq!(h.world(3), rect(350.0, 325.0, 401.0, 301.0));
    // Within two points of a top-left counts as on it: (298, 275) is on A,
    // (323, 300) on B, (348, 325) on C.
    appear(&mut h, 4, "app.d", "D", (404.0, 300.0));
    assert_eq!(h.world(4), rect(373.0, 350.0, 404.0, 300.0));
    // Three points away does not: (297, 275) is free.
    appear(&mut h, 5, "app.e", "E", (406.0, 300.0));
    assert_eq!(h.world(5), rect(297.0, 275.0, 406.0, 300.0));
    assert_eq!(h.stack(), vec![1, 2, 3, 4, 5]);
    // No flight was ticked, so every placement above read the same camera.
    assert_eq!(h.camera(), point(0.0, 0.0));
}

#[test]
fn center_placement_reads_the_current_pose_and_the_landing_zoom() {
    let scratch = Scratch::new();
    // Zoomed out, the usable center shows the world point (2000, 650). The
    // navigation that follows resets the zoom around the window's center.
    let mut h = running(&scratch, "window_placement = \"center\"\n");
    zoom_out(&mut h);
    let reply = appear(&mut h, 1, "app.a", "A", (400.0, 300.0));
    assert_eq!(h.world(1), rect(1800.0, 500.0, 400.0, 300.0));
    assert_eq!(armed(&reply), flight((1500.0, 225.0), 1.0));
    // With zoom.reset_on_new_window off the camera only has to stay.
    let mut h = running(
        &scratch,
        "window_placement = \"center\"\n[zoom]\nreset_on_new_window = false\n",
    );
    zoom_out(&mut h);
    let reply = appear(&mut h, 1, "app.a", "A", (400.0, 300.0));
    assert_eq!(h.world(1), rect(1800.0, 500.0, 400.0, 300.0));
    assert_eq!(armed(&reply), flight((1000.0, -200.0), 0.5));

    // focus_placement moves the spawn point with it: the top-left corner of
    // the usable area, 20 points in, is the world point (20, 70).
    let corner =
        "window_placement = \"center\"\nfocus_placement = \"top-left\"\n[snap]\nouter_gap = 20\n";
    let mut h = running(&scratch, corner);
    let reply = appear(&mut h, 1, "app.a", "A", (400.0, 300.0));
    assert_eq!(h.world(1), rect(20.0, 70.0, 400.0, 300.0));
    assert_eq!(armed(&reply), flight((0.0, 0.0), 1.0));
    // The align point is taken at the zoom the navigation lands at (1), the
    // canvas conversion at the current one (0.5): (220, 220) on screen is the
    // world point (1440, 240), the frame's center.
    let mut h = running(&scratch, corner);
    zoom_out(&mut h);
    let reply = appear(&mut h, 1, "app.a", "A", (400.0, 300.0));
    assert_eq!(h.world(1), rect(1240.0, 90.0, 400.0, 300.0));
    assert_eq!(armed(&reply), flight((1220.0, 20.0), 1.0));
}

#[test]
fn cursor_placement_centers_on_the_pointer_inside_the_usable_area() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "window_placement = \"cursor\"\n");
    // The global pointer (700, 500) is the world point (500, 400).
    let a = appear(&mut h, 1, "app.a", "A", (400.0, 300.0));
    assert_eq!(h.world(1), rect(300.0, 250.0, 400.0, 300.0));
    // Cursor mode stays put: raised and focused, the camera left alone.
    focus_effect(&a, 1, 1);
    assert_eq!(a["navigation"], Value::Null);
    assert_eq!(h.focused(), 1);
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    // Near the far corner the frame is held inside the usable area, whose
    // world extent is (0, 50) to (1000, 800).
    appear_at(
        &mut h,
        2,
        "app.b",
        "B",
        (400.0, 300.0),
        point(1150.0, 880.0),
    );
    assert_eq!(h.world(2), rect(600.0, 500.0, 400.0, 300.0));
    // And near the near one: the bar's 50 points are not usable.
    appear_at(&mut h, 3, "app.c", "C", (400.0, 300.0), point(210.0, 110.0));
    assert_eq!(h.world(3), rect(0.0, 50.0, 400.0, 300.0));
    // The cascade applies to a cursor placement too.
    appear_at(&mut h, 4, "app.d", "D", (400.0, 300.0), point(210.0, 110.0));
    assert_eq!(h.world(4), rect(25.0, 75.0, 400.0, 300.0));
    // An oversized frame keeps its top-left on the usable edge, (0, 50), which
    // C holds; D holds the next step.
    appear(&mut h, 5, "app.e", "E", (1200.0, 900.0));
    assert_eq!(h.world(5), rect(50.0, 100.0, 1200.0, 900.0));
    // Without a pointer upstream falls back to the center, and navigates.
    let reply = h.ok(json!({"op":"attach","identity":identity(6),"bundle_id":"app.f","title":"F","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,400.0,300.0),"output":1}));
    assert_eq!(h.world(6), rect(300.0, 275.0, 400.0, 300.0));
    assert_eq!(armed(&reply), flight((0.0, 0.0), 1.0));

    // Zoomed out, the pointer is the world point (2000, 600) and the reset
    // rescues the overview: the camera does fly, to the window at zoom 1.
    let mut h = running(&scratch, "window_placement = \"cursor\"\n");
    zoom_out(&mut h);
    let reply = appear(&mut h, 1, "app.a", "A", (400.0, 300.0));
    assert_eq!(h.world(1), rect(1800.0, 450.0, 400.0, 300.0));
    assert_eq!(armed(&reply), flight((1500.0, 175.0), 1.0));
    // With the reset off there is nothing to rescue.
    let mut h = running(
        &scratch,
        "window_placement = \"cursor\"\n[zoom]\nreset_on_new_window = false\n",
    );
    zoom_out(&mut h);
    let reply = appear(&mut h, 1, "app.a", "A", (400.0, 300.0));
    assert_eq!(h.world(1), rect(1800.0, 450.0, 400.0, 300.0));
    assert_eq!(reply["navigation"], Value::Null);
    focus_effect(&reply, 1, 1);
}

const AUTO: &str = "window_placement = \"auto\"\n[snap]\ngap = 12\n";

#[test]
fn auto_placement_snaps_beside_the_focused_window_or_the_nearest_in_view() {
    let scratch = Scratch::new();
    // The focused window has a neighbor docked under it. The usable center
    // (500, 425) is below the anchor's center, so the bottom edge is tried
    // first: the neighbor blocks it. Clockwise, the left edge is free: the new
    // frame's right edge sits 12 from the anchor's left, centered on its height.
    let mut h = running(&scratch, AUTO);
    put(&mut h, 1, "app.a", "A", rect(300.0, 200.0, 400.0, 300.0));
    put(&mut h, 2, "app.b", "B", rect(300.0, 512.0, 400.0, 200.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = appear(&mut h, 3, "app.c", "C", (200.0, 100.0));
    assert_eq!(h.world(3), rect(88.0, 300.0, 200.0, 100.0));
    // Auto placement navigates like the center does: the frame's center
    // (188, 350) flies to the usable center.
    assert_eq!(armed(&reply), flight((-312.0, -75.0), 1.0));
    focus_effect(&reply, 3, 3);
    assert_eq!((h.focused(), h.stack()), (json!(3), vec![2, 1, 3]));

    // Nothing focused: the element nearest the usable center anchors. B is 100
    // away, A about 266. The center is left of B, so B's left edge is taken.
    let mut h = running(&scratch, AUTO);
    put(&mut h, 1, "app.a", "A", rect(100.0, 100.0, 200.0, 150.0));
    put(&mut h, 2, "app.b", "B", rect(600.0, 300.0, 300.0, 200.0));
    assert_eq!(h.focused(), Value::Null);
    appear(&mut h, 3, "app.c", "C", (200.0, 100.0));
    assert_eq!(h.world(3), rect(388.0, 350.0, 200.0, 100.0));
    // The focused window anchors while it is in view, nearest or not. The
    // center is further right of A's than below it, so A's right edge is
    // taken: 12 from it, centered on A's height.
    let mut h = running(&scratch, AUTO);
    put(&mut h, 1, "app.a", "A", rect(100.0, 100.0, 200.0, 150.0));
    put(&mut h, 2, "app.b", "B", rect(600.0, 300.0, 300.0, 200.0));
    h.ok(json!({"op":"focus","window":1}));
    appear(&mut h, 3, "app.c", "C", (200.0, 100.0));
    assert_eq!(h.world(3), rect(312.0, 125.0, 200.0, 100.0));

    // A focused window out of view cannot anchor; the nearest in view does,
    // and a detached placeholder anchors like any window.
    let mut h = running(&scratch, AUTO);
    put(&mut h, 1, "app.a", "A", rect(100.0, 100.0, 200.0, 150.0));
    put(&mut h, 2, "app.b", "B", rect(600.0, 300.0, 300.0, 200.0));
    put(
        &mut h,
        3,
        "app.far",
        "Far",
        rect(5000.0, 5000.0, 300.0, 200.0),
    );
    h.ok(json!({"op":"remove_source","window":2,"identity":identity(2),"keep_placeholder":true}));
    h.ok(json!({"op":"focus","window":3}));
    appear(&mut h, 4, "app.c", "C", (200.0, 100.0));
    assert_eq!(h.world(4), rect(388.0, 350.0, 200.0, 100.0));
}

#[test]
fn auto_placement_falls_back_to_the_center_exactly_as_upstream_does() {
    let scratch = Scratch::new();
    // No window at all.
    let mut h = running(&scratch, AUTO);
    let reply = appear(&mut h, 1, "app.a", "A", (200.0, 100.0));
    assert_eq!(h.world(1), rect(400.0, 375.0, 200.0, 100.0));
    assert_eq!(armed(&reply), flight((0.0, 0.0), 1.0));
    // The only window is focused but out of view.
    let mut h = running(&scratch, AUTO);
    put(
        &mut h,
        1,
        "app.far",
        "Far",
        rect(5000.0, 5000.0, 300.0, 200.0),
    );
    h.ok(json!({"op":"focus","window":1}));
    appear(&mut h, 2, "app.a", "A", (200.0, 100.0));
    assert_eq!(h.world(2), rect(400.0, 375.0, 200.0, 100.0));
    // A quarter of the only window is in view: under upstream's third.
    let mut h = running(&scratch, AUTO);
    put(
        &mut h,
        1,
        "app.edge",
        "Edge",
        rect(-300.0, 100.0, 400.0, 300.0),
    );
    appear(&mut h, 2, "app.a", "A", (200.0, 100.0));
    assert_eq!(h.world(2), rect(400.0, 375.0, 200.0, 100.0));
    // 35% of it is: it anchors, and the new frame docks on its right edge,
    // the one facing the usable center, centered on its height.
    let mut h = running(&scratch, AUTO);
    put(
        &mut h,
        1,
        "app.edge",
        "Edge",
        rect(-260.0, 100.0, 400.0, 300.0),
    );
    appear(&mut h, 2, "app.a", "A", (200.0, 100.0));
    assert_eq!(h.world(2), rect(152.0, 200.0, 200.0, 100.0));
}

#[test]
fn windows_already_open_at_launch_are_placed_without_focus_or_flight() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    open(&mut h);
    // Center makes the cascading positions explicit; this scenario isolates
    // launch-pass suppression of focus and flights from the default policy.
    load_config(&mut h, &scratch, "window_placement = \"center\"\n");
    assert_eq!(h.lifecycle()["settled"], false);
    // The launch pass: placed by the policy, cascading, and nothing else.
    for (wid, at) in [(1, (300.0, 275.0)), (2, (325.0, 300.0))] {
        let reply = appear(&mut h, wid, "app.a", "A", (400.0, 300.0));
        assert_eq!(
            reply,
            json!({"window":wid,"adopted":false,"background":false,"effect":null,"navigation":null,"dirty":true})
        );
        assert_eq!(h.world(wid), rect(at.0, at.1, 400.0, 300.0));
    }
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["intent"], Value::Null);
    assert_eq!(snapshot["focus"]["pending_effect"], Value::Null);
    assert_eq!(snapshot["navigation"]["flights"], json!({}));
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[],"dirty":false})
    );
    assert_eq!(h.lifecycle()["settled"], true);
    // From now on a window that appears is a new one.
    let reply = appear(&mut h, 3, "app.a", "A", (400.0, 300.0));
    assert_eq!(h.world(3), rect(350.0, 325.0, 400.0, 300.0));
    focus_effect(&reply, 3, 3);
    assert_eq!(armed(&reply), flight((50.0, 50.0), 1.0));
    // With nothing waiting, another adoption_complete changes nothing.
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[],"dirty":false})
    );

    // Without an active output upstream has no view to place in: the origin,
    // cascading, and no focus or flight even after the launch pass.
    let mut h = running(&scratch, "");
    for (wid, at) in [(1, 0.0), (2, 25.0)] {
        let reply = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":"app.a","title":"A","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,400.0,300.0)}));
        assert_eq!(
            reply,
            json!({"window":wid,"adopted":false,"background":false,"effect":null,"navigation":null,"dirty":true})
        );
        assert_eq!(h.world(wid), rect(at, at, 400.0, 300.0));
    }
    assert_eq!(h.focused(), Value::Null);
    // The inputs are checked.
    for (extra, error) in [
        (json!({"output":9}), "unknown output"),
        (
            json!({"output":1,"pointer":{"x":1e300,"y":0.0}}),
            "invalid screen point",
        ),
    ] {
        let mut command = json!({"op":"attach","identity":identity(3),"bundle_id":"app.a","title":"A","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,400.0,300.0)});
        command
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        assert_eq!(h.error(command), error);
    }
}

/// A scene with four windows open, saved: two of one app, the second of them
/// focused and so on top.
fn saved_session(scratch: &Scratch) -> PathBuf {
    let mut h = Host::new();
    open(&mut h);
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.term",
        "beta",
        rect(500.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        3,
        "app.web",
        "docs",
        rect(100.0, 400.0, 400.0, 300.0),
    );
    put(
        &mut h,
        4,
        "app.notes",
        "todo",
        rect(600.0, 400.0, 300.0, 300.0),
    );
    h.ok(json!({"op":"focus","window":2}));
    let path = scratch.path("scene.json");
    h.ok(json!({"op":"save","path":path}));
    path
}
/// The next launch: the scene file, the output, the config, and no window yet.
fn relaunched(scratch: &Scratch, scene: &PathBuf, toml: &str) -> Host {
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":scene}));
    open(&mut h);
    load_config(&mut h, scratch, toml);
    assert_eq!(h.stack(), vec![1, 3, 4, 2]);
    h
}
const ADOPTED: fn(u64) -> Value = |id| json!({"window":id,"adopted":true,"background":false,"effect":null,"navigation":null,"dirty":true});

#[test]
fn still_open_windows_take_their_saved_slots_back_and_the_rest_are_dropped() {
    let scratch = Scratch::new();
    let scene = saved_session(&scratch);
    // The unmatched window's fixed center is incidental to slot matching.
    let mut h = relaunched(&scratch, &scene, "window_placement = \"center\"\n");
    // Two slots of one app: the title picks, not the lower id. The slot keeps
    // its logical id, its world frame whatever the native size is now, and its
    // place in the stack; the window brings its identity.
    assert_eq!(
        appear(&mut h, 21, "app.term", "beta", (640.0, 480.0)),
        ADOPTED(2)
    );
    assert_eq!(h.world(2), rect(500.0, 100.0, 300.0, 200.0));
    assert_eq!(h.window(2)["source"]["identity"], identity(21));
    // A retitled window still takes the slot of its app that is left.
    assert_eq!(
        appear(&mut h, 22, "app.term", "gamma", (640.0, 480.0)),
        ADOPTED(1)
    );
    assert_eq!(h.window(1)["metadata"]["title"], "gamma");
    assert_eq!(h.world(1), rect(100.0, 100.0, 300.0, 200.0));
    // A third window of the app has no slot: it is placed, and during the
    // launch pass that is all.
    assert_eq!(
        appear(&mut h, 23, "app.term", "delta", (640.0, 480.0)),
        json!({"window":5,"adopted":false,"background":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.world(5), rect(180.0, 185.0, 640.0, 480.0));
    assert_eq!(
        appear(&mut h, 24, "app.web", "another page", (640.0, 480.0)),
        ADOPTED(3)
    );
    // No slot of that app, and no bundle identifier at all: both are placed,
    // even when a slot has that very title.
    assert_eq!(
        appear(&mut h, 25, "app.files", "todo", (300.0, 200.0))["window"],
        6
    );
    assert_eq!(appear(&mut h, 26, "", "todo", (300.0, 200.0))["window"], 7);
    assert_eq!(h.stack(), vec![1, 3, 4, 2, 5, 6, 7]);
    // The saved focus stayed on its slot, and nothing asked for native focus.
    // With no request to answer, the adopted window that holds the focus is
    // in the focus history at once; the others are not.
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["intent"], 2);
    assert_eq!(snapshot["focus"]["pending_effect"], Value::Null);
    assert_eq!(snapshot["focus"]["history"], json!([2]));
    assert_eq!(snapshot["navigation"]["flights"], json!({}));
    // The notes window closed while the canvas was not running.
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[4],"standins":[],"dirty":true})
    );
    assert_eq!(h.stack(), vec![1, 3, 2, 5, 6, 7]);
    assert_eq!(
        h.lifecycle(),
        json!({"settled":true,"standins":[],"relaunching":[],"marks":{}})
    );

    // Nothing was still open: every slot goes, and with the focused one the
    // focus. An adopting window's output and pointer are checked like a
    // placed one's.
    let mut h = relaunched(&scratch, &scene, "");
    assert_eq!(
        h.error(json!({"op":"attach","identity":identity(21),"bundle_id":"app.term","title":"beta","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,640.0,480.0),"output":9})),
        "unknown output"
    );
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[1,2,3,4],"standins":[],"dirty":true})
    );
    let snapshot = h.snapshot();
    assert_eq!(snapshot["windows"], json!([]));
    assert_eq!(snapshot["focus"]["intent"], Value::Null);
    // A window rule turns restore_windows on for one app, as upstream's does.
    let rule = "[[window_rules]]\napp_id = \"app.notes\"\nrestore_windows = true\n";
    let mut h = relaunched(&scratch, &scene, rule);
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[1,2,3],"standins":[4],"dirty":true})
    );
    assert_eq!((h.stack(), h.focused()), (vec![4], Value::Null));
    // Upstream reads the rule by app alone on the way back, so one keyed on a
    // title restores nothing.
    let rule = "[[window_rules]]\ntitle = \"todo\"\nrestore_windows = true\n";
    let mut h = relaunched(&scratch, &scene, rule);
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[1,2,3,4],"standins":[],"dirty":true})
    );
}

#[test]
fn detached_windows_take_their_slots_back_when_the_canvas_reopens() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.term",
        "beta",
        rect(500.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        3,
        "app.web",
        "docs",
        rect(100.0, 400.0, 400.0, 300.0),
    );
    // The shell closes the canvas: every source is detached, every slot kept.
    for id in [1, 2, 3] {
        h.ok(json!({"op":"remove_source","window":id,"identity":identity(id),"keep_placeholder":true}));
    }
    assert_eq!(h.lifecycle()["standins"], json!([]));
    // Reopened after the launch pass, it reports the same windows again. One
    // was retitled meanwhile: the title still picks first, and the retitled
    // window takes the slot of its app that is left. Nothing moves or flies.
    assert_eq!(
        appear(&mut h, 2, "app.term", "beta", (300.0, 200.0)),
        ADOPTED(2)
    );
    assert_eq!(
        appear(&mut h, 1, "app.term", "build", (300.0, 200.0)),
        ADOPTED(1)
    );
    assert_eq!(
        appear(&mut h, 3, "app.web", "docs", (300.0, 200.0)),
        ADOPTED(3)
    );
    assert_eq!(h.stack(), vec![1, 2, 3]);
    assert_eq!(h.world(1), rect(100.0, 100.0, 300.0, 200.0));
    // A window opened while it was closed has no slot: a new window.
    let reply = appear(&mut h, 4, "app.term", "gamma", (300.0, 200.0));
    assert_eq!(
        (&reply["window"], &reply["adopted"]),
        (&json!(4), &json!(false))
    );
    focus_effect(&reply, 4, 4);

    // A scene loaded after the launch pass brings its slots and no second
    // pass: a window that appears with no slot is still a new one.
    let path = scratch.path("scene.json");
    h.ok(json!({"op":"save","path":path}));
    h.ok(json!({"op":"load","path":path}));
    open(&mut h);
    assert_eq!(h.lifecycle()["settled"], true);
    assert_eq!(
        appear(&mut h, 11, "app.web", "docs", (300.0, 200.0)),
        ADOPTED(3)
    );
    let reply = appear(&mut h, 12, "app.files", "Desktop", (300.0, 200.0));
    assert_eq!(reply["adopted"], false);
    focus_effect(&reply, 5, 12);
}

#[test]
fn restore_windows_keeps_unmatched_slots_as_dormant_stand_ins() {
    let scratch = Scratch::new();
    let scene = saved_session(&scratch);
    let mut h = relaunched(&scratch, &scene, "[session]\nrestore_windows = true\n");
    assert_eq!(
        appear(&mut h, 21, "app.web", "docs", (640.0, 480.0)),
        ADOPTED(3)
    );
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[1,2,4],"dirty":true})
    );
    assert_eq!(h.lifecycle()["standins"], json!([1, 2, 4]));
    assert_eq!(h.stack(), vec![1, 3, 4, 2]);
    // The focus comes back on its stand-in, as upstream restores it.
    assert_eq!(h.focused(), 2);
    // Dormant: a window of that app, with that very title, is a new window.
    let reply = appear(&mut h, 22, "app.term", "alpha", (400.0, 300.0));
    assert_eq!(
        (&reply["window"], &reply["adopted"]),
        (&json!(5), &json!(false))
    );
    focus_effect(&reply, 5, 22);
    let state = h.ipc(json!("State"))["reply"]["Ok"]["State"]["windows"].clone();
    let suspended: Vec<_> = state
        .as_array()
        .unwrap()
        .iter()
        .filter(|w| w["suspended"] == true)
        .map(|w| w["id"].as_u64().unwrap())
        .collect();
    assert_eq!(suspended, vec![1, 4, 2]);

    // Relaunching is what wakes one. Two stand-ins of one app are served in the
    // order they were relaunched, not by id.
    for id in [2, 1] {
        assert_eq!(
            h.ipc(json!({"Relaunch":id})),
            json!({"reply":{"Ok":"Ok"},"effects":[{"op":"launch","bundle_id":"app.term","window":id}],"dirty":false,"navigation":null})
        );
    }
    assert_eq!(h.lifecycle()["relaunching"], json!([2, 1]));
    // Asking again while one is in flight is upstream's no-op: nothing for
    // the shell, and the place in the queue is kept.
    assert_eq!(
        h.ipc(json!({"Relaunch":"TERM"})),
        json!({"reply":{"Ok":"Ok"},"effects":[],"dirty":false,"navigation":null})
    );
    assert_eq!(h.lifecycle()["relaunching"], json!([2, 1]));
    // The adopted window keeps the slot's frame and stacking, the camera
    // stays, and it takes the focus only if the stand-in held it.
    assert_eq!(
        appear(&mut h, 23, "app.term", "new shell", (400.0, 300.0)),
        ADOPTED(2)
    );
    assert_eq!(h.focused(), 5);
    h.ok(json!({"op":"focus","window":1}));
    let reply = appear(&mut h, 24, "app.term", "newer shell", (400.0, 300.0));
    assert_eq!(
        (&reply["window"], &reply["adopted"]),
        (&json!(1), &json!(true))
    );
    focus_effect(&reply, 1, 24);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(h.world(1), rect(100.0, 100.0, 300.0, 200.0));
    assert_eq!(h.stack(), vec![3, 4, 2, 5, 1]);
    assert_eq!(
        h.lifecycle(),
        json!({"settled":true,"standins":[4],"relaunching":[],"marks":{}})
    );
    // The focused stand-in is the one relaunched without a selector.
    h.ok(json!({"op":"focus","window":4}));
    assert_eq!(
        h.ipc(json!({"Relaunch":null}))["effects"],
        json!([{"op":"launch","bundle_id":"app.notes","window":4}])
    );
    // Dismissing a stand-in cancels its relaunch.
    assert_eq!(h.ipc(json!({"Close":4}))["reply"], json!({"Ok":"Ok"}));
    assert_eq!(h.lifecycle()["relaunching"], json!([]));
    assert_eq!(
        appear(&mut h, 25, "app.notes", "todo", (300.0, 300.0))["adopted"],
        false
    );
}

#[test]
fn stand_ins_survive_a_restart_whatever_restore_windows_says() {
    let scratch = Scratch::new();
    let path = scratch.path("scene.json");
    let mut h = running(&scratch, "[session]\nsuspend_on_close = true\n");
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.web",
        "docs",
        rect(500.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        3,
        "app.notes",
        "todo",
        rect(100.0, 400.0, 300.0, 200.0),
    );
    assert_eq!(h.closed(1)["standin"], true);
    h.ok(json!({"op":"save","path":path}));
    // The save names the stand-in by logical id and nothing native.
    let text = std::fs::read_to_string(&path).unwrap();
    let saved: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(saved["standins"], json!([1]));
    for native in [
        "\"pid\"",
        "\"wid\"",
        "birth",
        "identity",
        "generation",
        "owner",
        "source",
        "buffer",
        "4242",
        "1800000000",
        "4000",
        "3000",
    ] {
        assert!(!text.contains(native), "{native} in {text}");
    }

    let mut h = Host::new();
    h.ok(json!({"op":"load","path":path}));
    open(&mut h);
    load_config(&mut h, &scratch, "");
    assert_eq!(h.lifecycle()["standins"], json!([1]));
    // A stand-in is not waiting for a window: one of its app, with its title,
    // is placed. The slot of a window that was open is.
    assert_eq!(
        appear(&mut h, 21, "app.term", "alpha", (300.0, 200.0))["adopted"],
        false
    );
    assert_eq!(
        appear(&mut h, 22, "app.web", "docs", (300.0, 200.0)),
        ADOPTED(2)
    );
    // restore_windows is off: the open window that is gone is dropped, the
    // stand-in stays.
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[3],"standins":[],"dirty":true})
    );
    assert_eq!(h.stack(), vec![1, 2, 4]);
    assert_eq!(h.lifecycle()["standins"], json!([1]));
    // A file without stand-ins has no such key, as before they existed.
    h.ok(json!({"op":"forget","window":1}));
    h.ok(json!({"op":"save","path":path}));
    let saved: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(saved.get("standins").is_none(), "{saved}");
    // A stand-in that names no window is refused.
    let mut broken = saved.clone();
    broken["standins"] = json!([9]);
    let bad = scratch.path("bad.json");
    std::fs::write(&bad, serde_json::to_vec(&broken).unwrap()).unwrap();
    assert_eq!(
        h.error(json!({"op":"load","path":bad})),
        "invalid saved stand-in"
    );
}

#[test]
fn a_lost_source_takes_its_own_slot_back() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    // A capture error: the source is dropped, the window is still there.
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(1),"keep_placeholder":true}));
    assert_eq!(h.lifecycle()["standins"], json!([]));
    assert_eq!(
        appear(&mut h, 1, "app.term", "alpha", (300.0, 200.0))["window"],
        1
    );
    assert_eq!(h.world(1), rect(100.0, 100.0, 300.0, 200.0));
    assert_eq!(h.stack(), vec![1]);
    // A rebind by logical id, as the chooser does it, is what it always was.
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(1),"keep_placeholder":true}));
    assert_eq!(
        h.ok(json!({"op":"attach","logical_id":1,"identity":identity(31),"bundle_id":"app.other","title":"rebound","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,300.0,200.0),"output":1,"pointer":point(POINTER.0,POINTER.1)})),
        json!({"window":1})
    );
    assert_eq!(h.focused(), Value::Null);
    // And an explicit world rectangle is taken as given, pointer or not.
    let world = rect(-40.5, 900.25, 320.0, 240.0);
    assert_eq!(
        h.ok(json!({"op":"attach","identity":identity(32),"bundle_id":"app.other","title":"placed","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,300.0,200.0),"world_rect":world,"output":1,"pointer":point(POINTER.0,POINTER.1)})),
        json!({"window":2})
    );
    assert_eq!(h.world(2), world);
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["intent"], Value::Null);
    assert_eq!(snapshot["focus"]["pending_effect"], Value::Null);
    assert_eq!(snapshot["navigation"]["flights"], json!({}));
    assert_eq!(
        h.error(json!({"op":"attach","logical_id":1,"world_rect":world,"identity":identity(33),"bundle_id":"app.other","title":"both","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,300.0,200.0)})),
        "rebind cannot replace saved world geometry"
    );
}

#[test]
fn a_closed_window_leaves_the_scene_or_a_stand_in() {
    let scratch = Scratch::new();
    // suspend_on_close off, upstream's default: the window is gone entirely.
    let mut h = running(&scratch, "");
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    assert_eq!(
        h.closed(1),
        json!({"standin":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.stack(), Vec::<u64>::new());
    assert_eq!(h.snapshot()["placements"], json!([]));

    // On: a stand-in keeps the id, the frame and the place in the stack, and
    // the focus if the window held it.
    let mut h = running(&scratch, "[session]\nsuspend_on_close = true\n");
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.web",
        "docs",
        rect(500.0, 100.0, 300.0, 200.0),
    );
    put(&mut h, 3, "", "nameless", rect(100.0, 400.0, 300.0, 200.0));
    h.observe_focus(2);
    h.observe_focus(1);
    // A stale identity is refused, and changes nothing.
    assert_eq!(
        h.error(json!({"op":"window_closed","window":1,"identity":identity(9)})),
        "stale source identity"
    );
    assert_eq!(
        h.error(json!({"op":"window_closed","window":1,"identity":identity(1),"output":9})),
        "unknown output"
    );
    assert_eq!(
        h.closed(1),
        json!({"standin":true,"effect":null,"navigation":null,"dirty":true})
    );
    let window = h.window(1);
    assert_eq!(window["source"], Value::Null);
    assert_eq!(window["world_rect"], rect(100.0, 100.0, 300.0, 200.0));
    assert_eq!(
        window["metadata"],
        json!({"bundle_id":"app.term","title":"alpha"})
    );
    assert_eq!(h.stack(), vec![3, 2, 1]);
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["intent"], 1);
    assert_eq!(snapshot["focus"]["history"], json!([2]));
    assert_eq!(snapshot["focus"]["observed_native"], Value::Null);
    assert_eq!(snapshot["lifecycle"]["standins"], json!([1]));
    // It is gone for the controller: a second report is refused.
    assert_eq!(
        h.error(json!({"op":"window_closed","window":1,"identity":identity(1)})),
        "unbound source"
    );
    // A background close does not steal the focus from it.
    assert_eq!(h.closed(2)["standin"], true);
    assert_eq!(h.focused(), 1);
    // An app that could not be relaunched leaves no stand-in.
    assert_eq!(h.closed(3)["standin"], false);
    assert_eq!(h.stack(), vec![2, 1]);

    // A window rule overrides the section for its app, as upstream's does.
    let rule = "[session]\nsuspend_on_close = true\n[[window_rules]]\napp_id = \"app.term\"\nsuspend_on_close = false\n";
    let mut h = running(&scratch, rule);
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.web",
        "docs",
        rect(500.0, 100.0, 300.0, 200.0),
    );
    assert_eq!(h.closed(1)["standin"], false);
    assert_eq!(h.closed(2)["standin"], true);
    assert_eq!(h.stack(), vec![2]);
}

fn close_effect(window: u64, generation: u64) -> Value {
    json!({"op":"close_window","window":window,"identity":identity(window),"generation":generation})
}

#[test]
fn close_and_suspend_actions_ask_the_shell_and_mark_what_the_close_means() {
    let scratch = Scratch::new();
    // close-window is a real close: suspend_on_close leaves no stand-in.
    let mut h = running(&scratch, "[session]\nsuspend_on_close = true\n");
    // Nothing focused: upstream does nothing.
    let idle = json!({"navigation":null,"effects":[],"dirty":false});
    assert_eq!(h.action("close-window"), idle);
    assert_eq!(h.action("suspend-window"), idle);
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.web",
        "docs",
        rect(500.0, 100.0, 300.0, 200.0),
    );
    h.observe_focus(1);
    // The request names the binding exactly; the window stays until the shell
    // reports it gone.
    assert_eq!(
        h.action("close-window"),
        json!({"navigation":null,"effects":[close_effect(1, 1)],"dirty":false})
    );
    assert_eq!(h.lifecycle()["marks"], json!({"1":"close"}));
    assert_ne!(h.window(1)["source"], Value::Null);
    assert_eq!(h.closed(1)["standin"], false);
    assert_eq!(h.stack(), vec![2]);
    assert_eq!(h.lifecycle()["marks"], json!({}));
    // The action needs no active output.
    h.observe_focus(2);
    assert_eq!(
        h.ok(json!({"op":"action","output":null,"action":"close-window"}))["effects"],
        json!([close_effect(2, 2)])
    );

    // suspend-window leaves a stand-in whatever the section says.
    let mut h = running(&scratch, "");
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(&mut h, 2, "", "nameless", rect(500.0, 100.0, 300.0, 200.0));
    h.observe_focus(1);
    assert_eq!(
        h.action("suspend-window"),
        json!({"navigation":null,"effects":[close_effect(1, 1)],"dirty":false})
    );
    assert_eq!(h.lifecycle()["marks"], json!({"1":"suspend"}));
    // The later of two commands wins.
    h.action("close-window");
    assert_eq!(h.lifecycle()["marks"], json!({"1":"close"}));
    h.action("suspend-window");
    assert_eq!(h.closed(1)["standin"], true);
    assert_eq!(
        (h.focused(), h.lifecycle()["standins"].clone()),
        (json!(1), json!([1]))
    );
    // A second press, now on the stand-in, dismisses it. Nothing was focused
    // before it but the stand-in, so the nearest visible window follows.
    let reply = h.action("suspend-window");
    assert_eq!(reply["dirty"], true);
    assert_eq!(reply["effects"][0]["op"], "focus_native_window");
    assert_eq!(reply["effects"][0]["window"], 2);
    assert_eq!((h.stack(), h.focused()), (vec![2], json!(2)));
    // An app that could not be relaunched closes for real.
    assert_eq!(
        h.action("suspend-window")["effects"],
        json!([close_effect(2, 2)])
    );
    assert_eq!(h.lifecycle()["marks"], json!({"2":"close"}));
    // A mark does not outlive its binding.
    h.ok(json!({"op":"remove_source","window":2,"identity":identity(2),"keep_placeholder":true}));
    assert_eq!(h.lifecycle()["marks"], json!({}));
    // close-window on a focused placeholder dismisses it too.
    assert_eq!(
        h.action("close-window"),
        json!({"navigation":null,"effects":[],"dirty":true})
    );
    assert_eq!((h.stack(), h.focused()), (Vec::<u64>::new(), Value::Null));
}

#[test]
fn ipc_close_suspend_and_relaunch_answer_as_upstream_does() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    put(
        &mut h,
        1,
        "app.Term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.web",
        "docs",
        rect(500.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        3,
        "app.term",
        "beta",
        rect(100.0, 400.0, 300.0, 200.0),
    );
    put(&mut h, 4, "", "nameless", rect(500.0, 400.0, 300.0, 200.0));
    h.ok(json!({"op":"remove_source","window":3,"identity":identity(3),"keep_placeholder":true}));
    h.ok(json!({"op":"remove_source","window":4,"identity":identity(4),"keep_placeholder":true}));
    for (request, error) in [
        (json!({"Close":null}), "no focused window"),
        (json!({"Close":9}), "no window with id 9"),
        (json!({"Close":"nope"}), "no window matching 'nope'"),
        (json!({"Suspend":null}), "no focused window"),
        (json!({"Suspend":9}), "no window with id 9"),
        (json!({"Suspend":3}), "window is already suspended"),
        (
            json!({"Relaunch":null}),
            "no suspended window matching selector",
        ),
        (
            json!({"Relaunch":1}),
            "no suspended window matching selector",
        ),
        (
            json!({"Relaunch":"web"}),
            "no suspended window matching selector",
        ),
        (
            json!({"Relaunch":4}),
            "the app has no bundle identifier to relaunch",
        ),
    ] {
        assert_eq!(h.refused(request), error);
    }
    // An app id reaches the live window before the stand-in of the same app.
    assert_eq!(
        h.ipc(json!({"Close":"TERM"})),
        json!({"reply":{"Ok":"Ok"},"effects":[close_effect(1, 1)],"dirty":false,"navigation":null})
    );
    assert_eq!(h.lifecycle()["marks"], json!({"1":"close"}));
    // Suspend focuses its target first, without moving the camera, as
    // upstream's cmd_suspend does, then runs the action.
    let reply = h.ipc(json!({"Suspend":2}));
    assert_eq!(reply["reply"], json!({"Ok":"Ok"}));
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(reply["dirty"], true);
    assert_eq!(reply["effects"][0]["op"], "focus_native_window");
    assert_eq!(reply["effects"][0]["window"], 2);
    assert_eq!(reply["effects"][1], close_effect(2, 2));
    assert_eq!(h.focused(), 2);
    assert_eq!(h.lifecycle()["marks"], json!({"1":"close","2":"suspend"}));
    // Already focused: only the close.
    assert_eq!(
        h.ipc(json!({"Suspend":null})),
        json!({"reply":{"Ok":"Ok"},"effects":[close_effect(2, 2)],"dirty":false,"navigation":null})
    );
    assert_eq!(h.closed(2)["standin"], true);
    assert_eq!(h.closed(1)["standin"], false);
    // With no live window of the app left, the same selector is the stand-in.
    assert_eq!(
        h.ipc(json!({"Relaunch":"term"}))["effects"],
        json!([{"op":"launch","bundle_id":"app.term","window":3}])
    );
    // Close on a stand-in dismisses it.
    assert_eq!(
        h.ipc(json!({"Close":"term"})),
        json!({"reply":{"Ok":"Ok"},"effects":[],"dirty":true,"navigation":null})
    );
    assert_eq!(h.stack(), vec![4, 2]);
    // The focused stand-in, by no selector at all. Nothing is left in view
    // that could take the focus.
    assert_eq!(h.focused(), 2);
    assert_eq!(h.ipc(json!({"Close":null}))["reply"], json!({"Ok":"Ok"}));
    assert_eq!((h.stack(), h.focused()), (vec![4], Value::Null));
}

/// Four live windows focused in the order D, C, B, A. A and B are docked side
/// by side, C stands apart below them, D is far out of view.
fn neighbors(h: &mut Host) {
    put(h, 1, "app.a", "A", rect(100.0, 100.0, 300.0, 200.0));
    put(h, 2, "app.b", "B", rect(412.0, 100.0, 300.0, 200.0));
    put(h, 3, "app.c", "C", rect(100.0, 500.0, 200.0, 200.0));
    put(h, 4, "app.d", "D", rect(3000.0, 3000.0, 300.0, 200.0));
    for id in [4, 3, 2, 1] {
        h.observe_focus(id);
    }
    assert_eq!(h.snapshot()["focus"]["history"], json!([1, 2, 3, 4]));
}

#[test]
fn focus_follows_a_closed_window_through_upstreams_tiers() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    neighbors(&mut h);
    // A's snap neighbor is on screen: it is raised and focused, nothing flies.
    let reply = h.closed(1);
    assert_eq!(reply["standin"], false);
    focus_effect(&reply, 2, 2);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!((h.focused(), h.stack()), (json!(2), vec![4, 3, 2]));
    // B has no neighbor left: the most recent window still visible, C.
    let reply = h.closed(2);
    focus_effect(&reply, 3, 3);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(h.focused(), 3);
    // After C only D is left, out of view: nothing is focused rather than a
    // window nobody can see. The history and the stack are intact.
    assert_eq!(
        h.closed(3),
        json!({"standin":false,"effect":null,"navigation":null,"dirty":true})
    );
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["intent"], Value::Null);
    assert_eq!(snapshot["focus"]["pending_effect"], Value::Null);
    assert_eq!(snapshot["focus"]["history"], json!([4]));
    assert_eq!(h.stack(), vec![4]);
    assert_eq!(h.world(4), rect(3000.0, 3000.0, 300.0, 200.0));
    assert_eq!(h.camera(), point(0.0, 0.0));
    // Nothing focused is upstream's "no keyboard focus": the next close moves
    // the focus as well, to the visible window nearest the one that left.
    put(&mut h, 5, "app.e", "E", rect(100.0, 100.0, 300.0, 200.0));
    let reply = h.closed(4);
    focus_effect(&reply, 5, 5);
    assert_eq!(h.focused(), 5);

    // A close in the background leaves the focus where it is: C is neither
    // focused nor the last window focused.
    let mut h = running(&scratch, "");
    neighbors(&mut h);
    assert_eq!(
        h.closed(3),
        json!({"standin":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.focused(), 1);
    // A focused placeholder keeps the focus through an unrelated close, even
    // of the last window that had native focus.
    h.ok(json!({"op":"remove_source","window":2,"identity":identity(2),"keep_placeholder":true}));
    h.ok(json!({"op":"focus","window":2}));
    assert_eq!(h.snapshot()["focus"]["history"], json!([1, 4]));
    assert_eq!(h.closed(1)["effect"], Value::Null);
    assert_eq!(h.focused(), 2);
}

#[test]
fn auto_navigate_on_close_flies_to_a_follower_that_is_off_screen() {
    let scratch = Scratch::new();
    // Y is docked to X and hangs over the right edge of the view.
    let pair = |h: &mut Host| {
        put(h, 1, "app.x", "X", rect(100.0, 100.0, 300.0, 200.0));
        put(h, 2, "app.y", "Y", rect(412.0, 100.0, 700.0, 200.0));
        h.observe_focus(2);
        h.observe_focus(1);
    };
    // On, upstream's default: the camera flies until Y's center (762, 200) is
    // at the usable center, at the current zoom.
    let mut h = running(&scratch, "");
    pair(&mut h);
    let reply = h.closed(1);
    focus_effect(&reply, 2, 2);
    assert_eq!(armed(&reply), flight((262.0, -225.0), 1.0));
    assert_eq!(h.focused(), 2);
    // Off: the camera stays. Y is still partly visible, so it takes the focus.
    let off = "[navigation]\nauto_navigate_on_close = false\n";
    let mut h = running(&scratch, off);
    pair(&mut h);
    let reply = h.closed(1);
    focus_effect(&reply, 2, 2);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    // Off, and the neighbor wholly out of view: focus only moves to a visible
    // window, so here to none.
    let hidden = |h: &mut Host| {
        put(h, 1, "app.x", "X", rect(700.0, 100.0, 288.0, 200.0));
        put(h, 2, "app.y", "Y", rect(1000.0, 100.0, 300.0, 200.0));
        h.observe_focus(2);
        h.observe_focus(1);
    };
    let mut h = running(&scratch, off);
    hidden(&mut h);
    assert_eq!(
        h.closed(1),
        json!({"standin":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.focused(), Value::Null);
    // On, it is flown to.
    let mut h = running(&scratch, "");
    hidden(&mut h);
    let reply = h.closed(1);
    focus_effect(&reply, 2, 2);
    assert_eq!(armed(&reply), flight((650.0, -225.0), 1.0));
    // The active output can be named; it is checked.
    let mut h = running(&scratch, "");
    hidden(&mut h);
    let reply = h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    assert_eq!(armed(&reply), flight((650.0, -225.0), 1.0));
}

/// A shell that performs no native focus answers every request
/// `focus_logical`: a click, an IPC focus and a new window then give only
/// logical focus, nothing is ever reported as native focus, and the history
/// those answers fill is the one the tiers read, as `cycle-windows` does.
#[test]
fn a_close_follows_logical_focus_without_any_native_focus_report() {
    let scratch = Scratch::new();
    // Tier 1: the docked neighbor hanging over the right edge is flown to.
    let mut h = running(&scratch, "");
    put(&mut h, 1, "app.x", "X", rect(100.0, 100.0, 300.0, 200.0));
    put(&mut h, 2, "app.y", "Y", rect(412.0, 100.0, 700.0, 200.0));
    // The request alone promotes nothing; its answer does.
    let wanted = h.ok(json!({"op":"focus","window":2}))["effect"].clone();
    assert_eq!(h.snapshot()["focus"]["history"], json!([]));
    h.logical(&wanted);
    h.focus_logically(1);
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["history"], json!([1, 2]));
    assert_eq!(snapshot["focus"]["observed_native"], Value::Null);
    assert_eq!(snapshot["focus"].get("logical_history"), None);
    let reply = h.closed(1);
    focus_effect(&reply, 2, 2);
    assert_eq!(armed(&reply), flight((262.0, -225.0), 1.0));
    assert_eq!(h.snapshot()["focus"]["history"], json!([2]));
    // Tier 2: the most recent visible window, C, not the nearest one, B.
    let mut h = running(&scratch, "");
    put(&mut h, 1, "app.a", "A", rect(100.0, 100.0, 200.0, 150.0));
    put(&mut h, 2, "app.b", "B", rect(100.0, 400.0, 200.0, 150.0));
    put(&mut h, 3, "app.c", "C", rect(700.0, 550.0, 200.0, 150.0));
    for id in [2, 3, 1] {
        h.focus_logically(id);
    }
    let reply = h.closed(1);
    focus_effect(&reply, 3, 3);
    assert_eq!(reply["navigation"], Value::Null);
    // Two windows that appeared by themselves, each focus request answered:
    // the newer closes, the older one it overlapped is cut off by the view
    // and is flown to.
    let mut h = running(&scratch, "");
    for (wid, app, title) in [(1, "app.x", "X"), (2, "app.y", "Y")] {
        let mapped = appear(&mut h, wid, app, title, (300.0, 200.0));
        h.logical(&mapped["effect"]);
    }
    assert_eq!(h.snapshot()["focus"]["history"], json!([2, 1]));
    h.ok(json!({"op":"cancel_navigation","output":1}));
    assert_eq!(h.world(1), rect(350.0, 325.0, 300.0, 200.0));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(360.0,0.0)}));
    let reply = h.closed(2);
    focus_effect(&reply, 1, 1);
    assert_eq!(armed(&reply), flight((0.0, 0.0), 1.0));
    // A window that loses its source leaves the history, and a placeholder
    // never enters it: it has no request to answer.
    let mut h = running(&scratch, "");
    put(&mut h, 1, "app.x", "X", rect(100.0, 100.0, 300.0, 200.0));
    h.focus_logically(1);
    assert_eq!(h.snapshot()["focus"]["history"], json!([1]));
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(1),"keep_placeholder":true}));
    assert_eq!(
        h.ok(json!({"op":"focus","window":1})),
        json!({"effect":null})
    );
    assert_eq!(h.snapshot()["focus"]["history"], json!([]));
}

/// `cycle-windows` and the tiers after a close read one history. A held
/// cycle's steps leave it frozen and its release promotes the selection alone,
/// so the window that then closes is followed by the one focused before the
/// cycle, never by one the cycle only passed.
#[test]
fn cycling_and_a_close_read_the_same_focus_history() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    // Four windows in view, too far apart to be docked or to overlap.
    put(&mut h, 1, "app.a", "A", rect(50.0, 100.0, 200.0, 150.0));
    put(&mut h, 2, "app.b", "B", rect(400.0, 100.0, 200.0, 150.0));
    put(&mut h, 3, "app.c", "C", rect(750.0, 100.0, 200.0, 150.0));
    put(&mut h, 4, "app.d", "D", rect(50.0, 500.0, 200.0, 150.0));
    for id in [4, 3, 2, 1] {
        h.focus_logically(id);
    }
    assert_eq!(h.snapshot()["focus"]["history"], json!([1, 2, 3, 4]));
    // Held: A to B, C and D, every request answered as it is made.
    for selected in [2, 3, 4] {
        let reply =
            h.ok(json!({"op":"action","output":1,"action":"cycle-windows forward","held":true}));
        let step = reply["effects"][0].clone();
        assert_eq!(step["window"], selected, "{reply}");
        h.logical(&step);
        assert_eq!(h.snapshot()["focus"]["history"], json!([1, 2, 3, 4]));
    }
    h.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(h.snapshot()["focus"]["history"], json!([4, 1, 2, 3]));
    assert_eq!(h.focused(), 4);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    // D closes. Nothing is docked to it: the most recent window still in
    // view takes the focus, and that is A, not C.
    let reply = h.closed(4);
    focus_effect(&reply, 1, 1);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(h.snapshot()["focus"]["history"], json!([1, 2, 3]));
}

/// What a subscriber is sent follows the windows that come and go by
/// themselves: `state_event` hands out a new line when one is mapped, renamed,
/// replaced by a stand-in and dismissed, and none in between.
#[test]
fn the_state_event_follows_windows_that_appear_and_close() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "[session]\nsuspend_on_close = true\n");
    let event = |h: &mut Host| h.ok(json!({"op":"state_event","output":1}))["line"].clone();
    let windows = |line: &Value| {
        let event: Value = serde_json::from_str(line.as_str().expect("a changed line")).unwrap();
        event["State"]["windows"].clone()
    };
    assert_eq!(windows(&event(&mut h)), json!([]));
    assert_eq!(event(&mut h), Value::Null);
    // Mapped: placed under the focus placement point, and focused.
    appear(&mut h, 1, "app.term", "alpha", (400.0, 300.0));
    let mapped = json!({"id":1,"app_id":"app.term","title":"alpha","position":[500,-425],"size":[400,300],"is_focused":true,"is_widget":false,"suspended":false,"mode":"Normal"});
    assert_eq!(windows(&event(&mut h)), json!([mapped]));
    assert_eq!(event(&mut h), Value::Null);
    h.ok(json!({"op":"retitle","window":1,"identity":identity(1),"title":"beta"}));
    assert_eq!(windows(&event(&mut h))[0]["title"], "beta");
    // Closed under suspend_on_close: the stand-in is upstream's suspended window.
    assert_eq!(h.closed(1)["standin"], true);
    let standin = windows(&event(&mut h));
    assert_eq!(standin[0]["suspended"], true);
    assert_eq!(standin[0]["is_focused"], true);
    assert_eq!(event(&mut h), Value::Null);
    // Dismissed: gone from the state.
    assert_eq!(h.action("close-window")["dirty"], true);
    assert_eq!(windows(&event(&mut h)), json!([]));
    assert_eq!(event(&mut h), Value::Null);
}

/// The clock a host keeps current with `tick_navigation`, in whole seconds.
fn tick(h: &mut Host, seconds: u64) {
    h.ok(json!({"op":"tick_navigation","timestamp_ns":seconds * 1_000_000_000}));
}

#[test]
fn marks_and_pending_relaunches_lapse_on_the_navigation_clock() {
    let scratch = Scratch::new();
    // Expiry decides adoption; Center keeps the new-window frame independent
    // of the dormant stand-in that remains as an Auto placement anchor.
    let on = "window_placement = \"center\"\n[session]\nsuspend_on_close = true\n";
    // The command, then `later` seconds, then the window goes by itself: the
    // marks still in force and whether a stand-in is left.
    let closes = |toml: &str, action: &str, later: u64| {
        let mut h = running(&scratch, toml);
        put(
            &mut h,
            1,
            "app.term",
            "alpha",
            rect(100.0, 100.0, 300.0, 200.0),
        );
        h.ok(json!({"op":"focus","window":1}));
        tick(&mut h, 100);
        assert_eq!(h.action(action)["effects"], json!([close_effect(1, 1)]));
        tick(&mut h, 100 + later);
        (
            h.lifecycle()["marks"].clone(),
            h.closed(1)["standin"].clone(),
        )
    };
    // Upstream's ten seconds. Inside them the command decides; after them
    // the application refused, and a later close is the section's again.
    assert_eq!(
        closes(on, "close-window", 9),
        (json!({"1":"close"}), json!(false))
    );
    assert_eq!(closes(on, "close-window", 10), (json!({}), json!(true)));
    assert_eq!(
        closes("", "suspend-window", 9),
        (json!({"1":"suspend"}), json!(true))
    );
    assert_eq!(closes("", "suspend-window", 10), (json!({}), json!(false)));
    // The later of two commands starts its own ten seconds.
    let mut h = running(&scratch, "");
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    h.ok(json!({"op":"focus","window":1}));
    tick(&mut h, 100);
    h.action("close-window");
    tick(&mut h, 108);
    h.action("suspend-window");
    tick(&mut h, 117);
    assert_eq!(h.lifecycle()["marks"], json!({"1":"suspend"}));
    tick(&mut h, 118);
    assert_eq!(h.lifecycle()["marks"], json!({}));
    // A host that never ticks has no clock, and nothing lapses for it.
    let mut h = running(&scratch, on);
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    h.ok(json!({"op":"focus","window":1}));
    h.action("close-window");
    assert_eq!(h.snapshot()["navigation"]["clock_ns"], Value::Null);
    assert_eq!(h.closed(1)["standin"], false);

    // A stand-in of the terminal, and a relaunch asked at second 100.
    let relaunched = |later: u64| {
        let mut h = running(&scratch, on);
        put(
            &mut h,
            1,
            "app.term",
            "alpha",
            rect(100.0, 100.0, 300.0, 200.0),
        );
        assert_eq!(h.closed(1)["standin"], true);
        tick(&mut h, 100);
        assert_eq!(
            h.ipc(json!({"Relaunch":1}))["effects"],
            json!([{"op":"launch","bundle_id":"app.term","window":1}])
        );
        tick(&mut h, 100 + later);
        h
    };
    // Upstream's thirty seconds. Inside them the next window of the app takes
    // the slot. Upstream's identity match closes after five, because a token
    // covers the rest; there is no token here, so it stays open throughout.
    let mut h = relaunched(29);
    assert_eq!(h.lifecycle()["relaunching"], json!([1]));
    assert_eq!(
        appear(&mut h, 21, "app.term", "new shell", (400.0, 300.0)),
        ADOPTED(1)
    );
    assert_eq!(h.world(1), rect(100.0, 100.0, 300.0, 200.0));
    // After them the stand-in is dormant again: a window of that app is a new
    // one, placed, focused and flown to instead of taking a frame that may
    // be out of view.
    let mut h = relaunched(30);
    assert_eq!(h.lifecycle()["relaunching"], json!([]));
    let reply = appear(&mut h, 21, "app.term", "new shell", (400.0, 300.0));
    assert_eq!(
        (&reply["window"], &reply["adopted"]),
        (&json!(2), &json!(false))
    );
    assert_eq!(h.world(2), rect(300.0, 275.0, 400.0, 300.0));
    focus_effect(&reply, 2, 21);
    assert_eq!(armed(&reply), flight((0.0, 0.0), 1.0));
    assert_eq!(h.lifecycle()["standins"], json!([1]));
    // It can be asked for again, and that request has its own thirty seconds.
    assert_eq!(
        h.ipc(json!({"Relaunch":1}))["effects"],
        json!([{"op":"launch","bundle_id":"app.term","window":1}])
    );
    tick(&mut h, 159);
    assert_eq!(h.lifecycle()["relaunching"], json!([1]));
    tick(&mut h, 160);
    assert_eq!(h.lifecycle()["relaunching"], json!([]));
}

#[test]
fn a_reopened_canvas_ends_its_own_pass() {
    let scratch = Scratch::new();
    // Placement is incidental to ending the adoption pass. Specify Center
    // for the fixed new-window coordinates below, with both restore policies.
    for (toml, ended) in [
        (
            "window_placement = \"center\"\n",
            json!({"dropped":[1],"standins":[],"dirty":true}),
        ),
        (
            "window_placement = \"center\"\n[session]\nrestore_windows = true\n",
            json!({"dropped":[],"standins":[1],"dirty":true}),
        ),
    ] {
        let mut h = running(&scratch, toml);
        put(
            &mut h,
            1,
            "app.web",
            "GitHub",
            rect(5000.0, 5000.0, 800.0, 600.0),
        );
        put(
            &mut h,
            2,
            "app.web",
            "Docs",
            rect(100.0, 100.0, 300.0, 200.0),
        );
        put(
            &mut h,
            3,
            "app.term",
            "zsh",
            rect(500.0, 100.0, 300.0, 200.0),
        );
        // The canvas closes without a quit, as Return to desktop closed it
        // while a normal run had that button: every source is detached,
        // every slot kept.
        for id in [1, 2, 3] {
            h.ok(json!({"op":"remove_source","window":id,"identity":identity(id),"keep_placeholder":true}));
        }
        // The GitHub window closes while the canvas is closed. Reopened, the
        // shell reports the two that are left and ends its pass: the slot
        // nothing took belongs to a window that is gone.
        assert_eq!(
            appear(&mut h, 2, "app.web", "Docs", (300.0, 200.0)),
            ADOPTED(2)
        );
        assert_eq!(
            appear(&mut h, 3, "app.term", "zsh", (300.0, 200.0)),
            ADOPTED(3)
        );
        assert_eq!(h.ok(json!({"op":"adoption_complete"})), ended, "{toml}");
        assert_eq!(h.lifecycle()["settled"], true);
        // So the next window of that app is a new one: placed, focused and
        // flown to, not adopted into a dead window's frame out of view.
        let reply = appear(&mut h, 4, "app.web", "Start Page", (400.0, 300.0));
        assert_eq!(
            (&reply["window"], &reply["adopted"]),
            (&json!(4), &json!(false)),
            "{toml}"
        );
        assert_eq!(h.world(4), rect(300.0, 275.0, 400.0, 300.0));
        focus_effect(&reply, 4, 4);
        assert_eq!(armed(&reply), flight((0.0, 0.0), 1.0));
    }
}

#[test]
fn slots_of_windows_that_exist_off_screen_keep_waiting_for_them() {
    let scratch = Scratch::new();
    let scene = saved_session(&scratch);
    // Minimized, hidden or on another Space: the terminal's "beta" window and
    // the notes window exist but could not be offered. A window named twice
    // holds one slot, and names no slot answers to are ignored.
    let present = json!([
        {"bundle_id":"app.term","title":"beta"},
        {"bundle_id":"app.notes","title":"todo"},
        {"bundle_id":"app.notes","title":"todo"},
        {"bundle_id":"app.files","title":"docs"},
        {"bundle_id":"","title":"alpha"},
    ]);
    // Placement is incidental here. macOS defaults omitted placement to auto;
    // pin center so these assertions continue to isolate saved-slot matching.
    for (toml, ended, later) in [
        (
            "window_placement = \"center\"\n",
            json!({"dropped":[1,3],"standins":[],"dirty":true}),
            json!({"dropped":[4],"standins":[],"dirty":true}),
        ),
        (
            "window_placement = \"center\"\n[session]\nrestore_windows = true\n",
            json!({"dropped":[],"standins":[1,3],"dirty":true}),
            json!({"dropped":[],"standins":[4],"dirty":true}),
        ),
    ] {
        let mut h = relaunched(&scratch, &scene, toml);
        // Their slots are neither dropped nor made stand-ins.
        assert_eq!(
            h.ok(json!({"op":"adoption_complete","present":present})),
            ended,
            "{toml}"
        );
        assert_eq!(h.lifecycle()["held"], json!([2, 4]));
        assert_eq!(h.focused(), 2);
        // A held slot answers to its own title only: another window of the
        // app is a new one, placed, focused and flown to.
        let reply = appear(&mut h, 21, "app.term", "gamma", (400.0, 300.0));
        assert_eq!(
            (&reply["window"], &reply["adopted"]),
            (&json!(5), &json!(false)),
            "{toml}"
        );
        assert_eq!(h.world(5), rect(300.0, 275.0, 400.0, 300.0));
        focus_effect(&reply, 5, 21);
        assert_eq!(armed(&reply), flight((0.0, 0.0), 1.0));
        // The window itself, once it is on screen, returns to its frame:
        // nobody opened it just now, so nothing is focused or flown to.
        assert_eq!(
            appear(&mut h, 22, "app.term", "beta", (640.0, 480.0)),
            ADOPTED(2)
        );
        assert_eq!(h.world(2), rect(500.0, 100.0, 300.0, 200.0));
        assert_eq!(h.lifecycle()["held"], json!([4]));
        // The next pass says afresh what exists. The notes window is no longer
        // named: it closed while it was off screen.
        assert_eq!(h.ok(json!({"op":"adoption_complete"})), later, "{toml}");
        assert_eq!(h.lifecycle().get("held"), None);
    }
    // Unheld, a retitled window takes the lowest free slot of its app.
    let mut h = relaunched(&scratch, &scene, "");
    assert_eq!(
        appear(&mut h, 21, "app.term", "gamma", (640.0, 480.0)),
        ADOPTED(1)
    );
    // `present` is checked like any command field.
    let bad = h.error(json!({"op":"adoption_complete","present":[{"bundle_id":"app.term"}]}));
    assert!(bad.contains("title"), "{bad}");
}

#[test]
fn a_refused_config_file_decides_nothing_about_the_saved_slots() {
    let scratch = Scratch::new();
    let scene = saved_session(&scratch);
    let config = scratch.path("config.toml");
    let all = json!({"settled":true,"standins":[],"relaunching":[],"marks":{}});
    // The shell's order: the config, then the scene, then the output. The
    // file asks for restore_windows and has a typo elsewhere.
    std::fs::write(
        &config,
        "[session]\nrestore_windows = true\n\n[zoom]\nstep = \n",
    )
    .unwrap();
    let mut h = Host::new();
    let reply = h.ok(json!({"op":"load_config","path":config}));
    assert_eq!(reply["errors"].as_array().unwrap().len(), 1, "{reply}");
    h.ok(json!({"op":"load","path":scene}));
    open(&mut h);
    // The built-in defaults are in force and do not speak for the file:
    // nothing is dropped, nothing is made a stand-in, nothing is to be saved.
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[],"dirty":false})
    );
    assert_eq!(h.stack(), vec![1, 3, 4, 2]);
    assert_eq!(h.lifecycle(), all);
    // The launch pass is over all the same: a slot still takes its window
    // back, and a window with no slot is a new one.
    assert_eq!(
        appear(&mut h, 21, "app.web", "docs", (640.0, 480.0)),
        ADOPTED(3)
    );
    let reply = appear(&mut h, 22, "app.files", "Desktop", (300.0, 200.0));
    assert_eq!(reply["adopted"], false);
    focus_effect(&reply, 5, 22);
    let saved = scratch.path("next.json");
    h.ok(json!({"op":"save","path":saved}));
    // Once the file is accepted the next pass decides, in this run
    let fixed = "[session]\nrestore_windows = true\n";
    std::fs::write(&config, fixed).unwrap();
    let reply = h.ok(json!({"op":"load_config","path":config}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[1,2,4],"dirty":true})
    );
    // or at the next launch, where every slot was kept for it.
    let mut h = Host::new();
    let reply = h.ok(json!({"op":"load_config","path":config}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    h.ok(json!({"op":"load","path":saved}));
    open(&mut h);
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[1,2,3,4,5],"dirty":true})
    );
    // No file at all is the built-in defaults by choice: the slots go.
    std::fs::remove_file(&config).unwrap();
    let mut h = Host::new();
    let reply = h.ok(json!({"op":"load_config","path":config}));
    assert_eq!(
        (&reply["exists"], &reply["errors"]),
        (&json!(false), &json!([]))
    );
    h.ok(json!({"op":"load","path":saved}));
    open(&mut h);
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[1,2,3,4,5],"standins":[],"dirty":true})
    );
}

#[test]
fn a_drag_outlives_the_close_of_a_window_it_does_not_hold() {
    let scratch = Scratch::new();
    let drag = |window: u64, group: bool| json!({"op":"begin_drag","window":window,"output":1,"group":group});
    let to = |x: f64, y: f64| json!({"op":"gesture_to","screen_delta":point(x,y)});
    // A and B are docked; C and D stand apart, out of snapping reach.
    let mut h = running(&scratch, "");
    put(&mut h, 1, "app.a", "A", rect(100.0, 100.0, 300.0, 200.0));
    put(&mut h, 2, "app.b", "B", rect(412.0, 100.0, 300.0, 200.0));
    put(&mut h, 3, "app.c", "C", rect(100.0, 500.0, 200.0, 200.0));
    put(&mut h, 4, "app.d", "D", rect(600.0, 500.0, 200.0, 200.0));
    h.ok(json!({"op":"focus","window":1}));
    h.ok(drag(3, false));
    h.ok(to(30.0, 40.0));
    assert_eq!(h.world(3), rect(130.0, 540.0, 200.0, 200.0));
    // D closes by itself: upstream ends no other window's grab.
    assert_eq!(h.closed(4)["standin"], false);
    h.ok(to(60.0, 40.0));
    assert_eq!(h.world(3), rect(160.0, 540.0, 200.0, 200.0));
    // The dragged window closes: the drag is over.
    h.closed(3);
    assert_eq!(h.error(to(90.0, 40.0)), "no active gesture");
    // A group drag holds every window of the cluster: one of them closing
    // ends it too.
    h.ok(drag(1, true));
    h.ok(to(0.0, -20.0));
    assert_eq!(h.world(1), rect(100.0, 80.0, 300.0, 200.0));
    assert_eq!(h.world(2), rect(412.0, 80.0, 300.0, 200.0));
    h.closed(2);
    assert_eq!(h.error(to(0.0, -40.0)), "no active gesture");

    // A resize is held the same way: it outlives another window's close and
    // ends with its own window's.
    h.ok(json!({"op":"end_gesture"}));
    h.ok(json!({"op":"begin_resize","window":1,"output":1,"edges":"right"}));
    h.ok(to(20.0, 0.0));
    put(&mut h, 5, "app.e", "E", rect(600.0, 500.0, 200.0, 200.0));
    h.closed(5);
    h.ok(to(40.0, 0.0));
    assert_eq!(h.world(1), rect(100.0, 80.0, 340.0, 200.0));
    h.closed(1);
    assert_eq!(h.error(to(60.0, 0.0)), "no active gesture");

    // A stand-in taking the place of the dragged window ends the drag; one
    // taking the place of another window does not.
    let mut h = running(&scratch, "[session]\nsuspend_on_close = true\n");
    put(&mut h, 1, "app.a", "A", rect(100.0, 100.0, 300.0, 200.0));
    put(&mut h, 2, "app.b", "B", rect(600.0, 500.0, 200.0, 200.0));
    h.ok(drag(1, false));
    assert_eq!(h.closed(2)["standin"], true);
    h.ok(to(0.0, -20.0));
    assert_eq!(h.closed(1)["standin"], true);
    assert_eq!(h.error(to(0.0, -40.0)), "no active gesture");

    // A drag in progress keeps its camera, as when a window appears: the
    // follower out of view is focused and not flown to.
    let mut h = running(&scratch, "");
    put(&mut h, 1, "app.x", "X", rect(700.0, 100.0, 288.0, 200.0));
    put(&mut h, 2, "app.y", "Y", rect(1000.0, 100.0, 300.0, 200.0));
    put(&mut h, 3, "app.z", "Z", rect(100.0, 500.0, 200.0, 150.0));
    h.focus_logically(2);
    h.focus_logically(1);
    // The press that begins the drag raises and focuses Z, as upstream's
    // does; X then takes the focus back while Z is still held.
    focus_effect(&h.ok(drag(3, false)), 3, 3);
    assert_eq!(h.snapshot()["focus"]["intent"], 3);
    h.focus_logically(1);
    let reply = h.closed(1);
    focus_effect(&reply, 2, 2);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    h.ok(to(0.0, 20.0));
    assert_eq!(h.world(3), rect(100.0, 520.0, 200.0, 150.0));
}

#[test]
fn retitle_follows_the_window_and_is_saved_for_the_next_launch() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    put(
        &mut h,
        1,
        "app.term",
        "alpha",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.term",
        "beta",
        rect(500.0, 100.0, 300.0, 200.0),
    );
    let retitle =
        |title: &str| json!({"op":"retitle","window":2,"identity":identity(2),"title":title});
    assert_eq!(h.ok(retitle("build log")), json!({"dirty":true}));
    assert_eq!(h.ok(retitle("build log")), json!({"dirty":false}));
    assert_eq!(h.window(2)["metadata"]["title"], "build log");
    let state = h.ipc(json!("State"))["reply"]["Ok"]["State"]["windows"].clone();
    assert_eq!(state[1]["title"], "build log");
    assert_eq!(
        h.error(json!({"op":"retitle","window":2,"identity":identity(9),"title":"x"})),
        "stale source identity"
    );
    assert_eq!(
        h.error(retitle("nul\0")),
        "invalid source metadata or rectangle"
    );
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(1),"keep_placeholder":true}));
    assert_eq!(
        h.error(json!({"op":"retitle","window":1,"identity":identity(1),"title":"x"})),
        "unbound source"
    );
    // The new title is what the slot answers to at the next launch.
    let path = scratch.path("scene.json");
    h.ok(json!({"op":"save","path":path}));
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":path}));
    open(&mut h);
    assert_eq!(
        appear(&mut h, 21, "app.term", "build log", (300.0, 200.0)),
        ADOPTED(2)
    );
}

// Event delivery (LIFECYCLE.md). A shell that follows native windows by their
// events, with a slower poll behind them, reports one change twice (the event,
// then the poll), late (after the window it is about has gone) and early
// (before the window is bound), and in bursts. `Host::error` asserts that a
// refused report left the whole snapshot as it was: the scene, the focus and
// its pending request, the focus history, the flights, `lifecycle_events` and
// the render revision.

/// A close reported by its event and again by the poll behind it, for a window
/// that was never bound, and for a slot whose window is not back: only the
/// first report of a bound window does anything.
#[test]
fn a_close_reported_twice_or_for_no_bound_window_changes_nothing() {
    let scratch = Scratch::new();
    let report = |window: u64, output: Value| json!({"op":"window_closed","window":window,"identity":identity(window),"output":output});
    for (toml, standin) in [("", false), ("[session]\nsuspend_on_close = true\n", true)] {
        let mut h = running(&scratch, toml);
        // B, and A docked beside it; A holds the focus, B held it before.
        put(&mut h, 1, "app.a", "A", rect(100.0, 100.0, 300.0, 200.0));
        put(&mut h, 2, "app.b", "B", rect(412.0, 100.0, 300.0, 200.0));
        h.observe_focus(2);
        h.observe_focus(1);
        let revision = h.snapshot()["render"]["revision"].clone();
        let reply = h.ok(report(1, json!(1)));
        // What the one close did: a stand-in that keeps the focus, or the
        // window gone and its docked neighbor asked to take the focus.
        if standin {
            assert_eq!(
                reply,
                json!({"standin":true,"effect":null,"navigation":null,"dirty":true})
            );
            assert_eq!(
                h.events(),
                json!([logged(1, 1, "close_to_standin", json!(1))])
            );
            assert_eq!((h.focused(), h.stack()), (json!(1), vec![2, 1]));
        } else {
            assert_eq!(reply["standin"], false);
            focus_effect(&reply, 2, 2);
            assert_eq!(h.events(), json!([logged(1, 1, "close", json!(1))]));
            assert_eq!((h.focused(), h.stack()), (json!(2), vec![2]));
        }
        // The same close again, with the active output and without.
        for again in [report(1, json!(1)), report(1, Value::Null)] {
            assert_eq!(h.error(again), "unbound source", "{toml}");
        }
        // The follower was asked once, and that request is still the one to
        // answer: the second report neither moved the focus nor dropped it.
        if !standin {
            assert_eq!(h.snapshot()["focus"]["pending_effect"], reply["effect"]);
            h.logical(&reply["effect"]);
            assert_eq!(h.snapshot()["focus"]["history"], json!([2]));
        }
        // A close for a window that was never bound,
        assert_eq!(h.error(report(9, json!(1))), "unbound source");
        // and for a slot whose source was lost while its window is still
        // there: the slot keeps waiting.
        h.ok(
            json!({"op":"remove_source","window":2,"identity":identity(2),"keep_placeholder":true}),
        );
        assert_eq!(h.error(report(2, json!(1))), "unbound source");
        assert!(h.stack().contains(&2));
        assert_eq!(h.snapshot()["render"]["revision"], revision);
        assert_eq!(h.events().as_array().unwrap().len(), 1);
    }

    // A close reported late for a slot that another native window has taken
    // since names a binding that is no longer the slot's.
    let mut h = running(&scratch, "[session]\nsuspend_on_close = true\n");
    appear(&mut h, 1, "app.mail", "Inbox", (300.0, 200.0));
    assert_eq!(h.closed(1)["standin"], true);
    h.ipc(json!({"Relaunch":1}));
    assert_eq!(
        appear(&mut h, 21, "app.mail", "Inbox", (300.0, 200.0))["window"],
        1
    );
    assert_eq!(h.error(report(1, json!(1))), "stale source identity");
    // So does a title or a frame still on its way for the window that closed.
    for late in [
        json!({"op":"retitle","window":1,"identity":identity(1),"title":"late"}),
        json!({"op":"observe","window":1,"identity":identity(1),"source_rect":rect(0.0,0.0,300.0,200.0),"buffer":{"width":200,"height":100}}),
    ] {
        assert_eq!(h.error(late), "stale source identity");
    }
    assert_eq!(h.window(1)["source"]["identity"], identity(21));
}

/// A title or a frame reported for a window that is not bound, before its
/// attach or just after its close, is refused and nothing of it is kept. For
/// a bound window the same title or frame twice changes nothing the second
/// time.
#[test]
fn a_title_or_a_frame_for_a_window_that_is_not_bound_is_refused() {
    let scratch = Scratch::new();
    let retitle =
        |title: &str| json!({"op":"retitle","window":1,"identity":identity(1),"title":title});
    let observe = |width: f64| json!({"op":"observe","window":1,"identity":identity(1),"source_rect":rect(10.0,20.0,width,240.0),"buffer":{"width":640,"height":480}});
    for (toml, standin) in [("", false), ("[session]\nsuspend_on_close = true\n", true)] {
        let mut h = running(&scratch, toml);
        // Early: the report outran the attach, and there is no window 1 yet.
        for early in [retitle("early"), observe(500.0)] {
            assert_eq!(h.error(early), "unbound source", "{toml}");
        }
        // The attach brings the title and the frame the window has by then.
        assert_eq!(
            appear(&mut h, 1, "app.term", "alpha", (300.0, 200.0))["window"],
            1
        );
        let window = h.window(1);
        assert_eq!(window["metadata"]["title"], "alpha");
        assert_eq!(
            window["source"]["observed_rect"],
            rect(NATIVE.0, NATIVE.1, 300.0, 200.0)
        );
        // Bound: each report is taken once, and the same again, by the poll
        // behind the event, changes nothing and asks for no save.
        assert_eq!(h.ok(retitle("build")), json!({"dirty":true}));
        assert_eq!(h.ok(observe(320.0)), json!({}));
        let once = h.snapshot();
        assert_eq!(h.ok(retitle("build")), json!({"dirty":false}));
        assert_eq!(h.ok(observe(320.0)), json!({}));
        assert_eq!(h.snapshot(), once);
        assert_eq!(
            h.window(1)["source"]["observed_rect"],
            rect(10.0, 20.0, 320.0, 240.0)
        );
        // Late: the window has just closed.
        assert_eq!(h.closed(1)["standin"], standin);
        for late in [retitle("gone"), observe(400.0)] {
            assert_eq!(h.error(late), "unbound source", "{toml}");
        }
        // A stand-in keeps the title its window had when it closed.
        match standin {
            true => assert_eq!(h.window(1)["metadata"]["title"], "build"),
            false => assert_eq!(h.stack(), Vec::<u64>::new()),
        }
    }
}

/// One native identity closes and is reported again: an application that
/// keeps its window object shows the same window number when the window is
/// opened again. Nothing remembers the identity that closed, so the window
/// is a new one by the rules every new window follows, under a new binding.
#[test]
fn a_native_identity_that_closed_and_returns_is_a_new_window() {
    let scratch = Scratch::new();
    let offer = json!({"op":"attach","identity":identity(1),"bundle_id":"app.mail","title":"Inbox","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,300.0,200.0),"output":1,"pointer":point(POINTER.0,POINTER.1)});
    let again = |h: &mut Host| h.ok(offer.clone());

    // No stand-in: the window left, and it comes back as a new window.
    let mut h = running(&scratch, "");
    let first = again(&mut h);
    assert_eq!(
        (&first["window"], &first["adopted"]),
        (&json!(1), &json!(false))
    );
    assert_eq!(h.world(1), rect(350.0, 325.0, 300.0, 200.0));
    // While it is bound, the same window offered again, by an event and by
    // the poll behind it, is refused.
    assert_eq!(h.error(offer.clone()), "source already attached");
    assert_eq!(
        h.closed(1),
        json!({"standin":false,"effect":null,"navigation":null,"dirty":true})
    );
    let second = again(&mut h);
    assert_eq!(
        (&second["window"], &second["adopted"]),
        (&json!(2), &json!(false))
    );
    // Placed where the policy puts a new window, focused and flown to.
    assert_eq!(h.world(2), rect(350.0, 325.0, 300.0, 200.0));
    focus_effect(&second, 2, 1);
    assert_eq!(armed(&second), flight((0.0, 0.0), 1.0));
    assert_eq!(
        h.events(),
        json!([
            logged(1, 1, "open", json!(1)),
            logged(2, 1, "close", Value::Null),
            logged(3, 2, "open", json!(1)),
        ])
    );
    // The binding is a new one, so what the first one was asked, and what is
    // still reported for it, is stale.
    assert_eq!(
        (
            &first["effect"]["generation"],
            &second["effect"]["generation"]
        ),
        (&json!(1), &json!(2))
    );
    assert_eq!(
        h.error(json!({"op":"focus_result","effect_id":first["effect"]["effect_id"],"window":1,"identity":identity(1),"generation":1,"success":true})),
        "stale or superseded focus result"
    );
    assert_eq!(
        h.error(native(2, &identity(1), &json!(1))),
        "stale binding generation"
    );

    // A dormant stand-in is never adopted just because its native identity
    // returned. With the Mac default Auto policy, the 300 x 200 anchor is wider
    // than tall, so placement grows downward: y = 325 + 200 + snap.gap (12).
    // Explicit Center instead cascades one 25-point title-bar step diagonally.
    // Navigation puts each new center at the usable center (500, 425), so its
    // camera is the new origin minus (350, 325). Neither policy reads NATIVE.
    let on = "[session]\nsuspend_on_close = true\n";
    for (placement, at, camera) in [
        ("", (350.0, 537.0), (0.0, 212.0)),
        (
            "window_placement = \"center\"\n",
            (375.0, 350.0),
            (25.0, 25.0),
        ),
    ] {
        let mut h = running(&scratch, &format!("{placement}{on}"));
        again(&mut h);
        assert_eq!(h.closed(1)["standin"], true);
        let second = again(&mut h);
        assert_eq!(
            (&second["window"], &second["adopted"]),
            (&json!(2), &json!(false))
        );
        assert_eq!(h.world(2), rect(at.0, at.1, 300.0, 200.0));
        focus_effect(&second, 2, 1);
        assert_eq!(armed(&second), flight(camera, 1.0));
        assert_eq!(h.window(2)["source"]["generation"], 2);
        assert_eq!(
            h.window(2)["source"]["observed_rect"],
            rect(NATIVE.0, NATIVE.1, 300.0, 200.0)
        );
        assert_eq!(h.world(1), rect(350.0, 325.0, 300.0, 200.0));
        assert_eq!(h.window(1)["source"], Value::Null);
        assert_eq!(h.lifecycle()["standins"], json!([1]));
        assert_eq!(h.stack(), vec![1, 2]);
    }

    // Relaunched through its stand-in, the same identity takes the slot back
    // as any window of that app would: upstream's adoption, and its crossfade.
    let mut h = running(&scratch, on);
    again(&mut h);
    assert_eq!(h.closed(1)["standin"], true);
    assert_eq!(
        h.ipc(json!({"Relaunch":1}))["effects"],
        json!([{"op":"launch","bundle_id":"app.mail","window":1}])
    );
    let back = again(&mut h);
    assert_eq!(
        (&back["window"], &back["adopted"]),
        (&json!(1), &json!(true))
    );
    // The stand-in held the focus, so the window asks for it.
    focus_effect(&back, 1, 1);
    assert_eq!(back["navigation"], Value::Null);
    assert_eq!(h.window(1)["source"]["generation"], 2);
    assert_eq!(
        h.lifecycle(),
        json!({"settled":true,"standins":[],"relaunching":[],"marks":{}})
    );
    assert_eq!(
        h.events(),
        json!([
            logged(1, 1, "open", json!(1)),
            logged(2, 1, "close_to_standin", Value::Null),
            logged(3, 1, "standin_adopted", json!(1)),
        ])
    );
}

/// Native focus reported for a window that is not bound yet, twice for one
/// change, and for a window that has closed. The early and the late report
/// are refused; the repeated one is upstream's "already active", while the
/// window is on screen and while the flight the first report armed is still
/// bringing it there.
#[test]
fn native_focus_reported_early_twice_or_late_is_recorded_once() {
    let scratch = Scratch::new();
    let already = json!({"effect":null,"navigation":null,"dirty":false});
    let mut h = running(&scratch, "");
    // Early: the report outran the attach. There is no window 1 to name.
    assert_eq!(
        h.error(native(1, &identity(1), &json!(1))),
        "unknown window"
    );
    // The attach asks for the focus itself. The report, made again now that
    // the window is bound, is the focus: the request is dropped, the window
    // enters the focus history, and nothing moves, the window being in view.
    let mapped = appear(&mut h, 1, "app.a", "A", (300.0, 200.0));
    focus_effect(&mapped, 1, 1);
    assert_eq!(
        h.native(1),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    let focus = h.snapshot()["focus"].clone();
    assert_eq!(focus["pending_effect"], Value::Null);
    assert_eq!(focus["observed_native"]["window"], 1);
    assert_eq!(focus["history"], json!([1]));
    // The adapter's answer to the request the report superseded comes late.
    let asked = &mapped["effect"];
    assert_eq!(
        h.error(json!({"op":"focus_result","effect_id":asked["effect_id"],"window":1,"identity":identity(1),"generation":asked["generation"],"success":true})),
        "stale or superseded focus result"
    );
    // Twice, the window on screen: the second report asks for what holds.
    let once = h.snapshot();
    assert_eq!(h.native(1), already);
    assert_eq!(h.snapshot(), once);

    // B is far out of view: the report flies the camera until B's center
    // (5150, 5100) is at the usable center.
    h.ok(json!({"op":"cancel_navigation","output":1}));
    put(&mut h, 2, "app.b", "B", rect(5000.0, 5000.0, 300.0, 200.0));
    let reply = h.native(2);
    assert_eq!(reply["effect"], Value::Null);
    assert_eq!(armed(&reply), flight((4650.0, 4675.0), 1.0));
    assert_eq!(h.focused(), 2);
    assert_eq!(h.snapshot()["focus"]["history"], json!([2, 1]));
    // Twice, B still out of view and that flight in the air: before its
    // first frame,
    let once = h.snapshot();
    assert_eq!(h.native(2), already);
    assert_eq!(h.snapshot(), once);
    // and after two, the camera on its way and B not yet in view.
    h.ok(json!({"op":"tick_navigation","timestamp_ns":1_000_000_000u64}));
    h.ok(json!({"op":"tick_navigation","timestamp_ns":1_016_000_000u64}));
    let flying = h.snapshot();
    assert_ne!(flying["outputs"][0]["camera"], point(0.0, 0.0));
    assert!(flying["outputs"][0]["camera"]["x"].as_f64().unwrap() < 4000.0);
    assert_eq!(h.native(2), already);
    assert_eq!(h.snapshot(), flying);
    // Once the user has stopped the flight, the report is upstream's
    // activation of a window that is off screen: there is somewhere to go.
    h.ok(json!({"op":"cancel_navigation","output":1}));
    let reply = h.native(2);
    assert_eq!(armed(&reply), flight((4650.0, 4675.0), 1.0));
    assert_eq!(h.snapshot()["focus"]["history"], json!([2, 1]));

    // Late: B has closed and left the canvas.
    let binding = h.window(2)["source"].clone();
    assert_eq!(h.closed(2)["standin"], false);
    assert_eq!(
        h.error(native(2, &binding["identity"], &binding["generation"])),
        "unknown window"
    );
    // Late for a window whose stand-in kept the focus: a stand-in cannot
    // hold native focus, and the logical focus stays where it is.
    let mut h = running(&scratch, "[session]\nsuspend_on_close = true\n");
    put(&mut h, 1, "app.a", "A", rect(100.0, 100.0, 300.0, 200.0));
    h.native(1);
    let binding = h.window(1)["source"].clone();
    assert_eq!(h.closed(1)["standin"], true);
    assert_eq!(
        h.error(native(1, &binding["identity"], &binding["generation"])),
        "unbound source"
    );
    assert_eq!(h.focused(), 1);
    assert_eq!(h.snapshot()["focus"]["observed_native"], Value::Null);
}

/// An application quits: its windows close in a burst, and what was asked of
/// one of them in between is answered after it has gone. Each close is taken
/// once, the focus ends on the window that is left, and the late answers are
/// refused.
#[test]
fn an_application_that_quits_closes_its_windows_in_a_burst() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    // Two windows of one app docked side by side, and another app's below.
    put(
        &mut h,
        1,
        "app.mail",
        "Inbox",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        2,
        "app.mail",
        "Draft",
        rect(412.0, 100.0, 300.0, 200.0),
    );
    put(
        &mut h,
        3,
        "app.term",
        "zsh",
        rect(100.0, 500.0, 200.0, 200.0),
    );
    for id in [3, 2, 1] {
        h.observe_focus(id);
    }
    // The first close hands the focus to the docked sibling, which is dying.
    let first = h.closed(1);
    focus_effect(&first, 2, 2);
    let binding = h.window(2)["source"].clone();
    // The sibling closes before that request is answered: the request goes
    // with it, and the focus moves on to the window still in view.
    let second = h.closed(2);
    focus_effect(&second, 3, 3);
    assert_eq!(h.snapshot()["focus"]["pending_effect"], second["effect"]);
    // What was in flight for the sibling arrives now: the adapter's failure,
    // a native focus report, a title, a frame and its close once more.
    let asked = &first["effect"];
    for (late, error) in [
        (
            json!({"op":"focus_result","effect_id":asked["effect_id"],"window":2,"identity":identity(2),"generation":asked["generation"],"success":false}),
            "stale or superseded focus result",
        ),
        (
            native(2, &binding["identity"], &binding["generation"]),
            "unknown window",
        ),
        (
            json!({"op":"retitle","window":2,"identity":identity(2),"title":""}),
            "unbound source",
        ),
        (
            json!({"op":"observe","window":2,"identity":identity(2),"source_rect":rect(0.0,0.0,300.0,200.0),"buffer":{"width":200,"height":100}}),
            "unbound source",
        ),
        (
            json!({"op":"window_closed","window":2,"identity":identity(2)}),
            "unbound source",
        ),
    ] {
        assert_eq!(h.error(late), error);
    }
    // The survivor's request is still the one to answer.
    h.logical(&second["effect"]);
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["intent"], 3);
    assert_eq!(snapshot["focus"]["history"], json!([3]));
    assert_eq!(h.stack(), vec![3]);
    assert_eq!(
        h.events(),
        json!([
            logged(1, 1, "close", Value::Null),
            logged(2, 2, "close", Value::Null),
        ])
    );
}

/// macOS activates another window when one closes, and the report of that
/// focus arrives before the close or after it. Either way the focus ends on
/// the window macOS chose, one close is logged and the history is the same;
/// only in the order that reports the close first has the controller already
/// picked and raised a follower of its own.
#[test]
fn a_close_and_the_native_focus_that_follows_it_agree_in_either_order() {
    let scratch = Scratch::new();
    // W with X docked beside it, Y and F apart; F was focused first, then X,
    // then Y, then W: bottom to top the stack is F, X, Y, W.
    let desk = |h: &mut Host| {
        put(h, 1, "app.w", "W", rect(100.0, 100.0, 300.0, 200.0));
        put(h, 2, "app.x", "X", rect(412.0, 100.0, 300.0, 200.0));
        put(h, 3, "app.y", "Y", rect(100.0, 500.0, 200.0, 200.0));
        put(h, 4, "app.f", "F", rect(600.0, 500.0, 200.0, 200.0));
        for id in [4, 2, 3, 1] {
            h.observe_focus(id);
        }
        assert_eq!(h.stack(), vec![4, 2, 3, 1]);
        assert_eq!(h.snapshot()["focus"]["history"], json!([1, 3, 2, 4]));
    };
    let settled = |h: &mut Host| {
        let snapshot = h.snapshot();
        let focus = &snapshot["focus"];
        json!([
            snapshot["focus"]["intent"],
            focus["observed_native"]["window"],
            focus["pending_effect"],
            focus["history"],
            snapshot["lifecycle_events"],
            snapshot["navigation"]["flights"]
        ])
    };
    let chosen = json!([
        4,
        4,
        null,
        [4, 3, 2],
        [logged(1, 1, "close", Value::Null)],
        {}
    ]);
    // The close first: X, docked to W, is raised and asked to take the focus;
    // then macOS's choice replaces it, and the request for X is dropped.
    let mut h = running(&scratch, "");
    desk(&mut h);
    let reply = h.closed(1);
    focus_effect(&reply, 2, 2);
    assert_eq!(h.stack(), vec![4, 3, 2]);
    assert_eq!(
        h.native(4),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(settled(&mut h), chosen);
    assert_eq!(h.stack(), vec![3, 2, 4]);
    let asked = &reply["effect"];
    assert_eq!(
        h.error(json!({"op":"focus_result","effect_id":asked["effect_id"],"window":2,"identity":identity(2),"generation":asked["generation"],"success":true})),
        "stale or superseded focus result"
    );
    // The focus first: the close is then one in the background, and no
    // follower is picked or raised.
    let mut h = running(&scratch, "");
    desk(&mut h);
    h.native(4);
    assert_eq!(
        h.closed(1),
        json!({"standin":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(settled(&mut h), chosen);
    assert_eq!(h.stack(), vec![2, 3, 4]);

    // The close first, with its follower out of view: X is flown to, until
    // its center (1150, 200) is at the usable center. The report that then
    // moves the focus to F, in view, arms no flight of its own, so the camera
    // goes on to X while F holds the focus.
    let mut h = running(&scratch, "");
    put(&mut h, 1, "app.w", "W", rect(700.0, 100.0, 288.0, 200.0));
    put(&mut h, 2, "app.x", "X", rect(1000.0, 100.0, 300.0, 200.0));
    put(&mut h, 3, "app.f", "F", rect(100.0, 500.0, 200.0, 150.0));
    for id in [3, 2, 1] {
        h.observe_focus(id);
    }
    let reply = h.closed(1);
    focus_effect(&reply, 2, 2);
    assert_eq!(armed(&reply), flight((650.0, -225.0), 1.0));
    let flights = h.snapshot()["navigation"]["flights"].clone();
    assert_eq!(
        h.native(3),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    let snapshot = h.snapshot();
    assert_eq!(snapshot["focus"]["intent"], 3);
    assert_eq!(snapshot["focus"]["pending_effect"], Value::Null);
    assert_eq!(snapshot["navigation"]["flights"], flights);
    assert_eq!(
        flights["1"]["zoom_animation_anchor"]["canvas"],
        point(1150.0, 200.0)
    );
}

/// The discovery pass ends while a window that was open all along is still on
/// its way. Named in `present`, it finds its slot waiting and ends where it
/// would have ended had it arrived in time. Not named, it finds its slot
/// decided, and is a new window.
#[test]
fn a_pass_that_ends_before_a_window_arrives_decides_only_what_it_did_not_name() {
    let scratch = Scratch::new();
    let scene = saved_session(&scratch);
    // Pass ordering is under test; the later new window's fixed flight uses
    // Center explicitly instead of docking beside a surviving saved slot.
    let center = "window_placement = \"center\"\n";
    let beta = |h: &mut Host| appear(h, 21, "app.term", "beta", (640.0, 480.0));
    let docs = |h: &mut Host| appear(h, 22, "app.web", "docs", (640.0, 480.0));
    let ended = json!({"dropped":[1,4],"standins":[],"dirty":true});
    // In time: both windows are offered, then the pass ends.
    let mut timely = relaunched(&scratch, &scene, center);
    assert_eq!(beta(&mut timely), ADOPTED(2));
    assert_eq!(docs(&mut timely), ADOPTED(3));
    assert_eq!(timely.ok(json!({"op":"adoption_complete"})), ended);
    // Late: the pass ends first and names the window that is still arriving.
    let mut h = relaunched(&scratch, &scene, center);
    assert_eq!(beta(&mut h), ADOPTED(2));
    assert_eq!(
        h.ok(json!({"op":"adoption_complete","present":[{"bundle_id":"app.web","title":"docs"}]})),
        ended
    );
    assert_eq!(h.lifecycle()["held"], json!([3]));
    assert_eq!(docs(&mut h), ADOPTED(3));
    assert_eq!(h.snapshot(), timely.snapshot());

    // Reports still in flight for a slot the pass dropped are refused.
    for late in [
        json!({"op":"window_closed","window":1,"identity":identity(31)}),
        json!({"op":"retitle","window":1,"identity":identity(31),"title":"alpha"}),
        json!({"op":"observe","window":1,"identity":identity(31),"source_rect":rect(0.0,0.0,300.0,200.0),"buffer":{"width":200,"height":100}}),
    ] {
        assert_eq!(h.error(late), "unbound source");
    }
    assert_eq!(
        h.error(native(1, &identity(31), &json!(1))),
        "unknown window"
    );
    // The end of the pass reported again, with nothing waiting, decides
    // nothing and asks for no save.
    let once = h.snapshot();
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[],"dirty":false})
    );
    assert_eq!(h.snapshot(), once);
    // A window the pass did not name finds its slot gone: it is a new window,
    // placed, focused, flown to and opened.
    let reply = appear(&mut h, 23, "app.term", "alpha", (300.0, 200.0));
    assert_eq!(
        (&reply["window"], &reply["adopted"]),
        (&json!(5), &json!(false))
    );
    focus_effect(&reply, 5, 23);
    assert_eq!(armed(&reply), flight((0.0, 0.0), 1.0));
    assert_eq!(h.events(), json!([logged(1, 5, "open", json!(1))]));

    // With restore_windows the slot it did not name is a dormant stand-in by
    // then, which no window takes by itself: the window is new all the same.
    let mut h = relaunched(&scratch, &scene, "[session]\nrestore_windows = true\n");
    assert_eq!(beta(&mut h), ADOPTED(2));
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[1,3,4],"dirty":true})
    );
    let reply = docs(&mut h);
    assert_eq!(
        (&reply["window"], &reply["adopted"]),
        (&json!(5), &json!(false))
    );
    assert_eq!(h.lifecycle()["standins"], json!([1, 3, 4]));

    // The one thing the order shows. A slot that holds the saved focus asks
    // for it when its window arrives after the pass, as every adopted slot
    // that holds the focus does then; within the launch pass nothing is
    // asked and the focus is only recorded.
    let mut h = relaunched(&scratch, &scene, center);
    assert_eq!(
        h.ok(json!({"op":"adoption_complete","present":[{"bundle_id":"app.term","title":"beta"}]})),
        json!({"dropped":[1,3,4],"standins":[],"dirty":true})
    );
    let reply = beta(&mut h);
    assert_eq!(
        (&reply["window"], &reply["adopted"]),
        (&json!(2), &json!(true))
    );
    focus_effect(&reply, 2, 21);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(h.snapshot()["focus"]["history"], json!([]));
    assert_eq!(h.events(), json!([]));
}

#[test]
fn minimized_native_source_keeps_slot_identity_and_pin_but_requires_a_fresh_restore_receipt() {
    for pinned in [false, true] {
        let scratch = Scratch::new();
        let config = if pinned {
            "[[window_rules]]\napp_id = \"app.a\"\npinned_to_screen = true\nposition = [100, 100]\n"
        } else {
            ""
        };
        let mut h = running(&scratch, config);
        put(&mut h, 1, "app.a", "A", rect(300.0, 275.0, 400.0, 300.0));
        h.focus_logically(1);
        if pinned {
            h.ipc(json!({"Pin":{"window":1,"value":true}}));
        }
        let original = h.window(1);
        let source = original["source"].clone();
        let original_placements = h.snapshot()["placements"].clone();
        assert_eq!(original["pinned"].is_object(), pinned);
        let screen = original_placements[0]["screen_rect"].clone();
        let hit_point = point(
            screen["origin"]["x"].as_f64().unwrap() + 20.0,
            screen["origin"]["y"].as_f64().unwrap() + 20.0,
        );
        assert_eq!(
            h.ok(json!({"op":"hit","output":1,"screen":hit_point}))["hit"]["window"],
            1
        );
        let effect = h.ipc(json!({"Minimize":1}))["effects"][0].clone();
        assert_eq!(effect["op"], "set_minimized");
        assert_eq!(effect["minimized"], true);
        assert_eq!(
            h.window(1),
            original,
            "a native request is not visibility proof"
        );
        h.error(json!({"op":"observe_visibility","window":1,"identity":identity(2),"generation":source["generation"],"minimized":true}));
        h.error(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":999,"minimized":true}));
        h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":true}));
        assert_eq!(h.world(1), original["world_rect"]);
        assert_eq!(h.window(1)["source"]["identity"], source["identity"]);
        assert_eq!(h.window(1)["source"]["generation"], source["generation"]);
        assert_eq!(h.window(1)["pinned"], original["pinned"]);
        assert_eq!(h.window(1)["source"]["visibility"], "minimized");
        assert_eq!(h.snapshot()["placements"], json!([]));
        assert_eq!(
            h.ok(json!({"op":"hit","output":1,"screen":hit_point}))["hit"],
            Value::Null
        );
        assert_eq!(h.focused(), Value::Null);
        assert!(
            h.error(json!({"op":"focus","window":1}))
                .contains("minimized")
        );
        h.error(native(1, &source["identity"], &source["generation"]));
        h.error(json!({"op":"observe_focus","window":1,"identity":source["identity"],"generation":source["generation"]}));
        assert!(h.lifecycle()["marks"].as_array().is_none_or(Vec::is_empty));
        assert_eq!(
            h.ipc(json!({"Deminimize":1}))["effects"][0]["op"],
            "set_minimized"
        );
        h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":false}));
        let restoring = h.window(1)["source"].clone();
        assert_eq!(restoring["visibility"], "restoring");
        assert_eq!(
            h.ok(json!({"op":"hit","output":1,"screen":hit_point}))["hit"],
            Value::Null
        );
        assert_eq!(
            h.snapshot()["placements"].as_array().unwrap().len(),
            original_placements.as_array().unwrap().len()
        );
        h.error(json!({"op":"focus","window":1}));
        let visible = json!({"op":"source_visible","window":1,"identity":source["identity"],"generation":source["generation"],"visibility_revision":restoring["visibility_revision"]});
        // A repeated minimize/restore cycle invalidates the first ACK even
        // though the original live binding generation is retained.
        h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":true}));
        h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":false}));
        h.error(visible.clone());
        let mut fresh = visible;
        fresh["visibility_revision"] = h.window(1)["source"]["visibility_revision"].clone();
        h.ok(fresh);
        assert_eq!(h.window(1)["source"]["visibility"], "visible");
        assert_eq!(h.world(1), original["world_rect"]);
        h.focus_logically(1);
        h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":true}));
        h.closed(1);
        assert!(
            h.snapshot()["windows"].as_array().unwrap().is_empty(),
            "a real close is still a close"
        );
    }
}

#[test]
fn restoring_a_minimized_off_canvas_source_keeps_its_world_slot() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    let original = rect(10000.0, 10000.0, 400.0, 300.0);
    put(&mut h, 1, "app.a", "A", original.clone());
    let source = h.window(1)["source"].clone();
    for minimized in [true, false] {
        h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":minimized}));
        assert_eq!(h.world(1), original);
        assert_eq!(h.snapshot()["placements"], json!([]));
    }
    // The shell may supply a fresh parking ACK for this same visibility epoch.
    let restoring = h.window(1)["source"].clone();
    h.ok(json!({"op":"source_visible","window":1,"identity":source["identity"],"generation":source["generation"],"visibility_revision":restoring["visibility_revision"]}));
    assert_eq!(h.world(1), original);
    assert_eq!(h.snapshot()["placements"], json!([]));
}
