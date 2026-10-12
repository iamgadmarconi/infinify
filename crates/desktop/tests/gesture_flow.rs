// SPDX-License-Identifier: GPL-3.0-or-later
//! Trackpad gesture scenarios cross the exported C ABI and JSON decoder with
//! synthetic libinput-shaped event streams. They show what the controller does
//! with such a stream. They are no evidence that the shell's recogniser turns
//! real touches into one, that macOS delivers those touches, or that anything
//! is drawn. Config files live in a throwaway directory, never the default path.
use driftwm_core::config::Config;
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
        let response = self.call(command);
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }
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
    /// Output `id`'s camera and zoom.
    fn pose(&mut self, id: u64) -> ([f64; 2], f64) {
        let snapshot = self.snapshot();
        let output = snapshot["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|output| output["id"] == id)
            .unwrap();
        (xy(&output["camera"]), output["zoom"].as_f64().unwrap())
    }
    fn camera(&mut self) -> [f64; 2] {
        self.pose(1).0
    }
    fn zoom(&mut self) -> f64 {
        self.pose(1).1
    }
    /// A window's world origin. The snapshot lists windows in stacking order.
    fn origin(&mut self, window: u64) -> [f64; 2] {
        let snapshot = self.snapshot();
        let windows = snapshot["windows"].as_array().unwrap();
        let found = windows.iter().find(|w| w["window"] == window).unwrap();
        xy(&found["world_rect"]["origin"])
    }
    fn trackpad(&mut self) -> Value {
        self.snapshot()["trackpad"].clone()
    }
    /// Begin a gesture on output 1 at a global screen point.
    fn begin(
        &mut self,
        kind: &str,
        fingers: u32,
        held: &str,
        context: &str,
        at: [f64; 2],
    ) -> Value {
        self.ok(begin(kind, fingers, held, context, at, false))
    }
    fn swipe(&mut self, dx: f64, dy: f64, time_ms: u64) -> Value {
        self.ok(json!({"op":"gesture_update","dx":dx,"dy":dy,"time_ms":time_ms}))
    }
    fn pinch(&mut self, scale: f64, time_ms: u64) -> Value {
        self.ok(json!({"op":"gesture_update","dx":0.0,"dy":0.0,"scale":scale,"rotation":0.0,"time_ms":time_ms}))
    }
    fn end(&mut self, cancelled: bool, time_ms: u64) -> Value {
        self.ok(json!({"op":"gesture_end","cancelled":cancelled,"time_ms":time_ms}))
    }
    fn tick(&mut self, clock: &mut u64) -> Value {
        *clock += 16_666_667;
        self.ok(json!({"op":"tick_navigation","timestamp_ns":*clock}))
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
            "infinify-gesture-flow-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, contents: &str) -> PathBuf {
        let path = self.0.join(name);
        std::fs::write(&path, contents).unwrap();
        path
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Where output 1 sits on the global screen: deliberately not the origin.
const LEFT: f64 = 300.0;
const TOP: f64 = 200.0;
/// A global point over window 1 at the launch pose, and one over empty canvas.
const ON_WINDOW: [f64; 2] = [LEFT + 200.0, TOP + 200.0];
const ON_CANVAS: [f64; 2] = [LEFT + 900.0, TOP + 700.0];

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn point(at: [f64; 2]) -> Value {
    json!({"x":at[0],"y":at[1]})
}
fn xy(value: &Value) -> [f64; 2] {
    [value["x"].as_f64().unwrap(), value["y"].as_f64().unwrap()]
}
/// Physical modifiers from glyphs: ⌃ control, ⌥ option, ⇧ shift, ⌘ command.
fn chord(glyphs: &str) -> Value {
    json!({"control":glyphs.contains('⌃'),"option":glyphs.contains('⌥'),"shift":glyphs.contains('⇧'),"command":glyphs.contains('⌘')})
}
fn begin(
    kind: &str,
    fingers: u32,
    held: &str,
    context: &str,
    at: [f64; 2],
    doubletap: bool,
) -> Value {
    json!({"op":"gesture_begin","kind":kind,"fingers":fingers,"modifiers":chord(held),"context":context,"output":1,"pointer":point(at),"doubletap":doubletap,"time_ms":1000})
}
fn attach(h: &mut Host, wid: u64, world: Value) {
    h.ok(json!({"op":"attach","identity":{"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid},"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"world_rect":world}));
}
/// Output 1, 1000 x 800 at global (300, 200), and window 1 at world
/// (100, 100) 400 x 300 with window 2 far off at (2600, 1900) 300 x 200.
/// Desktop defaults are in force: no config file is read.
fn setup() -> Host {
    let mut h = Host::new();
    h.ok(json!({"op":"register_output","stable_id":"view","screen_bounds":rect(LEFT,TOP,1000.0,800.0)}));
    attach(&mut h, 1, rect(100.0, 100.0, 400.0, 300.0));
    attach(&mut h, 2, rect(2600.0, 1900.0, 300.0, 200.0));
    h
}
/// `setup`, then the given config file in force.
fn configured(scratch: &Scratch, toml: &str) -> Host {
    let mut h = setup();
    load(&mut h, scratch, toml);
    h
}
fn load(h: &mut Host, scratch: &Scratch, toml: &str) {
    let path = scratch.write("config.toml", toml);
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(reply["warnings"], json!([]), "{reply}");
}
// Movement scenarios configure the action they exercise; the desktop's
// default three-finger doubletap swipe pans instead.
const MOVE_GESTURE: &str = r#"
[gestures.on-window]
"3-finger-doubletap-swipe" = "move-window"
"#;
const DIRECTIONAL_SWIPE: &str = r#"
[gestures.anywhere]
"4-finger-swipe-up" = "none"
"#;

/// The bindings a `gesture_begin` reply resolved, as `combo = action` lines.
fn bindings(reply: &Value) -> Vec<String> {
    reply["gesture"]["bindings"]
        .as_array()
        .unwrap_or_else(|| panic!("{reply}"))
        .iter()
        .map(|b| {
            format!(
                "{} = {}",
                b["combo"].as_str().unwrap(),
                b["action"].as_str().unwrap()
            )
        })
        .collect()
}
/// The reply dispatched exactly this action string, and the action ran.
fn assert_ran(reply: &Value, action: &str) {
    assert_eq!(
        reply["fired"],
        json!({"action":action,"error":null}),
        "{reply}"
    );
}
/// The reply dispatched exactly this action string to an action that does not
/// run here yet: the error is the action command's own refusal, by name.
fn assert_refused(reply: &Value, action: &str) {
    let name = action.split(' ').next().unwrap();
    assert_eq!(
        reply["fired"],
        json!({"action":action,"error":format!("action not implemented on macOS yet: {name}")}),
        "{reply}"
    );
}
/// The focus request among a reply's effects: it asks for `window`.
fn focus_effect(reply: &Value, window: u64) -> Value {
    let effect = reply["effects"][0].clone();
    assert_eq!(effect["op"], "focus_native_window", "{reply}");
    assert_eq!(effect["window"], window, "{reply}");
    effect
}
/// Report that the adapter did what `effect` asked and read it back.
fn confirm(h: &mut Host, effect: &Value) {
    h.ok(json!({"op":"focus_result","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"],"success":true}));
}
/// One frame after a gesture's end, on a frame clock already running:
/// whether the launch left the camera moving.
fn launched(h: &mut Host, clock: &mut u64) -> bool {
    let lifted = h.camera();
    let tick = h.tick(clock);
    let moving = tick["needs_frames"] == true;
    assert_eq!(h.camera() != lifted, moving, "{tick}");
    moving
}
fn assert_close(actual: [f64; 2], expected: [f64; 2]) {
    assert!(
        (actual[0] - expected[0]).abs() < 1e-9 && (actual[1] - expected[1]).abs() < 1e-9,
        "{actual:?} != {expected:?}"
    );
}

#[test]
fn three_finger_swipe_pans_by_trackpad_speed_over_zoom_on_canvas_and_window() {
    let mut h = setup();
    h.ok(json!({"op":"register_output","stable_id":"other","screen_bounds":rect(1300.0,200.0,800.0,600.0)}));
    // Zoom out around the output's own corner: the camera stays at the origin.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":point([LEFT, TOP])}));
    assert_eq!(h.pose(1), ([0.0, 0.0], 0.5));
    let mut clock = 0;
    h.tick(&mut clock);
    // At zoom 0.5 window 1 covers global (350..550, 250..400).
    let mut expected = [0.0, 0.0];
    for (context, at) in [
        ("canvas", ON_CANVAS),
        ("window", [LEFT + 100.0, TOP + 100.0]),
    ] {
        let reply = h.begin("swipe", 3, "", context, at);
        assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
        assert_eq!(reply["gesture"]["output"], 1);
        assert_eq!(bindings(&reply), ["3-finger-swipe = pan-viewport"]);
        assert_eq!(reply["gesture"]["bindings"][0]["implemented"], true);
        assert_eq!(reply["trackpad"], true);
        // Upstream SwipePan: camera += -delta * trackpad_speed (1.5) / zoom.
        // Fingers right and up carry the canvas right and up.
        for (dx, dy, time) in [(10.0, -4.0, 1010), (0.0, 0.0, 1020), (-2.0, 6.0, 1030)] {
            let reply = h.swipe(dx, dy, time);
            assert_eq!(reply["gesture"]["state"], "swipe_pan");
            assert_eq!(reply["fired"], Value::Null);
            expected = [expected[0] - dx * 1.5 / 0.5, expected[1] - dy * 1.5 / 0.5];
            assert_eq!(h.camera(), expected);
            assert_eq!(h.zoom(), 0.5);
        }
        // The fingers rested before lifting. Upstream launches all the same,
        // a tracker its own 50 ms timer has emptied by then: the next frame
        // finds no velocity and the camera is where the fingers left it.
        let reply = h.end(false, 2000);
        assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
        assert_eq!(reply["gesture"]["cancelled"], false);
        assert_eq!(reply["dirty"], true);
        assert_eq!(reply["needs_frames"], true);
        assert!(!launched(&mut h, &mut clock));
        assert_eq!(h.camera(), expected);
    }
    assert_eq!(expected, [-48.0, -12.0]);
    // The gesture is pinned to its own output, and no window moved.
    assert_eq!(h.pose(2), ([0.0, 0.0], 1.0));
    assert_eq!(h.origin(1), [100.0, 100.0]);
    assert_eq!(
        h.trackpad(),
        json!({"enabled":true,"gesture":null,"coasting":[]})
    );
}

#[test]
fn a_flicked_swipe_coasts_on_upstream_momentum_and_live_input_stops_it() {
    let mut h = setup();
    let mut clock = 1_000_000_000;
    // 3750 points a second: 20 finger points every 8 ms at trackpad_speed 1.5.
    let flick = |h: &mut Host| {
        h.begin("swipe", 3, "", "canvas", ON_CANVAS);
        for step in 1..=6 {
            h.swipe(-20.0, 0.0, 1000 + step * 8);
        }
        h.end(false, 1056)
    };
    let reply = flick(&mut h);
    assert_eq!(reply["needs_frames"], true, "{reply}");
    assert_eq!(h.camera(), [180.0, 0.0]);
    assert_eq!(h.trackpad()["coasting"], json!([1]));
    // There is one momentum, the output's own. A second controller is given
    // the same fingers as the timed pans of a two-finger scroll and a pan_end
    // at the swipe's end: its launch and every frame of its coast must be the
    // gesture's, bit for bit.
    let mut scroll = setup();
    for step in 1..=6 {
        scroll.ok(json!({"op":"pan","output":1,"screen_delta":point([20.0, 0.0]),"time_ms":1000 + step * 8,"source":"finger"}));
    }
    assert_eq!(
        scroll.ok(json!({"op":"pan_end","output":1,"time_ms":1056})),
        json!({"needs_frames":true})
    );
    let momentum = |h: &mut Host| h.snapshot()["navigation"]["momentum"].clone();
    assert_eq!(momentum(&mut h), momentum(&mut scroll));
    assert_eq!(momentum(&mut h)["1"]["coasting"], true);
    // The camera keeps going the way the swipe sent it, slower each frame,
    // until upstream's physics stops it.
    let (mut last, mut stride, mut frames) = (180.0, f64::INFINITY, 0);
    h.tick(&mut clock);
    scroll.ok(json!({"op":"tick_navigation","timestamp_ns":clock}));
    loop {
        let tick = h.tick(&mut clock);
        scroll.ok(json!({"op":"tick_navigation","timestamp_ns":clock}));
        assert_eq!(scroll.camera(), h.camera());
        assert_eq!(momentum(&mut h), momentum(&mut scroll));
        let x = h.camera()[0];
        frames += 1;
        assert!(frames < 2000, "the coast never stopped");
        if tick["needs_frames"] == false {
            assert_eq!(x, last, "{tick}");
            break;
        }
        assert_eq!(tick["changed_outputs"], json!([1]), "{tick}");
        assert!(
            x > last && x - last < stride,
            "{last} -> {x} after {stride}"
        );
        (stride, last) = (x - last, x);
        assert_eq!(h.camera()[1], 0.0);
    }
    assert!(frames > 5 && last > 300.0, "{frames} frames to {last}");
    assert_eq!(h.trackpad()["coasting"], json!([]));

    // A new bound gesture, a pan, a zoom and cancel_navigation each stop it.
    for stop in [
        begin("swipe", 3, "", "canvas", ON_CANVAS, false),
        begin("pinch", 3, "", "canvas", ON_CANVAS, false),
        json!({"op":"pan","output":1,"screen_delta":point([1.0, 0.0])}),
        json!({"op":"zoom","output":1,"zoom":1.0,"anchor":point(ON_CANVAS)}),
        json!({"op":"cancel_navigation","output":1}),
    ] {
        assert_eq!(flick(&mut h)["needs_frames"], true);
        h.ok(stop);
        h.end(true, 3000);
        let rest = h.camera();
        assert_eq!(h.tick(&mut clock)["needs_frames"], false);
        assert_eq!(h.camera(), rest);
    }
    // The shell's order for a press on the pad during a moving pan: the
    // gesture ends cancelled, which launches the coast, and only then is
    // navigation cancelled, so the drag the press installs holds still.
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    for step in 1..=6 {
        h.swipe(-20.0, 0.0, 1000 + step * 8);
    }
    assert_eq!(h.end(true, 1056)["needs_frames"], true);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    h.ok(json!({"op":"begin_drag","window":1,"output":1,"group":false}));
    let (rest, held) = (h.camera(), h.origin(1));
    assert_eq!(h.tick(&mut clock)["needs_frames"], false);
    assert_eq!((h.camera(), h.origin(1)), (rest, held));
    assert_eq!(h.trackpad()["coasting"], json!([]));
    h.ok(json!({"op":"end_gesture"}));
    // An unbound gesture is not live input for the camera.
    assert_eq!(flick(&mut h)["needs_frames"], true);
    assert_eq!(
        h.begin("hold", 5, "", "canvas", ON_CANVAS)["needs_frames"],
        true
    );
    h.end(false, 3000);
    assert_eq!(h.trackpad()["coasting"], json!([1]));
    // A flight armed on the output stops its coast there and then.
    assert_eq!(
        h.ok(json!({"op":"zoom_to_fit","output":1}))["navigation"]["animating"],
        true
    );
    assert_eq!(h.trackpad()["coasting"], json!([]));
    h.ok(json!({"op":"cancel_navigation","output":1}));
    // Upstream's execute_action stops momentum before any action, armed or
    // not: the view actions, and the window, output and layout actions alike.
    for action in [
        "set-bookmark here",
        "exec true",
        "zoom-in",
        "center-nearest down",
        "center-window",
        "cycle-windows forward",
        "focus-center",
        "send-to-output right",
        "switch-layout next",
        "close-window",
    ] {
        assert_eq!(flick(&mut h)["needs_frames"], true);
        h.action(action);
        assert_eq!(h.trackpad()["coasting"], json!([]), "{action}");
        h.ok(json!({"op":"cancel_navigation","output":1}));
    }
    // So does an action that arrives as an IPC request.
    assert_eq!(flick(&mut h)["needs_frames"], true);
    let reply = h.ok(json!({"op":"ipc","output":1,"request":{"Action":"center-nearest down"}}));
    assert_eq!(reply["reply"], json!({"Ok":"Ok"}), "{reply}");
    assert_eq!(h.trackpad()["coasting"], json!([]));
    h.ok(json!({"op":"cancel_navigation","output":1}));
    // An action on another output, or on none, leaves this one coasting.
    h.ok(json!({"op":"register_output","stable_id":"other","screen_bounds":rect(1300.0,200.0,800.0,600.0)}));
    assert_eq!(flick(&mut h)["needs_frames"], true);
    h.ok(json!({"op":"action","output":2,"action":"set-bookmark there"}));
    h.ok(json!({"op":"action","output":null,"action":"exec true"}));
    assert_eq!(h.trackpad()["coasting"], json!([1]));
}

#[test]
fn momentum_follows_drift_and_the_launch_delay_and_a_cancelled_swipe_still_coasts() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, "[navigation]\ndrift = 0\n");
    let mut clock = 0;
    h.tick(&mut clock);
    let flick = |h: &mut Host, cancelled: bool| {
        h.begin("swipe", 3, "", "canvas", ON_CANVAS);
        for step in 1..=6 {
            h.swipe(0.0, 20.0, 1000 + step * 8);
        }
        h.end(cancelled, 1056)
    };
    // drift = 0 is upstream's "momentum disabled", and what its MomentumState
    // does with it: the launch happens, the first frame spends the whole
    // velocity (180 canvas points in 40 ms), and the one after is at rest.
    assert_eq!(flick(&mut h, false)["needs_frames"], true);
    assert_eq!(h.camera(), [0.0, -180.0]);
    assert!(launched(&mut h, &mut clock));
    let coasted = h.camera()[1] + 180.0;
    assert!((coasted + 4500.0 * 0.016666667).abs() < 1e-9, "{coasted}");
    assert_eq!(h.tick(&mut clock)["needs_frames"], false);
    assert_eq!(h.camera(), [0.0, -180.0 + coasted]);
    assert_eq!(h.trackpad()["coasting"], json!([]));
    // Upstream launches at the end of a swipe whether or not it was cancelled:
    // libinput cancels a swipe when one finger lifts ahead of the others.
    load(&mut h, &scratch, "");
    assert_eq!(flick(&mut h, true)["needs_frames"], true);
    assert_eq!(h.trackpad()["coasting"], json!([1]));
    assert!(launched(&mut h, &mut clock));
    // Upstream's MOMENTUM_LAUNCH_DELAY: 50 ms after the last delta its timer
    // has launched the coast and emptied the tracker, so the launch at the end
    // finds no velocity and the camera stays where the fingers left it.
    let rested = |h: &mut Host, ms: u64| {
        h.begin("swipe", 3, "", "canvas", ON_CANVAS);
        for step in 1..=6 {
            h.swipe(0.0, 20.0, 1000 + step * 8);
        }
        h.end(false, 1048 + ms)
    };
    assert_eq!(rested(&mut h, 49)["needs_frames"], true);
    assert_eq!(h.trackpad()["coasting"], json!([1]));
    assert!(launched(&mut h, &mut clock));
    for ms in [50, 79, 80] {
        // The launch at the end is still made, of nothing: a frame later the
        // camera is at rest where the fingers left it.
        assert_eq!(rested(&mut h, ms)["needs_frames"], true, "{ms}");
        assert!(!launched(&mut h, &mut clock), "{ms}");
        assert_eq!(h.trackpad()["coasting"], json!([]), "{ms}");
    }
    // The emptied tracker starts over with the next delta: one sample after
    // such a pause is no velocity, however fast the swipe was before it.
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    for time in [1008, 1016, 1024, 1032, 1040, 1048, 1098] {
        h.swipe(0.0, 20.0, time);
    }
    assert_eq!(h.end(false, 1106)["needs_frames"], true);
    assert!(!launched(&mut h, &mut clock));
    // A pause one millisecond shorter keeps the samples before it.
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    for time in [1008, 1016, 1024, 1032, 1040, 1048, 1097] {
        h.swipe(0.0, 20.0, time);
    }
    assert_eq!(h.end(false, 1105)["needs_frames"], true);
    assert!(launched(&mut h, &mut clock));
}

