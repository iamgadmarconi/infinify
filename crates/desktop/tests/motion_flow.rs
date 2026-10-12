// SPDX-License-Identifier: GPL-3.0-or-later
//! Camera-motion scenarios cross the exported C ABI and JSON decoder: timed
//! pans, their launch and the frames that follow, edge pans, cursor edge pan
//! and pointer zoom. Momentum is compared bit for bit with driftwm-core's
//! `MomentumState`, upstream's own code, fed the same deltas and frame times.
//! Config files live in a throwaway directory. Nothing here shows that the
//! shell sends these commands, that a scroll or pinch reaches it, or that a
//! frame is drawn.
use driftwm_core::canvas::MomentumState;
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

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
    fn output(&mut self, output: u64) -> Value {
        let snapshot = self.snapshot();
        let found = snapshot["outputs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["id"] == output);
        found.unwrap().clone()
    }
    fn camera(&mut self, output: u64) -> (f64, f64) {
        xy(&self.output(output)["camera"])
    }
    fn zoom(&mut self, output: u64) -> f64 {
        self.output(output)["zoom"].as_f64().unwrap()
    }
    fn world(&mut self, window: u64) -> Value {
        let snapshot = self.snapshot();
        let found = snapshot["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == window);
        found.unwrap()["world_rect"].clone()
    }
    fn motion(&mut self) -> Value {
        self.snapshot()["navigation"].clone()
    }
    fn load_config(&mut self, path: &PathBuf) {
        let reply = self.ok(json!({"op":"load_config","path":path}));
        assert_eq!(reply["errors"], json!([]), "{reply}");
        assert_eq!(reply["warnings"], json!([]), "{reply}");
    }
    /// One frame at `at` nanoseconds.
    fn tick(&mut self, at: u64) -> Value {
        self.ok(json!({"op":"tick_navigation","timestamp_ns":at}))
    }
    /// A pan with its event time, which may lie past upstream's u32 clock.
    fn pan_at(&mut self, output: u64, delta: (f64, f64), time_ms: u64, source: Option<&str>) {
        let mut command = json!({"op":"pan","output":output,"screen_delta":point(delta.0, delta.1),"time_ms":time_ms});
        if let Some(source) = source {
            command["source"] = json!(source);
        }
        assert_eq!(self.ok(command), json!({}));
    }
    fn coasting(&mut self, output: u64) -> bool {
        self.motion()["momentum"][output.to_string()]["coasting"] == true
    }
    /// Move the gesture's pointer by `delta` in all, to `pointer` on output 1.
    fn drag_to(&mut self, delta: (f64, f64), pointer: Option<(f64, f64)>) -> Value {
        let mut command = json!({"op":"gesture_to","screen_delta":point(delta.0, delta.1)});
        if let Some((x, y)) = pointer {
            command["pointer"] = global(x, y);
        }
        self.ok(command)
    }
    /// Report the pointer at a point local to output 1.
    fn pointer(&mut self, x: f64, y: f64) -> Value {
        self.ok(json!({"op":"pointer","output":1,"screen":global(x, y)}))
    }
    /// Where the window's top-left corner is drawn on the output.
    fn drawn(&mut self, window: u64, output: u64) -> (f64, f64) {
        let snapshot = self.snapshot();
        let found = snapshot["placements"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["window"] == window && p["output"] == output);
        xy(&found.unwrap()["screen_rect"]["origin"])
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
            "infinify-motion-flow-{}-{}",
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

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn point(x: f64, y: f64) -> Value {
    json!({"x":x,"y":y})
}
fn xy(point: &Value) -> (f64, f64) {
    (point["x"].as_f64().unwrap(), point["y"].as_f64().unwrap())
}
fn bits(point: (f64, f64)) -> (u64, u64) {
    (point.0.to_bits(), point.1.to_bits())
}
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid})
}
fn attach(h: &mut Host, wid: u64, world: Value) -> u64 {
    h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"world_rect":world}))["window"].as_u64().unwrap()
}
/// The global origin of output 1: a 1000 x 800 screen that is not at (0,0).
const ORIGIN: (f64, f64) = (200.0, 100.0);
/// Output 1 with the given config file in force and the frame clock started.
fn configured(scratch: &Scratch, toml: &str) -> Host {
    let mut h = Host::new();
    h.ok(json!({"op":"register_output","stable_id":"view","screen_bounds":rect(ORIGIN.0,ORIGIN.1,1000.0,800.0)}));
    h.load_config(&scratch.write("config.toml", toml));
    h.tick(0);
    h
}
/// A global screen point from a point local to output 1.
fn global(x: f64, y: f64) -> Value {
    point(ORIGIN.0 + x, ORIGIN.1 + y)
}

/// A hand scrolling and then flicking: screen deltas and event times.
const FLICK: [((f64, f64), u32); 9] = [
    ((-3.0, 1.0), 1000),
    ((-6.5, 2.25), 1008),
    ((-11.0, 3.0), 1016),
    ((-17.5, 4.5), 1024),
    ((-24.0, 7.0), 1033),
    ((-31.25, 9.0), 1041),
    ((-38.0, 12.5), 1049),
    ((-44.0, 13.0), 1058),
    ((-47.5, 15.75), 1066),
];
/// Frame intervals in nanoseconds: 60 Hz, 120 Hz, a stall past the 33 ms cap,
/// and a repeated timestamp.
const FRAMES: [u64; 6] = [16_666_667, 8_333_333, 16_666_667, 50_000_000, 0, 11_111_111];

/// Pan `FLICK` on output 1, at event times `epoch` later, and lift. Every
/// camera on the way must be the one upstream's drift_pan gives. Returns
/// upstream's momentum, fed the same world deltas and launched, and the camera
/// at the lift.
fn throw(
    h: &mut Host,
    source: Option<&str>,
    speed: f64,
    drift: f64,
    epoch: u64,
) -> (MomentumState, (f64, f64)) {
    let zoom = h.zoom(1);
    let mut oracle = MomentumState::new(drift);
    let mut camera = h.camera(1);
    for (delta, at) in FLICK {
        let at = epoch + u64::from(at);
        h.pan_at(1, delta, at, source);
        let world = (delta.0 * speed / zoom, delta.1 * speed / zoom);
        oracle.accumulate(world.into(), at as u32);
        camera = (camera.0 + world.0, camera.1 + world.1);
        assert_eq!(bits(h.camera(1)), bits(camera), "{source:?} {at}");
        assert!(!h.coasting(1));
    }
    assert_eq!(
        h.ok(json!({"op":"pan_end","output":1})),
        json!({"needs_frames":true})
    );
    oracle.launch();
    (oracle, camera)
}
/// Run frames until nothing coasts, or `frames` of them. Every camera must be
/// the one upstream's momentum gives for the same frame times.
fn coast(
    h: &mut Host,
    clock: &mut u64,
    oracle: &mut MomentumState,
    camera: &mut (f64, f64),
    frames: usize,
) {
    for frame in 0..frames {
        if !oracle.coasting {
            return;
        }
        let elapsed = FRAMES[frame % FRAMES.len()];
        *clock += elapsed;
        let tick = h.tick(*clock);
        let before = *camera;
        if let Some(delta) = oracle.tick(Duration::from_nanos(elapsed.min(33_000_000))) {
            *camera = (camera.0 + delta.x, camera.1 + delta.y);
        }
        assert_eq!(bits(h.camera(1)), bits(*camera), "frame {frame}");
        let changed = bits(*camera) != bits(before);
        assert_eq!(
            tick["changed_outputs"],
            if changed { json!([1]) } else { json!([]) },
            "frame {frame}"
        );
        assert_eq!(tick["needs_frames"], oracle.coasting, "frame {frame}");
        assert_eq!(h.coasting(1), oracle.coasting, "frame {frame}");
    }
}
/// A whole flick on output 1, to rest. Returns the distance coasted after the lift.
fn flick(h: &mut Host, clock: &mut u64, source: Option<&str>, speed: f64, drift: f64) -> f64 {
    let (mut oracle, lifted) = throw(h, source, speed, drift, *clock / 1_000_000);
    let mut camera = lifted;
    coast(h, clock, &mut oracle, &mut camera, 5000);
    assert!(!oracle.coasting, "momentum never stopped");
    (camera.0 - lifted.0).hypot(camera.1 - lifted.1)
}

