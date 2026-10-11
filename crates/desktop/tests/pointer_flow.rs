// SPDX-License-Identifier: GPL-3.0-or-later
//! Pointer policy scenarios cross the exported C ABI and JSON decoder with
//! synthetic identities, focus results and observations: hover and sloppy
//! focus, pick mode below `zoom.interact_min`, and the pointer's
//! `center-nearest`. The scenarios are upstream's src/tests/hover_focus.rs and
//! src/tests/interact_min.rs where those make sense without Wayland surfaces,
//! and expected cameras are derived by hand from upstream's rules, not read
//! back from the controller. The last three are about the layers of
//! RULES.md: a screen-pinned window and a widget under the pointer, for hover
//! and for pick mode. Config files are written to a throwaway
//! directory; the default config path is never read. They provide no evidence
//! that the shell sees the pointer move, that a motion reaches an application,
//! that a focus effect focuses a native window, or that a native focus change
//! is observed.
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
    fn focus_state(&mut self) -> Value {
        self.snapshot()["focus"].clone()
    }
    fn history(&mut self) -> Value {
        self.focus_state()["history"].clone()
    }
    fn focused(&mut self) -> Value {
        self.snapshot()["focused"].clone()
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
    fn frame(&mut self, window: u64) -> Value {
        let windows = self.snapshot()["windows"].clone();
        let found = windows
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["window"] == window)
            .unwrap();
        found["world_rect"].clone()
    }
    /// A screen-pinned window's rectangle in global screen points.
    fn pin_rect(&mut self, window: u64) -> Value {
        let windows = self.snapshot()["windows"].clone();
        let found = windows
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["window"] == window)
            .unwrap();
        found["pinned"]["screen_rect"].clone()
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
        self.ok(answer(effect, "focus_result", Some(true)));
    }
    /// Answer `effect` as a shell that performs no native focus does.
    fn logical(&mut self, effect: &Value) {
        self.ok(answer(effect, "focus_logical", None));
    }
    /// Logical focus that the adapter confirms: raised, and in the history.
    fn focus(&mut self, window: u64) {
        let effect = self.ok(json!({"op":"focus","window":window}))["effect"].clone();
        self.confirm(&effect);
    }
    /// Put output 1's camera at a world point and its zoom at `zoom`. Zooming
    /// about the output's own corner leaves the camera where it is, and the pan
    /// is made at zoom 1, so the pose is exact.
    fn look(&mut self, x: f64, y: f64, zoom: f64) {
        let corner = point(ORIGIN.0, ORIGIN.1);
        self.ok(json!({"op":"cancel_navigation","output":1}));
        self.ok(json!({"op":"zoom","output":1,"zoom":1.0,"anchor":corner}));
        let camera = self.pose(1)["camera"].clone();
        let delta = point(
            x - camera["x"].as_f64().unwrap(),
            y - camera["y"].as_f64().unwrap(),
        );
        self.ok(json!({"op":"pan","output":1,"screen_delta":delta}));
        self.ok(json!({"op":"zoom","output":1,"zoom":zoom,"anchor":corner}));
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
    /// The pointer moves over output 1 to the point that shows a world point.
    fn hover(&mut self, x: f64, y: f64) -> Value {
        let screen = pointer(self, x, y);
        self.ok(json!({"op":"hover","output":1,"screen":screen}))
    }
    /// The same motion, reported at an event time on the clock a timed pan
    /// carries.
    fn hover_at(&mut self, x: f64, y: f64, time_ms: u64) -> Value {
        let screen = pointer(self, x, y);
        self.ok(json!({"op":"hover","output":1,"screen":screen,"time_ms":time_ms}))
    }
    /// One 60 Hz frame.
    fn tick(&mut self) -> Value {
        self.clock += 16_666_667;
        self.ok(json!({"op":"tick_navigation","timestamp_ns":self.clock}))
    }
    /// Every output's scroll momentum, as the snapshot shows it.
    fn momentum(&mut self) -> Value {
        self.snapshot()["navigation"]["momentum"].clone()
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
    /// Replace the config file and load it again, as the shell's watcher does.
    fn reload(&mut self, toml: &str) -> Value {
        let path = self.scratch.0.join("config.toml");
        std::fs::write(&path, toml).unwrap();
        let reply = self.ok(json!({"op":"load_config","path":path}));
        assert_eq!(reply["errors"], json!([]), "{reply}");
        assert_eq!(reply["warnings"], json!([]), "{reply}");
        reply
    }
    /// A pointer binding lookup with no modifier held unless `modifiers` says so.
    fn binding(&mut self, trigger: &str, source: Value, modifiers: Value, pick: bool) -> Value {
        self.ok(json!({"op":"mouse_binding","trigger":trigger,"source":source,"modifiers":modifiers,"context":"window","pick":pick}))["binding"].clone()
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
            "infinify-pointer-flow-{}-{}",
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
/// Output 1's usable rectangle in output-local points. It is asymmetric, so
/// the output's own rectangle would place every navigation elsewhere.
const USABLE: (f64, f64, f64, f64) = (20.0, 40.0, 960.0, 740.0);
const SLOPPY: &str = "focus_follows_mouse = true\n";
/// World frames by window id, in attach order, bottom to top. Output 1 at the
/// world origin and zoom 1 shows x 0..1000 and y 0..800: A, B and the stand-in
/// C are wholly on it, D hangs off its right edge, and O overlaps A's lower
/// right corner (x 300..400, y 200..300).
const A: (f64, f64, f64, f64) = (100.0, 100.0, 300.0, 200.0);
const B: (f64, f64, f64, f64) = (600.0, 100.0, 300.0, 200.0);
const C: (f64, f64, f64, f64) = (100.0, 450.0, 300.0, 200.0);
const D: (f64, f64, f64, f64) = (850.0, 450.0, 300.0, 200.0);
const O: (f64, f64, f64, f64) = (300.0, 200.0, 200.0, 200.0);

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
/// The answer to a focus request: `focus_result` or `focus_logical`.
fn answer(effect: &Value, op: &str, success: Option<bool>) -> Value {
    let mut command = json!({"op":op,"effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"]});
    if let Some(success) = success {
        command["success"] = json!(success);
    }
    command
}
/// The shell's report that native focus moved to `window` by itself.
fn native(h: &mut Host, window: u64) -> Value {
    json!({"op":"activate","window":window,"output":1,"cause":"native","identity":identity(window),"generation":h.generation(window)})
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
/// A new window with a bound source. Its native rectangle is elsewhere and
/// twice the size of its world frame: nothing here may read it for geometry,
/// and a window-local point is scaled into it.
fn attach(h: &mut Host, wid: u64, frame: (f64, f64, f64, f64)) {
    attach_as(h, wid, "test", frame);
}
/// The same for an application a window rule may match.
fn attach_as(h: &mut Host, wid: u64, app: &str, frame: (f64, f64, f64, f64)) {
    let window = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,frame.2*2.0,frame.3*2.0),"world_rect":rect(frame.0,frame.1,frame.2,frame.3)}))["window"].clone();
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
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(USABLE.0,USABLE.1,USABLE.2,USABLE.3),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
    h.reload(toml);
    h.ok(json!({"op":"tick_navigation","timestamp_ns":1_000_000_000u64}));
    h
}
/// The five-window layout: 1 to 5 are A, B, C, D and O, and 3 (C) has lost its
/// source. A holds the focus and was raised by it: bottom to top 2, 3, 4, 5, 1.
fn layout(toml: &str) -> Host {
    let mut h = empty(toml);
    for (wid, frame) in [(1, A), (2, B), (3, C), (4, D), (5, O)] {
        attach(&mut h, wid, frame);
    }
    h.ok(json!({"op":"remove_source","window":3,"identity":identity(3),"keep_placeholder":true}));
    h.focus(1);
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    assert_eq!(h.history(), json!([1]));
    h
}
/// A hover that moved the focus to a window with a source: its request, which
/// is now the pending one.
fn moved(h: &mut Host, reply: &Value, window: u64) -> Value {
    let effect = reply["effect"].clone();
    assert_eq!(effect["op"], "focus_native_window", "{reply}");
    assert_eq!(effect["window"], window);
    assert_eq!(effect["identity"], identity(window));
    assert_eq!(effect["generation"], h.generation(window));
    assert_eq!(h.focus_state()["pending_effect"], effect);
    assert_eq!(reply["dirty"], true);
    assert_eq!(h.focused(), window);
    effect
}
/// A hover focus restacks nothing and moves no frame and no camera: the
/// windows, the placements, the outputs and the flights of `after` are those
/// of `before`. The one key left out is `focused`, which every window and
/// placement is drawn with (RENDER.md) and which follows the logical focus: it
/// is checked for itself, against each snapshot's own focus.
fn unmoved(after: &Value, before: &Value) {
    let drawn = |snapshot: &Value, part: &str| {
        let mut entries = snapshot[part].clone();
        for entry in entries.as_array_mut().unwrap() {
            let focused = entry.as_object_mut().unwrap().remove("focused");
            let holds = entry["window"] == snapshot["focused"];
            assert_eq!(focused, Some(json!(holds)), "{part}: {entry}");
        }
        entries
    };
    for part in ["windows", "placements"] {
        assert_eq!(drawn(after, part), drawn(before, part), "{part}");
    }
    for part in ["outputs", "navigation"] {
        assert_eq!(after[part], before[part], "{part}");
    }
}
/// A hover that moved no focus: there is no `effect` at all, so a shell that
/// hands the reply to its focus coordinator withdraws nothing in flight.
fn kept(reply: &Value) {
    assert!(reply.get("effect").is_none(), "{reply}");
    assert_eq!(reply["dirty"], false, "{reply}");
}