#[test]
fn a_configured_four_finger_swipe_fires_center_nearest_once_in_the_pan_direction() {
    let scratch = Scratch::new();
    for (context, at) in [("canvas", ON_CANVAS), ("window", ON_WINDOW)] {
        // Three steps of each vector. Upstream's threshold is 12 points of
        // accumulated travel, reached on the third. Fingers left look right.
        for (dx, dy, direction) in [
            (-5.0, 0.0, "right"),
            (5.0, 0.0, "left"),
            (0.0, -5.0, "down"),
            (0.0, 5.0, "up"),
            (-4.0, -4.0, "down-right"),
            (4.0, -4.0, "down-left"),
            (-4.0, 4.0, "up-right"),
            (4.0, 4.0, "up-left"),
            (-5.0, -1.0, "right"),
        ] {
            let mut h = configured(&scratch, DIRECTIONAL_SWIPE);
            let reply = h.begin("swipe", 4, "", context, at);
            assert_eq!(reply["gesture"]["state"], "swipe_threshold", "{reply}");
            assert_eq!(bindings(&reply), ["4-finger-swipe = center-nearest"]);
            for time in [1010, 1020] {
                assert_eq!(h.swipe(dx, dy, time)["fired"], Value::Null);
            }
            let reply = h.swipe(dx, dy, 1030);
            let action = format!("center-nearest {direction}");
            assert_ran(&reply, &action);
            // Nothing is focused, so the search starts at the viewport center
            // (500, 400): window 1, which holds that point, is found by its
            // own center, up and to the left, and window 2 lies down and to
            // the right. The camera flies there at the current zoom and the
            // window is raised and focused; a cone with no window in it does
            // nothing at all.
            let found = match direction {
                "left" | "up-left" => Some((1, [-200.0, -150.0])),
                "right" | "down-right" => Some((2, [2250.0, 1600.0])),
                _ => None,
            };
            match found {
                Some((window, camera)) => {
                    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
                    assert_eq!(reply["navigation"]["output"], 1);
                    assert_eq!(reply["navigation"]["target_camera"], point(camera));
                    assert_eq!(reply["navigation"]["target_zoom"], 1.0);
                    focus_effect(&reply, window);
                    assert_eq!(reply["needs_frames"], true);
                    assert_eq!(reply["dirty"], true);
                    assert_eq!(h.snapshot()["focus"]["intent"], window);
                }
                None => {
                    assert_eq!(reply["navigation"], Value::Null, "{reply}");
                    assert_eq!(reply["effects"], json!([]));
                    assert_eq!(reply["needs_frames"], false);
                    assert_eq!(reply["dirty"], false);
                    assert_eq!(h.snapshot()["focus"]["intent"], Value::Null);
                }
            }
            // Once: the same gesture never fires again, however far it goes.
            for time in [1040, 1050] {
                assert_eq!(h.swipe(dx * 10.0, dy * 10.0, time)["fired"], Value::Null);
            }
            assert_eq!(h.end(false, 1060)["fired"], Value::Null);
            // The gesture ran the action command's own action: on a second
            // controller that command arms the same flight, asks for the same
            // focus and leaves the same scene.
            let mut direct = configured(&scratch, DIRECTIONAL_SWIPE);
            let command =
                direct.ok(json!({"op":"action","output":1,"action":action,"pointer":point(at)}));
            for key in ["navigation", "effects", "dirty"] {
                assert_eq!(reply[key], command[key], "{action}: {key}");
            }
            assert_eq!(h.snapshot(), direct.snapshot(), "{action}");
        }
    }
    // A swipe that ends short of the threshold fires nothing.
    let mut h = configured(&scratch, DIRECTIONAL_SWIPE);
    h.begin("swipe", 4, "", "canvas", ON_CANVAS);
    assert_eq!(h.swipe(-11.0, 0.0, 1010)["fired"], Value::Null);
    assert_eq!(h.end(false, 1020)["fired"], Value::Null);
    assert_eq!(h.camera(), [0.0, 0.0]);
}

