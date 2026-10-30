// SPDX-License-Identifier: GPL-3.0-or-later
//! Fullscreen scenarios cross the exported C ABI and JSON decoder. The test
//! plays the shell's part: it answers every resize effect with a synthetic
//! `native_resize_result`. No native window is resized or drawn, so nothing
//! here is evidence that a real Mac window fills a screen. The scenarios that
//! have an upstream counterpart follow https://github.com/malbiruk/driftwm
//! `352333a8fa1b22171492d4b71a54102045c9a19d` (GPL-3.0-or-later)
//! `src/tests/{fullscreen_centering,fullscreen_handoff,translucent_fullscreen}.rs`,
//! read for the contract and not executed. Config files are written to a
//! throwaway directory; the default config path is never read.
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

struct Host {
    handle: *mut Controller,
    scratch: Scratch,
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
    fn ok(&mut self, command: Value) -> Value {
        let response: Value = serde_json::from_str(&self.raw(command.clone())).unwrap();
        assert_eq!(response["ok"], true, "{command}: {response}");
        response["data"].clone()
    }
    /// A rejected command says why and leaves every bit of state as it was.
    fn error(&mut self, command: Value) -> String {
        let before = self.snapshot();
        let response: Value = serde_json::from_str(&self.raw(command.clone())).unwrap();
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
            "infinify-fullscreen-flow-{}-{}",
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

/// Output 1, `view-a`, and output 2, `view-b`, to its right: global screen
/// rectangles, neither at the global origin and of different sizes.
const A: (f64, f64, f64, f64) = (300.0, 200.0, 1000.0, 800.0);
const B: (f64, f64, f64, f64) = (1300.0, 150.0, 800.0, 600.0);
/// Output 1's usable rectangle in output-local points: asymmetric on purpose.
const USABLE: (f64, f64, f64, f64) = (20.0, 40.0, 960.0, 740.0);
const USABLE_SCREEN_A: (f64, f64, f64, f64) = (A.0 + USABLE.0, A.1 + USABLE.1, USABLE.2, USABLE.3);
const CONFIG: &str = r#"focus_placement = "left"
[snap]
outer_gap = 8.0
[[outputs]]
name = "*"
[outputs.hot_corners]
top_left = "toggle-fullscreen"
[[outputs]]
name = "view-b"
[outputs.hot_corners]
top_left = "toggle-fullscreen"
disable_when_fullscreen = false
[[window_rules]]
app_id = "app.ruled"
fullscreen = true
output = "view-b"
[[window_rules]]
app_id = "app.glass"
opacity = 0.5
[[window_rules]]
app_id = "app.widget"
widget = true
position = [2000, 0]
[[window_rules]]
app_id = "app.pin"
pinned_to_screen = true
position = [100, 100]
"#;
/// Window 1's frame in every scenario.
const START: (f64, f64, f64, f64) = (100.0, 100.0, 400.0, 300.0);
/// Output 1's view in the scenarios that zoom it out: a fractional camera, so
/// that the park is visibly its rounding, and a zoom that is not 1.
const CAMERA: (f64, f64) = (60.6, -41.4);
const PARK: (f64, f64) = (61.0, -41.0);

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn of(r: (f64, f64, f64, f64)) -> Value {
    rect(r.0, r.1, r.2, r.3)
}
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid,"owner":null})
}
/// A window with a bound source at a world frame the caller names. Its
/// native frame has that size and sits somewhere else. Its window rules are
/// resolved; nothing places, focuses or reveals it.
fn attach(h: &mut Host, wid: u64, app: &str, frame: (f64, f64, f64, f64)) {
    let window = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,frame.2,frame.3),"world_rect":of(frame)}))["window"].clone();
    assert_eq!(window, wid);
}
/// A window that appears by itself with output 1 active: adopted or placed.
fn appear(h: &mut Host, wid: u64, app: &str, size: (f64, f64)) -> Value {
    h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":"R","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,size.0,size.1),"output":1}))
}
/// Two outputs, `toml` in force, the launch pass over, and window 1 at
/// `START`, focused. Every request of the capture below was made of exactly
/// this state.
fn fixture(toml: &str) -> Host {
    let handle = driftwm_desktop_create();
    assert!(!handle.is_null());
    let mut h = Host {
        handle,
        scratch: Scratch::new(),
    };
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":of(A),"usable_rect_local":of(USABLE)}));
    h.ok(json!({"op":"register_output","stable_id":"view-b","screen_bounds":of(B)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":of(USABLE),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
    let path = h.scratch.0.join("config.toml");
    std::fs::write(&path, toml).unwrap();
    let reply = h.ok(json!({"op":"load_config","path":path}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    h.ok(json!({"op":"tick_navigation","timestamp_ns":1_000_000_000u64}));
    h.ok(json!({"op":"adoption_complete"}));
    attach(&mut h, 1, "app.1", START);
    h.ok(json!({"op":"focus","window":1}));
    h
}
/// The supported native readback capability.
fn capable(toml: &str) -> Host {
    let mut h = fixture(toml);
    assert_eq!(
        h.ok(json!({"op":"native_resize_capability","enabled":true})),
        json!({})
    );
    h
}
/// Output 1 zoomed out to 0.5 around its own corner and panned to `CAMERA`.
fn zoomed(toml: &str) -> Host {
    let mut h = capable(toml);
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":A.0,"y":A.1}}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":30.3,"y":-20.7}}));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    h
}
fn view(camera: (f64, f64), zoom: f64) -> Value {
    json!({"camera":{"x":camera.0,"y":camera.1},"zoom":zoom})
}
fn output(h: &mut Host, id: u64) -> Value {
    let outputs = h.snapshot()["outputs"].clone();
    let found = outputs.as_array().unwrap().iter().find(|o| o["id"] == id);
    found.unwrap_or_else(|| panic!("no output {id}")).clone()
}
fn pose(h: &mut Host, id: u64) -> Value {
    let output = output(h, id);
    json!({"camera":output["camera"],"zoom":output["zoom"]})
}
/// The snapshot's per-output `fullscreen`.
fn fullscreen(h: &mut Host, id: u64) -> Value {
    output(h, id)["fullscreen"].clone()
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
/// The windows placed on one output, bottom to top.
fn placed(h: &mut Host, id: u64) -> Vec<Value> {
    let placements = h.snapshot()["placements"].clone();
    let on = placements.as_array().unwrap().iter();
    on.filter(|p| p["output"] == id).cloned().collect()
}
fn placed_ids(h: &mut Host, id: u64) -> Vec<u64> {
    let ids = placed(h, id);
    ids.iter().map(|p| p["window"].as_u64().unwrap()).collect()
}
fn action(h: &mut Host, output: u64, action: &str) -> Value {
    h.ok(json!({"op":"action","output":output,"action":action}))
}
fn ipc(h: &mut Host, request: Value) -> Value {
    h.ok(json!({"op":"ipc","output":1,"request":request}))
}
fn state(h: &mut Host) -> Value {
    ipc(h, json!("State"))["reply"]["Ok"]["State"].clone()
}
fn hit(h: &mut Host, output: u64, at: (f64, f64)) -> Value {
    h.ok(json!({"op":"hit","output":output,"screen":{"x":at.0,"y":at.1}}))["hit"]["window"].clone()
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
    let frame = rect(4000.0, 3000.0, size.0, size.1);
    answer_frame(h, effect, outcome, attempted, frame)
}
fn answer_frame(
    h: &mut Host,
    effect: &Value,
    outcome: &str,
    attempted: bool,
    frame: Value,
) -> Value {
    let requested = if effect["requested"].is_null() {
        json!({"width":0.0,"height":0.0})
    } else {
        effect["requested"].clone()
    };
    h.ok(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":outcome,"ax_error":0,"mutation_attempted":attempted,"observed":true,"requested":requested,"actual_ax":frame,"actual_cg":frame}}))
}
/// Answer one resize effect with no observation behind it: the adapter could
/// not reach the window, and nothing was asked of it.
fn unanswered(h: &mut Host, effect: &Value, outcome: &str) -> Value {
    let gone = rect(0.0, 0.0, 0.0, 0.0);
    let requested = if effect["requested"].is_null() {
        json!({"width":0.0,"height":0.0})
    } else {
        effect["requested"].clone()
    };
    h.ok(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":outcome,"ax_error":0,"mutation_attempted":false,"observed":false,"requested":requested,"actual_ax":gone,"actual_cg":gone}}))
}
/// Play the shell's part for the transaction whose first effect is `read`:
/// the baseline read finds `from`, the setter is asked for `asks` and the
/// window takes `took`, and the final read finds the same.
fn perform(
    h: &mut Host,
    read: &Value,
    from: (f64, f64),
    asks: (f64, f64),
    outcome: &str,
    took: (f64, f64),
) {
    assert_eq!(read["op"], "observe_resize_source", "{read}");
    let setter = answer(h, read, "observed", false, from)["effect"].clone();
    assert_eq!(setter["op"], "resize_native_window", "{setter}");
    assert_eq!(setter["requested"], json!({"width":asks.0,"height":asks.1}));
    if setter["native_origin"].is_object() {
        assert!(setter.get("native_action").is_none());
    }
    let last = answer(h, &setter, outcome, true, took)["effect"].clone();
    assert_eq!(last["op"], "observe_resize_source", "{last}");
    assert_eq!(
        answer(h, &last, "observed", false, took)["effect"],
        Value::Null
    );
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["phase"], "complete", "{slot}");
}
/// `perform` for the transaction an action-shaped reply carries.
fn deliver(
    h: &mut Host,
    reply: &Value,
    from: (f64, f64),
    asks: (f64, f64),
    outcome: &str,
    took: (f64, f64),
) {
    let read = began(h, reply);
    perform(h, &read, from, asks, outcome, took);
}
/// `deliver` for a request that may ask for the size the window already has.
/// v0.20's fit is the whole usable area, which is also the size this fixture's
/// fullscreen asks for, so a toggle between the two changes no size: the reply
/// then begins no transaction and the window is placed at once.
fn deliver_unless_unchanged(
    h: &mut Host,
    reply: &Value,
    from: (f64, f64),
    asks: (f64, f64),
    outcome: &str,
    took: (f64, f64),
) {
    if reply["effect"].is_object() {
        deliver(h, reply, from, asks, outcome, took);
    } else {
        assert_eq!(from, asks, "{reply}");
        assert_eq!(h.snapshot()["native_resize"]["pending_effect"], Value::Null);
    }
}
/// Window 1 fullscreen on output 1, having taken the size it was offered.
fn entered(h: &mut Host) {
    let reply = action(h, 1, "toggle-fullscreen");
    deliver(
        h,
        &reply,
        (START.2, START.3),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
}

fn enter_at_native_frame(h: &mut Host, original: &Value, fullscreen_frame: &Value, outcome: &str) {
    let reply = action(h, 1, "toggle-fullscreen");
    let read = began(h, &reply);
    let setter = answer_frame(h, &read, "observed", false, original.clone())["effect"].clone();
    assert_eq!(setter["native_origin"], Value::Null);
    let last = answer_frame(h, &setter, outcome, true, fullscreen_frame.clone())["effect"].clone();
    answer_frame(h, &last, "observed", false, fullscreen_frame.clone());
}

fn restore_at_native_frame(h: &mut Host, reply: &Value, current: &Value, original: &Value) {
    let read = began(h, reply);
    let setter = answer_frame(h, &read, "observed", false, current.clone())["effect"].clone();
    assert_eq!(setter["native_origin"], original["origin"]);
    assert_eq!(setter["requested"], original["size"]);
    let last = answer_frame(h, &setter, "applied", true, original.clone())["effect"].clone();
    answer_frame(h, &last, "observed", false, original.clone());
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
}

#[test]
fn fullscreen_restores_the_fresh_native_origin_separately_from_world_and_camera() {
    let mut h = zoomed(CONFIG);
    let original = rect(183.5, 211.25, START.2, START.3);
    let enlarged = rect(0.0, 30.0, USABLE.2, USABLE.3);
    enter_at_native_frame(&mut h, &original, &enlarged, "applied");
    let reply = action(&mut h, 1, "toggle-fullscreen");
    restore_at_native_frame(&mut h, &reply, &enlarged, &original);
    assert_eq!(window(&mut h, 1)["source"]["observed_rect"], original);
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
}

#[test]
fn fullscreen_restores_the_native_size_from_its_fresh_baseline() {
    let mut h = zoomed(CONFIG);
    // A native resize happened before the shell published its next observation.
    let original = rect(183.5, 211.25, 427.5, 316.25);
    let enlarged = rect(0.0, 30.0, USABLE.2, USABLE.3);
    enter_at_native_frame(&mut h, &original, &enlarged, "applied");
    let reply = action(&mut h, 1, "toggle-fullscreen");
    restore_at_native_frame(&mut h, &reply, &enlarged, &original);
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, 427.5, 316.25));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
}

#[test]
fn leaving_before_the_enter_baseline_preserves_the_fresh_native_frame_without_a_setter() {
    let mut h = zoomed(CONFIG);
    let original = rect(183.5, 211.25, 427.5, 316.25);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    action(&mut h, 1, "toggle-fullscreen");
    let reply = answer_frame(&mut h, &read, "observed", false, original.clone());
    assert_eq!(reply["effect"], Value::Null);
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(window(&mut h, 1)["source"]["observed_rect"], original);
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, 427.5, 316.25));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(ipc(&mut h, json!("State"))["effect"], Value::Null);
}

#[test]
fn fullscreen_restores_native_origin_even_when_the_owner_kept_its_original_size() {
    let mut h = zoomed(CONFIG);
    let original = rect(183.5, 211.25, START.2, START.3);
    let relocated = rect(0.0, 30.0, START.2, START.3);
    enter_at_native_frame(&mut h, &original, &relocated, "rejected");
    let reply = action(&mut h, 1, "toggle-fullscreen");
    restore_at_native_frame(&mut h, &reply, &relocated, &original);
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
}

