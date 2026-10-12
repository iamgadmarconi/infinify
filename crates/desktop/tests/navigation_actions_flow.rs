// SPDX-License-Identifier: GPL-3.0-or-later
//! Window navigation scenarios cross the exported C ABI and JSON decoder with
//! synthetic identities, focus results and observations, and settle through
//! tick_navigation. Config files are written to a throwaway directory; the
//! default config path is never read. They provide no evidence that a key or a
//! click reaches the shell, that a focus effect focuses a native window, or
//! that a native focus change is observed.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

struct Host {
    handle: *mut Controller,
    clock: u64,
    scratch: Scratch,
}
impl Host {
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
    fn action(&mut self, action: &str) -> Value {
        self.ok(json!({"op":"action","output":1,"action":action}))
    }
    /// A `cycle-windows` step fired while a real modifier is down.
    fn held(&mut self, action: &str) -> Value {
        self.ok(json!({"op":"action","output":1,"action":action,"held":true}))
    }
    fn focus_state(&mut self) -> Value {
        self.snapshot()["focus"].clone()
    }
    fn history(&mut self) -> Value {
        self.focus_state()["history"].clone()
    }
    fn focused(&mut self) -> Value {
        self.snapshot()["focus"]["intent"].clone()
    }
    /// Window ids bottom to top.
    fn stacking(&mut self) -> Vec<u64> {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|window| window["window"].as_u64().unwrap())
            .collect()
    }
    fn pose(&mut self, output: usize) -> Value {
        self.snapshot()["outputs"][output - 1].clone()
    }
    fn generation(&mut self, window: u64) -> Value {
        let windows = self.snapshot()["windows"].clone();
        let found = windows
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["window"] == window)
            .unwrap();
        found["source"]["generation"].clone()
    }
    /// Report that the adapter did what `effect` asked and read it back.
    fn confirm(&mut self, effect: &Value) {
        self.ok(json!({"op":"focus_result","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"],"success":true}));
    }
    /// Answer `effect` as a shell that performs no native focus does.
    fn logical(&mut self, effect: &Value) {
        self.ok(json!({"op":"focus_logical","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"]}));
    }
    /// Logical focus that the adapter confirms: the window enters the history.
    fn focus(&mut self, window: u64) {
        let effect = self.ok(json!({"op":"focus","window":window}))["effect"].clone();
        self.confirm(&effect);
    }
    /// Put output 1's camera at a world point and its zoom at `zoom`.
    fn look(&mut self, x: f64, y: f64, zoom: f64) {
        self.ok(json!({"op":"cancel_navigation","output":1}));
        // Zooming about the output's own corner leaves the camera where it is.
        self.ok(json!({"op":"zoom","output":1,"zoom":zoom,"anchor":point(ORIGIN.0, ORIGIN.1)}));
        let camera = self.pose(1)["camera"].clone();
        let delta = point(
            (x - camera["x"].as_f64().unwrap()) * zoom,
            (y - camera["y"].as_f64().unwrap()) * zoom,
        );
        self.ok(json!({"op":"pan","output":1,"screen_delta":delta}));
        assert_eq!(self.pose(1)["camera"], point(x, y));
        assert_eq!(self.pose(1)["zoom"], zoom);
    }
    /// Tick until every flight has landed.
    fn settle(&mut self) {
        for _ in 0..600 {
            self.clock += 16_666_667;
            let tick = self.ok(json!({"op":"tick_navigation","timestamp_ns":self.clock}));
            if tick["needs_frames"] == false {
                assert_eq!(self.snapshot()["navigation"]["flights"], json!({}));
                return;
            }
        }
        panic!("flight did not settle");
    }
    /// The flight `navigation` announces lands exactly where it says.
    fn lands(&mut self, navigation: &Value) {
        assert_eq!(navigation["animating"], true, "{navigation}");
        self.settle();
        let pose = self.pose(navigation["output"].as_u64().unwrap() as usize);
        assert_eq!(pose["camera"], navigation["target_camera"]);
        assert_eq!(pose["zoom"], navigation["target_zoom"]);
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
            "infinify-navigation-actions-flow-{}-{}",
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

/// Output 1's global top-left corner: not the global origin, so a global point
/// taken for an output-local one misses.
const ORIGIN: (f64, f64) = (300.0, 200.0);
/// Output 1's usable center in output-local points. The usable rectangle is
/// asymmetric, so the output's own center (500, 400) would miss every target.
const CENTER: (f64, f64) = (500.0, 410.0);
/// The file's one navigation anchor, Y up as a config file writes it. Its
/// world point is (500, 1400).
const ANCHORS: &str = "[navigation]\nanchors = [[500.0, -1400.0]]\n";
/// World frames by window id. A sits around the viewport center of a camera at
/// the world origin. C is a detached placeholder.
const A: (f64, f64, f64, f64) = (400.0, 300.0, 200.0, 200.0);
const B: (f64, f64, f64, f64) = (900.0, 150.0, 200.0, 100.0);
const C: (f64, f64, f64, f64) = (-300.0, 300.0, 200.0, 200.0);
const D: (f64, f64, f64, f64) = (450.0, -400.0, 100.0, 100.0);
const E: (f64, f64, f64, f64) = (1150.0, 1000.0, 200.0, 200.0);

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn point(x: f64, y: f64) -> Value {
    json!({"x":x,"y":y})
}
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid,"owner":null})
}
fn center(frame: (f64, f64, f64, f64)) -> (f64, f64) {
    (frame.0 + frame.2 / 2.0, frame.1 + frame.3 / 2.0)
}
/// The camera that puts a frame's center under output 1's usable center.
fn centered(frame: (f64, f64, f64, f64), zoom: f64) -> Value {
    let (x, y) = center(frame);
    point(x - CENTER.0 / zoom, y - CENTER.1 / zoom)
}
/// The global screen point that shows a world point on output 1.
fn pointer(h: &mut Host, x: f64, y: f64) -> Value {
    let pose = h.pose(1);
    let zoom = pose["zoom"].as_f64().unwrap();
    point(
        ORIGIN.0 + (x - pose["camera"]["x"].as_f64().unwrap()) * zoom,
        ORIGIN.1 + (y - pose["camera"]["y"].as_f64().unwrap()) * zoom,
    )
}
/// A new window with a bound source. Its native rectangle is elsewhere and of
/// another size: nothing here may read it.
fn attach(h: &mut Host, wid: u64, frame: (f64, f64, f64, f64)) {
    let window = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"world_rect":rect(frame.0,frame.1,frame.2,frame.3)}))["window"].clone();
    assert_eq!(window, wid);
}
/// One 1000 x 800 output with the given config in force and no window.
fn empty(toml: &str) -> Host {
    let handle = driftwm_desktop_create();
    assert!(!handle.is_null());
    let mut h = Host {
        handle,
        clock: 1_000_000_000,
        scratch: Scratch::new(),
    };
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":rect(ORIGIN.0,ORIGIN.1,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(20.0,40.0,960.0,740.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
    let path = h.scratch.0.join("config.toml");
    std::fs::write(&path, toml).unwrap();
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(reply["warnings"], json!([]), "{reply}");
    h.ok(json!({"op":"tick_navigation","timestamp_ns":1_000_000_000u64}));
    h
}
/// The five-window layout: 1 to 5 are A to E, and 3 (C) has lost its source.
fn layout(toml: &str) -> Host {
    let mut h = empty(toml);
    for (wid, frame) in [(1, A), (2, B), (3, C), (4, D), (5, E)] {
        attach(&mut h, wid, frame);
    }
    h.ok(json!({"op":"remove_source","window":3,"identity":identity(3),"keep_placeholder":true}));
    assert_eq!(h.focused(), Value::Null);
    h
}
/// The one focus effect of an action reply, which is also the pending effect.
fn effect(h: &mut Host, data: &Value, window: u64) -> Value {
    let effects = data["effects"].as_array().unwrap();
    assert_eq!(effects.len(), 1, "{data}");
    let effect = effects[0].clone();
    assert_eq!(effect["op"], "focus_native_window");
    assert_eq!(effect["window"], window);
    assert_eq!(effect["identity"], identity(window));
    assert_eq!(effect["generation"], h.generation(window));
    assert_eq!(h.focus_state()["pending_effect"], effect);
    assert_eq!(data["dirty"], true);
    effect
}
const NOTHING: &str = r#"{"navigation":null,"effects":[],"dirty":false}"#;
fn nothing() -> Value {
    serde_json::from_str(NOTHING).unwrap()
}

