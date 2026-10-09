// SPDX-License-Identifier: GPL-3.0-or-later
//! Hot corners, output transfer, keyboard layouts, the State event stream,
//! autostart and upstream's Linux default commands, through the exported C ABI
//! and JSON decoder with config files in a throwaway directory. Expected
//! positions are worked out by hand from the adapted upstream rules, not from an
//! oracle build. Nothing here watches a pointer, warps one, selects an input
//! source, writes to a socket or starts a process: those are the shell's.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::ffi::CStr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
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
    /// A controller error, which must leave the controller as it was.
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
    fn action_on(&mut self, output: Value, action: &str) -> Value {
        self.ok(json!({"op":"action","output":output,"action":action}))
    }
    fn refused(&mut self, output: Value, action: &str) -> String {
        self.error(json!({"op":"action","output":output,"action":action}))
    }
    fn corner(&mut self, output: u64, corner: &str) -> Value {
        self.ok(json!({"op":"hot_corner","output":output,"corner":corner}))
    }
    fn ipc(&mut self, output: Value, request: Value) -> Value {
        self.ok(json!({"op":"ipc","output":output,"request":request}))
    }
    fn load_config(&mut self, path: &PathBuf) -> Value {
        self.ok(json!({"op":"load_config","path":path}))
    }
    fn bindings(&mut self) -> Value {
        self.ok(json!({"op":"bindings"}))
    }
    /// A window's world rectangle, by logical id: raising reorders the list.
    fn world(&mut self, window: u64) -> Value {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == window)
            .unwrap()["world_rect"]
            .clone()
    }
    /// Stage order, bottom to top.
    fn stack(&mut self) -> Vec<u64> {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w["window"].as_u64().unwrap())
            .collect()
    }
    /// The pending State event line, or null.
    fn event(&mut self, output: Value) -> Value {
        self.ok(json!({"op":"state_event","output":output}))["line"].clone()
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
            "infinify-platform-flow-{}-{}",
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
    /// A directory of this scratch holding one file per name, each with `mode`.
    fn programs(&self, directory: &str, names: &[&str], mode: u32) -> PathBuf {
        let path = self.0.join(directory);
        std::fs::create_dir_all(&path).unwrap();
        for name in names {
            let file = path.join(name);
            std::fs::write(&file, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(mode)).unwrap();
        }
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
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid})
}
fn attach(h: &mut Host, wid: u64, world: Value) {
    h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(9000.0,9000.0,300.0,200.0),"world_rect":world}));
}
fn focus(h: &mut Host, window: u64) {
    h.ok(json!({"op":"focus","window":window}));
}
/// Output 1 at the global origin, output 2 to its right and lower, output 3
/// above output 1 and wider. Their centers are (500, 400), (1800, 550) and
/// (500, -600) in the shell's top-left, Y-down screen space.
const BOUNDS: [(&str, [f64; 4]); 3] = [
    ("left", [0.0, 0.0, 1000.0, 800.0]),
    ("right", [1000.0, 100.0, 1600.0, 900.0]),
    ("above", [-200.0, -1200.0, 1400.0, 1200.0]),
];
fn register(h: &mut Host, count: usize) {
    for (name, [x, y, w, h_]) in &BOUNDS[..count] {
        h.ok(
            json!({"op":"register_output","stable_id":name,"screen_bounds":rect(*x, *y, *w, *h_)}),
        );
    }
}
/// Give a freshly registered output a camera and zoom of its own.
fn pose(h: &mut Host, output: usize, camera: (f64, f64), zoom: f64) {
    let [x, y, _, _] = BOUNDS[output - 1].1;
    // Zooming about the output's own top-left corner keeps the camera at the
    // origin; the pan then moves it by `delta / zoom`.
    h.ok(json!({"op":"zoom","output":output,"zoom":zoom,"anchor":point(x, y)}));
    h.ok(
        json!({"op":"pan","output":output,"screen_delta":point(camera.0 * zoom, camera.1 * zoom)}),
    );
    let viewport = h.snapshot()["outputs"][output - 1].clone();
    assert_eq!(viewport["camera"], point(camera.0, camera.1));
    assert_eq!(viewport["zoom"], zoom);
}
/// Output 2 looks at a far part of the canvas at half size, under a 40 point
/// band its usable area leaves out: its usable center is (800, 470).
fn pose_right(h: &mut Host) {
    pose(h, 2, (3000.0, -2000.0), 0.5);
    h.ok(json!({"op":"set_navigation_context","output":2,"usable_rect_local":rect(0.0,40.0,1600.0,860.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
}
fn toml_string(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}
fn idle() -> Value {
    json!({"navigation":null,"effects":[],"dirty":false})
}
fn moved() -> Value {
    json!({"navigation":null,"effects":[],"dirty":true})
}
fn by_combo(entries: &Value) -> BTreeMap<String, Value> {
    entries
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| (entry["combo"].as_str().unwrap().to_owned(), entry.clone()))
        .collect()
}

const HOT_CORNERS: &str = r#"
[[outputs]]
name = "*"
[outputs.hot_corners]
threshold = 6
top_left = "zoom-to-fit"
top_right = "none"
bottom_right = "exec say corner"

[[outputs]]
name = "right"
[outputs.hot_corners]
disable_while_dragging = false
top_left = "close-window"
bottom_left = "send-cursor-to-output left"
bottom_right = "spawn say dragged"

[[outputs]]
name = "above"
focus_placement = "left"
"#;

#[test]
fn hot_corners_follow_the_outputs_entry_and_upstreams_wildcard() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    register(&mut h, 3);
    attach(&mut h, 1, rect(100.0, 100.0, 400.0, 300.0));
    // No config yet: every output is listed, and no corner is armed.
    let unarmed = |output: u64, name: &str| json!({"output":output,"stable_id":name,"threshold":4.0,"disable_while_dragging":true,"disable_when_fullscreen":true,"corners":{}});
    assert_eq!(
        h.bindings()["hot_corners"],
        json!([unarmed(1, "left"), unarmed(2, "right"), unarmed(3, "above")])
    );
    assert_eq!(h.corner(1, "top_left"), idle());

    let loaded = h.load_config(&scratch.write("config.toml", HOT_CORNERS));
    assert_eq!(loaded["errors"], json!([]));
    assert_eq!(loaded["warnings"], json!([]));
    // `left` has no entry of its own and takes the wildcard's; `right` has its
    // own; `above` has an exact entry without hot corners, which replaces the
    // wildcard whole, so it has none. `none` arms nothing.
    assert_eq!(
        h.bindings()["hot_corners"],
        json!([
            {"output":1,"stable_id":"left","threshold":6.0,"disable_while_dragging":true,"disable_when_fullscreen":true,
             "corners":{"top_left":"zoom-to-fit","bottom_right":"exec say corner"}},
            {"output":2,"stable_id":"right","threshold":4.0,"disable_while_dragging":false,"disable_when_fullscreen":true,
             "corners":{"top_left":"close-window","bottom_left":"send-cursor-to-output left","bottom_right":"spawn say dragged"}},
            unarmed(3, "above"),
        ])
    );

    // A corner runs its action exactly as `action` would on that output.
    let fit = h.corner(1, "top_left");
    assert_eq!(fit["navigation"]["output"], 1, "{fit}");
    assert_eq!(fit["navigation"]["animating"], true);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    let exec = h.corner(1, "bottom_right");
    assert_eq!(exec, h.action_on(json!(1), "exec say corner"));
    assert_eq!(exec["effects"][0]["command"], "say corner");
    // The corner's own output is the active one: output 1 is to the left of 2.
    assert_eq!(
        h.corner(2, "bottom_left"),
        json!({"navigation":null,"effects":[{"op":"warp_pointer","screen":point(500.0,400.0),"output":1}],"dirty":false})
    );
    // An unarmed corner, `none`, and an output without corners answer idle.
    for (output, corner) in [
        (1, "top_right"),
        (1, "bottom_left"),
        (2, "top_right"),
        (3, "top_left"),
        (3, "bottom_right"),
    ] {
        assert_eq!(h.corner(output, corner), idle(), "{output} {corner}");
    }
    // An action that does not run here is refused by name, as a binding's is.
    assert_eq!(
        h.error(json!({"op":"hot_corner","output":2,"corner":"top_left"})),
        "action not implemented on macOS yet: close-window"
    );
    assert_eq!(
        h.error(json!({"op":"hot_corner","output":99,"corner":"top_left"})),
        "unknown output"
    );
    for command in [
        json!({"op":"hot_corner","output":1,"corner":"middle"}),
        json!({"op":"hot_corner","output":1}),
        json!({"op":"hot_corner","corner":"top_left"}),
        json!({"op":"hot_corner","output":1,"corner":"top_left","extra":0}),
    ] {
        h.error(command);
    }

    // Upstream's disable_while_dragging: a pointer grab suppresses the corner
    // without an error. zoom-to-fit itself would be refused during a gesture.
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(h.corner(1, "top_left"), idle());
    assert_eq!(h.corner(1, "bottom_right"), idle());
    // Output 2 turned the rule off, so its corner still fires.
    assert_eq!(
        h.corner(2, "bottom_right")["effects"][0]["command"],
        "say dragged"
    );
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(
        h.corner(1, "bottom_right")["effects"][0]["command"],
        "say corner"
    );

    // The list follows the registered outputs and the config in force.
    h.ok(json!({"op":"remove_output","output":2}));
    let listed = h.bindings()["hot_corners"].clone();
    assert_eq!(listed.as_array().unwrap().len(), 2);
    assert_eq!(listed[1], unarmed(3, "above"));
    h.load_config(&scratch.write("config.toml", "mod_key = \"super\"\n"));
    assert_eq!(
        h.bindings()["hot_corners"],
        json!([unarmed(1, "left"), unarmed(3, "above")])
    );
    assert_eq!(h.corner(1, "top_left"), idle());
}

#[test]
fn send_to_output_lands_on_the_adjacent_outputs_placement_point() {
    let mut h = Host::new();
    register(&mut h, 2);
    pose_right(&mut h);
    attach(&mut h, 1, rect(100.0, 100.0, 400.0, 300.0));
    // Without a focused window nothing happens, with or without an output.
    assert_eq!(h.action_on(Value::Null, "send-to-output right"), idle());
    focus(&mut h, 1);

    // The window's center (300, 250) is shown by output 1 alone, so that is
    // the source whatever the active output is. Output 2 is to its right. Its
    // usable center (800, 470) at zoom 0.5 over camera (3000, -2000) is canvas
    // (3000 + 1600, -2000 + 940) = (4600, -1060); less half of 400 x 300.
    assert_eq!(h.action_on(Value::Null, "send-to-output right"), moved());
    assert_eq!(h.world(1), rect(4400.0, -1210.0, 400.0, 300.0));
    // Only output 2 shows it now, and nothing lies up, down or right of that.
    for direction in ["up", "down", "right", "up-right", "down-right"] {
        let action = format!("send-to-output {direction}");
        assert_eq!(h.action_on(json!(1), &action), idle(), "{direction}");
    }
    assert_eq!(h.world(1), rect(4400.0, -1210.0, 400.0, 300.0));
    // Left of output 2 is output 1: camera at the origin, zoom 1, usable
    // center (500, 400).
    assert_eq!(h.action_on(Value::Null, "send-to-output left"), moved());
    assert_eq!(h.world(1), rect(300.0, 250.0, 400.0, 300.0));
    // From output 1 only the right half-plane holds an output.
    for direction in ["up", "down", "left", "up-left", "down-left"] {
        let action = format!("send-to-output {direction}");
        assert_eq!(h.action_on(json!(2), &action), idle(), "{direction}");
    }

    // Pan output 1 away. Upstream rounds the camera before it asks what an
    // output shows: (-700.5, -600.75) reads (-701, -601), whose 1002 x 802
    // view stops short of the window's center (500, 400). No output shows the
    // window, so the active output is the source, and one is needed.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(-700.5, -600.75)}));
    assert_eq!(
        h.refused(Value::Null, "send-to-output right"),
        "no active output"
    );
    assert_eq!(
        h.refused(json!(99), "send-to-output right"),
        "unknown output"
    );
    assert_eq!(h.action_on(json!(2), "send-to-output right"), idle());
    assert_eq!(h.action_on(json!(1), "send-to-output right"), moved());
    assert_eq!(h.world(1), rect(4400.0, -1210.0, 400.0, 300.0));
    // Back on output 1 the center is (-700.5 + 500, -600.75 + 400) =
    // (-200.5, -200.75) and the corner (-400.5, -350.75). Upstream truncates
    // toward zero: (-400, -350), where rounding or flooring gives -401, -351.
    assert_eq!(h.action_on(Value::Null, "send-to-output left"), moved());
    assert_eq!(h.world(1), rect(-400.0, -350.0, 400.0, 300.0));

    // An odd size leaves halves on both axes: (4600 - 200.5, -1060 - 150.5) =
    // (4399.5, -1210.5), truncated to (4399, -1210). Output 1's rounded view
    // starts at (-701, -601) and shows the center (200.5, 150.5).
    attach(&mut h, 2, rect(0.0, 0.0, 401.0, 301.0));
    focus(&mut h, 2);
    attach(&mut h, 3, rect(0.0, 0.0, 50.0, 50.0));
    assert_eq!(h.stack(), [1, 2, 3]);
    let focus_before = h.snapshot()["focus"].clone();
    assert_eq!(h.action_on(Value::Null, "send-to-output right"), moved());
    assert_eq!(h.world(2), rect(4399.0, -1210.0, 401.0, 301.0));
    // Upstream raises what it sends. The window already held the logical
    // focus, and nothing is asked of native focus.
    assert_eq!(h.stack(), [1, 3, 2]);
    assert_eq!(h.snapshot()["focus"], focus_before);
    assert_eq!(focus_before["intent"], 2);

    // A fractional frame crosses upstream's integer boundary first: it reads
    // (10, 21) 400 x 301, so half is (200, 150.5), and its size is kept. Sent
    // back to output 1: (-200.5 - 200, -200.75 - 150.5) = (-400.5, -351.25).
    attach(&mut h, 4, rect(4410.4, -1189.4, 400.4, 300.6));
    focus(&mut h, 4);
    assert_eq!(h.action_on(Value::Null, "send-to-output left"), moved());
    assert_eq!(h.world(4), rect(-400.0, -351.0, 400.4, 300.6));

    // A logical world move, so a gesture in progress refuses it.
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(
        h.refused(json!(1), "send-to-output right"),
        "a window is under an interactive move or resize"
    );
}

#[test]
fn the_source_output_is_the_one_whose_rounded_view_shows_the_truncated_center() {
    let mut h = Host::new();
    register(&mut h, 2);
    pose_right(&mut h);
    // Output 2 is the active one throughout and has nothing to its right, so a
    // window moves exactly when output 1 is found to show it.
    let sent = |h: &mut Host, window: u64, world: Value| {
        attach(h, window, world);
        focus(h, window);
        let reply = h.action_on(json!(2), "send-to-output right");
        assert!(reply == moved() || reply == idle(), "{reply}");
        reply == moved()
    };
    // The center is (-0.5, 250), which upstream truncates to (0, 250). At
    // camera x = 0.5 the view is rounded to start at 1 and misses it; flooring
    // the camera would show it.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(0.5, 0.0)}));
    assert!(!sent(&mut h, 1, rect(-201.0, 100.0, 401.0, 300.0)));
    // At camera x = 0.4 the view starts at 0 and shows it; rounding the camera
    // up, or flooring the center to -1, would miss it.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(-0.1, 0.0)}));
    assert_eq!(h.action_on(json!(2), "send-to-output right"), moved());
    assert_eq!(h.world(1), rect(4399.0, -1210.0, 401.0, 300.0));
    // Upstream's view is two points wider than the output, and half-open: a
    // 1000 point output at camera 0 shows x = 1001 and not x = 1002.
    assert!(sent(&mut h, 2, rect(801.0, 100.0, 400.0, 300.0)));
    assert!(!sent(&mut h, 3, rect(802.0, 100.0, 400.0, 300.0)));
}

#[test]
fn send_to_output_parks_the_window_by_the_targets_focus_placement() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    register(&mut h, 2);
    pose_right(&mut h);
    let loaded = h.load_config(&scratch.write(
        "config.toml",
        "focus_placement = \"bottom-right\"\n[snap]\nouter_gap = 12.0\n[[outputs]]\nname = \"right\"\nfocus_placement = \"top-left\"\n",
    ));
    assert_eq!(loaded["errors"], json!([]));
    assert_eq!(loaded["warnings"], json!([]));
    attach(&mut h, 1, rect(100.0, 100.0, 400.0, 300.0));
    focus(&mut h, 1);
    // Output 2 parks windows top-left. At zoom 0.5 the frame is 200 x 150 on
    // screen and the gap 6, inside the usable area that starts at y = 40: the
    // placement point is (6 + 100, 40 + 6 + 75) = (106, 121), which is canvas
    // (3000 + 212, -2000 + 242) = (3212, -1758); less half of 400 x 300.
    assert_eq!(h.action_on(Value::Null, "send-to-output right"), moved());
    assert_eq!(h.world(1), rect(3012.0, -1908.0, 400.0, 300.0));
    // Output 1 takes the top-level bottom-right at zoom 1 with the 12 point
    // gap: (1000 - 12 - 200, 800 - 12 - 150) = (788, 638).
    assert_eq!(h.action_on(Value::Null, "send-to-output left"), moved());
    assert_eq!(h.world(1), rect(588.0, 488.0, 400.0, 300.0));
}

#[test]
fn three_outputs_are_adjacent_as_upstreams_direction_cone_says() {
    let mut h = Host::new();
    register(&mut h, 3);
    pose_right(&mut h);
    attach(&mut h, 1, rect(100.0, 100.0, 400.0, 300.0));
    focus(&mut h, 1);

    // The center of the target's usable area in global screen points: output
    // 1's whole 1000 x 800, output 2's usable (800, 470) past its origin
    // (1000, 100), output 3's whole 1400 x 1200 past (-200, -1200). The
    // camera and zoom of the target do not enter it.
    let warp = |output: u64| {
        let screen = match output {
            1 => point(500.0, 400.0),
            2 => point(1800.0, 570.0),
            _ => point(500.0, -600.0),
        };
        json!({"navigation":null,"effects":[{"op":"warp_pointer","screen":screen,"output":output}],"dirty":false})
    };
    // Centers (500, 400), (1800, 550), (500, -600). A target must lie within
    // 60 degrees of the direction, and the nearest such center wins: from 2,
    // `left` reaches both 1 (1308.6 away) and 3 (1735.7 away) and takes 1,
    // while `up` reaches only 3, at cosine 1150 / 1735.7 = 0.66.
    const NONE: u64 = 0;
    let table: [(u64, [u64; 8]); 3] = [
        (1, [3, NONE, NONE, 2, 3, 3, NONE, 2]),
        (2, [3, NONE, 1, NONE, 1, NONE, 1, NONE]),
        (3, [NONE, 1, NONE, 2, NONE, NONE, 1, 1]),
    ];
    let directions = [
        "up",
        "down",
        "left",
        "right",
        "up-left",
        "up-right",
        "down-left",
        "down-right",
    ];
    for (from, targets) in table {
        for (direction, target) in directions.iter().zip(targets) {
            let reply = h.action_on(json!(from), &format!("send-cursor-to-output {direction}"));
            let expected = if target == NONE { idle() } else { warp(target) };
            assert_eq!(reply, expected, "from {from} {direction}");
        }
    }
    assert_eq!(
        h.refused(Value::Null, "send-cursor-to-output up"),
        "no active output"
    );
    assert_eq!(
        h.refused(json!(99), "send-cursor-to-output up"),
        "unknown output"
    );

    // Outputs 1 and 3 both start at the origin and both show the window's
    // center (300, 250). Upstream takes the first registered, not the active
    // one: from 1 nothing lies below, though output 1 lies below output 3.
    assert_eq!(h.action_on(json!(3), "send-to-output down"), idle());
    assert_eq!(h.world(1), rect(100.0, 100.0, 400.0, 300.0));

    // Output 3 at a quarter size over camera (-4000, 4000): its usable center
    // (700, 600) is canvas (-4000 + 2800, 4000 + 2400) = (-1200, 6400).
    pose(&mut h, 3, (-4000.0, 4000.0), 0.25);
    let above = rect(-1400.0, 6250.0, 400.0, 300.0);
    let left = rect(300.0, 250.0, 400.0, 300.0);
    let right = rect(4400.0, -1210.0, 400.0, 300.0);
    for (direction, lands) in [
        ("up", &above),
        ("down", &left),
        ("right", &right),
        ("up", &above),
        ("right", &right),
        ("left", &left),
    ] {
        let action = format!("send-to-output {direction}");
        assert_eq!(h.action_on(Value::Null, &action), moved(), "{direction}");
        assert_eq!(h.world(1), *lands, "{direction}");
    }
}

#[test]
fn a_single_output_has_no_neighbour() {
    let mut h = Host::new();
    register(&mut h, 1);
    attach(&mut h, 1, rect(100.0, 100.0, 400.0, 300.0));
    focus(&mut h, 1);
    let before = h.snapshot();
    for direction in ["up", "down", "left", "right", "up-left", "down-right"] {
        for action in ["send-to-output", "send-cursor-to-output"] {
            let action = format!("{action} {direction}");
            assert_eq!(h.action_on(json!(1), &action), idle(), "{action}");
        }
    }
    assert_eq!(h.snapshot(), before);
    // Over IPC both are an `Ok` that asks nothing of the shell.
    assert_eq!(
        h.ipc(json!(1), json!({"Action":"send-to-output left"})),
        json!({"reply":{"Ok":"Ok"},"effects":[],"dirty":false,"navigation":null})
    );
}

#[test]
fn switch_layout_is_the_shells_effect_and_the_reported_layout_answers_ipc() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    register(&mut h, 1);
    let switch = |target: &str, index: Value| json!({"navigation":null,"effects":[{"op":"switch_layout","target":target,"index":index}],"dirty":false});
    // Every form upstream's grammar has; none needs an output.
    for (action, expected) in [
        ("switch-layout next", switch("next", Value::Null)),
        ("switch-layout prev", switch("prev", Value::Null)),
        ("switch-layout previous", switch("prev", Value::Null)),
        ("switch-layout NEXT", switch("next", Value::Null)),
        ("switch-layout 0", switch("index", json!(0))),
        ("switch-layout 2", switch("index", json!(2))),
    ] {
        assert_eq!(h.action_on(Value::Null, action), expected, "{action}");
        assert_eq!(h.action_on(json!(1), action), expected, "{action}");
    }
    assert_eq!(
        h.ipc(Value::Null, json!({"Action":"switch-layout 1"})),
        json!({"reply":{"Ok":"Ok"},"effects":[{"op":"switch_layout","target":"index","index":1}],"dirty":false,"navigation":null})
    );
    assert_eq!(
        h.refused(json!(1), "switch-layout -1"),
        "switch-layout: expected next, prev, or an index, got '-1'"
    );

    let layout = |h: &mut Host, short: bool| {
        let data = h.ipc(Value::Null, json!({"Layout":{"short":short}}));
        assert_eq!(data["effects"], json!([]));
        assert_eq!(data["dirty"], false);
        data["reply"]["Ok"]["Layout"].clone()
    };
    let state = |h: &mut Host| h.ipc(json!(1), json!("State"))["reply"]["Ok"]["State"].clone();
    // Nothing reported yet: upstream's shapes, with nothing in them.
    assert_eq!(layout(&mut h, false), "");
    assert_eq!(layout(&mut h, true), "");
    assert_eq!(h.snapshot()["keyboard_layout"], Value::Null);

    h.ok(json!({"op":"layout_changed","name":"U.S.","short":"US","index":0,"count":2}));
    assert_eq!(layout(&mut h, false), "U.S.");
    assert_eq!(layout(&mut h, true), "US");
    assert_eq!(state(&mut h)["layout"], "U.S.");
    assert_eq!(state(&mut h)["layout_short"], "US");
    h.ok(json!({"op":"layout_changed","name":"Russian","short":"RU","index":1,"count":2}));
    assert_eq!(layout(&mut h, false), "Russian");
    assert_eq!(layout(&mut h, true), "RU");
    assert_eq!(
        h.snapshot()["keyboard_layout"],
        json!({"name":"Russian","short":"RU","index":1,"count":2})
    );
    // Upstream's short form falls back to the display name.
    h.ok(json!({"op":"layout_changed","name":"Dvorak","short":"","index":0,"count":1}));
    assert_eq!(layout(&mut h, true), "Dvorak");
    assert_eq!(state(&mut h)["layout_short"], "Dvorak");

    // A report that names no layout among the enabled ones is refused.
    for command in [
        json!({"op":"layout_changed","name":"U.S.","short":"US","index":2,"count":2}),
        json!({"op":"layout_changed","name":"U.S.","short":"US","index":0,"count":0}),
        json!({"op":"layout_changed","name":"U.\u{0}S.","short":"US","index":0,"count":1}),
        json!({"op":"layout_changed","name":"U.S.","short":"US","index":-1,"count":1}),
        json!({"op":"layout_changed","name":"U.S.","index":0,"count":1}),
        json!({"op":"layout_changed","name":"U.S.","short":"US","index":0,"count":1,"extra":0}),
    ] {
        h.error(command);
    }
    assert_eq!(layout(&mut h, false), "Dvorak");

    // The layout is the machine's, not the scene's: a load keeps it, and a
    // save does not carry it.
    let scene = scratch.0.join("scene.json");
    h.ok(json!({"op":"save","path":scene}));
    assert!(!std::fs::read_to_string(&scene).unwrap().contains("Dvorak"));
    h.ok(json!({"op":"load","path":scene}));
    assert_eq!(layout(&mut h, false), "Dvorak");
    let mut fresh = Host::new();
    fresh.ok(json!({"op":"load","path":scene}));
    assert_eq!(layout(&mut fresh, false), "");
}