#[test]
fn three_finger_pinch_zooms_around_the_pointer_and_snaps_near_one() {
    let mut h = setup();
    // Start off the origin so the anchor arithmetic is not trivially zero.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point([40.0, 25.0])}));
    let under = |h: &mut Host, at: [f64; 2]| {
        let (camera, zoom) = h.pose(1);
        [
            camera[0] + (at[0] - LEFT) / zoom,
            camera[1] + (at[1] - TOP) / zoom,
        ]
    };
    for (context, at) in [("window", ON_WINDOW), ("canvas", ON_CANVAS)] {
        let anchor = under(&mut h, at);
        let reply = h.begin("pinch", 3, "", context, at);
        assert_eq!(reply["gesture"]["state"], "pinch_zoom", "{reply}");
        assert_eq!(bindings(&reply), ["3-finger-pinch = zoom"]);
        // Upstream PinchZoom: zoom = initial * (1 + (scale - 1) * 1.0), and the
        // canvas point under the pointer stays under it.
        for (scale, zoom) in [(0.8, 0.8), (0.5, 0.5), (0.65, 0.65)] {
            h.pinch(scale, 1010);
            assert!((h.zoom() - zoom).abs() < 1e-12, "{}", h.zoom());
            assert_close(under(&mut h, at), anchor);
        }
        // Zooming in stops at upstream's maximum, 1.0.
        h.pinch(3.0, 1020);
        assert_eq!(h.zoom(), 1.0);
        // Ending inside the dead zone around 1.0 snaps to it, around the pointer.
        h.pinch(0.97, 1030);
        assert!((h.zoom() - 0.97).abs() < 1e-12);
        let reply = h.end(false, 1040);
        assert_eq!(reply["dirty"], true, "{reply}");
        assert_eq!(h.zoom(), 1.0);
        assert_close(under(&mut h, at), anchor);
    }
    // The floor is upstream's dynamic minimum: half the zoom that fits every
    // window, with zoom.fit_padding points of margin, in the usable area.
    let padding = Config::default().zoom_fit_padding;
    let fit = ((1000.0 - 2.0 * padding) / 2800.0_f64).min((800.0 - 2.0 * padding) / 2000.0);
    h.begin("pinch", 3, "", "canvas", ON_CANVAS);
    h.pinch(0.001, 1010);
    assert!(
        (h.zoom() - fit * 0.5).abs() < 1e-12,
        "{} vs {fit}",
        h.zoom()
    );
    h.end(false, 1020);
    // A pinch is scale since the gesture began, so the next one starts here.
    h.begin("pinch", 3, "", "canvas", ON_CANVAS);
    h.pinch(2.0, 1010);
    assert!((h.zoom() - fit).abs() < 1e-12);
    h.end(true, 1020);
    assert!((h.zoom() - fit).abs() < 1e-12);
    // A pose below the minimum, which the direct zoom command can leave, is
    // pulled up to it by the first update, as upstream's clamp does.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.05,"anchor":point(ON_CANVAS)}));
    h.begin("pinch", 3, "", "canvas", ON_CANVAS);
    h.pinch(1.0, 1010);
    assert!((h.zoom() - fit * 0.5).abs() < 1e-12, "{}", h.zoom());
    h.end(false, 1020);
}

#[test]
fn two_finger_pinch_zooms_on_canvas_and_window_with_or_without_command() {
    let mut h = setup();
    let reply = h.begin("pinch", 2, "", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "pinch_zoom", "{reply}");
    assert_eq!(bindings(&reply), ["2-finger-pinch = zoom"]);
    h.pinch(0.6, 1010);
    assert_eq!(h.end(false, 1020)["dirty"], true);
    assert!((h.zoom() - 0.6).abs() < 1e-12);
    h.ok(json!({"op":"zoom","output":1,"zoom":1.0,"anchor":point(ON_WINDOW)}));

    let reply = h.begin("pinch", 2, "", "canvas", ON_CANVAS);
    assert_eq!(bindings(&reply), ["2-finger-pinch = zoom"]);
    h.pinch(0.6, 1010);
    h.end(false, 1020);
    assert!((h.zoom() - 0.6).abs() < 1e-12);

    // Command is the desktop `mod`: mod+2-finger-pinch zooms anywhere.
    let reply = h.begin("pinch", 2, "⌘", "window", [LEFT + 100.0, TOP + 100.0]);
    assert_eq!(reply["gesture"]["state"], "pinch_zoom", "{reply}");
    assert_eq!(bindings(&reply), ["mod+2-finger-pinch = zoom"]);
    h.pinch(0.5, 1010);
    h.end(false, 1020);
    assert!((h.zoom() - 0.3).abs() < 1e-12);
}

#[test]
fn four_finger_pinch_in_and_out_fire_zoom_to_fit_and_home_toggle_once_each() {
    let mut h = setup();
    // Away from home, so home-toggle has somewhere to fly.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point([5000.0, 5000.0])}));
    let reply = h.begin("pinch", 4, "", "canvas", ON_CANVAS);
    assert_eq!(reply["gesture"]["state"], "pinch_threshold", "{reply}");
    assert_eq!(
        bindings(&reply),
        [
            "4-finger-pinch-in = zoom-to-fit",
            "4-finger-pinch-out = home-toggle"
        ]
    );
    // Upstream's thresholds: in below 0.85, out above 1.15.
    for scale in [0.95, 0.86, 1.1] {
        assert_eq!(h.pinch(scale, 1010)["fired"], Value::Null);
    }
    let reply = h.pinch(0.84, 1020);
    assert_eq!(reply["fired"], json!({"action":"zoom-to-fit","error":null}));
    // The overview: every window in view, exactly as the action command arms it.
    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
    assert_eq!(reply["navigation"]["output"], 1);
    assert_eq!(reply["navigation"]["target_zoom"], 0.3);
    assert_eq!(reply["needs_frames"], true);
    assert_eq!(reply["dirty"], false);
    // In has fired: going further in does nothing more.
    for scale in [0.5, 0.2] {
        assert_eq!(h.pinch(scale, 1030)["fired"], Value::Null);
    }
    // The same gesture may still fire out, once.
    let reply = h.pinch(1.16, 1040);
    assert_eq!(reply["fired"], json!({"action":"home-toggle","error":null}));
    assert_eq!(reply["navigation"]["target_zoom"], 1.0, "{reply}");
    assert_eq!(
        reply["navigation"]["target_camera"],
        json!({"x":-500.0,"y":-400.0})
    );
    for scale in [2.0, 0.1, 3.0] {
        assert_eq!(h.pinch(scale, 1050)["fired"], Value::Null);
    }
    assert_eq!(h.end(false, 1060)["fired"], Value::Null);

    // The mod+ variants on three fingers, and the cluster's own fit.
    let reply = h.begin("pinch", 3, "⌘", "window", ON_WINDOW);
    assert_eq!(
        bindings(&reply),
        [
            "mod+3-finger-pinch-in = zoom-to-fit",
            "mod+3-finger-pinch-out = home-toggle"
        ]
    );
    assert_eq!(h.pinch(1.2, 1010)["fired"]["action"], "home-toggle");
    h.end(false, 1020);
    let reply = h.begin("pinch", 4, "⌘", "canvas", ON_CANVAS);
    assert_eq!(
        bindings(&reply),
        ["mod+4-finger-pinch-in = zoom-to-fit-snapped"]
    );
    assert_eq!(reply["gesture"]["bindings"][0]["implemented"], true);
    // Unbound in this direction: the threshold is spent, nothing fires.
    assert_eq!(h.pinch(1.2, 1010)["fired"], Value::Null);
    // It runs: tests/sizes_flow.rs covers what it does. No window is focused
    // here, so there is no cluster to frame.
    let reply = h.pinch(0.8, 1020);
    assert_ran(&reply, "zoom-to-fit-snapped");
    assert_eq!(reply["navigation"], Value::Null);
    h.end(false, 1030);
    // Option over a window: upstream's fit-window and toggle-fullscreen. The
    // first delivers a size, which this shell has not said it can do.
    for (fingers, action) in [(2, "fit-window"), (3, "toggle-fullscreen")] {
        let reply = h.begin("pinch", fingers, "⌥", "window", ON_WINDOW);
        assert_eq!(reply["gesture"]["state"], "pinch_threshold", "{reply}");
        assert_eq!(reply["gesture"]["bindings"][0]["implemented"], false);
        assert_refused(&h.pinch(0.8, 1010), action);
        assert_refused(&h.pinch(1.2, 1020), action);
        h.end(false, 1030);
    }
}

#[test]
fn hold_fires_on_release_and_not_when_cancelled() {
    let mut h = setup();
    for (fingers, held, combo) in [(4, "", "4-finger-hold"), (3, "⌘", "mod+3-finger-hold")] {
        let reply = h.begin("hold", fingers, held, "canvas", ON_CANVAS);
        assert_eq!(reply["gesture"]["state"], "hold", "{reply}");
        assert_eq!(bindings(&reply), [format!("{combo} = center-window")]);
        assert_eq!(reply["gesture"]["bindings"][0]["implemented"], true);
        assert_eq!(reply["fired"], Value::Null);
        // Nothing happens while the fingers rest.
        assert_eq!(h.swipe(0.0, 0.0, 1500)["fired"], Value::Null);
        // center-window: the focused window, and with none the window nearest
        // the middle of the view, which is window 1 both times; its center
        // comes to the middle of the output at zoom 1, and it is focused.
        let reply = h.end(false, 2000);
        assert_ran(&reply, "center-window");
        assert_eq!(
            reply["navigation"]["target_camera"],
            point([-200.0, -150.0])
        );
        assert_eq!(reply["navigation"]["target_zoom"], 1.0);
        focus_effect(&reply, 1);
        assert_eq!(reply["needs_frames"], true);
        assert_eq!(reply["dirty"], true);
        assert_eq!(h.snapshot()["focus"]["intent"], 1);
        h.begin("hold", fingers, held, "window", ON_WINDOW);
        assert_eq!(h.end(true, 2000)["fired"], Value::Null);
    }
    // Three fingers without mod, and five, hold nothing.
    for fingers in [3, 5] {
        let reply = h.begin("hold", fingers, "", "canvas", ON_CANVAS);
        assert_eq!(reply["gesture"]["state"], "unbound", "{reply}");
        assert_eq!(h.end(false, 2000)["fired"], Value::Null);
    }
    // An action that runs here, bound to the hold.
    let scratch = Scratch::new();
    let mut h = configured(
        &scratch,
        "[gestures.anywhere]\n\"4-finger-hold\" = \"zoom-to-fit\"\n",
    );
    h.begin("hold", 4, "", "canvas", ON_CANVAS);
    let reply = h.end(false, 2000);
    assert_eq!(reply["fired"], json!({"action":"zoom-to-fit","error":null}));
    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
    assert_eq!(reply["needs_frames"], true);
}

