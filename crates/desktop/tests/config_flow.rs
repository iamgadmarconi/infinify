// SPDX-License-Identifier: GPL-3.0-or-later
//! Configuration scenarios cross the exported C ABI and JSON decoder with
//! config files written to a throwaway directory. They never read the default
//! config path, and they provide no evidence that a chord is registered with
//! macOS, that a key or button reaches the shell, or that a command is run.
use driftwm_core::config::{Config, parse_action};
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
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
    fn load_config(&mut self, path: &PathBuf) -> Value {
        self.ok(json!({"op":"load_config","path":path}))
    }
    fn bookmarks(&mut self) -> Value {
        self.ok(json!({"op":"ipc","output":null,"request":{"Bookmark":{}}}))["reply"]["Ok"]
            ["Bookmarks"]
            .clone()
    }
    fn camera(&mut self) -> Value {
        self.snapshot()["outputs"][0]["camera"].clone()
    }
    fn world(&mut self, window: usize) -> Value {
        self.snapshot()["windows"][window - 1]["world_rect"].clone()
    }
    /// The key bindings by upstream combo text.
    fn keys(&mut self) -> BTreeMap<String, Value> {
        by_combo(&self.ok(json!({"op":"bindings"}))["keys"])
    }
    /// The pointer binding of a physical chord, less the speeds it carries.
    fn mouse(&mut self, trigger: &str, source: Value, modifiers: &str, context: &str) -> Value {
        let mut binding = self.ok(json!({"op":"mouse_binding","trigger":trigger,"source":source,"modifiers":chord(modifiers),"context":context}))["binding"].take();
        if let Some(binding) = binding.as_object_mut() {
            for speed in SPEEDS {
                assert!(binding.remove(speed).is_some_and(|v| v.is_f64()), "{speed}");
            }
        }
        binding
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
            "infinify-config-flow-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
    fn write(&self, name: &str, contents: &str) -> PathBuf {
        let path = self.path(name);
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
fn identity(wid: u64) -> Value {
    json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid})
}
fn attach(h: &mut Host, wid: u64, world: Value) {
    h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"world_rect":world}));
}
/// A 1000 x 800 output at the global origin whose usable area is all of it.
fn register(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"view","screen_bounds":rect(0.0,0.0,1000.0,800.0)}));
}
/// An `[env]` table whose `PATH` is one directory of this scratch holding an
/// executable for each program upstream's default bindings run. With it those
/// defaults are registered as upstream wrote them, on any machine;
/// tests/platform_actions_flow.rs covers what a Mac without them registers.
fn linux_programs(scratch: &Scratch) -> String {
    use std::os::unix::fs::PermissionsExt;
    let directory = scratch.path("linux-bin");
    std::fs::create_dir_all(&directory).unwrap();
    for name in ["swaylock", "wpctl", "brightnessctl", "playerctl", "grim"] {
        let file = directory.join(name);
        std::fs::write(&file, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    format!(
        "\n[env]\nPATH = {}\n",
        toml_string(directory.to_str().unwrap())
    )
}
/// One output, no windows, and the given config file in force.
fn configured(scratch: &Scratch, toml: &str) -> Host {
    let mut h = Host::new();
    register(&mut h);
    let reply = h.load_config(&scratch.write("config.toml", toml));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    assert_eq!(reply["warnings"], json!([]), "{reply}");
    h
}
/// Physical modifiers from glyphs: ⌃ control, ⌥ option, ⇧ shift, ⌘ command.
fn chord(glyphs: &str) -> Value {
    json!({"control":glyphs.contains('⌃'),"option":glyphs.contains('⌥'),"shift":glyphs.contains('⇧'),"command":glyphs.contains('⌘')})
}
fn by_combo(entries: &Value) -> BTreeMap<String, Value> {
    entries
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| (entry["combo"].as_str().unwrap().to_owned(), entry.clone()))
        .collect()
}
/// The whole reply, one binding per line, for a failure message.
fn listing(bindings: &Value) -> String {
    let mut lines = Vec::new();
    for list in ["keys", "media_keys", "skipped"] {
        for entry in bindings[list].as_array().unwrap() {
            lines.push(format!("{list}: {entry}"));
        }
    }
    lines.push(format!("warnings: {}", bindings["warnings"]));
    lines.join("\n")
}
/// Check keys of a `bindings` reply against one line each: upstream combo,
/// then virtual key code, layout character (`none` for a key that is the same
/// in every layout), physical chord,
/// whether it repeats, and the action. A failure prints the whole reply.
fn assert_keys(reply: &Value, expected: &str) {
    let keys = by_combo(&reply["keys"]);
    for line in expected.lines().filter(|line| !line.trim().is_empty()) {
        let (combo, key) = line.trim().split_once(" | ").unwrap();
        let key: Vec<&str> = key.splitn(5, ' ').collect();
        let code = u64::from_str_radix(key[0].trim_start_matches("0x"), 16).unwrap();
        let character = (key[1] != "none").then_some(key[1]);
        let entry = keys
            .get(combo)
            .unwrap_or_else(|| panic!("{combo} is not registered\n{}", listing(reply)));
        let shown = json!({"key_code":entry["key_code"],"character":entry["character"],"modifiers":entry["modifiers"],"action":entry["action"],"repeat":entry["repeat"]});
        assert_eq!(
            shown,
            json!({"key_code":code,"character":character,"modifiers":chord(key[2]),"action":key[4],"repeat":key[3] == "repeat"}),
            "{combo}\n{}",
            listing(reply)
        );
    }
}
fn target(data: &Value) -> (Value, f64) {
    (
        data["navigation"]["target_camera"].clone(),
        data["navigation"]["target_zoom"].as_f64().unwrap(),
    )
}
/// The `[navigation]` and `[zoom]` speeds a pointer binding carries.
const SPEEDS: [&str; 5] = [
    "trackpad_speed",
    "mouse_speed",
    "zoom_step",
    "zoom_mouse_speed",
    "zoom_trackpad_speed",
];
const SEEDS: &str =
    r#"{"1":[-1750.0,1750.0],"2":[1750.0,1750.0],"3":[1750.0,-1750.0],"4":[-1750.0,-1750.0]}"#;
fn seeds() -> Value {
    serde_json::from_str(SEEDS).unwrap()
}

#[test]
fn no_file_is_upstreams_defaults_and_a_file_changes_what_commands_do() {
    let scratch = Scratch::new();
    let absent = scratch.path("absent.toml");
    let mut h = Host::new();
    register(&mut h);
    // Before any config nothing is seeded.
    assert_eq!(h.bookmarks(), json!({}));
    assert_eq!(
        h.load_config(&absent),
        json!({"path":absent,"exists":false,"errors":[],"warnings":[],"dirty":false,"effects":[],"focus_follows_mouse":false})
    );
    // Upstream seeds the four corner bookmarks when the section is absent.
    assert_eq!(h.bookmarks(), seeds());
    for wid in [1, 2] {
        attach(
            &mut h,
            wid,
            rect(1600.0 * (wid - 1) as f64, 0.0, 400.0, 300.0),
        );
    }
    // pan_step 100, zoom.step 1.1 and fit_padding 80: the box is 2000 x 300 on a
    // 1000 x 800 output, so the fit is (1000 - 160) / 2000.
    assert_eq!(
        target(&h.action("pan-viewport right")),
        (point(100.0, 0.0), 1.0)
    );
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":point(0.0,0.0)}));
    assert_eq!(target(&h.action("zoom-in")).1, 0.55);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    assert_eq!(target(&h.action("zoom-to-fit")).1, 0.42);

    // The same commands under a file that sets each of those.
    let mut h = configured(
        &scratch,
        "[navigation]\npan_step = 250.0\n[zoom]\nstep = 2.0\nfit_padding = 0.0\n",
    );
    for wid in [1, 2] {
        attach(
            &mut h,
            wid,
            rect(1600.0 * (wid - 1) as f64, 0.0, 400.0, 300.0),
        );
    }
    assert_eq!(
        target(&h.action("pan-viewport right")),
        (point(250.0, 0.0), 1.0)
    );
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":point(0.0,0.0)}));
    assert_eq!(target(&h.action("zoom-in")).1, 1.0);
    h.ok(json!({"op":"cancel_navigation","output":1}));
    // The fit is 1000 / 2000, centered on the box.
    assert_eq!(
        target(&h.action("zoom-to-fit")),
        (point(1000.0 - 500.0 / 0.5, 150.0 - 400.0 / 0.5), 0.5)
    );

    // A step below 1 zooms out. Upstream gives zoom-in no lower bound; here
    // the target stops at the scene's floor, so every flight it arms lands.
    let mut h = configured(
        &scratch,
        "[navigation]\ncamera_speed = 1.0\n[zoom]\nstep = 0.03\n",
    );
    let mut clock = 1_000_000_000u64;
    for zoom in [0.03, 0.001, 0.001] {
        assert_eq!(target(&h.action("zoom-in")).1, zoom);
        for _ in 0..3 {
            clock += 16_000_000;
            h.ok(json!({"op":"tick_navigation","timestamp_ns":clock}));
        }
        assert_eq!(h.snapshot()["outputs"][0]["zoom"], zoom);
    }

    // navigation.anchors join the fit as points, Y up in the file: the box
    // grows to 5000 x 3000 and the limiting axis is the width.
    let mut h = configured(
        &scratch,
        "[navigation]\nanchors = [[5000.0, -3000.0]]\n[zoom]\nfit_padding = 0.0\n",
    );
    attach(&mut h, 1, rect(0.0, 0.0, 400.0, 300.0));
    assert_eq!(
        target(&h.action("zoom-to-fit")),
        (point(2500.0 - 500.0 / 0.2, 1500.0 - 400.0 / 0.2), 0.2)
    );
    // An anchor alone is something to fit; with no config there is nothing.
    let mut h = configured(&scratch, "[navigation]\nanchors = [[5000.0, -3000.0]]\n");
    assert_eq!(
        target(&h.action("zoom-to-fit")),
        (point(4500.0, 2600.0), 1.0)
    );
    let mut h = Host::new();
    register(&mut h);
    assert_eq!(h.action("zoom-to-fit")["navigation"], Value::Null);
}

#[test]
fn snap_settings_govern_the_logical_drag() {
    let scratch = Scratch::new();
    // Window 2's left edge starts 100 right of window 1's right edge. Returns
    // window 2's origin after one drag by `delta` from that start.
    let drag = |toml: &str, second: Value, deltas: &[(f64, f64)]| {
        let mut h = configured(&scratch, toml);
        attach(&mut h, 1, rect(0.0, 0.0, 400.0, 300.0));
        attach(&mut h, 2, second);
        h.ok(json!({"op":"begin_drag","window":2,"output":1}));
        let mut seen = Vec::new();
        for (x, y) in deltas {
            h.ok(json!({"op":"gesture_to","screen_delta":point(*x, *y)}));
            let origin = h.world(2)["origin"].clone();
            seen.push((origin["x"].as_f64().unwrap(), origin["y"].as_f64().unwrap()));
        }
        seen
    };
    let apart = || rect(500.0, 0.0, 400.0, 300.0);
    // Defaults: an edge 55 from its neighbour's is outside distance 24; 22
    // from it docks at gap 12; 40 past the dock is beyond break force 32.
    assert_eq!(
        drag("", apart(), &[(-45.0, 0.0), (-78.0, 0.0), (-128.0, 0.0)]),
        [(455.0, 0.0), (412.0, 0.0), (372.0, 0.0)]
    );
    // distance 60 reaches it from 55 away, gap 20 docks at 420, and break
    // force 100 holds 40 past the dock and lets go 100 past it.
    assert_eq!(
        drag(
            "[snap]\ndistance = 60.0\ngap = 20.0\nbreak_force = 100.0\n",
            apart(),
            &[(-45.0, 0.0), (-120.0, 0.0), (-180.0, 0.0)]
        ),
        [(420.0, 0.0), (420.0, 0.0), (320.0, 0.0)]
    );
    // Disabled: the same motion that docks by default goes where it is put.
    assert_eq!(
        drag("[snap]\nenabled = false\n", apart(), &[(-78.0, 0.0)]),
        [(422.0, 0.0)]
    );
    // corners: docked side by side, a top edge 20 off its neighbour's aligns.
    let beside = || rect(412.0, 15.0, 400.0, 300.0);
    assert_eq!(drag("", beside(), &[(0.0, 5.0)]), [(412.0, 20.0)]);
    assert_eq!(
        drag("[snap]\ncorners = true\n", beside(), &[(0.0, 5.0)]),
        [(412.0, 0.0)]
    );
    // centers: a shorter neighbour's middle, 5 off, aligns with the middle.
    let shorter = || rect(412.0, 40.0, 400.0, 200.0);
    assert_eq!(drag("", shorter(), &[(0.0, 5.0)]), [(412.0, 45.0)]);
    assert_eq!(
        drag("[snap]\ncenters = true\n", shorter(), &[(0.0, 5.0)]),
        [(412.0, 50.0)]
    );
}

#[test]
fn navigation_speed_and_focus_placement_come_from_the_config() {
    let scratch = Scratch::new();
    // The camera after the first frame that has a duration, and its target.
    let frame = |toml: &str| {
        let mut h = configured(&scratch, toml);
        h.ok(json!({"op":"tick_navigation","timestamp_ns":1_000_000_000u64}));
        let armed = h.action("pan-viewport down")["navigation"].clone();
        h.ok(json!({"op":"tick_navigation","timestamp_ns":1_016_000_000u64}));
        (h.camera(), armed["target_camera"].clone())
    };
    // camera_speed 1 is instant: one frame carries the camera all the way.
    let (camera, target) = frame("[navigation]\ncamera_speed = 1.0\n");
    assert_eq!(target, point(0.0, 100.0));
    assert_eq!(camera, target);
    // Upstream's default 0.3 covers 1 - 0.7^0.96 of the way in a 16 ms frame.
    let (camera, _) = frame("");
    let covered = camera["y"].as_f64().unwrap();
    assert!(
        (covered - 100.0 * (1.0 - 0.7f64.powf(0.96))).abs() < 1e-9,
        "{covered}"
    );

    // focus_placement and snap.outer_gap park a navigated window: top left, 10
    // in from the usable edge, so its center lands on screen (210, 160).
    let navigate = |toml: &str| {
        let mut h = configured(&scratch, toml);
        attach(&mut h, 1, rect(2000.0, 1000.0, 400.0, 300.0));
        // Once a config is in force it, not this command, decides the three.
        h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,0.0,1000.0,800.0),"focus_placement":"bottom_right","camera_speed":0.5,"outer_gap":0.0}));
        h.ok(json!({"op":"navigate_window","window":1,"output":1,"zoom_policy":"keep"}))["navigation"]
            ["target_camera"]
            .clone()
    };
    assert_eq!(navigate(""), point(2200.0 - 500.0, 1150.0 - 400.0));
    assert_eq!(
        navigate("focus_placement = \"top-left\"\n[snap]\nouter_gap = 10.0\n"),
        point(2200.0 - 210.0, 1150.0 - 160.0)
    );
    // Upstream's per-output rule, keyed here by the output's stable id.
    assert_eq!(
        navigate(
            "focus_placement = \"top-left\"\n[[outputs]]\nname = \"view\"\nfocus_placement = \"bottom\"\n"
        ),
        point(2200.0 - 500.0, 1150.0 - 650.0)
    );
}