#[test]
fn subscribe_and_state_event_carry_upstreams_event_line() {
    let mut h = Host::new();
    register(&mut h, 2);
    attach(&mut h, 1, rect(100.0, 100.0, 400.0, 300.0));
    let state =
        |h: &mut Host, output: Value| h.ipc(output, json!("State"))["reply"]["Ok"]["State"].clone();
    let parsed = |line: &Value| serde_json::from_str::<Value>(line.as_str().unwrap()).unwrap();

    // Upstream's subscribe: the ack, and the current snapshot for the shell to
    // write after it. The line is upstream's serialization of its own typed
    // event, member order and float form included.
    let subscribed = h.ipc(json!(1), json!("Subscribe"));
    assert_eq!(subscribed["reply"], json!({"Ok":"Ok"}));
    assert_eq!(subscribed["dirty"], false);
    assert_eq!(subscribed["navigation"], Value::Null);
    let effects = subscribed["effects"].as_array().unwrap();
    assert_eq!(effects.len(), 1);
    assert_eq!(effects[0]["op"], "subscribe");
    let line = effects[0]["line"].clone();
    let text = line.as_str().unwrap();
    assert!(
        text.starts_with(
            r#"{"State":{"camera":[500.0,-400.0],"zoom":1.0,"layout":"","layout_short":"","windows":[{"id":1,"app_id":"test","title":"fixture","position":[300,-250],"size":[400,300],"is_focused":false,"is_widget":false,"suspended":false,"mode":"Normal"}],"fullscreen":[],"pinned":[],"layers":[],"canvas_layers":[],"outputs":[{"name":"left","camera":[500.0,-400.0],"zoom":1.0,"size":[1000,800],"active":true,"active_bookmark":null},"#
        ),
        "{text}"
    );
    assert!(!text.contains('\n'));
    assert_eq!(parsed(&line), json!({"State":state(&mut h, json!(1))}));

    // Upstream's broadcast: the first one of a run always goes out, since a
    // subscribe snapshot is not a broadcast. After that only a changed event.
    assert_eq!(h.event(json!(1)), line);
    assert_eq!(h.event(json!(1)), Value::Null);
    assert_eq!(
        h.ipc(json!(1), json!("Subscribe"))["effects"][0]["line"],
        line
    );
    assert_eq!(h.event(json!(1)), Value::Null);
    // Requests that change nothing State reports push nothing.
    h.ok(json!({"op":"hit","output":1,"screen":point(5.0, 5.0)}));
    h.ipc(json!(1), json!({"Camera":null}));
    assert_eq!(h.event(json!(1)), Value::Null);

    // A camera, a window, the focus, the layout and the active output are all
    // part of the state, and each change is one event.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(10.0, 0.0)}));
    let panned = h.event(json!(1));
    assert_eq!(parsed(&panned)["State"]["camera"], json!([510.0, -400.0]));
    assert_eq!(h.event(json!(1)), Value::Null);
    h.ipc(json!(1), json!({"Move":{"window":1,"to":[0,0]}}));
    assert_eq!(
        parsed(&h.event(json!(1)))["State"]["windows"][0]["position"],
        json!([0, 0])
    );
    focus(&mut h, 1);
    assert_eq!(
        parsed(&h.event(json!(1)))["State"]["windows"][0]["is_focused"],
        true
    );
    h.ok(json!({"op":"layout_changed","name":"U.S.","short":"US","index":0,"count":1}));
    assert_eq!(parsed(&h.event(json!(1)))["State"]["layout_short"], "US");
    let other = h.event(json!(2));
    assert_eq!(parsed(&other), json!({"State":state(&mut h, json!(2))}));
    assert_eq!(parsed(&other)["State"]["outputs"][1]["active"], true);
    assert_eq!(h.event(json!(2)), Value::Null);
    let none = h.event(Value::Null);
    assert_eq!(parsed(&none)["State"]["camera"], json!([0.0, 0.0]));
    assert_eq!(h.event(Value::Null), Value::Null);

    // While a flight animates, each frame that moved the camera is one event,
    // and a frame that moved nothing is none.
    h.action_on(json!(1), "pan-viewport right");
    let mut clock = 1_000_000_000u64;
    h.ok(json!({"op":"tick_navigation","timestamp_ns":clock}));
    assert_ne!(h.event(json!(1)), Value::Null);
    let (mut frames, mut events) = (0, 0);
    loop {
        clock += 16_000_000;
        let tick = h.ok(json!({"op":"tick_navigation","timestamp_ns":clock}));
        let moved = !tick["changed_outputs"].as_array().unwrap().is_empty();
        assert_eq!(h.event(json!(1)) != Value::Null, moved);
        frames += 1;
        events += usize::from(moved);
        if tick["needs_frames"] == false {
            break;
        }
        assert!(frames < 600);
    }
    assert!(events > 3, "{events}");
    clock += 16_000_000;
    h.ok(json!({"op":"tick_navigation","timestamp_ns":clock}));
    assert_eq!(h.event(json!(1)), Value::Null);

    // An output that is not registered has no state to report.
    assert_eq!(
        h.error(json!({"op":"state_event","output":99})),
        "unknown output"
    );
    assert_eq!(
        h.ipc(json!(99), json!("Subscribe")),
        json!({"reply":{"Err":"unknown output"},"effects":[],"dirty":false,"navigation":null})
    );
    h.error(json!({"op":"state_event","output":1,"extra":0}));
    // No refusal moved the baseline.
    assert_eq!(h.event(json!(1)), Value::Null);
}

