// SPDX-License-Identifier: GPL-3.0-or-later
//! `pass_keys`, `pass_mouse` and the screen-space drag of a pinned window, by
//! the move binding and by the move gesture, cross the exported C ABI and JSON
//! decoder with synthetic observations. The pass scenarios follow upstream's
//! `src/tests/pass_mouse.rs` and the decision in `src/input/keyboard.rs`;
//! every expected rectangle is derived by hand, not read back from the
//! controller. They show which bindings the controller withholds and where it
//! puts a pin. They provide no evidence that a key or a press reaches a
//! native application.
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
    /// A refused IPC request: an `Err` reply, and nothing changed.
    fn refused(&mut self, request: Value) -> String {
        let before = self.snapshot();
        let data = self.ok(json!({"op":"ipc","output":1,"request":request}));
        assert_eq!(self.snapshot(), before, "{request}");
        data["reply"]["Err"].as_str().unwrap().to_owned()
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
    /// What `output` draws, bottom to top.
    fn drawn(&mut self, output: u64) -> Vec<u64> {
        self.snapshot()["placements"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|p| p["output"] == output)
            .map(|p| p["window"].as_u64().unwrap())
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
        self.snapshot()["focused"].clone()
    }
    fn pass_keys(&mut self) -> Value {
        self.snapshot()["pass_keys"].clone()
    }
    fn pending(&mut self) -> Value {
        let effect = self.snapshot()["focus"]["pending_effect"].clone();
        assert_eq!(effect["op"], "focus_native_window", "{effect}");
        effect
    }
    /// Answer the pending focus request as an adapter that performs no native
    /// focus does.
    fn settle_focus(&mut self) {
        let effect = self.pending();
        self.ok(json!({"op":"focus_logical","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"]}));
    }
    /// Answer the pending focus request as an adapter that tried.
    fn answer_focus(&mut self, success: bool) {
        let effect = self.pending();
        self.ok(json!({"op":"focus_result","effect_id":effect["effect_id"],"window":effect["window"],"identity":effect["identity"],"generation":effect["generation"],"success":success}));
    }
    /// Report native focus on a bound window: logical focus, raise and history.
    fn observe_focus(&mut self, id: u64) {
        let source = self.window(id)["source"].clone();
        self.ok(json!({"op":"observe_focus","window":id,"identity":source["identity"],"generation":source["generation"]}));
    }
    fn closed(&mut self, id: u64) -> Value {
        let identity = self.window(id)["source"]["identity"].clone();
        self.ok(json!({"op":"window_closed","window":id,"identity":identity,"output":1}))
    }
    fn retitle(&mut self, id: u64, title: &str) {
        let identity = self.window(id)["source"]["identity"].clone();
        self.ok(json!({"op":"retitle","window":id,"identity":identity,"title":title}));
    }
    /// The window `hit` finds under a global screen point of `output`.
    fn hit(&mut self, output: u64, x: f64, y: f64) -> Value {
        self.ok(json!({"op":"hit","output":output,"screen":point(x, y)}))["hit"]["window"].clone()
    }
    /// The whole reply of the lookup the shell makes for a press or a scroll,
    /// with the window under the pointer.
    fn mouse(
        &mut self,
        trigger: &str,
        source: Value,
        modifiers: &str,
        context: &str,
        window: Value,
    ) -> Value {
        self.ok(json!({"op":"mouse_binding","trigger":trigger,"source":source,"modifiers":chord(modifiers),"context":context,"window":window}))
    }
    /// A button press over `window`: the reply, which must be the reply the
    /// same lookup gives with no window whenever nothing is claimed.
    fn press(&mut self, trigger: &str, modifiers: &str, window: u64) -> Value {
        self.over(trigger, Value::Null, modifiers, window)
    }
    fn scroll(&mut self, source: &str, modifiers: &str, window: u64) -> Value {
        self.over("scroll", json!(source), modifiers, window)
    }
    fn over(&mut self, trigger: &str, source: Value, modifiers: &str, window: u64) -> Value {
        let reply = self.mouse(trigger, source.clone(), modifiers, "window", json!(window));
        if reply != PASSED() {
            let plain = self.ok(json!({"op":"mouse_binding","trigger":trigger,"source":source,"modifiers":chord(modifiers),"context":"window"}));
            assert_eq!(reply, plain, "an unclaimed lookup is today's reply");
            assert!(reply.get("passed").is_none(), "{reply}");
        }
        reply
    }
    /// The lookup over a pick target: `hit` said `pick` of this window.
    fn picked(&mut self, trigger: &str, source: Value, modifiers: &str, window: u64) -> Value {
        self.ok(json!({"op":"mouse_binding","trigger":trigger,"source":source,"modifiers":chord(modifiers),"context":"window","window":window,"pick":true}))
    }
    /// Pointer motion with no button down, at a global point of main.
    fn hover(&mut self, x: f64, y: f64) -> Value {
        self.ok(json!({"op":"hover","output":1,"screen":point(x, y)}))
    }
    /// The adapter saw native focus on a bound window by itself.
    fn native(&mut self, id: u64) -> Value {
        let source = self.window(id)["source"].clone();
        self.ok(json!({"op":"activate","window":id,"output":1,"cause":"native","identity":source["identity"],"generation":source["generation"]}))
    }
    fn history(&mut self) -> Value {
        self.snapshot()["focus"]["history"].clone()
    }
    /// The window events logged so far, oldest first.
    fn events(&mut self) -> Vec<(u64, String)> {
        self.snapshot()["lifecycle_events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| {
                (
                    e["window"].as_u64().unwrap(),
                    e["event"].as_str().unwrap().to_owned(),
                )
            })
            .collect()
    }
    /// The key bindings of the `bindings` reply.
    fn keys(&mut self) -> Vec<Value> {
        self.ok(json!({"op":"bindings"}))["keys"]
            .as_array()
            .unwrap()
            .clone()
    }
    fn drag_to(&mut self, delta: (f64, f64), pointer: Option<(f64, f64)>) -> Value {
        let pointer = pointer.map(|(x, y)| point(x, y));
        self.ok(json!({"op":"gesture_to","screen_delta":point(delta.0, delta.1),"pointer":pointer}))
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
            "infinify-passthrough-flow-{}-{}",
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
fn chord(glyphs: &str) -> Value {
    json!({"control":glyphs.contains('⌃'),"option":glyphs.contains('⌥'),"shift":glyphs.contains('⇧'),"command":glyphs.contains('⌘')})
}
fn identity(wid: u64) -> Value {
    json!({"pid":4242,"birth_sec":1800000000,"birth_usec":77,"wid":wid,"owner":null})
}
/// Where every fixture's native window sits on the desktop. No world or pinned
/// position may ever derive from it.
const NATIVE: (f64, f64) = (4000.0, 3000.0);

/// Two outputs, neither at the global origin. Output 1, `main`, is 1000 x 800
/// at the global point (200, 100), with a 50-point bar at the top. Output 2,
/// `side`, is 800 x 600 at the global point (1300, 100), and its camera is
/// parked at (10000, 0), so it shows nothing main shows.
fn main_output(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"main","screen_bounds":rect(200.0,100.0,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,50.0,1000.0,750.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
}
fn side_output(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"side","screen_bounds":rect(1300.0,100.0,800.0,600.0)}));
}
fn load_config(h: &mut Host, scratch: &Scratch, toml: &str) {
    let path = scratch.path("config.toml");
    std::fs::write(&path, toml).unwrap();
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(reply["warnings"], json!([]), "{reply}");
}
/// Both outputs, the given config file, and the launch pass already over.
fn running(scratch: &Scratch, toml: &str) -> Host {
    let mut h = Host::new();
    main_output(&mut h);
    side_output(&mut h);
    h.ok(json!({"op":"pan","output":2,"screen_delta":point(10000.0,0.0)}));
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
/// A window that appeared by itself: its rules place it.
fn appear(h: &mut Host, wid: u64, app: &str, title: &str, size: (f64, f64)) -> Value {
    h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":title,"buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,size.0,size.1),"output":1,"pointer":point(700.0,500.0)}))
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
    reply["window"].as_u64().unwrap()
}
/// Pin a window where it shows right now.
fn pin(h: &mut Host, id: u64) {
    h.observe_focus(id);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
}
const CHANGED: fn() -> Value = || json!({"navigation":null,"effects":[],"dirty":true});
/// What a claimed lookup answers.
const PASSED: fn() -> Value = || json!({"binding":null,"passed":true});
const UNBOUND: fn() -> Value = || json!({"binding":null});
const UNDER_A_GESTURE: &str = "a window is under an interactive move or resize";
const BY_HAND: &str = "a screen-pinned window is not moved or resized by hand";

const PASS_KEYS: &str = r#"
[keybindings]
"ctrl+q" = "zoom-in"
"mod+Escape" = "home-toggle"
"ctrl+shift+x" = "quit"
"XF86AudioPlay" = "zoom-in"
"XF86AudioNext" = "quit"