#[test]
fn a_configured_doubletap_swipe_moves_the_window_under_the_pointer() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, MOVE_GESTURE);
    let reply = h.ok(begin("swipe", 3, "", "window", ON_WINDOW, true));
    assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
    assert_eq!(reply["gesture"]["window"], 1);
    assert_eq!(bindings(&reply), ["3-finger-doubletap-swipe = move-window"]);
    // Upstream focuses and raises what the gesture grabbed.
    assert_eq!(reply["effects"][0]["op"], "focus_native_window", "{reply}");
    assert_eq!(reply["effects"][0]["window"], 1);
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
    // The window follows the fingers one to one in screen points: no
    // trackpad_speed, exactly as upstream warps its cursor.
    h.swipe(30.0, 20.0, 1010);
    assert_eq!(h.origin(1), [130.0, 120.0]);
    h.swipe(-10.0, 5.0, 1020);
    assert_eq!(h.origin(1), [120.0, 125.0]);
    assert_eq!(h.camera(), [0.0, 0.0]);
    // The virtual pointer stops at the output's edge, as upstream's cursor does
    // with no neighbouring output: 999 - 200 points right of where it began.
    h.swipe(5000.0, 0.0, 1030);
    assert_eq!(h.origin(1), [100.0 + 799.0, 125.0]);
    h.swipe(-799.0, -25.0, 1040);
    assert_eq!(h.origin(1), [100.0, 100.0]);
    // While it lasts it is the one interactive move: the pointer cannot start another.
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":2,"output":1,"group":false})),
        "gesture already active"
    );
    h.swipe(12.0, 8.0, 1050);
    let reply = h.end(false, 1060);
    assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
    assert_eq!(reply["dirty"], true);
    assert_eq!(h.origin(1), [112.0, 108.0]);
    assert_eq!(h.origin(2), [2600.0, 1900.0]);
    // Nothing is left installed.
    h.ok(json!({"op":"begin_drag","window":2,"output":1,"group":false}));
    h.ok(json!({"op":"end_gesture"}));

    // Zoomed out, the same finger travel covers more canvas.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":point([LEFT, TOP])}));
    h.ok(begin(
        "swipe",
        3,
        "",
        "window",
        [LEFT + 100.0, TOP + 100.0],
        true,
    ));
    h.swipe(30.0, 20.0, 1010);
    assert_eq!(h.origin(1), [172.0, 148.0]);
    h.end(false, 1020);
}

#[test]
fn a_move_gesture_at_the_output_edge_pans_the_canvas_under_its_window() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, MOVE_GESTURE);
    let mut clock = 0;
    h.tick(&mut clock);
    let edge_pans = |h: &mut Host| h.snapshot()["navigation"]["edge_pans"].clone();
    h.ok(begin("swipe", 3, "", "window", ON_WINDOW, true));
    // Inside the output and outside navigation.edge_pan's zone of 100: no pan.
    let reply = h.swipe(30.0, 20.0, 1010);
    assert_eq!(reply["needs_frames"], false, "{reply}");
    assert_eq!(edge_pans(&mut h), json!({}));
    // The virtual pointer runs into the right edge and stops one point short
    // of it. Upstream's move grab arms its edge pan from the warped cursor;
    // by its ramp, at depth t into the zone, that is (4 + 6·t²)·t a frame.
    let reply = h.swipe(5000.0, 0.0, 1020);
    assert_eq!(reply["needs_frames"], true, "{reply}");
    let t: f64 = (100.0 - 1.0) / 100.0;
    let velocity = (4.0 + (10.0 - 4.0) * t * t) * t;
    assert_eq!(
        edge_pans(&mut h),
        json!({"1":{"velocity":{"x":velocity,"y":0.0},"screen":{"x":999.0,"y":220.0}}})
    );
    let held = h.origin(1);
    assert_eq!(held, [100.0 + 799.0, 120.0]);
    // Every frame pans the camera by that many screen points and carries the
    // window with it, so it stays under the resting fingers.
    let mut carried = 0.0;
    for _ in 0..3 {
        let tick = h.tick(&mut clock);
        assert_eq!(tick["changed_outputs"], json!([1]), "{tick}");
        assert_eq!(tick["needs_frames"], true);
        carried += velocity;
        assert_eq!(h.camera(), [carried, 0.0]);
        assert_close(h.origin(1), [held[0] + carried, held[1]]);
    }
    // Fingers that come back out of the zone disarm it; the travel stays.
    let reply = h.swipe(-300.0, 0.0, 1030);
    assert_eq!(reply["needs_frames"], false, "{reply}");
    assert_eq!(edge_pans(&mut h), json!({}));
    assert_close(h.origin(1), [held[0] - 300.0 + carried, held[1]]);
    // The end of the gesture releases the grab, and its edge pan with it.
    assert_eq!(h.swipe(5000.0, 0.0, 1040)["needs_frames"], true);
    let reply = h.end(false, 1050);
    assert_eq!(reply["needs_frames"], false, "{reply}");
    assert_eq!(edge_pans(&mut h), json!({}));
    let rest = (h.camera(), h.origin(1));
    assert_eq!(h.tick(&mut clock)["changed_outputs"], json!([]));
    assert_eq!((h.camera(), h.origin(1)), rest);
}

#[test]
fn a_window_that_closes_under_a_move_ends_its_drag_and_the_edge_pan_with_it() {
    let identity = |wid: u64| json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid});
    let closed = |h: &mut Host, window: u64| {
        h.ok(json!({"op":"window_closed","window":window,"identity":identity(window),"output":1}))
    };
    let edge_pans = |h: &mut Host| h.snapshot()["navigation"]["edge_pans"].clone();
    // A trackpad move rests at the output's edge: the canvas pans under it.
    let scratch = Scratch::new();
    let mut h = configured(&scratch, MOVE_GESTURE);
    attach(&mut h, 3, rect(100.0, 500.0, 200.0, 100.0));
    let mut clock = 0;
    h.tick(&mut clock);
    h.ok(begin("swipe", 3, "", "window", ON_WINDOW, true));
    assert_eq!(h.swipe(5000.0, 0.0, 1010)["needs_frames"], true);
    assert_eq!(h.tick(&mut clock)["changed_outputs"], json!([1]));
    // Another window closing ends no other window's grab: the pan goes on.
    closed(&mut h, 3);
    assert_ne!(edge_pans(&mut h), json!({}));
    assert_eq!(h.tick(&mut clock)["changed_outputs"], json!([1]));
    // The moved window closes: the drag is over as a release ends it, and its
    // edge pan with it, so the frame clock has nothing left to run.
    closed(&mut h, 1);
    assert_eq!(edge_pans(&mut h), json!({}));
    let rest = h.camera();
    let tick = h.tick(&mut clock);
    assert_eq!(tick["changed_outputs"], json!([]), "{tick}");
    assert_eq!(tick["needs_frames"], false);
    assert_eq!(h.camera(), rest);
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point([0.0, 0.0])})),
        "no active gesture"
    );
    // The fingers are still down. Their gesture goes on with nothing to move,
    // and neither it nor its end touches a drag the pointer begins meanwhile.
    assert_eq!(h.trackpad()["gesture"]["state"], "swipe_move");
    let reply = h.swipe(-40.0, 10.0, 1020);
    assert_eq!(reply["needs_frames"], false, "{reply}");
    h.ok(json!({"op":"begin_drag","window":2,"output":1,"group":false}));
    h.swipe(-40.0, 10.0, 1030);
    assert_eq!(h.origin(2), [2600.0, 1900.0]);
    h.end(false, 1040);
    h.ok(json!({"op":"gesture_to","screen_delta":point([5.0, 5.0])}));
    assert_eq!(h.origin(2), [2605.0, 1905.0]);
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.camera(), rest);

    // A button drag held at the edge is the same drag: its window closing
    // ends it and disarms the pan it armed.
    let mut h = setup();
    let mut clock = 0;
    h.tick(&mut clock);
    h.ok(json!({"op":"begin_drag","window":1,"output":1,"group":false}));
    let reply = h.ok(json!({"op":"gesture_to","screen_delta":point([700.0, 0.0]),"pointer":point([LEFT + 999.0, TOP + 200.0])}));
    assert_eq!(reply, json!({"needs_frames":true}));
    assert_eq!(h.tick(&mut clock)["changed_outputs"], json!([1]));
    closed(&mut h, 1);
    assert_eq!(edge_pans(&mut h), json!({}));
    let tick = h.tick(&mut clock);
    assert_eq!(tick["changed_outputs"], json!([]), "{tick}");
    assert_eq!(tick["needs_frames"], false);
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point([0.0, 0.0])})),
        "no active gesture"
    );
}

