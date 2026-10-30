// SPDX-License-Identifier: GPL-3.0-or-later
//! Effects scenarios cross the exported C ABI and JSON decoder with synthetic
//! observations and config files written to a throwaway directory. The
//! `[effects]` table and a window's blur are compared with driftwm-core's own
//! parser and `effective_blur`; which window events are logged is derived by
//! hand from upstream's rules. They provide no evidence that anything is
//! blurred, animated or drawn in an error bar: the snapshot here is a
//! description nobody renders.
use driftwm_core::config::{Config, EffectsConfig, effective_blur};
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
    fn render(&mut self) -> Value {
        self.snapshot()["render"].clone()
    }
    fn revision(&mut self) -> u64 {
        self.render()["revision"].as_u64().unwrap()
    }
    fn errors(&mut self) -> Value {
        self.render()["errors"].clone()
    }
    fn events(&mut self) -> Value {
        self.snapshot()["lifecycle_events"].clone()
    }
    /// Write the config file and load it, whatever comes of it.
    fn load_config(&mut self, scratch: &Scratch, toml: &str) -> Value {
        let path = scratch.path("config.toml");
        std::fs::write(&path, toml).unwrap();
        self.ok(json!({"op":"load_config","path":path}))
    }
    /// Write the config file and load it: accepted, and without a warning.
    fn configure(&mut self, scratch: &Scratch, toml: &str) {
        let reply = self.load_config(scratch, toml);
        assert_eq!(reply["errors"], json!([]), "{reply}");
        assert_eq!(reply["warnings"], json!([]), "{reply}");
    }
    /// The window's entry in the snapshot's window list.
    fn window(&mut self, window: u64) -> Value {
        self.snapshot()["windows"]
            .as_array()
            .unwrap()
            .iter()
            .find(|w| w["window"] == window)
            .unwrap_or_else(|| panic!("no window {window}"))
            .clone()
    }
    /// What the window is drawn as and whether its backdrop is frosted: the
    /// same in its placement on the one output and in the window list.
    fn blur(&mut self, window: u64) -> (String, bool) {
        let snapshot = self.snapshot();
        let placed: Vec<&Value> = snapshot["placements"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|p| p["window"] == window)
            .collect();
        assert_eq!(placed.len(), 1, "window {window}");
        let entry = self.window(window);
        assert_eq!(placed[0]["decoration"], entry["decoration"]);
        assert_eq!(placed[0]["kind"], entry["kind"]);
        (
            entry["kind"].as_str().unwrap().to_owned(),
            entry["decoration"]["blur"].as_bool().unwrap(),
        )
    }
    fn ipc(&mut self, output: Value, request: Value) -> Value {
        self.ok(json!({"op":"ipc","output":output,"request":request}))
    }
    /// The native window is gone, reported with the active output or without.
    fn closed(&mut self, window: u64, output: Value) -> Value {
        let identity = self.window(window)["source"]["identity"].clone();
        self.ok(json!({"op":"window_closed","window":window,"identity":identity,"output":output}))
    }
    /// The bound window loses its source and stays as a waiting slot.
    fn detach(&mut self, window: u64) {
        let identity = self.window(window)["source"]["identity"].clone();
        self.ok(json!({"op":"remove_source","window":window,"identity":identity,"keep_placeholder":true}));
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
            "infinify-effects-flow-{}-{}",
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
    json!({"pid":4242,"birth_sec":1800000000,"birth_usec":77,"wid":wid})
}
/// One output of 1000 x 800 whose top-left is the global point (200, 100).
fn open(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"main","screen_bounds":rect(200.0,100.0,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,0.0,1000.0,800.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
}
/// A window that appeared by itself, reported with the active output and the
/// pointer or with neither. The logical id it got, and whether it took a slot.
fn appear(h: &mut Host, wid: u64, app: &str, title: &str, output: bool) -> (u64, bool) {
    let mut command = json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":title,"buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0)});
    if output {
        command["output"] = json!(1);
        command["pointer"] = json!({"x":700.0,"y":500.0});
    }
    let reply = h.ok(command);
    (
        reply["window"].as_u64().unwrap(),
        reply["adopted"].as_bool().unwrap(),
    )
}
/// A window the caller puts at a world rectangle, as the chooser does.
fn put(h: &mut Host, wid: u64, app: &str, title: &str, world: Value) -> u64 {
    let reply = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":title,"buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"world_rect":world}));
    reply["window"].as_u64().unwrap()
}
/// `render.effects` for one of driftwm-core's tables.
fn block(effects: &EffectsConfig) -> Value {
    json!({"blur_radius":effects.blur_radius,"blur_strength":effects.blur_strength,"animate_blur_fps":effects.animate_blur_fps,"animation_speed":effects.animation_speed,"animation_scale":effects.animation_scale})
}
fn event(serial: u64, window: u64, event: &str, output: Value) -> Value {
    json!({"serial":serial,"window":window,"event":event,"output":output})
}
/// Answer one resize effect as the shell's adapter would: the window found
/// with `size` at a native origin no world frame reads, or not found at all.
fn resized(
    h: &mut Host,
    effect: &Value,
    outcome: &str,
    attempted: bool,
    size: (f64, f64),
) -> Value {
    let observed = outcome != "missing_window";
    let frame = rect(4000.0, 3000.0, size.0, size.1);
    let requested = match effect["requested"].is_null() {
        true => json!({"width":0.0,"height":0.0}),
        false => effect["requested"].clone(),
    };
    h.ok(json!({"op":"native_resize_result","transaction":effect["transaction"],"effect_id":effect["effect_id"],"identity":effect["identity"],"generation":effect["generation"],"result":{"outcome":outcome,"ax_error":0,"mutation_attempted":attempted,"observed":observed,"requested":requested,"actual_ax":frame,"actual_cg":frame}}))
}