[[window_rules]]
app_id = "game.all"
pass_keys = true

[[window_rules]]
app_id = "game.some"
pass_keys = ["mod+q", "ctrl+q"]

[[window_rules]]
title = "*union*"
pass_keys = ["ctrl+s", "mod+Q"]

[[window_rules]]
title = "*everything*"
pass_keys = true

[[window_rules]]
title = "*after*"
pass_keys = ["ctrl+a"]

[[window_rules]]
title = "Keep*"
suspend_on_close = true
"#;

/// Six windows side by side on main, none focused: no rule, `true`, a list,
/// two lists, a list under `true`, and a list on a window that suspends.
fn key_passers(scratch: &Scratch) -> Host {
    key_passers_under(scratch, "")
}
/// The same under a config that begins with `top`, top-level keys.
fn key_passers_under(scratch: &Scratch, top: &str) -> Host {
    let mut h = running(scratch, &format!("{top}{PASS_KEYS}"));
    for (wid, app, title) in [
        (1, "app.plain", "plain"),
        (2, "game.all", "G"),
        (3, "game.some", "zsh"),
        (4, "game.some", "a union b"),
        (5, "app.plain", "union everything after"),
        (6, "app.plain", "Keep union"),
    ] {
        let at = rect(wid as f64 * 150.0 - 100.0, 100.0, 100.0, 100.0);
        assert_eq!(put(&mut h, wid, app, title, at), wid);
    }
    h
}

#[test]
fn pass_keys_is_the_focused_window_s_merged_list() {
    let scratch = Scratch::new();
    let mut h = key_passers(&scratch);
    // Nothing is focused, so nothing is passed.
    assert_eq!(h.focused(), Value::Null);
    assert_eq!(h.pass_keys(), Value::Null);
    // No rule; `true`; a list, in the spelling `bindings` gives a combo.
    h.observe_focus(1);
    assert_eq!(h.pass_keys(), Value::Null);
    h.observe_focus(2);
    assert_eq!(h.pass_keys(), json!(true));
    h.observe_focus(3);
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));
    // Two rules: the lists are unioned, and `mod+Q` is the `mod+q` the first
    // rule already listed.
    h.observe_focus(4);
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q", "ctrl+s"]));
    // `true` is sticky: a list before it and a list after it change nothing.
    h.observe_focus(5);
    assert_eq!(h.pass_keys(), json!(true));
    h.observe_focus(6);
    assert_eq!(h.pass_keys(), json!(["ctrl+s", "mod+q"]));
    // The rule each window mapped with still lists the merge by kind, and
    // neither pass list is reported as doing nothing.
    for (id, kind) in [(2, "all"), (3, "only"), (4, "only"), (5, "all")] {
        assert_eq!(h.rule(id)["pass_keys"], kind);
        assert_eq!(h.rule(id)["pass_mouse"], "none");
        assert_eq!(h.rule(id)["not_applied"], json!([]));
    }
    assert_eq!(h.rule(1), Value::Null);
}

#[test]
fn pass_keys_follows_every_kind_of_focus_change() {
    let scratch = Scratch::new();
    let mut h = key_passers(&scratch);
    h.observe_focus(1);
    // A focus request: the window is focused logically at once, and holds
    // the keyboard only when the adapter says so.
    h.ok(json!({"op":"focus","window":2}));
    assert_eq!(h.focused(), 2);
    assert_eq!(h.pass_keys(), Value::Null);
    h.answer_focus(true);
    assert_eq!(h.pass_keys(), json!(true));
    // A request that fails leaves the keyboard where it was, with a window
    // that is not the focused one: nothing is passed.
    h.ok(json!({"op":"focus","window":3}));
    assert_eq!(h.pass_keys(), Value::Null);
    h.answer_focus(false);
    assert_eq!(h.focused(), 3);
    assert_eq!(h.pass_keys(), Value::Null);
    // An adapter that performs no native focus settles it by logical focus.
    h.ok(json!({"op":"focus","window":3}));
    h.settle_focus();
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));
    // Native focus leaves the canvas: the window stays focused logically and
    // passes nothing until the keyboard is seen on it again.
    h.ok(json!({"op":"focus_lost"}));
    assert_eq!(h.focused(), 3);
    assert_eq!(h.pass_keys(), Value::Null);
    h.ok(json!({"op":"activate","window":3,"output":1,"cause":"native"}));
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));
    // A click on another window, on empty canvas, and on the first again.
    let click = h.ok(json!({"op":"activate","window":1,"output":1,"cause":"click"}));
    assert_eq!(click["effect"]["window"], 1, "{click}");
    h.settle_focus();
    assert_eq!(h.pass_keys(), Value::Null);
    h.ok(json!({"op":"activate","window":4,"output":1,"cause":"click"}));
    assert_eq!(h.pass_keys(), Value::Null);
    h.settle_focus();
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q", "ctrl+s"]));
    assert_eq!(h.ok(json!({"op":"clear_focus"})), json!({"dirty":true}));
    assert_eq!(h.pass_keys(), Value::Null);
    // A request for the window last seen holding the keyboard natively, 3,
    // takes nothing from it: it holds the keyboard while the request is in
    // flight, and still does when the request fails.
    h.ok(json!({"op":"focus","window":3}));
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));
    h.answer_focus(false);
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));
    // The focus a close hands on is a request like any other.
    h.observe_focus(1);
    h.observe_focus(2);
    assert_eq!(h.pass_keys(), json!(true));
    let closed = h.closed(2);
    assert_eq!(closed["standin"], false, "{closed}");
    let follower = closed["effect"]["window"].as_u64().unwrap();
    assert_eq!(h.focused(), follower);
    assert_eq!(h.pass_keys(), Value::Null);
    h.settle_focus();
    let expected = match follower {
        3 => json!(["mod+q", "ctrl+q"]),
        4 => json!(["mod+q", "ctrl+q", "ctrl+s"]),
        6 => json!(["ctrl+s", "mod+q"]),
        5 => json!(true),
        _ => Value::Null,
    };
    assert_eq!(h.pass_keys(), expected, "the follower is {follower}");
    // Upstream skips the test while a suspended window holds the focus: a
    // stand-in keeps the focus its window had, and passes nothing.
    h.observe_focus(6);
    assert_eq!(h.pass_keys(), json!(["ctrl+s", "mod+q"]));
    assert_eq!(h.closed(6)["standin"], true);
    assert_eq!(h.focused(), 6);
    assert_eq!(h.pass_keys(), Value::Null);
    // So does a slot whose window is gone for now.
    h.observe_focus(5);
    assert_eq!(h.pass_keys(), json!(true));
    let gone = h.window(5)["source"]["identity"].clone();
    h.ok(json!({"op":"remove_source","window":5,"identity":gone,"keep_placeholder":true}));
    h.ok(json!({"op":"focus","window":5}));
    assert_eq!(h.focused(), 5);
    assert_eq!(h.pass_keys(), Value::Null);
}