#[test]
fn autostart_commands_are_exec_effects_of_the_launch_load_only() {
    let scratch = Scratch::new();
    let toml = "autostart = [\"open -a Notes\", \"echo started > /dev/null\"]\n[env]\nGREETING = \"hello\"\n";
    let path = scratch.write("config.toml", toml);
    let mut h = Host::new();
    register(&mut h, 1);
    let launch = h.load_config(&path);
    assert_eq!(launch["errors"], json!([]));
    // Each is exactly the effect `exec <cmd>` returns: `sh -c` with the
    // config's child environment.
    let exec = |h: &mut Host, command: &str| {
        h.action_on(Value::Null, &format!("exec {command}"))["effects"][0].clone()
    };
    assert_eq!(
        launch["effects"],
        json!([
            exec(&mut h, "open -a Notes"),
            exec(&mut h, "echo started > /dev/null")
        ])
    );
    assert_eq!(launch["effects"][0]["op"], "exec");
    assert_eq!(launch["effects"][0]["command"], "open -a Notes");
    assert_eq!(launch["effects"][0]["env"]["GREETING"], "hello");
    // Never again: not on a reload, not when the list changes, not after a
    // scene load.
    assert_eq!(h.load_config(&path)["effects"], json!([]));
    let changed = scratch.write("config.toml", "autostart = [\"open -a Calculator\"]\n");
    assert_eq!(h.load_config(&changed)["effects"], json!([]));
    let scene = scratch.0.join("scene.json");
    h.ok(json!({"op":"save","path":scene}));
    h.ok(json!({"op":"load","path":scene}));
    assert_eq!(h.load_config(&changed)["effects"], json!([]));

    // Upstream starts with its defaults when the file is broken, and those
    // autostart nothing; fixing the file later is a reload.
    let mut h = Host::new();
    let broken = scratch.write("broken.toml", "autostart = [\"open -a Notes\"\n");
    let reply = h.load_config(&broken);
    assert_eq!(reply["errors"].as_array().unwrap().len(), 1);
    assert_eq!(reply["effects"], json!([]));
    assert_eq!(h.load_config(&path)["effects"], json!([]));
    // No file and no autostart key both start nothing.
    let mut h = Host::new();
    assert_eq!(
        h.load_config(&scratch.0.join("absent.toml"))["effects"],
        json!([])
    );
    let mut h = Host::new();
    let plain = scratch.write("plain.toml", "mod_key = \"super\"\n");
    assert_eq!(h.load_config(&plain)["effects"], json!([]));
}