// The search origin is A's center (500, 400): A is focused and wholly on the
// output. Each candidate is its frame's point closest to the origin, at offset
// d; it is in the cone of unit direction u when d·u > 0 and |d×u| <= d·u, and
// the lowest |d|²/(d·u) wins.
//   B (900, 250)   d = (400, -150)
//   C (-100, 400)  d = (-600, 0)       the placeholder
//   D (500, -300)  d = (0, -700)
//   E (1150, 1000) d = (650, 600)
//   P (500, 1400)  d = (0, 1000)       the anchor
#[test]
fn center_nearest_takes_the_best_candidate_of_each_cone() {
    // right: B scores 182500/400 = 456.25 and E, also in the cone (600 <= 650),
    // 782500/650 = 1203.8.
    let mut h = layout(ANCHORS);
    h.focus(1);
    let data = h.action("center-nearest right");
    let wanted = effect(&mut h, &data, 2);
    assert_eq!(h.focused(), 2);
    assert_eq!(h.stacking().last(), Some(&2));
    // Nothing claims that native focus followed.
    assert_eq!(h.focus_state()["observed_native"]["window"], 1);
    assert_eq!(h.history(), json!([1]));
    assert_eq!(data["navigation"]["output"], 1);
    assert_eq!(data["navigation"]["target_camera"], centered(B, 1.0));
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(500.0, -210.0));
    h.confirm(&wanted);
    assert_eq!(h.history(), json!([2, 1]));

    // left: only the placeholder is in the cone. It is focused and flown to,
    // and there is no source to ask for native focus.
    let mut h = layout(ANCHORS);
    h.focus(1);
    let data = h.action("center-nearest LEFT");
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], true);
    assert_eq!(h.focused(), 3);
    assert_eq!(h.focus_state()["pending_effect"], Value::Null);
    assert_eq!(data["navigation"]["target_camera"], centered(C, 1.0));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(-700.0, -10.0));

    // up: D scores 700. B is outside the cone (cross 400 > dot 150).
    let mut h = layout(ANCHORS);
    h.focus(1);
    let data = h.action("center-nearest up");
    effect(&mut h, &data, 4);
    assert_eq!(data["navigation"]["target_camera"], centered(D, 1.0));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(0.0, -760.0));

    // down: the anchor scores 1000. E is outside the cone (cross 650 > dot
    // 600). Landing on an anchor clears focus and moves only the camera.
    let mut h = layout(ANCHORS);
    h.focus(1);
    let before = h.stacking();
    let data = h.action("center-nearest down");
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], true);
    assert_eq!(h.focused(), Value::Null);
    assert_eq!(h.focus_state()["intent"], Value::Null);
    assert_eq!(h.stacking(), before);
    assert_eq!(h.history(), json!([1]));
    assert_eq!(data["navigation"]["target_camera"], point(0.0, 990.0));
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    h.lands(&data["navigation"]);
    // The next search starts from the viewport center, which is now the
    // anchor (500, 1400). up: A's closest point (500, 500) scores 900, B
    // 1482500/1150 = 1289.1, C 1170000/900 = 1300, D 1700; the anchor itself
    // has no direction.
    let data = h.action("center-nearest up");
    effect(&mut h, &data, 1);

    // down-right: E scores 782500/883.9 = 885.3. The anchor sits exactly on the
    // cone's edge and scores 1000000/707.1 = 1414.2. B is outside (cross
    // 388.9 > dot 176.8).
    let mut h = layout(ANCHORS);
    h.focus(1);
    let data = h.action("center-nearest down-right");
    effect(&mut h, &data, 5);
    assert_eq!(data["navigation"]["target_camera"], centered(E, 1.0));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(750.0, 690.0));

    // Without the anchor nothing is below A, and nothing happens.
    let mut h = layout("");
    h.focus(1);
    let before = h.snapshot();
    assert_eq!(h.action("center-nearest down"), nothing());
    assert_eq!(h.snapshot(), before);
}