/// Sloppy focus is one more way the focus moves: without a raise, by a
/// request the adapter may answer, fail, or answer late as an observation.
/// `pass_keys` follows the window that holds the keyboard through all of it.
/// With the camera at the origin window N's center is the global point
/// (150 N + 150, 250).
#[test]
fn pass_keys_follows_a_hover_focused_window_once_its_focus_is_confirmed() {
    let scratch = Scratch::new();
    let mut h = key_passers_under(&scratch, "focus_follows_mouse = true\n");
    let over = |window: u64| (150.0 * window as f64 + 150.0, 250.0);
    let hover = |h: &mut Host, window: u64| {
        let (x, y) = over(window);
        let reply = h.hover(x, y);
        assert_eq!(reply["dirty"], true, "{reply}");
        assert_eq!(reply["effect"]["window"], window, "{reply}");
        assert_eq!(h.focused(), window);
    };
    h.ok(json!({"op":"tick_navigation","timestamp_ns":1_000_000_000u64}));
    h.observe_focus(1);
    let stacking = h.stack();
    // The hover moves the focus intent at once and asks for the keyboard:
    // nothing is passed until the adapter says the window has it.
    hover(&mut h, 2);
    assert_eq!(h.pass_keys(), Value::Null);
    h.answer_focus(true);
    assert_eq!(h.pass_keys(), json!(true));
    // The pointer moves on: the window it left passes nothing from the
    // moment the intent leaves it, and the next one nothing yet.
    hover(&mut h, 3);
    assert_eq!(h.pass_keys(), Value::Null);
    // The answer arrives as an observation, the hover's echo: recorded
    // where the window stands, with no flight and no new request, and the
    // keyboard is its from then on.
    assert_eq!(
        h.native(3),
        json!({"effect":null,"navigation":null,"dirty":false})
    );
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));
    assert_eq!(h.stack(), stacking, "a hover restacks nothing");
    // Over empty canvas the focus stays, and so does what is passed.
    let nothing = h.hover(300.0, 600.0);
    assert_eq!(nothing["dirty"], false, "{nothing}");
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));
    // An adapter that performs no native focus settles a hover by logical
    // focus, like a click.
    hover(&mut h, 4);
    assert_eq!(h.pass_keys(), Value::Null);
    h.settle_focus();
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q", "ctrl+s"]));
    // A hover whose request fails leaves nothing passed: neither the window
    // it left nor the one it failed to reach.
    hover(&mut h, 2);
    h.answer_focus(false);
    assert_eq!(h.focused(), 2);
    assert_eq!(h.pass_keys(), Value::Null);
    // The window took the keyboard after the adapter gave up: its report is
    // still that hover's echo, and it passes.
    assert_eq!(h.native(2)["navigation"], Value::Null);
    assert_eq!(h.pass_keys(), json!(true));
    // A request withdrawn unanswered, as a press withdraws it, and never
    // answered at all: nothing is passed for as long as the intent is on a
    // window the keyboard was never seen on, the three seconds a hover's
    // echo is waited for and after.
    hover(&mut h, 3);
    h.ok(json!({"op":"cancel_focus_cycle"}));
    assert_eq!(h.pass_keys(), Value::Null);
    h.ok(json!({"op":"tick_navigation","timestamp_ns":4_000_000_000u64}));
    assert_eq!(h.focused(), 3);
    assert_eq!(h.pass_keys(), Value::Null);
    // A report after that is the user's own activation, with its raise, and
    // the keyboard is the window's all the same.
    h.native(3);
    assert_eq!(h.stack().last(), Some(&3));
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));

    // A screen-pinned window takes the focus by hover and never enters the
    // focus history. It holds the keyboard like any window, so it passes.
    pin(&mut h, 5);
    h.observe_focus(1);
    assert_eq!(h.pass_keys(), Value::Null);
    hover(&mut h, 5);
    assert_eq!(h.pass_keys(), Value::Null);
    h.answer_focus(true);
    assert_eq!(h.pass_keys(), json!(true));
    assert!(!h.history().as_array().unwrap().contains(&json!(5)));
    // A stand-in takes the focus by hover too, and has nobody to pass to.
    assert_eq!(h.closed(6)["standin"], true);
    let (x, y) = over(6);
    let reply = h.hover(x, y);
    assert_eq!(reply["dirty"], true, "{reply}");
    assert_eq!(reply["effect"], Value::Null, "{reply}");
    assert_eq!(h.focused(), 6);
    assert_eq!(h.pass_keys(), Value::Null);
}

#[test]
fn pass_keys_is_resolved_against_the_title_and_the_config_of_the_moment() {
    let scratch = Scratch::new();
    let mut h = key_passers(&scratch);
    h.observe_focus(3);
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q"]));
    // Upstream evaluates pass_keys per key press against the live config, so
    // a title change applies at once. The rule the window mapped with, which
    // decides everything else, is not re-resolved.
    h.retitle(3, "now a union");
    assert_eq!(h.pass_keys(), json!(["mod+q", "ctrl+q", "ctrl+s"]));
    h.retitle(3, "everything");
    assert_eq!(h.pass_keys(), json!(true));
    assert_eq!(h.rule(3)["pass_keys"], "only");
    // So does a reload, in both directions.
    load_config(&mut h, &scratch, "");
    assert_eq!(h.pass_keys(), Value::Null);
    assert_eq!(h.rule(3)["pass_keys"], "only");
    h.observe_focus(1);
    load_config(
        &mut h,
        &scratch,
        "[[window_rules]]\napp_id = \"app.plain\"\ntitle = \"plain\"\npass_keys = [\"alt+F25\", \"mod+shift+Return\"]\n",
    );
    assert_eq!(h.rule(1), Value::Null);
    // A key outside the key table that no binding names is written as its
    // keysym, F1's 0xffbe and 24 more: no binding can be on it.
    assert_eq!(h.pass_keys(), json!(["alt+0xffd6", "mod+shift+Return"]));
}