#[test]
fn bookmark_seeds_follow_the_config_and_reconcile_on_reload() {
    let scratch = Scratch::new();
    let mut h = configured(
        &scratch,
        "[navigation.bookmarks]\ndesk = [10.0, 20.0]\nlab = [1.0, 2.0]\n",
    );
    // An explicit section replaces the corner seeds.
    assert_eq!(h.bookmarks(), json!({"desk":[10.0,20.0],"lab":[1.0,2.0]}));
    // go-to-bookmark flies the usable center there, Y up.
    assert_eq!(
        target(&h.action("go-to-bookmark desk")).0,
        point(10.0 - 500.0, -20.0 - 400.0)
    );
    // Runtime edits: one seed moved, one name of the session's own.
    for (name, to) in [("desk", [7.0, 7.0]), ("mine", [3.0, 4.0])] {
        h.ok(json!({"op":"ipc","output":null,"request":{"Bookmark":{"name":name,"to":to}}}));
    }
    // Reload with desk untouched, lab changed, shed added: only what the file
    // changed is re-asserted, and the shell is told to save.
    let path = scratch.write(
        "config.toml",
        "[navigation.bookmarks]\ndesk = [10.0, 20.0]\nlab = [5.0, 6.0]\nshed = [8.0, 9.0]\n",
    );
    assert_eq!(h.load_config(&path)["dirty"], true);
    assert_eq!(
        h.bookmarks(),
        json!({"desk":[7.0,7.0],"lab":[5.0,6.0],"mine":[3.0,4.0],"shed":[8.0,9.0]})
    );
    // The same file again changes nothing.
    assert_eq!(h.load_config(&path)["dirty"], false);
    // A name removed from the file drops from the registry, runtime value and all.
    let path = scratch.write("config.toml", "[navigation.bookmarks]\nlab = [5.0, 6.0]\n");
    assert_eq!(h.load_config(&path)["dirty"], true);
    assert_eq!(h.bookmarks(), json!({"lab":[5.0,6.0],"mine":[3.0,4.0]}));
    // Removing the section brings the corner seeds back and drops lab.
    let path = scratch.write("config.toml", "");
    assert_eq!(h.load_config(&path)["dirty"], true);
    let mut expected = seeds();
    expected["mine"] = json!([3.0, 4.0]);
    assert_eq!(h.bookmarks(), expected);
}

