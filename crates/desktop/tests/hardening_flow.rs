// SPDX-License-Identifier: GPL-3.0-or-later
//! DriftWM v0.21.0's hardening (df3de27b26c7998e8a460cffd8a4925cbed3a322) as it
//! applies to a saved scene and to a stand-in: through the exported C ABI and
//! JSON decoder with synthetic observations, and real files in a directory of
//! the test's own. They say nothing about a native window, a socket of the app,
//! a screenshot written by the shell or the descriptors of a spawned command:
//! those live in the shell and are exercised by `tests/e2e/ipc-limits.sh`.
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

#[path = "support/host.rs"]
mod host;
use host::Host;

impl Host {
    /// The logical ids of the windows in the scene, bottom to top.
    fn ids(&mut self) -> Vec<u64> {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|w| w["window"].as_u64().unwrap())
            .collect()
    }
    fn world(&mut self, id: u64) -> Value {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == id)
            .unwrap_or_else(|| panic!("no window {id}"))["world_rect"]
            .clone()
    }
}
/// A directory of this test's own, removed when the test ends.
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "infinify-hardening-flow-{}-{}",
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
fn identity(wid: u64) -> Value {
    json!({"pid":4242,"birth_sec":1800000000,"birth_usec":77,"wid":wid,"owner":null})
}
fn open(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"main","screen_bounds":rect(0.0,0.0,1000.0,800.0)}));
}
/// A bound window at a world frame; its native frame is somewhere else.
fn put(h: &mut Host, wid: u64, app: &str, world: Value) {
    h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":app,"buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"world_rect":world}));
}
fn file(path: &PathBuf) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