#[test]
fn the_exit_chord_and_quit_are_never_passable() {
    let scratch = Scratch::new();
    let mut h = key_passers(&scratch);
    let reply = h.ok(json!({"op":"bindings"}));
    let keys = h.keys();
    assert!(keys.len() > 20, "{reply}");
    let by_combo = |combo: &str| {
        keys.iter()
            .find(|key| key["combo"] == combo)
            .unwrap_or_else(|| panic!("{combo} is not registered"))
            .clone()
    };
    // The binding that holds the shell's exit chord, whatever it runs, and
    // every binding that quits.
    assert_eq!(
        reply["reserved"],
        json!([{"purpose":"exit","key_code":0x35,"modifiers":chord("⌃⌥"),"claimed_by":"mod+Escape"}])
    );
    let exit = by_combo("mod+Escape");
    assert_eq!(
        (&exit["action"], &exit["passable"]),
        (&json!("home-toggle"), &json!(false))
    );
    let quits: Vec<&Value> = keys.iter().filter(|key| key["action"] == "quit").collect();
    assert!(
        quits.iter().any(|key| key["combo"] == "ctrl+shift+x"),
        "{quits:?}"
    );
    assert!(quits.len() >= 2, "upstream's default quit is bound too");
    // Every other key binding may be passed, the combos a rule lists here
    // among them: a list's combo is a binding's `combo`, letter for letter.
    for key in &keys {
        let held = key["action"] == "quit" || key["combo"] == "mod+Escape";
        assert_eq!(key["passable"], !held, "{key}");
    }
    for combo in ["mod+q", "ctrl+q"] {
        assert_eq!(by_combo(combo)["passable"], true);
    }
    // A media key is a binding like any other.
    let media: Vec<(&Value, &Value)> = reply["media_keys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|key| (&key["combo"], &key["passable"]))
        .collect();
    assert!(
        media.contains(&(&json!("XF86AudioPlay"), &json!(true))),
        "{media:?}"
    );
    assert!(
        media.contains(&(&json!("XF86AudioNext"), &json!(false))),
        "{media:?}"
    );
}

/// Window 1 is `app.claims`, window 2 `app.plain`, side by side on main with
/// the camera at the origin: global (500, 350) is on 1 and (900, 350) on 2.
fn two_windows(scratch: &Scratch, toml: &str) -> Host {
    let mut h = running(scratch, toml);
    put(
        &mut h,
        1,
        "app.claims",
        "One",
        rect(100.0, 100.0, 400.0, 300.0),
    );
    put(
        &mut h,
        2,
        "app.plain",
        "Two",
        rect(550.0, 100.0, 400.0, 300.0),
    );
    assert_eq!(h.hit(1, 500.0, 350.0), 1);
    assert_eq!(h.hit(1, 900.0, 350.0), 2);
    h
}
fn kind(reply: &Value) -> (&Value, &Value) {
    (&reply["binding"]["kind"], &reply["binding"]["combo"])
}

#[test]
fn a_listed_combo_is_the_window_s_and_every_other_stays_a_binding() {
    let scratch = Scratch::new();
    let mut h = two_windows(
        &scratch,
        "[[window_rules]]\napp_id = \"app.claims\"\npass_mouse = [\"alt+left\"]\n",
    );
    // Upstream a_claimed_drag_reaches_the_client: alt+left over the window
    // that lists it is no binding, so the shell forwards the press.
    assert_eq!(h.press("left", "⌥", 1), PASSED());
    // an_unclaimed_drag_moves_the_window: over a window with no rule the same
    // press is the move binding, and the reply is the one it always was.
    let unclaimed = h.press("left", "⌥", 2);
    assert_eq!(
        kind(&unclaimed),
        (&json!("move_window"), &json!("alt+left"))
    );
    // a_combo_outside_the_list_still_binds.
    let resize = h.press("right", "⌥", 1);
    assert_eq!(
        kind(&resize),
        (&json!("resize_window"), &json!("alt+right"))
    );
    let group = h.press("left", "⌥⇧", 1);
    assert_eq!(
        kind(&group),
        (&json!("move_snapped_windows"), &json!("alt+shift+left"))
    );
    // an_unclaimed_anywhere_binding_still_pans.
    let pan = h.press("left", "⌃⌥", 1);
    assert_eq!(kind(&pan), (&json!("pan_viewport"), &json!("mod+left")));
    // A press no binding takes is unbound, not passed: a claim is asked only
    // once a binding has matched.
    assert_eq!(h.press("left", "", 1), UNBOUND());
    // The claim is the window's under the pointer, not the focused one's.
    h.observe_focus(1);
    assert_eq!(kind(&h.press("left", "⌥", 2)).0, "move_window");
    h.observe_focus(2);
    assert_eq!(h.press("left", "⌥", 1), PASSED());
    // The shell says where the pointer is. Without a window, and on the
    // canvas, nothing is claimed.
    let lookup =
        json!({"op":"mouse_binding","trigger":"left","modifiers":chord("⌥"),"context":"window"});
    assert_eq!(h.ok(lookup)["binding"]["kind"], "move_window");
    assert_eq!(
        h.mouse("left", Value::Null, "⌥", "canvas", json!(1)),
        UNBOUND()
    );
    assert_eq!(
        h.mouse("left", Value::Null, "⌥", "window", Value::Null)["binding"]["kind"],
        "move_window"
    );
    assert_eq!(h.rule(1)["pass_mouse"], "only");
    assert_eq!(h.rule(1)["not_applied"], json!([]));
}

#[test]
fn passing_everything_claims_an_anywhere_binding_over_the_window_only() {
    let scratch = Scratch::new();
    let mut h = two_windows(
        &scratch,
        "[[window_rules]]\napp_id = \"app.claims\"\npass_mouse = true\n",
    );
    // Upstream passing_everything_claims_an_anywhere_binding: the default
    // `mod+left` pan comes from `anywhere` and is claimed like any other.
    for (trigger, modifiers) in [
        ("left", "⌥"),
        ("right", "⌥"),
        ("middle", "⌥"),
        ("left", "⌃⌥"),
    ] {
        assert_eq!(
            h.press(trigger, modifiers, 1),
            PASSED(),
            "{modifiers}{trigger}"
        );
    }
    assert_eq!(h.press("left", "⌃⌥⌘", 1), PASSED());
    assert_eq!(h.scroll("wheel", "⌃⌥", 1), PASSED());
    assert_eq!(h.scroll("finger", "⌃⌥", 1), PASSED());
    assert_eq!(kind(&h.press("left", "⌃⌥", 2)).0, "pan_viewport");
    assert_eq!(kind(&h.scroll("wheel", "⌃⌥", 2)).0, "zoom");
    // Still nothing to pass where nothing is bound.
    assert_eq!(h.press("left", "", 1), UNBOUND());
    assert_eq!(h.scroll("finger", "", 1), UNBOUND());
    // Upstream asks only in the on-window context: on the canvas the bare
    // drag pans and the bare wheel zooms, whatever window the shell names.
    let pan = h.mouse("left", Value::Null, "", "canvas", json!(1));
    assert_eq!(kind(&pan), (&json!("pan_viewport"), &json!("left")));
    let zoom = h.mouse("scroll", json!("wheel"), "", "canvas", json!(1));
    assert_eq!(kind(&zoom), (&json!("zoom"), &json!("wheel-scroll")));
    assert_eq!(h.rule(1)["pass_mouse"], "all");
}

#[test]
fn a_wheel_and_a_trackpad_scroll_are_claimed_under_their_own_triggers() {
    let scratch = Scratch::new();
    let mut h = two_windows(
        &scratch,
        r#"
[[window_rules]]
app_id = "app.claims"
pass_mouse = ["mod+wheel-scroll"]

[[window_rules]]
app_id = "app.plain"
pass_mouse = ["mod+trackpad-scroll"]
"#,
    );
    // Upstream a_claimed_scroll_reaches_the_client_without_zooming, and its
    // control over the window that lists the other trigger.
    assert_eq!(h.scroll("wheel", "⌃⌥", 1), PASSED());
    let zoom = h.scroll("wheel", "⌃⌥", 2);
    assert_eq!(kind(&zoom), (&json!("zoom"), &json!("mod+wheel-scroll")));
    // Every source that is not a finger scrolls as the wheel.
    assert_eq!(h.scroll("continuous", "⌃⌥", 1), PASSED());
    assert_eq!(h.over("scroll", Value::Null, "⌃⌥", 1), PASSED());
    // a_claimed_trackpad_scroll_reaches_the_client_without_panning.
    assert_eq!(h.scroll("finger", "⌃⌥", 2), PASSED());
    let pan = h.scroll("finger", "⌃⌥", 1);
    assert_eq!(
        kind(&pan),
        (&json!("pan_viewport"), &json!("mod+trackpad-scroll"))
    );
}

#[test]
fn a_wheel_notch_is_a_lookup_of_its_own_and_is_claimed_by_its_own_combo() {
    let scratch = Scratch::new();
    let mut h = two_windows(
        &scratch,
        r#"
[mouse.on-window]
"alt+wheel-down" = "toggle-fullscreen"
"alt+wheel-up" = "pan-viewport"

[[window_rules]]
app_id = "app.claims"
pass_mouse = ["alt+wheel-down", "mod+wheel-down"]
"#,
    );
    // Upstream an_unclaimed_wheel_notch_runs_its_action: the notch is bound
    // to an action over a window, and nowhere else.
    let notch = h.over("wheel_down", Value::Null, "⌥", 2);
    assert_eq!(
        (kind(&notch), &notch["binding"]["action"]),
        (
            (&json!("action"), &json!("alt+wheel-down")),
            &json!("toggle-fullscreen")
        )
    );
    assert_eq!(
        h.mouse("wheel_down", Value::Null, "⌥", "canvas", Value::Null),
        UNBOUND()
    );
    // a_claimed_wheel_notch_runs_no_action.
    assert_eq!(h.over("wheel_down", Value::Null, "⌥", 1), PASSED());
    // The notch site runs an action and nothing else: a notch bound to a
    // continuous action is no notch binding, claimed or not.
    assert_eq!(h.over("wheel_up", Value::Null, "⌥", 2), UNBOUND());
    assert_eq!(h.over("wheel_up", Value::Null, "⌥", 1), UNBOUND());
    // The notch is a channel apart from the continuous scroll: a claim on
    // `mod+wheel-down` leaves the `mod+wheel-scroll` zoom a binding, and
    // claims nothing where no notch is bound.
    assert_eq!(kind(&h.scroll("wheel", "⌃⌥", 1)).0, "zoom");
    assert_eq!(h.over("wheel_down", Value::Null, "⌃⌥", 1), UNBOUND());
}

#[test]
fn a_claim_is_resolved_live_and_only_for_a_window_with_a_client() {
    let scratch = Scratch::new();
    let mut h = two_windows(&scratch, "");
    assert_eq!(kind(&h.press("left", "⌥", 1)).0, "move_window");
    // Upstream a_reloaded_rule_applies_without_remapping_the_window.
    load_config(
        &mut h,
        &scratch,
        "[[window_rules]]\napp_id = \"app.claims\"\npass_mouse = [\"alt+left\"]\n",
    );
    assert_eq!(h.rule(1), Value::Null);
    assert_eq!(h.press("left", "⌥", 1), PASSED());
    // A title rule follows the title of the moment.
    load_config(
        &mut h,
        &scratch,
        r#"
[[window_rules]]
title = "Blender*"
pass_mouse = ["alt+left", "ctrl+alt+left"]

[[window_rules]]
title = "Keep*"
suspend_on_close = true
pass_mouse = true
"#,
    );
    assert_eq!(kind(&h.press("left", "⌥", 1)).0, "move_window");
    h.retitle(1, "Blender 4");
    assert_eq!(h.press("left", "⌥", 1), PASSED());
    // A physical chord can stand for two upstream combos. ⌃⌥ is `mod` and is
    // `ctrl+alt`; the binding that matches is `mod+left`, and a claim is
    // asked under the combo that matched, so listing `ctrl+alt+left` claims
    // nothing here.
    assert_eq!(
        kind(&h.press("left", "⌃⌥", 1)),
        (&json!("pan_viewport"), &json!("mod+left"))
    );
    // Upstream a_claimed_press_on_a_pinned_window_reaches_the_client: a
    // pinned window claims like any other.
    pin(&mut h, 1);
    assert_eq!(h.press("left", "⌥", 1), PASSED());
    // A stand-in has no client to pass anything to: the binding stays.
    h.retitle(2, "Keep me");
    assert_eq!(h.press("left", "⌥", 2), PASSED());
    assert_eq!(h.closed(2)["standin"], true);
    assert_eq!(kind(&h.press("left", "⌥", 2)).0, "move_window");
    // A window the controller does not know claims nothing either.
    assert_eq!(kind(&h.press("left", "⌥", 99)).0, "move_window");
}

const PICK_CLAIMS: &str = r#"
[zoom]
interact_min = 0.5

[mouse.on-window]
"alt+wheel-down" = "zoom-in"
"wheel-up" = "zoom-out"

[[window_rules]]
app_id = "app.claims"
pass_mouse = true
"#;

/// Upstream's pick-mode gate (docs/window-rules.md, and the `!pick_mode()`
/// of each call site): below `[zoom] interact_min` a canvas window has no
/// pointer focus to forward to, so its claims are ignored and the canvas's
/// bindings stay live, while a pinned window, drawn at its own size and still
/// interactive, keeps its button claims and no other.
#[test]
fn below_interact_min_a_canvas_window_claims_nothing_and_a_pinned_one_keeps_its_button_claims() {
    let scratch = Scratch::new();
    let mut h = two_windows(&scratch, PICK_CLAIMS);
    // Window 3 claims everything too, and is pinned at the global rectangle
    // (300, 550) 200 x 150. Window 4 is pinned on side, at (1400, 200).
    put(
        &mut h,
        3,
        "app.claims",
        "Pin",
        rect(100.0, 450.0, 200.0, 150.0),
    );
    pin(&mut h, 3);
    assert_eq!(
        h.pinned(3),
        json!({"output":1,"screen_rect":rect(300.0,550.0,200.0,150.0)})
    );
    put(
        &mut h,
        4,
        "app.claims",
        "Side",
        rect(10100.0, 100.0, 200.0, 150.0),
    );
    pin(&mut h, 4);
    assert_eq!(
        h.pinned(4),
        json!({"output":2,"screen_rect":rect(1400.0,200.0,200.0,150.0)})
    );
    let pick_of = |h: &mut Host, x: f64, y: f64| {
        let reply = h.ok(json!({"op":"hit","output":1,"screen":point(x, y)}));
        (reply["hit"]["window"].clone(), reply["hit"]["pick"].clone())
    };

    // Above the threshold every claim holds: the canvas window's and the
    // pinned window's, for a press, a scroll and a notch alike.
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
    assert_eq!(pick_of(&mut h, 500.0, 350.0), (json!(1), json!(false)));
    for window in [1, 3] {
        assert_eq!(h.press("left", "⌥", window), PASSED());
        assert_eq!(h.press("left", "⌃⌥", window), PASSED());
        assert_eq!(h.scroll("wheel", "⌃⌥", window), PASSED());
        assert_eq!(h.scroll("finger", "⌃⌥", window), PASSED());
        assert_eq!(h.over("wheel_down", Value::Null, "⌥", window), PASSED());
        assert_eq!(h.over("wheel_up", Value::Null, "", window), PASSED());
    }

    // Main at zoom 0.4 about its own origin: the camera stays, window 1 shows
    // at the global rectangle (240, 140) 160 x 120 and is a pick target. The
    // pinned window is where it was, and is none.
    h.ok(json!({"op":"zoom","output":1,"zoom":0.4,"anchor":point(200.0,100.0)}));
    assert_eq!(h.snapshot()["outputs"][0]["pick"], true);
    assert_eq!(h.snapshot()["outputs"][1]["pick"], false);
    assert_eq!(pick_of(&mut h, 300.0, 200.0), (json!(1), json!(true)));
    assert_eq!(pick_of(&mut h, 350.0, 600.0), (json!(3), json!(false)));

    // The canvas window claims nothing there. A binding whose modifiers are
    // held stays the canvas's, as try_pick_button lets it win.
    let moved = h.picked("left", Value::Null, "⌥", 1);
    assert_eq!(kind(&moved), (&json!("move_window"), &json!("alt+left")));
    let pan = h.picked("left", Value::Null, "⌃⌥", 1);
    assert_eq!(kind(&pan), (&json!("pan_viewport"), &json!("mod+left")));
    // A bare press is the pick's: unbound, and not passed to anyone.
    assert_eq!(h.picked("left", Value::Null, "", 1), UNBOUND());
    // A scroll: the bound one stays a binding, and the bare one, which no
    // window can receive, is looked up again as one on empty canvas.
    let zoom = h.picked("scroll", json!("wheel"), "⌃⌥", 1);
    assert_eq!(kind(&zoom), (&json!("zoom"), &json!("mod+wheel-scroll")));
    let pan = h.picked("scroll", json!("finger"), "", 1);
    assert_eq!(
        kind(&pan),
        (&json!("pan_viewport"), &json!("trackpad-scroll"))
    );
    // A notch is looked up ahead of the pick, with no modifier gate: the
    // bare one runs its action, and neither is claimed.
    let notch = h.picked("wheel_down", Value::Null, "⌥", 1);
    assert_eq!(
        (kind(&notch), &notch["binding"]["action"]),
        (
            (&json!("action"), &json!("alt+wheel-down")),
            &json!("zoom-in")
        )
    );
    let notch = h.picked("wheel_up", Value::Null, "", 1);
    assert_eq!(
        (kind(&notch), &notch["binding"]["action"]),
        ((&json!("action"), &json!("wheel-up")), &json!("zoom-out"))
    );
    // `pick` is the hit's to say: the same lookups are those of a window
    // above the threshold without it.
    assert_eq!(h.press("left", "⌥", 1), PASSED());

    // The pinned window keeps its button claims below the threshold, as
    // upstream's try_pinned_button asks them with no gate.
    assert_eq!(h.press("left", "⌥", 3), PASSED());
    assert_eq!(h.press("left", "⌃⌥", 3), PASSED());
    // Its scroll and notch claims go: both of upstream's axis sites ask
    // `!pick_mode()` whatever is under the pointer.
    let zoom = h.scroll("wheel", "⌃⌥", 3);
    assert_eq!(kind(&zoom), (&json!("zoom"), &json!("mod+wheel-scroll")));
    let pan = h.scroll("finger", "⌃⌥", 3);
    assert_eq!(
        kind(&pan),
        (&json!("pan_viewport"), &json!("mod+trackpad-scroll"))
    );
    let notch = h.over("wheel_down", Value::Null, "⌥", 3);
    assert_eq!(kind(&notch).0, "action");
    let notch = h.over("wheel_up", Value::Null, "", 3);
    assert_eq!(kind(&notch).0, "action");
    // It is the pin's own output that is asked: the window pinned on side,
    // which is above the threshold, claims its scroll as before.
    assert_eq!(h.scroll("wheel", "⌃⌥", 4), PASSED());
    assert_eq!(h.over("wheel_down", Value::Null, "⌥", 4), PASSED());

    // The pinned window is no pick target and its drag is the screen-space
    // one below the threshold too: 10 points right and 5 down, on screen.
    assert_eq!(
        h.ok(json!({"op":"pick","window":3,"output":1})),
        json!({"navigation":null,"dirty":false})
    );
    begin_drag(&mut h, 3);
    assert_eq!(h.drag_to((10.0, 5.0), Some((360.0, 605.0))), STILL());
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.pinned(3)["screen_rect"], rect(310.0, 555.0, 200.0, 150.0));

    // Back above the threshold every claim is back.
    h.ok(json!({"op":"zoom","output":1,"zoom":1.0,"anchor":point(200.0,100.0)}));
    assert_eq!(h.snapshot()["outputs"][0]["pick"], false);
    assert_eq!(h.scroll("wheel", "⌃⌥", 3), PASSED());
    assert_eq!(h.over("wheel_down", Value::Null, "⌥", 3), PASSED());
    assert_eq!(h.scroll("wheel", "⌃⌥", 1), PASSED());
}

