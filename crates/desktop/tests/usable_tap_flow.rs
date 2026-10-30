// SPDX-License-Identifier: GPL-3.0-or-later
//! The usable area of an output, as `register_output` and `set_usable_area`
//! deliver it, and tap-modifier bindings, through the exported C ABI and JSON
//! decoder with synthetic identities and config files in a throwaway
//! directory. Expected positions are worked out by hand from upstream's rules,
//! not from an oracle build. Nothing here reads a screen's visible frame,
//! watches a modifier key or counts a key press: those are the shell's.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::ffi::CStr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

struct Host {
    handle: *mut Controller,
    clock: u64,
    scratch: Scratch,
}
impl Host {
    fn new() -> Self {
        let handle = driftwm_desktop_create();
        assert!(!handle.is_null());
        Self {
            handle,
            clock: 1_000_000_000,
            scratch: Scratch::new(),
        }
    }
    fn call(&mut self, command: Value) -> Value {
        let bytes = serde_json::to_vec(&json!({"version":1,"command":command})).unwrap();
        // SAFETY: live exclusive handle, valid bytes, response freed exactly once.
        unsafe {
            let response = driftwm_desktop_request(self.handle, bytes.as_ptr(), bytes.len());
            assert!(!response.is_null());
            let result = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            driftwm_desktop_response_free(response);
            result
        }
    }
    fn ok(&mut self, command: Value) -> Value {
        let response = self.call(command);
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }
    /// A rejected command says why and leaves every bit of state as it was.
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
    fn load_config(&mut self, toml: &str) -> Value {
        let path = self.scratch.0.join("config.toml");
        std::fs::write(&path, toml).unwrap();
        let reply = self.ok(json!({"op":"load_config","path":path}));
        assert_eq!(reply["errors"], json!([]), "{reply}");
        reply
    }
    fn action(&mut self, output: u64, action: &str) -> Value {
        self.ok(json!({"op":"action","output":output,"action":action}))
    }
    fn bindings(&mut self) -> Value {
        self.ok(json!({"op":"bindings"}))
    }
    fn contexts(&mut self) -> Value {
        self.snapshot()["navigation"]["contexts"].clone()
    }
    fn pose(&mut self, output: usize) -> Value {
        let viewport = self.snapshot()["outputs"][output - 1].clone();
        json!({"camera":viewport["camera"],"zoom":viewport["zoom"]})
    }
    fn window(&mut self, id: u64) -> Value {
        let windows = self.snapshot()["windows"].clone();
        let found = windows
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == id);
        found.unwrap_or_else(|| panic!("no window {id}")).clone()
    }
    fn world(&mut self, id: u64) -> Value {
        self.window(id)["world_rect"].clone()
    }
    /// Put an output's camera at a world point and its zoom at `zoom`.
    fn look(&mut self, output: usize, camera: (f64, f64), zoom: f64) {
        let origin = self.snapshot()["outputs"][output - 1]["screen_bounds"]["origin"].clone();
        self.ok(json!({"op":"cancel_navigation","output":output}));
        // Zooming about the output's own corner leaves the camera where it is.
        self.ok(json!({"op":"zoom","output":output,"zoom":zoom,"anchor":origin}));
        let at = self.pose(output)["camera"].clone();
        let delta = point(
            (camera.0 - at["x"].as_f64().unwrap()) * zoom,
            (camera.1 - at["y"].as_f64().unwrap()) * zoom,
        );
        self.ok(json!({"op":"pan","output":output,"screen_delta":delta}));
        assert_eq!(self.pose(output), view(camera, zoom));
    }
    fn tick(&mut self) -> Value {
        self.clock += 16_666_667;
        self.ok(json!({"op":"tick_navigation","timestamp_ns":self.clock}))
    }
    /// Tick until every flight has landed and nothing coasts.
    fn settle(&mut self) {
        for _ in 0..900 {
            if self.tick()["needs_frames"] == false {
                return;
            }
        }
        panic!("the view did not settle");
    }
    /// Report that the adapter did what a focus `effect` asked.
    fn confirm(&mut self, effect: &Value) {
        self.ok(json!({"op":"focus_result","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"],"success":true}));
    }
    fn focus_state(&mut self) -> Value {
        self.snapshot()["focus"].clone()
    }
    /// Report native focus on a bound window: it then holds the keyboard.
    fn observe_focus(&mut self, id: u64) {
        let source = self.window(id)["source"].clone();
        self.ok(json!({"op":"observe_focus","window":id,"identity":source["identity"],"generation":source["generation"]}));
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        unsafe {
            driftwm_desktop_destroy(self.handle);
        }
    }
}

/// A directory of this test's own, removed when the test ends.
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "infinify-usable-tap-flow-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Output 1, `left`: a global screen rectangle that does not start at the
/// global origin, so a global point taken for a local one misses.
const OUT1: [f64; 4] = [200.0, 164.0, 1200.0, 800.0];
/// What a Dock 80 points wide on the left and a menu bar 30 points high on
/// top leave of output 1, in output-local points.
const USABLE1: [f64; 4] = [80.0, 30.0, 1120.0, 770.0];
/// Its center, (80 + 1120 / 2, 30 + 770 / 2). The output's own is (600, 400).
const CENTER1: (f64, f64) = (640.0, 415.0);
/// Output 2, `right`, with no usable rectangle: all of it is usable, and its
/// center is (500, 350).
const OUT2: [f64; 4] = [1500.0, 100.0, 1000.0, 700.0];
/// `[snap] outer_gap` in the scenarios that set one.
const GAP: &str = "[snap]\nouter_gap = 12.0\n";

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn of(r: [f64; 4]) -> Value {
    rect(r[0], r[1], r[2], r[3])
}
fn point(x: f64, y: f64) -> Value {
    json!({"x":x,"y":y})
}
fn view(camera: (f64, f64), zoom: f64) -> Value {
    json!({"camera":point(camera.0, camera.1),"zoom":zoom})
}
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid,"owner":null})
}
/// The two outputs, the first with its usable rectangle in its registration.
fn outputs(h: &mut Host) {
    assert_eq!(
        h.ok(json!({"op":"register_output","stable_id":"left","screen_bounds":of(OUT1),"usable_rect_local":of(USABLE1)})),
        json!({"output":1})
    );
    assert_eq!(
        h.ok(json!({"op":"register_output","stable_id":"right","screen_bounds":of(OUT2)})),
        json!({"output":2})
    );
    assert_eq!(
        h.ok(json!({"op":"outputs_settled"})),
        json!({"dirty":false})
    );
}
/// Both outputs, `toml` in force and the launch pass over: a window that
/// appears now is a new one.
fn running(toml: &str) -> Host {
    let mut h = Host::new();
    outputs(&mut h);
    let reply = h.load_config(toml);
    assert_eq!(reply["warnings"], json!([]), "{reply}");
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[],"dirty":false})
    );
    h.ok(json!({"op":"tick_navigation","timestamp_ns":h.clock}));
    h
}
/// A window the caller puts at a world rectangle. Its native frame has that
/// size and sits somewhere else: nothing here may read where.
fn put(h: &mut Host, wid: u64, app: &str, frame: (f64, f64, f64, f64)) {
    let reply = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,frame.2,frame.3),"world_rect":rect(frame.0,frame.1,frame.2,frame.3)}));
    assert_eq!(reply, json!({"window":wid}));
}
/// A window that appeared by itself, with the active output and the pointer.
fn appear(h: &mut Host, wid: u64, app: &str, size: (f64, f64), output: u64, at: Value) -> Value {
    let reply = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,size.0,size.1),"output":output,"pointer":at}));
    assert_eq!(reply["window"], wid, "{reply}");
    assert_eq!(reply["adopted"], false, "{reply}");
    reply
}
/// The destination of the flight a reply armed on `output`.
fn armed(reply: &Value, output: u64) -> Value {
    let navigation = &reply["navigation"];
    assert_eq!(navigation["output"], output, "{reply}");
    assert_eq!(navigation["animating"], true, "{reply}");
    json!({"camera":navigation["target_camera"],"zoom":navigation["target_zoom"]})
}

