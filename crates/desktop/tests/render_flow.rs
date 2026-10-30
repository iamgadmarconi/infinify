// SPDX-License-Identifier: GPL-3.0-or-later
//! Render scenarios cross the exported C ABI and JSON decoder with synthetic
//! observations and config files written to a throwaway directory. The default
//! block is compared with driftwm-core's own `Default` impls; every other
//! expected value is derived by hand from upstream's rules. They provide no
//! evidence that anything is drawn, that a capture stream delivers a frame, or
//! that a PNG is written: a screenshot here is a request nobody performs, and
//! the answers to it are typed in by the test.
use driftwm_core::config::{
    BackgroundKind, Config, DecorationConfig, DecorationMode, EffectsConfig, FontWeight,
    OutputOutlineSettings, TitleAlign,
};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

#[path = "support/host.rs"]
mod host;
use host::Host;

impl Host {
    /// A refused command: an error, and nothing changed.
    fn error(&mut self, command: Value) -> String {
        let before = self.snapshot();
        let response = self.call(command.clone());
        assert_eq!(response["ok"], false, "{command}: {response}");
        assert_eq!(self.snapshot(), before, "{command}");
        response["error"].as_str().unwrap().to_owned()
    }
    fn render(&mut self) -> Value {
        self.snapshot()["render"].clone()
    }
    /// Write the config file and load it: accepted, and without a warning.
    fn configure(&mut self, scratch: &Scratch, toml: &str) -> Value {
        let path = scratch.path("config.toml");
        std::fs::write(&path, toml).unwrap();
        let reply = self.ok(json!({"op":"load_config","path":path}));
        assert_eq!(reply["errors"], json!([]), "{reply}");
        assert_eq!(reply["warnings"], json!([]), "{reply}");
        self.render()
    }
    /// The one placement of `window` on `output`.
    fn placement_on(&mut self, window: u64, output: u64) -> Value {
        let snapshot = self.snapshot();
        let found: Vec<&Value> = snapshot["placements"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|p| p["window"] == window && p["output"] == output)
            .collect();
        assert_eq!(found.len(), 1, "window {window} on output {output}");
        found[0].clone()
    }
    fn placement(&mut self, window: u64) -> Value {
        self.placement_on(window, 1)
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
    fn source(&mut self, window: u64) -> Value {
        self.window(window)["source"].clone()
    }
    /// Report native focus on a bound window: logical focus and raise.
    fn observe_focus(&mut self, window: u64) {
        let source = self.source(window);
        self.ok(json!({"op":"observe_focus","window":window,"identity":source["identity"],"generation":source["generation"]}));
    }
    fn ipc_on(&mut self, output: Value, request: Value) -> Value {
        self.ok(json!({"op":"ipc","output":output,"request":request}))
    }
    /// A screenshot request the controller accepts: no reply yet, nothing to
    /// save, no flight, and exactly one effect for the shell, which is returned.
    /// Asking changes nothing a snapshot shows.
    fn shot_on(&mut self, output: Value, target: Value, scale: f64, path: &str) -> Value {
        let before = self.snapshot();
        let request = json!({"Screenshot":{"target":target,"scale":scale,"path":path}});
        let data = self.ipc_on(output, request.clone());
        assert_eq!(
            data,
            json!({"reply":null,"effects":[data["effects"][0]],"dirty":false,"navigation":null}),
            "{request}"
        );
        assert_eq!(self.snapshot(), before, "{request}");
        data["effects"][0].clone()
    }
    fn shot(&mut self, target: Value, scale: f64) -> Value {
        self.shot_on(json!(1), target, scale, SHOT)
    }
    /// A refused screenshot: upstream's `Err` now, nothing for the shell.
    fn shot_refused(&mut self, output: Value, target: Value, scale: f64, path: &str) -> String {
        let before = self.snapshot();
        let request = json!({"Screenshot":{"target":target,"scale":scale,"path":path}});
        let data = self.ipc_on(output, request.clone());
        assert_eq!(
            data,
            json!({"reply":{"Err":data["reply"]["Err"]},"effects":[],"dirty":false,"navigation":null}),
            "{request}"
        );
        assert_eq!(self.snapshot(), before, "{request}");
        data["reply"]["Err"]
            .as_str()
            .expect("an Err reply")
            .to_owned()
    }
    /// The shell reports the capture of `path` as written.
    fn written(&mut self, path: &str, width: u32, height: u32) -> Value {
        self.ok(json!({"op":"screenshot_result","path":path,"width":width,"height":height}))
    }
}
/// A directory of this test's own, removed when the test ends.
struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "infinify-render-flow-{}-{}",
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

/// Where every accepted screenshot here is asked to go. Nothing writes it.
const SHOT: &str = "/nonexistent/infinify-render-flow/shot.png";

fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
    json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
}
fn point(x: f64, y: f64) -> Value {
    json!({"x":x,"y":y})
}
fn identity(wid: u64) -> Value {
    json!({"pid":4242,"birth_sec":1800000000,"birth_usec":77,"wid":wid})
}
/// A colour as the snapshot carries it: straight alpha, each channel over 255.
fn rgba(color: [u8; 4]) -> Value {
    json!(color.map(|channel| f64::from(channel) / 255.0))
}
/// One output of 1000 x 800 whose top-left is the global point (200, 100).
fn open(h: &mut Host) {
    h.ok(json!({"op":"register_output","stable_id":"main","screen_bounds":rect(200.0,100.0,1000.0,800.0)}));
    h.ok(json!({"op":"set_navigation_context","output":1,"usable_rect_local":rect(0.0,0.0,1000.0,800.0),"focus_placement":"center","camera_speed":0.3,"outer_gap":0.0}));
}
/// A window the caller puts at a world rectangle. Its native rectangle is
/// somewhere else entirely: nothing below may derive from it.
fn put(h: &mut Host, wid: u64, app: &str, title: &str, world: Value) -> u64 {
    let reply = h.ok(json!({"op":"attach","identity":identity(wid),"bundle_id":app,"title":title,"buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,333.0,222.0),"world_rect":world}));
    reply["window"].as_u64().unwrap()
}
/// The bound window loses its source and stays as a detached placeholder.
fn detach(h: &mut Host, window: u64) {
    let identity = h.source(window)["identity"].clone();
    h.ok(json!({"op":"remove_source","window":window,"identity":identity,"keep_placeholder":true}));
}
/// Half the zoom and a camera off the origin: (1000, -200).
fn zoom_out(h: &mut Host) {
    h.ok(json!({"op":"zoom","output":1,"zoom":0.5,"anchor":point(200.0,100.0)}));
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(500.0,-100.0)}));
    let output = h.snapshot()["outputs"][0].clone();
    assert_eq!(output["camera"], point(1000.0, -200.0));
    assert_eq!(output["zoom"], 0.5);
}
/// The block a configuration with upstream's default tables produces.
fn default_block(revision: u64, configured: bool) -> Value {
    // The expected values are driftwm-core's, upstream's own `Default` impls.
    let decorations = DecorationConfig::default();
    let outline = OutputOutlineSettings::default();
    let config = Config::default();
    assert_eq!(config.decorations, decorations);
    assert_eq!(config.output_outline, outline);
    assert_eq!(config.background.kind, BackgroundKind::Default);
    assert_eq!(decorations.font_weight, FontWeight::Medium);
    assert_eq!(decorations.title_align, TitleAlign::Center);
    let effects = EffectsConfig::default();
    assert_eq!(config.effects, effects);
    json!({
        "background":{"type":"default","path":null,"texture":null,"mirror_tile":config.background.mirror_tile,"transparent_shader":config.background.transparent_shader,"animate_fps":config.background.animate_fps,"cache_shader":config.background.cache_shader,"cache_budget_mb":config.background.cache_budget_mb,"inherit_macos":configured,"parallax":configured},
        "chrome":{"background":rgba(decorations.bg_color),"foreground":rgba(decorations.fg_color),"corner_radius":decorations.corner_radius,"title_bar_height":decorations.title_bar_height,"font":decorations.font,"font_size":decorations.font_size,"font_weight":"medium","title_align":"center"},
        "outline":{"color":rgba(outline.color),"thickness":outline.thickness,"opacity":outline.opacity},
        "effects":{"blur_radius":effects.blur_radius,"blur_strength":effects.blur_strength,"animate_blur_fps":effects.animate_blur_fps,"animation_speed":effects.animation_speed,"animation_scale":effects.animation_scale},
        "errors":[],
        "revision":revision,
    })
}
/// The decoration of a window no rule matches under upstream's default
/// `[decorations]`, again from driftwm-core's own values.
fn default_decoration(focused: bool) -> Value {
    let decorations = DecorationConfig::default();
    assert_eq!(decorations.default_mode, DecorationMode::Client);
    let opacity = match focused {
        true => decorations.opacity_focused,
        false => decorations.opacity,
    };
    json!({"mode":"client","border_width":decorations.border_width,"border_color":rgba(decorations.border_color),"border_color_focused":rgba(decorations.border_color_focused),"corner_radius":decorations.corner_radius,"shadow":decorations.shadow,"shadow_radius":f64::from(DecorationConfig::SHADOW_RADIUS),"shadow_color":rgba(DecorationConfig::SHADOW_COLOR),"opacity":opacity,"blur":decorations.blur})
}