// Upstream hover_is_a_no_op_with_focus_follows_mouse_off, and
// hover_outside_window_edges_yields_no_pointer_motion: motion is the window's
// only inside its frame, at window-local coordinates.
#[test]
fn hover_reports_the_hit_and_changes_nothing_without_focus_follows_mouse() {
    let mut h = layout("");
    let before = h.snapshot();
    let (x, y) = center(B);
    let reply = h.hover(x, y);
    kept(&reply);
    assert_eq!(reply["pick"], false);
    assert_eq!(reply["forward"], true);
    // Exactly the hit the `hit` command answers there: B's centre, scaled into
    // a native window twice its size at (4000, 3000) and a 200 x 100 buffer.
    assert_eq!(reply["hit"], h.hit(x, y)["hit"]);
    assert_eq!(reply["hit"]["window"], 2);
    assert_eq!(reply["hit"]["identity"], identity(2));
    assert_eq!(reply["hit"]["local"], point(300.0, 200.0));
    assert_eq!(reply["hit"]["native_screen"], point(4300.0, 3200.0));
    assert_eq!(reply["hit"]["buffer_local"], point(100.0, 50.0));
    assert_eq!(reply["hit"]["pick"], false);
    assert_eq!(h.hit(x, y)["pick"], false);
    // Four points outside B's edges: nothing is hit and nothing is delivered.
    for (x, y) in [
        (750.0, 96.0),
        (596.0, 200.0),
        (904.0, 200.0),
        (750.0, 304.0),
    ] {
        let reply = h.hover(x, y);
        kept(&reply);
        assert_eq!(
            json!([reply["hit"], reply["forward"], reply["pick"]]),
            json!([null, false, false])
        );
    }
    // A stand-in has nothing to deliver to, and `hit` refuses it.
    let reply = h.hover(250.0, 550.0);
    kept(&reply);
    assert_eq!(
        json!([reply["hit"], reply["forward"]]),
        json!([null, false])
    );
    // A point of the screen that is not on the output.
    let reply = h.ok(json!({"op":"hover","output":1,"screen":point(10.0, 10.0)}));
    kept(&reply);
    assert_eq!(
        json!([reply["hit"], reply["forward"]]),
        json!([null, false])
    );
    assert_eq!(h.snapshot(), before);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);

    assert_eq!(
        h.error(json!({"op":"hover","output":9,"screen":point(400.0, 300.0)})),
        "unknown output"
    );
    assert_eq!(
        h.error(json!({"op":"hover","output":1,"screen":point(1e13, 300.0)})),
        "invalid screen point"
    );
}

// Upstream hover_flips_activated_hint_on_the_wire and
// hover_focus_does_not_raise_the_window.
#[test]
fn hover_focuses_the_window_under_the_pointer_without_raising_it() {
    let mut h = layout(SLOPPY);
    let before = h.snapshot();
    let (x, y) = center(B);
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 2);
    assert_eq!(reply["forward"], true);
    assert_eq!(reply["hit"]["window"], 2);
    // B takes the focus where it stands, at the bottom: nothing is restacked,
    // no frame moves and the camera stays.
    let after = h.snapshot();
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    unmoved(&after, &before);
    // Nothing claims that native focus followed, and the history waits for the
    // answer, as with every focus request here.
    assert_eq!(after["focus"]["observed_native"]["window"], 1);
    assert_eq!(after["focus"]["intent"], 2);
    assert_eq!(h.history(), json!([1]));

    // Again over the same window: it holds the focus intent, so nothing is
    // asked twice and the request in flight is the same one.
    let again = h.hover(x + 20.0, y - 30.0);
    kept(&again);
    assert_eq!(again["forward"], true);
    assert_eq!(h.snapshot(), after);

    h.confirm(&wanted);
    assert_eq!(h.history(), json!([2, 1]));
    assert_eq!(h.focus_state()["observed_native"]["window"], 2);
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);

    // Empty canvas keeps the focus: only a click there unfocuses.
    let settled = h.snapshot();
    kept(&h.hover(500.0, 50.0));
    assert_eq!(h.snapshot(), settled);

    // Upstream hover_on_a_higher_windows_title_bar_over_a_lower_windows_content:
    // where A lies over O the topmost frame is the target. A shell that performs
    // no native focus answers `focus_logical`, and the history follows.
    let reply = h.hover(350.0, 250.0);
    let wanted = moved(&mut h, &reply, 1);
    h.logical(&wanted);
    assert_eq!(h.history(), json!([1, 2]));
    // O beside A is focused under A, and stays under it.
    let reply = h.hover(450.0, 350.0);
    let wanted = moved(&mut h, &reply, 5);
    h.confirm(&wanted);
    assert_eq!(h.history(), json!([5, 1, 2]));
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    assert_eq!(h.hit(350.0, 250.0)["hit"]["window"], 1);

    // A stand-in takes the focus intent too. It has no native window, so the
    // effect is null and present: the request in flight is no longer wanted.
    let reply = h.hover(250.0, 550.0);
    assert_eq!(reply.get("effect"), Some(&Value::Null), "{reply}");
    assert_eq!(reply["dirty"], true);
    assert_eq!(
        json!([reply["hit"], reply["forward"]]),
        json!([null, false])
    );
    assert_eq!(h.focused(), 3);
    assert_eq!(h.focus_state()["pending_effect"], Value::Null);
    assert_eq!(h.history(), json!([5, 1, 2]));
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    assert_eq!(h.snapshot()["outputs"], before["outputs"]);
}

// Upstream's "a pointer grab owns input" guard of maybe_hover_focus.
#[test]
fn hover_moves_no_focus_under_a_gesture_a_native_resize_or_an_open_cycle() {
    // A drag gesture: no focus, and the motion is not the window's either.
    // The press that began it raised and focused its window, as upstream's
    // move binding does ahead of the grab: D comes over A, with the focus
    // request a click's reply carries. The history waits for its answer.
    let mut h = layout(SLOPPY);
    let begun = h.ok(json!({"op":"begin_drag","window":4,"output":1}));
    assert_eq!(begun, json!({"effect":h.focus_state()["pending_effect"]}));
    assert_eq!(begun["effect"]["op"], "focus_native_window", "{begun}");
    assert_eq!(begun["effect"]["window"], 4);
    assert_eq!((h.focused(), h.stacking()), (json!(4), vec![2, 3, 5, 1, 4]));
    assert_eq!(h.history(), json!([1]));
    let held = h.snapshot();
    let (x, y) = center(B);
    let reply = h.hover(x, y);
    kept(&reply);
    assert_eq!(reply["forward"], false);
    assert_eq!(reply["hit"]["window"], 2);
    assert_eq!(h.snapshot(), held);
    h.ok(json!({"op":"end_gesture"}));
    let reply = h.hover(x, y);
    moved(&mut h, &reply, 2);

    // A native resize that has not drained. The press that begins it raises
    // and focuses the window ahead of the grab, as upstream's resize binding
    // does and as a move's does: D comes over A and takes the focus. The
    // transaction's effect is the reply's `effect`, so the focus request is
    // the one entry of `effects`.
    let mut h = layout(SLOPPY);
    let screen = pointer(&mut h, 900.0, 500.0);
    let begun = h.ok(json!({"op":"begin_native_resize","window":4,"output":1,"edges":"bottom_right","start_screen":screen}));
    assert_eq!(begun["effect"]["op"], "observe_resize_source", "{begun}");
    assert_eq!(begun["effect"]["window"], 4);
    assert_eq!(begun["transaction"], begun["effect"]["transaction"]);
    assert_eq!(begun["effects"], json!([h.focus_state()["pending_effect"]]));
    assert_eq!(begun["effects"][0]["op"], "focus_native_window");
    assert_eq!(begun["effects"][0]["window"], 4);
    assert_eq!((h.focused(), h.stacking()), (json!(4), vec![2, 3, 5, 1, 4]));
    assert_eq!(h.history(), json!([1]));
    let held = h.snapshot();
    let reply = h.hover(x, y);
    kept(&reply);
    assert_eq!(reply["forward"], false);
    assert_eq!(h.snapshot(), held);

    // An open focus cycle: the step's own selection stands until the modifier
    // is let go. The keyboard is held, not the pointer, so motion still goes
    // to the window.
    let mut h = layout(SLOPPY);
    h.focus(2);
    assert_eq!(h.history(), json!([2, 1]));
    let step = h.ok(json!({"op":"action","output":1,"action":"cycle-windows forward","held":true}));
    assert_eq!(h.focused(), 1);
    h.lands(&step["navigation"]);
    assert_eq!(h.focus_state()["cycle"], 1);
    let open = h.snapshot();
    // The step flew the camera to A; O beside it is still on the output.
    let reply = h.hover(450.0, 350.0);
    kept(&reply);
    assert_eq!(reply["hit"]["window"], 5);
    assert_eq!(reply["forward"], true);
    assert_eq!(h.snapshot(), open);
    h.ok(json!({"op":"cancel_focus_cycle"}));
    let reply = h.hover(450.0, 350.0);
    moved(&mut h, &reply, 5);
}