#[test]
fn the_usable_rectangle_comes_with_the_registration_or_alone_and_must_fit_the_output() {
    let mut h = Host::new();
    // A rectangle that leaves its output, has no extent or is no rectangle
    // refuses the registration whole: no output appears.
    for bad in [
        rect(80.0, 30.0, 1121.0, 770.0),
        rect(80.0, 30.0, 1120.0, 771.0),
        rect(-1.0, 30.0, 1120.0, 770.0),
        rect(80.0, -0.5, 1120.0, 770.0),
        rect(80.0, 30.0, 0.0, 770.0),
        rect(80.0, 30.0, 1120.0, -5.0),
    ] {
        assert_eq!(
            h.error(json!({"op":"register_output","stable_id":"left","screen_bounds":of(OUT1),"usable_rect_local":bad})),
            "invalid usable area"
        );
    }
    assert_eq!(h.snapshot()["outputs"], json!([]));
    outputs(&mut h);
    // Only the rectangle is the shell's: the rest is the context's defaults.
    let context = |usable: Value| json!({"usable_rect_local":usable,"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0});
    assert_eq!(h.contexts(), json!({"1":context(of(USABLE1))}));

    // An update in place. The whole output is a usable area like any other.
    assert_eq!(
        h.ok(json!({"op":"set_usable_area","output":2,"usable_rect_local":rect(0.0,25.0,1000.0,675.0)})),
        json!({"dirty":false})
    );
    assert_eq!(
        h.ok(json!({"op":"set_usable_area","output":1,"usable_rect_local":rect(0.0,0.0,1200.0,800.0)})),
        json!({"dirty":false})
    );
    assert_eq!(
        h.contexts(),
        json!({"1":context(rect(0.0,0.0,1200.0,800.0)),"2":context(rect(0.0,25.0,1000.0,675.0))})
    );
    for (command, why) in [
        (
            json!({"op":"set_usable_area","output":3,"usable_rect_local":of(USABLE1)}),
            "unknown output",
        ),
        // Output 2 is 1000 x 700: output 1's rectangle does not fit it.
        (
            json!({"op":"set_usable_area","output":2,"usable_rect_local":of(USABLE1)}),
            "invalid usable area",
        ),
        (
            json!({"op":"set_usable_area","output":2,"usable_rect_local":rect(0.0,0.0,1000.0,0.0)}),
            "invalid usable area",
        ),
    ] {
        assert_eq!(h.error(command), why);
    }
    // A registration replaces what the output had: with a rectangle, that
    // one; without, the whole output again, as before this field existed.
    h.ok(json!({"op":"register_output","stable_id":"right","screen_bounds":of(OUT2),"usable_rect_local":rect(0.0,0.0,900.0,700.0)}));
    h.ok(json!({"op":"register_output","stable_id":"left","screen_bounds":of(OUT1)}));
    assert_eq!(
        h.contexts(),
        json!({"2":context(rect(0.0,0.0,900.0,700.0))})
    );
    // Before any config the placement, speed and gap are
    // `set_navigation_context`'s, and an update of the rectangle keeps them.
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,0.0,1200.0,800.0),"focus_placement":"top_left","camera_speed":0.5,"outer_gap":10.0}));
    h.ok(json!({"op":"set_usable_area","output":1,"usable_rect_local":of(USABLE1)}));
    assert_eq!(
        h.contexts()["1"],
        json!({"usable_rect_local":of(USABLE1),"focus_placement":"top_left","camera_speed":0.5,"outer_gap":10.0})
    );
    // A removed output takes its rectangle with it.
    h.ok(json!({"op":"remove_output","output":1}));
    assert_eq!(h.contexts().get("1"), None);
}