/// Upstream's default programs, none of which a Mac has.
const LINUX_PROGRAMS: [&str; 5] = ["swaylock", "wpctl", "brightnessctl", "playerctl", "grim"];
/// A config whose `[env]` makes `directory` the whole `PATH`, which is where
/// the controller then looks for a binding's program.
fn with_path(directory: &Path, rest: &str) -> String {
    format!(
        "{rest}\n[env]\nPATH = {}\n",
        toml_string(directory.to_str().unwrap())
    )
}

#[test]
fn default_bindings_on_missing_linux_programs_become_their_macos_equivalents() {
    let scratch = Scratch::new();
    // Nothing is installed: the PATH is one empty directory.
    let empty = scratch.programs("empty", &[], 0o755);
    let mut h = Host::new();
    register(&mut h, 1);
    let loaded = h.load_config(&scratch.write("config.toml", &with_path(&empty, "")));
    assert_eq!(loaded["errors"], json!([]));
    assert_eq!(loaded["warnings"], json!([]));
    let reply = h.bindings();
    let keys = by_combo(&reply["keys"]);
    // The lock is substituted, and does not repeat as upstream's spawn would.
    assert_eq!(keys.len(), 45);
    assert_eq!(
        keys["mod+l"],
        json!({
            "key_code":0x25,"character":"l","combo":"mod+l","chord":"⌃⌥L",
            "modifiers":{"control":true,"option":true,"shift":false,"command":false},
            "action":"exec /usr/bin/pmset displaysleepnow",
            "upstream":"spawn swaylock -f -c 000000 -kl",
            "repeat":false,"implemented":true
        })
    );
    // Every other default is untouched, and carries no `upstream`.
    assert_eq!(
        keys.values()
            .filter(|key| key.get("upstream").is_some())
            .count(),
        1
    );
    assert_eq!(keys["mod+Return"]["action"], "exec-terminal");
    assert_eq!(keys["mod+ctrl+Right"]["repeat"], true);
    // macOS owns the volume, brightness and media keys: nothing is registered
    // on them. The four keys a Mac lacks stay skipped for that reason.
    assert_eq!(reply["media_keys"], json!([]));
    let skipped: Vec<(&str, &str, &str)> = reply["skipped"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| {
            (
                entry["combo"].as_str().unwrap(),
                entry["action"].as_str().unwrap(),
                entry["reason"].as_str().unwrap(),
            )
        })
        .collect();
    let (absent, volume, brightness, media) = (
        "the key has no macOS equivalent",
        "macOS handles the volume keys itself",
        "macOS handles the brightness keys itself",
        "macOS handles the media keys itself",
    );
    assert_eq!(
        skipped,
        [
            ("Print", "spawn grim - | wl-copy", absent),
            (
                "XF86AudioLowerVolume",
                "spawn wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-",
                volume
            ),
            (
                "XF86AudioMute",
                "spawn wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle",
                volume
            ),
            ("XF86AudioNext", "spawn playerctl next", media),
            ("XF86AudioPause", "spawn playerctl play-pause", absent),
            ("XF86AudioPlay", "spawn playerctl play-pause", media),
            ("XF86AudioPrev", "spawn playerctl previous", media),
            (
                "XF86AudioRaiseVolume",
                "spawn wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+",
                volume
            ),
            ("XF86AudioStop", "spawn playerctl stop", absent),
            (
                "XF86MonBrightnessDown",
                "spawn brightnessctl set 5%-",
                brightness
            ),
            (
                "XF86MonBrightnessUp",
                "spawn brightnessctl set +5%",
                brightness
            ),
            (
                "shift+Print",
                "spawn grim -g \"$(slurp -d)\" - | wl-copy",
                absent
            ),
        ]
    );
    // The user asked for none of it, so none of it is a warning.
    assert_eq!(reply["warnings"], json!([]));
    // The substitute runs through the ordinary exec path.
    let lock = h.action_on(Value::Null, keys["mod+l"]["action"].as_str().unwrap());
    assert_eq!(lock["effects"][0]["op"], "exec");
    assert_eq!(
        lock["effects"][0]["command"],
        "/usr/bin/pmset displaysleepnow"
    );
    assert_eq!(lock["effects"][0]["env"]["PATH"], empty.to_str().unwrap());

    // With the programs installed the defaults are upstream's, as written.
    let installed = scratch.programs("installed", &LINUX_PROGRAMS, 0o755);
    h.load_config(&scratch.write("config.toml", &with_path(&installed, "")));
    let reply = h.bindings();
    let keys = by_combo(&reply["keys"]);
    assert_eq!(keys.len(), 45);
    assert_eq!(keys["mod+l"]["action"], "spawn swaylock -f -c 000000 -kl");
    assert_eq!(keys["mod+l"]["repeat"], true);
    assert!(keys["mod+l"].get("upstream").is_none());
    assert_eq!(reply["media_keys"].as_array().unwrap().len(), 8);
    assert_eq!(reply["skipped"].as_array().unwrap().len(), 4);
    assert_eq!(reply["warnings"], json!([]));

    // Each program is looked up on its own, and a file that cannot be executed
    // is not a program.
    let some = scratch.programs("some", &["playerctl"], 0o755);
    scratch.programs("some", &["swaylock", "wpctl"], 0o644);
    h.load_config(&scratch.write("config.toml", &with_path(&some, "")));
    let reply = h.bindings();
    assert_eq!(
        by_combo(&reply["media_keys"]).keys().collect::<Vec<_>>(),
        ["XF86AudioNext", "XF86AudioPlay", "XF86AudioPrev"]
    );
    assert_eq!(
        by_combo(&reply["keys"])["mod+l"]["action"],
        "exec /usr/bin/pmset displaysleepnow"
    );
    assert_eq!(reply["skipped"].as_array().unwrap().len(), 9);
}