#[test]
fn doubletap_swipe_without_a_window_to_grab_is_a_plain_swipe() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, MOVE_GESTURE);
    // No tap before it: the three-finger swipe pans, over a window too.
    let reply = h.begin("swipe", 3, "", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    h.end(false, 2000);
    // The binding is on-window only: on canvas a doubletap-swipe is a swipe.
    let reply = h.ok(begin("swipe", 3, "", "canvas", ON_CANVAS, true));
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(bindings(&reply), ["3-finger-swipe = pan-viewport"]);
    h.end(false, 2000);
    // Upstream falls back to the swipe when nothing draggable is there.
    let reply = h.ok(begin("swipe", 3, "", "window", ON_CANVAS, true));
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(reply["effects"], json!([]));
    h.end(false, 2000);
    // Four fingers have no doubletap binding.
    let reply = h.ok(begin("swipe", 4, "", "window", ON_WINDOW, true));
    assert_eq!(reply["gesture"]["state"], "swipe_threshold", "{reply}");
    h.end(false, 2000);
    assert_eq!(h.origin(1), [100.0, 100.0]);
    assert_eq!(h.snapshot()["focus"]["intent"], Value::Null);
    // A pointer drag already holds the one interactive move.
    h.ok(json!({"op":"begin_drag","window":2,"output":1,"group":false}));
    let reply = h.ok(begin("swipe", 3, "", "window", ON_WINDOW, true));
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    h.end(false, 2000);
    h.ok(json!({"op":"gesture_to","screen_delta":point([5.0, 5.0])}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.origin(2), [2605.0, 1905.0]);
    // A pinch under a pointer drag zooms, as upstream zooms under a grab, and
    // leaves the dragged window where it is in the world.
    h.ok(json!({"op":"begin_drag","window":2,"output":1,"group":false}));
    let reply = h.begin("pinch", 3, "", "canvas", ON_CANVAS);
    assert_eq!(reply["gesture"]["state"], "pinch_zoom", "{reply}");
    h.pinch(0.5, 1010);
    h.end(false, 1020);
    assert_eq!(h.zoom(), 0.5);
    assert_eq!(h.origin(2), [2605.0, 1905.0]);
    h.ok(json!({"op":"end_gesture"}));
}

#[test]
fn modifiers_select_the_mod_and_alt_variants() {
    let mut h = setup();
    // Command selects mod+3-finger-swipe directional navigation.
    let reply = h.begin("swipe", 3, "⌘", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "swipe_threshold", "{reply}");
    assert_eq!(bindings(&reply), ["mod+3-finger-swipe = center-nearest"]);
    assert_eq!(reply["gesture"]["bindings"][0]["implemented"], true);
    // Nothing lies straight below the middle of the view: the action runs and
    // finds no window.
    let reply = h.swipe(0.0, -20.0, 1010);
    assert_ran(&reply, "center-nearest down");
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
    h.end(false, 1020);
    assert_eq!(h.camera(), [0.0, 0.0]);

    // alt+3-finger-swipe over a window is upstream's resize: its own
    // scenarios are at the end of this file. Both bindings resolve and run.
    for (held, combo, action) in [
        ("⌥", "alt+3-finger-swipe", "resize-window"),
        ("⌥⇧", "alt+shift+3-finger-swipe", "resize-window-snapped"),
    ] {
        let reply = h.begin("swipe", 3, held, "window", ON_WINDOW);
        assert_eq!(bindings(&reply), [format!("{combo} = {action}")]);
        assert_eq!(reply["gesture"]["bindings"][0]["implemented"], true);
        assert_eq!(reply["note"], Value::Null, "{reply}");
        h.end(false, 1020);
    }
    // The resize bindings are on-window: on canvas the chord has no swipe.
    let reply = h.begin("swipe", 3, "⌥", "canvas", ON_CANVAS);
    assert_eq!(reply["gesture"]["state"], "unbound", "{reply}");
    h.swipe(40.0, 40.0, 1010);
    h.end(false, 1020);
    assert_eq!(h.camera(), [0.0, 0.0]);
    // A chord no binding names is unbound, not the unmodified binding.
    for held in ["⇧", "⌃⌥", "⌃", "⌘⇧"] {
        let reply = h.begin("swipe", 3, held, "canvas", ON_CANVAS);
        assert_eq!(reply["gesture"]["state"], "unbound", "{held}: {reply}");
        h.end(false, 1020);
    }

    // Another super chord moves `mod` with it.
    h.ok(json!({"op":"set_platform","super":"ctrl+alt"}));
    let reply = h.begin("swipe", 3, "⌃⌥", "canvas", ON_CANVAS);
    assert_eq!(bindings(&reply), ["mod+3-finger-swipe = center-nearest"]);
    h.end(false, 1020);
    let reply = h.begin("swipe", 3, "⌘", "canvas", ON_CANVAS);
    assert_eq!(reply["gesture"]["state"], "unbound", "{reply}");
    h.end(false, 1020);
}

#[test]
fn a_cancelled_gesture_leaves_no_session_and_no_drag_behind() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, MOVE_GESTURE);
    let idle = json!({"enabled":true,"gesture":null,"coasting":[]});
    // A move keeps what it did, as upstream's grab does, and lets go.
    h.ok(begin("swipe", 3, "", "window", ON_WINDOW, true));
    h.swipe(30.0, 20.0, 1010);
    assert_eq!(
        h.trackpad()["gesture"],
        json!({"state":"swipe_move","output":1,"window":1})
    );
    let reply = h.end(true, 2000);
    assert_eq!(reply["gesture"]["cancelled"], true, "{reply}");
    assert_eq!(h.trackpad(), idle);
    assert_eq!(h.origin(1), [130.0, 120.0]);
    // Events after the end belong to no gesture and do nothing.
    let before = h.snapshot();
    for late in [
        h.swipe(50.0, 50.0, 2010),
        h.pinch(0.5, 2020),
        h.end(false, 2030),
    ] {
        assert_eq!(late["gesture"], Value::Null, "{late}");
        assert_eq!(late["fired"], Value::Null);
        assert_eq!(late["dirty"], false);
    }
    assert_eq!(h.snapshot(), before);
    h.ok(json!({"op":"begin_drag","window":1,"output":1,"group":false}));
    h.ok(json!({"op":"end_gesture"}));

    // A cancelled threshold swipe and pinch fire nothing, before or after.
    h.begin("swipe", 4, "", "canvas", ON_CANVAS);
    h.swipe(-11.0, 0.0, 1010);
    assert_eq!(h.end(true, 1020)["fired"], Value::Null);
    assert_eq!(h.swipe(-11.0, 0.0, 1030)["fired"], Value::Null);
    h.begin("pinch", 4, "", "canvas", ON_CANVAS);
    h.pinch(0.9, 1010);
    assert_eq!(h.end(true, 1020)["fired"], Value::Null);
    assert_eq!(h.trackpad(), idle);

    // A begin whose end was lost cancels the stale gesture instead of locking
    // every later one out, and its drag goes with it.
    h.ok(begin("swipe", 3, "", "window", ON_WINDOW, true));
    let reply = h.begin("hold", 4, "", "canvas", ON_CANVAS);
    assert_eq!(reply["gesture"]["state"], "hold", "{reply}");
    assert_eq!(reply["dirty"], true);
    h.ok(json!({"op":"begin_drag","window":1,"output":1,"group":false}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.end(true, 3000)["fired"], Value::Null);

    // The pointer path ending the drag, the window going away, and the output
    // going away each leave the gesture harmless.
    h.ok(begin("swipe", 3, "", "window", ON_WINDOW, true));
    h.ok(json!({"op":"end_gesture"}));
    let at = h.origin(1);
    h.swipe(30.0, 20.0, 1010);
    assert_eq!(h.origin(1), at);
    // A drag the pointer then begins, of another window or of the same one,
    // is the pointer's: the gesture neither drives it nor releases it.
    for window in [2, 1] {
        h.ok(json!({"op":"begin_drag","window":window,"output":1,"group":false}));
        h.swipe(40.0, 0.0, 1015);
        assert_eq!((h.origin(1), h.origin(2)), (at, [2600.0, 1900.0]));
        h.ok(json!({"op":"end_gesture"}));
    }
    h.ok(json!({"op":"begin_drag","window":2,"output":1,"group":false}));
    h.end(false, 1020);
    h.ok(json!({"op":"gesture_to","screen_delta":point([5.0, 5.0])}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.origin(2), [2605.0, 1905.0]);
    h.ok(begin(
        "swipe",
        3,
        "",
        "window",
        [LEFT + at[0] + 10.0, TOP + at[1] + 10.0],
        true,
    ));
    h.ok(json!({"op":"forget","window":1}));
    h.swipe(30.0, 20.0, 1010);
    h.end(false, 1020);
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    h.ok(json!({"op":"remove_output","output":1}));
    assert_eq!(h.trackpad(), idle);
    assert_eq!(h.swipe(30.0, 20.0, 1010)["gesture"], Value::Null);
}

#[test]
fn a_gestures_table_in_the_config_file_changes_the_bindings() {
    let scratch = Scratch::new();
    let mut h = configured(
        &scratch,
        r#"
[navigation]
trackpad_speed = 2.0
[zoom]
trackpad_speed = 2.0
[gestures]
swipe_threshold = 40.0
pinch_in_threshold = 0.5
pinch_out_threshold = 1.5
[gestures.anywhere]
"3-finger-swipe" = "none"
"4-finger-swipe" = "pan-viewport"
"4-finger-swipe-up" = "none"
"5-finger-swipe" = "zoom-to-fit"
"5-finger-swipe-left" = "home-toggle"
"5-finger-swipe-up" = "zoom-reset"
"4-finger-pinch-in" = "home-toggle"
"3-finger-hold" = "zoom-reset"
[gestures.on-window]
"3-finger-swipe" = "move-window"
"4-finger-swipe" = "home-toggle"
"3-finger-doubletap-swipe" = "none"
[gestures.on-canvas]
"4-finger-doubletap-swipe" = "move-snapped-windows"
"#,
    );
    h.ok(json!({"op":"pan","output":1,"screen_delta":point([5000.0, 5000.0])}));
    let home = [5000.0, 5000.0];
    // Unbound by "none": the default pan is gone on canvas.
    let reply = h.begin("swipe", 3, "", "canvas", [LEFT + 900.0, TOP + 700.0]);
    assert_eq!(reply["gesture"]["state"], "unbound", "{reply}");
    h.swipe(10.0, 10.0, 1010);
    h.end(false, 2000);
    assert_eq!(h.camera(), home);
    // Four fingers pan instead, by the file's speed.
    let reply = h.begin("swipe", 4, "", "canvas", ON_CANVAS);
    assert_eq!(bindings(&reply), ["4-finger-swipe = pan-viewport"]);
    h.swipe(10.0, -5.0, 1010);
    assert_eq!(h.camera(), [home[0] - 20.0, home[1] + 10.0]);
    h.swipe(-10.0, 5.0, 1020);
    h.end(false, 2000);
    // The pointer's own context table is asked before `anywhere`: over a
    // window the same four fingers are the on-window binding.
    let reply = h.begin("swipe", 4, "", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "swipe_threshold", "{reply}");
    assert_eq!(bindings(&reply), ["4-finger-swipe = home-toggle"]);
    h.end(false, 2000);
    // A named direction is physical and beats the bare swipe; the bare swipe
    // takes every other direction. The file's threshold is 40.
    let reply = h.begin("swipe", 5, "", "canvas", ON_CANVAS);
    assert_eq!(
        bindings(&reply),
        [
            "5-finger-swipe = zoom-to-fit",
            "5-finger-swipe-up = zoom-reset",
            "5-finger-swipe-left = home-toggle"
        ]
    );
    assert_eq!(h.swipe(-39.0, 0.0, 1010)["fired"], Value::Null);
    let reply = h.swipe(-1.0, 0.0, 1020);
    assert_eq!(reply["fired"], json!({"action":"home-toggle","error":null}));
    assert_eq!(
        reply["navigation"]["target_camera"],
        json!({"x":-500.0,"y":-400.0})
    );
    h.end(false, 1030);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    // The larger axis picks the named direction; right and down have none.
    for (dx, dy, action) in [
        (40.0, 0.0, "zoom-to-fit"),
        (0.0, 40.0, "zoom-to-fit"),
        (0.0, -40.0, "zoom-reset"),
        (-28.0, -29.0, "zoom-reset"),
        (-29.0, -28.0, "home-toggle"),
        (29.0, 28.0, "zoom-to-fit"),
    ] {
        h.begin("swipe", 5, "", "canvas", ON_CANVAS);
        let reply = h.swipe(dx, dy, 1010);
        assert_eq!(
            reply["fired"],
            json!({"action":action,"error":null}),
            "{dx} {dy}"
        );
        h.end(false, 1020);
        h.ok(json!({"op":"cancel_navigation","output":1}));
    }
    // The pinch thresholds and the rebound action are the file's.
    h.begin("pinch", 4, "", "canvas", ON_CANVAS);
    assert_eq!(h.pinch(0.51, 1010)["fired"], Value::Null);
    assert_eq!(h.pinch(1.49, 1020)["fired"], Value::Null);
    assert_eq!(
        h.pinch(0.49, 1030)["fired"],
        json!({"action":"home-toggle","error":null})
    );
    // Out keeps upstream's default action, at the file's threshold.
    assert_eq!(h.pinch(1.51, 1040)["fired"]["action"], "home-toggle");
    h.end(false, 1050);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    // zoom.trackpad_speed scales the pinch.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.8,"anchor":point(ON_CANVAS)}));
    h.begin("pinch", 3, "", "canvas", ON_CANVAS);
    h.pinch(0.9, 1010);
    assert!((h.zoom() - 0.8 * 0.8).abs() < 1e-12, "{}", h.zoom());
    h.end(false, 1020);
    h.ok(json!({"op":"zoom","output":1,"zoom":1.0,"anchor":point([LEFT, TOP])}));
    let camera = h.camera();
    h.ok(json!({"op":"pan","output":1,"screen_delta":point([-camera[0], -camera[1]])}));
    assert_eq!(h.pose(1), ([0.0, 0.0], 1.0));
    // A hold bound where upstream has none.
    h.begin("hold", 3, "", "canvas", ON_CANVAS);
    assert_eq!(h.end(false, 2000)["fired"]["action"], "zoom-reset");
    h.ok(json!({"op":"cancel_navigation","output":1}));

    // A plain swipe bound to move-window grabs the window, and pans when there
    // is none; the doubletap variant is unbound, so a tap changes nothing.
    for doubletap in [false, true] {
        let reply = h.ok(begin("swipe", 3, "", "window", ON_WINDOW, doubletap));
        assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
        assert_eq!(bindings(&reply), ["3-finger-swipe = move-window"]);
        h.swipe(10.0, 10.0, 1010);
        h.swipe(-10.0, -10.0, 1020);
        h.end(false, 1030);
    }
    let reply = h.begin("swipe", 3, "", "window", ON_CANVAS);
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(bindings(&reply), ["3-finger-swipe = move-window"]);
    h.end(false, 2000);
    // A doubletap-swipe on another finger count, here on canvas, where there
    // is nothing to grab: it falls through to that count's swipe.
    let reply = h.ok(begin("swipe", 4, "", "canvas", ON_CANVAS, true));
    assert_eq!(bindings(&reply), ["4-finger-swipe = pan-viewport"]);
    h.end(false, 2000);

    // Reloading the defaults puts upstream's table back.
    load(&mut h, &scratch, "");
    let reply = h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    assert_eq!(bindings(&reply), ["3-finger-swipe = pan-viewport"]);
    h.swipe(10.0, 0.0, 1010);
    assert_eq!(h.camera(), [-15.0, 0.0]);
    h.end(false, 2000);
    // disable_defaults leaves only the file's own gestures.
    load(
        &mut h,
        &scratch,
        "[bindings]\ndisable_defaults = [\"gestures\"]\n[gestures.on-canvas]\n\"3-finger-pinch\" = \"zoom\"\n",
    );
    for (kind, fingers) in [
        ("swipe", 3),
        ("swipe", 4),
        ("pinch", 4),
        ("hold", 4),
        ("pinch", 2),
    ] {
        let reply = h.begin(kind, fingers, "", "canvas", ON_CANVAS);
        assert_eq!(
            reply["gesture"]["state"], "unbound",
            "{kind} {fingers}: {reply}"
        );
        h.end(false, 2000);
    }
    assert_eq!(
        h.begin("pinch", 3, "", "canvas", ON_CANVAS)["gesture"]["state"],
        "pinch_zoom"
    );
    h.end(false, 2000);
    assert_eq!(
        h.begin("pinch", 3, "", "window", ON_WINDOW)["gesture"]["state"],
        "unbound"
    );
}

#[test]
fn set_trackpad_turns_gesture_dispatch_off_and_on() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, MOVE_GESTURE);
    assert_eq!(h.trackpad()["enabled"], true);
    // The action runs through the same dispatch as a key binding's.
    assert_eq!(
        h.action("set-trackpad off"),
        json!({"navigation":null,"effects":[],"dirty":false})
    );
    assert_eq!(h.trackpad()["enabled"], false);
    let before = h.snapshot();
    for (kind, fingers) in [
        ("swipe", 3),
        ("swipe", 4),
        ("pinch", 3),
        ("pinch", 4),
        ("hold", 4),
    ] {
        let reply = h.begin(kind, fingers, "", "canvas", ON_CANVAS);
        assert_eq!(reply["gesture"], Value::Null, "{reply}");
        assert_eq!(reply["trackpad"], false);
        for late in [
            h.swipe(-30.0, 0.0, 1010),
            h.pinch(0.5, 1020),
            h.end(false, 1030),
        ] {
            assert_eq!(late["gesture"], Value::Null);
            assert_eq!(late["fired"], Value::Null);
        }
    }
    assert_eq!(h.snapshot(), before);
    // off is idempotent; toggle flips; on is idempotent.
    for (action, enabled) in [
        ("set-trackpad off", false),
        ("set-trackpad toggle", true),
        ("set-trackpad on", true),
        ("set-trackpad toggle", false),
        ("set-trackpad TOGGLE", true),
    ] {
        h.action(action);
        assert_eq!(h.trackpad()["enabled"], enabled, "{action}");
    }
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    h.swipe(10.0, 0.0, 1010);
    h.end(false, 2000);
    assert_eq!(h.camera(), [-15.0, 0.0]);

    // Turning it off ends the gesture in progress, and its drag with it.
    h.ok(begin("swipe", 3, "", "window", ON_WINDOW, true));
    h.swipe(10.0, 10.0, 1010);
    // The move it ended changed the scene, and no gesture_end will say so.
    assert_eq!(h.action("set-trackpad off")["dirty"], true);
    assert_eq!(h.action("set-trackpad off")["dirty"], false);
    assert_eq!(h.trackpad()["gesture"], Value::Null);
    assert_eq!(h.swipe(10.0, 10.0, 1020)["gesture"], Value::Null);
    assert_eq!(h.origin(1), [110.0, 110.0]);
    h.ok(json!({"op":"begin_drag","window":1,"output":1,"group":false}));
    h.ok(json!({"op":"end_gesture"}));
    // Through IPC, upstream's `msg action`, too.
    let reply = h.ok(json!({"op":"ipc","output":1,"request":{"Action":"set-trackpad on"}}));
    assert_eq!(reply["reply"], json!({"Ok":"Ok"}), "{reply}");
    assert_eq!(h.trackpad()["enabled"], true);

    // [input.trackpad] enable is the seed, and a press outranks it until a
    // saved config changes the resulting state.
    load(&mut h, &scratch, "[input.trackpad]\nenable = true\n");
    h.action("set-trackpad off");
    load(
        &mut h,
        &scratch,
        "[input.trackpad]\nenable = true\n[navigation]\npan_step = 50\n",
    );
    assert_eq!(h.trackpad()["enabled"], false);
    load(&mut h, &scratch, "[input.trackpad]\nenable = false\n");
    assert_eq!(h.trackpad()["enabled"], false);
    assert_eq!(
        h.begin("swipe", 3, "", "canvas", ON_CANVAS)["gesture"],
        Value::Null
    );
    h.action("set-trackpad on");
    assert_eq!(h.trackpad()["enabled"], true);
    load(
        &mut h,
        &scratch,
        "[input.trackpad]\nenable = false\n[navigation]\npan_step = 60\n",
    );
    assert_eq!(h.trackpad()["enabled"], true);
    load(&mut h, &scratch, "");
    assert_eq!(h.trackpad()["enabled"], true);
    h.action("set-trackpad off");
    // A config that turns the trackpad off ends a gesture in progress.
    h.action("set-trackpad on");
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    h.swipe(10.0, 0.0, 1010);
    let path = scratch.write("config.toml", "[input.trackpad]\nenable = false\n");
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["dirty"], true, "{reply}");
    assert_eq!(
        h.ok(json!({"op":"load_config","path":path}))["dirty"],
        false
    );
    assert_eq!(
        h.trackpad(),
        json!({"enabled":false,"gesture":null,"coasting":[]})
    );
    // A gesture can bind the action itself: the hold that turns the trackpad off.
    load(
        &mut h,
        &scratch,
        "[gestures.anywhere]\n\"4-finger-hold\" = \"set-trackpad toggle\"\n",
    );
    assert_eq!(h.trackpad()["enabled"], true);
    h.begin("hold", 4, "", "canvas", ON_CANVAS);
    let reply = h.end(false, 2000);
    assert_eq!(
        reply["fired"],
        json!({"action":"set-trackpad toggle","error":null})
    );
    assert_eq!(reply["trackpad"], false);
    assert_eq!(
        h.begin("hold", 4, "", "canvas", ON_CANVAS)["gesture"],
        Value::Null
    );
    // The state is this run's: a scene load keeps it, and nothing saves it.
    let scene = scratch.write("scene.json", "");
    h.ok(json!({"op":"save","path":scene}));
    h.ok(json!({"op":"load","path":scene}));
    assert_eq!(h.trackpad()["enabled"], false);
    assert!(
        !std::fs::read_to_string(&scene)
            .unwrap()
            .contains("trackpad")
    );
}