/// Five finger pans of a two-finger scroll, 8 ms apart, the last at 2032 ms:
/// fast enough to coast when let go.
fn scrolled() -> Host {
    let mut h = layout(SLOPPY);
    for step in 0..5u64 {
        h.ok(json!({"op":"pan","output":1,"screen_delta":point(-6.0, 2.0),"time_ms":2000 + step * 8,"source":"finger"}));
    }
    h
}
/// A motion over B's centre that the pointer's holder keeps from it: no focus
/// moves, the motion is not B's, and nothing at all changes.
fn withheld(h: &mut Host, time_ms: Option<u64>) {
    let (x, y) = center(B);
    let held = h.snapshot();
    let reply = match time_ms {
        Some(time_ms) => h.hover_at(x, y, time_ms),
        None => h.hover(x, y),
    };
    kept(&reply);
    assert_eq!(reply["forward"], false, "{reply}");
    assert_eq!(reply["hit"]["window"], 2);
    assert_eq!(h.snapshot(), held);
}

// What holds the pointer besides upstream's window grabs, where the camera
// moves by trackpad gesture, scroll and drag pan with momentum. A trackpad
// gesture between its begin and its end, a drag pan whose button is down
// (upstream's PanGrab) and a scroll pan whose momentum is yet to launch stop
// hover focus and delivery. A hover takes nothing from any of them, and
// nothing from a coast, a flight or cursor edge pan, which hold nothing:
// upstream's motion runs maybe_hover_focus and then refresh_cursor_edge_pan.
#[test]
fn hover_stands_down_while_the_pad_or_a_pan_has_the_pointer_and_stops_no_motion() {
    let (x, y) = center(B);
    // A trackpad gesture, whatever it resolved to: a swipe that pans, a hold
    // nothing is bound to, and a move, whose drag is the pointer's own.
    for (kind, doubletap, at, state) in [
        ("swipe", false, (950.0, 750.0), "swipe_pan"),
        ("hold", false, (950.0, 750.0), "unbound"),
        ("swipe", true, (150.0, 150.0), "swipe_move"),
    ] {
        let mut h = layout(SLOPPY);
        let at = pointer(&mut h, at.0, at.1);
        let context = if doubletap { "window" } else { "canvas" };
        let begun = h.ok(json!({"op":"gesture_begin","kind":kind,"fingers":3,"modifiers":{},"context":context,"output":1,"pointer":at,"doubletap":doubletap,"time_ms":1000}));
        assert_eq!(begun["gesture"]["state"], state, "{begun}");
        assert_eq!(h.snapshot()["trackpad"]["gesture"]["state"], state);
        withheld(&mut h, None);
        withheld(&mut h, Some(61_000));
        h.ok(json!({"op":"gesture_end","time_ms":61_000}));
        let reply = h.hover(x, y);
        assert_eq!(reply["forward"], true, "{state}");
        moved(&mut h, &reply, 2);
    }

    // A drag pan with its button down, however long the pointer has rested.
    let mut h = layout(SLOPPY);
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(10.0, 4.0),"time_ms":1000,"source":"drag"}));
    assert_eq!(h.momentum()["1"]["panning"], true);
    for time_ms in [None, Some(1001), Some(61_000)] {
        withheld(&mut h, time_ms);
    }
    h.ok(json!({"op":"pan_end","output":1,"time_ms":61_000}));
    // Let go after a rest, it has no velocity left to coast with.
    assert_eq!(h.momentum()["1"]["panning"], false);
    assert_eq!(h.momentum()["1"]["velocity"], point(0.0, 0.0));
    let reply = h.hover(x, y);
    assert_eq!(reply["forward"], true);
    moved(&mut h, &reply, 2);

    // A scroll that panned has the pointer until its momentum launches.
    // Upstream's own timer launches it 50 ms after the last pan event, here
    // at 2082 ms, whether or not the fingers have lifted. A host that reports
    // no time has no clock, and waits for the pan to end.
    let mut h = scrolled();
    for time_ms in [Some(2032), Some(2081), None] {
        withheld(&mut h, time_ms);
    }
    let before = h.snapshot();
    let reply = h.hover_at(x, y, 2082);
    assert_eq!(reply["forward"], true);
    moved(&mut h, &reply, 2);
    let after = h.snapshot();
    unmoved(&after, &before);
    // That hover took nothing from the pan: let go, it coasts exactly as on a
    // host no pointer moved over.
    let mut twin = scrolled();
    for host in [&mut h, &mut twin] {
        assert_eq!(
            host.ok(json!({"op":"pan_end","output":1})),
            json!({"needs_frames":true})
        );
    }
    assert_eq!(h.momentum()["1"]["coasting"], true);
    assert_eq!(h.momentum(), twin.momentum());

    // A coast holds nothing. Hovers move the focus under it, frame after
    // frame, and the camera coasts on as the twin's does.
    for (frame, (target, window)) in [(A, 1), (B, 2), (A, 1)].into_iter().enumerate() {
        let coasting = h.momentum();
        let (x, y) = center(target);
        let reply = if frame == 1 {
            h.hover(x, y)
        } else {
            h.hover_at(x, y, 2090 + frame as u64 * 16)
        };
        assert_eq!(reply["forward"], true, "frame {frame}");
        moved(&mut h, &reply, window);
        assert_eq!(h.momentum(), coasting, "frame {frame}");
        assert_eq!(h.tick()["changed_outputs"], json!([1]), "frame {frame}");
        twin.tick();
        assert_eq!(h.snapshot()["outputs"], twin.snapshot()["outputs"]);
        assert_eq!(h.momentum(), twin.momentum(), "frame {frame}");
    }
    assert_eq!(h.momentum()["1"]["coasting"], true);

    // A flight holds nothing either, and is not touched.
    let mut h = layout(SLOPPY);
    let flight = h.ok(json!({"op":"action","output":1,"action":"pan-viewport right"}));
    assert_eq!(flight["navigation"]["animating"], true);
    h.tick();
    let flying = h.snapshot();
    assert_ne!(flying["navigation"]["flights"], json!({}));
    // B's centre is still on the output one frame into the flight.
    let reply = h.hover(x, y);
    assert_eq!(reply["forward"], true);
    moved(&mut h, &reply, 2);
    let after = h.snapshot();
    unmoved(&after, &flying);
    h.lands(&flight["navigation"]);

    // Cursor edge pan is no grab: the pointer rests 5 points inside the usable
    // area's right edge, over D, the canvas pans under it, and the hover there
    // focuses D and leaves the pan armed.
    let mut h = layout(SLOPPY);
    h.ok(json!({"op":"action","output":1,"action":"toggle-cursor-pan"}));
    let at = point(ORIGIN.0 + 975.0, ORIGIN.1 + 500.0);
    assert_eq!(
        h.ok(json!({"op":"pointer","output":1,"screen":at}))["needs_frames"],
        true
    );
    let armed = h.snapshot()["navigation"]["edge_pans"].clone();
    assert_ne!(armed, json!({}));
    let reply = h.ok(json!({"op":"hover","output":1,"screen":at,"time_ms":3000}));
    assert_eq!(reply["hit"]["window"], 4);
    assert_eq!(reply["forward"], true);
    moved(&mut h, &reply, 4);
    assert_eq!(h.snapshot()["navigation"]["edge_pans"], armed);
    assert_eq!(h.tick()["changed_outputs"], json!([1]));

    // A window drag resting at the output's edge pans the canvas under its
    // window: the drag is the grab, and its edge pan is part of it.
    let mut h = layout(SLOPPY);
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    let edge = point(ORIGIN.0 + 995.0, ORIGIN.1 + 400.0);
    assert_eq!(
        h.ok(json!({"op":"gesture_to","screen_delta":point(0.0, 0.0),"pointer":edge}))["needs_frames"],
        true
    );
    assert_ne!(h.snapshot()["navigation"]["edge_pans"], json!({}));
    withheld(&mut h, Some(4000));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.snapshot()["navigation"]["edge_pans"], json!({}));
    let reply = h.hover(x, y);
    moved(&mut h, &reply, 2);

    // A time that is no time is refused, as a timed pan's is.
    let mut h = layout(SLOPPY);
    let screen = pointer(&mut h, x, y);
    assert!(
        h.error(json!({"op":"hover","output":1,"screen":screen,"time_ms":-1.0}))
            .contains("invalid time_ms")
    );
}

// macOS only: the native window a hover made key reports that it is. D hangs
// off the output and lies under A, so an activation would both fly to it and
// raise it. The echo of a hover does neither.
#[test]
fn a_native_focus_echo_of_a_hover_neither_restacks_nor_navigates() {
    let (x, y) = (900.0, 550.0);
    // The report arrives while the request is in flight: it answers it.
    let mut h = layout(SLOPPY);
    let before = h.snapshot();
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 4);
    let report = native(&mut h, 4);
    assert_eq!(
        h.ok(report.clone()),
        json!({"effect":null,"navigation":null,"dirty":false})
    );
    let after = h.snapshot();
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    unmoved(&after, &before);
    assert_eq!(h.focused(), 4);
    assert_eq!(h.history(), json!([4, 1]));
    assert_eq!(after["focus"]["observed_native"]["window"], 4);
    assert_eq!(after["focus"]["pending_effect"], Value::Null);
    // The request was answered by the observation: a late result is refused.
    assert_eq!(
        h.error(answer(&wanted, "focus_result", Some(true))),
        "stale or superseded focus result"
    );
    // Reported again, the window already holds the keyboard: upstream's
    // window_already_active.
    assert_eq!(
        h.ok(report),
        json!({"effect":null,"navigation":null,"dirty":false})
    );
    assert_eq!(h.snapshot(), after);

    // The request failed, and native focus arrived anyway.
    let mut h = layout(SLOPPY);
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 4);
    h.ok(answer(&wanted, "focus_result", Some(false)));
    let report = native(&mut h, 4);
    assert_eq!(h.ok(report)["navigation"], Value::Null);
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    assert_eq!(h.history(), json!([4, 1]));

    // Not an echo: nothing was asked of the native window (`focus_logical`), so
    // the report is the user's own activation, which raises and reveals.
    let mut h = layout(SLOPPY);
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 4);
    h.logical(&wanted);
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    let report = native(&mut h, 4);
    let reply = h.ok(report);
    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
    assert_eq!(h.stacking(), [2, 3, 5, 1, 4]);

    // Not an echo: without sloppy focus the hover focused nothing.
    let mut h = layout("");
    kept(&h.hover(x, y));
    let report = native(&mut h, 4);
    let reply = h.ok(report);
    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
    assert_eq!(h.stacking(), [2, 3, 5, 1, 4]);

    // Not an echo: a click on the hovered window made the later request.
    let mut h = layout(SLOPPY);
    let reply = h.hover(x, y);
    moved(&mut h, &reply, 4);
    h.ok(json!({"op":"activate","window":4,"output":1,"cause":"click"}));
    assert_eq!(h.stacking(), [2, 3, 5, 1, 4]);
    let report = native(&mut h, 4);
    assert_eq!(h.ok(report)["navigation"]["animating"], true);
}