#[test]
fn the_default_render_block_is_upstreams_defaults() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    // Before any output or config, with one, and with a launch config path
    // that names no file: the built-in defaults, and no revision spent.
    assert_eq!(h.render(), default_block(0, false));
    open(&mut h);
    assert_eq!(h.render(), default_block(0, false));
    let missing = h.ok(json!({"op":"load_config","path":scratch.path("absent.toml")}));
    assert_eq!(missing["exists"], false);
    assert_eq!(h.render(), default_block(1, true));
    // An empty file loaded after that is a reload: the same defaults, and a
    // revision, as every accepted reload spends one.
    assert_eq!(h.configure(&scratch, ""), default_block(2, true));

    // The snapshot holds exactly these keys.
    let snapshot = h.snapshot();
    let keys: BTreeSet<&str> = snapshot
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        BTreeSet::from([
            "bookmarks",
            "evidence",
            "focus",
            "keyboard_layout",
            "lifecycle",
            "lifecycle_events",
            "native_resize",
            "navigation",
            "outputs",
            "pass_keys",
            "placements",
            "render",
            "trackpad",
            "windows",
        ])
    );

    // A window no rule matches is decorated as upstream decorates a
    // client-side-decorated one: no title bar of the compositor's, the
    // default radius and shadow, no border.
    let window = put(
        &mut h,
        1,
        "app.term",
        "Shell",
        rect(100.0, 50.0, 400.0, 300.0),
    );
    let placement = h.placement(window);
    assert_eq!(placement["decoration"], default_decoration(false));
    assert_eq!(placement["kind"], "window");
    h.observe_focus(window);
    assert_eq!(h.placement(window)["decoration"], default_decoration(true));
}

