// SPDX-License-Identifier: GPL-3.0-or-later
//! Window-rule, widget and screen-pin scenarios cross the exported C ABI and
//! JSON decoder with synthetic observations. Every expected rectangle is
//! derived by hand from upstream's conventions (a rule `position` is a frame's
//! center with Y up; a pinned one is measured from its output's center), not
//! read back from the controller. They provide no evidence that a native
//! window is drawn translucent, kept above another, or receives a click.
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
        let response = self.call(command.clone());
        assert_eq!(response["ok"], true, "{command}: {response}");
        response["data"].clone()
    }
    /// A refused command: an error, and nothing changed.
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
    fn ipc(&mut self, request: Value) -> Value {
        self.ok(json!({"op":"ipc","output":1,"request":request}))
    }
    /// The `Ok` payload of a request that asks nothing of the shell and
    /// changes nothing that is saved.
    fn read(&mut self, request: Value) -> Value {
        let data = self.ipc(request.clone());
        assert_eq!(
            data,
            json!({"reply":{"Ok":data["reply"]["Ok"]},"effects":[],"dirty":false,"navigation":null}),
            "{request}"
        );
        data["reply"]["Ok"].clone()
    }
    /// The `Ok` payload of a request that changed saved state and no more.
    fn wrote(&mut self, request: Value) -> Value {
        let data = self.ipc(request.clone());
        assert_eq!(
            data,
            json!({"reply":{"Ok":data["reply"]["Ok"]},"effects":[],"dirty":true,"navigation":null}),
            "{request}"
        );
        data["reply"]["Ok"].clone()
    }
    /// A refused request: an `Err` reply, nothing for the shell, state untouched.
    fn refused_on(&mut self, output: Value, request: Value) -> String {
        let before = self.snapshot();
        let data = self.ok(json!({"op":"ipc","output":output,"request":request}));
        assert_eq!(
            data,
            json!({"reply":{"Err":data["reply"]["Err"]},"effects":[],"dirty":false,"navigation":null}),
            "{request}"
        );
        assert_eq!(self.snapshot(), before, "{request}");
        data["reply"]["Err"].as_str().unwrap().to_owned()
    }
    fn refused(&mut self, request: Value) -> String {
        self.refused_on(json!(1), request)
    }
    fn window(&mut self, id: u64) -> Value {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == id)
            .unwrap_or_else(|| panic!("no window {id}"))
            .clone()
    }
    fn world(&mut self, id: u64) -> Value {
        self.window(id)["world_rect"].clone()
    }
    fn rule(&mut self, id: u64) -> Value {
        self.window(id)["rule"].clone()
    }
    fn pinned(&mut self, id: u64) -> Value {
        self.window(id)["pinned"].clone()
    }
    /// Logical ids in stacking order, bottom to top.
    fn stack(&mut self) -> Vec<u64> {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w["window"].as_u64().unwrap())
            .collect()
    }
    /// What `output` draws, bottom to top: each window with its `pinned` and
    /// `widget` flags.
    fn drawn(&mut self, output: u64) -> Vec<(u64, bool, bool)> {
        self.snapshot()["placements"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|p| p["output"] == output)
            .map(|p| {
                (
                    p["window"].as_u64().unwrap(),
                    p["pinned"].as_bool().unwrap(),
                    p["widget"].as_bool().unwrap(),
                )
            })
            .collect()
    }
    fn placement(&mut self, output: u64, window: u64) -> Value {
        self.snapshot()["placements"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["output"] == output && p["window"] == window)
            .unwrap_or_else(|| panic!("window {window} is not drawn on output {output}"))
            .clone()
    }
    fn focused(&mut self) -> Value {
        self.snapshot()["focus"]["intent"].clone()
    }
    /// The focus history, which cycling walks and a close follows.
    fn history(&mut self) -> Value {
        self.snapshot()["focus"]["history"].clone()
    }
    /// Answer the pending focus request as an adapter that performs no native
    /// focus does: the focus is settled by logical focus alone, and enters the
    /// history unless the window is a widget or screen-pinned.
    fn settle_focus(&mut self) {
        let effect = self.snapshot()["focus"]["pending_effect"].clone();
        assert_eq!(effect["op"], "focus_native_window", "{effect}");
        self.ok(json!({"op":"focus_logical","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"]}));
    }
    /// Report native focus on a bound window: logical focus, raise and history.
    fn observe_focus(&mut self, id: u64) {
        let source = self.window(id)["source"].clone();
        self.ok(json!({"op":"observe_focus","window":id,"identity":source["identity"],"generation":source["generation"]}));
    }
    fn closed(&mut self, id: u64) -> Value {
        let identity = self.window(id)["source"]["identity"].clone();
        self.ok(json!({"op":"window_closed","window":id,"identity":identity}))
    }
    fn hit(&mut self, output: u64, x: f64, y: f64) -> Value {
        self.ok(json!({"op":"hit","output":output,"screen":point(x, y)}))["hit"].clone()
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
            "infinify-rules-flow-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
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
/// A fresh observation as the controller reports it back, `owner` and all.
fn identity(wid: u64) -> Value {
    json!({"pid":4242,"birth_sec":1800000000,"birth_usec":77,"wid":wid,"owner":null})
}
/// Where every fixture's native window sits on the desktop. No world or pinned
/// position may ever derive from it.
const NATIVE: (f64, f64) = (4000.0, 3000.0);

/// Two outputs, neither at the global origin. Output 1, `main`, is 1000 x 800
/// at the global point (200, 100), with a 50-point bar at the top: its usable
/// center is the local point (500, 425) and its own center (500, 400). Output
/// 2, `side`, is 800 x 600 at the global point (1300, 100), and its camera is
/// parked at (10000, 0), so it shows nothing main shows.
fn main_output(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"main","screen_bounds":rect(200.0,100.0,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,50.0,1000.0,750.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
}
fn side_output(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"side","screen_bounds":rect(1300.0,100.0,800.0,600.0)}));
}
fn open(h: &mut Host) {
    main_output(h);
    side_output(h);
    h.ok(json!({"op":"pan","output":2,"screen_delta":point(10000.0,0.0)}));
    assert_eq!(h.snapshot()["outputs"][1]["camera"], point(10000.0, 0.0));
}
fn load_config(h: &mut Host, scratch: &Scratch, toml: &str) {
    let path = scratch.path("config.toml");
    std::fs::write(&path, toml).unwrap();
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(reply["warnings"], json!([]), "{reply}");
}
/// Both outputs, the given config file, and the launch pass already over: a
/// window that appears now is a new one.
fn running(scratch: &Scratch, toml: &str) -> Host {
    let mut h = Host::new();
    open(&mut h);
    load_config(&mut h, scratch, toml);
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[],"dirty":false})
    );
    h
}
/// Main at half the zoom with its camera at (1000, -200).
fn zoom_out(h: &mut Host) {
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":point(200.0,100.0)}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(500.0,-100.0)}));
    assert_eq!(h.snapshot()["outputs"][0]["camera"], point(1000.0, -200.0));
    assert_eq!(h.snapshot()["outputs"][0]["zoom"], 0.5);
}
/// A window that appeared by itself, of the given native size: neither a world
/// rectangle nor a logical id. `output` is the active output.
fn appear_on(
    h: &mut Host,
    wid: u64,
    app: &str,
    title: &str,
    size: (f64, f64),
    output: Value,
) -> Value {
    h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":title,"buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,size.0,size.1),"output":output,"pointer":point(700.0,500.0)}))
}
fn appear(h: &mut Host, wid: u64, app: &str, title: &str, size: (f64, f64)) -> Value {
    appear_on(h, wid, app, title, size, json!(1))
}
/// A window the caller puts at a world rectangle. Its rules still apply, less
/// the placement the caller has decided.
fn put(h: &mut Host, wid: u64, app: &str, title: &str, world: Value) -> u64 {
    let source = rect(
        NATIVE.0,
        NATIVE.1,
        world["size"]["width"].as_f64().unwrap(),
        world["size"]["height"].as_f64().unwrap(),
    );
    let reply = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":title,"buffer":{"width":200,"height":100},"source_rect":source,"world_rect":world}));
    assert_eq!(reply, json!({"window":reply["window"]}), "{reply}");
    reply["window"].as_u64().unwrap()
}
const IDLE: fn() -> Value = || json!({"navigation":null,"effects":[],"dirty":false});
const CHANGED: fn() -> Value = || json!({"navigation":null,"effects":[],"dirty":true});
/// What `outputs_settled` answers: whether a pin moved.
const DIRTY: fn() -> Value = || json!({"dirty":true});
const CLEAN: fn() -> Value = || json!({"dirty":false});
const NO_CANVAS_POSITION: &str =
    "this window has no canvas position to move: it is pinned, fullscreen, or not on screen yet";
const NO_CANVAS_SIZE: &str = "this window has no canvas size to set: it is pinned, fullscreen, a widget, or not on screen yet";

#[test]
fn rules_match_by_app_id_by_title_and_by_both_and_merge_in_config_order() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        r#"
[[window_rules]]
app_id = "com.example.*"
blur = true
opacity = 0.5

[[window_rules]]
title = "*notes*"
opacity = 0.8
decoration = "minimal"

[[window_rules]]
app_id = "com.example.term"
title = "nvim*"
opacity = 1.0
decoration = "none"
blur = false

[[window_rules]]
app_id = "/^steam_app_\\d+$/"
corner_radius = 4
"#,
    );
    let size = (300.0, 200.0);
    appear(&mut h, 1, "com.example.term", "zsh", size);
    appear(&mut h, 2, "com.example.editor", "my notes.txt", size);
    appear(&mut h, 3, "com.example.term", "nvim notes", size);
    appear(&mut h, 4, "org.other.app", "notes", size);
    appear(&mut h, 5, "org.other.app", "plain", size);
    appear(&mut h, 6, "Com.Example.term", "zsh", size);
    appear(&mut h, 7, "steam_app_42", "game", size);
    appear(&mut h, 8, "steam_app_x", "game", size);
    let seen = |h: &mut Host, id: u64| {
        let rule = h.rule(id);
        json!([rule["opacity"], rule["decoration"], rule["blur"]])
    };
    // The app glob alone.
    assert_eq!(seen(&mut h, 1), json!([0.5, null, true]));
    // The app glob, then the title glob: its opacity is the later one.
    assert_eq!(seen(&mut h, 2), json!([0.8, "minimal", true]));
    // All three. Scalars are the last rule's; `blur` is sticky, so the third
    // rule's `blur = false` turns nothing off.
    assert_eq!(seen(&mut h, 3), json!([1.0, "none", true]));
    assert_eq!(
        h.rule(3),
        json!({
            "opacity":1.0,"decoration":"none","blur":true,"widget":false,
            "pinned_to_screen":false,"position":null,"size":null,"output":null,
            "fullscreen":null,"focus_on_open":null,"suspend_on_close":null,
            "restore_windows":null,"preserve_aspect_ratio":false,"pass_keys":"none",
            "pass_mouse":"none","border_width":null,"border_color":null,
            "border_color_focused":null,"corner_radius":null,"shadow":null,
            "layer_order":null,"not_applied":[]
        })
    );
    // The title glob alone; a rule with both criteria needs both.
    assert_eq!(seen(&mut h, 4), json!([0.8, "minimal", false]));
    // No rule, and globs are case-sensitive: no rule either.
    assert_eq!(h.rule(5), Value::Null);
    assert_eq!(h.rule(6), Value::Null);
    // A `/…/` pattern is a regular expression.
    assert_eq!(h.rule(7)["corner_radius"], 4);
    assert_eq!(h.rule(7)["opacity"], Value::Null);
    assert_eq!(h.rule(8), Value::Null);
    // What each is drawn at: a rule's opacity, else 1.
    for (window, opacity) in [(1, 0.5), (2, 0.8), (3, 1.0), (4, 0.8), (5, 1.0), (7, 1.0)] {
        let placement = h.placement(1, window);
        assert_eq!(placement["opacity"], opacity, "{window}");
        assert_eq!(placement["widget"], false, "{window}");
        assert_eq!(placement["pinned"], false, "{window}");
    }
    assert!(
        h.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .all(|w| w["widget"] == false && w["pinned"].is_null())
    );
}

#[test]
fn a_position_rule_overrides_the_placement_policy() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        r#"
window_placement = "cursor"

[[window_rules]]
app_id = "app.pos"
position = [100, 50]

[[window_rules]]
app_id = "app.quiet"
position = [-300, 0]
focus_on_open = false
"#,
    );
    // The frame's center goes to the canvas point (100, 50), Y up: (100, -50)
    // in world coordinates. Upstream halves in integers, 401 / 2 = 200 and
    // 301 / 2 = 150, so the top-left is (100 - 200, -50 - 150).
    let a = appear(&mut h, 1, "app.pos", "A", (401.0, 301.0));
    assert_eq!(h.world(1), rect(-100.0, -200.0, 401.0, 301.0));
    // Mapped as any new window: focused, and navigated to at zoom 1, which
    // parks its center (100.5, -49.5) on the usable center (500, 425). Cursor
    // placement would have stayed put; the rule did not place it at the cursor.
    assert_eq!(a["focus_on_open_suppressed"], Value::Null);
    assert_eq!(a["effect"]["op"], "focus_native_window");
    assert_eq!(a["effect"]["window"], 1);
    assert_eq!(a["navigation"]["target_camera"], point(-399.5, -474.5));
    assert_eq!(a["navigation"]["target_zoom"], 1.0);
    assert_eq!(h.focused(), 1);
    h.settle_focus();
    // Nothing cascades off a ruled position: the second lands on the first.
    appear(&mut h, 2, "app.pos", "A", (401.0, 301.0));
    assert_eq!(h.world(2), rect(-100.0, -200.0, 401.0, 301.0));
    assert_eq!(h.focused(), 2);
    h.settle_focus();
    // `focus_on_open = false`: placed by its rule, center (-300, 0), and
    // neither focused nor navigated to.
    assert_eq!(
        appear(&mut h, 3, "app.quiet", "Q", (200.0, 100.0)),
        json!({"window":3,"adopted":false,"background":false,"focus_on_open_suppressed":true,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.world(3), rect(-400.0, -50.0, 200.0, 100.0));
    assert_eq!(h.focused(), 2);
    assert_eq!(h.history(), json!([2, 1]));
    // A window without a rule is still the policy's: under the pointer, the
    // world point (500, 400), and it stays put.
    let other = appear(&mut h, 4, "app.other", "O", (300.0, 200.0));
    assert_eq!(h.world(4), rect(350.0, 300.0, 300.0, 200.0));
    assert_eq!(other["navigation"], Value::Null);
    // A canvas position is the same whatever the camera and the zoom.
    zoom_out(&mut h);
    appear(&mut h, 5, "app.pos", "A", (400.0, 300.0));
    assert_eq!(h.world(5), rect(-100.0, -200.0, 400.0, 300.0));
}

#[test]
fn an_ipc_move_raises_a_widget_only_within_the_widget_stack() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        "[[window_rules]]\napp_id = \"app.widget\"\nwidget = true\n",
    );
    for (id, app) in [(1, "app.widget"), (2, "app.widget"), (3, "app.normal")] {
        put(&mut h, id, app, "Overlap", rect(300.0, 275.0, 400.0, 300.0));
    }
    h.observe_focus(3);
    assert_eq!(h.stack(), [1, 2, 3]);
    let before = h.snapshot();
    assert_eq!(
        h.wrote(json!({"Move":{"window":1,"to":[500,-425]}})),
        json!({"Position":{"x":500,"y":-425}})
    );
    assert_eq!(h.stack(), [2, 1, 3]);
    assert_eq!(
        h.drawn(1),
        [(2, false, true), (1, false, true), (3, false, false)]
    );
    assert_eq!(h.hit(1, 700.0, 525.0)["window"], 3);
    let after = h.snapshot();
    assert_eq!(after["focus"], before["focus"]);
    assert_eq!(after["outputs"], before["outputs"]);
    h.ok(json!({"op":"remove_source","window":3,"identity":identity(3),"keep_placeholder":false}));
    assert_eq!(h.hit(1, 700.0, 525.0)["window"], 1);
}

