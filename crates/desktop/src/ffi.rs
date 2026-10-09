// SPDX-License-Identifier: GPL-3.0-or-later
use super::{Controller, MAX_REQUEST_BYTES, VERSION};
use serde_json::json;
use std::{
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
};

/// Allocate an opaque controller. Returns null if creation panics.
#[unsafe(no_mangle)]
pub extern "C" fn driftwm_desktop_create() -> *mut Controller {
    catch_unwind(|| Box::into_raw(Box::new(Controller::new()))).unwrap_or(ptr::null_mut())
}
/// Release the controller; null is a no-op.
///
/// # Safety
/// Pointer must be null or a live value returned by create, freed exactly once.
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
            Ok(Ok(data)) => json!({"version": VERSION, "ok": true, "data": data}),
            Ok(Err(error)) => json!({"version": VERSION, "ok": false, "error": error}),
            Err(_) => json!({"version": VERSION, "ok": false, "error": "controller panic; request rejected"}),
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