#[test]
fn center_nearest_keeps_the_zoom_and_starts_where_upstream_starts() {
    // Zoomed out, the camera still at the world origin: A is wholly on the
    // output, so the origin and the winners are as above, and the zoom stays.
    let mut h = layout(ANCHORS);
    h.focus(1);
    h.look(0.0, 0.0, 0.5);
    let data = h.action("center-nearest right");
    effect(&mut h, &data, 2);
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    assert_eq!(data["navigation"]["target_camera"], point(0.0, -620.0));
    h.lands(&data["navigation"]);
    let mut h = layout(ANCHORS);
    h.focus(1);
    h.look(0.0, 0.0, 0.5);
    let data = h.action("center-nearest down");
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    assert_eq!(data["navigation"]["target_camera"], point(-500.0, 580.0));
    h.lands(&data["navigation"]);
    assert_eq!(h.focused(), Value::Null);

    // A focused but clipped: the camera at (450, 0) cuts 50 points off its
    // left, so the search starts at the viewport center (950, 410) and A is a
    // candidate like any other.
    // up: B's closest point (950, 250) scores 160; D's (550, -300) 664100/710.
    let mut h = layout(ANCHORS);
    h.focus(1);
    h.look(450.0, 0.0, 1.0);
    let data = h.action("center-nearest up");
    effect(&mut h, &data, 2);
    // left: A's closest point (600, 410) scores 350, the placeholder's 1050.
    let mut h = layout(ANCHORS);
    h.focus(1);
    h.look(450.0, 0.0, 1.0);
    let data = h.action("center-nearest left");
    effect(&mut h, &data, 1);
    assert_eq!(data["navigation"]["target_camera"], centered(A, 1.0));

    // A pixel is enough: one point off the output's left edge, the focused
    // window no longer anchors the search.
    let mut h = layout(ANCHORS);
    h.focus(1);
    h.look(401.0, 0.0, 1.0);
    let data = h.action("center-nearest left");
    effect(&mut h, &data, 1);
    // Flush against the edge it still does, and the search goes past it.
    let mut h = layout(ANCHORS);
    h.focus(1);
    h.look(400.0, 0.0, 1.0);
    assert_eq!(h.action("center-nearest left")["effects"], json!([]));
    assert_eq!(h.focused(), 3);

    // Nothing focused: the viewport center (500, 410) lies inside A, and a
    // frame that holds the origin is found by its center (500, 400), ten
    // points up. up: A scores 10, D 710.
    let mut h = layout(ANCHORS);
    let data = h.action("center-nearest up");
    effect(&mut h, &data, 1);
    // down: A is behind the origin; the anchor is the only candidate. No
    // window was focused, so no saved state changes.
    let mut h = layout(ANCHORS);
    let data = h.action("center-nearest down");
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], false);
    assert_eq!(data["navigation"]["target_camera"], point(0.0, 990.0));
    assert_eq!(h.focused(), Value::Null);

    // A focused placeholder anchors the search as any window does: from C's
    // center (-200, 400), right finds A's edge (400, 400) at 600 before B's
    // (900, 250) at 1232500/1100.
    let mut h = layout(ANCHORS);
    h.look(-700.0, 0.0, 1.0);
    assert_eq!(
        h.ok(json!({"op":"focus","window":3}))["effect"],
        Value::Null
    );
    let data = h.action("center-nearest right");
    effect(&mut h, &data, 1);

    // The anchors are the file's: reloading without them removes the target.
    let mut h = layout(ANCHORS);
    let path = h.scratch.0.join("config.toml");
    std::fs::write(&path, "").unwrap();
    h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(h.action("center-nearest down"), nothing());

    // No output, an unknown output, and a gesture are refused untouched.
    let mut h = layout(ANCHORS);
    h.focus(1);
    assert_eq!(
        h.error(json!({"op":"action","output":null,"action":"center-nearest up"})),
        "no active output"
    );
    assert_eq!(
        h.error(json!({"op":"action","output":9,"action":"center-nearest up"})),
        "unknown output"
    );
    h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    for action in ["center-nearest up", "center-window", "focus-center"] {
        assert_eq!(
            h.error(json!({"op":"action","output":1,"action":action})),
            "navigation during active gesture"
        );
    }
}

// Nothing is focused and the camera is at the world origin, so every search
// starts at the viewport center (500, 410). These layouts are the ones where
// the frame's closest point and its center, and the cone score and the plain
// distance, pick different windows.
#[test]
fn center_nearest_measures_to_the_closest_point_and_scores_by_the_cone() {
    //   1 (700, 300, 2000, 200)  closest (700, 410)  center (1700, 400)
    //   2 (900, 360, 100, 100)   closest (900, 410)  center (950, 410)
    //   3 (300, 100, 3000, 100)  closest (500, 200)  center (1800, 150)
    let wide = || {
        let mut h = empty("");
        attach(&mut h, 1, (700.0, 300.0, 2000.0, 200.0));
        attach(&mut h, 2, (900.0, 360.0, 100.0, 100.0));
        attach(&mut h, 3, (300.0, 100.0, 3000.0, 100.0));
        h
    };
    // right: the wide window's near edge scores 200 and window 2's 400. By
    // their centers window 2 (450) would beat the wide one (1200.1).
    let mut h = wide();
    let data = h.action("center-nearest right");
    effect(&mut h, &data, 1);
    // up: window 3's edge is straight above, at 210. Its center, 1300 across
    // and 260 up, is outside the cone, as every other center is.
    let mut h = wide();
    let data = h.action("center-nearest up");
    effect(&mut h, &data, 3);

    //   1 (800, 700, 100, 100)  closest (800, 700)  d = (300, 290)
    //   2 (950, 360, 100, 100)  closest (950, 410)  d = (450, 0)
    // right: window 1 is the nearer, 417.3 against 450, and inside the cone
    // (290 <= 300), but it scores 174100/300 = 580.3 against window 2's 450.
    let mut h = empty("");
    attach(&mut h, 1, (800.0, 700.0, 100.0, 100.0));
    attach(&mut h, 2, (950.0, 360.0, 100.0, 100.0));
    let data = h.action("center-nearest right");
    effect(&mut h, &data, 2);
}

#[test]
fn center_window_takes_the_focused_window_or_the_nearest_one() {
    // Focused: that window, at zoom 1 whatever the zoom was.
    let mut h = layout("");
    h.focus(2);
    h.look(0.0, 0.0, 0.5);
    let data = h.action("center-window");
    effect(&mut h, &data, 2);
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(data["navigation"]["target_camera"], centered(B, 1.0));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(500.0, -210.0));
    assert_eq!(h.pose(1)["zoom"], 1.0);

    // A focused placeholder is centered like any other focused window.
    let mut h = layout("");
    h.ok(json!({"op":"focus","window":3}));
    let data = h.action("center-window");
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], true);
    assert_eq!(data["navigation"]["target_camera"], centered(C, 1.0));

    // Nothing focused: the window whose center is nearest the viewport
    // center. At zoom 0.5 that is (1000, 820): E's center (1250, 1100) is
    // 375.4 away, B's 620 and A's 653.
    let mut h = layout("");
    h.look(0.0, 0.0, 0.5);
    let data = h.action("center-window");
    effect(&mut h, &data, 5);
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(data["navigation"]["target_camera"], centered(E, 1.0));
    h.lands(&data["navigation"]);
    // From (-200, 410) it is the placeholder: focused, flown to, no effect.
    let mut h = layout("");
    h.look(-700.0, 0.0, 1.0);
    let data = h.action("center-window");
    assert_eq!(data["effects"], json!([]));
    assert_eq!(data["dirty"], true);
    assert_eq!(h.focused(), 3);
    assert_eq!(h.stacking().last(), Some(&3));
    assert_eq!(data["navigation"]["target_camera"], centered(C, 1.0));
    h.lands(&data["navigation"]);

    // No window at all: nothing to do, and no error.
    let mut h = empty("");
    let before = h.snapshot();
    assert_eq!(h.action("center-window"), nothing());
    assert_eq!(h.snapshot(), before);
    assert_eq!(
        h.error(json!({"op":"action","output":null,"action":"center-window"})),
        "no active output"
    );
}

