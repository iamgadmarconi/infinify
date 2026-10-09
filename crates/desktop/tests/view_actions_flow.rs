// SPDX-License-Identifier: GPL-3.0-or-later
//! View-action scenarios cross the exported C ABI and JSON decoder and settle
//! through tick_navigation. They provide no native rendering, capture, or
//! input-delivery evidence.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;

struct Host(*mut Controller);
impl Host {
    fn new() -> Self {
        let handle = driftwm_desktop_create();
        assert!(!handle.is_null());
        Self(handle)
    }
    fn raw(&mut self, bytes: &[u8]) -> Value {
        // SAFETY: live exclusive handle, valid bytes, response freed exactly once.
        unsafe {
            let response = driftwm_desktop_request(self.0, bytes.as_ptr(), bytes.len());
            assert!(!response.is_null());
            let result = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            driftwm_desktop_response_free(response);
            result
        }
    }
    fn call(&mut self, command: Value) -> Value {
        self.raw(&serde_json::to_vec(&json!({"version":1,"command":command})).unwrap())
    }
    fn ok(&mut self, command: Value) -> Value {
        let response = self.call(command);
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    }
    fn snapshot(&mut self) -> Value {
        self.ok(json!({"op":"snapshot"}))
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        unsafe {
            driftwm_desktop_destroy(self.0);
        }
    }
}
/// Output 1's usable center in output-local points.
const CENTER: (f64, f64) = (500.0, 410.0);
/// The fixture's integer bounding box is 2302 x 2902 and output 1's usable area
/// 960 x 740, so the 80 px padding leaves 580 px on the limiting axis.
const FIT: f64 = 580.0 / 2902.0;

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn context(h: &mut Host) {
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(20.0,40.0,960.0,740.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
}
fn setup() -> Host {
    let mut h = Host::new();
    // Neither output starts at the global origin, and output 1's usable area is
    // asymmetric, so a global point or the full size would miss every target.
    for (id, bounds) in [
        ("view-a", rect(100.0, 50.0, 1000.0, 800.0)),
        ("view-b", rect(1200.0, 50.0, 800.0, 600.0)),
    ] {
        h.ok(json!({"op":"register_output","stable_id":id,"screen_bounds":bounds}));
    }
    context(&mut h);
    // Fractional world frames; the observed native rectangle is unrelated.
    for (wid, world) in [
        (1, rect(-1000.5, -2000.25, 600.0, 400.0)),
        (2, rect(700.0, 500.0, 600.75, 400.5)),
    ] {
        h.ok(json!({"op":"attach","identity":{"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid},"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"world_rect":world}));
    }
    // Output 1 starts away from home at an exactly representable pose.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":100.0,"y":50.0}}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":150.0,"y":100.0}}));
    h
}
fn pose(h: &mut Host, output: usize) -> Value {
    h.snapshot()["outputs"][output - 1].clone()
}
fn returns(h: &mut Host, kind: &str) -> Value {
    h.snapshot()["navigation"][kind].clone()
}
fn view(op: &str) -> Value {
    json!({"op":op,"output":1})
}
fn num(value: &Value) -> f64 {
    value.as_f64().unwrap()
}
fn close(actual: &Value, expected: f64) {
    assert!(
        (num(actual) - expected).abs() < 1e-9,
        "{actual} != {expected}"
    );
}
/// World point under output 1's usable center.
fn centered(h: &mut Host) -> (f64, f64) {
    let pose = pose(h, 1);
    let zoom = num(&pose["zoom"]);
    (
        num(&pose["camera"]["x"]) + CENTER.0 / zoom,
        num(&pose["camera"]["y"]) + CENTER.1 / zoom,
    )
}
fn settle(h: &mut Host, clock: &mut u64, mut frame: impl FnMut(&mut Host)) {
    for _ in 0..600 {
        *clock += 16_666_667;
        let tick = h.ok(json!({"op":"tick_navigation","timestamp_ns":*clock}));
        let changed = tick["changed_outputs"].as_array().unwrap();
        assert!(!changed.contains(&json!(2)), "{tick}");
        frame(h);
        if tick["needs_frames"] == false {
            return;
        }
    }
    panic!("view flight did not settle");
}
/// Arm one action on output 1 and fly it to rest on its armed destination.
fn fly(h: &mut Host, clock: &mut u64, command: Value) -> Value {
    let armed = h.ok(command)["navigation"].clone();
    assert_eq!(armed["animating"], true, "{armed}");
    assert_eq!(armed["output"], 1);
    settle(h, clock, |_| {});
    let rest = pose(h, 1);
    assert_eq!(rest["camera"], armed["target_camera"]);
    assert_eq!(rest["zoom"], armed["target_zoom"]);
    armed
}

#[test]
fn fit_home_zoom_and_pan_fly_one_output_and_toggles_return_exactly() {
    let mut h = setup();
    let mut clock = 1_000_000_000;
    h.ok(json!({"op":"tick_navigation","timestamp_ns":clock}));
    // A fresh output is already home with nowhere to return to: nothing arms.
    assert_eq!(
        h.ok(json!({"op":"home_toggle","output":2})),
        json!({"navigation":null})
    );
    h.ok(json!({"op":"zoom","output":2,"zoom":0.5,"anchor":{"x":1200.0,"y":50.0}}));
    h.ok(json!({"op":"pan","output":2,"screen_delta":{"x":10.0,"y":20.0}}));
    let other = pose(&mut h, 2);
    let start = pose(&mut h, 1);
    assert_eq!(start["camera"], json!({"x":300.0,"y":200.0}));
    assert_eq!(start["zoom"], 0.5);
    let saved = json!({"1":{"camera":start["camera"],"zoom":0.5}});

    // Zoom-to-fit: the integer box (-1001,-2001)..(1301,901) centers on the
    // usable center and its height meets the padding.
    let fit = fly(&mut h, &mut clock, view("zoom_to_fit"));
    close(&fit["target_zoom"], FIT);
    close(&fit["target_camera"]["x"], 150.0 - CENTER.0 / FIT);
    close(&fit["target_camera"]["y"], -550.0 - CENTER.1 / FIT);
    assert_eq!(returns(&mut h, "overview_returns"), saved);
    let snapshot = h.snapshot();
    let placed: Vec<_> = snapshot["placements"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|p| p["output"] == 1)
        .collect();
    assert_eq!(placed.len(), 2);
    // Global usable area (120,90) 960 x 740, inset by 80 px on every side.
    let (mut top, mut bottom) = (f64::MAX, f64::MIN);
    for placement in placed {
        let r = &placement["screen_rect"];
        let (x, y) = (num(&r["origin"]["x"]), num(&r["origin"]["y"]));
        let (right, low) = (x + num(&r["size"]["width"]), y + num(&r["size"]["height"]));
        assert!(
            x >= 200.0 && right <= 1000.0 && y >= 170.0 && low <= 750.0,
            "{r}"
        );
        (top, bottom) = (top.min(y), bottom.max(low));
    }
    // The limiting axis is full up to the fractional frames' integer rounding.
    assert!(top < 171.0 && bottom > 749.0, "{top} {bottom}");
    let back = fly(&mut h, &mut clock, view("zoom_to_fit"));
    assert_eq!(back["target_camera"], start["camera"]);
    assert_eq!(pose(&mut h, 1), start);
    assert_eq!(returns(&mut h, "overview_returns"), json!({}));

    // Home: the world origin under the output-local usable center at zoom 1.
    let home = fly(&mut h, &mut clock, view("home_toggle"));
    assert_eq!(home["target_camera"], json!({"x":-500.0,"y":-410.0}));
    assert_eq!(home["target_zoom"], 1.0);
    assert_eq!(centered(&mut h), (0.0, 0.0));
    assert_eq!(returns(&mut h, "home_returns"), saved);
    fly(&mut h, &mut clock, view("home_toggle"));
    assert_eq!(pose(&mut h, 1), start);
    assert_eq!(returns(&mut h, "home_returns"), json!({}));

    // Two presses before any frame extend the destination: 2 x 100 px / 0.5.
    let pan = |direction: &str| json!({"op":"pan_viewport","output":1,"direction":direction});
    let first = h.ok(pan("right"))["navigation"].clone();
    assert_eq!(first["target_camera"], json!({"x":500.0,"y":200.0}));
    assert_eq!(first["target_zoom"], 0.5);
    assert_eq!(pose(&mut h, 1), start);
    let second = fly(&mut h, &mut clock, pan("right"));
    assert_eq!(second["target_camera"], json!({"x":700.0,"y":200.0}));
    assert_eq!(
        second["generation"].as_u64(),
        first["generation"].as_u64().map(|g| g + 1)
    );
    let diagonal = fly(&mut h, &mut clock, pan("up_left"));
    let step = 200.0 * std::f64::consts::FRAC_1_SQRT_2;
    close(&diagonal["target_camera"]["x"], 700.0 - step);
    close(&diagonal["target_camera"]["y"], 200.0 - step);

    // Keyboard zoom keeps the world point under the usable center fixed on
    // every frame of the flight.
    let fixed = centered(&mut h);
    for (op, zoom) in [
        ("zoom_out", 0.5 / 1.1),
        ("zoom_in", 0.5),
        ("zoom_reset", 1.0),
    ] {
        let armed = h.ok(view(op))["navigation"].clone();
        close(&armed["target_zoom"], zoom);
        settle(&mut h, &mut clock, |h| {
            let now = centered(h);
            assert!(
                (now.0 - fixed.0).abs() < 1e-6 && (now.1 - fixed.1).abs() < 1e-6,
                "{op}: {now:?} != {fixed:?}"
            );
        });
        assert_eq!(pose(&mut h, 1)["zoom"], armed["target_zoom"]);
    }
    // Native size is the ceiling: zoom_in re-arms the same zoom and settles.
    assert_eq!(fly(&mut h, &mut clock, view("zoom_in"))["target_zoom"], 1.0);
    // zoom_out stops at half the fit zoom, and below it does nothing at all
    // rather than zooming in (interactive zoom keeps the static 0.001 floor).
    h.ok(json!({"op":"zoom","output":1,"zoom":0.105,"anchor":{"x":100.0,"y":50.0}}));
    close(
        &fly(&mut h, &mut clock, view("zoom_out"))["target_zoom"],
        FIT / 2.0,
    );
    h.ok(json!({"op":"zoom","output":1,"zoom":0.01,"anchor":{"x":100.0,"y":50.0}}));
    let before = h.snapshot();
    assert_eq!(h.ok(view("zoom_out")), json!({"navigation":null}));
    assert_eq!(h.snapshot(), before);
    assert_eq!(pose(&mut h, 2), other);
}

#[test]
fn return_state_is_per_output_ephemeral_and_gestures_reject_view_actions() {
    let mut h = setup();
    // Every manual or window-directed camera move disarms the fit return, so
    // the next press fits again instead of restoring the 0.5 zoom it left.
    for clear in [
        json!({"op":"pan","output":1,"screen_delta":{"x":10.0,"y":0.0}}),
        json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":100.0,"y":50.0}}),
        json!({"op":"navigate_window","window":1,"output":1,"zoom_policy":"keep"}),
        json!({"op":"pan_viewport","output":1,"direction":"down_right"}),
        view("zoom_in"),
        view("zoom_out"),
        view("zoom_reset"),
        view("home_toggle"),
    ] {
        close(&h.ok(view("zoom_to_fit"))["navigation"]["target_zoom"], FIT);
        assert_eq!(returns(&mut h, "overview_returns")["1"]["zoom"], 0.5);
        h.ok(clear.clone());
        assert_eq!(returns(&mut h, "overview_returns"), json!({}), "{clear}");
    }
    // Another output's pan leaves this output's returns alone.
    close(&h.ok(view("zoom_to_fit"))["navigation"]["target_zoom"], FIT);
    h.ok(json!({"op":"pan","output":2,"screen_delta":{"x":5.0,"y":5.0}}));
    let navigation = h.snapshot()["navigation"].clone();
    for kind in ["home_returns", "overview_returns"] {
        let pending = navigation[kind].as_object().unwrap();
        assert!(pending.len() == 1 && pending.contains_key("1"), "{kind}");
    }

    // An active drag rejects every view action without touching any state.
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    let before = h.snapshot();
    for command in [
        json!({"op":"pan_viewport","output":1,"direction":"left"}),
        view("home_toggle"),
        view("zoom_in"),
        view("zoom_out"),
        view("zoom_reset"),
        view("zoom_to_fit"),
    ] {
        let response = h.call(command);
        assert_eq!(response["ok"], false, "{response}");
        assert_eq!(response["error"], "navigation during active gesture");
        assert_eq!(h.snapshot(), before);
    }
    h.ok(json!({"op":"end_gesture"}));
    for command in [
        json!({"op":"pan_viewport","output":1,"direction":"north"}),
        json!({"op":"pan_viewport","output":1}),
        json!({"op":"zoom_in","output":1,"extra":0}),
        json!({"op":"home_toggle"}),
        json!({"op":"zoom_to_fit","output":99}),
    ] {
        assert_eq!(h.call(command.clone())["ok"], false, "{command}");
        assert_eq!(h.snapshot(), before);
    }
    // Output 2's right edge sits about 5e4 inside the 1e12 world limit. One 1e5 pan
    // step would land the camera inside it and the far corner outside, a flight
    // no tick could ever apply: it is rejected before anything is armed.
    h.ok(json!({"op":"zoom","output":2,"zoom":0.001,"anchor":{"x":1200.0,"y":50.0}}));
    h.ok(json!({"op":"pan","output":2,"screen_delta":{"x":999_999_150.0,"y":0.0}}));
    let edge = h.snapshot();
    let response = h.call(json!({"op":"pan_viewport","output":2,"direction":"right"}));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"], "navigation target out of bounds");
    assert_eq!(h.snapshot(), edge);

    // Save carries no return state and load starts without any.
    let path =
        std::env::temp_dir().join(format!("driftwm-view-actions-{}.json", std::process::id()));
    h.ok(json!({"op":"save","path":path}));
    assert!(!std::fs::read_to_string(&path).unwrap().contains("return"));
    h.ok(json!({"op":"load","path":path}));
    std::fs::remove_file(path).unwrap();
    let navigation = h.snapshot()["navigation"].clone();
    assert_eq!(navigation["home_returns"], json!({}));
    assert_eq!(navigation["overview_returns"], json!({}));
    assert_eq!(
        h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":rect(100.0,50.0,1000.0,800.0)})),
        json!({"output":1})
    );
    context(&mut h);
    // Detached placeholders still bound the fit, and nothing is restored.
    assert_eq!(h.snapshot()["windows"][0]["source"], Value::Null);
    assert_eq!(h.ok(view("home_toggle"))["navigation"]["target_zoom"], 1.0);
    close(&h.ok(view("zoom_to_fit"))["navigation"]["target_zoom"], FIT);
    let navigation = h.snapshot()["navigation"].clone();
    assert!(navigation["home_returns"].get("1").is_some());
    assert!(navigation["overview_returns"].get("1").is_some());
    // Disconnecting the output drops its returns; reconnecting does not revive them.
    h.ok(json!({"op":"remove_output","output":1}));
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":rect(100.0,50.0,1000.0,800.0)}));
    let navigation = h.snapshot()["navigation"].clone();
    assert_eq!(navigation["home_returns"], json!({}));
    assert_eq!(navigation["overview_returns"], json!({}));
}
