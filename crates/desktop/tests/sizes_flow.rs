// SPDX-License-Identifier: GPL-3.0-or-later
//! Window sizing scenarios cross the exported C ABI and JSON decoder. The test
//! plays the shell's part: it answers every resize effect with a synthetic
//! `native_resize_result`. No native window is resized, so nothing here is
//! evidence that a size reaches a real Mac window. Config files are written to
//! a throwaway directory; the default config path is never read.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

struct Host {
    handle: *mut Controller,
    clock: u64,
    _scratch: Scratch,
}
impl Host {
    /// The response exactly as the C ABI returned it.
    fn raw(&mut self, command: Value) -> String {
        let bytes = serde_json::to_vec(&json!({"version":1,"command":command})).unwrap();
        // SAFETY: live exclusive handle, valid bytes, response freed exactly once.
        unsafe {
            let response = driftwm_desktop_request(self.handle, bytes.as_ptr(), bytes.len());
            assert!(!response.is_null());
            let text = CStr::from_ptr(response).to_str().unwrap().to_owned();
            driftwm_desktop_response_free(response);
            text
        }
    }
    fn call(&mut self, command: Value) -> Value {
        serde_json::from_str(&self.raw(command)).unwrap()
    }
    fn ok(&mut self, command: Value) -> Value {
        let response = self.call(command.clone());
        assert_eq!(response["ok"], true, "{command}: {response}");
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
            "infinify-sizes-flow-{}-{}",
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
/// or a native frame taken for a world one misses.
const ORIGIN: (f64, f64) = (300.0, 200.0);
/// Output 1's usable rectangle in output-local points: asymmetric on purpose.
const USABLE: (f64, f64, f64, f64) = (20.0, 40.0, 960.0, 740.0);
const CONFIG: &str = "focus_placement = \"left\"\n[navigation]\nresize_step = 30\n[snap]\nouter_gap = 8.0\n[[outputs]]\nname = \"*\"\n[outputs.hot_corners]\ntop_left = \"fit-window\"\n[keybindings]\n\"mod+g\" = \"fill-window\"\n\"mod+ctrl+shift+right\" = \"grow-window right\"\n\"mod+ctrl+shift+left\" = \"shrink-window right\"\n";

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid,"owner":null})
}
/// A new window with a bound source. Its native frame has the world frame's
/// size, as a size transaction's baseline requires, and sits somewhere else.
fn attach(h: &mut Host, wid: u64, frame: (f64, f64, f64, f64)) {
    let window = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":format!("app.{wid}"),"title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,frame.2,frame.3),"world_rect":rect(frame.0,frame.1,frame.2,frame.3)}))["window"].clone();
    assert_eq!(window, wid);
}
/// One 1000 x 800 output at `ORIGIN` with `toml` in force and no window.
fn empty(toml: &str) -> Host {
    let handle = driftwm_desktop_create();
    assert!(!handle.is_null());
    let mut h = Host {
        handle,
        clock: 1_000_000_000,
        _scratch: Scratch::new(),
    };
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":rect(ORIGIN.0,ORIGIN.1,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(USABLE.0,USABLE.1,USABLE.2,USABLE.3),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
    let path = h._scratch.0.join("config.toml");
    std::fs::write(&path, toml).unwrap();
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(reply["warnings"], json!([]), "{reply}");
    h.ok(json!({"op":"tick_navigation","timestamp_ns":h.clock}));
    h
}
/// Window 1 at world (100, 100) 400 x 300, focused, and nothing else.
fn one(toml: &str) -> Host {
    let mut h = empty(toml);
    attach(&mut h, 1, (100.0, 100.0, 400.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    h
}

/// The effect a reply began, which is also the transaction's pending effect:
/// what `-[DWResizeCoordinator consume:]` requires before it performs one.
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
/// finds `from`, the setter is asked for `asks` and the window takes `took`,
/// and the final read finds the same.
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
    assert_eq!(slot["pending_effect"], Value::Null);
}
fn window(h: &mut Host, id: u64) -> Value {
    let windows = h.snapshot()["windows"].clone();
    let found = windows
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["window"] == id);
    found.unwrap_or_else(|| panic!("no window {id}")).clone()
}
fn world(h: &mut Host, id: u64) -> Value {
    window(h, id)["world_rect"].clone()
}
fn mode(h: &mut Host, id: u64) -> Value {
    window(h, id)["mode"].clone()
}
/// The mode upstream's IPC inventory reports for a window.
fn ipc_mode(h: &mut Host, id: u64) -> Value {
    let state = ipc(h, json!("State"))["reply"]["Ok"]["State"].clone();
    let windows = state["windows"].as_array().unwrap();
    windows.iter().find(|w| w["id"] == id).unwrap()["mode"].clone()
}
fn pose(h: &mut Host) -> Value {
    let output = h.snapshot()["outputs"][0].clone();
    json!({"camera":output["camera"],"zoom":output["zoom"]})
}
fn action(h: &mut Host, action: &str) -> Value {
    h.ok(json!({"op":"action","output":1,"action":action}))
}
fn ipc(h: &mut Host, request: Value) -> Value {
    h.ok(json!({"op":"ipc","output":1,"request":request}))
}
/// Tick until every flight has landed.
fn settle(h: &mut Host) {
    for _ in 0..600 {
        h.clock += 16_666_667;
        let tick = h.ok(json!({"op":"tick_navigation","timestamp_ns":h.clock}));
        if tick["needs_frames"] == false {
            return;
        }
    }
    panic!("flight did not settle");
}
/// The shell started with `--experimental-native-resize` says so once.
fn capable(mut h: Host) -> Host {
    assert_eq!(
        h.ok(json!({"op":"native_resize_capability","enabled":true})),
        json!({})
    );
    h
}
const NOTHING: &str = r#"{"navigation":null,"effects":[],"dirty":false}"#;
fn nothing() -> Value {
    serde_json::from_str(NOTHING).unwrap()
}
/// Window 1's frame in every scenario that starts from `one`.
const START: (f64, f64, f64, f64) = (100.0, 100.0, 400.0, 300.0);
const BUSY: &str = "a native resize of window 1 is still pending";
const GRABBED: &str = "a window is under an interactive move or resize";

// Captured from the tree before this milestone: every line below is the exact
// response the C ABI returned for the same request then.
#[test]
fn without_the_capability_every_sizing_request_answers_as_it_did_before() {
    let mut h = one(CONFIG);
    let refused = |name: &str| {
        format!(
            r#"{{"error":"action not implemented on macOS yet: {name}","ok":false,"version":1}}"#
        )
    };
    let refused_ipc = |text: &str| {
        format!(
            r#"{{"data":{{"dirty":false,"effects":[],"navigation":null,"reply":{{"Err":"{text}"}}}},"ok":true,"version":1}}"#
        )
    };
    // Sent or not, false is the default: a bare shell and one that says so.
    for explicit in [false, true] {
        if explicit {
            assert_eq!(
                h.ok(json!({"op":"native_resize_capability","enabled":false})),
                json!({})
            );
        }
        let before = h.snapshot();
        for (sample, name) in [
            ("grow-window right", "grow-window"),
            ("shrink-window up-left", "shrink-window"),
            ("fit-window", "fit-window"),
            ("fit-window-snapped", "fit-window-snapped"),
            ("fill-window", "fill-window"),
        ] {
            assert_eq!(
                h.raw(json!({"op":"action","output":1,"action":sample})),
                refused(name)
            );
            assert_eq!(
                h.raw(json!({"op":"action","output":null,"action":sample})),
                refused(name)
            );
            assert_eq!(
                h.raw(json!({"op":"ipc","output":1,"request":{"Action":sample}})),
                refused_ipc(&format!("action not implemented on macOS yet: {name}"))
            );
        }
        let unavailable =
            "resize is not implemented on macOS yet: native layout resize is not available";
        for (request, text) in [
            (json!({"Resize":{"window":1,"to":[800,600]}}), unavailable),
            (json!({"Resize":{"to":[800,600]}}), unavailable),
            (json!({"Resize":{"to":[0,600]}}), "size must be positive"),
            (
                json!({"Resize":{"window":9,"to":[800,600]}}),
                "no window with id 9",
            ),
        ] {
            assert_eq!(
                h.raw(json!({"op":"ipc","output":1,"request":request})),
                refused_ipc(text)
            );
        }
        assert_eq!(
            h.raw(json!({"op":"ipc","output":1,"request":{"Resize":{}}})),
            r#"{"data":{"dirty":false,"effects":[],"navigation":null,"reply":{"Ok":{"Size":{"height":300,"width":400}}}},"ok":true,"version":1}"#
        );
        // A hot corner bound to fit-window, a key and a mouse button.
        assert_eq!(
            h.raw(json!({"op":"hot_corner","output":1,"corner":"top_left"})),
            refused("fit-window")
        );
        assert_eq!(
            h.raw(json!({"op":"mouse_binding","trigger":"middle","modifiers":{"control":false,"option":true,"shift":false,"command":false},"context":"window"})),
            r#"{"data":{"binding":{"action":"fit-window","combo":"alt+middle","implemented":false,"kind":"action","mouse_speed":1.0,"trackpad_speed":1.5,"zoom_mouse_speed":1.0,"zoom_step":1.1,"zoom_trackpad_speed":1.0}},"ok":true,"version":1}"#
        );
        let keys = h.ok(json!({"op":"bindings"}))["keys"].clone();
        let key = |action: &str| {
            let found = keys
                .as_array()
                .unwrap()
                .iter()
                .find(|k| k["action"] == action);
            found
                .unwrap_or_else(|| panic!("{action} is not bound"))
                .to_string()
        };
        assert_eq!(
            key("fill-window"),
            r#"{"action":"fill-window","character":"g","chord":"⌃⌥G","combo":"mod+g","implemented":false,"key_code":5,"modifiers":{"command":false,"control":true,"option":true,"shift":false},"passable":true,"repeat":false}"#
        );
        assert_eq!(
            key("fit-window"),
            r#"{"action":"fit-window","character":"m","chord":"⌃⌥M","combo":"mod+m","implemented":false,"key_code":46,"modifiers":{"command":false,"control":true,"option":true,"shift":false},"passable":true,"repeat":false}"#
        );
        assert_eq!(
            key("fit-window-snapped"),
            r#"{"action":"fit-window-snapped","character":"m","chord":"⌃⌥⇧M","combo":"mod+shift+m","implemented":false,"key_code":46,"modifiers":{"command":false,"control":true,"option":true,"shift":true},"passable":true,"repeat":false}"#
        );
        // A trackpad gesture bound to fit-window fires into the same refusal.
        h.ok(json!({"op":"gesture_begin","kind":"pinch","fingers":2,"modifiers":{"control":false,"option":true,"shift":false,"command":false},"context":"window","output":1,"pointer":{"x":ORIGIN.0+300.0,"y":ORIGIN.1+250.0},"doubletap":false,"time_ms":1000}));
        let fired = h.ok(json!({"op":"gesture_update","scale":0.8,"time_ms":1010}));
        assert_eq!(
            fired["fired"],
            json!({"action":"fit-window","error":"action not implemented on macOS yet: fit-window"})
        );
        assert!(fired.get("effect").is_none() && fired.get("transaction").is_none());
        h.ok(json!({"op":"gesture_end","time_ms":1020}));
        // Nothing moved, nothing was asked of the shell, no mode appeared.
        assert_eq!(h.snapshot(), before);
        assert_eq!(before["native_resize"], Value::Null);
        assert_eq!(mode(&mut h, 1), Value::Null);
        assert_eq!(ipc_mode(&mut h, 1), "Normal");
    }
    // The capability is a real boolean: an Objective-C boxed comparison is not.
    assert_eq!(
        h.call(json!({"op":"native_resize_capability","enabled":1}))["ok"],
        false
    );
}