#[test]
fn a_widget_sits_below_stays_out_of_cycling_and_moves_only_by_ipc() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        r#"
[session]
suspend_on_close = true

[[window_rules]]
app_id = "app.widget"
widget = true
position = [700, -400]
decoration = "none"
"#,
    );
    put(&mut h, 1, "app.a", "A", rect(300.0, 275.0, 400.0, 300.0));
    h.observe_focus(1);
    // The widget's center goes to (700, -400), Y up: its 200 x 100 frame is at
    // (600, 350). It maps without the focus and without a navigation, and
    // below the window that was already there.
    assert_eq!(
        appear(&mut h, 2, "app.widget", "W", (200.0, 100.0)),
        json!({"window":2,"adopted":false,"background":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.world(2), rect(600.0, 350.0, 200.0, 100.0));
    assert_eq!(h.focused(), 1);
    assert_eq!(h.stack(), vec![2, 1]);
    assert_eq!(h.window(2)["widget"], true);
    assert_eq!(h.rule(2)["decoration"], "none");
    assert_eq!(h.drawn(1), vec![(2, false, true), (1, false, false)]);
    // Where both are, the window is hit; the widget only where it shows.
    let over = h.hit(1, 850.0, 500.0);
    assert_eq!(
        (&over["window"], &over["widget"]),
        (&json!(1), &json!(false))
    );
    let beside = h.hit(1, 950.0, 500.0);
    assert_eq!(beside["window"], 2);
    assert_eq!(beside["widget"], true);
    assert_eq!(beside["pinned"], false);
    assert_eq!(beside["local"], point(150.0, 50.0));

    // Focus can sit on a widget, but it does not enter the focus history,
    // and it is never raised above a window.
    put(&mut h, 3, "app.b", "B", rect(1200.0, 275.0, 300.0, 200.0));
    h.observe_focus(3);
    h.observe_focus(1);
    h.observe_focus(2);
    assert_eq!(h.focused(), 2);
    assert_eq!(h.history(), json!([1, 3]));
    assert_eq!(h.stack(), vec![2, 3, 1]);
    // Cycling from it goes to the head of the history, never to a widget.
    let step = h.ok(json!({"op":"cycle_focus","backward":false,"held":true}));
    assert_eq!(step["effect"]["window"], 1);
    let step = h.ok(json!({"op":"cycle_focus","backward":false,"held":true}));
    assert_eq!(step["effect"]["window"], 3);
    let step = h.ok(json!({"op":"cycle_focus","backward":false,"held":true}));
    assert_eq!(step["effect"]["window"], 1);
    h.ok(json!({"op":"cancel_focus_cycle"}));

    // Drags, resizes, nudges and the bookmark move pass a widget over.
    let by_hand = "a widget is not moved or resized by hand";
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":2,"output":1})),
        by_hand
    );
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":2,"output":1,"group":true})),
        by_hand
    );
    assert_eq!(
        h.error(json!({"op":"begin_resize","window":2,"output":1,"edges":"right"})),
        by_hand
    );
    assert_eq!(
        h.error(json!({"op":"begin_native_resize","window":2,"output":1,"edges":"right","start_screen":point(950.0,500.0)})),
        by_hand
    );
    h.observe_focus(2);
    h.ipc(json!({"Bookmark":{"name":"lab","to":[0.0,0.0]}}));
    let before = h.snapshot();
    for action in [
        "nudge-window right",
        "move-to-bookmark lab",
        "close-window",
        "suspend-window",
    ] {
        assert_eq!(h.action(action), IDLE(), "{action}");
        assert_eq!(h.snapshot(), before, "{action}");
    }

    // IPC: an id reaches it and an app id passes it over; it cannot be
    // focused, resized or suspended, and `move` alone repositions it.
    assert_eq!(
        h.refused(json!({"Focus":2})),
        "window #2 is a widget and cannot be focused"
    );
    assert_eq!(
        h.refused(json!({"Focus":"app.widget"})),
        "no window matching 'app.widget'"
    );
    assert_eq!(
        h.refused(json!({"Resize":{"window":2,"to":[400,300]}})),
        NO_CANVAS_SIZE
    );
    assert_eq!(
        h.read(json!({"Resize":{"window":2}})),
        json!({"Size":{"width":200,"height":100}})
    );
    assert_eq!(
        h.refused(json!({"Suspend":2})),
        "widgets cannot be suspended"
    );
    assert_eq!(
        h.wrote(json!({"Move":{"window":2,"to":[0,0]}})),
        json!({"Position":{"x":0,"y":0}})
    );
    assert_eq!(h.world(2), rect(-100.0, -50.0, 200.0, 100.0));
    assert_eq!(h.stack(), vec![2, 3, 1]);
    let state = h.read(json!("State"))["State"].clone();
    let listed = state["windows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["id"] == 2)
        .unwrap()
        .clone();
    assert_eq!(
        listed,
        json!({"id":2,"app_id":"app.widget","title":"W","position":[0,0],"size":[200,100],"is_focused":true,"is_widget":true,"suspended":false,"mode":"Normal","pid":4242})
    );
    assert_eq!(state["pinned"], json!([]));

    // `suspend_on_close` leaves a stand-in for a window, never for a widget.
    assert_eq!(h.closed(2)["standin"], false);
    assert_eq!(h.stack(), vec![3, 1]);
    assert_eq!(h.closed(3)["standin"], true);
    assert_eq!(h.snapshot()["lifecycle"]["standins"], json!([3]));
}

#[test]
fn widgets_and_pinned_windows_take_no_part_in_snapping_or_clusters() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        "[[window_rules]]\napp_id = \"app.widget\"\nwidget = true\n\n[[window_rules]]\ntitle = \"Clock\"\nwidget = true\n",
    );
    let drag = |h: &mut Host, window: u64, group: bool, by: f64| {
        h.ok(json!({"op":"begin_drag","window":window,"output":1,"group":group}));
        h.ok(json!({"op":"gesture_to","screen_delta":point(by, 0.0)}));
        h.ok(json!({"op":"end_gesture"}));
    };
    // A left edge 22 from a window's right edge docks at the gap of 12, as
    // tests/config_flow.rs shows. Beside a widget it goes where it is put.
    put(&mut h, 1, "app.widget", "W", rect(0.0, 0.0, 400.0, 300.0));
    put(&mut h, 2, "app.b", "B", rect(500.0, 0.0, 400.0, 300.0));
    assert_eq!(h.window(1)["widget"], true);
    drag(&mut h, 2, false, -78.0);
    assert_eq!(h.world(2), rect(422.0, 0.0, 400.0, 300.0));
    // The same beside a pinned window, whose canvas frame is still there.
    put(&mut h, 3, "app.c", "C", rect(0.0, 400.0, 400.0, 300.0));
    h.observe_focus(3);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(h.world(3), rect(0.0, 400.0, 400.0, 300.0));
    put(&mut h, 4, "app.d", "D", rect(500.0, 400.0, 400.0, 300.0));
    drag(&mut h, 4, false, -78.0);
    assert_eq!(h.world(4), rect(422.0, 400.0, 400.0, 300.0));
    // A widget docked to a window is not in its cluster: a group move leaves
    // it behind.
    put(&mut h, 5, "app.e", "E", rect(1000.0, 1000.0, 400.0, 300.0));
    put(
        &mut h,
        6,
        "app.widget",
        "W2",
        rect(1412.0, 1000.0, 400.0, 300.0),
    );
    drag(&mut h, 5, true, 50.0);
    assert_eq!(h.world(5), rect(1050.0, 1000.0, 400.0, 300.0));
    assert_eq!(h.world(6), rect(1412.0, 1000.0, 400.0, 300.0));
    // The pinned window itself is dragged in screen space, and docks to
    // nothing: 5 to the right its edge is 17 from D's, where a canvas window
    // would dock at the gap of 12. It is not resized.
    assert_eq!(
        h.pinned(3),
        json!({"output":1,"screen_rect":rect(200.0,500.0,400.0,300.0)})
    );
    drag(&mut h, 3, false, 5.0);
    assert_eq!(
        h.pinned(3),
        json!({"output":1,"screen_rect":rect(205.0,500.0,400.0,300.0)})
    );
    assert_eq!(h.world(4), rect(422.0, 400.0, 400.0, 300.0));
    assert_eq!(
        h.error(json!({"op":"begin_resize","window":3,"output":1,"edges":"bottom_right"})),
        "a screen-pinned window is not moved or resized by hand"
    );
    // A detached slot is dragged, and its window comes back under a title a
    // widget rule matches: the slot lets go of the drag as it becomes one.
    let slot = put(
        &mut h,
        7,
        "app.late",
        "Loading",
        rect(3000.0, 3000.0, 300.0, 200.0),
    );
    let gone = h.window(slot)["source"]["identity"].clone();
    h.ok(json!({"op":"remove_source","window":slot,"identity":gone,"keep_placeholder":true}));
    h.ok(json!({"op":"begin_drag","window":slot,"output":1}));
    h.ok(json!({"op":"gesture_to","screen_delta":point(10.0, 0.0)}));
    assert_eq!(h.world(slot), rect(3010.0, 3000.0, 300.0, 200.0));
    let back = appear(&mut h, 8, "app.late", "Clock", (300.0, 200.0));
    assert_eq!(
        (&back["window"], &back["adopted"]),
        (&json!(slot), &json!(true))
    );
    assert_eq!(h.window(slot)["widget"], true);
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(50.0, 0.0)})),
        "no active gesture"
    );
    assert_eq!(h.world(slot), rect(3010.0, 3000.0, 300.0, 200.0));
}

#[test]
fn a_pinned_to_screen_rule_fixes_the_frame_to_its_output() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        r#"
[[window_rules]]
title = "Picture-in-Picture"
pinned_to_screen = true
position = [300, -200]
decoration = "none"

[[window_rules]]
app_id = "app.side"
pinned_to_screen = true
output = "side"

[[window_rules]]
app_id = "app.far"
pinned_to_screen = true
position = [1000, 1000]
output = "nowhere"
"#,
    );
    zoom_out(&mut h);
    put(&mut h, 1, "app.a", "A", rect(1100.0, 300.0, 400.0, 300.0));
    h.observe_focus(1);
    // On main, 1000 x 800: the 400 x 200 frame's center is 300 right of and
    // 200 below the output's center (500, 400), so its top-left is the local
    // point (500 + 300 - 200, 400 + 200 - 100) = (600, 500), the global point
    // (800, 600), at its own size whatever the zoom. Its canvas frame is the
    // point that shows there: (1000 + 600 / 0.5, -200 + 500 / 0.5).
    let pip = appear(&mut h, 2, "app.video", "Picture-in-Picture", (400.0, 200.0));
    assert_eq!(
        h.pinned(2),
        json!({"output":1,"screen_rect":rect(800.0,600.0,400.0,200.0)})
    );
    assert_eq!(h.world(2), rect(2200.0, 800.0, 400.0, 200.0));
    // Raised and focused where it is: there is nowhere to navigate to. It
    // does not enter the focus history, not even once its request is
    // answered.
    assert_eq!(pip["effect"]["op"], "focus_native_window");
    assert_eq!(pip["effect"]["window"], 2);
    assert_eq!(pip["navigation"], Value::Null);
    assert_eq!(h.focused(), 2);
    h.settle_focus();
    assert_eq!(h.history(), json!([1]));
    // Drawn above the canvas window, on its own output only, uncropped.
    assert_eq!(h.drawn(1), vec![(1, false, false), (2, true, false)]);
    assert_eq!(h.drawn(2), vec![]);
    let placement = h.placement(1, 2);
    assert_eq!(placement["screen_rect"], rect(800.0, 600.0, 400.0, 200.0));
    assert_eq!(placement["clip_rect"], rect(800.0, 600.0, 400.0, 200.0));
    assert_eq!(placement["world_local_crop"], rect(0.0, 0.0, 400.0, 200.0));
    // The canvas window beside it is the camera's: half size at half zoom.
    assert_eq!(
        h.placement(1, 1)["screen_rect"],
        rect(250.0, 350.0, 200.0, 150.0)
    );
    // Pan and zoom move the canvas under it. Only its canvas frame follows.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(100.0,0.0)}));
    assert_eq!(
        h.placement(1, 2)["screen_rect"],
        rect(800.0, 600.0, 400.0, 200.0)
    );
    assert_eq!(h.world(2), rect(2400.0, 800.0, 400.0, 200.0));
    h.ok(json!({"op":"zoom","output":1,"zoom":1.0,"anchor":point(200.0,100.0)}));
    assert_eq!(
        h.placement(1, 2)["screen_rect"],
        rect(800.0, 600.0, 400.0, 200.0)
    );
    assert_eq!(h.world(2), rect(1800.0, 300.0, 400.0, 200.0));
    assert_eq!(
        h.placement(1, 1)["screen_rect"],
        rect(100.0, 600.0, 400.0, 300.0)
    );

    // `output` names the output, whichever is active. Without a position the
    // frame is centered: (400 - 150, 300 - 100) on side, 800 x 600.
    appear(&mut h, 3, "app.side", "S", (300.0, 200.0));
    assert_eq!(
        h.pinned(3),
        json!({"output":2,"screen_rect":rect(1550.0,300.0,300.0,200.0)})
    );
    assert_eq!(h.drawn(2), vec![(3, true, false)]);
    // An output that is not connected falls through to the active one, and a
    // position off the output is clamped until the whole frame is on it:
    // (500 + 1000 - 200, 400 - 1000 - 100) becomes (600, 0).
    appear(&mut h, 4, "app.far", "F", (400.0, 200.0));
    assert_eq!(
        h.pinned(4),
        json!({"output":1,"screen_rect":rect(800.0,100.0,400.0,200.0)})
    );
    assert_eq!(
        h.drawn(1),
        vec![(1, false, false), (2, true, false), (4, true, false)]
    );
    // `state` lists them apart from the canvas windows, by output and
    // position, in the coordinates a rule takes.
    let state = h.read(json!("State"))["State"].clone();
    assert_eq!(
        state["pinned"],
        json!([
            {"id":2,"output":"main","app_id":"app.video","title":"Picture-in-Picture","position":[300,-200],"size":[400,200],"pid":4242},
            {"id":4,"output":"main","app_id":"app.far","title":"F","position":[300,300],"size":[400,200],"pid":4242},
            {"id":3,"output":"side","app_id":"app.side","title":"S","position":[0,0],"size":[300,200],"pid":4242}
        ])
    );
    let listed: Vec<_> = state["windows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["id"].clone())
        .collect();
    assert_eq!(listed, vec![json!(1)]);
    // With no output to pin to, the window is a canvas window and the
    // position a canvas one: center (300, -200), Y up.
    assert_eq!(
        appear_on(
            &mut h,
            5,
            "app.video",
            "Picture-in-Picture",
            (400.0, 200.0),
            Value::Null
        ),
        json!({"window":5,"adopted":false,"background":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.pinned(5), Value::Null);
    assert_eq!(h.world(5), rect(100.0, 100.0, 400.0, 200.0));
}

#[test]
fn toggle_pin_to_screen_keeps_the_on_screen_position_both_ways() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    zoom_out(&mut h);
    put(&mut h, 1, "app.a", "A", rect(1100.0, 300.0, 400.0, 300.0));
    put(&mut h, 2, "app.b", "B", rect(1200.0, 400.0, 400.0, 300.0));
    h.observe_focus(2);
    h.observe_focus(1);
    // A's top-left shows at the local point ((1100 - 1000) / 2, (300 + 200) / 2)
    // = (50, 250), the global point (250, 350), at half size.
    assert_eq!(
        h.placement(1, 1)["screen_rect"],
        rect(250.0, 350.0, 200.0, 150.0)
    );
    // Pinned there, on the output showing its center. Its top-left stays; its
    // size becomes its own. It leaves the focus history and keeps the focus.
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(250.0,350.0,400.0,300.0)})
    );
    assert_eq!(h.world(1), rect(1100.0, 300.0, 400.0, 300.0));
    assert_eq!(h.focused(), 1);
    assert_eq!(h.history(), json!([2]));
    assert_eq!(h.drawn(1), vec![(2, false, false), (1, true, false)]);
    // A window focused and raised later is still drawn below it.
    h.observe_focus(2);
    assert_eq!(h.drawn(1), vec![(2, false, false), (1, true, false)]);
    h.observe_focus(1);
    assert_eq!(h.history(), json!([2]));
    // The camera moves to (1100, -400) at a quarter zoom: the pin does not.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.25,"anchor":point(200.0,100.0)}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(25.0,-50.0)}));
    assert_eq!(h.snapshot()["outputs"][0]["camera"], point(1100.0, -400.0));
    assert_eq!(
        h.placement(1, 1)["screen_rect"],
        rect(250.0, 350.0, 400.0, 300.0)
    );
    // Unpinned at this camera and zoom: its canvas frame starts at the point
    // the pin shows, (1100 + 50 / 0.25, -400 + 250 / 0.25), so its top-left is
    // still at the global point (250, 350), now at a quarter size. It is back
    // on top of the canvas windows and at the head of the focus history.
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(h.pinned(1), Value::Null);
    assert_eq!(h.world(1), rect(1300.0, 600.0, 400.0, 300.0));
    assert_eq!(
        h.placement(1, 1)["screen_rect"],
        rect(250.0, 350.0, 100.0, 75.0)
    );
    assert_eq!(h.placement(1, 1)["pinned"], false);
    assert_eq!(h.stack(), vec![2, 1]);
    assert_eq!(h.history(), json!([1, 2]));

    // The site is the output showing the window's center, whichever is
    // active: side shows the world from (10000, 0) at zoom 1.
    put(&mut h, 3, "app.c", "C", rect(10100.0, 100.0, 300.0, 200.0));
    h.observe_focus(3);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(
        h.pinned(3),
        json!({"output":2,"screen_rect":rect(1400.0,200.0,300.0,200.0)})
    );
    assert_eq!(h.drawn(2), vec![(3, true, false)]);
    assert!(h.drawn(1).iter().all(|(window, _, _)| *window != 3));
    // A window no output shows pins to the active one, and without an active
    // output it stays as it was: the key has no one to tell.
    put(
        &mut h,
        4,
        "app.d",
        "D",
        rect(-5000.0, -5000.0, 300.0, 200.0),
    );
    h.observe_focus(4);
    let before = h.snapshot();
    assert_eq!(
        h.ok(json!({"op":"action","output":null,"action":"toggle-pin-to-screen"})),
        IDLE()
    );
    assert_eq!(h.snapshot(), before);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(
        h.pinned(4),
        json!({"output":1,"screen_rect":rect(-1325.0,-1050.0,300.0,200.0)})
    );
    // A pin waits for a drag to end, as an IPC move does.
    h.ok(json!({"op":"begin_drag","window":2,"output":1}));
    assert_eq!(
        h.refused(json!({"Pin":{"window":2,"value":true}})),
        "a window is under an interactive move or resize"
    );
    assert_eq!(
        h.refused(json!({"Pin":{"window":3,"value":false}})),
        "a window is under an interactive move or resize"
    );
    h.ok(json!({"op":"end_gesture"}));
}