// Upstream's placement of a new toplevel measures the usable area: the
// `focus_placement` point (align_point_on) and the cursor clamp
// (cursor_placement_pos) through get_usable_area, the auto anchor through
// viewport_center_canvas. The cascade measures nothing but other windows.
#[test]
fn a_new_window_is_placed_inside_the_usable_area_and_cascades_from_there() {
    // Explicit `center`: a 400 x 300 frame under the usable center
    // (640, 415) has its top-left at (640 - 200, 415 - 150). The output's own
    // center (600, 400) would put it at (400, 250).
    let mut h = running("window_placement = \"center\"\n");
    let pointer = point(OUT1[0] + 700.0, OUT1[1] + 500.0);
    let first = appear(&mut h, 1, "app.1", (400.0, 300.0), 1, pointer.clone());
    assert_eq!(h.world(1), rect(440.0, 265.0, 400.0, 300.0));
    // It already sits on the placement point: the camera has nowhere to go.
    assert_eq!(armed(&first, 1), view((0.0, 0.0), 1.0));
    h.settle();
    // The same spot is taken: one step of `title_bar_height` (25) down the
    // diagonal, and the camera follows the frame to the usable center.
    let second = appear(&mut h, 2, "app.2", (400.0, 300.0), 1, pointer.clone());
    assert_eq!(h.world(2), rect(465.0, 290.0, 400.0, 300.0));
    assert_eq!(armed(&second, 1), view((25.0, 25.0), 1.0));
    h.settle();
    assert_eq!(h.pose(1), view((25.0, 25.0), 1.0));
    // Output 2 has no rectangle: its own center (500, 350), as ever.
    let third = appear(&mut h, 3, "app.3", (400.0, 300.0), 2, pointer);
    assert_eq!(h.world(3), rect(300.0, 200.0, 400.0, 300.0));
    assert_eq!(armed(&third, 2), view((0.0, 0.0), 1.0));

    // `cursor`: centered on the pointer and held inside the usable area. A
    // pointer in the output's top-left corner, local (10, 6), leaves the
    // frame at the Dock's edge and under the menu bar, not at (0, 0).
    let mut h = running("window_placement = \"cursor\"\n");
    appear(
        &mut h,
        1,
        "app.1",
        (400.0, 300.0),
        1,
        point(OUT1[0] + 10.0, OUT1[1] + 6.0),
    );
    assert_eq!(h.world(1), rect(80.0, 30.0, 400.0, 300.0));
    // The far corner is the output's own: (1200 - 400, 800 - 300).
    appear(
        &mut h,
        2,
        "app.2",
        (400.0, 300.0),
        1,
        point(OUT1[0] + 1195.0, OUT1[1] + 795.0),
    );
    assert_eq!(h.world(2), rect(800.0, 500.0, 400.0, 300.0));
    // A frame wider than the usable area keeps its left edge on the usable
    // edge: 1150 fits the output's 1200 and not the 1120 the Dock leaves.
    appear(
        &mut h,
        3,
        "app.3",
        (1150.0, 300.0),
        1,
        point(OUT1[0] + 600.0, OUT1[1] + 400.0),
    );
    assert_eq!(h.world(3), rect(80.0, 250.0, 1150.0, 300.0));
    // On output 2 the same corner is the output's corner.
    appear(
        &mut h,
        4,
        "app.4",
        (400.0, 300.0),
        2,
        point(OUT2[0] + 5.0, OUT2[1] + 3.0),
    );
    assert_eq!(h.world(4), rect(0.0, 0.0, 400.0, 300.0));
    // Through a camera and a zoom: at half size from (100, 50) the usable
    // area shows the canvas from (100 + 80 / 0.5, 50 + 30 / 0.5).
    let mut h = running("window_placement = \"cursor\"\n");
    h.look(1, (100.0, 50.0), 0.5);
    appear(
        &mut h,
        1,
        "app.1",
        (400.0, 300.0),
        1,
        point(OUT1[0] + 10.0, OUT1[1] + 6.0),
    );
    assert_eq!(h.world(1), rect(260.0, 110.0, 400.0, 300.0));

    // `auto`: with nothing focused the anchor is the element nearest the
    // usable center. Two frames lie 300 points either side of the output's
    // center (600, 400), the left one on top, which is the one a tie takes.
    // From the usable center (640, 415) the right one is 260 away and the
    // left one 340: the new window docks beside the right one, on the side
    // that faces the viewport center, a snap gap (12) from it and centered
    // on it: (900 - 12 - 150, 400 - 75).
    let mut h = running("window_placement = \"auto\"\n");
    let (left, right) = ((100.0, 300.0, 200.0, 200.0), (900.0, 300.0, 200.0, 200.0));
    put(&mut h, 1, "app.right", right);
    put(&mut h, 2, "app.left", left);
    appear(
        &mut h,
        3,
        "app.3",
        (150.0, 150.0),
        1,
        point(OUT1[0] + 600.0, OUT1[1] + 400.0),
    );
    assert_eq!(h.world(3), rect(738.0, 325.0, 150.0, 150.0));
}

// Upstream align_point_on: with pull -1 an axis parks the frame's center at
// `low + inset + extent / 2`, with pull +1 at `low + span - inset - extent /
// 2`, else at the usable center, where `low` and `span` are the usable area's
// and `inset` is `snap.outer_gap` at the landing zoom. A 400 x 300 frame at
// zoom 1 with a gap of 12:
//   output 1, usable x 80..1200, y 30..800: left 80 + 12 + 200 = 292, right
//     1200 - 12 - 200 = 988, top 30 + 12 + 150 = 192, bottom 800 - 12 - 150 =
//     638, center (640, 415);
//   output 2, the whole 1000 x 700: left 212, right 788, top 162, bottom 538,
//     center (500, 350).
// The camera is the frame's center less that point.
#[test]
fn center_window_parks_the_frame_on_each_focus_placement_edge_of_the_usable_area() {
    let frame = (1000.0, 2000.0, 400.0, 300.0);
    let center = (1200.0, 2150.0);
    for (placement, on_one, on_two) in [
        ("center", (640.0, 415.0), (500.0, 350.0)),
        ("top", (640.0, 192.0), (500.0, 162.0)),
        ("bottom", (640.0, 638.0), (500.0, 538.0)),
        ("left", (292.0, 415.0), (212.0, 350.0)),
        ("right", (988.0, 415.0), (788.0, 350.0)),
        ("top-left", (292.0, 192.0), (212.0, 162.0)),
        ("top-right", (988.0, 192.0), (788.0, 162.0)),
        ("bottom-left", (292.0, 638.0), (212.0, 538.0)),
        ("bottom-right", (988.0, 638.0), (788.0, 538.0)),
    ] {
        let mut h = running(&format!("focus_placement = \"{placement}\"\n{GAP}"));
        put(&mut h, 1, "app.1", frame);
        for (output, at) in [(1, on_one), (2, on_two)] {
            let reply = h.action(output, "center-window");
            assert_eq!(
                armed(&reply, output),
                view((center.0 - at.0, center.1 - at.1), 1.0),
                "{placement} on output {output}"
            );
        }
        h.settle();
        assert_eq!(
            h.pose(1),
            view((center.0 - on_one.0, center.1 - on_one.1), 1.0)
        );
        assert_eq!(
            h.pose(2),
            view((center.0 - on_two.0, center.1 - on_two.1), 1.0)
        );
    }

    // The inset and the frame scale with the zoom a navigation lands at. At
    // 0.5 the frame is 200 x 150 on screen and the gap 6: top-left parks its
    // center at (80 + 6 + 100, 30 + 6 + 75), and the camera at the frame's
    // center less that point over the zoom.
    let mut h = running(&format!("focus_placement = \"top-left\"\n{GAP}"));
    put(&mut h, 1, "app.1", frame);
    h.look(1, (0.0, 0.0), 0.5);
    let reply = h.ok(json!({"op":"navigate_window","window":1,"output":1,"zoom_policy":"keep"}));
    assert_eq!(
        armed(&reply, 1),
        view((center.0 - 186.0 / 0.5, center.1 - 111.0 / 0.5), 0.5)
    );

    // A frame that cannot keep both gutters on an axis is centered on it:
    // 1100 + 2 * 12 is more than the 1120 the Dock leaves, though less than
    // the output's 1200, which would have parked it at 12 + 550.
    let mut h = running(&format!("focus_placement = \"top-left\"\n{GAP}"));
    put(&mut h, 1, "app.1", (1000.0, 2000.0, 1100.0, 300.0));
    let reply = h.action(1, "center-window");
    assert_eq!(
        armed(&reply, 1),
        view((1550.0 - CENTER1.0, 2150.0 - 192.0), 1.0)
    );

    // center-nearest flies a `navigation.anchors` point, here the world point
    // (3000, 415), under the usable center, whatever `focus_placement` says.
    let mut h =
        running("focus_placement = \"top-left\"\n[navigation]\nanchors = [[3000.0, -415.0]]\n");
    for (output, at) in [(1, CENTER1), (2, (500.0, 350.0))] {
        let reply = h.action(output, "center-nearest right");
        assert_eq!(
            armed(&reply, output),
            view((3000.0 - at.0, 415.0 - at.1), 1.0)
        );
    }
}