#[test]
fn malformed_gesture_events_are_refused_and_change_nothing() {
    let mut h = setup();
    let good = begin("swipe", 3, "", "canvas", ON_CANVAS, false);
    let with = |key: &str, value: Value| {
        let mut command = good.clone();
        command[key] = value;
        command
    };
    assert_eq!(h.error(with("output", json!(9))), "unknown output");
    assert_eq!(h.error(with("time_ms", json!(-1))), "invalid gesture time");
    for bad in [
        with("kind", json!("rotate")),
        with("context", json!("anywhere")),
        with("fingers", json!(-3)),
        with("fingers", json!(2.5)),
        with("doubletap", json!(1)),
        with("modifiers", json!({"control":0})),
        with("pointer", json!("here")),
        with("surprise", json!(true)),
    ] {
        h.error(bad);
    }
    for key in [
        "kind",
        "fingers",
        "modifiers",
        "context",
        "output",
        "pointer",
        "time_ms",
    ] {
        let mut command = good.clone();
        command.as_object_mut().unwrap().remove(key);
        h.error(command);
    }
    // A fractional or integral time, and a missing `doubletap`, are fine.
    let mut command = with("time_ms", json!(1000.25));
    command.as_object_mut().unwrap().remove("doubletap");
    assert_eq!(h.ok(command)["gesture"]["state"], "swipe_pan");
    for bad in [
        json!({"op":"gesture_update","dx":1e300,"dy":0,"time_ms":1010}),
        json!({"op":"gesture_update","scale":0,"time_ms":1010}),
        json!({"op":"gesture_update","scale":-1.0,"time_ms":1010}),
        json!({"op":"gesture_update","dx":1.0,"dy":1.0}),
        json!({"op":"gesture_update","dx":"1","time_ms":1010}),
        json!({"op":"gesture_end","cancelled":0,"time_ms":1010}),
        json!({"op":"gesture_end","cancelled":false}),
    ] {
        h.error(bad);
    }
    // The gesture survived every refusal, and an update needs only its own fields.
    h.ok(json!({"op":"gesture_update","dx":10.0,"time_ms":1010}));
    h.ok(json!({"op":"gesture_update","scale":0.5,"rotation":12.0,"time_ms":1020}));
    assert_eq!(h.pose(1), ([-15.0, 0.0], 1.0));
    assert_eq!(
        h.ok(json!({"op":"gesture_end","time_ms":3000}))["gesture"]["cancelled"],
        false
    );
}

/// The event stream's line while a camera coasts: the shell asks once a frame.
#[test]
fn a_coast_changes_the_state_event_every_frame_and_not_at_rest() {
    let mut h = setup();
    let mut clock = 1_000_000_000;
    h.tick(&mut clock);
    let event = |h: &mut Host| h.ok(json!({"op":"state_event","output":1}))["line"].clone();
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    for step in 1..=6 {
        h.swipe(-20.0, 0.0, 1000 + step * 8);
    }
    assert_eq!(h.end(false, 1056)["needs_frames"], true);
    // The pan itself is news once, however often it is asked for.
    assert!(event(&mut h).is_string());
    assert_eq!(event(&mut h), Value::Null);
    // Every frame of the coast moves the camera the State reports, so each is
    // one new line and never two; at rest there is nothing to send.
    let (mut frames, mut last) = (0, String::new());
    loop {
        let tick = h.tick(&mut clock);
        if tick["changed_outputs"] == json!([]) {
            assert_eq!(tick["needs_frames"], false, "{tick}");
            break;
        }
        let line = event(&mut h);
        let line = line
            .as_str()
            .unwrap_or_else(|| panic!("frame {frames}: {tick}"));
        assert_ne!(line, last);
        last = line.to_owned();
        assert_eq!(event(&mut h), Value::Null);
        frames += 1;
        assert!(frames < 2000, "the coast never stopped");
    }
    assert!(frames > 5, "{frames}");
    assert_eq!(event(&mut h), Value::Null);
    h.tick(&mut clock);
    assert_eq!(event(&mut h), Value::Null);
}