#[test]
fn a_broken_file_keeps_the_previous_config_and_reports_upstreams_message() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, "[navigation]\npan_step = 250.0\n");
    let pan = |h: &mut Host| {
        let data = h.action("pan-viewport right");
        h.ok(json!({"op":"cancel_navigation","output":1}));
        data["navigation"]["target_camera"]["x"].as_f64().unwrap()
    };
    assert_eq!(pan(&mut h), 250.0);
    let before = h.bookmarks();

    for (broken, piece) in [
        (
            "[navigation]\npan_step = \"fast\"\n",
            "invalid type: string \"fast\", expected f64",
        ),
        ("[navigation]\npan_stp = 3.0\n", "unknown field `pan_stp`"),
        (
            "[navigation\npan_step = 1.0\n",
            "TOML parse error at line 1",
        ),
    ] {
        let path = scratch.write("config.toml", broken);
        // Upstream's reload reports exactly this text.
        let upstream = format!("config error: {}", Config::from_toml(broken).unwrap_err());
        assert!(upstream.contains(piece), "{upstream}");
        assert_eq!(
            h.load_config(&path),
            json!({"path":path,"exists":true,"errors":[upstream],"warnings":[],"dirty":false,"effects":[],"focus_follows_mouse":false})
        );
        assert_eq!(pan(&mut h), 250.0, "{broken}");
        assert_eq!(h.bookmarks(), before);
    }
    // A path that cannot be read as a file is upstream's read failure.
    let reply = h.load_config(&scratch.0);
    let error = reply["errors"][0].as_str().unwrap();
    assert!(
        error.starts_with(&format!("config: failed to read {}: ", scratch.0.display())),
        "{error}"
    );
    assert_eq!(reply["exists"], true);
    assert_eq!(pan(&mut h), 250.0);

    // Values upstream corrects or rejects are warnings, in its words and order,
    // and the rest of the file applies.
    let odd = "[navigation]\npan_step = 40.0\ncamera_speed = 0.0\n[zoom]\nstep = -1.0\n[keybindings]\n\"mod+a\" = \"frobnicate\"\n";
    let path = scratch.write("config.toml", odd);
    let reply = h.load_config(&path);
    let upstream = Config::from_toml_collect(odd).unwrap().1;
    assert_eq!(reply["errors"], json!([]));
    assert_eq!(reply["warnings"], json!(upstream));
    assert_eq!(
        reply["warnings"],
        json!([
            "config: invalid action 'frobnicate': unknown action: frobnicate",
            "config: navigation.camera_speed 0 must be in (0, 1] (0 freezes the camera), using 0.3",
            "config: zoom.step -1 is negative, using 0"
        ])
    );
    assert_eq!(pan(&mut h), 40.0);

    // A broken first load leaves the built-in defaults in force, as upstream's
    // startup does, and they are what the run launches with.
    let mut h = Host::new();
    register(&mut h);
    let path = scratch.write("config.toml", "[navigation\n");
    assert_eq!(h.load_config(&path)["errors"].as_array().unwrap().len(), 1);
    assert_eq!(pan(&mut h), 100.0);
    assert_eq!(h.bookmarks(), seeds());
    // A file that disappears after it was accepted is upstream's reload read
    // failure: the config and the bookmark registry stay, runtime bookmarks
    // included, and there is nothing to save.
    let toml = "[session]\nrestore_bookmarks = true\n[navigation]\npan_step = 250.0\n[navigation.bookmarks]\ndesk = [10.0, 20.0]\n";
    let path = scratch.write("config.toml", toml);
    h.load_config(&path);
    assert_eq!(pan(&mut h), 250.0);
    for (name, to) in [("1", [10.0, 10.0]), ("desk", [7.0, 7.0])] {
        h.ok(json!({"op":"ipc","output":null,"request":{"Bookmark":{"name":name,"to":to}}}));
    }
    let kept = json!({"1":[10.0,10.0],"desk":[7.0,7.0]});
    assert_eq!(h.bookmarks(), kept);
    std::fs::remove_file(&path).unwrap();
    for _ in 0..2 {
        let reply = h.load_config(&path);
        let error = reply["errors"][0].as_str().unwrap();
        assert!(
            error.starts_with(&format!("config: failed to read {}: ", path.display())),
            "{error}"
        );
        assert_eq!(
            reply,
            json!({"path":path,"exists":false,"errors":[error],"warnings":[],"dirty":false,"effects":[],"focus_follows_mouse":false})
        );
        assert_eq!(pan(&mut h), 250.0);
        assert_eq!(h.bookmarks(), kept);
    }
    // The same file back is accepted and changes nothing.
    scratch.write("config.toml", toml);
    assert_eq!(
        h.load_config(&path),
        json!({"path":path,"exists":true,"errors":[],"warnings":[],"dirty":false,"effects":[],"focus_follows_mouse":false})
    );
    assert_eq!(pan(&mut h), 250.0);
    assert_eq!(h.bookmarks(), kept);
    // While no file has been accepted a missing one stays the defaults and no
    // error, however often it is loaded.
    let absent = scratch.path("absent.toml");
    let mut fresh = Host::new();
    register(&mut fresh);
    for _ in 0..2 {
        assert_eq!(
            fresh.load_config(&absent),
            json!({"path":absent,"exists":false,"errors":[],"warnings":[],"dirty":false,"effects":[],"focus_follows_mouse":false})
        );
        assert_eq!(pan(&mut fresh), 100.0);
        assert_eq!(fresh.bookmarks(), seeds());
    }
    // The command's own arguments are still checked.
    for command in [
        json!({"op":"load_config","path":""}),
        json!({"op":"load_config","path":7}),
        json!({"op":"load_config","path":path,"extra":1}),
    ] {
        h.error(command);
    }
}