#[test]
fn the_effects_block_is_cores_parsed_table_and_a_change_spends_a_revision() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    // Upstream's defaults, which is also what its parser makes of no table:
    // before any config, and after a launch file without one.
    let defaults = EffectsConfig::default();
    assert_eq!(Config::from_toml("").unwrap().effects, defaults);
    assert_eq!(
        block(&defaults),
        // v0.20: blur_radius 2 -> 5 and blur_strength 1.1 -> 1.5.
        json!({"blur_radius":5,"blur_strength":1.5,"animate_blur_fps":20,"animation_speed":0.5,"animation_scale":0.95})
    );
    assert_eq!(h.render()["effects"], block(&defaults));
    open(&mut h);
    h.configure(&scratch, "[navigation]\npan_step = 123\n");
    assert_eq!(h.render()["effects"], block(&defaults));
    // The first Mac config activates inherited wallpaper/parallax and therefore
    // changes render policy even though this effects table stays at its default.
    assert_eq!(h.render()["background"]["inherit_macos"], true);
    assert_eq!(h.revision(), 1);

    // A reload that sets every key: the block is the file's table, and the
    // reload spends a revision as every accepted one does.
    let written = "[effects]\nblur_radius = 4\nblur_strength = 2.5\nanimate_blur_fps = 60\nanimation_speed = 0.25\nanimation_scale = 0.8\n";
    h.configure(&scratch, written);
    let table = json!({"blur_radius":4,"blur_strength":2.5,"animate_blur_fps":60,"animation_speed":0.25,"animation_scale":0.8});
    assert_eq!(h.render()["effects"], table);
    assert_eq!(block(&Config::from_toml(written).unwrap().effects), table);
    assert_eq!(h.revision(), 2);
    // One key changed, and the edges upstream's ranges include: a speed of 1
    // is instant, a scale of 1 fades without scaling, 0 turns the refresh off.
    let edges = "[effects]\nblur_radius = 0\nblur_strength = 0.0\nanimate_blur_fps = 0\nanimation_speed = 1.0\nanimation_scale = 1.0\n";
    h.configure(&scratch, edges);
    assert_eq!(
        h.render()["effects"],
        json!({"blur_radius":0,"blur_strength":0.0,"animate_blur_fps":0,"animation_speed":1.0,"animation_scale":1.0})
    );
    assert_eq!(h.revision(), 3);

    // Values outside upstream's ranges are the parser's to mend, and it says
    // so: a negative strength is 0, the refresh rate is capped at 144 without
    // a word, a speed that is not above 0 is the default, a scale above 1 is 1.
    let mended = "[effects]\nblur_radius = 9\nblur_strength = -1.5\nanimate_blur_fps = 500\nanimation_speed = 0.0\nanimation_scale = 1.5\n";
    let reply = h.load_config(&scratch, mended);
    let (config, warnings) = Config::from_toml_collect(mended).unwrap();
    assert_eq!(reply["errors"], json!([]));
    assert_eq!(reply["warnings"], json!(warnings));
    assert_eq!(warnings.len(), 3, "{warnings:?}");
    assert!(
        warnings[0].contains("effects.animation_speed"),
        "{warnings:?}"
    );
    let table = json!({"blur_radius":9,"blur_strength":0.0,"animate_blur_fps":144,"animation_speed":0.5,"animation_scale":1.0});
    assert_eq!(h.render()["effects"], table);
    assert_eq!(block(&config.effects), table);
    assert_eq!(h.revision(), 4);
    // Not a number is no speed and no scale either: the defaults.
    let reply = h.load_config(
        &scratch,
        "[effects]\nanimation_speed = nan\nanimation_scale = nan\n",
    );
    assert_eq!(reply["warnings"].as_array().unwrap().len(), 2, "{reply}");
    assert_eq!(h.render()["effects"], block(&defaults));
    assert_eq!(h.revision(), 5);
    // The key upstream retired is accepted and warned about.
    let reply = h.load_config(
        &scratch,
        "[effects]\nanimate_blur = true\nblur_radius = 3\n",
    );
    assert_eq!(reply["warnings"].as_array().unwrap().len(), 1, "{reply}");
    assert_eq!(h.render()["effects"]["blur_radius"], 3);
    assert_eq!(h.revision(), 6);
    h.configure(&scratch, written);
    assert_eq!(h.revision(), 7);

    // A value of the wrong type and a key upstream does not have are parse
    // failures: the file is refused whole and the table in force stays.
    let kept = h.render()["effects"].clone();
    for refused in ["[effects]\nblur_radius = -1\n", "[effects]\nglow = 1\n"] {
        let reply = h.load_config(&scratch, refused);
        assert_eq!(reply["errors"].as_array().unwrap().len(), 1, "{reply}");
        assert_eq!(h.render()["effects"], kept, "{refused}");
    }
    // An infinite strength is the one value upstream's parser lets through
    // that no JSON number can say. It is accepted without a word, and the
    // block says 0, what the shell's compositor makes of it, and not null.
    let endless = "[effects]\nblur_strength = inf\n";
    let parsed = Config::from_toml(endless).unwrap().effects;
    assert!(parsed.blur_strength.is_infinite(), "{parsed:?}");
    let before = h.revision();
    h.configure(&scratch, endless);
    assert_eq!(
        h.render()["effects"],
        json!({"blur_radius":5,"blur_strength":0.0,"animate_blur_fps":20,"animation_speed":0.5,"animation_scale":0.95})
    );
    assert_eq!(h.revision(), before + 1);

    // Both launch files activate Mac background policy and spend one revision,
    // whether the effects table changes or stays at its defaults.
    let mut launched = Host::new();
    launched.configure(&scratch, "[effects]\nanimation_speed = 1.0\n");
    assert_eq!(launched.render()["effects"]["animation_speed"], 1.0);
    assert_eq!(launched.revision(), 1);
    let mut plain = Host::new();
    plain.configure(&scratch, "[effects]\nblur_radius = 5\n"); // the default since v0.20
    assert_eq!(plain.render()["effects"], block(&defaults));
    assert_eq!(plain.revision(), 1);
}