// Upstream ZoomToFitSnapped and fit_to_bbox. The cluster of window 1 is 1 and
// 2: 2 starts one snap gap (12) right of 1. Their bounding box is x 100..1712,
// y 100..400: 1612 x 300, centered on (906, 250). The usable area is 960 x 740
// and zoom.fit_padding 80 a side, so the zoom is min(800/1612, 580/300), and
// the camera puts the box's center under the usable center (500, 410).
#[test]
fn zoom_to_fit_snapped_moves_only_the_camera_and_needs_no_capability() {
    let mut h = one(CONFIG);
    attach(&mut h, 2, (512.0, 100.0, 1200.0, 300.0));
    attach(&mut h, 3, (6000.0, 5000.0, 300.0, 200.0));
    h.ok(json!({"op":"focus","window":1}));
    let before = pose(&mut h);
    let frames = h.snapshot()["windows"].clone();
    let fit = 800.0 / 1612.0;
    let reply = action(&mut h, "zoom-to-fit-snapped");
    assert_eq!(
        reply,
        json!({"navigation":{"output":1,"generation":1,"target_camera":{"x":906.0 - 500.0 / fit,"y":250.0 - 410.0 / fit},"target_zoom":fit,"animating":true},"effects":[],"dirty":false})
    );
    settle(&mut h);
    assert_eq!(
        pose(&mut h),
        json!({"camera":reply["navigation"]["target_camera"],"zoom":fit})
    );
    // A toggle, as zoom-to-fit is: the next press flies back.
    let back = action(&mut h, "zoom-to-fit-snapped");
    assert_eq!(back["navigation"]["target_camera"], before["camera"]);
    assert_eq!(back["navigation"]["target_zoom"], before["zoom"]);
    settle(&mut h);
    assert_eq!(pose(&mut h), before);
    // No window changed and nothing was asked of the resize path.
    let snapshot = h.snapshot();
    assert_eq!(snapshot["windows"], frames);
    assert_eq!(snapshot["native_resize"], Value::Null);
    // With nothing focused there is no cluster and nothing happens.
    h.ok(json!({"op":"clear_focus"}));
    assert_eq!(action(&mut h, "zoom-to-fit-snapped"), nothing());
    let keys = h.ok(json!({"op":"bindings"}))["keys"].clone();
    let key = keys
        .as_array()
        .unwrap()
        .iter()
        .find(|k| k["action"] == "zoom-to-fit-snapped");
    assert_eq!(key.unwrap()["implemented"], true);
}

// Upstream step_resize_focused. `resize_step` is 30 here, so a cardinal step
// is 30 and a diagonal moves each of its edges by round(30 / sqrt 2) = 21. The
// named edge walks; the opposite edge of window 1 (x 100..500, y 100..400)
// stays where it is.
#[test]
fn grow_and_shrink_walk_the_named_edge_and_hold_the_opposite_one() {
    let (x, y, w, hgt) = START;
    for (direction, dw, dh, left, top) in [
        ("right", 30.0, 0.0, false, false),
        ("left", 30.0, 0.0, true, false),
        ("up", 0.0, 30.0, false, true),
        ("down", 0.0, 30.0, false, false),
        ("up-left", 21.0, 21.0, true, true),
        ("up-right", 21.0, 21.0, false, true),
        ("down-left", 21.0, 21.0, true, false),
        ("down-right", 21.0, 21.0, false, false),
    ] {
        for (verb, sign) in [("grow-window", 1.0), ("shrink-window", -1.0)] {
            let mut h = capable(one(CONFIG));
            let reply = action(&mut h, &format!("{verb} {direction}"));
            // The window was on top already, so nothing saved changed yet, and
            // no camera moves for a step.
            assert_eq!(reply["navigation"], Value::Null, "{reply}");
            assert_eq!(reply["effects"], json!([]));
            assert_eq!(reply["dirty"], false);
            assert_eq!(world(&mut h, 1), rect(x, y, w, hgt));
            let asks = (w + sign * dw, hgt + sign * dh);
            deliver(&mut h, &reply, (w, hgt), asks, "applied", asks);
            let expected = rect(
                if left { x - sign * dw } else { x },
                if top { y - sign * dh } else { y },
                asks.0,
                asks.1,
            );
            assert_eq!(world(&mut h, 1), expected, "{verb} {direction}");
            assert_eq!(mode(&mut h, 1), Value::Null);
            assert_eq!(pose(&mut h), json!({"camera":{"x":0.0,"y":0.0},"zoom":1.0}));
        }
    }
}

// A window that grants only part of a step: the size it took is committed and
// the opposite edge still has not moved, which is where upstream ends up once
// its step_start_rect has taken back what the client refused.
#[test]
fn a_step_the_window_only_partly_grants_commits_its_size_and_still_anchors() {
    // Asked to shrink to 370 wide from the left, it stops at 390: the right
    // edge stays at 500.
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "shrink-window left");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (370.0, 300.0),
        "clamped",
        (390.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(110.0, 100.0, 390.0, 300.0));
    // Asked for 421 x 321 up and left, it takes 410 x 321: right edge 500 and
    // bottom edge 400 hold.
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "grow-window up-left");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (421.0, 321.0),
        "clamped",
        (410.0, 321.0),
    );
    assert_eq!(world(&mut h, 1), rect(90.0, 79.0, 410.0, 321.0));
    // A window that refuses outright keeps its frame, and the transaction ends.
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "grow-window left");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (430.0, 300.0),
        "rejected",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    // The next step starts from the size the window has, not from the request.
    let reply = action(&mut h, "grow-window left");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (430.0, 300.0),
        "applied",
        (430.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(70.0, 100.0, 430.0, 300.0));
}

