// SPDX-License-Identifier: GPL-3.0-or-later
//! `[zoom] interact_min` as DriftWM v0.20.0 ships it (default 0.5; upstream
//! src/tests/interact_min.rs): below it a window receives no pointer input, a
//! left click brings you to it and a drag moves it on the canvas. The
//! controller decides per pointer event whether the shell may forward it
//! (`hit`/`input`/`hover` `pick`, `mouse_binding`); these scenarios run the
//! default configuration and the three event classes, press, drag and scroll,
//! below and at or above the threshold. They are no evidence about what the
//! Objective-C shell then does with a decision: see POINTER.md. Config files
//! are written to a throwaway directory; the default config path is never read.
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
    fn focused(&mut self) -> Value {
        self.snapshot()["focus"]["intent"].clone()
    }
    fn pose(&mut self) -> Value {
        self.snapshot()["outputs"][0].clone()
    }
    /// Put output 1's camera at a world point and its zoom at `zoom`.
    fn look(&mut self, x: f64, y: f64, zoom: f64) {
        let corner = point(ORIGIN.0, ORIGIN.1);
        self.ok(json!({"op":"cancel_navigation","output":1}));
        self.ok(json!({"op":"zoom","output":1,"zoom":1.0,"anchor":corner}));
        let camera = self.pose()["camera"].clone();
        let delta = point(
            x - camera["x"].as_f64().unwrap(),
            y - camera["y"].as_f64().unwrap(),
        );
        self.ok(json!({"op":"pan","output":1,"screen_delta":delta}));
        self.ok(json!({"op":"zoom","output":1,"zoom":zoom,"anchor":corner}));
        assert_eq!(self.pose()["camera"], point(x, y));
        assert_eq!(self.pose()["zoom"], zoom);
    }
    fn hit(&mut self, x: f64, y: f64) -> Value {
        let screen = pointer(self, x, y);
        self.ok(json!({"op":"hit","output":1,"screen":screen}))
    }
    /// The press-forwarding validation of `window`'s source at a world point.
    fn input(&mut self, window: u64, x: f64, y: f64) -> Value {
        let screen = pointer(self, x, y);
        json!({"op":"input","output":1,"screen":screen,"identity":identity(window)})
    }
    fn hover(&mut self, x: f64, y: f64) -> Value {
        let screen = pointer(self, x, y);
        self.ok(json!({"op":"hover","output":1,"screen":screen}))
    }
    /// A pointer binding lookup over a window with no modifier held.
    fn binding(&mut self, trigger: &str, source: Value, pick: bool) -> Value {
        self.ok(json!({"op":"mouse_binding","trigger":trigger,"source":source,"modifiers":{"command":false,"control":false,"option":false,"shift":false},"context":"window","pick":pick}))["binding"].clone()
    }
    fn error(&mut self, command: Value) -> String {
        let response = self.call(command.clone());
        assert_eq!(response["ok"], false, "{command}: {response}");
        response["error"].as_str().unwrap().to_owned()
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
            "infinify-interact-min-flow-{}-{}",
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

/// Output 1's global top-left corner and usable rectangle.
const ORIGIN: (f64, f64) = (300.0, 200.0);
const USABLE: (f64, f64, f64, f64) = (20.0, 40.0, 960.0, 740.0);
type Frame = (f64, f64, f64, f64);
/// The window, 400 x 300 far out on the canvas.
const W: Frame = (2000.0, 1500.0, 400.0, 300.0);

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn point(x: f64, y: f64) -> Value {
    json!({"x":x,"y":y})
}
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid,"owner":null})
}
fn center(frame: Frame) -> (f64, f64) {
    (frame.0 + frame.2 / 2.0, frame.1 + frame.3 / 2.0)
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
fn frame(h: &mut Host, id: u64) -> Value {
    let windows = h.snapshot()["windows"].clone();
    windows
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["window"] == id)
        .unwrap()["world_rect"]
        .clone()
}
/// One 1000 x 800 output with `toml` in force (the empty string is upstream's
/// defaults, `interact_min = 0.5` among them) and window 1, with the view at
/// `zoom` showing it whole.
fn host(toml: &str, zoom: f64) -> Host {
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
    let window = h.ok(json!({"op":"attach","identity":identity(1),"bundle_id":"app.1","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,W.2*2.0,W.3*2.0),"world_rect":rect(W.0,W.1,W.2,W.3)}))["window"].clone();
    assert_eq!(window, 1);
    h.look(1500.0, 1000.0, zoom);
    h
}

// The default is on. Below 0.5 the window is one pick target: a press is
// refused for forwarding, motion is not delivered, and the press is the pick's.
#[test]
fn interact_min_defaults_to_one_half_and_a_press_below_it_reaches_no_application() {
    let mut h = host("", 0.4);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    let (x, y) = center(W);
    // Press: the controller says the window is a pick target, and refuses the
    // validation a forwarded press needs.
    let hit = h.hit(x, y);
    assert_eq!(hit["pick"], true);
    assert_eq!(hit["hit"]["pick"], true);
    assert_eq!(hit["hit"]["window"], 1);
    let press = h.input(1, x, y);
    assert_eq!(
        h.error(press),
        "pick mode: below zoom.interact_min a window takes no pointer input"
    );
    // A bare left button is not a binding over a pick target: the press is
    // the pick's. Above the threshold it is not a binding either, but then
    // nothing claims it and the press is the window's.
    assert_eq!(h.binding("left", Value::Null, true), Value::Null);
    // Motion is not the window's.
    let over = h.hover(x, y);
    assert_eq!(over["pick"], true);
    assert_eq!(over["forward"], false);
    // The press raises and focuses the target.
    let pressed = h.ok(json!({"op":"activate","window":1,"output":1,"cause":"click"}));
    assert_eq!(pressed["effect"]["window"], 1);
    assert_eq!(h.focused(), 1);
}

// A drag moves the window on the canvas, without any binding: 40 x 20 screen
// points are 100 x 50 canvas points at zoom 0.4.
#[test]
fn a_drag_below_interact_min_moves_the_window_on_the_canvas() {
    let mut h = host("", 0.4);
    let before_camera = h.pose()["camera"].clone();
    h.ok(json!({"op":"activate","window":1,"output":1,"cause":"click"}));
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    h.ok(json!({"op":"gesture_to","screen_delta":point(40.0, 20.0)}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(frame(&mut h, 1), rect(2100.0, 1550.0, 400.0, 300.0));
    assert_eq!(h.pose()["camera"], before_camera);
    // A click without a drag brings you to the window: one navigation to its
    // center at zoom 1 (focus_placement center: the usable center (500, 410)).
    let reply = h.ok(json!({"op":"pick","window":1,"output":1}));
    assert_eq!(reply["navigation"]["target_zoom"], 1.0);
    assert_eq!(
        reply["navigation"]["target_camera"],
        point(2300.0 - 500.0 + 0.0, 1700.0 - 410.0)
    );
    h.lands(&reply["navigation"]);
    // The pick is one navigation, not a mode: above the threshold again, the
    // window takes input.
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
    let (x, y) = center((2100.0, 1550.0, 400.0, 300.0));
    let press = h.input(1, x, y);
    assert_eq!(h.ok(press)["pick"], false);
}

// A scroll over a pick target is the canvas's: it pans or zooms instead of
// dying on a window that cannot receive it.
#[test]
fn a_scroll_below_interact_min_is_the_canvas_s_and_above_it_the_window_s() {
    let mut h = host("", 0.4);
    // Two-finger scroll over the pick target is looked up again on empty
    // canvas, where it pans.
    let scroll = h.binding("scroll", json!("finger"), true);
    assert_eq!(scroll["kind"], "pan_viewport");
    // Not a pick target (pick false): the window context has no bare scroll
    // binding, so the scroll is the window's.
    assert_eq!(h.binding("scroll", json!("finger"), false), Value::Null);
    // A wheel notch is neither: it has no retry.
    assert_eq!(h.binding("wheel_up", Value::Null, true), Value::Null);
}

// At the threshold, above it and with the feature off nothing is a pick.
#[test]
fn at_or_above_interact_min_and_with_it_set_to_zero_the_window_takes_input() {
    for (toml, zoom) in [
        ("", 0.5),
        ("", 0.6),
        ("[zoom]\ninteract_min = 0.0\n", 0.1),
        ("[zoom]\ninteract_min = 0.2\n", 0.3),
    ] {
        let mut h = host(toml, zoom);
        assert_eq!(h.snapshot()["outputs"][0]["pick"], false, "{toml} {zoom}");
        let (x, y) = center(W);
        let hit = h.hit(x, y);
        assert_eq!(hit["pick"], false, "{toml} {zoom}");
        let press = h.input(1, x, y);
        assert_eq!(h.ok(press)["pick"], false, "{toml} {zoom}");
        assert_eq!(h.hover(x, y)["forward"], true, "{toml} {zoom}");
    }
    // A raised threshold picks where the default would not.
    let mut h = host("[zoom]\ninteract_min = 0.8\n", 0.7);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    // And a config reload switches it live.
    let path = h.scratch.0.join("config.toml");
    std::fs::write(&path, "[zoom]\ninteract_min = 0.0\n").unwrap();
    h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
}