#[test]
fn a_flick_coasts_exactly_as_upstream_momentum_does() {
    let scratch = Scratch::new();
    // Each source at its own config speed, at a zoom that is not 1.
    let toml = "[navigation]\ntrackpad_speed = 2.0\nmouse_speed = 0.5\n";
    for (source, speed) in [
        (Some("finger"), 2.0),
        (Some("wheel"), 2.0),
        (Some("continuous"), 2.0),
        (Some("drag"), 0.5),
        (None, 1.0),
    ] {
        let mut h = configured(&scratch, toml);
        h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":global(0.0, 0.0)}));
        let mut clock = 0;
        let coasted = flick(&mut h, &mut clock, source, speed, 0.5);
        assert!(coasted > 100.0 * speed, "{source:?} coasted {coasted}");
        // A second flick starts from rest: a fresh oracle still matches it.
        let again = flick(&mut h, &mut clock, source, speed, 0.5);
        assert!((again - coasted).abs() < 1e-6, "{source:?}");
    }
    // Upstream's defaults with no file at all: trackpad 1.5, drift 0.5.
    let mut h = Host::new();
    h.ok(json!({"op":"register_output","stable_id":"view","screen_bounds":rect(ORIGIN.0,ORIGIN.1,1000.0,800.0)}));
    h.tick(0);
    assert!(flick(&mut h, &mut 0, Some("finger"), 1.5, 0.5) > 150.0);

    // Event times are upstream's u32 milliseconds: a clock past 2^32 wraps,
    // mid-flick here, and a fraction of a millisecond is dropped.
    let mut h = configured(&scratch, "");
    let (mut oracle, mut camera) = throw(&mut h, Some("finger"), 1.5, 0.5, (1 << 32) - 1030);
    coast(&mut h, &mut 0, &mut oracle, &mut camera, 5000);
    let mut h = configured(&scratch, "");
    let mut oracle = MomentumState::new(0.5);
    for (at, time_ms) in [(json!(1000.9), 1000), (json!(1008.2), 1008)] {
        h.ok(json!({"op":"pan","output":1,"screen_delta":point(-40.0,0.0),"time_ms":at,"source":"finger"}));
        oracle.accumulate((-60.0, 0.0).into(), time_ms);
    }
    h.ok(json!({"op":"pan_end","output":1}));
    oracle.launch();
    let mut camera = (-120.0, 0.0);
    coast(&mut h, &mut 0, &mut oracle, &mut camera, 5000);
    assert!(camera.0 < -200.0);

    // A scroll event that scrolls nothing is not a sample, as upstream drops
    // it; a drag event that has not moved is one.
    for (source, samples) in [("finger", 0.0), ("drag", 10.0)] {
        let mut h = configured(&scratch, "");
        h.pan_at(1, (10.0, 0.0), 2000, Some(source));
        h.pan_at(1, (0.0, 0.0), 2010, Some(source));
        h.ok(json!({"op":"pan_end","output":1}));
        let speed = if source == "drag" { 1.0 } else { 1.5 };
        // One sample launches nothing; two launch their distance over their time.
        assert_eq!(
            h.motion()["momentum"]["1"]["velocity"],
            point(samples * speed / 0.010, 0.0),
            "{source}"
        );
    }

    // A drag that rests with the button held and moves again. Upstream's
    // timer launches into the held grab 50 ms after the last motion, which
    // empties the tracker, so the release flings only what moved after the
    // rest; a millisecond sooner the timer has not fired and the samples
    // before the rest that are still inside the 80 ms window count too.
    for (rest, velocity) in [
        (60, -24.0 / 0.016),
        (50, -24.0 / 0.016),
        (49, -40.0 / 0.073),
    ] {
        let mut h = configured(&scratch, "");
        let mut oracle = MomentumState::new(0.5);
        let mut at = 3000;
        for sample in 0..16 {
            if sample == 13 {
                at += rest - 8;
                if rest >= 50 {
                    oracle.launch();
                }
            }
            h.pan_at(1, (-8.0, 0.0), at, Some("drag"));
            oracle.accumulate((-8.0, 0.0).into(), at as u32);
            at += 8;
        }
        h.ok(json!({"op":"pan_end","output":1}));
        oracle.launch();
        assert_eq!(
            h.motion()["momentum"]["1"]["velocity"],
            point(oracle.velocity.x, oracle.velocity.y),
            "{rest}"
        );
        assert_eq!(oracle.velocity.x, velocity, "{rest}");
        let mut camera = (-128.0, 0.0);
        coast(&mut h, &mut 0, &mut oracle, &mut camera, 5000);
        assert!(!oracle.coasting && camera.0 < -140.0, "{rest}");
    }
}

#[test]
fn drift_from_the_config_changes_the_trajectory() {
    let scratch = Scratch::new();
    let mut coasted = Vec::new();
    for drift in [0.0, 0.2, 0.5, 0.9] {
        let mut h = configured(&scratch, &format!("[navigation]\ndrift = {drift:?}\n"));
        coasted.push(flick(&mut h, &mut 0, Some("finger"), 1.5, drift));
    }
    // The same flick coasts further the floatier the knob: one frame at 0.
    assert!(coasted.is_sorted_by(|a, b| a < b), "{coasted:?}");
    assert!(
        coasted[0] < 100.0 && coasted[3] > 2.0 * coasted[2],
        "{coasted:?}"
    );

    // A reload reaches a coast in progress, as upstream's reload does.
    let mut h = configured(&scratch, "[navigation]\ndrift = 0.9\n");
    let mut clock = 0;
    let (mut oracle, mut camera) = throw(&mut h, Some("finger"), 1.5, 0.9, 0);
    coast(&mut h, &mut clock, &mut oracle, &mut camera, 4);
    h.load_config(&scratch.write("config.toml", "[navigation]\ndrift = 0.1\n"));
    oracle.drift = 0.1;
    assert!(oracle.coasting && h.coasting(1));
    coast(&mut h, &mut clock, &mut oracle, &mut camera, 5000);
    assert!(!oracle.coasting);
}