// The same for a hover the pointer has left: the pointer swept across D and on
// to B before D's request was answered, B's request then failed, and the
// window that ended up key is D.
#[test]
fn a_native_report_for_a_hover_the_pointer_left_is_recorded_in_place_while_open() {
    let mut h = layout(SLOPPY);
    let before = h.snapshot();
    let (x, y) = center(B);
    let reply = h.hover(900.0, 550.0);
    moved(&mut h, &reply, 4);
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 2);
    h.ok(answer(&wanted, "focus_result", Some(false)));
    // The observation is the focus, so logical focus goes back to D, where D
    // stands: under A, hanging off the output, with the camera where it was.
    let report = native(&mut h, 4);
    assert_eq!(
        h.ok(report),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    let after = h.snapshot();
    assert_eq!(h.focused(), 4);
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    unmoved(&after, &before);
    assert_eq!(h.history(), json!([4, 1]));
    assert_eq!(after["focus"]["observed_native"]["window"], 4);
    // B's failed request is still open: should its window take the keyboard
    // after all, that is recorded the same way.
    let report = native(&mut h, 2);
    assert_eq!(
        h.ok(report),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.focused(), 2);
    assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
    assert_eq!(h.history(), json!([2, 4, 1]));
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    // Both are settled now. A further report for D is an activation.
    let report = native(&mut h, 4);
    assert_eq!(h.ok(report)["navigation"]["animating"], true);
    assert_eq!(h.stacking(), [2, 3, 5, 1, 4]);

    // A later hover's confirmed request closes the ones before it: with B
    // read back as key, D becoming key is the user's own doing.
    let mut h = layout(SLOPPY);
    let reply = h.hover(900.0, 550.0);
    moved(&mut h, &reply, 4);
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 2);
    h.confirm(&wanted);
    let report = native(&mut h, 4);
    assert_eq!(h.ok(report)["navigation"]["animating"], true);
    assert_eq!(h.stacking(), [2, 3, 5, 1, 4]);

    // A shell that performs no native focus asked nothing of either window.
    let mut h = layout(SLOPPY);
    let reply = h.hover(900.0, 550.0);
    let wanted = moved(&mut h, &reply, 4);
    h.logical(&wanted);
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 2);
    h.logical(&wanted);
    let report = native(&mut h, 4);
    assert_eq!(h.ok(report)["navigation"]["animating"], true);
    assert_eq!(h.stacking(), [2, 3, 5, 1, 4]);
}

// A request that failed, or that a press withdrew before it was answered,
// closes by itself: 3 seconds after the hover, on the clock `tick_navigation`
// keeps, a report for its window is the user's own activation, whatever
// happened in between. One tick short of that it is still the hover's echo.
#[test]
fn an_open_hover_request_expires_and_a_later_report_is_an_activation() {
    let (x, y) = (900.0, 550.0);
    for (waited, echo) in [(2_900_000_000u64, true), (3_000_000_000, false)] {
        // Failed, the pointer gone, sloppy focus turned off, focus cleared.
        let mut h = layout(SLOPPY);
        let reply = h.hover(x, y);
        let wanted = moved(&mut h, &reply, 4);
        h.ok(answer(&wanted, "focus_result", Some(false)));
        h.clock += waited;
        h.ok(json!({"op":"tick_navigation","timestamp_ns":h.clock}));
        assert_eq!(h.reload("")["focus_follows_mouse"], false);
        h.ok(json!({"op":"clear_focus"}));
        let report = native(&mut h, 4);
        let reply = h.ok(report);
        if echo {
            assert_eq!(reply, json!({"effect":null,"navigation":null,"dirty":true}));
            assert_eq!(h.stacking(), [2, 3, 4, 5, 1]);
        } else {
            assert_eq!(reply["navigation"]["animating"], true, "{reply}");
            assert_eq!(h.stacking(), [2, 3, 5, 1, 4]);
        }
        // Withdrawn unanswered, as a press withdraws it.
        let mut h = layout(SLOPPY);
        let reply = h.hover(x, y);
        moved(&mut h, &reply, 4);
        h.ok(json!({"op":"cancel_focus_cycle"}));
        h.clock += waited;
        h.ok(json!({"op":"tick_navigation","timestamp_ns":h.clock}));
        let report = native(&mut h, 4);
        let reply = h.ok(report);
        assert_eq!(reply["navigation"].is_null(), echo, "{reply}");
        assert_eq!(h.stacking() == [2, 3, 4, 5, 1], echo);
    }
}

#[test]
fn a_config_reload_turns_sloppy_focus_and_pick_mode_on_and_off_live() {
    let mut h = layout("");
    let (x, y) = center(B);
    kept(&h.hover(x, y));
    assert_eq!(h.focused(), 1);

    assert_eq!(h.reload(SLOPPY)["focus_follows_mouse"], true);
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 2);
    h.confirm(&wanted);

    assert_eq!(h.reload("")["focus_follows_mouse"], false);
    kept(&h.hover(center(A).0 - 100.0, center(A).1));
    assert_eq!(h.focused(), 2);

    // The threshold is read at every command too: the same pose is pick mode
    // under one file and not under the next.
    h.look(0.0, 0.0, 0.4);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
    assert_eq!(h.hit(x, y)["pick"], false);
    h.reload("[zoom]\ninteract_min = 0.5\n");
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    assert_eq!(h.hit(x, y)["pick"], true);
    h.reload("[zoom]\ninteract_min = 0.3\n");
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
    assert_eq!(h.hit(x, y)["pick"], false);
}

/// Pick mode's config: a threshold of 0.5, and a placement that is not the
/// center, so that a landing taken from the output's own rectangle, or from
/// the global origin, misses.
const PICK: &str =
    "focus_placement = \"top-left\"\n[zoom]\ninteract_min = 0.5\n[snap]\nouter_gap = 12.0\n";
/// Window 1, and the stand-in 2 far enough from it that no drag below snaps.
const W: (f64, f64, f64, f64) = (2000.0, 1500.0, 400.0, 300.0);
const S: (f64, f64, f64, f64) = (3200.0, 2400.0, 400.0, 300.0);
/// Output 1 at camera (1500, 1000) and zoom 0.4 shows x 1500..4000 and
/// y 1000..3000: both frames, whole.
fn zoomed_out(toml: &str, zoom: f64) -> Host {
    let mut h = empty(toml);
    attach(&mut h, 1, W);
    attach(&mut h, 2, S);
    h.ok(json!({"op":"remove_source","window":2,"identity":identity(2),"keep_placeholder":true}));
    h.look(1500.0, 1000.0, zoom);
    h
}

