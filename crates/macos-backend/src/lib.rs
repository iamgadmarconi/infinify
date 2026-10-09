//! Experimental macOS native backend. Mutation is restricted to spawned fixture windows.
//! Private SkyLight symbols are observations, never proof of runtime support.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    fmt,
    io::{BufRead, BufReader, Write},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    time::{Duration, Instant},
};

/// Native failure, validation error, or subprocess protocol error.
#[derive(Debug)]
pub struct Error(String);
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for Error {}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self(e.to_string())
    }
}
impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Self(e.to_string())
    }
}
/// Backend result.
pub type Result<T> = std::result::Result<T, Error>;
/// JSON doctor report; preserves exact native capability evidence.
pub type DoctorReport = Value;
/// JSON CGWindow record; unavailable titles remain null.
pub type WindowInfo = Value;
/// JSON probe report with separate own-process and foreign-process evidence.
pub type ProbeReport = Value;

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn dw_free(p: *mut c_char);
    fn dw_doctor() -> *mut c_char;
    fn dw_list() -> *mut c_char;
    fn dw_process_start(pid: i32, sec: *mut u64, micros: *mut u64) -> i32;
    fn dw_identity(wid: u32, pid: *mut i32, connection: *mut i32) -> i32;
    fn dw_get(wid: u32, matrix: *mut f64, bounds: *mut f64) -> i32;
    fn dw_set(wid: u32, matrix: *const f64) -> i32;
    fn dw_screen_rect(wid: u32, bounds: *mut f64) -> i32;
    fn dw_fixture_open(nonce: *const c_char) -> u32;
    fn dw_fixture_pump();
    fn dw_fixture_telemetry() -> *mut c_char;
    fn dw_fixture_close();
    fn dw_fixture_layout() -> *mut c_char;
    fn dw_click_fixture(wid: u32, x: f64, y: f64) -> *mut c_char;
}
// This crate intentionally requires macOS rather than providing simulated native success.
#[cfg(not(target_os = "macos"))]
compile_error!("driftwm-macos-backend requires macOS");