#[test]
fn cycle_windows_holds_commits_and_yields_to_other_actions() {
    let mut h = layout("");
    // Nothing confirmed yet: the history is empty and there is nothing to step.
    let before = h.snapshot();
    assert_eq!(h.action("cycle-windows forward"), nothing());
    assert_eq!(h.snapshot(), before);
    for window in [1, 2, 4] {
        h.focus(window);
    }
    assert_eq!(h.history(), json!([4, 2, 1]));
    h.look(0.0, 0.0, 0.5);

    // Held: each step selects, focuses and flies at the current zoom, and the
    // history stays frozen until the release.
    let data = h.held("cycle-windows forward");
    let first = effect(&mut h, &data, 2);
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    assert_eq!(data["navigation"]["target_camera"], centered(B, 0.5));
    assert_eq!(h.focused(), 2);
    assert_eq!(h.focus_state()["cycle"], 1);
    assert_eq!(h.focus_state()["release_pending"], false);
    h.confirm(&first);
    assert_eq!(h.history(), json!([4, 2, 1]));
    let data = h.held("cycle-windows forward");
    let second = effect(&mut h, &data, 1);
    assert_eq!(h.focus_state()["cycle"], 2);
    h.confirm(&second);
    assert_eq!(h.history(), json!([4, 2, 1]));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], centered(A, 0.5));
    h.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(h.history(), json!([1, 4, 2]));
    assert_eq!(h.focus_state()["cycle"], Value::Null);

    // Not held: one committed step. The commit waits for the adapter's result.
    let data = h.action("cycle-windows forward");
    let step = effect(&mut h, &data, 4);
    assert_eq!(h.focus_state()["release_pending"], true);
    assert_eq!(h.history(), json!([1, 4, 2]));
    h.confirm(&step);
    assert_eq!(h.history(), json!([4, 1, 2]));
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    // `held` false is the same, and a fresh backward step is upstream's index one.
    let data =
        h.ok(json!({"op":"action","output":1,"action":"cycle-windows backward","held":false}));
    let step = effect(&mut h, &data, 1);
    h.confirm(&step);
    assert_eq!(h.history(), json!([1, 4, 2]));
    // A held backward step from index one wraps to the tail.
    let data = h.held("cycle-windows forward");
    effect(&mut h, &data, 4);
    let data = h.held("cycle-windows backward");
    effect(&mut h, &data, 1);
    let data = h.held("cycle-windows backward");
    let step = effect(&mut h, &data, 2);
    h.confirm(&step);
    h.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(h.history(), json!([2, 1, 4]));

    // Any other action ends a held cycle first, committing a confirmed selection.
    for other in ["zoom-in", "set-bookmark x", "quit", "center-nearest up"] {
        let head = h.history()[0].clone();
        let data = h.held("cycle-windows forward");
        let step = data["effects"][0].clone();
        assert_ne!(step["window"], head);
        h.confirm(&step);
        assert_eq!(h.history()[0], head, "{other}");
        h.action(other);
        assert_eq!(h.focus_state()["cycle"], Value::Null, "{other}");
        assert_eq!(h.history()[0], step["window"], "{other}");
    }
    // So does one that reaches the handler through `ipc`.
    h.focus(4);
    let data = h.held("cycle-windows forward");
    let step = data["effects"][0].clone();
    h.confirm(&step);
    let reply = h.ok(json!({"op":"ipc","output":1,"request":{"Action":"zoom-out"}}));
    assert_eq!(reply["reply"], json!({"Ok":"Ok"}));
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.history()[0], step["window"]);

    // A selection still waiting for its result is not promoted by the action;
    // its own result promotes it afterwards.
    let history = h.history();
    let data = h.held("cycle-windows forward");
    let step = data["effects"][0].clone();
    h.action("pan-viewport left");
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.history(), history);
    assert_eq!(h.focus_state()["pending_effect"], step);
    h.confirm(&step);
    assert_eq!(h.history()[0], step["window"]);

    // The direct command is not an action and leaves the cycle open. A refused
    // action and an unparseable one change nothing at all.
    let data = h.held("cycle-windows forward");
    h.confirm(&data["effects"][0]);
    h.ok(json!({"op":"zoom_in","output":1}));
    assert_eq!(h.focus_state()["cycle"], 1);
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"fill-window"})),
        "action not implemented on macOS yet: fill-window"
    );
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"frobnicate"})),
        "unknown action: frobnicate"
    );
    assert_eq!(h.focus_state()["cycle"], 1);
    // A request is never held: one committed step.
    let reply = h.ok(json!({"op":"ipc","output":1,"request":{"Action":"cycle-windows forward"}}));
    assert_eq!(reply["dirty"], true);
    assert_eq!(reply["effects"][0]["op"], "focus_native_window");
    assert_eq!(h.focus_state()["release_pending"], true);
    h.confirm(&reply["effects"][0]);
    assert_eq!(h.focus_state()["cycle"], Value::Null);

    // The fresh-cycle anchor is the logical focus. A focused placeholder is
    // not the history's head, so the cycle returns to the head.
    let head = h.history()[0].clone();
    h.ok(json!({"op":"focus","window":3}));
    let data = h.held("cycle-windows forward");
    assert_eq!(data["effects"][0]["window"], head);
    h.ok(json!({"op":"cancel_focus_cycle"}));

    // `held` is a boolean, and the action still needs an output.
    for held in [json!(1), json!("true"), Value::Null] {
        h.error(json!({"op":"action","output":1,"action":"cycle-windows forward","held":held}));
    }
    assert_eq!(
        h.error(json!({"op":"action","output":null,"action":"cycle-windows forward"})),
        "no active output"
    );
}

