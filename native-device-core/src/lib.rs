pub mod core;

use core::{
    clear_location_core, developer_mode_status_core, device_info_core,
    enumerate_ios_devices_core, set_location_core, CommandStatus, StatusResponse,
};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

// ── C FFI exports ───────────────────────────────────────────────────

fn to_c_string(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("error: null byte in output").unwrap())
        .into_raw()
}

fn from_c_str(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

macro_rules! ffi_ok {
    ($result:expr) => {
        match $result {
            Ok(s) => to_c_string(s),
            Err(e) => {
                let resp = StatusResponse {
                    status: CommandStatus::Error,
                    error: Some(e),
                };
                to_c_string(serde_json::to_string(&resp).unwrap_or_else(|_| {
                    r#"{"status":"error","error":"serialization failed"}"#.to_string()
                }))
            }
        }
    };
}

#[no_mangle]
pub extern "C" fn gte_enumerate_ios_devices() -> *mut c_char {
    let rt = tokio::runtime::Runtime::new().unwrap();
    ffi_ok!(rt.block_on(enumerate_ios_devices_core()))
}

#[no_mangle]
pub extern "C" fn gte_device_info(udid: *const c_char) -> *mut c_char {
    let udid = from_c_str(udid);
    let rt = tokio::runtime::Runtime::new().unwrap();
    ffi_ok!(rt.block_on(device_info_core(&udid)))
}

#[no_mangle]
pub extern "C" fn gte_developer_mode_status(udid: *const c_char) -> *mut c_char {
    let udid = from_c_str(udid);
    let rt = tokio::runtime::Runtime::new().unwrap();
    ffi_ok!(rt.block_on(developer_mode_status_core(&udid)))
}

#[no_mangle]
pub extern "C" fn gte_set_location(
    udid: *const c_char,
    lat: *const c_char,
    lon: *const c_char,
) -> *mut c_char {
    let udid = from_c_str(udid);
    let lat: f64 = match from_c_str(lat).parse() {
        Ok(v) => v,
        Err(e) => {
            let resp = StatusResponse {
                status: CommandStatus::Error,
                error: Some(format!("invalid latitude: {e}")),
            };
            return to_c_string(serde_json::to_string(&resp).unwrap_or_else(|_| {
                r#"{"status":"error","error":"serialization failed"}"#.to_string()
            }));
        }
    };
    let lon: f64 = match from_c_str(lon).parse() {
        Ok(v) => v,
        Err(e) => {
            let resp = StatusResponse {
                status: CommandStatus::Error,
                error: Some(format!("invalid longitude: {e}")),
            };
            return to_c_string(serde_json::to_string(&resp).unwrap_or_else(|_| {
                r#"{"status":"error","error":"serialization failed"}"#.to_string()
            }));
        }
    };
    let rt = tokio::runtime::Runtime::new().unwrap();
    ffi_ok!(rt.block_on(set_location_core(&udid, lat, lon)))
}

#[no_mangle]
pub extern "C" fn gte_clear_location(udid: *const c_char) -> *mut c_char {
    let udid = from_c_str(udid);
    let rt = tokio::runtime::Runtime::new().unwrap();
    ffi_ok!(rt.block_on(clear_location_core(&udid)))
}

/// # Safety
/// The `ptr` must have been allocated by Rust and returned from one of the other FFI functions.
#[no_mangle]
pub unsafe extern "C" fn gte_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    let _ = CString::from_raw(ptr);
}