#[test]
fn ipc_pin_and_opacity_read_write_and_refuse_as_upstream_does() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        r#"
[decorations]
opacity = 0.9
opacity_focused = 1.0

[[window_rules]]
app_id = "app.glass"
opacity = 0.5

[[window_rules]]
app_id = "app.widget"
widget = true
"#,
    );
    put(&mut h, 1, "app.a", "A", rect(300.0, 275.0, 400.0, 300.0));
    put(
        &mut h,
        2,
        "app.glass",
        "G",
        rect(100.0, 100.0, 300.0, 200.0),
    );
    put(&mut h, 3, "app.widget", "W", rect(0.0, 500.0, 200.0, 100.0));
    put(&mut h, 4, "app.b", "B", rect(600.0, 100.0, 300.0, 200.0));
    put(
        &mut h,
        5,
        "app.gone",
        "Gone",
        rect(700.0, 600.0, 200.0, 100.0),
    );
    let gone = identity(5);
    h.ok(json!({"op":"remove_source","window":5,"identity":gone,"keep_placeholder":true}));
    h.observe_focus(1);

    // Opacity reads what the window is drawn at: the focused default, a
    // rule's pin, a widget's opaque default, the unfocused default.
    let opacity = |h: &mut Host, window: Value| h.read(json!({"Opacity":{"window":window}}));
    assert_eq!(h.read(json!({"Opacity":{}})), json!({"Opacity":1.0}));
    assert_eq!(opacity(&mut h, json!(2)), json!({"Opacity":0.5}));
    assert_eq!(opacity(&mut h, json!("glass")), json!({"Opacity":0.5}));
    assert_eq!(opacity(&mut h, json!(3)), json!({"Opacity":1.0}));
    assert_eq!(opacity(&mut h, json!(4)), json!({"Opacity":0.9}));
    for (window, drawn) in [(1, 1.0), (2, 0.5), (3, 1.0), (4, 0.9)] {
        assert_eq!(h.placement(1, window)["opacity"], drawn, "{window}");
    }
    // A write pins the value in both focus states, on a window no rule
    // matched too, and is not saved state.
    assert_eq!(h.rule(4), Value::Null);
    assert_eq!(
        h.read(json!({"Opacity":{"window":4,"value":0.25}})),
        json!({"Opacity":0.25})
    );
    assert_eq!(opacity(&mut h, json!(4)), json!({"Opacity":0.25}));
    assert_eq!(h.rule(4)["opacity"], 0.25);
    assert_eq!(h.rule(4)["widget"], false);
    assert_eq!(h.placement(1, 4)["opacity"], 0.25);
    h.observe_focus(4);
    assert_eq!(h.placement(1, 4)["opacity"], 0.25);
    assert_eq!(h.placement(1, 1)["opacity"], 0.9);
    assert_eq!(
        h.read(json!({"Opacity":{"value":0.0}})),
        json!({"Opacity":0.0})
    );
    assert_eq!(h.placement(1, 4)["opacity"], 0.0);
    assert_eq!(
        h.read(json!({"Opacity":{"window":3,"value":1.0}})),
        json!({"Opacity":1.0})
    );
    // Out of range is refused, not clamped; only a live window has one.
    for value in [1.5, -0.1] {
        assert_eq!(
            h.refused(json!({"Opacity":{"value":value}})),
            "opacity must be between 0.0 and 1.0"
        );
    }
    assert_eq!(
        h.refused(json!({"Opacity":{"window":99}})),
        "no window with id 99"
    );
    assert_eq!(
        h.refused(json!({"Opacity":{"window":5,"value":0.5}})),
        "no window with id 5"
    );

    // Pin reads and writes the bool `toggle-pin-to-screen` flips.
    h.observe_focus(1);
    assert_eq!(h.read(json!({"Pin":{}})), json!({"Pin":false}));
    assert_eq!(
        h.wrote(json!({"Pin":{"window":2,"value":true}})),
        json!({"Pin":true})
    );
    assert_eq!(
        h.pinned(2),
        json!({"output":1,"screen_rect":rect(300.0,200.0,300.0,200.0)})
    );
    assert_eq!(h.read(json!({"Pin":{"window":2}})), json!({"Pin":true}));
    // Already so: answered, and nothing to save.
    assert_eq!(
        h.read(json!({"Pin":{"window":"glass","value":true}})),
        json!({"Pin":true})
    );
    assert_eq!(h.focused(), 1);

    // A pinned window has no canvas position to move or size to set; both
    // still read. A widget has a position and no size to set.
    assert_eq!(
        h.refused(json!({"Move":{"window":2,"to":[0,0]}})),
        NO_CANVAS_POSITION
    );
    assert_eq!(
        h.read(json!({"Move":{"window":2}})),
        json!({"Position":{"x":250,"y":-200}})
    );
    assert_eq!(
        h.refused(json!({"Resize":{"window":2,"to":[800,600]}})),
        NO_CANVAS_SIZE
    );
    assert_eq!(
        h.refused(json!({"Resize":{"window":3,"to":[800,600]}})),
        NO_CANVAS_SIZE
    );
    assert_eq!(
        h.read(json!({"Resize":{"window":2}})),
        json!({"Size":{"width":300,"height":200}})
    );
    // The size is checked first, and a canvas window's resize is still gated.
    assert_eq!(
        h.refused(json!({"Resize":{"window":2,"to":[0,600]}})),
        "size must be positive"
    );
    assert_eq!(
        h.refused(json!({"Resize":{"window":1,"to":[800,600]}})),
        "resize is not implemented on macOS yet: native layout resize is not available"
    );
    // Focusing a pinned window raises and focuses it without a navigation: it
    // is always on screen.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(5000.0,0.0)}));
    let focus = h.ipc(json!({"Focus":2}));
    assert_eq!(
        focus["reply"],
        json!({"Ok":{"Focused":{"id":2,"app_id":"app.glass"}}})
    );
    assert_eq!(focus["navigation"], Value::Null);
    assert_eq!(focus["effects"][0]["window"], 2);
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(-5000.0,0.0)}));
    h.observe_focus(1);

    // Unpinned by a selector while another window holds the focus: back on
    // the canvas where it shows, raised, and not focused.
    assert_eq!(
        h.wrote(json!({"Pin":{"window":"glass","value":false}})),
        json!({"Pin":false})
    );
    assert_eq!(h.pinned(2), Value::Null);
    assert_eq!(h.world(2), rect(100.0, 100.0, 300.0, 200.0));
    assert_eq!(h.stack(), vec![3, 5, 4, 1, 2]);
    assert_eq!(h.focused(), 1);
    assert_eq!(h.history(), json!([1, 4]));
    // A pinned widget is immovable in screen space; unpinned it is a widget
    // again, below the windows.
    assert_eq!(
        h.wrote(json!({"Pin":{"window":3,"value":true}})),
        json!({"Pin":true})
    );
    assert_eq!(h.drawn(1).last(), Some(&(3, true, true)));
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":3,"output":1})),
        "a widget is not moved or resized by hand"
    );
    assert_eq!(
        h.wrote(json!({"Pin":{"window":3,"value":false}})),
        json!({"Pin":false})
    );
    assert_eq!(h.stack(), vec![3, 5, 4, 1, 2]);
    assert_eq!(h.drawn(1).first(), Some(&(3, false, true)));

    // What cannot be pinned.
    assert_eq!(
        h.refused(json!({"Pin":{"window":5,"value":true}})),
        "stand-ins can't be pinned"
    );
    assert_eq!(
        h.refused(json!({"Pin":{"window":5}})),
        "stand-ins can't be pinned"
    );
    assert_eq!(
        h.refused(json!({"Pin":{"window":99}})),
        "no window with id 99"
    );
    put(
        &mut h,
        6,
        "app.far",
        "Far",
        rect(-9000.0, -9000.0, 300.0, 200.0),
    );
    assert_eq!(
        h.refused_on(Value::Null, json!({"Pin":{"window":6,"value":true}})),
        "no output to pin to"
    );
}

#[test]
fn move_to_bookmark_centers_the_focused_canvas_window_on_the_bookmark() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "[session]\nsuspend_on_close = true\n");
    put(&mut h, 1, "app.a", "A", rect(300.0, 275.0, 401.0, 301.0));
    put(&mut h, 2, "app.b", "B", rect(350.0, 300.0, 400.0, 300.0));
    h.observe_focus(1);
    h.ipc(json!({"Bookmark":{"name":"lab","to":[1000.4,-500.6]}}));
    // The bookmark rounds to (1000, -501), Y up: the frame's center goes to
    // the world point (1000, 501), its top-left to (1000 - 200, 501 - 150).
    assert_eq!(h.action("move-to-bookmark lab"), CHANGED());
    assert_eq!(h.world(1), rect(800.0, 351.0, 401.0, 301.0));
    assert_eq!(h.stack(), vec![2, 1]);
    // No such bookmark: nothing, and no error.
    assert_eq!(h.action("move-to-bookmark nowhere"), IDLE());
    // A pinned window has no canvas position to move.
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    let before = h.snapshot();
    assert_eq!(h.action("move-to-bookmark lab"), IDLE());
    assert_eq!(h.snapshot(), before);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    // A focused stand-in moves in place.
    h.ipc(json!({"Bookmark":{"name":"desk","to":[0.0,0.0]}}));
    assert_eq!(h.closed(1)["standin"], true);
    assert_eq!(h.focused(), 1);
    assert_eq!(h.action("move-to-bookmark desk"), CHANGED());
    assert_eq!(h.world(1), rect(-200.0, -150.0, 401.0, 301.0));
    // And a stand-in is never pinned.
    assert_eq!(h.action("toggle-pin-to-screen"), IDLE());
    assert_eq!(h.pinned(1), Value::Null);
}

#[test]
fn rules_are_resolved_when_a_window_maps_and_not_on_retitle_or_reload() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        r#"
[[window_rules]]
title = "Draft*"
widget = true
opacity = 0.5

[[window_rules]]
title = "Keep*"
suspend_on_close = true
"#,
    );
    appear(&mut h, 1, "app.x", "Draft 1", (300.0, 200.0));
    appear(&mut h, 2, "app.x", "Final", (300.0, 200.0));
    assert_eq!(h.window(1)["widget"], true);
    assert_eq!(h.rule(2), Value::Null);
    let retitle = |h: &mut Host, id: u64, title: &str| {
        let identity = h.window(id)["source"]["identity"].clone();
        h.ok(json!({"op":"retitle","window":id,"identity":identity,"title":title}))
    };
    // Upstream does not re-check a window against `title` rules after it has
    // mapped: the widget stays one under a title no rule matches, and a
    // window retitled into a rule is not made a widget.
    assert_eq!(retitle(&mut h, 1, "Final"), json!({"dirty":true}));
    assert_eq!(h.window(1)["metadata"]["title"], "Final");
    assert_eq!(h.window(1)["widget"], true);
    assert_eq!(h.rule(1)["opacity"], 0.5);
    assert_eq!(h.placement(1, 1)["opacity"], 0.5);
    retitle(&mut h, 2, "Draft 2");
    assert_eq!(h.window(2)["widget"], false);
    assert_eq!(h.rule(2), Value::Null);
    assert_eq!(h.stack(), vec![1, 2]);

    // A config reload changes no window that is already mapped, and no pin:
    // only windows that map afterwards see the new rules.
    appear(&mut h, 3, "app.y", "Report", (300.0, 200.0));
    h.observe_focus(3);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    let pin = h.pinned(3);
    load_config(
        &mut h,
        &scratch,
        r#"
[[window_rules]]
title = "Final"
opacity = 0.3

[[window_rules]]
title = "Keep*"
suspend_on_close = true
"#,
    );
    assert_eq!(h.window(1)["widget"], true);
    assert_eq!(h.rule(1)["opacity"], 0.5);
    assert_eq!(h.rule(2), Value::Null);
    assert_eq!(h.pinned(3), pin);
    appear(&mut h, 4, "app.z", "Final", (300.0, 200.0));
    assert_eq!(h.rule(4)["opacity"], 0.3);
    appear(&mut h, 5, "app.z", "Draft 3", (300.0, 200.0));
    assert_eq!(h.window(5)["widget"], false);
    assert_eq!(h.rule(5), Value::Null);

    // What upstream does resolve live follows the title of the moment:
    // `suspend_on_close` is asked when the window closes.
    retitle(&mut h, 2, "Keep me");
    assert_eq!(h.closed(2)["standin"], true);
    assert_eq!(h.closed(4)["standin"], false);
    // A stand-in carries no rule. The window that takes it over on a relaunch
    // maps like any other: it keeps the slot's frame and gets the rules its
    // own app id and title match now.
    assert_eq!(h.rule(2), Value::Null);
    let slot = h.world(2);
    h.ipc(json!({"Relaunch":2}));
    assert_eq!(
        appear(&mut h, 6, "app.x", "Final", (640.0, 480.0))["adopted"],
        true
    );
    assert_eq!(h.window(2)["source"]["identity"], identity(6));
    assert_eq!(h.world(2), slot);
    assert_eq!(h.rule(2)["opacity"], 0.3);
    assert_eq!(h.placement(1, 2)["opacity"], 0.3);
}