const DRAG_RULES: &str = r#"
[[window_rules]]
app_id = "app.widget"
widget = true

[[window_rules]]
title = "Keep*"
suspend_on_close = true
"#;

/// Main at zoom 0.5 with its camera at (1000, -200), and window 1 pinned
/// where the canvas showed it: the output-local point (100, 100), so the
/// global rectangle (300, 200) 400 x 300.
fn one_pin(scratch: &Scratch) -> Host {
    let mut h = running(scratch, DRAG_RULES);
    zoom_out(&mut h);
    put(&mut h, 1, "app.p", "P", rect(1200.0, 0.0, 400.0, 300.0));
    pin(&mut h, 1);
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(300.0,200.0,400.0,300.0)})
    );
    h
}
fn begin_drag(h: &mut Host, window: u64) {
    assert_eq!(
        h.ok(json!({"op":"begin_drag","window":window,"output":1})),
        json!({})
    );
}
const STILL: fn() -> Value = || json!({"needs_frames":false});

#[test]
fn the_move_binding_drags_a_pinned_window_in_screen_space() {
    let scratch = Scratch::new();
    let mut h = one_pin(&scratch);
    // The press: the pinned window is hit, the move binding is not claimed,
    // and the drag the shell then begins is accepted.
    assert_eq!(h.hit(1, 320.0, 220.0), 1);
    assert_eq!(kind(&h.press("left", "⌥", 1)).0, "move_window");
    let camera = h.snapshot()["outputs"][0].clone();
    begin_drag(&mut h, 1);
    // Upstream apply_pinned_move: the frame follows the pointer by its screen
    // displacement, whole points, whatever the zoom. A canvas window would
    // have moved by twice that in the world, and half of it on screen.
    assert_eq!(h.drag_to((37.4, -20.6), Some((357.4, 199.4))), STILL());
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(337.0,179.0,400.0,300.0)})
    );
    let placed = h.placement(1, 1);
    assert_eq!(placed["screen_rect"], rect(337.0, 179.0, 400.0, 300.0));
    assert_eq!(placed["pinned"], true);
    // The canvas frame is bookkeeping and follows: the output-local point
    // (137, 79) at zoom 0.5 from the camera (1000, -200).
    assert_eq!(h.world(1), rect(1274.0, -42.0, 400.0, 300.0));
    // The displacement is the total since the press, and a half rounds away
    // from zero, as upstream's does.
    assert_eq!(h.drag_to((0.5, -0.5), Some((320.5, 219.5))), STILL());
    assert_eq!(h.pinned(1)["screen_rect"], rect(301.0, 200.0, 400.0, 300.0));
    assert_eq!(h.world(1), rect(1202.0, 0.0, 400.0, 300.0));
    // Upstream writes the pin unclamped: the frame goes past the output's
    // top-left corner, and is drawn clipped to the output.
    assert_eq!(h.drag_to((-150.0, -130.0), Some((205.0, 105.0))), STILL());
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(150.0,70.0,400.0,300.0)})
    );
    assert_eq!(
        h.placement(1, 1)["clip_rect"],
        rect(200.0, 100.0, 350.0, 270.0)
    );
    assert_eq!(h.world(1), rect(900.0, -260.0, 400.0, 300.0));
    // And past the bottom-right one, with the pointer deep in the zone where
    // a canvas window's drag pans the camera: a pinned one never does.
    assert_eq!(h.drag_to((850.0, 560.0), Some((1195.0, 895.0))), STILL());
    assert_eq!(
        h.pinned(1)["screen_rect"],
        rect(1150.0, 760.0, 400.0, 300.0)
    );
    assert_eq!(h.snapshot()["navigation"]["edge_pans"], json!({}));
    assert_eq!(h.snapshot()["outputs"][0], camera);
    // Where it is let go is where it stays.
    assert_eq!(h.drag_to((60.0, 40.0), Some((380.0, 260.0))), STILL());
    assert_eq!(h.ok(json!({"op":"end_gesture"})), json!({}));
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(360.0,240.0,400.0,300.0)})
    );
    assert_eq!(h.world(1), rect(1320.0, 80.0, 400.0, 300.0));
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(5.0, 5.0)})),
        "no active gesture"
    );

    // Control: the same report on a canvas window. It moves by the screen
    // displacement over the zoom, and its pointer at the edge arms a pan.
    put(&mut h, 2, "app.b", "B", rect(1400.0, 600.0, 200.0, 100.0));
    begin_drag(&mut h, 2);
    assert_eq!(
        h.drag_to((60.0, 40.0), Some((1195.0, 500.0))),
        json!({"needs_frames":true})
    );
    assert_eq!(h.world(2), rect(1520.0, 680.0, 200.0, 100.0));
    h.ok(json!({"op":"end_gesture"}));

    // The pin is saved where the drag left it, and comes back there.
    let path = scratch.path("scene.json");
    h.ok(json!({"op":"save","path":path}));
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        saved["pins"],
        json!({"1":{"output":1,"screen_pos":[160,140]}})
    );
    let mut next = Host::new();
    next.ok(json!({"op":"load","path":path}));
    main_output(&mut next);
    side_output(&mut next);
    assert_eq!(
        next.pinned(1),
        json!({"output":1,"screen_rect":rect(360.0,240.0,400.0,300.0)})
    );

    // Unpinned, the frame lands at the canvas point the pin shows: its
    // top-left stays at the global point (360, 240), at the canvas's scale.
    h.observe_focus(1);
    assert_eq!(h.action("toggle-pin-to-screen"), CHANGED());
    assert_eq!(h.pinned(1), Value::Null);
    assert_eq!(h.world(1), rect(1320.0, 80.0, 400.0, 300.0));
    assert_eq!(
        h.placement(1, 1)["screen_rect"],
        rect(360.0, 240.0, 200.0, 150.0)
    );
}

