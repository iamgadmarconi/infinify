// SPDX-License-Identifier: GPL-3.0-or-later
//! DriftWM v0.20.0 / v0.21.0 navigation scenarios across the exported C ABI
//! and JSON decoder: the `focus-nearest` action (upstream src/tests/
//! focus_nearest.rs), Alt-Tab that no longer pans to a window already whole on
//! screen (cycle_windows.rs), `auto_navigate_on_click` scrolling minimally
//! (auto_navigate_click.rs), `focus-center`'s fallback (focus_center.rs) and
//! sloppy focus following a pan (hover_focus.rs). Expected cameras are derived
//! by hand from upstream's rules (`minimal_reveal_camera`, `landing_view`), not
//! read back from the controller. Config files are written to a throwaway
//! directory; the default config path is never read. They provide no evidence
//! that a key or a click reaches the shell, that a focus effect focuses a
//! native window, or that a native focus change is observed.
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
        let response = self.call(command.clone());
        assert_eq!(response["ok"], true, "{command}: {response}");
        response["data"].clone()
    }
    fn snapshot(&mut self) -> Value {
        self.ok(json!({"op":"snapshot"}))
    }
    fn action(&mut self, action: &str) -> Value {
        self.ok(json!({"op":"action","output":1,"action":action}))
    }
    fn focused(&mut self) -> Value {
        self.snapshot()["focus"]["intent"].clone()
    }
    fn pose(&mut self) -> Value {
        self.snapshot()["outputs"][0].clone()
    }
    /// Report that the adapter did what `effect` asked and read it back.
    fn confirm(&mut self, effect: &Value) {
        self.ok(json!({"op":"focus_result","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"],"success":true}));
    }
    /// Logical focus that the adapter confirms: raised, and in the history.
    fn focus(&mut self, window: u64) {
        let effect = self.ok(json!({"op":"focus","window":window}))["effect"].clone();
        self.confirm(&effect);
        self.ok(json!({"op":"cancel_navigation","output":1}));
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
        let pose = self.pose();
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
            "infinify-focus-nearest-flow-{}-{}",
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

/// Output 1's global top-left corner, and its asymmetric usable rectangle in
/// output-local points: at zoom 1 and camera (0, 0) it shows world x 20..980,
/// y 40..780. The v0.20 `snap.outer_gap` of 12 insets a minimal reveal.
const ORIGIN: (f64, f64) = (300.0, 200.0);
const USABLE: (f64, f64, f64, f64) = (20.0, 40.0, 960.0, 740.0);
const CENTER: (f64, f64) = (500.0, 410.0);
type Frame = (f64, f64, f64, f64);
/// A is wholly on screen, B is to its right, also wholly, and O overlaps A.
const A: Frame = (100.0, 100.0, 300.0, 200.0);
const B: Frame = (600.0, 100.0, 300.0, 200.0);
const O: Frame = (300.0, 200.0, 200.0, 200.0);
/// Q is snapped to B's right (a 12 point gap) and hangs off the usable area.
const Q: Frame = (912.0, 100.0, 300.0, 200.0);
/// R overlaps B and hangs off the usable area; Z is related to nothing and is
/// below the view.
const R: Frame = (850.0, 150.0, 300.0, 200.0);
const Z: Frame = (400.0, 1200.0, 300.0, 200.0);

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn point(x: f64, y: f64) -> Value {
    json!({"x":x,"y":y})
}
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid,"owner":null})
}
fn attach(h: &mut Host, wid: u64, frame: Frame) {
    let window = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":format!("app.{wid}"),"title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,frame.2,frame.3),"world_rect":rect(frame.0,frame.1,frame.2,frame.3)}))["window"].clone();
    assert_eq!(window, wid);
}
/// The global screen point that shows a world point on output 1.
fn pointer(h: &mut Host, x: f64, y: f64) -> Value {
    let pose = h.pose();
    let zoom = pose["zoom"].as_f64().unwrap();
    point(
        ORIGIN.0 + (x - pose["camera"]["x"].as_f64().unwrap()) * zoom,
        ORIGIN.1 + (y - pose["camera"]["y"].as_f64().unwrap()) * zoom,
    )
}
/// One 1000 x 800 output with `toml` in force and the given windows, the first
/// of which holds the focus.
fn host(toml: &str, windows: &[Frame]) -> Host {
    let handle = driftwm_desktop_create();
    assert!(!handle.is_null());
    let mut h = Host {
        handle,
        clock: 1_000_000_000,
        scratch: Scratch::new(),
    };
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":rect(ORIGIN.0,ORIGIN.1,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(USABLE.0,USABLE.1,USABLE.2,USABLE.3),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
    let path = h.scratch.0.join("config.toml");
    std::fs::write(&path, toml).unwrap();
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(reply["warnings"], json!([]), "{reply}");
    h.ok(json!({"op":"tick_navigation","timestamp_ns":1_000_000_000u64}));
    for (index, frame) in windows.iter().enumerate() {
        attach(&mut h, index as u64 + 1, *frame);
    }
    if !windows.is_empty() {
        h.focus(1);
    }
    h
}
/// The focus request an action made, for the window it names.
fn asked(data: &Value, window: u64) {
    assert_eq!(data["effects"].as_array().unwrap().len(), 1, "{data}");
    assert_eq!(data["effects"][0]["op"], "focus_native_window");
    assert_eq!(data["effects"][0]["window"], window, "{data}");
}