#[test]
fn momentum_stops_where_upstream_stops_it() {
    let scratch = Scratch::new();
    // Output 1 three frames into a coast, with one window on the canvas.
    let coasting = |windows: bool| {
        let mut h = configured(&scratch, "");
        if windows {
            assert_eq!(attach(&mut h, 1, rect(0.0, 0.0, 300.0, 200.0)), 1);
        }
        let mut clock = 0;
        let (mut oracle, mut camera) = throw(&mut h, Some("finger"), 1.5, 0.5, 0);
        coast(&mut h, &mut clock, &mut oracle, &mut camera, 3);
        assert!(h.coasting(1));
        (h, clock)
    };
    // `still`: the command arms no flight, so the next frame must not move.
    for (command, still) in [
        // The action prelude, whatever the action then does.
        (json!({"op":"action","output":1,"action":"zoom-in"}), false),
        (
            json!({"op":"action","output":1,"action":"set-bookmark here"}),
            true,
        ),
        (
            json!({"op":"action","output":1,"action":"toggle-cursor-pan"}),
            true,
        ),
        (
            json!({"op":"ipc","output":1,"request":{"Action":"home-toggle"}}),
            false,
        ),
        (
            json!({"op":"pan_viewport","output":1,"direction":"left"}),
            false,
        ),
        (json!({"op":"zoom_reset","output":1}), false),
        // A new flight target or anchor.
        (
            json!({"op":"navigate_window","window":1,"output":1,"zoom_policy":"keep"}),
            false,
        ),
        (
            json!({"op":"ipc","output":1,"request":{"Camera":[0,0]}}),
            false,
        ),
        (json!({"op":"ipc","output":1,"request":{"Zoom":0.5}}), false),
        // A new pan, with or without its time, and the other direct moves.
        (
            json!({"op":"pan","output":1,"screen_delta":point(1.0,0.0),"time_ms":5000,"source":"finger"}),
            true,
        ),
        (
            json!({"op":"pan","output":1,"screen_delta":point(1.0,0.0)}),
            true,
        ),
        (
            json!({"op":"zoom","output":1,"zoom":0.5,"anchor":global(0.0,0.0)}),
            true,
        ),
        (json!({"op":"cancel_navigation","output":1}), true),
        // Installing a grab, and the pointer zooms.
        (json!({"op":"begin_drag","window":1,"output":1}), true),
        (
            json!({"op":"begin_resize","window":1,"output":1,"edges":"right"}),
            true,
        ),
        (
            json!({"op":"zoom_by","output":1,"anchor":global(10.0,10.0),"delta":15.0,"source":"wheel"}),
            false,
        ),
        (
            json!({"op":"zoom_by","output":1,"anchor":global(10.0,10.0),"delta":-0.1,"source":"pinch"}),
            true,
        ),
    ] {
        let (mut h, clock) = coasting(true);
        h.ok(command.clone());
        assert!(!h.coasting(1), "{command}");
        if still {
            let camera = h.camera(1);
            let tick = h.tick(clock + 16_666_667);
            assert_eq!(tick["changed_outputs"], json!([]), "{command}");
            assert_eq!(tick["needs_frames"], false, "{command}");
            assert_eq!(bits(h.camera(1)), bits(camera), "{command}");
        }
    }
    // A view action with nothing to do still ran the prelude.
    let (mut h, _) = coasting(false);
    assert_eq!(
        h.ok(json!({"op":"zoom_to_fit","output":1})),
        json!({"navigation":null})
    );
    assert!(!h.coasting(1));
    // An action aimed at no output stops nothing, and a refused one changes nothing.
    let (mut h, _) = coasting(false);
    h.ok(json!({"op":"action","output":null,"action":"reload-config"}));
    assert!(h.coasting(1));
    h.error(json!({"op":"action","output":1,"action":"toggle-fullscreen"}));
    assert!(h.coasting(1));

    // A pan into a coast and a new flick: the first coast leaves nothing behind.
    let (mut h, mut clock) = coasting(false);
    let (mut oracle, mut camera) = throw(&mut h, Some("finger"), 1.5, 0.5, 10_000);
    coast(&mut h, &mut clock, &mut oracle, &mut camera, 5000);
    assert!(!oracle.coasting);

    // Momentum is per output, and a grab stops it on every output.
    let (mut h, clock) = coasting(true);
    h.ok(json!({"op":"register_output","stable_id":"side","screen_bounds":rect(2000.0,0.0,800.0,600.0)}));
    for at in [7000, 7008, 7016] {
        h.pan_at(2, (30.0, -20.0), at, Some("finger"));
    }
    assert_eq!(
        h.ok(json!({"op":"pan_end","output":2})),
        json!({"needs_frames":true})
    );
    assert!(h.coasting(1) && h.coasting(2));
    assert_eq!(h.tick(clock + 16_666_667)["changed_outputs"], json!([1, 2]));
    h.ok(json!({"op":"action","output":2,"action":"set-bookmark side"}));
    assert!(h.coasting(1) && !h.coasting(2));
    h.pan_at(2, (30.0, -20.0), 8000, Some("finger"));
    h.pan_at(2, (30.0, -20.0), 8008, Some("finger"));
    h.ok(json!({"op":"pan_end","output":2}));
    assert!(h.coasting(1) && h.coasting(2));
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert!(!h.coasting(1) && !h.coasting(2));
    assert_eq!(h.tick(clock + 33_333_334)["needs_frames"], false);
    // Removing an output drops its momentum with it.
    h.ok(json!({"op":"end_gesture"}));
    h.pan_at(2, (30.0, -20.0), 9000, Some("finger"));
    h.ok(json!({"op":"remove_output","output":2}));
    assert_eq!(h.motion()["momentum"].get("2"), None);
}

#[test]
fn a_pan_without_a_time_never_coasts() {
    let scratch = Scratch::new();
    // Exactly as before momentum: screen_delta / zoom, no config speed, and
    // nothing to launch, whatever `source` rides along.
    let mut h = configured(
        &scratch,
        "[navigation]\ntrackpad_speed = 2.0\nmouse_speed = 3.0\n",
    );
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":global(0.0, 0.0)}));
    let mut camera = h.camera(1);
    for (index, (delta, _)) in FLICK.into_iter().enumerate() {
        let mut command = json!({"op":"pan","output":1,"screen_delta":point(delta.0, delta.1)});
        if index % 2 == 1 {
            command["source"] = json!("finger");
        }
        assert_eq!(h.ok(command), json!({}));
        camera = (camera.0 + delta.0 / 0.5, camera.1 + delta.1 / 0.5);
        assert_eq!(bits(h.camera(1)), bits(camera));
    }
    assert_eq!(h.motion()["momentum"], json!({}));
    assert_eq!(
        h.ok(json!({"op":"pan_end","output":1})),
        json!({"needs_frames":false})
    );
    for frame in 1..4 {
        let tick = h.tick(frame * 16_666_667);
        assert_eq!(
            tick,
            json!({"changed_outputs":[],"needs_frames":false,"needs_pointer":false,"clock_only":false})
        );
    }
    assert_eq!(bits(h.camera(1)), bits(camera));
    // An untimed pan after timed ones drops their samples too, as a press
    // does through cancel_navigation: neither leaves anything to launch.
    for stop in [
        json!({"op":"pan","output":1,"screen_delta":point(-47.5, 15.75)}),
        json!({"op":"cancel_navigation","output":1}),
    ] {
        for (delta, at) in FLICK {
            h.pan_at(1, delta, u64::from(at), Some("drag"));
        }
        assert_eq!(h.motion()["momentum"]["1"]["panning"], true);
        h.ok(stop.clone());
        assert_eq!(
            h.motion()["momentum"]["1"]["panning"],
            stop["op"] == "pan",
            "{stop}"
        );
        let camera = h.camera(1);
        h.ok(json!({"op":"pan_end","output":1}));
        assert_eq!(h.motion()["momentum"]["1"]["velocity"], point(0.0, 0.0));
        let clock = h.motion()["clock_ns"].as_u64().unwrap();
        assert_eq!(h.tick(clock + 16_666_667)["needs_frames"], false);
        assert_eq!(bits(h.camera(1)), bits(camera));
    }

    // An end that carries its own event time launches only what upstream's
    // 50 ms timer would have left: everything before it, nothing after.
    for (lift, launches) in [(1066 + 49, true), (1066 + 50, false), (1066 + 5000, false)] {
        let mut h = configured(&scratch, "");
        for (delta, at) in FLICK {
            h.pan_at(1, delta, u64::from(at), Some("drag"));
        }
        assert_eq!(h.motion()["momentum"]["1"]["panning"], true);
        let camera = h.camera(1);
        assert_eq!(
            h.ok(json!({"op":"pan_end","output":1,"time_ms":lift})),
            json!({"needs_frames":true})
        );
        assert_eq!(h.motion()["momentum"]["1"]["panning"], false);
        let tick = h.tick(16_666_667);
        assert_eq!(tick["needs_frames"], launches, "{lift}");
        assert_eq!(bits(h.camera(1)) != bits(camera), launches, "{lift}");
    }

    // The additions are checked like every other command.
    let mut h = configured(&scratch, "");
    for (command, error) in [
        (
            json!({"op":"pan","output":9,"screen_delta":point(1.0,0.0),"time_ms":1}),
            "unknown output",
        ),
        (
            json!({"op":"pan","output":1,"screen_delta":point(1e13,0.0),"time_ms":1}),
            "invalid pan delta",
        ),
        (
            json!({"op":"pan","output":1,"screen_delta":point(1.0,0.0),"time_ms":-1}),
            "invalid time_ms",
        ),
        (
            json!({"op":"pan","output":1,"screen_delta":point(1.0,0.0),"time_ms":"now"}),
            "invalid type",
        ),
        (
            json!({"op":"pan","output":1,"screen_delta":point(1.0,0.0),"time_ms":1,"source":"touch"}),
            "unknown variant",
        ),
        (
            json!({"op":"pan","output":1,"screen_delta":point(1.0,0.0),"time_ms":1,"speed":2}),
            "unknown field",
        ),
        (json!({"op":"pan_end","output":9}), "unknown output"),
        (json!({"op":"pan_end"}), "missing field"),
        (
            json!({"op":"pointer","output":9,"screen":point(0.0,0.0)}),
            "unknown output",
        ),
        (
            json!({"op":"pointer","output":1,"screen":point(1e13,0.0)}),
            "invalid screen point",
        ),
        (
            json!({"op":"zoom_by","output":9,"anchor":point(0.0,0.0),"delta":1.0,"source":"wheel"}),
            "unknown output",
        ),
        (
            json!({"op":"zoom_by","output":1,"anchor":point(1e13,0.0),"delta":1.0,"source":"wheel"}),
            "invalid zoom anchor or delta",
        ),
        (
            json!({"op":"zoom_by","output":1,"anchor":point(0.0,0.0),"delta":1.0,"source":"touch"}),
            "unknown variant",
        ),
        (
            json!({"op":"zoom_by","output":1,"anchor":point(0.0,0.0),"delta":1.0}),
            "missing field",
        ),
        (
            json!({"op":"gesture_to","screen_delta":point(1.0,0.0),"pointer":point(1e13,0.0)}),
            "invalid gesture delta",
        ),
    ] {
        let message = h.error(command.clone());
        assert!(message.contains(error), "{command}: {message}");
    }
}

