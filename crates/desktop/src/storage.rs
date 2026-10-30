// SPDX-License-Identifier: GPL-3.0-or-later
// The bounds on what a saved scene, a request or a stand-in may hold are adapted
// from https://github.com/malbiruk/driftwm @ df3de27b26c7998e8a460cffd8a4925cbed3a322
// (v0.21.0), src/state/session_store.rs: CAMERA_LIMIT, POSITION_LIMIT,
// valid_canvas_point, within_window_range, valid_camera_seed, MAX_BOOKMARKS,
// MAX_BOOKMARK_NAME, bookmark_problem, bounded_bookmarks and DriftWm::set_bookmark,
// valid_entry_geometry (a saved window outside the limits is dropped), and
// src/decorations.rs MAX_BUFFER_EXTENT, the stand-in ceiling.
// Upstream's session store is a stand-in list; here the scene file holds a slot
// for every window, and the same rule applies to each slot.
use super::rules::{Pin, Policy};
use super::*;
use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};
const MAX_SAVE_BYTES: u64 = 32 * 1024 * 1024;
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// The canvas range `msg camera` and bookmarks may point the view at.
/// Navigating to a window can take it a little further, up to the windows'
/// [`POSITION_LIMIT`], which a restored camera is checked against.
pub(crate) const CAMERA_LIMIT: f64 = 1e9;

/// The canvas range a window position may lie in, saved or requested: the
/// camera's range plus headroom, so a window placed beside one at the camera's
/// edge still survives a restore. Any two positions inside it stay an `i32`
/// apart, so window-to-window math can't overflow.
pub(crate) const POSITION_LIMIT: i32 = 1_050_000_000;

/// Upstream `decorations::MAX_BUFFER_EXTENT`: the most a stand-in can measure
/// along either side, and so the largest a saved slot may be.
pub(crate) const MAX_STANDIN_EXTENT: i32 = 16384;

/// The registry takes no new name past this many bookmarks.
pub(crate) const MAX_BOOKMARKS: usize = 256;
/// Longest bookmark name, in bytes.
pub(crate) const MAX_BOOKMARK_NAME: usize = 256;

pub(crate) fn valid_canvas_point(x: f64, y: f64) -> bool {
    x.is_finite() && y.is_finite() && x.abs() <= CAMERA_LIMIT && y.abs() <= CAMERA_LIMIT
}

/// Whether a point lies in the windows' range: where navigating to a window
/// can take the view.
pub(crate) fn within_window_range(x: f64, y: f64) -> bool {
    let limit = f64::from(POSITION_LIMIT);
    x.is_finite() && y.is_finite() && x.abs() <= limit && y.abs() <= limit
}

/// Why bookmark `name` at `[x, y]` can't be held, if it can't. Config seeds
/// are the user's own and stand outside these bounds.
fn bookmark_problem(name: &str, [x, y]: [f64; 2]) -> Option<String> {
    if name.len() > MAX_BOOKMARK_NAME {
        return Some(format!(
            "bookmark names are at most {MAX_BOOKMARK_NAME} bytes"
        ));
    }
    if !x.is_finite() || !y.is_finite() {
        return Some("bookmark coordinates must be finite".to_string());
    }
    if !valid_canvas_point(x, y) {
        return Some(format!(
            "bookmark coordinates must be within ±{CAMERA_LIMIT:e}"
        ));
    }
    None
}

/// A saved registry cut to what [`Controller::store_bookmark`] would have
/// accepted, so a corrupt or hand-edited scene can't restore past it.
fn bounded_bookmarks(saved: BTreeMap<String, [f64; 2]>) -> BTreeMap<String, [f64; 2]> {
    saved
        .into_iter()
        .filter(|(name, point)| bookmark_problem(name, *point).is_none())
        .take(MAX_BOOKMARKS)
        .collect()
}

