// SPDX-License-Identifier: GPL-3.0-or-later
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

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Saved {
    version: u32,
    scene: Scene,
    metadata: BTreeMap<WindowId, Metadata>,
    outputs: BTreeMap<OutputId, SavedOutput>,
    next_window: u64,
    next_output: u64,
    /// Additive: absent from files written before bookmarks existed, and
    /// omitted while empty, so an older build still reads a save that has none.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    bookmarks: BTreeMap<String, [f64; 2]>,
    /// Additive in the same way: the logical ids of the stand-ins. Every other
    /// window was open at the save, bound or not, and is a slot its own window
    /// may come back to. A file written before stand-ins existed has only those.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    standins: BTreeSet<WindowId>,
}
impl Controller {
    /// Save world geometry and output cameras, never live bindings or gestures.
    /// Which windows are stand-ins is saved; marks and relaunches are not.
    /// Rename commits atomically; directory sync errors may occur after commit.
    pub fn save(&self, path: impl AsRef<Path>) -> Result<(), Error> {
        let mut scene = self.scene.clone();
        for output in self.scene.outputs() {
            scene.remove_output(output.id)?;
        }
        let saved = Saved {
            version: SAVE_VERSION,
            scene,
            metadata: self.metadata.clone(),
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
    pub fn load(path: impl AsRef<Path>) -> Result<Self, Error> {
        let mut bytes = Vec::new();
        File::open(path)?
            .take(MAX_SAVE_BYTES + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_SAVE_BYTES {
            return Err(Error::Invalid("save exceeds 32 MiB"));
        }
        let saved: Saved = serde_json::from_slice(&bytes)?;
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
        // Names are unrestricted, as upstream's are: load accepts what set stores.
        if saved.bookmarks.values().flatten().any(|v| !v.is_finite()) {
            return Err(Error::Invalid("invalid saved bookmark"));
        }
        if saved
            .standins
            .iter()
            .any(|id| saved.scene.window(*id).is_none())
        {
            return Err(Error::Invalid("invalid saved stand-in"));
        }
        let mut outputs = saved.outputs;
        for output in outputs.values_mut() {
            output.seed = CameraSeed::File;
        }
        Ok(Self {
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
            retired_resize_identities: Vec::new(),
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
        })
    }
}