#[test]
fn cancelling_a_fullscreen_setter_drains_it_then_restores_the_native_frame() {
    let mut h = zoomed(CONFIG);
    let original = rect(183.5, 211.25, START.2, START.3);
    let enlarged = rect(0.0, 30.0, USABLE.2, USABLE.3);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer_frame(&mut h, &read, "observed", false, original.clone())["effect"].clone();
    h.ok(json!({"op":"cancel_native_resize","transaction":read["transaction"]}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    let last = answer_frame(&mut h, &setter, "applied", true, enlarged.clone())["effect"].clone();
    let reply = answer_frame(&mut h, &last, "observed", false, enlarged.clone());
    restore_at_native_frame(&mut h, &reply, &enlarged, &original);
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
}

#[test]
fn a_refused_native_origin_is_not_counted_as_restored_or_allowed_as_applied() {
    let mut h = zoomed(CONFIG);
    let original = rect(183.5, 211.25, START.2, START.3);
    let relocated = rect(0.0, 30.0, START.2, START.3);
    enter_at_native_frame(&mut h, &original, &relocated, "rejected");
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter =
        answer_frame(&mut h, &read, "observed", false, relocated.clone())["effect"].clone();
    let before = h.snapshot();
    let raw = h.raw(json!({"op":"native_resize_result","transaction":setter["transaction"],"effect_id":setter["effect_id"],"identity":setter["identity"],"generation":setter["generation"],"result":{"outcome":"applied","ax_error":0,"mutation_attempted":true,"observed":true,"requested":setter["requested"],"actual_ax":relocated,"actual_cg":relocated}}));
    assert_eq!(serde_json::from_str::<Value>(&raw).unwrap()["ok"], false);
    assert_eq!(h.snapshot(), before);
    let last = answer_frame(&mut h, &setter, "rejected", true, relocated.clone())["effect"].clone();
    answer_frame(&mut h, &last, "observed", false, relocated.clone());
    let retry = ipc(&mut h, json!("State"));
    restore_at_native_frame(&mut h, &retry, &relocated, &original);
    assert_eq!(world(&mut h, 1), of(START));
}

#[test]
fn fullscreen_restore_keeps_the_native_origin_owed_until_the_final_read() {
    let mut h = zoomed(CONFIG);
    let original = rect(183.5, 211.25, START.2, START.3);
    let enlarged = rect(0.0, 30.0, USABLE.2, USABLE.3);
    let relocated = rect(0.0, 30.0, START.2, START.3);
    enter_at_native_frame(&mut h, &original, &enlarged, "applied");
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer_frame(&mut h, &read, "observed", false, enlarged.clone())["effect"].clone();
    let last = answer_frame(&mut h, &setter, "applied", true, original.clone())["effect"].clone();
    // The application changes its placement after the setter's readback.
    answer_frame(&mut h, &last, "observed", false, relocated.clone());
    let retry = ipc(&mut h, json!("State"));
    restore_at_native_frame(&mut h, &retry, &relocated, &original);
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
}

#[test]
fn a_failed_final_restore_read_requires_fresh_confirmation() {
    let mut h = zoomed(CONFIG);
    let original = rect(183.5, 211.25, START.2, START.3);
    let enlarged = rect(0.0, 30.0, USABLE.2, USABLE.3);
    enter_at_native_frame(&mut h, &original, &enlarged, "applied");
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer_frame(&mut h, &read, "observed", false, enlarged)["effect"].clone();
    let last = answer_frame(&mut h, &setter, "applied", true, original.clone())["effect"].clone();
    unanswered(&mut h, &last, "readback_failed");
    let retry = ipc(&mut h, json!("State"));
    let read = began(&mut h, &retry);
    assert_eq!(read["op"], "observe_resize_source");
    let reply = answer_frame(&mut h, &read, "observed", false, original);
    assert_eq!(reply["effect"], Value::Null);
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(ipc(&mut h, json!("State"))["effect"], Value::Null);
}

#[test]
fn cursor_transfer_without_active_output_exits_fullscreen_on_first_display() {
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let target = pose(&mut h, 2);
    let reply = h.ok(json!({"op":"action","output":null,"action":"send-cursor-to-output right"}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(pose(&mut h, 2), target);
    assert!(reply["effects"].as_array().unwrap().iter().any(|effect| {
        effect == &json!({"op":"warp_pointer","screen":{"x":B.0+B.2/2.0,"y":B.1+B.3/2.0},"output":2})
    }), "{reply}");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (START.2, START.3),
        "applied",
        (START.2, START.3),
    );
    assert_eq!(world(&mut h, 1), of(START));
}
/// Tick until every flight has landed. One clock serves every controller:
/// each only needs its own timestamps to grow.
fn settle(h: &mut Host) {
    static CLOCK: AtomicU64 = AtomicU64::new(2_000_000_000);
    for _ in 0..600 {
        let now = CLOCK.fetch_add(16_666_667, Ordering::Relaxed);
        let tick = h.ok(json!({"op":"tick_navigation","timestamp_ns":now}));
        if tick["needs_frames"] == false {
            return;
        }
    }
    panic!("flight did not settle");
}
const NOTHING: &str = r#"{"navigation":null,"effects":[],"dirty":false}"#;
fn nothing() -> Value {
    serde_json::from_str(NOTHING).unwrap()
}

fn decoration(h: &mut Host, id: u64, output: u64, action: &str) -> Value {
    let source = window(h, id)["source"].clone();
    h.ok(json!({"op":"native_decoration","window":id,"output":output,
        "identity":source["identity"],"generation":source["generation"],"action":action}))
}

#[test]
fn native_decoration_fill_and_restore_are_directional_and_exact_targeted() {
    let mut h = zoomed(CONFIG);
    attach(&mut h, 2, "app.2", (900.0, 600.0, 200.0, 100.0));
    h.ok(json!({"op":"focus","window":2}));
    let original = world(&mut h, 1);
    let other = world(&mut h, 2);
    let original_view = pose(&mut h, 2);
    let reply = decoration(&mut h, 1, 2, "fill");
    assert_eq!(fullscreen(&mut h, 2)["window"], 1);
    let pending = h.snapshot();
    assert_eq!(decoration(&mut h, 1, 1, "fill"), nothing());
    assert_eq!(
        h.snapshot(),
        pending,
        "repeated Fill must not exit or retarget"
    );
    deliver(
        &mut h,
        &reply,
        (START.2, START.3),
        (B.2, B.3),
        "applied",
        (B.2, B.3),
    );
    let filled = h.snapshot();
    assert_eq!(decoration(&mut h, 1, 2, "fill"), nothing());
    assert_eq!(h.snapshot(), filled);
    assert_eq!(decoration(&mut h, 2, 2, "restore"), nothing());
    assert_eq!(
        h.snapshot(),
        filled,
        "Restore must not exit a different window"
    );
    let reply = decoration(&mut h, 1, 1, "restore");
    assert_eq!(fullscreen(&mut h, 2), Value::Null);
    let pending = h.snapshot();
    assert_eq!(decoration(&mut h, 1, 2, "restore"), nothing());
    assert_eq!(h.snapshot(), pending);
    deliver(
        &mut h,
        &reply,
        (B.2, B.3),
        (START.2, START.3),
        "applied",
        (START.2, START.3),
    );
    assert_eq!(world(&mut h, 1), original);
    assert_eq!(world(&mut h, 2), other);
    assert_eq!(pose(&mut h, 2), original_view);
    let restored = h.snapshot();
    assert_eq!(decoration(&mut h, 1, 2, "restore"), nothing());
    assert_eq!(h.snapshot(), restored, "repeated Restore must not enter");
}

#[test]
fn native_decoration_center_uses_exact_target_and_canonical_navigation_without_sizing() {
    let mut h = fixture(CONFIG); // Center needs no native resize capability.
    attach(&mut h, 2, "app.2", (900.0, 600.0, 200.0, 100.0));
    let expected = action(&mut h, 2, "center-window");
    h.ok(json!({"op":"focus","window":2}));
    let before = [world(&mut h, 1), world(&mut h, 2)];
    let source = window(&mut h, 1)["source"].clone();
    let reply = decoration(&mut h, 1, 2, "center");
    assert_eq!(reply["effects"][0]["window"], 1);
    assert_eq!(reply["effects"][0]["identity"], source["identity"]);
    assert_eq!(reply["navigation"]["output"], 2);
    assert_eq!(
        reply["navigation"]["target_camera"],
        expected["navigation"]["target_camera"]
    );
    assert_eq!(
        reply["navigation"]["target_zoom"],
        expected["navigation"]["target_zoom"]
    );
    assert!(reply.get("transaction").is_none());
    assert_eq!([world(&mut h, 1), world(&mut h, 2)], before);
}

#[test]
fn native_decoration_directional_actions_preserve_pin_and_widget_rules() {
    let mut h = capable(CONFIG);
    attach(&mut h, 2, "app.widget", (500.0, 100.0, 300.0, 200.0));
    for action in ["fill", "restore"] {
        let before = h.snapshot();
        assert_eq!(decoration(&mut h, 2, 1, action), nothing());
        assert_eq!(h.snapshot(), before);
    }
    let before_view = pose(&mut h, 1);
    let reply = decoration(&mut h, 2, 1, "center");
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(pose(&mut h, 1), before_view);
    h.ok(json!({"op":"focus","window":1}));
    action(&mut h, 1, "toggle-pin-to-screen");
    let pin = window(&mut h, 1)["pinned"].clone();
    let reply = decoration(&mut h, 1, 1, "center");
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(pose(&mut h, 1), before_view);
    let reply = decoration(&mut h, 1, 1, "fill");
    assert_eq!(window(&mut h, 1)["pinned"], Value::Null);
    deliver(
        &mut h,
        &reply,
        (START.2, START.3),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    let reply = decoration(&mut h, 1, 1, "restore");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (START.2, START.3),
        "applied",
        (START.2, START.3),
    );
    assert_eq!(window(&mut h, 1)["pinned"], pin);
}

#[test]
fn native_decoration_directional_actions_reject_stale_bindings() {
    let mut h = capable(CONFIG);
    let source = window(&mut h, 1)["source"].clone();
    for action in ["fill", "restore", "center"] {
        for (identity, generation) in [
            (identity(99), source["generation"].clone()),
            (identity(1), json!(0)),
        ] {
            h.error(json!({"op":"native_decoration","window":1,"output":1,
                "identity":identity,"generation":generation,"action":action}));
        }
    }
}

// Captured from the tree before this milestone, built apart and asked the
// same requests of the same state: every literal below is the exact response
// the C ABI returned then. First from c5dd6fb, the tree the milestone was
// written on, and again from 6333dde, the tree it was merged into, which
// answered every one of them the same but `KEY`: a key binding's entry had
// gained `passable` there (pass-through). MOUSE and KEY now exercise the
// accepted Command-based desktop `mod` chord; the fullscreen refusal contract
// remains the historical one.
#[test]
fn without_the_capability_fullscreen_answers_as_it_did_before() {
    const ACTION: &str = r#"{"error":"action not implemented on macOS yet: toggle-fullscreen","ok":false,"version":1}"#;
    const IPC: &str = r#"{"data":{"dirty":false,"effects":[],"navigation":null,"reply":{"Err":"action not implemented on macOS yet: toggle-fullscreen"}},"ok":true,"version":1}"#;
    // v0.20: mod+middle is fill-window; fullscreen is on mod+f only.
    const MOUSE: &str = r#"{"data":{"binding":{"action":"fill-window","combo":"mod+middle","implemented":false,"kind":"action","mouse_speed":1.0,"trackpad_speed":1.5,"zoom_mouse_speed":1.0,"zoom_step":1.1,"zoom_trackpad_speed":1.0}},"ok":true,"version":1}"#;
    const BEGIN: &str = r#"{"data":{"dirty":false,"effects":[],"fired":null,"gesture":{"bindings":[{"action":"toggle-fullscreen","combo":"alt+3-finger-pinch-in","implemented":false},{"action":"toggle-fullscreen","combo":"alt+3-finger-pinch-out","implemented":false}],"output":1,"state":"pinch_threshold","window":null},"navigation":null,"needs_frames":false,"note":null,"trackpad":true},"ok":true,"version":1}"#;
    const UPDATE: &str = r#"{"data":{"dirty":false,"effects":[],"fired":{"action":"toggle-fullscreen","error":"action not implemented on macOS yet: toggle-fullscreen"},"gesture":{"output":1,"state":"pinch_threshold","window":null},"navigation":null,"needs_frames":false,"note":null,"trackpad":true},"ok":true,"version":1}"#;
    const END: &str = r#"{"data":{"dirty":false,"effects":[],"fired":null,"gesture":{"cancelled":false,"output":1,"state":"pinch_threshold","window":null},"navigation":null,"needs_frames":false,"note":null,"trackpad":true},"ok":true,"version":1}"#;
    const STATE: &str = r#"{"data":{"dirty":false,"effects":[],"navigation":null,"reply":{"Ok":{"State":{"active_bookmark":null,"camera":[500.0,-400.0],"canvas_layers":[],"fullscreen":[],"layers":[],"layout":"","layout_short":"","outputs":[{"active":true,"active_bookmark":null,"camera":[500.0,-400.0],"name":"view-a","size":[1000,800],"zoom":1.0},{"active":false,"active_bookmark":null,"camera":[400.0,-300.0],"name":"view-b","size":[800,600],"zoom":1.0}],"pinned":[],"windows":[{"app_id":"app.1","id":1,"is_focused":true,"is_widget":false,"mode":"Normal","pid":123,"position":[300,-250],"size":[400,300],"suspended":false,"title":"fixture"}],"zoom":1.0}}}},"ok":true,"version":1}"#;
    const KEY: &str = r#"{"action":"toggle-fullscreen","character":"f","chord":"⌘F","combo":"mod+f","implemented":false,"key_code":3,"modifiers":{"command":true,"control":false,"option":false,"shift":false},"passable":true,"repeat":false}"#;
    const ATTACH: &str = r#"{"data":{"adopted":false,"background":false,"dirty":true,"effect":{"effect_id":2,"generation":2,"identity":{"birth_sec":1800000000,"birth_usec":0,"owner":null,"pid":123,"wid":2},"op":"focus_native_window","window":2},"navigation":{"animating":true,"generation":1,"output":1,"target_camera":{"x":0.0,"y":0.0},"target_zoom":1.0},"window":2},"ok":true,"version":1}"#;
    const RULE: &str = r#"{"blur":false,"border_color":null,"border_color_focused":null,"border_width":null,"corner_radius":null,"decoration":null,"focus_on_open":null,"fullscreen":true,"layer_order":null,"not_applied":["fullscreen"],"opacity":null,"output":"view-b","pass_keys":"none","pass_mouse":"none","pinned_to_screen":false,"position":null,"preserve_aspect_ratio":false,"restore_windows":null,"shadow":null,"size":null,"suspend_on_close":null,"widget":false}"#;
    // Freeze the historical placement and Command chords behind the exact reply literals.
    // v0.20 unbound upstream's alt+3-finger pinch fullscreen toggle; the file
    // binds it again so the historical refusal is still exercised.
    let config = format!(
        "window_placement = \"center\"\n{CONFIG}[gestures.on-window]\n\"alt+3-finger-pinch-in\" = \"toggle-fullscreen\"\n\"alt+3-finger-pinch-out\" = \"toggle-fullscreen\"\n"
    );
    let mut h = fixture(&config);
    h.ok(json!({"op":"set_platform","super":"cmd"}));
    let option = json!({"control":false,"option":true,"shift":false,"command":false});
    // Sent or not, false is the default: a bare shell and one that says so.
    for explicit in [false, true] {
        if explicit {
            h.ok(json!({"op":"native_resize_capability","enabled":false}));
        }
        let before = h.snapshot();
        assert_eq!(
            h.raw(json!({"op":"action","output":1,"action":"toggle-fullscreen"})),
            ACTION
        );
        assert_eq!(
            h.raw(json!({"op":"ipc","output":1,"request":{"Action":"toggle-fullscreen"}})),
            IPC
        );
        // The corner's action is refused like the key's.
        assert_eq!(
            h.raw(json!({"op":"hot_corner","output":1,"corner":"top_left"})),
            ACTION
        );
        assert_eq!(
            h.raw(json!({"op":"mouse_binding","trigger":"middle","modifiers":{"control":false,"option":false,"shift":false,"command":true},"context":"window"})),
            MOUSE
        );
        assert_eq!(
            h.raw(json!({"op":"gesture_begin","kind":"pinch","fingers":3,"modifiers":option,"context":"window","output":1,"pointer":{"x":500.0,"y":400.0},"time_ms":10.0})),
            BEGIN
        );
        assert_eq!(
            h.raw(json!({"op":"gesture_update","scale":0.5,"time_ms":20.0})),
            UPDATE
        );
        assert_eq!(h.raw(json!({"op":"gesture_end","time_ms":30.0})), END);
        assert_eq!(
            h.raw(json!({"op":"ipc","output":1,"request":"State"})),
            STATE
        );
        let keys = h.ok(json!({"op":"bindings"}))["keys"].clone();
        let keys: Vec<String> = keys
            .as_array()
            .unwrap()
            .iter()
            .filter(|k| k["action"] == "toggle-fullscreen")
            .map(Value::to_string)
            .collect();
        assert_eq!(keys, [KEY]);
        // Nothing of it changed anything.
        assert_eq!(h.snapshot(), before);
    }
    // A rule's `fullscreen` and `output` are recorded and not applied: the
    // window is placed, focused and flown to like any other.
    assert_eq!(
        h.raw(json!({"op":"attach","identity":identity(2),"bundle_id":"app.ruled","title":"R","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,400.0,300.0),"output":1})),
        ATTACH
    );
    let ruled = window(&mut h, 2);
    assert_eq!(ruled["rule"].to_string(), RULE);
    assert_eq!(ruled["mode"], Value::Null);
    assert_eq!(ruled["world_rect"], rect(28.0, 260.0, 400.0, 300.0));
    // The snapshot's own addition says the same: no output is fullscreen.
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(fullscreen(&mut h, 2), Value::Null);
    assert_eq!(h.snapshot()["placements"].as_array().unwrap().len(), 4);
}

// Upstream enter_fullscreen and exit_fullscreen_on, on an output that is
// zoomed out at a fractional camera, with a second window on the canvas and a
// second output whose camera shows the same canvas.
#[test]
fn a_toggle_fills_the_output_and_a_second_restores_everything_exactly() {
    let mut h = zoomed(CONFIG);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    // Before: both windows are on both outputs.
    assert_eq!(placed_ids(&mut h, 1), [1, 2]);
    assert_eq!(placed_ids(&mut h, 2), [1, 2]);
    let other = output(&mut h, 2);

    let reply = action(&mut h, 1, "toggle-fullscreen");
    // The reply is a sizing action's: the focus request among `effects`, and
    // the transaction under the keys the shell's size hook reads.
    assert_eq!(reply["dirty"], true);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(reply["effects"][0]["op"], "focus_native_window");
    assert_eq!(reply["effects"][0]["window"], 1);
    // The output is fullscreen at once, as upstream marks it before its
    // configure: parked at the rounded camera and zoom 1.
    assert_eq!(
        fullscreen(&mut h, 1),
        json!({"window":1,"backdrop":"black"})
    );
    assert_eq!(pose(&mut h, 1), view(PARK, 1.0));
    assert_eq!(mode(&mut h, 1), "fullscreen");
    // Until the window answers it keeps its size, at the parked corner: an
    // unanswered offer is not centred.
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, 400.0, 300.0)
    );
    let alone = placed(&mut h, 1);
    assert_eq!(alone.len(), 1);
    assert_eq!(alone[0]["window"], 1);
    assert_eq!(alone[0]["fullscreen"], true);
    assert_eq!(
        alone[0]["screen_rect"],
        rect(A.0 + USABLE.0, A.1 + USABLE.1, 400.0, 300.0)
    );
    // The shell performs the transaction: the usable area below the menu.
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, USABLE.2, USABLE.3)
    );
    let alone = placed(&mut h, 1);
    assert_eq!(alone.len(), 1);
    assert_eq!(alone[0]["fullscreen"], true);
    // The output's own rectangle in global screen points, at zoom 1.
    assert_eq!(alone[0]["screen_rect"], of(USABLE_SCREEN_A));
    assert_eq!(alone[0]["clip_rect"], of(USABLE_SCREEN_A));
    assert_eq!(
        alone[0]["world_local_crop"],
        rect(0.0, 0.0, USABLE.2, USABLE.3)
    );
    // Upstream's DrawnChrome for a fullscreen window: all of it shed.
    let bare = &alone[0]["decoration"];
    assert_eq!(bare["mode"], "none");
    assert_eq!(bare["border_width"], 0);
    assert_eq!(bare["corner_radius"], 0);
    assert_eq!(bare["shadow"], false);
    assert_eq!(bare["opacity"], 1.0);
    // The other output is as it was, less the fullscreen window, which is
    // shown on its own output only although this camera covers its canvas.
    let after = output(&mut h, 2);
    assert_eq!(after, other);
    assert_eq!(after["fullscreen"], Value::Null);
    assert_eq!(placed_ids(&mut h, 2), [2]);
    assert!(placed(&mut h, 2)[0].get("fullscreen").is_none());
    // Upstream's State: the window is under `fullscreen`, not `windows`.
    let reported = state(&mut h);
    assert_eq!(
        reported["fullscreen"],
        json!([{"id":1,"output":"view-a","app_id":"app.1","title":"fixture","pid":123}])
    );
    let listed: Vec<&Value> = reported["windows"].as_array().unwrap().iter().collect();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0]["id"], 2);
    // A fullscreen window has no canvas place or size to write, and its pin
    // is the exit's to put back.
    for request in [
        json!({"Move":{"window":1,"to":[0,0]}}),
        json!({"Resize":{"window":1,"to":[500,400]}}),
        json!({"Pin":{"window":1,"value":true}}),
    ] {
        let refused = ipc(&mut h, request.clone())["reply"]["Err"].clone();
        assert!(
            refused.as_str().is_some_and(|e| e.contains("fullscreen")),
            "{request}: {refused}"
        );
    }
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, USABLE.2, USABLE.3)
    );

    // The second press: place, camera and zoom are back at once, and the size
    // is asked back.
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(reply["dirty"], true);
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    // Entering raised it, as upstream's does; nothing lowers it again.
    assert_eq!(placed_ids(&mut h, 1), [2, 1]);
    assert_eq!(placed_ids(&mut h, 2), [2, 1]);
    assert_eq!(output(&mut h, 2), other);
    assert_eq!(state(&mut h)["fullscreen"], json!([]));
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
}