#[test]
fn a_stand_in_is_cut_to_the_largest_chrome_buffer_and_keeps_its_top_left() {
    let scratch = Scratch::new();
    let config = scratch.path("config.toml");
    std::fs::write(&config, "[session]\nsuspend_on_close = true\n").unwrap();
    let mut h = Host::new();
    open(&mut h);
    let reply = h.ok(json!({"op":"load_config","path":config}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    h.ok(json!({"op":"adoption_complete"}));
    put(&mut h, 1, "app.wide", rect(-500.0, 40.0, 20000.0, 300.0));
    put(&mut h, 2, "app.tall", rect(100.0, -700.0, 400.0, 16385.0));
    put(&mut h, 3, "app.exact", rect(900.0, 0.0, 16384.0, 16384.0));
    put(&mut h, 4, "app.small", rect(0.0, 5000.0, 400.0, 300.0));
    for wid in 1..=4 {
        let source = h.snapshot()["windows"][wid as usize - 1]["source"]["identity"].clone();
        let closed = h.ok(json!({"op":"window_closed","window":wid,"identity":source}));
        assert_eq!(closed["standin"], true, "{closed}");
    }
    // Past the ceiling on one side only: that side is cut, the origin is kept.
    assert_eq!(h.world(1), rect(-500.0, 40.0, 16384.0, 300.0));
    assert_eq!(h.world(2), rect(100.0, -700.0, 400.0, 16384.0));
    // At the ceiling, and below it, nothing changes.
    assert_eq!(h.world(3), rect(900.0, 0.0, 16384.0, 16384.0));
    assert_eq!(h.world(4), rect(0.0, 5000.0, 400.0, 300.0));
}

/// A scene with a window per case: kept, too large to be a stand-in, too wide
/// by one pixel, beyond the position limit on either axis, and exactly at it.
fn scene_with_slots(h: &mut Host, path: &PathBuf) {
    open(h);
    put(h, 1, "app.kept", rect(100.0, 100.0, 400.0, 300.0));
    put(h, 2, "app.huge", rect(0.0, 0.0, 16385.0, 300.0));
    put(h, 3, "app.tall", rect(0.0, 0.0, 300.0, 40000.0));
    put(h, 4, "app.far-x", rect(1_050_000_001.0, 0.0, 400.0, 300.0));
    put(h, 5, "app.far-y", rect(0.0, -1_050_000_001.0, 400.0, 300.0));
    put(
        h,
        6,
        "app.edge",
        rect(1_050_000_000.0, -1_050_000_000.0, 400.0, 300.0),
    );
    put(h, 7, "app.biggest", rect(20.0, 20.0, 16384.0, 16384.0));
    h.ok(json!({"op":"focus","window":4}));
    h.ok(json!({"op":"save","path":path}));
}

#[test]
fn restoring_a_scene_drops_the_slots_a_stand_in_could_not_be_or_that_lie_past_the_window_range() {
    let scratch = Scratch::new();
    let saved = scratch.path("scene.json");
    {
        let mut h = Host::new();
        scene_with_slots(&mut h, &saved);
        // Focusing window 4 raised it.
        assert_eq!(h.ids(), [1, 2, 3, 5, 6, 7, 4]);
        assert_eq!(h.snapshot()["focus"]["intent"], 4);
    }
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":saved}));
    // Only the window that could never have been drawn as a stand-in goes, with
    // all that was saved about it; the rest of the scene restores whole.
    assert_eq!(h.ids(), [1, 6, 7]);
    let snapshot = h.snapshot();
    assert_eq!(h.world(1), rect(100.0, 100.0, 400.0, 300.0));
    assert_eq!(
        h.world(6),
        rect(1_050_000_000.0, -1_050_000_000.0, 400.0, 300.0)
    );
    assert_eq!(h.world(7), rect(20.0, 20.0, 16384.0, 16384.0));
    // Window 4 was the focused one and was not restored: upstream starts
    // unfocused when the focused window is not restored, it does not hand the
    // focus to whichever window is on top.
    assert_eq!(snapshot["focus"]["intent"], Value::Null, "{snapshot}");
    // What is saved again no longer carries them.
    let again = scratch.path("again.json");
    h.ok(json!({"op":"save","path":again}));
    let text = std::fs::read_to_string(&again).unwrap();
    for gone in ["app.huge", "app.tall", "app.far-x", "app.far-y"] {
        assert!(!text.contains(gone), "{gone} survived the restore");
    }
}

#[test]
fn restoring_a_scene_keeps_only_the_bookmarks_a_set_would_have_accepted() {
    let scratch = Scratch::new();
    let saved = scratch.path("scene.json");
    {
        let mut h = Host::new();
        open(&mut h);
        h.ok(json!({"op":"save","path":saved}));
    }
    let mut scene = file(&saved);
    let long = "n".repeat(257);
    let mut bookmarks = json!({
        "kept":[10.0,-20.0],
        "edge":[1e9,-1e9],
        "far":[1_000_000_001.0,0.0],
        "farther":[0.0,-2e9]
    });
    bookmarks[long.as_str()] = json!([0.0, 0.0]);
    bookmarks["a name of 256 bytes".to_owned() + &"n".repeat(237)] = json!([1.0, 1.0]);
    scene["bookmarks"] = bookmarks;
    std::fs::write(&saved, serde_json::to_vec(&scene).unwrap()).unwrap();

    let mut h = Host::new();
    h.ok(json!({"op":"load","path":saved}));
    let kept = h.snapshot()["bookmarks"].clone();
    let names: Vec<&str> = kept
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert!(
        names.contains(&"kept") && names.contains(&"edge"),
        "{names:?}"
    );
    assert!(
        !names.contains(&"far") && !names.contains(&"farther"),
        "{names:?}"
    );
    assert!(
        !names.contains(&long.as_str()),
        "an overlong name is dropped"
    );
    assert_eq!(names.len(), 3, "{names:?}");
    assert_eq!(kept["kept"], json!([10.0, -20.0]));
}

#[test]
fn restoring_a_scene_keeps_at_most_256_bookmarks() {
    let scratch = Scratch::new();
    let saved = scratch.path("scene.json");
    {
        let mut h = Host::new();
        open(&mut h);
        h.ok(json!({"op":"save","path":saved}));
    }
    let mut scene = file(&saved);
    let many: serde_json::Map<String, Value> = (0..300)
        .map(|index| (format!("mark-{index:03}"), json!([index as f64, 0.0])))
        .collect();
    scene["bookmarks"] = Value::Object(many);
    std::fs::write(&saved, serde_json::to_vec(&scene).unwrap()).unwrap();
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":saved}));
    assert_eq!(h.snapshot()["bookmarks"].as_object().unwrap().len(), 256);
}

#[test]
fn a_saved_camera_past_the_window_range_is_not_restored() {
    let scratch = Scratch::new();
    let saved = scratch.path("scene.json");
    {
        let mut h = Host::new();
        open(&mut h);
        h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":1_050_000_001.0,"y":-5.0}}));
        h.ok(json!({"op":"save","path":saved}));
        assert_eq!(
            file(&saved)["outputs"]["1"]["viewport"]["camera"],
            json!({"x":1_050_000_001.0,"y":-5.0}),
            "the fixture saved the far camera"
        );
    }
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":saved}));
    let copy = scratch.path("copy.json");
    h.ok(json!({"op":"save","path":copy}));
    let viewport = &file(&copy)["outputs"]["1"]["viewport"];
    assert_eq!(viewport["camera"], json!({"x":0.0,"y":0.0}), "{viewport}");
    assert_eq!(viewport["zoom"], 1.0);

    // A camera at the limit itself is a place a window may be, and comes back.
    {
        let mut h = Host::new();
        open(&mut h);
        h.ok(json!({"op":"pan","output":1,"screen_delta":{"x":1_050_000_000.0,"y":-5.0}}));
        h.ok(json!({"op":"save","path":saved}));
    }
    let mut h = Host::new();
    h.ok(json!({"op":"load","path":saved}));
    h.ok(json!({"op":"save","path":copy}));
    assert_eq!(
        file(&copy)["outputs"]["1"]["viewport"]["camera"],
        json!({"x":1_050_000_000.0,"y":-5.0})
    );
}

#[test]
fn the_scene_file_is_owner_only_and_leaves_no_temporary_behind() {
    let scratch = Scratch::new();
    let saved = scratch.path("scene.json");
    let mut h = Host::new();
    open(&mut h);
    put(&mut h, 1, "app.kept", rect(100.0, 100.0, 400.0, 300.0));
    for _ in 0..2 {
        h.ok(json!({"op":"save","path":saved}));
        let mode = std::fs::metadata(&saved).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600, "mode {mode:o}");
    }
    // A file that was group- and world-readable is replaced, not written
    // through, so the new one is private whatever the old one was.
    std::fs::set_permissions(&saved, std::fs::Permissions::from_mode(0o644)).unwrap();
    h.ok(json!({"op":"save","path":saved}));
    let mode = std::fs::metadata(&saved).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600, "mode {mode:o}");
    let names: Vec<_> = std::fs::read_dir(&scratch.0)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, ["scene.json"], "no .tmp is left beside the scene");
}