#[test]
fn a_windows_blur_is_upstreams_effective_blur_and_never_a_stand_ins() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    open(&mut h);
    let ruled = "[session]\nsuspend_on_close = true\n[[window_rules]]\napp_id = \"app.glass\"\nblur = true\n";
    h.configure(&scratch, ruled);
    h.ok(json!({"op":"adoption_complete"}));
    let glass = put(
        &mut h,
        1,
        "app.glass",
        "Glass",
        rect(100.0, 50.0, 400.0, 300.0),
    );
    let plain = put(
        &mut h,
        2,
        "app.plain",
        "Plain",
        rect(520.0, 60.0, 300.0, 200.0),
    );
    let window = |blur: bool| ("window".to_owned(), blur);
    let standin = ("standin".to_owned(), false);

    // driftwm-core's own answer for each window under each config below.
    let core = |toml: &str, app: &str, title: &str| {
        let config = Config::from_toml(toml).unwrap();
        let rule = config.resolve_window_rules(app, title);
        effective_blur(rule.as_ref(), &config.decorations, false)
    };
    assert!(core(ruled, "app.glass", "Glass"));
    assert!(!core(ruled, "app.plain", "Plain"));
    // A rule's blur reaches the window it matched and no other.
    assert_eq!(h.blur(glass), window(true));
    assert_eq!(h.blur(plain), window(false));

    // The ruled window closes into a stand-in, which upstream never frosts,
    // and its relaunched window maps under the rule again.
    assert_eq!(h.closed(glass, json!(1))["standin"], true);
    assert_eq!(h.blur(glass), standin);
    h.ipc(json!(1), json!({"Relaunch":glass}));
    assert_eq!(h.blur(glass), standin);
    assert_eq!(appear(&mut h, 3, "app.glass", "Glass", true), (glass, true));
    assert_eq!(h.blur(glass), window(true));

    // [decorations] blur reaches every bound window.
    let global = format!("{ruled}[decorations]\nblur = true\n");
    assert!(core(&global, "app.plain", "Plain"));
    h.configure(&scratch, &global);
    assert_eq!(h.blur(glass), window(true));
    assert_eq!(h.blur(plain), window(true));
    // And no stand-in: neither the one a close leaves nor a waiting slot.
    assert_eq!(h.closed(plain, json!(1))["standin"], true);
    assert_eq!(h.blur(plain), standin);
    h.detach(glass);
    assert_eq!(h.blur(glass), standin);

    // Without the global flag the rule alone decides again, for the window
    // that takes the waiting slot back.
    h.configure(&scratch, ruled);
    assert_eq!(h.blur(glass), standin);
    assert_eq!(appear(&mut h, 4, "app.glass", "Glass", true), (glass, true));
    assert_eq!(h.blur(glass), window(true));
    h.ipc(json!(1), json!({"Relaunch":plain}));
    assert_eq!(appear(&mut h, 5, "app.plain", "Plain", true), (plain, true));
    assert_eq!(h.blur(plain), window(false));
}