// Adapted from upstream src/tests/fullscreen_centering.rs. macOS fullscreen
// keeps the usable top-left even when the owner grants a different size;
// the requested size and exact exit restoration are unchanged.
#[test]
fn a_window_that_takes_another_size_stays_at_the_usable_top_left() {
    // A clamped answer: 800 x 600 inside the 960 x 740 usable area.
    let mut h = zoomed(CONFIG);
    attach(&mut h, 2, "app.2", (70.0, -30.0, 120.0, 90.0));
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    // The baseline read is no answer to the offer: still at the parked corner.
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, 400.0, 300.0)
    );
    let last = answer(&mut h, &setter, "clamped", true, (800.0, 600.0))["effect"].clone();
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, 800.0, 600.0)
    );
    answer(&mut h, &last, "observed", false, (800.0, 600.0));
    let alone = placed(&mut h, 1);
    assert_eq!(alone.len(), 1);
    assert_eq!(
        alone[0]["screen_rect"],
        rect(A.0 + USABLE.0, A.1 + USABLE.1, 800.0, 600.0)
    );
    // Under-fill alone conceals the canvas all the same.
    assert_eq!(fullscreen(&mut h, 1)["backdrop"], "black");
    // What is drawn is what is hit: the output's center reaches the window,
    // and the band it leaves reaches nothing, not even the window that lies
    // there on the canvas.

    assert_eq!(hit(&mut h, 1, (A.0 + 500.0, A.1 + 400.0)), 1);
    assert_eq!(hit(&mut h, 1, (A.0 + 21.0, A.1 + 41.0)), 1);
    assert_eq!(hit(&mut h, 1, (A.0 + 900.0, A.1 + 700.0)), Value::Null);
    assert_eq!(hit(&mut h, 1, (A.0 + 20.0, A.1 + 20.0)), Value::Null);
    // The exit restores the exact place it had before fullscreen.
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, 800.0, 600.0));
    deliver(
        &mut h,
        &reply,
        (800.0, 600.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));

    // An answer larger than the output clamps to no offset at all.
    let mut h = zoomed(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "clamped",
        (1200.0, 900.0),
    );
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, 1200.0, 900.0)
    );
    let alone = placed(&mut h, 1);
    assert_eq!(
        alone[0]["screen_rect"],
        rect(A.0 + USABLE.0, A.1 + USABLE.1, 1200.0, 900.0)
    );
    assert_eq!(alone[0]["clip_rect"], of(USABLE_SCREEN_A));

    // A window that refuses the size keeps the same usable top-left.
    // The exit confirms its native frame without issuing another setter.
    let mut h = zoomed(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "rejected",
        (400.0, 300.0),
    );
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, 400.0, 300.0)
    );
    assert_eq!(
        placed(&mut h, 1)[0]["screen_rect"],
        rect(A.0 + USABLE.0, A.1 + USABLE.1, 400.0, 300.0)
    );
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    assert_eq!(
        answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"],
        Value::Null
    );
    assert_eq!(reply["dirty"], true);
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
}

// Upstream execute_action's guard, by its own list: what ends a fullscreen
// first and what runs during it.
#[test]
fn an_action_ends_fullscreen_first_unless_upstream_runs_it_during_one() {
    // spawn runs during fullscreen; exec ends it.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "spawn true");
    assert_eq!(reply["effects"][0]["op"], "exec");
    assert_eq!(reply["dirty"], false);
    assert!(reply.get("transaction").is_none());
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    let reply = action(&mut h, 1, "exec true");
    assert_eq!(reply["effects"][0]["op"], "exec");
    assert_eq!(reply["dirty"], true);
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));

    // A navigation action runs on the restored canvas: the camera it flies
    // from is the one from before the fullscreen.
    let mut h = zoomed(CONFIG);
    attach(&mut h, 2, "app.2", (1900.0, 100.0, 300.0, 200.0));
    entered(&mut h);
    let reply = action(&mut h, 1, "center-nearest right");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(reply["navigation"]["animating"], true);
    assert_eq!(reply["navigation"]["target_zoom"], 0.5);
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));

    // A camera action, and the IPC camera and zoom writes. A read ends
    // nothing, and neither does a malformed write.
    for request in [
        json!({"Camera":null}),
        json!({"Zoom":null}),
        json!({"Zoom":-1.0}),
    ] {
        let mut h = zoomed(CONFIG);
        entered(&mut h);
        ipc(&mut h, request);
        assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    }
    for request in [json!({"Camera":[10.0, 20.0]}), json!({"Zoom":0.8})] {
        let mut h = zoomed(CONFIG);
        entered(&mut h);
        let reply = ipc(&mut h, request.clone());
        assert_eq!(fullscreen(&mut h, 1), Value::Null, "{request}");
        assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
        assert_eq!(reply["dirty"], true);
        assert_eq!(reply["navigation"]["animating"], true);
        deliver(
            &mut h,
            &reply,
            (USABLE.2, USABLE.3),
            (400.0, 300.0),
            "applied",
            (400.0, 300.0),
        );
    }
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "zoom-in");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(reply["navigation"]["animating"], true);
    assert!(reply["effect"].is_object());

    // An action on another output leaves this one's fullscreen alone, and so
    // does one that upstream runs during fullscreen.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    action(&mut h, 2, "zoom-in");
    action(&mut h, 1, "toggle-cursor-pan");
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    // A refused action is rolled back with the exit its guard made.
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"no-such-action"})),
        "unknown action: no-such-action"
    );
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
}

// The pointer's and the trackpad's ways out, and the camera lock: upstream's
// bound pan or zoom scroll, a grab and a continuous gesture end the
// fullscreen of their output; nothing else moves its camera.
#[test]
fn a_pan_a_zoom_a_drag_and_a_swipe_end_fullscreen_and_nothing_else_moves_the_camera() {
    // A scroll pan: the camera that moves is the restored one. Its reply is
    // not one the shell performs sizes from, so the size is owed until one
    // is. A pointer motion is not one either: the shell reads a hover
    // reply's forward, dirty and focus request and nothing else, so nothing
    // may begin there.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":10.0,"y":0.0}}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view((CAMERA.0 + 20.0, CAMERA.1), 0.5));
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], Value::Null);
    let reply = h.ok(json!({"op":"hover","output":2,"screen":{"x":B.0 + 790.0,"y":B.1 + 590.0}}));
    assert!(reply.get("transaction").is_none(), "{reply}");
    assert!(reply.get("effects").is_none(), "{reply}");
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], Value::Null);
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    // The click that follows carries it. A reply that lists no `effects`
    // gains the list with the transaction's effect in it, which is where the
    // shell's size hook finds it.
    let reply = h.ok(json!({"op":"clear_focus"}));
    let effects = reply["effects"].as_array().unwrap();
    assert_eq!(effects.len(), 1, "{reply}");
    assert_eq!(reply["transaction"], effects[0]["transaction"]);
    perform(
        &mut h,
        &effects[0].clone(),
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));

    // A wheel zoom and a direct zoom.
    for command in [
        json!({"op":"zoom_by","output":1,"anchor":{"x":A.0 + 500.0,"y":A.1 + 400.0},"delta":-15.0,"source":"wheel"}),
        json!({"op":"zoom","output":1,"zoom":0.8,"anchor":{"x":A.0,"y":A.1}}),
    ] {
        let mut h = zoomed(CONFIG);
        entered(&mut h);
        h.ok(command.clone());
        assert_eq!(fullscreen(&mut h, 1), Value::Null, "{command}");
    }

    // A press bound to a move: the drag takes hold of the restored window,
    // and the size owed to it keeps the top-left the drag leaves it at.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    h.ok(json!({"op":"gesture_to","screen_delta":{"x":50.0,"y":25.0}}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(
        world(&mut h, 1),
        rect(START.0 + 100.0, START.1 + 50.0, USABLE.2, USABLE.3)
    );
    let reply = action(&mut h, 2, "spawn true");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(
        world(&mut h, 1),
        rect(START.0 + 100.0, START.1 + 50.0, 400.0, 300.0)
    );

    // A continuous swipe, bound in the window context, which is the context
    // of a fullscreen output wherever the pointer is: here it is told canvas.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let none = json!({"control":false,"option":false,"shift":false,"command":false});
    let reply = h.ok(json!({"op":"gesture_begin","kind":"swipe","fingers":3,"modifiers":none,"context":"canvas","output":1,"pointer":{"x":A.0 + 5.0,"y":A.1 + 5.0},"time_ms":10.0}));
    assert_eq!(reply["gesture"]["state"], "swipe_pan", "{reply}");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(reply["dirty"], true);
    assert!(reply["effect"].is_object(), "{reply}");

    // The lock. A flight asked of a fullscreen output is not armed, and a
    // tick moves nothing: IPC focus of another window focuses it behind the
    // fullscreen one, as upstream's does, and the camera stays parked.
    let mut h = zoomed(CONFIG);
    attach(&mut h, 2, "app.2", (5000.0, 5000.0, 300.0, 200.0));
    entered(&mut h);
    let reply = ipc(&mut h, json!({"Focus":2}));
    assert_eq!(reply["reply"]["Ok"]["Focused"]["id"], 2);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    let tick = h.ok(json!({"op":"tick_navigation","timestamp_ns":900_000_000_000u64}));
    assert_eq!(tick["needs_frames"], false);
    assert_eq!(tick["changed_outputs"], json!([]));
    assert_eq!(pose(&mut h, 1), view(PARK, 1.0));
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(placed_ids(&mut h, 1), [1]);
}