#[test]
fn default_bindings_map_to_macos_chords() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, &linux_programs(&scratch));
    let reply = h.ok(json!({"op":"bindings"}));
    let table = listing(&reply);
    let keys = by_combo(&reply["keys"]);
    // logo is Control+Option; a modifier the chord already holds is displaced:
    // ctrl to Command, alt to Command+Shift.
    assert_keys(
        &reply,
        "mod+a | 0x00 a ⌃⌥ once home-toggle
        mod+ctrl+Right | 0x7C none ⌃⌥⌘ repeat pan-viewport right
        mod+alt+Right | 0x7C none ⌃⌥⇧⌘ once send-to-output right
        mod+shift+1 | 0x12 1 ⌃⌥⇧ once set-bookmark 1
        alt+Tab | 0x30 none ⌥ repeat cycle-windows forward
        alt+shift+Tab | 0x30 none ⌥⇧ repeat cycle-windows backward
        mod+equal | 0x18 = ⌃⌥ repeat zoom-in
        mod+minus | 0x1B - ⌃⌥ repeat zoom-out
        mod+ctrl+shift+q | 0x0C q ⌃⌥⇧⌘ once quit
        mod+Return | 0x24 none ⌃⌥ once exec-terminal
        mod+shift+Up | 0x7E none ⌃⌥⇧ repeat nudge-window up",
    );
    assert_eq!(keys["mod+a"]["chord"], "⌃⌥A", "{table}");
    assert_eq!(keys["mod+alt+Right"]["chord"], "⌃⌥⇧⌘Right", "{table}");
    // Upstream binds 57 keys by default: 45 on Mac keys, 8 on media keys, and 4
    // on keys a Mac keyboard lacks. None collide and none warn. Their programs
    // are on this config's PATH, so each is registered as upstream wrote it.
    assert_eq!(reply["warnings"], json!([]), "{table}");
    assert_eq!(keys.len(), 45, "{table}");
    let chords: BTreeSet<String> = keys
        .values()
        .map(|k| format!("{} {}", k["key_code"], k["modifiers"]))
        .collect();
    assert_eq!(chords.len(), 45, "{table}");
    let media = by_combo(&reply["media_keys"]);
    assert_eq!(
        media
            .iter()
            .map(|(combo, k)| (combo.as_str(), k["nx_key_type"].as_u64().unwrap()))
            .collect::<Vec<_>>(),
        [
            ("XF86AudioLowerVolume", 1),
            ("XF86AudioMute", 7),
            ("XF86AudioNext", 17),
            ("XF86AudioPlay", 16),
            ("XF86AudioPrev", 18),
            ("XF86AudioRaiseVolume", 0),
            ("XF86MonBrightnessDown", 3),
            ("XF86MonBrightnessUp", 2),
        ],
        "{table}"
    );
    assert!(media.values().all(|k| k.get("key_code").is_none()));
    assert_eq!(
        reply["skipped"],
        json!([
            {"combo":"Print","action":"spawn grim - | wl-copy","reason":"the key has no macOS equivalent"},
            {"combo":"XF86AudioPause","action":"spawn playerctl play-pause","reason":"the key has no macOS equivalent"},
            {"combo":"XF86AudioStop","action":"spawn playerctl stop","reason":"the key has no macOS equivalent"},
            {"combo":"shift+Print","action":"spawn grim -g \"$(slurp -d)\" - | wl-copy","reason":"the key has no macOS equivalent"}
        ]),
        "{table}"
    );
    assert_eq!(
        reply["reserved"],
        json!([{"purpose":"exit","key_code":0x35,"modifiers":chord("⌃⌥"),"claimed_by":null}])
    );
    assert_eq!(reply["layout_independent"], true);
    assert_eq!(reply["repeat_delay_ms"], 200);
    assert_eq!(reply["repeat_rate_hz"], 25);
    assert_eq!(reply["super"], "ctrl+alt");
    assert_eq!(
        reply["settings"],
        json!({"trackpad_speed":1.5,"mouse_speed":1.0,"zoom_step":1.1,"zoom_mouse_speed":1.0,"zoom_trackpad_speed":1.0})
    );
    // Listed in upstream combo order, the order collisions are decided in.
    let order: Vec<&str> = reply["keys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| k["combo"].as_str().unwrap())
        .collect();
    assert!(order.is_sorted(), "{table}");
    // The reply does not depend on anything but the config and the platform.
    assert_eq!(h.ok(json!({"op":"bindings"})), reply);

    // Every action string reads back through upstream's parser, and
    // `implemented` says what the action command then does with it.
    attach(&mut h, 1, rect(0.0, 0.0, 400.0, 300.0));
    for entry in ["keys", "media_keys", "skipped"]
        .iter()
        .flat_map(|list| reply[*list].as_array().unwrap())
    {
        let action = entry["action"].as_str().unwrap();
        assert!(parse_action(action).is_ok(), "{action}");
        let Some(implemented) = entry["implemented"].as_bool() else {
            continue;
        };
        let response = h.call(json!({"op":"action","output":1,"action":action}));
        h.ok(json!({"op":"cancel_navigation","output":1}));
        assert_eq!(response["ok"], implemented, "{action}: {response}");
        if !implemented {
            let error = response["error"].as_str().unwrap();
            assert!(
                error.starts_with("action not implemented on macOS yet: "),
                "{action}: {error}"
            );
        }
    }

    // The repeat settings and the layout rule are the file's.
    let mut h = configured(
        &scratch,
        "[input.keyboard]\nrepeat_delay = 350\nrepeat_rate = 40\nlayout_independent = false\n",
    );
    let reply = h.ok(json!({"op":"bindings"}));
    assert_eq!(reply["layout_independent"], false);
    assert_eq!(reply["repeat_delay_ms"], 350);
    assert_eq!(reply["repeat_rate_hz"], 40);
}

