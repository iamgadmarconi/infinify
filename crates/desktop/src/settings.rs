// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/reload.rs (reload_config: a file that cannot be read or parsed keeps
// the old config, a file that has gone missing included; an accepted one is
// swapped in whole and its bookmark seeds are reconciled with the live
// registry), src/config/mod.rs (load_from_collect: at startup a missing file is
// the built-in defaults) and src/state/session_store.rs
// (load_session and saved_camera_state: what restore_bookmarks and
// restore_camera let a saved session bring back) and src/main.rs (the
// autostart commands, spawned once after startup). The configuration itself is
// driftwm-core's `Config`, upstream's own code. When a reload drops a runtime
// set-trackpad is upstream's documented rule (docs/config.md, [input.trackpad]
// enable), not its reload code, which this port did not read.
use super::bindings::{Platform, key_known};
use super::*;
use driftwm_core::config::{
    BindingContext, Config, GestureBinding, Modifiers, MouseBinding, WindowPlacement, config_path,
    parse_action, parse_gesture_binding, parse_gesture_config_entry, parse_key_combo,
    parse_mouse_action, parse_mouse_binding, parse_tap_combo,
};
use std::io::Read;

/// A config file is hand-written text; anything larger is not one.
const MAX_CONFIG_BYTES: u64 = 4 * 1024 * 1024;

/// macOS presentation policy, separate from upstream's portable background.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct DesktopBackground {
    pub(crate) inherit_macos: bool,
    pub(crate) parallax: bool,
}
impl Default for DesktopBackground {
    fn default() -> Self {
        Self {
            inherit_macos: true,
            parallax: true,
        }
    }
}

/// The configuration in force. Never saved: it is the file's, or the built-in
/// defaults. Replaced whole by an accepted `load_config`.
#[derive(Debug)]
pub(crate) struct Settings {
    pub(crate) config: Config,
    pub(crate) desktop_background: DesktopBackground,
    /// Keysyms the file's `[keybindings]` table names that the macOS key table
    /// does not have, each with the key name as the file spells it, so their
    /// bindings can be reported instead of vanishing.
    pub(crate) extra_keysyms: Vec<(u32, String)>,
    /// Every key combo the file's `[keybindings]` table binds or unbinds.
    written_keys: Vec<(Modifiers, u32)>,
    written_gestures: Vec<(BindingContext, GestureBinding)>,
    written_mouse: Vec<(BindingContext, MouseBinding)>,
    /// The macOS adapter must honor the same category switches as upstream.
    pub(crate) default_keys_disabled: bool,
    pub(crate) default_gestures_disabled: bool,
    pub(crate) default_mouse_disabled: bool,
    /// Parsed from a file. False for the built-in defaults, whether no file was
    /// found or the launch file was refused.
    pub(crate) from_file: bool,
    /// The file was there and could not be read or parsed while no file had
    /// been accepted: the built-in defaults are in force without speaking for
    /// what the user wrote. An accepted load replaces it.
    pub(crate) refused: bool,
}

impl Default for Settings {
    fn default() -> Self {
        let mut config = Config::default();
        config.window_placement = WindowPlacement::Auto;
        Self {
            config,
            desktop_background: DesktopBackground::default(),
            extra_keysyms: Vec::new(),
            written_keys: Vec::new(),
            written_gestures: Vec::new(),
            written_mouse: Vec::new(),
            default_keys_disabled: false,
            default_gestures_disabled: false,
            default_mouse_disabled: false,
            from_file: false,
            refused: false,
        }
    }
}

/// Where a saved output's viewport comes from. Never saved.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum CameraSeed {
    /// This session's own camera: an output seen before reconnects to it.
    #[default]
    Live,
    /// Read from the scene file and not yet shown on a connected output.
    File,
    /// Read from the scene file and shown before any config was loaded.
    FileShown,
}
/// Upstream `[snap]` in world units at one zoom.
pub(crate) struct Snap {
    pub(crate) options: SnapOptions,
    pub(crate) break_force: f64,
    pub(crate) corners: bool,
    pub(crate) centers: bool,
}