#[test]
fn a_binding_the_file_wrote_is_registered_as_written() {
    let scratch = Scratch::new();
    let bin = scratch.programs("bin", &["mytool"], 0o755);
    // The first two repeat upstream's own defaults word for word.
    let toml = r#"
[keybindings]
"mod+l" = "spawn swaylock -f -c 000000 -kl"
"XF86AudioPlay" = "spawn playerctl play-pause"
"mod+p" = "exec missing-tool --flag"
"mod+u" = "spawn /nonexistent/tool now"
"mod+y" = "spawn FOO=1 missing-tool"
"mod+i" = "spawn cd /tmp && missing-tool"
"mod+o" = "spawn mytool --go"
"mod+g" = "spawn ./relative/tool"
"#;
    let mut h = Host::new();
    register(&mut h, 1);
    let loaded = h.load_config(&scratch.write("config.toml", &with_path(&bin, toml)));
    assert_eq!(loaded["errors"], json!([]));
    assert_eq!(loaded["warnings"], json!([]));
    let reply = h.bindings();
    let keys = by_combo(&reply["keys"]);
    let media = by_combo(&reply["media_keys"]);
    // (combo, action as written, repeats)
    for (combo, action, repeat) in [
        // Missing, so a held chord must not start a failing shell 25 times a
        // second; still registered, still the user's own command.
        ("mod+l", "spawn swaylock -f -c 000000 -kl", false),
        ("mod+u", "spawn /nonexistent/tool now", false),
        // exec never repeats upstream.
        ("mod+p", "exec missing-tool --flag", false),
        // No plain first word, a shell builtin, a relative path: not judged.
        ("mod+y", "spawn FOO=1 missing-tool", true),
        ("mod+i", "spawn cd /tmp && missing-tool", true),
        ("mod+g", "spawn ./relative/tool", true),
        // Found on the config's PATH.
        ("mod+o", "spawn mytool --go", true),
    ] {
        let entry = &keys[combo];
        assert_eq!(entry["action"], action, "{combo}");
        assert_eq!(entry["repeat"], repeat, "{combo}");
        assert_eq!(entry["implemented"], true, "{combo}");
        assert!(entry.get("upstream").is_none(), "{combo}");
        // And it runs as written.
        let effect = h.action_on(Value::Null, action)["effects"][0].clone();
        assert_eq!(effect["op"], "exec", "{combo}");
        assert_eq!(
            effect["command"],
            action.split_once(' ').unwrap().1,
            "{combo}"
        );
    }
    assert_eq!(
        media["XF86AudioPlay"]["action"],
        "spawn playerctl play-pause"
    );
    assert_eq!(media["XF86AudioPlay"]["repeat"], false);
    // The other media defaults were not written by the user and are left to
    // macOS, as in the default table.
    assert_eq!(media.len(), 1);
    assert_eq!(
        reply["warnings"],
        json!([
            "binding 'XF86AudioPlay' = 'spawn playerctl play-pause': 'playerctl' was not found, so it will not repeat while held",
            "binding 'mod+l' = 'spawn swaylock -f -c 000000 -kl': 'swaylock' was not found, so it will not repeat while held",
            "binding 'mod+u' = 'spawn /nonexistent/tool now': '/nonexistent/tool' was not found, so it will not repeat while held",
        ])
    );

    // An entry upstream's loader rejects binds nothing, so the default on its
    // combo is still a default: substituted or left to macOS, not registered
    // as if the user had written upstream's Linux command.
    let toml = r#"
[keybindings]
"mod+l" = "lock-screen"
"XF86AudioPlay" = "nope"
"#;
    let loaded = h.load_config(&scratch.write("config.toml", &with_path(&bin, toml)));
    assert_eq!(loaded["errors"], json!([]));
    let mut rejected: Vec<&str> = loaded["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|warning| warning.as_str().unwrap())
        .collect();
    rejected.sort_unstable();
    assert_eq!(rejected.len(), 2);
    assert!(rejected[0].starts_with("config: invalid action 'lock-screen'"));
    assert!(rejected[1].starts_with("config: invalid action 'nope'"));
    let reply = h.bindings();
    let lock = &by_combo(&reply["keys"])["mod+l"];
    assert_eq!(lock["action"], "exec /usr/bin/pmset displaysleepnow");
    assert_eq!(lock["upstream"], "spawn swaylock -f -c 000000 -kl");
    assert_eq!(lock["repeat"], false);
    assert_eq!(reply["media_keys"], json!([]));
    assert_eq!(
        by_combo(&reply["skipped"])["XF86AudioPlay"]["reason"],
        "macOS handles the media keys itself"
    );
    assert_eq!(reply["warnings"], json!([]));
}