// Upstream toplevel_destroyed, activate_window_output_local and the output
// removal, each of which ends a fullscreen by something that happened.
#[test]
fn a_close_an_activation_and_a_lost_output_end_fullscreen() {
    // The fullscreen window closes: the output has its view back, and what
    // stays of the window is seated at the frame it had before.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(state(&mut h)["fullscreen"], json!([]));
    match reply["standin"] == true {
        true => assert_eq!(world(&mut h, 1), of(START)),
        false => assert_eq!(h.snapshot()["windows"], json!([])),
    }
    // And as a stand-in for certain: `suspend-window` marks the close.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = ipc(&mut h, json!({"Suspend":1}));
    assert_eq!(reply["reply"], json!({"Ok":"Ok"}));
    // Upstream runs it through the action, whose guard ends the fullscreen.
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    let reply = h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    assert_eq!(reply["standin"], true);
    assert_eq!(world(&mut h, 1), of(START));
    // The window goes before its old size is observed: the transaction ends
    // unanswered, and the stand-in still takes the frame from before
    // (upstream's suspend mark carries the pre-fullscreen rect).
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "suspend-window");
    let read = began(&mut h, &reply);
    unanswered(&mut h, &read, "missing_window");
    assert_eq!(h.snapshot()["native_resize"]["phase"], "failed");
    let reply = h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    assert_eq!(reply["standin"], true);
    assert_eq!(world(&mut h, 1), of(START));
    // IPC `Close` is not its action: upstream's cmd_close asks the window to
    // close, or dismisses a stand-in, and ends no fullscreen. Another
    // window's close leaves it alone, and the fullscreen window's own ends
    // it only once the window is gone.
    let mut h = zoomed(CONFIG);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    entered(&mut h);
    let reply = ipc(&mut h, json!({"Close":2}));
    assert_eq!(reply["reply"], json!({"Ok":"Ok"}));
    assert_eq!(reply["effects"][0]["op"], "close_window");
    assert_eq!(reply["effects"][0]["window"], 2);
    assert!(reply.get("transaction").is_none(), "{reply}");
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(pose(&mut h, 1), view(PARK, 1.0));
    let reply = ipc(&mut h, json!({"Close":1}));
    assert_eq!(reply["effects"][0]["window"], 1);
    assert!(reply.get("transaction").is_none(), "{reply}");
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    let reply = h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    assert_eq!(reply["standin"], false);
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    // A fullscreen window that only loses its source lives on at the
    // output's size: its slot keeps the place from before and the size the
    // window has, the one a later size transaction is measured from.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(1),"keep_placeholder":true}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));

    // Another window is activated on the fullscreen output: the fullscreen
    // ends first, and what is visible is judged by the restored camera.
    let mut h = zoomed(CONFIG);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    entered(&mut h);
    let reply = h.ok(json!({"op":"activate","window":2,"output":1,"cause":"native"}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    // Wholly visible in the restored view: focus only.
    assert_eq!(reply["navigation"], Value::Null);
    let effects = reply["effects"].as_array().unwrap().clone();
    assert_eq!(effects.len(), 1, "{reply}");
    perform(
        &mut h,
        &effects[0],
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    // Activating the fullscreen window itself ends nothing.
    let mut h = zoomed(CONFIG);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    entered(&mut h);
    h.ok(json!({"op":"focus","window":2}));
    let reply = h.ok(json!({"op":"activate","window":1,"output":2,"cause":"native"}));
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(h.snapshot()["focus"]["intent"], 1);

    // The shell removes every output on any screen change and registers the
    // present ones again. An output that comes back keeps its fullscreen.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    h.ok(json!({"op":"remove_output","output":1}));
    h.ok(json!({"op":"remove_output","output":2}));
    // In between it is drawn nowhere.
    assert_eq!(h.snapshot()["placements"], json!([]));
    h.ok(json!({"op":"register_output","stable_id":"view-b","screen_bounds":of(B)}));
    assert_eq!(placed_ids(&mut h, 2), Vec::<u64>::new());
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":of(A),"usable_rect_local":of(USABLE)}));
    assert_eq!(
        h.ok(json!({"op":"outputs_settled"})),
        json!({"dirty":false})
    );
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(pose(&mut h, 1), view(PARK, 1.0));
    assert_eq!(placed(&mut h, 1)[0]["screen_rect"], of(USABLE_SCREEN_A));
    // One that comes back at another size has its window asked again, and
    // meanwhile keeps the same usable top-left.
    h.ok(json!({"op":"remove_output","output":1}));
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":rect(A.0, A.1, 1200.0, 900.0),"usable_rect_local":rect(USABLE.0,USABLE.1,1160.0,840.0)}));
    h.ok(json!({"op":"outputs_settled"}));
    assert_eq!(
        placed(&mut h, 1)[0]["screen_rect"],
        rect(A.0 + USABLE.0, A.1 + USABLE.1, USABLE.2, USABLE.3)
    );
    let reply = action(&mut h, 1, "spawn true");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (1160.0, 840.0),
        "applied",
        (1160.0, 840.0),
    );
    assert_eq!(
        placed(&mut h, 1)[0]["screen_rect"],
        rect(A.0 + USABLE.0, A.1 + USABLE.1, 1160.0, 840.0)
    );
    // One that does not come back ends its fullscreen once the shell has
    // said which outputs exist: the window is back on the canvas, and the
    // output's camera is the one from before, for when it returns.
    h.ok(json!({"op":"remove_output","output":1}));
    let reported = h.ok(json!({"op":"ipc","output":2,"request":"State"}));
    assert_eq!(reported["reply"]["Ok"]["State"]["fullscreen"], json!([]));
    assert_eq!(mode(&mut h, 1), "fullscreen");
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), json!({"dirty":true}));
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, 1160.0, 840.0));
    let reply = action(&mut h, 2, "spawn true");
    deliver(
        &mut h,
        &reply,
        (1160.0, 840.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":of(A),"usable_rect_local":of(USABLE)}));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
}

// Upstream's new toplevel beside a fullscreen window
// (fullscreen_background_pos), and its rule `fullscreen` with `output`.
#[test]
fn a_new_window_is_tucked_behind_a_fullscreen_one_and_a_ruled_one_takes_its_output() {
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    // A plain new window does not end the fullscreen, takes no focus and
    // moves no camera: it is placed beside the frame the fullscreen window
    // comes back to, and is drawn on the fullscreen output not at all.
    let reply = appear(&mut h, 2, "app.2", (300.0, 200.0));
    assert_eq!(reply["background"], true);
    assert_eq!(reply["effect"], Value::Null);
    assert_eq!(reply["navigation"], Value::Null);
    assert!(reply.get("transaction").is_none());
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
    assert_eq!(placed_ids(&mut h, 1), [1]);
    let tucked = world(&mut h, 2);
    let (x, y) = (
        tucked["origin"]["x"].as_f64().unwrap(),
        tucked["origin"]["y"].as_f64().unwrap(),
    );
    // Beside the saved 400 x 300 frame at (100, 100), a snap gap away, and
    // off it: below, centred under it.
    assert_eq!(tucked, rect(150.0, 412.0, 300.0, 200.0));
    let beside = x + 300.0 <= START.0
        || x >= START.0 + START.2
        || y + 200.0 <= START.1
        || y >= START.1 + START.3;
    assert!(beside, "{tucked}");
    let gap = [
        START.0 - (x + 300.0),
        x - (START.0 + START.2),
        START.1 - (y + 200.0),
        y - (START.1 + START.3),
    ];
    assert!(gap.contains(&12.0), "{tucked}");
    // A later deliberate native activation still ends fullscreen. The shell
    // uses the attach's background provenance to distinguish its bounded
    // initial launch focus correction before sending this command.
    let reply = h.ok(json!({"op":"activate","window":2,"output":1,"cause":"native"}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    let effects = reply["effects"].as_array().unwrap().clone();
    assert_eq!(effects.len(), 1, "{reply}");
    perform(
        &mut h,
        &effects[0],
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(world(&mut h, 2), tucked);
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    appear(&mut h, 2, "app.2", (300.0, 200.0));

    // A window whose rule says `fullscreen = true` with `output = "view-b"`
    // maps into fullscreen there, whatever output is active. The reply is a
    // ruled attach's: the focus request as `effect`, the transaction with
    // its effect as the one entry of `effects`, and no navigation.
    let reply = appear(&mut h, 3, "app.ruled", (400.0, 300.0));
    assert_eq!(reply["window"], 3);
    assert_eq!(reply["adopted"], false);
    assert_eq!(reply["effect"]["op"], "focus_native_window");
    assert_eq!(reply["effect"]["window"], 3);
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(reply["dirty"], true);
    let effects = reply["effects"].as_array().unwrap().clone();
    assert_eq!(effects.len(), 1, "{reply}");
    assert_eq!(reply["transaction"], effects[0]["transaction"]);
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], effects[0]);
    assert_eq!(
        fullscreen(&mut h, 2),
        json!({"window":3,"backdrop":"black"})
    );
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(window(&mut h, 3)["rule"]["not_applied"], json!([]));
    assert_eq!(mode(&mut h, 3), "fullscreen");
    assert_eq!(h.snapshot()["focus"]["intent"], 3);
    perform(
        &mut h,
        &effects[0],
        (400.0, 300.0),
        (B.2, B.3),
        "applied",
        (B.2, B.3),
    );
    assert_eq!(placed(&mut h, 2).len(), 1);
    assert_eq!(placed(&mut h, 2)[0]["screen_rect"], of(B));
    assert_eq!(placed(&mut h, 2)[0]["fullscreen"], true);
    let inventory = state(&mut h)["fullscreen"].clone();
    assert_eq!(
        inventory,
        json!([
            {"id":1,"output":"view-a","app_id":"app.1","title":"fixture","pid":123},
            {"id":3,"output":"view-b","app_id":"app.ruled","title":"R","pid":123},
        ])
    );

    // A second ruled window takes that output over: the first one's
    // fullscreen ends, and it is back where it was placed. Its size is owed
    // while the newcomer's transaction holds the slot.
    let reply = appear(&mut h, 4, "app.ruled", (400.0, 300.0));
    assert_eq!(fullscreen(&mut h, 2)["window"], 4);
    assert_eq!(mode(&mut h, 3), Value::Null);
    assert_eq!(placed_ids(&mut h, 2), [4]);
    let effects = reply["effects"].as_array().unwrap().clone();
    assert_eq!(effects[0]["window"], 4);
    perform(
        &mut h,
        &effects[0],
        (400.0, 300.0),
        (B.2, B.3),
        "applied",
        (B.2, B.3),
    );
    let reply = action(&mut h, 2, "spawn true");
    assert_eq!(reply["effect"]["window"], 3);
    deliver(
        &mut h,
        &reply,
        (B.2, B.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    // It was itself placed in the background of output 1's fullscreen
    // window: the slot below that window's saved frame was taken, so it got
    // the one to its right, a snap gap away.
    assert_eq!(
        world(&mut h, 3),
        rect(START.0 + START.2 + 12.0, START.1, 400.0, 300.0)
    );
    // A rule with a `size` too, in upstream's order: the size is configured
    // first and the window placed for it, and the deferred fullscreen then
    // saves that frame. So the window is placed for the 600 x 400 its rule
    // names, enters at the 400 x 300 it has, and comes back to that frame at
    // the rule's size, which is asked of it only then. `focus_placement =
    // "left"` puts a frame's left edge at 28 and its middle at 410, where the
    // 400 x 300 window of the gate scenario stands at (28, 260): the
    // 600 x 400 frame is (28, 210).
    let both = format!(
        "window_placement = \"center\"\n{CONFIG}[[window_rules]]\napp_id = \"app.both\"\nsize = [600, 400]\nfullscreen = true\n"
    );
    let mut sized = capable(&both);
    let reply = appear(&mut sized, 2, "app.both", (400.0, 300.0));
    assert_eq!(fullscreen(&mut sized, 1)["window"], 2);
    assert_eq!(window(&mut sized, 2)["rule"]["not_applied"], json!([]));
    // It entered at its own size, the only one an observation committed,
    // and waits in no queue for its rule's: the one transaction is the
    // enter's, and it asks for the output's size.
    assert_eq!(world(&mut sized, 2), rect(USABLE.0, USABLE.1, 400.0, 300.0));
    let effects = reply["effects"].as_array().unwrap().clone();
    assert_eq!(effects.len(), 1, "{reply}");
    perform(
        &mut sized,
        &effects[0],
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    let reply = action(&mut sized, 1, "toggle-fullscreen");
    deliver(
        &mut sized,
        &reply,
        (USABLE.2, USABLE.3),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(world(&mut sized, 2), rect(28.0, 210.0, 600.0, 400.0));
    assert_eq!(sized.snapshot()["native_resize"]["phase"], "complete");

    // The launch pass applies no rule's fullscreen: nobody opened those.
    let mut h = fixture(CONFIG);
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    let mut early = Host {
        handle: driftwm_desktop_create(),
        scratch: Scratch::new(),
    };
    early.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":of(A),"usable_rect_local":of(USABLE)}));
    early.ok(json!({"op":"native_resize_capability","enabled":true}));
    let path = early.scratch.0.join("config.toml");
    std::fs::write(&path, CONFIG).unwrap();
    early.ok(json!({"op":"load_config","path":path}));
    appear(&mut early, 1, "app.ruled", (400.0, 300.0));
    assert_eq!(fullscreen(&mut early, 1), Value::Null);
    assert_eq!(
        window(&mut early, 1)["rule"]["not_applied"],
        json!(["fullscreen"])
    );
    // And one that cannot begin now is recorded as not applied: a size
    // transaction of another window holds the slot.
    let held = action(&mut h, 1, "toggle-fullscreen");
    began(&mut h, &held);
    let reply = appear(&mut h, 2, "app.ruled", (400.0, 300.0));
    assert!(reply.get("transaction").is_none(), "{reply}");
    assert_eq!(fullscreen(&mut h, 2), Value::Null);
    assert_eq!(
        window(&mut h, 2)["rule"]["not_applied"],
        json!(["fullscreen"])
    );
}

// Upstream src/tests/translucent_fullscreen.rs: only a rule or IPC opacity
// below 1 stops a fullscreen window from concealing the canvas.
#[test]
fn a_translucent_fullscreen_window_shows_the_canvas_behind_it() {
    let mut h = capable(CONFIG);
    attach(&mut h, 2, "app.glass", (500.0, 100.0, 300.0, 200.0));
    attach(&mut h, 3, "app.3", (600.0, 400.0, 200.0, 100.0));
    h.ok(json!({"op":"focus","window":2}));
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(
        fullscreen(&mut h, 1),
        json!({"window":2,"backdrop":"canvas"})
    );
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (USABLE.2, USABLE.3),
        "clamped",
        (800.0, 600.0),
    );
    // The canvas shows through; the other windows stay hidden all the same.
    assert_eq!(fullscreen(&mut h, 1)["backdrop"], "canvas");
    let alone = placed(&mut h, 1);
    assert_eq!(alone.len(), 1);
    assert_eq!(alone[0]["window"], 2);
    // A rule's opacity holds in fullscreen; the global dim does not apply.
    assert_eq!(alone[0]["opacity"], 0.5);
    assert_eq!(alone[0]["decoration"]["opacity"], 0.5);
    // The IPC verb writes the rule the answer is read from, on the spot.
    assert_eq!(
        ipc(&mut h, json!({"Opacity":{"window":2,"value":1.0}}))["reply"],
        json!({"Ok":{"Opacity":1.0}})
    );
    assert_eq!(fullscreen(&mut h, 1)["backdrop"], "black");
    assert_eq!(
        ipc(&mut h, json!({"Opacity":{"window":2,"value":0.25}}))["reply"],
        json!({"Ok":{"Opacity":0.25}})
    );
    assert_eq!(fullscreen(&mut h, 1)["backdrop"], "canvas");
    // An opaque window with an explicit rule of 1.0 or none conceals.
    let mut h = capable(CONFIG);
    entered(&mut h);
    assert_eq!(fullscreen(&mut h, 1)["backdrop"], "black");
}

// Upstream check_hot_corners' fullscreen suppression, per output.
#[test]
fn a_hot_corner_is_suppressed_on_a_fullscreen_output_unless_its_rule_says_otherwise() {
    let mut h = capable(CONFIG);
    entered(&mut h);
    // Output 1 takes the `*` entry, whose `disable_when_fullscreen` is the
    // default: its corner runs nothing while the output is fullscreen.
    let before = h.snapshot();
    assert_eq!(
        h.ok(json!({"op":"hot_corner","output":1,"corner":"top_left"})),
        nothing()
    );
    assert_eq!(h.snapshot(), before);
    // The other output's corner is not suppressed by this one's fullscreen:
    // its action runs, and toggles the focused window out of fullscreen.
    let reply = h.ok(json!({"op":"hot_corner","output":2,"corner":"top_left"}));
    assert_eq!(reply["dirty"], true);
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    // Not fullscreen any more, output 1's corner runs its action again.
    let reply = h.ok(json!({"op":"hot_corner","output":1,"corner":"top_left"}));
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    // `view-b` says `disable_when_fullscreen = false`: with its own window
    // fullscreen its corner still runs, and ends it.
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    let reply = action(&mut h, 2, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (B.2, B.3),
        "applied",
        (B.2, B.3),
    );
    assert_eq!(fullscreen(&mut h, 2)["window"], 1);
    let reply = h.ok(json!({"op":"hot_corner","output":2,"corner":"top_left"}));
    assert_eq!(reply["dirty"], true);
    assert_eq!(fullscreen(&mut h, 2), Value::Null);
}

// Fit and fill survive a fullscreen, as upstream's stage entries do, and a
// sizing action pressed during one behaves as if the exit had been pressed
// first: upstream src/tests/fullscreen_handoff.rs.
#[test]
fn fit_and_fill_survive_fullscreen_and_a_sizing_action_runs_on_the_restored_window() {
    // From fit and back. The fit frame is the whole usable area (v0.20: edge to edge, no outer gap).
    let mut h = capable(CONFIG);
    let reply = action(&mut h, 1, "fit-window");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (960.0, 740.0),
        "applied",
        (960.0, 740.0),
    );
    let fit = world(&mut h, 1);
    assert_eq!(mode(&mut h, 1), "fit");
    settle(&mut h);
    let rested = pose(&mut h, 1);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(mode(&mut h, 1), "fullscreen");
    deliver_unless_unchanged(
        &mut h,
        &reply,
        (960.0, 740.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver_unless_unchanged(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (960.0, 740.0),
        "applied",
        (960.0, 740.0),
    );
    assert_eq!(world(&mut h, 1), fit);
    assert_eq!(mode(&mut h, 1), "fit");
    assert_eq!(pose(&mut h, 1), rested);
    // The unfit still knows the size from before the fit.
    let reply = action(&mut h, 1, "fit-window");
    deliver(
        &mut h,
        &reply,
        (960.0, 740.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(mode(&mut h, 1), Value::Null);
    let unfit = world(&mut h, 1);
    assert_eq!(unfit["size"], json!({"width":400.0,"height":300.0}));

    // Upstream's second handoff scenario: unfitting straight out of
    // fullscreen lands where a plain unfit of the restored window does. One
    // press, one transaction: from the output's size to the size from before
    // the fit.
    let mut h = capable(CONFIG);
    let reply = action(&mut h, 1, "fit-window");
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (960.0, 740.0),
        "applied",
        (960.0, 740.0),
    );
    settle(&mut h);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver_unless_unchanged(
        &mut h,
        &reply,
        (960.0, 740.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    let reply = action(&mut h, 1, "fit-window");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), unfit);
    assert_eq!(mode(&mut h, 1), Value::Null);

    // From fill and back, and upstream's first handoff scenario: filling
    // straight out of fullscreen lands where a plain fill does.
    let mut plain = capable(CONFIG);
    let reply = action(&mut plain, 1, "fill-window");
    deliver(
        &mut plain,
        &reply,
        (400.0, 300.0),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    let filled = world(&mut plain, 1);
    assert_eq!(mode(&mut plain, 1), "fill");
    let reply = action(&mut plain, 1, "toggle-fullscreen");
    deliver(
        &mut plain,
        &reply,
        (944.0, 724.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    assert_eq!(mode(&mut plain, 1), "fullscreen");
    let reply = action(&mut plain, 1, "toggle-fullscreen");
    deliver(
        &mut plain,
        &reply,
        (USABLE.2, USABLE.3),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut plain, 1), filled);
    assert_eq!(mode(&mut plain, 1), "fill");
    // The second fill press still restores the frame from before the fill.
    let reply = action(&mut plain, 1, "fill-window");
    deliver(
        &mut plain,
        &reply,
        (944.0, 724.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut plain, 1), of(START));

    let mut h = capable(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "fill-window");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (944.0, 724.0),
        "applied",
        (944.0, 724.0),
    );
    assert_eq!(world(&mut h, 1), filled);
    assert_eq!(mode(&mut h, 1), "fill");
    let reply = action(&mut h, 1, "fill-window");
    deliver(
        &mut h,
        &reply,
        (944.0, 724.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));

    // And a window that was neither: fitting straight out of fullscreen
    // lands where a plain fit of the restored window does. The fit centers
    // on the frame the exit owes, which is what upstream's
    // configured_window_size reads once the exit has sent its configure,
    // and not on the output's size, the last one the enter asked for.
    let mut plain = capable(CONFIG);
    let reply = action(&mut plain, 1, "fit-window");
    deliver(
        &mut plain,
        &reply,
        (400.0, 300.0),
        (960.0, 740.0),
        "applied",
        (960.0, 740.0),
    );
    let fitted = world(&mut plain, 1);
    let mut h = capable(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "fit-window");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    deliver_unless_unchanged(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (960.0, 740.0),
        "applied",
        (960.0, 740.0),
    );
    assert_eq!(world(&mut h, 1), fitted);
    assert_eq!(mode(&mut h, 1), "fit");

    // Upstream map_window_to_rule_point: a move to a point, pressed during
    // fullscreen or while the size is still owed, centers the restored frame
    // there, not the one that still has the output's size.
    let mut h = capable(CONFIG);
    entered(&mut h);
    ipc(
        &mut h,
        json!({"Bookmark":{"name":"spot","to":[500.0, -300.0]}}),
    );
    let reply = action(&mut h, 1, "move-to-bookmark spot");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(world(&mut h, 1), rect(300.0, 150.0, USABLE.2, USABLE.3));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(300.0, 150.0, 400.0, 300.0));
    let mut h = capable(CONFIG);
    entered(&mut h);
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":0.0,"y":0.0}}));
    let reply = ipc(&mut h, json!({"Move":{"window":1,"to":[0, 0]}}));
    assert_eq!(reply["reply"], json!({"Ok":{"Position":{"x":0,"y":0}}}));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(-200.0, -150.0, 400.0, 300.0));
    // A nudge is no center: the restored frame keeps the nudged top-left.
    let mut h = capable(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "nudge-window right");
    let nudged = world(&mut h, 1)["origin"].clone();
    assert_ne!(nudged, json!({"x":START.0,"y":START.1}));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1)["origin"], nudged);
    assert_eq!(
        world(&mut h, 1)["size"],
        json!({"width":400.0,"height":300.0})
    );

    // A step out of fullscreen walks on from the restored size.
    let mut h = capable(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "grow-window right");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (420.0, 300.0),
        "applied",
        (420.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, 420.0, 300.0));
    // A step that moves a left or top edge holds the opposite edge of the
    // restored frame, whatever size is granted, exactly as a step on a
    // window that was never fullscreen does.
    for (step, asks, outcome, took, at) in [
        (
            "grow-window left",
            (420.0, 300.0),
            "applied",
            (420.0, 300.0),
            (80.0, 100.0),
        ),
        (
            "grow-window up",
            (400.0, 320.0),
            "applied",
            (400.0, 320.0),
            (100.0, 80.0),
        ),
        (
            "shrink-window left",
            (380.0, 300.0),
            "applied",
            (380.0, 300.0),
            (120.0, 100.0),
        ),
        (
            "grow-window up-left",
            (414.0, 314.0),
            "applied",
            (414.0, 314.0),
            (86.0, 86.0),
        ),
        (
            "grow-window left",
            (420.0, 300.0),
            "clamped",
            (410.0, 300.0),
            (90.0, 100.0),
        ),
    ] {
        let mut h = capable(CONFIG);
        entered(&mut h);
        let reply = action(&mut h, 1, step);
        deliver(&mut h, &reply, (USABLE.2, USABLE.3), asks, outcome, took);
        assert_eq!(world(&mut h, 1), rect(at.0, at.1, took.0, took.1), "{step}");
    }
    // A held key walks on from the size asked for, on the same transaction.
    let mut h = capable(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "grow-window left");
    let read = began(&mut h, &reply);
    let held = action(&mut h, 1, "grow-window left");
    assert!(held.get("effect").is_none(), "{held}");
    perform(
        &mut h,
        &read,
        (USABLE.2, USABLE.3),
        (440.0, 300.0),
        "applied",
        (440.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), rect(60.0, 100.0, 440.0, 300.0));
}

// Who can be fullscreen: upstream's rules for a widget, a stand-in and a
// screen-pinned window.
#[test]
fn a_widget_and_a_stand_in_never_enter_and_a_pinned_window_is_pinned_again() {
    let mut h = capable(CONFIG);
    attach(&mut h, 2, "app.widget", (500.0, 100.0, 300.0, 200.0));
    attach(&mut h, 3, "app.3", (600.0, 400.0, 200.0, 100.0));
    h.ok(json!({"op":"remove_source","window":3,"identity":identity(3),"keep_placeholder":true}));
    for inert in [2, 3] {
        h.ok(json!({"op":"focus","window":inert}));
        let before = h.snapshot();
        assert_eq!(action(&mut h, 1, "toggle-fullscreen"), nothing());
        assert_eq!(h.snapshot(), before);
    }
    // With one of them focused the toggle still ends the active output's.
    h.ok(json!({"op":"focus","window":1}));
    entered(&mut h);
    h.ok(json!({"op":"focus","window":3}));
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(reply["effect"]["window"], 1);

    // A pinned window enters: its pin is put away, and the exit pins it
    // again at the same place on the screen and hands its size back.
    let mut h = capable(CONFIG);
    action(&mut h, 1, "toggle-pin-to-screen");
    let pin = window(&mut h, 1)["pinned"].clone();
    assert_eq!(pin["output"], 1);
    assert_eq!(
        pin["screen_rect"],
        rect(A.0 + START.0, A.1 + START.1, 400.0, 300.0)
    );
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(window(&mut h, 1)["pinned"], Value::Null);
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(state(&mut h)["pinned"], json!([]));
    assert_eq!(
        ipc(&mut h, json!({"Pin":{"window":1,"value":false}}))["reply"],
        json!({"Err":"fullscreen windows can't be pinned"})
    );
    assert_eq!(
        ipc(&mut h, json!({"Pin":{"window":1}}))["reply"],
        json!({"Ok":{"Pin":false}})
    );
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    // Fullscreen fits the menu-excluded usable display area.
    assert_eq!(
        placed(&mut h, 1)[0]["screen_rect"],
        rect(A.0 + USABLE.0, A.1 + USABLE.1, USABLE.2, USABLE.3)
    );
    assert_eq!(placed(&mut h, 1)[0]["pinned"], false);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(window(&mut h, 1)["pinned"]["output"], 1);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(window(&mut h, 1)["pinned"], pin);
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(placed(&mut h, 1)[0]["pinned"], true);

    // A pin put away by a fullscreen moves with the others when its output
    // goes (upstream reassign_orphaned_pinned), or the exit would pin the
    // window to an output that is gone.
    let mut h = capable(CONFIG);
    action(&mut h, 1, "toggle-pin-to-screen");
    entered(&mut h);
    let reply = action(&mut h, 1, "send-to-output right");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (B.2, B.3),
        "applied",
        (B.2, B.3),
    );
    h.ok(json!({"op":"remove_output","output":1}));
    assert_eq!(h.ok(json!({"op":"outputs_settled"})), json!({"dirty":true}));
    assert_eq!(fullscreen(&mut h, 2)["window"], 1);
    let reply = action(&mut h, 2, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (B.2, B.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    let pinned = window(&mut h, 1)["pinned"].clone();
    assert_eq!(pinned["output"], 2);
    assert_eq!(
        pinned["screen_rect"],
        rect(B.0 + START.0, B.1 + START.1, 400.0, 300.0)
    );
    assert_eq!(placed_ids(&mut h, 2), [1]);
}

// One transaction slot. An exit pressed while the enter is pending takes
// that transaction over, so the window is never left at the output's size.
#[test]
fn an_exit_while_the_enter_is_pending_does_not_strand_the_window() {
    // Before anything was read: the request is walked back to the size the
    // window has, and no setter is ever sent.
    let mut h = zoomed(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert!(reply.get("effect").is_none(), "{reply}");
    assert_eq!(reply["dirty"], true);
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(
        answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"],
        Value::Null
    );
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(mode(&mut h, 1), Value::Null);

    // With the setter already sent: the window does take the output's size,
    // and is then asked for its own again by the same transaction.
    let mut h = zoomed(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    assert_eq!(
        setter["requested"],
        json!({"width":USABLE.2,"height":USABLE.3})
    );
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert!(reply.get("effect").is_none(), "{reply}");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    let again = answer(&mut h, &setter, "applied", true, (USABLE.2, USABLE.3))["effect"].clone();
    assert_eq!(again["op"], "resize_native_window", "{again}");
    assert_eq!(again["requested"], json!({"width":400.0,"height":300.0}));
    let last = answer(&mut h, &again, "applied", true, (400.0, 300.0))["effect"].clone();
    assert_eq!(
        answer(&mut h, &last, "observed", false, (400.0, 300.0))["effect"],
        Value::Null
    );
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));

    // A third press while that second setter is in flight: the window has the
    // output's size by then, and that is neither the size nor the place it
    // comes back to.
    let mut h = zoomed(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    action(&mut h, 1, "toggle-fullscreen");
    let back = answer(&mut h, &setter, "applied", true, (USABLE.2, USABLE.3))["effect"].clone();
    assert_eq!(back["requested"], json!({"width":400.0,"height":300.0}));
    // Its size is still owed: it sits where the exit put it, and a save
    // writes that place.
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    let path = h.scratch.0.join("scene.json");
    h.ok(json!({"op":"save","path":path}));
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        saved["scene"]["windows"][0]["world_rect"],
        rect(START.0, START.1, USABLE.2, USABLE.3)
    );
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert!(reply.get("effect").is_none(), "{reply}");
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    let again = answer(&mut h, &back, "applied", true, (400.0, 300.0))["effect"].clone();
    assert_eq!(
        again["requested"],
        json!({"width":USABLE.2,"height":USABLE.3})
    );
    let last = answer(&mut h, &again, "applied", true, (USABLE.2, USABLE.3))["effect"].clone();
    assert_eq!(
        answer(&mut h, &last, "observed", false, (USABLE.2, USABLE.3))["effect"],
        Value::Null
    );
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, USABLE.2, USABLE.3)
    );
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));

    // And the other way about: an enter pressed while the exit is pending.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert!(reply.get("effect").is_none(), "{reply}");
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(
        answer(&mut h, &read, "observed", false, (USABLE.2, USABLE.3))["effect"],
        Value::Null
    );
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, USABLE.2, USABLE.3)
    );
    // The size it comes back to is still the one from before the first.
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));

    // An exit whose transaction ends before the window was asked leaves the
    // size owed, and the next reply that can carry it asks again. Cancelled
    // during its first read, as Escape or a screen change does:
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    h.ok(json!({"op":"cancel_native_resize","transaction":read["transaction"]}));
    let reply = answer(&mut h, &read, "observed", false, (USABLE.2, USABLE.3));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "preparing");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    let reply = ipc(&mut h, json!("State"));
    assert!(reply.get("transaction").is_none(), "{reply}");
    // With its setter answered by an adapter that was not available:
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (USABLE.2, USABLE.3))["effect"].clone();
    unanswered(&mut h, &setter, "unavailable");
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    let reply = action(&mut h, 1, "spawn true");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    // Cancelled while the enter's setter was still in flight, after the exit
    // had taken that transaction over: the setter's answer is none to the
    // exit, and the size stays owed.
    let mut h = zoomed(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    action(&mut h, 1, "toggle-fullscreen");
    h.ok(json!({"op":"cancel_native_resize","transaction":read["transaction"]}));
    let last = answer(&mut h, &setter, "applied", true, (USABLE.2, USABLE.3))["effect"].clone();
    let reply = answer(&mut h, &last, "observed", false, (USABLE.2, USABLE.3));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "preparing");
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    // Another window's transaction holds the slot: entering is refused like
    // any sizing action, and nothing changes.
    let mut h = capable(CONFIG);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    let step = action(&mut h, 1, "grow-window right");
    began(&mut h, &step);
    h.ok(json!({"op":"focus","window":2}));
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"toggle-fullscreen"})),
        "a native resize of window 1 is still pending"
    );
    // During a drag it is refused as a sizing action is.
    let mut h = capable(CONFIG);
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"toggle-fullscreen"})),
        "a window is under an interactive move or resize"
    );
}