#[test]
fn focus_center_takes_the_window_under_the_pointer() {
    let mut h = layout("");
    h.look(0.0, 0.0, 0.5);
    // Over B: focused, raised, flown to at zoom 1.
    let over = pointer(&mut h, 950.0, 200.0);
    assert_eq!(over, point(775.0, 300.0));
    let data =
        h.ok(json!({"op":"action","output":1,"action":"focus-center","pointer":over.clone()}));
    effect(&mut h, &data, 2);
    assert_eq!(h.stacking().last(), Some(&2));
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(data["navigation"]["target_camera"], centered(B, 1.0));
    h.lands(&data["navigation"]);

    // The same request through `ipc`, over the placeholder: no effect.
    let mut h = layout("");
    let over = pointer(&mut h, -150.0, 350.0);
    h.look(-700.0, 0.0, 1.0);
    let over_now = pointer(&mut h, -150.0, 350.0);
    assert_ne!(over, over_now);
    let reply =
        h.ok(json!({"op":"ipc","output":1,"request":{"Action":"focus-center"},"pointer":over_now}));
    assert_eq!(reply["reply"], json!({"Ok":"Ok"}));
    assert_eq!(reply["effects"], json!([]));
    assert_eq!(reply["dirty"], true);
    assert_eq!(reply["navigation"]["target_camera"], centered(C, 1.0));
    assert_eq!(h.focused(), 3);

    // Of two overlapping windows the topmost is taken.
    let mut h = empty("");
    attach(&mut h, 1, (0.0, 0.0, 400.0, 300.0));
    attach(&mut h, 2, (200.0, 100.0, 400.0, 300.0));
    let over = pointer(&mut h, 300.0, 200.0);
    let data =
        h.ok(json!({"op":"action","output":1,"action":"focus-center","pointer":over.clone()}));
    effect(&mut h, &data, 2);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    h.focus(1);
    let data =
        h.ok(json!({"op":"action","output":1,"action":"focus-center","pointer":over.clone()}));
    effect(&mut h, &data, 1);
    h.ok(json!({"op":"cancel_navigation","output":1}));

    // Empty canvas under the pointer, a pointer off the output, and no pointer
    // at all: nothing happens, and it is no error.
    let before = h.snapshot();
    for pointer in [
        pointer(&mut h, 700.0, 500.0),
        point(100.0, 100.0),
        Value::Null,
    ] {
        let data =
            h.ok(json!({"op":"action","output":1,"action":"focus-center","pointer":pointer}));
        assert_eq!(data, nothing());
    }
    assert_eq!(h.action("focus-center"), nothing());
    assert_eq!(h.snapshot(), before);
    // A point no screen could hold is the shell's mistake.
    for (op, key, value) in [
        ("action", "action", json!("focus-center")),
        ("ipc", "request", json!({"Action":"focus-center"})),
    ] {
        assert_eq!(
            h.error(json!({"op":op,"output":1,key:value,"pointer":point(1e13, 0.0)})),
            "invalid pointer"
        );
    }
    assert_eq!(
        h.error(json!({"op":"action","output":null,"action":"focus-center","pointer":over})),
        "no active output"
    );
}

// Two more windows for the visibility rules, with the camera at the world
// origin and the zoom at 0.5: the output shows (0, 0) to (2000, 1600) and its
// usable area (40, 80) to (1960, 1560).
//   F (0, 600, 100, 100)    wholly on the output, 40 points outside the usable area
//   G (-50, 900, 100, 100)  half off the output's left edge
//   A                       wholly inside both
//   D                       off the output altogether
const F: (f64, f64, f64, f64) = (0.0, 600.0, 100.0, 100.0);
const G: (f64, f64, f64, f64) = (-50.0, 900.0, 100.0, 100.0);
fn activation(toml: &str) -> Host {
    let mut h = layout(toml);
    attach(&mut h, 6, F);
    attach(&mut h, 7, G);
    h.look(0.0, 0.0, 0.5);
    h
}
fn click(h: &mut Host, window: u64, output: Value) -> Value {
    h.ok(json!({"op":"activate","window":window,"output":output,"cause":"click"}))
}
/// The press of `click` let go as a completed click.
fn released(h: &mut Host, window: u64, output: Value) -> Value {
    h.ok(json!({"op":"activate","window":window,"output":output,"cause":"click_release"}))
}
fn native(h: &mut Host, window: u64, output: Value) -> Value {
    h.ok(json!({"op":"activate","window":window,"output":output,"cause":"native"}))
}
/// What a release that reveals nothing replies: no flight, nothing to save,
/// and no `effect` key, which would tell the shell that focus had moved.
fn unmoved() -> Value {
    json!({"navigation":null,"dirty":false})
}

#[test]
fn a_click_focuses_at_the_press_and_navigates_at_the_release_when_configured() {
    // Upstream's default: a click raises and focuses, and never moves the camera.
    let mut h = activation("");
    for window in [1, 6, 7, 4] {
        let data = click(&mut h, window, json!(1));
        assert_eq!(data["navigation"], Value::Null, "{window}");
        let wanted = data["effect"].clone();
        assert_eq!(wanted["op"], "focus_native_window");
        assert_eq!(wanted["window"], window);
        assert_eq!(wanted["identity"], identity(window));
        assert_eq!(wanted["generation"], h.generation(window));
        assert_eq!(h.focus_state()["pending_effect"], wanted);
        assert_eq!(h.focused(), window);
        assert_eq!(h.stacking().last(), Some(&window));
        // The request is not the observation.
        assert_ne!(h.focus_state()["observed_native"]["window"], window);
        // The release changes nothing: not the camera, and not the request.
        let before = h.snapshot();
        assert_eq!(released(&mut h, window, json!(1)), unmoved(), "{window}");
        assert_eq!(h.snapshot(), before);
        h.confirm(&wanted);
        assert_eq!(h.focus_state()["observed_native"]["window"], window);
    }
    assert_eq!(h.history(), json!([4, 7, 6, 1]));
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    // A placeholder is focused, with nothing to ask of the adapter.
    assert_eq!(
        click(&mut h, 3, json!(1)),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.focused(), 3);
    // A click ends a held cycle, committing the confirmed selection.
    h.focus(4);
    let step = h.held("cycle-windows forward")["effects"][0].clone();
    h.confirm(&step);
    click(&mut h, 1, json!(1));
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.history()[0], step["window"]);

    // auto_navigate_on_click: the press still only focuses, so that it and its
    // drags reach the window where the pointer is. The release of a completed
    // click flies to a frame that is not wholly inside the usable area, at the
    // current zoom; one that is, is left alone.
    let mut h = activation("[navigation]\nauto_navigate_on_click = true\n");
    assert_eq!(click(&mut h, 1, json!(1))["navigation"], Value::Null);
    assert_eq!(released(&mut h, 1, json!(1)), unmoved());
    let press = click(&mut h, 6, json!(1));
    assert_eq!(press["navigation"], Value::Null);
    assert_eq!(press["effect"]["window"], 6);
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    let data = released(&mut h, 6, json!(1));
    // Nothing is asked again: the press's request is still the pending one.
    assert_eq!(data.get("effect"), None);
    assert_eq!(data["dirty"], false);
    assert_eq!(h.focus_state()["pending_effect"], press["effect"]);
    assert_eq!(data["navigation"]["output"], 1);
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    assert_eq!(data["navigation"]["target_camera"], centered(F, 0.5));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(-950.0, -170.0));
    h.confirm(&press["effect"]);
    // Now wholly in view: a second click moves nothing.
    assert_eq!(click(&mut h, 6, json!(1))["navigation"], Value::Null);
    assert_eq!(released(&mut h, 6, json!(1)), unmoved());
    h.look(0.0, 0.0, 0.5);
    assert_eq!(click(&mut h, 4, json!(1))["navigation"], Value::Null);
    let data = released(&mut h, 4, json!(1));
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    assert_eq!(data["navigation"]["target_camera"], centered(D, 0.5));
    // Focus went elsewhere before the button came up: the user is not pulled back.
    h.look(0.0, 0.0, 0.5);
    click(&mut h, 4, json!(1));
    h.ok(json!({"op":"focus","window":1}));
    assert_eq!(released(&mut h, 4, json!(1)), unmoved());
    assert_eq!(h.focused(), 1);
    // The placeholder too, still without an effect.
    assert_eq!(
        click(&mut h, 3, json!(1)),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    let data = released(&mut h, 3, json!(1));
    assert_eq!(data.get("effect"), None);
    assert_eq!(data["navigation"]["target_camera"], centered(C, 0.5));
    // With no active output there is nowhere to navigate.
    h.look(0.0, 0.0, 0.5);
    let data = click(&mut h, 4, Value::Null);
    assert_eq!(data["effect"]["window"], 4);
    assert_eq!(data["navigation"], Value::Null);
    assert_eq!(released(&mut h, 4, Value::Null), unmoved());

    // Refusals change nothing.
    for cause in ["click", "click_release"] {
        for (command, error) in [
            (
                json!({"op":"activate","window":99,"output":1,"cause":cause}),
                "unknown window",
            ),
            (
                json!({"op":"activate","window":1,"output":9,"cause":cause}),
                "unknown output",
            ),
            (
                json!({"op":"activate","window":1,"output":1,"cause":cause,"identity":identity(2)}),
                "stale source identity",
            ),
            (
                json!({"op":"activate","window":1,"output":1,"cause":cause,"generation":99}),
                "stale binding generation",
            ),
        ] {
            assert_eq!(h.error(command), error);
        }
    }
    h.error(json!({"op":"activate","window":1,"output":1,"cause":"hover"}));
    h.error(json!({"op":"activate","window":1,"output":1}));
    // A press during a gesture still focuses; the flight its release would
    // arm is refused.
    h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    assert_eq!(click(&mut h, 7, json!(1))["navigation"], Value::Null);
    assert_eq!(h.focused(), 7);
    assert_eq!(
        h.error(json!({"op":"activate","window":7,"output":1,"cause":"click_release"})),
        "navigation during active gesture"
    );
}