// Upstream window_fully_in_viewport measures the usable area: a frame that is
// all on the output and partly under the Dock is not wholly in view, and an
// IPC `Focus` then brings it there instead of only focusing it.
#[test]
fn a_frame_partly_under_the_dock_is_not_wholly_in_view() {
    let frame = (20.0, 100.0, 400.0, 300.0);
    let focus =
        |h: &mut Host, output: u64| h.ok(json!({"op":"ipc","output":output,"request":{"Focus":1}}));
    // Its left 60 points are under the Dock: flown to the usable center.
    let mut h = running("");
    put(&mut h, 1, "app.1", frame);
    let reply = focus(&mut h, 1);
    assert_eq!(armed(&reply, 1), view((220.0 - 640.0, 250.0 - 415.0), 1.0));
    // Output 2 shows the same canvas with nothing over it: focused in place.
    let mut h = running("");
    put(&mut h, 1, "app.1", frame);
    let reply = focus(&mut h, 2);
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
    // And so does output 1 once the Dock is hidden.
    let mut h = running("");
    put(&mut h, 1, "app.1", frame);
    h.ok(
        json!({"op":"set_usable_area","output":1,"usable_rect_local":rect(0.0,30.0,1200.0,770.0)}),
    );
    let reply = focus(&mut h, 1);
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
}

// Upstream fit_to_bbox and min_zoom measure the usable area's size and center
// the box on its center. The two frames span (0, 0) to (1920, 1220), and the
// default `zoom.fit_padding` is 80.
#[test]
fn zoom_to_fit_fits_the_usable_area_and_centers_on_its_center() {
    let mut h = running("");
    put(&mut h, 1, "app.1", (0.0, 0.0, 400.0, 300.0));
    put(&mut h, 2, "app.2", (1520.0, 920.0, 400.0, 300.0));
    // Output 1: (1120 - 160) / 1920 and (770 - 160) / 1220 are both 0.5, and
    // the box's center (960, 610) goes under (640, 415). The whole output
    // would fit at 640 / 1220.
    let fit = h.action(1, "zoom-to-fit");
    assert_eq!(
        armed(&fit, 1),
        view((960.0 - 640.0 / 0.5, 610.0 - 415.0 / 0.5), 0.5)
    );
    // Output 2, all 1000 x 700 of it: 840 / 1920 = 0.4375 is the tighter axis.
    let fit = h.action(2, "zoom-to-fit");
    assert_eq!(
        armed(&fit, 2),
        view((960.0 - 500.0 / 0.4375, 610.0 - 350.0 / 0.4375), 0.4375)
    );
    h.settle();
    assert_eq!(h.pose(1), view((-320.0, -220.0), 0.5));
    // The dynamic minimum is half the fit: an IPC zoom below it stops there.
    for (output, least) in [(1, 0.25), (2, 0.21875)] {
        let reply = h.ok(json!({"op":"ipc","output":output,"request":{"Zoom":0.01}}));
        assert_eq!(reply["reply"], json!({"Ok":{"Zoom":least}}), "{reply}");
    }

    // zoom-to-fit-snapped fits the focused window's cluster the same way:
    // window 1 alone fits at zoom 1, its center (200, 150) under (640, 415).
    let mut h = running("");
    put(&mut h, 1, "app.1", (0.0, 0.0, 400.0, 300.0));
    put(&mut h, 2, "app.2", (1520.0, 920.0, 400.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    let fit = h.action(1, "zoom-to-fit-snapped");
    assert_eq!(armed(&fit, 1), view((200.0 - 640.0, 150.0 - 415.0), 1.0));
}

// Upstream clamp_pin_frame takes output_logical_size: a pin is held on the
// output, not inside its usable area, so a pinned window may sit under the
// Dock or the menu bar. Nothing here changes for an asymmetric rectangle.
#[test]
fn a_pin_is_clamped_to_the_whole_output_as_upstream_clamps_it() {
    let rules = r#"
[[window_rules]]
app_id = "pin.far"
pinned_to_screen = true
position = [-5000, 5000]
[[window_rules]]
app_id = "pin.near"
pinned_to_screen = true
position = [5000, -5000]
"#;
    let mut h = running(rules);
    let pointer = point(OUT1[0] + 600.0, OUT1[1] + 400.0);
    // Far up and to the left: the output's own corner, global (200, 164),
    // where the usable area would have been (280, 194).
    appear(&mut h, 1, "pin.far", (300.0, 200.0), 1, pointer.clone());
    assert_eq!(
        h.window(1)["pinned"],
        json!({"output":1,"screen_rect":rect(200.0, 164.0, 300.0, 200.0)})
    );
    // Far down and to the right: (1200 - 300, 800 - 200) past the origin.
    appear(&mut h, 2, "pin.near", (300.0, 200.0), 1, pointer);
    assert_eq!(
        h.window(2)["pinned"],
        json!({"output":1,"screen_rect":rect(1100.0, 764.0, 300.0, 200.0)})
    );
    // A window pinned where it is drawn stays there, under the Dock.
    put(&mut h, 3, "app.3", (10.0, 5.0, 300.0, 200.0));
    h.observe_focus(3);
    assert_eq!(h.action(1, "toggle-pin-to-screen")["dirty"], true);
    assert_eq!(
        h.window(3)["pinned"],
        json!({"output":1,"screen_rect":rect(210.0, 169.0, 300.0, 200.0)})
    );
    // A change of the usable area moves none of them.
    let pins = |h: &mut Host| [1, 2, 3].map(|id| h.window(id)["pinned"].clone());
    let before = pins(&mut h);
    h.ok(json!({"op":"set_usable_area","output":1,"usable_rect_local":rect(300.0,300.0,400.0,300.0)}));
    assert_eq!(pins(&mut h), before);
}

/// The effect a reply began, which is also the transaction's pending effect.
fn began(h: &mut Host, reply: &Value) -> Value {
    let effect = reply["effect"].clone();
    assert!(effect.is_object(), "{reply}");
    assert_eq!(reply["transaction"], effect["transaction"], "{reply}");
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], effect);
    effect
}
/// Answer one resize effect as the adapter would, with the native frame the
/// window then has: its size, at a native origin no world math may read.
fn answer(h: &mut Host, effect: &Value, outcome: &str, attempted: bool, size: (f64, f64)) -> Value {
    let frame = rect(4000.0, 3000.0, size.0, size.1);
    let requested = if effect["requested"].is_null() {
        json!({"width":0.0,"height":0.0})
    } else {
        effect["requested"].clone()
    };
    h.ok(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":outcome,"ax_error":0,"mutation_attempted":attempted,"observed":true,"requested":requested,"actual_ax":frame,"actual_cg":frame}}))
}
/// Play the shell's whole part for the size transaction a reply carries: the
/// baseline read finds `from`, the setter is asked for `asks` and the window
/// takes `took`, and the final read finds the same.
fn deliver(
    h: &mut Host,
    reply: &Value,
    from: (f64, f64),
    asks: (f64, f64),
    outcome: &str,
    took: (f64, f64),
) {
    let read = began(h, reply);
    assert_eq!(read["op"], "observe_resize_source", "{read}");
    let setter = answer(h, &read, "observed", false, from)["effect"].clone();
    assert_eq!(setter["op"], "resize_native_window", "{setter}");
    assert_eq!(setter["requested"], json!({"width":asks.0,"height":asks.1}));
    let last = answer(h, &setter, outcome, true, took)["effect"].clone();
    assert_eq!(last["op"], "observe_resize_source", "{last}");
    assert_eq!(
        answer(h, &last, "observed", false, took)["effect"],
        Value::Null
    );
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["phase"], "complete", "{slot}");
}
/// As `running`, with supported native readback capability.
fn capable(toml: &str) -> Host {
    let mut h = running(toml);
    assert_eq!(
        h.ok(json!({"op":"native_resize_capability","enabled":true})),
        json!({})
    );
    h
}