#[test]
fn a_reload_changes_the_block_and_every_accepted_one_spends_a_revision() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    open(&mut h);
    // The launch load activates the default Mac wallpaper policy in the
    // renderer, so it spends one revision even though DriftWM's tables stay
    // at their defaults.
    let unrelated = "[navigation]\npan_step = 123\n";
    assert_eq!(h.configure(&scratch, unrelated), default_block(1, true));

    // [decorations]: the chrome the compositor rasterises.
    let decorations = "[decorations]\nbg_color = \"#102030\"\nfg_color = \"#a0b0c080\"\ncorner_radius = 4\ntitle_bar_height = 30\nfont = \"Menlo\"\nfont_size = 13\nfont_weight = \"semi-bold\"\ntitle_align = \"left\"\n";
    let mut toml = format!("{unrelated}{decorations}");
    let block = h.configure(&scratch, &toml);
    assert_eq!(block["revision"], 2);
    assert_eq!(
        block["chrome"],
        json!({"background":rgba([0x10,0x20,0x30,0xff]),"foreground":rgba([0xa0,0xb0,0xc0,0x80]),"corner_radius":4,"title_bar_height":30,"font":"Menlo","font_size":13,"font_weight":"semibold","title_align":"left"})
    );
    assert_eq!(block["background"], default_block(0, true)["background"]);
    assert_eq!(block["outline"], default_block(0, true)["outline"]);
    let chrome = block["chrome"].clone();

    // [output.outline].
    toml += "[output.outline]\ncolor = \"#ff8000\"\nthickness = 3\nopacity = 0.25\n";
    let block = h.configure(&scratch, &toml);
    assert_eq!(block["revision"], 3);
    let outline = json!({"color":rgba([0xff,0x80,0x00,0xff]),"thickness":3,"opacity":0.25});
    assert_eq!(block["outline"], outline);
    assert_eq!(block["chrome"], chrome);

    // [effects]: the table itself, which tests/effects_flow.rs covers.
    toml += "[effects]\nblur_radius = 5\n";
    let block = h.configure(&scratch, &toml);
    assert_eq!(block["revision"], 4);
    let mut effects = default_block(0, true)["effects"].clone();
    effects["blur_radius"] = json!(5);
    assert_eq!(block["effects"], effects);
    assert_eq!(block["chrome"], chrome);
    assert_eq!(block["outline"], outline);
    assert_eq!(block["background"], default_block(0, true)["background"]);

    // [background], every type. A leading `~/` arrives expanded from $HOME by
    // upstream's parser wherever that is set.
    let home = |rest: &str| match std::env::var("HOME") {
        Ok(home) => format!("{home}/{rest}"),
        Err(_) => format!("~/{rest}"),
    };
    let backgrounds = [
        (
            "type = \"shader\"\npath = \"/opt/shaders/smoke.glsl\"\ntexture = \"~/Pictures/photo.jpg\"\ntransparent_shader = true\nanimate_fps = 30\ncache_shader = true\ncache_budget_mb = 512\n",
            json!({"type":"shader","path":"/opt/shaders/smoke.glsl","texture":home("Pictures/photo.jpg"),"mirror_tile":false,"transparent_shader":true,"animate_fps":30,"cache_shader":true,"cache_budget_mb":512,"inherit_macos":false,"parallax":true}),
        ),
        (
            "type = \"tile\"\npath = \"~/Pictures/tile.png\"\nmirror_tile = true\n",
            json!({"type":"tile","path":home("Pictures/tile.png"),"texture":null,"mirror_tile":true,"transparent_shader":false,"animate_fps":0,"cache_shader":false,"cache_budget_mb":128,"inherit_macos":false,"parallax":true}),
        ),
        (
            "type = \"wallpaper\"\npath = \"/Library/Desktop Pictures/hill.heic\"\n",
            json!({"type":"wallpaper","path":"/Library/Desktop Pictures/hill.heic","texture":null,"mirror_tile":false,"transparent_shader":false,"animate_fps":0,"cache_shader":false,"cache_budget_mb":128,"inherit_macos":false,"parallax":true}),
        ),
        (
            "type = \"none\"\n",
            json!({"type":"none","path":null,"texture":null,"mirror_tile":false,"transparent_shader":false,"animate_fps":0,"cache_shader":false,"cache_budget_mb":128,"inherit_macos":false,"parallax":true}),
        ),
    ];
    let mut revision = 4;
    let mut last = String::new();
    for (background, expected) in backgrounds {
        revision += 1;
        last = format!("{toml}[background]\n{background}");
        let block = h.configure(&scratch, &last);
        assert_eq!(
            block,
            json!({"background":expected,"chrome":chrome,"outline":outline,"effects":effects,"errors":[],"revision":revision}),
            "{background}"
        );
    }
    let toml = last;
    let settled = h.render();
    assert_eq!(settled["revision"], 8);

    // The same file again, and a change elsewhere in it: the block is what it
    // was, and each reload spends a revision. Upstream reads the shader or
    // image behind an unchanged [background] again on every reload, and the
    // revision is what tells the shell to.
    let again = |revision: u64| {
        let mut block = settled.clone();
        block["revision"] = json!(revision);
        block
    };
    assert_eq!(h.configure(&scratch, &toml), again(9));
    let elsewhere = toml.replace("pan_step = 123", "pan_step = 321");
    assert_ne!(elsewhere, toml);
    assert_eq!(h.configure(&scratch, &elsewhere), again(10));
    // A file that does not parse is not an accepted reload: every table
    // stays. Its message is the error bar's, which the shell draws from this
    // block, so the revision moves for it (EFFECTS.md). A scene loaded over
    // the controller moves nothing.
    std::fs::write(scratch.path("config.toml"), "[decorations\n").unwrap();
    let refused = h.ok(json!({"op":"load_config","path":scratch.path("config.toml")}));
    assert_eq!(refused["errors"].as_array().unwrap().len(), 1, "{refused}");
    let mut failed = again(11);
    failed["errors"] = refused["errors"].clone();
    assert_eq!(h.render(), failed);
    let scene = scratch.path("scene.json");
    h.ok(json!({"op":"save","path":scene}));
    h.ok(json!({"op":"load","path":scene}));
    assert_eq!(h.render(), failed);

    // A [decorations] key that reaches only the placements.
    let bordered = elsewhere.replace(
        "corner_radius = 4\n",
        "corner_radius = 4\nborder_width = 2\n",
    );
    assert_ne!(bordered, elsewhere);
    // The accepted file clears the message too, for the one revision.
    let block = h.configure(&scratch, &bordered);
    assert_eq!(block["revision"], 12);
    assert_eq!(block["errors"], json!([]));
    assert_eq!(block["chrome"], chrome);

    // Back to no tables at all: upstream's defaults, one more revision.
    assert_eq!(h.configure(&scratch, unrelated), default_block(13, true));

    // A launch file that names a shader spends the first revision, and the
    // same file loaded again the next: that is how an edited shader file
    // reaches the shell.
    let mut launched = Host::new();
    let shader = "[background]\ntype = \"shader\"\npath = \"/opt/shaders/smoke.glsl\"\n";
    let first = launched.configure(&scratch, shader);
    assert_eq!(first["revision"], 1);
    let mut second = first.clone();
    second["revision"] = json!(2);
    assert_eq!(launched.configure(&scratch, shader), second);
}