#[test]
fn cycle_windows_follows_logical_focus_when_no_adapter_performs_it() {
    // The shell of a run without Accessibility access, or with
    // --no-native-focus, answers every request `focus_logical`. The focused
    // window then enters the history as upstream's keyboard focus does, and
    // nothing is ever recorded as observed.
    let mut h = layout("");
    for window in [1, 2, 4] {
        let wanted = click(&mut h, window, json!(1))["effect"].clone();
        // The request alone promotes nothing.
        assert!(!h.history().as_array().unwrap().contains(&json!(window)));
        h.logical(&wanted);
        let state = h.focus_state();
        assert_eq!(state["pending_effect"], Value::Null);
        assert_eq!(state["observed_native"], Value::Null);
        assert_eq!(
            state["last_result"],
            json!({"effect":wanted,"success":false,"logical":true})
        );
        assert_eq!(state["history"][0], window);
    }
    assert_eq!(h.history(), json!([4, 2, 1]));
    // A placeholder has no request to answer and stays out of the order.
    assert_eq!(click(&mut h, 3, json!(1))["effect"], Value::Null);
    assert_eq!(h.history(), json!([4, 2, 1]));
    let wanted = click(&mut h, 4, json!(1))["effect"].clone();
    h.logical(&wanted);
    assert_eq!(h.history(), json!([4, 2, 1]));

    // Not held: one step, committed when its answer arrives.
    let data = h.action("cycle-windows forward");
    let step = effect(&mut h, &data, 2);
    assert_eq!(data["navigation"]["target_camera"], centered(B, 1.0));
    assert_eq!(h.focus_state()["release_pending"], true);
    assert_eq!(h.history(), json!([4, 2, 1]));
    h.logical(&step);
    assert_eq!(h.history(), json!([2, 4, 1]));
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.focused(), 2);

    // Held: the steps go past the second window with the history frozen, and
    // the release commits the selection.
    let data = h.held("cycle-windows forward");
    let first = effect(&mut h, &data, 4);
    h.logical(&first);
    assert_eq!(h.focus_state()["cycle"], 1);
    let data = h.held("cycle-windows forward");
    let second = effect(&mut h, &data, 1);
    h.logical(&second);
    assert_eq!(h.focus_state()["cycle"], 2);
    assert_eq!(h.history(), json!([2, 4, 1]));
    h.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(h.history(), json!([1, 2, 4]));
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    // A release that comes before the answer waits for it.
    let data = h.held("cycle-windows backward");
    let step = effect(&mut h, &data, 2);
    h.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(h.focus_state()["release_pending"], true);
    assert_eq!(h.history(), json!([1, 2, 4]));
    h.logical(&step);
    assert_eq!(h.history(), json!([2, 1, 4]));

    // Another action commits a held selection, and so does a click, which
    // then puts the clicked window on top.
    let data = h.held("cycle-windows forward");
    let step = effect(&mut h, &data, 1);
    h.logical(&step);
    h.action("zoom-in");
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.history(), json!([1, 2, 4]));
    let data = h.held("cycle-windows forward");
    let step = effect(&mut h, &data, 2);
    h.logical(&step);
    let wanted = click(&mut h, 4, json!(1))["effect"].clone();
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.history(), json!([2, 1, 4]));
    h.logical(&wanted);
    assert_eq!(h.history(), json!([4, 2, 1]));
    assert_eq!(h.focus_state()["observed_native"], Value::Null);

    // Only the pending request can be answered, and only once.
    let old = click(&mut h, 1, json!(1))["effect"].clone();
    let new = click(&mut h, 2, json!(1))["effect"].clone();
    let answer = |effect: &Value| json!({"op":"focus_logical","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"]});
    assert_eq!(h.error(answer(&old)), "stale or superseded focus result");
    h.logical(&new);
    assert_eq!(h.error(answer(&new)), "stale or superseded focus result");
    assert_eq!(h.history(), json!([2, 4, 1]));
    // A logical answer does not vouch for the next request: a step that is
    // still pending is not committed by another action.
    let data = h.held("cycle-windows forward");
    let step = effect(&mut h, &data, 4);
    h.action("zoom-out");
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.history(), json!([2, 4, 1]));
    h.logical(&step);
    assert_eq!(h.history(), json!([4, 2, 1]));
    // An adapter that tried and failed is still a failure: the cycle is
    // cancelled and nothing is promoted.
    let data = h.held("cycle-windows forward");
    let step = effect(&mut h, &data, 2);
    h.ok(json!({"op":"focus_result","effect_id":step["effect_id"],"window":2,"identity":identity(2),"generation":step["generation"],"success":false}));
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.history(), json!([4, 2, 1]));
    assert_eq!(h.focus_state()["last_result"]["success"], false);
    assert_eq!(h.focus_state()["last_result"].get("logical"), None);
    h.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(h.history(), json!([4, 2, 1]));
}

