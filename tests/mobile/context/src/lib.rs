//! Android context initialization for the repository's test Activity.
use std::ffi::c_void;

/// Initialize the file backend with the test Activity’s Android context.
///
/// # Safety
/// The VM pointer must be valid and the Context must be a process-lifetime JNI
/// global reference. Call once, before starting the test program.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hxn_file_test_context(vm: *mut c_void, context: *mut c_void) {
    unsafe { ndk_context::initialize_android_context(vm, context) };
}