// Upstream focus_nearest.rs: a target fully on screen is only focused, and the
// view stays where it is (center-nearest would have centred it).
#[test]
fn focus_nearest_focuses_a_window_that_is_whole_on_screen_and_leaves_the_view() {
    let mut h = host("", &[A, B, O]);
    let before = h.pose();
    // From A, O (it overlaps A's corner) is the nearest to the right.
    let data = h.action("focus-nearest right");
    asked(&data, 3);
    assert_eq!(data["navigation"], Value::Null);
    assert_eq!(h.focused(), 3);
    assert_eq!(h.pose(), before);
    // From O, B is the nearest to the right, whole on screen as well.
    h.focus(3);
    let data = h.action("focus-nearest right");
    asked(&data, 2);
    assert_eq!(data["navigation"], Value::Null);
    assert_eq!(h.pose(), before);
    // center-nearest still always centres its target: B's center (750, 200)
    // goes to the usable center (500, 410).
    h.focus(3);
    let data = h.action("center-nearest right");
    asked(&data, 2);
    assert_eq!(data["navigation"]["target_camera"], point(250.0, -210.0));
}

// A clipped target in the focused window's snap cluster scrolls just far
// enough to show it, `outer_gap` in from the usable edge.
#[test]
fn focus_nearest_scrolls_a_clipped_cluster_member_just_into_view() {
    // Q sits a snap gap off B's right edge, so B and Q are one cluster. Its
    // right edge (1212) must end 12 inside the usable area's (980): camera
    // x = 1212 - (20 + 960 - 12) = 244. The y axis already fits.
    let mut h = host("", &[B, Q]);
    let data = h.action("focus-nearest right");
    asked(&data, 2);
    assert_eq!(data["navigation"]["target_camera"], point(244.0, 0.0));
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    h.lands(&data["navigation"]);
    assert_eq!(h.focused(), 2);
    // The same step with `center-nearest` parks Q's center on the usable
    // center instead: (1062, 200) - (500, 410).
    let mut h = host("", &[B, Q]);
    let data = h.action("center-nearest right");
    assert_eq!(data["navigation"]["target_camera"], point(562.0, -210.0));
}

// A clipped target that overlaps the focused window is related too.
#[test]
fn focus_nearest_scrolls_a_clipped_overlapping_window_into_view() {
    // R (x 850..1150, y 150..350) overlaps B and is cut off on the right:
    // camera x = 1150 - 968 = 182.
    let mut h = host("", &[B, R]);
    let data = h.action("focus-nearest right");
    asked(&data, 2);
    assert_eq!(data["navigation"]["target_camera"], point(182.0, 0.0));
    h.lands(&data["navigation"]);
}