#[test]
fn native_focus_is_followed_by_upstreams_reveal_rule() {
    // Wholly on the output, even outside the usable area: focus follows and
    // the camera stays. Nothing is asked of the adapter: the shell saw it.
    let mut h = activation("");
    h.focus(2);
    let pending = h.ok(json!({"op":"focus","window":4}))["effect"].clone();
    for window in [1, 6] {
        let generation = h.generation(window);
        assert_eq!(
            native(&mut h, window, json!(1)),
            json!({"effect":null,"navigation":null,"dirty":true})
        );
        assert_eq!(h.focused(), window);
        assert_eq!(h.stacking().last(), Some(&window));
        let state = h.focus_state();
        assert_eq!(state["pending_effect"], Value::Null);
        assert_eq!(
            state["observed_native"],
            json!({"op":"observed_native_focus","effect_id":0,"window":window,"identity":identity(window),"generation":generation})
        );
        assert_eq!(state["history"][0], window);
    }
    assert_eq!(h.history(), json!([6, 1, 2]));
    // The request the observation superseded is stale.
    h.error(json!({"op":"focus_result","effect_id":pending["effect_id"],"window":4,"identity":identity(4),"generation":pending["generation"],"success":true}));
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));

    // Clipped by the output: flown to on that output, at zoom 1 by default.
    let data = native(&mut h, 7, json!(1));
    assert_eq!(data["effect"], Value::Null);
    assert_eq!(data["navigation"]["output"], 1);
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(data["navigation"]["target_camera"], centered(G, 1.0));
    assert_eq!(h.history(), json!([7, 6, 1, 2]));
    // Already focused, observed and partly on screen: the same request again
    // asks for what holds, and nothing moves. This is what keeps a repeated
    // observation from flying the camera again.
    h.ok(json!({"op":"cancel_navigation","output":1}));
    let before = h.snapshot();
    assert_eq!(
        native(&mut h, 7, json!(1)),
        json!({"effect":null,"navigation":null,"dirty":false})
    );
    assert_eq!(h.snapshot(), before);
    // Off screen entirely it is not already active: there is somewhere to go.
    h.look(3000.0, 3000.0, 0.5);
    let data = native(&mut h, 7, json!(1));
    assert_eq!(data["navigation"]["target_camera"], centered(G, 1.0));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(-500.0, 540.0));
    assert_eq!(h.pose(1)["zoom"], 1.0);
    // Off the output altogether, from another window.
    h.look(0.0, 0.0, 0.5);
    let data = native(&mut h, 4, json!(1));
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(data["navigation"]["target_camera"], centered(D, 1.0));
    assert_eq!(h.history(), json!([4, 7, 6, 1, 2]));

    // zoom.reset_on_activation off: the zoom is kept, for an activation and
    // for the IPC focus alike. A click does not read it.
    let mut h = activation("[zoom]\nreset_on_activation = false\n");
    let data = native(&mut h, 7, json!(1));
    assert_eq!(data["navigation"]["target_zoom"], 0.5);
    assert_eq!(data["navigation"]["target_camera"], centered(G, 0.5));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(-1000.0, 130.0));
    h.look(0.0, 0.0, 0.5);
    let reply = h.ok(json!({"op":"ipc","output":1,"request":{"Focus":4}}));
    assert_eq!(reply["navigation"]["target_zoom"], 0.5);
    assert_eq!(reply["navigation"]["target_camera"], centered(D, 0.5));

    // It ends a held cycle and supersedes the step's pending request.
    let mut h = activation("");
    for window in [1, 2] {
        h.focus(window);
    }
    let step = h.held("cycle-windows forward")["effects"][0].clone();
    assert_eq!(step["window"], 1);
    native(&mut h, 6, json!(1));
    let state = h.focus_state();
    assert_eq!(state["cycle"], Value::Null);
    assert_eq!(state["pending_effect"], Value::Null);
    assert_eq!(state["history"], json!([6, 2, 1]));

    // The binding the shell names must be the current one, and there must be
    // one: a placeholder cannot hold native focus.
    let generation = h.generation(1);
    let data = h.ok(json!({"op":"activate","window":1,"output":1,"cause":"native","identity":identity(1),"generation":generation}));
    assert_eq!(data, json!({"effect":null,"navigation":null,"dirty":true}));
    assert_eq!(h.history(), json!([1, 6, 2]));
    for (command, error) in [
        (
            json!({"op":"activate","window":2,"output":1,"cause":"native","identity":identity(1)}),
            "stale source identity",
        ),
        (
            json!({"op":"activate","window":2,"output":1,"cause":"native","generation":99}),
            "stale binding generation",
        ),
        (
            json!({"op":"activate","window":3,"output":1,"cause":"native"}),
            "unbound source",
        ),
        (
            json!({"op":"activate","window":3,"output":1,"cause":"native","identity":identity(3)}),
            "unbound source",
        ),
    ] {
        assert_eq!(h.error(command), error);
    }
}