// Upstream below_threshold_press_over_window_arms, press_over_empty_canvas_
// falls_through, focus_suppressed_over_window_in_pick_mode,
// drag_past_slop_promotes_and_cancels_the_pick, resolve_within_slop_centers_
// the_window and stand_in_press_arms_and_bypasses_close_button.
#[test]
fn below_interact_min_a_window_is_picked_or_dragged_and_takes_no_input() {
    let mut h = zoomed_out(PICK, 0.4);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    let (x, y) = center(W);

    // The whole window is one pick target, said on the reply and on the hit.
    let hit = h.hit(x, y);
    assert_eq!(hit["pick"], true);
    assert_eq!(hit["hit"]["pick"], true);
    assert_eq!(hit["hit"]["window"], 1);
    // Empty canvas is not one: its press falls through to the canvas bindings.
    assert_eq!(h.hit(2800.0, 1200.0), json!({"hit":null,"pick":false}));
    // A press cannot be forwarded: the validation it needs is refused.
    let press = h.input(1, x, y);
    assert_eq!(
        h.error(press),
        "pick mode: below zoom.interact_min a window takes no pointer input"
    );
    // Nor is motion the window's, and the stand-in is a pick target as well.
    let over = h.hover(x, y);
    kept(&over);
    assert_eq!(
        json!([over["pick"], over["forward"], over["hit"]["window"]]),
        json!([true, false, 1])
    );
    let over = h.hover(center(S).0, center(S).1);
    assert_eq!(
        json!([over["pick"], over["forward"], over["hit"]]),
        json!([true, false, null])
    );

    // The press raises and focuses the target, upstream's try_pick_button:
    // `activate` with cause click. The stand-in is on top until then.
    assert_eq!((h.focused(), h.stacking()), (Value::Null, vec![1, 2]));
    let pressed = h.ok(json!({"op":"activate","window":1,"output":1,"cause":"click"}));
    assert_eq!(pressed["effect"]["window"], 1);
    assert_eq!((h.focused(), h.stacking()), (json!(1), vec![2, 1]));
    // Drag anywhere moves it, with no binding: 40 x 20 screen points are
    // 100 x 50 world points at zoom 0.4. `begin_drag` raises and focuses
    // what it grabs, as a bound press does: for the window the press already
    // took that restacks nothing, and the request is asked again.
    let begun = h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(begun, json!({"effect":h.focus_state()["pending_effect"]}));
    assert_eq!(begun["effect"]["window"], 1);
    assert_ne!(begun["effect"]["effect_id"], pressed["effect"]["effect_id"]);
    assert_eq!((h.focused(), h.stacking()), (json!(1), vec![2, 1]));
    h.ok(json!({"op":"gesture_to","screen_delta":point(40.0, 20.0)}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.frame(1), rect(2100.0, 1550.0, 400.0, 300.0));
    // The stand-in moves the same way: raised and focused, with no native
    // window to ask.
    let begun = h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    assert_eq!(begun, json!({"effect":null}));
    assert_eq!((h.focused(), h.stacking()), (json!(2), vec![1, 2]));
    assert_eq!(h.focus_state()["pending_effect"], Value::Null);
    h.ok(json!({"op":"gesture_to","screen_delta":point(-40.0, -20.0)}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.frame(2), rect(3100.0, 2350.0, 400.0, 300.0));
    assert_eq!(h.pose(1)["camera"], point(1500.0, 1000.0));

    // The click navigates as center-window does, at zoom 1. `top-left` parks
    // the frame's corner `snap.outer_gap` inside the usable rectangle, so at
    // zoom 1 its centre (2300, 1700) goes to the output-local point
    // (20 + 12 + 200, 40 + 12 + 150) = (232, 202): camera (2068, 1498).
    h.ok(json!({"op":"focus","window":2}));
    assert_eq!(h.stacking(), [1, 2]);
    let reply = h.ok(json!({"op":"pick","window":1,"output":1}));
    assert_eq!(reply["effect"]["op"], "focus_native_window");
    assert_eq!(reply["effect"]["window"], 1);
    assert_eq!(h.focus_state()["pending_effect"], reply["effect"]);
    assert_eq!(reply["dirty"], true);
    assert_eq!(reply["navigation"]["target_camera"], point(2068.0, 1498.0));
    assert_eq!(reply["navigation"]["target_zoom"], 1.0);
    assert_eq!(h.focused(), 1);
    assert_eq!(h.stacking(), [2, 1]);
    h.lands(&reply["navigation"]);
    assert_eq!(h.pose(1)["camera"], point(2068.0, 1498.0));
    assert_eq!(h.pose(1)["zoom"], 1.0);
    // On the screen that is the usable corner (300 + 20, 200 + 40) plus the gap.
    let placed = h.snapshot()["placements"]
        .as_array()
        .unwrap()
        .iter()
        .find(|placement| placement["window"] == 1)
        .unwrap()["screen_rect"]
        .clone();
    assert_eq!(placed, rect(332.0, 252.0, 400.0, 300.0));
    // A pick is one navigation, not a mode: the output is above the threshold
    // again and the window takes input.
    assert_eq!(h.pose(1)["pick"], false);
    let (x, y) = (2300.0, 1700.0);
    assert_eq!(h.hit(x, y)["pick"], false);
    let press = h.input(1, x, y);
    assert_eq!(h.ok(press)["pick"], false);
    assert_eq!(h.hover(x, y)["forward"], true);

    // A picked stand-in is centered like a window: its centre (3300, 2500)
    // goes to (232, 202) as well, and there is no native window to focus.
    h.look(1500.0, 1000.0, 0.4);
    let reply = h.ok(json!({"op":"pick","window":2,"output":1}));
    assert_eq!(reply["effect"], Value::Null);
    assert_eq!(reply["dirty"], true);
    assert_eq!(reply["navigation"]["target_camera"], point(3068.0, 2298.0));
    assert_eq!(reply["navigation"]["target_zoom"], 1.0);
    assert_eq!(h.focused(), 2);
    h.lands(&reply["navigation"]);

    // Upstream resolve_drops_when_target_died.
    h.look(1500.0, 1000.0, 0.4);
    h.ok(json!({"op":"forget","window":2}));
    assert_eq!(
        h.error(json!({"op":"pick","window":2,"output":1})),
        "unknown window"
    );
    assert_eq!(
        h.error(json!({"op":"pick","window":1,"output":7})),
        "unknown output"
    );
}

// Upstream above_threshold_press_is_not_consumed, resolve_drops_when_zoom_
// rose_above_threshold and default_zero_disables_pick_mode.
#[test]
fn at_or_above_interact_min_and_with_it_off_nothing_is_a_pick() {
    // 0.5 itself is not below 0.5.
    for zoom in [0.6, 0.5] {
        let mut h = zoomed_out(PICK, zoom);
        assert_eq!(h.snapshot()["outputs"][0]["pick"], false, "{zoom}");
        let (x, y) = center(W);
        let hit = h.hit(x, y);
        assert_eq!(hit["pick"], false);
        assert_eq!(hit["hit"]["pick"], false);
        let press = h.input(1, x, y);
        assert_eq!(h.ok(press)["hit"]["window"], 1);
        let over = h.hover(x, y);
        assert_eq!(json!([over["pick"], over["forward"]]), json!([false, true]));
        // Zoomed back above the threshold while the button was down: the
        // deliberate zoom stands. There is no `effect`, so the press's own
        // request is not withdrawn.
        let before = h.snapshot();
        assert_eq!(
            h.ok(json!({"op":"pick","window":1,"output":1})),
            json!({"navigation":null,"dirty":false})
        );
        assert_eq!(h.snapshot(), before);
    }

    // Off, upstream's default, at any zoom.
    let mut h = zoomed_out("", 0.01);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
    let (x, y) = center(W);
    assert_eq!(h.hit(x, y)["pick"], false);
    let press = h.input(1, x, y);
    assert_eq!(h.ok(press)["hit"]["window"], 1);
    assert_eq!(h.hover(x, y)["forward"], true);
    assert_eq!(
        h.ok(json!({"op":"pick","window":1,"output":1})),
        json!({"navigation":null,"dirty":false})
    );

    // Pick mode is each output's own: a second view at zoom 1 is not in it.
    let mut h = zoomed_out(PICK, 0.4);
    h.ok(json!({"op":"register_output","stable_id":"view-b","screen_bounds":rect(1400.0,200.0,800.0,600.0)}));
    h.ok(json!({"op":"pan","output":2,"screen_delta":point(1900.0, 1400.0)}));
    let outputs = h.snapshot()["outputs"].clone();
    assert_eq!(
        json!([outputs[0]["pick"], outputs[1]["pick"]]),
        json!([true, false])
    );
    // Window 1's centre (2200, 1650) on view-b, whose camera is (1900, 1400).
    let screen = point(1400.0 + 300.0, 200.0 + 250.0);
    let over = h.ok(json!({"op":"hover","output":2,"screen":screen}));
    assert_eq!(
        json!([over["pick"], over["forward"], over["hit"]["window"]]),
        json!([false, true, 1])
    );
    assert_eq!(
        h.ok(json!({"op":"input","output":2,"screen":screen,"identity":identity(1)}))["pick"],
        false
    );
}

// Upstream held_modifier_binding_defers_to_bindings and
// scroll_fallback_gate_hits_windows_not_widgets, as the lookup the shell makes.
#[test]
fn a_binding_lookup_over_a_pick_target_follows_upstreams_pick_rules() {
    let mut h = empty("[mouse.on-window]\n\"left\" = \"move-window\"\n");
    let (none, option) = (json!({}), json!({"option":true}));
    let mods = json!({"control":true,"option":true});
    // A bare scroll over a window is the application's. Over a pick target it
    // could reach nobody, so the canvas binding answers: pan, or wheel zoom.
    for (source, kind, combo) in [
        ("finger", "pan_viewport", "trackpad-scroll"),
        ("wheel", "zoom", "wheel-scroll"),
    ] {
        assert_eq!(
            h.binding("scroll", json!(source), none.clone(), false),
            Value::Null
        );
        let found = h.binding("scroll", json!(source), none.clone(), true);
        assert_eq!(json!([found["kind"], found["combo"]]), json!([kind, combo]));
    }
    // A scroll that is bound over a window is that binding either way.
    for pick in [false, true] {
        let found = h.binding("scroll", json!("wheel"), mods.clone(), pick);
        assert_eq!(
            json!([found["kind"], found["combo"]]),
            json!(["zoom", "mod+wheel-scroll"])
        );
    }
    // A bare button bound on a window does not outrank the pick; a
    // held-modifier binding does.
    assert_eq!(
        h.binding("left", Value::Null, none.clone(), false)["kind"],
        "move_window"
    );
    assert_eq!(h.binding("left", Value::Null, none, true), Value::Null);
    for pick in [false, true] {
        assert_eq!(
            h.binding("left", Value::Null, option.clone(), pick)["kind"],
            "move_window"
        );
        assert_eq!(
            h.binding("left", Value::Null, mods.clone(), pick)["kind"],
            "pan_viewport"
        );
    }
    // Empty canvas is never a pick target: the flag changes nothing there.
    let canvas = h.ok(json!({"op":"mouse_binding","trigger":"left","modifiers":{},"context":"canvas","pick":true}));
    assert_eq!(canvas["binding"]["kind"], "pan_viewport");
}

/// The frames of crates/desktop/tests/navigation_actions_flow.rs, whose
/// `center-nearest` candidates are worked out there: from A's centre
/// (500, 400), B is the best candidate to the right, the stand-in C to the
/// left, D upward and the anchor (500, 1400) downward. E's closest point
/// (1150, 1000) is the only one in the down-right cone besides the anchor,
/// and scores 782500 / 883.9 against the anchor's 1000000 / 707.1.
const NEAREST: [(f64, f64, f64, f64); 5] = [
    (400.0, 300.0, 200.0, 200.0),
    (900.0, 150.0, 200.0, 100.0),
    (-300.0, 300.0, 200.0, 200.0),
    (450.0, -400.0, 100.0, 100.0),
    (1150.0, 1000.0, 200.0, 200.0),
];
fn nearest() -> Host {
    let mut h = empty("[navigation]\nanchors = [[500.0, -1400.0]]\n");
    for (index, frame) in NEAREST.into_iter().enumerate() {
        attach(&mut h, index as u64 + 1, frame);
    }
    h.ok(json!({"op":"remove_source","window":3,"identity":identity(3),"keep_placeholder":true}));
    h.focus(1);
    h
}
/// A press at a point of output 1, dragged by `drag` screen points.
fn dragged(h: &mut Host, drag: (f64, f64)) -> Value {
    let start = (ORIGIN.0 + 480.0, ORIGIN.1 + 390.0);
    h.ok(json!({"op":"pointer_nearest","output":1,"start":point(start.0, start.1),"screen":point(start.0 + drag.0, start.1 + drag.1)}))
}

// Upstream NavigateGrab: the drag pulls the canvas, so the vector is the press
// minus the pointer; under 16 screen points nothing fires; past that the octant
// (a minor axis over 0.4142 of the major is a diagonal) is the direction of
// one center-nearest.
#[test]
fn a_center_nearest_press_goes_where_the_drag_pulls_the_canvas_from() {
    for (drag, direction, target) in [
        // Dragging left pulls in what lies to the right.
        ((-40.0, 0.0), "right", json!(2)),
        ((40.0, 0.0), "left", json!(3)),
        ((0.0, 40.0), "up", json!(4)),
        ((0.0, -40.0), "down", Value::Null),
        ((-40.0, -40.0), "down-right", json!(5)),
        // The threshold itself fires, as upstream's `>=` does.
        ((-16.0, 0.0), "right", json!(2)),
        // tan 22.5°: 41 in 100 is still the cardinal, 42 the diagonal.
        ((-100.0, -41.0), "right", json!(2)),
        ((-100.0, -42.0), "down-right", json!(5)),
    ] {
        let mut h = nearest();
        let reply = dragged(&mut h, drag);
        // Exactly the reply of the keyboard's action on the same scene.
        let mut twin = nearest();
        let action = format!("center-nearest {direction}");
        assert_eq!(
            reply,
            twin.ok(json!({"op":"action","output":1,"action":action})),
            "{drag:?}"
        );
        assert_eq!(reply["navigation"]["animating"], true, "{drag:?}");
        assert_eq!(h.focused(), target, "{drag:?}");
        h.lands(&reply["navigation"]);
        assert_eq!(h.snapshot(), {
            twin.settle();
            twin.snapshot()
        });
    }
    // Right lands B's centre (1000, 200) on the usable centre (500, 410).
    let mut h = nearest();
    let reply = dragged(&mut h, (-40.0, 0.0));
    assert_eq!(reply["effects"][0]["window"], 2);
    assert_eq!(reply["navigation"]["target_camera"], point(500.0, -210.0));
    assert_eq!(reply["navigation"]["target_zoom"], 1.0);

    // A plain click and a drag inside the dead zone do nothing at all.
    for drag in [(0.0, 0.0), (15.0, 0.0), (-11.0, 11.0), (0.0, -15.9)] {
        let mut h = nearest();
        let before = h.snapshot();
        assert_eq!(
            dragged(&mut h, drag),
            json!({"navigation":null,"effects":[],"dirty":false}),
            "{drag:?}"
        );
        assert_eq!(h.snapshot(), before, "{drag:?}");
    }
    let mut h = nearest();
    assert_eq!(
        h.error(json!({"op":"pointer_nearest","output":4,"start":point(0.0, 0.0),"screen":point(40.0, 0.0)})),
        "unknown output"
    );
}

// The swipe's action goes through the one dispatch every action takes, once.
// That dispatch's prelude is upstream's execute_action: a cycle held open ends
// and the output's coast stops, before the action runs. Inside the dead zone
// no action runs, and neither does its prelude.
#[test]
fn a_center_nearest_press_runs_the_action_prelude_once_and_none_in_the_dead_zone() {
    // B's cycle step is held open, its focus confirmed, and the camera coasts.
    let busy = || {
        let mut h = nearest();
        h.focus(2);
        h.focus(1);
        let step =
            h.ok(json!({"op":"action","output":1,"action":"cycle-windows forward","held":true}));
        assert_eq!(h.focused(), 2);
        h.confirm(&step["effects"][0]);
        for step in 0..5u64 {
            h.ok(json!({"op":"pan","output":1,"screen_delta":point(-30.0, 10.0),"time_ms":2000 + step * 8,"source":"finger"}));
        }
        h.ok(json!({"op":"pan_end","output":1}));
        assert_eq!(h.focus_state()["cycle"], 1);
        assert_eq!(h.momentum()["1"]["coasting"], true);
        h
    };
    let start = (ORIGIN.0 + 480.0, ORIGIN.1 + 390.0);
    for held in [true, false] {
        let mut h = busy();
        let at = point(start.0 - 40.0, start.1);
        let reply = h.ok(json!({"op":"pointer_nearest","output":1,"start":point(start.0, start.1),"screen":at,"held":held}));
        // Exactly the keyboard's action on the same scene, with the pointer
        // where the swipe fired and the modifier state it fired under.
        let mut twin = busy();
        assert_eq!(
            reply,
            twin.ok(json!({"op":"action","output":1,"action":"center-nearest right","pointer":at,"held":held})),
        );
        assert_eq!(reply["navigation"]["animating"], true, "{reply}");
        assert_eq!(reply["effects"].as_array().unwrap().len(), 1, "{reply}");
        assert_eq!(h.focus_state()["cycle"], Value::Null);
        assert_eq!(h.momentum()["1"]["coasting"], false);
        // Once: a second run would have armed a second flight and asked for
        // the focus again, and the two hosts would differ.
        assert_eq!(h.snapshot(), twin.snapshot());
        h.lands(&reply["navigation"]);
    }
    let mut h = busy();
    let before = h.snapshot();
    assert_eq!(
        h.ok(json!({"op":"pointer_nearest","output":1,"start":point(start.0, start.1),"screen":point(start.0 + 10.0, start.1),"held":true})),
        json!({"navigation":null,"effects":[],"dirty":false})
    );
    assert_eq!(h.snapshot(), before);
    assert_eq!(h.focus_state()["cycle"], 1);
    assert_eq!(h.momentum()["1"]["coasting"], true);
}

/// The one window attached as `app.widget` is a widget.
const WIDGET_RULE: &str = "[[window_rules]]\napp_id = \"app.widget\"\nwidget = true\n";
/// World frames of the layered scenes. P is pinned while output 1 is at the
/// world origin and zoom 1, so it stays at the global rectangle PIN whatever
/// the camera does: there it lies over LA's lower right. LB lies over the
/// top of the widget G (world y 450..500) and G is alone below that.
const LA: (f64, f64, f64, f64) = (100.0, 100.0, 400.0, 300.0);
const P: (f64, f64, f64, f64) = (300.0, 250.0, 200.0, 150.0);
const G: (f64, f64, f64, f64) = (600.0, 450.0, 300.0, 200.0);
const LB: (f64, f64, f64, f64) = (600.0, 300.0, 300.0, 200.0);
const PIN: (f64, f64, f64, f64) = (ORIGIN.0 + 300.0, ORIGIN.1 + 250.0, 200.0, 150.0);

/// Window 1 is LA, 2 is P, pinned to output 1, 3 is the widget G and 4 is LB.
/// LA holds the focus and tops the stack; P is under LB and LA there, and is
/// drawn and hit above both. Bottom to top 3, 2, 4, 1, and the pinned window
/// and the widget are outside the focus history.
fn layered(toml: &str) -> Host {
    let mut h = empty(toml);
    attach(&mut h, 1, LA);
    attach(&mut h, 2, P);
    attach_as(&mut h, 3, "app.widget", G);
    attach(&mut h, 4, LB);
    h.focus(2);
    assert_eq!(
        h.ok(json!({"op":"action","output":1,"action":"toggle-pin-to-screen"})),
        json!({"navigation":null,"effects":[],"dirty":true})
    );
    h.focus(4);
    h.focus(1);
    assert_eq!(h.stacking(), [3, 2, 4, 1]);
    assert_eq!(h.history(), json!([1, 4]));
    let windows = h.snapshot()["windows"].clone();
    assert_eq!(
        windows[1]["pinned"],
        json!({"output":1,"screen_rect":rect(PIN.0, PIN.1, PIN.2, PIN.3)})
    );
    assert_eq!(windows[0]["widget"], true);
    h
}
/// `hover`, `hit` and `input` at a global screen point of output 1: a pinned
/// window is where its pin says, not where the camera shows a world point.
fn hover_screen(h: &mut Host, x: f64, y: f64) -> Value {
    h.ok(json!({"op":"hover","output":1,"screen":point(x, y)}))
}
fn hit_screen(h: &mut Host, x: f64, y: f64) -> Value {
    h.ok(json!({"op":"hit","output":1,"screen":point(x, y)}))
}
fn input_screen(window: u64, x: f64, y: f64) -> Value {
    json!({"op":"input","output":1,"screen":point(x, y),"identity":identity(window)})
}

// Upstream maybe_hover_focus asks pinned_window_under before the canvas: a
// pinned window under the pointer has the priority and takes the focus, where
// it stands. Here it holds that focus outside the focus history, as every
// focus of a pinned window does (RULES.md), and the echo of its request
// neither restacks nor flies.
#[test]
fn hover_focuses_a_pinned_window_before_the_canvas_beneath_it() {
    let sloppy = format!("{SLOPPY}{WIDGET_RULE}");
    // World (400, 300) is on LA and, at this camera, global (700, 500): on P.
    let (x, y) = (400.0, 300.0);
    let mut h = layered(&sloppy);
    assert_eq!(pointer(&mut h, x, y), point(700.0, 500.0));
    let before = h.snapshot();
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 2);
    assert_eq!(
        json!([
            reply["hit"]["window"],
            reply["hit"]["pinned"],
            reply["hit"]["widget"]
        ]),
        json!([2, true, false])
    );
    // The motion is the pinned window's application's, like any window's.
    assert_eq!(
        json!([reply["forward"], reply["pick"]]),
        json!([true, false])
    );
    // Nothing is restacked, no frame and no pin moves, no camera flies.
    let after = h.snapshot();
    assert_eq!(h.stacking(), [3, 2, 4, 1]);
    unmoved(&after, &before);
    assert_eq!(after["focus"]["intent"], 2);
    assert_eq!(after["focus"]["observed_native"]["window"], 1);
    // The answer records the focus and leaves the history to the canvas
    // windows: a pinned window is never in it.
    h.confirm(&wanted);
    assert_eq!(h.history(), json!([1, 4]));
    assert_eq!(h.focus_state()["observed_native"]["window"], 2);
    assert_eq!(h.stacking(), [3, 2, 4, 1]);
    // Off the pin, LA beneath takes the focus back, and enters the history.
    let reply = h.hover(150.0, 150.0);
    let wanted = moved(&mut h, &reply, 1);
    assert_eq!(reply["hit"]["pinned"], false);
    h.logical(&wanted);
    assert_eq!(h.history(), json!([1, 4]));
    // The pin does not follow the canvas: with the camera 250 to the right
    // the same global point is still P's, and world (650, 300) under it is
    // LB's, which does not get the focus.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(250.0, 0.0)}));
    assert_eq!(pointer(&mut h, 650.0, 300.0), point(700.0, 500.0));
    let reply = hover_screen(&mut h, 700.0, 500.0);
    moved(&mut h, &reply, 2);
    assert_eq!(reply["hit"]["window"], 2);
    assert_eq!(h.stacking(), [3, 2, 4, 1]);

    // The echo: the native report for the hovered pinned window, while its
    // request is in flight, answers it where the window stands.
    let mut h = layered(&sloppy);
    let reply = h.hover(x, y);
    let wanted = moved(&mut h, &reply, 2);
    let hovered = h.snapshot();
    let report = native(&mut h, 2);
    assert_eq!(
        h.ok(report),
        json!({"effect":null,"navigation":null,"dirty":false})
    );
    let after = h.snapshot();
    assert_eq!(h.stacking(), [3, 2, 4, 1]);
    unmoved(&after, &hovered);
    assert_eq!(h.focused(), 2);
    assert_eq!(h.history(), json!([1, 4]));
    assert_eq!(after["focus"]["observed_native"]["window"], 2);
    assert_eq!(after["focus"]["pending_effect"], Value::Null);
    assert_eq!(after["navigation"]["flights"], json!({}));
    assert_eq!(
        h.error(answer(&wanted, "focus_result", Some(true))),
        "stale or superseded focus result"
    );
    // The same report with no hover behind it is an activation, which raises
    // the pinned window: that is what the echo rule keeps a hover from doing.
    let mut h = layered(WIDGET_RULE);
    kept(&h.hover(x, y));
    let report = native(&mut h, 2);
    assert_eq!(
        h.ok(report),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.stacking(), [3, 4, 1, 2]);
    assert_eq!(h.history(), json!([1, 4]));
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
}

// Upstream hover_focus_window returns for a widget: the focus stays where it
// is. Its pointer delivery does not ask who holds the keyboard, so the motion
// is still the widget's application's.
#[test]
fn hover_passes_over_a_widget_and_still_forwards_the_motion() {
    let mut h = layered(&format!("{SLOPPY}{WIDGET_RULE}"));
    // G alone, below LB.
    let settled = h.snapshot();
    let reply = h.hover(750.0, 600.0);
    kept(&reply);
    assert_eq!(
        json!([
            reply["hit"]["window"],
            reply["hit"]["widget"],
            reply["hit"]["pinned"]
        ]),
        json!([3, true, false])
    );
    assert_eq!(
        json!([reply["forward"], reply["pick"]]),
        json!([true, false])
    );
    // No request was made and none is remembered: the snapshot is the same,
    // and a native report for the widget is no echo. It is the activation of
    // a widget (RULES.md): focus recorded, history untouched, no flight.
    assert_eq!(h.snapshot(), settled);
    let report = native(&mut h, 3);
    assert_eq!(
        h.ok(report),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.focused(), 3);
    assert_eq!(h.history(), json!([1, 4]));
    assert_eq!(h.stacking(), [3, 2, 4, 1]);
    assert_eq!(h.snapshot()["navigation"]["flights"], json!({}));
    // A grab stops the delivery to a widget like any other.
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    let held = h.hover(750.0, 600.0);
    kept(&held);
    assert_eq!(held["forward"], false);
    h.ok(json!({"op":"end_gesture"}));
    // Where LB lies over the widget the hit is the canvas window, and it
    // takes the focus: the layers' order, not the stack's.
    let reply = h.hover(750.0, 475.0);
    let wanted = moved(&mut h, &reply, 4);
    assert_eq!(reply["hit"]["widget"], false);
    h.confirm(&wanted);
    assert_eq!(h.history(), json!([4, 1]));
    // Pinned, the widget is hit before the canvas and is still a widget:
    // upstream returns there, so LB beneath it takes nothing either, and the
    // motion is the widget's.
    let pinned = h.ok(json!({"op":"ipc","output":1,"request":{"Pin":{"window":3,"value":true}}}));
    assert_eq!(pinned["reply"], json!({"Ok":{"Pin":true}}));
    h.focus(1);
    let settled = h.snapshot();
    let reply = h.hover(750.0, 475.0);
    kept(&reply);
    assert_eq!(
        json!([
            reply["hit"]["window"],
            reply["hit"]["widget"],
            reply["hit"]["pinned"]
        ]),
        json!([3, true, true])
    );
    assert_eq!(reply["forward"], true);
    assert_eq!(h.snapshot(), settled);
    assert_eq!(h.focused(), 1);
}

// Upstream pick_target_under takes canvas windows and stand-ins. A pinned
// window is drawn at its own size at every zoom and stays interactive below
// `interact_min`, and a widget is never picked.
#[test]
fn below_interact_min_a_pinned_window_stays_interactive_and_a_widget_is_not_picked() {
    let mut h = layered(&format!("{PICK}{WIDGET_RULE}"));
    // At camera (-575, -500) and zoom 0.4 LA shows at global x 570..730,
    // y 440..560 and the widget at x 770..890, y 580..660. P is still at
    // x 600..800, y 450..600: over LA's right part.
    h.look(-575.0, -500.0, 0.4);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    assert_eq!(
        h.snapshot()["windows"][1]["pinned"]["screen_rect"],
        rect(PIN.0, PIN.1, PIN.2, PIN.3)
    );
    assert_eq!(pointer(&mut h, LA.0, LA.1), point(570.0, 440.0));
    assert_eq!(pointer(&mut h, G.0, G.1), point(770.0, 580.0));

    // LA where the pin does not cover it is a pick target and takes no input.
    let hit = hit_screen(&mut h, 585.0, 500.0);
    assert_eq!(
        json!([hit["pick"], hit["hit"]["pick"], hit["hit"]["window"]]),
        json!([true, true, 1])
    );
    assert_eq!(
        h.error(input_screen(1, 585.0, 500.0)),
        "pick mode: below zoom.interact_min a window takes no pointer input"
    );
    // The pinned window over it is none: it is hit, validated and hovered as
    // above the threshold, so a press there is its application's.
    let hit = hit_screen(&mut h, 650.0, 500.0);
    assert_eq!(
        json!([
            hit["pick"],
            hit["hit"]["pick"],
            hit["hit"]["window"],
            hit["hit"]["pinned"]
        ]),
        json!([false, false, 2, true])
    );
    let press = h.ok(input_screen(2, 650.0, 500.0));
    assert_eq!(
        json!([press["pick"], press["hit"]["window"]]),
        json!([false, 2])
    );
    let over = hover_screen(&mut h, 650.0, 500.0);
    kept(&over);
    assert_eq!(
        json!([over["pick"], over["forward"], over["hit"]["window"]]),
        json!([false, true, 2])
    );
    // The widget, alone at global (850, 620), is no pick target either.
    let hit = hit_screen(&mut h, 850.0, 620.0);
    assert_eq!(
        json!([
            hit["pick"],
            hit["hit"]["pick"],
            hit["hit"]["window"],
            hit["hit"]["widget"]
        ]),
        json!([false, false, 3, true])
    );
    let press = h.ok(input_screen(3, 850.0, 620.0));
    assert_eq!(press["pick"], false);
    let over = hover_screen(&mut h, 850.0, 620.0);
    assert_eq!(json!([over["pick"], over["forward"]]), json!([false, true]));
    // Where LB lies over it, global y 580..600, the widget gets nothing:
    // upstream's focus cascade stops at the canvas window above and hands the
    // pointer to nobody, so that the press cannot fall through to the widget.
    let hit = hit_screen(&mut h, 850.0, 590.0);
    assert_eq!(
        json!([hit["pick"], hit["hit"]["window"], hit["hit"]["widget"]]),
        json!([true, 4, false])
    );
    assert_eq!(
        h.error(input_screen(4, 850.0, 590.0)),
        "pick mode: below zoom.interact_min a window takes no pointer input"
    );
    assert_eq!(
        h.error(input_screen(3, 850.0, 590.0)),
        "stale source identity"
    );
    let over = hover_screen(&mut h, 850.0, 590.0);
    assert_eq!(
        json!([over["pick"], over["forward"], over["hit"]["window"]]),
        json!([true, false, 4])
    );

    // Neither is picked: the command does nothing with one. A widget is
    // dragged by nothing. The pinned window is dragged as above the
    // threshold, in screen space: by the pointer's own displacement, where
    // the canvas window below moves by that over the zoom.
    let settled = h.snapshot();
    for window in [2, 3] {
        assert_eq!(
            h.ok(json!({"op":"pick","window":window,"output":1})),
            json!({"navigation":null,"dirty":false})
        );
    }
    assert_eq!(h.snapshot(), settled);
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":3,"output":1})),
        "a widget is not moved or resized by hand"
    );
    // The press that begins the pinned drag raises and focuses the window
    // first, below the threshold as above it: upstream's try_pinned_button
    // stands ahead of try_pick_button. Nothing else of the scene moves, and
    // a pinned window stays out of the focus history.
    assert_eq!((h.focused(), h.stacking()), (json!(1), vec![3, 2, 4, 1]));
    let begun = h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    assert_eq!(begun, json!({"effect":h.focus_state()["pending_effect"]}));
    assert_eq!(begun["effect"]["op"], "focus_native_window");
    assert_eq!(begun["effect"]["window"], 2);
    assert_eq!((h.focused(), h.stacking()), (json!(2), vec![3, 4, 1, 2]));
    assert_eq!(h.history(), json!([1, 4]));
    h.ok(json!({"op":"gesture_to","screen_delta":point(-20.0, 10.0)}));
    assert_eq!(
        h.pin_rect(2),
        rect(PIN.0 - 20.0, PIN.1 + 10.0, PIN.2, PIN.3)
    );
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    h.ok(json!({"op":"gesture_to","screen_delta":point(0.0, 0.0)}));
    h.ok(json!({"op":"end_gesture"}));
    let after = h.snapshot();
    assert_eq!(h.pin_rect(2), rect(PIN.0, PIN.1, PIN.2, PIN.3));
    for window in [1, 3, 4] {
        let frame = |snapshot: &Value| {
            let windows = snapshot["windows"].as_array().unwrap();
            windows.iter().find(|w| w["window"] == window).unwrap()["world_rect"].clone()
        };
        assert_eq!(frame(&after), frame(&settled));
    }
    assert_eq!(after["outputs"], settled["outputs"]);
    assert_eq!(after["navigation"], settled["navigation"]);
    // LA still is: drag anywhere moves it, 20 screen points for 50 world
    // points, and its pick flies to it at zoom 1 with the pin where it was.
    let begun = h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(begun["effect"]["window"], 1);
    assert_eq!((h.focused(), h.stacking()), (json!(1), vec![3, 4, 2, 1]));
    h.ok(json!({"op":"gesture_to","screen_delta":point(-20.0, 0.0)}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.frame(1), rect(LA.0 - 50.0, LA.1, LA.2, LA.3));
    let reply = h.ok(json!({"op":"pick","window":1,"output":1}));
    assert_eq!(reply["effect"]["window"], 1);
    assert_eq!(reply["navigation"]["target_zoom"], 1.0);
    h.lands(&reply["navigation"]);
    assert_eq!(h.pose(1)["pick"], false);
    assert_eq!(h.pin_rect(2), rect(PIN.0, PIN.1, PIN.2, PIN.3));

    // A pinned widget is found with the pinned windows, ahead of the canvas
    // (upstream's pinned_window_under), so below the threshold it keeps its
    // pointer where LB covered the canvas widget: pinned where it shows at
    // this camera, it is 300 x 200 from global (770, 580) at every zoom.
    h.look(-575.0, -500.0, 0.4);
    assert_eq!(
        h.ok(json!({"op":"ipc","output":1,"request":{"Pin":{"window":3,"value":true}}}))["reply"],
        json!({"Ok":{"Pin":true}})
    );
    assert_eq!(h.pin_rect(3), rect(770.0, 580.0, 300.0, 200.0));
    let hit = hit_screen(&mut h, 850.0, 590.0);
    assert_eq!(
        json!([
            hit["pick"],
            hit["hit"]["pick"],
            hit["hit"]["window"],
            hit["hit"]["widget"],
            hit["hit"]["pinned"]
        ]),
        json!([false, false, 3, true, true])
    );
    assert_eq!(h.ok(input_screen(3, 850.0, 590.0))["pick"], false);
    let over = hover_screen(&mut h, 850.0, 590.0);
    kept(&over);
    assert_eq!(
        json!([over["pick"], over["forward"], over["hit"]["window"]]),
        json!([false, true, 3])
    );
    let settled = h.snapshot();
    assert_eq!(
        h.ok(json!({"op":"pick","window":3,"output":1})),
        json!({"navigation":null,"dirty":false})
    );
    assert_eq!(h.snapshot(), settled);
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":3,"output":1})),
        "a widget is not moved or resized by hand"
    );
}