#[test]
fn the_config_error_is_the_error_bars_message_and_a_change_spends_a_revision() {
    let scratch = Scratch::new();
    let path = scratch.path("config.toml");
    let reload = json!({"op":"load_config","path":path});
    let mut h = Host::new();
    open(&mut h);
    // No file is the defaults by choice, and no error. The first load
    // activates the Mac wallpaper policy and spends one render revision.
    assert_eq!(h.errors(), json!([]));
    assert_eq!(h.ok(reload.clone())["exists"], false);
    assert_eq!((h.errors(), h.revision()), (json!([]), 1));
    let good = "focus_follows_mouse = true\n[effects]\nblur_radius = 7\n";
    h.configure(&scratch, good);
    assert_eq!((h.errors(), h.revision()), (json!([]), 2));

    // A file that does not parse: its message is upstream's, the config in
    // force is the last good one, and the bar has something new to show.
    std::fs::write(&path, "[effects\n").unwrap();
    let reply = h.ok(reload.clone());
    let message = reply["errors"][0].as_str().unwrap().to_owned();
    assert!(message.starts_with("config error: "), "{message}");
    assert_eq!(reply["errors"], json!([message]));
    assert_eq!((h.errors(), h.revision()), (json!([message]), 3));
    assert_eq!(h.render()["effects"]["blur_radius"], 7);
    // The reply is the one every load gives, the key pointer policy added
    // included (POINTER.md): the refused file's message is all it holds of
    // that file, and `focus_follows_mouse` is still the last good file's.
    assert_eq!(
        reply,
        json!({"path":path,"exists":true,"errors":[message],"warnings":[],"dirty":false,"effects":[],"focus_follows_mouse":true})
    );
    // The same failure again changes nothing, as upstream redraws nothing
    // for an unchanged message.
    assert_eq!(h.ok(reload.clone())["errors"], json!([message]));
    assert_eq!((h.errors(), h.revision()), (json!([message]), 3));
    // Another failure replaces the message: one source, one line.
    std::fs::write(&path, "[effects]\nblur_radius = \"wide\"\n").unwrap();
    let other = h.ok(reload.clone())["errors"][0]
        .as_str()
        .unwrap()
        .to_owned();
    assert_ne!(other, message);
    assert_eq!((h.errors(), h.revision()), (json!([other]), 4));
    // The file gone after one was accepted is upstream's read failure.
    std::fs::remove_file(&path).unwrap();
    let gone = h.ok(reload.clone())["errors"][0]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(gone.starts_with("config: failed to read "), "{gone}");
    assert_eq!((h.errors(), h.revision()), (json!([gone]), 5));
    assert_eq!(h.render()["effects"]["blur_radius"], 7);

    // The message is not the scene's: a save holds none of it, and a scene
    // loaded over the controller leaves it and the revision alone.
    let scene = scratch.path("scene.json");
    h.ok(json!({"op":"save","path":scene}));
    let saved = std::fs::read_to_string(&scene).unwrap();
    assert!(!saved.contains("failed to read"), "{saved}");
    assert!(!saved.contains("errors"), "{saved}");
    h.ok(json!({"op":"load","path":scene}));
    assert_eq!((h.errors(), h.revision()), (json!([gone]), 5));

    // A clean reload clears it, for the one revision an accepted reload
    // spends anyway.
    h.configure(&scratch, good);
    assert_eq!((h.errors(), h.revision()), (json!([]), 6));

    // A file that loads with warnings is accepted, and the bar shows them as
    // upstream sums them up: the first, and how many more.
    let one = "[navigation]\ncamera_speed = 0\n";
    let reply = h.load_config(&scratch, one);
    let (_, warnings) = Config::from_toml_collect(one).unwrap();
    assert_eq!(warnings.len(), 1);
    assert_eq!(reply["warnings"], json!(warnings));
    assert_eq!(reply["errors"], json!([]));
    assert_eq!((h.errors(), h.revision()), (json!([warnings[0]]), 7));
    let three =
        "[navigation]\ncamera_speed = 0\n[effects]\nblur_strength = -1.0\nanimation_scale = 2.0\n";
    let reply = h.load_config(&scratch, three);
    let (_, warnings) = Config::from_toml_collect(three).unwrap();
    assert_eq!(warnings.len(), 3);
    assert_eq!(reply["warnings"], json!(warnings));
    let summary = "config: effects.animation_scale 2 above maximum 1, using 1 (+2 more)";
    assert_eq!((h.errors(), h.revision()), (json!([summary]), 8));
    // Which warning stands for the rest is the least in byte order, not the
    // parser's first: here its third.
    assert_eq!(warnings[2], summary.trim_end_matches(" (+2 more)"));
    // A failure after it keeps the warned config and replaces the message.
    std::fs::write(&path, "[effects\n").unwrap();
    h.ok(reload.clone());
    assert_eq!((h.errors(), h.revision()), (json!([message]), 9));
    h.configure(&scratch, good);
    assert_eq!((h.errors(), h.revision()), (json!([]), 10));

    // At launch the same messages: a refused file and a file with a warning
    // each spend the first revision for the bar, though the drawn tables are
    // the defaults either way.
    let mut refused = Host::new();
    std::fs::write(&path, "[effects\n").unwrap();
    refused.ok(reload.clone());
    assert_eq!(
        (refused.errors(), refused.revision()),
        (json!([message]), 1)
    );
    let mut warned = Host::new();
    warned.load_config(&scratch, one);
    assert_eq!(warned.errors().as_array().unwrap().len(), 1);
    assert_eq!(warned.revision(), 1);

    // The parser reads `[keybindings]` into a hash map and reports that
    // table's unknown actions in an order that changes from one load to the
    // next, so the parser's first would change the message of a file that
    // did not change. Two dozen loads of one such file name one warning: the
    // least of the three. The reply's own list is the parser's, as it was.
    let unordered = "[keybindings]\n\"mod+f1\" = \"zeta-is-no-action\"\n\"mod+f2\" = \"alpha-is-no-action\"\n\"mod+f3\" = \"mid-is-no-action\"\n";
    let named =
        "config: invalid action 'alpha-is-no-action': unknown action: alpha-is-no-action (+2 more)";
    let mut unsorted = Host::new();
    let mut orders = std::collections::BTreeSet::new();
    for load in 1..=24 {
        let reply = unsorted.load_config(&scratch, unordered);
        assert_eq!(reply["warnings"].as_array().unwrap().len(), 3, "{reply}");
        orders.insert(reply["warnings"].to_string());
        // One revision for the bar at launch, one per accepted reload after.
        assert_eq!(
            (unsorted.errors(), unsorted.revision()),
            (json!([named]), load)
        );
    }
    assert!(orders.len() > 1, "{orders:?}");
}