#[test]
fn a_pinned_drag_follows_the_pointer_to_another_output() {
    let scratch = Scratch::new();
    let mut h = one_pin(&scratch);
    begin_drag(&mut h, 1);
    // Upstream binds the pin to the output the pointer is on: the frame keeps
    // following the pointer in global screen points, (300, 200) + (1100, 50),
    // which is the point (100, 150) of side.
    assert_eq!(h.drag_to((1100.0, 50.0), Some((1450.0, 300.0))), STILL());
    assert_eq!(
        h.pinned(1),
        json!({"output":2,"screen_rect":rect(1400.0,250.0,400.0,300.0)})
    );
    assert_eq!((h.drawn(1), h.drawn(2)), (vec![], vec![1]));
    // Its canvas frame is where side's camera, parked at (10000, 0), shows it.
    assert_eq!(h.world(1), rect(10100.0, 150.0, 400.0, 300.0));
    // A report without a pointer stays on the output the drag is on.
    assert_eq!(h.drag_to((1110.0, 50.0), None), STILL());
    assert_eq!(
        h.pinned(1),
        json!({"output":2,"screen_rect":rect(1410.0,250.0,400.0,300.0)})
    );
    // So does one whose pointer is on no output, and the pointer counts as
    // held at that output's edge, as upstream's cursor is. The press was at
    // (350, 250), the frame's point (50, 50): 50 points above side, the
    // pointer is held at side's top edge, y = 100.
    assert_eq!(h.drag_to((1120.0, -200.0), Some((1470.0, 50.0))), STILL());
    assert_eq!(
        h.pinned(1),
        json!({"output":2,"screen_rect":rect(1420.0,50.0,400.0,300.0)})
    );
    assert_eq!(h.hit(2, 1470.0, 100.0), 1);
    // Far past side's bottom-right corner it is held at side's last point,
    // (2099, 699): the frame's point (50, 50) is still on side.
    assert_eq!(h.drag_to((4650.0, 4750.0), Some((5000.0, 5000.0))), STILL());
    assert_eq!(
        h.pinned(1),
        json!({"output":2,"screen_rect":rect(2049.0,649.0,400.0,300.0)})
    );
    assert_eq!(
        h.placement(2, 1)["clip_rect"],
        rect(2049.0, 649.0, 51.0, 51.0)
    );
    assert_eq!(h.hit(2, 2099.0, 699.0), 1);
    // Back on main.
    assert_eq!(h.drag_to((10.0, 0.0), Some((360.0, 250.0))), STILL());
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(310.0,200.0,400.0,300.0)})
    );
    // Let go on side: the pin is side's.
    assert_eq!(h.drag_to((1100.0, 50.0), Some((1450.0, 300.0))), STILL());
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.pinned(1)["output"], 2);
    // Upstream start_pinned_move installs nothing while the pin's output is
    // gone.
    h.ok(json!({"op":"remove_output","output":2}));
    assert_eq!(h.pinned(1), json!({"output":2,"screen_rect":null}));
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":1,"output":1})),
        "the window's output is not connected"
    );
}

/// The shell's output is its display less the 64-point strip at the top, and
/// its pointer goes wherever macOS lets it, the strip included. Upstream's
/// cursor is confined to an output, so the point a frame was taken by never
/// leaves one, and the frame can always be reached again.
#[test]
fn a_pinned_drag_whose_pointer_leaves_every_output_keeps_the_grabbed_point_on_one() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    h.ok(json!({"op":"register_output","stable_id":"main","screen_bounds":rect(0.0,64.0,1440.0,836.0)}));
    load_config(&mut h, &scratch, DRAG_RULES);
    h.ok(json!({"op":"adoption_complete"}));
    put(&mut h, 1, "app.p", "P", rect(300.0, 200.0, 400.0, 300.0));
    pin(&mut h, 1);
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(300.0,264.0,400.0,300.0)})
    );
    // Pressed at (500, 554), ten points above the frame's bottom edge, and
    // taken up into the strip: the pointer counts as held at the output's top
    // edge, y = 64, and the frame's row 290 is there.
    begin_drag(&mut h, 1);
    assert_eq!(h.drag_to((0.0, -534.0), Some((500.0, 20.0))), STILL());
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(300.0,-226.0,400.0,300.0)})
    );
    assert_eq!(
        h.placement(1, 1)["clip_rect"],
        rect(300.0, 64.0, 400.0, 10.0)
    );
    assert_eq!(h.hit(1, 500.0, 64.0), 1);
    // A frame shorter than the strip, pressed at (750, 394), its row 30.
    put(&mut h, 2, "app.q", "Q", rect(500.0, 300.0, 300.0, 60.0));
    pin(&mut h, 2);
    assert_eq!(
        h.pinned(2),
        json!({"output":1,"screen_rect":rect(500.0,364.0,300.0,60.0)})
    );
    begin_drag(&mut h, 2);
    assert_eq!(h.drag_to((0.0, -384.0), Some((750.0, 10.0))), STILL());
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(
        h.pinned(2),
        json!({"output":1,"screen_rect":rect(500.0,34.0,300.0,60.0)})
    );
    assert_eq!(
        h.placement(1, 2)["clip_rect"],
        rect(500.0, 64.0, 300.0, 30.0)
    );
    assert_eq!(h.hit(1, 750.0, 64.0), 2);
}

