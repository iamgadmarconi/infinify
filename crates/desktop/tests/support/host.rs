// SPDX-License-Identifier: GPL-3.0-or-later
//! The controller behind its exported C ABI, called with the JSON envelope the
//! shell sends. Shared by the flow scenarios; each adds its own helpers in an
//! `impl Host` of its own.
#![allow(dead_code)]
use driftwm_desktop::*;
use serde_json::{Value, json};
use std::ffi::CStr;

/// An owned controller handle, destroyed on drop.
pub struct Host(pub *mut Controller);
impl Host {
    pub fn new() -> Self {
        let handle = driftwm_desktop_create();
        assert!(!handle.is_null());
        Self(handle)
    }
    /// One request as bytes; the decoded reply, whatever it says.
    pub fn raw(&mut self, bytes: &[u8]) -> Value {
        // SAFETY: live exclusive handle, valid bytes, response freed exactly once.
        unsafe {
            let response = driftwm_desktop_request(self.0, bytes.as_ptr(), bytes.len());
            assert!(!response.is_null());
            let result = serde_json::from_slice(CStr::from_ptr(response).to_bytes()).unwrap();
            driftwm_desktop_response_free(response);
            result
        }
    }
    pub fn call(&mut self, command: Value) -> Value {
        self.raw(&serde_json::to_vec(&json!({"version":1,"command":command})).unwrap())
    }
    pub fn ok(&mut self, command: Value) -> Value {
        let response = self.call(command.clone());
        assert_eq!(response["ok"], true, "{command}: {response}");
        response["data"].clone()
    }
    pub fn snapshot(&mut self) -> Value {
        self.ok(json!({"op":"snapshot"}))
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        // SAFETY: the handle is live and owned; it is destroyed exactly once.
        unsafe {
            driftwm_desktop_destroy(self.0);
        }
    }
}