#[test]
fn hits_reach_pinned_windows_first_then_canvas_windows_then_widgets() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        "[[window_rules]]\napp_id = \"app.widget\"\nwidget = true\n",
    );
    put(
        &mut h,
        1,
        "app.widget",
        "W",
        rect(100.0, 100.0, 600.0, 400.0),
    );
    put(&mut h, 2, "app.a", "A", rect(200.0, 200.0, 300.0, 200.0));
    put(&mut h, 3, "app.p", "P", rect(400.0, 300.0, 200.0, 200.0));
    h.observe_focus(3);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    // A is focused and raised after the pin, and is still below it.
    h.observe_focus(2);
    assert_eq!(h.stack(), vec![1, 3, 2]);
    assert_eq!(
        h.drawn(1),
        vec![(1, false, true), (2, false, false), (3, true, false)]
    );
    // Global points are world points plus (200, 100) while the camera is at
    // the origin. Under (650, 450) are all three: the pinned window is hit.
    let hit = h.hit(1, 650.0, 450.0);
    assert_eq!(hit["window"], 3);
    assert_eq!(hit["pinned"], true);
    assert_eq!(hit["widget"], false);
    assert_eq!(hit["local"], point(50.0, 50.0));
    assert_eq!(hit["native_screen"], point(4050.0, 3050.0));
    // Under (450, 350) are the widget and A; under (350, 250) the widget.
    let hit = h.hit(1, 450.0, 350.0);
    assert_eq!((&hit["window"], &hit["pinned"]), (&json!(2), &json!(false)));
    assert_eq!(hit["widget"], false);
    let hit = h.hit(1, 350.0, 250.0);
    assert_eq!((&hit["window"], &hit["widget"]), (&json!(1), &json!(true)));
    assert_eq!(hit["pinned"], false);
    assert_eq!(h.hit(1, 250.0, 150.0), Value::Null);
    // At half zoom the canvas shrinks toward the output's corner; the pinned
    // window does not move, and is hit at its own scale.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":point(200.0,100.0)}));
    let hit = h.hit(1, 700.0, 550.0);
    assert_eq!(hit["window"], 3);
    assert_eq!(hit["local"], point(100.0, 150.0));
    // A now shows from (300, 200) to (450, 300): the widget's old spot.
    let hit = h.hit(1, 350.0, 250.0);
    assert_eq!(hit["window"], 2);
    assert_eq!(hit["local"], point(100.0, 100.0));
    // Input is validated against the same order.
    let input =
        h.ok(json!({"op":"input","output":1,"screen":point(700.0,550.0),"identity":identity(3)}));
    assert_eq!(input["hit"]["window"], 3);
    assert_eq!(
        h.error(
            json!({"op":"input","output":1,"screen":point(700.0,550.0),"identity":identity(2)})
        ),
        "stale source identity"
    );
    // The pin belongs to main: side draws and hits nothing of it.
    assert_eq!(h.drawn(2), vec![]);
    assert_eq!(h.hit(2, 1700.0, 400.0), Value::Null);
}

#[test]
fn a_close_never_hands_the_focus_to_a_widget_or_a_pinned_window() {
    let scratch = Scratch::new();
    let gone = json!({"standin":false,"effect":null,"navigation":null,"dirty":true});
    // Only a widget is left in view: its 200 x 100 frame is at (600, 350).
    let mut h = running(
        &scratch,
        "[[window_rules]]\napp_id = \"app.widget\"\nwidget = true\nposition = [700, -400]\n",
    );
    put(&mut h, 1, "app.a", "A", rect(300.0, 275.0, 400.0, 300.0));
    h.observe_focus(1);
    appear(&mut h, 2, "app.widget", "W", (200.0, 100.0));
    assert_eq!(h.world(2), rect(600.0, 350.0, 200.0, 100.0));
    assert_eq!(h.closed(1), gone);
    assert_eq!(h.focused(), Value::Null);
    assert_eq!(h.history(), json!([]));
    assert_eq!(h.action("toggle-pin-to-screen"), IDLE());
    assert_eq!(h.pinned(2), Value::Null);

    // Only a screen-pinned window is left in view.
    let mut h = running(&scratch, "");
    put(&mut h, 1, "app.a", "A", rect(300.0, 275.0, 400.0, 300.0));
    put(&mut h, 2, "app.b", "PiP", rect(750.0, 100.0, 200.0, 120.0));
    h.observe_focus(2);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    h.observe_focus(1);
    assert_eq!(h.closed(1), gone);
    assert_eq!(h.focused(), Value::Null);
    assert_eq!(h.history(), json!([]));
    assert_eq!(h.action("close-window"), IDLE());
    assert!(!h.pinned(2).is_null());

    // A canvas window in view still takes it, though a widget is nearer:
    // from the closed frame's center (500, 425) the widget's is about 202
    // away and the window's about 503.
    let mut h = running(
        &scratch,
        "[[window_rules]]\napp_id = \"app.widget\"\nwidget = true\nposition = [700, -400]\n",
    );
    put(&mut h, 1, "app.a", "A", rect(300.0, 275.0, 400.0, 300.0));
    put(&mut h, 2, "app.b", "B", rect(0.0, 600.0, 100.0, 100.0));
    appear(&mut h, 3, "app.widget", "W", (200.0, 100.0));
    assert_eq!(h.window(3)["widget"], true);
    h.observe_focus(1);
    // Window 2 never held the focus: only the nearest-visible tier finds it.
    assert_eq!(h.history(), json!([1]));
    let reply = h.closed(1);
    assert_eq!(reply["effect"]["window"], 2, "{reply}");
    assert_eq!(h.focused(), 2);
}

#[test]
fn a_closing_pinned_window_or_widget_has_no_spatial_follower() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        r#"
[[window_rules]]
app_id = "app.pip"
pinned_to_screen = true
position = [300, 200]

[[window_rules]]
app_id = "app.widget"
widget = true
position = [800, -200]
"#,
    );
    // A is in view and the most recent; B is older and hangs off the right edge.
    put(&mut h, 1, "app.a", "A", rect(100.0, 500.0, 200.0, 150.0));
    put(&mut h, 2, "app.b", "B", rect(800.0, 50.0, 400.0, 300.0));
    h.observe_focus(2);
    h.observe_focus(1);
    // The pinned window's canvas frame lies over B. It is not B's neighbour:
    // the most recent window in view takes the focus and no camera moves.
    appear(&mut h, 3, "app.pip", "P", (200.0, 100.0));
    assert_eq!(h.world(3), rect(700.0, 150.0, 200.0, 100.0));
    assert_eq!(h.focused(), 3);
    let closed = h.closed(3);
    assert_eq!(closed["standin"], false);
    assert_eq!(closed["effect"]["window"], 1, "{closed}");
    assert_eq!(closed["navigation"], Value::Null, "{closed}");
    assert_eq!(h.focused(), 1);
    assert_eq!(h.history(), json!([1, 2]));
    assert_eq!(h.snapshot()["outputs"][0]["camera"], point(0.0, 0.0));
    // The same for a widget on that frame.
    appear(&mut h, 4, "app.widget", "W", (200.0, 100.0));
    assert_eq!(h.world(4), rect(700.0, 150.0, 200.0, 100.0));
    h.observe_focus(4);
    let closed = h.closed(4);
    assert_eq!(closed["effect"]["window"], 1, "{closed}");
    assert_eq!(closed["navigation"], Value::Null, "{closed}");
    // Control: the same frame as a canvas window does follow to B and flies.
    let p = put(
        &mut h,
        5,
        "app.plain",
        "P",
        rect(700.0, 150.0, 200.0, 100.0),
    );
    h.observe_focus(p);
    let closed = h.closed(p);
    assert_eq!(closed["effect"]["window"], 2, "{closed}");
    assert_eq!(closed["navigation"]["animating"], true, "{closed}");
}

#[test]
fn a_size_rule_is_recorded_and_reported_as_not_applied() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        r#"
[[window_rules]]
app_id = "app.sized"
size = [800, 600]
position = [0, 0]
fullscreen = true
"#,
    );
    // The frame keeps the window's own size, centered where the rule says.
    // This shell never said it can deliver a size, so none is asked.
    let reply = appear(&mut h, 1, "app.sized", "S", (400.0, 300.0));
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    assert_eq!(h.snapshot()["native_resize"], Value::Null);
    assert_eq!(h.world(1), rect(-200.0, -150.0, 400.0, 300.0));
    let rule = h.rule(1);
    assert_eq!(rule["size"], json!([800, 600]));
    assert_eq!(rule["fullscreen"], true);
    assert_eq!(rule["position"], json!([0, 0]));
    assert_eq!(rule["not_applied"], json!(["size", "fullscreen"]));
    assert_eq!(
        h.read(json!({"Resize":{}})),
        json!({"Size":{"width":400,"height":300}})
    );
    // Nor of a shell that says it cannot.
    assert_eq!(
        h.ok(json!({"op":"native_resize_capability","enabled":false})),
        json!({})
    );
    let reply = appear(&mut h, 2, "app.sized", "S", (400.0, 300.0));
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    assert_eq!(h.snapshot()["native_resize"], Value::Null);
    assert_eq!(h.world(2), rect(-200.0, -150.0, 400.0, 300.0));
    assert_eq!(h.rule(2)["not_applied"], json!(["size", "fullscreen"]));
}

/// Answer one resize effect as the adapter would: the window is found with
/// `size`, at a native origin no world frame may read.
fn resized(
    h: &mut Host,
    effect: &Value,
    outcome: &str,
    attempted: bool,
    size: (f64, f64),
) -> Value {
    let frame = rect(NATIVE.0, NATIVE.1, size.0, size.1);
    let requested = if effect["requested"].is_null() {
        json!({"width":0.0,"height":0.0})
    } else {
        effect["requested"].clone()
    };
    h.ok(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":outcome,"ax_error":0,"mutation_attempted":attempted,"observed":true,"requested":requested,"actual_ax":frame,"actual_cg":frame}}))
}
/// The size transaction an `attach` reply began: `transaction`, and its effect
/// as the one entry of `effects`, which is also the slot's pending effect.
fn sized_by_rule(h: &mut Host, reply: &Value) -> Value {
    let effects = reply["effects"]
        .as_array()
        .unwrap_or_else(|| panic!("{reply}"));
    assert_eq!(effects.len(), 1, "{reply}");
    assert_eq!(effects[0]["op"], "observe_resize_source", "{reply}");
    assert_eq!(reply["transaction"], effects[0]["transaction"], "{reply}");
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], effects[0]);
    effects[0].clone()
}

/// Play the shell's part for the size transaction `read` begins: the baseline
/// read finds `from`, the setter is asked for `asks` and the window takes
/// `took`, and the final read finds the same. Returns the reply to that last
/// read, which ends the transaction.
fn deliver_ruled(
    h: &mut Host,
    read: &Value,
    from: (f64, f64),
    asks: (f64, f64),
    outcome: &str,
    took: (f64, f64),
) -> Value {
    assert_eq!(read["op"], "observe_resize_source", "{read}");
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], *read);
    let setter = resized(h, read, "observed", false, from)["effect"].clone();
    assert_eq!(setter["op"], "resize_native_window", "{setter}");
    assert_eq!(setter["requested"], json!({"width":asks.0,"height":asks.1}));
    let last = resized(h, &setter, outcome, true, took)["effect"].clone();
    assert_eq!(last["op"], "observe_resize_source", "{last}");
    resized(h, &last, "observed", false, took)
}
/// The transaction a reply that ended one began for the next window in the
/// queue: `transaction` and `effect`, the keys of a transaction's own next
/// effect, which `-[DWResizeCoordinator consume:]` reads.
fn next_ruled(h: &mut Host, ended: &Value, window: u64) -> Value {
    let read = ended["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source", "{ended}");
    assert_eq!(read["window"], window, "{ended}");
    assert_eq!(ended["transaction"], read["transaction"], "{ended}");
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["window"], window);
    assert_eq!(slot["pending_effect"], read);
    read
}

const SIZED_RULES: &str = r#"
[[window_rules]]
app_id = "app.sized"
size = [800, 600]
position = [0, 0]
preserve_aspect_ratio = true

[[window_rules]]
app_id = "app.sized-widget"
size = [800, 600]
position = [3000, 0]
widget = true

[[window_rules]]
app_id = "app.sized-pin"
size = [800, 600]
pinned_to_screen = true

[[window_rules]]
app_id = "app.sized-free"
size = [600, 400]
"#;
const OWED: fn(u64) -> String =
    |window| format!("a native resize of window {window} is still pending");