// What the pointer reaches: the fullscreen window on its own output and
// nothing else there; on no other output; and upstream maybe_hover_focus'
// fullscreen branch.
#[test]
fn the_pointer_reaches_only_the_fullscreen_window_on_its_output() {
    let config = format!("focus_follows_mouse = true\n{CONFIG}");
    let mut h = capable(&config);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    attach(&mut h, 3, "app.pin", (200.0, 500.0, 100.0, 80.0));
    h.ok(json!({"op":"focus","window":3}));
    action(&mut h, 1, "toggle-pin-to-screen");
    h.ok(json!({"op":"focus","window":1}));
    // Before: window 2 and the pinned one answer on output 1.
    assert_eq!(hit(&mut h, 1, (A.0 + 750.0, A.1 + 100.0)), 2);
    assert_eq!(hit(&mut h, 1, (A.0 + 250.0, A.1 + 540.0)), 3);
    assert_eq!(placed_ids(&mut h, 1), [2, 1, 3]);
    entered(&mut h);

    // During: the same points reach the fullscreen window, with the point in
    // its own frame, and nothing else is placed there.
    assert_eq!(placed_ids(&mut h, 1), [1]);
    for at in [(750.0, 100.0), (250.0, 540.0), (25.0, 45.0), (975.0, 775.0)] {
        let reply = h.ok(json!({"op":"hit","output":1,"screen":{"x":A.0 + at.0,"y":A.1 + at.1}}));
        assert_eq!(reply["hit"]["window"], 1, "{at:?}");
        assert_eq!(reply["pick"], false);
        // 200 x 100 buffer pixels over the menu-excluded usable frame.
        let local = &reply["hit"]["buffer_local"];
        let expected = [
            (at.0 - USABLE.0) * 200.0 / USABLE.2,
            (at.1 - USABLE.1) * 100.0 / USABLE.3,
        ];
        assert!((local["x"].as_f64().unwrap() - expected[0]).abs() < 1e-12);
        assert!((local["y"].as_f64().unwrap() - expected[1]).abs() < 1e-12);
    }
    let input = h.ok(json!({"op":"input","output":1,"screen":{"x":A.0 + 750.0,"y":A.1 + 100.0},"identity":identity(1)}));
    assert_eq!(input["hit"]["window"], 1);
    // On the other output, whose camera covers the canvas the window is
    // parked on, it is not there: the window beneath answers, or nothing.
    assert_eq!(hit(&mut h, 2, (B.0 + 750.0, B.1 + 100.0)), 2);
    assert_eq!(hit(&mut h, 2, (B.0 + 300.0, B.1 + 300.0)), Value::Null);
    assert_eq!(placed_ids(&mut h, 2), [2]);

    // Hover focus on the other output moves the focus to its window.
    let reply = h.ok(json!({"op":"hover","output":2,"screen":{"x":B.0 + 750.0,"y":B.1 + 100.0}}));
    assert_eq!(reply["effect"]["window"], 2);
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    // Back on the fullscreen output the window is given its focus back,
    // without a hover target being looked for, and without a raise.
    let reply = h.ok(json!({"op":"hover","output":1,"screen":{"x":A.0 + 250.0,"y":A.1 + 540.0}}));
    assert_eq!(reply["hit"]["window"], 1);
    assert_eq!(reply["forward"], true);
    assert_eq!(reply["effect"]["window"], 1);
    assert_eq!(reply["dirty"], true);
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
    // Already focused inside the usable area: nothing more is asked.
    let reply = h.ok(json!({"op":"hover","output":1,"screen":{"x":A.0 + 25.0,"y":A.1 + 45.0}}));
    assert!(reply.get("effect").is_none(), "{reply}");
    assert_eq!(reply["dirty"], false);

    // Alt-Tab on the other output passes over the fullscreen window, as
    // upstream's cycle_step does, and lands on the next window that is not
    // fullscreen, which may be the one that already holds the focus. The
    // window passed over keeps its place in the stack.
    let mut h = capable(CONFIG);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    for id in [2u64, 1] {
        let request = h.ok(json!({"op":"focus","window":id}))["effect"].clone();
        h.ok(json!({"op":"focus_logical","effect_id":request["effect_id"],"window":id,"identity":request["identity"],"generation":request["generation"]}));
    }
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let focus = reply["effects"][0].clone();
    h.ok(json!({"op":"focus_logical","effect_id":focus["effect_id"],"window":1,"identity":focus["identity"],"generation":focus["generation"]}));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    assert_eq!(h.snapshot()["focus"]["history"], json!([1, 2]));
    let reply = action(&mut h, 2, "cycle-windows forward");
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    assert_eq!(reply["navigation"]["output"], 2);
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    let request = reply["effects"][0].clone();
    h.ok(json!({"op":"focus_logical","effect_id":request["effect_id"],"window":2,"identity":request["identity"],"generation":request["generation"]}));
    assert_eq!(h.snapshot()["focus"]["history"], json!([2, 1]));
    let order = |h: &mut Host| -> Vec<Value> {
        let windows = h.snapshot()["windows"].clone();
        let ids = windows.as_array().unwrap().iter();
        ids.map(|w| w["window"].clone()).collect()
    };
    let stacked = order(&mut h);
    let reply = action(&mut h, 2, "cycle-windows forward");
    assert_eq!(reply["effects"][0]["window"], 2);
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    assert_eq!(order(&mut h), stacked);
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
}