#[test]
fn the_cache_budget_is_cores_parsed_value_and_a_change_spends_a_revision() {
    let scratch = Scratch::new();
    // The block with `[background] cache_budget_mb` at `budget` and every
    // other table at upstream's defaults.
    let budgeted = |budget: u32, revision: u64| {
        let mut block = default_block(revision, true);
        block["background"]["cache_budget_mb"] = json!(budget);
        block
    };
    // Upstream's default of 128 MB, from driftwm-core: with no config at all,
    // and under a launch file that does not name the key, which spends
    // nothing.
    let default = Config::default().background.cache_budget_mb;
    assert_eq!(default, 128);
    let mut h = Host::new();
    assert_eq!(h.render()["background"]["cache_budget_mb"], default);
    let unrelated = "[navigation]\npan_step = 123\n";
    assert_eq!(h.configure(&scratch, unrelated), default_block(1, true));

    // A reload that changes the budget alone: that key, and one revision.
    let toml = format!("{unrelated}[background]\ncache_budget_mb = 64\n");
    assert_eq!(h.configure(&scratch, &toml), budgeted(64, 2));
    // A reload that changes something else leaves the budget where it was:
    // the same block, but for the revision every accepted reload spends.
    let elsewhere = toml.replace("pan_step = 123", "pan_step = 321");
    assert_ne!(elsewhere, toml);
    assert_eq!(h.configure(&scratch, &elsewhere), budgeted(64, 3));
    // The value is core's `u32` as parsed, in megabytes, and nothing here
    // clamps it: what a budget too small for one chunk draws is the shell's.
    for (budget, revision) in [(0, 4), (u32::MAX, 5)] {
        let toml = format!("[background]\ncache_budget_mb = {budget}\n");
        assert_eq!(h.configure(&scratch, &toml), budgeted(budget, revision));
    }
    // A value core's parser refuses is a refused file: the budget in force
    // stays, and the revision moves for the message alone.
    std::fs::write(
        scratch.path("config.toml"),
        "[background]\ncache_budget_mb = -1\n",
    )
    .unwrap();
    let refused = h.ok(json!({"op":"load_config","path":scratch.path("config.toml")}));
    assert_eq!(refused["errors"].as_array().unwrap().len(), 1, "{refused}");
    let mut failed = budgeted(u32::MAX, 6);
    failed["errors"] = refused["errors"].clone();
    assert_eq!(h.render(), failed);
    // A file without the key is upstream's default again.
    assert_eq!(h.configure(&scratch, unrelated), default_block(7, true));

    // The launch load spends a revision only for a file whose drawn tables
    // are not the defaults, and the budget is one of [background]'s keys: a
    // launch file that changes it alone spends the first, as one that changes
    // any other key of the table does, and one that writes the default spends
    // none, as the unrelated launch file above spent none.
    let mut launched = Host::new();
    let changed = "[background]\ncache_budget_mb = 64\n";
    assert_eq!(launched.configure(&scratch, changed), budgeted(64, 1));
    let mut unchanged = Host::new();
    let written = format!("[background]\ncache_budget_mb = {default}\n");
    assert_eq!(
        unchanged.configure(&scratch, &written),
        default_block(1, true)
    );
}

/// The fields a placement gained, as one object.
fn drawn(placement: &Value) -> Value {
    json!({"kind":placement["kind"],"focused":placement["focused"],"title":placement["title"],"app_name":placement["app_name"],"launching":placement["launching"],"world_rect":placement["world_rect"],"decoration":placement["decoration"]})
}