#[test]
fn a_window_dragged_to_the_edge_pans_the_canvas_under_it() {
    let scratch = Scratch::new();
    // Defaults: zone 100, 4 to 10 screen points a frame. At zoom 0.5 a screen
    // point is two world points.
    let mut h = configured(&scratch, "");
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":global(0.0, 0.0)}));
    let window = attach(&mut h, 1, rect(400.0, 300.0, 300.0, 200.0));
    h.ok(json!({"op":"begin_drag","window":window,"output":1}));
    // Inside the output and outside the zone, and at its boundary: no pan.
    for pointer in [(500.0, 400.0), (900.0, 400.0), (100.0, 700.0)] {
        assert_eq!(
            h.drag_to((50.0, 20.0), Some(pointer)),
            json!({"needs_frames":false})
        );
        assert_eq!(h.motion()["edge_pans"], json!({}));
    }
    assert_eq!(h.world(window), rect(500.0, 340.0, 300.0, 200.0));
    assert_eq!(h.tick(1)["changed_outputs"], json!([]));

    // Upstream's ramp, by hand: depth t into the zone gives speed
    // 4 + 6·t² along the edge's normal, scaled once more by t.
    let diagonal = 200f64.sqrt();
    let skewed = 125f64.sqrt();
    let mut clock = 1;
    let mut camera = (0.0, 0.0);
    let mut carried = (0.0, 0.0);
    for (pointer, velocity) in [
        ((950.0, 400.0), (2.75, 0.0)),
        ((925.0, 400.0), (1.09375, 0.0)),
        ((1000.0, 400.0), (10.0, 0.0)),
        ((0.0, 400.0), (-10.0, 0.0)),
        ((500.0, 50.0), (0.0, -2.75)),
        ((500.0, 800.0), (0.0, 10.0)),
        // A corner is no faster than an edge.
        (
            (1000.0, 0.0),
            (10.0 / diagonal * 10.0, -10.0 / diagonal * 10.0),
        ),
        ((950.0, 0.0), (5.0 / skewed * 10.0, -10.0 / skewed * 10.0)),
    ] {
        assert_eq!(
            h.drag_to((50.0, 20.0), Some(pointer)),
            json!({"needs_frames":true})
        );
        assert_eq!(
            h.motion()["edge_pans"],
            json!({"1":{"velocity":point(velocity.0, velocity.1),"screen":point(pointer.0, pointer.1)}}),
            "{pointer:?}"
        );
        let drawn = h.drawn(window, 1);
        // Screen points per frame, not per second: every frame steps alike.
        for elapsed in [16_666_667, 8_333_333, 0, 40_000_000] {
            clock += elapsed;
            let tick = h.tick(clock);
            assert_eq!(tick["changed_outputs"], json!([1]), "{pointer:?}");
            assert_eq!(tick["needs_frames"], true);
            let step = (velocity.0 / 0.5, velocity.1 / 0.5);
            camera = (camera.0 + step.0, camera.1 + step.1);
            carried = (carried.0 + step.0, carried.1 + step.1);
            assert_eq!(bits(h.camera(1)), bits(camera), "{pointer:?}");
            // The window travels with the camera, so it stays where it was
            // drawn: under the pointer that holds it.
            assert_eq!(
                h.world(window),
                rect(
                    400.0 + (50.0 / 0.5 + carried.0),
                    300.0 + (20.0 / 0.5 + carried.1),
                    300.0,
                    200.0
                ),
                "{pointer:?}"
            );
            let now = h.drawn(window, 1);
            assert!(
                (now.0 - drawn.0).abs() < 1e-9 && (now.1 - drawn.1).abs() < 1e-9,
                "{pointer:?}: {drawn:?} became {now:?}"
            );
        }
    }
    assert!(carried.0.abs() > 20.0 && carried.1.abs() > 20.0);
    // The pointer's own motion still moves the window, on top of the travel.
    h.drag_to((60.0, 20.0), Some((960.0, 400.0)));
    assert_eq!(
        h.world(window)["origin"],
        point(
            400.0 + (60.0 / 0.5 + carried.0),
            300.0 + (20.0 / 0.5 + carried.1)
        )
    );
    // A pointer that has left the output pans nothing: the drag stays on it.
    for pointer in [
        (1000.5, 400.0),
        (-0.5, 400.0),
        (500.0, -1.0),
        (500.0, 801.0),
    ] {
        h.drag_to((60.0, 20.0), Some((1000.0, 400.0)));
        assert_eq!(
            h.drag_to((60.0, 20.0), Some(pointer)),
            json!({"needs_frames":false})
        );
        assert_eq!(h.motion()["edge_pans"], json!({}));
    }
    // Releasing ends the pan and leaves the window where it was carried.
    h.drag_to((60.0, 20.0), Some((1000.0, 400.0)));
    let (world, camera) = (h.world(window), h.camera(1));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.motion()["edge_pans"], json!({}));
    assert_eq!(
        h.tick(clock + 16_666_667),
        json!({"changed_outputs":[],"needs_frames":false,"needs_pointer":false,"clock_only":false})
    );
    assert_eq!((h.world(window), h.camera(1)), (world, camera));

    // Without a pointer a drag is what it was, and a resize never pans.
    h.ok(json!({"op":"begin_drag","window":window,"output":1}));
    assert_eq!(h.drag_to((5.0, 5.0), None), json!({"needs_frames":false}));
    h.ok(json!({"op":"end_gesture"}));
    h.ok(json!({"op":"begin_resize","window":window,"output":1,"edges":"right"}));
    assert_eq!(
        h.drag_to((5.0, 0.0), Some((1000.0, 400.0))),
        json!({"needs_frames":false})
    );
    assert_eq!(h.motion()["edge_pans"], json!({}));
    h.ok(json!({"op":"end_gesture"}));
    // A source that goes away mid-drag takes the pan with the gesture.
    h.ok(json!({"op":"begin_drag","window":window,"output":1}));
    h.drag_to((0.0, 0.0), Some((1000.0, 400.0)));
    h.ok(json!({"op":"remove_source","window":window,"identity":identity(1),"keep_placeholder":true}));
    assert_eq!(h.motion()["edge_pans"], json!({}));

    // A cluster is carried whole.
    let mut h = configured(&scratch, "");
    let first = attach(&mut h, 1, rect(400.0, 300.0, 300.0, 200.0));
    let second = attach(&mut h, 2, rect(712.0, 300.0, 300.0, 200.0));
    h.ok(json!({"op":"begin_drag","window":first,"output":1,"group":true}));
    h.drag_to((0.0, 0.0), Some((0.0, 400.0)));
    for frame in 1..=3 {
        h.tick(frame * 16_666_667);
    }
    assert_eq!(h.camera(1), (-30.0, 0.0));
    assert_eq!(h.world(first)["origin"], point(370.0, 300.0));
    assert_eq!(h.world(second)["origin"], point(682.0, 300.0));

    // The zone and both speeds are the config's.
    let mut h = configured(
        &scratch,
        "[navigation.edge_pan]\nzone = 50.0\nspeed_min = 2.0\nspeed_max = 20.0\n",
    );
    let window = attach(&mut h, 1, rect(400.0, 300.0, 300.0, 200.0));
    h.ok(json!({"op":"begin_drag","window":window,"output":1}));
    for (pointer, velocity) in [(950.0, None), (975.0, Some(3.25)), (1000.0, Some(20.0))] {
        h.drag_to((0.0, 0.0), Some((pointer, 400.0)));
        let request = h.motion()["edge_pans"].get("1").map(|r| xy(&r["velocity"]));
        assert_eq!(request, velocity.map(|x| (x, 0.0)), "{pointer}");
    }
    // A zone of zero disables it.
    let mut h = configured(&scratch, "[navigation.edge_pan]\nzone = 0.0\n");
    let window = attach(&mut h, 1, rect(400.0, 300.0, 300.0, 200.0));
    h.ok(json!({"op":"begin_drag","window":window,"output":1}));
    assert_eq!(
        h.drag_to((0.0, 0.0), Some((1000.0, 400.0))),
        json!({"needs_frames":false})
    );
}