// Upstream's HomeToggle and SendToOutput arms around a fullscreen window.
#[test]
fn home_toggle_returns_into_fullscreen_and_send_to_output_carries_it_over() {
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    // Away from home: the fullscreen ends, the restored view is remembered,
    // and the output snaps home at zoom 1 with no flight.
    let reply = action(&mut h, 1, "home-toggle");
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(reply["dirty"], true);
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(
        pose(&mut h, 1),
        view(
            (-(USABLE.0 + USABLE.2 / 2.0), -(USABLE.1 + USABLE.3 / 2.0)),
            1.0
        )
    );
    assert_eq!(
        h.snapshot()["navigation"]["home_returns"]["1"],
        view(CAMERA, 0.5)
    );
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    // At home: the view is put back in one step and the window is
    // fullscreen again, parked at that view's rounded camera.
    let reply = action(&mut h, 1, "home-toggle");
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(pose(&mut h, 1), view(PARK, 1.0));
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    // Its exit still returns to the view from before the first fullscreen.
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));

    // The direct command returns into fullscreen as the action does, and its
    // reply carries the size transaction that takes the window there.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    h.ok(json!({"op":"home_toggle","output":1}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    let reply = ipc(&mut h, json!("State"));
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    let reply = h.ok(json!({"op":"home_toggle","output":1}));
    assert_eq!(reply["navigation"], Value::Null);
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    deliver(
        &mut h,
        &reply,
        (400.0, 300.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    assert_eq!(placed(&mut h, 1)[0]["screen_rect"], of(USABLE_SCREEN_A));

    // send-to-output runs during fullscreen: the window becomes fullscreen
    // on the adjacent output, and the one it leaves has its view back. One
    // transaction, from one output's size to the other's.
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let reply = action(&mut h, 1, "send-to-output right");
    assert_eq!(reply["dirty"], true);
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(fullscreen(&mut h, 2)["window"], 1);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (B.2, B.3),
        "applied",
        (B.2, B.3),
    );
    assert_eq!(placed(&mut h, 2)[0]["screen_rect"], of(B));
    assert_eq!(placed_ids(&mut h, 1), Vec::<u64>::new());
    // No output further right: nothing happens.
    assert_eq!(action(&mut h, 2, "send-to-output right"), nothing());
    // The exit there hands back the frame from before the first enter.
    let reply = action(&mut h, 2, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (B.2, B.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
}

// Upstream's session store never saves a fullscreen, and a loaded scene has
// none. The window is saved at the place it had before and at the size it
// has: the application outlives the canvas at that size, where upstream's
// client maps again at the saved one.
#[test]
fn a_save_keeps_the_place_from_before_the_size_the_window_has_and_no_fullscreen() {
    let mut h = zoomed(CONFIG);
    entered(&mut h);
    let path = h.scratch.0.join("scene.json");
    let lives_on = rect(START.0, START.1, USABLE.2, USABLE.3);
    h.ok(json!({"op":"save","path":path}));
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(saved["scene"]["windows"][0]["world_rect"], lives_on);
    assert!(!saved.to_string().contains("fullscreen"));
    // The save changed nothing here.
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, USABLE.2, USABLE.3)
    );
    // A window still owed its size is saved as it stands: where the exit
    // put it, at the size it has until that one is delivered.
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":0.0,"y":0.0}}));
    assert_eq!(world(&mut h, 1), lives_on);
    h.ok(json!({"op":"save","path":path}));
    let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(saved["scene"]["windows"][0]["world_rect"], lives_on);

    let mut h = zoomed(CONFIG);
    entered(&mut h);
    h.ok(json!({"op":"save","path":path}));
    // A load needs the window detached, as it always does.
    h.ok(json!({"op":"remove_source","window":1,"identity":identity(1),"keep_placeholder":true}));
    h.ok(json!({"op":"load","path":path}));
    assert_eq!(h.snapshot()["outputs"], json!([]));
    h.ok(json!({"op":"register_output","stable_id":"view-a","screen_bounds":of(A),"usable_rect_local":of(USABLE)}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    assert_eq!(mode(&mut h, 1), Value::Null);
    assert_eq!(state(&mut h)["fullscreen"], json!([]));
    // The window that lived on at the output's size is adopted into a slot
    // of that size, so the next size transaction's first read finds the
    // size it is measured from.
    h.ok(json!({"op":"native_resize_capability","enabled":true}));
    let reply = h.ok(json!({"op":"attach","identity":identity(1),"bundle_id":"app.1","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,USABLE.2,USABLE.3),"output":1}));
    assert_eq!(reply["adopted"], true, "{reply}");
    h.ok(json!({"op":"adoption_complete"}));
    h.ok(json!({"op":"focus","window":1}));
    let reply = action(&mut h, 1, "grow-window right");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (USABLE.2 + 20.0, USABLE.3),
        "applied",
        (USABLE.2 + 20.0, USABLE.3),
    );
    assert_eq!(
        world(&mut h, 1),
        rect(START.0, START.1, USABLE.2 + 20.0, USABLE.3)
    );
}

// Fullscreen beside `pass_mouse` and `pass_keys` (docs/crates/desktop/RULES.md). Upstream's
// fullscreen_claims (src/input/pointer.rs) asks the fullscreen window's
// `pass_mouse` at the button site, the notch site and the scroll site, each
// ahead of every pick-mode test; and its key filter asks the window that
// holds the keyboard, fullscreen or not.
#[test]
fn a_fullscreen_window_claims_its_bindings_and_passes_its_keys() {
    let toml = format!(
        "{CONFIG}[[window_rules]]\napp_id = \"app.claims\"\npass_mouse = true\npass_keys = true\n[mouse.on-window]\n\"alt+wheel-down\" = \"zoom-in\"\n"
    );
    let option = json!({"control":false,"option":true,"shift":false,"command":false});
    let super_chord = json!({"control":true,"option":true,"shift":false,"command":false});
    let lookup = |h: &mut Host,
                  trigger: &str,
                  source: Value,
                  chord: &Value,
                  pick: bool,
                  id: u64| {
        h.ok(json!({"op":"mouse_binding","trigger":trigger,"source":source,"modifiers":chord,"context":"window","pick":pick,"window":id}))
    };
    let mut h = capable(&toml);
    attach(&mut h, 2, "app.claims", (500.0, 100.0, 300.0, 200.0));
    h.ok(json!({"op":"focus","window":2}));
    // The focus request is in flight: nothing holds the keyboard yet.
    assert_eq!(h.snapshot()["pass_keys"], Value::Null);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(fullscreen(&mut h, 1)["window"], 2);
    // Entering asks for the focus again. Once the adapter has confirmed it,
    // the fullscreen window holds the keyboard and its rule passes every key.
    assert_eq!(h.snapshot()["pass_keys"], Value::Null);
    let focus = reply["effects"][0].clone();
    assert_eq!(focus["window"], 2);
    h.ok(json!({"op":"focus_result","effect_id":focus["effect_id"],"window":2,"identity":focus["identity"],"generation":focus["generation"],"success":true}));
    assert_eq!(h.snapshot()["pass_keys"], json!(true));
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );

    assert_eq!(h.snapshot()["pass_keys"], json!(true));

    // What `hit` reports on the fullscreen output is the fullscreen window,
    // and never as a pick target.
    let under = h.ok(json!({"op":"hit","output":1,"screen":{"x":A.0 + 500.0,"y":A.1 + 400.0}}));
    assert_eq!(under["hit"]["window"], 2);
    assert_eq!(under["hit"]["pick"], false);
    // Its claims hold for a press, a wheel and a trackpad scroll and a wheel
    // notch, and with no pick gate: `pick` is said here although this shell
    // never says it of a fullscreen window.
    let passed = json!({"binding":null,"passed":true});
    for pick in [false, true] {
        assert_eq!(
            lookup(&mut h, "left", Value::Null, &option, pick, 2),
            passed
        );
        assert_eq!(
            lookup(&mut h, "scroll", json!("wheel"), &super_chord, pick, 2),
            passed
        );
        assert_eq!(
            lookup(&mut h, "scroll", json!("finger"), &super_chord, pick, 2),
            passed
        );
        assert_eq!(
            lookup(&mut h, "wheel_down", Value::Null, &option, pick, 2),
            passed
        );
    }
    // A claimed press or scroll is the application's: the lookups ended
    // nothing.
    assert_eq!(fullscreen(&mut h, 1)["window"], 2);

    // A fullscreen window whose rule passes nothing claims nothing: the same
    // four triggers are the canvas's bindings.
    let mut h = capable(&toml);
    entered(&mut h);
    let found = |h: &mut Host, trigger: &str, source: Value, chord: &Value| {
        let binding = lookup(h, trigger, source, chord, false, 1)["binding"].clone();
        (binding["kind"].clone(), binding["combo"].clone())
    };
    assert_eq!(
        found(&mut h, "left", Value::Null, &option),
        (json!("move_window"), json!("alt+left"))
    );
    assert_eq!(
        found(&mut h, "scroll", json!("wheel"), &super_chord),
        (json!("zoom"), json!("mod+wheel-scroll"))
    );
    assert_eq!(
        found(&mut h, "scroll", json!("finger"), &super_chord),
        (json!("zoom"), json!("mod+trackpad-scroll"))
    );
    assert_eq!(
        found(&mut h, "wheel_down", Value::Null, &option),
        (json!("action"), json!("alt+wheel-down"))
    );
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    // What each then does is its own site's exit rule. The grab and the
    // bound pan and zoom end the fullscreen themselves (above). A notch runs
    // its action like a key does, through the action's guard: `zoom-in` is
    // not one upstream runs during fullscreen, so it ends it first.
    let reply = action(&mut h, 1, "zoom-in");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
}

// Fullscreen beside the focus a grab takes first. Upstream's press bound to
// a move or a resize on a fullscreen output (src/input/pointer.rs
// on_pointer_button): the fullscreen block ends the fullscreen, and the
// binding's own arm then raises and focuses the window on the restored
// canvas and installs its grab. One order here too: the exit, the focus, the
// grab, in one command, and a grab that is refused undoes all three.
#[test]
fn a_grab_ends_the_fullscreen_then_focuses_the_window_and_then_takes_hold() {
    let order = |h: &mut Host| -> Vec<Value> {
        let windows = h.snapshot()["windows"].clone();
        let ids = windows.as_array().unwrap().iter();
        ids.map(|w| w["window"].clone()).collect()
    };
    let mut h = capable(CONFIG);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    entered(&mut h);
    // Another window holds the focus behind the fullscreen one, above it.
    ipc(&mut h, json!({"Focus":2}));
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    assert_eq!(order(&mut h), [1, 2]);
    // A window that is fullscreen on another output is not this press's to
    // take. Nothing ended and nothing was focused for it.
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":1,"output":2})),
        "a fullscreen window is not moved or resized by hand"
    );
    let reply = h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(reply["effect"]["op"], "focus_native_window");
    assert_eq!(reply["effect"]["window"], 1);
    assert!(reply.get("transaction").is_none(), "{reply}");
    assert_eq!(h.snapshot()["focus"]["intent"], 1);
    assert_eq!(order(&mut h), [2, 1]);
    // The drag has hold of the restored window, which still has the
    // output's size.
    h.ok(json!({"op":"gesture_to","screen_delta":{"x":50.0,"y":25.0}}));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(
        world(&mut h, 1),
        rect(START.0 + 50.0, START.1 + 25.0, USABLE.2, USABLE.3)
    );

    // A resize drag answers with the same focus request, and ends what the
    // exit owed as it ends a fit: no later reply begins a transaction for
    // it, and the window keeps the size it has.
    let mut h = capable(CONFIG);
    entered(&mut h);
    let reply =
        h.ok(json!({"op":"begin_resize","window":1,"output":1,"edges":"right","group":false}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(reply["effect"]["op"], "focus_native_window");
    assert_eq!(reply["effect"]["window"], 1);
    h.ok(json!({"op":"end_gesture"}));
    let reply = action(&mut h, 2, "spawn true");
    assert!(reply.get("transaction").is_none(), "{reply}");
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));

    // The native resize's reply is a size transaction's, so its focus
    // request is the one entry of `effects`.
    let mut h = capable(CONFIG);
    entered(&mut h);

    let reply = h.ok(json!({"op":"begin_native_resize","window":1,"output":1,"edges":"right","start_screen":{"x":A.0 + 999.0,"y":A.1 + 400.0},"group":false}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(reply["effect"]["op"], "observe_resize_source");
    assert_eq!(reply["transaction"], reply["effect"]["transaction"]);
    let effects = reply["effects"].as_array().unwrap();
    assert_eq!(effects.len(), 1, "{reply}");
    assert_eq!(effects[0]["op"], "focus_native_window");
    assert_eq!(effects[0]["window"], 1);
}

// Fullscreen beside the screen-space drag of a pinned window. Upstream
// MoveGrab::motion freezes a drag while the cursor is over a fullscreen
// output, which draws its fullscreen window alone ("a window dragged there
// would just vanish"); pinned_window_under finds no pinned window on one;
// and here no output becomes fullscreen under a drag.
#[test]
fn a_pinned_drag_stays_off_a_fullscreen_output() {
    let mut h = capable(CONFIG);
    attach(&mut h, 2, "app.2", (700.0, 50.0, 300.0, 200.0));
    attach(&mut h, 3, "app.3", (200.0, 500.0, 100.0, 80.0));
    h.ok(json!({"op":"focus","window":3}));
    action(&mut h, 1, "toggle-pin-to-screen");
    // The canvas point (200, 500) under a camera at the origin is the point
    // (200, 500) of output 1: the global (500, 700).
    let pin = |h: &mut Host| window(h, 3)["pinned"].clone();
    let at = |output: u64, x: f64, y: f64| json!({"output":output,"screen_rect":rect(x, y, 100.0, 80.0)});
    assert_eq!(pin(&mut h), at(1, 500.0, 700.0));
    let fill_side = |h: &mut Host| {
        h.ok(json!({"op":"focus","window":2}));
        let reply = action(h, 2, "toggle-fullscreen");
        deliver(h, &reply, (300.0, 200.0), (B.2, B.3), "applied", (B.2, B.3));

        assert_eq!(fullscreen(h, 2)["window"], 2);
    };
    let drag_to = |h: &mut Host, delta: (f64, f64), pointer: (f64, f64)| {
        let reply = h.ok(json!({"op":"gesture_to","screen_delta":{"x":delta.0,"y":delta.1},"pointer":{"x":pointer.0,"y":pointer.1}}));
        assert_eq!(reply, json!({"needs_frames":false}));
    };
    fill_side(&mut h);

    let reply = h.ok(json!({"op":"begin_drag","window":3,"output":1}));
    assert_eq!(reply["effect"]["window"], 3);
    // The pointer crosses onto the fullscreen output: the drag is frozen,
    // the pin stays where it was, and that output goes on placing its
    // fullscreen window alone.
    drag_to(&mut h, (1000.0, -300.0), (B.0 + 250.0, B.1 + 290.0));
    assert_eq!(pin(&mut h), at(1, 500.0, 700.0));
    assert_eq!(placed_ids(&mut h, 2), [2]);
    // Back on output 1 it goes on from the pointer's displacement.
    drag_to(&mut h, (10.0, 5.0), (A.0 + 260.0, A.1 + 545.0));
    assert_eq!(pin(&mut h), at(1, 510.0, 705.0));
    // And no output becomes fullscreen under it: the dragged window holds
    // the focus, and its enter is refused as any sizing is during a drag.
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"toggle-fullscreen"})),
        "a window is under an interactive move or resize"
    );
    h.ok(json!({"op":"end_gesture"}));

    // With output 2 on the canvas again the pin is dragged over and let go
    // there: (510, 705) + (1000, -300).
    h.ok(json!({"op":"focus","window":2}));
    let reply = action(&mut h, 2, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (B.2, B.3),
        (300.0, 200.0),
        "applied",
        (300.0, 200.0),
    );
    h.ok(json!({"op":"begin_drag","window":3,"output":1}));
    drag_to(&mut h, (1000.0, -300.0), (B.0 + 250.0, B.1 + 290.0));
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(pin(&mut h), at(2, 1510.0, 405.0));
    // Fullscreen there again, the pinned window is not drawn on its output
    // and is no target on it.
    fill_side(&mut h);
    assert_eq!(placed_ids(&mut h, 2), [2]);
    assert_eq!(hit(&mut h, 2, (1560.0, 445.0)), 2);
    // No drag of it is installed from elsewhere while its output is
    // fullscreen.
    assert_eq!(
        h.error(json!({"op":"begin_drag","window":3,"output":1})),
        "the window's output is fullscreen"
    );
    // A press on that output is a grab, and ends its fullscreen first: the
    // pinned window is drawn again, and taken.
    let reply = h.ok(json!({"op":"begin_drag","window":3,"output":2}));
    assert_eq!(fullscreen(&mut h, 2), Value::Null);
    assert_eq!(reply["effect"]["window"], 3);
    assert!(placed_ids(&mut h, 2).contains(&3));
    drag_to(&mut h, (5.0, 5.0), (B.0 + 255.0, B.1 + 295.0));
    assert_eq!(pin(&mut h), at(2, 1515.0, 410.0));
    h.ok(json!({"op":"end_gesture"}));
}