// A clipped target the focused window is unrelated to is a jump, and jumps
// park at `focus_placement`, as center-nearest and Alt-Tab do.
#[test]
fn focus_nearest_parks_a_clipped_window_it_is_unrelated_to() {
    let mut h = host("", &[A, Z]);
    let data = h.action("focus-nearest down");
    asked(&data, 2);
    // Z's center (550, 1300) on the usable center (500, 410).
    assert_eq!(data["navigation"]["target_camera"], point(50.0, 890.0));
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    h.lands(&data["navigation"]);
}

// With a navigation anchor in the cone and no window, the anchor is landed on
// through the anchor flight, and the focus is cleared.
#[test]
fn focus_nearest_lands_on_a_navigation_anchor_and_unfocuses() {
    // The file writes anchors Y up: (2000, -400) is world (2000, 400).
    let mut h = host("[navigation]\nanchors = [[2000.0, -400.0]]\n", &[A]);
    let data = h.action("focus-nearest right");
    assert_eq!(data["effects"], json!([]));
    assert_eq!(h.focused(), Value::Null);
    assert_eq!(
        data["navigation"]["target_camera"],
        point(2000.0 - CENTER.0, 400.0 - CENTER.1)
    );
    h.lands(&data["navigation"]);
}

// Upstream cycle_windows.rs: Alt-Tab no longer pans to a window already whole
// on screen, judged where the view lands; a clipped one still parks.
#[test]
fn alt_tab_only_focuses_a_window_that_is_whole_on_screen() {
    let mut h = host("", &[A, B, Z]);
    h.focus(2);
    h.focus(3);
    assert_eq!(h.focused(), 3);
    // Z is below the view and parks at the usable center...
    let data = h.action("cycle-windows forward");
    asked(&data, 2);
    // ...but the previous window (B) is whole on screen: focus only. The view
    // has not moved because Z (the current focus) never became the target.
    assert_eq!(data["navigation"], Value::Null);
    let mut h = host("", &[A, B, Z]);
    h.focus(3);
    let data = h.action("cycle-windows forward");
    asked(&data, 1);
    assert_eq!(data["navigation"], Value::Null);
    // From A, back to Z (clipped): parked at the usable center.
    h.focus(1);
    let data = h.action("cycle-windows forward");
    asked(&data, 3);
    assert_eq!(data["navigation"]["target_camera"], point(50.0, 890.0));
}

// Upstream auto_navigate_click.rs: the click scrolls the window just far
// enough to show it whole, keeping the zoom, instead of centring it.
#[test]
fn auto_navigate_on_click_scrolls_a_clipped_window_minimally() {
    let mut h = host("[navigation]\nauto_navigate_on_click = true\n", &[B, Q]);
    let press = h.ok(json!({"op":"activate","window":2,"output":1,"cause":"click"}));
    assert_eq!(press["navigation"], Value::Null);
    h.confirm(&press["effect"]);
    let released = h.ok(json!({"op":"activate","window":2,"output":1,"cause":"click_release"}));
    assert_eq!(released["navigation"]["target_camera"], point(244.0, 0.0));
    assert_eq!(released["navigation"]["target_zoom"], 1.0);
    assert_eq!(released.get("effect"), None);
    h.lands(&released["navigation"]);
    // Whole on screen now: a second click moves nothing.
    h.ok(json!({"op":"activate","window":2,"output":1,"cause":"click"}));
    let released = h.ok(json!({"op":"activate","window":2,"output":1,"cause":"click_release"}));
    assert_eq!(released["navigation"], Value::Null);
}