// Upstream's size arm of a new toplevel's first commit and the placement of
// the commit after it (src/handlers/compositor.rs), under a shell that can
// deliver a size: the rule's size is configured first, and the pin, the
// `position` and the placement policy then place the frame of that size, for
// a widget and a rule-pinned window like any other. Here the window is placed
// for the size asked as it maps and stands centered in that frame, at its own
// size, until it answers. Five ruled windows map together and are asked one
// at a time, in map order, each as the transaction before it ends.
//
// By hand, on main (1000 x 800 at global (200, 100), usable center (500, 425),
// camera at the origin): an 800 x 600 frame centered on the canvas point
// (0, 0) is (-400, -300), and a 401 x 301 window centered in it stands at
// (-400 + 399 / 2, -300 + 299 / 2) = (-201, -151), halving toward zero as
// upstream's i32 division does. The same frame around (3000, 0) is
// (2600, -300). Pinned and centered on the output it is at the output-local
// (500 - 400, 400 - 300) = (100, 100), the global point (300, 200). With no
// `position`, `window_placement` centers a 600 x 400 frame under the usable
// center: (500 - 300, 425 - 200) = (200, 225), and a 401 x 301 window stands
// in it at (200 + 199 / 2, 225 + 99 / 2) = (299, 274).
#[test]
fn a_size_rule_is_asked_of_a_new_window_when_the_shell_can_deliver_a_size() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, SIZED_RULES);
    assert_eq!(
        h.ok(json!({"op":"native_resize_capability","enabled":true})),
        json!({})
    );
    let reply = appear(&mut h, 1, "app.sized", "S", (401.0, 301.0));
    // The arrival is what it was: placed, focused, flown to. The flight is
    // aimed at the frame asked for, whose center (0, 0) goes under the usable
    // center: the 401 x 301 frame's own center is (-0.5, -0.5).
    assert_eq!(reply["window"], 1);
    assert_eq!(reply["adopted"], false);
    assert_eq!(reply["effect"]["op"], "focus_native_window");
    assert_eq!(reply["effect"]["window"], 1);
    assert_eq!(reply["navigation"]["animating"], true);
    assert_eq!(reply["navigation"]["target_camera"], point(-500.0, -425.0));
    assert_eq!(reply["dirty"], true);
    // And one size transaction began. No size is written before the window
    // has answered.
    let read = sized_by_rule(&mut h, &reply);
    assert_eq!(read["window"], 1);
    assert_eq!(h.world(1), rect(-201.0, -151.0, 401.0, 301.0));
    // `size` was asked; the field nothing applies is still named. A rule's
    // `fullscreen` under this shell is tests/fullscreen_flow.rs's.
    assert_eq!(h.rule(1)["not_applied"], json!([]));

    // Four more ruled windows while that size is owed. There is one
    // transaction: each is placed for the size its rule names, waits its
    // turn, and says `size` is not applied yet.
    let second = appear(&mut h, 2, "app.sized", "S", (400.0, 300.0));
    assert!(second.get("transaction").is_none() && second.get("effects").is_none());
    assert_eq!(second["effect"]["window"], 2);
    assert_eq!(h.world(2), rect(-200.0, -150.0, 400.0, 300.0));
    assert_eq!(h.rule(2)["not_applied"], json!(["size"]));
    // A widget is asked like any window, and maps without focus or flight.
    let widget = appear(&mut h, 3, "app.sized-widget", "S", (400.0, 300.0));
    assert!(widget.get("transaction").is_none() && widget.get("effects").is_none());
    assert_eq!(
        (&widget["effect"], &widget["navigation"]),
        (&Value::Null, &Value::Null)
    );
    assert_eq!(h.window(3)["widget"], true);
    assert_eq!(h.world(3), rect(2800.0, -150.0, 400.0, 300.0));
    assert_eq!(h.rule(3)["not_applied"], json!(["size"]));
    // So is a window its rule pins: the pin is the one of the frame asked
    // for. Pinned for its own size it would be at the global (500, 350).
    let pin = appear(&mut h, 4, "app.sized-pin", "S", (400.0, 300.0));
    assert!(pin.get("transaction").is_none() && pin.get("effects").is_none());
    assert_eq!(
        h.pinned(4),
        json!({"output":1,"screen_rect":rect(300.0,200.0,400.0,300.0)})
    );
    assert_eq!(h.rule(4)["not_applied"], json!(["size"]));
    // And one the placement policy places, for the frame asked for.
    let free = appear(&mut h, 5, "app.sized-free", "S", (401.0, 301.0));
    assert!(free.get("transaction").is_none() && free.get("effects").is_none());
    assert_eq!(h.world(5), rect(299.0, 274.0, 401.0, 301.0));
    assert_eq!(h.rule(5)["not_applied"], json!(["size"]));
    // Two that will not be there when their turn comes: one closes, which
    // nothing refuses for a window whose size is not the one in the slot,
    // and one loses its source.
    appear(&mut h, 6, "app.sized", "S", (400.0, 300.0));
    assert_eq!(h.closed(6)["standin"], false);
    appear(&mut h, 7, "app.sized", "S", (400.0, 300.0));
    h.ok(json!({"op":"remove_source","window":7,"identity":identity(7),"keep_placeholder":true}));
    assert_eq!(h.snapshot()["native_resize"]["window"], 1);
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], read);

    // The shell's part for window 1: the baseline read, the setter, the final
    // read. The frame is the one asked for, exactly: the request that keeps
    // the center lands on its top-left.
    let ended = deliver_ruled(
        &mut h,
        &read,
        (401.0, 301.0),
        (800.0, 600.0),
        "applied",
        (800.0, 600.0),
    );
    assert_eq!(h.world(1), rect(-400.0, -300.0, 800.0, 600.0));
    assert_eq!(
        h.read(json!({"Resize":{"window":1}})),
        json!({"Size":{"width":800,"height":600}})
    );
    // The reply that ends that transaction begins the next window's: map
    // order. From then on its `size` is asked, and the others' is not.
    let read = next_ruled(&mut h, &ended, 2);
    assert_eq!(h.rule(2)["not_applied"], json!([]));
    for waiting in [3, 4, 5] {
        assert_eq!(h.rule(waiting)["not_applied"], json!(["size"]));
    }
    // A window that grants less keeps the center for its observed size,
    // as the supported native readback IPC resize does.
    let ended = deliver_ruled(
        &mut h,
        &read,
        (400.0, 300.0),
        (800.0, 600.0),
        "clamped",
        (700.0, 600.0),
    );
    assert_eq!(h.world(2), rect(-350.0, -300.0, 700.0, 600.0));
    // The widget.
    let read = next_ruled(&mut h, &ended, 3);
    assert_eq!(h.rule(3)["not_applied"], json!([]));
    let ended = deliver_ruled(
        &mut h,
        &read,
        (400.0, 300.0),
        (800.0, 600.0),
        "applied",
        (800.0, 600.0),
    );
    assert_eq!(h.world(3), rect(2600.0, -300.0, 800.0, 600.0));
    assert_eq!(h.window(3)["widget"], true);
    // The pinned window. While its size is owed it is the transaction's: no
    // drag takes it and its pin waits, as for any window that owes a size.
    let read = next_ruled(&mut h, &ended, 4);
    assert_eq!(h.rule(4)["not_applied"], json!([]));
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":4,"output":1})),
        OWED(4)
    );
    assert_eq!(
        h.refused(json!({"Pin":{"window":4,"value":false}})),
        "resize must drain before structural change; cancel and reconcile pending effects"
    );
    let ended = deliver_ruled(
        &mut h,
        &read,
        (400.0, 300.0),
        (800.0, 600.0),
        "applied",
        (800.0, 600.0),
    );
    assert_eq!(
        h.pinned(4),
        json!({"output":1,"screen_rect":rect(300.0,200.0,800.0,600.0)})
    );
    // The policy-placed window. The two that left the queue are passed over:
    // the closed one is gone, and the slot without a source still names
    // `size`, which nothing asked of it.
    let read = next_ruled(&mut h, &ended, 5);
    assert_eq!(h.rule(7)["not_applied"], json!(["size"]));
    let ended = deliver_ruled(
        &mut h,
        &read,
        (401.0, 301.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(h.world(5), rect(200.0, 225.0, 600.0, 400.0));
    // Nobody is left: the last reply begins nothing.
    assert_eq!(ended, json!({"effect":null}));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(h.world(7), rect(-200.0, -150.0, 400.0, 300.0));

    // A window that takes over a slot keeps the slot's frame whatever its rule
    // says of `size`, as upstream's adopted window does: nothing is asked.
    // The slot that lost its source is waiting for exactly this window.
    let reply = appear(&mut h, 8, "app.sized", "S", (400.0, 300.0));
    assert_eq!(reply["window"], 7);
    assert_eq!(reply["adopted"], true);
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    assert_eq!(h.world(7), rect(-200.0, -150.0, 400.0, 300.0));
    assert_eq!(h.rule(7)["not_applied"], json!(["size"]));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");

    // A window that maps with the rule's size already needs nothing
    // delivered, a widget and a pinned one included: `size` is not listed.
    let reply = appear(&mut h, 9, "app.sized", "S", (800.0, 600.0));
    assert_eq!(reply["window"], 8);
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    assert_eq!(h.world(8), rect(-400.0, -300.0, 800.0, 600.0));
    assert_eq!(h.rule(8)["not_applied"], json!([]));
    for (wid, app) in [(10, "app.sized-widget"), (11, "app.sized-pin")] {
        let reply = appear(&mut h, wid, app, "S", (800.0, 600.0));
        assert_eq!(reply["window"], wid - 1);
        assert!(
            reply.get("transaction").is_none() && reply.get("effects").is_none(),
            "{app}: {reply}"
        );
        assert_eq!(h.rule(wid - 1)["not_applied"], json!([]), "{app}");
    }
    assert_eq!(h.world(9), rect(2600.0, -300.0, 800.0, 600.0));
    assert_eq!(
        h.pinned(10),
        json!({"output":1,"screen_rect":rect(300.0,200.0,800.0,600.0)})
    );
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
}

// A window whose rule names a size and that maps while a drag holds the
// canvas waits as well: no size transaction begins under a gesture. Nothing
// ends a gesture in a reply the shell hands to its resize coordinator, so the
// window is asked with the next new window that maps, in that window's reply,
// or when a later transaction ends.
#[test]
fn a_ruled_size_that_waited_out_a_drag_is_asked_with_the_next_new_window() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, SIZED_RULES);
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    put(
        &mut h,
        1,
        "app.plain",
        "P",
        rect(2000.0, 2000.0, 300.0, 200.0),
    );
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    let reply = appear(&mut h, 2, "app.sized", "S", (400.0, 300.0));
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    assert_eq!(h.world(2), rect(-200.0, -150.0, 400.0, 300.0));
    assert_eq!(h.snapshot()["native_resize"], Value::Null);
    assert_eq!(h.ok(json!({"op":"end_gesture"})), json!({}));
    assert_eq!(h.snapshot()["native_resize"], Value::Null);
    assert_eq!(h.rule(2)["not_applied"], json!(["size"]));
    // A window no rule matches maps: its reply is its own arrival, and
    // carries the transaction of the window that was waiting.
    let reply = appear(&mut h, 3, "app.plain", "P", (300.0, 200.0));
    assert_eq!(reply["window"], 3);
    assert_eq!(reply["effect"]["window"], 3);
    let read = sized_by_rule(&mut h, &reply);
    assert_eq!(read["window"], 2);
    assert_eq!(h.rule(2)["not_applied"], json!([]));
    let ended = deliver_ruled(
        &mut h,
        &read,
        (400.0, 300.0),
        (800.0, 600.0),
        "applied",
        (800.0, 600.0),
    );
    assert_eq!(ended, json!({"effect":null}));
    assert_eq!(h.world(2), rect(-400.0, -300.0, 800.0, 600.0));

    // A shell that says it can no longer deliver a size is asked nothing
    // more: what waited stops waiting.
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    appear(&mut h, 4, "app.sized", "S", (400.0, 300.0));
    h.ok(json!({"op":"end_gesture"}));
    h.ok(json!({"op":"native_resize_capability","enabled":false}));
    let reply = appear(&mut h, 5, "app.plain", "P", (300.0, 200.0));
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    let reply = appear(&mut h, 6, "app.plain", "P", (300.0, 200.0));
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(h.rule(4)["not_applied"], json!(["size"]));
    // A window that has the size already waits for nothing, a drag included.
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    let reply = appear(&mut h, 7, "app.sized", "S", (800.0, 600.0));
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    assert_eq!(h.world(7), rect(-400.0, -300.0, 800.0, 600.0));
    assert_eq!(h.rule(7)["not_applied"], json!([]));
}

// Upstream's rule size is one-shot at a window's first commit, "so the user
// can still resize" (`pending_size`, src/handlers/compositor.rs): nothing
// forces it over a size the user has given since. So a ruled window that the
// user sizes while it still waits its turn waits no longer. Its `size` was
// never asked and stays named.
//
// By hand, on main: the 400 x 300 window stands at (-200, -150) in the frame
// asked for. An IPC resize to 500 x 350 keeps its center: (-200 - 100 / 2,
// -150 - 50 / 2) = (-250, -175). A fit takes the usable area, 1000 x 750
// with no outer gap, around the same center (0, 0): (-500, -375). A resize
// drag by (60, 40) from the bottom right leaves the top-left where it is.
#[test]
fn a_ruled_window_the_user_sizes_before_its_turn_is_not_asked_its_rules_size() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, SIZED_RULES);
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    put(
        &mut h,
        1,
        "app.plain",
        "P",
        rect(2000.0, 2000.0, 300.0, 200.0),
    );
    // A ruled window that maps under a drag of window 1 and waits it out.
    let waiting = |h: &mut Host, wid: u64| -> u64 {
        h.ok(json!({"op":"begin_drag","window":1,"output":1}));
        let reply = appear(h, wid, "app.sized", "S", (400.0, 300.0));
        assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
        let window = reply["window"].as_u64().unwrap();
        assert_eq!(h.world(window), rect(-200.0, -150.0, 400.0, 300.0));
        assert_eq!(h.ok(json!({"op":"end_gesture"})), json!({}));
        assert_eq!(h.rule(window)["not_applied"], json!(["size"]));
        window
    };
    // Nothing is owed it afterwards: `size` is still named, and the next new
    // window's reply begins no transaction for it.
    let left_alone = |h: &mut Host, window: u64, wid: u64| {
        assert_eq!(h.rule(window)["not_applied"], json!(["size"]));
        let reply = appear(h, wid, "app.plain", "P", (300.0, 200.0));
        assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
        assert_eq!(h.snapshot()["native_resize"]["window"], window);
        assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    };

    // IPC `resize`. The reply that ends its transaction begins no other.
    let window = waiting(&mut h, 2);
    let data = h.ipc(json!({"Resize":{"window":window,"to":[500,350]}}));
    assert_eq!(
        data["reply"],
        json!({"Ok":{"Size":{"width":500,"height":350}}})
    );
    let ended = deliver_ruled(
        &mut h,
        &data["effect"],
        (400.0, 300.0),
        (500.0, 350.0),
        "applied",
        (500.0, 350.0),
    );
    assert_eq!(ended, json!({"effect":null}));
    assert_eq!(h.world(window), rect(-250.0, -175.0, 500.0, 350.0));
    left_alone(&mut h, window, 3);
    assert_eq!(h.world(window), rect(-250.0, -175.0, 500.0, 350.0));

    // The size it already has, asked by IPC, delivers nothing and ends the
    // wait all the same: the user has said what size the window is to be.
    let window = waiting(&mut h, 4);
    assert_eq!(
        h.read(json!({"Resize":{"window":window,"to":[400,300]}})),
        json!({"Size":{"width":400,"height":300}})
    );
    let other = h.ipc(json!({"Resize":{"window":1,"to":[320,220]}}));
    let ended = deliver_ruled(
        &mut h,
        &other["effect"],
        (300.0, 200.0),
        (320.0, 220.0),
        "applied",
        (320.0, 220.0),
    );
    assert_eq!(ended, json!({"effect":null}));
    assert_eq!(h.world(window), rect(-200.0, -150.0, 400.0, 300.0));
    assert_eq!(h.rule(window)["not_applied"], json!(["size"]));

    // A fit. Asked the rule's size after it, the window would lose the fit
    // and its restore point with it.
    let window = waiting(&mut h, 5);
    h.ok(json!({"op":"focus","window":window}));
    let reply = h.action("fit-window");
    let ended = deliver_ruled(
        &mut h,
        &reply["effect"],
        (400.0, 300.0),
        (1000.0, 750.0),
        "applied",
        (1000.0, 750.0),
    );
    assert_eq!(ended["effect"], Value::Null);
    assert!(ended.get("transaction").is_none(), "{ended}");
    assert_eq!(h.world(window), rect(-500.0, -375.0, 1000.0, 750.0));
    assert_eq!(h.window(window)["mode"], "fit");
    left_alone(&mut h, window, 6);
    assert_eq!(h.window(window)["mode"], "fit");

    // A resize drag, which commits its sizes itself.
    let window = waiting(&mut h, 7);
    h.ok(json!({"op":"begin_resize","window":window,"output":1,"edges":"bottom_right"}));
    h.ok(json!({"op":"gesture_to","screen_delta":point(60.0,40.0)}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.world(window), rect(-200.0, -150.0, 460.0, 340.0));
    assert_eq!(h.rule(window)["not_applied"], json!(["size"]));
    let reply = appear(&mut h, 8, "app.plain", "P", (300.0, 200.0));
    assert!(reply.get("transaction").is_none() && reply.get("effects").is_none());
    assert_eq!(h.world(window), rect(-200.0, -150.0, 460.0, 340.0));

    // And a resize by hand through the native transaction: 100 points down
    // and right from the bottom right corner, at zoom 1. The rule has
    // `preserve_aspect_ratio`, so the 4:3 the window starts with is kept
    // (upstream constrain_to_ratio): on a corner the axis that moved farther
    // relative to the ratio drives, here the height (100 * 400 > 100 * 300),
    // and the width is 400 * 4 / 3, rounded.
    let window = waiting(&mut h, 9);
    let begun = h.ok(json!({"op":"begin_native_resize","window":window,"output":1,"edges":"bottom_right","start_screen":point(500.0,500.0),"group":false}));
    let read = begun["effect"].clone();
    assert_eq!(read["op"], "observe_resize_source", "{begun}");
    resized(&mut h, &read, "observed", false, (400.0, 300.0));
    let moved = h.ok(json!({"op":"native_resize_to","transaction":read["transaction"],"screen":point(600.0,600.0)}));
    let setter = moved["effect"].clone();
    assert_eq!(
        setter["requested"],
        json!({"width":533.0,"height":400.0}),
        "{moved}"
    );
    resized(&mut h, &setter, "applied", true, (533.0, 400.0));
    let end = h.ok(json!({"op":"end_native_resize","transaction":read["transaction"]}));
    let ended = resized(&mut h, &end["effect"], "observed", false, (533.0, 400.0));
    assert_eq!(ended, json!({"effect":null}));
    assert_eq!(h.world(window), rect(-200.0, -150.0, 533.0, 400.0));
    left_alone(&mut h, window, 10);
    assert_eq!(h.world(window), rect(-200.0, -150.0, 533.0, 400.0));

    // Sizing another window ends no wait: the queued one is asked in the
    // reply that ends that transaction, as before.
    let window = waiting(&mut h, 11);
    let other = h.ipc(json!({"Resize":{"window":1,"to":[340,240]}}));
    let ended = deliver_ruled(
        &mut h,
        &other["effect"],
        (320.0, 220.0),
        (340.0, 240.0),
        "applied",
        (340.0, 240.0),
    );
    let read = next_ruled(&mut h, &ended, window);
    let ended = deliver_ruled(
        &mut h,
        &read,
        (400.0, 300.0),
        (800.0, 600.0),
        "applied",
        (800.0, 600.0),
    );
    assert_eq!(ended, json!({"effect":null}));
    assert_eq!(h.world(window), rect(-400.0, -300.0, 800.0, 600.0));
}