#[test]
fn exec_terminal_and_exec_launcher_read_the_config_env_before_the_process_env() {
    let scratch = Scratch::new();
    let config = scratch.path("config.toml");
    // $TERMINAL and $LAUNCHER as children see them: the config's [env] first.
    // An empty value is a value, and gets the macOS default, not the process's.
    std::fs::write(
        &config,
        "[env]\nTERMINAL = \"kitty --single-instance\"\nLAUNCHER = \"\"\n",
    )
    .unwrap();
    let mut h = Host::new();
    open(&mut h);
    let reply = h.ok(json!({"op":"load_config","path":config}));
    assert_eq!(reply["errors"], json!([]), "{reply}");
    let terminal = h.ok(json!({"op":"action","output":1,"action":"exec-terminal"}));
    assert_eq!(terminal["effects"][0]["op"], "exec");
    assert_eq!(terminal["effects"][0]["command"], "kitty --single-instance");
    let launcher = h.ok(json!({"op":"action","output":1,"action":"exec-launcher"}));
    assert_eq!(launcher["effects"][0]["command"], "open -a Apps");
    // The names the effect carries to the shell are the config's own [env].
    assert_eq!(
        terminal["effects"][0]["env"]["TERMINAL"],
        "kitty --single-instance"
    );
}