/// The same second of motion on a 60 Hz and on a 120 Hz frame clock, which is
/// what a ProMotion display's frame timer changes. Upstream's rule for each
/// kind of motion, at 352333a: a camera or zoom animation covers
/// `1 - (1 - camera_speed)^(dt·60)` of the way a frame
/// (viewport_animation.rs, animation_factor) and momentum is points a second
/// decayed by `drift^(dt·60)` (canvas.rs, MomentumState::tick), so both keep
/// their pace in seconds; an edge pan is `speed` screen points a frame with no
/// dt in it (tick_edge_pan_on; config.reference.toml: "px/frame"), so on a
/// 120 Hz output it covers twice the ground in the same second.
#[test]
fn a_second_of_motion_at_60_and_120_hz_keeps_upstreams_time_base() {
    let scratch = Scratch::new();
    // Two 120 Hz frames are exactly one 60 Hz frame.
    const HALF: u64 = 8_333_333;
    let frame = |hz: u64| HALF * (120 / hz);

    // A flight to a window 5000 points away, sampled every sixtieth of a second.
    let fly = |hz: u64| {
        let mut h = configured(&scratch, "");
        let window = attach(&mut h, 1, rect(5000.0, 3000.0, 300.0, 200.0));
        let reply =
            h.ok(json!({"op":"navigate_window","window":window,"output":1,"zoom_policy":"keep"}));
        let target = xy(&reply["navigation"]["target_camera"]);
        let (mut clock, mut poses, mut landed) = (0, Vec::new(), None);
        for step in 1..=hz {
            clock += frame(hz);
            let tick = h.tick(clock);
            if tick["needs_frames"] == false && landed.is_none() {
                landed = Some(clock);
            }
            if step % (hz / 60) == 0 {
                poses.push(h.camera(1));
            }
        }
        assert_eq!(bits(h.camera(1)), bits(target), "{hz} Hz never arrived");
        (poses, landed.unwrap(), target)
    };
    let (slow, slow_landed, target) = fly(60);
    let (fast, fast_landed, _) = fly(120);
    assert!(target.0 > 4000.0 && slow[0].0 > 1000.0 && slow[0].0 < target.0);
    for (sixtieth, (a, b)) in slow.iter().zip(&fast).enumerate() {
        // The same share of the way at the same moment. The last half point is
        // a snap onto the target, which the faster clock may take a frame of
        // its own earlier.
        let apart = (a.0 - b.0).hypot(a.1 - b.1);
        let left = (target.0 - a.0).hypot(target.1 - a.1);
        assert!(
            apart < if left > 1.0 { 1e-6 } else { 0.5 },
            "sixtieth {sixtieth}: {a:?} at 60 Hz, {b:?} at 120 Hz"
        );
    }
    assert!(slow_landed.abs_diff(fast_landed) <= 2 * HALF);

    // A flick, coasting to rest: every frame is upstream's own momentum for
    // that frame's dt, and the two clocks agree as upstream's own test asks of
    // its 60 Hz and 144 Hz runs (canvas_transforms_test.rs,
    // momentum_frame_rate_independence: within 5 %).
    let coast = |hz: u64| {
        let mut h = configured(&scratch, "[navigation]\ndrift = 0.5\n");
        let (mut oracle, lifted) = throw(&mut h, Some("finger"), 1.5, 0.5, 0);
        let (mut clock, mut camera) = (0, lifted);
        while oracle.coasting {
            clock += frame(hz);
            h.tick(clock);
            if let Some(delta) = oracle.tick(Duration::from_nanos(frame(hz))) {
                camera = (camera.0 + delta.x, camera.1 + delta.y);
            }
            assert_eq!(bits(h.camera(1)), bits(camera), "{hz} Hz at {clock}");
            assert!(clock < 60_000_000_000, "momentum never stopped");
        }
        assert!(!h.coasting(1));
        ((camera.0 - lifted.0).hypot(camera.1 - lifted.1), clock)
    };
    let ((slow, slow_rest), (fast, fast_rest)) = (coast(60), coast(120));
    assert!(
        slow > 150.0 && (slow / fast - 1.0).abs() < 0.05,
        "{slow} {fast}"
    );
    assert!(
        (slow_rest as f64 / fast_rest as f64 - 1.0).abs() < 0.05,
        "{slow_rest} {fast_rest}"
    );

    // An edge pan under a held window, at zoom 1 and the zone's full depth:
    // navigation.edge_pan.speed_max, 10 screen points, every frame. A second
    // is 600 points at 60 Hz and 1200 at 120 Hz, and the window goes with it.
    let pan = |hz: u64| {
        let mut h = configured(&scratch, "");
        let window = attach(&mut h, 1, rect(400.0, 300.0, 300.0, 200.0));
        h.ok(json!({"op":"begin_drag","window":window,"output":1}));
        assert_eq!(
            h.drag_to((0.0, 0.0), Some((1000.0, 400.0))),
            json!({"needs_frames":true})
        );
        let mut clock = 0;
        for _ in 0..hz {
            clock += frame(hz);
            assert_eq!(h.tick(clock)["needs_frames"], true);
        }
        (h.camera(1), xy(&h.world(window)["origin"]))
    };
    assert_eq!(pan(60), ((600.0, 0.0), (1000.0, 300.0)));
    assert_eq!(pan(120), ((1200.0, 0.0), (1600.0, 300.0)));
}

/// A window move whose end never comes is carried for as long as frames are
/// ticked: upstream's grab pans under a held pointer without limit, and the
/// controller cannot know that nothing holds this one any more. So the shell
/// must end it, and does through these two commands when a release or a
/// gesture's touches are lost. Each stops the travel at once and leaves
/// nothing in motion: no edge pan, no momentum, no drag for a flight to be
/// refused over.
#[test]
fn a_move_nothing_holds_any_more_stops_with_the_end_the_shell_sends() {
    let scratch = Scratch::new();
    let flying = "navigation during active gesture";
    for lost in ["button", "touches"] {
        // Exercise a move grab explicitly; the Mac default swipe pans.
        let mut h = configured(
            &scratch,
            "[gestures.on-window]\n\"3-finger-doubletap-swipe\" = \"move-window\"\n",
        );
        let window = attach(&mut h, 1, rect(100.0, 100.0, 400.0, 300.0));
        // A flick is coasting when the move begins: the grab stops it.
        throw(&mut h, Some("finger"), 1.5, 0.5, 0);
        assert!(h.coasting(1));
        let camera = h.camera(1);
        let over = point(ORIGIN.0 + 150.0 - camera.0, ORIGIN.1 + 150.0 - camera.1);
        if lost == "button" {
            h.ok(json!({"op":"begin_drag","window":window,"output":1}));
            // Into the top left corner, both edges at full depth.
            assert_eq!(
                h.drag_to((-150.0, -150.0), Some((0.0, 0.0))),
                json!({"needs_frames":true})
            );
        } else {
            let reply = h.ok(json!({"op":"gesture_begin","kind":"swipe","fingers":3,"modifiers":{"control":false,"option":false,"shift":false,"command":false},"context":"window","output":1,"pointer":over,"doubletap":true,"time_ms":2000}));
            assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
            // The fingers fling the window into the same corner and rest.
            let reply =
                h.ok(json!({"op":"gesture_update","dx":-5000.0,"dy":-5000.0,"time_ms":2010}));
            assert_eq!(reply["needs_frames"], true, "{reply}");
        }
        assert!(!h.coasting(1));
        assert_eq!(h.motion()["momentum"]["1"]["velocity"], point(0.0, 0.0));
        // Nothing arrives any more, and every frame carries the window on: a
        // corner's 10 points, split between its two edges.
        let step = 10.0 / 2f64.sqrt();
        let (mut clock, start) = (0, xy(&h.world(window)["origin"]));
        for frame in 1..=600u64 {
            clock += 8_333_333;
            assert_eq!(h.tick(clock)["needs_frames"], true, "{lost}");
            let at = xy(&h.world(window)["origin"]);
            let gone = frame as f64 * step;
            assert!(
                (start.0 - at.0 - gone).abs() < 1e-6 && (start.1 - at.1 - gone).abs() < 1e-6,
                "{lost} frame {frame}: {at:?}"
            );
        }
        // Held, the controller flies nowhere: every window navigation is refused.
        assert_eq!(
            h.error(
                json!({"op":"navigate_window","window":window,"output":1,"zoom_policy":"keep"})
            ),
            flying
        );
        // The end the shell sends for what it found lost.
        if lost == "button" {
            h.ok(json!({"op":"end_gesture"}));
        } else {
            let reply = h.ok(json!({"op":"gesture_end","cancelled":true,"time_ms":9000}));
            assert_eq!(reply["needs_frames"], false, "{reply}");
        }
        assert_eq!(h.motion()["edge_pans"], json!({}));
        assert!(!h.coasting(1));
        let rest = (h.world(window), h.camera(1));
        for _ in 0..10 {
            clock += 8_333_333;
            assert_eq!(
                h.tick(clock),
                json!({"changed_outputs":[],"needs_frames":false,"needs_pointer":false,"clock_only":false}),
                "{lost}"
            );
        }
        assert_eq!((h.world(window), h.camera(1)), rest, "{lost}");
        h.ok(json!({"op":"navigate_window","window":window,"output":1,"zoom_policy":"keep"}));
    }
}