// Upstream compute_fit_geometry, by hand. The usable area is (20, 40) 960 x 740
// in output points and snap.outer_gap is 8, so the fitted size is
// (960 - 16) x (740 - 16) = 944 x 724. Window 1 is centered on (300, 250) and
// the usable center is (500, 410), so the camera target is
// round((300, 250) - (500, 410)) = (-200, -160) and the window's top-left is
// camera + usable top-left + gap = (-200 + 20 + 8, -160 + 40 + 8) = (-172, -112).
// On the screen that frame runs from (28, 48) to (972, 772): the gap on every
// side, with its center on the usable center. `focus_placement = "left"` is in
// force and plays no part, as src/tests/focus_placement.rs states.
#[test]
fn fit_window_fills_the_usable_area_centers_the_camera_and_toggles_back() {
    let mut h = capable(one(CONFIG));
    // From a zoomed-out view somewhere else: the fit does not depend on it.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":ORIGIN.0,"y":ORIGIN.1}}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":700.0,"y":-90.0}}));
    let reply = action(&mut h, "fit-window");
    // Asked at once, as upstream asks beside its configure: the focus, and the
    // camera and zoom, which do not depend on the size the window then takes.
    assert_eq!(
        reply["navigation"],
        json!({"output":1,"generation":1,"target_camera":{"x":-200.0,"y":-160.0},"target_zoom":1.0,"animating":true})
    );
    assert_eq!(reply["effects"].as_array().unwrap().len(), 1, "{reply}");
    assert_eq!(reply["effects"][0]["op"], "focus_native_window");
    assert_eq!(reply["effects"][0]["window"], 1);
    assert_eq!(reply["dirty"], true);
    // The frame, the mode and the restore point wait for the window's answer.
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fit");
    assert_eq!(ipc_mode(&mut h, 1), "Fit");
    settle(&mut h);
    assert_eq!(
        pose(&mut h),
        json!({"camera":{"x":-200.0,"y":-160.0},"zoom":1.0})
    );

    // Moving a fit window does not end the fit: upstream's moves clear only a
    // fill restore point. The unfit then resizes around the center it finds.
    assert_eq!(action(&mut h, "nudge-window right")["dirty"], true);
    assert_eq!(world(&mut h, 1), rect(-152.0, -112.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fit");
    ipc(&mut h, json!({"Move":{"to":[300,-250]}}));
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fit");

    // The toggle: only the saved size comes back, around the frame's center
    // (300, 250). No camera moves and no focus is asked for.
    let reply = action(&mut h, "fit-window");
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(reply["effects"], json!([]));
    assert_eq!(mode(&mut h, 1), "fit");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert_eq!(ipc_mode(&mut h, 1), "Normal");
    assert_eq!(
        pose(&mut h),
        json!({"camera":{"x":-200.0,"y":-160.0},"zoom":1.0})
    );
}

// The integer rules of upstream's fit. A 401 x 301 window at (100, 100) is
// centered on (300.5, 250.5): the camera target rounds (-199.5, -159.5) away
// from zero to (-200, -160), so the fitted frame is the same (-172, -112). The
// unfit truncates: (300 - 200.5, 250 - 150.5) = (99.5, 99.5) becomes (99, 99).
#[test]
fn fit_rounds_the_camera_and_unfit_truncates_as_upstream_does() {
    let mut h = capable(empty(CONFIG));
    attach(&mut h, 1, (100.0, 100.0, 401.0, 301.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "fit-window");
    assert_eq!(
        reply["navigation"]["target_camera"],
        json!({"x":-200.0,"y":-160.0})
    );
    deliver(
        &mut h,
        &reply,
        (401.0, 301.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (401.0, 301.0),
        "applied",
        (401.0, 301.0),
    );
    assert_eq!(world(&mut h, 1), rect(99.0, 99.0, 401.0, 301.0));
}

// A window that takes less than the fit asked for is still fit: upstream marks
// it and maps it at the fit's top-left whatever the client commits, and goes
// on measuring it by the frame the fit asked for (its configured size):
// (-172, -112) 944 x 724, centered on (300, 250). So the unfit takes the
// window home, and a fill finds that frame already filling its space.
#[test]
fn a_fit_the_window_clamps_commits_its_size_at_the_fit_place() {
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "clamped",
        (900.0, 700.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 900.0, 700.0));
    assert_eq!(mode(&mut h, 1), "fit");
    // On an empty canvas the frame asked for is the whole inset usable area,
    // so fill-window has nothing to grow into: it starts nothing and the
    // window stays fit.
    settle(&mut h);
    assert_eq!(action(&mut h, "fill-window"), nothing());
    assert_eq!(mode(&mut h, 1), "fit");
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    // Around (300, 250) the saved 400 x 300 goes back to (100, 100).
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (900.0, 700.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);

    // A window that will not change size at all is moved to the fit's place
    // and marked, as upstream does for a client that ignores the configure.
    // Every fit and unfit of it is the same round trip: nothing walks.
    let mut h = capable(one(CONFIG));
    for _ in 0..2 {
        let reply = action(&mut h, "fit-window");
        assert_eq!(
            reply["navigation"]["target_camera"],
            json!({"x":-200.0,"y":-160.0})
        );
        deliver(
            &mut h,
            &reply,
            (400.0, 300.0),
            (944.0, 724.0),
            "rejected",
            (400.0, 300.0),
        );
        assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 400.0, 300.0));
        assert_eq!(mode(&mut h, 1), "fit");
        // The unfit needs no new size: it is a placement, applied at once,
        // around the same center (300, 250) of the frame the fit asked for.
        let reply = action(&mut h, "fit-window");
        assert!(reply.get("effect").is_none(), "{reply}");
        assert_eq!(reply["dirty"], true);
        assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
        assert_eq!(mode(&mut h, 1), Value::Null);
    }
}

// Upstream configured_window_size, as compute_fit_geometry and
// fit_window_snapped read it (src/state/fit.rs): a fit centers on the frame
// of the size the window was last asked for, at the top-left it has, and the
// snapped variant measures its neighbours from that frame. The size the
// window took of the request plays no part. The usable center is (500, 410)
// and the inset corner (28, 48), as above.
#[test]
fn a_fit_centers_on_the_frame_last_asked_for_not_the_one_the_window_took() {
    // A step asks 430 x 300 from the right edge and the window takes 410.
    // The frame asked for is (100, 100) 430 x 300, centered on (315, 250):
    // the camera goes to round((315, 250) - (500, 410)) = (-185, -160) and the
    // top-left to (-185 + 28, -160 + 48) = (-157, -112). The frame the window
    // took is centered on (305, 250), 10 short of that.
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "grow-window right");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (430.0, 300.0),
        "clamped",
        (410.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 410.0, 300.0));
    // Window 2 is one snap gap from the right edge of the frame asked for,
    // x 530 + 12, and 32 from the frame the window took: a neighbour of the
    // first only. The fit takes that edge from 530 to -157 + 944 = 787, and
    // the neighbour follows it by 257 to 787 + 12.
    attach(&mut h, 2, (542.0, 100.0, 200.0, 300.0));
    let reply = action(&mut h, "fit-window-snapped");
    assert_eq!(
        reply["navigation"]["target_camera"],
        json!({"x":-185.0,"y":-160.0})
    );
    deliver(
        &mut h,
        &reply,
        (410.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-157.0, -112.0, 944.0, 724.0));
    assert_eq!(world(&mut h, 2), rect(799.0, 100.0, 200.0, 300.0));
    assert_eq!(mode(&mut h, 1), "fit");
    // The unfit gives the 410 x 300 back around the fit frame's center
    // (315, 250): the window comes back 10 from where the step left it, as
    // upstream's does once its client has clamped the unfit's configure.
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (410.0, 300.0),
        "applied",
        (410.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(110.0, 100.0, 410.0, 300.0));

    // An IPC resize asks 1000 x 600 around the center (300, 250) and the
    // window takes 800 x 600 at the top-left written for the request,
    // (-200, -50). The frame asked for is still centered on (300, 250), so
    // the fit is the plain one: camera (-200, -160), top-left (-172, -112).
    // The frame the window took is centered on (200, 250).
    let mut h = capable(one(CONFIG));
    let reply = ipc(&mut h, json!({"Resize":{"to":[1000,600]}}));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (1000.0, 600.0),
        "clamped",
        (800.0, 600.0),
    );
    assert_eq!(world(&mut h, 1), rect(-200.0, -50.0, 800.0, 600.0));
    let reply = action(&mut h, "fit-window");
    assert_eq!(
        reply["navigation"]["target_camera"],
        json!({"x":-200.0,"y":-160.0})
    );
    deliver(
        &mut h,
        &reply,
        (800.0, 600.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    // And back: 800 x 600 around (300, 250).
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (800.0, 600.0),
        "applied",
        (800.0, 600.0),
    );
    assert_eq!(world(&mut h, 1), rect(-100.0, -50.0, 800.0, 600.0));

    // A fill asks (240, 48) 732 x 724 and the window takes 700 x 700 there.
    // The frame asked for is centered on (606, 410): camera
    // round((606, 410) - (500, 410)) = (106, 0), top-left (134, 48). The
    // frame the window took is centered on (590, 398). The fit saves the
    // 300 x 200 from before the fill.
    let mut h = capable(empty(CONFIG));
    attach(&mut h, 1, (400.0, 300.0, 300.0, 200.0));
    attach(&mut h, 2, (28.0, 48.0, 200.0, 724.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (732.0, 724.0),
        "clamped",
        (700.0, 700.0),
    );
    assert_eq!(world(&mut h, 1), rect(240.0, 48.0, 700.0, 700.0));
    assert_eq!(mode(&mut h, 1), "fill");
    let reply = action(&mut h, "fit-window");
    assert_eq!(
        reply["navigation"]["target_camera"],
        json!({"x":106.0,"y":0.0})
    );
    deliver(
        &mut h,
        &reply,
        (700.0, 700.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(134.0, 48.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fit");
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (300.0, 200.0),
        "applied",
        (300.0, 200.0),
    );
    // Around (134 + 472, 48 + 362) = (606, 410).
    assert_eq!(world(&mut h, 1), rect(456.0, 310.0, 300.0, 200.0));

    // A fill grows from the frame last asked for as well (src/state/fill.rs,
    // compute_fill_geometry). Alone on the canvas, a window at the inset
    // corner (28, 48) is stepped from 914 to 944 wide, the whole inset
    // width, and takes 930. The frame asked for already fills its space, so
    // fill-window starts nothing; the frame the window took is 14 short.
    let mut h = capable(empty(CONFIG));
    attach(&mut h, 1, (28.0, 48.0, 914.0, 724.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "grow-window right");
    deliver(
        &mut h,
        &reply,
        (914.0, 724.0),
        (944.0, 724.0),
        "clamped",
        (930.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(28.0, 48.0, 930.0, 724.0));
    assert_eq!(action(&mut h, "fill-window"), nothing());
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    // A resize drag ends what was asked: the window is measured by the size
    // it has again, and the same fill grows the 14 to the inset edge.
    h.ok(json!({"op":"begin_resize","window":1,"output":1,"edges":"bottom"}));
    h.ok(json!({"op":"end_gesture"}));
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (930.0, 724.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(28.0, 48.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fill");
}

// Upstream fit_window_snapped and shift_cluster_around_primary. Window 1 goes
// from x 100..500, y 100..400 to the fit frame x -172..772, y -112..612: its
// right edge moves +272, its left -272, its bottom +212 and its top -212.
// 2 is snapped to its right edge, 3 to its bottom edge and 4 to its left edge,
// each one snap gap (12) away; 5 is nobody's neighbour. Each neighbour follows
// the edge it is snapped to, and comes back with the unfit.
#[test]
fn fit_window_snapped_shoves_the_snapped_neighbours_and_brings_them_back() {
    let cluster = || {
        let mut h = capable(one(CONFIG));
        attach(&mut h, 2, (512.0, 100.0, 200.0, 300.0));
        attach(&mut h, 3, (100.0, 412.0, 400.0, 200.0));
        attach(&mut h, 4, (-62.0, 100.0, 150.0, 300.0));
        attach(&mut h, 5, (3000.0, 3000.0, 100.0, 100.0));
        h.ok(json!({"op":"focus","window":1}));
        h
    };
    let mut h = cluster();
    let reply = action(&mut h, "fit-window-snapped");
    assert_eq!(
        reply["navigation"]["target_camera"],
        json!({"x":-200.0,"y":-160.0})
    );
    // Nobody moves before the window has answered.
    assert_eq!(world(&mut h, 2), rect(512.0, 100.0, 200.0, 300.0));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fit");
    assert_eq!(world(&mut h, 2), rect(784.0, 100.0, 200.0, 300.0));
    assert_eq!(world(&mut h, 3), rect(100.0, 624.0, 400.0, 200.0));
    assert_eq!(world(&mut h, 4), rect(-334.0, 100.0, 150.0, 300.0));
    assert_eq!(world(&mut h, 5), rect(3000.0, 3000.0, 100.0, 100.0));
    for id in 2..=5 {
        assert_eq!(mode(&mut h, id), Value::Null);
    }
    let reply = action(&mut h, "fit-window-snapped");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(world(&mut h, 2), rect(512.0, 100.0, 200.0, 300.0));
    assert_eq!(world(&mut h, 3), rect(100.0, 412.0, 400.0, 200.0));
    assert_eq!(world(&mut h, 4), rect(-62.0, 100.0, 150.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);

    // The plain fit leaves the same neighbours where they are.
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 2), rect(512.0, 100.0, 200.0, 300.0));
    assert_eq!(world(&mut h, 4), rect(-62.0, 100.0, 150.0, 300.0));

    // A window that takes 940 x 718 of the 944 x 724 asked for. The neighbours
    // follow the frame asked for, and the unfit measures from that frame too
    // (upstream's configured size), not from the 4 and 6 pixels less the
    // window took: everyone comes home.
    let mut h = cluster();
    let reply = action(&mut h, "fit-window-snapped");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "clamped",
        (940.0, 718.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 940.0, 718.0));
    assert_eq!(world(&mut h, 2), rect(784.0, 100.0, 200.0, 300.0));
    assert_eq!(world(&mut h, 3), rect(100.0, 624.0, 400.0, 200.0));
    assert_eq!(world(&mut h, 4), rect(-334.0, 100.0, 150.0, 300.0));
    let reply = action(&mut h, "fit-window-snapped");
    deliver(
        &mut h,
        &reply,
        (940.0, 718.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(world(&mut h, 2), rect(512.0, 100.0, 200.0, 300.0));
    assert_eq!(world(&mut h, 3), rect(100.0, 412.0, 400.0, 200.0));
    assert_eq!(world(&mut h, 4), rect(-62.0, 100.0, 150.0, 300.0));
    assert_eq!(world(&mut h, 5), rect(3000.0, 3000.0, 100.0, 100.0));
}

// Upstream compute_fill_geometry, by hand. With the camera at the world origin
// at zoom 1 the usable area covers x 20..980, y 40..780, and snap.outer_gap 8
// leaves x 28..972, y 48..772 to grow into. Window 2 stands along the left
// edge, x 28..228 over the whole height, so window 1 (x 400..700, y 300..500)
// grows left to 228 + snap.gap 12 = 240 and to the other three inset edges:
// (240, 48) 732 x 724. No camera moves and no focus is asked for.
#[test]
fn fill_window_grows_into_the_free_space_and_toggles_back() {
    let mut h = capable(empty(CONFIG));
    attach(&mut h, 1, (400.0, 300.0, 300.0, 200.0));
    attach(&mut h, 2, (28.0, 48.0, 200.0, 724.0));
    h.ok(json!({"op":"focus","window":1}));
    let view = pose(&mut h);
    let reply = action(&mut h, "fill-window");
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
    assert_eq!(reply["effects"], json!([]));
    assert_eq!(mode(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (732.0, 724.0),
        "applied",
        (732.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(240.0, 48.0, 732.0, 724.0));
    assert_eq!(world(&mut h, 2), rect(28.0, 48.0, 200.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fill");
    assert_eq!(ipc_mode(&mut h, 1), "Fill");
    assert_eq!(pose(&mut h), view);

    // Upstream's RestoreFillElseReset: center-window on a window still filled
    // returns to the camera and zoom the fill ran in. `focus_placement = "left"`
    // would park this frame's left edge at the gap, a camera at x = 212.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":ORIGIN.0,"y":ORIGIN.1}}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":900.0,"y":300.0}}));
    let moved = action(&mut h, "center-window");
    assert_eq!(moved["navigation"]["target_camera"], view["camera"]);
    assert_eq!(moved["navigation"]["target_zoom"], view["zoom"]);
    settle(&mut h);
    assert_eq!(pose(&mut h), view);

    // The toggle restores the frame the fill replaced, exactly.
    let reply = action(&mut h, "fill-window");
    assert_eq!(reply["navigation"], Value::Null);
    deliver(
        &mut h,
        &reply,
        (732.0, 724.0),
        (300.0, 200.0),
        "applied",
        (300.0, 200.0),
    );
    assert_eq!(world(&mut h, 1), rect(400.0, 300.0, 300.0, 200.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    // And center-window is its plain self again: the left placement, zoom 1.
    // The frame is 300 wide, so its center parks at 20 + 8 + 150 = 178 and the
    // camera at x = 550 - 178.
    let moved = action(&mut h, "center-window");
    assert_eq!(moved["navigation"]["target_camera"]["x"], 372.0);
}

// What ends a fill restore point: upstream clears it wherever a window is
// re-anchored. The window keeps the filled frame and is simply no longer
// filled, so the next fill-window is a fill again, not a restore.
#[test]
fn moving_a_filled_window_ends_its_restore_point() {
    let filled = |h: &mut Host| {
        let reply = action(h, "fill-window");
        deliver(
            h,
            &reply,
            (300.0, 200.0),
            (732.0, 724.0),
            "applied",
            (732.0, 724.0),
        );
        assert_eq!(mode(h, 1), "fill");
    };
    let fresh = || {
        let mut h = capable(empty(CONFIG));
        attach(&mut h, 1, (400.0, 300.0, 300.0, 200.0));
        attach(&mut h, 2, (28.0, 48.0, 200.0, 724.0));
        h.ok(json!({"op":"focus","window":1}));
        filled(&mut h);
        h
    };
    // nudge-window.
    let mut h = fresh();
    action(&mut h, "nudge-window right");
    assert_eq!(mode(&mut h, 1), Value::Null);
    // The 300 x 200 from before the fill is still what a fit saves: upstream's
    // restore_size, which neither a fill nor a move replaces.
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (732.0, 724.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (300.0, 200.0),
        "applied",
        (300.0, 200.0),
    );
    assert_eq!(mode(&mut h, 1), Value::Null);
    // And what a later fill saves, with the place the window has by then.
    // Nudged 20 left it overlaps window 2, so the fill only pulls it back to
    // x = 240: a placement, at the size it has. The unfill gives back
    // 300 x 200 at (220, 48), where the fill found it.
    let mut h = fresh();
    action(&mut h, "nudge-window left");
    assert_eq!(world(&mut h, 1), rect(220.0, 48.0, 732.0, 724.0));
    let reply = action(&mut h, "fill-window");
    assert!(reply.get("effect").is_none(), "{reply}");
    assert_eq!(world(&mut h, 1), rect(240.0, 48.0, 732.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fill");
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (732.0, 724.0),
        (300.0, 200.0),
        "applied",
        (300.0, 200.0),
    );
    assert_eq!(world(&mut h, 1), rect(220.0, 48.0, 300.0, 200.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    // IPC Move, even to where the window already is.
    let mut h = fresh();
    ipc(&mut h, json!({"Move":{"to":[606,-410]}}));
    assert_eq!(world(&mut h, 1), rect(240.0, 48.0, 732.0, 724.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    // It fills its space already, so fill-window has nothing to do, starts
    // nothing and records nothing.
    assert_eq!(action(&mut h, "fill-window"), nothing());
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert!(!h.snapshot()["native_resize"]["pending_effect"].is_object());
    // A pointer drag, at its first press.
    let mut h = fresh();
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(mode(&mut h, 1), Value::Null);
    h.ok(json!({"op":"end_gesture"}));
    // A drag of its snap cluster, begun on the neighbour the fill stopped one
    // gap short of: every member dragged along is re-anchored.
    let mut h = fresh();
    h.ok(json!({"op":"begin_drag","window":2,"output":1,"group":true}));
    assert_eq!(mode(&mut h, 1), Value::Null);
    h.ok(json!({"op":"end_gesture"}));
    // The same neighbour dragged alone leaves the filled window where it is.
    let mut h = fresh();
    h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    assert_eq!(mode(&mut h, 1), "fill");
    h.ok(json!({"op":"end_gesture"}));
    // A resize drag ends it too, as it ends a fit.
    let mut h = fresh();
    h.ok(json!({"op":"begin_resize","window":1,"output":1,"edges":"right"}));
    assert_eq!(mode(&mut h, 1), Value::Null);
    h.ok(json!({"op":"end_gesture"}));
    // A group resize of the neighbour: the filled window keeps its restore
    // point until the growing edge actually shifts it.
    let mut h = fresh();
    h.ok(json!({"op":"begin_resize","window":2,"output":1,"edges":"right","group":true}));
    assert_eq!(mode(&mut h, 1), "fill");
    h.ok(json!({"op":"gesture_to","screen_delta":{"x":50.0,"y":0.0}}));
    assert_eq!(world(&mut h, 2), rect(28.0, 48.0, 250.0, 724.0));
    assert_eq!(world(&mut h, 1), rect(290.0, 48.0, 732.0, 724.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    h.ok(json!({"op":"end_gesture"}));
    // A step ends it once the window has answered.
    let mut h = fresh();
    let reply = action(&mut h, "grow-window down");
    assert_eq!(mode(&mut h, 1), "fill");
    deliver(
        &mut h,
        &reply,
        (732.0, 724.0),
        (732.0, 754.0),
        "applied",
        (732.0, 754.0),
    );
    assert_eq!(mode(&mut h, 1), Value::Null);
    // The window becoming a stand-in ends it.
    let mut h = fresh();
    ipc(&mut h, json!({"Suspend":null}));
    h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    assert_eq!(h.snapshot()["lifecycle"]["standins"], json!([1]));
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert_eq!(ipc_mode(&mut h, 1), "Normal");
}

// Fit and fill end each other. After the fit the camera is at (-200, -160), so
// the usable area covers x -180..780, y -120..620 and the fit frame is the
// inset area x -172..772, y -112..612. Window 2 (x 700..1000, y 0..300)
// overlaps its right part, so the fill pulls the right edge back to
// 700 - 12 = 688: (-172, -112) 860 x 724. The window is then filled, not fit,
// and the unfill gives back the size from before the fit, around the fit
// frame's center (300, 250): (100, 100) 400 x 300.
#[test]
fn a_fill_takes_a_window_out_of_fit_and_restores_the_frame_before_it() {
    let mut h = capable(one(CONFIG));
    attach(&mut h, 2, (700.0, 0.0, 300.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    settle(&mut h);
    assert_eq!(mode(&mut h, 1), "fit");
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (860.0, 724.0),
        "applied",
        (860.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 860.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fill");
    assert_eq!(ipc_mode(&mut h, 1), "Fill");
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (860.0, 724.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);

    // And a fit ends a fill: the mode is fit, and the unfit restores the size
    // from before the fill (upstream's restore_size), not the filled one.
    let reply = action(&mut h, "fill-window");
    let filled = began(&mut h, &reply);
    let setter = answer(&mut h, &filled, "observed", false, (400.0, 300.0))["effect"].clone();
    let asked = (
        setter["requested"]["width"].as_f64().unwrap(),
        setter["requested"]["height"].as_f64().unwrap(),
    );
    let last = answer(&mut h, &setter, "applied", true, asked)["effect"].clone();
    answer(&mut h, &last, "observed", false, asked);
    assert_eq!(mode(&mut h, 1), "fill");
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        asked,
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(mode(&mut h, 1), "fit");
    assert_eq!(ipc_mode(&mut h, 1), "Fit");
    assert_ne!(asked, (400.0, 300.0));
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(mode(&mut h, 1), Value::Null);
}

// Upstream cmd_resize. The size is the frame's, the center is kept by moving
// the top-left half the difference in whole pixels, and the reply echoes the
// size asked for.
#[test]
fn ipc_resize_keeps_the_center_and_follows_upstreams_refusals() {
    let mut h = capable(one(CONFIG));
    attach(&mut h, 2, (2000.0, 1000.0, 200.0, 100.0));
    h.ok(json!({"op":"focus","window":1}));
    // 400 x 300 at (100, 100) to 600 x 400: the top-left moves (-100, -50).
    let reply = ipc(&mut h, json!({"Resize":{"to":[600,400]}}));
    assert_eq!(
        reply["reply"],
        json!({"Ok":{"Size":{"width":600,"height":400}}})
    );
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(reply["effects"], json!([]));
    assert_eq!(reply["dirty"], false);
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(world(&mut h, 1), rect(0.0, 50.0, 600.0, 400.0));
    // An odd difference halves toward zero, as upstream's i32 division does.
    let reply = ipc(&mut h, json!({"Resize":{"window":1,"to":[601,401]}}));
    deliver(
        &mut h,
        &reply,
        (600.0, 400.0),
        (601.0, 401.0),
        "applied",
        (601.0, 401.0),
    );
    assert_eq!(world(&mut h, 1), rect(0.0, 50.0, 601.0, 401.0));
    // The read is what it was, and a selector reaches a window without focus.
    assert_eq!(
        ipc(&mut h, json!({"Resize":{"window":"app.2"}}))["reply"],
        json!({"Ok":{"Size":{"width":200,"height":100}}})
    );
    // Upstream's cmd_resize raises a client and hands it no focus: window 2
    // goes over the focused window 1 in the reply that asks, which says so
    // with `dirty`, the stacking being saved, and requests no focus.
    let before = h.snapshot();
    assert_eq!(before["windows"][1]["window"], 1);
    let reply = ipc(&mut h, json!({"Resize":{"window":"app.2","to":[300,200]}}));
    assert_eq!(
        (&reply["dirty"], &reply["effects"]),
        (&json!(true), &json!([]))
    );
    let raised = h.snapshot();
    assert_eq!(raised["windows"][0]["window"], 1);
    assert_eq!(raised["windows"][1]["window"], 2);
    assert_eq!(raised["focused"], 1);
    assert_eq!(raised["focus"], before["focus"]);
    deliver(
        &mut h,
        &reply,
        (200.0, 100.0),
        (300.0, 200.0),
        "applied",
        (300.0, 200.0),
    );
    assert_eq!(world(&mut h, 2), rect(1950.0, 950.0, 300.0, 200.0));
    // The same size again delivers nothing, moves nothing and restacks
    // nothing, as upstream's resize_element_to returns before its map: a
    // window that something else has covered stays covered.
    h.ok(json!({"op":"focus","window":1}));
    let before = h.snapshot();
    assert_eq!(before["windows"][1]["window"], 1);
    let reply = ipc(&mut h, json!({"Resize":{"window":2,"to":[300,200]}}));
    assert_eq!(
        reply,
        json!({"reply":{"Ok":{"Size":{"width":300,"height":200}}},"effects":[],"dirty":false,"navigation":null})
    );
    assert_eq!(h.snapshot(), before);

    // Upstream's refusals, each leaving everything as it was.
    let refused = |h: &mut Host, request: Value| {
        let before = h.snapshot();
        let reply = ipc(h, request);
        assert_eq!(h.snapshot(), before);
        assert!(reply.get("effect").is_none(), "{reply}");
        reply["reply"]["Err"].as_str().unwrap().to_owned()
    };
    assert_eq!(
        refused(&mut h, json!({"Resize":{"to":[0,400]}})),
        "size must be positive"
    );
    assert_eq!(
        refused(&mut h, json!({"Resize":{"to":[400,-1]}})),
        "size must be positive"
    );
    assert_eq!(
        refused(&mut h, json!({"Resize":{"window":9,"to":[400,300]}})),
        "no window with id 9"
    );
    h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    assert_eq!(
        refused(&mut h, json!({"Resize":{"window":1,"to":[400,300]}})),
        "this window is under an interactive move or resize, or still settling one"
    );
    h.ok(json!({"op":"end_gesture"}));
    h.ok(json!({"op":"clear_focus"}));
    assert_eq!(
        refused(&mut h, json!({"Resize":{"to":[400,300]}})),
        "no focused window"
    );
}

// Upstream requested_element_size: an absolute resize measures from the size
// it last asked for while the window's size still reads as an answer to it.
// From 400 x 300 at (100, 100), 1000 x 600 puts the top-left at (-200, -50).
// The window grants 800 x 600 and keeps that top-left: upstream writes the
// place for the size it asked for and does not re-center on what it got.
#[test]
fn an_absolute_resize_measures_from_the_size_it_last_asked_for() {
    let mut h = capable(one(CONFIG));
    let reply = ipc(&mut h, json!({"Resize":{"to":[1000,600]}}));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (1000.0, 600.0),
        "clamped",
        (800.0, 600.0),
    );
    assert_eq!(world(&mut h, 1), rect(-200.0, -50.0, 800.0, 600.0));
    // The same request again is a no-op: no second shift, nothing delivered.
    let before = h.snapshot();
    let reply = ipc(&mut h, json!({"Resize":{"to":[1000,600]}}));
    assert_eq!(
        reply,
        json!({"reply":{"Ok":{"Size":{"width":1000,"height":600}}},"effects":[],"dirty":false,"navigation":null})
    );
    assert_eq!(h.snapshot(), before);
    // Another size is measured from the 1000 asked for, not the 800 granted:
    // (1000 - 1200) / 2 = -100.
    let reply = ipc(&mut h, json!({"Resize":{"to":[1200,600]}}));
    deliver(
        &mut h,
        &reply,
        (800.0, 600.0),
        (1200.0, 600.0),
        "applied",
        (1200.0, 600.0),
    );
    assert_eq!(world(&mut h, 1), rect(-300.0, -50.0, 1200.0, 600.0));
    // And that request, repeated, is again nothing.
    let before = h.snapshot();
    ipc(&mut h, json!({"Resize":{"to":[1200,600]}}));
    assert_eq!(h.snapshot(), before);

    // Asking for the size the window settled on needs nothing delivered, but
    // it is not the size last asked for, so upstream still shifts the frame by
    // half the difference, (1000 - 800) / 2 = 100: a placement, applied at once.
    let mut h = capable(one(CONFIG));
    let reply = ipc(&mut h, json!({"Resize":{"to":[1000,600]}}));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (1000.0, 600.0),
        "clamped",
        (800.0, 600.0),
    );
    let reply = ipc(&mut h, json!({"Resize":{"to":[800,600]}}));
    assert_eq!(
        reply,
        json!({"reply":{"Ok":{"Size":{"width":800,"height":600}}},"effects":[],"dirty":true,"navigation":null})
    );
    assert_eq!(world(&mut h, 1), rect(-100.0, -50.0, 800.0, 600.0));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
}

// A stand-in has no native window. Upstream resizes a stand-in's own frame for
// a step and for IPC resize; here that is refused (SIZES.md says why). Fit and
// fill are upstream's own no-ops: its focused_window is a client.
#[test]
fn a_sizing_action_on_a_stand_in_is_refused() {
    let mut h = capable(one(CONFIG));
    ipc(&mut h, json!({"Suspend":null}));
    h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    assert_eq!(h.snapshot()["lifecycle"]["standins"], json!([1]));
    assert_eq!(h.snapshot()["focused"], 1);
    for (sample, name) in [
        ("grow-window right", "grow-window"),
        ("shrink-window up", "shrink-window"),
    ] {
        assert_eq!(
            h.error(json!({"op":"action","output":1,"action":sample})),
            format!("{name} needs a live window: a stand-in has no native size to change")
        );
    }
    let before = h.snapshot();
    let reply = ipc(&mut h, json!({"Resize":{"to":[500,400]}}));
    assert_eq!(
        reply["reply"],
        json!({"Err":"this window has no native size to set: it is a stand-in or has no live window"})
    );
    for sample in ["fit-window", "fit-window-snapped", "fill-window"] {
        assert_eq!(action(&mut h, sample), nothing(), "{sample}");
    }
    assert_eq!(h.snapshot(), before);
    assert_eq!(before["native_resize"], Value::Null);
    // A slot whose window was only detached is no different.
    let mut h = capable(one(CONFIG));
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(1),"keep_placeholder":true}));
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"grow-window left"})),
        "grow-window needs a live window: a stand-in has no native size to change"
    );
    assert_eq!(action(&mut h, "fit-window"), nothing());
    // With no window focused at all the actions do nothing, as upstream's do.
    h.ok(json!({"op":"clear_focus"}));
    for sample in ["grow-window right", "fit-window", "fill-window"] {
        assert_eq!(action(&mut h, sample), nothing(), "{sample}");
    }
}

// The window goes away while its size is still owed. The adapter then finds no
// window: the transaction fails, nothing of the plan is written, the close is
// accepted and the next sizing action starts cleanly.
#[test]
fn a_window_that_closes_mid_transaction_leaves_nothing_stuck() {
    for stage in ["baseline", "setter"] {
        let mut h = capable(one(CONFIG));
        attach(&mut h, 2, (2000.0, 1000.0, 200.0, 100.0));
        h.ok(json!({"op":"focus","window":1}));
        let reply = action(&mut h, "fit-window");
        let mut effect = began(&mut h, &reply);
        if stage == "setter" {
            effect = answer(&mut h, &effect, "observed", false, (400.0, 300.0))["effect"].clone();
            assert_eq!(effect["op"], "resize_native_window");
        }
        // While the effect is owed the close is refused, as for a drag: the
        // shell reports the result first.
        assert_eq!(
            h.error(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1})),
            "resize must drain before structural change; cancel and reconcile pending effects"
        );
        assert_eq!(
            answer(&mut h, &effect, "missing_window", false, (1.0, 1.0))["effect"],
            Value::Null
        );
        let slot = h.snapshot()["native_resize"].clone();
        assert_eq!(slot["phase"], "failed", "{stage}: {slot}");
        assert_eq!(slot["pending_effect"], Value::Null);
        assert_eq!(slot["uncertain_mutation"], false);
        // No part of the fit was written.
        assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
        assert_eq!(mode(&mut h, 1), Value::Null);
        let closed =
            h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
        assert_eq!(closed["standin"], false);
        assert_eq!(h.snapshot()["windows"].as_array().unwrap().len(), 1);
        // Another window sizes at once, and a late answer to the dead
        // transaction is refused without touching it.
        h.ok(json!({"op":"focus","window":2}));
        let reply = action(&mut h, "grow-window right");
        assert_eq!(
            h.call(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":"observed","ax_error":0,"mutation_attempted":false,"observed":true,"requested":{"width":0.0,"height":0.0},"actual_ax":rect(0.0,0.0,944.0,724.0),"actual_cg":rect(0.0,0.0,944.0,724.0)}}))["ok"],
            false
        );
        deliver(
            &mut h,
            &reply,
            (200.0, 100.0),
            (230.0, 100.0),
            "applied",
            (230.0, 100.0),
        );
        assert_eq!(world(&mut h, 2), rect(2000.0, 1000.0, 230.0, 100.0));
        assert_eq!(mode(&mut h, 2), Value::Null);
    }
}

// Upstream placed_element_size: while a size is still owed, the next step
// walks on from the size asked for. It takes the transaction's one
// latest-request slot; nothing new is dispatched until the owed result arrives.
#[test]
fn a_second_step_while_one_is_pending_walks_on_from_the_size_asked_for() {
    // Two presses before the baseline read is answered: one setter, for both.
    let mut h = capable(one(CONFIG));
    let first = action(&mut h, "grow-window right");
    let read = began(&mut h, &first);
    let second = action(&mut h, "grow-window right");
    assert_eq!(second, nothing());
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["pending_effect"], read);
    assert_eq!(
        slot["coalesced_latest"],
        json!({"width":460.0,"height":300.0})
    );
    deliver(
        &mut h,
        &first,
        (400.0, 300.0),
        (460.0, 300.0),
        "applied",
        (460.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 460.0, 300.0));

    // A press while the first setter is out: its result is committed with the
    // right edge held, then the second setter goes out and is committed too.
    let mut h = capable(one(CONFIG));
    let first = action(&mut h, "grow-window left");
    let read = began(&mut h, &first);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    assert_eq!(setter["requested"], json!({"width":430.0,"height":300.0}));
    assert_eq!(action(&mut h, "grow-window left"), nothing());
    let next = answer(&mut h, &setter, "applied", true, (430.0, 300.0))["effect"].clone();
    assert_eq!(world(&mut h, 1), rect(70.0, 100.0, 430.0, 300.0));
    assert_eq!(next["op"], "resize_native_window");
    assert_eq!(next["requested"], json!({"width":460.0,"height":300.0}));
    let last = answer(&mut h, &next, "applied", true, (460.0, 300.0))["effect"].clone();
    assert_eq!(world(&mut h, 1), rect(40.0, 100.0, 460.0, 300.0));
    answer(&mut h, &last, "observed", false, (460.0, 300.0));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    // A step back while the grow is owed returns to the size the window has:
    // nothing more is sent.
    let grow = action(&mut h, "grow-window left");
    assert_eq!(action(&mut h, "shrink-window left"), nothing());
    let read = began(&mut h, &grow);
    assert_eq!(
        answer(&mut h, &read, "observed", false, (460.0, 300.0))["effect"],
        Value::Null
    );
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(world(&mut h, 1), rect(40.0, 100.0, 460.0, 300.0));

    // Upstream ends fit and fill at the step itself. A request walked back to
    // the size the window has sends no setter, so no result would end them:
    // they end when the request comes back to that size.
    let fitted = || {
        let mut h = capable(one(CONFIG));
        let reply = action(&mut h, "fit-window");
        deliver(
            &mut h,
            &reply,
            (400.0, 300.0),
            (944.0, 724.0),
            "applied",
            (944.0, 724.0),
        );
        assert_eq!(mode(&mut h, 1), "fit");
        h
    };
    let mut h = fitted();
    let grow = action(&mut h, "grow-window right");
    assert_eq!(mode(&mut h, 1), "fit");
    assert_eq!(action(&mut h, "shrink-window right"), nothing());
    assert_eq!(mode(&mut h, 1), Value::Null);
    let read = began(&mut h, &grow);
    assert_eq!(
        answer(&mut h, &read, "observed", false, (944.0, 724.0))["effect"],
        Value::Null
    );
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(ipc_mode(&mut h, 1), "Normal");
    // The same for two absolute resizes that net to the size it has.
    let mut h = fitted();
    let first = ipc(&mut h, json!({"Resize":{"to":[1000,724]}}));
    assert_eq!(mode(&mut h, 1), "fit");
    let second = ipc(&mut h, json!({"Resize":{"to":[944,724]}}));
    assert!(second.get("effect").is_none(), "{second}");
    assert_eq!(mode(&mut h, 1), Value::Null);
    let read = began(&mut h, &first);
    assert_eq!(
        answer(&mut h, &read, "observed", false, (944.0, 724.0))["effect"],
        Value::Null
    );
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
}

// What cannot share the transaction is refused by name, and changes nothing:
// a step on other edges, a fit, a fill, an absolute resize, a drag of it.
#[test]
fn anything_else_while_a_size_is_owed_is_refused_not_queued() {
    let mut h = capable(one(CONFIG));
    attach(&mut h, 2, (2000.0, 1000.0, 200.0, 100.0));
    // Snapped to window 1's left edge, one gap away.
    attach(&mut h, 3, (-62.0, 100.0, 150.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    let first = action(&mut h, "grow-window right");
    for sample in [
        "grow-window up",
        "grow-window left",
        "shrink-window down-right",
        "fit-window",
        "fit-window-snapped",
        "fill-window",
    ] {
        assert_eq!(
            h.error(json!({"op":"action","output":1,"action":sample})),
            BUSY,
            "{sample}"
        );
    }
    let before = h.snapshot();
    for request in [
        json!({"Resize":{"to":[500,400]}}),
        json!({"Resize":{"window":2,"to":[500,400]}}),
        json!({"Action":"fit-window"}),
    ] {
        assert_eq!(ipc(&mut h, request)["reply"], json!({"Err":BUSY}));
    }
    assert_eq!(h.snapshot(), before);
    // Another window's step waits too: there is one transaction.
    h.ok(json!({"op":"focus","window":2}));
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"grow-window right"})),
        BUSY
    );
    h.ok(json!({"op":"focus","window":1}));
    // The interactive commands keep their own guard.
    assert_eq!(
        h.error(json!({"op":"begin_native_resize","window":1,"output":1,"edges":"right","start_screen":{"x":0.0,"y":0.0}})),
        "resize must drain before structural change; cancel and reconcile pending effects"
    );
    // The result will place window 1, so no drag takes it meanwhile, alone or
    // carried along with its cluster. Its neighbour dragged alone is free.
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":1,"output":1})),
        BUSY
    );
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":3,"output":1,"group":true})),
        BUSY
    );
    h.ok(json!({"op":"begin_drag","window":3,"output":1}));
    h.ok(json!({"op":"end_gesture"}));
    deliver(
        &mut h,
        &first,
        (400.0, 300.0),
        (430.0, 300.0),
        "applied",
        (430.0, 300.0),
    );

    // A second absolute resize replaces the first while it is owed: the place
    // is measured from the size already asked for. 400 -> 600 puts the left
    // edge at 0; 600 -> 500 then at 0 + 50.
    let mut h = capable(one(CONFIG));
    let first = ipc(&mut h, json!({"Resize":{"to":[600,300]}}));
    let second = ipc(&mut h, json!({"Resize":{"to":[500,300]}}));
    assert_eq!(
        second["reply"],
        json!({"Ok":{"Size":{"width":500,"height":300}}})
    );
    assert!(second.get("effect").is_none(), "{second}");
    deliver(
        &mut h,
        &first,
        (400.0, 300.0),
        (500.0, 300.0),
        "applied",
        (500.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(50.0, 100.0, 500.0, 300.0));

    // A cancel after the setter was sent cannot take the size back: its
    // result still applies the plan, and the transaction ends cancelled.
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "fit-window");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    h.ok(json!({"op":"cancel_native_resize","transaction":read["transaction"]}));
    let last = answer(&mut h, &setter, "applied", true, (944.0, 724.0))["effect"].clone();
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fit");
    answer(&mut h, &last, "observed", false, (944.0, 724.0));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "failed");
    assert_eq!(mode(&mut h, 1), "fit");

    // A cancel before the setter was sent drops the request whole.
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "fit-window");
    let read = began(&mut h, &reply);
    let cancelled = h.ok(json!({"op":"cancel_native_resize","transaction":read["transaction"]}));
    assert_eq!(cancelled["effect"], Value::Null);
    assert_eq!(
        answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"],
        Value::Null
    );
    assert_eq!(h.snapshot()["native_resize"]["phase"], "failed");
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    let reply = action(&mut h, "grow-window right");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (430.0, 300.0),
        "applied",
        (430.0, 300.0),
    );
}

// A drag or a resize gesture places its windows itself at every motion and
// holds the camera, so no sizing action runs under one.
#[test]
fn a_sizing_action_during_a_drag_is_refused() {
    let mut h = capable(one(CONFIG));
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    for sample in [
        "grow-window right",
        "shrink-window left",
        "fit-window",
        "fit-window-snapped",
        "fill-window",
    ] {
        assert_eq!(
            h.error(json!({"op":"action","output":1,"action":sample})),
            GRABBED,
            "{sample}"
        );
    }
    h.ok(json!({"op":"end_gesture"}));
    let reply = action(&mut h, "grow-window right");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (430.0, 300.0),
        "applied",
        (430.0, 300.0),
    );
}

// Every path an action can arrive by carries the transaction the same way.
#[test]
fn a_gesture_a_hot_corner_and_ipc_carry_the_resize_effect() {
    // A trackpad pinch bound to fit-window (upstream's alt+2-finger-pinch-in).
    let mut h = capable(one(CONFIG));
    let begun = h.ok(json!({"op":"gesture_begin","kind":"pinch","fingers":2,"modifiers":{"control":false,"option":true,"shift":false,"command":false},"context":"window","output":1,"pointer":{"x":ORIGIN.0+300.0,"y":ORIGIN.1+250.0},"doubletap":false,"time_ms":1000}));
    assert_eq!(begun["gesture"]["bindings"][0]["action"], "fit-window");
    assert_eq!(begun["gesture"]["bindings"][0]["implemented"], true);
    let fired = h.ok(json!({"op":"gesture_update","scale":0.8,"time_ms":1010}));
    assert_eq!(fired["fired"], json!({"action":"fit-window","error":null}));
    assert_eq!(
        fired["navigation"]["target_camera"],
        json!({"x":-200.0,"y":-160.0})
    );
    h.ok(json!({"op":"gesture_end","time_ms":1020}));
    deliver(
        &mut h,
        &fired,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(mode(&mut h, 1), "fit");

    // A hot corner bound to fit-window.
    let mut h = capable(one(CONFIG));
    let reply = h.ok(json!({"op":"hot_corner","output":1,"corner":"top_left"}));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));

    // An IPC action request.
    let mut h = capable(one(CONFIG));
    let reply = ipc(&mut h, json!({"Action":"grow-window down"}));
    assert_eq!(reply["reply"], json!({"Ok":"Ok"}));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (400.0, 330.0),
        "applied",
        (400.0, 330.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 330.0));

    // The key and mouse tables say the actions run now.
    let keys = h.ok(json!({"op":"bindings"}))["keys"].clone();
    for name in ["fit-window", "fit-window-snapped", "fill-window"] {
        let key = keys
            .as_array()
            .unwrap()
            .iter()
            .find(|k| k["action"] == name);
        assert_eq!(key.unwrap()["implemented"], true, "{name}");
    }
    let mouse = h.ok(json!({"op":"mouse_binding","trigger":"middle","modifiers":{"control":false,"option":true,"shift":false,"command":false},"context":"window"}));
    assert_eq!(mouse["binding"]["action"], "fit-window");
    assert_eq!(mouse["binding"]["implemented"], true);
    // toggle-fullscreen is delivered through the same gate, so it is
    // implemented under it too: tests/fullscreen_flow.rs.
    let keys = h.ok(json!({"op":"bindings"}))["keys"].clone();
    let fullscreen = keys.as_array().unwrap().iter();
    let fullscreen: Vec<&Value> = fullscreen
        .filter(|k| k["action"] == "toggle-fullscreen")
        .collect();
    assert!(!fullscreen.is_empty());
    assert!(fullscreen.iter().all(|k| k["implemented"] == true));
}

// The transaction's own uncertainty rules hold for a sizing action. A setter
// that timed out unobserved is followed by one read; what that read finds is
// committed and placed, and the fit is recorded, because the window did take
// the size. The transaction stays unresolved, so nothing more is delivered.
#[test]
fn an_unresolved_setter_keeps_the_transactions_uncertainty() {
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "fit-window");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    let timed_out = json!({"op":"native_resize_result","transaction":setter["transaction"],"effect_id":setter["effect_id"],"identity":setter["identity"],"generation":setter["generation"],"result":{"outcome":"timed_out","ax_error":0,"mutation_attempted":true,"observed":false,"requested":setter["requested"],"actual_ax":rect(0.0,0.0,1.0,1.0),"actual_cg":rect(0.0,0.0,1.0,1.0)}});
    let diagnostic = h.ok(timed_out)["effect"].clone();
    assert_eq!(diagnostic["op"], "observe_resize_source");
    assert_eq!(mode(&mut h, 1), Value::Null);
    answer(&mut h, &diagnostic, "observed", false, (944.0, 724.0));
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fit");
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["phase"], "needs_observation");
    assert_eq!(slot["uncertain_mutation"], true);
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"fit-window"})),
        BUSY
    );

    // A window the adapter will not resize: nothing is written, and the
    // source is marked as the transaction marks it.
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "fit-window");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    let last = answer(&mut h, &setter, "unsupported", false, (400.0, 300.0))["effect"].clone();
    answer(&mut h, &last, "observed", false, (400.0, 300.0));
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert_eq!(window(&mut h, 1)["source"]["resize_disabled"], true);
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"grow-window right"})),
        "source resize unsupported"
    );
}