fn native_json(p: *mut c_char) -> Result<Value> {
    if p.is_null() {
        return Err(Error("native JSON unavailable".into()));
    }
    // SAFETY: bridge returns a newly allocated NUL-terminated buffer; free exactly once.
    let result = unsafe { serde_json::from_slice(CStr::from_ptr(p).to_bytes()) };
    unsafe {
        dw_free(p);
    }
    Ok(result?)
}
fn status(operation: &str, code: i32) -> Result<()> {
    if code == 0 {
        Ok(())
    } else {
        Err(Error(format!("{operation}: native status {code}")))
    }
}
/// Read symbol presence and permission preflights without requesting permissions.
pub fn doctor() -> Result<DoctorReport> {
    native_json(unsafe { dw_doctor() })
}
/// Enumerate native windows without enrolling or mutating them.
pub fn list_windows() -> Result<Vec<WindowInfo>> {
    serde_json::from_value(native_json(unsafe { dw_list() })?).map_err(Into::into)
}
/// Exact CGAffineTransform components [a,b,c,d,tx,ty], in WindowServer convention.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Transform(pub [f64; 6]);
impl Transform {
    /// Reject nonfinite, singular, and impractically extreme transforms.
    pub fn validate(&self) -> Result<()> {
        let [a, b, c, d, tx, ty] = self.0;
        let determinant = a * d - b * c;
        if !self.0.iter().all(|x| x.is_finite())
            || !determinant.is_finite()
            || determinant.abs() < 1e-9
            || [a, b, c, d].iter().any(|x| x.abs() > 100.0)
            || tx.abs() > 1e7
            || ty.abs() > 1e7
        {
            return Err(Error("invalid/nonfinite/singular transform".into()));
        }
        Ok(())
    }
    fn near(&self, other: &Self) -> bool {
        self.0
            .iter()
            .zip(other.0)
            .all(|(a, b)| (a - b).abs() < 1e-5)
    }
}
/// Identity revalidated immediately before each native read or mutation.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct WindowIdentity {
    /// WindowServer window id.
    pub window_id: u32,
    /// Owning process id.
    pub pid: i32,
    /// Process birth timestamp, preventing PID reuse.
    pub process_start: [u64; 2],
    /// Owning WindowServer connection.
    pub owner_connection: i32,
}
fn identity(window_id: u32) -> Result<WindowIdentity> {
    if window_id == 0 {
        return Err(Error("zero window id".into()));
    }
    let (mut pid, mut connection, mut sec, mut micros) = (0, 0, 0, 0);
    status("SLSGetWindowOwner/CGWindow identity", unsafe {
        dw_identity(window_id, &mut pid, &mut connection)
    })?;
    status("proc_pidinfo process birth", unsafe {
        dw_process_start(pid, &mut sec, &mut micros)
    })?;
    Ok(WindowIdentity {
        window_id,
        pid,
        process_start: [sec, micros],
        owner_connection: connection,
    })
}
/// Actual saved transform and bounds; no identity-transform assumptions.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WindowSnapshot {
    /// Identity associated with this state.
    pub identity: WindowIdentity,
    /// Transform read from WindowServer.
    pub transform: Transform,
    /// WindowServer bounds [x,y,width,height].
    pub bounds: [f64; 4],
    /// Screen rect query status; distinct from untransformed bounds.
    pub screen_rect_status: i32,
    /// Actual WindowServer screen rect when the query succeeds.
    pub screen_rect: Option<[f64; 4]>,
}
/// Read native state only when all identity fields still match. Does not grant mutation authority.
pub fn snapshot_window(expected: &WindowIdentity) -> Result<WindowSnapshot> {
    if identity(expected.window_id)? != *expected {
        return Err(Error("stale window/process identity".into()));
    }
    let (mut matrix, mut bounds) = ([0.0; 6], [0.0; 4]);
    status("SLSGetWindowTransform/Bounds", unsafe {
        dw_get(expected.window_id, matrix.as_mut_ptr(), bounds.as_mut_ptr())
    })?;
    let transform = Transform(matrix);
    transform.validate()?;
    if !bounds.iter().all(|x| x.is_finite()) || bounds[2] <= 0.0 || bounds[3] <= 0.0 {
        return Err(Error("invalid native bounds".into()));
    }
    let mut screen_rect = [0.0; 4];
    let screen_rect_status =
        unsafe { dw_screen_rect(expected.window_id, screen_rect.as_mut_ptr()) };
    Ok(WindowSnapshot {
        screen_rect_status,
        screen_rect: (screen_rect_status == 0 && screen_rect.iter().all(|v| v.is_finite()))
            .then_some(screen_rect),
        identity: expected.clone(),
        transform,
        bounds,
    })
}
/// Proposed native placement on one output. Multi-presentation and clipping remain unsupported.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OutputPlacement {
    /// Output identifier retained for the planner.
    pub output_id: u32,
    /// WindowServer affine transform, not a world-space matrix.
    pub transform: Transform,
    /// Optional clipping rectangle; currently rejected.
    pub clip: Option<[f64; 4]>,
}
/// Validate native capability limits before any mutation.
pub fn validate_placements(placements: &[OutputPlacement]) -> Result<()> {
    if placements.len() != 1 {
        return Err(Error(
            "unsupported: multiple live presentations per window are unproven".into(),
        ));
    }
    if placements[0].clip.is_some() {
        return Err(Error("unsupported: per-output clipping is unproven".into()));
    }
    placements[0].transform.validate()
}
// Enrollment is intentionally private: only a verified child handshake or this process's
// newly-created NSWindow may produce it. Public snapshots cannot grant mutation authority.
struct Enrollment {
    identity: WindowIdentity,
}
struct TransformGuard<'a> {
    enrollment: &'a Enrollment,
    snapshot: WindowSnapshot,
    dirty: bool,
}
impl<'a> TransformGuard<'a> {
    fn new(enrollment: &'a Enrollment) -> Result<Self> {
        Ok(Self {
            enrollment,
            snapshot: snapshot_window(&enrollment.identity)?,
            dirty: false,
        })
    }
    fn apply(&mut self, transform: &Transform) -> Result<i32> {
        transform.validate()?;
        snapshot_window(&self.enrollment.identity)?;
        // A failing setter might still have side effects. Restore on every attempted call.
        self.dirty = true;
        Ok(unsafe { dw_set(self.enrollment.identity.window_id, transform.0.as_ptr()) })
    }
    fn restore(&mut self) -> Result<WindowSnapshot> {
        if identity(self.enrollment.identity.window_id)? != self.enrollment.identity {
            return Err(Error("refusing restore to stale identity".into()));
        }
        if self.dirty {
            status("restore SLSSetWindowTransform", unsafe {
                dw_set(
                    self.enrollment.identity.window_id,
                    self.snapshot.transform.0.as_ptr(),
                )
            })?;
        }
        let restored = snapshot_window(&self.enrollment.identity)?;
        if !restored.transform.near(&self.snapshot.transform) {
            return Err(Error("restore readback mismatch".into()));
        }
        self.dirty = false;
        Ok(restored)
    }
}
impl Drop for TransformGuard<'_> {
    fn drop(&mut self) {
        if !self.dirty {
            return;
        }
        if let Err(e) = self.restore() {
            eprintln!("fixture emergency restore failed: {e}");
        }
    }
}
fn attempt(enrollment: &Enrollment) -> Result<Value> {
    let mut guard = TransformGuard::new(enrollment)?;
    let mut requested = guard.snapshot.transform.clone();
    requested.0[0] *= 1.25;
    requested.0[3] *= 1.25;
    requested.0[4] -= 37.0;
    requested.0[5] -= 23.0;
    let set = guard.apply(&requested);
    let readback = snapshot_window(&enrollment.identity);
    let matched = readback
        .as_ref()
        .is_ok_and(|x| x.transform.near(&requested));
    let restoration = guard.restore();
    Ok(
        json!({"original":guard.snapshot,"requested":requested,"set_status":set.as_ref().ok(),"set_error":set.as_ref().err().map(ToString::to_string),"readback":readback.as_ref().ok(),"readback_error":readback.as_ref().err().map(ToString::to_string),"readback_matches_requested":matched,"runtime_transform_supported":set.as_ref().is_ok_and(|s| *s==0)&&matched,"restored":restoration.is_ok(),"restoration":restoration.as_ref().ok(),"restore_error":restoration.as_ref().err().map(ToString::to_string),"presentation_and_input_validation":"unproven; transform readback alone is insufficient"}),
    )
}
/// Locate the separately built fixture binary adjacent to the running CLI.
pub fn fixture_binary() -> Result<PathBuf> {
    let exe = std::env::current_exe()?;
    let dir = exe
        .parent()
        .ok_or_else(|| Error("executable has no parent".into()))?;
    let dir = if dir
        .file_name()
        .is_some_and(|name| name == "deps" || name == "examples")
    {
        dir.parent().unwrap_or(dir)
    } else {
        dir
    };
    let path = dir.join("driftwm-native-fixture");
    if !path.is_file() {
        return Err(Error(format!(
            "build fixture first: cargo build -p driftwm-macos-backend --bins; missing {}",
            path.display()
        )));
    }
    Ok(path)
}
/// Spawned fixture lifetime. Dropping closes only this child process.
pub struct FixtureSession {
    child: Child,
    input: ChildStdin,
    output: Receiver<std::io::Result<String>>,
    enrollment: Enrollment,
    nonce: String,
}
impl FixtureSession {
    /// Start the bundled fixture and verify nonce, pid, birth time, and WindowServer identity.
    pub fn spawn() -> Result<Self> {
        // macOS uuidgen supplies an unpredictable nonce without exposing an enrollment path.
        let generated = Command::new("/usr/bin/uuidgen").output()?;
        if !generated.status.success() {
            return Err(Error("uuidgen failed".into()));
        }
        let nonce = String::from_utf8_lossy(&generated.stdout).trim().to_owned();
        let mut child = Command::new(fixture_binary()?)
            .arg(&nonce)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let input = child
            .stdin
            .take()
            .ok_or_else(|| Error("fixture stdin missing".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| Error("fixture stdout missing".into()))?;
        let (tx, output) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let handshake = (|| -> Result<WindowIdentity> {
            let line = output
                .recv_timeout(Duration::from_secs(10))
                .map_err(|e| Error(format!("fixture handshake: {e}")))??;
            let v: Value = serde_json::from_str(&line)?;
            if v["nonce"] != nonce || v["pid"].as_u64() != Some(u64::from(child.id())) {
                return Err(Error("fixture nonce/pid mismatch".into()));
            }
            let claimed: WindowIdentity = serde_json::from_value(v["identity"].clone())?;
            if claimed.pid as u32 != child.id() || identity(claimed.window_id)? != claimed {
                return Err(Error("fixture native identity mismatch".into()));
            }
            Ok(claimed)
        })();
        match handshake {
            Ok(identity) => Ok(Self {
                child,
                input,
                output,
                enrollment: Enrollment { identity },
                nonce,
            }),
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                Err(e)
            }
        }
    }
    fn command(&mut self, command: &str) -> Result<Value> {
        writeln!(self.input, "{command}")?;
        self.input.flush()?;
        let line = self
            .output
            .recv_timeout(Duration::from_secs(10))
            .map_err(|e| Error(format!("fixture response: {e}")))??;
        Ok(serde_json::from_str(&line)?)
    }
    /// Read the native fixture's identity and current transform.
    pub fn snapshot(&self) -> Result<WindowSnapshot> {
        snapshot_window(&self.enrollment.identity)
    }
    /// Apply a single placement for a bounded callback, then restore even on error or unwind.
    /// The callback may inspect the native fixture but cannot escape the enrollment guard.
    pub fn with_placement<T>(
        &mut self,
        placement: &OutputPlacement,
        inspect: impl FnOnce(&WindowSnapshot) -> Result<T>,
    ) -> Result<T> {
        validate_placements(std::slice::from_ref(placement))?;
        let mut guard = TransformGuard::new(&self.enrollment)?;
        status("SLSSetWindowTransform", guard.apply(&placement.transform)?)?;
        let state = snapshot_window(&self.enrollment.identity)?;
        if !state.transform.near(&placement.transform) {
            return Err(Error("native transform readback mismatch".into()));
        }
        let result = inspect(&state);
        guard.restore()?;
        result
    }
}
impl Drop for FixtureSession {
    fn drop(&mut self) {
        let _ = writeln!(self.input, "quit");
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
/// Run bounded probes on a newly created native fixture only; never enroll user windows.
pub fn probe_fixture() -> Result<ProbeReport> {
    let mut session = FixtureSession::spawn()?;
    let own = session.command("own-probe")?;
    let foreign = attempt(&session.enrollment);
    let input_probe = input_probe(&mut session);
    let telemetry = session.command("telemetry")?;
    Ok(
        json!({"nonce":session.nonce,"fixture_identity":session.enrollment.identity,"own_process":own,"foreign_process":foreign.as_ref().ok(),"foreign_error":foreign.as_ref().err().map(ToString::to_string),"telemetry":telemetry,"input_probe":input_probe.as_ref().ok(),"input_probe_error":input_probe.as_ref().err().map(ToString::to_string),"doctor":doctor()?,"multiple_live_presentations":"unsupported: unproven","per_output_clipping":"unsupported: unproven","scope":"only self-created fixture windows; no injection or settings changes"}),
    )
}
/// Fixture executable entry. Must run on the process main thread.
pub fn run_fixture(nonce: &str) -> Result<()> {
    if nonce.len() < 16
        || nonce.len() > 128
        || !nonce.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
    {
        return Err(Error("invalid fixture nonce".into()));
    }
    let cnonce = CString::new(nonce).map_err(|e| Error(e.to_string()))?;
    let wid = unsafe { dw_fixture_open(cnonce.as_ptr()) };
    let deadline = Instant::now() + Duration::from_secs(3);
    let initial_identity = loop {
        unsafe { dw_fixture_pump() };
        match identity(wid) {
            Ok(value) => break value,
            Err(e) if Instant::now() >= deadline => return Err(e),
            Err(_) => std::thread::sleep(Duration::from_millis(20)),
        }
    };
    let enrollment = Enrollment {
        identity: initial_identity,
    };
    println!(
        "{}",
        json!({"nonce":nonce,"pid":std::process::id(),"identity":enrollment.identity})
    );
    std::io::stdout().flush()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line {
                Ok(line) => {
                    if tx.send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut held: Option<TransformGuard<'_>> = None;
    while Instant::now() < deadline {
        unsafe { dw_fixture_pump() };
        match rx.try_recv() {
            Ok(line) => {
                let value = match line.as_str() {
                    "own-probe" => match attempt(&enrollment) {
                        Ok(v) => v,
                        Err(e) => json!({"error":e.to_string()}),
                    },
                    "hold" => {
                        if held.is_some() {
                            json!({"error":"already held"})
                        } else {
                            let mut guard = TransformGuard::new(&enrollment)?;
                            let mut matrix = guard.snapshot.transform.clone();
                            matrix.0[0] *= 1.25;
                            matrix.0[3] *= 1.25;
                            matrix.0[4] -= 37.0;
                            matrix.0[5] -= 23.0;
                            let code = guard.apply(&matrix)?;
                            let layout = native_json(unsafe { dw_fixture_layout() })?;
                            let state = snapshot_window(&enrollment.identity)?;
                            let result = json!({"set_status":code,"requested":matrix,"original":guard.snapshot,"held":state,"layout":layout});
                            held = Some(guard);
                            result
                        }
                    }
                    "restore" => match held.take() {
                        Some(mut guard) => {
                            json!({"restored":guard.restore()?,"telemetry":native_json(unsafe {dw_fixture_telemetry()})?})
                        }
                        None => json!({"error":"no held transform"}),
                    },
                    "telemetry" => native_json(unsafe { dw_fixture_telemetry() })?,
                    "quit" => break,
                    _ => json!({"error":"unknown fixture command"}),
                };
                println!("{value}");
                std::io::stdout().flush()?;
            }
            Err(mpsc::TryRecvError::Disconnected) => break,
            Err(mpsc::TryRecvError::Empty) => std::thread::sleep(Duration::from_millis(5)),
        }
    }
    drop(held);
    unsafe { dw_fixture_close() };
    Ok(())
}

fn input_probe(session: &mut FixtureSession) -> Result<Value> {
    let before = session.command("telemetry")?;
    let hold = session.command("hold")?;
    // Always issue restore after a hold, including failures in parsing/identity validation.
    let posted = (|| -> Result<Value> {
        let state: WindowSnapshot = serde_json::from_value(hold["held"].clone())?;
        let original: WindowSnapshot = serde_json::from_value(hold["original"].clone())?;
        let requested: Transform = serde_json::from_value(hold["requested"].clone())?;
        requested.validate()?;
        if state.identity != session.enrollment.identity || original.identity != state.identity {
            return Err(Error("input probe identity mismatch".into()));
        }
        if hold["set_status"] != 0
            || !state.transform.near(&requested)
            || state.transform.near(&original.transform)
            || (requested.0[0] - 1.0).abs() < 1e-6
            || state.screen_rect.is_none()
            || state.screen_rect == original.screen_rect
        {
            return Err(Error("scaled input refused: requested nonunit transform and changed screen geometry were not established".into()));
        }
        let [a, b, c, d, tx, ty] = state.transform.0;
        let px = hold["layout"]["button_buffer_point"][0]
            .as_f64()
            .ok_or_else(|| Error("missing button x".into()))?;
        let py = hold["layout"]["button_buffer_point"][1]
            .as_f64()
            .ok_or_else(|| Error("missing button y".into()))?;
        let det = a * d - b * c;
        let x = (d * (px - tx) - c * (py - ty)) / det;
        let y = (-b * (px - tx) + a * (py - ty)) / det;
        let current = snapshot_window(&session.enrollment.identity)?;
        if !current.transform.near(&state.transform) {
            return Err(Error("held transform changed before input".into()));
        }
        native_json(unsafe { dw_click_fixture(state.identity.window_id, x, y) })
    })();
    std::thread::sleep(Duration::from_millis(150));
    let restoration = session.command("restore")?;
    let after = &restoration["telemetry"];
    let actions = after["actions"]
        .as_u64()
        .unwrap_or(0)
        .saturating_sub(before["actions"].as_u64().unwrap_or(0));
    let events = after["tagged_mouse_down_events"]
        .as_u64()
        .unwrap_or(0)
        .saturating_sub(before["tagged_mouse_down_events"].as_u64().unwrap_or(0));
    let restored: WindowSnapshot = serde_json::from_value(restoration["restored"].clone())?;
    let original: WindowSnapshot = serde_json::from_value(hold["original"].clone())?;
    let expected_x = hold["layout"]["button_buffer_point"][0].as_f64();
    let expected_y = hold["layout"]["appkit_frame"][3]
        .as_f64()
        .zip(hold["layout"]["button_buffer_point"][1].as_f64())
        .map(|(height, y)| height - y);
    let local_matches = after["last_mouse_in_window"][0]
        .as_f64()
        .zip(expected_x)
        .is_some_and(|(actual, expected)| (actual - expected).abs() < 0.01)
        && after["last_mouse_in_window"][1]
            .as_f64()
            .zip(expected_y)
            .is_some_and(|(actual, expected)| (actual - expected).abs() < 0.01);
    Ok(
        json!({"local_coordinates_match":local_matches,"hold":hold,"posted":posted.as_ref().ok(),"post_error":posted.as_ref().err().map(ToString::to_string),"actions_delta":actions,"mouse_down_delta":events,"scaled_button_input_proven":local_matches&&actions>0&&events>0&&hold["set_status"]==0&&hold["held"]["transform"]!=hold["original"]["transform"]&&posted.as_ref().is_ok_and(|v|v["posted"]==true),"restored":restored.transform.near(&original.transform),"restoration":restoration,"scope":"button only; keyboard, scroll, popup and multiple presentations remain unproven"}),
    )
}