// Several windows of one rule that names a size and no `position`, mapping
// together: `window_placement` places each one's frame of the size asked, and
// upstream's cascade walks a later one off an earlier (cascade_position,
// src/state/placement.rs, reads the stage, where each is at its ruled size
// by the time the next is placed). A window that stands at its own size,
// asked or still waiting its turn, counts as the frame it is becoming.
//
// By hand, on main: the first 600 x 400 frame is (200, 225), the second one
// title bar (25) down and right of it at (225, 250), the third at (250, 275).
// A 401 x 301 window stands in them at (299, 274), (324, 299) and (349, 324).
#[test]
fn ruled_windows_that_map_together_cascade_by_the_frames_asked_for() {
    let scratch = Scratch::new();
    // This scenario exercises center cascades; the macOS default is auto.
    let config = format!("window_placement = \"center\"\n{SIZED_RULES}");
    let mut h = running(&scratch, &config);
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    let first = appear(&mut h, 1, "app.sized-free", "S", (401.0, 301.0));
    let read = sized_by_rule(&mut h, &first);
    assert_eq!(read["window"], 1);
    assert_eq!(h.world(1), rect(299.0, 274.0, 401.0, 301.0));
    // While that size is asked and not answered: off the frame asked for.
    let second = appear(&mut h, 2, "app.sized-free", "S", (401.0, 301.0));
    assert!(second.get("transaction").is_none() && second.get("effects").is_none());
    assert_eq!(h.world(2), rect(324.0, 299.0, 401.0, 301.0));
    assert_eq!(h.rule(2)["not_applied"], json!(["size"]));
    // And off the frame of one that is still waiting its turn.
    let third = appear(&mut h, 3, "app.sized-free", "S", (401.0, 301.0));
    assert!(third.get("transaction").is_none() && third.get("effects").is_none());
    assert_eq!(h.world(3), rect(349.0, 324.0, 401.0, 301.0));
    let ended = deliver_ruled(
        &mut h,
        &read,
        (401.0, 301.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(h.world(1), rect(200.0, 225.0, 600.0, 400.0));
    let read = next_ruled(&mut h, &ended, 2);
    let ended = deliver_ruled(
        &mut h,
        &read,
        (401.0, 301.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(h.world(2), rect(225.0, 250.0, 600.0, 400.0));
    let read = next_ruled(&mut h, &ended, 3);
    let ended = deliver_ruled(
        &mut h,
        &read,
        (401.0, 301.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(ended, json!({"effect":null}));
    assert_eq!(h.world(3), rect(250.0, 275.0, 600.0, 400.0));
}

// The same under `window_placement = "auto"`: the slot beside the first
// window is measured from the frame it is becoming, so two ruled windows end
// where two windows that have the size already are placed.
#[test]
fn auto_placement_reads_the_frame_a_ruled_window_is_becoming() {
    let scratch = Scratch::new();
    let config = format!("window_placement = \"auto\"\n{SIZED_RULES}");
    let mut plain = running(&scratch, &config);
    plain.ok(json!({"op":"native_resize_capability","enabled":true}));
    appear(&mut plain, 1, "app.plain", "P", (600.0, 400.0));
    appear(&mut plain, 2, "app.plain", "P", (600.0, 400.0));
    assert_eq!(plain.world(1), rect(200.0, 225.0, 600.0, 400.0));
    assert_ne!(plain.world(2), plain.world(1));

    let mut h = running(&scratch, &config);
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    let first = appear(&mut h, 1, "app.sized-free", "S", (400.0, 300.0));
    let read = sized_by_rule(&mut h, &first);
    appear(&mut h, 2, "app.sized-free", "S", (400.0, 300.0));
    let ended = deliver_ruled(
        &mut h,
        &read,
        (400.0, 300.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    let read = next_ruled(&mut h, &ended, 2);
    deliver_ruled(
        &mut h,
        &read,
        (400.0, 300.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(h.world(1), plain.world(1));
    assert_eq!(h.world(2), plain.world(2));
}

#[test]
fn a_pin_follows_its_output_away_and_stays_on_screen() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    put(&mut h, 1, "app.q", "Q", rect(650.0, 560.0, 300.0, 200.0));
    h.observe_focus(1);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(850.0,660.0,300.0,200.0)})
    );
    // Main is removed. Until the shell says which outputs are left the pin
    // stays bound to it and is drawn nowhere.
    h.ok(json!({"op":"remove_output","output":1}));
    assert_eq!(h.pinned(1), json!({"output":1,"screen_rect":null}));
    assert_eq!(h.drawn(2), vec![]);
    // Main is really gone: the pin moves to side, 800 x 600, as far in as
    // the whole frame fits, (500, 400), and its canvas frame is side's.
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), DIRTY());
    assert_eq!(
        h.pinned(1),
        json!({"output":2,"screen_rect":rect(1800.0,500.0,300.0,200.0)})
    );
    assert_eq!(h.world(1), rect(10500.0, 400.0, 300.0, 200.0));
    assert_eq!(h.drawn(2), vec![(1, true, false)]);
    // Main comes back: the pin has moved for good.
    main_output(&mut h);
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), CLEAN());
    assert_eq!(h.pinned(1)["output"], 2);
    assert_eq!(h.drawn(1), vec![]);
    // Side goes: the pin moves to main, where it fits as it is.
    h.ok(json!({"op":"remove_output","output":2}));
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), DIRTY());
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(700.0,500.0,300.0,200.0)})
    );
    // The last output goes: the pin has nowhere to be drawn, and waits.
    h.ok(json!({"op":"remove_output","output":1}));
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), CLEAN());
    assert_eq!(h.pinned(1), json!({"output":1,"screen_rect":null}));
    assert_eq!(h.snapshot()["placements"], json!([]));
    assert_eq!(
        h.ok(json!({"op":"ipc","output":null,"request":"State"}))["reply"]["Ok"]["State"]["pinned"],
        json!([])
    );
    // Another output connects and is all there is: the pin takes it at the
    // settle, clamped into 640 x 480.
    h.ok(json!({"op":"register_output","stable_id":"other","screen_bounds":rect(0.0,0.0,640.0,480.0)}));
    assert_eq!(h.pinned(1), json!({"output":1,"screen_rect":null}));
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), DIRTY());
    assert_eq!(
        h.pinned(1),
        json!({"output":3,"screen_rect":rect(340.0,280.0,300.0,200.0)})
    );
    assert_eq!(h.drawn(3), vec![(1, true, false)]);
}

/// The shell answers any screen change by removing every output and
/// registering the current ones again in its own order, then
/// `outputs_settled`.
#[test]
fn pins_keep_their_outputs_through_a_screen_reconfiguration() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, "");
    // P is pinned by hand on main with its right and bottom edges off the
    // output: local (800, 650) on 1000 x 800. Q is pinned on side at (100, 100).
    put(&mut h, 1, "app.p", "P", rect(800.0, 650.0, 300.0, 200.0));
    h.observe_focus(1);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    put(&mut h, 2, "app.q", "Q", rect(10100.0, 100.0, 300.0, 200.0));
    h.observe_focus(2);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    let on_main = json!({"output":1,"screen_rect":rect(1000.0,750.0,300.0,200.0)});
    let on_side = json!({"output":2,"screen_rect":rect(1400.0,200.0,300.0,200.0)});
    assert_eq!(
        (h.pinned(1), h.pinned(2)),
        (on_main.clone(), on_side.clone())
    );
    let reconfigure = |h: &mut Host, side: bool| {
        h.ok(json!({"op":"remove_output","output":1}));
        h.ok(json!({"op":"remove_output","output":2}));
        assert_eq!(h.snapshot()["placements"], json!([]));
        main_output(h);
        if side {
            side_output(h);
        }
        h.ok(json!({"op":"outputs_settled"}))
    };
    // Both displays are still there: neither pin changes output, and the one
    // hanging off main's edge is not pulled in.
    assert_eq!(reconfigure(&mut h, true), CLEAN());
    assert_eq!((h.pinned(1), h.pinned(2)), (on_main.clone(), on_side));
    assert_eq!(h.drawn(1), vec![(1, true, false)]);
    assert_eq!(h.drawn(2), vec![(2, true, false)]);
    // Side is gone: its pin moves to main at the settle, where it fits as it
    // is. Main's own pin is untouched.
    h.ok(json!({"op":"remove_output","output":1}));
    h.ok(json!({"op":"remove_output","output":2}));
    main_output(&mut h);
    assert_eq!(h.pinned(2), json!({"output":2,"screen_rect":null}));
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), DIRTY());
    let moved = json!({"output":1,"screen_rect":rect(300.0,200.0,300.0,200.0)});
    assert_eq!((h.pinned(1), h.pinned(2)), (on_main, moved.clone()));
    // Side comes back: the pin that left it stays on main.
    side_output(&mut h);
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), CLEAN());
    assert_eq!(h.pinned(2), moved.clone());
    // Main comes back smaller, 640 x 480: now its pins are moved inward
    // until the whole frame is on it, (340, 280).
    h.ok(json!({"op":"remove_output","output":1}));
    h.ok(json!({"op":"register_output","stable_id":"main","screen_bounds":rect(200.0,100.0,640.0,480.0)}));
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(540.0,380.0,300.0,200.0)})
    );
    assert_eq!(h.pinned(2), moved);
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), CLEAN());
}

const SAVED_RULES: &str = r#"
[session]
restore_windows = true

[[window_rules]]
app_id = "app.widget"
widget = true
position = [0, -600]
"#;

/// A session with a canvas window (1), a widget (2), a window pinned to main
/// (3) and one pinned to side (4), saved after main's camera moved to (50, 0).
fn saved_session(scratch: &Scratch) -> PathBuf {
    let mut h = running(scratch, SAVED_RULES);
    put(&mut h, 1, "app.a", "A", rect(300.0, 275.0, 400.0, 300.0));
    appear(&mut h, 2, "app.widget", "W", (200.0, 100.0));
    assert_eq!(h.world(2), rect(-100.0, 550.0, 200.0, 100.0));
    put(&mut h, 3, "app.p", "P", rect(400.0, 300.0, 200.0, 200.0));
    h.observe_focus(3);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    put(&mut h, 4, "app.q", "Q", rect(10100.0, 100.0, 300.0, 200.0));
    h.observe_focus(4);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    // The widget is moved for the session, and holds the focus at the save.
    h.wrote(json!({"Move":{"window":2,"to":[0,0]}}));
    h.read(json!({"Opacity":{"window":1,"value":0.5}}));
    h.observe_focus(2);
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(50.0,0.0)}));
    let path = scratch.path("scene.json");
    h.ok(json!({"op":"save","path":path}));
    path
}