/// A bound output corner, the fourth way an action is run.
#[test]
fn a_hot_corner_action_stops_the_coast_like_any_other() {
    let scratch = Scratch::new();
    let mut h = configured(
        &scratch,
        "[[outputs]]\nname = \"*\"\n[outputs.hot_corners]\ntop_left = \"center-nearest down\"\n",
    );
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    for step in 1..=6 {
        h.swipe(-20.0, 0.0, 1000 + step * 8);
    }
    assert_eq!(h.end(false, 1056)["needs_frames"], true);
    assert_eq!(h.trackpad()["coasting"], json!([1]));
    // An unbound corner runs nothing, so nothing stops.
    h.ok(json!({"op":"hot_corner","output":1,"corner":"top_right"}));
    assert_eq!(h.trackpad()["coasting"], json!([1]));
    h.ok(json!({"op":"hot_corner","output":1,"corner":"top_left"}));
    assert_eq!(h.trackpad()["coasting"], json!([]));
}

#[test]
fn a_gesture_runs_window_navigation_with_its_pointer_and_the_modifiers_it_fires_under() {
    let scratch = Scratch::new();
    let mut h = configured(
        &scratch,
        r#"
[gestures.anywhere]
"4-finger-hold" = "focus-center"
"4-finger-swipe-left" = "cycle-windows forward"
"4-finger-swipe-right" = "cycle-windows backward"
"4-finger-pinch-in" = "zoom-in"
"#,
    );
    let focus = |h: &mut Host| h.snapshot()["focus"].clone();

    // focus-center reads the pointer the gesture began under, exactly as the
    // action command reads its `pointer`: over window 1 that window is flown
    // to at zoom 1 and focused, over empty canvas nothing is found.
    let reply = h.begin("hold", 4, "", "canvas", ON_CANVAS);
    assert_eq!(bindings(&reply), ["4-finger-hold = focus-center"]);
    assert_eq!(reply["gesture"]["bindings"][0]["implemented"], true);
    let reply = h.end(false, 2000);
    assert_ran(&reply, "focus-center");
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
    assert_eq!(reply["effects"], json!([]));
    assert_eq!(h.snapshot()["focus"]["intent"], Value::Null);
    // The action a gesture fires stops the output's coast before it runs, as
    // every action does, also when it then finds nothing to do. A hold's
    // begin stops nothing, so the stop is the action's.
    h.begin("swipe", 3, "", "canvas", ON_CANVAS);
    for step in 1..=6 {
        h.swipe(-20.0, 0.0, 3000 + step * 8);
    }
    assert_eq!(h.end(false, 3056)["needs_frames"], true);
    assert_eq!(
        h.begin("hold", 4, "", "canvas", ON_CANVAS)["needs_frames"],
        true
    );
    assert_eq!(h.trackpad()["coasting"], json!([1]));
    let reply = h.end(false, 4000);
    assert_ran(&reply, "focus-center");
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
    assert_eq!(reply["needs_frames"], false);
    assert_eq!(h.trackpad()["coasting"], json!([]));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point([-180.0, 0.0])}));
    assert_eq!(h.camera(), [0.0, 0.0]);
    h.begin("hold", 4, "", "window", ON_WINDOW);
    let reply = h.end(false, 3000);
    assert_ran(&reply, "focus-center");
    assert_eq!(
        reply["navigation"]["target_camera"],
        point([-200.0, -150.0])
    );
    assert_eq!(reply["navigation"]["target_zoom"], 1.0);
    let first = focus_effect(&reply, 1);
    assert_eq!(reply["dirty"], true);
    confirm(&mut h, &first);
    // The same pointer given to the action command asks for the same window.
    let command =
        h.ok(json!({"op":"action","output":1,"action":"focus-center","pointer":point(ON_WINDOW)}));
    assert_eq!(
        command["navigation"]["target_camera"],
        reply["navigation"]["target_camera"]
    );
    confirm(&mut h, &focus_effect(&command, 1));
    h.ok(json!({"op":"cancel_navigation","output":1}));
    let effect = h.ok(json!({"op":"focus","window":2}))["effect"].clone();
    confirm(&mut h, &effect);
    assert_eq!(focus(&mut h)["history"], json!([2, 1]));

    // cycle-windows from a gesture. Fingers left with no modifier down is one
    // committed step, as a key binding fired without one is.
    let swipe = |h: &mut Host, dx: f64, held: Value| {
        let reply = h.begin("swipe", 4, "", "canvas", ON_CANVAS);
        assert_eq!(reply["gesture"]["state"], "swipe_threshold", "{reply}");
        let mut update = json!({"op":"gesture_update","dx":dx,"dy":0.0,"time_ms":1010});
        if !held.is_null() {
            update["held"] = held;
        }
        let reply = h.ok(update);
        h.end(false, 1020);
        reply
    };
    let reply = swipe(&mut h, -20.0, Value::Null);
    assert_ran(&reply, "cycle-windows forward");
    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
    let step = focus_effect(&reply, 1);
    assert_eq!(focus(&mut h)["release_pending"], true);
    confirm(&mut h, &step);
    assert_eq!(focus(&mut h)["cycle"], Value::Null);
    assert_eq!(focus(&mut h)["history"], json!([1, 2]));
    // `held` false is the same.
    let reply = swipe(&mut h, -20.0, json!(false));
    confirm(&mut h, &focus_effect(&reply, 2));
    assert_eq!(focus(&mut h)["cycle"], Value::Null);
    assert_eq!(focus(&mut h)["history"], json!([2, 1]));
    // With a real modifier down as the swipe fires, the session stays open
    // until the shell reports the modifiers let go.
    let reply = swipe(&mut h, -20.0, json!(true));
    assert_ran(&reply, "cycle-windows forward");
    confirm(&mut h, &focus_effect(&reply, 1));
    assert_eq!(focus(&mut h)["cycle"], 1);
    assert_eq!(focus(&mut h)["history"], json!([2, 1]));
    // Fingers right step back while it is open.
    let reply = swipe(&mut h, 20.0, json!(true));
    assert_ran(&reply, "cycle-windows backward");
    confirm(&mut h, &focus_effect(&reply, 2));
    assert_eq!(focus(&mut h)["cycle"], 0);
    let reply = swipe(&mut h, -20.0, json!(true));
    confirm(&mut h, &focus_effect(&reply, 1));
    h.ok(json!({"op":"end_focus_cycle"}));
    assert_eq!(focus(&mut h)["cycle"], Value::Null);
    assert_eq!(focus(&mut h)["history"], json!([1, 2]));

    // Any other action a gesture fires ends an open cycle first, committing
    // the confirmed selection, as upstream's execute_action does for every
    // input source.
    let reply = swipe(&mut h, -20.0, json!(true));
    confirm(&mut h, &focus_effect(&reply, 2));
    assert_eq!(focus(&mut h)["cycle"], 1);
    assert_eq!(focus(&mut h)["history"], json!([1, 2]));
    h.begin("pinch", 4, "", "canvas", ON_CANVAS);
    let reply = h.ok(json!({"op":"gesture_update","scale":0.5,"time_ms":1010,"held":true}));
    assert_ran(&reply, "zoom-in");
    h.end(false, 1020);
    assert_eq!(focus(&mut h)["cycle"], Value::Null);
    assert_eq!(focus(&mut h)["history"], json!([2, 1]));
    // A hold's action takes `held` from the event that fires it, its end.
    let scratch = Scratch::new();
    let mut h = configured(
        &scratch,
        "[gestures.anywhere]\n\"4-finger-hold\" = \"cycle-windows forward\"\n",
    );
    for window in [1, 2] {
        let effect = h.ok(json!({"op":"focus","window":window}))["effect"].clone();
        confirm(&mut h, &effect);
    }
    h.begin("hold", 4, "⌥", "canvas", ON_CANVAS);
    assert_eq!(h.trackpad()["gesture"]["state"], "unbound");
    h.end(false, 2000);
    h.begin("hold", 4, "", "canvas", ON_CANVAS);
    let reply = h.ok(json!({"op":"gesture_end","time_ms":2000,"held":true}));
    assert_ran(&reply, "cycle-windows forward");
    confirm(&mut h, &focus_effect(&reply, 1));
    assert_eq!(focus(&mut h)["cycle"], 1);
    // `held` is a boolean.
    h.begin("hold", 4, "", "canvas", ON_CANVAS);
    for bad in [
        json!({"op":"gesture_end","time_ms":3000,"held":1}),
        json!({"op":"gesture_update","time_ms":3000,"held":"true"}),
    ] {
        h.error(bad);
    }
}

/// Desktop defaults, row by row, including the adapter overrides and
/// Command as the default super chord. Reports are controller evidence alone.
#[test]
fn the_default_table_on_a_mac() {
    // kind, fingers, physical modifiers, context, after a three-finger tap.
    let rows = [
        ("swipe", 3, "", "canvas", false),
        ("swipe", 4, "", "canvas", false),
        ("swipe", 3, "⌘", "canvas", false),
        ("swipe", 3, "", "window", true),
        ("swipe", 3, "⌥", "window", false),
        ("swipe", 3, "⌥⇧", "window", false),
        ("pinch", 2, "", "canvas", false),
        ("pinch", 2, "", "window", false),
        ("pinch", 2, "⌘", "window", false),
        ("pinch", 3, "", "window", false),
        ("pinch", 4, "", "canvas", false),
        ("pinch", 3, "⌘", "canvas", false),
        ("pinch", 4, "⌘", "canvas", false),
        ("pinch", 2, "⌥", "window", false),
        ("pinch", 2, "⌥⇧", "window", false),
        ("pinch", 3, "⌥", "window", false),
        ("hold", 4, "", "canvas", false),
        ("hold", 3, "⌘", "canvas", false),
    ];
    let mut seen = Vec::new();
    for (kind, fingers, held, context, doubletap) in rows {
        let mut h = setup();
        let at = if context == "window" {
            ON_WINDOW
        } else {
            ON_CANVAS
        };
        let reply = h.ok(begin(kind, fingers, held, context, at, doubletap));
        for binding in reply["gesture"]["bindings"].as_array().unwrap() {
            let here = if binding["implemented"] == true {
                "runs"
            } else {
                "refused"
            };
            seen.push(format!(
                "{} = {}: {here}",
                binding["combo"].as_str().unwrap(),
                binding["action"].as_str().unwrap()
            ));
        }
        if doubletap {
            assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
            assert_eq!(reply["effects"], json!([]));
            h.swipe(20.0, 10.0, 1010);
            assert_eq!(h.camera(), [-30.0, -15.0]);
            assert_eq!(h.origin(1), [100.0, 100.0]);
            assert_eq!(h.origin(2), [2600.0, 1900.0]);
            assert_eq!(h.snapshot()["focus"]["intent"], Value::Null);
        }
    }
    assert_eq!(
        seen,
        [
            "3-finger-swipe = pan-viewport: runs",
            "4-finger-swipe = center-nearest: runs",
            "4-finger-swipe-up = zoom-to-fit: runs",
            "mod+3-finger-swipe = center-nearest: runs",
            "3-finger-swipe = pan-viewport: runs",
            "alt+3-finger-swipe = resize-window: runs",
            "alt+shift+3-finger-swipe = resize-window-snapped: runs",
            "2-finger-pinch = zoom: runs",
            "2-finger-pinch = zoom: runs",
            "mod+2-finger-pinch = zoom: runs",
            "3-finger-pinch = zoom: runs",
            "4-finger-pinch-in = zoom-to-fit: runs",
            "4-finger-pinch-out = home-toggle: runs",
            "mod+3-finger-pinch-in = zoom-to-fit: runs",
            "mod+3-finger-pinch-out = home-toggle: runs",
            "mod+4-finger-pinch-in = zoom-to-fit-snapped: runs",
            "alt+2-finger-pinch-in = fit-window: refused",
            "alt+2-finger-pinch-out = fit-window: refused",
            "alt+shift+2-finger-pinch-in = fit-window-snapped: refused",
            "alt+shift+2-finger-pinch-out = fit-window-snapped: refused",
            "alt+3-finger-pinch-in = toggle-fullscreen: refused",
            "alt+3-finger-pinch-out = toggle-fullscreen: refused",
            "4-finger-hold = center-window: runs",
            "mod+3-finger-hold = center-window: runs",
        ]
    );
    // The adapter adds bare on-window pinch and four-finger swipe-up.
    // Doubletap pan resolves through plain swipe, so the row count stays the same.
    let gestures = Config::default().gestures;
    assert_eq!(
        gestures.on_window.len() + gestures.on_canvas.len() + gestures.anywhere.len() + 2,
        seen.len()
    );
}