#[test]
fn placements_say_what_is_drawn_for_windows_placeholders_and_stand_ins() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    open(&mut h);
    h.configure(
        &scratch,
        "[decorations]\nborder_width = 2\nborder_color = \"#112233\"\nborder_color_focused = \"#445566cc\"\ncorner_radius = 12\nopacity = 0.8\nopacity_focused = 0.95\n\
         [session]\nsuspend_on_close = true\n\
         [[window_rules]]\napp_id = \"app.notes\"\ndecoration = \"minimal\"\nborder_width = 5\nborder_color = \"#ff0000\"\ncorner_radius = 3\nshadow = false\nopacity = 0.5\nblur = true\n\
         [[window_rules]]\napp_id = \"app.bare\"\ndecoration = \"none\"\nborder_width = 7\ncorner_radius = 9\nshadow = true\n\
         [[window_rules]]\ntitle = \"Console\"\ndecoration = \"server\"\n",
    );
    h.ok(json!({"op":"adoption_complete"}));
    let term = put(
        &mut h,
        1,
        "app.term",
        "Shell",
        rect(100.0, 50.0, 400.0, 300.0),
    );
    let notes = put(
        &mut h,
        2,
        "app.notes",
        "Notes",
        rect(520.0, 60.0, 300.0, 200.0),
    );
    let bare = put(
        &mut h,
        3,
        "app.bare",
        "Bare",
        rect(60.0, 420.0, 300.0, 200.0),
    );
    let editor = put(
        &mut h,
        4,
        "app.editor",
        "Draft.txt",
        rect(400.0, 440.0, 250.0, 150.0),
    );
    let mail = put(
        &mut h,
        5,
        "app.notes",
        "Inbox",
        rect(700.0, 500.0, 200.0, 180.0),
    );
    let console = put(
        &mut h,
        6,
        "app.term",
        "Console",
        rect(880.0, 20.0, 100.0, 100.0),
    );
    assert_eq!(
        (term, notes, bare, editor, mail, console),
        (1, 2, 3, 4, 5, 6)
    );
    h.observe_focus(term);

    // The global table, as upstream resolves it for a window no rule matches.
    let global = |focused: bool| json!({"mode":"client","border_width":2,"border_color":rgba([0x11,0x22,0x33,0xff]),"border_color_focused":rgba([0x44,0x55,0x66,0xcc]),"corner_radius":12,"shadow":true,"shadow_radius":14.0,"shadow_color":rgba([0,0,0,0x66]),"opacity":if focused { 0.95 } else { 0.8 },"blur":false});
    let with = |base: Value, changes: Value| {
        let mut base = base;
        for (key, value) in changes.as_object().unwrap() {
            assert!(base.get(key).is_some(), "{key}");
            base[key] = value.clone();
        }
        base
    };
    // A rule overrides field by field and pins the opacity in both focus states.
    let ruled = with(
        global(false),
        json!({"mode":"minimal","border_width":5,"border_color":rgba([0xff,0,0,0xff]),"corner_radius":3,"shadow":false,"opacity":0.5,"blur":true}),
    );
    // `none` vetoes border, radius and shadow whatever the rule also says.
    let none = with(
        global(false),
        json!({"mode":"none","border_width":0,"corner_radius":0,"shadow":false}),
    );

    // A bound window: the existing keys, and what it is drawn with.
    let placement = h.placement(term);
    let keys: BTreeSet<&str> = placement
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        BTreeSet::from([
            "app_name",
            "buffer_crop",
            "clip_rect",
            "decoration",
            "focused",
            "kind",
            "launching",
            "opacity",
            "output",
            "pinned",
            "presentation_settled",
            "screen_rect",
            "source",
            "title",
            "widget",
            "window",
            "world_local_crop",
            "world_rect",
        ])
    );
    // Canvas space: the world rectangle, not the native one and not the
    // rectangle on the screen, which starts at the output's global origin.
    assert_eq!(placement["screen_rect"], rect(300.0, 150.0, 400.0, 300.0));
    assert_eq!(
        drawn(&placement),
        json!({"kind":"window","focused":true,"title":"Shell","app_name":"app.term","launching":false,"world_rect":rect(100.0,50.0,400.0,300.0),"decoration":global(true)})
    );
    assert_eq!(
        drawn(&h.placement(notes)),
        json!({"kind":"window","focused":false,"title":"Notes","app_name":"app.notes","launching":false,"world_rect":rect(520.0,60.0,300.0,200.0),"decoration":ruled})
    );
    assert_eq!(h.placement(bare)["decoration"], none);
    // A rule can match by title, and `server` is passed on as written.
    assert_eq!(
        h.placement(console)["decoration"],
        with(global(false), json!({"mode":"server"}))
    );

    // The focused flag and the focus-dependent opacity follow the focus; a
    // rule's opacity stays where it was pinned.
    h.observe_focus(notes);
    assert_eq!(h.snapshot()["focus"]["intent"], notes);
    let placement = h.placement(term);
    assert_eq!(placement["focused"], false);
    assert_eq!(placement["decoration"], global(false));
    let placement = h.placement(notes);
    assert_eq!(placement["focused"], true);
    assert_eq!(placement["decoration"], ruled);
    h.ok(json!({"op":"focus","window":editor}));
    assert_eq!(h.placement(notes)["focused"], false);
    let placement = h.placement(editor);
    assert_eq!(placement["focused"], true);
    assert_eq!(placement["decoration"], global(true));

    // A detached placeholder is drawn as a stand-in, from the global table,
    // and opaque: upstream composes a stand-in at alpha 1.0 whatever
    // `[decorations] opacity` and `opacity_focused` say.
    let standin = |focused: bool| with(global(focused), json!({"opacity":1.0}));
    detach(&mut h, editor);
    assert_eq!(h.snapshot()["lifecycle"]["standins"], json!([]));
    assert_eq!(
        drawn(&h.placement(editor)),
        json!({"kind":"standin","focused":true,"title":"Draft.txt","app_name":"app.editor","launching":false,"world_rect":rect(400.0,440.0,250.0,150.0),"decoration":standin(true)})
    );
    assert!(h.placement(editor)["source"].is_null());

    // A suspended stand-in: the window closed by itself under
    // `suspend_on_close`. The rule that decorated the live window no longer
    // applies: upstream resolves a stand-in without a client to match.
    assert_eq!(h.placement(mail)["decoration"], ruled);
    let closing = h.source(mail)["identity"].clone();
    let closed = h.ok(json!({"op":"window_closed","window":mail,"identity":closing,"output":1}));
    assert_eq!(closed["standin"], true);
    assert_eq!(h.snapshot()["lifecycle"]["standins"], json!([mail]));
    assert_eq!(
        drawn(&h.placement(mail)),
        json!({"kind":"standin","focused":false,"title":"Inbox","app_name":"app.notes","launching":false,"world_rect":rect(700.0,500.0,200.0,180.0),"decoration":standin(false)})
    );

    // A relaunch is pending for exactly the stand-in that was asked for.
    let relaunch = h.ipc_on(json!(1), json!({"Relaunch":mail}));
    assert_eq!(relaunch["reply"], json!({"Ok":"Ok"}));
    assert_eq!(h.snapshot()["lifecycle"]["relaunching"], json!([mail]));
    let placement = h.placement(mail);
    assert_eq!(placement["kind"], "standin");
    assert_eq!(placement["launching"], true);
    assert_eq!(h.placement(editor)["launching"], false);
    assert_eq!(h.placement(term)["launching"], false);

    // The app's window arrives and takes the slot: a live window again, under
    // its rule again, in the stand-in's rectangle.
    let adopted = h.ok(json!({"op":"attach","identity":identity(9),"bundle_id":"app.notes","title":"Inbox (2)","buffer":{"width":200,"height":100},"source_rect":rect(4000.0,3000.0,640.0,480.0),"output":1,"pointer":point(700.0,500.0)}));
    assert_eq!(adopted["window"], mail);
    assert_eq!(adopted["adopted"], true);
    assert_eq!(
        drawn(&h.placement(mail)),
        json!({"kind":"window","focused":false,"title":"Inbox (2)","app_name":"app.notes","launching":false,"world_rect":rect(700.0,500.0,200.0,180.0),"decoration":ruled})
    );

    // A second output showing the same canvas gets the same description of
    // each window: it is the window's, not the output's, and the window list
    // carries it as well.
    h.ok(json!({"op":"register_output","stable_id":"side","screen_bounds":rect(1200.0,100.0,1000.0,800.0)}));
    for window in [term, notes, bare, editor, mail, console] {
        let (main, side) = (h.placement_on(window, 1), h.placement_on(window, 2));
        assert_eq!(drawn(&main), drawn(&side), "window {window}");
        assert_ne!(main["screen_rect"], side["screen_rect"], "window {window}");
        assert_eq!(drawn(&h.window(window)), drawn(&main), "window {window}");
    }
    // A window that no output shows has no placement to say what it is drawn
    // with, and a capture can still reach it: its entry says it.
    let away = put(
        &mut h,
        7,
        "app.notes",
        "Away",
        rect(9000.0, 9000.0, 300.0, 200.0),
    );
    let snapshot = h.snapshot();
    let placed = snapshot["placements"].as_array().unwrap();
    assert!(placed.iter().all(|p| p["window"] != away));
    let entry = h.window(away);
    let keys: BTreeSet<&str> = entry
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        BTreeSet::from([
            "app_name",
            "decoration",
            "focused",
            "kind",
            "launching",
            "metadata",
            "mode",
            "pinned",
            "rule",
            "source",
            "title",
            "widget",
            "window",
            "world_rect",
        ])
    );
    assert_eq!(
        drawn(&entry),
        json!({"kind":"window","focused":false,"title":"Away","app_name":"app.notes","launching":false,"world_rect":rect(9000.0,9000.0,300.0,200.0),"decoration":ruled})
    );
    assert_eq!(
        entry["metadata"],
        json!({"bundle_id":"app.notes","title":"Away"})
    );
}

/// The screenshot effect of one target at one scale on the active output.
fn effect(target: Value, scale: f64, output: Value, region: Value, size: (u32, u32)) -> Value {
    json!({"op":"screenshot","target":target,"scale":scale,"path":SHOT,"output":output,"region":region,"width":size.0,"height":size.1})
}