// Upstream's resize border (`[mouse] resize_on_border`): decoration_hit_for,
// resize_margin_hit_for and resize_edge_at. The band is 8 canvas units
// strictly outside a window's frame. In `layout`, A (window 1, x 100..400,
// y 100..300) is on top and O (window 5, x 300..500, y 200..400) lies under
// its lower right corner; C (window 3) is a stand-in.
fn border(h: &mut Host, x: f64, y: f64) -> Value {
    let screen = pointer(h, x, y);
    h.ok(json!({"op":"resize_border","output":1,"screen":screen}))["border"].clone()
}
fn edge(window: u64, edges: &str) -> Value {
    json!({"window":window,"edges":edges,"snapped":false})
}
#[test]
fn the_resize_border_is_the_band_outside_a_frame_and_names_its_edge() {
    let mut h = layout("");
    let before = h.snapshot();
    for (x, y, edges) in [
        (96.0, 200.0, "left"),
        (92.0, 200.0, "left"),
        (404.0, 150.0, "right"),
        (250.0, 96.0, "top"),
        (250.0, 304.0, "bottom"),
        (96.0, 96.0, "top_left"),
        (404.0, 96.0, "top_right"),
        (96.0, 304.0, "bottom_left"),
    ] {
        assert_eq!(border(&mut h, x, y), edge(1, edges), "({x}, {y})");
    }
    // Eight units and no more, and a frame is no band: its own, or the one
    // of a window that lies there.
    assert_eq!(border(&mut h, 91.9, 200.0), Value::Null);
    assert_eq!(border(&mut h, 407.9, 150.0), edge(1, "right"));
    assert_eq!(border(&mut h, 408.0, 150.0), Value::Null);
    assert_eq!(border(&mut h, 250.0, 200.0), Value::Null);
    assert_eq!(border(&mut h, 404.0, 250.0), Value::Null);
    // The topmost window whose frame or band holds the point ends the walk:
    // A's band over O's, until O is raised.
    assert_eq!(border(&mut h, 404.0, 196.0), edge(1, "right"));
    assert_eq!(border(&mut h, 296.0, 350.0), edge(5, "left"));
    // A stand-in has no window to ask a size of, and empty canvas no band.
    assert_eq!(border(&mut h, 96.0, 500.0), Value::Null);
    assert_eq!(border(&mut h, 700.0, 600.0), Value::Null);
    // Asking changes nothing.
    assert_eq!(h.snapshot(), before);
    h.focus(5);
    assert_eq!(border(&mut h, 404.0, 196.0), edge(5, "top"));
    // decoration_resize_snapped: an edge drag has no modifier to say so.
    h.reload("[mouse]\ndecoration_resize_snapped = true\n");
    assert_eq!(
        border(&mut h, 96.0, 150.0),
        json!({"window":1,"edges":"left","snapped":true})
    );
    // Off, the band takes no press.
    h.reload("[mouse]\nresize_on_border = false\n");
    assert_eq!(border(&mut h, 96.0, 150.0), Value::Null);
    // A screen-pinned window is not resized here, and has no band.
    h.reload("");
    h.focus(1);
    h.ok(json!({"op":"action","output":1,"action":"toggle-pin-to-screen"}));
    assert_eq!(border(&mut h, 96.0, 150.0), Value::Null);
}
// The band is a canvas distance, as upstream's is: 8 units are 4.8 screen
// points at zoom 0.6. Below `zoom.interact_min` a press is the pick's.
#[test]
fn the_resize_border_scales_with_the_zoom_and_is_off_in_pick_mode() {
    let mut h = zoomed_out(PICK, 0.6);
    assert_eq!(border(&mut h, W.0 - 7.0, W.1 + 100.0), edge(1, "left"));
    assert_eq!(border(&mut h, W.0 - 10.0, W.1 + 100.0), Value::Null);
    let mut h = zoomed_out(PICK, 0.4);
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    assert_eq!(border(&mut h, W.0 - 4.0, W.1 + 100.0), Value::Null);
}
