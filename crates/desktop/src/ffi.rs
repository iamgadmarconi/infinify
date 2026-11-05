// SPDX-License-Identifier: GPL-3.0-or-later
use super::{
    ABI_VERSION, BufferSize, Controller, MAX_REQUEST_BYTES, OutputId, Rect, SourceIdentity,
    WindowId, ipc_client,
};
use serde_json::{Map, Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
};

/// Allocate an opaque controller. Returns null if creation panics.
#[unsafe(no_mangle)]
pub extern "C" fn driftwm_desktop_create() -> *mut Controller {
    catch_unwind(|| Box::into_raw(Box::new(Controller::new()))).unwrap_or(ptr::null_mut())
}
/// Copy a controller into an independently owned handle. Returns null for null
/// input or a panic. The copy may move to another thread with exclusive access.
///
/// # Safety
/// Controller must be live and exclusively accessed for this call. Destroy the
/// returned handle exactly once; it does not borrow the original handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_clone(controller: *const Controller) -> *mut Controller {
    fn owned_copy<T: Clone + Send>(value: &T) -> *mut T {
        Box::into_raw(Box::new(value.clone()))
    }
    if controller.is_null() {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller supplies a live, exclusively accessed controller.
        owned_copy(unsafe { &*controller })
    }))
    .unwrap_or(ptr::null_mut())
}
/// Release the controller; null is a no-op.
///
/// # Safety
/// Pointer must be null or a live value returned by create or clone, freed exactly once.
/// No operation may concurrently access this controller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_destroy(controller: *mut Controller) {
    if !controller.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            // SAFETY: required by the function's caller contract.
            drop(unsafe { Box::from_raw(controller) });
        }));
    }
}
/// Native readback observation for the allocation-free current-state query.
/// `owner == 0` means the optional logical owner is absent.
#[repr(C)]
pub struct DesktopObservation {
    pub window: u64,
    pub birth_sec: i64,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub pid: i32,
    pub birth_usec: i32,
    pub wid: u32,
    pub owner: u32,
    pub buffer_width: u32,
    pub buffer_height: u32,
}
/// Return 1 only when native readback Observe would change no source or world
/// state and no gesture or pending structural work requires its transaction.
/// Return 0 for changed/invalid observations, null arguments or panic; callers
/// then use the ordinary JSON Observe path. This does not read native ownership.
///
/// # Safety
/// Both pointers must be null or live and aligned for this call. Serialize access
/// to the controller. Caller must freshly validate native identity and geometry.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_observation_current(
    controller: *const Controller,
    observation: *const DesktopObservation,
) -> u8 {
    if controller.is_null() || observation.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller holds live aligned pointers and exclusive access.
        let (controller, observation) = unsafe { (&*controller, &*observation) };
        controller.observation_current(
            WindowId(observation.window),
            &SourceIdentity {
                pid: observation.pid,
                birth_sec: observation.birth_sec,
                birth_usec: observation.birth_usec,
                wid: observation.wid,
                owner: (observation.owner != 0).then_some(observation.owner),
            },
            Rect::new(
                observation.x,
                observation.y,
                observation.width,
                observation.height,
            ),
            BufferSize {
                width: observation.buffer_width,
                height: observation.buffer_height,
            },
        ) as u8
    }))
    .unwrap_or(0)
}
/// One controller source binding, filled by the read-only query below.
/// `owner == 0` means the optional logical owner is absent.
#[repr(C)]
pub struct DesktopSourceBinding {
    pub generation: u64,
    pub birth_sec: i64,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub pid: i32,
    pub birth_usec: i32,
    pub wid: u32,
    pub owner: u32,
    pub observation_known: u8,
}
/// Copy the current binding of one scene window's source into `binding`.
/// Returns 1 on success; 0 (leaving `binding` untouched) for null arguments,
/// a window absent from the scene, an unbound source or panic. Read-only, no
/// allocation, and it grants no native ownership.
///
/// # Safety
/// Pointers must be null or live and aligned for this call. Serialize access
/// to the controller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_source_binding(
    controller: *const Controller,
    window: u64,
    binding: *mut DesktopSourceBinding,
) -> u8 {
    if controller.is_null() || binding.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller holds a live controller with exclusive access.
        let controller = unsafe { &*controller };
        let id = WindowId(window);
        // The snapshot lists sources of scene windows only; match it.
        let Some(source) = controller
            .scene
            .window(id)
            .and_then(|_| controller.sources.get(&id))
        else {
            return 0;
        };
        let rect = source.observed_rect;
        // SAFETY: binding is live and aligned for writing.
        unsafe {
            binding.write(DesktopSourceBinding {
                generation: source.generation,
                birth_sec: source.identity.birth_sec,
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.size.width,
                height: rect.size.height,
                pid: source.identity.pid,
                birth_usec: source.identity.birth_usec,
                wid: source.identity.wid,
                owner: source.identity.owner.unwrap_or(0),
                observation_known: source.observation_known as u8,
            });
        }
        1
    }))
    .unwrap_or(0)
}
/// One output's screen rectangle, filled by the read-only queries below.
#[repr(C)]
pub struct DesktopRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
/// Copy one output's screen rectangle (the snapshot's outputs[].screen_bounds)
/// into `result`. Returns 1 on success; 0 (leaving `result` untouched) for a
/// null argument, an unknown output or panic. Read-only, no allocation.
///
/// # Safety
/// Pointers must be null or live and aligned for this call. Serialize access
/// to the controller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_output_screen_bounds(
    controller: *const Controller,
    output: u64,
    result: *mut DesktopRect,
) -> u8 {
    if controller.is_null() || result.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller holds a live controller with exclusive access.
        let controller = unsafe { &*controller };
        let Some(view) = controller.scene.output(OutputId(output)) else {
            return 0;
        };
        let b = view.screen_bounds;
        // SAFETY: result is live and aligned for writing.
        unsafe {
            result.write(DesktopRect {
                x: b.origin.x,
                y: b.origin.y,
                width: b.size.width,
                height: b.size.height,
            });
        }
        1
    }))
    .unwrap_or(0)
}
/// Number of outputs, in the snapshot's outputs order. 0 for null or panic.
///
/// # Safety
/// Pointer must be null or live for this call. Serialize access.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_output_count(controller: *const Controller) -> usize {
    if controller.is_null() {
        return 0;
    }
    // SAFETY: the caller holds a live controller with exclusive access.
    catch_unwind(AssertUnwindSafe(|| {
        unsafe { &*controller }.scene.outputs().len()
    }))
    .unwrap_or(0)
}
/// Id of the output at `index` in the snapshot's outputs order. Returns 1 and
/// writes `id`; 0 (untouched) for null, an index out of range or panic.
///
/// # Safety
/// Pointers must be null or live and aligned for this call. Serialize access.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_output_id_at(
    controller: *const Controller,
    index: usize,
    id: *mut u64,
) -> u8 {
    if controller.is_null() || id.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller holds a live controller with exclusive access.
        let Some(view) = unsafe { &*controller }.scene.outputs().get(index) else {
            return 0;
        };
        // SAFETY: id is live and aligned for writing.
        unsafe { id.write(view.id.0) };
        1
    }))
    .unwrap_or(0)
}
/// Execute one bounded UTF-8 JSON request. Always free the returned string with
/// response_free. Returns null only if constructing a response itself panics.
/// No native action is performed, even for the input command.
///
/// # Safety
/// Controller must be live and exclusively accessed for this call. Bytes must
/// point to len readable bytes for this call (not necessarily NUL-terminated).
/// Null arguments are rejected. len must be <= 1 MiB; larger inputs are rejected
/// before dereferencing bytes. Panics roll back in-memory controller changes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_request(
    controller: *mut Controller,
    bytes: *const u8,
    len: usize,
) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if controller.is_null() || bytes.is_null() {
            return Err("null controller or request".to_owned());
        }
        if len > MAX_REQUEST_BYTES {
            return Err("request exceeds 1 MiB".to_owned());
        }
        // SAFETY: caller supplies exclusively borrowed controller and readable bytes.
        let (controller, bytes) =
            unsafe { (&mut *controller, std::slice::from_raw_parts(bytes, len)) };
        controller.request(bytes).map_err(|e| e.to_string())
    }));
    catch_unwind(AssertUnwindSafe(|| {
        let value = match result {
            Ok(Ok(data)) => json!({"version": ABI_VERSION, "ok": true, "data": data}),
            Ok(Err(error)) => json!({"version": ABI_VERSION, "ok": false, "error": error}),
            Err(_) => json!({"version": ABI_VERSION, "ok": false, "error": "controller panic; request rejected"}),
        };
        // JSON escaping guarantees no interior NUL bytes.
        CString::new(value.to_string()).map(CString::into_raw).unwrap_or(ptr::null_mut())
    })).unwrap_or(ptr::null_mut())
}
/// Shell-owned memory of the last snapshot the shell reconstructed, so the next
/// reply can carry only the top-level sections that changed. It is deliberately
/// not part of the controller: a clone must not inherit another reader's base.
/// `token` is monotonic and is never 0 once `base` is set.
pub struct SnapshotCursor {
    base: Option<Value>,
    token: u64,
}
impl SnapshotCursor {
    /// The reply for `current`, then `current` becomes the base. A delta only
    /// answers a caller that applied exactly the base's token; any other caller
    /// (first call, a dropped reply, a reset) gets the whole snapshot.
    fn delta(&mut self, current: Value, applied_token: u64) -> Value {
        let Some(token) = self.token.checked_add(1) else {
            // Unreachable in practice; never let a wrapped token match a stale caller.
            self.base = None;
            return json!({"token": self.token, "full": current});
        };
        let patch = match (&self.base, &current) {
            (Some(Value::Object(old)), Value::Object(new)) if applied_token == self.token => {
                let replace: Map<String, Value> = new
                    .iter()
                    .filter(|(key, value)| old.get(*key) != Some(*value))
                    .map(|(key, value)| (key.clone(), value.clone()))
                    .collect();
                let remove: Vec<&String> =
                    old.keys().filter(|key| !new.contains_key(*key)).collect();
                Some(
                    json!({"base": applied_token, "token": token, "replace": replace, "remove": remove}),
                )
            }
            _ => None,
        };
        let reply = patch.unwrap_or_else(|| json!({"token": token, "full": current}));
        self.base = Some(current);
        self.token = token;
        reply
    }
}
/// Allocate an empty snapshot cursor. Returns null if creation panics.
#[unsafe(no_mangle)]
pub extern "C" fn driftwm_desktop_snapshot_cursor_new() -> *mut SnapshotCursor {
    catch_unwind(|| {
        Box::into_raw(Box::new(SnapshotCursor {
            base: None,
            token: 0,
        }))
    })
    .unwrap_or(ptr::null_mut())
}
/// Release the cursor; null is a no-op.
///
/// # Safety
/// Pointer must be null or a live value returned by cursor_new, freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_snapshot_cursor_free(cursor: *mut SnapshotCursor) {
    if !cursor.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            // SAFETY: required by the function's caller contract.
            drop(unsafe { Box::from_raw(cursor) });
        }));
    }
}
/// The `snapshot` request's data as a change against what `cursor` last gave
/// this caller. `applied_token` is the token of the snapshot the caller holds
/// (0: none). Returns allocated JSON, freed with response_free: on success
/// `{"base":T,"token":N,"replace":{key:value},"remove":[key]}` when T is the
/// cursor's token (patch the held snapshot's top-level keys), else
/// `{"token":N,"full":{...}}`; `full` is exactly the `data` of a `snapshot`
/// request. Failure is the request envelope `{"version":1,"ok":false,...}`.
/// The cursor advances to N on every success, so a caller that does not apply
/// a reply must pass its old token and receives `full`. Read-only on the controller.
///
/// # Safety
/// Pointers must be null or live for this call; serialize access to both.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_snapshot_delta(
    controller: *const Controller,
    cursor: *mut SnapshotCursor,
    applied_token: u64,
) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if controller.is_null() || cursor.is_null() {
            return Err("null controller or cursor".to_owned());
        }
        // SAFETY: the caller holds a live controller and cursor with exclusive access.
        let (controller, cursor) = unsafe { (&*controller, &mut *cursor) };
        let current = controller.pointer_snapshot().map_err(|e| e.to_string())?;
        Ok(cursor.delta(current, applied_token))
    }));
    if result.is_err() && !cursor.is_null() {
        // A panic may have left the base unknown: force the next call to be full.
        // SAFETY: same contract; the panicked closure no longer borrows the cursor.
        unsafe { (*cursor).base = None };
    }
    catch_unwind(AssertUnwindSafe(|| {
        let value = match result {
            Ok(Ok(delta)) => delta,
            Ok(Err(error)) => json!({"version": ABI_VERSION, "ok": false, "error": error}),
            Err(_) => json!({"version": ABI_VERSION, "ok": false, "error": "controller panic; request rejected"}),
        };
        // JSON escaping guarantees no interior NUL bytes.
        CString::new(value.to_string()).map(CString::into_raw).unwrap_or(ptr::null_mut())
    }))
    .unwrap_or(ptr::null_mut())
}
/// Release a response, or do nothing for null.
///
/// # Safety
/// Pointer must be null or an unmodified response returned by request, and may
/// be freed exactly once. Do not pass a pointer into the middle of a response.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_response_free(response: *mut c_char) {
    if !response.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            // SAFETY: required by the caller contract above.
            drop(unsafe { CString::from_raw(response) });
        }));
    }
}
/// Run the `msg` client: `argv` holds the `argc` arguments that follow `msg`.
/// Sends one request to a running Infinify's IPC socket, prints the reply and
/// returns the process exit status: 0 on `Ok`, 1 on an `Err` reply or a
/// connection failure, 2 on a usage error. It creates no controller and
/// performs no native action.
///
/// # Safety
/// `argv` must point to `argc` readable pointers to NUL-terminated strings that
/// stay valid for this call, or `argc` must be zero or negative.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn driftwm_desktop_msg(argc: i32, argv: *const *const c_char) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let mut args = Vec::new();
        for index in 0..usize::try_from(argc).unwrap_or(0) {
            // SAFETY: the caller supplies argc readable argument pointers.
            let arg = if argv.is_null() {
                std::ptr::null()
            } else {
                unsafe { *argv.add(index) }
            };
            // SAFETY: each non-null argument is a NUL-terminated string.
            match (!arg.is_null()).then(|| unsafe { CStr::from_ptr(arg) }.to_str()) {
                Some(Ok(arg)) => args.push(arg.to_owned()),
                _ => {
                    eprintln!("error: arguments must be present and valid UTF-8");
                    return 2;
                }
            }
        }
        ipc_client::run(&args)
    }))
    .unwrap_or(1)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A controller plus the shell's side of the snapshot transport: the
    /// snapshot it holds and the token of that snapshot.
    struct Rig {
        controller: *mut Controller,
        cursor: *mut SnapshotCursor,
        held: Option<Value>,
        token: u64,
    }
    impl Rig {
        fn new() -> Self {
            let mut rig = Self {
                controller: driftwm_desktop_create(),
                cursor: driftwm_desktop_snapshot_cursor_new(),
                held: None,
                token: 0,
            };
            for (name, x) in [("delta-a", 0), ("delta-b", 1000)] {
                rig.call(json!({"op":"register_output","stable_id":name,"screen_bounds":rect(x as f64,50.0,1000.0,800.0)})).unwrap();
            }
            for (wid, x, w) in [(1, 2000.0, 200.0), (2, 10.0, 600.0)] {
                rig.call(json!({"op":"attach","identity":identity(wid),"bundle_id":"test","title":"fixture","buffer":{"width":200,"height":100},"source_rect":rect(x,20.0,w,300.0),"world_rect":rect(x,20.0,w,300.0)})).unwrap();
            }
            rig
        }
        fn call(&mut self, command: Value) -> Result<Value, String> {
            // SAFETY: the rig owns the controller and accesses it exclusively.
            unsafe { &mut *self.controller }
                .request(&serde_json::to_vec(&json!({"version":1,"command":command})).unwrap())
                .map_err(|e| e.to_string())
        }
        fn fresh(&mut self) -> Value {
            self.call(json!({"op":"snapshot"})).unwrap()
        }
        /// One raw delta reply for the given applied token.
        fn raw_delta(&self, applied: u64) -> Value {
            // SAFETY: live controller and cursor; the response is freed exactly once.
            unsafe {
                let response =
                    driftwm_desktop_snapshot_delta(self.controller, self.cursor, applied);
                assert!(!response.is_null());
                let reply = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                driftwm_desktop_response_free(response);
                reply
            }
        }
        /// Pull a delta the way the shell does, apply it to the held snapshot
        /// and compare with a fresh one. True when the reply was a patch.
        fn pull(&mut self) -> (bool, Value) {
            let reply = self.raw_delta(self.token);
            let patched = reply.get("full").is_none();
            let mut next = match reply.get("full") {
                Some(full) => full.clone(),
                None => {
                    assert_eq!(Some(self.token), reply["base"].as_u64());
                    self.held.clone().expect("a patch needs a held snapshot")
                }
            };
            if patched {
                for (key, value) in reply["replace"].as_object().unwrap() {
                    next[key] = value.clone();
                }
                for key in reply["remove"].as_array().unwrap() {
                    next.as_object_mut().unwrap().remove(key.as_str().unwrap());
                }
            }
            assert_eq!(
                next,
                self.fresh(),
                "reconstruction differs from a fresh snapshot"
            );
            assert!(reply["token"].as_u64().unwrap() > self.token);
            self.token = reply["token"].as_u64().unwrap();
            self.held = Some(next);
            (patched, reply)
        }
    }
    impl Drop for Rig {
        fn drop(&mut self) {
            // SAFETY: both handles are live and destroyed exactly once.
            unsafe {
                driftwm_desktop_snapshot_cursor_free(self.cursor);
                driftwm_desktop_destroy(self.controller);
            }
        }
    }
    fn rect(x: f64, y: f64, w: f64, h: f64) -> Value {
        json!({"origin":{"x":x,"y":y},"size":{"width":w,"height":h}})
    }
    fn identity(wid: u32) -> Value {
        json!({"pid":123,"birth_sec":1800000000,"birth_usec":0,"wid":wid})
    }
    #[test]
    fn snapshot_deltas_rebuild_the_snapshot_across_flights_and_edits() {
        let mut rig = Rig::new();
        let (patched, first) = rig.pull();
        assert!(!patched, "the first reply is the whole snapshot");
        assert_eq!(first["token"], 1);
        // Full is exactly what the snapshot request answers.
        assert_eq!(first["full"], rig.fresh());
        let mut patches = 0;
        let mut kept_windows = 0;
        rig.call(json!({"op":"navigate_window","window":1,"output":1,"zoom_policy":"keep"}))
            .unwrap();
        let mut moved = false;
        for frame in 0..400u64 {
            let ticked = rig
                .call(json!({"op":"tick_navigation","timestamp_ns":frame * 16_000_000}))
                .unwrap();
            let (patched, reply) = rig.pull();
            assert!(patched, "frame {frame}");
            patches += 1;
            kept_windows += !reply["replace"]
                .as_object()
                .unwrap()
                .contains_key("windows") as u32;
            moved |= reply["replace"]
                .as_object()
                .unwrap()
                .contains_key("outputs");
            if frame > 2 && ticked["clock_only"] == true {
                break;
            }
        }
        assert!(moved, "the flight moved an output");
        // Only the flight's first frame (focus and the window list settle) re-sends windows.
        assert!(
            patches > 3 && kept_windows + 1 >= patches,
            "windows re-sent during a camera flight"
        );
        let steps = [
            json!({"op":"action","output":1,"action":"zoom-in"}),
            json!({"op":"action","output":1,"action":"zoom-out"}),
            json!({"op":"pan","output":1,"screen_delta":{"x":20.0,"y":5.0},"time_ms":1000,"source":"finger"}),
            json!({"op":"hover","output":1,"screen":{"x":300.0,"y":200.0}}),
            json!({"op":"hover","output":2,"screen":{"x":1300.0,"y":300.0}}),
            json!({"op":"observe","window":2,"identity":identity(2),"source_rect":rect(30.0,40.0,640.0,320.0),"buffer":{"width":640,"height":320}}),
            json!({"op":"attach","identity":identity(3),"bundle_id":"test","title":"third","buffer":{"width":200,"height":100},"source_rect":rect(500.0,500.0,300.0,200.0),"world_rect":rect(500.0,500.0,300.0,200.0)}),
            json!({"op":"retitle","window":3,"identity":identity(3),"title":"renamed"}),
            json!({"op":"action","output":1,"action":"close-window"}),
            json!({"op":"window_closed","window":3,"identity":identity(3)}),
            json!({"op":"register_output","stable_id":"delta-c","screen_bounds":rect(2200.0,50.0,500.0,400.0)}),
        ];
        for step in steps {
            // A refused command (a window already gone) still leaves a consistent pair.
            let _ = rig.call(step);
            rig.pull();
        }
        // A failed command changes nothing and the next delta is empty.
        assert!(rig.call(json!({"op":"no-such-op"})).is_err());
        assert!(
            rig.call(json!({"op":"tick_navigation","timestamp_ns":1}))
                .is_err()
        );
        let (patched, reply) = rig.pull();
        assert!(
            patched
                && reply["replace"].as_object().unwrap().is_empty()
                && reply["remove"] == json!([])
        );
        // Save, edit, load: the loaded scene replaces whole sections.
        let path = std::env::temp_dir().join(format!("infinify-delta-{}.json", std::process::id()));
        let path = path.to_str().unwrap().to_owned();
        rig.call(json!({"op":"save","path":path})).unwrap();
        rig.call(json!({"op":"action","output":1,"action":"zoom-in"}))
            .unwrap();
        rig.pull();
        rig.call(json!({"op":"load","path":path})).unwrap();
        rig.pull();
        let _ = std::fs::remove_file(&path);
    }
    #[test]
    fn snapshot_delta_answers_full_for_a_stale_token_and_after_a_dropped_reply() {
        let mut rig = Rig::new();
        rig.pull();
        rig.call(json!({"op":"action","output":1,"action":"zoom-in"}))
            .unwrap();
        assert!(rig.pull().0);
        // The shell never applied this reply: it still holds the old token.
        let dropped = rig.raw_delta(rig.token);
        assert!(dropped.get("full").is_none());
        let again = rig.raw_delta(rig.token);
        assert!(
            again.get("full").is_some(),
            "a stale token must resynchronise"
        );
        assert_eq!(again["full"], rig.fresh());
        assert!(again["token"].as_u64() > dropped["token"].as_u64());
        // Its own token (and the unapplied one) now match nothing but the latest reply.
        assert!(
            rig.raw_delta(dropped["token"].as_u64().unwrap())
                .get("full")
                .is_some()
        );
        // A future or zero token is full as well.
        assert!(rig.raw_delta(u64::MAX).get("full").is_some());
        assert!(rig.raw_delta(0).get("full").is_some());
        let latest = rig.raw_delta(0)["token"].as_u64().unwrap();
        let patch = rig.raw_delta(latest);
        assert_eq!(patch["base"], latest);
        assert!(patch["replace"].as_object().unwrap().is_empty());
        // Removed keys are named when the next snapshot lacks them.
        let mut cursor = SnapshotCursor {
            base: None,
            token: 0,
        };
        cursor.delta(json!({"a":1,"b":2,"c":null}), 0);
        let reply = cursor.delta(json!({"a":1,"b":3,"d":null}), 1);
        assert_eq!(
            reply,
            json!({"base":1,"token":2,"replace":{"b":3,"d":null},"remove":["c"]})
        );
        // A non-object snapshot is always sent whole.
        assert_eq!(cursor.delta(json!([1]), 2), json!({"token":3,"full":[1]}));
        assert_eq!(cursor.delta(json!([1]), 3), json!({"token":4,"full":[1]}));
    }
    #[test]
    fn snapshot_delta_rejects_null_arguments() {
        let rig = Rig::new();
        // SAFETY: null arguments are rejected; the responses are freed exactly once.
        unsafe {
            for response in [
                driftwm_desktop_snapshot_delta(ptr::null(), rig.cursor, 0),
                driftwm_desktop_snapshot_delta(rig.controller, ptr::null_mut(), 0),
            ] {
                assert!(!response.is_null());
                let reply: Value =
                    serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
                assert_eq!(
                    (reply["ok"].as_bool(), reply["version"].as_u64()),
                    (Some(false), Some(1))
                );
                driftwm_desktop_response_free(response);
            }
            driftwm_desktop_snapshot_cursor_free(ptr::null_mut());
        }
        // A rejected call leaves the cursor untouched: the first real call is token 1.
        assert_eq!(rig.raw_delta(0)["token"], 1);
    }

    #[test]
    fn output_screen_bounds_match_the_snapshot() {
        let controller = driftwm_desktop_create();
        // SAFETY: the test owns the controller and accesses it exclusively.
        let call = |value: serde_json::Value| {
            unsafe { &mut *controller }
                .request(&serde_json::to_vec(&json!({"version":1,"command":value})).unwrap())
                .unwrap()
        };
        for (name, x) in [("bounds-a", 0), ("bounds-b", 1000)] {
            call(
                json!({"op":"register_output","stable_id":name,"screen_bounds":{"origin":{"x":x,"y":-30.5},"size":{"width":1000,"height":800.25}}}),
            );
        }
        let snapshot = call(json!({"op":"snapshot"}));
        let outputs = snapshot["outputs"].as_array().expect("outputs");
        assert_eq!(outputs.len(), 2);
        // SAFETY: live controller.
        assert_eq!(unsafe { driftwm_desktop_output_count(controller) }, 2);
        for (index, o) in outputs.iter().enumerate() {
            let id = o["id"].as_u64().expect("output id");
            let mut at = 0u64;
            // SAFETY: live controller and result.
            assert_eq!(
                unsafe { driftwm_desktop_output_id_at(controller, index, &mut at) },
                1
            );
            assert_eq!(at, id);
            let mut r = DesktopRect {
                x: 9.0,
                y: 9.0,
                width: 9.0,
                height: 9.0,
            };
            // SAFETY: live controller and result.
            assert_eq!(
                unsafe { driftwm_desktop_output_screen_bounds(controller, id, &mut r) },
                1
            );
            let b = &o["screen_bounds"];
            assert_eq!(Some(r.x), b["origin"]["x"].as_f64());
            assert_eq!(Some(r.y), b["origin"]["y"].as_f64());
            assert_eq!(Some(r.width), b["size"]["width"].as_f64());
            assert_eq!(Some(r.height), b["size"]["height"].as_f64());
        }
        let mut r = DesktopRect {
            x: 9.0,
            y: 9.0,
            width: 9.0,
            height: 9.0,
        };
        let mut at = 7u64;
        // SAFETY: live controller and results; null arguments are rejected.
        unsafe {
            assert_eq!(
                driftwm_desktop_output_screen_bounds(controller, 9999, &mut r),
                0
            );
            assert_eq!(driftwm_desktop_output_id_at(controller, 2, &mut at), 0);
            assert_eq!((r.x, r.width, at), (9.0, 9.0, 7));
            assert_eq!(
                driftwm_desktop_output_screen_bounds(ptr::null(), 1, &mut r),
                0
            );
            assert_eq!(
                driftwm_desktop_output_screen_bounds(controller, 1, ptr::null_mut()),
                0
            );
            assert_eq!(driftwm_desktop_output_count(ptr::null()), 0);
            assert_eq!(driftwm_desktop_output_id_at(ptr::null(), 0, &mut at), 0);
            driftwm_desktop_destroy(controller);
        }
    }
    #[test]
    fn source_binding_tracks_missing_detached_and_rebound_sources() {
        let controller = driftwm_desktop_create();
        // SAFETY: the test owns the controller and accesses it exclusively.
        let call = |value: serde_json::Value| {
            unsafe { &mut *controller }
                .request(&serde_json::to_vec(&json!({"version":1,"command":value})).unwrap())
                .unwrap()
        };
        let query = |window: u64| {
            let mut binding: DesktopSourceBinding = unsafe { std::mem::zeroed() };
            // SAFETY: live controller and binding.
            let found = unsafe { driftwm_desktop_source_binding(controller, window, &mut binding) };
            (found, binding)
        };
        call(
            json!({"op":"register_output","stable_id":"binding-test","screen_bounds":{"origin":{"x":0,"y":0},"size":{"width":1000,"height":800}}}),
        );
        assert_eq!(query(1).0, 0);
        // SAFETY: null arguments are rejected.
        assert_eq!(
            unsafe { driftwm_desktop_source_binding(ptr::null(), 1, ptr::null_mut()) },
            0
        );
        let identity = json!({"pid":123,"birth_sec":1800000000,"birth_usec":5,"wid":456});
        let rect = |x: f64| json!({"origin":{"x":x,"y":0},"size":{"width":300,"height":200}});
        let attached = call(
            json!({"op":"attach","identity":identity,"bundle_id":"test","title":"w","buffer":{"width":300,"height":200},"source_rect":rect(0.0),"world_rect":rect(0.0)}),
        );
        let window = attached["window"].as_u64().expect("attached window id");
        let (found, first) = query(window);
        assert_eq!(
            (found, first.wid, first.owner, first.observation_known),
            (1, 456, 0, 1)
        );
        assert_eq!((first.x, first.width, first.pid), (0.0, 300.0, 123));
        let snapshot = call(json!({"op":"snapshot"}));
        let source = &snapshot["windows"][0]["source"];
        assert_eq!(source["generation"].as_u64(), Some(first.generation));
        assert_eq!(
            source["observed_rect"]["size"]["width"].as_f64(),
            Some(first.width)
        );
        // An observation change is visible immediately.
        call(
            json!({"op":"observe","window":window,"identity":identity,"source_rect":rect(7.0),"buffer":{"width":300,"height":200}}),
        );
        assert_eq!(query(window).1.x, 7.0);
        // A closed source fails closed; a later binding reports its own, newer generation.
        call(json!({"op":"window_closed","window":window,"identity":identity}));
        assert_eq!(query(window).0, 0);
        let rebound = json!({"pid":123,"birth_sec":1800000001,"birth_usec":6,"wid":789,"owner":5});
        let next = call(
            json!({"op":"attach","identity":rebound,"bundle_id":"test","title":"w","buffer":{"width":300,"height":200},"source_rect":rect(3.0),"world_rect":rect(3.0)}),
        );
        let (found, second) = query(next["window"].as_u64().expect("window id"));
        assert_eq!((found, second.wid, second.owner), (1, 789, 5));
        assert!(second.generation > first.generation);
        // SAFETY: the controller is destroyed exactly once.
        unsafe { driftwm_desktop_destroy(controller) };
    }
    #[test]
    fn cloned_handle_owns_independent_state_on_a_worker() {
        // SAFETY: null is explicitly accepted by clone.
        assert!(unsafe { driftwm_desktop_clone(ptr::null()) }.is_null());
        let original = driftwm_desktop_create();
        assert!(!original.is_null());
        // SAFETY: the test owns original and accesses it exclusively.
        let copy = unsafe { driftwm_desktop_clone(original) };
        assert!(!copy.is_null());
        let register = br#"{"version":1,"command":{"op":"register_output","stable_id":"copy-test","screen_bounds":{"origin":{"x":0,"y":0},"size":{"width":100,"height":100}}}}"#;
        // SAFETY: neither original nor copy is accessed concurrently.
        unsafe { &mut *original }.request(register).unwrap();
        // SAFETY: copy transfers to this Box; original is freed exactly once.
        let mut owned = unsafe { Box::from_raw(copy) };
        unsafe { driftwm_desktop_destroy(original) };
        let snapshot = br#"{"version":1,"command":{"op":"snapshot"}}"#;
        let outputs = std::thread::spawn(move || {
            let count = |controller: &mut Controller| {
                controller.request(snapshot).unwrap()["outputs"]
                    .as_array()
                    .unwrap()
                    .len()
            };
            assert_eq!(count(&mut owned), 0);
            owned.request(register).unwrap();
            count(&mut owned)
        })
        .join()
        .unwrap();
        assert_eq!(outputs, 1);
    }
}