// Upstream's resize gesture (try_start_gesture_resize, the SwipeResize arms
// of on_gesture_swipe_update and _end), on the readback path every normal run
// has. These drive the controller alone: nothing here shows a trackpad, a
// native window or the shell performing a size request.
fn readback() -> Host {
    let mut h = setup();
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    h
}
/// The adapter's answer to a size effect: what was read back from the window.
fn sized(h: &mut Host, effect: &Value, outcome: &str, size: [f64; 2]) -> Value {
    let setter = !effect["requested"].is_null();
    let actual = rect(4000.0, 3000.0, size[0], size[1]);
    h.ok(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":outcome,"ax_error":0,"mutation_attempted":setter,"observed":true,"requested":if setter{effect["requested"].clone()}else{json!({"width":0.0,"height":0.0})},"actual_ax":actual,"actual_cg":actual}}))
}
fn world(h: &mut Host, window: u64) -> Value {
    let snapshot = h.snapshot();
    let windows = snapshot["windows"].as_array().unwrap();
    windows.iter().find(|w| w["window"] == window).unwrap()["world_rect"].clone()
}
fn size(w: f64, h: f64) -> Value {
    json!({"width":w,"height":h})
}

// ON_WINDOW is (100, 100) inside window 1's 400 x 300: the left third, the
// middle row. Upstream's edges_from_position makes that a resize of the left
// edge alone, whose opposite edge, the right one at x = 500, must stay.
#[test]
fn a_resize_swipe_asks_each_size_of_the_window_and_shows_the_size_it_took() {
    let mut h = readback();
    let reply = h.begin("swipe", 3, "⌥", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "swipe_resize", "{reply}");
    assert_eq!(reply["gesture"]["window"], 1);
    assert_eq!(reply["note"], Value::Null);
    // Raised and focused, and one read of the window before any size is asked.
    focus_effect(&reply, 1);
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
    let read = reply["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source", "{reply}");
    assert_eq!(h.snapshot()["native_resize"]["edges"], "left");
    // Motion before the answer takes the one latest-request slot.
    assert_eq!(h.swipe(-10.0, 0.0, 1010)["effect"], Value::Null);
    assert_eq!(h.swipe(-10.5, 7.0, 1020)["effect"], Value::Null);
    // The baseline answers: the latest size is asked, once. 20.5 screen
    // points at zoom 1 are 20 whole units (upstream's `as i32`), and the
    // vertical motion means nothing to a left edge.
    let setter = sized(&mut h, &read, "observed", [400.0, 300.0])["effect"].clone();
    assert_eq!(setter["op"], "resize_native_window");
    assert_eq!(setter["requested"], size(420.0, 300.0));
    // More motion while that setter is out: nothing is sent.
    assert_eq!(h.swipe(-20.0, 0.0, 1030)["effect"], Value::Null);
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    // It answers: the canvas takes the size, the right edge stays, and the
    // newer size goes out.
    let next = sized(&mut h, &setter, "applied", [420.0, 300.0])["effect"].clone();
    assert_eq!(world(&mut h, 1), rect(80.0, 100.0, 420.0, 300.0));
    assert_eq!(next["requested"], size(440.0, 300.0));
    // The window grants less than was asked: what it took is what is shown.
    assert_eq!(
        sized(&mut h, &next, "clamped", [432.0, 300.0])["effect"],
        Value::Null
    );
    assert_eq!(world(&mut h, 1), rect(68.0, 100.0, 432.0, 300.0));
    // A swipe that asks nothing new of a window at rest sends nothing.
    assert_eq!(h.swipe(0.0, 5.0, 1040)["effect"], Value::Null);
    // The end is a release: one last read, and the transaction completes.
    let reply = h.end(false, 1050);
    let last = reply["effect"].clone();
    assert_eq!(last["op"], "observe_resize_source", "{reply}");
    assert_eq!(reply["dirty"], true);
    sized(&mut h, &last, "observed", [432.0, 300.0]);
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(world(&mut h, 1), rect(68.0, 100.0, 432.0, 300.0));
    assert_eq!(h.trackpad()["gesture"], Value::Null);
}

// Upstream ends the grab the same way for a cancelled swipe: what was asked
// stays asked, and the transaction still completes.
#[test]
fn a_cancelled_resize_swipe_still_completes_and_the_pointer_is_held_inside_the_output() {
    let mut h = readback();
    let reply = h.begin("swipe", 3, "⌥", "window", ON_WINDOW);
    let read = reply["effect"].clone();
    sized(&mut h, &read, "observed", [400.0, 300.0]);
    // The virtual pointer starts 200 points inside the output's left edge
    // and cannot leave it: a swipe of 5000 to the left is 200.
    let setter = h.swipe(-5000.0, 0.0, 1010)["effect"].clone();
    assert_eq!(setter["requested"], size(600.0, 300.0));
    let reply = h.end(true, 1020);
    assert_eq!(reply["gesture"]["cancelled"], true);
    assert_eq!(reply["effect"], Value::Null, "{reply}");
    let last = sized(&mut h, &setter, "applied", [600.0, 300.0])["effect"].clone();
    assert_eq!(last["op"], "observe_resize_source");
    sized(&mut h, &last, "observed", [600.0, 300.0]);
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(world(&mut h, 1), rect(-100.0, 100.0, 600.0, 300.0));
}

// resize-window-snapped: a window a snap gap to the left of window 1 follows
// its left edge by what the window took, not by what was asked, and its own
// size is never asked for.
#[test]
fn a_snapped_resize_swipe_shifts_the_cluster_by_the_size_the_window_took() {
    let mut h = readback();
    attach(&mut h, 3, rect(-212.0, 100.0, 300.0, 300.0));
    let reply = h.begin("swipe", 3, "⌥⇧", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "swipe_resize", "{reply}");
    assert_eq!(h.snapshot()["native_resize"]["group"], true);
    let read = reply["effect"].clone();
    sized(&mut h, &read, "observed", [400.0, 300.0]);
    let setter = h.swipe(-60.0, 0.0, 1010)["effect"].clone();
    assert_eq!(setter["requested"], size(460.0, 300.0));
    assert_eq!(setter["window"], 1);
    // Nothing moves before the answer.
    assert_eq!(world(&mut h, 3), rect(-212.0, 100.0, 300.0, 300.0));
    sized(&mut h, &setter, "clamped", [440.0, 300.0]);
    assert_eq!(world(&mut h, 1), rect(60.0, 100.0, 440.0, 300.0));
    assert_eq!(world(&mut h, 3), rect(-252.0, 100.0, 300.0, 300.0));
    let last = h.end(false, 1020)["effect"].clone();
    sized(&mut h, &last, "observed", [440.0, 300.0]);
    assert_eq!(world(&mut h, 3), rect(-252.0, 100.0, 300.0, 300.0));
    // The plain binding leaves the neighbour where it is.
    let reply = h.begin("swipe", 3, "⌥", "window", [LEFT + 70.0, TOP + 200.0]);
    assert_eq!(h.snapshot()["native_resize"]["group"], false, "{reply}");
    let read = reply["effect"].clone();
    sized(&mut h, &read, "observed", [440.0, 300.0]);
    // The left edge rests a snap gap from the neighbour: a short swipe is
    // held by that snap and asks nothing, a long one breaks away.
    assert_eq!(h.swipe(-20.0, 0.0, 1030)["effect"], Value::Null);
    let setter = h.swipe(-80.0, 0.0, 1040)["effect"].clone();
    sized(&mut h, &setter, "applied", [540.0, 300.0]);
    assert_eq!(world(&mut h, 1), rect(-40.0, 100.0, 540.0, 300.0));
    assert_eq!(world(&mut h, 3), rect(-252.0, 100.0, 300.0, 300.0));
}

// Upstream's `false` from try_start_gesture_resize: the swipe pans, and
// nothing was raised, focused or begun for the resize that was refused.
#[test]
fn a_resize_swipe_that_cannot_begin_pans_and_a_pinned_window_resizes() {
    let mut h = readback();
    // A stand-in has no window to ask a size of.
    h.ok(json!({"op":"remove_source","window":1,"identity":{"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":1},"keep_placeholder":true}));
    let reply = h.begin("swipe", 3, "⌥", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(reply["effects"], json!([]));
    assert!(reply.get("transaction").is_none(), "{reply}");
    assert_eq!(h.snapshot()["focus"]["intent"], Value::Null);
    assert_eq!(h.snapshot()["native_resize"], Value::Null);
    h.swipe(-30.0, 0.0, 1010);
    h.end(false, 1020);
    assert_eq!(world(&mut h, 1), rect(100.0, 100.0, 400.0, 300.0));
    // Empty canvas: pan, as upstream.
    let reply = h.begin("swipe", 3, "⌥", "window", ON_CANVAS);
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    h.end(false, 1030);
    // A size transaction already holds the one slot: pan.
    let mut h = readback();
    h.ok(json!({"op":"ipc","output":1,"request":{"Resize":{"window":2,"to":[320,220]}}}));
    let reply = h.begin("swipe", 3, "⌥", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(h.snapshot()["focus"]["intent"], Value::Null);
    h.end(false, 1040);
    // Pinned swipe resizing uses the same native transaction in screen points.
    let mut h = readback();
    h.ok(json!({"op":"focus","window":1}));
    h.action("toggle-pin-to-screen");
    let reply = h.begin("swipe", 3, "⌥", "window", ON_WINDOW);
    assert_eq!(reply["gesture"]["state"], "swipe_resize", "{reply}");
    assert_eq!(reply["note"], Value::Null);
    let read = reply["effect"].clone();
    assert_eq!(h.snapshot()["native_resize"]["screen_space"], true);
    sized(&mut h, &read, "observed", [400., 300.]);
    let set = h.swipe(40., 40., 1010)["effect"].clone();
    let size = set["requested"].clone();
    assert!(size["width"].as_f64().is_some());
    sized(
        &mut h,
        &set,
        "applied",
        [
            size["width"].as_f64().unwrap(),
            size["height"].as_f64().unwrap(),
        ],
    );
    let end = h.end(false, 1020)["effect"].clone();
    sized(
        &mut h,
        &end,
        "observed",
        [
            size["width"].as_f64().unwrap(),
            size["height"].as_f64().unwrap(),
        ],
    );
}