#[test]
fn a_screenshot_request_becomes_an_effect_with_upstreams_region_and_pixel_size() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    open(&mut h);
    // `fit_padding` frames an `all` capture; the stand-in bar is 25 high.
    h.configure(&scratch, "[zoom]\nfit_padding = 40\n");
    zoom_out(&mut h);
    let term = put(
        &mut h,
        1,
        "app.term",
        "Shell",
        rect(100.0, 50.0, 400.0, 300.0),
    );
    let mail = put(
        &mut h,
        2,
        "app.mail",
        "Inbox",
        rect(700.0, 500.0, 300.0, 200.0),
    );
    detach(&mut h, mail);
    h.observe_focus(term);
    // Neither is under a rule that pins an opacity: captured alone, opaque.
    let window =
        |id: u64, world: Value| json!({"Window":{"window":id,"world_rect":world,"opacity":1.0}});
    let term_world = rect(100.0, 50.0, 400.0, 300.0);
    let mail_world = rect(700.0, 500.0, 300.0, 200.0);

    // Viewport: what the active output shows, `size / zoom` canvas units from
    // the camera, at `scale` pixels per canvas unit whatever the zoom.
    assert_eq!(
        h.shot(json!("Viewport"), 1.0),
        effect(
            json!("Viewport"),
            1.0,
            json!(1),
            rect(1000.0, -200.0, 2000.0, 1600.0),
            (2000, 1600)
        )
    );
    assert_eq!(
        h.shot(json!("Viewport"), 0.5),
        effect(
            json!("Viewport"),
            0.5,
            json!(1),
            rect(1000.0, -200.0, 2000.0, 1600.0),
            (1000, 800)
        )
    );

    // Window: alone, with its shadow. No border by default, so the frame grows
    // by the shadow radius (14) on every side; no compositor title bar. By
    // focus, by id and by app id.
    let shadowed = rect(86.0, 36.0, 428.0, 328.0);
    for selector in [json!({}), json!({"window":1}), json!({"window":"TERM"})] {
        assert_eq!(
            h.shot(json!({"Window":selector}), 2.0),
            effect(
                window(1, term_world.clone()),
                2.0,
                json!(1),
                shadowed.clone(),
                (856, 656)
            ),
            "{selector}"
        );
    }
    // A stand-in: its bar and body take exactly the placement's rectangle,
    // and upstream frames a stand-in without its shadow.
    for selector in [json!({"window":2}), json!({"window":"mail"})] {
        assert_eq!(
            h.shot(json!({"Window":selector}), 1.0),
            effect(
                window(2, mail_world.clone()),
                1.0,
                json!(1),
                mail_world.clone(),
                (300, 200)
            ),
            "{selector}"
        );
    }
    // A window target needs no active output, and names none.
    assert_eq!(
        h.shot_on(Value::Null, json!({"Window":{"window":1}}), 1.0, SHOT),
        effect(
            window(1, term_world.clone()),
            1.0,
            Value::Null,
            shadowed.clone(),
            (428, 328)
        )
    );

    // All: the union of both, stand-in included, with `fit_padding` around it.
    // (86, 36)..(514, 364) and (700, 500)..(1000, 700), padded by 40.
    assert_eq!(
        h.shot(json!("All"), 0.25),
        effect(
            json!("All"),
            0.25,
            json!(1),
            rect(46.0, -4.0, 994.0, 744.0),
            (249, 186)
        )
    );

    // Region in canvas coordinates: the center, Y up, with upstream's
    // truncating halving of an odd size.
    let canvas = json!({"Region":{"x":-1000,"y":-500,"w":2000,"h":1001,"from_screen":false}});
    assert_eq!(
        h.shot(canvas.clone(), 1.0),
        effect(
            canvas,
            1.0,
            json!(1),
            rect(-2000.0, 0.0, 2000.0, 1001.0),
            (2000, 1001)
        )
    );
    // Region in screen coordinates: global points through the output under
    // its corner. The output starts at (200, 100), shows the canvas from
    // (1000, -200) and halves it.
    let screen = json!({"Region":{"x":300,"y":150,"w":100,"h":50,"from_screen":true}});
    assert_eq!(
        h.shot(screen.clone(), 3.0),
        effect(
            screen,
            3.0,
            json!(1),
            rect(1200.0, -100.0, 200.0, 100.0),
            (600, 300)
        )
    );
    // A corner outside every output is read through the active one.
    let outside = json!({"Region":{"x":5000,"y":5000,"w":10,"h":10,"from_screen":true}});
    assert_eq!(
        h.shot(outside.clone(), 1.0),
        effect(
            outside,
            1.0,
            json!(1),
            rect(10600.0, 9600.0, 20.0, 20.0),
            (20, 20)
        )
    );
    // A corner on another output is read through that one, whichever is
    // active: output 2 starts at (1200, 100) with its own camera and zoom 1.
    h.ok(json!({"op":"register_output","stable_id":"side","screen_bounds":rect(1200.0,100.0,800.0,600.0)}));
    h.ok(json!({"op":"pan","output":2,"screen_delta":point(-70.0,30.0)}));
    let other = json!({"Region":{"x":1300,"y":150,"w":100,"h":50,"from_screen":true}});
    for active in [json!(1), Value::Null] {
        assert_eq!(
            h.shot_on(active, other.clone(), 1.0, SHOT),
            effect(
                other.clone(),
                1.0,
                json!(2),
                rect(30.0, 80.0, 100.0, 50.0),
                (100, 50)
            )
        );
    }
    // The bare viewport capture is the active output's, and rounds a
    // fractional camera to the nearest canvas unit, halves away from zero.
    h.ok(json!({"op":"pan","output":1,"screen_delta":point(0.25,-0.25)}));
    assert_eq!(h.snapshot()["outputs"][0]["camera"], point(1000.5, -200.5));
    assert_eq!(
        h.shot(json!("Viewport"), 1.0)["region"],
        rect(1001.0, -201.0, 2000.0, 1600.0)
    );
    let side = h.shot_on(json!(2), json!("Viewport"), 2.0, SHOT);
    assert_eq!(
        side,
        effect(
            json!("Viewport"),
            2.0,
            json!(2),
            rect(-70.0, 30.0, 800.0, 600.0),
            (1600, 1200)
        )
    );

    // The pixel size is `round(region * scale)`, at most 16384 a side and at
    // least one: half a pixel rounds up to it.
    let wide = json!({"Region":{"x":0,"y":0,"w":2000,"h":1000,"from_screen":false}});
    let largest = h.shot(wide.clone(), 8.192);
    assert_eq!(largest["region"], rect(-1000.0, -500.0, 2000.0, 1000.0));
    assert_eq!(
        (&largest["width"], &largest["height"]),
        (&json!(16384), &json!(8192))
    );
    let square = json!({"Region":{"x":0,"y":0,"w":2000,"h":2000,"from_screen":false}});
    let smallest = h.shot(square, 0.00025);
    assert_eq!(
        (&smallest["width"], &smallest["height"]),
        (&json!(1), &json!(1))
    );
    for (target, scale, error) in [
        (
            wide.clone(),
            8.193,
            "capture 16386x8193px exceeds the 16384px per-side limit — lower --scale or shrink the region",
        ),
        (
            json!("Viewport"),
            10.0,
            "capture 20000x16000px exceeds the 16384px per-side limit — lower --scale or shrink the region",
        ),
        (wide.clone(), 0.00025, "capture resolves to zero pixels"),
        (wide.clone(), 0.0, "scale must be a positive number"),
        (wide.clone(), -1.0, "scale must be a positive number"),
    ] {
        assert_eq!(h.shot_refused(json!(1), target, scale, SHOT), error);
    }
}