impl Settings {
    /// Extract the Mac-only boolean before the strict upstream parser runs.
    /// The original document still supplies binding provenance; every other
    /// option is validated by upstream with its existing defaults and errors.
    fn parse(contents: &str) -> Result<(Self, Vec<String>), String> {
        let mut table = contents
            .parse::<toml::Table>()
            .map_err(|error| format!("config error: {error}"))?;
        let has_window_placement = table.contains_key("window_placement");
        let mut desktop_background = DesktopBackground::default();
        let mut extracted = false;
        if let Some(background) = table
            .get_mut("background")
            .and_then(toml::Value::as_table_mut)
        {
            desktop_background.inherit_macos = !["type", "path", "texture"]
                .iter()
                .any(|key| background.contains_key(*key));
            if let Some(value) = background.remove("parallax") {
                extracted = true;
                desktop_background.parallax = value.as_bool().ok_or_else(|| {
                    "config error: [background] parallax must be true or false".to_owned()
                })?;
            }
        }
        let normalized;
        let upstream = if extracted {
            normalized =
                toml::to_string(&table).map_err(|error| format!("config error: {error}"))?;
            normalized.as_str()
        } else {
            contents
        };
        let (mut config, warnings) = Config::from_toml_collect(upstream)
            .map_err(|error| format!("config error: {error}"))?;
        if !has_window_placement {
            config.window_placement = WindowPlacement::Auto;
        }
        let mut settings = Self::of_file(contents, config);
        settings.desktop_background = desktop_background;
        Ok((settings, warnings))
    }
    /// Did the file's `[keybindings]` table bind or unbind this combo? If
    /// not, a binding on it is one of upstream's defaults.
    pub(crate) fn wrote(&self, modifiers: &Modifiers, sym: u32) -> bool {
        self.written_keys
            .iter()
            .any(|(written, key)| written == modifiers && *key == sym)
    }
    pub(crate) fn wrote_gesture(&self, context: BindingContext, binding: &GestureBinding) -> bool {
        self.written_gestures
            .iter()
            .any(|(written_context, written)| *written_context == context && written == binding)
    }
    pub(crate) fn wrote_mouse(&self, context: BindingContext, binding: &MouseBinding) -> bool {
        self.written_mouse
            .iter()
            .any(|(written_context, written)| *written_context == context && written == binding)
    }
    /// An accepted file's configuration, with what its `[keybindings]` table
    /// names: every key combo upstream's loader took the entry of (`none`, or
    /// an action that parses; an entry it warns about and drops leaves the
    /// default on that combo a default), and the key names on a keysym outside
    /// the macOS key table. Upstream normalizes each combo before storing it,
    /// so the same is done before the combo is kept.
    fn of_file(contents: &str, config: Config) -> Self {
        let (mut written_keys, mut extra_keysyms) = (Vec::new(), Vec::<(u32, String)>::new());
        let table = contents.parse::<toml::Table>().unwrap_or_default();
        // Upstream accepts exactly keys/mouse/gestures/touch. Unknown categories
        // (including "all") are warned and ignored by its config parser.
        let disabled = table
            .get("bindings")
            .and_then(toml::Value::as_table)
            .and_then(|bindings| bindings.get("disable_defaults"))
            .and_then(toml::Value::as_array);
        let disables = |category: &str| {
            disabled.is_some_and(|categories| {
                categories
                    .iter()
                    .any(|value| value.as_str() == Some(category))
            })
        };
        let (default_keys_disabled, default_gestures_disabled) =
            (disables("keys"), disables("gestures"));
        let default_mouse_disabled = disables("mouse");
        let mut written_mouse = Vec::new();
        if let Some(mouse) = table.get("mouse").and_then(toml::Value::as_table) {
            for (name, context) in [
                ("on-window", BindingContext::OnWindow),
                ("on-canvas", BindingContext::OnCanvas),
                ("anywhere", BindingContext::Anywhere),
            ] {
                for (name, action) in mouse
                    .get(name)
                    .and_then(toml::Value::as_table)
                    .into_iter()
                    .flatten()
                {
                    if let Ok(binding) = parse_mouse_binding(name, config.mod_key)
                        && action.as_str().is_some_and(|action| {
                            action == "none" || parse_mouse_action(action).is_ok()
                        })
                    {
                        written_mouse.push((context, binding));
                    }
                }
            }
        }
        let mut written_gestures = Vec::new();
        if let Some(gestures) = table.get("gestures").and_then(toml::Value::as_table) {
            for (name, context) in [
                ("on-window", BindingContext::OnWindow),
                ("on-canvas", BindingContext::OnCanvas),
                ("anywhere", BindingContext::Anywhere),
            ] {
                for (name, action) in gestures
                    .get(name)
                    .and_then(toml::Value::as_table)
                    .into_iter()
                    .flatten()
                {
                    if let Ok(binding) = parse_gesture_binding(name, config.mod_key)
                        && action.as_str().is_some_and(|action| {
                            action == "none"
                                || parse_gesture_config_entry(&binding.trigger, action).is_ok()
                        })
                    {
                        written_gestures.push((context, binding));
                    }
                }
            }
        }
        for (name, action) in table
            .get("keybindings")
            .and_then(toml::Value::as_table)
            .into_iter()
            .flatten()
        {
            if parse_tap_combo(name, config.mod_key).is_some() {
                continue;
            }
            if let Ok(mut combo) = parse_key_combo(name, config.mod_key) {
                combo.normalize();
                let sym = combo.sym.raw();
                if !key_known(sym) && extra_keysyms.iter().all(|(known, _)| *known != sym) {
                    let key = name.rsplit('+').next().unwrap_or(name).trim();
                    extra_keysyms.push((sym, key.to_owned()));
                }
                if action
                    .as_str()
                    .is_some_and(|action| action == "none" || parse_action(action).is_ok())
                {
                    written_keys.push((combo.modifiers, sym));
                }
            }
        }
        Self {
            config,
            desktop_background: DesktopBackground::default(),
            extra_keysyms,
            written_keys,
            written_gestures,
            written_mouse,
            default_keys_disabled,
            default_gestures_disabled,
            default_mouse_disabled,
            from_file: true,
            refused: false,
        }
    }
}