#[test]
fn a_save_keeps_pins_with_their_slots_and_never_holds_a_widget() {
    let scratch = Scratch::new();
    let scene = saved_session(&scratch);
    let saved: Value = serde_json::from_slice(&std::fs::read(&scene).unwrap()).unwrap();
    // Upstream: widgets never enter the session store. Nothing of the widget
    // is in the file, and the focus it held is not handed to another window.
    let ids: Vec<_> = saved["scene"]["windows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["id"].clone())
        .collect();
    assert_eq!(ids, vec![json!(1), json!(3), json!(4)]);
    let mut titled: Vec<_> = saved["metadata"].as_object().unwrap().keys().collect();
    titled.sort();
    assert_eq!(titled, ["1", "3", "4"]);
    assert_eq!(saved["scene"]["focused"], Value::Null);
    // A pinned window's slot keeps its pin, and the canvas frame the pin
    // showed: main's camera was at (50, 0).
    assert_eq!(
        saved["pins"],
        json!({"3":{"output":1,"screen_pos":[400,300]},"4":{"output":2,"screen_pos":[100,100]}})
    );
    assert_eq!(
        saved["scene"]["windows"][1]["world_rect"],
        rect(450.0, 300.0, 200.0, 200.0)
    );
    // No rule, no opacity and no snapping state is saved.
    let mut keys: Vec<_> = saved.as_object().unwrap().keys().collect();
    keys.sort();
    // The bookmark registry is part of the file since v0.20 turned
    // `session.restore_bookmarks` on.
    assert_eq!(
        keys,
        [
            "bookmarks",
            "metadata",
            "next_output",
            "next_window",
            "outputs",
            "pins",
            "scene",
            "version"
        ]
    );
    let mut keys: Vec<_> = saved["scene"].as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(keys, ["bookmarks", "focused", "outputs", "windows"]);
    // A scene with neither widget nor pin writes no new field at all.
    let mut plain = running(&scratch, "");
    put(
        &mut plain,
        1,
        "app.a",
        "A",
        rect(300.0, 275.0, 400.0, 300.0),
    );
    let path = scratch.path("plain.json");
    plain.ok(json!({"op":"save","path":path}));
    let plain: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert!(plain.get("pins").is_none());

    // The next launch. Side connects first: the pin saved on main waits for
    // main instead of taking the first output.
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":scene}));
    side_output(&mut h);
    assert_eq!(h.pinned(3), json!({"output":1,"screen_rect":null}));
    assert_eq!(
        h.pinned(4),
        json!({"output":2,"screen_rect":rect(1400.0,200.0,300.0,200.0)})
    );
    assert_eq!(h.drawn(2), vec![(4, true, false)]);
    main_output(&mut h);
    assert_eq!(
        h.pinned(3),
        json!({"output":1,"screen_rect":rect(600.0,400.0,200.0,200.0)})
    );
    // The config of this launch now pins and places app.a by rule.
    load_config(
        &mut h,
        &scratch,
        &format!(
            "{SAVED_RULES}\n[[window_rules]]\napp_id = \"app.a\"\npinned_to_screen = true\nposition = [5000, 5000]\nopacity = 0.6\n"
        ),
    );
    // A window still open takes its slot back as it was: the pinned one is
    // pinned where it was, on a slot that is not in the focus history.
    assert_eq!(
        appear(&mut h, 31, "app.p", "P", (200.0, 200.0)),
        json!({"window":3,"adopted":true,"background":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(
        h.placement(1, 3)["screen_rect"],
        rect(600.0, 400.0, 200.0, 200.0)
    );
    assert_eq!(h.placement(1, 3)["pinned"], true);
    // As upstream's adopted window keeps its slot whatever its rule says of
    // position or pinning, and still carries the rule's other fields.
    assert_eq!(
        appear(&mut h, 32, "app.a", "A", (400.0, 300.0)),
        json!({"window":1,"adopted":true,"background":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.world(1), rect(300.0, 275.0, 400.0, 300.0));
    assert_eq!(h.pinned(1), Value::Null);
    assert_eq!(h.rule(1)["opacity"], 0.6);
    assert_eq!(h.rule(1)["pinned_to_screen"], true);
    // The widget has no slot: it maps again, by its rule, as a new window. The
    // position it was moved to by IPC lasted only for the session.
    assert_eq!(
        appear(&mut h, 33, "app.widget", "W", (200.0, 100.0)),
        json!({"window":5,"adopted":false,"background":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.world(5), rect(-100.0, 550.0, 200.0, 100.0));
    assert_eq!(h.window(5)["widget"], true);
    assert_eq!(h.stack(), vec![5, 1, 3, 4]);
    // Q closed while nobody was looking. `restore_windows` keeps its slot as
    // a stand-in, and a stand-in is never pinned: it is back on the canvas
    // where its pin showed it. Side's camera was restored (v0.20 turned
    // `session.restore_camera` on): (10000, 0), so its pin's screen point
    // shows world (10100, 100).
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[4],"dirty":true})
    );
    assert_eq!(h.pinned(4), Value::Null);
    assert_eq!(h.world(4), rect(10100.0, 100.0, 300.0, 200.0));
    assert_eq!(h.placement(2, 4)["pinned"], false);
    assert_eq!(
        h.placement(2, 4)["screen_rect"],
        rect(1400.0, 200.0, 300.0, 200.0)
    );
    assert_eq!(
        h.refused(json!({"Pin":{"window":4,"value":true}})),
        "stand-ins can't be pinned"
    );

    // Another launch, on which side never connects. Q is still open: its pin
    // waits through the discovery pass, then moves to the output that exists.
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":scene}));
    main_output(&mut h);
    load_config(&mut h, &scratch, SAVED_RULES);
    assert_eq!(
        appear(&mut h, 41, "app.q", "Q", (300.0, 200.0)),
        json!({"window":4,"adopted":true,"background":false,"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.pinned(4), json!({"output":2,"screen_rect":null}));
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[1,3],"dirty":true})
    );
    assert_eq!(
        h.pinned(4),
        json!({"output":1,"screen_rect":rect(300.0,200.0,300.0,200.0)})
    );
    assert_eq!(h.pinned(3), Value::Null);
    // Main's camera is restored (v0.20 default), so the stand-in is back on the
    // canvas at the world rectangle the save recorded for it.
    assert_eq!(h.world(3), rect(450.0, 300.0, 200.0, 200.0));

    // A pin that names a stand-in or an output the file does not hold is not
    // a save this build wrote: the load is refused.
    let mut broken = saved.clone();
    broken["pins"]["3"]["output"] = json!(9);
    let path = scratch.path("broken.json");
    std::fs::write(&path, serde_json::to_vec(&broken).unwrap()).unwrap();
    let mut h = Host::new();
    assert_eq!(
        h.error(json!({"op":"load","path":path})),
        "invalid saved pin"
    );
}

/// What `window` is drawn at on main: its placement's `opacity`, which must be
/// the `decoration.opacity` of that placement and of its window entry too.
fn drawn_opacity(h: &mut Host, window: u64) -> f64 {
    let placement = h.placement(1, window);
    let entry = h.window(window);
    assert_eq!(
        placement["opacity"], placement["decoration"]["opacity"],
        "{window}"
    );
    assert_eq!(
        placement["decoration"], entry["decoration"],
        "window {window}"
    );
    placement["opacity"].as_f64().unwrap()
}
const CROSSING_RULES: &str = r#"
[[window_rules]]
app_id = "app.widget"
widget = true
position = [1800, -1000]
border_width = 5

[[window_rules]]
title = "Picture-in-Picture"
pinned_to_screen = true
position = [300, -200]
opacity = 0.6
corner_radius = 3
"#;
fn crossing_config(opacity: f64, focused: f64, rules: &str) -> String {
    format!(
        "[decorations]\nborder_width = 2\nopacity = {opacity}\nopacity_focused = {focused}\n\
         [zoom]\nfit_padding = 40\n[session]\nsuspend_on_close = true\n{rules}"
    )
}

/// The policy of this file and the drawing description of RENDER.md, on one
/// frame: a widget, a rule-pinned window and an ordinary window on main, whose
/// origin is the global point (200, 100), at half the zoom. The layer each is
/// drawn in, the space its rectangle is in, and one opacity for both readers.
#[test]
fn a_widget_a_pinned_window_and_a_canvas_window_are_described_for_one_frame() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, &crossing_config(0.8, 0.9, CROSSING_RULES));
    // The launch file is not the built-in `[decorations]`: one revision.
    assert_eq!(h.snapshot()["render"]["revision"], 1);
    zoom_out(&mut h);
    put(&mut h, 1, "app.a", "A", rect(1100.0, 300.0, 400.0, 300.0));
    h.observe_focus(1);
    // Pinned by its rule on main, 1000 x 800: the 400 x 200 frame's center is
    // 300 right of and 200 below the output's center, so its top-left is the
    // local point (600, 500), the global point (800, 600). It takes the focus.
    appear(&mut h, 2, "app.video", "Picture-in-Picture", (400.0, 200.0));
    // The widget's center is the canvas point (1800, -1000), Y up: its
    // 200 x 100 frame is at (1700, 950).
    appear(&mut h, 3, "app.widget", "W", (200.0, 100.0));
    assert_eq!(h.focused(), 2);

    // Bottom to top, and the two flags the compositor picks a layer from.
    assert_eq!(
        h.drawn(1),
        vec![(3, false, true), (1, false, false), (2, true, false)]
    );
    assert_eq!(h.drawn(2), vec![]);
    // A canvas rectangle goes through the camera (1000, -200) at half the
    // zoom and lands after the output's origin: (world - camera) / 2 + origin.
    let widget = h.placement(1, 3);
    assert_eq!(
        json!([
            widget["kind"],
            widget["widget"],
            widget["pinned"],
            widget["focused"]
        ]),
        json!(["window", true, false, false])
    );
    assert_eq!(widget["world_rect"], rect(1700.0, 950.0, 200.0, 100.0));
    assert_eq!(widget["screen_rect"], rect(550.0, 675.0, 100.0, 50.0));
    assert_eq!(widget["decoration"]["border_width"], 5);
    let canvas = h.placement(1, 1);
    assert_eq!(
        json!([
            canvas["kind"],
            canvas["widget"],
            canvas["pinned"],
            canvas["focused"]
        ]),
        json!(["window", false, false, false])
    );
    assert_eq!(canvas["world_rect"], rect(1100.0, 300.0, 400.0, 300.0));
    assert_eq!(canvas["screen_rect"], rect(250.0, 350.0, 200.0, 150.0));
    assert_eq!(canvas["decoration"]["border_width"], 2);
    // The pinned placement's rectangle is its pin's: global screen points at
    // the window's own size, not half of it. Its world rectangle is the
    // canvas point that shows there, camera + (600, 500) / 0.5, and is not
    // what it is drawn from.
    let pinned = h.placement(1, 2);
    assert_eq!(
        json!([
            pinned["kind"],
            pinned["widget"],
            pinned["pinned"],
            pinned["focused"]
        ]),
        json!(["window", false, true, true])
    );
    assert_eq!(pinned["screen_rect"], rect(800.0, 600.0, 400.0, 200.0));
    assert_eq!(pinned["clip_rect"], rect(800.0, 600.0, 400.0, 200.0));
    assert_eq!(pinned["world_rect"], rect(2200.0, 800.0, 400.0, 200.0));
    assert_eq!(pinned["decoration"]["corner_radius"], 3);
    // The window list says the same of each, with the pin and the rule.
    assert_eq!(
        h.pinned(2),
        json!({"output":1,"screen_rect":rect(800.0,600.0,400.0,200.0)})
    );
    assert_eq!(h.window(2)["kind"], "window");
    assert_eq!(h.rule(2)["opacity"], 0.6);
    assert_eq!(h.window(3)["widget"], true);
    assert_eq!(h.pinned(3), Value::Null);
    assert_eq!(h.rule(1), Value::Null);
    // One opacity for both readers: a widget's opaque default, the unfocused
    // default, a rule's value on the focused window.
    assert_eq!(drawn_opacity(&mut h, 3), 1.0);
    assert_eq!(drawn_opacity(&mut h, 1), 0.8);
    assert_eq!(drawn_opacity(&mut h, 2), 0.6);

    // A window retitled into the pin rule is drawn as it was: the decoration
    // is the rule it mapped with, not one matched again at the snapshot.
    let before = h.placement(1, 1);
    let renamed = identity(1);
    assert_eq!(
        h.ok(json!({"op":"retitle","window":1,"identity":renamed,"title":"Picture-in-Picture"})),
        json!({"dirty":true})
    );
    let after = h.placement(1, 1);
    assert_eq!(after["title"], "Picture-in-Picture");
    assert_eq!(after["decoration"], before["decoration"]);
    assert_eq!(after["pinned"], false);
    assert_eq!(drawn_opacity(&mut h, 1), 0.8);

    // The camera moves the canvas under the pin. Pan by (100, 0) on screen:
    // the camera is (1200, -200). Then a quarter of the zoom about the
    // output's origin, which leaves the camera there.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(100.0,0.0)}));
    assert_eq!(
        h.placement(1, 2)["screen_rect"],
        rect(800.0, 600.0, 400.0, 200.0)
    );
    assert_eq!(
        h.placement(1, 2)["world_rect"],
        rect(2400.0, 800.0, 400.0, 200.0)
    );
    assert_eq!(
        h.placement(1, 1)["screen_rect"],
        rect(150.0, 350.0, 200.0, 150.0)
    );
    assert_eq!(
        h.placement(1, 3)["screen_rect"],
        rect(450.0, 675.0, 100.0, 50.0)
    );
    h.ok(json!({"op":"zoom","output":1,"zoom":0.25,"anchor":point(200.0,100.0)}));
    assert_eq!(h.snapshot()["outputs"][0]["camera"], point(1200.0, -200.0));
    assert_eq!(
        h.placement(1, 2)["screen_rect"],
        rect(800.0, 600.0, 400.0, 200.0)
    );
    assert_eq!(
        h.placement(1, 2)["world_rect"],
        rect(3600.0, 1800.0, 400.0, 200.0)
    );
    assert_eq!(
        h.placement(1, 1)["screen_rect"],
        rect(175.0, 225.0, 100.0, 75.0)
    );
    assert_eq!(
        h.placement(1, 3)["screen_rect"],
        rect(325.0, 387.5, 50.0, 25.0)
    );
    assert_eq!(
        h.drawn(1),
        vec![(3, false, true), (1, false, false), (2, true, false)]
    );

    // A reload of `[decorations] opacity` spends a render revision and
    // changes what the unruled window is drawn at, in both keys. The file's
    // rules are gone and nothing mapped is matched again: the widget, the pin
    // and what each rule decorated stay.
    load_config(&mut h, &scratch, &crossing_config(0.5, 0.7, ""));
    assert_eq!(h.snapshot()["render"]["revision"], 2);
    assert_eq!(drawn_opacity(&mut h, 1), 0.5);
    assert_eq!(drawn_opacity(&mut h, 2), 0.6);
    assert_eq!(drawn_opacity(&mut h, 3), 1.0);
    assert_eq!(h.placement(1, 3)["decoration"]["border_width"], 5);
    assert_eq!(h.placement(1, 2)["decoration"]["corner_radius"], 3);
    assert_eq!(
        h.drawn(1),
        vec![(3, false, true), (1, false, false), (2, true, false)]
    );

    // An IPC `Opacity` write is the same source: both keys follow it, for the
    // canvas window, the widget and the pinned window alike.
    for (window, value) in [(1, 0.25), (3, 0.5), (2, 0.3)] {
        assert_eq!(
            h.read(json!({"Opacity":{"window":window,"value":value}})),
            json!({"Opacity":value})
        );
        assert_eq!(drawn_opacity(&mut h, window), value, "{window}");
    }
    // A `Window` capture takes it from there too, and frames the pinned
    // window at its canvas frame: the frame, a border of 2 and upstream's
    // shadow radius of 14 on every side.
    let shot = |h: &mut Host, target: Value| {
        let data = h.ipc(
            json!({"Screenshot":{"target":target,"scale":1.0,"path":"/nonexistent/infinify-rules-flow/shot.png"}}),
        );
        assert_eq!(data["reply"], Value::Null, "{data}");
        data["effects"][0].clone()
    };
    let alone = shot(&mut h, json!({"Window":{"window":2}}));
    assert_eq!(
        alone["target"],
        json!({"Window":{"window":2,"world_rect":rect(3600.0,1800.0,400.0,200.0),"opacity":0.3}})
    );
    assert_eq!(alone["region"], rect(3584.0, 1784.0, 432.0, 232.0));
    // `All` frames the canvas windows, as upstream's does: neither the widget
    // nor the pinned window. The one canvas frame, grown by 16 and then by
    // `fit_padding`.
    let all = shot(&mut h, json!("All"));
    assert_eq!(all["region"], rect(1044.0, 244.0, 512.0, 412.0));

    // The pinned window closes and leaves a stand-in: back on the canvas
    // where its pin showed it, in no layer of its own, under no rule and
    // opaque in both keys, whatever its rule and the write said.
    assert_eq!(h.closed(2)["standin"], true);
    let standin = h.placement(1, 2);
    assert_eq!(
        json!([standin["kind"], standin["widget"], standin["pinned"]]),
        json!(["standin", false, false])
    );
    assert_eq!(standin["screen_rect"], rect(800.0, 600.0, 100.0, 50.0));
    assert_eq!(standin["decoration"]["corner_radius"], 10);
    assert_eq!(standin["decoration"]["border_width"], 2);
    assert_eq!(drawn_opacity(&mut h, 2), 1.0);
    assert_eq!(h.rule(2), Value::Null);
    assert_eq!(h.pinned(2), Value::Null);
}

/// Main at zoom 1 with its camera at the origin, so a global point is a world
/// point plus (200, 100). A holds the usable center (500, 425) ten points left
/// of its own; B is far to the right, off screen; the widget lies between
/// them and hangs off the output's right edge; the pinned window lies over
/// A's right part. The history is A, then B.
fn mixed_layers(scratch: &Scratch, extra: &str) -> Host {
    let toml = format!("[[window_rules]]\napp_id = \"app.widget\"\nwidget = true\n{extra}");
    let mut h = running(scratch, &toml);
    put(&mut h, 1, "app.a", "A", rect(310.0, 275.0, 400.0, 300.0));
    put(&mut h, 2, "app.b", "B", rect(1500.0, 325.0, 300.0, 200.0));
    put(
        &mut h,
        3,
        "app.widget",
        "W",
        rect(900.0, 150.0, 150.0, 100.0),
    );
    put(&mut h, 4, "app.c", "PiP", rect(600.0, 400.0, 150.0, 100.0));
    h.observe_focus(4);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    h.observe_focus(2);
    h.observe_focus(1);
    assert_eq!(h.window(3)["widget"], true);
    assert_eq!(
        h.pinned(4),
        json!({"output":1,"screen_rect":rect(800.0,500.0,150.0,100.0)})
    );
    assert_eq!(h.history(), json!([1, 2]));
    h
}
/// Global points of `mixed_layers`: on the pinned window where it covers A,
/// on the widget alone, and on A alone.
const ON_PIN: (f64, f64) = (850.0, 550.0);
const ON_WIDGET: (f64, f64) = (1150.0, 300.0);
const ON_A: (f64, f64) = (600.0, 450.0);

#[test]
fn window_navigation_and_activation_take_canvas_windows_only() {
    let scratch = Scratch::new();
    let mut h = mixed_layers(&scratch, "\n[navigation]\nauto_navigate_on_click = true\n");
    let focus_of = |reply: &Value| reply["effects"][0]["window"].clone();

    // center-nearest right of A: the widget's nearest point is 427 away and
    // B's 990. The widget is no candidate, nor is the pinned window.
    let reply = h.action("center-nearest right");
    assert_eq!(focus_of(&reply), 2, "{reply}");
    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
    assert_eq!(h.focused(), 2);
    // center-window with a widget focused centers the canvas window nearest
    // the viewport center, as with nothing focused: A.
    h.observe_focus(3);
    let reply = h.action("center-window");
    assert_eq!(focus_of(&reply), 1, "{reply}");
    assert_eq!(h.focused(), 1);
    // center-nearest does not anchor on a focused pinned window: the search
    // starts at the viewport center, which A holds. Anchored on the pinned
    // window it would have found B. The search is made from where the view
    // lands (v0.20), so the flight the center-window above armed is dropped
    // first: landing, it would put A's own center on the viewport center,
    // where a window has no direction.
    h.ok(json!({"op":"cancel_navigation","output":1}));
    h.observe_focus(4);
    let reply = h.action("center-nearest right");
    assert_eq!(focus_of(&reply), 1, "{reply}");
    // cycle-windows from a focused widget goes to the head of the history,
    // which holds neither the widget nor the pinned window.
    h.observe_focus(3);
    let reply = h.action("cycle-windows forward");
    assert_eq!(focus_of(&reply), 1, "{reply}");
    h.settle_focus();
    assert_eq!(h.history(), json!([1, 2]));
    let reply = h.action("cycle-windows forward");
    assert_eq!(focus_of(&reply), 2, "{reply}");
    h.settle_focus();
    assert_eq!(h.history(), json!([2, 1]));

    // focus-center over a pinned window focuses the pin and leaves the view
    // where it is (v0.20, "Navigation"; upstream passed over the pin to the
    // canvas window it covers). It takes no widget: with no canvas window
    // under the pointer it is center-window, which flies to A.
    assert_eq!(h.hit(1, ON_PIN.0, ON_PIN.1)["window"], 4);
    let centre = |h: &mut Host, at: (f64, f64)| {
        h.ok(json!({"op":"action","output":1,"action":"focus-center","pointer":point(at.0, at.1)}))
    };
    let reply = centre(&mut h, ON_PIN);
    assert_eq!(focus_of(&reply), 4, "{reply}");
    assert_eq!(reply["navigation"], Value::Null, "{reply}");
    assert_eq!(h.focused(), 4);
    assert_eq!(h.hit(1, ON_WIDGET.0, ON_WIDGET.1)["window"], 3);
    let reply = centre(&mut h, ON_WIDGET);
    assert_eq!(focus_of(&reply), 1, "{reply}");
    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
    assert_eq!(h.focused(), 1);

    // A press focuses a widget or a pinned window and asks for native focus;
    // the answer puts neither in the history.
    let activate = |h: &mut Host, window: u64, cause: &str| {
        h.ok(json!({"op":"activate","window":window,"output":1,"cause":cause}))
    };
    for window in [3, 4] {
        let reply = activate(&mut h, window, "click");
        assert_eq!(reply["effect"]["window"], window, "{reply}");
        assert_eq!(reply["navigation"], Value::Null, "{reply}");
        assert_eq!(h.focused(), window);
        h.settle_focus();
        assert_eq!(h.history(), json!([2, 1]));
        // The completed click flies nowhere, though the widget is clipped by
        // the output's edge and `auto_navigate_on_click` is on.
        assert_eq!(
            activate(&mut h, window, "click_release"),
            json!({"navigation":null,"dirty":false})
        );
    }
    // Control: the same click on a clipped canvas window does fly.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(400.0,0.0)}));
    activate(&mut h, 1, "click");
    let reply = activate(&mut h, 1, "click_release");
    assert_eq!(reply["navigation"]["animating"], true, "{reply}");
    h.ok(json!({"op":"cancel_navigation","output":1}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(-400.0,0.0)}));
    // Native focus observed on the clipped widget: focused where it is, out
    // of the history, and no camera moves.
    h.observe_focus(1);
    assert_eq!(
        activate(&mut h, 3, "native"),
        json!({"effect":null,"navigation":null,"dirty":true})
    );
    assert_eq!(h.focused(), 3);
    assert_eq!(h.history(), json!([1, 2]));
    // navigate_window raises and focuses either without a flight.
    for window in [3, 4] {
        let reply =
            h.ok(json!({"op":"navigate_window","window":window,"output":1,"zoom_policy":"keep"}));
        assert_eq!(reply["effect"]["window"], window, "{reply}");
        assert_eq!(reply["navigation"], Value::Null, "{reply}");
    }
    assert_eq!(h.snapshot()["outputs"][0]["camera"], point(0.0, 0.0));
    // A widget is never above a window, whatever was focused.
    assert_eq!(h.drawn(1)[0], (3, false, true));
    assert_eq!(h.drawn(1).last(), Some(&(4, true, false)));
}

#[test]
fn send_to_output_rebinds_a_pin_and_leaves_a_widget() {
    let scratch = Scratch::new();
    let mut h = mixed_layers(&scratch, "");
    // A focused widget stays where it is.
    h.observe_focus(3);
    let before = h.snapshot();
    assert_eq!(h.action("send-to-output right"), IDLE());
    assert_eq!(h.snapshot(), before);
    // A focused pinned window keeps its place on the screen and changes
    // output: side is 800 x 600 at (1300, 100), and the whole 150 x 100 frame
    // fits there at the local point (600, 400).
    h.observe_focus(4);
    assert_eq!(h.action("send-to-output right"), CHANGED());
    assert_eq!(
        h.pinned(4),
        json!({"output":2,"screen_rect":rect(1900.0,500.0,150.0,100.0)})
    );
    assert_eq!(h.drawn(2), vec![(4, true, false)]);
    assert_eq!(h.focused(), 4);
    assert_eq!(h.history(), json!([1, 2]));
    // No output lies further right.
    assert_eq!(h.action("send-to-output right"), IDLE());
    assert_eq!(h.action("send-to-output left"), CHANGED());
    assert_eq!(
        h.pinned(4),
        json!({"output":1,"screen_rect":rect(800.0,500.0,150.0,100.0)})
    );
    // The event stream's State lists it under `pinned` and marks the widget.
    let line = h.ok(json!({"op":"state_event","output":1}))["line"].clone();
    let state: Value = serde_json::from_str(line.as_str().unwrap()).unwrap();
    let state = &state["State"];
    assert_eq!(state["pinned"][0]["id"], 4, "{state}");
    assert_eq!(state["pinned"][0]["output"], "main");
    let listed: Vec<(u64, bool)> = state["windows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| (w["id"].as_u64().unwrap(), w["is_widget"].as_bool().unwrap()))
        .collect();
    assert_eq!(listed, vec![(3, true), (2, false), (1, false)]);
}

#[test]
fn trackpad_gestures_grab_no_widget_and_move_a_pinned_window_in_screen_space() {
    let scratch = Scratch::new();
    let mut h = mixed_layers(
        &scratch,
        "\n[[window_rules]]\ntitle = \"Clock\"\nwidget = true\n[gestures.on-window]\n\"3-finger-doubletap-swipe\" = \"move-window\"\n",
    );
    let begin = |h: &mut Host, at: (f64, f64), option: bool, doubletap: bool| {
        h.ok(json!({"op":"gesture_begin","kind":"swipe","fingers":3,"modifiers":{"control":false,"option":option,"shift":false,"command":false},"context":"window","output":1,"pointer":point(at.0, at.1),"doubletap":doubletap,"time_ms":1000}))
    };
    let swipe = |h: &mut Host, dx: f64| {
        h.ok(json!({"op":"gesture_update","dx":dx,"dy":0.0,"time_ms":1010}))
    };
    let end = |h: &mut Host| h.ok(json!({"op":"gesture_end","cancelled":false,"time_ms":1020}));
    let before = h.snapshot();

    // A move over a widget grabs nothing and falls back to the plain swipe,
    // as upstream's does: nothing is focused or raised.
    let reply = begin(&mut h, ON_WIDGET, false, true);
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(reply["effects"], json!([]), "{reply}");
    assert_eq!(reply["note"], Value::Null);
    end(&mut h);
    // So does a resize over a widget.
    let reply = begin(&mut h, ON_WIDGET, true, false);
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(reply["note"], Value::Null);
    end(&mut h);
    assert_eq!(h.snapshot()["windows"], before["windows"]);
    assert_eq!(h.focused(), 1);

    // A move over a pinned window is upstream's GestureTarget::Pinned: the
    // pinned drag a bound press installs, then the window raised and
    // focused. It moves by the fingers' screen displacement, on its output,
    // and no camera pans.
    let camera = h.snapshot()["outputs"][0].clone();
    let reply = begin(&mut h, ON_PIN, false, true);
    assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
    assert_eq!(reply["gesture"]["window"], 4);
    assert_eq!(reply["note"], Value::Null);
    assert_eq!(reply["effects"][0]["op"], "focus_native_window", "{reply}");
    assert_eq!(reply["effects"][0]["window"], 4, "{reply}");
    assert_eq!(h.focused(), 4);
    assert_eq!(h.stack().last(), Some(&4));
    // It takes the focus without entering the history, as a click on it does.
    h.settle_focus();
    assert_eq!(h.history(), json!([1, 2]));
    assert_eq!(swipe(&mut h, 40.0)["needs_frames"], false);
    assert_eq!(
        h.pinned(4),
        json!({"output":1,"screen_rect":rect(840.0,500.0,150.0,100.0)})
    );
    // The pointer path cannot begin a drag of its own under it.
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":1,"output":1})),
        "gesture already active"
    );
    let reply = end(&mut h);
    assert_eq!(reply["dirty"], true, "{reply}");
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(50.0, 0.0)})),
        "no active gesture"
    );
    assert_eq!(h.pinned(4)["screen_rect"], rect(840.0, 500.0, 150.0, 100.0));
    assert_eq!(h.snapshot()["outputs"][0], camera);
    let before = h.snapshot();
    // This host has no resize capability. A resize gesture falls back to pan.
    let reply = begin(&mut h, ON_PIN, true, false);
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(reply["note"], Value::Null);
    end(&mut h);
    assert_eq!(h.snapshot(), before);
    h.observe_focus(1);
    // Control: the same move over a canvas window grabs it.
    let reply = begin(&mut h, ON_A, false, true);
    assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
    assert_eq!(reply["gesture"]["window"], 1);
    swipe(&mut h, 40.0);
    assert_eq!(h.world(1), rect(350.0, 275.0, 400.0, 300.0));
    end(&mut h);

    // A detached slot is moved by a gesture, and its window comes back under
    // a title a widget rule matches: the gesture lets go of it there.
    let slot = put(
        &mut h,
        7,
        "app.late",
        "Loading",
        rect(100.0, 600.0, 200.0, 150.0),
    );
    let gone = h.window(slot)["source"]["identity"].clone();
    h.ok(json!({"op":"remove_source","window":slot,"identity":gone,"keep_placeholder":true}));
    let reply = begin(&mut h, (400.0, 775.0), false, true);
    assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
    assert_eq!(reply["gesture"]["window"], slot);
    swipe(&mut h, 10.0);
    assert_eq!(h.world(slot), rect(110.0, 600.0, 200.0, 150.0));
    let back = appear(&mut h, 8, "app.late", "Clock", (200.0, 150.0));
    assert_eq!(
        (&back["window"], &back["adopted"]),
        (&json!(slot), &json!(true))
    );
    assert_eq!(h.window(slot)["widget"], true);
    swipe(&mut h, 50.0);
    assert_eq!(h.world(slot), rect(110.0, 600.0, 200.0, 150.0));
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(50.0, 0.0)})),
        "no active gesture"
    );
    end(&mut h);
    assert_eq!(h.snapshot()["trackpad"]["gesture"], Value::Null);
}

