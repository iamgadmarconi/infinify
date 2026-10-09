// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/state/reload.rs (reload_config: a file that cannot be read or parsed keeps
// the old config, a file that has gone missing included; an accepted one is
// swapped in whole and its bookmark seeds are reconciled with the live
// registry), src/config/mod.rs (load_from_collect: at startup a missing file is
// the built-in defaults) and src/state/session_store.rs
// (load_session and saved_camera_state: what restore_bookmarks and
// restore_camera let a saved session bring back). The configuration itself is
// driftwm-core's `Config`, upstream's own code.
use super::bindings::{Platform, key_known};
use super::*;
use driftwm_core::config::{Config, config_path, parse_key_combo, parse_tap_combo};
use std::io::Read;

/// A config file is hand-written text; anything larger is not one.
const MAX_CONFIG_BYTES: u64 = 4 * 1024 * 1024;

/// The configuration in force. Never saved: it is the file's, or the built-in
/// defaults. Replaced whole by an accepted `load_config`.
#[derive(Debug, Default)]
pub(crate) struct Settings {
    pub(crate) config: Config,
    /// Keysyms the file's `[keybindings]` table names that the macOS key table
    /// does not have, each with the key name as the file spells it, so their
    /// bindings can be reported instead of vanishing.
    pub(crate) extra_keysyms: Vec<(u32, String)>,
    /// Parsed from a file. False for the built-in defaults, whether no file was
    /// found or the launch file was refused.
    pub(crate) from_file: bool,
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

/// The key names of the file's `[keybindings]` table that parse as a key combo
/// on a keysym outside the macOS key table. Upstream normalizes each combo
/// before storing it, so the same is done before the keysym is kept.
fn extra_keysyms(contents: &str, config: &Config) -> Vec<(u32, String)> {
    let Ok(table) = contents.parse::<toml::Table>() else {
        return Vec::new();
    };
    let mut extra: Vec<(u32, String)> = Vec::new();
    for name in table
        .get("keybindings")
        .and_then(toml::Value::as_table)
        .into_iter()
        .flat_map(|bindings| bindings.keys())
    {
        if parse_tap_combo(name, config.mod_key).is_some() {
            continue;
        }
        if let Ok(mut combo) = parse_key_combo(name, config.mod_key) {
            combo.normalize();
            let sym = combo.sym.raw();
            if !key_known(sym) && extra.iter().all(|(known, _)| *known != sym) {
                let key = name.rsplit('+').next().unwrap_or(name).trim();
                extra.push((sym, key.to_owned()));
            }
        }
    }
    extra
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
    /// `warnings` are upstream's own messages. A file that is missing is the
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
            Ok(contents) => (
                true,
                Config::from_toml_collect(&contents)
                    .map(|(config, warnings)| {
                        let extra_keysyms = extra_keysyms(&contents, &config);
                        (
                            Settings {
                                config,
                                extra_keysyms,
                                from_file: true,
                            },
                            warnings,
                        )
                    })
                    .map_err(|e| format!("config error: {e}")),
            ),
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
        let (errors, warnings) = match parsed {
            Ok((settings, warnings)) => {
                let old = std::mem::replace(&mut self.settings, std::sync::Arc::new(settings));
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
            Err(error) => (vec![error], Vec::new()),
        };
        if launch {
            self.seed_bookmarks();
            self.settle_shown_cameras()?;
        }
        Ok(
            json!({"path":path.to_string_lossy(),"exists":exists,"errors":errors,"warnings":warnings,"dirty":dirty}),
        )
    }
}