#[test]
fn an_edge_facing_another_output_waits_out_the_latency() {
    let scratch = Scratch::new();
    const LATENCY: u64 = 120_000_000;
    // Output 2 touches the lower half of output 1's right edge.
    let dragging = |toml: &str| {
        let mut h = configured(&scratch, toml);
        h.ok(json!({"op":"register_output","stable_id":"side","screen_bounds":rect(ORIGIN.0 + 1000.0,ORIGIN.1 + 400.0,800.0,400.0)}));
        let window = attach(&mut h, 1, rect(400.0, 300.0, 300.0, 200.0));
        h.ok(json!({"op":"begin_drag","window":window,"output":1}));
        h
    };
    let mut h = dragging("");
    let mut clock = 1_000_000_000;
    // Pushing at the shared stretch pans nothing until the latency has passed
    // on the frame clock, so a pointer bound for output 2 can cross.
    assert_eq!(
        h.drag_to((0.0, 0.0), Some((1000.0, 600.0))),
        json!({"needs_frames":true})
    );
    for elapsed in [0, 60_000_000, 59_999_999] {
        clock += elapsed;
        let tick = h.tick(clock);
        assert_eq!(tick["changed_outputs"], json!([]), "{elapsed}");
        assert_eq!(tick["needs_frames"], true);
    }
    clock += 1;
    assert_eq!(h.tick(clock)["changed_outputs"], json!([1]));
    assert_eq!(h.camera(1), (10.0, 0.0));
    // Sliding along the shared stretch does not start the wait again.
    h.drag_to((0.0, -100.0), Some((1000.0, 500.0)));
    clock += 16_666_667;
    h.tick(clock);
    assert_eq!(h.camera(1), (20.0, 0.0));
    // Leaving the zone does.
    h.drag_to((-200.0, -100.0), Some((800.0, 500.0)));
    h.drag_to((0.0, -100.0), Some((1000.0, 500.0)));
    clock += 16_666_667;
    assert_eq!(h.tick(clock)["changed_outputs"], json!([]));
    clock += LATENCY;
    assert_eq!(h.tick(clock)["changed_outputs"], json!([1]));
    assert_eq!(h.camera(1), (30.0, 0.0));
    // The stretch is half-open, as upstream's is: its first point belongs to
    // it, the point above does not, and that outer edge is immediate.
    h.drag_to((-200.0, -100.0), Some((800.0, 500.0)));
    h.drag_to((0.0, -200.0), Some((1000.0, 400.0)));
    clock += 16_666_667;
    assert_eq!(h.tick(clock)["changed_outputs"], json!([]));
    h.drag_to((0.0, -201.0), Some((1000.0, 399.0)));
    clock += 16_666_667;
    assert_eq!(h.tick(clock)["changed_outputs"], json!([1]));
    assert_eq!(h.camera(1), (40.0, 0.0));

    // At a corner only the component facing the other output waits. One point
    // above the bottom edge the ramp is (10, 9.9), cut back to length 10.
    let mut h = dragging("");
    let mut clock = 1_000_000_000;
    let length = (10.0f64 * 10.0 + 9.9 * 9.9).sqrt();
    let corner = (10.0 / length * 10.0, 9.9 / length * 10.0);
    h.drag_to((0.0, 0.0), Some((1000.0, 799.0)));
    h.tick(clock);
    assert_eq!(h.camera(1), (0.0, corner.1));
    clock += LATENCY;
    h.tick(clock);
    assert_eq!(h.camera(1), (corner.0, corner.1 + corner.1));
    // The corner itself is past the half-open stretch: nothing waits there.
    let mut h = dragging("");
    h.drag_to((0.0, 0.0), Some((1000.0, 800.0)));
    h.tick(1);
    let both = 10.0 / 200f64.sqrt() * 10.0;
    assert_eq!(h.camera(1), (both, both));
    // Every other edge of output 1 is an outer one.
    for pointer in [(0.0, 600.0), (500.0, 0.0), (500.0, 800.0)] {
        let mut h = dragging("");
        h.drag_to((0.0, 0.0), Some(pointer));
        assert_eq!(h.tick(1)["changed_outputs"], json!([1]), "{pointer:?}");
    }
    // Zero disables the wait.
    let mut h = dragging("[navigation.edge_pan]\nlatency_ms = 0\n");
    h.drag_to((0.0, 0.0), Some((1000.0, 600.0)));
    assert_eq!(h.tick(1)["changed_outputs"], json!([1]));
}