#[test]
fn a_window_capture_frames_the_chrome_the_config_gives_it() {
    let scratch = Scratch::new();
    let mut h = Host::new();
    open(&mut h);
    h.configure(
        &scratch,
        "[decorations]\nborder_width = 2\ntitle_bar_height = 30\nopacity = 0.7\nopacity_focused = 0.9\n\
         [[window_rules]]\napp_id = \"app.flat\"\nborder_width = 3\nshadow = false\nopacity = 0.5\n\
         [[window_rules]]\napp_id = \"app.bare\"\ndecoration = \"none\"\n\
         [[window_rules]]\napp_id = \"app.barred\"\ndecoration = \"server\"\n",
    );
    let world = rect(100.0, 50.0, 400.0, 300.0);
    let region = |h: &mut Host, id: u64| {
        let effect = h.shot(json!({"Window":{"window":id}}), 1.0);
        assert_eq!(effect["target"]["Window"]["window"], id);
        effect["region"].clone()
    };
    let opacity = |h: &mut Host, id: u64| {
        h.shot(json!({"Window":{"window":id}}), 1.0)["target"]["Window"]["opacity"].clone()
    };
    // The global border (2) and the shadow radius (14) on every side.
    let plain = put(&mut h, 1, "app.plain", "Plain", world.clone());
    assert_eq!(region(&mut h, plain), rect(84.0, 34.0, 432.0, 332.0));
    // A rule's border (3) and no shadow.
    let flat = put(&mut h, 2, "app.flat", "Flat", world.clone());
    assert_eq!(region(&mut h, flat), rect(97.0, 47.0, 406.0, 306.0));
    // A window captured alone is captured as itself, not as the unfocused or
    // focused window it is on screen: at its rule's opacity, else opaque.
    assert_eq!(h.placement(plain)["decoration"]["opacity"], 0.7);
    assert_eq!(opacity(&mut h, plain), 1.0);
    h.observe_focus(plain);
    assert_eq!(h.placement(plain)["decoration"]["opacity"], 0.9);
    assert_eq!(opacity(&mut h, plain), 1.0);
    assert_eq!(opacity(&mut h, flat), 0.5);
    // `none`: the bare frame.
    let bare = put(&mut h, 3, "app.bare", "Bare", world.clone());
    assert_eq!(region(&mut h, bare), world);
    // `server`: the compositor's title bar (30) above the frame as well.
    let barred = put(&mut h, 4, "app.barred", "Barred", world.clone());
    assert_eq!(region(&mut h, barred), rect(84.0, 4.0, 432.0, 362.0));
    // A frame off the pixel grid is read at upstream's integer boundary.
    let offgrid = put(
        &mut h,
        5,
        "app.plain",
        "Offgrid",
        rect(10.4, 20.6, 100.4, 50.5),
    );
    assert_eq!(region(&mut h, offgrid), rect(-6.0, 5.0, 132.0, 83.0));

    // Stand-ins take the global border and no rule, and never the shadow. Its
    // bar and body cover the window's rectangle; one shorter than the bar
    // keeps a body one unit high below it, as upstream's does.
    detach(&mut h, flat);
    assert_eq!(region(&mut h, flat), rect(98.0, 48.0, 404.0, 304.0));
    assert_eq!(opacity(&mut h, flat), 1.0);
    let short = put(&mut h, 6, "app.plain", "Short", rect(0.0, 0.0, 300.0, 10.0));
    detach(&mut h, short);
    assert_eq!(region(&mut h, short), rect(-2.0, -2.0, 304.0, 35.0));
    // Off the grid a stand-in is rounded outward, as upstream rounds one.
    detach(&mut h, offgrid);
    assert_eq!(region(&mut h, offgrid), rect(8.0, 18.0, 105.0, 56.0));
}

#[test]
fn screenshot_refusals_are_upstreams_and_ask_nothing_of_the_shell() {
    let mut h = Host::new();
    let viewport = json!("Viewport");
    let all = json!("All");
    let region = |w: i32, h: i32, from_screen: bool| json!({"Region":{"x":0,"y":0,"w":w,"h":h,"from_screen":from_screen}});
    // No output, no window.
    for (output, target, scale, path, error) in [
        (
            Value::Null,
            viewport.clone(),
            1.0,
            SHOT,
            "no active output to capture",
        ),
        (Value::Null, all.clone(), 1.0, SHOT, "no windows to capture"),
        (
            Value::Null,
            json!({"Window":{}}),
            1.0,
            SHOT,
            "no focused window",
        ),
        (
            Value::Null,
            region(10, 10, true),
            1.0,
            SHOT,
            "no output for the screen region",
        ),
        (json!(7), all.clone(), 1.0, SHOT, "unknown output"),
    ] {
        assert_eq!(h.shot_refused(output, target, scale, path), error);
    }
    open(&mut h);
    put(
        &mut h,
        1,
        "app.term",
        "Shell",
        rect(100.0, 50.0, 400.0, 300.0),
    );
    // The path first, then the target, then the scale, as upstream checks them.
    for (target, scale, path, error) in [
        (
            viewport.clone(),
            1.0,
            "shot.png",
            "screenshot path must be absolute",
        ),
        (
            json!({"Window":{"window":9}}),
            0.0,
            "./shot.png",
            "screenshot path must be absolute",
        ),
        (
            viewport.clone(),
            1.0,
            "",
            "screenshot path must be absolute",
        ),
        (
            viewport.clone(),
            1.0,
            "/tmp/shot\u{0}.png",
            "screenshot path is not a usable file path",
        ),
        (
            json!({"Window":{"window":9}}),
            0.0,
            SHOT,
            "no window with id 9",
        ),
        (
            json!({"Window":{"window":"Nope"}}),
            0.0,
            SHOT,
            "no window matching 'nope'",
        ),
        (json!({"Window":{}}), 1.0, SHOT, "no focused window"),
        (
            region(0, 10, false),
            0.0,
            SHOT,
            "region width and height must be positive",
        ),
        (
            region(10, -1, true),
            1.0,
            SHOT,
            "region width and height must be positive",
        ),
        (all.clone(), 0.0, SHOT, "scale must be a positive number"),
        (
            json!({"Window":{"window":1}}),
            -2.0,
            SHOT,
            "scale must be a positive number",
        ),
        (
            region(10, 10, false),
            0.04,
            SHOT,
            "capture resolves to zero pixels",
        ),
        (
            region(20000, 10, false),
            1.0,
            SHOT,
            "capture 20000x10px exceeds the 16384px per-side limit — lower --scale or shrink the region",
        ),
    ] {
        assert_eq!(h.shot_refused(json!(1), target, scale, path), error);
    }
    // A frame that rounds to no area has nothing to capture, alone or as the
    // only window of the canvas.
    let mut thin = Host::new();
    open(&mut thin);
    put(
        &mut thin,
        1,
        "app.thin",
        "Thin",
        rect(10.0, 10.0, 0.3, 40.0),
    );
    assert_eq!(
        thin.shot_refused(json!(1), json!({"Window":{"window":1}}), 1.0, SHOT),
        "window has no capturable area"
    );
    assert_eq!(
        thin.shot_refused(json!(1), all.clone(), 1.0, SHOT),
        "no windows to capture"
    );
    // Geometry outside upstream's integers is refused, not saturated: a
    // frame, and a camera, three billion units out.
    let mut far = Host::new();
    open(&mut far);
    put(
        &mut far,
        1,
        "app.far",
        "Far",
        rect(3.0e9, 0.0, 400.0, 300.0),
    );
    for target in [json!({"Window":{"window":1}}), all.clone()] {
        assert_eq!(
            far.shot_refused(json!(1), target, 1.0, SHOT),
            "window geometry exceeds integer range"
        );
    }
    far.ok(json!({"op":"pan","output":1,"screen_delta":point(3.0e9,0.0)}));
    // A screen region that lands past the canvas range is refused by v0.21's
    // own check (src/ipc/mod.rs `within_window_range`) before the geometry is
    // read.
    for (target, message) in [
        (viewport.clone(), "view geometry exceeds integer range"),
        (region(10, 10, true), "region lies past the canvas range"),
    ] {
        assert_eq!(far.shot_refused(json!(1), target, 1.0, SHOT), message);
    }

    // What is not upstream's request at all is refused as one.
    for request in [
        json!({"Screenshot":{"target":"Viewport","scale":1.0}}),
        json!({"Screenshot":{"target":"Viewport","path":SHOT}}),
        json!({"Screenshot":{"target":"Desktop","scale":1.0,"path":SHOT}}),
        json!({"Screenshot":{"target":{"Region":{"x":0,"y":0,"w":5,"h":5}},"scale":1.0,"path":SHOT}}),
        json!({"Screenshot":{"target":"Viewport","scale":"big","path":SHOT}}),
    ] {
        let data = h.ipc_on(json!(1), request.clone());
        let error = data["reply"]["Err"].as_str().expect("an Err reply");
        assert!(error.starts_with("invalid request: "), "{request}: {error}");
        assert_eq!(data["effects"], json!([]), "{request}");
    }
    // Nothing was asked of the shell, so there is nothing for it to answer.
    assert_eq!(
        h.error(json!({"op":"screenshot_result","error":"too late"})),
        "no screenshot is pending"
    );
}

