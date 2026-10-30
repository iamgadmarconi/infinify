// SPDX-License-Identifier: GPL-3.0-or-later
//! DriftWM v0.20.0 / v0.21.0 keyboard snapping across the exported C ABI and
//! JSON decoder: `move-to-snap` and `resize-to-snap` (upstream src/tests/
//! snap_actions.rs, step_units.rs), and `nudge_step` / `resize_step` as screen
//! pixels. Expected frames are derived by hand from upstream's stops
//! (`layout::snap::next_origin`, `next_grow_line`, `next_shrink_line`), not read
//! back from the controller. The test plays the shell's part for a resize: it
//! answers every resize effect with a synthetic `native_resize_result`, so
//! nothing here is evidence that a size reaches a real Mac window. Config files
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
    fn action(&mut self, action: &str) -> Value {
        self.ok(json!({"op":"action","output":1,"action":action}))
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
            "infinify-snap-actions-flow-{}-{}",
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
/// y 40..780. `snap.gap` is 12, `snap.outer_gap` 12, `snap.distance` 24.
const ORIGIN: (f64, f64) = (300.0, 200.0);
const USABLE: (f64, f64, f64, f64) = (20.0, 40.0, 960.0, 740.0);
type Frame = (f64, f64, f64, f64);
/// P is the window under test and Q its neighbour to the right.
const P: Frame = (100.0, 100.0, 300.0, 200.0);
const Q: Frame = (600.0, 100.0, 300.0, 200.0);

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
fn world(h: &mut Host, id: u64) -> Value {
    let windows = h.snapshot()["windows"].clone();
    windows
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["window"] == id)
        .unwrap()["world_rect"]
        .clone()
}
/// One 1000 x 800 output with `toml` in force and the given windows, the first
/// of which holds the focus, and the shell able to resize.
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
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    for (index, frame) in windows.iter().enumerate() {
        attach(&mut h, index as u64 + 1, *frame);
    }
    if !windows.is_empty() {
        h.focus(1);
    }
    h
}
/// The effect a reply began: the baseline read of a size transaction.
fn began(h: &mut Host, reply: &Value) -> Value {
    let effect = reply["effect"].clone();
    assert!(effect.is_object(), "{reply}");
    assert_eq!(reply["transaction"], effect["transaction"], "{reply}");
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], effect);
    effect
}
/// Answer one resize effect as the adapter would, with the native frame the
/// window then has.
fn answer(h: &mut Host, effect: &Value, outcome: &str, attempted: bool, size: (f64, f64)) -> Value {
    let observed = !matches!(outcome, "missing_window" | "unavailable");
    let frame = rect(4000.0, 3000.0, size.0, size.1);
    let requested = if effect["requested"].is_null() {
        json!({"width":0.0,"height":0.0})
    } else {
        effect["requested"].clone()
    };
    h.ok(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":outcome,"ax_error":0,"mutation_attempted":attempted,"observed":observed,"requested":requested,"actual_ax":frame,"actual_cg":frame}}))
}
/// Play the shell's whole part for one sized transaction: the baseline read
/// finds `from`, the setter is asked for `asks` and the window takes it, and
/// the final read finds the same.
fn deliver(h: &mut Host, reply: &Value, from: (f64, f64), asks: (f64, f64)) {
    let read = began(h, reply);
    assert_eq!(read["op"], "observe_resize_source", "{read}");
    let setter = answer(h, &read, "observed", false, from)["effect"].clone();
    assert_eq!(setter["op"], "resize_native_window", "{setter}");
    assert_eq!(setter["requested"], json!({"width":asks.0,"height":asks.1}));
    let last = answer(h, &setter, "applied", true, asks)["effect"].clone();
    assert_eq!(last["op"], "observe_resize_source", "{last}");
    assert_eq!(
        answer(h, &last, "observed", false, asks)["effect"],
        Value::Null
    );
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
}

// Upstream snap_actions.rs: `move-to-snap` walks the stops a drag would snap
// to, and docks a snap gap off a neighbour's side. P (x 100..400) to Q
// (x 600..900), 12 points apart in y overlap: P's high edge docks at
// Q.x - 12 = 588, so its origin is 288; the next stop is past Q's far side,
// 900 + 12 = 912.
#[test]
fn move_to_snap_walks_to_the_next_stop_and_the_camera_follows_a_clipped_one() {
    let mut h = host("", &[P, Q]);
    h.action("move-to-snap right");
    assert_eq!(world(&mut h, 1), rect(288.0, 100.0, 300.0, 200.0));
    // Whole on screen: the view stays.
    assert_eq!(h.pose()["camera"], point(0.0, 0.0));
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    let data = h.action("move-to-snap right");
    assert_eq!(world(&mut h, 1), rect(912.0, 100.0, 300.0, 200.0));
    assert_eq!(data["dirty"], true);
    // It is not wholly in the view (x 912..1212 against the usable 20..980):
    // the camera parks it like a navigation does, at the usable center.
    assert_eq!(data["navigation"]["target_camera"], point(562.0, -210.0));
    h.lands(&data["navigation"]);
    // Back left: the stop before 912 is the dock at 288 again (past Q, which
    // is passed over, not landed on).
    h.action("move-to-snap left");
    assert_eq!(world(&mut h, 1), rect(288.0, 100.0, 300.0, 200.0));
    // P now sits a gap off Q's left side, so downward it steps out beside Q:
    // Q's bottom (300) plus the gap is the stop, origin y 312.
    let data = h.action("move-to-snap down");
    assert_eq!(world(&mut h, 1), rect(288.0, 312.0, 300.0, 200.0));
    assert_eq!(data["dirty"], true);
    // Nothing is left below it: a nudge by nudge_step (20 screen px, zoom 1),
    // so that holding the key keeps it moving.
    h.action("move-to-snap down");
    assert_eq!(world(&mut h, 1), rect(288.0, 332.0, 300.0, 200.0));
}

// Upstream v0.21: with no stop that way the move nudges by `nudge_step`, so
// holding the key keeps moving, and at the usable edge the window stays
// `outer_gap` in while the canvas scrolls under it.
#[test]
fn move_to_snap_nudges_when_no_stop_is_left_and_scrolls_at_the_edge() {
    let mut h = host("", &[P]);
    h.action("move-to-snap right");
    assert_eq!(world(&mut h, 1), rect(120.0, 100.0, 300.0, 200.0));
    h.action("move-to-snap up");
    assert_eq!(world(&mut h, 1), rect(120.0, 80.0, 300.0, 200.0));
    // Put the right edge 5 points short of the usable edge (980): the next
    // nudge carries it past the line 12 points in (968), so the camera scrolls
    // along until that edge sits on the line: camera x = 1010 - 968... the
    // edge is at 975 + 20 = 995; x_high - (20 + 960 - 12) = 27.
    let mut h = host("", &[(675.0, 100.0, 300.0, 200.0)]);
    let data = h.action("move-to-snap right");
    assert_eq!(world(&mut h, 1), rect(695.0, 100.0, 300.0, 200.0));
    assert_eq!(data["navigation"]["target_camera"], point(27.0, 0.0));
    assert_eq!(data["navigation"]["target_zoom"], 1.0);
    h.lands(&data["navigation"]);
    // The same key again: the window stays 12 points in while the canvas moves.
    let data = h.action("move-to-snap right");
    assert_eq!(world(&mut h, 1), rect(715.0, 100.0, 300.0, 200.0));
    assert_eq!(data["navigation"]["target_camera"], point(47.0, 0.0));
}

// v0.21: `nudge_step` and `resize_step` are screen pixels, like `pan_step`.
#[test]
fn nudge_and_resize_steps_are_screen_pixels() {
    // At zoom 0.5 a 20 px step covers 40 canvas px.
    let mut h = host("", &[P]);
    h.look(0.0, 0.0, 0.5);
    h.action("nudge-window right");
    assert_eq!(world(&mut h, 1), rect(140.0, 100.0, 300.0, 200.0));
    h.action("nudge-window down");
    assert_eq!(world(&mut h, 1), rect(140.0, 140.0, 300.0, 200.0));
    // `msg move` stays in canvas px.
    let moved =
        h.ok(json!({"op":"ipc","output":1,"request":{"Move":{"window":null,"to":[200,300]}}}));
    assert_eq!(moved["reply"]["Ok"], json!({"Position":{"x":200,"y":300}}));
    // grow-window at zoom 0.5: 20 screen px are 40 canvas px of width.
    let mut h = host("", &[P]);
    h.look(0.0, 0.0, 0.5);
    let reply = h.action("grow-window right");
    deliver(&mut h, &reply, (300.0, 200.0), (340.0, 200.0));
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 340.0, 200.0));
}