// Fullscreen beside the effects (docs/crates/desktop/EFFECTS.md): the frost, and the window
// events the shell animates. Upstream's effective_blur takes `is_fullscreen`:
// the global `[decorations] blur` does not reach a fullscreen window, its
// own rule's `blur` does. And a window that maps straight into fullscreen
// opened, and one that closes fullscreen closed, like any other.
#[test]
fn a_fullscreen_window_is_frosted_by_its_own_rule_alone_and_opens_and_closes_like_any_other() {
    let toml = format!(
        "{CONFIG}[[window_rules]]\napp_id = \"app.frost\"\nblur = true\n[decorations]\nblur = true\n"
    );
    let mut h = capable(&toml);
    attach(&mut h, 2, "app.frost", (700.0, 50.0, 300.0, 200.0));
    let blur = |h: &mut Host, output: u64, id: u64| -> Value {
        let on = placed(h, output);
        let own = on.iter().find(|p| p["window"] == id);
        own.unwrap_or_else(|| panic!("window {id} is not on output {output}"))["decoration"]["blur"]
            .clone()
    };
    // On the canvas the global table frosts both.
    assert_eq!(blur(&mut h, 1, 1), true);
    assert_eq!(blur(&mut h, 1, 2), true);
    entered(&mut h);
    assert_eq!(blur(&mut h, 1, 1), false);
    h.ok(json!({"op":"focus","window":2}));
    let reply = action(&mut h, 2, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (300.0, 200.0),
        (B.2, B.3),
        "applied",
        (B.2, B.3),
    );
    assert_eq!(blur(&mut h, 2, 2), true);

    // A rule's `fullscreen` takes the place of the arrival's navigation,
    // not of its `open`: the event names the active output of the command,
    // as every event does, while the window fills the rule's.
    assert_eq!(h.snapshot()["lifecycle_events"], json!([]));
    let reply = appear(&mut h, 3, "app.ruled", (400.0, 300.0));
    assert_eq!(fullscreen(&mut h, 2)["window"], 3);
    let opened = json!({"serial":1,"window":3,"event":"open","output":1});
    assert_eq!(h.snapshot()["lifecycle_events"], json!([opened]));
    let effects = reply["effects"].as_array().unwrap().clone();
    perform(
        &mut h,
        &effects[0],
        (400.0, 300.0),
        (B.2, B.3),
        "applied",
        (B.2, B.3),
    );
    // It closes: one `close`, and the snapshot that carries it has the
    // output on the canvas again.
    h.ok(json!({"op":"window_closed","window":3,"identity":identity(3),"output":1}));
    let closed = json!({"serial":2,"window":3,"event":"close","output":1});
    assert_eq!(h.snapshot()["lifecycle_events"], json!([opened, closed]));
    assert_eq!(fullscreen(&mut h, 2), Value::Null);
}

// Fullscreen beside the queue of rule sizes (docs/crates/desktop/RULES.md): there is one size
// transaction, and a window whose rule names a `size` waits for it in map
// order, standing at its own size inside the frame it was placed for.
#[test]
fn a_ruled_size_waits_out_a_fullscreen_enter_and_is_placed_in_its_background() {
    // The rule-size frame calculations below explicitly exercise centering.
    let toml = format!(
        "window_placement = \"center\"\n{CONFIG}[[window_rules]]\napp_id = \"app.sized\"\nsize = [600, 400]\n"
    );
    let mut h = capable(&toml);
    let held = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &held);
    // A ruled window maps while the enter holds the slot. It is tucked in
    // the background like any new window, for the 600 x 400 its rule names:
    // below the frame the fullscreen window comes back to, (100, 100)
    // 400 x 300, a snap gap away and centred under it, which is
    // (100 + 200 - 300, 100 + 300 + 12) = (0, 412). It stands in the middle
    // of that frame at its own 400 x 300, (0 + 100, 412 + 50), and waits.
    let reply = appear(&mut h, 2, "app.sized", (400.0, 300.0));
    assert_eq!(reply["effect"], Value::Null);
    assert_eq!(reply["navigation"], Value::Null);
    assert!(reply.get("transaction").is_none(), "{reply}");
    assert_eq!(world(&mut h, 2), rect(100.0, 462.0, 400.0, 300.0));
    assert_eq!(window(&mut h, 2)["rule"]["not_applied"], json!(["size"]));
    // The next new window is placed against the frame that one is becoming.
    // That frame lies a snap gap below the saved one, so it is its neighbour
    // on that axis, and upstream's placement grows the cluster sideways:
    // right of the saved frame and centred on it, (100 + 400 + 12,
    // 100 + 150 - 100). Read at the frame it stands at, 50 further down, it
    // would be no neighbour, and the slot above would be taken instead.
    appear(&mut h, 3, "app.3", (300.0, 200.0));
    assert_eq!(world(&mut h, 3), rect(512.0, 150.0, 300.0, 200.0));
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(placed_ids(&mut h, 1), [1]);

    // The enter's transaction ends, the slot is free, and the reply to its
    // last result carries the first effect of the waiting window's.
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    let last = answer(&mut h, &setter, "applied", true, (USABLE.2, USABLE.3))["effect"].clone();
    let ended = answer(&mut h, &last, "observed", false, (USABLE.2, USABLE.3));
    let next = ended["effect"].clone();
    assert_eq!(next["op"], "observe_resize_source", "{ended}");
    assert_eq!(next["window"], 2);
    assert_eq!(ended["transaction"], next["transaction"]);
    assert_eq!(
        world(&mut h, 1),
        rect(USABLE.0, USABLE.1, USABLE.2, USABLE.3)
    );
    perform(
        &mut h,
        &next,
        (400.0, 300.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(world(&mut h, 2), rect(0.0, 412.0, 600.0, 400.0));
    assert_eq!(window(&mut h, 2)["rule"]["not_applied"], json!([]));
    // None of it ended the fullscreen or was drawn on its output.
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    assert_eq!(placed_ids(&mut h, 1), [1]);

    // Entering is a sizing of the user's, like a fit or an IPC resize: a
    // window that still waits for its rule's `size` leaves the queue with it
    // and is not asked afterwards (upstream's rule size is one-shot at the
    // first commit). This one maps under a drag, so nothing can be asked: it
    // is placed for the 600 x 400 its rule names, (28, 210) by
    // `focus_placement = "left"`, and stands in it at (128, 260).
    let mut h = capable(&toml);
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    let reply = appear(&mut h, 2, "app.sized", (400.0, 300.0));
    assert!(reply.get("transaction").is_none(), "{reply}");
    h.ok(json!({"op":"end_gesture"}));
    assert_eq!(world(&mut h, 2), rect(128.0, 260.0, 400.0, 300.0));
    assert_eq!(window(&mut h, 2)["rule"]["not_applied"], json!(["size"]));
    assert_eq!(h.snapshot()["focus"]["intent"], 2);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(fullscreen(&mut h, 1)["window"], 2);
    // The enter's last result frees the slot, and nobody is waiting for it.
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    let last = answer(&mut h, &setter, "applied", true, (USABLE.2, USABLE.3))["effect"].clone();
    let ended = answer(&mut h, &last, "observed", false, (USABLE.2, USABLE.3));
    assert_eq!(ended["effect"], Value::Null, "{ended}");
    // It comes back at the size it had, where it stood, with `size` still
    // named: it was never asked.
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 2), rect(128.0, 260.0, 400.0, 300.0));
    assert_eq!(window(&mut h, 2)["rule"]["not_applied"], json!(["size"]));
    assert_eq!(h.snapshot()["native_resize"]["phase"], "complete");
}