#[test]
fn cursor_edge_pan_follows_the_reported_pointer_and_the_toggle() {
    let scratch = Scratch::new();
    let on = "[navigation.edge_pan]\ncursor_pan = true\n";
    let enabled = |h: &mut Host| h.motion()["cursor_pan"].clone();
    // Off by default: the shell is not asked for the pointer, and a report
    // arms nothing.
    let mut h = configured(&scratch, "");
    assert_eq!(
        enabled(&mut h),
        json!({"enabled":false,"needs_pointer":false})
    );
    assert_eq!(
        h.pointer(0.0, 400.0),
        json!({"needs_pointer":false,"needs_frames":false})
    );
    assert_eq!(h.motion()["edge_pans"], json!({}));

    // On from the config: 20 points inside the usable area, at speed_max
    // whatever the depth. The strip above the usable area never pans.
    let mut h = configured(&scratch, on);
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,30.0,1000.0,770.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
    assert_eq!(
        enabled(&mut h),
        json!({"enabled":true,"needs_pointer":true})
    );
    let diagonal = 2f64.sqrt();
    let mut clock = 0;
    let mut camera = (0.0, 0.0);
    for (pointer, velocity) in [
        ((500.0, 400.0), None),
        ((20.0, 400.0), None),
        ((19.5, 400.0), Some((-10.0, 0.0))),
        ((0.0, 400.0), Some((-10.0, 0.0))),
        ((980.5, 400.0), Some((10.0, 0.0))),
        ((500.0, 10.0), None),
        ((500.0, 29.5), None),
        ((500.0, 30.0), Some((0.0, -10.0))),
        ((500.0, 49.5), Some((0.0, -10.0))),
        ((500.0, 50.0), None),
        ((500.0, 800.0), Some((0.0, 10.0))),
        (
            (5.0, 35.0),
            Some((-1.0 / diagonal * 10.0, -1.0 / diagonal * 10.0)),
        ),
    ] {
        let reply = h.pointer(pointer.0, pointer.1);
        assert_eq!(
            reply,
            json!({"needs_pointer":true,"needs_frames":velocity.is_some()}),
            "{pointer:?}"
        );
        let request = h.motion()["edge_pans"].get("1").map(|r| xy(&r["velocity"]));
        assert_eq!(request, velocity, "{pointer:?}");
        // The frame arms it again from the last report before it pans.
        for _ in 0..2 {
            clock += 16_666_667;
            let tick = h.tick(clock);
            let step = velocity.unwrap_or((0.0, 0.0));
            camera = (camera.0 + step.0, camera.1 + step.1);
            assert_eq!(bits(h.camera(1)), bits(camera), "{pointer:?}");
            assert_eq!(tick["needs_frames"], velocity.is_some(), "{pointer:?}");
            assert_eq!(tick["needs_pointer"], true);
        }
    }
    // A pointer on no output disarms it.
    h.pointer(0.0, 400.0);
    assert_eq!(
        h.ok(json!({"op":"pointer","output":null,"screen":global(0.0, 400.0)})),
        json!({"needs_pointer":true,"needs_frames":false})
    );
    // The speed is a screen speed: at zoom 0.5 the canvas moves twice as far.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":global(0.0, 0.0)}));
    let before = h.camera(1);
    h.pointer(0.0, 400.0);
    h.tick(clock + 16_666_667);
    assert_eq!(h.camera(1), (before.0 - 20.0, before.1));

    // toggle-cursor-pan flips the runtime flag and reports nothing else, with
    // or without an output. Off stops the pan at once and forgets the pointer.
    for request in [
        json!({"op":"action","output":null,"action":"toggle-cursor-pan"}),
        json!({"op":"ipc","output":null,"request":{"Action":"toggle-cursor-pan"}}),
    ] {
        h.pointer(0.0, 400.0);
        let reply = h.ok(request.clone());
        assert_eq!(reply["navigation"], Value::Null, "{request}");
        assert_eq!(reply["effects"], json!([]));
        assert_eq!(reply["dirty"], false);
        assert_eq!(
            enabled(&mut h),
            json!({"enabled":false,"needs_pointer":false})
        );
        assert_eq!(h.motion()["edge_pans"], json!({}));
        clock += 100_000_000;
        assert_eq!(
            h.tick(clock),
            json!({"changed_outputs":[],"needs_frames":false,"needs_pointer":false,"clock_only":false})
        );
        assert_eq!(
            h.pointer(0.0, 400.0),
            json!({"needs_pointer":false,"needs_frames":false})
        );
        // On again: nothing pans until the pointer is reported afresh.
        h.ok(request);
        assert_eq!(
            enabled(&mut h),
            json!({"enabled":true,"needs_pointer":true})
        );
        clock += 16_666_667;
        assert_eq!(h.tick(clock)["needs_frames"], false);
        assert_eq!(h.pointer(0.0, 400.0)["needs_frames"], true);
    }

    // The config sets the flag once, at launch. A reload leaves it to the
    // toggle, in either direction, and a scene load keeps it.
    let off = scratch.write("off.toml", "[navigation.edge_pan]\ncursor_pan = false\n");
    h.load_config(&off);
    assert_eq!(enabled(&mut h)["enabled"], true);
    let scene = scratch.write("scene.json", "");
    h.ok(json!({"op":"save","path":scene}));
    h.ok(json!({"op":"load","path":scene}));
    assert_eq!(enabled(&mut h)["enabled"], true);
    assert_eq!(h.motion()["edge_pans"], json!({}));
    let mut h = configured(&scratch, "");
    h.load_config(&scratch.write("on.toml", on));
    assert_eq!(enabled(&mut h)["enabled"], false);
    // The zone and the speed are the config's; speed_min is not used.
    let mut h = configured(
        &scratch,
        "[navigation.edge_pan]\ncursor_pan = true\ncursor_zone = 5.0\nspeed_min = 9.0\nspeed_max = 3.0\n",
    );
    assert_eq!(h.pointer(5.0, 400.0)["needs_frames"], false);
    h.pointer(4.0, 400.0);
    h.tick(16_666_667);
    assert_eq!(h.camera(1), (-3.0, 0.0));

    // A grab owns the request. A window drag arms its own from its own
    // pointer; a resize and a drag pan leave it as it stood.
    let mut h = configured(&scratch, on);
    let window = attach(&mut h, 1, rect(400.0, 300.0, 300.0, 200.0));
    // A drag that begins on an armed cursor pan takes it over after one frame,
    // as upstream's warped pointer re-drives the move grab: the window is
    // carried, and the request becomes the drag's ramp at that spot.
    h.pointer(5.0, 400.0);
    h.ok(json!({"op":"begin_drag","window":window,"output":1}));
    h.tick(16_666_667);
    assert_eq!(h.camera(1), (-10.0, 0.0));
    assert_eq!(h.world(window)["origin"], point(390.0, 300.0));
    let speed = 4.0 + (10.0 - 4.0) * 0.95 * 0.95;
    assert_eq!(
        xy(&h.motion()["edge_pans"]["1"]["velocity"]),
        (0.0 - speed * 0.95, 0.0)
    );
    h.ok(json!({"op":"end_gesture"}));
    let mut h = configured(&scratch, on);
    let window = attach(&mut h, 1, rect(400.0, 300.0, 300.0, 200.0));
    h.ok(json!({"op":"begin_drag","window":window,"output":1}));
    assert_eq!(h.pointer(0.0, 400.0)["needs_frames"], false);
    h.drag_to((0.0, 0.0), Some((950.0, 400.0)));
    h.pointer(0.0, 400.0);
    assert_eq!(xy(&h.motion()["edge_pans"]["1"]["velocity"]), (2.75, 0.0));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.motion()["edge_pans"], json!({}));
    h.ok(json!({"op":"begin_resize","window":window,"output":1,"edges":"right"}));
    assert_eq!(h.pointer(0.0, 400.0)["needs_frames"], false);
    h.ok(json!({"op":"end_gesture"}));
    h.pan_at(1, (5.0, 0.0), 1000, Some("drag"));
    assert_eq!(h.pointer(0.0, 400.0)["needs_frames"], false);
    h.ok(json!({"op":"pan_end","output":1}));
    h.tick(16_666_667);
    assert_eq!(h.pointer(0.0, 400.0)["needs_frames"], true);

    // An edge that borders another output waits out the latency for the bare
    // pointer too; the outer edges do not.
    let mut h = configured(&scratch, on);
    h.ok(json!({"op":"register_output","stable_id":"side","screen_bounds":rect(ORIGIN.0 + 1000.0,ORIGIN.1,800.0,800.0)}));
    assert_eq!(h.pointer(995.0, 400.0)["needs_frames"], true);
    assert_eq!(h.tick(1_000_000_000)["changed_outputs"], json!([]));
    assert_eq!(h.tick(1_119_999_999)["changed_outputs"], json!([]));
    assert_eq!(h.tick(1_120_000_000)["changed_outputs"], json!([1]));
    assert_eq!(h.camera(1), (10.0, 0.0));
    // The pointer crossed: output 1 is disarmed and output 2 is armed at once
    // by its own outer edge.
    assert_eq!(
        h.ok(
            json!({"op":"pointer","output":2,"screen":point(ORIGIN.0 + 1790.0, ORIGIN.1 + 400.0)})
        )["needs_frames"],
        true
    );
    assert_eq!(h.motion()["edge_pans"].as_object().unwrap().len(), 1);
    assert_eq!(h.tick(1_136_666_667)["changed_outputs"], json!([2]));
    assert_eq!((h.camera(1), h.camera(2)), ((10.0, 0.0), (10.0, 0.0)));
}

