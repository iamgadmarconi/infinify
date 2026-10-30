// SPDX-License-Identifier: GPL-3.0-or-later
use super::{
    ABI_VERSION, BufferSize, Controller, MAX_REQUEST_BYTES, Rect, SourceIdentity, WindowId,
    ipc_client,
};
use serde_json::json;
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