// Readback mode: what every normal run without the flag reports. Nothing
// acknowledges a capture, so a fullscreen window is hit and drawn at once,
// and every enter and exit ends whether or not the window answers.
fn readback(toml: &str) -> Host {
    let mut h = fixture(toml);
    assert_eq!(
        h.ok(json!({"op":"native_resize_capability","enabled":true})),
        json!({})
    );
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":{"x":A.0,"y":A.1}}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":30.3,"y":-20.7}}));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    h
}
/// The readback invariant for every bound source and every placement.
fn usable(h: &mut Host) {
    let snapshot = h.snapshot();
    for w in snapshot["windows"].as_array().unwrap() {
        let source = &w["source"];
        if !source.is_null() {
            assert_eq!(source["observation_known"], true, "{w}");
        }
    }
    for p in snapshot["placements"].as_array().unwrap() {
        assert_eq!(p["presentation_settled"], true, "{p}");
    }
}
/// A result with no observation behind it: the adapter's deadline, or the
/// shell's watchdog.
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
fn failed_fullscreen_baseline_restores_the_view_and_reveals_other_windows() {
    // Finder's real failure was unavailable / AXIllegalArgument, before any
    // size setter. Other failures of that same initial read have the same duty.
    for (outcome, ax_error) in [
        ("unavailable", -25201),
        ("readback_failed", -25200),
        ("timed_out", -25204),
    ] {
        let mut h = readback(CONFIG);
        attach(&mut h, 2, "app.2", (200.0, 150.0, 100.0, 100.0));
        let before = world(&mut h, 1);
        let other_output = output(&mut h, 2);
        assert!(placed_ids(&mut h, 1).contains(&2));
        let reply = ipc(&mut h, json!({"Action":"toggle-fullscreen"}));
        let read = began(&mut h, &reply);
        assert_eq!(read["requested"], Value::Null);
        assert_eq!(placed_ids(&mut h, 1), vec![1]);
        let none = rect(0.0, 0.0, 0.0, 0.0);
        let end = h.ok(json!({"op":"native_resize_result","transaction":read["transaction"],"effect_id":read["effect_id"],"identity":read["identity"],"generation":read["generation"],"result":{"outcome":outcome,"ax_error":ax_error,"mutation_attempted":false,"observed":false,"requested":{"width":0.0,"height":0.0},"actual_ax":none,"actual_cg":none}}));
        assert_eq!(fullscreen(&mut h, 1), Value::Null, "{outcome}");
        assert_eq!(world(&mut h, 1), before);
        assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
        assert_eq!(output(&mut h, 2), other_output);
        assert!(placed_ids(&mut h, 1).contains(&2));
        assert!(end["failure"].as_str().unwrap().contains("fullscreen"));
        assert_eq!(end["dirty"], true);
        assert_eq!(end["effect"], Value::Null);
        // No native resize happened, so a later carrier must not invent one.
        assert_eq!(ipc(&mut h, json!("State"))["effect"], Value::Null);
        assert_eq!(state(&mut h)["fullscreen"], json!([]));
        assert_eq!(h.snapshot()["native_resize"]["phase"], "failed");
        // The failed attempt does not poison a later enter.
        entered(&mut h);
        assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    }
}

#[test]
fn unattempted_fullscreen_setter_restores_the_view_without_new_native_debt() {
    // Actual native Fill gate refusal: the baseline succeeds, but no AX
    // normalization or Fill/size setter is attempted.
    let mut h = readback(CONFIG);
    attach(&mut h, 2, "app.2", (200.0, 150.0, 100.0, 100.0));
    let before = world(&mut h, 1);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (START.2, START.3))["effect"].clone();
    assert_eq!(setter["native_action"], "fill");
    let end = unanswered(&mut h, &setter, "unavailable");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(world(&mut h, 1), before);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert!(placed_ids(&mut h, 1).contains(&2));
    assert!(end["failure"].as_str().unwrap().contains("fullscreen"));
    assert_eq!(end["effect"], Value::Null);
    assert_eq!(ipc(&mut h, json!("State"))["effect"], Value::Null);
    // A subsequent attempt starts normally rather than toggling the failed
    // logical fullscreen off or inheriting an invented native restore.
    entered(&mut h);
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
}

#[test]
fn failed_fullscreen_baseline_restores_a_screen_pin() {
    let mut h = readback(CONFIG);
    ipc(&mut h, json!({"Pin":{"window":1,"value":true}}));
    let before = state(&mut h)["pinned"].clone();
    let before_world = world(&mut h, 1);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    unanswered(&mut h, &read, "unavailable");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(state(&mut h)["pinned"], before);
    assert_eq!(world(&mut h, 1), before_world);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(ipc(&mut h, json!("State"))["effect"], Value::Null);
}

#[test]
fn failed_fullscreen_baseline_keeps_an_earlier_exits_native_restore() {
    let mut h = readback(CONFIG);
    entered(&mut h);
    let exit = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &exit);
    // Re-enter while the exit's initial read is still pending. The old
    // fullscreen size is still native, so failure must not discard its debt.
    action(&mut h, 1, "toggle-fullscreen");
    let reply = unanswered(&mut h, &read, "unavailable");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    let retry = began(&mut h, &reply);
    assert_ne!(retry["transaction"], read["transaction"]);
    let setter = answer(&mut h, &retry, "observed", false, (USABLE.2, USABLE.3))["effect"].clone();
    assert_eq!(
        setter["requested"],
        json!({"width":START.2,"height":START.3})
    );
    assert_eq!(setter["native_origin"], json!({"x":4000.0,"y":3000.0}));
    let last = answer(&mut h, &setter, "applied", true, (START.2, START.3))["effect"].clone();
    answer(&mut h, &last, "observed", false, (START.2, START.3));
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(ipc(&mut h, json!("State"))["effect"], Value::Null);
}

#[test]
fn failed_fullscreen_baseline_keeps_the_rules_pending_size() {
    let config = format!(
        "window_placement = \"center\"\n{CONFIG}[[window_rules]]\napp_id = \"app.both\"\nsize = [600, 400]\nfullscreen = true\n"
    );
    let mut h = capable(&config);
    let before_view = pose(&mut h, 1);
    let reply = appear(&mut h, 2, "app.both", (400.0, 300.0));
    let read = reply["effects"][0].clone();
    assert_eq!(read["op"], "observe_resize_source");
    assert_eq!(fullscreen(&mut h, 1)["window"], 2);
    let failed = unanswered(&mut h, &read, "unavailable");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), before_view);
    assert_eq!(world(&mut h, 2), rect(28.0, 210.0, 400.0, 300.0));
    // The fullscreen never sized the window, but its rule still owes 600x400.
    // That obligation predates the failed read and must leave on its reply.
    let retry = began(&mut h, &failed);
    assert_ne!(retry["transaction"], read["transaction"]);
    perform(
        &mut h,
        &retry,
        (400.0, 300.0),
        (600.0, 400.0),
        "applied",
        (600.0, 400.0),
    );
    assert_eq!(world(&mut h, 2), rect(28.0, 210.0, 600.0, 400.0));
    assert_eq!(ipc(&mut h, json!("State"))["effect"], Value::Null);
}

#[test]
fn readback_enters_and_leaves_with_a_smaller_answer_aligned_and_hit_at_once() {
    let mut h = readback(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    usable(&mut h);
    let read = began(&mut h, &reply);
    assert!(read.get("native_action").is_none());
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    assert_eq!(setter["native_action"], "fill");
    usable(&mut h);
    let last = answer(&mut h, &setter, "clamped", true, (800.0, 600.0))["effect"].clone();
    assert!(last.get("native_action").is_none());
    usable(&mut h);
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, 800.0, 600.0)
    );
    // No acknowledgement is waited for: the window is hit where it is drawn
    // while its final read is still owed, and the band around it is not.
    assert_eq!(hit(&mut h, 1, (A.0 + 500.0, A.1 + 400.0)), 1);
    assert_eq!(hit(&mut h, 1, (A.0 + 21.0, A.1 + 41.0)), 1);
    assert_eq!(hit(&mut h, 1, (A.0 + 900.0, A.1 + 700.0)), Value::Null);
    assert_eq!(hit(&mut h, 1, (A.0 + 20.0, A.1 + 20.0)), Value::Null);
    answer(&mut h, &last, "observed", false, (800.0, 600.0));
    assert_eq!(
        placed(&mut h, 1)[0]["screen_rect"],
        rect(A.0 + USABLE.0, A.1 + USABLE.1, 800.0, 600.0)
    );
    assert_eq!(mode(&mut h, 1), "fullscreen");
    let reply = action(&mut h, 1, "toggle-fullscreen");
    usable(&mut h);
    deliver(
        &mut h,
        &reply,
        (800.0, 600.0),
        (400.0, 300.0),
        "applied",
        (400.0, 300.0),
    );
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    usable(&mut h);
}
// A window that was not settable once is asked again at every enter: the
// answer aligns it at its own size, or it takes the output's by now.
#[test]
fn readback_asks_a_window_that_was_not_settable_again_at_the_next_enter() {
    let mut h = readback(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    let last = answer(&mut h, &setter, "unsupported", false, (400.0, 300.0))["effect"].clone();
    answer(&mut h, &last, "observed", false, (400.0, 300.0));
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, 400.0, 300.0)
    );
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    usable(&mut h);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    assert_eq!(
        answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"],
        Value::Null
    );
    assert_eq!(world(&mut h, 1), of(START));
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (START.2, START.3),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    assert_eq!(
        world(&mut h, 1),
        rect(PARK.0 + USABLE.0, PARK.1 + USABLE.1, USABLE.2, USABLE.3)
    );
    usable(&mut h);
}
#[test]
fn readback_an_exit_while_the_enter_is_pending_gives_the_size_back() {
    let mut h = readback(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &reply);
    let setter = answer(&mut h, &read, "observed", false, (400.0, 300.0))["effect"].clone();
    assert_eq!(setter["native_action"], "fill");
    let reply = action(&mut h, 1, "toggle-fullscreen");
    assert!(reply.get("effect").is_none(), "{reply}");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    usable(&mut h);
    let again = answer(&mut h, &setter, "applied", true, (USABLE.2, USABLE.3))["effect"].clone();
    assert!(again.get("native_action").is_none());
    assert_eq!(again["requested"], json!({"width":400.0,"height":300.0}));
    usable(&mut h);
    let last = answer(&mut h, &again, "applied", true, (400.0, 300.0))["effect"].clone();
    assert_eq!(
        answer(&mut h, &last, "observed", false, (400.0, 300.0))["effect"],
        Value::Null
    );
    assert_eq!(world(&mut h, 1), of(START));
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    usable(&mut h);
}
#[test]
fn readback_a_close_after_the_enter_ended_restores_the_view() {
    let mut h = readback(CONFIG);
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (START.2, START.3),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    assert_eq!(fullscreen(&mut h, 1)["window"], 1);
    h.ok(json!({"op":"window_closed","window":1,"identity":identity(1),"output":1}));
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    assert_eq!(h.snapshot()["windows"], json!([]));
}
#[test]
fn readback_an_exit_the_window_never_answers_leaves_the_slot_free() {
    let mut h = readback(CONFIG);
    attach(&mut h, 2, "app.2", (3000.0, 2000.0, 200.0, 100.0));
    let reply = action(&mut h, 1, "toggle-fullscreen");
    deliver(
        &mut h,
        &reply,
        (START.2, START.3),
        (USABLE.2, USABLE.3),
        "applied",
        (USABLE.2, USABLE.3),
    );
    // The exit puts the view and the place back at once. Its size is asked
    // RESTORE_TRIES times at most, each try ended by the setter's timeout and
    // the one diagnostic read after it.
    let mut reply = action(&mut h, 1, "toggle-fullscreen");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(pose(&mut h, 1), view(CAMERA, 0.5));
    let mut tries = 0;
    while reply["effect"].is_object() {
        tries += 1;
        assert!(tries <= 3, "{reply}");
        let read = began(&mut h, &reply);
        let setter =
            answer(&mut h, &read, "observed", false, (USABLE.2, USABLE.3))["effect"].clone();
        assert_eq!(setter["requested"], json!({"width":400.0,"height":300.0}));
        let diagnostic = timed_out(&mut h, &setter)["effect"].clone();
        assert_eq!(diagnostic["op"], "observe_resize_source");
        usable(&mut h);
        let end = timed_out(&mut h, &diagnostic);
        usable(&mut h);
        // The next carrier takes what is still owed.
        reply = if end["effect"].is_object() {
            end
        } else {
            ipc(&mut h, json!("State"))
        };
    }
    assert_eq!(tries, 3);
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["phase"], "failed", "{slot}");
    assert_eq!(slot["pending_effect"], Value::Null);
    assert_eq!(slot["uncertain_mutation"], false);
    // The window is usable at the size it has, and another window sizes.
    assert_eq!(world(&mut h, 1), rect(START.0, START.1, USABLE.2, USABLE.3));
    h.ok(json!({"op":"focus","window":2}));
    let reply = action(&mut h, 1, "grow-window right");
    // v0.21: `resize_step` (20) is in screen px and the view is at zoom 0.5,
    // so the step covers 40 canvas px (canvas_step).
    deliver(
        &mut h,
        &reply,
        (200.0, 100.0),
        (240.0, 100.0),
        "applied",
        (240.0, 100.0),
    );
}

#[test]
fn external_minimize_exits_fill_and_defers_native_restore_until_visible_placement() {
    let mut h = zoomed(CONFIG);
    let initial = world(&mut h, 1);
    let initial_pose = pose(&mut h, 1);
    entered(&mut h);
    let source = window(&mut h, 1)["source"].clone();
    let reply = h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":true}));
    assert!(reply["effect"].is_null());
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    assert_eq!(world(&mut h, 1), initial);
    assert_eq!(pose(&mut h, 1), initial_pose);
    assert!(placed_ids(&mut h, 1).is_empty());
    // Other commands may carry owed sizes, but never resize a minimized app.
    assert!(h.ok(json!({"op":"clear_focus"}))["effect"].is_null());
    let reply=h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":false}));
    assert!(reply["effect"].is_null());
    assert!(h.ok(json!({"op":"clear_focus"}))["effect"].is_null());
    let binding = window(&mut h, 1)["source"].clone();
    let ack = json!({"op":"source_visible","window":1,"identity":source["identity"],"generation":source["generation"],"visibility_revision":binding["visibility_revision"]});
    let restore = h.ok(ack.clone());
    assert_eq!(restore["visibility"], "restoring");
    assert_eq!(window(&mut h, 1)["source"]["visibility"], "restoring");
    perform(
        &mut h,
        &restore["effects"][0],
        (USABLE.2, USABLE.3),
        (START.2, START.3),
        "applied",
        (START.2, START.3),
    );
    assert_eq!(h.ok(ack)["visibility"], "visible");
    assert_eq!(world(&mut h, 1), initial);
    assert_eq!(pose(&mut h, 1), initial_pose);
}

#[test]
fn product_minimize_leaves_fill_through_its_existing_resize_handoff() {
    let mut h = zoomed(CONFIG);
    let initial = world(&mut h, 1);
    entered(&mut h);
    let reply = ipc(&mut h, json!({"Minimize":1}));
    assert_eq!(reply["effects"][0]["op"], "set_minimized");
    assert_eq!(reply["effects"][0]["minimized"], true);
    assert_eq!(window(&mut h, 1)["source"]["visibility"], "visible");
    assert_eq!(fullscreen(&mut h, 1), Value::Null);
    deliver(
        &mut h,
        &reply,
        (USABLE.2, USABLE.3),
        (START.2, START.3),
        "applied",
        (START.2, START.3),
    );
    assert_eq!(world(&mut h, 1), initial);
}

#[test]
fn visibility_hint_during_restore_keeps_owed_native_size_while_cancellation_drains() {
    let mut h = zoomed(CONFIG);
    let initial = world(&mut h, 1);
    entered(&mut h);
    let restore = action(&mut h, 1, "toggle-fullscreen");
    let read = began(&mut h, &restore);
    let source = window(&mut h, 1)["source"].clone();
    h.ok(json!({"op":"source_visibility_pending","window":1,"identity":source["identity"],"generation":source["generation"]}));
    h.ok(json!({"op":"cancel_native_resize","transaction":read["transaction"]}));
    let drained = answer(&mut h, &read, "observed", false, (USABLE.2, USABLE.3));
    assert!(
        drained["effect"].is_null(),
        "pending visibility must not retry and exhaust the native-size debt: {drained}"
    );
    h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":true}));
    assert_eq!(world(&mut h, 1), initial);
    h.ok(json!({"op":"observe_visibility","window":1,"identity":source["identity"],"generation":source["generation"],"minimized":false}));
    let source = window(&mut h, 1)["source"].clone();
    let ready = json!({"op":"source_visible","window":1,"identity":source["identity"],"generation":source["generation"],"visibility_revision":source["visibility_revision"]});
    let restore = h.ok(ready.clone());
    perform(
        &mut h,
        &restore["effects"][0],
        (USABLE.2, USABLE.3),
        (START.2, START.3),
        "applied",
        (START.2, START.3),
    );
    assert_eq!(h.ok(ready)["visibility"], "visible");
    assert_eq!(world(&mut h, 1), initial);
}