impl Controller {
    pub(crate) fn config(&self) -> &Config {
        &self.settings.config
    }
    /// `[snap]` for a gesture at `zoom`: distance and break force are screen
    /// points, the gap world points. Disabled snapping is a zero distance, which
    /// still lets a group move find its cluster by the gap. Every value is kept
    /// inside the range the canvas accepts.
    pub(crate) fn snap(&self, zoom: f64) -> Snap {
        let config = self.config();
        let distance = if config.snap_enabled {
            config.snap_distance
        } else {
            0.0
        };
        Snap {
            options: SnapOptions {
                gap: config.snap_gap.min(1e6),
                threshold: (distance / zoom).min(1e6),
                ..SnapOptions::default()
            },
            break_force: (config.snap_break_force / zoom).min(1e6),
            corners: config.snap_corners,
            centers: config.snap_centers,
        }
    }
    /// The registry at launch: the config seeds, with the scene file's registry
    /// laid over them only when `session.restore_bookmarks` is on.
    pub(crate) fn seed_bookmarks(&mut self) {
        let config = &self.settings.config;
        let mut bookmarks = config.navigation_bookmarks.clone();
        if config.session.restore_bookmarks {
            bookmarks.extend(self.durable_bookmarks.clone());
        }
        self.bookmarks = bookmarks;
    }
    /// The first config of a run decides what a scene file loaded before it may
    /// keep. A camera already shown from the file stays with
    /// `session.restore_camera` on, and otherwise goes back to a new output's
    /// pose, as if the config had come first.
    fn settle_shown_cameras(&mut self) -> Result<(), Error> {
        let restore = self.config().session.restore_camera;
        for (id, saved) in &mut self.outputs {
            if saved.seed != CameraSeed::FileShown {
                continue;
            }
            saved.seed = CameraSeed::Live;
            if restore {
                continue;
            }
            saved.viewport.camera = Point::default();
            saved.viewport.zoom = 1.0;
            if self.scene.output(*id).is_some() {
                self.scene.update_output(saved.viewport.clone())?;
                self.flights.remove(id);
                self.home_returns.remove(id);
                self.overview_returns.remove(id);
            }
        }
        Ok(())
    }
    pub(crate) fn set_platform(&mut self, chord: &str) -> Result<Value, Error> {
        self.platform = Platform::parse(chord).map_err(Error::Refused)?;
        Ok(json!({"super":self.platform.super_text()}))
    }
    /// Load upstream's config file, or keep what is in force. `errors` and
    /// `warnings` are upstream's own messages. `effects` are the `autostart`
    /// commands, on the first load only. A file that is missing is the
    /// built-in defaults and no error until a file has been accepted; after
    /// that a missing file is a read failure like any other. A file that cannot
    /// be read or parsed leaves the previous configuration in force, as
    /// upstream's reload does.
    pub(crate) fn load_config(&mut self, path: Option<String>) -> Result<Value, Error> {
        let path = match path {
            Some(path) if text_valid(&path, 4096) && !path.is_empty() => {
                std::path::PathBuf::from(path)
            }
            Some(_) => return Err(Error::Invalid("invalid config path")),
            None => config_path(),
        };
        let contents = (|| -> std::io::Result<String> {
            let mut contents = String::new();
            std::fs::File::open(&path)?
                .take(MAX_CONFIG_BYTES + 1)
                .read_to_string(&mut contents)?;
            if contents.len() as u64 > MAX_CONFIG_BYTES {
                return Err(std::io::Error::other("file exceeds 4 MiB"));
            }
            Ok(contents)
        })();
        let (exists, parsed) = match contents {
            Ok(contents) => (true, Settings::parse(&contents)),
            // Upstream's startup: no file is the built-in defaults. Once a file
            // has been accepted, its disappearance is upstream's reload read
            // failure and the config in force stays.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && !self.settings.from_file => {
                (false, Ok((Settings::default(), Vec::new())))
            }
            Err(e) => (
                e.kind() != std::io::ErrorKind::NotFound,
                Err(format!("config: failed to read {}: {e}", path.display())),
            ),
        };
        let launch = !self.configured;
        self.configured = true;
        let mut dirty = false;
        let revision = self.render_revision;
        let (errors, warnings) = match parsed {
            Ok((settings, warnings)) => {
                let old = std::mem::replace(&mut self.settings, std::sync::Arc::new(settings));
                // Upstream reload: a coast in progress takes the new drift.
                self.motion.set_drift(self.settings.config.drift);
                // Upstream docs/config.md: a set-trackpad press holds until a
                // saved config changes the resulting on/off state.
                if old.config.trackpad.send_events != self.settings.config.trackpad.send_events {
                    self.trackpad_override = None;
                }
                dirty |= self.settle_trackpad()?;
                // The shell rebuilds what it derived from the config only when
                // the revision moves. Upstream's reload drops its background
                // caches whatever the file changed, so that a shader or image
                // edited on disk is read again (src/state/reload.rs): every
                // accepted reload spends a revision. The launch load spends
                // one when drawn tables change, including activation of Mac
                // wallpaper policy from an unconfigured controller snapshot.
                if !launch
                    || render::sections_differ(&old.config, &self.settings.config)
                    || old.desktop_background != self.settings.desktop_background
                    || self.settings.desktop_background.inherit_macos
                    || self.settings.desktop_background.parallax
                {
                    self.render_revision = self
                        .render_revision
                        .checked_add(1)
                        .ok_or(Error::Invalid("render revisions exhausted"))?;
                }
                if !launch {
                    // Upstream reload: config is a seed. A name added or changed
                    // in config re-asserts into the registry, a name removed from
                    // config drops from it, and names config did not touch keep
                    // any runtime value.
                    let (old, new) = (
                        &old.config.navigation_bookmarks,
                        &self.settings.config.navigation_bookmarks,
                    );
                    for (name, value) in new {
                        if old.get(name) != Some(value) {
                            self.bookmarks.insert(name.clone(), *value);
                            dirty = true;
                        }
                    }
                    for name in old.keys().filter(|name| !new.contains_key(*name)) {
                        self.bookmarks.remove(name);
                        dirty = true;
                    }
                }
                (Vec::new(), warnings)
            }
            Err(error) => {
                // No file is the built-in defaults by choice. A file that is
                // there and refused before any was accepted is not.
                if !self.settings.from_file {
                    self.settings = std::sync::Arc::new(Settings {
                        refused: true,
                        ..Settings::default()
                    });
                }
                (vec![error], Vec::new())
            }
        };
        // The error bar's message, and a revision for it if none was spent above.
        self.note_config(&errors, &warnings, revision)?;
        let mut effects = Vec::new();
        if launch {
            self.seed_bookmarks();
            self.settle_shown_cameras()?;
            // Upstream reads `edge_pan.cursor_pan` once, at startup: from then
            // on the flag is toggle-cursor-pan's and a reload leaves it alone.
            self.motion.cursor_pan = self.config().edge_pan_cursor;
            // Upstream main: the launch config's autostart commands, spawned
            // as an `exec` is. A reload never runs them, a changed list included.
            let config = self.config();
            effects.extend(config.autostart.iter().map(|cmd| self.exec_effect(cmd)));
        }
        Ok(
            json!({"path":path.to_string_lossy(),"exists":exists,"errors":errors,"warnings":warnings,"dirty":dirty,"effects":effects}),
        )
    }
}