#[test]
fn wheel_zoom_is_upstreams_animated_zoom_around_the_pointer() {
    let scratch = Scratch::new();
    // One 2000 x 1600 window: it fits at 0.4, so the dynamic minimum is 0.2.
    let mut h = configured(&scratch, "[zoom]\nstep = 1.25\nmouse_speed = 2.0\n");
    let window = attach(&mut h, 1, rect(0.0, 0.0, 2000.0, 1600.0));
    let wheel = |h: &mut Host, delta: f64| {
        h.ok(json!({"op":"zoom_by","output":1,"anchor":global(250.0, 200.0),"delta":delta,"source":"wheel"}))
    };
    // Upstream: zoom.step ^ (-v / 30 · zoom.mouse_speed), from the zoom the
    // output is already heading for, between the dynamic minimum and 1.
    let target = |base: f64, delta: f64| (base * 1.25f64.powf(-delta / 30.0 * 2.0)).clamp(0.2, 1.0);
    // Every frame holds the world point under the pointer where it was.
    let settle = |h: &mut Host, clock: &mut u64, world: (f64, f64)| {
        for frame in 0.. {
            assert!(frame < 1000, "the zoom never arrived");
            *clock += 16_666_667;
            let tick = h.tick(*clock);
            let (camera, zoom) = (h.camera(1), h.zoom(1));
            let under = (camera.0 + 250.0 / zoom, camera.1 + 200.0 / zoom);
            assert!(
                (under.0 - world.0).abs() < 1e-9 && (under.1 - world.1).abs() < 1e-9,
                "{under:?}"
            );
            if tick["needs_frames"] == false {
                break;
            }
        }
    };
    let mut clock = 0;

    // One notch down, and a second before any frame: they compound on the target.
    let first = target(1.0, 15.0);
    let reply = wheel(&mut h, 15.0);
    assert_eq!(reply["needs_frames"], true);
    assert_eq!(
        reply["navigation"],
        json!({"output":1,"generation":1,"target_camera":point(250.0 - 250.0 / first, 200.0 - 200.0 / first),"target_zoom":first,"animating":true})
    );
    assert_eq!(
        h.motion()["flights"]["1"],
        json!({"camera_target":null,"zoom_target":first,"zoom_animation_anchor":{"canvas":point(250.0, 200.0),"screen":point(250.0, 200.0)},"generation":1})
    );
    assert_eq!(h.zoom(1), 1.0);
    let second = target(first, 15.0);
    assert!(second < first && first < 1.0);
    assert_eq!(wheel(&mut h, 15.0)["navigation"]["target_zoom"], second);
    settle(&mut h, &mut clock, (250.0, 200.0));
    assert_eq!(h.zoom(1).to_bits(), second.to_bits());
    assert_eq!(
        bits(h.camera(1)),
        bits((250.0 - 250.0 / second, 200.0 - 200.0 / second))
    );
    assert_eq!(h.motion()["flights"], json!({}));

    // Never below the dynamic minimum, never above 1, and never snapped to 1.
    assert_eq!(wheel(&mut h, 600.0)["navigation"]["target_zoom"], 0.2);
    settle(&mut h, &mut clock, (250.0, 200.0));
    assert_eq!(h.zoom(1), 0.2);
    assert_eq!(
        wheel(&mut h, 15.0),
        json!({"navigation":null,"needs_frames":false})
    );
    assert_eq!(wheel(&mut h, -600.0)["navigation"]["target_zoom"], 1.0);
    settle(&mut h, &mut clock, (250.0, 200.0));
    assert_eq!(h.zoom(1), 1.0);
    for delta in [-15.0, 0.0] {
        assert_eq!(
            wheel(&mut h, delta),
            json!({"navigation":null,"needs_frames":false})
        );
    }
    let near = target(1.0, 2.0);
    assert!(near > 0.95 && near < 1.0);
    assert_eq!(wheel(&mut h, 2.0)["navigation"]["target_zoom"], near);
    settle(&mut h, &mut clock, (250.0, 200.0));
    assert_eq!(h.zoom(1).to_bits(), near.to_bits());

    // It replaces a flight in progress and disarms a zoom-to-fit return.
    h.ok(json!({"op":"zoom_to_fit","output":1}));
    assert!(h.motion()["overview_returns"].get("1").is_some());
    let reply = wheel(&mut h, 15.0);
    assert_eq!(reply["navigation"]["target_zoom"], target(0.4, 15.0));
    assert_eq!(h.motion()["overview_returns"], json!({}));
    assert_eq!(h.motion()["flights"]["1"]["camera_target"], Value::Null);
    // The defaults: step 1.1, speed 1, so a notch of 15 is half a step.
    let mut h = configured(&scratch, "");
    assert_eq!(
        h.ok(json!({"op":"zoom_by","output":1,"anchor":global(0.0, 0.0),"delta":15.0,"source":"wheel"}))["navigation"]["target_zoom"],
        1.1f64.powf(-0.5)
    );
    // Like every flight, it is refused while a drag or resize holds the pointer.
    let window_2 = attach(&mut h, 1, rect(0.0, 0.0, 300.0, 200.0));
    assert_eq!((window, window_2), (1, 1));
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    for source in ["wheel", "pinch"] {
        assert_eq!(
            h.error(json!({"op":"zoom_by","output":1,"anchor":global(0.0, 0.0),"delta":15.0,"source":source})),
            "navigation during active gesture"
        );
    }
}

#[test]
fn pinch_zoom_is_upstreams_gesture_one_event_at_a_time() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, "[zoom]\ntrackpad_speed = 2.0\n");
    attach(&mut h, 1, rect(0.0, 0.0, 2000.0, 1600.0));
    let pinch = |h: &mut Host, delta: f64, phase: Option<&str>| {
        let mut command = json!({"op":"zoom_by","output":1,"anchor":global(250.0, 200.0),"delta":delta,"source":"pinch"});
        if let Some(phase) = phase {
            command["phase"] = json!(phase);
        }
        let under = |h: &mut Host| {
            let (camera, zoom) = (h.camera(1), h.zoom(1));
            (camera.0 + 250.0 / zoom, camera.1 + 200.0 / zoom)
        };
        let before = under(h);
        assert_eq!(
            h.ok(command),
            json!({"navigation":null,"needs_frames":false})
        );
        // Applied at once, around the pointer.
        let after = under(h);
        assert!(
            (after.0 - before.0).abs() < 1e-9 && (after.1 - before.1).abs() < 1e-9,
            "{before:?} became {after:?}"
        );
        h.zoom(1)
    };
    // Upstream: initial_zoom · (1 + (scale - 1) · zoom.trackpad_speed), where
    // the scale is one plus every delta since the gesture began, held between
    // the dynamic minimum of its start (0.2 here) and 1.
    let zoom_at = |initial: f64, scale: f64| (initial * (1.0 + scale * 2.0)).clamp(0.2, 1.0);
    assert_eq!(pinch(&mut h, 0.0, Some("begin")), 1.0);
    assert_eq!(
        h.motion()["pinch"],
        json!({"output":1,"initial_zoom":1.0,"min_zoom":0.2,"scale":0.0})
    );
    let mut scale = 0.0;
    for (delta, phase) in [
        (-0.1, None),
        (-0.1, Some("update")),
        // Past the minimum and back: the zoom is where the scale says, not
        // where the clamp left it.
        (-0.5, None),
        (0.25, None),
        (0.35, None),
        // Past 1 and back.
        (0.5, None),
        (-0.55, None),
    ] {
        scale += delta;
        let zoom = pinch(&mut h, delta, phase);
        assert_eq!(zoom.to_bits(), zoom_at(1.0, scale).to_bits(), "{delta}");
    }
    assert_eq!(h.motion()["pinch"]["scale"], scale);
    // The end snaps a zoom within 0.05 of 1 onto it, as upstream's does.
    scale += 0.14;
    let last = zoom_at(1.0, scale);
    assert!(last > 0.95 && last < 1.0, "{last}");
    assert_eq!(pinch(&mut h, 0.14, None), last);
    assert_eq!(pinch(&mut h, 0.0, Some("end")), 1.0);
    assert_eq!(h.motion()["pinch"], Value::Null);
    // An end elsewhere leaves the zoom alone.
    pinch(&mut h, 0.0, Some("begin"));
    assert_eq!(pinch(&mut h, -0.2, Some("end")), zoom_at(1.0, -0.2));
    assert_eq!(h.motion()["pinch"], Value::Null);

    // A new gesture starts from the zoom it finds and the minimum of its own
    // start: with nothing on the canvas that is upstream's 5 x 5 stand-in.
    let mut h = configured(&scratch, "[zoom]\ntrackpad_speed = 2.0\n");
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":global(0.0, 0.0)}));
    pinch(&mut h, 0.0, Some("begin"));
    assert_eq!(
        h.motion()["pinch"],
        json!({"output":1,"initial_zoom":0.5,"min_zoom":0.5,"scale":0.0})
    );
    assert_eq!(pinch(&mut h, 0.1, None), 0.5 * (1.0 + 0.1 * 2.0));
    assert_eq!(pinch(&mut h, -0.4, None), 0.5);
    pinch(&mut h, 0.0, Some("end"));

    // An event outside a begun gesture is a gesture of its own: it scales the
    // zoom it finds, holds no state, and does not snap.
    let mut h = configured(&scratch, "[zoom]\ntrackpad_speed = 2.0\n");
    attach(&mut h, 1, rect(0.0, 0.0, 2000.0, 1600.0));
    let mut zoom = 1.0;
    for delta in [-0.1, -0.1, 0.05, 0.19] {
        zoom = zoom_at(zoom, delta);
        assert_eq!(pinch(&mut h, delta, None).to_bits(), zoom.to_bits());
        assert_eq!(h.motion()["pinch"], Value::Null);
    }
    assert!(zoom > 0.95 && zoom < 1.0, "{zoom}");
    assert_eq!(pinch(&mut h, 0.0, Some("end")), 1.0);

    // It ends a flight, and a change disarms a zoom-to-fit return.
    h.ok(json!({"op":"zoom_to_fit","output":1}));
    assert_eq!(h.motion()["flights"].as_object().unwrap().len(), 1);
    pinch(&mut h, 0.0, Some("begin"));
    assert_eq!(h.motion()["flights"], json!({}));
    assert!(h.motion()["overview_returns"].get("1").is_some());
    pinch(&mut h, -0.1, None);
    assert_eq!(h.motion()["overview_returns"], json!({}));
    // Removing the output ends its gesture.
    h.ok(json!({"op":"remove_output","output":1}));
    assert_eq!(h.motion()["pinch"], Value::Null);
}