// Upstream compute_fit_geometry and compute_fill_geometry measure the usable
// area less `snap.outer_gap` on every side. Mac fullscreen uses the usable
// area without that gap so the menu/notch exclusion remains visible.
#[test]
fn fit_fill_and_fullscreen_respect_the_usable_area() {
    // Fit (v0.20: edge to edge, `snap.outer_gap` is fill's margin and fit
    // ignores it): the size is the usable area, 1120 x 770. The window keeps
    // its center (300, 250), the camera goes to that less the usable center,
    // and the frame's top-left to the camera plus (80, 30).
    let mut h = capable(GAP);
    put(&mut h, 1, "app.1", (100.0, 100.0, 400.0, 300.0));
    put(&mut h, 2, "app.2", (100.0, 100.0, 400.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = h.action(1, "fit-window");
    assert_eq!(armed(&reply, 1), view((-340.0, -165.0), 1.0));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (1120.0, 770.0),
        "applied",
        (1120.0, 770.0),
    );
    assert_eq!(h.world(1), rect(-260.0, -135.0, 1120.0, 770.0));
    assert_eq!(h.window(1)["mode"], "fit");
    // On output 2 the same window shape fits all 1000 x 700.
    h.ok(json!({"op":"focus","window":2}));
    let reply = h.action(2, "fit-window");
    assert_eq!(armed(&reply, 2), view((-200.0, -100.0), 1.0));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (1000.0, 700.0),
        "applied",
        (1000.0, 700.0),
    );
    assert_eq!(h.world(2), rect(-200.0, -100.0, 1000.0, 700.0));

    // Fill: alone on output 1 at the origin, the frame grows to the usable
    // area on the canvas, x 80..1200 and y 30..800, less the gap.
    let mut h = capable(GAP);
    put(&mut h, 1, "app.1", (400.0, 300.0, 300.0, 200.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = h.action(1, "fill-window");
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (1096.0, 746.0),
        "applied",
        (1096.0, 746.0),
    );
    assert_eq!(h.world(1), rect(92.0, 42.0, 1096.0, 746.0));
    assert_eq!(h.window(1)["mode"], "fill");
    // Upstream fill_restore_view reads the usable area of the moment. The
    // Dock moves to the right: the area keeps its shape, so center-window
    // still returns to the fill's framing, and the camera takes up the new
    // origin, (80 - 0, 30 - 30), which shows the frame inside the new area.
    h.look(1, (500.0, 500.0), 0.5);
    assert_eq!(
        h.ok(json!({"op":"set_usable_area","output":1,"usable_rect_local":rect(0.0,30.0,1120.0,770.0)})),
        json!({"dirty":false})
    );
    assert_eq!(h.world(1), rect(92.0, 42.0, 1096.0, 746.0));
    assert_eq!(h.pose(1), view((500.0, 500.0), 0.5));
    let back = h.action(1, "center-window");
    assert_eq!(armed(&back, 1), view((80.0, 0.0), 1.0));
    // An area of another shape is no framing to return to: the plain
    // navigation, the frame's center (640, 415) under the area's (640, 380).
    h.ok(
        json!({"op":"set_usable_area","output":1,"usable_rect_local":rect(80.0,30.0,1120.0,700.0)}),
    );
    let plain = h.action(1, "center-window");
    assert_eq!(armed(&plain, 1), view((0.0, 35.0), 1.0));
    assert_eq!(h.window(1)["mode"], "fill");

    // Fullscreen asks for the usable 1120 x 770 without the fill gap. A
    // window refusing that size sits at the usable top-left, (80, 30)
    // relative to the output origin (tests/fullscreen_flow.rs,
    // `a_window_that_takes_another_size_stays_at_the_usable_top_left`).
    let mut h = capable(GAP);
    put(&mut h, 1, "app.1", (100.0, 100.0, 400.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = h.action(1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (1120.0, 770.0),
        "rejected",
        (400.0, 300.0),
    );
    let placements = h.snapshot()["placements"].clone();
    let shown: Vec<&Value> = placements
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["output"] == 1)
        .collect();
    assert_eq!(shown.len(), 1, "{placements}");
    assert_eq!(shown[0]["fullscreen"], true);
    assert_eq!(
        shown[0]["screen_rect"],
        rect(OUT1[0] + 80.0, OUT1[1] + 30.0, 400.0, 300.0)
    );
}

// What upstream does when a panel's exclusive zone changes is arrange its
// layers again and owe the output a frame. It moves no camera, window or pin
// and cancels no animation: every reader simply measures the new area the
// next time it reads, and the per-frame active bookmark at once.
#[test]
fn a_change_of_the_usable_area_moves_nothing_and_is_measured_from_then_on() {
    let config = format!(
        "{GAP}[navigation.bookmarks]\na = [300.0, -400.0]\nb = [900.0, -400.0]\n[[window_rules]]\napp_id = \"pin\"\npinned_to_screen = true\nposition = [-5000, 5000]\n"
    );
    let mut h = running(&config);
    put(&mut h, 1, "app.1", (1000.0, 2000.0, 400.0, 300.0));
    appear(
        &mut h,
        2,
        "pin",
        (300.0, 200.0),
        1,
        point(OUT1[0] + 600.0, OUT1[1] + 400.0),
    );
    // The Dock moves from the left edge to the right one.
    let moved = rect(0.0, 30.0, 1120.0, 770.0);
    let update = |h: &mut Host, usable: Value| {
        let before = h.snapshot();
        assert_eq!(
            h.ok(json!({"op":"set_usable_area","output":1,"usable_rect_local":usable})),
            json!({"dirty":false})
        );
        (before, h.snapshot())
    };

    // The active bookmark is the visible one nearest the usable center, and
    // a rival takes the title when it is under 0.9 of the incumbent's
    // distance. From (640, 415), b at (900, 400) is 260.4 away and a at
    // (300, 400) is 340.3; from (560, 415) it is the other way round. Output
    // 2's center (500, 350) is nearest a throughout.
    assert_eq!(
        h.snapshot()["navigation"]["active_bookmarks"],
        json!({"1":"b","2":"a"})
    );
    let (mut before, after) = update(&mut h, moved.clone());
    before["navigation"]["contexts"]["1"]["usable_rect_local"] = moved.clone();
    before["navigation"]["active_bookmarks"]["1"] = json!("a");
    assert_eq!(after, before);
    let (mut before, after) = update(&mut h, of(USABLE1));
    before["navigation"]["contexts"]["1"]["usable_rect_local"] = of(USABLE1);
    before["navigation"]["active_bookmarks"]["1"] = json!("b");
    assert_eq!(after, before);

    // A flight armed under the old area keeps its anchor: center-window flies
    // the frame's center (1200, 2150) to the old usable center (640, 415).
    let flight = h.action(1, "center-window");
    assert_eq!(armed(&flight, 1), view((560.0, 1735.0), 1.0));
    h.tick();
    let mid = h.pose(1);
    assert_ne!(mid, view((0.0, 0.0), 1.0));
    assert_ne!(mid, view((560.0, 1735.0), 1.0));
    // In mid-flight the rectangle is the one thing that changes: no pose, no
    // window, no pin, no flight, no focus, no placement.
    let (mut before, after) = update(&mut h, moved.clone());
    before["navigation"]["contexts"]["1"]["usable_rect_local"] = moved.clone();
    assert_eq!(after, before);
    assert_eq!(after["navigation"]["flights"]["1"]["generation"], 1);
    h.settle();
    assert_eq!(h.pose(1), view((560.0, 1735.0), 1.0));

    // From then on the new area is measured: the same action parks the frame
    // under (560, 415), and the cursor is sent to that point of the screen.
    let again = h.action(1, "center-window");
    assert_eq!(armed(&again, 1), view((640.0, 1735.0), 1.0));
    assert_eq!(
        h.action(2, "send-cursor-to-output left")["effects"],
        json!([{"op":"warp_pointer","screen":point(OUT1[0] + 560.0, OUT1[1] + 415.0),"output":1}])
    );
    h.ok(json!({"op":"set_usable_area","output":1,"usable_rect_local":of(USABLE1)}));
    assert_eq!(
        h.action(2, "send-cursor-to-output left")["effects"],
        json!([{"op":"warp_pointer","screen":point(OUT1[0] + 640.0, OUT1[1] + 415.0),"output":1}])
    );
}

// The three outputs and the numbers of platform_actions_flow's
// `three_outputs_are_adjacent_as_upstreams_direction_cone_says`, which gives
// its second output a usable rectangle through `set_navigation_context` and
// the other two none: the cursor is sent to (500, 400), (1800, 570) and
// (500, -600). The same rectangle in the registration gives the same three
// points, and an output without one is its whole self.
#[test]
fn an_output_without_a_usable_rectangle_is_measured_as_it_always_was() {
    let mut h = Host::new();
    h.ok(json!({"op":"register_output","stable_id":"left","screen_bounds":rect(0.0,0.0,1000.0,800.0)}));
    h.ok(json!({"op":"register_output","stable_id":"right","screen_bounds":rect(1000.0,100.0,1600.0,900.0),"usable_rect_local":rect(0.0,40.0,1600.0,860.0)}));
    h.ok(json!({"op":"register_output","stable_id":"above","screen_bounds":rect(-200.0,-1200.0,1400.0,1200.0)}));
    for (from, direction, to, at) in [
        (2, "left", 1, (500.0, 400.0)),
        (1, "right", 2, (1800.0, 570.0)),
        (1, "up", 3, (500.0, -600.0)),
    ] {
        assert_eq!(
            h.action(from, &format!("send-cursor-to-output {direction}")),
            json!({"navigation":null,"effects":[{"op":"warp_pointer","screen":point(at.0, at.1),"output":to}],"dirty":false})
        );
    }
    // And navigation_actions_flow's first center-window: an output at
    // (300, 200) of 1000 x 800 with the usable rectangle (20, 40, 960, 740)
    // parks the frame (900, 150, 200, 100) with the camera at (500, -210).
    // Without the rectangle it is the output's center: (500, -200).
    for (usable, camera) in [
        (Some(rect(20.0, 40.0, 960.0, 740.0)), (500.0, -210.0)),
        (None, (500.0, -200.0)),
    ] {
        let mut h = Host::new();
        let mut register = json!({"op":"register_output","stable_id":"view-a","screen_bounds":rect(300.0,200.0,1000.0,800.0)});
        if let Some(usable) = usable {
            register["usable_rect_local"] = usable;
        }
        h.ok(register);
        h.load_config("");
        h.ok(json!({"op":"tick_navigation","timestamp_ns":h.clock}));
        put(&mut h, 1, "test", (900.0, 150.0, 200.0, 100.0));
        let reply = h.action(1, "center-window");
        assert_eq!(armed(&reply, 1), view(camera, 1.0));
    }
}

fn chord(control: bool, option: bool, shift: bool, command: bool) -> Value {
    json!({"control":control,"option":option,"shift":shift,"command":command})
}
const CONTROL: [bool; 4] = [true, false, false, false];
const SHIFT: [bool; 4] = [false, false, true, false];
const OPTION_SHIFT: [bool; 4] = [false, true, true, false];
const CONTROL_OPTION: [bool; 4] = [true, true, false, false];
fn tap_command(modifiers: [bool; 4], output: Value) -> Value {
    let [control, option, shift, command] = modifiers;
    json!({"op":"tap","modifiers":chord(control, option, shift, command),"output":output})
}
fn tap(h: &mut Host, modifiers: [bool; 4]) -> Value {
    h.ok(tap_command(modifiers, json!(1)))
}
fn by_combo(entries: &Value) -> BTreeMap<String, Value> {
    entries
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| (entry["combo"].as_str().unwrap().to_owned(), entry.clone()))
        .collect()
}
fn switched() -> Value {
    json!({"navigation":null,"effects":[{"op":"switch_layout","target":"next","index":null}],"dirty":false})
}

#[test]
fn the_default_config_binds_no_tap_and_warns_of_none() {
    // Upstream's reference config has a tap binding only as a commented
    // example: with no file, and with an empty one, nothing is listed.
    let mut h = Host::new();
    outputs(&mut h);
    let unconfigured = h.bindings();
    assert_eq!(unconfigured["taps"], json!([]));
    let loaded = h.load_config("");
    assert_eq!(loaded["warnings"], json!([]));
    let reply = h.bindings();
    assert_eq!(reply["taps"], json!([]));
    assert_eq!(reply["warnings"], json!([]));
    // Nor is a bare modifier among what the defaults skip: every skipped
    // combo names a key.
    let modifiers = ["mod", "ctrl", "alt", "shift", "super", "mod3"];
    for entry in reply["skipped"].as_array().unwrap() {
        let combo = entry["combo"].as_str().unwrap();
        assert!(
            combo.split('+').any(|part| !modifiers.contains(&part)),
            "{combo}"
        );
    }
    assert_eq!(
        h.error(tap_command(OPTION_SHIFT, json!(1))),
        "no tap binding on ⌥⇧"
    );
}

const TAPS: &str = r#"
[keybindings]
"alt+shift" = "switch-layout next"
"alt+shift+k" = "zoom-in"
"ctrl+alt" = "zoom-reset"
"mod" = "home-toggle"
"mod+alt" = "center-window"
"mod+ctrl" = "zoom-to-fit"
"mod3" = "zoom-out"
"shift" = "fit-window"
"#;

#[test]
fn bindings_lists_each_tap_with_the_macos_modifiers_a_key_binding_would_have() {
    let mut h = Host::new();
    // Exercise an explicit multi-key Super override before returning to the
    // Mac's Command default below; this is no longer the default chord.
    h.ok(json!({"op":"set_platform","super":"ctrl+alt"}));
    outputs(&mut h);
    let loaded = h.load_config(TAPS);
    assert_eq!(loaded["warnings"], json!([]));
    let reply = h.bindings();
    // Sorted by combo. `logo` is the super chord, Control+Option, and a
    // modifier the chord already holds is displaced: `ctrl` to Command,
    // `alt` to Command+Shift. `fit-window` runs only once the shell can
    // deliver a size.
    assert_eq!(
        reply["taps"],
        json!([
            {"combo":"alt+shift","modifiers":chord(false, true, true, false),"action":"switch-layout next","implemented":true},
            {"combo":"ctrl+alt","modifiers":chord(true, true, false, false),"action":"zoom-reset","implemented":true},
            {"combo":"mod+alt","modifiers":chord(true, true, true, true),"action":"center-window","implemented":true},
            {"combo":"mod+ctrl","modifiers":chord(true, true, false, true),"action":"zoom-to-fit","implemented":true},
            {"combo":"shift","modifiers":chord(false, false, true, false),"action":"fit-window","implemented":false},
        ])
    );
    // `mod` alone is Control+Option too: sorted by combo, `ctrl+alt` keeps
    // the chord. Mod3 has no key. Both are reported as a key binding's are.
    let skipped = by_combo(&reply["skipped"]);
    assert_eq!(
        skipped["mod"],
        json!({"combo":"mod","action":"home-toggle","reason":"'ctrl+alt' already holds this macOS chord"})
    );
    assert_eq!(
        skipped["mod3"],
        json!({"combo":"mod3","action":"zoom-out","reason":"macOS has no Mod3 modifier"})
    );
    assert_eq!(
        reply["warnings"],
        json!([
            "binding 'mod' = 'home-toggle' skipped: 'ctrl+alt' already holds this macOS chord",
            "binding 'mod3' = 'zoom-out' skipped: macOS has no Mod3 modifier",
        ])
    );
    // A tap and a chord that begins with it are two bindings: the chord is a
    // hot key on K under the tap's own modifiers.
    let key = by_combo(&reply["keys"])["alt+shift+k"].clone();
    assert_eq!(key["modifiers"], chord(false, true, true, false));
    assert_eq!(key["key_code"], 0x28);
    assert_eq!(key["action"], "zoom-in");
    assert_eq!(h.bindings(), reply);

    // With Command as the super chord nothing collides or is displaced.
    assert_eq!(
        h.ok(json!({"op":"set_platform","super":"cmd"})),
        json!({"super":"cmd"})
    );
    let literal = by_combo(&h.bindings()["taps"]);
    assert_eq!(
        literal.keys().collect::<Vec<_>>(),
        [
            "alt+shift",
            "ctrl+alt",
            "mod",
            "mod+alt",
            "mod+ctrl",
            "shift"
        ]
    );
    assert_eq!(
        literal["mod"]["modifiers"],
        chord(false, false, false, true)
    );
    assert_eq!(
        literal["mod+alt"]["modifiers"],
        chord(false, true, false, true)
    );
    assert_eq!(
        literal["mod+ctrl"]["modifiers"],
        chord(true, false, false, true)
    );
    // A super chord that holds Command leaves nothing to displace to.
    h.ok(json!({"op":"set_platform","super":"ctrl+cmd"}));
    let reply = h.bindings();
    let taps = by_combo(&reply["taps"]);
    assert_eq!(taps["mod"]["modifiers"], chord(true, false, false, true));
    assert_eq!(taps["mod+alt"]["modifiers"], chord(true, true, false, true));
    assert!(!taps.contains_key("mod+ctrl"));
    assert_eq!(
        by_combo(&reply["skipped"])["mod+ctrl"]["reason"],
        "super is ctrl+cmd: it holds ctrl and Command, so nothing is left to stand for ctrl on its own"
    );
    // The capability makes the sizing tap run.
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    assert_eq!(
        by_combo(&h.bindings()["taps"])["shift"]["implemented"],
        true
    );
}

/// Three focused-in-turn windows on a canvas whose output 1 is coasting after
/// a flick, with a held `cycle-windows` step open.
fn mid_cycle(toml: &str) -> Host {
    let mut h = running(toml);
    for (wid, x) in [(1, 0.0), (2, 500.0), (3, 1000.0)] {
        put(&mut h, wid, &format!("app.{wid}"), (x, 100.0, 300.0, 200.0));
        h.observe_focus(wid);
    }
    for (delta, at) in [(-3.0, 1000), (-11.0, 1008), (-24.0, 1016), (-38.0, 1024)] {
        h.ok(json!({"op":"pan","output":1,"screen_delta":point(delta, 2.0),"time_ms":at,"source":"finger"}));
    }
    assert_eq!(
        h.ok(json!({"op":"pan_end","output":1})),
        json!({"needs_frames":true})
    );
    h.tick();
    assert!(coasting(&mut h));
    // History 3, 2, 1: the step selects window 2, and the adapter focuses it.
    let step = h.ok(json!({"op":"action","output":1,"action":"cycle-windows forward","held":true}));
    // v0.20: Alt-Tab does not pan to a window the view already shows whole,
    // and window 2 is whole on this view after the flick: focus only.
    assert_eq!(step["navigation"], Value::Null, "{step}");
    assert_eq!(step["effects"][0]["window"], 2, "{step}");
    h.confirm(&step["effects"][0]);
    assert_eq!(h.focus_state()["cycle"], 1);
    assert_eq!(h.focus_state()["history"], json!([3, 2, 1]));
    // The step's own prelude stopped the coast: flick again under the cycle.
    h.ok(json!({"op":"cancel_navigation","output":1}));
    for (delta, at) in [(-3.0, 2000), (-11.0, 2008), (-24.0, 2016), (-38.0, 2024)] {
        h.ok(json!({"op":"pan","output":1,"screen_delta":point(delta, 2.0),"time_ms":at,"source":"finger"}));
    }
    h.ok(json!({"op":"pan_end","output":1}));
    h.tick();
    assert!(coasting(&mut h));
    assert_eq!(h.focus_state()["cycle"], 1);
    h
}
fn coasting(h: &mut Host) -> bool {
    h.snapshot()["navigation"]["momentum"]["1"]["coasting"] == true
}

#[test]
fn a_tap_runs_its_action_once_through_the_action_prelude() {
    // Two controllers in the same state. One is sent the tap, the other the
    // action the tap is bound to: the replies and what they leave are equal.
    let mut tapped = mid_cycle(TAPS);
    let mut asked = mid_cycle(TAPS);
    assert_eq!(tapped.snapshot(), asked.snapshot());
    let reply = tap(&mut tapped, OPTION_SHIFT);
    assert_eq!(reply, switched());
    assert_eq!(reply, asked.action(1, "switch-layout next"));
    assert_eq!(tapped.snapshot(), asked.snapshot());
    // The prelude ended the cycle, which commits the window it had reached,
    // and stopped the coast; switch-layout itself touches neither.
    let after = tapped.snapshot();
    assert_eq!(after["focus"]["cycle"], Value::Null);
    assert_eq!(after["focus"]["history"], json!([2, 3, 1]));
    assert!(!coasting(&mut tapped));

    // An action that needs the output takes the tap's: `ctrl+alt` is
    // zoom-reset, a flight on the output named.
    let mut h = running(TAPS);
    h.look(2, (0.0, 0.0), 0.5);
    let reply = h.ok(tap_command(CONTROL_OPTION, json!(2)));
    assert_eq!(reply["navigation"]["output"], 2, "{reply}");
    assert_eq!(reply["navigation"]["target_zoom"], 1.0);
    assert_eq!(
        h.error(tap_command(CONTROL_OPTION, Value::Null)),
        "no active output"
    );
    // With no output the prelude has no momentum to stop and the action no
    // view to act on; one that needs neither runs.
    assert_eq!(h.ok(tap_command(OPTION_SHIFT, Value::Null)), switched());

    // `pointer` and `held` are as `action` takes them. A tap bound to
    // focus-center centers the window under the pointer, and without one is
    // center-window since v0.20 (the focused window, here 2); a held
    // cycle-windows step stays open.
    let toml =
        "[keybindings]\n\"ctrl\" = \"focus-center\"\n\"shift\" = \"cycle-windows forward\"\n";
    let mut h = running(toml);
    for (wid, x) in [(1, 0.0), (2, 500.0)] {
        put(&mut h, wid, &format!("app.{wid}"), (x, 100.0, 300.0, 200.0));
        h.observe_focus(wid);
    }
    let reply = tap(&mut h, CONTROL);
    assert_eq!(
        armed(&reply, 1),
        view((650.0 - CENTER1.0, 200.0 - CENTER1.1), 1.0),
        "{reply}"
    );
    assert_eq!(reply["effects"][0]["window"], 2, "{reply}");
    let over = point(OUT1[0] + 100.0, OUT1[1] + 200.0);
    let mut command = tap_command(CONTROL, json!(1));
    command["pointer"] = over;
    let reply = h.ok(command);
    assert_eq!(
        armed(&reply, 1),
        view((150.0 - CENTER1.0, 200.0 - CENTER1.1), 1.0)
    );
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
    h.observe_focus(1);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    // Every modifier is up when a tap fires unless the shell says otherwise:
    // the step is committed as a release would commit it.
    let reply = tap(&mut h, SHIFT);
    // Both windows are whole on the view, so v0.20's Alt-Tab step is focus only.
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
    assert_eq!(h.focus_state()["release_pending"], true);
    let mut command = tap_command(SHIFT, json!(1));
    command["held"] = json!(true);
    h.ok(command);
    assert_eq!(h.focus_state()["release_pending"], false);
    assert_ne!(h.focus_state()["cycle"], Value::Null);
}

#[test]
fn a_chord_with_no_tap_binding_is_refused_and_changes_nothing() {
    // Mid-cycle and coasting: a refused tap is rolled back with its prelude,
    // which `error` checks against the whole snapshot.
    let mut h = mid_cycle(TAPS);
    assert_eq!(
        h.error(tap_command(CONTROL, json!(1))),
        "no tap binding on ⌃"
    );
    // The chord of a key binding is no tap: Option+Tab is `alt+Tab`, and
    // Option alone is bound to nothing.
    assert_eq!(
        h.error(tap_command([false, true, false, false], json!(1))),
        "no tap binding on ⌥"
    );
    assert_eq!(
        h.error(tap_command([true, true, true, false], json!(1))),
        "no tap binding on ⌃⌥⇧"
    );
    assert_eq!(
        h.error(tap_command([false; 4], json!(1))),
        "a tap needs a modifier"
    );
    // A tap whose action does not run here is refused by name, as from a key.
    assert_eq!(
        h.error(tap_command(SHIFT, json!(1))),
        "action not implemented on macOS yet: fit-window"
    );
    assert_eq!(h.focus_state()["cycle"], 1);
    assert!(coasting(&mut h));
    // The chord two taps map to runs the one that kept it: `ctrl+alt`, not
    // `mod`, so zoom-reset and not home-toggle.
    let reply = tap(&mut h, CONTROL_OPTION);
    assert_eq!(reply["navigation"]["target_zoom"], 1.0, "{reply}");
    assert_eq!(h.snapshot()["navigation"]["home_returns"], json!({}));
    // The modifiers are real booleans and the command has no other field.
    let response = h.call(
        json!({"op":"tap","modifiers":{"control":1,"option":0,"shift":0,"command":0},"output":1}),
    );
    assert_eq!(response["ok"], false, "{response}");
    let response = h.call(
        json!({"op":"tap","modifiers":chord(false, true, true, false),"output":1,"key_code":40}),
    );
    assert_eq!(response["ok"], false, "{response}");
    let response = h.call(json!({"op":"tap","output":1}));
    assert_eq!(response["ok"], false, "{response}");
}

// Upstream decides a tap in on_keyboard before, and whatever, the focused
// window's `pass_keys`: the chord completes on a release, and the pass test
// asks key presses only. So a tap fires over a window that takes every key.
#[test]
fn no_window_s_pass_keys_takes_a_tap() {
    let toml = format!(
        "{TAPS}[[window_rules]]\napp_id = \"game.all\"\npass_keys = true\n[[window_rules]]\napp_id = \"game.some\"\npass_keys = [\"alt+shift+k\", \"mod+q\"]\n"
    );
    let mut h = running(&toml);
    put(&mut h, 1, "game.all", (0.0, 100.0, 300.0, 200.0));
    put(&mut h, 2, "game.some", (500.0, 100.0, 300.0, 200.0));
    h.observe_focus(1);
    assert_eq!(h.snapshot()["pass_keys"], json!(true));
    assert_eq!(tap(&mut h, OPTION_SHIFT), switched());
    // The list of the other window names the chord that begins with the tap:
    // that key binding is the window's, the tap is still the canvas's.
    h.observe_focus(2);
    assert_eq!(h.snapshot()["pass_keys"], json!(["alt+shift+k", "mod+q"]));
    assert_eq!(tap(&mut h, OPTION_SHIFT), switched());
    // And the tap entries carry no `passable`: there is nothing to decide.
    let taps = h.bindings()["taps"].clone();
    assert!(
        taps.as_array()
            .unwrap()
            .iter()
            .all(|entry| entry.get("passable").is_none()),
        "{taps}"
    );
}

// A tap's reply is an action's: a size a fullscreen exit still owes leaves
// with it, under `transaction` and `effect`, as it leaves with an action's.
#[test]
fn a_tap_reply_carries_the_size_a_fullscreen_exit_owes() {
    let mut h = capable(TAPS);
    put(&mut h, 1, "app.1", (100.0, 100.0, 400.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = h.action(1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (1120.0, 770.0),
        "applied",
        (1120.0, 770.0),
    );
    // A scroll pan ends the fullscreen, and its reply is not one the shell
    // performs a size from: the size is owed.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(10.0, 0.0)}));
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], Value::Null);
    let reply = tap(&mut h, OPTION_SHIFT);
    assert_eq!(reply["effects"], switched()["effects"]);
    deliver(
        &mut h,
        &reply,
        (1120.0, 770.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(h.world(1), rect(100.0, 100.0, 400.0, 300.0));
}