// Upstream focus_center.rs: with nothing under the pointer the action is
// center-window; over a pin it focuses the pin and leaves the view.
#[test]
fn focus_center_falls_back_to_center_window() {
    let mut h = host("", &[A, B]);
    h.focus(2);
    let over_nothing = pointer(&mut h, 700.0, 700.0);
    let data =
        h.ok(json!({"op":"action","output":1,"action":"focus-center","pointer":over_nothing}));
    asked(&data, 2);
    // B's center (750, 200) on the usable center, at zoom 1.
    assert_eq!(data["navigation"]["target_camera"], point(250.0, -210.0));
    h.ok(json!({"op":"cancel_navigation","output":1}));
    // No pointer at all is the same fallback.
    let data = h.action("focus-center");
    assert_eq!(data["navigation"]["target_camera"], point(250.0, -210.0));
}

// Upstream hover_focus.rs: a pan under a still pointer moves sloppy focus to
// the window that lands under it; a navigation parks the pull.
#[test]
fn a_pan_under_a_resting_pointer_moves_sloppy_focus_and_a_navigation_parks_it() {
    let mut h = host("focus_follows_mouse = true\n", &[A, B]);
    // The pointer rests over A.
    let over_a = pointer(&mut h, 250.0, 200.0);
    let hover = h.ok(json!({"op":"hover","output":1,"screen":over_a}));
    assert_eq!(hover["forward"], true);
    assert_eq!(h.focused(), 1);
    // Nothing owes the pointer a look until the view moves.
    assert_eq!(
        h.snapshot()["navigation"]["hover_pull"]["needs_pointer"],
        false
    );
    let reported = h.ok(json!({"op":"pointer","output":1,"screen":over_a}));
    assert_eq!(reported.get("dirty"), None);
    // A pan (the user's) slides B under the pointer: the view differs from the
    // one hover answered for, and the shell is asked to report the pointer.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(500.0, 0.0)}));
    assert_eq!(
        h.snapshot()["navigation"]["hover_pull"]["needs_pointer"],
        true
    );
    let reported = h.ok(json!({"op":"pointer","output":1,"screen":over_a}));
    assert_eq!(reported["dirty"], true);
    assert_eq!(reported["effect"]["window"], 2);
    assert_eq!(h.focused(), 2);
    assert_eq!(
        h.snapshot()["navigation"]["hover_pull"]["needs_pointer"],
        false
    );
    h.confirm(&reported["effect"]);

    // A navigation sets focus and parks the pull: its own flight slides other
    // windows under the resting pointer and takes nothing from the focus.
    let data = h.action("center-nearest left");
    asked(&data, 1);
    assert_eq!(h.focused(), 1);
    for _ in 0..10 {
        h.clock += 16_666_667;
        h.ok(json!({"op":"tick_navigation","timestamp_ns":h.clock}));
        let reported = h.ok(json!({"op":"pointer","output":1,"screen":over_a}));
        assert_eq!(reported.get("dirty"), None, "{reported}");
        assert_eq!(h.focused(), 1);
    }
    h.settle();
    // The view moved while parked, and the pull stamped it without acting.
    let reported = h.ok(json!({"op":"pointer","output":1,"screen":over_a}));
    assert_eq!(reported.get("dirty"), None);
    assert_eq!(
        h.snapshot()["navigation"]["hover_pull"]["needs_pointer"],
        false
    );
    // A pan of the user's brings it back: the pointer is over A or B again and
    // the focus follows whichever lands under it.
    let rest = pointer(&mut h, 250.0, 200.0);
    h.ok(json!({"op":"hover","output":1,"screen":rest}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(500.0, 0.0)}));
    let reported = h.ok(json!({"op":"pointer","output":1,"screen":rest}));
    assert_eq!(reported["dirty"], true);
    assert_eq!(reported["effect"]["window"], 2);

    // Without focus_follows_mouse nothing is owed.
    let mut h = host("", &[A, B]);
    let over_a = pointer(&mut h, 250.0, 200.0);
    h.ok(json!({"op":"hover","output":1,"screen":over_a}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(500.0, 0.0)}));
    assert_eq!(
        h.snapshot()["navigation"]["hover_pull"]["needs_pointer"],
        false
    );
    let reported = h.ok(json!({"op":"pointer","output":1,"screen":over_a}));
    assert_eq!(reported.get("dirty"), None);
    assert_eq!(h.focused(), 1);
}