/// Upstream `valid_entry_geometry` for one saved window: sizes in
/// `1..=MAX_STANDIN_EXTENT` and a top-left within [`POSITION_LIMIT`].
fn valid_slot_geometry(rect: Rect) -> bool {
    let sizes = 1.0..=f64::from(MAX_STANDIN_EXTENT);
    let limit = f64::from(POSITION_LIMIT);
    sizes.contains(&rect.size.width)
        && sizes.contains(&rect.size.height)
        && rect.origin.x.abs() <= limit
        && rect.origin.y.abs() <= limit
}

/// Upstream `valid_camera_seed`: a saved camera is applied only inside the
/// windows' range and a zoom inside the real zoom bounds. An invalid one is
/// replaced by the origin at zoom 1 instead of warping every canvas conversion.
fn valid_camera_seed(camera: Point, zoom: f64) -> bool {
    within_window_range(camera.x, camera.y)
        && zoom.is_finite()
        && (driftwm_core::canvas::MIN_ZOOM_FLOOR..=driftwm_core::canvas::MAX_ZOOM).contains(&zoom)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Saved {
    version: u32,
    scene: Scene,
    metadata: BTreeMap<WindowId, Metadata>,
    outputs: BTreeMap<OutputId, SavedOutput>,
    next_window: u64,
    next_output: u64,
    /// Absent from files written before bookmarks existed, and omitted while
    /// empty.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    bookmarks: BTreeMap<String, [f64; 2]>,
    /// The logical ids of the stand-ins. Every other window was open at the
    /// save, bound or not, and is a slot its own window may come back to.
    /// Absent from files written before stand-ins existed.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    standins: BTreeSet<WindowId>,
    /// The screen-pinned windows, each with the output it is fixed to and its
    /// place there. Upstream's session file holds none, because its windows
    /// die with the compositor; here the window lives on, and its slot keeps
    /// the pin it had. Absent from files that have none.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pins: BTreeMap<WindowId, Pin>,
}
impl Controller {
    /// Save world geometry and output cameras, never live bindings or gestures.
    /// Which windows are stand-ins is saved; marks and relaunches are not.
    /// Upstream's widgets never enter the session store: a widget is left out
    /// with everything about it, and so is every window's applied rule, which
    /// is resolved again when the window maps. A pinned window is saved with
    /// its pin, and with the canvas frame that pin shows.
    /// Rename commits atomically; directory sync errors may occur after commit.
    pub(crate) fn save(&self, path: impl AsRef<Path>) -> Result<(), Error> {
        let mut scene = self.scene.clone();
        for output in self.scene.outputs() {
            scene.remove_output(output.id)?;
        }
        // Upstream's session store: fullscreen is never saved. A fullscreen
        // window is saved at the place it had before (live_window_rect), with
        // the pin it had, and at the size it has: a native window outlives
        // the canvas at that size, where upstream's client maps again at the
        // saved one. The output's camera is saved as it stands, parked, as
        // upstream's per_output_cameras writes it.
        for (window, rect) in self.fullscreen_saved_frames() {
            scene.set_window_rect(window, rect)?;
        }
        let widget = |id: &WindowId| self.is_widget(*id);
        if self.scene.windows().iter().any(|w| widget(&w.id)) {
            // `Scene` cannot drop a window without moving the focus onto
            // another, so the widgets leave through its own validated form.
            let mut data = serde_json::to_value(&scene)?;
            if scene.focused().is_some_and(|id| widget(&id)) {
                data["focused"] = Value::Null;
            }
            if let Some(windows) = data["windows"].as_array_mut() {
                windows.retain(|w| !w["id"].as_u64().is_some_and(|id| widget(&WindowId(id))));
            }
            scene = serde_json::from_value(data)?;
        }
        let kept = |id: &WindowId| scene.window(*id).is_some();
        let saved = Saved {
            version: SAVE_VERSION,
            metadata: self
                .metadata
                .iter()
                .filter(|(id, _)| kept(id))
                .map(|(id, metadata)| (*id, metadata.clone()))
                .collect(),
            outputs: self.outputs.clone(),
            next_window: self.next_window,
            next_output: self.next_output,
            // Upstream: with restore on, the live registry is the durable one.
            // With it off runtime edits are ephemeral, so the file's registry
            // is carried forward untouched instead.
            bookmarks: if !self.configured || self.config().session.restore_bookmarks {
                self.bookmarks.clone()
            } else {
                self.durable_bookmarks.clone()
            },
            standins: self
                .lifecycle
                .standins
                .iter()
                .copied()
                .filter(|id| self.scene.window(*id).is_some() && !self.sources.contains_key(id))
                .collect(),
            pins: self
                .policy
                .pins
                .iter()
                .map(|(id, pin)| (*id, *pin))
                .chain(self.fullscreen.stashed_pins())
                .filter(|(id, _)| kept(id) && !self.lifecycle.standins.contains(id))
                .collect(),
            scene,
        };
        let bytes = serde_json::to_vec_pretty(&saved)?;
        if bytes.len() as u64 > MAX_SAVE_BYTES {
            return Err(Error::Invalid("save exceeds 32 MiB"));
        }
        let path = path.as_ref();
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let name = path
            .file_name()
            .ok_or(Error::Invalid("save path has no filename"))?;
        let (temporary, mut file) = loop {
            let mut name = name.to_os_string();
            name.push(format!(
                ".{}.{}.tmp",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let temporary = parent.join(name);
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            match options.open(&temporary) {
                Ok(file) => break (temporary, file),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e.into()),
            }
        };
        let result = (|| -> std::io::Result<()> {
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temporary, path)?;
            File::open(parent)?.sync_all()
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result?;
        Ok(())
    }
    /// Load detached placeholders. The host must register connected outputs and
    /// explicitly attach newly observed identities before requesting input.
    /// The result is unconfigured: the `load` command carries the configuration
    /// in force across and applies its session rules.
    pub(crate) fn load(path: impl AsRef<Path>) -> Result<Self, Error> {
        let mut bytes = Vec::new();
        File::open(path)?
            .take(MAX_SAVE_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_SAVE_BYTES {
            return Err(Error::Invalid("save exceeds 32 MiB"));
        }
        let mut saved: Saved = serde_json::from_slice(&bytes)?;
        if saved.version != SAVE_VERSION {
            return Err(Error::Invalid("unsupported desktop save schema"));
        }
        if !saved.scene.outputs().is_empty() {
            return Err(Error::Invalid("saved outputs must be detached"));
        }
        if saved.metadata.len() != saved.scene.windows().len() {
            return Err(Error::Invalid("saved metadata mismatch"));
        }
        for window in saved.scene.windows() {
            if window.id.0 == 0 || window.id.0 > saved.next_window {
                return Err(Error::Invalid("invalid saved window counter"));
            }
            let metadata = saved
                .metadata
                .get(&window.id)
                .ok_or(Error::Invalid("missing saved metadata"))?;
            if !text_valid(&metadata.bundle_id, 1024) || !text_valid(&metadata.title, 16384) {
                return Err(Error::Invalid("invalid saved metadata"));
            }
        }
        // Upstream valid_entry_geometry: a saved window whose size is past what
        // a stand-in can be, or whose position lies past the window range, is
        // dropped with everything saved about it, and the rest restore. The
        // focus is not handed on to another window, as upstream starts
        // unfocused when the focused one is not restored.
        let outside: Vec<WindowId> = saved
            .scene
            .windows()
            .iter()
            .filter(|w| !valid_slot_geometry(w.world_rect))
            .map(|w| w.id)
            .collect();
        if !outside.is_empty() {
            let unfocus = saved
                .scene
                .focused()
                .is_some_and(|id| outside.contains(&id));
            for id in &outside {
                saved.scene.remove_window(*id)?;
                saved.metadata.remove(id);
                saved.standins.remove(id);
                saved.pins.remove(id);
            }
            if unfocus {
                saved.scene.clear_focus();
            }
        }
        let mut ids = std::collections::BTreeSet::new();
        let mut validation = Scene::new();
        for (id, output) in &saved.outputs {
            if id.0 == 0
                || id.0 > saved.next_output
                || *id != output.viewport.id
                || output.stable_id.trim().is_empty()
                || !text_valid(&output.stable_id, 1024)
                || !ids.insert(&output.stable_id)
            {
                return Err(Error::Invalid("invalid saved output metadata"));
            }
            validation.add_output(output.viewport.clone())?;
        }
        // Upstream bounded_bookmarks: a registry past what `set` would accept
        // is cut to the entries it would have, not refused as a whole.
        saved.bookmarks = bounded_bookmarks(saved.bookmarks);
        if saved
            .standins
            .iter()
            .any(|id| saved.scene.window(*id).is_none())
        {
            return Err(Error::Invalid("invalid saved stand-in"));
        }
        // A pin belongs to a window that is no stand-in, on a saved output.
        if saved.pins.iter().any(|(id, pin)| {
            saved.scene.window(*id).is_none()
                || saved.standins.contains(id)
                || !saved.outputs.contains_key(&pin.output)
        }) {
            return Err(Error::Invalid("invalid saved pin"));
        }
        let mut outputs = saved.outputs;
        for output in outputs.values_mut() {
            output.seed = CameraSeed::File;
            // Upstream valid_camera_seed: a saved camera that no window could
            // put the view at is not restored.
            if !valid_camera_seed(output.viewport.camera, output.viewport.zoom) {
                output.viewport.camera = Point::default();
                output.viewport.zoom = 1.0;
            }
        }
        let mut controller = Self {
            scene: saved.scene,
            metadata: saved.metadata,
            sources: BTreeMap::new(),
            outputs,
            next_window: saved.next_window,
            next_output: saved.next_output,
            gesture: None,
            focus: FocusRuntime::default(),
            next_effect: 0,
            next_generation: 0,
            flights: BTreeMap::new(),
            navigation_contexts: BTreeMap::new(),
            navigation_clock: None,
            next_navigation: 0,
            home_returns: BTreeMap::new(),
            overview_returns: BTreeMap::new(),
            bookmarks: saved.bookmarks.clone(),
            active_bookmarks: BTreeMap::new(),
            native_resize: None,
            next_resize: 0,
            settings: Arc::default(),
            configured: false,
            platform: Platform::default(),
            durable_bookmarks: saved.bookmarks,
            layout: None,
            last_event: None,
            lifecycle: Lifecycle {
                standins: saved.standins,
                ..Lifecycle::default()
            },
            motion: Motion::default(),
            trackpad_gesture: None,
            trackpad_override: None,
            drags: 0,
            policy: Policy {
                pins: saved.pins,
                ..Policy::default()
            },
            render_revision: 0,
            pending_screenshots: Vec::new(),
            sizes: Sizes::default(),
            effects: Effects::default(),
            fullscreen: Fullscreen::default(),
        };
        // A scene file holds no snapping exclusions; the pins restore them.
        // Public load returns that normalized state immediately, so queries
        // need not mutate a newly loaded controller to finish restoring it.
        controller.settle_state()?;
        Ok(controller)
    }
}
impl Controller {
    /// Upstream `DriftWm::set_bookmark`: set bookmark `name` to `point`,
    /// refusing a new name once the registry holds [`MAX_BOOKMARKS`], and an
    /// overlong name or out-of-range point.
    pub(crate) fn store_bookmark(&mut self, name: String, point: [f64; 2]) -> Result<(), String> {
        if let Some(problem) = bookmark_problem(&name, point) {
            return Err(problem);
        }
        if !self.bookmarks.contains_key(&name) && self.bookmarks.len() >= MAX_BOOKMARKS {
            return Err(format!(
                "at most {MAX_BOOKMARKS} bookmarks can be set; delete one first"
            ));
        }
        self.bookmarks.insert(name, point);
        Ok(())
    }
}