#[test]
fn the_super_chord_and_mod_key_choose_the_physical_modifiers() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, "");
    // --super cmd: upstream's chords read literally with Command as super.
    assert_eq!(
        h.ok(json!({"op":"set_platform","super":"cmd"})),
        json!({"super":"cmd"})
    );
    let reply = h.ok(json!({"op":"bindings"}));
    let table = listing(&reply);
    let keys = by_combo(&reply["keys"]);
    assert_keys(
        &reply,
        "mod+a | 0x00 a ⌘ once home-toggle
        mod+ctrl+Right | 0x7C none ⌃⌘ repeat pan-viewport right
        mod+alt+Right | 0x7C none ⌥⌘ once send-to-output right
        mod+shift+1 | 0x12 1 ⇧⌘ once set-bookmark 1
        alt+Tab | 0x30 none ⌥ repeat cycle-windows forward
        mod+equal | 0x18 = ⌘ repeat zoom-in",
    );
    assert_eq!(reply["warnings"], json!([]), "{table}");
    assert_eq!(keys.len(), 45, "{table}");
    assert_eq!(reply["super"], "cmd");

    // A chord that holds Command and Control leaves nothing to displace an
    // explicit ctrl to: those five bindings are skipped, each with a warning.
    assert_eq!(
        h.ok(json!({"op":"set_platform","super":" Cmd + CTRL "})),
        json!({"super":"ctrl+cmd"})
    );
    let reply = h.ok(json!({"op":"bindings"}));
    let table = listing(&reply);
    let keys = by_combo(&reply["keys"]);
    assert_eq!(keys.len(), 40, "{table}");
    assert_keys(
        &reply,
        "mod+alt+Right | 0x7C none ⌃⌥⌘ once send-to-output right",
    );
    let warnings: Vec<&str> = reply["warnings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w.as_str().unwrap())
        .collect();
    assert_eq!(warnings.len(), 5, "{table}");
    assert_eq!(
        warnings[0],
        "binding 'mod+ctrl+Down' = 'pan-viewport down' skipped: super is ctrl+cmd: it holds ctrl and Command, so nothing is left to stand for ctrl on its own"
    );
    assert!(
        warnings.iter().all(|w| w.starts_with("binding 'mod+ctrl+")),
        "{table}"
    );
    // Anything but a subset of ctrl, alt and cmd is refused and changes nothing.
    for chord in ["", "ctrl+", "ctrl+shift", "meta", "super"] {
        assert_eq!(
            h.error(json!({"op":"set_platform","super":chord})),
            format!("invalid super chord '{chord}': expected a +-joined subset of ctrl, alt, cmd")
        );
    }
    assert_eq!(h.ok(json!({"op":"bindings"}))["super"], "ctrl+cmd");

    // mod_key = "alt": `mod` is Option and the super chord is not involved.
    // Upstream drops its mod+alt send-to-output defaults in that case.
    let mut h = configured(&scratch, "mod_key = \"alt\"\n");
    let reply = h.ok(json!({"op":"bindings"}));
    let table = listing(&reply);
    let keys = by_combo(&reply["keys"]);
    assert_keys(
        &reply,
        "mod+a | 0x00 a ⌥ once home-toggle
        mod+ctrl+Right | 0x7C none ⌃⌥ repeat pan-viewport right
        mod+shift+1 | 0x12 1 ⌥⇧ once set-bookmark 1
        mod+Tab | 0x30 none ⌥ repeat cycle-windows forward
        mod+equal | 0x18 = ⌥ repeat zoom-in",
    );
    assert!(!keys.contains_key("mod+alt+Right"), "{table}");
    assert_eq!(keys.len(), 41, "{table}");
    assert_eq!(reply["warnings"], json!([]), "{table}");

    // mod_key = "mod3": macOS has no such modifier, so only upstream's two
    // alt+Tab bindings remain and each skipped binding says why.
    let mut h = Host::new();
    register(&mut h);
    h.load_config(&scratch.write("config.toml", "mod_key = \"mod3\"\n"));
    let reply = h.ok(json!({"op":"bindings"}));
    let keys = by_combo(&reply["keys"]);
    assert_eq!(
        keys.keys().collect::<Vec<_>>(),
        ["alt+Tab", "alt+shift+Tab"],
        "{}",
        listing(&reply)
    );
    let warnings = reply["warnings"].as_array().unwrap();
    assert_eq!(warnings.len(), 43);
    assert!(warnings.iter().all(|w| {
        w.as_str()
            .unwrap()
            .ends_with("skipped: macOS has no Mod3 modifier")
    }));
}

#[test]
fn colliding_and_unreachable_bindings_are_reported_with_a_deterministic_winner() {
    let scratch = Scratch::new();
    // Under Control+Option both of these are ⌃⌥⇧⌘→. Sorted by combo text the
    // first keeps the chord, whatever order upstream's table yields them in.
    let toml = r#"
[keybindings]
"mod+ctrl+shift+Right" = "zoom-out"
"mod+alt+Right" = "zoom-in"
"mod+XF86Calculator" = "zoom-reset"
"mod3+x" = "zoom-in"
"alt+shift" = "switch-layout next"
"Print" = "exec screencapture -c"
"shift+Print" = "none"
"mod+Escape" = "quit"
"ctrl+alt+a" = "zoom-to-fit"
"#;
    let toml = format!("{toml}{}", linux_programs(&scratch));
    let mut h = Host::new();
    register(&mut h);
    let loaded = h.load_config(&scratch.write("config.toml", &toml));
    assert_eq!(loaded["errors"], json!([]));
    assert_eq!(loaded["warnings"], json!([]));
    let reply = h.ok(json!({"op":"bindings"}));
    let table = listing(&reply);
    let keys = by_combo(&reply["keys"]);
    // Control+Option+A is both ctrl+alt+a and mod+a: the same rule decides.
    // A binding on the shell's exit chord is registered like any other.
    assert_keys(
        &reply,
        "mod+alt+Right | 0x7C none ⌃⌥⇧⌘ repeat zoom-in
        ctrl+alt+a | 0x00 a ⌃⌥ once zoom-to-fit
        mod+Escape | 0x35 none ⌃⌥ once quit",
    );
    assert!(!keys.contains_key("mod+ctrl+shift+Right"), "{table}");
    assert!(!keys.contains_key("mod+a"), "{table}");
    assert_eq!(
        reply["warnings"],
        json!([
            "binding 'Print' = 'exec screencapture -c' skipped: the key has no macOS equivalent",
            "binding 'mod+XF86Calculator' = 'zoom-reset' skipped: the key has no macOS equivalent",
            "binding 'mod+a' = 'home-toggle' skipped: 'ctrl+alt+a' already holds this macOS chord",
            "binding 'mod+ctrl+shift+Right' = 'zoom-out' skipped: 'mod+alt+Right' already holds this macOS chord",
            "binding 'mod3+x' = 'zoom-in' skipped: macOS has no Mod3 modifier",
            "binding 'alt+shift' = 'switch-layout next' skipped: tap-modifier bindings are not supported on macOS"
        ]),
        "{table}"
    );
    // `none` removed upstream's shift+Print, so it is not even listed.
    let skipped = by_combo(&reply["skipped"]);
    assert!(!skipped.contains_key("shift+Print"), "{table}");
    assert_eq!(skipped.len(), 8, "{table}");
    // And the exit chord then belongs to that binding.
    assert_eq!(reply["reserved"][0]["claimed_by"], "mod+Escape");
    assert_eq!(h.ok(json!({"op":"bindings"})), reply);
}