#[test]
fn native_activation_pans_the_output_the_window_lives_on() {
    let mut h = activation("");
    // A second output, registered later, looking at a far part of the world:
    // (5000, 5000) to (5800, 5600) at zoom 1. Its usable area is all of it.
    h.ok(json!({"op":"register_output","stable_id":"view-b","screen_bounds":rect(1400.0,200.0,800.0,600.0)}));
    h.ok(json!({"op":"pan","output":2,"screen_delta":point(5000.0, 5000.0)}));
    assert_eq!(h.pose(2)["camera"], point(5000.0, 5000.0));
    // H's center (5750, 5300) is shown there and nowhere else, and its right
    // 50 points are cut off.
    attach(&mut h, 8, (5650.0, 5200.0, 200.0, 200.0));
    let first = h.pose(1);
    let data = native(&mut h, 8, json!(1));
    assert_eq!(data["navigation"]["output"], 2);
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(data["navigation"]["target_camera"], point(5350.0, 5000.0));
    h.lands(&data["navigation"]);
    assert_eq!(h.pose(1), first);
    // Wholly visible there now: activating it again from output 1 moves nothing.
    h.focus(1);
    assert_eq!(
        native(&mut h, 8, json!(1)),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    // Both outputs show A's center: the first registered is its home, so a
    // clipped A pans output 1 even when output 2 is the active one.
    h.ok(json!({"op":"pan","output":2,"screen_delta":point(-5000.0, -5000.0)}));
    h.look(450.0, 0.0, 1.0);
    let data = native(&mut h, 1, json!(2));
    assert_eq!(data["navigation"]["output"], 1);
    assert_eq!(data["navigation"]["target_camera"], centered(A, 1.0));
    // A window no output shows is revealed on the active one, and with no
    // active output only focus follows.
    h.ok(json!({"op":"cancel_navigation","output":1}));
    let data = native(&mut h, 4, json!(2));
    assert_eq!(data["navigation"]["output"], 2);
    assert_eq!(data["navigation"]["target_camera"], point(100.0, -650.0));
    h.ok(json!({"op":"cancel_navigation","output":2}));
    h.focus(1);
    assert_eq!(
        native(&mut h, 4, Value::Null),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.focused(), 4);
    assert_eq!(h.focus_state()["observed_native"]["window"], 4);
}

#[test]
fn clear_focus_and_the_reported_cycle_hold() {
    let mut h = layout("");
    for window in [1, 2] {
        h.focus(window);
    }
    let step = h.held("cycle-windows forward")["effects"][0].clone();
    let order = h.stacking();
    // A click on empty canvas: no window is focused, the cycle is over, the
    // pending request is gone, and what the adapter last saw is still true.
    assert_eq!(h.ok(json!({"op":"clear_focus"})), json!({"dirty":true}));
    let state = h.focus_state();
    assert_eq!(h.focused(), Value::Null);
    assert_eq!(state["intent"], Value::Null);
    assert_eq!(state["cycle"], Value::Null);
    assert_eq!(state["pending_effect"], Value::Null);
    assert_eq!(state["observed_native"]["window"], 2);
    assert_eq!(state["history"], json!([2, 1]));
    assert_eq!(h.stacking(), order);
    h.error(json!({"op":"focus_result","effect_id":step["effect_id"],"window":1,"identity":identity(1),"generation":step["generation"],"success":true}));
    // Nothing is focused for the actions that act on the focused window.
    assert_eq!(h.action("nudge-window left")["dirty"], false);
    assert_eq!(
        h.ok(json!({"op":"ipc","output":1,"request":{"Focus":null}}))["reply"],
        json!({"Ok":{"Focused":null}})
    );
    // The unfocused scene saves and loads as such.
    let path = h.scratch.0.join("scene.json");
    h.ok(json!({"op":"save","path":path}));
    h.ok(json!({"op":"load","path":path}));
    assert_eq!(h.focused(), Value::Null);
    // With nothing focused there is nothing to save.
    assert_eq!(h.ok(json!({"op":"clear_focus"})), json!({"dirty":false}));
    h.error(json!({"op":"clear_focus","window":1}));

    // The modifiers that hold a cycle open, as the shell must watch them.
    let option = json!({"control":false,"option":true,"shift":false,"command":false});
    let keys = h.ok(json!({"op":"bindings"}));
    assert_eq!(keys["cycle_hold"], option);
    for (combo, action) in [
        ("alt+Tab", "cycle-windows forward"),
        ("alt+shift+Tab", "cycle-windows backward"),
        ("mod+c", "center-window"),
        ("mod+x", "focus-center"),
        ("mod+Left", "center-nearest left"),
    ] {
        let key = keys["keys"]
            .as_array()
            .unwrap()
            .iter()
            .find(|key| key["combo"] == combo)
            .unwrap();
        assert_eq!(key["action"], action);
        assert_eq!(key["implemented"], true, "{combo}");
    }
    // They follow the `cycle-windows forward` binding, through the super chord.
    let rebound = "[bindings]\ndisable_defaults = [\"keys\"]\n[keybindings]\n\"mod+Tab\" = \"cycle-windows forward\"\n";
    let mut h = empty(rebound);
    assert_eq!(
        h.ok(json!({"op":"bindings"}))["cycle_hold"],
        json!({"control":false,"option":false,"shift":false,"command":true})
    );
    h.ok(json!({"op":"set_platform","super":"cmd"}));
    assert_eq!(
        h.ok(json!({"op":"bindings"}))["cycle_hold"],
        json!({"control":false,"option":false,"shift":false,"command":true})
    );
    // Unbound, upstream falls back to alt.
    let mut h = empty("[bindings]\ndisable_defaults = [\"keys\"]\n");
    assert_eq!(h.ok(json!({"op":"bindings"}))["cycle_hold"], option);
}

/// Hot corners on every output: window navigation actions, and an action of
/// another family.
const CORNERS: &str = r#"
[[outputs]]
name = "*"
[outputs.hot_corners]
top_left = "focus-center"
top_right = "cycle-windows forward"
bottom_left = "send-to-output right"
"#;
#[test]
fn a_hot_corner_runs_window_navigation_with_the_pointer_and_modifiers_it_fires_under() {
    let mut h = layout(CORNERS);
    for window in [1, 2, 4] {
        h.focus(window);
    }
    assert_eq!(h.history(), json!([4, 2, 1]));
    let corner = |h: &mut Host, corner: &str, pointer: Value, held: bool| {
        h.ok(json!({"op":"hot_corner","output":1,"corner":corner,"pointer":pointer,"held":held}))
    };

    // focus-center reads the pointer the corner fired under, exactly as the
    // action does; a corner sent without one finds nothing.
    assert_eq!(
        h.ok(json!({"op":"hot_corner","output":1,"corner":"top_left"})),
        nothing()
    );
    let over = pointer(&mut h, 950.0, 200.0);
    let data = corner(&mut h, "top_left", over.clone(), false);
    let wanted = effect(&mut h, &data, 2);
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    assert_eq!(data["navigation"]["target_camera"], centered(B, 1.0));
    h.confirm(&wanted);
    assert_eq!(h.history(), json!([2, 4, 1]));
    assert_eq!(
        h.error(
            json!({"op":"hot_corner","output":1,"corner":"top_left","pointer":point(1e13, 0.0)})
        ),
        "invalid pointer"
    );

    // cycle-windows from a corner: with no modifier down it is one committed
    // step, and with one down the session stays open, as a key binding's does.
    let data = h.ok(json!({"op":"hot_corner","output":1,"corner":"top_right"}));
    let step = effect(&mut h, &data, 4);
    assert_eq!(h.focus_state()["release_pending"], true);
    h.confirm(&step);
    assert_eq!(h.history(), json!([4, 2, 1]));
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    let data = corner(&mut h, "top_right", Value::Null, true);
    let step = effect(&mut h, &data, 2);
    h.confirm(&step);
    assert_eq!(h.focus_state()["cycle"], 1);
    assert_eq!(h.history(), json!([4, 2, 1]));
    // A corner bound to any other action ends that cycle before it runs, as
    // upstream's execute_action does for every input source. With one output
    // send-to-output then has nowhere to send the window.
    assert_eq!(corner(&mut h, "bottom_left", over, true), nothing());
    assert_eq!(h.focus_state()["cycle"], Value::Null);
    assert_eq!(h.history(), json!([2, 4, 1]));

    // The output and layout actions end a held cycle first like any other.
    for other in [
        "send-to-output right",
        "send-cursor-to-output left",
        "switch-layout next",
    ] {
        let head = h.history()[0].clone();
        let data = h.held("cycle-windows forward");
        let step = data["effects"][0].clone();
        assert_ne!(step["window"], head);
        h.confirm(&step);
        assert_eq!(h.history()[0], head, "{other}");
        h.action(other);
        assert_eq!(h.focus_state()["cycle"], Value::Null, "{other}");
        assert_eq!(h.history()[0], step["window"], "{other}");
    }
}