// Upstream snap_actions.rs: `resize-to-snap` grows the right or bottom edge to
// the next stop and stops docked against the next window; left and up pull it
// back to the previous stop, or by `resize_step` with none inside the window.
#[test]
fn resize_to_snap_grows_to_the_dock_and_shrinks_by_the_step() {
    let mut h = host("", &[P, Q]);
    // Q's high dock is 600 - 12 = 588: 188 more width.
    let reply = h.action("resize-to-snap right");
    deliver(&mut h, &reply, (300.0, 200.0), (488.0, 200.0));
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 488.0, 200.0));
    // Docked: another press has nowhere to go and asks nothing.
    let reply = h.action("resize-to-snap right");
    assert_eq!(reply["effect"], Value::Null);
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 488.0, 200.0));
    // No stop inside the window to the left: pulled back by resize_step.
    let reply = h.action("resize-to-snap left");
    deliver(&mut h, &reply, (488.0, 200.0), (468.0, 200.0));
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 468.0, 200.0));
    // The bottom edge: nothing below, so the usable edge 12 points in is the
    // stop. The fence's far edge is y = 780 - 12 = 768: 768 - 300 = 468 more.
    let reply = h.action("resize-to-snap down");
    deliver(&mut h, &reply, (468.0, 200.0), (468.0, 668.0));
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 468.0, 668.0));
}

// The diagonals never parse for these actions; the names do.
#[test]
fn the_snap_actions_take_four_directions() {
    let mut h = host("", &[P]);
    for action in [
        "move-to-snap up-left",
        "resize-to-snap down-right",
        "move-to-snap",
    ] {
        let response = h.call(json!({"op":"action","output":1,"action":action}));
        assert_eq!(response["ok"], false, "{action}");
    }
    let keys = h.ok(json!({"op":"bindings"}));
    let bound: Vec<_> = keys["keys"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|key| key["combo"] == "mod+shift+Right" || key["combo"] == "mod+shift+q")
        .map(|key| key["action"].clone())
        .collect();
    assert!(bound.contains(&json!("move-to-snap right")), "{bound:?}");
    assert!(bound.contains(&json!("suspend-window")), "{bound:?}");
}
