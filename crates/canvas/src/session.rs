// SPDX-License-Identifier: GPL-3.0-or-later
// Versioned envelope and sibling-temp rename pattern adapted from
// malbiruk/driftwm src/session.rs at 352333a8fa1b22171492d4b71a54102045c9a19d. This port rejects bad files without
// mutating them, validates the scene and uses exclusive temp creation + fsync.
use crate::{Error, Scene};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};

/// This port's independent on-disk schema (not the upstream Linux schema).
pub const SESSION_VERSION: u32 = 1;
const MAX_SESSION_BYTES: u64 = 32 * 1024 * 1024;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u32,
    scene: Scene,
}

impl Scene {
    /// Encode a validated, versioned session as pretty JSON.
    pub fn to_json(&self) -> Result<String, Error> {
        self.validate()?;
        #[derive(Serialize)]
        struct BorrowedEnvelope<'a> {
            version: u32,
            scene: &'a Scene,
        }
        let json = serde_json::to_string_pretty(&BorrowedEnvelope {
            version: SESSION_VERSION,
            scene: self,
        })?;
        if json.len() as u64 > MAX_SESSION_BYTES {
            return Err(Error::Invalid("session exceeds 32 MiB"));
        }
        Ok(json)
    }
    /// Parse a session; reject unsupported versions, duplicate IDs, dangling focus,
    /// unknown fields, invalid dimensions, non-finite values, and invalid zoom.
    pub fn from_json(json: &str) -> Result<Self, Error> {
        if json.len() as u64 > MAX_SESSION_BYTES {
            return Err(Error::Invalid("session exceeds 32 MiB"));
        }
        let envelope: Envelope = serde_json::from_str(json)?;
        if envelope.version != SESSION_VERSION {
            return Err(Error::UnsupportedVersion(envelope.version));
        }
        envelope.scene.validate()?;
        Ok(envelope.scene)
    }
    /// Load a session without modifying it on failure. Missing files are reported
    /// as IO errors, letting the application choose a first-run policy explicitly.
    pub fn load(path: impl AsRef<Path>) -> Result<Self, Error> {
        let file = File::open(path)?;
        let mut bytes = Vec::new();
        file.take(MAX_SESSION_BYTES + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_SESSION_BYTES {
            return Err(Error::Invalid("session exceeds 32 MiB"));
        }
        let json =
            std::str::from_utf8(&bytes).map_err(|_| Error::Invalid("session is not UTF-8"))?;
        Self::from_json(json)
    }
    /// Atomically save via a unique sibling file, syncing file contents before
    /// rename and the containing directory afterward. Concurrent saves cannot
    /// share a temp file; the last successful rename wins. Existing parent
    /// directories are required. A directory-sync error may occur after commit.
    pub fn save_atomic(&self, path: impl AsRef<Path>) -> Result<(), Error> {
        let json = self.to_json()?;
        let path = path.as_ref();
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        let name = path
            .file_name()
            .ok_or(Error::Invalid("session path has no filename"))?;
        let (temp_path, mut file) = loop {
            let mut temp_name = name.to_os_string();
            temp_name.push(format!(
                ".{}.{}.tmp",
                std::process::id(),
                TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            let temp_path = parent.join(temp_name);
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            match options.open(&temp_path) {
                Ok(file) => break (temp_path, file),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error.into()),
            }
        };
        let result = (|| -> std::io::Result<()> {
            file.write_all(json.as_bytes())?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temp_path, path)?;
            File::open(parent)?.sync_all()
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp_path);
        }
        Ok(result?)
    }
}