// The capability belongs to the run and the restore points to the session:
// neither is saved, and a loaded scene keeps the capability the shell reported.
#[test]
fn the_capability_survives_a_load_and_nothing_of_it_is_saved() {
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(mode(&mut h, 1), "fit");
    let path = h._scratch.0.join("scene.json");
    h.ok(json!({"op":"save","path":path}));
    let saved = std::fs::read_to_string(&path).unwrap();
    for word in ["capability", "mode", "fit", "restore"] {
        assert!(!saved.contains(word), "{word}: {saved}");
    }
    h.ok(json!({"op":"load","path":path}));
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":rect(ORIGIN.0,ORIGIN.1,1000.0,800.0)}));
    // The frame is the committed one; the fit is gone with the session.
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    h.ok(json!({"op":"attach","identity":identity(1),"bundle_id":"app.1","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,944.0,724.0),"logical_id":1}));
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "shrink-window right");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (914.0, 724.0),
        "applied",
        (914.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 914.0, 724.0));
}

// Sizing beside window rules, widgets, screen pins and pointer policy. A window
// of `app.widget` is a widget by its rule; a window is pinned by an IPC `Pin`.
const WIDGET_RULE: &str = "[[window_rules]]\napp_id = \"app.widget\"\nwidget = true\n";
const NO_CANVAS_SIZE: &str = "this window has no canvas size to set: it is pinned, fullscreen, a widget, or not on screen yet";
const NOT_A_WIDGET: &str = "a widget is not moved or resized by hand";
fn layered() -> String {
    format!("{CONFIG}{WIDGET_RULE}")
}
/// The next window, a widget by its rule, at a world frame. Its logical id.
fn widget(h: &mut Host, frame: (f64, f64, f64, f64)) -> u64 {
    let next = h.snapshot()["windows"].as_array().unwrap().len() as u64 + 1;
    let reply = h.ok(json!({"op":"attach","identity":identity(next),"bundle_id":"app.widget","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,frame.2,frame.3),"world_rect":rect(frame.0,frame.1,frame.2,frame.3)}));
    assert_eq!(reply, json!({"window":next}));
    assert_eq!(window(h, next)["widget"], true);
    next
}
fn pin(h: &mut Host, id: u64) {
    assert_eq!(
        ipc(h, json!({"Pin":{"window":id,"value":true}})),
        json!({"reply":{"Ok":{"Pin":true}},"effects":[],"dirty":true,"navigation":null})
    );
    assert!(window(h, id)["pinned"].is_object());
}

// Upstream filters `is_canvas_window` in every sizing arm (GrowWindow and
// ShrinkWindow in step_resize_focused, FitWindow, FitWindowSnapped, FillWindow
// and ZoomToFitSnapped in execute_action): with a widget or a screen-pinned
// window focused nothing happens and nothing is an error. cmd_resize refuses
// them in its own words, before it looks at a grab or at the size it holds.
#[test]
fn every_sizing_action_passes_over_a_widget_and_a_screen_pinned_window() {
    let mut h = capable(one(&layered()));
    let widget = widget(&mut h, (1200.0, 100.0, 300.0, 200.0));
    attach(&mut h, 3, (1200.0, 400.0, 300.0, 200.0));
    pin(&mut h, 3);
    for id in [widget, 3] {
        h.ok(json!({"op":"focus","window":id}));
        let before = h.snapshot();
        assert_eq!(before["focused"], id);
        for sample in [
            "grow-window right",
            "shrink-window up-left",
            "fit-window",
            "fit-window-snapped",
            "fill-window",
            "zoom-to-fit-snapped",
        ] {
            assert_eq!(action(&mut h, sample), nothing(), "{sample} on {id}");
            assert_eq!(
                ipc(&mut h, json!({"Action":sample})),
                json!({"reply":{"Ok":"Ok"},"effects":[],"dirty":false,"navigation":null}),
                "{sample} on {id}"
            );
        }
        // The hot corner bound to fit-window.
        assert_eq!(
            h.ok(json!({"op":"hot_corner","output":1,"corner":"top_left"})),
            nothing()
        );
        for request in [
            json!({"Resize":{"to":[800,600]}}),
            json!({"Resize":{"window":id,"to":[800,600]}}),
        ] {
            assert_eq!(
                ipc(&mut h, request),
                json!({"reply":{"Err":NO_CANVAS_SIZE},"effects":[],"dirty":false,"navigation":null})
            );
        }
        assert_eq!(
            ipc(&mut h, json!({"Resize":{"to":[0,600]}}))["reply"],
            json!({"Err":"size must be positive"})
        );
        assert_eq!(
            ipc(&mut h, json!({"Resize":{}}))["reply"],
            json!({"Ok":{"Size":{"width":300,"height":200}}})
        );
        assert_eq!(h.snapshot(), before, "window {id}");
        assert_eq!(before["native_resize"], Value::Null);
        assert_eq!(mode(&mut h, id), Value::Null);
    }
    // The canvas window beside them is sized as ever.
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "grow-window right");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (430.0, 300.0),
        "applied",
        (430.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 430.0, 300.0));
}

// Upstream pin_window clears neither fit nor fill: the stage keeps the restore
// point of a window that is pinned afterwards. Pinned, it is passed over and
// listed under `State.pinned`, which carries no mode; unpinned, where the pin
// showed it, the fit is still there to undo. After the fit the camera is at
// (-200, -160), so the pin holds the frame's top-left at the screen point
// (28, 48) and the unpin returns it to (-172, -112).
#[test]
fn a_pin_keeps_a_fit_and_the_unpin_gives_it_back() {
    let mut h = capable(one(CONFIG));
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    settle(&mut h);
    pin(&mut h, 1);
    assert_eq!(mode(&mut h, 1), "fit");
    let state = ipc(&mut h, json!("State"))["reply"]["Ok"]["State"].clone();
    assert_eq!(state["windows"], json!([]));
    assert_eq!(state["pinned"][0]["id"], 1);
    assert_eq!(state["pinned"][0]["size"], json!([944, 724]));
    assert_eq!(action(&mut h, "fit-window"), nothing());
    assert_eq!(action(&mut h, "fill-window"), nothing());
    assert_eq!(
        ipc(&mut h, json!({"Resize":{"to":[400,300]}}))["reply"],
        json!({"Err":NO_CANVAS_SIZE})
    );
    assert_eq!(
        ipc(&mut h, json!({"Pin":{"value":false}}))["reply"],
        json!({"Ok":{"Pin":false}})
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fit");
    assert_eq!(ipc_mode(&mut h, 1), "Fit");
    let reply = action(&mut h, "fit-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
}

// Upstream's snap rectangles leave out widgets and screen-pinned windows
// (snap_rect_for), so neither is an obstacle to a fill, a neighbour a snapped
// fit shoves, or a member of the cluster zoom-to-fit-snapped frames.
#[test]
fn a_fill_a_shove_and_a_snapped_zoom_see_only_the_windows_that_snap() {
    // The fill of `fill_window_grows_into_the_free_space_and_toggles_back`,
    // with a widget where its neighbour stood and a pinned window inside the
    // area: the whole inset usable area is free, (28, 48) 944 x 724.
    let mut h = capable(empty(&layered()));
    attach(&mut h, 1, (400.0, 300.0, 300.0, 200.0));
    let beside = widget(&mut h, (28.0, 48.0, 200.0, 724.0));
    attach(&mut h, 3, (800.0, 48.0, 150.0, 724.0));
    pin(&mut h, 3);
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(28.0, 48.0, 944.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fill");
    assert_eq!(world(&mut h, beside), rect(28.0, 48.0, 200.0, 724.0));

    // The snapped fit of `fit_window_snapped_shoves_...`: window 3 below
    // follows the bottom edge down 212; the widget one gap to the right and
    // the pinned window one gap to the left stay where they are.
    let mut h = capable(one(&layered()));
    let beside = widget(&mut h, (512.0, 100.0, 200.0, 300.0));
    attach(&mut h, 3, (100.0, 412.0, 400.0, 200.0));
    attach(&mut h, 4, (-62.0, 100.0, 150.0, 300.0));
    pin(&mut h, 4);
    let pinned = window(&mut h, 4)["pinned"].clone();
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "fit-window-snapped");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
    assert_eq!(world(&mut h, 3), rect(100.0, 624.0, 400.0, 200.0));
    assert_eq!(world(&mut h, beside), rect(512.0, 100.0, 200.0, 300.0));
    assert_eq!(window(&mut h, 4)["pinned"], pinned);

    // The cluster of `zoom_to_fit_snapped_moves_only_the_camera_...`, windows
    // 1 and 2, with a widget one gap right of 2 and a pinned window one gap
    // below 1. Neither widens the box: x 100..1712, y 100..400 as before.
    let mut h = one(&layered());
    attach(&mut h, 2, (512.0, 100.0, 1200.0, 300.0));
    widget(&mut h, (1724.0, 100.0, 600.0, 300.0));
    attach(&mut h, 4, (100.0, 412.0, 400.0, 900.0));
    pin(&mut h, 4);
    h.ok(json!({"op":"focus","window":1}));
    let fit = 800.0 / 1612.0;
    let reply = action(&mut h, "zoom-to-fit-snapped");
    assert_eq!(
        reply["navigation"]["target_camera"],
        json!({"x":906.0 - 500.0 / fit,"y":250.0 - 410.0 / fit})
    );
    assert_eq!(reply["navigation"]["target_zoom"], fit);
}

// install_drag holds four rules in one place, each with its own behaviour: a
// widget is not dragged; a screen-pinned window is, in screen space and so by
// the pointer's own displacement whatever the zoom; a window whose sizing
// action is still owed its size is placed by that action's plan, and no drag
// of it is installed; and below `zoom.interact_min` the same install serves a
// pick-mode press, under the same rules. The plan's guard stands ahead of the
// pinned drag as of any other. A sizing action's window never meets it
// pinned: a pin waits for the transaction. The one pinned window that owes a
// size is the one a rule pinned and sized as it mapped, and its drag is
// refused the same way (tests/rules_flow.rs).
#[test]
fn a_drag_is_refused_for_a_widget_and_for_a_pending_plan_in_pick_mode_too() {
    let config = format!("{}[zoom]\ninteract_min = 0.5\n", layered());
    let mut h = capable(one(&config));
    attach(&mut h, 2, (512.0, 100.0, 200.0, 300.0));
    let widget = widget(&mut h, (1200.0, 100.0, 300.0, 200.0));
    attach(&mut h, 4, (1200.0, 400.0, 300.0, 200.0));
    pin(&mut h, 4);
    h.ok(json!({"op":"focus","window":1}));
    let drag =
        |id: u64, group: bool| json!({"op":"begin_drag","window":id,"output":1,"group":group});
    for pick in [false, true] {
        if pick {
            h.ok(json!({"op":"zoom","output":1,"zoom":0.4,"anchor":{"x":ORIGIN.0,"y":ORIGIN.1}}));
        }
        assert_eq!(h.snapshot()["outputs"][0]["pick"], pick);
        assert_eq!(h.error(drag(widget, false)), NOT_A_WIDGET);
        pinned_drag(&mut h, false);
        // The press that dragged the pinned window raised and focused it, as
        // upstream's does. Window 1 takes the focus back for its step.
        assert_eq!(h.snapshot()["focused"], 4);
        h.ok(json!({"op":"focus","window":1}));
        // A sizing plan still owed its size: the window, and the cluster
        // drag that would carry it along, are refused in the plan's words.
        let size = world(&mut h, 1)["size"].clone();
        let from = (
            size["width"].as_f64().unwrap(),
            size["height"].as_f64().unwrap(),
        );
        let reply = action(&mut h, "grow-window down");
        assert_eq!(h.error(drag(1, false)), BUSY);
        assert_eq!(h.error(drag(2, true)), BUSY);
        assert_eq!(h.error(drag(widget, false)), NOT_A_WIDGET);
        // The pinned window is not the plan's, alone or as a cluster drag: it
        // has no cluster. And the plan's own window cannot become a pinned one
        // while its size is owed.
        pinned_drag(&mut h, true);
        assert_eq!(
            ipc(&mut h, json!({"Pin":{"window":1,"value":true}}))["reply"],
            json!({"Err":DRAINING})
        );
        assert_eq!(window(&mut h, 1)["pinned"], Value::Null);
        // The neighbour alone is not the plan's to place.
        h.ok(drag(2, false));
        h.ok(json!({"op":"end_gesture"}));
        let to = (from.0, from.1 + 30.0);
        deliver(&mut h, &reply, from, to, "applied", to);
        // With the size delivered the window drags again.
        h.ok(drag(1, false));
        h.ok(json!({"op":"end_gesture"}));
    }
}

const DRAINING: &str =
    "resize must drain before structural change; cancel and reconcile pending effects";
/// Window 4, pinned, dragged by (12, -8) screen points and back: its pin
/// moves by exactly that, at any zoom.
fn pinned_drag(h: &mut Host, group: bool) {
    let rect_of = |h: &mut Host| window(h, 4)["pinned"]["screen_rect"].clone();
    let before = rect_of(h);
    let (x, y) = (
        before["origin"]["x"].as_f64().unwrap(),
        before["origin"]["y"].as_f64().unwrap(),
    );
    h.ok(json!({"op":"begin_drag","window":4,"output":1,"group":group}));
    h.ok(json!({"op":"gesture_to","screen_delta":{"x":12.0,"y":-8.0}}));
    let moved = rect_of(h);
    assert_eq!(
        moved["origin"],
        json!({"x":x + 12.0,"y":y - 8.0}),
        "{moved}"
    );
    assert_eq!(moved["size"], before["size"]);
    h.ok(json!({"op":"gesture_to","screen_delta":{"x":0.0,"y":0.0}}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(rect_of(h), before);
}

// Pointer policy's grab guard reads the resize slot, whoever filled it: while a
// sizing action's transaction is unresolved no motion is forwarded and hover
// focus stays where it is, as during a resize the pointer began. Window 1
// covers the screen point (600, 450) and window 2 the point (1000, 450).
#[test]
fn a_size_still_owed_holds_the_pointer_as_a_resize_drag_does() {
    let config = format!("focus_follows_mouse = true\n{CONFIG}");
    let mut h = capable(one(&config));
    attach(&mut h, 2, (600.0, 100.0, 300.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    let hover = |h: &mut Host, x: f64| {
        h.ok(json!({"op":"hover","output":1,"screen":{"x":ORIGIN.0 + x,"y":ORIGIN.1 + 250.0}}))
    };
    let over = hover(&mut h, 300.0);
    assert_eq!(over["forward"], true, "{over}");
    assert_eq!(over["hit"]["window"], 1);
    let reply = action(&mut h, "grow-window down");
    let held = hover(&mut h, 300.0);
    assert_eq!(held["forward"], false, "{held}");
    // Over the other window: no focus moves, nothing is asked.
    let held = hover(&mut h, 700.0);
    assert_eq!(held["forward"], false, "{held}");
    assert_eq!(held["dirty"], false);
    assert!(held.get("effect").is_none(), "{held}");
    assert_eq!(h.snapshot()["focused"], 1);
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (400.0, 330.0),
        "applied",
        (400.0, 330.0),
    );
    let free = hover(&mut h, 700.0);
    assert_eq!(free["forward"], true, "{free}");
    assert_eq!(free["dirty"], true);
    assert_eq!(free["effect"]["window"], 2);
    assert_eq!(h.snapshot()["focused"], 2);
}

// Upstream resolve_pick: a pick is `center-window`'s navigation, and a window
// still filled returns to its fill view instead, provided that view is itself
// at or above `zoom.interact_min`: one that left the output in pick mode would
// make the pick a mode. The first fill runs at zoom 1 with the camera at the
// origin; the second at zoom 0.4, where the usable area covers the canvas from
// (50, 100) to (2450, 1950) and the fill takes all of it less the gap.
#[test]
fn a_pick_returns_a_filled_window_to_a_fill_view_above_the_threshold() {
    let config = format!("{CONFIG}[zoom]\ninteract_min = 0.5\n");
    let zoom_out = |h: &mut Host| {
        h.ok(json!({"op":"zoom","output":1,"zoom":0.4,"anchor":{"x":ORIGIN.0,"y":ORIGIN.1}}));
    };
    let mut h = capable(empty(&config));
    attach(&mut h, 1, (400.0, 300.0, 300.0, 200.0));
    attach(&mut h, 2, (28.0, 48.0, 200.0, 724.0));
    h.ok(json!({"op":"focus","window":1}));
    let view = pose(&mut h);
    assert_eq!(view, json!({"camera":{"x":0.0,"y":0.0},"zoom":1.0}));
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (732.0, 724.0),
        "applied",
        (732.0, 724.0),
    );
    assert_eq!(mode(&mut h, 1), "fill");
    zoom_out(&mut h);
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":150.0,"y":60.0}}));
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    // `focus_placement = "left"` at zoom 1 would park the camera at x = 212.
    let picked = h.ok(json!({"op":"pick","window":1,"output":1}));
    assert_eq!(picked["navigation"]["target_camera"], view["camera"]);
    assert_eq!(picked["navigation"]["target_zoom"], 1.0);
    assert_eq!(picked["effect"]["window"], 1);
    settle(&mut h);
    assert_eq!(pose(&mut h), view);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
    // A window that is not filled is centered as before: the left placement.
    zoom_out(&mut h);
    let picked = h.ok(json!({"op":"pick","window":2,"output":1}));
    assert_eq!(picked["navigation"]["target_zoom"], 1.0);
    assert_eq!(
        picked["navigation"]["target_camera"]["x"],
        28.0 + 100.0 - 128.0
    );

    // A fill that ran below the threshold. center-window still restores it;
    // a pick does not, and lands at zoom 1.
    let mut h = capable(empty(&config));
    attach(&mut h, 1, (400.0, 300.0, 300.0, 200.0));
    h.ok(json!({"op":"focus","window":1}));
    zoom_out(&mut h);
    let low = pose(&mut h);
    assert_eq!(low, json!({"camera":{"x":0.0,"y":0.0},"zoom":0.4}));
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (2384.0, 1834.0),
        "applied",
        (2384.0, 1834.0),
    );
    assert_eq!(world(&mut h, 1), rect(58.0, 108.0, 2384.0, 1834.0));
    assert_eq!(mode(&mut h, 1), "fill");
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":150.0,"y":60.0}}));
    let centered = action(&mut h, "center-window");
    assert_eq!(centered["navigation"]["target_camera"], low["camera"]);
    assert_eq!(centered["navigation"]["target_zoom"], 0.4);
    settle(&mut h);
    assert_eq!(pose(&mut h), low);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    let picked = h.ok(json!({"op":"pick","window":1,"output":1}));
    assert_eq!(picked["navigation"]["target_zoom"], 1.0);
    settle(&mut h);
    assert_eq!(pose(&mut h)["zoom"], 1.0);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
    // Still filled: the pick moved a camera, not the window.
    assert_eq!(mode(&mut h, 1), "fill");
}

// center-window and focus-center take canvas windows only, and return a filled
// one to its fill view. The fill is the one of
// `fill_window_grows_into_the_free_space_and_toggles_back`, (240, 48)
// 732 x 724 in the view at the origin, where `focus_placement = "left"` at
// zoom 1 would park the camera at x = 212 instead. With the pinned window
// focused, center-window goes to the canvas window nearest the viewport
// center, which is the filled one; focus-center passes over the pinned window
// lying on the filled one under the pointer.
#[test]
fn centering_restores_a_fill_view_past_a_pinned_window() {
    let mut h = capable(empty(CONFIG));
    attach(&mut h, 1, (400.0, 300.0, 300.0, 200.0));
    attach(&mut h, 2, (500.0, 300.0, 200.0, 100.0));
    pin(&mut h, 2);
    attach(&mut h, 3, (28.0, 48.0, 200.0, 724.0));
    h.ok(json!({"op":"focus","window":1}));
    let view = pose(&mut h);
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (732.0, 724.0),
        "applied",
        (732.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), rect(240.0, 48.0, 732.0, 724.0));
    assert_eq!(mode(&mut h, 1), "fill");
    for sample in ["center-window", "focus-center"] {
        action(&mut h, "pan-viewport right");
        settle(&mut h);
        assert_eq!(pose(&mut h)["camera"], json!({"x":100.0,"y":0.0}));
        h.ok(json!({"op":"focus","window":2}));
        // The pointer is on the pinned window, which stays at the screen
        // point (500, 300), and on the filled window beneath it.
        let moved = h.ok(json!({"op":"action","output":1,"action":sample,"pointer":{"x":ORIGIN.0 + 600.0,"y":ORIGIN.1 + 350.0}}));
        assert_eq!(
            moved["navigation"]["target_camera"], view["camera"],
            "{sample}"
        );
        assert_eq!(moved["navigation"]["target_zoom"], 1.0, "{sample}");
        assert_eq!(moved["effects"][0]["window"], 1, "{sample}: {moved}");
        settle(&mut h);
        assert_eq!(pose(&mut h), view, "{sample}");
        assert_eq!(h.snapshot()["focused"], 1);
    }
}

// Upstream SendToOutput: the canvas leg re-anchors the window and ends its
// fill restore point; the pinned leg only binds the pin to the other output
// (tests/rules_flow.rs covers where it lands) and clears nothing.
#[test]
fn send_to_output_ends_a_fill_and_leaves_a_pinned_windows_restore_point() {
    let mut h = capable(empty(CONFIG));
    h.ok(json!({"op":"register_output","stable_id":"view-b","screen_bounds":rect(ORIGIN.0 + 1000.0,ORIGIN.1,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":2,"usable_rect_local":rect(0.0,0.0,1000.0,800.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
    h.ok(json!({"op":"pan","output":2,"screen_delta":{"x":-5000.0,"y":0.0}}));
    let filled = |h: &mut Host| {
        attach(h, 1, (400.0, 300.0, 300.0, 200.0));
        h.ok(json!({"op":"focus","window":1}));
        let reply = action(h, "fill-window");
        deliver(
            h,
            &reply,
            (300.0, 200.0),
            (944.0, 724.0),
            "applied",
            (944.0, 724.0),
        );
        assert_eq!(mode(h, 1), "fill");
    };
    filled(&mut h);
    pin(&mut h, 1);
    assert_eq!(action(&mut h, "send-to-output right")["dirty"], true);
    assert_eq!(window(&mut h, 1)["pinned"]["output"], 2);
    assert_eq!(mode(&mut h, 1), "fill");
    assert_eq!(
        ipc(&mut h, json!({"Pin":{"value":false}}))["reply"],
        json!({"Ok":{"Pin":false}})
    );
    // Back on the canvas, and sent as a canvas window: the fill is over.
    assert_eq!(mode(&mut h, 1), "fill");
    assert_eq!(action(&mut h, "send-to-output left")["dirty"], true);
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert_eq!(ipc_mode(&mut h, 1), "Normal");
}

// Upstream apply_member_shifts ends the fill of a member a resize shifts. A
// filled window pinned since is no member of anything: its canvas frame
// follows its pin as the camera moves, and a resize drag of another window
// leaves its restore point alone.
#[test]
fn a_resize_drag_elsewhere_leaves_a_pinned_windows_fill() {
    let mut h = capable(empty(CONFIG));
    attach(&mut h, 1, (400.0, 300.0, 300.0, 200.0));
    attach(&mut h, 2, (3000.0, 3000.0, 300.0, 200.0));
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, "fill-window");
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    pin(&mut h, 1);
    action(&mut h, "pan-viewport right");
    settle(&mut h);
    // The pin holds the screen point (28, 48); the camera is at (100, 0).
    assert_eq!(world(&mut h, 1), rect(128.0, 48.0, 944.0, 724.0));
    h.ok(json!({"op":"begin_resize","window":2,"output":1,"edges":"right"}));
    h.ok(json!({"op":"gesture_to","screen_delta":{"x":40.0,"y":0.0}}));
    assert_eq!(world(&mut h, 2), rect(3000.0, 3000.0, 340.0, 200.0));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(mode(&mut h, 1), "fill");
}

// Readback mode: what every normal run without the flag reports. A size is
// settled by the native read alone, so no command may leave a bound window
// without a picture revision or refuse a press on it (NATIVE_RESIZE.md).
fn readback(mut h: Host) -> Host {
    assert_eq!(
        h.ok(json!({"op":"native_resize_capability","enabled":true,"readback":true})),
        json!({})
    );
    h
}
/// The readback invariant, read from the snapshot, and a press on every
/// placed window answered rather than refused.
fn usable(h: &mut Host) {
    let snapshot = h.snapshot();
    for w in snapshot["windows"].as_array().unwrap() {
        let source = &w["source"];
        if source.is_null() {
            continue;
        }
        assert_eq!(source["observation_known"], true, "{w}");
        assert_eq!(
            source["capture_revision"], source["observation_revision"],
            "{w}"
        );
    }
    for p in snapshot["placements"].as_array().unwrap() {
        assert_eq!(p["presentation_settled"], true, "{p}");
        assert!(p["buffer_crop"].is_object(), "{p}");
        let clip = &p["clip_rect"];
        let at = json!({"x":clip["origin"]["x"].as_f64().unwrap()+clip["size"]["width"].as_f64().unwrap()/2.0,"y":clip["origin"]["y"].as_f64().unwrap()+clip["size"]["height"].as_f64().unwrap()/2.0});
        let hit = h.ok(json!({"op":"hit","output":p["output"],"screen":at}));
        assert!(hit["hit"].is_object(), "{hit}");
    }
}
/// `deliver`, with the invariant checked after every command of it.
fn served(
    h: &mut Host,
    reply: &Value,
    from: (f64, f64),
    asks: (f64, f64),
    outcome: &str,
    took: (f64, f64),
) {
    usable(h);
    let read = began(h, reply);
    let setter = answer(h, &read, "observed", false, from)["effect"].clone();
    usable(h);
    assert_eq!(setter["requested"], json!({"width":asks.0,"height":asks.1}));
    let last = answer(h, &setter, outcome, true, took)["effect"].clone();
    usable(h);
    assert_eq!(last["op"], "observe_resize_source", "{last}");
    assert_eq!(
        answer(h, &last, "observed", false, took)["effect"],
        Value::Null
    );
    usable(h);
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["phase"], "complete", "{slot}");
    assert_eq!(world(h, 1)["size"], json!({"width":took.0,"height":took.1}));
}
/// A setter result with no observation behind it, as the adapter's deadline
/// or the shell's watchdog reports one.
fn timed_out(h: &mut Host, effect: &Value) -> Value {
    let none = rect(0.0, 0.0, 0.0, 0.0);
    let attempted = !effect["requested"].is_null();
    let requested = if attempted {
        effect["requested"].clone()
    } else {
        json!({"width":0.0,"height":0.0})
    };
    h.ok(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":"timed_out","ax_error":-25204,"mutation_attempted":attempted,"observed":false,"requested":requested,"actual_ax":none,"actual_cg":none}}))
}
#[test]
fn readback_keeps_every_window_usable_through_applied_clamped_and_rejected() {
    let mut h = readback(one(CONFIG));
    usable(&mut h);
    let reply = action(&mut h, "fit-window");
    served(
        &mut h,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(mode(&mut h, 1), "fit");
    // A step the window only partly grants: the canvas has the size it took.
    let reply = action(&mut h, "grow-window right");
    served(
        &mut h,
        &reply,
        (944.0, 724.0),
        (974.0, 724.0),
        "clamped",
        (960.0, 724.0),
    );
    // An absolute request the window ignores: it keeps the size it has.
    let reply = ipc(&mut h, json!({"Resize":{"window":1,"to":[500,400]}}));
    served(
        &mut h,
        &reply,
        (960.0, 724.0),
        (500.0, 400.0),
        "rejected",
        (960.0, 724.0),
    );
}
#[test]
fn readback_adopts_a_baseline_the_window_changed_by_itself() {
    let mut h = readback(one(CONFIG));
    let reply = action(&mut h, "grow-window right");
    let read = began(&mut h, &reply);
    // The window is 450 x 320 by now and no `observe` has said so: the size
    // it has is the baseline, its top-left kept, and the target is asked.
    let setter = answer(&mut h, &read, "observed", false, (450.0, 320.0));
    assert_eq!(setter["failure"], Value::Null, "{setter}");
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 450.0, 320.0));
    usable(&mut h);
    let setter = setter["effect"].clone();
    assert_eq!(setter["requested"], json!({"width":430.0,"height":300.0}));
    let last = answer(&mut h, &setter, "applied", true, (430.0, 300.0))["effect"].clone();
    answer(&mut h, &last, "observed", false, (430.0, 300.0));
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 430.0, 300.0));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    usable(&mut h);
    // The window already has the size a fit asks for: the transaction ends
    // without a setter, and the fit is written as for a window that had it.
    let reply = action(&mut h, "fit-window");
    let read = began(&mut h, &reply);
    assert_eq!(
        answer(&mut h, &read, "observed", false, (944.0, 724.0))["effect"],
        Value::Null
    );
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(
        world(&mut h, 1)["size"],
        json!({"width":944.0,"height":724.0})
    );
    assert_eq!(mode(&mut h, 1), "fit");
    usable(&mut h);
}
#[test]
fn readback_ends_a_timed_out_setter_with_its_one_diagnostic_read() {
    for observed in [true, false] {
        let mut h = readback(one(CONFIG));
        attach(&mut h, 2, (2000.0, 1000.0, 200.0, 100.0));
        h.ok(json!({"op":"focus","window":1}));
        let reply = action(&mut h, "fit-window");
        let read = began(&mut h, &reply);
        let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
        let diagnostic = timed_out(&mut h, &setter)["effect"].clone();
        assert_eq!(diagnostic["op"], "observe_resize_source");
        usable(&mut h);
        // While it is owed, another window's request is refused, not queued.
        h.ok(json!({"op":"focus","window":2}));
        assert_eq!(
            h.error(json!({"op":"action","output":1,"action":"grow-window right"})),
            BUSY
        );
        let end = if observed {
            answer(&mut h, &diagnostic, "observed", false, (944.0, 724.0))
        } else {
            timed_out(&mut h, &diagnostic)
        };
        assert_eq!(end["effect"], Value::Null);
        let slot = h.snapshot()["native_resize"].clone();
        assert_eq!(slot["uncertain_mutation"], false, "{slot}");
        assert_eq!(slot["pending_effect"], Value::Null);
        if observed {
            assert_eq!(slot["phase"], "complete", "{slot}");
            assert_eq!(world(&mut h, 1), rect(-172.0, -112.0, 944.0, 724.0));
            assert_eq!(mode(&mut h, 1), "fit");
        } else {
            assert_eq!(slot["phase"], "failed", "{slot}");
            assert_eq!(
                end["failure"],
                "the window did not answer the size request in time"
            );
            assert_eq!(
                world(&mut h, 1)["size"],
                json!({"width":400.0,"height":300.0})
            );
        }
        usable(&mut h);
        // The slot is free: the next request is accepted, and the structural
        // commands the transaction held back are too.
        let reply = action(&mut h, "grow-window right");
        deliver(
            &mut h,
            &reply,
            (200.0, 100.0),
            (230.0, 100.0),
            "applied",
            (230.0, 100.0),
        );
        h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    }
}
#[test]
fn readback_fails_an_unanswered_transaction_and_the_window_stays_usable() {
    let mut h = readback(one(CONFIG));
    let reply = action(&mut h, "fit-window");
    let read = began(&mut h, &reply);
    assert_eq!(timed_out(&mut h, &read)["effect"], Value::Null);
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["phase"], "failed", "{slot}");
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(mode(&mut h, 1), Value::Null);
    usable(&mut h);
    let reply = action(&mut h, "grow-window right");
    served(
        &mut h,
        &reply,
        (400.0, 300.0),
        (430.0, 300.0),
        "applied",
        (430.0, 300.0),
    );
}
#[test]
fn readback_asks_again_a_window_accessibility_said_is_not_settable() {
    for (ax_error, disabled) in [(0, true), (-25204, false)] {
        let mut h = readback(one(CONFIG));
        let reply = action(&mut h, "grow-window right");
        let read = began(&mut h, &reply);
        let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
        let frame = rect(4000.0, 3000.0, 400.0, 300.0);
        let last = h.ok(json!({"op":"native_resize_result","transaction":setter["transaction"],"effect_id":setter["effect_id"],"identity":setter["identity"],"generation":setter["generation"],"result":{"outcome":"unsupported","ax_error":ax_error,"mutation_attempted":false,"observed":true,"requested":setter["requested"],"actual_ax":frame,"actual_cg":frame}}))["effect"].clone();
        answer(&mut h, &last, "observed", false, (400.0, 300.0));
        assert_eq!(h.snapshot()["native_resize"]["phase"], "failed");
        assert_eq!(
            window(&mut h, 1)["source"]["resize_disabled"],
            disabled,
            "{ax_error}"
        );
        usable(&mut h);
        // Not settable then (a sheet was up) is no answer for now: the next
        // request is asked, and the size it is granted ends the record.
        let reply = action(&mut h, "grow-window right");
        served(
            &mut h,
            &reply,
            (400.0, 300.0),
            (430.0, 300.0),
            "applied",
            (430.0, 300.0),
        );
        assert_eq!(window(&mut h, 1)["source"]["resize_disabled"], false);
        assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 430.0, 300.0));
    }
}
// Upstream cmd_resize clamps the size to its client's limits, then keeps the
// center for the clamped size and records that as the request
// (src/ipc/mod.rs). The limits are learned here from what the window took.
#[test]
fn readback_keeps_the_center_for_the_size_an_absolute_request_was_granted() {
    let mut h = readback(one(CONFIG));
    // From 400 x 300 at (100, 100): 800 x 600 of 1000 x 600 is 200 to the
    // left and 150 up, where 1000 x 600 would have been 300 to the left.
    let reply = ipc(&mut h, json!({"Resize":{"to":[1000,600]}}));
    served(
        &mut h,
        &reply,
        (400.0, 300.0),
        (1000.0, 600.0),
        "clamped",
        (800.0, 600.0),
    );
    assert_eq!(world(&mut h, 1), rect(-100.0, -50.0, 800.0, 600.0));
    // The next request is measured from the 800 granted: (800 - 1200) / 2.
    let reply = ipc(&mut h, json!({"Resize":{"to":[1200,600]}}));
    served(
        &mut h,
        &reply,
        (800.0, 600.0),
        (1200.0, 600.0),
        "applied",
        (1200.0, 600.0),
    );
    assert_eq!(world(&mut h, 1), rect(-300.0, -50.0, 1200.0, 600.0));
    // Below a minimum, and a request the window ignores: the center stays.
    let reply = ipc(&mut h, json!({"Resize":{"to":[100,100]}}));
    served(
        &mut h,
        &reply,
        (1200.0, 600.0),
        (100.0, 100.0),
        "clamped",
        (300.0, 260.0),
    );
    assert_eq!(world(&mut h, 1), rect(150.0, 120.0, 300.0, 260.0));
    let reply = ipc(&mut h, json!({"Resize":{"to":[50,50]}}));
    served(
        &mut h,
        &reply,
        (300.0, 260.0),
        (50.0, 50.0),
        "rejected",
        (300.0, 260.0),
    );
    assert_eq!(world(&mut h, 1), rect(150.0, 120.0, 300.0, 260.0));
    // The size granted is the size on record: asked for again, it is nothing.
    let before = h.snapshot();
    let reply = ipc(&mut h, json!({"Resize":{"to":[300,260]}}));
    assert_eq!(reply["effects"], json!([]), "{reply}");
    assert_eq!(h.snapshot(), before);
}
#[test]
fn readback_sizes_a_window_by_its_rule() {
    let toml = format!("{CONFIG}[[window_rules]]\napp_id = \"app.sized\"\nsize = [480, 360]\n");
    let mut h = readback(empty(&toml));
    h.ok(json!({"op":"adoption_complete"}));
    let reply = h.ok(json!({"op":"attach","identity":identity(1),"bundle_id":"app.sized","title":"R","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,400.0,300.0),"output":1}));
    let read = reply["effects"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["op"] == "observe_resize_source")
        .unwrap_or_else(|| panic!("{reply}"))
        .clone();
    usable(&mut h);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    assert_eq!(setter["requested"], json!({"width":480.0,"height":360.0}));
    let last = answer(&mut h, &setter, "applied", true, (480.0, 360.0))["effect"].clone();
    usable(&mut h);
    answer(&mut h, &last, "observed", false, (480.0, 360.0));
    assert_eq!(
        world(&mut h, 1)["size"],
        json!({"width":480.0,"height":360.0})
    );
    usable(&mut h);
}
