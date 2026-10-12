// SPDX-License-Identifier: GPL-3.0-or-later
//! Explicit selected-window session over an already-running authenticated helper.
//! Scene persistence never grants native enrollment. No injection or permissions UI.
mod transport;
use anyhow::{Context, Result, bail, ensure};
use driftwm_canvas::{Rect, Scene, WindowId};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    path::Path,
    sync::{Arc, Mutex, mpsc},
    thread::{self, JoinHandle},
    time::Duration,
};
use transport::Client;

/// Full fresh process-lifetime/window-owner identity; never recovered from Scene.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    pub pid: i32,
    pub birth_sec: u64,
    pub birth_usec: u32,
    pub wid: u32,
    pub owner: i32,
}
/// Actual WindowServer readback, not a successful setter return code.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Readback {
    pub readback_ok: bool,
    pub matrix: [f64; 6],
    pub screen_rect: [f64; 4],
    /// Actual untransformed native bounds, observed independently of screen rect.
    pub bounds: [f64; 4],
}
/// A revision acknowledged only after native matrix AND screen-rectangle readback.
#[derive(Clone, Debug, Serialize)]
pub struct Presented {
    pub revision: u64,
    pub window: WindowId,
    pub screen_rect: [f64; 4],
    pub readback: Readback,
}
struct Connection {
    client: Client,
    failure: Option<String>,
    expected: Readback,
}
/// One explicitly enrolled native window. Additional offscreen world entries persist.
/// Drop attempts restore; use close to obtain verified restoration or an error.
pub struct Session {
    desired: Scene,
    revision: u64,
    presented: Option<Presented>,
    selected: WindowId,
    identity: Identity,
    original: Readback,
    connection: Arc<Mutex<Connection>>,
    stop: Option<mpsc::Sender<()>>,
    heartbeat: Option<JoinHandle<()>>,
    closed: bool,
}
impl Session {
    /// Probe an already-running helper without enrollment or native mutation.
    pub fn probe(directory: &Path, nonce: String) -> Result<Value> {
        Client::connect(directory, nonce)?.probe()
    }
    /// Enroll only the caller's explicit fresh identity. Server revalidates full
    /// process birth time, owner connection, window ID and UID before snapshotting.
    pub fn enroll(
        directory: &Path,
        nonce: String,
        desired: Scene,
        selected: WindowId,
        identity: Identity,
    ) -> Result<Self> {
        desired.validate()?;
        ensure!(
            desired.window(selected).is_some(),
            "selected logical window is absent"
        );
        ensure!(
            identity.pid > 0
                && identity.wid > 0
                && identity.birth_sec > 0
                && identity.birth_usec < 1_000_000,
            "invalid complete native identity"
        );
        let mut client = Client::connect(directory, nonce)?;
        client.probe()?;
        let original = client.inspect(&identity)?;
        let heartbeat_identity = identity.clone();
        let connection = Arc::new(Mutex::new(Connection {
            client,
            failure: None,
            expected: original.clone(),
        }));
        let (stop, receive) = mpsc::channel();
        let shared = Arc::clone(&connection);
        let heartbeat = thread::spawn(move || {
            while receive.recv_timeout(Duration::from_millis(400))
                == Err(mpsc::RecvTimeoutError::Timeout)
            {
                let Ok(mut state) = shared.lock() else {
                    break;
                };
                let result = state.client.heartbeat().and_then(|()| {
                    let observed = state.client.inspect(&heartbeat_identity)?;
                    verify(&observed, state.expected.matrix, state.expected.screen_rect)?;
                    ensure!(
                        near(&observed.bounds, &state.expected.bounds, 1.0),
                        "native bounds changed during lease"
                    );
                    Ok(())
                });
                if let Err(error) = result {
                    state.failure = Some(error.to_string());
                    state.client.disconnect();
                    break;
                }
            }
        });
        Ok(Self {
            desired,
            revision: 0,
            presented: None,
            selected,
            identity,
            original,
            connection,
            stop: Some(stop),
            heartbeat: Some(heartbeat),
            closed: false,
        })
    }
    pub fn desired(&self) -> &Scene {
        &self.desired
    }
    pub fn desired_revision(&self) -> u64 {
        self.revision
    }
    /// Reject stale presentation after a background lease/readback failure.
    pub fn presented(&self) -> Option<&Presented> {
        if self.closed || self.connection.lock().ok()?.failure.is_some() {
            None
        } else {
            self.presented.as_ref()
        }
    }
    pub fn original(&self) -> &Readback {
        &self.original
    }
    /// Replace logical desired state independently of whether native presentation
    /// supports it. Save this Scene through Scene::save_atomic for persistence.
    pub fn set_desired(&mut self, scene: Scene) -> Result<()> {
        scene.validate()?;
        self.revision = self.revision.checked_add(1).context("revision overflow")?;
        self.desired = scene;
        Ok(())
    }
    /// Present one complete, unclipped native instance. Unsupported states are
    /// errors before mutation; they remain in desired state for persistence.
    pub fn apply(&mut self) -> Result<&Presented> {
        ensure!(!self.closed, "session is closed");
        let placements = self.desired.placements();
        ensure!(
            placements.iter().all(|p| p.window == self.selected),
            "visible un-enrolled windows are unsupported"
        );
        let selected: Vec<_> = placements
            .iter()
            .filter(|p| p.window == self.selected)
            .collect();
        ensure!(
            selected.len() == 1,
            "native presentation requires exactly one selected placement; hiding/offscreen or duplicate output instances are unsupported"
        );
        let placement = selected[0];
        ensure!(
            near(
                &rect(placement.screen_rect),
                &rect(placement.clip_rect),
                1e-6
            ),
            "native per-output clipping is unsupported"
        );
        let desired = rect(placement.screen_rect);
        let matrix = inverse_screen_transform(&self.original, desired)?;
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| anyhow::anyhow!("connection lock poisoned"))?;
        if let Some(failure) = &connection.failure {
            bail!("helper lease failed: {failure}");
        }
        // Once a request starts native state may change even if its reply is lost.
        self.presented = None;
        let result = (|| {
            // A native move or transform since selection/last acknowledgment
            // invalidates this camera basis before we overwrite any state.
            let before = connection.client.inspect(&self.identity)?;
            verify(
                &before,
                connection.expected.matrix,
                connection.expected.screen_rect,
            )?;
            ensure!(
                near(&before.bounds, &connection.expected.bounds, 1.0),
                "native bounds changed before applying camera"
            );
            let actual = connection.client.apply(&self.identity, matrix)?;
            verify(&actual, matrix, desired)?;
            ensure!(
                near(&actual.bounds, &self.original.bounds, 1.0),
                "native bounds changed while applying camera"
            );
            Ok(actual)
        })();
        match result {
            Ok(actual) => {
                connection.expected = actual.clone();
                self.presented = Some(Presented {
                    revision: self.revision,
                    window: self.selected,
                    screen_rect: desired,
                    readback: actual,
                });
                self.presented
                    .as_ref()
                    .context("presentation was not retained")
            }
            Err(error) => {
                connection.failure = Some(error.to_string());
                // Disconnection invokes helper restoration even after rejected/no-op
                // requests; never keep heartbeating an unverified mutation.
                connection.client.disconnect();
                Err(error)
            }
        }
    }
    /// Explicit current readback, checked against the last acknowledged native state.
    pub fn readback(&self) -> Result<Readback> {
        ensure!(!self.closed, "session is closed");
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| anyhow::anyhow!("connection lock poisoned"))?;
        if let Some(failure) = &connection.failure {
            bail!("helper lease failed: {failure}");
        }
        let result = connection
            .client
            .inspect(&self.identity)
            .and_then(|actual| {
                verify(
                    &actual,
                    connection.expected.matrix,
                    connection.expected.screen_rect,
                )?;
                ensure!(
                    near(&actual.bounds, &connection.expected.bounds, 1.0),
                    "native bounds changed during lease"
                );
                Ok(actual)
            });
        if let Err(error) = &result {
            connection.failure = Some(error.to_string());
            connection.client.disconnect();
        }
        result
    }

    fn stop_heartbeat(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(heartbeat) = self.heartbeat.take() {
            let _ = heartbeat.join();
        }
    }
    /// Stop heartbeats, restore exact original state, verify, and close the socket.
    pub fn close(&mut self) -> Result<Readback> {
        ensure!(!self.closed, "session already closed");
        self.stop_heartbeat();
        self.closed = true;
        self.presented = None;
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| anyhow::anyhow!("connection lock poisoned"))?;
        let result = connection
            .client
            .restore(&self.identity)
            .and_then(|actual| {
                verify(&actual, self.original.matrix, self.original.screen_rect)?;
                ensure!(
                    near(&actual.bounds, &self.original.bounds, 1.0),
                    "original native bounds did not restore"
                );
                Ok(actual)
            });
        connection.client.disconnect();
        result
    }
    /// Close transport without an explicit restore request to exercise server-side
    /// disconnect recovery. Caller must independently verify restoration.
    pub fn disconnect(&mut self) {
        self.stop_heartbeat();
        self.closed = true;
        self.presented = None;
        if let Ok(connection) = self.connection.lock() {
            connection.client.disconnect();
        }
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        if !self.closed {
            let _ = self.close();
        }
    }
}
fn rect(r: Rect) -> [f64; 4] {
    [r.origin.x, r.origin.y, r.size.width, r.size.height]
}
fn valid_rect(r: [f64; 4]) -> Result<()> {
    ensure!(
        r.iter().all(|v| v.is_finite() && v.abs() <= 1e12) && r[2] > 0.0 && r[3] > 0.0,
        "invalid native rectangle"
    );
    Ok(())
}
fn valid_matrix(m: [f64; 6]) -> Result<()> {
    ensure!(
        m.iter().all(|v| v.is_finite() && v.abs() <= 1e6)
            && (m[0] * m[3] - m[1] * m[2]).abs() >= 1e-8,
        "invalid native matrix"
    );
    Ok(())
}
fn near<const N: usize>(a: &[f64; N], b: &[f64; N], tolerance: f64) -> bool {
    a.iter()
        .zip(b)
        .all(|(a, b)| a.is_finite() && b.is_finite() && (a - b).abs() <= tolerance)
}
fn verify(actual: &Readback, matrix: [f64; 6], screen: [f64; 4]) -> Result<()> {
    ensure!(
        near(&actual.matrix, &matrix, 1e-6),
        "native matrix readback mismatch (setter may be a no-op)"
    );
    ensure!(
        near(&actual.screen_rect, &screen, 1.0),
        "native screen rectangle mismatch: expected {screen:?}, observed {:?}",
        actual.screen_rect
    );
    Ok(())
}
/// Private SLS matrix maps SCREEN -> BUFFER. Recover the untransformed buffer
/// rectangle from the original native matrix and observed screen bounds, then
/// map the desired projected rectangle into that same buffer. Positive axis-
/// aligned original transforms only; rotated/sheared originals fail explicitly.
pub fn inverse_screen_transform(original: &Readback, desired: [f64; 4]) -> Result<[f64; 6]> {
    valid_rect(original.screen_rect)?;
    valid_rect(original.bounds)?;
    valid_rect(desired)?;
    valid_matrix(original.matrix)?;
    let [a, b, c, d, tx, ty] = original.matrix;
    ensure!(
        a > 0.0 && d > 0.0 && b == 0.0 && c == 0.0,
        "rotated/sheared/reflected native original is unsupported"
    );
    let [x, y, w, h] = original.screen_rect;
    ensure!(
        near(
            &[a * w, d * h],
            &[original.bounds[2], original.bounds[3]],
            1.0
        ),
        "native bounds and original inverse matrix disagree"
    );
    let sx = original.bounds[2] / desired[2];
    let sy = original.bounds[3] / desired[3];
    let matrix = [
        sx,
        0.0,
        0.0,
        sy,
        a * x + tx - sx * desired[0],
        d * y + ty - sy * desired[1],
    ];
    valid_matrix(matrix)?;
    Ok(matrix)
}