#[test]
fn lifecycle_events_are_logged_for_what_upstream_animates_and_nothing_else() {
    let scratch = Scratch::new();
    // A scene another run saved, with one slot.
    let scene = scratch.path("scene.json");
    {
        let mut earlier = Host::new();
        open(&mut earlier);
        let term = put(
            &mut earlier,
            1,
            "app.term",
            "Shell",
            rect(100.0, 50.0, 400.0, 300.0),
        );
        assert_eq!(term, 1);
        earlier.ok(json!({"op":"save","path":scene}));
        assert_eq!(earlier.events(), json!([]));
    }
    let mut h = Host::new();
    h.configure(
        &scratch,
        "[[window_rules]]\napp_id = \"app.mail\"\nsuspend_on_close = true\n\
         [[window_rules]]\napp_id = \"app.clock\"\nwidget = true\n\
         [[window_rules]]\napp_id = \"app.log\"\nfocus_on_open = false\n\
         [[window_rules]]\napp_id = \"app.hud\"\npinned_to_screen = true\n",
    );
    h.ok(json!({"op":"load","path":scene}));
    open(&mut h);
    let term = 1;

    // The launch pass: the window that was open all along takes its slot
    // back and one the scene never held is placed. Neither opened here.
    assert_eq!(appear(&mut h, 11, "app.term", "Shell", true), (term, true));
    let (mail, adopted) = appear(&mut h, 12, "app.mail", "Inbox", true);
    assert!(!adopted);
    h.ok(json!({"op":"adoption_complete"}));
    assert_eq!(h.events(), json!([]));

    // From here a window that appears is a new one, and it opens: a widget
    // and a `focus_on_open = false` window as any other, as upstream's do,
    // and a window its rule pins to the screen.
    let (editor, _) = appear(&mut h, 13, "app.editor", "Draft", true);
    assert_eq!(h.events(), json!([event(1, editor, "open", json!(1))]));
    let (clock, _) = appear(&mut h, 14, "app.clock", "Clock", true);
    let (log, _) = appear(&mut h, 15, "app.log", "Log", true);
    let (hud, _) = appear(&mut h, 16, "app.hud", "HUD", true);
    assert_eq!(h.window(clock)["widget"], true);
    assert_eq!(h.window(log)["rule"]["focus_on_open"], false);
    assert_eq!(h.window(hud)["pinned"]["output"], 1);
    // `output` is the active output the command named, or null.
    let (far, _) = appear(&mut h, 17, "app.far", "Far", false);
    let mut expected = vec![
        event(1, editor, "open", json!(1)),
        event(2, clock, "open", json!(1)),
        event(3, log, "open", json!(1)),
        event(4, hud, "open", json!(1)),
        event(5, far, "open", Value::Null),
    ];
    assert_eq!(h.events(), json!(expected));

    // Nothing upstream has no animation for is logged: the chooser's explicit
    // attach, a lost source and the waiting slot's window coming back, a
    // rebind by logical id, a bound window that is forgotten (it is drawn as
    // a window, and `forget` is no close), and a refused command.
    let chosen = put(
        &mut h,
        18,
        "app.chosen",
        "Chosen",
        rect(900.0, 900.0, 300.0, 200.0),
    );
    h.detach(editor);
    assert_eq!(
        appear(&mut h, 19, "app.editor", "Draft", true),
        (editor, true)
    );
    h.detach(chosen);
    h.ok(json!({"op":"attach","identity":identity(20),"bundle_id":"app.chosen","title":"Chosen","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"logical_id":chosen}));
    h.ok(json!({"op":"forget","window":chosen}));
    h.error(json!({"op":"window_closed","window":editor,"identity":identity(999)}));
    assert_eq!(h.events(), json!(expected));

    // A window that closes and leaves the canvas, with and without an output.
    assert_eq!(h.closed(editor, json!(1))["standin"], false);
    assert_eq!(h.closed(far, Value::Null)["standin"], false);
    assert_eq!(h.closed(clock, json!(1))["standin"], false);
    expected.push(event(6, editor, "close", json!(1)));
    expected.push(event(7, far, "close", Value::Null));
    expected.push(event(8, clock, "close", json!(1)));
    assert_eq!(h.events(), json!(expected));
    // The poll behind an event reports a close again (LIFECYCLE.md, Event
    // delivery): it is refused, and a refusal logs nothing.
    h.error(json!({"op":"window_closed","window":editor,"identity":identity(19),"output":1}));
    assert_eq!(h.events(), json!(expected));

    // A close that leaves a stand-in, under its rule's suspend_on_close.
    assert_eq!(h.closed(mail, json!(1))["standin"], true);
    expected.push(event(9, mail, "close_to_standin", json!(1)));
    assert_eq!(h.events(), json!(expected));
    // Reported again, the stand-in is not closed a second time.
    h.error(json!({"op":"window_closed","window":mail,"identity":identity(12),"output":1}));
    assert_eq!(h.events(), json!(expected));
    // A relaunch logs nothing by itself; the window that takes the stand-in's
    // slot is the adoption upstream crossfades, and it does not open.
    h.ipc(json!(1), json!({"Relaunch":mail}));
    assert_eq!(h.events(), json!(expected));
    assert_eq!(appear(&mut h, 21, "app.mail", "Inbox", true), (mail, true));
    expected.push(event(10, mail, "standin_adopted", json!(1)));
    assert_eq!(h.events(), json!(expected));
    // A stand-in that is dismissed, by an IPC close and by the action on the
    // focused one without an output.
    assert_eq!(h.closed(mail, json!(1))["standin"], true);
    assert_eq!(
        h.ipc(json!(1), json!({"Close":mail}))["reply"],
        json!({"Ok":"Ok"})
    );
    expected.push(event(11, mail, "close_to_standin", json!(1)));
    expected.push(event(12, mail, "standin_dismiss", json!(1)));
    assert_eq!(h.events(), json!(expected));
    // `suspend-window` marks the next close a suspend, and `close-window` on
    // the focused stand-in dismisses it, here with no output named.
    let (mail, _) = appear(&mut h, 22, "app.mail", "Inbox", true);
    h.ok(json!({"op":"focus","window":mail}));
    h.ok(json!({"op":"action","output":1,"action":"suspend-window"}));
    assert_eq!(h.closed(mail, json!(1))["standin"], true);
    assert_eq!(h.snapshot()["focus"]["intent"], mail);
    h.ok(json!({"op":"action","output":null,"action":"close-window"}));
    expected.push(event(13, mail, "open", json!(1)));
    expected.push(event(14, mail, "close_to_standin", json!(1)));
    expected.push(event(15, mail, "standin_dismiss", Value::Null));
    assert_eq!(h.events(), json!(expected));
    // `forget` is the shell's own dismissal, its ctrl-option-click on a
    // placeholder: what is drawn as a stand-in fades as any dismissed one
    // does, a suspended stand-in and a waiting slot alike. The command names
    // no output. One that is refused logs nothing.
    let (mail, _) = appear(&mut h, 23, "app.mail", "Inbox", true);
    assert_eq!(h.closed(mail, json!(1))["standin"], true);
    assert_eq!(h.window(mail)["kind"], "standin");
    h.ok(json!({"op":"forget","window":mail}));
    expected.push(event(16, mail, "open", json!(1)));
    expected.push(event(17, mail, "close_to_standin", json!(1)));
    expected.push(event(18, mail, "standin_dismiss", Value::Null));
    assert_eq!(h.events(), json!(expected));
    let (slot, _) = appear(&mut h, 24, "app.slot", "Slot", true);
    h.detach(slot);
    assert_eq!(h.window(slot)["kind"], "standin");
    h.ok(json!({"op":"forget","window":slot}));
    expected.push(event(19, slot, "open", json!(1)));
    expected.push(event(20, slot, "standin_dismiss", Value::Null));
    assert_eq!(h.events(), json!(expected));
    h.error(json!({"op":"forget","window":slot}));
    assert_eq!(h.events(), json!(expected));

    // The list keeps the 32 most recent events; the serials go on.
    for round in 0..12 {
        let (window, _) = appear(&mut h, 100 + round, "app.burst", "Burst", true);
        assert_eq!(h.closed(window, json!(1))["standin"], false);
    }
    let events = h.events();
    let listed = events.as_array().unwrap();
    assert_eq!(listed.len(), 32);
    let serials: Vec<u64> = listed
        .iter()
        .map(|e| e["serial"].as_u64().unwrap())
        .collect();
    assert_eq!(serials, (13..=44).collect::<Vec<u64>>());
    assert_eq!(listed[0], expected[12]);
    assert_eq!(listed[31]["event"], "close");

    // Nothing of it is saved, and a scene loaded over the controller neither
    // empties the list nor starts the serials again.
    let later = scratch.path("later.json");
    h.ok(json!({"op":"save","path":later}));
    let saved = std::fs::read_to_string(&later).unwrap();
    assert!(!saved.contains("lifecycle_events"), "{saved}");
    assert!(!saved.contains("serial"), "{saved}");
    assert!(!saved.contains("standin_dismiss"), "{saved}");
    h.ok(json!({"op":"load","path":later}));
    open(&mut h);
    assert_eq!(h.events(), events);
    let (next, _) = appear(&mut h, 200, "app.next", "Next", true);
    let events = h.events();
    let listed = events.as_array().unwrap();
    assert_eq!(listed.len(), 32);
    assert_eq!(listed[31], event(45, next, "open", json!(1)));
    assert_eq!(listed[0]["serial"], 14);
}

// Effects beside window sizing (SIZES.md). Under a shell that can deliver a
// size, a rule's `size` is asked of a new window in the reply that maps it,
// and until the last of that transaction's effects is answered the window
// may have nothing settled to draw. The event log is told nothing of that:
// the window opened once, when it mapped, and it is the shell that waits to
// play it, on what this scenario pins down: while the size is owed the
// snapshot's `native_resize` names the window and holds a pending effect,
// and afterwards holds none. A close reported while the size is owed is
// refused, as a drag's is, and a refusal logs nothing; the same close
// reported again once the transaction has drained is logged once.
#[test]
fn a_size_that_is_owed_neither_adds_nor_loses_a_lifecycle_event() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    open(&mut h);
    h.configure(
        &scratch,
        "[[window_rules]]\napp_id = \"app.sized\"\nsize = [600, 400]\n",
    );
    h.ok(json!({"op":"adoption_complete"}));
    assert_eq!(
        h.ok(json!({"op":"native_resize_capability","enabled":true})),
        json!({})
    );
    let appear = |h: &mut Host, wid: u64| {
        h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":"app.sized","title":"Sized","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,300.0,200.0),"output":1,"pointer":{"x":700.0,"y":500.0}}))
    };
    let settled = |h: &mut Host, window: &Value| {
        let placements = h.snapshot()["placements"].clone();
        let placed = placements.as_array().unwrap();
        let found = placed.iter().find(|p| &p["window"] == window);
        found.unwrap_or_else(|| panic!("window {window} is on no output"))["presentation_settled"]
            .clone()
    };

    // The window maps, and its rule's size transaction begins in that reply.
    let reply = appear(&mut h, 31);
    let window = reply["window"].clone();
    let id = window.as_u64().unwrap();
    assert_eq!(reply["adopted"], false, "{reply}");
    let read = reply["effects"][0].clone();
    assert_eq!(read["op"], "observe_resize_source", "{reply}");
    assert_eq!(reply["transaction"], read["transaction"], "{reply}");
    // One `open`, logged with the map and not with the size.
    let opened = json!([event(1, id, "open", json!(1))]);
    assert_eq!(h.events(), opened);
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["window"], window, "{slot}");
    assert_eq!(slot["pending_effect"], read, "{slot}");
    assert_eq!(settled(&mut h, &window), true);
    // The baseline read is answered and the setter is owed. Native readback
    // retains the observed picture while this effect is outstanding.
    let setter = resized(&mut h, &read, "observed", false, (300.0, 200.0))["effect"].clone();
    assert_eq!(setter["op"], "resize_native_window", "{setter}");
    assert_eq!(setter["requested"], json!({"width":600.0,"height":400.0}));
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["window"], window, "{slot}");
    assert_eq!(slot["pending_effect"], setter, "{slot}");
    assert_eq!(settled(&mut h, &window), true);
    assert_eq!(h.events(), opened);

    // The window closes while its size is owed. The report is refused and
    // changes nothing, the list and the serial included (`error` compares
    // the whole snapshot).
    let gone =
        json!({"op":"window_closed","window":window,"identity":setter["identity"],"output":1});
    assert_eq!(
        h.error(gone.clone()),
        "resize must drain before structural change; cancel and reconcile pending effects"
    );
    // The shell's own removal of the window is held off the same way.
    assert_eq!(
        h.error(json!({"op":"forget","window":window})),
        "resize must drain before structural change; cancel and reconcile pending effects"
    );
    assert_eq!(h.events(), opened);
    // The adapter finds no window: the transaction fails and owes nothing.
    assert_eq!(
        resized(&mut h, &setter, "missing_window", false, (1.0, 1.0))["effect"],
        Value::Null
    );
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["phase"], "failed", "{slot}");
    assert_eq!(slot["pending_effect"], Value::Null, "{slot}");
    assert_eq!(h.events(), opened);
    // The same report again is accepted, and the close is logged once.
    assert_eq!(h.ok(gone.clone())["standin"], false);
    let closed = json!([
        event(1, id, "open", json!(1)),
        event(2, id, "close", json!(1))
    ]);
    assert_eq!(h.events(), closed);
    // A third report finds no window, and adds nothing.
    h.error(gone);
    assert_eq!(h.events(), closed);

    // A size that is delivered: the open is the one event of the whole map,
    // and nothing is owed once the final read is answered.
    let reply = appear(&mut h, 32);
    let window = reply["window"].clone();
    let read = reply["effects"][0].clone();
    assert_eq!(read["op"], "observe_resize_source", "{reply}");
    let mut expected = closed.as_array().unwrap().clone();
    expected.push(event(3, window.as_u64().unwrap(), "open", json!(1)));
    let setter = resized(&mut h, &read, "observed", false, (300.0, 200.0))["effect"].clone();
    let last = resized(&mut h, &setter, "applied", true, (600.0, 400.0))["effect"].clone();
    assert_eq!(last["op"], "observe_resize_source", "{last}");
    assert_eq!(h.snapshot()["native_resize"]["pending_effect"], last);
    assert_eq!(
        resized(&mut h, &last, "observed", false, (600.0, 400.0))["effect"],
        Value::Null
    );
    let slot = h.snapshot()["native_resize"].clone();
    assert_eq!(slot["phase"], "complete", "{slot}");
    assert_eq!(slot["pending_effect"], Value::Null, "{slot}");
    assert_eq!(
        h.window(window.as_u64().unwrap())["world_rect"]["size"],
        json!({"width":600.0,"height":400.0})
    );
    assert_eq!(h.events(), json!(expected));
}