#[test]
fn a_pinned_drag_is_one_gesture_among_the_others() {
    let scratch = Scratch::new();
    let mut h = one_pin(&scratch);
    put(&mut h, 2, "app.b", "B", rect(1400.0, 600.0, 200.0, 100.0));
    // A resize of a pinned window needs native resize and stays refused.
    assert_eq!(
        h.error(json!({"op":"begin_resize","window":1,"output":1,"edges":"bottom_right"})),
        BY_HAND
    );
    assert_eq!(
        h.error(json!({"op":"begin_native_resize","window":1,"output":1,"edges":"bottom_right","start_screen":point(690.0, 490.0)})),
        BY_HAND
    );
    // A pinned widget is a widget: upstream's move binding passes it over.
    put(
        &mut h,
        3,
        "app.widget",
        "W",
        rect(1200.0, 700.0, 200.0, 100.0),
    );
    assert_eq!(
        h.ok(json!({"op":"ipc","output":1,"request":{"Pin":{"window":3,"value":true}}}))["reply"],
        json!({"Ok":{"Pin":true}})
    );
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":3,"output":1})),
        "a widget is not moved or resized by hand"
    );
    // A pinned window has no cluster: a group move drags it alone.
    assert_eq!(
        h.ok(json!({"op":"begin_drag","window":1,"output":1,"group":true})),
        json!({})
    );
    assert_eq!(h.drag_to((10.0, 10.0), Some((330.0, 230.0))), STILL());
    assert_eq!(h.pinned(1)["screen_rect"], rect(310.0, 210.0, 400.0, 300.0));
    // It is the one pointer gesture there is, and a pin waits for it to end,
    // as it waits for any drag.
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":2,"output":1})),
        "gesture already active"
    );
    assert_eq!(
        h.refused(json!({"Pin":{"window":1,"value":false}})),
        UNDER_A_GESTURE
    );
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"toggle-pin-to-screen"})),
        UNDER_A_GESTURE
    );
    h.ok(json!({"op":"end_gesture"}));

    // A trackpad move drives only the drag it installed. Window 2 shows at
    // the global rectangle (400, 500) 100 x 50, below the pinned one. The
    // pointer ends the swipe's drag and begins a pinned window's: the swipe
    // neither moves it nor, when the fingers lift, releases it.
    let begin = h.ok(json!({"op":"gesture_begin","kind":"swipe","fingers":3,"modifiers":chord(""),"context":"window","output":1,"pointer":point(450.0, 525.0),"doubletap":true,"time_ms":1000}));
    assert_eq!(begin["gesture"]["state"], "swipe_move", "{begin}");
    assert_eq!(begin["gesture"]["window"], 2);
    h.ok(json!({"op":"end_gesture"}));
    begin_drag(&mut h, 1);
    let before = h.snapshot();
    h.ok(json!({"op":"gesture_update","dx":40.0,"dy":0.0,"time_ms":1010}));
    assert_eq!(h.snapshot()["windows"], before["windows"]);
    h.ok(json!({"op":"gesture_end","cancelled":false,"time_ms":1020}));
    assert_eq!(h.drag_to((5.0, 0.0), None), STILL());
    assert_eq!(h.pinned(1)["screen_rect"], rect(315.0, 210.0, 400.0, 300.0));
    // An output that goes takes every gesture with it.
    h.ok(json!({"op":"remove_output","output":2}));
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(9.0, 9.0)})),
        "no active gesture"
    );
}

/// Upstream try_start_gesture_move, its GestureTarget::Pinned arm: the move
/// gesture over a screen-pinned window installs the pinned drag a bound press
/// installs (start_pinned_move), raises and focuses the window, and drives
/// the drag from the same SwipeMove state as a canvas window's.
#[test]
fn the_move_gesture_drags_a_pinned_window_in_screen_space() {
    let scratch = Scratch::new();
    let mut h = one_pin(&scratch);
    put(&mut h, 2, "app.b", "B", rect(1400.0, 600.0, 200.0, 100.0));
    h.observe_focus(2);
    let begin = |h: &mut Host, doubletap: bool| {
        h.ok(json!({"op":"gesture_begin","kind":"swipe","fingers":3,"modifiers":chord(""),"context":"window","output":1,"pointer":point(350.0, 250.0),"doubletap":doubletap,"time_ms":1000}))
    };
    let swipe = |h: &mut Host, dx: f64, dy: f64| {
        h.ok(json!({"op":"gesture_update","dx":dx,"dy":dy,"time_ms":1010}))
    };
    let end = |h: &mut Host| h.ok(json!({"op":"gesture_end","cancelled":false,"time_ms":1020}));
    let camera = h.snapshot()["outputs"][0].clone();

    // The default move gesture, begun on the pinned window at its point
    // (50, 50): the same state as any move, the window raised and focused.
    let reply = begin(&mut h, true);
    assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
    assert_eq!(reply["gesture"]["window"], 1);
    assert_eq!(reply["note"], Value::Null);
    assert_eq!(reply["effects"][0]["op"], "focus_native_window", "{reply}");
    assert_eq!(reply["effects"][0]["window"], 1, "{reply}");
    assert_eq!(h.focused(), 1);
    assert_eq!(h.stack(), vec![2, 1]);
    // The frame follows the fingers by their screen displacement, whole
    // points, whatever the zoom: the numbers of the bound press's drag. A
    // canvas window would move by twice that in the world at zoom 0.5.
    assert_eq!(swipe(&mut h, 37.4, -20.6)["needs_frames"], false);
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(337.0,179.0,400.0,300.0)})
    );
    assert_eq!(h.world(1), rect(1274.0, -42.0, 400.0, 300.0));
    // Upstream warps its cursor inside the gesture's output, so the pointer
    // the drag follows stops at main's last column, x = 1199: 849 from the
    // press. The pin never reaches side, no camera pans, nothing coasts.
    assert_eq!(swipe(&mut h, 5000.0, 0.0)["needs_frames"], false);
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(1149.0,179.0,400.0,300.0)})
    );
    assert_eq!(h.snapshot()["navigation"]["edge_pans"], json!({}));
    assert_eq!(h.snapshot()["outputs"][0], camera);
    // It is the pointer's one gesture while it lasts.
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":2,"output":1})),
        "gesture already active"
    );
    assert_eq!(swipe(&mut h, -799.0, 20.6)["needs_frames"], false);
    let reply = end(&mut h);
    assert_eq!(reply["dirty"], true, "{reply}");
    assert_eq!(
        h.pinned(1),
        json!({"output":1,"screen_rect":rect(350.0,200.0,400.0,300.0)})
    );
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(5.0, 5.0)})),
        "no active gesture"
    );

    // The cluster move is the same drag: a pinned window has no cluster.
    load_config(
        &mut h,
        &scratch,
        &format!(
            "{DRAG_RULES}\n[gestures.on-window]\n\"3-finger-swipe\" = \"move-snapped-windows\"\n"
        ),
    );
    let reply = begin(&mut h, false);
    assert_eq!(reply["gesture"]["state"], "swipe_move", "{reply}");
    assert_eq!(reply["gesture"]["window"], 1);
    swipe(&mut h, -50.0, 0.0);
    assert_eq!(h.pinned(1)["screen_rect"], rect(300.0, 200.0, 400.0, 300.0));
    assert_eq!(h.world(2), rect(1400.0, 600.0, 200.0, 100.0));
    // The gesture drives only the drag it installed. The pointer ends that
    // one and begins its own of the same window: the swipe neither moves it
    // nor, when the fingers lift, releases it.
    h.ok(json!({"op":"end_gesture"}));
    begin_drag(&mut h, 1);
    swipe(&mut h, 40.0, 0.0);
    assert_eq!(h.pinned(1)["screen_rect"], rect(300.0, 200.0, 400.0, 300.0));
    end(&mut h);
    assert_eq!(h.drag_to((5.0, 0.0), None), STILL());
    assert_eq!(h.pinned(1)["screen_rect"], rect(305.0, 200.0, 400.0, 300.0));
    h.ok(json!({"op":"end_gesture"}));

    // A pinned widget is grab-proof, like every widget: the gesture finds
    // nothing to move there and pans, and nothing beneath it is reached.
    put(
        &mut h,
        3,
        "app.widget",
        "W",
        rect(1200.0, 700.0, 200.0, 100.0),
    );
    assert_eq!(
        h.ok(json!({"op":"ipc","output":1,"request":{"Pin":{"window":3,"value":true}}}))["reply"],
        json!({"Ok":{"Pin":true}})
    );
    let at = h.pinned(3)["screen_rect"]["origin"].clone();
    let over = point(
        at["x"].as_f64().unwrap() + 10.0,
        at["y"].as_f64().unwrap() + 10.0,
    );
    let reply = h.ok(json!({"op":"gesture_begin","kind":"swipe","fingers":3,"modifiers":chord(""),"context":"window","output":1,"pointer":over,"doubletap":false,"time_ms":2000}));
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(reply["effects"], json!([]), "{reply}");
    h.ok(json!({"op":"gesture_end","cancelled":true,"time_ms":2010}));
}