#[test]
fn canonical_action_strings_round_trip_through_a_config_file() {
    let scratch = Scratch::new();
    // One of every action upstream's grammar has, each in its canonical form.
    let actions = [
        "exec open -a \"Text Edit\" --args  -x",
        "exec-terminal",
        "exec-launcher",
        "spawn say hello",
        "close-window",
        "suspend-window",
        "nudge-window up-left",
        "grow-window down-right",
        "shrink-window left",
        "pan-viewport up-right",
        "center-window",
        "center-nearest down-left",
        "cycle-windows forward",
        "cycle-windows backward",
        "home-toggle",
        "go-to-bookmark my desk",
        "set-bookmark 1",
        "move-to-bookmark lab",
        "zoom-in",
        "zoom-out",
        "zoom-reset",
        "zoom-to-fit",
        "zoom-to-fit-snapped",
        "toggle-fullscreen",
        "fit-window",
        "fit-window-snapped",
        "fill-window",
        "send-to-output right",
        "send-cursor-to-output up",
        "focus-center",
        "toggle-pin-to-screen",
        "switch-layout next",
        "switch-layout prev",
        "switch-layout 2",
        "reload-config",
        "toggle-cursor-pan",
        "set-trackpad on",
        "set-trackpad off",
        "set-trackpad toggle",
        "quit",
    ];
    let names: Vec<String> = "abcdefghijklmnopqrstuvwxyz1234567890"
        .chars()
        .map(String::from)
        .chain((1..=12).map(|n| format!("F{n}")))
        .collect();
    assert!(names.len() >= actions.len());
    let mut toml = String::from("[bindings]\ndisable_defaults = [\"keys\"]\n[keybindings]\n");
    for (action, name) in actions.iter().zip(&names) {
        toml.push_str(&format!(
            "\"ctrl+shift+{name}\" = {}\n",
            toml_string(action)
        ));
    }
    let mut h = configured(&scratch, &toml);
    let reply = h.ok(json!({"op":"bindings"}));
    let keys = by_combo(&reply["keys"]);
    assert_eq!(keys.len(), actions.len(), "{}", listing(&reply));
    assert_eq!(reply["warnings"], json!([]));
    for (action, name) in actions.iter().zip(&names) {
        let entry = &keys[&format!("ctrl+shift+{name}")];
        assert_eq!(entry["action"], *action);
        assert_eq!(entry["modifiers"], chord("⌃⇧"));
        assert_eq!(
            parse_action(entry["action"].as_str().unwrap()),
            parse_action(action)
        );
    }
    // A spelling that is not canonical comes back canonical, and means the same.
    let mut h = configured(
        &scratch,
        "[keybindings]\n\"ctrl+shift+a\" = \"  pan-viewport   UP-Left \"\n\"ctrl+shift+b\" = \"switch-layout PREVIOUS\"\n\"ctrl+shift+c\" = \"set-trackpad OFF\"\n",
    );
    let keys = h.keys();
    for (combo, canonical, written) in [
        (
            "ctrl+shift+a",
            "pan-viewport up-left",
            "  pan-viewport   UP-Left ",
        ),
        (
            "ctrl+shift+b",
            "switch-layout prev",
            "switch-layout PREVIOUS",
        ),
        ("ctrl+shift+c", "set-trackpad off", "set-trackpad OFF"),
    ] {
        assert_eq!(keys[combo]["action"], canonical);
        assert_eq!(parse_action(canonical), parse_action(written));
    }
}
fn toml_string(text: &str) -> String {
    format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Upstream's default mouse bindings as macOS chords, one lookup per line:
/// trigger, scroll source, physical modifiers and context, then the binding's
/// kind and upstream combo, or `-` for none. An `action` kind is followed by
/// whether the action runs here and by the action itself.
const DEFAULT_MOUSE: &str = "
left - ⌥ window | move_window alt+left
left - ⌥⇧ window | move_snapped_windows alt+shift+left
right - ⌥ window | resize_window alt+right
right - ⌥⇧ window | resize_window_snapped alt+shift+right
middle - ⌥ window | action alt+middle no fit-window
middle - ⌥⇧ window | action alt+shift+middle no fit-window-snapped
middle - ⌃⌥ window | action mod+middle no toggle-fullscreen
left - - canvas | pan_viewport left
left - - window | -
right - - window | -
right - - canvas | -
middle - - window | -
left - ⌥ canvas | -
left - ⌃⌥ window | pan_viewport mod+left
left - ⌃⌥ canvas | pan_viewport mod+left
left - ⌃⌥⌘ window | center_nearest mod+ctrl+left
left - ⌃⌥⌘ canvas | center_nearest mod+ctrl+left
left - ⌘ canvas | -
scroll finger - canvas | pan_viewport trackpad-scroll
scroll wheel - canvas | zoom wheel-scroll
scroll continuous - canvas | zoom wheel-scroll
scroll - - canvas | zoom wheel-scroll
scroll finger - window | -
scroll wheel - window | -
scroll finger ⌃⌥ window | pan_viewport mod+trackpad-scroll
scroll wheel ⌃⌥ window | zoom mod+wheel-scroll
scroll finger ⌃⌥ canvas | pan_viewport mod+trackpad-scroll
scroll wheel ⌃⌥ canvas | zoom mod+wheel-scroll
scroll finger ⌥ canvas | -
back - - canvas | -
forward - ⌃⌥ window | -
";

#[test]
fn mouse_bindings_resolve_from_physical_chords() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, "");
    let bound = |kind: &str, action: Option<&str>, combo: &str, implemented: Option<bool>| json!({"kind":kind,"action":action,"combo":combo,"implemented":implemented});
    // A bare drag or scroll over a window is the app's; on the canvas it pans
    // or zooms. `mod` works anywhere, and mod+ctrl is displaced to Command.
    // Upstream's grammar has no name for the side buttons.
    for line in DEFAULT_MOUSE.lines().filter(|line| !line.is_empty()) {
        let (lookup, binding) = line.split_once(" | ").unwrap();
        let lookup: Vec<&str> = lookup.split(' ').collect();
        let source = match lookup[1] {
            "-" => Value::Null,
            source => json!(source),
        };
        let binding: Vec<&str> = binding.splitn(4, ' ').collect();
        let expected = match binding[..] {
            ["-"] => Value::Null,
            [kind, combo] => bound(kind, None, combo, None),
            [kind, combo, runs, action] => bound(kind, Some(action), combo, Some(runs == "yes")),
            _ => panic!("{line}"),
        };
        assert_eq!(
            h.mouse(lookup[0], source, lookup[2], lookup[3]),
            expected,
            "{line}"
        );
    }
    // A binding carries the speeds its gesture scales by.
    let reply = h.ok(json!({"op":"mouse_binding","trigger":"scroll","source":"wheel","modifiers":chord(""),"context":"canvas"}));
    assert_eq!(
        reply,
        json!({"binding":{"kind":"zoom","action":null,"combo":"wheel-scroll","implemented":null,"trackpad_speed":1.5,"mouse_speed":1.0,"zoom_step":1.1,"zoom_mouse_speed":1.0,"zoom_trackpad_speed":1.0}})
    );
    // Missing modifiers are not held; an unknown one is refused.
    assert_eq!(
        h.ok(json!({"op":"mouse_binding","trigger":"left","modifiers":{"option":true},"context":"window"}))["binding"]["kind"],
        "move_window"
    );
    for command in [
        json!({"op":"mouse_binding","trigger":"left","modifiers":{"fn":true},"context":"window"}),
        json!({"op":"mouse_binding","trigger":"left","modifiers":{},"context":"desktop"}),
        json!({"op":"mouse_binding","trigger":"wheel","modifiers":{},"context":"canvas"}),
        json!({"op":"mouse_binding","trigger":"scroll","source":"pen","modifiers":{},"context":"canvas"}),
    ] {
        h.error(command);
    }

    // Under --super cmd the same bindings sit on upstream's literal chords.
    h.ok(json!({"op":"set_platform","super":"cmd"}));
    for (glyphs, context, kind) in [
        ("⌘", "window", json!("pan_viewport")),
        ("⌃⌘", "canvas", json!("center_nearest")),
        ("⌥", "window", json!("move_window")),
        ("⌃⌥", "canvas", Value::Null),
    ] {
        assert_eq!(
            h.mouse("left", Value::Null, glyphs, context)["kind"],
            kind,
            "{glyphs}"
        );
    }

    // A file rebinds, unbinds, and binds any action; the window's own table
    // wins over `anywhere`, and the speeds are the file's.
    let mut h = configured(
        &scratch,
        r#"
[navigation]
trackpad_speed = 2.0
mouse_speed = 0.5
[zoom]
step = 1.25
mouse_speed = 3.0
trackpad_speed = 0.25
[mouse.on-window]
"mod+left" = "move-window"
"alt+left" = "none"
[mouse.on-canvas]
"mod+right" = "zoom-in"
"left" = "none"
[mouse.anywhere]
"mod+alt+left" = "exec open ."
"#,
    );
    for (glyphs, context, kind) in [
        ("⌃⌥", "window", json!("move_window")),
        ("⌃⌥", "canvas", json!("pan_viewport")),
        ("⌥", "window", Value::Null),
        ("", "canvas", Value::Null),
    ] {
        assert_eq!(
            h.mouse("left", Value::Null, glyphs, context)["kind"],
            kind,
            "{glyphs} on {context}"
        );
    }
    assert_eq!(
        h.mouse("right", Value::Null, "⌃⌥", "canvas"),
        bound("action", Some("zoom-in"), "mod+right", Some(true))
    );
    // mod+alt is displaced to ⌃⌥⇧⌘.
    assert_eq!(
        h.mouse("left", Value::Null, "⌃⌥⇧⌘", "window"),
        bound("action", Some("exec open ."), "mod+alt+left", Some(true))
    );
    let reply = h.ok(
        json!({"op":"mouse_binding","trigger":"left","modifiers":chord("⌃⌥"),"context":"canvas"}),
    );
    assert_eq!(
        reply,
        json!({"binding":{"kind":"pan_viewport","action":null,"combo":"mod+left","implemented":null,"trackpad_speed":2.0,"mouse_speed":0.5,"zoom_step":1.25,"zoom_mouse_speed":3.0,"zoom_trackpad_speed":0.25}})
    );
    assert_eq!(
        h.ok(json!({"op":"mouse_binding","trigger":"left","modifiers":{},"context":"canvas"})),
        json!({"binding":null})
    );

    // Two upstream chords on one physical chord: the pointer's own context
    // table is asked for both before `anywhere` is asked for either.
    let mut h = configured(
        &scratch,
        "[mouse.on-window]\n\"mod+left\" = \"move-window\"\n[mouse.anywhere]\n\"ctrl+alt+left\" = \"zoom\"\n",
    );
    assert_eq!(
        h.mouse("left", Value::Null, "⌃⌥", "window"),
        bound("move_window", None, "mod+left", None)
    );
    assert_eq!(
        h.mouse("left", Value::Null, "⌃⌥", "canvas"),
        bound("zoom", None, "ctrl+alt+left", None)
    );
}