#[test]
fn the_shells_screenshot_result_becomes_upstreams_reply() {
    let mut h = Host::new();
    open(&mut h);
    let (first, second, third) = ("/shots/first.png", "/shots/second.png", "/shots/third.png");
    for path in [first, second, third] {
        let effect = h.shot_on(json!(1), json!("Viewport"), 1.0, path);
        assert_eq!(effect["path"], path);
        assert_eq!(
            (&effect["width"], &effect["height"]),
            (&json!(1000), &json!(800))
        );
    }
    let waiting = |h: &mut Host| {
        h.ipc_on(Value::Null, json!("DebugCounters"))["reply"]["Ok"]["DebugCounters"]
            ["pending_screenshots"]
            .clone()
    };
    assert_eq!(waiting(&mut h), 3);
    // A result is not a request: every malformed one is a controller error
    // that answers nobody and keeps what is waiting.
    for command in [
        json!({"op":"screenshot_result"}),
        json!({"op":"screenshot_result","path":second}),
        json!({"op":"screenshot_result","path":second,"width":1000}),
        json!({"op":"screenshot_result","width":1000,"height":800}),
        json!({"op":"screenshot_result","path":second,"width":1000,"height":800,"error":"both"}),
        json!({"op":"screenshot_result","path":second,"error":"both"}),
        json!({"op":"screenshot_result","path":second,"width":0,"height":800}),
        json!({"op":"screenshot_result","path":second,"width":1000,"height":16385}),
        json!({"op":"screenshot_result","path":second,"width":-1,"height":800}),
        json!({"op":"screenshot_result","path":second,"width":1000,"height":800,"extra":1}),
        json!({"op":"screenshot_result","path":"/shots/other.png","width":1000,"height":800}),
    ] {
        h.error(command);
    }
    assert_eq!(
        h.error(
            json!({"op":"screenshot_result","path":"/shots/other.png","width":1000,"height":800})
        ),
        "no screenshot is pending for this path"
    );

    // Written: upstream's `Screenshot` reply with the path that was asked for
    // and the pixel size the shell wrote, whichever capture finishes first.
    assert_eq!(
        h.written(second, 1000, 800),
        json!({"reply":{"Ok":{"Screenshot":{"path":second,"width":1000,"height":800}}}})
    );
    assert_eq!(waiting(&mut h), 2);
    // Answered once: the same path is no longer waiting.
    assert_eq!(
        h.error(json!({"op":"screenshot_result","path":second,"width":1000,"height":800})),
        "no screenshot is pending for this path"
    );
    // Failed: upstream's `Err` with the shell's text, for the oldest waiting.
    assert_eq!(
        h.ok(json!({"op":"screenshot_result","error":"cannot write /shots/first.png: Permission denied"})),
        json!({"reply":{"Err":"cannot write /shots/first.png: Permission denied"}})
    );
    assert_eq!(
        h.error(json!({"op":"screenshot_result","path":first,"width":1000,"height":800})),
        "no screenshot is pending for this path"
    );
    assert_eq!(
        h.written(third, 2000, 1600),
        json!({"reply":{"Ok":{"Screenshot":{"path":third,"width":2000,"height":1600}}}})
    );
    assert_eq!(waiting(&mut h), 0);
    assert_eq!(
        h.error(json!({"op":"screenshot_result","error":"nothing left"})),
        "no screenshot is pending"
    );

    // What is waiting survives a scene loaded over the controller, as the
    // other effects in flight do.
    let scratch = Scratch::new();
    let scene = scratch.path("scene.json");
    let effect = h.shot_on(json!(1), json!("Viewport"), 1.0, first);
    assert_eq!(effect["path"], first);
    h.ok(json!({"op":"save","path":scene}));
    h.ok(json!({"op":"load","path":scene}));
    assert_eq!(
        h.written(first, 1000, 800),
        json!({"reply":{"Ok":{"Screenshot":{"path":first,"width":1000,"height":800}}}})
    );
}