#[test]
fn a_window_that_closes_under_a_pinned_drag_leaves_no_gesture() {
    let scratch = Scratch::new();
    let mut h = one_pin(&scratch);
    put(&mut h, 2, "app.b", "B", rect(1400.0, 600.0, 200.0, 100.0));
    put(
        &mut h,
        3,
        "app.k",
        "Keep me",
        rect(1300.0, 200.0, 300.0, 200.0),
    );
    pin(&mut h, 3);
    assert_eq!(
        h.pinned(3),
        json!({"output":1,"screen_rect":rect(350.0,300.0,300.0,200.0)})
    );
    // The window goes: the drag goes with it, and the close is logged once
    // for the shell to animate, as any window's is.
    assert_eq!(h.events(), vec![]);
    begin_drag(&mut h, 1);
    assert_eq!(h.drag_to((20.0, 20.0), None), STILL());
    assert_eq!(h.closed(1)["standin"], false);
    assert_eq!(h.events(), vec![(1, "close".to_owned())]);
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(30.0, 30.0)})),
        "no active gesture"
    );
    assert_eq!(h.stack(), vec![2, 3]);
    // The window becomes a stand-in, which is never pinned: it is unpinned
    // under the drag, at the canvas frame its pin showed, and the drag ends.
    begin_drag(&mut h, 3);
    assert_eq!(h.drag_to((-50.0, 40.0), None), STILL());
    assert_eq!(h.pinned(3)["screen_rect"], rect(300.0, 340.0, 300.0, 200.0));
    assert_eq!(h.closed(3)["standin"], true);
    assert_eq!(h.pinned(3), Value::Null);
    assert_eq!(h.world(3), rect(1200.0, 280.0, 300.0, 200.0));
    assert_eq!(
        h.events(),
        vec![(1, "close".to_owned()), (3, "close_to_standin".to_owned())]
    );
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(30.0, 30.0)})),
        "no active gesture"
    );
    // Nothing is left that would refuse the next gesture.
    begin_drag(&mut h, 2);
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(h.snapshot()["trackpad"]["gesture"], Value::Null);
}

const KEPT_SLOTS: &str = r#"
[session]
restore_windows = true

[[window_rules]]
app_id = "app.widget"
widget = true
"#;

#[test]
fn a_pinned_slot_keeps_its_drag_when_its_window_maps_and_loses_it_as_a_stand_in() {
    let scratch = Scratch::new();
    let mut h = one_pin(&scratch);
    load_config(&mut h, &scratch, KEPT_SLOTS);
    let detach = |h: &mut Host, id: u64| {
        let gone = h.window(id)["source"]["identity"].clone();
        h.ok(json!({"op":"remove_source","window":id,"identity":gone,"keep_placeholder":true}));
    };
    let adopt = |h: &mut Host, id: u64, wid: u64, app: &str| {
        h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":"P","buffer":{"width":200,"height":100},"source_rect":rect(NATIVE.0,NATIVE.1,400.0,300.0),"logical_id":id}))
    };
    // A slot whose window is gone for now keeps its pin, and is dragged as
    // the window was.
    detach(&mut h, 1);
    assert_eq!(h.window(1)["source"], Value::Null);
    begin_drag(&mut h, 1);
    assert_eq!(h.drag_to((40.0, 30.0), Some((390.0, 280.0))), STILL());
    assert_eq!(h.pinned(1)["screen_rect"], rect(340.0, 230.0, 400.0, 300.0));
    // Its window maps under the drag: the slot keeps its pin where the drag
    // has it, and the drag goes on.
    assert_eq!(adopt(&mut h, 1, 11, "app.p"), json!({"window":1}));
    assert_eq!(h.pinned(1)["screen_rect"], rect(340.0, 230.0, 400.0, 300.0));
    assert_eq!(h.drag_to((50.0, 30.0), Some((400.0, 280.0))), STILL());
    assert_eq!(h.pinned(1)["screen_rect"], rect(350.0, 230.0, 400.0, 300.0));
    h.ok(json!({"op":"end_gesture"}));
    // A window that maps as a widget ends the drag of its slot, pinned or
    // not: the slot keeps its pin and is a widget.
    put(&mut h, 2, "app.b", "B", rect(1400.0, 600.0, 200.0, 100.0));
    pin(&mut h, 2);
    detach(&mut h, 2);
    begin_drag(&mut h, 2);
    assert_eq!(adopt(&mut h, 2, 12, "app.widget"), json!({"window":2}));
    assert_eq!(h.window(2)["widget"], true);
    assert_eq!(h.pinned(2)["output"], 1);
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(30.0, 30.0)})),
        "no active gesture"
    );
    // A discovery pass that ends under the drag keeps the slot as a stand-in,
    // which is never pinned: it is unpinned there, and the drag ends.
    detach(&mut h, 1);
    begin_drag(&mut h, 1);
    assert_eq!(h.drag_to((20.0, 0.0), None), STILL());
    assert_eq!(h.pinned(1)["screen_rect"], rect(370.0, 230.0, 400.0, 300.0));
    assert_eq!(
        h.ok(json!({"op":"adoption_complete"})),
        json!({"dropped":[],"standins":[1],"dirty":true})
    );
    assert_eq!(h.pinned(1), Value::Null);
    assert_eq!(
        h.error(json!({"op":"gesture_to","screen_delta":point(30.0, 30.0)})),
        "no active gesture"
    );
    // Nothing is left that would refuse the next gesture: the stand-in is a
    // canvas window, and is dragged as one.
    begin_drag(&mut h, 1);
    h.ok(json!({"op":"end_gesture"}));
}

const LAYER_RULES: &str = r#"
[[window_rules]]
app_id = "widget.*"
widget = true

[[window_rules]]
app_id = "pin.*"
pinned_to_screen = true

[[window_rules]]
app_id = "*.top"
layer_order = 5

[[window_rules]]
app_id = "*.under"
layer_order = -1
"#;

/// Upstream orders layer-shell surfaces by `layer_order` and ignores it for a
/// regular window (docs/config.md), which every window here is: the field is
/// read, shown with the rule and named in `not_applied`, and orders nothing.
#[test]
fn layer_order_is_recorded_and_orders_no_window() {
    let scratch = Scratch::new();
    let mut h = running(&scratch, LAYER_RULES);
    // Two of each bucket, overlapping, the ranked one mapped first. Widgets
    // and canvas windows share the world rectangle (100, 100) 300 x 200 and
    // its neighbour; the pinned pair is centered on main by its rule.
    let widgets = rect(100.0, 100.0, 300.0, 200.0);
    let canvas = rect(500.0, 100.0, 300.0, 200.0);
    put(&mut h, 1, "widget.top", "W top", widgets.clone());
    put(&mut h, 2, "widget.plain", "W", widgets);
    put(&mut h, 3, "canvas.top", "C top", canvas.clone());
    put(&mut h, 4, "canvas.under", "C under", canvas);
    appear(&mut h, 5, "pin.top", "P top", (300.0, 200.0));
    appear(&mut h, 6, "pin.plain", "P", (300.0, 200.0));
    let centered = rect(550.0, 400.0, 300.0, 200.0);
    for id in [5, 6] {
        assert_eq!(h.pinned(id), json!({"output":1,"screen_rect":centered}));
    }
    for (id, rank) in [(1, json!(5)), (4, json!(-1)), (5, json!(5))] {
        assert_eq!(h.rule(id)["layer_order"], rank);
        assert_eq!(h.rule(id)["not_applied"], json!(["layer_order"]));
    }
    assert_eq!(h.rule(2)["layer_order"], Value::Null);
    assert_eq!(h.rule(2)["not_applied"], json!([]));
    // Drawn bottom to top in stacking order within each bucket: widgets,
    // canvas windows, pinned windows, the one mapped last on top whatever
    // its rank.
    assert_eq!(h.stack(), vec![1, 2, 3, 4, 5, 6]);
    assert_eq!(h.drawn(1), vec![1, 2, 3, 4, 5, 6]);
    // A hit takes the top of what is drawn: global points are world points
    // plus (200, 100) while the camera is at the origin.
    assert_eq!(h.hit(1, 400.0, 300.0), 2);
    assert_eq!(h.hit(1, 800.0, 300.0), 4);
    assert_eq!(h.hit(1, 700.0, 500.0), 6);
    // A raise is all that reorders: the ranked canvas window, focused, is
    // drawn and hit on top of the one ranked below it and of everything else
    // in its bucket alike.
    h.observe_focus(3);
    assert_eq!(h.drawn(1), vec![1, 2, 4, 3, 5, 6]);
    assert_eq!(h.hit(1, 800.0, 300.0), 3);
    h.observe_focus(4);
    assert_eq!(h.drawn(1), vec![1, 2, 3, 4, 5, 6]);
    let centered = h.ok(
        json!({"op":"action","output":1,"action":"focus-center","pointer":point(800.0, 300.0)}),
    );
    assert_eq!(centered["effects"][0]["window"], 4, "{centered}");
}