#[test]
fn nudge_exec_spawn_and_reload_actions() {
    let scratch = Scratch::new();
    let mut h = configured(&scratch, "");
    attach(&mut h, 1, rect(100.0, 200.0, 400.0, 300.0));
    let idle = json!({"navigation":null,"effects":[],"dirty":false});
    let moved = json!({"navigation":null,"effects":[],"dirty":true});
    // No focused window is no error upstream, and nothing to save.
    assert_eq!(h.action("nudge-window right"), idle);
    assert_eq!(h.world(1), rect(100.0, 200.0, 400.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    // navigation.nudge_step is 20 world points; a diagonal rounds each axis.
    assert_eq!(h.action("nudge-window right"), moved);
    assert_eq!(h.world(1), rect(120.0, 200.0, 400.0, 300.0));
    assert_eq!(h.action("nudge-window up-left"), moved);
    assert_eq!(h.world(1), rect(106.0, 186.0, 400.0, 300.0));
    // It needs no output, and goes through the IPC action request too.
    assert_eq!(
        h.ok(json!({"op":"action","output":null,"action":"nudge-window down"})),
        moved
    );
    assert_eq!(
        h.ok(json!({"op":"ipc","output":null,"request":{"Action":"nudge-window left"}})),
        json!({"reply":{"Ok":"Ok"},"effects":[],"dirty":true,"navigation":null})
    );
    assert_eq!(h.world(1), rect(86.0, 206.0, 400.0, 300.0));
    // A window under a gesture is not nudged.
    h.ok(json!({"op":"begin_drag","window":1,"output":1}));
    assert_eq!(
        h.error(json!({"op":"action","output":1,"action":"nudge-window up"})),
        "a window is under an interactive move or resize"
    );
    h.ok(json!({"op":"end_gesture"}));
    // The step is the file's.
    let mut h = configured(&scratch, "[navigation]\nnudge_step = 7\n");
    attach(&mut h, 1, rect(100.0, 200.0, 400.0, 300.0));
    h.ok(json!({"op":"focus","window":1}));
    h.action("nudge-window down-right");
    assert_eq!(h.world(1), rect(105.0, 205.0, 400.0, 300.0));

    // exec and spawn are the shell's to run: upstream's `sh -c` command and
    // the child environment, which the controller never executes itself.
    let mut h = configured(&scratch, "");
    let exec = |command: &str, env: Value| json!({"navigation":null,"effects":[{"op":"exec","command":command,"env":env}],"dirty":false});
    assert_eq!(
        h.action("exec open -a TextEdit  \"$HOME/a b.txt\""),
        exec("open -a TextEdit  \"$HOME/a b.txt\"", json!({}))
    );
    assert_eq!(h.action("spawn say hi"), exec("say hi", json!({})));
    assert_eq!(
        h.ok(json!({"op":"action","output":null,"action":"exec true"})),
        exec("true", json!({}))
    );
    assert_eq!(
        h.ok(json!({"op":"ipc","output":null,"request":{"Action":"spawn true"}})),
        json!({"reply":{"Ok":"Ok"},"effects":[{"op":"exec","command":"true","env":{}}],"dirty":false,"navigation":null})
    );
    // exec-terminal and exec-launcher: the user's variable, else the macOS
    // default. The expectation reads the same environment the controller does.
    let or = |variable: &str, fallback: &str| {
        std::env::var(variable)
            .ok()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| fallback.to_owned())
    };
    assert_eq!(
        h.action("exec-terminal"),
        exec(&or("TERMINAL", "open -a Terminal \"$HOME\""), json!({}))
    );
    assert_eq!(
        h.action("exec-launcher"),
        exec(&or("LAUNCHER", "open -a Apps"), json!({}))
    );
    // reload-config asks the shell to send load_config again.
    assert_eq!(
        h.action("reload-config"),
        json!({"navigation":null,"effects":[{"op":"reload_config"}],"dirty":false})
    );

    // [env] and the cursor variables reach the child. Upstream's Wayland
    // toolkit fallbacks do not, unless the file itself sets one.
    let mut h = configured(
        &scratch,
        "[env]\nFOO = \"bar\"\nQT_QPA_PLATFORM = \"cocoa\"\n[cursor]\ntheme = \"Adwaita\"\nsize = 24\n",
    );
    assert_eq!(
        h.action("exec env"),
        exec(
            "env",
            json!({"FOO":"bar","QT_QPA_PLATFORM":"cocoa","XCURSOR_SIZE":"24","XCURSOR_THEME":"Adwaita"})
        )
    );
}

#[test]
fn session_flags_govern_what_a_scene_file_restores() {
    let scratch = Scratch::new();
    let scene = scratch.path("scene.json");
    let absent = scratch.path("absent.toml");
    let restoring = scratch.write(
        "restore.toml",
        "[session]\nrestore_camera = true\nrestore_bookmarks = true\n",
    );
    let bookmarks_only = scratch.write("bookmarks.toml", "[session]\nrestore_bookmarks = true\n");
    let saved_camera = point(300.0, 200.0);
    let saved_bookmarks = json!({"1":[5.0,5.0],"saved":[40.0,50.0]});
    // A scene written by a run with no config: camera and bookmarks as left.
    {
        let mut h = Host::new();
        register(&mut h);
        h.ok(json!({"op":"pan","output":1,"screen_delta":saved_camera}));
        for (name, to) in [("1", [5.0, 5.0]), ("saved", [40.0, 50.0])] {
            h.ok(json!({"op":"ipc","output":null,"request":{"Bookmark":{"name":name,"to":to}}}));
        }
        h.ok(json!({"op":"save","path":scene}));
    }
    let file = |path: &PathBuf| -> Value {
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    };
    assert_eq!(file(&scene)["bookmarks"], saved_bookmarks);

    // Upstream's defaults restore neither: the output starts at a new
    // output's camera and the registry is the config seeds alone.
    let mut h = Host::new();
    h.load_config(&absent);
    h.ok(json!({"op":"load","path":scene}));
    register(&mut h);
    assert_eq!(h.camera(), point(0.0, 0.0));
    assert_eq!(h.bookmarks(), seeds());
    // Runtime edits are ephemeral with the flag off: a save carries the file's
    // registry forward untouched, and the camera in use is the one written.
    h.ok(json!({"op":"ipc","output":null,"request":{"Bookmark":{"name":"temp","to":[1.0,1.0]}}}));
    let copy = scratch.path("copy.json");
    h.ok(json!({"op":"save","path":copy}));
    assert_eq!(file(&copy)["bookmarks"], saved_bookmarks);
    assert_eq!(
        file(&copy)["outputs"]["1"]["viewport"]["camera"],
        point(0.0, 0.0)
    );
    // The session's own camera survives its output reconnecting.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(70.0, 80.0)}));
    h.ok(json!({"op":"remove_output","output":1}));
    register(&mut h);
    assert_eq!(h.camera(), point(70.0, 80.0));
    // An output that never connects keeps its saved camera in the file.
    let mut h = Host::new();
    h.load_config(&absent);
    h.ok(json!({"op":"load","path":scene}));
    h.ok(json!({"op":"save","path":copy}));
    assert_eq!(
        file(&copy)["outputs"]["1"]["viewport"]["camera"],
        saved_camera
    );

    // Both flags on: the camera comes back, and the saved registry lies over
    // the seeds, a saved value winning per name.
    let mut restored = seeds();
    restored["1"] = json!([5.0, 5.0]);
    restored["saved"] = json!([40.0, 50.0]);
    let mut h = Host::new();
    h.load_config(&restoring);
    h.ok(json!({"op":"load","path":scene}));
    register(&mut h);
    assert_eq!(h.camera(), saved_camera);
    assert_eq!(h.bookmarks(), restored);
    // With restore on the live registry is the durable one.
    h.ok(json!({"op":"ipc","output":null,"request":{"Bookmark":{"name":"kept","to":[1.0,1.0]}}}));
    h.ok(json!({"op":"save","path":copy}));
    let mut written = restored.clone();
    written["kept"] = json!([1.0, 1.0]);
    assert_eq!(file(&copy)["bookmarks"], written);
    // Each flag stands alone.
    let mut h = Host::new();
    h.load_config(&bookmarks_only);
    h.ok(json!({"op":"load","path":scene}));
    register(&mut h);
    assert_eq!(h.camera(), point(0.0, 0.0));
    assert_eq!(h.bookmarks(), restored);

    // The shell may load the scene before the config, and even show an output
    // first: the first config still decides, with the same results.
    for (config, camera, bookmarks) in [
        (&absent, point(0.0, 0.0), seeds()),
        (&restoring, saved_camera.clone(), restored.clone()),
    ] {
        let mut h = Host::new();
        h.ok(json!({"op":"load","path":scene}));
        h.load_config(config);
        register(&mut h);
        assert_eq!(h.camera(), camera);
        assert_eq!(h.bookmarks(), bookmarks);

        let mut h = Host::new();
        h.ok(json!({"op":"load","path":scene}));
        register(&mut h);
        assert_eq!(h.camera(), saved_camera);
        h.load_config(config);
        assert_eq!(h.camera(), camera);
        assert_eq!(h.snapshot()["outputs"][0]["zoom"], 1.0);
        assert_eq!(h.bookmarks(), bookmarks);
        // Only the first config of a run is the launch: a reload moves nothing.
        h.ok(json!({"op":"pan","output":1,"screen_delta":point(11.0, 12.0)}));
        let moved = h.camera();
        h.load_config(&absent);
        h.load_config(&restoring);
        assert_eq!(h.camera(), moved);
    }
    // A scene loaded under a config keeps that config.
    let mut h = Host::new();
    h.load_config(&scratch.write("pan.toml", "[navigation]\npan_step = 250.0\n"));
    h.ok(json!({"op":"set_platform","super":"cmd"}));
    h.ok(json!({"op":"load","path":scene}));
    register(&mut h);
    assert_eq!(target(&h.action("pan-viewport right")).0, point(250.0, 0.0));
    assert_eq!(h.ok(json!({"op":"bindings"}))["super"], "cmd");
}
