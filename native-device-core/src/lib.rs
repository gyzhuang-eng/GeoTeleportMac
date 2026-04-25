mod core;

use core::{
    clear_location_core, device_info_core, enumerate_ios_devices_core, json_str,
    set_location_core,
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
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

macro_rules! ffi_ok {
    ($result:expr) => {
        match $result {
            Ok(s) => to_c_string(s),
            Err(e) => to_c_string(format!(r#"{{"error":{}}}"#, json_str(&e))),
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
pub extern "C" fn gte_set_location(
    udid: *const c_char,
    lat: *const c_char,
    lon: *const c_char,
) -> *mut c_char {
    let udid = from_c_str(udid);
    let lat: f64 = match from_c_str(lat).parse() {
        Ok(v) => v,
        Err(e) => return to_c_string(format!(r#"{{"error":"invalid latitude: {e}"}}"#)),
    };
    let lon: f64 = match from_c_str(lon).parse() {
        Ok(v) => v,
        Err(e) => return to_c_string(format!(r#"{{"error":"invalid longitude: {e}"}}"#)),
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

#[no_mangle]
pub extern "C" fn gte_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(ptr);
    }
}
