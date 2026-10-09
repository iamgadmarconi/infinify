// SPDX-License-Identifier: GPL-3.0-or-later
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    net::Shutdown,
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, MetadataExt},
            net::UnixStream,
        },
    },
    path::Path,
    time::{Duration, Instant},
};

const MAX_PACKET: usize = 4096;

// Deliberately no Debug implementation: nonce must never enter receipts/logs.
pub(crate) struct Client {
    stream: UnixStream,
    nonce: String,
}
impl Client {
    pub(crate) fn connect(directory: &Path, nonce: String) -> Result<Self> {
        ensure!(
            nonce.len() == 64
                && nonce
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "nonce must be 64 lowercase hexadecimal characters"
        );
        // SAFETY: getuid has no pointer arguments or preconditions.
        let uid = unsafe { libc::getuid() };
        let dir = fs::symlink_metadata(directory)
            .context("private helper directory unavailable; explicitly start the helper first")?;
        ensure!(
            dir.is_dir() && dir.uid() == uid && dir.mode() & 0o777 == 0o700,
            "helper directory must be a same-UID, non-symlink 0700 directory"
        );
        let path = directory.join("helper.sock");
        let socket = fs::symlink_metadata(&path)
            .context("helper socket unavailable; privileged helper is not running")?;
        ensure!(
            socket.file_type().is_socket() && socket.uid() == uid && socket.mode() & 0o777 == 0o600,
            "helper socket must be a same-UID 0600 socket"
        );
        let stream =
            UnixStream::connect(path).context("cannot connect to explicitly selected helper")?;
        let (mut peer_uid, mut peer_gid) = (0, 0);
        // SAFETY: live descriptor and valid output pointers. Darwin getpeereid
        // authenticates the connected endpoint, beyond filesystem metadata.
        #[cfg(target_os = "macos")]
        let status = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut peer_uid, &mut peer_gid) };
        #[cfg(not(target_os = "macos"))]
        let status = {
            let _ = (stream.as_raw_fd(), &mut peer_uid, &mut peer_gid);
            -1
        };
        ensure!(
            status == 0 && peer_uid == uid,
            "helper peer UID authentication failed (macOS required)"
        );
        stream.set_read_timeout(Some(Duration::from_secs(1)))?;
        stream.set_write_timeout(Some(Duration::from_secs(1)))?;
        Ok(Self { stream, nonce })
    }
    pub(crate) fn request(&mut self, op: &str, fields: Value) -> Result<Value> {
        let mut packet = json!({"v":1,"nonce":self.nonce,"op":op});
        if let Some(fields) = fields.as_object() {
            for (key, value) in fields {
                packet[key] = value.clone();
            }
        }
        let mut bytes = serde_json::to_vec(&packet)?;
        ensure!(
            bytes.len() < MAX_PACKET,
            "request exceeds helper packet limit"
        );
        bytes.push(b'\n');
        self.stream.write_all(&bytes)?;
        let mut response = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .context("helper response deadline exceeded")?;
            ensure!(!remaining.is_zero(), "helper response deadline exceeded");
            self.stream.set_read_timeout(Some(remaining))?;
            let mut byte = [0];
            self.stream
                .read_exact(&mut byte)
                .context("helper disconnected or timed out; native state is unacknowledged")?;
            if byte[0] == b'\n' {
                break;
            }
            ensure!(
                response.len() < MAX_PACKET,
                "helper response exceeds packet limit"
            );
            response.push(byte[0]);
        }
        let value: Value = serde_json::from_slice(&response).context("invalid helper response")?;
        ensure!(value["v"] == 1, "unsupported helper response version");
        if value["ok"] != true {
            bail!(
                "helper rejected {op}: {}",
                value.get("error").and_then(Value::as_str).unwrap_or(
                    "native readback did not match; privilege or native capability unavailable"
                )
            );
        }
        Ok(value)
    }
    pub(crate) fn disconnect(&self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}