#[test]
fn the_pin_and_bookmark_actions_run_through_the_action_prelude() {
    let scratch = Scratch::new();
    let mut h = mixed_layers(
        &scratch,
        "\n[[outputs]]\nname = \"*\"\n[outputs.hot_corners]\ntop_left = \"toggle-pin-to-screen\"\ntop_right = \"move-to-bookmark lab\"\n",
    );
    let cycle = |h: &mut Host| h.snapshot()["focus"]["cycle"].clone();
    let coasting = |h: &mut Host| h.snapshot()["navigation"]["momentum"]["1"]["coasting"].clone();
    let step = json!({"op":"action","output":1,"action":"cycle-windows forward","held":true});
    // Both are ordinary actions: each ends an open cycle before it runs.
    h.ok(step.clone());
    assert_eq!(cycle(&mut h), 1);
    assert_eq!(h.focused(), 2);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(cycle(&mut h), Value::Null);
    // B's center is on no output: the pin takes the active one.
    assert_eq!(h.pinned(2)["output"], 1);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(h.pinned(2), Value::Null);
    h.observe_focus(2);
    h.observe_focus(1);
    h.ok(step);
    assert_eq!(cycle(&mut h), 1);
    assert_eq!(h.action("move-to-bookmark nowhere"), IDLE());
    assert_eq!(cycle(&mut h), Value::Null);
    // And each stops its output's scroll momentum.
    for action in ["toggle-pin-to-screen", "move-to-bookmark nowhere"] {
        for step in 1..=6 {
            h.ok(json!({"op":"pan","output":1,"screen_delta":point(-20.0,0.0),"time_ms":1000 + step * 8,"source":"finger"}));
        }
        h.ok(json!({"op":"pan_end","output":1,"time_ms":1056}));
        assert_eq!(coasting(&mut h), true, "{action}");
        h.action(action);
        assert_eq!(coasting(&mut h), false, "{action}");
    }
    // A hot corner runs them like any other action.
    h.ipc(json!({"Bookmark":{"name":"lab","to":[0.0,0.0]}}));
    h.observe_focus(1);
    assert_eq!(h.pinned(1), Value::Null);
    assert_eq!(
        h.ok(json!({"op":"hot_corner","output":1,"corner":"top_left"})),
        CHANGED()
    );
    assert!(!h.pinned(1).is_null());
    assert_eq!(
        h.ok(json!({"op":"hot_corner","output":1,"corner":"top_left"})),
        CHANGED()
    );
    assert_eq!(h.pinned(1), Value::Null);
    assert_eq!(
        h.ok(json!({"op":"hot_corner","output":1,"corner":"top_right"})),
        CHANGED()
    );
    let center = h.world(1);
    assert_eq!(center["origin"], point(-200.0, -150.0));
    // Upstream's default binding of the pin toggle is one that runs.
    let keys = h.ok(json!({"op":"bindings"}))["keys"].clone();
    let bound: Vec<&Value> = keys
        .as_array()
        .unwrap()
        .iter()
        .filter(|key| key["action"] == "toggle-pin-to-screen")
        .collect();
    assert_eq!(bound.len(), 1, "{keys}");
    assert_eq!(bound[0]["implemented"], true, "{keys}");
}

// Upstream's `preserve_aspect_ratio` (locked_ratio_for, constrain_to_ratio)
// on the readback path of a normal run: the ratio is the one the window has
// when a grab begins, an edge drives its own axis, and neither a snap nor a
// cluster takes part. Output 1 is at the global point (200, 100) with its
// camera at the world origin, so the screen point (510, 450) is the world
// point (310, 350): the left third of the window, in its middle row.
#[test]
fn preserve_aspect_ratio_bends_a_resize_grab_from_an_edge_and_drops_its_cluster() {
    let scratch = Scratch::new();
    let mut h = running(
        &scratch,
        "[[window_rules]]\napp_id = \"app.ratio\"\npreserve_aspect_ratio = true\n",
    );
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    let window = put(
        &mut h,
        1,
        "app.ratio",
        "R",
        rect(300.0, 200.0, 400.0, 300.0),
    );
    // A window a snap gap to the left, which a cluster resize would carry.
    let other = put(&mut h, 2, "app.plain", "P", rect(88.0, 200.0, 200.0, 300.0));
    assert_eq!(h.rule(window)["preserve_aspect_ratio"], true);
    assert_eq!(h.rule(window)["not_applied"], json!([]));
    // The left edge, 60 points to the left: 460 wide, and 460 * 300 / 400
    // high. The right edge stays; the height grows downwards, as upstream's.
    let begun = h.ok(json!({"op":"begin_native_resize","window":window,"output":1,"start_screen":point(510.0,450.0),"group":true}));
    let read = begun["effect"].clone();
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["edges"], "left", "{slot}");
    assert_eq!(slot["group"], false, "{slot}");
    resized(&mut h, &read, "observed", false, (400.0, 300.0));
    let moved = h.ok(json!({"op":"native_resize_to","transaction":read["transaction"],"screen":point(450.0,600.0)}));
    let setter = moved["effect"].clone();
    assert_eq!(
        setter["requested"],
        json!({"width":460.0,"height":345.0}),
        "{moved}"
    );
    assert_eq!(
        h.snapshot()["native_resize"]["requested_outline"],
        rect(240.0, 200.0, 460.0, 345.0)
    );
    resized(&mut h, &setter, "applied", true, (460.0, 345.0));
    let end = h.ok(json!({"op":"end_native_resize","transaction":read["transaction"]}));
    resized(&mut h, &end["effect"], "observed", false, (460.0, 345.0));
    assert_eq!(h.world(window), rect(240.0, 200.0, 460.0, 345.0));
    // The neighbour was not carried, and the edge was not snapped to it.
    assert_eq!(h.world(other), rect(88.0, 200.0, 200.0, 300.0));
    // The next grab takes the ratio the window has by then, still 4:3. A
    // corner: 30 right and 90 down, the height moved farther relative to the
    // ratio (30 * 345 < 90 * 460), so it drives: 435 high, 435 * 4 / 3 wide.
    let begun = h.ok(json!({"op":"begin_native_resize","window":window,"output":1,"edges":"bottom_right","start_screen":point(900.0,645.0)}));
    let read = begun["effect"].clone();
    resized(&mut h, &read, "observed", false, (460.0, 345.0));
    let moved = h.ok(json!({"op":"native_resize_to","transaction":read["transaction"],"screen":point(930.0,735.0)}));
    assert_eq!(
        moved["effect"]["requested"],
        json!({"width":580.0,"height":435.0}),
        "{moved}"
    );
}
